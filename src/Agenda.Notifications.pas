unit Agenda.Notifications;

{$I agenda.inc}

(* The customer's email for an appointment event (docs/design.md, M4): an
  outbox handler (IOutboxHandler, "email") for appointment.booked, .moved,
  .cancelled and .reminder.

  - Thin events (decision 2): the handler reads the appointment as it is now,
    with its customer, service, professional and tenant, in one query on the
    event's tenant (TTenantFilter, a tag per joined table). What goes out
    follows the row, not the event: a booking or move read after a cancel
    sends nothing (the cancel's own event does); a reminder for an
    appointment no longer active, or already started, sends nothing. The
    event's version only goes in the log line and the span.
  - Who (decision 7): the customer's email; none, nothing sent (OnSkip says
    why). An appointment that isn't there (the event's tenant has none with
    that id) is skipped too: retrying wouldn't find it.
  - The links (M3's Agenda.SignedLinks): purpose "appointment", scope the
    tenant, expiry the start, as the public booking's answer has them; the
    worker needs the same LINK_SIGNING_KEYS and PUBLIC_BASE_URL as the api.
  - The time: the tenant's zone (pascal-common-faa's PcTimeZones), with the
    zone's name, in English as the rest of the text.
  - A failure to send raises: the local sink retries the delivery
    (Agenda.Outbox), a broker consumer won't record it as processed.

  AppointmentMail composes the message alone (no database, no clock), for
  the unit tests. *)

interface

uses
  PascalDb.Interfaces,
  Agenda.Outbox,
  Agenda.Mail,
  Agenda.SignedLinks;

const
  NOTIFY_SQL_APPOINTMENT = 'NOTIFY.APPOINTMENT';
  /// OUTBOX_DELIVERIES.HANDLER: keep it once deliveries exist.
  NOTIFY_HANDLER_EMAIL = 'email';
  /// The link's purpose, Agenda.Public's.
  NOTIFY_LINK_PURPOSE = 'appointment';

type
  /// What the email says, read from the database.
  TAppointmentNotice = record
    TenantId: string;
    TenantName: string;
    TimeZone: string;
    AppointmentId: string;
    StartUtc: Int64;
    EndUtc: Int64;
    Status: string;
    Version: Integer;
    CustomerName: string;
    CustomerEmail: string;
    ServiceName: string;
    ProfessionalName: string;
  end;

  /// A skipped event and why, for the log.
  TNotifySkipProc = procedure(const AEvent: TOutboxEvent; const AReason: string) of object;

  TAppointmentMailer = class(TInterfacedObject, IOutboxHandler)
  private
    FFactory: IDBFactory;
    FMail: IMailSender;
    FLinks: TSignedLinks;
    FFrom: string;
    FBaseUrl: string;
    FOnSkip: TNotifySkipProc;
    function Read(const AEvent: TOutboxEvent; const AId: string;
      out ANotice: TAppointmentNotice): Boolean;
    procedure Skip(const AEvent: TOutboxEvent; const AReason: string);
  public
    /// ALinks is not owned. AFrom: the sender ("Name <address>"); ABaseUrl
    /// what goes before /public/... ('' for a path alone).
    constructor Create(const AFactory: IDBFactory; const AMail: IMailSender;
      ALinks: TSignedLinks; const AFrom, ABaseUrl: string);
    function Name: string;
    function Accepts(const AKind: string): Boolean;
    procedure Handle(const AEvent: TOutboxEvent);
    property OnSkip: TNotifySkipProc read FOnSkip write FOnSkip;
  end;

/// The message for AKind about ANotice; '' AUrl/ACancelUrl leaves the links
/// out (a cancellation has none). An unknown AKind raises.
function AppointmentMail(const AKind: string; const ANotice: TAppointmentNotice;
  const AFrom, AEventId, AUrl, ACancelUrl: string): TMailMessage;

/// "Tuesday, 3 November 2026, 14:30" in AZone (an IANA name).
function NoticeTime(AUtc: Int64; const AZone: string): string;

implementation

uses
  SysUtils,
  PascalCommon.Tracing,
  PascalCommon.TimeZones,
  PascalApi.Tenancy,
  PascalApi.Jwt,
  Agenda.Events;

const
  STATUS_BOOKED = 'booked';
  STATUS_CONFIRMED = 'confirmed';
  STATUS_CANCELLED = 'cancelled';
  NL = #13#10;
  WEEKDAYS: array[1..7] of string = ('Monday', 'Tuesday', 'Wednesday', 'Thursday',
    'Friday', 'Saturday', 'Sunday');
  MONTHS: array[1..12] of string = ('January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December');

function NoticeTime(AUtc: Int64; const AZone: string): string;
var
  LLocal: TPcLocalDateTime;
begin
  LLocal := PcTimeZones.Find(AZone).ToLocal(AUtc);
  Result := Format('%s, %d %s %d, %.2d:%.2d', [WEEKDAYS[LLocal.IsoWeekday], LLocal.Day,
    MONTHS[LLocal.Month], LLocal.Year, LLocal.Hour, LLocal.Minute]);
end;

// The domain of the sender's address, for the Message-ID.
function DomainOf(const AFrom: string): string;
var
  LAddress: string;
  LAt: Integer;
begin
  LAddress := MailAddress(AFrom);
  LAt := LastDelimiter('@', LAddress);
  if LAt > 0 then
    Result := Copy(LAddress, LAt + 1, MaxInt)
  else
    Result := 'agenda.invalid';
end;

function AppointmentMail(const AKind: string; const ANotice: TAppointmentNotice;
  const AFrom, AEventId, AUrl, ACancelUrl: string): TMailMessage;
var
  LWhen, LWhat, LLead: string;
begin
  LWhen := NoticeTime(ANotice.StartUtc, ANotice.TimeZone);
  LWhat := ANotice.ServiceName + ' with ' + ANotice.ProfessionalName;
  if AKind = EVENT_APPOINTMENT_BOOKED then
  begin
    Result.Subject := 'Booked: ' + ANotice.ServiceName + ', ' + LWhen;
    LLead := 'Your appointment is booked.';
  end
  else if AKind = EVENT_APPOINTMENT_MOVED then
  begin
    Result.Subject := 'Moved: ' + ANotice.ServiceName + ', now ' + LWhen;
    LLead := 'Your appointment has a new time.';
  end
  else if AKind = EVENT_APPOINTMENT_CANCELLED then
  begin
    Result.Subject := 'Cancelled: ' + ANotice.ServiceName + ', ' + LWhen;
    LLead := 'Your appointment is cancelled.';
  end
  else if AKind = EVENT_APPOINTMENT_REMINDER then
  begin
    Result.Subject := 'Reminder: ' + ANotice.ServiceName + ', ' + LWhen;
    LLead := 'A reminder of your appointment.';
  end
  else
    raise EArgumentException.CreateFmt('No email for the event kind "%s".', [AKind]);
  Result.From := AFrom;
  Result.ToAddress := ANotice.CustomerEmail;
  Result.TextBody := 'Hello, ' + ANotice.CustomerName + '.' + NL + NL +
    LLead + NL + NL +
    '  ' + LWhat + NL +
    '  ' + LWhen + ' (' + ANotice.TimeZone + ')' + NL +
    '  ' + ANotice.TenantName + NL;
  if AUrl <> '' then
    Result.TextBody := Result.TextBody + NL + 'See it: ' + AUrl + NL;
  if ACancelUrl <> '' then
    Result.TextBody := Result.TextBody + 'Cancel it: ' + ACancelUrl + NL;
  Result.TextBody := Result.TextBody + NL + ANotice.TenantName + NL;
  Result.MessageId := AEventId + '@' + DomainOf(AFrom);
  SetLength(Result.Headers, 3);
  Result.Headers[0] := 'X-Agenda-Event: ' + AEventId;
  Result.Headers[1] := 'X-Agenda-Kind: ' + AKind;
  Result.Headers[2] := 'X-Agenda-Appointment: ' + ANotice.AppointmentId;
end;

{ TAppointmentMailer }

constructor TAppointmentMailer.Create(const AFactory: IDBFactory; const AMail: IMailSender;
  ALinks: TSignedLinks; const AFrom, ABaseUrl: string);
begin
  inherited Create;
  FFactory := AFactory;
  FMail := AMail;
  FLinks := ALinks;
  FFrom := AFrom;
  FBaseUrl := ABaseUrl;
  // A trailing "/" would double the one the path starts with.
  while (FBaseUrl <> '') and (FBaseUrl[Length(FBaseUrl)] = '/') do
    Delete(FBaseUrl, Length(FBaseUrl), 1);
end;

function TAppointmentMailer.Name: string;
begin
  Result := NOTIFY_HANDLER_EMAIL;
end;

function TAppointmentMailer.Accepts(const AKind: string): Boolean;
begin
  Result := (AKind = EVENT_APPOINTMENT_BOOKED) or (AKind = EVENT_APPOINTMENT_MOVED) or
    (AKind = EVENT_APPOINTMENT_CANCELLED) or (AKind = EVENT_APPOINTMENT_REMINDER);
end;

procedure TAppointmentMailer.Skip(const AEvent: TOutboxEvent; const AReason: string);
var
  LSpan: IPcSpan;
begin
  LSpan := TPcTracing.Current;
  if LSpan <> nil then
    LSpan.SetAttribute('notify.skipped', AReason);
  if Assigned(FOnSkip) then
    FOnSkip(AEvent, AReason);
end;

function TAppointmentMailer.Read(const AEvent: TOutboxEvent; const AId: string;
  out ANotice: TAppointmentNotice): Boolean;
var
  LScope: TTenantDataScope;
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  LScope.Factory := FFactory;
  LScope.Discriminator := AEvent.TenantId;
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  TTenantFilter.Prepare(LQuery, LScope, NOTIFY_SQL_APPOINTMENT);
  LQuery.Params.Strings['ID'] := AId;
  LResult := LQuery.Open;
  Result := not LResult.Eof;
  if not Result then
    Exit;
  ANotice.TenantId := AEvent.TenantId;
  ANotice.TenantName := LResult.Strings['TENANT_NAME'];
  ANotice.TimeZone := LResult.Strings['TIME_ZONE'];
  ANotice.AppointmentId := LResult.Strings['ID'];
  ANotice.StartUtc := LResult.Int64s['START_UTC'];
  ANotice.EndUtc := LResult.Int64s['END_UTC'];
  ANotice.Status := LResult.Strings['STATUS'];
  ANotice.Version := LResult.Integers['VERSION'];
  ANotice.CustomerName := LResult.Strings['CUSTOMER_NAME'];
  ANotice.CustomerEmail := LResult.NullableStrings['CUSTOMER_EMAIL'].ValueOr('');
  ANotice.ServiceName := LResult.Strings['SERVICE_NAME'];
  ANotice.ProfessionalName := LResult.Strings['PROFESSIONAL_NAME'];
end;

procedure TAppointmentMailer.Handle(const AEvent: TOutboxEvent);
var
  LEvent: IAppointmentEvent;
  LNotice: TAppointmentNotice;
  LActive: Boolean;
  LPath, LQuery, LUrl, LCancelUrl: string;
  LSpan: IPcSpan;
begin
  LEvent := ReadAppointmentEvent(AEvent.Payload);
  LSpan := TPcTracing.Current;
  if LSpan <> nil then
  begin
    LSpan.SetAttribute('appointment.id', LEvent.AppointmentId);
    LSpan.SetAttribute('appointment.version', IntToStr(LEvent.Version));
  end;
  if not Read(AEvent, LEvent.AppointmentId, LNotice) then
  begin
    Skip(AEvent, 'no such appointment');
    Exit;
  end;
  if LNotice.CustomerEmail = '' then
  begin
    Skip(AEvent, 'the customer has no email');
    Exit;
  end;
  LActive := (LNotice.Status = STATUS_BOOKED) or (LNotice.Status = STATUS_CONFIRMED);
  if AEvent.Kind = EVENT_APPOINTMENT_CANCELLED then
  begin
    if LNotice.Status <> STATUS_CANCELLED then
    begin
      Skip(AEvent, 'not cancelled now (' + LNotice.Status + ')');
      Exit;
    end;
  end
  else if not LActive then
  begin
    Skip(AEvent, 'no longer active (' + LNotice.Status + ')');
    Exit;
  end
  else if (AEvent.Kind = EVENT_APPOINTMENT_REMINDER) and
    (LNotice.StartUtc <= TJwt.UnixNow) then
  begin
    Skip(AEvent, 'already started');
    Exit;
  end;
  LUrl := '';
  LCancelUrl := '';
  if LActive then
  begin
    LPath := FBaseUrl + '/public/' + LNotice.TenantId + '/appointments/' +
      LNotice.AppointmentId;
    LQuery := FLinks.Query(LNotice.TenantId, NOTIFY_LINK_PURPOSE, LNotice.AppointmentId,
      LNotice.StartUtc);
    LUrl := LPath + '?' + LQuery;
    LCancelUrl := LPath + '/cancel?' + LQuery;
  end;
  FMail.Send(AppointmentMail(AEvent.Kind, LNotice, FFrom, AEvent.Id, LUrl, LCancelUrl));
end;

end.
