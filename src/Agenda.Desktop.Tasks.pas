unit Agenda.Desktop.Tasks;

{$I agenda.inc}

{ Work a screen sends off its thread and whose result comes back to it:
  decision 8 of "M6: design" (no call runs on the UI thread).

  - A TUiTask has two halves: Run, on a pool thread, makes the calls and
    keeps their results in the task's own fields (it never touches the
    screen nor its view model); Done, on the UI thread, hands them to the
    view model. An exception in Run is given to Fail (on the pool thread)
    and Done still runs, with Failed True.
  - A task is created with its owner (the view model) and its inputs
    copied in; the runner owns it from Start on and frees it after Done.
  - Forget(AOwner): the owner is going away; its tasks still running finish
    their Run, but their Done is skipped. A view model calls it in its
    destructor, so a late answer never reaches a freed object.
  - TPoolTaskRunner: pascal-common-faa's PcPool runs Run, TThread.Queue
    brings Done to the main thread. A form that closes calls WaitIdle (in
    OnCloseQuery, while the client it calls is still alive): it pumps
    CheckSynchronize until every task is done (pascal-common-faa's
    ThreadPool notes: Application frees the forms before any unit's
    finalization).
  - TManualTaskRunner, for the tests: Start keeps the task; RunPending runs
    Run then Done on the caller's thread, so a test sees the "busy" state in
    between and needs no threads.
  - Spans (decision 9 of "M6: design"): a task is a user action. Start
    opens a detached span named SpanName (PascalCommon.Tracing: it never
    becomes a thread's current span, so it can end on another thread), Run
    goes in a child span "run" that is the pool thread's current span (the
    HTTP calls inside are its children), and the action's span ends after
    Done, on the UI thread: from the click to the screen updated. A failed
    Run is an error on both; a forgotten task's span says so
    (ui.forgotten). A task freed without its Done (a runner freed early)
    exports nothing.

  A library candidate (docs/design.md, "Library candidates"): nothing of
  this application in it. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  PascalCommon.Tracing,
  PascalCommon.Threading,
  PascalCommon.ThreadPool;

type
  TUiTask = class
  private
    FOwner: TObject;
    FForgotten: Boolean;
    FFailed: Boolean;
    FErrorClass: string;
    FErrorMessage: string;
    FSpan: IPcSpan;
  protected
    /// The action's span name. The default: the class name without its T.
    function SpanName: string; virtual;
    /// On a pool thread: the calls, their results kept in fields.
    procedure Run; virtual; abstract;
    /// On the UI thread: the results (or the failure) to the owner.
    procedure Done; virtual; abstract;
    /// On the pool thread, when Run raised: keep what Done needs (E dies
    /// after this). The default keeps the class name and the message.
    procedure Fail(E: Exception); virtual;
  public
    constructor Create(AOwner: TObject);
    property Owner: TObject read FOwner;
    property Failed: Boolean read FFailed;
    property ErrorClass: string read FErrorClass;
    property ErrorMessage: string read FErrorMessage;
    /// The action's span, from Start until after Done (nil before Start).
    property Span: IPcSpan read FSpan;
  end;

  IUiTaskRunner = interface
    ['{5F0B7C2A-9E41-4D3B-A8C6-1E2F3D4B5A69}']
    /// Takes ATask (frees it after its Done).
    procedure Start(ATask: TUiTask);
    /// AOwner's tasks: Done skipped from now on.
    procedure Forget(AOwner: TObject);
    /// Tasks started and not yet done.
    function Pending: Integer;
  end;

  /// The common part: the tasks in flight, Forget, and running one.
  TUiTaskRunnerBase = class(TInterfacedObject)
  protected
    FLock: TCriticalSection;
    FTasks: TList;
    procedure Track(ATask: TUiTask);
    /// Run with its exception given to Fail.
    procedure RunHalf(ATask: TUiTask);
    /// Done unless forgotten, then the task freed.
    procedure DoneHalf(ATask: TUiTask);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Forget(AOwner: TObject);
    function Pending: Integer;
  end;

  TPoolTaskRunner = class(TUiTaskRunnerBase, IUiTaskRunner)
  private type
    // Run on the pool; the pool frees it when Execute returns.
    TItem = class(TPcWorkItem)
    private
      FRunner: TPoolTaskRunner;
      FTask: TUiTask;
    public
      constructor Create(ARunner: TPoolTaskRunner; ATask: TUiTask);
      procedure Execute; override;
    end;
    // Done on the main thread (TThread.Queue takes a method): frees itself.
    TFinisher = class
    private
      FRunner: TPoolTaskRunner;
      FTask: TUiTask;
    public
      constructor Create(ARunner: TPoolTaskRunner; ATask: TUiTask);
      procedure Fire;
    end;
  public
    procedure Start(ATask: TUiTask);
    /// On the main thread: pumps CheckSynchronize until nothing is pending
    /// or ATimeoutMs passed; True when idle.
    function WaitIdle(ATimeoutMs: Cardinal = 30000): Boolean;
  end;

  TManualTaskRunner = class(TUiTaskRunnerBase, IUiTaskRunner)
  private
    FWaiting: TList;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(ATask: TUiTask);
    /// Runs the waiting tasks, oldest first (and any they start), each Run
    /// then Done; the number run.
    function RunPending: Integer;
    /// Runs only the oldest waiting task; False when none.
    function RunOne: Boolean;
  end;

implementation

{ TUiTask }

constructor TUiTask.Create(AOwner: TObject);
begin
  inherited Create;
  FOwner := AOwner;
end;

function TUiTask.SpanName: string;
begin
  Result := ClassName;
  if (Result <> '') and (Result[1] = 'T') then
    Delete(Result, 1, 1);
end;

procedure TUiTask.Fail(E: Exception);
begin
  FErrorClass := E.ClassName;
  FErrorMessage := E.Message;
end;

{ TUiTaskRunnerBase }

constructor TUiTaskRunnerBase.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTasks := TList.Create;
end;

destructor TUiTaskRunnerBase.Destroy;
var
  I: Integer;
begin
  // Tasks never done (a test that stopped early): freed, not run.
  for I := 0 to FTasks.Count - 1 do
    TObject(FTasks[I]).Free;
  FTasks.Free;
  FLock.Free;
  inherited;
end;

procedure TUiTaskRunnerBase.Track(ATask: TUiTask);
begin
  ATask.FSpan := TPcTracing.StartDetachedSpan(ATask.SpanName);
  FLock.Acquire;
  try
    FTasks.Add(ATask);
  finally
    FLock.Release;
  end;
end;

procedure TUiTaskRunnerBase.RunHalf(ATask: TUiTask);
var
  LRun: IPcSpan;
begin
  LRun := TPcTracing.StartChildSpan(ATask.FSpan, 'run');
  try
    ATask.Run;
  except
    on E: Exception do
    begin
      LRun.SetStatus(ssError, E.Message);
      ATask.FFailed := True;
      try
        ATask.Fail(E);
      except
        on Exception do
          ATask.FErrorMessage := E.Message;
      end;
    end;
  end;
  // On this thread: it was its current span.
  LRun.Finish;
end;

procedure TUiTaskRunnerBase.DoneHalf(ATask: TUiTask);
var
  LForgotten: Boolean;
begin
  FLock.Acquire;
  try
    LForgotten := ATask.FForgotten;
    FTasks.Remove(ATask);
  finally
    FLock.Release;
  end;
  try
    try
      if not LForgotten then
        ATask.Done;
    finally
      if ATask.FSpan <> nil then
      begin
        if ATask.FFailed then
          ATask.FSpan.SetStatus(ssError, ATask.FErrorMessage);
        if LForgotten then
          ATask.FSpan.SetBoolAttribute('ui.forgotten', True);
        ATask.FSpan.Finish;
      end;
    end;
  finally
    ATask.Free;
  end;
end;

procedure TUiTaskRunnerBase.Forget(AOwner: TObject);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    for I := 0 to FTasks.Count - 1 do
      if TUiTask(FTasks[I]).FOwner = AOwner then
        TUiTask(FTasks[I]).FForgotten := True;
  finally
    FLock.Release;
  end;
end;

function TUiTaskRunnerBase.Pending: Integer;
begin
  FLock.Acquire;
  try
    Result := FTasks.Count;
  finally
    FLock.Release;
  end;
end;

{ TPoolTaskRunner.TItem }

constructor TPoolTaskRunner.TItem.Create(ARunner: TPoolTaskRunner; ATask: TUiTask);
begin
  inherited Create;
  FRunner := ARunner;
  FTask := ATask;
end;

procedure TPoolTaskRunner.TItem.Execute;
begin
  FRunner.RunHalf(FTask);
  TThread.Queue(nil, TFinisher.Create(FRunner, FTask).Fire);
end;

{ TPoolTaskRunner.TFinisher }

constructor TPoolTaskRunner.TFinisher.Create(ARunner: TPoolTaskRunner; ATask: TUiTask);
begin
  inherited Create;
  FRunner := ARunner;
  FTask := ATask;
end;

procedure TPoolTaskRunner.TFinisher.Fire;
begin
  try
    FRunner.DoneHalf(FTask);
  finally
    Free;
  end;
end;

{ TPoolTaskRunner }

procedure TPoolTaskRunner.Start(ATask: TUiTask);
begin
  Track(ATask);
  PcPool.Queue(TItem.Create(Self, ATask));
end;

function TPoolTaskRunner.WaitIdle(ATimeoutMs: Cardinal): Boolean;
var
  LStart: UInt64;
begin
  LStart := PcTickMs;
  while Pending > 0 do
  begin
    if PcTickMs - LStart >= ATimeoutMs then
      Exit(False);
    CheckSynchronize(10);
  end;
  Result := True;
end;

{ TManualTaskRunner }

constructor TManualTaskRunner.Create;
begin
  inherited Create;
  FWaiting := TList.Create;
end;

destructor TManualTaskRunner.Destroy;
begin
  FWaiting.Free;
  inherited;
end;

procedure TManualTaskRunner.Start(ATask: TUiTask);
begin
  Track(ATask);
  FWaiting.Add(ATask);
end;

function TManualTaskRunner.RunOne: Boolean;
var
  LTask: TUiTask;
begin
  Result := FWaiting.Count > 0;
  if not Result then
    Exit;
  LTask := TUiTask(FWaiting[0]);
  FWaiting.Delete(0);
  RunHalf(LTask);
  DoneHalf(LTask);
end;

function TManualTaskRunner.RunPending: Integer;
begin
  Result := 0;
  while RunOne do
    Inc(Result);
end;

end.
