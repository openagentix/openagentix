# The tool calls in the AUDIT lines of a vMCP (jq -cR -f hack/ci/rca-audit-tools.jq), as {tool, outcome, actor}. Used by hack/ci/rca-live.sh.
# The shape was read from a live run: {"level":"AUDIT","msg":"audit_event","type":"mcp_tool_call","outcome":"success","subjects":{"user_id":"actor/kagent/session-..."},
# "target":{"method":"tools/call","name":"cluster-read_pods_get"}}. Every tools/call line is kept, whatever the tool is called: the check "only
# diagnostics tools" reads ALL names, so a call of another tool cannot be dropped here. Lines that are not JSON, and other methods
# (initialize, tools/list, server/discover), are left out.
fromjson?
| select(type == "object" and .msg == "audit_event" and ((.target.method? // "") == "tools/call"))
| {tool: (.target.name // ""), outcome: (.outcome // ""), actor: (.subjects.user_id // "")}
