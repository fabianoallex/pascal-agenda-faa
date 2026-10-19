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
    digits); the email lower case (Agenda.Auth's NormalizeEmail).
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
  PascalApi.Text,
  PascalApi.Jwt,
  PascalApi.PagedQuery,
  Agenda.Auth,
  PascalCommon.Text,
  Agenda.Text,
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

function CheckPhone(const APhone: string): string;
begin
  Result := NormalizePhone(APhone);
  if Result = '' then
    raise EValidationException.Create('"phone" is not a phone number (8 to 15 digits).');
end;

function CheckEmail(const AEmail: string): string;
begin
  Result := NormalizeEmail(AEmail);
  if Result = '' then
    raise EValidationException.Create('"email" is not an email address.');
end;

{ the stored row }

type
  TCustomerRow = record
    Name: string;
    Phone: string; // '' = none
    Email: string; // '' = none
  end;

function SearchKey(const ARow: TCustomerRow): string;
var
  LDigits: string;
begin
  if not TryPhoneDigits(ARow.Phone, LDigits) then
    LDigits := '';
  Result := PcFoldForSearch(ARow.Name) + '|' + ARow.Email + '|' + LDigits;
end;

function NullIfEmpty(const AText: string): IOptNullString;
begin
  if AText = '' then
    Result := TOptNullString.Null
  else
    Result := TOptNullString.From(AText);
end;

// The row's columns, through TTenantFilter.Prepare already done.
procedure BindRow(const AQuery: IQuery; const ARow: TCustomerRow);
begin
  AQuery.Params.Strings['NAME'] := ARow.Name;
  AQuery.Params.Strings['NAME_KEY'] := PcFoldForSearch(ARow.Name);
  AQuery.Params.OptNullStrings['PHONE'] := NullIfEmpty(ARow.Phone);
  AQuery.Params.OptNullStrings['EMAIL'] := NullIfEmpty(ARow.Email);
  AQuery.Params.Strings['SEARCH_KEY'] := SearchKey(ARow);
  AQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
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
  LRow: TCustomerRow;
  LId: string;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LRow.Name := CheckName(ACustomer.Name);
  LRow.Phone := '';
  if ACustomer.Phone.HasValue then
    LRow.Phone := CheckPhone(ACustomer.Phone.Value);
  LRow.Email := '';
  if ACustomer.Email.HasValue then
    LRow.Email := CheckEmail(ACustomer.Email.Value);
  LId := NewId;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.INSERT');
    LQuery.Params.Strings['ID'] := LId;
    BindRow(LQuery, LRow);
    LQuery.Params.Int64s['CREATED_AT'] := TJwt.UnixNow;
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
  LRow: TCustomerRow;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LFound: Boolean;
begin
  // Checked before the transaction: a 400 touches nothing.
  if APatch.Name.HasValue then
    LRow.Name := CheckName(APatch.Name.Value);
  if APatch.Phone.HasValue and not APatch.Phone.IsNull then
    LRow.Phone := CheckPhone(APatch.Phone.Value);
  if APatch.Email.HasValue and not APatch.Email.IsNull then
    LRow.Email := CheckEmail(APatch.Email.Value);
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.BY_ID');
    LQuery.Params.Strings['ID'] := AId;
    LResult := LQuery.Open;
    LFound := not LResult.Eof;
    if LFound then
    begin
      // Absent: the stored value; null: none; a value: the checked one.
      if not APatch.Name.HasValue then
        LRow.Name := LResult.Strings['NAME'];
      if not APatch.Phone.HasValue then
        LRow.Phone := LResult.NullableStrings['PHONE'].ValueOr('')
      else if APatch.Phone.IsNull then
        LRow.Phone := '';
      if not APatch.Email.HasValue then
        LRow.Email := LResult.NullableStrings['EMAIL'].ValueOr('')
      else if APatch.Email.IsNull then
        LRow.Email := '';
      LResult := nil;
      TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.UPDATE');
      LQuery.Params.Strings['ID'] := AId;
      BindRow(LQuery, LRow);
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
