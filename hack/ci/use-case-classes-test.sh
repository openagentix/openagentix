#!/usr/bin/env bash
# Offline test of the budget classes of the three use cases (ADR 0029, slice 5): each use case defines its own class in values.yaml and in values-full-demo.yaml and names it on
# its agent; the classes compose by name beside each other (two or three use cases, with the quick start or the full demo files), the same name with other numbers is
# refused, the chart renders the conditional entries and refuses more than 15 classes, and the event rate of a sender agrees with the class. No cluster.
# Usage: hack/ci/use-case-classes-test.sh   (exit 1 on any failure; needs helm, jq and the Python yq)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE="$ROOT/hack/compose-values.sh"
CHART="$ROOT/charts/openagentix"
UC="$ROOT/examples/use-cases"
QS="$ROOT/components/quickstart/values.yaml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
for t in jq yq; do command -v "$t" >/dev/null || { echo "use-case-classes-test: $t is required" >&2; exit 2; }; done
HAVE_HELM=0; command -v helm >/dev/null && HAVE_HELM=1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
CIDR=(--set-json 'controlPlane.apiServerCIDRs=["172.18.0.0/24"]' --set-json 'diagnostics.apiServerCIDRs=["172.18.0.0/24"]')

# use case, class, tokens, agent
UCS=("bank bank-case-agent 800000 dispute-agent" "equipment equipment-case-agent 800000 service-agent" "software-org rca-diagnostic-agent 300000 pod-rca")

echo "# each use case defines its class and names it on its agent, in both variants"
for row in "${UCS[@]}"; do
  read -r uc cls tok agent <<<"$row"
  for f in values.yaml values-full-demo.yaml; do
    check "$uc/$f: the class $cls ($tok tokens an hour, per agent) is the only class, and $agent names it" \
      "[ \"\$(yq -c '.gateway' '$UC/$uc/$f')\" = '{\"policy\":{\"budgetClasses\":[{\"name\":\"$cls\",\"tokens\":$tok,\"unit\":\"Hours\",\"per\":\"agent\"}]}}' ] && [ \"\$(yq -r '.agents[] | select(.name==\"$agent\") | .budgetClass' '$UC/$uc/$f')\" = '$cls' ]"
  done
  check "$uc: the class is the same in both variants" "[ \"\$(yq -c '.gateway' '$UC/$uc/values.yaml')\" = \"\$(yq -c '.gateway' '$UC/$uc/values-full-demo.yaml')\" ]"
  check "$uc: the README says what the class allows in cases an hour and that it is a soft limit and not a spend cap" "grep -q '$cls' '$UC/$uc/README.md' && grep -qi 'cases an hour' '$UC/$uc/README.md' && grep -qi 'soft limit' '$UC/$uc/README.md' && grep -qi 'not a spend cap' '$UC/$uc/README.md'"
done

echo "# the classes compose by name"
bash "$COMPOSE" -o "$TMP/three.yaml" "$QS" "$UC/bank/values.yaml" "$UC/equipment/values.yaml" "$UC/software-org/values.yaml" 2> "$TMP/three.err"; rc=$?
check "the quick start plus the three use case values compose with no refusal" "[ $rc = 0 ]" "$(head -c 600 "$TMP/three.err")"
check "the composed values hold the three classes once each, in order" "[ \"\$(yq -c '.gateway.policy.budgetClasses | map(.name)' '$TMP/three.yaml')\" = '[\"bank-case-agent\",\"equipment-case-agent\",\"rca-diagnostic-agent\"]' ]"
check "each addition of a class is reported as security relevant" "[ \"\$(grep -c 'SECURITY-RELEVANT.*budget class' '$TMP/three.err')\" = 3 ]" "$(grep -c SECURITY "$TMP/three.err")"
check "the quick start's own gateway entries stay (the model, the stub)" "yq -e '(.gateway.models | map(.name) | index(\"quickstart-model\")) != null and .gateway.stubModel.enabled == true' '$TMP/three.yaml' >/dev/null"
if [ "$HAVE_HELM" = 1 ]; then
helm template t "$CHART" -f "$TMP/three.yaml" "${CIDR[@]}" > "$TMP/three.render" 2> "$TMP/three.rerr"; rc=$?
check "the chart renders the composed values" "[ $rc = 0 ]" "$(head -c 600 "$TMP/three.rerr")"
yq -c 'select(.kind=="AgentgatewayPolicy") | select(.spec.traffic.rateLimit != null) | .spec.traffic.rateLimit.conditional | map(.condition // "default")' "$TMP/three.render" > "$TMP/cond.json" 2>/dev/null
check "the one gateway policy has a conditional entry for each class and the default last" "[ \"\$(cat '$TMP/cond.json')\" = '[\"apiKey.budget_class == \\\"bank-case-agent\\\"\",\"apiKey.budget_class == \\\"equipment-case-agent\\\"\",\"apiKey.budget_class == \\\"rca-diagnostic-agent\\\"\",\"default\"]' ]" "$(cat "$TMP/cond.json")"
check "the model config of each of the three agents carries its class annotation (install.sh writes it into the agent's key entry)" "[ \"\$(yq -r 'select(.kind==\"ModelConfig\" and (.metadata.annotations[\"openagentix.io/budget-class\"] != null)) | .metadata.annotations[\"openagentix.io/agent\"] + \"=\" + .metadata.annotations[\"openagentix.io/budget-class\"]' '$TMP/three.render' | sort | tr '\\n' ' ')\" = 'dispute-agent=bank-case-agent pod-rca=rca-diagnostic-agent service-agent=equipment-case-agent ' ]" "$(yq -r 'select(.kind=="ModelConfig" and (.metadata.annotations["openagentix.io/budget-class"] != null)) | .metadata.annotations["openagentix.io/agent"] + "=" + .metadata.annotations["openagentix.io/budget-class"]' "$TMP/three.render" | tr '\n' ' ')"
else echo "  --   helm is not installed: the render checks are skipped"; fi

echo "# the full demo variants compose the same way (ALSO_COMPOSE order: the other use cases, then this one)"
bash "$COMPOSE" -o "$TMP/fd.yaml" "$QS" "$UC/bank/values-full-demo.yaml" "$UC/equipment/values-full-demo.yaml" "$UC/software-org/values-full-demo.yaml" 2> "$TMP/fd.err"; rc=$?
check "the three values-full-demo.yaml files compose after the quick start with no refusal" "[ $rc = 0 ] && [ \"\$(yq -c '.gateway.policy.budgetClasses | map(.name)' '$TMP/fd.yaml')\" = '[\"bank-case-agent\",\"equipment-case-agent\",\"rca-diagnostic-agent\"]' ]" "$(head -c 600 "$TMP/fd.err")"
bash "$COMPOSE" -o "$TMP/pair.yaml" "$QS" "$UC/equipment/values.yaml" "$UC/bank/values.yaml" 2> "$TMP/pair.err"; rc=$?
check "two use cases in the other order compose too, with their own class each" "[ $rc = 0 ] && [ \"\$(yq -c '.gateway.policy.budgetClasses | map(.name)' '$TMP/pair.yaml')\" = '[\"equipment-case-agent\",\"bank-case-agent\"]' ]"
bash "$COMPOSE" -o "$TMP/ev.yaml" "$QS" "$UC/bank/values.yaml" "$UC/equipment/values.yaml" "$UC/bank/values-events.yaml" "$UC/equipment/values-events.yaml" 2> "$TMP/ev.err"; rc=$?
check "with both event files composed last, the classes and the event callers are all there" "[ $rc = 0 ] && yq -e '(.gateway.policy.budgetClasses|length)==2 and (.governance.a2a.callers|map(.name)|index(\"fernvale-case-events\")) != null and (.governance.a2a.callers|map(.name)|index(\"kestrel-fault-events\")) != null' '$TMP/ev.yaml' >/dev/null" "$(head -c 600 "$TMP/ev.err")"

echo "# the same name with other numbers is refused"
printf 'gateway:\n  policy:\n    budgetClasses:\n      - {name: bank-case-agent, tokens: 5000000, unit: Hours, per: agent}\n' > "$TMP/clash.yaml"
bash "$COMPOSE" -o "$TMP/clash-out.yaml" "$QS" "$UC/bank/values.yaml" "$TMP/clash.yaml" 2> "$TMP/clash.err"; rc=$?
check "another file with bank-case-agent at other numbers is refused, naming the class, and nothing is written" "[ $rc = 1 ] && grep -q 'bank-case-agent' '$TMP/clash.err' && grep -q 'different content' '$TMP/clash.err' && [ ! -e '$TMP/clash-out.yaml' ]" "rc=$rc $(head -c 500 "$TMP/clash.err")"

echo "# the chart's limit on classes: 15 fit, 16 do not"
mk_extra() { # mk_extra <n>: a values file with n more classes
  { printf 'gateway:\n  policy:\n    budgetClasses:\n'; for i in $(seq 1 "$1"); do printf '      - {name: extra-%s, tokens: 1000, unit: Hours, per: agent}\n' "$i"; done; } > "$TMP/extra$1.yaml"
}
mk_extra 12; mk_extra 13
bash "$COMPOSE" -o "$TMP/c15.yaml" "$QS" "$UC/bank/values.yaml" "$UC/equipment/values.yaml" "$UC/software-org/values.yaml" "$TMP/extra12.yaml" 2> "$TMP/c15.err"; rc=$?
check "the three use case classes and 12 more (15) compose" "[ $rc = 0 ]" "$(head -c 400 "$TMP/c15.err")"
if [ "$HAVE_HELM" = 1 ]; then
helm template t "$CHART" -f "$TMP/c15.yaml" "${CIDR[@]}" > /dev/null 2> "$TMP/c15.rerr"; rc=$?
check "and the chart renders 15 classes" "[ $rc = 0 ]" "$(head -c 400 "$TMP/c15.rerr")"
bash "$COMPOSE" -o "$TMP/c16.yaml" "$QS" "$UC/bank/values.yaml" "$UC/equipment/values.yaml" "$UC/software-org/values.yaml" "$TMP/extra13.yaml" 2> /dev/null
helm template t "$CHART" -f "$TMP/c16.yaml" "${CIDR[@]}" > /dev/null 2> "$TMP/c16.rerr"; rc=$?
check "16 classes compose but the chart refuses them, naming the limit" "[ $rc != 0 ] && grep -q 'at most 15' '$TMP/c16.rerr'" "rc=$rc $(head -c 400 "$TMP/c16.rerr")"
fi

echo "# the event rate of a sender and its class agree"
# per case, the high end of the measured runs (tokens): bank 180,000 (README), equipment 94,000 (660,000 over seven cases)
ev_check() { # ev_check <use case> <class tokens> <high tokens per case>
  local uc=$1 tok=$2 high=$3 burst
  burst=$(yq -r '.governance.a2a.callers[0].event.rate.burst' "$UC/$uc/values-events.yaml")
  check "$uc: the burst ($burst runs at once, at most $high tokens each) fits inside the class ($tok tokens), so the rate spreads a burst and the class is the stop" "[ $((burst * high)) -le $tok ]"
  check "$uc: values-events.yaml names the class as the real stop, not only the gateway budget" "grep -q '$(yq -r '.gateway.policy.budgetClasses[0].name' "$UC/$uc/values.yaml")' '$UC/$uc/values-events.yaml'"
  check "$uc: the README says the class is the real stop of the event sender" "grep -qi 'class.*real stop\|real stop.*class' '$UC/$uc/README.md'"
}
ev_check bank 800000 180000
ev_check equipment 800000 94000

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
