#!/bin/sh
# The api under load with k6 (docs/design.md, M5 decision 7): load/agenda.js
# in the grafana/k6 image, against one build, PASSES times, each pass checked
# by tools/load_check.py (no 5xx, no double booking, the api's /metrics
# agreeing with k6's counts), and the memory compared between the passes.
#
#   sh tools/load_test.sh <target> [db]
#
# Targets (db: postgresql, the default, or sqlite):
#   fpc-linux     the agenda-app image (docker/Dockerfile: fpc -O2), in a
#                 container; build it first (docker compose build api)
#   fpc-win       lazbuild --bm=Release api/AgendaApi.lpi (-O2, no heaptrc)
#   delphi-win64  api/Win64/Release/AgendaApi.exe (built in the IDE)
#   delphi-win32  api/Win32/Release/AgendaApi.exe, SQLite only (no 32-bit libpq)
#   compose       the running docker-compose.yml stack (its api on
#                 AGENDA_PORT, 9400): recreates the api container with the
#                 rate limits raised, seeds the "load" tenant once; the
#                 dashboards show the run. Nothing is stopped afterwards.
#
# The other targets get a fresh PostgreSQL 17 (port 55450) and Redis (56450)
# in containers, removed at the end, or a fresh SQLite file; the api on
# LOAD_PORT (9500) with RATE_LIMIT and PUBLIC_RATE_LIMIT out of the way. k6
# runs next to the api (see "the passes"): in a container for the container
# targets, a k6 installed on Windows (K6_EXE) for the Windows ones.
#
# Settings: DURATION (60s), VUS (20), PASSES (2), LOAD_POOL (40), K6_IMAGE. Results in
# load/out/<target>-<db>-*: k6's summaries and logs, /metrics before and
# after each pass. Exit code 0 only if every check passed.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TARGET="${1:?target: fpc-linux, fpc-win, delphi-win64, delphi-win32 or compose}"
DB="${2:-postgresql}"
[ "$TARGET" = delphi-win32 ] && DB=sqlite
[ "$TARGET" = compose ] && DB=postgresql
DURATION="${DURATION:-60s}"
VUS="${VUS:-20}"
PASSES="${PASSES:-2}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.54.0}"
PORT="${LOAD_PORT:-9500}"
PASSWORD="correct horse battery staple"
OUT="$ROOT/load/out"
TAG="$TARGET-$DB"
NET=agenda-load
PG=agenda-load-pg
REDIS=agenda-load-redis
API_CONTAINER=agenda-load-api
PY=python3
"$PY" -c "import sys" >/dev/null 2>&1 || PY=python
mkdir -p "$OUT"
rm -f "$OUT/$TAG"-*
# The k6 image runs as its own user (uid 12345): on Linux it can't write its
# summary into $OUT, made by this user with mode 755 (CI, 2026-10-31). Run
# it as this user there. Docker Desktop on Windows doesn't check the mount.
K6_USER=""
command -v cygpath >/dev/null 2>&1 || K6_USER="--user $(id -u):$(id -g)"

export DEV_MODE=true PASSWORD_ITERATIONS=20000 AUTH_RATE_LIMIT=1000
export RATE_LIMIT=1000000 PUBLIC_RATE_LIMIT=1000000
# The database pool (10 by default): with 10 and this load, requests waited
# out its 5 s and answered 503 (bookings hold a connection while they wait
# for the professional's row lock). LOAD_POOL=10 measures the default.
export DB_POOL_MAX="${LOAD_POOL:-40}"

cleanup() {
  if [ "$TARGET" != compose ]; then
    stop_api >/dev/null 2>&1 || true
    docker rm -f "$PG" "$REDIS" "$API_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- the build
case "$TARGET" in
  fpc-win)
    LAZBUILD="${LAZBUILD:-lazbuild}"
    command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe
    (cd api && "$LAZBUILD" -B --bm=Release AgendaApi.lpi > build-release.log 2>&1) \
      || { grep -E "Error|Fatal" api/build-release.log | head -20; exit 1; }
    EXE="$ROOT/api/release/AgendaApi.exe"
    cp "${SQLITE_DLL:-.deps/sqlite3.dll}" api/release/sqlite3.dll ;;
  delphi-win64) EXE="$ROOT/api/Win64/Release/AgendaApi.exe" ;;
  delphi-win32) EXE="$ROOT/api/Win32/Release/AgendaApi.exe" ;;
  fpc-linux)
    docker image inspect agenda-app >/dev/null 2>&1 \
      || { echo "no agenda-app image: docker compose build api"; exit 1; } ;;
  compose) ;;
  *) echo "unknown target $TARGET"; exit 1 ;;
esac
if [ -n "$EXE" ]; then
  [ -f "$EXE" ] || { echo "no $EXE: build it first"; exit 1; }
fi

# --- the database and the api
api_cmd() {
  if [ "$TARGET" = fpc-linux ]; then
    api_env_file
    MSYS_NO_PATHCONV=1 docker run --rm --network "$NET" --env-file "$(cygpath -w "$OUT/$TAG.env" 2>/dev/null || echo "$OUT/$TAG.env")" agenda-app \
      /app/AgendaApi "$@"
  else
    (cd "$(dirname "$EXE")" && "$EXE" "$@")
  fi
}
# The api's settings for a container, as an --env-file (a value may have
# spaces: the password).
api_env_file() {
  : > "$OUT/$TAG.env"
  for V in DEV_MODE PASSWORD_ITERATIONS AUTH_RATE_LIMIT RATE_LIMIT PUBLIC_RATE_LIMIT \
    DB_ENGINE DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD DB_POOL_MAX REDIS_HOST REDIS_PORT \
    AGENDA_PASSWORD; do
    eval "VAL=\${$V-}"
    if [ -n "$VAL" ]; then printf '%s=%s\n' "$V" "$VAL" >> "$OUT/$TAG.env"; fi
  done
}
EXE_WIN=""
start_api() {
  if [ "$TARGET" = fpc-linux ]; then
    api_env_file
    MSYS_NO_PATHCONV=1 docker run -d --name "$API_CONTAINER" --network "$NET" -p "$PORT:9400" \
      --env-file "$(cygpath -w "$OUT/$TAG.env" 2>/dev/null || echo "$OUT/$TAG.env")" agenda-app /app/AgendaApi 9400 >/dev/null
  else
    EXE_WIN="$(cygpath -w "$EXE")"
    (cd "$(dirname "$EXE")" && "$EXE" "$PORT" > "$OUT/$TAG-server.log" 2>&1 &)
  fi
  for I in $(seq 1 30); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/health/ready" && return 0; sleep 1
  done
  echo "the api did not start"; exit 1
}
stop_api() {
  if [ "$TARGET" = fpc-linux ]; then
    docker stop -t 15 "$API_CONTAINER" >/dev/null
    docker logs "$API_CONTAINER" > "$OUT/$TAG-server.log" 2>&1
    grep -q "agenda-api stopped" "$OUT/$TAG-server.log" \
      || { echo "FAIL: the api did not stop cleanly on SIGTERM"; return 1; }
    echo "ok: the api stopped cleanly on SIGTERM"
  elif [ -n "$EXE_WIN" ]; then
    powershell -NoProfile -Command "Get-Process AgendaApi -ErrorAction SilentlyContinue | Where-Object { \$_.Path -eq '$EXE_WIN' } | Stop-Process -Force" >/dev/null 2>&1 || true
  fi
}
memory_mb() {
  if [ "$TARGET" = fpc-linux ] || [ "$TARGET" = compose ]; then
    C="$API_CONTAINER"
    [ "$TARGET" = compose ] && C=agenda-api-1
    docker stats --no-stream --format '{{.MemUsage}}' "$C" | "$PY" -c "
import re, sys
v, u = re.match(r'([0-9.]+)\s*([KMG]i?B)', sys.stdin.read()).groups()
print(round(float(v) * {'KiB': 1/1024, 'MiB': 1, 'GiB': 1024, 'kB': 1/1000, 'MB': 1, 'GB': 1000}[u], 1))"
  else
    powershell -NoProfile -Command "\$p = Get-Process AgendaApi | Where-Object { \$_.Path -eq '$EXE_WIN' } | Select-Object -First 1; [math]::Round(\$p.WorkingSet64 / 1MB, 1)" | tr -d '\r'
  fi
}

if [ "$TARGET" = compose ]; then
  PORT="${AGENDA_PORT:-9400}"
  echo "== compose: the api again, with the rate limits raised"
  RATE_LIMIT=1000000 PUBLIC_RATE_LIMIT=1000000 AUTH_RATE_LIMIT=1000 \
    docker compose up -d --no-deps --wait api >/dev/null
  # The load tenant once; again, it is already there (the command says so).
  sh tools/compose_api.sh --create-tenant load "Load Test" America/Sao_Paulo >/dev/null 2>&1 || true
  AGENDA_PASSWORD="$PASSWORD" sh tools/compose_api.sh --create-user load owner@load.test owner >/dev/null 2>&1 || true
  AGENDA_PASSWORD="$PASSWORD" sh tools/compose_api.sh --create-user load staff@load.test staff >/dev/null 2>&1 || true
else
  echo "== $TARGET on $DB"
  docker rm -f "$PG" "$REDIS" "$API_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker network create "$NET" >/dev/null
  docker run -d --name "$REDIS" --network "$NET" -p 56450:6379 redis:7.2-alpine >/dev/null
  if [ "$DB" = postgresql ]; then
    docker run -d --name "$PG" --network "$NET" -p 55450:5432 -e POSTGRES_PASSWORD=postgres \
      -e POSTGRES_DB=agenda_load postgres:17 >/dev/null
    for I in $(seq 1 60); do
      docker exec "$PG" pg_isready -q -h 127.0.0.1 -U postgres -d agenda_load && break; sleep 1
    done
    export DB_ENGINE=postgresql DB_NAME=agenda_load DB_USER=postgres DB_PASSWORD=postgres
    if [ "$TARGET" = fpc-linux ]; then
      export DB_HOST="$PG" DB_PORT=5432 REDIS_HOST="$REDIS" REDIS_PORT=6379
    else
      export DB_HOST=127.0.0.1 DB_PORT=55450 REDIS_HOST=127.0.0.1 REDIS_PORT=56450
      if [ -z "$PG_CLIENT" ]; then
        PG_CLIENT="$(ls -d "/c/Program Files/PostgreSQL/"*/bin/libpq.dll 2>/dev/null | sort -V | tail -1)"
        [ -n "$PG_CLIENT" ] || { echo "no libpq.dll: set PG_CLIENT"; exit 1; }
        export PG_CLIENT="$(cygpath -w "$PG_CLIENT")"
      fi
    fi
  else
    export DB_ENGINE=sqlite DB_FILE="$(dirname "${EXE:-$ROOT/api/x}")/agenda-load.sqlite"
    rm -f "$DB_FILE"
    export REDIS_HOST=127.0.0.1 REDIS_PORT=56450
  fi
  api_cmd --create-tenant load "Load Test" America/Sao_Paulo >/dev/null
  AGENDA_PASSWORD="$PASSWORD" api_cmd --create-user load owner@load.test owner >/dev/null
  AGENDA_PASSWORD="$PASSWORD" api_cmd --create-user load staff@load.test staff >/dev/null
  start_api
fi

# --- the passes
# k6 next to the api, never through Docker Desktop's port forwarding: with a
# connection per request (FPC 3.2.2's server closes each one), the forwarder
# dropped dials ("dial: i/o timeout", measured on both the Windows and the
# Linux api, none with k6 on the api's own network). A container target: k6
# in a container on its network; a Windows target: a k6 on Windows (K6_EXE,
# or k6 on the PATH) against 127.0.0.1.
K6_DOCKER=1
case "$TARGET" in
  fpc-linux) K6_NETWORK="$NET"; K6_BASE="http://$API_CONTAINER:9400" ;;
  compose) K6_NETWORK=agenda_default; K6_BASE="http://api:9400" ;;
  *)
    K6_DOCKER=0
    K6_EXE="${K6_EXE:-$(command -v k6 2>/dev/null || true)}"
    # Where its installer (winget install k6) puts it, before a new shell has it on PATH.
    [ -n "$K6_EXE" ] || { [ -x "/c/Program Files/k6/k6.exe" ] && K6_EXE="/c/Program Files/k6/k6.exe"; }
    [ -n "$K6_EXE" ] || { echo "no k6 on Windows: install it (k6.io) or set K6_EXE"; exit 1; }
    K6_BASE="http://127.0.0.1:$PORT" ;;
esac
RC=0
MEMS=""
P=1
while [ $P -le "$PASSES" ]; do
  echo "== pass $P ($DURATION, $VUS virtual users)"
  curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$TAG-p$P-before.txt"
  K6RC=0
  RUN_TAG="$TAG-$P-$(date +%s)"
  if [ $K6_DOCKER = 1 ]; then
    MSYS_NO_PATHCONV=1 docker run --rm --network "$K6_NETWORK" $K6_USER \
      -v "$(cygpath -w "$ROOT/load" 2>/dev/null || echo "$ROOT/load"):/load" \
      -e BASE="$K6_BASE" -e DURATION="$DURATION" -e VUS="$VUS" -e RUN="$RUN_TAG" \
      "$K6_IMAGE" run --quiet --summary-export "/load/out/$TAG-p$P.json" /load/agenda.js \
      > "$OUT/$TAG-p$P.log" 2>&1 || K6RC=$?
  else
    BASE="$K6_BASE" DURATION="$DURATION" VUS="$VUS" RUN="$RUN_TAG" "$K6_EXE" run --quiet \
      --summary-export "$OUT/$TAG-p$P.json" load/agenda.js > "$OUT/$TAG-p$P.log" 2>&1 || K6RC=$?
  fi
  curl -s "http://127.0.0.1:$PORT/metrics" > "$OUT/$TAG-p$P-after.txt"
  [ -f "$OUT/$TAG-p$P.json" ] || { echo "no k6 summary (exit $K6RC); its log:"; tail -20 "$OUT/$TAG-p$P.log"; }
  MEM="$(memory_mb)"
  MEMS="$MEMS $MEM"
  "$PY" tools/load_check.py pass "$TAG" "$P" "$OUT/$TAG-p$P.json" "$OUT/$TAG-p$P-before.txt" \
    "$OUT/$TAG-p$P-after.txt" "$MEM" "$K6RC" || RC=1
  P=$((P + 1))
done
"$PY" tools/load_check.py memory "$TAG" $MEMS || RC=1
if [ "$TARGET" != compose ]; then
  stop_api || RC=1
fi
[ $RC -eq 0 ] && echo "ok: $TAG under load"
exit $RC
