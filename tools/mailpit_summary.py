"""The messages Mailpit holds for one recipient, one line each, for
tools/http_scenarios_mail.sh.

    python tools/mailpit_summary.py <mailpit base url> <recipient>

Each line, tab separated, oldest first: the X-Agenda-Kind header, the
X-Agenda-Appointment header, the subject (decoded by Mailpit), the "See it"
link and the "Cancel it" link ('-' when there is none). Mailpit's API:
/api/v1/search (to:<address>), /api/v1/message/<id> (the text body) and
/api/v1/message/<id>/headers.
"""
import json
import re
import sys
import urllib.parse
import urllib.request


def get(url):
    with urllib.request.urlopen(url, timeout=10) as answer:
        return json.loads(answer.read().decode("utf-8"))


def main():
    sys.stdout.reconfigure(encoding="utf-8")
    base, recipient = sys.argv[1].rstrip("/"), sys.argv[2]
    query = urllib.parse.quote("to:" + recipient)
    found = get("%s/api/v1/search?query=%s&limit=200" % (base, query))
    for item in reversed(found.get("messages", [])):
        message = get("%s/api/v1/message/%s" % (base, item["ID"]))
        headers = get("%s/api/v1/message/%s/headers" % (base, item["ID"]))
        text = message.get("Text", "")
        see = re.search(r"See it: (\S+)", text)
        cancel = re.search(r"Cancel it: (\S+)", text)
        print("\t".join([
            (headers.get("X-Agenda-Kind") or ["-"])[0],
            (headers.get("X-Agenda-Appointment") or ["-"])[0],
            message.get("Subject", ""),
            see.group(1) if see else "-",
            cancel.group(1) if cancel else "-",
        ]))


if __name__ == "__main__":
    main()
