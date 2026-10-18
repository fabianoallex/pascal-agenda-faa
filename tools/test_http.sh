#!/bin/sh
# Builds the API with lazbuild (FPC on Windows), starts it on a fresh
# database and runs tools/http_scenarios.sh; then starts it again on the
# same database, to check that a second start applies no migration.
#
# FPC on Windows loads sqlite3.dll, and it must be sqlite.org's build
# (pascal-db-faa gotcha 23). The script copies SQLITE_DLL, or
# .deps/sqlite3.dll (git-ignored), next to the executable.
#
# For a Delphi build, skip this: start api\Win32\Debug\AgendaApi.exe (or
# Win64) with --reset and run sh tools/http_scenarios.sh 9400.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe
PORT="${PORT:-9400}"
cd "$ROOT"

DLL="${SQLITE_DLL:-.deps/sqlite3.dll}"
[ -f "$DLL" ] || { echo "no sqlite.org sqlite3.dll: set SQLITE_DLL or put one in .deps/sqlite3.dll"; exit 1; }

# Never pipe lazbuild into head: it hangs when the pipe closes.
if ! (cd api && "$LAZBUILD" -B AgendaApi.lpi > build.log 2>&1); then
  grep -E "Error|Fatal" api/build.log | head -30
  exit 1
fi
cp "$DLL" api/sqlite3.dll

# Only the executable this script built and started (api/AgendaApi.exe), by
# its path: a Delphi build running from api/Win32/Debug stays up. (taskkill
# by image name stopped one, 2026-10-18.)
EXE_WIN="$(cygpath -w "$ROOT/api/AgendaApi.exe" 2>/dev/null || echo "$ROOT/api/AgendaApi.exe")"
stop() {
  powershell -NoProfile -Command "Get-Process AgendaApi -ErrorAction SilentlyContinue | Where-Object { \$_.Path -eq '$EXE_WIN' } | Stop-Process -Force" >/dev/null 2>&1 ||
    pkill -f "$ROOT/api/AgendaApi" 2>/dev/null || true
  sleep 1
}
# start [ARGS]: the server in the background, waiting until it answers.
start() {
  (cd api && ./AgendaApi.exe "$PORT" "$@" > server.log 2>&1 &)
  for I in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/health/live" && return 0; sleep 1
  done
  echo "the API didn't start"; cat api/server.log; stop; exit 1
}

echo "== fresh database"
start --reset
RC=0
SERVER_LOG="$ROOT/api/server.log" sh tools/http_scenarios.sh "$PORT" || RC=$?
stop
[ $RC -eq 0 ] || { echo "--- api/server.log"; tail -20 api/server.log; exit $RC; }
grep -q "migration 2 MIG.0002" api/server.log || { echo "FAIL: migrations not applied"; exit 1; }

echo "== second start on the same database"
start
stop
if grep -q "^migration " api/server.log; then
  echo "FAIL: a second start applied migrations again"; cat api/server.log; exit 1
fi
grep -q "at version 2" api/server.log || { echo "FAIL: not at version 2"; cat api/server.log; exit 1; }
echo "ok: no migration on the second start, version 2"
