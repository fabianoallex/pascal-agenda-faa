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
# For a Delphi build: AGENDA_EXE=api/Win32/Debug/AgendaApi.exe skips the
# build and runs the same steps on that executable.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAZBUILD="${LAZBUILD:-lazbuild}"
command -v "$LAZBUILD" >/dev/null 2>&1 || LAZBUILD=/c/lazarus4.0/lazbuild.exe
PORT="${PORT:-9400}"
cd "$ROOT"

# The scenarios' settings: development master key, a lower PBKDF2 cost (the
# rate-limit check logs in dozens of times), the /auth/ limit they expect.
export DEV_MODE=true PASSWORD_ITERATIONS=20000 AUTH_RATE_LIMIT=60

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
EXE="$ROOT/$AGENDA_EXE"
DIR="$(dirname "$EXE")"
LOG="$DIR/server.log"
export DB_FILE="$DIR/agenda-scenarios.sqlite"

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

echo "== fresh database"
rm -f "$DB_FILE"
sh tools/seed_scenarios.sh "$EXE"
start
# A token for after the restart, before the scenarios fill the /auth/ window.
TOKEN="$(curl -s -H 'Content-Type: application/json' \
  --data-binary '{"tenant":"other","email":"owner@other.test","password":"correct horse battery staple"}' \
  "http://127.0.0.1:$PORT/auth/login" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')"
RC=0
SERVER_LOG="$LOG" sh tools/http_scenarios.sh "$PORT" || RC=$?
stop
[ $RC -eq 0 ] || { echo "--- $LOG"; tail -20 "$LOG"; exit $RC; }
[ -n "$TOKEN" ] || { echo "FAIL: no token before the restart"; exit 1; }
VERSION="$(grep -o 'at version [0-9]*' "$LOG" | head -1 | tr -cd '0-9')"
[ -n "$VERSION" ] || { echo "FAIL: no schema version in the log"; exit 1; }

echo "== second start on the same database"
start
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
  "http://127.0.0.1:$PORT/me")"
stop
if grep -q "^migration " "$LOG"; then
  echo "FAIL: a second start applied migrations again"; cat "$LOG"; exit 1
fi
grep -q "at version $VERSION" "$LOG" || { echo "FAIL: not at version $VERSION"; cat "$LOG"; exit 1; }
[ "$STATUS" = 200 ] || { echo "FAIL: a token from before the restart answered $STATUS"; exit 1; }
echo "ok: no migration on the second start, version $VERSION; a token from before the restart verifies"
