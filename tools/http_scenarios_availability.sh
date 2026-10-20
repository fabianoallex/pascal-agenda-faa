#!/bin/sh
# Free slots over HTTP, sourced by tools/http_scenarios.sh after
# tools/http_scenarios_schedule.sh (it uses the catalog file's helpers,
# $OWNER, $STAFF and $OTHER). No logins here.
#
# Dates are computed from today (GNU date, as on Git Bash and in the Linux
# image), so the checks don't expire: a Monday a week or more ahead for
# tenant demo (America/Sao_Paulo, -03:00 all year), and for tenant other
# (Europe/Lisbon) the next last Sunday of March (clocks 01:00 -> 02:00) and
# of October (02:00 -> 01:00).

# The next last Sunday of month $1 (03 or 10) after today, YYYY-MM-DD.
next_last_sunday() {
  Y="$(date -u +%Y)"
  for YY in "$Y" $((Y + 1)); do
    LAST="$YY-$1-31"
    D="$(date -u -d "$LAST - $(( $(date -u -d "$LAST" +%u) % 7 )) days" +%F)"
    if [ "$D" \> "$(date -u -d tomorrow +%F)" ]; then echo "$D"; return; fi
  done
}
slots_count() { grep -o '"local":' "$T/body" | wc -l | tr -d ' '; }
count_is() { [ "$(slots_count)" = "$1" ] && ok || fail "$2: $(slots_count) slots, expected $1 (body: $(cat "$T/body"))"; }

MON="$(date -u -d "next monday + 7 days" +%F)"
NEXT_MON="$(date -u -d "$MON + 7 days" +%F)"
SPRING="$(next_last_sunday 03)"
FALL="$(next_last_sunday 10)"
SAT_BEFORE_FALL="$(date -u -d "$FALL - 1 day" +%F)"

req POST /professionals '{"name":"Elisa Prado"}' -H "$OWNER"
status_is 201 "availability: a professional"
APRO="$(id_of)"
req POST /services '{"name":"Tintura","durationMinutes":60,"bufferMinutes":15,"price":120}' -H "$OWNER"
status_is 201 "availability: a service of 60 minutes plus 15"
ASVC="$(id_of)"
AV="/professionals/$APRO/availability?service=$ASVC"

req GET "$AV&date=$MON" "" -H "$STAFF"
status_is 200 "availability: staff reads"
body_is "{\"professional\":\"$APRO\",\"service\":\"$ASVC\",\"timeZone\":\"America/Sao_Paulo\",\"slots\":[]}" \
  "availability: no hours, no slots, the tenant's zone"

req PUT "/professionals/$APRO/working-hours" '{"intervals":[{"weekday":1,"from":"09:00","to":"12:00"}]}' -H "$OWNER"
status_is 200 "availability: Mondays 09:00-12:00"
req GET "$AV&date=$MON" "" -H "$STAFF"
status_is 200 "availability: a Monday"
count_is 9 "availability: 09:00 to 11:00 every 15 minutes"
body_has "\"slots\":[{\"startsAt\":\"${MON}T12:00:00Z\",\"endsAt\":\"${MON}T13:00:00Z\",\"local\":\"${MON}T09:00:00-03:00\"}" \
  "availability: the first, UTC and the tenant's clock"
body_has "\"local\":\"${MON}T11:00:00-03:00\"}]" "availability: the last ends at closing"
req GET "$AV&date=$(date -u -d "$MON + 1 day" +%F)" "" -H "$STAFF"
body_has '"slots":[]' "availability: no hours on Tuesday"

# Time off 10:00-10:30: a start before 10:30 would run into it with its buffer.
req POST "/professionals/$APRO/time-off" "{\"startsAt\":\"${MON}T10:00:00-03:00\",\"endsAt\":\"${MON}T10:30:00-03:00\"}" -H "$OWNER"
status_is 201 "availability: time off 10:00-10:30"
req GET "$AV&date=$MON" "" -H "$STAFF"
count_is 3 "availability: 10:30, 10:45, 11:00 around the time off"
body_has "\"slots\":[{\"startsAt\":\"${MON}T13:30:00Z\"" "availability: the first after the time off"
req GET "$AV&date=$MON&days=7" "" -H "$STAFF"
count_is 3 "availability: seven days, one Monday"
req GET "$AV&date=$MON&days=8" "" -H "$STAFF"
count_is 12 "availability: eight days, the next Monday whole"
body_has "\"local\":\"${NEXT_MON}T09:00:00-03:00\"" "availability: the next Monday's first"

# The query, every failing member in one 400
req GET "/professionals/$APRO/availability" "" -H "$STAFF"
status_is 400 "availability: neither service nor date"
body_has '"code":"invalid_fields"' "availability: the fields' code"
body_has '"field":"service","code":"required"' "availability: service required"
body_has '"field":"date","code":"required"' "availability: date required, in the same answer"
req GET "$AV&date=2026-02-30" "" -H "$STAFF"
status_is 400 "availability: no such date"
body_has '"field":"date","code":"invalid_date"' "availability: invalid_date"
req GET "$AV&date=$MON&days=0" "" -H "$STAFF"
status_is 400 "availability: days 0"
body_has '"field":"days"' "availability: days, named"
req GET "$AV&date=$MON&days=15" "" -H "$STAFF"
status_is 400 "availability: days 15"
req GET "$AV&date=$MON&days=x" "" -H "$STAFF"
status_is 400 "availability: days not a number"
req GET "$AV&date=$(date -u -d "today + 400 days" +%F)" "" -H "$STAFF"
status_is 400 "availability: more than 366 days ahead"
body_has '"code":"date_out_of_range"' "availability: date_out_of_range"
req GET "$AV&date=$(date -u -d "today - 10 days" +%F)" "" -H "$STAFF"
status_is 200 "availability: a past day answers"
body_has '"slots":[]' "availability: no slot before now"

req GET "/professionals/nothing/availability?service=$ASVC&date=$MON" "" -H "$STAFF"
status_is 404 "availability: an unknown professional"
req GET "/professionals/$APRO/availability?service=nothing&date=$MON" "" -H "$STAFF"
status_is 404 "availability: an unknown service"
req GET "$AV&date=$MON" "" -H "$OTHER"
status_is 404 "availability: other tenant can't read demo's"

req PATCH "/services/$ASVC" '{"active":false}' -H "$OWNER"
req GET "$AV&date=$MON" "" -H "$STAFF"
status_is 409 "availability: an inactive service"
body_has '"code":"service_inactive"' "availability: service_inactive"
req PATCH "/services/$ASVC" '{"active":true}' -H "$OWNER"
req PATCH "/professionals/$APRO" '{"active":false}' -H "$OWNER"
req GET "$AV&date=$MON" "" -H "$STAFF"
status_is 409 "availability: an inactive professional"
body_has '"code":"professional_inactive"' "availability: professional_inactive"
req PATCH "/professionals/$APRO" '{"active":true}' -H "$OWNER"
req GET "$AV&date=$MON" "" -H "$STAFF"
count_is 3 "availability: active again"

# Daylight saving: tenant other (Europe/Lisbon), Sundays 00:00-03:00, a
# 60-minute service with no buffer.
req POST /professionals '{"name":"Rui Lobo"}' -H "$OTHER"
LPRO="$(id_of)"
req POST /services '{"name":"Massagem","durationMinutes":60,"price":40}' -H "$OTHER"
LSVC="$(id_of)"
req PUT "/professionals/$LPRO/working-hours" '{"intervals":[{"weekday":7,"from":"00:00","to":"03:00"}]}' -H "$OTHER"
status_is 200 "dst: Sundays 00:00-03:00 in Lisbon"
LAV="/professionals/$LPRO/availability?service=$LSVC"

# Clocks go 01:00 -> 02:00: two real hours, the starts 00:00 to 00:45, then
# 02:00 (01:00Z).
req GET "$LAV&date=$SPRING" "" -H "$OTHER"
status_is 200 "dst: the spring Sunday ($SPRING)"
body_has '"timeZone":"Europe/Lisbon"' "dst: the tenant's zone"
count_is 5 "dst: three hours on the clock, two real ones"
body_has "\"local\":\"${SPRING}T00:45:00+00:00\"},{\"startsAt\":\"${SPRING}T01:00:00Z\",\"endsAt\":\"${SPRING}T02:00:00Z\",\"local\":\"${SPRING}T02:00:00+01:00\"}]" \
  "dst: 00:45 WET, then 02:00 WEST"

# Clocks go 02:00 -> 01:00: four real hours from 23:00Z the day before.
req GET "$LAV&date=$FALL" "" -H "$OTHER"
status_is 200 "dst: the autumn Sunday ($FALL)"
count_is 13 "dst: three hours on the clock, four real ones"
body_has "\"slots\":[{\"startsAt\":\"${SAT_BEFORE_FALL}T23:00:00Z\",\"endsAt\":\"${FALL}T00:00:00Z\",\"local\":\"${FALL}T00:00:00+01:00\"}" \
  "dst: the Sunday starts on Saturday in UTC"
body_has "\"local\":\"${FALL}T01:00:00+01:00\"" "dst: 01:00 WEST"
body_has "\"local\":\"${FALL}T01:00:00+00:00\"" "dst: 01:00 WET, an hour later"
body_has "\"local\":\"${FALL}T02:00:00+00:00\"}]" "dst: the last at 02:00 WET"
