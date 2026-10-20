#!/bin/sh
# Booking over HTTP, sourced by tools/http_scenarios.sh after
# tools/http_scenarios_availability.sh: it books with that file's
# professional ($APRO: Mondays 09:00-12:00 in America/Sao_Paulo, time off
# 10:00-10:30 on $MON) and service ($ASVC: 60 minutes plus 15 of buffer).
# No logins here.

req POST /customers '{"name":"Bia Costa"}' -H "$STAFF"
status_is 201 "booking: a customer"
CUST="$(id_of)"
book() { req POST /appointments "{\"professionalId\":\"$1\",\"serviceId\":\"$2\",\"customerId\":\"$3\",\"startsAt\":\"$4\"}" -H "$STAFF"; }

# A start the availability lists
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T09:00:00-03:00"
status_is 201 "booking: a free slot"
body_has "\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"customerId\":\"$CUST\",\"startsAt\":\"${NEXT_MON}T12:00:00Z\",\"endsAt\":\"${NEXT_MON}T13:00:00Z\",\"status\":\"booked\",\"version\":1" \
  "booking: as stored, in UTC, booked, version 1"
APPT="$(id_of)"
req GET "$AV&date=$NEXT_MON" "" -H "$STAFF"
count_is 4 "booking: the slot and its buffer taken (10:15 to 11:00 left)"
body_has "\"slots\":[{\"startsAt\":\"${NEXT_MON}T13:15:00Z\"" "booking: the first after the buffer"

# Starts that aren't free
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T09:00:00-03:00"
status_is 409 "booking: the same slot again"
body_has '"code":"slot_unavailable"' "booking: slot_unavailable"
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T10:00:00-03:00"
status_is 409 "booking: inside the first one's buffer"
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T10:20:00-03:00"
status_is 409 "booking: off the 15-minute grid"
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T11:30:00-03:00"
status_is 409 "booking: the service would end after closing"
book "$APRO" "$ASVC" "$CUST" "${MON}T09:00:00-03:00"
status_is 409 "booking: its buffer would run into time off"
book "$APRO" "$ASVC" "$CUST" "$(date -u -d "next monday + 7 days - 14 days" +%F)T12:00:00Z"
status_is 409 "booking: a Monday in the past"
book "$APRO" "$ASVC" "$CUST" "$(date -u -d "$MON + 1 day" +%F)T12:00:00Z"
status_is 409 "booking: a day without hours"

# Two clients race for one slot, four requests at once: one wins.
P="{\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"customerId\":\"$CUST\",\"startsAt\":\"${NEXT_MON}T13:30:00Z\"}"
for I in 1 2 3 4; do
  curl -s -o "$T/race$I.body" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
    -H "$STAFF" --data-binary "$P" "$BASE/appointments" > "$T/race$I" &
done
wait
RACE="$(cat "$T/race1" "$T/race2" "$T/race3" "$T/race4" | fold -w3 | sort | tr '\n' ' ')"
[ "$RACE" = "201 409 409 409 " ] && ok || fail "booking: four at once, expected one 201 and three 409 ($RACE; $(cat "$T"/race*.body))"
req GET "/appointments?professional=$APRO&status=booked" "" -H "$STAFF"
body_has '"total":2,' "booking: two booked, not five"
req GET "$AV&date=$NEXT_MON" "" -H "$STAFF"
count_is 0 "booking: the day is full"

# The body, every failing member in one 400
req POST /appointments '{}' -H "$STAFF"
status_is 400 "booking: an empty body"
body_has '"field":"professionalId","code":"required"' "booking: professionalId required"
body_has '"field":"startsAt","code":"required"' "booking: startsAt required, in the same answer"
book nothing nothing nothing "${NEXT_MON}T12:00:00Z"
status_is 400 "booking: ids the tenant doesn't have"
body_has '"field":"professionalId","code":"unknown_professional"' "booking: unknown_professional"
body_has '"field":"serviceId","code":"unknown_service"' "booking: unknown_service"
body_has '"field":"customerId","code":"unknown_customer"' "booking: unknown_customer"
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T12:00:00"
status_is 400 "booking: an instant without its zone"
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T12:00:30Z"
status_is 400 "booking: seconds"
body_has '"code":"not_whole_minutes"' "booking: not_whole_minutes"
req POST /appointments "{\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"customerId\":\"$CUST\",\"startsAt\":\"${NEXT_MON}T12:00:00Z\"}" -H "$OTHER"
status_is 400 "booking: other tenant can't use demo's rows"
body_has '"code":"unknown_professional"' "booking: demo's professional unknown to other"
req PATCH "/services/$ASVC" '{"active":false}' -H "$OWNER"
book "$APRO" "$ASVC" "$CUST" "${NEXT_MON}T13:45:00Z"
status_is 409 "booking: an inactive service"
body_has '"code":"service_inactive"' "booking: service_inactive"
req PATCH "/services/$ASVC" '{"active":true}' -H "$OWNER"

# Reading
req GET "/appointments/$APPT" "" -H "$STAFF"
status_is 200 "booking: one"
body_has "\"id\":\"$APPT\"" "booking: by id"
req GET "/appointments/$APPT" "" -H "$OTHER"
status_is 404 "booking: other tenant can't read demo's"
req GET "/appointments/nothing" "" -H "$STAFF"
status_is 404 "booking: an unknown id"
req GET "/appointments?from=${NEXT_MON}T13:00:00Z&to=${NEXT_MON}T13:30:00Z" "" -H "$STAFF"
body_has '"total":0,' "booking: from/to between the two"
req GET "/appointments?from=${NEXT_MON}T12:59:00Z&to=${NEXT_MON}T13:31:00Z" "" -H "$STAFF"
body_has '"total":2,' "booking: from/to overlapping both"
req GET "/appointments?orderBy=-startsAt&limit=1" "" -H "$STAFF"
body_has "\"items\":[{\"id\":\"" "booking: a page of one"
body_has "\"startsAt\":\"${NEXT_MON}T13:30:00Z\"" "booking: the latest first"
req GET "/appointments?status=lost" "" -H "$STAFF"
status_is 400 "booking: a status that isn't one"
req GET "/appointments" "" -H "$OTHER"
body_has '"total":0,' "booking: other tenant has none"

# What an appointment names can't be deleted
req DELETE "/services/$ASVC" "" -H "$OWNER"
status_is 409 "booking: a booked service can't be deleted"
req DELETE "/customers/$CUST" "" -H "$OWNER"
status_is 409 "booking: a customer with appointments can't be deleted"

# The slot lock (Agenda.Locks), when the runner gives a Redis: REDIS_CMD runs
# one command (tools/redis_cmd.py). Last: it shuts Redis down.
if [ -n "$REDIS_CMD" ]; then
  MON3="$(date -u -d "$NEXT_MON + 7 days" +%F)"
  KEY="agenda:lock:demo:$APRO:$(date -u -d "${MON3}T12:00:00Z" +%s)"
  $REDIS_CMD SET "$KEY" someone-else PX 60000 >/dev/null
  book "$APRO" "$ASVC" "$CUST" "${MON3}T12:00:00Z"
  status_is 409 "lock: a slot another request holds"
  body_has 'Another request is booking this slot.' "lock: answered before the database"
  [ "$($REDIS_CMD GET "$KEY")" = someone-else ] && ok || fail "lock: the other request's lock kept"
  $REDIS_CMD DEL "$KEY" >/dev/null
  book "$APRO" "$ASVC" "$CUST" "${MON3}T12:00:00Z"
  status_is 201 "lock: free once the other released it"
  [ "$($REDIS_CMD EXISTS "$KEY")" = 0 ] && ok || fail "lock: released after the booking"

  # Redis down: the booking goes on to the database, which still decides.
  $REDIS_CMD SHUTDOWN NOSAVE >/dev/null 2>&1 || true
  sleep 1
  book "$APRO" "$ASVC" "$CUST" "${MON3}T13:15:00Z"
  status_is 201 "lock: Redis down, the database books"
  book "$APRO" "$ASVC" "$CUST" "${MON3}T13:15:00Z"
  status_is 409 "lock: Redis down, the database refuses the same slot"
  body_has '"code":"slot_unavailable"' "lock: the database's slot_unavailable"
  if [ -n "$SERVER_LOG" ]; then
    grep -q "slot lock unavailable (acquire agenda:lock:demo:$APRO:" "$SERVER_LOG" && ok \
      || fail "lock: Redis down logged with its key"
  fi
else
  echo "skipped: no Redis for the slot lock (REDIS_CMD)"
fi
