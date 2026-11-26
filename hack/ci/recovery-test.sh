#!/usr/bin/env bash
# Recovery after a node restart (issue #203). Run it against a kind cluster that already has the quick start installed:
#   PROFILE=quickstart ./install.sh && CLUSTER=openagentix hack/ci/recovery-test.sh
# It installs nothing. It restarts the node container of the cluster named by CLUSTER ($CLUSTER-control-plane), so never point it at a
# cluster you use. In CI it runs on a throwaway runner (.github/workflows/recovery.yml).
#
#   1. smoke test before (RECOVERY_SMOKE_BEFORE=0 skips it) and a baseline of every pod's restart count
#   2. `docker restart` of the kind node container (the same as a laptop VM restart)
#   3. wait for the API server (kind export kubeconfig on the way: the published port can change)
#   4. wait until every pod is Ready AND every container was started after the restart (a stale Ready is not counted)
#   5. wait RECOVERY_SETTLE seconds, then count restarts again. One restart per container is the node restart itself; more is a crash.
#   6. the AgentDefinition (RECOVERY_AGENT, default quickstart) is Ready=True, and the smoke test passes again
#   7. no Job has failed
# Exit 1 when: recovery (restart until the smoke test passes) takes longer than RECOVERY_BUDGET seconds (default 600); a pod restarted more
# than once per container; a Job failed; the agent is not Ready. hack/ci/recovery-allow.txt can excuse one known item, only with an issue
# number on the same line. Exit 2: the test could not start (the smoke test fails before the restart, docker restart failed).
# The measured values go to RECOVERY_SUMMARY (markdown; the workflow appends it to the job summary). Needs kubectl, jq, docker, kind.
# Offline test: hack/ci/recovery-test-test.sh.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
K=${KUBECTL:-kubectl}; DOCKER=${DOCKER:-docker}; KIND=${KIND:-kind}
CLUSTER=${CLUSTER:-openagentix}; NODE=${RECOVERY_NODE:-$CLUSTER-control-plane}
NS=${RECOVERY_NAMESPACE:-kagent}; AGENT=${RECOVERY_AGENT:-quickstart}
BUDGET=${RECOVERY_BUDGET:-600}; SETTLE=${RECOVERY_SETTLE:-60}; POLL=${RECOVERY_POLL:-10}
SMOKE=${RECOVERY_SMOKE_CMD:-hack/ci/smoke.sh}
ALLOW=${RECOVERY_ALLOW:-hack/ci/recovery-allow.txt}
OUT=${RECOVERY_SUMMARY:-/dev/stdout}
SLEEP=${RECOVERY_SLEEP:-sleep}; NOWCMD=${RECOVERY_NOW_CMD:-date +%s}
now(){ $NOWCMD; }
log(){ printf '[recovery %s] %s\n' "$(now)" "$*" >&2; }
fails=()

# The allowlist: "<restarts|job> <namespace>/<name prefix>  # #<issue>". An entry without an issue number is ignored.
allowed(){ # allowed <kind> <ns/name>
  [ -f "$ALLOW" ] || return 1
  local k p rest
  while read -r k p rest; do
    case "$k" in ''|'#'*) continue;; esac
    case "$rest" in *'#'[0-9]*) ;; *) continue;; esac
    [ "$k" = "$1" ] || continue
    case "$2" in "$p"*) return 0;; esac
  done < "$ALLOW"
  return 1
}

# Pods that are not finished and not being deleted.
PODS_JQ='[.items[] | select(.metadata.deletionTimestamp==null) | select(.status.phase!="Succeeded" and .status.phase!="Failed")]'
restarts_of(){ jq -r "$PODS_JQ | .[] | \"\(.metadata.namespace)/\(.metadata.name) \([.status.containerStatuses[]?.restartCount]|add // 0) \(.spec.containers|length)\""; }
# not_ready <epoch>: the pods that are not Ready, or hold a container that started before <epoch> (so it did not restart yet)
not_ready(){
  jq -r --argjson t "$1" "$PODS_JQ | .[] | select(
      .status.phase != \"Running\"
      or (([.status.conditions[]? | select(.type==\"Ready\") | .status] | first) != \"True\")
      or any(.status.containerStatuses[]?; ((.state.running.startedAt // \"1970-01-01T00:00:00Z\") | fromdateiso8601) < \$t)
      or ((.status.containerStatuses // []) | length) < (.spec.containers | length)
    ) | \"\(.metadata.namespace)/\(.metadata.name)\""
}
count_pods(){ jq "$PODS_JQ | length"; }
get_pods(){ $K get pods -A -o json 2>/dev/null; }

# The cluster named openagentix is the one people use by hand: restarting its node stops their work.
if [ "$CLUSTER" = openagentix ] && [ "${RECOVERY_ALLOW_DEFAULT_CLUSTER:-0}" != 1 ]; then
  echo "refusing to restart the node of the cluster 'openagentix'. Set CLUSTER to a throwaway cluster (CI uses oa-recovery), or RECOVERY_ALLOW_DEFAULT_CLUSTER=1 if you mean it." >&2
  exit 2
fi

# ---------------------------------------------------------------- before
if [ "${RECOVERY_SMOKE_BEFORE:-1}" = 1 ]; then
  log "smoke test before the restart"
  $SMOKE >&2 || { echo "the smoke test fails before the restart: nothing to measure" >&2; exit 2; }
fi
BASE=$(get_pods); [ -n "$BASE" ] || { echo "cannot list pods before the restart" >&2; exit 2; }
BASE_RESTARTS=$(restarts_of <<<"$BASE"); BASE_COUNT=$(count_pods <<<"$BASE")
log "baseline: $BASE_COUNT pods"

# ---------------------------------------------------------------- restart
T0=$(now)
log "docker restart $NODE"
$DOCKER restart "$NODE" >&2 || { echo "docker restart $NODE failed" >&2; exit 2; }
DEADLINE=$((T0 + BUDGET))

# ---------------------------------------------------------------- API server
API_AT=""
while :; do
  if $K get --raw /readyz >/dev/null 2>&1; then API_AT=$(now); break; fi
  $KIND export kubeconfig --name "$CLUSTER" >/dev/null 2>&1 || true
  [ "$(now)" -ge "$DEADLINE" ] && break
  $SLEEP 3
done
[ -n "$API_AT" ] || fails+=("the API server did not answer within ${BUDGET}s")

# ---------------------------------------------------------------- all pods Ready, every container started after the restart
READY_AT=""; LAST_NOT_READY=""
if [ -n "$API_AT" ]; then
  while :; do
    P=$(get_pods)
    if [ -n "$P" ]; then
      LAST_NOT_READY=$(not_ready "$T0" <<<"$P"); N=$(count_pods <<<"$P")
      if [ -z "$LAST_NOT_READY" ] && [ "$N" -ge "$BASE_COUNT" ]; then READY_AT=$(now); break; fi
    fi
    [ "$(now)" -ge "$DEADLINE" ] && break
    $SLEEP "$POLL"
  done
  [ -n "$READY_AT" ] || fails+=("pods not Ready after ${BUDGET}s: $(tr '\n' ' ' <<<"$LAST_NOT_READY")")
fi

# ---------------------------------------------------------------- settle, then count restarts
if [ -n "$READY_AT" ]; then log "pods Ready; waiting ${SETTLE}s to see crash loops"; $SLEEP "$SETTLE"; fi
AFTER=$(get_pods); AFTER_RESTARTS=""; [ -z "$AFTER" ] || AFTER_RESTARTS=$(restarts_of <<<"$AFTER")
# one row per pod that restarted: pod, restarts since the baseline, containers, extra (restarts beyond one per container)
RESTART_ROWS=$(awk 'NR==FNR{b[$1]=$2;next}{d=$2-b[$1]; e=d-$3; if (d>0) printf "%s %d %d %d\n",$1,d,$3,(e>0?e:0)}' <(echo "$BASE_RESTARTS") <(echo "$AFTER_RESTARTS"))
EXTRA_BAD=()
while read -r pod d c e; do
  [ -n "$pod" ] || continue
  if [ "$e" -gt 0 ] && ! allowed restarts "$pod"; then EXTRA_BAD+=("$pod $e"); fi
done <<<"$RESTART_ROWS"
[ ${#EXTRA_BAD[@]} -eq 0 ] || fails+=("pods that restarted more than once per container: $(printf '%s; ' "${EXTRA_BAD[@]}")")

# ---------------------------------------------------------------- agent and smoke
AGENT_OK=no; AGENT_AT=""
if [ -n "$API_AT" ]; then
  LEFT=$((DEADLINE - $(now))); [ "$LEFT" -gt 5 ] || LEFT=5
  if $K wait "agentdefinition/$AGENT" -n "$NS" --for=condition=Ready --timeout="${LEFT}s" >/dev/null 2>&1; then AGENT_OK=yes; AGENT_AT=$(now); fi
fi
[ "$AGENT_OK" = yes ] || fails+=("AgentDefinition $AGENT is not Ready=True after the restart")

SMOKE_OK=no; SMOKE_AT=""; SMOKE_TRIES=0
if [ -n "$API_AT" ]; then
  while :; do
    SMOKE_TRIES=$((SMOKE_TRIES+1))
    if $SMOKE >&2; then SMOKE_OK=yes; SMOKE_AT=$(now); break; fi
    [ "$(now)" -ge "$DEADLINE" ] && break
    $SLEEP "$POLL"
  done
fi
[ "$SMOKE_OK" = yes ] || fails+=("the smoke test did not pass within ${BUDGET}s of the restart")

# ---------------------------------------------------------------- jobs
JOBS_FAILED=$($K get jobs -A -o json 2>/dev/null | jq -r '.items[]? | select((.status.failed // 0) > 0) | "\(.metadata.namespace)/\(.metadata.name) failed=\(.status.failed)"')
JOBS_BAD=()
while read -r j rest; do
  [ -n "$j" ] || continue
  allowed job "$j" || JOBS_BAD+=("$j $rest")
done <<<"$JOBS_FAILED"
[ ${#JOBS_BAD[@]} -eq 0 ] || fails+=("failed jobs: $(printf '%s; ' "${JOBS_BAD[@]}")")

# ---------------------------------------------------------------- budget
RECOVERY_S=""
if [ -n "$SMOKE_AT" ]; then
  RECOVERY_S=$((SMOKE_AT - T0))
  [ "$RECOVERY_S" -le "$BUDGET" ] || fails+=("recovery took ${RECOVERY_S}s, budget ${BUDGET}s")
fi
secs(){ if [ -n "$2" ]; then echo "$(( $2 - $1 )) s"; else echo "not reached"; fi; }

{
  echo "## Recovery after a node restart (docker restart $NODE)"
  echo
  echo "| Measure | Value |"
  echo "|---|---|"
  echo "| budget | ${BUDGET} s |"
  echo "| API server answers | $(secs "$T0" "$API_AT") |"
  echo "| every pod Ready, every container started after the restart | $(secs "$T0" "$READY_AT") |"
  echo "| AgentDefinition $AGENT Ready=True | $(secs "$T0" "$AGENT_AT") (Ready: $AGENT_OK) |"
  echo "| smoke test passes again | $(secs "$T0" "$SMOKE_AT") (attempts: $SMOKE_TRIES, passed: $SMOKE_OK) |"
  echo "| failed Jobs | $(printf '%s' "$JOBS_FAILED" | grep -c . || true) |"
  echo "| result | $([ ${#fails[@]} -eq 0 ] && echo PASS || echo FAIL) |"
  echo
  echo "### Pods with new restarts (since before the node restart, counted ${SETTLE} s after the pods were Ready)"
  echo
  echo "One restart per container is the node restart itself. extra is what is beyond that: a crash loop or a start-up failure."
  echo
  echo '```'
  printf '%-60s %8s %10s %6s\n' pod restarts containers extra
  while read -r pod d c e; do
    [ -n "$pod" ] || continue
    note=""; [ "$e" -gt 0 ] && allowed restarts "$pod" && note="  (allowlisted)"
    printf '%-60s %8s %10s %6s%s\n' "$pod" "$d" "$c" "$e" "$note"
  done <<<"$RESTART_ROWS"
  echo '```'
  echo
  echo "### Failed Jobs"
  echo '```'; printf '%s\n' "${JOBS_FAILED:-none}"; echo '```'
  if [ ${#fails[@]} -gt 0 ]; then echo; echo "### Why it failed"; printf -- '- %s\n' "${fails[@]}"; fi
} > "$OUT"
[ "$OUT" = /dev/stdout ] || cat "$OUT"

if [ ${#fails[@]} -gt 0 ]; then printf 'FAIL: %s\n' "${fails[@]}" >&2; exit 1; fi
echo "PASS: recovered in ${RECOVERY_S}s (budget ${BUDGET}s)" >&2
