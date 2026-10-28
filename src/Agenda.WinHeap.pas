unit Agenda.WinHeap;

{$I agenda.inc}

{ Delphi on Windows: the program's memory goes to the Windows process heap
  instead of the RTL's memory manager. First unit of a program's uses.

  Measured in pascal-db-faa (gotcha 55, 2026-10-28, from this application's
  M5 load test): with the RTL's manager a Delphi program with several
  threads gained no throughput over one thread (FireDAC on SQLite, about
  2,100 operations a second with 1, 8 or 32 threads; Zeos the same), while
  FPC's SQLdb went from 2,120 to 9,177. The process heap (Windows' low
  fragmentation heap) took FireDAC to 6,214 with 32 threads, with nothing
  else changed. The RTL's manager has one lock for all its medium blocks.

  It installs only when nothing was allocated yet (a block the RTL's
  manager gave can't be freed here), which holds for the first unit of the
  uses; otherwise it leaves the RTL's manager in place and says so in
  MemoryManagerName. MEMORY_MANAGER=default in the environment keeps the
  RTL's manager too, for comparing the two (read from the process
  environment only: the .env isn't loaded yet).

  No leak report through this manager: the unit tests keep the RTL's
  (ReportMemoryLeaksOnShutdown). FPC: nothing (its manager is another one,
  and Linux has no such heap).

  A library candidate (docs/design.md, "Library candidates"): nothing of
  this application in it. }

interface

/// Which memory manager the program runs on, for its startup log.
function MemoryManagerName: string;

implementation

{$IF DEFINED(MSWINDOWS) and not DEFINED(FPC)}
uses
  Windows;

var
  GHeap: THandle;
  GName: string;

function HeapGet(Size: NativeInt): Pointer;
begin
  Result := HeapAlloc(GHeap, 0, Size);
end;

function HeapAllocZero(Size: NativeInt): Pointer;
begin
  Result := HeapAlloc(GHeap, HEAP_ZERO_MEMORY, Size);
end;

function HeapRelease(P: Pointer): Integer;
begin
  if HeapFree(GHeap, 0, P) then
    Result := 0
  else
    Result := 1;
end;

function HeapResize(P: Pointer; Size: NativeInt): Pointer;
begin
  Result := HeapReAlloc(GHeap, 0, P, Size);
end;

function NothingAllocated: Boolean;
var
  LState: TMemoryManagerState;
  I: Integer;
begin
  GetMemoryManagerState(LState);
  Result := (LState.AllocatedMediumBlockCount = 0) and (LState.AllocatedLargeBlockCount = 0);
  for I := Low(LState.SmallBlockTypeStates) to High(LState.SmallBlockTypeStates) do
    if LState.SmallBlockTypeStates[I].AllocatedBlockCount <> 0 then
      Result := False;
end;

function KeepDefault: Boolean;
var
  LBuf: array[0..15] of WideChar;
begin
  Result := (GetEnvironmentVariableW('MEMORY_MANAGER', LBuf, Length(LBuf)) = 7) and
    (LBuf[0] = 'd') and (LBuf[1] = 'e') and (LBuf[2] = 'f') and (LBuf[3] = 'a') and
    (LBuf[4] = 'u') and (LBuf[5] = 'l') and (LBuf[6] = 't');
end;

procedure Install;
var
  LManager: TMemoryManagerEx;
begin
  // No string assignment before the switch: that would allocate.
  if KeepDefault then
    Exit;
  if not NothingAllocated then
    Exit;
  GHeap := GetProcessHeap;
  GetMemoryManager(LManager);
  LManager.GetMem := HeapGet;
  LManager.AllocMem := HeapAllocZero;
  LManager.FreeMem := HeapRelease;
  LManager.ReallocMem := HeapResize;
  SetMemoryManager(LManager);
end;

function MemoryManagerName: string;
begin
  Result := GName;
end;

initialization
  Install;
  if GHeap <> 0 then
    GName := 'windows heap'
  else if KeepDefault then
    GName := 'delphi (MEMORY_MANAGER=default)'
  else
    GName := 'delphi (blocks allocated before Agenda.WinHeap)';
{$ELSE}
function MemoryManagerName: string;
begin
  {$IFDEF FPC}
  Result := 'fpc';
  {$ELSE}
  Result := 'delphi';
  {$ENDIF}
end;
{$IFEND}
end.
