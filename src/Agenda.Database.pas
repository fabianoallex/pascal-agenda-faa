unit Agenda.Database;

{$I agenda.inc}

{ Opening the database and bringing it to the latest migration.

  SQLite in development: SQLdb on FPC, FireDAC on Delphi (pascal-db-faa's
  adapters). On FPC the SQLite library is SQLITE_CLIENT, by default
  libsqlite3.so.0 on Linux and the sqlite3.dll next to the executable on
  Windows, which must be sqlite.org's build (pascal-db-faa gotcha 23:
  Python's lacks the column metadata functions).

  PostgreSQL (docker compose) comes with its own SqlSource directory when the
  schema has more than the catalog. }

interface

uses
  PascalDb.Interfaces,
  PascalDb.Migrations;

type
  /// The database of the process: one factory (one pool), opened once.
  TAgendaDatabase = class
  private
    FFactory: IDBFactory;
    FVersion: Integer;
  public
    /// Opens (creates) the SQLite file AFile. Nothing is migrated yet.
    constructor Create(const AFile: string);
    /// Runs the pending migrations; AOnEvent sees each one.
    procedure Migrate(const AOnEvent: TMigrationEventProc);
    /// A pooled connection answers a query. Raises when the database can't
    /// be reached (the readiness endpoint counts that as a failure).
    function Ready: Boolean;
    property Factory: IDBFactory read FFactory;
    /// The schema version after Migrate.
    property Version: Integer read FVersion;
  end;

implementation

uses
  PascalDb.Adapter.Base,
  {$IFDEF FPC}
  PascalDb.Adapter.SQLdb,
  {$ELSE}
  PascalDb.Adapter.FireDAC,
  {$ENDIF}
  PascalApi.Config,
  Agenda.Schema;

constructor TAgendaDatabase.Create(const AFile: string);
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (pascal-db-faa's rule)
begin
  inherited Create;
  LConfig := TDatabaseConfig.Create;
  {$IFDEF FPC}
  LConfig.ConnectionParams.Values['ConnectorType'] := 'SQLite3';
  LConfig.ConnectionParams.Values['DatabaseName'] := AFile;
  {$IFDEF UNIX}
  LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', 'libsqlite3.so.0');
  {$ELSE}
  LConfig.ConnectionParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', '');
  {$ENDIF}
  {$ELSE}
  LConfig.ConnectionParams.Values['DriverID'] := 'SQLite';
  LConfig.ConnectionParams.Values['Database'] := AFile;
  {$ENDIF}
  LConfig.SQLDialect := 'SQLite';
  LConfig.SQLDirectory := SQLITE_DIR;
  LConfig.SqlSource := AgendaSqlSource;
  LConfig.PoolName := 'agenda';
  LConfig.PoolIniConnections := 1;
  LConfig.PoolMaxConnections := TAppConfig.GetInt('DB_POOL_MAX', 10);
  LConfig.PoolWaitMaxAttemps := 50;
  LConfig.PoolWaitMilliseconds := 100;
  {$IFDEF FPC}
  FFactory := TSQLdbFactory.Create(LConfig);
  {$ELSE}
  FFactory := TFDFactory.Create(LConfig);
  {$ENDIF}
end;

procedure TAgendaDatabase.Migrate(const AOnEvent: TMigrationEventProc);
var
  LEngine: TDBMigrationEngine;
begin
  LEngine := TDBMigrationEngine.Create(FFactory, AOnEvent);
  try
    LEngine.Execute(AgendaMigrations);
    FVersion := LEngine.CurrentVersion;
  finally
    LEngine.Free;
  end;
end;

function TAgendaDatabase.Ready: Boolean;
var
  LQuery: IQuery;
  LScope: IScopeTransaction;
begin
  LScope := FFactory.GetPool.AcquireQuery(LQuery);
  LQuery.Sql := FFactory.SqlLoader['HEALTH.PING'].SQL;
  Result := LQuery.Open.RecordCount = 1;
end;

end.
