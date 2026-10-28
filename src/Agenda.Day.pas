unit Agenda.Day;

{$I agenda.inc}

(* One day of the tenant's agenda: GET /agenda/day?date=&professional=
  (M5, decision 3). The MCP tool "the day" and the desktop client's main
  view (M6); its DTOs are in Agenda.Day.Dtos.

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
  PascalApi.Tenancy,
  Agenda.Day.Dtos;

const
  /// The day's statement (Agenda.Schema).
  DAY_SQL_APPOINTMENTS = 'APPOINTMENT.DAY';

type

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
  Agenda.Availability,
  Agenda.Availability.Dtos;

const
  DAY_SECONDS = 86400;

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

end.
