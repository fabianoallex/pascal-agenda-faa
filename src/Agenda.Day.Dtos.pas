unit Agenda.Day.Dtos;

{$I agenda.inc}

{ One day of the agenda: the query, an appointment of the day with its
  names, and the answer.

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

type
  /// GET /agenda/day: date (required, YYYY-MM-DD, the tenant's local day),
  /// professional (optional, an id).
  IDayFind = interface(IDTOBase)
    ['{B6F2B8CF-3B6B-4BD2-B1B4-3AFFC9A9E631}']
    function GetDate: string;
    function GetProfessional: IOptString;
    property Date: string read GetDate;
    property Professional: IOptString read GetProfessional;
  end;

  IDayAppointment = interface(IDTOBase)
    ['{F9D84E90-741B-4953-AE17-5BB2B691350B}']
    function GetId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetLocalStart: string;
    function GetLocalEnd: string;
    function GetStatus: string;
    function GetVersion: Integer;
    function GetProfessionalId: string;
    function GetProfessionalName: string;
    function GetServiceId: string;
    function GetServiceName: string;
    function GetCustomerId: string;
    function GetCustomerName: string;
    property Id: string read GetId;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property EndsAt: TUtcDateTime read GetEndsAt;
    property LocalStart: string read GetLocalStart;
    property LocalEnd: string read GetLocalEnd;
    property Status: string read GetStatus;
    property Version: Integer read GetVersion;
    property ProfessionalId: string read GetProfessionalId;
    property ProfessionalName: string read GetProfessionalName;
    property ServiceId: string read GetServiceId;
    property ServiceName: string read GetServiceName;
    property CustomerId: string read GetCustomerId;
    property CustomerName: string read GetCustomerName;
  end;

  TDayAppointmentArray = TArray<IDayAppointment>;

  IDay = interface(IResponseDTOBase)
    ['{F2D637BB-B3E1-4AC0-8EDB-5E9DE114EADC}']
    function GetDate: string;
    function GetTimeZone: string;
    function GetAppointments: TDayAppointmentArray;
    property Date: string read GetDate;
    property TimeZone: string read GetTimeZone;
    property Appointments: TDayAppointmentArray read GetAppointments;
  end;

{$M+}
  TDayFind = class(TDTOBase, IDayFind)
  private
    FDate: string;
    FProfessional: IOptString;
  public
    function GetDate: string;
    function GetProfessional: IOptString;
  published
    property Date: string read FDate write FDate;
    property Professional: IOptString read FProfessional write FProfessional;
  end;

  TDayAppointment = class(TDTOBase, IDayAppointment)
  private
    FId, FLocalStart, FLocalEnd, FStatus: string;
    FStartsAt, FEndsAt: TUtcDateTime;
    FVersion: Integer;
    FProfessionalId, FProfessionalName, FServiceId, FServiceName: string;
    FCustomerId, FCustomerName: string;
  public
    function GetId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetLocalStart: string;
    function GetLocalEnd: string;
    function GetStatus: string;
    function GetVersion: Integer;
    function GetProfessionalId: string;
    function GetProfessionalName: string;
    function GetServiceId: string;
    function GetServiceName: string;
    function GetCustomerId: string;
    function GetCustomerName: string;
  published
    property Id: string read FId write FId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property EndsAt: TUtcDateTime read FEndsAt write FEndsAt;
    property LocalStart: string read FLocalStart write FLocalStart;
    property LocalEnd: string read FLocalEnd write FLocalEnd;
    property Status: string read FStatus write FStatus;
    property Version: Integer read FVersion write FVersion;
    property ProfessionalId: string read FProfessionalId write FProfessionalId;
    property ProfessionalName: string read FProfessionalName write FProfessionalName;
    property ServiceId: string read FServiceId write FServiceId;
    property ServiceName: string read FServiceName write FServiceName;
    property CustomerId: string read FCustomerId write FCustomerId;
    property CustomerName: string read FCustomerName write FCustomerName;
  end;

  TDay = class(TResponseDTOBase, IDay)
  private
    FDate, FTimeZone: string;
    FAppointments: TDayAppointmentArray;
  public
    function GetDate: string;
    function GetTimeZone: string;
    function GetAppointments: TDayAppointmentArray;
  published
    property Date: string read FDate write FDate;
    property TimeZone: string read FTimeZone write FTimeZone;
    property Appointments: TDayAppointmentArray read FAppointments write FAppointments;
  end;
{$M-}

implementation

uses
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi;

{ DTOs }

function TDayFind.GetDate: string;
begin
  Result := FDate;
end;

function TDayFind.GetProfessional: IOptString;
begin
  Result := TOptionals.Safe(FProfessional);
end;

function TDayAppointment.GetId: string;
begin
  Result := FId;
end;

function TDayAppointment.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TDayAppointment.GetEndsAt: TUtcDateTime;
begin
  Result := FEndsAt;
end;

function TDayAppointment.GetLocalStart: string;
begin
  Result := FLocalStart;
end;

function TDayAppointment.GetLocalEnd: string;
begin
  Result := FLocalEnd;
end;

function TDayAppointment.GetStatus: string;
begin
  Result := FStatus;
end;

function TDayAppointment.GetVersion: Integer;
begin
  Result := FVersion;
end;

function TDayAppointment.GetProfessionalId: string;
begin
  Result := FProfessionalId;
end;

function TDayAppointment.GetProfessionalName: string;
begin
  Result := FProfessionalName;
end;

function TDayAppointment.GetServiceId: string;
begin
  Result := FServiceId;
end;

function TDayAppointment.GetServiceName: string;
begin
  Result := FServiceName;
end;

function TDayAppointment.GetCustomerId: string;
begin
  Result := FCustomerId;
end;

function TDayAppointment.GetCustomerName: string;
begin
  Result := FCustomerName;
end;

function TDay.GetDate: string;
begin
  Result := FDate;
end;

function TDay.GetTimeZone: string;
begin
  Result := FTimeZone;
end;

function TDay.GetAppointments: TDayAppointmentArray;
begin
  Result := FAppointments;
end;

initialization
  TJsonMapper.Shared.RegisterMapping<IDayFind, TDayFind>;
  TJsonMapper.Shared.RegisterMapping<IDayAppointment, TDayAppointment>;
  TJsonMapper.Shared.RegisterMapping<IDay, TDay>;
  TApiSchema.Describe(TypeInfo(IDayFind))
    .Prop('Date').Desc('The day, YYYY-MM-DD, the tenant''s local day (required)')
      .Example('2026-11-02')
    .Prop('Professional').Desc('One professional''s id (optional; all when left out)');
  TApiSchema.Describe(TypeInfo(IDayAppointment), 'An appointment of the day')
    .Prop('StartsAt').Desc('UTC').Format('date-time')
    .Prop('EndsAt').Desc('UTC').Format('date-time')
    .Prop('LocalStart').Desc('The start on the tenant''s clock, with its offset')
      .Example('2026-11-02T09:00:00-03:00')
    .Prop('LocalEnd').Desc('The end on the tenant''s clock, with its offset')
    .Prop('Status').Desc('booked, confirmed, cancelled, done or no_show')
    .Prop('Version').Desc('For If-Match, in quotes: "3"');
  TApiSchema.Describe(TypeInfo(IDay), 'One day of the tenant''s agenda')
    .Prop('TimeZone').Desc('The tenant''s IANA time zone').Example('America/Sao_Paulo')
    .Prop('Appointments').Desc('Those that start on the day, any status, by start');

end.
