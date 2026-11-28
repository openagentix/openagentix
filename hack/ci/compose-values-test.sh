#!/usr/bin/env bash
# Tests for hack/compose-values.sh (ADR 0026, E): merge values files by entry name, refuse a changed entry and a changed security key,
# report every change, keep an explicit empty list. No cluster. Needs: bash, jq, yq (the Python jq wrapper), helm (for the last cases).
# Usage: hack/ci/compose-values-test.sh   (exit 1 on any failure)
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
SCRIPT="$ROOT/hack/compose-values.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
for t in jq yq; do command -v "$t" >/dev/null || { echo "ERROR: $t is required" >&2; exit 2; }; done
yq --version 2>&1 | grep -q '^yq 3\.' || { echo "ERROR: yq must be the Python wrapper (kislyuk/yq 3.x)" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# w NAME <<<yaml : write a fixture file under $T
w() { cat > "$T/$1"; }
# run ARGS... : the script; stdout in $T/out, stderr in $T/err, exit code in $RC
run() { bash "$SCRIPT" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
out_json() { yq -c . "$T/out"; }
out_has() { out_json | jq -e "$1" >/dev/null; }     # a jq test on the composed values

echo "# the script and its help"
check "the script exists and is executable" "[ -x '$SCRIPT' ]"
run -h
check "-h exits 0 and says what it does" "[ $RC = 0 ] && grep -q 'compose-values.sh' '$T/out'"
check "the help carries the note: read the report and the output before installing" "grep -qi 'read the report and the output' '$T/out'"
run
check "no file: usage error (exit 2), nothing on stdout" "[ $RC = 2 ] && [ ! -s '$T/out' ] && grep -qi 'usage' '$T/err'"
run "$T/missing.yaml"
check "a missing file: exit 2 and its name" "[ $RC = 2 ] && grep -q 'missing.yaml' '$T/err'"
run --nonsense "$T/a.yaml"
check "an unknown option: exit 2" "[ $RC = 2 ]"
w bad.yaml <<<'[1, 2]'
run "$T/bad.yaml"
check "a file that is not a mapping: refused with its name" "[ $RC = 1 ] && grep -q 'bad.yaml' '$T/err' && [ ! -s '$T/out' ]"
printf 'a: [unclosed\n' > "$T/broken.yaml"
run "$T/broken.yaml"
check "a file that is not YAML: refused with its name" "[ $RC != 0 ] && grep -q 'broken.yaml' '$T/err' && [ ! -s '$T/out' ]"

echo "# maps merge, the output names its inputs, the output is stable"
w a.yaml <<'EOF'
knowledge: {enabled: false}
gateway:
  stubModel: {enabled: true}
x: {keep: 1, over: 1}
EOF
w b.yaml <<'EOF'
knowledge: {enabled: true, kb: {graph: {enabled: true}}}
x: {over: 2, added: 3}
EOF
run "$T/a.yaml" "$T/b.yaml"
check "exit 0" "[ $RC = 0 ]" "$(cat "$T/err")"
check "the output starts with a comment that lists both files" "head -1 '$T/out' | grep -q '^# ' && head -3 '$T/out' | grep -q 'a.yaml' && head -3 '$T/out' | grep -q 'b.yaml'"
check "maps are merged: keys from both, the later scalar wins" "out_has '.x == {keep:1, over:2, added:3} and .gateway.stubModel.enabled == true and .knowledge.enabled == true and .knowledge.kb.graph.enabled == true'"
check "a changed scalar is reported with path, old and new value" "grep -q 'knowledge.enabled' '$T/err' && grep 'knowledge.enabled' '$T/err' | grep -q 'false' && grep 'knowledge.enabled' '$T/err' | grep -q 'true'"
check "x.over is reported 1 to 2" "grep 'x.over' '$T/err' | grep -q '1' && grep 'x.over' '$T/err' | grep -q '2'"
check "an unchanged scalar is not reported" "! grep -q 'x.keep' '$T/err' && ! grep -q 'gateway.stubModel.enabled' '$T/err'"
cp "$T/out" "$T/out1"; run "$T/a.yaml" "$T/b.yaml"
check "two runs give the same output, byte for byte" "cmp -s '$T/out1' '$T/out'"
run "$T/b.yaml" "$T/a.yaml"
check "the order of the files is the order of precedence (b then a: a wins)" "out_has '.x.over == 1 and .knowledge.enabled == false'"
w c.yaml <<'EOF'
x: {over: 3}
EOF
run "$T/a.yaml" "$T/b.yaml" "$T/c.yaml"
check "three files: the last file wins, and both changes are reported" "out_has '.x.over == 3' && [ \"\$(grep -c 'x.over' '$T/err')\" -ge 2 ]"
run "$T/a.yaml"
check "one file: the same values come out" "[ $RC = 0 ] && out_has '.x == {keep:1, over:1} and .knowledge.enabled == false'"

echo "# lists are merged by name: agents, schedules, governance.a2a.callers, gateway.models, mcp.servers, mcp.endpoints, mcp.profiles"
for path in agents schedules governance.a2a.callers gateway.models mcp.servers mcp.endpoints mcp.profiles; do
  jq -n --arg p "$path" 'setpath(($p|split(".")); [{name:"one", v:1},{name:"two", v:2}])' > "$T/l1.json"
  jq -n --arg p "$path" 'setpath(($p|split(".")); [{name:"two", v:2},{name:"three", v:3}])' > "$T/l2.json"
  run "$T/l1.json" "$T/l2.json"
  check "$path: entries of both files, in order of first appearance, the same entry once" "[ $RC = 0 ] && out_has '(getpath(\"$path\"|split(\".\")) | map(.name)) == [\"one\",\"two\",\"three\"]'" "rc=$RC $(cat "$T/err")"
  check "$path: the entry that a later file adds is reported on stderr" "grep -q 'added.*three' '$T/err'"
  check "$path: an entry that is the same in both files is not a change" "! grep -E 'changed|refused' '$T/err' | grep -q 'two'"
done
w d1.yaml <<'EOF'
agents:
  - {name: alpha, model: m1, tools: [a, b]}
EOF
w d2.yaml <<'EOF'
agents:
  - {name: alpha, model: m1, tools: [a, b]}
  - {name: beta, model: m2}
EOF
run "$T/d1.yaml" "$T/d2.yaml"
check "the same name with the same body (deep) is kept once" "[ $RC = 0 ] && out_has '(.agents|length) == 2 and .agents[0].name == \"alpha\" and .agents[1].name == \"beta\"'"
w d3.yaml <<'EOF'
agents:
  - {name: alpha, model: m9, tools: [a]}
EOF
run "$T/d1.yaml" "$T/d3.yaml"
check "the same name with a different body: refused, exit 1, nothing on stdout" "[ $RC = 1 ] && [ ! -s '$T/out' ]"
check "the refusal names the entry and both file names" "grep -q 'alpha' '$T/err' && grep -q 'd1.yaml' '$T/err' && grep -q 'd3.yaml' '$T/err'"
check "the refusal points at --later-wins" "grep -q -- '--later-wins' '$T/err'"
run --later-wins "$T/d1.yaml" "$T/d3.yaml"
check "--later-wins: the later body replaces the entry" "[ $RC = 0 ] && out_has '.agents == [{name:\"alpha\", model:\"m9\", tools:[\"a\"]}]'"
check "--later-wins: each changed scalar of the entry is reported with its path" "grep -q 'agents\[alpha\].model' '$T/err' && grep 'agents\[alpha\].model' '$T/err' | grep -q 'm1' && grep 'agents\[alpha\].model' '$T/err' | grep -q 'm9'"
w dup.yaml <<'EOF'
agents:
  - {name: alpha, model: m1}
  - {name: alpha, model: m2}
EOF
run "$T/dup.yaml"
check "the same name twice in one file with different bodies: refused, names the file" "[ $RC = 1 ] && grep -q 'dup.yaml' '$T/err' && [ ! -s '$T/out' ]"
w dupok.yaml <<'EOF'
agents:
  - {name: alpha, model: m1}
  - {name: alpha, model: m1}
EOF
run "$T/dupok.yaml"
check "the same name twice in one file with the same body: kept once" "[ $RC = 0 ] && out_has '(.agents|length) == 1'"
w noname.yaml <<'EOF'
agents:
  - {model: m1}
EOF
run "$T/noname.yaml"
check "an entry without a name: refused, names the file and the list" "[ $RC = 1 ] && grep -q 'noname.yaml' '$T/err' && grep -q 'agents' '$T/err' && grep -qi 'name' '$T/err'"

echo "# an explicit empty list is kept; other lists are replaced and reported"
w e1.yaml <<'EOF'
agents: []
x: {list: [1, 2], other: [a]}
EOF
run "$T/e1.yaml"
check "a file that has agents: [] gives agents: [] (not dropped)" "[ $RC = 0 ] && out_has '(.agents == []) and (.x.list == [1,2])'"
w e2.yaml <<'EOF'
agents:
  - {name: alpha}
x: {list: [3], other: []}
EOF
run "$T/e1.yaml" "$T/e2.yaml"
check "an earlier [] and a later list of entries: the entries" "out_has '.agents == [{name:\"alpha\"}]'"
check "a list that is not merged by name is replaced by the later file" "out_has '.x.list == [3]'"
check "the replaced list is reported with its path" "grep -q 'x.list' '$T/err' && grep 'x.list' '$T/err' | grep -qi 'replac'"
check "a later [] replaces the earlier list and stays [] in the output" "out_has '.x.other == []' && grep -q 'x.other' '$T/err'"
run "$T/e2.yaml" "$T/e1.yaml"
check "a later agents: [] replaces the entries of the earlier file (as Helm does) and is reported" "[ $RC = 0 ] && out_has '.agents == []' && grep -q 'agents' '$T/err' && grep 'agents' '$T/err' | grep -qi 'empty\|replac'"

echo "# secrets and keys are reported by path only"
w s1.yaml <<'EOF'
gateway: {models: [{name: m, authSecret: SENTINEL-OLD-SECRET}]}
foo: {apiKey: SENTINEL-OLD-APIKEY, tokenKey: SENTINEL-OLD-TOKENKEY, password: SENTINEL-OLD-PW, plain: visible-old}
EOF
w s2.yaml <<'EOF'
foo: {apiKey: SENTINEL-NEW-APIKEY, tokenKey: SENTINEL-NEW-TOKENKEY, password: SENTINEL-NEW-PW, plain: visible-new}
EOF
run "$T/s1.yaml" "$T/s2.yaml"
check "exit 0" "[ $RC = 0 ]" "$(cat "$T/err")"
check "the path of each changed key or secret is reported" "grep -q 'foo.apiKey' '$T/err' && grep -q 'foo.tokenKey' '$T/err' && grep -q 'foo.password' '$T/err'"
check "no secret or key value appears in the report" "! grep -q 'SENTINEL' '$T/err'"
check "an ordinary value is reported with both values" "grep 'foo.plain' '$T/err' | grep -q 'visible-old' && grep 'foo.plain' '$T/err' | grep -q 'visible-new'"
check "the composed values still hold the later value (it is the operator's file)" "out_has '.foo.apiKey == \"SENTINEL-NEW-APIKEY\"'"

echo "# security keys: a later file may not change them without --later-wins"
sec() { # sec "<dotted path>" '<json old>' '<json new>' : one case
  local p=$1 old=$2 new=$3
  jq -n --arg p "$p" --argjson v "$old" 'setpath(($p|split(".")); $v)' > "$T/sec1.json"
  jq -n --arg p "$p" --argjson v "$new" 'setpath(($p|split(".")); $v)' > "$T/sec2.json"
  run "$T/sec1.json" "$T/sec2.json"
  check "$p: a change is refused (exit 1), nothing on stdout, the key is named" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q '$p' '$T/err'" "rc=$RC $(cat "$T/err")"
  check "$p: the refusal names both files and --later-wins" "grep -q 'sec1.json' '$T/err' && grep -q 'sec2.json' '$T/err' && grep -q -- '--later-wins' '$T/err'"
  run --later-wins "$T/sec1.json" "$T/sec2.json"
  check "$p: --later-wins replaces it" "[ $RC = 0 ] && out_has 'getpath(\"$p\"|split(\".\")) == $new'"
  check "$p: --later-wins reports it as a change of a security key" "grep -i 'security' '$T/err' | grep -q '$p'"
  run "$T/sec1.json" "$T/sec1.json"
  check "$p: the same value in the later file is not a change" "[ $RC = 0 ]"
}
sec controlPlane.policy.allowedModels '["a"]' '["b"]'
sec controlPlane.policy.allowedProfiles '["lookup"]' '["lookup","other"]'
sec controlPlane.policy.allowedSkills '["s1"]' '[]'
sec controlPlane.policy.egress.inClusterDestinations '["a.b"]' '["a.b","c.d"]'
sec controlPlane.policy.egress.origins '["https://a.example"]' '["https://b.example"]'
sec controlPlane.policy.requireToolProfile 'true' 'false'
sec controlPlane.policy.allowKnowledge 'false' 'true'
sec controlPlane.policy.allowNotify 'false' 'true'
sec controlPlane.policy.memory.allow 'false' 'true'
sec controlPlane.policy.allowedRuntimes '["builtin"]' '["builtin","container"]'
sec controlPlane.policy.runtimes.container.images '["registry.local/oa/"]' '["registry.example/"]'
sec controlPlane.containerAgents.toolProfiles '["a"]' '["a","b"]'
sec networkPolicy.enabled 'true' 'false'

# networkPolicy.extraA2ACallers is a list of entries named by `namespace` (ADR 0027 slices 5 and 6: a use case's records service calls the gate, and two use cases
# can run side by side): entries are merged by namespace and every addition is reported as SECURITY-RELEVANT, like a caller rule. A changed entry is refused.
# A new entry is refused unless it is narrow: podLabels that are not empty, keys namespace and podLabels only, a namespace that is not default, kube-*, openagentix-* or a namespace
# of the chart's own values (the platform namespaces: the list the chart's endpoint check walks), and a caller rule in the composed result for a ServiceAccount of that namespace.
xcfile() { # xcfile <file> <namespace> <entry json> [with-rule: 1|0]: a values file with one extraA2ACallers entry and (by default) a caller rule for the namespace
  local f=$1 ns=$2 entry=$3 rule=${4:-1}
  if [ "$rule" = 1 ]; then
    jq -n --arg ns "$ns" --argjson e "$entry" '{governance:{a2a:{callers:[{name:("rule-"+$ns),serviceAccount:{namespace:$ns,name:"records-events"},agents:["agent"]}]}},networkPolicy:{extraA2ACallers:[$e]}}' > "$T/$f"
  else
    jq -n --argjson e "$entry" '{networkPolicy:{extraA2ACallers:[$e]}}' > "$T/$f"
  fi
}
xcfile xc1.yaml kestrel-records '{"namespace":"kestrel-records","podLabels":{"app":"records"}}'
xcfile xc2.yaml fernvale-records '{"namespace":"fernvale-records","podLabels":{"app":"records"}}'
xcfile xc3.yaml kestrel-records '{"namespace":"kestrel-records","podLabels":{"app":"other"}}'
w xc0.yaml <<'EOF'
knowledge: {enabled: false}
EOF
run "$T/xc0.yaml" "$T/xc1.yaml"
check "extraA2ACallers: a first file that has none, a later one adds an entry (with its caller rule): composed" "[ $RC = 0 ] && out_has '.networkPolicy.extraA2ACallers == [{namespace:\"kestrel-records\",podLabels:{app:\"records\"}}]'" "$(cat "$T/err")"
check "extraA2ACallers: the addition is reported as security relevant and names the namespace" "grep -q 'SECURITY-RELEVANT' '$T/err' && grep 'SECURITY-RELEVANT' '$T/err' | grep -q 'kestrel-records'"
run "$T/xc0.yaml" "$T/xc1.yaml" "$T/xc2.yaml"
check "extraA2ACallers: two files with different namespaces are joined by namespace (the two use cases, each with its caller rule)" "[ $RC = 0 ] && out_has '(.networkPolicy.extraA2ACallers | map(.namespace)) == [\"kestrel-records\",\"fernvale-records\"]'" "$(cat "$T/err")"
run "$T/xc0.yaml" "$T/xc1.yaml" "$T/xc1.yaml"
check "extraA2ACallers: the same entry twice is kept once" "[ $RC = 0 ] && out_has '(.networkPolicy.extraA2ACallers | length) == 1'"
run "$T/xc1.yaml" "$T/xc3.yaml"
check "extraA2ACallers: the same namespace with other pod labels is refused, naming both files" "[ $RC = 1 ] && grep -q 'xc1.yaml' '$T/err' && grep -q 'xc3.yaml' '$T/err' && [ ! -s '$T/out' ]"
w xc4.yaml <<'EOF'
networkPolicy:
  extraA2ACallers:
    - {podLabels: {app: records}}
EOF
run "$T/xc1.yaml" "$T/xc4.yaml"
check "extraA2ACallers: an entry without a namespace is refused" "[ $RC = 1 ] && grep -qi 'namespace' '$T/err'"
w xc5.yaml <<'EOF'
networkPolicy:
  enabled: false
  extraA2ACallers:
    - {namespace: fernvale-records, podLabels: {app: records}}
EOF
run "$T/xc0.yaml" "$T/xc5.yaml"
check "extraA2ACallers: another networkPolicy key beside it is still a security key and is refused" "[ $RC = 1 ] && grep -q 'networkPolicy.enabled' '$T/err'"
# the narrow rules, one refusal each (the first file has no entry, the later one adds the entry)
refuse_entry() { # refuse_entry <description> <namespace> <entry json> <part of the error> [with-rule 1|0]
  xcfile xl.yaml "$2" "$3" "${5:-1}"
  run "$T/xc0.yaml" "$T/xl.yaml"
  check "extraA2ACallers: $1: refused (exit 1, nothing on stdout, the file named)" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q 'xl.yaml' '$T/err' && grep -q -- '$4' '$T/err'" "rc=$RC $(head -c 400 "$T/err")"
}
refuse_entry "no podLabels (every pod of the namespace would be admitted)" kestrel-records '{"namespace":"kestrel-records"}' 'podLabels'
refuse_entry "empty podLabels" kestrel-records '{"namespace":"kestrel-records","podLabels":{}}' 'podLabels'
refuse_entry "podLabels that is not a map" kestrel-records '{"namespace":"kestrel-records","podLabels":"records"}' 'podLabels'
refuse_entry "an extra key (ipBlock)" kestrel-records '{"namespace":"kestrel-records","podLabels":{"app":"records"},"ipBlock":{"cidr":"0.0.0.0/0"}}' 'other than namespace and podLabels'
refuse_entry "the namespace default" default '{"namespace":"default","podLabels":{"app":"records"}}' 'platform or system namespace'
refuse_entry "the namespace kube-system" kube-system '{"namespace":"kube-system","podLabels":{"app":"x"}}' 'platform or system namespace'
refuse_entry "another kube-* namespace" kube-public '{"namespace":"kube-public","podLabels":{"app":"x"}}' 'platform or system namespace'
refuse_entry "a kube- namespace that the chart does not list" kube-extra '{"namespace":"kube-extra","podLabels":{"app":"x"}}' 'platform or system namespace'
refuse_entry "an openagentix-* namespace" openagentix-gateway '{"namespace":"openagentix-gateway","podLabels":{"app":"x"}}' 'platform or system namespace'
refuse_entry "an openagentix- namespace that the chart does not list" openagentix-anything '{"namespace":"openagentix-anything","podLabels":{"app":"x"}}' 'platform or system namespace'
refuse_entry "a namespace of the chart's own values (kagent)" kagent '{"namespace":"kagent","podLabels":{"app":"x"}}' 'platform or system namespace'
refuse_entry "no caller rule for a ServiceAccount of that namespace in the composed result" kestrel-records '{"namespace":"kestrel-records","podLabels":{"app":"records"}}' 'no caller rule' 0
w xc6.yaml <<'EOF'
governance:
  a2a:
    callers:
      - {name: other-rule, serviceAccount: {namespace: another-ns, name: x}, agents: [agent]}
EOF
run "$T/xc0.yaml" "$T/xc6.yaml" "$T/xc1.yaml"
check "extraA2ACallers: a caller rule for ANOTHER namespace does not satisfy the entry" "[ $RC = 0 ]" "$(cat "$T/err")"
xcfile xl2.yaml kestrel-records '{"namespace":"kestrel-records","podLabels":{"app":"records"}}' 0
run "$T/xc0.yaml" "$T/xc6.yaml" "$T/xl2.yaml"
check "extraA2ACallers: with a rule for another namespace only, the entry without its own rule is refused" "[ $RC = 1 ] && grep -q 'no caller rule' '$T/err'"
run "$T/xc0.yaml" "$T/xc1.yaml" "$T/xc2.yaml" "$T/xc3.yaml"
check "extraA2ACallers: refusing a bad file writes nothing even when the others are good" "[ $RC = 1 ] && [ ! -s '$T/out' ]"
# A platform namespace that an EARLIER file renames is still refused: the namespaces of the composed values count, not only the chart defaults
w xn1.yaml <<'EOF2'
kagent: {namespace: renamed-agents-ns}
EOF2
xcfile xn2.yaml renamed-agents-ns '{"namespace":"renamed-agents-ns","podLabels":{"app":"records"}}'
run "$T/xc0.yaml" "$T/xn1.yaml" "$T/xn2.yaml"
check "extraA2ACallers: a platform namespace renamed by an earlier file (kagent.namespace) is refused" "[ $RC = 1 ] && grep -q 'renamed-agents-ns' '$T/err' && grep -q 'platform or system namespace' '$T/err' && [ ! -s '$T/out' ]" "rc=$RC $(head -c 500 "$T/err")"
run "$T/xc0.yaml" "$T/xn2.yaml"
check "extraA2ACallers: the same entry without that rename composes (the check is about the renamed value)" "[ $RC = 0 ]" "$(cat "$T/err")"
# --later-wins: the checks also apply to a CHANGED existing entry
w xw1.yaml <<'EOF2'
networkPolicy:
  extraA2ACallers:
    - {namespace: kestrel-records, podLabels: {}}
EOF2
run --later-wins "$T/xc0.yaml" "$T/xc1.yaml" "$T/xw1.yaml"
check "--later-wins: a changed existing entry may not become podLabels {}" "[ $RC = 1 ] && grep -q 'podLabels' '$T/err' && grep -q 'xw1.yaml' '$T/err' && [ ! -s '$T/out' ]" "rc=$RC $(head -c 500 "$T/err")"
w xw2.yaml <<'EOF2'
networkPolicy:
  extraA2ACallers:
    - {namespace: kestrel-records, podLabels: {app: records}, ipBlock: {cidr: 0.0.0.0/0}}
EOF2
run --later-wins "$T/xc0.yaml" "$T/xc1.yaml" "$T/xw2.yaml"
check "--later-wins: a changed existing entry may not gain another key" "[ $RC = 1 ] && grep -q 'other than namespace and podLabels' '$T/err'"
run --later-wins "$T/xc0.yaml" "$T/xc1.yaml" "$T/xc3.yaml"
check "--later-wins: a narrow change of an existing entry (other pod labels) is still allowed" "[ $RC = 0 ] && out_has '.networkPolicy.extraA2ACallers[0].podLabels == {app:\"other\"}'" "$(cat "$T/err")"
# gateway.policy.budgetClasses is a list of classes named by `name` (ADR 0029, slice 5): each use case adds its own, the same name with other numbers is refused
w bc0.yaml <<'EOF2'
gateway: {models: [{name: m1}]}
EOF2
w bc1.yaml <<'EOF2'
gateway:
  policy:
    budgetClasses:
      - {name: bank-case-agent, tokens: 800000, unit: Hours, per: agent}
EOF2
w bc2.yaml <<'EOF2'
gateway:
  policy:
    budgetClasses:
      - {name: equipment-case-agent, tokens: 800000, unit: Hours, per: agent}
EOF2
w bc3.yaml <<'EOF2'
gateway:
  policy:
    budgetClasses:
      - {name: bank-case-agent, tokens: 9000000, unit: Hours, per: agent}
EOF2
run "$T/bc0.yaml" "$T/bc1.yaml"
check "budgetClasses: a class added by a later file that has no gateway.policy composes, and is reported as security relevant" "[ $RC = 0 ] && out_has '.gateway.policy.budgetClasses | map(.name) == [\"bank-case-agent\"]' && grep -q 'SECURITY-RELEVANT.*bank-case-agent' '$T/err'" "$(cat "$T/err")"
run "$T/bc0.yaml" "$T/bc1.yaml" "$T/bc2.yaml"
check "budgetClasses: two files with different classes are joined by name, in order" "[ $RC = 0 ] && out_has '.gateway.policy.budgetClasses | map(.name) == [\"bank-case-agent\",\"equipment-case-agent\"]'" "$(cat "$T/err")"
run "$T/bc0.yaml" "$T/bc1.yaml" "$T/bc1.yaml"
check "budgetClasses: the same class twice is kept once" "[ $RC = 0 ] && out_has '.gateway.policy.budgetClasses | length == 1'"
run "$T/bc0.yaml" "$T/bc1.yaml" "$T/bc3.yaml"
check "budgetClasses: the same name with other numbers is refused, naming the class and both files" "[ $RC = 1 ] && grep -q 'bank-case-agent' '$T/err' && grep -q 'bc1.yaml' '$T/err' && grep -q 'bc3.yaml' '$T/err' && [ ! -s '$T/out' ]"
run "$T/bc0.yaml" "$T/bc1.yaml" "$T/bc2.yaml" "$T/xc1.yaml"
check "budgetClasses: composes beside the other joined lists" "[ $RC = 0 ] && out_has '(.gateway.policy.budgetClasses|length) == 2 and (.networkPolicy.extraA2ACallers|length) == 1'"
w bc4.yaml <<'EOF2'
gateway:
  policy:
    tokenBudget: {tokens: 99, unit: Hours}
    budgetClasses:
      - {name: bank-case-agent, tokens: 800000, unit: Hours, per: agent}
EOF2
run "$T/bc0.yaml" "$T/bc4.yaml"
check "budgetClasses: another gateway.policy key beside them is still a security key and is refused" "[ $RC = 1 ] && grep -q 'gateway.policy.tokenBudget' '$T/err'"
sec governance.a2a.enabled 'true' 'false'
sec mcp.virtual.incomingAuth.type '"anonymous"' '"oidc"'
sec mcp.virtual.codeMode.enabled 'false' 'true'
sec mcp.egress.allow '[]' '["api.example"]'
sec observability.capture.content 'false' 'true'
sec gateway.policy.tokenBudget.tokens '1000' '9999999'
w eg1.yaml <<'EOF'
agents:
  - {name: alpha, model: m1, egress: {allow: [a.example]}}
EOF
w eg2.yaml <<'EOF'
agents:
  - {name: alpha, model: m1, egress: {allow: [a.example, b.example]}}
EOF
run "$T/eg1.yaml" "$T/eg2.yaml"
check "agents[].egress: a different egress on the same agent is refused" "[ $RC = 1 ] && grep -q 'alpha' '$T/err' && [ ! -s '$T/out' ]"
run --later-wins "$T/eg1.yaml" "$T/eg2.yaml"
check "agents[].egress with --later-wins: replaced, and reported as a security key" "[ $RC = 0 ] && out_has '.agents[0].egress.allow == [\"a.example\",\"b.example\"]' && grep -i 'security' '$T/err' | grep -q 'egress'"
w eg3.yaml <<'EOF'
agents:
  - {name: beta, model: m1, egress: {allow: [x.example]}}
EOF
run "$T/eg1.yaml" "$T/eg3.yaml"
check "a new agent with its own egress is not a change of an existing one: added and reported" "[ $RC = 0 ] && out_has '(.agents|length) == 2'"
w ns1.yaml <<'EOF'
controlPlane: {policy: {allowedModels: [a]}}
EOF
w ns2.yaml <<'EOF'
controlPlane: {policy: {allowedProfiles: [p], allowKnowledge: true}}
EOF
run "$T/ns1.yaml" "$T/ns2.yaml"
check "a security key that only the later file sets and that differs from the chart default is refused (allowedProfiles: the default is [])" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q 'allowedProfiles' '$T/err' && grep -q 'ns2.yaml' '$T/err' && grep -qi 'chart default' '$T/err'"
check "allowKnowledge: true equals the chart default: not a change, not refused" "! grep -i 'refused' '$T/err' | grep -q 'allowKnowledge'"
w ns3.yaml <<'EOF'
controlPlane: {policy: {allowedModels: [b]}}
EOF
run --later-wins "$T/ns1.yaml" "$T/ns3.yaml"
check "--later-wins does not join two allow lists either: [a] and [b] give [b]" "out_has '.controlPlane.policy.allowedModels == [\"b\"]'"
w ok1.yaml <<'EOF'
controlPlane: {policy: {maxAgents: 3}}
mcp: {virtual: {codeMode: {enabled: false}}}
EOF
w ok2.yaml <<'EOF'
controlPlane: {policy: {maxAgents: 7}}
EOF
run "$T/ok1.yaml" "$T/ok2.yaml"
check "a key that is not a security key (maxAgents) changes with a report, exit 0" "[ $RC = 0 ] && out_has '.controlPlane.policy.maxAgents == 7' && grep -q 'maxAgents' '$T/err'"
w ref1.yaml <<'EOF'
mcp: {profiles: [{name: lookup, tools: {osv: [q]}}]}
controlPlane: {policy: {allowedProfiles: [lookup], allowedModels: [m]}}
EOF
w ref2.yaml <<'EOF'
mcp: {profiles: [{name: lookup, tools: {osv: [q]}}, {name: disputes, tools: {records: [get]}}]}
EOF
run "$T/ref1.yaml" "$T/ref2.yaml"
check "a profile added by the later file does not widen controlPlane.policy.allowedProfiles by itself" "[ $RC = 0 ] && out_has '.controlPlane.policy.allowedProfiles == [\"lookup\"] and (.mcp.profiles|length) == 2'"

QS="$ROOT/components/quickstart/values.yaml"; BANK="$ROOT/examples/use-cases/bank/values.yaml"
echo "# security keys that only a later file sets are compared with the chart defaults (the chart values file is the implicit base)"
CHART_VALUES="$ROOT/charts/openagentix/values.yaml"
yq -c . "$CHART_VALUES" > "$T/chart.json"
w base.yaml <<'EOF'
unrelated: 1
EOF
# every leaf (arrays count as one leaf) of the chart defaults under a security key, as a JSON path array
jq -c --argjson pfx '["controlPlane.policy.allowedModels","controlPlane.policy.allowedProfiles","controlPlane.policy.allowedSkills","controlPlane.policy.egress","controlPlane.policy.requireToolProfile","controlPlane.policy.allowKnowledge","controlPlane.policy.allowNotify","controlPlane.policy.memory","controlPlane.policy.allowedRuntimes","controlPlane.policy.runtimes","controlPlane.containerAgents.toolProfiles","networkPolicy","governance.a2a.enabled","mcp.virtual.incomingAuth","mcp.virtual.codeMode.enabled","mcp.egress.allow","observability.capture.content","gateway.policy"]' \
  '[paths(type != "object")] | map(select(map(type) | index("number") == null)) | .[] | select((join(".")) as $d | $d != "networkPolicy.extraA2ACallers" and $d != "gateway.policy.budgetClasses" and any($pfx[]; . as $s | $d == $s or ($d | startswith($s + "."))))' "$T/chart.json" > "$T/secpaths.jsonl"
check "the chart defaults hold security keys to test (more than 40 leaves)" "[ \"\$(wc -l < '$T/secpaths.jsonl' | tr -d ' ')\" -gt 40 ]"
NSEC=0
while IFS= read -r P; do
  NSEC=$((NSEC+1)); DOT=$(jq -r 'join(".")' <<<"$P")
  jq -c --argjson p "$P" 'getpath($p) | if type=="boolean" then (. | not) elif type=="number" then (. + 1) elif type=="string" then (. + "-x") elif type=="array" then (. + ["added-by-test"]) else "x" end' "$T/chart.json" > "$T/newval.json"
  jq -c -n --argjson p "$P" --slurpfile v "$T/newval.json" 'setpath($p; $v[0])' > "$T/sec-later.json"
  run "$T/base.yaml" "$T/sec-later.json"
  check "$DOT: set only by a later file to a value other than the chart default: refused (exit 1, nothing on stdout, key and file named)" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q 'sec-later.json' '$T/err' && grep -qF '$DOT' '$T/err'" "rc=$RC $(head -c 400 "$T/err")"
  run --later-wins "$T/base.yaml" "$T/sec-later.json"
  check "$DOT: --later-wins takes it and reports a change of a security key" "[ $RC = 0 ] && out_json | jq -e --slurpfile v '$T/newval.json' 'getpath($P) == \$v[0]' >/dev/null && grep -i 'security key' '$T/err' | grep -qF '$DOT'" "rc=$RC $(head -c 400 "$T/err")"
done < "$T/secpaths.jsonl"
# the chart default itself, set by the later file, is not a change
jq -c -n --slurpfile c "$T/chart.json" '$c[0] | {networkPolicy, observability: {capture: .observability.capture}, gateway: {policy: .gateway.policy}, mcp: {virtual: {codeMode: .mcp.virtual.codeMode, incomingAuth: .mcp.virtual.incomingAuth}}, governance: {a2a: {enabled: .governance.a2a.enabled}}}' > "$T/sec-default.json"
run "$T/base.yaml" "$T/sec-default.json"
check "a later file that sets security keys to the chart defaults: exit 0, no refusal" "[ $RC = 0 ] && ! grep -qi 'refused' '$T/err'" "$(head -c 400 "$T/err")"
for pv in 'networkPolicy.enabled|false' 'observability.capture.content|true' 'mcp.virtual.incomingAuth.type|"anonymous"' 'mcp.virtual.codeMode.enabled|false' 'governance.a2a.enabled|true' 'gateway.policy.tokenBudget.tokens|99999999' 'mcp.egress.allow|["api.example"]'; do
  K=${pv%%|*}; V=${pv#*|}
  jq -c -n --arg k "$K" --argjson v "$V" 'setpath(($k|split(".")); $v)' > "$T/sec-named.json"
  run "$T/base.yaml" "$T/sec-named.json"
  check "$K = $V from a later file only: refused (named case from the review)" "[ $RC = 1 ] && grep -qF '$K' '$T/err' && [ ! -s '$T/out' ]" "rc=$RC $(head -c 300 "$T/err")"
done
check "the compose of the quick start and the bank values still exits 0 with the chart defaults as the base" "bash '$SCRIPT' '$ROOT/components/quickstart/values.yaml' '$ROOT/examples/use-cases/bank/values.yaml' >/dev/null 2>&1"
check "the first file is never compared with the chart defaults (the quick start sets allowedModels and stays)" "bash '$SCRIPT' '$ROOT/components/quickstart/values.yaml' 2>/dev/null | yq -e '.controlPlane.policy.allowedModels == [\"quickstart-model\"]' >/dev/null"

echo "# redaction: the key, every path segment, keys with dots; numbers and labels stay visible"
w r1.yaml <<'EOF'
annotations: {"my.secret.value": SENTINEL-OLD-DOT}
credentials: {user: SENTINEL-OLD-PARENT}
secretStore: {name: SENTINEL-OLD-STORE, deep: {x: SENTINEL-OLD-DEEP}}
plain: visible-old
EOF
w r2.yaml <<'EOF'
annotations: {"my.secret.value": SENTINEL-NEW-DOT}
credentials: {user: SENTINEL-NEW-PARENT}
secretStore: {name: SENTINEL-NEW-STORE, deep: {x: SENTINEL-NEW-DEEP}}
plain: visible-new
EOF
run "$T/r1.yaml" "$T/r2.yaml"
check "a key with dots that names a secret, a parent that names a credential, and a deep child of a secret store: path only" "[ $RC = 0 ] && ! grep -q 'SENTINEL' '$T/err' && grep -q 'credentials.user' '$T/err' && grep -q 'secretStore.deep.x' '$T/err'" "$(cat "$T/err")"
check "an ordinary value is still shown" "grep 'plain' '$T/err' | grep -q 'visible-old'"
w t1.yaml <<'EOF'
gateway: {policy: {tokenBudget: {tokens: 1000, unit: Hours}, apiKeyLabel: label/old-apikey}}
EOF
w t2.yaml <<'EOF'
gateway: {policy: {tokenBudget: {tokens: 2000, unit: Hours}, apiKeyLabel: label/new-apikey}}
EOF
run --later-wins "$T/t1.yaml" "$T/t2.yaml"
check "tokenBudget.tokens (a number) and apiKeyLabel (a label) are shown, not hidden" "grep 'tokenBudget.tokens' '$T/err' | grep -q '1000' && grep 'tokenBudget.tokens' '$T/err' | grep -q '2000' && grep 'apiKeyLabel' '$T/err' | grep -q 'label/old-apikey' && grep 'apiKeyLabel' '$T/err' | grep -q 'label/new-apikey'" "$(cat "$T/err")"
w t3.yaml <<'EOF'
agents:
  - {name: alpha, model: m1, secretRef: {value: SENTINEL-OLD-ENTRY}}
EOF
w t4.yaml <<'EOF'
agents:
  - {name: alpha, model: m1, secretRef: {value: SENTINEL-NEW-ENTRY}}
EOF
run --later-wins "$T/t3.yaml" "$T/t4.yaml"
check "inside a replaced list entry, a value under a secret-like parent is not shown either" "[ $RC = 0 ] && ! grep -q 'SENTINEL' '$T/err' && grep -q 'secretRef' '$T/err'" "$(cat "$T/err")"

echo "# robustness: yq stderr, --, file names, -o FILE"
mkdir -p "$T/fakebin"
printf '#!/usr/bin/env bash\necho "yq: a warning that must stay out of the data" >&2\nexec "%s" "$@"\n' "$(command -v yq)" > "$T/fakebin/yq"; chmod +x "$T/fakebin/yq"
PATH="$T/fakebin:$PATH" bash "$SCRIPT" "$T/a.yaml" > "$T/out" 2> "$T/err"; RC=$?
check "a warning that yq prints on stderr does not become data" "[ $RC = 0 ] && yq -e '.x.keep == 1' '$T/out' >/dev/null"
printf 'x: {dash: 1}\n' > "$T/-dash.yaml"
(cd "$T" && bash "$SCRIPT" -- -dash.yaml > "$T/out" 2> "$T/err"); RC=$?
check "-- ends the options: a file name that starts with a dash works" "[ $RC = 0 ] && yq -e '.x.dash == 1' '$T/out' >/dev/null" "$(cat "$T/err")"
NLF="$T/line"$'\n'"break.yaml"; printf 'x: 1\n' > "$NLF"
run "$NLF"
check "a file name with a newline is refused (exit 2) before anything is read" "[ $RC = 2 ] && [ ! -s '$T/out' ] && grep -qi 'newline' '$T/err'"
rm -f "$T/o1.yaml"
run -o "$T/o1.yaml" "$T/a.yaml" "$T/b.yaml"
check "-o FILE writes the composed values, nothing on stdout, the report still on stderr" "[ $RC = 0 ] && [ ! -s '$T/out' ] && [ -s '$T/o1.yaml' ] && yq -e '.x.over == 2' '$T/o1.yaml' >/dev/null && grep -q 'x.over' '$T/err'"
run "$T/a.yaml" "$T/b.yaml"
check "-o FILE has the same content as the standard output" "cmp -s '$T/o1.yaml' '$T/out'"
check "-o leaves no temporary file next to the output" "[ \"\$(ls -A '$T' | grep -c '^\\.compose')\" = 0 ]"
printf 'KEEP-ME\n' > "$T/o2.yaml"
run -o "$T/o2.yaml" "$T/d1.yaml" "$T/d3.yaml"
check "-o with a refusal: exit 1, the output file is not created or changed" "[ $RC = 1 ] && [ \"\$(cat '$T/o2.yaml')\" = KEEP-ME ]"
rm -f "$T/o3.yaml"; run -o "$T/o3.yaml" "$T/d1.yaml" "$T/d3.yaml"
check "-o with a refusal: no file appears" "[ $RC = 1 ] && [ ! -e '$T/o3.yaml' ] && [ \"\$(ls -A '$T' | grep -c '^\\.compose')\" = 0 ]"
run -o "$T/a.yaml" "$T/a.yaml" "$T/b.yaml"
check "-o naming an input file is refused (exit 2)" "[ $RC = 2 ] && grep -q 'a.yaml' '$T/err' && grep -q 'keep: 1' '$T/a.yaml'"
run -o
check "-o without a file name: exit 2" "[ $RC = 2 ]"
run -o "$T/nodir/o.yaml" "$T/a.yaml"
check "-o into a directory that does not exist: exit 2, no output" "[ $RC = 2 ]"

echo "# additions that matter for security are called out"
w p1.yaml <<'EOF'
mcp: {profiles: [{name: lookup, codeMode: false, tools: {osv: [q]}}]}
governance: {a2a: {callers: [{name: ask, agents: [a]}]}}
EOF
w p2.yaml <<'EOF'
mcp: {profiles: [{name: lookup, codeMode: false, tools: {osv: [q]}}, {name: scripted, codeMode: true, tools: {osv: [q]}}, {name: plain, codeMode: false, tools: {osv: [q]}}]}
governance: {a2a: {callers: [{name: ask, agents: [a]}, {name: desk, agents: [b]}]}}
EOF
run "$T/p1.yaml" "$T/p2.yaml"
check "a profile with code mode on, added by a later file, is called out as security relevant (exit 0: the ADR key list covers only mcp.virtual.codeMode.enabled)" "[ $RC = 0 ] && grep -i 'security-relevant' '$T/err' | grep -q 'scripted' && grep -i 'security-relevant' '$T/err' | grep -qi 'code mode'"
check "a profile without code mode is not called out" "! grep -i 'security-relevant' '$T/err' | grep -q 'plain'"
check "a new caller rule added by a later file is called out" "grep -i 'security-relevant' '$T/err' | grep -q 'desk'"
check "a caller rule that both files have is not called out" "! grep -i 'security-relevant' '$T/err' | grep -q 'rule ask '"
w p3.yaml <<'EOF'
mcp: {profiles: [{name: lookup, codeMode: true, tools: {osv: [q]}}]}
EOF
run --later-wins "$T/p1.yaml" "$T/p3.yaml"
check "--later-wins turning code mode on for an existing profile is called out too" "[ $RC = 0 ] && grep -i 'security-relevant' '$T/err' | grep -q 'lookup'"
run "$T/p1.yaml" "$T/p3.yaml"
check "without --later-wins that change of an existing profile is refused as a changed entry" "[ $RC = 1 ]"
run "$QS" "$BANK"
check "the bank composition calls out its new caller rule disputes-desk" "[ $RC = 0 ] && grep -i 'security-relevant' '$T/err' | grep -q 'disputes-desk'"

echo "# the quick start plus the bank values (the use case this helper is for)"
run "$QS" "$BANK"
check "they compose: exit 0, no refusal" "[ $RC = 0 ] && ! grep -qi 'refused' '$T/err'" "$(cat "$T/err")"
check "the caller the bank file restates (quickstart-ask) is kept once" "out_has '[.governance.a2a.callers[] | select(.name==\"quickstart-ask\")] | length == 1' && out_has '.governance.a2a.callers | map(.name) == [\"quickstart-ask\",\"disputes-desk\"]'"
check "the quick start's own entries stay (the osv server, the lookup profile, the quickstart-model) and the agents list holds dispute-agent" "out_has '(.mcp.servers|map(.name)) == [\"osv\"] and (.mcp.profiles|map(.name)) == [\"lookup\",\"disputes\"] and (.mcp.endpoints|map(.name)) == [\"records\"] and (.gateway.models|map(.name)) == [\"quickstart-model\"] and (.agents|map(.name)) == [\"dispute-agent\"]'"
check "the change of knowledge.enabled and of the empty agents list is in the report" "grep -q 'knowledge.enabled' '$T/err' && grep -q 'dispute-agent' '$T/err'"
check "no security key is changed by it" "! grep -qi 'security key changed' '$T/err'"
if command -v helm >/dev/null; then
  cp "$T/out" "$T/composed.yaml"
  helm template t "$ROOT/charts/openagentix" -f "$QS" -f "$BANK" --set-json 'controlPlane.apiServerCIDRs=["172.18.0.0/24"]' > "$T/direct.render" 2> "$T/direct.err"; DR=$?
  helm template t "$ROOT/charts/openagentix" -f "$T/composed.yaml" --set-json 'controlPlane.apiServerCIDRs=["172.18.0.0/24"]' > "$T/composed.render" 2> "$T/composed.err"; CR=$?
  check "the composed file renders with helm template" "[ $CR = 0 ] && [ -s '$T/composed.render' ]" "$(cat "$T/composed.err")"
  check "the render of the composed file equals the render of the two files given to helm (the same behaviour)" "[ $DR = 0 ] && cmp -s '$T/direct.render' '$T/composed.render'"
else
  echo "  skip the helm template cases: helm is not installed"
fi

echo "# mcp.virtual.ownServiceAccounts (ADR 0031): a security key that a later file may turn on and never off"
w sa-none.yaml <<'EOF'
mcp: {profiles: [{name: lookup, tools: {osv: [query_vulnerability]}}]}
EOF
w sa-on.yaml <<'EOF'
mcp: {virtual: {ownServiceAccounts: true}}
EOF
w sa-off.yaml <<'EOF'
mcp: {virtual: {ownServiceAccounts: false}}
EOF
run "$T/sa-none.yaml" "$T/sa-on.yaml"
check "a later file turns it on (no earlier file sets it; the chart default is false): composed, exit 0" "[ $RC = 0 ] && out_has '.mcp.virtual.ownServiceAccounts == true and (.mcp.profiles|length)==1'" "$(cat "$T/err")"
check "... and the report says it was turned on, with the file" "grep -q 'turned on security key mcp.virtual.ownServiceAccounts' '$T/err' && grep -q 'sa-on.yaml' '$T/err'"
run "$T/sa-off.yaml" "$T/sa-on.yaml"
check "an earlier file false and a later file true: composed true, reported" "[ $RC = 0 ] && out_has '.mcp.virtual.ownServiceAccounts == true' && grep -q 'turned on security key' '$T/err'" "$(cat "$T/err")"
run "$T/sa-on.yaml" "$T/sa-off.yaml"
check "an earlier file true and a later file false: refused, exit 1, nothing written" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q 'turns security key mcp.virtual.ownServiceAccounts off' '$T/err'" "$(cat "$T/err")"
check "... the refusal names both files and says on, never off" "grep -q 'sa-on.yaml' '$T/err' && grep -q 'sa-off.yaml' '$T/err' && grep -q 'turn it on, never off' '$T/err'"
run --later-wins "$T/sa-on.yaml" "$T/sa-off.yaml"
check "--later-wins does not turn it off either: refused, exit 1" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q 'does not change that' '$T/err'" "$(cat "$T/err")"
run "$T/sa-on.yaml" "$T/sa-none.yaml"
check "a later file that does not mention it keeps it on" "[ $RC = 0 ] && out_has '.mcp.virtual.ownServiceAccounts == true'"
run "$T/sa-on.yaml" "$T/sa-on.yaml"
check "true then true: composed, no report about it" "[ $RC = 0 ] && ! grep -q 'turned on security key' '$T/err'"
run "$T/sa-none.yaml" "$T/sa-off.yaml"
check "a later file that sets it to the chart default (false) is not a change" "[ $RC = 0 ] && ! grep -qi 'refused' '$T/err'"
w sa-str.yaml <<'EOF'
mcp: {virtual: {ownServiceAccounts: "yes"}}
EOF
run "$T/sa-none.yaml" "$T/sa-str.yaml"
check "a value that is not true (a string) from a later file is still a refused change of a security key" "[ $RC = 1 ] && grep -q 'ownServiceAccounts' '$T/err'" "$(cat "$T/err")"
w sa-vnull.yaml <<'EOF'
mcp: {virtual: null}
EOF
w sa-mcpnull.yaml <<'EOF'
mcp: null
EOF
w sa-name.yaml <<'EOF'
mcp: {virtual: {name: tools}}
EOF
for LW in "" "--later-wins"; do
  run $LW "$T/sa-on.yaml" "$T/sa-vnull.yaml" "$T/sa-name.yaml"
  check "true, then mcp.virtual: null, then mcp.virtual.name: the switch may not end off ($LW): refused, exit 1, nothing written" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q 'ownServiceAccounts' '$T/err' && grep -q 'sa-on.yaml' '$T/err'" "$(cat "$T/err")"
  run $LW "$T/sa-on.yaml" "$T/sa-mcpnull.yaml" "$T/sa-name.yaml"
  check "true, then mcp: null, then mcp.virtual.name: refused too ($LW)" "[ $RC = 1 ] && [ ! -s '$T/out' ] && grep -q 'ownServiceAccounts' '$T/err'" "$(cat "$T/err")"
  run $LW "$T/sa-on.yaml" "$T/sa-vnull.yaml"
  check "true, then mcp.virtual: null: refused too ($LW)" "[ $RC = 1 ] && [ ! -s '$T/out' ]" "$(cat "$T/err")"
done
run --later-wins "$T/sa-on.yaml" "$T/sa-vnull.yaml" "$T/sa-on.yaml"
check "true, null, true again with --later-wins: the result is on, so it composes" "[ $RC = 0 ] && out_has '.mcp.virtual.ownServiceAccounts == true'" "$(cat "$T/err")"
OWN="$ROOT/components/tools/own-service-accounts-values.yaml"
run "$QS" "$BANK" "$OWN"
check "the quick start, the bank values and the platform switch file compose: exit 0, switch on" "[ $RC = 0 ] && out_has '.mcp.virtual.ownServiceAccounts == true and (.mcp.profiles|map(.name)) == [\"lookup\",\"disputes\"]'" "$(cat "$T/err")"
run "$QS" "$OWN" "$BANK"
check "the order of the switch file in the list does not matter to the result" "[ $RC = 0 ] && out_has '.mcp.virtual.ownServiceAccounts == true'" "$(cat "$T/err")"

echo "# plain English, no personal data"
check "no em dash in the script or in this test" "! grep -l \$'\xe2\x80\x94' '$SCRIPT' '$ROOT/hack/ci/compose-values-test.sh'"
if command -v shellcheck >/dev/null; then check "shellcheck (warning level)" "shellcheck -S warning '$SCRIPT'"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
