program AgendaApi;

(* The scheduling API (docs/design.md). One source for Delphi (AgendaApi.dproj)
  and Lazarus/FPC (AgendaApi.lpi, or plain fpc in tools/test_http_docker.sh).

    AgendaApi [port] [--reset]       serve (default port: PORT, else 9400)
    AgendaApi --create-tenant <id> <name> <time zone>
    AgendaApi --create-user <tenant> <email> <owner|staff>   (password: AGENDA_PASSWORD)
    AgendaApi --suspend-tenant <id>
    AgendaApi --resume-tenant <id>

  The commands open the same database, run its migrations, do one thing and
  exit (0, or 1 with the reason). The password comes from the environment,
  never from the command line (other users of the machine can read that).

  Settings come from the environment or a .env file next to the executable
  (pascal-api-infra-faa's TAppConfig; .env.example lists them):

    DB_FILE, SQLITE_CLIENT, DB_POOL_MAX   the database (Agenda.Database)
    JWT_KEYS_MASTER_KEY  seals the JWT signing keys in the database
                         (AES-256-GCM); required unless DEV_MODE=true
    DEV_MODE             true: a development master key when none is set
    ACCESS_TOKEN_SECONDS (900), REFRESH_TOKEN_SECONDS (30 days),
    PASSWORD_ITERATIONS (210000), AUTH_RATE_LIMIT (10 a minute per client
    address on the /auth/ routes), RATE_LIMIT (600 a minute per tenant), CATALOG_TTL (30)
    OTEL_EXPORTER_OTLP_ENDPOINT  spans to an OpenTelemetry collector, when set

  On startup the database is brought to the latest migration, before the
  server listens; --reset deletes the file first.

  Routes:
    POST /auth/login     {"tenant","email","password"} -> tokens; 401
                         "invalid_credentials" for any wrong part; 403
                         "tenant_suspended" after a right password
    POST /auth/refresh   {"refreshToken"} -> new tokens; the old one is spent
    POST /auth/logout    {"refreshToken"} -> 204, whatever the token
    GET  /me             the caller (access token)
    GET  /health/live, /health/ready, /metrics, /swagger (/swagger/doc.json)

  Signing keys: one rotating ring per tenant (TTenantJwtKeyRing), kept and
  sealed in the database (TDbJwtKeyStore + TSealedJwtKeyStore). No legacy
  secret: a token without kid is refused.

  tools/http_scenarios.sh checks all of this over HTTP. *)

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  SysUtils,
  Horse,
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  PascalDb.Interfaces,
  PascalDb.Migrations,
  PascalCommon.SafeLog,
  PascalCommon.Tracing,
  PascalApi.Config,
  PascalApi.Otlp,
  PascalApi.Http,
  PascalApi.JwtKeys,
  PascalApi.Tenancy,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.OpenApi,
  PascalApi.Horse.Observability,
  PascalApi.Horse.Tenancy,
  Agenda.Schema in '..\src\Agenda.Schema.pas',
  Agenda.Database in '..\src\Agenda.Database.pas',
  Agenda.Passwords in '..\src\Agenda.Passwords.pas',
  Agenda.Tokens in '..\src\Agenda.Tokens.pas',
  Agenda.Auth in '..\src\Agenda.Auth.pas',
  Agenda.AuthDtos in '..\src\Agenda.AuthDtos.pas';

const
  APP_NAME = 'agenda-api';
  APP_VERSION = '0.0.2';
  DEFAULT_PORT = 9400;
  // The 32 bytes "development-master-key-change-me": DEV_MODE only.
  DEV_MASTER_KEY = 'dev:ZGV2ZWxvcG1lbnQtbWFzdGVyLWtleS1jaGFuZ2UtbWU=';
  OPEN_PATHS: array[0..6] of string = ('/health', '/metrics', '/swagger', '/auth/login',
    '/auth/refresh', '/auth/logout', '/favicon.ico');

type
  // Horse's and the libraries' callbacks are methods on FPC ("of object"),
  // so the program's are methods of one object.
  TAgendaHooks = class
  public
    procedure Error(const ALine: string);
    procedure Security(const ALine: string);
    procedure Migration(const AEvent: TMigrationEvent);
    function DatabaseReady: Boolean;
    /// TTenantDataResolver's: every tenant is in the one database.
    function NewFactory(const ADatabaseKey, APoolName: string): IDBFactory;
    /// Agenda.Auth's signer: the JWT middleware's key ring.
    function SignClaims(const AClaims: string): string;
    /// The rate limit: /auth/* by client address, the rest by tenant.
    function RateKey(AReq: THorseRequest): string;
    function RateLimitFor(AReq: THorseRequest): Integer;
  end;

var
  GDatabase: TAgendaDatabase;
  GCatalog: ITenantCatalog;
  GResolver: ITenantDataResolver;
  GKeys: IJwtKeyRing;
  GAuth: TAuthService;
  GAuthLimit: Integer;

{ TAgendaHooks }

procedure TAgendaHooks.Error(const ALine: string);
begin
  SafeWriteln('ERROR ' + ALine);
end;

procedure TAgendaHooks.Security(const ALine: string);
begin
  SafeWriteln('SECURITY ' + ALine);
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

function TAgendaHooks.NewFactory(const ADatabaseKey, APoolName: string): IDBFactory;
begin
  if ADatabaseKey <> 'shared' then
    raise ETenantCatalogError.CreateFmt('Database "%s": this API keeps every tenant in one ' +
      'database (mode shared).', [ADatabaseKey]);
  Result := GDatabase.Factory;
end;

function TAgendaHooks.SignClaims(const AClaims: string): string;
begin
  Result := TJwtMiddleware.Sign(AClaims);
end;

function IsAuthPath(AReq: THorseRequest): Boolean;
begin
  Result := Copy(LowerCase(AReq.PathInfo), 1, 6) = '/auth/';
end;

function TAgendaHooks.RateKey(AReq: THorseRequest): string;
var
  LInfo: TTenantInfo;
begin
  if IsAuthPath(AReq) then
    Result := 'auth:' + TClientAddress.Resolve(AReq)
  else if TTenantMiddleware.TryCurrent(AReq, LInfo) then
    Result := 'tenant:' + LInfo.Id
  else
    Result := 'anonymous';
end;

function TAgendaHooks.RateLimitFor(AReq: THorseRequest): Integer;
begin
  Result := 0; // the options' Limit
  if IsAuthPath(AReq) then
    Result := GAuthLimit;
end;

var
  GHooks: TAgendaHooks;

{ Handlers }

// {"error": ..., "code": ...}; a 401 also names its scheme, as HTTP requires.
procedure SendAuthError(ARes: THorseResponse; E: EAuthError);
var
  LWriter: TJsonWriter;
begin
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('error');
    LWriter.WriteString(E.Message);
    LWriter.Name('code');
    LWriter.WriteString(E.Code);
    LWriter.EndObject;
    if E.Status = 401 then
      ARes.AddHeader('WWW-Authenticate', BearerChallenge(False));
    TJsonSend.Send(ARes, LWriter.ToString, E.Status);
  finally
    LWriter.Free;
  end;
end;

procedure SendTokens(ARes: THorseResponse; const ATokens: TAuthTokens);
var
  LDto: TTokensResponse;
  LIntf: ITokensResponse;
begin
  LDto := TTokensResponse.Create;
  LIntf := LDto;
  LDto.AccessToken := ATokens.AccessToken;
  LDto.TokenType := 'Bearer';
  LDto.ExpiresIn := ATokens.ExpiresIn;
  LDto.RefreshToken := ATokens.RefreshToken;
  // Tokens are credentials: no cache may keep them (RFC 6749 section 5.1).
  ARes.AddHeader('Cache-Control', 'no-store');
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ITokensResponse>(LIntf));
end;

function Required(const AValue, AName: string): string;
begin
  if Trim(AValue) = '' then
    // Not CreateFmt: Exception's, inherited, leaves StatusCode 0 (an invalid
    // "HTTP/1.1 0" answer; measured, docs/design.md).
    raise EValidationException.Create(Format('"%s" is required.', [AName]));
  Result := AValue;
end;

procedure PostLogin(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: ILoginRequest;
begin
  LBody := TJsonMapper.Shared.FromJson<ILoginRequest>(AReq.Body);
  try
    SendTokens(ARes, GAuth.Login(Required(LBody.GetTenant, 'tenant'),
      Required(LBody.GetEmail, 'email'), Required(LBody.GetPassword, 'password')));
  except
    on E: EAuthError do
      SendAuthError(ARes, E);
  end;
end;

procedure PostRefresh(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: IRefreshRequest;
begin
  LBody := TJsonMapper.Shared.FromJson<IRefreshRequest>(AReq.Body);
  try
    SendTokens(ARes, GAuth.Refresh(Required(LBody.GetRefreshToken, 'refreshToken')));
  except
    on E: EAuthError do
      SendAuthError(ARes, E);
  end;
end;

procedure PostLogout(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: IRefreshRequest;
begin
  LBody := TJsonMapper.Shared.FromJson<IRefreshRequest>(AReq.Body);
  GAuth.Logout(Required(LBody.GetRefreshToken, 'refreshToken'));
  ARes.Status(204).Send('');
end;

procedure GetMe(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LClaims, LSub: TJsonValue;
  LInfo: TTenantInfo;
  LUser: TUserRow;
  LUserId: string;
  LDto: TMeResponse;
  LIntf: IMeResponse;
begin
  LInfo := TTenantMiddleware.Current(AReq);
  LClaims := TJwtMiddleware.Claims(AReq);
  try
    LSub := nil;
    if LClaims <> nil then
      LSub := LClaims.Find('sub');
    if (LSub = nil) or (LSub.Kind <> jkString) then
      raise ENotFoundException.Create('No such user.');
    LUserId := LSub.AsString;
  finally
    LClaims.Free;
  end;
  // A user removed or deactivated after the token was issued.
  if not GAuth.FindUser(LInfo, LUserId, LUser) then
    raise ENotFoundException.Create('No such user.');
  LDto := TMeResponse.Create;
  LIntf := LDto;
  LDto.Id := LUser.Id;
  LDto.Email := LUser.Email;
  LDto.Role := LUser.Role;
  LDto.Tenant := LInfo.Id;
  TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IMeResponse>(LIntf));
end;

{ Setup }

function OpenKeys: IJwtKeyRing;
var
  LOptions: TJwtRotationOptions;
  LMaster: string;
begin
  LMaster := TAppConfig.Get('JWT_KEYS_MASTER_KEY', '');
  if LMaster = '' then
  begin
    if not TAppConfig.GetBool('DEV_MODE', False) then
      raise Exception.Create('JWT_KEYS_MASTER_KEY is required (or DEV_MODE=true for ' +
        'development). Generate one with: openssl rand -base64 32, and set "v1:<that>".');
    SafeWriteln('WARNING DEV_MODE: the JWT signing keys are sealed with a development key');
    LMaster := DEV_MASTER_KEY;
  end;
  LOptions := TJwtRotationOptions.Default;
  LOptions.MaxTokenSeconds := TAppConfig.GetInt('ACCESS_TOKEN_SECONDS', 900);
  LOptions.LegacySecret := '';
  Result := TTenantJwtKeyRing.Create(GCatalog,
    TSealedJwtKeyStore.Create(TDbJwtKeyStore.Create(GDatabase.Factory),
      TAesGcmSecretCipher.Create(LMaster), True),
    LOptions, TENANT_DEFAULT_CLAIM, GHooks.Error);
end;

function AuthOptions: TAuthOptions;
begin
  Result := TAuthOptions.Default;
  Result.AccessSeconds := TAppConfig.GetInt('ACCESS_TOKEN_SECONDS', Result.AccessSeconds);
  Result.RefreshSeconds := TAppConfig.GetInt('REFRESH_TOKEN_SECONDS', Result.RefreshSeconds);
  Result.PasswordIterations := TAppConfig.GetInt('PASSWORD_ITERATIONS',
    Result.PasswordIterations);
end;

procedure SetSuspended(const AId: string; ASuspended: Boolean);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := GDatabase.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := GDatabase.Factory.SqlLoader['TENANT.SET_SUSPENDED'].SQL;
    LQuery.Params.Integers['SUSPENDED'] := Ord(ASuspended);
    LQuery.Params.Strings['ID'] := AId;
    if LQuery.ExecSql <> 1 then
      raise EArgumentException.CreateFmt('No tenant "%s".', [AId]);
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

// A command instead of the server: ExitCode 0 or 1.
procedure RunCommand(const ACommand: string);

  procedure Need(ACount: Integer; const AUsage: string);
  begin
    if ParamCount < ACount + 1 then
      raise EArgumentException.Create('Usage: AgendaApi ' + ACommand + ' ' + AUsage);
  end;

var
  LPassword: string;
begin
  if ACommand = '--create-tenant' then
  begin
    Need(3, '<id> <name> <time zone>');
    CreateTenant(GDatabase.Factory, ParamStr(2), ParamStr(3), ParamStr(4));
    SafeWriteln('tenant %s created', [ParamStr(2)]);
  end
  else if ACommand = '--create-user' then
  begin
    Need(3, '<tenant> <email> <owner|staff>   (password in AGENDA_PASSWORD)');
    LPassword := GetEnvironmentVariable('AGENDA_PASSWORD');
    if LPassword = '' then
      raise EArgumentException.Create('Set the password in AGENDA_PASSWORD.');
    SafeWriteln('user %s created', [CreateUser(GCatalog, GResolver, ParamStr(2),
      ParamStr(3), ParamStr(4), LPassword, AuthOptions.PasswordIterations)]);
  end
  else if (ACommand = '--suspend-tenant') or (ACommand = '--resume-tenant') then
  begin
    Need(1, '<id>');
    SetSuspended(ParamStr(2), ACommand = '--suspend-tenant');
    SafeWriteln('tenant %s %s', [ParamStr(2), Copy(ACommand, 3, 7) + 'ed']);
  end
  else
    raise EArgumentException.CreateFmt('Unknown command %s.', [ACommand]);
end;

var
  GRateLimit: TRateLimitOptions;
  GPort, I: Integer;
  GReset: Boolean;
  GFile, GCommand: string;

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
  GCommand := '';
  if (ParamCount >= 1) and (Copy(ParamStr(1), 1, 2) = '--') and (ParamStr(1) <> '--reset') then
    GCommand := ParamStr(1)
  else
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
    GResolver := TTenantDataResolver.Create(GHooks.NewFactory);
    if GCommand <> '' then
    begin
      GCatalog := TDbTenantCatalog.Create(GDatabase.Factory);
      try
        RunCommand(GCommand);
      except
        on E: Exception do
        begin
          SafeWriteln('%s: %s', [E.ClassName, E.Message]);
          ExitCode := 1;
        end;
      end;
      Exit;
    end;
    SafeWriteln('database %s at version %d', [GFile, GDatabase.Version]);

    GCatalog := TCachedTenantCatalog.Create(TDbTenantCatalog.Create(GDatabase.Factory),
      TAppConfig.GetInt('CATALOG_TTL', 30));
    GKeys := OpenKeys;
    GAuth := TAuthService.Create(GCatalog, GResolver, GHooks.SignClaims, AuthOptions,
      GHooks.Security);
    GAuthLimit := TAppConfig.GetInt('AUTH_RATE_LIMIT', 10);

    if TAppConfig.Get('OTEL_EXPORTER_OTLP_ENDPOINT', '') <> '' then
      TPcTracing.Start(TPcTracingOptions.FromEnvironment(APP_NAME, APP_VERSION, ReadAppConfig),
        TOtlpHttpExporter.FromEnvironment, GHooks.Error);
    TErrorHandlerMiddleware.Register(GHooks.Error);
    TLoggerMiddleware.AddField('tenant.id', TenantIdOf);
    // The logger first: it also answers a middleware's exception on FPC.
    THorse.Use(TLoggerMiddleware.New(nil, alfJson));
    THorse.Use(TMetricsMiddleware.New);
    THorse.Use(TJwtMiddleware.New(GKeys, OPEN_PATHS));
    THorse.Use(TTenantMiddleware.New(GCatalog));
    GRateLimit := TRateLimitOptions.Default;
    GRateLimit.Limit := TAppConfig.GetInt('RATE_LIMIT', 600);
    GRateLimit.WindowSeconds := 60;
    GRateLimit.KeyExtractor := GHooks.RateKey;
    GRateLimit.LimitFor := GHooks.RateLimitFor;
    THorse.Use(TRateLimitMiddleware.New(GRateLimit));

    TRouteDoc.Post('/auth/login').Summary('Log in: tokens for a user of one tenant').Tag('auth')
      .Body<ILoginRequest>
      .Response<ITokensResponse>(200, 'An access token and a refresh token')
      .Error(400, 'A member is missing or unknown')
      .Error(401, 'invalid_credentials: any part is wrong (the answer doesn''t say which)')
      .Error(403, 'tenant_suspended')
      .Error(429, 'Too many attempts from this address')
      .Register(PostLogin);
    TRouteDoc.Post('/auth/refresh').Summary('New tokens for a refresh token, which is spent')
      .Tag('auth')
      .Body<IRefreshRequest>
      .Response<ITokensResponse>(200, 'The next access token and refresh token')
      .Error(401, 'invalid_refresh_token: unknown, expired, revoked or already used ' +
        '(a reuse revokes every token of that login)')
      .Error(403, 'tenant_suspended')
      .Register(PostRefresh);
    TRouteDoc.Post('/auth/logout').Summary('Revoke a refresh token and the ones before it')
      .Tag('auth')
      .Body<IRefreshRequest>
      .NoContent(204, 'Done (the same for any token)')
      .Register(PostLogout);
    TRouteDoc.Get('/me').Summary('The caller').Tag('auth')
      .Response<IMeResponse>(200)
      .Error(401, 'No valid access token')
      .Error(404, 'The user no longer exists or is inactive')
      .Register(GetMe);

    TMetricsEndpoint.Register;
    THealthEndpoint.AddCheck('database', GHooks.DatabaseReady);
    THealthEndpoint.Register('/health', GHooks.Error);
    TRouteDoc.Serve('/swagger', 'Agenda API', APP_VERSION);

    SafeWriteln('%s %s listening on port %d', [APP_NAME, APP_VERSION, GPort]);
    THorse.Listen(GPort);
  finally
    GAuth.Free;
    GKeys := nil;
    GCatalog := nil;
    GResolver := nil;
    GDatabase.Free;
    GHooks.Free;
  end;
end.
