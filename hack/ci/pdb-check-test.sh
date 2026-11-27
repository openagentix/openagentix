#!/usr/bin/env bash
# Tests for hack/pdb-check.sh (ADR 0024, issue #198) with a fake `kubectl` that answers from JSON fixtures (no cluster).
# The check stops an install when a PodDisruptionBudget that the release does not own selects a pod of the chart: a pod that two budgets select
# cannot be evicted. Cases: a match by matchLabels, by matchExpressions, by an empty selector; no match; the release's own budgets; the switch off;
# and that the script only ever reads.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/fx"
# The fake kubectl: drops `--context X`, turns the other arguments into a file name, prints that fixture (exit 1 when there is none), records the call.
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
a=(); while [ \$# -gt 0 ]; do case "\$1" in --context) shift 2;; --context=*) shift;; *) a+=("\$1"); shift;; esac; done
echo "\${a[*]}" >> "$D/calls"
f="$D/fx/\$(printf '%s' "\${a[*]}" | tr -c 'A-Za-z0-9' _)"
[ -f "\$f" ] || { echo "Error from server (NotFound): fake kubectl has no fixture for: \${a[*]}" >&2; exit 1; }
cat "\$f"
EOS
chmod +x "$D/bin/kubectl"
export KUBECTL="$D/bin/kubectl"
fx(){ printf '%s\n' "$2" > "$D/fx/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }   # fx "<kubectl arguments>" <json>
reset(){ rm -f "$D"/fx/*; : > "$D/calls"; }
L='"app.kubernetes.io/instance":"openagentix","app.kubernetes.io/part-of":"openagentix"'
# a small render: the console in openagentix-system, the kb in openagentix-knowledge, and the console's own budget
RENDER="$D/render.jsonl"
cat > "$RENDER" <<EOF
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"openagentix-console","namespace":"openagentix-system"},"spec":{"selector":{"matchLabels":{"app":"console"}},"template":{"metadata":{"labels":{"app":"console",$L}}}}}
{"apiVersion":"policy/v1","kind":"PodDisruptionBudget","metadata":{"name":"openagentix-console","namespace":"openagentix-system"},"spec":{"maxUnavailable":1,"selector":{"matchLabels":{"app":"console",$L}}}}
{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"kb","namespace":"openagentix-knowledge"},"spec":{"selector":{"matchLabels":{"app":"kb"}},"template":{"metadata":{"labels":{"app":"kb",$L}}}}}
{"apiVersion":"apps/v1","kind":"StatefulSet","metadata":{"name":"kb-postgres","namespace":"openagentix-knowledge"},"spec":{"selector":{"matchLabels":{"app":"kb-postgres"}},"template":{"metadata":{"labels":{"app":"kb-postgres",$L}}}}}
EOF
NOPDB="$D/render-off.jsonl"; jq -c 'select(.kind!="PodDisruptionBudget")' "$RENDER" > "$NOPDB"
OWN='{"metadata":{"name":"openagentix-console","namespace":"openagentix-system","annotations":{"meta.helm.sh/release-name":"openagentix","meta.helm.sh/release-namespace":"openagentix-system"}},"spec":{"maxUnavailable":1,"selector":{"matchLabels":{"app":"console","app.kubernetes.io/instance":"openagentix","app.kubernetes.io/part-of":"openagentix"}}}}'
items(){ local i out=""; for i in "$@"; do out="${out:+$out,}$i"; done; printf '{"items":[%s]}' "$out"; }
good(){ reset; fx "get pdb -n openagentix-system -o json" "$(items "$OWN")"; fx "get pdb -n openagentix-knowledge -o json" '{"items":[]}'; }
run(){ KUBE_CONTEXT=${CTX:-kind-x} RELEASE=openagentix bash hack/pdb-check.sh "${1:-$RENDER}" 2>&1; }
foreign(){ printf '{"metadata":{"name":"%s","namespace":"%s"},"spec":{"selector":%s}}' "$1" "$2" "$3"; }   # foreign <name> <ns> <selector json>

echo "# nothing foreign: the release's own budgets and an empty namespace pass"
good; OUT=$(run); RC=$?
t "exit 0" "$RC" 0
t "the check lists the namespaces it read" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'PodDisruptionBudget check: ok')" 1
t "it read both namespaces, with get only" "$(sort "$D/calls" | tr '\n' ';')" "get pdb -n openagentix-knowledge -o json;get pdb -n openagentix-system -o json;"

echo "# a foreign budget with matchLabels {app: console} in the console's namespace"
good; fx "get pdb -n openagentix-system -o json" "$(items "$OWN" "$(foreign team-console openagentix-system '{"matchLabels":{"app":"console"}}')")"
OUT=$(run); RC=$?
t "exit 1" "$RC" 1
t "it names the budget" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'openagentix-system/team-console')" 1
t "it names the workload it selects" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'Deployment/openagentix-console')" 1
t "it prints the first fix: delete that budget" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'kubectl delete pdb team-console -n openagentix-system')" 1
t "it prints the second fix: turn the switch off" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'availability.podDisruptionBudgets.enabled=false')" 1
t "it says nothing was changed" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'Nothing was changed')" 1

echo "# matchExpressions"
for case in \
  'In|{"matchExpressions":[{"key":"app","operator":"In","values":["console","other"]}]}|1' \
  'In, no value matches|{"matchExpressions":[{"key":"app","operator":"In","values":["other"]}]}|0' \
  'NotIn, our value excluded|{"matchExpressions":[{"key":"app","operator":"NotIn","values":["console"]}]}|0' \
  'NotIn, a value we do not have|{"matchExpressions":[{"key":"app","operator":"NotIn","values":["other"]}]}|1' \
  'Exists|{"matchExpressions":[{"key":"app","operator":"Exists"}]}|1' \
  'Exists on a label we lack|{"matchExpressions":[{"key":"team","operator":"Exists"}]}|0' \
  'DoesNotExist on a label we lack|{"matchExpressions":[{"key":"team","operator":"DoesNotExist"}]}|1' \
  'DoesNotExist on app|{"matchExpressions":[{"key":"app","operator":"DoesNotExist"}]}|0' \
  'matchLabels and an expression, both match|{"matchLabels":{"app":"console"},"matchExpressions":[{"key":"app","operator":"Exists"}]}|1' \
  'matchLabels matches, expression does not|{"matchLabels":{"app":"console"},"matchExpressions":[{"key":"app","operator":"In","values":["x"]}]}|0'; do
  IFS='|' read -r name sel want <<<"$case"
  good; fx "get pdb -n openagentix-system -o json" "$(items "$OWN" "$(foreign foreign-x openagentix-system "$sel")")"
  OUT=$(run); RC=$?
  t "$name: exit code" "$RC" "$want"
done

echo "# an empty selector selects every pod of the namespace"
good; fx "get pdb -n openagentix-system -o json" "$(items "$OWN" "$(foreign everything openagentix-system '{}')")"
OUT=$(run); RC=$?
t "exit 1" "$RC" 1
t "it names the budget" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'openagentix-system/everything')" 1

echo "# a budget that selects no pod of ours passes"
good; fx "get pdb -n openagentix-system -o json" "$(items "$OWN" "$(foreign other-team openagentix-system '{"matchLabels":{"app":"payments"}}')")"
OUT=$(run); RC=$?
t "other app label: exit 0" "$RC" 0
good; fx "get pdb -n openagentix-knowledge -o json" "$(items "$(foreign kb-elsewhere openagentix-knowledge '{"matchLabels":{"app":"kb","app.kubernetes.io/instance":"someone-else"}}')")"
OUT=$(run); RC=$?
t "same app label but another release instance: exit 0 (not our pod)" "$RC" 0
good; fx "get pdb -n kube-system -o json" "$(items "$(foreign kube-dns kube-system '{"matchLabels":{"app":"console"}}')")"
OUT=$(run); RC=$?
t "a budget in a namespace we do not use is never read: exit 0" "$RC" 0

echo "# a budget with our release annotation is ours, a Helm annotation of another release is not"
good; fx "get pdb -n openagentix-system -o json" "$(items "$(printf '{"metadata":{"name":"theirs","namespace":"openagentix-system","annotations":{"meta.helm.sh/release-name":"other"}},"spec":{"selector":{"matchLabels":{"app":"console"}}}}')")"
OUT=$(run); RC=$?
t "owned by another release: exit 1" "$RC" 1
good; fx "get pdb -n openagentix-system -o json" "$(items "$(printf '{"metadata":{"name":"mine","namespace":"openagentix-system","annotations":{"meta.helm.sh/release-name":"openagentix"}},"spec":{"selector":{"matchLabels":{"app":"console"}}}}')")"
OUT=$(run); RC=$?
t "owned by this release: exit 0" "$RC" 0

echo "# the switch: a render without budgets does not run the check"
good; fx "get pdb -n openagentix-system -o json" "$(items "$(foreign everything openagentix-system '{}')")"
OUT=$(run "$NOPDB"); RC=$?
t "exit 0 even with a foreign budget present" "$RC" 0
t "no kubectl call at all" "$(wc -l < "$D/calls" | tr -d ' ')" 0
t "it says the check was skipped and why" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'skipped')" 1

echo "# the API does not answer"
good; rm "$D/fx/"*openagentix_knowledge*; OUT=$(run); RC=$?
t "a failed read stops the install (exit 1), it does not pass silently" "$RC" 1
t "and says which namespace it could not read" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'openagentix-knowledge')" 1

echo "# install.sh runs the check before anything is changed, and SKIP_PREFLIGHT does not skip it"
CALL=$(/usr/bin/grep -n 'bash hack/pdb-check.sh' install.sh | head -1 | cut -d: -f1)
HELM=$(/usr/bin/grep -n '^helm upgrade --install' install.sh | head -1 | cut -d: -f1)
# shellcheck disable=SC2016  # the pattern is for grep
FIRST_WRITE=$(/usr/bin/grep -nE '^(cluster_create|\$K (create|apply)|kind create|helm (repo|upgrade))' install.sh | head -1 | cut -d: -f1)
t "install.sh calls hack/pdb-check.sh" "$([ -n "$CALL" ] && echo yes || echo no)" yes
t "the call is before helm upgrade" "$([ -n "$CALL" ] && [ -n "$HELM" ] && [ "$CALL" -lt "$HELM" ] && echo yes || echo no)" yes
t "the call is before the first write of the installer" "$([ -n "$CALL" ] && [ "$CALL" -lt "${FIRST_WRITE:-99999}" ] && echo yes || echo no)" yes
t "the call line does not mention SKIP_PREFLIGHT" "$(sed -n "$((CALL-1)),$((CALL+1))p" install.sh | /usr/bin/grep -c SKIP_PREFLIGHT)" 0

echo "# only reads"
t "every recorded call of the whole run is get" "$(awk '$1!="get"' "$D/calls" | wc -l | tr -d ' ')" 0
# shellcheck disable=SC2016  # the pattern is for grep
t "no write verb anywhere in the script" "$(/usr/bin/grep -vE '^ *(#|echo|printf)' hack/pdb-check.sh | /usr/bin/grep -cE '(\$K|\$KUBECTL|kubectl) +(--context +[^ ]+ +)?(apply|create|delete|patch|replace|label|annotate|edit|exec|run|scale|drain|cordon|taint)( |$)')" 0

echo "# with the real chart: the full demo render against an empty cluster, then against a foreign budget on the gate"
if command -v helm >/dev/null 2>&1; then
  RC_DIR=components
  helm template openagentix charts/openagentix -n openagentix-system -f $RC_DIR/channels/demo-values.yaml -f $RC_DIR/schedules/demo-values.yaml -f $RC_DIR/notify/demo-values.yaml \
    -f $RC_DIR/observability/demo-values.yaml -f $RC_DIR/knowledge/graph-demo-values.yaml -f $RC_DIR/governance/demo-values.yaml -f $RC_DIR/governance/profiles-demo-values.yaml \
    -f $RC_DIR/governance/memory-demo-values.yaml -f $RC_DIR/control-plane/demo-values.yaml -f $RC_DIR/console/demo-values.yaml --set gateway.stubModel.enabled=true --api-versions agentkourier.dev/v1alpha1 \
    | yq -c 'select(.!=null)' > "$D/full.jsonl"
  reset
  for ns in $(jq -r 'select(.kind=="Deployment" or .kind=="StatefulSet")|.metadata.namespace' "$D/full.jsonl" | sort -u); do fx "get pdb -n $ns -o json" '{"items":[]}'; done
  OUT=$(run "$D/full.jsonl"); RC=$?
  t "full demo, nothing foreign: exit 0" "$RC" 0
  t "full demo: it read $(jq -r 'select(.kind=="Deployment" or .kind=="StatefulSet")|.metadata.namespace' "$D/full.jsonl" | sort -u | wc -l | tr -d ' ') namespaces, one get each" "$(wc -l < "$D/calls" | tr -d ' ')" "$(jq -r 'select(.kind=="Deployment" or .kind=="StatefulSet")|.metadata.namespace' "$D/full.jsonl" | sort -u | wc -l | tr -d ' ')"
  fx "get pdb -n openagentix-gateway -o json" "$(items "$(foreign my-gate openagentix-gateway '{"matchLabels":{"app":"a2a-gate"}}')")"
  OUT=$(run "$D/full.jsonl"); RC=$?
  t "a foreign budget on the gate: exit 1" "$RC" 1
  t "and it names Deployment/a2a-gate" "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'Deployment/a2a-gate')" 1
else
  echo "  (helm not found: the real render case is skipped)"
fi
echo
[ "$F" = 0 ] && echo "pdb-check-test: all passed" || echo "pdb-check-test: FAILED"
exit "$F"
