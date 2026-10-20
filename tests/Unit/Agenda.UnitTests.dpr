program Agenda.UnitTests;

{ DUnitX runner for the unit tests (Delphi). No network, no database server.

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
  Agenda.SqlSources in '..\..\src\Agenda.SqlSources.pas',
  Agenda.Schema in '..\..\src\Agenda.Schema.pas',
  Agenda.DUnitXCompat in 'Agenda.DUnitXCompat.pas',
  Agenda.PasswordsTests in 'Agenda.PasswordsTests.pas',
  Agenda.TokensTests in 'Agenda.TokensTests.pas',
  Agenda.TextTests in 'Agenda.TextTests.pas',
  Agenda.NormalizersTests in 'Agenda.NormalizersTests.pas',
  Agenda.MoneyTests in 'Agenda.MoneyTests.pas',
  Agenda.SqlSourcesTests in 'Agenda.SqlSourcesTests.pas',
  Agenda.TimesTests in 'Agenda.TimesTests.pas';

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
