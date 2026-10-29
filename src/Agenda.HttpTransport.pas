unit Agenda.HttpTransport;

{$I agenda.inc}

{ One HTTP exchange behind an interface: a method, a URL, headers and a text
  body in; the status, the headers and the text body out. The desktop
  client's typed layer (Agenda.HttpClient) talks to IHttpTransport only, so
  its tests run on a fake (Agenda.HttpTransport.Fake) with no server.

  NewHttpTransport gives each compiler's own client:
  - Delphi: THTTPClient (WinHTTP on Windows: the system's TLS, no OpenSSL to
    ship).
  - FPC: fphttpclient. This unit uses opensslsockets, so an https URL works
    (fphttpclient finds its TLS handler there); OpenSSL is loaded on the
    first https exchange only.
  Both with redirects off and one client per exchange: Send may be called
  from several threads at once.

  Every status is an answer, never an exception: a 401 or a 503 is for the
  caller to read. EHttpTransport means there was no answer (refused,
  unreachable, a timeout, TLS); the request may or may not have reached the
  server, so only the caller knows whether it may send it again.

  Bodies are UTF-8 on the wire. POST, PUT and PATCH always carry a body,
  empty when there is none, so fphttpclient sends "Content-Length: 0" (it
  sends no length at all without one).

  A library candidate (docs/design.md, "Library candidates": the typed HTTP
  client, and this switch between the two clients, its third copy after
  pascal-api-infra-faa's PascalApi.Otlp and MCP executor). Nothing of this
  application in it. }

interface

uses
  SysUtils;

const
  /// A request with TimeoutMs 0 waits this long to connect and as long for
  /// each read.
  HTTP_DEFAULT_TIMEOUT_MS = 15000;

type
  /// A header: name and value as sent or received.
  THttpField = record
    Name: string;
    Value: string;
  end;

  THttpFields = TArray<THttpField>;

  TTransportRequest = record
    Method: string;
    Url: string;
    Headers: THttpFields;
    Body: string;
    /// 0: HTTP_DEFAULT_TIMEOUT_MS.
    TimeoutMs: Integer;
    class function Create(const AMethod, AUrl: string): TTransportRequest; static;
    procedure AddHeader(const AName, AValue: string);
    /// The first header named AName (any case); '' when absent.
    function Header(const AName: string): string;
  end;

  TTransportResponse = record
    Status: Integer;
    Headers: THttpFields;
    Body: string;
    /// The first header named AName (any case); '' when absent.
    function Header(const AName: string): string;
  end;

  /// No answer: refused, unreachable, a timeout, TLS, or an answer that
  /// isn't HTTP.
  EHttpTransport = class(Exception);

  IHttpTransport = interface
    ['{6B0C2E64-3F1D-4C55-9A57-2E7D8F0B9C11}']
    /// Raises EHttpTransport when there was no answer.
    function Send(const ARequest: TTransportRequest): TTransportResponse;
  end;

/// The compiler's own client (see the unit's comment).
function NewHttpTransport: IHttpTransport;

/// The first field named AName (any case).
function FindHttpField(const AFields: THttpFields; const AName: string;
  out AValue: string): Boolean;

/// A header line as fphttpclient keeps it ("Name: value") split at its
/// first colon, both sides trimmed. False for a line without a colon or
/// without a name.
function SplitHttpHeaderLine(const ALine: string; out AField: THttpField): Boolean;

/// POST, PUT and PATCH (any case): the methods that always carry a body.
function HttpMethodHasBody(const AMethod: string): Boolean;

implementation

uses
  Classes,
  {$IFDEF FPC}
  fphttpclient,
  opensslsockets,
  {$ELSE}
  System.Net.HttpClient,
  System.Net.URLClient,
  {$ENDIF}
  PascalCommon.Utf8;

function FindHttpField(const AFields: THttpFields; const AName: string;
  out AValue: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(AFields) do
    if SameText(AFields[I].Name, AName) then
    begin
      AValue := AFields[I].Value;
      Exit(True);
    end;
  AValue := '';
  Result := False;
end;

function SplitHttpHeaderLine(const ALine: string; out AField: THttpField): Boolean;
var
  LColon: Integer;
begin
  LColon := Pos(':', ALine);
  AField.Name := '';
  AField.Value := '';
  if LColon = 0 then
    Exit(False);
  AField.Name := Trim(Copy(ALine, 1, LColon - 1));
  AField.Value := Trim(Copy(ALine, LColon + 1, MaxInt));
  Result := AField.Name <> '';
end;

function HttpMethodHasBody(const AMethod: string): Boolean;
begin
  Result := SameText(AMethod, 'POST') or SameText(AMethod, 'PUT') or SameText(AMethod, 'PATCH');
end;

function TimeoutOf(const ARequest: TTransportRequest): Integer;
begin
  Result := ARequest.TimeoutMs;
  if Result <= 0 then
    Result := HTTP_DEFAULT_TIMEOUT_MS;
end;

function NoAnswer(const ARequest: TTransportRequest; E: Exception): EHttpTransport;
begin
  Result := EHttpTransport.CreateFmt('%s %s: no answer (%s: %s)',
    [ARequest.Method, ARequest.Url, E.ClassName, E.Message]);
end;

{ TTransportRequest }

class function TTransportRequest.Create(const AMethod, AUrl: string): TTransportRequest;
begin
  Result.Method := AMethod;
  Result.Url := AUrl;
  Result.Headers := nil;
  Result.Body := '';
  Result.TimeoutMs := 0;
end;

procedure TTransportRequest.AddHeader(const AName, AValue: string);
var
  N: Integer;
begin
  N := Length(Headers);
  SetLength(Headers, N + 1);
  Headers[N].Name := AName;
  Headers[N].Value := AValue;
end;

function TTransportRequest.Header(const AName: string): string;
begin
  FindHttpField(Headers, AName, Result);
end;

{ TTransportResponse }

function TTransportResponse.Header(const AName: string): string;
begin
  FindHttpField(Headers, AName, Result);
end;

{ the compiler's own client }

type
  TNativeHttpTransport = class(TInterfacedObject, IHttpTransport)
  public
    function Send(const ARequest: TTransportRequest): TTransportResponse;
  end;

{$IFDEF FPC}

function TNativeHttpTransport.Send(const ARequest: TTransportRequest): TTransportResponse;
var
  LClient: TFPHTTPClient;
  LSent: TBytesStream;
  LReceived: TBytesStream;
  LText: string;
  I, N: Integer;
begin
  LClient := TFPHTTPClient.Create(nil);
  LSent := nil;
  LReceived := TBytesStream.Create;
  try
    LClient.ConnectTimeout := TimeoutOf(ARequest);
    LClient.IOTimeout := TimeoutOf(ARequest);
    LClient.AllowRedirect := False;
    for I := 0 to High(ARequest.Headers) do
      LClient.AddHeader(ARequest.Headers[I].Name, ARequest.Headers[I].Value);
    if (ARequest.Body <> '') or HttpMethodHasBody(ARequest.Method) then
    begin
      LSent := TBytesStream.Create(PcStringToUtf8Bytes(ARequest.Body));
      LClient.RequestBody := LSent;
    end;
    try
      // No accepted-status list: every status is an answer.
      LClient.HTTPMethod(ARequest.Method, ARequest.Url, LReceived, []);
    except
      on E: Exception do
        raise NoAnswer(ARequest, E);
    end;
    Result.Status := LClient.ResponseStatusCode;
    Result.Headers := nil;
    for I := 0 to LClient.ResponseHeaders.Count - 1 do
    begin
      N := Length(Result.Headers);
      SetLength(Result.Headers, N + 1);
      if not SplitHttpHeaderLine(LClient.ResponseHeaders[I], Result.Headers[N]) then
        SetLength(Result.Headers, N);
    end;
    if not PcTryUtf8BytesToString(Copy(LReceived.Bytes, 0, LReceived.Size), LText) then
      raise EHttpTransport.CreateFmt('%s %s: the answer has non-ASCII text and the process ' +
        'code page is %d, not UTF-8: call SetMultiByteConversionCodePage(CP_UTF8) at startup',
        [ARequest.Method, ARequest.Url, DefaultSystemCodePage]);
    Result.Body := LText;
  finally
    LClient.RequestBody := nil;
    LReceived.Free;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ELSE}

function TNativeHttpTransport.Send(const ARequest: TTransportRequest): TTransportResponse;
var
  LClient: THTTPClient;
  LRequest: IHTTPRequest;
  LSent: TBytesStream;
  LResponse: IHTTPResponse;
  LHeaders: TNetHeaders;
  I: Integer;
begin
  LClient := THTTPClient.Create;
  LSent := nil;
  try
    LClient.ConnectionTimeout := TimeoutOf(ARequest);
    LClient.ResponseTimeout := TimeoutOf(ARequest);
    LClient.HandleRedirects := False;
    LRequest := LClient.GetRequest(ARequest.Method, ARequest.Url);
    for I := 0 to High(ARequest.Headers) do
      LRequest.SetHeaderValue(ARequest.Headers[I].Name, ARequest.Headers[I].Value);
    if (ARequest.Body <> '') or HttpMethodHasBody(ARequest.Method) then
    begin
      LSent := TBytesStream.Create(PcStringToUtf8Bytes(ARequest.Body));
      LRequest.SourceStream := LSent;
    end;
    try
      LResponse := LClient.Execute(LRequest);
    except
      on E: ENetException do
        raise NoAnswer(ARequest, E);
    end;
    Result.Status := LResponse.StatusCode;
    LHeaders := LResponse.Headers;
    SetLength(Result.Headers, Length(LHeaders));
    for I := 0 to High(LHeaders) do
    begin
      Result.Headers[I].Name := LHeaders[I].Name;
      Result.Headers[I].Value := LHeaders[I].Value;
    end;
    Result.Body := LResponse.ContentAsString(TEncoding.UTF8);
  finally
    // Released before the stream and the client they point to.
    LResponse := nil;
    LRequest := nil;
    LSent.Free;
    LClient.Free;
  end;
end;

{$ENDIF}

function NewHttpTransport: IHttpTransport;
begin
  Result := TNativeHttpTransport.Create;
end;

end.
