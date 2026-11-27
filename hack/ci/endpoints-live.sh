#!/usr/bin/env bash
# Live check of mcp.endpoints on a cluster that ./install.sh set up with hack/ci/endpoints-ci-values.yaml (ADR 0026, slice 2).
#   kind create cluster --name openagentix --config hack/kind-config.yaml
#   ENDPOINTS=1 hack/ci/endpoints-ci-setup.sh
#   PROFILE=quickstart VALUES_FILE=hack/ci/endpoints-ci-values.yaml ./install.sh
#   ENDPOINTS=1 hack/ci/endpoints-live.sh
# Opt-in: it does nothing without ENDPOINTS=1, so a stray local run never touches the cluster you are on. The e2e workflow runs it on request.
#
# What it settles: the two tiny MCP endpoints (echo and other, each in endpoint-ci, with a header value from a Secret) are backends of the group `disputes`; the
# profile vMCP tools-disputes lists exactly the two tools its profile names, through a REAL tools/list and call; the shared vMCP lists none and refuses a call; the
# endpoint refuses a call with no header and with a wrong one; the header value is in no log line and in no object; the shared vMCP pod has no environment value that
# references the endpoint Secret; the answer of `kubectl auth can-i get secret/<header Secret>` for the shared vMCP's ServiceAccount is recorded (the remaining risk
# of ADR 0026 A3); a pod in `default` times out against the endpoint; the endpoint's ingress policy and the group's egress policy exist; every backend stays ready.
# Resources and prompts: the first live run found that a profile vMCP listed and read the resources and prompts of a backend that its profile does not list (the filter
# covers tools only), so the chart now forbids resource reads and prompt gets on a profile of an endpoint group; here they are checks.
# The last part is a SPIKE (ADR 0026, slice 2): what the vMCP does with the field `overrides` and with a redirect. Those lines say "observed" and are recorded for the
# diary; they are not pass or fail.
# It never prints a header value. Exit 1 when a check fails.
set -u
[ "${ENDPOINTS:-0}" = 1 ] || { echo "endpoints-live: set ENDPOINTS=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
# This script changes the cluster it runs on (a ClusterRoleBinding, a ConfigMap, a restart of two vMCPs, throwaway objects) and the cluster must be a CI cluster:
# the install used values (hack/ci/endpoints-ci-values.yaml) that break the agents' tool path. It refuses to run anywhere else: on GitHub Actions (GITHUB_ACTIONS=true),
# or when ENDPOINTS_CI_CONTEXT names the current kube context exactly, and only on a kind or k3d context.
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in
  kind-*|k3d-*) ;;
  *) echo "endpoints-live: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind or k3d context. Nothing was changed." >&2; exit 2;;
esac
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${ENDPOINTS_CI_CONTEXT:-}" != "$CTX_NOW" ]; then
  echo "endpoints-live: refusing to run on '$CTX_NOW': it is not a CI run (GITHUB_ACTIONS is not true) and ENDPOINTS_CI_CONTEXT does not name this context. This script changes the cluster; do not run it on a cluster you use. Nothing was changed." >&2
  exit 2
fi
MCPNS=${MCP_NAMESPACE:-mcp-tools}; ENS=endpoint-ci; GROUP=disputes; PROFILE=${EP_PROFILE:-disputes}
PF=""; PF2=""; PF3=""; PF4=""; TD=""
# undo what this script changed, on every way out
cleanup() {
  kill $PF $PF2 $PF3 $PF4 2>/dev/null
  [ -z "$TD" ] || rm -rf "$TD"
  $K delete virtualmcpserver tools-ovr tools-ovr2 probe-redir -n "$MCPNS" --ignore-not-found >/dev/null 2>&1
  $K delete mcpserverentry redir -n "$MCPNS" --ignore-not-found >/dev/null 2>&1
  $K delete mcpexternalauthconfig redir-noauth -n "$MCPNS" --ignore-not-found >/dev/null 2>&1
  $K delete mcpgroup probe -n "$MCPNS" --ignore-not-found >/dev/null 2>&1
  $K delete networkpolicy ci-probe-ingress -n "$ENS" --ignore-not-found >/dev/null 2>&1
  $K delete deployment,service redir sink -n "$ENS" --ignore-not-found >/dev/null 2>&1
  $K delete secret redir-auth -n "$MCPNS" --ignore-not-found >/dev/null 2>&1
  $K delete secret sink-expected -n "$ENS" --ignore-not-found >/dev/null 2>&1
  $K delete clusterrolebinding ci-jwks-anonymous --ignore-not-found >/dev/null 2>&1
  $K delete configmap ci-apiserver-ca -n "$MCPNS" --ignore-not-found >/dev/null 2>&1
  $K delete pod nettest -n default --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
obs() { printf '  observed: %s\n' "$1"; }

echo "# the endpoints are backends of the group, and the objects are as rendered"
VM=$($K get virtualmcpserver -n "$MCPNS" "tools-$PROFILE" -o json 2>/dev/null || echo '{}')
SH=$($K get virtualmcpserver -n "$MCPNS" tools -o json 2>/dev/null || echo '{}')
check "the vMCP tools-$PROFILE is on the group $GROUP" "$(jq -r '.spec.groupRef.name // "none"' <<<"$VM")" "$GROUP"
echo "       status of tools-$PROFILE (conditions left out): $(jq -c '.status|del(.conditions)' <<<"$VM" | cut -c1-900)"
check "tools-$PROFILE lists the backends echo and other as ready (status.discoveredBackends)" "$(jq -r '[.status.discoveredBackends[]?|select((.name=="echo" or .name=="other") and .status=="ready")|.name]|sort|join(",")' <<<"$VM")" "echo,other"
check "no condition DiscoveredAuthConfig-* of any vMCP is False" "$($K get virtualmcpserver -n "$MCPNS" -o json | jq '[.items[].status.conditions[]?|select((.type|startswith("DiscoveredAuthConfig-")) and .status=="False")]|length')" 0
check "the shared vMCP found no backend echo or other" "$(jq '[.status|.. |strings|select(.=="echo" or .=="other")]|length' <<<"$SH")" 0
check "the entries echo and other are in the group $GROUP, with a header from a Secret" "$($K get mcpserverentry -n "$MCPNS" echo other -o json | jq -r '[.items[]|(.spec.groupRef.name+":"+(.spec.headerForward.addHeadersFromSecret[0].valueSecretRef.name))]|sort|join(",")')" "$GROUP:echo-mcp-auth,$GROUP:other-mcp-auth"
check "the endpoint's ingress policy exists in its namespace" "$($K get networkpolicy openagentix-endpoint-echo -n "$ENS" -o json 2>/dev/null | jq -r '[.spec.ingress[0].from[]|.podSelector.matchLabels["toolhive-name"]]|join(",")')" "tools-$PROFILE"
check "the group's egress policy exists" "$($K get networkpolicy "openagentix-vmcp-egress-$GROUP" -n "$MCPNS" -o json 2>/dev/null | jq -r '.spec.podSelector.matchExpressions[0].values|join(",")')" "tools-$PROFILE"
SHP=$($K get pods -n "$MCPNS" -l app=virtualmcpserver,toolhive-name=tools -o json)
check "the shared vMCP pod exists (the control is not empty)" "$(jq '.items|length>0' <<<"$SHP")" true
check "no environment value of the shared vMCP pod points at a header Secret of an endpoint" "$(jq '[.items[].spec.containers[].env[]?|select((.valueFrom.secretKeyRef.name//"")|test("^(echo|other)-mcp-auth$"))]|length' <<<"$SHP")" 0
GP=$($K get pods -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" -o json)
check "the pod of the group's vMCP holds the header Secrets by reference, as environment values (positive control)" "$(jq '[.items[].spec.containers[].env[]?|select((.valueFrom.secretKeyRef.name//"")|test("^(echo|other)-mcp-auth$"))]|length>0' <<<"$GP")" true
SA=$(jq -r '.items[0].spec.serviceAccountName // ""' <<<"$SHP")
CAN=$($K auth can-i get "secret/echo-mcp-auth" -n "$MCPNS" --as="system:serviceaccount:$MCPNS:$SA" 2>/dev/null || true)
obs "kubectl auth can-i get secret/echo-mcp-auth -n $MCPNS, as the shared vMCP's ServiceAccount ($SA): '${CAN:-no answer}' (ADR 0026 A3 expects yes: the ToolHive operator gives every vMCP read access to Secrets in the tools namespace)"

echo "# the endpoint refuses a call without its header value, and with a wrong one"
PORT=$((20000 + RANDOM % 20000))
$K port-forward -n "$ENS" svc/echo "$PORT:8080" >/dev/null 2>&1 & PF=$!
sleep 3
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ep-live","version":"0"}}}'
check "the endpoint answers /readyz" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/readyz")" 200
check "/mcp without the header is refused (401)" "$(curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT" "http://127.0.0.1:$PORT/mcp")" 401
# the header goes to curl through a config file made by process substitution: the value is never an argument
ep_init() { curl -s -o /dev/null -w '%{http_code}' -K <(printf 'header = "Authorization: %s"\n' "$1") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT" "http://127.0.0.1:$PORT/mcp"; }
check "/mcp with a wrong header value is refused (401)" "$(ep_init 'Bearer not-the-value')" 401
check "/mcp with the other endpoint's value is refused (401)" "$(ep_init "$($K get secret -n "$MCPNS" other-mcp-auth -o jsonpath='{.data.value}' | base64 -d)")" 401
check "/mcp with the right value answers initialize (200)" "$(ep_init "$($K get secret -n "$MCPNS" echo-mcp-auth -o jsonpath='{.data.value}' | base64 -d)")" 200
kill $PF 2>/dev/null; PF=""

echo "# real calls through the gateways: the vMCPs trust the API server's own tokens in this job (hack/ci/endpoints-ci-values.yaml)"
$K get configmap kube-root-ca.crt -n "$MCPNS" -o json | jq --arg n ci-apiserver-ca '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:.metadata.namespace},data:{"ca.crt":.data["ca.crt"]}}' | $K apply -f - >/dev/null
$K create clusterrolebinding ci-jwks-anonymous --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated --dry-run=client -o yaml | $K apply -f - >/dev/null
for v in tools "tools-$PROFILE"; do $K rollout restart "deployment/$v" -n "$MCPNS" >/dev/null 2>&1; done
for v in tools "tools-$PROFILE"; do $K rollout status "deployment/$v" -n "$MCPNS" --timeout=180s >/dev/null 2>&1 || echo "       (vMCP $v: restart not confirmed)"; done
mcp_token() { $K create token default -n "$MCPNS" --audience "$1" --duration 10m 2>/dev/null; }
mcp_post() {  # mcp_post <port> <token file> <session id or -> <json>: prints the JSON-RPC answer (the data line of an event stream, or the body)
  local port=$1 tf=$2 sid=$3 body=$4 out hdr=()
  [ "$sid" = - ] || hdr=(-H "Mcp-Session-Id: $sid")
  out=$(curl -s -m 30 -D "$tf.h" -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' ${hdr[@]+"${hdr[@]}"} -d "$body" "http://127.0.0.1:$port/mcp" 2>/dev/null)
  if grep -q '^data:' <<<"$out"; then sed -n 's/^data: *//p' <<<"$out" | tail -1; else printf '%s' "$out"; fi
}
mcp_open() {  # mcp_open <port> <token file>: prints the session id
  mcp_post "$1" "$2" - '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ep-live","version":"0"}}}' >/dev/null
  local sid; sid=$(grep -i '^mcp-session-id:' "$2.h" | tr -d '\r' | awk '{print $2}')
  [ -z "$sid" ] || mcp_post "$1" "$2" "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  printf '%s' "${sid:--}"
}
mcp_call() {  # mcp_call <port> <token file> <session> <id> <method> <params json>
  mcp_post "$1" "$2" "$3" "{\"jsonrpc\":\"2.0\",\"id\":$4,\"method\":\"$5\",\"params\":$6}"
}
TD=$(mktemp -d)
GPORT=$((30000 + RANDOM % 10000)); SPORT=$((GPORT + 1)); XPORT=$((GPORT + 2))
$K port-forward -n "$MCPNS" "svc/vmcp-tools-$PROFILE" "$GPORT:4483" >/dev/null 2>&1 & PF2=$!
$K port-forward -n "$MCPNS" svc/vmcp-tools "$SPORT:4483" >/dev/null 2>&1 & PF3=$!
sleep 4
mcp_token "openagentix-vmcp-$PROFILE" > "$TD/group"; mcp_token openagentix-vmcp > "$TD/shared"
check "a token for the group's audience was made" "$([ -s "$TD/group" ] && echo yes || echo no)" yes
SID_G=-
for _ in $(seq 1 10); do SID_G=$(mcp_open $GPORT "$TD/group"); [ "$SID_G" != - ] && break; sleep 5; done
LIST_G=$(mcp_call $GPORT "$TD/group" "$SID_G" 2 tools/list '{}' | jq -r '[.result.tools[]?.name]|sort|join(" ")' 2>/dev/null)
check "tools/list on the group's vMCP lists the two tools of the profile, as <endpoint>_<tool>, and nothing from the other endpoint" "$LIST_G" "echo_echo echo_list_notes"
CALL=$(mcp_call $GPORT "$TD/group" "$SID_G" 3 tools/call '{"name":"echo_echo","arguments":{"text":"hello from the live check"}}')
check "a call of echo_echo through the group's vMCP reaches the endpoint with the header and answers" "$(jq -r '(.result.isError//false|tostring)+" "+([.result.content[]?.text]|join(" "))' <<<"$CALL" 2>/dev/null)" "false echo from echo: hello from the live check"
CALL=$(mcp_call $GPORT "$TD/group" "$SID_G" 4 tools/call '{"name":"echo_set_note","arguments":{"text":"x"}}')
check "a tool the endpoint has and the profile does not list (set_note) is refused" "$(jq -r '((.error!=null) or (.result.isError==true))|tostring' <<<"$CALL" 2>/dev/null)" true
CALL=$(mcp_call $GPORT "$TD/group" "$SID_G" 5 tools/call '{"name":"other_echo","arguments":{"text":"x"}}')
check "a tool of the other endpoint (in the group, not in the profile) is refused" "$(jq -r '((.error!=null) or (.result.isError==true))|tostring' <<<"$CALL" 2>/dev/null)" true
SID_S=$(mcp_open $SPORT "$TD/shared")
LIST_S=$(mcp_call $SPORT "$TD/shared" "$SID_S" 2 tools/list '{}')
check "the shared vMCP answers tools/list (the control is not empty: it lists tools)" "$(jq '[.result.tools[]?]|length>0' <<<"$LIST_S" 2>/dev/null)" true
check "tools/list on the shared vMCP lists no endpoint tool" "$(jq '[.result.tools[]?.name|select(test("^(echo|other)_"))]|length' <<<"$LIST_S" 2>/dev/null)" 0
SEEN_ECHO() { $K logs -n "$ENS" deploy/echo --tail=2000 2>/dev/null | grep -c '"event": "request"'; }
BEFORE=$(SEEN_ECHO)
CALL=$(mcp_call $SPORT "$TD/shared" "$SID_S" 3 tools/call '{"name":"echo_echo","arguments":{"text":"x"}}')
echo "       the shared vMCP answered: $(printf '%s' "$CALL" | cut -c1-200)"
check "a call of an endpoint tool through the shared vMCP is refused (an error, no result)" "$(jq -r '((.error!=null) or (.result.isError==true))|tostring' <<<"$CALL" 2>/dev/null)" true
sleep 2
check "and it never reached the endpoint (no new request in its log)" "$(( $(SEEN_ECHO) - BEFORE ))" 0
check "the endpoint saw its own header value on the calls through the group's vMCP (its log says presented=self)" "$($K logs -n "$ENS" deploy/echo --tail=2000 2>/dev/null | grep -c '"presented": "self"' | awk '{print ($1>0)?"yes":"no"}')" yes
check "every backend of the group's vMCP is still ready after the calls" "$($K get virtualmcpserver -n "$MCPNS" "tools-$PROFILE" -o json | jq -r '[.status.discoveredBackends[]?|select(.status!="ready")|.name]|join(",")')" ""

echo "# the header value is in no log and in no object"
LEAKS=0
for n in echo other; do
  V=$($K get secret -n "$MCPNS" "$n-mcp-auth" -o jsonpath='{.data.value}' | base64 -d); RAW=${V#Bearer }
  for p in $($K get pods -n "$MCPNS" -o name 2>/dev/null) ; do LEAKS=$((LEAKS + $($K logs -n "$MCPNS" "$p" --all-containers --tail=3000 2>/dev/null | grep -cF -e "$RAW"))); done
  for p in $($K get pods -n toolhive-system -o name 2>/dev/null) ; do LEAKS=$((LEAKS + $($K logs -n toolhive-system "$p" --all-containers --tail=3000 2>/dev/null | grep -cF -e "$RAW"))); done
  for p in $($K get pods -n "$ENS" -o name 2>/dev/null) ; do LEAKS=$((LEAKS + $($K logs -n "$ENS" "$p" --tail=3000 2>/dev/null | grep -cF -e "$RAW"))); done
  LEAKS=$((LEAKS + $($K get virtualmcpserver,mcpserverentry,mcpgroup,mcpexternalauthconfig,networkpolicy,configmap -A -o yaml 2>/dev/null | grep -cF -e "$RAW")))
  unset V RAW
done
check "the header values are in no log line of the vMCPs, the operator and the endpoints, and in no ToolHive object, policy or ConfigMap" "$LEAKS" 0

echo "# a pod in another namespace must not reach the endpoint (its ingress policy)"
$K delete pod nettest -n default --ignore-not-found >/dev/null 2>&1
CODE=$($K run nettest -n default --image=curlimages/curl:8.10.1 --restart=Never --rm -i --quiet --command -- curl -s -m 8 -o /dev/null -w '%{http_code}' "http://echo.$ENS.svc.cluster.local:8080/readyz" 2>/dev/null | tail -1)
case "$CODE" in
  000|"") ok "a pod in default timed out against the endpoint (the ingress policy is enforced here)";;
  *) bad "a pod in default reached the endpoint (HTTP $CODE)" "the network plugin of this cluster does not enforce ingress policy, or the policy does not select the pod. The header value is then the only check; do not read this as a pass.";;
esac

echo "# resources and prompts: the profile filter covers tools only, so the chart forbids resource reads and prompt gets on a profile of an endpoint group"
# The first live run of this slice found that, without the forbids, a profile vMCP listed and read the resources and prompts of the endpoint `other`, which the
# profile does not list. Now the profile offers tools only.
RES=$(mcp_call $GPORT "$TD/group" "$SID_G" 20 resources/list '{}' 2>/dev/null); PRM=$(mcp_call $GPORT "$TD/group" "$SID_G" 21 prompts/list '{}' 2>/dev/null)
obs "resources/list through tools-$PROFILE: $(printf '%s' "$RES" | jq -c '(.error // [.result.resources[]?.uri])' 2>/dev/null | cut -c1-300)"
obs "prompts/list through tools-$PROFILE: $(printf '%s' "$PRM" | jq -c '(.error // [.result.prompts[]?.name])' 2>/dev/null | cut -c1-300)"
check "resources/list through the group's vMCP shows no resource of the endpoint other (nor of echo)" "$(printf '%s' "$RES" | jq -r '[.result.resources[]?.uri]|length' 2>/dev/null)" 0
check "prompts/list through the group's vMCP shows no prompt of the endpoint other (nor of echo)" "$(printf '%s' "$PRM" | jq -r '[.result.prompts[]?.name]|length' 2>/dev/null)" 0
RD=$(mcp_call $GPORT "$TD/group" "$SID_G" 22 resources/read '{"uri":"echo://other/note"}' 2>/dev/null)
check "resources/read of a resource of the endpoint other is refused (no contents)" "$(printf '%s' "$RD" | jq -r '([.result.contents[]?]|length>0)|not' 2>/dev/null)" true
PG=$(mcp_call $GPORT "$TD/group" "$SID_G" 23 prompts/get '{"name":"other_greet-other"}' 2>/dev/null)
check "prompts/get of a prompt of the endpoint other is refused (no messages)" "$(printf '%s' "$PG" | jq -r '([.result.messages[]?]|length>0)|not' 2>/dev/null)" true
obs "resources/read answered: $(printf '%s' "$RD" | cut -c1-200); prompts/get answered: $(printf '%s' "$PG" | cut -c1-200)"
kill $PF2 $PF3 2>/dev/null; PF2=""; PF3=""

echo "# SPIKE (observations): the field overrides of the VirtualMCPServer aggregation (a tool's name and description)"
# Two throwaway vMCPs on the group, copies of tools-$PROFILE: A keeps the profile's filter and renames the tool echo; B has no filter and no deny default, only the rename.
# They need a policy of their own: the endpoint's policy admits the chart's vMCPs only.
$K apply -f - >/dev/null 2>&1 <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: ci-probe-ingress, namespace: $ENS}
spec:
  podSelector: {matchExpressions: [{key: app, operator: In, values: [echo, other]}]}
  policyTypes: [Ingress]
  ingress:
    - ports: [{protocol: TCP, port: 8080}]
      from:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: $MCPNS}}
          podSelector: {matchLabels: {app: virtualmcpserver}, matchExpressions: [{key: toolhive-name, operator: In, values: [tools-ovr, tools-ovr2]}]}
YAML
ovr_probe() {  # ovr_probe <vMCP name> <label> <jq filter that edits the copy's spec>
  local n=$1 label=$2 edit=$3 port=$4 sid raw
  $K get virtualmcpserver "tools-$PROFILE" -n "$MCPNS" -o json | jq --arg n "$n" "{apiVersion,kind,metadata:{name:\$n,namespace:.metadata.namespace},spec:(.spec|$edit)}" | $K apply -f - >/dev/null 2>&1 \
    || { obs "$label: the probe vMCP $n could not be applied"; return 0; }
  for _ in $(seq 1 40); do $K get deployment "$n" -n "$MCPNS" >/dev/null 2>&1 && break; sleep 3; done
  $K rollout status "deployment/$n" -n "$MCPNS" --timeout=180s >/dev/null 2>&1 || true
  $K wait "virtualmcpserver/$n" -n "$MCPNS" --for=condition=Ready --timeout=120s >/dev/null 2>&1 || true
  $K port-forward -n "$MCPNS" "svc/vmcp-$n" "$port:4483" >/dev/null 2>&1 & PF4=$!
  sleep 4
  sid=-
  for _ in $(seq 1 8); do sid=$(mcp_open "$port" "$TD/group"); [ "$sid" != - ] && break; sleep 5; done
  raw=$(mcp_call "$port" "$TD/group" "$sid" 2 tools/list '{}' 2>/dev/null)
  obs "$label: tools/list: $(printf '%s' "$raw" | jq -c '[.result.tools[]?|{name,description}]' 2>/dev/null | cut -c1-500) (backends: $($K get virtualmcpserver "$n" -n "$MCPNS" -o json 2>/dev/null | jq -c '[.status.discoveredBackends[]?|(.name+"="+.status)]' 2>/dev/null); session $([ "$sid" = - ] && echo none || echo open); raw: $(printf '%s' "$raw" | cut -c1-140))"
  kill $PF4 2>/dev/null; PF4=""
}
ovr_probe tools-ovr "A (the profile's filter [echo] and overrides echo -> renamed_echo)" '.config.aggregation.tools=[{workload:"echo",filter:["echo"],overrides:{echo:{name:"renamed_echo",description:"renamed by the CI probe"}}}]' "$XPORT"
ovr_probe tools-ovr2 "B (no filter, no deny default, overrides echo -> renamed_echo)" '.config.aggregation|=(del(.defaultToolVisibility)|.tools=[{workload:"echo",overrides:{echo:{name:"renamed_echo",description:"renamed by the CI probe"}}}])' "$((XPORT + 1))"

echo "# SPIKE (observations): a redirect from a backend (the header is the Authorization header of the entry)"
RV="Bearer $(openssl rand -hex 24)"
$K create secret generic redir-auth -n "$MCPNS" --from-file=value=<(printf '%s' "$RV") --dry-run=client -o yaml | $K apply -f - >/dev/null 2>&1
$K create secret generic sink-expected -n "$ENS" --from-file=expected=<(printf '%s' "not-redir-$(openssl rand -hex 8)") --from-file=redir=<(printf '%s' "$RV") --dry-run=client -o yaml | $K apply -f - >/dev/null 2>&1
unset RV
for spec in "sink|echo|/etc/echo/auth/expected|redir=/etc/echo/auth/redir||" "redir|redirect||||http://sink.$ENS.svc.cluster.local:8080/mcp"; do
  IFS='|' read -r NM MODE EXP OTH _ TO <<<"$spec"
  $K apply -f - >/dev/null 2>&1 <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: $NM, namespace: $ENS, labels: {app: $NM}}
spec:
  replicas: 1
  selector: {matchLabels: {app: $NM}}
  template:
    metadata: {labels: {app: $NM}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: echo
          image: python:3.12.7-slim
          command: ["python3", "-I", "/app/echo-mcp.py"]
          env:
            - {name: ECHO_NAME, value: $NM}
            - {name: ECHO_MODE, value: $MODE}
            - {name: ECHO_EXPECTED_FILE, value: "$EXP"}
            - {name: ECHO_OTHER_FILES, value: "$OTH"}
            - {name: ECHO_REDIRECT_TO, value: "$TO"}
            - {name: PYTHONDONTWRITEBYTECODE, value: "1"}
          ports: [{name: http, containerPort: 8080}]
          readinessProbe: {httpGet: {path: /readyz, port: http}, periodSeconds: 3}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          volumeMounts:
            - {name: src, mountPath: /app, readOnly: true}
            - {name: auth, mountPath: /etc/echo/auth, readOnly: true}
      volumes:
        - {name: src, configMap: {name: echo-mcp-src}}
        - {name: auth, secret: {secretName: sink-expected, defaultMode: 0440}}
---
apiVersion: v1
kind: Service
metadata: {name: $NM, namespace: $ENS, labels: {app: $NM}}
spec:
  selector: {app: $NM}
  ports: [{name: http, port: 8080, targetPort: http}]
YAML
done
$K rollout status deployment/sink -n "$ENS" --timeout=120s >/dev/null 2>&1; $K rollout status deployment/redir -n "$ENS" --timeout=120s >/dev/null 2>&1
$K apply -f - >/dev/null 2>&1 <<YAML
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPGroup
metadata: {name: probe, namespace: $MCPNS}
spec: {description: "CI probe: a redirect"}
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPExternalAuthConfig
metadata: {name: redir-noauth, namespace: $MCPNS}
spec: {type: unauthenticated}
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPServerEntry
metadata: {name: redir, namespace: $MCPNS}
spec:
  groupRef: {name: probe}
  remoteUrl: http://redir.$ENS.svc.cluster.local:8080/mcp
  transport: streamable-http
  allowPrivateEndpoint: true
  externalAuthConfigRef: {name: redir-noauth}
  headerForward:
    addHeadersFromSecret:
      - {headerName: Authorization, valueSecretRef: {name: redir-auth, key: value}}
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: VirtualMCPServer
metadata: {name: probe-redir, namespace: $MCPNS}
spec:
  groupRef: {name: probe}
  config:
    aggregation: {conflictResolution: prefix, conflictResolutionConfig: {prefixFormat: "{workload}_"}}
  incomingAuth: {type: anonymous}
  outgoingAuth: {source: discovered}
YAML
$K rollout status deployment/probe-redir -n "$MCPNS" --timeout=180s >/dev/null 2>&1 || true
sleep 20
obs "the vMCP probe-redir, backend redir: $($K get virtualmcpserver probe-redir -n "$MCPNS" -o json 2>/dev/null | jq -c '[.status.discoveredBackends[]?|{name,status,message:(.message|tostring|.[0:120])}]' 2>/dev/null)"
obs "requests that reached the redirecting server (redir), by what its Authorization header was (other = a value this server does not know, none = no header): $($K logs -n "$ENS" deploy/redir --tail=500 2>/dev/null | jq -rs '[.[]|select(.event=="request")|.presented]|group_by(.)|map(.[0]+"="+(length|tostring))|join(", ")' 2>/dev/null)"
obs "requests that reached the redirect target (sink), by what the Authorization header was (redir = the value the vMCP sends to redir): $($K logs -n "$ENS" deploy/sink --tail=500 2>/dev/null | jq -rs '[.[]|select(.event=="request")|.presented]|group_by(.)|map(.[0]+"="+(length|tostring))|join(", ")' 2>/dev/null)"
obs "a custom header on a redirect: not tested (an entry of mcp.endpoints has one header; the field headerForward is not rendered with more)"

echo
echo "endpoints-live: passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
