# pascal-agenda-faa

Online scheduling API for clinics and salons (multi-tenant), in Object Pascal, building on
both Delphi and Lazarus/FPC. It is built only on the `*-faa` libraries
(pascal-api-infra-faa, pascal-db-faa, pascal-jsonmapper-faa, pascal-common-faa; later
pascal-redis-faa and pascal-amqp-faa), to validate them in a real application and to find
what they lack.

Status: M0 to M2 done (tenants, login and refresh tokens, the catalog and people, working
hours and free slots, booking with a slot lock, If-Match and Idempotency-Key); M3 (public
routes by slug, rate limit by address, signed links) built; M4 in progress: the outbox, and
the worker (`worker/AgendaWorker`) that sends the customer's email and the reminders. Scope,
milestones and library candidates: [`docs/design.md`](docs/design.md).

## Getting the code

```
git clone <this repository>
git submodule update --init      # no --recursive: the libraries' own external/ isn't needed
```

The libraries are pinned in `external/`, one copy each: pascal-common-faa 1.24.0,
pascal-jsonmapper-faa 0.7.0, pascal-db-faa 0.17.0, pascal-api-infra-faa 0.24.0,
pascal-redis-faa 0.3.1, pascal-amqp-faa 0.4.1, Horse 3.3.12, Synapse (SMTP, a commit).

## Building and testing

| Where | How |
|---|---|
| FPC on Windows | `sh tools/test_fpc.sh`: the unit tests. `sh tools/test_http.sh`: lazbuild `api/AgendaApi.lpi` and `worker/AgendaWorker.lpi`, start, `tools/http_scenarios.sh`, then the worker's (`tools/http_scenarios_worker.sh`). Needs sqlite.org's `sqlite3.dll` in `.deps/` (or `SQLITE_DLL`). `DB_ENGINE=postgresql sh tools/test_http.sh`: the same on a throwaway `postgres:17` container (Docker) and a local 64-bit `libpq.dll` |
| FPC on Linux (Docker) | `sh tools/ci-test.sh`: what CI runs; plain `fpc`, then the scenarios on SQLite and on PostgreSQL 17, the OpenAPI validator and promtool |
| Delphi 12 | open `Agenda.groupproj`, build the tests, the api and the worker, Win32 and Win64; `AGENDA_EXE=api/Win32/Debug/AgendaApi.exe WORKER_EXE=worker/Win32/Debug/AgendaWorker.exe sh tools/test_http.sh` (and Win64); PostgreSQL on Win64 only (no 32-bit libpq): `DB_ENGINE=postgresql AGENDA_EXE=api/Win64/Debug/AgendaApi.exe sh tools/test_http.sh` |

Settings: environment or `.env` next to the executable (`.env.example`).
