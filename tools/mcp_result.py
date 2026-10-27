"""One MCP answer (JSON-RPC over HTTP) in a form a shell script can check,
for tools/http_scenarios_mcp.sh.

    python tools/mcp_result.py <answer.json> call    -> "<isError>\\t<text>"
    python tools/mcp_result.py <answer.json> tools   -> one line per tool:
        "<name>\\t<required arguments, comma-separated>\\t<all arguments>"
    python tools/mcp_result.py <answer.json> error   -> "<code>\\t<message>"

Exit code 1 when the answer isn't JSON or lacks what was asked for.
"""
import json
import sys


def main():
    path, what = sys.argv[1], sys.argv[2]
    with open(path, encoding="utf-8") as f:
        answer = json.load(f)
    out = sys.stdout
    if what == "error":
        error = answer.get("error")
        if error is None:
            return 1
        out.write("%s\t%s\n" % (error.get("code"), error.get("message", "")))
        return 0
    result = answer.get("result")
    if result is None:
        return 1
    if what == "call":
        text = "".join(c.get("text", "") for c in result.get("content", [])
                       if c.get("type") == "text")
        out.write("%s\t%s\n" % ("true" if result.get("isError") else "false",
                                text.replace("\n", " ")))
        return 0
    if what == "tools":
        for tool in result.get("tools", []):
            schema = tool.get("inputSchema", {})
            out.write("%s\t%s\t%s\n" % (tool.get("name"),
                                        ",".join(sorted(schema.get("required", []))),
                                        ",".join(sorted(schema.get("properties", {})))))
        return 0
    return 1


if __name__ == "__main__":
    # The text is the api's UTF-8 body: write it as UTF-8 whatever the console.
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
