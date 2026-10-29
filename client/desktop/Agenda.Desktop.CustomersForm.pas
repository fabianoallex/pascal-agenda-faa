unit Agenda.Desktop.CustomersForm;

{ The customers' dialog (TCustomersModel): a search, the list a page at a
  time, New and Edit (TCustomerForm; a double click edits too). After a
  save the page is read again with the customer selected. Built in code
  with OPCB, the same source on the VCL and the LCL. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  Forms, Classes, Controls, StdCtrls, ExtCtrls, ComCtrls, Graphics,
  {$ELSE}
  Vcl.Forms, System.Classes, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.ComCtrls,
  Vcl.Graphics,
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
  TCustomersForm = class(TForm)
  private
    FRunner: IUiTaskRunner;
    FClient: TAgendaClient;
    FModel: TCustomersModel;
    FSearch: TEdit;
    FList: TListView;
    FPage: TLabel;
    FPrevious, FNext: TButton;
    FEdit: TButton;
    FStatus: TLabel;
    FRendering: Boolean;
    procedure Build;
    procedure Render(Sender: TObject);
    procedure SearchClick(Sender: TObject);
    procedure PreviousClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure NewClick(Sender: TObject);
    procedure EditClick(Sender: TObject);
    procedure ListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure EditCustomer(const ACustomer: ICustomer);
  public
    constructor CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient);
    destructor Destroy; override;
    class procedure Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
      AClient: TAgendaClient);
  end;

implementation

uses
  Agenda.Desktop.CustomerForm;

constructor TCustomersForm.CreateFor(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient);
begin
  inherited CreateNew(AOwner);
  FRunner := ARunner;
  FClient := AClient;
  Build;
  FModel := TCustomersModel.Create(ARunner, AClient);
  FModel.OnChange := Render;
  FModel.Search('');
end;

destructor TCustomersForm.Destroy;
begin
  FModel.Free;
  inherited;
end;

class procedure TCustomersForm.Execute(AOwner: TComponent; const ARunner: IUiTaskRunner;
  AClient: TAgendaClient);
var
  LForm: TCustomersForm;
begin
  LForm := TCustomersForm.CreateFor(AOwner, ARunner, AClient);
  try
    LForm.ShowModal;
  finally
    LForm.Free;
  end;
end;

procedure TCustomersForm.Build;
var
  LCreator: TControlCreator;
  LColumn: TListColumn;
  LFind, LClose: TButton;
begin
  Caption := 'Agenda: customers';
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
      .Add(TControlBuilder.Create(TEdit, 'edtSearch', FSearch).WithWidth(300).WithHeight(23))
      .Add(TControlBuilder.Create(TButton, 'btnFind', LFind).WithCaption('Find').WithWidth(80)
        .WithHeight(23).WithOnClick(SearchClick))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TListView, 'lvCustomers', FList).WithWidth(540).WithHeight(260))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TButton, 'btnPrevious', FPrevious).WithCaption('<').WithWidth(30)
        .WithHeight(23).WithOnClick(PreviousClick))
      .Add(TControlBuilder.Create(TLabel, 'lblPage', FPage).WithCaption('').WithWidth(150)
        .WithHeight(23))
      .Add(TControlBuilder.Create(TButton, 'btnNext', FNext).WithCaption('>').WithWidth(30)
        .WithHeight(23).WithOnClick(NextClick))
      .BreakLine(8)
      .Add(TControlBuilder.Create(TLabel, 'lblStatus', FStatus).WithCaption('').WithWidth(540)
        .WithHeight(30))
      .BreakLine(4)
      .IncLeft(272)
      .Add(TControlBuilder.Create(TButton, 'btnNew').WithCaption('New...').WithWidth(80)
        .WithHeight(25).WithOnClick(NewClick))
      .Add(TControlBuilder.Create(TButton, 'btnEdit', FEdit).WithCaption('Edit...').WithWidth(80)
        .WithHeight(25).WithOnClick(EditClick))
      .Add(TControlBuilder.Create(TButton, 'btnClose', LClose).WithCaption('Close').WithWidth(80)
        .WithHeight(25))
      .RecalcParentSize(12, 12);
  finally
    LCreator.Free;
  end;
  CenterLabels(Self);
  FPage.Alignment := taCenter;
  FStatus.WordWrap := True;
  FStatus.Layout := tlTop;
  LFind.Default := True;
  LClose.Cancel := True;
  LClose.ModalResult := mrCancel;
  FList.ViewStyle := vsReport;
  FList.ReadOnly := True;
  FList.RowSelect := True;
  FList.HideSelection := False;
  FList.OnSelectItem := ListSelect;
  FList.OnDblClick := EditClick;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Name';
  LColumn.Width := 200;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Phone';
  LColumn.Width := 140;
  LColumn := FList.Columns.Add;
  LColumn.Caption := 'Email';
  LColumn.Width := 175;
  ActiveControl := FSearch;
end;

procedure TCustomersForm.Render(Sender: TObject);
var
  I: Integer;
  LItem: TListItem;
  LCustomer: ICustomer;
begin
  FRendering := True;
  try
    FList.Items.BeginUpdate;
    try
      FList.Items.Clear;
      for I := 0 to High(FModel.Customers) do
      begin
        LCustomer := FModel.Customers[I];
        LItem := FList.Items.Add;
        LItem.Caption := LCustomer.Name;
        LItem.SubItems.Add(LCustomer.Phone.ValueOr(''));
        LItem.SubItems.Add(LCustomer.Email.ValueOr(''));
      end;
    finally
      FList.Items.EndUpdate;
    end;
    I := FModel.SelectedIndex;
    if I >= 0 then
    begin
      FList.Items[I].Selected := True;
      FList.Items[I].MakeVisible(False);
    end;
    if FModel.Info.TotalPages > 0 then
      FPage.Caption := Format('Page %d of %d', [FModel.Info.Page, FModel.Info.TotalPages])
    else
      FPage.Caption := '';
    FPrevious.Enabled := FModel.CanPreviousPage;
    FNext.Enabled := FModel.CanNextPage;
    FEdit.Enabled := FModel.Selected <> nil;
    if not FModel.Error.IsNone then
    begin
      FStatus.Font.Color := clRed;
      FStatus.Caption := FModel.Error.Text;
    end
    else
    begin
      FStatus.Font.Color := clWindowText;
      if FModel.Busy then
        FStatus.Caption := 'Reading...'
      else
        FStatus.Caption := Format('Customers: %d', [FModel.Info.Total]);
    end;
  finally
    FRendering := False;
  end;
end;

procedure TCustomersForm.SearchClick(Sender: TObject);
begin
  FModel.Search(FSearch.Text);
end;

procedure TCustomersForm.PreviousClick(Sender: TObject);
begin
  FModel.PreviousPage;
end;

procedure TCustomersForm.NextClick(Sender: TObject);
begin
  FModel.NextPage;
end;

procedure TCustomersForm.EditCustomer(const ACustomer: ICustomer);
var
  LSaved: ICustomer;
begin
  LSaved := TCustomerForm.Execute(Self, FRunner, FClient, ACustomer);
  if LSaved = nil then
    Exit;
  // A new one: searched by its name, so it is on the page read.
  if ACustomer = nil then
  begin
    FSearch.Text := LSaved.Name;
    FModel.Search(LSaved.Name, LSaved.Id);
  end
  else
    FModel.Reload(LSaved.Id);
end;

procedure TCustomersForm.NewClick(Sender: TObject);
begin
  EditCustomer(nil);
end;

procedure TCustomersForm.EditClick(Sender: TObject);
begin
  if FModel.Selected <> nil then
    EditCustomer(FModel.Selected);
end;

procedure TCustomersForm.ListSelect(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if FRendering then
    Exit;
  if Selected and (Item <> nil) then
    FModel.Select(Item.Index)
  else if FList.Selected = nil then
    FModel.Select(-1);
end;

procedure TCustomersForm.HandleCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  FModel.OnChange := nil;
  CanClose := True;
end;

end.
