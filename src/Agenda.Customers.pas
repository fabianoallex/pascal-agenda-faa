unit Agenda.Customers;

{$I agenda.inc}

(* A tenant's customers (who books): a name, and a phone and an email, both
  optional. DTOs, the ordering clients may ask for, and a repository on a
  tenant's scope; the same shape as Agenda.Professionals.

  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag).
  - Neither the name nor the contacts are unique: two people share a name,
    a family shares a phone. Public booking (M3) decides how it finds a
    returning customer.
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
  PascalApi.Tenancy;

type
  ICustomerInsert = interface(IInsertDTOBase)
    ['{AAEF90A4-3DB8-400E-AFA7-4178129C42F3}']
    function GetName: string;
    function GetPhone: IOptString;
    function GetEmail: IOptString;
    property Name: string read GetName;
    property Phone: IOptString read GetPhone;
    property Email: IOptString read GetEmail;
  end;

  /// PATCH: absent leaves a member; null clears the phone or the email.
  ICustomerPatch = interface(IUpdateDTOBase)
    ['{AB6B302E-3912-4D44-B8F0-95BFE1EC1CBB}']
    function GetName: IOptString;
    function GetPhone: IOptNullString;
    function GetEmail: IOptNullString;
    property Name: IOptString read GetName;
    property Phone: IOptNullString read GetPhone;
    property Email: IOptNullString read GetEmail;
  end;

  ICustomer = interface(IResponseDTOBase)
    ['{ACC07937-F116-4053-9DF6-A025C8D6EB8F}']
    function GetId: string;
    function GetName: string;
    function GetPhone: INullString;
    function GetEmail: INullString;
    property Id: string read GetId;
    property Name: string read GetName;
    property Phone: INullString read GetPhone;
    property Email: INullString read GetEmail;
  end;

  /// GET /customers: page, limit, orderBy, search (name, email or phone).
  ICustomerFind = interface(IFindPaginationDTOBase)
    ['{B2632329-69AA-4D09-90FD-F9837DE8D993}']
  end;

{$M+}
  TCustomerInsert = class(TInsertDTOBase, ICustomerInsert)
  private
    FName: string;
    FPhone, FEmail: IOptString;
  public
    function GetName: string;
    function GetPhone: IOptString;
    function GetEmail: IOptString;
  published
    property Name: string read FName write FName;
    property Phone: IOptString read FPhone write FPhone;
    property Email: IOptString read FEmail write FEmail;
  end;

  TCustomerPatch = class(TUpdateDTOBase, ICustomerPatch)
  private
    FName: IOptString;
    FPhone, FEmail: IOptNullString;
  public
    function GetName: IOptString;
    function GetPhone: IOptNullString;
    function GetEmail: IOptNullString;
  published
    property Name: IOptString read FName write FName;
    property Phone: IOptNullString read FPhone write FPhone;
    property Email: IOptNullString read FEmail write FEmail;
  end;

  TCustomer = class(TResponseDTOBase, ICustomer)
  private
    FId, FName: string;
    FPhone, FEmail: INullString;
  public
    function GetId: string;
    function GetName: string;
    function GetPhone: INullString;
    function GetEmail: INullString;
  published
    property Id: string read FId write FId;
    property Name: string read FName write FName;
    property Phone: INullString read FPhone write FPhone;
    property Email: INullString read FEmail write FEmail;
  end;

  TCustomerFind = class(TFindPaginationDTOBase, ICustomerFind)
  end;
{$M-}

  TCustomerArray = TArray<ICustomer>;

  TCustomerRepository = class
  private
    FScope: TTenantDataScope;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// EOrderByException for a field not allowed (400).
    function FindPage(const AFind: ICustomerFind; const APage: TPageRequest): TPage<ICustomer>;
    /// ENotFoundException when the tenant has none with this id.
    function FindById(const AId: string): ICustomer;
    /// EValidationException for invalid data.
    function Insert(const ACustomer: ICustomerInsert): ICustomer;
    function Update(const AId: string; const APatch: ICustomerPatch): ICustomer;
    procedure Delete(const AId: string);
  end;

function CustomerOrderSpec: TOrderBySpec;

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
  MAX_NAME_CHARS = 100;

function CustomerOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('name', 'NAME_KEY')
    .Allow('createdAt', 'CREATED_AT')
    .Default('name')
    .AlwaysLast('ID');
end;

function CustomerSearchTerm(const AText: string): string;
var
  LDigits: string;
begin
  if TryPhoneDigits(AText, LDigits) then
    Result := LDigits
  else
    Result := PcFoldForSearch(AText);
end;

{ DTOs }

function TCustomerInsert.GetName: string;
begin
  Result := FName;
end;

function TCustomerInsert.GetPhone: IOptString;
begin
  Result := TOptionals.Safe(FPhone);
end;

function TCustomerInsert.GetEmail: IOptString;
begin
  Result := TOptionals.Safe(FEmail);
end;

function TCustomerPatch.GetName: IOptString;
begin
  Result := TOptionals.Safe(FName);
end;

function TCustomerPatch.GetPhone: IOptNullString;
begin
  Result := TOptionals.Safe(FPhone);
end;

function TCustomerPatch.GetEmail: IOptNullString;
begin
  Result := TOptionals.Safe(FEmail);
end;

function TCustomer.GetId: string;
begin
  Result := FId;
end;

function TCustomer.GetName: string;
begin
  Result := FName;
end;

function TCustomer.GetPhone: INullString;
begin
  Result := TOptionals.Safe(FPhone);
end;

function TCustomer.GetEmail: INullString;
begin
  Result := TOptionals.Safe(FEmail);
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

function SearchOf(const AFind: ICustomerFind): string;
begin
  Result := '';
  if AFind.Search.HasValue then
    Result := CustomerSearchTerm(AFind.Search.Value);
end;

function TCustomerRepository.FindPage(const AFind: ICustomerFind;
  const APage: TPageRequest): TPage<ICustomer>;
var
  LOrder, LSearch: string;
  LArgs: TQueryArgs;
begin
  LOrder := CustomerOrderSpec.Build(AFind.OrderBy.ValueOr(''));
  LSearch := SearchOf(AFind);
  LArgs := TQueryArgs.New;
  if LSearch <> '' then
    LArgs := LArgs.Strings('SEARCH', PdbLikeContains(LSearch));
  Result := TTenantPagedQuery.Run<ICustomer>(FScope,
    FScope.Factory.SqlLoader['CUSTOMER.COUNT'].ProcessTag('SEARCH', LSearch <> ''),
    FScope.Factory.SqlLoader['CUSTOMER.PAGE'].ProcessTag('SEARCH', LSearch <> ''),
    LOrder, APage, LArgs, ReadCustomer);
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

function TCustomerRepository.Insert(const ACustomer: ICustomerInsert): ICustomer;
var
  LName, LId: string;
  LPhone, LEmail: IOptString;
  LCheck: TPcValidation;
  LNow: Int64;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  // Normalized (Agenda.Normalizers), then checked (Agenda.Validators; the
  // document's limits were enforced at the edge): a contact that didn't come
  // stays absent and isn't checked, with no if.
  LName := TNorm.DisplayName.Apply(ACustomer.Name);
  LPhone := TOptionals.Normalize(ACustomer.Phone, TNorm.Phone);
  LEmail := TOptionals.Normalize(ACustomer.Email, TNorm.Email);
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.DisplayName);
  LCheck.Check('phone', LPhone, TValid.Phone);
  LCheck.Check('email', LEmail, TValid.Email);
  LCheck.RaiseIfAny;
  LId := NewId;
  LNow := TJwt.UnixNow;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // A column per optional contact, kept exactly when it came; absent, the
    // database writes NULL. The tag and the parameter go together.
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['CUSTOMER.INSERT']
      .ProcessTag('PHONE', LPhone.HasValue)
      .ProcessTag('EMAIL', LEmail.HasValue));
    LQuery.Params.Strings['ID'] := LId;
    LQuery.Params.Strings['NAME'] := LName;
    LQuery.Params.Strings['NAME_KEY'] := TNorm.FoldForSearch.Apply(LName);
    LQuery.Params.OptStrings['PHONE'] := LPhone;
    LQuery.Params.OptStrings['EMAIL'] := LEmail;
    LQuery.Params.Strings['SEARCH_KEY'] := SearchKey(LName, LPhone.ValueOr(''), LEmail.ValueOr(''));
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

initialization
  TJsonMapper.Shared.RegisterMapping<ICustomerInsert, TCustomerInsert>;
  TJsonMapper.Shared.RegisterMapping<ICustomerPatch, TCustomerPatch>;
  TJsonMapper.Shared.RegisterMapping<ICustomer, TCustomer>;
  TJsonMapper.Shared.RegisterMapping<ICustomerFind, TCustomerFind>;
  TApiSchema.Describe(TypeInfo(ICustomerInsert), 'A new customer of the caller''s tenant')
    .Prop('Name').Desc('Full name').Example('Maria Lima').MaxLength(MAX_NAME_CHARS)
    .Prop('Phone').Desc('Optional; 8 to 15 digits, "+" first allowed, spaces, "-", ".", ' +
      '"(" and ")" ignored').Example('+55 11 99999-0000')
    .Prop('Email').Desc('Optional').Example('maria@example.test');
  TApiSchema.Describe(TypeInfo(ICustomerPatch), 'The members to change; the others stay')
    .Prop('Name').Desc('Never null').MaxLength(MAX_NAME_CHARS)
    .Prop('Phone').Desc('null removes it')
    .Prop('Email').Desc('null removes it');
  TApiSchema.Describe(TypeInfo(ICustomer), 'A customer of the caller''s tenant')
    .Prop('Phone').Desc('"+" and digits; null when none').Example('+5511999990000')
    .Prop('Email').Desc('null when none');
  TApiSchema.Describe(TypeInfo(ICustomerFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Customers per page (default 20, at most 100)')
    .Prop('OrderBy').Desc(CustomerOrderSpec.DocHint)
    .Prop('Search').Desc('Part of the name (ignoring case and accents), of the email, ' +
      'or of the phone (its digits)');

end.
