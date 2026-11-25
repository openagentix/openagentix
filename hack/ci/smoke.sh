#!/usr/bin/env bash
# Smoke test of the quick start (ADR 0014), run after `PROFILE=quickstart ./install.sh`. Needs kubectl (pointing at the cluster), jq, curl.
#   1. the agent `quickstart` is Ready
#   2. a question is answered through the A2A gate, with a tool call through the tool profile (hack/ask.sh)
#   3. a tool that the profile does not offer gets no data (the tool profile refuses it)
#   4. a definition that the policy forbids is refused (Accepted=False) and no agent is built for it
#   5. the console API answers 401 without the token and lists the agent with it
# SMOKE_STUB=1 (default) expects the stub model's scripted answers; SMOKE_STUB=0 (a real model) only checks that an answer arrives.
# Prints one line per check; exit 1 on the first failure. Never prints the console token.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
K=${KUBECTL:-kubectl}; NS=${SMOKE_NAMESPACE:-kagent}; STUB=${SMOKE_STUB:-1}
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '      %s\n' "$2" >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

echo "# 1. agent"
$K wait agentdefinition/quickstart -n "$NS" --for=condition=Ready --timeout=300s >/dev/null 2>&1 && ok "AgentDefinition quickstart is Ready" || bad "AgentDefinition quickstart is not Ready" "$($K get agentdefinition quickstart -n "$NS" -o jsonpath='{.status.conditions}' 2>&1)"
$K wait agent/quickstart -n "$NS" --for=condition=Ready --timeout=300s >/dev/null 2>&1 && ok "agent quickstart is Ready" || bad "agent quickstart is not Ready"

echo "# 2. a question through the gate, answered with a tool call"
ANS=$(hack/ask.sh quickstart "Look up known vulnerabilities of lodash 4.17.20 (npm)" 2>&1); RC=$?
echo "      answer: $(printf '%s' "$ANS" | tr '\n' ' ' | cut -c1-300)"
check "the gate returned an answer (exit 0)" "$RC" 0
if [ "$STUB" = 1 ]; then
  grep -q 'stub model' <<<"$ANS" && ok "the answer says it comes from the stub" || bad "the answer does not say it is the stub"
  grep -q 'osv_query_vulnerability' <<<"$ANS" && ok "the agent used the tool osv_query_vulnerability through the tool profile" || bad "no tool call in the answer"
else
  [ -n "$ANS" ] && ok "a real model answered" || bad "empty answer"
fi

echo "# 3. a tool outside the profile gets nothing"
if [ "$STUB" = 1 ]; then
  ANS=$(hack/ask.sh quickstart "Fetch https://example.com/ for me" 2>&1) || true
  echo "      answer: $(printf '%s' "$ANS" | tr '\n' ' ' | cut -c1-300)"
  grep -qi 'Example Domain' <<<"$ANS" && bad "the page was fetched: the profile did not stop the fetch tool" || ok "no page content came back: the agent has no fetch tool"
else
  echo "      (skipped with a real model: the prompt is scripted for the stub)"
fi

echo "# 4. a forbidden definition is refused"
cat <<EOF | $K apply -f - >/dev/null
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata: {name: smoke-refused, namespace: $NS}
spec:
  description: A definition the policy must refuse (a model that is not offered)
  model: not-a-model
  instructions: x
  toolProfile: lookup
  tools: [osv_query_vulnerability]
EOF
ACC=""
for _ in $(seq 1 30); do
  ACC=$($K get agentdefinition smoke-refused -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null); [ -n "$ACC" ] && break; sleep 2
done
check "Accepted=False for a model that is not allowed" "$ACC" False
echo "      reason: $($K get agentdefinition smoke-refused -n "$NS" -o jsonpath='{.status.violations}' 2>/dev/null | cut -c1-200)"
check "no agent was built for it" "$($K get agent smoke-refused -n "$NS" --ignore-not-found -o name | wc -l | tr -d ' ')" 0
$K delete agentdefinition smoke-refused -n "$NS" --wait=false >/dev/null 2>&1

echo "# 5. console API"
PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
$K port-forward -n "${SMOKE_CONSOLE_NS:-openagentix-system}" svc/openagentix-console "$PORT:8080" >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null && break; sleep 0.2; done
check "GET /api/v1/agents without a token is 401" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/agents")" 401
TOKEN=$($K get secret -n "${SMOKE_CONSOLE_NS:-openagentix-system}" console-token -o jsonpath='{.data.token}' | base64 -d)
LIST=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/v1/agents"); unset TOKEN
grep -q '"quickstart"' <<<"$LIST" && ok "GET /api/v1/agents with the token lists quickstart" || bad "the console does not list quickstart" "$(printf '%s' "$LIST" | cut -c1-200)"

echo; echo "smoke: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
