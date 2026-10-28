unit Agenda.Professionals.Dtos;

{$I agenda.inc}

{ Professionals: a new one, a change, a professional and the list's
  filter, and the ordering the list allows.

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

/// The fields the list may be ordered by (orderBy).
function ProfessionalOrderSpec: TOrderBySpec;

implementation

uses
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi;

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
