#!/usr/bin/env bash
# Offline tests of the bank use case files: the values render over `helm template`, the manifests, the seed and the scenario file.
# No cluster, no Docker, no network. Needs: helm, jq, yq (the Python jq wrapper, as for the chart tests), python3, bash.
# Usage: examples/use-cases/bank/tests/run.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CHART="$ROOT/charts/openagentix"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
for t in helm jq yq python3; do command -v "$t" >/dev/null || { echo "ERROR: $t is required" >&2; exit 2; }; done
yq --version 2>&1 | grep -q '^yq 3\.' || { echo "ERROR: yq must be the Python wrapper (kislyuk/yq 3.x)" >&2; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
QS="$ROOT/components/quickstart/values.yaml"
VALS="$HERE/values.yaml"
helm template t "$CHART" > "$T/default.yaml" 2> "$T/default.err"; DEF_RC=$?
helm template t "$CHART" -f "$QS" > "$T/qs.yaml" 2> "$T/qs.err"; QS_RC=$?
helm template t "$CHART" -f "$QS" -f "$VALS" > "$T/bank.yaml" 2> "$T/bank.err"; BANK_RC=$?
ids() { yq -r '[.kind, (.metadata.namespace // "-"), .metadata.name] | join(" ")' "$1" | sort; }
doc() { yq -c "select(.kind==\"$2\" and .metadata.name==\"$3\")" "$1"; }

echo "# render"
check "the default chart still renders" "[ $DEF_RC = 0 ]" "$(cat "$T/default.err")"
check "the quick start still renders" "[ $QS_RC = 0 ]" "$(cat "$T/qs.err")"
check "the quick start plus the bank values render" "[ $BANK_RC = 0 ]" "$(cat "$T/bank.err")"
ids "$T/qs.yaml" > "$T/qs.ids"; ids "$T/bank.yaml" > "$T/bank.ids"
comm -13 "$T/qs.ids" "$T/bank.ids" > "$T/added.ids"; comm -23 "$T/qs.ids" "$T/bank.ids" > "$T/removed.ids"
check "the values remove no object of the quick start" "[ ! -s '$T/removed.ids' ]" "$(cat "$T/removed.ids")"
for want in "Agent kagent dispute-agent" "AgentTemplate kagent dispute-agent-template" "ModelConfig kagent gateway-dispute-agent" "Harness kagent dispute-agent-harness" \
            "CronJob openagentix-schedules deadline-sweep" "Deployment openagentix-knowledge kb" "StatefulSet openagentix-knowledge kb-postgres" "MCPServerEntry mcp-tools knowledge"; do
  check "adds: $want" "grep -qx '$want' '$T/added.ids'" "added: $(tr '\n' ';' < "$T/added.ids")"
done
check "adds nothing of the records service (it is not a chart object)" "! grep -qi 'records\|fernvale' '$T/added.ids'"
check "adds no EgressPolicy: the agent reaches the gateway and its tool path only" "! grep -q '^EgressPolicy' '$T/added.ids'"
check "adds no Secret" "! grep -q '^Secret' '$T/added.ids'"

echo "# the default render does not know the use case"
for f in default qs; do
  check "$f render: no dispute-agent, deadline-sweep, records or fernvale" "! grep -Eqi 'dispute-agent|deadline-sweep|fernvale|records-bank' '$T/$f.yaml'"
done
check "the use case files are not read by the chart (no value, template or test under charts/ names them)" "! grep -rEqi 'use-cases/bank|dispute-agent|fernvale' '$CHART'"

echo "# the agent"
doc "$T/bank.yaml" AgentTemplate dispute-agent-template > "$T/tpl.json"
# PROMPT, TOOLS, RULES and FILES are read inside the strings that `check` evaluates
# shellcheck disable=SC2034
PROMPT=$(jq -r '.spec.systemPrompt' "$T/tpl.json")
TOOLS=$(jq -r '.spec.tools[].mcp.tools[]' "$T/tpl.json")
check "the prompt names the desk agent (the scenario marker)" "printf %s \"\$PROMPT\" | grep -qi 'You are the Fernvale dispute desk agent'"
check "the prompt says a credit is never claimed as posted" "printf %s \"\$PROMPT\" | grep -q 'Never say or write that a credit was'"
check "the prompt treats customer text as untrusted and names the review phrase" "printf %s \"\$PROMPT\" | grep -q 'untrusted_' && printf %s \"\$PROMPT\" | grep -q 'needs human review'"
check "the knowledge base prompt is added" "printf %s \"\$PROMPT\" | grep -q 'knowledge_kb_search'"
check "the agent has the three graph tools" "printf '%s\n' \$TOOLS | grep -qx knowledge_kb_graph_search && printf '%s\n' \$TOOLS | grep -qx knowledge_kb_graph_paths && printf '%s\n' \$TOOLS | grep -qx knowledge_kb_graph_entity"
check "no tool of the agent could move money or send a letter" "! printf '%s\n' \$TOOLS | grep -Eq 'approve|reject|post|credit|send|execute|release|decide|ledger|fetch'"
check "no execute_tool_script (code mode) and no notify tool" "! printf '%s\n' \$TOOLS | grep -Eq 'execute_tool_script|notify'"
# every records tool the agent lists exists in the service (tools.go registers them)
grep -o 'register(d, srv, "[a-z_]*"' "$ROOT/examples/use-cases/records/internal/bank/tools.go" | sed 's/.*"\(.*\)"/\1/' | sort > "$T/service.tools"
printf '%s\n' $TOOLS | grep '^records_' | sed 's/^records_//' | sort > "$T/agent.tools"
check "every records tool of the agent is a tool of the service" "[ -s '$T/agent.tools' ] && [ -z \"\$(comm -13 '$T/service.tools' '$T/agent.tools')\" ]" "unknown: $(comm -13 "$T/service.tools" "$T/agent.tools" | tr '\n' ' ')"
check "the agent uses the shared tool server (no profile is possible yet)" "jq -e '.spec.tools[0].mcp.server.name == \"toolhive-vmcp\"' '$T/tpl.json' >/dev/null"
check "the agent has no memory and no skill" "! jq -e '.spec.skills' '$T/tpl.json' >/dev/null 2>&1 && ! printf %s \"\$PROMPT\" | grep -qi 'memory'"
check "the agent's model is the quick start model (the gateway counts its tokens)" "jq -e '.spec.modelConfig.name == \"gateway-dispute-agent\"' '$T/tpl.json' >/dev/null && doc '$T/bank.yaml' ModelConfig gateway-dispute-agent | jq -e '.spec.model == \"quickstart-model\"' >/dev/null"

echo "# the schedule and the callers"
doc "$T/bank.yaml" CronJob deadline-sweep > "$T/cj.json"
check "the sweep is a CronJob every 2 hours from 07:00 to 19:00 on working days" "jq -e '.spec.schedule == \"0 7-19/2 * * 1-5\"' '$T/cj.json' >/dev/null"
check "the sweep is suspended (no unattended run, no tokens)" "jq -e '.spec.suspend == true' '$T/cj.json' >/dev/null"
check "the sweep is not retried" "jq -e '.spec.jobTemplate.spec.backoffLimit == 0' '$T/cj.json' >/dev/null"
check "the sweep prompt is report only" "doc '$T/bank.yaml' ConfigMap schedule-deadline-sweep | jq -r '.data | tostring' | grep -qi 'deadline sweep' && doc '$T/bank.yaml' ConfigMap schedule-deadline-sweep | jq -r '.data | tostring' | grep -q 'change nothing'"
# shellcheck disable=SC2034
RULES=$(yq -r 'select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules") | .data["rules.json"]' "$T/bank.yaml")
check "the gate has a rule for the disputes desk: the dispute agent only, user ids desk:" "printf %s \"\$RULES\" | jq -e '.callers[] | select(.name==\"disputes-desk\") | (.agents==[\"kagent/dispute-agent\"] and .userId.prefix==\"desk:\")' >/dev/null"
check "the quick start caller is kept" "printf %s \"\$RULES\" | jq -e '.callers[] | select(.name==\"quickstart-ask\")' >/dev/null"
check "the sweep has its own caller rule for the dispute agent" "printf %s \"\$RULES\" | jq -e '.callers[] | select(.name==\"schedule-deadline-sweep\") | .agents==[\"kagent/dispute-agent\"]' >/dev/null"
check "no rule for a branch kiosk: the gate answers 403" "! printf %s \"\$RULES\" | grep -qi kiosk"

echo "# a tool profile for the records tools is not possible with the existing chart (pinned, so the ADR turns this red on purpose)"
printf 'mcp:\n  profiles:\n    - name: disputes\n      tools:\n        records: [get_case]\n' > "$T/profile.yaml"
helm template t "$CHART" -f "$QS" -f "$VALS" -f "$T/profile.yaml" > /dev/null 2> "$T/profile.err"; PRC=$?
check "a profile that names the backend records is refused by the chart" "[ $PRC != 0 ] && grep -q 'workload \"records\" is not a backend of the tool group' '$T/profile.err'" "rc=$PRC: $(cat "$T/profile.err")"

echo "# the records manifests"
M="$HERE/manifests/records.yaml"
DEP=$(yq -c 'select(.kind=="Deployment")' "$M")
check "one Deployment, one Service, one NetworkPolicy, one ServiceAccount, one Namespace and no Secret" "[ \"\$(yq -r .kind '$M' | sort | tr '\n' ' ')\" = 'Deployment Namespace NetworkPolicy Service ServiceAccount ' ]"
check "everything is in the namespace fernvale-records" "[ \"\$(yq -r 'select(.kind!=\"Namespace\") | .metadata.namespace' '$M' | sort -u)\" = fernvale-records ]"
check "the namespace enforces the restricted pod security level" "yq -e 'select(.kind==\"Namespace\") | .metadata.labels[\"pod-security.kubernetes.io/enforce\"] == \"restricted\"' '$M' >/dev/null"
check "non-root, no privilege escalation, read-only root, all capabilities dropped, default seccomp" "printf %s '$DEP' | jq -e '.spec.template.spec.securityContext.runAsNonRoot == true and .spec.template.spec.securityContext.seccompProfile.type == \"RuntimeDefault\" and (.spec.template.spec.containers[0].securityContext | .allowPrivilegeEscalation == false and .readOnlyRootFilesystem == true and .capabilities.drop == [\"ALL\"])' >/dev/null"
check "no service account token is mounted" "printf %s '$DEP' | jq -e '.spec.template.spec.automountServiceAccountToken == false' >/dev/null"
check "the three probes are on port 8080" "printf %s '$DEP' | jq -e '.spec.template.spec.containers[0] | [.startupProbe, .livenessProbe, .readinessProbe] | all(.httpGet.port == 8080)' >/dev/null"
check "requests 10m and 32Mi, limits 100m and 96Mi" "printf %s '$DEP' | jq -e '.spec.template.spec.containers[0].resources | .requests.cpu == \"10m\" and .requests.memory == \"32Mi\" and .limits.cpu == \"100m\" and .limits.memory == \"96Mi\"' >/dev/null"
check "REST is not opened: RECORDS_REST_ADDR is not set (the service listens on the loopback)" "! printf %s '$DEP' | jq -e '.spec.template.spec.containers[0].env[] | select(.name==\"RECORDS_REST_ADDR\")' >/dev/null 2>&1"
check "only the MCP port is declared" "printf %s '$DEP' | jq -e '[.spec.template.spec.containers[0].ports[].containerPort] == [8080]' >/dev/null"
check "the approvers come from a Secret volume, mounted read only; the data is an emptyDir with a size limit" "printf %s '$DEP' | jq -e '(.spec.template.spec.volumes | map(select(.secret.secretName==\"records-approvers\")) | length == 1) and (.spec.template.spec.volumes | map(select(.name==\"data\" and .emptyDir.sizeLimit)) | length == 1)' >/dev/null"
check "one replica with the Recreate strategy (one SQLite file)" "printf %s '$DEP' | jq -e '.spec.replicas == 1 and .spec.strategy.type == \"Recreate\"' >/dev/null"
NP=$(yq -c 'select(.kind=="NetworkPolicy")' "$M")
check "the NetworkPolicy admits only the vMCP pods of the tool group on 8080 and allows no egress" "printf %s '$NP' | jq -e '(.spec.policyTypes | sort) == [\"Egress\",\"Ingress\"] and .spec.egress == [] and (.spec.ingress | length == 1) and .spec.ingress[0].ports[0].port == 8080 and .spec.ingress[0].from[0].podSelector.matchLabels[\"app\"] == \"virtualmcpserver\"' >/dev/null"
check "the image is a placeholder that install.sh replaces" "grep -q 'image: IMAGE_PLACEHOLDER' '$M'"
check "the manifests hold no token, password or hash" "! grep -Eqi 'token_sha256|password|[0-9a-f]{64}' '$M' '$HERE/manifests/tool-registration.yaml'"
R="$HERE/manifests/tool-registration.yaml"
check "the registration is an MCPServerEntry in the group tools of mcp-tools, with the explicit unauthenticated config" "yq -e 'select(.kind==\"MCPServerEntry\") | .spec.groupRef.name == \"tools\" and .metadata.namespace == \"mcp-tools\" and .spec.remoteUrl == \"http://records.fernvale-records.svc.cluster.local:8080/mcp\"' '$R' >/dev/null && yq -e 'select(.kind==\"MCPExternalAuthConfig\") | .spec.type == \"unauthenticated\"' '$R' >/dev/null"

echo "# the knowledge base seed"
KB_DRY=$(KB_INGEST_DRY_RUN=1 "$ROOT/hack/kb-ingest.sh" "$HERE/seed/kb" fernvale-disputes 2>&1); KB_RC=$?
check "kb-ingest reads every document (dry run)" "[ $KB_RC = 0 ] && [ \"\$(printf '%s\n' \"\$KB_DRY\" | wc -l | tr -d ' ')\" = 7 ]" "$KB_DRY"
for title in "Fernvale Dispute Handling Policy" "Ficticard Scheme Dispute Rules" "Customer Text and Untrusted Input Rule" "Fernvale Provisional Credit Rule"; do
  check "a document is titled '$title' (the scenarios and the cases cite it)" "printf '%s\n' \"\$KB_DRY\" | cut -f2 | grep -qx '$title'"
done
for f in "$HERE"/seed/kb/*.md; do
  check "$(basename "$f"): says it is invented" "grep -qi 'invented' '$f'"
done
GR=$(KB_GRAPH_LOAD_DRY_RUN=1 "$ROOT/hack/kb-graph-load.sh" fernvale-disputes fernvale-bank "$HERE/seed/graph/dispute-facts.yaml" 2>&1); GR_RC=$?
check "kb-graph-load reads the facts (dry run)" "[ $GR_RC = 0 ]" "$GR"
yq -c . "$HERE/seed/graph/dispute-facts.yaml" > "$T/graph.json"
check "every relation names two entities of the file" "jq -e '([.entities[].name]) as \$n | all(.relations[]; (.source as \$s | \$n | index(\$s)) != null and (.target as \$t | \$n | index(\$t)) != null)' '$T/graph.json' >/dev/null"
check "every entity type is one the graph allows" "jq -e 'all(.entities[]; .type | IN(\"service\",\"team\",\"person\",\"system\",\"location\",\"organization\",\"product\",\"event\",\"concept\"))' '$T/graph.json' >/dev/null"
check "the graph holds the ring: five cases at one merchant on one device" "[ \"\$(jq '[.relations[] | select(.predicate==\"seen_on_device\")] | length' '$T/graph.json')\" = 5 ]"

echo "# the scenario and the evaluation set"
SC="$HERE/eval/scenario.json"
check "the scenario file is JSON with five scenarios" "[ \"\$(jq '.scenarios | length' '$SC')\" = 5 ]"
SYSRE=$(jq -r '.scenarios[0].match.system' "$SC")
check "every scenario matches the agent prompt of values.yaml (same marker)" "jq -r '.scenarios[].match.system' '$SC' | sort -u | wc -l | tr -d ' ' | grep -qx 1 && SYSRE='$SYSRE' PROMPT=\"\$PROMPT\" python3 -I -c 'import os,re,sys; sys.exit(0 if re.search(os.environ[\"SYSRE\"], os.environ[\"PROMPT\"]) else 1)'"
jq -r '.scenarios[].steps[].tool' "$SC" | sort -u > "$T/scn.tools"
check "every tool a scenario calls is a tool of the agent (by suffix)" "while read -r t; do printf '%s\n' \$TOOLS | grep -q \"_\$t\$\" || { echo \"missing \$t\"; exit 1; }; done < '$T/scn.tools'"
check "no scenario calls a tool that could move money or send a letter" "! grep -Eq 'approve|reject|post|credit|send|execute|release|decide|ledger' '$T/scn.tools'"
check "every scenario that asks for approval first sets a route and drafts a letter" "jq -e 'all(.scenarios[] | select(any(.steps[]; .tool==\"request_approval\")); ([.steps[].tool] | index(\"set_route\")) < ([.steps[].tool] | index(\"draft_letter\")) and ([.steps[].tool] | index(\"draft_letter\")) < ([.steps[].tool] | index(\"request_approval\")))' '$SC' >/dev/null"
check "request_approval is always the last step" "jq -e 'all(.scenarios[] | select(any(.steps[]; .tool==\"request_approval\")); .steps[-1].tool==\"request_approval\")' '$SC' >/dev/null"
check "the scenario file holds no URL, address, token or credential" "! grep -Eqi 'https?://|@|bearer|password|token' '$SC'"
helm template t "$CHART" -f "$QS" -f "$VALS" --set-file 'gateway.stubModel.scenarios.files.scenario\.json'="$SC" > "$T/bank-scn.yaml" 2> "$T/bank-scn.err"; SCN_RC=$?
check "the scenario file is shipped through the chart contract (ADR 0026): quick start, bank values and --set-file render" "[ $SCN_RC = 0 ]" "$(cat "$T/bank-scn.err")"
check "the chart ConfigMap stub-model-scenarios holds eval/scenario.json byte for byte" "[ \"\$(doc '$T/bank-scn.yaml' ConfigMap stub-model-scenarios | jq -j '.data[\"scenario.json\"]' | shasum -a 256 | cut -c1-64)\" = \"\$(cat '$SC' | shasum -a 256 | cut -c1-64)\" ]"
check "the stub model Deployment reads the mounted directory and rolls on a change" "doc '$T/bank-scn.yaml' Deployment stub-model | jq -e '(.spec.template.spec.containers[0].env[0].value == \"/etc/stub-model/scenarios\") and (.spec.template.metadata.annotations | has(\"openagentix.io/scenarios-checksum\"))' >/dev/null"
check "without the scenario file the bank render has no scenario ConfigMap (off by default)" "! grep -q 'stub-model-scenarios' '$T/bank.yaml'"
check "install.sh does not patch the stub model or make a scenario ConfigMap any more (it only deletes the old one on --uninstall)" "! grep -Eq 'patch deployment|create configmap' '$HERE/install.sh' && [ \"\$(grep -c 'bank-scenarios' '$HERE/install.sh')\" -le 2 ]"
check "the README ships the scenarios with STUB_SCENARIOS and says a run with them is scripted" "grep -q 'STUB_SCENARIOS=examples/use-cases/bank/eval/scenario.json' '$HERE/README.md' && grep -qi 'scripted' '$HERE/README.md'"
CS="$HERE/eval/cases.yaml"
yq -c . "$CS" > "$T/cases.json"
check "the evaluation set has the three required cases and two more" "[ \"\$(jq '.cases | length' '$T/cases.json')\" = 5 ] && jq -e '[.cases[].id] | contains([\"duplicate-charge\",\"out-of-time-declined\",\"injected-instruction-refused\"])' '$T/cases.json' >/dev/null"
check "the duplicate case checks order, approval before any credit, citing the policy" "jq -e '.cases[] | select(.id==\"duplicate-charge\") | .expect | (.tool_order | length > 3) and (.requires | length >= 1) and (.cites | length == 1) and (.state_checks | any(.url==\"/ledger\" and .count==0))' '$T/cases.json' >/dev/null"
check "every case checks the ledger is empty" "jq -e 'all(.cases[]; .expect.state_checks | any(.url==\"/ledger\" and .count==0))' '$T/cases.json' >/dev/null"
check "every cited title is a document title of the seed" "jq -r '.cases[].expect.cites[]?' '$T/cases.json' | while read -r c; do printf '%s\n' \"\$KB_DRY\" | cut -f2 | grep -qx \"\$c\" || exit 1; done"
check "the injection case expects a refusal and no approval request" "jq -e '.cases[] | select(.id==\"injected-instruction-refused\") | .expect | (.answer_must | any(test(\"not follow\"))) and (.tools_not_called | index(\"records_request_approval\") != null)' '$T/cases.json' >/dev/null"

echo "# the restated caller, the profile vMCP and the exposure limits"
check "the restated quick start caller is the whole entry of the quick start values" "[ \"\$(yq -c '.governance.a2a.callers[] | select(.name==\"quickstart-ask\")' '$QS')\" = \"\$(yq -c '.governance.a2a.callers[] | select(.name==\"quickstart-ask\")' '$VALS')\" ]"
bash "$ROOT/hack/compose-values.sh" "$QS" "$VALS" > "$T/composed.yaml" 2> "$T/composed.err"; COMP_RC=$?
check "hack/compose-values.sh composes the quick start and values.yaml, with no refusal and the restated caller kept once" "[ $COMP_RC = 0 ] && yq -e '[.governance.a2a.callers[] | select(.name==\"quickstart-ask\")] | length == 1' '$T/composed.yaml' >/dev/null" "$(cat "$T/composed.err")"
helm template t "$CHART" -f "$T/composed.yaml" > "$T/composed.render" 2> "$T/composed.render.err"; COMP_R=$?
check "the composed file renders byte for byte like the quick start plus values.yaml (the same behaviour)" "[ $COMP_R = 0 ] && cmp -s '$T/bank.yaml' '$T/composed.render'" "$(head -3 "$T/composed.render.err")"
check "the README shows the compose command" "grep -q 'hack/compose-values.sh -o /tmp/bank-values.yaml components/quickstart/values.yaml examples/use-cases/bank/values.yaml' '$HERE/README.md'"
check "the quick start has exactly the one caller that values.yaml restates (so nothing else is lost)" "[ \"\$(yq -r '.governance.a2a.callers | length' '$QS')\" = 1 ]"
check "the quick start renders the profile vMCP tools-lookup that the records policy admits" "doc '$T/qs.yaml' VirtualMCPServer tools-lookup | jq -e '.metadata.name == \"tools-lookup\"' >/dev/null && yq -e 'select(.kind==\"NetworkPolicy\") | .spec.ingress[0].from[0].podSelector.matchExpressions[0].values | index(\"tools-lookup\") != null' '$M' >/dev/null"
check "the quick start shared vMCP has code mode off (install.sh refuses it on)" "! doc '$T/qs.yaml' VirtualMCPServer tools | jq -e '.spec.config.codeMode' >/dev/null 2>&1"
check "values.yaml and the README say quick start only" "grep -qi 'quick start only' '$HERE/values.yaml' && grep -qi 'quick start only' '$HERE/README.md'"
check "values.yaml no longer tells anyone to install beside the full demo" "! grep -qi 'beside the full demo' '$HERE/values.yaml' '$HERE/README.md'"
check "the README makes no claim about kindnet enforcement" "! grep -qi 'kindnet' '$HERE/README.md' '$HERE/manifests/records.yaml'"
check "the README has the live proof checklist, all unchecked" "grep -q 'Live proof checklist' '$HERE/README.md' && [ \"\$(grep -c '^- \\[ \\]' '$HERE/README.md')\" -ge 10 ] && ! grep -q '^- \\[x\\]' '$HERE/README.md'"
check "ctl.sh asks as an analyst, not as the approver" "grep -q 'ASK_USER=desk:analyst-1' '$HERE/ctl.sh' && ! grep -q 'ASK_USER=desk:lead-1' '$HERE/ctl.sh'"

echo "# plain English and no personal data"
# shellcheck disable=SC2034
FILES=$(find "$HERE" -type f ! -path '*/tests/*' | sort)
check "no em dash anywhere in the use case" "! grep -l \$'\xe2\x80\x94' \$FILES"
check "no e-mail address, link to a real company or phone-like digit run in the seed and the scenario" "! grep -Eq '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+|[0-9]{9,}' \$(find '$HERE/seed' '$HERE/eval' -type f)"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
