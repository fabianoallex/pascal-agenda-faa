unit Agenda.Availability.Dtos;

{$I agenda.inc}

{ Free slots: the query, a slot and the answer, the longest span a query
  may ask for, and the error codes of the date and of an inactive
  professional or service.

  Shared by the api and the desktop client: it needs pascal-common-faa,
  pascal-jsonmapper-faa and pascal-api-infra-faa's PascalApi.Dto and
  PascalApi.OpenApi only, never the database. The TApiSchema.Describe
  below gives the server's OpenAPI document and the limits both sides
  check (TApiSchema.Check). }

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalApi.Dto;

const
  CODE_INVALID_DATE = 'invalid_date';
  CODE_DATE_OUT_OF_RANGE = 'date_out_of_range';
  CODE_SERVICE_INACTIVE = 'service_inactive';
  CODE_PROFESSIONAL_INACTIVE = 'professional_inactive';
  /// days: at most this many from date.
  MAX_AVAILABILITY_DAYS = 14;

type
  /// GET .../availability: service (required), date (required, YYYY-MM-DD,
  /// the tenant's local day), days (1 to MAX_AVAILABILITY_DAYS, default 1).
  IAvailabilityFind = interface(IDTOBase)
    ['{7163E4CD-A06A-44F8-8AD8-DD0A50AB0871}']
    function GetService: string;
    function GetDate: string;
    function GetDays: IOptInteger;
    property Service: string read GetService;
    property Date: string read GetDate;
    property Days: IOptInteger read GetDays;
  end;

  IAvailableSlot = interface(IDTOBase)
    ['{4F96559C-82B6-4033-9EA6-A59CF145312A}']
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetLocal: string;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property EndsAt: TUtcDateTime read GetEndsAt;
    property Local: string read GetLocal;
  end;

  TAvailableSlotArray = TArray<IAvailableSlot>;

  IAvailability = interface(IResponseDTOBase)
    ['{12EC4B10-6D79-4E34-93BC-28E5C2F59CC2}']
    function GetProfessional: string;
    function GetService: string;
    function GetTimeZone: string;
    function GetSlots: TAvailableSlotArray;
    property Professional: string read GetProfessional;
    property Service: string read GetService;
    property TimeZone: string read GetTimeZone;
    property Slots: TAvailableSlotArray read GetSlots;
  end;

{$M+}
  TAvailabilityFind = class(TDTOBase, IAvailabilityFind)
  private
    FService, FDate: string;
    FDays: IOptInteger;
  public
    function GetService: string;
    function GetDate: string;
    function GetDays: IOptInteger;
  published
    property Service: string read FService write FService;
    property Date: string read FDate write FDate;
    property Days: IOptInteger read FDays write FDays;
  end;

  TAvailableSlot = class(TDTOBase, IAvailableSlot)
  private
    FStartsAt, FEndsAt: TUtcDateTime;
    FLocal: string;
  public
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetLocal: string;
  published
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property EndsAt: TUtcDateTime read FEndsAt write FEndsAt;
    property Local: string read FLocal write FLocal;
  end;

  TAvailability = class(TResponseDTOBase, IAvailability)
  private
    FProfessional, FService, FTimeZone: string;
    FSlots: TAvailableSlotArray;
  public
    function GetProfessional: string;
    function GetService: string;
    function GetTimeZone: string;
    function GetSlots: TAvailableSlotArray;
  published
    property Professional: string read FProfessional write FProfessional;
    property Service: string read FService write FService;
    property TimeZone: string read FTimeZone write FTimeZone;
    property Slots: TAvailableSlotArray read FSlots write FSlots;
  end;
{$M-}

implementation

uses
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi;

{ DTOs }

function TAvailabilityFind.GetService: string;
begin
  Result := FService;
end;

function TAvailabilityFind.GetDate: string;
begin
  Result := FDate;
end;

function TAvailabilityFind.GetDays: IOptInteger;
begin
  Result := TOptionals.Safe(FDays);
end;

function TAvailableSlot.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TAvailableSlot.GetEndsAt: TUtcDateTime;
begin
  Result := FEndsAt;
end;

function TAvailableSlot.GetLocal: string;
begin
  Result := FLocal;
end;

function TAvailability.GetProfessional: string;
begin
  Result := FProfessional;
end;

function TAvailability.GetService: string;
begin
  Result := FService;
end;

function TAvailability.GetTimeZone: string;
begin
  Result := FTimeZone;
end;

function TAvailability.GetSlots: TAvailableSlotArray;
begin
  Result := FSlots;
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IAvailabilityFind, TAvailabilityFind>;
  TJsonMapper.Shared.RegisterMapping<IAvailableSlot, TAvailableSlot>;
  TJsonMapper.Shared.RegisterMapping<IAvailability, TAvailability>;
  TApiSchema.Describe(TypeInfo(IAvailabilityFind))
    .Prop('Service').Desc('The service''s id (required)')
    .Prop('Date').Desc('The first day, YYYY-MM-DD, the tenant''s local day (required)')
      .Example('2026-11-02')
    .Prop('Days').Desc('How many days from date (default 1)').Minimum(1)
      .Maximum(MAX_AVAILABILITY_DAYS);
  TApiSchema.Describe(TypeInfo(IAvailableSlot), 'A start the service fits')
    .Prop('StartsAt').Desc('UTC').Format('date-time')
    .Prop('EndsAt').Desc('UTC: the service''s end, its buffer not counted').Format('date-time')
    .Prop('Local').Desc('The start on the tenant''s clock, with its offset')
      .Example('2026-11-02T09:00:00-03:00');
  TApiSchema.Describe(TypeInfo(IAvailability), 'Free slots of a professional for a service')
    .Prop('TimeZone').Desc('The tenant''s IANA time zone').Example('America/Sao_Paulo')
    .Prop('Slots').Desc('By start; every 15 minutes where the service fits');

end.
