#!/usr/bin/env bash
# Smoke test of the quick start (ADR 0014), run after `PROFILE=quickstart ./install.sh`. Needs kubectl (pointing at the cluster), jq, curl.
#   1. the agent `quickstart` is Ready
#   2. a question is answered through the A2A gate, with a tool call through the tool profile (hack/ask.sh)
#   3. a tool that the profile does not offer gets no data (the tool profile refuses it)
#   4. a definition that the policy forbids is refused (Accepted=False) and no agent is built for it
#   5. the console API answers 401 without the token, lists the agent with it, and lists the tool profiles the policy allows
# SMOKE_CONSOLE=0 skips check 5 (PROFILE=minimal has no console).
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
[ "$RC" != 0 ] || echo "TIMING first_answer_epoch=$(date +%s)"   # read by hack/ci/phases.sh (time to first working agent)
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

if [ "${SMOKE_CONSOLE:-1}" = 1 ]; then
  echo "# 5. console API"
  PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  $K port-forward -n "${SMOKE_CONSOLE_NS:-openagentix-system}" svc/openagentix-console "$PORT:8080" >/dev/null 2>&1 & PF=$!
  trap 'kill $PF 2>/dev/null' EXIT
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/healthz" 2>/dev/null && break; sleep 0.2; done
  check "GET /api/v1/agents without a token is 401" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/agents")" 401
  TOKEN=$($K get secret -n "${SMOKE_CONSOLE_NS:-openagentix-system}" console-token -o jsonpath='{.data.token}' | base64 -d)
  LIST=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/v1/agents")
  PLAT=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/api/v1/platform"); unset TOKEN
  grep -q '"quickstart"' <<<"$LIST" && ok "GET /api/v1/agents with the token lists quickstart" || bad "the console does not list quickstart" "$(printf '%s' "$LIST" | cut -c1-200)"
  # The builder offers what this answer lists. An empty profiles list with requireToolProfile left no way to create an
  # agent (the console once read a catalog shape the control plane never wrote). The install defines mcp.profiles, so the
  # list must not be empty and must hold every profile the policy names.
  NPROF=$(python3 -I -c 'import json,sys;print(len(json.load(sys.stdin).get("profiles") or []))' <<<"$PLAT" 2>/dev/null || echo error)
  if [ "$NPROF" != error ] && [ "$NPROF" -gt 0 ]; then ok "GET /api/v1/platform lists $NPROF tool profile(s)"; else bad "GET /api/v1/platform lists no tool profile" "$(printf '%s' "$PLAT" | cut -c1-200)"; fi
  MISSING=$(python3 -I -c 'import json,sys;d=json.load(sys.stdin);have={p["name"] for p in d.get("profiles") or []};print(" ".join(n for n in d["policy"].get("allowedProfiles") or [] if n!="*" and n not in have))' <<<"$PLAT" 2>/dev/null || echo error)
  check "every profile the policy allows is in the console's platform answer" "$MISSING" ""
else
  echo "# 5. console API (skipped: SMOKE_CONSOLE=0, the profile has no console)"
fi

# 6. bring your own agent (ADR 0015), only when the quick start was installed with QUICKSTART_BYO=1 (SMOKE_BYO=1)
if [ "${SMOKE_BYO:-0}" = 1 ]; then
  echo "# 6. a container agent (the sample echo-go)"
  WNS=${SMOKE_WORKLOAD_NS:-openagentix-workloads}
  $K wait agentdefinition/echo-go -n "$NS" --for=condition=Ready --timeout=300s >/dev/null 2>&1 && ok "AgentDefinition echo-go is Ready" || bad "AgentDefinition echo-go is not Ready" "$($K get agentdefinition echo-go -n "$NS" -o jsonpath='{.status.conditions}' 2>&1 | cut -c1-600)"
  CREATED=$($K get agentdefinition echo-go -n "$NS" -o jsonpath='{.metadata.creationTimestamp}' 2>/dev/null)
  READYAT=$($K get agentdefinition echo-go -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}' 2>/dev/null)
  if [ -n "$CREATED" ] && [ -n "$READYAT" ]; then
    S1=$(python3 -I -c 'import sys,datetime as d;f=lambda s:d.datetime.strptime(s,"%Y-%m-%dT%H:%M:%SZ");print(int((f(sys.argv[2])-f(sys.argv[1])).total_seconds()))' "$CREATED" "$READYAT" 2>/dev/null || echo "?")
    echo "      echo-go was Ready $S1 s after it was created"
  fi
  check "status.capabilities.isolation says container" "$($K get agentdefinition echo-go -n "$NS" -o jsonpath='{.status.capabilities.isolation}' 2>/dev/null)" container
  EP=$($K get agentdefinition echo-go -n "$NS" -o jsonpath='{.status.endpoint.url}' 2>/dev/null)
  echo "      status.endpoint.url: $EP"
  case "$EP" in *"/agents/$NS/echo-go") ok "the endpoint goes through the A2A gate, not to the pod";; *) bad "the endpoint is not the gate route" "$EP";; esac
  POD=$($K get pod -n "$WNS" -l openagentix.io/agent=echo-go -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  check "the pod runs as user 65532, non-root" "$($K get pod -n "$WNS" "$POD" -o jsonpath='{.spec.securityContext.runAsUser}:{.spec.securityContext.runAsNonRoot}' 2>/dev/null)" 65532:true
  check "the pod has a read-only root filesystem and no service account token" "$($K get pod -n "$WNS" "$POD" -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}:{.spec.automountServiceAccountToken}' 2>/dev/null)" true:false
  # The gate learns a new agent from a route list file that the kubelet syncs into its pod from a ConfigMap (up to about two minutes after the
  # controller wrote it), so the agent can be Ready a little before the gate routes to it. Ask again until it answers; print how long it took.
  T0=$(date +%s); TRIES=0
  while :; do
    TRIES=$((TRIES+1)); ANS=$(hack/ask.sh echo-go "Say hello" 2>&1); RC=$?
    [ "$RC" = 0 ] && break
    [ $(( $(date +%s) - T0 )) -ge "${SMOKE_ROUTE_WAIT:-120}" ] && break
    sleep 5
  done
  echo "      echo-go answered after $(( $(date +%s) - T0 )) s and $TRIES attempt(s) (exit $RC) after it was Ready"
  if [ "$RC" != 0 ]; then
    echo "      route list in the cluster:  $($K get configmap a2a-gate-routes -n openagentix-gateway -o jsonpath='{.data.routes\.json}' 2>&1 | cut -c1-300)"
    GP=$($K get pod -n openagentix-gateway -l app=a2a-gate -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    echo "      route list inside the gate pod ($GP): $($K exec -n openagentix-gateway "$GP" -- cat /etc/a2a-gate/routes/routes.json 2>&1 | cut -c1-300)"
    echo "      gate env: $($K get pod -n openagentix-gateway "$GP" -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value} {end}' 2>&1 | cut -c1-600)"
    $K logs -n openagentix-gateway "$GP" 2>&1 | grep -iv '"audit"' | head -20 | cut -c1-300 | sed 's/^/      gate log: /'
    $K logs -n openagentix-gateway "$GP" --tail=3 2>&1 | cut -c1-300 | sed 's/^/      gate last: /'
    GPF=$((20000 + RANDOM % 20000)); $K port-forward -n openagentix-gateway svc/a2a-gate "$GPF:8080" >/dev/null 2>&1 & GPID=$!; sleep 3
    TK=$($K create token quickstart-ask -n openagentix-system --audience openagentix-a2a --duration 5m 2>/dev/null)
    echo "      card via the gate: $(curl -sS --max-time 10 -H "Authorization: Bearer $TK" -H 'X-User-Id: quickstart:ask' "http://127.0.0.1:$GPF/agents/kagent/echo-go/.well-known/agent-card.json" 2>&1 | cut -c1-400)"
    echo "      raw SendMessage via the gate: $(curl -sS --max-time 20 -H "Authorization: Bearer $TK" -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -X POST -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"messageId":"m1","role":"ROLE_USER","parts":[{"text":"hi"}]}}}' "http://127.0.0.1:$GPF/agents/kagent/echo-go" 2>&1 | cut -c1-500)"
    kill $GPID 2>/dev/null; unset TK
    $K get svc,endpoints,networkpolicy,pod -n "$WNS" -o wide 2>&1 | cut -c1-250 | sed 's/^/      workload: /'
    $K logs -n "$WNS" -l openagentix.io/agent=echo-go --tail=15 2>&1 | cut -c1-300 | sed 's/^/      echo-go log: /'
  fi
  echo "      answer: $(printf '%s' "$ANS" | tr '\n' ' ' | cut -c1-300)"
  check "echo-go answered through the gate (exit 0)" "$RC" 0
  if [ "$STUB" = 1 ]; then
    grep -q 'stub model' <<<"$ANS" && ok "the answer came from the stub model, through the model gateway" || bad "the answer does not say it came from the stub model"
  else
    [ -n "$ANS" ] && ok "a real model answered" || bad "empty answer"
  fi
  KEYS=$($K get configmap llm-api-keys-control-plane -n agentgateway-system -o jsonpath='{.data}' 2>/dev/null)
  grep -q '"kagent.echo-go"' <<<"$KEYS" && ok "the gateway knows its own user: kagent.echo-go" || bad "no gateway key entry for kagent.echo-go"
  GWLOG=$($K logs -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=model-gateway --tail=400 2>/dev/null | grep -c 'kagent.echo-go' || true)
  echo "      gateway log lines that mention kagent.echo-go: ${GWLOG:-0}"
  [ "${GWLOG:-0}" -gt 0 ] && ok "the gateway log shows the request under the gateway user kagent.echo-go" || echo "      (note: the gateway log does not name the user at this log level; the key entry above is the proof of identity)"
  echo "# 6a. tools through the profile lookup (ADR 0019)"
  check "the pod carries the profile label" "$($K get pod -n "$WNS" "$POD" -o jsonpath='{.metadata.labels.openagentix\.io/tool-profile}' 2>/dev/null)" lookup
  check "the pod gets the tool URL" "$($K get pod -n "$WNS" "$POD" -o jsonpath='{.spec.containers[0].env[?(@.name=="OPENAGENTIX_MCP_URL")].value}' 2>/dev/null)" "http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp"
  check "the token is a projected ServiceAccount token with the profile's audience" "$($K get pod -n "$WNS" "$POD" -o jsonpath='{.spec.volumes[?(@.name=="mcp-token")].projected.sources[0].serviceAccountToken.audience}' 2>/dev/null)" openagentix-vmcp-lookup-workload
  $K wait virtualmcpserver/tools-lookup-workload -n mcp-tools --for=jsonpath='{.status.phase}'=Ready --timeout=180s >/dev/null 2>&1 \
    && ok "the workload tool server is Ready" || bad "the workload tool server is not Ready" "$($K get virtualmcpserver tools-lookup-workload -n mcp-tools -o jsonpath='{.status}' 2>&1 | cut -c1-400)"
  T0=$(date +%s); TOOLS=""
  while :; do
    TOOLS=$(hack/ask.sh echo-go "/tools" 2>&1); RC=$?
    [ "$RC" = 0 ] && grep -q 'osv_query_vulnerability' <<<"$TOOLS" && break
    [ $(( $(date +%s) - T0 )) -ge "${SMOKE_TOOLS_WAIT:-180}" ] && break
    sleep 5
  done
  echo "      /tools answered after $(( $(date +%s) - T0 )) s: $(printf '%s' "$TOOLS" | tr '\n' ' ' | cut -c1-300)"
  grep -q 'tools: osv_query_vulnerability' <<<"$TOOLS" && ok "echo-go listed the profile's one tool through the workload tool server (its own token, its own network rule)" \
    || { bad "echo-go could not list the profile's tools" "$(printf '%s' "$TOOLS" | cut -c1-300)"
         $K logs -n mcp-tools -l toolhive-name=tools-lookup-workload --tail=400 2>&1 | grep -v '"AUDIT"\|cache sync' | tail -20 | cut -c1-400 | sed 's/^/      workload vMCP log: /'
         $K logs -n "$WNS" -l openagentix.io/agent=echo-go --tail=10 2>&1 | cut -c1-300 | sed 's/^/      echo-go log: /'; }
  # The identity, from outside: the port-forward goes around network policy on purpose, so only the token decides here.
  VPF=$((20000 + RANDOM % 20000)); $K port-forward -n mcp-tools svc/vmcp-tools-lookup-workload "$VPF:4483" >/dev/null 2>&1 & VPID=$!; sleep 3
  # The positive control of this flow is the /tools answer above: the agent ran the same initialize, initialized and tools/list with its
  # own pod-bound token. A token for a ServiceAccount of the workload namespace cannot be made from outside (admission refuses it).
  OUT=$($K create token echo-go -n "$WNS" --audience openagentix-vmcp-lookup-workload --duration 10m 2>&1 >/dev/null); RC=$?
  if [ "$RC" != 0 ] && grep -q 'only the kubelet may request a ServiceAccount token' <<<"$OUT"; then ok "a token for the agent's ServiceAccount cannot be requested from outside, not even by the cluster admin"
  else bad "a token for the agent's ServiceAccount could be requested from outside" "exit $RC: $(printf '%s' "$OUT" | cut -c1-200)"; fi
  mcp_list() { # mcp_list <token>: "<initialize status>|<session id>|<tools/list status>|<tools/list body>"
    local h st sid ls body
    h=$(mktemp)
    st=$(curl -sS -D "$h" -o "$h.body" -w '%{http_code}' --max-time 10 -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -X POST \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' "http://127.0.0.1:$VPF/mcp" 2>/dev/null)
    sid=$(tr -d '\r' < "$h" | awk -F': ' 'tolower($1)=="mcp-session-id"{print $2}')
    case "$st" in 401|403) body="initialize: $(tr '\n' ' ' < "$h.body" | cut -c1-700)";; esac   # the server's reason (no token in it)
    rm -f "$h" "$h.body"
    if [ -n "$sid" ]; then
      curl -sS -o /dev/null --max-time 10 -H "Authorization: Bearer $1" -H "Mcp-Session-Id: $sid" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -X POST \
        -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' "http://127.0.0.1:$VPF/mcp" 2>/dev/null
      body=$(curl -sS -w '\n%{http_code}' --max-time 10 -H "Authorization: Bearer $1" -H "Mcp-Session-Id: $sid" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -X POST \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' "http://127.0.0.1:$VPF/mcp" 2>/dev/null)
      ls=$(tail -n1 <<<"$body"); body=$(sed '$d' <<<"$body" | tr '\n' ' ' | cut -c1-400)
    fi
    printf '%s|%s|%s|%s' "$st" "$sid" "${ls:-}" "${body:-}"
  }
  denied() { # denied <desc> <mcp_list output>: an explicit refusal, or a list without the profile's tool
    local st sid ls body; IFS='|' read -r st sid ls body <<<"$2"
    echo "      $1: initialize HTTP $st, session ${sid:+set}${sid:-EMPTY}, tools/list HTTP ${ls:--}: $(printf '%s' "$body" | cut -c1-700)"
    case "$st" in 401|403) ok "$1: refused at initialize (HTTP $st)"; return;; esac
    if [ -z "$sid" ]; then bad "$1: no session id, so the check cannot judge" "initialize HTTP $st"; return; fi
    case "$ls" in 401|403) ok "$1: tools/list refused (HTTP $ls)"; return;; esac
    if grep -q 'osv_query_vulnerability' <<<"$body"; then bad "$1: the profile's tool was listed" "$body"
    elif grep -q '"error"' <<<"$body" || grep -Eq '"tools": ?\[\]' <<<"$body"; then ok "$1: tools/list gave an authorization error or an empty list"
    else bad "$1: no explicit refusal" "$body"; fi
  }
  TK=$($K create token quickstart-ask -n openagentix-system --audience openagentix-vmcp-lookup-workload --duration 10m 2>/dev/null)
  denied "a ServiceAccount of another namespace with the profile's audience" "$(mcp_list "$TK")"
  TK=$($K create token quickstart-ask -n openagentix-system --audience openagentix-vmcp-lookup --duration 10m 2>/dev/null)
  denied "a token with another audience" "$(mcp_list "$TK")"
  kill $VPID 2>/dev/null; unset TK
  echo "# 6b. a container agent that policy must refuse"
  GOODREF=$($K get agentdefinition echo-go -n "$NS" -o jsonpath='{.spec.runtime.container.image}')
  DIGEST=${GOODREF#*@}
  refuse_def() { # refuse_def <name> <expected text in the violations> <image> [extra spec json]
    local n=$1 want=$2 img=$3 extra=${4:-}; [ -n "$extra" ] || extra='{}'
    jq -nc --arg n "$n" --arg ns "$NS" --arg i "$img" --argjson x "$extra" '{apiVersion:"openagentix.io/v1alpha1",kind:"AgentDefinition",metadata:{name:$n,namespace:$ns},spec:({description:"must be refused",model:"quickstart-model",runtime:{type:"container",container:{image:$i,port:8080}}}+$x)}' | $K apply -f - >/dev/null
    local acc="" v=""
    for _ in $(seq 1 30); do acc=$($K get agentdefinition "$n" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null); [ -n "$acc" ] && break; sleep 2; done
    v=$($K get agentdefinition "$n" -n "$NS" -o jsonpath='{.status.violations}' 2>/dev/null)
    check "$n: Accepted=False" "$acc" False
    grep -q "$want" <<<"$v" && ok "$n: the reason says '$want'" || bad "$n: the reason does not say '$want'" "$(printf '%s' "$v" | cut -c1-300)"
    check "$n: nothing was created in the workload namespace" "$($K get deploy -n "$WNS" -l openagentix.io/agent-definition="$n" -o name 2>/dev/null | wc -l | tr -d ' ')" 0
    $K delete agentdefinition "$n" -n "$NS" --wait=false >/dev/null 2>&1
  }
  refuse_def byo-bad-registry "not under a registry prefix" "docker.io/evil/agent@$DIGEST"
  refuse_def byo-bad-tag "must be pinned by digest" "registry.local/oa/echo-a2a:latest"
  refuse_def byo-bad-tools "tools cannot be listed" "$GOODREF" '{"tools":["osv_query_vulnerability"]}'
  refuse_def byo-bad-profile "is not defined" "$GOODREF" '{"toolProfile":"nope"}'
fi

echo; echo "smoke: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
