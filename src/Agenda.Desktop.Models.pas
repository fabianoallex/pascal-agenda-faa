unit Agenda.Desktop.Models;

{$I agenda.inc}

{ The view models' common part (decision 3 of "M6: design": the logic
  lives in view models with tests; a form reads their state and passes its
  events on, pascal-snake's rule).

  - State is read and changed on the UI thread only; the calls go through
    an IUiTaskRunner (the pool in the program, the manual runner in the
    tests). Busy while any of the model's tasks runs.
  - OnChange after every change of state the screen shows; OnSessionLost
    when a call met a 401 the session couldn't renew (the program goes back
    to the login).
  - Error: the last call's failure (TUiError.None after a success); Notice:
    a line for the user that isn't an error (someone else was first, the
    screen read again).
  - The destructor forgets the model's tasks still running: their Done is
    skipped. }

interface

uses
  SysUtils,
  Classes,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors;

type
  TClockFunc = function: TDateTime of object;

  TDesktopModel = class
  private
    FRunner: IUiTaskRunner;
    FPending: Integer;
    FError: TUiError;
    FNotice: string;
    FOnChange: TNotifyEvent;
    FOnSessionLost: TNotifyEvent;
  protected
    procedure Changed;
    /// Starts ATask (its Done must call Finished first).
    procedure StartTask(ATask: TAgendaTask);
    /// From a task's Done: one fewer pending; AError kept (a 401 also
    /// raises OnSessionLost). True when the task succeeded.
    function Finished(const AError: TUiError): Boolean;
    procedure SetError(const AError: TUiError);
    procedure SetNotice(const AText: string);
    property Runner: IUiTaskRunner read FRunner;
  public
    constructor Create(const ARunner: IUiTaskRunner);
    destructor Destroy; override;
    function Busy: Boolean;
    property Error: TUiError read FError;
    property Notice: string read FNotice;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    property OnSessionLost: TNotifyEvent read FOnSessionLost write FOnSessionLost;
  end;

implementation

constructor TDesktopModel.Create(const ARunner: IUiTaskRunner);
begin
  inherited Create;
  FRunner := ARunner;
  FError := TUiError.None;
end;

destructor TDesktopModel.Destroy;
begin
  if FRunner <> nil then
    FRunner.Forget(Self);
  FRunner := nil;
  inherited;
end;

function TDesktopModel.Busy: Boolean;
begin
  Result := FPending > 0;
end;

procedure TDesktopModel.Changed;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

procedure TDesktopModel.StartTask(ATask: TAgendaTask);
begin
  Inc(FPending);
  FRunner.Start(ATask);
  Changed;
end;

function TDesktopModel.Finished(const AError: TUiError): Boolean;
begin
  if FPending > 0 then
    Dec(FPending);
  FError := AError;
  Result := AError.IsNone;
  if (AError.Kind = ekSession) and Assigned(FOnSessionLost) then
    FOnSessionLost(Self);
end;

procedure TDesktopModel.SetError(const AError: TUiError);
begin
  FError := AError;
end;

procedure TDesktopModel.SetNotice(const AText: string);
begin
  FNotice := AText;
end;

end.
