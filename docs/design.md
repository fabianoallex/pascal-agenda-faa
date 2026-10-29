# pascal-agenda-faa — design

Status: scope agreed with the user on 2026-10-18. M0 to M5 built (see "Progress" and the
milestone sections after it); M5 closed 2026-10-28. M6 designed 2026-10-28 ("M6: design").

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

Public (rate limited, tenant from the path slug — see decision 2; the routes as built in
"M3: design (2026-10-21)", which moved the availability under its professional and put the
slug in the signed link's path):

- `GET /public/{slug}/services`, `GET /public/{slug}/professionals`
- `GET /public/{slug}/professionals/{id}/availability?service=&date=&days=`
- `POST /public/{slug}/appointments` (`Idempotency-Key` required)
- `GET /public/{slug}/appointments/{id}?exp=&sig=`,
  `POST /public/{slug}/appointments/{id}/cancel?exp=&sig=` (signed link)

Operations: `/health`, `/metrics`, `/openapi.json`, `/mcp`.

## Processes and infrastructure

- **api**: Horse, every pascal-api-infra-faa middleware, OpenAPI and MCP.
- **worker**: consumes AMQP (pascal-amqp-faa); sends confirmations and reminders; a scheduler
  with a lease (one instance runs each reminder).
- **Outbox relay**: in the api or the worker; reads `outbox` and hands each event to a sink (AMQP here; see "Library candidates").
- Development: SQLite, no Docker needed for the api alone.
- `docker compose`: PostgreSQL, Redis, RabbitMQ, Mailpit (fake SMTP), OpenTelemetry
  Collector, Prometheus, Grafana; api and worker built with plain `fpc` on Linux.
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
| M6 | Desktop client sharing the server's DTOs: VCL (Delphi) and LCL (Lazarus) from one source, screens built in code with OPCB | Typed HTTP client, refresh, DTO reuse |
| M7 | Review of the library candidates still in this application (see "Library candidates") | Which pieces are worth a library without a second case |

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
| `Idempotency-Key` middleware: replay, 409 while in flight, 422 on another body | `PascalApi.Idempotency` + Horse, db/Redis store | same pluggable-store shape as the JWT keys; **built here 2026-10-21** as `src/Agenda.Idempotency` (memory and database stores, 9 unit tests), see "M2: Idempotency-Key". **Done** in pascal-api-infra-faa 0.23.0 (`PascalApi.Idempotency`, `THorseIdempotentRequest`); adopted 2026-10-21 ("Candidates promoted (2026-10-21)") |
| Optimistic concurrency: `ETag`/`If-Match`, 412/428 | `PascalApi.Http` + middleware | small; **built here 2026-10-21** as `src/Agenda.Preconditions` (RFC 9110 parsing, 6 unit tests), see "M2: changing and cancelling". **Done** in pascal-api-infra-faa 0.23.0 (`PascalApi.Preconditions`, no middleware); adopted 2026-10-21 |
| Tenant from the path or host | `PascalApi.Tenancy` | multi-tenancy decision 5; **built here 2026-10-21** as `src/Agenda.PublicTenancy` (the path's slug; unknown and suspended one 404), see "M3: design" |
| Signed links: HMAC with expiry | `PascalApi.SignedUrl` | cancel, invite, email confirmation. Not the JWT key ring (user, 2026-10-21: its keys retire in about 30 days, a link may need a year); keys of its own, derived per tenant. **Built here 2026-10-21** as `src/Agenda.SignedLinks`, see "M3: design" |
| IANA time zones on both compilers | pascal-common-faa | **biggest risk**: neither RTL converts an arbitrary zone. Linux has `/usr/share/zoneinfo`; Windows has the registry (Windows names) or an embedded database. Own design phase before M2. **Done in pascal-common-faa 1.22.0** (`PascalCommon.TimeZones`, the tzdb embedded); adopted 2026-10-20 |

**Probable** (a second case should confirm the shape):

A candidate moves with a second case **or at the final review (M7)**, decided by the user
(2026-10-27). The review looks at each candidate still here and records one decision per
candidate (promote, keep in the application, drop) with these criteria:

- Use inside this application: more than one place (another job on the lease, another
  consumer on the outbox) counts as a case.
- Generality: the unit depends only on the libraries, with no agenda rule left in it.
- Stability: its API unchanged across the milestones since it was written.
- The cost of keeping it here: how much another application would copy, and how easy it is to
  copy wrong (the outbox's retry, dead queue and dedupe: large; the stop signal: small but
  platform details).
- The destination: which library, and whether it adds a dependency between libraries (the
  AMQP sink needs a bridge).

- Transactional outbox + relay (the dual write problem). Shape discussed with the user on
  2026-10-23, built here in M4 as `src/Agenda.Outbox` (the core and the local sink, 11 unit
  tests; 2026-10-26, see "M4: the outbox core"), and its broker sink as
  `src/Agenda.Outbox.Amqp` (2026-10-26, see "M4: the broker, the compose file, the trace"),
  with metrics of its own since M5 (see "M5: the metrics and the dashboards"):
  - **Core**, on pascal-db-faa only: `Enqueue` writes one row per event (type, payload, trace
    context) in the caller's transaction; a polling relay reads a batch and hands each event to
    an `IOutboxSink`, then marks it delivered. Delivery is at-least-once: consumers deduplicate
    by the event id. The table and its SQL are the application's, as with `PascalApi.Idempotency`.
    Per dialect: claiming a batch with several relays (`FOR UPDATE SKIP LOCKED` on PostgreSQL and
    MySQL 8, `READPAST` on SQL Server, a lease on Firebird and SQLite).
  - **Broker sink**: publishes each event once (a fanout/topic exchange; one queue per
    consumer, each keeps its own state). Needs pascal-amqp-faa, so a bridge (`src/amqp` in
    pascal-api-infra-faa, or a bridge in pascal-amqp-faa); Redis could be another sink.
  - **Local sink** (no broker): a dispatcher with a handler per event type, run in the relay's
    process; one `outbox_deliveries` row per event and handler (status, attempts, last error),
    so a failing handler neither blocks nor re-runs the others.
  - The `outbox` table is the same for both sinks: an application can start with the local one
    and move to a broker without changing the code that writes events.
  - Not a sink: a side effect such as email belongs to a handler or a consumer, not to the
    transport (a sink sees every event; SMTP can't deduplicate; a slow server would stall the
    relay). Out of scope: CDC (reading the database log, as Debezium does); polling is enough.
- Scheduler with a lease (Redis `SetNx` or a database row): the core in pascal-common-faa.
  **Built here 2026-10-26** as `src/Agenda.Leases`, one interface with a database store (the
  default) and a Redis one (`TRedisLock`); see "M4: the worker".
- RFC 9457 errors (`application/problem+json`) as an option of `TErrorHandlerMiddleware`.
- Typed HTTP client for Delphi/Lazarus with refresh, retry and trace propagation (M6; its shape
  in "M6: design", decisions 4 to 7). Its transport **built here 2026-10-29** as
  `src/Agenda.HttpTransport` (`IHttpTransport`, each compiler's own client, the third copy of
  that switch) with a fake, `src/Agenda.HttpTransport.Fake`; see "M6: the HTTP transport".
  The client over it **built here 2026-10-29** as `src/Agenda.HttpClient`, and the session's
  tokens as `src/Agenda.HttpSession`; see "M6: the generic client" and "M6: the session".

**Found while building** (not in the first list):

- Filling a Find DTO from the query string, and the paged query (count + page through the same
  filters): both repeated in every list route (see "Progress", M1, customers and users).
- Phone normalization, next to the accent-insensitive search key (pascal-common-faa).
- Percent-encoding a query string's values (RFC 3986, UTF-8 bytes): pascal-api-infra-faa's
  `McpUrlEncode` is private to the MCP unit, so the client wrote its own, `ApiQueryEscape` in
  `src/Agenda.HttpClient` (M6): the second copy (pascal-common-faa).
- Background work for a screen with its result back on the UI thread, on `PcPool`: a task
  with `Run` (pool thread) and `Done` (UI thread, via `TThread.Queue`), `Forget(owner)` so a
  late answer never reaches a freed view model, `WaitIdle` for `OnCloseQuery`, and a manual
  runner for tests (pascal-common-faa, next to the pool; FPC 3.2.2 has no closures, so a task
  is an object). **Built here 2026-10-29** as `src/Agenda.Desktop.Tasks` (M6).
- A package of pascal-api-infra-faa's units a client needs (`PascalApi.Dto`, `PascalApi.OpenApi`,
  `PascalApi.OrderBy`, `PascalApi.Text`): `pascal_api_infra_faa.lpk` requires `pascal_db_faa`,
  so the desktop client's `.lpi` takes the library's `src` as a search path instead (M6).
- A console program's stop request: Ctrl+C, Ctrl+Break and the console closing on Windows,
  SIGINT and SIGTERM on Unix, as a flag the main loop reads, and a sleep that wakes on it
  (pascal-common-faa). No library has it: the amqp, redis and pipes samples stop on Enter or
  are killed. **Built here 2026-10-26** as `src/Agenda.StopSignal` (the worker; SIGTERM checked
  on Linux by the HTTP scenarios); the api uses it too since M5 (a second case, with an FPC
  gotcha: block the signals on the thread that accepts, "M5: under load").
- `Connection: close` on FPC 3.2.2 (its server closes every connection without saying so),
  pascal-api-infra-faa or Horse: found 2026-10-27 under load, "M5: under load".
- An `Idempotency-Key` completed after the caller's commit can fail on its own (no pool
  connection): the client gets a 5xx for a change that was made. pascal-api-infra-faa's
  `THorseIdempotentRequest`; found 2026-10-27 under load, "M5: under load". **Fixed there**
  in 0.27.0 (2026-10-28, adopted the same day): `Complete` never raises and keeps the key; an
  optional `CompleteOn` stores the answer in the handler's own transaction.
- `Agenda.WinHeap` (Delphi on Windows: the program's memory on the process heap; Delphi's own
  manager kept a program's threads at one thread's throughput, pascal-db-faa gotcha 55):
  pascal-common-faa; written 2026-10-28, "M5: under load".
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

### M2 — the slot lock in Redis (2026-10-20)

`src/Agenda.Locks`: `ISlotLock` and `TRedisSlotLock` on pascal-redis-faa 0.2.0 (a new submodule,
one `TRedisClient` for the process), in front of the booking's transaction, when `REDIS_HOST` is
set. The decision (`SetNx` around the booking) as the database's helper, not its replacement:

- The key is the slot (`agenda:lock:<tenant>:<professional>:<start>`), so only requests for the
  same start meet in Redis; the ones that don't get it are a 409 `slot_unavailable` ("Another
  request is booking this slot.") without reaching the database. Different starts for one
  professional still meet at the professional's row lock, which stays the final word.
- `SET NX PX 10000` with a random token, released after the commit with the Lua script that
  deletes the key only while it holds that token (pascal-redis-faa's README: `GET` then `DEL`
  could delete a lock another request took after this one expired).
- **Redis down: the database decides.** Only `ERedisConnectionLost`, `ERedisTimeout` and
  `ERedisPoolExhausted` let the booking through, logged with the key (never the token); any
  other Redis error propagates (pascal-api-infra-faa's guide "Messaging", step 6).
  `REDIS_CONNECT_TIMEOUT_MS` is 500 here, so a booking pays at most that while Redis is away (the
  guide measured ~2 s with the default).
- Without `REDIS_HOST` there is no lock and no Redis connection: development stays without Docker.

Tests: the runners start a `redis:7.2-alpine` container for the PostgreSQL run only, so SQLite
checks the booking without the lock and PostgreSQL with it. 9 checks
(`tools/http_scenarios_appointments.sh`, through `tools/redis_cmd.py`, a RESP client of 40
lines: the Linux image has Python, not redis-cli): a slot whose key another request holds is a
409 and that lock is left alone; free once deleted; the key gone after the booking; then
`SHUTDOWN NOSAVE`, and the next booking is a 201 from the database, the same slot again a 409 from
the database, and the log names the key. Result: 57 unit tests; 426 HTTP checks on SQLite and
435 on PostgreSQL 17 with Redis, FPC Windows and Linux. Delphi 12: 57 unit tests (0 leaks); 426 checks on SQLite
(Win32, Win64), 435 on PostgreSQL with Redis (Win64) and on SQLite with Redis (Win32, a container
started by hand: the 32-bit Redis client too).

**Candidate (pascal-redis-faa):** the lock as a class. Its README shows the acquire (`SET NX PX`)
and the release script as snippets, and its `LockDistribuidoVcl` sample shows the `DEL` trap;
every application copies both, with the token and the "only connection failures fall through"
rule. A `TRedisLock` (`TryAcquire(key, ttl, out token)`, `Release(key, token)`) would hold them
once. `Agenda.Locks` is written under the libraries' rules and could move as it is, minus the
log callback's shape.

## Filters as optionals (pascal-api-infra-faa 0.22.0, 2026-10-20)

The user's review: every list repository wrote each optional filter twice, a `ProcessTag(TAG,
HasValue)` on both statements and an `if HasValue then` for the parameter, and asked for
`TQueryArgs` to take the `IOptXxx` as it is. Planned with the user (the tag explicit per
argument: tags and parameter names differ here, `PROFESSIONAL` / `PROFESSIONAL_ID`), built in
the library: `OptStrings`, `OptInt64s`, `OptFlags`... with the tag of the block; an absent filter
binds nothing and its block goes, and `Run` processes the tags itself. Absent filters stay in the
arguments, not dropped: a block nobody processes keeps its content (pascal-db-faa's
`TSQLResult.SQL`), which would leave the condition unbound.

Here: the six repositories (services, professionals, users, customers, time off, appointments)
lost their `Filtered` functions and their `if`s (148 lines out, 96 in, tests included). What turns
a filter into its value stays here, as one expression on the optional: the search through
`TOptionals.Map(AFind.Search, PcFoldForSearch)` (or `Lower(Trim(...))` for emails, or
`CustomerSearchTerm`), then `SearchPattern` (`src/Agenda.Text`: absent when nothing is left, else
`PdbLikeContains`); the instants through `OptInstant` (`src/Agenda.Times`: absent stays absent,
a text that isn't one is the 400 `invalid_instant`); the appointment status through
`TPcValidation` with `OneOf` before the arguments (its 400 now lists the field, `invalid_fields`).
The `IOptString` -> `IOptInt64` step is the one `TOptionals.Map` can't do (it keeps the type, the
cross-type map candidate above): `OptInstant` is that map, written once.

Result: 60 unit tests (3 new: `SearchPattern`, `OptInstant`); 426 HTTP checks on SQLite and 435
on PostgreSQL 17 with Redis, unchanged (every list filter alone and combined was already covered),
FPC Windows and Linux. Delphi 12: 60 unit tests (0 leaks), 426 checks on SQLite (Win32, Win64),
435 on PostgreSQL with Redis (Win64). The library's 0.22.0 on Delphi 12: 398 unit tests (0 leaks,
Win32 and Win64), samples 253/98/160 on both and sample 02/03 on PostgreSQL (Win64) 99/160;
tagged v0.22.0, which the submodule pins.

## M2: changing and cancelling (2026-10-21)

`PATCH /appointments/:id` (`startsAt`, `status`) and `POST /appointments/:id/cancel`, any user,
both with `If-Match`. `src/Agenda.Preconditions` (the candidate), `src/Agenda.Appointments`.

- **The ETag is the version in quotes** (`"3"`), a strong validator, sent on every appointment
  read, booked or changed; the body's `version` is the same number, so a client that read a list
  can build it. `If-Match` follows RFC 9110: a list of tags, blanks and empty elements allowed,
  strong comparison (a weak `W/"3"` never matches). Absent: 428 `precondition_required`; `*` is
  also a 428 here (it names no version: a choice of the API, the unit takes `AAcceptAny`); not the
  RFC's syntax (`3` without quotes): 400 `invalid_if_match`; another version: 412
  `precondition_failed`. The 428 and 400 come before the body's checks and the 404; the 412 after
  the read.
- **Read, check, then a write that names the version read**: the row is read on its own
  connection (404, the If-Match check, the rules), then `APPOINTMENT.UPDATE ... WHERE VERSION =
  :VERSION` moves it up; a change that landed in between matches no row, a 412. Reading outside
  the transaction keeps the SQLite rule the booking follows: a transaction's first statement is
  a write (a read first would take a shared lock that two writers can't both upgrade). Four
  PATCHes from one version at once: one 200, three 412 (checked).
- **Status**: PATCH sets `confirmed`, `done` or `no_show`; `cancelled` is the cancel route's
  (400 `use_cancel`), `booked` isn't settable (400). Only a booked or confirmed appointment
  changes (409 `appointment_closed`); `done` and `no_show` only once it has started (409
  `not_started`). An empty PATCH changes nothing and keeps the version.
- **A move is a booking's check again**: the new start's slot lock (Redis, when there is one),
  then one transaction that touches the professional's row, checks it is active, and accepts the
  start only if `FreeStartsOn` lists it for that local day, with the appointment's own busy span
  left out (`APPOINTMENT.BUSY`'s new `[EXCEPT]` block). It keeps the duration and buffer it was
  booked with, as the booking stored them (a later change to the service doesn't move it).
- **Cancel**: booked or confirmed, and no later than `TENANTS.CANCEL_NOTICE_HOURS` (24 by
  default) before the start: 409 `cancel_notice_passed`, naming the hours and the last instant.
  The rule applies to every user here; whether the owner (or the front desk) may cancel inside the
  notice is open, and M3's signed link is where it matters most.

Scenarios (`tools/http_scenarios_changes.sh`, 64 checks; 2 more in the Redis block of
`tools/http_scenarios_appointments.sh`): the ETag on booking and reading; every If-Match answer
(absent, `*`, unquoted, unknown, weak, another tenant's id); confirmed, then a lost update caught;
the status rules; a move 15 minutes over its own old time and the availability following it;
moves onto another booking, into its buffer, off the grid, into the past, with seconds, with a
text that isn't an instant, from an old version; four changes racing from one version; cancel
with and without If-Match, twice, and the slot free again; the notice, with a professional who
works every hour and a booking within the next half hour; with Redis, a move onto a slot whose
lock another request holds. **Not checked over HTTP**: `done` and `no_show` on a started
appointment (the API can't book in the past and the scenarios don't wait); the 409 before the
start is.

Result: 66 unit tests (6 new: `Agenda.PreconditionsTests`, 0 leaks); 490 HTTP checks on SQLite
and 501 on PostgreSQL 17 with Redis, FPC Windows and Linux (Docker; OpenAPI valid). Delphi 12:
66 unit tests (0 leaks) and 490 checks on SQLite, Win32 and Win64; 501 on PostgreSQL with Redis,
Win64.

What it showed:
- **Candidate, now built** (`Agenda.Preconditions`, no Horse, no database): `VersionETag`,
  `EvaluateIfMatch`, `RequireIfMatchSent`, `RequireIfMatch`, `RaisePreconditionFailed`. In
  pascal-api-infra-faa it would sit in `PascalApi.Http` with the other header parsers
  (`ParseBearer`); a middleware isn't needed, since the check needs the row.
- **Small candidate (pascal-api-infra-faa):** `TRouteDocBuilder` can't document a header
  parameter (`If-Match`) or a response header (`ETag`): `AddParam` takes a location but is
  private, and there is no `HeaderParam`. The routes say it in `Descr`.
- **pascal-db-faa, as documented and met again:** a tag block nobody processes keeps its content,
  so `APPOINTMENT.BUSY`'s `[EXCEPT]` is processed on every call, also when there is nothing to
  leave out.
- The scenario helper `req` keeps its body in a global `B`: a scenario variable named `B` was
  overwritten by the next request (the cancel checks hit `/appointments//cancel`). The new file
  names its ids `CA`, `CB`.
- **Delphi gotcha (for the skill):** a unit-level test helper named `Status` (three parameters)
  compiled on FPC, but inside a DUnitX fixture method Delphi bound the name to another `Status`
  first ("E2034 Too many actual parameters"). Renamed `IfMatchAnswer`. A generic name for a free
  function in a test unit can be shadowed on one compiler only.

## M2: Idempotency-Key (2026-10-21)

`POST /appointments` takes an optional `Idempotency-Key` (M3's public booking will require it).
`src/Agenda.Idempotency` (the candidate), migration 12 (`IDEMPOTENCY_KEYS`), the handler in
`api/AgendaApi.dpr`.

- **A key is per tenant and per request**: the first use stores a fingerprint, the SHA-256 of
  method, path and body. The same key with another body is a 422 `idempotency_key_reused`; another
  tenant's key of the same name is its own.
- **Claimed, then answered**: the first request claims the key (a lease of 30 seconds) and runs; a
  request with the same key while it runs is a 409 `idempotency_key_in_flight`, never a second run.
  When it ends the answer is stored and later retries get it back, status, body and ETag, with
  `Idempotent-Replayed: true`. A client error (one the error handler doesn't log: a 400, the 409
  `slot_unavailable`) is stored as the handler sends it, so the same request keeps getting the same
  answer; anything else (a 500, the database gone) releases the key, so a retry runs again. A
  request that died mid-way leaves a lease the next retry takes over once it runs out.
- **Expiry**: 24 hours (`IDEMPOTENCY_TTL_HOURS`); an expired key is a new one. The tenant's expired
  keys are deleted at each claim.
- **The key**: 1 to 255 visible ASCII characters, bare or as a structured-field string in quotes
  (the IETF draft writes it `"..."`); otherwise 400 `invalid_idempotency_key`.
- **The claim in the database**: one transaction whose first statement is a write (the expired
  keys deleted), then `INSERT ... ON CONFLICT (TENANT_ID, IDEM_KEY) DO NOTHING`: 1 row is a claim,
  0 rows reads the key (another request, an answer, a lease running or run out; a lease taken over
  by an `UPDATE ... WHERE LEASE_UNTIL <= :NOW`, so by one request only). That INSERT is the same on
  SQLite (3.24 and later) and PostgreSQL, so it sits in `COMMON`.
- **Not atomic with the booking**: the claim, the booking and the stored answer are three
  transactions. A process that dies after the booking committed and before the answer was stored
  books again on the retry, and the booking's own check answers 409 `slot_unavailable`: no double
  booking, but the client sees a 409 for a booking that did happen. Storing the answer in the
  booking's transaction would close it, at the cost of the store knowing the request's connection.

Scenarios (`tools/http_scenarios_idempotency.sh`, 32 checks): a booking and its retries (the same
status, body and ETag, marked as a replay, a quoted key the same key, one appointment stored); the
key with another body (422); another tenant's key of the same name; a 409 `slot_unavailable` and a
400 replayed with their codes and fields; invalid keys; four requests with one key at once (a 201,
the others 409 in flight or the 201 replayed, one appointment); without a key, as before. Expiry
and a lease taken over are unit-tested only (memory store).

Result: 75 unit tests (9 new: `Agenda.IdempotencyTests`); 522 HTTP checks on SQLite and 533 on
PostgreSQL 17 with Redis, FPC Windows and Linux (Docker; OpenAPI valid). Delphi 12:
75 unit tests (0 leaks) and 522 checks on SQLite, Win32 and Win64; 533 on PostgreSQL with Redis,
Win64. **M2 is complete**: free slots, booking with a lock, If-Match, Idempotency-Key.

What it showed:
- The scenario helper `req` keeps its arguments in the globals `M`, `P` and `B`: a scenario
  variable named `P` was overwritten too (the retry sent the last GET's path as its body: a 422,
  which was right). Second time in a day; the helper could use names no scenario would pick.
- **Candidate shape**: in pascal-api-infra-faa it would be `PascalApi.Idempotency` (the policy and
  the stores, as here) plus a Horse helper for the handler (replay, complete, fail). A middleware
  would need to capture the handler's response body, which Horse doesn't expose the same way on
  both compilers; the handler-level helper doesn't.

## Candidates promoted (2026-10-21)

The user decided (2026-10-21) to promote what M2 built and proved. Each library got it with its
own tests, docs and a release, green on FPC (Windows, Linux) and Delphi 12 (Win32, Win64) before
its tag; then this application moved its submodules to the tags and dropped its copies.

| Candidate | Library | What it replaced here |
|---|---|---|
| Optimistic concurrency | pascal-api-infra-faa 0.23.0 `PascalApi.Preconditions` (`VersionETag`, `EvaluateIfMatch`, `RequireIfMatchSent`, `RequireIfMatch`, `RaisePreconditionFailed`) | `src/Agenda.Preconditions` and its 6 tests |
| Idempotency-Key | pascal-api-infra-faa 0.23.0 `PascalApi.Idempotency` (`TIdempotency`, `TDbIdempotencyStore` with the same statement names) + `PascalApi.Horse.Idempotency` (`THorseIdempotentRequest`) | `src/Agenda.Idempotency` and its 9 tests; `SendReplay` and the key handling in `PostAppointment` |
| Header parameters and response headers in the document | pascal-api-infra-faa 0.23.0 `TRouteDocBuilder.HeaderParam`, `ResponseHeader` | `If-Match`, `Idempotency-Key`, `ETag` told only in `Descr`; now in the OpenAPI document too |
| A required query member | pascal-api-infra-faa 0.23.0 `THorseQueryParams.Read` (a non-optional member missing is a `required` field failure) | the availability's own `service` and `date` checks |
| The slot lock | pascal-redis-faa 0.3.0 `TRedisLock` (`Redis.Lock`) | `src/Agenda.Locks` (`ISlotLock`, `TRedisSlotLock`) |
| An instant with its zone's offset | pascal-common-faa 1.23.0 `PcLocalIsoString` | `Agenda.Slots.LocalIso` and its test |

What stays here: the policy that a Redis that doesn't answer lets the booking through
(`TAppointmentRepository.LockSlot`: `rlBusy` is a 409, `rlUnavailable` goes on with no token, the
database decides) and its log line, now from `TRedisLock.OnUnavailable` in the same words the
scenario reads; the keys' table and its SQL (migration 12, `IDEMPOTENCY.*`), which the library's
store reads by the names it already had; the "*" refused by If-Match (the library's default).

Every HTTP check stayed green and unchanged in number: 522 on SQLite, 533 on PostgreSQL 17 with
Redis, on FPC Windows and Linux (Docker; OpenAPI valid) and on Delphi 12 (SQLite Win32 and
Win64, PostgreSQL with Redis Win64); unit tests 0 leaks on all four. The 400s kept their codes (the availability's missing `service` and `date` are still
`invalid_fields` with a `required` field each, the same message), the 428/412/400 of If-Match and
the 400/409/422 of the key the same codes and texts (the libraries' English messages are the
ones this application wrote). The unit tests went from 75 to 59: the 16 that moved live in the
libraries now (with more around them: 24 in pascal-api-infra-faa, 17 in pascal-redis-faa, 4 in
pascal-common-faa).

What promoting showed about the libraries:

- **The lock's "unavailable" was a third answer hidden in a Boolean.** `ISlotLock.TryAcquire`
  answered `True` with an empty token for "Redis didn't answer", which only this application's
  caller knew to read. `TRedisLock.Acquire` returns `rlAcquired`/`rlBusy`/`rlUnavailable`, and
  the choice to go on without the lock stays with the application: the library classifies, it
  doesn't decide. `TryAcquire` there raises on unavailability; `Extend` came in from the
  library's own sample.
- **`LocalIso` truncated an offset with seconds.** Zones' local mean time before 1900 has them
  (New York's -04:56:02); the truncated text named another instant. Unreachable here (dates
  within 366 days of today), but a library function keeps them, as Python and java.time do.
- **A library's client messages belong in its message table.** The two units carried their
  English messages as literals; in pascal-api-infra-faa they went to `TApiMessages` (with
  Portuguese), and the codes got the library's prefix (`API_CODE_PRECONDITION_REQUIRED`...).
- **Making required query members required changes a library's behavior**, so it is in its
  CHANGELOG under "Changed": a Find DTO with a plain member that clients may omit now answers
  400. Every Find DTO here but the availability's uses optionals, so nothing else moved.
- **A header parameter can't be an MCP argument**: the MCP executor sends no headers of the
  model's, so the library leaves them out of the tools, and its sample marks the route that
  requires `If-Match` `NoMcp`. This application has no MCP endpoint.
- **The sample that proves a feature found its own edges**: pascal-api-infra-faa's sample 02
  (`PUT /cities/:code` with If-Match, an Idempotency-Key on `POST /cities`, on SQLite and
  PostgreSQL, four concurrent requests each) went from 98/99 to 151/152 checks. Writing it
  showed that an absent `INullInteger` member is read as null, not refused (the mapper's
  contract: nullable is not required), and that the scenario helpers' `grep '"code"'` matched
  a city's own `code` member.
- **Found right after, in a browser** (2026-10-21): this application's `/swagger` showed
  nothing ("duplicated mapping key"). Its `startsAt`/`endsAt` are `TUtcDateTime` described with
  `.Format('date-time')`, and the library wrote `"format"` twice; openapi-spec-validator reads
  JSON with the last key winning, so every run had passed. Fixed in pascal-api-infra-faa
  0.23.1, whose `tools/json_no_duplicate_keys.py` now runs before the validator here too.
- **And on rereading the skill's index**: `TRedisLock` 0.3.0 made its token with `CreateGUID`,
  which FPC 3.2.2 bases on a clock-seeded `Random` on some Unix targets (the index says never);
  two processes started together could share a token. pascal-redis-faa 0.3.1 takes 16 bytes of
  `PcRandomBytes` (its minimum pascal-common-faa is now 1.15.0). Same results with both:
  59 unit tests, 522/533 HTTP checks, FPC Windows and Linux, Delphi Win32/Win64.

## M3: design (2026-10-21)

Public routes for the end customer, who has no account: the tenant from the path's slug, a rate
limit per client address, booking with a required `Idempotency-Key`, and a signed link to see
and cancel the appointment. Three decisions taken with the user (2026-10-21), the rest follows
from rules already set.

### Decisions (user, 2026-10-21)

1. **The link has keys of its own, not the JWT key ring.** A ring's key retires
   `MaxTokenSeconds` after the next one starts signing (15 minutes here) and the ring rotates
   every 30 days, while an appointment may be up to 366 days ahead: a link signed with the
   ring would stop working long before it is needed. `LINK_SIGNING_KEYS`, in
   `JWT_KEYS_MASTER_KEY`'s format (`id:<base64 of at least 32 bytes>`, comma separated, the
   first signs and every one verifies, so a key is rotated by putting the new one first and
   dropping the old one once its links expired). Each tenant's key is derived from it with
   HMAC (`HMAC(key, "agenda-link-key|<tenant>")`), so a signature for one tenant never
   verifies for another. `DEV_MODE` without the setting uses a development key, as for the JWT
   master key; otherwise the server doesn't start without it.
2. **A returning customer is found by contact and name.** The phone (normalized) when the
   booking has one, else the email, plus the name folded for search (`NAME_KEY`): a family
   sharing a phone stays several customers. No match creates a customer; a match is used as it
   is (never changed by a public request) and its data never goes back in the answer. At least
   one contact is required (`contact_required`): it is how the business reaches the customer,
   and the email will carry the link (M4).
3. **A suspended tenant answers like an unknown one on the public routes: 404, the same body.**
   Multi-tenancy decision 7 gives a suspended tenant 403 `tenant_suspended` because the caller
   already logged in to it; on a public route anyone can try names, and a different answer
   would say which slugs are customers. A refinement of decision 7 for sources nobody
   authenticated, to record in pascal-api-infra-faa when the path source moves there.

### What follows from rules already set

- **The tenant from the path** (`Agenda.PublicTenancy`, the `PascalApi.Tenancy` candidate): a
  middleware after the rate limit takes the segment after `/public/`, checks it against the
  catalog (`CheckTenant`) and, when usable, marks the request as `TTenantMiddleware` does
  (`TPascalApiRequestState.TenantId`). From there `TTenantMiddleware.Current`, the access log's
  `tenant.id` and every repository work as on the authenticated routes. Text that can't be a
  tenant id never reaches the catalog. `/public` is excluded from the JWT, so these routes
  read no token: there is no second source to compare with the slug (decision 2's "must
  agree" has nothing to apply to).
- **The rate limit**: `/public/*` keyed by client address (`TClientAddress.Resolve`,
  `TClientAddress.ProxyHops` from `TRUSTED_PROXY_HOPS`), `PUBLIC_RATE_LIMIT` a minute (60). The
  limit runs before the slug is looked up, so trying names spends the same window.
- **What a public route shows**: active services (id, name, duration, price) and active
  professionals (id, name), a page at a time as the staff lists; free slots exactly as the
  staff route answers them. No email, buffer, customer or version.
- **Booking** (`POST /public/{slug}/appointments`): professional, service, start, the
  customer's name, phone and email. `Idempotency-Key` required (400
  `idempotency_key_required`), and at least 16 characters (400 `invalid_idempotency_key`): the
  stored answer carries the link, so a key another client could guess would hand it over
  (the request's body must match too, but a short key like "1" is a mistake worth refusing).
  The answer: the appointment (no customer, no version) and its two links, `url` (GET) and
  `cancelUrl` (POST). `PUBLIC_BASE_URL`, when set, makes them absolute.
- **The link**: `?exp=<unix seconds>&sig=<key id>.<HMAC-SHA256, Base64url>` over
  `agenda-link|v1|<tenant>|<purpose>|<appointment id>|<exp>`, purpose `appointment`. `exp` is
  the appointment's start when booked. A missing, malformed or wrong signature, or a key no
  longer configured, is 403 `invalid_link`; a right signature past `exp` is 410
  `link_expired` (only a holder of a valid link learns that). The appointment id is inside the
  signature, so another id with the same `sig` is a wrong signature, never a 404.
- **Cancelling by link** needs no `If-Match`: the link is the authority, and the customer has
  no ETag. The tenant's notice still applies (409 `cancel_notice_passed`). Cancelling twice
  answers the cancelled appointment again (200): a link opened twice is not an error. Another
  closed status is 409 `appointment_closed`. A change between the read and the write (staff
  moving it) is read again; if it is then cancelled, 200, otherwise 409
  `appointment_changed`.

### Known limits, accepted

- **A new customer stays when the booking fails** (a 409 for a slot taken in the meantime):
  the customer and the booking are two transactions. The idempotency store replays the 409,
  so a retry doesn't create a second one. Booking inside the customer's transaction would
  close it, at the cost of `Book` taking a customer to create.
- **Two first bookings of one new customer at once** can create two customers (no unique key
  on contact and name: by decision 2, those aren't unique by nature). The front desk merges.
- **A moved appointment keeps its old link**, whose `exp` is the old start: a later start
  leaves the customer without a way to cancel from the link after the old date. M4's
  confirmation sends a new link on every change.
- **Anyone can book**: the rate limit bounds how fast, not whether. A confirmation step (M4,
  the email) is the usual answer if it is abused.

### Found while designing (for the libraries)

- `THorseIdempotentRequest.Start` has no "required" mode: without a key it lets the request
  run. A route that requires one checks the header itself; a `Required` flag (400 with a code
  of the library's) would do it in one place.
- **A Base64url signature has more than one spelling.** 32 bytes are 43 characters, and the last
  one carries 4 bits: the next character of the alphabet decodes to the same bytes (measured on
  the Linux run: a link whose signature ended in "A" verified with "B"; the Windows run passed
  only because its signature ended otherwise). Not a forgery (the bytes are the signature's),
  but one link had two spellings. `Agenda.SignedLinks` now takes only the canonical text
  (decoded and encoded again, the same). The same holds for pascal-api-infra-faa's JWT: `TJwt`
  decodes the signature and compares bytes (`PascalApi.Jwt`, `PaBase64UrlDecode` then
  `PaSameBytes`), so a token with its last character changed that way still verifies. For
  pascal-common-faa: a strict `PcBase64UrlDecode` (or a canonical check) that the JWT and this
  unit both use. Not patched here (the libraries are fixed in their repositories).
- `THorseQueryParams.Read` ignores a query member the Find DTO doesn't have
  (`/public/demo/services?active=false` lists the active ones, 200), where a body's unknown
  member is a 400 (`UnknownMembers := umError`). Not a finding after all: the library's guide
  says so and why (`docs/guide/dtos-json.md`: a query string often carries a cache buster).

### M3: built (2026-10-21)

`src/Agenda.SignedLinks` and `src/Agenda.PublicTenancy` (the two candidates, pure, 21 unit
tests), `src/Agenda.Public` (DTOs and the booking for the public routes),
`TCustomerRepository.FindOrInsert`, `TAppointmentRepository.CancelByLink` (the cancel's notice
and write now shared with `Cancel`), migration 13 (`IX_CUSTOMERS_EMAIL`), the six routes and
the slug's middleware in `api/AgendaApi.dpr`, settings `LINK_SIGNING_KEYS`,
`PUBLIC_RATE_LIMIT`, `PUBLIC_BASE_URL`, `TRUSTED_PROXY_HOPS` (`.env.example`).

Scenarios (`tools/http_scenarios_public.sh`, 89 checks): no token, and a bad one not read; only
active services and professionals, without buffer, email or flags; another tenant's list; an
unknown, a suspended and an upper-case slug with one 404 body; free slots; the key required
and at least 16 characters; the booking's members before the customer (a 400 creates none);
`contact_required`; a booking, its replay with the same link and `no-store`; the same slot
with a new key (409); the returning customer by phone and name written differently, a
family's phone, an email in another case; the link: shown, its `exp` the start, a changed
character, the same bytes spelled another way, a later `exp`, no `sig`, another appointment,
another tenant's path (403), an unknown one (404), signed outside the API with Python as this
section writes it, and past its expiry (410); cancelling by link twice, the slot free again, a
confirmed appointment cancelled; the access log's `tenant.id` from the slug; the rate limit
by address, shared by every slug, the staff routes untouched. The OpenAPI document: the
public routes, the required key, and `security: []` on the public routes only.

Result: 78 unit tests (from 59), 0 leaks, FPC Windows and Linux; HTTP 612 checks on SQLite
(from 522) and 623 on PostgreSQL 17 with Redis (from 533), FPC Windows and Linux (Docker;
OpenAPI valid, no duplicate keys). Delphi 12: 78 unit tests (0 leaks) and 612 checks on
SQLite, Win32 and Win64; 623 on PostgreSQL with Redis, Win64. **M3 is complete**; the user
chose (2026-10-21) to take the findings to the libraries (the strict Base64url, the required
Idempotency-Key).

### M3 findings in the libraries (2026-10-21)

- pascal-common-faa **1.24.0**: `PcBase64UrlDecodeStrict`, only the text `PcBase64UrlEncode`
  writes (added, not changed: the lenient decoder stays, by the library's versioning rule).
  `Agenda.SignedLinks` uses it instead of its own encode-and-compare.
- pascal-api-infra-faa **0.24.0**: `TJwt` reads a signature with it (a token with its last
  character changed, or padded, was valid; now `jrMalformed`), and
  `THorseIdempotentRequest.Start(..., ARequired)` answers a missing key 400
  `idempotency_key_required`. The public booking passes `True` and keeps only its own rule, a
  key of 16 characters at least, checked before `Start`.

Both tagged (v1.24.0, v0.24.0) after their Delphi 12 runs, Win32 and Win64: pascal-common-faa
397 tests, pascal-api-infra-faa 425 tests (0 leaks) and its samples' 253/151/160 checks
(SQLite), 152/160 on PostgreSQL (Win64). This application on them: 78 tests, 614 checks on
SQLite (Win32, Win64) and 625 on PostgreSQL with Redis (Win64), as on FPC Windows and Linux.

## M4: design (2026-10-26)

Events out of the database without a dual write: the outbox, a relay, a sink (AMQP or local),
a worker process that sends the confirmation (with M3's signed link) and the reminders, and a
trace from the request to the email. Seven decisions taken with the user (2026-10-26), the
rest follows from rules already set. Nothing built yet.

What exists today: no worker, no `docker compose` file (the scenario scripts start PostgreSQL
and Redis with `docker run`), pascal-amqp-faa not yet a submodule (its 0.4.x has publisher
confirms, manual ack, reconnect with topology recovery, `AMQP.Tracing`, and an embeddable
broker, `TAMQPServer`). No `*-faa` library sends email. The api runs no background thread (the
JWT keys rotate on a request).

### Decisions (user, 2026-10-26)

1. **The relay runs in the worker.** The api stays a request server with nothing to stop at
   shutdown but Horse; the worker already needs the database (reminders) and a pool. Several
   workers are allowed: the batch claim per dialect is the candidate's.
2. **A thin event**: tenant, appointment id, kind, the version written, the trace context. The
   consumer reads the rest from the database and signs the link itself (`Agenda.SignedLinks`,
   so the worker needs `LINK_SIGNING_KEYS`). No personal data in the outbox and the broker; an
   event handled late reads the appointment as it is now (a moved one gets the new start and
   link, a cancelled one no confirmation); the version tells a stale event from the current one.
3. **The reminder**: when, a tenant column `REMINDER_HOURS` (default 24, 0 = none), as
   `CANCEL_NOTICE_HOURS`. Once: a scheduler pass every minute picks the appointments due and,
   per appointment, a conditional `UPDATE ... SET REMINDER_QUEUED_AT WHERE REMINDER_QUEUED_AT
   IS NULL AND VERSION = :VERSION` plus an outbox event in one transaction: the row is the
   claim, so two passes at once still queue one reminder. A moved appointment clears
   `REMINDER_QUEUED_AT`. The lease (the "Scheduler with a lease" candidate) only keeps two
   workers from scanning together: one interface, two stores, a database row
   (`SCHEDULER_LEASES`: job, owner, until) by default (works on SQLite without Redis) and
   Redis (`TRedisLock`), as the idempotency store has two.
4. **Email through Synapse (Ararat)**, a submodule like Horse: one code on both compilers,
   STARTTLS through OpenSSL, behind an application interface (`IMailSender`) with a second
   implementation that writes `.eml` files (unit tests, a run without Mailpit). Not library
   material (decided 2026-10-18).
5. **Without RabbitMQ, the local sink**: `AMQP_HOST` unset runs the handlers in the relay's
   process (`OUTBOX_DELIVERIES` per event and handler); set, the AMQP sink. The candidate's own
   promise (start local, move to a broker without touching the code that writes events); the
   scenarios run both ways, as SQLite and PostgreSQL today. pascal-amqp-faa's embedded broker
   is not needed here.
6. **At-least-once email**: send, then record the event as handled (`PROCESSED_EVENTS`:
   consumer, event id); a crash between them sends it twice, never loses it. The record still
   stops the broker's redeliveries.
7. **Who gets an email**: a customer with an email; one with a phone only is skipped and logged
   (SMS out of scope). Staff-made bookings and changes email the customer too, as public ones.
   Events: `appointment.booked`, `appointment.moved`, `appointment.cancelled` (by staff or by
   link), `appointment.reminder`; a status change to `confirmed`/`done`/`no_show` emits none
   in M4.

### What follows from rules already set

- **The outbox row is written in the appointment's transaction** (`Book`, `Update`, `Cancel`,
  `CancelByLink`, the reminder's claim), with the tenant (`${TENANT}` like every table), an
  event id from `PcRandomBytes`, the kind, a JSON payload and the request's `traceparent`. An
  idempotent replay writes nothing: the stored answer is replayed, the booking isn't run again.
- **The trace crosses processes**: the relay continues the stored `traceparent` when it
  publishes (`AMQP.Tracing`), the consumer continues the message's; the access log's trace id,
  the publish and the email's span share one trace in the collector.
- **The candidate's code lives in its own units** under the libraries' rules
  (`src/Agenda.Outbox` core on pascal-db-faa only, `src/Agenda.Outbox.Amqp` the broker sink,
  the local dispatcher in the core; `src/Agenda.Leases`), unit-tested on both compilers with
  pascal-db-faa's mock and SQLite, and listed in "Library candidates".
- **The worker is a console program** (`worker/AgendaWorker.dpr`/`.lpi`), the same `.env`,
  stopped by Ctrl+C/SIGTERM with a clean shutdown (relay, consumers, pool: the
  `using-faa-libraries` order); a Windows service or systemd unit is out of M4.
- **`docker compose`** arrives with M4: PostgreSQL, Redis, RabbitMQ, Mailpit, OpenTelemetry
  Collector; the HTTP scenarios check the email through Mailpit's API (subject, recipient, a
  link that opens the appointment) and the trace id in the collector's output.
- **Acceptance** as in every milestone: FPC Windows and Linux, Delphi Win32 and Win64, 0 leaks.

### Known limits, expected

- **Polling delay**: an event waits up to the relay's interval (`OUTBOX_POLL_MS`, 1000) before it
  leaves; no `LISTEN/NOTIFY` (PostgreSQL only).
- **A reminder for an appointment changed after it was queued** is read again by the consumer
  (question 2's thin event), so it carries the current start; one already sent is not recalled.
- **The outbox grows**: delivered rows are deleted after `OUTBOX_KEEP_DAYS` by the scheduler.

### M4: the new submodules (2026-10-26)

- `external/pascal-amqp-faa` at **v0.4.1** (needs pascal-common-faa 1.8.0; here 1.24.0).
- `external/synapse` (https://github.com/geby/synapse, the author's repository; no tags, so a
  commit: `eb5a511`, 2026-10-19). A probe outside the repository (`smtpsend`, `mimemess`,
  `mimepart`, `ssl_openssl3`; a multipart message with a UTF-8 subject and body, encoded, not
  sent) builds and runs with 0 unfreed blocks on FPC 3.2.2 Windows (Win64) and Linux (the CI
  image), the same text on both: the subject goes out as `ISO-8859-1` Q-encoding (Synapse picks
  the smallest charset that holds it; valid), the body as UTF-8 quoted-printable. Three
  deprecation warnings in `synautil` (`TimeSeparator`, `ShortMonthNames`). Delphi 12 is checked
  when the worker has its `.dproj` (this Delphi edition builds in the IDE only).

### M4: migration 14 (2026-10-26)

- `TENANTS.REMINDER_HOURS` (default 24) was already there, since migration 2: decision 3's
  column needs no migration, only its reading (0 = no reminder).
- Migration 14 (`Agenda.Schema`, comments there): `OUTBOX` (one row per event; a lease for the
  claim, attempts and the next try, `DELIVERED_AT`), `OUTBOX_DELIVERIES` (the local sink, one
  row per event and handler, `pending`/`done`/`dead`), `PROCESSED_EVENTS` (a broker consumer's
  record, by consumer and event), `SCHEDULER_LEASES` (a job, its owner, until when; no tenant),
  `APPOINTMENTS.REMINDER_QUEUED_AT` and `IX_APPOINTMENTS_REMINDER` (`START_UTC`, the scan across
  tenants). All of it in `COMMON`: the claim is a lease, portable; PostgreSQL's `SKIP LOCKED`
  goes in a `PG` override of the claim's statement, not in the table.
- Found running the scenarios: for a few days after the last Sunday of March and of October,
  the next one is more than 366 days ahead (from 2026-10-26, 2027-10-31 is 370) and the
  availability route answers `date_out_of_range`; the one just gone has no free slot left.
  `tools/http_scenarios_availability.sh` now skips that Sunday's checks then, with a `SKIP`
  line (6 checks for October, 4 for March). Not a bug of the route: a time bomb in the script.
- Result: 78 unit tests, 0 leaks (FPC Windows); HTTP 608 checks on SQLite and 619 on
  PostgreSQL 17 with Redis (6 skipped, above), FPC Windows, migration 14 applied and a second
  start applying none.

### M4: the outbox core (2026-10-26)

- `src/Agenda.Outbox` (the candidate; pascal-db-faa and pascal-common-faa only):
  `TOutbox.Enqueue` (in the caller's transaction, the current span's traceparent),
  `TOutbox.Purge`, `TOutboxRelay.RunOnce` (a lease-claimed batch, each event handed to an
  `IOutboxSink` and marked delivered in one transaction with what the sink wrote; a failure
  counts attempts, waits `TOutboxRetry`'s doubling delay, and the batch goes on),
  `TOutboxLocalSink` (`IOutboxLocalSink`: a delivery per accepting handler, written in the
  relay's transaction; its `RunOnce` runs them outside any transaction, in a span continuing
  the event's trace, each retried apart and dead after `MaxAttempts`). No thread, no sleep:
  the worker calls the passes. Its SQL is `Agenda.Schema`'s (`OUTBOX.*`, `OUTBOX_DELIVERY.*`),
  common to both engines except the two claims, whose PostgreSQL versions skip locked rows.
- `src/Agenda.Events`: the kinds and the thin payload (`{"appointmentId","version"}`, through
  the mapper). `TAppointmentRepository` writes `appointment.booked` (version 1), `.moved` (a
  PATCH with `startsAt`; it also clears `REMINDER_QUEUED_AT`) and `.cancelled` (staff and
  link: `WriteCancel`, only when its UPDATE matched) in the change's transaction; a status
  PATCH writes none. The public booking goes through `Book`, so it has its event too.
- `TAgendaDatabase.CreateSQLite(file)` for tests. The unit suite now opens SQLite
  (`Agenda.OutboxTests`, a file in the temporary directory, every migration): the FPC
  project requires `pascal_db_faa_sqldb`, `tools/test_fpc.sh` copies `.deps/sqlite3.dll` next
  to the runner, the Docker script adds the SQLdb adapter's path, and the Delphi project
  the FireDAC adapter's (`adapters\firedac`).
- Found while writing it: FPC warns that a method named `Dispatch` hides `TObject.Dispatch`
  (the local sink's pass is `RunOnce`, as the relay's). pascal-db-faa doesn't say whether a
  write outside `StartTransaction` commits; every write here starts one.
- Result: 89 unit tests (from 78), 0 errors, 0 failures, 0 leaks on FPC Windows and Linux
  (Docker). HTTP 608 checks on SQLite and 619 on PostgreSQL with Redis (6 skipped, as in
  "migration 14"); after the SQLite run its database had one `booked` event per appointment
  (14), 3 `cancelled`, 2 `moved`, each with the request's traceparent. Not run yet: the
  PostgreSQL claims (only the worker runs them; step 4's scenarios will), Delphi (the IDE).

### M4: the worker (2026-10-26)

- `worker/AgendaWorker` (`.dpr`, `.lpi`, `.dproj`; in `Agenda.groupproj`): one console process,
  one loop. Every `OUTBOX_POLL_MS` (at once again while a pass found work): the relay hands
  pending events to the local sink, the sink runs its deliveries (one handler today, the
  customer's email); every `REMINDER_INTERVAL_SECONDS`, holding the `reminders` lease, the
  reminders' pass and, once an hour, the outbox's purge (`OUTBOX_KEEP_DAYS`). A pass that
  raises is logged and the loop goes on. `--drain` runs passes until one finds nothing, then
  exits (0, or 1 when a pass failed): what the scripts use. It doesn't migrate: it waits for the
  api to bring the database to its schema (`TAgendaDatabase.SchemaVersion`/`LatestVersion`),
  so one process migrates. Ctrl+C, the console closing and SIGTERM end the pass in progress,
  release the lease and free everything in reverse order. `AMQP_HOST` is not read yet (step 5):
  the local sink always.
- `src/Agenda.Notifications`: the handler (`TAppointmentMailer`, "email"). It reads the
  appointment as it is now (one query, a `${TENANT.x}` tag per joined table, the event's
  tenant) and decides by the row, not the event: a booking or a move read after a cancel sends
  nothing, a reminder for one no longer active or already started neither; a customer with no
  email is skipped and logged (decision 7). The links are M3's (`Agenda.SignedLinks`, expiry
  the start), so the worker reads the api's `LINK_SIGNING_KEYS` and `PUBLIC_BASE_URL`, now in
  `src/Agenda.Settings`, which both programs use. The time is in the tenant's zone, with the
  zone's name; the text in English.
- `src/Agenda.Mail`: `IMailSender`, `TSmtpMailSender` (Synapse's `TSMTPSend`; plain, STARTTLS
  or TLS) and `TEmlMailSender` (`.eml` files, `MAIL_DIR`; the worker's choice when `SMTP_HOST`
  is unset). The message is written by `MailToMime`, not by Synapse's MIME classes, which were
  the first try: on Delphi their text goes through the ANSI code page; they encode again any
  header with `=`, `?`, `:` or `,` (an encoded word included, and an ASCII subject came out as
  ISO-8859-1 Q-encoding); they always write an empty `From:` of their own; their
  quoted-printable wrote lines of 79 (RFC 2045: 76). Here: RFC 2047 words (UTF-8, Base64, 39
  bytes each so `Subject: ` and one word fit in 76), quoted-printable of the UTF-8 bytes, headers
  folded at a space. Synapse stays for SMTP and its RFC 822 date. Not library material.
- `src/Agenda.Reminders` (decision 3): across tenants, booked or confirmed, start within the
  tenant's `REMINDER_HOURS` and at most `REMINDER_MAX_HOURS` (720) ahead, no reminder queued,
  the tenant not suspended; per appointment one transaction, the conditional `UPDATE` (the
  version read) and the outbox event. The version isn't moved (an `If-Match` the client holds
  stays good); each queued reminder starts a trace of its own. The api has a command for the
  tenant's hours, `--reminder-hours <tenant> <0..720>` (no route sets them yet).
- `src/Agenda.Leases` (the "Scheduler with a lease" candidate): `ISchedulerLease`,
  `TDbSchedulerLease` (`SCHEDULER_LEASES`: an `UPDATE` for the owner's own or one that ran out,
  else `INSERT ... ON CONFLICT DO NOTHING`, one transaction) and `TRedisSchedulerLease`
  (`TRedisLock`, renewed with `Extend`; Redis down: not held, the pass waits, logged). With
  `REDIS_HOST` the worker uses Redis. The worker keeps it between passes (renewed every one).
- `src/Agenda.StopSignal`: a console program's stop request (Windows `SetConsoleCtrlHandler`,
  Unix `fpSignal` for SIGINT and SIGTERM; the handler only sets a flag) and a sleep that wakes
  on it. A library candidate (below).
- Tests: `Agenda.MailTests` (8: encoded words, the message, folding, the `.eml` writer) and
  `Agenda.WorkerTests` (11, SQLite: the lease taken, refused, renewed, taken over, released;
  the reminder queued once with its event, only the due ones, the claim needing the version
  read, a move clearing it; the email with links that verify, no email, after a cancel, a
  reminder for one started; the time in the zone). `tools/http_scenarios_worker.sh`, run by
  `tools/test_http.sh` and `tools/test_http_docker.sh` on the api's second start, with the
  worker in `--drain` between steps and its mail read back by `tools/eml_summary.py`: the
  backlog the other scenarios left (each event once, customers without email skipped), a
  booking's email (recipient, subject decoded, a link that opens the appointment on the api),
  nothing sent twice, the reminder once, again after a move together with the move's email,
  the cancel through the email's own link (its email has no link), two workers draining at
  once (each event once: the claims' `SKIP LOCKED` on PostgreSQL, the leases on SQLite), the
  lease in Redis with `REDIS_HOST`, and every run's heaptrc report. On Linux, the worker
  running (not `--drain`) sends a booking and stops on SIGTERM with exit code 0 and 0 unfreed
  blocks.
- Found while building: two workers starting at once both create the mail directory, and
  `ForceDirectories` fails for the one that lost the race on FPC/Linux, though the directory
  is there (now checked after). On Linux, heaptrc writes its report only with
  `HEAPTRC=log=<file>`. The appointments' scenarios end with Redis shut down (the slot lock's
  fallback); `tools/test_http.sh` starts it again for the worker, and the Docker script, which
  can't from inside the container, runs the worker with the database lease. Accented request
  bodies go through a file with UTF-8 bytes (curl.exe gets its arguments in the ANSI code page,
  as the catalog's scenarios knew).
- Known limits: one loop, so a slow SMTP server delays the relay's next pass (the email's
  timeout, `SMTP_TIMEOUT_MS`, bounds it); an appointment booked inside its reminder window gets
  the reminder right after its confirmation; with Redis down there is no reminders' pass until
  it is back; Ctrl+C on Windows is checked by hand only (Git Bash can't send a console's
  Ctrl+C to a Windows program).
- Result: 108 unit tests (from 89), 0 errors, 0 failures, 0 leaks on FPC Windows and Linux
  (Docker). HTTP, FPC Windows: 608 checks and 73 for the worker on SQLite, 619 and 73 on
  PostgreSQL 17 with Redis; FPC Linux (Docker): 608 and 78, 619 and 78 (SIGTERM included).
  Delphi 12 (built in the IDE): HTTP 608 checks and 67 for the worker on SQLite, Win32 and
  Win64, 619 and 67 on PostgreSQL (Win64); the worker's leaks are the unit tests' to report, as
  the api's (no heaptrc). Its first unit run: 106 of 108, both failures the accents of
  `Agenda.MailTests`; it and `Agenda.WorkerTests` had no BOM, so Delphi read their UTF-8
  literals as ANSI (the WorkerTests passed by luck: "João" was written and compared in the
  same wrong code page). The rule the older tests follow, now these too: a test unit with a
  non-ASCII literal starts with a BOM. Before that, `GetTempDir` (FPC's RTL only) stopped the
  build; the tests now use `TPath.GetTempPath` on Delphi.
  Rebuilt: 108 of 108, 0 leaked, Win32 and Win64. Step 4 meets the acceptance on both
  compilers.

### M4: the broker, the compose file, the trace (2026-10-26)

- `src/Agenda.Outbox.Amqp` (the outbox candidate's broker sink): `TOutboxAmqpSink` publishes
  each event (the payload as the body, `application/json`, persistent; `MessageId` the event
  id, `type` the kind, `timestamp` its creation, a `tenant-id` header; routing key the kind,
  on the topic exchange `agenda.events`) on a confirm channel and waits for the ack: no ack,
  or the broker down, raises and the relay retries. `TOutboxAmqpConsumer` runs one handler on
  a queue of its own, with three queues per consumer (`agenda.email` bound to
  `appointment.#`; `.retry`, no consumer, a TTL, dead-lettering back; `.dead`): a failure is a
  `Nack` without requeue, so the work queue's dead-letter takes it to the retry queue and back
  after `AMQP_RETRY_MS`; the tries are the work queue's `rejected` entries in `x-death`, and
  at `MaxAttempts` the consumer parks the message in `.dead` and acks it (pascal-amqp-faa's
  `RetryDlqVcl` sample's pattern). Decision 6: handle, record in `PROCESSED_EVENTS`
  (`PROCESSED.*` statements), ack; a redelivered event already recorded is acked unrun.
- The worker: `AMQP_HOST` set, the relay's sink is the broker's and the consumer runs the
  email handler; unset, the local sink as before. The connection reconnects by itself (the
  topology and the consumer come back), and at the start the worker waits for the broker as
  for the database. `--drain` with the broker ends when a round found nothing, both queues are
  empty and no callback runs, three times 250 ms apart. The hourly purge also deletes old
  `PROCESSED_EVENTS` rows.
- The trace crosses the processes as designed: the api's request span is the outbox row's
  `traceparent`; the relay continues it (`outbox appointment.booked`), pascal-amqp-faa's
  publish span puts it in the message, the consumer's `process agenda.email` is its child,
  and the handler's `email send` (new, a client span) times the mail server. Measured in the
  collector: the booking's `X-Request-Id` names one trace with the api's request, its SQL and
  Redis spans, the worker's relay, publish, process and send.
- `docker-compose.yml` (project `agenda`): PostgreSQL 17, Redis, RabbitMQ 3 (management on
  15672), Mailpit (SMTP 1025, UI and API on 8025), the OpenTelemetry Collector (contrib; OTLP
  over HTTP in, a JSON file in the `otel-data` volume and its log out), and the api and the
  worker from `docker/Dockerfile` (built with plain `fpc` on the CI image, run on
  `debian:bookworm-slim` with libsqlite3, libpq, OpenSSL 3 and curl). `DEV_MODE`: a
  development stack. `tools/test_compose.sh` builds and starts it (`--wait` on the health
  checks), seeds it through `tools/compose_api.sh` (the api's commands in the container),
  runs `tools/http_scenarios_mail.sh` (the booking's email in Mailpit, read by
  `tools/mailpit_summary.py`: recipient, subject decoded, the link opening the appointment;
  the cancel through the email's link and its email; the trace in the collector's file, by
  `tools/otel_spans.py`), stops the worker with SIGTERM (a clean stop, exit code 0, no
  `ERROR` in its log) and removes everything. Host ports of its own (19400, 18025, 25672), so
  a stack on the defaults doesn't collide. `tools/ci-test.sh` runs it after the rest.
- `tools/test_http.sh` (PostgreSQL) and `tools/test_http_docker.sh` (PostgreSQL) now start a
  `rabbitmq:3` container, and the worker's scenarios run through it; on SQLite, the local
  sink. Both ways pass the same checks, two workers at once included (two consumers of one
  queue: each event once). `tools/test_fpc_docker.sh` takes `DOCKER_CPUS=1`.
- Found while building, for pascal-amqp-faa: `TAMQPChannel.Close` sends `Channel.Close` and
  only then waits for the callbacks in flight (`DrainInFlight`), so a callback's `Ack` sent
  after the `Close-Ok` reaches a closed channel and the broker closes the whole connection
  (`504 ... channel 2, which is not open`; measured with the embedded broker, the consumer
  test that stopped right after its handler ran). The library could drop an `Ack`/`Nack` on a
  channel it closed (as it already does after a connection drop), or cancel the consumers and
  drain before the `Close`. Here: `TOutboxAmqpConsumer.Stop` cancels, waits for the
  callbacks, and a callback that starts after it neither handles nor acks (the close requeues
  the message; `PROCESSED_EVENTS` covers the rest).
- Found while building: probing RabbitMQ with `docker exec rabbitmq-diagnostics` before the
  server is up creates the Erlang cookie as root, and the server then fails to start
  (`.erlang.cookie: eacces`); the scripts wait for its "Server startup complete" log line and
  the compose health check opens the port. Git Bash turns `/app/...` into a Windows path in
  `docker compose exec` (`MSYS_NO_PATHCONV=1`, which then also stops a `-f /c/...` path from
  converting: the wrapper runs from the project's directory).
- Tests: `Agenda.OutboxAmqpTests` (7, pascal-amqp-faa's embedded broker `TAMQPServer` on an
  ephemeral port, no RabbitMQ; the unit suite now requires `pascal_amqp_faa_server`): the
  published message and its fields, handled once and recorded, a redelivered event not run
  again, a failure retried from the retry queue, one parked after the tries, another kind
  acked unrun, the purge. Waits are polls with a deadline.
- Result: 115 unit tests (from 108), 0 errors, 0 failures, 0 leaks on FPC Windows and Linux
  (Linux also three times at one CPU). HTTP, FPC Windows: SQLite 608 + 74 for the worker
  (local sink), PostgreSQL with Redis and RabbitMQ 619 + 74; FPC Linux (Docker): 608 + 79 and
  619 + 79 (SIGTERM included, through the broker on PostgreSQL). Compose: 22 checks, a clean
  stop. Also by hand, once (2026-10-26, not scripted): the 39 events of a scenario database
  through RabbitMQ (16 emails, 23 skipped: customers without an email), then all 39 published
  again: no email sent twice (`PROCESSED_EVENTS`). Delphi (2026-10-27): 115 of 115, 0 leaks, on Win32 and Win64; HTTP on SQLite
  608 + 68 on both (the worker's 6 fewer checks are heaptrc's reports, FPC only), and on
  Win64 with PostgreSQL, Redis and RabbitMQ 619 + 68. M4 holds on both compilers.
- pascal-amqp-faa **0.4.2** (2026-10-27) fixed the finding above: `Close` cancels the
  channel's consumers and waits for the callbacks before `Channel.Close`, and an `Ack`/`Nack` on
  a channel closed or closing no longer goes out. Adopted the same day; `TOutboxAmqpConsumer.Stop`
  stays (no new work while the process stops, and safe to free before the channel), its comment
  updated. FPC: 115 unit tests, 0 leaks, Windows and Linux; HTTP on PostgreSQL with RabbitMQ
  619 + 74 (Windows); compose 22 checks and a clean stop. Delphi: 115 of 115, 0 leaks, Win32
  and Win64; HTTP on SQLite 608 + 68 on both, on PostgreSQL with RabbitMQ 619 + 68 (Win64).

## M5: design (2026-10-27)

The api offered to an AI agent over MCP, the api and the worker on dashboards, and the four
builds under load. Seven decisions taken with the user (2026-10-27); two of them are changes
in pascal-api-infra-faa, made in sessions there, as pascal-amqp-faa's 0.4.2 was. Nothing built
yet.

What exists today:
- The api serves `/metrics` (Prometheus text): request duration and active requests by
  route, and pascal-db-faa's pool.
- pascal-api-infra-faa 0.24.0 has `TMcpEndpoint`: the documented routes become tools, and each
  call goes back through the api with the caller's token.
- No MCP route, no dashboard, no load test. The worker has no HTTP, so no metrics.

Two gaps found while designing:
- The MCP tools leave header parameters out: the executor sends no header of the model's
  (`PascalApi.Mcp`, `WithoutHeaderParams`; noted in 0.23.0). Moving and cancelling require
  `If-Match` (428 without), so an agent couldn't cancel, which "The product" promises.
- `GET /appointments` returns ids only (professional, service, customer): summarising a day
  would take a call per name.

### Decisions (user, 2026-10-27)

1. **`If-Match` and `Idempotency-Key` through MCP: fixed in pascal-api-infra-faa.** A
   documented header parameter becomes a tool argument when the route opts in, per parameter,
   and the executor sends it as that header. The same change gives `Idempotency-Key` to the
   booking tool: a model that repeats a call is the case the key exists for. Not taken: a
   version in the body as an alternative to `If-Match` (two ways to say one thing), or moving
   and cancelling out of MCP (the product's promise).
2. **The tools**: one `/mcp`, behind JWT, with a staff or owner token. In: availability,
   list and read appointments, book, move, cancel, the day (decision 3), list and read
   customers, services and professionals, create a customer. Out (`NoMcp`): login, refresh
   and logout, users, every delete, working hours and time off changes, creating or changing
   services and professionals, the public routes. Every tool named by `OperationId` (the
   derived names drop a final "s": `list_appointment`).
3. **A new route, `GET /agenda/day?date=&professional=`**: one day in the tenant's time zone,
   each appointment with the professional's, the service's and the customer's names, its
   status and version; `professional` optional. The MCP tool "the day", and the desktop
   client's main view in M6.
4. **The worker's metrics over OTLP**, to the collector already in the compose file, which
   Prometheus reads. The exporter is pascal-api-infra-faa's, next to the traces' one
   (`PascalApi.Otlp`; its observability design lists "metrics over OTLP" as not done), from
   `PcMetrics`, pushed on an interval. The worker keeps no port open. Not taken: a small HTTP
   server in the worker for `/metrics` and `/health`.
5. **Metrics of the application**, in `PcMetrics` with OpenTelemetry names:
   - worker: outbox rows pending and the oldest one's age, events published, events handled
     by kind and result (done, retried, parked), emails sent and skipped, the send's duration;
   - api: bookings by channel (staff, public) and result, slot conflicts, bookings made
     without the lock because Redis was down;
   - RabbitMQ: its own Prometheus plugin (queue depth, unacked).
6. **Dashboards**: Prometheus and Grafana in the compose file, three dashboards kept in the
   repository and provisioned at start (api, worker, broker). A script checks that
   Prometheus's targets are up, that the dashboards' queries return series after the
   scenarios, and that Grafana loads the three.
7. **Load test with k6**, run in Docker (no install), its scripts in `load/`:
   - scenarios on PostgreSQL with Redis: reads (availability, the day, lists), bookings with
     several clients on one slot, the public routes;
   - targets: FPC on Linux (the compose file), FPC on Windows, Delphi Win64 and Win32, all on
     the same PostgreSQL;
   - a run fails on any 5xx, two bookings of one slot, a leak at the stop, memory growing
     between two runs, or the api's metrics disagreeing with k6's counts; the speed is
     recorded, not gated;
   - `tools/ci-test.sh` gets a short run (about 20 s); the full run is by hand.

### What follows from rules already set

- **A tool call is a request**: authenticated by the caller's token, counted by the rate
  limit, logged, in the MCP request's trace; a role the route refuses is an `isError` result.
- **The MCP check uses the official client**, as pascal-api-infra-faa's CI does (the Python
  SDK, `mcp` 2.0.0): list the tools, read the day, book, move and cancel with `If-Match`.
- **The new route and metrics** are unit-tested and in the HTTP scenarios on both compilers
  and both databases; `promtool check metrics` on the api's `/metrics`.
- **Acceptance** as in every milestone: FPC Windows and Linux, Delphi Win32 and Win64, 0 leaks.

### Known limits, expected

- **The comparison is between stacks, not compilers alone**: Horse's HTTP server is Indy on
  Delphi and fphttpserver on FPC, and Linux runs inside Docker Desktop's VM on this machine.
- **An MCP client needs a valid access token** and renews it outside MCP; a refresh token has
  no place in a model's context (pascal-api-infra-faa's rule).

### M5: the day and the MCP tools (2026-10-27)

- pascal-api-infra-faa **0.25.0** and **0.26.0**, made for this milestone (decisions 1 and 4)
  and adopted the same day; same dependencies as 0.24.0. 0.25.0: `McpHeader` makes a
  documented header a tool argument (`If-Match` the tool's `ifMatch`, `Idempotency-Key` its
  `idempotencyKey`), the reserved headers refused at `Register`, a value that isn't printable
  ASCII an `isError` without calling the api. 0.26.0: `TOtlpMetricsExporter`, for the worker
  (the next step).
- `GET /agenda/day?date=&professional=` (`src/Agenda.Day`, statement `APPOINTMENT.DAY`): the
  appointments that start on the tenant's local day, any status, by start, each with the
  professional's, the service's and the customer's names, UTC and the tenant's clock
  (`localStart`, `localEnd`), and its version. An unknown professional is a 404; the date's
  rules are the availability's (`invalid_date`, `date_out_of_range`). No paging: a day is
  bounded by the working hours.
- `POST /mcp` (`TMcpEndpoint`, after every route; the api's own base URL on 127.0.0.1): 18
  tools, each named by `OperationId` (`get_day`, `get_availability`, `book_appointment`,
  `update_appointment`, `cancel_appointment`, `create_customer`, the reads of the catalog,
  customers, appointments, working hours and time off, `get_me`); 25 routes `NoMcp` (the
  auth routes, users, every delete, the owner's changes, the public routes). The If-Match
  parameter's text says what a model sends: the `version` field in double quotes. The api is
  0.0.4.
- `tools/http_scenarios_day.sh` and `tools/http_scenarios_mcp.sh` (57 checks), sourced by
  `tools/http_scenarios.sh` before the public routes; `tools/mcp_result.py` reads the
  JSON-RPC answers. The MCP checks: the exact tool list, `ifMatch` required, `idempotencyKey`
  optional; the day through `get_day`; a booking repeated with one key (one booking); a key
  with a line break refused; cancel without `ifMatch`, with an old version
  (`precondition_failed`), confirm and cancel with the version read; another tenant's token
  gets `isError`, the owner's reaches the api; no token is a 401.
- `tools/mcp_client_check.py`: the official Python SDK (`mcp` 2.0.0) connects, negotiates
  2026-07-28, lists the tools and runs a model's flow (create a customer, the free slots, book
  twice with one key, the day, confirm, cancel from an old and the current version). The
  owner's and the staff's tokens are taken before the scenarios fill the `/auth/` window.
  `tools/test_http.sh` runs it when `MCP_PYTHON` has the SDK (skipped, and said so,
  otherwise); `tools/test_http_docker.sh` always (the CI image has `mcp==2.0.0`).
- Result: FPC Windows 115 unit tests, 0 leaks; HTTP on SQLite 665 checks (from 608) + the
  worker's 74, on PostgreSQL with Redis and RabbitMQ 676 (from 619) + 74, the official client
  13 of 13 on both. FPC Linux (CI): 115, 0 leaks; 665 + 79 and 676 + 79, the official client on
  both; compose 22 checks. The compose run found a race in its own check, not in the code: the
  trace was read as soon as the worker's send span was there, and the api's batch (exported on
  its own schedule) came later; `tools/http_scenarios_mail.sh` now waits for both. Delphi (the
  api rebuilt): HTTP on SQLite 665 + 68, Win32 and Win64, on PostgreSQL with Redis and RabbitMQ
  676 + 68 (Win64), the official client 0 failed on each.

### M5: the metrics and the dashboards (2026-10-27)

- `src/Agenda.Metrics`: the application's metrics in `PcMetrics`, OpenTelemetry names, every
  label one of a few fixed words. The api: `agenda.bookings` (by `agenda.channel`, staff or
  public, and `agenda.booking.result`: booked, slot_unavailable, refused, failed; counted
  where the booking runs, so an idempotent replay doesn't count again) and
  `agenda.slot_lock.fallbacks` (Redis configured but down). The worker: `agenda.emails` (by
  kind and result: sent, failed, no_address, skipped), `agenda.email.send.duration` (s) and
  `agenda.reminders.queued`. `AgendaMetricsInit` registers them at start.
- The outbox candidate records its own (the units' headers): `outbox.events.delivered` and
  `outbox.events.failed` by kind (the relay), `outbox.handler.runs` by handler, kind and
  result (the local sink), `outbox.consumer.messages` by consumer, kind and result (done,
  duplicate, ignored, retried, parked; the kind is "other" for one the handler doesn't take,
  so a stranger publishing to the exchange can't grow the series), and the gauges
  `outbox.events.pending` and `outbox.events.oldest_age` (s), which `TOutbox.MeasurePending`
  sets from one query (`OUTBOX.PENDING`), every 15 s in the worker.
- The worker pushes its registry with pascal-api-infra-faa 0.26.0's `TOtlpMetricsExporter`
  (with `OTEL_EXPORTER_OTLP_ENDPOINT`; `OTEL_METRIC_EXPORT_INTERVAL`, and one more export at
  the stop); the worker is 0.0.3. The collector's `prometheus` exporter serves them on :8889.
- `docker-compose.yml`: Prometheus 2.53.0 (`docker/prometheus.yml`: the api's `/metrics`, the
  collector with `honor_labels`, so the job stays `agenda-worker`, and RabbitMQ's plugin per
  queue, `/metrics/per-object`) and Grafana 11.2.0, provisioned from `docker/grafana` (the data
  source by uid, three dashboards in the folder Agenda: `agenda-api`, `agenda-worker`,
  `agenda-broker`; anonymous viewers).
- `tools/dashboards_check.py`, run by `tools/test_compose.sh` after the mail scenarios: the
  three targets up, nine series the scenarios must have made, every panel's query accepted by
  Prometheus (one without data yet is listed, not failed: a rate needs two samples), each
  dashboard loaded in Grafana, its data source healthy. Found on the first run: the worker's
  consumer is named after its queue (`agenda.email`), not `email` as in the unit tests.
- Tests: `Metrics_Relay_Handlers_Pending` (Agenda.OutboxTests: delivered, failed, a handler's
  run, the gauges as events come and go) and the consumer's results in the five consumer tests
  of Agenda.OutboxAmqpTests (done, duplicate, retried, parked, ignored as "other"); the
  values are read from `PcMetrics` before and after, since the registry is the process's. The
  HTTP scenarios check the api's bookings by channel and result on `/metrics`.
- Result: FPC Windows 116 unit tests, 0 leaks; HTTP on SQLite 669 + 74, on PostgreSQL with
  Redis and RabbitMQ 680 + 74, the official MCP client on both; FPC Linux (CI): 116, 0 leaks;
  669 + 79 and 680 + 79, the official client on both, promtool on the api's /metrics; compose:
  22 mail checks, the dashboards 0 failed, a clean stop. Delphi: 116 of 116, 0 leaks, Win32 and
  Win64; HTTP on SQLite 669 + 68 on both, on PostgreSQL with Redis and RabbitMQ 680 + 68
  (Win64), the official client 0 failed on each. Not measured on Delphi: the worker's OTLP
  metrics export (the compose stack is FPC on Linux; test_http.sh runs no collector).

### M5: under load (2026-10-27)

- `load/agenda.js` (k6 0.54.0): four scenarios at once for `DURATION` (60 s): reads (the free
  slots, the day, the appointments, the services, a customer search), bookings (a staff user
  books a slot it just read, 409 when another took it, confirms one in ten with `If-Match`),
  a race (4 bookings of one slot arriving together, on a professional of their own) and the
  public routes. Thresholds: no 5xx or network error (`http_req_failed`; a 4xx is an answer),
  every check, no double booking (teardown reads every booked day through `/agenda/day`).
- `tools/load_test.sh <target>`: a fresh PostgreSQL 17 and Redis per target (or SQLite), the
  tenant `load` seeded through the api's commands, two passes; `tools/load_check.py` checks
  each against the api's `/metrics` (its request count but `/metrics` and `/health/*`, the
  staff bookings booked and slot_unavailable: equal to k6's) and the memory between passes
  (at most 1.25 times the first plus 16 MB). Targets: `fpc-linux` (the `agenda-app` image),
  `fpc-win` (a new `Release` build mode in `api/AgendaApi.lpi`: -O2, no heaptrc),
  `delphi-win64`, `delphi-win32` (SQLite: no 32-bit libpq), and `compose` (the running stack,
  its api recreated with the limits raised; the dashboards show the run).
- Found while building, in this order:
  - **The api had no clean stop**: `THorse.Listen` returned only when the process died, so no
    leak report at the stop. Now `Agenda.StopSignal` (Ctrl+C, SIGINT, SIGTERM) and a watcher
    thread: on FPC `fphttpapp`'s `Application.Terminate` (Horse's FPC provider has no
    `StopListen`), on Delphi `THorse.StopListenGraceful` (5 s). Measured on FPC Linux: a
    SIGTERM reaching the main thread interrupts its `accept` (EINTR), FPC's web application
    takes that for an error and listens again (the process went on, in `accept`, with the
    accepted connections in CLOSE_WAIT); the main thread now blocks SIGINT and SIGTERM, so
    they reach the watcher. `tools/test_http_docker.sh` builds the api with heaptrc and
    stops it with SIGTERM at each of its two starts.
  - **One block of 64 bytes at the stop**, FPC Linux, with no call trace: none when the api
    served no request, the same one after two requests or the whole scenarios (thousands); a
    500 ms wait before the cleanup changed nothing. Not found yet; the check accepts exactly
    this and fails on anything else. To look at with a minimal Horse program on FPC (is it
    fphttpserver's, Horse's or ours).
  - **On PostgreSQL the database pool isn't freed at the stop**, FPC Linux, every run (320
    blocks, the same each time; with Redis or without, with its outage scenario or without):
    after "agenda-api stopped", `EThreadError: Thread error` escapes `FPool.Clear` in
    `TConnectionPool.Destroy` (pascal-db-faa 0.17.0, line 1443), so the pool, its
    connections (the first ones, the migration's, the requests') and the database object stay
    allocated. FPC's cthreads raises that error when a mutex fails to lock, unlock or be
    destroyed (one destroyed while locked); not seen on SQLite. Suspected, not shown: a lock
    inside SQLdb's `TPQConnection` left held. For pascal-db-faa, with a reproduction; the
    check reports this exact case as known and fails any other.
  - **FPC 3.2.2's server closes the connection after every response without saying so** (no
    `Connection` header; Horse's FPC provider notes it, keep-alive only from FPC 3.3.1). A
    client that keeps the connection for its next request writes to a closed socket: k6 (Go)
    got "EOF" on a `PUT`, which never reached the api (curl reconnects silently). The api
    now answers `Connection: close` on FPC before 3.3.1 (`ConnectionClose`, a middleware).
    Candidate for pascal-api-infra-faa or Horse.
  - **Horse's listen queue is 15**; with a connection per request, dials timed out under
    load. `LISTEN_QUEUE` (128) sets `THorse.ListenQueue`.
  - **Delphi's WebBroker serves 32 requests at once** (`TWebRequestHandler.MaxConnections`;
    Horse changes it only when `THorse.MaxConnections` is set) and answers the next one with
    a 500 of its own, "Maximum number of concurrent connections exceeded", before Horse: no
    log line, no metric. Measured on Delphi Win64 with PostgreSQL: 75% of k6's requests
    failed so, the api counted 8725 of 34273; it showed as the count check failing.
    `MAX_CONNECTIONS` (256) sets it on Delphi. `load/agenda.js` now logs the first failed
    checks of each virtual user with the status and the body of a 5xx. Candidate for
    pascal-api-infra-faa's guide (a Delphi api under load) or Horse's default.
  - **The database pool (10) answered 503 under load**: a booking holds its connection while
    it waits for the professional's row lock, so 20 clients booking one professional left the
    reads without one (pascal-db-faa's `EPoolTimeoutException` after 5 s). And a booking
    already committed answered 503 when completing its `Idempotency-Key` found no connection:
    the client gets an error for an appointment that exists (a retry with the key meets the
    key still in flight). For pascal-api-infra-faa's idempotency (complete inside the
    caller's transaction?) or the application. The load runs use `DB_POOL_MAX=40`
    (`LOAD_POOL`); `docker-compose.yml` passes `DB_POOL_MAX` and `RATE_LIMIT` now.
  - **Docker Desktop's port forwarding drops dials** at a connection per request ("dial: i/o
    timeout" on both the Windows and the Linux api through `host.docker.internal`; none with
    k6 on the api's own network: 0 errors, 277 req/s against 38). k6 runs next to the api:
    in a container on its network, or installed on Windows for the Windows targets.
  - `tools/test_compose.sh` ran `docker compose down -v` on the project `agenda`, the
    development stack's name: running it with a development stack up would remove that
    stack and its data. Caught before it ran; it has a project of its own now
    (`COMPOSE_PROJECT_NAME=agenda-test`).
- Results (20 virtual users for reads, 10 booking, 4 public, 20 race bookings a second; the
  rate counts setup and teardown too):

  | Target | Pass | Requests | Rate | p50 | p95 | p99 | Booked | Race | Memory |
  |---|---|---|---|---|---|---|---|---|---|
  | compose (FPC Linux, -O2) | 1 | 17580 | 283/s | 111 ms | 263 ms | 419 ms | 1164 | 300 of 1200 | 61 MB |
  | compose | 2 | 15809 | 256/s | 123 ms | 311 ms | 476 ms | 1180 | 300 of 1200 | 68 MB |
  | fpc-linux | 1 | 16027 | 259/s | 97 ms | 676 ms | 1178 ms | 916 | 298 of 1192 | 23 MB |
  | fpc-linux | 2 | 17750 | 286/s | 92 ms | 577 ms | 1023 ms | 984 | 299 of 1193 | 25 MB |
  | fpc-win (k6 2.2.0 on Windows) | 1 | 10891 | 168/s | 127 ms | 787 ms | 3689 ms | 928 | 298 of 1190 | 34 MB |
  | fpc-win | 2 | 11980 | 185/s | 125 ms | 667 ms | 2527 ms | 966 | 299 of 1194 | 34 MB |
  | fpc-win, SQLite | 1 | 14185 | 221/s | 76 ms | 525 ms | 1635 ms | 681 | 297 of 1190 | 44 MB |
  | fpc-win, SQLite | 2 | 20594 | 330/s | 66 ms | 241 ms | 1030 ms | 911 | 300 of 1201 | 45 MB |
  | delphi-win64 (MAX_CONNECTIONS 256) | 1 | 7645 | 113/s | 163 ms | 1579 ms | 6238 ms | 758 | 294 of 1174 | 33 MB |
  | delphi-win64 | 2 | 7443 | 111/s | 170 ms | 1669 ms | 6279 ms | 742 | 295 of 1177 | 34 MB |
  | delphi-win32, SQLite | 1 | 10849 | 176/s | 78 ms | 821 ms | 6687 ms | 262 | 218 of 1192 | 30 MB |
  | delphi-win32, SQLite | 2 | 10346 | 169/s | 80 ms | 843 ms | 6687 ms | 263 | 225 of 1191 | 31 MB |

  Not every pass above passed its checks (2026-10-28):
  - **Delphi with PostgreSQL is slower than FPC on the same machine** (113/s against 185/s,
    every route: `GET /services` p50 94 ms against 63; the bookings p95 6 s against 3.8 s), and
    5 requests of 15088 got 503 (`EPoolTimeoutException`, the pool's 40 all held). Delphi uses
    pascal-db-faa's FireDAC adapter, FPC its SQLdb one; where the time goes was not looked into.
  - **On SQLite, writers under load get "database is locked"**, answered 409
    (`ELockConflictException`): 238 times on Delphi (FireDAC), 19 on FPC (SQLdb). Every one
    after the busy timeout (5 s) ran out: the requests took 6.3 s at least (their access log
    lines, by trace id). SQLite has one writer at a time and a booking holds the write lock
    from its first statement (the professional's row) to its commit, so under load the queue of
    writers passes 5 s; on Delphi sooner, each operation being slower (the item above). A
    first guess, a read transaction upgraded to a write failing at once, was wrong: the
    booking's and the idempotency store's transactions start with a write. Capacity, not a
    library bug: SQLite is the development engine here.
  - **Why Delphi was slower** (pascal-db-faa, 2026-10-28, gotcha 55; measured there without
    HTTP, SQLite): Delphi's own memory manager keeps a program's threads at one thread's
    throughput. FireDAC made about 2,100 operations a second with 1, 8 or 32 threads, SQLdb
    2,120 → 9,177; Zeos, the same code on both compilers, 4,057 on FPC and 560 on Delphi with
    32 threads. On the Windows process heap, FireDAC went to 6,214 (32 threads); on
    PostgreSQL, 475-689 → 779-857, SQLdb 916-1,020. Not the adapter. The api and the worker
    now start with `Agenda.WinHeap` (first unit; the startup line says which manager runs;
    `MEMORY_MANAGER=default` keeps Delphi's, for comparing).
  - **pascal-api-infra-faa 0.27.0 adopted** (2026-10-28): a booking's key whose answer can't be
    stored is logged ("the Idempotency-Key answer was not stored, sent anyway") and the 201
    goes out. FPC Windows, SQLite: the api's bookings equal k6's 201s again (they differed by
    2 before; 3 such lines in a run). And the counts: a 409 other than `slot_unavailable` is
    the database busy (SQLite's writer lock waited out), counted apart by k6 (`agenda_busy`)
    and compared with the api's failed bookings; the key's claim, before the booking, meets the
    same lock, so a claim that fails counts as a failed booking now (`StartBooking`). A run on
    a busy machine (pascal-db-faa's MySQL and SQL Server containers up) made 35 requests a
    second and 29 503s from the pool; again on a quiet one, 163/s and none.
  - **And a booking committed then answered 409**, the case already found with the pool: the
    `Idempotency-Key`'s completion, after the commit, met the lock. The database had 568
    appointments, k6 got 525 201s: the 43 others all on the scenario that sends a key; 12 keys
    stayed in flight (`DONE=0`), the rest were released, so a retry with the key runs the
    booking again and gets 409 (the slot taken, by the client's own appointment).
    FPC: 2 in a pass. This moves the candidate below ("completed after the caller's commit")
    from a rare case to one in four bookings under write contention on SQLite.

  Every pass: 0 failed requests, every check, no double booking, the api's counts equal to
  k6's. FPC on Windows has a long tail (p99 2.5 to 3.7 s, the slowest request 16 to 23 s)
  that FPC on Linux hasn't: not looked into. k6 on Windows installed by the user (winget,
  2.2.0; the container runs 0.54.0): the same script, the same summary. Not measured yet:
  Delphi's Release builds (the IDE).
- CI (FPC Linux, tools/ci-test.sh): 116 unit tests, 0 leaks; HTTP 669 + 79 (SQLite) and 680 + 79 (PostgreSQL), the official MCP client on both, the api stopped by SIGTERM at each start (SQLite: the known block of 64 bytes; PostgreSQL: the known pool error); compose 22 + the dashboards; the short load run (20 s, 10 users) 318/s, p95 110 ms, every check. FPC Windows: HTTP 669 + 74 and 680 + 74, the official client on both. Delphi (Debug): HTTP 669 + 68 on Win32 and Win64, 680 + 68 on Win64 with PostgreSQL, the official client on all three; Ctrl+Break (sent by a script to the api in a process group of its own) stops it through StopListenGraceful on both, exit code 0 in 0.2 s, "agenda-api stopped". The Delphi api has no leak report at its stop (the unit tests carry Delphi's leak check). Delphi under load: see the WebBroker limit above and "M5: closed" below.

### M5: closed (2026-10-28)

Every target under load passes (two passes of 60 s, every check, the api's counts equal to
k6's, no double booking, the memory flat), with pascal-api-infra-faa 0.27.0, `MAX_CONNECTIONS`
and `Agenda.WinHeap`. Delphi's builds measured with the Windows process heap and, for
comparison, with Delphi's own manager (`MEMORY_MANAGER=default`):

| Target | Memory manager | Pass | Requests | Rate | p50 | p95 | p99 | Booked | Busy 409 | Memory |
|---|---|---|---|---|---|---|---|---|---|---|
| delphi-win64, PostgreSQL | windows heap | 1 | 13234 | 188/s | 100 ms | 701 ms | 2566 ms | 951 | 0 | 33 MB |
| delphi-win64, PostgreSQL | windows heap | 2 | 13171 | 201/s | 103 ms | 706 ms | 2495 ms | 944 | 0 | 34 MB |
| delphi-win64, PostgreSQL | delphi | 1 | 8875 | 135/s | 161 ms | 1053 ms | 4889 ms | 864 | 0 | 33 MB |
| delphi-win64, PostgreSQL | delphi | 2 | 8108 | 123/s | 170 ms | 1403 ms | 5437 ms | 804 | 0 | 34 MB |
| delphi-win32, SQLite | windows heap | 1 | 36032 | 587/s | 32 ms | 140 ms | 674 ms | 850 | 2 | 36 MB |
| delphi-win32, SQLite | windows heap | 2 | 29951 | 487/s | 39 ms | 169 ms | 679 ms | 788 | 7 | 38 MB |
| delphi-win32, SQLite | delphi | 1 | 10865 | 175/s | 82 ms | 784 ms | 6689 ms | 299 | 90 | 31 MB |
| delphi-win32, SQLite | delphi | 2 | 10911 | 177/s | 81 ms | 791 ms | 6672 ms | 295 | 95 | 30 MB |
| fpc-win, PostgreSQL | fpc | 1 | 11093 | 163/s | 132 ms | 740 ms | 2940 ms | 950 | 0 | 34 MB |
| fpc-win, PostgreSQL | fpc | 2 | 10690 | 163/s | 159 ms | 663 ms | 2702 ms | 968 | 0 | 35 MB |
| fpc-win, SQLite | fpc | 1 | 10954 | 172/s | 138 ms | 593 ms | 1025 ms | 914 | 0 | 46 MB |
| fpc-win, SQLite | fpc | 2 | 10124 | 161/s | 168 ms | 572 ms | 1099 ms | 900 | 0 | 68 MB |

- On the process heap Delphi Win64 with PostgreSQL went from 123-135 to 188-201 requests a
  second (FPC Windows: 163), and Delphi Win32 with SQLite from 175 to 487-587, its busy 409s
  from 90-95 a pass to 2-7: each booking holds SQLite's writer lock for less time.
- The memory manager was the gap between the compilers that M5 set out to measure, not the
  database adapter or Indy. FPC on Linux ran in Docker with k6 on its network (259-286/s,
  "M5: under load"): not the same setup, so not compared here. The FPC Windows tail (p99 about 3 s, the slowest request up
  to 20 s on PostgreSQL) is still not looked into.
- Delphi Debug: HTTP 669 + 68 on Win32 and Win64, 680 + 68 on Win64 with PostgreSQL, the
  official MCP client on all three, each api on the process heap. FPC Windows: unit tests
  116, 0 leaks; HTTP 669 + 74 and 680 + 74. CI (FPC Linux): green, the two stop cases known
  (the block of 64 bytes; pascal-db-faa's pool error on PostgreSQL, open).
- Still open from M5: the PostgreSQL pool's `EThreadError` at the stop (pascal-db-faa, prompt
  given), the 64-byte block at the stop, the FPC Windows tail; candidates: `Connection: close`
  on FPC 3.2.2, `MAX_CONNECTIONS` for a Delphi api, `Agenda.WinHeap`, `Agenda.StopSignal`.
  `CompleteOn` (closing the in-flight window of a key whose answer wasn't stored) not
  adopted: 2-3 such keys a run on SQLite under load, none on PostgreSQL.

## M6: design (2026-10-28)

A desktop client for the staff's day on the server's own DTOs: a typed HTTP client with
refresh, retry and the trace, and the screens built in code from one source for VCL (Delphi)
and LCL (Lazarus). Nine decisions taken with the user (2026-10-28); one of them adds a
library outside the `*-faa` family (OPCB). Nothing built yet but the probe below.

What exists today:
- The DTOs live in the units of their repositories: `Agenda.Appointments` has `PascalDb.Paging`,
  `PascalApi.Tenancy` and `Redis.Lock` in its interface; `Agenda.Day` and `Agenda.Availability`
  use `PascalDb.Interfaces`. A client that uses them as they are links pascal-db-faa, FireDAC
  and the Redis client.
- What a client can take: `PascalApi.Dto` needs pascal-common-faa only; `PascalApi.OpenApi`
  only the mapper and the validators, so the `TApiSchema.Describe` calls in each unit's
  `initialization` can go with the DTOs. Not `PascalApi.Http` (pascal-db-faa in its
  implementation), so not `PascalApi.Preconditions` either: the client reads the error body
  (`code`, the fields) itself.
- The switch between `THTTPClient` (Delphi) and `fphttpclient` (FPC) is written twice in
  pascal-api-infra-faa (`PascalApi.Otlp`, the MCP executor); the client would be the third.
- What the server asks of a client: an access token of 900 s, a refresh token of 30 days,
  rotated, a spent one coming back revokes its family (so two refreshes racing on one token
  log the user out); `/auth/` limited to 10 a minute per client address.
- Forms on both compilers: the skill's `references/forms-dfm-lfm.md`. The ten `samples/*Vcl` of
  pascal-amqp-faa keep a `.dfm` and an `.lfm` next to one `.pas` (checked on LCL/GTK2 on Linux
  too); both IDEs rewrite those files whole (DPI, `Anchors` order, accents), and they are kept
  in step by hand. pascal-snake builds its form in code (`CreateNew`, no form file). OPCB
  (https://github.com/fabianoallex/opcb-object-pascal-component-builder, the author's, Apache
  2.0) builds controls in code with a fluent API on VCL, LCL and FMX; its suites: 213 tests on
  FPC, 207 on Delphi, 0 leaks (its README). Its only form built from one source on both
  compilers is a sample with five buttons.

### Decisions (user, 2026-10-28)

1. **DTO units of their own.** Each group's interfaces, classes, status constants, error codes
   and `Describe` calls move to a unit that needs only `PascalCommon.Optionals`,
   `PascalJsonMapper`, `PascalApi.Dto` and `PascalApi.OpenApi` (`Agenda.Appointments.Dtos`,
   `Agenda.Day.Dtos`, `Agenda.Customers.Dtos`...); the server's units use them, its behaviour
   unchanged (the HTTP scenarios say so). Not taken: the units as they are (the database in a
   desktop program), DTOs generated from `/openapi.json` (no reuse left to validate).
2. **The client checks a body with the server's limits**: `TApiSchema.Check` before sending,
   the same field failures a 400 would list, without the request. The server still decides.
3. **The whole client on both compilers, the screens built in code with OPCB.** The core (the
   DTO units, the typed client, the view models) and the forms build on Delphi Win32/Win64
   (VCL) and Lazarus (LCL) from the same source: no `.dfm`/`.lfm`, each form calls `CreateNew`
   and lays itself out with OPCB, a submodule (`external/opcb`, at its tag v0.2.0, the first
   with the probe's two fixes). The logic lives in view models with tests; a form reads their state and passes its
   events on (pascal-snake's rule). On Linux the core's tests run in CI; the screens are not
   built there (the CI image has no LCL). If OPCB fell short, the fallback was `CreateNew` with
   controls placed by hand; `.dfm` + `.lfm` was not taken (the skill's measured cost).
4. **HTTP**: each compiler's own client behind `IHttpTransport` (one `Send`: method, URL,
   headers, body in; status, headers, body out), with a fake one for the unit tests:
   `THTTPClient` on Delphi (WinHTTP, the TLS of Windows, no OpenSSL to ship), `fphttpclient`
   with `opensslsockets` on FPC. The third copy of that switch is a candidate (pascal-common-faa
   or pascal-api-infra-faa). Not taken: Indy (OpenSSL 1.0.2 for TLS), Synapse (OpenSSL on the
   Windows desktop too).
5. **Two layers.** `Agenda.HttpClient`, the "Typed HTTP client" candidate, knows nothing of the
   agenda: base URL, bearer token, refresh, retry, `traceparent`, JSON through `TJsonMapper`,
   the error body read into an exception (status, `code`, fields), `ETag`/`If-Match`,
   `Idempotency-Key`. `Agenda.Client` has one hand-written method per route (`GetDay`,
   `GetAvailability`, `Book`, `Move`, `SetStatus`, `Cancel`, `FindCustomers`, `CreateCustomer`...),
   taking and returning the server's DTO interfaces.
6. **Refresh once at a time, the refresh token in memory only.** One refresh in flight; a
   caller that needs a token meanwhile waits for it and uses the new one, so a client never
   revokes its own family. Renewed before it runs out (`expiresIn` less a margin), and on a 401
   once more, then the request again. The program logs in when it starts and logs out
   (`/auth/logout`) when it closes; keeping the token between runs (DPAPI) is out of M6.
7. **Retry**: a GET up to three times with a backoff on a lost connection, 502, 503 and 504,
   after the `Retry-After` of a 429 or 503; a booking with an `Idempotency-Key` made by the
   client for each user action and kept across its tries, so it retries the same way; a PATCH
   or a cancel never retried on its own: on a lost connection the client reads the appointment
   again and shows it (a second try would meet a 412). A 409 `slot_unavailable` or a 412 is
   told to the user, and the day read again.
8. **The screens are the staff's day**: login (server, slug, email, password); the day as the
   main view (`GET /agenda/day`, by professional, moving between dates); booking (customer,
   service, professional, free slots); moving, the status (confirmed, done, no_show),
   cancelling; customers (search, create, edit: a PATCH with the email absent, null or a value,
   the three states of an optional sent by a client). The owner's screens (services,
   professionals, working hours, time off, users) stay out. The day is read again after each
   change, on F5 and every 60 s. No call runs on the UI thread: pascal-common-faa's pool runs
   it, `TThread.Queue` brings the result back, a window that closes waits for its call.
9. **One trace from the click**: a trace id per user action, sent as `traceparent` (its retries
   and refresh in the same trace); the client's spans exported through `PascalApi.Otlp` only
   when `OTEL_EXPORTER_OTLP_ENDPOINT` is set, so one trace runs from the click to the worker's
   email.

### What follows from rules already set

- **No time zone in the client**: it shows `localStart`/`localEnd` as the server sends them and
  books the instant of the slot as the availability gave it.
- **Tests**: the core's unit tests with the fake transport (refresh once at a time, retry, the
  key kept, the error body read) on the four targets; a console program, `AgendaClientCheck`,
  run by `tools/test_http.sh` as `mcp_client_check.py` is, through the real api: login, the day,
  a booking twice with one key, a move with `If-Match`, a 412 from an old version, a cancel, and
  with a short `ACCESS_TOKEN_SECONDS` two calls at once on a spent token (one refresh, the family
  alive); the forms by hand from a written list, on VCL and LCL.
- **Settings**: the server's address from a `.env` next to the program (`TAppConfig`).
- **Candidates**: `Agenda.HttpClient`, the transport switch, the error body in a light unit;
  listed in "Library candidates" when built.
- **Acceptance** as in every milestone: FPC Windows and Linux, Delphi Win32 and Win64, 0 leaks
  (the screens: Windows, both compilers).

### Known limits, expected

- **Behind one address**: ten logins or refreshes a minute per address on `/auth/`; an office
  whose desktops share one public address and all log in at eight meets it. Recorded, not
  changed now.
- **No push**: another user's change reaches the day within 60 s.
- **The screens are checked by hand**, not by a script; the view models carry the tests.

### M6: the OPCB probe (2026-10-28)

`external/opcb` at **b61c993** (2026-08-09, no tags). A probe outside the repository (the M4
Synapse probe's way): a main window like the day (a bar on top, a `TListView` with `alClient`)
and a login dialog in OPCB's grid mode, both `CreateNew`, one `.pas` in `{$MODE DELPHI}`
calling OPCB (`{$mode objfpc}`, generics) with method pointers only; a program that builds
both, resizes the window and checks the layout, then quits.

- FPC 3.2.2 Win64 (Lazarus 4.4): 10 of 10 checks, 0 unfreed blocks: the list fills the window
  and follows a resize, accented text kept, the click handler wired, the grid in two columns,
  the buttons below it, the dialog sized to its content (`RecalcParentSize`).
- **Found (OPCB)**: in grid mode a control without an explicit height is placed with height 0:
  its top is the cell's middle (`AdjustRectForCellLayout` gets 0), the LCL then gives the
  `TEdit` its own height, and what follows the grid (`GridFinish`, `BreakLine`) starts over its
  last row. The creator's `SetControlHeight` default comes too late for a cell: `Add` applies it
  (`ApplyDefaultControlSize`) after the control is built at the position computed with height
  0, and over the cell's stretched height. Here: `GridCellStrechAll`, the cell's height given to each
  control (the same layout on the VCL); the height-0 case itself measured on the LCL only. To
  be fixed in OPCB, not here. Fixed in OPCB v0.1.0 (see below).
- Also learnt: after `GridFinish` the grid is one block in the outer level's direction; a row
  below it needs `BreakLine` in that level (OPCB's `grid-autoexpand` sample does `.Break`).
- Delphi 12 Win64 (the same probe, `OpcbProbeDelphi.dpr`, a `.dproj` from the skill's
  scaffold; run by the user, Debug and Release): 9 of 10, the same layout as the LCL (the grid,
  the buttons below it, the list following a resize), and one failure the LCL hides:
- **Found (OPCB)**: `RecalcParentSize` sets the parent's `Height` and `Width`. On the LCL for
  Windows a form's `Height` is its client area (the dialog came out 167 high, 155 needed); on
  the VCL it includes the caption and the borders, so the dialog's client area was 128 for
  buttons that end at 155 (39 pixels short), and its width short the same way (the edits cut
  at the right; the probe didn't check the width). `ClientHeight`/`ClientWidth` for a
  `TWinControl` parent would be right on both. Here: the client size set by the form from its
  last control. To be fixed in OPCB. Fixed in OPCB v0.1.0 (see below).
- Also different, harmless: a `TLabel` stretched to its cell keeps the cell's height on the
  VCL (28) and its text's on the LCL (15).
- Delphi 12 Win32 builds too; no leak report at the stop on either platform
  (`ReportMemoryLeaksOnShutdown`, a dialog only when something leaked).

### M6: the DTO units (2026-10-28, decisions 1 and 2)

- Six units of their own: `Agenda.Appointments.Dtos` (the statuses, `STATUS_CANCELLED` among
  them, moved from `Agenda.Availability`; the error codes; the ordering), `Agenda.Availability.Dtos`
  (its error codes; `MAX_AVAILABILITY_DAYS`, moved from `Agenda.Slots`, where only the
  description used it), `Agenda.Day.Dtos`, `Agenda.Customers.Dtos`, `Agenda.Professionals.Dtos`,
  `Agenda.Services.Dtos` (its limits). Each holds the interfaces, the classes, the mapper's
  registrations and the `Describe` calls; it uses pascal-common-faa, pascal-jsonmapper-faa and
  `PascalApi.Dto`/`PascalApi.OrderBy`/`PascalApi.OpenApi` only. The server's units use them
  (`Agenda.Day`, `Agenda.Appointments` and `Agenda.Public` gained a `uses`). The users',
  working hours' and time off's DTOs stay in their units (no screen of the client needs them);
  `Agenda.AuthDtos` was already apart.
- Checked: a program on the six units and `Agenda.AuthDtos`, built with no pascal-db-faa,
  pascal-redis-faa or Horse in its search path (FPC Win64): a booking to JSON and back, and a
  service of 900 minutes refused by `TApiSchema.Check` before any request (`durationMinutes`),
  0 unfreed blocks.
- The api unchanged: FPC Windows, HTTP on SQLite 669 + 74, on PostgreSQL with Redis and RabbitMQ
  680 + 74, the restart; unit tests 116, 0 leaks, on FPC Windows and Linux. Not run: the official
  MCP client (this machine's `python` has no `mcp`). Delphi: the api builds on Win32 and
  Win64 with the six units (the user, in the IDE).
- Found while running them: the compose file's api, left up, publishes port 9400, the runner's
  default; the health check reached it before the api under test bound the port, so the token
  for the restart came from it ("no token before the restart", the same on the last commit).
  `tools/test_http.sh` now stops with a message when the port already answers; `PORT=9410` runs
  beside the compose file.

### M6: OPCB v0.2.0 adopted (2026-10-28)

- OPCB fixed both findings in its v0.1.0 (its first tag) and added `SetDefaultProp`/
  `UnsetDefaultProps` in v0.2.0 (c03d7a6; its suites: Lazarus 243, Delphi Win32 237).
  `external/opcb` moved from b61c993 to v0.2.0; nothing here changes (the probe lives outside
  the repository).
- The probe again on FPC Win64, without the workaround (`GridCellStrechHorizontal`, the case of
  the first finding): with the creator's default height (23) each edit is centered in its cell
  (tops 14, 42, 70, 98 in cells of 28 from 12) and the buttons start below the grid (132);
  with no default at all each control is centered by its own height (edits 23 at 14..., labels
  15 at 17...). 10 of 10 both ways, 0 unfreed blocks. The dialog is still 167 high on the LCL.
- Delphi 12 Win32 and Win64 with v0.2.0 (run by the user): 10 of 10 on both, the same tops as
  the LCL (edits at 14, 42, 70, 98; buttons at 132), and the dialog's client area 167 high, as
  on the LCL (128 before the fix). Harmless: a `TLabel` there takes the default height (23) and
  the cell's width (80), the LCL one its text's size.

### M6: the HTTP transport (2026-10-29, decision 4)

- `src/Agenda.HttpTransport`: `IHttpTransport.Send` takes a `TTransportRequest` (method, URL,
  headers, text body, timeout) and gives a `TTransportResponse` (status, headers, text body);
  `NewHttpTransport` is `THTTPClient` on Delphi and `fphttpclient` with `opensslsockets` on FPC,
  one client per exchange (callable from the pool's threads), redirects off, 15 s by default.
  Every status is an answer; `EHttpTransport` only when there was none (refused, timeout, TLS),
  which leaves to the caller whether the request may go again (decision 7). Bodies are UTF-8
  through pascal-common-faa's `PascalCommon.Utf8`, not `PascalApi.Text`.
- `src/Agenda.HttpTransport.Fake`: answers from a queue (`Answer`, `Fail` for a lost
  connection), keeps the requests, thread-safe; an unexpected request raises
  `EFakeHttpTransport`, so it fails the test instead of looking like a lost connection.
- Found: `fphttpclient` sends no `Content-Length` when a request has no body, and a POST
  without one (the cancel) would go without a length. The transport always gives POST, PUT
  and PATCH a body, empty when there is none (`HttpMethodHasBody`).
- Found: the client can't take `PascalApi.Http`'s `THttpHeader` (nor anything in that unit):
  its implementation uses pascal-db-faa. The same holds for decision 9: `PascalApi.Otlp`
  uses `PascalApi.Http`, so a client exporting spans would link pascal-db-faa's units. To
  settle when decision 9 is built (an OTLP exporter with no pascal-db-faa in pascal-api-infra-faa,
  or `THttpHeader` in a unit of its own there); a library change, the user's decision.
- Tests: 8 more (`Agenda.HttpTransportTests`: the header lines, headers in any case, the
  methods with a body, the fake, the compiler's own client on a closed port), 124 in all,
  0 failures, 0 leaks on FPC Windows and Linux. The real client checked on FPC Win64 against
  the api (a probe outside the repository): the health check, a failed and a good login, a
  customer created as "João Ação Müller" and found by `search=acao` with the same name, a
  POST without a body answered 428 (not 411), a closed port as `EHttpTransport`; 0 unfreed
  blocks. `AgendaClientCheck` (decision 5 on) will run such exchanges in `tools/test_http.sh`.
  Delphi 12 Win32 and Win64 (the user): 124 of 124, no leak.

### M6: the generic client (2026-10-29, decisions 5 and 7)

- `src/Agenda.HttpClient`, `TApiHttpClient.Execute(TApiRequest)`: JSON text in and out (the
  mapping is the typed layer's), `Accept`, the body's type, `If-Match`, `Idempotency-Key`, a
  `traceparent` per try in the request's trace (`TraceId`, one per user action; a new trace
  when none), the bearer token from an `IApiCredentials`. A 2xx is returned; any other status
  raises `EApiError` with the error body's message, `code` and `fields` as `TPcFieldErrors`
  (the type a local `TApiSchema.Check` fills, so a screen shows both alike); a body that isn't
  JSON leaves the status alone ("GET /x answered 404").
- Decision 7 inside it: a GET or HEAD, and a request with an `Idempotency-Key`, go again on a
  lost connection, 429, 502, 503, 504, and (keyed only) on 409 `idempotency_key_in_flight`,
  which the first draft of the decision missed: the retry of a booking whose first try still
  runs meets that 409 (pascal-api-infra-faa's lease), and waiting is right. Three tries in all,
  300 ms then 600 ms, or the answer's `Retry-After` in seconds; one longer than 10 s goes to the
  caller instead. A PATCH or a cancel is never sent twice (`NoRetry` stops a GET too). The
  waits go through a `Sleep` property, recorded by the tests.
- Decision 6's hook: on a 401 the client asks `IApiCredentials.Renew(staleToken)` once and,
  when it gives a token, sends again (not a retry); a second 401 goes to the caller.
  `Anonymous` requests (login, refresh) carry no token and renew nothing. The single-flight
  refresh is the credentials' own ("M6: the session").
- Execute keeps no state between calls: several threads may call it.
- Tests: 16 (`Agenda.HttpClientTests`, on the fake transport), 140 in all, 0 failures, 0 leaks
  on FPC Windows and Linux; on Delphi 12 Win32 and Win64 with the session's (149 of 149, no
  leak, the user).

### M6: the session (2026-10-29, decision 6)

- `src/Agenda.HttpSession`, `TApiSession`, the `IApiCredentials` of a logged-in client: the
  access token, the refresh token in memory only, the moment to renew. The refresh call is the
  application's (`IApiTokenRefresher`: the route and its body), so the unit knows no route.
- One refresh at a time: `Renew(staleToken)` refreshes under a lock; a thread refused
  meanwhile waits on it and, finding a token other than its stale one, uses it without a
  refresh of its own. The server's reuse detection (two refreshes with one token revoke the
  family) never sees the client race itself.
- Renewed early: `AccessToken` refreshes when less than 60 s are left, or a quarter of the
  token's life when that is shorter (a test api with `ACCESS_TOKEN_SECONDS=8` renews at 6 s,
  not on every call). Early, a lost connection, a 429 or a 5xx keeps the old token, which is
  still good; after a 401 they reach the caller, as the request's own failure would.
- A refresh refused with 401 ends the session: the tokens forgotten, `Lost` true, `Renew`
  false, so the request's 401 reaches the screen, which logs in again.
- A monotonic millisecond clock (`GetTickCount64`), replaced by the tests: a wall clock set
  back doesn't keep a dead token.
- Tests: 9 (`Agenda.HttpSessionTests`: the margin on a moved clock, four threads refused at
  once making one refresh, the session ending, the old token kept, the session under
  `TApiHttpClient`), 149 in all, 0 failures, 0 leaks on FPC Windows and Linux (also on one
  CPU), and on Delphi 12 Win32 and Win64 (149 of 149, no leak, the user).

### M6: the agenda's client and its check against the api (2026-10-29, decisions 1, 2, 5, 7, 8)

- `src/Agenda.Client`, `TAgendaClient`: one method per route the staff's screens use (login,
  logout, me; the day, the free slots, book, read, move, status, cancel; customers: find, read,
  create, change; the active services and professionals for a booking), taking and returning
  the server's DTO interfaces. Over `TApiHttpClient` and `TApiSession` (its refresher: POST
  `/auth/refresh`, anonymous, never retried, a second refresh with a spent token being what the
  reuse detection revokes). A booking takes the user action's `Idempotency-Key`; a move, a
  status and a cancel send the version read as `If-Match` (the ETag is the version in quotes,
  so the day's rows are enough, no read first). Lists through `ReadApiPage` (the page's
  numbers, its `items` to the mapper) and `ApiQuery`.
- Decision 2 as built: `TApiSchema.Check` before a customer's create and change and before a
  booking and a status. Only the customer's name has a limit described (`MaxLength`); the
  booking and the appointment's PATCH describe none, so the check passes everything there and
  the server's 400 is what the screen shows. An `Enum` on the PATCH's status would refuse
  `cancelled` before the server's own `use_cancel` answer (a scenario checks it), so it wasn't
  added.
- `client/check/AgendaClientCheck` (`.dpr`, `.lpi`, `.dproj`; in `Agenda.groupproj`): the
  client against the real api, 29 checks. The owner (through `Http.Execute`) creates a service
  and a professional working every day; the staff: who they are, a customer named "João
  Cliente ..." found by `joao cliente`, its email set and cleared (the PATCH's three states), a
  101-character name refused with no request, the free slots three days on, one key sent twice
  (one appointment), another key on the slot (409 `slot_unavailable`), the day with the version
  and the names, a move, the old version's 412, the status, the cancel and a second one (409
  `appointment_closed`), the logout. Then the tokens, on an api started with
  `ACCESS_TOKEN_SECONDS=8`: renewed at 6 s with no 401 (counted by a transport around the real
  one); two calls on two threads at once on a spent token, one refresh for both; another
  refresh accepted after them (the family alive); the refresh token refused after the logout.
- `tools/test_http.sh` and `tools/test_http_docker.sh` run it on a third start of the api
  (`ACCESS_TOKEN_SECONDS=8`, an `/auth/` window of its own); `CLIENT_CHECK_EXE` for a Delphi
  build. Its project links no pascal-db-faa, Redis or Horse (FPC: none of their units in its
  output; Linux: built with only the four libraries' paths).
- Found: `TApiResponse` was also a type of `PascalApi.OpenApi`, which every DTO unit's user
  sees: the client's records are `TApiCall` and `TApiReply`.
- Found: a DTO class instance given straight to a `const` interface parameter gets no
  reference on FPC; when the call raised (the local check), it leaked (2 blocks, the unit
  tests' heaptrc). The client holds every DTO it builds through its interface first; the
  check program does the same.
- Known limit: a refresh whose answer is lost on the way (the server rotated, the client never
  heard) leaves the client with the spent token; its next refresh is refused as a reuse and the
  family revoked, so the user logs in again. Not retrying the refresh is what keeps it to that.
- Tests: 14 for the client (`Agenda.ClientTests`) and 3 more in `Agenda.HttpClientTests` (the
  query, the page), 163 in all, 0 failures, 0 leaks on FPC Windows and Linux. HTTP, FPC Windows:
  SQLite 669 + 74 + client 29, PostgreSQL with Redis and RabbitMQ 680 + 74 + 29; FPC Linux
  (Docker, SQLite) the scenarios, the worker's 79 and the client's 29 with 0 unfreed blocks.
  Delphi 12 Win32 Debug (the user, `CLIENT_CHECK_EXE`): HTTP 669 + 68 (the worker's usual
  Delphi count) + client 29, no leak report. Delphi: the unit tests and Win64 still to run.

### M6: the view models (2026-10-29, decisions 3 and 8)

- No screen yet: the logic first, in view models a form will read and feed (pascal-snake's
  rule), tested without LCL or VCL on the four targets.
- `src/Agenda.Desktop.Tasks`: `TUiTask` (`Run` on a pool thread, its results in the task's
  fields; `Done` on the UI thread, to the view model; an exception in `Run` goes to `Fail`, and
  `Done` still runs). `TPoolTaskRunner` on `PcPool` with `TThread.Queue`, `WaitIdle` pumping
  `CheckSynchronize` (for `OnCloseQuery`: the forms are freed before any unit's finalization);
  `TManualTaskRunner` for the tests (each task run when the test says, so the busy state is
  seen in between). `Forget(owner)` in a view model's destructor skips its tasks' `Done`.
- `src/Agenda.Desktop.Errors`: the exception as a `TUiError` record for `Done` (the exception
  is gone by then): `ekInvalid` with the fields (local check or a 400), `ekSession` (401),
  `ekConflict` (409, 412), `ekRefused`, `ekServer`, `ekOffline`, `ekOther`; the server's
  message as the text when it sent one.
- `src/Agenda.Desktop.Models` (the common part: busy, error, notice, `OnChange`,
  `OnSessionLost`), and three view models:
  - `Agenda.Desktop.Login`: server (an address without a scheme gets `http://`), company,
    email, password; `Submit` makes the `TAgendaClient` and logs in on the pool; on success the
    password is forgotten and `TakeClient` hands the client to the program. A 401 here is
    "Wrong company, email or password.", not a lost session.
  - `Agenda.Desktop.Day`: the day by date and professional; reads after each change, on
    `Reload` (F5) and `Tick` (60 s, skipped while a call runs); an older read answering late is
    dropped (a sequence number); the selection follows the id; confirm, done, no-show, cancel
    with the version shown as `If-Match`, allowed as the server's rules (done and no-show once
    started, on an injectable UTC clock); a 409 or 412 becomes a notice and the day is read
    again.
  - `Agenda.Desktop.Booking`: services and professionals, the free slots of the chosen day
    (read again on each choice, late answers dropped), a customer search, `Book`. The
    `Idempotency-Key` belongs to one choice (service, professional, slot, customer): pressed
    again after no answer, the same key (the server replays); a new choice, a new key. A 409
    `slot_unavailable` is a notice, the slots read again, the slot cleared.
- The UI's texts are English, as the rest of the project (the OPCB probe's Portuguese captions
  were the probe's).
- Tests: 14 (`Agenda.DesktopTests`: the manual runner, the pool runner for real with `Done` on
  the main thread and a forgotten task, the error kinds, the three view models on the fake
  transport), 177 in all, 0 failures, 0 leaks on FPC Windows and Linux (also on one CPU).
- Found on Delphi (the user's run, 176 of 177): `Agenda.ClientTests` expected "João" and got
  "JoÃ£o". A script of this session had written the accent into a file without a BOM:
  FPC reads such a source as UTF-8, Delphi in the ANSI code page. Rule (the user, 2026-10-29):
  accented text is written as it reads, never as escapes (hard to maintain), in a source
  saved as UTF-8 with a BOM, which both compilers read as UTF-8. The tests and
  `AgendaClientCheck` now do so, and `tools/test_fpc.sh` fails on non-ASCII text in the
  project's `.pas`/`.dpr` without a BOM, so FPC catches what only Delphi showed.
- Delphi 12 Win32 and Win64 (the user): 177 of 177, no leak.
