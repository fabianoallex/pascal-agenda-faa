unit Agenda.Desktop.Customers;

{$I agenda.inc}

{ The customers' view models (decision 8 of "M6: design"): the list
  (search, pages) and one customer's form (create, or edit).

  TCustomersModel
  - Search reads the first page of a search ('' lists everyone, by name);
    NextPage and PreviousPage move through it; Reload reads the same page
    again (after an edit). A read that comes back after a newer one was
    asked for is dropped.
  - The selection follows the customer's id across reads; Search and
    Reload may name the one to select (a customer just saved).

  TCustomerEditModel
  - New: POST /customers with the name, and the phone and the email when
    typed (an empty one is left out).
  - Edit: PATCH /customers/:id with what changed only, each member in one
    of its three states (CustomerChangeOf): left out when the text is the
    one read, null when it was emptied, the new text otherwise. The name is
    never null (emptied, CanSave is False).
  - The server normalizes and checks the phone and the email: its 400 comes
    back as Error, with the fields (FieldText).
  - Saved holds the answer, and OnSaved is raised. }

interface

uses
  SysUtils,
  Classes,
  Agenda.HttpClient,
  Agenda.Client,
  Agenda.Customers.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Models;

const
  /// Customers a page of the list shows.
  CUSTOMERS_PAGE_SIZE = 20;

type
  TCustomersModel = class(TDesktopModel)
  private
    FClient: TAgendaClient;
    FSearch: string;
    FPage: Integer;
    FInfo: TApiPageInfo;
    FCustomers: TCustomerArray;
    FSelectedId: string;
    FSeq: Integer;
    procedure Load(APage: Integer);
  public
    constructor Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient);
    /// The first page of AText's search ('' for everyone); ASelectId
    /// selected when it is on it (a customer just saved).
    procedure Search(const AText: string; const ASelectId: string = '');
    procedure NextPage;
    procedure PreviousPage;
    /// The same search and page, read again; ASelectId as in Search.
    procedure Reload(const ASelectId: string = '');
    procedure Select(AIndex: Integer);
    /// -1 when nothing is selected.
    function SelectedIndex: Integer;
    function Selected: ICustomer;
    function CanNextPage: Boolean;
    function CanPreviousPage: Boolean;
    property Customers: TCustomerArray read FCustomers;
    property SearchText: string read FSearch;
    /// The page read (Page, TotalPages, Total...).
    property Info: TApiPageInfo read FInfo;
  end;

  TCustomerEditModel = class(TDesktopModel)
  private
    FClient: TAgendaClient;
    FOriginal: ICustomer;
    FName, FPhone, FEmail: string;
    FSaving: Boolean;
    FSaved: ICustomer;
    FOnSaved: TNotifyEvent;
    procedure SetName(const AValue: string);
    procedure SetPhone(const AValue: string);
    procedure SetEmail(const AValue: string);
  public
    /// A new customer.
    constructor CreateNew(const ARunner: IUiTaskRunner; AClient: TAgendaClient);
    /// ACustomer as read: its fields fill the form, and are what a change
    /// is measured against.
    constructor CreateEdit(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
      const ACustomer: ICustomer);
    function IsNew: Boolean;
    /// Edit: something differs from what was read.
    function HasChanges: Boolean;
    function CanSave: Boolean;
    procedure Save;
    property Name: string read FName write SetName;
    property Phone: string read FPhone write SetPhone;
    property Email: string read FEmail write SetEmail;
    property Original: ICustomer read FOriginal;
    property Saved: ICustomer read FSaved;
    property OnSaved: TNotifyEvent read FOnSaved write FOnSaved;
  end;

/// The PATCH from ACustomer as read to the texts typed (trimmed): each
/// member left out when equal, null when emptied (the phone, the email),
/// the text otherwise. The name emptied is left out (never null).
function CustomerChangeOf(const ACustomer: ICustomer;
  const AName, APhone, AEmail: string): ICustomerPatch;
/// No member to send.
function CustomerChangeIsEmpty(const AChange: ICustomerPatch): Boolean;

implementation

uses
  PascalCommon.Optionals;

type
  TCustomersTask = class(TAgendaTask)
  protected
    FModel: TCustomersModel;
    // Run's client, taken when the task is made: Run may still be going
    // on a pool thread after its dialog closed and freed the model.
    FClient: TAgendaClient;
    FSeq: Integer;
    FSearch: string;
    FPage: Integer;
    FInfo: TApiPageInfo;
    FCustomers: TCustomerArray;
    procedure Run; override;
    procedure Done; override;
  end;

  TSaveTask = class(TAgendaTask)
  protected
    FModel: TCustomerEditModel;
    // Run's client, taken when the task is made: Run may still be going
    // on a pool thread after its dialog closed and freed the model.
    FClient: TAgendaClient;
    FId: string;
    FInsert: ICustomerInsert;
    FChange: ICustomerPatch;
    FSaved: ICustomer;
    procedure Run; override;
    procedure Done; override;
  end;

function CustomerChangeOf(const ACustomer: ICustomer;
  const AName, APhone, AEmail: string): ICustomerPatch;
var
  LChange: TCustomerPatch;

  function Member(const AWas: INullString; const ATyped: string): IOptNullString;
  begin
    if ATyped = AWas.ValueOr('') then
      Result := nil
    else if ATyped = '' then
      Result := TOptNullString.Null
    else
      Result := TOptNullString.From(ATyped);
  end;

begin
  LChange := TCustomerPatch.Create;
  Result := LChange;
  if (Trim(AName) <> '') and (Trim(AName) <> ACustomer.Name) then
    LChange.Name := TOptNullString.From(Trim(AName));
  LChange.Phone := Member(ACustomer.Phone, Trim(APhone));
  LChange.Email := Member(ACustomer.Email, Trim(AEmail));
end;

function CustomerChangeIsEmpty(const AChange: ICustomerPatch): Boolean;
begin
  Result := not AChange.Name.HasValue and
    not (AChange.Phone.HasValue or AChange.Phone.IsNull) and
    not (AChange.Email.HasValue or AChange.Email.IsNull);
end;

{ TCustomersTask }

procedure TCustomersTask.Run;
begin
  FCustomers := FClient.FindCustomers(FSearch, FPage, CUSTOMERS_PAGE_SIZE, FInfo);
end;

procedure TCustomersTask.Done;
begin
  if FSeq <> FModel.FSeq then
  begin
    FModel.Finished(FModel.Error);
    Exit;
  end;
  if FModel.Finished(Error) then
  begin
    FModel.FCustomers := FCustomers;
    FModel.FInfo := FInfo;
    FModel.FPage := FPage;
    if FModel.SelectedIndex < 0 then
      FModel.FSelectedId := '';
  end;
  FModel.Changed;
end;

{ TCustomersModel }

constructor TCustomersModel.Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient);
begin
  inherited Create(ARunner);
  FClient := AClient;
  FPage := 1;
end;

procedure TCustomersModel.Load(APage: Integer);
var
  LTask: TCustomersTask;
begin
  Inc(FSeq);
  LTask := TCustomersTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  LTask.FSeq := FSeq;
  LTask.FSearch := FSearch;
  LTask.FPage := APage;
  StartTask(LTask);
end;

procedure TCustomersModel.Search(const AText, ASelectId: string);
begin
  FSearch := Trim(AText);
  FSelectedId := ASelectId;
  Load(1);
end;

procedure TCustomersModel.NextPage;
begin
  if CanNextPage then
    Load(FPage + 1);
end;

procedure TCustomersModel.PreviousPage;
begin
  if CanPreviousPage then
    Load(FPage - 1);
end;

procedure TCustomersModel.Reload(const ASelectId: string);
begin
  if ASelectId <> '' then
    FSelectedId := ASelectId;
  Load(FPage);
end;

function TCustomersModel.CanNextPage: Boolean;
begin
  Result := (not Busy) and FInfo.HasNext;
end;

function TCustomersModel.CanPreviousPage: Boolean;
begin
  Result := (not Busy) and FInfo.HasPrev;
end;

procedure TCustomersModel.Select(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex <= High(FCustomers)) then
    FSelectedId := FCustomers[AIndex].Id
  else
    FSelectedId := '';
  Changed;
end;

function TCustomersModel.SelectedIndex: Integer;
var
  I: Integer;
begin
  if FSelectedId <> '' then
    for I := 0 to High(FCustomers) do
      if FCustomers[I].Id = FSelectedId then
        Exit(I);
  Result := -1;
end;

function TCustomersModel.Selected: ICustomer;
var
  I: Integer;
begin
  I := SelectedIndex;
  if I >= 0 then
    Result := FCustomers[I]
  else
    Result := nil;
end;

{ TSaveTask }

procedure TSaveTask.Run;
begin
  if FInsert <> nil then
    FSaved := FClient.CreateCustomer(FInsert)
  else
    FSaved := FClient.UpdateCustomer(FId, FChange);
end;

procedure TSaveTask.Done;
begin
  FModel.FSaving := False;
  if not FModel.Finished(Error) then
  begin
    FModel.Changed;
    Exit;
  end;
  FModel.FSaved := FSaved;
  FModel.Changed;
  if Assigned(FModel.FOnSaved) then
    FModel.FOnSaved(FModel);
end;

{ TCustomerEditModel }

constructor TCustomerEditModel.CreateNew(const ARunner: IUiTaskRunner; AClient: TAgendaClient);
begin
  inherited Create(ARunner);
  FClient := AClient;
end;

constructor TCustomerEditModel.CreateEdit(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
  const ACustomer: ICustomer);
begin
  inherited Create(ARunner);
  FClient := AClient;
  FOriginal := ACustomer;
  FName := ACustomer.Name;
  FPhone := ACustomer.Phone.ValueOr('');
  FEmail := ACustomer.Email.ValueOr('');
end;

function TCustomerEditModel.IsNew: Boolean;
begin
  Result := FOriginal = nil;
end;

procedure TCustomerEditModel.SetName(const AValue: string);
begin
  FName := AValue;
  Changed;
end;

procedure TCustomerEditModel.SetPhone(const AValue: string);
begin
  FPhone := AValue;
  Changed;
end;

procedure TCustomerEditModel.SetEmail(const AValue: string);
begin
  FEmail := AValue;
  Changed;
end;

function TCustomerEditModel.HasChanges: Boolean;
begin
  Result := IsNew or not CustomerChangeIsEmpty(CustomerChangeOf(FOriginal, FName, FPhone, FEmail));
end;

function TCustomerEditModel.CanSave: Boolean;
begin
  Result := (not FSaving) and (FSaved = nil) and (Trim(FName) <> '') and HasChanges;
end;

procedure TCustomerEditModel.Save;
var
  LTask: TSaveTask;
  LInsert: TCustomerInsert;
begin
  if not CanSave then
    Exit;
  FSaving := True;
  SetError(TUiError.None);
  LTask := TSaveTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  if IsNew then
  begin
    LInsert := TCustomerInsert.Create;
    LTask.FInsert := LInsert;
    LInsert.Name := Trim(FName);
    if Trim(FPhone) <> '' then
      LInsert.Phone := TOptNullString.From(Trim(FPhone));
    if Trim(FEmail) <> '' then
      LInsert.Email := TOptNullString.From(Trim(FEmail));
  end
  else
  begin
    LTask.FId := FOriginal.Id;
    LTask.FChange := CustomerChangeOf(FOriginal, FName, FPhone, FEmail);
  end;
  StartTask(LTask);
end;

end.
