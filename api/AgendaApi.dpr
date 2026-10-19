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
    GET  /services, /services/:id, /professionals, /professionals/:id
                         any user of the tenant; page, limit, orderBy, search
                         (ignoring case and accents), active=true|false
    POST /services, PATCH|DELETE /services/:id, and the same for
    /professionals       the tenant's owner only (403 "owner_only")
    GET  /professionals/:id/working-hours, /professionals/:id/time-off[/:offId]
                         any user; PUT working-hours (the whole week), POST
                         and DELETE time-off: the owner only
    GET|POST /customers, GET|PATCH /customers/:id
                         any user of the tenant; search in the name, email
                         or phone; DELETE /customers/:id the owner only
    /users, /users/:id   the owner only: list, create (with a password),
                         change, delete; never their own role, active or
                         account (409 "own_account")
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
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalDb.Interfaces,
  PascalDb.Migrations,
  PascalDb.Paging,
  PascalCommon.SafeLog,
  PascalCommon.Tracing,
  PascalApi.Config,
  PascalApi.Otlp,
  PascalApi.Http,
  PascalApi.Pagination,
  PascalApi.JwtKeys,
  PascalApi.Tenancy,
  PascalApi.Horse.Middlewares,
  PascalApi.Horse.OpenApi,
  PascalApi.Horse.Observability,
  PascalApi.Horse.Tenancy,
  PascalApi.RefreshTokens,
  Agenda.Schema in '..\src\Agenda.Schema.pas',
  Agenda.Database in '..\src\Agenda.Database.pas',
  Agenda.Passwords in '..\src\Agenda.Passwords.pas',
  Agenda.Tokens in '..\src\Agenda.Tokens.pas',
  Agenda.Auth in '..\src\Agenda.Auth.pas',
  Agenda.AuthDtos in '..\src\Agenda.AuthDtos.pas',
  Agenda.Text in '..\src\Agenda.Text.pas',
  Agenda.Normalizers in '..\src\Agenda.Normalizers.pas',
  Agenda.Validators in '..\src\Agenda.Validators.pas',
  Agenda.Money in '..\src\Agenda.Money.pas',
  Agenda.Services in '..\src\Agenda.Services.pas',
  Agenda.Professionals in '..\src\Agenda.Professionals.pas',
  Agenda.Customers in '..\src\Agenda.Customers.pas',
  Agenda.Users in '..\src\Agenda.Users.pas',
  Agenda.Times in '..\src\Agenda.Times.pas',
  Agenda.WorkingHours in '..\src\Agenda.WorkingHours.pas',
  Agenda.TimeOff in '..\src\Agenda.TimeOff.pas';

const
  APP_NAME = 'agenda-api';
  APP_VERSION = '0.0.3';
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
  GPasswordIterations: Integer;

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
    // CreateFmt gives a 400 since pascal-api-infra-faa's f1d0aaf; before, it
    // left the status 0 ("HTTP/1.1 0", docs/design.md).
    raise EValidationException.CreateFmt('"%s" is required.', [AName]);
  Result := AValue;
end;

procedure PostLogin(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: ILoginRequest;
begin
  LBody := TJsonMapper.Shared.FromJson<ILoginRequest>(AReq.Body);
  SendTokens(ARes, GAuth.Login(Required(LBody.Tenant, 'tenant'),
    Required(LBody.Email, 'email'), Required(LBody.Password, 'password')));
end;

procedure PostRefresh(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: IRefreshRequest;
begin
  LBody := TJsonMapper.Shared.FromJson<IRefreshRequest>(AReq.Body);
  SendTokens(ARes, GAuth.Refresh(Required(LBody.RefreshToken, 'refreshToken')));
end;

procedure PostLogout(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LBody: IRefreshRequest;
begin
  LBody := TJsonMapper.Shared.FromJson<IRefreshRequest>(AReq.Body);
  GAuth.Logout(Required(LBody.RefreshToken, 'refreshToken'));
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

{ Services and professionals }

const
  PAGE_DEFAULT_LIMIT = 20;
  PAGE_MAX_LIMIT = 100;

function ScopeOf(AReq: THorseRequest): TTenantDataScope;
begin
  Result := GResolver.ScopeFor(TTenantMiddleware.Current(AReq));
end;

// A string claim of the verified token; '' when absent or not a string.
function ClaimString(AReq: THorseRequest; const AName: string): string;
var
  LClaims, LValue: TJsonValue;
begin
  Result := '';
  LClaims := TJwtMiddleware.Claims(AReq);
  try
    LValue := nil;
    if LClaims <> nil then
      LValue := LClaims.Find(AName);
    if (LValue <> nil) and (LValue.Kind = jkString) then
      Result := LValue.AsString;
  finally
    LClaims.Free;
  end;
end;

// Writes are the owner's: a staff member reads. The role comes from the
// verified token (Agenda.Auth writes it at login).
procedure RequireOwner(AReq: THorseRequest);
begin
  if ClaimString(AReq, 'role') <> ROLE_OWNER then
    raise EHttpException.Create(403, 'Only the tenant''s owner can change this.', 'owner_only');
end;

procedure GetServices(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LFind: IServiceFind;
  LRepo: TServiceRepository;
  LPage: TPage<IService>;
begin
  // The members QueryParams<IServiceFind> documents (pascal-api-infra-faa 0.19.0).
  LFind := THorseQueryParams.Read<IServiceFind>(AReq);
  LRepo := TServiceRepository.Create(ScopeOf(AReq));
  try
    LPage := LRepo.FindPage(LFind, PageRequestFrom(LFind.Page, LFind.Limit,
      PAGE_DEFAULT_LIMIT, PAGE_MAX_LIMIT));
  finally
    LRepo.Free;
  end;
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TServiceArray>(LPage.Items)));
end;

procedure GetService(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TServiceRepository;
begin
  LRepo := TServiceRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IService>(LRepo.FindById(AReq.Params['id'])));
  finally
    LRepo.Free;
  end;
end;

procedure PostService(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TServiceRepository;
begin
  RequireOwner(AReq);
  LRepo := TServiceRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IService>(
      LRepo.Insert(THorseBody.Read<IServiceInsert>(AReq))), 201);
  finally
    LRepo.Free;
  end;
end;

procedure PatchService(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TServiceRepository;
begin
  RequireOwner(AReq);
  LRepo := TServiceRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IService>(LRepo.Update(AReq.Params['id'],
      THorseBody.Read<IServicePatch>(AReq))));
  finally
    LRepo.Free;
  end;
end;

procedure DeleteService(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TServiceRepository;
begin
  RequireOwner(AReq);
  LRepo := TServiceRepository.Create(ScopeOf(AReq));
  try
    LRepo.Delete(AReq.Params['id']);
  finally
    LRepo.Free;
  end;
  ARes.Status(204).Send('');
end;

procedure GetProfessionals(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LFind: IProfessionalFind;
  LRepo: TProfessionalRepository;
  LPage: TPage<IProfessional>;
begin
  // The members QueryParams<IProfessionalFind> documents (pascal-api-infra-faa 0.19.0).
  LFind := THorseQueryParams.Read<IProfessionalFind>(AReq);
  LRepo := TProfessionalRepository.Create(ScopeOf(AReq));
  try
    LPage := LRepo.FindPage(LFind, PageRequestFrom(LFind.Page, LFind.Limit,
      PAGE_DEFAULT_LIMIT, PAGE_MAX_LIMIT));
  finally
    LRepo.Free;
  end;
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TProfessionalArray>(LPage.Items)));
end;

procedure GetProfessional(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TProfessionalRepository;
begin
  LRepo := TProfessionalRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IProfessional>(
      LRepo.FindById(AReq.Params['id'])));
  finally
    LRepo.Free;
  end;
end;

procedure PostProfessional(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TProfessionalRepository;
begin
  RequireOwner(AReq);
  LRepo := TProfessionalRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IProfessional>(
      LRepo.Insert(THorseBody.Read<IProfessionalInsert>(AReq))), 201);
  finally
    LRepo.Free;
  end;
end;

procedure PatchProfessional(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TProfessionalRepository;
begin
  RequireOwner(AReq);
  LRepo := TProfessionalRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IProfessional>(LRepo.Update(
      AReq.Params['id'], THorseBody.Read<IProfessionalPatch>(AReq))));
  finally
    LRepo.Free;
  end;
end;

procedure DeleteProfessional(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TProfessionalRepository;
begin
  RequireOwner(AReq);
  LRepo := TProfessionalRepository.Create(ScopeOf(AReq));
  try
    LRepo.Delete(AReq.Params['id']);
  finally
    LRepo.Free;
  end;
  ARes.Status(204).Send('');
end;

{ Customers: any user reads and writes; the owner deletes }

procedure GetCustomers(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LFind: ICustomerFind;
  LRepo: TCustomerRepository;
  LPage: TPage<ICustomer>;
begin
  // The members QueryParams<ICustomerFind> documents (pascal-api-infra-faa 0.19.0).
  LFind := THorseQueryParams.Read<ICustomerFind>(AReq);
  LRepo := TCustomerRepository.Create(ScopeOf(AReq));
  try
    LPage := LRepo.FindPage(LFind, PageRequestFrom(LFind.Page, LFind.Limit,
      PAGE_DEFAULT_LIMIT, PAGE_MAX_LIMIT));
  finally
    LRepo.Free;
  end;
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TCustomerArray>(LPage.Items)));
end;

procedure GetCustomer(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TCustomerRepository;
begin
  LRepo := TCustomerRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICustomer>(LRepo.FindById(AReq.Params['id'])));
  finally
    LRepo.Free;
  end;
end;

procedure PostCustomer(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TCustomerRepository;
begin
  LRepo := TCustomerRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICustomer>(
      LRepo.Insert(THorseBody.Read<ICustomerInsert>(AReq))), 201);
  finally
    LRepo.Free;
  end;
end;

procedure PatchCustomer(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TCustomerRepository;
begin
  LRepo := TCustomerRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ICustomer>(LRepo.Update(AReq.Params['id'],
      THorseBody.Read<ICustomerPatch>(AReq))));
  finally
    LRepo.Free;
  end;
end;

procedure DeleteCustomer(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TCustomerRepository;
begin
  RequireOwner(AReq);
  LRepo := TCustomerRepository.Create(ScopeOf(AReq));
  try
    LRepo.Delete(AReq.Params['id']);
  finally
    LRepo.Free;
  end;
  ARes.Status(204).Send('');
end;

{ Users: the owner only }

function NewUserRepository(AReq: THorseRequest): TUserRepository;
begin
  Result := TUserRepository.Create(ScopeOf(AReq), GPasswordIterations);
end;

procedure GetUsers(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LFind: IUserFind;
  LRepo: TUserRepository;
  LPage: TPage<IUser>;
begin
  RequireOwner(AReq);
  // The members QueryParams<IUserFind> documents (pascal-api-infra-faa 0.19.0).
  LFind := THorseQueryParams.Read<IUserFind>(AReq);
  LRepo := NewUserRepository(AReq);
  try
    LPage := LRepo.FindPage(LFind, PageRequestFrom(LFind.Page, LFind.Limit,
      PAGE_DEFAULT_LIMIT, PAGE_MAX_LIMIT));
  finally
    LRepo.Free;
  end;
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TUserArray>(LPage.Items)));
end;

procedure GetUser(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TUserRepository;
begin
  RequireOwner(AReq);
  LRepo := NewUserRepository(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IUser>(LRepo.FindById(AReq.Params['id'])));
  finally
    LRepo.Free;
  end;
end;

procedure PostUser(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TUserRepository;
begin
  RequireOwner(AReq);
  LRepo := NewUserRepository(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IUser>(
      LRepo.Insert(THorseBody.Read<IUserInsert>(AReq))), 201);
  finally
    LRepo.Free;
  end;
end;

procedure PatchUser(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TUserRepository;
begin
  RequireOwner(AReq);
  LRepo := NewUserRepository(AReq);
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IUser>(LRepo.Update(ClaimString(AReq, 'sub'),
      AReq.Params['id'], THorseBody.Read<IUserPatch>(AReq))));
  finally
    LRepo.Free;
  end;
end;

procedure DeleteUser(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TUserRepository;
begin
  RequireOwner(AReq);
  LRepo := NewUserRepository(AReq);
  try
    LRepo.Delete(ClaimString(AReq, 'sub'), AReq.Params['id']);
  finally
    LRepo.Free;
  end;
  ARes.Status(204).Send('');
end;

{ Working hours and time off: any user reads; the owner changes }

procedure GetWorkingHours(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TWorkingHoursRepository;
begin
  LRepo := TWorkingHoursRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IWorkingWeek>(LRepo.Get(AReq.Params['id'])));
  finally
    LRepo.Free;
  end;
end;

procedure PutWorkingHours(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TWorkingHoursRepository;
begin
  RequireOwner(AReq);
  LRepo := TWorkingHoursRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<IWorkingWeek>(LRepo.Replace(
      AReq.Params['id'], THorseBody.Read<IWorkingWeekPut>(AReq))));
  finally
    LRepo.Free;
  end;
end;

procedure GetTimeOffList(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LFind: ITimeOffFind;
  LRepo: TTimeOffRepository;
  LPage: TPage<ITimeOff>;
begin
  // The members QueryParams<ITimeOffFind> documents (pascal-api-infra-faa 0.19.0).
  LFind := THorseQueryParams.Read<ITimeOffFind>(AReq);
  LRepo := TTimeOffRepository.Create(ScopeOf(AReq));
  try
    LPage := LRepo.FindPage(AReq.Params['id'], LFind, PageRequestFrom(LFind.Page, LFind.Limit,
      PAGE_DEFAULT_LIMIT, PAGE_MAX_LIMIT));
  finally
    LRepo.Free;
  end;
  TJsonSend.Send(ARes, PageEnvelopeJson(LPage.Meta,
    TJsonMapper.Shared.Serialize<TTimeOffArray>(LPage.Items)));
end;

procedure GetTimeOff(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TTimeOffRepository;
begin
  LRepo := TTimeOffRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ITimeOff>(
      LRepo.FindById(AReq.Params['id'], AReq.Params['offId'])));
  finally
    LRepo.Free;
  end;
end;

procedure PostTimeOff(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TTimeOffRepository;
begin
  RequireOwner(AReq);
  LRepo := TTimeOffRepository.Create(ScopeOf(AReq));
  try
    TJsonSend.Send(ARes, TJsonMapper.Shared.ToJson<ITimeOff>(LRepo.Insert(AReq.Params['id'],
      THorseBody.Read<ITimeOffInsert>(AReq))), 201);
  finally
    LRepo.Free;
  end;
end;

procedure DeleteTimeOff(AReq: THorseRequest; ARes: THorseResponse; ANext: TNextProc);
var
  LRepo: TTimeOffRepository;
begin
  RequireOwner(AReq);
  LRepo := TTimeOffRepository.Create(ScopeOf(AReq));
  try
    LRepo.Delete(AReq.Params['id'], AReq.Params['offId']);
  finally
    LRepo.Free;
  end;
  ARes.Status(204).Send('');
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
      TDbRefreshTokenStore.Create(GDatabase.Factory), GHooks.Security);
    GAuthLimit := TAppConfig.GetInt('AUTH_RATE_LIMIT', 10);
    GPasswordIterations := AuthOptions.PasswordIterations;

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

    TRouteDoc.Get('/services').Summary('The tenant''s services, a page at a time').Tag('services')
      .QueryParams<IServiceFind>
      .ResponsePaged<IService>(200, 'A page of services')
      .Error(400, 'A parameter or an order field that is not allowed')
      .Register(GetServices);
    TRouteDoc.Get('/services/:id').Summary('One service').Tag('services')
      .PathParam('id', 'The service''s id')
      .Response<IService>(200)
      .Error(404, 'The tenant has no service with this id')
      .Register(GetService);
    TRouteDoc.Post('/services').Summary('Create a service (owner)').Tag('services')
      .Body<IServiceInsert>
      .Response<IService>(201, 'Created')
      .Error(400, 'Invalid data')
      .Error(403, 'owner_only')
      .Error(409, 'The tenant already has a service with this name')
      .Register(PostService);
    TRouteDoc.Patch('/services/:id').Summary('Change a service (owner)').Tag('services')
      .PathParam('id', 'The service''s id')
      .Body<IServicePatch>
      .Response<IService>(200, 'The service after the change')
      .Error(400, 'Invalid data')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no service with this id')
      .Error(409, 'The tenant already has a service with this name')
      .Register(PatchService);
    TRouteDoc.Delete('/services/:id').Summary('Delete a service (owner)').Tag('services')
      .PathParam('id', 'The service''s id')
      .NoContent(204, 'Deleted')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no service with this id')
      .Register(DeleteService);
    TRouteDoc.Get('/professionals').Summary('The tenant''s professionals, a page at a time')
      .Tag('professionals')
      .QueryParams<IProfessionalFind>
      .ResponsePaged<IProfessional>(200, 'A page of professionals')
      .Error(400, 'A parameter or an order field that is not allowed')
      .Register(GetProfessionals);
    TRouteDoc.Get('/professionals/:id').Summary('One professional').Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .Response<IProfessional>(200)
      .Error(404, 'The tenant has no professional with this id')
      .Register(GetProfessional);
    TRouteDoc.Post('/professionals').Summary('Create a professional (owner)').Tag('professionals')
      .Body<IProfessionalInsert>
      .Response<IProfessional>(201, 'Created')
      .Error(400, 'Invalid data')
      .Error(403, 'owner_only')
      .Register(PostProfessional);
    TRouteDoc.Patch('/professionals/:id').Summary('Change a professional (owner)')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .Body<IProfessionalPatch>
      .Response<IProfessional>(200, 'The professional after the change')
      .Error(400, 'Invalid data')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no professional with this id')
      .Register(PatchProfessional);
    TRouteDoc.Delete('/professionals/:id').Summary('Delete a professional (owner)')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .NoContent(204, 'Deleted')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no professional with this id')
      .Register(DeleteProfessional);

    TRouteDoc.Get('/professionals/:id/working-hours').Summary('A professional''s week')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .Response<IWorkingWeek>(200)
      .Error(404, 'The tenant has no professional with this id')
      .Register(GetWorkingHours);
    TRouteDoc.Put('/professionals/:id/working-hours').Summary('Replace a professional''s week (owner)')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .Body<IWorkingWeekPut>
      .Response<IWorkingWeek>(200, 'The week as stored')
      .Error(400, 'invalid_week: a weekday, a time or an overlap')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no professional with this id')
      .Register(PutWorkingHours);
    TRouteDoc.Get('/professionals/:id/time-off').Summary('A professional''s time off, a page at a time')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .QueryParams<ITimeOffFind>
      .ResponsePaged<ITimeOff>(200, 'A page of time off')
      .Error(400, 'invalid_instant, or an order field that is not allowed')
      .Error(404, 'The tenant has no professional with this id')
      .Register(GetTimeOffList);
    TRouteDoc.Get('/professionals/:id/time-off/:offId').Summary('One entry of time off')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .PathParam('offId', 'The entry''s id')
      .Response<ITimeOff>(200)
      .Error(404, 'The professional has no such entry')
      .Register(GetTimeOff);
    TRouteDoc.Post('/professionals/:id/time-off').Summary('Add time off (owner)')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .Body<ITimeOffInsert>
      .Response<ITimeOff>(201, 'Created')
      .Error(400, 'invalid_instant, or not whole minutes, start after end, too long')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no professional with this id')
      .Register(PostTimeOff);
    TRouteDoc.Delete('/professionals/:id/time-off/:offId').Summary('Remove time off (owner)')
      .Tag('professionals')
      .PathParam('id', 'The professional''s id')
      .PathParam('offId', 'The entry''s id')
      .NoContent(204, 'Removed')
      .Error(403, 'owner_only')
      .Error(404, 'The professional has no such entry')
      .Register(DeleteTimeOff);
    TRouteDoc.Get('/customers').Summary('The tenant''s customers, a page at a time')
      .Tag('customers')
      .QueryParams<ICustomerFind>
      .ResponsePaged<ICustomer>(200, 'A page of customers')
      .Error(400, 'A parameter or an order field that is not allowed')
      .Register(GetCustomers);
    TRouteDoc.Get('/customers/:id').Summary('One customer').Tag('customers')
      .PathParam('id', 'The customer''s id')
      .Response<ICustomer>(200)
      .Error(404, 'The tenant has no customer with this id')
      .Register(GetCustomer);
    TRouteDoc.Post('/customers').Summary('Create a customer').Tag('customers')
      .Body<ICustomerInsert>
      .Response<ICustomer>(201, 'Created')
      .Error(400, 'Invalid data')
      .Register(PostCustomer);
    TRouteDoc.Patch('/customers/:id').Summary('Change a customer').Tag('customers')
      .PathParam('id', 'The customer''s id')
      .Body<ICustomerPatch>
      .Response<ICustomer>(200, 'The customer after the change')
      .Error(400, 'Invalid data')
      .Error(404, 'The tenant has no customer with this id')
      .Register(PatchCustomer);
    TRouteDoc.Delete('/customers/:id').Summary('Delete a customer (owner)').Tag('customers')
      .PathParam('id', 'The customer''s id')
      .NoContent(204, 'Deleted')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no customer with this id')
      .Register(DeleteCustomer);
    TRouteDoc.Get('/users').Summary('The tenant''s users, a page at a time (owner)').Tag('users')
      .QueryParams<IUserFind>
      .ResponsePaged<IUser>(200, 'A page of users')
      .Error(400, 'A parameter or an order field that is not allowed')
      .Error(403, 'owner_only')
      .Register(GetUsers);
    TRouteDoc.Get('/users/:id').Summary('One user (owner)').Tag('users')
      .PathParam('id', 'The user''s id')
      .Response<IUser>(200)
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no user with this id')
      .Register(GetUser);
    TRouteDoc.Post('/users').Summary('Create a user (owner)').Tag('users')
      .Body<IUserInsert>
      .Response<IUser>(201, 'Created')
      .Error(400, 'Invalid data; password_too_short; unknown_professional')
      .Error(403, 'owner_only')
      .Error(409, 'The email, or the professional, belongs to another user')
      .Register(PostUser);
    TRouteDoc.Patch('/users/:id').Summary('Change a user (owner)').Tag('users')
      .PathParam('id', 'The user''s id')
      .Body<IUserPatch>
      .Response<IUser>(200, 'The user after the change')
      .Error(400, 'Invalid data; password_too_short; unknown_professional')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no user with this id')
      .Error(409, 'own_account: your own role or active; or the email or professional is taken')
      .Register(PatchUser);
    TRouteDoc.Delete('/users/:id').Summary('Delete a user (owner)').Tag('users')
      .PathParam('id', 'The user''s id')
      .NoContent(204, 'Deleted; the user''s sessions end')
      .Error(403, 'owner_only')
      .Error(404, 'The tenant has no user with this id')
      .Error(409, 'own_account: you can''t delete yourself')
      .Register(DeleteUser);

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
