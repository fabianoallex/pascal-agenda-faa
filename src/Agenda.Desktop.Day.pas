unit Agenda.Desktop.Day;

{$I agenda.inc}

{ The day screen's view model, the main window (decision 8 of "M6:
  design"): one local day of the tenant (GET /agenda/day), everyone's or a
  professional's, moving between dates; the status of the selected
  appointment (confirmed, done, no_show) and its cancel. Its move is a
  dialog of its own (TMoveModel); CanMove says when.

  - The day is read again after each change, on Reload (F5) and on Tick (a
    60-second timer of the form; skipped while a call runs). A read that
    comes back after a newer one was asked for is dropped.
  - The selection follows the appointment's id across reads.
  - A change sends the version the day showed (If-Match). A 409 or 412
    (someone else changed it, or it closed meanwhile) becomes a Notice and
    the day is read again; nothing is retried.
  - What the selected appointment allows, as the server's rules: confirm a
    booked one; cancel a booked or confirmed one; done and no_show once it
    started (Clock, the UTC now, replaced by the tests).
  - Times are shown as the server sends them (localStart, localEnd): the
    client converts no zone. }

interface

uses
  SysUtils,
  Classes,
  PascalJsonMapper.Json,
  Agenda.Client,
  Agenda.Appointments.Dtos,
  Agenda.Day.Dtos,
  Agenda.Professionals.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Models;

const
  TEXT_CHANGED_FIRST = 'Someone changed this appointment first. The day was read again.';

type
  TDayModel = class(TDesktopModel)
  private
    FClient: TAgendaClient;
    FDate: TDateTime;
    FProfessionalId: string;
    FProfessionals: TProfessionalArray;
    FRows: TDayAppointmentArray;
    FTimeZone: string;
    FSelectedId: string;
    FLoadSeq: Integer;
    FLoading: Boolean;
    FChanging: Boolean;
    FClock: TClockFunc;
    function SystemClock: TDateTime;
    procedure Load;
    procedure Change(const AStatus: string; ACancel: Boolean);
    function Started(const ARow: IDayAppointment): Boolean;
  public
    /// AClient: the logged-in client, not owned. AToday: the local date to
    /// open on.
    constructor Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient; AToday: TDateTime);
    /// Reads the professionals (for the filter) and the day.
    procedure Open;
    procedure Reload;
    /// The 60-second timer: a reload unless a call runs.
    procedure Tick;
    procedure SetDate(ADate: TDateTime);
    procedure NextDay;
    procedure PreviousDay;
    /// '' for everyone.
    procedure SetProfessional(const AProfessionalId: string);
    procedure Select(AIndex: Integer);
    /// -1 when nothing is selected.
    function SelectedIndex: Integer;
    function Selected: IDayAppointment;
    function CanConfirm: Boolean;
    function CanCancel: Boolean;
    function CanMarkDone: Boolean;
    function CanMarkNoShow: Boolean;
    /// A booked or confirmed one moves (the move dialog, TMoveModel).
    function CanMove: Boolean;
    procedure Confirm;
    procedure Cancel;
    procedure MarkDone;
    procedure MarkNoShow;
    /// 'YYYY-MM-DD'
    function DateText: string;
    property Date: TDateTime read FDate;
    property ProfessionalId: string read FProfessionalId;
    property Professionals: TProfessionalArray read FProfessionals;
    property Rows: TDayAppointmentArray read FRows;
    property TimeZone: string read FTimeZone;
    property Loading: Boolean read FLoading;
    property Clock: TClockFunc read FClock write FClock;
  end;

implementation

uses
  DateUtils;

type
  TDayTask = class(TAgendaTask)
  protected
    FModel: TDayModel;
  end;

  TOpenTask = class(TDayTask)
  private
    FProfessionals: TProfessionalArray;
  protected
    procedure Run; override;
    procedure Done; override;
  end;

  TLoadTask = class(TDayTask)
  private
    FSeq: Integer;
    FDate, FProfessionalId: string;
    FDay: IDay;
  protected
    procedure Run; override;
    procedure Done; override;
  end;

  TChangeTask = class(TDayTask)
  private
    FId: string;
    FVersion: Integer;
    FStatus: string;
    FCancel: Boolean;
  protected
    procedure Run; override;
    procedure Done; override;
  end;

{ TOpenTask }

procedure TOpenTask.Run;
begin
  FProfessionals := FModel.FClient.ActiveProfessionals;
end;

procedure TOpenTask.Done;
begin
  if FModel.Finished(Error) then
    FModel.FProfessionals := FProfessionals;
  FModel.Changed;
end;

{ TLoadTask }

procedure TLoadTask.Run;
begin
  FDay := FModel.FClient.GetDay(FDate, FProfessionalId);
end;

procedure TLoadTask.Done;
begin
  // A newer read was asked for: this one's answer is old.
  if FSeq <> FModel.FLoadSeq then
  begin
    FModel.Finished(FModel.Error);
    Exit;
  end;
  FModel.FLoading := False;
  if FModel.Finished(Error) then
  begin
    FModel.FRows := FDay.Appointments;
    FModel.FTimeZone := FDay.TimeZone;
    if FModel.SelectedIndex < 0 then
      FModel.FSelectedId := '';
  end;
  FModel.Changed;
end;

{ TChangeTask }

procedure TChangeTask.Run;
begin
  if FCancel then
    FModel.FClient.Cancel(FId, FVersion)
  else
    FModel.FClient.SetStatus(FId, FVersion, FStatus);
end;

procedure TChangeTask.Done;
var
  LError: TUiError;
begin
  FModel.FChanging := False;
  LError := Error;
  if LError.Kind = ekConflict then
  begin
    FModel.Finished(TUiError.None);
    FModel.SetNotice(TEXT_CHANGED_FIRST);
  end
  else
    FModel.Finished(LError);
  // Read again after any answer: the day shows what the server has.
  if LError.Kind in [ekNone, ekConflict] then
    FModel.Load
  else
    FModel.Changed;
end;

{ TDayModel }

constructor TDayModel.Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
  AToday: TDateTime);
begin
  inherited Create(ARunner);
  FClient := AClient;
  FDate := Trunc(AToday);
  FClock := SystemClock;
end;

function TDayModel.SystemClock: TDateTime;
begin
  // Seconds are enough to tell whether an appointment started.
  Result := UnixToDateTime(DateTimeToUnix(Now, False));
end;

function TDayModel.DateText: string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd', FDate);
end;

procedure TDayModel.Open;
var
  LTask: TOpenTask;
begin
  LTask := TOpenTask.Create(Self);
  LTask.FModel := Self;
  StartTask(LTask);
  Load;
end;

procedure TDayModel.Load;
var
  LTask: TLoadTask;
begin
  Inc(FLoadSeq);
  FLoading := True;
  LTask := TLoadTask.Create(Self);
  LTask.FModel := Self;
  LTask.FSeq := FLoadSeq;
  LTask.FDate := DateText;
  LTask.FProfessionalId := FProfessionalId;
  StartTask(LTask);
end;

procedure TDayModel.Reload;
begin
  SetNotice('');
  Load;
end;

procedure TDayModel.Tick;
begin
  if not Busy then
    Load;
end;

procedure TDayModel.SetDate(ADate: TDateTime);
begin
  FDate := Trunc(ADate);
  FRows := nil;
  FSelectedId := '';
  Reload;
end;

procedure TDayModel.NextDay;
begin
  SetDate(FDate + 1);
end;

procedure TDayModel.PreviousDay;
begin
  SetDate(FDate - 1);
end;

procedure TDayModel.SetProfessional(const AProfessionalId: string);
begin
  FProfessionalId := AProfessionalId;
  FRows := nil;
  FSelectedId := '';
  Reload;
end;

procedure TDayModel.Select(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex <= High(FRows)) then
    FSelectedId := FRows[AIndex].Id
  else
    FSelectedId := '';
  Changed;
end;

function TDayModel.SelectedIndex: Integer;
var
  I: Integer;
begin
  if FSelectedId <> '' then
    for I := 0 to High(FRows) do
      if FRows[I].Id = FSelectedId then
        Exit(I);
  Result := -1;
end;

function TDayModel.Selected: IDayAppointment;
var
  I: Integer;
begin
  I := SelectedIndex;
  if I >= 0 then
    Result := FRows[I]
  else
    Result := nil;
end;

function TDayModel.Started(const ARow: IDayAppointment): Boolean;
begin
  Result := TDateTime(ARow.StartsAt) <= FClock();
end;

function TDayModel.CanConfirm: Boolean;
var
  LRow: IDayAppointment;
begin
  LRow := Selected;
  Result := (not FChanging) and (LRow <> nil) and (LRow.Status = STATUS_BOOKED);
end;

function TDayModel.CanCancel: Boolean;
var
  LRow: IDayAppointment;
begin
  LRow := Selected;
  Result := (not FChanging) and (LRow <> nil) and
    ((LRow.Status = STATUS_BOOKED) or (LRow.Status = STATUS_CONFIRMED));
end;

function TDayModel.CanMarkDone: Boolean;
var
  LRow: IDayAppointment;
begin
  LRow := Selected;
  Result := (not FChanging) and (LRow <> nil) and
    ((LRow.Status = STATUS_BOOKED) or (LRow.Status = STATUS_CONFIRMED)) and Started(LRow);
end;

function TDayModel.CanMarkNoShow: Boolean;
begin
  Result := CanMarkDone;
end;

function TDayModel.CanMove: Boolean;
begin
  Result := CanCancel;
end;

procedure TDayModel.Change(const AStatus: string; ACancel: Boolean);
var
  LTask: TChangeTask;
  LRow: IDayAppointment;
begin
  LRow := Selected;
  FChanging := True;
  SetNotice('');
  SetError(TUiError.None);
  LTask := TChangeTask.Create(Self);
  LTask.FModel := Self;
  LTask.FId := LRow.Id;
  LTask.FVersion := LRow.Version;
  LTask.FStatus := AStatus;
  LTask.FCancel := ACancel;
  StartTask(LTask);
end;

procedure TDayModel.Confirm;
begin
  if CanConfirm then
    Change(STATUS_CONFIRMED, False);
end;

procedure TDayModel.Cancel;
begin
  if CanCancel then
    Change('', True);
end;

procedure TDayModel.MarkDone;
begin
  if CanMarkDone then
    Change(STATUS_DONE, False);
end;

procedure TDayModel.MarkNoShow;
begin
  if CanMarkNoShow then
    Change(STATUS_NO_SHOW, False);
end;

end.
