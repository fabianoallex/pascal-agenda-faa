program AgendaClientCheck;

{ The desktop client's calls against the real api (decision "Tests" of
  "M6: design"): what the unit tests check on the fake transport, through
  the network, the server's rules and its database. Run by
  tools/test_http.sh on an api started with a short ACCESS_TOKEN_SECONDS
  (CHECK_TOKEN_SECONDS tells this program the same number).

    AgendaClientCheck <base url>

  - The owner (Http.Execute, the owner's routes aren't the client's)
    creates a service and a professional working every day.
  - The staff, through TAgendaClient: who they are; a customer with an
    accented name, found by a search without accents, its email set and
    cleared; a body refused before any request; the free slots; a booking
    sent twice with one key (one appointment), another key on the same slot
    (409 slot_unavailable); the day; a move with If-Match, a 412 from the
    old version, the status, the cancel, a second cancel (409).
  - The tokens: renewed before they run out with no 401; two calls at once
    on a spent token (one refresh, the family still alive); after the
    logout the refresh token refused.

  One "ok <name>" or "FAIL <name>: <detail>" line per check, then a
  summary line; exit code 1 on any failure. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  {$IFNDEF FPC}
  Winapi.Windows,
  {$ENDIF}
  SysUtils,
  Classes,
  SyncObjs,
  PascalCommon.Optionals,
  PascalCommon.Validators,
  PascalJsonMapper.Json,
  PascalJsonMapper.Mapper,
  Agenda.HttpTransport in '..\..\src\Agenda.HttpTransport.pas',
  Agenda.HttpClient in '..\..\src\Agenda.HttpClient.pas',
  Agenda.HttpSession in '..\..\src\Agenda.HttpSession.pas',
  Agenda.AuthDtos in '..\..\src\Agenda.AuthDtos.pas',
  Agenda.Appointments.Dtos in '..\..\src\Agenda.Appointments.Dtos.pas',
  Agenda.Availability.Dtos in '..\..\src\Agenda.Availability.Dtos.pas',
  Agenda.Customers.Dtos in '..\..\src\Agenda.Customers.Dtos.pas',
  Agenda.Day.Dtos in '..\..\src\Agenda.Day.Dtos.pas',
  Agenda.Professionals.Dtos in '..\..\src\Agenda.Professionals.Dtos.pas',
  Agenda.Services.Dtos in '..\..\src\Agenda.Services.Dtos.pas',
  Agenda.Client in '..\..\src\Agenda.Client.pas';

type
  // The real transport, counting the 401s and the refreshes it carried.
  TWatchedTransport = class(TInterfacedObject, IHttpTransport)
  private
    FInner: IHttpTransport;
    FLock: TCriticalSection;
    FRequests: Integer;
    FRefused: Integer;
    FRefreshes: Integer;
  public
    constructor Create(const AInner: IHttpTransport);
    destructor Destroy; override;
    function Send(const ARequest: TTransportRequest): TTransportResponse;
    procedure Counts(out ARequests, ARefused, ARefreshes: Integer);
  end;

  // One GetDay on a thread of its own.
  TDayThread = class(TThread)
  private
    FClient: TAgendaClient;
    FDate: string;
    FProfessionalId: string;
    FError: string;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TAgendaClient; const ADate, AProfessionalId: string);
    property Error: string read FError;
  end;

  TCheck = class
  private
    FBase: string;
    FPassword: string;
    FTokenSeconds: Integer;
    FChecks: Integer;
    FFailures: Integer;
    FSuffix: string;
    procedure Check(ACondition: Boolean; const AName: string; const ADetail: string = '');
    procedure Fail(const AName: string; E: Exception);
    function FrozenClock: Int64;
    function RealClock: Int64;
    function Post(AClient: TAgendaClient; const APath, ABody: string): string;
    procedure Put(AClient: TAgendaClient; const APath, ABody: string);
    procedure Staff(const AServiceId, AProfessionalId: string);
    procedure Tokens(const AProfessionalId: string);
  public
    constructor Create(const ABase: string);
    function Run: Boolean;
  end;

function JsonText(const ABody, AName: string): string;
var
  LRoot, LValue: TJsonValue;
begin
  Result := '';
  LRoot := ParseJson(ABody);
  try
    LValue := LRoot.Find(AName);
    if (LValue <> nil) and (LValue.Kind = jkString) then
      Result := LValue.AsString;
  finally
    LRoot.Free;
  end;
end;

{ TWatchedTransport }

constructor TWatchedTransport.Create(const AInner: IHttpTransport);
begin
  inherited Create;
  FInner := AInner;
  FLock := TCriticalSection.Create;
end;

destructor TWatchedTransport.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TWatchedTransport.Send(const ARequest: TTransportRequest): TTransportResponse;
begin
  Result := FInner.Send(ARequest);
  FLock.Acquire;
  try
    Inc(FRequests);
    if Result.Status = 401 then
      Inc(FRefused);
    if Pos('/auth/refresh', ARequest.Url) > 0 then
      Inc(FRefreshes);
  finally
    FLock.Release;
  end;
end;

procedure TWatchedTransport.Counts(out ARequests, ARefused, ARefreshes: Integer);
begin
  FLock.Acquire;
  try
    ARequests := FRequests;
    ARefused := FRefused;
    ARefreshes := FRefreshes;
  finally
    FLock.Release;
  end;
end;

{ TDayThread }

constructor TDayThread.Create(AClient: TAgendaClient; const ADate, AProfessionalId: string);
begin
  FClient := AClient;
  FDate := ADate;
  FProfessionalId := AProfessionalId;
  inherited Create(False);
end;

procedure TDayThread.Execute;
begin
  try
    FClient.GetDay(FDate, FProfessionalId);
  except
    on E: Exception do
      FError := E.ClassName + ': ' + E.Message;
  end;
end;

{ TCheck }

constructor TCheck.Create(const ABase: string);
begin
  inherited Create;
  FBase := ABase;
  FPassword := GetEnvironmentVariable('SCENARIO_PASSWORD');
  if FPassword = '' then
    FPassword := 'correct horse battery staple';
  FTokenSeconds := StrToIntDef(GetEnvironmentVariable('CHECK_TOKEN_SECONDS'), 0);
  // Names of their own: the scenarios ran on this database before.
  FSuffix := Copy(NewTraceId, 1, 8);
end;

procedure TCheck.Check(ACondition: Boolean; const AName, ADetail: string);
begin
  Inc(FChecks);
  if ACondition then
    Writeln('ok ', AName)
  else
  begin
    Inc(FFailures);
    Writeln('FAIL ', AName, ': ', ADetail);
  end;
end;

procedure TCheck.Fail(const AName: string; E: Exception);
begin
  Check(False, AName, E.ClassName + ': ' + E.Message);
end;

function TCheck.FrozenClock: Int64;
begin
  Result := 0;
end;

function TCheck.RealClock: Int64;
begin
  Result := Int64(GetTickCount64);
end;

function TCheck.Post(AClient: TAgendaClient; const APath, ABody: string): string;
var
  LCall: TApiCall;
begin
  LCall := TApiCall.Create('POST', APath);
  LCall.Body := ABody;
  Result := JsonText(AClient.Http.Execute(LCall).Body, 'id');
end;

procedure TCheck.Put(AClient: TAgendaClient; const APath, ABody: string);
var
  LCall: TApiCall;
begin
  LCall := TApiCall.Create('PUT', APath);
  LCall.Body := ABody;
  AClient.Http.Execute(LCall);
end;

procedure TCheck.Staff(const AServiceId, AProfessionalId: string);
var
  LClient: TAgendaClient;
  LName, LDate, LKey: string;
  LCustomer: TCustomerInsert;
  LCustomerRef: ICustomerInsert;
  LChange: TCustomerPatch;
  LChangeRef: ICustomerPatch;
  LCreated, LRead: ICustomer;
  LFound: TCustomerArray;
  LInfo: TApiPageInfo;
  LSlots: TAvailableSlotArray;
  LBooking: TAppointmentInsert;
  LBookingRef: IAppointmentInsert;
  LFirst, LAgain, LChanged: IAppointment;
  LDay: IDay;
  I: Integer;
  LInDay: Boolean;
begin
  LClient := TAgendaClient.Create(FBase, NewHttpTransport);
  try
    LClient.Login('demo', 'staff@demo.test', FPassword);
    Check(LClient.Me.Role = 'staff', 'me: the staff');

    // A customer, its name with accents, found without them.
    LName := 'João Cliente ' + FSuffix;
    LCustomer := TCustomerInsert.Create;
    LCustomerRef := LCustomer;
    LCustomer.Name := LName;
    LCustomer.Phone := TOptNullString.From('+55 11 99999-' + Copy(IntToStr(1000 + Random(9000)), 1, 4));
    LCreated := LClient.CreateCustomer(LCustomerRef);
    Check(LCreated.Name = LName, 'customer: created, the name as sent', LCreated.Name);
    LFound := LClient.FindCustomers('joao cliente ' + FSuffix, 1, 20, LInfo);
    Check((Length(LFound) = 1) and (LFound[0].Id = LCreated.Id) and (LFound[0].Name = LName),
      'customer: found without the accent', IntToStr(Length(LFound)));
    Check(LInfo.Total = 1, 'customer: the page''s total', IntToStr(LInfo.Total));

    LChange := TCustomerPatch.Create;
    LChangeRef := LChange;
    LChange.Email := TOptNullString.From('joao.' + FSuffix + '@demo.test');
    LRead := LClient.UpdateCustomer(LCreated.Id, LChangeRef);
    Check((not LRead.Email.IsNull) and (LRead.Email.Value = 'joao.' + FSuffix + '@demo.test') and
      (LRead.Phone.Value = LCreated.Phone.Value),
      'customer: the email set, the phone kept');
    LChange := TCustomerPatch.Create;
    LChangeRef := LChange;
    LChange.Email := TOptNullString.Null;
    LRead := LClient.UpdateCustomer(LCreated.Id, LChangeRef);
    Check(LRead.Email.IsNull and (LRead.Name = LName), 'customer: the email cleared');
    Check(LClient.GetCustomer(LCreated.Id).Email.IsNull, 'customer: read again');

    // Refused before any request: the server's limit, checked here.
    LCustomer := TCustomerInsert.Create;
    LCustomerRef := LCustomer;
    LCustomer.Name := StringOfChar('x', 101);
    try
      LClient.CreateCustomer(LCustomerRef);
      Check(False, 'customer: a 101-character name refused here', 'sent');
    except
      on E: EPcValidationError do
        Check((Length(E.Errors) = 1) and (E.Errors[0].Field = 'name'),
          'customer: a 101-character name refused here');
    end;

    // The free slots, three days on (the cancel's notice is 24 hours).
    LDate := FormatDateTime('yyyy"-"mm"-"dd', Date + 3);
    LSlots := LClient.GetAvailability(AProfessionalId, AServiceId, LDate, 7).Slots;
    Check(Length(LSlots) >= 2, 'availability: free slots', IntToStr(Length(LSlots)));
    if Length(LSlots) < 2 then
      Exit;

    // One key, sent twice: one appointment.
    LBooking := TAppointmentInsert.Create;
    LBookingRef := LBooking;
    LBooking.ProfessionalId := AProfessionalId;
    LBooking.ServiceId := AServiceId;
    LBooking.CustomerId := LCreated.Id;
    LBooking.StartsAt := LSlots[0].StartsAt;
    LKey := NewIdempotencyKey;
    LFirst := LClient.Book(LBookingRef, LKey);
    Check((LFirst.Status = STATUS_BOOKED) and (LFirst.Version = 1), 'book: booked, version 1');
    LAgain := LClient.Book(LBookingRef, LKey);
    Check(LAgain.Id = LFirst.Id, 'book: the same key again, the same appointment', LAgain.Id);
    try
      LClient.Book(LBookingRef, NewIdempotencyKey);
      Check(False, 'book: another key, the slot taken', 'booked twice');
    except
      on E: EApiError do
        Check((E.Status = 409) and (E.Code = CODE_SLOT_UNAVAILABLE),
          'book: another key, the slot taken', E.Code);
    end;

    LDay := LClient.GetDay(Copy(LSlots[0].Local, 1, 10), AProfessionalId);
    LInDay := False;
    for I := 0 to High(LDay.Appointments) do
      if LDay.Appointments[I].Id = LFirst.Id then
        LInDay := (LDay.Appointments[I].Version = 1) and
          (LDay.Appointments[I].CustomerName = LName);
    Check(LInDay, 'day: the appointment, its version and the customer''s name');

    // Changes with the version read.
    LChanged := LClient.Move(LFirst.Id, 1, LSlots[1].StartsAt);
    Check((LChanged.Version = 2) and (LChanged.StartsAt = LSlots[1].StartsAt), 'move: version 2');
    try
      LClient.Move(LFirst.Id, 1, LSlots[0].StartsAt);
      Check(False, 'move: the old version refused', 'moved');
    except
      on E: EApiError do
        Check(E.Status = 412, 'move: the old version refused', IntToStr(E.Status));
    end;
    LChanged := LClient.SetStatus(LFirst.Id, 2, STATUS_CONFIRMED);
    Check((LChanged.Status = STATUS_CONFIRMED) and (LChanged.Version = 3), 'status: confirmed');
    LChanged := LClient.Cancel(LFirst.Id, 3);
    Check((LChanged.Status = STATUS_CANCELLED) and (LChanged.Version = 4), 'cancel: cancelled');
    try
      LClient.Cancel(LFirst.Id, 4);
      Check(False, 'cancel: again refused', 'cancelled twice');
    except
      on E: EApiError do
        Check((E.Status = 409) and (E.Code = CODE_APPOINTMENT_CLOSED), 'cancel: again refused', E.Code);
    end;
    Check(LClient.Logout, 'logout: 204');
  finally
    LClient.Free;
  end;
end;

procedure TCheck.Tokens(const AProfessionalId: string);
var
  LWatch: TWatchedTransport;
  LWatchRef: IHttpTransport;
  LClient: TAgendaClient;
  LThreads: array[0..1] of TDayThread;
  LRequests, LRefused, LRefreshes, LRefreshesBefore, I: Integer;
  LDate, LSpent: string;
  LCall: TApiCall;
begin
  LWatch := TWatchedTransport.Create(NewHttpTransport);
  LWatchRef := LWatch;
  LClient := TAgendaClient.Create(FBase, LWatchRef);
  try
    LClient.Login('demo', 'staff@demo.test', FPassword);
    LDate := FormatDateTime('yyyy"-"mm"-"dd', Date + 3);

    // Renewed early: a quarter of the life before the end, no 401.
    Sleep(FTokenSeconds * 750 + 300);
    LClient.Me;
    LWatch.Counts(LRequests, LRefused, LRefreshes);
    Check((LRefused = 0) and (LRefreshes = 1), 'tokens: renewed before the end, no 401',
      Format('%d refused, %d refreshes', [LRefused, LRefreshes]));

    // Two calls at once on a spent token: never renewed early now.
    LClient.Session.Clock := FrozenClock;
    Sleep(FTokenSeconds * 1000 + 1000);
    LWatch.Counts(LRequests, LRefused, LRefreshesBefore);
    for I := 0 to High(LThreads) do
      LThreads[I] := TDayThread.Create(LClient, LDate, AProfessionalId);
    for I := 0 to High(LThreads) do
    begin
      LThreads[I].WaitFor;
      Check(LThreads[I].Error = '', Format('tokens: call %d at once on a spent token', [I + 1]),
        LThreads[I].Error);
      LThreads[I].Free;
    end;
    LWatch.Counts(LRequests, LRefused, LRefreshes);
    Check(LRefreshes - LRefreshesBefore = 1, 'tokens: one refresh for both',
      IntToStr(LRefreshes - LRefreshesBefore));
    Check(LRefused >= 1, 'tokens: the spent token refused', IntToStr(LRefused));
    // The family alive: another refresh is accepted.
    LClient.Session.Clock := RealClock;
    Check(LClient.Session.Renew(LClient.Session.AccessToken) and not LClient.SessionLost,
      'tokens: the family still alive');
    Check(LClient.Me.Role = 'staff', 'tokens: a call after them');

    // After the logout the refresh token is refused.
    LSpent := LClient.Session.RefreshToken;
    Check(LClient.Logout, 'tokens: logout');
    LCall := TApiCall.Create('POST', '/auth/refresh');
    LCall.Body := '{"refreshToken":"' + LSpent + '"}';
    LCall.Anonymous := True;
    try
      LClient.Http.Execute(LCall);
      Check(False, 'tokens: refused after the logout', 'refreshed');
    except
      on E: EApiError do
        Check(E.Status = 401, 'tokens: refused after the logout', IntToStr(E.Status));
    end;
  finally
    LClient.Free;
  end;
end;

function TCheck.Run: Boolean;
var
  LOwner: TAgendaClient;
  LServiceId, LProfessionalId, LWeek: string;
  I: Integer;
begin
  LOwner := TAgendaClient.Create(FBase, NewHttpTransport);
  try
    try
      LOwner.Login('demo', 'owner@demo.test', FPassword);
      LServiceId := Post(LOwner, '/services', '{"name":"Client check ' + FSuffix +
        '","durationMinutes":30,"price":50}');
      LProfessionalId := Post(LOwner, '/professionals', '{"name":"Client check ' + FSuffix + '"}');
      LWeek := '';
      for I := 1 to 7 do
      begin
        if LWeek <> '' then
          LWeek := LWeek + ',';
        LWeek := LWeek + Format('{"weekday":%d,"from":"08:00","to":"18:00"}', [I]);
      end;
      Put(LOwner, '/professionals/' + LProfessionalId + '/working-hours',
        '{"intervals":[' + LWeek + ']}');
      Check((LServiceId <> '') and (LProfessionalId <> ''), 'owner: a service and a professional');
      LOwner.Logout;
    except
      on E: Exception do
      begin
        Fail('owner: a service and a professional', E);
        Exit(False);
      end;
    end;
  finally
    LOwner.Free;
  end;
  try
    Staff(LServiceId, LProfessionalId);
  except
    on E: Exception do
      Fail('staff: unexpected', E);
  end;
  if FTokenSeconds > 0 then
    try
      Tokens(LProfessionalId);
    except
      on E: Exception do
        Fail('tokens: unexpected', E);
    end
  else
    Writeln('skipped: the tokens (CHECK_TOKEN_SECONDS unset)');
  Writeln(Format('client check: %d checks, %d failures', [FChecks, FFailures]));
  Result := FFailures = 0;
end;

var
  GCheck: TCheck;
begin
  {$IFDEF FPC}
  SetMultiByteConversionCodePage(CP_UTF8);
  {$ELSE}
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  {$ENDIF}
  Randomize;
  if ParamCount < 1 then
  begin
    Writeln('usage: AgendaClientCheck <base url>');
    ExitCode := 2;
    Exit;
  end;
  GCheck := TCheck.Create(ParamStr(1));
  try
    if not GCheck.Run then
      ExitCode := 1;
  finally
    GCheck.Free;
  end;
end.
