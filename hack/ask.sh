#!/usr/bin/env bash
# Ask an agent one question, with no chat app: hack/ask.sh <agent> "<question>"   (quick start: hack/ask.sh quickstart "...")
# It opens a kubectl port-forward to the A2A gate, signs in as the ServiceAccount quickstart-ask (a short-lived token, audience
# openagentix-a2a, checked by the gate) and sends one A2A SendMessage. The gate decides who may ask which agent: the quick start profile
# allows this caller to ask the agent `quickstart` only. Prints the agent's answer, then one line with the elapsed time.
# Needs: kubectl, jq, curl. Env: KUBECTL, KUBE_CONTEXT (default: the current context), ASK_NAMESPACE (agents namespace, default kagent),
# ASK_TIMEOUT (seconds, default 300), ASK_SA (default openagentix-system/quickstart-ask), ASK_USER (default quickstart:ask),
# ASK_PORT (local port, default a free one).
set -euo pipefail
[ $# -eq 2 ] || { echo 'usage: hack/ask.sh <agent> "<question>"' >&2; exit 2; }
AGENT=$1; Q=$2
K=${KUBECTL:-kubectl}; [ -z "${KUBE_CONTEXT:-}" ] || K="$K --context=$KUBE_CONTEXT"
NS=${ASK_NAMESPACE:-kagent}
ASK_SA=${ASK_SA:-openagentix-system/quickstart-ask}
SA_NS=${ASK_SA%%/*}; SA_NAME=${ASK_SA##*/}
GATE_NS=${GATE_NAMESPACE:-openagentix-gateway}
TIMEOUT=${ASK_TIMEOUT:-300}
USER_ID=${ASK_USER:-quickstart:ask}
PORT=${ASK_PORT:-$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')}

$K get svc a2a-gate -n "$GATE_NS" >/dev/null 2>&1 || { echo "ask.sh: the A2A gate is not installed (Service a2a-gate in $GATE_NS). Install with PROFILE=quickstart ./install.sh" >&2; exit 1; }
$K get serviceaccount "$SA_NAME" -n "$SA_NS" >/dev/null 2>&1 || $K create serviceaccount "$SA_NAME" -n "$SA_NS" >/dev/null
TOKEN=$($K create token "$SA_NAME" -n "$SA_NS" --audience openagentix-a2a --duration 10m)

$K port-forward -n "$GATE_NS" svc/a2a-gate "$PORT:8080" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null && break; sleep 0.2; done

BODY=$(jq -nc --arg q "$Q" --arg id "ask-$(date +%s)-$$" '{jsonrpc:"2.0",id:1,method:"SendMessage",params:{message:{messageId:$id,role:"ROLE_USER",parts:[{text:$q}]}}}')
t0=$(date +%s)
RESP=$(curl -sS --max-time "$TIMEOUT" -w '\n%{http_code}' -X POST "http://127.0.0.1:$PORT/agents/$NS/$AGENT" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H "X-User-Id: $USER_ID" -d "$BODY") || { echo "ask.sh: the request failed" >&2; exit 1; }
CODE=${RESP##*$'\n'}; RESP=${RESP%$'\n'*}
if [ "$CODE" != 200 ]; then echo "ask.sh: HTTP $CODE from the gate: $RESP" >&2; exit 1; fi
STATE=$(jq -r '.result.task.status.state // "none"' <<<"$RESP")
jq -r '[.result.task.artifacts[]?.parts[]?.text] | join("\n")' <<<"$RESP"
if [ "$STATE" != TASK_STATE_COMPLETED ]; then echo "ask.sh: the task ended in state $STATE: $(jq -c '.error // .result.task.status' <<<"$RESP")" >&2; exit 1; fi
echo "(answered in $(( $(date +%s) - t0 ))s through the A2A gate)" >&2
