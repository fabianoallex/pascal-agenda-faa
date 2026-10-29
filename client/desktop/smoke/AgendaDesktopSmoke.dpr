program AgendaDesktopSmoke;

{ The desktop client's screens, driven by a program against the real api:
  the forms built (OPCB, VCL or LCL), the fields filled, the buttons
  clicked, the answers waited for (the pool's tasks come back through
  TThread.Queue, pumped here), and what the screens show checked. Also
  their layout: every control inside its parent's client area, no two
  siblings overlapping.

    AgendaDesktopSmoke <base url>

  The owner first creates (through Http.Execute) a service, a professional
  working every day and a customer; then, as the staff: the login dialog,
  the booking dialog (service, professional, the day three days on, the
  first free time, the customer, Book), the day window on that day (the
  appointment listed), Confirm, then Cancel it; closing logs out.

  One "OK"/"FAIL" line per check and a summary; exit code 1 on a failure.
  SMOKE_SHOTS=<folder> saves each form as a PNG there (login.png,
  booking.png, day.png) for a look. Windows only (it shows the forms). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}
  Interfaces, Forms, Controls, StdCtrls, ComCtrls, ExtCtrls, Graphics,
  {$ELSE}
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Graphics,
  Vcl.Imaging.pngimage,
  {$ENDIF}
  SysUtils,
  Classes,
  PascalJsonMapper.Json,
  Agenda.HttpTransport in '..\..\..\src\Agenda.HttpTransport.pas',
  Agenda.HttpClient in '..\..\..\src\Agenda.HttpClient.pas',
  Agenda.HttpSession in '..\..\..\src\Agenda.HttpSession.pas',
  Agenda.AuthDtos in '..\..\..\src\Agenda.AuthDtos.pas',
  Agenda.Appointments.Dtos in '..\..\..\src\Agenda.Appointments.Dtos.pas',
  Agenda.Availability.Dtos in '..\..\..\src\Agenda.Availability.Dtos.pas',
  Agenda.Customers.Dtos in '..\..\..\src\Agenda.Customers.Dtos.pas',
  Agenda.Day.Dtos in '..\..\..\src\Agenda.Day.Dtos.pas',
  Agenda.Professionals.Dtos in '..\..\..\src\Agenda.Professionals.Dtos.pas',
  Agenda.Services.Dtos in '..\..\..\src\Agenda.Services.Dtos.pas',
  Agenda.Client in '..\..\..\src\Agenda.Client.pas',
  Agenda.Desktop.Tasks in '..\..\..\src\Agenda.Desktop.Tasks.pas',
  Agenda.Desktop.Errors in '..\..\..\src\Agenda.Desktop.Errors.pas',
  Agenda.Desktop.Models in '..\..\..\src\Agenda.Desktop.Models.pas',
  Agenda.Desktop.Login in '..\..\..\src\Agenda.Desktop.Login.pas',
  Agenda.Desktop.Day in '..\..\..\src\Agenda.Desktop.Day.pas',
  Agenda.Desktop.Booking in '..\..\..\src\Agenda.Desktop.Booking.pas',
  Agenda.Desktop.Ui in '..\Agenda.Desktop.Ui.pas',
  Agenda.Desktop.LoginForm in '..\Agenda.Desktop.LoginForm.pas',
  Agenda.Desktop.DayForm in '..\Agenda.Desktop.DayForm.pas',
  Agenda.Desktop.BookingForm in '..\Agenda.Desktop.BookingForm.pas',
  Agenda.Desktop.App in '..\Agenda.Desktop.App.pas';

type
  TSmoke = class
  private
    FBase: string;
    FPassword: string;
    FSuffix: string;
    FFails: Integer;
    FChecks: Integer;
    FServiceId, FProfessionalId, FCustomerName: string;
    procedure Check(ACondition: Boolean; const AWhat: string; const ADetail: string = '');
    function Pump(ATimeoutMs: Integer): Boolean;
    function WaitFor(AForm: TForm; const AControl, AText: string; ATimeoutMs: Integer = 10000): Boolean;
    function Text(AForm: TForm; const AControl: string): string;
    procedure SetEdit(AForm: TForm; const AName, AText: string);
    procedure Click(AForm: TForm; const AName: string);
    function Button(AForm: TForm; const AName: string): TButton;
    procedure CheckLayout(AForm: TForm; const AWhat: string);
    procedure Shot(AForm: TForm; const AName: string);
    procedure CheckChildren(AParent: TWinControl; const AWhat: string);
    function ListHas(AList: TListView; const AText: string; ACol: Integer): Integer;
    function WaitList(AList: TListView; const AText: string; ACol, ATimeoutMs: Integer): Integer;
    function WaitListBox(ABox: TListBox; ATimeoutMs: Integer): Boolean;
    /// The row whose customer is ACustomer once its status is AStatus (the
    /// day lists everyone's: another customer's row may have it already).
    function WaitRow(AForm: TForm; AList: TListView; const ACustomer, AStatus: string;
      ATimeoutMs: Integer): Integer;
    procedure Setup;
    procedure Run;
  public
    constructor Create(const ABase: string);
    function Execute: Boolean;
  end;

function JsonId(const ABody: string): string;
var
  LRoot, LValue: TJsonValue;
begin
  Result := '';
  LRoot := ParseJson(ABody);
  try
    LValue := LRoot.Find('id');
    if LValue <> nil then
      Result := LValue.AsString;
  finally
    LRoot.Free;
  end;
end;

constructor TSmoke.Create(const ABase: string);
begin
  inherited Create;
  FBase := ABase;
  FPassword := GetEnvironmentVariable('SCENARIO_PASSWORD');
  if FPassword = '' then
    FPassword := 'correct horse battery staple';
  FSuffix := Copy(NewTraceId, 1, 6);
end;

procedure TSmoke.Check(ACondition: Boolean; const AWhat, ADetail: string);
begin
  Inc(FChecks);
  if ACondition then
    Writeln('OK   ', AWhat)
  else
  begin
    Inc(FFails);
    Writeln('FAIL ', AWhat, ': ', ADetail);
  end;
end;

// Runs the message loop and the queued Done calls for a while.
function TSmoke.Pump(ATimeoutMs: Integer): Boolean;
var
  LUntil: TDateTime;
begin
  LUntil := Now + ATimeoutMs / MSecsPerDay;
  repeat
    Application.ProcessMessages;
    CheckSynchronize(5);
  until Now >= LUntil;
  Result := True;
end;

function TSmoke.Text(AForm: TForm; const AControl: string): string;
var
  LComponent: TComponent;
begin
  LComponent := AForm.FindComponent(AControl);
  if LComponent is TLabel then
    Result := TLabel(LComponent).Caption
  else if LComponent is TEdit then
    Result := TEdit(LComponent).Text
  else
    Result := '';
end;

function TSmoke.WaitFor(AForm: TForm; const AControl, AText: string; ATimeoutMs: Integer): Boolean;
var
  LUntil: TDateTime;
begin
  LUntil := Now + ATimeoutMs / MSecsPerDay;
  repeat
    Application.ProcessMessages;
    CheckSynchronize(5);
    if Pos(AText, Text(AForm, AControl)) > 0 then
      Exit(True);
  until Now >= LUntil;
  Result := False;
end;

procedure TSmoke.SetEdit(AForm: TForm; const AName, AText: string);
begin
  (AForm.FindComponent(AName) as TEdit).Text := AText;
end;

function TSmoke.Button(AForm: TForm; const AName: string): TButton;
begin
  Result := AForm.FindComponent(AName) as TButton;
end;

procedure TSmoke.Click(AForm: TForm; const AName: string);
begin
  Button(AForm, AName).Click;
end;

procedure TSmoke.CheckChildren(AParent: TWinControl; const AWhat: string);
var
  I, J: Integer;
  A, B: TControl;
  LInside, LApart: Boolean;
  LDetail: string;
begin
  LInside := True;
  LApart := True;
  LDetail := '';
  for I := 0 to AParent.ControlCount - 1 do
  begin
    A := AParent.Controls[I];
    if not A.Visible then
      Continue;
    if (A.Left < 0) or (A.Top < 0) or (A.Left + A.Width > AParent.ClientWidth) or
      (A.Top + A.Height > AParent.ClientHeight) then
    begin
      LInside := False;
      LDetail := LDetail + Format(' %s(%d,%d %dx%d in %dx%d)', [A.Name, A.Left, A.Top, A.Width,
        A.Height, AParent.ClientWidth, AParent.ClientHeight]);
    end;
    for J := I + 1 to AParent.ControlCount - 1 do
    begin
      B := AParent.Controls[J];
      if not B.Visible then
        Continue;
      if (A.Left < B.Left + B.Width) and (B.Left < A.Left + A.Width) and
        (A.Top < B.Top + B.Height) and (B.Top < A.Top + A.Height) then
      begin
        LApart := False;
        LDetail := LDetail + Format(' %s/%s', [A.Name, B.Name]);
      end;
    end;
    if (A is TWinControl) and (TWinControl(A).ControlCount > 0) and not (A is TListView) and
      not (A is TComboBox) then
      CheckChildren(TWinControl(A), AWhat + ' ' + A.Name);
  end;
  Check(LInside and LApart, AWhat + ': inside, apart', LDetail);
end;

procedure TSmoke.CheckLayout(AForm: TForm; const AWhat: string);
begin
  CheckChildren(AForm, AWhat);
end;

procedure TSmoke.Shot(AForm: TForm; const AName: string);
var
  LFolder: string;
  LBitmap: TBitmap;
  {$IFDEF FPC}
  LPng: TPortableNetworkGraphic;
  {$ELSE}
  LPng: TPngImage;
  {$ENDIF}
begin
  LFolder := GetEnvironmentVariable('SMOKE_SHOTS');
  if LFolder = '' then
    Exit;
  Pump(200);
  LBitmap := AForm.GetFormImage;
  try
    {$IFDEF FPC}
    LPng := TPortableNetworkGraphic.Create;
    {$ELSE}
    LPng := TPngImage.Create;
    {$ENDIF}
    try
      LPng.Assign(LBitmap);
      LPng.SaveToFile(IncludeTrailingPathDelimiter(LFolder) + AName + '.png');
    finally
      LPng.Free;
    end;
  finally
    LBitmap.Free;
  end;
end;

function TSmoke.ListHas(AList: TListView; const AText: string; ACol: Integer): Integer;
var
  I: Integer;
  LValue: string;
begin
  for I := 0 to AList.Items.Count - 1 do
  begin
    if ACol = 0 then
      LValue := AList.Items[I].Caption
    else
      LValue := AList.Items[I].SubItems[ACol - 1];
    if Pos(AText, LValue) > 0 then
      Exit(I);
  end;
  Result := -1;
end;

function TSmoke.WaitList(AList: TListView; const AText: string; ACol, ATimeoutMs: Integer): Integer;
var
  LUntil: TDateTime;
begin
  LUntil := Now + ATimeoutMs / MSecsPerDay;
  repeat
    Application.ProcessMessages;
    CheckSynchronize(5);
    Result := ListHas(AList, AText, ACol);
    if Result >= 0 then
      Exit;
  until Now >= LUntil;
end;

function TSmoke.WaitRow(AForm: TForm; AList: TListView; const ACustomer, AStatus: string;
  ATimeoutMs: Integer): Integer;
var
  LUntil: TDateTime;
  I: Integer;
begin
  LUntil := Now + ATimeoutMs / MSecsPerDay;
  repeat
    Application.ProcessMessages;
    CheckSynchronize(5);
    // The read done (the status line says so) and the row there.
    if Pos('Appointments: ', Text(AForm, 'lblStatus')) = 1 then
      for I := 0 to AList.Items.Count - 1 do
        if (AList.Items[I].SubItems[0] = ACustomer) and (AList.Items[I].SubItems[3] = AStatus) then
          Exit(I);
  until Now >= LUntil;
  Result := -1;
end;

function TSmoke.WaitListBox(ABox: TListBox; ATimeoutMs: Integer): Boolean;
var
  LUntil: TDateTime;
begin
  LUntil := Now + ATimeoutMs / MSecsPerDay;
  repeat
    Application.ProcessMessages;
    CheckSynchronize(5);
    if ABox.Items.Count > 0 then
      Exit(True);
  until Now >= LUntil;
  Result := False;
end;

procedure TSmoke.Setup;
var
  LOwner: TAgendaClient;
  LCall: TApiCall;
  LWeek: string;
  I: Integer;
begin
  LOwner := TAgendaClient.Create(FBase, NewHttpTransport);
  try
    LOwner.Login('demo', 'owner@demo.test', FPassword);
    LCall := TApiCall.Create('POST', '/services');
    LCall.Body := '{"name":"Smoke ' + FSuffix + '","durationMinutes":30,"price":40}';
    FServiceId := JsonId(LOwner.Http.Execute(LCall).Body);
    LCall := TApiCall.Create('POST', '/professionals');
    LCall.Body := '{"name":"Smoke ' + FSuffix + '"}';
    FProfessionalId := JsonId(LOwner.Http.Execute(LCall).Body);
    LWeek := '';
    for I := 1 to 7 do
    begin
      if LWeek <> '' then
        LWeek := LWeek + ',';
      LWeek := LWeek + Format('{"weekday":%d,"from":"08:00","to":"18:00"}', [I]);
    end;
    LCall := TApiCall.Create('PUT', '/professionals/' + FProfessionalId + '/working-hours');
    LCall.Body := '{"intervals":[' + LWeek + ']}';
    LOwner.Http.Execute(LCall);
    FCustomerName := 'Conceição Smoke ' + FSuffix;
    LCall := TApiCall.Create('POST', '/customers');
    LCall.Body := '{"name":"' + FCustomerName + '"}';
    LOwner.Http.Execute(LCall);
    LOwner.Logout;
  finally
    LOwner.Free;
  end;
end;

procedure TSmoke.Run;
var
  LLogin: TLoginModel;
  LLoginForm: TLoginForm;
  LBooking: TBookingForm;
  LDay: TDayForm;
  LBox: TComboBox;
  LSlots, LCustomers: TListBox;
  LList: TListView;
  LDate, LTime: string;
  I, LRow: Integer;
begin
  Desktop := TDesktop.Create;
  try
    // The login dialog.
    LLogin := TLoginModel.Create(Desktop.RunnerRef, NewHttpTransport, FBase);
    try
      LLoginForm := TLoginForm.CreateFor(nil, LLogin);
      try
        LLoginForm.Show;
        Pump(200);
        CheckLayout(LLoginForm, 'login');
        Check(not Button(LLoginForm, 'btnOk').Enabled, 'login: Log in off while blank');
        SetEdit(LLoginForm, 'edtTenant', 'demo');
        SetEdit(LLoginForm, 'edtEmail', 'staff@demo.test');
        SetEdit(LLoginForm, 'edtPassword', 'wrong password');
        Check(Button(LLoginForm, 'btnOk').Enabled, 'login: Log in on once filled');
        Click(LLoginForm, 'btnOk');
        Check(WaitFor(LLoginForm, 'lblStatus', TEXT_WRONG_LOGIN), 'login: the wrong password told',
          Text(LLoginForm, 'lblStatus'));
        SetEdit(LLoginForm, 'edtPassword', FPassword);
        Click(LLoginForm, 'btnOk');
        Pump(100);
        I := 0;
        while (LLoginForm.ModalResult <> mrOk) and (I < 200) do
        begin
          Pump(50);
          Inc(I);
        end;
        Check(LLoginForm.ModalResult = mrOk, 'login: logged in');
        Shot(LLoginForm, 'login');
        Check(Text(LLoginForm, 'edtPassword') = '', 'login: the password forgotten');
      finally
        LLoginForm.Free;
      end;
      Desktop.UseClient(LLogin.TakeClient, LLogin.Tenant, LLogin.Email);
    finally
      LLogin.Free;
    end;
    if Desktop.Client = nil then
      Exit;

    // The booking dialog, three days on.
    LDate := FormatDateTime('yyyy"-"mm"-"dd', Date + 3);
    LBooking := TBookingForm.CreateFor(nil, Desktop.RunnerRef, Desktop.Client, Date + 3);
    try
      LBooking.Show;
      LBox := LBooking.FindComponent('cbxService') as TComboBox;
      I := 0;
      while (LBox.Items.Count = 0) and (I < 200) do
      begin
        Pump(50);
        Inc(I);
      end;
      CheckLayout(LBooking, 'booking');
      Check(Text(LBooking, 'lblDate') = LDate, 'booking: the day', Text(LBooking, 'lblDate'));
      LBox.ItemIndex := -1;
      for I := 0 to LBox.Items.Count - 1 do
        if Pos('Smoke ' + FSuffix, LBox.Items[I]) = 1 then
          LBox.ItemIndex := I;
      Check(LBox.ItemIndex >= 0, 'booking: the service listed');
      LBox.OnChange(LBox);
      LBox := LBooking.FindComponent('cbxProfessional') as TComboBox;
      LBox.ItemIndex := LBox.Items.IndexOf('Smoke ' + FSuffix);
      Check(LBox.ItemIndex >= 0, 'booking: the professional listed');
      LBox.OnChange(LBox);
      LSlots := LBooking.FindComponent('lbxSlots') as TListBox;
      Check(WaitListBox(LSlots, 10000), 'booking: free times listed');
      Check(not Button(LBooking, 'btnBook').Enabled, 'booking: Book off with no time nor customer');
      if LSlots.Items.Count = 0 then
        Exit;
      LTime := LSlots.Items[0];
      LSlots.ItemIndex := 0;
      LSlots.OnClick(LSlots);
      SetEdit(LBooking, 'edtSearch', 'conceicao smoke ' + FSuffix);
      Click(LBooking, 'btnSearch');
      LCustomers := LBooking.FindComponent('lbxCustomers') as TListBox;
      I := 0;
      while ((LCustomers.Items.Count <> 1) or (LCustomers.Items[0] <> FCustomerName)) and (I < 200) do
      begin
        Pump(50);
        Inc(I);
      end;
      Check((LCustomers.Items.Count = 1) and (LCustomers.Items[0] = FCustomerName),
        'booking: the customer found without the accents');
      LCustomers.ItemIndex := 0;
      LCustomers.OnClick(LCustomers);
      Check(Button(LBooking, 'btnBook').Enabled, 'booking: Book on');
      Shot(LBooking, 'booking');
      Click(LBooking, 'btnBook');
      I := 0;
      while (LBooking.ModalResult <> mrOk) and (I < 200) do
      begin
        Pump(50);
        Inc(I);
      end;
      Check(LBooking.ModalResult = mrOk, 'booking: booked', Text(LBooking, 'lblStatus'));
    finally
      LBooking.Free;
    end;

    // The day window, on that day.
    LDay := TDayForm.Create(nil);
    try
      LDay.Show;
      Pump(300);
      CheckLayout(LDay, 'day');
      for I := 1 to 3 do
        Click(LDay, 'btnNext');
      Check(WaitFor(LDay, 'lblDate', LDate), 'day: the day', Text(LDay, 'lblDate'));
      LList := LDay.FindComponent('lvDay') as TListView;
      LRow := WaitList(LList, FCustomerName, 1, 10000);
      Check(LRow >= 0, 'day: the appointment listed');
      if LRow < 0 then
        Exit;
      Check(Pos(LTime, LList.Items[LRow].Caption) = 1, 'day: its time', LList.Items[LRow].Caption);
      Check(LList.Items[LRow].SubItems[3] = 'Booked', 'day: booked', LList.Items[LRow].SubItems[3]);
      Check(not Button(LDay, 'btnConfirm').Enabled, 'day: Confirm off with nothing selected');
      LList.Items[LRow].Selected := True;
      Pump(50);
      Check(Button(LDay, 'btnConfirm').Enabled and Button(LDay, 'btnCancel').Enabled and
        not Button(LDay, 'btnDone').Enabled, 'day: what a future booked one allows');
      Click(LDay, 'btnConfirm');
      LRow := WaitRow(LDay, LList, FCustomerName, 'Confirmed', 10000);
      Check(LRow >= 0, 'day: confirmed');
      Shot(LDay, 'day');
      Check((LList.Selected <> nil) and (LList.Selected.SubItems[0] = FCustomerName),
        'day: still selected after the read');
      Click(LDay, 'btnCancel');
      LRow := WaitRow(LDay, LList, FCustomerName, 'Cancelled', 10000);
      Check(LRow >= 0, 'day: cancelled');
      Check(not Button(LDay, 'btnCancel').Enabled, 'day: nothing left to do with it');
      Check(Pos('Appointments: ', Text(LDay, 'lblStatus')) = 1, 'day: the status line',
        Text(LDay, 'lblStatus'));
      LDay.Close;
      Pump(100);
    finally
      LDay.Free;
    end;
  finally
    Desktop.Shutdown;
    Check(Desktop.Client = nil, 'closing: logged out, the client freed');
    FreeAndNil(Desktop);
  end;
end;

function TSmoke.Execute: Boolean;
begin
  try
    Setup;
    Run;
  except
    on E: Exception do
      Check(False, 'unexpected', E.ClassName + ': ' + E.Message);
  end;
  Writeln(Format('desktop smoke: %d checks, %d failures', [FChecks, FFails]));
  Result := FFails = 0;
end;

var
  GSmoke: TSmoke;
begin
  {$IFNDEF FPC}
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  {$ENDIF}
  Application.Initialize;
  if ParamCount < 1 then
  begin
    Writeln('usage: AgendaDesktopSmoke <base url>');
    ExitCode := 2;
    Exit;
  end;
  GSmoke := TSmoke.Create(ParamStr(1));
  try
    if not GSmoke.Execute then
      ExitCode := 1;
  finally
    GSmoke.Free;
  end;
end.
