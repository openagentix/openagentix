#!/usr/bin/env bash
# Live check of the event sender of a use case's records service (ADR 0027, slices 5 and 6, issue #229), on a cluster that
# examples/use-cases/<use case>/install.sh set up. Two phases, run one after the other in the opt-in jobs of the e2e workflow:
#
#   CLUSTER=oa-equipment-demo examples/use-cases/equipment/install.sh                          # the sender is OFF
#   EVENTS_LIVE=1 hack/ci/events-live.sh equipment off                                          # nothing is sent
#   EVENTS=1 CLUSTER=oa-equipment-demo examples/use-cases/equipment/install.sh --skip-platform  # the sender is turned ON (the records service only)
#   EVENTS_LIVE=1 hack/ci/events-live.sh equipment on                                           # a real event starts the agent
#
# Opt-in: it does nothing without EVENTS_LIVE=1. It refuses any context that is not kind, refuses kind-openagentix outside GitHub Actions, and refuses to run
# outside GitHub Actions unless EVENTS_CI_CONTEXT names the current context exactly: it posts cases into the records service and restarts nothing else.
# The stub model plays the scenarios: a run is SCRIPTED, not the behaviour of a model. It never prints a token or a header value.
#
# off: the records pod has no sender setting and no gate token; a new fault (or dispute) opens a case, ctl.sh says what to do next, and after a wait no
#      audit line of the gate names the use case's event caller, so nothing was sent.
# on:  1. the pod has the sender settings, a projected token for the gate's audience (600 s) and an egress rule to DNS and the gate only;
#      2. a new case posted to the intake route starts a run with no ask by a person: the gate has one audit line with status 200 for the event caller, with the event id
#         case-<record id> (the record's own id) and rpc SendMessage, and the records service's audit shows the agent read that case through its tools;
#      3. the same fault again (equipment) reuses the open case and sends no second event; the gate still has exactly one 200 line for the event id;
#      4. a burst of ten new cases is held to the caller's rate: the gate answers 429 (reason rate), the sender waits and sends again, and in the end every one of the
#         ten event ids has exactly one 200 line;
#      5. an agent tool cannot cause an event (equipment: open_proactive_case called on the MCP port opens a case and no event line follows; a case that came from an
#         intake route is the only kind that has one);
#      6. no message text: the gate's audit lines and logs, and the records service's log, hold none of the words "Work case" and none of the planted dealer or customer
#         text; no log holds the token.
# Exit 1 when a check fails.
# Env: KUBECTL, EVENTS_OUT (a directory for the audit lines that were read; default a temporary one), EVENTS_BURST (default 10), EVENTS_WAIT (seconds to wait for a
#      single event, default 180), EVENTS_BURST_WAIT (seconds to wait for the burst, default 900).
set -u
[ "${EVENTS_LIVE:-0}" = 1 ] || { echo "events-live: set EVENTS_LIVE=1 to run this against the current cluster (it is opt-in)"; exit 0; }
UCN=${1:-}; PHASE=${2:-}
case "$UCN" in equipment|bank) ;; *) echo "usage: EVENTS_LIVE=1 events-live.sh <equipment|bank> <off|on>" >&2; exit 2;; esac
case "$PHASE" in off|on) ;; *) echo "usage: EVENTS_LIVE=1 events-live.sh <equipment|bank> <off|on>" >&2; exit 2;; esac
KBASE=${KUBECTL:-kubectl}
CTX_NOW=$($KBASE config current-context 2>/dev/null || true)
case "$CTX_NOW" in
  kind-*) ;;
  *) echo "events-live: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind context. Nothing was changed." >&2; exit 2;;
esac
if [ "$CTX_NOW" = kind-openagentix ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo "events-live: refusing to run on 'kind-openagentix': that is the name of a full demo cluster. Nothing was changed." >&2; exit 2
fi
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${EVENTS_CI_CONTEXT:-}" != "$CTX_NOW" ]; then
  echo "events-live: refusing to run on '$CTX_NOW': it is not a CI run and EVENTS_CI_CONTEXT does not name this context. Nothing was changed." >&2; exit 2
fi
K="$KBASE --context=$CTX_NOW"
GATE_NS=${GATE_NAMESPACE:-openagentix-gateway}
BURST=${EVENTS_BURST:-10}; WAIT=${EVENTS_WAIT:-180}; BURST_WAIT=${EVENTS_BURST_WAIT:-900}
case "$UCN" in
  equipment) RNS=kestrel-records; AGENT=service-agent; CALLER=kestrel-fault-events; PLANT="PLANTED-DEALER-NOTE-4417" ;;
  bank)      RNS=fernvale-records; AGENT=dispute-agent;  CALLER=fernvale-case-events;  PLANT="PLANTED-CUSTOMER-NOTE-4417" ;;
esac
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
if [ -n "${EVENTS_OUT:-}" ]; then mkdir -p "$EVENTS_OUT"; TD=$(cd "$EVENTS_OUT" && pwd); KEEP=1; else TD=$(mktemp -d); KEEP=0; fi
PF=""; PFM=""
cleanup() { for p in $PF $PFM; do kill "$p" 2>/dev/null; done; [ "$KEEP" = 1 ] || rm -rf "$TD"; }
trap cleanup EXIT
free_port() { python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }

# the audit lines of the gate, as JSON lines (the log of the gate holds nothing else that parses as a line with msg audit)
gate_audit() { $K logs -n "$GATE_NS" deploy/a2a-gate --tail=-1 2>/dev/null | jq -cR 'fromjson? | select(.msg=="audit")'; }
# the audit lines are read once into a file (refresh_ga), then counted: the 200 lines of the event caller for one event id
refresh_ga() { gate_audit > "$TD/ga.jsonl"; }
ok_lines() { jq -c --arg c "$CALLER" --arg e "$1" 'select(.caller==$c and .event_id==$e and .status==200)' "$TD/ga.jsonl" | wc -l | tr -d ' '; }
# wait <seconds> <command...>: poll every 3 s until the command succeeds
wait_for() { local t=$1 end; shift; end=$(( $(date +%s) + t )); while [ "$(date +%s)" -lt "$end" ]; do "$@" && return 0; sleep 3; done; return 1; }

# the records REST port (loopback in the pod): a port-forward, as ctl.sh does
RP=$(free_port)
$K port-forward -n "$RNS" deploy/records "$RP:8081" >/dev/null 2>&1 & PF=$!
wait_for 60 curl -fsS -m 3 "http://127.0.0.1:$RP/readyz" -o /dev/null || { echo "events-live: the records REST port did not come up" >&2; exit 1; }
BASE="http://127.0.0.1:$RP"
rest_post() { curl -sS -m 20 -o "$TD/resp.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$2" "$BASE$1"; }
rest_get() { curl -fsS -m 20 "$BASE$1"; }

# one new case through the intake route; sets CASE (its id) and DEDUP and HTTP. $1 is a counter that makes the case a new one.
new_case() {
  local n=$1 code
  DEDUP=""; CASE=""
  if [ "$UCN" = equipment ]; then
    local serial; serial=$(printf 'KH4120-%05d' $((300 + n)))
    code=$(rest_post /faults "$(jq -nc --arg s "$serial" '{serial:$s,code:"E-330"}')") || code=000
    CASE=$(jq -r '.case.id // empty' "$TD/resp.json" 2>/dev/null); DEDUP=$(jq -r '.deduplicated | tostring' "$TD/resp.json" 2>/dev/null)
  else
    local acct txn
    # the burst uses the accounts 2031 to 2040 (no seeded case there), the single case the account 2021
    if [ "$n" -le 10 ]; then acct="ACC-$((2030 + n))"; else acct="ACC-$((2000 + n))"; fi
    txn=$(rest_get "/savingsaccounts/$acct/transactions?limit=50" 2>/dev/null | jq -r '[.transactions[]|select(.amount_cents>0)][0].id // empty')
    [ -n "$txn" ] || { HTTP=000; return 1; }
    code=$(rest_post /cases "$(jq -nc --arg a "$acct" --arg t "$txn" --arg n "$PLANT" '{account_id:$a,transaction_id:$t,claim_type:"not_recognised",claim_note:$n}')") || code=000
    CASE=$(jq -r '.id // empty' "$TD/resp.json" 2>/dev/null)
  fi
  HTTP=$code
  [ "$code" = 200 ] || [ "$code" = 201 ]
}

echo "# the records pod ($UCN, sender $PHASE)"
DEP=$($K get deployment records -n "$RNS" -o json)
HAS_URL=$(jq -r '[.spec.template.spec.containers[0].env[]|select(.name=="RECORDS_EVENT_GATE_URL")]|length' <<<"$DEP")
if [ "$PHASE" = off ]; then
  check "the pod has no sender setting and no projected gate token" "$HAS_URL $(jq -r '[.spec.template.spec.volumes[]?|select(.projected)]|length' <<<"$DEP")" "0 0"
  check "the pod makes no connection (egress is the empty list)" "$($K get networkpolicy records -n "$RNS" -o json | jq -c '.spec.egress // []')" "[]"
  before=$(gate_audit | jq -c --arg c "$CALLER" 'select(.caller==$c)' | wc -l | tr -d ' ')
  new_case 1; rc=$?
  check "a new case is accepted by the intake route with the sender off (HTTP $HTTP)" "$rc" 0
  echo "       case $CASE"
  sleep 25
  after=$(gate_audit | jq -c --arg c "$CALLER" 'select(.caller==$c)' | wc -l | tr -d ' ')
  check "nothing was sent: the gate has no new audit line for the event caller $CALLER" "$((after - before))" 0
  check "the records service has no events table activity in its audit (no event_sent, no event_retry)" "$($K logs -n "$RNS" deploy/records --tail=-1 2>/dev/null | jq -cR 'fromjson? | select(.action? != null and (.action|startswith("event_")))' | wc -l | tr -d ' ')" 0
  echo; echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]; exit $?
fi

# ---- phase on -------------------------------------------------------------------------------------------------------------------------
check "the pod has the sender settings: the gate URL names the agent $AGENT, and the token file" "$(jq -r '[.spec.template.spec.containers[0].env[]|select(.name|startswith("RECORDS_EVENT"))|.name]|sort|join(" ")' <<<"$DEP")" "RECORDS_EVENT_GATE_URL RECORDS_EVENT_TOKEN_FILE"
check "the gate URL is the agent on the gate, in the gateway namespace" "$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="RECORDS_EVENT_GATE_URL")|.value' <<<"$DEP")" "http://a2a-gate.$GATE_NS.svc.cluster.local:8080/agents/kagent/$AGENT"
check "the token is projected for the gate's audience, 600 seconds" "$(jq -c '[.spec.template.spec.volumes[]|select(.projected)|.projected.sources[].serviceAccountToken|[.audience,.expirationSeconds]]' <<<"$DEP")" '[["openagentix-a2a",600]]'
check "the pod may reach DNS and the gate on 8080 and nothing else (two egress rules, no address range)" "$($K get networkpolicy records -n "$RNS" -o json | jq -c '[(.spec.egress|length), ([.spec.egress[].to[]|has("ipBlock")]|any), (.spec.egress[1].ports|map(.port))]')" '[2,false,[8080]]'
check "the pod runs as the ServiceAccount records-events and mounts no API token" "$(jq -r '.spec.template.spec.serviceAccountName+" "+(.spec.template.spec.automountServiceAccountToken|tostring)' <<<"$DEP")" "records-events false"
check "the gate's caller rule is the event caller $CALLER for the agent $AGENT" "$($K get configmap a2a-gate-rules -n "$GATE_NS" -o jsonpath='{.data.rules\.json}' | jq -c --arg c "$CALLER" '.callers[]|select(.name==$c)|[.agents, .serviceAccount.name, (.event.text|length>0)]')" "[[\"kagent/$AGENT\"],\"records-events\",true]"

echo "# a new case starts a run with no person asking"
new_case 21; rc=$?
check "the intake route accepts the case (HTTP $HTTP)" "$rc" 0
ID=$CASE; EV="case-$ID"
echo "       case $ID, event id $EV"
check "the case is new" "$DEDUP" "$([ "$UCN" = equipment ] && echo false || echo '')"
sent() { refresh_ga; [ "$(ok_lines "$EV")" -ge 1 ]; }
wait_for "$WAIT" sent; SENT=$?
check "the gate has an audit line with status 200 for $CALLER and the event id $EV (the record's id)" "$SENT" 0
LINE=$(gate_audit | jq -c --arg c "$CALLER" --arg e "$EV" 'select(.caller==$c and .event_id==$e and .status==200)' | head -1)
echo "       audit: $(printf '%s' "$LINE" | jq -c 'del(.time,.duration_ms,.user_id)' 2>/dev/null)"
check "the line names the agent $AGENT, the method SendMessage, and has no reason" "$(printf '%s' "$LINE" | jq -r '[.agent, .rpc, (.reason // "none")] | join(" ")' 2>/dev/null)" "kagent/$AGENT SendMessage none"
tool_read() { $K logs -n "$RNS" deploy/records --tail=-1 2>/dev/null | jq -cR --arg id "$ID" 'fromjson? | select(.msg=="AUDIT" and .channel=="mcp" and .subject==$id)' | grep -q .; }
wait_for "$WAIT" tool_read; TR=$?
check "the agent ran: the records service's audit shows a tool call on $ID through the MCP port (the run that the event started)" "$TR" 0

if [ "$UCN" = equipment ]; then
  echo "# the same fault again reuses the open case and sends no second event"
  new_case 21; rc=$?
  check "the intake route answers 200 and says deduplicated (HTTP $HTTP)" "$rc $HTTP $DEDUP" "0 200 true"
  check "it is the same case" "$CASE" "$ID"
  sleep 20
  refresh_ga
  check "the gate still has exactly one 200 line for $EV" "$(ok_lines "$EV")" 1
  echo "# a dealer's service request with a planted note: the event names only the case id"
  code=$(rest_post /requests "$(jq -nc --arg n "$PLANT" '{serial:"KT260-00130",note:$n,safety:false}')") || code=000
  RQ=$(jq -r '.id // empty' "$TD/resp.json" 2>/dev/null)
  check "the request is accepted and opens a case (HTTP $code)" "$([ "$code" = 201 ] && [ -n "$RQ" ] && echo yes || echo no)" yes
  rq_sent() { refresh_ga; [ "$(ok_lines "case-$RQ")" -ge 1 ]; }
  wait_for "$WAIT" rq_sent; RS=$?
  check "the gate has one 200 line for case-$RQ" "$RS" 0
fi

echo "# a burst of $BURST new cases is held to the rate, the sender backs off and sends again, and every one is sent once"
: > "$TD/burst.ids"
for n in $(seq 1 "$BURST"); do
  if new_case "$n"; then echo "case-$CASE" >> "$TD/burst.ids"; else echo "       burst case $n: HTTP $HTTP (not accepted)"; fi
done
check "all $BURST cases were accepted by the intake route" "$(wc -l < "$TD/burst.ids" | tr -d ' ')" "$BURST"
all_sent() { local missing=0 e; refresh_ga; while read -r e; do [ "$(ok_lines "$e")" -ge 1 ] || missing=1; done < "$TD/burst.ids"; [ "$missing" = 0 ]; }
wait_for "$BURST_WAIT" all_sent; AS=$?
check "every one of the $BURST event ids has a 200 line in the end" "$AS" 0
DUP=0; while read -r e; do [ "$(ok_lines "$e")" = 1 ] || DUP=1; done < "$TD/burst.ids"
check "and exactly one (no case was asked twice)" "$DUP" 0
refresh_ga; cp "$TD/ga.jsonl" "$TD/gate-audit.jsonl"
R429=$(jq -c --arg c "$CALLER" 'select(.caller==$c and .status==429)' "$TD/gate-audit.jsonl" | wc -l | tr -d ' ')
check "the gate refused part of the burst with 429 (reason rate): $R429 lines" "$([ "$R429" -ge 1 ] && echo yes || echo no)" yes
check "every 429 line of the caller has the reason rate or caller_busy and an event id of invalid (the body was not read)" "$(jq -c --arg c "$CALLER" 'select(.caller==$c and .status==429)|[.reason, .event_id]' "$TD/gate-audit.jsonl" | sort -u | jq -cs 'map(.[0]|IN("rate","caller_busy"))|all')" true
check "no 5xx line of the caller (the sender is not refused for any other reason)" "$(jq -c --arg c "$CALLER" 'select(.caller==$c and .status>=500)' "$TD/gate-audit.jsonl" | wc -l | tr -d ' ')" 0

if [ "$UCN" = equipment ]; then
  echo "# an agent tool cannot cause an event"
  MP=$(free_port)
  $K port-forward -n "$RNS" deploy/records "$MP:8080" >/dev/null 2>&1 & PFM=$!
  wait_for 60 curl -s -m 3 -o /dev/null "http://127.0.0.1:$MP/healthz" || true
  before=$(jq -c --arg c "$CALLER" 'select(.caller==$c and .status==200)' "$TD/gate-audit.jsonl" | wc -l | tr -d ' ')
  HV=$($K get secret records-mcp-expected -n "$RNS" -o jsonpath='{.data.value}' 2>/dev/null | base64 -d 2>/dev/null)
  if [ -n "$HV" ]; then
    mcp() { curl -sS -m 30 -K <(printf 'header = "Authorization: %s"\n' "$HV") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$1" "http://127.0.0.1:$MP/mcp"; }
    mcp '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"events-live","version":"1"}}}' > /dev/null
    RES=$(mcp '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_proactive_case","arguments":{"serial":"KH4120-00317","reason":"events-live: the sweep read this machine as trending to failure"}}}')
    unset HV
    SWEEP_CASE=$(printf '%s' "$RES" | grep -o 'SVC-[0-9]\{4\}-[0-9]\{4\}' | head -1)
    check "open_proactive_case opened (or returned) a case through the MCP port" "$([ -n "$SWEEP_CASE" ] && echo yes || echo no)" yes
    sleep 25
    gate_audit > "$TD/gate-audit2.jsonl"
    check "the gate has no event line for that case (event id case-$SWEEP_CASE)" "$(jq -c --arg c "$CALLER" --arg e "case-$SWEEP_CASE" 'select(.caller==$c and .event_id==$e)' "$TD/gate-audit2.jsonl" | wc -l | tr -d ' ')" 0
    check "and no new 200 line of the event caller at all" "$(jq -c --arg c "$CALLER" 'select(.caller==$c and .status==200)' "$TD/gate-audit2.jsonl" | wc -l | tr -d ' ')" "$before"
  else
    bad "the MCP credential Secret could not be read, so the tool call was not made" ""
  fi
fi

echo "# no message text, no token in any log"
gate_audit > "$TD/gate-audit3.jsonl"
GLOG=$($K logs -n "$GATE_NS" deploy/a2a-gate --tail=-1 2>/dev/null)
RLOG=$($K logs -n "$RNS" deploy/records --tail=-1 2>/dev/null)
SLOG=$($K logs -n agentgateway-system deploy/stub-model --tail=-1 2>/dev/null)
check "the gate's log holds no \"Work case\" and no planted text" "$(printf '%s' "$GLOG" | grep -c -e 'Work case' -e "$PLANT")" 0
check "the records service's log holds no \"Work case\" and no planted text" "$(printf '%s' "$RLOG" | grep -c -e 'Work case' -e "$PLANT")" 0
check "no line of the stub model that holds \"Work case\" (the message the agent got) holds the planted text" "$(printf '%s' "$SLOG" | grep 'Work case' | grep -c "$PLANT")" 0
check "no log of the gate or the records service holds a service account token (the shape of a JWT)" "$(printf '%s\n%s' "$GLOG" "$RLOG" | grep -cE 'eyJ[A-Za-z0-9_-]{15,}[.]eyJ[A-Za-z0-9_-]{15,}[.]')" 0
check "every event line of the caller has an event id of the form case-<record id> or invalid" "$(jq -c --arg c "$CALLER" 'select(.caller==$c)|.event_id' "$TD/gate-audit3.jsonl" | sort -u | grep -vE '^"(invalid|case-[A-Z]{3}-[0-9]{4}-[0-9]{4})"$' | wc -l | tr -d ' ')" 0

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
