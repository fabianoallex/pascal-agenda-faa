# pascal-agenda-faa

Online scheduling API for clinics and salons (multi-tenant), in Object Pascal, building on
both Delphi and Lazarus/FPC. It is built only on the `*-faa` libraries
(pascal-api-infra-faa, pascal-db-faa, pascal-jsonmapper-faa, pascal-common-faa; later
pascal-redis-faa and pascal-amqp-faa), to validate them in a real application and to find
what they lack.

Status: M0 to M2 done (tenants, login and refresh tokens, the catalog and people, working
hours and free slots, booking with a slot lock, If-Match and Idempotency-Key); M3 (public
routes by slug, rate limit by address, signed links) and M4 (the outbox, the worker
`worker/AgendaWorker` that sends the customer's email and the reminders, through RabbitMQ or
without it, and `docker-compose.yml` with the whole stack) built; M5 (the api as MCP tools for
an AI agent, `POST /mcp`, one day of the agenda, the dashboards, the load test) and M6 (the
desktop client `client/desktop`, VCL and LCL from one source, on the server's DTOs) closed.
Next: M7, the review of the library candidates. Scope, milestones and library candidates:
[`docs/design.md`](docs/design.md).

## Getting the code

```
git clone <this repository>
git submodule update --init      # no --recursive: the libraries' own external/ isn't needed
```

The libraries are pinned in `external/`, one copy each: pascal-common-faa 1.25.0,
pascal-jsonmapper-faa 0.7.0, pascal-db-faa 0.17.0, pascal-api-infra-faa 0.29.0,
pascal-redis-faa 0.3.1, pascal-amqp-faa 0.4.2, Horse 3.3.12, Synapse (SMTP, a commit). The unit
suite also uses pascal-amqp-faa's embedded broker (`pascal_amqp_faa_server`).

## Building and testing

| Where | How |
|---|---|
| FPC on Windows | `sh tools/test_fpc.sh`: the unit tests. `sh tools/test_http.sh`: lazbuild `api/AgendaApi.lpi` and `worker/AgendaWorker.lpi`, start, `tools/http_scenarios.sh`, then the worker's (`tools/http_scenarios_worker.sh`); with `MCP_PYTHON` naming a Python that has `mcp==2.0.0`, also the official MCP client (`tools/mcp_client_check.py`; skipped, and said so, without it). Needs sqlite.org's `sqlite3.dll` in `.deps/` (or `SQLITE_DLL`). `DB_ENGINE=postgresql sh tools/test_http.sh`: the same on a throwaway `postgres:17` container (Docker) and a local 64-bit `libpq.dll` |
| FPC on Linux (Docker) | `sh tools/ci-test.sh`: what CI runs; plain `fpc`, then the scenarios on SQLite and on PostgreSQL 17 (the worker through RabbitMQ there), the official MCP client, the OpenAPI validator and promtool, `tools/test_compose.sh` (its own compose project, `agenda-test`: never the development stack) and a short load run |
| Delphi 12 | open `Agenda.groupproj`, build the tests, the api and the worker, Win32 and Win64; `AGENDA_EXE=api/Win32/Debug/AgendaApi.exe WORKER_EXE=worker/Win32/Debug/AgendaWorker.exe sh tools/test_http.sh` (and Win64); PostgreSQL on Win64 only (no 32-bit libpq): `DB_ENGINE=postgresql AGENDA_EXE=api/Win64/Debug/AgendaApi.exe sh tools/test_http.sh` |

Settings: environment or `.env` next to the executable (`.env.example`).

## Under load (k6)

`sh tools/load_test.sh <target>` runs `load/agenda.js` (reads, bookings, several clients on one
slot, the public routes) twice and checks each pass: no 5xx, no double booking, the api's
`/metrics` agreeing with k6's counts, the memory not growing. Targets: `fpc-linux` (the
`agenda-app` image), `fpc-win` (`lazbuild --bm=Release`), `delphi-win64` and `delphi-win32`
(the IDE's Release builds; Win32 on SQLite), each on a fresh PostgreSQL 17 and Redis; and
`compose`, the running stack, whose dashboards then show the run. k6 runs next to the api: in
Docker for the container targets, a k6 installed on Windows (`K6_EXE`) for the others.
Results in `load/out/`.

## The whole stack (Docker)

`docker compose up -d --build --wait` starts PostgreSQL, Redis, RabbitMQ, Mailpit, an
OpenTelemetry Collector, Prometheus, Grafana, the api (http://localhost:9400) and the worker,
built with FPC on Linux from `docker/Dockerfile` (on the CI image: `sh tools/ci-test.sh` builds
`agenda-fpc322`). The emails show in Mailpit (http://localhost:8025), the dashboards of the
api, the worker and the broker in Grafana (http://localhost:3000, folder Agenda; the JSON in
`docker/grafana/dashboards`). Create a tenant and its owner with the api's commands in the
container (the header of `docker-compose.yml`). `sh tools/test_compose.sh` checks it end to
end (the email, one trace from the request to the email, the dashboards' queries, a clean
stop).
