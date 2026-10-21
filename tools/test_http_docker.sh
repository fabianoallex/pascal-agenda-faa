#!/bin/sh
# Builds the API with plain fpc on Linux (Docker, FPC_IMAGE), creates a fresh
# database with tools/seed_scenarios.sh, starts the API and runs
# tools/http_scenarios.sh; validates the OpenAPI document
# (openapi-spec-validator) and /metrics (promtool, through
# pascal-api-infra-faa's tools/promtool_check.sh); starts it again: no
# migration may run, and a token issued before the restart must verify.
#
# Plain fpc, not lazbuild: every path is given by hand (-Fu/-Fi), the same
# copies the .lpi names. The image needs FPC 3.2.2, curl, libsqlite3-0,
# libpq5, python3, openapi-spec-validator and promtool; tools/ci-test.sh
# builds one.
#
# DB_ENGINE=postgresql runs the same steps on PostgreSQL: a postgres:17
# container (PG_IMAGE) on a private network, removed at the end, and a
# redis:7.2-alpine container there for the slot lock (tools/redis_cmd.py
# talks to it; the image has no redis-cli).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${FPC_IMAGE:-agenda-fpc322}"
MOUNT="$ROOT"
command -v cygpath >/dev/null 2>&1 && MOUNT="$(cygpath -w "$ROOT")"

cd "$ROOT"
for D in pascal-common-faa pascal-jsonmapper-faa pascal-db-faa pascal-api-infra-faa pascal-redis-faa horse; do
  [ -d "external/$D/src" ] || { echo "external/$D is empty: git submodule update --init"; exit 1; }
done

ENGINE="${DB_ENGINE:-sqlite}"
NET=agenda-it-net
PG=agenda-it-pg
REDIS=agenda-it-redis
NETOPT=""
REDIS_HOST=""
REDIS_CMD=""
if [ "$ENGINE" = postgresql ]; then
  cleanup() {
    docker rm -f "$PG" "$REDIS" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  cleanup
  docker network create "$NET" >/dev/null
  docker run -d --name "$REDIS" --network "$NET" redis:7.2-alpine >/dev/null
  REDIS_HOST="$REDIS"
  REDIS_CMD="python3 /t/tools/redis_cmd.py $REDIS 6379"
  docker run -d --name "$PG" --network "$NET" -e POSTGRES_PASSWORD=postgres \
    -e POSTGRES_DB=agenda_scenarios "${PG_IMAGE:-postgres:17}" >/dev/null
  # Over TCP: during its first start the image's server listens on the
  # socket only, and restarts once the database is created.
  READY=""
  for I in $(seq 1 60); do
    docker exec "$PG" pg_isready -q -h 127.0.0.1 -U postgres -d agenda_scenarios && { READY=1; break; }
    sleep 1
  done
  [ -n "$READY" ] || { echo "PostgreSQL didn't start"; docker logs "$PG" | tail -20; exit 1; }
  NETOPT="--network $NET"
fi
echo "== engine: $ENGINE"

# $NETOPT is unquoted on purpose: empty, or "--network <name>".
MSYS_NO_PATHCONV=1 docker run --rm $NETOPT -v "$MOUNT:/src:ro" \
  -e DEV_MODE=true -e PASSWORD_ITERATIONS=20000 -e AUTH_RATE_LIMIT=60 -e PUBLIC_RATE_LIMIT=60 \
  -e DB_ENGINE="$ENGINE" -e DB_HOST="$PG" -e DB_NAME=agenda_scenarios \
  -e DB_USER=postgres -e DB_PASSWORD=postgres \
  -e REDIS_HOST="$REDIS_HOST" -e REDIS_CMD="$REDIS_CMD" \
  -e DB_FILE=/t/run/agenda.sqlite "$IMAGE" sh -c '
  set -e
  mkdir -p /t/units /t/run && cp -r /src/src /src/api /src/tools /src/external /t/
  E=/t/external
  P="-Fu/t/src -Fi/t/src"
  P="$P -Fu$E/pascal-api-infra-faa/src -Fi$E/pascal-api-infra-faa/src -Fu$E/pascal-api-infra-faa/src/horse"
  P="$P -Fu$E/horse/src -Fi$E/horse/src"
  P="$P -Fu$E/pascal-common-faa/src -Fi$E/pascal-common-faa/src -Fu$E/pascal-common-faa/bridges/jsonmapper"
  P="$P -Fu$E/pascal-jsonmapper-faa/src -Fi$E/pascal-jsonmapper-faa/src"
  P="$P -Fu$E/pascal-db-faa/src -Fi$E/pascal-db-faa/src"
  P="$P -Fu$E/pascal-db-faa/adapters/sqldb -Fi$E/pascal-db-faa/adapters/sqldb"
  P="$P -Fu$E/pascal-redis-faa/src -Fi$E/pascal-redis-faa/src"
  cd /t/api
  fpc -v0 -Mdelphi -dUseCThreads $P -FU/t/units -o/t/AgendaApi AgendaApi.dpr > /t/build.log 2>&1 \
    || { grep -iE "error|fatal" /t/build.log | head -30; exit 1; }
  cd /t/run
  start() {
    /t/AgendaApi 9400 > /t/server.log 2>&1 &
    PID=$!
    for I in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -o /dev/null http://127.0.0.1:9400/health/live && return 0; sleep 1
    done
    echo "the API did not start"; cat /t/server.log; exit 1
  }
  stop() { kill $PID; wait $PID 2>/dev/null || true; }

  echo "== fresh database"
  sh /t/tools/seed_scenarios.sh /t/AgendaApi
  start
  # A token for after the restart, before the scenarios fill the /auth/ window.
  TOKEN="$(curl -s -H "Content-Type: application/json" \
    --data-binary "{\"tenant\":\"other\",\"email\":\"owner@other.test\",\"password\":\"correct horse battery staple\"}" \
    http://127.0.0.1:9400/auth/login | sed -n "s/.*\"accessToken\":\"\([^\"]*\)\".*/\1/p")"
  RC=0
  OPENAPI_OUT=/t/openapi.json METRICS_OUT=/t/metrics.txt SERVER_LOG=/t/server.log \
    sh /t/tools/http_scenarios.sh 9400 || RC=$?
  stop
  [ $RC -eq 0 ] || { echo "--- server.log"; tail -20 /t/server.log; exit $RC; }
  [ -n "$TOKEN" ] || { echo "FAIL: no token before the restart"; exit 1; }
  VERSION="$(grep -o "at version [0-9]*" /t/server.log | head -1 | tr -cd "0-9")"
  [ -n "$VERSION" ] || { echo "FAIL: no schema version in the log"; exit 1; }
  python3 $E/pascal-api-infra-faa/tools/json_no_duplicate_keys.py /t/openapi.json
  python3 -m openapi_spec_validator /t/openapi.json
  # pascal-api-infra-faa'"'"'s check: promtool, accepting only the "_count" lint
  # of pascal-db-faa'"'"'s db_client_connection_count (its OpenTelemetry name).
  sh $E/pascal-api-infra-faa/tools/promtool_check.sh /t/metrics.txt

  echo "== second start on the same database"
  start
  STATUS="$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9400/me)"
  stop
  if grep -q "^migration " /t/server.log; then
    echo "FAIL: a second start applied migrations again"; cat /t/server.log; exit 1
  fi
  grep -q "at version $VERSION" /t/server.log || { echo "FAIL: not at version $VERSION"; cat /t/server.log; exit 1; }
  [ "$STATUS" = 200 ] || { echo "FAIL: a token from before the restart answered $STATUS"; exit 1; }
  echo "ok: no migration on the second start, version $VERSION; a token from before the restart verifies"
'
