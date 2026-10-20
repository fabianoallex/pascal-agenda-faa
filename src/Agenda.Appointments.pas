unit Agenda.Appointments;

{$I agenda.inc}

(* Appointments: a customer booked with a professional for a service at an
  instant. DTOs, the ordering clients may ask for, and a repository on a
  tenant's scope. M2 books and reads; changing and cancelling (If-Match)
  come next.

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
    move it. STATUS starts as booked, VERSION as 1 (If-Match, next).
  - The body names the professional, the service and the customer by id;
    one that the tenant doesn't have is a 400 naming its member, every one
    in the same answer. An inactive professional or service is a 409, as in
    the availability route.
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
  PascalApi.Tenancy;

const
  STATUS_BOOKED = 'booked';
  CODE_SLOT_UNAVAILABLE = 'slot_unavailable';

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
  public
    constructor Create(const AScope: TTenantDataScope);
    /// EValidationException for from/to that aren't instants or a status
    /// that isn't one; EOrderByException (400).
    function FindPage(const AFind: IAppointmentFind; const APage: TPageRequest): TPage<IAppointment>;
    /// ENotFoundException when the tenant has none with this id.
    function FindById(const AId: string): IAppointment;
    /// EValidationException (400) for the body; 409 for an inactive
    /// professional or service, or a start that isn't free (slot_unavailable).
    /// ANow: Unix seconds.
    function Book(const AInsert: IAppointmentInsert; ANow: Int64): IAppointment;
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
  Agenda.Times,
  Agenda.Tokens,
  Agenda.Slots,
  Agenda.Availability;

const
  STATUSES: array[0..4] of string = ('booked', 'confirmed', 'cancelled', 'done', 'no_show');

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

// AText as Unix seconds; 400 naming AMember unless it is an instant.
function CheckInstant(const AText, AMember: string): Int64;
begin
  if not TryParseInstant(AText, Result) then
    raise EValidationException.Create(Format('"%s" must be an ISO 8601 date and time with ' +
      'its zone ("Z" or an offset), such as 2026-12-24T13:00:00Z.', [AMember]),
      'invalid_instant');
end;

function IsStatus(const AText: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(STATUSES) do
    if AText = STATUSES[I] then
      Exit(True);
end;

{ TAppointmentRepository }

constructor TAppointmentRepository.Create(const AScope: TTenantDataScope);
begin
  inherited Create;
  FScope := AScope;
end;

function TAppointmentRepository.FindPage(const AFind: IAppointmentFind;
  const APage: TPageRequest): TPage<IAppointment>;
var
  LOrder: string;
  LArgs: TQueryArgs;

  function Filtered(const ASql: TSQLResult): TSQLResult;
  begin
    Result := ASql.ProcessTag('PROFESSIONAL', AFind.Professional.HasValue)
      .ProcessTag('STATUS', AFind.Status.HasValue)
      .ProcessTag('FROM', AFind.From.HasValue).ProcessTag('TO', AFind.To_.HasValue);
  end;

begin
  LOrder := AppointmentOrderSpec.Build(AFind.OrderBy.ValueOr(''));
  LArgs := TQueryArgs.New;
  if AFind.Professional.HasValue then
    LArgs := LArgs.Strings('PROFESSIONAL_ID', AFind.Professional.Value);
  if AFind.Status.HasValue then
  begin
    if not IsStatus(AFind.Status.Value) then
      raise EValidationException.Create('"status" must be booked, confirmed, cancelled, done ' +
        'or no_show.', 'invalid_status');
    LArgs := LArgs.Strings('STATUS', AFind.Status.Value);
  end;
  if AFind.From.HasValue then
    LArgs := LArgs.Int64s('FROM_UTC', CheckInstant(AFind.From.Value, 'from'));
  if AFind.To_.HasValue then
    LArgs := LArgs.Int64s('TO_UTC', CheckInstant(AFind.To_.Value, 'to'));
  Result := TTenantPagedQuery.Run<IAppointment>(FScope,
    Filtered(FScope.Factory.SqlLoader['APPOINTMENT.COUNT']),
    Filtered(FScope.Factory.SqlLoader['APPOINTMENT.PAGE']), LOrder, APage, LArgs,
    ReadAppointment);
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
  LProfessional, LService, LCustomer, LId: string;
  LStart: Int64;
  LProfessionalActive, LServiceActive, LFree: Boolean;
  LBookable: TBookable;
  LZone: IPcTimeZone;
  LLocal: TPcLocalDateTime;
  LStarts: TSlotStarts;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  I: Integer;

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
  else if LStart mod 60 <> 0 then
    LCheck.Fail('startsAt', 'not_whole_minutes', '"startsAt" must be whole minutes.')
  else if LStart > ANow + Int64(MAX_DATE_DISTANCE_DAYS) * 86400 then
    LCheck.Fail('startsAt', CODE_DATE_OUT_OF_RANGE,
      Format('"startsAt" must be within %d days.', [MAX_DATE_DISTANCE_DAYS]));
  LCheck.RaiseIfAny;

  LId := NewId;
  LServiceActive := False;
  LProfessionalActive := False;
  LBookable.DurationMinutes := 0;
  LBookable.BufferMinutes := 0;
  LTx := FScope.Factory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    // The lock first: every change to this professional's time waits here.
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
    LFree := False;
    for I := 0 to High(LStarts) do
      if LStarts[I] = LStart then
        LFree := True;
    if not LFree then
      raise EHttpException.Create(409, 'The professional isn''t free for this service at ' +
        'startsAt: see GET /professionals/{id}/availability.', CODE_SLOT_UNAVAILABLE);

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
  Result := FindById(LId);
end;

initialization
  TJsonMapper.Shared.RenameMember(TAppointmentFind, 'To_', 'to');
  TJsonMapper.Shared.RegisterMapping<IAppointmentInsert, TAppointmentInsert>;
  TJsonMapper.Shared.RegisterMapping<IAppointment, TAppointment>;
  TJsonMapper.Shared.RegisterMapping<IAppointmentFind, TAppointmentFind>;
  TApiSchema.Describe(TypeInfo(IAppointmentInsert), 'A booking')
    .Prop('ProfessionalId').Desc('The professional''s id')
    .Prop('ServiceId').Desc('The service''s id')
    .Prop('CustomerId').Desc('The customer''s id')
    .Prop('StartsAt').Desc('A start GET /professionals/{id}/availability lists')
      .Format('date-time').Example('2026-11-02T12:00:00Z');
  TApiSchema.Describe(TypeInfo(IAppointment), 'An appointment')
    .Prop('StartsAt').Desc('UTC').Format('date-time')
    .Prop('EndsAt').Desc('UTC: the service''s end').Format('date-time')
    .Prop('Status').Desc('booked, confirmed, cancelled, done or no_show')
    .Prop('Version').Desc('Goes up with every change (If-Match)');
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
