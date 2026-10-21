#!/bin/sh
# Idempotency-Key on the booking over HTTP, sourced by tools/http_scenarios.sh
# after tools/http_scenarios_changes.sh: it books with the availability's
# professional ($APRO: Mondays 12:00-15:00Z) and service ($ASVC: 60 minutes
# plus 15) for the booking's customer ($CUST), on a Monday nobody booked yet.
# req keeps its arguments in the globals M, P and B: none of those names here.

MON5="$(date -u -d "$NEXT_MON + 21 days" +%F)"
body_at() { echo "{\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"customerId\":\"$CUST\",\"startsAt\":\"${MON5}T$1:00Z\"}"; }
book_key() { req POST /appointments "$2" -H "$STAFF" -H "Idempotency-Key: $1"; }

book_key k1-booking "$(body_at 12:00)"
status_is 201 "idempotency: the first request runs"
header_is Idempotent-Replayed '' "idempotency: the first answer isn't a replay"
FIRST="$(id_of)"
FIRST_BODY="$(cat "$T/body")"
book_key k1-booking "$(body_at 12:00)"
status_is 201 "idempotency: a retry gets the first status"
body_is "$FIRST_BODY" "idempotency: a retry gets the first body, the same appointment"
header_is Idempotent-Replayed 'true' "idempotency: marked as a replay"
header_is ETag '"1"' "idempotency: the stored ETag replayed"
book_key '"k1-booking"' "$(body_at 12:00)"
status_is 201 "idempotency: the key as a quoted string is the same key"
req GET "/appointments?professional=$APRO&from=${MON5}T00:00:00Z&to=${MON5}T23:59:00Z" "" -H "$STAFF"
body_has '"total":1,' "idempotency: one appointment stored, not three"

# The key belongs to one request, one tenant
book_key k1-booking "$(body_at 13:30)"
status_is 422 "idempotency: the same key for another body"
body_has '"code":"idempotency_key_reused"' "idempotency: idempotency_key_reused"
req POST /appointments "$(body_at 12:00)" -H "$OTHER" -H "Idempotency-Key: k1-booking"
status_is 400 "idempotency: another tenant's key with the same name is its own (it runs)"
body_has '"code":"unknown_professional"' "idempotency: other ran its own request"

# A client error is an answer too: the same request keeps getting it.
book_key k2-taken "$(body_at 12:00)"
status_is 409 "idempotency: a new key for a taken slot runs"
body_has '"code":"slot_unavailable"' "idempotency: slot_unavailable"
header_is Idempotent-Replayed '' "idempotency: not a replay yet"
book_key k2-taken "$(body_at 12:00)"
status_is 409 "idempotency: its retry replays the 409"
body_has '"code":"slot_unavailable"' "idempotency: the stored code"
header_is Idempotent-Replayed 'true' "idempotency: the 409 marked as a replay"
book_key k3-empty '{}'
status_is 400 "idempotency: an invalid body"
book_key k3-empty '{}'
status_is 400 "idempotency: its retry replays the 400"
body_has '"field":"professionalId","code":"required"' "idempotency: with its fields"

# The key itself
book_key 'a b' "$(body_at 14:00)"
status_is 400 "idempotency: a key with a space"
body_has '"code":"invalid_idempotency_key"' "idempotency: invalid_idempotency_key"
book_key "$(printf 'k%.0s' $(seq 1 256))" "$(body_at 14:00)"
status_is 400 "idempotency: a key of 256 characters"

# Four retries of one request at once: one runs; the others are told it is
# running (409) or, once it ended, get its answer (201). Never a second run.
RACE_BODY="$(body_at 13:30)"
for I in 1 2 3 4; do
  curl -s -o "$T/idem$I.body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H "$STAFF" -H 'Idempotency-Key: k4-race' --data-binary "$RACE_BODY" "$BASE/appointments" > "$T/idem$I" &
done
wait
IDEM="$(cat "$T/idem1" "$T/idem2" "$T/idem3" "$T/idem4" | fold -w3 | sort | tr '\n' ' ')"
case "$IDEM" in
  "201 "*) ok ;;
  *) fail "idempotency: four at once, expected a 201 first ($IDEM)" ;;
esac
echo "$IDEM" | grep -qE '^(201|409)( (201|409))* $' && ok || fail "idempotency: four at once, only 201 and 409 ($IDEM)"
if grep -l '"code"' "$T"/idem?.body >/dev/null 2>&1; then
  grep -h '"code"' "$T"/idem?.body | grep -qv 'idempotency_key_in_flight' \
    && fail "idempotency: a 409 other than in flight ($(cat "$T"/idem?.body))" || ok
else
  ok
fi
req GET "/appointments?professional=$APRO&from=${MON5}T13:00:00Z&to=${MON5}T14:00:00Z" "" -H "$STAFF"
body_has '"total":1,' "idempotency: one appointment from the four"
book_key k4-race "$RACE_BODY"
status_is 201 "idempotency: a later retry gets the 201"
header_is Idempotent-Replayed 'true' "idempotency: as a replay"

# Without a key the booking is as before (a week later: this day is full).
MON6="$(date -u -d "$MON5 + 7 days" +%F)"
req POST /appointments "$(body_at 12:00 | sed "s/$MON5/$MON6/")" -H "$STAFF"
status_is 201 "idempotency: no key, no replay"
req POST /appointments "$(body_at 12:00 | sed "s/$MON5/$MON6/")" -H "$STAFF"
status_is 409 "idempotency: no key, the same request runs again"
