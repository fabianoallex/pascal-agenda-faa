unit Agenda.Schema;

{$I agenda.inc}

(* The database schema: the SQL the application runs, by name, and the
  migrations, in order.

  The statements live in a TMemorySqlSource under three directories: COMMON
  for what SQLite and PostgreSQL both run, SQLITE and PG for what one of them
  needs differently. Agenda.Database sets the engine's directory, and
  pascal-db-faa's TFallbackSqlSource (0.17.0; built here first, as
  Agenda.SqlSources) answers a key from it, else from COMMON: a key under
  PG overrides the common one for PostgreSQL only. On 2026-10-19 every
  statement is in COMMON: the types are ones both take (VARCHAR, INTEGER,
  BIGINT, TIMESTAMP), flags are INTEGER (bound with pascal-db-faa's
  Flags/OptFlags, 0.17.0: PostgreSQL refuses a Boolean parameter for an
  integer column), times are Unix seconds, money is cents, and paging is
  the dialect's ${PAGE}. An override is the place for what can't be
  common (RETURNING, ON CONFLICT, a JSONB column); a copy of a statement
  that is the same on both isn't.

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
  /// What both engines run.
  COMMON_SQL_DIR = 'COMMON';
  /// Each engine's overrides; the database's SQLDirectory.
  SQLITE_SQL_DIR = 'SQLITE';
  PG_SQL_DIR = 'PG';

function AgendaSqlSource: ISqlSource;

/// Every migration, in version order.
function AgendaMigrations: TArray<TMigrationItem>;

implementation

function AgendaSqlSource: ISqlSource;
var
  LSource: TMemorySqlSource;
  LMemory: ISqlSource;
begin
  LSource := TMemorySqlSource.Create;
  LMemory := LSource;
  Result := TFallbackSqlSource.Create(LMemory, COMMON_SQL_DIR);
  LSource
    // --- migrations
    .Add(COMMON_SQL_DIR, 'MIG.0001',
      'CREATE TABLE IF NOT EXISTS SCHEMA_MIGRATIONS (VERSION INTEGER NOT NULL, ' +
      'APPLIED_AT TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL, ' +
      'CONSTRAINT PK_SCHEMA_MIGRATIONS PRIMARY KEY (VERSION));')
    .Add(COMMON_SQL_DIR, 'MIG.0002',
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
    .Add(COMMON_SQL_DIR, 'MIG.0003',
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
    .Add(COMMON_SQL_DIR, 'MIG.0004',
      'CREATE TABLE JWT_KEYS (TENANT_ID VARCHAR(40) NOT NULL, GENERATION INTEGER NOT NULL, ' +
      'KID VARCHAR(128) NOT NULL, SECRET VARCHAR(255) NOT NULL, CREATED_AT BIGINT NOT NULL, ' +
      'ACTIVE_FROM BIGINT NOT NULL, CONSTRAINT PK_JWT_KEYS PRIMARY KEY (TENANT_ID, GENERATION), ' +
      'CONSTRAINT UQ_JWT_KEYS_KID UNIQUE (KID));')
    .Add(COMMON_SQL_DIR, 'MIG.0005',
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
    .Add(COMMON_SQL_DIR, 'MIG.0006',
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
    .Add(COMMON_SQL_DIR, 'MIG.0007',
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
    // SEARCH_KEY: NAME_KEY|EMAIL|the phone's digits, one column for one
    // LIKE (Agenda.Customers). PHONE: Agenda.Text's NormalizePhone.
    .Add(COMMON_SQL_DIR, 'MIG.0008',
      'CREATE TABLE CUSTOMERS (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'ID VARCHAR(32) NOT NULL, ' +
      'NAME VARCHAR(100) NOT NULL, ' +
      'NAME_KEY VARCHAR(100) NOT NULL, ' +
      'PHONE VARCHAR(16), ' +
      'EMAIL VARCHAR(254), ' +
      'SEARCH_KEY VARCHAR(400) NOT NULL, ' +
      'CREATED_AT BIGINT NOT NULL, ' +
      'UPDATED_AT BIGINT NOT NULL, ' +
      'CONSTRAINT PK_CUSTOMERS PRIMARY KEY (TENANT_ID, ID), ' +
      'CONSTRAINT FK_CUSTOMERS_TENANT FOREIGN KEY (TENANT_ID) REFERENCES TENANTS (ID));' +
      'CREATE INDEX IX_CUSTOMERS_NAME ON CUSTOMERS (TENANT_ID, NAME_KEY);' +
      'CREATE INDEX IX_CUSTOMERS_PHONE ON CUSTOMERS (TENANT_ID, PHONE);')
    // A user may be one of the tenant's professionals, and a professional at
    // most one user (NULLs don't collide in a unique index, on SQLite and
    // PostgreSQL alike). The application checks the professional exists:
    // ADD COLUMN can't add a two-column foreign key.
    .Add(COMMON_SQL_DIR, 'MIG.0009',
      'ALTER TABLE USERS ADD COLUMN PROFESSIONAL_ID VARCHAR(32);' +
      'ALTER TABLE USERS ADD COLUMN UPDATED_AT BIGINT;' +
      'CREATE UNIQUE INDEX UQ_USERS_PROFESSIONAL ON USERS (TENANT_ID, PROFESSIONAL_ID);')
    // WORKING_HOURS: the tenant's local clock (minutes since midnight, an
    // end up to 1440), WEEKDAY ISO (1 = Monday). TIME_OFF: instants, Unix
    // seconds UTC. Both go with their professional (Agenda.Professionals).
    .Add(COMMON_SQL_DIR, 'MIG.0010',
      'CREATE TABLE WORKING_HOURS (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'PROFESSIONAL_ID VARCHAR(32) NOT NULL, ' +
      'WEEKDAY INTEGER NOT NULL, ' +
      'START_MINUTE INTEGER NOT NULL, ' +
      'END_MINUTE INTEGER NOT NULL, ' +
      'CONSTRAINT PK_WORKING_HOURS PRIMARY KEY (TENANT_ID, PROFESSIONAL_ID, WEEKDAY, START_MINUTE), ' +
      'CONSTRAINT FK_WORKING_HOURS_PROFESSIONAL FOREIGN KEY (TENANT_ID, PROFESSIONAL_ID) ' +
      'REFERENCES PROFESSIONALS (TENANT_ID, ID));' +
      'CREATE TABLE TIME_OFF (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'ID VARCHAR(32) NOT NULL, ' +
      'PROFESSIONAL_ID VARCHAR(32) NOT NULL, ' +
      'START_UTC BIGINT NOT NULL, ' +
      'END_UTC BIGINT NOT NULL, ' +
      'REASON VARCHAR(200), ' +
      'CREATED_AT BIGINT NOT NULL, ' +
      'CONSTRAINT PK_TIME_OFF PRIMARY KEY (TENANT_ID, ID), ' +
      'CONSTRAINT FK_TIME_OFF_PROFESSIONAL FOREIGN KEY (TENANT_ID, PROFESSIONAL_ID) ' +
      'REFERENCES PROFESSIONALS (TENANT_ID, ID));' +
      'CREATE INDEX IX_TIME_OFF_START ON TIME_OFF (TENANT_ID, PROFESSIONAL_ID, START_UTC);')
    // APPOINTMENTS: instants (Unix seconds UTC). END_UTC is the service's
    // end, BUSY_UNTIL_UTC adds its buffer, both as the service was when
    // booked. The foreign keys keep what an appointment names from being
    // deleted (Agenda.Appointments).
    .Add(COMMON_SQL_DIR, 'MIG.0011',
      'CREATE TABLE APPOINTMENTS (' +
      'TENANT_ID VARCHAR(40) NOT NULL, ' +
      'ID VARCHAR(32) NOT NULL, ' +
      'PROFESSIONAL_ID VARCHAR(32) NOT NULL, ' +
      'SERVICE_ID VARCHAR(32) NOT NULL, ' +
      'CUSTOMER_ID VARCHAR(32) NOT NULL, ' +
      'START_UTC BIGINT NOT NULL, ' +
      'END_UTC BIGINT NOT NULL, ' +
      'BUSY_UNTIL_UTC BIGINT NOT NULL, ' +
      'STATUS VARCHAR(10) NOT NULL, ' +
      'VERSION INTEGER NOT NULL, ' +
      'CREATED_AT BIGINT NOT NULL, ' +
      'UPDATED_AT BIGINT NOT NULL, ' +
      'CONSTRAINT PK_APPOINTMENTS PRIMARY KEY (TENANT_ID, ID), ' +
      'CONSTRAINT FK_APPOINTMENTS_PROFESSIONAL FOREIGN KEY (TENANT_ID, PROFESSIONAL_ID) ' +
      'REFERENCES PROFESSIONALS (TENANT_ID, ID), ' +
      'CONSTRAINT FK_APPOINTMENTS_SERVICE FOREIGN KEY (TENANT_ID, SERVICE_ID) ' +
      'REFERENCES SERVICES (TENANT_ID, ID), ' +
      'CONSTRAINT FK_APPOINTMENTS_CUSTOMER FOREIGN KEY (TENANT_ID, CUSTOMER_ID) ' +
      'REFERENCES CUSTOMERS (TENANT_ID, ID));' +
      'CREATE INDEX IX_APPOINTMENTS_PROFESSIONAL ON APPOINTMENTS (TENANT_ID, PROFESSIONAL_ID, START_UTC);' +
      'CREATE INDEX IX_APPOINTMENTS_START ON APPOINTMENTS (TENANT_ID, START_UTC);')

    // --- operations
    .Add(COMMON_SQL_DIR, 'HEALTH.PING', 'SELECT 1 AS ONE')

    // --- catalog (TDbTenantCatalog; the application adds tenants)
    .Add(COMMON_SQL_DIR, 'TENANT.BY_ID', 'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS WHERE ID = :ID')
    .Add(COMMON_SQL_DIR, 'TENANT.ALL', 'SELECT ID, MODE, SUSPENDED, PLAN FROM TENANTS ORDER BY ID')
    .Add(COMMON_SQL_DIR, 'TENANT.INSERT',
      'INSERT INTO TENANTS (ID, NAME, TIME_ZONE, MODE, SUSPENDED) ' +
      'VALUES (:ID, :NAME, :TIME_ZONE, ''shared'', 0)')
    // The tenant's IANA zone (Agenda.Availability): its days and clock.
    .Add(COMMON_SQL_DIR, 'TENANT.TIME_ZONE', 'SELECT TIME_ZONE FROM TENANTS WHERE ID = :ID')
    .Add(COMMON_SQL_DIR, 'TENANT.SET_SUSPENDED', 'UPDATE TENANTS SET SUSPENDED = :SUSPENDED WHERE ID = :ID')

    // --- JWT signing keys (TDbJwtKeyStore)
    .Add(COMMON_SQL_DIR, 'JWT_KEY.BY_TENANT',
      'SELECT KID, SECRET, GENERATION, CREATED_AT, ACTIVE_FROM FROM JWT_KEYS ' +
      'WHERE TENANT_ID = :TENANT_ID')
    .Add(COMMON_SQL_DIR, 'JWT_KEY.INSERT',
      'INSERT INTO JWT_KEYS (TENANT_ID, GENERATION, KID, SECRET, CREATED_AT, ACTIVE_FROM) ' +
      'VALUES (:TENANT_ID, :GENERATION, :KID, :SECRET, :CREATED_AT, :ACTIVE_FROM)')
    .Add(COMMON_SQL_DIR, 'JWT_KEY.DELETE', 'DELETE FROM JWT_KEYS WHERE TENANT_ID = :TENANT_ID AND KID = :KID')

    // --- users (a tenant's rows)
    .Add(COMMON_SQL_DIR, 'USER.BY_EMAIL',
      'SELECT ID, EMAIL, PASSWORD_HASH, ROLE, ACTIVE FROM USERS WHERE EMAIL = :EMAIL AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'USER.BY_ID',
      'SELECT ID, EMAIL, PASSWORD_HASH, ROLE, ACTIVE FROM USERS WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'USER.INSERT',
      'INSERT INTO USERS (TENANT_ID, ID, EMAIL, PASSWORD_HASH, ROLE, ACTIVE, ' +
      '[PROFESSIONAL {] PROFESSIONAL_ID, [} PROFESSIONAL] CREATED_AT, UPDATED_AT) ' +
      'VALUES (:TENANT_ID, :ID, :EMAIL, :PASSWORD_HASH, :ROLE, 1, ' +
      '[PROFESSIONAL {] :PROFESSIONAL_ID, [} PROFESSIONAL] :CREATED_AT, :UPDATED_AT)')
    .Add(COMMON_SQL_DIR, 'USER.SET_PASSWORD_HASH',
      'UPDATE USERS SET PASSWORD_HASH = :PASSWORD_HASH WHERE ID = :ID AND ${TENANT}')
    // The users API (Agenda.Users): never the password hash.
    .Add(COMMON_SQL_DIR, 'USER.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM USERS WHERE ${TENANT} ' +
      '[SEARCH {] AND EMAIL LIKE :SEARCH ESCAPE ''!'' [} SEARCH] ' +
      '[ROLE {] AND ROLE = :ROLE [} ROLE] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE]')
    .Add(COMMON_SQL_DIR, 'USER.PAGE',
      'SELECT ID, EMAIL, ROLE, ACTIVE, PROFESSIONAL_ID FROM USERS WHERE ${TENANT} ' +
      '[SEARCH {] AND EMAIL LIKE :SEARCH ESCAPE ''!'' [} SEARCH] ' +
      '[ROLE {] AND ROLE = :ROLE [} ROLE] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE] ORDER BY ${ORDER} ${PAGE}')
    .Add(COMMON_SQL_DIR, 'USER.VIEW',
      'SELECT ID, EMAIL, ROLE, ACTIVE, PROFESSIONAL_ID FROM USERS WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'USER.UPDATE',
      'UPDATE USERS SET UPDATED_AT = :UPDATED_AT ' +
      '[EMAIL {], EMAIL = :EMAIL [} EMAIL] ' +
      '[PASSWORD {], PASSWORD_HASH = :PASSWORD_HASH [} PASSWORD] ' +
      '[ROLE {], ROLE = :ROLE [} ROLE] ' +
      '[ACTIVE {], ACTIVE = :ACTIVE [} ACTIVE] ' +
      '[PROFESSIONAL {], PROFESSIONAL_ID = :PROFESSIONAL_ID [} PROFESSIONAL] ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'USER.DELETE', 'DELETE FROM USERS WHERE ID = :ID AND ${TENANT}')
    // A professional deleted: the user linked to it stays, unlinked.
    .Add(COMMON_SQL_DIR, 'USER.UNLINK_PROFESSIONAL',
      'UPDATE USERS SET PROFESSIONAL_ID = NULL WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID ' +
      'AND ${TENANT}')

    // --- refresh tokens (a tenant's rows): pascal-api-infra-faa's
    // TDbRefreshTokenStore binds :TENANT_ID itself (its SQL contract), and
    // TTenantFilter.Prepare binds it too when Agenda.Users runs them.
    .Add(COMMON_SQL_DIR, 'REFRESH.INSERT',
      'INSERT INTO REFRESH_TOKENS (TENANT_ID, ID, TOKEN_HASH, USER_ID, FAMILY_ID, CREATED_AT, ' +
      'EXPIRES_AT) VALUES (:TENANT_ID, :ID, :TOKEN_HASH, :USER_ID, :FAMILY_ID, :CREATED_AT, ' +
      ':EXPIRES_AT)')
    .Add(COMMON_SQL_DIR, 'REFRESH.BY_HASH',
      'SELECT ID, USER_ID, FAMILY_ID, EXPIRES_AT, USED_AT, REVOKED_AT FROM REFRESH_TOKENS ' +
      'WHERE TOKEN_HASH = :TOKEN_HASH AND TENANT_ID = :TENANT_ID')
    // Only the first of two concurrent refreshes matches: the other one sees
    // 0 rows and is treated as a reuse.
    .Add(COMMON_SQL_DIR, 'REFRESH.MARK_USED',
      'UPDATE REFRESH_TOKENS SET USED_AT = :USED_AT WHERE ID = :ID AND USED_AT IS NULL ' +
      'AND REVOKED_AT IS NULL AND TENANT_ID = :TENANT_ID')
    .Add(COMMON_SQL_DIR, 'REFRESH.REVOKE_FAMILY',
      'UPDATE REFRESH_TOKENS SET REVOKED_AT = :REVOKED_AT WHERE FAMILY_ID = :FAMILY_ID ' +
      'AND REVOKED_AT IS NULL AND TENANT_ID = :TENANT_ID')
    // A user's password changed, or the user deactivated: every login ends.
    .Add(COMMON_SQL_DIR, 'REFRESH.REVOKE_USER',
      'UPDATE REFRESH_TOKENS SET REVOKED_AT = :REVOKED_AT WHERE USER_ID = :USER_ID ' +
      'AND REVOKED_AT IS NULL AND TENANT_ID = :TENANT_ID')
    // Before the user's row (the foreign key, enforced on PostgreSQL).
    .Add(COMMON_SQL_DIR, 'REFRESH.DELETE_USER',
      'DELETE FROM REFRESH_TOKENS WHERE USER_ID = :USER_ID AND ${TENANT}')

    // --- services (a tenant's rows). LIKE ... ESCAPE '!': PdbLikeContains' escape;
    // a backslash makes SQLdb lose the parameters after it (pascal-db-faa's gotcha 26). [SEARCH] and [ACTIVE] are kept only
    // when that filter came (ProcessTag); ${ORDER} comes from
    // ServiceOrderSpec, ${PAGE} from the connection's dialect.
    .Add(COMMON_SQL_DIR, 'SERVICE.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM SERVICES WHERE ${TENANT} ' +
      '[SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''!'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE]')
    .Add(COMMON_SQL_DIR, 'SERVICE.PAGE',
      'SELECT ID, NAME, DURATION_MINUTES, BUFFER_MINUTES, PRICE_CENTS, ACTIVE FROM SERVICES ' +
      'WHERE ${TENANT} [SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''!'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE] ORDER BY ${ORDER} ${PAGE}')
    .Add(COMMON_SQL_DIR, 'SERVICE.BY_ID',
      'SELECT ID, NAME, DURATION_MINUTES, BUFFER_MINUTES, PRICE_CENTS, ACTIVE FROM SERVICES ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'SERVICE.INSERT',
      'INSERT INTO SERVICES (TENANT_ID, ID, NAME, NAME_KEY, DURATION_MINUTES, BUFFER_MINUTES, ' +
      'PRICE_CENTS, ACTIVE, CREATED_AT, UPDATED_AT) VALUES (:TENANT_ID, :ID, :NAME, :NAME_KEY, ' +
      ':DURATION_MINUTES, :BUFFER_MINUTES, :PRICE_CENTS, 1, :CREATED_AT, :UPDATED_AT)')
    .Add(COMMON_SQL_DIR, 'SERVICE.UPDATE',
      'UPDATE SERVICES SET UPDATED_AT = :UPDATED_AT ' +
      '[NAME {], NAME = :NAME, NAME_KEY = :NAME_KEY [} NAME] ' +
      '[DURATION {], DURATION_MINUTES = :DURATION_MINUTES [} DURATION] ' +
      '[BUFFER {], BUFFER_MINUTES = :BUFFER_MINUTES [} BUFFER] ' +
      '[PRICE {], PRICE_CENTS = :PRICE_CENTS [} PRICE] ' +
      '[ACTIVE {], ACTIVE = :ACTIVE [} ACTIVE] ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'SERVICE.DELETE', 'DELETE FROM SERVICES WHERE ID = :ID AND ${TENANT}')

    // --- professionals (a tenant's rows)
    .Add(COMMON_SQL_DIR, 'PROFESSIONAL.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM PROFESSIONALS WHERE ${TENANT} ' +
      '[SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''!'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE]')
    .Add(COMMON_SQL_DIR, 'PROFESSIONAL.PAGE',
      'SELECT ID, NAME, EMAIL, ACTIVE FROM PROFESSIONALS ' +
      'WHERE ${TENANT} [SEARCH {] AND NAME_KEY LIKE :SEARCH ESCAPE ''!'' [} SEARCH] ' +
      '[ACTIVE {] AND ACTIVE = :ACTIVE [} ACTIVE] ORDER BY ${ORDER} ${PAGE}')
    .Add(COMMON_SQL_DIR, 'PROFESSIONAL.BY_ID',
      'SELECT ID, NAME, EMAIL, ACTIVE FROM PROFESSIONALS WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'PROFESSIONAL.INSERT',
      'INSERT INTO PROFESSIONALS (TENANT_ID, ID, NAME, NAME_KEY, [EMAIL {] EMAIL, [} EMAIL] ' +
      'ACTIVE, CREATED_AT, UPDATED_AT) VALUES (:TENANT_ID, :ID, :NAME, :NAME_KEY, ' +
      '[EMAIL {] :EMAIL, [} EMAIL] 1, :CREATED_AT, :UPDATED_AT)')
    .Add(COMMON_SQL_DIR, 'PROFESSIONAL.UPDATE',
      'UPDATE PROFESSIONALS SET UPDATED_AT = :UPDATED_AT ' +
      '[NAME {], NAME = :NAME, NAME_KEY = :NAME_KEY [} NAME] ' +
      '[EMAIL {], EMAIL = :EMAIL [} EMAIL] ' +
      '[ACTIVE {], ACTIVE = :ACTIVE [} ACTIVE] ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'PROFESSIONAL.DELETE',
      'DELETE FROM PROFESSIONALS WHERE ID = :ID AND ${TENANT}')
    // The first statement of a change to a professional's schedule: 0 rows
    // is a 404, and on PostgreSQL it locks the row, so two changes to one
    // professional's week run one after the other.
    .Add(COMMON_SQL_DIR, 'PROFESSIONAL.TOUCH',
      'UPDATE PROFESSIONALS SET UPDATED_AT = :UPDATED_AT WHERE ID = :ID AND ${TENANT}')

    // --- working hours (a tenant's rows); a PUT replaces the week
    .Add(COMMON_SQL_DIR, 'WORKING_HOURS.BY_PROFESSIONAL',
      'SELECT WEEKDAY, START_MINUTE, END_MINUTE FROM WORKING_HOURS ' +
      'WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID AND ${TENANT} ORDER BY WEEKDAY, START_MINUTE')
    .Add(COMMON_SQL_DIR, 'WORKING_HOURS.DELETE_ALL',
      'DELETE FROM WORKING_HOURS WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'WORKING_HOURS.INSERT',
      'INSERT INTO WORKING_HOURS (TENANT_ID, PROFESSIONAL_ID, WEEKDAY, START_MINUTE, END_MINUTE) ' +
      'VALUES (:TENANT_ID, :PROFESSIONAL_ID, :WEEKDAY, :START_MINUTE, :END_MINUTE)')

    // --- time off (a tenant's rows). [FROM] and [TO]: the entries that
    // overlap [from, to).
    .Add(COMMON_SQL_DIR, 'TIME_OFF.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM TIME_OFF WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID ' +
      'AND ${TENANT} [FROM {] AND END_UTC > :FROM_UTC [} FROM] [TO {] AND START_UTC < :TO_UTC [} TO]')
    .Add(COMMON_SQL_DIR, 'TIME_OFF.PAGE',
      'SELECT ID, START_UTC, END_UTC, REASON FROM TIME_OFF WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID ' +
      'AND ${TENANT} [FROM {] AND END_UTC > :FROM_UTC [} FROM] [TO {] AND START_UTC < :TO_UTC [} TO] ' +
      'ORDER BY ${ORDER} ${PAGE}')
    .Add(COMMON_SQL_DIR, 'TIME_OFF.BY_ID',
      'SELECT ID, START_UTC, END_UTC, REASON FROM TIME_OFF WHERE ID = :ID ' +
      'AND PROFESSIONAL_ID = :PROFESSIONAL_ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'TIME_OFF.INSERT',
      'INSERT INTO TIME_OFF (TENANT_ID, ID, PROFESSIONAL_ID, START_UTC, END_UTC, REASON, CREATED_AT) ' +
      'VALUES (:TENANT_ID, :ID, :PROFESSIONAL_ID, :START_UTC, :END_UTC, :REASON, :CREATED_AT)')
    .Add(COMMON_SQL_DIR, 'TIME_OFF.DELETE',
      'DELETE FROM TIME_OFF WHERE ID = :ID AND PROFESSIONAL_ID = :PROFESSIONAL_ID AND ${TENANT}')
    // Free slots (Agenda.Availability): every entry that meets [from, to).
    .Add(COMMON_SQL_DIR, 'TIME_OFF.OVERLAPPING',
      'SELECT START_UTC, END_UTC FROM TIME_OFF WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID ' +
      'AND ${TENANT} AND END_UTC > :FROM_UTC AND START_UTC < :TO_UTC')
    .Add(COMMON_SQL_DIR, 'TIME_OFF.DELETE_ALL',
      'DELETE FROM TIME_OFF WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID AND ${TENANT}')

    // --- appointments (a tenant's rows). [FROM] and [TO]: the ones that
    // overlap [from, to).
    .Add(COMMON_SQL_DIR, 'APPOINTMENT.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM APPOINTMENTS WHERE ${TENANT} ' +
      '[PROFESSIONAL {] AND PROFESSIONAL_ID = :PROFESSIONAL_ID [} PROFESSIONAL] ' +
      '[STATUS {] AND STATUS = :STATUS [} STATUS] ' +
      '[FROM {] AND END_UTC > :FROM_UTC [} FROM] [TO {] AND START_UTC < :TO_UTC [} TO]')
    .Add(COMMON_SQL_DIR, 'APPOINTMENT.PAGE',
      'SELECT ID, PROFESSIONAL_ID, SERVICE_ID, CUSTOMER_ID, START_UTC, END_UTC, STATUS, VERSION ' +
      'FROM APPOINTMENTS WHERE ${TENANT} ' +
      '[PROFESSIONAL {] AND PROFESSIONAL_ID = :PROFESSIONAL_ID [} PROFESSIONAL] ' +
      '[STATUS {] AND STATUS = :STATUS [} STATUS] ' +
      '[FROM {] AND END_UTC > :FROM_UTC [} FROM] [TO {] AND START_UTC < :TO_UTC [} TO] ' +
      'ORDER BY ${ORDER} ${PAGE}')
    .Add(COMMON_SQL_DIR, 'APPOINTMENT.BY_ID',
      'SELECT ID, PROFESSIONAL_ID, SERVICE_ID, CUSTOMER_ID, START_UTC, END_UTC, STATUS, VERSION ' +
      'FROM APPOINTMENTS WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'APPOINTMENT.INSERT',
      'INSERT INTO APPOINTMENTS (TENANT_ID, ID, PROFESSIONAL_ID, SERVICE_ID, CUSTOMER_ID, ' +
      'START_UTC, END_UTC, BUSY_UNTIL_UTC, STATUS, VERSION, CREATED_AT, UPDATED_AT) VALUES ' +
      '(:TENANT_ID, :ID, :PROFESSIONAL_ID, :SERVICE_ID, :CUSTOMER_ID, :START_UTC, :END_UTC, ' +
      ':BUSY_UNTIL_UTC, :STATUS, 1, :CREATED_AT, :CREATED_AT)')
    // Free slots (Agenda.Availability): what is busy, buffer included, in
    // [from, to); the status bound, not quoted in the SQL.
    .Add(COMMON_SQL_DIR, 'APPOINTMENT.BUSY',
      'SELECT START_UTC, BUSY_UNTIL_UTC AS END_UTC FROM APPOINTMENTS ' +
      'WHERE PROFESSIONAL_ID = :PROFESSIONAL_ID AND ${TENANT} AND STATUS <> :CANCELLED ' +
      'AND BUSY_UNTIL_UTC > :FROM_UTC AND START_UTC < :TO_UTC')

    // --- customers (a tenant's rows)
    .Add(COMMON_SQL_DIR, 'CUSTOMER.COUNT',
      'SELECT COUNT(*) AS TOTAL FROM CUSTOMERS WHERE ${TENANT} ' +
      '[SEARCH {] AND SEARCH_KEY LIKE :SEARCH ESCAPE ''!'' [} SEARCH]')
    .Add(COMMON_SQL_DIR, 'CUSTOMER.PAGE',
      'SELECT ID, NAME, PHONE, EMAIL FROM CUSTOMERS WHERE ${TENANT} ' +
      '[SEARCH {] AND SEARCH_KEY LIKE :SEARCH ESCAPE ''!'' [} SEARCH] ' +
      'ORDER BY ${ORDER} ${PAGE}')
    .Add(COMMON_SQL_DIR, 'CUSTOMER.BY_ID',
      'SELECT ID, NAME, PHONE, EMAIL FROM CUSTOMERS WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'CUSTOMER.INSERT',
      'INSERT INTO CUSTOMERS (TENANT_ID, ID, NAME, NAME_KEY, ' +
      '[PHONE {] PHONE, [} PHONE] ' +
      '[EMAIL {] EMAIL, [} EMAIL] SEARCH_KEY, ' +
      'CREATED_AT, UPDATED_AT) VALUES (:TENANT_ID, :ID, :NAME, :NAME_KEY, ' +
      '[PHONE {] :PHONE, [} PHONE] ' +
      '[EMAIL {] :EMAIL, [} EMAIL] ' +
      ':SEARCH_KEY, :CREATED_AT, :UPDATED_AT)')
    // Every column: the search key depends on all of them, so a PATCH writes
    // the merged row.
    .Add(COMMON_SQL_DIR, 'CUSTOMER.UPDATE',
      'UPDATE CUSTOMERS SET NAME = :NAME, NAME_KEY = :NAME_KEY, PHONE = :PHONE, ' +
      'EMAIL = :EMAIL, SEARCH_KEY = :SEARCH_KEY, UPDATED_AT = :UPDATED_AT ' +
      'WHERE ID = :ID AND ${TENANT}')
    .Add(COMMON_SQL_DIR, 'CUSTOMER.DELETE', 'DELETE FROM CUSTOMERS WHERE ID = :ID AND ${TENANT}');
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
  SetLength(Result, 11);
  Result[0] := Item(1, 'MIG.0001');
  Result[1] := Item(2, 'MIG.0002');
  Result[2] := Item(3, 'MIG.0003');
  Result[3] := Item(4, 'MIG.0004');
  Result[4] := Item(5, 'MIG.0005');
  Result[5] := Item(6, 'MIG.0006');
  Result[6] := Item(7, 'MIG.0007');
  Result[7] := Item(8, 'MIG.0008');
  Result[8] := Item(9, 'MIG.0009');
  Result[9] := Item(10, 'MIG.0010');
  Result[10] := Item(11, 'MIG.0011');
end;

end.
