program AgendaUnitTestsFpc;

{ FPCUnit runner for the unit tests. Same tests as the DUnitX suite
  (tests/Unit/Agenda.UnitTests.dpr): the fixtures in tests/Unit/fpc are
  generated from the DUnitX masters by tools/gen_fpc_mirror.py.

  Console (text output), when called with any parameter:
    .\AgendaUnitTestsFpc.exe --all --format=plain
  GUI (test tree), with no parameters, on Windows only. }

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  cwstring,
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  Interfaces, Forms, GuiTestRunner,
  {$ENDIF}
  Classes, consoletestrunner, testregistry,
  Agenda.PasswordsTests,
  Agenda.TokensTests,
  Agenda.TextTests,
  Agenda.MoneyTests,
  Agenda.TimesTests;

var
  ConsoleApp: TTestRunner;
begin
  // The tests' non-ASCII literals are UTF-8.
  SetMultiByteConversionCodePage(CP_UTF8);
  {$IFDEF MSWINDOWS}
  if ParamCount = 0 then
  begin
    Application.Initialize;
    Application.CreateForm(TGUITestRunner, TestRunner);
    Application.Run;
  end
  else
  {$ENDIF}
  begin
    DefaultFormat := fPlain;
    DefaultRunAllTests := True;
    ConsoleApp := TTestRunner.Create(nil);
    try
      ConsoleApp.Initialize;
      ConsoleApp.Title := 'pascal-agenda-faa - unit tests (FPCUnit)';
      ConsoleApp.Run;
    finally
      ConsoleApp.Free;
    end;
  end;
end.
