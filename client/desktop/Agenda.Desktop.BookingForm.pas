unit Agenda.Desktop.BookingForm;

{ The booking dialog (TBookingModel), built in code with OPCB, the same
  source on the VCL and the LCL: the service, the professional and the day
  on top, the free times and the customers side by side (New... creates
  one, TCustomerForm, and chooses it), Book at the bottom. Execute returns
  True when an appointment was booked. }

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
  Agenda.Customers.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Booking;

type
  TBookingForm = class(TForm)
  private
    FRunner: IUiTaskRunner;
    FClient: TAgendaClient;
    FModel: TBookingModel;
    FService: TComboBox;
    FProfessional: TComboBox;
    FDate: TLabel;
    FSlots: TListBox;
    FSearch: TEdit;
    FCustomers: TListBox;
    FStatus: TLabel;
    FBook: TButton;
    FRendering: Boolean;
    // The lists' contents: rebuilt only when the model has others, so a
    // click doesn't scroll them back to the top.
    FShownSlots: TAvailableSlotArray;
    FShownCustomers: TCustomerArray;
    procedure Build;
    procedure Render(Sender: TObject);
    procedure Booked(Sender: TObject);
    procedure ServiceChange(Sender: TObject);
    procedure ProfessionalChange(Sender: TObject);
    procedure PreviousClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure SlotClick(Sender: TObject);
    procedure SearchClick(Sender: TObject);
    procedure NewCustomerClick(Sender: TObject);
    procedure CustomerClick(Sender: TObject);
    procedure BookClick(Sender: TObject);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    constructor CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient; ADate: TDateTime);
    destructor Destroy; override;
    /// Shows the dialog; True when an appointment was booked.
    class function Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient; ADate: TDateTime): Boolean;
  end;

implementation

uses
  Agenda.Desktop.CustomerForm;

constructor TBookingForm.CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient; ADate: TDateTime);
begin
  inherited CreateNew(AOwner);
  FRunner := ARunner;
  FClient := AClient;
  Build;
  FModel := TBookingModel.Create(ARunner, AClient, ADate);
  FModel.OnChange := Render;
  FModel.OnBooked := Booked;
  FModel.Open;
  FModel.Search('');
end;

destructor TBookingForm.Destroy;
begin
  FModel.Free;
  inherited;
end;

class function TBookingForm.Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient; ADate: TDateTime): Boolean;
var
  LForm: TBookingForm;
begin
  LForm := TBookingForm.CreateFor(AOwner, ARunner, AClient, ADate);
  try
    Result := LForm.ShowModal = mrOk;
  finally
    LForm.Free;
  end;
end;

procedure TBookingForm.Build;
var
  LCreator: TControlCreator;
  LClose: TButton;
begin
  Caption := 'Agenda: book';
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  OnCloseQuery := HandleCloseQuery;
  LCreator := TControlCreator.Create;
  try
    LCreator
      .SetOwnerAndParent(Self, Self)
      .SetTopLeft(12, 12)
      .SetControlHeight(23)
      .GridInit(2, 2)
      .GridSetCellWidthAndHeight(300, 30)
      .GridSetColWidth(0, 90)
      .GridCellStrechHorizontal
      .Add(TControlBuilder.Create(TLabel).WithCaption('Service'))
      .Add(TControlBuilder.Create(TComboBox, 'cbxService', FService))
      .Add(TControlBuilder.Create(TLabel).WithCaption('Professional'))
      .Add(TControlBuilder.Create(TComboBox, 'cbxProfessional', FProfessional))
      .GridFinish
      // Every control below has its own height: SetControlHeight would force
      // 23 on the lists too (OPCB applies it over an explicit height).
      .UnsetControlHeight
      .SetDirection(cpdHorizontal)
      .SetSpace(8, 5)
      .BreakLine(4)
      .Add(TControlBuilder.Create(TLabel).WithCaption('Day').WithWidth(85).WithHeight(23))
      .Add(TControlBuilder.Create(TButton, 'btnPrevious').WithCaption('<').WithWidth(30)
        .WithHeight(23).WithOnClick(PreviousClick))
      .Add(TControlBuilder.Create(TLabel, 'lblDate', FDate).WithCaption('').WithWidth(80)
        .WithHeight(23))
      .Add(TControlBuilder.Create(TButton, 'btnNext').WithCaption('>').WithWidth(30)
        .WithHeight(23).WithOnClick(NextClick))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TLabel).WithCaption('Free times').WithWidth(140).WithHeight(23))
      .Add(TControlBuilder.Create(TEdit, 'edtSearch', FSearch).WithWidth(110).WithHeight(23))
      .Add(TControlBuilder.Create(TButton, 'btnSearch').WithCaption('Find customer')
        .WithWidth(85).WithHeight(23).WithOnClick(SearchClick))
      .Add(TControlBuilder.Create(TButton, 'btnNewCustomer').WithCaption('New...')
        .WithWidth(50).WithHeight(23).WithOnClick(NewCustomerClick))
      .BreakLine(4)
      .Add(TControlBuilder.Create(TListBox, 'lbxSlots', FSlots).WithWidth(140).WithHeight(200))
      .Add(TControlBuilder.Create(TListBox, 'lbxCustomers', FCustomers).WithWidth(261)
        .WithHeight(200))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TLabel, 'lblStatus', FStatus).WithCaption('').WithWidth(409)
        .WithHeight(30))
      .BreakLine(4)
      .IncLeft(237)
      .Add(TControlBuilder.Create(TButton, 'btnBook', FBook).WithCaption('Book').WithWidth(80)
        .WithHeight(25).WithOnClick(BookClick))
      .Add(TControlBuilder.Create(TButton, 'btnClose', LClose).WithCaption('Close').WithWidth(80)
        .WithHeight(25))
      .RecalcParentSize(12, 12);
  finally
    LCreator.Free;
  end;
  FStatus.AutoSize := False;
  FStatus.WordWrap := True;
  CenterLabels(Self);
  FStatus.Layout := tlTop;
  FService.Style := csDropDownList;
  FProfessional.Style := csDropDownList;
  FService.OnChange := ServiceChange;
  FProfessional.OnChange := ProfessionalChange;
  FSlots.OnClick := SlotClick;
  FCustomers.OnClick := CustomerClick;
  FBook.Default := True;
  LClose.Cancel := True;
  LClose.ModalResult := mrCancel;
end;

procedure TBookingForm.Render(Sender: TObject);
var
  I, LIndex: Integer;
begin
  FRendering := True;
  try
    if FService.Items.Count <> Length(FModel.Services) then
    begin
      FService.Items.Clear;
      for I := 0 to High(FModel.Services) do
        FService.Items.Add(Format('%s (%d min)', [FModel.Services[I].Name,
          FModel.Services[I].DurationMinutes]));
    end;
    if FProfessional.Items.Count <> Length(FModel.Professionals) then
    begin
      FProfessional.Items.Clear;
      for I := 0 to High(FModel.Professionals) do
        FProfessional.Items.Add(FModel.Professionals[I].Name);
    end;
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
    if (Pointer(FShownCustomers) <> Pointer(FModel.Customers)) or
      (FCustomers.Items.Count <> Length(FModel.Customers)) then
    begin
      FCustomers.Items.BeginUpdate;
      try
        FCustomers.Items.Clear;
        for I := 0 to High(FModel.Customers) do
          FCustomers.Items.Add(FModel.Customers[I].Name);
      finally
        FCustomers.Items.EndUpdate;
      end;
      FShownCustomers := FModel.Customers;
    end;
    LIndex := -1;
    for I := 0 to High(FModel.Customers) do
      if FModel.Customers[I].Id = FModel.CustomerId then
        LIndex := I;
    if FCustomers.ItemIndex <> LIndex then
      FCustomers.ItemIndex := LIndex;
    FBook.Enabled := FModel.CanBook;
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
      else if (FModel.ServiceId <> '') and (FModel.ProfessionalId <> '') and
        (Length(FModel.Slots) = 0) then
        FStatus.Caption := 'No free time on this day.'
      else
        FStatus.Caption := '';
    end;
  finally
    FRendering := False;
  end;
end;

procedure TBookingForm.Booked(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TBookingForm.ServiceChange(Sender: TObject);
begin
  if (not FRendering) and (FService.ItemIndex >= 0) then
    FModel.SetService(FModel.Services[FService.ItemIndex].Id);
end;

procedure TBookingForm.ProfessionalChange(Sender: TObject);
begin
  if (not FRendering) and (FProfessional.ItemIndex >= 0) then
    FModel.SetProfessional(FModel.Professionals[FProfessional.ItemIndex].Id);
end;

procedure TBookingForm.PreviousClick(Sender: TObject);
begin
  FModel.SetDate(FModel.Date - 1);
end;

procedure TBookingForm.NextClick(Sender: TObject);
begin
  FModel.SetDate(FModel.Date + 1);
end;

procedure TBookingForm.SlotClick(Sender: TObject);
begin
  if not FRendering then
    FModel.SelectSlot(FSlots.ItemIndex);
end;

procedure TBookingForm.SearchClick(Sender: TObject);
begin
  FModel.Search(FSearch.Text);
end;

procedure TBookingForm.NewCustomerClick(Sender: TObject);
var
  LCustomer: ICustomer;
begin
  LCustomer := TCustomerForm.Execute(Self, FRunner, FClient, nil);
  if LCustomer <> nil then
    FModel.UseCustomer(LCustomer);
end;

procedure TBookingForm.CustomerClick(Sender: TObject);
begin
  if (not FRendering) and (FCustomers.ItemIndex >= 0) then
    FModel.SelectCustomer(FModel.Customers[FCustomers.ItemIndex].Id);
end;

procedure TBookingForm.BookClick(Sender: TObject);
begin
  FModel.Book;
end;

procedure TBookingForm.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // The model's tasks still running: their Done is skipped (the model is
  // freed with the form; the runner forgets it in its destructor).
  FModel.OnChange := nil;
  FModel.OnBooked := nil;
  CanClose := True;
end;

end.
