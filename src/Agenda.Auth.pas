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
  sub = the user's id, tenant_id, role, iat, exp) and a refresh token
  (Agenda.Tokens: "<tenant>.<secret>", only its SHA-256 stored), valid
  RefreshSeconds. Each refresh token is used once: a refresh marks it used
  and issues the next one in the same family. A token used twice means it
  was copied: the whole family is revoked, the legitimate holder included,
  and AOnSecurity hears of it. Two refreshes racing on one token are the
  same case (only the first UPDATE matches; measured by the HTTP
  scenarios). Logout revokes the family; it answers the same for any token.

  Every query on a tenant's rows goes through TTenantFilter.Prepare
  (pascal-api-infra-faa's rule): the tenant comes from the catalog first. }

interface

uses
  SysUtils,
  PascalCommon.Tracing,
  PascalDb.Interfaces,
  PascalApi.Tenancy;

const
  ROLE_OWNER = 'owner';
  ROLE_STAFF = 'staff';
  CODE_INVALID_CREDENTIALS = 'invalid_credentials';
  CODE_INVALID_REFRESH_TOKEN = 'invalid_refresh_token';
  CODE_TENANT_SUSPENDED = 'tenant_suspended';

type
  /// A refusal the routes answer as {"error": Message, "code": Code}.
  EAuthError = class(Exception)
  private
    FStatus: Integer;
    FCode: string;
  public
    constructor Create(AStatus: Integer; const ACode, AMessage: string);
    property Status: Integer read FStatus;
    property Code: string read FCode;
  end;

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
    FOnSecurity: TPcLogProc;
    FDummyHash: string;
    function Issue(const ATenant: TTenantInfo; const AUser: TUserRow;
      const AQuery: IQuery; const AFamily: string): TAuthTokens;
    function AccessToken(const ATenant: TTenantInfo; const AUser: TUserRow): string;
    procedure RevokeFamily(const AScope: TTenantDataScope; const AFamily, AReason: string);
    procedure Security(const ALine: string);
  public
    /// Computes the dummy hash (one PBKDF2 at startup).
    constructor Create(const ACatalog: ITenantCatalog; const AResolver: ITenantDataResolver;
      const ASign: TSignClaimsFunc; const AOptions: TAuthOptions;
      const AOnSecurity: TPcLogProc = nil);
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
  PascalJsonMapper.Json,
  PascalApi.Jwt,
  PascalApi.Http,
  Agenda.Passwords,
  Agenda.Tokens;

const
  MSG_INVALID_CREDENTIALS = 'Invalid email or password.';
  MSG_INVALID_REFRESH_TOKEN = 'Invalid or expired refresh token.';

{ EAuthError }

constructor EAuthError.Create(AStatus: Integer; const ACode, AMessage: string);
begin
  inherited Create(AMessage);
  FStatus := AStatus;
  FCode := ACode;
end;

function InvalidCredentials: EAuthError;
begin
  Result := EAuthError.Create(401, CODE_INVALID_CREDENTIALS, MSG_INVALID_CREDENTIALS);
end;

function InvalidRefreshToken: EAuthError;
begin
  Result := EAuthError.Create(401, CODE_INVALID_REFRESH_TOKEN, MSG_INVALID_REFRESH_TOKEN);
end;

function TenantSuspended: EAuthError;
begin
  Result := EAuthError.Create(403, CODE_TENANT_SUSPENDED, TApiMessages.Current.TenantSuspended);
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
  const AOptions: TAuthOptions; const AOnSecurity: TPcLogProc);
begin
  inherited Create;
  FCatalog := ACatalog;
  FResolver := AResolver;
  FSign := ASign;
  FOptions := AOptions;
  FOnSecurity := AOnSecurity;
  FDummyHash := TPasswords.Hash(NewId, FOptions.PasswordIterations);
end;

procedure TAuthService.Security(const ALine: string);
begin
  if Assigned(FOnSecurity) then
    FOnSecurity(ALine);
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

// The access token and a new refresh token in AFamily, inserted through
// AQuery (the caller's transaction).
function TAuthService.Issue(const ATenant: TTenantInfo; const AUser: TUserRow;
  const AQuery: IQuery; const AFamily: string): TAuthTokens;
var
  LScope: TTenantDataScope;
  LNow: Int64;
begin
  LScope := FResolver.ScopeFor(ATenant);
  LNow := TJwt.UnixNow;
  Result.RefreshToken := NewRefreshToken(ATenant.Id);
  TTenantFilter.Prepare(AQuery, LScope, 'REFRESH.INSERT');
  AQuery.Params.Strings['ID'] := NewId;
  AQuery.Params.Strings['TOKEN_HASH'] := RefreshTokenHash(Result.RefreshToken);
  AQuery.Params.Strings['USER_ID'] := AUser.Id;
  AQuery.Params.Strings['FAMILY_ID'] := AFamily;
  AQuery.Params.Int64s['CREATED_AT'] := LNow;
  AQuery.Params.Int64s['EXPIRES_AT'] := LNow + FOptions.RefreshSeconds;
  AQuery.ExecSql;
  Result.AccessToken := AccessToken(ATenant, AUser);
  Result.ExpiresIn := FOptions.AccessSeconds;
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

  // Hashed before the transaction: it holds no connection for 0.3 s.
  LNewHash := '';
  if TPasswords.NeedsRehash(LUser.PasswordHash, FOptions.PasswordIterations) then
    LNewHash := TPasswords.Hash(APassword, FOptions.PasswordIterations);
  LTx := LScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    if LNewHash <> '' then
    begin
      TTenantFilter.Prepare(LQuery, LScope, 'USER.SET_PASSWORD_HASH');
      LQuery.Params.Strings['PASSWORD_HASH'] := LNewHash;
      LQuery.Params.Strings['ID'] := LUser.Id;
      LQuery.ExecSql;
    end;
    Result := Issue(LInfo, LUser, LQuery, NewId);
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TAuthService.RevokeFamily(const AScope: TTenantDataScope; const AFamily, AReason: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LCount: Int64;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, AScope, 'REFRESH.REVOKE_FAMILY');
    LQuery.Params.Int64s['REVOKED_AT'] := TJwt.UnixNow;
    LQuery.Params.Strings['FAMILY_ID'] := AFamily;
    LCount := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if (LCount > 0) and (AReason <> '') then
    Security(Format('refresh token family %s of tenant %s revoked: %s',
      [AFamily, AScope.Discriminator, AReason]));
end;

function TAuthService.Refresh(const ARefreshToken: string): TAuthTokens;
var
  LTenant, LId, LUserId, LFamily: string;
  LInfo: TTenantInfo;
  LScope: TTenantDataScope;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LUsed, LRevoked: Boolean;
  LExpires: Int64;
  LUser: TUserRow;
begin
  if not TryParseRefreshToken(ARefreshToken, LTenant) then
    raise InvalidRefreshToken;
  case CheckTenant(FCatalog, LTenant, LInfo) of
    tcOk: ;
    tcSuspended:
      raise TenantSuspended;
  else
    raise InvalidRefreshToken;
  end;
  LScope := FResolver.ScopeFor(LInfo);

  LTx := LScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, LScope, 'REFRESH.BY_HASH');
  LQuery.Params.Strings['TOKEN_HASH'] := RefreshTokenHash(ARefreshToken);
  LResult := LQuery.Open;
  if LResult.Eof then
    raise InvalidRefreshToken;
  LId := LResult.Strings['ID'];
  LUserId := LResult.Strings['USER_ID'];
  LFamily := LResult.Strings['FAMILY_ID'];
  LExpires := LResult.Int64s['EXPIRES_AT'];
  LUsed := not LResult.NullableInt64['USED_AT'].IsNull;
  LRevoked := not LResult.NullableInt64['REVOKED_AT'].IsNull;
  LResult := nil;
  LTx := nil;
  LQuery := nil;

  if LRevoked then
    raise InvalidRefreshToken;
  if LUsed then
  begin
    RevokeFamily(LScope, LFamily, 'a used refresh token came back (copied?)');
    raise InvalidRefreshToken;
  end;
  if LExpires <= TJwt.UnixNow then
    raise InvalidRefreshToken;
  if not FindUser(LInfo, LUserId, LUser) then
  begin
    RevokeFamily(LScope, LFamily, 'the user is gone or inactive');
    raise InvalidRefreshToken;
  end;

  LTx := LScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, LScope, 'REFRESH.MARK_USED');
    LQuery.Params.Int64s['USED_AT'] := TJwt.UnixNow;
    LQuery.Params.Strings['ID'] := LId;
    if LQuery.ExecSql <> 1 then
    begin
      // Another request used it between the read and here.
      LTx.Rollback;
      RevokeFamily(LScope, LFamily, 'two refreshes raced on one token');
      raise InvalidRefreshToken;
    end;
    Result := Issue(LInfo, LUser, LQuery, LFamily);
    LTx.Commit;
  except
    on E: EAuthError do
      raise;
    on E: Exception do
    begin
      LTx.Rollback;
      raise;
    end;
  end;
end;

procedure TAuthService.Logout(const ARefreshToken: string);
var
  LTenant, LFamily: string;
  LInfo: TTenantInfo;
  LScope: TTenantDataScope;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  if not TryParseRefreshToken(ARefreshToken, LTenant) then
    Exit;
  if not (CheckTenant(FCatalog, LTenant, LInfo) in [tcOk, tcSuspended]) then
    Exit;
  LScope := FResolver.ScopeFor(LInfo);
  LTx := LScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, LScope, 'REFRESH.BY_HASH');
  LQuery.Params.Strings['TOKEN_HASH'] := RefreshTokenHash(ARefreshToken);
  LResult := LQuery.Open;
  if LResult.Eof then
    Exit;
  LFamily := LResult.Strings['FAMILY_ID'];
  LResult := nil;
  LTx := nil;
  LQuery := nil;
  RevokeFamily(LScope, LFamily, '');
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
    LQuery.Params.Int64s['CREATED_AT'] := TJwt.UnixNow;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

end.
