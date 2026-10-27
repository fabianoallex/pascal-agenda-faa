#!/bin/sh
# The api as MCP tools over HTTP (POST /mcp, docs/design.md, M5 decisions 1
# and 2), sourced by tools/http_scenarios.sh after tools/http_scenarios_day.sh:
# its day ($DAY: $DA1 cancelled at 09:00 local, $DA2 booked at 10:30, both
# Elisa Prado's) and the same helpers. Revision 2026-07-28, no session: each
# request carries its version in _meta and in the headers
# (pascal-api-infra-faa's docs/guide/mcp.md). tools/mcp_result.py reads the
# answers.
# req keeps its arguments in the globals M, P and B: none of those names here.

MCP_VERSION=2026-07-28
MCP_META="\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"$MCP_VERSION\",\"io.modelcontextprotocol/clientCapabilities\":{}}"
MCP_ID=0
# The caller's header: $STAFF when left out, none when given empty.
auth_of() { if [ $# -ge 1 ]; then echo "${1:-X-No-Token: 1}"; else echo "$STAFF"; fi; }
# mcp_list [auth header]
mcp_list() {
  MCP_ID=$((MCP_ID + 1))
  req POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":$MCP_ID,\"method\":\"tools/list\",\"params\":{$MCP_META}}" \
    -H "MCP-Protocol-Version: $MCP_VERSION" -H 'Mcp-Method: tools/list' -H "$(auth_of "$@")"
}
# mcp_call TOOL ARGUMENTS-JSON [auth header] -> $T/status, $T/body; $T/call.txt
mcp_call() {
  MCP_ID=$((MCP_ID + 1))
  if [ $# -ge 3 ]; then MCP_AUTH="$(auth_of "$3")"; else MCP_AUTH="$STAFF"; fi
  req POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":$MCP_ID,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2,$MCP_META}}" \
    -H "MCP-Protocol-Version: $MCP_VERSION" -H 'Mcp-Method: tools/call' -H "Mcp-Name: $1" \
    -H "$MCP_AUTH"
  "$PY" "$(dirname "$0")/mcp_result.py" "$T/body" call > "$T/call.txt" 2>/dev/null || : > "$T/call.txt"
}
call_ok()  { case "$(cat "$T/call.txt")" in "false	"*) ok ;; *) fail "$1: $(cat "$T/body")" ;; esac; }
call_err() { case "$(cat "$T/call.txt")" in "true	"*) ok ;; *) fail "$1: expected isError ($(cat "$T/body"))" ;; esac; }
call_has() { grep -qF -- "$1" "$T/call.txt" && ok || fail "$2: lacks $1 ($(cat "$T/call.txt"))"; }
tool_line() { awk -F '\t' -v n="$1" '$1 == n' "$T/tools.txt"; }

# --- the catalog
mcp_list
status_is 200 "mcp: tools/list"
"$PY" "$(dirname "$0")/mcp_result.py" "$T/body" tools > "$T/tools.txt" 2>/dev/null || : > "$T/tools.txt"
TOOLS="$(cut -f1 "$T/tools.txt" | sort | tr '\n' ' ')"
EXPECTED="book_appointment cancel_appointment create_customer get_appointment get_availability get_customer get_day get_me get_professional get_service get_time_off get_working_hours list_appointments list_customers list_professionals list_services list_time_off update_appointment "
[ "$TOOLS" = "$EXPECTED" ] && ok || fail "mcp: the tools: $TOOLS"
[ "$(tool_line cancel_appointment | cut -f2)" = "id,ifMatch" ] && ok \
  || fail "mcp: cancel requires id and ifMatch ($(tool_line cancel_appointment))"
[ "$(tool_line update_appointment | cut -f2)" = "id,ifMatch" ] && ok \
  || fail "mcp: update requires id and ifMatch ($(tool_line update_appointment))"
case ",$(tool_line book_appointment | cut -f3)," in *,idempotencyKey,*) ok ;; *) fail "mcp: book takes idempotencyKey ($(tool_line book_appointment))" ;; esac
case ",$(tool_line book_appointment | cut -f2)," in *,idempotencyKey,*) fail "mcp: idempotencyKey is optional" ;; *) ok ;; esac
[ "$(tool_line get_day | cut -f2)" = "date" ] && ok || fail "mcp: the day requires date ($(tool_line get_day))"
body_has 'in double quotes: the appointment' "mcp: ifMatch says what to send"
mcp_list ""
status_is 401 "mcp: no token"

# --- the day, read by a model
mcp_call get_day "{\"date\":\"$DAY\"}"
status_is 200 "mcp: get_day"
call_ok "mcp: get_day"
call_has "\"customerName\":\"Bia Costa\"" "mcp: get_day, the names"
call_has "\"id\":\"$DA2\"" "mcp: get_day, the 10:30 one"
mcp_call get_day "{\"date\":\"$DAY\",\"professional\":\"nothing\"}"
call_err "mcp: get_day, an unknown professional"
call_has "Professional not found." "mcp: the api's error, for the model"
mcp_call get_day "{\"day\":\"$DAY\"}"
call_err "mcp: an unknown argument"

# --- booking, with an Idempotency-Key the model repeats
KEY="mcp-$(date +%s)-1"
BOOK="{\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"customerId\":\"$CUST\",\"startsAt\":\"${DAY}T12:00:00Z\",\"idempotencyKey\":\"$KEY\"}"
mcp_call book_appointment "$BOOK"
call_ok "mcp: book the cancelled one's slot"
call_has '"status":"booked","version":1' "mcp: booked, version 1"
MA="$(sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p' "$T/call.txt")"
mcp_call book_appointment "$BOOK"
call_ok "mcp: the same call again"
call_has "\"id\":\"$MA\"" "mcp: the same appointment (the key replayed it)"
req GET "/agenda/day?date=$DAY" "" -H "$STAFF"
[ "$(grep -o '"status":"booked"' "$T/body" | wc -l | tr -d ' ')" = 2 ] && ok \
  || fail "mcp: one booking, not two ($(cat "$T/body"))"
mcp_call book_appointment "{\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"customerId\":\"$CUST\",\"startsAt\":\"${DAY}T12:00:00Z\"}"
call_err "mcp: the slot taken, without a key"
call_has "slot_unavailable" "mcp: slot_unavailable"
mcp_call book_appointment "{\"professionalId\":\"$APRO\",\"serviceId\":\"$ASVC\",\"customerId\":\"$CUST\",\"startsAt\":\"${DAY}T12:00:00Z\",\"idempotencyKey\":\"a\\nb\"}"
call_err "mcp: a key with a line break (not a header value)"

# --- moving and cancelling with ifMatch
mcp_call cancel_appointment "{\"id\":\"$MA\"}"
call_err "mcp: cancel without ifMatch"
call_has "ifMatch" "mcp: names the missing argument"
mcp_call cancel_appointment "{\"id\":\"$MA\",\"ifMatch\":\"\\\"9\\\"\"}"
call_err "mcp: cancel with an old version"
call_has "precondition_failed" "mcp: precondition_failed"
mcp_call update_appointment "{\"id\":\"$MA\",\"ifMatch\":\"\\\"1\\\"\",\"status\":\"confirmed\"}"
call_ok "mcp: confirm with the version read"
call_has '"status":"confirmed","version":2' "mcp: confirmed, version 2"
mcp_call cancel_appointment "{\"id\":\"$MA\",\"ifMatch\":\"\\\"2\\\"\"}"
call_ok "mcp: cancel with the version read"
call_has '"status":"cancelled","version":3' "mcp: cancelled, version 3"

# --- the caller's token goes with each call
mcp_call get_appointment "{\"id\":\"$DA2\"}" "$OTHER"
call_err "mcp: another tenant's appointment"
mcp_call get_me "{}" "$OWNER"
call_has '"role":"owner"' "mcp: the owner's token reached the api"
