unit Agenda.Professionals;

{$I agenda.inc}

(* A tenant's professionals (who is booked): name, an optional email,
  active. A repository on a tenant's scope (the DTOs and the ordering:
  Agenda.Professionals.Dtos); the same shape as Agenda.Services.

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
  PascalApi.Tenancy,
  Agenda.Professionals.Dtos;

type

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
  PascalApi.Jwt,
  PascalApi.PagedQuery,
  PascalCommon.Text,
  Agenda.Normalizers,
  PascalCommon.Validators,
  Agenda.Validators,
  Agenda.Text,
  Agenda.Tokens;

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

// The filters of the count and the page, each optional with the tag of its
// block: Run keeps the block of a present one and drops an absent one's
// (TQueryArgs, pascal-api-infra-faa 0.22.0).
function FilterArgs(const AFind: IProfessionalFind): TQueryArgs;
begin
  Result := TQueryArgs.New
    .OptStrings('SEARCH', SearchPattern(TOptionals.Map(AFind.Search, PcFoldForSearch)), 'SEARCH')
    .OptFlags('ACTIVE', AFind.Active, 'ACTIVE');
end;

function TProfessionalRepository.FindPage(const AFind: IProfessionalFind;
  const APage: TPageRequest): TPage<IProfessional>;
begin
  Result := TTenantPagedQuery.Run<IProfessional>(FScope,
    FScope.Factory.SqlLoader['PROFESSIONAL.COUNT'], FScope.Factory.SqlLoader['PROFESSIONAL.PAGE'],
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
  LCheck: TPcValidation;
begin
  // Normalized (Agenda.Normalizers), then checked (Agenda.Validators; the
  // document's limits were enforced at the edge): an absent email stays
  // absent and isn't checked, with no if.
  LName := TNorm.DisplayName.Apply(AProfessional.Name);
  LEmail := TOptionals.Normalize(AProfessional.Email, TNorm.Email);
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.DisplayName);
  LCheck.Check('email', LEmail, TValid.Email);
  LCheck.RaiseIfAny;
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
    LQuery.Params.Strings['NAME_KEY'] := TNorm.FoldForSearch.Apply(LName);
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
  LCheck: TPcValidation;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  // Normalized inside the optionals: absent stays absent (left), null stays
  // null (the email cleared). Then the checks, for the members that came.
  LName := TOptionals.Normalize(APatch.Name, TNorm.DisplayName);
  LEmail := TOptionals.Normalize(APatch.Email, TNorm.Email);
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.DisplayName);
  LCheck.Check('email', LEmail, TValid.Email);
  LCheck.RaiseIfAny;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['PROFESSIONAL.UPDATE']
      .ProcessTag('NAME', LName.HasValue)
      .ProcessTag('EMAIL', LEmail.HasValue)
      .ProcessTag('ACTIVE', APatch.Active.HasValue));
    // No if per member: an absent optional binds nothing (its block is gone),
    // a Null binds NULL, a value binds it.
    LQuery.Params.Strings['ID'] := AId;
    LQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
    LQuery.Params.OptStrings['NAME'] := LName;
    LQuery.Params.OptStrings['NAME_KEY'] := TOptionals.Normalize(LName, TNorm.FoldForSearch);
    LQuery.Params.OptNullStrings['EMAIL'] := LEmail;
    LQuery.Params.OptFlags['ACTIVE'] := APatch.Active; // an INTEGER column: Flags, never Booleans
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

end.
