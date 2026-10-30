unit Agenda.Desktop.MoveForm;

{ The move dialog (TMoveModel), built in code with OPCB, the same source on
  the VCL and the LCL: the appointment on top, the day and its free times,
  Move at the bottom. The day window reads itself again when it closes,
  moved or not (someone else may have changed the appointment). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  Forms, Classes, Controls, StdCtrls, ExtCtrls, Graphics,
  {$ELSE}
  Vcl.Forms, System.Classes, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  {$ENDIF}
  SysUtils,
  OPCB,
  Agenda.Desktop.Ui,
  Agenda.Client,
  Agenda.Availability.Dtos,
  Agenda.Day.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Move;

type
  TMoveForm = class(TForm)
  private
    FModel: TMoveModel;
    FWhat: TLabel;
    FDate: TLabel;
    FSlots: TListBox;
    FStatus: TLabel;
    FMove: TButton;
    FRendering: Boolean;
    // The free times on the list: rebuilt only when the model has others.
    FShownSlots: TAvailableSlotArray;
    procedure Build;
    procedure Render(Sender: TObject);
    procedure Moved(Sender: TObject);
    procedure PreviousClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure SlotClick(Sender: TObject);
    procedure MoveClick(Sender: TObject);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient; const AAppointment: IDayAppointment; ADate: TDateTime);
    destructor Destroy; override;
    /// Shows the dialog; True when the appointment was moved.
    class function Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient; const AAppointment: IDayAppointment; ADate: TDateTime): Boolean;
  end;

implementation

// '2026-11-02T09:00:00' -> '2026-11-02 09:00'
function LocalText(const ALocal: string): string;
begin
  Result := Copy(ALocal, 1, 10) + ' ' + Copy(ALocal, 12, 5);
end;

constructor TMoveForm.CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient; const AAppointment: IDayAppointment; ADate: TDateTime);
begin
  inherited CreateNew(AOwner);
  Build;
  FModel := TMoveModel.Create(ARunner, AClient, AAppointment, ADate);
  FModel.OnChange := Render;
  FModel.OnMoved := Moved;
  FWhat.Caption := Format('%s: %s with %s, now at %s', [AAppointment.CustomerName,
    AAppointment.ServiceName, AAppointment.ProfessionalName, LocalText(AAppointment.LocalStart)]);
  FModel.Open;
end;

destructor TMoveForm.Destroy;
begin
  FModel.Free;
  inherited;
end;

class function TMoveForm.Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient; const AAppointment: IDayAppointment; ADate: TDateTime): Boolean;
var
  LForm: TMoveForm;
begin
  LForm := TMoveForm.CreateFor(AOwner, ARunner, AClient, AAppointment, ADate);
  try
    Result := LForm.ShowModal = mrOk;
  finally
    LForm.Free;
  end;
end;

procedure TMoveForm.Build;
var
  LCreator: TControlCreator;
  LClose: TButton;
begin
  Caption := 'Agenda: move';
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  OnCloseQuery := HandleCloseQuery;
  LCreator := TControlCreator.Create;
  try
    LCreator
      .SetOwnerAndParent(Self, Self)
      .SetTopLeft(12, 12)
      .SetDirection(cpdHorizontal)
      .SetSpace(8, 5)
      .Add(TControlBuilder.Create(TLabel, 'lblWhat', FWhat).WithCaption('').WithWidth(360)
        .WithHeight(36))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TLabel).WithCaption('Day').WithWidth(85).WithHeight(23))
      .Add(TControlBuilder.Create(TButton, 'btnPrevious').WithCaption('<').WithWidth(30)
        .WithHeight(23).WithOnClick(PreviousClick))
      .Add(TControlBuilder.Create(TLabel, 'lblDate', FDate).WithCaption('').WithWidth(80)
        .WithHeight(23))
      .Add(TControlBuilder.Create(TButton, 'btnNext').WithCaption('>').WithWidth(30)
        .WithHeight(23).WithOnClick(NextClick))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TLabel).WithCaption('Free times').WithWidth(85).WithHeight(23))
      .Add(TControlBuilder.Create(TListBox, 'lbxSlots', FSlots).WithWidth(160).WithHeight(200))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TLabel, 'lblStatus', FStatus).WithCaption('').WithWidth(360)
        .WithHeight(30))
      .BreakLine(4)
      .IncLeft(192)
      .Add(TControlBuilder.Create(TButton, 'btnMove', FMove).WithCaption('Move').WithWidth(80)
        .WithHeight(25).WithOnClick(MoveClick))
      .Add(TControlBuilder.Create(TButton, 'btnClose', LClose).WithCaption('Close').WithWidth(80)
        .WithHeight(25))
      .RecalcParentSize(12, 12);
  finally
    LCreator.Free;
  end;
  CenterLabels(Self);
  FWhat.WordWrap := True;
  FWhat.Layout := tlTop;
  FStatus.WordWrap := True;
  FStatus.Layout := tlTop;
  FSlots.OnClick := SlotClick;
  FMove.Default := True;
  LClose.Cancel := True;
  LClose.ModalResult := mrCancel;
end;

procedure TMoveForm.Render(Sender: TObject);
var
  I: Integer;
begin
  FRendering := True;
  try
    FDate.Caption := FModel.DateText;
    if (Pointer(FShownSlots) <> Pointer(FModel.Slots)) or
      (FSlots.Items.Count <> Length(FModel.Slots)) then
    begin
      FSlots.Items.BeginUpdate;
      try
        FSlots.Items.Clear;
        for I := 0 to High(FModel.Slots) do
          FSlots.Items.Add(Copy(FModel.Slots[I].Local, 12, 5));
      finally
        FSlots.Items.EndUpdate;
      end;
      FShownSlots := FModel.Slots;
    end;
    if FSlots.ItemIndex <> FModel.SlotIndex then
      FSlots.ItemIndex := FModel.SlotIndex;
    FMove.Enabled := FModel.CanMove;
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
      if FModel.Busy then
        FStatus.Caption := 'Working...'
      else if Length(FModel.Slots) = 0 then
        FStatus.Caption := 'No free time on this day.'
      else
        FStatus.Caption := '';
    end;
  finally
    FRendering := False;
  end;
end;

procedure TMoveForm.Moved(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TMoveForm.PreviousClick(Sender: TObject);
begin
  FModel.PreviousDay;
end;

procedure TMoveForm.NextClick(Sender: TObject);
begin
  FModel.NextDay;
end;

procedure TMoveForm.SlotClick(Sender: TObject);
begin
  if not FRendering then
    FModel.SelectSlot(FSlots.ItemIndex);
end;

procedure TMoveForm.MoveClick(Sender: TObject);
begin
  FModel.Move;
end;

procedure TMoveForm.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // The model's tasks still running: their Done is skipped (the runner
  // forgets the model when it is freed with the form).
  FModel.OnChange := nil;
  FModel.OnMoved := nil;
  CanClose := True;
end;

end.
