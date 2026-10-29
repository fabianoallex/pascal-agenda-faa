unit Agenda.Desktop.App;

{ The desktop program's flow, the same on the VCL and the LCL:

  1. Settings from the .env next to the program (TAppConfig): AGENDA_SERVER
     (http://127.0.0.1:9400), and AGENDA_TENANT, AGENDA_EMAIL to fill the
     login in.
  2. The login dialog; cancelled, the program ends.
  3. The day as the main form (Application.CreateForm: TDayForm has no
     .dfm/.lfm, its Create calls CreateNew and reads Desktop below).
  4. When it closes: the calls still running waited for, the logout
     (decision 6: the refresh token lives in memory only), the client
     freed. }

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
  {$IFDEF FPC}
  Forms, Controls,
  {$ELSE}
  Vcl.Forms, Vcl.Controls,
  {$ENDIF}
  SysUtils,
  PascalApi.Config,
  Agenda.HttpTransport,
  Agenda.Client,
  Agenda.Desktop.Tasks;

const
  DEFAULT_SERVER = 'http://127.0.0.1:9400';

type
  TDesktop = class
  private
    FRunner: TPoolTaskRunner;
    FRunnerRef: IUiTaskRunner;
    FClient: TAgendaClient;
    FTenant: string;
    FEmail: string;
  public
    constructor Create;
    destructor Destroy; override;
    /// The login dialog; True when logged in.
    function LogIn: Boolean;
    /// The logged-in client the screens will use (now owned here).
    procedure UseClient(AClient: TAgendaClient; const ATenant, AEmail: string);
    /// Waits for the calls, logs out, frees the client.
    procedure Shutdown;
    property Runner: TPoolTaskRunner read FRunner;
    property RunnerRef: IUiTaskRunner read FRunnerRef;
    property Client: TAgendaClient read FClient;
    property Tenant: string read FTenant;
    property Email: string read FEmail;
  end;

var
  /// The running program's (set by RunDesktop).
  Desktop: TDesktop;

/// The whole program, after Application.Initialize.
procedure RunDesktop;

implementation

uses
  Agenda.Desktop.Login,
  Agenda.Desktop.LoginForm,
  Agenda.Desktop.DayForm;

constructor TDesktop.Create;
begin
  inherited Create;
  FRunner := TPoolTaskRunner.Create;
  FRunnerRef := FRunner;
end;

destructor TDesktop.Destroy;
begin
  Shutdown;
  FRunnerRef := nil;
  inherited;
end;

function TDesktop.LogIn: Boolean;
var
  LModel: TLoginModel;
  LForm: TLoginForm;
begin
  LModel := TLoginModel.Create(FRunnerRef, NewHttpTransport,
    TAppConfig.Get('AGENDA_SERVER', DEFAULT_SERVER));
  try
    LModel.Tenant := TAppConfig.Get('AGENDA_TENANT', '');
    LModel.Email := TAppConfig.Get('AGENDA_EMAIL', '');
    LForm := TLoginForm.CreateFor(nil, LModel);
    try
      Result := LForm.ShowModal = mrOk;
    finally
      LForm.Free;
    end;
    if Result then
      UseClient(LModel.TakeClient, LModel.Tenant, LModel.Email);
  finally
    LModel.Free;
  end;
end;

procedure TDesktop.UseClient(AClient: TAgendaClient; const ATenant, AEmail: string);
begin
  FClient := AClient;
  FTenant := ATenant;
  FEmail := AEmail;
end;

procedure TDesktop.Shutdown;
begin
  if FRunner <> nil then
    FRunner.WaitIdle(15000);
  if FClient <> nil then
  begin
    FClient.Logout;
    FreeAndNil(FClient);
  end;
end;

procedure RunDesktop;
var
  LForm: TDayForm;
begin
  Desktop := TDesktop.Create;
  try
    if Desktop.LogIn then
    begin
      Application.CreateForm(TDayForm, LForm);
      Application.Run;
    end;
    Desktop.Shutdown;
  finally
    FreeAndNil(Desktop);
  end;
end;

end.
