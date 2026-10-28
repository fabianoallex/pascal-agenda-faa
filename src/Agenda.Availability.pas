unit Agenda.Availability;

{$I agenda.inc}

(* A professional's free slots for one service: GET
  /professionals/:id/availability?service=&date=&days=. The reads behind
  it (the DTOs: Agenda.Availability.Dtos) (FreeStartsOn, which the booking runs too, inside its
  transaction), and the reader the route uses; the computation is
  Agenda.Slots'.

  - The days are the tenant's local days (TENANTS.TIME_ZONE, an IANA name
    checked when the tenant was created), from date for days days (1 to
    MAX_AVAILABILITY_DAYS). A slot belongs to the day it starts on.
  - Each slot carries its instants in UTC ("Z") and the tenant's clock with
    its offset (local), so a client shows the right hour on both sides of a
    daylight-saving change without a time zone database of its own.
  - Busy: the professional's time off, and the appointments that aren't
    cancelled, each until its end plus the buffer its service had when it
    was booked (BUSY_UNTIL_UTC): a later change to the service doesn't move
    what is already booked.
  - An inactive professional or service is a 409, not an empty list: the
    caller asked about something that can't be booked, which differs from a
    full day.
  - Every query on a tenant's rows goes through TTenantFilter.Prepare (the
    ${TENANT} tag); the time zone comes from the catalog row of the tenant
    the token named. The reads take the caller's query, so the booking makes
    them on its own connection, after locking the professional.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalCommon.TimeZones,
  PascalJsonMapper.Json,
  PascalDb.Interfaces,
  PascalApi.Dto,
  PascalApi.Tenancy,
  Agenda.Slots,
  Agenda.Availability.Dtos;

const
  /// date at most this many days before or after today.
  MAX_DATE_DISTANCE_DAYS = 366;

type

  /// What booking a service takes, as the service says now.
  TBookable = record
    DurationMinutes, BufferMinutes: Integer;
  end;

  TAvailabilityReader = class
  private
    FScope: TTenantDataScope;
  public
    constructor Create(const AScope: TTenantDataScope);
    /// EValidationException (400) for the query; ENotFoundException for an
    /// unknown professional or service; 409 when one is inactive. ANow:
    /// Unix seconds, no slot starts before it.
    function Find(const AProfessionalId: string; const AFind: IAvailabilityFind;
      ANow: Int64): IAvailability;
  end;

/// The tenant's zone, from its catalog row (the tenant the token named).
function TenantZone(const AQuery: IQuery; const AScope: TTenantDataScope): IPcTimeZone;

/// The starts free for a service of ABookable on ADays local days of AZone
/// from ADay: AProfessionalId's working hours minus its time off and
/// appointments, read on AQuery. AExceptAppointment: one appointment left
/// out of the busy ones (a move: its own time is free to it).
function FreeStartsOn(const AQuery: IQuery; const AScope: TTenantDataScope;
  const AZone: IPcTimeZone; const AProfessionalId: string; const ABookable: TBookable;
  const ADay: TPcLocalDateTime; ADays: Integer; ANow: Int64;
  const AExceptAppointment: string = ''): TSlotStarts;

implementation

uses
  SysUtils,
  PascalCommon.Validators,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalDb.SqlLoader,
  Agenda.Times,
  Agenda.Appointments.Dtos;

const
  DAY_SECONDS = 86400;

{ reads }

function TenantZone(const AQuery: IQuery; const AScope: TTenantDataScope): IPcTimeZone;
var
  LResult: IQueryResult;
begin
  AQuery.Sql := AScope.Factory.SqlLoader['TENANT.TIME_ZONE'].SQL;
  AQuery.Params.Strings['ID'] := AScope.Discriminator;
  LResult := AQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Tenant not found.');
  Result := PcTimeZones.Find(LResult.Strings['TIME_ZONE']);
end;

procedure RequireActiveProfessional(const AQuery: IQuery; const AScope: TTenantDataScope;
  const AId: string);
var
  LResult: IQueryResult;
begin
  TTenantFilter.Prepare(AQuery, AScope, 'PROFESSIONAL.BY_ID');
  AQuery.Params.Strings['ID'] := AId;
  LResult := AQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Professional not found.');
  if not LResult.Booleans['ACTIVE'] then
    raise EHttpException.Create(409, 'The professional is inactive.', CODE_PROFESSIONAL_INACTIVE);
end;

function ActiveService(const AQuery: IQuery; const AScope: TTenantDataScope;
  const AId: string): TBookable;
var
  LResult: IQueryResult;
begin
  TTenantFilter.Prepare(AQuery, AScope, 'SERVICE.BY_ID');
  AQuery.Params.Strings['ID'] := AId;
  LResult := AQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Service not found.');
  if not LResult.Booleans['ACTIVE'] then
    raise EHttpException.Create(409, 'The service is inactive.', CODE_SERVICE_INACTIVE);
  Result.DurationMinutes := LResult.Integers['DURATION_MINUTES'];
  Result.BufferMinutes := LResult.Integers['BUFFER_MINUTES'];
end;

function ReadWeek(const AQuery: IQuery; const AScope: TTenantDataScope;
  const AProfessionalId: string): TClockIntervalArray;
var
  LResult: IQueryResult;
  LCount: Integer;
begin
  TTenantFilter.Prepare(AQuery, AScope, 'WORKING_HOURS.BY_PROFESSIONAL');
  AQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
  LResult := AQuery.Open;
  Result := nil;
  LCount := 0;
  while not LResult.Eof do
  begin
    if LCount = Length(Result) then
      SetLength(Result, LCount * 2 + 8);
    Result[LCount].Weekday := LResult.Integers['WEEKDAY'];
    Result[LCount].StartMinute := LResult.Integers['START_MINUTE'];
    Result[LCount].EndMinute := LResult.Integers['END_MINUTE'];
    Inc(LCount);
    LResult.Next;
  end;
  SetLength(Result, LCount);
end;

// The spans of ASql's rows (START_UTC, END_UTC) that meet [AFrom, ATo),
// appended to ASpans. The query is prepared and its own parameters bound.
procedure AddSpans(const AQuery: IQuery; const AProfessionalId: string; AFrom, ATo: Int64;
  var ASpans: TSpanArray);
var
  LResult: IQueryResult;
  LCount: Integer;
begin
  AQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
  AQuery.Params.Int64s['FROM_UTC'] := AFrom;
  AQuery.Params.Int64s['TO_UTC'] := ATo;
  LResult := AQuery.Open;
  LCount := Length(ASpans);
  while not LResult.Eof do
  begin
    SetLength(ASpans, LCount + 1);
    ASpans[LCount].StartUtc := LResult.Int64s['START_UTC'];
    ASpans[LCount].EndUtc := LResult.Int64s['END_UTC'];
    Inc(LCount);
    LResult.Next;
  end;
end;

function FreeStartsOn(const AQuery: IQuery; const AScope: TTenantDataScope;
  const AZone: IPcTimeZone; const AProfessionalId: string; const ABookable: TBookable;
  const ADay: TPcLocalDateTime; ADays: Integer; ANow: Int64;
  const AExceptAppointment: string): TSlotStarts;
var
  LFrom, LTo: Int64;
  LWorking, LBusy: TSpanArray;
begin
  DaysWindow(AZone, ADay, ADays, LFrom, LTo);
  LWorking := WorkingSpans(AZone, ReadWeek(AQuery, AScope, AProfessionalId), ADay, ADays);
  // The busy spans a start inside the window can meet: its service and
  // buffer end at most a day after the window.
  LBusy := nil;
  TTenantFilter.Prepare(AQuery, AScope, 'TIME_OFF.OVERLAPPING');
  AddSpans(AQuery, AProfessionalId, LFrom - DAY_SECONDS, LTo + DAY_SECONDS, LBusy);
  TTenantFilter.Prepare(AQuery, AScope, AScope.Factory.SqlLoader['APPOINTMENT.BUSY']
    .ProcessTag('EXCEPT', AExceptAppointment <> ''));
  AQuery.Params.Strings['CANCELLED'] := STATUS_CANCELLED;
  if AExceptAppointment <> '' then
    AQuery.Params.Strings['EXCEPT_ID'] := AExceptAppointment;
  AddSpans(AQuery, AProfessionalId, LFrom - DAY_SECONDS, LTo + DAY_SECONDS, LBusy);
  Result := FreeSlots(LWorking, LBusy, ABookable.DurationMinutes, ABookable.BufferMinutes,
    SLOT_STEP_MINUTES, LFrom, LTo, ANow);
end;

{ TAvailabilityReader }

constructor TAvailabilityReader.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

function TAvailabilityReader.Find(const AProfessionalId: string;
  const AFind: IAvailabilityFind; ANow: Int64): IAvailability;
var
  LCheck: TPcValidation;
  LDay: TPcLocalDateTime;
  LDays: Integer;
  LZone: IPcTimeZone;
  LBookable: TBookable;
  LFrom, LTo: Int64;
  LStarts: TSlotStarts;
  LSlots: TAvailableSlotArray;
  LSlot: TAvailableSlot;
  LAvailability: TAvailability;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  I: Integer;
begin
  // service and date are required and days' range is the document's
  // (Minimum, Maximum): both enforced when the query was read
  // (THorseQueryParams.Read, pascal-api-infra-faa 0.23.0). What it can't say
  // is checked here.
  LCheck := TPcValidation.Create;
  if not TryParseLocalDate(AFind.Date, LDay) then
    LCheck.Fail('date', CODE_INVALID_DATE, '"date" must be a date, YYYY-MM-DD.');
  LCheck.RaiseIfAny;
  LDays := AFind.Days.ValueOr(1);

  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LZone := TenantZone(LQuery, FScope);
  DaysWindow(LZone, LDay, LDays, LFrom, LTo);
  if (LFrom > ANow + Int64(MAX_DATE_DISTANCE_DAYS) * DAY_SECONDS) or
    (LTo < ANow - Int64(MAX_DATE_DISTANCE_DAYS) * DAY_SECONDS) then
    raise EValidationException.Create(Format('"date" must be within %d days of today.',
      [MAX_DATE_DISTANCE_DAYS]), CODE_DATE_OUT_OF_RANGE);
  RequireActiveProfessional(LQuery, FScope, AProfessionalId);
  LBookable := ActiveService(LQuery, FScope, Trim(AFind.Service));
  LStarts := FreeStartsOn(LQuery, FScope, LZone, AProfessionalId, LBookable, LDay, LDays, ANow);

  LSlots := nil;
  SetLength(LSlots, Length(LStarts));
  for I := 0 to High(LStarts) do
  begin
    LSlot := TAvailableSlot.Create;
    LSlots[I] := LSlot;
    LSlot.StartsAt := UnixToUtc(LStarts[I]);
    LSlot.EndsAt := UnixToUtc(LStarts[I] + Int64(LBookable.DurationMinutes) * 60);
    LSlot.Local := PcLocalIsoString(LZone, LStarts[I]);
  end;
  LAvailability := TAvailability.Create;
  Result := LAvailability;
  LAvailability.Professional := AProfessionalId;
  LAvailability.Service := Trim(AFind.Service);
  LAvailability.TimeZone := LZone.Name;
  LAvailability.Slots := LSlots;
end;

end.
