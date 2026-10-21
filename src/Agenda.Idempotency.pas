unit Agenda.Idempotency;

{$I agenda.inc}

(* Idempotency-Key: a client that retries a POST with the same key gets the
  first answer again instead of a second effect (the IETF draft
  "The Idempotency-Key HTTP Header Field").

  - A key belongs to a scope (the tenant) and to one request: a fingerprint,
    the SHA-256 of the method, the path and the body. The same key with
    another request is a 422 (idempotency_key_reused).
  - The first request claims the key and runs; a second one arriving while
    it runs is a 409 (idempotency_key_in_flight), never a second run. A
    claim is a lease (30 seconds by default): a request that died without
    finishing leaves a key the next retry takes over.
  - When it ends, the answer is stored: a success, and a client error
    exactly as the error handler sends it (status, code, fields), so the
    same request keeps getting the same answer. Anything else (a server
    error, a lost connection to the database) releases the key: a retry
    runs again. Stored answers expire (24 hours by default); an expired key
    is a new one.
  - The key is 1 to 255 visible ASCII characters, bare or as a structured
    field string in quotes ("..."); anything else is a 400
    (invalid_idempotency_key).

  The store is an interface (memory, database), the same shape as
  pascal-api-infra-faa's refresh-token and JWT-key stores. Not atomic with
  the request's own transaction: a process that dies after the request
  committed and before the answer was stored runs it again on the retry
  (the booking then finds its slot taken, a 409).

  A library candidate (PascalApi.Idempotency, docs/design.md): no Horse,
  written under the libraries' rules. *)

interface

uses
  SysUtils,
  SyncObjs,
  PascalDb.Interfaces;

const
  CODE_INVALID_IDEMPOTENCY_KEY = 'invalid_idempotency_key';
  CODE_IDEMPOTENCY_KEY_IN_FLIGHT = 'idempotency_key_in_flight';
  CODE_IDEMPOTENCY_KEY_REUSED = 'idempotency_key_reused';
  IDEMPOTENCY_MAX_KEY_CHARS = 255;
  IDEMPOTENCY_DEFAULT_TTL_SECONDS = 86400;
  IDEMPOTENCY_DEFAULT_LEASE_SECONDS = 30;

type
  TIdempotencyClaim = (
    icProceed,  // claimed (new, or a lease that ran out): run the request
    icReplay,   // finished: AResponse is the answer
    icInFlight, // another request with this key is running
    icMismatch  // the key was used for another request
  );

  /// An answer as it is replayed. Headers: "Name: value" lines, #10 between.
  TStoredResponse = record
    Status: Integer;
    Headers: string;
    Body: string;
  end;

  IIdempotencyStore = interface
    ['{5B2B8E77-0E59-4F8A-9C61-3D7A2E4F1B90}']
    /// Atomic. An expired key counts as absent.
    function Claim(const AScope, AKey, AFingerprint: string; ANow, ALeaseUntil,
      AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
    procedure Complete(const AScope, AKey: string; const AResponse: TStoredResponse);
    /// Forgets a claimed key that has no answer.
    procedure Release(const AScope, AKey: string);
  end;

  TMemoryIdempotencyStore = class(TInterfacedObject, IIdempotencyStore)
  private type
    TEntry = record
      Scope, Key, Fingerprint: string;
      Done: Boolean;
      LeaseUntil, ExpiresAt: Int64;
      Response: TStoredResponse;
    end;
  private
    FLock: TCriticalSection;
    FEntries: array of TEntry;
    function IndexOfLocked(const AScope, AKey: string): Integer;
    procedure DeleteLocked(AIndex: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    function Claim(const AScope, AKey, AFingerprint: string; ANow, ALeaseUntil,
      AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
    procedure Complete(const AScope, AKey: string; const AResponse: TStoredResponse);
    procedure Release(const AScope, AKey: string);
  end;

  /// The keys in a table, by named SQL (TENANT_ID, IDEM_KEY, FINGERPRINT,
  /// DONE, LEASE_UNTIL, EXPIRES_AT, STATUS_CODE, RESPONSE_HEADERS,
  /// RESPONSE_BODY; Agenda.Schema's IDEMPOTENCY.*). The claim is one
  /// transaction whose first statement is a write: the scope's expired keys
  /// deleted, then an INSERT that does nothing when the key exists.
  TDbIdempotencyStore = class(TInterfacedObject, IIdempotencyStore)
  private
    FFactory: IDBFactory;
  public
    constructor Create(const AFactory: IDBFactory);
    function Claim(const AScope, AKey, AFingerprint: string; ANow, ALeaseUntil,
      AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
    procedure Complete(const AScope, AKey: string; const AResponse: TStoredResponse);
    procedure Release(const AScope, AKey: string);
  end;

  /// The policy over a store.
  TIdempotency = class
  private
    FStore: IIdempotencyStore;
    FTtlSeconds, FLeaseSeconds: Int64;
  public
    constructor Create(const AStore: IIdempotencyStore;
      ATtlSeconds: Int64 = IDEMPOTENCY_DEFAULT_TTL_SECONDS;
      ALeaseSeconds: Int64 = IDEMPOTENCY_DEFAULT_LEASE_SECONDS);
    /// AKey as the header came, already known not to be blank. True: replay
    /// AResponse. False: run the request, then Complete or Fail with the
    /// key Start returned in AKey (unquoted). EHttpException: 400 invalid,
    /// 409 in flight, 422 another request.
    function Start(const AScope: string; var AKey: string; const AFingerprint: string;
      ANow: Int64; out AResponse: TStoredResponse): Boolean;
    procedure Complete(const AScope, AKey: string; AStatus: Integer;
      const AHeaders, ABody: string);
    /// After the request raised E: a client error (one the error handler
    /// doesn't log) is stored as the handler answers it; anything else
    /// releases the key. Never raises (the caller re-raises E).
    procedure Fail(const AScope, AKey: string; E: Exception; const AMethod, APath: string);
  end;

/// The key without its quotes, or '' when it isn't one.
function NormalizeIdempotencyKey(const AHeader: string): string;

/// Lower-case hex SHA-256 of "<method> <path>" #10 <body> (UTF-8).
function RequestFingerprint(const AMethod, APath, ABody: string): string;

implementation

uses
  PascalCommon.Crypto,
  PascalCommon.Utf8,
  PascalApi.Http;

function NormalizeIdempotencyKey(const AHeader: string): string;
var
  LKey: string;
  I: Integer;
begin
  Result := '';
  LKey := Trim(AHeader);
  if (Length(LKey) >= 2) and (LKey[1] = '"') and (LKey[Length(LKey)] = '"') then
    LKey := Copy(LKey, 2, Length(LKey) - 2);
  if (LKey = '') or (Length(LKey) > IDEMPOTENCY_MAX_KEY_CHARS) then
    Exit;
  // Visible ASCII; no quote or backslash (a structured string's escapes).
  for I := 1 to Length(LKey) do
    if (LKey[I] < #$21) or (LKey[I] > #$7E) or (LKey[I] = '"') or (LKey[I] = '\') then
      Exit;
  Result := LKey;
end;

function RequestFingerprint(const AMethod, APath, ABody: string): string;
begin
  Result := LowerCase(PcBytesToHex(PcDigestToBytes(PcSha256(
    PcStringToUtf8Bytes(AMethod + ' ' + APath + #10 + ABody)))));
end;

{ TMemoryIdempotencyStore }

constructor TMemoryIdempotencyStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
end;

destructor TMemoryIdempotencyStore.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TMemoryIdempotencyStore.IndexOfLocked(const AScope, AKey: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(FEntries) do
    if (FEntries[I].Scope = AScope) and (FEntries[I].Key = AKey) then
      Exit(I);
end;

procedure TMemoryIdempotencyStore.DeleteLocked(AIndex: Integer);
var
  I: Integer;
begin
  for I := AIndex to High(FEntries) - 1 do
    FEntries[I] := FEntries[I + 1];
  SetLength(FEntries, Length(FEntries) - 1);
end;

function TMemoryIdempotencyStore.Claim(const AScope, AKey, AFingerprint: string;
  ANow, ALeaseUntil, AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
var
  I: Integer;
begin
  AResponse.Status := 0;
  AResponse.Headers := '';
  AResponse.Body := '';
  FLock.Acquire;
  try
    I := IndexOfLocked(AScope, AKey);
    if (I >= 0) and (FEntries[I].ExpiresAt <= ANow) then
    begin
      DeleteLocked(I);
      I := -1;
    end;
    if I < 0 then
    begin
      I := Length(FEntries);
      SetLength(FEntries, I + 1);
      FEntries[I].Scope := AScope;
      FEntries[I].Key := AKey;
      FEntries[I].Fingerprint := AFingerprint;
      FEntries[I].Done := False;
      FEntries[I].LeaseUntil := ALeaseUntil;
      FEntries[I].ExpiresAt := AExpiresAt;
      Exit(icProceed);
    end;
    if FEntries[I].Fingerprint <> AFingerprint then
      Exit(icMismatch);
    if FEntries[I].Done then
    begin
      AResponse := FEntries[I].Response;
      Exit(icReplay);
    end;
    if FEntries[I].LeaseUntil > ANow then
      Exit(icInFlight);
    FEntries[I].LeaseUntil := ALeaseUntil;
    Result := icProceed;
  finally
    FLock.Release;
  end;
end;

procedure TMemoryIdempotencyStore.Complete(const AScope, AKey: string;
  const AResponse: TStoredResponse);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    I := IndexOfLocked(AScope, AKey);
    if I >= 0 then
    begin
      FEntries[I].Done := True;
      FEntries[I].Response := AResponse;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TMemoryIdempotencyStore.Release(const AScope, AKey: string);
var
  I: Integer;
begin
  FLock.Acquire;
  try
    I := IndexOfLocked(AScope, AKey);
    if (I >= 0) and not FEntries[I].Done then
      DeleteLocked(I);
  finally
    FLock.Release;
  end;
end;

{ TDbIdempotencyStore }

constructor TDbIdempotencyStore.Create(const AFactory: IDBFactory);
begin
  inherited Create;
  FFactory := AFactory;
end;

function TDbIdempotencyStore.Claim(const AScope, AKey, AFingerprint: string;
  ANow, ALeaseUntil, AExpiresAt: Int64; out AResponse: TStoredResponse): TIdempotencyClaim;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
  LResult: IQueryResult;
begin
  AResponse.Status := 0;
  AResponse.Headers := '';
  AResponse.Body := '';
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['IDEMPOTENCY.PURGE'].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Int64s['NOW'] := ANow;
    LQuery.ExecSql;
    LQuery.Sql := FFactory.SqlLoader['IDEMPOTENCY.CLAIM'].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings['IDEM_KEY'] := AKey;
    LQuery.Params.Strings['FINGERPRINT'] := AFingerprint;
    LQuery.Params.Int64s['LEASE_UNTIL'] := ALeaseUntil;
    LQuery.Params.Int64s['EXPIRES_AT'] := AExpiresAt;
    LQuery.Params.Int64s['CREATED_AT'] := ANow;
    if LQuery.ExecSql = 1 then
      Result := icProceed
    else
    begin
      LQuery.Sql := FFactory.SqlLoader['IDEMPOTENCY.BY_KEY'].SQL;
      LQuery.Params.Strings['TENANT_ID'] := AScope;
      LQuery.Params.Strings['IDEM_KEY'] := AKey;
      LResult := LQuery.Open;
      if LResult.Eof then
        Result := icInFlight // released between the two statements: retry later
      else if LResult.Strings['FINGERPRINT'] <> AFingerprint then
        Result := icMismatch
      else if LResult.Integers['DONE'] <> 0 then
      begin
        AResponse.Status := LResult.Integers['STATUS_CODE'];
        AResponse.Headers := LResult.Strings['RESPONSE_HEADERS'];
        AResponse.Body := LResult.Strings['RESPONSE_BODY'];
        Result := icReplay;
      end
      else if LResult.Int64s['LEASE_UNTIL'] > ANow then
        Result := icInFlight
      else
      begin
        // A lease that ran out: taken over by one request only.
        LQuery.Sql := FFactory.SqlLoader['IDEMPOTENCY.TAKE_OVER'].SQL;
        LQuery.Params.Strings['TENANT_ID'] := AScope;
        LQuery.Params.Strings['IDEM_KEY'] := AKey;
        LQuery.Params.Int64s['LEASE_UNTIL'] := ALeaseUntil;
        LQuery.Params.Int64s['NOW'] := ANow;
        if LQuery.ExecSql = 1 then
          Result := icProceed
        else
          Result := icInFlight;
      end;
    end;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TDbIdempotencyStore.Complete(const AScope, AKey: string;
  const AResponse: TStoredResponse);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['IDEMPOTENCY.COMPLETE'].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings['IDEM_KEY'] := AKey;
    LQuery.Params.Integers['STATUS_CODE'] := AResponse.Status;
    LQuery.Params.Strings['RESPONSE_HEADERS'] := AResponse.Headers;
    LQuery.Params.Strings['RESPONSE_BODY'] := AResponse.Body;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TDbIdempotencyStore.Release(const AScope, AKey: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader['IDEMPOTENCY.RELEASE'].SQL;
    LQuery.Params.Strings['TENANT_ID'] := AScope;
    LQuery.Params.Strings['IDEM_KEY'] := AKey;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

{ TIdempotency }

constructor TIdempotency.Create(const AStore: IIdempotencyStore;
  ATtlSeconds, ALeaseSeconds: Int64);
begin
  inherited Create;
  FStore := AStore;
  FTtlSeconds := ATtlSeconds;
  FLeaseSeconds := ALeaseSeconds;
end;

function TIdempotency.Start(const AScope: string; var AKey: string;
  const AFingerprint: string; ANow: Int64; out AResponse: TStoredResponse): Boolean;
var
  LKey: string;
begin
  LKey := NormalizeIdempotencyKey(AKey);
  if LKey = '' then
    raise EHttpException.Create(400, Format('Idempotency-Key must be 1 to %d visible ASCII ' +
      'characters, such as a UUID.', [IDEMPOTENCY_MAX_KEY_CHARS]), CODE_INVALID_IDEMPOTENCY_KEY);
  AKey := LKey;
  case FStore.Claim(AScope, LKey, AFingerprint, ANow, ANow + FLeaseSeconds,
    ANow + FTtlSeconds, AResponse) of
    icReplay:
      Result := True;
    icInFlight:
      raise EHttpException.Create(409, 'A request with this Idempotency-Key is still running: ' +
        'retry in a moment.', CODE_IDEMPOTENCY_KEY_IN_FLIGHT);
    icMismatch:
      raise EHttpException.Create(422, 'This Idempotency-Key was used for another request: ' +
        'use a new key for a new request.', CODE_IDEMPOTENCY_KEY_REUSED);
  else
    Result := False;
  end;
end;

procedure TIdempotency.Complete(const AScope, AKey: string; AStatus: Integer;
  const AHeaders, ABody: string);
var
  LResponse: TStoredResponse;
begin
  LResponse.Status := AStatus;
  LResponse.Headers := AHeaders;
  LResponse.Body := ABody;
  FStore.Complete(AScope, AKey, LResponse);
end;

procedure TIdempotency.Fail(const AScope, AKey: string; E: Exception;
  const AMethod, APath: string);
var
  LError: TErrorResponse;
begin
  try
    LError := MapException(E, AMethod, APath);
    if LError.LogLine = '' then
      Complete(AScope, AKey, LError.Status, '',
        ErrorJson(LError.Message, '', LError.Code, LError.Fields))
    else
      FStore.Release(AScope, AKey);
  except
    // The original error matters more; an unreleased key frees itself when
    // its lease runs out.
  end;
end;

end.
