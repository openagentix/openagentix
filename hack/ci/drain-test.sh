#!/usr/bin/env bash
# Drain test (ADR 0024, issue #198): on a cluster with two worker nodes and the chart installed (PROFILE=quickstart, one replica of each workload),
# `kubectl drain` of the worker that runs the most platform pods must finish, and no PodDisruptionBudget of the chart may block it.
#   1. every Deployment and StatefulSet of the release has a budget, and each budget allows one disruption (status.disruptionsAllowed >= 1)
#      while its workload is Ready;
#   2. where every platform pod runs is printed before the drain;
#   3. kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=$DRAIN_TIMEOUT finishes (exit 0) and its output has no
#      "disruption budget" refusal (the eviction API answers a blocked eviction with HTTP 429 and that text);
#   4. where every platform pod runs is printed after the drain; the node is uncordoned.
# This proves that a budget on a SINGLE replica does not block a drain. It does not prove that a second replica survives a drain (#199), a node failure
# (#204) or a one-node cluster; see ADR 0024, "Tests and proof".
# Needs: kubectl (current context = the cluster to drain: a throwaway one, never a cluster you use), helm, jq, yq (the Python wrapper).
# Env: RELEASE (openagentix), RELEASE_NS (openagentix-system), DRAIN_TIMEOUT (300s), DRAIN_NS_RE (platform namespaces).
# Exit 1 when a check fails. Never prints a Secret value.
set -uo pipefail
K=${KUBECTL:-kubectl}
# the one guard of the live CI scripts (issue #212): kind or k3d only, a CI run or the named context, never kind-openagentix by hand; it reads the kubeconfig and nothing else
. "$(cd "$(dirname "$0")" && pwd)/lib/require-ci-context.sh"
KUBECTL=$K; export KUBECTL
require_ci_context drain-test DRAIN_CI_CONTEXT
RELEASE=${RELEASE:-openagentix}; RELEASE_NS=${RELEASE_NS:-openagentix-system}
DRAIN_TIMEOUT=${DRAIN_TIMEOUT:-300s}
NS_RE=${DRAIN_NS_RE:-'^(openagentix-.*|agentgateway-system)$'}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail=0
ok(){ printf 'ok    %s\n' "$1"; }
bad(){ fail=1; printf 'FAIL  %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /' >&2; }

placement(){   # placement <label>: one line per pod of the platform namespaces, with its node
  echo "--- where the platform pods run ($1)"
  $K get pods -A -o json | jq -r --arg re "$NS_RE" '.items[]|select(.metadata.namespace|test($re))|[.spec.nodeName//"-",.metadata.namespace,.metadata.name,.status.phase]|@tsv' | sort | awk -F'\t' '{printf "      %-24s %-26s %-52s %s\n",$1,$2,$3,$4}'
  echo "--- pods per node"
  $K get pods -A -o json | jq -r --arg re "$NS_RE" '.items[]|select(.metadata.namespace|test($re))|.spec.nodeName//"(not scheduled)"' | sort | uniq -c | sed 's/^/      /'
}

echo "# nodes"
$K get nodes -o wide
WORKERS=$($K get nodes -l '!node-role.kubernetes.io/control-plane' -o json | jq -r '.items[].metadata.name')
if [ "$(printf '%s\n' "$WORKERS" | grep -c .)" -ge 2 ]; then ok "the cluster has at least two worker nodes"; else bad "the cluster has at least two worker nodes" "found: $WORKERS"; exit 1; fi

echo "# budgets"
helm get manifest "$RELEASE" -n "$RELEASE_NS" 2>/dev/null | yq -c 'select(.!=null)' > "$W/manifest.jsonl" || true
[ -s "$W/manifest.jsonl" ] || { bad "helm get manifest $RELEASE answers (the chart is installed)"; exit 1; }
jq -r 'select(.kind=="Deployment" or .kind=="StatefulSet")|(.metadata.namespace//"'"$RELEASE_NS"'")+"/"+.metadata.name' "$W/manifest.jsonl" | sort > "$W/workloads"
jq -r 'select(.kind=="PodDisruptionBudget")|(.metadata.namespace//"'"$RELEASE_NS"'")+"/"+.metadata.name' "$W/manifest.jsonl" | sort > "$W/budgets"
echo "workloads: $(wc -l < "$W/workloads" | tr -d ' '), budgets: $(wc -l < "$W/budgets" | tr -d ' ')"
if [ -s "$W/workloads" ] && [ "$(cat "$W/workloads")" = "$(cat "$W/budgets")" ]; then ok "every workload of the release has a budget of the same name, and there is no other"
else bad "every workload has a budget of the same name" "$(diff "$W/workloads" "$W/budgets")"; fi
$K get pdb -A -o wide
# a workload that is Ready has one allowed disruption (maxUnavailable 1)
NOT_ALLOWED=""
while IFS=/ read -r ns name; do
  allowed=$($K get pdb "$name" -n "$ns" -o json | jq -r '.status.disruptionsAllowed // 0')
  if [ "$allowed" -ge 1 ]; then ok "budget $ns/$name allows $allowed disruption"; else NOT_ALLOWED="$NOT_ALLOWED $ns/$name"; fi
done < "$W/budgets"
# a budget with 0 allowed disruptions is only acceptable while no pod of its workload is Ready (an unhealthy pod is evicted under AlwaysAllow)
for b in $NOT_ALLOWED; do
  ns=${b%%/*}; name=${b##*/}
  app=$($K get pdb "$name" -n "$ns" -o json | jq -r '.spec.selector.matchLabels.app')
  ready=$($K get pods -n "$ns" -l "app=$app" -o json | jq -r '[.items[]|select(any(.status.conditions[]?; .type=="Ready" and .status=="True"))]|length')
  if [ "$ready" = 0 ]; then ok "budget $b allows 0 disruptions because no pod of $app is Ready (not a block)"; else bad "budget $b allows 0 disruptions although $ready pod(s) of $app are Ready"; fi
done

placement "before the drain"
NODE=$($K get pods -A -o json | jq -r --arg re "$NS_RE" '[.items[]|select(.metadata.namespace|test($re))|.spec.nodeName//empty]|group_by(.)|map({n:.[0],c:length})|sort_by(-.c)|.[0].n')
FOUND=0; for w in $WORKERS; do [ "$w" = "$NODE" ] && FOUND=1; done
[ "$FOUND" = 1 ] || { bad "the node with the most platform pods is a worker" "got '$NODE'"; exit 1; }
echo "# kubectl drain $NODE (the worker with the most platform pods), timeout $DRAIN_TIMEOUT"
$K drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout="$DRAIN_TIMEOUT" > "$W/drain.log" 2>&1; rc=$?
tail -n 60 "$W/drain.log" | sed 's/^/      | /'
if [ "$rc" = 0 ]; then ok "kubectl drain $NODE finished (exit 0)"; else bad "kubectl drain $NODE finished (exit $rc)" "$(tail -n 15 "$W/drain.log")"; fi
if grep -qi 'disruption budget' "$W/drain.log"; then bad "no eviction was refused by a PodDisruptionBudget" "$(grep -i 'disruption budget' "$W/drain.log" | head -5)"; else ok "no eviction was refused by a PodDisruptionBudget"; fi
placement "after the drain"
LEFT=$($K get pods -A -o json | jq -r --arg re "$NS_RE" --arg n "$NODE" '[.items[]|select((.metadata.namespace|test($re)) and .spec.nodeName==$n)|select((.metadata.ownerReferences//[])|all(.kind!="DaemonSet"))]|length')
if [ "$LEFT" = 0 ]; then ok "no platform pod is left on the drained node"; else bad "no platform pod is left on the drained node" "$LEFT pod(s) still there"; fi
$K uncordon "$NODE" >/dev/null && ok "node $NODE uncordoned"

echo
if [ "$fail" = 0 ]; then echo "drain-test: all checks passed"; exit 0; fi
echo "drain-test: FAILED"; exit 1
