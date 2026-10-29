unit Agenda.HttpSession;

{$I agenda.inc}

{ The tokens of a logged-in client, as Agenda.HttpClient's IApiCredentials:
  an access token, a refresh token kept in memory only, and the access
  token's end. Decision 6 of "M6: design".

  - One refresh at a time. Renew runs the refresh under a lock; a thread
    that needed a token meanwhile waits on the lock and, finding a token
    other than the one it was refused with, uses it without refreshing. A
    server that rotates refresh tokens with reuse detection (two refreshes
    with the same token revoke the family) never sees the client race
    itself.
  - Renewed before it runs out: AccessToken refreshes first when less than
    the margin is left (RefreshMarginMs, or a quarter of the token's life
    when that is shorter). A refresh that finds no server then (or a 429,
    a 5xx) keeps the old token, still good for a while; a 401 later renews
    again.
  - The refresh itself is the application's (IApiTokenRefresher: which
    route, which body): this unit knows no route.
  - A refresh refused with 401 (the refresh token expired or revoked) ends
    the session: the tokens are forgotten, Lost is True, Renew answers
    False, so the request's 401 reaches the caller (a screen logs in
    again). A lost connection during a Renew raises, as the request would
    have.
  - The time is a monotonic millisecond count (Clock, replaced by the
    tests), never the wall clock: a clock set back doesn't keep a dead
    token.

  A library candidate (docs/design.md, "Library candidates": the typed HTTP
  client). Nothing of this application in it. }

interface

uses
  SysUtils,
  SyncObjs,
  Agenda.HttpClient;

const
  /// Renew when less than this is left (or a quarter of the token's life).
  SESSION_DEFAULT_REFRESH_MARGIN_MS = 60000;

type
  TApiTokens = record
    AccessToken: string;
    RefreshToken: string;
    /// The access token's life from now, in seconds (expiresIn).
    ExpiresInSeconds: Int64;
  end;

  /// Exchanges a refresh token for new tokens; EApiError when refused
  /// (401: the session is over), EHttpTransport when there was no answer.
  IApiTokenRefresher = interface
    ['{C3E1A0B7-2D4F-4B19-8E56-7A9F1C0D3B42}']
    function Refresh(const ARefreshToken: string): TApiTokens;
  end;

  TApiClockFunc = function: Int64 of object;

  TApiSession = class(TInterfacedObject, IApiCredentials)
  private
    FLock: TCriticalSection;
    FRefreshLock: TCriticalSection;
    FRefresher: IApiTokenRefresher;
    FAccessToken: string;
    FRefreshToken: string;
    FRenewAt: Int64;
    FLost: Boolean;
    FRefreshes: Integer;
    FRefreshMarginMs: Integer;
    FClock: TApiClockFunc;
    function SystemClock: Int64;
    procedure Store(const ATokens: TApiTokens);
    // The refresh, under FRefreshLock. AStaleToken: the token found wanting;
    // nothing is done when the current one is already another. AQuiet: a
    // lost connection keeps the old token instead of raising.
    function RefreshFrom(const AStaleToken: string; AQuiet: Boolean): Boolean;
  public
    constructor Create(const ARefresher: IApiTokenRefresher);
    destructor Destroy; override;
    /// The tokens of a login (or of a refresh made elsewhere).
    procedure Start(const ATokens: TApiTokens);
    /// Forgets the tokens (after the logout).
    procedure Clear;
    function AccessToken: string;
    function Renew(const AStaleToken: string): Boolean;
    function RefreshToken: string;
    /// A refresh was refused: log in again.
    function Lost: Boolean;
    /// Refreshes made so far (tests, the screen's status line).
    function Refreshes: Integer;
    property RefreshMarginMs: Integer read FRefreshMarginMs write FRefreshMarginMs;
    property Clock: TApiClockFunc read FClock write FClock;
  end;

implementation

uses
  {$IFNDEF FPC}
  Winapi.Windows,
  {$ENDIF}
  Agenda.HttpTransport;

constructor TApiSession.Create(const ARefresher: IApiTokenRefresher);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRefreshLock := TCriticalSection.Create;
  FRefresher := ARefresher;
  FRefreshMarginMs := SESSION_DEFAULT_REFRESH_MARGIN_MS;
  FClock := SystemClock;
end;

destructor TApiSession.Destroy;
begin
  FRefreshLock.Free;
  FLock.Free;
  inherited;
end;

function TApiSession.SystemClock: Int64;
begin
  Result := Int64(GetTickCount64);
end;

procedure TApiSession.Store(const ATokens: TApiTokens);
var
  LLifeMs, LMarginMs: Int64;
begin
  LLifeMs := ATokens.ExpiresInSeconds * 1000;
  LMarginMs := FRefreshMarginMs;
  if LLifeMs div 4 < LMarginMs then
    LMarginMs := LLifeMs div 4;
  FLock.Acquire;
  try
    FAccessToken := ATokens.AccessToken;
    FRefreshToken := ATokens.RefreshToken;
    FRenewAt := FClock() + LLifeMs - LMarginMs;
    FLost := False;
  finally
    FLock.Release;
  end;
end;

procedure TApiSession.Start(const ATokens: TApiTokens);
begin
  Store(ATokens);
end;

procedure TApiSession.Clear;
begin
  FLock.Acquire;
  try
    FAccessToken := '';
    FRefreshToken := '';
    FRenewAt := 0;
  finally
    FLock.Release;
  end;
end;

function TApiSession.RefreshFrom(const AStaleToken: string; AQuiet: Boolean): Boolean;
var
  LCurrent, LRefreshToken: string;
  LTokens: TApiTokens;
begin
  FRefreshLock.Acquire;
  try
    FLock.Acquire;
    try
      LCurrent := FAccessToken;
      LRefreshToken := FRefreshToken;
    finally
      FLock.Release;
    end;
    // Another thread renewed it while this one waited.
    if (LCurrent <> '') and (LCurrent <> AStaleToken) then
      Exit(True);
    if LRefreshToken = '' then
      Exit(False);
    try
      LTokens := FRefresher.Refresh(LRefreshToken);
    except
      on E: EApiError do
      begin
        if E.Status <> 401 then
        begin
          // A 429 or a 5xx: before the end, the old token goes on.
          if not AQuiet then
            raise;
          Exit(False);
        end;
        FLock.Acquire;
        try
          FAccessToken := '';
          FRefreshToken := '';
          FLost := True;
        finally
          FLock.Release;
        end;
        Exit(False);
      end;
      on EHttpTransport do
      begin
        if not AQuiet then
          raise;
        Exit(False);
      end;
    end;
    Store(LTokens);
    FLock.Acquire;
    try
      Inc(FRefreshes);
    finally
      FLock.Release;
    end;
    Result := True;
  finally
    FRefreshLock.Release;
  end;
end;

function TApiSession.AccessToken: string;
var
  LDue: Boolean;
begin
  FLock.Acquire;
  try
    Result := FAccessToken;
    LDue := (Result <> '') and (FRefreshToken <> '') and (FClock() >= FRenewAt);
  finally
    FLock.Release;
  end;
  if not LDue then
    Exit;
  RefreshFrom(Result, True);
  FLock.Acquire;
  try
    Result := FAccessToken;
  finally
    FLock.Release;
  end;
end;

function TApiSession.Renew(const AStaleToken: string): Boolean;
begin
  Result := RefreshFrom(AStaleToken, False);
end;

function TApiSession.RefreshToken: string;
begin
  FLock.Acquire;
  try
    Result := FRefreshToken;
  finally
    FLock.Release;
  end;
end;

function TApiSession.Lost: Boolean;
begin
  FLock.Acquire;
  try
    Result := FLost;
  finally
    FLock.Release;
  end;
end;

function TApiSession.Refreshes: Integer;
begin
  FLock.Acquire;
  try
    Result := FRefreshes;
  finally
    FLock.Release;
  end;
end;

end.
