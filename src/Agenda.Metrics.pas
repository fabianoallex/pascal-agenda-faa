unit Agenda.Metrics;

{$I agenda.inc}

{ The application's own metrics (docs/design.md, M5 decision 5), in
  pascal-common-faa's process-wide registry (PcMetrics): the api serves them
  on GET /metrics with the request and pool metrics, the worker pushes them
  over OTLP (pascal-api-infra-faa's TOtlpMetricsExporter).

  OpenTelemetry names; Prometheus sees agenda_bookings_total,
  agenda_email_send_duration_seconds and so on. Every label value is one of
  a few fixed words, never an id or a free text (the registry never drops a
  series). The outbox's own metrics (outbox.*) are its units'.

  AgendaMetricsInit registers the families at start, so /metrics and the
  dashboards show them (at 0 for those without labels) before the first
  event. }

interface

uses
  SysUtils;

const
  BOOKING_CHANNEL_STAFF = 'staff';
  BOOKING_CHANNEL_PUBLIC = 'public';
  BOOKING_BOOKED = 'booked';
  BOOKING_SLOT_UNAVAILABLE = 'slot_unavailable';
  /// Any other 4xx: an inactive service, a missing member...
  BOOKING_REFUSED = 'refused';
  /// Anything else: a 5xx.
  BOOKING_FAILED = 'failed';

  EMAIL_SENT = 'sent';
  EMAIL_FAILED = 'failed';
  /// The customer has no email address.
  EMAIL_NO_ADDRESS = 'no_address';
  /// The appointment changed since the event (cancelled, moved past...).
  EMAIL_SKIPPED = 'skipped';

procedure AgendaMetricsInit;

/// One booking that ran (an idempotent replay doesn't run it again):
/// AChannel BOOKING_CHANNEL_*, AError nil when it booked.
procedure CountBooking(const AChannel: string; AError: Exception);
/// A booking made without the slot lock: Redis was configured but down.
procedure CountSlotLockFallback;
/// AKind: the event's kind (appointment.booked...); AResult EMAIL_*.
procedure CountEmail(const AKind, AResult: string);
procedure ObserveEmailSend(ASeconds: Double);
procedure CountRemindersQueued(ACount: Integer);

implementation

uses
  PascalCommon.Metrics,
  PascalApi.Http;

const
  CODE_SLOT_UNAVAILABLE = 'slot_unavailable';

function Bookings: TPcCounter;
begin
  Result := PcMetrics.Counter('agenda.bookings', '{booking}',
    'Bookings run, by channel (staff, public) and result (booked, slot_unavailable, ' +
    'refused, failed)', ['agenda.channel', 'agenda.booking.result']);
end;

function SlotLockFallbacks: TPcCounter;
begin
  Result := PcMetrics.Counter('agenda.slot_lock.fallbacks', '{booking}',
    'Bookings decided by the database alone because Redis, configured, did not answer', []);
end;

function Emails: TPcCounter;
begin
  Result := PcMetrics.Counter('agenda.emails', '{email}',
    'Appointment emails, by event kind and result (sent, failed, no_address, skipped)',
    ['agenda.email.kind', 'agenda.email.result']);
end;

function EmailSendDuration: TPcHistogram;
begin
  Result := PcMetrics.Histogram('agenda.email.send.duration', 's',
    'Time the mail server took to accept one email, failed ones included', [],
    PC_DURATION_BUCKETS);
end;

function RemindersQueued: TPcCounter;
begin
  Result := PcMetrics.Counter('agenda.reminders.queued', '{reminder}',
    'Reminders queued by the scheduler', []);
end;

procedure AgendaMetricsInit;
begin
  Bookings;
  SlotLockFallbacks;
  Emails;
  EmailSendDuration;
  RemindersQueued;
end;

procedure CountBooking(const AChannel: string; AError: Exception);
var
  LResult: string;
begin
  if AError = nil then
    LResult := BOOKING_BOOKED
  else if (AError is EHttpException) and (EHttpException(AError).StatusCode < 500) then
  begin
    if EHttpException(AError).Code = CODE_SLOT_UNAVAILABLE then
      LResult := BOOKING_SLOT_UNAVAILABLE
    else
      LResult := BOOKING_REFUSED;
  end
  else
    LResult := BOOKING_FAILED;
  Bookings.Labels([AChannel, LResult]).Inc;
end;

procedure CountSlotLockFallback;
begin
  SlotLockFallbacks.Inc;
end;

procedure CountEmail(const AKind, AResult: string);
begin
  Emails.Labels([AKind, AResult]).Inc;
end;

procedure ObserveEmailSend(ASeconds: Double);
begin
  EmailSendDuration.Observe(ASeconds);
end;

procedure CountRemindersQueued(ACount: Integer);
begin
  if ACount > 0 then
    RemindersQueued.Add(ACount);
end;

end.
