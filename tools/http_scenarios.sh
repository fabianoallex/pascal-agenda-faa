#!/bin/sh
# Checks the API over HTTP with curl, on a database seeded by
# tools/seed_scenarios.sh (tenants demo, other, frozen suspended):
# - operations: health (the database answering), the trace id, metrics, the
#   OpenAPI document, a JSON 404;
# - login: the right password, and one answer for every wrong part (tenant,
#   email, password); a suspended tenant only after the right password;
# - refresh tokens: rotation, a spent token coming back revokes its family,
#   two refreshes racing on one token, logout, a token moved to another
#   tenant; /me with the access token; an access token whose tenant was
#   changed (signature no longer matches);
# - the rate limit on /auth/ by client address (last: it uses the window).
#
#   sh tools/http_scenarios.sh [port]   (default 9400; AgendaApi must be running,
#                                        with AUTH_RATE_LIMIT=60)
#
# The same script for every build (FPC Windows/Linux, Delphi Win32/Win64).
# OPENAPI_OUT / METRICS_OUT: also save the document and the metrics, for the
# validators. SERVER_LOG: the server's output, to check what it logged.
# Python (python3 or python) forges the tampered token; without it that
# check is skipped. Exit code 0 only if every check passed. POSIX sh: CI
# runs it under dash.
PORT="${1:-9400}"
BASE="http://127.0.0.1:$PORT"
T="$(mktemp -d)"
FAILS=0
CHECKS=0
PASSWORD="${SCENARIO_PASSWORD:-correct horse battery staple}"
# A Python that runs (on Windows, "python3" may be the Store's stub).
PY=""
for C in python3 python; do
  if command -v "$C" >/dev/null 2>&1 && "$C" -c "import sys" >/dev/null 2>&1; then PY="$C"; break; fi
done

# req METHOD PATH [BODY] [extra curl args...] -> $T/status, $T/headers, $T/body
req() {
  M="$1"; P="$2"; B="$3"; if [ $# -ge 3 ]; then shift 3; else shift $#; fi # dash: shift past $# is fatal
  if [ -n "$B" ]; then
    curl -s -X "$M" -o "$T/body" -D "$T/headers" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary "$B" "$@" "$BASE$P" > "$T/status"
  else
    curl -s -X "$M" -o "$T/body" -D "$T/headers" -w '%{http_code}' "$@" "$BASE$P" > "$T/status"
  fi
}
ok()   { CHECKS=$((CHECKS + 1)); }
fail() { CHECKS=$((CHECKS + 1)); FAILS=$((FAILS + 1)); echo "FAIL: $1"; }
status_is() { [ "$(cat "$T/status")" = "$1" ] && ok || fail "$2: status $(cat "$T/status"), expected $1 (body: $(cat "$T/body"))"; }
body_is()   { [ "$(cat "$T/body")" = "$1" ] && ok || fail "$2: body $(cat "$T/body"), expected $1"; }
body_has()  { grep -qF -- "$1" "$T/body" && ok || fail "$2: body lacks $1 (body: $(cat "$T/body"))"; }
body_lacks(){ grep -qF -- "$1" "$T/body" && fail "$2: body has $1" || ok; }
header()    { tr -d '\r' < "$T/headers" | grep -i "^$1:" | head -1 | sed 's/^[^:]*: *//'; }
header_is() { [ "$(header "$1")" = "$2" ] && ok || fail "$3: header $1 = '$(header "$1")', expected '$2'"; }
is_trace_id() { echo "$1" | grep -qE '^[0-9a-f]{32}$'; }
field()     { sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$T/body"; }
login()     { req POST /auth/login "{\"tenant\":\"$1\",\"email\":\"$2\",\"password\":\"$3\"}"; }
refresh()   { req POST /auth/refresh "{\"refreshToken\":\"$1\"}"; }
logout()    { req POST /auth/logout "{\"refreshToken\":\"$1\"}"; }
INVALID_CREDENTIALS='{"error":"Invalid email or password.","code":"invalid_credentials"}'
INVALID_REFRESH='{"error":"Invalid or expired refresh token.","code":"invalid_refresh_token"}'

# --- health
req GET /health/live ""
status_is 200 "liveness"
is_trace_id "$(header X-Request-Id)" && ok || fail "liveness: X-Request-Id '$(header X-Request-Id)'"
req GET /health/ready ""
status_is 200 "readiness"
body_is '{"status":"ok","checks":{"database":"ok"}}' "readiness: the database answers"

# --- an unknown route: refused before routing (JWT), one trace id
req GET /nothing-here ""
status_is 401 "unknown route without a token"
[ "$(tr -d '\r' < "$T/headers" | grep -ci '^X-Request-Id:')" = 1 ] && ok \
  || fail "unknown route: one X-Request-Id"

# --- login
req GET /me ""
status_is 401 "me without a token"
header_is WWW-Authenticate 'Bearer' "me without a token"

login demo owner@demo.test "$PASSWORD"
status_is 200 "login"
header_is Cache-Control 'no-store' "login: tokens are not cached"
body_has '"tokenType":"Bearer","expiresIn":900' "login: token type and lifetime"
ACCESS="$(field accessToken)"
REFRESH1="$(field refreshToken)"
case "$REFRESH1" in demo.*) ok ;; *) fail "login: refresh token '$REFRESH1' names its tenant" ;; esac
[ "$(echo "$ACCESS" | tr -cd '.' | wc -c | tr -d ' ')" = 2 ] && ok || fail "login: a JWT ($ACCESS)"

req GET /me "" -H "Authorization: Bearer $ACCESS"
status_is 200 "me"
body_has '"email":"owner@demo.test","role":"owner","tenant":"demo"' "me: the caller"

login demo '  OWNER@Demo.Test ' "$PASSWORD"
status_is 200 "login: the email is trimmed and lower-cased"
login demo staff@demo.test "$PASSWORD"
status_is 200 "login: staff"
STAFF_ACCESS="$(field accessToken)"
req GET /me "" -H "Authorization: Bearer $STAFF_ACCESS"
body_has '"email":"staff@demo.test","role":"staff"' "me: staff"

# One answer for every wrong part: nothing says which tenants or users exist.
login demo owner@demo.test "wrong password"
status_is 401 "wrong password"
body_is "$INVALID_CREDENTIALS" "wrong password"
header_is WWW-Authenticate 'Bearer' "wrong password: the scheme"
login demo nobody@demo.test "$PASSWORD"
status_is 401 "unknown email"
body_is "$INVALID_CREDENTIALS" "unknown email: the same answer"
login nowhere owner@demo.test "$PASSWORD"
status_is 401 "unknown tenant"
body_is "$INVALID_CREDENTIALS" "unknown tenant: the same answer"
login 'Demo Clinic!' owner@demo.test "$PASSWORD"
status_is 401 "not a tenant id"
body_is "$INVALID_CREDENTIALS" "not a tenant id: the same answer"
login other owner@demo.test "$PASSWORD"
status_is 401 "another tenant's user"
body_is "$INVALID_CREDENTIALS" "another tenant's user: the same answer"
login demo 'not-an-email' "$PASSWORD"
body_is "$INVALID_CREDENTIALS" "not an email: the same answer"
login frozen owner@frozen.test "wrong password"
status_is 401 "suspended tenant, wrong password"
body_is "$INVALID_CREDENTIALS" "suspended tenant, wrong password: not told it is suspended"
login frozen owner@frozen.test "$PASSWORD"
status_is 403 "suspended tenant, right password"
body_has '"code":"tenant_suspended"' "suspended tenant, right password"

req POST /auth/login '{"tenant":"demo","email":"owner@demo.test"}'
status_is 400 "login without password"
body_has '"password' "login without password: names it"
req POST /auth/login "{\"tenant\":\"demo\",\"email\":\"owner@demo.test\",\"password\":\"$PASSWORD\",\"admin\":true}"
status_is 400 "login with an unknown member"
req POST /auth/login 'not json'
status_is 400 "login, not JSON"

# --- refresh tokens: rotation
refresh "$REFRESH1"
status_is 200 "refresh"
REFRESH2="$(field refreshToken)"
ACCESS2="$(field accessToken)"
[ -n "$REFRESH2" ] && [ "$REFRESH2" != "$REFRESH1" ] && ok || fail "refresh: a new refresh token"
req GET /me "" -H "Authorization: Bearer $ACCESS2"
body_has '"email":"owner@demo.test"' "refresh: the new access token works"

# A spent token comes back: someone copied it. The family is revoked.
refresh "$REFRESH1"
status_is 401 "a spent refresh token"
body_is "$INVALID_REFRESH" "a spent refresh token"
refresh "$REFRESH2"
status_is 401 "after a reuse, the newest token of the family is revoked too"
if [ -n "$SERVER_LOG" ]; then
  grep -q "SECURITY refresh token family .* of tenant demo revoked: a used refresh token came back" \
    "$SERVER_LOG" && ok || fail "the reuse is in the server's log"
fi

# Two refreshes racing on one token: one wins, and the family is revoked
# (the loser can't tell a race from a copy).
login demo owner@demo.test "$PASSWORD"
RACE="$(field refreshToken)"
for N in 1 2; do
  curl -s -o "$T/race$N" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary "{\"refreshToken\":\"$RACE\"}" "$BASE/auth/refresh" > "$T/race$N.status" &
done
wait
STATUSES="$(cat "$T/race1.status") $(cat "$T/race2.status")"
case "$STATUSES" in "200 401"|"401 200") ok ;; *) fail "race: statuses $STATUSES, expected one 200 and one 401" ;; esac
for N in 1 2; do
  if [ "$(cat "$T/race$N.status")" = 200 ]; then
    WINNER="$(sed -n 's/.*"refreshToken":"\([^"]*\)".*/\1/p' "$T/race$N")"
    refresh "$WINNER"
    status_is 401 "race: the winner's next token is revoked with its family"
  fi
done

# Logout
login demo owner@demo.test "$PASSWORD"
REFRESH3="$(field refreshToken)"
logout "$REFRESH3"
status_is 204 "logout"
refresh "$REFRESH3"
status_is 401 "refresh after logout"
logout "$REFRESH3"
status_is 204 "logout again: the same answer"
logout "garbage"
status_is 204 "logout of garbage: the same answer"

# Malformed, and a token moved to another tenant.
refresh "garbage"
status_is 401 "refresh: garbage"
body_is "$INVALID_REFRESH" "refresh: garbage"
login demo owner@demo.test "$PASSWORD"
REFRESH4="$(field refreshToken)"
refresh "other.${REFRESH4#demo.}"
status_is 401 "refresh: a demo token presented as other's"
refresh "nowhere.${REFRESH4#demo.}"
status_is 401 "refresh: an unknown tenant"
body_is "$INVALID_REFRESH" "refresh: an unknown tenant, the same answer"
refresh "$REFRESH4"
status_is 200 "refresh: the real one still works after the attempts"
req POST /auth/refresh '{}'
status_is 400 "refresh without a token"

# --- another tenant, and a tampered access token
login other owner@other.test "$PASSWORD"
status_is 200 "login other"
OTHER_ACCESS="$(field accessToken)"
req GET /me "" -H "Authorization: Bearer $OTHER_ACCESS"
body_has '"email":"owner@other.test","role":"owner","tenant":"other"' "me: other tenant"
if [ -n "$PY" ]; then
  FORGED="$("$PY" -I -c '
import base64, json, sys
h, p, s = sys.argv[1].split(".")
claims = json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))
claims["tenant_id"] = "other"
p2 = base64.urlsafe_b64encode(json.dumps(claims, separators=(",", ":")).encode()).decode().rstrip("=")
print(h + "." + p2 + "." + s)' "$ACCESS")"
  # Forged for real: a JWT that differs from the original only in its payload.
  [ "${FORGED%%.*}" = "${ACCESS%%.*}" ] && [ "${FORGED##*.}" = "${ACCESS##*.}" ] &&
    [ "$FORGED" != "$ACCESS" ] && ok || fail "the tampered token was not built ($FORGED)"
  req GET /me "" -H "Authorization: Bearer $FORGED"
  status_is 401 "an access token whose tenant was changed"
else
  echo "skipped: no Python for the tampered token"
fi

# --- OpenAPI document and Swagger UI
req GET /swagger/doc.json ""
status_is 200 "OpenAPI document"
body_has '"openapi":"3.0.3"' "OpenAPI version"
body_has '"title":"Agenda API"' "OpenAPI title"
body_has '"/auth/login":{"post":{' "OpenAPI: login"
body_has '"securitySchemes":{"bearerAuth":' "OpenAPI: the bearer scheme, from the middleware"
body_has '"LoginRequest":{"type":"object","description":"Credentials of a user of one tenant"' "OpenAPI: the login body"
[ -n "$OPENAPI_OUT" ] && cp "$T/body" "$OPENAPI_OUT"
req GET /swagger ""
status_is 200 "Swagger UI"
body_has 'swagger-ui-dist@' "Swagger UI page"

# --- metrics (after the requests above, so they are counted)
req GET /metrics ""
status_is 200 "metrics"
body_has 'http_server_request_duration_seconds_bucket' "metrics: request duration"
body_has 'http_route="/auth/login"' "metrics: route template"
body_has 'pool_name="agenda"' "metrics: the database pool, by name"
[ -n "$METRICS_OUT" ] && cp "$T/body" "$METRICS_OUT"

# --- the rate limit on /auth/ (last: it fills this address's window)
LIMITED=0
I=0
while [ $I -lt 80 ]; do
  I=$((I + 1))
  login demo owner@demo.test "wrong password"
  if [ "$(cat "$T/status")" = 429 ]; then LIMITED=1; break; fi
done
[ $LIMITED = 1 ] && ok || fail "the /auth/ rate limit never answered 429 in 80 attempts"
header_is X-RateLimit-Limit 60 "rate limit: the /auth/ limit"
req GET /me "" -H "Authorization: Bearer $ACCESS2"
status_is 200 "rate limit: other routes keep their own window"

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
