#!/bin/sh
# Builds the API with plain fpc on Linux (Docker, FPC_IMAGE), starts it on a
# fresh database and runs tools/http_scenarios.sh; validates the OpenAPI
# document (openapi-spec-validator) and /metrics (promtool, through
# pascal-api-infra-faa's tools/promtool_check.sh); starts it again
# to check that a second start applies no migration.
#
# Plain fpc, not lazbuild: every path is given by hand (-Fu/-Fi), the same
# copies the .lpi names. The image needs FPC 3.2.2, curl, libsqlite3-0,
# openapi-spec-validator and promtool; tools/ci-test.sh builds one.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-agenda-fpc322}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for D in pascal-common-faa pascal-jsonmapper-faa pascal-db-faa pascal-api-infra-faa horse; do
  [ -d "external/$D/src" ] || { echo "external/$D is empty: git submodule update --init"; exit 1; }
done

MSYS_NO_PATHCONV=1 docker run --rm -v "$MOUNT:/src:ro" "$IMAGE" sh -c '
  set -e
  mkdir -p /t/units && cp -r /src/src /src/api /src/tools /src/external /t/
  E=/t/external
  P="-Fu/t/src -Fi/t/src"
  P="$P -Fu$E/pascal-api-infra-faa/src -Fi$E/pascal-api-infra-faa/src -Fu$E/pascal-api-infra-faa/src/horse"
  P="$P -Fu$E/horse/src -Fi$E/horse/src"
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src"
  P="$P -Fu$E/pascal-db-faa/adapters/sqldb -Fi$E/pascal-db-faa/adapters/sqldb"
  cd /t/api
  fpc -v0 -Mdelphi -dUseCThreads $P -FU/t/units -o/t/AgendaApi AgendaApi.dpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  mkdir -p /t/run && cd /t/run
  start() {
    /t/AgendaApi 9400 "$@" > /t/server.log 2>&1 &
    PID=$!
    for I in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -o /dev/null http://127.0.0.1:9400/health/live && return 0; sleep 1
    done
    echo "the API did not start"; cat /t/server.log; exit 1
  }
  stop() { kill $PID; wait $PID 2>/dev/null || true; }

  echo "== fresh database"
  start --reset
  RC=0
  OPENAPI_OUT=/t/openapi.json METRICS_OUT=/t/metrics.txt sh /t/tools/http_scenarios.sh 9400 || RC=$?
  stop
  [ $RC -eq 0 ] || { echo "--- server.log"; tail -20 /t/server.log; exit $RC; }
  grep -q "migration 2 MIG.0002" /t/server.log || { echo "FAIL: migrations not applied"; exit 1; }
  python3 -m openapi_spec_validator /t/openapi.json
  # pascal-api-infra-faa'"'"'s check: promtool, accepting only the "_count" lint
  # of pascal-db-faa'"'"'s db_client_connection_count (its OpenTelemetry name).
  sh $E/pascal-api-infra-faa/tools/promtool_check.sh /t/metrics.txt

  echo "== second start on the same database"
  start
  stop
  if grep -q "^migration " /t/server.log; then
    echo "FAIL: a second start applied migrations again"; cat /t/server.log; exit 1
  fi
  grep -q "at version 2" /t/server.log || { echo "FAIL: not at version 2"; cat /t/server.log; exit 1; }
  echo "ok: no migration on the second start, version 2"
'
