unit Agenda.Services;

{$I agenda.inc}

(* A tenant's services (what a customer books): name, duration, the buffer
  after it (cleaning, preparing the next customer), price, active. DTOs, the
  ordering clients may ask for, and a repository on a tenant's scope.

  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag).
  - The name is unique within a tenant by its search key (NAME_KEY,
    Agenda.Text): "Corte" and "corte " are the same service; the database's
    unique key answers a duplicate (409, pascal-api-infra-faa's mapping).
  - The price is cents in the database (Agenda.Money); a fraction of a cent
    is a 400.
  - A service is deactivated, not deleted, once appointments use it: the
    appointments' foreign key refuses the DELETE (409); DELETE removes one
    nothing references.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalDb.Paging,
  PascalApi.OrderBy,
  PascalApi.Dto,
  PascalApi.Tenancy;

const
  MIN_DURATION_MINUTES = 5;
  MAX_DURATION_MINUTES = 480;
  MAX_BUFFER_MINUTES = 120;
  MAX_NAME_CHARS = 100;
  MAX_PRICE = 100000;

type
  IServiceInsert = interface(IInsertDTOBase)
    ['{1B1132CE-CEAC-42BA-A604-158E28CC429A}']
    function GetName: string;
    function GetDurationMinutes: Integer;
    function GetBufferMinutes: IOptInteger;
    function GetPrice: Currency;
    property Name: string read GetName;
    property DurationMinutes: Integer read GetDurationMinutes;
    property BufferMinutes: IOptInteger read GetBufferMinutes;
    property Price: Currency read GetPrice;
  end;

  /// PATCH: every member may be absent (left as it is); none may be null.
  IServicePatch = interface(IUpdateDTOBase)
    ['{910AF319-CFE8-4A1F-B239-A1BB2A607C3E}']
    function GetName: IOptString;
    function GetDurationMinutes: IOptInteger;
    function GetBufferMinutes: IOptInteger;
    function GetPrice: IOptCurrency;
    function GetActive: IOptBoolean;
    property Name: IOptString read GetName;
    property DurationMinutes: IOptInteger read GetDurationMinutes;
    property BufferMinutes: IOptInteger read GetBufferMinutes;
    property Price: IOptCurrency read GetPrice;
    property Active: IOptBoolean read GetActive;
  end;

  IService = interface(IResponseDTOBase)
    ['{3FDC5BEC-FEDB-48F4-9235-8A758D66FCD3}']
    function GetId: string;
    function GetName: string;
    function GetDurationMinutes: Integer;
    function GetBufferMinutes: Integer;
    function GetPrice: Currency;
    function GetActive: Boolean;
    property Id: string read GetId;
    property Name: string read GetName;
    property DurationMinutes: Integer read GetDurationMinutes;
    property BufferMinutes: Integer read GetBufferMinutes;
    property Price: Currency read GetPrice;
    property Active: Boolean read GetActive;
  end;

  /// GET /services: page, limit, orderBy, search (in the name, ignoring case
  /// and accents), active.
  IServiceFind = interface(IFindPaginationDTOBase)
    ['{47937802-211D-4792-B57C-0731C1D70C8A}']
    function GetActive: IOptBoolean;
    property Active: IOptBoolean read GetActive;
  end;

{$M+}
  TServiceInsert = class(TInsertDTOBase, IServiceInsert)
  private
    FName: string;
    FDurationMinutes: Integer;
    FBufferMinutes: IOptInteger;
    FPrice: Currency;
  public
    function GetName: string;
    function GetDurationMinutes: Integer;
    function GetBufferMinutes: IOptInteger;
    function GetPrice: Currency;
  published
    property Name: string read FName write FName;
    property DurationMinutes: Integer read FDurationMinutes write FDurationMinutes;
    property BufferMinutes: IOptInteger read FBufferMinutes write FBufferMinutes;
    property Price: Currency read FPrice write FPrice;
  end;

  TServicePatch = class(TUpdateDTOBase, IServicePatch)
  private
    FName: IOptString;
    FDurationMinutes, FBufferMinutes: IOptInteger;
    FPrice: IOptCurrency;
    FActive: IOptBoolean;
  public
    function GetName: IOptString;
    function GetDurationMinutes: IOptInteger;
    function GetBufferMinutes: IOptInteger;
    function GetPrice: IOptCurrency;
    function GetActive: IOptBoolean;
  published
    property Name: IOptString read FName write FName;
    property DurationMinutes: IOptInteger read FDurationMinutes write FDurationMinutes;
    property BufferMinutes: IOptInteger read FBufferMinutes write FBufferMinutes;
    property Price: IOptCurrency read FPrice write FPrice;
    property Active: IOptBoolean read FActive write FActive;
  end;

  TService = class(TResponseDTOBase, IService)
  private
    FId, FName: string;
    FDurationMinutes, FBufferMinutes: Integer;
    FPrice: Currency;
    FActive: Boolean;
  public
    function GetId: string;
    function GetName: string;
    function GetDurationMinutes: Integer;
    function GetBufferMinutes: Integer;
    function GetPrice: Currency;
    function GetActive: Boolean;
  published
    property Id: string read FId write FId;
    property Name: string read FName write FName;
    property DurationMinutes: Integer read FDurationMinutes write FDurationMinutes;
    property BufferMinutes: Integer read FBufferMinutes write FBufferMinutes;
    property Price: Currency read FPrice write FPrice;
    property Active: Boolean read FActive write FActive;
  end;

  TServiceFind = class(TFindPaginationDTOBase, IServiceFind)
  private
    FActive: IOptBoolean;
  public
    function GetActive: IOptBoolean;
  published
    property Active: IOptBoolean read FActive write FActive;
  end;
{$M-}

  // TArray<IService>: the same type as TPage<IService>.Items (E2008 on
  // Delphi otherwise), and a name for Serialize<>.
  TServiceArray = TArray<IService>;

  TServiceRepository = class
  private
    FScope: TTenantDataScope;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// EOrderByException for a field not allowed (400).
    function FindPage(const AFind: IServiceFind; const APage: TPageRequest): TPage<IService>;
    /// ENotFoundException when the tenant has none with this id.
    function FindById(const AId: string): IService;
    /// EValidationException for invalid data; 409 (the database's unique
    /// key) for a name the tenant already has.
    function Insert(const AService: IServiceInsert): IService;
    function Update(const AId: string; const APatch: IServicePatch): IService;
    procedure Delete(const AId: string);
  end;

function ServiceOrderSpec: TOrderBySpec;

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
  Agenda.Normalizers,
  PascalCommon.Validators,
  Agenda.Validators,
  Agenda.Money,
  Agenda.Text,
  Agenda.Tokens;

function ServiceOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('name', 'NAME_KEY')
    .Allow('duration', 'DURATION_MINUTES')
    .Allow('price', 'PRICE_CENTS')
    .Default('name')
    .AlwaysLast('ID');
end;

{ DTOs }

function TServiceInsert.GetName: string;
begin
  Result := FName;
end;

function TServiceInsert.GetDurationMinutes: Integer;
begin
  Result := FDurationMinutes;
end;

function TServiceInsert.GetBufferMinutes: IOptInteger;
begin
  Result := TOptionals.Safe(FBufferMinutes);
end;

function TServiceInsert.GetPrice: Currency;
begin
  Result := FPrice;
end;

function TServicePatch.GetName: IOptString;
begin
  Result := TOptionals.Safe(FName);
end;

function TServicePatch.GetDurationMinutes: IOptInteger;
begin
  Result := TOptionals.Safe(FDurationMinutes);
end;

function TServicePatch.GetBufferMinutes: IOptInteger;
begin
  Result := TOptionals.Safe(FBufferMinutes);
end;

function TServicePatch.GetPrice: IOptCurrency;
begin
  Result := TOptionals.Safe(FPrice);
end;

function TServicePatch.GetActive: IOptBoolean;
begin
  Result := TOptionals.Safe(FActive);
end;

function TServiceFind.GetActive: IOptBoolean;
begin
  Result := TOptionals.Safe(FActive);
end;

function TService.GetId: string;
begin
  Result := FId;
end;

function TService.GetName: string;
begin
  Result := FName;
end;

function TService.GetDurationMinutes: Integer;
begin
  Result := FDurationMinutes;
end;

function TService.GetBufferMinutes: Integer;
begin
  Result := FBufferMinutes;
end;

function TService.GetPrice: Currency;
begin
  Result := FPrice;
end;

function TService.GetActive: Boolean;
begin
  Result := FActive;
end;

{ validation }

// The service's rules the OpenAPI document can't say (its ranges are in
// TApiSchema.Describe below, enforced at the edge by THorseBody.Read).

function FiveMinuteSteps: IPcIntegerValidator;
begin
  Result := TPcIntegerValidators.MultipleOf(5);
end;

function WholeCents: IPcCurrencyValidator;
begin
  Result := TPcCurrencyValidators.MaxDecimals(2);
end;

// A price WholeCents accepted, in cents.
function CentsOf(const APrice: Currency): Int64;
begin
  if not TryCurrencyToCents(APrice, Result) then
    raise EValidationException.Create('"price" can''t have a fraction of a cent.');
end;

{ TServiceRepository }

constructor TServiceRepository.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

function ReadService(const AResult: IQueryResult): IService;
var
  LService: TService;
begin
  LService := TService.Create;
  Result := LService;
  LService.Id := AResult.Strings['ID'];
  LService.Name := AResult.Strings['NAME'];
  LService.DurationMinutes := AResult.Integers['DURATION_MINUTES'];
  LService.BufferMinutes := AResult.Integers['BUFFER_MINUTES'];
  LService.Price := CentsToCurrency(AResult.Int64s['PRICE_CENTS']);
  LService.Active := AResult.Integers['ACTIVE'] <> 0;
end;

// The filters of the count and the page, each optional with the tag of its
// block: Run keeps the block of a present one and drops an absent one's
// (TQueryArgs, pascal-api-infra-faa 0.22.0).
function FilterArgs(const AFind: IServiceFind): TQueryArgs;
begin
  Result := TQueryArgs.New
    .OptStrings('SEARCH', SearchPattern(TOptionals.Map(AFind.Search, PcFoldForSearch)), 'SEARCH')
    .OptFlags('ACTIVE', AFind.Active, 'ACTIVE');
end;

function TServiceRepository.FindPage(const AFind: IServiceFind;
  const APage: TPageRequest): TPage<IService>;
begin
  Result := TTenantPagedQuery.Run<IService>(FScope, FScope.Factory.SqlLoader['SERVICE.COUNT'],
    FScope.Factory.SqlLoader['SERVICE.PAGE'], ServiceOrderSpec.Build(AFind.OrderBy.ValueOr('')),
    APage, FilterArgs(AFind), ReadService);
end;

function TServiceRepository.FindById(const AId: string): IService;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'SERVICE.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if not LResult.Eof then
    Result := ReadService(LResult);
  if Result = nil then
    raise ENotFoundException.Create('Service not found.');
end;

function TServiceRepository.Insert(const AService: IServiceInsert): IService;
var
  LName, LId: string;
  LBuffer: Integer;
  LNow: Int64;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LCheck: TPcValidation;
begin
  // The document's limits were enforced at the edge (THorseBody.Read).
  // Normalized (Agenda.Normalizers), then the rules it can't say, every
  // failing field in one 400 that touches nothing.
  LName := TNorm.DisplayName.Apply(AService.Name);
  LBuffer := AService.BufferMinutes.ValueOr(0);
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.DisplayName);
  LCheck.Check('durationMinutes', AService.DurationMinutes, FiveMinuteSteps);
  LCheck.Check('bufferMinutes', AService.BufferMinutes, FiveMinuteSteps);
  LCheck.Check('price', AService.Price, WholeCents);
  LCheck.RaiseIfAny;
  LId := NewId;
  LNow := TJwt.UnixNow;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'SERVICE.INSERT');
    LQuery.Params.Strings['ID'] := LId;
    LQuery.Params.Strings['NAME'] := LName;
    LQuery.Params.Strings['NAME_KEY'] := TNorm.FoldForSearch.Apply(LName);
    LQuery.Params.Integers['DURATION_MINUTES'] := AService.DurationMinutes;
    LQuery.Params.Integers['BUFFER_MINUTES'] := LBuffer;
    LQuery.Params.Int64s['PRICE_CENTS'] := CentsOf(AService.Price);
    LQuery.Params.Int64s['CREATED_AT'] := LNow;
    LQuery.Params.Int64s['UPDATED_AT'] := LNow;
    LQuery.ExecSql; // a name the tenant has: EConstraintViolationException -> 409
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  Result := FindById(LId);
end;

function TServiceRepository.Update(const AId: string; const APatch: IServicePatch): IService;
var
  LName: IOptString;
  LCheck: TPcValidation;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  // Normalized inside the optionals, by the rules of Agenda.Normalizers: an
  // absent member stays absent, so there is no if here.
  LName := TOptionals.Normalize(APatch.Name, TNorm.DisplayName);
  // The checks, for the members that came (TPcValidation skips an absent
  // one): a 400 touches nothing.
  LCheck := TPcValidation.Create;
  LCheck.Check('name', LName, TValid.DisplayName);
  LCheck.Check('durationMinutes', APatch.DurationMinutes, FiveMinuteSteps);
  LCheck.Check('bufferMinutes', APatch.BufferMinutes, FiveMinuteSteps);
  LCheck.Check('price', APatch.Price, WholeCents);
  LCheck.RaiseIfAny;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['SERVICE.UPDATE']
      .ProcessTag('NAME', LName.HasValue)
      .ProcessTag('DURATION', APatch.DurationMinutes.HasValue)
      .ProcessTag('BUFFER', APatch.BufferMinutes.HasValue)
      .ProcessTag('PRICE', APatch.Price.HasValue)
      .ProcessTag('ACTIVE', APatch.Active.HasValue));
    // No if per member: an absent optional binds nothing (its block is gone),
    // a value binds it.
    LQuery.Params.Strings['ID'] := AId;
    LQuery.Params.Int64s['UPDATED_AT'] := TJwt.UnixNow;
    LQuery.Params.OptStrings['NAME'] := LName;
    LQuery.Params.OptStrings['NAME_KEY'] := TOptionals.Normalize(LName, TNorm.FoldForSearch);
    LQuery.Params.OptIntegers['DURATION_MINUTES'] := APatch.DurationMinutes;
    LQuery.Params.OptIntegers['BUFFER_MINUTES'] := APatch.BufferMinutes;
    LQuery.Params.OptFlags['ACTIVE'] := APatch.Active; // an INTEGER column: Flags, never Booleans
    // The one if left: the price is stored in cents, and an optional keeps
    // its type (an IOptCurrency can't become an IOptInt64).
    if APatch.Price.HasValue then
      LQuery.Params.Int64s['PRICE_CENTS'] := CentsOf(APatch.Price.Value);
    LRows := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('Service not found.');
  Result := FindById(AId);
end;

procedure TServiceRepository.Delete(const AId: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LRows: Int64;
begin
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, 'SERVICE.DELETE');
    LQuery.Params.Strings['ID'] := AId;
    LRows := LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  if LRows = 0 then
    raise ENotFoundException.Create('Service not found.');
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IServiceInsert, TServiceInsert>;
  TJsonMapper.Shared.RegisterMapping<IServicePatch, TServicePatch>;
  TJsonMapper.Shared.RegisterMapping<IService, TService>;
  TJsonMapper.Shared.RegisterMapping<IServiceFind, TServiceFind>;
  TApiSchema.Describe(TypeInfo(IServiceInsert), 'A new service of the caller''s tenant')
    .Prop('Name').Desc('Unique within the tenant, ignoring case and accents')
      .Example('Corte de cabelo').MaxLength(MAX_NAME_CHARS)
    .Prop('DurationMinutes').Desc('Multiple of 5, from 5 to 480').Example('45')
      .Minimum(MIN_DURATION_MINUTES).Maximum(MAX_DURATION_MINUTES)
    .Prop('BufferMinutes').Desc('Kept free after it; multiple of 5, 0 to 120 (default 0)')
      .Example('10').Minimum(0).Maximum(MAX_BUFFER_MINUTES)
    .Prop('Price').Desc('At most 2 decimals, 0 to 100000').Example('80.00')
      .Minimum(0).Maximum(MAX_PRICE);
  TApiSchema.Describe(TypeInfo(IServicePatch), 'The members to change; the others stay')
    .Prop('Name').Desc('Unique within the tenant; never null').MaxLength(MAX_NAME_CHARS)
    .Prop('DurationMinutes').Desc('Multiple of 5, from 5 to 480')
      .Minimum(MIN_DURATION_MINUTES).Maximum(MAX_DURATION_MINUTES)
    .Prop('BufferMinutes').Desc('Multiple of 5, 0 to 120').Minimum(0).Maximum(MAX_BUFFER_MINUTES)
    .Prop('Price').Desc('At most 2 decimals, 0 to 100000').Minimum(0).Maximum(MAX_PRICE)
    .Prop('Active').Desc('false: no longer offered');
  TApiSchema.Describe(TypeInfo(IService), 'A service of the caller''s tenant')
    .Prop('Price').Example('80.00');
  TApiSchema.Describe(TypeInfo(IServiceFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Services per page (default 20, at most 100)')
    .Prop('OrderBy').Desc(ServiceOrderSpec.DocHint)
    .Prop('Search').Desc('Part of the name, ignoring case and accents')
    .Prop('Active').Desc('true or false: only active, or only inactive, services');

end.
