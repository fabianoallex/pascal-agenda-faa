#!/bin/sh
# The public routes over HTTP (docs/design.md, M3), sourced by
# tools/http_scenarios.sh after tools/http_scenarios_idempotency.sh: no token,
# the tenant from the path's slug; the availability's professional ($APRO:
# Mondays 09:00-12:00 in America/Sao_Paulo, 12:00-15:00Z) and service ($ASVC:
# 60 minutes plus 15), on a Monday nobody booked yet. Last: it fills this
# address's /public/ window (PUBLIC_RATE_LIMIT, 60).
# req keeps its arguments in the globals M, P and B: none of those names here.

MON7="$(date -u -d "$NEXT_MON + 35 days" +%F)"
PUB=/public/demo
pub_book() { req POST "$PUB/appointments" "$2" -H "Idempotency-Key: $1"; }
book_body() {
  echo "{\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"startsAt\":\"${MON7}T$1:00Z\",$2}"
}
# The body without its requestId, so two 404s can be compared.
plain_body() { sed 's/,"requestId":"[^"]*"//' "$T/body"; }
customer_of() {
  req GET "/appointments/$1" "" -H "$STAFF"
  sed -n 's/.*"customerId":"\([0-9a-f]*\)".*/\1/p' "$T/body"
}

# --- the tenant from the slug; no token
req GET "$PUB/services" ""
status_is 200 "public: services with no token"
body_has "\"id\":\"$ASVC\",\"name\":\"Tintura\",\"durationMinutes\":60,\"price\":120" \
  "public: a service's id, name, duration and price"
body_lacks '"bufferMinutes"' "public: no buffer"
body_lacks '"active"' "public: no active flag"
req POST /services '{"name":"Hidden Service","durationMinutes":30}' -H "$OWNER"
HIDDEN="$(id_of)"
req PATCH "/services/$HIDDEN" '{"active":false}' -H "$OWNER"
status_is 200 "public: a service made inactive"
req GET "$PUB/services?limit=100" ""
body_lacks "$HIDDEN" "public: an inactive service isn't listed"
# An unknown query member is ignored (THorseQueryParams), so asking for the
# inactive ones still gets the active ones only.
req GET "$PUB/services?active=false&limit=100" ""
status_is 200 "public: active=false is not a filter here"
body_lacks "$HIDDEN" "public: asking for the inactive ones doesn't show them"
req GET "$PUB/services" "" -H "Authorization: Bearer not-a-token"
status_is 200 "public: a token, even a bad one, is not read"
req GET "$PUB/professionals?search=elisa" ""
status_is 200 "public: professionals"
body_has "\"id\":\"$APRO\",\"name\":\"Elisa Prado\"}" "public: a professional's id and name, nothing else"
req GET "/public/other/services" ""
body_lacks "$ASVC" "public: another tenant's list has none of demo's"

req GET /public/nowhere/services ""
status_is 404 "public: an unknown slug"
UNKNOWN_404="$(plain_body)"
req GET /public/frozen/services ""
status_is 404 "public: a suspended tenant is not found either"
[ "$(plain_body)" = "$UNKNOWN_404" ] && ok || fail "public: suspended and unknown, one body ($(plain_body) / $UNKNOWN_404)"
req GET /public/DEMO/services ""
status_is 404 "public: a slug in upper case"
[ "$(plain_body)" = "$UNKNOWN_404" ] && ok || fail "public: not an id, the same body"
req GET /publicity/demo ""
status_is 401 "public: /publicity is not under /public"

# --- free slots, as the staff route answers them
req GET "$PUB/professionals/$APRO/availability?service=$ASVC&date=$MON7" ""
status_is 200 "public: free slots"
body_has "\"slots\":[{\"startsAt\":\"${MON7}T12:00:00Z\"" "public: the day's first slot"

# --- booking: the key
pub_book "" "$(book_body 12:00 '"name":"Carla Dias","phone":"+55 11 98765-4321"')"
status_is 400 "public booking: no Idempotency-Key"
body_has '"code":"idempotency_key_required"' "public booking: idempotency_key_required"
pub_book short-key-15chr "$(book_body 12:00 '"name":"Carla Dias","phone":"+55 11 98765-4321"')"
status_is 400 "public booking: a key of 15 characters"
body_has '"code":"invalid_idempotency_key"' "public booking: invalid_idempotency_key"

# The body: the booking's members first (no customer is created), then a contact.
req GET "/customers?search=zoe" "" -H "$STAFF"
body_has '"total":0,' "public booking: no customer Zoe yet"
pub_book public-key-00000001 '{"name":"Zoe Alves","phone":"+55 11 91111-1111"}'
status_is 400 "public booking: no professional, service or start"
body_has '"field":"professionalId","code":"required"' "public booking: names the member"
req GET "/customers?search=zoe" "" -H "$STAFF"
body_has '"total":0,' "public booking: a 400 for the booking's members creates no customer"
pub_book public-key-00000002 "$(book_body 12:00 '"name":"Zoe Alves"')"
status_is 400 "public booking: no phone and no email"
body_has '"field":"phone","code":"contact_required"' "public booking: contact_required"

# --- a booking, and its retry
pub_book public-key-00000003 "$(book_body 12:00 '"name":"Carla Dias","phone":"+55 11 98765-4321"')"
status_is 201 "public booking"
header_is Cache-Control 'no-store' "public booking: the link isn't cached"
body_has "\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"startsAt\":\"${MON7}T12:00:00Z\",\"endsAt\":\"${MON7}T13:00:00Z\",\"status\":\"booked\"" \
  "public booking: as stored"
body_lacks '"customerId"' "public booking: no customer in the answer"
body_lacks '"version"' "public booking: no version"
body_lacks '98765' "public booking: no phone in the answer"
PUB_ID="$(id_of)"
PUB_URL="$(field url)"
PUB_CANCEL="$(field cancelUrl)"
case "$PUB_URL" in "$PUB/appointments/$PUB_ID?exp="*"&sig="*) ok ;; *) fail "public booking: url '$PUB_URL'" ;; esac
[ "$PUB_CANCEL" = "$(echo "$PUB_URL" | sed 's/?/\/cancel?/')" ] && ok || fail "public booking: cancelUrl '$PUB_CANCEL'"
FIRST_PUB_BODY="$(cat "$T/body")"
pub_book public-key-00000003 "$(book_body 12:00 '"name":"Carla Dias","phone":"+55 11 98765-4321"')"
status_is 201 "public booking: a retry"
body_is "$FIRST_PUB_BODY" "public booking: the retry gets the same appointment and link"
header_is Idempotent-Replayed 'true' "public booking: a replay"
header_is Cache-Control 'no-store' "public booking: the replay isn't cached either"
pub_book public-key-00000004 "$(book_body 12:00 '"name":"Carla Dias","phone":"+55 11 98765-4321"')"
status_is 409 "public booking: the same slot with a new key"
body_has '"code":"slot_unavailable"' "public booking: slot_unavailable"

# --- the returning customer: phone (or email) and name
CARLA="$(customer_of "$PUB_ID")"
[ -n "$CARLA" ] && ok || fail "public booking: staff sees the customer"
pub_book public-key-00000005 "$(book_body 13:15 '"name":"  carla   DIAS ","phone":"+55 (11) 98765-4321"')"
status_is 201 "public booking: the same customer again, written differently"
SECOND_ID="$(id_of)"
[ "$(customer_of "$SECOND_ID")" = "$CARLA" ] && ok || fail "public booking: the same phone and name is the same customer"
req GET "/customers/$CARLA" "" -H "$STAFF"
body_has '"name":"Carla Dias"' "public booking: a customer found isn't changed"
MON9="$(date -u -d "$MON7 + 14 days" +%F)"
pub_book public-key-00000006 "$(book_body 12:00 '"name":"Davi Dias","phone":"+55 11 98765-4321","email":"davi@example.com"' | sed "s/$MON7/$MON9/")"
status_is 201 "public booking: the same phone, another name"
[ "$(customer_of "$(id_of)")" != "$CARLA" ] && ok || fail "public booking: another name is another customer (a family's phone)"
MON8="$(date -u -d "$MON7 + 7 days" +%F)"
pub_book public-key-00000007 "$(book_body 12:00 '"name":"Eva Lima","email":"EVA@Example.com"' | sed "s/$MON7/$MON8/")"
status_is 201 "public booking: an email only"
EVA="$(customer_of "$(id_of)")"
pub_book public-key-00000008 "$(book_body 13:15 '"name":"Eva Lima","email":"eva@example.com"' | sed "s/$MON7/$MON8/")"
status_is 201 "public booking: the same email, another case"
[ "$(customer_of "$(id_of)")" = "$EVA" ] && ok || fail "public booking: the same email and name is the same customer"

# --- the link
req GET "$PUB_URL" ""
status_is 200 "link: shows the appointment"
body_has "\"id\":\"$PUB_ID\"" "link: that appointment"
body_has '"status":"booked"' "link: its status"
body_lacks '"customerId"' "link: no customer"
header_is Cache-Control 'no-store' "link: not cached"
EXP_OF_URL="$(echo "$PUB_URL" | sed 's/.*exp=\([0-9]*\).*/\1/')"
[ "$EXP_OF_URL" = "$(date -u -d "${MON7}T12:00:00Z" +%s)" ] && ok || fail "link: exp is the start ($EXP_OF_URL)"
SIG="$(echo "$PUB_URL" | sed 's/.*sig=//')"
# A character in the middle (every one of its 6 bits is signature).
MID="$(printf '%s' "$SIG" | cut -c10)"
if [ "$MID" = A ]; then NEWMID=B; else NEWMID=A; fi
req GET "$PUB/appointments/$PUB_ID?exp=$EXP_OF_URL&sig=$(printf '%s' "$SIG" | cut -c1-9)$NEWMID$(printf '%s' "$SIG" | cut -c11-)" ""
status_is 403 "link: a signature changed"
body_has '"code":"invalid_link"' "link: invalid_link"
# The last character carries 4 bits: the next one in the alphabet decodes to
# the same bytes. Refused all the same (found on Linux: "...A" as "...B").
LAST="$(printf '%s' "$SIG" | tail -c 1)"
ALIAS="$(printf '%s' "$LAST" | awk '{ a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"; print substr(a, index(a, $0) + 1, 1) }')"
req GET "$PUB/appointments/$PUB_ID?exp=$EXP_OF_URL&sig=${SIG%?}$ALIAS" ""
status_is 403 "link: the same bytes spelled another way"
req GET "$PUB/appointments/$PUB_ID?exp=$((EXP_OF_URL + 86400))&sig=$SIG" ""
status_is 403 "link: the expiry pushed later"
req GET "$PUB/appointments/$PUB_ID?exp=$EXP_OF_URL" ""
status_is 403 "link: no signature"
req GET "$PUB/appointments/$PUB_ID?exp=soon&sig=$SIG" ""
status_is 403 "link: an expiry that isn't a number"
req GET "$PUB/appointments/$SECOND_ID?exp=$EXP_OF_URL&sig=$SIG" ""
status_is 403 "link: another appointment with this signature"
req GET "/public/other/appointments/$PUB_ID?exp=$EXP_OF_URL&sig=$SIG" ""
status_is 403 "link: on another tenant's path"
req GET "/public/nowhere/appointments/$PUB_ID?exp=$EXP_OF_URL&sig=$SIG" ""
status_is 404 "link: on an unknown tenant's path"
if [ -n "$PY" ]; then
  # Signed outside the API, with DEV_MODE's key: the format is the one the
  # design names, and a good link past its expiry is told so.
  pysig() {
    "$PY" -I -c '
import base64, hashlib, hmac, sys
key = b"development-link-signing-key-123"
scope_key = hmac.new(key, ("agenda-link-key|" + sys.argv[1]).encode(), hashlib.sha256).digest()
text = "agenda-link|v1|%s|appointment|%s|%s" % (sys.argv[1], sys.argv[2], sys.argv[3])
mac = hmac.new(scope_key, text.encode(), hashlib.sha256).digest()
print("dev." + base64.urlsafe_b64encode(mac).decode().rstrip("="))' "$@"
  }
  [ "$(pysig demo "$PUB_ID" "$EXP_OF_URL")" = "$SIG" ] && ok || fail "link: the signature as the design writes it"
  req GET "$PUB/appointments/$PUB_ID?exp=1000&sig=$(pysig demo "$PUB_ID" 1000)" ""
  status_is 410 "link: a good link past its expiry"
  body_has '"code":"link_expired"' "link: link_expired"
else
  echo "skipped: no Python for the links signed outside the API"
fi

# --- cancelling by the link: no If-Match, twice is fine
req POST "$PUB_CANCEL" ""
status_is 200 "link: cancels"
body_has '"status":"cancelled"' "link: cancelled"
req POST "$PUB_CANCEL" ""
status_is 200 "link: cancelling again answers the same"
body_has '"status":"cancelled"' "link: still cancelled"
req GET "/appointments/$PUB_ID" "" -H "$STAFF"
body_has '"status":"cancelled","version":2' "link: staff sees it cancelled, one change"
req GET "$PUB/professionals/$APRO/availability?service=$ASVC&date=$MON7" ""
body_has "\"slots\":[{\"startsAt\":\"${MON7}T12:00:00Z\"" "link: the slot is free again"
# A staff change in between doesn't stop the link (no ETag needed).
pub_book public-key-00000009 "$(book_body 12:00 '"name":"Carla Dias","phone":"+55 11 98765-4321"')"
status_is 201 "public booking: the freed slot"
MOVED_ID="$(id_of)"
MOVED_CANCEL="$(field cancelUrl)"
req PATCH "/appointments/$MOVED_ID" '{"status":"confirmed"}' -H "$STAFF" -H 'If-Match: "1"'
status_is 200 "link: staff confirms it"
req POST "$MOVED_CANCEL" ""
status_is 200 "link: a confirmed appointment cancels"
body_has '"status":"cancelled"' "link: from confirmed to cancelled"

# --- the access log names the slug's tenant
if [ -n "$SERVER_LOG" ]; then
  grep -F "$PUB/services" "$SERVER_LOG" | grep -qF '"tenant.id":"demo"' && ok \
    || fail "public: the access log has the slug's tenant"
fi

# --- the rate limit by client address (last: it fills this address's window)
LIMITED=0
I=0
while [ $I -lt 80 ]; do
  I=$((I + 1))
  req GET /public/nowhere/services ""
  if [ "$(cat "$T/status")" = 429 ]; then LIMITED=1; break; fi
done
[ $LIMITED = 1 ] && ok || fail "public: the rate limit never answered 429 in 80 requests"
header_is X-RateLimit-Limit 60 "public: the limit"
req GET "$PUB/services" ""
status_is 429 "public: a known slug shares the address's window"
req GET /services "" -H "$STAFF"
status_is 200 "public: the staff routes keep their own window"
