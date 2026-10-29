unit Agenda.Desktop.CustomerForm;

{ One customer's dialog (TCustomerEditModel): new, or an edit of one read.
  Built in code with OPCB, the same source on the VCL and the LCL. The
  server's field failures show under the fields, each next to its name.
  Execute returns the customer saved, nil when the dialog was closed. }

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
  Agenda.Customers.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Customers;

type
  TCustomerForm = class(TForm)
  private
    FModel: TCustomerEditModel;
    FName: TEdit;
    FPhone: TEdit;
    FEmail: TEdit;
    FStatus: TLabel;
    FSave: TButton;
    FRendering: Boolean;
    procedure Build;
    procedure Render(Sender: TObject);
    procedure HandleSaved(Sender: TObject);
    procedure InputChanged(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
  public
    /// ACustomer nil: a new one.
    constructor CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient; const ACustomer: ICustomer);
    destructor Destroy; override;
    /// Shows the dialog; the customer saved, or nil.
    class function Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient; const ACustomer: ICustomer): ICustomer;
    /// The customer saved (nil before).
    function Saved: ICustomer;
  end;

/// What a screen shows for AError: its text, or each field's message, one
/// a line, when there are fields (the server's messages name their field).
function UiErrorLines(const AError: TUiError): string;

implementation

function UiErrorLines(const AError: TUiError): string;
var
  I: Integer;
begin
  if Length(AError.Fields) = 0 then
    Exit(AError.Text);
  Result := '';
  for I := 0 to High(AError.Fields) do
  begin
    if Result <> '' then
      Result := Result + sLineBreak;
    Result := Result + AError.Fields[I].Message;
  end;
end;

constructor TCustomerForm.CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient; const ACustomer: ICustomer);
begin
  inherited CreateNew(AOwner);
  if ACustomer = nil then
    FModel := TCustomerEditModel.CreateNew(ARunner, AClient)
  else
    FModel := TCustomerEditModel.CreateEdit(ARunner, AClient, ACustomer);
  Build;
  FName.Text := FModel.Name;
  FPhone.Text := FModel.Phone;
  FEmail.Text := FModel.Email;
  FName.OnChange := InputChanged;
  FPhone.OnChange := InputChanged;
  FEmail.OnChange := InputChanged;
  FModel.OnChange := Render;
  FModel.OnSaved := HandleSaved;
  Render(nil);
end;

destructor TCustomerForm.Destroy;
begin
  FModel.Free;
  inherited;
end;

class function TCustomerForm.Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient; const ACustomer: ICustomer): ICustomer;
var
  LForm: TCustomerForm;
begin
  LForm := TCustomerForm.CreateFor(AOwner, ARunner, AClient, ACustomer);
  try
    if LForm.ShowModal = mrOk then
      Result := LForm.FModel.Saved
    else
      Result := nil;
  finally
    LForm.Free;
  end;
end;

function TCustomerForm.Saved: ICustomer;
begin
  Result := FModel.Saved;
end;

procedure TCustomerForm.Build;
var
  LCreator: TControlCreator;
  LClose: TButton;
begin
  if FModel.IsNew then
    Caption := 'Agenda: new customer'
  else
    Caption := 'Agenda: customer';
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  OnCloseQuery := HandleCloseQuery;
  LCreator := TControlCreator.Create;
  try
    LCreator
      .SetOwnerAndParent(Self, Self)
      .SetTopLeft(12, 12)
      .SetControlHeight(23)
      .GridInit(3, 2)
      .GridSetCellWidthAndHeight(260, 30)
      .GridSetColWidth(0, 80)
      .GridCellStrechHorizontal
      .Add(TControlBuilder.Create(TLabel).WithCaption('Name'))
      .Add(TControlBuilder.Create(TEdit, 'edtName', FName))
      .Add(TControlBuilder.Create(TLabel).WithCaption('Phone'))
      .Add(TControlBuilder.Create(TEdit, 'edtPhone', FPhone))
      .Add(TControlBuilder.Create(TLabel).WithCaption('Email'))
      .Add(TControlBuilder.Create(TEdit, 'edtEmail', FEmail))
      .GridFinish
      .UnsetControlHeight
      .SetDirection(cpdHorizontal)
      .BreakLine(4)
      .Add(TControlBuilder.Create(TLabel, 'lblStatus', FStatus).WithCaption('').WithWidth(340)
        .WithHeight(48))
      .BreakLine(8)
      .IncLeft(172)
      .Add(TControlBuilder.Create(TButton, 'btnSave', FSave).WithCaption('Save').WithWidth(80)
        .WithHeight(25).WithOnClick(SaveClick))
      .Add(TControlBuilder.Create(TButton, 'btnClose', LClose).WithCaption('Close').WithWidth(80)
        .WithHeight(25))
      .RecalcParentSize(12, 12);
  finally
    LCreator.Free;
  end;
  CenterLabels(Self);
  FStatus.WordWrap := True;
  FStatus.Layout := tlTop;
  FSave.Default := True;
  LClose.Cancel := True;
  LClose.ModalResult := mrCancel;
end;

procedure TCustomerForm.Render(Sender: TObject);
begin
  FRendering := True;
  try
    FSave.Enabled := FModel.CanSave;
    if not FModel.Error.IsNone then
    begin
      FStatus.Font.Color := clRed;
      FStatus.Caption := UiErrorLines(FModel.Error);
    end
    else
    begin
      FStatus.Font.Color := clWindowText;
      if FModel.Busy then
        FStatus.Caption := 'Saving...'
      else if Trim(FModel.Name) = '' then
        FStatus.Caption := 'A name is required.'
      else
        FStatus.Caption := '';
    end;
  finally
    FRendering := False;
  end;
end;

procedure TCustomerForm.InputChanged(Sender: TObject);
begin
  if FRendering then
    Exit;
  // Only the field that changed (a render doesn't write the edits back).
  if Sender = FName then
    FModel.Name := FName.Text
  else if Sender = FPhone then
    FModel.Phone := FPhone.Text
  else if Sender = FEmail then
    FModel.Email := FEmail.Text;
end;

procedure TCustomerForm.SaveClick(Sender: TObject);
begin
  FModel.Save;
end;

procedure TCustomerForm.HandleSaved(Sender: TObject);
begin
  ModalResult := mrOk;
end;

procedure TCustomerForm.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  FModel.OnChange := nil;
  FModel.OnSaved := nil;
  CanClose := True;
end;

end.
