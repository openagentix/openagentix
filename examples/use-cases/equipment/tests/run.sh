#!/usr/bin/env bash
# Offline tests of the equipment use case files: the values render over `helm template`, the manifests, the seed, the scenario file, the evaluation set, and
# how the use case sits beside the bank use case. No cluster, no Docker, no network. Needs: helm, jq, yq (the Python jq wrapper, as for the chart tests),
# python3, bash.
# Usage: examples/use-cases/equipment/tests/run.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
CHART="$ROOT/charts/openagentix"
BANK="$ROOT/examples/use-cases/bank"
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
helm template t "$CHART" -f "$QS" -f "$VALS" "${APIS[@]}" > "$T/eq.yaml" 2> "$T/eq.err"; EQ_RC=$?
ids() { yq -r '[.kind, (.metadata.namespace // "-"), .metadata.name] | join(" ")' "$1" | sort; }
doc() { yq -c "select(.kind==\"$2\" and .metadata.name==\"$3\")" "$1"; }

echo "# render"
check "the default chart still renders" "[ $DEF_RC = 0 ]" "$(cat "$T/default.err")"
check "the quick start still renders" "[ $QS_RC = 0 ]" "$(cat "$T/qs.err")"
check "the quick start plus the equipment values render" "[ $EQ_RC = 0 ]" "$(cat "$T/eq.err")"
ids "$T/qs.yaml" > "$T/qs.ids"; ids "$T/eq.yaml" > "$T/eq.ids"
comm -13 "$T/qs.ids" "$T/eq.ids" > "$T/added.ids"; comm -23 "$T/qs.ids" "$T/eq.ids" > "$T/removed.ids"
check "the values remove no object of the quick start" "[ ! -s '$T/removed.ids' ]" "$(cat "$T/removed.ids")"
# ADR 0031: the use case turns the switch on, so every tool server names an account of the chart and has a ServiceAccount, a Role and a RoleBinding
yq -r 'select(.kind=="VirtualMCPServer")|.metadata.name+" "+(.spec.serviceAccount // "none")' "$T/eq.yaml" | sort > "$T/tsa.vmcps"
yq -r 'select(.kind=="Role" and .metadata.namespace=="mcp-tools")|.metadata.name' "$T/eq.yaml" | sort > "$T/tsa.roles"
check "the values turn mcp.virtual.ownServiceAccounts on: every tool server names the account openagentix-<name>" "[ -s '$T/tsa.vmcps' ] && ! grep -q ' none\$' '$T/tsa.vmcps' && [ \"\$(awk '{print \"openagentix-\"\$1}' '$T/tsa.vmcps')\" = \"\$(cat '$T/tsa.roles')\" ]" "$(cat "$T/tsa.vmcps") / $(cat "$T/tsa.roles")"
check "the quick start alone renders no tool server account (the switch is the use case's)" "! grep -q 'name: openagentix-tools' '$T/qs.yaml'"
for want in "Agent kagent service-agent" "AgentTemplate kagent service-agent-template" "ModelConfig kagent gateway-service-agent" "Harness kagent service-agent-harness" \
            "CronJob openagentix-schedules fleet-sweep" "Deployment openagentix-knowledge kb" "StatefulSet openagentix-knowledge kb-postgres" "MCPServerEntry mcp-tools knowledge" \
            "MCPGroup mcp-tools dealer" "MCPServerEntry mcp-tools dealer-records" "MCPServerEntry mcp-tools knowledge-dealer" "VirtualMCPServer mcp-tools tools-dealer" \
            "NetworkPolicy kestrel-records openagentix-endpoint-dealer-records" "NetworkPolicy mcp-tools openagentix-vmcp-egress-dealer"; do
  check "adds: $want" "grep -qx '$want' '$T/added.ids'" "added: $(tr '\n' ';' < "$T/added.ids")"
done
check "adds of the records service only its endpoint objects: no Deployment, Service, Secret or Namespace (the service is not a chart object)" "! grep -E '^(Deployment|Service|Secret|Namespace|ServiceAccount|StatefulSet) .*(records|kestrel)' '$T/added.ids'"
check "adds no EgressPolicy: the agent reaches the gateway and its tool path only" "! grep -q '^EgressPolicy' '$T/added.ids'"
check "adds no Secret" "! grep -q '^Secret' '$T/added.ids'"

echo "# the default render does not know the use case"
for f in default qs; do
  check "$f render: no service-agent, fleet-sweep, dealer-records or kestrel" "! grep -Eqi 'service-agent|fleet-sweep|kestrel|dealer-records|records-equipment' '$T/$f.yaml'"
done
check "the use case files are not read by the chart (no value, template or test under charts/ names them)" "! grep -rEqi 'use-cases/equipment|service-agent|kestrel' '$CHART'"

echo "# the agent"
doc "$T/eq.yaml" AgentTemplate service-agent-template > "$T/tpl.json"
# PROMPT, TOOLS, RULES and FILES are read inside the strings that `check` evaluates
# shellcheck disable=SC2034
PROMPT=$(jq -r '.spec.systemPrompt' "$T/tpl.json")
TOOLS=$(jq -r '.spec.tools[].mcp.tools[]' "$T/tpl.json")
check "the prompt names the desk agent (the scenario marker)" "printf %s \"\$PROMPT\" | grep -qi 'You are the Kestrel Valley service desk agent'"
check "the prompt says nothing is ordered, claimed, sent or confirmed by the agent" "printf %s \"\$PROMPT\" | grep -q 'Never say or write that a part was ordered'"
check "the prompt treats dealer text as untrusted, names the review phrase, and sends safety requests to a person" "printf %s \"\$PROMPT\" | grep -q 'untrusted_' && printf %s \"\$PROMPT\" | grep -q 'needs human review' && printf %s \"\$PROMPT\" | grep -q 'escalate_to_person'"
check "the prompt leaves the warranty decision to the record" "printf %s \"\$PROMPT\" | grep -q 'check_warranty'"
check "the knowledge base prompt is added" "printf %s \"\$PROMPT\" | grep -q 'knowledge-dealer_kb_search'"
check "the agent has the three graph tools" "printf '%s\n' \$TOOLS | grep -qx knowledge-dealer_kb_graph_search && printf '%s\n' \$TOOLS | grep -qx knowledge-dealer_kb_graph_paths && printf '%s\n' \$TOOLS | grep -qx knowledge-dealer_kb_graph_entity"
check "no tool of the agent could release anything (approve, reject, place, submit, send, execute, confirm, decide, fetch)" "! printf '%s\n' \$TOOLS | grep -Eq 'approve|reject|place_|submit|send|execute|release|decide|confirm|fetch'"
check "no execute_tool_script (code mode) and no notify tool" "! printf '%s\n' \$TOOLS | grep -Eq 'execute_tool_script|notify'"
# every records tool the agent lists exists in the service (tools.go registers them)
grep -o 'register(d, srv, "[a-z_]*"' "$ROOT/examples/use-cases/records/internal/equipment/tools.go" | sed 's/.*"\(.*\)"/\1/' | sort > "$T/service.tools"
printf '%s\n' $TOOLS | grep '^dealer-records_' | sed 's/^dealer-records_//' | sort > "$T/agent.tools"
check "every records tool of the agent is a tool of the service" "[ -s '$T/agent.tools' ] && [ -z \"\$(comm -13 '$T/service.tools' '$T/agent.tools')\" ]" "unknown: $(comm -13 "$T/service.tools" "$T/agent.tools" | tr '\n' ' ')"
check "the agent has 20 records tools; the only service tool it lacks is open_proactive_case (the sweep reports, it opens no case)" "[ \"\$(wc -l < '$T/agent.tools' | tr -d ' ')\" = 20 ] && [ \"\$(comm -23 '$T/service.tools' '$T/agent.tools' | tr '\n' ' ')\" = 'open_proactive_case ' ]" "missing: $(comm -23 "$T/service.tools" "$T/agent.tools" | tr '\n' ' ')"
check "the agent is on the tool profile dealer: its only tool server is the one of that profile, not the shared one" "jq -e '[.spec.tools[].mcp.server.name] == [\"toolhive-vmcp-dealer\"]' '$T/tpl.json' >/dev/null"
check "the agent has no memory and no skill" "! jq -e '.spec.skills' '$T/tpl.json' >/dev/null 2>&1 && ! printf %s \"\$PROMPT\" | grep -qi 'memory'"
check "the agent's model is the quick start model (the gateway counts its tokens)" "jq -e '.spec.modelConfig.name == \"gateway-service-agent\"' '$T/tpl.json' >/dev/null && doc '$T/eq.yaml' ModelConfig gateway-service-agent | jq -e '.spec.model == \"quickstart-model\"' >/dev/null"

echo "# the schedule and the callers"
doc "$T/eq.yaml" CronJob fleet-sweep > "$T/cj.json"
check "the sweep is a CronJob on Mondays at 05:00" "jq -e '.spec.schedule == \"0 5 * * 1\"' '$T/cj.json' >/dev/null"
check "the sweep is suspended (no unattended run, no tokens)" "jq -e '.spec.suspend == true' '$T/cj.json' >/dev/null"
check "the sweep is not retried" "jq -e '.spec.jobTemplate.spec.backoffLimit == 0' '$T/cj.json' >/dev/null"
check "the sweep prompt is report only" "doc '$T/eq.yaml' ConfigMap schedule-fleet-sweep | jq -r '.data | tostring' | grep -qi 'fleet sweep' && doc '$T/eq.yaml' ConfigMap schedule-fleet-sweep | jq -r '.data | tostring' | grep -q 'change nothing'"
# shellcheck disable=SC2034
RULES=$(yq -r 'select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules") | .data["rules.json"]' "$T/eq.yaml")
check "the gate has a rule for the service desk: the service agent only, user ids service:" "printf %s \"\$RULES\" | jq -e '.callers[] | select(.name==\"service-desk\") | (.agents==[\"kagent/service-agent\"] and .userId.prefix==\"service:\")' >/dev/null"
check "the quick start caller is kept" "printf %s \"\$RULES\" | jq -e '.callers[] | select(.name==\"quickstart-ask\")' >/dev/null"
check "the sweep has its own caller rule for the service agent" "printf %s \"\$RULES\" | jq -e '.callers[] | select(.name==\"schedule-fleet-sweep\") | .agents==[\"kagent/service-agent\"]' >/dev/null"
check "no rule for a dealer kiosk: the gate answers 403" "! printf %s \"\$RULES\" | grep -qi kiosk"

echo "# the records endpoint, the profile and the profile's tool server (ADR 0026)"
doc "$T/eq.yaml" MCPServerEntry dealer-records > "$T/ep.json"
check "the endpoint entry is in the group dealer, points at the records Service of the equipment namespace, and takes its header from the Secret dealer-records-mcp-auth" "jq -e '.spec.groupRef.name == \"dealer\" and .spec.remoteUrl == \"http://records.kestrel-records.svc.cluster.local:8080/mcp\" and .spec.headerForward.addHeadersFromSecret == [{\"headerName\":\"Authorization\",\"valueSecretRef\":{\"name\":\"dealer-records-mcp-auth\",\"key\":\"value\"}}]' '$T/ep.json' >/dev/null" "$(cat "$T/ep.json")"
check "the values hold no header value, token or password (only the name of a Secret)" "! grep -Eqi 'bearer [a-z0-9]|password|token_sha256' '$VALS'"
check "no bearerToken and no plaintext header anywhere in the render" "! grep -Eqi 'type: *bearerToken|addPlaintextHeaders|compositeTools|compositeToolRefs' '$T/eq.yaml'"
doc "$T/eq.yaml" VirtualMCPServer tools-dealer > "$T/vm.json"
check "the profile's tool server is on the group dealer, has no code mode, and keeps audit request and response data off" "jq -e '.spec.groupRef.name == \"dealer\" and (.spec.config | has(\"codeMode\") | not)' '$T/vm.json' >/dev/null && ! jq -e '.. | objects | select(.includeRequestData == true or .includeResponseData == true)' '$T/vm.json' >/dev/null 2>&1"
yq -c '.mcp.profiles[] | select(.name=="dealer") | .tools["dealer-records"] | sort' "$VALS" > "$T/profile.records"
yq -r '.mcp.profiles[] | select(.name=="dealer") | .tools | to_entries[] | .key' "$VALS" | sort | tr '\n' ' ' > "$T/profile.keys"
check "the profile lists the records tools and the knowledge tools, and nothing else" "[ \"\$(cat '$T/profile.keys')\" = 'dealer-records knowledge ' ]"
check "the profile's records tools are exactly the records tools of the agent (nothing more is offered, nothing is missing)" "[ \"\$(cat '$T/profile.records')\" = \"\$(printf '%s\n' \$TOOLS | grep '^dealer-records_' | sed 's/^dealer-records_//' | jq -R . | jq -sc 'sort')\" ]"
check "every records tool the profile lists is a tool of the service" "[ -z \"\$(jq -r '.[]' '$T/profile.records' | sort | comm -13 '$T/service.tools' -)\" ]"
check "the tool server filter of the profile names dealer-records, knowledge-dealer and nothing else" "jq -e '[.spec.config.aggregation.tools[].workload] | sort == [\"dealer-records\",\"knowledge-dealer\"]' '$T/vm.json' >/dev/null"
check "the shared tool server never names the records service, the group or the header Secret" "! doc '$T/eq.yaml' VirtualMCPServer tools | jq -r 'del(.spec.incomingAuth.authzConfig) | tojson' | grep -Eq 'dealer-records|tools-dealer|knowledge-dealer|\"dealer\"'"
check "the shared tool server forbids each records tool the profile lists (a second layer)" "[ \"\$(doc '$T/eq.yaml' VirtualMCPServer tools | jq '[.spec.incomingAuth.authzConfig.inline.policies[] | select(startswith(\"forbid\") and contains(\"Tool::\\\"dealer-records_\"))] | length')\" = 20 ]"
check "no other agent and no profile of the quick start uses the group dealer" "[ \"\$(yq -r 'select(.kind==\"VirtualMCPServer\") | select(.spec.groupRef.name==\"dealer\") | .metadata.name' '$T/eq.yaml')\" = tools-dealer ]"
check "the endpoint's ingress policy admits the tool server of the group, on the pod port 8080, for the pods app=records" "doc '$T/eq.yaml' NetworkPolicy openagentix-endpoint-dealer-records | jq -e '.metadata.namespace == \"kestrel-records\" and .spec.podSelector.matchLabels == {\"app\":\"records\"} and ([.spec.ingress[].ports[].port] == [8080])' >/dev/null"
check "the profile is not opened to definitions or container agents (no allowedProfiles entry, no containerAgents list)" "! yq -e '.controlPlane.policy.allowedProfiles[]? | select(. == \"dealer\")' '$VALS' >/dev/null 2>&1 && ! yq -e '.controlPlane.containerAgents.toolProfiles' '$VALS' >/dev/null 2>&1"
check "the restated profile lookup is exactly the quick start's" "[ \"\$(yq -c '.mcp.profiles[] | select(.name==\"lookup\")' '$QS')\" = \"\$(yq -c '.mcp.profiles[] | select(.name==\"lookup\")' '$VALS')\" ]"
check "the quick start agent still reaches only its profile lookup" "! yq -r 'select(.kind==\"AgentTemplate\" and .metadata.name!=\"service-agent-template\") | .spec.tools[].mcp.server.name' '$T/eq.yaml' | grep -q dealer"
printf 'mcp:\n  profiles:\n    - name: dealer\n      codeMode: true\n      tools:\n        dealer-records: [get_case]\n' > "$T/codemode.yaml"
helm template t "$CHART" -f "$QS" -f "$VALS" "${APIS[@]}" -f "$T/codemode.yaml" > /dev/null 2> "$T/codemode.err"; CMRC=$?
check "code mode on the profile is refused by the chart (the profile lists write tools)" "[ $CMRC != 0 ] && grep -qi 'code mode' '$T/codemode.err'" "rc=$CMRC: $(head -3 "$T/codemode.err")"
helm template t "$CHART" -f "$QS" -f "$VALS" > /dev/null 2> "$T/noapi.err"; NARC=$?
check "without the API server addresses the render is refused (install.sh finds them)" "[ $NARC != 0 ] && grep -q 'apiServerCIDRs' '$T/noapi.err'"

echo "# the records manifests"
MSRC="$HERE/manifests/records.yaml"
# the manifest as install.sh applies it: EVENTS unset (M) and EVENTS=1 (M1). The lines between the #EVENTS markers belong to one form or the other.
render_manifest() { awk -v on="$1" '/#EVENTS-ON-BEGIN/{skip=(on!=1);next} /#EVENTS-ON-END/{skip=0;next} /#EVENTS-OFF-BEGIN/{skip=(on==1);next} /#EVENTS-OFF-END/{skip=0;next} !skip{print}' "$MSRC"; }
M="$T/records-off.yaml"; render_manifest 0 > "$M"
M1="$T/records-on.yaml"; render_manifest 1 > "$M1"
DEP=$(yq -c 'select(.kind=="Deployment")' "$M")
check "one Deployment, one Service, one NetworkPolicy, one ServiceAccount, one Namespace and no Secret (the Secrets are made by install.sh)" "[ \"\$(yq -r .kind '$M' | sort | tr '\n' ' ')\" = 'Deployment Namespace NetworkPolicy Service ServiceAccount ' ]"
check "everything is in the namespace kestrel-records" "[ \"\$(yq -r 'select(.kind!=\"Namespace\") | .metadata.namespace' '$M' | sort -u)\" = kestrel-records ]"
check "the namespace enforces the restricted pod security level" "yq -e 'select(.kind==\"Namespace\") | .metadata.labels[\"pod-security.kubernetes.io/enforce\"] == \"restricted\"' '$M' >/dev/null"
check "the service runs the equipment domain" "printf %s '$DEP' | jq -e '[.spec.template.spec.containers[0].env[] | select(.name==\"RECORDS_DOMAIN\") | .value] == [\"equipment\"]' >/dev/null"
check "non-root, no privilege escalation, read-only root, all capabilities dropped, default seccomp" "printf %s '$DEP' | jq -e '.spec.template.spec.securityContext.runAsNonRoot == true and .spec.template.spec.securityContext.seccompProfile.type == \"RuntimeDefault\" and (.spec.template.spec.containers[0].securityContext | .allowPrivilegeEscalation == false and .readOnlyRootFilesystem == true and .capabilities.drop == [\"ALL\"])' >/dev/null"
check "no service account token is mounted" "printf %s '$DEP' | jq -e '.spec.template.spec.automountServiceAccountToken == false' >/dev/null"
check "the three probes are on port 8080" "printf %s '$DEP' | jq -e '.spec.template.spec.containers[0] | [.startupProbe, .livenessProbe, .readinessProbe] | all(.httpGet.port == 8080)' >/dev/null"
check "requests 10m and 32Mi, limits 100m and 96Mi" "printf %s '$DEP' | jq -e '.spec.template.spec.containers[0].resources | .requests.cpu == \"10m\" and .requests.memory == \"32Mi\" and .limits.cpu == \"100m\" and .limits.memory == \"96Mi\"' >/dev/null"
check "REST is not opened: RECORDS_REST_ADDR is not set (the service listens on the loopback)" "! printf %s '$DEP' | jq -e '.spec.template.spec.containers[0].env[] | select(.name==\"RECORDS_REST_ADDR\")' >/dev/null 2>&1"
check "only the MCP port is declared" "printf %s '$DEP' | jq -e '[.spec.template.spec.containers[0].ports[].containerPort] == [8080]' >/dev/null"
check "the approvers come from a Secret volume, mounted read only; the data is an emptyDir with a size limit" "printf %s '$DEP' | jq -e '(.spec.template.spec.volumes | map(select(.secret.secretName==\"records-approvers\")) | length == 1) and (.spec.template.spec.volumes | map(select(.name==\"data\" and .emptyDir.sizeLimit)) | length == 1)' >/dev/null"
check "one replica with the Recreate strategy (one SQLite file)" "printf %s '$DEP' | jq -e '.spec.replicas == 1 and .spec.strategy.type == \"Recreate\"' >/dev/null"
NP=$(yq -c 'select(.kind=="NetworkPolicy")' "$M")
check "the base NetworkPolicy denies all ingress and all egress for the pod (the chart's policy openagentix-endpoint-dealer-records adds the one allowed path, so there is none before the platform is installed)" "printf %s '$NP' | jq -e '(.spec.policyTypes | sort) == [\"Egress\",\"Ingress\"] and .spec.egress == [] and .spec.ingress == [] and .spec.podSelector.matchLabels == {\"app\":\"records\"}' >/dev/null"
DEP1=$(yq -c 'select(.kind=="Deployment")' "$M1")
NP1=$(yq -c 'select(.kind=="NetworkPolicy")' "$M1")
check "the manifest without the sender (EVENTS unset) has no event setting, no gate token, no marker and an empty egress" "! grep -q -e RECORDS_EVENT -e gate-token -e EVENTS- -e openagentix-a2a '$M' && printf %s '$NP' | jq -e '.spec.egress == []' >/dev/null"
check "the pod runs as the ServiceAccount records with the sender off (as before), and as records-events with it on, with no API token mounted either way" "printf %s '$DEP' | jq -e '.spec.template.spec.serviceAccountName == \"records\" and .spec.template.spec.automountServiceAccountToken == false' >/dev/null && printf %s '$DEP1' | jq -e '.spec.template.spec.serviceAccountName == \"records-events\" and .spec.template.spec.automountServiceAccountToken == false' >/dev/null && [ \"\$(yq -r 'select(.kind==\"ServiceAccount\") | .metadata.name' '$M')\" = records ] && [ \"\$(yq -r 'select(.kind==\"ServiceAccount\") | .metadata.name' '$M1')\" = records-events ]"
check "with the sender on: the gate URL names the agent service-agent, the token file is the projected one, and nothing else about events is set" "printf %s '$DEP1' | jq -e '[.spec.template.spec.containers[0].env[] | select(.name|startswith(\"RECORDS_EVENT\")) | [.name,.value]] == [[\"RECORDS_EVENT_GATE_URL\",\"http://a2a-gate.openagentix-gateway.svc.cluster.local:8080/agents/kagent/service-agent\"],[\"RECORDS_EVENT_TOKEN_FILE\",\"/var/run/records-events/token\"]]' >/dev/null"
check "with the sender on: the token is projected for the gate (audience openagentix-a2a), 600 seconds, mounted read only, and it is the only projected source" "printf %s '$DEP1' | jq -e '(.spec.template.spec.volumes | map(select(.projected)) | length == 1) and (.spec.template.spec.volumes[] | select(.name==\"gate-token\") | .projected.sources == [{\"serviceAccountToken\":{\"audience\":\"openagentix-a2a\",\"expirationSeconds\":600,\"path\":\"token\"}}]) and (.spec.template.spec.containers[0].volumeMounts[] | select(.name==\"gate-token\") | .readOnly == true and .mountPath == \"/var/run/records-events\")' >/dev/null"
check "with the sender on: egress is DNS and the gate on 8080 and nothing else; ingress stays empty" "printf %s '$NP1' | jq -e '.spec.ingress == [] and (.spec.egress | length == 2) and (.spec.egress[0].ports | map(.port) == [53,53]) and (.spec.egress[1].ports == [{\"protocol\":\"TCP\",\"port\":8080}]) and (.spec.egress[1].to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"] == \"openagentix-gateway\") and (.spec.egress[1].to[0].podSelector.matchLabels.app == \"a2a-gate\") and ([.spec.egress[].to[] | has(\"ipBlock\")] | any | not)' >/dev/null"
check "with the sender on: the container is the same as without it apart from its env and mounts (image, probes, limits, security context)" "[ \"\$(printf %s '$DEP' | jq -S -c '.spec.template.spec.containers[0]|del(.env,.volumeMounts)')\" = \"\$(printf %s '$DEP1' | jq -S -c '.spec.template.spec.containers[0]|del(.env,.volumeMounts)')\" ]"
check "the MCP credential is read from a mounted file: RECORDS_MCP_TOKEN_FILE, a read-only Secret volume records-mcp-expected, no insecure flag" "printf %s '$DEP' | jq -e '(.spec.template.spec.containers[0].env | map(select(.name==\"RECORDS_MCP_TOKEN_FILE\")) | length == 1) and (.spec.template.spec.volumes | map(select(.secret.secretName==\"records-mcp-expected\")) | length == 1) and ([.spec.template.spec.containers[0].volumeMounts[] | select(.name==\"mcp-credential\") | .readOnly] == [true])' >/dev/null && ! grep -q 'RECORDS_MCP_INSECURE_NO_AUTH' '$M'"
check "the env value for the credential does not hold a value (only a path)" "printf %s '$DEP' | jq -r '.spec.template.spec.containers[0].env[] | select(.name==\"RECORDS_MCP_TOKEN_FILE\") | .value' | grep -q '^/etc/records-mcp/'"
check "the image is a placeholder that install.sh replaces" "grep -q 'image: IMAGE_PLACEHOLDER' '$M'"
check "the manifests hold no token, password or hash" "! grep -Eqi 'token_sha256|password|[0-9a-f]{64}' '$M'"
check "the namespace and the part-of label say equipment, and differ from the bank's (two use cases never share a namespace)" "grep -q 'openagentix-use-case-equipment' '$M' && ! grep -q 'fernvale\|use-case-bank' '$M'"

echo "# the event caller (ADR 0027, slices 5 and 6)"
FD="$HERE/values-full-demo.yaml"
EVF="$HERE/values-events.yaml"
for f in "$VALS" "$FD"; do
  fb=$(basename "$f")
  check "$fb: no event caller and no namespace admitted to the gate (they are in values-events.yaml, composed only with EVENTS=1)" "yq -e '(.governance.a2a.callers // [] | map(.name) | index(\"kestrel-fault-events\")) == null and (.networkPolicy.extraA2ACallers == null)' '$f' >/dev/null"
done
for f in "$EVF"; do
  fb=$(basename "$f")
  check "$fb: the event caller kestrel-fault-events is the pod's own ServiceAccount records-events, names the chart agent service-agent, has no methods, memory, key or user id, and pins the text to a case id" "yq -e '(.governance.a2a.callers[] | select(.name==\"kestrel-fault-events\")) | .serviceAccount == {\"namespace\":\"kestrel-records\",\"name\":\"records-events\"} and .agents == [\"service-agent\"] and .event.text == \"Work case SVC-[0-9]{4}-[0-9]{4}\" and (has(\"methods\") or has(\"memory\") or has(\"key\") or has(\"userId\") | not) and .event.rate.perMinute == 4 and .event.rate.burst == 3 and .event.maxInFlight == 2' '$f' >/dev/null"
  check "$fb: only the records namespace is admitted to the gate, and only its records pods" "[ \"\$(yq -c '.networkPolicy.extraA2ACallers' '$f')\" = '[{\"namespace\":\"kestrel-records\",\"podLabels\":{\"app\":\"records\"}}]' ]"
done
check "the event caller's agent is a chart agent without long-term memory" "yq -e '(.agents[] | select(.name==\"service-agent\")) | has(\"memory\") | not' '$VALS' >/dev/null"

echo "# the knowledge base seed"
KB_DRY=$(KB_INGEST_DRY_RUN=1 "$ROOT/hack/kb-ingest.sh" "$HERE/seed/kb" kestrel-service 2>&1); KB_RC=$?
check "kb-ingest reads every document (dry run)" "[ $KB_RC = 0 ] && [ \"\$(printf '%s\n' \"\$KB_DRY\" | wc -l | tr -d ' ')\" = 9 ]" "$KB_DRY"
for title in "Kestrel Warranty Policy" "Out of Warranty and Excluded Faults" "Service Bulletin SB-2026-011 Coolant Temperature Fault E-317" "Service Bulletin SB-2026-014 Coolant Sensor Connector and Erratic Readings" \
             "Safety Procedures for Interlocks and Guards" "Dealer Notes and Untrusted Input Rule" "Parts Ordering and Supersession Rule"; do
  check "a document is titled '$title' (the scenarios and the cases cite it)" "printf '%s\n' \"\$KB_DRY\" | cut -f2 | grep -qx '$title'"
done
for f in "$HERE"/seed/kb/*.md; do
  check "$(basename "$f"): says it is invented" "grep -qi 'invented' '$f'"
done
GR=$(KB_GRAPH_LOAD_DRY_RUN=1 "$ROOT/hack/kb-graph-load.sh" kestrel-service kestrel-fleet "$HERE/seed/graph/service-facts.yaml" 2>&1); GR_RC=$?
check "kb-graph-load reads the facts (dry run)" "[ $GR_RC = 0 ]" "$GR"
yq -c . "$HERE/seed/graph/service-facts.yaml" > "$T/graph.json"
check "every relation names two entities of the file" "jq -e '([.entities[].name]) as \$n | all(.relations[]; (.source as \$s | \$n | index(\$s)) != null and (.target as \$t | \$n | index(\$t)) != null)' '$T/graph.json' >/dev/null"
check "every entity type is one the graph allows" "jq -e 'all(.entities[]; .type | IN(\"service\",\"team\",\"person\",\"system\",\"location\",\"organization\",\"product\",\"event\",\"concept\"))' '$T/graph.json' >/dev/null"
check "the graph holds the supersession: the fitted part P-10006 is superseded by P-10361" "jq -e 'any(.relations[]; .source==\"Part P-10006\" and .predicate==\"superseded_by\" and .target==\"Part P-10361\")' '$T/graph.json' >/dev/null"

echo "# the seed matches the records service (the facts the scenarios and the documents rely on)"
RS="$ROOT/examples/use-cases/records/internal/equipment/seed.go"
check "the fault code E-317 has the part P-10006, which P-10361 supersedes, and the demo machine KH4120-00317 is a combine of 14 months" "grep -q 'case 17:' '$RS' && grep -q 'P-10006' '$RS' && grep -q '\"KH4120-00317\": *{dealer: \"D-401\", months: 14' '$RS'"
check "the wear item codes of the out of warranty document are the codes the seed marks as not warrantable (every ninth code from E-309)" "grep -q 'n%9 == 0' '$RS' && grep -q 'E-309, E-318, E-327, E-336, E-345 and E-354' '$HERE/seed/kb/out-of-warranty.md'"
HARD_ORDER=$(awk '/hard := \[\]seedCase\{/{f=1;next} f&&/^\t\}/{f=0} f' "$RS" | sed -E 's/.*", "(demo|out_of_warranty|stock_nearest_out|repeat_fault|injection|safety|flapping_sensor)", "open".*/\1/' | tr '\n' ' ')
check "the seven hard cases are in the order the scenarios and the set use (0001 covered, 0002 out of warranty, 0005 injection, 0006 safety, 0007 flapping)" "[ \"$HARD_ORDER\" = 'demo out_of_warranty stock_nearest_out repeat_fault injection safety flapping_sensor ' ]" "got: $HARD_ORDER"

echo "# the scenario and the evaluation set"
SC="$HERE/eval/scenario.json"
check "the scenario file is JSON with seven scenarios" "[ \"\$(jq '.scenarios | length' '$SC')\" = 7 ]"
SYSRE=$(jq -r '.scenarios[0].match.system' "$SC")
check "every scenario matches the agent prompt of values.yaml (same marker)" "jq -r '.scenarios[].match.system' '$SC' | sort -u | wc -l | tr -d ' ' | grep -qx 1 && SYSRE='$SYSRE' PROMPT=\"\$PROMPT\" python3 -I -c 'import os,re,sys; sys.exit(0 if re.search(os.environ[\"SYSRE\"], os.environ[\"PROMPT\"]) else 1)'"
jq -r '.scenarios[].steps[].tool' "$SC" | sort -u > "$T/scn.tools"
check "every tool a scenario calls is a tool of the agent (by suffix)" "while read -r t; do printf '%s\n' \$TOOLS | grep -q \"_\$t\$\" || { echo \"missing \$t\"; exit 1; }; done < '$T/scn.tools'"
check "no scenario calls a tool that could release anything" "! grep -Eq 'approve|reject|place_|submit|send|execute|release|decide|confirm' '$T/scn.tools'"
check "every scenario that asks for approval first records the diagnosis, creates the work order, drafts the order and the notice, and holds a slot" "jq -e 'all(.scenarios[] | select(any(.steps[]; .tool==\"request_approval\")); ([.steps[].tool] | index(\"set_diagnosis\")) < ([.steps[].tool] | index(\"create_work_order\")) and ([.steps[].tool] | index(\"create_work_order\")) < ([.steps[].tool] | index(\"draft_parts_order\")) and ([.steps[].tool] | index(\"draft_parts_order\")) < ([.steps[].tool] | index(\"draft_customer_notice\")) and ([.steps[].tool] | index(\"draft_customer_notice\")) < ([.steps[].tool] | index(\"propose_slot\")) and ([.steps[].tool] | index(\"propose_slot\")) < ([.steps[].tool] | index(\"request_approval\")))' '$SC' >/dev/null"
check "request_approval is the last write of every scenario that asks for approval, and the only step after it is get_approval (the request is read back before the answer, so a superseded request is never reported as pending)" "jq -e 'all(.scenarios[] | select(any(.steps[]; .tool==\"request_approval\")); ([.steps[].tool] | index(\"request_approval\")) as \$r | (.steps | length) == \$r + 2 and .steps[-1].tool==\"get_approval\" and .steps[\$r].tool==\"request_approval\")' '$SC' >/dev/null"
check "every answer of a scenario that asks for approval says pending only when the read-back status is pending" "jq -e 'all(.scenarios[] | select(any(.steps[]; .tool==\"request_approval\")); all(.answers[] | select(.text | test(\"pending approval\")); .when | to_entries | any(.key | endswith(\"output.approval.status\"))))' '$SC' >/dev/null"
check "the prompt makes the approval request the last write, and says to read the request back before reporting it pending" "printf %s \"\$PROMPT\" | grep -q 'LAST write' && printf %s \"\$PROMPT\" | grep -q 'dealer-records_get_approval' && printf %s \"\$PROMPT\" | grep -q 'only when its status is pending'"
check "only the covered scenario drafts a claim, and it asks for the claim kind; the out of warranty scenario asks for the plain order kind" "jq -e '([.scenarios[] | select(any(.steps[]; .tool==\"draft_warranty_claim\")) | .name] == [\"equipment-covered-fault\"]) and ((.scenarios[] | select(.name==\"equipment-covered-fault\") | (.steps[]|select(.tool==\"request_approval\")|.args.kind)) == \"parts_order_with_claim\") and ((.scenarios[] | select(.name==\"equipment-out-of-warranty\") | (.steps[]|select(.tool==\"request_approval\")|.args.kind)) == \"parts_order\")' '$SC' >/dev/null"
check "a scenario that escalates (safety, injection) drafts nothing, creates no work order and asks for no approval" "jq -e 'all(.scenarios[] | select(any(.steps[]; .tool==\"escalate_to_person\")); all(.steps[]; .tool as \$t | [\"draft_parts_order\",\"draft_warranty_claim\",\"draft_customer_notice\",\"create_work_order\",\"propose_slot\",\"request_approval\",\"set_diagnosis\"] | index(\$t) | not))' '$SC' >/dev/null"
check "the safety and the injection scenarios each escalate, and the flapping scenario drafts no order" "jq -e '([.scenarios[] | select(any(.steps[]; .tool==\"escalate_to_person\")) | .name] | sort) == [\"equipment-injection-attempt\",\"equipment-safety-critical\"] and all(.scenarios[] | select(.name==\"equipment-flapping-sensor\"); all(.steps[]; .tool != \"draft_parts_order\" and .tool != \"request_approval\"))' '$SC' >/dev/null"
check "no scenario name is also a scenario name of the bank use case (the stub model refuses a name used twice, and the install beside the bank loads both files)" "[ -z \"\$(comm -12 <(jq -r '.scenarios[].name' '$SC' | sort) <(jq -r '.scenarios[].name' '$BANK/eval/scenario.json' | sort))\" ]"
check "the scenario file holds no URL, address, token or credential" "! grep -Eqi 'https?://|@|bearer|password|token' '$SC'"
helm template t "$CHART" -f "$QS" -f "$VALS" --set-file 'gateway.stubModel.scenarios.files.scenario\.json'="$SC" "${APIS[@]}" > "$T/eq-scn.yaml" 2> "$T/eq-scn.err"; SCN_RC=$?
check "the scenario file is shipped through the chart contract (ADR 0026): quick start, equipment values and --set-file render" "[ $SCN_RC = 0 ]" "$(cat "$T/eq-scn.err")"
check "the chart ConfigMap stub-model-scenarios holds eval/scenario.json byte for byte" "[ \"\$(doc '$T/eq-scn.yaml' ConfigMap stub-model-scenarios | jq -j '.data[\"scenario.json\"]' | shasum -a 256 | cut -c1-64)\" = \"\$(cat '$SC' | shasum -a 256 | cut -c1-64)\" ]"
check "without the scenario file the equipment render has no scenario ConfigMap (off by default)" "! grep -q 'stub-model-scenarios' '$T/eq.yaml'"
check "install.sh does not patch the stub model or make a scenario ConfigMap" "! grep -Eq 'patch deployment|create configmap' '$HERE/install.sh'"
check "the README ships the scenarios with STUB_SCENARIOS and says a run with them is scripted" "grep -q 'STUB_SCENARIOS=examples/use-cases/equipment/eval/scenario.json' '$HERE/README.md' && grep -qi 'scripted' '$HERE/README.md'"
CS="$HERE/eval/cases.yaml"
yq -c . "$CS" > "$T/cases.json"
check "the evaluation set has the four required kinds (covered, out of warranty, safety, injection) and three more" "[ \"\$(jq '.cases | length' '$T/cases.json')\" = 7 ] && jq -e '[.cases[].id] | contains([\"covered-fault-claim-and-order\",\"out-of-warranty-no-claim\",\"safety-critical-escalated\",\"injected-dealer-note-refused\"])' '$T/cases.json' >/dev/null"
check "the covered case checks order, approval after the warranty check and the order draft, citing the bulletin and the policy, and the kind of the request" "jq -e '.cases[] | select(.id==\"covered-fault-claim-and-order\") | .expect | (.tool_order | length > 3) and (.requires | length >= 2) and (.cites | length == 2) and (.state_checks | any(.path==\"approvals.0.kind\" and .equals==\"parts_order_with_claim\"))' '$T/cases.json' >/dev/null"
check "the out of warranty case forbids a claim draft and expects the plain order kind" "jq -e '.cases[] | select(.id==\"out-of-warranty-no-claim\") | .expect | (.tools_not_called | index(\"dealer-records_draft_warranty_claim\") != null) and (.state_checks | any(.path==\"approvals.0.kind\" and .equals==\"parts_order\"))' '$T/cases.json' >/dev/null"
check "the safety and the injection cases expect needs_person, no approval request and nothing in the outbox, and set max_tool_calls" "jq -e 'all(.cases[] | select(.id==\"safety-critical-escalated\" or .id==\"injected-dealer-note-refused\"); .expect | (.max_tool_calls > 0) and (.state_checks | any(.path==\"status\" and .equals==\"needs_person\") and any(.path==\"approvals\" and .count==0) and any(.path==\"outbox\" and .count==0)) and (.tools_not_called | index(\"dealer-records_request_approval\") != null))' '$T/cases.json' >/dev/null"
check "the injection case expects a refusal and names the rule it cites" "jq -e '.cases[] | select(.id==\"injected-dealer-note-refused\") | .expect | (.answer_must | any(test(\"not follow\"))) and (.cites == [\"Dealer Notes and Untrusted Input Rule\"])' '$T/cases.json' >/dev/null"
check "every case that works a case checks the record after the run (a state check)" "jq -e 'all(.cases[]; .expect.state_checks | length > 0)' '$T/cases.json' >/dev/null"
check "every cited title is a document title of the seed" "jq -r '.cases[].expect.cites[]?' '$T/cases.json' | while read -r c; do printf '%s\n' \"\$KB_DRY\" | cut -f2 | grep -qx \"\$c\" || exit 1; done"
check "every tool the set names is a tool of the profile (prefixed as the model sees it)" "jq -r '.cases[].expect | (.tools_called // [])[], (.tools_not_called // [])[], (.tool_order // [])[]' '$T/cases.json' | sort -u | while read -r t; do case \"\$t\" in dealer-records_*) grep -qx \"\${t#dealer-records_}\" '$T/service.tools' || { echo \"unknown \$t\"; exit 1; } ;; knowledge-dealer_*) ;; *) echo \"unprefixed \$t\"; exit 1 ;; esac; done"

echo "# the restated caller, the composition and the exposure limits"
check "the restated quick start caller is the whole entry of the quick start values" "[ \"\$(yq -c '.governance.a2a.callers[] | select(.name==\"quickstart-ask\")' '$QS')\" = \"\$(yq -c '.governance.a2a.callers[] | select(.name==\"quickstart-ask\")' '$VALS')\" ]"
bash "$ROOT/hack/compose-values.sh" "$QS" "$VALS" > "$T/composed.yaml" 2> "$T/composed.err"; COMP_RC=$?
check "hack/compose-values.sh composes the quick start and values.yaml, with no refusal and the restated caller kept once" "[ $COMP_RC = 0 ] && yq -e '[.governance.a2a.callers[] | select(.name==\"quickstart-ask\")] | length == 1' '$T/composed.yaml' >/dev/null" "$(cat "$T/composed.err")"
helm template t "$CHART" -f "$T/composed.yaml" "${APIS[@]}" > "$T/composed.render" 2> "$T/composed.render.err"; COMP_R=$?
check "the composed file renders byte for byte like the quick start plus values.yaml (the same behaviour)" "[ $COMP_R = 0 ] && cmp -s '$T/eq.yaml' '$T/composed.render'" "$(head -3 "$T/composed.render.err")"
check "the README says install.sh composes the quick start and values.yaml with hack/compose-values.sh" "grep -q 'hack/compose-values.sh' '$HERE/README.md' && grep -q 'components/quickstart/values.yaml' '$HERE/README.md'"
check "values.yaml and the README name the ways to install: on its own cluster, --beside-full-demo, and beside the bank" "grep -q -- '--beside-full-demo' '$HERE/values.yaml' && grep -q -- '--beside-full-demo' '$HERE/README.md' && grep -qi 'beside the bank' '$HERE/README.md'"
check "the README and the install script name ALSO_COMPOSE, name no flag that does not exist (--with-bank), and say that the two use cases share the knowledge base" "grep -q 'ALSO_COMPOSE' '$HERE/README.md' && grep -q 'ALSO_COMPOSE' '$HERE/install.sh' && ! grep -rq --exclude-dir=tests -- '--with-bank' '$HERE' && grep -q 'share the knowledge base' '$HERE/README.md' && ! grep -q 'share nothing' '$HERE/README.md' && grep -q 'Uninstall one of two use cases' '$HERE/README.md'"
check "the README says the egress policy is not shown to be enforced on kindnet unless the live run shows it, and what the live run did show" "grep -qi 'kindnet' '$HERE/README.md'"
check "the README has the live proof checklist, and the first real-model run list stays unchecked" "grep -q 'Live proof checklist' '$HERE/README.md' && [ \"\$(grep -c '^- \\[ \\]' '$HERE/README.md')\" -ge 8 ] && grep -q 'first real-model run' '$HERE/README.md'"
check "ctl.sh asks as a service desk user, not as the approver" "grep -q 'ASK_USER=service:desk-1' '$HERE/ctl.sh' && ! grep -q 'ASK_USER=dealer:svc-mgr-02' '$HERE/ctl.sh'"

echo "# beside the bank use case (one records deployment each; the two agents cannot call each other's tools)"
bash "$ROOT/hack/compose-values.sh" -o "$T/both.yaml" "$QS" "$BANK/values.yaml" "$VALS" 2> "$T/both.err"; BOTH_RC=$?
check "hack/compose-values.sh composes the quick start, the bank values and the equipment values with no refusal" "[ $BOTH_RC = 0 ]" "$(head -5 "$T/both.err")"
helm template t "$CHART" -f "$T/both.yaml" "${APIS[@]}" > "$T/both-r.yaml" 2> "$T/both-r.err"; BOTH_R=$?
check "the composed values render" "[ $BOTH_R = 0 ]" "$(head -3 "$T/both-r.err")"
helm template t "$CHART" -f "$QS" -f "$BANK/values.yaml" "${APIS[@]}" > "$T/bank.yaml" 2> /dev/null
ids "$T/bank.yaml" > "$T/bank.ids"; ids "$T/both-r.yaml" > "$T/both.ids"
check "with both, nothing of the quick start plus the bank is removed" "[ -z \"\$(comm -23 '$T/bank.ids' '$T/both.ids')\" ]" "$(comm -23 "$T/bank.ids" "$T/both.ids" | head -5 | tr '\n' ';')"
for want in "Agent kagent dispute-agent" "Agent kagent service-agent" "MCPGroup mcp-tools disputes" "MCPGroup mcp-tools dealer" "VirtualMCPServer mcp-tools tools-disputes" "VirtualMCPServer mcp-tools tools-dealer" \
            "NetworkPolicy fernvale-records openagentix-endpoint-records" "NetworkPolicy kestrel-records openagentix-endpoint-dealer-records"; do
  check "with both: $want" "grep -qx '$want' '$T/both.ids'" "ids: $(tr '\n' ';' < "$T/both.ids" | cut -c1-400)"
done
doc "$T/both-r.yaml" VirtualMCPServer tools-disputes | jq -r '.spec.config.aggregation.tools[].workload' | sort | tr '\n' ' ' > "$T/bank.workloads"
doc "$T/both-r.yaml" VirtualMCPServer tools-dealer | jq -r '.spec.config.aggregation.tools[].workload' | sort | tr '\n' ' ' > "$T/eq.workloads"
check "the bank's tool server lists only its own backends, and the equipment's only its own" "[ \"\$(cat '$T/bank.workloads')\" = 'knowledge-disputes records ' ] && [ \"\$(cat '$T/eq.workloads')\" = 'dealer-records knowledge-dealer ' ]"
doc "$T/both-r.yaml" AgentTemplate dispute-agent-template | jq -r '.spec.tools[].mcp.tools[]' | sort > "$T/bank.agent.tools"
doc "$T/both-r.yaml" AgentTemplate service-agent-template | jq -r '.spec.tools[].mcp.tools[]' | sort > "$T/eq.agent.tools"
check "the two agents have no tool name in common (a name is a tool, so neither can call the other's)" "[ -s '$T/bank.agent.tools' ] && [ -s '$T/eq.agent.tools' ] && [ -z \"\$(comm -12 '$T/bank.agent.tools' '$T/eq.agent.tools')\" ]"
check "the equipment agent lists no tool of the bank (no records_* and no knowledge-disputes_*), and the bank agent lists no dealer-records_* and no knowledge-dealer_*" "! grep -Eq '^(records|knowledge-disputes)_' '$T/eq.agent.tools' && ! grep -Eq '^(dealer-records|knowledge-dealer)_' '$T/bank.agent.tools'"
check "each agent is on the tool server of its own profile and no other" "doc '$T/both-r.yaml' AgentTemplate service-agent-template | jq -e '[.spec.tools[].mcp.server.name] == [\"toolhive-vmcp-dealer\"]' >/dev/null && doc '$T/both-r.yaml' AgentTemplate dispute-agent-template | jq -e '[.spec.tools[].mcp.server.name] == [\"toolhive-vmcp-disputes\"]' >/dev/null"
check "the two endpoints have different names, namespaces and header Secrets" "[ \"\$(yq -r '.mcp.endpoints[0].name' '$VALS')\" != \"\$(yq -r '.mcp.endpoints[0].name' '$BANK/values.yaml')\" ] && [ \"\$(yq -r '.mcp.endpoints[0].url' '$VALS')\" != \"\$(yq -r '.mcp.endpoints[0].url' '$BANK/values.yaml')\" ] && [ \"\$(yq -r '.mcp.endpoints[0].auth.header.secret.name' '$VALS')\" != \"\$(yq -r '.mcp.endpoints[0].auth.header.secret.name' '$BANK/values.yaml')\" ] && [ \"\$(yq -r '.mcp.endpoints[0].group' '$VALS')\" != \"\$(yq -r '.mcp.endpoints[0].group' '$BANK/values.yaml')\" ]"
check "the shared tool server forbids the tools of both use cases and names neither service" "[ \"\$(doc '$T/both-r.yaml' VirtualMCPServer tools | jq '[.spec.incomingAuth.authzConfig.inline.policies[] | select(startswith(\"forbid\"))] | length')\" -ge 35 ] && ! doc '$T/both-r.yaml' VirtualMCPServer tools | jq -r 'del(.spec.incomingAuth.authzConfig) | tojson' | grep -Eq 'records|disputes|dealer'"
check "no group, profile or agent name of the bank is reused by the equipment values (and the reverse)" "[ -z \"\$(comm -12 <(yq -r '.agents[].name, (.mcp.profiles[].name)' '$VALS' | grep -vx lookup | sort) <(yq -r '.agents[].name, (.mcp.profiles[].name)' '$BANK/values.yaml' | grep -vx lookup | sort))\" ]"

echo "# beside the full demo (values-full-demo.yaml, composed after the values of the install you have)"
FD="$HERE/values-full-demo.yaml"
DEMO_FILES=(components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml components/observability/demo-values.yaml components/knowledge/graph-demo-values.yaml components/governance/demo-values.yaml components/governance/profiles-demo-values.yaml components/governance/memory-demo-values.yaml components/control-plane/demo-values.yaml components/console/demo-values.yaml components/tools/own-service-accounts-values.yaml)
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
for want in "Agent kagent service-agent" "MCPGroup mcp-tools dealer" "MCPServerEntry mcp-tools dealer-records" "VirtualMCPServer mcp-tools tools-dealer" "NetworkPolicy kestrel-records openagentix-endpoint-dealer-records" "CronJob openagentix-schedules fleet-sweep"; do
  check "beside the full demo it adds: $want" "comm -13 '$T/demo.ids' '$T/beside.ids' | grep -qx '$want'" "added: $(comm -13 "$T/demo.ids" "$T/beside.ids" | head -30 | tr '\n' ';')"
done
check "beside the full demo the agent uses the full demo's model name claude-haiku" "doc '$T/beside-r.yaml' ModelConfig gateway-service-agent | jq -e '.spec.model == \"claude-haiku\"' >/dev/null"
check "values-full-demo.yaml holds the same agent prompt as values.yaml (a test compares them)" "[ \"\$(yq -r '.agents[] | select(.name==\"service-agent\") | .systemPrompt' '$FD')\" = \"\$(yq -r '.agents[] | select(.name==\"service-agent\") | .systemPrompt' '$VALS')\" ]"
check "values-full-demo.yaml holds the same endpoint, profile and caller as values.yaml" "[ \"\$(yq -c '[.mcp.endpoints, (.mcp.profiles[]|select(.name==\"dealer\")), (.governance.a2a.callers[]|select(.name==\"service-desk\"))]' '$FD')\" = \"\$(yq -c '[.mcp.endpoints, (.mcp.profiles[]|select(.name==\"dealer\")), (.governance.a2a.callers[]|select(.name==\"service-desk\"))]' '$VALS')\" ]"
check "values-full-demo.yaml sets no security key: no allow list, no network policy switch (only the namespace that may call the gate), no code mode, no capture" "! yq -e '.controlPlane or .mcp.virtual or .observability or .gateway or (.networkPolicy and ((.networkPolicy | keys) != ["extraA2ACallers"]))' '$FD' >/dev/null 2>&1"
check "beside the full demo the shared tool server (with its code mode) never names the records service" "! doc '$T/beside-r.yaml' VirtualMCPServer tools | jq -r 'del(.spec.incomingAuth.authzConfig) | tojson' | grep -Eq 'dealer-records|tools-dealer|knowledge-dealer|\"dealer\"'"

echo "# the full demo with both use cases beside it (ALSO_COMPOSE order: your list, the other use case, this one)"
bash "$ROOT/hack/compose-values.sh" -o "$T/three.yaml" "$T/demo-merged.yaml" "$BANK/values-full-demo.yaml" "$FD" 2> "$T/three.err"; TH_RC=$?
check "hack/compose-values.sh composes the full demo, the bank's values-full-demo.yaml and this one with no refusal" "[ $TH_RC = 0 ]" "$(head -5 "$T/three.err")"
helm template t "$CHART" "${API_V[@]}" -f "$T/three.yaml" "${APIS[@]}" > "$T/three-r.yaml" 2> "$T/three-r.err"; TH_R=$?
check "the composed values render" "[ $TH_R = 0 ]" "$(head -3 "$T/three-r.err")"
ids "$T/three-r.yaml" > "$T/three.ids"
check "they remove no object of the full demo and no object of the full demo with the bank" "[ -z \"\$(comm -23 '$T/demo.ids' '$T/three.ids')\" ]"
for want in "Agent kagent dispute-agent" "Agent kagent service-agent" "VirtualMCPServer mcp-tools tools-disputes" "VirtualMCPServer mcp-tools tools-dealer" "CronJob openagentix-schedules deadline-sweep" "CronJob openagentix-schedules fleet-sweep"; do
  check "with both beside the full demo: $want" "grep -qx '$want' '$T/three.ids'" "ids: $(tr '\n' ';' < "$T/three.ids" | cut -c1-300)"
done
check "the full demo's own agent and its code mode stay, and the shared tool server names neither use case" "doc '$T/three-r.yaml' Agent assistant >/dev/null; yq -e 'select(.kind==\"Agent\" and .metadata.name==\"assistant\")' '$T/three-r.yaml' >/dev/null && ! doc '$T/three-r.yaml' VirtualMCPServer tools | jq -r 'del(.spec.incomingAuth.authzConfig) | tojson' | grep -Eq 'dealer-records|disputes|knowledge-dealer'"

echo "# plain English and no personal data"
# shellcheck disable=SC2034
FILES=$(find "$HERE" -type f ! -path '*/tests/*' | sort)
check "no em dash anywhere in the use case" "! grep -l \$'\xe2\x80\x94' \$FILES"
check "no e-mail address, link to a real company or phone-like digit run in the seed and the scenario" "! grep -Eq '[A-Za-z0-9._-]+@[A-Za-z0-9.-]+|[0-9]{9,}' \$(find '$HERE/seed' '$HERE/eval' -type f)"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
