unit Agenda.Auth;

{$I agenda.inc}

{ Login, refresh tokens and logout, and creating tenants and users; no Horse
  here (the routes are in the API program).

  Login: the tenant (its slug), an email and a password. Every way to fail
  before the password is checked (an unknown tenant, an unknown or inactive
  user) still verifies the password against a dummy hash, so it costs the
  same time as a wrong password and the answers can't tell which tenants or
  users exist: all of them are one 401, "invalid_credentials". A suspended
  tenant is told so (403, "tenant_suspended") only after a right password.
  A stored hash with fewer iterations than PasswordIterations is replaced
  while the password is at hand.

  Tokens: a short access token (a JWT signed by the tenant's key ring:
  sub = the user's id, tenant_id, role, iat, exp) and a refresh token,
  pascal-api-infra-faa's TRefreshTokens (0.19.0; this unit's flow, moved
  there at the user's choice): "<tenant>.<secret>", only its SHA-256
  stored, used once; a copy that comes back, two refreshes racing on one
  token, or a user gone or inactive revoke the family (AOnSecurity hears of
  it). Logout revokes the family; it answers the same for any token. What
  stays here: the tenant checked against the catalog before any lookup (a
  suspended one is a 403), and the access token's claims.

  Every query on a tenant's rows goes through TTenantFilter.Prepare
  (pascal-api-infra-faa's rule): the tenant comes from the catalog first.
  The refresh tokens' store binds TENANT_ID itself (TDbRefreshTokenStore).

  Refusals are pascal-api-infra-faa's exceptions with a code
  (EUnauthorizedException, EHttpException 403), answered by its error
  handler with "error" and "code" members, a 401 with WWW-Authenticate. }

interface

uses
  SysUtils,
  PascalCommon.Tracing,
  PascalDb.Interfaces,
  PascalApi.Tenancy,
  PascalApi.RefreshTokens;

const
  ROLE_OWNER = 'owner';
  ROLE_STAFF = 'staff';
  CODE_INVALID_CREDENTIALS = 'invalid_credentials';
  CODE_INVALID_REFRESH_TOKEN = 'invalid_refresh_token';
  CODE_TENANT_SUSPENDED = 'tenant_suspended';

type
  /// Signs JWT claims (the API passes the JWT middleware's key ring).
  TSignClaimsFunc = function(const AClaims: string): string of object;

  TAuthOptions = record
    AccessSeconds: Int64;
    RefreshSeconds: Int64;
    PasswordIterations: Integer;
    class function Default: TAuthOptions; static;
  end;

  TAuthTokens = record
    AccessToken: string;
    ExpiresIn: Int64;
    RefreshToken: string;
  end;

  TUserRow = record
    Id: string;
    Email: string;
    PasswordHash: string;
    Role: string;
    Active: Boolean;
  end;

  TAuthService = class
  private
    FCatalog: ITenantCatalog;
    FResolver: ITenantDataResolver;
    FSign: TSignClaimsFunc;
    FOptions: TAuthOptions;
    FRefresh: TRefreshTokens;
    FDummyHash: string;
    function Tokens(const ATenant: TTenantInfo; const AUser: TUserRow;
      const ARefreshToken: string): TAuthTokens;
    function AccessToken(const ATenant: TTenantInfo; const AUser: TUserRow): string;
    /// TRefreshTokens' user check: the user still exists and is active.
    function UserActive(const AScope, AUserId: string): Boolean;
  public
    /// Computes the dummy hash (one PBKDF2 at startup). ARefreshStore keeps
    /// the refresh tokens (TDbRefreshTokenStore on the REFRESH.* SQL).
    constructor Create(const ACatalog: ITenantCatalog; const AResolver: ITenantDataResolver;
      const ASign: TSignClaimsFunc; const AOptions: TAuthOptions;
      const ARefreshStore: IRefreshTokenStore; const AOnSecurity: TPcLogProc = nil);
    destructor Destroy; override;
    function Login(const ATenant, AEmail, APassword: string): TAuthTokens;
    function Refresh(const ARefreshToken: string): TAuthTokens;
    /// Revokes the token's family; nothing (and no error) for anything else.
    procedure Logout(const ARefreshToken: string);
    /// The user of a verified access token; False when gone or inactive.
    function FindUser(const ATenant: TTenantInfo; const AUserId: string;
      out AUser: TUserRow): Boolean;
  end;

/// Trimmed and lower-cased (ASCII); '' when it can't be an address.
function NormalizeEmail(const AEmail: string): string;

/// Provisioning (the command line): a tenant in the catalog. EArgumentException
/// for an id that isn't a tenant id, or an empty name or time zone.
procedure CreateTenant(const AFactory: IDBFactory; const AId, AName, ATimeZone: string);

/// A user of ATenant (in the catalog); returns its id. EArgumentException for
/// a bad email or role; Agenda.Passwords' EPasswordError for a bad password.
function CreateUser(const ACatalog: ITenantCatalog; const AResolver: ITenantDataResolver;
  const ATenant, AEmail, ARole, APassword: string; AIterations: Integer): string;

implementation

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalApi.Jwt,
  PascalApi.Http,
  Agenda.Passwords,
  Agenda.Tokens;

const
  MSG_INVALID_CREDENTIALS = 'Invalid email or password.';
  MSG_INVALID_REFRESH_TOKEN = 'Invalid or expired refresh token.';

function InvalidCredentials: EHttpException;
begin
  Result := EUnauthorizedException.Create(MSG_INVALID_CREDENTIALS, CODE_INVALID_CREDENTIALS);
end;

function InvalidRefreshToken: EHttpException;
begin
  Result := EUnauthorizedException.Create(MSG_INVALID_REFRESH_TOKEN, CODE_INVALID_REFRESH_TOKEN);
end;

function TenantSuspended: EHttpException;
begin
  Result := EHttpException.Create(403, TApiMessages.Current.TenantSuspended,
    CODE_TENANT_SUSPENDED);
end;

{ TAuthOptions }

class function TAuthOptions.Default: TAuthOptions;
begin
  Result.AccessSeconds := 900;
  Result.RefreshSeconds := 30 * 86400;
  Result.PasswordIterations := DEFAULT_PASSWORD_ITERATIONS;
end;

{ helpers }

function NormalizeEmail(const AEmail: string): string;
var
  P: Integer;
begin
  Result := LowerCase(Trim(AEmail));
  P := Pos('@', Result);
  if (P < 2) or (P = Length(Result)) or (Length(Result) > 254) or
    (Pos('@', Copy(Result, P + 1, MaxInt)) > 0) or (Pos(' ', Result) > 0) then
    Result := '';
end;

function ReadUser(const AResult: IQueryResult): TUserRow;
begin
  Result.Id := AResult.Strings['ID'];
  Result.Email := AResult.Strings['EMAIL'];
  Result.PasswordHash := AResult.Strings['PASSWORD_HASH'];
  Result.Role := AResult.Strings['ROLE'];
  Result.Active := AResult.Integers['ACTIVE'] <> 0;
end;

function FindUserBy(const AScope: TTenantDataScope; const ASqlName, AParam, AValue: string;
  out AUser: TUserRow): Boolean;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, AScope, ASqlName);
  LQuery.Params.Strings[AParam] := AValue;
  LResult := LQuery.Open;
  Result := not LResult.Eof;
  if Result then
    AUser := ReadUser(LResult);
end;

{ TAuthService }

constructor TAuthService.Create(const ACatalog: ITenantCatalog;
  const AResolver: ITenantDataResolver; const ASign: TSignClaimsFunc;
  const AOptions: TAuthOptions; const ARefreshStore: IRefreshTokenStore;
  const AOnSecurity: TPcLogProc);
begin
  inherited Create;
  FCatalog := ACatalog;
  FResolver := AResolver;
  FSign := ASign;
  FOptions := AOptions;
  FRefresh := TRefreshTokens.Create(ARefreshStore, AOptions.RefreshSeconds, AOnSecurity);
  FDummyHash := TPasswords.Hash(NewId, FOptions.PasswordIterations);
end;

destructor TAuthService.Destroy;
begin
  FRefresh.Free;
  inherited;
end;

function TAuthService.AccessToken(const ATenant: TTenantInfo; const AUser: TUserRow): string;
var
  LWriter: TJsonWriter;
  LNow: Int64;
begin
  LNow := TJwt.UnixNow;
  LWriter := TJsonWriter.Create;
  try
    LWriter.BeginObject;
    LWriter.Name('sub');
    LWriter.WriteString(AUser.Id);
    LWriter.Name(TENANT_DEFAULT_CLAIM);
    LWriter.WriteString(ATenant.Id);
    LWriter.Name('role');
    LWriter.WriteString(AUser.Role);
    LWriter.Name('iat');
    LWriter.WriteInt64(LNow);
    LWriter.Name('exp');
    LWriter.WriteInt64(LNow + FOptions.AccessSeconds);
    LWriter.EndObject;
    Result := FSign(LWriter.ToString);
  finally
    LWriter.Free;
  end;
end;

function TAuthService.Tokens(const ATenant: TTenantInfo; const AUser: TUserRow;
  const ARefreshToken: string): TAuthTokens;
begin
  Result.RefreshToken := ARefreshToken;
  Result.AccessToken := AccessToken(ATenant, AUser);
  Result.ExpiresIn := FOptions.AccessSeconds;
end;

function TAuthService.UserActive(const AScope, AUserId: string): Boolean;
var
  LInfo: TTenantInfo;
  LUser: TUserRow;
begin
  Result := FCatalog.Find(AScope, LInfo) and FindUser(LInfo, AUserId, LUser);
end;

function TAuthService.Login(const ATenant, AEmail, APassword: string): TAuthTokens;
var
  LInfo: TTenantInfo;
  LCheck: TTenantCheck;
  LScope: TTenantDataScope;
  LEmail, LNewHash: string;
  LUser: TUserRow;
  LFound, LOk: Boolean;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LEmail := NormalizeEmail(AEmail);
  if IsTenantId(ATenant) then
    LCheck := CheckTenant(FCatalog, ATenant, LInfo)
  else
    LCheck := tcUnknown;
  LFound := False;
  if (LEmail <> '') and (LCheck in [tcOk, tcSuspended]) then
  begin
    LScope := FResolver.ScopeFor(LInfo);
    LFound := FindUserBy(LScope, 'USER.BY_EMAIL', 'EMAIL', LEmail, LUser) and LUser.Active;
  end;
  // The same work whatever failed: the answer's time says nothing.
  if LFound then
    LOk := TPasswords.Verify(APassword, LUser.PasswordHash)
  else
  begin
    TPasswords.Verify(APassword, FDummyHash);
    LOk := False;
  end;
  if not LOk then
    raise InvalidCredentials;
  if LCheck = tcSuspended then
    raise TenantSuspended;

  // A weaker stored hash is replaced while the password is at hand; hashed
  // before the transaction, so it holds no connection for 0.3 s.
  if TPasswords.NeedsRehash(LUser.PasswordHash, FOptions.PasswordIterations) then
  begin
    LNewHash := TPasswords.Hash(APassword, FOptions.PasswordIterations);
    LTx := LScope.Factory.GetPool.AcquireQuery(LQuery);
    LTx.StartTransaction;
    try
      TTenantFilter.Prepare(LQuery, LScope, 'USER.SET_PASSWORD_HASH');
      LQuery.Params.Strings['PASSWORD_HASH'] := LNewHash;
      LQuery.Params.Strings['ID'] := LUser.Id;
      LQuery.ExecSql;
      LTx.Commit;
    except
      LTx.Rollback;
      raise;
    end;
  end;
  Result := Tokens(LInfo, LUser, FRefresh.Issue(LInfo.Id, LUser.Id));
end;

function TAuthService.Refresh(const ARefreshToken: string): TAuthTokens;
var
  LTenant: string;
  LInfo: TTenantInfo;
  LNext: TRotatedRefreshToken;
  LUser: TUserRow;
begin
  // The tenant is in the token, in clear: checked against the catalog before
  // any lookup. Every token here names one (no scope '').
  if not TRefreshTokens.TryParse(ARefreshToken, LTenant) or not IsTenantId(LTenant) then
    raise InvalidRefreshToken;
  case CheckTenant(FCatalog, LTenant, LInfo) of
    tcOk: ;
    tcSuspended:
      raise TenantSuspended;
  else
    raise InvalidRefreshToken;
  end;
  try
    LNext := FRefresh.Rotate(ARefreshToken, UserActive);
  except
    on E: ERefreshTokenRejected do
      raise InvalidRefreshToken; // one answer, whatever the reason
  end;
  if not FindUser(LInfo, LNext.UserId, LUser) then
    raise InvalidRefreshToken; // removed between the check and here
  Result := Tokens(LInfo, LUser, LNext.Token);
end;

procedure TAuthService.Logout(const ARefreshToken: string);
var
  LTenant: string;
  LInfo: TTenantInfo;
begin
  if not TRefreshTokens.TryParse(ARefreshToken, LTenant) or not IsTenantId(LTenant) then
    Exit;
  if CheckTenant(FCatalog, LTenant, LInfo) in [tcOk, tcSuspended] then
    FRefresh.Revoke(ARefreshToken);
end;

function TAuthService.FindUser(const ATenant: TTenantInfo; const AUserId: string;
  out AUser: TUserRow): Boolean;
begin
  Result := FindUserBy(FResolver.ScopeFor(ATenant), 'USER.BY_ID', 'ID', AUserId, AUser) and
    AUser.Active;
end;

{ provisioning }

procedure CreateTenant(const AFactory: IDBFactory; const AId, AName, ATimeZone: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  if not IsTenantId(AId) then
    raise EArgumentException.CreateFmt('"%s" is not a tenant id (1-40 of a-z, 0-9, -).', [AId]);
  if (Trim(AName) = '') or (Trim(ATimeZone) = '') then
    raise EArgumentException.Create('A tenant needs a name and a time zone.');
  LTx := AFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := AFactory.SqlLoader['TENANT.INSERT'].SQL;
    LQuery.Params.Strings['ID'] := AId;
    LQuery.Params.Strings['NAME'] := Trim(AName);
    LQuery.Params.Strings['TIME_ZONE'] := Trim(ATimeZone);
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

function CreateUser(const ACatalog: ITenantCatalog; const AResolver: ITenantDataResolver;
  const ATenant, AEmail, ARole, APassword: string; AIterations: Integer): string;
var
  LInfo: TTenantInfo;
  LEmail, LHash: string;
  LScope: TTenantDataScope;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  if not ACatalog.Find(ATenant, LInfo) then
    raise EArgumentException.CreateFmt('No tenant "%s".', [ATenant]);
  LEmail := NormalizeEmail(AEmail);
  if LEmail = '' then
    raise EArgumentException.CreateFmt('"%s" is not an email address.', [AEmail]);
  if (ARole <> ROLE_OWNER) and (ARole <> ROLE_STAFF) then
    raise EArgumentException.CreateFmt('Role "%s": owner or staff.', [ARole]);
  Result := NewId;
  LScope := AResolver.ScopeFor(LInfo);
  LHash := TPasswords.Hash(APassword, AIterations);
  LTx := LScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, LScope, 'USER.INSERT');
    LQuery.Params.Strings['ID'] := Result;
    LQuery.Params.Strings['EMAIL'] := LEmail;
    LQuery.Params.Strings['PASSWORD_HASH'] := LHash;
    LQuery.Params.Strings['ROLE'] := ARole;
    LQuery.Params.OptNullStrings['PROFESSIONAL_ID'] := TOptNullString.Null;
    LQuery.Params.Int64s['CREATED_AT'] := TJwt.UnixNow;
    LQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

end.
