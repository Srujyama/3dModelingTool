#!/usr/bin/env bash
# mcp.sh <tool_name>    # reads JSON arguments from stdin (default {})
# Calls the robloxstudio MCP server directly over streamable HTTP and prints the
# tool's text result (unwrapped from the JSON-RPC/SSE envelope).
set -euo pipefail
URL="${MCP_URL:-http://localhost:58741/mcp}"
TOOL="$1"
ARGS="$(cat)"
[ -z "$ARGS" ] && ARGS="{}"

REQ=$(TOOL="$TOOL" ARGS="$ARGS" python3 <<'PY'
import os, json
tool = os.environ["TOOL"]; args = os.environ["ARGS"]
print(json.dumps({
    "jsonrpc":"2.0","id":1,"method":"tools/call",
    "params":{"name":tool,"arguments":json.loads(args)}
}))
PY
)

RESP=$(curl -s -m 90 -X POST "$URL" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d "$REQ")

RESP="$RESP" python3 <<'PY'
import os, json
raw = os.environ["RESP"]
payload = None
for line in raw.splitlines():
    line = line.strip()
    if line.startswith("data:"):
        payload = line[5:].strip()
if not payload:
    print("NO_DATA:", raw[:500]); raise SystemExit(1)
obj = json.loads(payload)
if "error" in obj:
    print("ERROR:", json.dumps(obj["error"])); raise SystemExit(2)
res = obj.get("result", {})
content = res.get("content")
if content:
    for c in content:
        t = c.get("text", "")
        try:
            print(json.dumps(json.loads(t), indent=2))
        except Exception:
            print(t)
else:
    print(json.dumps(res, indent=2))
PY
