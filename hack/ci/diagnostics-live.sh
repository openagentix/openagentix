#!/usr/bin/env bash
# Live check of cluster-read on a cluster that ./install.sh set up with components/diagnostics/ci-values.yaml (ADR 0025, slice 4).
#   PROFILE=quickstart VALUES_FILE=components/diagnostics/ci-values.yaml ./install.sh
#   DIAGNOSTICS=1 hack/ci/diagnostics-live.sh
# Opt-in: it does nothing without DIAGNOSTICS=1, so a stray local run never touches the cluster you are on. The e2e workflow runs it on request.
#
# What it settles (the open question R2 of the code review): does the server become Ready on a REAL API server, that is, does its rights check
# pass with the default discovery rules of a real ServiceAccount? And through the whole chain (kagent -> actor JWT -> vMCP -> bearer header ->
# server), does the dedicated profile `rca` list the eight tools while the shared tool server lists none?
# It reads the cluster and makes one port-forward to the server. It never prints the bearer value. Exit 1 when a check fails.
set -u
[ "${DIAGNOSTICS:-0}" = 1 ] || { echo "diagnostics-live: set DIAGNOSTICS=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
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
trap 'kill $PF 2>/dev/null' EXIT
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

echo "# through the whole chain: what each tool server lists (kagent asks the vMCPs with an actor token)"
# kagent's RemoteMCPServer keeps the tools it found in status.discoveredTools. Wait for the dedicated one.
LIST=""
for _ in $(seq 1 60); do
  LIST=$($K get remotemcpserver -n "$KNS" "toolhive-vmcp-$PROFILE" -o json 2>/dev/null | jq -r '[.status.discoveredTools[]?.name]|sort|join(" ")')
  [ -n "$LIST" ] && break
  sleep 3
done
WANT=$(for t in $TOOLS; do printf 'cluster-read_%s ' "$t"; done | sed 's/ $//')
check "the dedicated profile $PROFILE lists the eight tools, and only those" "$LIST" "$WANT"
[ "$LIST" = "$WANT" ] || { $K get remotemcpserver -n "$KNS" "toolhive-vmcp-$PROFILE" -o jsonpath='{.status}' 2>/dev/null | cut -c1-800 | sed 's/^/       status: /'; echo; }
SHLIST=$($K get remotemcpserver -n "$KNS" toolhive-vmcp -o json 2>/dev/null | jq -r '[.status.discoveredTools[]?.name]|map(select(test("cluster-read")))|length')
SHALL=$($K get remotemcpserver -n "$KNS" toolhive-vmcp -o json 2>/dev/null | jq -r '[.status.discoveredTools[]?.name]|length')
check "the shared tool server lists no cluster-read tool" "$SHLIST" 0
echo "       (the shared tool server lists $SHALL tool(s) in all: a control that the status is read at all)"
OTHER=$($K get remotemcpserver -n "$KNS" toolhive-vmcp-lookup -o json 2>/dev/null | jq -r '[.status.discoveredTools[]?.name]|map(select(test("cluster-read")))|length')
check "the shared-group profile lookup lists no cluster-read tool either" "$OTHER" 0

echo "# the rights, asked of the real API server as the ServiceAccount"
SA="system:serviceaccount:$DNS:cluster-read"
can() { $K auth can-i "$@" --as="$SA" 2>/dev/null || true; }
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
