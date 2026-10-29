program AgendaDesktop;

{ The staff's desktop client (M6): the day, booking, the appointments'
  status, on the api through Agenda.Client and the server's own DTOs.
  One source for Delphi (VCL, AgendaDesktop.dproj) and Lazarus (LCL,
  AgendaDesktop.lpi); the screens are built in code with OPCB, no .dfm or
  .lfm. The flow: Agenda.Desktop.App. Settings: a .env next to the program
  (AGENDA_SERVER, AGENDA_TENANT, AGENDA_EMAIL). }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  {$IFDEF FPC}
  Interfaces,
  Forms,
  {$ELSE}
  Vcl.Forms,
  {$ENDIF}
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
  Agenda.Client in '..\..\src\Agenda.Client.pas',
  Agenda.Desktop.Tasks in '..\..\src\Agenda.Desktop.Tasks.pas',
  Agenda.Desktop.Errors in '..\..\src\Agenda.Desktop.Errors.pas',
  Agenda.Desktop.Models in '..\..\src\Agenda.Desktop.Models.pas',
  Agenda.Desktop.Login in '..\..\src\Agenda.Desktop.Login.pas',
  Agenda.Desktop.Day in '..\..\src\Agenda.Desktop.Day.pas',
  Agenda.Desktop.Booking in '..\..\src\Agenda.Desktop.Booking.pas',
  Agenda.Desktop.Ui in 'Agenda.Desktop.Ui.pas',
  Agenda.Desktop.LoginForm in 'Agenda.Desktop.LoginForm.pas',
  Agenda.Desktop.DayForm in 'Agenda.Desktop.DayForm.pas',
  Agenda.Desktop.BookingForm in 'Agenda.Desktop.BookingForm.pas',
  Agenda.Desktop.App in 'Agenda.Desktop.App.pas';

begin
  {$IFNDEF FPC}
  {$IFDEF DEBUG}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.MainFormOnTaskbar := True;
  {$ENDIF}
  Application.Title := 'Agenda';
  Application.Initialize;
  RunDesktop;
end.
