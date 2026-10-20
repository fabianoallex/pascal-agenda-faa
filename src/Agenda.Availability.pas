unit Agenda.Availability;

{$I agenda.inc}

(* A professional's free slots for one service: GET
  /professionals/:id/availability?service=&date=&days=. DTOs and the reads
  behind them; the computation is Agenda.Slots'.

  - The days are the tenant's local days (TENANTS.TIME_ZONE, an IANA name
    checked when the tenant was created), from date for days days (1 to
    MAX_AVAILABILITY_DAYS). A slot belongs to the day it starts on.
  - Each slot carries its instants in UTC ("Z") and the tenant's clock with
    its offset (local), so a client shows the right hour on both sides of a
    daylight-saving change without a time zone database of its own.
  - Busy: the professional's time off; appointments join when booking does
    (M2's next step).
  - An inactive professional or service is a 409, not an empty list: the
    caller asked about something that can't be booked, which differs from a
    full day.
  - Every query on a tenant's rows goes through TTenantFilter.Prepare (the
    ${TENANT} tag); the time zone comes from the catalog row of the tenant
    the token named.

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalApi.Dto,
  PascalApi.Tenancy;

const
  CODE_INVALID_DATE = 'invalid_date';
  CODE_DATE_OUT_OF_RANGE = 'date_out_of_range';
  CODE_SERVICE_INACTIVE = 'service_inactive';
  CODE_PROFESSIONAL_INACTIVE = 'professional_inactive';
  /// date at most this many days before or after today.
  MAX_DATE_DISTANCE_DAYS = 366;

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

implementation

uses
  SysUtils,
  PascalCommon.TimeZones,
  PascalCommon.Validators,
  PascalDb.Interfaces,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  Agenda.Times,
  Agenda.Slots;

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

{ TAvailabilityReader }

constructor TAvailabilityReader.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

type
  TBookable = record
    DurationMinutes, BufferMinutes: Integer;
  end;

// The tenant's zone, from its catalog row (the tenant the token named).
function TenantZone(const AScope: TTenantDataScope): IPcTimeZone;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := AScope.Factory.SqlLoader['TENANT.TIME_ZONE'].SQL;
  LQuery.Params.Strings['ID'] := AScope.Discriminator;
  LResult := LQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Tenant not found.');
  Result := PcTimeZones.Find(LResult.Strings['TIME_ZONE']);
end;

procedure RequireActiveProfessional(const AScope: TTenantDataScope; const AId: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, AScope, 'PROFESSIONAL.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Professional not found.');
  if not LResult.Booleans['ACTIVE'] then
    raise EHttpException.Create(409, 'The professional is inactive.', CODE_PROFESSIONAL_INACTIVE);
end;

function ActiveService(const AScope: TTenantDataScope; const AId: string): TBookable;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, AScope, 'SERVICE.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Service not found.');
  if not LResult.Booleans['ACTIVE'] then
    raise EHttpException.Create(409, 'The service is inactive.', CODE_SERVICE_INACTIVE);
  Result.DurationMinutes := LResult.Integers['DURATION_MINUTES'];
  Result.BufferMinutes := LResult.Integers['BUFFER_MINUTES'];
end;

function ReadWeek(const AScope: TTenantDataScope; const AProfessionalId: string): TClockIntervalArray;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LCount: Integer;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, AScope, 'WORKING_HOURS.BY_PROFESSIONAL');
  LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
  LResult := LQuery.Open;
  Result := nil;
  SetLength(Result, LResult.RecordCount);
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

// Time off that meets [AFrom, ATo).
function ReadBusy(const AScope: TTenantDataScope; const AProfessionalId: string;
  AFrom, ATo: Int64): TSpanArray;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LCount: Integer;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, AScope, 'TIME_OFF.OVERLAPPING');
  LQuery.Params.Strings['PROFESSIONAL_ID'] := AProfessionalId;
  LQuery.Params.Int64s['FROM_UTC'] := AFrom;
  LQuery.Params.Int64s['TO_UTC'] := ATo;
  LResult := LQuery.Open;
  Result := nil;
  LCount := 0;
  while not LResult.Eof do
  begin
    if LCount = Length(Result) then
      SetLength(Result, LCount * 2 + 8);
    Result[LCount].StartUtc := LResult.Int64s['START_UTC'];
    Result[LCount].EndUtc := LResult.Int64s['END_UTC'];
    Inc(LCount);
    LResult.Next;
  end;
  SetLength(Result, LCount);
end;

function TAvailabilityReader.Find(const AProfessionalId: string;
  const AFind: IAvailabilityFind; ANow: Int64): IAvailability;
const
  DAY = 86400;
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
  I: Integer;
begin
  // days' range is the document's (Minimum, Maximum), enforced when the
  // query was read; what it can't say is checked here, every member at once.
  LCheck := TPcValidation.Create;
  if Trim(AFind.Service) = '' then
    LCheck.Fail('service', PC_VALIDATION_REQUIRED, '"service" is required.');
  if AFind.Date = '' then
    LCheck.Fail('date', PC_VALIDATION_REQUIRED, '"date" is required.')
  else if not TryParseLocalDate(AFind.Date, LDay) then
    LCheck.Fail('date', CODE_INVALID_DATE, '"date" must be a date, YYYY-MM-DD.');
  LCheck.RaiseIfAny;
  LDays := AFind.Days.ValueOr(1);

  LZone := TenantZone(FScope);
  DaysWindow(LZone, LDay, LDays, LFrom, LTo);
  if (LFrom > ANow + Int64(MAX_DATE_DISTANCE_DAYS) * DAY) or
    (LTo < ANow - Int64(MAX_DATE_DISTANCE_DAYS) * DAY) then
    raise EValidationException.Create(Format('"date" must be within %d days of today.',
      [MAX_DATE_DISTANCE_DAYS]), CODE_DATE_OUT_OF_RANGE);
  RequireActiveProfessional(FScope, AProfessionalId);
  LBookable := ActiveService(FScope, Trim(AFind.Service));

  // The busy spans a start inside the window can meet: its service and
  // buffer end at most a day after the window.
  LStarts := FreeSlots(WorkingSpans(LZone, ReadWeek(FScope, AProfessionalId), LDay, LDays),
    ReadBusy(FScope, AProfessionalId, LFrom - DAY, LTo + DAY),
    LBookable.DurationMinutes, LBookable.BufferMinutes, SLOT_STEP_MINUTES, LFrom, LTo, ANow);

  LSlots := nil;
  SetLength(LSlots, Length(LStarts));
  for I := 0 to High(LStarts) do
  begin
    LSlot := TAvailableSlot.Create;
    LSlots[I] := LSlot;
    LSlot.StartsAt := UnixToUtc(LStarts[I]);
    LSlot.EndsAt := UnixToUtc(LStarts[I] + Int64(LBookable.DurationMinutes) * 60);
    LSlot.Local := LocalIso(LZone, LStarts[I]);
  end;
  LAvailability := TAvailability.Create;
  Result := LAvailability;
  LAvailability.Professional := AProfessionalId;
  LAvailability.Service := Trim(AFind.Service);
  LAvailability.TimeZone := LZone.Name;
  LAvailability.Slots := LSlots;
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
