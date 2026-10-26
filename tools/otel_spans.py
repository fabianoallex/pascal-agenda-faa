"""The spans of one trace in the OpenTelemetry Collector's file exporter
output (OTLP JSON, one object per line), for tools/http_scenarios_mail.sh.

    python tools/otel_spans.py <traces.json> <trace id>

One line per span, "<service.name><TAB><span name>", in the order the
collector wrote them; nothing when the trace isn't there (yet).
"""
import json
import sys


def service_of(resource):
    for attribute in resource.get("attributes", []):
        if attribute.get("key") == "service.name":
            return attribute.get("value", {}).get("stringValue", "?")
    return "?"


def main():
    path, trace_id = sys.argv[1], sys.argv[2].lower()
    with open(path, encoding="utf-8") as lines:
        for line in lines:
            line = line.strip()
            if not line:
                continue
            for resource_spans in json.loads(line).get("resourceSpans", []):
                service = service_of(resource_spans.get("resource", {}))
                for scope in resource_spans.get("scopeSpans", []):
                    for span in scope.get("spans", []):
                        if span.get("traceId", "").lower() == trace_id:
                            print("%s\t%s" % (service, span.get("name", "")))


if __name__ == "__main__":
    main()
