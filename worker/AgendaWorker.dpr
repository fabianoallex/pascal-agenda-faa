program AgendaWorker;

(* The worker (docs/design.md, M4): the outbox relay, the email handler and
  the reminders' scheduler, in one console process. One source for Delphi
  (AgendaWorker.dproj) and Lazarus/FPC (AgendaWorker.lpi, or plain fpc in
  tools/test_http_docker.sh).

    AgendaWorker            run until Ctrl+C or SIGTERM
    AgendaWorker --drain    run passes until one finds nothing to do, then
                            exit (0, or 1 when a pass failed): for scripts

  The loop, every OUTBOX_POLL_MS (at once again while a pass found work):
  - the relay (Agenda.Outbox) hands each pending event to the local sink,
    which writes a delivery per handler; then the sink runs them: today one
    handler, the customer's email (Agenda.Notifications);
  - every REMINDER_INTERVAL_SECONDS, with the "reminders" lease
    (Agenda.Leases: the database's row, or Redis with REDIS_HOST), the
    reminders' pass (Agenda.Reminders), and once an hour the outbox's purge.
  A pass that raises is logged and the loop goes on (a database restarting,
  a mail server down: the outbox retries).

  The worker doesn't migrate: it waits for the api to bring the database to
  the schema it was built for, so one process migrates.

  Settings, from the environment or a .env file next to the executable
  (pascal-api-infra-faa's TAppConfig), besides the api's DB_*, DEV_MODE,
  LINK_SIGNING_KEYS, PUBLIC_BASE_URL, REDIS_* and OTEL_*:

    OUTBOX_POLL_MS            the loop's sleep when idle (1000)
    OUTBOX_BATCH              events a relay pass claims (50)
    OUTBOX_KEEP_DAYS          delivered events kept before the purge (7)
    REMINDER_INTERVAL_SECONDS between reminders' passes (60)
    MAIL_FROM                 the sender, "Name <address>"; required unless
                              DEV_MODE=true
    SMTP_HOST                 send through this server; unset: write .eml
                              files in MAIL_DIR (default: mail, next to the
                              executable)
    SMTP_PORT (25), SMTP_USER, SMTP_PASSWORD,
    SMTP_SECURITY             plain (default), starttls or tls
    SMTP_TIMEOUT_MS (30000)

  Every log line goes through SafeWriteln. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  PascalJsonMapper.Mapper,
  PascalCommon.SafeLog,
  PascalCommon.Tracing,
  PascalApi.Config,
  PascalApi.Otlp,
  PascalApi.Jwt,
  Redis.Types,
  Redis.Client,
  Redis.Lock,
  Agenda.Schema in '..\src\Agenda.Schema.pas',
  Agenda.Database in '..\src\Agenda.Database.pas',
  Agenda.SignedLinks in '..\src\Agenda.SignedLinks.pas',
  Agenda.Settings in '..\src\Agenda.Settings.pas',
  Agenda.Events in '..\src\Agenda.Events.pas',
  Agenda.Outbox in '..\src\Agenda.Outbox.pas',
  Agenda.Mail in '..\src\Agenda.Mail.pas',
  Agenda.Notifications in '..\src\Agenda.Notifications.pas',
  Agenda.Leases in '..\src\Agenda.Leases.pas',
  Agenda.Reminders in '..\src\Agenda.Reminders.pas',
  Agenda.StopSignal in '..\src\Agenda.StopSignal.pas';

const
  APP_NAME = 'agenda-worker';
  APP_VERSION = '0.0.1';
  DEV_MAIL_FROM = 'Agenda <no-reply@agenda.localhost>';
  JOB_REMINDERS = 'reminders';
  PURGE_EVERY_SECONDS = 3600;
  SCHEMA_WAIT_MS = 2000;
  // --drain: at most this many rounds (a handler failing forever ends too).
  DRAIN_MAX_ROUNDS = 100;

type
  // The libraries' callbacks are methods on FPC ("of object").
  TWorkerHooks = class
  public
    procedure Error(const ALine: string);
    procedure OutboxError(const AEvent: TOutboxEvent; const AHandler, AMessage: string);
    procedure Skipped(const AEvent: TOutboxEvent; const AReason: string);
    procedure LeaseUnavailable(ASender: TObject; const AOperation, AKey: string;
      AError: Exception);
  end;

var
  GHooks: TWorkerHooks;
  GFailed: Boolean;

{ TWorkerHooks }

procedure TWorkerHooks.Error(const ALine: string);
begin
  GFailed := True;
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
  GSink: IOutboxLocalSink;
  GMailer: TAppointmentMailer;
  GRelay: TOutboxRelay;
  GReminders: TReminderScheduler;
  GOptions: TOutboxOptions;
  GOwner, GMailDescription, GWarning: string;
  GDrain, GHasLease: Boolean;
  GPollMs, GReminderSeconds, GKeepDays, GRounds: Integer;
  GNextReminders, GNextPurge, GNow: Int64;
  GWork: Integer;

// One round: the relay, the sink, and the scheduler when due. Returns the
// work done (events, deliveries, reminders queued).
function RunRound(ANow: Int64): Integer;
begin
  Result := 0;
  try
    Inc(Result, GRelay.RunOnce(ANow));
  except
    on E: Exception do
      GHooks.Error(Format('relay pass: %s: %s', [E.ClassName, E.Message]));
  end;
  try
    Inc(Result, GSink.RunOnce(ANow));
  except
    on E: Exception do
      GHooks.Error(Format('handlers pass: %s: %s', [E.ClassName, E.Message]));
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
      end;
    end;
  except
    on E: Exception do
      GHooks.Error(Format('reminders pass: %s: %s', [E.ClassName, E.Message]));
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
  GFailed := False;
  GHooks := TWorkerHooks.Create;
  GDatabase := nil;
  GLinks := nil;
  GRedis := nil;
  GRedisLock := nil;
  GRelay := nil;
  GReminders := nil;
  GMailer := nil;
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

      GSink := TOutboxLocalSink.Create(GDatabase.Factory, GOwner, GOptions);
      GSink.SetOnError(GHooks.OutboxError);
      GMailer := TAppointmentMailer.Create(GDatabase.Factory, OpenMail(GMailDescription),
        GLinks, MailFrom, ConfiguredPublicBaseUrl);
      GMailer.OnSkip := GHooks.Skipped;
      GSink.AddHandler(GMailer);
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

      if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
        TPcTracing.Start(TPcTracingOptions.FromEnvironment(APP_NAME, APP_VERSION,
          ReadAppConfig), TOtlpHttpExporter.FromEnvironment, GHooks.Error);

      if GDrain then
        SafeWriteln('%s %s draining as %s', [APP_NAME, APP_VERSION, GOwner])
      else
        SafeWriteln('%s %s running as %s', [APP_NAME, APP_VERSION, GOwner]);
      GNextReminders := 0;
      GNextPurge := 0;
      GRounds := 0;
      while not StopRequested do
      begin
        GNow := TJwt.UnixNow;
        GWork := RunRound(GNow);
        Inc(GRounds);
        if GDrain and ((GWork = 0) or (GRounds >= DRAIN_MAX_ROUNDS)) then
          Break;
        if GWork = 0 then
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
    // The loop has stopped, so nothing runs on these any more: free them in
    // the reverse order of creation.
    GReminders.Free;
    GRelay.Free;
    GSink := nil;
    GMailer := nil;
    GLease := nil;
    GRedisLock.Free;
    GRedis.Free;
    GLinks.Free;
    GDatabase.Free;
    if GFailed and GDrain then
      ExitCode := 1;
    GHooks.Free;
    StopSignalDone;
    StopSignalUninstall;
  end;
end.
