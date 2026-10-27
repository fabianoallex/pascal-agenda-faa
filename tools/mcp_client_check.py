"""The api's /mcp driven by the official MCP Python SDK (mcp 2.0.0, protocol
2026-07-28), as an AI client would (docs/design.md, M5): connects, lists the
tools, reads a day, books with an idempotencyKey (twice: one booking), moves
the status and cancels with ifMatch.

    python3 tools/mcp_client_check.py <base url> <owner token> <staff token>

The owner's token prepares what the tools can't create (a professional open
every day, a service), over the api's routes; the staff token is the
client's. The tokens come from the caller: tools/test_http*.sh log in
before the scenarios fill the /auth/ window. Exit code 0 only if every check
passed; needs `pip install mcp==2.0.0`.
"""
import asyncio
import datetime
import json
import sys
import time
import urllib.request

import httpx2
from mcp.client import Client
from mcp.client.streamable_http import streamable_http_client

FAILS = []


def check(cond, label):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        FAILS.append(label)


def rest(base, token, method, path, body=None):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read() or b"null")


def text_of(result):
    return "".join(c.text for c in result.content if getattr(c, "type", "") == "text")


async def run(base, owner, staff):
    run_id = str(int(time.time()))
    pro = rest(base, owner, "POST", "/professionals", {"name": "SDK Pro " + run_id})["id"]
    week = [{"weekday": d, "from": "08:00", "to": "20:00"} for d in range(1, 8)]
    rest(base, owner, "PUT", "/professionals/%s/working-hours" % pro, {"intervals": week})
    svc = rest(base, owner, "POST", "/services",
               {"name": "SDK Service " + run_id, "durationMinutes": 30, "price": 50})["id"]
    day = (datetime.date.today() + datetime.timedelta(days=3)).isoformat()

    async with httpx2.AsyncClient(headers={"Authorization": "Bearer " + staff}) as http:
        async with Client(streamable_http_client(base + "/mcp", http_client=http)) as client:
            check(client.protocol_version == "2026-07-28",
                  "negotiated 2026-07-28 (%s)" % client.protocol_version)
            check(client.server_info is not None and client.server_info.name == "agenda-api",
                  "server info")
            tools = {t.name: t for t in (await client.list_tools()).tools}
            check({"get_day", "get_availability", "book_appointment", "update_appointment",
                   "cancel_appointment", "create_customer"} <= set(tools),
                  "the agent's tools: %s" % sorted(tools))
            check(not any(n.startswith("delete_") or "user" in n or "login" in n for n in tools),
                  "no delete, user or login tool")
            check("ifMatch" in tools["cancel_appointment"].input_schema.get("required", []),
                  "cancel requires ifMatch")

            r = await client.call_tool("create_customer", {"name": "SDK Customer " + run_id})
            check(not r.is_error, "create_customer: %s" % text_of(r))
            cust = json.loads(text_of(r))["id"]
            r = await client.call_tool("get_availability", {"id": pro, "service": svc, "date": day})
            slots = json.loads(text_of(r))["slots"]
            check(not r.is_error and len(slots) > 0, "get_availability: %d slots" % len(slots))
            start = slots[0]["startsAt"]

            book = {"professionalId": pro, "serviceId": svc, "customerId": cust,
                    "startsAt": start, "idempotencyKey": "sdk-" + run_id}
            first = await client.call_tool("book_appointment", book)
            again = await client.call_tool("book_appointment", book)
            check(not first.is_error and text_of(first) == text_of(again),
                  "book repeated with one idempotencyKey: one answer")
            appt = json.loads(text_of(first))

            r = await client.call_tool("get_day", {"date": day, "professional": pro})
            items = json.loads(text_of(r))["appointments"]
            check(not r.is_error and [a["id"] for a in items] == [appt["id"]],
                  "get_day: one appointment, not two")
            check(items and items[0]["customerName"] == "SDK Customer " + run_id
                  and items[0]["professionalName"] == "SDK Pro " + run_id,
                  "get_day: the names")

            r = await client.call_tool("update_appointment",
                                       {"id": appt["id"], "ifMatch": '"%d"' % appt["version"],
                                        "status": "confirmed"})
            moved = json.loads(text_of(r)) if not r.is_error else {}
            check(moved.get("status") == "confirmed" and moved.get("version") == appt["version"] + 1,
                  "update with the version read: %s" % text_of(r))
            r = await client.call_tool("cancel_appointment",
                                       {"id": appt["id"], "ifMatch": '"%d"' % appt["version"]})
            check(r.is_error and "precondition_failed" in text_of(r),
                  "cancel from an old version: %s" % text_of(r))
            r = await client.call_tool("cancel_appointment",
                                       {"id": appt["id"], "ifMatch": '"%d"' % moved.get("version", 0)})
            check(not r.is_error and json.loads(text_of(r))["status"] == "cancelled",
                  "cancel with the version read: %s" % text_of(r))


def main():
    base, owner, staff = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
    asyncio.run(run(base, owner, staff))
    print("mcp client: %d failed" % len(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
