unit Agenda.StopSignal;

{$I agenda.inc}

{ A console program's stop request: Ctrl+C, Ctrl+Break or the console
  closing on Windows; SIGINT or SIGTERM on Unix (Ctrl+C, docker stop,
  systemd). The handler only raises a flag: the program's loop asks
  StopRequested between passes, finishes the one it is in and shuts down in
  its own order.

  - Windows: SetConsoleCtrlHandler. The handler runs on a thread the system
    creates. When the console closes, the system ends the process as soon as
    the handler returns (and a few seconds later anyway), so for that one it
    waits for StopSignalDone, at most STOP_CLOSE_WAIT_MS.
  - Unix: fpSignal. The handler only sets an integer (what a signal handler
    may do); the main thread reads it.
  - StopSleep sleeps in short slices, so a stop doesn't wait out a long
    sleep.

  A library candidate (docs/design.md, "Library candidates"): nothing of this
  application in it. }

interface

const
  /// Windows, console closing: how long the handler waits for the program's
  /// shutdown before returning (the system kills the process after ~5 s).
  STOP_CLOSE_WAIT_MS = 4500;
  /// StopSleep's slice.
  STOP_SLICE_MS = 50;

/// Installs the handlers; once, from the main thread, before the loop.
procedure StopSignalInstall;
/// Removes them (Windows) or restores the default action (Unix).
procedure StopSignalUninstall;
/// A stop was asked for (a signal or RequestStop).
function StopRequested: Boolean;
/// Asks for a stop from the program itself (a fatal error, a test).
procedure RequestStop;
/// Sleeps up to AMilliseconds, returning early on a stop; True when a stop
/// was asked for.
function StopSleep(AMilliseconds: Integer): Boolean;
/// The program finished shutting down: a handler waiting for it (Windows,
/// the console closing) may return.
procedure StopSignalDone;

implementation

uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  {$IFDEF FPC}{$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}{$ENDIF}
  SysUtils,
  PascalCommon.Threading;

var
  GStop: Integer = 0;
  GDone: Integer = 0;

function StopRequested: Boolean;
begin
  Result := PcAtomicGet(GStop) <> 0;
end;

procedure RequestStop;
begin
  PcAtomicSet(GStop, 1);
end;

procedure StopSignalDone;
begin
  PcAtomicSet(GDone, 1);
end;

function StopSleep(AMilliseconds: Integer): Boolean;
var
  LLeft, LSlice: Integer;
begin
  LLeft := AMilliseconds;
  while (LLeft > 0) and not StopRequested do
  begin
    LSlice := LLeft;
    if LSlice > STOP_SLICE_MS then
      LSlice := STOP_SLICE_MS;
    Sleep(LSlice);
    Dec(LLeft, LSlice);
  end;
  Result := StopRequested;
end;

{$IFDEF MSWINDOWS}
const
  // Windows' values (wincon.h); not every RTL version names all of them.
  STOP_CTRL_C = 0;
  STOP_CTRL_BREAK = 1;
  STOP_CTRL_CLOSE = 2;

function ConsoleHandler(ACtrlType: DWORD): BOOL; stdcall;
var
  LWaited: Integer;
begin
  Result := (ACtrlType = STOP_CTRL_C) or (ACtrlType = STOP_CTRL_BREAK) or
    (ACtrlType = STOP_CTRL_CLOSE);
  if not Result then
    Exit;
  RequestStop;
  if ACtrlType = STOP_CTRL_CLOSE then
  begin
    LWaited := 0;
    while (PcAtomicGet(GDone) = 0) and (LWaited < STOP_CLOSE_WAIT_MS) do
    begin
      Sleep(STOP_SLICE_MS);
      Inc(LWaited, STOP_SLICE_MS);
    end;
  end;
end;

procedure StopSignalInstall;
begin
  if not SetConsoleCtrlHandler(@ConsoleHandler, True) then
    RaiseLastOSError;
end;

procedure StopSignalUninstall;
begin
  SetConsoleCtrlHandler(@ConsoleHandler, False);
end;
{$ENDIF}

{$IFDEF FPC}{$IFDEF UNIX}
procedure UnixStopHandler(ASignal: cint); cdecl;
begin
  PcAtomicSet(GStop, 1);
end;

procedure StopSignalInstall;
begin
  fpSignal(SIGINT, SignalHandler(@UnixStopHandler));
  fpSignal(SIGTERM, SignalHandler(@UnixStopHandler));
end;

procedure StopSignalUninstall;
begin
  // nil is SIG_DFL (0): the default action again.
  fpSignal(SIGINT, nil);
  fpSignal(SIGTERM, nil);
end;
{$ENDIF}{$ENDIF}

end.
