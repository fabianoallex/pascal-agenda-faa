#!/bin/sh
# The worker over HTTP (docs/design.md, M4): the api running on the
# scenarios' database (after tools/http_scenarios.sh), the worker run with
# --drain between the steps, its email written as .eml files (MAIL_DIR) and
# read back by tools/eml_summary.py.
#
#   sh tools/http_scenarios_worker.sh <port> <AgendaWorker> <AgendaApi>
#
# Expects the environment tools/test_http.sh (or tools/test_http_docker.sh)
# exports: DEV_MODE, DB_*, REDIS_HOST for the Redis lease. The api's own
# command sets the tenant's reminder hours (--reminder-hours). Checks:
# - the backlog: every event the scenarios wrote handled once, the customers
#   with no email skipped and logged;
# - a booking's email: to the customer, the subject in the tenant's clock,
#   a link that opens the appointment on the api; nothing sent twice;
# - the reminder: queued once when it is due (REMINDER_HOURS), again after a
#   move (the move's own email too), none after the cancel by link (whose
#   email has no link);
# - two workers draining at once: every event emailed exactly once (on
#   PostgreSQL, the claims' SKIP LOCKED; through a broker, two consumers of
#   one queue); with REDIS_HOST, the lease in Redis; with AMQP_HOST, the
#   events through the broker (AMQP.Outbox), else the local sink;
# - on Linux, the worker running (not --drain) stops on SIGTERM, after
#   sending what was due, with exit code 0 (and 0 unfreed blocks when built
#   with heaptrc). Git Bash can't send a console's Ctrl+C to a Windows
#   program.
PORT="${1:-9400}"
WORKER="$2"
API="$3"
[ -n "$API" ] || { echo "usage: http_scenarios_worker.sh <port> <AgendaWorker> <AgendaApi>"; exit 2; }
BASE="http://127.0.0.1:$PORT"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
MAIL="$T/mail"
FAILS=0
CHECKS=0
PASSWORD="${SCENARIO_PASSWORD:-correct horse battery staple}"
PY=python3
"$PY" -c "import sys" >/dev/null 2>&1 || PY=python
export MAIL_DIR="$MAIL" PUBLIC_BASE_URL="$BASE" MAIL_FROM="Agenda Demo <agenda@demo.test>"
HEAP="$T/heap.txt"
if command -v cygpath >/dev/null 2>&1; then
  MAIL_DIR="$(cygpath -w "$MAIL")"
  HEAP="$(cygpath -w "$T/heap.txt")"
fi

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

# The tenant's reminder hours, through the api's command (no route sets it).
reminder_hours() { "$API" --reminder-hours demo "$1" > "$T/command.log" 2>&1; }

# drain [keep]: runs the worker until it finds nothing to do; the messages it
# wrote in $T/mail.txt (one line each, tools/eml_summary.py), its log in
# $T/worker.log. Without "keep" the mail directory starts empty.
# A build with heaptrc writes its report to $T/heap.txt (HEAPTRC; on Linux
# it writes none without it); no_leaks checks it when there is one.
drain() {
  [ "$1" = keep ] || rm -rf "$MAIL"
  rm -f "$T/heap.txt"
  HEAPTRC="log=$HEAP" "$WORKER" --drain > "$T/worker.log" 2>&1
  echo $? > "$T/worker.rc"
  "$PY" "$ROOT/tools/eml_summary.py" "$MAIL" > "$T/mail.txt"
}
no_leaks() {
  [ -f "$T/heap.txt" ] || return 0
  grep -q "^0 unfreed memory blocks" "$T/heap.txt" && ok || { fail "$1: leaks"; grep unfreed "$T/heap.txt"; }
}
drained_ok() {
  no_leaks "$1"
  [ "$(cat "$T/worker.rc")" = 0 ] && ok || { fail "$1: the worker exited $(cat "$T/worker.rc")"; cat "$T/worker.log"; }
  grep -q '^BAD' "$T/mail.txt" && fail "$1: a malformed message: $(grep '^BAD' "$T/mail.txt")" || ok
}
mails() { grep -c . "$T/mail.txt" | tr -d ' '; }
# mails_of KIND APPOINTMENT: how many of that kind for that appointment.
mails_of() { awk -F '\t' -v k="$1" -v a="$2" '$2 == k && $3 == a' "$T/mail.txt" | grep -c . | tr -d ' '; }
mail_field() { awk -F '\t' -v k="$1" -v a="$2" -v f="$3" '$2 == k && $3 == a { print $f; exit }' "$T/mail.txt"; }
count_is() { [ "$1" = "$2" ] && ok || { fail "$3: $1, expected $2"; cat "$T/mail.txt"; }; }

login() {
  req POST /auth/login "{\"tenant\":\"demo\",\"email\":\"$1\",\"password\":\"$PASSWORD\"}"
  sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p' "$T/body"
}
OWNER="Authorization: Bearer $(login owner@demo.test)"
STAFF="Authorization: Bearer $(login staff@demo.test)"

# --- the backlog the other scenarios left
drain
drained_ok "backlog"
[ "$(mails)" -gt 0 ] && ok || fail "backlog: no email at all"
grep -q "email skipped: .*the customer has no email" "$T/worker.log" && ok \
  || fail "backlog: a customer without email skipped and logged"
DUP="$(cut -f1 "$T/mail.txt" | sort | uniq -d)"
[ -z "$DUP" ] && ok || fail "backlog: an event emailed twice: $DUP"
if [ -n "$REDIS_HOST" ]; then
  grep -q "^lease: redis" "$T/worker.log" && ok || fail "the lease in Redis with REDIS_HOST"
else
  grep -q "^lease: database" "$T/worker.log" && ok || fail "the lease in the database"
fi
if [ -n "$AMQP_HOST" ]; then
  grep -q "^events: amqp" "$T/worker.log" && ok || fail "the broker with AMQP_HOST"
else
  grep -q "^events: the local sink" "$T/worker.log" && ok || fail "the local sink"
fi
drain
count_is "$(mails)" 0 "backlog: a second drain sends nothing"

# --- what this script books: a professional open every day, a service of 30
# minutes, a customer with an email (and accents in the name).
req POST /professionals '{"name":"Worker Pro"}' -H "$OWNER"
status_is 201 "worker: a professional"
WPRO="$(id_of)"
req PUT "/professionals/$WPRO/working-hours" \
  '{"intervals":[{"weekday":1,"from":"08:00","to":"20:00"},{"weekday":2,"from":"08:00","to":"20:00"},{"weekday":3,"from":"08:00","to":"20:00"},{"weekday":4,"from":"08:00","to":"20:00"},{"weekday":5,"from":"08:00","to":"20:00"},{"weekday":6,"from":"08:00","to":"20:00"},{"weekday":7,"from":"08:00","to":"20:00"}]}' \
  -H "$OWNER"
status_is 200 "worker: open every day"
# Accented bodies through a file with explicit UTF-8 bytes: curl.exe on
# Windows gets its arguments in the ANSI code page (as the catalog's).
printf '{"name":"Corte R\303\241pido","durationMinutes":30,"price":40}' > "$T/in.json"
req POST /services "" -H 'Content-Type: application/json' --data-binary "@$T/in.json" -H "$OWNER"
status_is 201 "worker: a service"
WSVC="$(id_of)"
printf '{"name":"J\303\272lia Worker","email":"julia@example.test"}' > "$T/in.json"
req POST /customers "" -H 'Content-Type: application/json' --data-binary "@$T/in.json" -H "$STAFF"
status_is 201 "worker: a customer with an email"
WCUST="$(id_of)"
req GET "/professionals/$WPRO/availability?service=$WSVC&date=$(date -u -d '+2 days' +%F)&days=7" "" -H "$STAFF"
status_is 200 "worker: free slots"
# Starts at least 30 minutes apart, so none overlaps another.
"$PY" -c "
import json,sys
last=''
for s in json.load(open(sys.argv[1]))['slots']:
    if s['startsAt']>=last:
        print(s['startsAt']); last=s['endsAt']
" "$T/body" > "$T/slots"
slot() { sed -n "$1p" "$T/slots"; }
[ "$(grep -c . "$T/slots")" -ge 10 ] && ok || fail "worker: ten free slots ($(cat "$T/slots"))"
book() {
  req POST /appointments "{\"professionalId\":\"$WPRO\",\"serviceId\":\"$WSVC\",\"customerId\":\"$WCUST\",\"startsAt\":\"$1\"}" -H "$STAFF"
}

# --- a booking's email
book "$(slot 1)"
status_is 201 "worker: booked"
A="$(id_of)"
drain
drained_ok "booked"
count_is "$(mails)" 1 "booked: one email"
count_is "$(mails_of appointment.booked "$A")" 1 "booked: the booking's"
count_is "$(mail_field appointment.booked "$A" 4)" "julia@example.test" "booked: to the customer"
SUBJECT="$(mail_field appointment.booked "$A" 5)"
case "$SUBJECT" in
  "Booked: Corte Rápido, "*) ok ;;
  *) fail "booked: the subject, decoded: $SUBJECT" ;;
esac
URL="$(mail_field appointment.booked "$A" 6)"
case "$URL" in
  "$BASE/public/demo/appointments/$A?exp="*) ok ;;
  *) fail "booked: the link: $URL" ;;
esac
req GET "${URL#$BASE}" ""
status_is 200 "booked: the email's link opens the appointment"
body_has "\"id\":\"$A\"" "booked: that appointment"
drain
count_is "$(mails)" 0 "booked: nothing sent twice"

# --- the reminder: due once REMINDER_HOURS reaches the start
reminder_hours 721 && fail "reminder: 721 hours accepted" || ok
reminder_hours 720 && ok || { fail "reminder: 720 hours"; cat "$T/command.log"; }
drain
drained_ok "reminder"
count_is "$(mails_of appointment.reminder "$A")" 1 "reminder: queued and sent"
SUBJECT="$(mail_field appointment.reminder "$A" 5)"
case "$SUBJECT" in
  "Reminder: Corte Rápido, "*) ok ;;
  *) fail "reminder: the subject: $SUBJECT" ;;
esac
drain
count_is "$(mails_of appointment.reminder "$A")" 0 "reminder: once"

# --- a move: its email, and the reminder again for the new start
req GET "/appointments/$A" "" -H "$STAFF"
ETAG="$(header ETag)"
req PATCH "/appointments/$A" "{\"startsAt\":\"$(slot 2)\"}" -H "$STAFF" -H "If-Match: $ETAG"
status_is 200 "move: moved"
drain
drained_ok "move"
count_is "$(mails_of appointment.moved "$A")" 1 "move: its email"
count_is "$(mails_of appointment.reminder "$A")" 1 "move: a reminder for the new start"
CANCEL_URL="$(mail_field appointment.moved "$A" 7)"
case "$CANCEL_URL" in
  "$BASE/public/demo/appointments/$A/cancel?exp="*) ok ;;
  *) fail "move: the cancel link: $CANCEL_URL" ;;
esac

# --- cancelled through the email's own link
req POST "${CANCEL_URL#$BASE}" ""
status_is 200 "cancel: the email's cancel link"
body_has '"status":"cancelled"' "cancel: cancelled"
drain
drained_ok "cancel"
count_is "$(mails_of appointment.cancelled "$A")" 1 "cancel: its email"
count_is "$(mail_field appointment.cancelled "$A" 6)" "-" "cancel: no link in it"
count_is "$(mails)" 1 "cancel: no reminder for it"

# --- two workers at once: each event once
# (req keeps its arguments in the globals M, P and B: none of those here.)
IDS=""
for I in 3 4 5 6 7 8; do
  book "$(slot $I)"
  status_is 201 "two workers: booking $I"
  IDS="$IDS $(id_of)"
done
rm -rf "$MAIL"
"$WORKER" --drain > "$T/w1.log" 2>&1 &
W1=$!
RC2=0
"$WORKER" --drain > "$T/w2.log" 2>&1 || RC2=$?
RC1=0
wait $W1 || RC1=$?
# Neither failed (both start at once: the mail directory, the leases).
[ "$RC1.$RC2" = 0.0 ] && ok || { fail "two workers: exit codes $RC1 and $RC2"; grep -h "^ERROR" "$T/w1.log" "$T/w2.log" | head -5; }
# Nothing left behind (a third drain finds the outbox done).
drain keep
drained_ok "two workers"
for ID in $IDS; do
  count_is "$(mails_of appointment.booked "$ID")" 1 "two workers: one booking email for $ID"
  count_is "$(mails_of appointment.reminder "$ID")" 1 "two workers: one reminder for $ID"
done
DUP="$(cut -f1 "$T/mail.txt" | sort | uniq -d)"
[ -z "$DUP" ] && ok || fail "two workers: an event emailed twice: $DUP"

# --- running, stopped by SIGTERM (Linux): what was due goes out first
if [ "$(uname -s)" = Linux ]; then
  rm -rf "$MAIL"
  rm -f "$T/heap.txt"
  HEAPTRC="log=$HEAP" OUTBOX_POLL_MS=200 "$WORKER" > "$T/run.log" 2>&1 &
  WPID=$!
  book "$(slot 9)"
  status_is 201 "running: a booking"
  RUNID="$(id_of)"
  for I in $(seq 1 50); do
    "$PY" "$ROOT/tools/eml_summary.py" "$MAIL" > "$T/mail.txt"
    [ "$(mails_of appointment.booked "$RUNID")" = 1 ] && break
    sleep 0.2
  done
  count_is "$(mails_of appointment.booked "$RUNID")" 1 "running: sent without --drain"
  kill -TERM "$WPID"
  RC=0
  wait "$WPID" || RC=$?
  count_is "$RC" 0 "running: SIGTERM, exit code"
  grep -q "^agenda-worker stopped" "$T/run.log" && ok || { fail "running: a clean stop"; cat "$T/run.log"; }
  no_leaks "running"
fi

reminder_hours 24 && ok || fail "reminder: back to 24 hours"
echo "worker: $CHECKS checks, $FAILS failed"
rm -rf "$T"
[ "$FAILS" -eq 0 ]
