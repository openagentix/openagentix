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
sec networkPolicy.extraA2ACallers '[]' '[{"namespace":"x"}]'
sec networkPolicy.enabled 'true' 'false'
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
check "an allow list is never joined: a security key that only the later file sets is kept, noted, and the earlier one is untouched" "[ $RC = 0 ] && out_has '.controlPlane.policy.allowedModels == [\"a\"] and .controlPlane.policy.allowedProfiles == [\"p\"]' && grep -qi 'security' '$T/err' && grep -q 'allowedProfiles' '$T/err'"
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

echo "# the quick start plus the bank values (the use case this helper is for)"
QS="$ROOT/components/quickstart/values.yaml"; BANK="$ROOT/examples/use-cases/bank/values.yaml"
run "$QS" "$BANK"
check "they compose: exit 0, no refusal" "[ $RC = 0 ] && ! grep -qi 'refused' '$T/err'" "$(cat "$T/err")"
check "the caller the bank file restates (quickstart-ask) is kept once" "out_has '[.governance.a2a.callers[] | select(.name==\"quickstart-ask\")] | length == 1' && out_has '.governance.a2a.callers | map(.name) == [\"quickstart-ask\",\"disputes-desk\"]'"
check "the quick start's own entries stay (the osv server, the lookup profile, the quickstart-model) and the agents list holds dispute-agent" "out_has '(.mcp.servers|map(.name)) == [\"osv\"] and (.mcp.profiles|map(.name)) == [\"lookup\"] and (.gateway.models|map(.name)) == [\"quickstart-model\"] and (.agents|map(.name)) == [\"dispute-agent\"]'"
check "the change of knowledge.enabled and of the empty agents list is in the report" "grep -q 'knowledge.enabled' '$T/err' && grep -q 'dispute-agent' '$T/err'"
check "no security key is changed by it" "! grep -qi 'security key changed' '$T/err'"
if command -v helm >/dev/null; then
  cp "$T/out" "$T/composed.yaml"
  helm template t "$ROOT/charts/openagentix" -f "$QS" -f "$BANK" > "$T/direct.render" 2> "$T/direct.err"; DR=$?
  helm template t "$ROOT/charts/openagentix" -f "$T/composed.yaml" > "$T/composed.render" 2> "$T/composed.err"; CR=$?
  check "the composed file renders with helm template" "[ $CR = 0 ] && [ -s '$T/composed.render' ]" "$(cat "$T/composed.err")"
  check "the render of the composed file equals the render of the two files given to helm (the same behaviour)" "[ $DR = 0 ] && cmp -s '$T/direct.render' '$T/composed.render'"
else
  echo "  skip the helm template cases: helm is not installed"
fi

echo "# plain English, no personal data"
check "no em dash in the script or in this test" "! grep -l \$'\xe2\x80\x94' '$SCRIPT' '$ROOT/hack/ci/compose-values-test.sh'"
if command -v shellcheck >/dev/null; then check "shellcheck (warning level)" "shellcheck -S warning '$SCRIPT'"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
