#!/usr/bin/env bash
# Live proof of tool server accounts (ADR 0031, slice 3) on a cluster that ./install.sh set up with hack/ci/tool-accounts-ci-values.yaml (quick start, QUICKSTART_BYO=1):
#   kind create cluster --name openagentix --config hack/kind-config.yaml
#   ENDPOINTS=1 hack/ci/endpoints-ci-setup.sh
#   TOOL_ACCOUNTS_LIVE=1 hack/ci/tool-accounts-live.sh prepare
#   QUICKSTART_BYO=1 PROFILE=quickstart VALUES_FILE=hack/ci/tool-accounts-ci-values.yaml ./install.sh                                    then   ... off
#   same, VALUES_FILE="hack/ci/tool-accounts-ci-values.yaml components/tools/own-service-accounts-values.yaml"                         then   ... on
#   same without the second file (install.sh must REFUSE: the release has the switch on)                                              then   ... refused
#   same without the second file and ALLOW_TOOL_SECRET_READ=1                                                                         then   ... back-off
# Opt-in: it does nothing without TOOL_ACCOUNTS_LIVE=1. It refuses any cluster that is not a kind or k3d CI cluster. The e2e workflow runs it on request (input tool_accounts).
# The five tool servers that these values render: tools (shared group), tools-lookup and tools-lookup-workload (shared group), tools-disputes (group disputes: the endpoint
# echo with a header Secret, and the knowledge base and notify mirrors) and tools-rca (group diagnostics: cluster-read with its bearer value, and the two mirrors).
# Phases: prepare (the CA ConfigMap and the JWKS binding that make the tool servers trust the API server's tokens, before the install); off (the old behaviour: the operator's accounts
# can read Secrets); on (every account is the chart's, none can read a Secret or create a pod, a pod as an account gets 403, every backend is ready on every tool server, the install
# check ran, no forbidden line in a tool server log, a call through each group reaches its endpoint with its header); refused (the run that would turn the switch off was refused and
# nothing changed); back-off (the switch was turned off on purpose: the old behaviour is back).
# It never prints a header or bearer value. Exit 1 when a check fails.
set -u
[ "${TOOL_ACCOUNTS_LIVE:-0}" = 1 ] || { echo "tool-accounts-live: set TOOL_ACCOUNTS_LIVE=1 to run this against the current cluster (it is opt-in)"; exit 0; }
PHASE=${1:-}
case "$PHASE" in prepare|off|on|refused|back-off) ;; *) echo "tool-accounts-live: usage: tool-accounts-live.sh prepare|off|on|refused|back-off" >&2; exit 2;; esac
K=${KUBECTL:-kubectl}
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in
  kind-*|k3d-*) ;;
  *) echo "tool-accounts-live: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind or k3d context. Nothing was changed." >&2; exit 2;;
esac
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${TOOL_ACCOUNTS_CI_CONTEXT:-}" != "$CTX_NOW" ]; then
  echo "tool-accounts-live: refusing to run on '$CTX_NOW': it is not a CI run (GITHUB_ACTIONS is not true) and TOOL_ACCOUNTS_CI_CONTEXT does not name this context. Nothing was changed." >&2
  exit 2
fi
MCPNS=${MCP_NAMESPACE:-mcp-tools}; ENS=endpoint-ci
SERVERS="tools tools-lookup tools-lookup-workload tools-disputes tools-rca"
PF=""; PF2=""; PF3=""; TD=""
cleanup() { kill $PF $PF2 $PF3 2>/dev/null; [ -z "$TD" ] || rm -rf "$TD"; $K delete pod -n "$MCPNS" -l ta-live=probe --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
obs() { printf '  observed: %s\n' "$1"; }
fin() { echo; echo "tool-accounts-live ($PHASE): passed=$PASS failed=$FAIL"; [ "$FAIL" = 0 ]; exit $?; }

if [ "$PHASE" = prepare ]; then
  echo "# prepare: the tool gateways trust the API server's own ServiceAccount tokens in this job (hack/ci/tool-accounts-ci-values.yaml)"
  $K get namespace "$MCPNS" >/dev/null 2>&1 || $K create namespace "$MCPNS" >/dev/null
  $K get configmap kube-root-ca.crt -n "$MCPNS" -o json | jq --arg n ci-apiserver-ca '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:.metadata.namespace},data:{"ca.crt":.data["ca.crt"]}}' | $K apply -f - >/dev/null
  $K create clusterrolebinding ci-jwks-anonymous --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated --dry-run=client -o yaml | $K apply -f - >/dev/null
  check "the CA ConfigMap exists" "$($K get configmap ci-apiserver-ca -n "$MCPNS" -o json | jq -r '.data["ca.crt"]|length>0')" true
  fin
fi

VMJ=$($K get virtualmcpserver -n "$MCPNS" -o json 2>/dev/null || echo '{"items":[]}')
echo "# the tool servers of this install"
check "the five tool servers are there" "$(jq -r '[.items[].metadata.name]|sort|join(" ")' <<<"$VMJ")" "$(printf '%s\n' $SERVERS | sort | tr '\n' ' ' | sed 's/ $//')"
op_objects() { local n=$1 kind c=0; for kind in serviceaccount role rolebinding; do $K get "$kind" "$n-vmcp" -n "$MCPNS" >/dev/null 2>&1 && c=$((c+1)); done; echo "$c"; }
backends_ready() {   # backends_ready <tool server> <expected backends, space separated>: every expected backend is in status.discoveredBackends with status ready, and none is not ready
  local n=$1 want=$2 j
  j=$($K get virtualmcpserver "$n" -n "$MCPNS" -o json 2>/dev/null || echo '{}')
  check "$n: every backend is ready ($want)" "$(jq -r --arg w "$want" '(.status.discoveredBackends // []) as $d | ($w|split(" ")) as $want | [$want[] as $b | select(($d|map(select(.name==$b and .status=="ready"))|length)==0)|$b]|join(",")' <<<"$j")+$(jq -r '[(.status.discoveredBackends // [])[]|select(.status!="ready")|.name]|join(",")' <<<"$j")" "+"
}
wait_backends() { local n; for n in $SERVERS; do for _ in $(seq 1 40); do [ "$($K get virtualmcpserver "$n" -n "$MCPNS" -o json 2>/dev/null | jq -r '[.status.discoveredBackends[]?|select(.status!="ready")]|length' 2>/dev/null)" = 0 ] && break; sleep 3; done; done; }
all_backends() {
  wait_backends
  backends_ready tools "osv knowledge delivery"
  backends_ready tools-lookup "osv knowledge delivery"
  backends_ready tools-lookup-workload "osv knowledge delivery"
  backends_ready tools-disputes "echo knowledge-disputes delivery-disputes"
  backends_ready tools-rca "cluster-read knowledge-diagnostics delivery-diagnostics"
}
no_forbidden() {
  local n lines
  for n in $SERVERS; do
    lines=$($K logs -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=$n" --all-containers --tail=-1 2>/dev/null | grep -ciE 'forbidden|cannot (get|list|watch)|rbac:' || true)
    check "$n: no forbidden or RBAC line in its log" "$lines" 0
  done
}

if [ "$PHASE" = off ]; then
  echo "# off: the old behaviour (the operator makes the accounts, and they can read Secrets)"
  for n in $SERVERS; do
    check "$n: spec.serviceAccount is not set" "$(jq -r --arg n "$n" '.items[]|select(.metadata.name==$n)|.spec.serviceAccount // "none"' <<<"$VMJ")" none
    check "$n: the operator made its ServiceAccount, Role and RoleBinding $n-vmcp" "$(op_objects "$n")" 3
    check "$n: its account can get secrets (the reach ADR 0031 removes)" "$($K auth can-i get secrets -n "$MCPNS" --as="system:serviceaccount:$MCPNS:$n-vmcp" 2>/dev/null || true)" yes
  done
  check "the chart wrote no account of its own (no ServiceAccount openagentix-tools* in $MCPNS)" "$($K get serviceaccount -n "$MCPNS" -o name | grep -c 'openagentix-tools' || true)" 0
  if [ -n "${TA_INSTALL_LOG:-}" ] && [ -f "$TA_INSTALL_LOG" ]; then
    check "install.sh warned that every tool server can read the header Secrets (names only; the installer and Helm each print it)" "$(grep -c 'WARNING: mcp.virtual.ownServiceAccounts is false' "$TA_INSTALL_LOG" | awk '{print ($1>=1)?"yes":"no"}')/$(grep -c 'echo-mcp-auth' "$TA_INSTALL_LOG" | awk '{print ($1>=1)?"yes":"no"}')" "yes/yes"
    check "install.sh did not run the account check (the switch is off)" "$(grep -c 'tool server accounts:' "$TA_INSTALL_LOG")" 0
  fi
  all_backends
  fin
fi

if [ "$PHASE" = refused ]; then
  echo "# refused: the run without the switch was stopped before it changed anything"
  if [ -n "${TA_INSTALL_LOG:-}" ] && [ -f "$TA_INSTALL_LOG" ]; then
    check "install.sh said it refuses to turn the switch off, and how to override it" "$(grep -c 'turn mcp.virtual.ownServiceAccounts off' "$TA_INSTALL_LOG")/$(grep -c 'ALLOW_TOOL_SECRET_READ=1' "$TA_INSTALL_LOG")" "1/1"
    check "it said so before the chart was applied (no helm upgrade line)" "$(grep -c 'helm upgrade --install openagentix' "$TA_INSTALL_LOG")" 0
  fi
  for n in $SERVERS; do
    check "$n: still on the chart's account" "$(jq -r --arg n "$n" '.items[]|select(.metadata.name==$n)|.spec.serviceAccount // "none"' <<<"$VMJ")" "openagentix-$n"
  done
  fin
fi

if [ "$PHASE" = back-off ]; then
  echo "# back-off: the switch was turned off on purpose (ALLOW_TOOL_SECRET_READ=1): the old behaviour is back"
  for n in $SERVERS; do
    check "$n: spec.serviceAccount is not set again" "$(jq -r --arg n "$n" '.items[]|select(.metadata.name==$n)|.spec.serviceAccount // "none"' <<<"$VMJ")" none
  done
  sleep 20
  for n in $SERVERS; do
    check "$n: the operator made its ServiceAccount, Role and RoleBinding $n-vmcp again" "$(op_objects "$n")" 3
    check "$n: its account can get secrets again" "$($K auth can-i get secrets -n "$MCPNS" --as="system:serviceaccount:$MCPNS:$n-vmcp" 2>/dev/null || true)" yes
    check "$n: the Deployment runs as $n-vmcp" "$($K get deployment "$n" -n "$MCPNS" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)" "$n-vmcp"
  done
  if [ -n "${TA_INSTALL_LOG:-}" ] && [ -f "$TA_INSTALL_LOG" ]; then
    check "install.sh printed the warning that follows from ALLOW_TOOL_SECRET_READ=1" "$(grep -c 'turning off mcp.virtual.ownServiceAccounts' "$TA_INSTALL_LOG")" 1
  fi
  all_backends
  fin
fi

# ---- on ----
echo "# on: every tool server runs under an account of the chart"
for n in $SERVERS; do
  check "$n: spec.serviceAccount is openagentix-$n" "$(jq -r --arg n "$n" '.items[]|select(.metadata.name==$n)|.spec.serviceAccount // "none"' <<<"$VMJ")" "openagentix-$n"
  check "$n: the Deployment runs as that account" "$($K get deployment "$n" -n "$MCPNS" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null)" "openagentix-$n"
  check "$n: the chart's ServiceAccount, Role and RoleBinding exist" "$(for kind in serviceaccount role rolebinding; do $K get "$kind" "openagentix-$n" -n "$MCPNS" >/dev/null 2>&1 && echo y; done | wc -l | tr -d ' ')" 3
  check "$n: its Role has no rule on secrets or on a wildcard" "$($K get role "openagentix-$n" -n "$MCPNS" -o json | jq '[.rules[]|select((.resources|index("secrets")!=null) or (.resources|index("*")!=null))]|length')" 0
  check "$n: the operator's $n-vmcp ServiceAccount, Role and RoleBinding were deleted by install.sh" "$(op_objects "$n")" 0
done
if [ -n "${TA_INSTALL_LOG:-}" ] && [ -f "$TA_INSTALL_LOG" ]; then
  echo "# the install check ran and passed"
  check "install.sh printed the result line for 5 tool servers" "$(grep -c 'tool server accounts: 5 tool server(s) run under accounts of the chart' "$TA_INSTALL_LOG")" 1
  check "install.sh ran can-i as each of the five accounts and found no right (one line each)" "$(grep -c 'no right on Secrets, and none to create pods, StatefulSets or Deployments' "$TA_INSTALL_LOG")" 5
  check "install.sh printed no ERROR line about an account" "$(grep -c 'ERROR: the account' "$TA_INSTALL_LOG")" 0
  check "install.sh read the backends of every tool server (the ADR 0026 A4 check, once per tool server)" "$(grep -c 'every backend of its group is ready' "$TA_INSTALL_LOG" | awk '{print ($1>=5)?"yes":"no"}')" yes
fi

echo "# every backend is ready on every tool server (the knowledge base mirror, notify, cluster-read and the endpoint included)"
all_backends

echo "# as each account: no right on Secrets, none to create a pod, a StatefulSet or a Deployment"
for n in $SERVERS; do
  SAS="system:serviceaccount:$MCPNS:openagentix-$n"
  for q in "get secrets" "list secrets" "watch secrets" "get secrets/echo-mcp-auth" "create pods" "create statefulsets.apps" "create deployments.apps" "create pods --subresource=exec" "create pods --subresource=attach"; do
    # shellcheck disable=SC2086   # $q is a verb, a resource and maybe a flag
    check "openagentix-$n may not: $q" "$($K auth can-i $q -n "$MCPNS" --as="$SAS" 2>/dev/null || true)" no
  done
  # shellcheck disable=SC2086
  check "openagentix-$n may (positive control): list mcpserverentries" "$($K auth can-i list mcpserverentries.toolhive.stacklok.dev -n "$MCPNS" --as="$SAS" 2>/dev/null || true)" yes
done
check "the chart's accounts in $MCPNS are exactly the five (the loop above covered all of them)" "$($K get serviceaccount -n "$MCPNS" -o name | grep -c 'openagentix-tools')" 5

echo "# a pod that runs as an account gets 403 on a Secret, and 200 on a ConfigMap (so the 403 is not a broken token)"
probe_pod() {  # probe_pod <account>: prints the HTTP codes of three reads with the account's own token
  local sa=$1 name="ta-probe-${1#openagentix-}" script out
  script='T=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); C=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt; B=https://kubernetes.default.svc/api/v1/namespaces/'"$MCPNS"'; for p in secrets/echo-mcp-auth secrets configmaps/kube-root-ca.crt; do printf "%s " "$(curl -s -m 10 -o /dev/null -w %{http_code} --cacert $C -H "Authorization: Bearer $T" $B/$p)"; done; echo'
  $K delete pod "$name" -n "$MCPNS" --ignore-not-found --wait=true >/dev/null 2>&1
  # a pod that runs to the end and a read of its log: an attached run loses the first lines of a short pod
  $K run "$name" -n "$MCPNS" -l ta-live=probe --image=curlimages/curl:8.10.1 --restart=Never \
    --overrides "$(jq -cn --arg sa "$sa" --arg name "$name" --arg s "$script" '{spec:{serviceAccountName:$sa,containers:[{name:$name,image:"curlimages/curl:8.10.1",command:["sh","-c",$s],securityContext:{allowPrivilegeEscalation:false,capabilities:{drop:["ALL"]},runAsNonRoot:true,runAsUser:100,seccompProfile:{type:"RuntimeDefault"}}}]}}')" >/dev/null 2>&1
  for _ in $(seq 1 40); do case "$($K get pod "$name" -n "$MCPNS" -o jsonpath='{.status.phase}' 2>/dev/null)" in Succeeded|Failed) break;; esac; sleep 2; done
  out=$($K logs "$name" -n "$MCPNS" 2>/dev/null | tail -1)
  $K delete pod "$name" -n "$MCPNS" --ignore-not-found --wait=false >/dev/null 2>&1
  printf '%s' "$out"
}
for n in tools-disputes tools-rca tools; do
  check "a pod as openagentix-$n: GET the Secret echo-mcp-auth, GET the list of Secrets, GET a ConfigMap" "$(probe_pod "openagentix-$n" | tr -s ' ' | sed 's/ $//')" "403 403 200"
done

echo "# no forbidden line in the log of any tool server"
no_forbidden

echo "# real calls through the groups (the tool servers trust the API server's own tokens in this job)"
# As hack/ci/endpoints-live.sh does: restart the tool servers once the CA ConfigMap and the JWKS binding are there, so each starts with a fresh fetch of the keys.
$K get configmap kube-root-ca.crt -n "$MCPNS" -o json | jq --arg n ci-apiserver-ca '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:.metadata.namespace},data:{"ca.crt":.data["ca.crt"]}}' | $K apply -f - >/dev/null
for n in $SERVERS; do $K rollout restart "deployment/$n" -n "$MCPNS" >/dev/null 2>&1; done
for n in $SERVERS; do $K rollout status "deployment/$n" -n "$MCPNS" --timeout=240s >/dev/null 2>&1 || echo "       (tool server $n: restart not confirmed)"; done
mcp_token() { $K create token default -n "$MCPNS" --audience "$1" --duration 10m 2>/dev/null; }
mcp_post() {  # mcp_post <port> <token file> <session id or -> <json>
  local port=$1 tf=$2 sid=$3 body=$4 out hdr=()
  [ "$sid" = - ] || hdr=(-H "Mcp-Session-Id: $sid")
  out=$(curl -s -m 30 -D "$tf.h" -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' ${hdr[@]+"${hdr[@]}"} -d "$body" "http://127.0.0.1:$port/mcp" 2>/dev/null)
  if grep -q '^data:' <<<"$out"; then sed -n 's/^data: *//p' <<<"$out" | tail -1; else printf '%s' "$out"; fi
}
mcp_open() {
  mcp_post "$1" "$2" - '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ta-live","version":"0"}}}' >/dev/null
  local sid; sid=$(grep -i '^mcp-session-id:' "$2.h" | tr -d '\r' | awk '{print $2}')
  [ -z "$sid" ] || mcp_post "$1" "$2" "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  printf '%s' "${sid:--}"
}
mcp_call() { mcp_post "$1" "$2" "$3" "{\"jsonrpc\":\"2.0\",\"id\":$4,\"method\":\"$5\",\"params\":$6}"; }
sess_debug() {  # sess_debug <port> <token file> <tool server>: why no session opened (a status line, the start of the body, the end of the log; never a token)
  [ "$SID" = - ] || return 0
  echo "       no session on $3: $(curl -s -m 20 -i -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$2")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"ta-live","version":"0"}}}' "http://127.0.0.1:$1/mcp" 2>&1 | tr "\r\n" "  " | cut -c1-900)"
  $K logs -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=$3" --all-containers --tail=15 2>/dev/null | cut -c1-260 | sed 's/^/       | /'
}
TD=$(mktemp -d)
P1=$((20000 + RANDOM % 10000)); P2=$((P1 + 1)); P3=$((P1 + 2))
$K port-forward -n "$MCPNS" svc/vmcp-tools-disputes "$P1:4483" >/dev/null 2>&1 & PF=$!
$K port-forward -n "$MCPNS" svc/vmcp-tools-rca "$P2:4483" >/dev/null 2>&1 & PF2=$!
$K port-forward -n "$MCPNS" svc/vmcp-tools-lookup "$P3:4483" >/dev/null 2>&1 & PF3=$!
sleep 4
mcp_token openagentix-vmcp-disputes > "$TD/d"; mcp_token openagentix-vmcp-rca > "$TD/r"; mcp_token openagentix-vmcp-lookup > "$TD/l"
SID=-; for _ in $(seq 1 12); do SID=$(mcp_open $P1 "$TD/d"); [ "$SID" != - ] && break; sleep 5; done; sess_debug $P1 "$TD/d" tools-disputes
LIST=$(mcp_call $P1 "$TD/d" "$SID" 2 tools/list '{}' | jq -r '[.result.tools[]?.name]|sort|join(" ")' 2>/dev/null)
check "group disputes: tools/list lists the endpoint, the knowledge base mirror and the notify mirror tools of the profile" "$LIST" "delivery-disputes_notify_list_destinations echo_echo echo_list_notes knowledge-disputes_kb_list_collections"
SEEN() { $K logs -n "$ENS" deploy/echo --tail=2000 2>/dev/null | grep -c '"presented": "self"'; }
BEFORE=$(SEEN)
CALL=$(mcp_call $P1 "$TD/d" "$SID" 3 tools/call '{"name":"echo_echo","arguments":{"text":"tool accounts"}}')
check "group disputes: a call of echo_echo reaches the endpoint and answers" "$(jq -r '(.result.isError//false|tostring)+" "+([.result.content[]?.text]|join(" "))' <<<"$CALL" 2>/dev/null)" "false echo from echo: tool accounts"
sleep 2
check "group disputes: the endpoint saw its own header value on that call (its log says presented=self)" "$(( $(SEEN) - BEFORE ))" 1
CALL=$(mcp_call $P1 "$TD/d" "$SID" 4 tools/call '{"name":"knowledge-disputes_kb_list_collections","arguments":{}}')
check "group disputes: a call through the knowledge base mirror reaches the knowledge base and is not an error" "$(jq -r '(.error==null and (.result.isError//false)==false)|tostring' <<<"$CALL" 2>/dev/null)" true
CALL=$(mcp_call $P1 "$TD/d" "$SID" 5 tools/call '{"name":"delivery-disputes_notify_list_destinations","arguments":{}}')
obs "group disputes: a call through the notify mirror answered: $(printf '%s' "$CALL" | cut -c1-200)"
check "group disputes: a call through the notify mirror reaches notify (an answer, not a transport error)" "$(jq -r '((.result != null) or ((.error.message // "")|test("denied|not found|unknown")|not))|tostring' <<<"$CALL" 2>/dev/null)" true
SID=-; for _ in $(seq 1 12); do SID=$(mcp_open $P2 "$TD/r"); [ "$SID" != - ] && break; sleep 5; done; sess_debug $P2 "$TD/r" tools-rca
CALL=$(mcp_call $P2 "$TD/r" "$SID" 3 tools/call '{"name":"cluster-read_pods_list_in_namespace","arguments":{"namespace":"kagent"}}')
check "group diagnostics: a call through tools-rca reaches cluster-read with its bearer value and answers (the server refuses a call without it)" "$(jq -r '(.result.isError//false|tostring)+" "+([.result.content[]?.text]|join(" ")|length>0|tostring)' <<<"$CALL" 2>/dev/null)" "false true"
CALL=$(mcp_call $P2 "$TD/r" "$SID" 4 tools/call '{"name":"knowledge-diagnostics_kb_list_collections","arguments":{}}')
check "group diagnostics: a call through the knowledge base mirror of the group is not an error" "$(jq -r '(.error==null and (.result.isError//false)==false)|tostring' <<<"$CALL" 2>/dev/null)" true
SID=-; for _ in $(seq 1 12); do SID=$(mcp_open $P3 "$TD/l"); [ "$SID" != - ] && break; sleep 5; done; sess_debug $P3 "$TD/l" tools-lookup
LIST=$(mcp_call $P3 "$TD/l" "$SID" 2 tools/list '{}' | jq -r '[.result.tools[]?.name]|sort|join(" ")' 2>/dev/null)
check "shared group: tools/list on the profile lookup lists its one tool" "$LIST" "osv_query_vulnerability"
echo "# after the calls: every backend still ready, still no forbidden line"
all_backends
no_forbidden

echo "# the header and bearer values are in no log line of a tool server, in no ConfigMap and in no ToolHive object"
for sk in "echo-mcp-auth value" "diagnostics-bearer-cluster-read authorization"; do
  LEAKS=0
  V=$($K get secret -n "$MCPNS" "${sk% *}" -o jsonpath="{.data.${sk#* }}" 2>/dev/null | base64 -d); RAW=${V#Bearer }
  check "${sk% *}: the Secret has a value (the leak check below is not empty)" "$([ "${#RAW}" -ge 16 ] && echo yes || echo no)" yes
  if [ "${#RAW}" -ge 16 ]; then
    for p in $($K get pods -n "$MCPNS" -o name 2>/dev/null); do LEAKS=$((LEAKS + $($K logs -n "$MCPNS" "$p" --all-containers --tail=3000 2>/dev/null | grep -cF -e "$RAW"))); done
    LEAKS=$((LEAKS + $($K get virtualmcpserver,mcpserverentry,mcpgroup,mcpexternalauthconfig,configmap,role,rolebinding -n "$MCPNS" -o yaml 2>/dev/null | grep -cF -e "$RAW")))
  fi
  unset V RAW
  check "the value of ${sk% *} is in no tool server log, no ConfigMap, no Role and no ToolHive object" "$LEAKS" 0
done
fin
