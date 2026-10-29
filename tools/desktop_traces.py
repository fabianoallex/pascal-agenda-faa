"""Checks the desktop client's spans (decision 9 of "M6: design") in what
tools/otlp_sink.py kept from AgendaDesktopSmoke, for tools/test_http.sh.

    python tools/desktop_traces.py <sink file> <api log>

- Every user action the smoke goes through has its span: a root span, with
  one child "run" (the task on the pool).
- Every call made inside a task is a client span whose parent is a "run".
- Every client span's trace is in the api's log (its "trace_id"): the
  traceparent sent was the one the server used, so the server's side joins
  the desktop's trace.

Prints one summary line; exits 1 with the failures.
"""
import json
import sys

SERVICE = "agenda-desktop"
ACTIONS = ["login", "day.open", "day.load", "booking.open", "booking.slots", "booking.book",
           "day.confirmed", "move.slots", "move.move", "customers.list", "customer.save",
           "day.cancel"]
KIND_CLIENT = 3


def service_of(resource):
    for attribute in resource.get("attributes", []):
        if attribute.get("key") == "service.name":
            return attribute.get("value", {}).get("stringValue", "?")
    return "?"


def read_spans(path):
    spans = []
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            line = line.strip()
            if not line:
                continue
            for resource_spans in json.loads(line).get("resourceSpans", []):
                if service_of(resource_spans.get("resource", {})) != SERVICE:
                    continue
                for scope in resource_spans.get("scopeSpans", []):
                    spans.extend(scope.get("spans", []))
    return spans


def read_api_traces(path):
    traces = set()
    with open(path, encoding="utf-8", errors="replace") as lines:
        for line in lines:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                trace = json.loads(line).get("trace_id", "")
            except ValueError:
                continue
            if trace:
                traces.add(trace.lower())
    return traces


def main():
    spans = read_spans(sys.argv[1])
    api_traces = read_api_traces(sys.argv[2])
    by_id = {span["spanId"]: span for span in spans}
    failures = []

    roots = [s for s in spans if not s.get("parentSpanId")]
    runs = [s for s in spans if s["name"] == "run"]
    calls = [s for s in spans if s.get("kind") == KIND_CLIENT]
    names = {s["name"] for s in roots}
    for action in ACTIONS:
        if action not in names:
            failures.append("no span for the action %s" % action)
    for run in runs:
        parent = by_id.get(run.get("parentSpanId", ""))
        if parent is None or parent.get("parentSpanId"):
            failures.append("a run span (%s) without its action" % run["spanId"])
        elif parent["traceId"] != run["traceId"]:
            failures.append("a run span in another trace than its action")
    actions = [s for s in roots if s.get("kind") != KIND_CLIENT]
    for action in actions:
        children = [r for r in runs if r.get("parentSpanId") == action["spanId"]]
        if len(children) != 1:
            failures.append("the action %s has %d run spans" % (action["name"], len(children)))
    inside = 0
    for call in calls:
        parent = by_id.get(call.get("parentSpanId", ""))
        if call.get("parentSpanId"):
            inside += 1
            if parent is None or parent["name"] != "run":
                failures.append("the call %s isn't under a run span" % call["name"])
        if call["traceId"].lower() not in api_traces:
            failures.append("the call %s (trace %s) isn't in the api's log" %
                            (call["name"], call["traceId"]))

    print("desktop traces: %d spans, %d actions, %d calls (%d inside an action), all in the "
          "api's log" % (len(spans), len(actions), len(calls), inside)
          if not failures else "desktop traces: %d failures" % len(failures))
    for failure in failures[:30]:
        print("FAIL: " + failure)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
