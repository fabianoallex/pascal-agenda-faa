unit Agenda.Database;

{$I agenda.inc}

{ Opening the database and bringing it to the latest migration.

  Two engines, chosen by DB_ENGINE, through pascal-db-faa's adapters (SQLdb
  on FPC, FireDAC on Delphi), with the same SQL (Agenda.Schema: the
  engine's directory, SQLITE or PG, then COMMON):
  - sqlite (the default, development): the file DB_FILE (agenda.sqlite next
    to the executable). On FPC the library is SQLITE_CLIENT, by default
    libsqlite3.so.0 on Linux and the sqlite3.dll next to the executable on
    Windows, which must be sqlite.org's build (pascal-db-faa gotcha 23:
    Python's lacks the column metadata functions).
  - postgresql: DB_HOST (localhost), DB_PORT (5432), DB_NAME (agenda),
    DB_USER (postgres), DB_PASSWORD; the database must exist (the
    migrations create the tables, not the database). PG_CLIENT is libpq:
    on Windows the full path of a 64-bit libpq.dll (PostgreSQL ships no
    32-bit client, so a Delphi build for PostgreSQL is Win64); on Linux
    libpq.so.5 is found without it. }

interface

uses
  PascalDb.Interfaces,
  PascalDb.Migrations;

type
  TAgendaEngine = (aeSQLite, aePostgreSQL);

  /// The database of the process: one factory (one pool), opened once.
  TAgendaDatabase = class
  private
    FFactory: IDBFactory;
    FVersion: Integer;
    FEngine: TAgendaEngine;
    FDescription: string;
  public
    /// Opens the database the settings name (SQLite: creates the file).
    /// Nothing is migrated yet.
    constructor Create;
    /// DB_ENGINE: sqlite (default) or postgresql; anything else raises.
    class function ConfiguredEngine: TAgendaEngine; static;
    /// DB_FILE, expanded: the SQLite database.
    class function SQLiteFile: string; static;
    /// Runs the pending migrations; AOnEvent sees each one.
    procedure Migrate(const AOnEvent: TMigrationEventProc);
    /// A pooled connection answers a query. Raises when the database can't
    /// be reached (the readiness endpoint counts that as a failure).
    function Ready: Boolean;
    property Factory: IDBFactory read FFactory;
    property Engine: TAgendaEngine read FEngine;
    /// For the log: "sqlite <file>" or "postgresql <host>:<port>/<name>".
    property Description: string read FDescription;
    /// The schema version after Migrate.
    property Version: Integer read FVersion;
  end;

implementation

uses
  SysUtils,
  Classes,
  PascalDb.Adapter.Base,
  {$IFDEF FPC}
  PascalDb.Adapter.SQLdb,
  {$ELSE}
  PascalDb.Adapter.FireDAC,
  {$ENDIF}
  PascalApi.Config,
  Agenda.Schema;

class function TAgendaDatabase.ConfiguredEngine: TAgendaEngine;
var
  LName: string;
begin
  LName := LowerCase(TAppConfig.Get('DB_ENGINE', 'sqlite'));
  if LName = 'sqlite' then
    Result := aeSQLite
  else if LName = 'postgresql' then
    Result := aePostgreSQL
  else
    raise Exception.CreateFmt('DB_ENGINE must be sqlite or postgresql, not "%s"', [LName]);
end;

class function TAgendaDatabase.SQLiteFile: string;
begin
  Result := ExpandFileName(TAppConfig.Get('DB_FILE',
    ExtractFilePath(ParamStr(0)) + 'agenda.sqlite'));
end;

procedure SetSQLiteParams(AParams: TStrings; const AFile: string);
begin
  {$IFDEF FPC}
  AParams.Values['ConnectorType'] := 'SQLite3';
  AParams.Values['DatabaseName'] := AFile;
  {$IFDEF UNIX}
  AParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', 'libsqlite3.so.0');
  {$ELSE}
  AParams.Values['ClientLibrary'] := TAppConfig.Get('SQLITE_CLIENT', '');
  {$ENDIF}
  {$ELSE}
  AParams.Values['DriverID'] := 'SQLite';
  AParams.Values['Database'] := AFile;
  {$ENDIF}
end;

// The adapters' names for the same settings (pascal-db-faa docs/adapters.md).
procedure SetPostgreSQLParams(AParams: TStrings; const AHost, APort, AName: string);
begin
  {$IFDEF FPC}
  AParams.Values['ConnectorType'] := 'PostgreSQL';
  AParams.Values['HostName'] := AHost;
  AParams.Values['Port'] := APort;
  AParams.Values['DatabaseName'] := AName;
  AParams.Values['UserName'] := TAppConfig.Get('DB_USER', 'postgres');
  AParams.Values['Password'] := TAppConfig.Get('DB_PASSWORD', '');
  AParams.Values['CharSet'] := 'UTF8';
  AParams.Values['ClientLibrary'] := TAppConfig.Get('PG_CLIENT', '');
  {$ELSE}
  AParams.Values['DriverID'] := 'PG';
  AParams.Values['Server'] := AHost;
  AParams.Values['Port'] := APort;
  AParams.Values['Database'] := AName;
  AParams.Values['User_Name'] := TAppConfig.Get('DB_USER', 'postgres');
  AParams.Values['Password'] := TAppConfig.Get('DB_PASSWORD', '');
  AParams.Values['CharacterSet'] := 'UTF8';
  AParams.Values['VendorLib'] := TAppConfig.Get('PG_CLIENT', '');
  {$ENDIF}
end;

constructor TAgendaDatabase.Create;
var
  LConfig: IDatabaseConfig; // an interface variable, never a class one (pascal-db-faa's rule)
  LHost, LPort, LName: string;
begin
  inherited Create;
  FEngine := ConfiguredEngine;
  LConfig := TDatabaseConfig.Create;
  case FEngine of
    aePostgreSQL:
      begin
        LHost := TAppConfig.Get('DB_HOST', 'localhost');
        LPort := TAppConfig.Get('DB_PORT', '5432');
        LName := TAppConfig.Get('DB_NAME', 'agenda');
        SetPostgreSQLParams(LConfig.ConnectionParams, LHost, LPort, LName);
        LConfig.SQLDialect := 'PostgreSQL';
        LConfig.SQLDirectory := PG_SQL_DIR;
        FDescription := Format('postgresql %s:%s/%s', [LHost, LPort, LName]);
      end;
  else
    SetSQLiteParams(LConfig.ConnectionParams, SQLiteFile);
    LConfig.SQLDialect := 'SQLite';
    LConfig.SQLDirectory := SQLITE_SQL_DIR;
    FDescription := 'sqlite ' + SQLiteFile;
  end;
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
