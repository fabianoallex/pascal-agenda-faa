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
| IANA time zones on both compilers | pascal-common-faa | **biggest risk**: neither RTL converts an arbitrary zone. Linux has `/usr/share/zoneinfo`; Windows has the registry (Windows names) or an embedded database. Own design phase before M2 |

**Probable** (a second case should confirm the shape):

- Transactional outbox + relay to AMQP: needs pascal-db-faa and pascal-amqp-faa together, so a
  bridge (`src/amqp` in pascal-api-infra-faa, or a bridge in pascal-amqp-faa).
- Scheduler with a lease (Redis `SetNx` or a database row): the core in pascal-common-faa.
- RFC 9457 errors (`application/problem+json`) as an option of `TErrorHandlerMiddleware`.
- Typed HTTP client for Delphi/Lazarus with refresh, retry and trace propagation (M6).

**Found while building** (not in the first list):

- A shared test kit: the DUnitX-to-FPCUnit adapter and the mirror generator, copied in every
  repository of the family (see "Progress", M1).

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

**Shared test kit**: the DUnitX-to-FPCUnit adapter (`*.DUnitXCompat.pas`) and
`gen_fpc_mirror.py` exist as near-identical copies in pascal-common-faa, -jsonmapper-faa,
-db-faa, -redis-faa, -api-infra-faa and three other projects; this is the eighth. A
candidate for one shared copy (a `testing/` folder in pascal-common-faa, or the skill).
