#!/bin/sh
# Builds the API with lazbuild (FPC on Windows), creates a fresh database
# with tools/seed_scenarios.sh, starts the API and runs
# tools/http_scenarios.sh; then starts it again on the same database: no
# migration may run, and a token issued before the restart must still verify
# (the signing keys are kept, sealed, in the database).
#
# FPC on Windows loads sqlite3.dll, and it must be sqlite.org's build
# (pascal-db-faa gotcha 23). The script copies SQLITE_DLL, or
# .deps/sqlite3.dll (git-ignored), next to the executable.
#
# For a Delphi build: AGENDA_EXE=api/Win32/Debug/AgendaApi.exe and
# WORKER_EXE=worker/Win32/Debug/AgendaWorker.exe skip the build and run the
# same steps on those executables.
#
# The worker (M4): on the second start, tools/http_scenarios_worker.sh runs
# it with --drain on the same database (the api restarted, so the public
# rate limit's window is empty again).
#
# DB_ENGINE=postgresql runs them on PostgreSQL: a fresh postgres:17 container
# (PG_IMAGE) on port 55433 (PG_PORT), removed at the end, and the 64-bit
# libpq.dll of the newest install under C:\Program Files\PostgreSQL
# (PG_CLIENT to choose another). PostgreSQL has no 32-bit client: a Delphi
# build for it is Win64. That run also starts a redis:7.2-alpine container
# on port 56379 (REDIS_TEST_PORT) for the slot lock, so the SQLite run checks
# the booking without it and the PostgreSQL run with it (and with it down),
# and a rabbitmq:3 container on port 55672 (AMQP_TEST_PORT): the worker's
# scenarios run through the broker there and through the local sink on
# SQLite.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe
PORT="${PORT:-9400}"
# A Python with the official MCP SDK (pip install mcp==2.0.0), for
# tools/mcp_client_check.py; without it that check is skipped, and said so.
MCP_PYTHON="${MCP_PYTHON:-python}"
cd "$ROOT"

# The scenarios' settings: development master key, a lower PBKDF2 cost (the
# rate-limit check logs in dozens of times), the /auth/ and /public/ limits
# they expect.
export DEV_MODE=true PASSWORD_ITERATIONS=20000 AUTH_RATE_LIMIT=60 PUBLIC_RATE_LIMIT=60

if [ -z "$AGENDA_EXE" ]; then
  DLL="${SQLITE_DLL:-.deps/sqlite3.dll}"
  [ -f "$DLL" ] || { echo "no sqlite.org sqlite3.dll: set SQLITE_DLL or put one in .deps/sqlite3.dll"; exit 1; }
  # Never pipe lazbuild into head: it hangs when the pipe closes.
  if ! (cd api && "$LAZBUILD" -B AgendaApi.lpi > build.log 2>&1); then
    grep -E "Error|Fatal" api/build.log | head -30
    exit 1
  fi
  cp "$DLL" api/sqlite3.dll
  AGENDA_EXE=api/AgendaApi.exe
fi
if [ -z "$WORKER_EXE" ]; then
  if ! (cd worker && "$LAZBUILD" -B AgendaWorker.lpi > build.log 2>&1); then
    grep -E "Error|Fatal" worker/build.log | head -30
    exit 1
  fi
  cp "${SQLITE_DLL:-.deps/sqlite3.dll}" worker/sqlite3.dll
  WORKER_EXE=worker/AgendaWorker.exe
fi
EXE="$ROOT/$AGENDA_EXE"
DIR="$(dirname "$EXE")"
LOG="$DIR/server.log"
export DB_FILE="$DIR/agenda-scenarios.sqlite"

export PG_CONTAINER=agenda-test-pg
if [ "${DB_ENGINE:-sqlite}" = postgresql ]; then
  if [ -z "$PG_CLIENT" ]; then
    PG_CLIENT="$(ls -d "/c/Program Files/PostgreSQL/"*/bin/libpq.dll 2>/dev/null | sort -V | tail -1)"
    [ -n "$PG_CLIENT" ] || { echo "no libpq.dll under C:/Program Files/PostgreSQL: set PG_CLIENT"; exit 1; }
    PG_CLIENT="$(cygpath -w "$PG_CLIENT")"
  fi
  export DB_HOST=127.0.0.1 DB_PORT="${PG_PORT:-55433}" DB_NAME=agenda_scenarios
  export DB_USER=postgres DB_PASSWORD=postgres PG_CLIENT
  REDIS_CONTAINER=agenda-test-redis
  export REDIS_HOST=127.0.0.1 REDIS_PORT="${REDIS_TEST_PORT:-56379}"
  export REDIS_CMD="python tools/redis_cmd.py $REDIS_HOST $REDIS_PORT"
  RABBIT_CONTAINER=agenda-test-rabbit
  trap 'docker rm -f "$PG_CONTAINER" "$REDIS_CONTAINER" "$RABBIT_CONTAINER" >/dev/null 2>&1 || true' EXIT
  docker rm -f "$REDIS_CONTAINER" "$RABBIT_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$REDIS_CONTAINER" -p "$REDIS_PORT:6379" redis:7.2-alpine >/dev/null
  # Started now, waited for before the worker: it takes some seconds. Never
  # probe it with "docker exec rabbitmq-diagnostics" before it is up: run as
  # root, that creates the Erlang cookie the server then can't read.
  docker run -d --name "$RABBIT_CONTAINER" -p "${AMQP_TEST_PORT:-55672}:5672" rabbitmq:3 >/dev/null
  for I in $(seq 1 30); do
    docker exec "$REDIS_CONTAINER" redis-cli ping >/dev/null 2>&1 && break; sleep 1
  done
fi

# A fresh database: a new file, or a new PostgreSQL container. pg_isready
# over TCP: during its first start the image's server listens on the socket
# only, and restarts once the database is created.
fresh_database() {
  if [ "${DB_ENGINE:-sqlite}" = postgresql ]; then
    docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$PG_CONTAINER" -p "$DB_PORT:5432" -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB="$DB_NAME" "${PG_IMAGE:-postgres:17}" >/dev/null
    for I in $(seq 1 60); do
      docker exec "$PG_CONTAINER" pg_isready -q -h 127.0.0.1 -U postgres -d "$DB_NAME" && return 0
      sleep 1
    done
    echo "PostgreSQL didn't start"; docker logs "$PG_CONTAINER" | tail -20; exit 1
  else
    rm -f "$DB_FILE"
  fi
}

# Only the executable this script started, by its path: another build
# running elsewhere stays up. (taskkill by image name stopped one, 2026-10-18.)
EXE_WIN="$(cygpath -w "$EXE" 2>/dev/null || echo "$EXE")"
stop() {
  powershell -NoProfile -Command "Get-Process AgendaApi -ErrorAction SilentlyContinue | Where-Object { \$_.Path -eq '$EXE_WIN' } | Stop-Process -Force" >/dev/null 2>&1 ||
    pkill -f "$EXE" 2>/dev/null || true
  sleep 1
}
start() {
  (cd "$DIR" && "$EXE" "$PORT" > "$LOG" 2>&1 &)
  for I in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/health/live" && return 0; sleep 1
  done
  echo "the API didn't start"; cat "$LOG"; stop; exit 1
}

echo "== fresh database (${DB_ENGINE:-sqlite})"
fresh_database
sh tools/seed_scenarios.sh "$EXE"
start
# A token for after the restart, before the scenarios fill the /auth/ window.
TOKEN="$(curl -s -H 'Content-Type: application/json' \
  --data-binary '{"tenant":"other","email":"owner@other.test","password":"correct horse battery staple"}' \
  "http://127.0.0.1:$PORT/auth/login" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')"
# The MCP client's tokens (tools/mcp_client_check.py runs after the scenarios).
demo_token() {
  curl -s -H 'Content-Type: application/json' \
    --data-binary "{\"tenant\":\"demo\",\"email\":\"$1\",\"password\":\"correct horse battery staple\"}" \
    "http://127.0.0.1:$PORT/auth/login" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'
}
MCP_OWNER="$(demo_token owner@demo.test)"
MCP_STAFF="$(demo_token staff@demo.test)"
RC=0
SERVER_LOG="$LOG" sh tools/http_scenarios.sh "$PORT" || RC=$?
if [ $RC -eq 0 ]; then
  if "$MCP_PYTHON" -c "import mcp.client, httpx2" >/dev/null 2>&1; then
    "$MCP_PYTHON" tools/mcp_client_check.py "http://127.0.0.1:$PORT" "$MCP_OWNER" "$MCP_STAFF"       > "$ROOT/api/mcp_client.log" 2>&1 || RC=$?
    tail -1 "$ROOT/api/mcp_client.log"
    [ $RC -eq 0 ] || grep -v '^ok ' "$ROOT/api/mcp_client.log"
  else
    echo "skipped: the official MCP client (MCP_PYTHON=$MCP_PYTHON has no mcp 2.0.0)"
  fi
fi
stop
[ $RC -eq 0 ] || { echo "--- $LOG"; tail -20 "$LOG"; exit $RC; }
[ -n "$TOKEN" ] || { echo "FAIL: no token before the restart"; exit 1; }
VERSION="$(grep -o 'at version [0-9]*' "$LOG" | head -1 | tr -cd '0-9')"
[ -n "$VERSION" ] || { echo "FAIL: no schema version in the log"; exit 1; }

echo "== second start on the same database"
start
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/me")"
echo "== the worker"
# The appointments' scenarios end by shutting Redis down (the slot lock's
# fallback): up again for the worker's lease.
if [ -n "$REDIS_CONTAINER" ]; then
  docker start "$REDIS_CONTAINER" >/dev/null
  for I in $(seq 1 30); do
    docker exec "$REDIS_CONTAINER" redis-cli ping >/dev/null 2>&1 && break; sleep 1
  done
fi
if [ -n "$RABBIT_CONTAINER" ]; then
  for I in $(seq 1 90); do
    docker logs "$RABBIT_CONTAINER" 2>&1 | grep -q "Server startup complete" && break; sleep 1
  done
  export AMQP_HOST=127.0.0.1 AMQP_PORT="${AMQP_TEST_PORT:-55672}" AMQP_RETRY_MS=2000
fi
WRC=0
sh tools/http_scenarios_worker.sh "$PORT" "$ROOT/$WORKER_EXE" "$EXE" || WRC=$?
stop
[ $WRC -eq 0 ] || exit $WRC
if grep -q "^migration " "$LOG"; then
  echo "FAIL: a second start applied migrations again"; cat "$LOG"; exit 1
fi
grep -q "at version $VERSION" "$LOG" || { echo "FAIL: not at version $VERSION"; cat "$LOG"; exit 1; }
[ "$STATUS" = 200 ] || { echo "FAIL: a token from before the restart answered $STATUS"; exit 1; }
echo "ok: no migration on the second start, version $VERSION; a token from before the restart verifies"
