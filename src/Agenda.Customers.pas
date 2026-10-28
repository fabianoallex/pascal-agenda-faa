unit Agenda.Customers;

{$I agenda.inc}

(* A tenant's customers (who books): a name, and a phone and an email, both
  optional. A repository on a tenant's scope (the DTOs and the ordering:
  Agenda.Customers.Dtos); the same shape as Agenda.Professionals.

  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag).
  - Neither the name nor the contacts are unique: two people share a name,
    a family shares a phone. The public booking finds a returning customer
    with FindOrInsert: the same phone (or, without one, the same email) and
    the same name folded for search (docs/design.md, M3 decision 2).
  - The phone is stored as Agenda.Text's NormalizePhone gives it ("+" and
    digits); the email lower case (Agenda.Normalizers' TNorm.Email).
  - Search: one stored key, SEARCH_KEY = NAME_KEY|EMAIL|phone digits, so one
    LIKE finds a customer by any of the three. A search typed like a phone
    ("(11) 9999") is matched by its digits; anything else is folded like a
    name. A PATCH reads the row and writes it whole, the key recomputed.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalDb.Paging,
  PascalApi.OrderBy,
  PascalApi.Dto,
  PascalApi.Tenancy,
  Agenda.Customers.Dtos;

type

  TCustomerRepository = class
  private
    FScope: TTenantDataScope;
    function InsertPrepared(const AName: string; const APhone, AEmail: IOptString): ICustomer;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// EOrderByException for a field not allowed (400).
    function FindPage(const AFind: ICustomerFind; const APage: TPageRequest): TPage<ICustomer>;
    /// ENotFoundException when the tenant has none with this id.
    function FindById(const AId: string): ICustomer;
    /// EValidationException for invalid data.
    function Insert(const ACustomer: ICustomerInsert): ICustomer;
    /// The customer with the same phone, or without one the same email, and
    /// the same name folded for search (the oldest when several); else a new
    /// one. A customer found is returned as stored, never changed.
    /// EValidationException for invalid data, or contact_required when
    /// there is neither a phone nor an email.
    function FindOrInsert(const ACustomer: ICustomerInsert): ICustomer;
    function Update(const AId: string; const APatch: ICustomerPatch): ICustomer;
    procedure Delete(const AId: string);
  end;

/// What the search looks for in SEARCH_KEY: a phone's digits, or the text
/// folded like a name; '' for nothing to search.
function CustomerSearchTerm(const AText: string): string;

implementation

uses
  SysUtils,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.Jwt,
  PascalApi.PagedQuery,
  PascalCommon.Text,
  Agenda.Text,
  Agenda.Normalizers,
  PascalCommon.Validators,
  Agenda.Validators,
  Agenda.Tokens;

const
  CODE_CONTACT_REQUIRED = 'contact_required';

function CustomerSearchTerm(const AText: string): string;
var
  LDigits: string;
begin
  if TryPhoneDigits(AText, LDigits) then
    Result := LDigits
  else
    Result := PcFoldForSearch(AText);
end;

{ the stored row }

type
  // A customer as stored: the contacts null or a value (never '' for none).
  TCustomerRow = record
    Name: string;
    Phone: INullString;
    Email: INullString;
  end;

// NAME_KEY|EMAIL|the phone's digits ('' for a contact there isn't).
function SearchKey(const AName, APhone, AEmail: string): string;
var
  LDigits: string;
begin
  if not TryPhoneDigits(APhone, LDigits) then
    LDigits := '';
  Result := PcFoldForSearch(AName) + '|' + AEmail + '|' + LDigits;
end;

// A PATCH member over the stored value: the stored one when the member is
// absent, else what came (null clears it).
function Merged(const APatch: IOptNullString; const AStored: INullString): INullString;
begin
  if APatch.HasValue then
    Result := APatch as INullString
  else
    Result := AStored;
end;

function ReadCustomer(const AResult: IQueryResult): ICustomer;
var
  LCustomer: TCustomer;
begin
  LCustomer := TCustomer.Create;
  Result := LCustomer;
  LCustomer.Id := AResult.Strings['ID'];
  LCustomer.Name := AResult.Strings['NAME'];
  LCustomer.Phone := AResult.NullableStrings['PHONE'];
  LCustomer.Email := AResult.NullableStrings['EMAIL'];
end;

{ TCustomerRepository }

constructor TCustomerRepository.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;


function TCustomerRepository.FindPage(const AFind: ICustomerFind;
  const APage: TPageRequest): TPage<ICustomer>;
var
  LOrder: string;
begin
  LOrder := CustomerOrderSpec.Build(AFind.OrderBy.ValueOr(''));
  // A phone's digits, or the text folded like a name (CustomerSearchTerm);
  // the SEARCH block only when something is left to look for.
  Result := TTenantPagedQuery.Run<ICustomer>(FScope, FScope.Factory.SqlLoader['CUSTOMER.COUNT'],
    FScope.Factory.SqlLoader['CUSTOMER.PAGE'], LOrder, APage,
    TQueryArgs.New.OptStrings('SEARCH', SearchPattern(TOptionals.Map(AFind.Search,
    CustomerSearchTerm)), 'SEARCH'), ReadCustomer);
end;

function TCustomerRepository.FindById(const AId: string): ICustomer;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if not LResult.Eof then
    Result := ReadCustomer(LResult);
  if Result = nil then
    raise ENotFoundException.Create('Customer not found.');
end;

// Normalized (Agenda.Normalizers), then checked (Agenda.Validators; the
// document's limits were enforced at the edge): a contact that didn't come
// stays absent and isn't checked, with no if. AContactRequired: a phone or an
// email must come (contact_required on "phone" otherwise).
procedure PrepareInsert(const ACustomer: ICustomerInsert; AContactRequired: Boolean;
  out AName: string; out APhone, AEmail: IOptString);
var
  LCheck: TPcValidation;
begin
  AName := TNorm.DisplayName.Apply(ACustomer.Name);
  APhone := TOptionals.Normalize(ACustomer.Phone, TNorm.Phone);
  AEmail := TOptionals.Normalize(ACustomer.Email, TNorm.Email);
  LCheck := TPcValidation.Create;
  LCheck.Check('name', AName, TValid.DisplayName);
  LCheck.Check('phone', APhone, TValid.Phone);
  LCheck.Check('email', AEmail, TValid.Email);
  if AContactRequired and not APhone.HasValue and not AEmail.HasValue then
    LCheck.Fail('phone', CODE_CONTACT_REQUIRED, 'A phone or an email is required.');
  LCheck.RaiseIfAny;
end;

function TCustomerRepository.Insert(const ACustomer: ICustomerInsert): ICustomer;
var
  LName: string;
  LPhone, LEmail: IOptString;
begin
  PrepareInsert(ACustomer, False, LName, LPhone, LEmail);
  Result := InsertPrepared(LName, LPhone, LEmail);
end;

function TCustomerRepository.FindOrInsert(const ACustomer: ICustomerInsert): ICustomer;
var
  LName: string;
  LPhone, LEmail: IOptString;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  PrepareInsert(ACustomer, True, LName, LPhone, LEmail);
  Result := nil;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  if LPhone.HasValue then
  begin
    TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.MATCH_PHONE');
    LQuery.Params.Strings['PHONE'] := LPhone.Value;
  end
  else
  begin
    TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.MATCH_EMAIL');
    LQuery.Params.Strings['EMAIL'] := LEmail.Value;
  end;
  LQuery.Params.Strings['NAME_KEY'] := TNorm.FoldForSearch.Apply(LName);
  LResult := LQuery.Open;
  if not LResult.Eof then
    Result := ReadCustomer(LResult);
  // The connection back to the pool before the insert takes one.
  LResult := nil;
  LQuery := nil;
  LTx := nil;
  if Result = nil then
    Result := InsertPrepared(LName, LPhone, LEmail);
end;

function TCustomerRepository.InsertPrepared(const AName: string;
  const APhone, AEmail: IOptString): ICustomer;
var
  LId: string;
  LNow: Int64;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LId := NewId;
  LNow := TJwt.UnixNow;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // A column per optional contact, kept exactly when it came; absent, the
    // database writes NULL. The tag and the parameter go together.
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['CUSTOMER.INSERT']
      .ProcessTag('PHONE', APhone.HasValue)
      .ProcessTag('EMAIL', AEmail.HasValue));
    LQuery.Params.Strings['ID'] := LId;
    LQuery.Params.Strings['NAME'] := AName;
    LQuery.Params.Strings['NAME_KEY'] := TNorm.FoldForSearch.Apply(AName);
    LQuery.Params.OptStrings['PHONE'] := APhone;
    LQuery.Params.OptStrings['EMAIL'] := AEmail;
    LQuery.Params.Strings['SEARCH_KEY'] := SearchKey(AName, APhone.ValueOr(''), AEmail.ValueOr(''));
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

function TCustomerRepository.Update(const AId: string; const APatch: ICustomerPatch): ICustomer;
var
  LName: IOptString;
  LPhone, LEmail: IOptNullString;
  LCheck: TPcValidation;
  LRow: TCustomerRow;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LFound: Boolean;
begin
  // Normalized inside the optionals, then checked, before the transaction: a
  // 400 touches nothing; null and absent pass through unchanged.
  LName := TOptionals.Normalize(APatch.Name, TNorm.DisplayName);
  LPhone := TOptionals.Normalize(APatch.Phone, TNorm.Phone);
  LEmail := TOptionals.Normalize(APatch.Email, TNorm.Email);
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.DisplayName);
  LCheck.Check('phone', LPhone, TValid.Phone);
  LCheck.Check('email', LEmail, TValid.Email);
  LCheck.RaiseIfAny;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // The search key depends on every column, so the row is read and written
    // whole: what came over what is stored.
    TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.BY_ID');
    LQuery.Params.Strings['ID'] := AId;
    LResult := LQuery.Open;
    LFound := not LResult.Eof;
    if LFound then
    begin
      LRow.Name := LName.ValueOr(LResult.Strings['NAME']);
      LRow.Phone := Merged(LPhone, LResult.NullableStrings['PHONE']);
      LRow.Email := Merged(LEmail, LResult.NullableStrings['EMAIL']);
      LResult := nil;
      TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.UPDATE');
      LQuery.Params.Strings['ID'] := AId;
      LQuery.Params.Strings['NAME'] := LRow.Name;
      LQuery.Params.Strings['NAME_KEY'] := TNorm.FoldForSearch.Apply(LRow.Name);
      LQuery.Params.NullStrings['PHONE'] := LRow.Phone;
      LQuery.Params.NullStrings['EMAIL'] := LRow.Email;
      LQuery.Params.Strings['SEARCH_KEY'] := SearchKey(LRow.Name, LRow.Phone.ValueOr(''),
        LRow.Email.ValueOr(''));
      LQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
      LQuery.ExecSql;
    end;
    LResult := nil;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if not LFound then
    raise ENotFoundException.Create('Customer not found.');
  Result := FindById(AId);
end;

procedure TCustomerRepository.Delete(const AId: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.DELETE');
    LQuery.Params.Strings['ID'] := AId;
    LRows := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('Customer not found.');
end;

end.
