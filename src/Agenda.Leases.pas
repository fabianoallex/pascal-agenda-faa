unit Agenda.Leases;

{$I agenda.inc}

{ A scheduler's lease: one process at a time runs a job's pass (docs/design.md,
  M4 decision 3). One interface, two stores, as the idempotency store has:

  - TDbSchedulerLease: a row of SCHEDULER_LEASES (job, owner, until), the
    default; it works on SQLite with no Redis. Taking it is one transaction:
    an UPDATE that succeeds when the row is the owner's or ran out, else an
    INSERT ... ON CONFLICT DO NOTHING for a job with no row yet (the same
    statement on SQLite 3.24+ and PostgreSQL). Two processes at once: one
    UPDATE or INSERT matches, the other matches nothing.
  - TRedisSchedulerLease: pascal-redis-faa's TRedisLock, a key per job with
    a TTL; held again by the same owner through Extend. Redis down: not
    held (the pass waits for the next one), reported by the lock's
    OnUnavailable.

  The lease keeps two workers from scanning together; it is not what makes
  a reminder go once (the appointment's conditional UPDATE is). A lease that
  runs out mid-pass lets another process start a pass: harmless for that
  reason, only wasted work.

  A library candidate (docs/design.md, "Scheduler with a lease"): its SQL is
  Agenda.Schema's LEASE.* statements, named by the constants below. }

interface

uses
  PascalDb.Interfaces,
  Redis.Lock;

const
  LEASE_SQL_TAKE = 'LEASE.TAKE';
  LEASE_SQL_INSERT = 'LEASE.INSERT';
  LEASE_SQL_RELEASE = 'LEASE.RELEASE';

type
  ISchedulerLease = interface
    ['{5D3A1F7C-8E29-4B60-A4C1-2F9E7B0D6385}']
    /// True when this process holds AJob for ASeconds from ANow (Unix
    /// seconds): it was free, ran out, or was this process's already (then
    /// renewed). False when another process holds it.
    function TryAcquire(const AJob: string; ASeconds: Integer; ANow: Int64): Boolean;
    /// Gives AJob up when this process still holds it.
    procedure Release(const AJob: string);
  end;

  TDbSchedulerLease = class(TInterfacedObject, ISchedulerLease)
  private
    FFactory: IDBFactory;
    FOwner: string;
  public
    /// AOwner: unique per process (PdbOutboxNewOwner's kind of name).
    constructor Create(const AFactory: IDBFactory; const AOwner: string);
    function TryAcquire(const AJob: string; ASeconds: Integer; ANow: Int64): Boolean;
    procedure Release(const AJob: string);
    property Owner: string read FOwner;
  end;

  TRedisSchedulerLease = class(TInterfacedObject, ISchedulerLease)
  private type
    THeld = record
      Job: string;
      Token: string;
    end;
  private
    FLock: TRedisLock;
    FHeld: array of THeld;
    function IndexOf(const AJob: string): Integer;
    procedure Forget(AIndex: Integer);
  public
    /// ALock is not owned. One instance per process, used from one thread.
    constructor Create(ALock: TRedisLock);
    function TryAcquire(const AJob: string; ASeconds: Integer; ANow: Int64): Boolean;
    procedure Release(const AJob: string);
  end;

implementation

uses
  SysUtils;

{ TDbSchedulerLease }

constructor TDbSchedulerLease.Create(const AFactory: IDBFactory; const AOwner: string);
begin
  inherited Create;
  FFactory := AFactory;
  FOwner := AOwner;
end;

function TDbSchedulerLease.TryAcquire(const AJob: string; ASeconds: Integer;
  ANow: Int64): Boolean;
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[LEASE_SQL_TAKE].SQL;
    LQuery.Params.Strings['JOB'] := AJob;
    LQuery.Params.Strings['OWNER'] := FOwner;
    LQuery.Params.Int64s['LEASE_UNTIL'] := ANow + ASeconds;
    LQuery.Params.Int64s['NOW'] := ANow;
    Result := LQuery.ExecSql > 0;
    if not Result then
    begin
      LQuery.Sql := FFactory.SqlLoader[LEASE_SQL_INSERT].SQL;
      LQuery.Params.Strings['JOB'] := AJob;
      LQuery.Params.Strings['OWNER'] := FOwner;
      LQuery.Params.Int64s['LEASE_UNTIL'] := ANow + ASeconds;
      Result := LQuery.ExecSql > 0;
    end;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

procedure TDbSchedulerLease.Release(const AJob: string);
var
  LQuery: IQuery;
  LTx: IScopeTransaction;
begin
  LTx := FFactory.GetPool.AcquireQuery(LQuery);
  LTx.StartTransaction;
  try
    LQuery.Sql := FFactory.SqlLoader[LEASE_SQL_RELEASE].SQL;
    LQuery.Params.Strings['JOB'] := AJob;
    LQuery.Params.Strings['OWNER'] := FOwner;
    LQuery.ExecSql;
    LTx.Commit;
  except
    LTx.Rollback;
    raise;
  end;
end;

{ TRedisSchedulerLease }

constructor TRedisSchedulerLease.Create(ALock: TRedisLock);
begin
  inherited Create;
  FLock := ALock;
end;

function TRedisSchedulerLease.IndexOf(const AJob: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FHeld) do
    if FHeld[I].Job = AJob then
      Exit(I);
  Result := -1;
end;

procedure TRedisSchedulerLease.Forget(AIndex: Integer);
begin
  FHeld[AIndex] := FHeld[High(FHeld)];
  SetLength(FHeld, Length(FHeld) - 1);
end;

function TRedisSchedulerLease.TryAcquire(const AJob: string; ASeconds: Integer;
  ANow: Int64): Boolean;
var
  LIndex: Integer;
  LToken: string;
begin
  // Redis keeps its own clock: ANow isn't needed here.
  LIndex := IndexOf(AJob);
  if LIndex >= 0 then
  begin
    if FLock.Extend(AJob, FHeld[LIndex].Token, ASeconds * 1000) then
      Exit(True);
    // Ran out (or Redis didn't answer): take it anew below.
    Forget(LIndex);
  end;
  Result := FLock.Acquire(AJob, ASeconds * 1000, LToken) = rlAcquired;
  if Result then
  begin
    SetLength(FHeld, Length(FHeld) + 1);
    FHeld[High(FHeld)].Job := AJob;
    FHeld[High(FHeld)].Token := LToken;
  end;
end;

procedure TRedisSchedulerLease.Release(const AJob: string);
var
  LIndex: Integer;
begin
  LIndex := IndexOf(AJob);
  if LIndex < 0 then
    Exit;
  FLock.Release(AJob, FHeld[LIndex].Token);
  Forget(LIndex);
end;

end.
