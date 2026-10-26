"""One line per .eml file in a directory, for tools/http_scenarios_worker.sh.

    python tools/eml_summary.py <directory>

Each line, tab separated: the event id, the kind, the appointment id, the
recipient, the subject (decoded), the "See it" link and the "Cancel it" link
('-' when there is none), from the headers Agenda.Notifications writes and
the body decoded (quoted-printable, UTF-8). Sorted by file name (the time the
worker wrote it). Also checks what every message must be: UTF-8 text, a
Message-ID, no line over 78 characters; a message that isn't is printed as
"BAD <file>: <why>".
"""
import email
import email.header
import email.policy
import os
import re
import sys


def summary(path):
    raw = open(path, "rb").read()
    for line in raw.split(b"\r\n"):
        if len(line) > 78:
            return "BAD %s: a line of %d characters" % (path, len(line))
    msg = email.message_from_bytes(raw, policy=email.policy.default)
    if msg.get_content_charset() != "utf-8":
        return "BAD %s: charset %s" % (path, msg.get_content_charset())
    if not msg["Message-ID"]:
        return "BAD %s: no Message-ID" % path
    body = msg.get_content()
    see = re.search(r"See it: (\S+)", body)
    cancel = re.search(r"Cancel it: (\S+)", body)
    return "\t".join([
        msg["X-Agenda-Event"] or "-",
        msg["X-Agenda-Kind"] or "-",
        msg["X-Agenda-Appointment"] or "-",
        str(msg["To"]),
        str(msg["Subject"]),
        see.group(1) if see else "-",
        cancel.group(1) if cancel else "-",
    ])


def main():
    # The subjects have accents: UTF-8 out, whatever the console's code page.
    sys.stdout.reconfigure(encoding="utf-8")
    folder = sys.argv[1]
    if not os.path.isdir(folder):
        return
    for name in sorted(os.listdir(folder)):
        if name.endswith(".eml"):
            print(summary(os.path.join(folder, name)))


if __name__ == "__main__":
    main()
