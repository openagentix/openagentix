#!/usr/bin/env bash
# Chart tests of ADR 0026 slice 2: mcp.endpoints[], own group mode with a header credential. Sourced by run.sh (it shares eq, q, count, docs,
# render_err, with_agents and the variables CHART, REPO). Every check here was written before the chart code and failed first (see the pull request).
echo "# endpoints (ADR 0026, slice 2): mcp.endpoints[], own tool group, header credential, off by default"
EX="$(dirname "$0")/.ep-values.yaml"
EX2="$(dirname "$0")/.ep-values2.yaml"
trap 'rm -f "$EX" "$EX2"' EXIT
cat > "$EX" <<YAML
controlPlane:
  apiServerCIDRs: [172.18.0.0/24]
notify:
  enabled: true
mcp:
  endpoints:
    - name: records
      url: http://records.records-ns.svc.cluster.local:8080/mcp
      group: disputes
      auth:
        header: {name: Authorization, secret: {name: records-mcp-auth, key: value}}
      ingress:
        podSelector: {app: records}
        port: 8080
  profiles:
    - name: disputes
      codeMode: false
      tools:
        records: [get_case, set_route]
        knowledge: [kb_search]
        delivery: [notify_send]
    - name: lookup
      codeMode: false
      tools:
        osv: [query_vulnerability]
YAML
EA=(-f "$EX")
# ev <jq filter>: the dedicated values with one edit, written to $EX2 (use -f "$EX2")
ev() { rm -f "$EX2"; yq -y "$1" "$EX" > "$EX2"; }
# er <description> <sentence part> <helm args...>: the render must fail and the error must contain the sentence part
er() { local d=$1 s=$2; shift 2; eq "$d" "$(render_err "$@" | /usr/bin/grep -cF -- "$s")" 1; }
# ok_render <description> <helm args...>: the render must succeed
okr() { local d=$1; shift; eq "$d" "$([ -z "$(render_err "$@")" ] && echo rendered || echo failed)" rendered; }

E0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
eq "endpoints defaults: none, nothing held" "$(yq -c '.mcp|[.endpoints,.endpointEntriesHeld]' "$CHART/values.yaml")" '[[],[]]'
eq "mcp.endpoints=[] and endpointEntriesHeld=[] render byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set-json 'mcp.endpoints=[]' --set-json 'mcp.endpointEntriesHeld=[]' 2>&1 | shasum -a 256)" "$E0"
eq "mcp.endpoints=null renders byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set 'mcp.endpoints=null' 2>&1 | shasum -a 256)" "$E0"
eq "the other values set, mcp.endpoints=[] and no profile listing it: byte-identical to the render without them" "$(helm template openagentix "$CHART" -n openagentix-system -f "$EX" --set-json 'mcp.endpoints=[]' --set 'mcp.profiles=null' 2>&1 | shasum -a 256)" "$(helm template openagentix "$CHART" -n openagentix-system --set notify.enabled=true --set-json 'controlPlane.apiServerCIDRs=["172.18.0.0/24"]' 2>&1 | shasum -a 256)"
DD=$(docs)
eq "default: no object of the endpoints (no group but tools, no egress policy of a group, no endpoint policy)" "$(q "$DD" '[.[]|select((.kind=="MCPGroup" and .metadata.name!="tools") or ((.metadata.name//"")|test("^openagentix-(endpoint|vmcp-egress)")))]|length')" 0

D=$(docs "${EA[@]}")
eq "on: the dedicated values render" "$([ -z "$(render_err "${EA[@]}")" ] && echo rendered || echo failed)" rendered
ENT='.[]|select(.kind=="MCPServerEntry")'
echo "# endpoints: the group, the entries, the credential"
eq "one MCPGroup per distinct group: disputes next to tools" "$(q "$D" '[.[]|select(.kind=="MCPGroup")|.metadata.namespace+"/"+.metadata.name]|sort|join(" ")')" "mcp-tools/disputes mcp-tools/tools"
eq "entries of the group: the endpoint, and knowledge and delivery named <entryName>-<group> (ADR 0026 A3, the same rule as diagnostics)" "$(q "$D" "[$ENT|select(.spec.groupRef.name==\"disputes\")|.metadata.name]|sort|join(\" \")")" "delivery-disputes knowledge-disputes records"
eq "no endpoint entry in the shared group: it keeps knowledge and delivery only" "$(q "$D" "[$ENT|select(.spec.groupRef.name==\"tools\")|.metadata.name]|sort|join(\" \")")" "delivery knowledge"
eq "the endpoint entry points at the given URL, streamable-http, private endpoint allowed (an in-cluster Service)" "$(q "$D" "$ENT|select(.metadata.name==\"records\")|[.spec.remoteUrl,.spec.transport,(.spec.allowPrivateEndpoint|tostring)]|join(\" \")")" "http://records.records-ns.svc.cluster.local:8080/mcp streamable-http true"
eq "the mirrors have the same URL as the shared entries" "$(q "$D" "[$ENT|select(.metadata.name==\"knowledge-disputes\" or .metadata.name==\"delivery-disputes\")|.spec.remoteUrl]|sort|join(\" \")")" "$(q "$D" "[$ENT|select(.metadata.name==\"knowledge\" or .metadata.name==\"delivery\")|.spec.remoteUrl]|sort|join(\" \")")"
eq "the header goes with headerForward from the Secret named in the values (in the tools namespace), next to an unauthenticated auth config" "$(q "$D" "$ENT|select(.metadata.name==\"records\")|[(.spec.headerForward|tojson),.spec.externalAuthConfigRef.name,.metadata.namespace]|join(\" \")")" '{"addHeadersFromSecret":[{"headerName":"Authorization","valueSecretRef":{"name":"records-mcp-auth","key":"value"}}]} records-noauth mcp-tools'
eq "only the endpoint entry has a header" "$(q "$D" "[$ENT|select(.spec|has(\"headerForward\"))|.metadata.name]|join(\",\")")" records
eq "every auth config is unauthenticated" "$(q "$D" '[.[]|select(.kind=="MCPExternalAuthConfig")|.spec.type]|unique|join(",")')" unauthenticated
eq "the auth configs of the group: one per entry, named <entry>-noauth" "$(q "$D" "[$ENT|select(.spec.groupRef.name==\"disputes\")|.spec.externalAuthConfigRef.name]|sort|join(\" \")")" "delivery-disputes-noauth knowledge-disputes-noauth records-noauth"
eq "bearerToken, addPlaintextHeaders, compositeTools, compositeToolRefs appear nowhere in the render" "$(printf '%s' "$D" | /usr/bin/grep -ci 'bearerToken\|addPlaintextHeaders\|compositeTool')" 0
eq "the chart renders no Secret object" "$(count "$D" '.kind=="Secret"')" 0
eq "the Secret name appears in the endpoint entry and nowhere else" "$(q "$D" '[.[]|select(tojson|test("records-mcp-auth"))|.kind+"/"+.metadata.name]|join(" ")')" "MCPServerEntry/records"

echo "# endpoints: the profile vMCP of the group, the shared vMCP, audit"
DIS='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-disputes")'
eq "profile disputes: its vMCP is on the group disputes" "$(q "$D" "$DIS|.spec.groupRef.name")" disputes
eq "profile disputes: deny by default, the filter names the endpoint and the mirrors, no more" "$(q "$D" "$DIS|[.spec.config.aggregation.defaultToolVisibility,(.spec.config.aggregation.tools|map(.workload+\":\"+(.filter|sort|join(\",\")))|join(\" \"))]|join(\" \")")" "deny delivery-disputes:notify_send knowledge-disputes:kb_search records:get_case,set_route"
eq "profile disputes: its own audience, oidc, no code mode" "$(q "$D" "$DIS|[.spec.incomingAuth.type,.spec.incomingAuth.oidcConfigRef.audience,(.spec.config|has(\"codeMode\")|tostring)]|join(\" \")")" "oidc openagentix-vmcp-disputes false"
eq "profile lookup stays on the shared group" "$(q "$D" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")|[.spec.groupRef.name,(.spec.config.aggregation.tools|tojson)]|join(" ")')" 'tools [{"workload":"osv","filter":["query_vulnerability"]}]'
eq "the shared vMCP and the shared-group profiles never reference the group or the header Secret" "$(q "$D" '[.[]|select(.kind=="VirtualMCPServer" and .spec.groupRef.name=="tools")|del(.spec.incomingAuth.authzConfig)|tojson|select(test("disputes|records|records-mcp-auth"))]|length')" 0
eq "the shared vMCP keeps its filter-free aggregation" "$(q "$D" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools")|.spec.config.aggregation|has("tools")')" false
SH='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools")'
eq "shared vMCP: a Cedar forbid for each endpoint tool a profile lists, in front of the permit" "$(q "$D" "$SH|.spec.incomingAuth.authzConfig.inline.policies|tojson")" '["forbid(principal, action == Action::\"call_tool\", resource == Tool::\"records_get_case\");","forbid(principal, action == Action::\"call_tool\", resource == Tool::\"records_set_route\");","permit(principal, action, resource);"]'
eq "shared vMCP: with toolAccess the forbids are still in front of the permits" "$(q "$(docs "${EA[@]}" --set 'mcp.virtual.incomingAuth.toolAccess[0].atespace=kagent' --set 'mcp.virtual.incomingAuth.toolAccess[0].tools={fetch_fetch}')" "$SH|.spec.incomingAuth.authzConfig.inline.policies|[(.[0:2]|map(startswith(\"forbid\"))|all|tostring),(.[2]|startswith(\"permit\")|tostring)]|join(\" \")")" "true true"
eq "profile disputes: an ALLOW LIST on the profile vMCP: permit call_tool on each of the profile's tools (as the model sees them) and list_tools, nothing else (ADR 0026 review: the profile filter covers tools only, so every other method is denied by default)" "$(q "$D" "$DIS|.spec.incomingAuth.authzConfig.inline.policies|tojson")" '["permit(principal, action == Action::\"call_tool\", resource == Tool::\"delivery-disputes_notify_send\");","permit(principal, action == Action::\"call_tool\", resource == Tool::\"knowledge-disputes_kb_search\");","permit(principal, action == Action::\"call_tool\", resource == Tool::\"records_get_case\");","permit(principal, action == Action::\"call_tool\", resource == Tool::\"records_set_route\");","permit(principal, action == Action::\"list_tools\", resource);"]'
eq "profile disputes: no forbid, no permit of every action, no permit of resources or prompts" "$(q "$D" "$DIS|.spec.incomingAuth.authzConfig.inline.policies|map(select(startswith(\"forbid\") or startswith(\"permit(principal, action, resource)\") or test(\"_resource|_prompt|resources|prompts\";\"i\")))|length")" 0
eq "profile lookup on the shared group has the same kind of allow list (tool calls and listing only)" "$(q "$D" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")|.spec.incomingAuth.authzConfig.inline.policies|tojson')" '["permit(principal, action == Action::\"call_tool\", resource == Tool::\"osv_query_vulnerability\");","permit(principal, action == Action::\"list_tools\", resource);"]'
eq "audit of the profile on the group: enabled, request and response data false" "$(q "$D" "$DIS|.spec.config.audit|[(.enabled|tostring),(.includeRequestData|tostring),(.includeResponseData|tostring)]|join(\" \")")" "true false false"
DC=$(docs "${EA[@]}" --set observability.enabled=true --set observability.bundled.enabled=true --set observability.capture.content=true)
eq "audit data stays false on the group's vMCP with observability.capture.content=true" "$(q "$DC" "$DIS|.spec.config.audit|[(.includeRequestData|tostring),(.includeResponseData|tostring)]|join(\" \")")" "false false"
eq "... while a shared-group profile follows the content switch (the control is not empty)" "$(q "$DC" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")|.spec.config.audit|[(.includeRequestData|tostring),(.includeResponseData|tostring)]|join(" ")')" "true true"
eq "no vMCP has compositeTools, a tool optimizer or a plaintext header" "$(q "$D" '[.[]|select(.kind=="VirtualMCPServer")|tojson|select(test("composite|optimizer";"i"))]|length')" 0
eq "the RemoteMCPServer of the profile exists" "$(q "$D" '[.[]|select(.kind=="RemoteMCPServer")|.metadata.name]|sort|join(" ")')" "toolhive-vmcp toolhive-vmcp-disputes toolhive-vmcp-lookup"

echo "# endpoints: network"
NPI='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-endpoint-records")'
eq "ingress policy: in the endpoint's namespace, Ingress only, selects the given pods" "$(q "$D" "$NPI|[.metadata.namespace,(.spec.policyTypes|join(\",\")),(.spec.podSelector|tojson)]|join(\" \")")" 'records-ns Ingress {"matchLabels":{"app":"records"}}'
eq "ingress policy: the given pod port, from the vMCPs of the group and nothing else" "$(q "$D" "$NPI|[(.spec.ingress|length|tostring),(.spec.ingress[0].ports|tojson),([.spec.ingress[0].from[]|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]+\"/\"+.podSelector.matchLabels.app+\"/\"+.podSelector.matchLabels[\"toolhive-name\"]]|join(\",\"))]|join(\" \")")" '1 [{"protocol":"TCP","port":8080}] mcp-tools/virtualmcpserver/tools-disputes'
eq "ingress policy: never the shared vMCP or a shared-group profile" "$(q "$D" "$NPI|[.spec.ingress[].from[].podSelector.matchLabels[\"toolhive-name\"]]|map(select(.==\"tools\" or .==\"tools-lookup\"))|length")" 0
NPE='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-egress-disputes")'
eq "egress policy: in the tools namespace, Egress only, selects the vMCPs of the group by name" "$(q "$D" "$NPE|[.metadata.namespace,(.spec.policyTypes|join(\",\")),(.spec.podSelector|tojson)]|join(\" \")")" 'mcp-tools Egress {"matchExpressions":[{"key":"toolhive-name","operator":"In","values":["tools-disputes"]}],"matchLabels":{"app":"virtualmcpserver"}}'
eq "egress policy: DNS, the endpoint pods, kb, notify, the identity provider namespace, the API server: six rules, each with a destination" "$(q "$D" "$NPE|[(.spec.egress|length|tostring),([.spec.egress[]|has(\"to\")]|all|tostring)]|join(\" \")")" "6 true"
eq "egress policy: the endpoint rule names the namespace, the pod selector and the pod port" "$(q "$D" "$NPE|.spec.egress[]|select(.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"records-ns\")|[(.to|tojson),(.ports|tojson)]|join(\" \")")" '[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"records-ns"}},"podSelector":{"matchLabels":{"app":"records"}}}] [{"protocol":"TCP","port":8080}]'
eq "egress policy: the identity provider rule names the Substrate namespace, the provider's pod labels and its pod port (values networkPolicy.substrate.idp)" "$(q "$D" "$NPE|.spec.egress[]|select(.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"ate-system\")|[(.to|tojson),(.ports|tojson)]|join(\" \")")" '[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"ate-system"}},"podSelector":{"matchLabels":{"app":"ate-idp-server"}}}] [{"protocol":"TCP","port":8443}]'
eq "networkPolicy.substrate.idp defaults: the labels and pod port of the Substrate chart 1.0.1 (ate-idp-server, 8443)" "$(yq -c '.networkPolicy.substrate.idp' "$CHART/values.yaml")" '{"podLabels":{"app":"ate-idp-server"},"port":8443}'
eq "the identity provider values are used: another label and port show in the rule" "$(q "$(docs "${EA[@]}" --set networkPolicy.substrate.idp.podLabels.app=idp --set networkPolicy.substrate.idp.port=9443)" "$NPE|.spec.egress[]|select(.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"ate-system\")|[.to[0].podSelector.matchLabels.app,(.ports[0].port|tostring)]|join(\" \")")" "idp 9443"
eq "egress policy: the API server rule uses controlPlane.apiServerCIDRs and the ports" "$(q "$D" "$NPE|.spec.egress[]|select(.to[0].ipBlock!=null)|[(.to|tojson),(.ports|map(.port)|tojson)]|join(\" \")")" '[{"ipBlock":{"cidr":"172.18.0.0/24"}}] [443,6443]'
eq "egress policy: kb and notify by namespace and pod label, port 8080 (the mirrors)" "$(q "$D" "$NPE|[.spec.egress[]|select(.to[0].podSelector.matchLabels.app==\"kb\" or .to[0].podSelector.matchLabels.app==\"notify\")|.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]+\"/\"+.to[0].podSelector.matchLabels.app+\":\"+(.ports[0].port|tostring)]|sort|join(\" \")")" "openagentix-knowledge/kb:8080 openagentix-notify/notify:8080"
eq "egress policy: no rule without a destination (no allow-all)" "$(q "$D" "$NPE|[.spec.egress[]|select(has(\"to\")|not)]|length")" 0
eq "egress policy: nothing reaches the internet (no 0.0.0.0/0 block) for an in-cluster group" "$(q "$D" "$NPE|tojson|test(\"0.0.0.0/0\")")" false
ev '.notify.enabled=false | del(.mcp.profiles[0].tools.delivery)'
DNO=$(docs -f "$EX2")
eq "without a delivery tool in the profile the notify rule and the mirror are gone" "$(q "$DNO" "[$ENT|select(.spec.groupRef.name==\"disputes\")|.metadata.name]|sort|join(\" \")")" "knowledge-disputes records"
eq "no egress policy and no endpoint policy exist for a group that is not there (lookup, tools)" "$(q "$D" '[.[]|select(.kind=="NetworkPolicy")|.metadata.name|select(test("^openagentix-vmcp-egress-"))]|join(",")')" openagentix-vmcp-egress-disputes
eq "the kb and notify ingress policies admit the profile vMCP of the group (as every profile vMCP)" "$(q "$D" '[.[]|select(.kind=="NetworkPolicy" and (.metadata.name=="kb-ingress" or .metadata.name=="notify-ingress"))|[.spec.ingress[0].from[]|.podSelector.matchLabels["toolhive-name"]]|index("tools-disputes")!=null]|all')" true
DOBS=$(docs "${EA[@]}" --set observability.enabled=true --set observability.bundled.enabled=true)
eq "with observability the egress policy also admits the telemetry endpoint (jaeger, 4318)" "$(q "$DOBS" "$NPE|[.spec.egress[]|select(.to[0].podSelector.matchLabels.app==\"jaeger\")|(.ports|tojson)]|join(\" \")")" '[{"protocol":"TCP","port":4318}]'
OBX=(--set observability.enabled=true --set observability.bundled.enabled=false)
EGN='[.spec.egress[]|(.to[0]|tojson)+" "+(.ports//[]|map(.port)|tojson)]|map(select(test("collector|203|0.0.0.0")))|join(";")'
eq "telemetry to a named collector outside the cluster: no rule at all (a policy cannot name a host, and a rule for every public address would undo the policy)" "$(q "$(docs "${EA[@]}" "${OBX[@]}" --set observability.otlp.endpoint=https://collector.example.com)" "$NPE|$EGN")" ""
eq "... and the other six rules are unchanged" "$(q "$(docs "${EA[@]}" "${OBX[@]}" --set observability.otlp.endpoint=https://collector.example.com)" "$NPE|.spec.egress|length")" 6
eq "telemetry to an address literal: that address only, the port of the URL (443 for https without a port)" "$(q "$(docs "${EA[@]}" "${OBX[@]}" --set observability.otlp.endpoint=https://203.0.113.5)" "$NPE|$EGN")" '{"ipBlock":{"cidr":"203.0.113.5/32"}} [443]'
eq "... 80 for http without a port, and an explicit port is kept" "$(q "$(docs "${EA[@]}" "${OBX[@]}" --set observability.otlp.endpoint=http://203.0.113.5)" "$NPE|$EGN")/$(q "$(docs "${EA[@]}" "${OBX[@]}" --set observability.otlp.endpoint=http://203.0.113.5:4318)" "$NPE|$EGN")" '{"ipBlock":{"cidr":"203.0.113.5/32"}} [80]/{"ipBlock":{"cidr":"203.0.113.5/32"}} [4318]'
eq "telemetry to an in-cluster collector: its namespace and port" "$(q "$(docs "${EA[@]}" "${OBX[@]}" --set observability.otlp.endpoint=http://collector.mon.svc.cluster.local:4318)" "$NPE|[.spec.egress[]|select(.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"mon\")|(.ports|map(.port)|tojson)]|join(\",\")")" "[4318]"

echo "# endpoints: the catalog and definitions"
CATP='.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|[.tools.toolhive.profiles[]|.name]|sort|join(",")'
DCP=$(docs "${EA[@]}" --set controlPlane.enabled=true)
eq "catalog: the profile with an endpoint tool is absent, the shared-group profile is there" "$(q "$DCP" "$CATP")" lookup
DCS=$(docs "${EA[@]}" --set controlPlane.enabled=true --set 'controlPlane.policy.allowedProfiles={*}')
eq "catalog with allowedProfiles [*]: still absent" "$(q "$DCS" "$CATP")" lookup
CATNS='.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.namespaces'
eq "the catalog names the namespaces of the endpoints (the guard and the controller refuse their hosts in every form, whatever the shape of the namespace name)" "$(q "$DCP" "$CATNS|.endpoints|tojson")" '["records-ns"]'
eq "the catalog has no endpoints key without an endpoint (byte-identical catalog)" "$(q "$(docs --set controlPlane.enabled=true)" "$CATNS|has(\"endpoints\")")" false
eq "the AgentTemplate guard names neither the server of the profile nor an endpoint tool" "$(q "$DCS" '[.[]|select(.kind=="ValidatingAdmissionPolicy")|tojson]|join(" ")' | /usr/bin/grep -c 'toolhive-vmcp-disputes\|records_get_case')" 0
er "naming the profile in controlPlane.policy.allowedProfiles is refused, with the fix" 'controlPlane.policy.allowedProfiles names the profile "disputes", which lists a tool of mcp.endpoints' "${EA[@]}" --set controlPlane.enabled=true --set 'controlPlane.policy.allowedProfiles={disputes}'
CAV=(--set controlPlane.enabled=true --set controlPlane.containerAgents.enabled=true --set governance.a2a.enabled=true --set 'controlPlane.policy.allowedRuntimes={builtin,container}' --set 'controlPlane.policy.runtimes.container.images={registry.local/oa/}')
er "naming the profile in containerAgents.toolProfiles is refused" 'controlPlane.containerAgents.toolProfiles names the profile "disputes"' "${EA[@]}" "${CAV[@]}" --set 'controlPlane.containerAgents.toolProfiles={disputes}'
okr "a container agent profile without endpoint tools is not affected" "${EA[@]}" "${CAV[@]}" --set 'controlPlane.containerAgents.toolProfiles={lookup}'
ev '.mcp.endpoints[0].allowDefinitions=true'
er "allowDefinitions on an endpoint with a group of its own is refused" 'allowDefinitions: true is not accepted' -f "$EX2"

echo "# endpoints: agents on the profile"
AG='{name:"disputeagent", model:"claude-haiku", systemPrompt:"You review disputes.", toolProfile:"disputes", knowledge:true, notify:{enabled:true}, tools:[{tools:["records_get_case"]}]}'
yq -y "{agents: (.agents|. + [$AG])}" "$CHART/values.yaml" > "$EX2"
EX3="$(dirname "$0")/.ep-values3.yaml"
yq -y '.mcp.profiles[0].tools.knowledge=["kb_search","kb_get_document","kb_list_collections"] | .mcp.profiles[0].tools.delivery=["notify_send","notify_list_destinations"]' "$EX" > "$EX3"
DA2=$(docs -f "$EX2" -f "$EX3")
AT='.[]|select(.kind=="AgentTemplate" and .metadata.name=="disputeagent-template")'
eq "an agent on the profile names its tools as the vMCP serves them, knowledge and notify with the mirror names" "$(q "$DA2" "$AT|.spec.tools[0].mcp|[.server.name,(.tools|sort|join(\",\"))]|join(\" \")")" "toolhive-vmcp-disputes delivery-disputes_notify_list_destinations,delivery-disputes_notify_send,knowledge-disputes_kb_get_document,knowledge-disputes_kb_list_collections,knowledge-disputes_kb_search,records_get_case"
eq "the prompt of such an agent names the mirror tools, not the shared ones" "$(q "$DA2" "$AT|.spec.systemPrompt|(contains(\"knowledge-disputes_kb_search\") and (contains(\"knowledge_kb_search\")|not))")" true
yq -y '{agents: (.agents|. + [{name:"other", model:"claude-haiku", systemPrompt:"x", toolProfile:"lookup", knowledge:false, tools:[{tools:["osv_query_vulnerability"]}]}])}' "$CHART/values.yaml" > "$EX2"
eq "an agent on a shared-group profile keeps the shared names" "$(q "$(docs -f "$EX2" -f "$EX3")" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="other-template")|.spec.tools[0].mcp.tools|join(",")')" osv_query_vulnerability
yq -y "{agents: (.agents|. + [{name:\"bad\", model:\"claude-haiku\", systemPrompt:\"x\", toolProfile:\"disputes\", tools:[{tools:[\"records_drop_all\"]}]}])}" "$CHART/values.yaml" > "$EX2"
er "an agent that lists a tool the profile does not offer is refused (the profile is the limit)" 'agent "bad" lists tool "records_drop_all" which is not in profile "disputes"' -f "$EX2" -f "$EX"
rm -f "$EX3"

echo "# endpoints: the refusals (each fails the render with a sentence that names the value)"
ev '.mcp.endpoints[0].url="http://records:8080/mcp"'
er "a one-label host is refused" '.url "http://records:8080/mcp" must be http(s)://' -f "$EX2"
ev '.mcp.endpoints[0].url="http://records.records-ns:8080/mcp"'
er "the short form <service>.<namespace> is refused as a URL (write .svc or .svc.cluster.local)" '.url "http://records.records-ns:8080/mcp" must be http(s)://' -f "$EX2"
ev '.mcp.endpoints[0].url="http://records.records-ns.svc:8080/mcp"'
okr "the .svc form is accepted" -f "$EX2"
ev '.mcp.endpoints[0].url="https://records.records-ns.svc.cluster.local/mcp"'
okr "https and no port are accepted" -f "$EX2"
ev '.mcp.endpoints[0].url="https://api.example.com/mcp"'
er "an internet URL is refused (not in this slice)" '.url "https://api.example.com/mcp" is outside the cluster' -f "$EX2"
ev '.mcp.endpoints[0].url="http://10.0.0.5:8080/mcp"'
er "an IPv4 literal is refused" 'names an address (an IPv4 or IPv6 literal)' -f "$EX2"
ev '.mcp.endpoints[0].url="http://[::1]:8080/mcp"'
er "an IPv6 literal is refused" 'names an address (an IPv4 or IPv6 literal)' -f "$EX2"
ev '.mcp.endpoints[0].url="http://user:pw@records.records-ns.svc.cluster.local:8080/mcp"'
er "a user name and password in the URL are refused" '.url may not hold a user name or password' -f "$EX2"
ev '.mcp.endpoints[0].url="http://records.records-ns.svc.cluster.local:8080/mcp?x=1"'
er "a query is refused" '.url may not hold a query' -f "$EX2"
ev '.mcp.endpoints[0].url="http://records.records-ns.svc.cluster.local:8080/mcp#a"'
er "a fragment is refused" '.url may not hold a fragment' -f "$EX2"
ev '.mcp.endpoints[0].url="http://records.records-ns.svc.cluster.local:99999/mcp"'
er "a port above 65535 is refused" '.url has the port 99999' -f "$EX2"
ev '.mcp.endpoints[0].url="ftp://records.records-ns.svc.cluster.local/mcp"'
er "a scheme other than http and https is refused" '.url must start with http:// or https:// (got "ftp://' -f "$EX2"
# the namespaces: every value of values.yaml whose key ends in "namespace" (an empty value is the release namespace), and the fixed ones
NSV=$(yq -r '[.. | objects | to_entries[] | select(.key|test("namespace$";"i")) | .value | strings | if .=="" then "openagentix-system" else . end] | unique | .[]' "$CHART/values.yaml")
eq "the walk of values.yaml finds the namespace values (the test is not empty)" "$([ "$(printf '%s\n' "$NSV" | wc -l | tr -d ' ')" -ge 15 ] && echo yes || echo no)" yes
for NSX in $NSV default kube-system kube-public kube-node-lease openagentix-anything; do
  ev ".mcp.endpoints[0].url=\"http://records.$NSX.svc.cluster.local:8080/mcp\""
  er "an endpoint in the namespace $NSX is refused as a platform namespace" "is in the namespace \"$NSX\", a platform or system namespace" -f "$EX2"
done
er "a namespace value that is new in the values (zzz.extraNamespace) is refused at once: the refusal list is built from the values" 'is in the namespace "records-ns", a platform or system namespace' -f "$EX" --set zzz.extraNamespace=records-ns
ev '.mcp.endpoints[0].url="http://kubernetes.default.svc.cluster.local:443/mcp"'
er "the Kubernetes API service is refused by name" '.url is the Kubernetes API service' -f "$EX2"
ev '.mcp.endpoints[0].ingress.podSelector={}'
er "an empty podSelector is refused" '.ingress.podSelector must be a non-empty map' -f "$EX2"
ev 'del(.mcp.endpoints[0].ingress.podSelector)'
er "a missing podSelector is refused" '.ingress.podSelector must be a non-empty map' -f "$EX2"
ev 'del(.mcp.endpoints[0].ingress.port)'
er "a missing port is refused" '.ingress.port is required' -f "$EX2"
ev '.mcp.endpoints[0].ingress.port=0'
er "port 0 is refused" '.ingress.port is required' -f "$EX2"
ev 'del(.mcp.endpoints[0].ingress)'
er "an in-cluster endpoint without ingress is refused" '.ingress is required for an in-cluster endpoint' -f "$EX2"
ev '.mcp.endpoints[0].ingress.podSelector={app:{x:1}}'
er "a podSelector value that is not a string is refused" '.ingress.podSelector label "app" needs a non-empty string value' -f "$EX2"
er "networkPolicy.enabled=false is refused with an endpoint" 'needs networkPolicy.enabled=true' -f "$EX" --set networkPolicy.enabled=false
er "an empty controlPlane.apiServerCIDRs is refused with an endpoint (the fallback would open the API server to any address)" 'needs controlPlane.apiServerCIDRs' -f "$EX" --set-json 'controlPlane.apiServerCIDRs=[]'
er "mcp.enabled=false with endpoints is refused" 'needs mcp.enabled=true' -f "$EX" --set mcp.enabled=false --set 'mcp.profiles=null'
er "mcp.endpoints that is not a list is refused" 'mcp.endpoints must be a list' --set mcp.endpoints=x
ev '.mcp.endpoints[0].urll="x"'
er "an unknown key in an endpoint is refused" 'unknown key "urll"' -f "$EX2"
for BADN in 'Records' 'a--b' '-a' "$(printf 'a%.0s' $(seq 1 31))" 'a_b'; do
  ev ".mcp.endpoints[0].name=\"$BADN\" | .mcp.profiles[0].tools={\"$BADN\":[\"get_case\"]}"
  er "the endpoint name '$(printf '%s' "$BADN" | cut -c1-12)' is refused" 'name must be lower case letters, digits and single dashes, at most 30' -f "$EX2"
done
ev '.mcp.endpoints += [.mcp.endpoints[0]]'
er "a duplicate endpoint name is refused" 'the name "records" is used twice' -f "$EX2"
for TAKEN in fetch osv knowledge delivery knowledge-disputes delivery-disputes cluster-read db-read; do
  ev ".mcp.endpoints[0].name=\"$TAKEN\" | .mcp.profiles[0].tools={\"$TAKEN\":[\"get_case\"]}"
  er "the endpoint name $TAKEN is refused (it is taken or reserved)" 'is already' -f "$EX2"
done
for BADG in tools diagnostics Disputes a--b -x "$(printf 'a%.0s' $(seq 1 21))"; do
  ev ".mcp.endpoints[0].group=\"$BADG\""
  er "the group name '$(printf '%s' "$BADG" | cut -c1-12)' is refused" ".group \"$BADG\" is not valid" -f "$EX2"
done
ev '.mcp.endpoints[0].group=""'
er "an empty group without allowUnauthenticated is refused (the shared group is opt-in)" '.group is empty: set group' -f "$EX2"
ev '.mcp.endpoints[0].group="" | .mcp.endpoints[0].allowUnauthenticated=true | del(.mcp.endpoints[0].auth)'
er "the shared group mode is not in this slice: allowUnauthenticated is refused with that sentence" 'is not available in this release (ADR 0026 slice 6)' -f "$EX2"
ev 'del(.mcp.endpoints[0].auth)'
er "an in-cluster endpoint without a credential is refused" '.auth is required' -f "$EX2"
ev '.mcp.endpoints[0].transport="websocket"'
er "an unknown transport is refused" '.transport must be streamable-http' -f "$EX2"
ev '.mcp.endpoints[0].transport="sse"'
okr "transport sse is accepted" -f "$EX2"
for HN in Host Content-Length content-type Transfer-Encoding Connection Cookie Proxy-Authorization Mcp-Session-Id Mcp-Protocol-Version Metadata-Flavor Metadata X-aws-ec2-metadata-token x-AWS-ec2-metadata-token; do
  ev ".mcp.endpoints[0].auth.header.name=\"$HN\""
  er "the header name $HN is refused" 'is a refused header name' -f "$EX2"
done
for HN in 'bad name' 'a_b' "$(printf 'a%.0s' $(seq 1 65))" ''; do
  ev ".mcp.endpoints[0].auth.header.name=\"$HN\""
  er "the header name '$(printf '%s' "$HN" | cut -c1-12)' is refused (not a token of letters, digits, dashes, at most 64)" 'is not a valid header name' -f "$EX2"
done
ev '.mcp.endpoints[0].auth.header.name="X-Api-Key"'
okr "a custom header name is accepted" -f "$EX2"
ev 'del(.mcp.endpoints[0].auth.header.secret.key)'
er "a Secret reference without a key is refused" '.auth.header.secret must be {name:' -f "$EX2"
ev '.mcp.endpoints[0].auth.header.secret.name="Bad_Name"'
er "a Secret name that is not a DNS name is refused" '.auth.header.secret must be {name:' -f "$EX2"
ev '.mcp.endpoints[0].auth.header.value="x"'
er "a header value in the values is refused (only a Secret reference is possible)" '.auth.header: only name and secret are accepted, got "value"' -f "$EX2"
ev '.mcp.endpoints[0].auth.bearer={token:"x"}'
er "an auth type other than header is refused" '.auth: only the key header is accepted, got "bearer"' -f "$EX2"
ev '.mcp.profiles[0].codeMode=true'
er "code mode on a profile that lists an endpoint tool is refused" 'codeMode must be false' -f "$EX2"
ev '.mcp.profiles[0].tools.records=["get.case"]'
er "a '.' in an endpoint tool name is refused" 'get.case' -f "$EX2"
ev ".mcp.profiles[0].tools.records=[\"$(printf 'a%.0s' $(seq 1 57))\"]"
er "a prefixed tool name of 65 characters is refused" '64 characters' -f "$EX2"
ev ".mcp.profiles[0].tools.records=[\"$(printf 'a%.0s' $(seq 1 56))\"]"
okr "a prefixed tool name of 64 characters is accepted" -f "$EX2"
ev '.mcp.endpoints += [{name:"ab",url:"http://ab.records-ns.svc.cluster.local:8080/mcp",group:"disputes",auth:{header:{name:"Authorization",secret:{name:"x",key:"value"}}},ingress:{podSelector:{app:"ab"},port:8080}}] | .mcp.endpoints[0].name="a" | .mcp.profiles[0].tools={a:["bc"],ab:["c"]}'
er "two backends of one group with one prefixed tool name are refused, naming both" 'a" and "ab' -f "$EX2" --set-json 'mcp.virtual.prefixFormat="{workload}"'
ev '.mcp.endpoints += [{name:"other",url:"http://other.records-ns.svc.cluster.local:8080/mcp",group:"second",auth:{header:{name:"Authorization",secret:{name:"sec2",key:"value"}}},ingress:{podSelector:{app:"other"},port:8080}}] | .mcp.profiles[0].tools.other=["x"]'
er "a profile that lists endpoints of two groups is refused" 'two tool groups' -f "$EX2"
ev '.mcp.profiles[0].tools.osv=["query_vulnerability"]'
er "a profile that lists an endpoint and an mcp.servers entry is refused (an MCPServer has one group)" 'mcp.servers' -f "$EX2"
ev '.mcp.profiles[0].tools.fetch=["fetch"]'
er "... also for fetch" 'mcp.servers' -f "$EX2"
ev '.diagnostics={enabled:true,apiServerCIDRs:["172.18.0.0/24"],cluster:{enabled:true,statusNamespaces:["kagent"]}} | .mcp.profiles[0].tools["cluster-read"]=["pods_get"]'
eq "a profile that lists an endpoint and a diagnostics tool is refused (two groups)" "$([ -n "$(render_err -f "$EX2")" ] && echo refused || echo rendered)" refused
er "mcp.endpointEntriesHeld naming an endpoint of a group of its own is refused" 'an endpoint with a group of its own: only an endpoint' -f "$EX" --set 'mcp.endpointEntriesHeld={records}'
er "mcp.endpointEntriesHeld naming something that is not an endpoint is refused" 'which is not an entry of mcp.endpoints' -f "$EX" --set 'mcp.endpointEntriesHeld={nosuch}'
er "mcp.endpointEntriesHeld that is not a list is refused" 'must be a list of endpoint names' -f "$EX" --set mcp.endpointEntriesHeld=records

echo "# endpoints: agents and definitions cannot reach the endpoint around the profile"
for FORM in records.records-ns records.records-ns.svc records.records-ns.svc.cluster.local '*.records-ns.svc' '*.records-ns.svc.cluster.local'; do
  yq -y "{agents: (.agents|.[0].egress={allow:[\"http://$FORM\"]})}" "$CHART/values.yaml" > "$EX2"
  er "agents[].egress.allow naming the endpoint host as $FORM is refused" 'names the host of an entry of mcp.endpoints (in any form' -f "$EX2" -f "$EX"
  er "controlPlane.policy.egress.allowedOrigins naming it as $FORM is refused" 'names the host of an entry of mcp.endpoints (in any form' -f "$EX" --set controlPlane.enabled=true --set "controlPlane.policy.egress.allowedOrigins={http://$FORM}"
done
for FORM in records.records-ns:8080 records.records-ns.svc:8080 records.records-ns.svc.cluster.local:8080; do
  er "controlPlane.policy.egress.inClusterDestinations naming it as $FORM is refused" 'names the host of an entry of mcp.endpoints (in any form' -f "$EX" --set controlPlane.enabled=true --set "controlPlane.policy.egress.inClusterDestinations={$FORM}"
done
yq -y '{agents: (.agents|.[0].egress={allow:["http://other.records-ns.svc.cluster.local"]})}' "$CHART/values.yaml" > "$EX2"
okr "another service of the same namespace is not named by this rule (it is only the endpoint host)" -f "$EX2" -f "$EX"
okr "a wildcard of another namespace is fine" -f "$EX" --set controlPlane.enabled=true --set 'controlPlane.policy.egress.allowedOrigins={https://*.example.com}'
# The control plane refuses the WHOLE namespace of an endpoint (the controller refuses to start with such a value, and the guard refuses it): the render says so first
for FORM in other.records-ns:8080 other.records-ns.svc:8080 other.records-ns.svc.cluster.local:8080; do
  er "controlPlane.policy.egress.inClusterDestinations naming ANOTHER service of the endpoint's namespace ($FORM) is refused" "inClusterDestinations entry $FORM is inside the namespace \"records-ns\" of an entry of mcp.endpoints" -f "$EX" --set controlPlane.enabled=true --set "controlPlane.policy.egress.inClusterDestinations={$FORM}"
done
for FORM in 'https://*.records-ns.svc' 'https://*.records-ns.svc.cluster.local'; do
  er "controlPlane.policy.egress.allowedOrigins with a wildcard over the whole namespace ($FORM) is refused (it covers the endpoint host)" "names the host of an entry of mcp.endpoints (in any form" -f "$EX" --set controlPlane.enabled=true --set "controlPlane.policy.egress.allowedOrigins={$FORM}"
done
for FORM in http://other.records-ns https://other.records-ns.svc https://other.records-ns.svc.cluster.local:8443; do
  er "controlPlane.policy.egress.allowedOrigins naming a host of the endpoint's namespace ($FORM) is refused" "allowedOrigins entry $FORM is inside the namespace \"records-ns\" of an entry of mcp.endpoints" -f "$EX" --set controlPlane.enabled=true --set "controlPlane.policy.egress.allowedOrigins={$FORM}"
done
okr "inClusterDestinations of another namespace is fine" -f "$EX" --set controlPlane.enabled=true --set 'controlPlane.policy.egress.inClusterDestinations={registry.ci.svc:5000}'
okr "agents[].egress.allow keeps the host-only rule: another service of the namespace renders (the sandbox's proxy is not the controller)" -f "$EX2" -f "$EX"
okr "the same values without endpoints render (the namespace rule is for endpoints only)" --set controlPlane.enabled=true --set 'controlPlane.policy.egress.inClusterDestinations={other.records-ns.svc:8080}'
# the identity provider values must be usable when endpoints are on
er "an empty networkPolicy.substrate.idp.podLabels is refused with an endpoint (an empty selector would admit every pod of the Substrate namespace)" 'networkPolicy.substrate.idp.podLabels must be a non-empty map' -f "$EX" --set networkPolicy.substrate.idp.podLabels=null
er "a podLabels value that is not a string is refused" 'networkPolicy.substrate.idp.podLabels must be a non-empty map' -f "$EX" --set-json 'networkPolicy.substrate.idp.podLabels={"app":1}'
er "a missing networkPolicy.substrate.idp.port is refused with an endpoint" 'networkPolicy.substrate.idp.port must be a port number' -f "$EX" --set networkPolicy.substrate.idp.port=null
er "networkPolicy.substrate.idp.port 0 is refused" 'networkPolicy.substrate.idp.port must be a port number' -f "$EX" --set networkPolicy.substrate.idp.port=0
okr "an empty idp selector is not looked at without endpoints (the default render does not change)" --set-json 'networkPolicy.substrate.idp.podLabels={}\'

echo "# endpoints: the values file"
eq "values.yaml documents the shape (endpoints, group, auth.header, ingress, allowDefinitions) in comments" "$(/usr/bin/grep -c '#  *- name: records\|#    group:\|#      header:\|#      podSelector:\|#    allowDefinitions:' "$CHART/values.yaml" | awk '{print ($1>=5)?"yes":"no"}')" yes

echo "# endpoints: the render equals the baseline of the chart before this slice"
# The default render (the control plane is off) is byte-identical. With the control plane on (the quick start, the full demo) exactly one rule of the admission guard
# changed on purpose: the egress host rule of the EgressPolicy guard (the short form <service>.<namespace> of a cluster name, ADR 0026 slice 2): two comment lines and
# one line of CEL. The comparison below leaves those lines out on both sides, so any other difference fails.
if [ -n "${OA_BASELINE_DIR:-}" ]; then
  RC3="$REPO/components"
  GUARDLINES='top level domain|ADR 0026\). A namespace of letters|names that only look public|!host.matches\(.\^\[0-9.\]\+\$.\)'
  nog() { /usr/bin/grep -Ev -e "$GUARDLINES"; }
  eq "default render is byte-identical to the baseline (OA_BASELINE_DIR)" "$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)" "$(shasum -a 256 < "$OA_BASELINE_DIR/default.txt")"
  eq "quick start render equals the baseline apart from the egress host rule of the guard" "$(helm template openagentix "$CHART" -n openagentix-system -f "$RC3/quickstart/values.yaml" 2>&1 | nog | shasum -a 256)" "$(nog < "$OA_BASELINE_DIR/qs.txt" | shasum -a 256)"
  eq "full demo render equals the baseline apart from the egress host rule of the guard" "$(helm template openagentix "$CHART" -n openagentix-system "${RCDEMO[@]}" $GKAPI 2>&1 | nog | shasum -a 256)" "$(nog < "$OA_BASELINE_DIR/full.txt" | shasum -a 256)"
  eq "the lines that were left out are exactly the guard's egress host rule (six lines differ in the quick start render)" "$(diff <(helm template openagentix "$CHART" -n openagentix-system -f "$RC3/quickstart/values.yaml" 2>&1) "$OA_BASELINE_DIR/qs.txt" | /usr/bin/grep -c '^[<>]')" 6
fi
rm -f "$EX" "$EX2"
