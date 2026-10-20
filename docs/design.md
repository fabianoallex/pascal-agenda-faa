# pascal-agenda-faa — design

Status: scope agreed with the user on 2026-10-18. M0 built (see "Progress").

## Why this application exists

The `*-faa` libraries (pascal-common-faa, pascal-jsonmapper-faa, pascal-db-faa,
pascal-api-infra-faa, pascal-redis-faa, pascal-amqp-faa) were proven by their own tests and
samples. A sample never meets the problems of a real consumer: search paths, package versions,
one copy of pascal-common-faa, concurrency, time zones, data from one customer reaching another.
This application is a real product built only on them, to find what they lack.

Two outputs, both counted as success:

1. A working scheduling API (and later a desktop client) on both compilers.
2. A list of **library candidates**: pieces any similar API would need, built here first and
   promoted to a library (opt-in) only after they work here and turn out generic.

## The product

Online scheduling for clinics, salons and similar businesses. Each business is a tenant.

| Who | Does |
|---|---|
| Owner (tenant admin) | registers professionals, services, working hours; manages staff |
| Staff / professional | sees and manages the agenda |
| End customer | books and cancels without an account (public routes, a signed cancel link) |
| AI agent (MCP) | lists free slots, books, cancels, summarises the day |

## Data model

Every table except the catalog has `tenant_id`; every query goes through
`TTenantFilter.Prepare` (pascal-api-infra-faa's rule).

| Table | Main columns |
|---|---|
| `tenants` (catalog) | slug, name, **IANA time zone**, cancellation notice (hours), reminder lead (hours), status |
| `users` | email, `password_hash`, role (`owner`, `staff`), linked professional |
| `professionals` | name, active |
| `services` | name, duration (min), buffer after (min), price (`Currency`) |
| `working_hours` | professional, weekday, start, end — **local** time of the tenant |
| `time_off` | professional, start, end (UTC), reason |
| `customers` | name, phone, email |
| `appointments` | professional, service, customer, `start_utc`, `end_utc`, status (`booked`, `confirmed`, `cancelled`, `done`, `no_show`), `version` |
| `refresh_tokens` | user, family, hash, expires, replaced by, revoked |
| `idempotency_keys` | key, request hash, status, stored response, expires |
| `outbox` | event type, payload (JSON), created, published |

## Rules that stress the libraries

- **No double booking** of a professional: a Redis lock (`SetNx` with expiry) around the
  booking, and the database has the final word (constraint or a checked insert). Two
  concurrent requests for one slot: one 201, one 409. A scenario script fires them in parallel.
- **Free slots** = working hours − time off − appointments − buffers, computed in the tenant's
  time zone and stored in UTC; a daylight-saving change (a tenant in `America/New_York` or
  `Europe/Lisbon`) is part of the tests.
- **Cancellation** only inside the tenant's notice; an update with an old `version` is 412,
  without `If-Match` 428.
- **Booking is idempotent**: the same `Idempotency-Key` replays the first answer.

## Routes

Authenticated (tenant from the token claim, as today):

- `POST /auth/login` (excluded from JWT; tenant from the body's slug, checked against the
  catalog), `POST /auth/refresh`, `POST /auth/logout`
- CRUD: `/services`, `/professionals`, `/professionals/{id}/working-hours`,
  `/professionals/{id}/time-off`, `/customers`, `/users`
- `GET /appointments?from=&to=&professional=&status=&page=&order=`,
  `POST /appointments`, `PATCH /appointments/{id}` (`If-Match`), `POST /appointments/{id}/cancel`

Public (rate limited, tenant from the path slug — see decision 2):

- `GET /public/{slug}/services`, `GET /public/{slug}/professionals`
- `GET /public/{slug}/availability?service=&professional=&date=`
- `POST /public/{slug}/appointments` (`Idempotency-Key` required)
- `POST /public/appointments/{id}/cancel?exp=&sig=` (signed link)

Operations: `/health`, `/metrics`, `/openapi.json`, `/mcp`.

## Processes and infrastructure

- **api**: Horse, every pascal-api-infra-faa middleware, OpenAPI and MCP.
- **worker**: consumes AMQP (pascal-amqp-faa); sends confirmations and reminders; a scheduler
  with a lease (one instance runs each reminder).
- **Outbox relay**: in the api or the worker; reads `outbox` and publishes to AMQP.
- Development: SQLite, no Docker needed for the api alone.
- `docker compose`: PostgreSQL, Redis, RabbitMQ, Mailpit (fake SMTP), OpenTelemetry
  Collector, Prometheus; api and worker built with plain `fpc` on Linux.
- The same sources build on Delphi (Windows) and Lazarus/FPC; CI on Linux with FPC.
- The libraries are git submodules in `external/`, pinned, one copy each (the
  `using-faa-libraries` skill).

## Milestones

| # | Delivers | Validates |
|---|---|---|
| M0 | Repository, submodules, build on both compilers, CI, `/health`, config, migrations | The consumer's experience: search paths, `.lpk`, minimum versions |
| M1 | Tenants, login with password hash, refresh tokens, CRUD with paging and ordering, OpenAPI | Tenancy, per-tenant JWT key rings, DTOs, migrations on two dialects |
| M2 | Free-slot computation, booking with a lock, idempotency, `If-Match` | Concurrency, time zones |
| M3 | Public routes by slug, rate limit, signed cancel link | Tenant outside the token, rate limit |
| M4 | Outbox → AMQP → worker, scheduled reminders | Messaging, a trace across processes |
| M5 | MCP tools, dashboards, load test (k6 or wrk) | MCP, metrics under load, FPC/Linux vs Delphi/Windows |
| M6 | Delphi VCL desktop client sharing the server's DTOs | Typed HTTP client, refresh, DTO reuse |

Every milestone ends with: unit tests (DUnitX masters, FPCUnit mirrors) and HTTP scenario
scripts green on FPC (Windows and Linux) and Delphi (Win32 and Win64), 0 leaks.

## Decisions (user, 2026-10-18)

1. **Name and place**: `pascal-agenda-faa`, next to the libraries.
2. **Public routes take the tenant from the path slug.** This reopens pascal-api-infra-faa's
   multi-tenancy decision 5 ("host and header come when a real case asks for them"): this is
   the real case. Rules already set there apply: an unknown slug is 404, the same for every
   name (decision 7); when a token and a slug both name a tenant they must agree (403); the
   tenant never comes from the body (except the login, which checks it against the catalog).
3. **Time zones are solved properly**: a design phase for IANA time zones on both compilers
   (`PascalCommon.TimeZones` candidate), not a fixed offset table.
4. **The desktop client stays in scope as M6.**

## Library candidates

Each candidate is born in an isolated unit of this application, written under the libraries'
code rules (`{$I ...inc}`, no anonymous methods, no string helpers, UTF-8 in bytes). It moves
to a library only when it works here and is generic, and only with the user's decision. Code
two libraries would share goes to pascal-common-faa.

**Very likely** (any similar API needs them):

| Candidate | Would live in | Notes |
|---|---|---|
| Password hashing: PBKDF2-HMAC-SHA256, `$pbkdf2-sha256$<iter>$<salt>$<hash>`, constant-time compare, "needs rehash" | pascal-common-faa (has HMAC and `Random`) | no library has it |
| Refresh tokens: rotation, reuse detection, family revoke, db/Redis store | `PascalApi.RefreshTokens` + `src/redis` | `docs/jwt-keys-design.md` lists them as "an application's flow": promoting reopens that |
| `Idempotency-Key` middleware: replay, 409 while in flight, 422 on another body | `PascalApi.Idempotency` + Horse, db/Redis store | same pluggable-store shape as the JWT keys |
| Optimistic concurrency: `ETag`/`If-Match`, 412/428 | `PascalApi.Http` + middleware | small |
| Tenant from the path or host | `PascalApi.Tenancy` | multi-tenancy decision 5 |
| Signed links: HMAC with expiry, keys from the JWT key ring | `PascalApi.SignedUrl` | cancel, invite, email confirmation |
| IANA time zones on both compilers | pascal-common-faa | **biggest risk**: neither RTL converts an arbitrary zone. Linux has `/usr/share/zoneinfo`; Windows has the registry (Windows names) or an embedded database. Own design phase before M2. **Done in pascal-common-faa 1.22.0** (`PascalCommon.TimeZones`, the tzdb embedded); adopted 2026-10-20 |

**Probable** (a second case should confirm the shape):

- Transactional outbox + relay to AMQP: needs pascal-db-faa and pascal-amqp-faa together, so a
  bridge (`src/amqp` in pascal-api-infra-faa, or a bridge in pascal-amqp-faa).
- Scheduler with a lease (Redis `SetNx` or a database row): the core in pascal-common-faa.
- RFC 9457 errors (`application/problem+json`) as an option of `TErrorHandlerMiddleware`.
- Typed HTTP client for Delphi/Lazarus with refresh, retry and trace propagation (M6).

**Found while building** (not in the first list):

- Filling a Find DTO from the query string, and the paged query (count + page through the same
  filters): both repeated in every list route (see "Progress", M1, customers and users).
- Phone normalization, next to the accent-insensitive search key (pascal-common-faa).
- An instant type for the mapper: zone required on input, `Z` on output (pascal-jsonmapper-faa).
- A Boolean parameter into an `INTEGER` column fails on PostgreSQL ("column ... is of type
  integer but expression is of type boolean"); SQLite takes it, and pascal-db-faa's contract suite
  only binds `Integers` to its flag column (it reads one back as a Boolean). pascal-db-faa: say it
  in `docs/optionals.md`, or convert in the parameter (the dialect knows); pascal-api-infra-faa's
  `TQueryArgs.Booleans` has the same trap. Here: `Agenda.Flags` (`OptFlag`, a cross-type map).
  **Done** in pascal-db-faa 0.17.0 (`IParams.Flags`/`OptFlags`, measured on every adapter: also
  SQLdb on Firebird stored -1 and Zeos sent `'Y'`, both fixed; gotcha 54) and pascal-api-infra-faa
  0.21.0 (`TQueryArgs.Flags`); adopted here 2026-10-20, `Agenda.Flags` removed.
- The refresh rotation in one transaction (pascal-api-infra-faa): **fixed in 0.20.1**, found by
  the PostgreSQL run ("Migrations on two dialects", below).
- A SQL source that falls back to a common directory (`src/Agenda.SqlSources`,
  `TFallbackSqlSource`, pascal-db-faa's `PascalDb.SqlSources`): the database's directory first,
  then `COMMON`, so SQL that is the same on two databases is written once and a statement that
  differs has its place. Written under pascal-db-faa's rules, unit-tested; built 2026-10-20.
  **Done** in pascal-db-faa 0.17.0 (same name, the common directory a constructor parameter);
  adopted here 2026-10-20, `Agenda.SqlSources` and its 7 tests removed.
- Validation in the libraries (from `Agenda.Validation`'s three overloads per rule and the limits written twice, once in `Describe`): **designed 2026-10-19** in pascal-api-infra-faa's `docs/validation-design.md`; built in pascal-common-faa 1.21.0 and pascal-api-infra-faa 0.20.0, adopted here 2026-10-19 ("Validation from the libraries", below).

- A shared test kit: the DUnitX-to-FPCUnit adapter and the mirror generator, copied in every
  repository of the family. **Done 2026-10-19 in the skill** (the user's choice):
  `dual-compiler-delphi-lazarus/scripts/gen_fpc_mirror.py` (canonical, copied unchanged into
  `tools/`), `assets/DUnitXCompat.pas.template`, `scripts/check_test_kit.py`. Adopted here and in
  pascal-common-faa, -jsonmapper-faa, -db-faa, -api-infra-faa, then redis, amqp and pipes.

**Not library material**: email/SMS sending, agenda rules, free-slot computation.

When a candidate is found or promoted, record it here and in pascal-api-infra-faa's
`docs/plan.md` ("Candidates from pascal-agenda-faa").

## Progress

### M0 — skeleton (2026-10-18)

`api/AgendaApi.dpr` (one source, `.lpi` and `.dproj`), `src/Agenda.Schema` (SQL by name,
migrations: `SCHEMA_MIGRATIONS`, `TENANTS`), `src/Agenda.Database` (SQLite through
pascal-db-faa, readiness check). Middlewares: error handler, logger (JSON), metrics. Routes:
`/health/live`, `/health/ready` (database), `/metrics`, `/swagger`. `tools/http_scenarios.sh`
(15 checks) plus a second start that must apply no migration.

| Build | Result |
|---|---|
| FPC 3.2.2, Windows (lazbuild) | 15/15, second start ok |
| FPC 3.2.2, Linux (Docker, plain fpc) | 15/15, OpenAPI valid, promtool ok, second start ok |
| Delphi 12, Win32 / Win64 (built in the IDE) | 15/15 each; Win64 second start ok |

What setting it up as a consumer showed:

- The `.lpi` naming every package with `Prefer="True"` worked as documented: the build log
  has no path inside `external/pascal-api-infra-faa/external` (the library's own, empty,
  submodules).
- The middlewares' `{$I pascalapi.inc}` needs pascal-api-infra-faa's `src` as an include
  path; the guide says so (`docs/guide/getting-started.md`), it was missed here first.
- `promtool check metrics` fails on any application that uses pascal-db-faa's pool
  (`db_client_connection_count`, the "_count" lint). The library's
  `tools/promtool_check.sh`, which accepts only that lint, is used straight from the
  submodule. Its observability guide could say a consumer can do that.
- No unit tests yet: M0 has no logic of its own. The test project (DUnitX masters, FPCUnit
  mirrors) comes with M1's first logic (password hashing).

### M1 — in progress

**Unit tests**: `tests/Unit` (DUnitX masters, `Agenda.UnitTests.dproj`), mirrors generated in
`tests/Unit/fpc` by `tools/gen_fpc_mirror.py`; `tools/test_fpc.sh` (Windows) and
`tools/test_fpc_docker.sh` (Linux, in CI). `Agenda.groupproj` holds both Delphi projects.

**Password hashing** (`src/Agenda.Passwords`, a library candidate): PBKDF2-HMAC-SHA256 on
pascal-common-faa's HMAC, checked against RFC 7914 and the "password"/"salt" vectors
(Python's hashlib). 14 tests, 0 leaks, FPC Windows and Linux.

Measured on FPC 3.2.2 Win64 `-O2`, one hash of 600,000 iterations (OWASP's figure):

| Implementation | Time |
|---|---|
| on `PcHmacSha256` (4 compressions and 3 allocations per iteration) | 1.7–2.1 s |
| HMAC's inner and outer states computed once (2 compressions, no allocation) | 0.78–0.81 s |
| Python's `hashlib` (OpenSSL), for reference | about 0.3 s |

The faster form needs SHA-256's compression function, which is private to
`PascalCommon.Crypto`: it can only be written well **inside** pascal-common-faa. Moving the
unit there also needs a string-to-UTF-8-bytes function there (`PaStringToUtf8Bytes` is
pascal-api-infra-faa's).

Decided with the user (2026-10-18): optimize in pascal-common-faa. **pascal-common-faa 1.18.0**
adds `PcPbkdf2HmacSha256` (measured there: 210,000 iterations in 0.24–0.28 s, 600,000 in
0.74–0.88 s) and `PcStringToUtf8Bytes`; `Agenda.Passwords` keeps the stored form, the salt
and the checks on top of them, with a default of **210,000** iterations (raised later through
`NeedsRehash`). Its tests dropped the PBKDF2 vectors, which now live in pascal-common-faa.

Also found: `tools/test_http.sh` stopped the API with `taskkill /IM AgendaApi.exe`, which
also killed a Delphi build the user had running; it now stops only the executable it started,
by path.

**Login and refresh tokens** (2026-10-18): `src/Agenda.Auth` (service, no Horse),
`src/Agenda.Tokens` (ids and refresh tokens, unit-tested), `src/Agenda.AuthDtos`; migrations
3–5 (`USERS`, `JWT_KEYS`, `REFRESH_TOKENS`); routes `POST /auth/login`, `/auth/refresh`,
`/auth/logout`, `GET /me`; commands `--create-tenant`, `--create-user` (password from
`AGENDA_PASSWORD`), `--suspend-tenant`, `--resume-tenant`.

- Catalog: `TCachedTenantCatalog(TDbTenantCatalog)` on the one database; resolver: every tenant
  `shared`, the factory is the process's.
- Signing keys: `TTenantJwtKeyRing` on `TSealedJwtKeyStore(TDbJwtKeyStore)`, sealed with
  `JWT_KEYS_MASTER_KEY` (required unless `DEV_MODE=true`), no legacy secret. A token issued
  before a restart verifies after it (checked by both runners).
- Login: every wrong part (tenant, email, password, inactive user) is one 401
  `invalid_credentials` after the same PBKDF2 work (a dummy hash); a suspended tenant is told
  only after a right password (403 `tenant_suspended`); a weaker stored hash is replaced.
- Refresh tokens: `<tenant>.<secret>`, SHA-256 stored, used once; a spent token coming back
  revokes its family and is logged (`SECURITY ...`); two refreshes racing on one token: one
  wins, the family is revoked (an `UPDATE ... WHERE USED_AT IS NULL` that must match 1 row).
- Rate limit: `/auth/` by client address (`AUTH_RATE_LIMIT`, `TClientAddress.Resolve`), the rest
  by tenant, through the library's `KeyExtractor` and `LimitFor`: it worked as documented.

Checks: 15 unit tests; `tools/http_scenarios.sh` 77 checks (FPC Windows, FPC Linux in Docker),
plus the restart; OpenAPI valid, promtool ok. Delphi 12 Win32/Win64: 15 unit tests and 77 checks each, with the restart.

What building it showed about the libraries:

- **Bug (pascal-api-infra-faa):** `EValidationException.CreateFmt(...)` compiles (it is
  `Exception.CreateFmt`, inherited) and leaves `StatusCode` 0: the error handler answers
  `HTTP/1.1 0`, which curl refuses ("Unsupported HTTP/1 subversion"), and the access log says
  `"status":0` (measured on FPC Windows). The same for every `EHttpException` subclass.
  Neither the library nor its samples call it, so nothing caught it. Fix candidates: override
  `CreateFmt` in those classes, and/or have `MapException` answer 500 (and log) for a status
  outside 100–599. **Fixed** in pascal-api-infra-faa 0.17.0: both of those;
  `Required` here uses `CreateFmt` again.
- **Gap (pascal-api-infra-faa):** a handler can't refuse with a 401 the way the middlewares do:
  `EHttpException(401)` gets no `WWW-Authenticate` (HTTP requires one), and the error body has
  no room for a machine-readable code (`TenantRejection` builds `"code"` by hand). The API
  wrote both itself (`SendAuthError`). **Added** in pascal-api-infra-faa 0.17.0:
  `EUnauthorizedException`, a `Code` on `EHttpException`, `WWW-Authenticate` on every 401;
  `Agenda.Auth` raises them and `SendAuthError` is gone. The 77 checks pass unchanged.
- **Known gotcha, hit anyway:** `/auth/*)` in a `(* ... *)` comment closed it ("BEGIN expected").
  pascal-api-infra-faa's CLAUDE.md records it for its own units; a consumer meets it too.
- **pascal-db-faa:** a scope released without `Commit` is rolled back, even for a single
  statement without `StartTransaction`: every write starts and commits its transaction (read
  in `TScopeTransaction.Destroy`; caught before it bit).

**Services and professionals** (2026-10-18): `src/Agenda.Services`, `src/Agenda.Professionals`
(DTOs, ordering, a repository on the tenant's scope), `src/Agenda.Text` (search key, LIKE
pattern), `src/Agenda.Money` (Currency and cents); migrations 6–7. `GET /services`,
`/services/:id`, `POST`, `PATCH`, `DELETE`, and the same for `/professionals`: any user reads,
the owner writes (403 `owner_only`, from the token's `role`). Paging and ordering in SQL
(`TOrderBySpec`, `PdbPagingClause`) through `TTenantFilter.Prepare`'s `TSQLResult` overload.

- A service's name is unique within its tenant by its search key: `NAME_KEY`, lower case and
  Latin accents removed, computed in the application ("Corte de Cabélo" = "corte de cabelo"),
  the database's unique key answers 409. Search goes through the same key (`coloracao` finds
  "Coloração"), with `LIKE ... ESCAPE '\'` so a `%` typed is literal.
- Prices are cents in the database, Currency in JSON; a fraction of a cent is a 400.
- Professionals' email: absent, null (clears it on PATCH) or a value: the three optionals.

Checks: 24 unit tests; 153 HTTP checks (76 new in `tools/http_scenarios_catalog.sh`) on FPC
Windows and Linux, and Delphi 12 Win32/Win64; the runners now compare the schema version of the two starts instead of a
fixed number.

What it showed about the libraries:

- **pascal-common-faa, inconsistent API:** every optional's `From` returns its class
  (`TOptNullInteger`, `TOptNullString`...), which goes into any of its interfaces, but
  `TOptNullBoolean.From` returns `IOptNullBoolean` (cached instances), which doesn't go into an
  `IOptBoolean` ("Incompatible types", FPC). Worked around with `as IOptBoolean`, then with
  `TrueValue`/`FalseValue`, which return the class. The user's decision (2026-10-18): an
  oversight, kept for compatibility in 1.x and documented in pascal-common-faa 1.19.0; the fix
  waits in its `docs/plan.md`, "Planned for 2.0".
- **pascal-common-faa, small gap:** the optionals had no `ValueOr(default)`; every default was
  an `if HasValue`. **Added in pascal-common-faa 1.19.0** (`ValueOr` on every optional); the
  repositories here use it.
- **FPC gotcha (for the skill):** `Currency(92233720368547)`, a typecast of an integer literal,
  reinterprets the bits on FPC 3.2.2 for Linux x86_64 (9223372036.8547) and converts on FPC for
  Windows (measured by `Agenda.MoneyTests`). pascal-db-faa's gotcha 18 is the other direction
  (`Double(Currency)`). A typed constant is the same on both.
- **Candidates:** an accent-insensitive search key and a literal LIKE pattern (pascal-common-faa
  has normalizers, none of these); and filling a Find DTO from the query string: every list
  handler copies each member by hand (`ParseQueryInt`/`ParseQueryStr` per member), while
  pascal-api-infra-faa already reads the DTO's members for `QueryParams<T>` in OpenAPI.
- Writing these files through scripts lost backslashes twice (an `ESCAPE ''\''` became `''''`,
  a sed `\1` became a control character): the HTTP checks caught the first, a scan for control
  characters the second.

**DTO convention, pascal-api-infra-faa 0.18.0** (2026-10-19): every DTO interface mirrors its
class's published properties, read-only (`property Name: string read GetName;`); the response
DTOs gained getters; the Find DTOs lost `SetActive` and are filled through the class while the
interface holds them (`LFill := TServiceFind.Create; LFind := LFill; LFill.Active := ...`).
Repositories read `AFind.Active`, `APatch.Name` instead of the getters. 153 HTTP checks unchanged
on FPC Windows.

**Customers and users** (2026-10-19): `src/Agenda.Customers`, `src/Agenda.Users`; migrations
8 (`CUSTOMERS`) and 9 (`USERS.PROFESSIONAL_ID`, `USERS.UPDATED_AT`, a unique index on the link);
`NormalizePhone`/`TryPhoneDigits` in `src/Agenda.Text`. Routes `/customers`, `/customers/:id`,
`/users`, `/users/:id` (GET, POST, PATCH, DELETE).

- Customers: any user reads, creates and changes (the front desk registers customers); the owner
  deletes. Name required; phone and email optional, neither unique (a family shares a phone):
  public booking (M3) decides how it finds a returning customer. Phone stored as `+` and 8 to 15
  digits. Search through one stored key, `SEARCH_KEY` = `NAME_KEY|EMAIL|digits`: a search typed
  like a phone matches by its digits, anything else is folded like a name. A PATCH reads the row
  and writes it whole, so the key always follows the values.
- Users: the owner only. The owner sets the password (at least 8 characters, `password_too_short`);
  it is never returned. A new password or a deactivation revokes the user's refresh tokens
  (`REFRESH.REVOKE_USER`); deleting a user deletes them first (the foreign key, enforced on
  PostgreSQL). A user may be one professional and a professional at most one user (409);
  an unknown professional is 400 `unknown_professional`; deleting the professional unlinks the
  user. The acting owner can't change their own role, deactivate or delete themselves (409
  `own_account`), so a tenant keeps an active owner. **Known gap:** two owners demoting each
  other at the same moment could leave none; a guarded `UPDATE` (another active owner exists)
  closes it if it matters.
- `--create-user` writes the new columns (no professional).

Checks: 28 unit tests (4 new, the phone) on FPC Windows and Linux; 247 HTTP checks (94 new in
`tools/http_scenarios_people.sh`) on FPC Windows and Linux (Docker), plus the restart; OpenAPI
valid, promtool ok. Delphi 12 Win32/Win64: 28 unit tests (0 leaks) and 247 checks each, with the
restart.

What it showed about the libraries:

- The 0.18.0 DTO convention held on four more DTO families with nothing new to learn; the read-only
  interface made the repositories read `APatch.Phone`, `AFind.Role` naturally.
- **Candidate, stronger now:** filling a Find DTO from the query string. Four list handlers copy
  `page`, `limit`, `orderBy`, `search` by hand, plus their own filters.
- **Candidate (probable):** the paged query. Four repositories repeat the same `FindPage`: the
  count and the page through the same tags and binds, the order spec, `PdbPagingClause`, reading
  the rows. A helper taking the two SQL names, a "filter" callback and a row reader would fit
  pascal-api-infra-faa (it already joins `TTenantFilter`, `TOrderBySpec` and paging).
- **Candidate:** phone normalization (digits, `+`, length) next to the search key in
  pascal-common-faa's normalizers.

**Working hours and time off** (2026-10-19): `src/Agenda.WorkingHours`, `src/Agenda.TimeOff`,
`src/Agenda.Times` (clock times, instants, the week's check; unit-tested); migration 10
(`WORKING_HOURS`, `TIME_OFF`). Routes: `GET`/`PUT /professionals/:id/working-hours`,
`GET`/`POST /professionals/:id/time-off`, `GET`/`DELETE /professionals/:id/time-off/:offId`. Any
user reads, the owner changes.

- Working hours are the tenant's **local clock**, `{"weekday":1,"from":"09:00","to":"12:00"}`
  (ISO weekday), so "09:00 on Mondays" survives a daylight-saving change; M2 turns them into
  instants. The week is read and replaced whole: checked first (5-minute steps, `from` before
  `to`, up to 24:00, no overlap within a day, at most 70 intervals; 400 `invalid_week` naming
  the problem), then written in one transaction that starts by touching the professional's row
  (404 when gone; on PostgreSQL a row lock, so two PUTs don't mix). A night shift is two
  intervals.
- Time off is **instants**: ISO 8601 that must carry `Z` or an offset (400 `invalid_instant`),
  stored as Unix seconds, written back in UTC with `Z`; whole minutes, at most 366 days; spans may
  overlap; created and deleted, never changed. The list filters by the span it overlaps
  (`from`/`to`, both exclusive at the edges) and is reached only through its own professional.
- Deleting a professional deletes its week and its time off in the same transaction.

Checks: 41 unit tests (13 new) on FPC Windows and Linux; 319 HTTP checks (72 new in
`tools/http_scenarios_schedule.sh`) on FPC Windows and Linux (Docker), plus the restart; OpenAPI
valid. Delphi 12 Win32/Win64: 41 unit tests (0 leaks) and 319 checks each, with the restart.

What it showed about the libraries:

- **Gap (pascal-jsonmapper-faa):** a `TDateTime` member can't carry an instant. Its reader takes
  `"2026-12-24T13:00"` without a zone as is (it can't say a zone was missing) and its writer puts
  no zone back, so a client reading a UTC value can't tell it from local time. The API carries
  instants as strings through `Agenda.Times` (zone required, `Z` written, built from Unix
  seconds with integer arithmetic). **Candidate:** an instant type in the mapper (a UTC
  `TDateTime` or Unix seconds that writes `Z` and refuses a text without a zone), with
  `date-time` in the OpenAPI document.
- `RenameMember` for a member named after a Pascal keyword (`to`, property `To_`) worked as
  documented, and the OpenAPI document followed it (it reads the mapper's names).
- Arrays of DTOs as a published member (`intervals`) mapped both ways on both compilers.
- The paged query is now in five repositories (see the candidate above).

**Candidates promoted to the libraries** (2026-10-19, the user's decision: "attack the
candidates"). Built there with their own tests, then adopted here against the new commits:

| Candidate | Library | What it replaced here |
|---|---|---|
| Search key | pascal-common-faa 1.20.0 `PcFoldForSearch` | `Agenda.Text.FoldForSearch` |
| LIKE pattern | pascal-db-faa 0.16.0 `PdbLikeContains`, escape `!` | `Agenda.Text.LikeContains` and `ESCAPE ''` |
| Instant type | pascal-jsonmapper-faa 0.7.0 `TUtcDateTime` | time off's `startsAt`/`endsAt` as strings, `Agenda.Times`' parser and writer |
| Find DTO from the query string | pascal-api-infra-faa 0.19.0 `THorseQueryParams.Read<I>` | five handlers copying each member, `ParseQueryBool`, `ParseQueryRole` |
| Paged query | pascal-api-infra-faa 0.19.0 `TTenantPagedQuery.Run<T>` + `TQueryArgs` | five `FindPage` bodies (about 35 lines each) |
| Refresh tokens (core) | pascal-api-infra-faa 0.19.0 `TRefreshTokens` + `TDbRefreshTokenStore` | `Agenda.Tokens`' format, parse and hash, and `Agenda.Auth`'s issue, rotate, reuse/race revocation and logout |

The phone stays here (`Agenda.Text`): pascal-common-faa's normalizers leave business rules to the
application.

- **Bug found while promoting** (pascal-db-faa's gotcha 26, already documented there): with
  `ESCAPE ''`, SQLdb's SQLite3 and PostgreSQL connectors read `'` as an escaped quote while
  looking for parameters and lose every parameter after it. `GET /services?search=c&active=true`
  and `GET /users?search=demo&role=staff` answered **500** (`Parameter "ACTIVE" not found`,
  measured on FPC Windows); no scenario combined a search with a filter. Now `ESCAPE '!'` through
  `PdbLikeContains`, and two scenarios combine them. The library's documentation had the warning
  as text and a `StringReplace` chain to copy; a function that carries the escape is what keeps a
  consumer from it.
- Time off's `startsAt` without a zone is now refused by the mapper (`startsAt: Invalid UTC
  date/time ...`, 400) instead of this API's `invalid_instant` code; the query's `from`/`to` keep
  `invalid_instant` (read by `TryParseInstant`, now on the mapper's parser).
- An invalid query value keeps its 400 and message (`"active" must be true or false.`, the
  library's `InvalidQueryBoolean`, the same text as before).

- Refresh tokens: the user chose the core only (2026-10-19). What stays here is the tenant
  checked against the catalog before any lookup (suspended: 403) and the access token's claims;
  the user check is `UserActive`. The `REFRESH.*` SQL now names `TENANT_ID = :TENANT_ID` (the
  store's contract; `TTenantFilter.Prepare` binds it too when `Agenda.Users` revokes a user's
  tokens). The security line says "of scope demo" (was "of tenant demo"). Login no longer issues
  the token in the rehash's transaction: each store call is its own (the library's rule).

Checks: 31 unit tests (6 search-key and LIKE tests and 4 refresh-token tests moved to the
libraries); 323 HTTP checks (4 new) on FPC Windows and Linux, OpenAPI valid; Delphi 12 Win32/Win64:
31 unit tests (0 leaks) and 323 checks each, with the restart. Released 2026-10-19:
pascal-common-faa v1.20.0, pascal-jsonmapper-faa v0.7.0, pascal-db-faa v0.16.0 and
pascal-api-infra-faa v0.19.0 (each green on Delphi 12 Win32/Win64 too: 342, 135, 217 and 380
unit tests; api-infra's samples 195 + 95 + 107 + 31 checks); the submodules pin those tags.
pascal-api-infra-faa v0.19.1 (2026-10-19) followed: a sample and a guide for the refresh tokens,
which found a race in `TRefreshTokens.Rotate` (the loser's revoke could land before the
winner stored its next token, leaving a live token of a revoked family; now the winner reads the
spent token again and refuses). This API pins it: 31 unit tests and 323 HTTP checks on FPC
Windows and Linux.

**Repositories: normalize, then validate, then bind the optionals** (2026-10-19, the user's
review, in the shape of pascal-api-infra-faa's guide "DTOs and JSON"):

1. **Normalize** with the API's factory `TNorm` (`src/Agenda.Normalizers`, a
   `TPcStringNormalizers` descendant: `DisplayName`, `Email`, `Phone`, plus the library's `Trim`,
   `Lower`, `FoldForSearch`...), inside the optionals: `TOptionals.Normalize(APatch.Name,
   TNorm.DisplayName)`; a plain value with `TNorm.Email.Apply(...)`. A normalizer never refuses:
   what can't be made right comes out as it went in.
2. **Validate** with `src/Agenda.Validation` (`ValidateName`, `ValidateEmail`, `ValidatePhone`) and
   each repository's own rules (`ValidateDuration`, `ValidatePrice`, `ValidateRole`,
   `ValidatePassword`, `ValidateProfessional`): checks that change nothing and raise a 400, one
   overload per shape (a required string, an `IOptString` checked when it came, an `IOptNullString`
   checked when it came with a value). The `if HasValue` lives inside the rule, once.
3. **Bind** the optional as it is (`OptStrings`, `OptNullStrings`, `OptIntegers`, `OptBooleans`)
   next to a `ProcessTag` on the same `HasValue`, in UPDATEs and INSERTs (an absent contact leaves
   its column out; the database writes NULL).

The password hash, a transformation that needs the iterations, is a normalizer object
(`THashPassword`) taken by `Normalize` after `ValidatePassword`. Customers keep reading the row
before an update (the search key depends on every column), merged with `ValueOr` and `Merged`.
Behaviour change: names now collapse inner runs of blanks (`TNorm.DisplayName`). `NormalizeEmail`
moved from `Agenda.Auth` to `Agenda.Text`. 40 unit tests (9 new: `Agenda.NormalizersTests`); 323
HTTP checks unchanged on FPC Windows and Linux.

Found while doing it (candidates, not built):
- `Map` keeps the type: an `IOptCurrency` price can't become the `IOptInt64` of its cents, so
  that member keeps one `if`. A cross-type map (or `OptInt64s` from a function) would remove it.
- "What came, else what is stored" for a nullable member (`Merged` here): an
  `IOptNullString` over an `INullString`. `ValueOr` covers a non-nullable one; the nullable case
  needs a combinator (absent -> the stored value, null -> null, value -> value).
- pascal-api-infra-faa's sample 02 says a normalizer shouldn't validate (it would hide a
  mistake); that holds for `Normalize`. A check that raises goes through `Map`, which says what it
  is. The guide could tell the two apart.

**Shared test kit**: the DUnitX-to-FPCUnit adapter (`*.DUnitXCompat.pas`) and
`gen_fpc_mirror.py` exist as near-identical copies in pascal-common-faa, -jsonmapper-faa,
-db-faa, -redis-faa, -api-infra-faa and three other projects; this is the eighth. A
candidate for one shared copy (a `testing/` folder in pascal-common-faa, or the skill).

## Validation from the libraries (F3, 2026-10-19)

On pascal-common-faa 1.21.0 (`PascalCommon.Validators`) and pascal-api-infra-faa 0.20.0, the
phase F3 of their `docs/validation-design.md`. Step 2 of "normalize, then validate, then bind"
changed shape:

- **The document's limits are enforced at the edge.** The handlers read bodies with
  `THorseBody.Read<I>(AReq)` (services, professionals, customers, users, working hours, time off;
  the auth routes keep `FromJson`), and `THorseQueryParams.Read` already ran the same check. Added
  to the `Describe` declarations so each limit is written once: the price's `Maximum(100000)`, the
  patch's duration, buffer and price ranges, the password's `MinLength(8)`, the role's
  `Enum([owner, staff])` (insert, patch and the `role` filter). Gone from the repositories:
  `ValidateDuration`/`ValidateBuffer`/`ValidatePrice` ranges, `ValidateRole`, `ValidatePassword`,
  the name's 100 characters, the reason's 200.
- **What the document can't say** is `src/Agenda.Validators` (`TValid = class(TPcStringValidators)`:
  `DisplayName`, `Email`, `Phone`) plus the library's `TPcIntegerValidators.MultipleOf(5)` and
  `TPcCurrencyValidators.MaxDecimals(2)`, run through `TPcValidation` after normalizing. One
  `Check` per member whatever its shape (the "absent or null: not checked" rule is the library's),
  `Fail` for a rule with context (`CheckProfessional`, the time off's span), `RaiseIfAny` once.
  `src/Agenda.Validation` (three overloads per rule) is deleted.
- **One 400 lists every failing field**: `{"error": <first message>, "code": "invalid_fields",
  "fields": [{field, code, message}]}`. Changed codes: `name_required` is now the field's
  `required`, `password_too_short` the document's `too_short`, `unknown_professional` moved into
  `fields`. `own_account` and `invalid_week` stay single refusals (`EValidationException`).

Observed: the edge checks the value as it came, so a time off's reason of 200 characters plus
blanks around it is now refused (it was trimmed first); the edge also answers before the
repository, so a request that breaks a limit and a rule hears of the limit only. 40 unit tests
(`Agenda.NormalizersTests` tests `TValid` and the collector); 333 HTTP checks (10 new: three
fields wrong at once, the document's ranges, the role's enum in a body and in the query) on FPC
Windows and Linux, OpenAPI valid; Delphi 12 Win32/Win64: 40 unit tests (0 leaks) and 333 checks each.

## Migrations on two dialects (M1, 2026-10-19)

The API runs on SQLite or PostgreSQL 17, chosen by `DB_ENGINE` (`src/Agenda.Database`: the
adapters' connection names for each engine; `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`,
`DB_PASSWORD`, `PG_CLIENT`). The ten migrations and every statement ran unchanged on PostgreSQL:
the schema already kept to the common ground (VARCHAR, INTEGER, BIGINT, TIMESTAMP; Unix seconds,
cents, INTEGER flags; paging through `${PAGE}`), and pascal-db-faa's SQLite adapters turn foreign
keys on, so the deletes were already in the order PostgreSQL enforces.

**SQL directories: common, plus each engine's overrides** (2026-10-20, after asking the user).
pascal-db-faa's loader reads `<SQLDirectory>/<KEY>`, one directory per database and no fallback,
so the choice was two identical copies of every statement, or one directory for both with no
place for a statement that has to differ. The user chose a fallback: `src/Agenda.SqlSources`
(`TFallbackSqlSource`) asks the engine's directory (`SQLITE` or `PG`, the factory's
`SQLDirectory`) and, when the key isn't there, `COMMON`. Every statement is in `COMMON` today;
an override goes under `PG` or `SQLITE` with the same key, and the not-found message names both
places. A unit test checks every migration resolves from both directories; the CI runs both
engines, so an override that breaks one of them breaks the build.

The scripts: `DB_ENGINE=postgresql sh tools/test_http.sh` (a throwaway `postgres:17` container on
port 55433, the newest local `libpq.dll`), `DB_ENGINE=postgresql sh tools/test_http_docker.sh` (a
container on a private network; the Linux image gains `libpq5`); `tools/ci-test.sh` runs both
engines. `--reset` stays SQLite's (it deletes the file).

What the first PostgreSQL run found:
- **Flags**: every PATCH with `active` answered 500. `Params.OptBooleans` sends a boolean, which
  PostgreSQL refuses for an `INTEGER` column. Now `Params.OptIntegers['ACTIVE'] :=
  OptFlag(APatch.Active)` (`src/Agenda.Flags`), the filters `FlagOf`. The skill's
  repository-patterns said `Booleans` into an integer column works everywhere, citing the
  contract suite, which never binds one: corrected.
- **The refresh race** (pascal-api-infra-faa 0.20.0): two refreshes on one token left the winner's
  next token alive in 4 of 7 runs on Linux. The loser's family revoke, under READ COMMITTED, took
  its snapshot before the next token was committed and committed after the winner's re-read (the
  0.19.1 guard). Fixed in the library, 0.20.1: the token marked used and the next one stored in
  one transaction (`IRefreshTokenAtomicRotation`), so the loser waits for the winner's commit. 6
  of 6 clean runs after.

Result: 48 unit tests (8 new: `Agenda.SqlSourcesTests`); 333 HTTP checks on SQLite and on
PostgreSQL 17, FPC Windows and Linux, with the restart (no migration on the second start, a token
from before it verifies); OpenAPI valid. Delphi 12: 48 unit tests (0 leaks) and 333 checks on
SQLite, Win32 and Win64, and 333 on PostgreSQL, Win64 (no 32-bit libpq); on pascal-api-infra-faa
v0.20.1.

**On pascal-db-faa 0.17.0 and pascal-api-infra-faa 0.21.0** (2026-10-20). Both candidates of the
PostgreSQL run came back from the libraries, so the application's copies went: `Agenda.Flags`
(the PATCHes bind `Params.OptFlags['ACTIVE'] := APatch.Active`, the filters
`TQueryArgs.Flags('ACTIVE', ...)`, an Integer 1/0 either way) and `Agenda.SqlSources` (the schema
uses pascal-db-faa's `TFallbackSqlSource`, same behavior; its 7 tests moved to the library, the
schema's own test stays). Measuring the Booleans in the library found more than PostgreSQL's
refusal: SQLdb on Firebird stored `True` as -1 and Zeos sent `'Y'` (gotcha 54 there), which this
application never met (SQLdb, SQLite and PostgreSQL). Result: 41 unit tests; 333 HTTP checks on
SQLite and on PostgreSQL 17, FPC Windows and Linux. Delphi 12: 41 unit tests (0 leaks) and 333
checks on SQLite, Win32 and Win64, and 333 on PostgreSQL, Win64.

**On pascal-common-faa 1.22.0** (2026-10-20): `PascalCommon.TimeZones`, IANA time zones on both
compilers from an embedded tzdb (2026e), designed for this application's free slots
(`docs/timezones-design.md` there). Used so far in one place: `--create-tenant` refuses a name
that isn't a zone, exact case (`america/sao_paulo` is refused with "did you mean
"America/Sao_Paulo"?"), since the free slots of M2 are computed in it and a typo would surface
only at booking. The seed checks both refusals. M2 uses `ToUtc` (the working hours' local clock
to instants, the daylight-saving gap and overlap by the library's defaults), `DayBounds` (a
date's availability) and `ToLocal`. Result: 41 unit tests; 333 HTTP checks on SQLite and on
PostgreSQL 17, FPC Windows and Linux. Delphi 12: 41 unit tests (0 leaks) and 333 checks on
SQLite, Win32 and Win64, and 333 on PostgreSQL, Win64.

## M2 — free slots (2026-10-20)

`GET /professionals/:id/availability?service=&date=&days=`: the starts where a service fits,
on the tenant's local days (`date`, YYYY-MM-DD, for `days` days, 1 to 14). Any user reads. The
computation is `src/Agenda.Slots` (no database, no HTTP; unit-tested), the reads
`src/Agenda.Availability`.

- **Working hours to instants** in the tenant's zone (`TENANTS.TIME_ZONE`), each local day's
  intervals through `IPcTimeZone.ToUtc` with `gapStartOfAfter` and `overlapEarlier` (the rules
  of its `DayBounds`): an edge in a gap becomes the jump (02:00-05:00 on the day 02:00 doesn't
  exist starts at 03:00), an edge in an overlap takes the first occurrence (00:00-03:00 on the
  day the clock goes back is four real hours, as worked). Intervals that touch in instants join,
  so a night shift written as 22:00-24:00 plus 00:00-02:00 takes a service across midnight; a
  slot belongs to the day it starts on.
- **Starts every 15 minutes of real time** from the start of each span (`SLOT_STEP_MINUTES`),
  the same grid on both sides of a transition. A start is free when the service ends inside the
  span and the service plus its buffer meets nothing busy; the buffer may run past closing.
  Starts before now are left out.
- **Busy**: the professional's time off (`TIME_OFF.OVERLAPPING`); appointments join with the
  booking, next.
- Each slot has `startsAt`/`endsAt` in UTC and `local`, the tenant's clock with its offset
  (`2027-10-31T01:00:00+01:00`, then `+00:00` an hour later), so a client needs no time zone
  database. `endsAt` is the service's end, the buffer not counted.
- An inactive professional or service is a 409 (`professional_inactive`, `service_inactive`):
  something that can't be booked is not a full day. A missing `service` or `date` and an invalid
  date come in one 400 (`invalid_fields`); `days` outside 1-14 is the document's limit, enforced
  by `THorseQueryParams.Read`; a date more than 366 days from today is `date_out_of_range`.

Tests: `Agenda.SlotsTests` (16) on New York's 2026-11-01 (25 h) and 2027-03-14 (23 h), expected
instants from Python's zoneinfo: four real hours in 00:00-03:00 and three in 00:00-04:00, a start
in the gap, the night shift, the buffer around a busy span, starts before now, the local reading
with both offsets of 01:30 and Kathmandu's +05:45. `tools/http_scenarios_availability.sh` (50
checks): the hours, the time off and the buffer for tenant demo (America/Sao_Paulo), the query's
failures, the 404s and 409s, another tenant, and tenant other (Europe/Lisbon) on the next last
Sundays of March (five starts in 00:00-03:00: 00:45 WET then 02:00 WEST) and October (thirteen,
from 23:00Z the day before, 01:00 twice). Its dates come from today (GNU date), so it doesn't
expire. Result: 57 unit tests; 383 HTTP checks on SQLite and on PostgreSQL 17, FPC Windows and
Linux. Delphi 12: 57 unit tests (0 leaks) and 383 checks on SQLite, Win32 and Win64, and
383 on PostgreSQL, Win64.

What it showed:
- pascal-common-faa 1.22.0's `PascalCommon.TimeZones` covered every need of the computation:
  `ToUtc` with the rules named, `DayBounds` for the window, `ToLocal`/`OffsetAt` for the local
  reading. **Small candidate** (pascal-common-faa): an instant written as ISO 8601 with its
  offset in a zone (`LocalIso` here: `TPcLocalDateTime.ToString` plus the offset); any API that
  shows a local time needs it.
- **Small candidate** (pascal-api-infra-faa): `TRouteDoc.QueryParams<>` documents a non-optional
  member (`service: string`) as `required`, but `THorseQueryParams.Read` takes its absence as ''
  without a word, so the handler checks it again. Read could refuse a missing required member
  with the same `required` failure the body validation gives.
- The accented service name the scenario first used ("Coloração") reached the API mangled from
  Git Bash's curl (its arguments go through the ANSI code page, as pascal-api-infra-faa's
  CLAUDE.md says) and collided only on Linux; the scenario uses an ASCII name.

### M2 — booking, the database's word (2026-10-20)

`POST /appointments` (`professionalId`, `serviceId`, `customerId`, `startsAt`), `GET
/appointments/:id`, `GET /appointments?professional=&status=&from=&to=&page=&orderBy=`; any user
books and reads. `src/Agenda.Appointments`, migration 11 (`APPOINTMENTS`).

- **No double booking without Redis**: one transaction that starts by touching the professional's
  row (`PROFESSIONAL.TOUCH`: a row lock on PostgreSQL, the one write lock on SQLite), then
  computes that local day's free starts on the same connection (`FreeStartsOn`, shared with the
  availability route) and inserts only if `startsAt` is one of them, else 409
  `slot_unavailable`. Time off and a new week touch the same row, so they can't slip in between
  either. The Redis lock (the decision: `SetNx` around the booking) comes next, as an optional
  layer in front of this, so development stays without Docker.
- So a start must be what the availability lists: inside the hours, on the grid, not past, the
  service and its buffer clear of time off and other appointments. The availability now counts
  appointments that aren't cancelled, each until `BUSY_UNTIL_UTC` (its end plus the buffer the
  service had when booked: a later change to the service doesn't move it).
- Unknown ids in the body are a 400 naming each member (`unknown_professional`,
  `unknown_service`, `unknown_customer`), all in one answer; an inactive professional or service
  is a 409, as in the availability. The foreign keys keep a booked service, customer or
  professional from being deleted (409, the library's mapping).
- `FreeStartsOn` and the reads under it take the caller's query: the booking makes them on the
  connection that holds the lock (a second connection from the pool while holding one could wait
  forever on a small pool).

Scenarios (`tools/http_scenarios_appointments.sh`, 43 checks): a free slot booked and the
availability shrinking by the slot and its buffer; the same slot, a start inside the buffer, off
the grid, past closing, into time off, in the past, on a day without hours (409); **four requests
for one slot fired at once: one 201, three 409** (and two appointments stored, not five); the
body's failures in one 400; another tenant's ids unknown; reading, filters, ordering; deletes
refused. Result: 57 unit tests; 426 HTTP checks on SQLite and on PostgreSQL 17, FPC Windows and
Linux (PostgreSQL three times on Windows, both engines twice on Linux). Delphi 12: 57 unit tests (0 leaks)
and 426 checks on SQLite, Win32 and Win64, and on PostgreSQL, Win64 (twice). What wasn't measured: that
the four requests overlapped inside the server every time; the outcome is checked, not the
interleaving.

