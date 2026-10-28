unit Agenda.Customers.Dtos;

{$I agenda.inc}

{ Customers: a new one, a change, a customer and the list's filter, and
  the ordering the list allows.

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

/// The fields the list may be ordered by (orderBy).
function CustomerOrderSpec: TOrderBySpec;

implementation

uses
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi;

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
