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
APIS=(--set-json 'controlPlane.apiServerCIDRs=["172.18.0.0/24"]')   # install.sh finds the real ones; an endpoint needs them for the egress policy
VALS="$HERE/values.yaml"
helm template t "$CHART" > "$T/default.yaml" 2> "$T/default.err"; DEF_RC=$?
helm template t "$CHART" -f "$QS" > "$T/qs.yaml" 2> "$T/qs.err"; QS_RC=$?
helm template t "$CHART" -f "$QS" -f "$VALS" "${APIS[@]}" > "$T/bank.yaml" 2> "$T/bank.err"; BANK_RC=$?
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
            "CronJob openagentix-schedules deadline-sweep" "Deployment openagentix-knowledge kb" "StatefulSet openagentix-knowledge kb-postgres" "MCPServerEntry mcp-tools knowledge" \
            "MCPGroup mcp-tools disputes" "MCPServerEntry mcp-tools records" "MCPServerEntry mcp-tools knowledge-disputes" "VirtualMCPServer mcp-tools tools-disputes" \
            "NetworkPolicy fernvale-records openagentix-endpoint-records" "NetworkPolicy mcp-tools openagentix-vmcp-egress-disputes"; do
  check "adds: $want" "grep -qx '$want' '$T/added.ids'" "added: $(tr '\n' ';' < "$T/added.ids")"
done
check "adds of the records service only its endpoint objects: no Deployment, Service, Secret or Namespace (the service is not a chart object)" "! grep -E '^(Deployment|Service|Secret|Namespace|ServiceAccount|StatefulSet) .*(records|fernvale)' '$T/added.ids'"
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
check "the knowledge base prompt is added" "printf %s \"\$PROMPT\" | grep -q 'knowledge-disputes_kb_search'"
check "the agent has the three graph tools" "printf '%s\n' \$TOOLS | grep -qx knowledge-disputes_kb_graph_search && printf '%s\n' \$TOOLS | grep -qx knowledge-disputes_kb_graph_paths && printf '%s\n' \$TOOLS | grep -qx knowledge-disputes_kb_graph_entity"
check "no tool of the agent could move money or send a letter" "! printf '%s\n' \$TOOLS | grep -Eq 'approve|reject|post|credit|send|execute|release|decide|ledger|fetch'"
check "no execute_tool_script (code mode) and no notify tool" "! printf '%s\n' \$TOOLS | grep -Eq 'execute_tool_script|notify'"
# every records tool the agent lists exists in the service (tools.go registers them)
grep -o 'register(d, srv, "[a-z_]*"' "$ROOT/examples/use-cases/records/internal/bank/tools.go" | sed 's/.*"\(.*\)"/\1/' | sort > "$T/service.tools"
printf '%s\n' $TOOLS | grep '^records_' | sed 's/^records_//' | sort > "$T/agent.tools"
check "every records tool of the agent is a tool of the service" "[ -s '$T/agent.tools' ] && [ -z \"\$(comm -13 '$T/service.tools' '$T/agent.tools')\" ]" "unknown: $(comm -13 "$T/service.tools" "$T/agent.tools" | tr '\n' ' ')"
check "the agent is on the tool profile disputes: its only tool server is the one of that profile, not the shared one" "jq -e '[.spec.tools[].mcp.server.name] == [\"toolhive-vmcp-disputes\"]' '$T/tpl.json' >/dev/null"
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

echo "# the records endpoint, the profile and the profile's tool server (ADR 0026, slice 5)"
doc "$T/bank.yaml" MCPServerEntry records > "$T/ep.json"
check "the endpoint entry is in the group disputes, points at the records Service, and takes its header from the Secret records-mcp-auth" "jq -e '.spec.groupRef.name == \"disputes\" and .spec.remoteUrl == \"http://records.fernvale-records.svc.cluster.local:8080/mcp\" and .spec.headerForward.addHeadersFromSecret == [{\"headerName\":\"Authorization\",\"valueSecretRef\":{\"name\":\"records-mcp-auth\",\"key\":\"value\"}}]' '$T/ep.json' >/dev/null" "$(cat "$T/ep.json")"
check "the values hold no header value, token or password (only the name of a Secret)" "! grep -Eqi 'bearer [a-z0-9]|password|token_sha256' '$VALS'"
check "no bearerToken and no plaintext header anywhere in the render" "! grep -Eqi 'type: *bearerToken|addPlaintextHeaders|compositeTools|compositeToolRefs' '$T/bank.yaml'"
doc "$T/bank.yaml" VirtualMCPServer tools-disputes > "$T/vm.json"
check "the profile's tool server is on the group disputes, has no code mode, and keeps audit request and response data off" "jq -e '.spec.groupRef.name == \"disputes\" and (.spec.config | has(\"codeMode\") | not)' '$T/vm.json' >/dev/null && ! jq -e '.. | objects | select(.includeRequestData == true or .includeResponseData == true)' '$T/vm.json' >/dev/null 2>&1"
yq -c '.mcp.profiles[] | select(.name=="disputes") | .tools.records | sort' "$VALS" > "$T/profile.records"
yq -r '.mcp.profiles[] | select(.name=="disputes") | .tools | to_entries[] | .key' "$VALS" | sort | tr '\n' ' ' > "$T/profile.keys"
check "the profile lists the records tools and the knowledge tools, and nothing else" "[ \"\$(cat '$T/profile.keys')\" = 'knowledge records ' ]"
check "the profile's records tools are exactly the records tools of the agent (nothing more is offered, nothing is missing)" "[ \"\$(cat '$T/profile.records')\" = \"\$(printf '%s\n' \$TOOLS | grep '^records_' | sed 's/^records_//' | jq -R . | jq -sc 'sort')\" ]"
check "every records tool the profile lists is a tool of the service" "[ -z \"\$(jq -r '.[]' '$T/profile.records' | sort | comm -13 '$T/service.tools' -)\" ]"
check "the tool server filter of the profile names records, knowledge-disputes and nothing else" "jq -e '[.spec.config.aggregation.tools[].workload] | sort == [\"knowledge-disputes\",\"records\"]' '$T/vm.json' >/dev/null"
check "the shared tool server never names records or the header Secret" "! doc '$T/bank.yaml' VirtualMCPServer tools | jq -r 'del(.spec.incomingAuth.authzConfig) | tojson' | grep -Eq 'records|disputes'"
check "the shared tool server forbids each records tool the profile lists (a second layer)" "[ \"\$(doc '$T/bank.yaml' VirtualMCPServer tools | jq '[.spec.incomingAuth.authzConfig.inline.policies[] | select(startswith(\"forbid\") and contains(\"Tool::\\\"records_\"))] | length')\" = 15 ]"
check "no other agent and no profile of the quick start uses the group disputes" "[ \"\$(yq -r 'select(.kind==\"VirtualMCPServer\") | select(.spec.groupRef.name==\"disputes\") | .metadata.name' '$T/bank.yaml')\" = tools-disputes ]"
check "the endpoint's ingress policy admits the tool server of the group, on the pod port 8080, for the pods app=records" "doc '$T/bank.yaml' NetworkPolicy openagentix-endpoint-records | jq -e '.metadata.namespace == \"fernvale-records\" and .spec.podSelector.matchLabels == {\"app\":\"records\"} and ([.spec.ingress[].ports[].port] == [8080])' >/dev/null"
check "the profile is not opened to definitions or container agents (no allowedProfiles entry, no containerAgents list)" "! yq -e '.controlPlane.policy.allowedProfiles[]? | select(. == \"disputes\")' '$VALS' >/dev/null 2>&1 && ! yq -e '.controlPlane.containerAgents.toolProfiles' '$VALS' >/dev/null 2>&1"
check "the restated profile lookup is exactly the quick start's" "[ \"\$(yq -c '.mcp.profiles[] | select(.name==\"lookup\")' '$QS')\" = \"\$(yq -c '.mcp.profiles[] | select(.name==\"lookup\")' '$VALS')\" ]"
check "the quick start agent still reaches only its profile lookup" "! yq -r 'select(.kind==\"AgentTemplate\" and .metadata.name!=\"dispute-agent-template\") | .spec.tools[].mcp.server.name' '$T/bank.yaml' | grep -q disputes"
printf 'mcp:\n  profiles:\n    - name: disputes\n      codeMode: true\n      tools:\n        records: [get_case]\n' > "$T/codemode.yaml"
helm template t "$CHART" -f "$QS" -f "$VALS" "${APIS[@]}" -f "$T/codemode.yaml" > /dev/null 2> "$T/codemode.err"; CMRC=$?
check "code mode on the profile is refused by the chart (the profile lists write tools)" "[ $CMRC != 0 ] && grep -qi 'code mode' '$T/codemode.err'" "rc=$CMRC: $(head -3 "$T/codemode.err")"
helm template t "$CHART" -f "$QS" -f "$VALS" > /dev/null 2> "$T/noapi.err"; NARC=$?
check "without the API server addresses the render is refused (install.sh finds them)" "[ $NARC != 0 ] && grep -q 'apiServerCIDRs' '$T/noapi.err'"

echo "# the records manifests"
M="$HERE/manifests/records.yaml"
DEP=$(yq -c 'select(.kind=="Deployment")' "$M")
check "one Deployment, one Service, one NetworkPolicy, one ServiceAccount, one Namespace and no Secret (the two Secrets are made by install.sh)" "[ \"\$(yq -r .kind '$M' | sort | tr '\n' ' ')\" = 'Deployment Namespace NetworkPolicy Service ServiceAccount ' ]"
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
check "the base NetworkPolicy denies all ingress and all egress for the pod (the chart's policy openagentix-endpoint-records adds the one allowed path, so there is none before the platform is installed)" "printf %s '$NP' | jq -e '(.spec.policyTypes | sort) == [\"Egress\",\"Ingress\"] and .spec.egress == [] and .spec.ingress == [] and .spec.podSelector.matchLabels == {\"app\":\"records\"}' >/dev/null"
check "the MCP credential is read from a mounted file: RECORDS_MCP_TOKEN_FILE, a read-only Secret volume records-mcp-expected, no insecure flag" "printf %s '$DEP' | jq -e '(.spec.template.spec.containers[0].env | map(select(.name==\"RECORDS_MCP_TOKEN_FILE\")) | length == 1) and (.spec.template.spec.volumes | map(select(.secret.secretName==\"records-mcp-expected\")) | length == 1) and ([.spec.template.spec.containers[0].volumeMounts[] | select(.name==\"mcp-credential\") | .readOnly] == [true])' >/dev/null && ! grep -q 'RECORDS_MCP_INSECURE_NO_AUTH' '$M'"
check "the env value for the credential does not hold a value (only a path)" "printf %s '$DEP' | jq -r '.spec.template.spec.containers[0].env[] | select(.name==\"RECORDS_MCP_TOKEN_FILE\") | .value' | grep -q '^/etc/records-mcp/'"
check "the image is a placeholder that install.sh replaces" "grep -q 'image: IMAGE_PLACEHOLDER' '$M'"
check "the manifests hold no token, password or hash" "! grep -Eqi 'token_sha256|password|[0-9a-f]{64}' '$M'"
check "the hand-applied tool registration is gone: no file, and install.sh neither applies an MCPServerEntry nor patches anything" "[ ! -e '$HERE/manifests/tool-registration.yaml' ] && ! sed -e 's/ #.*//' -e '/^ *#/d' '$HERE/install.sh' | grep -Eq 'apply.*tool-registration|[a-z ]patch |create mcpserverentry'"

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
helm template t "$CHART" -f "$QS" -f "$VALS" --set-file 'gateway.stubModel.scenarios.files.scenario\.json'="$SC" "${APIS[@]}" > "$T/bank-scn.yaml" 2> "$T/bank-scn.err"; SCN_RC=$?
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
helm template t "$CHART" -f "$T/composed.yaml" "${APIS[@]}" > "$T/composed.render" 2> "$T/composed.render.err"; COMP_R=$?
check "the composed file renders byte for byte like the quick start plus values.yaml (the same behaviour)" "[ $COMP_R = 0 ] && cmp -s '$T/bank.yaml' '$T/composed.render'" "$(head -3 "$T/composed.render.err")"
check "the README says install.sh composes the quick start and values.yaml with hack/compose-values.sh" "grep -q 'hack/compose-values.sh' '$HERE/README.md' && grep -q 'components/quickstart/values.yaml' '$HERE/README.md'"
check "the quick start has exactly the one caller that values.yaml restates (so nothing else is lost)" "[ \"\$(yq -r '.governance.a2a.callers | length' '$QS')\" = 1 ]"
check "values.yaml and the README name the two ways to install: on its own cluster, and --beside-full-demo" "grep -q -- '--beside-full-demo' '$HERE/values.yaml' && grep -q -- '--beside-full-demo' '$HERE/README.md'"
check "the README says the egress policy is not shown to be enforced on kindnet unless the live run shows it, and what the live run did show" "grep -qi 'kindnet' '$HERE/README.md'"
check "the README has the live proof checklist, and the first real-model run list stays unchecked" "grep -q 'Live proof checklist' '$HERE/README.md' && [ \"\$(grep -c '^- \\[ \\]' '$HERE/README.md')\" -ge 8 ] && grep -q 'first real-model run' '$HERE/README.md'"
check "ctl.sh asks as an analyst, not as the approver" "grep -q 'ASK_USER=desk:analyst-1' '$HERE/ctl.sh' && ! grep -q 'ASK_USER=desk:lead-1' '$HERE/ctl.sh'"

echo "# beside the full demo (values-full-demo.yaml, composed after the values of the install you have)"
FD="$HERE/values-full-demo.yaml"
DEMO_FILES=(components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml components/observability/demo-values.yaml components/knowledge/graph-demo-values.yaml components/governance/demo-values.yaml components/governance/profiles-demo-values.yaml components/governance/memory-demo-values.yaml components/control-plane/demo-values.yaml components/console/demo-values.yaml)
DEMO_ARGS=(); : > "$T/demo.json"
for f in "${DEMO_FILES[@]}"; do DEMO_ARGS+=(-f "$ROOT/$f"); yq . "$ROOT/$f" >> "$T/demo.json"; done
jq -s 'reduce .[] as $x ({}; . * $x)' "$T/demo.json" > "$T/demo-merged.yaml"
API_V=(--api-versions agentkourier.dev/v1alpha1)
helm template t "$CHART" "${API_V[@]}" "${DEMO_ARGS[@]}" > "$T/demo.yaml" 2> "$T/demo.err"; DEMO_RC=$?
helm template t "$CHART" "${API_V[@]}" -f "$T/demo-merged.yaml" > "$T/demo-m.yaml" 2> "$T/demo-m.err"
check "the full demo files render, and the merged copy of them renders the same (what install.sh --beside-full-demo checks first)" "[ $DEMO_RC = 0 ] && cmp -s '$T/demo.yaml' '$T/demo-m.yaml'" "$(head -3 "$T/demo.err")"
bash "$ROOT/hack/compose-values.sh" -o "$T/beside.yaml" "$T/demo-merged.yaml" "$FD" 2> "$T/beside.err"; BE_RC=$?
check "hack/compose-values.sh composes values-full-demo.yaml after the full demo values with no refusal" "[ $BE_RC = 0 ]" "$(head -5 "$T/beside.err")"
helm template t "$CHART" "${API_V[@]}" -f "$T/beside.yaml" "${APIS[@]}" > "$T/beside-r.yaml" 2> "$T/beside-r.err"; BR_RC=$?
check "the composed values render" "[ $BR_RC = 0 ]" "$(head -3 "$T/beside-r.err")"
ids "$T/demo.yaml" > "$T/demo.ids"; ids "$T/beside-r.yaml" > "$T/beside.ids"
check "the composed values remove no object of the full demo" "[ -z \"\$(comm -23 '$T/demo.ids' '$T/beside.ids')\" ]" "$(comm -23 "$T/demo.ids" "$T/beside.ids" | head -5 | tr '\n' ';')"
for want in "Agent kagent dispute-agent" "MCPGroup mcp-tools disputes" "MCPServerEntry mcp-tools records" "VirtualMCPServer mcp-tools tools-disputes" "NetworkPolicy fernvale-records openagentix-endpoint-records" "CronJob openagentix-schedules deadline-sweep"; do
  check "beside the full demo it adds: $want" "comm -13 '$T/demo.ids' '$T/beside.ids' | grep -qx '$want'" "added: $(comm -13 "$T/demo.ids" "$T/beside.ids" | head -30 | tr '\n' ';')"
done
check "beside the full demo the agent uses the full demo's model name claude-haiku" "doc '$T/beside-r.yaml' ModelConfig gateway-dispute-agent | jq -e '.spec.model == \"claude-haiku\"' >/dev/null"
check "values-full-demo.yaml holds the same agent prompt as values.yaml (a test compares them)" "[ \"\$(yq -r '.agents[] | select(.name==\"dispute-agent\") | .systemPrompt' '$FD')\" = \"\$(yq -r '.agents[] | select(.name==\"dispute-agent\") | .systemPrompt' '$VALS')\" ]"
check "values-full-demo.yaml holds the same endpoint, profile and caller as values.yaml" "[ \"\$(yq -c '[.mcp.endpoints, (.mcp.profiles[]|select(.name==\"disputes\")), (.governance.a2a.callers[]|select(.name==\"disputes-desk\"))]' '$FD')\" = \"\$(yq -c '[.mcp.endpoints, (.mcp.profiles[]|select(.name==\"disputes\")), (.governance.a2a.callers[]|select(.name==\"disputes-desk\"))]' '$VALS')\" ]"
check "values-full-demo.yaml sets no security key: no allow list, no network policy switch, no code mode, no capture" "! yq -e '.controlPlane or .networkPolicy or .mcp.virtual or .observability or .gateway' '$FD' >/dev/null 2>&1"
check "beside the full demo the shared tool server (with its code mode) never names records" "! doc '$T/beside-r.yaml' VirtualMCPServer tools | jq -r 'del(.spec.incomingAuth.authzConfig) | tojson' | grep -Eq 'records|disputes'"

echo "# plain English and no personal data"
# shellcheck disable=SC2034
FILES=$(find "$HERE" -type f ! -path '*/tests/*' | sort)
check "no em dash anywhere in the use case" "! grep -l \$'\xe2\x80\x94' \$FILES"
check "no e-mail address, link to a real company or phone-like digit run in the seed and the scenario" "! grep -Eq '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+|[0-9]{9,}' \$(find '$HERE/seed' '$HERE/eval' -type f)"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
