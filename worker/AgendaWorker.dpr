program AgendaWorker;

(* The worker (docs/design.md, M4): the outbox relay, the email handler and
  the reminders' scheduler, in one console process. One source for Delphi
  (AgendaWorker.dproj) and Lazarus/FPC (AgendaWorker.lpi, or plain fpc in
  tools/test_http_docker.sh).

    AgendaWorker            run until Ctrl+C or SIGTERM
    AgendaWorker --drain    run passes until one finds nothing to do, then
                            exit (0, or 1 when a pass failed): for scripts

  Two ways to carry the events (decision 5), the same handler either way:
  - AMQP_HOST unset, the local sink: the relay (Agenda.Outbox) hands each
    pending event to the local sink, which writes a delivery per handler;
    the loop then runs them.
  - AMQP_HOST set, the broker (Agenda.Outbox.Amqp): the relay publishes each
    event to the exchange (confirmed), and a consumer on the "agenda.email"
    queue runs the handler, on pascal-amqp-faa's threads, recording each
    event in PROCESSED_EVENTS; a failure waits AMQP_RETRY_MS in the retry
    queue, and after the tries the message is parked in "agenda.email.dead".
  The handler today is one, the customer's email (Agenda.Notifications).

  The loop, every OUTBOX_POLL_MS (at once again while a pass found work): the
  relay, the local sink's deliveries, and every REMINDER_INTERVAL_SECONDS,
  with the "reminders" lease (Agenda.Leases: the database's row, or Redis
  with REDIS_HOST), the reminders' pass (Agenda.Reminders); once an hour the
  purge of delivered events and processed records. A pass that raises is
  logged and the loop goes on (a database restarting, a mail server or a
  broker down: the outbox retries).

  --drain with the broker: done when a round found nothing, the work and
  retry queues are empty and no handler runs, three times in a row 250 ms
  apart (a message the broker already pushed but the library hasn't handed
  to a callback yet is in neither count); at most DRAIN_MAX_SECONDS.

  Metrics (M5): the outbox's, the consumer's, the emails' and the
  reminders' (Agenda.Metrics, Agenda.Outbox and its AMQP unit) in PcMetrics; with
  OTEL_EXPORTER_OTLP_ENDPOINT set, pushed there every
  OTEL_METRIC_EXPORT_INTERVAL ms (60000) by pascal-api-infra-faa's
  TOtlpMetricsExporter, and once more at the stop. The pending events'
  gauges are measured every PENDING_EVERY_SECONDS.

  The worker doesn't migrate: it waits for the api to bring the database to
  the schema it was built for, so one process migrates. It waits for the
  broker too, when it can't be reached at the start; later drops are the
  connection's own reconnection (the topology and the consumer come back).

  Settings, from the environment or a .env file next to the executable
  (pascal-api-infra-faa's TAppConfig), besides the api's DB_*, DEV_MODE,
  LINK_SIGNING_KEYS, PUBLIC_BASE_URL, REDIS_* and OTEL_*:

    OUTBOX_POLL_MS            the loop's sleep when idle (1000)
    OUTBOX_BATCH              events a relay pass claims (50)
    OUTBOX_KEEP_DAYS          delivered events and processed records kept
                              before the purge (7)
    REMINDER_INTERVAL_SECONDS between reminders' passes (60)
    MAIL_FROM                 the sender, "Name <address>"; required unless
                              DEV_MODE=true
    SMTP_HOST                 send through this server; unset: write .eml
                              files in MAIL_DIR (default: mail, next to the
                              executable)
    SMTP_PORT (25), SMTP_USER, SMTP_PASSWORD,
    SMTP_SECURITY             plain (default), starttls or tls
    SMTP_TIMEOUT_MS (30000)
    AMQP_HOST                 the broker; unset: the local sink
    AMQP_PORT (5672), AMQP_USER (guest), AMQP_PASSWORD (guest), AMQP_VHOST (/)
    AMQP_EXCHANGE             the events' topic exchange (agenda.events)
    AMQP_RETRY_MS             a failed email's wait in the retry queue (30000;
                              changing it means deleting agenda.email.retry)
    AMQP_PREFETCH             messages a consumer holds at once (10)

  Every log line goes through SafeWriteln. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  // First on Windows: Delphi's threads scale on the process heap (M5).
  Agenda.WinHeap in '..\src\Agenda.WinHeap.pas',
  SysUtils,
  PascalJsonMapper.Mapper,
  PascalCommon.SafeLog,
  PascalCommon.Tracing,
  PascalCommon.Threading,
  PascalCommon.Metrics,
  PascalApi.Config,
  PascalApi.Otlp,
  PascalApi.Jwt,
  Redis.Types,
  Redis.Client,
  Redis.Lock,
  AMQP.Connection,
  Agenda.Schema in '..\src\Agenda.Schema.pas',
  Agenda.Database in '..\src\Agenda.Database.pas',
  Agenda.SignedLinks in '..\src\Agenda.SignedLinks.pas',
  Agenda.Settings in '..\src\Agenda.Settings.pas',
  Agenda.Events in '..\src\Agenda.Events.pas',
  Agenda.Outbox in '..\src\Agenda.Outbox.pas',
  Agenda.Outbox.Amqp in '..\src\Agenda.Outbox.Amqp.pas',
  Agenda.Mail in '..\src\Agenda.Mail.pas',
  Agenda.Notifications in '..\src\Agenda.Notifications.pas',
  Agenda.Leases in '..\src\Agenda.Leases.pas',
  Agenda.Reminders in '..\src\Agenda.Reminders.pas',
  Agenda.Metrics in '..\src\Agenda.Metrics.pas',
  Agenda.StopSignal in '..\src\Agenda.StopSignal.pas';

const
  APP_NAME = 'agenda-worker';
  APP_VERSION = '0.0.3';
  DEV_MAIL_FROM = 'Agenda <no-reply@agenda.localhost>';
  JOB_REMINDERS = 'reminders';
  PURGE_EVERY_SECONDS = 3600;
  PENDING_EVERY_SECONDS = 15;
  SCHEMA_WAIT_MS = 2000;
  // --drain: at most this long (a handler failing forever ends too).
  DRAIN_MAX_SECONDS = 90;
  DRAIN_QUIET_ROUNDS = 3;
  DRAIN_QUIET_MS = 250;
  // The email's queue and its PROCESSED_EVENTS consumer name.
  EMAIL_QUEUE = 'agenda.email';
  EMAIL_BINDING = 'appointment.#';

type
  // The libraries' callbacks are methods on FPC ("of object").
  TWorkerHooks = class
  public
    procedure Error(const ALine: string);
    procedure OutboxError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
    procedure Skipped(const AEvent: TOutboxEvent; const AReason: string);
    procedure LeaseUnavailable(ASender: TObject; const AOperation, AKey: string;
      AError: Exception);
    procedure AmqpDisconnected(AConnection: TAMQPConnection);
    procedure AmqpReconnected(AConnection: TAMQPConnection);
    procedure AmqpReconnectError(AConnection: TAMQPConnection; AAttempt: Integer;
      const AError: string);
  end;

var
  GHooks: TWorkerHooks;
  GFailed: Integer;

{ TWorkerHooks }

procedure TWorkerHooks.Error(const ALine: string);
begin
  // The broker's callbacks run on other threads.
  PcAtomicSet(GFailed, 1);
  SafeWriteln('ERROR ' + ALine);
end;

procedure TWorkerHooks.OutboxError(const AEvent: TOutboxEvent; const AHandler,
  AMessage: string);
begin
  if AHandler = '' then
    Error(Format('outbox event %s (%s, tenant %s, try %d): %s', [AEvent.Id, AEvent.Kind,
      AEvent.TenantId, AEvent.Attempts + 1, AMessage]))
  else
    Error(Format('handler %s, event %s (%s, tenant %s, try %d): %s', [AHandler, AEvent.Id,
      AEvent.Kind, AEvent.TenantId, AEvent.Attempts + 1, AMessage]));
end;

procedure TWorkerHooks.Skipped(const AEvent: TOutboxEvent; const AReason: string);
begin
  SafeWriteln('email skipped: event %s (%s, tenant %s): %s', [AEvent.Id, AEvent.Kind,
    AEvent.TenantId, AReason]);
end;

procedure TWorkerHooks.LeaseUnavailable(ASender: TObject; const AOperation, AKey: string;
  AError: Exception);
begin
  Error(Format('lease unavailable (%s %s), the pass waits: %s: %s',
    [AOperation, AKey, AError.ClassName, AError.Message]));
end;

procedure TWorkerHooks.AmqpDisconnected(AConnection: TAMQPConnection);
begin
  SafeWriteln('WARNING broker connection lost; reconnecting');
end;

procedure TWorkerHooks.AmqpReconnected(AConnection: TAMQPConnection);
begin
  SafeWriteln('broker connection back');
end;

procedure TWorkerHooks.AmqpReconnectError(AConnection: TAMQPConnection; AAttempt: Integer;
  const AError: string);
begin
  SafeWriteln('WARNING broker reconnection, try %d: %s', [AAttempt, AError]);
end;

{ Setup }

function OpenMail(out ADescription: string): IMailSender;
var
  LOptions: TSmtpOptions;
  LSecurity: string;
  LEml: TEmlMailSender;
begin
  if TAppConfig.Get('SMTP_HOST', '') = '' then
  begin
    LEml := TEmlMailSender.Create(TAppConfig.Get('MAIL_DIR',
      ExtractFilePath(ParamStr(0)) + 'mail'));
    Result := LEml;
    ADescription := 'eml files in ' + LEml.Directory;
    Exit;
  end;
  LOptions := TSmtpOptions.Default;
  LOptions.Host := TAppConfig.Get('SMTP_HOST', '');
  LOptions.Port := TAppConfig.GetInt('SMTP_PORT', LOptions.Port);
  LOptions.User := TAppConfig.Get('SMTP_USER', '');
  LOptions.Password := TAppConfig.Get('SMTP_PASSWORD', '');
  LOptions.TimeoutMs := TAppConfig.GetInt('SMTP_TIMEOUT_MS', LOptions.TimeoutMs);
  LSecurity := LowerCase(TAppConfig.Get('SMTP_SECURITY', 'plain'));
  if LSecurity = 'plain' then
    LOptions.Security := smPlain
  else if LSecurity = 'starttls' then
    LOptions.Security := smStartTls
  else if LSecurity = 'tls' then
    LOptions.Security := smTls
  else
    raise Exception.CreateFmt('SMTP_SECURITY must be plain, starttls or tls, not "%s"',
      [LSecurity]);
  Result := TSmtpMailSender.Create(LOptions);
  ADescription := Format('smtp %s:%d (%s)', [LOptions.Host, LOptions.Port, LSecurity]);
end;

// The lease's Redis client, as the api's slot lock has its own (REDIS_*).
function OpenRedis: TRedisClient;
var
  LParams: TRedisParams;
begin
  LParams := RedisDefaultParams;
  LParams.Host := TAppConfig.Get('REDIS_HOST', '');
  LParams.Port := TAppConfig.GetInt('REDIS_PORT', REDIS_DEFAULT_PORT);
  LParams.Password := TAppConfig.Get('REDIS_PASSWORD', '');
  LParams.ConnectTimeoutMs := TAppConfig.GetInt('REDIS_CONNECT_TIMEOUT_MS', 500);
  LParams.ClientName := APP_NAME;
  Result := TRedisClient.Create(LParams);
end;

// The broker's connection, reconnecting by itself (the consumer and the
// topology come back with it).
function OpenAmqp: TAMQPConnection;
var
  LParams: TAMQPConnectionParams;
begin
  LParams := TAMQPConnectionParams.Localhost;
  LParams.Host := TAppConfig.Get('AMQP_HOST', '');
  LParams.Port := Word(TAppConfig.GetInt('AMQP_PORT', 5672));
  LParams.User := TAppConfig.Get('AMQP_USER', 'guest');
  LParams.Password := TAppConfig.Get('AMQP_PASSWORD', 'guest');
  LParams.VirtualHost := TAppConfig.Get('AMQP_VHOST', '/');
  LParams.AutoReconnect := True;
  LParams.ConnectionName := APP_NAME;
  Result := TAMQPConnection.Create(LParams);
  Result.OnDisconnect := GHooks.AmqpDisconnected;
  Result.OnReconnect := GHooks.AmqpReconnected;
  Result.OnReconnectError := GHooks.AmqpReconnectError;
end;

// Opens AConnection, trying again every SCHEMA_WAIT_MS while the broker
// can't be reached (it may start after the worker); False when stopped first.
function WaitForBroker(AConnection: TAMQPConnection): Boolean;
var
  LSaid, LLine: string;
begin
  LSaid := '';
  while not StopRequested do
  begin
    try
      AConnection.Open;
      Exit(True);
    except
      on E: Exception do
        LLine := Format('waiting for the broker: %s: %s', [E.ClassName, E.Message]);
    end;
    if LLine <> LSaid then
      SafeWriteln(LLine);
    LSaid := LLine;
    StopSleep(SCHEMA_WAIT_MS);
  end;
  Result := False;
end;

function MailFrom: string;
begin
  Result := TAppConfig.Get('MAIL_FROM', '');
  if Result = '' then
  begin
    if not TAppConfig.GetBool('DEV_MODE', False) then
      raise Exception.Create('MAIL_FROM is required (or DEV_MODE=true for development), ' +
        'as "Name <address>".');
    Result := DEV_MAIL_FROM;
  end;
end;

// Waits until the api has migrated the database to this build's schema;
// False when stopped first.
function WaitForSchema(ADatabase: TAgendaDatabase): Boolean;
var
  LVersion: Integer;
  LSaid: string;
  LLine: string;
begin
  LSaid := '';
  while not StopRequested do
  begin
    try
      LVersion := ADatabase.SchemaVersion;
      if LVersion >= TAgendaDatabase.LatestVersion then
      begin
        SafeWriteln('database %s at version %d', [ADatabase.Description, LVersion]);
        Exit(True);
      end;
      LLine := Format('waiting for the api to migrate the database (version %d, this ' +
        'worker needs %d)', [LVersion, TAgendaDatabase.LatestVersion]);
    except
      on E: Exception do
        LLine := Format('waiting for the database: %s: %s', [E.ClassName, E.Message]);
    end;
    if LLine <> LSaid then
      SafeWriteln(LLine);
    LSaid := LLine;
    StopSleep(SCHEMA_WAIT_MS);
  end;
  Result := False;
end;

var
  GDatabase: TAgendaDatabase;
  GLinks: TSignedLinks;
  GRedis: TRedisClient;
  GRedisLock: TRedisLock;
  GLease: ISchedulerLease;
  GLocal: IOutboxLocalSink;
  GSink: IOutboxSink;
  GMailer: TAppointmentMailer;
  GHandler: IOutboxHandler;
  GAmqp: TAMQPConnection;
  GPublish, GConsume: TAMQPChannel;
  GConsumer: TOutboxAmqpConsumer;
  GQueue: TOutboxAmqpQueue;
  GRelay: TOutboxRelay;
  GReminders: TReminderScheduler;
  GOptions: TOutboxOptions;
  GOwner, GMailDescription, GWarning, GExchange: string;
  GDrain, GHasLease: Boolean;
  GPollMs, GReminderSeconds, GKeepDays, GQuiet: Integer;
  GNextReminders, GNextPurge, GNextPending, GNow, GDrainUntil: Int64;
  GMetrics: TOtlpMetricsExporter;
  GWork: Integer;

// One round: the relay, the local sink, and the scheduler when due. Returns
// the work done (events, deliveries, reminders queued).
function RunRound(ANow: Int64): Integer;
begin
  Result := 0;
  try
    Inc(Result, GRelay.RunOnce(ANow));
  except
    on E: Exception do
      GHooks.Error(Format('relay pass: %s: %s', [E.ClassName, E.Message]));
  end;
  if GLocal <> nil then
    try
      Inc(Result, GLocal.RunOnce(ANow));
    except
      on E: Exception do
        GHooks.Error(Format('handlers pass: %s: %s', [E.ClassName, E.Message]));
    end;
  if ANow >= GNextPending then
  begin
    GNextPending := ANow + PENDING_EVERY_SECONDS;
    try
      TOutbox.MeasurePending(GDatabase.Factory, ANow);
    except
      on E: Exception do
        GHooks.Error(Format('pending events: %s: %s', [E.ClassName, E.Message]));
    end;
  end;
  if (ANow < GNextReminders) and not GDrain then
    Exit;
  GNextReminders := ANow + GReminderSeconds;
  try
    // Kept between passes (renewed each one), so the same worker goes on
    // with it; another takes over when it stops renewing.
    GHasLease := GLease.TryAcquire(JOB_REMINDERS, GReminderSeconds + 30, ANow);
    if GHasLease then
    begin
      Inc(Result, GReminders.RunOnce(ANow));
      if ANow >= GNextPurge then
      begin
        GNextPurge := ANow + PURGE_EVERY_SECONDS;
        TOutbox.Purge(GDatabase.Factory, ANow - Int64(GKeepDays) * 86400);
        OutboxAmqpPurgeProcessed(GDatabase.Factory, ANow - Int64(GKeepDays) * 86400);
      end;
    end;
  except
    on E: Exception do
      GHooks.Error(Format('reminders pass: %s: %s', [E.ClassName, E.Message]));
  end;
end;

// --drain with the broker: nothing ready in the queues, no handler running.
function BrokerQuiet: Boolean;
begin
  Result := True;
  if GConsumer = nil then
    Exit;
  try
    Result := (GConsumer.InFlight = 0) and (OutboxAmqpPending(GPublish, GQueue) = 0);
  except
    on E: Exception do
    begin
      GHooks.Error(Format('queue count: %s: %s', [E.ClassName, E.Message]));
      Result := False;
    end;
  end;
end;

begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
  PcSetSafeLogUtf8(True);
  GDrain := (ParamCount >= 1) and (ParamStr(1) = '--drain');
  if (ParamCount >= 1) and not GDrain then
  begin
    SafeWriteln('Usage: AgendaWorker [--drain]');
    ExitCode := 2;
    Exit;
  end;
  GFailed := 0;
  GHooks := TWorkerHooks.Create;
  GDatabase := nil;
  GLinks := nil;
  GRedis := nil;
  GRedisLock := nil;
  GRelay := nil;
  GReminders := nil;
  GMailer := nil;
  GAmqp := nil;
  GPublish := nil;
  GConsume := nil;
  GConsumer := nil;
  StopSignalInstall;
  try
    try
      GDatabase := TAgendaDatabase.Create;
      if not WaitForSchema(GDatabase) then
        Exit;
      GLinks := ConfiguredLinks(GWarning);
      if GWarning <> '' then
        SafeWriteln(GWarning);
      GOwner := OutboxNewOwner(APP_NAME);
      GOptions := TOutboxOptions.Default;
      GOptions.BatchSize := TAppConfig.GetInt('OUTBOX_BATCH', GOptions.BatchSize);
      GPollMs := TAppConfig.GetInt('OUTBOX_POLL_MS', 1000);
      GReminderSeconds := TAppConfig.GetInt('REMINDER_INTERVAL_SECONDS', 60);
      GKeepDays := TAppConfig.GetInt('OUTBOX_KEEP_DAYS', 7);

      GMailer := TAppointmentMailer.Create(GDatabase.Factory, OpenMail(GMailDescription),
        GLinks, MailFrom, ConfiguredPublicBaseUrl);
      GMailer.OnSkip := GHooks.Skipped;
      GHandler := GMailer;

      if TAppConfig.Get('AMQP_HOST', '') = '' then
      begin
        GLocal := TOutboxLocalSink.Create(GDatabase.Factory, GOwner, GOptions);
        GLocal.SetOnError(GHooks.OutboxError);
        GLocal.AddHandler(GHandler);
        GSink := GLocal;
        SafeWriteln('events: the local sink');
      end
      else
      begin
        GExchange := TAppConfig.Get('AMQP_EXCHANGE', 'agenda.events');
        GQueue := TOutboxAmqpQueue.Create(EMAIL_QUEUE, GExchange, EMAIL_BINDING);
        GQueue.RetryDelayMs := TAppConfig.GetInt('AMQP_RETRY_MS', GQueue.RetryDelayMs);
        GQueue.Prefetch := TAppConfig.GetInt('AMQP_PREFETCH', GQueue.Prefetch);
        GQueue.MaxAttempts := GOptions.MaxAttempts;
        GAmqp := OpenAmqp;
        if not WaitForBroker(GAmqp) then
          Exit;
        GPublish := GAmqp.CreateChannel;
        OutboxAmqpDeclareExchange(GPublish, GExchange);
        OutboxAmqpDeclareQueues(GPublish, GQueue);
        GSink := TOutboxAmqpSink.Create(GPublish, GExchange);
        GConsume := GAmqp.CreateChannel;
        GConsumer := TOutboxAmqpConsumer.Create(GDatabase.Factory, GConsume, GQueue,
          EMAIL_QUEUE, GHandler);
        GConsumer.OnError := GHooks.OutboxError;
        GConsumer.Start;
        SafeWriteln('events: amqp %s:%d, exchange %s, queue %s', [TAppConfig.Get('AMQP_HOST', ''),
          TAppConfig.GetInt('AMQP_PORT', 5672), GExchange, EMAIL_QUEUE]);
      end;
      GRelay := TOutboxRelay.Create(GDatabase.Factory, GSink, GOwner, GOptions);
      GRelay.OnError := GHooks.OutboxError;
      GReminders := TReminderScheduler.Create(GDatabase.Factory);

      if TAppConfig.Get('REDIS_HOST', '') <> '' then
      begin
        GRedis := OpenRedis;
        GRedisLock := TRedisLock.Create(GRedis, TAppConfig.Get('REDIS_LEASE_PREFIX',
          'agenda:lease:'));
        GRedisLock.OnUnavailable := GHooks.LeaseUnavailable;
        GLease := TRedisSchedulerLease.Create(GRedisLock);
        SafeWriteln('lease: redis %s:%d', [TAppConfig.Get('REDIS_HOST', ''),
          TAppConfig.GetInt('REDIS_PORT', REDIS_DEFAULT_PORT)]);
      end
      else
      begin
        GLease := TDbSchedulerLease.Create(GDatabase.Factory, GOwner);
        SafeWriteln('lease: database');
      end;
      SafeWriteln('mail: %s', [GMailDescription]);

      AgendaMetricsInit;
      if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
      begin
        TPcTracing.Start(TPcTracingOptions.FromEnvironment(APP_NAME, APP_VERSION,
          ReadAppConfig), TOtlpHttpExporter.FromEnvironment, GHooks.Error);
        GMetrics := TOtlpMetricsExporter.Create(PcMetrics,
          TOtlpMetricsOptions.FromEnvironment(APP_NAME, APP_VERSION, ReadAppConfig),
          GHooks.Error);
      end;

      if GDrain then
        SafeWriteln('%s %s draining as %s (memory: %s)', [APP_NAME, APP_VERSION, GOwner,
          MemoryManagerName])
      else
        SafeWriteln('%s %s running as %s (memory: %s)', [APP_NAME, APP_VERSION, GOwner,
          MemoryManagerName]);
      GNextReminders := 0;
      GNextPurge := 0;
      GNextPending := 0;
      GQuiet := 0;
      GDrainUntil := TJwt.UnixNow + DRAIN_MAX_SECONDS;
      while not StopRequested do
      begin
        GNow := TJwt.UnixNow;
        GWork := RunRound(GNow);
        if GDrain then
        begin
          if GNow >= GDrainUntil then
          begin
            GHooks.Error(Format('--drain: still busy after %d seconds', [DRAIN_MAX_SECONDS]));
            Break;
          end;
          if (GWork = 0) and BrokerQuiet then
            Inc(GQuiet)
          else
            GQuiet := 0;
          if (GQuiet > 0) and ((GConsumer = nil) or (GQuiet >= DRAIN_QUIET_ROUNDS)) then
            Break;
          if GWork = 0 then
            StopSleep(DRAIN_QUIET_MS);
        end
        else if GWork = 0 then
          StopSleep(GPollMs);
      end;
      if GHasLease then
        try
          GLease.Release(JOB_REMINDERS);
        except
          on E: Exception do
            GHooks.Error(Format('lease release: %s: %s', [E.ClassName, E.Message]));
        end;
      SafeWriteln('%s stopped', [APP_NAME]);
    except
      on E: Exception do
      begin
        GHooks.Error(Format('%s: %s', [E.ClassName, E.Message]));
        ExitCode := 1;
      end;
    end;
  finally
    // The loop has stopped. The consumer first: its channel's Free waits
    // for the callbacks already dispatched (pascal-amqp-faa), which use the
    // handler and the database; then the rest in the reverse order of
    // creation.
    if GConsumer <> nil then
      try
        GConsumer.Stop;
      except
        on E: Exception do
          GHooks.Error(Format('consumer stop: %s: %s', [E.ClassName, E.Message]));
      end;
    GConsume.Free;
    GConsumer.Free;
    GReminders.Free;
    GRelay.Free;
    GSink := nil;
    GPublish.Free;
    GAmqp.Free;
    GLocal := nil;
    GHandler := nil;
    GMailer := nil;
    GLease := nil;
    GRedisLock.Free;
    GRedis.Free;
    GLinks.Free;
    GDatabase.Free;
    if (PcAtomicGet(GFailed) <> 0) and GDrain then
      ExitCode := 1;
    // Last: its Free sends one more export, with what the stop counted.
    GMetrics.Free;
    GHooks.Free;
    StopSignalDone;
    StopSignalUninstall;
  end;
end.
