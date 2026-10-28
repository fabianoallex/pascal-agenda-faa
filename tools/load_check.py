"""The checks of one load pass, and of the memory across passes, for
tools/load_test.sh (docs/design.md, M5 decision 7).

    python tools/load_check.py pass <tag> <n> <k6 summary.json> <metrics before> <metrics after> <memory MB> <k6 exit code>
    python tools/load_check.py memory <tag> <MB after pass 1> <MB after pass 2> ...

A pass fails on: k6's thresholds (any 5xx or network error, a failed check,
a double booking: k6 exits 99), the api's request count (/metrics, its
routes but /metrics and /health/*, which Prometheus and the health check
call too) differing from k6's http_reqs, the api's staff bookings booked
slot_unavailable and failed differing from k6's counts (failed: a 409
other than slot_unavailable, the database busy, which k6 counts as busy). The memory fails when the
last pass ends above the first by more than MEMORY_GROWTH and MEMORY_SLACK_MB
(the passes add data, so some growth is expected). The speed is printed, not
judged.
"""
import json
import re
import sys

MEMORY_GROWTH = 1.25
MEMORY_SLACK_MB = 16.0
SAMPLE = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{([^}]*)\})?\s+(\S+)$')
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')
SKIPPED_ROUTES = {"/metrics", "/health/live", "/health/ready"}


def samples(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = SAMPLE.match(line.strip())
            if m and not line.startswith("#"):
                labels = dict(LABEL.findall(m.group(3) or ""))
                out.append((m.group(1), labels, float(m.group(4))))
    return out


def total(path, name, **want):
    return sum(v for n, labels, v in samples(path)
               if n == name and all(labels.get(k) == w for k, w in want.items()))


def api_requests(path):
    return sum(v for n, labels, v in samples(path)
               if n == "http_server_request_duration_seconds_count"
               and labels.get("http_route") not in SKIPPED_ROUTES)


def k6_count(summary, name):
    return summary["metrics"].get(name, {}).get("count", 0)


def check_pass(tag, n, summary_path, before, after, memory, k6rc):
    fails = []
    with open(summary_path, encoding="utf-8") as f:
        summary = json.load(f)
    m = summary["metrics"]
    reqs = k6_count(summary, "http_reqs")
    failed = m.get("http_req_failed", {}).get("passes", 0)
    checks = m.get("checks", {})
    dur = m.get("http_req_duration", {})
    booked = k6_count(summary, "agenda_booked") + k6_count(summary, "agenda_race_booked")
    conflicts = k6_count(summary, "agenda_conflicts") + k6_count(summary, "agenda_race_conflicts")
    doubles = k6_count(summary, "agenda_double_bookings")
    busy = k6_count(summary, "agenda_busy")
    api_reqs = api_requests(after) - api_requests(before)
    api_booked = (total(after, "agenda_bookings_total", agenda_channel="staff",
                        agenda_booking_result="booked")
                  - total(before, "agenda_bookings_total", agenda_channel="staff",
                          agenda_booking_result="booked"))
    api_conflicts = (total(after, "agenda_bookings_total", agenda_channel="staff",
                           agenda_booking_result="slot_unavailable")
                     - total(before, "agenda_bookings_total", agenda_channel="staff",
                             agenda_booking_result="slot_unavailable"))
    api_failed = (total(after, "agenda_bookings_total", agenda_channel="staff",
                        agenda_booking_result="failed")
                  - total(before, "agenda_bookings_total", agenda_channel="staff",
                          agenda_booking_result="failed"))
    if k6rc != 0:
        fails.append("k6 exited %d (a threshold failed)" % k6rc)
    if failed:
        fails.append("%d requests failed (5xx or network)" % failed)
    if checks.get("fails", 0):
        fails.append("%d checks failed" % checks["fails"])
    if doubles:
        fails.append("%d double bookings" % doubles)
    if api_reqs != reqs:
        fails.append("the api counted %d requests, k6 sent %d" % (api_reqs, reqs))
    if api_booked != booked:
        fails.append("the api counted %d bookings, k6 got %d 201s" % (api_booked, booked))
    if api_conflicts != conflicts:
        fails.append("the api counted %d conflicts, k6 got %d 409s" % (api_conflicts, conflicts))
    # A booking the api counted failed is a busy 409 here: any other error is
    # a 5xx (failed above) or a check that failed.
    if api_failed != busy:
        fails.append("the api counted %d failed bookings, k6 got %d busy 409s" % (api_failed, busy))
    race = k6_count(summary, "agenda_race_booked")
    print("%s pass %s: %d requests, %.0f/s, p50 %.1f ms, p95 %.1f ms, p99 %.1f ms, max %.0f ms; "
          "%d booked, %d conflicts, %d busy (%d confirms) (race: %d booked of %d); %s MB"
          % (tag, n, reqs, m.get("http_reqs", {}).get("rate", 0), dur.get("p(50)", 0),
             dur.get("p(95)", 0), dur.get("p(99)", 0), dur.get("max", 0), booked, conflicts,
             busy, k6_count(summary, "agenda_confirm_busy"), race,
             race + k6_count(summary, "agenda_race_conflicts"), memory))
    for f in fails:
        print("FAIL %s pass %s: %s" % (tag, n, f))
    return 1 if fails else 0


def check_memory(tag, values):
    # PowerShell writes the decimal separator of the locale ("24,7").
    mbs = [float(v.replace(",", ".")) for v in values]
    if len(mbs) < 2:
        return 0
    limit = mbs[0] * MEMORY_GROWTH + MEMORY_SLACK_MB
    ok = mbs[-1] <= limit
    print("%s memory: %s MB after each pass (limit %.1f)%s"
          % (tag, ", ".join("%.1f" % v for v in mbs), limit, "" if ok else ": FAIL, it grows"))
    return 0 if ok else 1


def main():
    if sys.argv[1] == "pass":
        sys.exit(check_pass(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6],
                            sys.argv[7], int(sys.argv[8])))
    sys.exit(check_memory(sys.argv[2], sys.argv[3:]))


if __name__ == "__main__":
    main()
