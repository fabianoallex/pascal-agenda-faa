unit Agenda.HttpClient;

{$I agenda.inc}

(* A JSON API client over IHttpTransport, knowing nothing of the agenda: the
  base URL, the bearer token, a 401 answered by renewing the token once, the
  retries, traceparent, the error body read into an exception, If-Match and
  Idempotency-Key. Bodies go in and out as JSON text; the typed layer above
  (Agenda.Client) maps them with TJsonMapper.

  - Execute returns a 2xx answer and raises EApiError for any other status,
    with the error body's message, code and fields (the shape of
    pascal-api-infra-faa's error handler: {"error", "code", "fields":
    [{"field", "code", "message"}]}), the same TPcFieldErrors a local
    TApiSchema.Check gives, so a screen shows both alike.
  - EHttpTransport passes through when there was no answer and no retry is
    left (or none was allowed).
  - Credentials (IApiCredentials) give the bearer token; on a 401 Renew is
    asked once and, when it gives a new token, the request goes again with
    it (not counted as a retry). Anonymous requests skip both.
  - Retries (decision 7 of "M6: design"): a GET or HEAD, and a request with
    an Idempotency-Key (the server replays its first answer), go again on a
    lost connection, 502, 503 and 504, and on 429; a keyed request also on
    409 idempotency_key_in_flight (its first try still running). The wait
    is the answer's Retry-After in seconds when it has one, else a backoff
    (BackoffMs, doubled each time); a Retry-After longer than
    MaxRetryAfterMs isn't waited for: the error goes to the caller. Any
    other request (a PATCH, a cancel) is never sent twice by the client.
  - Spans (PascalCommon.Tracing): each try is a client span, named after
    the method, and its traceparent is the one sent. Its parent is the
    calling thread's current span (a desktop task's run span); with none,
    the tries share the request's TraceId, or a new trace when it names
    none. The retries and the try after a renewed token stay in the same
    trace. Attributes: http.request.method, url.path (no query: it may
    carry what a user typed), http.response.status_code,
    http.request.resend_count; a status of 400 or more, or no answer, is
    an error. With tracing not started the spans record nothing, and the
    traceparent still goes.
  - Execute keeps no state between calls: several threads may call it at
    once (the client's settings are set before).

  A library candidate (docs/design.md, "Library candidates": the typed HTTP
  client). Nothing of this application in it. *)

interface

uses
  SysUtils,
  PascalCommon.Validators,
  PascalCommon.Tracing,
  Agenda.HttpTransport;

const
  API_DEFAULT_MAX_ATTEMPTS = 3;
  API_DEFAULT_BACKOFF_MS = 300;
  API_DEFAULT_MAX_RETRY_AFTER_MS = 10000;
  /// pascal-api-infra-faa's code for a keyed request whose first try runs.
  API_CODE_KEY_IN_FLIGHT = 'idempotency_key_in_flight';

type
  /// What the client sends; Path starts with '/' and carries the query.
  TApiCall = record
    Method: string;
    Path: string;
    /// JSON; '' for none.
    Body: string;
    /// The ETag of the version read, for a change ('' for none).
    IfMatch: string;
    /// Made once per user action and kept across its tries ('' for none).
    IdempotencyKey: string;
    /// The user action's trace ('' for a new one per request).
    TraceId: string;
    /// No bearer token, no renewal (the login, the refresh).
    Anonymous: Boolean;
    /// Never retried, even when it could be.
    NoRetry: Boolean;
    class function Create(const AMethod, APath: string): TApiCall; static;
  end;

  TApiReply = record
    Status: Integer;
    Body: string;
    Headers: THttpFields;
    function Header(const AName: string): string;
    /// The ETag header ('' when absent).
    function ETag: string;
  end;

  /// An answer other than 2xx.
  EApiError = class(Exception)
  private
    FStatus: Integer;
    FCode: string;
    FFields: TPcFieldErrors;
    FBody: string;
    FMethod: string;
    FPath: string;
  public
    constructor CreateFromResponse(const ARequest: TApiCall; const AResponse: TApiReply);
    property Status: Integer read FStatus;
    /// The body's "code" ('' when it had none).
    property Code: string read FCode;
    /// The body's "fields" (none when it had none).
    property Fields: TPcFieldErrors read FFields;
    property Body: string read FBody;
    property Method: string read FMethod;
    property Path: string read FPath;
  end;

  /// The bearer token's source; thread-safe (Execute calls it from any
  /// thread).
  IApiCredentials = interface
    ['{A4D3B8E1-5C2F-4E7A-9B61-0F8C2D7E4A35}']
    /// The token to send ('' for none: the request goes without one).
    function AccessToken: string;
    /// After a 401 to AStaleToken: True when there is a token to try (a
    /// newer one already, or one renewed now); False to give the 401 up.
    function Renew(const AStaleToken: string): Boolean;
  end;

  TApiSleepProc = procedure(AMilliseconds: Integer) of object;

  TApiHttpClient = class
  private
    FBaseUrl: string;
    FTransport: IHttpTransport;
    FCredentials: IApiCredentials;
    FMaxAttempts: Integer;
    FBackoffMs: Integer;
    FMaxRetryAfterMs: Integer;
    FTimeoutMs: Integer;
    FSleep: TApiSleepProc;
    procedure DefaultSleep(AMilliseconds: Integer);
    function Exchange(const ARequest: TApiCall; const ATraceParent, AToken: string): TApiReply;
    function TrySend(const ARequest: TApiCall; const AParent: IPcSpan;
      const ATraceId: string; ASampled: Boolean; AResend: Integer; const AToken: string): TApiReply;
    function MayRetry(const ARequest: TApiCall): Boolean;
    function WaitBefore(const ARequest: TApiCall; const AResponse: TApiReply;
      AAttempt: Integer; out AWaitMs: Integer): Boolean;
  public
    /// ABaseUrl without the trailing '/' (one is removed).
    constructor Create(const ABaseUrl: string; const ATransport: IHttpTransport);
    /// A 2xx answer; EApiError for any other status, EHttpTransport when
    /// there was no answer and no retry left.
    function Execute(const ARequest: TApiCall): TApiReply;
    property BaseUrl: string read FBaseUrl;
    property Credentials: IApiCredentials read FCredentials write FCredentials;
    /// Tries in all for a request that may be retried (1: no retry).
    property MaxAttempts: Integer read FMaxAttempts write FMaxAttempts;
    property BackoffMs: Integer read FBackoffMs write FBackoffMs;
    property MaxRetryAfterMs: Integer read FMaxRetryAfterMs write FMaxRetryAfterMs;
    /// Per try (0: the transport's default).
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    /// How the client waits between tries (tests record it).
    property Sleep: TApiSleepProc read FSleep write FSleep;
  end;

  /// A page of a list as pascal-api-infra-faa writes it: page, limit,
  /// total, totalPages, hasNext, hasPrev, items.
  TApiPageInfo = record
    Page: Integer;
    Limit: Integer;
    Total: Int64;
    TotalPages: Int64;
    HasNext: Boolean;
    HasPrev: Boolean;
  end;

  EApiPageFormat = class(Exception);

/// '?name=value&...' from name/value pairs; a pair whose value is '' is
/// left out; '' when every value is.
function ApiQuery(const ANamesAndValues: array of string): string;
/// The page's numbers in AInfo and its "items" array as JSON text, for the
/// mapper; EApiPageFormat when ABody isn't such a page.
function ReadApiPage(const ABody: string; out AInfo: TApiPageInfo): string;

/// A key for Idempotency-Key: 32 lowercase hex digits, random.
function NewIdempotencyKey: string;
/// A trace id for a user action (W3C: 32 lowercase hex digits).
function NewTraceId: string;
/// A Retry-After in seconds as milliseconds; False for an HTTP date or
/// anything else (the caller's backoff applies then).
function TryRetryAfterMs(const AHeader: string; out AMilliseconds: Integer): Boolean;

implementation

uses
  PascalCommon.TraceContext,
  PascalCommon.Utf8,
  PascalJsonMapper.Json;

function ApiQuery(const ANamesAndValues: array of string): string;
var
  I: Integer;
begin
  if Odd(Length(ANamesAndValues)) then
    raise EArgumentException.Create('ApiQuery: names and values in pairs');
  Result := '';
  I := 0;
  while I < High(ANamesAndValues) do
  begin
    if ANamesAndValues[I + 1] <> '' then
    begin
      if Result = '' then
        Result := '?'
      else
        Result := Result + '&';
      Result := Result + PcPercentEncode(ANamesAndValues[I]) + '=' +
        PcPercentEncode(ANamesAndValues[I + 1]);
    end;
    Inc(I, 2);
  end;
end;

function ReadApiPage(const ABody: string; out AInfo: TApiPageInfo): string;

  function Int(ARoot: TJsonValue; const AName: string): Int64;
  var
    LValue: TJsonValue;
  begin
    LValue := ARoot.Find(AName);
    if (LValue = nil) or (LValue.Kind <> jkNumber) or not LValue.TryAsInt64(Result) then
      raise EApiPageFormat.CreateFmt('a page without a whole "%s"', [AName]);
  end;

  function Bool(ARoot: TJsonValue; const AName: string): Boolean;
  var
    LValue: TJsonValue;
  begin
    LValue := ARoot.Find(AName);
    Result := (LValue <> nil) and (LValue.Kind = jkBoolean) and LValue.AsBoolean;
  end;

var
  LRoot, LItems: TJsonValue;
begin
  try
    LRoot := ParseJson(ABody);
  except
    on E: EJsonError do
      raise EApiPageFormat.Create('a page that isn''t JSON: ' + E.Message);
  end;
  try
    if LRoot.Kind <> jkObject then
      raise EApiPageFormat.Create('a page that isn''t an object');
    LItems := LRoot.Find('items');
    if (LItems = nil) or (LItems.Kind <> jkArray) then
      raise EApiPageFormat.Create('a page without "items"');
    AInfo.Page := Integer(Int(LRoot, 'page'));
    AInfo.Limit := Integer(Int(LRoot, 'limit'));
    AInfo.Total := Int(LRoot, 'total');
    AInfo.TotalPages := Int(LRoot, 'totalPages');
    AInfo.HasNext := Bool(LRoot, 'hasNext');
    AInfo.HasPrev := Bool(LRoot, 'hasPrev');
    Result := LItems.ToJson;
  finally
    LRoot.Free;
  end;
end;

function NewIdempotencyKey: string;
begin
  // A trace id has the shape asked for: 32 hex digits from the OS random source.
  Result := PcNewTraceId;
end;

function NewTraceId: string;
begin
  Result := PcNewTraceId;
end;

function TryRetryAfterMs(const AHeader: string; out AMilliseconds: Integer): Boolean;
var
  LText: string;
  I: Integer;
  LSeconds: Int64;
begin
  AMilliseconds := 0;
  LText := Trim(AHeader);
  if (LText = '') or (Length(LText) > 9) then
    Exit(False);
  for I := 1 to Length(LText) do
    if (LText[I] < '0') or (LText[I] > '9') then
      Exit(False);
  LSeconds := StrToInt64(LText);
  if LSeconds > High(Integer) div 1000 then
    AMilliseconds := High(Integer)
  else
    AMilliseconds := Integer(LSeconds) * 1000;
  Result := True;
end;

{ TApiCall }

class function TApiCall.Create(const AMethod, APath: string): TApiCall;
begin
  Result.Method := AMethod;
  Result.Path := APath;
  Result.Body := '';
  Result.IfMatch := '';
  Result.IdempotencyKey := '';
  Result.TraceId := '';
  Result.Anonymous := False;
  Result.NoRetry := False;
end;

{ TApiReply }

function TApiReply.Header(const AName: string): string;
begin
  FindHttpField(Headers, AName, Result);
end;

function TApiReply.ETag: string;
begin
  Result := Header('ETag');
end;

{ EApiError }

constructor EApiError.CreateFromResponse(const ARequest: TApiCall; const AResponse: TApiReply);
var
  LRoot, LValue, LFields, LItem: TJsonValue;
  LMessage: string;
  I, N: Integer;
begin
  FStatus := AResponse.Status;
  FBody := AResponse.Body;
  FMethod := ARequest.Method;
  FPath := ARequest.Path;
  FCode := '';
  FFields := nil;
  LMessage := '';
  LRoot := nil;
  try
    try
      if Trim(AResponse.Body) <> '' then
        LRoot := ParseJson(AResponse.Body);
    except
      on EJsonError do
        LRoot := nil; // not JSON (a proxy's page): the status alone
    end;
    if (LRoot <> nil) and (LRoot.Kind = jkObject) then
    begin
      LValue := LRoot.Find('error');
      if (LValue <> nil) and (LValue.Kind = jkString) then
        LMessage := LValue.AsString;
      LValue := LRoot.Find('code');
      if (LValue <> nil) and (LValue.Kind = jkString) then
        FCode := LValue.AsString;
      LFields := LRoot.Find('fields');
      if (LFields <> nil) and (LFields.Kind = jkArray) then
        for I := 0 to LFields.Count - 1 do
        begin
          LItem := LFields[I];
          if LItem.Kind <> jkObject then
            Continue;
          N := Length(FFields);
          SetLength(FFields, N + 1);
          LValue := LItem.Find('field');
          if (LValue <> nil) and (LValue.Kind = jkString) then
            FFields[N].Field := LValue.AsString;
          LValue := LItem.Find('code');
          if (LValue <> nil) and (LValue.Kind = jkString) then
            FFields[N].Code := LValue.AsString;
          LValue := LItem.Find('message');
          if (LValue <> nil) and (LValue.Kind = jkString) then
            FFields[N].Message := LValue.AsString;
        end;
    end;
  finally
    LRoot.Free;
  end;
  if LMessage = '' then
    LMessage := Format('%s %s answered %d', [ARequest.Method, ARequest.Path, AResponse.Status]);
  inherited Create(LMessage);
end;

{ TApiHttpClient }

constructor TApiHttpClient.Create(const ABaseUrl: string; const ATransport: IHttpTransport);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
  if (FBaseUrl <> '') and (FBaseUrl[Length(FBaseUrl)] = '/') then
    SetLength(FBaseUrl, Length(FBaseUrl) - 1);
  FTransport := ATransport;
  FMaxAttempts := API_DEFAULT_MAX_ATTEMPTS;
  FBackoffMs := API_DEFAULT_BACKOFF_MS;
  FMaxRetryAfterMs := API_DEFAULT_MAX_RETRY_AFTER_MS;
  FTimeoutMs := 0;
  FSleep := DefaultSleep;
end;

procedure TApiHttpClient.DefaultSleep(AMilliseconds: Integer);
begin
  SysUtils.Sleep(AMilliseconds);
end;

function TApiHttpClient.Exchange(const ARequest: TApiCall;
  const ATraceParent, AToken: string): TApiReply;
var
  LSend: TTransportRequest;
  LAnswer: TTransportResponse;
begin
  LSend := TTransportRequest.Create(ARequest.Method, FBaseUrl + ARequest.Path);
  LSend.TimeoutMs := FTimeoutMs;
  LSend.AddHeader('Accept', 'application/json');
  if ARequest.Body <> '' then
  begin
    LSend.AddHeader('Content-Type', 'application/json; charset=utf-8');
    LSend.Body := ARequest.Body;
  end;
  if AToken <> '' then
    LSend.AddHeader('Authorization', 'Bearer ' + AToken);
  if ARequest.IfMatch <> '' then
    LSend.AddHeader('If-Match', ARequest.IfMatch);
  if ARequest.IdempotencyKey <> '' then
    LSend.AddHeader('Idempotency-Key', ARequest.IdempotencyKey);
  LSend.AddHeader('traceparent', ATraceParent);
  LAnswer := FTransport.Send(LSend);
  Result.Status := LAnswer.Status;
  Result.Body := LAnswer.Body;
  Result.Headers := LAnswer.Headers;
end;

// One try in its client span: a child of AParent, or (none) of the trace
// ATraceId as a root.
function TApiHttpClient.TrySend(const ARequest: TApiCall; const AParent: IPcSpan;
  const ATraceId: string; ASampled: Boolean; AResend: Integer; const AToken: string): TApiReply;
var
  LSpan: IPcSpan;
  LPath: string;
  LQuery: Integer;
begin
  if AParent <> nil then
    LSpan := TPcTracing.StartChildSpan(AParent, UpperCase(ARequest.Method), skClient)
  else
    LSpan := TPcTracing.StartSpanWith(ATraceId, PcNewSpanId, '', '', ASampled,
      UpperCase(ARequest.Method), skClient);
  try
    LPath := ARequest.Path;
    LQuery := Pos('?', LPath);
    if LQuery > 0 then
      LPath := Copy(LPath, 1, LQuery - 1);
    LSpan.SetAttribute('http.request.method', UpperCase(ARequest.Method));
    LSpan.SetAttribute('url.path', LPath);
    if AResend > 0 then
      LSpan.SetIntAttribute('http.request.resend_count', AResend);
    try
      Result := Exchange(ARequest, LSpan.TraceParent, AToken);
    except
      on E: EHttpTransport do
      begin
        LSpan.SetAttribute('error.type', E.ClassName);
        LSpan.SetStatus(ssError, E.Message);
        raise;
      end;
    end;
    LSpan.SetIntAttribute('http.response.status_code', Result.Status);
    if Result.Status >= 400 then
    begin
      LSpan.SetAttribute('error.type', IntToStr(Result.Status));
      LSpan.SetStatus(ssError);
    end;
  finally
    // Finished here, on the thread that started it (it was its current span).
    LSpan.Finish;
  end;
end;

function TApiHttpClient.MayRetry(const ARequest: TApiCall): Boolean;
begin
  Result := (not ARequest.NoRetry) and (SameText(ARequest.Method, 'GET') or
    SameText(ARequest.Method, 'HEAD') or (ARequest.IdempotencyKey <> ''));
end;

// Whether a try that got AResponse (Status 0: no answer) goes again, and
// after how long. AAttempt: the tries made so far.
function TApiHttpClient.WaitBefore(const ARequest: TApiCall;
  const AResponse: TApiReply; AAttempt: Integer; out AWaitMs: Integer): Boolean;
var
  LInFlight: Boolean;
  LRetryAfter: Integer;
  LCode: string;
  LError: EApiError;
begin
  AWaitMs := 0;
  if (AAttempt >= FMaxAttempts) or not MayRetry(ARequest) then
    Exit(False);
  LInFlight := False;
  if (AResponse.Status = 409) and (ARequest.IdempotencyKey <> '') then
  begin
    LError := EApiError.CreateFromResponse(ARequest, AResponse);
    try
      LCode := LError.Code;
    finally
      LError.Free;
    end;
    LInFlight := LCode = API_CODE_KEY_IN_FLIGHT;
  end;
  case AResponse.Status of
    0, 429, 502, 503, 504: ;
  else
    if not LInFlight then
      Exit(False);
  end;
  AWaitMs := FBackoffMs shl (AAttempt - 1);
  if (AResponse.Status <> 0) and TryRetryAfterMs(AResponse.Header('Retry-After'), LRetryAfter) then
  begin
    if LRetryAfter > FMaxRetryAfterMs then
      Exit(False);
    AWaitMs := LRetryAfter;
  end;
  Result := True;
end;

function TApiHttpClient.Execute(const ARequest: TApiCall): TApiReply;
var
  LTraceId, LToken: string;
  LParent: IPcSpan;
  LSampled: Boolean;
  LAttempt, LWaitMs, LSent: Integer;
  LRenewed: Boolean;
begin
  LParent := TPcTracing.Current;
  LTraceId := '';
  LSampled := True;
  if LParent = nil then
  begin
    LTraceId := ARequest.TraceId;
    if LTraceId = '' then
      LTraceId := PcNewTraceId;
    LSampled := TPcTracing.ShouldSample(LTraceId);
  end;
  LRenewed := False;
  LAttempt := 0;
  LSent := 0;
  while True do
  begin
    Inc(LAttempt);
    LToken := '';
    if (not ARequest.Anonymous) and (FCredentials <> nil) then
      LToken := FCredentials.AccessToken;
    try
      Inc(LSent);
      Result := TrySend(ARequest, LParent, LTraceId, LSampled, LSent - 1, LToken);
    except
      on EHttpTransport do
      begin
        Result.Status := 0;
        Result.Body := '';
        Result.Headers := nil;
        if not WaitBefore(ARequest, Result, LAttempt, LWaitMs) then
          raise;
        FSleep(LWaitMs);
        Continue;
      end;
    end;
    if (Result.Status >= 200) and (Result.Status < 300) then
      Exit;
    if (Result.Status = 401) and (LToken <> '') and not LRenewed then
    begin
      LRenewed := True;
      if FCredentials.Renew(LToken) then
      begin
        Dec(LAttempt); // the token's renewal isn't a retry
        Continue;
      end;
    end;
    if not WaitBefore(ARequest, Result, LAttempt, LWaitMs) then
      raise EApiError.CreateFromResponse(ARequest, Result);
    FSleep(LWaitMs);
  end;
end;

end.
