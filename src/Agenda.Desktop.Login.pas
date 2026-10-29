unit Agenda.Desktop.Login;

{$I agenda.inc}

{ The login screen's view model: the server's address (from the settings,
  editable), the company (the tenant's slug), the email and the password.

  - CanSubmit when nothing is blank and no login runs.
  - Submit makes a TAgendaClient for that server and logs in on the pool
    (the password's PBKDF2 on the server takes a moment); Done keeps the
    client and raises OnLoggedIn. TakeClient hands it to the program, which
    owns it from then on (and logs out with it when it closes).
  - A 401 here is the wrong company, email or password (one answer for
    all, as the server gives); 403 tenant_suspended and the rest show the
    server's message; no server, ekOffline.
  - An address without a scheme gets http://.
  - Logging in again (the session was lost): CreateAgain takes the client
    the screens already use; Submit logs it in again (the server is the
    client's), and TakeClient gives nil: the program keeps its own. }

interface

uses
  SysUtils,
  Classes,
  Agenda.HttpTransport,
  Agenda.Client,
  Agenda.Desktop.Tasks,
  Agenda.Desktop.Errors,
  Agenda.Desktop.Models;

const
  TEXT_WRONG_LOGIN = 'Wrong company, email or password.';

type
  TLoginModel = class(TDesktopModel)
  private
    FTransport: IHttpTransport;
    FServer: string;
    FTenant: string;
    FEmail: string;
    FPassword: string;
    FClient: TAgendaClient;
    FAgain: TAgendaClient;
    FRole: string;
    FOnLoggedIn: TNotifyEvent;
    procedure SetServer(const AValue: string);
    procedure SetTenant(const AValue: string);
    procedure SetEmail(const AValue: string);
    procedure SetPassword(const AValue: string);
  public
    /// ATransport: the HTTP client the session will use (the fake one in
    /// the tests).
    constructor Create(const ARunner: IUiTaskRunner; const ATransport: IHttpTransport;
      const AServer: string);
    /// Logging AClient (not owned) in again, the company and email kept.
    constructor CreateAgain(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
      const ATenant, AEmail: string);
    destructor Destroy; override;
    /// True when logging the screens' client in again.
    function Again: Boolean;
    function CanSubmit: Boolean;
    procedure Submit;
    /// The logged-in client, now the caller's (nil before OnLoggedIn).
    function TakeClient: TAgendaClient;
    /// The server's address as it will be called.
    function ServerUrl: string;
    property Server: string read FServer write SetServer;
    property Tenant: string read FTenant write SetTenant;
    property Email: string read FEmail write SetEmail;
    property Password: string read FPassword write SetPassword;
    /// The user's role after the login (owner, staff).
    property Role: string read FRole;
    property OnLoggedIn: TNotifyEvent read FOnLoggedIn write FOnLoggedIn;
  end;

implementation

type
  TLoginTask = class(TAgendaTask)
  private
    FModel: TLoginModel;
    FClient: TAgendaClient;
    FOwnsClient: Boolean;
    FTenant, FEmail, FPassword: string;
    FRole: string;
  protected
    function SpanName: string; override;
    procedure Run; override;
    procedure Done; override;
  public
    destructor Destroy; override;
  end;

destructor TLoginTask.Destroy;
begin
  // Not handed over (failed, or the model gone): the client goes with it.
  if FOwnsClient then
    FClient.Free;
  inherited;
end;

procedure TLoginTask.Run;
begin
  FClient.Login(FTenant, FEmail, FPassword);
  FRole := FClient.Me.Role;
end;

procedure TLoginTask.Done;
var
  LError: TUiError;
begin
  LError := Error;
  if (LError.Kind = ekSession) then
  begin
    // A 401 on the login: the credentials, not a session.
    LError.Kind := ekRefused;
    LError.Text := TEXT_WRONG_LOGIN;
  end;
  if not FModel.Finished(LError) then
  begin
    FModel.Changed;
    Exit;
  end;
  if FOwnsClient then
  begin
    FModel.FClient.Free;
    FModel.FClient := FClient;
    FClient := nil;
  end;
  FModel.FRole := FRole;
  FModel.FPassword := '';
  FModel.Changed;
  if Assigned(FModel.FOnLoggedIn) then
    FModel.FOnLoggedIn(FModel);
end;

{ TLoginModel }

constructor TLoginModel.Create(const ARunner: IUiTaskRunner; const ATransport: IHttpTransport;
  const AServer: string);
begin
  inherited Create(ARunner);
  FTransport := ATransport;
  FServer := AServer;
end;

constructor TLoginModel.CreateAgain(const ARunner: IUiTaskRunner; AClient: TAgendaClient;
  const ATenant, AEmail: string);
begin
  inherited Create(ARunner);
  FAgain := AClient;
  FServer := AClient.Http.BaseUrl;
  FTenant := ATenant;
  FEmail := AEmail;
end;

function TLoginModel.Again: Boolean;
begin
  Result := FAgain <> nil;
end;

destructor TLoginModel.Destroy;
begin
  FClient.Free;
  inherited;
end;

procedure TLoginModel.SetServer(const AValue: string);
begin
  FServer := AValue;
  Changed;
end;

procedure TLoginModel.SetTenant(const AValue: string);
begin
  FTenant := AValue;
  Changed;
end;

procedure TLoginModel.SetEmail(const AValue: string);
begin
  FEmail := AValue;
  Changed;
end;

procedure TLoginModel.SetPassword(const AValue: string);
begin
  FPassword := AValue;
  Changed;
end;

function TLoginModel.ServerUrl: string;
begin
  Result := Trim(FServer);
  if (Result <> '') and (Pos('://', Result) = 0) then
    Result := 'http://' + Result;
end;

function TLoginModel.CanSubmit: Boolean;
begin
  Result := (not Busy) and (Trim(FServer) <> '') and (Trim(FTenant) <> '') and
    (Trim(FEmail) <> '') and (FPassword <> '');
end;

procedure TLoginModel.Submit;
var
  LTask: TLoginTask;
begin
  if not CanSubmit then
    Exit;
  SetError(TUiError.None);
  LTask := TLoginTask.Create(Self);
  LTask.FModel := Self;
  if FAgain <> nil then
    LTask.FClient := FAgain
  else
  begin
    LTask.FClient := TAgendaClient.Create(ServerUrl, FTransport);
    LTask.FOwnsClient := True;
  end;
  LTask.FTenant := Trim(FTenant);
  LTask.FEmail := Trim(FEmail);
  LTask.FPassword := FPassword;
  StartTask(LTask);
end;

function TLoginModel.TakeClient: TAgendaClient;
begin
  Result := FClient;
  FClient := nil;
end;

function TLoginTask.SpanName: string;
begin
  Result := 'login';
end;

end.
