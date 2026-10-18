program AgendaApi;

(* The scheduling API (docs/design.md). One source for Delphi (AgendaApi.dproj)
  and Lazarus/FPC (AgendaApi.lpi, or plain fpc in tools/test_http_docker.sh).

    AgendaApi [port] [--reset]       (default port: PORT, else 9400)

  Settings come from the environment or a .env file next to the executable
  (pascal-api-infra-faa's TAppConfig; .env.example lists them):

    DB_FILE        the SQLite file (default agenda.sqlite next to the executable)
    SQLITE_CLIENT  FPC only: the SQLite library (see Agenda.Database)
    DB_POOL_MAX    connections in the pool (default 10)
    OTEL_EXPORTER_OTLP_ENDPOINT  spans to an OpenTelemetry collector, when set

  On startup the database is brought to the latest migration, before the
  server listens; --reset deletes the file first.

  M0 routes (the rest of the API comes with the next milestones):
    GET /health/live    200 while the process answers
    GET /health/ready   200 when the database answers, 503 otherwise
    GET /metrics        Prometheus text
    GET /swagger        Swagger UI; /swagger/doc.json is the OpenAPI document

  tools/http_scenarios.sh checks them over HTTP. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  Horse,
  PascalJsonMapper.Mapper,
  PascalDb.Migrations,
  PascalCommon.SafeLog,
  PascalCommon.Tracing,
  PascalApi.Config,
  PascalApi.Otlp,
  PascalApi.Http,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.OpenApi,
  PascalApi.Horse.Observability,
  Agenda.Schema in '..\src\Agenda.Schema.pas',
  Agenda.Database in '..\src\Agenda.Database.pas';

const
  APP_NAME = 'agenda-api';
  APP_VERSION = '0.0.1';
  DEFAULT_PORT = 9400;

type
  // Horse's and the libraries' callbacks are methods on FPC ("of object"),
  // so the program's are methods of one object.
  TAgendaHooks = class
  public
    procedure Error(const ALine: string);
    procedure Migration(const AEvent: TMigrationEvent);
    function DatabaseReady: Boolean;
  end;

var
  GDatabase: TAgendaDatabase;

procedure TAgendaHooks.Error(const ALine: string);
begin
  SafeWriteln('ERROR ' + ALine);
end;

procedure TAgendaHooks.Migration(const AEvent: TMigrationEvent);
begin
  if AEvent.Kind = mekApplied then
    SafeWriteln('migration %d %s', [AEvent.Version, AEvent.ScriptName]);
end;

function TAgendaHooks.DatabaseReady: Boolean;
begin
  Result := GDatabase.Ready;
end;

var
  GHooks: TAgendaHooks;
  GPort, I: Integer;
  GReset: Boolean;
  GFile: string;

begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ENDIF}
  // Log lines in UTF-8 on both compilers, to a file or a pipe too. Every log
  // line of this program goes through SafeWriteln, never Writeln.
  PcSetSafeLogUtf8(True);
  // A member a DTO doesn't have is a 400 with its path, not silently dropped.
  TJsonMapper.Shared.UnknownMembers := umError;

  GPort := TAppConfig.GetInt('PORT', DEFAULT_PORT);
  GReset := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--reset' then
      GReset := True
    else
      GPort := StrToIntDef(ParamStr(I), GPort);
  GFile := ExpandFileName(TAppConfig.Get('DB_FILE', ExtractFilePath(ParamStr(0)) + 'agenda.sqlite'));
  // A file another process holds open can't be deleted on Windows: stop
  // instead of starting on old data.
  if GReset and FileExists(GFile) and not DeleteFile(GFile) then
    raise Exception.CreateFmt('--reset: can''t delete %s (another instance using it?)', [GFile]);

  GHooks := TAgendaHooks.Create;
  try
    GDatabase := TAgendaDatabase.Create(GFile);
    GDatabase.Migrate(GHooks.Migration);
    SafeWriteln('database %s at version %d', [GFile, GDatabase.Version]);

    if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
      TPcTracing.Start(TPcTracingOptions.FromEnvironment(APP_NAME, APP_VERSION, ReadAppConfig),
        TOtlpHttpExporter.FromEnvironment, GHooks.Error);
    TErrorHandlerMiddleware.Register(GHooks.Error);
    // The logger first: it also answers a middleware's exception on FPC.
    THorse.Use(TLoggerMiddleware.New(nil, alfJson));
    THorse.Use(TMetricsMiddleware.New);

    TMetricsEndpoint.Register;
    THealthEndpoint.AddCheck('database', GHooks.DatabaseReady);
    THealthEndpoint.Register('/health', GHooks.Error);
    TRouteDoc.Serve('/swagger', 'Agenda API', APP_VERSION);

    SafeWriteln('%s %s listening on port %d', [APP_NAME, APP_VERSION, GPort]);
    THorse.Listen(GPort);
  finally
    GDatabase.Free;
    GHooks.Free;
  end;
end.
