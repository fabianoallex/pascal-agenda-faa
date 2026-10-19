unit Agenda.Professionals;

{$I agenda.inc}

(* A tenant's professionals (who is booked): name, an optional email,
  active. DTOs, the ordering clients may ask for, and a repository on a
  tenant's scope; the same shape as Agenda.Services.

  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag).
  - Names aren't unique (two professionals may share one); the search key
    (NAME_KEY, Agenda.Text) serves the search and the ordering.
  - The email: absent on create is no email; on PATCH absent leaves it,
    null clears it (IOptNullString), a value replaces it.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalDb.Interfaces,
  PascalDb.Paging,
  PascalApi.OrderBy,
  PascalApi.Dto,
  PascalApi.Tenancy;

type
  IProfessionalInsert = interface(IInsertDTOBase)
    ['{70887D01-50F7-4B0A-A3ED-22EA9B3B4D71}']
    function GetName: string;
    function GetEmail: IOptString;
    property Name: string read GetName;
    property Email: IOptString read GetEmail;
  end;

  IProfessionalPatch = interface(IUpdateDTOBase)
    ['{78FC1AC4-303F-477B-B582-CE2F896E78E5}']
    function GetName: IOptString;
    function GetEmail: IOptNullString;
    function GetActive: IOptBoolean;
    property Name: IOptString read GetName;
    property Email: IOptNullString read GetEmail;
    property Active: IOptBoolean read GetActive;
  end;

  IProfessional = interface(IResponseDTOBase)
    ['{AAF886A5-D509-4176-AFA1-976DB4DD95F8}']
    function GetId: string;
    function GetName: string;
    function GetEmail: INullString;
    function GetActive: Boolean;
    property Id: string read GetId;
    property Name: string read GetName;
    property Email: INullString read GetEmail;
    property Active: Boolean read GetActive;
  end;

  IProfessionalFind = interface(IFindPaginationDTOBase)
    ['{9331C7F3-0740-445F-9AA0-AC337F1FC9DE}']
    function GetActive: IOptBoolean;
    property Active: IOptBoolean read GetActive;
  end;

{$M+}
  TProfessionalInsert = class(TInsertDTOBase, IProfessionalInsert)
  private
    FName: string;
    FEmail: IOptString;
  public
    function GetName: string;
    function GetEmail: IOptString;
  published
    property Name: string read FName write FName;
    property Email: IOptString read FEmail write FEmail;
  end;

  TProfessionalPatch = class(TUpdateDTOBase, IProfessionalPatch)
  private
    FName: IOptString;
    FEmail: IOptNullString;
    FActive: IOptBoolean;
  public
    function GetName: IOptString;
    function GetEmail: IOptNullString;
    function GetActive: IOptBoolean;
  published
    property Name: IOptString read FName write FName;
    property Email: IOptNullString read FEmail write FEmail;
    property Active: IOptBoolean read FActive write FActive;
  end;

  TProfessional = class(TResponseDTOBase, IProfessional)
  private
    FId, FName: string;
    FEmail: INullString;
    FActive: Boolean;
  public
    function GetId: string;
    function GetName: string;
    function GetEmail: INullString;
    function GetActive: Boolean;
  published
    property Id: string read FId write FId;
    property Name: string read FName write FName;
    property Email: INullString read FEmail write FEmail;
    property Active: Boolean read FActive write FActive;
  end;

  TProfessionalFind = class(TFindPaginationDTOBase, IProfessionalFind)
  private
    FActive: IOptBoolean;
  public
    function GetActive: IOptBoolean;
  published
    property Active: IOptBoolean read FActive write FActive;
  end;
{$M-}

  TProfessionalArray = TArray<IProfessional>;

  TProfessionalRepository = class
  private
    FScope: TTenantDataScope;
  public
    constructor Create(const AScope: TTenantDataScope);
    function FindPage(const AFind: IProfessionalFind;
      const APage: TPageRequest): TPage<IProfessional>;
    function FindById(const AId: string): IProfessional;
    function Insert(const AProfessional: IProfessionalInsert): IProfessional;
    function Update(const AId: string; const APatch: IProfessionalPatch): IProfessional;
    procedure Delete(const AId: string);
  end;

function ProfessionalOrderSpec: TOrderBySpec;

/// Raises ENotFoundException unless the tenant has a professional AId.
procedure RequireProfessional(const AScope: TTenantDataScope; const AId: string);

/// The first statement of a change to a professional's schedule, through
/// AQuery inside the caller's transaction: raises ENotFoundException when the
/// tenant has no professional AId; on PostgreSQL it also locks the row until
/// the transaction ends, so two changes to one schedule don't interleave.
procedure TouchProfessional(const AQuery: IQuery; const AScope: TTenantDataScope;
  const AId: string);

implementation

uses
  SysUtils,
  PascalDb.SqlLoader,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.Text,
  PascalApi.Jwt,
  PascalApi.PagedQuery,
  Agenda.Auth,
  PascalCommon.Text,
  Agenda.Text,
  Agenda.Tokens;

const
  MAX_NAME_CHARS = 100;

function ProfessionalOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('name', 'NAME_KEY')
    .Allow('createdAt', 'CREATED_AT')
    .Default('name')
    .AlwaysLast('ID');
end;

procedure RequireProfessional(const AScope: TTenantDataScope; const AId: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, AScope, 'PROFESSIONAL.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  if LQuery.Open.Eof then
    raise ENotFoundException.Create('Professional not found.');
end;

procedure TouchProfessional(const AQuery: IQuery; const AScope: TTenantDataScope;
  const AId: string);
begin
  TTenantFilter.Prepare(AQuery, AScope, 'PROFESSIONAL.TOUCH');
  AQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
  AQuery.Params.Strings['ID'] := AId;
  if AQuery.ExecSql = 0 then
    raise ENotFoundException.Create('Professional not found.');
end;

{ DTOs }

function TProfessionalInsert.GetName: string;
begin
  Result := FName;
end;

function TProfessionalInsert.GetEmail: IOptString;
begin
  Result := TOptionals.Safe(FEmail);
end;

function TProfessionalPatch.GetName: IOptString;
begin
  Result := TOptionals.Safe(FName);
end;

function TProfessionalPatch.GetEmail: IOptNullString;
begin
  Result := TOptionals.Safe(FEmail);
end;

function TProfessionalPatch.GetActive: IOptBoolean;
begin
  Result := TOptionals.Safe(FActive);
end;

function TProfessionalFind.GetActive: IOptBoolean;
begin
  Result := TOptionals.Safe(FActive);
end;

function TProfessional.GetId: string;
begin
  Result := FId;
end;

function TProfessional.GetName: string;
begin
  Result := FName;
end;

function TProfessional.GetEmail: INullString;
begin
  Result := TOptionals.Safe(FEmail);
end;

function TProfessional.GetActive: Boolean;
begin
  Result := FActive;
end;

{ validation }

function CheckName(const AName: string): string;
begin
  Result := Trim(AName);
  if PcFoldForSearch(Result) = '' then
    raise EValidationException.Create('"name" is required.', 'name_required');
  if PaCharCount(Result) > MAX_NAME_CHARS then
    raise EValidationException.CreateFmt('"name" must have at most %d characters.',
      [MAX_NAME_CHARS]);
end;

function CheckEmail(const AEmail: string): string;
begin
  Result := NormalizeEmail(AEmail);
  if Result = '' then
    raise EValidationException.Create('"email" is not an email address.');
end;

{ TProfessionalRepository }

constructor TProfessionalRepository.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

function ReadProfessional(const AResult: IQueryResult): IProfessional;
var
  LProfessional: TProfessional;
begin
  LProfessional := TProfessional.Create;
  Result := LProfessional;
  LProfessional.Id := AResult.Strings['ID'];
  LProfessional.Name := AResult.Strings['NAME'];
  LProfessional.Email := AResult.NullableStrings['EMAIL'];
  LProfessional.Active := AResult.Integers['ACTIVE'] <> 0;
end;

function HasSearch(const AFind: IProfessionalFind): Boolean;
begin
  Result := AFind.Search.HasValue and (PcFoldForSearch(AFind.Search.Value) <> '');
end;

function Filtered(const ASql: TSQLResult; const AFind: IProfessionalFind): TSQLResult;
begin
  Result := ASql.ProcessTag('SEARCH', HasSearch(AFind)).ProcessTag('ACTIVE', AFind.Active.HasValue);
end;

function FilterArgs(const AFind: IProfessionalFind): TQueryArgs;
begin
  Result := TQueryArgs.New;
  if HasSearch(AFind) then
    Result := Result.Strings('SEARCH', PdbLikeContains(PcFoldForSearch(AFind.Search.Value)));
  if AFind.Active.HasValue then
    Result := Result.Integers('ACTIVE', Ord(AFind.Active.Value));
end;

function TProfessionalRepository.FindPage(const AFind: IProfessionalFind;
  const APage: TPageRequest): TPage<IProfessional>;
begin
  Result := TTenantPagedQuery.Run<IProfessional>(FScope,
    Filtered(FScope.Factory.SqlLoader['PROFESSIONAL.COUNT'], AFind),
    Filtered(FScope.Factory.SqlLoader['PROFESSIONAL.PAGE'], AFind),
    ProfessionalOrderSpec.Build(AFind.OrderBy.ValueOr('')), APage, FilterArgs(AFind),
    ReadProfessional);
end;

function TProfessionalRepository.FindById(const AId: string): IProfessional;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if not LResult.Eof then
    Result := ReadProfessional(LResult);
  if Result = nil then
    raise ENotFoundException.Create('Professional not found.');
end;

function TProfessionalRepository.Insert(const AProfessional: IProfessionalInsert): IProfessional;
var
  LName, LId: string;
  LEmail: IOptString;
  LNow: Int64;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LName := CheckName(AProfessional.Name);
  LEmail := AProfessional.Email.Map(CheckEmail); // absent stays absent
  LId := NewId;
  LNow := TJwt.UnixNow;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // The EMAIL column only when it came; absent, the database writes NULL.
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['PROFESSIONAL.INSERT']
      .ProcessTag('EMAIL', LEmail.HasValue));
    LQuery.Params.Strings['ID'] := LId;
    LQuery.Params.Strings['NAME'] := LName;
    LQuery.Params.Strings['NAME_KEY'] := PcFoldForSearch(LName);
    LQuery.Params.OptStrings['EMAIL'] := LEmail;
    LQuery.Params.Int64s['CREATED_AT'] := LNow;
    LQuery.Params.Int64s['UPDATED_AT'] := LNow;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  Result := FindById(LId);
end;

function TProfessionalRepository.Update(const AId: string;
  const APatch: IProfessionalPatch): IProfessional;
var
  LName: IOptString;
  LEmail: IOptNullString;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  // Through Map: absent stays absent (left), null stays null (cleared), a
  // value is checked (a 400) and normalized.
  LName := APatch.Name.Map(CheckName);
  LEmail := APatch.Email.Map(CheckEmail);
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['PROFESSIONAL.UPDATE']
      .ProcessTag('NAME', LName.HasValue)
      .ProcessTag('EMAIL', LEmail.HasValue)
      .ProcessTag('ACTIVE', APatch.Active.HasValue));
    LQuery.Params.Strings['ID'] := AId;
    LQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
    LQuery.Params.OptStrings['NAME'] := LName;
    LQuery.Params.OptStrings['NAME_KEY'] := LName.Map(PcFoldForSearch);
    LQuery.Params.OptNullStrings['EMAIL'] := LEmail;
    LQuery.Params.OptBooleans['ACTIVE'] := APatch.Active;
    LRows := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('Professional not found.');
  Result := FindById(AId);
end;

procedure TProfessionalRepository.Delete(const AId: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // The user who was this professional stays, unlinked (Agenda.Users).
    TTenantFilter.Prepare(LQuery, FScope, 'USER.UNLINK_PROFESSIONAL');
    LQuery.Params.Strings['PROFESSIONAL_ID'] := AId;
    LQuery.ExecSql;
    // Its schedule goes with it (Agenda.WorkingHours, Agenda.TimeOff).
    TTenantFilter.Prepare(LQuery, FScope, 'WORKING_HOURS.DELETE_ALL');
    LQuery.Params.Strings['PROFESSIONAL_ID'] := AId;
    LQuery.ExecSql;
    TTenantFilter.Prepare(LQuery, FScope, 'TIME_OFF.DELETE_ALL');
    LQuery.Params.Strings['PROFESSIONAL_ID'] := AId;
    LQuery.ExecSql;
    TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.DELETE');
    LQuery.Params.Strings['ID'] := AId;
    LRows := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('Professional not found.');
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IProfessionalInsert, TProfessionalInsert>;
  TJsonMapper.Shared.RegisterMapping<IProfessionalPatch, TProfessionalPatch>;
  TJsonMapper.Shared.RegisterMapping<IProfessional, TProfessional>;
  TJsonMapper.Shared.RegisterMapping<IProfessionalFind, TProfessionalFind>;
  TApiSchema.Describe(TypeInfo(IProfessionalInsert), 'A new professional of the caller''s tenant')
    .Prop('Name').Desc('Full name').Example('Ana Souza').MaxLength(MAX_NAME_CHARS)
    .Prop('Email').Desc('Optional').Example('ana@demo.test');
  TApiSchema.Describe(TypeInfo(IProfessionalPatch), 'The members to change; the others stay')
    .Prop('Name').Desc('Never null').MaxLength(MAX_NAME_CHARS)
    .Prop('Email').Desc('null removes it')
    .Prop('Active').Desc('false: no longer booked');
  TApiSchema.Describe(TypeInfo(IProfessional), 'A professional of the caller''s tenant')
    .Prop('Email').Desc('null when none');
  TApiSchema.Describe(TypeInfo(IProfessionalFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Professionals per page (default 20, at most 100)')
    .Prop('OrderBy').Desc(ProfessionalOrderSpec.DocHint)
    .Prop('Search').Desc('Part of the name, ignoring case and accents')
    .Prop('Active').Desc('true or false');

end.
