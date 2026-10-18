#!/bin/sh
# Checks the API over HTTP with curl. M0: health (live and ready, the
# database answering), the trace id in X-Request-Id, metrics, the OpenAPI
# document and Swagger UI, and a JSON 404 for an unknown route.
#
#   sh tools/http_scenarios.sh [port]   (default 9400; AgendaApi must be running)
#
# The same script for every build (FPC Windows/Linux, Delphi Win32/Win64).
# OPENAPI_OUT / METRICS_OUT: also save the document and the metrics, for the
# validators of tools/test_http_docker.sh. Exit code 0 only if every check
# passed. POSIX sh: CI runs it under dash.
PORT="${1:-9400}"
BASE="http://127.0.0.1:$PORT"
T="$(mktemp -d)"
FAILS=0
CHECKS=0

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
header()    { tr -d '\r' < "$T/headers" | grep -i "^$1:" | head -1 | sed 's/^[^:]*: *//'; }
is_trace_id() { echo "$1" | grep -qE '^[0-9a-f]{32}$'; }

# --- health
req GET /health/live ""
status_is 200 "liveness"
is_trace_id "$(header X-Request-Id)" && ok || fail "liveness: X-Request-Id '$(header X-Request-Id)'"
req GET /health/ready ""
status_is 200 "readiness"
body_is '{"status":"ok","checks":{"database":"ok"}}' "readiness: the database answers"

# --- an unknown route: JSON, one trace id (Horse runs the router twice there)
req GET /nothing-here ""
status_is 404 "unknown route"
[ "$(tr -d '\r' < "$T/headers" | grep -ci '^X-Request-Id:')" = 1 ] && ok \
  || fail "unknown route: one X-Request-Id"

# --- OpenAPI document and Swagger UI
req GET /swagger/doc.json ""
status_is 200 "OpenAPI document"
body_has '"openapi":"3.0.3"' "OpenAPI version"
body_has '"title":"Agenda API"' "OpenAPI title"
[ -n "$OPENAPI_OUT" ] && cp "$T/body" "$OPENAPI_OUT"
req GET /swagger ""
status_is 200 "Swagger UI"
body_has 'swagger-ui-dist@' "Swagger UI page"

# --- metrics (after the requests above, so they are counted)
req GET /metrics ""
status_is 200 "metrics"
body_has 'http_server_request_duration_seconds_bucket' "metrics: request duration"
body_has 'http_route="/health/ready"' "metrics: route template"
body_has 'pool_name="agenda"' "metrics: the database pool, by name"
[ -n "$METRICS_OUT" ] && cp "$T/body" "$METRICS_OUT"

rm -rf "$T"
echo "$CHECKS checks, $FAILS failed"
[ "$FAILS" -eq 0 ]
