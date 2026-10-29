program Agenda.UnitTests;

{ DUnitX runner for the unit tests (Delphi). No network, no database server
  (Agenda.OutboxTests and Agenda.WorkerTests use a SQLite file in the
  temporary directory).

  The sibling FPCUnit suite lives in tests/Unit/fpc, with identical test
  bodies: the files there are GENERATED from these by tools/gen_fpc_mirror.py
  (Agenda.DUnitXCompat exists for that). Always edit the DUnitX masters here
  and regenerate the mirror. }

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  Agenda.Passwords in '..\..\src\Agenda.Passwords.pas',
  Agenda.Tokens in '..\..\src\Agenda.Tokens.pas',
  Agenda.Text in '..\..\src\Agenda.Text.pas',
  Agenda.Normalizers in '..\..\src\Agenda.Normalizers.pas',
  Agenda.Validators in '..\..\src\Agenda.Validators.pas',
  Agenda.Money in '..\..\src\Agenda.Money.pas',
  Agenda.Times in '..\..\src\Agenda.Times.pas',
  Agenda.Slots in '..\..\src\Agenda.Slots.pas',
  Agenda.Schema in '..\..\src\Agenda.Schema.pas',
  Agenda.SignedLinks in '..\..\src\Agenda.SignedLinks.pas',
  Agenda.PublicTenancy in '..\..\src\Agenda.PublicTenancy.pas',
  Agenda.Database in '..\..\src\Agenda.Database.pas',
  Agenda.Outbox in '..\..\src\Agenda.Outbox.pas',
  Agenda.Settings in '..\..\src\Agenda.Settings.pas',
  Agenda.Events in '..\..\src\Agenda.Events.pas',
  Agenda.Mail in '..\..\src\Agenda.Mail.pas',
  Agenda.Metrics in '..\..\src\Agenda.Metrics.pas',
  Agenda.Notifications in '..\..\src\Agenda.Notifications.pas',
  Agenda.Leases in '..\..\src\Agenda.Leases.pas',
  Agenda.Reminders in '..\..\src\Agenda.Reminders.pas',
  Agenda.Outbox.Amqp in '..\..\src\Agenda.Outbox.Amqp.pas',
  Agenda.HttpTransport in '..\..\src\Agenda.HttpTransport.pas',
  Agenda.HttpTransport.Fake in '..\..\src\Agenda.HttpTransport.Fake.pas',
  Agenda.HttpClient in '..\..\src\Agenda.HttpClient.pas',
  Agenda.HttpSession in '..\..\src\Agenda.HttpSession.pas',
  Agenda.DUnitXCompat in 'Agenda.DUnitXCompat.pas',
  Agenda.PasswordsTests in 'Agenda.PasswordsTests.pas',
  Agenda.TokensTests in 'Agenda.TokensTests.pas',
  Agenda.TextTests in 'Agenda.TextTests.pas',
  Agenda.NormalizersTests in 'Agenda.NormalizersTests.pas',
  Agenda.MoneyTests in 'Agenda.MoneyTests.pas',
  Agenda.SqlSourcesTests in 'Agenda.SqlSourcesTests.pas',
  Agenda.TimesTests in 'Agenda.TimesTests.pas',
  Agenda.SlotsTests in 'Agenda.SlotsTests.pas',
  Agenda.SignedLinksTests in 'Agenda.SignedLinksTests.pas',
  Agenda.PublicTenancyTests in 'Agenda.PublicTenancyTests.pas',
  Agenda.OutboxTests in 'Agenda.OutboxTests.pas',
  Agenda.MailTests in 'Agenda.MailTests.pas',
  Agenda.WorkerTests in 'Agenda.WorkerTests.pas',
  Agenda.OutboxAmqpTests in 'Agenda.OutboxAmqpTests.pas',
  Agenda.HttpTransportTests in 'Agenda.HttpTransportTests.pas',
  Agenda.HttpClientTests in 'Agenda.HttpClientTests.pas',
  Agenda.HttpSessionTests in 'Agenda.HttpSessionTests.pas';

var
  runner: ITestRunner;
  results: IRunResults;
  logger: ITestLogger;
  nunitLogger: ITestLogger;
begin
  // Acceptance criterion on both sides: 0 leaks (FastMM here, heaptrc on FPC).
  ReportMemoryLeaksOnShutdown := True;
  try
    TDUnitX.CheckCommandLine;
    if TDUnitX.Options.Include = '' then
      TDUnitX.Options.Include := '.';
    runner := TDUnitX.CreateRunner;
    runner.UseRTTI := True;
    runner.FailsOnNoAsserts := False;
    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      runner.AddLogger(logger);
    end;
    nunitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    runner.AddLogger(nunitLogger);
    results := runner.Execute;
    if not results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
    if (TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause) and IsConsole then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
