unit Agenda.Schema;

{$I agenda.inc}

{ The database schema: the SQL the application runs, by name (a
  TMemorySqlSource, directory SQLITE), and the migrations, in order.

  One database holds every tenant (the shared mode of pascal-api-infra-faa's
  tenancy): the catalog table TENANTS and, from M1 on, the domain tables,
  each with TENANT_ID. A migration is never edited after it ships: a change
  is a new one.

  TENANTS.ID is the tenant's slug, the name in the public routes
  (/public/<slug>/...). The catalog columns pascal-api-infra-faa's
  TDbTenantCatalog reads are ID, MODE, SUSPENDED and PLAN; the others are the
  application's. }

interface

uses
  PascalDb.SqlSources,
  PascalDb.Migrations;

const
  /// The SqlSource directory of the SQLite statements.
  SQLITE_DIR = 'SQLITE';

function AgendaSqlSource: ISqlSource;

/// Every migration, in version order.
function AgendaMigrations: TArray<TMigrationItem>;

implementation

function AgendaSqlSource: ISqlSource;
var
  LSource: TMemorySqlSource;
begin
  LSource := TMemorySqlSource.Create;
  Result := LSource;
  LSource
    .Add(SQLITE_DIR, 'MIG.0001',
      'CREATE TABLE IF NOT EXISTS SCHEMA_MIGRATIONS (VERSION INTEGER NOT NULL, ' +
      'APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL, ' +
      'CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION));')
    .Add(SQLITE_DIR, 'MIG.0002',
      'CREATE TABLE TENANTS (' +
      'ID VARCHAR(40) NOT NULL PRIMARY KEY, ' +
      'NAME VARCHAR(120) NOT NULL, ' +
      'TIME_ZONE VARCHAR(64) NOT NULL, ' +
      'MODE VARCHAR(10) DEFAULT ''shared'' NOT NULL, ' +
      'SUSPENDED INTEGER DEFAULT 0 NOT NULL, ' +
      'PLAN VARCHAR(40), ' +
      'CANCEL_NOTICE_HOURS INTEGER DEFAULT 24 NOT NULL, ' +
      'REMINDER_HOURS INTEGER DEFAULT 24 NOT NULL, ' +
      'CREATED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL);')
    .Add(SQLITE_DIR, 'HEALTH.PING', 'SELECT 1 AS ONE');
end;

function AgendaMigrations: TArray<TMigrationItem>;

  function Item(AVersion: Integer; const AName: string): TMigrationItem;
  begin
    Result.Version := AVersion;
    Result.ScriptName := AName;
    Result.ParamReplaceProc := nil;
    Result.Terminator := ';';
    Result.IsDDL := True;
  end;

begin
  Result := nil;
  SetLength(Result, 2);
  Result[0] := Item(1, 'MIG.0001');
  Result[1] := Item(2, 'MIG.0002');
end;

end.
