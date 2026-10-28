unit Agenda.Services.Dtos;

{$I agenda.inc}

{ Services: a new one, a change, a service and the list's filter, their
  limits, and the ordering the list allows.

  Shared by the api and the desktop client: it needs pascal-common-faa,
  pascal-jsonmapper-faa and pascal-api-infra-faa's PascalApi.Dto and
  PascalApi.OpenApi only, never the database. The TApiSchema.Describe
  below gives the server's OpenAPI document and the limits both sides
  check (TApiSchema.Check). }

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalApi.OrderBy,
  PascalApi.Dto;

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

/// The fields the list may be ordered by (orderBy).
function ServiceOrderSpec: TOrderBySpec;

implementation

uses
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi;

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
