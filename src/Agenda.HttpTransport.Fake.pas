unit Agenda.HttpTransport.Fake;

{$I agenda.inc}

{ An IHttpTransport for tests: it answers from a queue the test fills
  (Answer, Fail) and keeps every request it was given (Requests), so a test
  checks what the client sent and how it read each answer, with no server.

  Thread-safe: the client's refresh is checked with several calls at once.
  A Send with the queue empty raises EFakeHttpTransport, not
  EHttpTransport: a request the test didn't expect is the test's failure,
  not a lost connection for the client to retry.

  Hold it through an IHttpTransport variable as well as the class one (it is
  reference counted), and give the IHttpTransport to the client.

  Goes with Agenda.HttpTransport (the same library candidate). }

interface

uses
  SysUtils,
  SyncObjs,
  Agenda.HttpTransport;

type
  EFakeHttpTransport = class(Exception);

  TFakeHttpTransport = class(TInterfacedObject, IHttpTransport)
  private type
    TQueued = record
      Fails: Boolean;
      Response: TTransportResponse;
      Message: string;
    end;
  private
    FLock: TCriticalSection;
    FQueue: TArray<TQueued>;
    FRequests: TArray<TTransportRequest>;
    procedure Push(const AQueued: TQueued);
  public
    constructor Create;
    destructor Destroy; override;
    /// Queues an answer; AHeaders as 'Name: value' lines.
    procedure Answer(AStatus: Integer; const ABody: string;
      const AHeaders: array of string); overload;
    procedure Answer(AStatus: Integer; const ABody: string = ''); overload;
    /// Queues a lost connection: that Send raises EHttpTransport(AMessage).
    procedure Fail(const AMessage: string = 'connection refused');
    /// Answers queued and not yet given.
    function Pending: Integer;
    function RequestCount: Integer;
    /// A copy of the requests, in the order received.
    function Requests: TArray<TTransportRequest>;
    /// The I-th request (from 0); raises EFakeHttpTransport past the last.
    function Request(AIndex: Integer): TTransportRequest;
    function Send(const ARequest: TTransportRequest): TTransportResponse;
  end;

implementation

constructor TFakeHttpTransport.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TFakeHttpTransport.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TFakeHttpTransport.Push(const AQueued: TQueued);
var
  N: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FQueue);
    SetLength(FQueue, N + 1);
    FQueue[N] := AQueued;
  finally
    FLock.Release;
  end;
end;

procedure TFakeHttpTransport.Answer(AStatus: Integer; const ABody: string;
  const AHeaders: array of string);
var
  LQueued: TQueued;
  I, N: Integer;
begin
  LQueued.Fails := False;
  LQueued.Message := '';
  LQueued.Response.Status := AStatus;
  LQueued.Response.Body := ABody;
  LQueued.Response.Headers := nil;
  for I := 0 to High(AHeaders) do
  begin
    N := Length(LQueued.Response.Headers);
    SetLength(LQueued.Response.Headers, N + 1);
    if not SplitHttpHeaderLine(AHeaders[I], LQueued.Response.Headers[N]) then
      raise EFakeHttpTransport.CreateFmt('not a header line: "%s"', [AHeaders[I]]);
  end;
  Push(LQueued);
end;

procedure TFakeHttpTransport.Answer(AStatus: Integer; const ABody: string);
begin
  Answer(AStatus, ABody, []);
end;

procedure TFakeHttpTransport.Fail(const AMessage: string);
var
  LQueued: TQueued;
begin
  LQueued.Fails := True;
  LQueued.Message := AMessage;
  LQueued.Response.Status := 0;
  LQueued.Response.Body := '';
  LQueued.Response.Headers := nil;
  Push(LQueued);
end;

function TFakeHttpTransport.Pending: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FQueue);
  finally
    FLock.Release;
  end;
end;

function TFakeHttpTransport.RequestCount: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FRequests);
  finally
    FLock.Release;
  end;
end;

function TFakeHttpTransport.Requests: TArray<TTransportRequest>;
begin
  FLock.Acquire;
  try
    Result := Copy(FRequests, 0, Length(FRequests));
  finally
    FLock.Release;
  end;
end;

function TFakeHttpTransport.Request(AIndex: Integer): TTransportRequest;
begin
  FLock.Acquire;
  try
    if (AIndex < 0) or (AIndex >= Length(FRequests)) then
      raise EFakeHttpTransport.CreateFmt('no request %d (%d received)',
        [AIndex, Length(FRequests)]);
    Result := FRequests[AIndex];
  finally
    FLock.Release;
  end;
end;

function TFakeHttpTransport.Send(const ARequest: TTransportRequest): TTransportResponse;
var
  LQueued: TQueued;
  N: Integer;
begin
  FLock.Acquire;
  try
    N := Length(FRequests);
    SetLength(FRequests, N + 1);
    FRequests[N] := ARequest;
    if Length(FQueue) = 0 then
      raise EFakeHttpTransport.CreateFmt('%s %s: no answer queued', [ARequest.Method, ARequest.Url]);
    LQueued := FQueue[0];
    Delete(FQueue, 0, 1);
  finally
    FLock.Release;
  end;
  if LQueued.Fails then
    raise EHttpTransport.Create(LQueued.Message);
  Result := LQueued.Response;
end;

end.
