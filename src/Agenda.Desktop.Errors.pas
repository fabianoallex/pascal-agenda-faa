unit Agenda.Desktop.Errors;

{$I agenda.inc}

{ What a screen shows when a call failed, from the exception the client
  raised (kept as a record: the exception is gone when the task's Done
  runs on the UI thread).

  - EPcValidationError (the server's limits checked here, before sending)
    and a 400 with fields: ekInvalid, the fields to show next to their
    controls.
  - EApiError 401: ekSession (the session is over: log in again), except
    on the login itself, where it is the wrong password (the view model
    says which).
  - 409 and 412: ekConflict (someone was first: the screen reads again).
  - Another 4xx: ekRefused, the server's message.
  - 5xx: ekServer. EHttpTransport: ekOffline. Anything else: ekOther.

  The text is the server's message when it sent one (English, as the
  api's), else this unit's. TAgendaTask keeps one for its Done. }

interface

uses
  SysUtils,
  PascalCommon.Validators,
  PascalApi.HttpTransport,
  Agenda.HttpClient,
  Agenda.Desktop.Tasks;

type
  TUiErrorKind = (ekNone, ekInvalid, ekSession, ekConflict, ekRefused, ekServer, ekOffline,
    ekOther);

  TUiError = record
    Kind: TUiErrorKind;
    /// The HTTP status (0 when there was none).
    Status: Integer;
    /// The server's code ('' when none).
    Code: string;
    Text: string;
    Fields: TPcFieldErrors;
    class function None: TUiError; static;
    function IsNone: Boolean;
    /// The message of AField's first failure ('' when it has none).
    function FieldText(const AField: string): string;
  end;

  /// A task of the desktop client: its failure kept as a TUiError.
  TAgendaTask = class(TUiTask)
  protected
    FError: TUiError;
    procedure Fail(E: Exception); override;
  public
    property Error: TUiError read FError;
  end;

const
  TEXT_OFFLINE = 'The server didn''t answer. Check the connection and try again.';
  TEXT_SESSION = 'Your session has ended. Log in again.';
  TEXT_SERVER = 'The server failed (%d). Try again in a moment.';
  TEXT_CHECK_FIELDS = 'Check the fields marked.';

function UiErrorOf(E: Exception): TUiError;

implementation

class function TUiError.None: TUiError;
begin
  Result.Kind := ekNone;
  Result.Status := 0;
  Result.Code := '';
  Result.Text := '';
  Result.Fields := nil;
end;

function TUiError.IsNone: Boolean;
begin
  Result := Kind = ekNone;
end;

function TUiError.FieldText(const AField: string): string;
var
  I: Integer;
begin
  for I := 0 to High(Fields) do
    if SameText(Fields[I].Field, AField) then
      Exit(Fields[I].Message);
  Result := '';
end;

function UiErrorOf(E: Exception): TUiError;
var
  LApi: EApiError;
begin
  Result := TUiError.None;
  Result.Text := E.Message;
  if E is EPcValidationError then
  begin
    Result.Kind := ekInvalid;
    Result.Fields := Copy(EPcValidationError(E).Errors, 0, MaxInt);
    if Length(Result.Fields) > 1 then
      Result.Text := TEXT_CHECK_FIELDS;
  end
  else if E is EApiError then
  begin
    LApi := EApiError(E);
    Result.Status := LApi.Status;
    Result.Code := LApi.Code;
    Result.Fields := Copy(LApi.Fields, 0, MaxInt);
    case LApi.Status of
      401:
        begin
          Result.Kind := ekSession;
          Result.Text := TEXT_SESSION;
        end;
      409, 412:
        Result.Kind := ekConflict;
      500..599:
        begin
          Result.Kind := ekServer;
          Result.Text := Format(TEXT_SERVER, [LApi.Status]);
        end;
    else
      if Length(Result.Fields) > 0 then
      begin
        Result.Kind := ekInvalid;
        if Length(Result.Fields) > 1 then
          Result.Text := TEXT_CHECK_FIELDS;
      end
      else
        Result.Kind := ekRefused;
    end;
  end
  else if E is EHttpTransport then
  begin
    Result.Kind := ekOffline;
    Result.Text := TEXT_OFFLINE;
  end
  else
    Result.Kind := ekOther;
end;

{ TAgendaTask }

procedure TAgendaTask.Fail(E: Exception);
begin
  inherited Fail(E);
  FError := UiErrorOf(E);
end;

end.
