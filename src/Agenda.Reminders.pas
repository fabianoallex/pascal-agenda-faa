unit Agenda.Reminders;

{$I agenda.inc}

(* The reminders' scheduler pass (docs/design.md, M4 decision 3): across
  tenants, the appointments that start within their tenant's REMINDER_HOURS
  (0: none) and have no reminder queued, each claimed and queued once.

  - Due: booked or confirmed, START_UTC after now and at most REMINDER_HOURS
    ahead, REMINDER_QUEUED_AT empty, the tenant not suspended. The scan is
    bounded by REMINDER_MAX_HOURS (IX_APPOINTMENTS_REMINDER serves the
    range); a tenant's hours above it count as that.
  - The claim, per appointment, in one transaction: UPDATE ... SET
    REMINDER_QUEUED_AT WHERE REMINDER_QUEUED_AT IS NULL AND VERSION =
    :VERSION, and the outbox event (appointment.reminder, the version read)
    when it matched. Two passes at once, or an appointment changed between
    the scan and the claim: one row or none, so one reminder at most. The
    version isn't moved (a reminder is no change of the appointment: an
    If-Match the client holds stays good); a move clears the column, so the
    new start gets its reminder.
  - Each queued reminder starts a trace of its own (a root span, "reminder
    queue"): the event carries it to the email.
  - No lease here: the worker takes one (Agenda.Leases) around the pass.

  Known limit: an appointment booked inside its reminder window gets the
  reminder right after its confirmation. Across tenants, so these SQL
  statements bind TENANT_ID themselves instead of ${TENANT}, as the outbox's
  do. *)

interface

uses
  PascalDb.Interfaces;

const
  REMINDER_SQL_DUE = 'REMINDER.DUE';
  REMINDER_SQL_CLAIM = 'REMINDER.CLAIM';
  /// The scan's horizon: no reminder is queued earlier than this before the
  /// start, whatever REMINDER_HOURS says (30 days).
  REMINDER_MAX_HOURS = 720;
  REMINDER_DEFAULT_BATCH = 200;
  /// A pass reads at most this many batches.
  REMINDER_MAX_BATCHES = 20;

type
  TReminderScheduler = class
  private
    FFactory: IDBFactory;
    FBatchSize: Integer;
    function Claim(const ATenantId, AId: string; AVersion: Integer; ANow: Int64): Boolean;
  public
    constructor Create(const AFactory: IDBFactory; ABatchSize: Integer = REMINDER_DEFAULT_BATCH);
    /// One pass; returns the reminders queued.
    function RunOnce(ANow: Int64): Integer;
  end;

implementation

uses
  SysUtils,
  PascalDb.Paging,
  PascalDb.Outbox,
  PascalCommon.Tracing,
  Agenda.Events,
  Agenda.Metrics;

const
  STATUS_BOOKED = 'booked';
  STATUS_CONFIRMED = 'confirmed';

type
  TDue = record
    TenantId: string;
    Id: string;
    Version: Integer;
  end;

constructor TReminderScheduler.Create(const AFactory: IDBFactory; ABatchSize: Integer);
begin
  inherited Create;
  FFactory := AFactory;
  FBatchSize := ABatchSize;
  if FBatchSize < 1 then
    FBatchSize := REMINDER_DEFAULT_BATCH;
end;

function TReminderScheduler.Claim(const ATenantId, AId: string; AVersion: Integer;
  ANow: Int64): Boolean;
var
  LSpan: IPcSpan;
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LSpan := TPcTracing.StartSpan('reminder queue', skInternal);
  try
    LSpan.SetAttribute('tenant.id', ATenantId);
    LSpan.SetAttribute('appointment.id', AId);
    try
      LTx := FFactory.GetPool.AcquireQuery(LQuery);
      LTx.StartTransaction;
      try
        LQuery.Sql := FFactory.SqlLoader[REMINDER_SQL_CLAIM].SQL;
        LQuery.Params.Int64s['NOW'] := ANow;
        LQuery.Params.Strings['TENANT_ID'] := ATenantId;
        LQuery.Params.Strings['ID'] := AId;
        LQuery.Params.Integers['VERSION'] := AVersion;
        LQuery.Params.Strings['BOOKED'] := STATUS_BOOKED;
        LQuery.Params.Strings['CONFIRMED'] := STATUS_CONFIRMED;
        Result := LQuery.ExecSql > 0;
        if Result then
        begin
          TOutbox.Enqueue(FFactory, LQuery, ATenantId, EVENT_APPOINTMENT_REMINDER,
            AppointmentEventPayload(AId, AVersion), ANow);
          LTx.Commit;
        end
        else
          LTx.Rollback;
      except
        LTx.Rollback;
        raise;
      end;
    except
      on E: Exception do
      begin
        LSpan.SetStatus(ssError, E.ClassName + ': ' + E.Message);
        raise;
      end;
    end;
  finally
    LSpan.Finish;
  end;
end;

function TReminderScheduler.RunOnce(ANow: Int64): Integer;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
  LDue: array of TDue;
  LBatch, LCount, LQueued, I: Integer;
begin
  Result := 0;
  for LBatch := 1 to REMINDER_MAX_BATCHES do
  begin
    LDue := nil;
    LCount := 0;
    LTx := FFactory.GetPool.AcquireQuery(LQuery);
    LQuery.Sql := FFactory.SqlLoader[REMINDER_SQL_DUE]
      .ReplaceLiteral('PAGE', PdbPagingClause(LTx,
        TPageRequest.Create(1, FBatchSize, FBatchSize, FBatchSize))).SQL;
    LQuery.Params.Int64s['NOW'] := ANow;
    LQuery.Params.Int64s['HORIZON'] := ANow + Int64(REMINDER_MAX_HOURS) * 3600;
    LQuery.Params.Strings['BOOKED'] := STATUS_BOOKED;
    LQuery.Params.Strings['CONFIRMED'] := STATUS_CONFIRMED;
    LResult := LQuery.Open;
    while not LResult.Eof do
    begin
      SetLength(LDue, LCount + 1);
      LDue[LCount].TenantId := LResult.Strings['TENANT_ID'];
      LDue[LCount].Id := LResult.Strings['ID'];
      LDue[LCount].Version := LResult.Integers['VERSION'];
      Inc(LCount);
      LResult.Next;
    end;
    LResult := nil;
    LQuery := nil;
    LTx := nil;
    LQueued := 0;
    for I := 0 to LCount - 1 do
      if Claim(LDue[I].TenantId, LDue[I].Id, LDue[I].Version, ANow) then
        Inc(LQueued);
    Inc(Result, LQueued);
    CountRemindersQueued(LQueued);
    // A short batch was the last; a full one where nothing was claimed
    // (changed meanwhile, or another pass took them) would read the same
    // rows again.
    if (LCount < FBatchSize) or (LQueued = 0) then
      Break;
  end;
end;

end.
