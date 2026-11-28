#!/usr/bin/env bash
# Chart tests of ADR 0029, slice 3: budget classes in the one gateway policy. Sourced by run.sh (it shares eq, q, count, docs, render_err,
# and the variables CHART, REPO, CP9). Every check here was written before the chart code and failed first (see the pull request).
echo "# budget classes (ADR 0029, slice 3): conditional rate limit per class, off by default"
RCQ="$REPO/components/quickstart/values.yaml"
BCX="$(dirname "$0")/.bc-values.yaml"
trap 'rm -f "$BCX"' EXIT
POL='.[]|select(.kind=="AgentgatewayPolicy")|.spec.traffic.rateLimit'
# bc_render_ok / bc_fail <description> <sentence part> <helm args...>
bc_fail() { local d=$1 s=$2; shift 2; eq "$d" "$(render_err "$@" | /usr/bin/grep -cF -- "$s")" 1; }
CLS2='[{"name":"bank-agents","tokens":300000,"unit":"Hours","per":"agent"},{"name":"shared-pool","tokens":500000,"unit":"Hours","per":"class"}]'

echo "# budget classes: nothing set renders what it rendered before"
DEF=$(docs)
eq "default: the one local entry, as before" "$(q "$DEF" "$POL|tojson")" '{"local":[{"tokens":1000000,"unit":"Hours","key":"apiKey.user_id"}]}'
eq "default values: gateway.policy.budgetClasses is an empty list" "$(yq -c '.gateway.policy.budgetClasses' "$CHART/values.yaml")" '[]'
eq "default values: controlPlane.policy.budgetClasses.definitions is the empty string" "$(yq -c '.controlPlane.policy.budgetClasses' "$CHART/values.yaml")" '{"definitions":""}'
eq "default: no ModelConfig has a budget-class annotation" "$(q "$DEF" '[.[]|select(.kind=="ModelConfig")|select(.metadata.annotations["openagentix.io/budget-class"]!=null)]|length')" 0
B0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
BQ0=$(helm template openagentix "$CHART" -n openagentix-system -f "$RCQ" 2>&1 | shasum -a 256)
BF0=$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" --set gateway.stubModel.enabled=true 2>&1 | shasum -a 256)
eq "budgetClasses=[] and definitions empty render byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set-json 'gateway.policy.budgetClasses=[]' --set 'controlPlane.policy.budgetClasses.definitions=' 2>&1 | shasum -a 256)" "$B0"
eq "budgetClasses=null renders byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set 'gateway.policy.budgetClasses=null' 2>&1 | shasum -a 256)" "$B0"
eq "controlPlane.policy.budgetClasses=null renders byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set 'controlPlane.policy.budgetClasses=null' 2>&1 | shasum -a 256)" "$B0"
eq "quick start: explicit empty classes render byte-identical" "$(helm template openagentix "$CHART" -n openagentix-system -f "$RCQ" --set-json 'gateway.policy.budgetClasses=[]' 2>&1 | shasum -a 256)" "$BQ0"
eq "full demo: explicit empty classes render byte-identical" "$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" --set gateway.stubModel.enabled=true --set-json 'gateway.policy.budgetClasses=[]' --set 'controlPlane.policy.budgetClasses.definitions=' 2>&1 | shasum -a 256)" "$BF0"
if [ -n "${OA_BASELINE_CHART:-}" ]; then   # the chart as it was before this feature (CI: a checkout of main)
  BL() { helm template openagentix "$OA_BASELINE_CHART" -n openagentix-system "$@" 2>&1 | shasum -a 256; }
  eq "the default render is byte-identical to the baseline chart (OA_BASELINE_CHART)" "$B0" "$(BL)"
  eq "the quick start render is byte-identical to the baseline chart (OA_BASELINE_CHART)" "$BQ0" "$(BL -f "$RCQ")"
  eq "the full demo render is byte-identical to the baseline chart (OA_BASELINE_CHART)" "$BF0" "$(BL "${CP9[@]}" --set gateway.stubModel.enabled=true)"
fi
GUARD_CM='.[]|select(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="openagentix-control-plane-guard-configmaps")'
DG0=$(docs "${CP9[@]}")
eq "control plane on, definitions empty: the key rule has no budget_class" "$(q "$DG0" "[$GUARD_CM|.spec.validations[]|select(.expression|test(\"budget_class\"))]|length")" 0

echo "# budget classes: the conditional render"
D=$(docs --set-json "gateway.policy.budgetClasses=$CLS2")
RL=$(q "$D" "$POL")
eq "two classes and the fallback: three conditional entries, no plain local" "$(jq -r '[(.conditional|length),(has("local"))]|join(" ")' <<<"$RL")" "3 false"
eq "class 1: condition on the metadata member, one local entry per agent (key apiKey.user_id)" "$(jq -c '.conditional[0]' <<<"$RL")" '{"condition":"apiKey.budget_class == \"bank-agents\"","policy":{"local":[{"tokens":300000,"unit":"Hours","key":"apiKey.user_id"}]}}'
eq "class 2: per class, no key (one shared bucket)" "$(jq -c '.conditional[1]' <<<"$RL")" '{"condition":"apiKey.budget_class == \"shared-pool\"","policy":{"local":[{"tokens":500000,"unit":"Hours"}]}}'
eq "the fallback is last, has no condition, and is today's budget" "$(jq -c '.conditional[2]' <<<"$RL")" '{"policy":{"local":[{"tokens":1000000,"unit":"Hours","key":"apiKey.user_id"}]}}'
D=$(docs --set-json "gateway.policy.budgetClasses=$CLS2" --set gateway.policy.tokenBudget.tokens=42000 --set gateway.policy.tokenBudget.unit=Minutes)
eq "the fallback follows gateway.policy.tokenBudget" "$(q "$D" "$POL|.conditional[2]|tojson")" '{"policy":{"local":[{"tokens":42000,"unit":"Minutes","key":"apiKey.user_id"}]}}'
eq "the other parts of the one policy are unchanged (auth, retry)" "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.traffic|[(.apiKeyAuthentication|tojson),(.retry|tojson)]|join(" ")')" "$(q "$DEF" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.traffic|[(.apiKeyAuthentication|tojson),(.retry|tojson)]|join(" ")')"
eq "still one AgentgatewayPolicy" "$(count "$D" '.kind=="AgentgatewayPolicy"')" 1
D=$(docs --set-json 'gateway.policy.budgetClasses=[{"name":"a","tokens":1,"unit":"Seconds","per":"agent"},{"name":"b","tokens":2147483647,"unit":"Minutes","per":"agent"}]')
eq "the smallest and the largest token count, Seconds and Minutes, render" "$(q "$D" "$POL|[.conditional[0].policy.local[0].tokens,.conditional[0].policy.local[0].unit,.conditional[1].policy.local[0].tokens,.conditional[1].policy.local[0].unit]|join(\" \")")" "1 Seconds 2147483647 Minutes"
eq "tokens render as numbers, not as 3e+05 or as a string" "$(helm template openagentix "$CHART" -n openagentix-system --set-json "gateway.policy.budgetClasses=$CLS2" | /usr/bin/grep -c 'tokens: 300000$')" 1

echo "# budget classes: the list length (15 classes and the fallback fit the CRD's 16 entries)"
mkcls() { jq -nc --argjson n "$1" '[range($n)|{name:("c"+tostring),tokens:1000,unit:"Hours",per:"agent"}]'; }
eq "15 classes render, 16 conditional entries" "$(q "$(docs --set-json "gateway.policy.budgetClasses=$(mkcls 15)")" "$POL|.conditional|length")" 16
bc_fail "16 classes fail the render and say why" "gateway.policy.budgetClasses" --set-json "gateway.policy.budgetClasses=$(mkcls 16)"
eq "16 classes: the error names the limit of 15" "$(render_err --set-json "gateway.policy.budgetClasses=$(mkcls 16)" | /usr/bin/grep -c 'at most 15')" 1

echo "# budget classes: refusals, one test each"
ONE='{"name":"ok","tokens":1000,"unit":"Hours","per":"agent"}'
mut() { jq -c ". + $1" <<<"$ONE"; }
bcf() { local d=$1 s=$2 v=$3; bc_fail "$d" "$s" --set-json "gateway.policy.budgetClasses=[$v]"; }
bcf "a name in upper case is refused"                "budgetClasses[0].name" "$(mut '{"name":"Bank"}')"
bcf "a name with an underscore is refused"           "budgetClasses[0].name" "$(mut '{"name":"a_b"}')"
bcf "a name that starts with a dash is refused"      "budgetClasses[0].name" "$(mut '{"name":"-a"}')"
bcf "a name of 41 characters is refused"             "budgetClasses[0].name" "$(mut "{\"name\":\"$(printf 'a%.0s' $(seq 1 41))\"}")"
eq  "a name of 40 characters renders" "$([ -z "$(render_err --set-json "gateway.policy.budgetClasses=[$(mut "{\"name\":\"$(printf 'a%.0s' $(seq 1 40))\"}")]")" ] && echo rendered || echo failed)" rendered
bcf "an empty name is refused"                       "budgetClasses[0].name" "$(mut '{"name":""}')"
bcf "a missing name is refused"                      "budgetClasses[0].name" "$(jq -c 'del(.name)' <<<"$ONE")"
bcf "the name default is reserved"                   "default" "$(mut '{"name":"default"}')"
bc_fail "a duplicate name is refused" "duplicate" --set-json "gateway.policy.budgetClasses=[$ONE,$ONE]"
bcf "tokens 0 is refused"                            "budgetClasses[0].tokens" "$(mut '{"tokens":0}')"
bcf "negative tokens are refused"                    "budgetClasses[0].tokens" "$(mut '{"tokens":-5}')"
bcf "tokens above 2147483647 are refused"            "budgetClasses[0].tokens" "$(mut '{"tokens":2147483648}')"
bcf "tokens as a string are refused"                 "budgetClasses[0].tokens" "$(mut '{"tokens":"1000"}')"
bcf "fractional tokens are refused"                  "budgetClasses[0].tokens" "$(mut '{"tokens":1000.5}')"
bcf "missing tokens are refused"                     "budgetClasses[0].tokens" "$(jq -c 'del(.tokens)' <<<"$ONE")"
bcf "a unit in lower case is refused"                "budgetClasses[0].unit" "$(mut '{"unit":"hours"}')"
bcf "the unit Days is refused (the CRD stops at Hours)" "budgetClasses[0].unit" "$(mut '{"unit":"Days"}')"
bcf "a missing unit is refused"                      "budgetClasses[0].unit" "$(jq -c 'del(.unit)' <<<"$ONE")"
bcf "a missing per is refused (no default)"          "budgetClasses[0].per" "$(jq -c 'del(.per)' <<<"$ONE")"
bcf "per namespace is refused"                       "budgetClasses[0].per" "$(mut '{"per":"namespace"}')"
bcf "per in upper case is refused"                   "budgetClasses[0].per" "$(mut '{"per":"Agent"}')"
bcf "a misspelt field is refused (not silently ignored)" "budgetClasses[0]" "$(mut '{"perr":"agent"}')"
bcf "an entry that is not a map is refused"          "budgetClasses[0]" '"bank"'
bc_fail "a value that is not a list is refused" "gateway.policy.budgetClasses must be a list" --set-json 'gateway.policy.budgetClasses={"a":1}'
bc_fail "a second bad entry is named by its position" "budgetClasses[1]" --set-json "gateway.policy.budgetClasses=[$ONE,$(mut '{"name":"two","tokens":0}')]"

echo "# budget classes: chart agents name a class"
cat > "$BCX" <<YAML
gateway:
  policy:
    budgetClasses: $CLS2
agents:
  - name: assistant
    description: General assistant
    model: claude-haiku
    budgetClass: bank-agents
    systemPrompt: hello
    tools: []
  - name: plain
    description: An agent with no class
    model: claude-haiku
    systemPrompt: hello
    tools: []
YAML
D=$(docs -f "$BCX")
MC='.[]|select(.kind=="ModelConfig")'
eq "the agent that names a class: its ModelConfig carries the annotation" "$(q "$D" "$MC|select(.metadata.annotations[\"openagentix.io/agent\"]==\"assistant\")|.metadata.annotations[\"openagentix.io/budget-class\"]")" bank-agents
eq "the agent that names none: no annotation" "$(q "$D" "$MC|select(.metadata.annotations[\"openagentix.io/agent\"]==\"plain\")|.metadata.annotations|has(\"openagentix.io/budget-class\")")" false
eq "the annotation is on no other kind" "$(q "$D" '[.[]|select(.kind!="ModelConfig")|select(.metadata.annotations["openagentix.io/budget-class"]!=null)]|length')" 0
eq "agents with a class render without error" "$([ -z "$(render_err -f "$BCX")" ] && echo rendered || echo failed)" rendered
bc_fail "an agent that names a class that does not exist fails and names the agent and the class" "agents[assistant]: budgetClass \"nope\"" -f "$BCX" --set 'agents[0].budgetClass=nope'
bc_fail "an agent that names a class when none is defined fails" "budgetClass" --set-json 'agents=[{"name":"assistant","description":"x","model":"claude-haiku","budgetClass":"bank-agents","systemPrompt":"x","tools":[]}]'
bc_fail "an agent budgetClass that is not a string fails" "budgetClass" -f "$BCX" --set-json 'agents[0].budgetClass=5'
bc_fail "an agent budgetClass of default is refused (reserved)" "default" -f "$BCX" --set 'agents[0].budgetClass=default'
eq "an empty budgetClass on an agent means no class: no annotation" "$(q "$(docs -f "$BCX" --set 'agents[0].budgetClass=')" "[$MC|select(.metadata.annotations[\"openagentix.io/budget-class\"]!=null)]|length")" 0
eq "an agent with a class: the rest of the rendered agent objects equal the render without the class" "$(docs -f "$BCX" | jq -S -c '[.[]|select(.kind=="Agent" or .kind=="AgentTemplate" or .kind=="Harness")]' | shasum -a 256)" "$(docs -f "$BCX" --set 'agents[0].budgetClass=' | jq -S -c '[.[]|select(.kind=="Agent" or .kind=="AgentTemplate" or .kind=="Harness")]' | shasum -a 256)"

echo "# budget classes: the class of definitions (controlPlane.policy.budgetClasses.definitions) and the guard"
DEFS=(--set-json "gateway.policy.budgetClasses=$CLS2")
D=$(docs "${CP9[@]}" "${DEFS[@]}" --set controlPlane.policy.budgetClasses.definitions=bank-agents)
KEYRULE="[$GUARD_CM|.spec.validations[]|select(.message|test(\"key ConfigMap|an entry of the key\"))]"
KR=$(q "$D" "$KEYRULE|map(.expression)|join(\"\\n\")")
eq "definitions=bank-agents: the key rule accepts one optional last member, that class, written out" "$(printf '%s' "$KR" | /usr/bin/grep -cF '(,"budget_class":"bank-agents")?\\}\\}$')" 1
eq "definitions=bank-agents: no other class name is in the key rule" "$(printf '%s' "$KR" | /usr/bin/grep -c 'shared-pool')" 0
eq "definitions=bank-agents: the rule still pins user_id and the key hash" "$(printf '%s' "$KR" | /usr/bin/grep -cE 'keyHash.*user_id|user_id.*keyHash')" 1
eq "definitions set: the rule is the only difference from the default guard (no other policy changes)" "$(q "$D" '[.[]|select(.kind=="ValidatingAdmissionPolicy" and .metadata.name!="openagentix-control-plane-guard-configmaps")]|tojson' | shasum -a 256)" "$(q "$DG0" '[.[]|select(.kind=="ValidatingAdmissionPolicy" and .metadata.name!="openagentix-control-plane-guard-configmaps")]|tojson' | shasum -a 256)"
eq "definitions empty with classes defined: the guard is byte-identical to the default guard" "$(q "$(docs "${CP9[@]}" "${DEFS[@]}")" "$GUARD_CM|tojson" | shasum -a 256)" "$(q "$DG0" "$GUARD_CM|tojson" | shasum -a 256)"
bc_fail "definitions naming a per: class class is refused, and says why" "per: agent" "${CP9[@]}" "${DEFS[@]}" --set controlPlane.policy.budgetClasses.definitions=shared-pool
bc_fail "definitions naming a class that does not exist is refused" "controlPlane.policy.budgetClasses.definitions" "${CP9[@]}" "${DEFS[@]}" --set controlPlane.policy.budgetClasses.definitions=nope
bc_fail "definitions with no classes defined is refused" "controlPlane.policy.budgetClasses.definitions" "${CP9[@]}" --set controlPlane.policy.budgetClasses.definitions=bank-agents
bc_fail "definitions=default is refused (reserved)" "default" "${CP9[@]}" "${DEFS[@]}" --set controlPlane.policy.budgetClasses.definitions=default
bc_fail "definitions that is not a string is refused" "controlPlane.policy.budgetClasses.definitions" "${CP9[@]}" "${DEFS[@]}" --set-json controlPlane.policy.budgetClasses.definitions=5
eq "definitions set but the control plane off: still validated (a typo fails, it does not wait for the switch)" "$(render_err "${DEFS[@]}" --set controlPlane.policy.budgetClasses.definitions=nope | /usr/bin/grep -c 'controlPlane.policy.budgetClasses.definitions')" 1
eq "definitions set and the control plane off: the render has no guard and no key rule" "$(count "$(docs "${DEFS[@]}" --set controlPlane.policy.budgetClasses.definitions=bank-agents)" '.kind=="ValidatingAdmissionPolicy"')" 0

echo "# budget classes: agents[].budgetClass is checked with the gateway off too (security review of PR 267, F1)"
GOFF=(--set gateway.enabled=false)
HOSTILE_A='[{"name":"a","description":"x","model":"claude-haiku","budgetClass":"Evil\",\"admin\":\"1","systemPrompt":"x","tools":[]}]'
HOSTILE_B='[{"name":"a","description":"x","model":"claude-haiku","budgetClass":{"x":1},"systemPrompt":"x","tools":[]}]'
HOSTILE_C='[{"name":"a","description":"x","model":"claude-haiku","budgetClass":"wide","systemPrompt":"x","tools":[]}]'
bc_fail "gateway off: a class with quotes is refused" "budgetClass" "${GOFF[@]}" --set-json "agents=$HOSTILE_A"
bc_fail "gateway off: a class that is a map is refused" "budgetClass" "${GOFF[@]}" --set-json "agents=$HOSTILE_B"
bc_fail "gateway off: a class that no class list defines is refused" "agents[a]: budgetClass \"wide\"" "${GOFF[@]}" --set-json "agents=$HOSTILE_C"
HOSTILE_D='[{"name":"a","description":"x","model":"claude-haiku","systemPrompt":"x","tools":[]}]'
eq "gateway off: an agent with no class renders" "$([ -z "$(render_err "${GOFF[@]}" --set-json "agents=$HOSTILE_D")" ] && echo rendered || echo failed)" rendered
