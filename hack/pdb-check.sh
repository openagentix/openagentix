#!/usr/bin/env bash
# Read-only check before `helm upgrade` (ADR 0024, issue #198): a pod that two PodDisruptionBudgets select cannot be evicted, so every node
# drain would fail. The chart renders one budget per Deployment and StatefulSet (availability.podDisruptionBudgets.enabled, on by default).
# This script finds budgets that the release does NOT own and whose selector matches the pod template labels of one of our workloads.
#
#   hack/pdb-check.sh [rendered.jsonl]     the chart render as one JSON document per line (default: standard input)
#
# 1. From the render: the pod template labels of every Deployment and StatefulSet, per namespace. No budget in the render (the switch is off):
#    the check is skipped and no cluster call is made.
# 2. For each such namespace: kubectl get pdb -n <ns> -o json. A budget with the annotation meta.helm.sh/release-name equal to $RELEASE is ours and is dropped.
# 3. Each remaining budget whose selector matches (matchLabels, and matchExpressions In, NotIn, Exists, DoesNotExist; an empty selector {}
#    matches every pod) is printed with the workload it matches and the two fixes. Exit 1 then. A namespace that cannot be read is also exit 1.
# It uses only `get`. It runs on a fresh install too: it compares with the rendered templates, not with running pods.
#
# Env: KUBECTL (default kubectl), KUBE_CONTEXT (optional, passed as --context), RELEASE (default openagentix).
# Tests: hack/ci/pdb-check-test.sh (fake kubectl, no cluster).
set -uo pipefail
K=${KUBECTL:-kubectl}
RELEASE=${RELEASE:-openagentix}
KC=(); [ -z "${KUBE_CONTEXT:-}" ] || KC=(--context "$KUBE_CONTEXT")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
if [ -n "${1:-}" ]; then cp "$1" "$W/render" || { echo "ERROR: cannot read $1" >&2; exit 1; }; else cat > "$W/render"; fi

if ! jq -e 'select(.kind=="PodDisruptionBudget")' "$W/render" >/dev/null 2>&1; then
  echo "PodDisruptionBudget check: skipped (this render has no budgets of its own: availability.podDisruptionBudgets.enabled is false)"
  exit 0
fi
jq -c 'select(.kind=="Deployment" or .kind=="StatefulSet")|{kind,name:.metadata.name,ns:.metadata.namespace,labels:(.spec.template.metadata.labels//{})}' "$W/render" > "$W/workloads"
NSS=$(jq -r '.ns' "$W/workloads" | sort -u)

# one selector against one label set: matchLabels all equal, every expression true; an empty selector matches everything; no selector matches nothing
# shellcheck disable=SC2016  # jq program, not shell
MATCH='def sel($l; $s):
  if $s==null then false
  else (($s.matchLabels//{})|to_entries|all(. as $e|$l[$e.key]==$e.value))
       and (($s.matchExpressions//[])|all(. as $x|$l[$x.key] as $v|
            if $x.operator=="In" then ($v!=null and (($x.values//[])|any(.==$v)))
            elif $x.operator=="NotIn" then ($v==null or (($x.values//[])|all(.!=$v)))
            elif $x.operator=="Exists" then $v!=null
            elif $x.operator=="DoesNotExist" then $v==null
            else false end))
  end;'
rc=0; found=0
for ns in $NSS; do
  if ! $K ${KC[@]+"${KC[@]}"} get pdb -n "$ns" -o json > "$W/pdb.json" 2>"$W/err"; then
    echo "ERROR: cannot read the PodDisruptionBudgets of namespace $ns: $(head -c 300 "$W/err")" >&2
    echo "The check needs read access to poddisruptionbudgets in every platform namespace. Nothing was changed." >&2
    rc=1; continue
  fi
  while IFS=$'\t' read -r pname wkind wname; do
    [ -n "$pname" ] || continue
    found=1
    printf 'ERROR: PodDisruptionBudget %s/%s is not owned by release %s and selects the pods of %s/%s.\n' "$ns" "$pname" "$RELEASE" "$wkind" "$wname" >&2
    printf '  A pod that two budgets select cannot be evicted, so every node drain would fail. Fix one of these:\n' >&2
    printf '    1. delete that budget:  kubectl delete pdb %s -n %s\n' "$pname" "$ns" >&2
    printf '    2. or turn the chart'"'"'s budgets off and keep yours:  set availability.podDisruptionBudgets.enabled=false in your values.\n' >&2
  done < <(jq -r --arg rel "$RELEASE" --slurpfile wl "$W/workloads" "$MATCH"'
    .items[]?|select((.metadata.annotations["meta.helm.sh/release-name"]//"")!=$rel)|. as $b
    |($wl[]|select(.ns==$ns)|select(sel(.labels; $b.spec.selector))) as $w
    |[$b.metadata.name,$w.kind,$w.name]|@tsv' --arg ns "$ns" "$W/pdb.json")
done
if [ "$found" = 1 ]; then echo "Nothing was changed." >&2; exit 1; fi
[ "$rc" = 0 ] || exit 1
echo "PodDisruptionBudget check: ok ($(printf '%s\n' "$NSS" | wc -l | tr -d ' ') namespaces read, no budget of another owner selects a pod of this chart)"
