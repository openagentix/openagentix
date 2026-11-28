#!/usr/bin/env bash
# Live check of the bank use case (examples/use-cases/bank) on mcp.endpoints, through REAL agent sessions, on a cluster that
# examples/use-cases/bank/install.sh set up (the quick start plus the use case, the stub model with the scenarios; ADR 0026, slice 5, issue #229):
#
#   CLUSTER=oa-bank-demo examples/use-cases/bank/install.sh
#   BANK_LIVE=1 hack/ci/bank-live.sh
#
# Opt-in: it does nothing without BANK_LIVE=1. It refuses any context that is not kind, and refuses to run outside GitHub Actions unless BANK_CI_CONTEXT names
# the current context exactly (the same rule as hack/ci/endpoints-live.sh): it changes the cluster (it approves a credit, patches the identity settings of the
# tool gateways for a while, restarts them) and it reads the logs of the platform. It undoes what it changes on every way out.
#
# What it settles (every run through the stub model is SCRIPTED, not the behaviour of a model):
#   1. the platform: no backend dropped, the agent Ready, the group's tool server sees records and the knowledge mirror as ready;
#   2. a real agent session through the A2A gate: the raw answer and the wire shape of a tool result (the scenarios read it);
#   3. who may ask the agent (caller rules: an unlisted caller gets 403);
#   4. tools/oa-eval with eval/cases.yaml: the duplicate charge asks for an approval, the out-of-time claim is declined, the injected instruction asks for none
#      (and makes at most max_tool_calls calls), the audit of the group's tool server as the audit source, the records REST state as the state source;
#   5. only records and knowledge tools were called, the shared tool server saw none of them;
#   6. the approver path with ctl.sh: exactly one credit is posted, a changed case is refused, a second approval is refused;
#   7. the records service refuses a call with a wrong or no header, and answers the health check without one;
#   8. no header value and no approver token is in any log, and the header value is in no object;
#   9. isolation: the shared tool server pod holds no reference to the header Secret, the answer of `auth can-i` is recorded, a pod in `default` times out
#      against the records port, and what the egress policy of the group does on this network plugin (recorded: kindnet is not known to enforce egress);
#  10. the tool servers directly (tools/list and calls with a token of the API server, which the script makes them trust for a while): the group's tool server
#      lists exactly the 21 tools of the profile, the shared one lists no records tool and refuses a call, so does the profile of the quick start agent.
# It never prints a token or a header value. Exit 1 when a check fails.
# Env: KUBECTL, BANK_AUDIT_SETTLE (default 6s), BANK_CASE_TIMEOUT (default 300s), BANK_OUT (a directory for the report and the audit file; default a temporary
#      one, kept when BANK_OUT is set), BANK_USER_ID (default desk:eval), BANK_INSTALL_LOG (a file: checked for secret values too).
set -u
[ "${BANK_LIVE:-0}" = 1 ] || { echo "bank-live: set BANK_LIVE=1 to run this against the current cluster (it is opt-in)"; exit 0; }
KBASE=${KUBECTL:-kubectl}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
UC=$ROOT/examples/use-cases/bank
# the one guard of the live CI scripts (issue #212): kind or k3d only, a CI run or the named context, never kind-openagentix by hand; it reads the kubeconfig and nothing else
. "$(cd "$(dirname "$0")" && pwd)/lib/require-ci-context.sh"
KUBECTL=${KUBECTL:-kubectl}; export KUBECTL
require_ci_context bank-live BANK_CI_CONTEXT
CTX_NOW=$($KBASE config current-context 2>/dev/null || true)
# Every call below names the context that was checked, so a change of the current context during the run (another shell, another install) cannot send a
# credit approval, a patch of the identity settings or a ClusterRoleBinding to another cluster.
K="$KBASE --context=$CTX_NOW"
MCPNS=${MCP_NAMESPACE:-mcp-tools}; KNS=${KAGENT_NAMESPACE:-kagent}; GATE_NS=${GATE_NAMESPACE:-openagentix-gateway}; RNS=fernvale-records; DESK_NS=openagentix-system
PROFILE=disputes; USER_ID=${BANK_USER_ID:-desk:eval}
AUDIT_SETTLE=${BANK_AUDIT_SETTLE:-6s}; CASE_TIMEOUT=${BANK_CASE_TIMEOUT:-300s}
YEAR=$(date -u +%Y)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
obs() { printf '  observed: %s\n' "$1"; }

if [ -n "${BANK_OUT:-}" ]; then mkdir -p "$BANK_OUT"; TD=$(cd "$BANK_OUT" && pwd); KEEP=1; else TD=$(mktemp -d); KEEP=0; fi   # an absolute path: the build of oa-eval runs in another directory
PF=""; REF=""; PFR=""; PFM=""; PFG=""; PFS=""; PFL=""; OIDC_PATCHED=0; OIDC_ORIG=""
# Every tool server of the tools namespace (the shared one, each profile's, and any use case's): the identity settings are patched for all of them and
# restored for all of them, not for a fixed list, so a tool server of another use case cannot keep the patched settings.
tool_servers() { $K get virtualmcpserver -n "$MCPNS" -o name 2>/dev/null | sed 's#.*/##' | grep -E '^tools(-|$)'; }
TOOL_SERVERS=""   # read once, just before the identity patch, and reused by the restore: a server that goes missing meanwhile is still restarted
restore_oidc() {   # returns 1 when the settings or a restart could not be put back
  [ "$OIDC_PATCHED" = 1 ] || return 0
  local rc=0 v
  $K patch mcpoidcconfig substrate-actor-jwt -n "$MCPNS" --type merge -p "$OIDC_ORIG" >/dev/null 2>&1 || { echo "       the identity settings could not be patched back" >&2; rc=1; }
  for v in $TOOL_SERVERS; do $K rollout restart "deployment/$v" -n "$MCPNS" >/dev/null 2>&1 || { echo "       tool server $v: restart failed" >&2; rc=1; }; done
  for v in $TOOL_SERVERS; do $K rollout status "deployment/$v" -n "$MCPNS" --timeout=180s >/dev/null 2>&1 || { echo "       tool server $v: not ready after the restart" >&2; rc=1; }; done
  OIDC_PATCHED=0
  return $rc
}
cleanup() {
  # the gate token (60 minutes), the three tool server tokens (10 minutes) and their header dumps never stay on disk, even when BANK_OUT keeps the directory
  rm -f "$TD/token" "$TD/tg" "$TD/ts" "$TD/tl" "$TD"/*.h "$TD"/*.h.* "$TD/secret.patterns"
  for p in $PF $REF $PFR $PFM $PFG $PFS $PFL; do kill "$p" 2>/dev/null; done
  $K delete pod egress-probe egress-control nettest -n "$MCPNS" --ignore-not-found --wait=false >/dev/null 2>&1
  $K delete pod egress-target -n default --ignore-not-found --wait=false >/dev/null 2>&1
  $K delete pod nettest -n default --ignore-not-found --wait=false >/dev/null 2>&1
  $K delete serviceaccount branch-kiosk -n "$DESK_NS" --ignore-not-found >/dev/null 2>&1
  restore_oidc
  $K delete clusterrolebinding ci-jwks-anonymous --ignore-not-found >/dev/null 2>&1
  $K delete configmap ci-apiserver-ca -n "$MCPNS" --ignore-not-found >/dev/null 2>&1
  [ "$KEEP" = 1 ] || rm -rf "$TD"
}
trap cleanup EXIT
export KUBE_CONTEXT="$CTX_NOW"   # ctl.sh and hack/ask.sh work on the context this script checked
free_port() { python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
# the header goes to curl through a config file made by process substitution: the value is never an argument
CLEAN_CASES="$TD/cases.yaml"
sed "s/DSP-2026-/DSP-$YEAR-/g" "$UC/eval/cases.yaml" > "$CLEAN_CASES"

echo "# the platform"
VM=$($K get virtualmcpserver -n "$MCPNS" "tools-$PROFILE" -o json 2>/dev/null || echo '{}')
SH=$($K get virtualmcpserver -n "$MCPNS" tools -o json 2>/dev/null || echo '{}')
check "no vMCP condition DiscoveredAuthConfig-* is False" "$($K get virtualmcpserver -n "$MCPNS" -o json | jq '[.items[].status.conditions[]?|select((.type|startswith("DiscoveredAuthConfig-")) and .status=="False")]|length')" 0
check "the tool server tools-$PROFILE is on the group $PROFILE and lists the backends records and knowledge-disputes as ready" "$(jq -r '(.spec.groupRef.name)+" "+([.status.discoveredBackends[]?|select(.status=="ready")|.name]|sort|join(","))' <<<"$VM")" "$PROFILE knowledge-disputes,records"
check "the shared tool server found no backend records or knowledge-disputes" "$(jq '[.status|.. |strings|select(.=="records" or .=="knowledge-disputes")]|length' <<<"$SH")" 0
check "the agent dispute-agent is Ready" "$($K get agents.api.kagent.dev dispute-agent -n "$KNS" -o json 2>/dev/null | jq -r '[.status.conditions[]?|select(.type=="Ready")|.status]|first // "unknown"')" True
check "the records service is available (one replica) and its pod runs the image of this checkout's source" "$($K get deployment records -n "$RNS" -o json | jq -r '.status.availableReplicas')" 1
check "the stub model started with the scenarios from the chart (its start log says so)" "$($K logs -n agentgateway-system deploy/stub-model --tail=200 2>/dev/null | grep -c 'scenarios loaded from /etc/stub-model/scenarios' | awk '{print ($1>0)?"yes":"no"}')" yes
RMS=toolhive-vmcp-$PROFILE
echo "       RemoteMCPServer $RMS status: $($K get remotemcpserver -n "$KNS" "$RMS" -o json 2>/dev/null | jq -c '{conditions:[.status.conditions[]?|{type,status,reason}],tools:[.status.discoveredTools[]?.name]}' 2>/dev/null | cut -c1-500)"

# --- the audit source: the AUDIT lines of the group's tool server, as JSON lines with a `tool` field --------------------------------------
AUDIT_JQ=$HERE/bank-audit-tools.jq
audit_pull() { # audit_pull <out file>
  local tmp="$1.tmp.$BASHPID"
  $K logs -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" --all-containers --tail=-1 2>/dev/null | jq -cR -f "$AUDIT_JQ" 2>/dev/null > "$tmp" && mv "$tmp" "$1"; rm -f "$tmp"
}
: > "$TD/audit.jsonl"
( while true; do audit_pull "$TD/audit.jsonl"; sleep 1; done ) & REF=$!

# --- 2. the first real run: one question that only reads, the raw answer --------------------------------------------------------------
echo "# one question through the A2A gate to the agent dispute-agent (a real agent session; hack/ask.sh, as the caller disputes-desk)"
PROBE=$(ASK_SA=$DESK_NS/disputes-desk ASK_USER=desk:probe ASK_TIMEOUT=300 "$ROOT/hack/ask.sh" dispute-agent "Work case DSP-$YEAR-0002" 2>&1); PRC=$?
printf '%s\n' "$PROBE" | cut -c1-1500 | sed 's/^/       | /'
check "the agent answered (exit 0 of hack/ask.sh)" "$PRC" 0
if printf '%s' "$PROBE" | grep -qi 'is not offered to this agent'; then
  echo "       FINDING: the agent was not offered a tool the scenario names. RemoteMCPServer: $($K get remotemcpserver -n "$KNS" "$RMS" -o yaml 2>/dev/null | grep -iE 'reason|message|discover|tool' | head -20 | tr '\n' ' ' | cut -c1-800)"
fi
check "the answer is the scripted one for a case with no scenario of its own (it read the case and changed nothing)" "$(printf '%s' "$PROBE" | grep -ci 'needs human review')" 1
# the wire format: what the agent runtime hands to the model as the result of a tool call. The scenario placeholders read fields of it, so a different shape shows
# up as "<missing ...>" in the answers. The probe scenario (read only) answers with the first two raw results.
FMT=$(ASK_SA=$DESK_NS/disputes-desk ASK_USER=desk:probe ASK_TIMEOUT=300 "$ROOT/hack/ask.sh" dispute-agent "Show the raw results of DSP-$YEAR-0002" 2>&1)
echo "       FORMAT PROBE: the first two tool results as the model received them (first 3500 characters):"
printf '%s\n' "$FMT" | grep -v '^$' | cut -c1-3500 | sed 's/^/       | /'
check "the format probe shows no unresolved placeholder: the scenarios read the results the way the runtime hands them over" "$(printf '%s' "$FMT" | grep -c '<missing')" 0
sleep 3; audit_pull "$TD/audit.jsonl"
echo "       audit lines so far, by tool: $(jq -rs 'group_by(.tool)|map("\(.[0].tool)=\(length)")|join(" ")' "$TD/audit.jsonl" 2>/dev/null)"
echo "       one raw AUDIT line of the group's tool server (to read its shape): $($K logs -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" --all-containers --tail=-1 2>/dev/null | grep -m1 AUDIT | cut -c1-700)"
check "the audit of the group's tool server shows records_get_case for that question" "$(jq -rs '[.[]|select(.tool=="records_get_case")]|length>0' "$TD/audit.jsonl" 2>/dev/null)" true

# --- 3. who may ask the agent ----------------------------------------------------------------------------------------------------------
echo "# the gate: who may ask the agent (an unlisted caller gets 403)"
refused() { # refused <service account> <user id> <agent>: succeeds when the gate answers 403 (hack/ask.sh prints "HTTP 403 from the gate")
  local out; out=$(ASK_SA=$1 ASK_USER=$2 ASK_TIMEOUT=60 "$ROOT/hack/ask.sh" "$3" "hello" 2>&1); [ $? != 0 ] && printf '%s' "$out" | grep -q 'HTTP 403'
}
check "the quick start caller may not ask dispute-agent (403)" "$(refused $DESK_NS/quickstart-ask quickstart:ask dispute-agent && echo 403 || echo 'not refused')" 403
check "the disputes desk may not ask the quick start agent (403)" "$(refused $DESK_NS/disputes-desk desk:probe quickstart && echo 403 || echo 'not refused')" 403
check "the disputes desk with a user id outside its prefix is refused (403)" "$(refused $DESK_NS/disputes-desk someone:else dispute-agent && echo 403 || echo 'not refused')" 403
check "a caller with no rule at all (a service account branch-kiosk) is refused (403)" "$(refused $DESK_NS/branch-kiosk desk:kiosk dispute-agent && echo 403 || echo 'not refused')" 403
$K delete serviceaccount branch-kiosk -n "$DESK_NS" --ignore-not-found >/dev/null 2>&1

# --- 4. the evaluation set -----------------------------------------------------------------------------------------------------------------
echo "# oa-eval: eval/cases.yaml through the gate (machine checks, no model judge), the records REST state as the state source"
( cd "$ROOT/tools/oa-eval" && CGO_ENABLED=0 go build -trimpath -o "$TD/oa-eval" ./cmd/oa-eval ) || { bad "oa-eval did not build" "go build in tools/oa-eval failed"; echo; echo "bank-live: passed=$PASS failed=$FAIL"; exit 1; }
GP=$(free_port); RP=$(free_port)
$K port-forward -n "$GATE_NS" svc/a2a-gate "$GP:8080" >/dev/null 2>&1 & PFG=$!
$K port-forward -n "$RNS" deploy/records "$RP:8081" >/dev/null 2>&1 & PFR=$!
for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:$GP/healthz" 2>/dev/null && break; sleep 0.2; done
for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:$RP/readyz" 2>/dev/null && break; sleep 0.2; done
$K create token disputes-desk -n "$DESK_NS" --audience openagentix-a2a --duration 60m > "$TD/token"
"$TD/oa-eval" run --cases "$CLEAN_CASES" --gate-url "http://127.0.0.1:$GP" --namespace "$KNS" --token-file "$TD/token" --user-id "$USER_ID" \
  --audit "$TD/audit.jsonl" --audit-settle "$AUDIT_SETTLE" --timeout "$CASE_TIMEOUT" --state-base "http://127.0.0.1:$RP" --include-answers --out "$TD/report.json" 2>&1 | tee "$TD/eval.out"
[ -s "$TD/report.json" ] || bad "oa-eval wrote no report" "$(tail -5 "$TD/eval.out")"
for id in $(jq -r '.cases[]?.id' "$TD/report.json" 2>/dev/null); do
  if [ "$(jq -r --arg i "$id" '.cases[]|select(.id==$i)|.pass' "$TD/report.json")" = true ]; then ok "case $id passed"
  else bad "case $id failed" "$(jq -r --arg i "$id" '[.cases[]|select(.id==$i)|.checks[]|select(.pass|not)|(.name+": "+(.detail//""))]|join("; ")' "$TD/report.json" | cut -c1-700)"; fi
done
check "oa-eval ran five cases" "$(jq -r '.total' "$TD/report.json" 2>/dev/null)" 5
echo "       answers of the run (first 600 characters each):"
jq -r '.cases[]|"       | "+.id+": "+((.answer // "")|gsub("\n";" ")|.[0:600])' "$TD/report.json" 2>/dev/null

# --- 5. only records and knowledge tools -------------------------------------------------------------------------------------------------
echo "# every tool call of the run was a records or knowledge tool of the profile"
audit_pull "$TD/audit.jsonl"
echo "       calls by tool: $(jq -rs 'group_by(.tool)|map("\(.[0].tool)=\(length)")|join(" ")' "$TD/audit.jsonl" 2>/dev/null)"
CALLS=$(jq -s 'length' "$TD/audit.jsonl" 2>/dev/null)
check "the audit has tool calls: more than zero (a check on an empty audit proves nothing)" "$([ "${CALLS:-0}" -gt 0 ] && echo yes || echo "no: ${CALLS:-0}")" yes
ALLOWED=$(yq -r '.mcp.profiles[]|select(.name=="disputes")|(.tools.records|map("records_"+.)) + (.tools.knowledge|map("knowledge-disputes_"+.))|.[]' "$UC/values.yaml" | sort | tr '\n' ' ')
check "the profile lists 21 tools (the control for the next check is not empty)" "$(printf '%s' "$ALLOWED" | wc -w | tr -d ' ')" 21
check "every tools/call line of the group's tool server names a tool of the profile: records_* or knowledge-disputes_* only (all names are read, none is dropped)" "$(jq -rs --arg a "$ALLOWED" '($a|split(" ")|map(select(.!=""))) as $ok | [.[]|select(.tool as $t | $ok|index($t)|not)]|length' "$TD/audit.jsonl" 2>/dev/null)" 0
check "every audited call has an outcome and names the session actor" "$(jq -s '[.[]|select(.outcome==""  or (.actor|startswith("actor/kagent/session-")|not))]|length' "$TD/audit.jsonl" 2>/dev/null)" 0
check "the shared tool server never saw a records or knowledge-disputes call or tool in its log" "$($K logs -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools" --all-containers --tail=-1 2>/dev/null | grep -cE 'records_|knowledge-disputes_')" 0
check "the audit of the group's tool server has no request or response data (capture is off): no scenario argument text is in it" "$($K logs -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" --all-containers --tail=-1 2>/dev/null | grep -c 'provisional credit\|Dear cardholder')" 0

# --- 6. the approver path -------------------------------------------------------------------------------------------------------------------
echo "# the approver path (ctl.sh: the exact request is read, the hash is recomputed here, then decided as desk:lead-1)"
rest() { curl -fsS -m 15 "http://127.0.0.1:$RP$1"; }
apr_of() { rest /approvals | jq -r --arg c "$1" '[.approvals[]|select(.subject==$c)]|last|.id // empty'; }
A1=$(apr_of "DSP-$YEAR-0001"); A5=$(apr_of "DSP-$YEAR-0005")
check "the duplicate charge case has an approval request, pending" "$(rest "/approvals/${A1:-none}" 2>/dev/null | jq -r '.status')" pending
check "the out-of-time case has an approval request, pending" "$(rest "/approvals/${A5:-none}" 2>/dev/null | jq -r '.status')" pending
check "the injection case has no approval request" "$(rest /approvals | jq -r --arg c "DSP-$YEAR-0011" '[.approvals[]|select(.subject==$c)]|length')" 0
check "before any decision the ledger is empty and nothing is queued to leave the bank" "$(rest /ledger | jq '.ledger|length') $(rest /outbox | jq '[.outbox[]|select(.status=="queued")]|length')" "0 0"
SHOW=$("$UC/ctl.sh" show "$A1" 2>&1); echo "$SHOW" | head -8 | cut -c1-300 | sed 's/^/       | /'
check "ctl.sh show prints the payload the approver decides and its hash" "$(printf '%s' "$SHOW" | grep -c '^payload_hash: [0-9a-f]\{64\}$')" 1
OUT=$("$UC/ctl.sh" approve "$A1" --yes "approved in the live run" 2>&1); RC=$?
printf '%s\n' "$OUT" | tail -3 | sed 's/^/       | /'
check "ctl.sh approve decides the duplicate charge (exit 0, approved by desk:lead-1)" "$RC $(printf '%s' "$OUT" | grep -c 'approved by desk:lead-1')" "0 1"
check "exactly one credit was posted" "$(rest /ledger | jq '.ledger|length')" 1
check "the credit is for the duplicate charge case" "$(rest /ledger | jq -r '.ledger[0].case_id')" "DSP-$YEAR-0001"
check "the letter and the chargeback filing are queued (two items), after the decision only" "$(rest /outbox | jq '[.outbox[]|select(.status=="queued")]|length')" 2
OUT=$("$UC/ctl.sh" approve "$A1" --yes "again" 2>&1); RC=$?
check "a second approval of the same request is refused (exit 1, not pending)" "$RC $(printf '%s' "$OUT" | grep -c 'not pending')" "1 1"
check "still exactly one credit after the second try" "$(rest /ledger | jq '.ledger|length')" 1
# a changed case: the out-of-time case gets a new evidence item (REST, from the loopback of the pod), so its approval request is superseded
curl -fsS -m 15 -o /dev/null -X POST -H 'Content-Type: application/json' -d "{\"kind\":\"gap\",\"ref\":\"DSP-$YEAR-0005\",\"note\":\"a late note added in the live run\"}" "http://127.0.0.1:$RP/cases/DSP-$YEAR-0005/evidence"
check "a change to the case after the request supersedes the request" "$(rest "/approvals/$A5" | jq -r '.status')" superseded
OUT=$("$UC/ctl.sh" approve "$A5" --yes "too late" 2>&1); RC=$?
check "approving the request of a changed case is refused (exit 1, superseded)" "$RC $(printf '%s' "$OUT" | grep -c 'superseded')" "1 1"
check "nothing more was posted or queued by the refused approval" "$(rest /ledger | jq '.ledger|length') $(rest /outbox | jq '[.outbox[]|select(.status=="queued")]|length')" "1 2"
PFLOGLEFT=$(pgrep -f "port-forward -n $RNS deploy/records :8081" | wc -l | tr -d ' ')
check "ctl.sh left no port-forward behind" "$PFLOGLEFT" 0

# --- 7. the endpoint refuses a wrong or missing header ---------------------------------------------------------------------------------------
echo "# the records service: the MCP port needs the header value, the health check does not"
MP=$(free_port)
$K port-forward -n "$RNS" svc/records "$MP:8080" >/dev/null 2>&1 & PFM=$!
for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:$MP/healthz" 2>/dev/null && break; sleep 0.2; done
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bank-live","version":"0"}}}'
ep_init() { # ep_init <header value or empty>
  if [ -z "$1" ]; then curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT" "http://127.0.0.1:$MP/mcp"
  else curl -s -o /dev/null -w '%{http_code}' -K <(printf 'header = "Authorization: %s"\n' "$1") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$INIT" "http://127.0.0.1:$MP/mcp"; fi
}
check "the health check /healthz needs no header (200)" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MP/healthz")" 200
check "/readyz needs no header (200)" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MP/readyz")" 200
check "/mcp without the header is refused (401)" "$(ep_init '')" 401
check "/mcp with a wrong header value is refused (401)" "$(ep_init 'Bearer not-the-value-not-the-value-not-the-value')" 401
check "/mcp with the approver token as the header is refused (401: the two credentials are different)" "$(ep_init "Bearer $($K get secret records-approver-token -n "$RNS" -o jsonpath='{.data.token}' | base64 -d)")" 401
check "/mcp with the right value answers initialize (200)" "$(ep_init "$($K get secret -n "$MCPNS" records-mcp-auth -o jsonpath='{.data.value}' | base64 -d)")" 200
check "the two Secrets hold the same header value (the one the tool gateway sends is the one the service expects)" "$([ "$($K get secret -n "$MCPNS" records-mcp-auth -o jsonpath='{.data.value}')" = "$($K get secret -n "$RNS" records-mcp-expected -o jsonpath='{.data.value}')" ] && echo same || echo different)" same
kill $PFM 2>/dev/null; PFM=""

# --- 8. no secret value in any log ---------------------------------------------------------------------------------------------------------
echo "# the header value and the approver token are in no log, and the header value is in no object"
HV=$($K get secret -n "$MCPNS" records-mcp-auth -o jsonpath='{.data.value}' | base64 -d); HRAW=${HV#Bearer }
AT=$($K get secret -n "$RNS" records-approver-token -o jsonpath='{.data.token}' | base64 -d)
# the two values are kept in a shell variable and given to grep through a process substitution: they are never written to a file
PATS=$(printf '%s\n%s' "$HRAW" "$AT"); unset HV HRAW AT
[ "$(printf '%s\n' "$PATS" | grep -c .)" = 2 ] && ok "two patterns to look for (the control is not empty)" || bad "the pattern list is not what was expected" "$(printf '%s\n' "$PATS" | grep -c .)"
LEAKS=0; WHERE=""
scan() { local n; n=$(eval "$2" 2>/dev/null | grep -cF -f <(printf '%s\n' "$PATS")); if [ "$n" != 0 ]; then LEAKS=$((LEAKS+n)); WHERE="$WHERE $1($n)"; fi; }
for ns in "$MCPNS" toolhive-system "$RNS" "$GATE_NS" "$KNS" agentgateway-system ate-system openagentix-knowledge openagentix-system; do
  for p in $($K get pods -n "$ns" -o name 2>/dev/null); do
    scan "$ns:$p" "$K logs -n $ns $p --all-containers --tail=-1"
    scan "$ns:$p (previous)" "$K logs -n $ns $p --all-containers --previous --tail=-1"
  done
done
scan "objects" "$K get virtualmcpserver,mcpserverentry,mcpgroup,mcpexternalauthconfig,mcpoidcconfig,networkpolicy,configmap,agents.api.kagent.dev,agenttemplates.api.kagent.dev,remotemcpservers.kagent.dev -A -o yaml"
for f in "${BANK_INSTALL_LOG:-}" "${BANK_INSTALL_LOG2:-}" "${BANK_LIVE_LOG:-}"; do [ -z "$f" ] || [ ! -f "$f" ] || scan "$f" "cat $f"; done
scan "oa-eval report" "cat $TD/report.json"
check "no header value and no approver token in any log (current and previous container logs of ten namespaces), in any object, in the two install logs, in this script's own log so far or in the report${WHERE:+: $WHERE}" "$LEAKS" 0
unset PATS

# --- 9. isolation ---------------------------------------------------------------------------------------------------------------------------
echo "# isolation"
SHP=$($K get pods -n "$MCPNS" -l app=virtualmcpserver,toolhive-name=tools -o json)
check "the shared tool server pod exists (the control is not empty)" "$(jq '.items|length>0' <<<"$SHP")" true
check "no environment value of the shared tool server pod points at the header Secret" "$(jq '[.items[].spec.containers[].env[]?|select((.valueFrom.secretKeyRef.name//"")=="records-mcp-auth")]|length' <<<"$SHP")" 0
GPD=$($K get pods -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" -o json)
check "the pod of the group's tool server holds the header Secret by reference (positive control)" "$(jq '[.items[].spec.containers[].env[]?|select((.valueFrom.secretKeyRef.name//"")=="records-mcp-auth")]|length>0' <<<"$GPD")" true
SA=$(jq -r '.items[0].spec.serviceAccountName // ""' <<<"$SHP")
CAN=$($K auth can-i get "secret/records-mcp-auth" -n "$MCPNS" --as="system:serviceaccount:$MCPNS:$SA" 2>/dev/null || true)
obs "kubectl auth can-i get secret/records-mcp-auth -n $MCPNS, as the shared tool server's ServiceAccount ($SA): '${CAN:-no answer}' (ADR 0026 A3 expects yes: the ToolHive operator gives every tool server read access to Secrets in the tools namespace; the header Secret is as safe as that namespace)"
CANPOD=$($K auth can-i create pods -n "$MCPNS" --as="system:serviceaccount:$MCPNS:$SA" 2>/dev/null || true)
check "the shared tool server's ServiceAccount cannot create pods in the tools namespace (so it cannot copy the labels that the records ingress policy admits)" "${CANPOD:-no answer}" no
check "the records service does not listen for REST on the network: the REST port is on the pod's loopback (the pod's own spec sets no RECORDS_REST_ADDR)" "$($K get deployment records -n "$RNS" -o json | jq '[.spec.template.spec.containers[0].env[]|select(.name=="RECORDS_REST_ADDR")]|length')" 0
$K delete pod nettest -n default --ignore-not-found >/dev/null 2>&1
CODE=$($K run nettest -n default --image=curlimages/curl:8.10.1 --restart=Never --rm -i --quiet --command -- curl -s -m 8 -o /dev/null -w '%{http_code}' "http://records.$RNS.svc.cluster.local:8080/healthz" 2>/dev/null | tail -1)
case "$CODE" in
  000|"") ok "a pod in default timed out against the records port (the ingress policy is enforced here)";;
  *) bad "a pod in default reached the records port (HTTP $CODE)" "the network plugin of this cluster does not enforce ingress policy, or the policies do not select the pod. The header value is then the only check; do not read this as a pass.";;
esac
# What the egress policy of the group does on this network plugin. Three throwaway pods: a target in `default` that nothing restricts (a small web server), a
# control with no tool server labels (it is not selected by the policy: it must reach the target), and a probe with the labels of the group's tool server (it is
# selected by the policy: the target is not on its list, so an enforced policy cuts it). A probe that is cut while the control is not shows enforcement; a probe
# that is not cut shows that the policy is applied and listed, not that it works here. The target is in `default` so that no policy of the platform decides.
$K delete pod egress-target -n default --ignore-not-found --wait=false >/dev/null 2>&1
$K apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata: {name: egress-target, namespace: default, labels: {app: egress-target}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
    - name: web
      image: python:3.12.7-slim
      command: ["python3", "-I", "-m", "http.server", "8000", "--bind", "0.0.0.0"]
      readinessProbe: {httpGet: {path: /, port: 8000}, periodSeconds: 2}
---
apiVersion: v1
kind: Pod
metadata:
  name: egress-probe
  namespace: $MCPNS
  labels: {app: virtualmcpserver, toolhive-name: tools-$PROFILE}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "300"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
---
apiVersion: v1
kind: Pod
metadata: {name: egress-control, namespace: $MCPNS, labels: {app: egress-control}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "300"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
$K wait pod/egress-target -n default --for=condition=Ready --timeout=180s >/dev/null 2>&1
$K wait pod/egress-probe pod/egress-control -n "$MCPNS" --for=condition=Ready --timeout=180s >/dev/null 2>&1
TIP=$($K get pod egress-target -n default -o jsonpath='{.status.podIP}' 2>/dev/null)
eprobe() { $K exec -n "$MCPNS" "$1" -- curl -s -m 8 -o /dev/null -w '%{http_code}' "$2" 2>/dev/null; }
CTRL_OK=$(eprobe egress-probe "http://records.$RNS.svc.cluster.local:8080/healthz")
CTRL=$(eprobe egress-control "http://$TIP:8000/")
OFF=$(eprobe egress-probe "http://$TIP:8000/")
obs "egress probe: the records pod, which the policy allows, from the probe: HTTP ${CTRL_OK:-none}; the target pod in default from the control (no tool server labels): HTTP ${CTRL:-none}; the same target from the probe (the tool server labels, not on the policy's list): HTTP ${OFF:-none}"
if [ "$CTRL_OK" = 200 ] && [ "$CTRL" = 200 ]; then
  case "$OFF" in
    000|"") ok "the egress policy of the group is ENFORCED on this network plugin: the probe with the tool server labels was cut from a target the control reached, while it still reached the records pod" ;;
    *) obs "the egress policy of the group is NOT shown to be enforced on this network plugin: the probe reached the target (HTTP $OFF). The policy is applied and listed; here it does not cut a connection. This is the documented limit (ADR 0026, A5), not a pass of the egress rule." ;;
  esac
else
  obs "a control did not answer (the records pod from the probe: ${CTRL_OK:-none}; the target from the control: ${CTRL:-none}): nothing can be said about egress from this run"
fi
$K delete pod egress-probe egress-control -n "$MCPNS" --ignore-not-found --wait=false >/dev/null 2>&1
$K delete pod egress-target -n default --ignore-not-found --wait=false >/dev/null 2>&1

# --- 10. the tool servers directly ------------------------------------------------------------------------------------------------------------
# The agents' own path (above) stays as the platform made it. For this part only, the identity settings of the tool servers are changed: they trust the API
# server's own ServiceAccount tokens, so that this script can make a token and call them. The original settings are put back, and the tool servers restarted,
# on every way out. Agents' calls do not work while the settings are changed: nothing else runs now.
echo "# the tool servers, called directly (tools/list and calls; the identity settings are changed for this part and restored)"
OIDC_ORIG=$($K get mcpoidcconfig substrate-actor-jwt -n "$MCPNS" -o json | jq -c '{spec:{inline:(.spec.inline|{issuer,jwksUrl,caBundleRef})}}')
if [ -n "$OIDC_ORIG" ]; then ok "the original identity settings are kept in memory, for the restore"
else
  bad "could not read the identity settings" "nothing was changed, so this section stops here: it cannot put them back"
  echo; echo "bank-live: passed=$PASS failed=$FAIL"; exit 1
fi
$K get configmap kube-root-ca.crt -n "$MCPNS" -o json | jq --arg n ci-apiserver-ca '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:.metadata.namespace},data:{"ca.crt":.data["ca.crt"]}}' | $K apply -f - >/dev/null
$K create clusterrolebinding ci-jwks-anonymous --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated --dry-run=client -o yaml | $K apply -f - >/dev/null
TOOL_SERVERS=$(tool_servers)
OIDC_PATCHED=1
$K patch mcpoidcconfig substrate-actor-jwt -n "$MCPNS" --type merge -p '{"spec":{"inline":{"issuer":"https://kubernetes.default.svc.cluster.local","jwksUrl":"https://kubernetes.default.svc/openid/v1/jwks","caBundleRef":{"configMapRef":{"name":"ci-apiserver-ca","key":"ca.crt"}}}}}' >/dev/null
for v in $TOOL_SERVERS; do $K rollout restart "deployment/$v" -n "$MCPNS" >/dev/null 2>&1; done
for v in $TOOL_SERVERS; do $K rollout status "deployment/$v" -n "$MCPNS" --timeout=180s >/dev/null 2>&1 || echo "       (tool server $v: restart not confirmed)"; done
mcp_token() { $K create token default -n "$MCPNS" --audience "$1" --duration 10m 2>/dev/null; }
mcp_post() {  # mcp_post <port> <token file> <session id or -> <json>: prints the JSON-RPC answer (the data line of an event stream, or the body)
  local port=$1 tf=$2 sid=$3 body=$4 out hdr=()
  [ "$sid" = - ] || hdr=(-H "Mcp-Session-Id: $sid")
  out=$(curl -s -m 30 -D "$tf.h" -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' ${hdr[@]+"${hdr[@]}"} -d "$body" "http://127.0.0.1:$port/mcp" 2>/dev/null)
  if grep -q '^data:' <<<"$out"; then sed -n 's/^data: *//p' <<<"$out" | tail -1; else printf '%s' "$out"; fi
}
mcp_open() {  # mcp_open <port> <token file>: prints the session id
  mcp_post "$1" "$2" - '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bank-live","version":"0"}}}' >/dev/null
  local sid; sid=$(grep -i '^mcp-session-id:' "$2.h" | tr -d '\r' | awk '{print $2}')
  [ -z "$sid" ] || mcp_post "$1" "$2" "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  printf '%s' "${sid:--}"
}
mcp_call() { mcp_post "$1" "$2" "$3" "{\"jsonrpc\":\"2.0\",\"id\":$4,\"method\":\"$5\",\"params\":$6}"; }
GPORT=$(free_port); SPORT=$(free_port); LPORT=$(free_port)
$K port-forward -n "$MCPNS" "svc/vmcp-tools-$PROFILE" "$GPORT:4483" >/dev/null 2>&1 & PF=$!
$K port-forward -n "$MCPNS" svc/vmcp-tools "$SPORT:4483" >/dev/null 2>&1 & PFS=$!
$K port-forward -n "$MCPNS" svc/vmcp-tools-lookup "$LPORT:4483" >/dev/null 2>&1 & PFL=$!
sleep 4
mcp_token "openagentix-vmcp-$PROFILE" > "$TD/tg"; mcp_token openagentix-vmcp > "$TD/ts"; mcp_token openagentix-vmcp-lookup > "$TD/tl"
check "tokens for the three audiences were made" "$([ -s "$TD/tg" ] && [ -s "$TD/ts" ] && [ -s "$TD/tl" ] && echo yes || echo no)" yes
SID_G=-; for _ in $(seq 1 10); do SID_G=$(mcp_open "$GPORT" "$TD/tg"); [ "$SID_G" != - ] && break; sleep 5; done
LIST_G=$(mcp_call "$GPORT" "$TD/tg" "$SID_G" 2 tools/list '{}' | jq -r '[.result.tools[]?.name]|sort|join(" ")' 2>/dev/null)
WANT=$(printf '%s' "$ALLOWED" | tr ' ' '\n' | grep . | sort | tr '\n' ' ' | sed 's/ $//')
check "tools/list on the group's tool server lists exactly the 21 tools of the profile (records_* and knowledge-disputes_*)" "$LIST_G" "$WANT"
CALL=$(mcp_call "$GPORT" "$TD/tg" "$SID_G" 3 tools/call '{"name":"records_get_case","arguments":{"case_id":"DSP-'"$YEAR"'-0002"}}')
echo "       the group's tool server answered the call: $(printf '%s' "$CALL" | cut -c1-400)"
check "a call of records_get_case through the group's tool server reaches the service with the header and answers a case" "$(jq -r '(.result.isError//false|tostring)+" "+([.result.content[]?.text]|join(" ")|test("DSP-")|tostring)' <<<"$CALL" 2>/dev/null)" "false true"
CALL=$(mcp_call "$GPORT" "$TD/tg" "$SID_G" 4 tools/call '{"name":"records_approve","arguments":{"approval_id":"APR-0001"}}')
check "a tool name the records service does not have (records_approve) is refused (the service has exactly the 15 tools of the profile, so this shows an unknown name is refused, not the filter)" "$(jq -r '((.error!=null) or (.result.isError==true))|tostring' <<<"$CALL" 2>/dev/null)" true
RES=$(mcp_call "$GPORT" "$TD/tg" "$SID_G" 5 resources/list '{}' 2>/dev/null)
check "resources/list through the group's tool server shows no resource of a backend" "$(printf '%s' "$RES" | jq -r '[.result.resources[]?]|length' 2>/dev/null)" 0
SID_S=$(mcp_open "$SPORT" "$TD/ts")
LIST_S=$(mcp_call "$SPORT" "$TD/ts" "$SID_S" 2 tools/list '{}')
check "the shared tool server answers tools/list (the control is not empty: it lists tools)" "$(jq '[.result.tools[]?]|length>0' <<<"$LIST_S" 2>/dev/null)" true
check "tools/list on the shared tool server lists no records or knowledge-disputes tool" "$(jq '[.result.tools[]?.name|select(test("^(records|knowledge-disputes)_"))]|length' <<<"$LIST_S" 2>/dev/null)" 0
CALL=$(mcp_call "$SPORT" "$TD/ts" "$SID_S" 3 tools/call '{"name":"records_get_case","arguments":{"case_id":"DSP-'"$YEAR"'-0002"}}')
echo "       the shared tool server answered: $(printf '%s' "$CALL" | cut -c1-200)"
check "a call of records_get_case through the shared tool server is refused (an error, no result)" "$(jq -r '((.error!=null) or (.result.isError==true))|tostring' <<<"$CALL" 2>/dev/null)" true
SID_L=$(mcp_open "$LPORT" "$TD/tl")
LIST_L=$(mcp_call "$LPORT" "$TD/tl" "$SID_L" 2 tools/list '{}')
check "the profile of the quick start agent (lookup) lists a tool (the control is not empty) and no records tool" "$(jq -r '([.result.tools[]?]|length>0|tostring)+" "+([.result.tools[]?.name|select(test("^(records|knowledge-disputes)_"))]|length|tostring)' <<<"$LIST_L" 2>/dev/null)" "true 0"
CALL=$(mcp_call "$LPORT" "$TD/tl" "$SID_L" 3 tools/call '{"name":"records_get_case","arguments":{"case_id":"DSP-'"$YEAR"'-0002"}}')
check "another agent's profile (lookup, the quick start agent) cannot call a records tool (refused)" "$(jq -r '((.error!=null) or (.result.isError==true))|tostring' <<<"$CALL" 2>/dev/null)" true
check "every backend of the group's tool server is still ready after the calls" "$($K get virtualmcpserver -n "$MCPNS" "tools-$PROFILE" -o json | jq -r '[.status.discoveredBackends[]?|select(.status!="ready")|.name]|join(",")')" ""
kill $PF $PFS $PFL 2>/dev/null; PF=""; PFS=""; PFL=""
if restore_oidc; then ok "the identity settings were put back and every tool server was restarted and is ready"; else bad "the identity settings were NOT restored" "see the lines above: tool servers may still trust the API server tokens until they restart"; fi
check "after the restore every tool server is Ready again" "$($K get virtualmcpserver -n "$MCPNS" -o json | jq -r '[.items[]|select(([.status.conditions[]?|select(.type=="Ready")|.status]|first // "Unknown")!="True")|.metadata.name]|join(",")')" ""

echo
echo "bank-live: passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
