unit Agenda.Desktop.Booking;

{$I agenda.inc}

{ The booking screen's view model: a service, a professional, a day, a free
  slot and a customer (found by a search), then Book.

  - Open reads the active services and professionals. Choosing a service,
    a professional or a day reads the free slots again (when the three are
    there); an older read's answer that comes back late is dropped, as is a
    search's.
  - The Idempotency-Key belongs to one choice: it is made again whenever
    the service, the professional, the slot or the customer changes, and
    kept otherwise. So a Book pressed again after "the server didn't
    answer" replays the first try (one appointment), and a new choice books
    anew.
  - A 409 slot_unavailable (someone took the slot): a Notice, the slots
    read again, the slot cleared. The server's 400s show as Error, with the
    fields.
  - UseCustomer: a customer created from the dialog, chosen at once.
  - After a booking, Booked holds it and OnBooked is raised (the day reads
    itself again). }

interface

uses
  SysUtils,
  Classes,
  PascalJsonMapper.Json,
  Agenda.HttpClient,
  Agenda.Client,
  Agenda.Appointments.Dtos,
  Agenda.Availability.Dtos,
  Agenda.Customers.Dtos,
  Agenda.Professionals.Dtos,
  Agenda.Services.Dtos,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Models;

const
  TEXT_SLOT_TAKEN = 'That time was just taken. The free times were read again.';
  /// Customers a search shows.
  BOOKING_SEARCH_LIMIT = 20;

type
  TBookingModel = class(TDesktopModel)
  private
    FClient: TAgendaClient;
    FServices: TServiceArray;
    FProfessionals: TProfessionalArray;
    FServiceId: string;
    FProfessionalId: string;
    FDate: TDateTime;
    FSlots: TAvailableSlotArray;
    FSlotIndex: Integer;
    FSearch: string;
    FCustomers: TCustomerArray;
    FCustomerId: string;
    FKey: string;
    FSlotsSeq: Integer;
    FSearchSeq: Integer;
    FBooking: Boolean;
    FBooked: IAppointment;
    FOnBooked: TNotifyEvent;
    procedure NewKey;
    procedure LoadSlots;
  public
    constructor Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient; ADate: TDateTime);
    procedure Open;
    procedure SetService(const AServiceId: string);
    procedure SetProfessional(const AProfessionalId: string);
    procedure SetDate(ADate: TDateTime);
    procedure SelectSlot(AIndex: Integer);
    /// Searches the customers (name, email or phone; '' lists the first).
    procedure Search(const AText: string);
    procedure SelectCustomer(const ACustomerId: string);
    /// A customer just created (the customer dialog): listed alone and
    /// selected.
    procedure UseCustomer(const ACustomer: ICustomer);
    function CanBook: Boolean;
    procedure Book;
    function DateText: string;
    property Services: TServiceArray read FServices;
    property Professionals: TProfessionalArray read FProfessionals;
    property ServiceId: string read FServiceId;
    property ProfessionalId: string read FProfessionalId;
    property Date: TDateTime read FDate;
    property Slots: TAvailableSlotArray read FSlots;
    /// -1 when none.
    property SlotIndex: Integer read FSlotIndex;
    property Customers: TCustomerArray read FCustomers;
    property CustomerId: string read FCustomerId;
    /// The Idempotency-Key the next Book sends.
    property Key: string read FKey;
    property Booked: IAppointment read FBooked;
    property OnBooked: TNotifyEvent read FOnBooked write FOnBooked;
  end;

implementation

type
  TBookingTask = class(TAgendaTask)
  protected
    FModel: TBookingModel;
    // Run's client, taken when the task is made: Run may still be going
    // on a pool thread after its dialog closed and freed the model.
    FClient: TAgendaClient;
  end;

  TOpenTask = class(TBookingTask)
  private
    FServices: TServiceArray;
    FProfessionals: TProfessionalArray;
  protected
    function SpanName: string; override;
    procedure Run; override;
    procedure Done; override;
  end;

  TSlotsTask = class(TBookingTask)
  private
    FSeq: Integer;
    FProfessionalId, FServiceId, FDate: string;
    FSlots: TAvailableSlotArray;
  protected
    function SpanName: string; override;
    procedure Run; override;
    procedure Done; override;
  end;

  TSearchTask = class(TBookingTask)
  private
    FSeq: Integer;
    FText: string;
    FCustomers: TCustomerArray;
  protected
    function SpanName: string; override;
    procedure Run; override;
    procedure Done; override;
  end;

  TBookTask = class(TBookingTask)
  private
    FBooking: IAppointmentInsert;
    FKey: string;
    FBooked: IAppointment;
  protected
    function SpanName: string; override;
    procedure Run; override;
    procedure Done; override;
  end;

{ TOpenTask }

procedure TOpenTask.Run;
begin
  FServices := FClient.ActiveServices;
  FProfessionals := FClient.ActiveProfessionals;
end;

procedure TOpenTask.Done;
begin
  if FModel.Finished(Error) then
  begin
    FModel.FServices := FServices;
    FModel.FProfessionals := FProfessionals;
  end;
  FModel.Changed;
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

{ TSearchTask }

procedure TSearchTask.Run;
var
  LInfo: TApiPageInfo;
begin
  FCustomers := FClient.FindCustomers(FText, 1, BOOKING_SEARCH_LIMIT, LInfo);
end;

procedure TSearchTask.Done;
begin
  if FSeq <> FModel.FSearchSeq then
  begin
    FModel.Finished(FModel.Error);
    Exit;
  end;
  if FModel.Finished(Error) then
    FModel.FCustomers := FCustomers;
  FModel.Changed;
end;

{ TBookTask }

procedure TBookTask.Run;
begin
  FBooked := FClient.Book(FBooking, FKey);
end;

procedure TBookTask.Done;
var
  LError: TUiError;
begin
  FModel.FBooking := False;
  LError := Error;
  if (LError.Kind = ekConflict) and (LError.Code = CODE_SLOT_UNAVAILABLE) then
  begin
    FModel.Finished(TUiError.None);
    FModel.SetNotice(TEXT_SLOT_TAKEN);
    FModel.LoadSlots;
    Exit;
  end;
  if not FModel.Finished(LError) then
  begin
    FModel.Changed;
    Exit;
  end;
  FModel.FBooked := FBooked;
  FModel.Changed;
  if Assigned(FModel.FOnBooked) then
    FModel.FOnBooked(FModel);
end;

{ TBookingModel }

constructor TBookingModel.Create(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
  ADate: TDateTime);
begin
  inherited Create(ARunner);
  FClient := AClient;
  FDate := Trunc(ADate);
  FSlotIndex := -1;
  NewKey;
end;

procedure TBookingModel.NewKey;
begin
  FKey := NewIdempotencyKey;
end;

function TBookingModel.DateText: string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd', FDate);
end;

procedure TBookingModel.Open;
var
  LTask: TOpenTask;
begin
  LTask := TOpenTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  StartTask(LTask);
end;

procedure TBookingModel.LoadSlots;
var
  LTask: TSlotsTask;
begin
  Inc(FSlotsSeq);
  FSlots := nil;
  FSlotIndex := -1;
  NewKey;
  if (FServiceId = '') or (FProfessionalId = '') then
  begin
    Changed;
    Exit;
  end;
  LTask := TSlotsTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  LTask.FSeq := FSlotsSeq;
  LTask.FProfessionalId := FProfessionalId;
  LTask.FServiceId := FServiceId;
  LTask.FDate := DateText;
  StartTask(LTask);
end;

procedure TBookingModel.SetService(const AServiceId: string);
begin
  FServiceId := AServiceId;
  SetNotice('');
  LoadSlots;
end;

procedure TBookingModel.SetProfessional(const AProfessionalId: string);
begin
  FProfessionalId := AProfessionalId;
  SetNotice('');
  LoadSlots;
end;

procedure TBookingModel.SetDate(ADate: TDateTime);
begin
  FDate := Trunc(ADate);
  SetNotice('');
  LoadSlots;
end;

procedure TBookingModel.SelectSlot(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FSlots)) then
    AIndex := -1;
  if AIndex <> FSlotIndex then
  begin
    FSlotIndex := AIndex;
    NewKey;
  end;
  Changed;
end;

procedure TBookingModel.Search(const AText: string);
var
  LTask: TSearchTask;
begin
  Inc(FSearchSeq);
  FSearch := AText;
  LTask := TSearchTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  LTask.FSeq := FSearchSeq;
  LTask.FText := Trim(AText);
  StartTask(LTask);
end;

procedure TBookingModel.SelectCustomer(const ACustomerId: string);
begin
  if ACustomerId <> FCustomerId then
  begin
    FCustomerId := ACustomerId;
    NewKey;
  end;
  Changed;
end;

procedure TBookingModel.UseCustomer(const ACustomer: ICustomer);
begin
  // A search still running would replace the list: its answer is old now.
  Inc(FSearchSeq);
  SetLength(FCustomers, 1);
  FCustomers[0] := ACustomer;
  SelectCustomer(ACustomer.Id);
end;

function TBookingModel.CanBook: Boolean;
begin
  Result := (not FBooking) and (FServiceId <> '') and (FProfessionalId <> '') and
    (FSlotIndex >= 0) and (FCustomerId <> '') and (FBooked = nil);
end;

procedure TBookingModel.Book;
var
  LTask: TBookTask;
  LBooking: TAppointmentInsert;
begin
  if not CanBook then
    Exit;
  FBooking := True;
  SetNotice('');
  SetError(TUiError.None);
  LTask := TBookTask.Create(Self);
  LTask.FModel := Self;
  LTask.FClient := FClient;
  LBooking := TAppointmentInsert.Create;
  LTask.FBooking := LBooking;
  LBooking.ProfessionalId := FProfessionalId;
  LBooking.ServiceId := FServiceId;
  LBooking.CustomerId := FCustomerId;
  LBooking.StartsAt := FSlots[FSlotIndex].StartsAt;
  LTask.FKey := FKey;
  StartTask(LTask);
end;

function TOpenTask.SpanName: string;
begin
  Result := 'booking.open';
end;

function TSlotsTask.SpanName: string;
begin
  Result := 'booking.slots';
end;

function TSearchTask.SpanName: string;
begin
  Result := 'booking.customers';
end;

function TBookTask.SpanName: string;
begin
  Result := 'booking.book';
end;

end.
