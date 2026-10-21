unit Agenda.Appointments;

{$I agenda.inc}

(* Appointments: a customer booked with a professional for a service at an
  instant. DTOs, the ordering clients may ask for, and a repository on a
  tenant's scope: book, read, change (PATCH) and cancel.

  - No double booking, the database's word: the booking runs in one
    transaction that starts by touching the professional's row
    (PROFESSIONAL.TOUCH: on PostgreSQL a row lock, on SQLite the one write
    lock), then computes that day's free starts on the same connection
    (Agenda.Availability's FreeStartsOn: working hours minus time off and
    the appointments already there) and inserts only if the start is one of
    them. Two requests for one slot: the second waits for the first's commit
    and then finds the slot taken (409 slot_unavailable). Time off and a new
    week touch the same row, so they can't slip in between either.
  - So a start must be a slot the availability route would list: inside the
    working hours, on the 15-minute grid of its span, not before now, with
    the service and its buffer clear of everything busy.
  - The row keeps what the booking took: END_UTC (the service's end) and
    BUSY_UNTIL_UTC (plus its buffer); a later change to the service doesn't
    move it. STATUS starts as booked, VERSION as 1.
  - Changes need If-Match (pascal-api-infra-faa's PascalApi.Preconditions):
    the ETag is the version in
    quotes, sent with every appointment read, booked or changed. Absent is a
    428, another version a 412. The row is read first (404, the If-Match
    check, the rules), then written by an UPDATE that also names the version
    read: a change that landed in between makes it match no row, a 412.
  - PATCH moves the start (startsAt) and/or sets the status (confirmed, done,
    no_show). Only a booked or confirmed appointment changes (409
    appointment_closed); done and no_show only once it has started (409
    not_started). A move is a booking's check again, in the same kind of
    transaction (the professional's row first, the slot lock in front), on
    the new start's local day, with the appointment's own busy span left
    out; it keeps the duration and buffer it was booked with.
  - Cancel (its own route, not a status in PATCH): booked or confirmed, and
    no later than the tenant's notice before the start
    (TENANTS.CANCEL_NOTICE_HOURS; 409 cancel_notice_passed).
  - The body names the professional, the service and the customer by id;
    one that the tenant doesn't have is a 400 naming its member, every one
    in the same answer. An inactive professional or service is a 409, as in
    the availability route.
  - Optionally, a slot lock in front (pascal-redis-faa's TRedisLock): requests
    for the same professional and start meet there first, and the ones that
    don't get it (rlBusy) are a 409 without reaching the database. Released
    after the commit; without it (no REDIS_HOST, or rlUnavailable: Redis
    down) the transaction alone decides, the same way.
  - Every query goes through TTenantFilter.Prepare (the ${TENANT} tag); the
    foreign keys keep a professional, service or customer with appointments
    from being deleted (409).

  This comment uses parenthesis-asterisk: it quotes ${TENANT}, whose brace
  would close a brace comment. *)

interface

uses
  PascalCommon.Optionals,
  PascalJsonMapper.Json,
  PascalDb.Paging,
  PascalApi.OrderBy,
  PascalApi.Dto,
  PascalApi.Tenancy,
  Redis.Lock;

const
  STATUS_BOOKED = 'booked';
  STATUS_CONFIRMED = 'confirmed';
  STATUS_DONE = 'done';
  STATUS_NO_SHOW = 'no_show';
  CODE_SLOT_UNAVAILABLE = 'slot_unavailable';
  CODE_APPOINTMENT_CLOSED = 'appointment_closed';
  CODE_NOT_STARTED = 'not_started';
  CODE_CANCEL_NOTICE_PASSED = 'cancel_notice_passed';
  CODE_USE_CANCEL = 'use_cancel';
  /// The slot lock outlives a booking that hangs by at most this long.
  SLOT_LOCK_TTL_MS = 10000;

type
  IAppointmentInsert = interface(IInsertDTOBase)
    ['{2D83BB82-ED6F-43A3-B601-9AF86720EB06}']
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
    property ProfessionalId: string read GetProfessionalId;
    property ServiceId: string read GetServiceId;
    property CustomerId: string read GetCustomerId;
    property StartsAt: TUtcDateTime read GetStartsAt;
  end;

  IAppointment = interface(IResponseDTOBase)
    ['{58BB9DF7-A936-484F-BD7A-941641B00146}']
    function GetId: string;
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetStatus: string;
    function GetVersion: Integer;
    property Id: string read GetId;
    property ProfessionalId: string read GetProfessionalId;
    property ServiceId: string read GetServiceId;
    property CustomerId: string read GetCustomerId;
    property StartsAt: TUtcDateTime read GetStartsAt;
    property EndsAt: TUtcDateTime read GetEndsAt;
    property Status: string read GetStatus;
    property Version: Integer read GetVersion;
  end;

  /// PATCH /appointments/:id: the members that came change.
  IAppointmentPatch = interface(IUpdateDTOBase)
    ['{6C0E5F3B-9A41-4C7D-8E25-3B1F0A7D9C64}']
    function GetStartsAt: IOptString;
    function GetStatus: IOptString;
    property StartsAt: IOptString read GetStartsAt;
    property Status: IOptString read GetStatus;
  end;

  /// GET /appointments: page, limit, orderBy, professional, status, from, to
  /// (instants: the appointments that overlap [from, to)).
  IAppointmentFind = interface(IFindPaginationDTOBase)
    ['{E01B503D-1EC1-41F7-992D-0F80D2C3F473}']
    function GetProfessional: IOptString;
    function GetStatus: IOptString;
    function GetFrom: IOptString;
    function GetTo: IOptString;
    property Professional: IOptString read GetProfessional;
    property Status: IOptString read GetStatus;
    property From: IOptString read GetFrom;
    property To_: IOptString read GetTo;
  end;

{$M+}
  TAppointmentInsert = class(TInsertDTOBase, IAppointmentInsert)
  private
    FProfessionalId, FServiceId, FCustomerId: string;
    FStartsAt: TUtcDateTime;
  public
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
  published
    property ProfessionalId: string read FProfessionalId write FProfessionalId;
    property ServiceId: string read FServiceId write FServiceId;
    property CustomerId: string read FCustomerId write FCustomerId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
  end;

  TAppointmentPatch = class(TUpdateDTOBase, IAppointmentPatch)
  private
    FStartsAt, FStatus: IOptString;
  public
    function GetStartsAt: IOptString;
    function GetStatus: IOptString;
  published
    property StartsAt: IOptString read FStartsAt write FStartsAt;
    property Status: IOptString read FStatus write FStatus;
  end;

  TAppointment = class(TResponseDTOBase, IAppointment)
  private
    FId, FProfessionalId, FServiceId, FCustomerId, FStatus: string;
    FStartsAt, FEndsAt: TUtcDateTime;
    FVersion: Integer;
  public
    function GetId: string;
    function GetProfessionalId: string;
    function GetServiceId: string;
    function GetCustomerId: string;
    function GetStartsAt: TUtcDateTime;
    function GetEndsAt: TUtcDateTime;
    function GetStatus: string;
    function GetVersion: Integer;
  published
    property Id: string read FId write FId;
    property ProfessionalId: string read FProfessionalId write FProfessionalId;
    property ServiceId: string read FServiceId write FServiceId;
    property CustomerId: string read FCustomerId write FCustomerId;
    property StartsAt: TUtcDateTime read FStartsAt write FStartsAt;
    property EndsAt: TUtcDateTime read FEndsAt write FEndsAt;
    property Status: string read FStatus write FStatus;
    property Version: Integer read FVersion write FVersion;
  end;

  TAppointmentFind = class(TFindPaginationDTOBase, IAppointmentFind)
  private
    FProfessional, FStatus, FFrom, FTo: IOptString;
  public
    function GetProfessional: IOptString;
    function GetStatus: IOptString;
    function GetFrom: IOptString;
    function GetTo: IOptString;
  published
    property Professional: IOptString read FProfessional write FProfessional;
    property Status: IOptString read FStatus write FStatus;
    property From: IOptString read FFrom write FFrom;
    property To_: IOptString read FTo write FTo;
  end;
{$M-}

  TAppointmentArray = TArray<IAppointment>;

  TAppointmentRepository = class
  private
    FScope: TTenantDataScope;
    FLock: TRedisLock;
    function LockSlot(const AKey: string; out AToken: string): Boolean;
  public
    /// ALock: the slot lock in front of the booking (not owned), or nil for
    /// none.
    constructor Create(const AScope: TTenantDataScope; ALock: TRedisLock = nil);
    /// EValidationException for from/to that aren't instants or a status
    /// that isn't one; EOrderByException (400).
    function FindPage(const AFind: IAppointmentFind; const APage: TPageRequest): TPage<IAppointment>;
    /// ENotFoundException when the tenant has none with this id.
    function FindById(const AId: string): IAppointment;
    /// EValidationException (400) for the body; 409 for an inactive
    /// professional or service, or a start that isn't free (slot_unavailable).
    /// ANow: Unix seconds.
    function Book(const AInsert: IAppointmentInsert; ANow: Int64): IAppointment;
    /// AIfMatch: the request's If-Match: 428 (absent) and 400 (invalid)
    /// before anything else, 412 after the read. 404; 400 for the body; 409
    /// for the rules or a start that isn't free.
    function Update(const AId, AIfMatch: string; const APatch: IAppointmentPatch;
      ANow: Int64): IAppointment;
    /// The same If-Match answers; 409 when it is closed or past the notice.
    function Cancel(const AId, AIfMatch: string; ANow: Int64): IAppointment;
  end;

function AppointmentOrderSpec: TOrderBySpec;

implementation

uses
  SysUtils,
  PascalCommon.TimeZones,
  PascalCommon.Validators,
  PascalDb.Interfaces,
  PascalDb.SqlLoader,
  PascalJsonMapper.Mapper,
  PascalCommon.JsonMapper.Optionals,
  PascalApi.OpenApi,
  PascalApi.Http,
  PascalApi.PagedQuery,
  PascalApi.Preconditions,
  Agenda.Times,
  Agenda.Tokens,
  Agenda.Slots,
  Agenda.Availability;

const
  STATUSES: array[0..4] of string = ('booked', 'confirmed', 'cancelled', 'done', 'no_show');
  /// What PATCH may set; cancelled has its own route.
  PATCH_STATUSES: array[0..2] of string = ('confirmed', 'done', 'no_show');

function AppointmentOrderSpec: TOrderBySpec;
begin
  Result := TOrderBySpec.New
    .Allow('startsAt', 'START_UTC')
    .Default('startsAt')
    .AlwaysLast('ID');
end;

{ DTOs }

function TAppointmentInsert.GetProfessionalId: string;
begin
  Result := FProfessionalId;
end;

function TAppointmentInsert.GetServiceId: string;
begin
  Result := FServiceId;
end;

function TAppointmentInsert.GetCustomerId: string;
begin
  Result := FCustomerId;
end;

function TAppointmentInsert.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TAppointmentPatch.GetStartsAt: IOptString;
begin
  Result := TOptionals.Safe(FStartsAt);
end;

function TAppointmentPatch.GetStatus: IOptString;
begin
  Result := TOptionals.Safe(FStatus);
end;

function TAppointment.GetId: string;
begin
  Result := FId;
end;

function TAppointment.GetProfessionalId: string;
begin
  Result := FProfessionalId;
end;

function TAppointment.GetServiceId: string;
begin
  Result := FServiceId;
end;

function TAppointment.GetCustomerId: string;
begin
  Result := FCustomerId;
end;

function TAppointment.GetStartsAt: TUtcDateTime;
begin
  Result := FStartsAt;
end;

function TAppointment.GetEndsAt: TUtcDateTime;
begin
  Result := FEndsAt;
end;

function TAppointment.GetStatus: string;
begin
  Result := FStatus;
end;

function TAppointment.GetVersion: Integer;
begin
  Result := FVersion;
end;

function TAppointmentFind.GetProfessional: IOptString;
begin
  Result := TOptionals.Safe(FProfessional);
end;

function TAppointmentFind.GetStatus: IOptString;
begin
  Result := TOptionals.Safe(FStatus);
end;

function TAppointmentFind.GetFrom: IOptString;
begin
  Result := TOptionals.Safe(FFrom);
end;

function TAppointmentFind.GetTo: IOptString;
begin
  Result := TOptionals.Safe(FTo);
end;

{ reading }

function ReadAppointment(const AResult: IQueryResult): IAppointment;
var
  LAppointment: TAppointment;
begin
  LAppointment := TAppointment.Create;
  Result := LAppointment;
  LAppointment.Id := AResult.Strings['ID'];
  LAppointment.ProfessionalId := AResult.Strings['PROFESSIONAL_ID'];
  LAppointment.ServiceId := AResult.Strings['SERVICE_ID'];
  LAppointment.CustomerId := AResult.Strings['CUSTOMER_ID'];
  LAppointment.StartsAt := UnixToUtc(AResult.Int64s['START_UTC']);
  LAppointment.EndsAt := UnixToUtc(AResult.Int64s['END_UTC']);
  LAppointment.Status := AResult.Strings['STATUS'];
  LAppointment.Version := AResult.Integers['VERSION'];
end;

type
  /// What the rules read of a row before a change.
  TAppointmentRow = record
    ProfessionalId, Status: string;
    StartUtc, EndUtc, BusyUntilUtc: Int64;
    Version: Integer;
  end;

// On its own connection, released on return. ENotFoundException.
function ReadRow(const AScope: TTenantDataScope; const AId: string): TAppointmentRow;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, AScope, 'APPOINTMENT.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Appointment not found.');
  Result.ProfessionalId := LResult.Strings['PROFESSIONAL_ID'];
  Result.Status := LResult.Strings['STATUS'];
  Result.StartUtc := LResult.Int64s['START_UTC'];
  Result.EndUtc := LResult.Int64s['END_UTC'];
  Result.BusyUntilUtc := LResult.Int64s['BUSY_UNTIL_UTC'];
  Result.Version := LResult.Integers['VERSION'];
end;

function CancelNoticeHours(const AScope: TTenantDataScope): Integer;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LTx := AScope.Factory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := AScope.Factory.SqlLoader['TENANT.CANCEL_NOTICE'].SQL;
  LQuery.Params.Strings['ID'] := AScope.Discriminator;
  LResult := LQuery.Open;
  if LResult.Eof then
    raise ENotFoundException.Create('Tenant not found.');
  Result := LResult.Integers['CANCEL_NOTICE_HOURS'];
end;

// Booked and confirmed change; cancelled, done and no_show are final.
procedure RequireOpen(const ARow: TAppointmentRow);
begin
  if (ARow.Status <> STATUS_BOOKED) and (ARow.Status <> STATUS_CONFIRMED) then
    raise EHttpException.Create(409, Format('The appointment is %s: it can''t change.',
      [ARow.Status]), CODE_APPOINTMENT_CLOSED);
end;

// A start's own checks, the same for a booking and a move.
procedure CheckStart(var ACheck: TPcValidation; AStart, ANow: Int64);
begin
  if AStart mod 60 <> 0 then
    ACheck.Fail('startsAt', 'not_whole_minutes', '"startsAt" must be whole minutes.')
  else if AStart > ANow + Int64(MAX_DATE_DISTANCE_DAYS) * 86400 then
    ACheck.Fail('startsAt', CODE_DATE_OUT_OF_RANGE,
      Format('"startsAt" must be within %d days.', [MAX_DATE_DISTANCE_DAYS]));
end;

function Contains(const AStarts: TSlotStarts; AStart: Int64): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(AStarts) do
    if AStarts[I] = AStart then
      Exit(True);
end;

procedure RaiseSlotUnavailable;
begin
  raise EHttpException.Create(409, 'The professional isn''t free for this service at ' +
    'startsAt: see GET /professionals/{id}/availability.', CODE_SLOT_UNAVAILABLE);
end;

function SlotLockKey(const AScope: TTenantDataScope; const AProfessionalId: string;
  AStart: Int64): string;
begin
  Result := Format('%s:%s:%d', [AScope.Discriminator, AProfessionalId, AStart]);
end;

{ TAppointmentRepository }

constructor TAppointmentRepository.Create(const AScope: TTenantDataScope;
  ALock: TRedisLock);
begin
  inherited Create;
  FScope := AScope;
  FLock := ALock;
end;

// False only when another request holds the slot. Without a lock, or with
// Redis down (rlUnavailable, logged by its OnUnavailable), True with AToken
// '': the transaction decides alone, and Release of '' does nothing.
function TAppointmentRepository.LockSlot(const AKey: string; out AToken: string): Boolean;
begin
  AToken := '';
  Result := (FLock = nil) or (FLock.Acquire(AKey, SLOT_LOCK_TTL_MS, AToken) <> rlBusy);
end;

function TAppointmentRepository.FindPage(const AFind: IAppointmentFind;
  const APage: TPageRequest): TPage<IAppointment>;
var
  LOrder: string;
  LCheck: TPcValidation;
  LArgs: TQueryArgs;
begin
  LOrder := AppointmentOrderSpec.Build(AFind.OrderBy.ValueOr(''));
  LCheck := TPcValidation.Create;
  LCheck.Check('status', AFind.Status, TPcStringValidators.OneOf(STATUSES));
  LCheck.RaiseIfAny;
  // Each block kept only for the filter that came (TQueryArgs, 0.22.0).
  LArgs := TQueryArgs.New
    .OptStrings('PROFESSIONAL_ID', AFind.Professional, 'PROFESSIONAL')
    .OptStrings('STATUS', AFind.Status, 'STATUS')
    .OptInt64s('FROM_UTC', OptInstant(AFind.From, 'from'), 'FROM')
    .OptInt64s('TO_UTC', OptInstant(AFind.To_, 'to'), 'TO');
  Result := TTenantPagedQuery.Run<IAppointment>(FScope,
    FScope.Factory.SqlLoader['APPOINTMENT.COUNT'], FScope.Factory.SqlLoader['APPOINTMENT.PAGE'],
    LOrder, APage, LArgs, ReadAppointment);
end;

function TAppointmentRepository.FindById(const AId: string): IAppointment;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  Result := nil;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, FScope, 'APPOINTMENT.BY_ID');
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  if not LResult.Eof then
    Result := ReadAppointment(LResult);
  if Result = nil then
    raise ENotFoundException.Create('Appointment not found.');
end;

function TAppointmentRepository.Book(const AInsert: IAppointmentInsert;
  ANow: Int64): IAppointment;
var
  LCheck: TPcValidation;
  LProfessional, LService, LCustomer, LId, LLockKey, LLockToken: string;
  LStart: Int64;
  LProfessionalActive, LServiceActive, LFree: Boolean;
  LBookable: TBookable;
  LZone: IPcTimeZone;
  LLocal: TPcLocalDateTime;
  LStarts: TSlotStarts;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;

  procedure Required(const AValue, AField: string);
  begin
    if AValue = '' then
      LCheck.Fail(AField, PC_VALIDATION_REQUIRED, Format('"%s" is required.', [AField]));
  end;

begin
  LProfessional := Trim(AInsert.ProfessionalId);
  LService := Trim(AInsert.ServiceId);
  LCustomer := Trim(AInsert.CustomerId);
  // The mapper already refused a text without its zone (TUtcDateTime); an
  // absent member is 0, 1899.
  LStart := UtcToUnix(AInsert.StartsAt);
  LCheck := TPcValidation.Create;
  Required(LProfessional, 'professionalId');
  Required(LService, 'serviceId');
  Required(LCustomer, 'customerId');
  if LStart < 0 then
    LCheck.Fail('startsAt', PC_VALIDATION_REQUIRED, '"startsAt" is required.')
  else
    CheckStart(LCheck, LStart, ANow);
  LCheck.RaiseIfAny;

  LId := NewId;
  LServiceActive := False;
  LProfessionalActive := False;
  LBookable.DurationMinutes := 0;
  LBookable.BufferMinutes := 0;
  // The slot lock first, when there is one: a second request for this
  // professional and start stops here.
  LLockKey := SlotLockKey(FScope, LProfessional, LStart);
  LLockToken := '';
  if not LockSlot(LLockKey, LLockToken) then
    raise EHttpException.Create(409, 'Another request is booking this slot.',
      CODE_SLOT_UNAVAILABLE);
  try
    LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
    LTx.StartTransaction;
    try
      // The professional's row first: every change to its time waits here.
      TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.TOUCH');
      LQuery.Params.Int64s['UPDATED_AT'] := ANow;
      LQuery.Params.Strings['ID'] := LProfessional;
      if LQuery.ExecSql = 0 then
        LCheck.Fail('professionalId', 'unknown_professional',
          '"professionalId": the tenant has no such professional.')
      else
      begin
        TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.BY_ID');
        LQuery.Params.Strings['ID'] := LProfessional;
        LProfessionalActive := LQuery.Open.Booleans['ACTIVE'];
      end;
      TTenantFilter.Prepare(LQuery, FScope, 'SERVICE.BY_ID');
      LQuery.Params.Strings['ID'] := LService;
      LResult := LQuery.Open;
      if LResult.Eof then
        LCheck.Fail('serviceId', 'unknown_service', '"serviceId": the tenant has no such service.')
      else
      begin
        LServiceActive := LResult.Booleans['ACTIVE'];
        LBookable.DurationMinutes := LResult.Integers['DURATION_MINUTES'];
        LBookable.BufferMinutes := LResult.Integers['BUFFER_MINUTES'];
      end;
      TTenantFilter.Prepare(LQuery, FScope, 'CUSTOMER.BY_ID');
      LQuery.Params.Strings['ID'] := LCustomer;
      if LQuery.Open.Eof then
        LCheck.Fail('customerId', 'unknown_customer', '"customerId": the tenant has no such customer.');
      LCheck.RaiseIfAny;
      if not LProfessionalActive then
        raise EHttpException.Create(409, 'The professional is inactive.', CODE_PROFESSIONAL_INACTIVE);
      if not LServiceActive then
        raise EHttpException.Create(409, 'The service is inactive.', CODE_SERVICE_INACTIVE);

      // The start must be one of that local day's free starts, computed now,
      // under the lock.
      LZone := TenantZone(LQuery, FScope);
      LLocal := LZone.ToLocal(LStart);
      LStarts := FreeStartsOn(LQuery, FScope, LZone, LProfessional, LBookable,
        TPcLocalDateTime.Create(LLocal.Year, LLocal.Month, LLocal.Day), 1, ANow);
      LFree := Contains(LStarts, LStart);
      if not LFree then
        RaiseSlotUnavailable;

      TTenantFilter.Prepare(LQuery, FScope, 'APPOINTMENT.INSERT');
      LQuery.Params.Strings['ID'] := LId;
      LQuery.Params.Strings['PROFESSIONAL_ID'] := LProfessional;
      LQuery.Params.Strings['SERVICE_ID'] := LService;
      LQuery.Params.Strings['CUSTOMER_ID'] := LCustomer;
      LQuery.Params.Int64s['START_UTC'] := LStart;
      LQuery.Params.Int64s['END_UTC'] := LStart + Int64(LBookable.DurationMinutes) * 60;
      LQuery.Params.Int64s['BUSY_UNTIL_UTC'] := LStart +
        Int64(LBookable.DurationMinutes + LBookable.BufferMinutes) * 60;
      LQuery.Params.Strings['STATUS'] := STATUS_BOOKED;
      LQuery.Params.Int64s['CREATED_AT'] := ANow;
      LQuery.ExecSql;
      LTx.Commit;
    except
      LTx.Rollback;
      raise;
    end;
  finally
    if FLock <> nil then
      FLock.Release(LLockKey, LLockToken);
  end;
  // The connection back to the pool before FindById takes one.
  LQuery := nil;
  LTx := nil;
  Result := FindById(LId);
end;

function TAppointmentRepository.Update(const AId, AIfMatch: string;
  const APatch: IAppointmentPatch; ANow: Int64): IAppointment;
var
  LMove: IOptInt64;
  LCheck: TPcValidation;
  LRow: TAppointmentRow;
  LStart: Int64;
  LStatus, LLockKey, LLockToken: string;
  LLocked: Boolean;
  LBookable: TBookable;
  LZone: IPcTimeZone;
  LLocal: TPcLocalDateTime;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  RequireIfMatchSent(AIfMatch);
  LMove := OptInstant(APatch.StartsAt, 'startsAt');
  LCheck := TPcValidation.Create;
  if APatch.Status.HasValue and (APatch.Status.Value = STATUS_CANCELLED) then
    LCheck.Fail('status', CODE_USE_CANCEL,
      '"status": cancel through POST /appointments/{id}/cancel.')
  else
    LCheck.Check('status', APatch.Status, TPcStringValidators.OneOf(PATCH_STATUSES));
  if LMove.HasValue then
    CheckStart(LCheck, LMove.Value, ANow);
  LCheck.RaiseIfAny;

  LRow := ReadRow(FScope, AId);
  RequireIfMatch(AIfMatch, VersionETag(LRow.Version));
  RequireOpen(LRow);
  LStart := LMove.ValueOr(LRow.StartUtc);
  LStatus := APatch.Status.ValueOr(LRow.Status);
  if ((LStatus = STATUS_DONE) or (LStatus = STATUS_NO_SHOW)) and (LStart > ANow) then
    raise EHttpException.Create(409, Format('An appointment is %s only once it has started.',
      [LStatus]), CODE_NOT_STARTED);
  if not LMove.HasValue and not APatch.Status.HasValue then
    Exit(FindById(AId)); // nothing to change: the version stays

  // A move: the new start's slot lock first, as for a booking.
  LLocked := False;
  LLockKey := '';
  LLockToken := '';
  if LMove.HasValue and (FLock <> nil) then
  begin
    LLockKey := SlotLockKey(FScope, LRow.ProfessionalId, LStart);
    if not LockSlot(LLockKey, LLockToken) then
      raise EHttpException.Create(409, 'Another request is booking this slot.',
        CODE_SLOT_UNAVAILABLE);
    LLocked := True;
  end;
  try
    LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
    LTx.StartTransaction;
    try
      if LMove.HasValue then
      begin
        // The professional's row first (a write: on SQLite, the write lock
        // from the first statement), then the new start's day without this
        // appointment's own span.
        TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.TOUCH');
        LQuery.Params.Int64s['UPDATED_AT'] := ANow;
        LQuery.Params.Strings['ID'] := LRow.ProfessionalId;
        LQuery.ExecSql;
        TTenantFilter.Prepare(LQuery, FScope, 'PROFESSIONAL.BY_ID');
        LQuery.Params.Strings['ID'] := LRow.ProfessionalId;
        if not LQuery.Open.Booleans['ACTIVE'] then
          raise EHttpException.Create(409, 'The professional is inactive.',
            CODE_PROFESSIONAL_INACTIVE);
        LBookable.DurationMinutes := Integer((LRow.EndUtc - LRow.StartUtc) div 60);
        LBookable.BufferMinutes := Integer((LRow.BusyUntilUtc - LRow.EndUtc) div 60);
        LZone := TenantZone(LQuery, FScope);
        LLocal := LZone.ToLocal(LStart);
        if not Contains(FreeStartsOn(LQuery, FScope, LZone, LRow.ProfessionalId, LBookable,
          TPcLocalDateTime.Create(LLocal.Year, LLocal.Month, LLocal.Day), 1, ANow, AId),
          LStart) then
          RaiseSlotUnavailable;
      end;
      // The version read: a change in between leaves no row to update.
      TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['APPOINTMENT.UPDATE']
        .ProcessTag('MOVE', LMove.HasValue)
        .ProcessTag('STATUS', APatch.Status.HasValue));
      LQuery.Params.Strings['ID'] := AId;
      LQuery.Params.Integers['VERSION'] := LRow.Version;
      LQuery.Params.Int64s['UPDATED_AT'] := ANow;
      if LMove.HasValue then
      begin
        LQuery.Params.Int64s['START_UTC'] := LStart;
        LQuery.Params.Int64s['END_UTC'] := LStart + (LRow.EndUtc - LRow.StartUtc);
        LQuery.Params.Int64s['BUSY_UNTIL_UTC'] := LStart + (LRow.BusyUntilUtc - LRow.StartUtc);
      end;
      LQuery.Params.OptStrings['STATUS'] := APatch.Status;
      if LQuery.ExecSql = 0 then
        RaisePreconditionFailed;
      LTx.Commit;
    except
      LTx.Rollback;
      raise;
    end;
  finally
    if LLocked then
      FLock.Release(LLockKey, LLockToken);
  end;
  LQuery := nil;
  LTx := nil;
  Result := FindById(AId);
end;

function TAppointmentRepository.Cancel(const AId, AIfMatch: string;
  ANow: Int64): IAppointment;
var
  LRow: TAppointmentRow;
  LNotice: Integer;
  LLatest: Int64;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  RequireIfMatchSent(AIfMatch);
  LRow := ReadRow(FScope, AId);
  RequireIfMatch(AIfMatch, VersionETag(LRow.Version));
  RequireOpen(LRow);
  LNotice := CancelNoticeHours(FScope);
  LLatest := LRow.StartUtc - Int64(LNotice) * 3600;
  if ANow > LLatest then
    raise EHttpException.Create(409, Format('Cancelling needs %d hours'' notice: it was ' +
      'possible until %s.', [LNotice, JsonUtcDateTimeToStr(UnixToUtc(LLatest))]),
      CODE_CANCEL_NOTICE_PASSED);
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    TTenantFilter.Prepare(LQuery, FScope, FScope.Factory.SqlLoader['APPOINTMENT.UPDATE']
      .ProcessTag('MOVE', False)
      .ProcessTag('STATUS', True));
    LQuery.Params.Strings['ID'] := AId;
    LQuery.Params.Integers['VERSION'] := LRow.Version;
    LQuery.Params.Int64s['UPDATED_AT'] := ANow;
    LQuery.Params.Strings['STATUS'] := STATUS_CANCELLED;
    if LQuery.ExecSql = 0 then
      RaisePreconditionFailed;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
  LQuery := nil;
  LTx := nil;
  Result := FindById(AId);
end;

initialization
  TJsonMapper.Shared.RenameMember(TAppointmentFind, 'To_', 'to');
  TJsonMapper.Shared.RegisterMapping<IAppointmentInsert, TAppointmentInsert>;
  TJsonMapper.Shared.RegisterMapping<IAppointmentPatch, TAppointmentPatch>;
  TJsonMapper.Shared.RegisterMapping<IAppointment, TAppointment>;
  TJsonMapper.Shared.RegisterMapping<IAppointmentFind, TAppointmentFind>;
  TApiSchema.Describe(TypeInfo(IAppointmentInsert), 'A booking')
    .Prop('ProfessionalId').Desc('The professional''s id')
    .Prop('ServiceId').Desc('The service''s id')
    .Prop('CustomerId').Desc('The customer''s id')
    .Prop('StartsAt').Desc('A start GET /professionals/{id}/availability lists')
      .Format('date-time').Example('2026-11-02T12:00:00Z');
  TApiSchema.Describe(TypeInfo(IAppointmentPatch), 'The members to change; the others stay')
    .Prop('StartsAt').Desc('A new start: a free slot (its own time counted free), ISO 8601 ' +
      'with its zone').Format('date-time').Example('2026-11-02T13:00:00Z')
    .Prop('Status').Desc('confirmed, done or no_show (done and no_show once started); ' +
      'cancel through POST /appointments/{id}/cancel');
  TApiSchema.Describe(TypeInfo(IAppointment), 'An appointment')
    .Prop('StartsAt').Desc('UTC').Format('date-time')
    .Prop('EndsAt').Desc('UTC: the service''s end').Format('date-time')
    .Prop('Status').Desc('booked, confirmed, cancelled, done or no_show')
    .Prop('Version').Desc('Goes up with every change; the ETag is it in quotes, for If-Match');
  TApiSchema.Describe(TypeInfo(IAppointmentFind))
    .Prop('Page').Desc('Page number, from 1')
    .Prop('Limit').Desc('Entries per page (default 20, at most 100)')
    .Prop('OrderBy').Desc(AppointmentOrderSpec.DocHint)
    .Prop('Search').Desc('Not used here')
    .Prop('Professional').Desc('Only this professional''s')
    .Prop('Status').Desc('booked, confirmed, cancelled, done or no_show')
    .Prop('From').Desc('Only appointments that end after this instant (ISO 8601 with its zone)')
    .Prop('To_').Desc('Only appointments that start before this instant (ISO 8601 with its zone)');

end.
