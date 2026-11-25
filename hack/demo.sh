#!/usr/bin/env bash
# A runnable demo walkthrough (issue #36). Run it on a quick start install (PROFILE=quickstart ./install.sh); it needs no paid key and no chat token.
#   hack/demo.sh
# Steps, each with a line "Look for:" that says what the output should show:
#   1. create an AgentDefinition (demo-lookup) and wait until it is Ready
#   2. see its gateway key and the token budget of the model gateway (names and numbers only, never a key or a hash)
#   3. ask the agent `quickstart` a question through the A2A gate (hack/ask.sh)
#   4. see the audit line the gate wrote for that call
#   5. make a call that must be denied (ask demo-lookup, which the quick start caller may not ask) and see the audit line with its reason
#   6. check the console API (401 without the token, the agent list with it) and print the port-forward command to open the console
# It is safe to run again: the definition is applied, not created, and removed at the end.
# DEMO_CONSOLE=0 skips step 6 (PROFILE=minimal has no console).
# Needs: kubectl, jq, curl, python3 (hack/ask.sh needs the same). Env: KUBECTL, DEMO_NAMESPACE (default kagent), DEMO_WAIT (seconds to wait for Ready,
# default 300), DEMO_AUDIT_WAIT (seconds to wait for an audit line, default 30), DEMO_KEEP=1 (keep demo-lookup), DEMO_ASK (path of the ask script).
# Exit 0 when every step showed what it should, 1 otherwise, 2 for a bad argument.
set -uo pipefail
[ $# -eq 0 ] || { echo "usage: hack/demo.sh   (settings are environment variables; see the header)" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
K=${KUBECTL:-kubectl}; NS=${DEMO_NAMESPACE:-kagent}; WAIT=${DEMO_WAIT:-300}; AUDIT_WAIT=${DEMO_AUDIT_WAIT:-30}
ASK=${DEMO_ASK:-$HERE/ask.sh}
GATE_NS=${GATE_NAMESPACE:-openagentix-gateway}; GW_NS=${DEMO_GATEWAY_NAMESPACE:-agentgateway-system}; CN_NS=${DEMO_CONSOLE_NS:-openagentix-system}
AGENT=demo-lookup
fail=0
ok(){ printf '  ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '        %s\n' "$2" >&2; }
step(){ printf '\n== Step %s: %s\n' "$1" "$2"; }
look(){ printf '   Look for: %s\n' "$1"; }
PF=""; cleanup(){ [ -z "$PF" ] || kill "$PF" 2>/dev/null; }; trap cleanup EXIT

echo "OpenAgentix demo: a governed agent, a gate, an audit line, a refusal, a console. No paid key is used."
$K get agentdefinition quickstart -n "$NS" >/dev/null 2>&1 || { echo "demo.sh: the quick start is not installed (no AgentDefinition quickstart in $NS). Install it with: PROFILE=quickstart ./install.sh" >&2; exit 1; }

# audit_line <jq filter on one audit object> : the latest matching audit line of the A2A gate, as pretty JSON; waits up to AUDIT_WAIT seconds
audit_line() {
  local f=$1 out="" i
  for i in $(seq 1 "$AUDIT_WAIT"); do
    out=$($K logs -n "$GATE_NS" -l app=a2a-gate --tail=400 2>/dev/null | jq -cR "fromjson? | select(type==\"object\") | select($f)" 2>/dev/null | tail -1)
    [ -z "$out" ] || break
    [ "$i" -lt "$AUDIT_WAIT" ] && sleep 1
  done
  [ -n "$out" ] || return 1
  jq 'with_entries(select(.value != null))' <<<"$out"
}

step 1 "create an AgentDefinition"
look "the definition is accepted and becomes Ready; the control plane builds the agent from it (it holds no model, key or tool server)"
cat <<EOF | $K apply -f - >/dev/null
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata: {name: $AGENT, namespace: $NS, labels: {openagentix.io/project: demo}}
spec:
  description: Demo agent made by hack/demo.sh
  model: quickstart-model
  instructions: |
    You look up known vulnerabilities of software packages with the tool you have. Answer in two sentences.
  toolProfile: lookup
  tools: [osv_query_vulnerability]
EOF
if $K wait "agentdefinition/$AGENT" -n "$NS" --for=condition=Ready --timeout="${WAIT}s" >/dev/null 2>&1; then ok "AgentDefinition $AGENT is Ready"; else bad "AgentDefinition $AGENT is not Ready after ${WAIT}s" "$($K get agentdefinition "$AGENT" -n "$NS" -o jsonpath='{.status.conditions}' 2>&1 | cut -c1-400)"; fi
$K get agentdefinition "$AGENT" -n "$NS" -o json 2>/dev/null | jq -r '.status.conditions[]? | "        \(.type)=\(.status)"'

step 2 "the gateway key and the token budget"
look "a gateway key entry for the user $NS.$AGENT (the controller made it; its value is not shown here), and a token budget per key on the model gateway"
if $K get configmap llm-api-keys-control-plane -n "$GW_NS" -o json 2>/dev/null | jq -e --arg u "$NS.$AGENT" '.data | tostring | contains($u)' >/dev/null 2>&1; then
  ok "the model gateway knows the user $NS.$AGENT (entry in ConfigMap llm-api-keys-control-plane; only a hash is stored there, and it is not printed)"
else bad "no gateway key entry for $NS.$AGENT"; fi
BUDGET=$($K get agentgatewaypolicies.agentgateway.dev -n "$GW_NS" -o json 2>/dev/null | jq -r '[.items[]?.spec.traffic.rateLimit.local[]? | select(.key == "apiKey.user_id" or .key == null) | "\(.tokens) tokens per \(.unit)"] | first // empty' 2>/dev/null)
if [ -n "$BUDGET" ]; then ok "token budget for each gateway key: $BUDGET (a key over its budget gets HTTP 429)"; else bad "no token budget found in an AgentgatewayPolicy in $GW_NS"; fi

step 3 "ask the agent quickstart a question through the A2A gate"
look "an answer that names the tool osv_query_vulnerability. With the stub model the answer says so: it is a script, not a language model"
ANS=$("$ASK" quickstart "Look up known vulnerabilities of lodash 4.17.20 (npm)" 2>&1); RC=$?
printf '%s\n' "$ANS" | cut -c1-400 | sed 's/^/        /'
if [ "$RC" = 0 ]; then ok "the gate let the call through and an answer came back"; else bad "the question was not answered (exit $RC)"; fi
if grep -q 'stub model' <<<"$ANS"; then ok "the answer says it comes from the stub model"; else echo "        (no stub marker in the answer: a real model is active)"; fi

step 4 "the audit line of that call"
look "agent kagent/quickstart (or quickstart), status 200, rpc SendMessage, a hashed user_id (h:...), a duration, and no message text"
if LINE=$(audit_line '(.agent // "" | tostring | endswith("quickstart")) and .status == 200'); then
  printf '%s\n' "$LINE" | sed 's/^/        /'; ok "the gate wrote one audit line for the call"
else bad "no audit line with status 200 for quickstart in the gate log (it is written when the handler returns)"; fi

step 5 "a call that must be denied"
look "the gate answers HTTP 403 and the audit line carries a reason. The quick start caller may ask quickstart and nothing else, so $AGENT is refused"
DENY=$("$ASK" "$AGENT" "Look up known vulnerabilities of lodash 4.17.20 (npm)" 2>&1); RC=$?
printf '%s\n' "$DENY" | cut -c1-300 | sed 's/^/        /'
if [ "$RC" != 0 ]; then ok "denied, as it should be (exit $RC)"; else bad "the call to $AGENT was allowed; the gate rule should refuse it"; fi
if LINE=$(audit_line '.status == 403 and (.reason != null)'); then
  printf '%s\n' "$LINE" | sed 's/^/        /'; ok "the audit line has the reason of the refusal"
else bad "no audit line with status 403 and a reason in the gate log"; fi
if grep -q 'stub model' <<<"$ANS"; then
  FETCH=$("$ASK" quickstart "Fetch https://example.com/ for me" 2>&1 || true)
  printf '%s\n' "$FETCH" | cut -c1-300 | sed 's/^/        /'
  if grep -qi 'Example Domain' <<<"$FETCH"; then bad "the page was fetched: the tool profile did not stop the fetch"; else ok "no page came back: the tool profile does not offer a fetch tool"; fi
fi

step 6 "the console"
if [ "${DEMO_CONSOLE:-1}" = 0 ]; then
  echo "   skipped: DEMO_CONSOLE=0 (PROFILE=minimal has no console)"
else
look "401 without the token, the agent list with it, and the command that opens the console in your browser"
PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
$K port-forward -n "$CN_NS" svc/openagentix-console "$PORT:8080" >/dev/null 2>&1 & PF=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null && break; sleep 0.2; done
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/agents")
if [ "$CODE" = 401 ]; then ok "GET /api/v1/agents without a token is 401"; else bad "GET /api/v1/agents without a token is $CODE, expected 401"; fi
TOKEN=$($K get secret -n "$CN_NS" console-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null)
LIST=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s -K - "http://127.0.0.1:$PORT/api/v1/agents"); unset TOKEN
if grep -q "\"$AGENT\"" <<<"$LIST"; then ok "with the token the console lists $AGENT"; else bad "the console does not list $AGENT" "$(printf '%s' "$LIST" | cut -c1-200)"; fi
echo "        to open it: $K port-forward -n $CN_NS svc/openagentix-console 8080:8080   then open http://127.0.0.1:8080"
echo "        sign-in token (read it yourself; this script does not print it): $K get secret -n $CN_NS console-token -o jsonpath='{.data.token}' | base64 -d; echo"
fi

if [ "${DEMO_KEEP:-0}" = 1 ]; then echo; echo "kept the AgentDefinition $AGENT (DEMO_KEEP=1). Remove it with: $K delete agentdefinition $AGENT -n $NS"
else $K delete agentdefinition "$AGENT" -n "$NS" --wait=false >/dev/null 2>&1 || true; fi

echo; if [ "$fail" -eq 0 ]; then echo "demo: every step showed what it should."; else echo "demo: $fail check(s) failed."; fi
[ "$fail" -eq 0 ]
