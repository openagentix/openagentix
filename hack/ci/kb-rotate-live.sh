#!/usr/bin/env bash
# Live check of the rotation of one tool group's value (ADR 0030, section 3, review finding M2) on the cluster of hack/ci/kb-access-live.sh, in mode enforce:
#   KB_ROTATE=prepare   KB_ACCESS=1 hack/ci/kb-rotate-live.sh   keeps the old value of the group alpha in a file of mode 600 (KB_ROTATE_FILE) and deletes both Secrets of the group
#   ./install.sh                                                 makes a new value, writes both Secrets and restarts the vMCPs of the group, which hold the old one
#   KB_ROTATE=check     KB_ACCESS=1 hack/ci/kb-rotate-live.sh   the kb takes the new value (200) and refuses the old one (401); every backend of the group's vMCP is ready (the
#                                                                vMCP holds the new value, or the kb would refuse its discovery)
# Opt-in: it does nothing without KB_ACCESS=1. The old value stays in a file of the throwaway runner and is never printed. Exit 1 when a check fails.
set -u
[ "${KB_ACCESS:-0}" = 1 ] || { echo "kb-rotate-live: set KB_ACCESS=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
# the one guard of the live CI scripts (issue #212): kind or k3d only, a CI run or the named context, never kind-openagentix by hand; it reads the kubeconfig and nothing else
. "$(cd "$(dirname "$0")" && pwd)/lib/require-ci-context.sh"
require_ci_context kb-rotate-live KB_ACCESS_CI_CONTEXT
case "${KB_ROTATE:-}" in prepare|check) ;; *) echo "kb-rotate-live: set KB_ROTATE to prepare or check" >&2; exit 2;; esac
MCPNS=${MCP_NAMESPACE:-mcp-tools}; KBNS=openagentix-knowledge
OLD=${KB_ROTATE_FILE:-${RUNNER_TEMP:-/tmp}/kb-rotate-old-alpha}
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }

if [ "$KB_ROTATE" = prepare ]; then
  umask 077
  $K get secret kb-caller-alpha -n "$MCPNS" -o jsonpath='{.data.value}' | base64 -d > "$OLD" || exit 1
  [ -s "$OLD" ] || { echo "kb-rotate-live: the value of alpha is empty" >&2; exit 1; }
  $K delete secret kb-caller-alpha -n "$MCPNS" >/dev/null || exit 1
  $K patch secret kb-callers -n "$KBNS" --type=json -p '[{"op":"remove","path":"/data/alpha"}]' >/dev/null || exit 1
  echo "kb-rotate-live: the old value of alpha is kept in a file, both Secrets of alpha are deleted"
  exit 0
fi

echo "# after the install: the value of alpha is new, the kb takes it and refuses the old one"
NEW=$($K get secret kb-caller-alpha -n "$MCPNS" -o jsonpath='{.data.value}' | base64 -d)
check "a new value was made (it differs from the old one)" "$([ -s "$OLD" ] && [ -n "$NEW" ] && [ "$NEW" != "$(cat "$OLD")" ] && echo new || echo same)" new
check "the two Secrets of alpha hold the same new value" "$([ "$($K get secret kb-callers -n "$KBNS" -o jsonpath='{.data.alpha}')" = "$($K get secret kb-caller-alpha -n "$MCPNS" -o jsonpath='{.data.value}')" ] && echo same || echo different)" same
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"rotate","version":"0"}}}'
probe() {   # probe <file with the whole header value>: the HTTP status of an initialize from the pod that the kb network policy admits and that is not a tool server
  $K delete pod kb-probe -n kb-ci --ignore-not-found --wait=true >/dev/null 2>&1
  # the header goes in through standard input and `curl -K -`: the value is in no argument
  { printf 'header = "Authorization: '; tr -d '\n' < "$1"; printf '"\n'; } | $K run kb-probe -n kb-ci --labels app=kb-probe --image=curlimages/curl:8.10.1 --restart=Never --rm -i --quiet --command -- \
    curl -s -m 10 -o /dev/null -w '%{http_code}' -K - -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT" http://kb.openagentix-knowledge.svc.cluster.local:8080/mcp 2>/dev/null | tail -c 3
}
printf '%s' "$NEW" > "$OLD.new"
check "the kb takes the new value (200)" "$(probe "$OLD.new")" 200
check "the kb refuses the old value (401)" "$(probe "$OLD")" 401
rm -f "$OLD.new" "$OLD"
echo "# the vMCPs of the group hold the new value"
check "every backend of the vMCP tools-alpha is ready (the kb refuses a vMCP that holds the old value)" "$($K get virtualmcpserver tools-alpha -n "$MCPNS" -o json | jq -r '[.status.discoveredBackends[]?|select(.status!="ready")|.name]|join(",")')" ""
check "no condition DiscoveredAuthConfig-* of the vMCP is False" "$($K get virtualmcpserver tools-alpha -n "$MCPNS" -o json | jq '[.status.conditions[]?|select((.type|startswith("DiscoveredAuthConfig-")) and .status=="False")]|length')" 0
check "the vMCP of alpha has been restarted since the value was made (its pod is newer than the Secret)" "$(a=$($K get secret kb-caller-alpha -n "$MCPNS" -o jsonpath='{.metadata.creationTimestamp}'); p=$($K get pods -n "$MCPNS" -l app=virtualmcpserver,toolhive-name=tools-alpha -o jsonpath='{.items[0].metadata.creationTimestamp}'); [ "$p" \> "$a" ] || [ "$p" = "$a" ] && echo newer || echo older)" newer
echo
echo "kb-rotate-live: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
