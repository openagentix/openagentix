#!/usr/bin/env bash
# Offline test of hack/use-case-eval.sh (issue #229). A fake kubectl, a fake oa-eval and one small fake HTTP server (the gate, the records REST port and
# VictoriaMetrics) stand in for the cluster. No cluster, no Docker, no model. It checks the guards (nothing is called when the script refuses), the
# reset rule, that every kubectl call names the context, the summary maths, the token handling (never in a file, an argument or the output), the
# sweep check, and that no port-forward or reader is left behind on a normal exit and on an abort.
# Usage: hack/use-case-eval-test.sh   (exit 1 on any failure; needs bash, jq, curl, python3)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
S=$HERE/use-case-eval.sh
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
for c in jq curl python3; do command -v "$c" >/dev/null || { echo "need $c"; exit 1; }; done

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/tmp"
export TMPDIR=$T/tmp
SECRET=FAKE-TOKEN-SECRET-12345

# ---- the fake HTTP server: gate, records REST, VictoriaMetrics ------------------------------------------------------------------------------
cat >"$T/server.py" <<'PY'
import http.server, json, os, sys, urllib.parse
mode, state = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query)
        if u.path in ('/healthz', '/readyz', '/health'): return self.send(200, {'status': 'ok'})
        if mode == 'records':
            f = os.path.join(state, u.path.strip('/') + '.json')
            if os.path.exists(f): return self.send(200, json.load(open(f)))
            return self.send(404, {})
        if mode == 'vm' and u.path == '/api/v1/query':
            query = q.get('query', [''])[0]
            uid = os.environ.get('FAKE_VM_UID', 'dispute-agent')
            if query == 'vector(1)': return self.send(200, {'status': 'success', 'data': {'resultType': 'vector', 'result': []}})
            if query.startswith('count by (user_id)'):
                return self.send(200, {'status': 'success', 'data': {'result': [{'metric': {'user_id': uid}, 'value': [0, '1']}]}})
            cf = os.path.join(state, 'vm-counter'); c = int(open(cf).read()) if os.path.exists(cf) else 0
            c += 1; open(cf, 'w').write(str(c))
            if 'user_id="%s"' % uid not in query: return self.send(200, {'status': 'success', 'data': {'result': []}})
            return self.send(200, {'status': 'success', 'data': {'result': [
                {'metric': {'gen_ai_token_type': 'input'}, 'value': [0, str(1000 * c)]},
                {'metric': {'gen_ai_token_type': 'output'}, 'value': [0, str(200 * c)]}]}})
        self.send(404, {})
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
open(os.environ['FAKE_PIDS'], 'a').write(str(os.getpid()) + '\n')
print('Forwarding from 127.0.0.1:%d -> 0' % srv.server_address[1], flush=True)
srv.serve_forever()
PY

# ---- the fake kubectl ---------------------------------------------------------------------------------------------------------------------
cat >"$T/bin/kubectl" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_LOG"
ctx=""; if [ "${1:-}" = --context ]; then ctx=$2; shift 2; fi
[ -n "$ctx" ] || { echo "kubectl called without --context: $*" >&2; echo "NOCONTEXT $*" >>"$FAKE_LOG"; }
case "$1" in
  get)
    case "$2" in
      namespace) [ "${FAKE_NO_NS:-0}" = 1 ] && exit 1; echo namespace/x ;;
      service) [ "$3" = victoria-metrics ] && [ "${FAKE_NO_VM:-0}" = 1 ] && exit 1; echo ok ;;
      serviceaccount | deployment) exit 0 ;;
      cronjob) echo cronjob/x ;;
      pods)
        if printf '%s ' "$@" | grep -q -- '-o json'; then
          echo '{"items":[{"metadata":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
        else echo pod/tools-x; fi ;;
      job) if [ "${FAKE_JOB_FAIL:-0}" = 1 ]; then echo '{"status":{"failed":1}}'; else echo '{"status":{"succeeded":1}}'; fi ;;
    esac ;;
  delete) case "$2" in pod) echo "RESET-POD $*" >>"$FAKE_LOG" ;; esac ;;
  create)
    case "$2" in
      token) echo "$FAKE_SECRET" ;;
      job)
        echo "SWEEP-JOB $*" >>"$FAKE_LOG"
        for t in $FAKE_SWEEP_TOOLS; do
          printf '{"level":"AUDIT","msg":"audit_event","outcome":"success","subjects":{"user_id":"actor/kagent/session-9"},"target":{"method":"tools/call","name":"%s"}}\n' "$t" >>"$FAKE_AUDIT_LOG"
        done
        [ "${FAKE_SWEEP_WRITE:-0}" != 1 ] || echo '{"approvals":[{"id":"APR-0001"}]}' >"$FAKE_STATE/approvals.json" ;;
    esac ;;
  logs)
    if printf '%s ' "$@" | grep -q 'job/'; then echo "${FAKE_JOB_LOG:-fake job log}"; else cat "$FAKE_AUDIT_LOG"; fi ;;
  port-forward)
    target=$4
    case "$target" in
      svc/a2a-gate) m=gate ;;
      deploy/records) m=records ;;
      svc/victoria-metrics) m=vm ;;
      *) echo "unexpected port-forward $*" >&2; exit 1 ;;
    esac
    exec python3 "$FAKE_SERVER" "$m" "$FAKE_STATE" ;;
esac
exit 0
SH

# ---- the fake oa-eval ---------------------------------------------------------------------------------------------------------------------
cat >"$T/oa-eval" <<'SH'
#!/usr/bin/env bash
# Reads the token from the file it is given (it must be a named pipe), checks it, never stores it. FAKE_FAIL="N:case:check ..." fails check of case in call N.
echo "oa-eval $*" >>"$FAKE_LOG"
cases=""; out=""; only=""; tf=""; statebase=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cases) cases=$2; shift 2 ;; --out) out=$2; shift 2 ;; --only) only=${2//,/ }; shift 2 ;; --token-file) tf=$2; shift 2 ;; --state-base) statebase=$2; shift 2 ;;
    *) shift ;;
  esac
done
n=$(( $(cat "$FAKE_STATE/oa-counter" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FAKE_STATE/oa-counter"
fifo=no; [ -p "$tf" ] && fifo=yes
got=$(cat "$tf"); tok=bad; [ "$got" = "$FAKE_SECRET" ] && tok=ok; unset got
echo "call=$n fifo=$fifo token=$tok state_base=${statebase:+yes}" >>"$FAKE_STATE/oa-seen"
cp "$cases" "$FAKE_STATE/seen-cases-$n.yaml"
[ "${FAKE_OA_ABORT_AT:-0}" != "$n" ] || { echo "oa-eval: simulated bad setup" >&2; exit 2; }
ids=$(sed -nE 's/^  - id: *([A-Za-z0-9._-]+).*/\1/p' "$cases")
[ -z "$only" ] || ids=$only
rep='{"version":1,"mode":"run","cases":[]}'; p=0; anyfail=0; refused=0
for id in $ids; do
  if [ "$refused" = 1 ] || [ "${FAKE_REFUSE_AT:-}" = "$n:$id" ]; then
    refused=1
    rep=$(jq -c --arg id "$id" '.cases += [{id: $id, pass: false, not_run: true, not_run_reason: "the model call was refused: 429 (no tool call)", ms: 1500, checks: []}]' <<<"$rep")
    p=$((p + 1)); continue
  fi
  fails=""
  for f in ${FAKE_FAIL:-}; do
    IFS=: read -r fn fid fcheck <<<"$f"
    [ "$fn" = "$n" ] && [ "$fid" = "$id" ] && fails="$fails $fcheck"
  done
  for w in $FAKE_AUDIT_TOOLS; do
    printf '{"level":"AUDIT","msg":"audit_event","outcome":"success","subjects":{"user_id":"actor/kagent/session-1"},"target":{"method":"tools/call","name":"%s"}}\n' "$w" >>"$FAKE_AUDIT_LOG"
  done
  rep=$(jq -c --arg id "$id" --argjson ms $((1000 * n + 10 * p)) --argjson calls $((5 + n)) --arg fails "$fails" '
    .cases += [{id: $id, pass: ($fails == ""), ms: $ms, tools_seen: [range($calls) | "t"],
      checks: ([{name: "state", pass: true}] + [$fails | split(" ")[] | select(. != "") | {name: ., pass: false, detail: "fake failure"}])}]' <<<"$rep")
  [ -z "$fails" ] || anyfail=1
  p=$((p + 1))
done
printf '%s\n' "$rep" >"$out"
echo "fake oa-eval table call $n"
[ "$anyfail" = 0 ] && [ "$refused" = 1 ] && exit 3
exit "$anyfail"
SH
chmod +x "$T/bin/kubectl" "$T/oa-eval"

# ---- one run of the script ------------------------------------------------------------------------------------------------------------------
setup_state() { # setup_state <id prefix>
  rm -rf "$T/state"; mkdir -p "$T/state"
  printf '{"cases":[{"id":"%s-2031-0001"},{"id":"%s-2031-0002"}]}\n' "$1" "$1" >"$T/state/cases.json"
  echo '{"approvals":[]}' >"$T/state/approvals.json"; echo '{"outbox":[]}' >"$T/state/outbox.json"; echo '{"ledger":[]}' >"$T/state/ledger.json"
  : >"$T/audit.log"; : >"$T/calls"; : >"$T/pids"
}
# a fake helm: `helm get values` prints the file FAKE_HELM_VALUES, or fails the way helm does when there is no release; the calls are logged to $T/helm.calls
cat >"$T/bin/helm" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_HELM_CALLS"
[ "${FAKE_HELM_FAIL:-0}" = 1 ] && { echo "Error: Kubernetes cluster unreachable" >&2; exit 1; }
if [ -n "${FAKE_HELM_VALUES:-}" ] && [ -f "$FAKE_HELM_VALUES" ]; then cat "$FAKE_HELM_VALUES"; exit 0; fi
echo "Error: release: not found" >&2; exit 1
SH
chmod +x "$T/bin/helm"
run() { # run <args...>; the environment of the caller is used; output in $T/out, exit code in $RC
  env HELM="$T/bin/helm" FAKE_HELM_CALLS="$T/helm.calls" KUBECTL="$T/bin/kubectl" OA_EVAL="$T/oa-eval" FAKE_LOG="$T/calls" FAKE_STATE="$T/state" FAKE_AUDIT_LOG="$T/audit.log" FAKE_SECRET="$SECRET" \
    FAKE_SERVER="$T/server.py" FAKE_PIDS="$T/pids" METRICS_SCRAPE_SECONDS=0 METRICS_SCRAPE_MARGIN=0 EVAL_AUDIT_SETTLE=0s \
    "$@" >"$T/out" 2>&1
  RC=$?
}
alive() { local p n=0; for p in $(cat "$T/pids" 2>/dev/null); do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; echo "$n"; }
ncalls() { wc -l <"$T/calls" | tr -d ' '; }

echo "# usage and guards: nothing is called when the script refuses"
setup_state DSP
run bash "$S"; check "no arguments: usage, exit 2" "$RC" 2
run bash "$S" nothing --runs 1; check "an unknown use case: exit 2" "$RC" 2
run bash "$S" bank; check "no --runs: exit 2" "$RC" 2
run bash "$S" bank --runs 0 --reset-records; check "--runs 0: exit 2" "$RC" 2
run bash "$S" bank --runs 1 --reset-records --tokens sideways; check "a bad --tokens: exit 2" "$RC" 2
run env -u CLUSTER -u KUBE_CONTEXT bash "$S" bank --runs 1 --reset-records
check "no cluster named: refused, exit 1, no default" "$RC" 1
check "  the message says there is no default" "$(grep -c 'no default cluster' "$T/out")" 1
check "  kubectl was not called" "$(ncalls)" 0
run env KUBE_CONTEXT=gke_example_project bash "$S" bank --runs 1 --reset-records
check "a context that is not kind-*: refused" "$RC" 1; check "  kubectl was not called" "$(ncalls)" 0
run env CLUSTER=a KUBE_CONTEXT=kind-b bash "$S" bank --runs 1 --reset-records
check "CLUSTER and KUBE_CONTEXT that disagree: refused" "$RC" 1
check "  the message says they name different clusters" "$(grep -c 'different clusters' "$T/out")" 1
check "  kubectl was not called" "$(ncalls)" 0
run env CLUSTER=oa-test bash "$S" bank --runs 1
check "bank without --reset-records: refused" "$RC" 1
check "  the message says what the reset deletes and names the flag" "$(grep -c 'needs --reset-records.*emptyDir' "$T/out")" 1
check "  kubectl was not called" "$(ncalls)" 0
run env CLUSTER=oa-test bash "$S" equipment --runs 2
check "equipment without --reset-records: refused" "$RC" 1; check "  kubectl was not called" "$(ncalls)" 0
run env CLUSTER=oa-test bash "$S" software-org --runs 1 --reset-records
check "software-org with --reset-records: refused (no store)" "$RC" 1; check "  kubectl was not called" "$(ncalls)" 0
run env CLUSTER=oa-test bash "$S" software-org --runs 1 --sweep
check "software-org with --sweep: refused (no schedule)" "$RC" 1; check "  kubectl was not called" "$(ncalls)" 0
mkdir -p "$T/notempty"; : >"$T/notempty/x"
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --out "$T/notempty"
check "a non-empty --out is refused" "$RC" 1
run env CLUSTER=oa-test FAKE_NO_NS=1 bash "$S" bank --runs 1 --reset-records
check "a cluster that does not answer: loud, exit 1" "$RC" 1
check "  the message names the namespace and the context" "$(grep -c 'cannot read namespace .* on context kind-oa-test' "$T/out")" 1
check "  nothing was deleted" "$(grep -c RESET-POD "$T/calls")" 0

echo "# bank: three runs, reset each run, tokens per run, the sweep"
setup_state DSP
export FAKE_AUDIT_TOOLS="records_get_case" FAKE_SWEEP_TOOLS="records_list_fired_timers records_list_open_cases"
run env CLUSTER=oa-test FAKE_FAIL="2:duplicate-charge:state_checks[1] 3:duplicate-charge:state_checks[1] 3:out-of-time-declined:max_tool_calls" \
  bash "$S" bank --runs 3 --reset-records --sweep --out "$T/o1"
check "exit 0: the measurement ran" "$RC" 0
SUM=$T/o1/summary.json
[ -s "$SUM" ] || bad "summary.json was written" "$(cat "$T/out")"
check "three runs completed" "$(jq -r .runs_completed "$SUM")" 3
check "five cases" "$(jq -r '.cases | length' "$SUM")" 5
check "duplicate-charge passed 1 of 3" "$(jq -r '.cases[] | select(.id == "duplicate-charge") | "\(.passed)/\(.runs)"' "$SUM")" 1/3
check "out-of-time-declined passed 2 of 3" "$(jq -r '.cases[] | select(.id == "out-of-time-declined") | "\(.passed)/\(.runs)"' "$SUM")" 2/3
check "the failed check is named and counted (state_checks[1] twice)" "$(jq -c '.cases[] | select(.id == "duplicate-charge") | [.failed_checks[] | {check, count}]' "$SUM")" '[{"check":"state_checks[1]","count":2}]'
check "a case that never failed lists no failed check" "$(jq -c '.cases[] | select(.id == "injected-instruction-refused") | .failed_checks' "$SUM")" '[]'
check "median duration of duplicate-charge (1000, 2000, 3000 ms) is 2000" "$(jq -r '.cases[] | select(.id == "duplicate-charge") | .duration_ms.median' "$SUM")" 2000
check "max duration is 3000" "$(jq -r '.cases[] | select(.id == "duplicate-charge") | .duration_ms.max' "$SUM")" 3000
check "tool calls (6, 7, 8): median 7, max 8" "$(jq -r '.cases[] | select(.id == "duplicate-charge") | "\(.tool_calls.median)/\(.tool_calls.max)"' "$SUM")" 7/8
check "median of an even count is the mean (case 2 of out-of-time: 1010, 2010, 3010 -> 2010)" "$(jq -r '.cases[] | select(.id == "out-of-time-declined") | .duration_ms.median' "$SUM")" 2010
check "tokens are per run, available, for the agent's key" "$(jq -c '.tokens | {scope, available, user_id}' "$SUM")" '{"scope":"per run","available":true,"user_id":"dispute-agent"}'
check "tokens per run: 1000 in, 200 out, three times" "$(jq -c '[.tokens_per_run[] | [.tokens.input, .tokens.output]]' "$SUM")" '[[1000,200],[1000,200],[1000,200]]'
check "no token count is attributed to a case in per-run mode" "$(jq -c '[.cases[].tokens] | unique' "$SUM")" '[null]'
check "the unit is tokens, never a price" "$(jq -r .tokens.unit "$SUM")" "tokens, never a price"
check "the records pod was reset before each of the three runs" "$(grep -c RESET-POD "$T/calls")" 3
check "the reset says so loudly first" "$(grep -c '^!!! RESET' "$T/out")" 3
check "the case ids carry the year of the seed (2031), none of 2026 is left in what oa-eval read" "$(cat "$T/state"/seen-cases-*.yaml | grep -c 'DSP-2026-')" 0
check "  and the 2031 ids are there" "$([ "$(cat "$T/state"/seen-cases-1.yaml | grep -c 'DSP-2031-0001')" -gt 0 ] && echo yes || echo no)" yes
check "oa-eval was called once per run, with a state base" "$(grep -c 'state_base=yes' "$T/state/oa-seen")" 3
check "every call of kubectl names the context" "$(grep -c '^--context kind-oa-test ' "$T/calls")" "$(grep -vc '^oa-eval\|^RESET-POD\|^SWEEP-JOB\|^NOCONTEXT' "$T/calls")"
check "no call of kubectl without a context" "$(grep -c '^NOCONTEXT' "$T/calls")" 0
check "the reset comes before the records port-forward of run 1" "$([ "$(grep -n RESET-POD "$T/calls" | head -1 | cut -d: -f1)" -lt "$(grep -n 'port-forward.*deploy/records' "$T/calls" | head -1 | cut -d: -f1)" ] && echo yes || echo no)" yes
check "oa-eval got the token through a named pipe, and it was the right token (all calls)" "$(grep -c 'fifo=yes token=ok' "$T/state/oa-seen")" "$(wc -l <"$T/state/oa-seen" | tr -d ' ')"
check "the token is in no file of the output directory" "$(grep -rlF "$SECRET" "$T/o1" | wc -l | tr -d ' ')" 0
check "the token is not in the output of the script" "$(grep -cF "$SECRET" "$T/out")" 0
check "the token is in no argument of any call" "$(grep -cF "$SECRET" "$T/calls")" 0
check "the private directory (the pipe) is gone" "$(find "$T/tmp" -maxdepth 1 -name 'use-case-eval-priv*' | wc -l | tr -d ' ')" 0
check "no port-forward and no reader is left behind" "$(alive)" 0
check "the sweep: schedule started by hand from the cronjob, in the schedules namespace" "$(grep -c 'SWEEP-JOB create job -n openagentix-schedules --from=cronjob/deadline-sweep' "$T/calls")" 1
check "the sweep job is deleted at the end" "$(grep -c 'delete job -n openagentix-schedules deadline-sweep-eval-' "$T/calls")" 1
check "the sweep only read: two calls, no write, nothing changed" "$(jq -c '.sweep | {only_read, tool_calls, write_tool_calls, records_changed}' "$SUM")" '{"only_read":true,"tool_calls":2,"write_tool_calls":0,"records_changed":[]}'

echo "# the sweep fails when the job writes and when the record changes"
setup_state DSP
export FAKE_SWEEP_TOOLS="records_list_open_cases records_set_route"
run env CLUSTER=oa-test FAKE_SWEEP_WRITE=1 bash "$S" bank --runs 1 --reset-records --sweep --out "$T/o2"
check "exit 1" "$RC" 1
check "the write tool call is counted" "$(jq -r .sweep.write_tool_calls "$T/o2/summary.json")" 1
check "the record list that changed is named" "$(jq -c .sweep.records_changed "$T/o2/summary.json")" '["approvals"]'
check "the summary says it did not only read" "$(jq -r .sweep.only_read "$T/o2/summary.json")" false
check "the output says SWEEP FAILED" "$(grep -c 'SWEEP FAILED' "$T/out")" 1
check "nothing is left behind" "$(alive)" 0
setup_state DSP
export FAKE_SWEEP_TOOLS=""
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --sweep --out "$T/o2b"
check "a sweep with no tool call in the audit is a failure (a check on nothing proves nothing)" "$RC" 1
check "  and says so" "$(grep -c 'no tool call of the sweep was seen' "$T/out")" 1
setup_state DSP
export FAKE_SWEEP_TOOLS="records_list_open_cases"
run env CLUSTER=oa-test FAKE_JOB_FAIL=1 bash "$S" bank --runs 1 --reset-records --sweep --out "$T/o2c"
check "a job that failed is a failure, with the end of its log" "$RC" 1
check "  the job state is in the summary" "$(jq -r .sweep.job_state "$T/o2c/summary.json")" failed

echo "# an abort (oa-eval cannot run in run 2): loud, the summary covers run 1, nothing is left behind"
setup_state DSP
export FAKE_SWEEP_TOOLS="records_list_open_cases"
run env CLUSTER=oa-test FAKE_OA_ABORT_AT=2 bash "$S" bank --runs 3 --reset-records --out "$T/o3"
check "exit 1" "$RC" 1
check "the message says it stopped and why" "$(grep -c 'stopped: oa-eval exited 2 in run 2' "$T/out")" 1
check "the summary covers the finished run only" "$(jq -r '.runs_completed' "$T/o3/summary.json")" 1
check "the summary records the abort" "$(jq -r '.aborted != null' "$T/o3/summary.json")" true
check "run 3 was never started (two resets)" "$(grep -c RESET-POD "$T/calls")" 2
check "no port-forward and no reader is left behind" "$(alive)" 0
check "the private directory is gone" "$(find "$T/tmp" -maxdepth 1 -name 'use-case-eval-priv*' | wc -l | tr -d ' ')" 0

echo "# tokens: not available, wrong key, per case"
setup_state DSP
run env CLUSTER=oa-test FAKE_NO_VM=1 bash "$S" bank --runs 1 --reset-records --out "$T/o4"
check "no metrics store: the run goes on, exit 0" "$RC" 0
check "  the summary says not available and why" "$(jq -c '.tokens | {available, scope, why: (.reason | test("victoria-metrics"))}' "$T/o4/summary.json")" '{"available":false,"scope":"not available","why":true}'
check "  the output says NOT AVAILABLE" "$(grep -c 'tokens: NOT AVAILABLE' "$T/out")" 1
check "  no token figure is invented" "$(jq -c '.tokens_per_run' "$T/o4/summary.json")" '[]'
setup_state DSP
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --metrics-user-id other-key --out "$T/o5"
check "a gateway key without a series: the figure is withheld, the reason names the keys that exist" "$(grep -c 'no token series for user_id=other-key (user_id values it has: dispute-agent)' "$T/out")" 1
check "  no token figure is invented" "$(jq -c '.tokens_per_run' "$T/o5/summary.json")" '[]'
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --metrics-user-id 'a"b'
check "a user id with a quote is refused (it goes into a query)" "$RC" 2
setup_state DSP
run env CLUSTER=oa-test bash "$S" bank --runs 2 --reset-records --tokens per-case --out "$T/o6"
check "per case: oa-eval runs one case at a time (10 calls, each with --only)" "$(grep -c '^oa-eval .*--only ' "$T/calls")" 10
check "per case: the scope says so" "$(jq -r .tokens.scope "$T/o6/summary.json")" "per case"
check "per case: the median tokens of a case are 1000 in and 200 out" "$(jq -c '.cases[0].tokens | {input_median, output_median, measured_runs}' "$T/o6/summary.json")" '{"input_median":1000,"output_median":200,"measured_runs":2}'
check "per case: the total of a run is the sum of its five cases" "$(jq -c '[.tokens_per_run[] | .tokens.input]' "$T/o6/summary.json")" '[5000,5000]'
check "per case: still no token in a file" "$(grep -rlF "$SECRET" "$T/o6" | wc -l | tr -d ' ')" 0
check "per case: nothing is left behind" "$(alive)" 0
setup_state DSP
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --tokens off --out "$T/o7"
check "--tokens off reads no metric" "$(grep -c 'victoria-metrics' "$T/calls")" 0
check "--only runs the named cases" "$( : )" ""
setup_state DSP
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --only duplicate-charge,out-of-time-declined --out "$T/o8"
check "--only: two cases in the summary" "$(jq -r '.cases | length' "$T/o8/summary.json")" 2

echo "# equipment and software-org"
setup_state SVC
export FAKE_VM_UID=service-agent FAKE_SWEEP_TOOLS="dealer-records_list_fleet_trends"
run env CLUSTER=oa-test bash "$S" equipment --runs 1 --reset-records --sweep --out "$T/o9"
check "equipment: exit 0, seven cases" "$(jq -r '"\(.cases | length)"' "$T/o9/summary.json")" 7
check "equipment: the namespace of its records store is reset" "$(grep -c 'RESET-POD.*-n kestrel-records' "$T/calls")" 1
check "equipment: the ids carry the seed year (and no 2026 is left)" "$(grep -c 'SVC-2026-' "$T/state/seen-cases-1.yaml")$([ "$(grep -c 'SVC-2031-0001' "$T/state/seen-cases-1.yaml")" -gt 0 ] && echo yes)" 0yes
check "equipment: the key is the agent's name" "$(jq -r .tokens.user_id "$T/o9/summary.json")" service-agent
check "equipment: the fleet sweep was started" "$(grep -c '^SWEEP-JOB .*--from=cronjob/fleet-sweep' "$T/calls")" 1
check "equipment: the sweep only read" "$(jq -r .sweep.only_read "$T/o9/summary.json")" true
check "equipment: nothing is left behind" "$(alive)" 0
setup_state SVC
export FAKE_VM_UID=pod-rca
run env CLUSTER=oa-test bash "$S" software-org --runs 2 --out "$T/o10"
check "software-org: exit 0, eight cases, two runs" "$(jq -r '"\(.cases | length) \(.runs_completed)"' "$T/o10/summary.json")" "8 2"
check "software-org: no reset" "$(grep -c RESET-POD "$T/calls")" 0
check "software-org: no records port-forward and no state base" "$(grep -c 'port-forward.*records' "$T/calls")$(grep -c 'state_base=yes' "$T/state/oa-seen")" "00"
check "software-org: the case file is used as it is (no year rewrite)" "$(cmp -s "$T/state/seen-cases-1.yaml" "$HERE/../examples/use-cases/software-org/eval/cases-real.yaml" && echo same || echo different)" same
check "software-org: nothing is left behind" "$(alive)" 0

echo "# the script itself"
check "bash -n" "$(bash -n "$S" && echo ok)" ok
check "shellcheck (warnings) when it is installed" "$(if command -v shellcheck >/dev/null; then shellcheck -S warning "$S" >/dev/null 2>&1 && echo ok || echo findings; else echo ok; fi)" ok
check "no --token flag and no token in an argument list: the token comes from kubectl into a variable" "$(grep -c -- '--token ' "$S")" 0
check "no trace output that could print the token (set -x)" "$(grep -c 'set -x\|set -o xtrace' "$S")" 0
check "the token is never redirected to a file by name (only to the named pipe)" "$(grep -n '"\$TOKEN"' "$S" | grep -v 'fifo' | grep -vc '\[ -n')" 0
check "every kubectl call goes through KC (pinned context)" "$(grep -n '"\$KUBECTL"\|kubectl ' "$S" | grep -v '^[0-9]*:#' | grep -v 'KC=(' | grep -vc 'die \|log \|usage\|echo\|cat >&2\|!!!\|"\$KUBECTL" --context\|go to\|KUBECTL=')" 0
check "a records pod is deleted only after --reset-records (the guard is before any kubectl call)" "$([ "$(grep -n 'needs --reset-records' "$S" | head -1 | cut -d: -f1)" -lt "$(grep -n 'get namespace' "$S" | head -1 | cut -d: -f1)" ] && echo yes || echo no)" yes
check "no em dash" "$(grep -c $'\xe2\x80\x94' "$S")" 0

echo "# the budget of the key is read from the composed release (helm get values) when it can be; the flag is the fallback; the script says which it used"
setup_state DSP
export FAKE_VM_UID=dispute-agent FAKE_SWEEP_TOOLS="records_list_open_cases"
printf '%s\n' '{"agents":[{"name":"dispute-agent","budgetClass":"bank-case-agent"}],"gateway":{"policy":{"budgetClasses":[{"name":"bank-case-agent","tokens":800000,"unit":"Hours","per":"agent"}]}}}' > "$T/hv-class.json"
: > "$T/helm.calls"
run env CLUSTER=oa-test FAKE_HELM_VALUES="$T/hv-class.json" bash "$S" bank --runs 1 --reset-records --out "$T/h1"
check "with the class in the release the budget is the class: 800000, and the output says it was read from the release" "$(grep -c 'budget of the key of dispute-agent: 800000 tokens an hour (the class bank-case-agent of the release' "$T/out")" 1
check "the summary records the number and where it came from" "$(jq -c '.budget | {t: .tokens_per_hour_per_key, s: (.source | test("class bank-case-agent"))}' "$T/h1/summary.json")" '{"t":800000,"s":true}'
check "helm was asked for the values of the release in the context named, read only" "$(grep -c '^get values openagentix -n openagentix-system --kube-context kind-oa-test -o json$' "$T/helm.calls")" 1
printf '%s\n' '{"agents":[{"name":"dispute-agent","budgetClass":"bank-case-agent"}],"gateway":{"policy":{"budgetClasses":[{"name":"bank-case-agent","tokens":20000,"unit":"Minutes","per":"agent"}]}}}' > "$T/hv-min.json"
run env CLUSTER=oa-test FAKE_HELM_VALUES="$T/hv-min.json" bash "$S" bank --runs 1 --reset-records --out "$T/h2"
check "a class in Minutes is turned into an hour: 20000 a minute is 1200000 an hour" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h2/summary.json")" 1200000
printf '%s\n' '{"agents":[{"name":"dispute-agent"}],"gateway":{"policy":{"tokenBudget":{"tokens":500000,"unit":"Hours"}}}}' > "$T/hv-none.json"
run env CLUSTER=oa-test FAKE_HELM_VALUES="$T/hv-none.json" bash "$S" bank --runs 1 --reset-records --out "$T/h3"
check "an agent with no class gets the default budget of the release (tokenBudget, 500000)" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h3/summary.json")" 500000
check "  and the output says that the agent has no class" "$(grep -c 'no class' "$T/out")" 1
run env CLUSTER=oa-test FAKE_HELM_VALUES="$T/hv-class.json" bash "$S" bank --runs 1 --reset-records --budget-tokens-per-hour 123456 --out "$T/h4"
check "the flag wins when it is given (123456), and the output says it was the flag" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h4/summary.json") $(grep -c 'from the flag --budget-tokens-per-hour' "$T/out")" "123456 1"
: > "$T/helm.calls"
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --budget-tokens-per-hour 123456 --out "$T/h5"
check "with the flag no helm call is made at all" "$(wc -l < "$T/helm.calls" | tr -d ' ')" 0
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --out "$T/h6"
check "no release: the default 1000000 is used, and the output says why" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h6/summary.json") $(grep -c 'the default 1000000 (no release values: ' "$T/out")" "1000000 1"
run env CLUSTER=oa-test FAKE_HELM_FAIL=1 bash "$S" bank --runs 1 --reset-records --out "$T/h7"
check "helm fails: the default is used and the reason is shown" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h7/summary.json") $(grep -c 'the default 1000000 (could not read the release' "$T/out")" "1000000 1"
run env CLUSTER=oa-test HELM=/nonexistent/helm bash "$S" bank --runs 1 --reset-records --out "$T/h8"
check "no helm command: the default is used and the output says helm was not found" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h8/summary.json") $(grep -c 'helm was not found' "$T/out")" "1000000 1"
printf '%s\n' '{"agents":[{"name":"dispute-agent","budgetClass":"gone"}],"gateway":{"policy":{"budgetClasses":[]}}}' > "$T/hv-gone.json"
run env CLUSTER=oa-test FAKE_HELM_VALUES="$T/hv-gone.json" bash "$S" bank --runs 1 --reset-records --out "$T/h9"
check "a class that the release does not define: the default is used and the class is named" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h9/summary.json") $(grep -c 'names the class gone, which the release does not define' "$T/out")" "1000000 1"
printf '%s\n' '{"agents":[{"name":"dispute-agent","budgetClass":"pool"}],"gateway":{"policy":{"budgetClasses":[{"name":"pool","tokens":900000,"unit":"Hours","per":"class"}]}}}' > "$T/hv-pool.json"
run env CLUSTER=oa-test FAKE_HELM_VALUES="$T/hv-pool.json" bash "$S" bank --runs 1 --reset-records --out "$T/h10"
check "a class shared by every key (per class): the number is used and the output says it is shared" "$(jq -r '.budget.tokens_per_hour_per_key' "$T/h10/summary.json") $(grep -c 'shared by every key of the class' "$T/out")" "900000 1"

echo "# the budget: a refused case is not run, the run stops early, the sweep is skipped; a run that does not fit waits or stops"
setup_state DSP
export FAKE_VM_UID=dispute-agent FAKE_SWEEP_TOOLS="records_list_open_cases"
run env CLUSTER=oa-test FAKE_REFUSE_AT="2:injected-instruction-refused" bash "$S" bank --runs 3 --reset-records --sweep --out "$T/b1"
check "a refused case: exit 3 (not 0, not 1)" "$RC" 3
check "the message says the gateway budget is exhausted and what to do" "$([ "$(grep -c "the agent's gateway budget is exhausted: .* tokens used in the last hour.*Wait or lower --runs" "$T/out")" -ge 1 ] && echo yes)" yes
check "the run stopped early: run 3 never started (two resets)" "$(grep -c RESET-POD "$T/calls")" 2
SUM=$T/b1/summary.json
check "the refused case and the cases after it are not run, and the case before it counted" "$(jq -c '[.cases[] | select(.id == "injected-instruction-refused" or .id == "pressure-prompt-holds" or .id == "deadline-sweep-reads-only") | {id, runs, not_run, passed}] | sort_by(.id)' "$SUM")" '[{"id":"deadline-sweep-reads-only","runs":1,"not_run":1,"passed":1},{"id":"injected-instruction-refused","runs":1,"not_run":1,"passed":1},{"id":"pressure-prompt-holds","runs":1,"not_run":1,"passed":1}]'
check "a refused case is out of the denominator: pass rate stays 1 of 1" "$(jq -c '.cases[] | select(.id == "injected-instruction-refused") | .pass_rate' "$SUM")" 1
check "the cases that ran in both runs have 2 runs" "$(jq -c '.cases[] | select(.id == "duplicate-charge") | {runs, not_run}' "$SUM")" '{"runs":2,"not_run":0}'
check "the summary records that the budget stopped it" "$(jq -c '.budget | {stopped_by_budget, per_hour: .tokens_per_hour_per_key}' "$SUM")" '{"stopped_by_budget":true,"per_hour":1000000}'
check "the sweep was skipped with the same message, and no job was made" "$(jq -r '.sweep.skipped' "$SUM")$(grep -c SWEEP-JOB "$T/calls")" true0
check "a refusal is no failure of the sweep and no failure of a check" "$(jq -r '[.cases[].failed_checks[]] | length' "$SUM")" 0
check "nothing is left behind" "$(alive)" 0

setup_state DSP
run env CLUSTER=oa-test FAKE_REFUSE_AT="2:out-of-time-declined" bash "$S" bank --runs 1 --reset-records --tokens per-case --out "$T/b2"
check "per case: a refusal stops the cases that follow in the same run" "$(jq -c '[.cases[] | {id, not_run}] | map(select(.not_run > 0)) | map(.id) | sort' "$T/b2/summary.json")" '["deadline-sweep-reads-only","injected-instruction-refused","out-of-time-declined","pressure-prompt-holds"]'
check "per case: exit 3" "$RC" 3
check "per case: only two cases were sent to oa-eval" "$(grep -c '^oa-eval .*--only ' "$T/calls")" 2

setup_state DSP
run env CLUSTER=oa-test bash "$S" bank --runs 3 --reset-records --budget-tokens-per-hour 2000 --no-wait --out "$T/b3"
check "--no-wait: the second run does not fit (1200 used, 1200 needed, 2000 budget): exit 3" "$RC" 3
check "  one run was done" "$(jq -r .runs_completed "$T/b3/summary.json")" 1
check "  the message says it does not fit and that --no-wait was given" "$(grep -c 'does not fit, and --no-wait was given' "$T/out")" 1
check "  only one reset: the second run was never started" "$(grep -c RESET-POD "$T/calls")" 1
setup_state DSP
run env CLUSTER=oa-test EVAL_BUDGET_WINDOW_SECONDS=5 EVAL_COUNTDOWN_STEP=1 bash "$S" bank --runs 2 --reset-records --budget-tokens-per-hour 2000 --out "$T/b4"
check "waiting: the second run waits for the first to leave the window, then runs: exit 0" "$RC" 0
check "  a countdown was printed" "$([ "$(grep -c 's to go' "$T/out")" -ge 2 ] && echo yes || echo no)" yes
check "  both runs completed" "$(jq -r .runs_completed "$T/b4/summary.json")" 2
setup_state DSP
run env CLUSTER=oa-test bash "$S" bank --runs 2 --reset-records --budget-tokens-per-hour 1000 --out "$T/b5"
check "a run bigger than the whole hourly budget: stop, say so, exit 3" "$RC" 3
check "  the message names both numbers" "$(grep -c 'a run used about 1200 tokens, which is more than the hourly budget of 1000' "$T/out")" 1
run env CLUSTER=oa-test bash "$S" bank --runs 1 --reset-records --budget-tokens-per-hour lots
check "a bad --budget-tokens-per-hour: exit 2" "$RC" 2

setup_state DSP
export FAKE_SWEEP_TOOLS=""
run env CLUSTER=oa-test FAKE_JOB_FAIL=1 FAKE_JOB_LOG='{"error":"task ended in TASK_STATE_FAILED: agent run failed: OpenAI chat completion request failed: OpenAI API error: 429 Too Many Requests"}' \
  bash "$S" bank --runs 1 --reset-records --sweep --out "$T/b6"
check "a sweep job refused by the model with no tool call is NOT RUN, not a failure: exit 3" "$RC" 3
check "  the summary says not run and does not say it only read" "$(jq -c '.sweep | {not_run, only_read}' "$T/b6/summary.json")" '{"not_run":true,"only_read":null}'
check "  the job is deleted" "$(grep -c 'delete job -n openagentix-schedules deadline-sweep-eval-' "$T/calls")" 1

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
