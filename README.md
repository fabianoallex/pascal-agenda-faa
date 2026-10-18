# pascal-agenda-faa

Online scheduling API for clinics and salons (multi-tenant), in Object Pascal, building on
both Delphi and Lazarus/FPC. It is built only on the `*-faa` libraries
(pascal-api-infra-faa, pascal-db-faa, pascal-jsonmapper-faa, pascal-common-faa; later
pascal-redis-faa and pascal-amqp-faa), to validate them in a real application and to find
what they lack.

Status: M0 (skeleton: health, metrics, OpenAPI, migrations). Scope, milestones and library
candidates: [`docs/design.md`](docs/design.md).

## Getting the code

```
git clone <this repository>
git submodule update --init      # no --recursive: the libraries' own external/ isn't needed
```

The libraries are pinned in `external/`, one copy each: pascal-common-faa 1.17.0,
pascal-jsonmapper-faa 0.6.0, pascal-db-faa 0.15.0, pascal-api-infra-faa 0.16.0, Horse 3.3.12.

## Building and testing

| Where | How |
|---|---|
| FPC on Windows | `sh tools/test_http.sh`: lazbuild `api/AgendaApi.lpi`, start, `tools/http_scenarios.sh`. Needs sqlite.org's `sqlite3.dll` in `.deps/` (or `SQLITE_DLL`) |
| FPC on Linux (Docker) | `sh tools/ci-test.sh`: what CI runs; plain `fpc`, then the scenarios, the OpenAPI validator and promtool |
| Delphi 12 | open `api/AgendaApi.dproj`, build Win32 and Win64; start `api\Win32\Debug\AgendaApi.exe 9400 --reset` and run `sh tools/http_scenarios.sh 9400` |

Settings: environment or `.env` next to the executable (`.env.example`).
