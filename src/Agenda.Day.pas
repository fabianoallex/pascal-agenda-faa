unit Agenda.Day;

{$I agenda.inc}

(* One day of the tenant's agenda: GET /agenda/day?date=&professional=
  (M5, decision 3). The MCP tool "the day" and the desktop client's main
  view (M6).

  - The day is the tenant's local day (TENANTS.TIME_ZONE): the appointments
    that start on it, in any status, by start, then the professional's
    name. professional (optional) keeps one professional's; an unknown one
    is a 404, as on the other routes that name one.
  - Each appointment carries the professional's, the service's and the
    customer's names next to their ids, its instants in UTC and its start
    and end on the tenant's clock with the offset, and its version (what
    If-Match sends back to move or cancel it).
  - date within MAX_DATE_DISTANCE_DAYS of today, as the availability.
  - Every table of the join goes through the tenant filter
    (${TENANT.alias}), as NOTIFY.APPOINTMENT does.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalApi.Dto,
  PascalApi.Tenancy;

const
  /// The day's statement (Agenda.Schema).
  DAY_SQL_APPOINTMENTS = 'APPOINTMENT.DAY';

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

  TDayReader = class
  private
    FScope: TTenantDataScope;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// EValidationException (400) for the date; ENotFoundException for an
    /// unknown professional. ANow: Unix seconds, for the date's range.
    function Find(const AFind: IDayFind; ANow: Int64): IDay;
  end;

implementation

uses
  SysUtils,
  PascalCommon.TimeZones,
  PascalCommon.Validators,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalApi.OpenApi,
  PascalApi.Http,
  Agenda.Times,
  Agenda.Slots,
  Agenda.Availability;

const
  DAY_SECONDS = 86400;

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

{ TDayReader }

constructor TDayReader.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

function TDayReader.Find(const AFind: IDayFind; ANow: Int64): IDay;
var
  LCheck: TPcValidation;
  LDay: TPcLocalDateTime;
  LZone: IPcTimeZone;
  LFrom, LTo, LStart, LEnd: Int64;
  LProfessional: string;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LItems: TDayAppointmentArray;
  LItem: TDayAppointment;
  LDayDto: TDay;
  LCount: Integer;
begin
  // date is required (THorseQueryParams.Read); its form is checked here.
  LCheck := TPcValidation.Create;
  if not TryParseLocalDate(AFind.Date, LDay) then
    LCheck.Fail('date', CODE_INVALID_DATE, '"date" must be a date, YYYY-MM-DD.');
  LCheck.RaiseIfAny;
  LProfessional := Trim(AFind.Professional.ValueOr(''));

  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LZone := TenantZone(LQuery, FScope);
  DaysWindow(LZone, LDay, 1, LFrom, LTo);
  if (LFrom > ANow + Int64(MAX_DATE_DISTANCE_DAYS) * DAY_SECONDS) or
    (LTo < ANow - Int64(MAX_DATE_DISTANCE_DAYS) * DAY_SECONDS) then
    raise EValidationException.Create(Format('"date" must be within %d days of today.',
      [MAX_DATE_DISTANCE_DAYS]), CODE_DATE_OUT_OF_RANGE);
  if LProfessional <> '' then
  begin
    TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.BY_ID');
    LQuery.Params.Strings['ID'] := LProfessional;
    if LQuery.Open.Eof then
      raise ENotFoundException.Create('Professional not found.');
  end;

  TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader[DAY_SQL_APPOINTMENTS]
    .ProcessTag('PROFESSIONAL', LProfessional <> ''));
  LQuery.Params.Int64s['FROM_UTC'] := LFrom;
  LQuery.Params.Int64s['TO_UTC'] := LTo;
  if LProfessional <> '' then
    LQuery.Params.Strings['PROFESSIONAL_ID'] := LProfessional;
  LResult := LQuery.Open;
  LItems := nil;
  LCount := 0;
  while not LResult.Eof do
  begin
    if LCount = Length(LItems) then
      SetLength(LItems, LCount * 2 + 8);
    LItem := TDayAppointment.Create;
    LItems[LCount] := LItem;
    Inc(LCount);
    LStart := LResult.Int64s['START_UTC'];
    LEnd := LResult.Int64s['END_UTC'];
    LItem.Id := LResult.Strings['ID'];
    LItem.StartsAt := UnixToUtc(LStart);
    LItem.EndsAt := UnixToUtc(LEnd);
    LItem.LocalStart := PcLocalIsoString(LZone, LStart);
    LItem.LocalEnd := PcLocalIsoString(LZone, LEnd);
    LItem.Status := LResult.Strings['STATUS'];
    LItem.Version := LResult.Integers['VERSION'];
    LItem.ProfessionalId := LResult.Strings['PROFESSIONAL_ID'];
    LItem.ProfessionalName := LResult.Strings['PROFESSIONAL_NAME'];
    LItem.ServiceId := LResult.Strings['SERVICE_ID'];
    LItem.ServiceName := LResult.Strings['SERVICE_NAME'];
    LItem.CustomerId := LResult.Strings['CUSTOMER_ID'];
    LItem.CustomerName := LResult.Strings['CUSTOMER_NAME'];
    LResult.Next;
  end;
  SetLength(LItems, LCount);

  LDayDto := TDay.Create;
  Result := LDayDto;
  LDayDto.Date := Trim(AFind.Date);
  LDayDto.TimeZone := LZone.Name;
  LDayDto.Appointments := LItems;
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
