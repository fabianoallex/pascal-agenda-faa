unit Agenda.Desktop.DayForm;

{ The main window: one day of the agenda (TDayModel), built in code with
  OPCB, the same source on the VCL and the LCL.

  - A bar on top (the previous and next day, today, the professional, read
    again, book), the day's list, and a bar at the bottom with what the
    selected appointment allows and a status line (the error or the notice).
  - F5 reads the day again; a 60-second timer too (the model skips it while
    a call runs). The booking dialog, on success, makes the day read again.
  - A lost session opens the login again on the same client
    (TLoginModel.CreateAgain); cancelled, the program closes.
  - Closing waits for the calls still running (the runner's WaitIdle,
    pumping the queue), then the program logs out (Agenda.Desktop.App). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  Forms, Classes, Controls, StdCtrls, ExtCtrls, ComCtrls, Graphics, LCLType,
  {$ELSE}
  Winapi.Windows, Vcl.Forms, System.Classes, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls,
  Vcl.ComCtrls, Vcl.Graphics,
  {$ENDIF}
  SysUtils,
  OPCB,
  Agenda.Desktop.Ui,
  Agenda.Client,
  Agenda.Appointments.Dtos,
  Agenda.Day.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Day;

type
  TDayForm = class(TForm)
  private
    FRunner: TPoolTaskRunner;
    FRunnerRef: IUiTaskRunner;
    FClient: TAgendaClient;
    FTenant: string;
    FEmail: string;
    FModel: TDayModel;
    FDate: TLabel;
    FProfessional: TComboBox;
    FProfessionalIds: TStringList;
    FList: TListView;
    FStatus: TLabel;
    FConfirm, FDone, FNoShow, FCancel: TButton;
    FTimer: TTimer;
    FRendering: Boolean;
    procedure Build;
    procedure Render(Sender: TObject);
    procedure RenderProfessionals;
    procedure RenderRows;
    procedure SessionLost(Sender: TObject);
    procedure PreviousClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure TodayClick(Sender: TObject);
    procedure ReloadClick(Sender: TObject);
    procedure BookClick(Sender: TObject);
    procedure ConfirmClick(Sender: TObject);
    procedure DoneClick(Sender: TObject);
    procedure NoShowClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
    procedure ProfessionalChange(Sender: TObject);
    procedure ListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure Tick(Sender: TObject);
    procedure KeyDownHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    /// No .dfm/.lfm: CreateNew, and the runner, the client and the login's
    /// company and email from Agenda.Desktop.App's Desktop (so
    /// Application.CreateForm can make it the main form).
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

uses
  Agenda.Desktop.App,
  Agenda.Desktop.Login,
  Agenda.Desktop.LoginForm,
  Agenda.Desktop.BookingForm;

function StatusText(const AStatus: string): string;
begin
  if AStatus = STATUS_BOOKED then
    Result := 'Booked'
  else if AStatus = STATUS_CONFIRMED then
    Result := 'Confirmed'
  else if AStatus = STATUS_DONE then
    Result := 'Done'
  else if AStatus = STATUS_NO_SHOW then
    Result := 'No show'
  else if AStatus = STATUS_CANCELLED then
    Result := 'Cancelled'
  else
    Result := AStatus;
end;

// '2026-11-02T09:00:00' -> '09:00'
function TimeOf(const ALocal: string): string;
begin
  Result := Copy(ALocal, 12, 5);
end;

constructor TDayForm.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  FRunner := Desktop.Runner;
  FRunnerRef := Desktop.RunnerRef;
  FClient := Desktop.Client;
  FTenant := Desktop.Tenant;
  FEmail := Desktop.Email;
  FProfessionalIds := TStringList.Create;
  Build;
  FModel := TDayModel.Create(FRunnerRef, FClient, Date);
  FModel.OnChange := Render;
  FModel.OnSessionLost := SessionLost;
  FModel.Open;
  FTimer.Enabled := True;
end;

destructor TDayForm.Destroy;
begin
  FModel.Free;
  FProfessionalIds.Free;
  inherited;
end;

procedure TDayForm.Build;
var
  LCreator: TControlCreator;
  LColumn: TListColumn;
begin
  Caption := 'Agenda';
  Width := 820;
  Height := 520;
  Position := poScreenCenter;
  KeyPreview := True;
  OnKeyDown := KeyDownHandler;
  OnCloseQuery := HandleCloseQuery;
  LCreator := TControlCreator.Create;
  try
    LCreator
      .SetOwnerAndParent(Self, Self)
      .SubLevel(TControlBuilder.Create(TPanel, 'pnlTop').WithAlign(alTop).WithHeight(40)
        .WithCaption(''))
        .SetDirection(cpdHorizontal)
        .SetTopLeft(8, 8)
        .SetSpace(5, 5)
        .SetControlHeight(25)
        .Add(TControlBuilder.Create(TButton, 'btnPrevious').WithCaption('<').WithWidth(30)
          .WithOnClick(PreviousClick))
        .Add(TControlBuilder.Create(TLabel, 'lblDate', FDate).WithCaption('').WithWidth(90))
        .Add(TControlBuilder.Create(TButton, 'btnNext').WithCaption('>').WithWidth(30)
          .WithOnClick(NextClick))
        .Add(TControlBuilder.Create(TButton, 'btnToday').WithCaption('Today').WithWidth(60)
          .WithOnClick(TodayClick))
        .Add(TControlBuilder.Create(TComboBox, 'cbxProfessional', FProfessional).WithWidth(200))
        .Add(TControlBuilder.Create(TButton, 'btnReload').WithCaption('Reload (F5)').WithWidth(90)
          .WithOnClick(ReloadClick))
        .Add(TControlBuilder.Create(TButton, 'btnBook').WithCaption('Book...').WithWidth(80)
          .WithOnClick(BookClick))
      .SuperLevel
      .SubLevel(TControlBuilder.Create(TPanel, 'pnlBottom').WithAlign(alBottom).WithHeight(72)
        .WithCaption(''))
        .SetDirection(cpdHorizontal)
        .SetTopLeft(8, 8)
        .SetSpace(5, 5)
        .SetControlHeight(25)
        .Add(TControlBuilder.Create(TButton, 'btnConfirm', FConfirm).WithCaption('Confirm')
          .WithWidth(80).WithOnClick(ConfirmClick))
        .Add(TControlBuilder.Create(TButton, 'btnDone', FDone).WithCaption('Done')
          .WithWidth(80).WithOnClick(DoneClick))
        .Add(TControlBuilder.Create(TButton, 'btnNoShow', FNoShow).WithCaption('No show')
          .WithWidth(80).WithOnClick(NoShowClick))
        .Add(TControlBuilder.Create(TButton, 'btnCancel', FCancel).WithCaption('Cancel it')
          .WithWidth(80).WithOnClick(CancelClick))
        .BreakLine(4)
        .Add(TControlBuilder.Create(TLabel, 'lblStatus', FStatus).WithCaption('').WithWidth(780))
      .SuperLevel
      .Add(TControlBuilder.Create(TListView, 'lvDay', FList).WithAlign(alClient));
  finally
    LCreator.Free;
  end;
  CenterLabels(Self);
  FTimer := TTimer.Create(Self);
  FTimer.Enabled := False;
  FTimer.Interval := 60000;
  FTimer.OnTimer := Tick;
  FProfessional.Style := csDropDownList;
  FProfessional.OnChange := ProfessionalChange;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.HideSelection := False;
  FList.OnSelectItem := ListSelect;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Time';
  LColumn.Width := 100;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Customer';
  LColumn.Width := 220;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Service';
  LColumn.Width := 160;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Professional';
  LColumn.Width := 160;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Status';
  LColumn.Width := 100;
end;

procedure TDayForm.RenderProfessionals;
var
  I, LIndex: Integer;
begin
  if FProfessional.Items.Count = Length(FModel.Professionals) + 1 then
    Exit;
  FProfessional.Items.BeginUpdate;
  try
    FProfessional.Items.Clear;
    FProfessionalIds.Clear;
    FProfessional.Items.Add('Everyone');
    FProfessionalIds.Add('');
    for I := 0 to High(FModel.Professionals) do
    begin
      FProfessional.Items.Add(FModel.Professionals[I].Name);
      FProfessionalIds.Add(FModel.Professionals[I].Id);
    end;
  finally
    FProfessional.Items.EndUpdate;
  end;
  LIndex := FProfessionalIds.IndexOf(FModel.ProfessionalId);
  if LIndex < 0 then
    LIndex := 0;
  FProfessional.ItemIndex := LIndex;
end;

procedure TDayForm.RenderRows;
var
  I: Integer;
  LRow: IDayAppointment;
  LItem: TListItem;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for I := 0 to High(FModel.Rows) do
    begin
      LRow := FModel.Rows[I];
      LItem := FList.Items.Add;
      LItem.Caption := TimeOf(LRow.LocalStart) + ' - ' + TimeOf(LRow.LocalEnd);
      LItem.SubItems.Add(LRow.CustomerName);
      LItem.SubItems.Add(LRow.ServiceName);
      LItem.SubItems.Add(LRow.ProfessionalName);
      LItem.SubItems.Add(StatusText(LRow.Status));
    end;
  finally
    FList.Items.EndUpdate;
  end;
  I := FModel.SelectedIndex;
  if I >= 0 then
    FList.Items[I].Selected := True;
end;

procedure TDayForm.Render(Sender: TObject);
begin
  FRendering := True;
  try
    FDate.Caption := FModel.DateText;
    RenderProfessionals;
    RenderRows;
    FConfirm.Enabled := FModel.CanConfirm;
    FDone.Enabled := FModel.CanMarkDone;
    FNoShow.Enabled := FModel.CanMarkNoShow;
    FCancel.Enabled := FModel.CanCancel;
    if not FModel.Error.IsNone then
    begin
      FStatus.Font.Color := clRed;
      FStatus.Caption := FModel.Error.Text;
    end
    else if FModel.Notice <> '' then
    begin
      FStatus.Font.Color := clMaroon;
      FStatus.Caption := FModel.Notice;
    end
    else
    begin
      FStatus.Font.Color := clWindowText;
      if FModel.Loading then
        FStatus.Caption := 'Reading the day...'
      else
        FStatus.Caption := Format('Appointments: %d (%s)', [Length(FModel.Rows), FModel.TimeZone]);
    end;
  finally
    FRendering := False;
  end;
end;

procedure TDayForm.SessionLost(Sender: TObject);
var
  LLogin: TLoginModel;
  LForm: TLoginForm;
begin
  FTimer.Enabled := False;
  LLogin := TLoginModel.CreateAgain(FRunnerRef, FClient, FTenant, FEmail);
  try
    LForm := TLoginForm.CreateFor(nil, LLogin);
    try
      if LForm.ShowModal <> mrOk then
      begin
        Close;
        Exit;
      end;
    finally
      LForm.Free;
    end;
  finally
    LLogin.Free;
  end;
  FTimer.Enabled := True;
  FModel.Reload;
end;

procedure TDayForm.PreviousClick(Sender: TObject);
begin
  FModel.PreviousDay;
end;

procedure TDayForm.NextClick(Sender: TObject);
begin
  FModel.NextDay;
end;

procedure TDayForm.TodayClick(Sender: TObject);
begin
  FModel.SetDate(Date);
end;

procedure TDayForm.ReloadClick(Sender: TObject);
begin
  FModel.Reload;
end;

procedure TDayForm.BookClick(Sender: TObject);
begin
  if TBookingForm.Execute(Self, FRunnerRef, FClient, FModel.Date) then
    FModel.Reload;
end;

procedure TDayForm.ConfirmClick(Sender: TObject);
begin
  FModel.Confirm;
end;

procedure TDayForm.DoneClick(Sender: TObject);
begin
  FModel.MarkDone;
end;

procedure TDayForm.NoShowClick(Sender: TObject);
begin
  FModel.MarkNoShow;
end;

procedure TDayForm.CancelClick(Sender: TObject);
begin
  FModel.Cancel;
end;

procedure TDayForm.ProfessionalChange(Sender: TObject);
begin
  if FRendering or (FProfessional.ItemIndex < 0) then
    Exit;
  FModel.SetProfessional(FProfessionalIds[FProfessional.ItemIndex]);
end;

procedure TDayForm.ListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if FRendering then
    Exit;
  if Selected and (Item <> nil) then
    FModel.Select(Item.Index)
  else if FList.Selected = nil then
    FModel.Select(-1);
end;

procedure TDayForm.Tick(Sender: TObject);
begin
  FModel.Tick;
end;

procedure TDayForm.KeyDownHandler(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_F5 then
  begin
    FModel.Reload;
    Key := 0;
  end;
end;

procedure TDayForm.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  FTimer.Enabled := False;
  // The calls still running finish while the model and the client are
  // whole; their Done updates nothing once the model is forgotten.
  FModel.OnChange := nil;
  FModel.OnSessionLost := nil;
  FRunnerRef.Forget(FModel);
  FRunner.WaitIdle(15000);
  CanClose := True;
end;

end.
