#!/bin/sh
# One day of the agenda over HTTP (GET /agenda/day, docs/design.md, M5
# decision 3), sourced by tools/http_scenarios.sh after
# tools/http_scenarios_idempotency.sh: that professional ($APRO, "Elisa
# Prado": Mondays 09:00-12:00 in America/Sao_Paulo, 12:00-15:00Z), service
# ($ASVC, "Tintura": 60 minutes plus 15) and customer ($CUST, "Bia Costa"),
# on a Monday nobody booked yet ($DAY). tools/http_scenarios_mcp.sh uses the
# same day after it.
# req keeps its arguments in the globals M, P and B: none of those names here.

DAY="$(date -u -d "$NEXT_MON + 56 days" +%F)"
day() { req GET "/agenda/day?date=$1$2" "" -H "${3:-$STAFF}"; }

book "$APRO" "$ASVC" "$CUST" "${DAY}T13:30:00Z"
status_is 201 "day: a booking at 10:30 local"
DA2="$(id_of)"
book "$APRO" "$ASVC" "$CUST" "${DAY}T12:00:00Z"
status_is 201 "day: a booking at 09:00 local"
DA1="$(id_of)"
req POST "/appointments/$DA1/cancel" "" -H "$STAFF" -H 'If-Match: "1"'
status_is 200 "day: the 09:00 one cancelled"

day "$DAY"
status_is 200 "day: read"
body_has "\"date\":\"$DAY\",\"timeZone\":\"America/Sao_Paulo\",\"appointments\":[{\"id\":\"$DA1\"" \
  "day: the date, the zone, by start (the cancelled one first)"
body_has "\"id\":\"$DA1\",\"startsAt\":\"${DAY}T12:00:00Z\",\"endsAt\":\"${DAY}T13:00:00Z\",\"localStart\":\"${DAY}T09:00:00-03:00\",\"localEnd\":\"${DAY}T10:00:00-03:00\",\"status\":\"cancelled\",\"version\":2" \
  "day: UTC and the tenant's clock, any status, the version"
body_has "\"professionalId\":\"$APRO\",\"professionalName\":\"Elisa Prado\",\"serviceId\":\"$ASVC\",\"serviceName\":\"Tintura\",\"customerId\":\"$CUST\",\"customerName\":\"Bia Costa\"" \
  "day: the names next to the ids"
body_has "\"id\":\"$DA2\",\"startsAt\":\"${DAY}T13:30:00Z\"" "day: the 10:30 one"
[ "$(grep -o '"id":"' "$T/body" | wc -l | tr -d ' ')" = 2 ] && ok || fail "day: two appointments ($(cat "$T/body"))"

day "$DAY" "&professional=$APRO"
status_is 200 "day: one professional"
body_has "\"id\":\"$DA2\"" "day: that professional's"
day "$DAY" "&professional=$NPRO"
status_is 200 "day: a professional with nothing that day"
body_has '"appointments":[]' "day: an empty day"
day "$DAY" "&professional=nothing"
status_is 404 "day: an unknown professional"
day "$(date -u -d "$DAY + 1 day" +%F)"
body_has '"appointments":[]' "day: the next day has none"

req GET "/agenda/day" "" -H "$STAFF"
status_is 400 "day: no date"
day "2026-13-01"
status_is 400 "day: not a date"
body_has '"code":"invalid_date"' "day: invalid_date"
day "$(date -u -d '+400 days' +%F)"
status_is 400 "day: too far"
body_has '"code":"date_out_of_range"' "day: date_out_of_range"

day "$DAY" "" "$OTHER"
status_is 200 "day: another tenant"
body_has '"appointments":[]' "day: another tenant sees none of demo's"
req GET "/agenda/day?date=$DAY" ""
status_is 401 "day: no token"
