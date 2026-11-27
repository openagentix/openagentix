#!/usr/bin/env bash
# The SRE desk's commands for the pod root-cause use case.
#   ctl.sh ask "<question>"        ask the agent pod-rca anything (as the caller rca-desk, user id sre:analyst-1)
#   ctl.sh analyze <workload>      ask for the root-cause report of one workload of the namespace rca-demo
#   ctl.sh pods                    kubectl get pods -n rca-demo (what the six faults look like to a person)
#   ctl.sh wait [seconds]          wait until every workload shows its fault (default 240 s)
# Local kind or k3d cluster only: it refuses any other kube context. The agent can read, never change: nothing here changes the cluster.
# Env: CLUSTER (default oa-rca-demo)  KUBE_CONTEXT (default kind-$CLUSTER)  KUBECTL  ASK (the ask script, default hack/ask.sh)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
CLUSTER=${CLUSTER:-oa-rca-demo}
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-$CLUSTER}
KUBECTL=${KUBECTL:-kubectl}
ASK=${ASK:-$ROOT/hack/ask.sh}
KC=("$KUBECTL" --context "$KUBE_CONTEXT")
NS=rca-demo
WORKLOADS="img-typo crash-start oom-kill cfg-missing-key probe-fail pending-selector ghost-worker"

die(){ echo "ERROR: $*" >&2; exit 1; }
case "$KUBE_CONTEXT" in
  kind-*|k3d-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind or k3d cluster (kind-<name> or k3d-<name>). Set CLUSTER or KUBE_CONTEXT." ;;
esac
usage(){ sed -n 2,8p "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
[ $# -ge 1 ] || usage

# ask as the SRE desk: the caller rule of values.yaml (the ServiceAccount rca-desk, user ids sre:...)
ask() { KUBE_CONTEXT="$KUBE_CONTEXT" KUBECTL="$KUBECTL" ASK_SA=openagentix-system/rca-desk ASK_USER=sre:analyst-1 ASK_TIMEOUT="${ASK_TIMEOUT:-300}" "$ASK" pod-rca "$1"; }

case "$1" in
  ask)
    [ $# -eq 2 ] || usage
    ask "$2" ;;
  analyze)
    [ $# -eq 2 ] || usage
    case " $WORKLOADS " in *" $2 "*) ;; *) die "'$2' is not a workload of the demo. Try one of: $WORKLOADS" ;; esac
    ask "Pod root-cause analysis for workload $2 in namespace $NS." ;;
  pods)
    "${KC[@]}" get pods -n "$NS" -o wide ;;
  wait)
    secs=${2:-240}
    for _ in $(seq 1 "$secs"); do
      OUT=$("${KC[@]}" get pods -n "$NS" -o json 2>/dev/null || true)
      if [ -n "$OUT" ] && printf '%s' "$OUT" | jq -e '
          def reason: (.status.containerStatuses[0].state.waiting.reason // "") ;
          def last:   (.status.containerStatuses[0].lastState.terminated.reason // "") ;
          (.items | length) == 6 and
          ([.items[] | select(.metadata.labels.app=="img-typo")         | select(reason | IN("ImagePullBackOff","ErrImagePull"))] | length == 1) and
          ([.items[] | select(.metadata.labels.app=="crash-start")      | select(reason == "CrashLoopBackOff")] | length == 1) and
          ([.items[] | select(.metadata.labels.app=="oom-kill")         | select(last == "OOMKilled")] | length == 1) and
          ([.items[] | select(.metadata.labels.app=="cfg-missing-key")  | select(reason == "CreateContainerConfigError")] | length == 1) and
          ([.items[] | select(.metadata.labels.app=="probe-fail")       | select(.status.phase=="Running" and (.status.containerStatuses[0].ready == false))] | length == 1) and
          ([.items[] | select(.metadata.labels.app=="pending-selector") | select(.status.phase=="Pending" and (.status.containerStatuses == null))] | length == 1)
        ' >/dev/null 2>&1; then
        echo "every workload shows its fault"; exit 0
      fi
      sleep 1
    done
    echo "the workloads did not all show their fault within ${secs}s:" >&2
    "${KC[@]}" get pods -n "$NS" >&2 || true
    exit 1 ;;
  *) usage ;;
esac
