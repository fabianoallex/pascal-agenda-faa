unit Agenda.Locks;

{$I agenda.inc}

{ A short lock on one slot, in front of the booking's transaction: two
  requests for the same professional and start meet here, and the second is
  answered at once without reaching the database. The database stays the
  final word (Agenda.Appointments: the professional's row lock and the
  free-slot check); this only saves it the work, so the lock is optional
  (no REDIS_HOST, no lock) and a Redis that can't answer lets the booking
  through to the database.

  TRedisSlotLock is pascal-redis-faa's single-instance lock, as its README
  shows it (not Redlock): SET key token NX PX ttl to take it, and a Lua
  script that deletes the key only while it still holds this caller's token
  to give it back (GET then DEL could delete a lock another request took
  after this one's expired). The token is a random id per acquisition.

  Only a connection failure or a timeout lets the booking through
  (ERedisConnectionLost, ERedisTimeout, ERedisPoolExhausted), logged through
  the callback; any other Redis error is a bug and propagates
  (pascal-api-infra-faa's guide "Messaging", step 6). Keys are logged,
  never tokens. }

interface

uses
  Redis.Client;

type
  TSlotLockLogProc = procedure(const ALine: string) of object;

  ISlotLock = interface
    ['{5815281C-26DA-4725-A8F3-A87805ACA727}']
    /// False only when another caller holds AKey. True with AToken when
    /// this caller holds it for at most ATtlMs; True with AToken '' when the
    /// lock couldn't be asked (the caller goes on without it).
    function TryAcquire(const AKey: string; ATtlMs: Integer; out AToken: string): Boolean;
    /// Gives AKey back if it still holds AToken; nothing for AToken ''.
    procedure Release(const AKey, AToken: string);
  end;

  TRedisSlotLock = class(TInterfacedObject, ISlotLock)
  private
    FClient: TRedisClient;
    FPrefix: string;
    FLog: TSlotLockLogProc;
    procedure Unavailable(const AWhat, AKey: string; E: TObject);
  public
    /// AClient isn't owned (one client for the process). APrefix goes before
    /// every key ('agenda:lock:').
    constructor Create(AClient: TRedisClient; const APrefix: string; ALog: TSlotLockLogProc);
    function TryAcquire(const AKey: string; ATtlMs: Integer; out AToken: string): Boolean;
    procedure Release(const AKey, AToken: string);
  end;

implementation

uses
  SysUtils,
  Redis.Types,
  Redis.Pool,
  Redis.Commands.Strings,
  Agenda.Tokens;

const
  RELEASE_SCRIPT =
    'if redis.call("GET", KEYS[1]) == ARGV[1] then ' +
    'return redis.call("DEL", KEYS[1]) else return 0 end';

constructor TRedisSlotLock.Create(AClient: TRedisClient; const APrefix: string;
  ALog: TSlotLockLogProc);
begin
  inherited Create;
  if AClient = nil then
    raise EArgumentException.Create('TRedisSlotLock: AClient is nil');
  FClient := AClient;
  FPrefix := APrefix;
  FLog := ALog;
end;

procedure TRedisSlotLock.Unavailable(const AWhat, AKey: string; E: TObject);
begin
  if Assigned(FLog) then
    FLog(Format('slot lock unavailable (%s %s), the database decides: %s: %s',
      [AWhat, FPrefix + AKey, E.ClassName, Exception(E).Message]));
end;

function TRedisSlotLock.TryAcquire(const AKey: string; ATtlMs: Integer;
  out AToken: string): Boolean;
var
  LOptions: TRedisSetOptions;
  LToken: string;
begin
  AToken := '';
  LToken := NewId;
  LOptions := RedisDefaultSetOptions;
  LOptions.Condition := scNotExists;
  LOptions.Expiry := seMilliseconds;
  LOptions.ExpiryValue := ATtlMs;
  try
    Result := not FClient.Strings.SetWithOptions(FPrefix + AKey, LToken, LOptions).IsNull;
    if Result then
      AToken := LToken;
  except
    on E: ERedisConnectionLost do
    begin
      Unavailable('acquire', AKey, E);
      Result := True;
    end;
    on E: ERedisTimeout do
    begin
      Unavailable('acquire', AKey, E);
      Result := True;
    end;
    on E: ERedisPoolExhausted do
    begin
      Unavailable('acquire', AKey, E);
      Result := True;
    end;
  end;
end;

procedure TRedisSlotLock.Release(const AKey, AToken: string);
begin
  if AToken = '' then
    Exit;
  // The key expires by itself: a release that fails only keeps the slot
  // locked until then.
  try
    FClient.Scripting.Run(RELEASE_SCRIPT, [FPrefix + AKey], [AToken]);
  except
    on E: ERedisConnectionLost do
      Unavailable('release', AKey, E);
    on E: ERedisTimeout do
      Unavailable('release', AKey, E);
    on E: ERedisPoolExhausted do
      Unavailable('release', AKey, E);
  end;
end;

end.
