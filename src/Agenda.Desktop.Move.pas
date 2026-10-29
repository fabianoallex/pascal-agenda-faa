unit Agenda.Desktop.Move;

{$I agenda.inc}

{ The move dialog's view model (decision 8 of "M6: design"): another free
  time for an appointment of the day, with the same professional and
  service.

  - Open reads the free times of the day the dialog opens on; SetDate,
    NextDay and PreviousDay read another day's. A read that comes back
    after a newer one was asked for is dropped.
  - Move sends a PATCH of "startsAt" with the version the day showed
    (If-Match). The client never sends it twice (decision 7).
  - 409 slot_unavailable (someone took the time): a Notice, the free times
    read again.
  - 412, or another 409 (the appointment closed or changed meanwhile): a
    Notice, and Stale: this dialog has nothing more to send (the day reads
    itself again when it closes).
  - The connection lost on the move: the appointment is read again, so the
    dialog says what happened. Moved (a newer version, starting at the
    chosen time): a success. Unchanged (the same version): the error, and
    Move allowed again (a second try can't move twice: it would meet 412).
    Changed in another way: Stale. The read failing too: the error.
  - The free times leave out the appointment's own span (the availability
    knows nothing of the move), so a move that overlaps its current time
    isn't offered, though the server would take it. A known limit. }

interface

uses
  SysUtils,
  Classes,
  PascalJsonMapper.Json,
  Agenda.HttpTransport,
  Agenda.Client,
  Agenda.Appointments.Dtos,
  Agenda.Availability.Dtos,
  Agenda.Day.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Models;

const
  TEXT_MOVE_SLOT_TAKEN = 'That time was just taken. The free times were read again.';
  TEXT_MOVE_STALE = 'Someone changed this appointment first. Close this window: ' +
    'the day is read again.';

type
  TMoveModel = class(TDesktopModel)
  private
    FClient: TAgendaClient;
    FAppointment: IDayAppointment;
    FDate: TDateTime;
    FSlots: TAvailableSlotArray;
    FSlotIndex: Integer;
    FSlotsSeq: Integer;
    FMoving: Boolean;
    FStale: Boolean;
    FMoved: IAppointment;
    FOnMoved: TNotifyEvent;
    procedure LoadSlots;
    procedure MarkMoved(const AAppointment: IAppointment);
    procedure MarkStale;
  public
    /// AAppointment: the row of the day (its id, version, professional and
    /// service). ADate: the local day to look for free times on first.
    constructor Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
      const AAppointment: IDayAppointment; ADate: TDateTime);
    procedure Open;
    procedure SetDate(ADate: TDateTime);
    procedure NextDay;
    procedure PreviousDay;
    procedure SelectSlot(AIndex: Integer);
    function CanMove: Boolean;
    procedure Move;
    /// 'YYYY-MM-DD'
    function DateText: string;
    property Appointment: IDayAppointment read FAppointment;
    property Date: TDateTime read FDate;
    property Slots: TAvailableSlotArray read FSlots;
    /// -1 when none.
    property SlotIndex: Integer read FSlotIndex;
    /// Someone changed the appointment first: nothing more to send.
    property Stale: Boolean read FStale;
    property Moved: IAppointment read FMoved;
    property OnMoved: TNotifyEvent read FOnMoved write FOnMoved;
  end;

implementation

type
  TMoveTask = class(TAgendaTask)
  protected
    FModel: TMoveModel;
    // Run's client, taken when the task is made: Run may still be going
    // on a pool thread after its dialog closed and freed the model.
    FClient: TAgendaClient;
  end;

  TSlotsTask = class(TMoveTask)
  private
    FSeq: Integer;
    FProfessionalId, FServiceId, FDate: string;
    FSlots: TAvailableSlotArray;
  protected
    procedure Run; override;
    procedure Done; override;
  end;

  TChangeTask = class(TMoveTask)
  private
    FId: string;
    FVersion: Integer;
    FStartsAt: TUtcDateTime;
    FMoved: IAppointment;
    // The connection was lost on the move; FRead: the appointment read
    // after it (nil when that failed too).
    FLost: Boolean;
    FRead: IAppointment;
  protected
    procedure Run; override;
    procedure Done; override;
  end;

function SameInstant(A, B: TUtcDateTime): Boolean;
begin
  Result := Abs(TDateTime(A) - TDateTime(B)) < 0.5 / SecsPerDay;
end;

{ TSlotsTask }

procedure TSlotsTask.Run;
begin
  FSlots := FClient.GetAvailability(FProfessionalId, FServiceId, FDate).Slots;
end;

procedure TSlotsTask.Done;
begin
  if FSeq <> FModel.FSlotsSeq then
  begin
    FModel.Finished(FModel.Error);
    Exit;
  end;
  if FModel.Finished(Error) then
    FModel.FSlots := FSlots;
  FModel.Changed;
end;

{ TChangeTask }

procedure TChangeTask.Run;
begin
  try
    FMoved := FClient.Move(FId, FVersion, FStartsAt);
  except
    on EHttpTransport do
    begin
      // Did it get there? Read it again (a GET, retried by the client).
      FLost := True;
      try
        FRead := FClient.GetAppointment(FId);
      except
        on Exception do
          FRead := nil;
      end;
    end;
  end;
end;

procedure TChangeTask.Done;
var
  LError: TUiError;
begin
  FModel.FMoving := False;
  if FLost then
  begin
    if (FRead <> nil) and (FRead.Version > FVersion) and SameInstant(FRead.StartsAt, FStartsAt) then
    begin
      FModel.Finished(TUiError.None);
      FModel.MarkMoved(FRead);
    end
    else if (FRead <> nil) and (FRead.Version <> FVersion) then
    begin
      FModel.Finished(TUiError.None);
      FModel.MarkStale;
    end
    else
    begin
      LError := TUiError.None;
      LError.Kind := ekOffline;
      LError.Text := TEXT_OFFLINE;
      FModel.Finished(LError);
      FModel.Changed;
    end;
    Exit;
  end;
  LError := Error;
  if (LError.Kind = ekConflict) and (LError.Code = CODE_SLOT_UNAVAILABLE) then
  begin
    FModel.Finished(TUiError.None);
    FModel.SetNotice(TEXT_MOVE_SLOT_TAKEN);
    FModel.LoadSlots;
  end
  else if LError.Kind = ekConflict then
  begin
    FModel.Finished(TUiError.None);
    FModel.MarkStale;
  end
  else if FModel.Finished(LError) then
    FModel.MarkMoved(FMoved)
  else
    FModel.Changed;
end;

{ TMoveModel }

constructor TMoveModel.Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
  const AAppointment: IDayAppointment; ADate: TDateTime);
begin
  inherited Create(ARunner);
  FClient := AClient;
  FAppointment := AAppointment;
  FDate := Trunc(ADate);
  FSlotIndex := -1;
end;

function TMoveModel.DateText: string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd', FDate);
end;

procedure TMoveModel.Open;
begin
  LoadSlots;
end;

procedure TMoveModel.LoadSlots;
var
  LTask: TSlotsTask;
begin
  Inc(FSlotsSeq);
  FSlots := nil;
  FSlotIndex := -1;
  LTask := TSlotsTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  LTask.FSeq := FSlotsSeq;
  LTask.FProfessionalId := FAppointment.ProfessionalId;
  LTask.FServiceId := FAppointment.ServiceId;
  LTask.FDate := DateText;
  StartTask(LTask);
end;

procedure TMoveModel.SetDate(ADate: TDateTime);
begin
  FDate := Trunc(ADate);
  SetNotice('');
  LoadSlots;
end;

procedure TMoveModel.NextDay;
begin
  SetDate(FDate + 1);
end;

procedure TMoveModel.PreviousDay;
begin
  SetDate(FDate - 1);
end;

procedure TMoveModel.SelectSlot(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FSlots)) then
    AIndex := -1;
  FSlotIndex := AIndex;
  Changed;
end;

function TMoveModel.CanMove: Boolean;
begin
  Result := (not FMoving) and (not FStale) and (FMoved = nil) and (FSlotIndex >= 0);
end;

procedure TMoveModel.Move;
var
  LTask: TChangeTask;
begin
  if not CanMove then
    Exit;
  FMoving := True;
  SetNotice('');
  SetError(TUiError.None);
  LTask := TChangeTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  LTask.FId := FAppointment.Id;
  LTask.FVersion := FAppointment.Version;
  LTask.FStartsAt := FSlots[FSlotIndex].StartsAt;
  StartTask(LTask);
end;

procedure TMoveModel.MarkMoved(const AAppointment: IAppointment);
begin
  FMoved := AAppointment;
  Changed;
  if Assigned(FOnMoved) then
    FOnMoved(Self);
end;

procedure TMoveModel.MarkStale;
begin
  FStale := True;
  SetNotice(TEXT_MOVE_STALE);
  Changed;
end;

end.
