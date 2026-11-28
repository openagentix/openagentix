#!/usr/bin/env bash
# Measure a pass rate and the cost of a use case on a REAL model (issue #229).
#
#   hack/use-case-eval.sh <bank|equipment|software-org> --runs N [--out DIR] [--reset-records] [--sweep]
#                         [--tokens per-run|per-case|off] [--only ID,ID] [--include-answers] [--metrics-user-id ID]
#
# It runs examples/use-cases/<use case>/eval/cases-real.yaml N times through the A2A gate with tools/oa-eval, and writes DIR/summary.json
# (and prints a table): per case, the passes out of N, which checks failed and how often, median and maximum duration, tool calls, tokens.
# The checks are outcome checks that any competent run meets (see the header of each cases-real.yaml). It does NOT call a model itself:
# the agent in the cluster does, so a run costs real money when the agent's model is a paid one. Read the model and the key in the install first.
#
# For a kind cluster only, named by CLUSTER (the kind cluster name) or KUBE_CONTEXT (kind-<name>). There is no default: the script refuses
# without one, refuses a context that is not kind-*, and refuses CLUSTER and KUBE_CONTEXT that name different clusters. Every kubectl call
# carries --context. Nothing is changed before those checks.
#
# --reset-records  REQUIRED for bank and equipment. Before every run the pod of the use case's records service is deleted and the script waits for
#                  the new pod to be Ready and for the seed (the store is an emptyDir): every case, approval, outbox item and ledger row of
#                  that use case is replaced by the seed, and a request you made by hand is gone. The script says so before it does it.
#                  The software organisation use case has no records store and refuses this flag.
# --sweep          After the runs, start the use case's suspended schedule once by hand (kubectl create job --from=cronjob/deadline-sweep or
#                  fleet-sweep, in openagentix-schedules), wait for it, and check from the audit lines and the records state that it only read.
#                  A job that wrote, or a record that changed, is a failure (exit 1). Not for software-org.
# --tokens         Where tokens come from: the gateway's own metric agentgateway_gen_ai_client_token_usage_sum (label user_id, the agent's
#                  gateway key name, label gen_ai_token_type) in the bundled VictoriaMetrics (observability on). per-run (default): one reading before
#                  and after a run, one total per run. per-case: cases run one by one with a reading around each, which needs one scrape interval
#                  (default 30 s, METRICS_SCRAPE_SECONDS) per case. off: do not read. If the metric is not there, the summary says "not available"
#                  and why. Other traffic on the same gateway key during a run is counted too: use a quiet cluster. Tokens only, never a price.
# --budget-tokens-per-hour N   The hourly token budget of the agent's gateway key. Without the flag the script reads it from the release it is measuring
#                  (helm get values RELEASE, default openagentix in openagentix-system; env HELM, RELEASE, RELEASE_NS): the budget class that the agent names
#                  (agents[].budgetClass, ADR 0029), or the release's gateway.policy.tokenBudget when the agent names none. When it cannot read the release
#                  (no helm, no release, no such class) it uses 1000000, the chart default, and says why. The flag always wins. The output and summary.json
#                  say which one was used.
#                  Before each run after the first, the script estimates the run from the largest run so far (input plus output tokens, read from
#                  the metric) and, if it does not fit in what is left of the last hour, waits with a printed countdown until it does. --no-wait
#                  stops instead. Needs the token metric; without it there is no estimate and no wait.
# --no-wait        With --budget-tokens-per-hour: stop with exit 3 instead of waiting for the budget.
# --include-answers  Put the answers in the reports of DIR (hash only otherwise). Synthetic data, but the answers can hold anything the model wrote.
#
# Env: CLUSTER | KUBE_CONTEXT, KUBECTL, OA_EVAL (a built oa-eval; otherwise it is built with go), EVAL_TOKEN_DURATION (30m),
#      EVAL_AUDIT_SETTLE (6s), EVAL_CASE_TIMEOUT (300s), METRICS_SCRAPE_SECONDS (30) and METRICS_SCRAPE_MARGIN (5), GATE_NAMESPACE, MCP_NAMESPACE, KAGENT_NAMESPACE,
#      OBS_NAMESPACE, SCHEDULES_NAMESPACE, EVAL_RESET_TIMEOUT (240), EVAL_SWEEP_TIMEOUT (420).
# The gate token is minted per call of oa-eval (short lived), kept in a shell variable, handed to oa-eval through a named pipe in a private
# directory, and never written to a file, an argument or the output. Every port-forward and background reader stops on every way out.
# A model call that the gateway or the provider refuses (HTTP 429, a spent token budget) with no tool call is NOT RUN, not a failure: it is left out of
# the pass rate, the rest of the run is not sent, and the script stops with a message. The sweep is skipped then too.
# Env also: EVAL_BUDGET_WINDOW_SECONDS (3600), EVAL_COUNTDOWN_STEP (30).
# Exit: 0 the measurement ran (read summary.json for the rates), 1 a setup failure or a failed sweep check, 2 wrong usage,
#       3 the budget stopped it (a model call was refused, or the next run does not fit and --no-wait was given): the summary covers what ran.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
die() { echo "ERROR: $*" >&2; exit 1; }
usage() { awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit "${1:-2}"; }
log() { printf '%s\n' "$*"; }

# ---- arguments ----------------------------------------------------------------------------------------------------------------------------
[ $# -ge 1 ] || usage 2
case "$1" in -h | --help) usage 0 ;; esac
UC=$1; shift
case "$UC" in bank | equipment | software-org) ;; *) echo "ERROR: the use case is bank, equipment or software-org, not '$UC'" >&2; usage 2 ;; esac
BUDGET_FLAG=0; BUDGET_SOURCE=""
BUDGET=1000000; NO_WAIT=0; RUNS=""; OUT=""; RESET=0; SWEEP=0; TOKENS_MODE="per-run"; ONLY=""; INCLUDE_ANSWERS=0; METRICS_UID_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --runs) RUNS=${2:-}; shift 2 || usage 2 ;;
    --out) OUT=${2:-}; shift 2 || usage 2 ;;
    --reset-records) RESET=1; shift ;;
    --sweep) SWEEP=1; shift ;;
    --tokens) TOKENS_MODE=${2:-}; shift 2 || usage 2 ;;
    --only) ONLY=${2:-}; shift 2 || usage 2 ;;
    --metrics-user-id) METRICS_UID_ARG=${2:-}; shift 2 || usage 2 ;;
    --include-answers) INCLUDE_ANSWERS=1; shift ;;
    --budget-tokens-per-hour) BUDGET=${2:-}; BUDGET_FLAG=1; shift 2 || usage 2 ;;
    --no-wait) NO_WAIT=1; shift ;;
    -h | --help) usage 0 ;;
    *) echo "ERROR: unknown argument '$1'" >&2; usage 2 ;;
  esac
done
case "$RUNS" in '' | *[!0-9]*) echo "ERROR: --runs N is required (a whole number from 1 to 200)" >&2; usage 2 ;; esac
[ "$RUNS" -ge 1 ] && [ "$RUNS" -le 200 ] || { echo "ERROR: --runs must be from 1 to 200, not $RUNS" >&2; usage 2; }
case "$BUDGET" in '' | *[!0-9]* | 0) echo "ERROR: --budget-tokens-per-hour is a whole number above 0" >&2; usage 2 ;; esac
case "$TOKENS_MODE" in per-run | per-case | off) ;; *) echo "ERROR: --tokens is per-run, per-case or off, not '$TOKENS_MODE'" >&2; usage 2 ;; esac
case "$METRICS_UID_ARG" in *[!A-Za-z0-9._:-]*) echo "ERROR: --metrics-user-id may hold letters, digits and . _ : - only" >&2; usage 2 ;; esac
case "$ONLY" in *[!A-Za-z0-9._,-]*) echo "ERROR: --only takes case ids separated by commas" >&2; usage 2 ;; esac

# ---- the cluster: kind only, named, in agreement (the rule of the install scripts); nothing is changed before this ------------------------------
[ -n "${CLUSTER:-}${KUBE_CONTEXT:-}" ] || die "set CLUSTER (the kind cluster name) or KUBE_CONTEXT: there is no default cluster. Nothing was changed."
DISAGREE=0
[ -z "${CLUSTER:-}" ] || [ -z "${KUBE_CONTEXT:-}" ] || [ "$KUBE_CONTEXT" = "kind-$CLUSTER" ] || DISAGREE=1
CLUSTER=${CLUSTER:-${KUBE_CONTEXT#kind-}}
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-$CLUSTER}
case "$KUBE_CONTEXT" in
  kind-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind cluster (kind-<name>). Set CLUSTER or KUBE_CONTEXT. Nothing was changed." ;;
esac
[ "$DISAGREE" = 0 ] || die "CLUSTER=$CLUSTER and KUBE_CONTEXT=$KUBE_CONTEXT name different clusters (the context of $CLUSTER is kind-$CLUSTER). Set one of them, or make them agree. Nothing was changed."
KUBECTL=${KUBECTL:-kubectl}
KC=("$KUBECTL" --context "$KUBE_CONTEXT")

# ---- the use case -------------------------------------------------------------------------------------------------------------------------
GATE_NS=${GATE_NAMESPACE:-openagentix-gateway}; MCPNS=${MCP_NAMESPACE:-mcp-tools}; KNS=${KAGENT_NAMESPACE:-kagent}
OBS_NS=${OBS_NAMESPACE:-openagentix-observability}; SCHED_NS=${SCHEDULES_NAMESPACE:-openagentix-schedules}; DESK_NS=openagentix-system
UCDIR=$ROOT/examples/use-cases/$UC
CASES_SRC=$UCDIR/eval/cases-real.yaml
case "$UC" in
  bank)
    RECORDS=1; RNS=fernvale-records; PROFILE=disputes; SA=disputes-desk; USER_ID=desk:eval; AGENT=dispute-agent
    ID_RE='DSP'; CRON='deadline-sweep'; AUDIT_JQ=$ROOT/hack/ci/bank-audit-tools.jq; SNAP_PATHS="cases?limit=200 approvals outbox ledger"
    WRITE_TOOLS="records_attach_evidence records_set_route records_set_case_status records_draft_letter records_draft_chargeback records_set_timer records_request_approval" ;;
  equipment)
    RECORDS=1; RNS=kestrel-records; PROFILE=dealer; SA=service-desk; USER_ID=service:eval; AGENT=service-agent
    ID_RE='SVC'; CRON='fleet-sweep'; AUDIT_JQ=$ROOT/hack/ci/equipment-audit-tools.jq; SNAP_PATHS="cases?limit=200 approvals outbox"
    WRITE_TOOLS="dealer-records_set_diagnosis dealer-records_create_work_order dealer-records_draft_parts_order dealer-records_draft_warranty_claim dealer-records_draft_customer_notice dealer-records_propose_slot dealer-records_set_timer dealer-records_escalate_to_person dealer-records_request_approval" ;;
  software-org)
    RECORDS=0; RNS=""; PROFILE=rca; SA=rca-desk; USER_ID=sre:eval; AGENT=pod-rca
    ID_RE=''; CRON=''; AUDIT_JQ=$ROOT/hack/ci/rca-audit-tools.jq; SNAP_PATHS=""; WRITE_TOOLS="" ;;
esac
METRICS_UID=${METRICS_UID_ARG:-$AGENT}
[ -f "$CASES_SRC" ] || die "the set for a real model is missing: $CASES_SRC"
[ -f "$AUDIT_JQ" ] || die "the audit filter is missing: $AUDIT_JQ"

if [ "$RECORDS" = 1 ] && [ "$RESET" != 1 ]; then
  die "$UC needs --reset-records. Each run starts from the seed, so the records pod of the use case (namespace $RNS, context $KUBE_CONTEXT) is deleted before every run and its store, an emptyDir, is lost: every case, approval, outbox item and ledger row of $UC, including a request you made by hand. Give --reset-records to allow that. Nothing was changed."
fi
if [ "$RECORDS" = 0 ] && [ "$RESET" = 1 ]; then die "software-org has no records store: --reset-records does not apply. Nothing was changed."; fi
if [ "$SWEEP" = 1 ] && [ -z "$CRON" ]; then die "software-org has no schedule to run by hand: --sweep does not apply. Nothing was changed."; fi
for c in jq curl awk sed; do command -v "$c" >/dev/null || die "$c is required"; done

PIDS=(); PRIV=""
JOB_NAME=""
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  for p in ${PIDS[@]+"${PIDS[@]}"}; do wait "$p" 2>/dev/null || true; done
  if [ -n "$JOB_NAME" ]; then "${KC[@]}" delete job -n "$SCHED_NS" "$JOB_NAME" --ignore-not-found >/dev/null 2>&1 || true; fi
  [ -z "$PRIV" ] || rm -rf "$PRIV"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---- private state: a directory only the user can read, and the output directory ---------------------------------------------------------------
umask 077
TMP_BASE=${TMPDIR:-/tmp}
PRIV=$(mktemp -d "${TMP_BASE%/}/use-case-eval-priv.XXXXXX")
if [ -z "$OUT" ]; then OUT=$(mktemp -d "${TMP_BASE%/}/use-case-eval.XXXXXX")
else
  mkdir -p "$OUT"
  [ -z "$(ls -A "$OUT")" ] || die "the output directory $OUT is not empty: give a new or empty one"
fi
OUT=$(cd "$OUT" && pwd); chmod 700 "$OUT"

stop_pid() { # stop_pid <pid>: stop one background process and forget it
  local pid=$1 p keep=()
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for p in ${PIDS[@]+"${PIDS[@]}"}; do [ "$p" = "$pid" ] || keep+=("$p"); done
  PIDS=(${keep[@]+"${keep[@]}"})
}

PF_PORT=""; PF_PID=""
start_pf() { # start_pf <namespace> <target> <remote port>: sets PF_PORT and PF_PID; the local port is chosen by kubectl
  local log; log=$(mktemp "$PRIV/pf.XXXXXX")
  "${KC[@]}" port-forward -n "$1" "$2" ":$3" >"$log" 2>&1 &
  PF_PID=$!; PIDS+=("$PF_PID")
  PF_PORT=""
  local _
  for _ in $(seq 1 60); do
    PF_PORT=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$log" | head -1)
    [ -z "$PF_PORT" ] || return 0
    kill -0 "$PF_PID" 2>/dev/null || die "port-forward to $2 in $1 failed: $(head -c 400 "$log")"
    sleep 0.5
  done
  die "port-forward to $2 in $1 did not come up in 30 s: $(head -c 400 "$log")"
}
wait_http() { # wait_http <url> <what>
  local _
  for _ in $(seq 1 60); do curl -fsS -m 3 -o /dev/null "$1" 2>/dev/null && return 0; sleep 0.5; done
  die "$2 did not answer at $1 within 30 s (a port-forward that started is not a service that answers)"
}

# ---- preflight (read only) ----------------------------------------------------------------------------------------------------------------
log "# use-case-eval: $UC, $RUNS run(s), context $KUBE_CONTEXT, output $OUT"
"${KC[@]}" get namespace "$GATE_NS" -o name >/dev/null 2>&1 || die "cannot read namespace $GATE_NS on context $KUBE_CONTEXT: is the kind cluster up and the platform installed?"
"${KC[@]}" get service a2a-gate -n "$GATE_NS" >/dev/null 2>&1 || die "no Service a2a-gate in $GATE_NS: the A2A gate is not installed"
"${KC[@]}" get serviceaccount "$SA" -n "$DESK_NS" >/dev/null 2>&1 || die "no ServiceAccount $SA in $DESK_NS: install the $UC use case first (it creates the caller)"
if [ "$RECORDS" = 1 ]; then "${KC[@]}" get deployment records -n "$RNS" >/dev/null 2>&1 || die "no Deployment records in $RNS: install the $UC use case first"; fi
TS_PODS=$("${KC[@]}" get pods -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" -o name 2>/dev/null || true)
[ -n "$TS_PODS" ] || die "no tool server pod (app=virtualmcpserver, toolhive-name=tools-$PROFILE) in $MCPNS: the audit lines come from it, and without them no tool check can pass"

OA=${OA_EVAL:-}
if [ -z "$OA" ]; then
  command -v go >/dev/null || die "go is required to build tools/oa-eval (or set OA_EVAL to a built oa-eval)"
  OA=$PRIV/oa-eval
  (cd "$ROOT/tools/oa-eval" && CGO_ENABLED=0 go build -trimpath -o "$OA" ./cmd/oa-eval) || die "oa-eval did not build"
fi
[ -x "$OA" ] || die "OA_EVAL=$OA is not an executable file"

# ---- the budget of the key: the flag, else the class of the release (helm get values), else the chart default ---------------------------------------
resolve_budget() {
  local helm=${HELM:-helm} rel=${RELEASE:-openagentix} relns=${RELEASE_NS:-openagentix-system} vals err why line kind cls tok unit per
  if [ "$BUDGET_FLAG" = 1 ]; then BUDGET_SOURCE="from the flag --budget-tokens-per-hour"; return 0; fi
  why=""
  if ! command -v "$helm" >/dev/null 2>&1; then why="helm was not found, so the release was not read"
  else
    err="$PRIV/helm.err"
    if ! vals=$("$helm" get values "$rel" -n "$relns" --kube-context "$KUBE_CONTEXT" -o json 2>"$err"); then
      if grep -qxF "Error: release: not found" "$err" 2>/dev/null; then why="no release values: $rel in $relns on $KUBE_CONTEXT has none"; else why="could not read the release $rel: $(head -n 1 "$err" 2>/dev/null | cut -c1-200)"; fi
    fi
  fi
  if [ -z "$why" ]; then
    line=$(printf '%s' "$vals" | jq -r --arg a "$AGENT" '
      (((.agents // []) | map(select(.name == $a)) | .[0].budgetClass) // "") as $c
      | if $c != "" then
          (((.gateway.policy.budgetClasses // []) | map(select(.name == $c)) | .[0]) // null) as $k
          | if $k == null then "missing|\($c)|0||" else "class|\($c)|\($k.tokens)|\($k.unit)|\($k.per)" end
        elif (.gateway.policy.tokenBudget.tokens // null) != null then "default||\(.gateway.policy.tokenBudget.tokens)|\(.gateway.policy.tokenBudget.unit // "Hours")|agent"
        else "none||0||" end' 2>/dev/null) || line=""
    IFS='|' read -r kind cls tok unit per <<<"$line"
    case "$kind" in
      class | default)
        case "$unit" in Hours) ;; Minutes) tok=$((tok * 60)) ;; Seconds) tok=$((tok * 3600)) ;; *) why="the release has an unknown unit '$unit' for the budget" ;; esac
        if [ -z "$why" ]; then
          BUDGET=$tok
          if [ "$kind" = class ]; then
            BUDGET_SOURCE="the class $cls of the release (read with helm get values $rel)"
            [ "$per" != class ] || BUDGET_SOURCE="$BUDGET_SOURCE; the class is shared by every key of the class, so other agents of it spend from the same budget and this script counts only its own runs"
          else BUDGET_SOURCE="the release's default budget (gateway.policy.tokenBudget; $AGENT names no class)"; fi
          return 0
        fi ;;
      missing) why="$AGENT names the class $cls, which the release does not define" ;;
      *) why="the release sets no budget for $AGENT (no class, no gateway.policy.tokenBudget)" ;;
    esac
  fi
  BUDGET=1000000
  BUDGET_SOURCE="the default 1000000 ($why)"
}
resolve_budget
log "# budget of the key of $AGENT: $BUDGET tokens an hour ($BUDGET_SOURCE)"

TOKEN_DURATION=${EVAL_TOKEN_DURATION:-30m}; SETTLE=${EVAL_AUDIT_SETTLE:-6s}; CASE_TIMEOUT=${EVAL_CASE_TIMEOUT:-300s}
SCRAPE_WAIT=$(( ${METRICS_SCRAPE_SECONDS:-30} + ${METRICS_SCRAPE_MARGIN:-5} ))
WINDOW=${EVAL_BUDGET_WINDOW_SECONDS:-3600}; COUNTDOWN_STEP=${EVAL_COUNTDOWN_STEP:-30}
RESET_TIMEOUT=${EVAL_RESET_TIMEOUT:-240}; SWEEP_TIMEOUT=${EVAL_SWEEP_TIMEOUT:-420}

# ---- tokens: the gateway's metric in the bundled VictoriaMetrics --------------------------------------------------------------------------------
TOK_OK=0; TOK_REASON=""; VM_PORT=""
tok_setup() {
  [ "$TOKENS_MODE" != off ] || { TOK_REASON="not read: --tokens off"; return 0; }
  if ! "${KC[@]}" get service victoria-metrics -n "$OBS_NS" >/dev/null 2>&1; then
    TOK_REASON="no Service victoria-metrics in $OBS_NS: observability is off or uses another store. The gateway exports agentgateway_gen_ai_client_token_usage_sum only when it is scraped"
    return 0
  fi
  local log; log=$(mktemp "$PRIV/vm.XXXXXX")
  "${KC[@]}" port-forward -n "$OBS_NS" svc/victoria-metrics :8428 >"$log" 2>&1 &
  local pid=$! _; PIDS+=("$pid")
  for _ in $(seq 1 60); do
    VM_PORT=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$log" | head -1)
    [ -z "$VM_PORT" ] || break
    kill -0 "$pid" 2>/dev/null || { TOK_REASON="port-forward to victoria-metrics failed: $(head -c 200 "$log")"; return 0; }
    sleep 0.5
  done
  [ -n "$VM_PORT" ] || { TOK_REASON="port-forward to victoria-metrics did not come up"; return 0; }
  for _ in $(seq 1 30); do curl -fsS -m 3 -o /dev/null -G "http://127.0.0.1:$VM_PORT/api/v1/query" --data-urlencode 'query=vector(1)' 2>/dev/null && { TOK_OK=1; return 0; }; sleep 0.5; done
  TOK_REASON="the metrics store did not answer a query"
}
tok_query() { curl -fsS -m 10 -G "http://127.0.0.1:$VM_PORT/api/v1/query" --data-urlencode "query=$1"; }
tok_read() { # tok_read: prints {"input":N,"output":N,...} (the sum of the counter by token type for the agent's key); {} when there is no series
  local body
  body=$(tok_query "sum by (gen_ai_token_type)(agentgateway_gen_ai_client_token_usage_sum{user_id=\"$METRICS_UID\"})") || return 1
  jq -c 'if .status == "success" then ([.data.result[] | {key: (.metric.gen_ai_token_type // "unknown"), value: (.value[1] | tonumber)}] | from_entries) else error("query failed") end' <<<"$body"
}
tok_ids() { tok_query 'count by (user_id)(agentgateway_gen_ai_client_token_usage_sum)' 2>/dev/null | jq -r '[.data.result[].metric.user_id] | join(", ")' 2>/dev/null || true; }
TOK_DELTA=null; TOK_WHY=""
tok_delta() { # tok_delta <before json> <after json>: sets TOK_DELTA (json or null) and TOK_WHY
  TOK_DELTA=null; TOK_WHY=""
  if [ "$2" = "{}" ]; then TOK_WHY="the metrics store has no token series for user_id=$METRICS_UID (user_id values it has: $(tok_ids)); set --metrics-user-id"; return 0; fi
  local d
  d=$(jq -nc --argjson a "$1" --argjson b "$2" '(($a | keys) + ($b | keys) | unique) | map({key: ., value: (($b[.] // 0) - ($a[.] // 0))}) | from_entries')
  if [ "$(jq -r '[.[] | select(. < 0)] | length' <<<"$d")" != 0 ]; then TOK_WHY="a token counter went down during the window (the gateway restarted?)"; return 0; fi
  if [ "$(jq -r '((.input // 0) + (.output // 0)) == 0' <<<"$d")" = true ]; then TOK_WHY="no new tokens were recorded in the window for user_id=$METRICS_UID (the scrape had not landed, or another gateway key is in use)"; return 0; fi
  TOK_DELTA=$d
}
tok_setup
if [ "$TOK_OK" = 1 ]; then log "# tokens: read from the gateway metric agentgateway_gen_ai_client_token_usage_sum, user_id=$METRICS_UID, mode $TOKENS_MODE"
else log "# tokens: NOT AVAILABLE: $TOK_REASON"; TOKENS_SCOPE="not available"; fi
if [ "$TOK_OK" = 1 ]; then TOKENS_SCOPE=${TOKENS_MODE/per-run/per run}; TOKENS_SCOPE=${TOKENS_SCOPE/per-case/per case}; fi

# ---- the audit source: the AUDIT lines of the use case's tool server as JSON lines with a tool field -----------------------------------------------
audit_pull() { # audit_pull <out file>
  local tmp; tmp=$(mktemp "$1.XXXXXX")
  if "${KC[@]}" logs -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-$PROFILE" --all-containers --tail=-1 2>/dev/null | jq -cR -f "$AUDIT_JQ" 2>/dev/null >"$tmp"; then mv "$tmp" "$1"; else rm -f "$tmp"; return 1; fi
}

# ---- records: reset, REST, year ------------------------------------------------------------------------------------------------------------------
reset_records() {
  cat >&2 <<EOF
!!! RESET: deleting the records pod of the $UC use case (namespace $RNS, context $KUBE_CONTEXT).
!!! Its store is an emptyDir: every case, approval, outbox item and ledger row of $UC is replaced by the seed.
!!! A request you made by hand is gone. You gave --reset-records.
EOF
  "${KC[@]}" delete pod -n "$RNS" -l app=records --wait=true >/dev/null || die "could not delete the records pod in $RNS"
  local deadline=$((SECONDS + RESET_TIMEOUT)) ready
  while :; do
    ready=$("${KC[@]}" get pods -n "$RNS" -l app=records -o json 2>/dev/null | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' 2>/dev/null || echo 0)
    [ "${ready:-0}" = 1 ] && break
    [ "$SECONDS" -lt "$deadline" ] || die "the records pod in $RNS was not Ready within ${RESET_TIMEOUT}s after the reset"
    sleep 2
  done
}
SEED_YEAR=""
detect_year() { # detect_year <records base url>: the seed ids carry the year of the day the pod started
  local _
  SEED_YEAR=""
  for _ in $(seq 1 60); do
    SEED_YEAR=$(curl -fsS -m 5 "$1/cases?limit=200" 2>/dev/null | jq -r --arg p "$ID_RE" '[.cases[]?.id | capture("^" + $p + "-(?<y>[0-9]{4})-") | .y] | unique | first // empty' 2>/dev/null || true)
    [ -z "$SEED_YEAR" ] || return 0
    sleep 1
  done
  die "the records service in $RNS has no seeded cases after 60 s (the seed did not run, or it answers something else)"
}
sha256() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
snapshot() { # snapshot <base url>: one hash per record list, as "name=hash ..."
  local p out="" body
  for p in $SNAP_PATHS; do
    body=$(curl -fsS -m 15 "$1/$p") || die "cannot read $1/$p for the before/after comparison"
    out="$out ${p%%\?*}=$(jq -S -c . <<<"$body" | sha256)"
  done
  echo "${out# }"
}

# ---- one call of oa-eval, with a token that never touches a file --------------------------------------------------------------------------------
# mint_and_run <report> <cases> <gate port> <records port or -> <audit file> <log> [extra oa-eval args]
mint_and_run() {
  local report=$1 cases=$2 gp=$3 rp=$4 audit=$5 evlog=$6; shift 6
  local TOKEN fifo=$PRIV/token feeder rc args
  TOKEN=$("${KC[@]}" create token "$SA" -n "$DESK_NS" --audience openagentix-a2a --duration "$TOKEN_DURATION") || die "kubectl create token $SA failed"
  [ -n "$TOKEN" ] || die "kubectl create token $SA gave no token"
  rm -f "$fifo"; mkfifo "$fifo"; chmod 600 "$fifo"
  # One write per pipe: oa-eval reads the gate token file once, and a second writer that opens at once would be read as a second copy of the token.
  ( printf '%s' "$TOKEN" >"$fifo" 2>/dev/null ) &
  feeder=$!; PIDS+=("$feeder")
  args=(run --cases "$cases" --gate-url "http://127.0.0.1:$gp" --namespace "$KNS" --token-file "$fifo" --user-id "$USER_ID"
    --audit "$audit" --audit-settle "$SETTLE" --timeout "$CASE_TIMEOUT" --out "$report")
  [ "$rp" = - ] || args+=(--state-base "http://127.0.0.1:$rp")
  [ "$INCLUDE_ANSWERS" != 1 ] || args+=(--include-answers)
  set +e
  "$OA" "${args[@]}" "$@" 2>&1 | tee -a "$evlog"
  rc=${PIPESTATUS[0]}
  set -e
  stop_pid "$feeder"; rm -f "$fifo"; unset TOKEN
  return "$rc"
}

case_ids() { sed -nE 's/^  - id: *([A-Za-z0-9._-]+).*/\1/p' "$1"; }

ABORT=""
BUDGET_STOP=""      # set when the budget stops the measurement: the message
BUDGET_LOG=$PRIV/budget.log   # lines: <epoch seconds at the end of a run> <input plus output tokens of the run>
: >"$BUDGET_LOG"
tokens_in_window() { # tokens of the runs that ended in the last hour
  awk -v now="$(date +%s)" -v w="$WINDOW" 'now - $1 < w {s += $2} END {print s + 0}' "$BUDGET_LOG"
}
note_run_tokens() { # note_run_tokens <tokens json or null>: the budget tokens of a run (input plus output)
  local t
  t=$(jq -r 'if . == null then 0 else ((.input // 0) + (.output // 0)) end' <<<"$1")
  [ "$t" = 0 ] || echo "$(date +%s) $t" >>"$BUDGET_LOG"
}
budget_gate() { # before a run: wait until the next run (as big as the biggest so far) fits in the hourly budget; sets BUDGET_STOP and returns 1 when it cannot
  [ "$TOK_OK" = 1 ] && [ -s "$BUDGET_LOG" ] || return 0
  local need now used free_at left
  need=$(awk 'BEGIN {m = 0} $2 > m {m = $2} END {print m}' "$BUDGET_LOG")
  if [ "$need" -gt "$BUDGET" ]; then
    BUDGET_STOP="a run used about $need tokens, which is more than the hourly budget of $BUDGET tokens per key: no run fits. Lower the number of cases with --only, or raise the budget of the gateway key."
    return 1
  fi
  while :; do
    now=$(date +%s); used=$(tokens_in_window)
    [ $((used + need)) -gt "$BUDGET" ] || return 0
    # the first moment at which enough of the earlier runs have left the window
    free_at=$(sort -n "$BUDGET_LOG" | awk -v need="$need" -v b="$BUDGET" -v w="$WINDOW" '{ts[NR] = $1; tk[NR] = $2; tot += $2}
      END {rest = tot; for (i = 1; i <= NR; i++) {rest -= tk[i]; if (rest + need <= b) {print ts[i] + w; exit}} print ts[NR] + w}')
    if [ "$NO_WAIT" = 1 ]; then
      BUDGET_STOP="the next run needs about $need tokens and $used tokens were used in the last hour (budget $BUDGET): it does not fit, and --no-wait was given. Wait about $((free_at - now)) s, or lower --runs."
      return 1
    fi
    left=$((free_at - now)); [ "$left" -gt 0 ] || left=1
    log "    waiting for the gateway budget: the next run needs about $need tokens, $used of $BUDGET were used in the last hour; $left s to go"
    while [ "$left" -gt 0 ]; do
      sleep "$([ "$left" -lt "$COUNTDOWN_STEP" ] && echo "$left" || echo "$COUNTDOWN_STEP")"
      now=$(date +%s); left=$((free_at - now))
      [ "$left" -le 0 ] || log "    ... $left s to go"
    done
  done
}
refused_message() { # the message when a model call was refused
  local used; used=$(tokens_in_window)
  echo "the agent's gateway budget is exhausted: $used tokens used in the last hour by this script's runs (budget $BUDGET per key), and a model call was refused (HTTP 429 or another model-call error). Wait or lower --runs."
}
append_results() { # append_results <run> <report> <tokens json or null>
  jq -c --argjson run "$1" --argjson tok "$3" '.cases[] | {run: $run, id: .id, pass: .pass, not_run: (.not_run // false), reason: (.not_run_reason // null), ms: .ms, tool_calls: ((.tools_seen // []) | length), failed: [(.checks // [])[] | select(.pass | not) | {name: .name, detail: (.detail // "")}], tokens: $tok}' "$2" >>"$OUT/results.jsonl"
}

run_once() { # run_once <n>
  local n=$1 rundir cases ids id rc report aud base gp rp="-" tok_b tok_a
  rundir=$(printf '%s/run-%03d' "$OUT" "$n"); mkdir -p "$rundir"
  log; log "=== run $n of $RUNS ($(date -u +%H:%M:%SZ))"
  [ "$RECORDS" != 1 ] || reset_records
  start_pf "$GATE_NS" svc/a2a-gate 8080; gp=$PF_PORT; local gpid=$PF_PID
  wait_http "http://127.0.0.1:$gp/healthz" "the A2A gate"
  local rpid=""
  if [ "$RECORDS" = 1 ]; then
    start_pf "$RNS" deploy/records 8081; rp=$PF_PORT; rpid=$PF_PID
    wait_http "http://127.0.0.1:$rp/readyz" "the records service"
    detect_year "http://127.0.0.1:$rp"
    sed "s/$ID_RE-2026-/$ID_RE-$SEED_YEAR-/g" "$CASES_SRC" >"$rundir/cases.yaml"
    log "    seed year $SEED_YEAR; records state starts from the seed"
  else
    cp "$CASES_SRC" "$rundir/cases.yaml"
  fi
  cases=$rundir/cases.yaml
  aud=$rundir/audit-all.jsonl
  audit_pull "$aud" || die "cannot read the audit lines of the tool server (kubectl logs of tools-$PROFILE in $MCPNS)"
  base=$(wc -l <"$aud" | tr -d ' ')
  ( set +e; while :; do audit_pull "$aud"; sleep 2; done ) &
  local refpid=$!; PIDS+=("$refpid")

  ids=$(case_ids "$cases")
  if [ -n "$ONLY" ]; then
    local want; want=""
    for id in $ids; do case ",$ONLY," in *",$id,"*) want="$want $id" ;; esac; done
    [ -n "$want" ] || die "--only $ONLY matches no case of $CASES_SRC"
    ids=$want
  fi
  : >"$rundir/eval.out"
  local run_tok_b="{}" run_tok_a="{}"
  if [ "$TOK_OK" = 1 ]; then run_tok_b=$(tok_read) || { TOK_OK=0; TOK_REASON="the metrics store stopped answering"; }; fi
  local sum_tok=null
  if [ "$TOKENS_MODE" = per-case ] && [ "$TOK_OK" = 1 ]; then
    local tok_a_prev=$run_tok_b
    for id in $ids; do
      report=$rundir/report-$id.json
      tok_b=$tok_a_prev
      set +e; mint_and_run "$report" "$cases" "$gp" "$rp" "$aud" "$rundir/eval.out" --only "$id"; rc=$?; set -e
      { [ "$rc" -le 1 ] || [ "$rc" = 3 ]; } && [ -s "$report" ] || { ABORT="oa-eval exited $rc for case $id in run $n and wrote no report (see $rundir/eval.out)"; break; }
      sleep "$SCRAPE_WAIT"
      tok_a=$(tok_read) || tok_a="{}"
      tok_delta "$tok_b" "$tok_a"
      tok_a_prev=$tok_a
      append_results "$n" "$report" "$TOK_DELTA"
      [ -z "$TOK_WHY" ] || log "    tokens for $id: not available: $TOK_WHY"
      if [ "$(jq -r '[.cases[] | select(.not_run)] | length' "$report")" != 0 ]; then
        # the model refused this case: the rest is not sent
        local rest="" seen_it=0 r
        for r in $ids; do if [ "$seen_it" = 1 ]; then rest="$rest $r"; elif [ "$r" = "$id" ]; then seen_it=1; fi; done
        for r in $rest; do
          jq -nc --argjson run "$n" --arg id "$r" '{run: $run, id: $id, pass: false, not_run: true, reason: "not sent: an earlier case was refused by the model", ms: 0, tool_calls: 0, failed: [], tokens: null}' >>"$OUT/results.jsonl"
        done
        BUDGET_STOP=refused
        break
      fi
    done
    if [ -z "$ABORT" ]; then
      tok_delta "$run_tok_b" "$tok_a_prev"
      sum_tok=$TOK_DELTA
    fi
  else
    report=$rundir/report.json
    local only_args=(); [ -z "$ONLY" ] || only_args=(--only "$ONLY")
    set +e; mint_and_run "$report" "$cases" "$gp" "$rp" "$aud" "$rundir/eval.out" ${only_args[@]+"${only_args[@]}"}; rc=$?; set -e
    if { [ "$rc" -le 1 ] || [ "$rc" = 3 ]; } && [ -s "$report" ]; then
      if [ "$TOK_OK" = 1 ]; then
        sleep "$SCRAPE_WAIT"
        run_tok_a=$(tok_read) || run_tok_a="{}"
        tok_delta "$run_tok_b" "$run_tok_a"; sum_tok=$TOK_DELTA
        [ -z "$TOK_WHY" ] || log "    tokens of run $n: not available: $TOK_WHY"
      fi
      append_results "$n" "$report" null
      if [ "$(jq -r '[.cases[] | select(.not_run)] | length' "$report")" != 0 ]; then BUDGET_STOP="refused"; fi
    else
      ABORT="oa-eval exited $rc in run $n and wrote no report (see $rundir/eval.out)"
    fi
  fi
  note_run_tokens "$sum_tok"
  [ "$BUDGET_STOP" != refused ] || BUDGET_STOP=$(refused_message)
  stop_pid "$refpid"
  # the audit lines of this run's window
  sleep 1; audit_pull "$aud" || true
  tail -n +"$((base + 1))" "$aud" >"$rundir/audit-window.jsonl" 2>/dev/null || : >"$rundir/audit-window.jsonl"
  jq -nc --argjson run "$n" --argjson tok "$sum_tok" --argjson calls "$(wc -l <"$rundir/audit-window.jsonl" | tr -d ' ')" '{run: $run, tokens: $tok, audit_tool_calls: $calls}' >>"$OUT/runs.jsonl"
  stop_pid "$gpid"; [ -z "$rpid" ] || stop_pid "$rpid"
  [ -z "$ABORT" ] || return 1
}

# ---- the sweep: the suspended schedule, started by hand, must only read ---------------------------------------------------------------------------
SWEEP_JSON=null
run_sweep() {
  local dir=$OUT/sweep gpid rpid rp aud base before after name deadline st
  mkdir -p "$dir"
  log; log "=== sweep: the schedule $CRON, started once by hand (kubectl create job --from=cronjob/$CRON in $SCHED_NS)"
  "${KC[@]}" get cronjob "$CRON" -n "$SCHED_NS" >/dev/null 2>&1 || die "no CronJob $CRON in $SCHED_NS (CronJobs there: $("${KC[@]}" get cronjob -n "$SCHED_NS" -o name 2>&1 | tr '\n' ' ' | head -c 300))"
  start_pf "$RNS" deploy/records 8081; rp=$PF_PORT; rpid=$PF_PID
  wait_http "http://127.0.0.1:$rp/readyz" "the records service"
  aud=$dir/audit-all.jsonl
  audit_pull "$aud" || die "cannot read the audit lines of the tool server"
  base=$(wc -l <"$aud" | tr -d ' ')
  before=$(snapshot "http://127.0.0.1:$rp")
  name="$CRON-eval-$(date +%s)"
  JOB_NAME=$name
  "${KC[@]}" create job -n "$SCHED_NS" --from="cronjob/$CRON" "$name" >/dev/null || die "could not create the job from cronjob/$CRON"
  deadline=$((SECONDS + SWEEP_TIMEOUT)); st=""
  while :; do
    st=$("${KC[@]}" get job -n "$SCHED_NS" "$name" -o json 2>/dev/null | jq -r 'if (.status.succeeded // 0) > 0 then "succeeded" elif (.status.failed // 0) > 0 then "failed" else "running" end' 2>/dev/null || echo running)
    [ "$st" = running ] || break
    [ "$SECONDS" -lt "$deadline" ] || { st=timeout; break; }
    sleep 3
  done
  local ok=true why="" joblog="" refused=0
  if [ "$st" != succeeded ]; then
    joblog=$("${KC[@]}" logs -n "$SCHED_NS" "job/$name" --tail=20 2>&1 | head -c 600 | tr '\n' ' ')
    ok=false; why="the job $name ended as '$st'. Last lines of its log: $joblog"
    if printf '%s' "$joblog" | grep -Eqi 'agent run failed.*(429|too many requests|rate.?limit|quota|API error)|OpenAI API error'; then refused=1; fi
  fi
  sleep "${SETTLE%s}" 2>/dev/null || sleep 6
  audit_pull "$aud" || die "cannot read the audit lines of the tool server after the sweep"
  tail -n +"$((base + 1))" "$aud" >"$dir/audit-window.jsonl"
  after=$(snapshot "http://127.0.0.1:$rp")
  local calls writes w changed=""
  calls=$(wc -l <"$dir/audit-window.jsonl" | tr -d ' ')
  writes=0
  for w in $WRITE_TOOLS; do writes=$((writes + $(jq -r --arg t "$w" 'select(.tool == $t) | 1' "$dir/audit-window.jsonl" | wc -l | tr -d ' '))); done
  if [ "$before" != "$after" ]; then
    local a b
    for a in $before; do b=${a%%=*}; case " $after " in *" $a "*) ;; *) changed="$changed $b" ;; esac; done
  fi
  if [ "$refused" = 1 ]; then
    # the model refused a call (before the first tool call or part way): the sweep did not finish, which says nothing about whether it only reads
    BUDGET_STOP=$(refused_message)
    SWEEP_JSON=$(jq -nc --arg cron "$CRON" --arg job "$name" --arg why "${why#; }" '{schedule: $cron, job: $job, job_state: "failed", not_run: true, only_read: null, problem: $why}')
    log "    SWEEP NOT RUN: the model refused the call. $BUDGET_STOP"
    "${KC[@]}" delete job -n "$SCHED_NS" "$name" --ignore-not-found >/dev/null 2>&1 || true
    JOB_NAME=""
    stop_pid "$rpid"
    return 0
  fi
  [ "$calls" -gt 0 ] || { ok=false; why="$why; no tool call of the sweep was seen in the audit lines (the job may have run without reaching a tool, or the audit source lags)"; }
  [ "$writes" = 0 ] || { ok=false; why="$why; $writes write tool call(s) in the audit lines of the sweep"; }
  [ -z "$changed" ] || { ok=false; why="$why; the record changed during the sweep:$changed"; }
  SWEEP_JSON=$(jq -nc --arg cron "$CRON" --arg job "$name" --arg st "$st" --argjson calls "$calls" --argjson writes "$writes" --arg changed "${changed# }" --argjson ok "$ok" --arg why "${why#; }" \
    '{schedule: $cron, job: $job, job_state: $st, tool_calls: $calls, write_tool_calls: $writes, records_changed: ($changed | if . == "" then [] else split(" ") end), only_read: $ok, problem: (if $why == "" then null else $why end)}')
  log "    job $name: $st; $calls tool call(s), $writes write(s); record lists changed: ${changed:-none}"
  [ "$ok" = true ] && log "    SWEEP OK: it only read" || log "    SWEEP FAILED:${why}"
  "${KC[@]}" delete job -n "$SCHED_NS" "$name" --ignore-not-found >/dev/null 2>&1 || true
  JOB_NAME=""
  stop_pid "$rpid"
  [ "$ok" = true ]
}

# ---- the summary ---------------------------------------------------------------------------------------------------------------------------------
write_summary() { # write_summary <runs completed>
  local completed=$1
  [ -s "$OUT/results.jsonl" ] || { log "no results were collected"; return 0; }
  jq -s --arg uc "$UC" --arg ctx "$KUBE_CONTEXT" --argjson requested "$RUNS" --argjson completed "$completed" --arg scope "$TOKENS_SCOPE" --argjson tokok "$([ "$TOK_OK" = 1 ] && echo true || echo false)" \
    --arg reason "$TOK_REASON" --arg tuid "$METRICS_UID" --slurpfile runs "$OUT/runs.jsonl" --argjson sweep "$SWEEP_JSON" --arg abort "$ABORT" --argjson budget "$BUDGET" --arg bsrc "$BUDGET_SOURCE" --arg stop "$BUDGET_STOP" '
    def median: sort | if length == 0 then null elif length % 2 == 1 then .[(length - 1) / 2] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    def maxv: if length == 0 then null else max end;
    def tokmed($k): [.[] | .tokens | select(. != null) | .[$k] // empty] | median;
    def budgetmed: [.[] | .tokens | select(. != null) | ((.input // 0) + (.output // 0))] | median;
    {use_case: $uc, context: $ctx, runs_requested: $requested, runs_completed: $completed, aborted: (if $abort == "" then null else $abort end),
     tokens: {scope: $scope, available: $tokok, user_id: $tuid, reason: (if $tokok then null else $reason end), unit: "tokens, never a price"},
     cases: (group_by(.id) | map(. as $g | ([$g[] | select(.not_run | not)]) as $c | {id: $g[0].id, runs: ($c | length), not_run: ([$g[] | select(.not_run)] | length), passed: ([$c[] | select(.pass)] | length),
        pass_rate: (if ($c | length) == 0 then null else (([$c[] | select(.pass)] | length) / ($c | length)) end),
        failed_checks: ([$c[] | .failed[]] | group_by(.name) | map({check: .[0].name, count: length, example: .[0].detail}) | sort_by(-.count)),
        duration_ms: {median: ([$c[].ms] | median), max: ([$c[].ms] | maxv)},
        tool_calls: {median: ([$c[].tool_calls] | median), max: ([$c[].tool_calls] | maxv)},
        tokens: (if ([$c[] | select(.tokens != null)] | length) == 0 then null else {measured_runs: ([$c[] | select(.tokens != null)] | length), input_median: ($c | tokmed("input")), output_median: ($c | tokmed("output")), budget_tokens_median: ($c | budgetmed)} end)})),
     tokens_per_run: ($runs | map(select(.tokens != null) | {run: .run, tokens: .tokens, budget_tokens: ((.tokens.input // 0) + (.tokens.output // 0)), audit_tool_calls: .audit_tool_calls})),
     budget: {tokens_per_hour_per_key: $budget, source: $bsrc, stopped_by_budget: ($stop != ""), message: (if $stop == "" then null else $stop end), counts: "input plus output tokens of a run count against the key; a case that was refused is not run and is not in the pass rate"},
     sweep: $sweep}' "$OUT/results.jsonl" >"$OUT/summary.json"
  log; log "=== summary ($UC, $completed of $RUNS run(s) completed; $OUT/summary.json)"
  jq -r '.cases[] | [.id, "\(.passed)/\(.runs)" + (if .not_run > 0 then " (+\(.not_run) not run)" else "" end), (.duration_ms.median | tostring) + "ms", (.duration_ms.max | tostring) + "ms", (.tool_calls.median | tostring), (.tool_calls.max | tostring),
      (if .tokens == null then "-" else "\(.tokens.input_median // "-")/\(.tokens.output_median // "-")" end),
      ([.failed_checks[] | "\(.check) x\(.count)"] | join("; "))] | @tsv' "$OUT/summary.json" |
    { printf 'CASE\tPASSED\tMS-MEDIAN\tMS-MAX\tCALLS-MED\tCALLS-MAX\tTOKENS-IN/OUT-MEDIAN\tFAILED-CHECKS\n'; cat; } | column -t -s "$(printf '\t')" 2>/dev/null || cat
  if [ "$TOK_OK" = 1 ]; then
    log "tokens ($(jq -r .tokens.scope "$OUT/summary.json")): per run $(jq -c '[.tokens_per_run[] | {run, input: .tokens.input, output: .tokens.output}]' "$OUT/summary.json")"
  else
    log "tokens: not available: $TOK_REASON"
  fi
  if [ "$TOKENS_MODE" = per-run ] && [ "$TOK_OK" = 1 ]; then log "(tokens are per run: a run holds every case, so they are not split by case. Use --tokens per-case for that.)"; fi
}

# ---- go ------------------------------------------------------------------------------------------------------------------------------------------
: >"$OUT/results.jsonl"; : >"$OUT/runs.jsonl"
DONE=0
for n in $(seq 1 "$RUNS"); do
  if [ "$n" -gt 1 ] && ! budget_gate; then break; fi
  if run_once "$n"; then DONE=$n; else DONE=$((n - 1)); break; fi
  [ -z "$BUDGET_STOP" ] || break
done
SWEEP_RC=0
if [ -z "$ABORT" ] && [ "$SWEEP" = 1 ]; then
  if [ -n "$BUDGET_STOP" ]; then
    log; log "=== sweep: SKIPPED. $BUDGET_STOP"
    SWEEP_JSON=$(jq -nc --arg cron "$CRON" --arg why "$BUDGET_STOP" '{schedule: $cron, skipped: true, only_read: null, problem: $why}')
  else
    run_sweep || SWEEP_RC=1
  fi
fi
write_summary "$DONE"
if [ -n "$ABORT" ]; then die "stopped: $ABORT. The summary above covers the $DONE run(s) that finished."; fi
[ "$SWEEP_RC" = 0 ] || die "the sweep check failed (see above and $OUT/sweep)"
if [ -n "$BUDGET_STOP" ]; then
  log; log "STOPPED BY THE BUDGET: $BUDGET_STOP"
  log "The summary covers the $DONE run(s) that finished. Cases that were refused are 'not run' and are not in the pass rate."
  exit 3
fi
log; log "done. The measurement ran; the pass rates are in $OUT/summary.json. A pass rate over $RUNS run(s) is a rate for this model, these prompts and this cluster, nothing more."
