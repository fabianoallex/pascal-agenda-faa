"""The dashboards of docker-compose.yml against the running stack
(docs/design.md, M5 decision 6), for tools/test_compose.sh, after the mail
scenarios ran:

    python tools/dashboards_check.py <prometheus url> <grafana url> <dashboards dir>

- every Prometheus target is up (the api, the collector's exporter, RabbitMQ);
- every query of every panel of docker/grafana/dashboards runs (a query
  Prometheus refuses fails; one with no data yet is listed, not failed);
- the series the scenarios must have made exist (REQUIRED);
- Grafana loaded each dashboard by its uid, in the Agenda folder, and its
  data source answers.

Waits up to WAIT_SECONDS for the targets and the series (the worker pushes
every OTEL_METRIC_EXPORT_INTERVAL, Prometheus scrapes every 5 s). Exit code
0 only if every check passed.
"""
import base64
import glob
import json
import os
import sys
import time
import urllib.parse
import urllib.request

WAIT_SECONDS = 90
# A query each: one series at least once the scenarios ran.
REQUIRED = [
    'http_server_request_duration_seconds_count{job="agenda-api"}',
    'agenda_bookings_total{job="agenda-api",agenda_channel="staff",agenda_booking_result="booked"}',
    'outbox_events_delivered_total{job="agenda-worker",outbox_event_kind="appointment.booked"}',
    'outbox_consumer_messages_total{job="agenda-worker",outbox_consumer="agenda.email",outbox_result="done"}',
    'agenda_emails_total{job="agenda-worker",agenda_email_result="sent"}',
    'agenda_email_send_duration_seconds_count{job="agenda-worker"}',
    'outbox_events_pending{job="agenda-worker"}',
    'db_client_connection_count{job="agenda-worker"}',
    'rabbitmq_queue_messages_ready{job="rabbitmq",queue="agenda.email"}',
]
FAILS = []


def check(cond, label):
    print(("ok   " if cond else "FAIL ") + label)
    if not cond:
        FAILS.append(label)


# Grafana as its admin (docker-compose.yml's default admin/admin): a data
# source's health check needs more than an anonymous viewer.
GRAFANA_AUTH = "Basic " + base64.b64encode(b"admin:admin").decode("ascii")


def get(url, auth=None):
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", auth)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def query(prom, expr):
    return get(prom + "/api/v1/query?" + urllib.parse.urlencode({"query": expr}))


def wait(predicate):
    deadline = time.time() + WAIT_SECONDS
    while True:
        try:
            if predicate():
                return True
        except OSError:
            pass
        if time.time() >= deadline:
            return False
        time.sleep(2)


def main():
    prom, grafana, folder = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/"), sys.argv[3]

    def targets_up():
        active = get(prom + "/api/v1/targets")["data"]["activeTargets"]
        return len(active) == 3 and all(t["health"] == "up" for t in active)
    up = wait(targets_up)
    try:
        detail = ", ".join("%s %s" % (t["labels"]["job"], t["health"])
                           for t in get(prom + "/api/v1/targets")["data"]["activeTargets"])
    except OSError as e:
        detail = str(e)
    check(up, "Prometheus targets up: " + detail)

    for expr in REQUIRED:
        found = wait(lambda: len(query(prom, expr)["data"]["result"]) > 0)
        check(found, "series: " + expr)

    for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
        with open(path, encoding="utf-8") as f:
            board = json.load(f)
        empty = []
        for p in board["panels"]:
            for t in p["targets"]:
                try:
                    answer = query(prom, t["expr"])
                    ok = answer.get("status") == "success"
                except urllib.error.HTTPError as e:
                    ok, answer = False, {"error": e.read().decode("utf-8", "replace")}
                check(ok, "%s: \"%s\" runs" % (board["uid"], p["title"]) +
                      ("" if ok else " (%s)" % answer.get("error")))
                if ok and not answer["data"]["result"]:
                    empty.append(p["title"])
        if empty:
            print("     %s: no data yet in %s" % (board["uid"], "; ".join(empty)))
        loaded = get(grafana + "/api/dashboards/uid/" + board["uid"], GRAFANA_AUTH)
        check(loaded["dashboard"]["title"] == board["title"] and
              loaded["meta"].get("folderTitle") == "Agenda",
              "Grafana: %s loaded in Agenda" % board["uid"])

    health = get(grafana + "/api/datasources/uid/prometheus/health", GRAFANA_AUTH)
    check(health.get("status") == "OK", "Grafana: the Prometheus data source answers")

    print("dashboards: %d failed" % len(FAILS))
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
