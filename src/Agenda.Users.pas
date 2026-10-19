unit Agenda.Users;

{$I agenda.inc}

(* A tenant's users, managed by its owner: DTOs, the ordering clients may
  ask for, and a repository on a tenant's scope. Logging in is Agenda.Auth's;
  the first owner comes from the command line (--create-user).

  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag).
  - The email is unique within the tenant (UQ_USERS_EMAIL: 409), lower case.
  - The owner sets the first password (at least MIN_PASSWORD_CHARS
    characters) and may replace it; the hash is never read back out. A new
    password, or the user deactivated, revokes the user's refresh tokens:
    every session ends (the access token lasts until it expires).
  - A user may be one of the tenant's professionals (professionalId), and a
    professional at most one user (UQ_USERS_PROFESSIONAL: 409). The
    professional must exist in the tenant (400 otherwise); deleting it
    unlinks the user (Agenda.Professionals).
  - The acting owner can't change their own role, deactivate themselves or
    delete themselves (409 "own_account"): so the tenant always keeps an
    active owner. Two owners demoting each other at the same moment could
    still leave none; noted in docs/design.md.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalCommon.Validators,
  PascalDb.Paging,
  PascalApi.OrderBy,
  PascalApi.Dto,
  PascalApi.Tenancy;

const
  MIN_PASSWORD_CHARS = 8;
  CODE_OWN_ACCOUNT = 'own_account';

type
  IUserInsert = interface(IInsertDTOBase)
    ['{2B638832-41BF-4A05-ACD1-DF51DE3C21DA}']
    function GetEmail: string;
    function GetPassword: string;
    function GetRole: string;
    function GetProfessionalId: IOptString;
    property Email: string read GetEmail;
    property Password: string read GetPassword;
    property Role: string read GetRole;
    property ProfessionalId: IOptString read GetProfessionalId;
  end;

  /// PATCH: absent leaves a member; null unlinks the professional.
  IUserPatch = interface(IUpdateDTOBase)
    ['{8DF5B547-EB00-418B-AB44-B945AC158C19}']
    function GetEmail: IOptString;
    function GetPassword: IOptString;
    function GetRole: IOptString;
    function GetActive: IOptBoolean;
    function GetProfessionalId: IOptNullString;
    property Email: IOptString read GetEmail;
    property Password: IOptString read GetPassword;
    property Role: IOptString read GetRole;
    property Active: IOptBoolean read GetActive;
    property ProfessionalId: IOptNullString read GetProfessionalId;
  end;

  IUser = interface(IResponseDTOBase)
    ['{6CB0E268-84B1-444E-BB3C-FD826465D118}']
    function GetId: string;
    function GetEmail: string;
    function GetRole: string;
    function GetActive: Boolean;
    function GetProfessionalId: INullString;
    property Id: string read GetId;
    property Email: string read GetEmail;
    property Role: string read GetRole;
    property Active: Boolean read GetActive;
    property ProfessionalId: INullString read GetProfessionalId;
  end;

  /// GET /users: page, limit, orderBy, search (in the email), role, active.
  IUserFind = interface(IFindPaginationDTOBase)
    ['{FF7793BB-5B4B-4CF1-A2D4-81F34B4D71DF}']
    function GetRole: IOptString;
    function GetActive: IOptBoolean;
    property Role: IOptString read GetRole;
    property Active: IOptBoolean read GetActive;
  end;

{$M+}
  TUserInsert = class(TInsertDTOBase, IUserInsert)
  private
    FEmail, FPassword, FRole: string;
    FProfessionalId: IOptString;
  public
    function GetEmail: string;
    function GetPassword: string;
    function GetRole: string;
    function GetProfessionalId: IOptString;
  published
    property Email: string read FEmail write FEmail;
    property Password: string read FPassword write FPassword;
    property Role: string read FRole write FRole;
    property ProfessionalId: IOptString read FProfessionalId write FProfessionalId;
  end;

  TUserPatch = class(TUpdateDTOBase, IUserPatch)
  private
    FEmail, FPassword, FRole: IOptString;
    FActive: IOptBoolean;
    FProfessionalId: IOptNullString;
  public
    function GetEmail: IOptString;
    function GetPassword: IOptString;
    function GetRole: IOptString;
    function GetActive: IOptBoolean;
    function GetProfessionalId: IOptNullString;
  published
    property Email: IOptString read FEmail write FEmail;
    property Password: IOptString read FPassword write FPassword;
    property Role: IOptString read FRole write FRole;
    property Active: IOptBoolean read FActive write FActive;
    property ProfessionalId: IOptNullString read FProfessionalId write FProfessionalId;
  end;

  TUser = class(TResponseDTOBase, IUser)
  private
    FId, FEmail, FRole: string;
    FActive: Boolean;
    FProfessionalId: INullString;
  public
    function GetId: string;
    function GetEmail: string;
    function GetRole: string;
    function GetActive: Boolean;
    function GetProfessionalId: INullString;
  published
    property Id: string read FId write FId;
    property Email: string read FEmail write FEmail;
    property Role: string read FRole write FRole;
    property Active: Boolean read FActive write FActive;
    property ProfessionalId: INullString read FProfessionalId write FProfessionalId;
  end;

  TUserFind = class(TFindPaginationDTOBase, IUserFind)
  private
    FRole: IOptString;
    FActive: IOptBoolean;
  public
    function GetRole: IOptString;
    function GetActive: IOptBoolean;
  published
    property Role: IOptString read FRole write FRole;
    property Active: IOptBoolean read FActive write FActive;
  end;
{$M-}

  TUserArray = TArray<IUser>;

  TUserRepository = class
  private
    FScope: TTenantDataScope;
    FIterations: Integer;
    /// Adds a failure to ACheck unless the tenant has the professional (when
    /// it came with a value): a rule that needs the scope, so a method.
    procedure CheckProfessional(const AId: IOptString; var ACheck: TPcValidation); overload;
    procedure CheckProfessional(const AId: IOptNullString; var ACheck: TPcValidation); overload;
  public
    /// AIterations: PBKDF2's, for the passwords this repository hashes.
    constructor Create(const AScope: TTenantDataScope; AIterations: Integer);
    /// EOrderByException for a field not allowed (400).
    function FindPage(const AFind: IUserFind; const APage: TPageRequest): TPage<IUser>;
    /// ENotFoundException when the tenant has none with this id.
    function FindById(const AId: string): IUser;
    /// EValidationException for invalid data; 409 for an email or a
    /// professional another user has.
    function Insert(const AUser: IUserInsert): IUser;
    /// AActorId: the owner making the change (the token's sub).
    function Update(const AActorId, AId: string; const APatch: IUserPatch): IUser;
    procedure Delete(const AActorId, AId: string);
  end;

function UserOrderSpec: TOrderBySpec;

implementation

uses
  SysUtils,
  PascalCommon.Normalizers,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.Jwt,
  PascalApi.PagedQuery,
  Agenda.Auth,
  Agenda.Passwords,
  Agenda.Normalizers,
  Agenda.Validators,
  Agenda.Flags,
  Agenda.Tokens;

function UserOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('email', 'EMAIL')
    .Allow('createdAt', 'CREATED_AT')
    .Default('email')
    .AlwaysLast('ID');
end;

{ DTOs }

function TUserInsert.GetEmail: string;
begin
  Result := FEmail;
end;

function TUserInsert.GetPassword: string;
begin
  Result := FPassword;
end;

function TUserInsert.GetRole: string;
begin
  Result := FRole;
end;

function TUserInsert.GetProfessionalId: IOptString;
begin
  Result := TOptionals.Safe(FProfessionalId);
end;

function TUserPatch.GetEmail: IOptString;
begin
  Result := TOptionals.Safe(FEmail);
end;

function TUserPatch.GetPassword: IOptString;
begin
  Result := TOptionals.Safe(FPassword);
end;

function TUserPatch.GetRole: IOptString;
begin
  Result := TOptionals.Safe(FRole);
end;

function TUserPatch.GetActive: IOptBoolean;
begin
  Result := TOptionals.Safe(FActive);
end;

function TUserPatch.GetProfessionalId: IOptNullString;
begin
  Result := TOptionals.Safe(FProfessionalId);
end;

function TUser.GetId: string;
begin
  Result := FId;
end;

function TUser.GetEmail: string;
begin
  Result := FEmail;
end;

function TUser.GetRole: string;
begin
  Result := FRole;
end;

function TUser.GetActive: Boolean;
begin
  Result := FActive;
end;

function TUser.GetProfessionalId: INullString;
begin
  Result := TOptionals.Safe(FProfessionalId);
end;

function TUserFind.GetRole: IOptString;
begin
  Result := TOptionals.Safe(FRole);
end;

function TUserFind.GetActive: IOptBoolean;
begin
  Result := TOptionals.Safe(FActive);
end;

{ validation }

// The stored hash of a password the edge accepted (the document's MinLength).
function HashPassword(const APassword: string; AIterations: Integer): string;
begin
  try
    Result := TPasswords.Hash(APassword, AIterations);
  except
    on E: EPasswordError do
      raise EValidationException.Create('"password": ' + E.Message);
  end;
end;

type
  /// A password -> its stored hash, as a normalizer object: a transformation
  /// that needs the iterations, taken by an optional with Normalize (called
  /// only when the member came).
  THashPassword = class(TInterfacedObject, IPcStringNormalizer)
  private
    FIterations: Integer;
  public
    constructor Create(AIterations: Integer);
    function Apply(const AValue: string): string;
  end;

constructor THashPassword.Create(AIterations: Integer);
begin
  inherited Create;
  FIterations := AIterations;
end;

function THashPassword.Apply(const AValue: string): string;
begin
  Result := HashPassword(AValue, FIterations);
end;

function OwnAccount: EConflictException;
begin
  Result := EConflictException.Create('You can''t change your own role, deactivate or ' +
    'delete your own account.', CODE_OWN_ACCOUNT);
end;

{ TUserRepository }

constructor TUserRepository.Create(const AScope: TTenantDataScope; AIterations: Integer);
begin
  inherited Create;
  FScope := AScope;
  FIterations := AIterations;
end;

function ReadUserDto(const AResult: IQueryResult): IUser;
var
  LUser: TUser;
begin
  LUser := TUser.Create;
  Result := LUser;
  LUser.Id := AResult.Strings['ID'];
  LUser.Email := AResult.Strings['EMAIL'];
  LUser.Role := AResult.Strings['ROLE'];
  LUser.Active := AResult.Integers['ACTIVE'] <> 0;
  LUser.ProfessionalId := AResult.NullableStrings['PROFESSIONAL_ID'];
end;

function HasSearch(const AFind: IUserFind): Boolean;
begin
  Result := AFind.Search.HasValue and (Trim(AFind.Search.Value) <> '');
end;

function Filtered(const ASql: TSQLResult; const AFind: IUserFind): TSQLResult;
begin
  Result := ASql.ProcessTag('SEARCH', HasSearch(AFind))
    .ProcessTag('ROLE', AFind.Role.HasValue)
    .ProcessTag('ACTIVE', AFind.Active.HasValue);
end;

function FilterArgs(const AFind: IUserFind): TQueryArgs;
begin
  Result := TQueryArgs.New;
  // Emails are stored lower case (ASCII): the search is too.
  if HasSearch(AFind) then
    Result := Result.Strings('SEARCH', PdbLikeContains(LowerCase(Trim(AFind.Search.Value))));
  if AFind.Role.HasValue then
    Result := Result.Strings('ROLE', AFind.Role.Value);
  if AFind.Active.HasValue then
    Result := Result.Integers('ACTIVE', FlagOf(AFind.Active.Value));
end;

function TUserRepository.FindPage(const AFind: IUserFind;
  const APage: TPageRequest): TPage<IUser>;
var
  LOrder: string;
begin
  LOrder := UserOrderSpec.Build(AFind.OrderBy.ValueOr(''));
  Result := TTenantPagedQuery.Run<IUser>(FScope,
    Filtered(FScope.Factory.SqlLoader['USER.COUNT'], AFind),
    Filtered(FScope.Factory.SqlLoader['USER.PAGE'], AFind), LOrder, APage, FilterArgs(AFind),
    ReadUserDto);
end;

function TUserRepository.FindById(const AId: string): IUser;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'USER.VIEW');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if not LResult.Eof then
    Result := ReadUserDto(LResult);
  if Result = nil then
    raise ENotFoundException.Create('User not found.');
end;

procedure TUserRepository.CheckProfessional(const AId: IOptString; var ACheck: TPcValidation);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  if not AId.HasValue then
    Exit;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.BY_ID');
  LQuery.Params.Strings['ID'] := AId.Value;
  if LQuery.Open.Eof then
    ACheck.Fail('professionalId', 'unknown_professional',
      '"professionalId": the tenant has no such professional.');
end;

procedure TUserRepository.CheckProfessional(const AId: IOptNullString;
  var ACheck: TPcValidation);
var
  LId: IOptString;
begin
  if AId.HasValue and not AId.IsNull then
  begin
    // A variable, not From(...) in the call: From answers the class, which
    // fits both overloads.
    LId := TOptNullString.From(AId.Value);
    CheckProfessional(LId, ACheck);
  end;
end;

function TUserRepository.Insert(const AUser: IUserInsert): IUser;
var
  LEmail, LHash, LId: string;
  LCheck: TPcValidation;
  LNow: Int64;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  // Normalized (Agenda.Normalizers), then checked: a 400 touches nothing.
  LEmail := TNorm.Email.Apply(AUser.Email);
  // The role and the password's length are the document's (Enum, MinLength),
  // enforced at the edge.
  LCheck := TPcValidation.Create;
  LCheck.Check('email', LEmail, TValid.Email);
  CheckProfessional(AUser.ProfessionalId, LCheck);
  LCheck.RaiseIfAny;
  // Hashed before the transaction: it holds no connection while it works.
  LHash := HashPassword(AUser.Password, FIterations);
  LId := NewId;
  LNow := TJwt.UnixNow;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // PROFESSIONAL_ID only when it came; absent, the database writes NULL.
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['USER.INSERT']
      .ProcessTag('PROFESSIONAL', AUser.ProfessionalId.HasValue));
    LQuery.Params.Strings['ID'] := LId;
    LQuery.Params.Strings['EMAIL'] := LEmail;
    LQuery.Params.Strings['PASSWORD_HASH'] := LHash;
    LQuery.Params.Strings['ROLE'] := AUser.Role;
    LQuery.Params.OptStrings['PROFESSIONAL_ID'] := AUser.ProfessionalId;
    LQuery.Params.Int64s['CREATED_AT'] := LNow;
    LQuery.Params.Int64s['UPDATED_AT'] := LNow;
    LQuery.ExecSql; // the email or the professional taken: 409
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  Result := FindById(LId);
end;

function TUserRepository.Update(const AActorId, AId: string; const APatch: IUserPatch): IUser;
var
  LEmail, LHash: IOptString;
  LCheck: TPcValidation;
  LDeactivate: Boolean;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  // Normalized inside the optionals, then checked, for the members that came:
  // a 400 touches nothing.
  LEmail := TOptionals.Normalize(APatch.Email, TNorm.Email);
  LCheck := TPcValidation.Create;
  LCheck.Check('email', LEmail, TValid.Email);
  CheckProfessional(APatch.ProfessionalId, LCheck);
  LCheck.RaiseIfAny;
  LDeactivate := APatch.Active.HasValue and not APatch.Active.Value;
  // The actor is an owner (the route checks it): keeping the role is fine.
  if (AId = AActorId) and (LDeactivate or (APatch.Role.ValueOr(ROLE_OWNER) <> ROLE_OWNER)) then
    raise OwnAccount;
  // Hashed here, before the transaction holds a connection.
  LHash := TOptionals.Normalize(APatch.Password, THashPassword.Create(FIterations));

  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['USER.UPDATE']
      .ProcessTag('EMAIL', LEmail.HasValue)
      .ProcessTag('PASSWORD', LHash.HasValue)
      .ProcessTag('ROLE', APatch.Role.HasValue)
      .ProcessTag('ACTIVE', APatch.Active.HasValue)
      .ProcessTag('PROFESSIONAL', APatch.ProfessionalId.HasValue));
    // No if per member: an absent optional binds nothing (its block is gone),
    // a Null binds NULL, a value binds it.
    LQuery.Params.Strings['ID'] := AId;
    LQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
    LQuery.Params.OptStrings['EMAIL'] := LEmail;
    LQuery.Params.OptStrings['PASSWORD_HASH'] := LHash;
    LQuery.Params.OptStrings['ROLE'] := APatch.Role;
    LQuery.Params.OptIntegers['ACTIVE'] := OptFlag(APatch.Active); // an INTEGER column (Agenda.Flags)
    LQuery.Params.OptNullStrings['PROFESSIONAL_ID'] := APatch.ProfessionalId;
    LRows := LQuery.ExecSql; // the email or the professional taken: 409
    // A new password or a deactivation ends every session of the user.
    if (LRows > 0) and (LDeactivate or LHash.HasValue) then
    begin
      TTenantFilter.Prepare(LQuery, FScope, 'REFRESH.REVOKE_USER');
      LQuery.Params.Int64s['REVOKED_AT'] := TJwt.UnixNow;
      LQuery.Params.Strings['USER_ID'] := AId;
      LQuery.ExecSql;
    end;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('User not found.');
  Result := FindById(AId);
end;

procedure TUserRepository.Delete(const AActorId, AId: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  if AId = AActorId then
    raise OwnAccount;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'REFRESH.DELETE_USER');
    LQuery.Params.Strings['USER_ID'] := AId;
    LQuery.ExecSql;
    TTenantFilter.Prepare(LQuery, FScope, 'USER.DELETE');
    LQuery.Params.Strings['ID'] := AId;
    LRows := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('User not found.');
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IUserInsert, TUserInsert>;
  TJsonMapper.Shared.RegisterMapping<IUserPatch, TUserPatch>;
  TJsonMapper.Shared.RegisterMapping<IUser, TUser>;
  TJsonMapper.Shared.RegisterMapping<IUserFind, TUserFind>;
  TApiSchema.Describe(TypeInfo(IUserInsert), 'A new user of the caller''s tenant')
    .Prop('Email').Desc('Unique within the tenant; the login').Example('ana@demo.test')
    .Prop('Password').Desc('At least 8 characters; never returned')
      .Example('a long passphrase').MinLength(MIN_PASSWORD_CHARS)
    .Prop('Role').Desc('owner or staff').Example('staff').Enum([ROLE_OWNER, ROLE_STAFF])
    .Prop('ProfessionalId').Desc('Optional: the professional this user is');
  TApiSchema.Describe(TypeInfo(IUserPatch), 'The members to change; the others stay')
    .Prop('Email').Desc('Unique within the tenant')
    .Prop('Password').Desc('A new password; ends the user''s sessions')
      .MinLength(MIN_PASSWORD_CHARS)
    .Prop('Role').Desc('owner or staff; not your own').Enum([ROLE_OWNER, ROLE_STAFF])
    .Prop('Active').Desc('false: can''t log in, sessions end; not yourself')
    .Prop('ProfessionalId').Desc('null unlinks');
  TApiSchema.Describe(TypeInfo(IUser), 'A user of the caller''s tenant')
    .Prop('Role').Example('staff')
    .Prop('ProfessionalId').Desc('null when the user is no professional');
  TApiSchema.Describe(TypeInfo(IUserFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Users per page (default 20, at most 100)')
    .Prop('OrderBy').Desc(UserOrderSpec.DocHint)
    .Prop('Search').Desc('Part of the email')
    .Prop('Role').Desc('owner or staff').Enum([ROLE_OWNER, ROLE_STAFF])
    .Prop('Active').Desc('true or false');

end.
