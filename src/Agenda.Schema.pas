unit Agenda.Schema;

{$I agenda.inc}

(* The database schema: the SQL the application runs, by name (a
  TMemorySqlSource, directory SQLITE), and the migrations, in order.

  One database holds every tenant (the shared mode of pascal-api-infra-faa's
  tenancy): the catalog table TENANTS, the JWT signing keys, and the tenants'
  rows, each with TENANT_ID, part of every primary and unique key. A
  migration is never edited after it ships: a change is a new one.

  Named SQL the libraries read, with the columns they expect:
  - TENANT.BY_ID, TENANT.ALL: pascal-api-infra-faa's TDbTenantCatalog (ID,
    MODE, SUSPENDED, PLAN).
  - JWT_KEY.BY_TENANT, JWT_KEY.INSERT, JWT_KEY.DELETE: its TDbJwtKeyStore;
    the primary key on (TENANT_ID, GENERATION) settles two instances
    rotating at once.

  Every query on a tenant's rows has the ${TENANT} tag (or :TENANT_ID in an
  INSERT) and goes through TTenantFilter.Prepare, which sets the condition
  and binds its value in one call. Times are Unix seconds (BIGINT), the same
  on every database.

  TENANTS.ID is the tenant's slug, the name in the public routes
  (/public/<slug>/...). This comment uses parenthesis-asterisk: it quotes
  ${TENANT}, whose brace would close a brace comment. *)

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
    // --- migrations
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
    .Add(SQLITE_DIR, 'MIG.0003',
      'CREATE TABLE USERS (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'ID VARCHAR(32) NOT NULL, ' +
      'EMAIL VARCHAR(254) NOT NULL, ' +
      'PASSWORD_HASH VARCHAR(200) NOT NULL, ' +
      'ROLE VARCHAR(10) NOT NULL, ' +
      'ACTIVE INTEGER DEFAULT 1 NOT NULL, ' +
      'CREATED_AT BIGINT NOT NULL, ' +
      'CONSTRAINT PK_USERS PRIMARY KEY (TENANT_ID, ID), ' +
      'CONSTRAINT UQ_USERS_EMAIL UNIQUE (TENANT_ID, EMAIL), ' +
      'CONSTRAINT FK_USERS_TENANT FOREIGN KEY (TENANT_ID) REFERENCES TENANTS (ID));')
    .Add(SQLITE_DIR, 'MIG.0004',
      'CREATE TABLE JWT_KEYS (TENANT_ID VARCHAR(40) NOT NULL, GENERATION INTEGER NOT NULL, ' +
      'KID VARCHAR(128) NOT NULL, SECRET VARCHAR(255) NOT NULL, CREATED_AT BIGINT NOT NULL, ' +
      'ACTIVE_FROM BIGINT NOT NULL, CONSTRAINT PK_JWT_KEYS PRIMARY KEY (TENANT_ID, GENERATION), ' +
      'CONSTRAINT UQ_JWT_KEYS_KID UNIQUE (KID));')
    .Add(SQLITE_DIR, 'MIG.0005',
      'CREATE TABLE REFRESH_TOKENS (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'ID VARCHAR(32) NOT NULL, ' +
      'TOKEN_HASH VARCHAR(64) NOT NULL, ' +
      'USER_ID VARCHAR(32) NOT NULL, ' +
      'FAMILY_ID VARCHAR(32) NOT NULL, ' +
      'CREATED_AT BIGINT NOT NULL, ' +
      'EXPIRES_AT BIGINT NOT NULL, ' +
      'USED_AT BIGINT, ' +
      'REVOKED_AT BIGINT, ' +
      'CONSTRAINT PK_REFRESH_TOKENS PRIMARY KEY (TENANT_ID, ID), ' +
      'CONSTRAINT UQ_REFRESH_TOKENS_HASH UNIQUE (TENANT_ID, TOKEN_HASH), ' +
      'CONSTRAINT FK_REFRESH_TOKENS_USER FOREIGN KEY (TENANT_ID, USER_ID) ' +
      'REFERENCES USERS (TENANT_ID, ID));' +
      'CREATE INDEX IX_REFRESH_TOKENS_FAMILY ON REFRESH_TOKENS (TENANT_ID, FAMILY_ID);')
    // NAME_KEY: the name folded for searching (Agenda.Text); a service's is
    // unique within its tenant. PRICE_CENTS: exact on every database.
    .Add(SQLITE_DIR, 'MIG.0006',
      'CREATE TABLE SERVICES (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'ID VARCHAR(32) NOT NULL, ' +
      'NAME VARCHAR(100) NOT NULL, ' +
      'NAME_KEY VARCHAR(100) NOT NULL, ' +
      'DURATION_MINUTES INTEGER NOT NULL, ' +
      'BUFFER_MINUTES INTEGER DEFAULT 0 NOT NULL, ' +
      'PRICE_CENTS BIGINT NOT NULL, ' +
      'ACTIVE INTEGER DEFAULT 1 NOT NULL, ' +
      'CREATED_AT BIGINT NOT NULL, ' +
      'UPDATED_AT BIGINT NOT NULL, ' +
      'CONSTRAINT PK_SERVICES PRIMARY KEY (TENANT_ID, ID), ' +
      'CONSTRAINT UQ_SERVICES_NAME UNIQUE (TENANT_ID, NAME_KEY), ' +
      'CONSTRAINT FK_SERVICES_TENANT FOREIGN KEY (TENANT_ID) REFERENCES TENANTS (ID));')
    .Add(SQLITE_DIR, 'MIG.0007',
      'CREATE TABLE PROFESSIONALS (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'ID VARCHAR(32) NOT NULL, ' +
      'NAME VARCHAR(100) NOT NULL, ' +
      'NAME_KEY VARCHAR(100) NOT NULL, ' +
      'EMAIL VARCHAR(254), ' +
      'ACTIVE INTEGER DEFAULT 1 NOT NULL, ' +
      'CREATED_AT BIGINT NOT NULL, ' +
      'UPDATED_AT BIGINT NOT NULL, ' +
      'CONSTRAINT PK_PROFESSIONALS PRIMARY KEY (TENANT_ID, ID), ' +
      'CONSTRAINT FK_PROFESSIONALS_TENANT FOREIGN KEY (TENANT_ID) REFERENCES TENANTS (ID));' +
      'CREATE INDEX IX_PROFESSIONALS_NAME ON PROFESSIONALS (TENANT_ID, NAME_KEY);')

    // --- operations
    .Add(SQLITE_DIR, 'HEALTH.PING', 'SELECT 1 AS ONE')

    // --- catalog (TDbTenantCatalog; the application adds tenants)
    .Add(SQLITE_DIR, 'TENANT.BY_ID', 'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS WHERE ID = :ID')
    .Add(SQLITE_DIR, 'TENANT.ALL', 'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS ORDER BY ID')
    .Add(SQLITE_DIR, 'TENANT.INSERT',
      'INSERT INTO TENANTS (ID, NAME, TIME_ZONE, MODE, SUSPENDED) ' +
      'VALUES (:ID, :NAME, :TIME_ZONE, ''shared'', 0)')
    .Add(SQLITE_DIR, 'TENANT.SET_SUSPENDED', 'UPDATE TENANTS SET SUSPENDED = :SUSPENDED WHERE ID = :ID')

    // --- JWT signing keys (TDbJwtKeyStore)
    .Add(SQLITE_DIR, 'JWT_KEY.BY_TENANT',
      'SELECT KID, SECRET, GENERATION, CREATED_AT, ACTIVE_FROM FROM JWT_KEYS ' +
      'WHERE TENANT_ID = :TENANT_ID')
    .Add(SQLITE_DIR, 'JWT_KEY.INSERT',
      'INSERT INTO JWT_KEYS (TENANT_ID, GENERATION, KID, SECRET, CREATED_AT, ACTIVE_FROM) ' +
      'VALUES (:TENANT_ID, :GENERATION, :KID, :SECRET, :CREATED_AT, :ACTIVE_FROM)')
    .Add(SQLITE_DIR, 'JWT_KEY.DELETE', 'DELETE FROM JWT_KEYS WHERE TENANT_ID = :TENANT_ID AND KID = :KID')

    // --- users (a tenant's rows)
    .Add(SQLITE_DIR, 'USER.BY_EMAIL',
      'SELECT ID, EMAIL, PASSWORD_HASH, ROLE, ACTIVE FROM USERS WHERE EMAIL = :EMAIL AND ${TENANT}')
    .Add(SQLITE_DIR, 'USER.BY_ID',
      'SELECT ID, EMAIL, PASSWORD_HASH, ROLE, ACTIVE FROM USERS WHERE ID = :ID AND ${TENANT}')
    .Add(SQLITE_DIR, 'USER.INSERT',
      'INSERT INTO USERS (TENANT_ID, ID, EMAIL, PASSWORD_HASH, ROLE, ACTIVE, CREATED_AT) ' +
      'VALUES (:TENANT_ID, :ID, :EMAIL, :PASSWORD_HASH, :ROLE, 1, :CREATED_AT)')
    .Add(SQLITE_DIR, 'USER.SET_PASSWORD_HASH',
      'UPDATE USERS SET PASSWORD_HASH = :PASSWORD_HASH WHERE ID = :ID AND ${TENANT}')

    // --- refresh tokens (a tenant's rows)
    .Add(SQLITE_DIR, 'REFRESH.INSERT',
      'INSERT INTO REFRESH_TOKENS (TENANT_ID, ID, TOKEN_HASH, USER_ID, FAMILY_ID, CREATED_AT, ' +
      'EXPIRES_AT) VALUES (:TENANT_ID, :ID, :TOKEN_HASH, :USER_ID, :FAMILY_ID, :CREATED_AT, ' +
      ':EXPIRES_AT)')
    .Add(SQLITE_DIR, 'REFRESH.BY_HASH',
      'SELECT ID, USER_ID, FAMILY_ID, EXPIRES_AT, USED_AT, REVOKED_AT FROM REFRESH_TOKENS ' +
      'WHERE TOKEN_HASH = :TOKEN_HASH AND ${TENANT}')
    // Only the first of two concurrent refreshes matches: the other one sees
    // 0 rows and is treated as a reuse.
    .Add(SQLITE_DIR, 'REFRESH.MARK_USED',
      'UPDATE REFRESH_TOKENS SET USED_AT = :USED_AT WHERE ID = :ID AND USED_AT IS NULL ' +
      'AND REVOKED_AT IS NULL AND ${TENANT}')
    .Add(SQLITE_DIR, 'REFRESH.REVOKE_FAMILY',
      'UPDATE REFRESH_TOKENS SET REVOKED_AT = :REVOKED_AT WHERE FAMILY_ID = :FAMILY_ID ' +
      'AND REVOKED_AT IS NULL AND ${TENANT}')

    // --- services (a tenant's rows). [SEARCH] and [ACTIVE] are kept only
    // when that filter came (ProcessTag); ${ORDER} comes from
    // ServiceOrderSpec, ${PAGE} from the connection's dialect.
    .Add(SQLITE_DIR, 'SERVICE.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM SERVICES WHERE ${TENANT} ' +
      '[SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''\'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE]')
    .Add(SQLITE_DIR, 'SERVICE.PAGE',
      'SELECT ID, NAME, DURATION_MINUTES, BUFFER_MINUTES, PRICE_CENTS, ACTIVE FROM SERVICES ' +
      'WHERE ${TENANT} [SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''\'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE] ORDER BY ${ORDER} ${PAGE}')
    .Add(SQLITE_DIR, 'SERVICE.BY_ID',
      'SELECT ID, NAME, DURATION_MINUTES, BUFFER_MINUTES, PRICE_CENTS, ACTIVE FROM SERVICES ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(SQLITE_DIR, 'SERVICE.INSERT',
      'INSERT INTO SERVICES (TENANT_ID, ID, NAME, NAME_KEY, DURATION_MINUTES, BUFFER_MINUTES, ' +
      'PRICE_CENTS, ACTIVE, CREATED_AT, UPDATED_AT) VALUES (:TENANT_ID, :ID, :NAME, :NAME_KEY, ' +
      ':DURATION_MINUTES, :BUFFER_MINUTES, :PRICE_CENTS, 1, :CREATED_AT, :UPDATED_AT)')
    .Add(SQLITE_DIR, 'SERVICE.UPDATE',
      'UPDATE SERVICES SET UPDATED_AT = :UPDATED_AT ' +
      '[NAME {], NAME = :NAME, NAME_KEY = :NAME_KEY [} NAME] ' +
      '[DURATION {], DURATION_MINUTES = :DURATION_MINUTES [} DURATION] ' +
      '[BUFFER {], BUFFER_MINUTES = :BUFFER_MINUTES [} BUFFER] ' +
      '[PRICE {], PRICE_CENTS = :PRICE_CENTS [} PRICE] ' +
      '[ACTIVE {], ACTIVE = :ACTIVE [} ACTIVE] ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(SQLITE_DIR, 'SERVICE.DELETE', 'DELETE FROM SERVICES WHERE ID = :ID AND ${TENANT}')

    // --- professionals (a tenant's rows)
    .Add(SQLITE_DIR, 'PROFESSIONAL.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM PROFESSIONALS WHERE ${TENANT} ' +
      '[SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''\'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE]')
    .Add(SQLITE_DIR, 'PROFESSIONAL.PAGE',
      'SELECT ID, NAME, EMAIL, ACTIVE FROM PROFESSIONALS ' +
      'WHERE ${TENANT} [SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''\'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE] ORDER BY ${ORDER} ${PAGE}')
    .Add(SQLITE_DIR, 'PROFESSIONAL.BY_ID',
      'SELECT ID, NAME, EMAIL, ACTIVE FROM PROFESSIONALS WHERE ID = :ID AND ${TENANT}')
    .Add(SQLITE_DIR, 'PROFESSIONAL.INSERT',
      'INSERT INTO PROFESSIONALS (TENANT_ID, ID, NAME, NAME_KEY, EMAIL, ACTIVE, CREATED_AT, ' +
      'UPDATED_AT) VALUES (:TENANT_ID, :ID, :NAME, :NAME_KEY, :EMAIL, 1, :CREATED_AT, :UPDATED_AT)')
    .Add(SQLITE_DIR, 'PROFESSIONAL.UPDATE',
      'UPDATE PROFESSIONALS SET UPDATED_AT = :UPDATED_AT ' +
      '[NAME {], NAME = :NAME, NAME_KEY = :NAME_KEY [} NAME] ' +
      '[EMAIL {], EMAIL = :EMAIL [} EMAIL] ' +
      '[ACTIVE {], ACTIVE = :ACTIVE [} ACTIVE] ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(SQLITE_DIR, 'PROFESSIONAL.DELETE',
      'DELETE FROM PROFESSIONALS WHERE ID = :ID AND ${TENANT}');
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
  SetLength(Result, 7);
  Result[0] := Item(1, 'MIG.0001');
  Result[1] := Item(2, 'MIG.0002');
  Result[2] := Item(3, 'MIG.0003');
  Result[3] := Item(4, 'MIG.0004');
  Result[4] := Item(5, 'MIG.0005');
  Result[5] := Item(6, 'MIG.0006');
  Result[6] := Item(7, 'MIG.0007');
end;

end.
