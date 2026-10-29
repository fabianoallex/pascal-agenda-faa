"""A stand-in for an OpenTelemetry collector, for tools/test_http.sh: it takes
OTLP over HTTP with JSON (POST /v1/traces, or any path) and appends each
body, one line each, to a file. tools/desktop_traces.py reads that file.

    python tools/otlp_sink.py <port> <file>

It answers 200 with {} and keeps nothing else. Stopped by killing it.
"""
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


class Sink(BaseHTTPRequestHandler):
    path_out = ""

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8")
        with LOCK:
            with open(Sink.path_out, "a", encoding="utf-8") as out:
                out.write(body.replace("\n", " ") + "\n")
        answer = b"{}"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(answer)))
        self.end_headers()
        self.wfile.write(answer)

    def do_GET(self):
        # The runner's readiness check.
        self.send_response(204)
        self.end_headers()

    def log_message(self, format, *args):
        pass


def main():
    port, Sink.path_out = int(sys.argv[1]), sys.argv[2]
    open(Sink.path_out, "w", encoding="utf-8").close()
    ThreadingHTTPServer(("127.0.0.1", port), Sink).serve_forever()


if __name__ == "__main__":
    main()
