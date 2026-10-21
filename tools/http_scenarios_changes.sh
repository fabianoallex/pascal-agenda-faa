#!/bin/sh
# Changing and cancelling appointments over HTTP (If-Match), sourced by
# tools/http_scenarios.sh after tools/http_scenarios_appointments.sh: it uses
# that file's professional ($APRO: Mondays 09:00-12:00 in America/Sao_Paulo,
# 12:00-15:00Z), service ($ASVC: 60 minutes plus 15 of buffer) and customer
# ($CUST), on a Monday nobody booked yet ($MON4).

MON4="$(date -u -d "$NEXT_MON + 14 days" +%F)"
patch_appt() { req PATCH "/appointments/$1" "$2" -H "$STAFF" -H "If-Match: $3"; }
cancel_appt() { req POST "/appointments/$1/cancel" "" -H "$STAFF" -H "If-Match: $2"; }

book "$APRO" "$ASVC" "$CUST" "${MON4}T12:00:00Z"
status_is 201 "changes: a booking"
header_is ETag '"1"' "changes: the booking's ETag, its version in quotes"
CA="$(id_of)"
req GET "/appointments/$CA" "" -H "$STAFF"
header_is ETag '"1"' "changes: the same ETag on a read"

# If-Match: required, a tag, the current one
req PATCH "/appointments/$CA" '{"status":"confirmed"}' -H "$STAFF"
status_is 428 "changes: without If-Match"
body_has '"code":"precondition_required"' "changes: precondition_required"
patch_appt "$CA" '{"status":"confirmed"}' '*'
status_is 428 "changes: If-Match * names no version"
patch_appt "$CA" '{"status":"confirmed"}' '1'
status_is 400 "changes: a version without its quotes"
body_has '"code":"invalid_if_match"' "changes: invalid_if_match"
patch_appt "$CA" '{"status":"confirmed"}' '"2"'
status_is 412 "changes: a version it never had"
body_has '"code":"precondition_failed"' "changes: precondition_failed"
patch_appt "$CA" '{"status":"confirmed"}' 'W/"1"'
status_is 412 "changes: a weak tag never matches"
patch_appt nothing '{"status":"confirmed"}' '"1"'
status_is 404 "changes: an unknown id"
req PATCH "/appointments/$CA" '{"status":"confirmed"}' -H "$OTHER" -H 'If-Match: "1"'
status_is 404 "changes: other tenant can't change demo's"

# The status
patch_appt "$CA" '{"status":"confirmed"}' '"1"'
status_is 200 "changes: confirmed"
body_has '"status":"confirmed","version":2' "changes: confirmed, version 2"
header_is ETag '"2"' "changes: the new ETag"
patch_appt "$CA" '{"status":"confirmed"}' '"1"'
status_is 412 "changes: the version read before someone else's change (a lost update)"
patch_appt "$CA" '{"status":"cancelled"}' '"2"'
status_is 400 "changes: cancelled is not a PATCH"
body_has '"code":"use_cancel"' "changes: use_cancel"
patch_appt "$CA" '{"status":"lost"}' '"2"'
status_is 400 "changes: a status that isn't one"
patch_appt "$CA" '{"status":"booked"}' '"2"'
status_is 400 "changes: back to booked isn't one PATCH sets"
patch_appt "$CA" '{"status":"done"}' '"2"'
status_is 409 "changes: done before it started"
body_has '"code":"not_started"' "changes: not_started"
patch_appt "$CA" '{"status":"no_show"}' '"2"'
status_is 409 "changes: no_show before it started"
patch_appt "$CA" '{}' '"2"'
status_is 200 "changes: nothing to change"
body_has '"version":2' "changes: nothing changed, the version stays"

# Moving: the booking's checks, its own time counted free
patch_appt "$CA" "{\"startsAt\":\"${MON4}T12:15:00Z\"}" '"2"'
status_is 200 "changes: moved 15 minutes, over its own old time"
body_has "\"startsAt\":\"${MON4}T12:15:00Z\",\"endsAt\":\"${MON4}T13:15:00Z\",\"status\":\"confirmed\",\"version\":3" \
  "changes: the new start, the same duration, the status kept, version 3"
req GET "$AV&date=$MON4" "" -H "$STAFF"
count_is 3 "changes: the moved slot and its buffer taken (13:30 to 14:00 left)"
body_has "\"slots\":[{\"startsAt\":\"${MON4}T13:30:00Z\"" "changes: the first after the new buffer"
book "$APRO" "$ASVC" "$CUST" "${MON4}T13:30:00Z"
status_is 201 "changes: a second booking right after"
CB="$(id_of)"
patch_appt "$CA" "{\"startsAt\":\"${MON4}T13:30:00Z\"}" '"3"'
status_is 409 "changes: onto the second booking"
body_has '"code":"slot_unavailable"' "changes: slot_unavailable"
patch_appt "$CA" "{\"startsAt\":\"${MON4}T12:30:00Z\"}" '"3"'
status_is 409 "changes: its buffer would run into the second booking"
patch_appt "$CA" "{\"startsAt\":\"${MON4}T12:20:00Z\"}" '"3"'
status_is 409 "changes: off the 15-minute grid"
patch_appt "$CA" "{\"startsAt\":\"$(date -u -d "next monday - 14 days" +%F)T12:00:00Z\"}" '"3"'
status_is 409 "changes: to a Monday in the past"
patch_appt "$CA" "{\"startsAt\":\"${MON4}T12:00:30Z\"}" '"3"'
status_is 400 "changes: seconds"
body_has '"code":"not_whole_minutes"' "changes: not_whole_minutes"
patch_appt "$CA" '{"startsAt":"tomorrow"}' '"3"'
status_is 400 "changes: a start that isn't an instant"
body_has '"code":"invalid_instant"' "changes: invalid_instant"
patch_appt "$CA" "{\"startsAt\":\"${MON4}T12:00:00Z\"}" '"2"'
status_is 412 "changes: a move from an old version"
patch_appt "$CA" "{\"startsAt\":\"${MON4}T09:00:00-03:00\"}" '"3"'
status_is 200 "changes: moved back, given with an offset"
body_has "\"startsAt\":\"${MON4}T12:00:00Z\"" "changes: stored in UTC"
body_has '"version":4' "changes: version 4"

# Four changes from the same version at once: one wins, the others are 412.
for I in 1 2 3 4; do
  curl -s -o "$T/chg$I.body" -w '%{http_code}' -X PATCH -H 'Content-Type: application/json' \
    -H "$STAFF" -H 'If-Match: "4"' --data-binary '{"status":"confirmed"}' \
    "$BASE/appointments/$CA" > "$T/chg$I" &
done
wait
CHG="$(cat "$T/chg1" "$T/chg2" "$T/chg3" "$T/chg4" | fold -w3 | sort | tr '\n' ' ')"
[ "$CHG" = "200 412 412 412 " ] && ok || fail "changes: four at once from one version, expected one 200 and three 412 ($CHG; $(cat "$T"/chg*.body))"
req GET "/appointments/$CA" "" -H "$STAFF"
body_has '"version":5' "changes: one change stored, version 5"

# Cancelling: If-Match, then the rules
req POST "/appointments/$CB/cancel" "" -H "$STAFF"
status_is 428 "cancel: without If-Match"
cancel_appt "$CB" '"2"'
status_is 412 "cancel: a version it never had"
cancel_appt "$CB" '"1"'
status_is 200 "cancel: within the notice"
body_has '"status":"cancelled","version":2' "cancel: cancelled, version 2"
header_is ETag '"2"' "cancel: the new ETag"
cancel_appt "$CB" '"2"'
status_is 409 "cancel: already cancelled"
body_has '"code":"appointment_closed"' "cancel: appointment_closed"
patch_appt "$CB" '{"status":"confirmed"}' '"2"'
status_is 409 "changes: a cancelled appointment doesn't change"
req GET "$AV&date=$MON4" "" -H "$STAFF"
body_has "\"startsAt\":\"${MON4}T13:15:00Z\"" "cancel: its time free again"
req POST "/appointments/$CB/cancel" "" -H "$OTHER" -H 'If-Match: "2"'
status_is 404 "cancel: other tenant can't cancel demo's"

# The notice (24 hours by default): a professional who works every hour, a
# booking within the next half hour, too late to cancel.
req POST /professionals '{"name":"Gil Ramos"}' -H "$OWNER"
NPRO="$(id_of)"
WEEK=""
for D in 1 2 3 4 5 6 7; do WEEK="$WEEK${WEEK:+,}{\"weekday\":$D,\"from\":\"00:00\",\"to\":\"24:00\"}"; done
req PUT "/professionals/$NPRO/working-hours" "{\"intervals\":[$WEEK]}" -H "$OWNER"
status_is 200 "notice: a professional working every hour"
req GET "/professionals/$NPRO/availability?service=$ASVC&date=$(date -u -d "yesterday" +%F)&days=3" "" -H "$STAFF"
# The second slot: the first may have started by the time the booking arrives.
SOON="$(sed -n 's/.*"slots":\[{[^}]*},{"startsAt":"\([^"]*\)".*/\1/p' "$T/body")"
[ -n "$SOON" ] && ok || fail "notice: a free slot soon (body: $(cat "$T/body"))"
book "$NPRO" "$ASVC" "$CUST" "$SOON"
status_is 201 "notice: booked within the next half hour"
N="$(id_of)"
cancel_appt "$N" '"1"'
status_is 409 "notice: too late to cancel"
body_has '"code":"cancel_notice_passed"' "notice: cancel_notice_passed"
body_has "Cancelling needs 24 hours' notice" "notice: the hours named"
patch_appt "$N" '{"status":"confirmed"}' '"1"'
status_is 200 "notice: still confirmed"
