#!/bin/sh
# The email and the trace end to end on the docker-compose.yml stack
# (tools/test_compose.sh runs it): the api and the worker in containers, the
# events through RabbitMQ, the email through SMTP to Mailpit, the spans to
# the OpenTelemetry Collector.
#
#   sh tools/http_scenarios_mail.sh [api port] [mailpit port]   (9400, 8025)
#
# Checks: a booking's email reaches Mailpit (recipient, subject decoded, the
# link opening the appointment on the api), the cancel through the email's
# link sends its own; the booking's trace (the api's X-Request-Id) holds the
# api's request, the worker's relay, the publish and the "process" span of
# the email's consumer, in the collector's output. Waits are polls with a
# deadline: the worker runs on its own.
PORT="${1:-9400}"
MAILPIT="http://127.0.0.1:${2:-8025}"
BASE="http://127.0.0.1:$PORT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
FAILS=0
CHECKS=0
PASSWORD="${SCENARIO_PASSWORD:-correct horse battery staple}"
PY=python3
"$PY" -c "import sys" >/dev/null 2>&1 || PY=python
# The links the worker writes (PUBLIC_BASE_URL in docker-compose.yml).
LINK_BASE="http://localhost:$PORT"
# Unique per run: Mailpit keeps what earlier runs sent.
RUN="$(date +%s)"
EMAIL="mail$RUN@example.test"

req() {
  M="$1"; P="$2"; B="$3"; if [ $# -ge 3 ]; then shift 3; else shift $#; fi
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
body_has()  { grep -qF -- "$1" "$T/body" && ok || fail "$2: body lacks $1 (body: $(cat "$T/body"))"; }
id_of()     { sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p' "$T/body"; }
header()    { tr -d '\r' < "$T/headers" | grep -i "^$1:" | head -1 | sed 's/^[^:]*: *//'; }
count_is()  { [ "$1" = "$2" ] && ok || fail "$3: $1, expected $2"; }

# The customer's messages in $T/mail.txt (tools/mailpit_summary.py).
mails() { "$PY" "$ROOT/tools/mailpit_summary.py" "$MAILPIT" "$EMAIL" > "$T/mail.txt" 2>/dev/null; }
kind_count() { awk -F '\t' -v k="$1" '$1 == k' "$T/mail.txt" | grep -c . | tr -d ' '; }
mail_field() { awk -F '\t' -v k="$1" -v f="$2" '$1 == k { print $f; exit }' "$T/mail.txt"; }
# wait_mail KIND: polls Mailpit until a message of KIND is there (30 s).
wait_mail() {
  for I in $(seq 1 60); do
    mails
    [ "$(kind_count "$1")" -ge 1 ] && return 0
    sleep 0.5
  done
  return 1
}

req POST /auth/login "{\"tenant\":\"demo\",\"email\":\"owner@demo.test\",\"password\":\"$PASSWORD\"}"
status_is 200 "login"
OWNER="Authorization: Bearer $(sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' "$T/body")"

req POST /professionals "{\"name\":\"Mail Pro $RUN\"}" -H "$OWNER"
status_is 201 "a professional"
PRO="$(id_of)"
req PUT "/professionals/$PRO/working-hours" \
  '{"intervals":[{"weekday":1,"from":"08:00","to":"20:00"},{"weekday":2,"from":"08:00","to":"20:00"},{"weekday":3,"from":"08:00","to":"20:00"},{"weekday":4,"from":"08:00","to":"20:00"},{"weekday":5,"from":"08:00","to":"20:00"},{"weekday":6,"from":"08:00","to":"20:00"},{"weekday":7,"from":"08:00","to":"20:00"}]}' \
  -H "$OWNER"
status_is 200 "open every day"
# Accented bodies through a file with UTF-8 bytes (curl.exe on Windows gets
# its arguments in the ANSI code page).
printf '{"name":"Massagem R\303\241pida %s","durationMinutes":30,"price":90}' "$RUN" > "$T/in.json"
req POST /services "" -H 'Content-Type: application/json' --data-binary "@$T/in.json" -H "$OWNER"
status_is 201 "a service"
SVC="$(id_of)"
printf '{"name":"Jo\303\243o Mail","email":"%s"}' "$EMAIL" > "$T/in.json"
req POST /customers "" -H 'Content-Type: application/json' --data-binary "@$T/in.json" -H "$OWNER"
status_is 201 "a customer with an email"
CUST="$(id_of)"
req GET "/professionals/$PRO/availability?service=$SVC&date=$(date -u -d '+2 days' +%F)&days=3" "" -H "$OWNER"
status_is 200 "free slots"
START="$(sed -n 's/.*"slots":\[{"startsAt":"\([^"]*\)".*/\1/p' "$T/body")"

# --- a booking's email, through the broker and SMTP
req POST /appointments "{\"professionalId\":\"$PRO\",\"serviceId\":\"$SVC\",\"customerId\":\"$CUST\",\"startsAt\":\"$START\"}" -H "$OWNER"
status_is 201 "booked"
A="$(id_of)"
TRACE="$(header X-Request-Id)"
wait_mail appointment.booked && ok || fail "booked: no email in Mailpit"
count_is "$(mail_field appointment.booked 2)" "$A" "booked: for this appointment"
SUBJECT="$(mail_field appointment.booked 3)"
case "$SUBJECT" in
  "Booked: Massagem Rápida $RUN, "*) ok ;;
  *) fail "booked: the subject, decoded by Mailpit: $SUBJECT" ;;
esac
URL="$(mail_field appointment.booked 4)"
case "$URL" in
  "$LINK_BASE/public/demo/appointments/$A?exp="*) ok ;;
  *) fail "booked: the link: $URL" ;;
esac
req GET "${URL#$LINK_BASE}" ""
status_is 200 "booked: the email's link opens the appointment"
body_has "\"id\":\"$A\"" "booked: that appointment"

# --- the cancel through the email's own link, and its email
CANCEL="$(mail_field appointment.booked 5)"
req POST "${CANCEL#$LINK_BASE}" ""
status_is 200 "cancel: the email's cancel link"
wait_mail appointment.cancelled && ok || fail "cancel: no email in Mailpit"
count_is "$(mail_field appointment.cancelled 4)" "-" "cancel: no link in it"
count_is "$(kind_count appointment.booked)" 1 "booked: one email, not two"

# --- one trace from the request to the email (the collector's file)
SPANS=""
for I in $(seq 1 60); do
  # MSYS_NO_PATHCONV: Git Bash would turn /data into a Windows path.
  MSYS_NO_PATHCONV=1 docker run --rm -v "${COMPOSE_PROJECT_NAME:-agenda}_otel-data:/data" busybox cat /data/traces.json     > "$T/traces.json" 2>/dev/null
  "$PY" "$ROOT/tools/otel_spans.py" "$T/traces.json" "$TRACE" > "$T/spans.txt" 2>/dev/null
  # Both processes' batches: each exports on its own schedule (OTEL_BSP_SCHEDULE_DELAY).
  grep -q "^agenda-worker	email send" "$T/spans.txt" && grep -q "^agenda-api	" "$T/spans.txt" && break
  sleep 0.5
done
grep -q "^agenda-api	" "$T/spans.txt" && ok || fail "trace $TRACE: no api span ($(cat "$T/spans.txt"))"
grep -q "^agenda-worker	outbox appointment.booked" "$T/spans.txt" && ok \
  || fail "trace $TRACE: no relay span ($(cat "$T/spans.txt"))"
grep -q "^agenda-worker	publish agenda.events" "$T/spans.txt" && ok \
  || fail "trace $TRACE: no publish span ($(cat "$T/spans.txt"))"
grep -q "^agenda-worker	process agenda.email" "$T/spans.txt" && ok \
  || fail "trace $TRACE: no consumer span ($(cat "$T/spans.txt"))"
grep -q "^agenda-worker	email send" "$T/spans.txt" && ok \
  || fail "trace $TRACE: no span for the send ($(cat "$T/spans.txt"))"

echo "mail: $CHECKS checks, $FAILS failed"
rm -rf "$T"
[ "$FAILS" -eq 0 ]
