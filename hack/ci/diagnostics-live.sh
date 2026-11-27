#!/usr/bin/env bash
# Live check of cluster-read on a cluster that ./install.sh set up with hack/ci/diagnostics-ci-values.yaml (ADR 0025, slice 4).
#   PROFILE=quickstart VALUES_FILE=hack/ci/diagnostics-ci-values.yaml ./install.sh
#   DIAGNOSTICS=1 hack/ci/diagnostics-live.sh
# Opt-in: it does nothing without DIAGNOSTICS=1, so a stray local run never touches the cluster you are on. The e2e workflow runs it on request.
#
# What it settles (the open question R2 of the code review): does the server become Ready on a REAL API server, that is, does its rights check
# pass with the default rights of a real ServiceAccount? And does the chain around it hold: the bearer value (the server refuses a call without
# it, the shared vMCP pod never holds it, no log line has it), no dropped backend, and what ToolHive loaded for the dedicated profile `rca` (the
# eight tools) and for the shared vMCP (none of them)? A tools/list through an agent needs an actor token: that is slice 5 of the ADR.
# It reads the cluster and makes one port-forward to the server. It never prints the bearer value. Exit 1 when a check fails.
set -u
[ "${DIAGNOSTICS:-0}" = 1 ] || { echo "diagnostics-live: set DIAGNOSTICS=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
# This script changes the cluster it runs on (a ClusterRoleBinding, a ConfigMap, a restart of two vMCPs, a throwaway pod) and the cluster must be a CI
# cluster: the install used values (hack/ci/diagnostics-ci-values.yaml) that break the agents' tool path. It refuses to run anywhere else: on GitHub
# Actions (GITHUB_ACTIONS=true), or when DIAGNOSTICS_CI_CONTEXT names the current kube context exactly, and only on a kind or k3d context.
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in
  kind-*|k3d-*) ;;
  *) echo "diagnostics-live: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind or k3d context. Nothing was changed." >&2; exit 2;;
esac
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${DIAGNOSTICS_CI_CONTEXT:-}" != "$CTX_NOW" ]; then
  echo "diagnostics-live: refusing to run on '$CTX_NOW': it is not a CI run (GITHUB_ACTIONS is not true) and DIAGNOSTICS_CI_CONTEXT does not name this context. This script changes the cluster; do not run it on a cluster you use. Nothing was changed." >&2
  exit 2
fi
CHANGED_CRB=0; CHANGED_CM=0; PF=""; PF2=""; PF3=""; TD=""
# undo what this script changed, on every way out
cleanup() {
  kill $PF $PF2 $PF3 2>/dev/null
  [ -z "$TD" ] || rm -rf "$TD"
  [ "$CHANGED_CRB" != 1 ] || $K delete clusterrolebinding ci-jwks-anonymous --ignore-not-found >/dev/null 2>&1
  [ "$CHANGED_CM" != 1 ] || $K delete configmap ci-apiserver-ca -n "${MCPNS:-mcp-tools}" --ignore-not-found >/dev/null 2>&1
  $K delete pod nettest -n default --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT
DNS=openagentix-diagnostics; MCPNS=${MCP_NAMESPACE:-mcp-tools}; KNS=${KAGENT_NAMESPACE:-kagent}; PROFILE=${DIAG_PROFILE:-rca}
LOGNS=${DIAG_LOG_NAMESPACE:-diag-ci}
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
TOOLS="events_list nodes_get nodes_list pods_get pods_list_in_namespace pods_log workloads_get workloads_list"

echo "# R2: the server is Ready on a real API server (its rights check passes)"
if $K rollout status deployment/cluster-read -n "$DNS" --timeout=120s >/dev/null 2>&1; then ok "deployment/cluster-read is Ready (readiness is /readyz: the rights check passed)"
else
  bad "deployment/cluster-read is not Ready after 120 s" "R2 answer: the rights check of the server does NOT pass on this API server. The reason is in its log (it holds no secret):"
  $K logs -n "$DNS" deploy/cluster-read --tail=40 2>&1 | sed 's/^/       | /'
fi
$K logs -n "$DNS" deploy/cluster-read --tail=200 2>/dev/null | grep -E 'rights check|cluster-read starting' | sed 's/^/       log: /' | cut -c1-300
check "the pod runs the ServiceAccount cluster-read with the default projected token" "$($K get pod -n "$DNS" -l app=cluster-read -o jsonpath='{.items[0].spec.serviceAccountName}:{.items[0].spec.automountServiceAccountToken}')" "cluster-read:true"

echo "# the server refuses a call without the bearer value, and takes the one the gateway sends"
PORT=$((20000 + RANDOM % 20000))
$K port-forward -n "$DNS" svc/cluster-read "$PORT:8080" >/dev/null 2>&1 & PF=$!
sleep 3
check "/readyz answers 200" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/readyz")" 200
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"diag-live","version":"0"}}}'
check "/mcp without a bearer value is refused (401)" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT" "http://127.0.0.1:$PORT/mcp")" 401
# the header goes to curl through a config file made by process substitution: the value is never an argument (not even in a test)
mcp_init() { curl -s -o /dev/null -w '%{http_code}' -K <(printf 'header = "Authorization: Bearer %s"\n' "$1") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT" "http://127.0.0.1:$PORT/mcp"; }
check "/mcp with a wrong bearer value is refused (401)" "$(mcp_init not-the-value)" 401
VAL=$($K get secret -n "$DNS" cluster-read-bearer -o jsonpath='{.data.bearer}' | base64 -d)
code=$(mcp_init "$VAL")
check "/mcp with the right bearer value answers initialize (200)" "$code" 200
HV=$($K get secret -n "$MCPNS" diagnostics-bearer-cluster-read -o jsonpath='{.data.authorization}' | base64 -d)
check "the two Secrets hold the same value (the gateway's has the scheme word in front)" "$([ "$HV" = "Bearer $VAL" ] && echo same || echo different)" same
LEAKS=0
LEAKS=$((LEAKS + $($K logs -n "$DNS" deploy/cluster-read --tail=2000 2>/dev/null | grep -cF "$VAL")))
for p in $($K get pods -n "$MCPNS" -l app=virtualmcpserver -o name 2>/dev/null); do LEAKS=$((LEAKS + $($K logs -n "$MCPNS" "$p" --tail=2000 2>/dev/null | grep -cF "$VAL"))); done
check "the bearer value is in no log line of the server or of any vMCP" "$LEAKS" 0
unset VAL HV

echo "# the vMCPs: the shared one holds no bearer Secret, the dedicated one does, no backend is dropped"
SHARED=$($K get pods -n "$MCPNS" -l app=virtualmcpserver,toolhive-name=tools -o json)
check "the shared vMCP pod exists (the control is not empty)" "$(jq '.items|length>0' <<<"$SHARED")" true
check "no environment value of the shared vMCP pod points at a diagnostics bearer Secret" "$(jq '[.items[].spec.containers[].env[]?|select((.valueFrom.secretKeyRef.name//"")|test("bearer"))]|length' <<<"$SHARED")" 0
RCA=$($K get pods -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" -o json)
check "the pod of the dedicated profile holds the bearer Secret by reference, as an environment value (positive control)" "$(jq '[.items[].spec.containers[].env[]?|select((.valueFrom.secretKeyRef.name//"")=="diagnostics-bearer-cluster-read")]|length>0' <<<"$RCA")" true
check "no vMCP condition DiscoveredAuthConfig-* is False" "$($K get virtualmcpserver -n "$MCPNS" -o json | jq '[.items[].status.conditions[]?|select((.type|startswith("DiscoveredAuthConfig-")) and .status=="False")]|length')" 0

echo "# what each tool server lists, as ToolHive loaded it"
# kagent cannot list the tools for us: with actorJwt on, its RemoteMCPServer says DiscoveryDisabled ("Global tool discovery requires an executing Actor"),
# and an actor token only exists inside an agent session. So this reads what ToolHive itself holds for each vMCP: its status (the backends it found)
# and its configuration (the tool filter). A real tools/list through an agent is slice 5 of ADR 0025.
STATUS_RCA=$($K get virtualmcpserver -n "$MCPNS" "tools-$PROFILE" -o json 2>/dev/null)
STATUS_SH=$($K get virtualmcpserver -n "$MCPNS" tools -o json 2>/dev/null)
echo "       status of tools-$PROFILE (conditions left out): $(jq -c '.status|del(.conditions)' <<<"$STATUS_RCA" | cut -c1-700)"
echo "       status of tools (conditions left out): $(jq -c '.status|del(.conditions)' <<<"$STATUS_SH" | cut -c1-700)"
check "the dedicated vMCP tools-$PROFILE found the backend cluster-read" "$(jq '[.status|.. |strings|select(.=="cluster-read")]|length>0' <<<"$STATUS_RCA")" true
check "the shared vMCP found no backend cluster-read" "$(jq '[.status|.. |strings|select(test("cluster-read"))]|length' <<<"$STATUS_SH")" 0
check "no condition of the shared vMCP mentions cluster-read" "$(jq '[.status.conditions[]?|tojson|select(test("cluster-read"))]|length' <<<"$STATUS_SH")" 0
CMS=$($K get configmap -n "$MCPNS" -o json 2>/dev/null)
echo "       ConfigMaps of the vMCPs: $(jq -r --arg a "tools-$PROFILE" '[.items[]|select(any(.metadata.ownerReferences[]?;.name=="tools" or .name==$a))|(.metadata.name+" (owner "+(.metadata.ownerReferences[0].name)+")")]|join(", ")' <<<"$CMS")"
CFG_RCA=$(jq -r --arg a "tools-$PROFILE" '.items[]|select(any(.metadata.ownerReferences[]?;.name==$a))|.data[]?' <<<"$CMS")
CFG_SH=$(jq -r '.items[]|select(any(.metadata.ownerReferences[]?;.name=="tools"))|.data[]?' <<<"$CMS")
N=0; for t in $TOOLS; do grep -q "$t" <<<"$CFG_RCA" && N=$((N + 1)); done
check "the configuration of the dedicated vMCP names all eight tools" "$N" 8
check "the configuration of the dedicated vMCP hides every other tool (defaultToolVisibility deny)" "$(grep -c 'defaultToolVisibility: deny\|default_tool_visibility: deny\|"defaultToolVisibility": "deny"' <<<"$CFG_RCA" | awk '{print ($1>0)?"yes":"no"}')" yes
# the shared vMCP's configuration does hold the eight names, in its Cedar forbid policies (the second layer): those are cut out first, what is left
# (the aggregation: groups, backends, filters) must not name a tool
CFG_SH_NOFORBID=$(sed -E 's/forbid\([^;]*;//g' <<<"$CFG_SH")
check "the shared vMCP's configuration names a tool only in its forbid policies" "$(for t in $TOOLS; do grep -c "$t" <<<"$CFG_SH_NOFORBID"; done | paste -sd+ - | bc)" 0
check "the shared vMCP's configuration has the eight forbid policies (the second layer)" "$(grep -o 'forbid(' <<<"$CFG_SH" | wc -l | tr -d ' ')" 8
check "the shared vMCP's configuration was found (the control is not empty)" "$([ -n "$CFG_SH" ] && echo yes || echo no)" yes
echo "       kagent says: $($K get remotemcpserver -n "$KNS" "toolhive-vmcp-$PROFILE" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)"

echo "# real calls through the gateway (review F5): the vMCPs trust the API server's own tokens in this job (hack/ci/diagnostics-ci-values.yaml)"
# The values make the vMCPs accept ServiceAccount tokens of the API server (issuer and keys of the cluster) instead of Substrate's actor tokens, so that
# this script can make a token and call the gateway itself. That breaks the agents' tool path in this cluster, which nothing here uses. The script
# gives the vMCPs the cluster's CA (the installer put Substrate's into the ConfigMap), lets them read the public keys without a token, and restarts them.
CA_CM=ci-apiserver-ca
CHANGED_CM=1; CHANGED_CRB=1   # the cleanup deletes both (the CM exists after the installer anyway; the CRB is ours)
$K get configmap kube-root-ca.crt -n "$MCPNS" -o json | jq --arg n "$CA_CM" '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:.metadata.namespace},data:{"ca.crt":.data["ca.crt"]}}' | $K apply -f - >/dev/null
$K create clusterrolebinding ci-jwks-anonymous --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated --dry-run=client -o yaml | $K apply -f - >/dev/null
for v in tools "tools-$PROFILE"; do $K rollout restart "deployment/$v" -n "$MCPNS" >/dev/null 2>&1; done
for v in tools "tools-$PROFILE"; do $K rollout status "deployment/$v" -n "$MCPNS" --timeout=180s >/dev/null 2>&1 || echo "       (vMCP $v: restart not confirmed)"; done
# mcp_session <local port> <audience>: initializes a session; prints "<session id>" and keeps the token file for the next calls
mcp_token() { $K create token default -n "$MCPNS" --audience "$1" --duration 10m 2>/dev/null; }
mcp_post() {  # mcp_post <port> <token file> <session id or -> <json>: prints the JSON-RPC answer (the data line of an event stream, or the body)
  local port=$1 tf=$2 sid=$3 body=$4 out hdr=()
  [ "$sid" = - ] || hdr=(-H "Mcp-Session-Id: $sid")
  out=$(curl -s -m 30 -D "$tf.h" -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' ${hdr[@]+"${hdr[@]}"} -d "$body" "http://127.0.0.1:$port/mcp" 2>/dev/null)
  if grep -q '^data:' <<<"$out"; then sed -n 's/^data: *//p' <<<"$out" | tail -1; else printf '%s' "$out"; fi
}
mcp_open() {  # mcp_open <port> <token file>: prints the session id
  mcp_post "$1" "$2" - '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"diag-live","version":"0"}}}' >/dev/null
  local sid; sid=$(grep -i '^mcp-session-id:' "$2.h" | tr -d '\r' | awk '{print $2}')
  [ -z "$sid" ] || mcp_post "$1" "$2" "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  printf '%s' "${sid:--}"
}
TD=$(mktemp -d)
RP=$((30000 + RANDOM % 10000)); SP=$((RP + 1))
$K port-forward -n "$MCPNS" "svc/vmcp-tools-$PROFILE" "$RP:4483" >/dev/null 2>&1 & PF2=$!
$K port-forward -n "$MCPNS" svc/vmcp-tools "$SP:4483" >/dev/null 2>&1 & PF3=$!
sleep 4
mcp_token openagentix-vmcp-$PROFILE > "$TD/rca"; mcp_token openagentix-vmcp > "$TD/shared"
check "a token for the dedicated audience was made" "$([ -s "$TD/rca" ] && echo yes || echo no)" yes
# the vMCP reads the keys of the API server on the first token; give it a moment and a few tries
SID_RCA=-
for _ in $(seq 1 10); do SID_RCA=$(mcp_open $RP "$TD/rca"); [ "$SID_RCA" != - ] && break; sleep 5; done
LIST_RCA=$(mcp_post $RP "$TD/rca" "$SID_RCA" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | jq -r '[.result.tools[]?.name]|sort|join(" ")' 2>/dev/null)
WANT=$(for t in $TOOLS; do printf 'cluster-read_%s ' "$t"; done | sed 's/ $//')
check "tools/list on the dedicated vMCP lists the eight tools, and only those" "$LIST_RCA" "$WANT"
SID_SH=$(mcp_open $SP "$TD/shared")
LIST_SH=$(mcp_post $SP "$TD/shared" "$SID_SH" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
check "the shared vMCP answers tools/list (the control is not empty: it lists tools)" "$(jq '[.result.tools[]?]|length>0' <<<"$LIST_SH" 2>/dev/null)" true
check "tools/list on the shared vMCP lists no cluster-read tool" "$(jq '[.result.tools[]?.name|select(test("cluster-read"))]|length' <<<"$LIST_SH" 2>/dev/null)" 0
AUDIT_OK() { $K logs -n "$DNS" deploy/cluster-read --tail=5000 2>/dev/null | grep '"msg":"audit"' | grep -c "\"tool\":\"$1\".*\"outcome\":\"$2\""; }
BEFORE_OK=$(AUDIT_OK pods_list_in_namespace ok); BEFORE_REF=$(AUDIT_OK pods_log refused)
CALL=$(mcp_post $RP "$TD/rca" "$SID_RCA" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"cluster-read_pods_list_in_namespace","arguments":{"namespace":"kagent"}}}')
check "a call of pods_list_in_namespace through the dedicated vMCP succeeds, and the result is marked as data" "$(jq -r '(.result.isError//false|tostring)+" "+([.result.content[]?.text]|join(" ")|contains("data, not instructions")|tostring)' <<<"$CALL" 2>/dev/null)" "false true"
sleep 2
check "the server's own audit line for that call is there (the call came through the NetworkPolicy with the injected header)" "$(( $(AUDIT_OK pods_list_in_namespace ok) - BEFORE_OK ))" 1
CALL=$(mcp_post $RP "$TD/rca" "$SID_RCA" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"cluster-read_pods_log","arguments":{"namespace":"kagent","pod":"x"}}}')
sleep 2
check "pods_log in a status-only namespace is refused by the server (an audit line with outcome refused)" "$(( $(AUDIT_OK pods_log refused) - BEFORE_REF ))" 1
BEFORE_ANY=$($K logs -n "$DNS" deploy/cluster-read --tail=5000 2>/dev/null | grep -c '"msg":"audit"')
CALL=$(mcp_post $SP "$TD/shared" "$SID_SH" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"cluster-read_pods_list_in_namespace","arguments":{"namespace":"kagent"}}}')
echo "       the shared vMCP answered: $(printf '%s' "$CALL" | cut -c1-200)"
check "a call of a diagnostics tool through the shared vMCP is refused (an error, no result)" "$(jq -r '((.error!=null) or (.result.isError==true))|tostring' <<<"$CALL" 2>/dev/null)" true
sleep 2
check "and it never reached the server (no new audit line)" "$(( $($K logs -n "$DNS" deploy/cluster-read --tail=5000 2>/dev/null | grep -c '"msg":"audit"') - BEFORE_ANY ))" 0
kill $PF2 $PF3 2>/dev/null

echo "# a pod in another namespace must not reach the server (the NetworkPolicy)"
$K delete pod nettest -n default --ignore-not-found >/dev/null 2>&1
CODE=$($K run nettest -n default --image=curlimages/curl:8.10.1 --restart=Never --rm -i --quiet --command -- curl -s -m 8 -o /dev/null -w '%{http_code}' "http://cluster-read.$DNS.svc.cluster.local:8080/readyz" 2>/dev/null | tail -1)
case "$CODE" in
  000|"") ok "a pod in default timed out against the server (the ingress policy is enforced here)";;
  *) bad "a pod in default reached the server (HTTP $CODE)" "the network plugin of this cluster does not enforce ingress policy, or the policy does not select the pod. The bearer value is then the only check; do not read this as a pass.";;
esac

echo "# the rights, asked of the real API server as the ServiceAccount"
SA="system:serviceaccount:$DNS:cluster-read"
# kubectl reads "pods/exec" as the pod NAMED exec; a subresource is --subresource=exec: translate the ADR's shorthand
can() { local a=() r; for r in "$@"; do case "$r" in -*) a+=("$r");; */*) a+=("${r%%/*}" "--subresource=${r#*/}");; *) a+=("$r");; esac; done; $K auth can-i "${a[@]}" --as="$SA" 2>/dev/null || true; }
check "may list pods in the log namespace" "$(can list pods -n "$LOGNS")" yes
check "may get pod logs in the log namespace" "$(can get pods/log -n "$LOGNS")" yes
check "may list events in a status namespace" "$(can list events -n "$KNS")" yes
check "may list nodes" "$(can list nodes)" yes
check "may NOT get pod logs in a status namespace" "$(can get pods/log -n "$KNS")" no
check "may NOT get pod logs in kube-system" "$(can get pods/log -n kube-system)" no
check "may NOT get secrets in the log namespace, a status namespace, kube-system, or at all" "$(can get secrets -n "$LOGNS")$(can get secrets -n "$KNS")$(can get secrets -n kube-system)$(can get secrets --all-namespaces)" nononono
check "may NOT exec, attach, port-forward, watch or delete" "$(can create pods/exec -n "$LOGNS")$(can create pods/attach -n "$LOGNS")$(can create pods/portforward -n "$LOGNS")$(can watch pods -n "$LOGNS")$(can delete pods -n "$LOGNS")" nonononono
check "the admission policy refuses a binding of cluster-read to cluster-admin" "$(printf '%s' '{"apiVersion":"rbac.authorization.k8s.io/v1","kind":"RoleBinding","metadata":{"name":"probe","namespace":"'"$LOGNS"'"},"roleRef":{"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"cluster-admin"},"subjects":[{"kind":"ServiceAccount","name":"cluster-read","namespace":"'"$DNS"'"}]}' | $K create --dry-run=server -f - 2>&1 | grep -c 'openagentix-diagnostics-rbac')" 1

echo
echo "diagnostics-live: passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
