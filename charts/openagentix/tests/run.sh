#!/usr/bin/env bash
# Plain-shell tests over `helm template` output. Needs: helm, yq (jq wrapper), jq.
# Usage: charts/openagentix/tests/run.sh   (exit 1 on any failure)
set -u
CHART="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

# docs <helm args...> -> JSON array of all rendered documents ("[]" if helm fails)
docs() { helm template openagentix "$CHART" -n openagentix-system "$@" 2>/dev/null | yq -c 'select(.!=null)' 2>/dev/null | jq -s . 2>/dev/null || echo '[]'; }
# render_fails <helm args...> -> prints helm's error output (empty if it rendered)
render_err() { helm template openagentix "$CHART" -n openagentix-system "$@" 2>&1 >/dev/null; }

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$3" "$2"; }          # eq desc actual expected
# q <docs-json> <jq filter> -> raw result
q()    { jq -r "$2" <<<"$1"; }
count(){ q "$1" "[.[] | select($2)] | length"; }                      # count docs-json 'jq select expr'

# the default agents list with one yq edit applied (lists are replaced, not merged, by helm --set)
with_agents() { local e=$1; shift; yq -y "{agents: (.agents|$e)}" "$CHART/values.yaml" > "$(dirname "$0")/.agents-variant.yaml"; docs -f "$(dirname "$0")/.agents-variant.yaml" "$@"; rm -f "$(dirname "$0")/.agents-variant.yaml"; }
echo "# defaults"
D=$(docs)
eq "default render is non-empty"                       "$(q "$D" 'length>0')" true
eq "bridge Deployment rendered once"                   "$(count "$D" '.kind=="Deployment" and .metadata.name=="telegram-bridge"')" 1
eq "bridge lives in openagentix-gateway"               "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.metadata.namespace')" openagentix-gateway
eq "bridge keeps legacy selector app=telegram-bridge"  "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.selector.matchLabels.app')" telegram-bridge
eq "bridge strategy Recreate"                          "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.strategy.type')" Recreate
eq "bridge image"                                      "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].image')" openagentix/telegram-bridge:dev
eq "bridge A2A_URL derived from bridge.agent"          "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="A2A_URL")|.value')" http://kagent-controller.kagent.svc.cluster.local:8083/agents/kagent/assistant
eq "bridge token comes from secretKeyRef"              "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="TELEGRAM_BOT_TOKEN")|.valueFrom.secretKeyRef.name')" telegram-bridge
eq "bridge token env has no literal value"             "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="TELEGRAM_BOT_TOKEN")|has("value")')" false
eq "allowlist env present by default, optional"        "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="TELEGRAM_ALLOWED_CHAT_IDS")|.valueFrom.secretKeyRef.optional')" true
eq "bot is not open to everyone by default"            "$(q "$D" '[.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="TELEGRAM_ALLOW_ALL")]|length')" 0
eq "bridge liveness probe hits /healthz"               "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].livenessProbe.httpGet|.path+":"+(.port|tostring)')" /healthz:health
eq "bridge exposes health port 8080"                   "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].ports[]|select(.name=="health")|.containerPort')" 8080

echo "# bridge toggles"
D=$(docs --set bridge.enabled=false)
eq "bridge.enabled=false renders no bridge Deployment" "$(count "$D" '.kind=="Deployment" and .metadata.name=="telegram-bridge"')" 0
D=$(docs --set bridge.allowlist.enabled=false)
eq "allowlist.enabled=false drops the env var"         "$(q "$D" '[.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="TELEGRAM_ALLOWED_CHAT_IDS")]|length')" 0
eq "allowlist.enabled=false opens the bot explicitly"  "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="TELEGRAM_ALLOW_ALL")|.value')" true
D=$(docs --set bridge.existingSecret=my-secret --set bridge.tokenKey=TOK --set bridge.a2aUrl=http://x/y)
eq "bridge.existingSecret honoured"                    "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="TELEGRAM_BOT_TOKEN")|.valueFrom.secretKeyRef|.name+"/"+.key')" my-secret/TOK
eq "bridge.a2aUrl overrides derived url"               "$(q "$D" '.[]|select(.kind=="Deployment")|.spec.template.spec.containers[0].env[]|select(.name=="A2A_URL")|.value')" http://x/y

echo "# model gateway"
D=$(docs)
eq "one Gateway"                                       "$(count "$D" '.kind=="Gateway"')" 1
eq "Gateway class agentgateway"                        "$(q "$D" '.[]|select(.kind=="Gateway")|.spec.gatewayClassName')" agentgateway
eq "Gateway ns"                                        "$(q "$D" '.[]|select(.kind=="Gateway")|.metadata.namespace')" agentgateway-system
eq "listener allows AgentgatewayModel"                 "$(q "$D" '.[]|select(.kind=="Gateway")|[.spec.listeners[0].allowedRoutes.kinds[].kind]|index("AgentgatewayModel")!=null')" true
eq "default model claude-haiku"                        "$(q "$D" '.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="claude-haiku")|.metadata.name')" claude-haiku
eq "claude-haiku provider Anthropic"                   "$(q "$D" '.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="claude-haiku")|.spec.provider')" Anthropic
eq "claude-haiku auth secret"                          "$(q "$D" '.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="claude-haiku")|.spec.policies.auth.secretRef.name')" anthropic-api-key
eq "claude-haiku upstream model rewrite"               "$(q "$D" '.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="claude-haiku")|.spec.policies.transformations[0].expression')" '"claude-haiku-5-5"'
eq "model parentRef is the gateway"                    "$(q "$D" '.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="claude-haiku")|.spec.parentRefs[0].name')" model-gateway
eq "exactly ONE AgentgatewayPolicy"                    "$(count "$D" '.kind=="AgentgatewayPolicy"')" 1
eq "policy: strict api-key auth"                       "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.traffic.apiKeyAuthentication.mode')" Strict
eq "policy: per-user token budget"                     "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.traffic.rateLimit.local[0].key')" apiKey.user_id
eq "policy: token budget default 1000000 per hour"     "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.traffic.rateLimit.local[0]|"\(.tokens) \(.unit)"')" "1000000 Hours"
eq "policy: retry attempts"                            "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.traffic.retry.attempts')" 2
eq "policy: access log attributes user_id"             "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.frontend.accessLog.attributes.add[0].name')" user_id
eq "policy: metrics attribute user_id"                 "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.frontend.metrics.attributes.add[0].name')" user_id
eq "policy: prompt caching is on by default (backend.ai.promptCaching)" "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.backend.ai.promptCaching|"\(.cacheSystem) \(.cacheMessages) \(.cacheTools) \(.minTokens)"')" "true true true 1024"
D=$(docs --set gateway.policy.promptCaching.enabled=false)
eq "promptCaching.enabled=false renders no backend section" "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec|has("backend")')" false
D=$(docs)
eq "promptCaching keeps the one policy and its traffic part" "$(q "$D" '[.[]|select(.kind=="AgentgatewayPolicy")]|length')" 1
D=$(docs --set gateway.policy.promptCaching.enabled=true --set gateway.policy.promptCaching.cacheTools=false --set gateway.policy.promptCaching.cacheMessages=false --set gateway.policy.promptCaching.minTokens=0)
eq "promptCaching switches and minTokens are honoured (0 is kept)" "$(q "$D" '.[]|select(.kind=="AgentgatewayPolicy")|.spec.backend.ai.promptCaching|"\(.cacheSystem) \(.cacheMessages) \(.cacheTools) \(.minTokens)"')" "true false false 0"
D=$(docs --set gateway.enabled=false)
eq "gateway.enabled=false: no Gateway/Model/Policy"    "$(count "$D" '.kind=="Gateway" or .kind=="AgentgatewayModel" or .kind=="AgentgatewayPolicy"')" 0
cat > "$(dirname "$0")/.extra-models.yaml" <<'YAML'
gateway:
  models:
    - name: claude-haiku
      provider: Anthropic
      authSecret: anthropic-api-key
      upstreamModel: claude-haiku-5-5
    - name: gemini
      provider: Gemini
      authSecret: gemini-api-key
      upstreamModel: gemini-3.5-flash-lite
    - name: auto
      failover: [gemini, claude-haiku]
YAML
D=$(docs -f "$(dirname "$0")/.extra-models.yaml")
eq "models come from values (3 chat models + embed-default + embed-memory)" "$(count "$D" '.kind=="AgentgatewayModel"')" 5
eq "failover model renders virtualModel targets"       "$(q "$D" '.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="auto")|[.spec.virtualModel.failover.targets[]|.modelRef.name+":"+(.priority|tostring)]|join(",")')" gemini:0,claude-haiku:1
rm -f "$(dirname "$0")/.extra-models.yaml"

echo "# MCP tool layer"
D=$(docs)
eq "one MCPGroup"                                      "$(count "$D" '.kind=="MCPGroup"')" 1
eq "two MCPServers by default"                         "$(count "$D" '.kind=="MCPServer"')" 2
eq "MCPServers reference the group"                    "$(q "$D" '[.[]|select(.kind=="MCPServer")|.spec.groupRef.name]|unique|join(",")')" tools
eq "one VirtualMCPServer"                              "$(count "$D" '.kind=="VirtualMCPServer"')" 1
eq "codeMode enabled by default"                       "$(q "$D" '.[]|select(.kind=="VirtualMCPServer")|.spec.config.codeMode.enabled')" true
eq "tool name prefixing kept"                          "$(q "$D" '.[]|select(.kind=="VirtualMCPServer")|.spec.config.aggregation.conflictResolution')" prefix
D=$(docs --set mcp.virtual.codeMode.enabled=false)
eq "codeMode toggle off omits codeMode"                "$(q "$D" '.[]|select(.kind=="VirtualMCPServer")|.spec.config|has("codeMode")')" false
D=$(docs --set mcp.enabled=false)
eq "mcp.enabled=false: no ToolHive resources"          "$(count "$D" '.kind=="MCPGroup" or .kind=="MCPServer" or .kind=="VirtualMCPServer"')" 0
cat > "$(dirname "$0")/.servers.yaml" <<'YAML'
mcp:
  servers:
    - {name: fetch, image: "ghcr.io/stackloklabs/gofetch/server:2.0.1", port: 8080}
    - {name: osv, image: "ghcr.io/stackloklabs/osv-mcp/server:0.2.1", port: 8080}
    - {name: extra, image: "example.com/x:1", port: 9000}
YAML
D=$(docs -f "$(dirname "$0")/.servers.yaml"); rm -f "$(dirname "$0")/.servers.yaml"
eq "MCPServers come from a values list (3)"            "$(count "$D" '.kind=="MCPServer"')" 3
D=$(docs)
eq "RemoteMCPServer url derived from vMCP name+ns"     "$(q "$D" '.[]|select(.kind=="RemoteMCPServer")|.spec.url')" http://vmcp-tools.mcp-tools.svc.cluster.local:4483/mcp
eq "RemoteMCPServer lives in kagent"                   "$(q "$D" '.[]|select(.kind=="RemoteMCPServer")|.metadata.namespace')" kagent

echo "# kagent agents"
eq "one Agent by default"                              "$(count "$D" '.kind=="Agent"')" 1
eq "one AgentTemplate by default"                      "$(count "$D" '.kind=="AgentTemplate"')" 1
eq "one Harness by default"                            "$(count "$D" '.kind=="Harness"')" 1
eq "Agent refs template and harness"                   "$(q "$D" '.[]|select(.kind=="Agent")|.spec.template.ref.name+"/"+.spec.harnessRef.name')" assistant-template/assistant-harness
eq "template systemPrompt set"                         "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt|length>20')" true
eq "template modelConfig ref"                          "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.modelConfig.name')" gateway-claude-haiku
eq "mcp binding kind"                                  "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.server.kind')" RemoteMCPServer
eq "mcp binding has NO apiGroup (webhook rejects it)"  "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.server|has("apiGroup")')" false
eq "mcp binding server name"                           "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.server.name')" toolhive-vmcp
eq "mcp binding tool allowlist (5 + 3 kb tools)"                    "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.tools|length')" 8
eq "harness uses substrate worker pool"                "$(q "$D" '.[]|select(.kind=="Harness")|.spec.substrate.workerPoolRef.name')" kagent-default
eq "harness image is digest pinned"                    "$(q "$D" '.[]|select(.kind=="Harness")|.spec.workload.image|test("@sha256:[0-9a-f]{64}$")')" true
eq "skill source is a digest-pinned oci ref"           "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.skills[0].source.oci|test("@sha256:[0-9a-f]{64}$")')" true
eq "default skill ref has no hard-coded node IP"       "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.skills[0].source.oci|test("^172\\.")')" false
eq "skill name"                                        "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.skills[0].name')" openagentix-canary
E=$(render_err --set skills.openagentix-canary.oci=registry.example/skills/x:latest)
eq "unpinned skill ref fails the render"               "$([ -n "$E" ] && echo failed || echo rendered)" failed
D=$(docs --set kagent.enabled=false)
eq "kagent.enabled=false: no kagent resources"         "$(count "$D" '.kind=="Agent" or .kind=="AgentTemplate" or .kind=="Harness" or .kind=="ModelConfig" or .kind=="RemoteMCPServer"')" 0

cat > "$(dirname "$0")/.two-agents.yaml" <<'YAML'
agents:
  - name: alpha
    model: claude-haiku
    systemPrompt: "You are alpha, a terse assistant for testing."
    tools: []
    skills: []
  - name: beta
    model: claude-haiku
    systemPrompt: "You are beta, a terse assistant for testing."
    tools:
      - tools: [fetch_fetch]
    skills: []
YAML
D=$(docs -f "$(dirname "$0")/.two-agents.yaml")
eq "2 agents -> 2 Agent"                               "$(count "$D" '.kind=="Agent"')" 2
eq "2 agents -> 2 AgentTemplate"                       "$(count "$D" '.kind=="AgentTemplate"')" 2
eq "2 agents -> 2 Harness"                             "$(count "$D" '.kind=="Harness"')" 2
eq "2 agents -> 2 ModelConfig"                         "$(count "$D" '.kind=="ModelConfig"')" 2
eq "agent without tools renders no tools key"          "$(q "$D" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="alpha-template")|has("spec") and (.spec|has("tools"))')" false
eq "tools entry defaults server to the vMCP RemoteMCPServer" "$(q "$D" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="beta-template")|.spec.tools[0].mcp.server.name')" toolhive-vmcp
eq "agent without skills renders no skills key"        "$(q "$D" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="alpha-template")|.spec|has("skills")')" false

echo "# per-agent virtual keys"
eq "alpha ModelConfig uses alpha-virtual-key"          "$(q "$D" '.[]|select(.kind=="ModelConfig" and .metadata.name=="gateway-alpha")|.spec.apiKeySecret')" alpha-virtual-key
eq "beta ModelConfig uses beta-virtual-key"            "$(q "$D" '.[]|select(.kind=="ModelConfig" and .metadata.name=="gateway-beta")|.spec.apiKeySecret')" beta-virtual-key
eq "virtual key secret key"                            "$(q "$D" '[.[]|select(.kind=="ModelConfig")|.spec.apiKeySecretKey]|unique|join(",")')" OPENAI_API_KEY
eq "ModelConfig points at the gateway FQDN"            "$(q "$D" '.[]|select(.kind=="ModelConfig" and .metadata.name=="gateway-alpha")|.spec.openAI.baseUrl')" http://model-gateway.agentgateway-system.svc.cluster.local/v1
eq "ModelConfig model is the gateway model name"       "$(q "$D" '.[]|select(.kind=="ModelConfig" and .metadata.name=="gateway-alpha")|.spec.model')" claude-haiku
eq "ModelConfig annotated with its agent (install.sh reads it)" "$(q "$D" '[.[]|select(.kind=="ModelConfig")|.metadata.annotations["openagentix.io/agent"]]|sort|join(",")')" alpha,beta
eq "each template uses its own ModelConfig"            "$(q "$D" '[.[]|select(.kind=="AgentTemplate")|.spec.modelConfig.name]|sort|join(",")')" gateway-alpha,gateway-beta
rm -f "$(dirname "$0")/.two-agents.yaml"
E=$(render_err --set 'agents[0].model=nope')
eq "agent referencing an unknown gateway model fails"  "$([ -n "$E" ] && echo failed || echo rendered)" failed

echo "# network policies (stage 1)"
D=$(docs)
VP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-ingress")'
CP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-controller")'
BP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-mcp-tools-default")'
eq "4 platform NetworkPolicies by default (knowledge ns excluded)" "$(count "$D" '.kind=="NetworkPolicy" and .metadata.namespace!="openagentix-knowledge" and .metadata.namespace!="openagentix-memory"')" 4
eq "mcp-tools default policy lives in mcp-tools"       "$(q "$D" "$BP|.metadata.namespace")" mcp-tools
eq "mcp-tools default policy selects every pod"        "$(q "$D" "$BP|.spec.podSelector|length")" 0
eq "mcp-tools default policy is ingress-only"          "$(q "$D" "$BP|.spec.policyTypes|join(\",\")")" Ingress
eq "backends: allowed from own namespace and operator ns" "$(q "$D" "$BP|[.spec.ingress[].from[]|(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]//\"same-ns\")]|sort|join(\",\")")" same-ns,toolhive-system
eq "vMCP policy selects the vMCP pod"                  "$(q "$D" "$VP|.spec.podSelector.matchLabels|\"\\(.app)/\\(.[\"toolhive-name\"])\"")" virtualmcpserver/tools
eq "vMCP policy only on the vMCP port"                 "$(q "$D" "$VP|[.spec.ingress[].ports[].port]|unique|join(\",\")")" 4483
eq "vMCP: sources are egress proxy and kagent controller" "$(q "$D" "$VP|[.spec.ingress[].from[]|.podSelector.matchLabels|to_entries[0].value]|sort|join(\",\")")" atenet-egress,controller
eq "vMCP: egress source scoped to ate-system namespace" "$(q "$D" "$VP|[.spec.ingress[].from[]|select(.podSelector.matchLabels.app==\"atenet-egress\")|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]]|join(\",\")")" ate-system
eq "controller policy lives in kagent"                 "$(q "$D" "$CP|.metadata.namespace")" kagent
eq "controller policy selects the controller pod"      "$(q "$D" "$CP|.spec.podSelector.matchLabels[\"app.kubernetes.io/component\"]")" controller
eq "controller: 8083 sources are bridge pod, kagent UI pods, egress proxy" "$(q "$D" "$CP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]|(.podSelector.matchLabels|if .==null then \"any-pod\" else to_entries[0].value end)]|sort|join(\",\")")" atenet-egress,telegram-bridge,ui
eq "controller: bridge source is pod-scoped (ns AND pod label in one entry)" "$(q "$D" "$CP|[.spec.ingress[].from[]?|select(.podSelector.matchLabels.app==\"telegram-bridge\")|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]]|join(\",\")")" openagentix-gateway
eq "controller: ports other than 8083 stay open"       "$(q "$D" "$CP|[.spec.ingress[]|select(has(\"from\")|not)|.ports[]|(.port|tostring)+\"-\"+(.endPort|tostring)]|sort|join(\",\")")" 1-8082,8084-65535
UP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-ui")'
eq "kagent UI policy lives in kagent and selects the UI pods" "$(q "$D" "$UP|.metadata.namespace+\" \"+(.spec.podSelector.matchLabels|to_entries|map(.key+\"=\"+.value)|sort|join(\",\"))")" "kagent app.kubernetes.io/component=ui,app.kubernetes.io/name=kagent"
eq "kagent UI policy is ingress-only and denies all by default" "$(q "$D" "$UP|[(.spec.policyTypes|join(\",\")),((.spec.ingress//[])|length|tostring)]|join(\" \")")" "Ingress 0"
D2=$(docs --set 'networkPolicy.kagentUI.allowFrom[0].namespace=ops' --set 'networkPolicy.kagentUI.allowFrom[0].podLabels.app=proxy')
eq "kagentUI.allowFrom adds a peer scoped by namespace AND pod labels, on the UI port only" "$(q "$D2" "$UP|.spec.ingress|map([(.from[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]),(.from[0].podSelector.matchLabels.app),(.ports[0].port|tostring)]|join(\"/\"))|join(\",\")")" "ops/proxy/8080"
eq "kagentUI.allowFrom without podLabels admits the namespace" "$(q "$(docs --set 'networkPolicy.kagentUI.allowFrom[0].namespace=ops')" "$UP|.spec.ingress[0].from[0]|has(\"podSelector\")|tostring")" false
eq "kagent.enabled=false renders no UI policy"        "$(count "$(docs --set kagent.enabled=false)" '.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-ui"')" 0
eq "no controller peer admits the whole kagent namespace" "$(q "$D" "$CP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]|select(has(\"podSelector\")|not)]|length")" 0
eq "the UI pods are a controller peer (the UI proxies /api to it)" "$(q "$D" "$CP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]|select(.podSelector.matchLabels[\"app.kubernetes.io/component\"]==\"ui\")|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]]|join(\",\")")" kagent
D=$(docs --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false renders none (also in the knowledge ns)" "$(count "$D" '.kind=="NetworkPolicy"')" 0
D=$(docs --set mcp.enabled=false)
eq "mcp.enabled=false: only the controller and UI policies"     "$(q "$D" '[.[]|select(.kind=="NetworkPolicy" and .metadata.namespace!="openagentix-knowledge" and .metadata.namespace!="openagentix-memory")|.metadata.name]|join(",")')" openagentix-kagent-controller,openagentix-kagent-ui
D=$(docs --set bridge.enabled=false)
eq "bridge.enabled=false drops the bridge source"      "$(q "$D" "$CP|[.spec.ingress[].from[]?|select(.podSelector.matchLabels.app==\"telegram-bridge\")]|length")" 0
D=$(docs --set kagent.enabled=false)
eq "kagent.enabled=false: no controller policy, vMCP policy keeps ns sources" "$(q "$D" '[.[]|select(.kind=="NetworkPolicy" and .metadata.namespace!="openagentix-knowledge" and .metadata.namespace!="openagentix-memory")|.metadata.name]|sort|join(",")')" openagentix-mcp-tools-default,openagentix-vmcp-ingress

echo "# tool-layer identity (stage 2)"
D=$(docs)
V='.[]|select(.kind=="VirtualMCPServer")'
O='.[]|select(.kind=="MCPOIDCConfig")'
eq "vMCP incoming auth is oidc by default"             "$(q "$D" "$V|.spec.incomingAuth.type")" oidc
eq "vMCP references the MCPOIDCConfig"                 "$(q "$D" "$V|.spec.incomingAuth.oidcConfigRef.name")" substrate-actor-jwt
eq "vMCP expects the dedicated audience"               "$(q "$D" "$V|.spec.incomingAuth.oidcConfigRef.audience")" openagentix-vmcp
eq "Cedar policy is still rendered for authenticated callers" "$(q "$D" "$V|.spec.incomingAuth.authzConfig.inline.policies|length")" 1
eq "one MCPOIDCConfig in mcp-tools"                    "$(q "$D" "[$O|select(.metadata.namespace==\"mcp-tools\")]|length")" 1
eq "MCPOIDCConfig is inline"                           "$(q "$D" "$O|.spec.type")" inline
eq "issuer is the Substrate IdP"                       "$(q "$D" "$O|.spec.inline.issuer")" https://idp.ate-system.svc
eq "explicit jwksUrl (no reliance on discovery)"       "$(q "$D" "$O|.spec.inline.jwksUrl")" https://idp.ate-system.svc/openid/v1/jwks
eq "CA bundle from a ConfigMap"                        "$(q "$D" "$O|.spec.inline.caBundleRef.configMapRef|.name+\"/\"+.key")" substrate-idp-ca/ca.crt
eq "jwksAllowPrivateIP is on by default (the in-cluster IdP is a ClusterIP)" "$(q "$D" "$O|.spec.inline.jwksAllowPrivateIP")" true
eq "no insecure flags on the OIDC config"              "$(q "$D" "$O|.spec.inline|has(\"insecureAllowHTTP\")")" false
eq "RemoteMCPServer asks for an actor JWT with the audience" "$(q "$D" '.[]|select(.kind=="RemoteMCPServer")|.spec.actorJwt.audiences|join(",")')" openagentix-vmcp
eq "actor JWT lifetime is set"                         "$(q "$D" '.[]|select(.kind=="RemoteMCPServer")|.spec.actorJwt.expirationSeconds')" 3600
D=$(docs --set mcp.virtual.incomingAuth.type=anonymous)
eq "anonymous: no MCPOIDCConfig"                       "$(count "$D" '.kind=="MCPOIDCConfig"')" 0
eq "anonymous: no oidcConfigRef"                       "$(q "$D" "$V|.spec.incomingAuth|has(\"oidcConfigRef\")")" false
eq "anonymous: no actorJwt on the RemoteMCPServer"     "$(q "$D" '.[]|select(.kind=="RemoteMCPServer")|.spec|has("actorJwt")')" false
E=$(render_err --set mcp.virtual.incomingAuth.type=bogus)
eq "unknown incomingAuth.type fails the render"        "$([ -n "$E" ] && echo failed || echo rendered)" failed
D=$(docs --set mcp.virtual.incomingAuth.oidc.audience=other-aud --set mcp.virtual.incomingAuth.oidc.jwksAllowPrivateIP=false)
eq "audience value is shared by vMCP and RemoteMCPServer" "$(q "$D" "[($V|.spec.incomingAuth.oidcConfigRef.audience), (.[]|select(.kind==\"RemoteMCPServer\")|.spec.actorJwt.audiences[0])]|unique|join(\",\")")" other-aud
eq "jwksAllowPrivateIP follows values (false omits it)" "$(q "$D" "$O|.spec.inline|has(\"jwksAllowPrivateIP\")")" false

echo "# tool authorization keyed on the actor identity"
D=$(docs)
eq "default: Cedar stays permit-all (one policy)"      "$(q "$D" "$V|.spec.incomingAuth.authzConfig.inline.policies|join(\"|\")")" 'permit(principal, action, resource);'
cat > "$(dirname "$0")/.toolaccess.yaml" <<'YAML'
mcp:
  virtual:
    incomingAuth:
      toolAccess:
        - atespace: kagent
          tools: [fetch_fetch, osv_get_vulnerability]
        - atespace: other
          tools: [fetch_fetch]
YAML
D=$(docs -f "$(dirname "$0")/.toolaccess.yaml"); rm -f "$(dirname "$0")/.toolaccess.yaml"
eq "toolAccess renders one permit per atespace+tool (3)" "$(q "$D" "$V|.spec.incomingAuth.authzConfig.inline.policies|length")" 3
eq "toolAccess replaces the permit-all policy"         "$(q "$D" "$V|[.spec.incomingAuth.authzConfig.inline.policies[]|select(.==\"permit(principal, action, resource);\")]|length")" 0
eq "permit is keyed on the atespace claim and the tool" "$(q "$D" "$V|.spec.incomingAuth.authzConfig.inline.policies[0]")" 'permit(principal, action == Action::"call_tool", resource == Tool::"fetch_fetch") when { context["claim_actor.ate.dev"].atespace == "kagent" };'
eq "second atespace is rendered too"                   "$(q "$D" "$V|.spec.incomingAuth.authzConfig.inline.policies[2]|test(\"atespace == \\\"other\\\"\")")" true
E=$(render_err --set mcp.virtual.incomingAuth.type=anonymous --set 'mcp.virtual.incomingAuth.toolAccess[0].atespace=x' --set 'mcp.virtual.incomingAuth.toolAccess[0].tools[0]=fetch_fetch')
eq "toolAccess without oidc fails (anonymous has no identity)" "$([ -n "$E" ] && echo failed || echo rendered)" failed

echo "# knowledge base (kb + pgvector + local embeddings)"
D=$(docs)
KNS=openagentix-knowledge
inns() { count "$1" ".metadata.namespace==\"$KNS\" and ($2)"; }
KB='.[]|select(.kind=="Deployment" and .metadata.name=="kb")'
KC="$KB|.spec.template.spec.containers[0]"
KE="$KC|.env[]"
eq "knowledge block renders into its own namespace"    "$(q "$D" '[.[]|select(.metadata.namespace=="openagentix-knowledge")|.kind]|sort|join(",")')" Deployment,Deployment,NetworkPolicy,NetworkPolicy,NetworkPolicy,PersistentVolumeClaim,Service,Service,Service,StatefulSet
eq "kb Deployment, kb image"                           "$(q "$D" "$KC|.image")" openagentix/kb:dev
eq "kb uses the postgres store"                        "$(q "$D" "$KE|select(.name==\"KB_STORE\")|.value")" postgres
eq "kb database URL comes from a Secret"               "$(q "$D" "$KE|select(.name==\"KB_DATABASE_URL\")|.valueFrom.secretKeyRef|.name+\"/\"+.key")" kb-database/KB_DATABASE_URL
eq "kb database URL has no literal value"              "$(q "$D" "$KE|select(.name==\"KB_DATABASE_URL\")|has(\"value\")")" false
eq "kb admin token comes from a Secret"                "$(q "$D" "$KE|select(.name==\"KB_ADMIN_TOKEN\")|.valueFrom.secretKeyRef|.name+\"/\"+.key")" kb-admin/KB_ADMIN_TOKEN
eq "kb admin token is NOT optional (no silent open/closed API)" "$(q "$D" "$KE|select(.name==\"KB_ADMIN_TOKEN\")|.valueFrom.secretKeyRef.optional // false")" false
eq "kb embeds through the model gateway"               "$(q "$D" "$KE|select(.name==\"KB_EMBEDDINGS_URL\")|.value")" http://model-gateway.agentgateway-system.svc.cluster.local/v1
eq "kb embeddings model is the gateway alias"          "$(q "$D" "$KE|select(.name==\"KB_EMBEDDINGS_MODEL\")|.value")" embed-default
eq "kb embeddings dimension"                           "$(q "$D" "$KE|select(.name==\"KB_EMBEDDINGS_DIM\")|.value")" 384
eq "kb embeddings key is its own virtual key (Secret)" "$(q "$D" "$KE|select(.name==\"KB_EMBEDDINGS_API_KEY\")|.valueFrom.secretKeyRef|.name+\"/\"+.key")" kb-virtual-key/OPENAI_API_KEY
eq "kb pod is annotated for install.sh virtual key creation" "$(q "$D" "$KB|.metadata.annotations[\"openagentix.io/gateway-user\"]+\"/\"+.metadata.annotations[\"openagentix.io/gateway-key-secret\"]")" kb/kb-virtual-key
eq "kb runs non-root, read-only rootfs, no capabilities" "$(q "$D" "$KB|.spec.template.spec|[.securityContext.runAsNonRoot,.containers[0].securityContext.readOnlyRootFilesystem,.containers[0].securityContext.allowPrivilegeEscalation,(.containers[0].securityContext.capabilities.drop|join(\",\"))]|map(tostring)|join(\" \")")" "true true false ALL"
eq "kb probes: /healthz liveness, /readyz readiness"   "$(q "$D" "$KC|[.livenessProbe.httpGet.path,.readinessProbe.httpGet.path]|join(\",\")")" /healthz,/readyz
eq "kb has requests and limits"                        "$(q "$D" "$KC|.resources|(.requests.memory!=null) and (.limits.memory!=null) and (.requests.cpu!=null)")" true
eq "kb waits for its postgres in an initContainer (no crash-restart on first start)" "$(q "$D" "$KB|.spec.template.spec.initContainers|map(.name)|join(\",\")")" wait-for-postgres
eq "kb chunk size is tuned for the small embedding model (600 / overlap 100)" "$(q "$D" "[$KE|select(.name==\"KB_CHUNK_MAX_CHARS\" or .name==\"KB_CHUNK_OVERLAP\")|.value]|join(\"/\")")" 600/100
eq "kb pod template has no source-hash annotation by default" "$(q "$D" "$KB|.spec.template.metadata.annotations|has(\"openagentix.io/source-hash\")")" false
D3=$(docs --set-string knowledge.kb.sourceHash=abc123)
eq "kb sourceHash becomes a pod annotation (rolls the pod when the code changes)" "$(q "$D3" "$KB|.spec.template.metadata.annotations[\"openagentix.io/source-hash\"]")" abc123
eq "kb Service exposes 8080 only"                      "$(q "$D" '.[]|select(.kind=="Service" and .metadata.name=="kb")|[.spec.ports[].port]|join(",")')" 8080
PG='.[]|select(.kind=="StatefulSet" and .metadata.name=="kb-postgres")'
PC="$PG|.spec.template.spec.containers[0]"
eq "postgres image pinned by tag and digest"           "$(q "$D" "$PC|.image|test(\"^pgvector/pgvector:pg17@sha256:[0-9a-f]{64}\$\")")" true
eq "postgres password from a Secret, no literal"       "$(q "$D" "$PC|.env[]|select(.name==\"POSTGRES_PASSWORD\")|(.valueFrom.secretKeyRef.name+\"/\"+.valueFrom.secretKeyRef.key)+\" literal=\"+(has(\"value\")|tostring)")" "kb-postgres/POSTGRES_PASSWORD literal=false"
eq "postgres has a volumeClaimTemplate"                "$(q "$D" "$PG|.spec.volumeClaimTemplates|length")" 1
eq "postgres non-root with fsGroup"                    "$(q "$D" "$PG|.spec.template.spec.securityContext|(.runAsNonRoot|tostring)+\" \"+(.fsGroup|tostring)")" "true 999"
eq "postgres drops all capabilities"                   "$(q "$D" "$PC|.securityContext.capabilities.drop|join(\",\")")" ALL
eq "postgres readiness uses pg_isready"                "$(q "$D" "$PC|.readinessProbe.exec.command|join(\" \")|test(\"pg_isready\")")" true
eq "postgres has requests and limits"                  "$(q "$D" "$PC|.resources|(.requests.memory!=null) and (.limits.memory!=null)")" true
eq "postgres Service on 5432"                          "$(q "$D" '.[]|select(.kind=="Service" and .metadata.name=="kb-postgres")|.spec.ports[0].port')" 5432
EM='.[]|select(.kind=="Deployment" and .metadata.name=="kb-embeddings")'
EC="$EM|.spec.template.spec.containers[0]"
eq "embedding server image pinned by tag and digest"   "$(q "$D" "$EC|.image|test(\"^ghcr.io/ggml-org/llama.cpp:server-b[0-9]+@sha256:[0-9a-f]{64}\$\")")" true
eq "embedding server serves the default model (bge-small)" "$(q "$D" "$EC|.args|join(\" \")|test(\"bge-small-en-v1.5\")")" true
eq "embedding server runs in embeddings mode with cls pooling" "$(q "$D" "$EC|.args|join(\" \")|test(\"--embeddings\") and test(\"--pooling cls\")")" true
eq "embedding readiness is /health (200 only once the model is loaded)" "$(q "$D" "$EC|.readinessProbe.httpGet.path")" /health
eq "embedding server has a startup probe (model download)" "$(q "$D" "$EC|.startupProbe.httpGet.path")" /health
eq "embedding model cache is a PVC"                    "$(q "$D" "$EM|.spec.template.spec.volumes[]|select(.name==\"models\")|.persistentVolumeClaim.claimName")" kb-embeddings-models
eq "embedding server non-root, no capabilities"        "$(q "$D" "$EM|.spec.template.spec|[.securityContext.runAsNonRoot,(.containers[0].securityContext.capabilities.drop|join(\",\"))]|map(tostring)|join(\" \")")" "true ALL"
eq "embedding server has requests and limits"          "$(q "$D" "$EC|.resources|(.requests.memory!=null) and (.limits.memory!=null)")" true
eq "embedding strategy Recreate (RWO volume)"          "$(q "$D" "$EM|.spec.strategy.type")" Recreate
EG='.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="embed-default")'
eq "gateway model embed-default exists in the gateway ns" "$(q "$D" "$EG|.metadata.namespace")" agentgateway-system
eq "embed-default is an OpenAI-compatible provider at the embedding Service" "$(q "$D" "$EG|.spec.provider+\" \"+.spec.baseURL")" "OpenAI http://kb-embeddings.openagentix-knowledge.svc.cluster.local:8080/v1"
eq "embed-default attaches to the model gateway"       "$(q "$D" "$EG|.spec.parentRefs[0].name")" model-gateway
eq "embed-default carries no provider credential"      "$(q "$D" "$EG|.spec|has(\"policies\")")" false
eq "still exactly ONE AgentgatewayPolicy"              "$(count "$D" '.kind=="AgentgatewayPolicy"')" 1
ME='.[]|select(.kind=="MCPServerEntry")'
eq "kb is one more backend of the vMCP group"          "$(q "$D" "$ME|.spec.groupRef.name+\" \"+.metadata.namespace")" "tools mcp-tools"
eq "MCPServerEntry points at the kb /mcp endpoint"     "$(q "$D" "$ME|.spec.remoteUrl")" http://kb.openagentix-knowledge.svc.cluster.local:8080/mcp
eq "MCPServerEntry transport streamable-http"          "$(q "$D" "$ME|.spec.transport")" streamable-http
eq "MCPServerEntry allows the in-cluster endpoint"     "$(q "$D" "$ME|.spec.allowPrivateEndpoint")" true
eq "MCPServerEntry references an unauthenticated outgoing config" "$(q "$D" "[$ME|.spec.externalAuthConfigRef.name]|join(\"\")")" "$(q "$D" '.[]|select(.kind=="MCPExternalAuthConfig")|.metadata.name')"
eq "outgoing auth config type is unauthenticated"      "$(q "$D" '.[]|select(.kind=="MCPExternalAuthConfig")|.spec.type')" unauthenticated
eq "MCPServers are unchanged (still 2)"                "$(count "$D" '.kind=="MCPServer"')" 2
KP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-ingress")'
eq "kb policy selects the kb pod"                      "$(q "$D" "$KP|.spec.podSelector.matchLabels.app")" kb
eq "kb policy is ingress-only on 8080"                 "$(q "$D" "$KP|(.spec.policyTypes|join(\",\"))+\" \"+([.spec.ingress[].ports[].port]|unique|map(tostring)|join(\",\"))")" "Ingress 8080"
eq "kb MCP source is the vMCP pod in mcp-tools (pod-scoped)" "$(q "$D" "[$KP|.spec.ingress[].from[]|select(.podSelector.matchLabels.\"toolhive-name\"==\"tools\")|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]+\"/\"+.podSelector.matchLabels.app]|join(\",\")")" mcp-tools/virtualmcpserver
eq "kb policy: no namespace-wide or any-pod source by default" "$(q "$D" "[$KP|.spec.ingress[].from[]|select((.podSelector.matchLabels==null) or (.namespaceSelector==null))]|length")" 0
eq "kb policy: exactly one source by default (ingest is by port-forward)" "$(q "$D" "$KP|[.spec.ingress[].from[]]|length")" 1
PP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-postgres-ingress")'
eq "postgres accepts only the kb pod on 5432"          "$(q "$D" "$PP|([.spec.ingress[].from[]|.podSelector.matchLabels.app]|join(\",\"))+\" \"+([.spec.ingress[].ports[].port]|map(tostring)|join(\",\"))")" "kb 5432"
EP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-embeddings-ingress")'
eq "embeddings accept only the model gateway proxy pod" "$(q "$D" "[$EP|.spec.ingress[].from[]|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]+\"/\"+.podSelector.matchLabels[\"gateway.networking.k8s.io/gateway-name\"]]|join(\",\")")" agentgateway-system/model-gateway
eq "embeddings policy only on 8080"                    "$(q "$D" "$EP|[.spec.ingress[].ports[].port]|map(tostring)|join(\",\")")" 8080
echo "# knowledge base: agent wiring"
AT='.[]|select(.kind=="AgentTemplate" and .metadata.name=="assistant-template")'
eq "assistant gets the kb tools next to the existing ones" "$(q "$D" "$AT|.spec.tools[0].mcp.tools|length")" 8
eq "assistant kb tool names (prefix + kb tool)"        "$(q "$D" "$AT|[.spec.tools[0].mcp.tools[]|select(test(\"kb_\"))]|sort|join(\",\")")" knowledge_kb_get_document,knowledge_kb_list_collections,knowledge_kb_search
eq "assistant keeps the original tools"                "$(q "$D" "$AT|[.spec.tools[0].mcp.tools[]|select(test(\"^(execute_tool_script|fetch_fetch|osv_)\"))]|length")" 5
eq "system prompt tells it to search the knowledge base and cite titles" "$(q "$D" "$AT|.spec.systemPrompt|test(\"knowledge base\") and test(\"knowledge_kb_search\") and test(\"title\")")" true
eq "original prompt text is kept"                      "$(q "$D" "$AT|.spec.systemPrompt|test(\"say when you used one\")")" true
cat > "$(dirname "$0")/.noknow-agent.yaml" <<'YAML'
agents:
  - name: plain
    model: claude-haiku
    systemPrompt: "You are plain."
    tools: [{tools: [fetch_fetch]}]
YAML
D2=$(docs -f "$(dirname "$0")/.noknow-agent.yaml"); rm -f "$(dirname "$0")/.noknow-agent.yaml"
eq "agent without knowledge:true is not given kb tools" "$(q "$D2" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.tools|join(",")')" fetch_fetch
eq "agent without knowledge:true keeps its prompt"     "$(q "$D2" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt')" "You are plain."
echo "# knowledge base: switches"
D=$(with_agents '.[0].memory.enabled=false' --set knowledge.enabled=false)
eq "knowledge.enabled=false renders nothing in the knowledge ns" "$(count "$D" '.metadata.namespace=="openagentix-knowledge"')" 0
eq "knowledge.enabled=false: no embed-default, no MCPServerEntry, no MCPExternalAuthConfig" "$(count "$D" '.kind=="MCPServerEntry" or .kind=="MCPExternalAuthConfig" or (.kind=="AgentgatewayModel" and .metadata.name=="embed-default")')" 0
eq "knowledge.enabled=false: assistant keeps its original 5 tools" "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.tools|length')" 5
eq "knowledge.enabled=false: prompt has no knowledge text" "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt|test("knowledge")')" false
eq "knowledge.enabled=false: platform NetworkPolicies unchanged (4)" "$(count "$D" '.kind=="NetworkPolicy"')" 4
eq "knowledge.enabled=false: one model, one policy, 2 MCPServers" "$(count "$D" '.kind=="AgentgatewayModel" or .kind=="AgentgatewayPolicy" or .kind=="MCPServer"')" 4
eq "knowledge.enabled=false: no Deployment but the bridge" "$(count "$D" '.kind=="Deployment" or .kind=="StatefulSet"')" 1
D=$(docs --set mcp.enabled=false)
eq "mcp.enabled=false: no MCPServerEntry, kb still deployed" "$(q "$D" '[(.[]|select(.kind=="MCPServerEntry")),(.[]|select(.kind=="Deployment" and .metadata.name=="kb"))]|map(.kind)|join(",")')" Deployment
eq "mcp.enabled=false: agent keeps its 5 tools"      "$(q "$D" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.tools|length')" 5
eq "mcp.enabled=false: kb policy has no tool-gateway source" "$(q "$D" '[.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-ingress")|.spec.ingress[].from[]?]|length')" 0
D=$(docs --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false: no knowledge policies" "$(inns "$D" '.kind=="NetworkPolicy"')" 0
D=$(docs --set gateway.enabled=false)
eq "gateway.enabled=false: no embed-default model"     "$(count "$D" '.kind=="AgentgatewayModel"')" 0
D=$(docs --set knowledge.embeddings.viaGateway=false)
eq "direct mode: kb calls the embedding Service"       "$(q "$D" "$KE|select(.name==\"KB_EMBEDDINGS_URL\")|.value")" http://kb-embeddings.openagentix-knowledge.svc.cluster.local:8080/v1
eq "direct mode: model is the served model name"       "$(q "$D" "$KE|select(.name==\"KB_EMBEDDINGS_MODEL\")|.value")" bge-small-en-v1.5
eq "direct mode: no API key env, no gateway model"     "$(q "$D" "[$KE|select(.name==\"KB_EMBEDDINGS_API_KEY\")]|length")/$(count "$D" '.kind=="AgentgatewayModel" and .metadata.name=="embed-default"')" 0/0
eq "direct mode: embeddings accept only the kb pod"    "$(q "$D" "[$EP|.spec.ingress[].from[]|.podSelector.matchLabels.app]|join(\",\")")" kb
eq "direct mode: kb has no virtual-key annotation"     "$(q "$D" "$KB|.metadata.annotations|has(\"openagentix.io/gateway-user\")")" false
D=$(docs --set knowledge.embeddings.enabled=false)
eq "embeddings.enabled=false: lexical-only, no embedding objects" "$(q "$D" "[$KE|select(.name|test(\"^KB_EMBEDDINGS\"))]|length")/$(inns "$D" '.metadata.name|test("embeddings")')/$(count "$D" '.kind=="AgentgatewayModel" and .metadata.name=="embed-default"')" 0/0/0
D=$(docs --set knowledge.embeddings.enabled=false --set knowledge.kb.embeddings.url=https://api.example.com/v1 --set knowledge.kb.embeddings.model=text-embedding-3-small --set knowledge.kb.embeddings.dim=1536 --set knowledge.kb.embeddings.apiKeySecret.name=hosted-key --set knowledge.kb.embeddings.apiKeySecret.key=KEY)
eq "hosted embedder: url, model, dim from values"      "$(q "$D" "[$KE|select(.name==\"KB_EMBEDDINGS_URL\" or .name==\"KB_EMBEDDINGS_MODEL\" or .name==\"KB_EMBEDDINGS_DIM\")|.value]|join(\" \")")" "https://api.example.com/v1 text-embedding-3-small 1536"
eq "hosted embedder: key from the named Secret"        "$(q "$D" "$KE|select(.name==\"KB_EMBEDDINGS_API_KEY\")|.valueFrom.secretKeyRef|.name+\"/\"+.key")" hosted-key/KEY
D=$(docs --set knowledge.postgres.enabled=false)
eq "external database: no StatefulSet/Service/policy for postgres" "$(inns "$D" '.metadata.name|test("postgres")')" 0
eq "external database: no wait-for-postgres initContainer" "$(q "$D" "$KB|.spec.template.spec|has(\"initContainers\")")" false
eq "external database: kb still reads the URL from its Secret" "$(q "$D" "$KE|select(.name==\"KB_DATABASE_URL\")|.valueFrom.secretKeyRef.name")" kb-database
D=$(docs --set 'knowledge.kb.ingestFrom[0].namespace=ci' --set 'knowledge.kb.ingestFrom[0].podLabels.app=ingest')
eq "ingestFrom adds a pod-scoped source for in-cluster ingestion" "$(q "$D" "[$KP|.spec.ingress[].from[]|select(.podSelector.matchLabels.app==\"ingest\")|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]]|join(\",\")")" ci
eq "dimension above pgvector's HNSW limit (2000) fails the render" "$([ -n "$(render_err --set knowledge.embeddings.model.dim=4096)" ] && echo failed || echo rendered)" failed
eq "embeddings url without model fails the render"     "$([ -n "$(render_err --set knowledge.kb.embeddings.url=http://x/v1 --set knowledge.embeddings.enabled=false)" ] && echo failed || echo rendered)" failed

echo "# long-term memory (kagent Harness spec.kagent.memory)"
D=$(docs)
HM='.[]|select(.kind=="Harness" and .metadata.name=="assistant-harness")'
MC='.[]|select(.kind=="ModelConfig" and .metadata.name=="gateway-embed-memory")'
MD='.[]|select(.kind=="Deployment" and .metadata.name=="memory-embeddings")'
eq "assistant opts in: harness has memory.modelConfigRef"  "$(q "$D" "$HM|.spec.kagent.memory.modelConfigRef|.name+\"/\"+.namespace")" gateway-embed-memory/kagent
eq "assistant memory ttlDays from values"              "$(q "$D" "$HM|.spec.kagent.memory.ttlDays")" 30
eq "embedding ModelConfig rendered exactly once"       "$(count "$D" '.kind=="ModelConfig" and .metadata.name=="gateway-embed-memory"')" 1
eq "embedding ModelConfig: provider OpenAI, model embed-memory" "$(q "$D" "$MC|.spec.provider+\"/\"+.spec.model")" OpenAI/embed-memory
eq "embedding ModelConfig has its own virtual key secret" "$(q "$D" "$MC|.spec.apiKeySecret+\"/\"+.spec.apiKeySecretKey")" memory-virtual-key/OPENAI_API_KEY
eq "embedding ModelConfig annotated so install.sh creates its key (user memory)" "$(q "$D" "$MC|.metadata.annotations[\"openagentix.io/agent\"]")" memory
eq "embedding baseUrl is a DIFFERENT origin than the chat ModelConfig (kagent binds one credential per origin)" "$(q "$D" "$MC|.spec.openAI.baseUrl")" http://model-gateway-memory.agentgateway-system.svc.cluster.local/v1
eq "chat ModelConfig origin unchanged"                 "$(q "$D" '.[]|select(.kind=="ModelConfig" and .metadata.name=="gateway-claude-haiku")|.spec.openAI.baseUrl')" http://model-gateway.agentgateway-system.svc.cluster.local/v1
eq "alias Service is ExternalName to the gateway"      "$(q "$D" '.[]|select(.kind=="Service" and .metadata.name=="model-gateway-memory")|.spec.type+"/"+.spec.externalName')" ExternalName/model-gateway.agentgateway-system.svc.cluster.local
eq "gateway model embed-memory -> memory-embeddings (OpenAI-compatible)" "$(q "$D" '.[]|select(.kind=="AgentgatewayModel" and .metadata.name=="embed-memory")|.spec.provider+" "+.spec.baseURL')" "OpenAI http://memory-embeddings.openagentix-memory.svc.cluster.local:8080/v1"
eq "embedding server is a 768-dimension model (kagent fixes 768)" "$(q "$D" "$MD|.spec.template.spec.containers[0].args|index(\"CompendiumLabs/bge-base-en-v1.5-gguf:Q8_0\")!=null")" true
eq "embedding server image is digest pinned"           "$(q "$D" "$MD|.spec.template.spec.containers[0].image|test(\"@sha256:[0-9a-f]{64}\$\")")" true
eq "embedding server lives in openagentix-memory"      "$(q "$D" "$MD|.metadata.namespace")" openagentix-memory
eq "embedding server has resource limits"              "$(q "$D" "$MD|.spec.template.spec.containers[0].resources.limits.memory")" 512Mi
eq "embedding server ingress only from the gateway proxy" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="memory-embeddings-ingress")|[.spec.ingress[].from[].podSelector.matchLabels["gateway.networking.k8s.io/gateway-name"]]|join(",")')" model-gateway
eq "memory objects carry no Secret"                    "$(count "$D" '.kind=="Secret"')" 0
cat > "$(dirname "$0")/.mem-agents.yaml" <<'YAML'
agents:
  - name: alpha
    model: claude-haiku
    systemPrompt: "You are alpha, a terse assistant for testing."
    memory: {enabled: true}
  - name: beta
    model: claude-haiku
    systemPrompt: "You are beta, a terse assistant for testing."
  - name: gamma
    model: claude-haiku
    systemPrompt: "You are gamma, a terse assistant for testing."
    memory: {enabled: false, ttlDays: 5}
YAML
D=$(docs -f "$(dirname "$0")/.mem-agents.yaml"); rm -f "$(dirname "$0")/.mem-agents.yaml"
eq "only the opted-in agent has memory"                "$(q "$D" '[.[]|select(.kind=="Harness" and (.spec.kagent|has("memory")))|.metadata.name]|join(",")')" alpha-harness
eq "agents without the block render spec.kagent: {}"   "$(q "$D" '[.[]|select(.kind=="Harness" and .metadata.name!="alpha-harness")|.spec.kagent|length]|join(",")')" 0,0
eq "ttlDays omitted when not set (kagent default)"     "$(q "$D" '.[]|select(.kind=="Harness" and .metadata.name=="alpha-harness")|.spec.kagent.memory|has("ttlDays")')" false
eq "one embedding stack for any number of agents"      "$(count "$D" '(.kind=="ModelConfig" and .metadata.name=="gateway-embed-memory") or (.kind=="Deployment" and .metadata.name=="memory-embeddings")')" 2
D=$(with_agents '.[0].memory.enabled=false')
eq "variant renders (guards the tests below against vacuous passes)" "$(q "$D" 'length>0')" true
eq "memory disabled on every agent: no memory objects at all" "$(count "$D" '.metadata.namespace=="openagentix-memory" or .metadata.name=="gateway-embed-memory" or .metadata.name=="embed-memory" or .metadata.name=="model-gateway-memory" or (.kind=="Harness" and (.spec.kagent|has("memory")))')" 0
D=$(with_agents 'map(del(.memory))')
eq "variant without the block renders"                 "$(q "$D" 'length>0')" true
eq "no memory block: no memory objects at all"         "$(count "$D" '.metadata.namespace=="openagentix-memory" or .metadata.name=="gateway-embed-memory" or .metadata.name=="embed-memory" or .metadata.name=="model-gateway-memory" or (.kind=="Harness" and (.spec.kagent|has("memory")))')" 0
D=$(docs --set kagent.enabled=false)
eq "kagent.enabled=false: no memory objects"           "$(count "$D" '.metadata.namespace=="openagentix-memory" or .metadata.name=="embed-memory"')" 0
D=$(docs --set knowledge.enabled=false)
eq "memory is independent of knowledge.enabled"        "$(count "$D" '.kind=="Deployment" and .metadata.name=="memory-embeddings"')" 1
D=$(docs --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false: no memory policy"     "$(count "$D" '.kind=="NetworkPolicy" and .metadata.namespace=="openagentix-memory"')" 0
eq "embedding dimension other than 768 fails the render (kagent stores vector(768))" "$([ -n "$(render_err --set memory.embeddings.model.dim=384)" ] && echo failed || echo rendered)" failed
eq "memory without the gateway fails the render"       "$([ -n "$(render_err --set gateway.enabled=false)" ] && echo failed || echo rendered)" failed
eq "memory prompt hint is appended for opted-in agents" "$(q "$(docs)" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt|test("save_memory")')" true
eq "memory prompt saves facts worth keeping, not only on request" "$(q "$(docs)" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt|test("worth keeping across conversations")')" true
eq "memory prompt has no save-only-on-request rule" "$(q "$(docs)" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt|test("Do not save anything the user merely mentions")')" false
eq "memory prompt still forbids secrets"            "$(q "$(docs)" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt|test("Never store passwords")')" true

echo "# bridge user identity and rollout"
D=$(docs)
BE='.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]'
eq "bridge: no A2A_USER_ID_PREFIX env by default (the bridge default telegram: applies)" "$(q "$D" "[$BE|select(.name==\"A2A_USER_ID_PREFIX\")]|length")" 0
D=$(docs --set-string bridge.userIdPrefix=botB:)
eq "bridge.userIdPrefix becomes A2A_USER_ID_PREFIX"    "$(q "$D" "$BE|select(.name==\"A2A_USER_ID_PREFIX\")|.value")" botB:
BT='.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.metadata'
D=$(docs)
eq "bridge pod template has no source-hash annotation by default" "$(q "$D" "$BT|(.annotations//{})|has(\"openagentix.io/source-hash\")")" false
D=$(docs --set-string bridge.sourceHash=abc123)
eq "bridge sourceHash becomes a pod annotation (rolls the pod when bridge code changes, tag stays dev)" "$(q "$D" "$BT|.annotations[\"openagentix.io/source-hash\"]")" abc123

echo "# extra A2A callers of the kagent controller"
D=$(docs)
eq "extraA2ACallers defaults to empty"                 "$(yq -c .networkPolicy.extraA2ACallers "$CHART/values.yaml")" '[]'
EX="$(dirname "$0")/.extra-callers.yaml"
cat > "$EX" <<'YAML'
networkPolicy:
  extraA2ACallers:
    - namespace: agent-kourier
      podLabels: {app.kubernetes.io/name: agent-kourier}
    - namespace: other-ns
YAML
D2=$(docs -f "$EX"); rm -f "$EX"
eq "default render: controller policy has 3 sources on 8083" "$(q "$D" "$CP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]]|length")" 3
eq "extraA2ACallers adds two sources to 8083"          "$(q "$D2" "$CP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]]|length")" 5
eq "extra caller is scoped by namespace AND pod labels" "$(q "$D2" "$CP|[.spec.ingress[].from[]?|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"agent-kourier\")|.podSelector.matchLabels[\"app.kubernetes.io/name\"]]|join(\",\")")" agent-kourier
eq "extra caller without podLabels admits its whole namespace" "$(q "$D2" "$CP|[.spec.ingress[].from[]?|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"other-ns\")|has(\"podSelector\")]|join(\",\")")" false
eq "extra callers do not open the other ports"         "$(q "$D2" "$CP|[.spec.ingress[]|select(has(\"from\")|not)|.ports[]|(.port|tostring)+\"-\"+(.endPort|tostring)]|sort|join(\",\")")" 1-8082,8084-65535
eq "default policy is byte-identical when the list is empty" "$(q "$D" "$CP|.spec.ingress|length")" 2

echo "# channels and triggers (Agent Kourier, opt-in)"
KAPI="--api-versions agentkourier.dev/v1alpha1"
CHF="$(dirname "$0")/.channels.yaml"
cat > "$CHF" <<'YAML'
channels:
  kourier:
    enabled: true
  connections:
    - name: orders-hook
      platform: webhook
      existingSecret: orders-hook-webhook
      webhook:
        identity: orders-system
        verify: {scheme: hmac-sha256, header: X-Sig, prefix: "sha256="}
        channel: {from: [/channel]}
        actor: {from: [/user/login]}
        thread: {field: conversation, prefix: conv-}
        delivery: {header: X-Delivery}
        fields:
          - {name: event, from: [/event], kind: id}
          - {name: conversation, from: [/conversation], kind: id}
    - name: team-slack
      platform: slack
      existingSecret: team-slack-tokens
      slack: {mode: socket}
  bindings:
    - name: orders-assistant
      connection: orders-hook
      channel: orders
      agent: assistant
      triggers:
        - type: webhookEvent
          match: {event: '^order\.failed$'}
          promptTemplate: "Check order {{ .Fields.conversation }}."
          limits: {rateLimit: {maxRuns: 5, per: 1h, maxConcurrent: 1}, maxRunsPerDay: 20}
    - name: eng-slack
      connection: team-slack
      channel: C0123456789
      agent: assistant
      userId: slack-eng
      output: final
      triggers:
        - {type: mention}
    - name: eng-default
      connection: team-slack
      channel: C0999999999
      agent: assistant
      triggers:
        - {type: personMessage}
YAML
D=$(docs)
eq "default render has no agentkourier.dev objects"    "$(count "$D" '(.apiVersion|startswith("agentkourier.dev"))')" 0
eq "default render has no channels namespace objects"  "$(count "$D" '.metadata.namespace=="openagentix-channels"')" 0
eq "channels.kourier.enabled defaults to false"        "$(yq -c .channels.kourier.enabled "$CHART/values.yaml")" false
eq "channels.connections and bindings default to empty" "$(yq -c '[.channels.connections,.channels.bindings]' "$CHART/values.yaml")" '[[],[]]'
H0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
H1=$(helm template openagentix "$CHART" -n openagentix-system -f <(sed 's/enabled: true/enabled: false/' "$CHF") $KAPI 2>&1 | shasum -a 256)
eq "enabled=false with connections/bindings defined renders byte-identical to the defaults" "$H1" "$H0"
D=$(docs -f "$CHF")
eq "enabled but CRDs absent (no api-versions): no Kourier custom resources" "$(count "$D" '(.apiVersion|startswith("agentkourier.dev"))')" 0
eq "enabled but CRDs absent: Role and marker ConfigMap still render" "$(count "$D" '.metadata.namespace=="openagentix-channels"')" 3
D=$(docs -f "$CHF" $KAPI)
eq "AgentBackend, 2 ChatConnections, 3 Bindings"       "$(q "$D" '[.[]|select(.apiVersion|startswith("agentkourier.dev"))|.kind]|sort|join(",")')" AgentBackend,Binding,Binding,Binding,ChatConnection,ChatConnection
eq "CRs live in channels.kourier.namespace"            "$(q "$D" '[.[]|select(.apiVersion|startswith("agentkourier.dev"))|.metadata.namespace]|unique|join(",")')" openagentix-channels
AB='.[]|select(.kind=="AgentBackend")'
eq "AgentBackend dialect kagent-v1"                    "$(q "$D" "$AB|.spec.dialect")" kagent-v1
eq "AgentBackend url derived from kagent values"       "$(q "$D" "$AB|.spec.url")" http://kagent-controller.kagent.svc.cluster.local:8083
CW='.[]|select(.kind=="ChatConnection" and .metadata.name=="orders-hook")'
CS='.[]|select(.kind=="ChatConnection" and .metadata.name=="team-slack")'
eq "webhook connection: platform and Secret reference" "$(q "$D" "$CW|.spec.platform+\" \"+.spec.credentialsSecretRef.name")" "webhook orders-hook-webhook"
eq "webhook settings pass through faithfully"          "$(q "$D" "$CW|.spec.webhook|[.identity,.verify.scheme,.verify.header,.verify.prefix,.channel.from[0],.actor.from[0],.thread.field,.thread.prefix,.delivery.header,(.fields|length)]|join(\" \")")" "orders-system hmac-sha256 X-Sig sha256= /channel /user/login conversation conv- X-Delivery 2"
eq "webhook connection has no slack block"             "$(q "$D" "$CW|.spec|has(\"slack\")")" false
eq "slack connection: platform, Secret, mode"          "$(q "$D" "$CS|.spec.platform+\" \"+.spec.credentialsSecretRef.name+\" \"+.spec.slack.mode")" "slack team-slack-tokens socket"
eq "slack connection has no webhook block"             "$(q "$D" "$CS|.spec|has(\"webhook\")")" false
BW='.[]|select(.kind=="Binding" and .metadata.name=="orders-assistant")'
BS='.[]|select(.kind=="Binding" and .metadata.name=="eng-slack")'
eq "binding: agent ref (name, namespace, backend)"     "$(q "$D" "$BW|.spec.agent|.name+\" \"+.namespace+\" \"+.backendRef.name")" "assistant kagent kagent"
eq "binding: connection and channel"                   "$(q "$D" "$BW|.spec.chat|.connectionRef.name+\" \"+.channel")" "orders-hook orders"
eq "binding: default userId is kourier:<binding name>" "$(q "$D" "$BW|.spec.identity.userId")" kourier:orders-assistant
eq "binding: explicit userId wins"                     "$(q "$D" "$BS|.spec.identity.userId")" slack-eng
eq "binding on a webhook connection defaults to output none" "$(q "$D" "$BW|.spec.chat.output")" none
eq "binding: explicit output honoured"                 "$(q "$D" "$BS|.spec.chat.output")" final
eq "binding on slack without output omits it (Kourier default live)" "$(q "$D" '.[]|select(.kind=="Binding" and .metadata.name=="eng-default")|.spec.chat|has("output")')" false
eq "webhook trigger passes through (type, match, template, limits)" "$(q "$D" "$BW|.spec.chat.triggers[0]|[.type,.match.event,.promptTemplate,.limits.rateLimit.maxRuns,.limits.maxRunsPerDay]|map(tostring)|join(\"|\")")" 'webhookEvent|^order\.failed$|Check order {{ .Fields.conversation }}.|5|20'
eq "mention trigger passes through"                    "$(q "$D" "$BS|.spec.chat.triggers[0].type")" mention
RL='.[]|select(.kind=="Role" and .metadata.namespace=="openagentix-channels")'
eq "Role grants list+watch on exactly the connection Secrets" "$(q "$D" "$RL|.rules|map((.resources|join(\",\"))+\":\"+(.resourceNames|sort|join(\",\"))+\":\"+(.verbs|sort|join(\",\")))|join(\";\")")" "secrets:orders-hook-webhook,team-slack-tokens:list,watch"
eq "RoleBinding grants it to the broker ServiceAccount"  "$(q "$D" '.[]|select(.kind=="RoleBinding" and .metadata.namespace=="openagentix-channels")|.subjects[0]|.kind+" "+.name+" "+.namespace')" "ServiceAccount agent-kourier agent-kourier"
eq "marker ConfigMap names the team and broker namespaces" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-channels")|.data.namespace+" "+.data.brokerNamespace')" "openagentix-channels agent-kourier"
eq "marker ConfigMap carries the broker egress rule to the controller" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-channels")|.data.brokerEgress|fromjson|.[0]|[.to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"],.to[0].podSelector.matchLabels["app.kubernetes.io/component"],(.ports[0].port|tostring)]|join(" ")')" "kagent controller 8083"
eq "no Secret objects, no data/stringData"             "$(count "$D" '.kind=="Secret" or (has("data") and .kind!="ConfigMap") or has("stringData")')" 0
S1=$(docs -f "$CHF" $KAPI --set channels.connections[0].token=SENTINEL-CH-777)
eq "stray token value is never rendered"               "$(q "$S1" 'tostring|contains("SENTINEL-CH-777")')" false
echo "# channels: validation and network policy"
EB='--set channels.bindings[0].agent=ghost'
eq "binding to an unknown agent fails the render"      "$([ -n "$(render_err -f "$CHF" $KAPI $EB)" ] && echo failed || echo rendered)" failed
eq "the failure names the agent and lists the valid ones" "$(render_err -f "$CHF" $KAPI $EB | command grep -c 'binding "orders-assistant": agent "ghost" is not in agents\[\].*assistant')" 1
eq "binding to an unknown connection fails the render" "$([ -n "$(render_err -f "$CHF" $KAPI --set channels.bindings[0].connection=nope)" ] && echo failed || echo rendered)" failed
eq "unknown platform fails the render"                 "$([ -n "$(render_err -f "$CHF" $KAPI --set channels.connections[0].platform=irc)" ] && echo failed || echo rendered)" failed
eq "connection without existingSecret fails the render" "$([ -n "$(render_err -f "$CHF" $KAPI --set channels.connections[0].existingSecret=)" ] && echo failed || echo rendered)" failed
eq "channels enabled without kagent fails the render"  "$([ -n "$(render_err -f "$CHF" $KAPI --set kagent.enabled=false)" ] && echo failed || echo rendered)" failed
eq "an invalid binding is not checked while the block is disabled" "$([ -z "$(render_err -f "$CHF" $KAPI $EB --set channels.kourier.enabled=false)" ] && echo rendered || echo failed)" rendered
KP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-controller")'
Dd=$(docs)
eq "controller policy has no Kourier peer by default"  "$(q "$Dd" "$KP|[.spec.ingress[].from[]?|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"agent-kourier\")]|length")" 0
eq "enabled: controller policy admits the Kourier pod (namespace AND pod labels)" "$(q "$D" "$KP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"agent-kourier\")|.podSelector.matchLabels[\"app.kubernetes.io/name\"]]|join(\",\")")" agent-kourier
eq "enabled: 8083 has one more source than the default (4)" "$(q "$D" "$KP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]]|length")" 4
EXC="$(dirname "$0")/.extra2.yaml"
printf 'networkPolicy:\n  extraA2ACallers:\n    - namespace: other-ns\n' > "$EXC"
D2=$(docs -f "$CHF" -f "$EXC" $KAPI); rm -f "$EXC"
eq "extraA2ACallers still works next to the Kourier peer (5)" "$(q "$D2" "$KP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]]|length")" 5
D3=$(docs -f "$CHF" $KAPI --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false: no controller policy, so no peer" "$(count "$D3" '.kind=="NetworkPolicy"')" 0
D4=$(docs -f "$CHF" $KAPI --set channels.connections=null --set channels.bindings=null)
eq "no connections: no Role, no Kourier connection/binding" "$(count "$D4" '.kind=="Role" or .kind=="ChatConnection" or .kind=="Binding"')" 0
rm -f "$CHF"

echo "# schedules (CronJobs that call an agent over A2A)"
SCF="$(dirname "$0")/.schedules.yaml"
cat > "$SCF" <<'YAML'
schedules:
  - name: daily-brief
    agent: assistant
    schedule: "0 8 * * 1-5"
    timeZone: Europe/Berlin
    prompt: |
      Summarise the open vulnerabilities in lodash 4.17.20.
      Keep it short.
  - name: quarter-hour
    agent: assistant
    schedule: "*/15 * * * *"
    prompt: "Say ok."
    userId: custom-user
    timeout: 2m
    suspend: true
    concurrencyPolicy: Replace
    historyLimits: {successful: 1, failed: 5}
    backoffLimit: 1
    startingDeadlineSeconds: 120
    resources:
      requests: {cpu: 10m, memory: 20Mi}
      limits: {cpu: 50m, memory: 40Mi}
YAML
D=$(docs)
eq "schedules default to an empty list"                "$(yq -c .schedules "$CHART/values.yaml")" '[]'
eq "default render has no CronJob"                     "$(count "$D" '.kind=="CronJob"')" 0
eq "default render has no schedules namespace objects" "$(count "$D" '.metadata.namespace=="openagentix-schedules"')" 0
eq "default controller policy has no schedule peer"    "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-controller")|[.spec.ingress[].from[]?|select(.namespaceSelector.matchLabels["kubernetes.io/metadata.name"]=="openagentix-schedules")]|length')" 0
D=$(docs -f "$SCF")
CJ='.[]|select(.kind=="CronJob" and .metadata.name=="daily-brief")'
CJ2='.[]|select(.kind=="CronJob" and .metadata.name=="quarter-hour")'
CP2='.template.spec'
POD="$CJ|.spec.jobTemplate.spec.template.spec"
eq "one CronJob per schedule"                          "$(count "$D" '.kind=="CronJob"')" 2
eq "one prompt ConfigMap per schedule"                 "$(q "$D" '[.[]|select(.kind=="ConfigMap" and .metadata.namespace=="openagentix-schedules")|.metadata.name]|sort|join(",")')" schedule-daily-brief,schedule-quarter-hour
eq "everything lives in openagentix-schedules"         "$(q "$D" '[.[]|select(.kind=="CronJob" or (.kind=="ConfigMap" and (.metadata.name|startswith("schedule-")))) |.metadata.namespace]|unique|join(",")')" openagentix-schedules
eq "cron expression and time zone pass through"        "$(q "$D" "$CJ|.spec.schedule+\" \"+.spec.timeZone")" "0 8 * * 1-5 Europe/Berlin"
eq "no timeZone key when none is set"                  "$(q "$D" "$CJ2|.spec|has(\"timeZone\")")" false
eq "concurrencyPolicy defaults to Forbid"              "$(q "$D" "$CJ|.spec.concurrencyPolicy")" Forbid
eq "concurrencyPolicy can be set"                      "$(q "$D" "$CJ2|.spec.concurrencyPolicy")" Replace
eq "suspend defaults to false"                         "$(q "$D" "$CJ|.spec.suspend")" false
eq "suspend can be set"                                "$(q "$D" "$CJ2|.spec.suspend")" true
eq "history limits default to 3 and 3"                 "$(q "$D" "$CJ|[.spec.successfulJobsHistoryLimit,.spec.failedJobsHistoryLimit]|map(tostring)|join(\",\")")" 3,3
eq "history limits can be set"                         "$(q "$D" "$CJ2|[.spec.successfulJobsHistoryLimit,.spec.failedJobsHistoryLimit]|map(tostring)|join(\",\")")" 1,5
eq "startingDeadlineSeconds defaults to 300"           "$(q "$D" "$CJ|.spec.startingDeadlineSeconds")" 300
eq "startingDeadlineSeconds can be set"                "$(q "$D" "$CJ2|.spec.startingDeadlineSeconds")" 120
eq "backoffLimit defaults to 0 (a failed agent run is never retried blindly)" "$(q "$D" "$CJ|.spec.jobTemplate.spec.backoffLimit")" 0
eq "backoffLimit can be set"                           "$(q "$D" "$CJ2|.spec.jobTemplate.spec.backoffLimit")" 1
eq "finished Jobs are removed after a day"             "$(q "$D" "$CJ|.spec.jobTemplate.spec.ttlSecondsAfterFinished")" 86400
eq "activeDeadlineSeconds is the timeout plus 60 (default 300s)" "$(q "$D" "$CJ|.spec.jobTemplate.spec.activeDeadlineSeconds")" 360
eq "activeDeadlineSeconds follows a custom timeout (2m)" "$(q "$D" "$CJ2|.spec.jobTemplate.spec.activeDeadlineSeconds")" 180
eq "pod never restarts in place"                       "$(q "$D" "$POD|.restartPolicy")" Never
eq "image comes from scheduling.image"                 "$(q "$D" "$POD|.containers[0].image")" openagentix/a2a-call:dev
eq "image is not pulled when present (kind-loaded)"    "$(q "$D" "$POD|.containers[0].imagePullPolicy")" IfNotPresent
eq "A2A_URL targets the schedule's agent on the controller" "$(q "$D" "$POD|.containers[0].env[]|select(.name==\"A2A_URL\")|.value")" http://kagent-controller.kagent.svc.cluster.local:8083/agents/kagent/assistant
eq "user id defaults to schedule:<name>"               "$(q "$D" "$POD|.containers[0].env[]|select(.name==\"A2A_USER_ID\")|.value")" schedule:daily-brief
eq "user id can be set"                                "$(q "$D" "$CJ2|.spec.jobTemplate.spec.template.spec.containers[0].env[]|select(.name==\"A2A_USER_ID\")|.value")" custom-user
eq "A2A_TIMEOUT defaults to 300s"                      "$(q "$D" "$POD|.containers[0].env[]|select(.name==\"A2A_TIMEOUT\")|.value")" 300s
eq "A2A_TIMEOUT can be set"                            "$(q "$D" "$CJ2|.spec.jobTemplate.spec.template.spec.containers[0].env[]|select(.name==\"A2A_TIMEOUT\")|.value")" 2m
eq "the answer is not printed (PRINT_ANSWER unset)"    "$(q "$D" "$POD|[.containers[0].env[]|select(.name==\"PRINT_ANSWER\")]|length")" 0
eq "prompt is read from a file"                        "$(q "$D" "$POD|.containers[0].env[]|select(.name==\"PROMPT_FILE\")|.value")" /etc/schedule/prompt.txt
eq "the prompt file comes from the schedule's ConfigMap" "$(q "$D" "$POD|.volumes[0].configMap.name")" schedule-daily-brief
eq "the prompt volume is mounted read-only"            "$(q "$D" "$POD|.containers[0].volumeMounts[0]|[.mountPath,.readOnly]|map(tostring)|join(\" \")")" "/etc/schedule true"
eq "ConfigMap holds the prompt text verbatim"          "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="schedule-daily-brief")|.data["prompt.txt"]')" "$(printf 'Summarise the open vulnerabilities in lodash 4.17.20.\nKeep it short.')"
eq "no service account token in the pod"               "$(q "$D" "$POD|.automountServiceAccountToken")" false
eq "pod runs as non-root"                              "$(q "$D" "$POD|.securityContext|[.runAsNonRoot,.runAsUser,.runAsGroup]|map(tostring)|join(\",\")")" true,65532,65532
eq "seccomp RuntimeDefault"                            "$(q "$D" "$POD|.securityContext.seccompProfile.type")" RuntimeDefault
eq "container: no privilege escalation, read-only root, all caps dropped" "$(q "$D" "$POD|.containers[0].securityContext|[.allowPrivilegeEscalation,.readOnlyRootFilesystem,(.capabilities.drop|join(\",\"))]|map(tostring)|join(\" \")")" "false true ALL"
eq "default resources are small"                       "$(q "$D" "$POD|.containers[0].resources|[.requests.memory,.limits.memory]|join(\",\")")" 16Mi,32Mi
eq "resources can be set"                              "$(q "$D" "$CJ2|.spec.jobTemplate.spec.template.spec.containers[0].resources.limits.memory")" 40Mi
eq "pods carry the label the network policies select"  "$(q "$D" "$CJ|.spec.jobTemplate.spec.template.metadata.labels[\"openagentix.io/component\"]")" schedule
eq "pod template carries no source hash by default"    "$(q "$D" "$CJ|.spec.jobTemplate.spec.template.metadata|has(\"annotations\")")" false
D1=$(docs -f "$SCF" --set-string scheduling.sourceHash=abc123)
eq "scheduling.sourceHash is stamped on the pod template" "$(q "$D1" "$CJ|.spec.jobTemplate.spec.template.metadata.annotations[\"openagentix.io/source-hash\"]")" abc123
eq "no Secret objects, no stringData"                  "$(count "$D" '.kind=="Secret" or has("stringData")')" 0
echo "# schedules: network policy"
KP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-controller")'
eq "controller policy admits the schedule pods: namespace AND pod label" "$(q "$D" "$KP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"openagentix-schedules\")|.podSelector.matchLabels[\"openagentix.io/component\"]]|join(\",\")")" schedule
eq "8083 has exactly one more source than the default (4)" "$(q "$D" "$KP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]]|length")" 4
eq "the other ports stay as before"                    "$(q "$D" "$KP|[.spec.ingress[]|select(has(\"from\")|not)|.ports[]|(.port|tostring)+\"-\"+(.endPort|tostring)]|sort|join(\",\")")" 1-8082,8084-65535
EP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-schedules-egress")'
eq "egress policy selects exactly the schedule pods"   "$(q "$D" "$EP|.metadata.namespace+\" \"+(.spec.podSelector.matchLabels|tojson)")" 'openagentix-schedules {"openagentix.io/component":"schedule"}'
eq "egress policy restricts Egress only"               "$(q "$D" "$EP|.spec.policyTypes|join(\",\")")" Egress
eq "egress: DNS (udp+tcp 53) to CoreDNS in kube-system" "$(q "$D" "$EP|.spec.egress[0]|[(.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]),(.to[0].podSelector.matchLabels[\"k8s-app\"]),([.ports[]|.protocol+(.port|tostring)]|sort|join(\"+\"))]|join(\" \")")" "kube-system kube-dns TCP53+UDP53"
eq "egress: the kagent controller pod on 8083 only"    "$(q "$D" "$EP|.spec.egress[1]|[.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"],.to[0].podSelector.matchLabels[\"app.kubernetes.io/component\"],(.ports|map(.protocol+(.port|tostring))|join(\"+\"))]|join(\" \")")" "kagent controller TCP8083"
eq "egress policy has exactly two rules"               "$(q "$D" "$EP|.spec.egress|length")" 2
D3=$(docs -f "$SCF" --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false: no policies for schedules either" "$(count "$D3" '.kind=="NetworkPolicy"')" 0
eq "networkPolicy.enabled=false: the CronJobs still render" "$(count "$D3" '.kind=="CronJob"')" 2
echo "# schedules: validation"
bad_sched() { # <jq-free yq edit applied to the first schedule>  -> prints helm's error
  local f="$(dirname "$0")/.sched-bad.yaml"
  yq -y "$1" "$SCF" > "$f"; render_err -f "$f"; rm -f "$f"
}
fails() { [ -n "$1" ] && echo failed || echo rendered; }
E=$(bad_sched '.schedules[0].agent="ghost"')
eq "unknown agent fails the render"                    "$(fails "$E")" failed
eq "the failure names the schedule, the agent and the valid agents" "$(printf '%s' "$E" | command grep -c 'schedule "daily-brief": agent "ghost" is not in agents\[\].*assistant')" 1
for cron in "0 8 * *" "0 8 * * * *" "61 8 * * *" "* 24 * * *" "* * 0 * *" "* * 32 * *" "* * * 13 *" "* * * * 8" "every day" "*/0 * * * *" "0 8 * * 1-" "0 8 * * 1;2" ""; do
  eq "invalid cron rejected: '$cron'"                  "$(fails "$(bad_sched ".schedules[0].schedule=\"$cron\"")")" failed
done
for cron in "0 8 * * 1-5" "*/15 * * * *" "0,30 9-17 * * mon-fri" "0 0 1 jan *" "5 4 * * 7" "0-59/10 * * * *" "0 0 29 2 *"; do
  eq "valid cron accepted: '$cron'"                    "$(fails "$(bad_sched ".schedules[0].schedule=\"$cron\"")")" rendered
done
eq "missing prompt fails the render"                   "$(fails "$(bad_sched '.schedules[0].prompt=""')")" failed
eq "missing name fails the render"                     "$(fails "$(bad_sched 'del(.schedules[0].name)')")" failed
eq "an invalid name (upper case) fails the render"     "$(fails "$(bad_sched '.schedules[0].name="Daily"')")" failed
eq "a name longer than 40 characters fails the render" "$(fails "$(bad_sched '.schedules[0].name="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"')")" failed
eq "duplicate names fail the render"                   "$(fails "$(bad_sched '.schedules[1].name="daily-brief"')")" failed
eq "an invalid timeout fails the render"               "$(fails "$(bad_sched '.schedules[0].timeout="soon"')")" failed
eq "a zero timeout fails the render"                   "$(fails "$(bad_sched '.schedules[0].timeout="0s"')")" failed
eq "an invalid concurrencyPolicy fails the render"     "$(fails "$(bad_sched '.schedules[0].concurrencyPolicy="Sometimes"')")" failed
eq "a bad timeZone shape fails the render"             "$(fails "$(bad_sched '.schedules[0].timeZone="Europe/Berlin; rm"')")" failed
eq "schedules without kagent fail the render"          "$(fails "$(render_err -f "$SCF" --set kagent.enabled=false)")" failed
D4=$(docs -f "$SCF" --set scheduling.namespace=jobs-ns)
eq "scheduling.namespace moves everything"             "$(q "$D4" '[.[]|select(.kind=="CronJob")|.metadata.namespace]|unique|join(",")')" jobs-ns
eq "scheduling.namespace moves the controller peer"    "$(q "$D4" "$KP|[.spec.ingress[].from[]?|select(.podSelector.matchLabels[\"openagentix.io/component\"]==\"schedule\")|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]]|join(\",\")")" jobs-ns
D5=$(docs -f "$SCF" --set 'schedules=null')
eq "schedules=null renders like the default"           "$(count "$D5" '.kind=="CronJob"')" 0
H0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
H1=$(helm template openagentix "$CHART" -n openagentix-system --set schedules=null 2>&1 | shasum -a 256)
eq "schedules=null is byte-identical to the default"   "$H1" "$H0"
rm -f "$SCF"

echo "# notify service (agents deliver a result to a chat)"
NNS=openagentix-notify
NV="$(dirname "$0")/.notify-values.yaml"
# the enabled render: the first agent opts in; tokens: the default Telegram one plus a second, made-up name
yq -y '{agents: (.agents|.[0].notify={enabled: true})}' "$CHART/values.yaml" > "$NV"
cat >> "$NV" <<'YAML'
notify:
  enabled: true
  tokens:
    - {env: NOTIFY_TELEGRAM_TOKEN, secret: notify-credentials, key: NOTIFY_TELEGRAM_TOKEN}
    - {env: NOTIFY_SLACK_TOKEN, secret: slack-creds, key: tok}
YAML
D=$(docs)
eq "notify is OFF by default"                          "$(yq -c .notify.enabled "$CHART/values.yaml")" false
eq "default render has nothing in the notify namespace" "$(count "$D" '.metadata.namespace=="openagentix-notify"')" 0
eq "default render has no delivery MCPServerEntry"     "$(count "$D" '.kind=="MCPServerEntry" and .metadata.name=="delivery"')" 0
DA=$(docs -f "$NV")
NP='.[]|select(.kind=="Deployment" and .metadata.name=="notify")'
NC="$NP|.spec.template.spec.containers[0]"
eq "enabled: kinds in the notify namespace"            "$(q "$DA" '[.[]|select(.metadata.namespace=="openagentix-notify")|.kind]|sort|join(",")')" Deployment,NetworkPolicy,NetworkPolicy,Service
eq "enabled: one MCPServerEntry and one auth config"   "$(count "$DA" '(.kind=="MCPServerEntry" or .kind=="MCPExternalAuthConfig") and (.metadata.name|startswith("delivery"))')" 2
eq "entry lives in mcp-tools, in the vMCP group"       "$(q "$DA" '.[]|select(.kind=="MCPServerEntry" and .metadata.name=="delivery")|.metadata.namespace+" "+.spec.groupRef.name')" "mcp-tools tools"
eq "entry points at the notify /mcp endpoint"          "$(q "$DA" '.[]|select(.kind=="MCPServerEntry" and .metadata.name=="delivery")|.spec.remoteUrl')" http://notify.openagentix-notify.svc.cluster.local:8080/mcp
eq "entry is unauthenticated (explicitly)"             "$(q "$DA" '.[]|select(.kind=="MCPExternalAuthConfig" and .metadata.name=="delivery-noauth")|.spec.type')" unauthenticated
eq "entry references that auth config"                 "$(q "$DA" '.[]|select(.kind=="MCPServerEntry" and .metadata.name=="delivery")|.spec.externalAuthConfigRef.name')" delivery-noauth
eq "exactly one replica, Recreate (limits are per replica)" "$(q "$DA" "$NP|(.spec.replicas|tostring)+\" \"+.spec.strategy.type")" "1 Recreate"
eq "image from values"                                 "$(q "$DA" "$NC|.image")" openagentix/notify:dev
eq "config path env"                                   "$(q "$DA" "$NC|.env[]|select(.name==\"NOTIFY_CONFIG\")|.value")" /etc/notify/destinations.yaml
eq "destinations come from an existing Secret volume"  "$(q "$DA" "$NP|.spec.template.spec.volumes[0].secret|.secretName+\" \"+(.optional|tostring)+\" \"+(.items[0].key)")" "notify-destinations true destinations.yaml"
eq "the volume is mounted read-only at /etc/notify"    "$(q "$DA" "$NC|.volumeMounts[0]|.mountPath+\" \"+(.readOnly|tostring)")" "/etc/notify true"
eq "token env vars are wired from the values list (2)" "$(q "$DA" "$NC|[.env[]|select(.valueFrom.secretKeyRef!=null)|.name+\"=\"+.valueFrom.secretKeyRef.name+\"/\"+.valueFrom.secretKeyRef.key]|sort|join(\",\")")" "NOTIFY_SLACK_TOKEN=slack-creds/tok,NOTIFY_TELEGRAM_TOKEN=notify-credentials/NOTIFY_TELEGRAM_TOKEN"
eq "token env vars are optional (pod starts without them)" "$(q "$DA" "$NC|[.env[]|select(.valueFrom.secretKeyRef!=null)|.valueFrom.secretKeyRef.optional]|unique|join(\",\")")" true
eq "no env var carries a literal value that looks like a secret" "$(q "$DA" "$NC|[.env[]|select((.name|test(\"TOKEN|SECRET|CHAT\")) and has(\"value\"))]|length")" 0
eq "hardened pod: non-root, no token, read-only root" "$(q "$DA" "$NP|.spec.template.spec|[.automountServiceAccountToken,.securityContext.runAsNonRoot,.containers[0].securityContext.readOnlyRootFilesystem,.containers[0].securityContext.allowPrivilegeEscalation]|map(tostring)|join(\",\")")" false,true,true,false
eq "readiness is /readyz by default"                   "$(q "$DA" "$NC|.readinessProbe.httpGet.path")" /readyz
eq "pod template carries no source hash by default"    "$(q "$DA" "$NP|.spec.template.metadata|has(\"annotations\")")" false
D1=$(docs -f "$NV" --set-string notify.sourceHash=abc123)
eq "notify.sourceHash is stamped on the pod template"  "$(q "$D1" "$NP|.spec.template.metadata.annotations[\"openagentix.io/source-hash\"]")" abc123
D1=$(docs -f "$NV" --set notify.requireReady=false)
eq "requireReady=false: readiness is /healthz (empty config must not block helm --wait)" "$(q "$D1" "$NC|.readinessProbe.httpGet.path")" /healthz
eq "the Service selects the pod, port 8080"             "$(q "$DA" '.[]|select(.kind=="Service" and .metadata.name=="notify")|(.spec.selector|tojson)+" "+(.spec.ports[0].port|tostring)')" '{"app":"notify"} 8080'
echo "# notify: network policy"
NI='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="notify-ingress")'
NE='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="notify-egress")'
eq "ingress: only the vMCP pods of mcp-tools, MCP port only" "$(q "$DA" "$NI|.spec.ingress|map(.from|map(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]+\" \"+(.podSelector.matchLabels|tojson))|join(\";\"))|join(\"|\")")" 'mcp-tools {"app":"virtualmcpserver","toolhive-name":"tools"}'
eq "ingress: one rule, TCP 8080"                       "$(q "$DA" "$NI|.spec.ingress|length|tostring")+$(q "$DA" "$NI|.spec.ingress[0].ports|map(.protocol+(.port|tostring))|join(\",\")")" "1+TCP8080"
eq "ingress policy selects the notify pods"            "$(q "$DA" "$NI|.spec.podSelector.matchLabels|tojson")" '{"app":"notify"}'
eq "egress: Egress only, two rules (DNS, public 443)"  "$(q "$DA" "$NE|(.spec.policyTypes|join(\",\"))+\" \"+(.spec.egress|length|tostring)")" "Egress 2"
eq "egress: DNS to kube-dns"                           "$(q "$DA" "$NE|.spec.egress[0]|[.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"],.to[0].podSelector.matchLabels[\"k8s-app\"],(.ports|map(.protocol+(.port|tostring))|sort|join(\"+\"))]|join(\" \")")" "kube-system kube-dns TCP53+UDP53"
eq "egress: 443 to public addresses, private ranges excluded" "$(q "$DA" "$NE|.spec.egress[1]|[.ports[0].port,(.to[0].ipBlock.cidr),(.to[0].ipBlock.except|length)]|map(tostring)|join(\" \")")" "443 0.0.0.0/0 5"
D1=$(docs -f "$NV" --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false: no notify policies"   "$(count "$D1" '.kind=="NetworkPolicy"')" 0
D1=$(docs -f "$NV" --set mcp.virtual.name=gw)
eq "ingress follows mcp.virtual.name"                  "$(q "$D1" "$NI|.spec.ingress[0].from[0].podSelector.matchLabels[\"toolhive-name\"]")" gw
echo "# notify: agent opt-in"
AT='.[]|select(.kind=="AgentTemplate" and .metadata.name=="assistant-template")'
eq "tool names: entry name prefix + the service's tool names" "$(q "$DA" "$AT|[.spec.tools[0].mcp.tools[]|select(test(\"^delivery_\"))]|sort|join(\",\")")" delivery_notify_list_destinations,delivery_notify_send
eq "the opted-in agent keeps its other tools (5 + 3 kb + 2)" "$(q "$DA" "$AT|.spec.tools[0].mcp.tools|length")" 10
eq "prompt names both tools and the rules"             "$(q "$DA" "$AT|.spec.systemPrompt|test(\"delivery_notify_send\") and test(\"delivery_notify_list_destinations\") and test(\"explicitly asks\") and test(\"exactly as\") and test(\"secret\")")" true
eq "original prompt text is kept"                      "$(q "$DA" "$AT|.spec.systemPrompt|test(\"say when you used one\")")" true
DB=$(docs -f "$NV" --set 'agents[0].notify.enabled=false')
cat > "$(dirname "$0")/.nonotify-agent.yaml" <<'YAML'
notify: {enabled: true}
agents:
  - name: plain
    model: claude-haiku
    systemPrompt: "You are plain."
    tools: [{tools: [fetch_fetch]}]
YAML
D2=$(docs -f "$(dirname "$0")/.nonotify-agent.yaml"); rm -f "$(dirname "$0")/.nonotify-agent.yaml"
eq "agent without notify keeps its tools"              "$(q "$D2" '.[]|select(.kind=="AgentTemplate")|.spec.tools[0].mcp.tools|join(",")')" fetch_fetch
eq "agent without notify keeps its prompt"             "$(q "$D2" '.[]|select(.kind=="AgentTemplate")|.spec.systemPrompt')" "You are plain."
eq "enabled but no agent opted in: AgentTemplate is identical to the default render" "$(q "$D2" '.[]|select(.kind=="AgentTemplate")|tojson'|shasum -a 256)" "$(docs -f /dev/stdin <<<'agents: [{name: plain, model: claude-haiku, systemPrompt: "You are plain.", tools: [{tools: [fetch_fetch]}]}]' | jq -r '.[]|select(.kind=="AgentTemplate")|tojson'|shasum -a 256)"
D3=$(docs -f "$NV" --set notify.enabled=false)
eq "notify.enabled=false with an agent opt-in: no notify tools, no notify prompt" "$(q "$D3" "$AT|(.spec.tools[0].mcp.tools|length|tostring)+\" \"+(.spec.systemPrompt|test(\"delivery_\")|tostring)")" "8 false"
D3=$(docs -f "$NV" --set mcp.enabled=false)
eq "mcp.enabled=false: no entry, and the agent gets no notify tools" "$(count "$D3" '.kind=="MCPServerEntry"')+$(q "$D3" "$AT|.spec.systemPrompt|test(\"delivery_\")")" "0+false"
echo "# notify: hygiene"
eq "no Secret objects, no data/stringData anywhere"    "$(count "$DA" '.kind=="Secret" or has("data") or has("stringData")')" 0
eq "no chat id, URL or token looking value is rendered in the notify namespace" "$(q "$DA" '[.[]|select(.metadata.namespace=="openagentix-notify")|tojson|select(test("api\\.telegram|chatId|chat_id|[0-9]{8,}"))]|length')" 0
H0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
H1=$(helm template openagentix "$CHART" -n openagentix-system --set notify.enabled=false 2>&1 | shasum -a 256)
eq "notify.enabled=false is byte-identical to the default render" "$H1" "$H0"
if [ -n "${OA_BASELINE_RENDER:-}" ]; then   # set to the output of `helm template openagentix <chart at the previous commit> -n openagentix-system`
  eq "default render is byte-identical to the baseline render (OA_BASELINE_RENDER)" "$H0" "$(shasum -a 256 < "$OA_BASELINE_RENDER")"
fi
E=$(render_err -f "$NV" --set notify.tokens[0].env=lower-case)
eq "an invalid token env var name fails the render"    "$([ -n "$E" ] && echo failed || echo rendered)" failed
E=$(render_err -f "$NV" --set notify.destinations.existingSecret.name=)
eq "enabled without a destinations Secret name fails the render" "$([ -n "$E" ] && echo failed || echo rendered)" failed
rm -f "$NV"

echo "# observability: off by default"
D=$(docs)
POL='.[]|select(.kind=="AgentgatewayPolicy")'
eq "no observability objects by default"               "$(count "$D" '.metadata.namespace=="openagentix-observability" or .kind=="MCPTelemetryConfig" or .kind=="PodMonitor" or .kind=="ServiceMonitor" or (.metadata.name=="openagentix-observability")')" 0
eq "default gateway policy has no tracing"             "$(q "$D" "$POL|.spec.frontend|has(\"tracing\")")" false
eq "default vMCP has no telemetryConfigRef or audit"   "$(q "$D" '.[]|select(.kind=="VirtualMCPServer")|(.spec|has("telemetryConfigRef"))|tostring')+$(q "$D" '.[]|select(.kind=="VirtualMCPServer")|.spec.config|has("audit")|tostring')" "false+false"
H0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
H1=$(helm template openagentix "$CHART" -n openagentix-system --set observability.enabled=false --set observability.bundled.enabled=true --set observability.capture.content=true --set observability.otlp.endpoint=http://x:4318 2>&1 | shasum -a 256)
eq "observability.enabled=false (other observability values set) is byte-identical to the default render" "$H1" "$H0"
H2=$(helm template openagentix "$CHART" -n openagentix-system -f /dev/stdin <<<'observability: null' 2>&1 | shasum -a 256)
eq "observability=null is byte-identical to the default render" "$H2" "$H0"

echo "# observability: wiring to your own OTLP endpoint"
OE=(--set observability.enabled=true --set observability.otlp.endpoint=http://otel.example.svc:4318 --set observability.otlp.contentFiltered=true)
OB=(--set observability.enabled=true --set observability.bundled.enabled=true)
D=$(docs "${OE[@]}")
MK='.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-observability")'
eq "still exactly ONE AgentgatewayPolicy"              "$(count "$D" '.kind=="AgentgatewayPolicy"')" 1
eq "policy: tracing url is the configured endpoint"    "$(q "$D" "$POL|.spec.frontend.tracing.url")" http://otel.example.svc:4318
eq "policy: tracing protocol HTTP for http/protobuf"   "$(q "$D" "$POL|.spec.frontend.tracing.protocol")" HTTP
eq "policy: tracing random sampling from values"       "$(q "$D" "$POL|.spec.frontend.tracing.randomSampling")" 1.0
eq "policy: tracing adds NO span attributes (no content)" "$(q "$D" "$POL|.spec.frontend.tracing|has(\"attributes\")")" false
eq "policy: user_id access log attribute is kept"      "$(q "$D" "$POL|.spec.frontend.accessLog.attributes.add[0].name")" user_id
eq "policy: traffic section unchanged (apikey auth)"   "$(q "$D" "$POL|.spec.traffic.apiKeyAuthentication.mode")" Strict
D2=$(docs "${OE[@]}" --set observability.otlp.protocol=grpc --set observability.otlp.endpoint=http://otel.example.svc:4317)
eq "policy: grpc protocol maps to GRPC"                "$(q "$D2" "$POL|.spec.frontend.tracing.protocol")" GRPC
D2=$(docs "${OE[@]}" --set observability.tracing.enabled=false)
eq "tracing.enabled=false: no gateway tracing"         "$(q "$D2" "$POL|.spec.frontend|has(\"tracing\")")" false
TC='.[]|select(.kind=="MCPTelemetryConfig")'
eq "one MCPTelemetryConfig in the tools namespace"     "$(count "$D" '.kind=="MCPTelemetryConfig"')/$(q "$D" "$TC|.metadata.namespace")" 1/mcp-tools
eq "toolhive: otlp endpoint without scheme"            "$(q "$D" "$TC|.spec.openTelemetry.endpoint")" otel.example.svc:4318
eq "toolhive: http endpoint means insecure"            "$(q "$D" "$TC|.spec.openTelemetry.insecure")" true
eq "toolhive: tracing on, sampling from values"        "$(q "$D" "$TC|.spec.openTelemetry.tracing|\"\(.enabled) \(.samplingRate)\"")" "true 1.0"
eq "toolhive: prometheus metrics on"                   "$(q "$D" "$TC|.spec.prometheus.enabled")" true
VM='.[]|select(.kind=="VirtualMCPServer")'
eq "vMCP references the telemetry config"              "$(q "$D" "$VM|.spec.telemetryConfigRef.name")" "$(q "$D" "$TC|.metadata.name")"
eq "vMCP audit on, request and response data OFF"      "$(q "$D" "$VM|.spec.config.audit|\"\(.enabled) \(.includeRequestData) \(.includeResponseData)\"")" "true false false"
eq "vMCP: incoming auth untouched"                     "$(q "$D" "$VM|.spec.incomingAuth.type")" oidc
D2=$(docs "${OE[@]}" --set observability.audit.enabled=false)
eq "audit.enabled=false: no audit block"               "$(q "$D2" "$VM|.spec.config|has(\"audit\")")" false
eq "marker ConfigMap in the observability namespace"   "$(q "$D" "$MK|.metadata.namespace")" openagentix-observability
eq "marker: endpoint, protocol"                        "$(q "$D" "$MK|.data|\"\(.otlpEndpoint) \(.otlpProtocol)\"")" "http://otel.example.svc:4318 http/protobuf"
eq "marker: capture and baggage are false"             "$(q "$D" "$MK|.data|\"\(.captureContent) \(.baggage)\"")" "false false"
eq "marker: propagators default to tracecontext"       "$(q "$D" "$MK|.data.propagators")" tracecontext
eq "marker: kourier and kagent switches present"       "$(q "$D" "$MK|.data|has(\"tracesEnabled\") and has(\"samplingRate\")")" true
eq "no bundled backend without bundled.enabled"        "$(count "$D" '.metadata.namespace=="openagentix-observability" and .kind!="ConfigMap"')" 0
eq "no Secret objects"                                 "$(count "$D" '.kind=="Secret"')" 0
D2=$(docs "${OE[@]}" --set observability.baggage=true)
eq "baggage=true: propagators include baggage"         "$(q "$D2" "$MK|.data.propagators")" tracecontext,baggage
eq "baggage=true: the Harness carries OTEL_PROPAGATORS" "$(q "$D2" '.[]|select(.kind=="Harness" and .metadata.name=="assistant-harness")|.spec.env[]|select(.name=="OTEL_PROPAGATORS")|.value')" tracecontext,baggage
eq "baggage off: the Harness has no env"               "$(q "$D" '.[]|select(.kind=="Harness" and .metadata.name=="assistant-harness")|has("spec") and (.spec|has("env"))')" false
E=$(render_err --set observability.enabled=true)
eq "enabled with no endpoint and no bundled backend fails the render" "$([ -n "$E" ] && echo failed || echo rendered)" failed
E=$(render_err "${OE[@]}" --set observability.otlp.protocol=carrier-pigeon)
eq "an unknown OTLP protocol fails the render"         "$([ -n "$E" ] && echo failed || echo rendered)" failed
E=$(render_err "${OE[@]}" --set observability.tracing.samplingRate=2)
eq "a sampling rate outside 0..1 fails the render"     "$([ -n "$E" ] && echo failed || echo rendered)" failed
D2=$(docs --set observability.enabled=true --set observability.otlp.endpoint=http://x:4318 --set mcp.enabled=false)
eq "mcp.enabled=false: no telemetry config, render ok" "$(count "$D2" '.kind=="MCPTelemetryConfig"')+$(count "$D2" '.kind=="ConfigMap" and .metadata.name=="openagentix-observability"')" "0+1"
D2=$(docs --set observability.enabled=true --set observability.otlp.endpoint=http://x:4318 --set gateway.enabled=false)
eq "gateway.enabled=false: render ok, no tracing policy" "$(count "$D2" '.kind=="AgentgatewayPolicy"')" 0

echo "# observability: Agent Kourier wiring (applied by install.sh from the marker)"
eq "kourier switched off: marker has no kourier env"   "$(q "$D" "$MK|.data.kourierEnv")" "[]"
DK=$(docs "${OE[@]}" --set channels.kourier.enabled=true)
eq "kourier on: OTLP env, http/protobuf, no credentials" "$(q "$DK" "$MK|.data.kourierEnv|fromjson|map(.name)|join(\",\")")" "OTEL_EXPORTER_OTLP_ENDPOINT,OTEL_EXPORTER_OTLP_PROTOCOL,OTEL_TRACES_EXPORTER,OTEL_SERVICE_NAME"
eq "kourier on: endpoint value is the configured one"  "$(q "$DK" "$MK|.data.kourierEnv|fromjson|.[0].value")" http://otel.example.svc:4318
DK2=$(docs "${OE[@]}" --set channels.kourier.enabled=true --set observability.otlp.protocol=grpc)
eq "kourier on, grpc: no kourier tracing env (http/protobuf only)" "$(q "$DK2" "$MK|.data.kourierEnv")" "[]"
eq "kourier: no scraper peer or egress without the bundled profile" "$(q "$DK" "$MK|.data|[.kourierMetricsFrom,.kourierEgress]|join(\" \")")" "[] []"
DK3=$(docs "${OB[@]}" --set channels.kourier.enabled=true)
eq "kourier + bundled: scraper peer is the VictoriaMetrics pod" "$(q "$DK3" "$MK|.data.kourierMetricsFrom|fromjson|.[0].podSelector.matchLabels.app")" victoria-metrics
eq "kourier + bundled: egress to the bundled Jaeger OTLP port" "$(q "$DK3" "$MK|.data.kourierEgress|fromjson|.[0]|[.to[0].podSelector.matchLabels.app,(.ports[0].port|tostring)]|join(\" \")")" "jaeger 4318"

echo "# observability: an own endpoint that is not known to drop tool arguments gets no runtime or vMCP traces"
DU=$(docs --set observability.enabled=true --set observability.otlp.endpoint=http://otel.example.svc:4318)
eq "unfiltered own endpoint: marker says runtime traces are off" "$(q "$DU" "$MK|.data.runtimeTraces")" false
eq "unfiltered own endpoint: the gateway (no content) still traces" "$(q "$DU" "$POL|.spec.frontend.tracing.url")" http://otel.example.svc:4318
eq "unfiltered own endpoint: no vMCP tracing, metrics stay on" "$(q "$DU" "$TC|(.spec.openTelemetry//{})|has(\"enabled\")")+$(q "$DU" "$TC|.spec.prometheus.enabled")" "false+true"
eq "unfiltered own endpoint: no Kourier tracing env"   "$(q "$(docs --set observability.enabled=true --set observability.otlp.endpoint=http://x:4318 --set channels.kourier.enabled=true)" "$MK|.data.kourierEnv")" "[]"
eq "contentFiltered=true turns runtime traces on"      "$(q "$D" "$MK|.data.runtimeTraces")" true
eq "bundled with its own Jaeger: runtime traces on"    "$(q "$(docs "${OB[@]}")" "$MK|.data.runtimeTraces")" true
eq "bundled but exporting elsewhere: runtime traces off unless filtered" "$(q "$(docs "${OB[@]}" --set observability.otlp.endpoint=http://mine:4318)" "$MK|.data.runtimeTraces")" false
eq "capture.content=true: runtime traces on (the operator asked for content)" "$(q "$(docs --set observability.enabled=true --set observability.otlp.endpoint=http://x:4318 --set observability.capture.content=true)" "$MK|.data.runtimeTraces")" true

echo "# observability: monitors only when the CRD API exists"
eq "no PodMonitor without the monitoring.coreos.com/v1 API" "$(count "$D" '.kind=="PodMonitor" or .kind=="ServiceMonitor"')" 0
DM=$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1)
eq "with the API: one PodMonitor per target"           "$(count "$DM" '.kind=="PodMonitor"')" 9
eq "PodMonitor for the gateway proxy"                  "$(q "$DM" '.[]|select(.kind=="PodMonitor" and .metadata.name=="openagentix-model-gateway")|.spec.namespaceSelector.matchNames[0]+" "+(.spec.podMetricsEndpoints[0].portNumber|tostring)')" "agentgateway-system 15020"
eq "PodMonitors live in the observability namespace"   "$(q "$DM" '[.[]|select(.kind=="PodMonitor")|.metadata.namespace]|unique|join(",")')" openagentix-observability
eq "PodMonitor selects pods by label"                  "$(q "$DM" '.[]|select(.kind=="PodMonitor" and .metadata.name=="openagentix-atenet-egress")|.spec.selector.matchLabels.app')" atenet-egress
DM2=$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1 --set observability.metrics.scrape.enabled=false)
eq "scrape.enabled=false: no monitors even with the API" "$(count "$DM2" '.kind=="PodMonitor"')" 0
DM2=$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1 --set observability.metrics.scrape.namespace=monitoring --set observability.metrics.scrape.interval=15s)
eq "scrape.namespace and interval are honoured"        "$(q "$DM2" '[.[]|select(.kind=="PodMonitor")]|map(.metadata.namespace+" "+.spec.podMetricsEndpoints[0].interval)|unique|join(",")')" "monitoring 15s"
DM2=$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1 --set channels.kourier.enabled=true)
eq "kourier target appears only with channels.kourier"  "$(count "$DM" '.kind=="PodMonitor" and .metadata.name=="openagentix-agent-kourier"')+$(count "$DM2" '.kind=="PodMonitor" and .metadata.name=="openagentix-agent-kourier"')" "0+1"
DM2=$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1 --set gateway.enabled=false --set mcp.enabled=false --set agents=null --set knowledge.enabled=false)
eq "gateway/mcp targets drop with their blocks"         "$(count "$DM2" '.kind=="PodMonitor"')" 5

echo "# observability round 2: kb and notify expose Prometheus metrics on their own port"
NS='.metadata.namespace=="openagentix-observability"'
NT='.[]|select(.kind=="Deployment" and .metadata.name=="notify")'
NTC="$NT|.spec.template.spec.containers[0]"
NTE="$NTC|.env[]"
NTV=(--set notify.enabled=true --set mcp.enabled=true)
DOFF=$(docs "${NTV[@]}")
eq "off: no KB_METRICS_ADDR, no NOTIFY_METRICS_ADDR"   "$(q "$DOFF" "[($KE|select(.name|test(\"METRICS\"))), ($NTE|select(.name|test(\"METRICS\")))]|length")" 0
eq "off: no container port named metrics"              "$(q "$DOFF" "[($KC|.ports[]|select(.name==\"metrics\")), ($NTC|.ports[]|select(.name==\"metrics\"))]|length")" 0
eq "off: no metrics NetworkPolicy"                     "$(count "$DOFF" '.kind=="NetworkPolicy" and (.metadata.name|test("-metrics$"))')" 0
H0=$(helm template openagentix "$CHART" -n openagentix-system "${NTV[@]}" 2>&1 | shasum -a 256)
H1=$(helm template openagentix "$CHART" -n openagentix-system "${NTV[@]}" --set observability.enabled=false --set observability.bundled.enabled=true --set knowledge.kb.metrics.port=9191 --set knowledge.kb.metrics.collectionLabels=true --set notify.metrics.port=9292 2>&1 | shasum -a 256)
eq "off: the metrics settings change nothing (byte-identical render)" "$H1" "$H0"
DK=$(docs "${OB[@]}" "${NTV[@]}")
eq "on: kb serves metrics on :9090 (own listener)"     "$(q "$DK" "$KE|select(.name==\"KB_METRICS_ADDR\")|.value")" ":9090"
eq "on: kb metrics container port is named metrics"    "$(q "$DK" "$KC|.ports[]|select(.name==\"metrics\")|.containerPort")" 9090
eq "on: the kb API port and Service are unchanged"     "$(q "$DK" "$KC|[.ports[]|select(.name==\"http\")|.containerPort]|join(\",\")")+$(q "$DK" '.[]|select(.kind=="Service" and .metadata.name=="kb")|[.spec.ports[].port]|join(",")')" "8080+8080"
eq "on: the Services never expose the metrics ports"   "$(count "$DK" '.kind=="Service" and ([.spec.ports[]?.port]|any(.==9090))')" 0
eq "on: per-collection labels off unless asked"        "$(q "$DK" "[$KE|select(.name==\"KB_METRICS_COLLECTION_LABELS\")]|length")" 0
eq "on: collectionLabels=true sets the kb flag"        "$(q "$(docs "${OB[@]}" --set knowledge.kb.metrics.collectionLabels=true)" "$KE|select(.name==\"KB_METRICS_COLLECTION_LABELS\")|.value")" true
eq "on: notify serves metrics on :9090 (own listener)" "$(q "$DK" "$NTE|select(.name==\"NOTIFY_METRICS_ADDR\")|.value")" ":9090"
eq "on: notify metrics container port is named metrics" "$(q "$DK" "$NTC|.ports[]|select(.name==\"metrics\")|.containerPort")" 9090
eq "on: the notify Service exposes only 8080"          "$(q "$DK" '.[]|select(.kind=="Service" and .metadata.name=="notify")|[.spec.ports[].port]|join(",")')" 8080
eq "on: no scrape annotations on the pods (as in round 1)" "$(q "$DK" "[($KB|.spec.template.metadata.annotations//{}|keys[]|select(test(\"prometheus\"))), ($NT|.spec.template.metadata.annotations//{}|keys[]|select(test(\"prometheus\")))]|length")" 0
eq "on: metrics port override reaches env and container port" "$(q "$(docs "${OB[@]}" --set knowledge.kb.metrics.port=9191)" "[($KE|select(.name==\"KB_METRICS_ADDR\")|.value), ($KC|.ports[]|select(.name==\"metrics\")|.containerPort|tostring)]|join(\" \")")" ":9191 9191"
eq "on: a metrics port equal to the API port is rejected" "$(render_err "${OB[@]}" --set knowledge.kb.metrics.port=8080 | grep -c 'metrics.port')" 1
eq "on: a non-numeric metrics port is rejected"        "$(render_err "${OB[@]}" "${NTV[@]}" --set notify.metrics.port=abc | grep -c 'metrics.port')" 1
DKM=$(docs "${OE[@]}" "${NTV[@]}" --api-versions monitoring.coreos.com/v1)
eq "PodMonitors: kb"                                   "$(q "$DKM" '.[]|select(.kind=="PodMonitor" and .metadata.name=="openagentix-kb")|[.spec.namespaceSelector.matchNames[0],.spec.selector.matchLabels.app,(.spec.podMetricsEndpoints[0].portNumber|tostring),.spec.podMetricsEndpoints[0].path]|join(" ")')" "openagentix-knowledge kb 9090 /metrics"
eq "PodMonitors: notify"                               "$(q "$DKM" '.[]|select(.kind=="PodMonitor" and .metadata.name=="openagentix-notify")|[.spec.namespaceSelector.matchNames[0],.spec.selector.matchLabels.app,(.spec.podMetricsEndpoints[0].portNumber|tostring),.spec.podMetricsEndpoints[0].path]|join(" ")')" "openagentix-notify notify 9090 /metrics"
eq "PodMonitors: 10 targets with notify on (8 + kb + notify)" "$(count "$DKM" '.kind=="PodMonitor"')" 10
eq "PodMonitors: no notify target while notify is off" "$(count "$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1)" '.kind=="PodMonitor" and .metadata.name=="openagentix-notify"')" 0
eq "PodMonitors: no kb target while knowledge is off"  "$(count "$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1 --set knowledge.enabled=false)" '.kind=="PodMonitor" and .metadata.name=="openagentix-kb"')" 0
eq "PodMonitors: the kb target follows knowledge.namespace and the port override" "$(q "$(docs "${OE[@]}" --api-versions monitoring.coreos.com/v1 --set knowledge.namespace=kb-ns --set knowledge.kb.metrics.port=9191)" '.[]|select(.kind=="PodMonitor" and .metadata.name=="openagentix-kb")|.spec.namespaceSelector.matchNames[0]+" "+(.spec.podMetricsEndpoints[0].portNumber|tostring)')" "kb-ns 9191"
SCK=$(q "$DK" ".[]|select($NS and .kind==\"ConfigMap\" and .metadata.name==\"victoria-metrics-scrape\")|.data[\"scrape.yml\"]")
eq "bundled scrape: kb and notify jobs"                "$(yq -r '[.scrape_configs[].job_name]|map(select(.=="kb" or .=="notify"))|sort|join(",")' <<<"$SCK")" kb,notify
eq "bundled scrape: the kb job targets pod IP :9090 in the knowledge namespace" "$(yq -r '.scrape_configs[]|select(.job_name=="kb")|[.kubernetes_sd_configs[0].namespaces.names[0], .kubernetes_sd_configs[0].selectors[0].label, (.relabel_configs|tostring|contains(":9090"))]|join(" ")' <<<"$SCK")" "openagentix-knowledge app=kb true"
eq "bundled scrape: the notify job targets pod IP :9090 in the notify namespace" "$(yq -r '.scrape_configs[]|select(.job_name=="notify")|[.kubernetes_sd_configs[0].namespaces.names[0], .kubernetes_sd_configs[0].selectors[0].label, (.relabel_configs|tostring|contains(":9090"))]|join(" ")' <<<"$SCK")" "openagentix-notify app=notify true"
eq "bundled scrape: no notify job while notify is off" "$(yq -r '[.scrape_configs[].job_name]|index("notify")' <<<"$(q "$(docs "${OB[@]}")" ".[]|select($NS and .kind==\"ConfigMap\" and .metadata.name==\"victoria-metrics-scrape\")|.data[\"scrape.yml\"]")")" null
eq "bundled scrape: the VictoriaMetrics pod restarts when the targets change" "$([ "$(q "$DK" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"victoria-metrics\")|.spec.template.metadata.annotations[\"checksum/scrape\"]")" != "$(q "$(docs "${OB[@]}")" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"victoria-metrics\")|.spec.template.metadata.annotations[\"checksum/scrape\"]")" ] && echo differs || echo same)" differs
KM='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-metrics")'
NM='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="notify-metrics")'
eq "NetworkPolicy kb-metrics: only the bundled scraper, only the metrics port" "$(q "$DK" "$KM|[.metadata.namespace,(.spec.podSelector.matchLabels.app),(.spec.ingress|length|tostring),(.spec.ingress[0].ports|map(.port|tostring)|join(\",\")),(.spec.ingress[0].from|length|tostring),.spec.ingress[0].from[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"],.spec.ingress[0].from[0].podSelector.matchLabels.app]|join(\" \")")" "openagentix-knowledge kb 1 9090 1 openagentix-observability victoria-metrics"
eq "NetworkPolicy notify-metrics: only the bundled scraper, only the metrics port" "$(q "$DK" "$NM|[.metadata.namespace,(.spec.podSelector.matchLabels.app),(.spec.ingress|length|tostring),(.spec.ingress[0].ports|map(.port|tostring)|join(\",\")),(.spec.ingress[0].from|length|tostring),.spec.ingress[0].from[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"],.spec.ingress[0].from[0].podSelector.matchLabels.app]|join(\" \")")" "openagentix-notify notify 1 9090 1 openagentix-observability victoria-metrics"
eq "the API policies do not open the metrics port"     "$(q "$DK" '[.[]|select(.kind=="NetworkPolicy" and (.metadata.name=="kb-ingress" or .metadata.name=="notify-ingress"))|.spec.ingress[]?.ports[]?.port]|map(tostring)|unique|join(",")')" 8080
eq "no metrics NetworkPolicy without the bundled profile" "$(count "$(docs "${OE[@]}" "${NTV[@]}")" '.kind=="NetworkPolicy" and (.metadata.name=="kb-metrics" or .metadata.name=="notify-metrics")')" 0
eq "no metrics NetworkPolicy with networkPolicy.enabled=false" "$(count "$(docs "${OB[@]}" "${NTV[@]}" --set networkPolicy.enabled=false)" '.kind=="NetworkPolicy" and (.metadata.name=="kb-metrics" or .metadata.name=="notify-metrics")')" 0
eq "no notify-metrics NetworkPolicy while notify is off" "$(count "$(docs "${OB[@]}")" '.kind=="NetworkPolicy" and .metadata.name=="notify-metrics"')" 0
eq "the metrics settings render no Secret and no literal credential" "$(count "$DK" '.kind=="Secret"')" 0

echo "# observability: privacy, one switch"
DC=$(docs "${OE[@]}" --set observability.capture.content=true)
eq "capture.content=true: marker says so"             "$(q "$DC" "$MK|.data.captureContent")" true
eq "capture.content=true: audit includes request and response data" "$(q "$DC" "$VM|.spec.config.audit|\"\(.includeRequestData) \(.includeResponseData)\"")" "true true"
DC2=$(docs "${OE[@]}" --set observability.audit.includeRequestData=true --set observability.audit.includeResponseData=true --set observability.tracing.captureContent=true --set observability.capture.captureContent=true)
eq "no other value path turns content on"              "$(q "$DC2" "$MK|.data.captureContent")+$(q "$DC2" "$VM|.spec.config.audit|\"\(.includeRequestData) \(.includeResponseData)\"")" "false+false false"
eq "gateway span attributes never reference prompt, completion or body (the backend.ai.promptCaching switches are cache marks, not content)" "$(q "$DC" "$POL|.spec|del(.backend)|tojson|test(\"prompt|completion|request.body|response.body|llm\\\\.\")")" false
eq "backend section holds only the promptCaching switches (no content capture)" "$(q "$DC" "$POL|.spec.backend|tojson")" '{"ai":{"promptCaching":{"cacheSystem":true,"cacheMessages":true,"cacheTools":true,"minTokens":1024}}}'

echo "# observability: bundled dev profile"
OB=(--set observability.enabled=true --set observability.bundled.enabled=true)
D=$(docs "${OB[@]}")
NS='.metadata.namespace=="openagentix-observability"'
eq "bundled: VictoriaMetrics and Jaeger Deployments"   "$(count "$D" "$NS and .kind==\"Deployment\" and (.metadata.name==\"victoria-metrics\" or .metadata.name==\"jaeger\")")" 2
eq "bundled: endpoint defaults to the bundled Jaeger"  "$(q "$D" "$MK|.data.otlpEndpoint")" http://jaeger.openagentix-observability.svc.cluster.local:4318
eq "bundled: gateway tracing url is the bundled Jaeger" "$(q "$D" "$POL|.spec.frontend.tracing.url")" http://jaeger.openagentix-observability.svc.cluster.local:4318
eq "bundled: no Ingress, no LoadBalancer, no NodePort" "$(count "$D" "$NS and (.kind==\"Ingress\" or (.kind==\"Service\" and (.spec.type//\"ClusterIP\")!=\"ClusterIP\"))")" 0
eq "bundled: images pinned by tag and digest"          "$(q "$D" "[.[]|select($NS and .kind==\"Deployment\")|.spec.template.spec.containers[].image|select(test(\":[0-9v][^@]*@sha256:[0-9a-f]{64}\$\"))]|length")" 2
for W in victoria-metrics jaeger; do
  DEP=".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"$W\")|.spec.template.spec"
  eq "$W: non-root, read-only root, no capabilities, no privilege escalation, seccomp" "$(q "$D" "$DEP|[(.securityContext.runAsNonRoot), (.containers[0].securityContext.readOnlyRootFilesystem), (.containers[0].securityContext.allowPrivilegeEscalation), (.containers[0].securityContext.capabilities.drop|join(\",\")), (.securityContext.seccompProfile.type)]|map(tostring)|join(\" \")")" "true true false ALL RuntimeDefault"
  eq "$W: requests and limits set"                     "$(q "$D" "$DEP|.containers[0].resources|[.requests.memory,.limits.memory,.requests.cpu,.limits.cpu]|all(.!=null)")" true
done
eq "jaeger: no service account token mounted"          "$(q "$D" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"jaeger\")|.spec.template.spec.automountServiceAccountToken")" false
eq "victoria-metrics: own ServiceAccount, token mounted (pod discovery needs it)" "$(q "$D" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"victoria-metrics\")|.spec.template.spec|[.serviceAccountName,(.automountServiceAccountToken//true)]|map(tostring)|join(\" \")")" "victoria-metrics true"
eq "victoria-metrics: retention and PVC"               "$(q "$D" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"victoria-metrics\")|.spec.template.spec.containers[0].args|index(\"-retentionPeriod=7d\")!=null")" true
eq "victoria-metrics: scrape config comes from a ConfigMap" "$(count "$D" "$NS and .kind==\"ConfigMap\" and .metadata.name==\"victoria-metrics-scrape\"")" 1
SC=$(q "$D" ".[]|select($NS and .kind==\"ConfigMap\" and .metadata.name==\"victoria-metrics-scrape\")|.data[\"scrape.yml\"]")
eq "scrape config: one job per target"                 "$(yq -r '[.scrape_configs[].job_name]|sort|join(",")' <<<"$SC")" "agentgateway,ate-api-server,ate-controller,atelet,atenet-egress,atenet-router,kb,model-gateway,victoria-metrics,vmcp"
eq "scrape config: the gateway job targets pod IP :15020 in its namespace" "$(yq -r '.scrape_configs[]|select(.job_name=="model-gateway")|[.kubernetes_sd_configs[0].role, .kubernetes_sd_configs[0].namespaces.names[0], (.relabel_configs|tostring|contains("15020"))]|join(" ")' <<<"$SC")" "pod agentgateway-system true"
eq "ClusterRole: only get/list/watch on pods"          "$(q "$D" '.[]|select(.kind=="ClusterRole" and .metadata.name=="openagentix-observability-discovery")|.rules|tojson')" '[{"apiGroups":[""],"resources":["pods"],"verbs":["get","list","watch"]}]'
eq "bundled: no Secret objects"                        "$(count "$D" '.kind=="Secret"')" 0
JC=$(q "$D" ".[]|select($NS and .kind==\"ConfigMap\" and .metadata.name==\"jaeger-config\")|.data[\"config.yaml\"]")
eq "jaeger: in-memory store capped by maxTraces"       "$(yq -r '.extensions.jaeger_storage.backends.memstore.memory.max_traces' <<<"$JC")" 2000
eq "jaeger: OTLP gRPC and HTTP receivers"              "$(yq -r '.receivers.otlp.protocols|keys|join(",")' <<<"$JC")" grpc,http
eq "jaeger: content-dropping processor in the pipeline by default" "$(yq -r '.service.pipelines.traces.processors|index("attributes/drop-content")!=null' <<<"$JC")" true
DROP=$(yq -r '.processors["attributes/drop-content"].actions|map(.pattern // .key)|join("|")' <<<"$JC")
eq "jaeger: drops the Go ADK tool arguments and results" "$(grep -c 'tool_call_args' <<<"$DROP")+$(grep -c 'tool_response' <<<"$DROP")" "1+1"
eq "jaeger: deletes the end-user id from spans by default (user.id carries telegram:<chat id>)" "$(grep -c 'user.id' <<<"$DROP")+$(grep -c 'enduser.id' <<<"$DROP")" "1+1"
eq "jaeger: drops the vMCP tool arguments (mcp.tool.arguments)" "$(grep -c 'mcp.tool.arguments' <<<"$DROP")" 1
eq "jaeger: drops GenAI message content keys"          "$(grep -c 'gen_ai.input.messages' <<<"$DROP")" 1
DC=$(docs "${OB[@]}" --set observability.capture.content=true)
JC2=$(q "$DC" ".[]|select($NS and .kind==\"ConfigMap\" and .metadata.name==\"jaeger-config\")|.data[\"config.yaml\"]")
eq "capture.content=true: the dropping processor is gone" "$(yq -r '.service.pipelines.traces.processors|index("attributes/drop-content")==null' <<<"$JC2")" true
DX=$(docs "${OB[@]}" --set 'observability.bundled.traces.extraDropAttributes={app.secret.key}')
JX=$(q "$DX" ".[]|select($NS and .kind==\"ConfigMap\" and .metadata.name==\"jaeger-config\")|.data[\"config.yaml\"]")
eq "jaeger: extraDropAttributes adds attributes to the delete list" "$(yq -r '.processors["attributes/drop-content"].actions|map(.key)|index("app.secret.key")!=null' <<<"$JX")" true
eq "jaeger: the pod template hash follows the CONFIG CONTENT (a changed drop list must restart Jaeger)" "$([ "$(q "$D" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"jaeger\")|.spec.template.metadata.annotations[\"checksum/config\"]")" != "$(q "$DX" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"jaeger\")|.spec.template.metadata.annotations[\"checksum/config\"]")" ] && echo differs || echo same)" differs
eq "jaeger: a pod-template hash follows the config"    "$(q "$D" ".[]|select($NS and .kind==\"Deployment\" and .metadata.name==\"jaeger\")|.spec.template.metadata.annotations|has(\"checksum/config\")")" true
NP='.[]|select(.kind=="NetworkPolicy" and '"$NS"')'
eq "jaeger NetworkPolicy: OTLP ports only from the listed namespaces" "$(q "$D" "$NP|select(.metadata.name==\"jaeger-ingress\")|.spec.ingress[0]|[(.ports|map(.port)|join(\",\")), (.from|length)]|map(tostring)|join(\" \")")" "4317,4318 7"
eq "jaeger NetworkPolicy: UI port is not opened (port-forward only)" "$(q "$D" "[$NP|select(.metadata.name==\"jaeger-ingress\")|.spec.ingress[].ports[].port]|index(16686)==null")" true
eq "victoria-metrics NetworkPolicy: no ingress rule (query via port-forward)" "$(q "$D" "$NP|select(.metadata.name==\"victoria-metrics-ingress\")|(.spec.ingress//[])|length")" 0
eq "vMCP admits the metrics scraper on 9464"           "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-metrics")|.spec.ingress[0]|[(.ports[0].port),(.from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]),(.from[0].podSelector.matchLabels.app)]|map(tostring)|join(" ")')" "9464 openagentix-observability victoria-metrics"
D2=$(docs "${OB[@]}" --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false: no NetworkPolicy for the bundled pods" "$(count "$D2" "$NS and .kind==\"NetworkPolicy\"")" 0
D2=$(docs "${OB[@]}" --set observability.bundled.metrics.storage.size=)
eq "empty storage size: emptyDir, no PVC"              "$(count "$D2" '.kind=="PersistentVolumeClaim" and .metadata.name=="victoria-metrics"')" 0
D2=$(docs "${OB[@]}" --set observability.otlp.endpoint=http://mine:4318)
eq "bundled with an explicit endpoint: the endpoint wins" "$(q "$D2" "$MK|.data.otlpEndpoint")" http://mine:4318
eq "no secret-looking data anywhere in the bundled render" "$(count "$D" 'has("data") and (.kind!="ConfigMap")')" 0

echo "# knowledge graph (kb.graph, off by default)"
D=$(docs)
GE="$KC|.env[]"
eq "graph off by default: no KB_GRAPH_* env on the kb" "$(q "$D" "[$KE|select(.name|startswith(\"KB_GRAPH\"))]|length")" 0
eq "graph off by default: nothing refers to the extraction key Secret" "$(q "$D" 'tostring|contains("kb-extract-key")')" false
# every graph tunable set, but off: the render must be byte-identical to the default render
DEFAULT_TXT=$(helm template openagentix "$CHART" -n openagentix-system 2>&1)
OFF_TXT=$(helm template openagentix "$CHART" -n openagentix-system --set knowledge.kb.graph.enabled=false --set knowledge.kb.graph.extractModel=other \
  --set knowledge.kb.graph.windowChars=100 --set knowledge.kb.graph.tokensPerHour=5 --set knowledge.kb.graph.keySecret.name=other-key 2>&1)
eq "graph.enabled=false with tunables set renders byte-identical to the default" "$([ "$DEFAULT_TXT" = "$OFF_TXT" ] && echo identical || echo differs)" identical
GR=(--set knowledge.kb.graph.enabled=true)
D=$(docs "${GR[@]}")
gv() { q "$D" "$KE|select(.name==\"$1\")|.value"; }
eq "graph on: switch"                                  "$(gv KB_GRAPH_ENABLED)" true
eq "graph on: extract model is a gateway alias (the default model)" "$(gv KB_GRAPH_EXTRACT_MODEL)" claude-haiku
eq "graph on: gateway URL is the model gateway's base URL" "$(gv KB_GRAPH_GATEWAY_URL)" http://model-gateway.agentgateway-system.svc.cluster.local/v1
eq "graph on: key comes from a Secret reference"       "$(q "$D" "$KE|select(.name==\"KB_GRAPH_API_KEY\")|.valueFrom.secretKeyRef|.name+\"/\"+.key")" kb-extract-key/OPENAI_API_KEY
eq "graph on: key env has no literal value"            "$(q "$D" "$KE|select(.name==\"KB_GRAPH_API_KEY\")|has(\"value\")")" false
eq "graph on: key Secret is required (a missing key is visible, not silent)" "$(q "$D" "$KE|select(.name==\"KB_GRAPH_API_KEY\")|.valueFrom.secretKeyRef.optional // false")" false
eq "graph on: defaults window/entities/relations"      "$(gv KB_GRAPH_WINDOW_CHARS)/$(gv KB_GRAPH_MAX_ENTITIES_PER_CHUNK)/$(gv KB_GRAPH_MAX_RELATIONS_PER_WINDOW)" 2400/12/30
eq "graph on: defaults budget/hops/prompt version"     "$(gv KB_GRAPH_TOKENS_PER_HOUR)/$(gv KB_GRAPH_MAX_HOPS)/$(gv KB_GRAPH_PROMPT_VERSION)" 300000/3/v2
eq "graph on: exactly the 10 KB_GRAPH_* variables"     "$(q "$D" "[$KE|select(.name|startswith(\"KB_GRAPH\"))]|length")" 10
eq "graph on: nothing else on the kb Deployment changed" "$(diff <(q "$D" "[$KE|.name]|map(select(startswith(\"KB_GRAPH\")|not))|join(\",\")") <(q "$(docs)" "[$KE|.name]|join(\",\")") >/dev/null && echo same || echo differs)" same
eq "graph on: the kb keeps its embedding-key annotations untouched" "$(q "$D" "$KB|.metadata.annotations[\"openagentix.io/gateway-user\"]+\"/\"+.metadata.annotations[\"openagentix.io/gateway-key-secret\"]")" kb/kb-virtual-key
eq "graph on: the extraction key is a second annotation set, user id kb-extract" "$(q "$D" "$KB|.metadata.annotations|[.[\"openagentix.io/gateway-user-extract\"],.[\"openagentix.io/gateway-key-secret-extract\"],.[\"openagentix.io/gateway-key-name-extract\"]]|join(\"/\")")" kb-extract/kb-extract-key/OPENAI_API_KEY
eq "graph on: the extraction key is not the embedding key" "$(q "$D" "$KB|.metadata.annotations|(.[\"openagentix.io/gateway-key-secret-extract\"]!=.[\"openagentix.io/gateway-key-secret\"]) and (.[\"openagentix.io/gateway-user-extract\"]!=.[\"openagentix.io/gateway-user\"])")" true
eq "graph on: KB_GRAPH_API_KEY reads the annotated Secret" "$(q "$D" "$KB|[.metadata.annotations[\"openagentix.io/gateway-key-secret-extract\"],.metadata.annotations[\"openagentix.io/gateway-key-name-extract\"]]|join(\"/\")")" "$(q "$D" "$KE|select(.name==\"KB_GRAPH_API_KEY\")|.valueFrom.secretKeyRef|.name+\"/\"+.key")"
eq "graph on: renders no extra object (same kinds as default)" "$(q "$D" '[.[]|.kind]|sort|join(",")')" "$(q "$(docs)" '[.[]|.kind]|sort|join(",")')"
eq "graph on: the chart renders no Secret"             "$(count "$D" '.kind=="Secret"')" 0
D=$(docs "${GR[@]}" --set-json 'gateway.models=[{"name":"claude-haiku","provider":"Anthropic","authSecret":"anthropic-api-key","upstreamModel":"claude-haiku-5-5"},{"name":"gemini","provider":"Gemini","authSecret":"gemini-api-key"}]' --set knowledge.kb.graph.extractModel=gemini --set knowledge.kb.graph.windowChars=1800 --set knowledge.kb.graph.maxEntitiesPerChunk=8 \
  --set knowledge.kb.graph.maxRelationsPerWindow=10 --set knowledge.kb.graph.tokensPerHour=50000 --set knowledge.kb.graph.maxHops=2 \
  --set knowledge.kb.graph.promptVersion=v2 --set knowledge.kb.graph.keySecret.name=my-key --set knowledge.kb.graph.keySecret.key=K)
eq "graph overrides: model"                            "$(gv KB_GRAPH_EXTRACT_MODEL)" gemini
eq "graph overrides: numbers"                          "$(gv KB_GRAPH_WINDOW_CHARS)/$(gv KB_GRAPH_MAX_ENTITIES_PER_CHUNK)/$(gv KB_GRAPH_MAX_RELATIONS_PER_WINDOW)/$(gv KB_GRAPH_TOKENS_PER_HOUR)/$(gv KB_GRAPH_MAX_HOPS)/$(gv KB_GRAPH_PROMPT_VERSION)" 1800/8/10/50000/2/v2
eq "graph overrides: key Secret reference"             "$(q "$D" "$KE|select(.name==\"KB_GRAPH_API_KEY\")|.valueFrom.secretKeyRef|.name+\"/\"+.key")" my-key/K
eq "graph overrides: the annotation names the same Secret and key" "$(q "$D" "$KB|.metadata.annotations|[.[\"openagentix.io/gateway-key-secret-extract\"],.[\"openagentix.io/gateway-key-name-extract\"]]|join(\"/\")")" my-key/K
D=$(docs "${GR[@]}" --set knowledge.kb.graph.gatewayUrl=http://gw.example/v1)
eq "graph.gatewayUrl overrides the gateway URL"        "$(gv KB_GRAPH_GATEWAY_URL)" http://gw.example/v1
eq "graph on without gateway and without gatewayUrl fails to render" "$(render_err "${GR[@]}" --set gateway.enabled=false --set agents=null | grep -c 'knowledge.kb.graph.gatewayUrl')" 1
D=$(docs "${GR[@]}" --set gateway.enabled=false --set knowledge.kb.graph.gatewayUrl=http://gw.example/v1 --set agents=null)
eq "graph.gatewayUrl of your own: no extraction key is created for it" "$(q "$(docs "${GR[@]}" --set knowledge.kb.graph.gatewayUrl=http://gw.example/v1)" "$KB|.metadata.annotations|keys|map(select(endswith(\"-extract\")))|length")" 0
eq "graph on: extractModel must be a gateway model (claude-haiku is the default)" "$(render_err "${GR[@]}" --set knowledge.kb.graph.extractModel=nonesuch | grep -c 'is not a gateway.models name')" 1
eq "graph on with a model of your own endpoint needs no gateway.models entry" "$(q "$(docs "${GR[@]}" --set knowledge.kb.graph.extractModel=nonesuch --set knowledge.kb.graph.gatewayUrl=http://gw.example/v1)" "$KE|select(.name==\"KB_GRAPH_EXTRACT_MODEL\")|.value")" nonesuch
eq "graph on without the bundled gateway but with gatewayUrl renders" "$(q "$D" "$KE|select(.name==\"KB_GRAPH_GATEWAY_URL\")|.value")" http://gw.example/v1
eq "graph maxHops above 3 is rejected"                 "$(render_err "${GR[@]}" --set knowledge.kb.graph.maxHops=4 | grep -c 'maxHops')" 1
eq "graph windowChars below 1 is rejected"             "$(render_err "${GR[@]}" --set knowledge.kb.graph.windowChars=0 | grep -c 'windowChars')" 1
eq "graph with an empty extractModel is rejected"      "$(render_err "${GR[@]}" --set knowledge.kb.graph.extractModel= | grep -c 'extractModel')" 1
D=$(docs --set knowledge.enabled=false "${GR[@]}")
eq "knowledge.enabled=false wins over graph.enabled"   "$(count "$D" '.metadata.namespace=="openagentix-knowledge"')" 0
D=$(docs "${GR[@]}" --set knowledge.kb.graph.apiKey=SENTINEL-GRAPH-KEY --set knowledge.kb.graph.keySecret.value=SENTINEL-GRAPH-KEY)
eq "a key value passed in values is never rendered"    "$(q "$D" 'tostring|contains("SENTINEL-GRAPH-KEY")')" false

echo "# knowledge graph: agent wiring"
DG=$(docs "${GR[@]}")
ATG='.[]|select(.kind=="AgentTemplate" and .metadata.name=="assistant-template")'
eq "graph on: the assistant also gets the three graph tools" "$(q "$DG" "$ATG|[.spec.tools[0].mcp.tools[]|select(test(\"kb_graph_\"))]|sort|join(\",\")")" knowledge_kb_graph_entity,knowledge_kb_graph_paths,knowledge_kb_graph_search
eq "graph on: the kb tools are still there, 3 more tools in all" "$(q "$DG" "$ATG|.spec.tools[0].mcp.tools|length")" 11
eq "graph off: the assistant has no graph tool"        "$(q "$(docs)" "$ATG|[.spec.tools[0].mcp.tools[]|select(test(\"graph\"))]|length")" 0
eq "graph on: the prompt names the graph tools as the agent sees them" "$(q "$DG" "$ATG|.spec.systemPrompt|test(\"knowledge_kb_graph_search\") and test(\"knowledge_kb_graph_entity\") and test(\"knowledge_kb_graph_paths\") and test(\"knowledge_kb_get_document\")")" true
eq "graph on: the prompt has no unreplaced placeholder" "$(q "$DG" "$ATG|.spec.systemPrompt|test(\"[{]graph|[{]get[}]|[{]search[}]\")")" false
eq "graph off: the prompt does not mention the graph" "$(q "$(docs)" "$ATG|.spec.systemPrompt|test(\"graph\")")" false
eq "graph on: the original knowledge base prompt is kept" "$(q "$DG" "$ATG|.spec.systemPrompt|test(\"knowledge base\") and test(\"say when you used one\")")" true
# Cedar toolAccess is the operator's own list: the chart adds nothing to it
DT=$(docs "${GR[@]}" --set 'mcp.virtual.incomingAuth.toolAccess[0].atespace=kagent' --set 'mcp.virtual.incomingAuth.toolAccess[0].tools={fetch_fetch}')
eq "toolAccess is rendered as given, graph tools are never added to it" "$(q "$DT" '[.[]|select(.kind=="VirtualMCPServer")|tostring|test("kb_graph")]|any')" false

echo "# governance: the A2A gate is off by default"
REPO="$(cd "$CHART/../.." && pwd)"
GKAPI="--api-versions agentkourier.dev/v1alpha1"
GOFF=(-f "$REPO/components/channels/demo-values.yaml" -f "$REPO/components/schedules/demo-values.yaml" $GKAPI)
GON=("${GOFF[@]}" -f "$REPO/components/governance/demo-values.yaml")
eq "governance.a2a.enabled defaults to false"         "$(yq -c .governance.a2a.enabled "$CHART/values.yaml")" false
D=$(docs "${GOFF[@]}")
eq "off: no a2a-gate object of any kind"               "$(count "$D" '(.metadata.name|tostring|test("a2a-gate|a2a-key"))')" 0
eq "off: bridge talks to the controller directly"      "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].env[]|select(.name=="A2A_URL")|.value')" http://kagent-controller.kagent.svc.cluster.local:8083/agents/kagent/assistant
eq "off: bridge has no token file and no service account" "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|[([.spec.template.spec.containers[0].env[]|select(.name=="A2A_TOKEN_FILE")]|length),(.spec.template.spec|has("serviceAccountName"))]|tostring')" '[0,false]'
eq "off: no ServiceAccount and no ClusterRoleBinding rendered" "$(count "$D" '.kind=="ServiceAccount" or .kind=="ClusterRoleBinding"')" 0
eq "off: Binding has no tokenSecretRef"                "$(q "$D" '[.[]|select(.kind=="Binding")|.spec.identity|has("tokenSecretRef")]|any')" false

echo "# governance: the gate and its wiring"
DG=$(docs "${GON[@]}")
GD='.[]|select(.kind=="Deployment" and .metadata.name=="a2a-gate")'
eq "one gate Deployment in the gateway namespace"      "$(q "$DG" "[$GD|.metadata.namespace]|join(\",\")")" openagentix-gateway
eq "gate image"                                        "$(q "$DG" "$GD|.spec.template.spec.containers[0].image")" openagentix/a2a-gate:dev
eq "gate upstream is the controller"                   "$(q "$DG" "$GD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_GATE_UPSTREAM\")|.value")" http://kagent-controller.kagent.svc.cluster.local:8083
eq "gate audience"                                     "$(q "$DG" "$GD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_GATE_AUDIENCE\")|.value")" openagentix-a2a
eq "gate audit user id defaults to hash"               "$(q "$DG" "$GD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_GATE_AUDIT_USER_ID\")|.value")" hash
eq "gate runs as non-root with a read-only root filesystem" "$(q "$DG" "$GD|[.spec.template.spec.securityContext.runAsNonRoot,.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem,.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation]|tostring")" '[true,true,false]'
eq "gate pod has an fsGroup so the mounted key hashes (mode 0440) are readable by the non-root user" "$(q "$DG" "$GD|.spec.template.spec.securityContext.fsGroup")" 65532
eq "gate has its own ServiceAccount, token mounted for TokenReview" "$(q "$DG" "$GD|[.spec.template.spec.serviceAccountName,.spec.template.spec.automountServiceAccountToken]|tostring")" '["a2a-gate",true]'
eq "ServiceAccount a2a-gate"                           "$(count "$DG" '.kind=="ServiceAccount" and .metadata.name=="a2a-gate" and .metadata.namespace=="openagentix-gateway"')" 1
eq "ClusterRoleBinding to system:auth-delegator"       "$(q "$DG" '.[]|select(.kind=="ClusterRoleBinding" and .metadata.name=="a2a-gate-auth-delegator")|[.roleRef.kind,.roleRef.name,.subjects[0].name,.subjects[0].namespace]|join(" ")')" "ClusterRole system:auth-delegator a2a-gate openagentix-gateway"
eq "the gate defines no ClusterRole of its own"        "$(count "$DG" '.kind=="ClusterRole"')" 0
eq "gate Service on 8080"                              "$(q "$DG" '.[]|select(.kind=="Service" and .metadata.name=="a2a-gate")|.spec.ports[0].port')" 8080
eq "gate mounts the rules ConfigMap and the key hashes Secret" "$(q "$DG" "$GD|[.spec.template.spec.volumes[]|(.configMap.name // .secret.secretName)]|sort|join(\",\")")" a2a-gate-keys,a2a-gate-rules
eq "key hashes Secret is optional (the gate starts without it)" "$(q "$DG" "$GD|.spec.template.spec.volumes[]|select(.secret!=null)|.secret.optional")" true
eq "the pod template carries a checksum of the rules"  "$(q "$DG" "$GD|.spec.template.metadata.annotations[\"checksum/rules\"]|test(\"^[0-9a-f]{64}\$\")")" true
R=$(q "$DG" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]')
eq "rules: callers are the bridge, the schedule and the bindings" "$(jq -r '[.callers[].name]|sort|join(",")' <<<"$R")" bridge,kourier-demo-assistant,kourier-demo-assistant-notify,schedule-demo-brief
eq "rules: bridge may call its agent with the telegram: prefix" "$(jq -r '.callers[]|select(.name=="bridge")|[.serviceAccount.namespace,.serviceAccount.name,(.agents|join(",")),.userId.prefix]|join(" ")' <<<"$R")" "openagentix-gateway telegram-bridge kagent/assistant telegram:"
eq "rules: the schedule has its own ServiceAccount and an exact user id" "$(jq -r '.callers[]|select(.name=="schedule-demo-brief")|[.serviceAccount.namespace,.serviceAccount.name,(.agents|join(",")),.userId.exact]|join(" ")' <<<"$R")" "openagentix-schedules schedule-demo-brief kagent/assistant schedule:demo-brief"
eq "rules: a Kourier binding has a key and a fixed user id" "$(jq -r '.callers[]|select(.name=="kourier-demo-assistant")|[.key,(.agents|join(",")),.userId.fixed,(has("serviceAccount")|tostring)]|join(" ")' <<<"$R")" "true kagent/assistant kourier:demo-assistant false"
eq "rules: the bridge and each schedule may only SendMessage" "$(jq -r '[.callers[]|select(.name=="bridge" or (.name|startswith("schedule-")))|(.methods|join("+"))]|unique|join(",")' <<<"$R")" SendMessage
eq "rules: a Kourier binding may send, stream, read, subscribe and cancel" "$(jq -r '[.callers[]|select(.name|startswith("kourier-"))|(.methods|sort|join("+"))]|unique|join(",")' <<<"$R")" "CancelTask+GetTask+SendMessage+SendStreamingMessage+SubscribeToTask"
eq "gate in-flight cap defaults to 128"                "$(q "$DG" "$GD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_GATE_MAX_INFLIGHT\")|.value")" 128
eq "gate in-flight cap is a value"                     "$(q "$(docs "${GON[@]}" --set governance.a2a.maxInFlight=32)" "$GD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_GATE_MAX_INFLIGHT\")|.value")" 32
eq "rules hold no secret value"                        "$(jq -r 'tostring|test("vk-|sk-|ak-|Bearer|password")' <<<"$R")" false
eq "audit raw switch is passed on"                     "$(q "$(docs "${GON[@]}" --set governance.a2a.audit.userId=raw)" "$GD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_GATE_AUDIT_USER_ID\")|.value")" raw
eq "source hash lands on the pod template"             "$(q "$(docs "${GON[@]}" --set-string governance.a2a.sourceHash=abc123)" "$GD|.spec.template.metadata.annotations[\"openagentix.io/source-hash\"]")" abc123

echo "# governance: network policies"
CP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-controller")'
P83="$CP|[.spec.ingress[]|select(any(.ports[]?;.port==8083))|.from[]]"
eq "port 8083 has exactly three sources"               "$(q "$DG" "$P83|length")" 3
eq "port 8083 sources: the gate, atenet-egress, kagent" "$(q "$DG" "$P83|map(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]+\"/\"+((.podSelector.matchLabels.app // \"*\")))|sort|join(\",\")")" "ate-system/atenet-egress,kagent/*,openagentix-gateway/a2a-gate"
eq "gate on: the kagent peer of 8083 is the UI pods only" "$(q "$DG" "$P83|map(select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"kagent\"))|map(.podSelector.matchLabels[\"app.kubernetes.io/component\"])|join(\",\")")" ui
eq "the Kourier and schedule namespaces are no longer peers of 8083" "$(q "$DG" "$P83|map(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"])|map(select(.==\"agent-kourier\" or .==\"openagentix-schedules\"))|length")" 0
eq "the bridge pod is not a peer of 8083"              "$(q "$DG" "$P83|map(select(.podSelector.matchLabels.app==\"telegram-bridge\"))|length")" 0
eq "the port ranges around 8083 stay as they were"     "$(q "$DG" "$CP|[.spec.ingress[]|select(has(\"from\")|not)|.ports[]|(.port|tostring)+\"-\"+(.endPort|tostring)]|sort|join(\",\")")" 1-8082,8084-65535
GI='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="a2a-gate-ingress")'
eq "gate ingress policy exists in the gate namespace"  "$(q "$DG" "$GI|.metadata.namespace+\" \"+.spec.podSelector.matchLabels.app")" "openagentix-gateway a2a-gate"
eq "gate ingress: port 8080 only"                      "$(q "$DG" "$GI|[.spec.ingress[].ports[].port]|map(tostring)|join(\",\")")" 8080
eq "gate ingress peers: bridge, Kourier broker, schedules" "$(q "$DG" "$GI|[.spec.ingress[].from[]|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]]|sort|join(\",\")")" agent-kourier,openagentix-gateway,openagentix-schedules
eq "gate ingress: the bridge peer is scoped by pod label" "$(q "$DG" "$GI|.spec.ingress[].from[]|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"openagentix-gateway\")|.podSelector.matchLabels.app")" telegram-bridge
eq "gate ingress: the schedule peer is scoped by the schedule label" "$(q "$DG" "$GI|.spec.ingress[].from[]|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"openagentix-schedules\")|.podSelector.matchLabels[\"openagentix.io/component\"]")" schedule
eq "schedule egress goes to the gate, not the controller" "$(q "$DG" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-schedules-egress")|.spec.egress[1]|[.to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"],.to[0].podSelector.matchLabels.app,(.ports[0].port|tostring)]|join(" ")')" "openagentix-gateway a2a-gate 8080"
BE=$(q "$DG" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-channels")|.data.brokerEgress')
eq "Kourier egress goes to the gate"                   "$(jq -r '.[0]|[.to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"],.to[0].podSelector.matchLabels.app,(.ports[0].port|tostring)]|join(" ")' <<<"$BE")" "openagentix-gateway a2a-gate 8080"
eq "networkPolicy.enabled=false: no policy at all, the gate still renders" "$(q "$(docs "${GON[@]}" --set networkPolicy.enabled=false)" '[(.[]|select(.kind=="NetworkPolicy")),(.[]|select(.kind=="Deployment" and .metadata.name=="a2a-gate"))]|map(.kind)|join(",")')" Deployment

echo "# governance: callers authenticate"
BD='.[]|select(.kind=="Deployment" and .metadata.name=="telegram-bridge")'
eq "bridge A2A_URL is the gate"                        "$(q "$DG" "$BD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_URL\")|.value")" http://a2a-gate.openagentix-gateway.svc.cluster.local:8080/agents/kagent/assistant
eq "bridge reads its token from a file"                "$(q "$DG" "$BD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_TOKEN_FILE\")|.value")" /var/run/a2a/token
eq "bridge has a projected token with the audience"    "$(q "$DG" "$BD|.spec.template.spec.volumes[]|select(.name==\"a2a-token\")|.projected.sources[0].serviceAccountToken|[.audience,(.expirationSeconds|tostring),.path]|join(\" \")")" "openagentix-a2a 3600 token"
eq "bridge mounts it read-only"                        "$(q "$DG" "$BD|.spec.template.spec.containers[0].volumeMounts[]|select(.name==\"a2a-token\")|[.mountPath,(.readOnly|tostring)]|join(\" \")")" "/var/run/a2a true"
eq "bridge has its own ServiceAccount and keeps automount off" "$(q "$DG" "$BD|[.spec.template.spec.serviceAccountName,(.spec.template.spec.automountServiceAccountToken|tostring)]|join(\" \")")" "telegram-bridge false"
eq "ServiceAccount telegram-bridge exists"             "$(count "$DG" '.kind=="ServiceAccount" and .metadata.name=="telegram-bridge" and .metadata.namespace=="openagentix-gateway" and .automountServiceAccountToken==false')" 1
eq "an explicit bridge.a2aUrl still wins"              "$(q "$(docs "${GON[@]}" --set bridge.a2aUrl=http://x/y)" "$BD|.spec.template.spec.containers[0].env[]|select(.name==\"A2A_URL\")|.value")" http://x/y
CJ='.[]|select(.kind=="CronJob" and .metadata.name=="demo-brief")'
CJP="$CJ|.spec.jobTemplate.spec.template.spec"
eq "each schedule has its own ServiceAccount"          "$(count "$DG" '.kind=="ServiceAccount" and .metadata.name=="schedule-demo-brief" and .metadata.namespace=="openagentix-schedules" and .automountServiceAccountToken==false')" 1
eq "the schedule pod uses it and keeps automount off"  "$(q "$DG" "$CJP|[.serviceAccountName,(.automountServiceAccountToken|tostring)]|join(\" \")")" "schedule-demo-brief false"
eq "the schedule pod has a projected token with the audience" "$(q "$DG" "$CJP|.volumes[]|select(.name==\"a2a-token\")|.projected.sources[0].serviceAccountToken|[.audience,(.expirationSeconds|tostring)]|join(\" \")")" "openagentix-a2a 3600"
eq "the schedule reads it from a file"                 "$(q "$DG" "$CJP|.containers[0].env[]|select(.name==\"A2A_TOKEN_FILE\")|.value")" /var/run/a2a/token
eq "the schedule A2A_URL is the gate"                  "$(q "$DG" "$CJP|.containers[0].env[]|select(.name==\"A2A_URL\")|.value")" http://a2a-gate.openagentix-gateway.svc.cluster.local:8080/agents/kagent/assistant
eq "the schedule keeps its prompt volume"              "$(q "$DG" "$CJP|[.volumes[].name]|sort|join(\",\")")" a2a-token,prompt
BN='.[]|select(.kind=="Binding" and .metadata.name=="demo-assistant")'
eq "Binding sends a key Secret as its token"           "$(q "$DG" "$BN|.spec.identity.tokenSecretRef|[.name,.key]|join(\" \")")" "a2a-key-demo-assistant token"
eq "Binding keeps its userId (the gate fixes it)"      "$(q "$DG" "$BN|.spec.identity.userId")" kourier:demo-assistant
eq "Binding names its gate caller"                     "$(q "$DG" "$BN|.metadata.annotations[\"openagentix.io/a2a-caller\"]")" kourier-demo-assistant
eq "every Binding has a distinct key Secret"           "$(q "$DG" '[.[]|select(.kind=="Binding")|.spec.identity.tokenSecretRef.name]|unique|length')" 2
eq "AgentBackend points at the gate"                   "$(q "$DG" '.[]|select(.kind=="AgentBackend")|.spec.url')" http://a2a-gate.openagentix-gateway.svc.cluster.local:8080
eq "the broker may read the key Secrets (Role resourceNames)" "$(q "$DG" '.[]|select(.kind=="Role" and .metadata.name=="agent-kourier-secrets")|.rules[0].resourceNames|join(",")')" a2a-key-demo-assistant,a2a-key-demo-assistant-notify,demo-webhook
eq "an explicit channels.kourier.backend.url still wins" "$(q "$(docs "${GON[@]}" --set channels.kourier.backend.url=http://z:1)" '.[]|select(.kind=="AgentBackend")|.spec.url')" http://z:1
eq "no Secret object is rendered"                      "$(count "$DG" '.kind=="Secret"')" 0
eq "bridge disabled: its rule and ServiceAccount are gone" "$(q "$(docs "${GON[@]}" --set bridge.enabled=false)" '[(.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]|fromjson|.callers[]|select(.name=="bridge")),(.[]|select(.kind=="ServiceAccount" and .metadata.name=="telegram-bridge"))]|length')" 0

echo "# governance: extra callers and validation"
GX="$(dirname "$0")/.gate-extra.yaml"
cat > "$GX" <<'YAML'
networkPolicy:
  extraA2ACallers:
    - namespace: ci
      podLabels: {app: smoke}
governance:
  a2a:
    callers:
      - name: ci-smoke
        serviceAccount: {namespace: ci, name: smoke}
        agents: [assistant]
        userId: {exact: "ci:smoke"}
YAML
DX=$(docs "${GON[@]}" -f "$GX")
eq "an extra caller with a rule renders"               "$([ -z "$(render_err "${GON[@]}" -f "$GX")" ] && echo rendered || echo failed)" rendered
eq "its rule is in the file"                           "$(q "$DX" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]|fromjson|.callers[]|select(.name=="ci-smoke")|[.serviceAccount.namespace,.serviceAccount.name,(.agents|join(",")),.userId.exact]|join(" ")')" "ci smoke kagent/assistant ci:smoke"
eq "its peer moves to the gate policy"                 "$(q "$DX" "$GI|[.spec.ingress[].from[]|select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"ci\")|.podSelector.matchLabels.app]|join(\",\")")" smoke
eq "and is not a peer of 8083"                         "$(q "$DX" "$P83|map(select(.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]==\"ci\"))|length")" 0
eq "an extra caller without methods gets none in its rule (the gate default applies)" "$(q "$DX" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]|fromjson|.callers[]|select(.name=="ci-smoke")|has("methods")|tostring')" false
cat > "$GX" <<'YAML'
governance:
  a2a:
    callers:
      - {name: ci-smoke, serviceAccount: {namespace: ci, name: smoke}, agents: [assistant], userId: {exact: "ci:smoke"}, methods: [SendMessage, GetTask]}
YAML
eq "an extra caller's own methods are kept"            "$(q "$(docs "${GON[@]}" -f "$GX")" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]|fromjson|.callers[]|select(.name=="ci-smoke")|.methods|join(",")')" SendMessage,GetTask
for bad in '[]' '[""]' '["Send Message"]' '[SendMessage, SendMessage]' 'SendMessage'; do
  printf 'governance:\n  a2a:\n    callers:\n      - {name: ci-smoke, serviceAccount: {namespace: ci, name: smoke}, agents: [assistant], userId: {exact: "ci:smoke"}, methods: %s}\n' "$bad" > "$GX"
  eq "invalid methods $bad fail the render"            "$([ -n "$(render_err "${GON[@]}" -f "$GX")" ] && echo failed || echo rendered)" failed
done
printf 'networkPolicy:\n  extraA2ACallers:\n    - namespace: ci\n' > "$GX"
E=$(render_err "${GON[@]}" -f "$GX")
eq "extraA2ACallers without a caller rule fails the render" "$(printf '%s' "$E" | command grep -c 'extraA2ACallers.*ci.*governance.a2a.callers')" 1
eq "the same extraA2ACallers renders with the gate off" "$([ -z "$(render_err "${GOFF[@]}" -f "$GX")" ] && echo rendered || echo failed)" rendered
printf 'governance:\n  a2a:\n    callers:\n      - {name: bridge, serviceAccount: {namespace: a, name: b}, agents: [assistant], userId: {exact: x}}\n' > "$GX"
eq "a caller named like a derived one fails the render" "$([ -n "$(render_err "${GON[@]}" -f "$GX")" ] && echo failed || echo rendered)" failed
printf 'governance:\n  a2a:\n    callers:\n      - {name: ci, serviceAccount: {namespace: a, name: b}, agents: [ghost], userId: {exact: x}}\n' > "$GX"
eq "a caller for an unknown agent fails the render"    "$([ -n "$(render_err "${GON[@]}" -f "$GX")" ] && echo failed || echo rendered)" failed
printf 'governance:\n  a2a:\n    callers:\n      - {name: ci, serviceAccount: {namespace: a, name: b}, agents: [assistant], userId: {exact: x, prefix: y}}\n' > "$GX"
eq "a caller with two user id rules fails the render"  "$([ -n "$(render_err "${GON[@]}" -f "$GX")" ] && echo failed || echo rendered)" failed
printf 'governance:\n  a2a:\n    callers:\n      - {name: ci, serviceAccount: {namespace: a, name: b}, agents: [assistant]}\n' > "$GX"
eq "a caller without a user id rule fails the render"  "$([ -n "$(render_err "${GON[@]}" -f "$GX")" ] && echo failed || echo rendered)" failed
rm -f "$GX"
eq "audit.userId must be hash or raw"                  "$([ -n "$(render_err "${GON[@]}" --set governance.a2a.audit.userId=plain)" ] && echo failed || echo rendered)" failed
eq "the gate needs kagent.enabled"                     "$([ -n "$(render_err "${GON[@]}" --set kagent.enabled=false)" ] && echo failed || echo rendered)" failed
eq "an invalid gate block is not checked while it is off" "$([ -z "$(render_err --set governance.a2a.audit.userId=plain)" ] && echo rendered || echo failed)" rendered
eq "the gate alone (no channels, no schedules) renders" "$(q "$(docs --set governance.a2a.enabled=true)" '[.[]|select(.metadata.name|tostring|test("a2a"))|.kind]|sort|join(",")')" ClusterRoleBinding,ConfigMap,Deployment,NetworkPolicy,Service,ServiceAccount
eq "stray secret-looking values are never rendered with the gate on" "$(q "$(docs "${GON[@]}" --set bridge.token=SENTINEL-GATE-123 --set governance.a2a.apiKey=SENTINEL-GATE-123)" 'tostring|contains("SENTINEL-GATE-123")')" false

echo "# profiles and egress (ADR 0006, round 2): everything is off by default"
PV="$REPO/components/governance/profiles-demo-values.yaml"
PX="$(dirname "$0")/.profiles-variant.yaml"
eq "mcp.profiles defaults to an empty list"           "$(yq -c '.mcp.profiles' "$CHART/values.yaml")" '[]'
D=$(docs)
eq "default: no vMCP besides the shared one"           "$(q "$D" '[.[]|select(.kind=="VirtualMCPServer")|.metadata.name]|join(",")')" tools
eq "default: no EgressPolicy"                          "$(count "$D" '.kind=="EgressPolicy"')" 0
eq "default: no Agent has egressPolicyRefs"            "$(q "$D" '[.[]|select(.kind=="Agent")|.spec|has("egressPolicyRefs")]|any')" false
eq "default: the shared vMCP has no tool filter"       "$(q "$D" '.[]|select(.kind=="VirtualMCPServer")|.spec.config.aggregation|has("tools") or has("defaultToolVisibility")')" false
eq "default: one RemoteMCPServer"                      "$(count "$D" '.kind=="RemoteMCPServer"')" 1

echo "# profiles: what one profile renders"
PALL=(-f "$REPO/components/channels/demo-values.yaml" -f "$REPO/components/schedules/demo-values.yaml" -f "$REPO/components/notify/demo-values.yaml" -f "$REPO/components/observability/demo-values.yaml" -f "$REPO/components/knowledge/graph-demo-values.yaml" -f "$REPO/components/governance/demo-values.yaml" -f "$PV" $GKAPI)
PNG=(-f "$REPO/components/notify/demo-values.yaml" -f "$REPO/components/observability/demo-values.yaml" -f "$REPO/components/knowledge/graph-demo-values.yaml" -f "$PV")   # no gate, no bridge rule: tests may replace agents
DP=$(docs "${PALL[@]}")
VS='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools")'
VP='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")'
eq "the demo file renders"                             "$([ -z "$(render_err "${PALL[@]}")" ] && echo rendered || echo failed)" rendered
eq "two vMCP servers: the shared one and tools-lookup" "$(q "$DP" '[.[]|select(.kind=="VirtualMCPServer")|.metadata.name]|sort|join(",")')" tools,tools-lookup
eq "the profile vMCP serves the same MCPGroup"         "$(q "$DP" "$VP|.spec.groupRef.name")" "$(q "$DP" "$VS|.spec.groupRef.name")"
eq "the profile vMCP is in the mcp namespace"          "$(q "$DP" "$VP|.metadata.namespace")" mcp-tools
eq "profile: unlisted backends advertise nothing (deny)" "$(q "$DP" "$VP|.spec.config.aggregation.defaultToolVisibility")" deny
eq "profile: osv filter holds only the listed tools"   "$(q "$DP" "$VP|.spec.config.aggregation.tools[]|select(.workload==\"osv\")|.filter|sort|join(\",\")")" get_vulnerability,query_vulnerability
eq "profile: the MCPServerEntry backend has its filter" "$(q "$DP" "$VP|.spec.config.aggregation.tools[]|select(.workload==\"knowledge\")|.filter|join(\",\")")" kb_search
eq "profile: fetch and delivery have no entry (so they contribute nothing)" "$(q "$DP" "$VP|[.spec.config.aggregation.tools[].workload]|sort|join(\",\")")" knowledge,osv
eq "profile: conflict resolution and prefix as the shared vMCP" "$(q "$DP" "$VP|.spec.config.aggregation|[.conflictResolution,.conflictResolutionConfig.prefixFormat]|join(\" \")")" "prefix {workload}_"
eq "profile: code mode on (profile value), with the shared limits" "$(q "$DP" "$VP|.spec.config.codeMode|[.enabled,.stepLimit,.toolCallTimeout]|map(tostring)|join(\" \")")" "true 100000 30s"
eq "profile: incoming auth is oidc with its own audience" "$(q "$DP" "$VP|.spec.incomingAuth|[.type,.oidcConfigRef.name,.oidcConfigRef.audience]|join(\" \")")" "oidc substrate-actor-jwt openagentix-vmcp-lookup"
eq "the audiences of all vMCP servers are unique"      "$(q "$DP" '[.[]|select(.kind=="VirtualMCPServer")|.spec.incomingAuth.oidcConfigRef.audience]|(length==(unique|length))|tostring')" true
eq "the shared vMCP keeps its audience"                "$(q "$DP" "$VS|.spec.incomingAuth.oidcConfigRef.audience")" openagentix-vmcp
eq "the profile vMCP is authorized by an explicit allow-all policy (the filter is the limit)" "$(q "$DP" "$VP|.spec.incomingAuth.authzConfig.inline.policies|join(\" \")")" 'permit(principal, action, resource);'
eq "profile: outgoing auth discovered like the shared one" "$(q "$DP" "$VP|.spec.outgoingAuth.source")" discovered
eq "profile: telemetry and audit follow observability" "$(q "$DP" "$VP|[(.spec.telemetryConfigRef.name),(.spec.config.audit.enabled|tostring)]|join(\" \")")" "openagentix-telemetry true"
eq "the shared vMCP is unchanged by the profile"       "$(q "$DP" "$VS|.spec.config.aggregation|has(\"tools\")")" false
eq "the OIDC config is shared (issuer and keys are the same), one object" "$(count "$DP" '.kind=="MCPOIDCConfig"')" 1
eq "a RemoteMCPServer per profile"                     "$(q "$DP" '[.[]|select(.kind=="RemoteMCPServer")|.metadata.name]|sort|join(",")')" toolhive-vmcp,toolhive-vmcp-lookup
RP='.[]|select(.kind=="RemoteMCPServer" and .metadata.name=="toolhive-vmcp-lookup")'
eq "profile RemoteMCPServer points at its own vMCP Service" "$(q "$DP" "$RP|.spec.url")" http://vmcp-tools-lookup.mcp-tools.svc.cluster.local:4483/mcp
eq "profile RemoteMCPServer asks Substrate for its own audience" "$(q "$DP" "$RP|.spec.actorJwt|[(.audiences|join(\",\")),(.expirationSeconds|tostring)]|join(\" \")")" "openagentix-vmcp-lookup 3600"
eq "the shared RemoteMCPServer still asks for the shared audience" "$(q "$DP" '.[]|select(.kind=="RemoteMCPServer" and .metadata.name=="toolhive-vmcp")|.spec.actorJwt.audiences|join(",")')" openagentix-vmcp
eq "profile RemoteMCPServer keeps timeout and protocol" "$(q "$DP" "$RP|[.spec.timeout,.spec.protocol]|join(\" \")")" "60s STREAMABLE_HTTP"

echo "# profiles: the agents"
AP='.[]|select(.kind=="AgentTemplate" and .metadata.name=="profile-demo-template")'
AS='.[]|select(.kind=="AgentTemplate" and .metadata.name=="assistant-template")'
eq "the profile agent exists beside assistant"         "$(q "$DP" '[.[]|select(.kind=="Agent")|.metadata.name]|sort|join(",")')" assistant,profile-demo
eq "the profile agent takes tools only from its profile server" "$(q "$DP" "$AP|[.spec.tools[].mcp.server.name]|unique|join(\",\")")" toolhive-vmcp-lookup
eq "the profile agent's tool list"                     "$(q "$DP" "$AP|[.spec.tools[].mcp.tools[]]|sort|join(\",\")")" execute_tool_script,knowledge_kb_search,osv_get_vulnerability,osv_query_vulnerability
eq "assistant stays on the shared vMCP, unchanged"     "$(q "$DP" "$AS|[.spec.tools[].mcp.server.name]|unique|join(\",\")")" toolhive-vmcp
eq "assistant keeps every tool it had (and the knowledge and notify ones)" "$(q "$DP" "$AS|[.spec.tools[].mcp.tools[]]|map(select(test(\"^(fetch_fetch|osv_|knowledge_|delivery_|execute_)\")))|length")" 13
eq "the profile agent renders an EgressPolicy"         "$(q "$DP" '.[]|select(.kind=="EgressPolicy")|[.metadata.name,.metadata.namespace,(.spec.destinations|map(.origin)|join(","))]|join(" ")')" "profile-demo-egress kagent https://api.osv.dev"
eq "exactly one EgressPolicy"                          "$(count "$DP" '.kind=="EgressPolicy"')" 1
eq "the EgressPolicy grants no credentials"            "$(q "$DP" '.[]|select(.kind=="EgressPolicy")|[.spec.destinations[]|has("authentication")]|any')" false
eq "the Agent refers to it"                            "$(q "$DP" '.[]|select(.kind=="Agent" and .metadata.name=="profile-demo")|.spec.egressPolicyRefs|map(.name)|join(",")')" profile-demo-egress
eq "assistant has no egressPolicyRefs"                 "$(q "$DP" '.[]|select(.kind=="Agent" and .metadata.name=="assistant")|.spec|has("egressPolicyRefs")|tostring')" false
eq "the profile agent has its own model config and key" "$(q "$DP" '.[]|select(.kind=="ModelConfig" and .metadata.annotations["openagentix.io/agent"]=="profile-demo")|[.metadata.name,.spec.apiKeySecret]|join(" ")')" "gateway-profile-demo profile-demo-virtual-key"
eq "profiles render no Secret"                         "$(count "$DP" '.kind=="Secret"')" 0

eq "with the gate on, the demo caller may call the profile agent and assistant" "$(q "$DP" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]|fromjson|.callers[]|select(.name=="profile-canary")|[(.agents|sort|join(",")),.userId.exact]|join(" ")')" "kagent/assistant,kagent/profile-demo canary:profiles"
eq "the profile demo file alone (gate off) renders without the caller rule" "$(count "$(docs -f "$PV")" '.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules"')" 0

echo "# profiles: network policies"
NI='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-ingress")'
NP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-ingress-lookup")'
eq "the profile vMCP has its own ingress policy"       "$(q "$DP" "$NP|.spec.podSelector.matchLabels|[.app,.[\"toolhive-name\"]]|join(\" \")")" "virtualmcpserver tools-lookup"
eq "its peers and ports equal the shared vMCP's"       "$(q "$DP" "[($NP|.spec.ingress),($NI|.spec.ingress)]|(.[0]==.[1])|tostring")" true
eq "the shared vMCP policy still selects only the shared pod" "$(q "$DP" "$NI|.spec.podSelector.matchLabels[\"toolhive-name\"]")" tools
eq "a metrics policy per profile (observability on)"   "$(q "$DP" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-metrics-lookup")|[.spec.podSelector.matchLabels["toolhive-name"],(.spec.ingress[0].ports[0].port|tostring)]|join(" ")')" "tools-lookup 9464"
eq "the kb admits the profile vMCP (every vMCP of the group connects to every backend, or it reports Degraded)" "$(q "$DP" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-ingress")|[.spec.ingress[0].from[]|.podSelector.matchLabels["toolhive-name"]]|sort|join(",")')" tools,tools-lookup
eq "notify admits the profile vMCP too, although the profile lists no notify tool" "$(q "$DP" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="notify-ingress")|[.spec.ingress[0].from[]|.podSelector.matchLabels["toolhive-name"]]|sort|join(",")')" tools,tools-lookup
eq "networkPolicy.enabled=false: no profile policy"    "$(count "$(docs "${PALL[@]}" --set networkPolicy.enabled=false)" '.kind=="NetworkPolicy"')" 0
eq "observability off: no profile metrics policy"      "$(count "$(docs -f "$PV")" '.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-metrics-lookup"')" 0
printf 'agents:\n  - {name: pd, model: claude-haiku, systemPrompt: x}\n' > "$PX"
eq "mcp.enabled=false: no profile object and no vMCP" "$(count "$(docs "${PNG[@]}" -f "$PX" --set mcp.enabled=false --set knowledge.enabled=false)" '(.metadata.name|tostring|test("lookup")) or .kind=="VirtualMCPServer" or (.kind=="RemoteMCPServer" and .metadata.name!="toolhive-vmcp")')" 0
eq "kagent.enabled=false: no profile RemoteMCPServer (the vMCP still renders)" "$(count "$(docs "${PNG[@]}" -f "$PX" --set kagent.enabled=false)" '.kind=="RemoteMCPServer" or (.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")')" 1

echo "# profiles: a second profile, notify tools and no code mode"
cat > "$PX" <<'YAML'
mcp:
  profiles:
    - name: lookup
      codeMode: true
      tools: {osv: [query_vulnerability]}
    - name: Notifier2
      tools: {delivery: [notify_send]}
agents:
  - {name: pd, model: claude-haiku, systemPrompt: x}
YAML
eq "an uppercase profile name fails the render"        "$([ -n "$(render_err "${PNG[@]}" -f "$PX")" ] && echo failed || echo rendered)" failed
sed -i.bak 's/Notifier2/sender/' "$PX"; rm -f "$PX.bak"
DN=$(docs "${PNG[@]}" -f "$PX")
eq "the lookup profile in this file has one workload"  "$(q "$DN" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")|.spec.config.aggregation.tools|length')" 1
eq "a profile without codeMode renders no codeMode block" "$(q "$DN" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-sender")|.spec.config|has("codeMode")|tostring')" false
eq "each profile has its own audience"                 "$(q "$DN" '[.[]|select(.kind=="VirtualMCPServer")|.spec.incomingAuth.oidcConfigRef.audience]|sort|join(",")')" openagentix-vmcp,openagentix-vmcp-lookup,openagentix-vmcp-sender
eq "notify admits every profile vMCP"                  "$(q "$DN" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="notify-ingress")|[.spec.ingress[0].from[]|.podSelector.matchLabels["toolhive-name"]]|sort|join(",")')" tools,tools-lookup,tools-sender
eq "the kb admits every profile vMCP"                  "$(q "$DN" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-ingress")|[.spec.ingress[0].from[]|.podSelector.matchLabels["toolhive-name"]]|sort|join(",")')" tools,tools-lookup,tools-sender
eq "two profiles, two RemoteMCPServers more"           "$(count "$DN" '.kind=="RemoteMCPServer"')" 3

echo "# profiles: render-time failures"
perr() { # perr <description> <expected text in the error> <yaml for -f after the demo profile file>
  printf '%s\n' "$3" > "$PX"
  local e; e=$(render_err "${PNG[@]}" -f "$PX")
  eq "$1" "$(printf '%s' "$e" | command grep -c -- "$2")" 1
}
perr "an unknown profile fails the render" 'toolProfile.*nope' 'agents:
  - {name: pd, model: claude-haiku, systemPrompt: x, toolProfile: nope, tools: [{tools: [osv_query_vulnerability]}]}'
perr "a tool that is not in the profile fails the render" 'fetch_fetch.*profile.*lookup' 'agents:
  - {name: pd, model: claude-haiku, systemPrompt: x, toolProfile: lookup, tools: [{tools: [osv_query_vulnerability, fetch_fetch]}]}'
perr "a tool of the profile's workload that the filter hides fails the render" 'osv_query_vulnerabilities_batch.*lookup' 'agents:
  - {name: pd, model: claude-haiku, systemPrompt: x, toolProfile: lookup, tools: [{tools: [osv_query_vulnerabilities_batch]}]}'
perr "knowledge: true on a profile that lacks the other kb tools fails" 'knowledge_kb_get_document.*lookup' 'agents:
  - {name: pd, model: claude-haiku, systemPrompt: x, toolProfile: lookup, knowledge: true, tools: [{tools: [osv_query_vulnerability]}]}'
perr "duplicate profile names fail the render" 'duplicate.*lookup' 'mcp:
  profiles:
    - {name: lookup, tools: {osv: [query_vulnerability]}}
    - {name: lookup, tools: {osv: [get_vulnerability]}}'
perr "a profile name that would collide with the shared vMCP naming fails" 'profile name' 'mcp:
  profiles:
    - {name: "a b", tools: {osv: [query_vulnerability]}}'
perr "a profile with an unknown workload fails the render" 'workload.*ghost' 'mcp:
  profiles:
    - {name: lookup, tools: {ghost: [x]}}'
perr "a profile workload with no tools fails the render" 'lookup.*osv.*tools' 'mcp:
  profiles:
    - {name: lookup, tools: {osv: []}}'
perr "a profile without any workload fails the render" 'lookup.*tools' 'mcp:
  profiles:
    - {name: lookup, tools: {}}'
perr "execute_tool_script without codeMode on the profile fails" 'execute_tool_script.*codeMode' 'mcp:
  profiles:
    - {name: lookup, tools: {osv: [query_vulnerability]}}'
perr "a profile agent that names another server fails the render (a path around the profile)" 'another server' 'agents:
  - {name: pd, model: claude-haiku, systemPrompt: x, toolProfile: lookup, tools: [{server: toolhive-vmcp, tools: [osv_query_vulnerability]}]}'
perr "profiles need oidc incoming auth" 'incomingAuth.type oidc' 'mcp:
  virtual: {incomingAuth: {type: anonymous}}'
perr "a profile agent needs the RemoteMCPServer switch" 'remoteMCPServer' 'kagent:
  remoteMCPServer: {enabled: false}'
perr "toolProfile with mcp.enabled=false fails" 'toolProfile.*mcp.enabled' 'mcp: {enabled: false}'
perr "toolProfile must be a string" 'toolProfile' 'agents:
  - {name: pd, model: claude-haiku, systemPrompt: x, toolProfile: [lookup]}'
eq "profiles without agents on them render (a profile may be unused)" "$(printf 'agents:\n  - {name: pd, model: claude-haiku, systemPrompt: x}\n' > "$PX"; [ -z "$(render_err "${PNG[@]}" -f "$PX")" ] && echo rendered || echo failed)" rendered

echo "# egress.allow: renders an EgressPolicy, fails on bad entries"
eg() { printf 'agents:\n  - name: pd\n    model: claude-haiku\n    systemPrompt: x\n    egress: %s\n' "$1" > "$PX"; }
eg '{allow: ["https://api.github.com", "https://*.example.com:8443", "http://svc.example.org"]}'
DE=$(docs -f "$PX")
eq "an agent on the shared vMCP can have egress.allow" "$(q "$DE" '.[]|select(.kind=="EgressPolicy")|[.metadata.name,(.spec.destinations|map(.origin)|join(","))]|join(" ")')" "pd-egress https://api.github.com,https://*.example.com:8443,http://svc.example.org"
eq "the Agent carries egressPolicyRefs"                "$(q "$DE" '.[]|select(.kind=="Agent")|.spec.egressPolicyRefs|map(.name)|join(",")')" pd-egress
eq "the EgressPolicy is in the agent's namespace"      "$(q "$DE" '.[]|select(.kind=="EgressPolicy")|.metadata.namespace')" kagent
eg '{allow: []}'
eq "an empty allow list renders nothing"               "$(count "$(docs -f "$PX")" '.kind=="EgressPolicy"')" 0
eq "an empty allow list adds no egressPolicyRefs"      "$(q "$(docs -f "$PX")" '.[]|select(.kind=="Agent")|.spec|has("egressPolicyRefs")|tostring')" false
eg '{}'
eq "egress without allow renders nothing"              "$(count "$(docs -f "$PX")" '.kind=="EgressPolicy"')" 0
for bad in '"api.github.com"' '"ftp://example.com"' '"https://example.com/path"' '"https://Example.com"' '"https://1.2.3.4"' '"https://*"' '"https://*.com"' '"https://exa mple.com"' '"https://example.com:0"' '"https://example.com:99999"' '"https://user@example.com"' '"https://example.com?x=1"' '""' '5'; do
  eg "{allow: [$bad]}"
  eq "malformed entry $bad fails the render"           "$([ -n "$(render_err -f "$PX")" ] && echo failed || echo rendered)" failed
done
eg '{allow: ["https://example.com", "https://example.com"]}'
eq "a duplicate entry fails the render"               "$([ -n "$(render_err -f "$PX")" ] && echo failed || echo rendered)" failed
eg '{allow: "https://example.com"}'
eq "allow must be a list"                              "$([ -n "$(render_err -f "$PX")" ] && echo failed || echo rendered)" failed
eg '[https://example.com]'
eq "egress must be a map"                              "$([ -n "$(render_err -f "$PX")" ] && echo failed || echo rendered)" failed
eg '{allow: ["http://vmcp-tools.mcp-tools.svc.cluster.local:4483"]}'
eq "an origin that is the shared vMCP fails the render" "$([ -n "$(render_err -f "$PX")" ] && echo failed || echo rendered)" failed
eg '{allow: ["http://vmcp-tools-lookup.mcp-tools.svc.cluster.local:4483"]}'
eq "an origin that is a profile vMCP fails the render" "$([ -n "$(render_err -f "$PV" -f "$PX")" ] && echo failed || echo rendered)" failed
eg '{allow: ["http://vmcp-tools.mcp-tools.svc.cluster.local:4483"]}'
eq "and the same origin on a profile agent as well"    "$([ -n "$(render_err -f "$PV" -f "$PX")" ] && echo failed || echo rendered)" failed
eg "{allow: [$(for i in $(seq 1 17); do printf '"https://h%s.example.com",' $i; done | sed 's/,$//')]}"
eq "more than 16 origins is fine (limit is 64)"        "$([ -z "$(render_err -f "$PX")" ] && echo rendered || echo failed)" rendered
eg "{allow: [$(for i in $(seq 1 65); do printf '"https://h%s.example.com",' $i; done | sed 's/,$//')]}"
eq "more than 64 origins fails the render"             "$([ -n "$(render_err -f "$PX")" ] && echo failed || echo rendered)" failed
eg '{allow: ["https://api.github.com"]}'
eq "kagent.enabled=false: egress.allow renders nothing" "$(count "$(docs -f "$PX" --set kagent.enabled=false)" '.kind=="EgressPolicy"')" 0
rm -f "$PX"

echo "# memory governance (ADR 0006, round 3): everything is off by default"
MD="$REPO/components/governance/memory-demo-values.yaml"
MON=("${GON[@]}" -f "$MD")
eq "memory.expiry.enabled defaults to false"           "$(yq -c .memory.expiry.enabled "$CHART/values.yaml")" false
eq "memory.expiry.secretScan defaults to false"        "$(yq -c .memory.expiry.secretScan "$CHART/values.yaml")" false
eq "memory.expiry.secretScanDelete defaults to false"  "$(yq -c .memory.expiry.secretScanDelete "$CHART/values.yaml")" false
eq "bridge.memoryCommands defaults to false"           "$(yq -c .bridge.memoryCommands "$CHART/values.yaml")" false
D=$(docs "${GON[@]}")
eq "off: no memory-expiry object of any kind"          "$(count "$D" '(.metadata.name|tostring|test("memory-expiry|kagent-pg"))')" 0
eq "off: the bridge has no memory env"                 "$(q "$D" "$BD|[.spec.template.spec.containers[0].env[]|select(.name|test(\"MEMORY\"))]|length")" 0
eq "off: no rule has a memory flag"                    "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]|fromjson|[.callers[]|has("memory")]|any')" false

echo "# memory governance: the expiry CronJob"
DM=$(docs "${MON[@]}")
MC='.[]|select(.kind=="CronJob" and .metadata.name=="memory-expiry")'
MP="$MC|.spec.jobTemplate.spec.template.spec"
MCT="$MP|.containers[0]"
eq "one CronJob memory-expiry in the kagent namespace" "$(q "$DM" "[$MC|.metadata.namespace]|join(\",\")")" kagent
eq "default schedule is nightly"                        "$(q "$DM" "$MC|.spec.schedule")" "17 3 * * *"
eq "overlapping runs are forbidden"                     "$(q "$DM" "$MC|.spec.concurrencyPolicy")" Forbid
eq "a failed run is not retried (the next night runs again)" "$(q "$DM" "$MC|.spec.jobTemplate.spec.backoffLimit|tostring")" 0
eq "the run is bounded in time"                         "$(q "$DM" "$MC|.spec.jobTemplate.spec.activeDeadlineSeconds|tostring")" 300
eq "image is the server's own pinned image (client matches the server major version)" "$(q "$DM" "$MCT|.image")" "pgvector/pgvector:pg17@sha256:b513c48566e4777cd3370451400000c78eda6a08131d68f4c31d4a76f27bd8fd"
eq "the image is never pulled when present"             "$(q "$DM" "$MCT|.imagePullPolicy")" IfNotPresent
eq "the database URL comes from the existing Secret by reference" "$(q "$DM" "$MCT|.env[]|select(.name==\"KAGENT_DB_URL\")|.valueFrom.secretKeyRef|[.name,.key]|join(\" \")")" "kagent-postgres-readwrite readWriteConnectionString"
eq "the database URL has no literal value"              "$(q "$DM" "$MCT|.env[]|select(.name==\"KAGENT_DB_URL\")|has(\"value\")|tostring")" false
eq "schema and role are passed"                         "$(q "$DM" "$MCT|[.env[]|select(.name==\"MEMORY_SCHEMA\" or .name==\"MEMORY_DB_ROLE\")|.value]|join(\" \")")" "kagent kagent_readwrite"
eq "secret scan on, delete off in the demo"             "$(q "$DM" "$MCT|[.env[]|select(.name==\"SECRET_SCAN\" or .name==\"SECRET_SCAN_DELETE\")|.value]|join(\" \")")" "1 0"
eq "runs the mounted script"                            "$(q "$DM" "$MCT|.command|join(\" \")")" "sh /scripts/memory-expiry.sh"
eq "the script ConfigMap holds the file from the chart" "$(q "$DM" '.[]|select(.kind=="ConfigMap" and .metadata.name=="memory-expiry-script")|.data["memory-expiry.sh"]|test("PruneExpiredMemories") and test("expires_at < NOW\\(\\) AND access_count >= 10") and test("expires_at < NOW\\(\\) AND access_count < 10")')" true
eq "the script quotes kagent's path and line"           "$(q "$DM" '.[]|select(.kind=="ConfigMap" and .metadata.name=="memory-expiry-script")|.data["memory-expiry.sh"]|test("go/core/internal/database/memory.go lines 125-139")')" true
eq "the pod rolls when the script changes"              "$(q "$DM" "$MC|.spec.jobTemplate.spec.template.metadata.annotations[\"checksum/script\"]|test(\"^[0-9a-f]{64}\$\")")" true
eq "pod labels are the ones the database policy admits" "$(q "$DM" "$MC|.spec.jobTemplate.spec.template.metadata.labels|[.app,.[\"openagentix.io/component\"]]|join(\" \")")" "memory-expiry memory-expiry"
eq "no ServiceAccount token in the pod"                 "$(q "$DM" "$MP|.automountServiceAccountToken|tostring")" false
eq "non-root, read-only root filesystem, no capabilities" "$(q "$DM" "$MP|[.securityContext.runAsNonRoot,(.containers[0].securityContext.readOnlyRootFilesystem),(.containers[0].securityContext.allowPrivilegeEscalation),(.containers[0].securityContext.capabilities.drop|join(\",\"))]|tostring")" '[true,true,false,"ALL"]'
eq "restartPolicy Never"                                "$(q "$DM" "$MP|.restartPolicy")" Never
eq "the job has resource limits"                        "$(q "$DM" "$MCT|.resources.limits|has(\"memory\") and has(\"cpu\")|tostring")" true
eq "no Secret object and no URL with a password"        "$(q "$DM" '[.[]|select(.kind=="Secret")]|length')" 0
eq "no rendered document holds a connection string"     "$(q "$DM" 'tostring|test("postgres(ql)?://[^ ]*@")')" false
DM2=$(docs "${MON[@]}" --set memory.expiry.secretScan=false)
eq "secretScan=false passes 0"                          "$(q "$DM2" "$MCT|.env[]|select(.name==\"SECRET_SCAN\")|.value")" 0
DM3=$(docs "${MON[@]}" --set memory.expiry.secretScanDelete=true)
eq "secretScanDelete=true passes 1"                     "$(q "$DM3" "$MCT|.env[]|select(.name==\"SECRET_SCAN_DELETE\")|.value")" 1
DM4=$(docs "${MON[@]}" --set 'memory.expiry.schedule=5 4 * * 0' --set memory.expiry.schema=kagent2 --set memory.expiry.secret.name=my-db --set memory.expiry.secret.key=url)
eq "schedule, schema and Secret are values"             "$(q "$DM4" "[($MC|.spec.schedule),($MCT|.env[]|select(.name==\"MEMORY_SCHEMA\")|.value),($MCT|.env[]|select(.name==\"KAGENT_DB_URL\")|.valueFrom.secretKeyRef.name)]|join(\"|\")")" '5 4 * * 0|kagent2|my-db'
eq "kagent.enabled=false renders no expiry job"         "$(count "$(docs "${MON[@]}" --set kagent.enabled=false 2>/dev/null)" '.kind=="CronJob" and .metadata.name=="memory-expiry"')" 0
eq "expiry works without the gate (it needs only the database)" "$(count "$(docs --set memory.expiry.enabled=true)" '.kind=="CronJob" and .metadata.name=="memory-expiry"')" 1

echo "# memory governance: validation"
badv() { eq "bad value fails the render: $1=$2" "$([ -n "$(render_err "${MON[@]}" --set-string "$1=$2")" ] && echo failed || echo rendered)" failed; }
eq "secretScanDelete without secretScan fails the render" "$([ -n "$(render_err "${MON[@]}" --set memory.expiry.secretScan=false --set memory.expiry.secretScanDelete=true)" ] && echo failed || echo rendered)" failed
badv memory.expiry.secretScan yes
badv memory.expiry.secretScanDelete maybe
badv memory.expiry.enabled maybe
badv memory.expiry.schedule nightly
badv memory.expiry.schedule "* * * *"
badv memory.expiry.schedule "* * * * * *"
badv memory.expiry.schema "a;b"
badv memory.expiry.schema "Kagent"
badv memory.expiry.schema ""
badv memory.expiry.role "x y"
badv memory.expiry.secret.name ""
badv memory.expiry.secret.name "UPPER"
badv memory.expiry.activeDeadlineSeconds 5
eq "an expiry block with a bad value is not checked while it is off" "$([ -z "$(render_err --set memory.expiry.schedule=nightly)" ] && echo rendered || echo failed)" rendered

echo "# memory governance: network policy of kagent's PostgreSQL"
NPG='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-pg")'
eq "a policy selects the database pods"                 "$(q "$DM" "$NPG|[.metadata.namespace,(.spec.podSelector.matchLabels|tostring),(.spec.policyTypes|join(\",\"))]|join(\" \")")" 'kagent {"app":"kagent-pg"} Ingress'
eq "it admits only the controller and the expiry job on 5432" "$(q "$DM" "$NPG|[.spec.ingress[]|.ports[0].port]|tostring")" '[5432]'
eq "two peers: the controller pods and the job pods"    "$(q "$DM" "$NPG|[.spec.ingress[].from[]|(.podSelector.matchLabels|to_entries|map(.value)|join(\"/\"))]|sort|join(\",\")")" 'controller/kagent,memory-expiry'
eq "both peers are in the kagent namespace"             "$(q "$DM" "$NPG|[.spec.ingress[].from[].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]]|unique|join(\",\")")" kagent
eq "networkPolicy.enabled=false renders no database policy" "$(count "$(docs "${MON[@]}" --set networkPolicy.enabled=false)" '.kind=="NetworkPolicy" and .metadata.name=="openagentix-kagent-pg"')" 0
eq "networkPolicy.enabled=false still renders the job"  "$(count "$(docs "${MON[@]}" --set networkPolicy.enabled=false)" '.kind=="CronJob" and .metadata.name=="memory-expiry"')" 1
eq "pod labels of the database are a value"             "$(q "$(docs "${MON[@]}" --set networkPolicy.kagentPostgres.podLabels.app=pg2)" "$NPG|.spec.podSelector.matchLabels.app")" pg2

echo "# memory governance: the bridge commands and the gate rule"
BM='.spec.template.spec.containers[0].env'
eq "bridge: the gate URL is the memory URL"             "$(q "$DM" "$BD|$BM[]|select(.name==\"MEMORY_GATE_URL\")|.value")" http://a2a-gate.openagentix-gateway.svc.cluster.local:8080
eq "bridge: the agent is the bridge's agent"            "$(q "$DM" "$BD|$BM[]|select(.name==\"MEMORY_AGENT\")|.value")" kagent/assistant
eq "the bridge has no new volume or token"              "$(q "$DM" "$BD|[.spec.template.spec.volumes[].name]|join(\",\")")" a2a-token
RM=$(q "$DM" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]')
eq "rules: the bridge has memory true"                  "$(jq -r '.callers[]|select(.name=="bridge")|.memory|tostring' <<<"$RM")" true
eq "rules: no other caller has a memory flag, except the demo canary" "$(jq -r '[.callers[]|select(.name!="bridge" and .name!="memory-canary")|has("memory")]|any|tostring' <<<"$RM")" false
eq "rules: the demo canary may use memory for probe: ids only" "$(jq -r '.callers[]|select(.name=="memory-canary")|[.memory,.userId.prefix,(.agents|join(","))]|map(tostring)|join(" ")' <<<"$RM")" "true probe: kagent/assistant"
eq "the memory demo alone (gate off) fails the render, it needs the gate demo" "$([ -n "$(render_err -f "$MD")" ] && echo failed || echo rendered)" failed
eq "rules: the bridge keeps SendMessage as its only A2A method" "$(jq -r '.callers[]|select(.name=="bridge")|.methods|join(",")' <<<"$RM")" SendMessage
eq "memoryCommands without the gate fails the render"   "$([ -n "$(render_err "${GOFF[@]}" --set bridge.memoryCommands=true)" ] && echo failed || echo rendered)" failed
eq "memoryCommands without the bridge fails the render" "$([ -n "$(render_err "${GON[@]}" --set bridge.memoryCommands=true --set bridge.enabled=false)" ] && echo failed || echo rendered)" failed
eq "memoryCommands must be a boolean"                   "$([ -n "$(render_err "${GON[@]}" --set bridge.memoryCommands=yes)" ] && echo failed || echo rendered)" failed
eq "the bridge A2A_URL override does not move the memory URL" "$(q "$(docs "${MON[@]}" --set bridge.a2aUrl=http://x/y)" "$BD|$BM[]|select(.name==\"MEMORY_GATE_URL\")|.value")" http://a2a-gate.openagentix-gateway.svc.cluster.local:8080
MX="$(dirname "$0")/.memory-variant.yaml"
yq -y '{agents: (.agents|map(if .name=="assistant" then del(.memory) else . end))}' "$CHART/values.yaml" > "$MX"
E=$(render_err "${MON[@]}" -f "$MX")
eq "the bridge agent must have memory on"               "$(printf '%s' "$E" | command grep -c 'memoryCommands.*memory.enabled')" 1
printf 'bridge:\n  agent: ghost\n  memoryCommands: true\n' > "$MX"
eq "an unknown bridge agent fails the render"           "$([ -n "$(render_err "${GON[@]}" -f "$MX")" ] && echo failed || echo rendered)" failed
cat > "$MX" <<'YAML'
governance:
  a2a:
    callers:
      - {name: ci-mem, serviceAccount: {namespace: ci, name: mem}, agents: [assistant], userId: {prefix: "ci:"}, memory: true}
      - {name: ci-plain, serviceAccount: {namespace: ci, name: plain}, agents: [assistant], userId: {prefix: "ci2:"}}
YAML
RX=$(q "$(docs "${GON[@]}" -f "$MX")" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-rules")|.data["rules.json"]')
eq "an extra caller can have memory: true"              "$(jq -r '.callers[]|select(.name=="ci-mem")|.memory|tostring' <<<"$RX")" true
eq "and one without it has no flag"                     "$(jq -r '.callers[]|select(.name=="ci-plain")|has("memory")|tostring' <<<"$RX")" false
printf 'governance:\n  a2a:\n    callers:\n      - {name: ci-mem, serviceAccount: {namespace: ci, name: mem}, agents: [assistant], userId: {prefix: "ci:"}, memory: "yes"}\n' > "$MX"
eq "memory: must be a boolean for an extra caller"      "$([ -n "$(render_err "${GON[@]}" -f "$MX")" ] && echo failed || echo rendered)" failed
rm -f "$MX"
eq "no Secret object with everything on"                "$(count "$(docs "${MON[@]}" "${PALL[@]:0:0}")" '.kind=="Secret"')" 0

echo "# control plane (ADR 0007, slice 1): off by default"
CPV="$REPO/components/control-plane/demo-values.yaml"
CP8=(-f "$REPO/components/channels/demo-values.yaml" -f "$REPO/components/schedules/demo-values.yaml" -f "$REPO/components/notify/demo-values.yaml" -f "$REPO/components/observability/demo-values.yaml" -f "$REPO/components/knowledge/graph-demo-values.yaml" -f "$REPO/components/governance/demo-values.yaml" -f "$REPO/components/governance/profiles-demo-values.yaml" -f "$REPO/components/governance/memory-demo-values.yaml")
CP9=("${CP8[@]}" -f "$CPV")
CPSVC="$REPO/services/control-plane"
D=$(docs)
eq "no control plane objects by default"               "$(count "$D" '.metadata.name|tostring|test("control-plane|agent-builder|agent-viewer|agentdefinitions")')" 0
H0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
CPX="$(dirname "$0")/.cp-variant.yaml"
cat > "$CPX" <<'YAML'
controlPlane:
  enabled: false
  namespace: elsewhere
  sourceHash: abc
  apiServerCIDRs: [10.0.0.0/24]
  policy: {maxAgents: 1, allowedModels: ["*"], allowedProfiles: ["*"], allowNotify: true, memory: {allowed: true}}
YAML
H1=$(helm template openagentix "$CHART" -n openagentix-system -f "$CPX" 2>&1 | shasum -a 256)
eq "controlPlane.enabled=false (other controlPlane values set) is byte-identical to the default render" "$H1" "$H0"
H2=$(helm template openagentix "$CHART" -n openagentix-system -f /dev/stdin <<<'controlPlane: null' 2>&1 | shasum -a 256)
eq "controlPlane=null is byte-identical to the default render" "$H2" "$H0"
HD8=$(helm template openagentix "$CHART" -n openagentix-system "${CP8[@]}" 2>&1 | shasum -a 256)
HD8X=$(helm template openagentix "$CHART" -n openagentix-system "${CP8[@]}" -f "$CPX" 2>&1 | shasum -a 256)
eq "the eight demo files render byte-identically with the switch off and controlPlane values set" "$HD8X" "$HD8"
rm -f "$CPX"
if [ -n "${OA_BASELINE_DEMO8_RENDER:-}" ]; then   # the same render at the previous commit
  eq "the eight demo files render byte-identically to the baseline (OA_BASELINE_DEMO8_RENDER)" "$HD8" "$(shasum -a 256 < "$OA_BASELINE_DEMO8_RENDER")"
fi
eq "the nine demo files render"                        "$([ -z "$(render_err "${CP9[@]}")" ] && echo rendered || echo failed)" rendered

echo "# control plane: the objects"
D=$(docs "${CP9[@]}")
CPNS=openagentix-system
CPD='.[]|select(.kind=="Deployment" and .metadata.name=="openagentix-control-plane")'
CPP="$CPD|.spec.template.spec"
CPC="$CPP|.containers[0]"
eq "the CRD is rendered once"                          "$(count "$D" '.kind=="CustomResourceDefinition" and .metadata.name=="agentdefinitions.openagentix.io"')" 1
eq "the CRD is kept on helm uninstall"                 "$(q "$D" '.[]|select(.kind=="CustomResourceDefinition" and .metadata.name=="agentdefinitions.openagentix.io")|.metadata.annotations["helm.sh/resource-policy"]')" keep
eq "the chart's CRD file is byte-identical to the service's"  "$(cmp -s "$CHART/files/agentdefinition-crd.yaml" "$CPSVC/crd/agentdefinition.yaml" && echo identical || echo differs)" identical
CRDR=$(q "$D" '.[]|select(.kind=="CustomResourceDefinition" and .metadata.name=="agentdefinitions.openagentix.io")|del(.metadata.annotations)|walk(if type=="object" then with_entries(select(.value!=null)) else . end)' | jq -S .)
CRDS=$(yq -c . "$CPSVC/crd/agentdefinition.yaml" | jq -S 'walk(if type=="object" then with_entries(select(.value!=null)) else . end)')
eq "the rendered CRD equals the service's CRD (annotations aside)" "$([ "$CRDR" = "$CRDS" ] && echo identical || echo differs)" identical
eq "catalog ConfigMap"                                 "$(count "$D" '.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog" and .metadata.namespace=="'$CPNS'"')" 1
eq "policy ConfigMap"                                  "$(count "$D" '.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy" and .metadata.namespace=="'$CPNS'"')" 1
CAT=$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]')
POL=$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]')
eq "catalog.json parses"                               "$(jq -e type <<<"$CAT" 2>/dev/null)" '"object"'
eq "policy.json parses"                                "$(jq -e type <<<"$POL" 2>/dev/null)" '"object"'
eq "catalog equals the controller's testdata/catalog.json (demo values, normalised, reservedNames aside)" "$([ "$(jq -S 'del(.reservedNames)' <<<"$CAT")" = "$(jq -S 'del(.reservedNames)' "$CPSVC/testdata/catalog.json")" ] && echo equal || echo differs)" equal
eq "the chart's reservedNames contain every name of the controller's testdata/catalog.json" "$(jq -n --argjson a "$CAT" --slurpfile b "$CPSVC/testdata/catalog.json" '(($b[0].reservedNames)-($a.reservedNames))|length')" 0
CPT="$(dirname "$0")/.cp-testdata-policy.yaml"
jq '{controlPlane: {policy: .}}' "$CPSVC/testdata/policy.json" > "$CPT"
POLT=$(q "$(docs "${CP9[@]}" -f "$CPT")" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]')
eq "policy equals the controller's testdata/policy.json when the values say the same (normalised)" "$([ "$(jq -S . <<<"$POLT")" = "$(jq -S . "$CPSVC/testdata/policy.json")" ] && echo equal || echo differs)" equal
rm -f "$CPT"
eq "demo policy: one model, one profile, knowledge, no notify, no memory, no egress" "$(jq -c '[.allowedModels,.allowedProfiles,.allowKnowledge,.allowNotify,.memory.allowed,.egress.allowedOrigins,.allowedSkills,.requireToolProfile,.maxAgents]' <<<"$POL")" '[["claude-haiku"],["lookup"],true,false,false,[],[],true,5]'
eq "demo catalog lists the profile server and its tools" "$(jq -c '.tools.toolhive.profiles[0]|[.name,.toolServer,.codeMode]' <<<"$CAT")" '["lookup","toolhive-vmcp-lookup",true]'
eq "no Secret object and no Secret reference in the catalog or policy" "$(printf '%s%s' "$CAT" "$POL" | command grep -ciE 'secretRef|apiKeySecret|virtual-key' || true)" 0
eq "no secret-shaped value in the catalog or policy"   "$(printf '%s%s' "$CAT" "$POL" | command grep -cE 'vk-[0-9a-f]{16,}|sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{12,}|xox[bpa]-[0-9A-Za-z-]{10,}|BEGIN [A-Z ]*PRIVATE KEY|eyJ[A-Za-z0-9_-]{10,}[.]' || true)" 0
KC='.[]|select(.kind=="ConfigMap" and .metadata.name=="llm-api-keys-control-plane")'
eq "the controller's key ConfigMap is in the gateway namespace" "$(q "$D" "$KC|.metadata.namespace")" agentgateway-system
eq "the key ConfigMap carries the gateway's selector label"    "$(q "$D" "$KC|.metadata.labels[\"agentgateway.dev/apikey\"]")" true
eq "the key ConfigMap has no data key at all"          "$(q "$D" "$KC|[has(\"data\"),has(\"binaryData\")]|any")" false
eq "the key ConfigMap is kept on helm uninstall"       "$(q "$D" "$KC|.metadata.annotations[\"helm.sh/resource-policy\"]")" keep
eq "exactly one key ConfigMap of the control plane"    "$(count "$D" '.kind=="ConfigMap" and .metadata.name=="llm-api-keys-control-plane"')" 1
eq "the installer's key ConfigMap name is not rendered by the chart" "$(count "$D" '.kind=="ConfigMap" and .metadata.name=="llm-api-keys"')" 0
eq "ServiceAccount"                                    "$(count "$D" '.kind=="ServiceAccount" and .metadata.name=="openagentix-control-plane" and .metadata.namespace=="'$CPNS'"')" 1
RQ='.[]|select(.kind=="ResourceQuota" and .metadata.name=="openagentix-agentdefinitions")'
eq "ResourceQuota caps the number of definitions in the agents namespace" "$(q "$D" "$RQ|[.metadata.namespace,(.spec.hard|tojson)]|join(\" \")")" 'kagent {"count/agentdefinitions.openagentix.io":"50"}'
eq "exactly one ResourceQuota is rendered"             "$(count "$D" '.kind=="ResourceQuota"')" 1
eq "controlPlane.maxDefinitions sets the cap"          "$(q "$(docs "${CP9[@]}" --set controlPlane.maxDefinitions=7)" "$RQ|.spec.hard[\"count/agentdefinitions.openagentix.io\"]")" 7
eq "the quota is namespaced like the agents (kagent.namespace)" "$(q "$(docs --set controlPlane.enabled=true --set kagent.namespace=ag2)" "$RQ|.metadata.namespace")" ag2
eq "the cap is documented next to policy.maxAgents in values.yaml" "$(command grep -c 'refused drafts count' "$CHART/values.yaml")" 1

echo "# control plane: permissions (namespaced Roles only)"
RA='.[]|select(.kind=="Role" and .metadata.name=="openagentix-control-plane" and .metadata.namespace=="kagent")'
RG='.[]|select(.kind=="Role" and .metadata.name=="openagentix-control-plane" and .metadata.namespace=="agentgateway-system")'
eq "no ClusterRole or ClusterRoleBinding comes from the control plane" "$(count "$D" '(.kind=="ClusterRole" or .kind=="ClusterRoleBinding") and (.metadata.name|test("control-plane|agent-builder|agent-viewer"))')" 0
eq "Role in the kagent namespace"                      "$(count "$D" '.kind=="Role" and .metadata.name=="openagentix-control-plane" and .metadata.namespace=="kagent"')" 1
eq "Role in the gateway namespace"                     "$(count "$D" '.kind=="Role" and .metadata.name=="openagentix-control-plane" and .metadata.namespace=="agentgateway-system"')" 1
eq "RoleBindings bind the ServiceAccount, one per Role" "$(q "$D" '[.[]|select(.kind=="RoleBinding" and .metadata.name=="openagentix-control-plane")|[.metadata.namespace,.roleRef.kind,.roleRef.name,.subjects[0].kind,.subjects[0].name,.subjects[0].namespace]|join("/")]|sort|join(" ")')" "agentgateway-system/Role/openagentix-control-plane/ServiceAccount/openagentix-control-plane/$CPNS kagent/Role/openagentix-control-plane/ServiceAccount/openagentix-control-plane/$CPNS"
eq "Secrets: exactly create and delete, one rule"      "$(q "$D" "$RA|[.rules[]|select(.resources|index(\"secrets\"))]|map(.verbs|sort|join(\",\"))|join(\";\")")" create,delete
eq "Secrets rule has no resourceNames (create cannot have them)" "$(q "$D" "$RA|[.rules[]|select(.resources|index(\"secrets\"))|has(\"resourceNames\")]|any")" false
eq "definitions: get, list, watch, update"             "$(q "$D" "$RA|.rules[]|select(.resources==[\"agentdefinitions\"])|.verbs|sort|join(\",\")")" get,list,update,watch
eq "definitions/status: patch"                         "$(q "$D" "$RA|.rules[]|select(.resources==[\"agentdefinitions/status\"])|.verbs|join(\",\")")" patch
eq "kagent kinds: get, list, create, patch, delete (no watch: the controller never watches them)" "$(q "$D" "$RA|.rules[]|select(.apiGroups==[\"api.kagent.dev\"])|[(.resources|sort|join(\",\")),(.verbs|sort|join(\",\"))]|join(\" \")")" "agents,agenttemplates,egresspolicies,harnesses,modelconfigs create,delete,get,list,patch"
eq "the kagent Role has exactly four rules"            "$(q "$D" "$RA|.rules|length")" 4
eq "gateway Role: one rule, ConfigMaps"                "$(q "$D" "$RG|.rules|length")" 1
eq "gateway Role: only llm-api-keys-control-plane"     "$(q "$D" "$RG|.rules[0]|[(.resources|join(\",\")),(.resourceNames|join(\",\")),(.verbs|sort|join(\",\"))]|join(\" \")")" "configmaps llm-api-keys-control-plane get,patch"
eq "no wildcard in any rule of the block"              "$(q "$D" '[.[]|select((.kind=="Role" or .kind=="ClusterRole") and (.metadata.name|test("control-plane|agent-builder|agent-viewer")))|.rules[]|(.verbs+.resources+.apiGroups+(.resourceNames//[]))[]|select(.=="*")]|length')" 0
eq "builder Role is rendered, in the kagent namespace" "$(q "$D" '.[]|select(.kind=="Role" and .metadata.name=="openagentix-agent-builder")|.metadata.namespace')" kagent
eq "builder writes agentdefinitions and nothing else" "$(q "$D" '.[]|select(.kind=="Role" and .metadata.name=="openagentix-agent-builder")|[.rules[]|[(.apiGroups|join(",")),(.resources|join(","))]|join(" ")]|unique|join(";")')" "openagentix.io agentdefinitions;openagentix.io agentdefinitions/status"
eq "builder has no verb on Secrets, kagent kinds or pods/exec" "$(q "$D" '.[]|select(.kind=="Role" and .metadata.name=="openagentix-agent-builder")|[.rules[].resources[]|select(test("secrets|exec|api.kagent|agents$|harnesses"))]|length')" 0
eq "builder may create, update and delete"             "$(q "$D" '.[]|select(.kind=="Role" and .metadata.name=="openagentix-agent-builder")|[.rules[].verbs[]]|unique|join(",")')" create,delete,get,list,patch,update,watch
eq "viewer Role reads definitions only"                "$(q "$D" '.[]|select(.kind=="Role" and .metadata.name=="openagentix-agent-viewer")|[.rules[].verbs[]]|unique|join(",")')" get,list,watch
eq "viewer Role names agentdefinitions"                "$(q "$D" '.[]|select(.kind=="Role" and .metadata.name=="openagentix-agent-viewer")|[.rules[].resources[]]|unique|join(",")')" agentdefinitions,agentdefinitions/status
eq "builder and viewer are rendered WITHOUT bindings"  "$(count "$D" '(.kind=="RoleBinding" or .kind=="ClusterRoleBinding") and (.roleRef.name|test("agent-builder|agent-viewer"))')" 0

echo "# control plane: the output guard (ValidatingAdmissionPolicy)"
# The expressions are EXECUTED by hack/ci/guardtest (make test-guard, the CI job `guard`): this block checks the structure around them.
GP='.[]|select(.kind=="ValidatingAdmissionPolicy" and (.metadata.name|startswith("openagentix-control-plane-guard-")))'
GB='.[]|select(.kind=="ValidatingAdmissionPolicyBinding" and (.metadata.name|startswith("openagentix-control-plane-guard-")))'
SAU="system:serviceaccount:$CPNS:openagentix-control-plane"
eq "no policy of the previous name is rendered"        "$(count "$D" '(.kind=="ValidatingAdmissionPolicy" or .kind=="ValidatingAdmissionPolicyBinding") and .metadata.name=="openagentix-control-plane-output-guard"')" 0
eq "eight policies, one per kind, and the last rule"   "$(q "$D" "[$GP|.metadata.name|ltrimstr(\"openagentix-control-plane-guard-\")]|sort|join(\",\")")" "agents,agenttemplates,configmaps,egresspolicies,harnesses,modelconfigs,other,secrets"
eq "one binding per policy, each refers to its policy"  "$(q "$D" "[$GB|select(.metadata.name==.spec.policyName)]|length")+$(q "$D" "[$GB]|length")" 8+8
eq "every binding denies (and only denies)"           "$(q "$D" "[$GB|.spec.validationActions|join(\",\")]|unique|join(\" \")")" Deny
eq "every policy fails closed"                         "$(q "$D" "[$GP|.spec.failurePolicy]|unique|join(\",\")")" Fail
eq "every policy applies to the controller's ServiceAccount only (matchCondition names the username)" "$(q "$D" "[$GP|.spec.matchConditions|map(.expression)|join(\" \")|contains(\"$SAU\")]|unique|join(\",\")")" true
eq "every validation has a message"                    "$(q "$D" "[$GP|.spec.validations[]|(.message//\"\")==\"\"]|any")" false
eq "no policy matches CONNECT or names an operation of its own other than CREATE, UPDATE, DELETE (the last rule: all)" "$(q "$D" "[$GP|select(.metadata.name!=\"openagentix-control-plane-guard-other\")|.spec.matchConstraints.resourceRules[].operations[]]|unique|join(\",\")")" CREATE,DELETE,UPDATE
eq "the five kagent kinds are one policy each"         "$(q "$D" "[$GP|select(.spec.matchConstraints.resourceRules[0].apiGroups==[\"api.kagent.dev\"])|.spec.matchConstraints.resourceRules[0].resources[0]]|sort|join(\",\")")" agents,agenttemplates,egresspolicies,harnesses,modelconfigs
eq "Secrets are matched for UPDATE too (so that an UPDATE can be refused)" "$(q "$D" "$GP|select(.metadata.name==\"openagentix-control-plane-guard-secrets\")|.spec.matchConstraints.resourceRules[0].operations|sort|join(\",\")")" CREATE,DELETE,UPDATE
eq "the last rule matches everything and excludes Secrets, ConfigMaps, the kagent kinds and the definitions' UPDATE" "$(q "$D" "$GP|select(.metadata.name==\"openagentix-control-plane-guard-other\")|[.spec.matchConstraints.resourceRules[0].resources[],(.spec.matchConstraints.excludeResourceRules|map(.resources|join(\"+\"))|join(\";\")),(.spec.validations|map(.expression)|join(\";\"))]|join(\" \")")" "*/* secrets+configmaps;modelconfigs+harnesses+agenttemplates+egresspolicies+agents;agentdefinitions+agentdefinitions/status false"
eq "the guard states an ALLOWLIST: no blocklist wording is left, keys are listed with all(k, k in [...])" "$(q "$D" "[$GP|(.spec.validations|map(.expression)|join(\"\\n\"))]|join(\"\\n\")|[scan(\"all\\\\(k, k in \\\\[\")]|length>=40")" true
eq "the EgressPolicy rule lists no authentication key (only origin)" "$(q "$D" "$GP|select(.metadata.name==\"openagentix-control-plane-guard-egresspolicies\")|.spec.validations|map(.expression)|join(\"\\n\")|(contains(\"k in ['origin']\") and (contains(\"authentication\")|not))")" true
eq "the EgressPolicy rule allows exactly the operator's in-cluster destinations (none by default)" "$(q "$D" "$GP|select(.metadata.name==\"openagentix-control-plane-guard-egresspolicies\")|.spec.validations|map(.expression)|join(\"\\n\")|contains(\"hp in []\")")" true
DKS=$(docs --set controlPlane.enabled=true --set kagent.namespace=ag2)
eq "the kagent namespace follows into the Secret rule"  "$(q "$DKS" "$GP|select(.metadata.name==\"openagentix-control-plane-guard-secrets\")|.spec.validations[0].expression|contains(\"ag2\")")" true
eq "...and into the names of the key ConfigMap's entries" "$(q "$DKS" "$GP|select(.metadata.name==\"openagentix-control-plane-guard-configmaps\")|.spec.validations|map(.expression)|join(\" \")|contains(\"^ag2\")")" true
DIC=$(docs "${CP9[@]}" --set 'controlPlane.policy.egress.inClusterDestinations={registry.ci.svc:5000,db.data.svc.cluster.local:5432}')
eq "the operator's in-cluster destinations are the only exception in the guard" "$(q "$DIC" "$GP|select(.metadata.name==\"openagentix-control-plane-guard-egresspolicies\")|.spec.validations|map(.expression)|join(\"\\n\")|contains(\"hp in [\\\"registry.ci.svc:5000\\\",\\\"db.data.svc.cluster.local:5432\\\"]\")")" true

echo "# control plane: the Deployment"
eq "Deployment in the control plane namespace"         "$(q "$D" "$CPD|.metadata.namespace")" "$CPNS"
eq "one replica"                                       "$(q "$D" "$CPD|.spec.replicas")" 1
eq "strategy Recreate"                                 "$(q "$D" "$CPD|.spec.strategy.type")" Recreate
eq "image"                                             "$(q "$D" "$CPC|.image")" openagentix/control-plane:dev
eq "ServiceAccount"                                    "$(q "$D" "$CPP|.serviceAccountName")" openagentix-control-plane
eq "runs as non-root 65532"                            "$(q "$D" "$CPP|.securityContext|[.runAsNonRoot,.runAsUser,.runAsGroup]|map(tostring)|join(\",\")")" true,65532,65532
eq "fsGroup 65532"                                     "$(q "$D" "$CPP|.securityContext.fsGroup")" 65532
eq "seccomp RuntimeDefault"                            "$(q "$D" "$CPP|.securityContext.seccompProfile.type")" RuntimeDefault
eq "read-only root filesystem"                         "$(q "$D" "$CPC|.securityContext.readOnlyRootFilesystem")" true
eq "no privilege escalation"                           "$(q "$D" "$CPC|.securityContext.allowPrivilegeEscalation")" false
eq "drops ALL capabilities"                            "$(q "$D" "$CPC|.securityContext.capabilities.drop|join(\",\")")" ALL
eq "the catalog and the policy are mounted as files"   "$(q "$D" "$CPC|.volumeMounts|map(.name+\":\"+.mountPath+\":\"+(.readOnly|tostring))|sort|join(\" \")")" "catalog:/etc/control-plane/catalog:true policy:/etc/control-plane/policy:true"
eq "the file paths are passed by env"                  "$(q "$D" "$CPC|.env|map(select(.name|test(\"FILE\"))|.name+\"=\"+.value)|sort|join(\" \")")" "CONTROL_PLANE_CATALOG_FILE=/etc/control-plane/catalog/catalog.json CONTROL_PLANE_POLICY_FILE=/etc/control-plane/policy/policy.json"
eq "CONTROL_PLANE_MIN_INTERVAL is not set by default"  "$(q "$D" "$CPC|[.env[]|select(.name==\"CONTROL_PLANE_MIN_INTERVAL\")]|length")" 0
eq "controlPlane.minInterval sets CONTROL_PLANE_MIN_INTERVAL" "$(q "$(docs "${CP9[@]}" --set controlPlane.minInterval=2s)" "$CPC|.env[]|select(.name==\"CONTROL_PLANE_MIN_INTERVAL\")|.value")" 2s
eq "CONTROL_PLANE_MIN_RECREATE_INTERVAL is not set by default" "$(q "$D" "$CPC|[.env[]|select(.name==\"CONTROL_PLANE_MIN_RECREATE_INTERVAL\")]|length")" 0
eq "controlPlane.minRecreateInterval sets CONTROL_PLANE_MIN_RECREATE_INTERVAL" "$(q "$(docs "${CP9[@]}" --set controlPlane.minRecreateInterval=5m)" "$CPC|.env[]|select(.name==\"CONTROL_PLANE_MIN_RECREATE_INTERVAL\")|.value")" 5m
eq "no env var has a secretKeyRef or a literal secret" "$(q "$D" "$CPC|[.env[]|select(has(\"valueFrom\"))]|length")" 0
eq "volumes are the two ConfigMaps"                    "$(q "$D" "$CPP|.volumes|map(.name+\":\"+.configMap.name)|sort|join(\" \")")" "catalog:openagentix-control-plane-catalog policy:openagentix-control-plane-policy"
eq "probes on the health port"                         "$(q "$D" "$CPC|[.livenessProbe.httpGet.path,.readinessProbe.httpGet.path,.livenessProbe.httpGet.port]|map(tostring)|join(\" \")")" "/healthz /readyz health"
eq "health container port"                             "$(q "$D" "$CPC|.ports|map(.name+\":\"+(.containerPort|tostring))|join(\",\")")" health:8081
eq "resources are set"                                 "$(q "$D" "$CPC|.resources|has(\"limits\") and has(\"requests\")")" true
eq "the pod does not get a Service"                    "$(count "$D" '.kind=="Service" and .metadata.name=="openagentix-control-plane"')" 0
eq "checksum of the catalog is set"                    "$(q "$D" "$CPD|.spec.template.metadata.annotations[\"checksum/catalog\"]|test(\"^[0-9a-f]{64}\$\")")" true
eq "checksum of the policy is set"                     "$(q "$D" "$CPD|.spec.template.metadata.annotations[\"checksum/policy\"]|test(\"^[0-9a-f]{64}\$\")")" true
eq "no source hash annotation without install.sh"      "$(q "$D" "$CPD|.spec.template.metadata.annotations|has(\"openagentix.io/source-hash\")")" false
DH=$(docs "${CP9[@]}" --set-string controlPlane.sourceHash=0123456789abcdef)
eq "sourceHash becomes the pod annotation"             "$(q "$DH" "$CPD|.spec.template.metadata.annotations[\"openagentix.io/source-hash\"]")" 0123456789abcdef
DP=$(docs "${CP9[@]}" --set controlPlane.policy.maxAgents=3)
eq "maxAgents change reaches the policy"               "$(jq -r '.maxAgents' <<<"$(q "$DP" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]')")" 3
eq "a policy change rolls the pod (checksum differs)"  "$([ "$(q "$DP" "$CPD|.spec.template.metadata.annotations[\"checksum/policy\"]")" != "$(q "$D" "$CPD|.spec.template.metadata.annotations[\"checksum/policy\"]")" ] && echo differs || echo same)" differs
eq "a policy change leaves the catalog checksum alone" "$([ "$(q "$DP" "$CPD|.spec.template.metadata.annotations[\"checksum/catalog\"]")" = "$(q "$D" "$CPD|.spec.template.metadata.annotations[\"checksum/catalog\"]")" ] && echo same || echo differs)" same
DC=$(docs "${CP9[@]}" --set kagent.workerPool=other-pool)
eq "a catalog change rolls the pod (checksum differs)" "$([ "$(q "$DC" "$CPD|.spec.template.metadata.annotations[\"checksum/catalog\"]")" != "$(q "$D" "$CPD|.spec.template.metadata.annotations[\"checksum/catalog\"]")" ] && echo differs || echo same)" differs
DN=$(docs "${CP9[@]}" --set controlPlane.namespace=cp-ns)
eq "controlPlane.namespace moves the controller"       "$(q "$DN" "$CPD|.metadata.namespace")" cp-ns
eq "...and the guard names the ServiceAccount there"   "$(q "$DN" "[$GP|.spec.matchConditions[0].expression|contains(\"system:serviceaccount:cp-ns:openagentix-control-plane\")]|unique|join(\",\")")" true

echo "# control plane: the NetworkPolicy"
NP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-control-plane")'
eq "NetworkPolicy selects the controller pod"          "$(q "$D" "$NP|.spec.podSelector.matchLabels.app")" control-plane
eq "no ingress at all"                                 "$(q "$D" "$NP|[(.spec.policyTypes|sort|join(\",\")), (.spec.ingress//[]|length|tostring)]|join(\" \")")" "Egress,Ingress 0"
eq "egress: DNS first"                                 "$(q "$D" "$NP|.spec.egress[0]|[.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"],.to[0].podSelector.matchLabels[\"k8s-app\"],(.ports|map(.protocol+(.port|tostring))|sort|join(\",\"))]|join(\" \")")" "kube-system kube-dns TCP53,UDP53"
eq "egress: two rules without CIDRs"                   "$(q "$D" "$NP|.spec.egress|length")" 2
eq "egress without CIDRs: the API server ports towards any address (documented fallback)" "$(q "$D" "$NP|.spec.egress[1]|[(.to//[]|length|tostring),(.ports|map(.port|tostring)|join(\",\"))]|join(\" \")")" "0 443,6443"
DA=$(docs "${CP9[@]}" --set 'controlPlane.apiServerCIDRs={172.18.0.0/24,10.1.2.3/32}')
eq "egress with CIDRs: only those, on the API server ports" "$(q "$DA" "$NP|.spec.egress[1]|[(.to|map(.ipBlock.cidr)|join(\",\")),(.ports|map(.port|tostring)|join(\",\"))]|join(\" \")")" "172.18.0.0/24,10.1.2.3/32 443,6443"
DT=$(docs "${CP9[@]}" --set networkPolicy.enabled=false)
eq "networkPolicy.enabled=false renders no NetworkPolicy for the controller" "$(count "$DT" '.kind=="NetworkPolicy" and .metadata.name=="openagentix-control-plane"')" 0

echo "# control plane: the catalog follows the chart values"
eq "catalog: models are the gateway models"            "$(jq -c .models <<<"$CAT")" '["claude-haiku"]'
eq "catalog: gateway URL is the one agents use"        "$(jq -r .gatewayBaseUrl <<<"$CAT")" "$(q "$D" '.[]|select(.kind=="ModelConfig" and .metadata.name=="gateway-profile-demo")|.spec.openAI.baseUrl')"
eq "catalog: the harness image is the one agents use"  "$(jq -r .runtime.kagent.harnessImage <<<"$CAT")" "$(q "$D" '.[]|select(.kind=="Harness" and .metadata.name=="profile-demo-harness")|.spec.workload.image')"
eq "catalog: the profile's tools are the ones the chart validates agents against" "$(jq -c '.tools.toolhive.profiles[0].tools' <<<"$CAT")" '["knowledge_kb_search","osv_query_vulnerability","osv_get_vulnerability","execute_tool_script"]'
eq "catalog: the profile server is the RemoteMCPServer name agents use" "$(jq -r '.tools.toolhive.profiles[0].toolServer' <<<"$CAT")" "$(q "$D" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="profile-demo-template")|.spec.tools[0].mcp.server.name')"
eq "catalog: reserved names are the chart agents, the platform's names, the key Secret bases, the non-default ModelConfig suffixes and every gateway user" "$(jq -c '.reservedNames' <<<"$CAT")" '["assistant","profile-demo","kb","kb-extract","memory","claude-haiku","embed-memory"]'
eq "catalog: the gate URL (gate on)"                   "$(jq -r .gateUrl <<<"$CAT")" http://a2a-gate.openagentix-gateway.svc.cluster.local:8080
GWU=$(q "$D" '[(.[]|select(.kind=="ModelConfig")|.metadata.annotations["openagentix.io/agent"]),(.[]|select(.kind=="Deployment")|(.metadata.annotations//{})|to_entries[]|select(.key|test("^openagentix.io/gateway-user(-.+)?$"))|.value)]|map(select(.!=null and .!=""))|unique|join(",")')
eq "catalog: every gateway user id the installer registers is reserved (derived from the render)" "$(jq -r --arg u "$GWU" '($u|split(","))-.reservedNames|length' <<<"$CAT")" 0
eq "catalog: the users are agents, kb, kb-extract and memory" "$GWU" assistant,kb,kb-extract,memory,profile-demo
CPO="$(dirname "$0")/.cp-override.yaml"
cat > "$CPO" <<'YAML'
controlPlane: {enabled: true}
agents:
  - name: bar
    model: claude-haiku
    modelConfigName: gateway-baz-model
    virtualKeySecret: foo-virtual-key
    systemPrompt: hi
  - name: qux
    model: claude-haiku
    virtualKeySecret: odd-key
    systemPrompt: hi
  - name: plain
    model: claude-haiku
    modelConfigName: gateway-plain
    virtualKeySecret: plain-virtual-key
    systemPrompt: hi
YAML
RES=$(q "$(docs -f "$CPO")" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.reservedNames|join(",")')
eq "catalog: a virtualKeySecret override reserves its base name, a non-default modelConfigName its suffix, a default one nothing extra" "$RES" "bar,qux,plain,kb,kb-extract,memory,foo,odd-key,baz-model"
rm -f "$CPO"
eq "catalog: an overridden memory key Secret reserves its base too" "$(q "$(docs --set controlPlane.enabled=true --set memory.modelConfig.virtualKeySecret=mem2-virtual-key)" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.reservedNames|index("mem2")!=null')" true
DOFF=$(docs --set controlPlane.enabled=true)
CATOFF=$(q "$DOFF" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]')
eq "catalog without the other demos: no profiles, no gate, no notify; knowledge and memory follow the chart defaults" "$(jq -c '[.tools.toolhive.profiles,.gateUrl,.knowledge.available,.notify.available,.memory.available]' <<<"$CATOFF")" '[[],"",true,false,true]'
eq "catalog: the chart's default agent has memory, so the memory stack is present" "$(jq -r .memory.available <<<"$CATOFF")" true
CPM="$(dirname "$0")/.cp-nomem.yaml"
yq -y '{agents: (.agents|map(del(.memory)))}' "$CHART/values.yaml" > "$CPM"
DNM=$(docs --set controlPlane.enabled=true -f "$CPM")
eq "catalog: memory.available follows the chart's own memory switch" "$(q "$DNM" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.memory.available')" false

echo "# control plane: adapter-owned catalog sections and the policy additions (ADR 0012)"
eq "catalog: nothing of kagent or the tool servers is at the top level (adapter-owned sections only)" "$(jq -c '[has("harnessImage"),has("workerPool"),has("snapshotLocation"),has("harnessEnv"),has("toolServer"),has("profiles"),(.memory|has("modelConfig"))]|any' <<<"$CAT")" false
eq "catalog: runtime.kagent holds the harness image, worker pool, snapshot location, env and the memory model config" "$(jq -c '.runtime.kagent|[(.harnessImage|startswith("ghcr.io")),.workerPool,.snapshotLocation,.harnessEnv,.memoryModelConfig]' <<<"$CAT")" '[true,"kagent-default","s3://ate-snapshots/kagent/",[],"gateway-embed-memory"]'
eq "catalog: the memory model config is the one the chart agents use" "$(jq -r '.runtime.kagent.memoryModelConfig' <<<"$CAT")" "$(q "$D" '.[]|select(.kind=="Harness" and .metadata.name=="assistant-harness")|.spec.kagent.memory.modelConfigRef.name')"
eq "catalog: tools.toolhive names the code-mode tool and holds the profiles" "$(jq -c '.tools.toolhive|[.codeModeTool,(.profiles|length)]' <<<"$CAT")" '["execute_tool_script",1]'
eq "catalog: the adapter sections are the only ones (runtime.kagent, tools.toolhive)" "$(jq -c '[(.runtime|keys),(.tools|keys)]' <<<"$CAT")" '[["kagent"],["toolhive"]]'
eq "catalog: harnessEnv follows observability baggage into runtime.kagent" "$(jq -c '.runtime.kagent.harnessEnv|map(.name)' <<<"$(q "$(docs "${CP8[@]}" -f "$CPV" --set observability.baggage=true)" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]')")" '["OTEL_PROPAGATORS"]'
eq "policy: suspendAll is off by default"              "$(jq -c .suspendAll <<<"$POL")" false
eq "policy: inClusterDestinations is empty by default" "$(jq -c .egress.inClusterDestinations <<<"$POL")" '[]'
DS=$(docs "${CP9[@]}" --set controlPlane.policy.suspendAll=true --set 'controlPlane.policy.egress.inClusterDestinations={registry.ci.svc:5000,db.data.svc.cluster.local:5432}')
POLS=$(q "$DS" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]')
eq "policy: suspendAll and inClusterDestinations reach the policy file" "$(jq -c '[.suspendAll,.egress.inClusterDestinations]' <<<"$POLS")" '[true,["registry.ci.svc:5000","db.data.svc.cluster.local:5432"]]'
eq "a suspendAll change rolls the pod (checksum differs)" "$([ "$(q "$DS" "$CPD|.spec.template.metadata.annotations[\"checksum/policy\"]")" != "$(q "$D" "$CPD|.spec.template.metadata.annotations[\"checksum/policy\"]")" ] && echo differs || echo same)" differs

echo "# control plane: the controller accepts the rendered files"
if command -v go >/dev/null 2>&1 && [ -d "$CPSVC/cmd/control-plane" ]; then
  CPW="$(mktemp -d)"
  if (cd "$CPSVC" && go build -o "$CPW/control-plane" ./cmd/control-plane) 2>/dev/null; then
    printf '%s' "$CAT" > "$CPW/catalog.json"; printf '%s' "$POL" > "$CPW/policy.json"
    # No --validate flag exists: the controller loads both files first and only then asks for the in-cluster client, so an error that
    # names neither file (it asks for the ServiceAccount) means both were accepted. Unknown fields are refused by the loader.
    E=$(CONTROL_PLANE_CATALOG_FILE="$CPW/catalog.json" CONTROL_PLANE_POLICY_FILE="$CPW/policy.json" "$CPW/control-plane" 2>&1 | head -3)
    eq "the controller loads the rendered catalog and policy (stops only at the in-cluster client)" "$(printf '%s' "$E" | command grep -cE 'catalog:|policy:|invalid configuration')" 0
    eq "...and it really got that far (the in-cluster client was asked for)" "$(printf '%s' "$E" | command grep -ciE 'service|token|KUBERNETES|in-cluster|in cluster')" 1
    jq '.surprise=1' <<<"$CAT" > "$CPW/bad.json"
    E=$(CONTROL_PLANE_CATALOG_FILE="$CPW/bad.json" CONTROL_PLANE_POLICY_FILE="$CPW/policy.json" "$CPW/control-plane" 2>&1 | head -3)
    eq "negative control: an unknown field in the catalog is refused by the controller" "$(printf '%s' "$E" | command grep -c 'catalog:')" 1
  else
    echo "  skip the controller could not be built here"
  fi
  rm -rf "$CPW"
else
  echo "  skip no go toolchain: the check that the controller accepts the rendered files did not run"
fi

echo "# control plane: render-time failures"
cpfail() { local d=$1; shift; eq "$d" "$([ -n "$(render_err "${CP9[@]}" "$@")" ] && echo failed || echo rendered)" failed; }
cpfail "enabled must be a boolean"                     --set controlPlane.enabled=yes
cpfail "kagent.enabled=false fails the render"         --set kagent.enabled=false
cpfail "gateway.enabled=false fails the render"        --set gateway.enabled=false
cpfail "an allowed model that the gateway does not have fails" --set 'controlPlane.policy.allowedModels={ghost}'
cpfail "an allowed profile that does not exist fails"  --set 'controlPlane.policy.allowedProfiles={ghost}'
cpfail "an allowed skill that does not exist fails"    --set 'controlPlane.policy.allowedSkills={ghost}'
cpfail "allowNotify with notify.enabled=false fails"   --set controlPlane.policy.allowNotify=true --set notify.enabled=false
cpfail "negative maxAgents fails"                      --set controlPlane.policy.maxAgents=-1
cpfail "memory allowed with maxTtlDays 0 fails"        --set controlPlane.policy.memory.allowed=true --set controlPlane.policy.memory.maxTtlDays=0
cpfail "memory allowed while the expiry job is off (requireExpiry) fails" --set controlPlane.policy.memory.allowed=true --set memory.expiry.enabled=false
cpfail "an egress origin that is not an origin fails"  --set 'controlPlane.policy.egress.allowedOrigins={http://x/y}'
cpfail "an egress origin inside the tools namespace fails" --set 'controlPlane.policy.egress.allowedOrigins={https://vmcp.mcp-tools.svc}'
cpfail "an allow list that is not a list fails"        --set controlPlane.policy.allowedModels=claude-haiku
cpfail "a bad API server CIDR fails"                   --set 'controlPlane.apiServerCIDRs={not-a-cidr}'
cpfail "suspendAll must be a boolean"                  --set controlPlane.policy.suspendAll=yes
cpfail "inClusterDestinations without a port fails"    --set 'controlPlane.policy.egress.inClusterDestinations={registry.ci.svc}'
cpfail "inClusterDestinations with a scheme fails"     --set 'controlPlane.policy.egress.inClusterDestinations={http://registry.ci.svc:5000}'
cpfail "inClusterDestinations with a wildcard fails"   --set 'controlPlane.policy.egress.inClusterDestinations={*.ci.svc:5000}'
cpfail "inClusterDestinations that is an IP fails"     --set 'controlPlane.policy.egress.inClusterDestinations={10.0.0.4:5000}'
cpfail "inClusterDestinations without a namespace fails" --set 'controlPlane.policy.egress.inClusterDestinations={registry:5000}'
cpfail "inClusterDestinations in the tools namespace fails" --set 'controlPlane.policy.egress.inClusterDestinations={vmcp.mcp-tools.svc:4483}'
cpfail "inClusterDestinations in the agents namespace fails" --set 'controlPlane.policy.egress.inClusterDestinations={x.kagent.svc:80}'
cpfail "inClusterDestinations in the gateway namespace fails" --set 'controlPlane.policy.egress.inClusterDestinations={model-gateway.agentgateway-system.svc:80}'
cpfail "inClusterDestinations in kube-system fails"    --set 'controlPlane.policy.egress.inClusterDestinations={coredns.kube-system.svc:53}'
cpfail "inClusterDestinations naming the Kubernetes API fails" --set 'controlPlane.policy.egress.inClusterDestinations={kubernetes.default.svc:443}'
cpfail "inClusterDestinations naming the Kubernetes API (short) fails" --set 'controlPlane.policy.egress.inClusterDestinations={kubernetes.default:443}'
cpfail "minRecreateInterval that is not a duration fails" --set controlPlane.minRecreateInterval=often
cpfail "inClusterDestinations that is not a list fails" --set controlPlane.policy.egress.inClusterDestinations=registry.ci.svc:5000
cpfail "memoryDefaultTtlDays below 1 fails"            --set controlPlane.memoryDefaultTtlDays=0
cpfail "maxDefinitions below 1 fails"                  --set controlPlane.maxDefinitions=0
cpfail "maxDefinitions that is not a number fails"     --set controlPlane.maxDefinitions=many
cpfail "minInterval that is not a duration fails"      --set controlPlane.minInterval=fast
cpfail "minInterval without a unit fails"              --set controlPlane.minInterval=5
eq "memory allowed without the memory stack fails, and the message says why" "$(render_err --set controlPlane.enabled=true -f "$CPM" --set controlPlane.policy.memory.allowed=true | command grep -c 'memory stack')" 1
rm -f "$CPM"
eq "wildcard entries are accepted in every allow list" "$([ -z "$(render_err "${CP9[@]}" --set 'controlPlane.policy.allowedModels={*}' --set 'controlPlane.policy.allowedProfiles={*}' --set 'controlPlane.policy.allowedSkills={*}')" ] && echo rendered || echo failed)" rendered
eq "the closed chart defaults render (nothing allowed)" "$([ -z "$(render_err --set controlPlane.enabled=true)" ] && echo rendered || echo failed)" rendered
eq "...and render empty allow lists"                   "$(q "$(docs --set controlPlane.enabled=true)" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]|fromjson|[.allowedModels,.allowedProfiles,.allowedSkills,.egress.allowedOrigins]|tojson')" '[[],[],[],[]]'


echo "# console (ADR 0007, slice 3): off by default"
CNV="$REPO/components/console/demo-values.yaml"
CN10=("${CP9[@]}" -f "$CNV")
D=$(docs)
eq "no console objects by default"                     "$(count "$D" '.metadata.name|tostring|test("console")')" 0
CNX="$(dirname "$0")/.console-variant.yaml"
cat > "$CNX" <<'YAML'
console:
  enabled: false
  namespace: elsewhere
  sourceHash: abc
  viewer: true
  allowedHosts: [console.example.org]
  apiServerCIDRs: [10.0.0.0/24]
YAML
CH0=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
eq "console.enabled=false (other console values set) is byte-identical to the default render" "$(helm template openagentix "$CHART" -n openagentix-system -f "$CNX" 2>&1 | shasum -a 256)" "$CH0"
eq "console=null is byte-identical to the default render" "$(helm template openagentix "$CHART" -n openagentix-system -f /dev/stdin <<<'console: null' 2>&1 | shasum -a 256)" "$CH0"
eq "the eight demo files render byte-identically with the console switch off and console values set" "$(helm template openagentix "$CHART" -n openagentix-system "${CP8[@]}" -f "$CNX" 2>&1 | shasum -a 256)" "$(helm template openagentix "$CHART" -n openagentix-system "${CP8[@]}" 2>&1 | shasum -a 256)"
eq "the nine demo files (control plane on) render byte-identically with the console switch off and console values set" "$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" -f "$CNX" 2>&1 | shasum -a 256)" "$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" 2>&1 | shasum -a 256)"
rm -f "$CNX"
eq "the ten demo files render"                         "$([ -z "$(render_err "${CN10[@]}")" ] && echo rendered || echo failed)" rendered

echo "# console: the objects"
D=$(docs "${CN10[@]}" --set observability.enabled=false)
CNNS=openagentix-system
CND='.[]|select(.kind=="Deployment" and .metadata.name=="openagentix-console")'
CNP="$CND|.spec.template.spec"
CNC="$CNP|.containers[0]"
eq "one Deployment"                                    "$(count "$D" '.kind=="Deployment" and .metadata.name=="openagentix-console"')" 1
eq "one ServiceAccount, in the console namespace"      "$(count "$D" '.kind=="ServiceAccount" and .metadata.name=="openagentix-console" and .metadata.namespace=="'$CNNS'"')" 1
eq "one Role and one RoleBinding, in the agents namespace" "$(count "$D" '(.kind=="Role" or .kind=="RoleBinding") and .metadata.name=="openagentix-console" and .metadata.namespace=="kagent"')" 2
eq "the RoleBinding binds the Role to the console ServiceAccount only" "$(q "$D" '.[]|select(.kind=="RoleBinding" and .metadata.name=="openagentix-console")|[.roleRef.kind,.roleRef.name,(.subjects|map(.kind+":"+.namespace+"/"+.name)|join(","))]|join(" ")')" "Role openagentix-console ServiceAccount:$CNNS/openagentix-console"
eq "one Service"                                       "$(count "$D" '.kind=="Service" and .metadata.name=="openagentix-console"')" 1
eq "one NetworkPolicy"                                 "$(count "$D" '.kind=="NetworkPolicy" and .metadata.name=="openagentix-console"')" 1
eq "no Ingress, ClusterRole, ClusterRoleBinding or route for the console" "$(count "$D" '(.kind=="Ingress" or .kind=="ClusterRole" or .kind=="ClusterRoleBinding" or .kind=="HTTPRoute") and (.metadata.name|tostring|test("console"))')" 0
eq "the console adds no Secret object (the installer creates the token)" "$(count "$D" '.kind=="Secret"')" 0

echo "# console: the Role"
CNR='.[]|select(.kind=="Role" and .metadata.name=="openagentix-console")'
CNRULES='[{"apiGroups":["api.kagent.dev"],"resources":["agents","agenttemplates","harnesses","modelconfigs"],"verbs":["list"]},{"apiGroups":["openagentix.io"],"resources":["agentdefinitions"],"verbs":["create","delete","get","list","update"]}]'
cnrules() { jq -S -c "$CNR|.rules|map(.verbs|=sort)|sort_by(.apiGroups[0])" <<<"$1"; }
eq "operator mode: exact rules (definitions: get list create update delete; kagent kinds: list)" "$(cnrules "$D")" "$(jq -S -c . <<<"$CNRULES")"
DV=$(docs "${CN10[@]}" --set console.viewer=true)
eq "viewer mode: exact rules (definitions: get list only)" "$(cnrules "$DV")" "$(jq -S -c '.[1].verbs=["get","list"]' <<<"$CNRULES")"
BADRULE='[.rules[]|(.resources+.verbs+.apiGroups)[]|select(.=="secrets" or .=="*" or .=="agentdefinitions/status" or .=="patch" or .=="watch" or .=="deletecollection")]|length'
eq "no Secrets, wildcard, status, patch, watch or deletecollection (operator)" "$(q "$D" "$CNR|$BADRULE")" 0
eq "no Secrets, wildcard, status, patch, watch or deletecollection (viewer)"   "$(q "$DV" "$CNR|$BADRULE")" 0
eq "the Role names no resource other than the five the console reads or writes" "$(q "$D" "[$CNR|.rules[]|.apiGroups[]+\"/\"+.resources[]]|sort|join(\" \")")" "api.kagent.dev/agents api.kagent.dev/agenttemplates api.kagent.dev/harnesses api.kagent.dev/modelconfigs openagentix.io/agentdefinitions"
eq "the console has no permission on Secrets anywhere (every Role and ClusterRole bound to its ServiceAccount)" "$(q "$D" '[.[]|select(.kind=="RoleBinding" or .kind=="ClusterRoleBinding")|select(any(.subjects[]?;.name=="openagentix-console"))|.roleRef.name] as $names|[.[]|select((.kind=="Role" or .kind=="ClusterRole") and (.metadata.name|IN($names[])))|.rules[]|select(.resources|index("secrets") or index("*"))]|length')" 0
eq "no binding of any kind other than its own (and the two read-only ones below) names the console ServiceAccount" "$(count "$D" '(.kind=="RoleBinding" or .kind=="ClusterRoleBinding") and any(.subjects[]?;.name=="openagentix-console") and .metadata.name!="openagentix-console" and .metadata.name!="openagentix-console-schedules" and .metadata.name!="openagentix-console-gate"')" 0
eq "viewer: the Role has no write verb at all"         "$(q "$DV" "[$CNR|.rules[].verbs[]|select(.==\"create\" or .==\"update\" or .==\"delete\")]|length")" 0
eq "viewer: CONSOLE_VIEWER=1"                          "$(q "$DV" "$CNC|.env[]|select(.name==\"CONSOLE_VIEWER\")|.value")" 1
eq "operator: CONSOLE_VIEWER is not set"               "$(q "$D" "$CNC|[.env[]|select(.name==\"CONSOLE_VIEWER\")]|length")" 0

echo "# console: the admission guard does not touch the console"
CGP='.[]|select(.kind=="ValidatingAdmissionPolicy" and (.metadata.name|startswith("openagentix-control-plane-guard-")))'
CGB='.[]|select(.kind=="ValidatingAdmissionPolicyBinding" and (.metadata.name|startswith("openagentix-control-plane-guard-")))'
eq "no policy or binding of the guard names the console ServiceAccount" "$(q "$D" "[($CGP),($CGB)|tostring|select(contains(\"openagentix-console\"))]|length")" 0
eq "every guard policy matches the controller's username only (matchConditions) and no other" "$(q "$D" "[$CGP|.spec.matchConditions|map(.expression)|join(\" \")|(contains(\"system:serviceaccount:$CNNS:openagentix-control-plane\") and (contains(\"openagentix-console\")|not))]|unique|join(\",\")")" true
eq "no guard binding narrows or widens by a ServiceAccount (every binding is the policy's own)" "$(q "$D" "[$CGB|select(.metadata.name!=.spec.policyName)]|length")" 0
eq "the console is not the controller's ServiceAccount" "$(q "$D" "[$CGP|.spec.matchConditions[]|.expression|contains(\"system:serviceaccount:$CNNS:openagentix-console\")]|any")" false
eq "the guard is rendered identically with the console on and off" "$(q "$D" "[($CGP),($CGB)]|tostring"|shasum -a 256)" "$(q "$(docs "${CP9[@]}")" "[($CGP),($CGB)]|tostring"|shasum -a 256)"

echo "# console: the Deployment"
eq "Deployment in the console namespace"               "$(q "$D" "$CND|.metadata.namespace")" "$CNNS"
eq "one replica"                                       "$(q "$D" "$CND|.spec.replicas")" 1
eq "image"                                             "$(q "$D" "$CNC|.image")" openagentix/console:dev
eq "ServiceAccount"                                    "$(q "$D" "$CNP|.serviceAccountName")" openagentix-console
eq "runs as non-root 65532"                            "$(q "$D" "$CNP|.securityContext|[.runAsNonRoot,.runAsUser,.runAsGroup]|map(tostring)|join(\",\")")" true,65532,65532
eq "fsGroup 65532"                                     "$(q "$D" "$CNP|.securityContext.fsGroup")" 65532
eq "seccomp RuntimeDefault"                            "$(q "$D" "$CNP|.securityContext.seccompProfile.type")" RuntimeDefault
eq "read-only root filesystem"                         "$(q "$D" "$CNC|.securityContext.readOnlyRootFilesystem")" true
eq "no privilege escalation"                           "$(q "$D" "$CNC|.securityContext.allowPrivilegeEscalation")" false
eq "drops ALL capabilities"                            "$(q "$D" "$CNC|.securityContext.capabilities.drop|join(\",\")")" ALL
eq "container port 8080 named http"                    "$(q "$D" "$CNC|.ports|map(.name+\":\"+(.containerPort|tostring))|join(\",\")")" http:8080
eq "the liveness probe is /healthz on http and sends Host: localhost" "$(q "$D" "$CNC|.livenessProbe.httpGet|[.path,.port,(.httpHeaders|map(.name+\"=\"+.value)|join(\",\"))]|map(tostring)|join(\" \")")" "/healthz http Host=localhost"
eq "the readiness probe is /healthz on http and sends Host: localhost" "$(q "$D" "$CNC|.readinessProbe.httpGet|[.path,.port,(.httpHeaders|map(.name+\"=\"+.value)|join(\",\"))]|map(tostring)|join(\" \")")" "/healthz http Host=localhost"
eq "resources are set"                                 "$(q "$D" "$CNC|.resources|has(\"limits\") and has(\"requests\")")" true
eq "the three files are mounted read-only"             "$(q "$D" "$CNC|.volumeMounts|map(.name+\":\"+.mountPath+\":\"+(.readOnly|tostring))|sort|join(\" \")")" "catalog:/etc/console/catalog:true policy:/etc/console/policy:true token:/etc/console/token:true"
eq "volumes: the two control plane ConfigMaps and the token Secret" "$(q "$D" "$CNP|.volumes|map(.name+\":\"+(.configMap.name//.secret.secretName))|sort|join(\" \")")" "catalog:openagentix-control-plane-catalog policy:openagentix-control-plane-policy token:console-token"
eq "the token volume mounts the one key, nothing else" "$(q "$D" "$CNP|.volumes[]|select(.name==\"token\")|.secret.items|map(.key+\"->\"+.path)|join(\",\")")" "token->token"
eq "env: the three files, the namespaces (agents, schedules, gate)"               "$(q "$D" "$CNC|.env|map(.name+\"=\"+.value)|sort|join(\" \")")" "CONSOLE_CATALOG_FILE=/etc/console/catalog/catalog.json CONSOLE_GATE_NAMESPACE=openagentix-gateway CONSOLE_NAMESPACE=kagent CONSOLE_POLICY_FILE=/etc/console/policy/policy.json CONSOLE_SCHEDULES_NAMESPACE=openagentix-schedules CONSOLE_TOKEN_FILE=/etc/console/token/token"
eq "no env var carries a secret (no valueFrom, no literal token)" "$(q "$D" "$CNC|[.env[]|select(has(\"valueFrom\"))]|length")" 0
eq "the token Secret is optional: false (the pod waits for the installer's Secret)" "$(q "$D" "$CNP|.volumes[]|select(.name==\"token\")|(.secret.optional//false)|tostring")" false
CNA="$CND|.spec.template.metadata.annotations"
eq "checksum of the catalog is the control plane's"    "$(q "$D" "$CNA[\"checksum/catalog\"]")" "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="openagentix-control-plane")|.spec.template.metadata.annotations["checksum/catalog"]')"
eq "checksum of the policy is the control plane's"     "$(q "$D" "$CNA[\"checksum/policy\"]")" "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="openagentix-control-plane")|.spec.template.metadata.annotations["checksum/policy"]')"
eq "checksum of the token Secret reference is set"     "$(q "$D" "$CNA[\"checksum/token-secret\"]|test(\"^[0-9a-f]{64}\$\")")" true
eq "no source hash annotation without install.sh"      "$(q "$D" "$CNA|has(\"openagentix.io/source-hash\")")" false
eq "sourceHash becomes the pod annotation"             "$(q "$(docs "${CN10[@]}" --set-string console.sourceHash=0123456789abcdef)" "$CNA[\"openagentix.io/source-hash\"]")" 0123456789abcdef
eq "a policy change rolls the console too"             "$([ "$(q "$(docs "${CN10[@]}" --set controlPlane.policy.maxAgents=3)" "$CNA[\"checksum/policy\"]")" != "$(q "$D" "$CNA[\"checksum/policy\"]")" ] && echo differs || echo same)" differs
eq "a changed token Secret name rolls the console"     "$([ "$(q "$(docs "${CN10[@]}" --set console.tokenSecret.name=other)" "$CNA[\"checksum/token-secret\"]")" != "$(q "$D" "$CNA[\"checksum/token-secret\"]")" ] && echo differs || echo same)" differs
DTS=$(docs "${CN10[@]}" --set console.tokenSecret.name=other --set console.tokenSecret.key=pw)
eq "tokenSecret name and key reach the volume and the env" "$(q "$DTS" "$CNP|[(.volumes[]|select(.name==\"token\")|.secret.secretName+\":\"+.secret.items[0].key),(.containers[0].env[]|select(.name==\"CONSOLE_TOKEN_FILE\")|.value)]|join(\" \")")" "other:pw /etc/console/token/pw"
eq "CONSOLE_ALLOWED_HOSTS is not set by default"       "$(q "$D" "$CNC|[.env[]|select(.name==\"CONSOLE_ALLOWED_HOSTS\")]|length")" 0
eq "allowedHosts is passed comma-separated"            "$(q "$(docs "${CN10[@]}" --set 'console.allowedHosts={console.example.org,other.example.org:8443}')" "$CNC|.env[]|select(.name==\"CONSOLE_ALLOWED_HOSTS\")|.value")" "console.example.org,other.example.org:8443"
eq "the probes still send Host: localhost with allowedHosts set" "$(q "$(docs "${CN10[@]}" --set 'console.allowedHosts={console.example.org}')" "$CNC|[.livenessProbe,.readinessProbe]|map(.httpGet.httpHeaders[0].value)|unique|join(\",\")")" localhost
eq "CONSOLE_NAMESPACE follows kagent.namespace"        "$(q "$(docs --set controlPlane.enabled=true --set console.enabled=true --set kagent.namespace=ag2)" "$CNC|.env[]|select(.name==\"CONSOLE_NAMESPACE\")|.value")" ag2
eq "the Role follows kagent.namespace"                 "$(q "$(docs --set controlPlane.enabled=true --set console.enabled=true --set kagent.namespace=ag2)" "$CNR|.metadata.namespace")" ag2
eq "the Service is a ClusterIP on 8080 selecting the pod" "$(q "$D" '.[]|select(.kind=="Service" and .metadata.name=="openagentix-console")|[.spec.type,(.spec.ports|map(.name+":"+(.port|tostring)+"->"+(.targetPort|tostring))|join(",")),.spec.selector.app]|join(" ")')" "ClusterIP http:8080->http console"
eq "the pod carries the label the Service and the policy select" "$(q "$D" "$CND|.spec.template.metadata.labels.app")" console

echo "# console: the two read-only pages (schedules, access rules): extra Roles only when there is something to read"
CNSR='.[]|select(.kind=="Role" and .metadata.name=="openagentix-console-schedules")'
CNGR='.[]|select(.kind=="Role" and .metadata.name=="openagentix-console-gate")'
eq "schedules: one Role in the schedules namespace"    "$(count "$D" '.kind=="Role" and .metadata.name=="openagentix-console-schedules" and .metadata.namespace=="openagentix-schedules"')" 1
eq "schedules: the Role may only list CronJobs"        "$(q "$D" "$CNSR|.rules|tojson")" '[{"apiGroups":["batch"],"resources":["cronjobs"],"verbs":["list"]}]'
eq "schedules: the RoleBinding binds that Role to the console ServiceAccount only" "$(q "$D" '.[]|select(.kind=="RoleBinding" and .metadata.name=="openagentix-console-schedules")|[.metadata.namespace,.roleRef.kind,.roleRef.name,(.subjects|map(.kind+":"+.namespace+"/"+.name)|join(","))]|join(" ")')" "openagentix-schedules Role openagentix-console-schedules ServiceAccount:$CNNS/openagentix-console"
eq "schedules: CONSOLE_SCHEDULES_NAMESPACE is set"     "$(q "$D" "$CNC|.env[]|select(.name==\"CONSOLE_SCHEDULES_NAMESPACE\")|.value")" openagentix-schedules
eq "gate: one Role in the gate namespace"              "$(count "$D" '.kind=="Role" and .metadata.name=="openagentix-console-gate" and .metadata.namespace=="openagentix-gateway"')" 1
eq "gate: the Role may only get the one ConfigMap a2a-gate-rules" "$(q "$D" "$CNGR|.rules|tojson")" '[{"apiGroups":[""],"resources":["configmaps"],"resourceNames":["a2a-gate-rules"],"verbs":["get"]}]'
eq "gate: the RoleBinding binds that Role to the console ServiceAccount only" "$(q "$D" '.[]|select(.kind=="RoleBinding" and .metadata.name=="openagentix-console-gate")|[.metadata.namespace,.roleRef.kind,.roleRef.name,(.subjects|map(.kind+":"+.namespace+"/"+.name)|join(","))]|join(" ")')" "openagentix-gateway Role openagentix-console-gate ServiceAccount:$CNNS/openagentix-console"
eq "gate: CONSOLE_GATE_NAMESPACE is set"               "$(q "$D" "$CNC|.env[]|select(.name==\"CONSOLE_GATE_NAMESPACE\")|.value")" openagentix-gateway
eq "the two extra Roles name no Secret, wildcard, watch or write verb" "$(q "$D" "[($CNSR),($CNGR)|.rules[]|(.resources+.verbs+.apiGroups)[]|select(.==\"secrets\" or .==\"*\" or .==\"watch\" or .==\"create\" or .==\"update\" or .==\"patch\" or .==\"delete\")]|length")" 0
eq "viewer mode gives the extra Roles the same read verbs" "$(q "$DV" "[($CNSR),($CNGR)|.rules[].verbs[]]|sort|join(\",\")")" "get,list"
DNS=$(docs "${CN10[@]}" --set observability.enabled=false --set schedules=null)
eq "no schedules: no schedules Role, binding or env"   "$(count "$DNS" '.metadata.name=="openagentix-console-schedules"')$(q "$DNS" "$CNC|[.env[]|select(.name==\"CONSOLE_SCHEDULES_NAMESPACE\")]|length")" 00
DNG=$(docs --set controlPlane.enabled=true --set console.enabled=true)
eq "no schedules and no gate (chart defaults): no extra Role, binding or env"            "$(count "$DNG" '.metadata.name=="openagentix-console-gate"')$(q "$DNG" "$CNC|[.env[]|select(.name==\"CONSOLE_GATE_NAMESPACE\")]|length")" 00
eq "the gate namespace follows governance.a2a.namespace" "$(q "$(docs "${CN10[@]}" --set observability.enabled=false --set governance.a2a.namespace=gate2)" "$CNC|.env[]|select(.name==\"CONSOLE_GATE_NAMESPACE\")|.value")" gate2
eq "the schedules namespace follows scheduling.namespace" "$(q "$(docs "${CN10[@]}" --set observability.enabled=false --set scheduling.namespace=sched2)" "$CNC|.env[]|select(.name==\"CONSOLE_SCHEDULES_NAMESPACE\")|.value")" sched2

echo "# console: the NetworkPolicy"
CNN='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")'
eq "NetworkPolicy selects the console pod, in its namespace" "$(q "$D" "$CNN|.spec.podSelector.matchLabels.app+\" \"+.metadata.namespace")" "console $CNNS"
eq "no ingress at all"                                 "$(q "$D" "$CNN|[(.spec.policyTypes|sort|join(\",\")), (.spec.ingress//[]|length|tostring)]|join(\" \")")" "Egress,Ingress 0"
eq "egress: DNS first"                                 "$(q "$D" "$CNN|.spec.egress[0]|[.to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"],.to[0].podSelector.matchLabels[\"k8s-app\"],(.ports|map(.protocol+(.port|tostring))|sort|join(\",\"))]|join(\" \")")" "kube-system kube-dns TCP53,UDP53"
eq "egress: two rules without CIDRs"                   "$(q "$D" "$CNN|.spec.egress|length")" 2
eq "egress without CIDRs: the API server ports towards any address (documented fallback)" "$(q "$D" "$CNN|.spec.egress[1]|[(.to//[]|length|tostring),(.ports|map(.port|tostring)|join(\",\"))]|join(\" \")")" "0 443,6443"
DCA=$(docs "${CN10[@]}" --set observability.enabled=false --set 'console.apiServerCIDRs={172.18.0.0/24,10.1.2.3/32}')
eq "egress with CIDRs: only those, on the API server ports" "$(q "$DCA" "$CNN|.spec.egress[1]|[(.to|map(.ipBlock.cidr)|join(\",\")),(.ports|map(.port|tostring)|join(\",\"))]|join(\" \")")" "172.18.0.0/24,10.1.2.3/32 443,6443"
eq "networkPolicy.enabled=false renders no NetworkPolicy for the console" "$(count "$(docs "${CN10[@]}" --set networkPolicy.enabled=false)" '.kind=="NetworkPolicy" and .metadata.name=="openagentix-console"')" 0

echo "# console: render failures"
cnfail() { local d=$1; shift; eq "$d" "$([ -n "$(render_err "${CN10[@]}" "$@")" ] && echo failed || echo rendered)" failed; }
eq "console without the control plane fails, and says why" "$(render_err --set console.enabled=true | command grep -c 'console.enabled needs controlPlane.enabled')" 1
eq "a namespace that differs from the control plane's fails, and says why" "$(render_err "${CN10[@]}" --set console.namespace=elsewhere | command grep -c 'same namespace as the control plane')" 1
eq "the same namespace spelled out renders"            "$([ -z "$(render_err "${CN10[@]}" --set console.namespace=openagentix-system)" ] && echo rendered || echo failed)" rendered
eq "a moved control plane needs the console there too" "$(render_err "${CN10[@]}" --set controlPlane.namespace=cp-ns | command grep -c 'same namespace as the control plane')" 1
eq "...and the console follows when it is told to"     "$([ -z "$(render_err "${CN10[@]}" --set controlPlane.namespace=cp-ns --set console.namespace=cp-ns)" ] && echo rendered || echo failed)" rendered
cnfail "enabled must be a boolean"                     --set console.enabled=yes
cnfail "viewer must be a boolean"                      --set console.viewer=yes
cnfail "allowedHosts must be a list"                   --set console.allowedHosts=console.example.org
cnfail "an allowed host with a scheme fails"           --set 'console.allowedHosts={https://console.example.org}'
cnfail "an allowed host with a path fails"             --set 'console.allowedHosts={console.example.org/x}'
cnfail "an allowed host with a comma fails"            --set 'console.allowedHosts={a.example.org\,b.example.org}'
cnfail "a bad API server CIDR fails"                   --set 'console.apiServerCIDRs={not-a-cidr}'
cnfail "apiServerCIDRs must be a list"                 --set console.apiServerCIDRs=10.0.0.0/24
cnfail "a bad API server port fails"                   --set 'console.apiServerPorts={0}'
cnfail "an empty token Secret name fails"              --set console.tokenSecret.name=
cnfail "an empty token Secret key fails"               --set console.tokenSecret.key=
cnfail "a token Secret key with a slash fails"         --set console.tokenSecret.key=a/b
echo "# stub model (ADR 0014): off by default, nothing renders"
D=$(docs)
eq "no stub-model Deployment by default"               "$(count "$D" '.metadata.name=="stub-model"')" 0
D=$(docs --set gateway.stubModel.enabled=true)
SM='.metadata.name=="stub-model"'
eq "stub-model: Deployment, Service, NetworkPolicy"    "$(count "$D" "$SM")" 3
eq "stub-model lives in the gateway namespace"         "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="stub-model")|.metadata.namespace')" agentgateway-system
eq "stub-model image"                                  "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="stub-model")|.spec.template.spec.containers[0].image')" openagentix/stub-model:dev
eq "stub-model runs non-root, read-only, no caps"      "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="stub-model")|.spec.template.spec|[.securityContext.runAsNonRoot,.containers[0].securityContext.readOnlyRootFilesystem,.containers[0].securityContext.allowPrivilegeEscalation,.containers[0].securityContext.capabilities.drop[0],.automountServiceAccountToken]|join(",")')" "true,true,false,ALL,false"
eq "stub-model has limits and a probe"                 "$(q "$D" '.[]|select(.kind=="Deployment" and .metadata.name=="stub-model")|.spec.template.spec.containers[0]|(.resources.limits.memory!=null) and (.readinessProbe.httpGet.path=="/healthz")')" true
eq "stub-model: only the gateway proxy may call it"    "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="stub-model")|[.spec.policyTypes[0],(.spec.ingress|length),.spec.ingress[0].from[0].podSelector.matchLabels["gateway.networking.k8s.io/gateway-name"],.spec.ingress[0].from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]]|join(",")')" "Ingress,1,model-gateway,agentgateway-system"
eq "stub-model: egress closed"                         "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="stub-model")|.spec.policyTypes|index("Egress")!=null')" true
eq "stub-model NetworkPolicy has no egress rule"       "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="stub-model")|(.spec.egress//[])|length')" 0
eq "stub-model sourceHash annotates the pod"           "$(q "$(docs --set gateway.stubModel.enabled=true --set-string gateway.stubModel.sourceHash=abc)" '.[]|select(.kind=="Deployment" and .metadata.name=="stub-model")|.spec.template.metadata.annotations["openagentix.io/source-hash"]')" abc
eq "stub-model off when the gateway is off"            "$(count "$(docs --set gateway.stubModel.enabled=true --set gateway.enabled=false)" "$SM")" 0

echo "# quick start profile (components/quickstart/values.yaml)"
QS="$CHART/../../components/quickstart/values.yaml"
D=$(docs -f "$QS")
eq "profile renders"                                   "$(q "$D" 'length>0')" true
eq "profile: stub-model rendered"                      "$(count "$D" "$SM and .kind==\"Deployment\"")" 1
eq "profile: no Telegram bridge"                       "$(count "$D" '.kind=="Deployment" and .metadata.name=="telegram-bridge"')" 0
eq "profile: no chart agents"                          "$(count "$D" '.kind=="Agent"')" 0
eq "profile: no knowledge base"                        "$(count "$D" '.metadata.name=="kb" or .metadata.name=="kb-embeddings"')" 0
eq "profile: no notify, no memory embeddings"          "$(count "$D" '.metadata.name=="notify" or .metadata.name=="memory-embeddings"')" 0
eq "profile: no schedules, no Kourier objects"         "$(count "$D" '.kind=="CronJob" or (.apiVersion|startswith("agentkourier"))')" 0
eq "profile: control plane, console and gate on"       "$(count "$D" '.kind=="Deployment" and (.metadata.name|IN("openagentix-control-plane","openagentix-console","a2a-gate"))')" 3
eq "profile: one tool server and one profile vMCP"     "$(count "$D" '.kind=="MCPServer"')/$(count "$D" '.kind=="VirtualMCPServer" and (.metadata.annotations["openagentix.io/tool-profile"]//"")!=""')" 1/1
eq "profile: bundled observability on, content capture off"  "$(count "$D" '.kind=="Deployment" and (.metadata.name|IN("jaeger","victoria-metrics"))')/$(q "$D" '[.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-observability")|.data.captureContent]|first')" 2/false
eq "profile: the model alias goes through the gateway" "$(q "$D" '.[]|select(.kind=="AgentgatewayModel")|.metadata.name')" quickstart-model
eq "profile: the gate has the ask rule"                "$(q "$D" '.[]|select(.kind=="ConfigMap" and (.data["rules.json"]//"")!="")|.data["rules.json"]|fromjson|.callers[]|select(.name=="quickstart-ask")|.agents[0]')" kagent/quickstart
eq "profile: the policy admits the alias and profile"  "$(q "$D" '[.[]|select(.kind=="ConfigMap")|.data["policy.json"]//empty|fromjson|(.allowedModels[0],.allowedProfiles[0])]|join(",")')" quickstart-model,lookup

echo "# minimal profile (components/quickstart/minimal-values.yaml, on top of the quick start profile; issue #29)"
MIN="$CHART/../../components/quickstart/minimal-values.yaml"
D=$(docs -f "$QS" -f "$MIN")
eq "minimal renders"                                   "$(q "$D" 'length>0')" true
eq "minimal: no console"                               "$(count "$D" '.metadata.name|test("^openagentix-console")')" 0
eq "minimal: no bundled observability"                 "$(count "$D" '.kind=="Deployment" and (.metadata.name|IN("jaeger","victoria-metrics"))')/$(count "$D" '.metadata.name=="openagentix-observability"')" 0/0
eq "minimal: the governed path stays (gate, control plane, stub)" "$(count "$D" '.kind=="Deployment" and (.metadata.name|IN("openagentix-control-plane","a2a-gate","stub-model"))')" 3
eq "minimal: one tool server and one profile vMCP"     "$(count "$D" '.kind=="MCPServer"')/$(count "$D" '.kind=="VirtualMCPServer" and (.metadata.annotations["openagentix.io/tool-profile"]//"")!=""')" 1/1
eq "minimal: the model alias and the policy are the same" "$(q "$D" '[.[]|select(.kind=="AgentgatewayModel")|.metadata.name]|join(",")')/$(q "$D" '[.[]|select(.kind=="ConfigMap")|.data["policy.json"]//empty|fromjson|(.allowedModels[0],.allowedProfiles[0])]|join(",")')" quickstart-model/quickstart-model,lookup
eq "minimal: the gate keeps the ask rule"              "$(q "$D" '.[]|select(.kind=="ConfigMap" and (.data["rules.json"]//"")!="")|.data["rules.json"]|fromjson|.callers[]|select(.name=="quickstart-ask")|.agents[0]')" kagent/quickstart
eq "minimal: no Telegram bridge, no knowledge, no notify" "$(count "$D" '.kind=="Deployment" and (.metadata.name|IN("telegram-bridge","kb","notify"))')" 0
eq "the quick start profile alone still has the console and the observability" "$(count "$(docs -f "$QS")" '.kind=="Deployment" and (.metadata.name|IN("openagentix-console","jaeger","victoria-metrics"))')" 3

echo "# secrets hygiene"
D=$(docs --set bridge.token=SENTINEL-TOKEN-123 --set gateway.apiKey=SENTINEL-TOKEN-123)
eq "chart renders no Secret objects"                   "$(count "$D" '.kind=="Secret"')" 0
eq "no stringData/data anywhere"                       "$(q "$D" '[.[]|select(has("data") or has("stringData"))]|length')" 0
eq "stray secret-looking values are never rendered"    "$(q "$D" 'tostring|contains("SENTINEL-TOKEN-123")')" false
eq "no Secret-valued env var has a literal value"      "$(q "$D" '[.[]|select(.kind=="Deployment")|.spec.template.spec.containers[].env[]|select((.name|test("TOKEN|KEY|CHAT_IDS")) and has("value"))]|length')" 0

echo "# console: metrics (the bundled metrics store is reachable by the console only)"
D=$(docs "${CN10[@]}")
VMURL="http://victoria-metrics.openagentix-observability.svc:8428"
eq "console on + observability on: CONSOLE_METRICS_URL is the bundled store" "$(q "$D" "$CNC|.env[]|select(.name==\"CONSOLE_METRICS_URL\")|.value")" "$VMURL"
eq "the console NetworkPolicy gets one egress rule to the store's pod and port 8428 only" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|[.spec.egress[]|select(.to[0].podSelector.matchLabels.app=="victoria-metrics")|[.to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"],(.ports|map(.port)|join(","))]]|tostring')" '[["openagentix-observability","8428"]]'
eq "the store's ingress admits the console pods only, on 8428 only" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="victoria-metrics-ingress")|[.spec.ingress[]|[.from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"],.from[0].podSelector.matchLabels.app,(.ports|map(.port)|join(","))]]|tostring')" '[["openagentix-system","console","8428"]]'
D=$(docs "${CP9[@]}")
eq "observability on, console off: the store's ingress still admits nobody" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="victoria-metrics-ingress")|(.spec.ingress // [])|length')" 0
D=$(docs "${CN10[@]}" --set observability.enabled=false)
eq "console on, observability off: no CONSOLE_METRICS_URL" "$(q "$D" "$CNC|[.env[]|select(.name==\"CONSOLE_METRICS_URL\")]|length")" 0
eq "console on, observability off: no egress to a metrics store" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|[.spec.egress[]|select(.to[0].podSelector.matchLabels.app=="victoria-metrics")]|length')" 0
D=$(docs "${CN10[@]}" --set console.metrics.url=https://metrics.example.org:8428)
eq "console.metrics.url overrides the bundled store" "$(q "$D" "$CNC|.env[]|select(.name==\"CONSOLE_METRICS_URL\")|.value")" "https://metrics.example.org:8428"
eq "an override opens no egress to the bundled store" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|[.spec.egress[]|select(.to[0].podSelector.matchLabels.app=="victoria-metrics")]|length')" 0
eq "a console.metrics.url with a query or credentials is refused" "$(render_err "${CN10[@]}" --set 'console.metrics.url=http://u:p@x:1/?q=1' | /usr/bin/grep -c 'console.metrics.url')" 1

echo "# console: traces (Jaeger's query port is reachable by the console only)"
D=$(docs "${CN10[@]}")
JGURL="http://jaeger.openagentix-observability.svc:16686"
eq "console on + observability on: CONSOLE_TRACES_URL is the bundled Jaeger" "$(q "$D" "$CNC|.env[]|select(.name==\"CONSOLE_TRACES_URL\")|.value")" "$JGURL"
eq "the console NetworkPolicy gets one egress rule to Jaeger's pod and port 16686 only" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|[.spec.egress[]|select(.to[0].podSelector.matchLabels.app=="jaeger")|[.to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"],(.ports|map(.port)|join(","))]]|tostring')" '[["openagentix-observability","16686"]]'
eq "Jaeger's ingress keeps its OTLP ports and adds the console on 16686 only" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="jaeger-ingress")|[.spec.ingress[]|(.ports|map(.port)|join(","))]|tostring')" '["4317,4318","16686"]'
eq "the console rule on Jaeger admits the console pods of the console namespace" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="jaeger-ingress")|.spec.ingress[]|select(.ports[0].port==16686)|[.from[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"],.from[0].podSelector.matchLabels.app]|join(" ")')" "openagentix-system console"
D=$(docs "${CP9[@]}")
eq "console off: Jaeger's ingress is OTLP only" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="jaeger-ingress")|[.spec.ingress[]|(.ports|map(.port)|join(","))]|tostring')" '["4317,4318"]'
D=$(docs "${CN10[@]}" --set observability.enabled=false)
eq "observability off: no CONSOLE_TRACES_URL" "$(q "$D" "$CNC|[.env[]|select(.name==\"CONSOLE_TRACES_URL\")]|length")" 0
D=$(docs "${CN10[@]}" --set console.traces.url=https://jaeger.example.org:16686)
eq "console.traces.url overrides the bundled Jaeger and opens no egress for it" "$(q "$D" "$CNC|.env[]|select(.name==\"CONSOLE_TRACES_URL\")|.value") $(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|[.spec.egress[]|select(.to[0].podSelector.matchLabels.app=="jaeger")]|length')" "https://jaeger.example.org:16686 0"
eq "a console.traces.url with credentials is refused" "$(render_err "${CN10[@]}" --set 'console.traces.url=http://u:p@x:1/' | /usr/bin/grep -c 'console.traces.url')" 1

echo "# bring your own agent (container runtime, ADR 0015)"
CA=(--set controlPlane.containerAgents.enabled=true --set 'controlPlane.policy.allowedRuntimes={builtin,container}' --set 'controlPlane.policy.runtimes.container.images={registry.local/oa/}')
H0=$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" 2>&1 | shasum -a 256)
H1=$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" --set controlPlane.containerAgents.enabled=false --set 'controlPlane.policy.allowedRuntimes={builtin,container}' 2>&1 | shasum -a 256)
eq "containerAgents off (even with the policy keys set) renders byte-identical to the defaults" "$H1" "$H0"
D=$(docs "${CP9[@]}")
eq "off: no workload namespace, no workload guard, no route list" "$(count "$D" '(.kind=="Namespace" and .metadata.name=="openagentix-workloads") or (.metadata.name // "" | startswith("openagentix-control-plane-guard-workload")) or .metadata.name=="a2a-gate-routes"')" 0
eq "off: the policy file has no allowedRuntimes" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]|fromjson|has("allowedRuntimes")')" false
eq "off: the catalog names no container adapter" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.adapters|has("runtimes")')" false
D=$(docs "${CP9[@]}" "${CA[@]}")
eq "on: the workload namespace enforces Pod Security restricted" "$(q "$D" '.[]|select(.kind=="Namespace" and .metadata.name=="openagentix-workloads")|.metadata.labels["pod-security.kubernetes.io/enforce"]')" restricted
eq "on: the workload namespace is deny-by-default (both directions, every pod)" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="default-deny" and .metadata.namespace=="openagentix-workloads")|[.spec.podSelector,(.spec.policyTypes|sort|join(",")),(.spec|has("ingress")),(.spec|has("egress"))]|tostring')" '[{},"Egress,Ingress",false,false]'
WR='.[]|select(.kind=="Role" and .metadata.namespace=="openagentix-workloads")|.rules[]'
eq "on: the controller's Role in the workload namespace can never read a Secret" "$(q "$D" "[$WR|select(.resources|index(\"secrets\"))|.verbs[]]|sort|join(\",\")")" "create,delete"
eq "on: that Role has no wildcard and no pods or exec" "$(q "$D" "[$WR|(.resources+.verbs+.apiGroups)[]|select(.==\"*\" or .==\"pods\" or .==\"pods/exec\")]|length")" 0
eq "on: the route list ConfigMap exists in the gate namespace, empty" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-routes")|.metadata.namespace+" "+.data["routes.json"]')" 'openagentix-gateway {"container":[]}'
eq "on: the controller may only get and patch that ConfigMap there" "$(q "$D" '.[]|select(.kind=="Role" and .metadata.name=="openagentix-control-plane-routes")|.rules|tostring')" '[{"apiGroups":[""],"resources":["configmaps"],"resourceNames":["a2a-gate-routes"],"verbs":["get","patch"]}]'
GATE='.[]|select(.kind=="Deployment" and .metadata.name=="a2a-gate")|.spec.template.spec'
eq "on: the gate mounts the route list as a directory and reads it" "$(q "$D" "$GATE|[(.containers[0].env[]|select(.name==\"A2A_GATE_ROUTES_FILE\")|.value),(.containers[0].volumeMounts[]|select(.name==\"routes\")|.mountPath),(.containers[0].volumeMounts[]|select(.name==\"routes\")|has(\"subPath\"))]|tostring")" '["/etc/a2a-gate/routes/routes.json","/etc/a2a-gate/routes",false]'
eq "on: the gate gets the workload namespace and its public URL" "$(q "$D" "$GATE|[.containers[0].env[]|select(.name==\"A2A_GATE_WORKLOAD_NAMESPACE\" or .name==\"A2A_GATE_PUBLIC_URL\")|.value]|tostring")" '["openagentix-workloads","http://a2a-gate.openagentix-gateway.svc.cluster.local:8080"]'
eq "on: the gate's container agent limits default to 300 s and 32" "$(q "$D" "$GATE|[.containers[0].env[]|select(.name==\"A2A_GATE_WORKLOAD_HEADER_TIMEOUT_SECONDS\" or .name==\"A2A_GATE_WORKLOAD_MAX_INFLIGHT\")|.value]|tostring")" '["300","32"]'
eq "on: the gate's container agent limits are values" "$(q "$(docs "${CP9[@]}" "${CA[@]}" --set controlPlane.containerAgents.responseTimeoutSeconds=900 --set controlPlane.containerAgents.maxInFlightPerAgent=8)" "$GATE|[.containers[0].env[]|select(.name==\"A2A_GATE_WORKLOAD_HEADER_TIMEOUT_SECONDS\" or .name==\"A2A_GATE_WORKLOAD_MAX_INFLIGHT\")|.value]|tostring")" '["900","8"]'
eq "off: the gate gets no container agent limits" "$(q "$(docs "${CP9[@]}")" "$GATE|[.containers[0].env[]|select(.name|startswith(\"A2A_GATE_WORKLOAD\"))]|length")" 0
eq "on: the policy lists container, and no image is allowed until the operator names a prefix" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]|fromjson|[.allowedRuntimes,.runtimes.container.images]|tostring')" '[["builtin","container"],["registry.local/oa/"]]'
D2=$(docs "${CP9[@]}" --set controlPlane.containerAgents.enabled=true)
eq "on: allowedRuntimes stays [builtin] unless the operator opens it" "$(q "$D2" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-policy")|.data["policy.json"]|fromjson|.allowedRuntimes|tostring')" '["builtin"]'
GP='.[]|select(.kind=="ValidatingAdmissionPolicy" and (.metadata.name|startswith("openagentix-control-plane-guard-workload")))'
eq "on: six workload guard policies (four kinds, Secrets, the route list), all fail-closed and Deny-bound" "$(q "$D" "[$GP|select(.spec.failurePolicy==\"Fail\")]|length") $(q "$D" '[.[]|select(.kind=="ValidatingAdmissionPolicyBinding" and (.metadata.name|startswith("openagentix-control-plane-guard-workload")) and .spec.validationActions==["Deny"])]|length')" "6 6"
eq "on: every workload policy looks at the controller only" "$(q "$D" "[$GP|select(.spec.matchConditions[0].expression|contains(\"system:serviceaccount:openagentix-system:openagentix-control-plane\"))]|length")" 6
eq "on: the guard of the agents namespace steps aside for the workload objects only" "$(q "$D" '.[]|select(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="openagentix-control-plane-guard-secrets")|.spec.matchConditions|map(.name)|join(",")')" "only-the-controller,not-the-workload-namespace"
eq "on: the container catalog section names the workload namespace and the gate" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.runtime.container|[.namespace,.gateNamespace,.gatePodSelector.app]|join(" ")')" "openagentix-workloads openagentix-gateway a2a-gate"
eq "containerAgents needs the A2A gate" "$(render_err "${CP9[@]}" --set governance.a2a.enabled=false --set controlPlane.containerAgents.enabled=true | /usr/bin/grep -c 'containerAgents.enabled needs governance.a2a.enabled')" 1
eq "the workload namespace may not be a platform namespace" "$(render_err "${CP9[@]}" "${CA[@]}" --set controlPlane.containerAgents.namespace=kagent | /usr/bin/grep -c 'foreign code needs a namespace of its own')" 1
eq "an image prefix without a trailing slash is refused" "$(render_err "${CP9[@]}" --set controlPlane.containerAgents.enabled=true --set 'controlPlane.policy.runtimes.container.images={registry.local/oa}' | /usr/bin/grep -c 'trailing slash')" 1
eq "an unknown runtime type is refused" "$(render_err "${CP9[@]}" --set controlPlane.containerAgents.enabled=true --set 'controlPlane.policy.allowedRuntimes={vm}' | /usr/bin/grep -c 'not a runtime type')" 1

echo "# tools for container agents (ADR 0019): a workload tool server per opened profile"
HCA=$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" "${CA[@]}" 2>&1 | shasum -a 256)
eq "toolProfiles empty (the default) renders byte-identical to before, token settings changed or not" "$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" "${CA[@]}" --set controlPlane.containerAgents.serviceAccountTokens.issuer=https://x.example 2>&1 | shasum -a 256)" "$HCA"
eq "toolProfiles listed but containerAgents off renders byte-identical to the defaults" "$(helm template openagentix "$CHART" -n openagentix-system "${CP9[@]}" --set 'controlPlane.containerAgents.toolProfiles={lookup}' 2>&1 | shasum -a 256)" "$H0"
D=$(docs "${CP9[@]}" "${CA[@]}")
eq "off (empty list): no workload tool server, no Kubernetes token config, no workload entry in the catalog" "$(count "$D" '(.kind=="VirtualMCPServer" and (.metadata.name|endswith("-workload"))) or (.kind=="MCPOIDCConfig" and .metadata.name=="openagentix-workload-sa")') $(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|[.tools.toolhive.profiles[]|select(has("workload"))]|length')" "0 0"
TP=(--set 'controlPlane.containerAgents.toolProfiles={lookup}')
D=$(docs "${CP9[@]}" "${CA[@]}" "${TP[@]}")
WV='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup-workload")'
PV='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")'
eq "on: one workload tool server for the opened profile, in the tools namespace" "$(count "$D" '.kind=="VirtualMCPServer" and (.metadata.name|endswith("-workload"))') $(q "$D" "$WV|.metadata.namespace")" "1 mcp-tools"
eq "on: it filters exactly like the profile's own server (tools, visibility, code mode)" "$(q "$D" "$WV|.spec.config|del(.audit)|tojson")" "$(q "$D" "$PV|.spec.config|del(.audit)|tojson")"
eq "on: it takes Kubernetes ServiceAccount tokens with the profile's own workload audience" "$(q "$D" "$WV|.spec.incomingAuth|[.type,.oidcConfigRef.name,.oidcConfigRef.audience]|join(\" \")")" "oidc openagentix-workload-sa openagentix-vmcp-lookup-workload"
eq "on: its policy admits only subjects of the workload namespace" "$(q "$D" "$WV|.spec.incomingAuth.authzConfig.inline.policies|tojson")" '["permit(principal, action, resource) when { context.claim_sub like \"system:serviceaccount:openagentix-workloads:*\" };"]'
OC='.[]|select(.kind=="MCPOIDCConfig" and .metadata.name=="openagentix-workload-sa")'
eq "on: the token config is type kubernetesServiceAccount with the issuer and key URL set explicitly" "$(q "$D" "$OC|[.metadata.namespace,.spec.type,.spec.kubernetesServiceAccount.issuer,.spec.kubernetesServiceAccount.jwksUrl,(.spec.kubernetesServiceAccount.useClusterAuth|tostring)]|join(\" \")")" "mcp-tools kubernetesServiceAccount https://kubernetes.default.svc.cluster.local https://kubernetes.default.svc/openid/v1/jwks true"
eq "on: the issuer is a value" "$(q "$(docs "${CP9[@]}" "${CA[@]}" "${TP[@]}" --set controlPlane.containerAgents.serviceAccountTokens.issuer=https://oidc.example.org)" "$OC|.spec.kubernetesServiceAccount.issuer")" "https://oidc.example.org"
eq "on: the profile's own server is unchanged by opening it" "$(q "$D" "$PV|tojson")" "$(q "$(docs "${CP9[@]}" "${CA[@]}")" "$PV|tojson")"
WN='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-ingress-lookup-workload")'
eq "on: the workload server admits only pods of the workload namespace labelled for its profile, on its port" "$(q "$D" "$WN|[.metadata.namespace,(.spec.podSelector.matchLabels|tojson),(.spec.ingress|tojson)]|join(\" \")")" 'mcp-tools {"app":"virtualmcpserver","toolhive-name":"tools-lookup-workload"} [{"ports":[{"protocol":"TCP","port":4483}],"from":[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"openagentix-workloads"}},"podSelector":{"matchLabels":{"openagentix.io/tool-profile":"lookup"}}}]}]'
eq "networkPolicy off: no ingress policy for it" "$(count "$(docs "${CP9[@]}" "${CA[@]}" "${TP[@]}" --set networkPolicy.enabled=false)" '.kind=="NetworkPolicy" and .metadata.name=="openagentix-vmcp-ingress-lookup-workload"')" 0
eq "on: the catalog opens the profile with its URL, audience and server pods" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.tools.toolhive.profiles[]|select(.name=="lookup")|.workload|tojson')" '{"audience":"openagentix-vmcp-lookup-workload","namespace":"mcp-tools","podSelector":{"app":"virtualmcpserver","toolhive-name":"tools-lookup-workload"},"port":4483,"url":"http://vmcp-tools-lookup-workload.mcp-tools.svc.cluster.local:4483/mcp"}'
eq "on: the controller's Roles are unchanged (no Secret read, no new kind)" "$(q "$D" '[.[]|select(.kind=="Role" and (.metadata.name|startswith("openagentix-control-plane")))|.rules]|tojson' | shasum -a 256)" "$(q "$(docs "${CP9[@]}" "${CA[@]}")" '[.[]|select(.kind=="Role" and (.metadata.name|startswith("openagentix-control-plane")))|.rules]|tojson' | shasum -a 256)"
eq "a toolProfiles entry that is not a profile fails the render" "$(render_err "${CP9[@]}" "${CA[@]}" --set 'controlPlane.containerAgents.toolProfiles={nope}' | /usr/bin/grep -c 'controlPlane.containerAgents.toolProfiles lists "nope", which is not in mcp.profiles')" 1
eq "toolProfiles needs mcp" "$(render_err -f "$REPO/components/quickstart/values.yaml" -f "$REPO/components/quickstart/byo-values.yaml" "${TP[@]}" --set mcp.enabled=false | /usr/bin/grep -c 'controlPlane.containerAgents.toolProfiles needs mcp.enabled')" 1
eq "a workload server name that would collide with a profile's server fails the render" "$(render_err "${CP9[@]}" "${CA[@]}" "${TP[@]}" --set 'mcp.profiles[1].name=lookup-workload' --set 'mcp.profiles[1].tools.osv={query_vulnerability}' | /usr/bin/grep -c 'collides')" 1
eq "toolProfiles must be a list" "$(render_err "${CP9[@]}" "${CA[@]}" --set controlPlane.containerAgents.toolProfiles=lookup | /usr/bin/grep -c 'toolProfiles must be a list')" 1
eq "the issuer must be an https URL" "$(render_err "${CP9[@]}" "${CA[@]}" "${TP[@]}" --set controlPlane.containerAgents.serviceAccountTokens.issuer=http://x | /usr/bin/grep -c 'serviceAccountTokens.issuer')" 1
GW='.[]|select(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="openagentix-control-plane-guard-workload-deployments")|[.spec.variables[].expression, .spec.validations[].expression]|join(" ")'
eq "on: the Deployment guard knows the opened profile's URL and audience" "$(q "$D" "$GW" | /usr/bin/grep -c 'openagentix-vmcp-lookup-workload')" 1
eq "off: the Deployment guard knows no tool profile" "$(q "$(docs "${CP9[@]}" "${CA[@]}")" "$GW" | /usr/bin/grep -c 'vmcp')" 0

echo "# platform: openshift (issue #32): manifests only, not run on OpenShift"
OSALL=("${CP9[@]}" -f "$REPO/components/console/demo-values.yaml")
OS0=$(helm template openagentix "$CHART" -n openagentix-system "${OSALL[@]}" 2>&1 | shasum -a 256)
eq "platform is empty by default" "$(yq -c .platform "$CHART/values.yaml")" '""'
eq "platform=\"\" renders byte-identical to the default (all features on)" "$(helm template openagentix "$CHART" -n openagentix-system "${OSALL[@]}" --set platform= 2>&1 | shasum -a 256)" "$OS0"
eq "platform=kubernetes renders byte-identical to the default (all features on)" "$(helm template openagentix "$CHART" -n openagentix-system "${OSALL[@]}" --set platform=kubernetes 2>&1 | shasum -a 256)" "$OS0"
eq "default (all features on) still pins the ids, so the check below can see a change" "$(q "$(docs "${OSALL[@]}")" '[.. | objects | select(has("runAsUser"))] | length > 5')" true
eq "an unknown platform fails the render, and says why" "$(render_err --set platform=nomad | /usr/bin/grep -c 'platform must be')" 1
OD=$(docs "${OSALL[@]}" --set platform=openshift)
eq "openshift: the render is not empty and has the console and the control plane" "$(count "$OD" '.kind=="Deployment" and (.metadata.name=="openagentix-console" or .metadata.name=="openagentix-control-plane")')" 2
eq "openshift: no runAsUser anywhere (the SCC assigns it from the namespace range)" "$(q "$OD" '[.. | objects | select(has("runAsUser"))] | length')" 0
eq "openshift: no runAsGroup anywhere" "$(q "$OD" '[.. | objects | select(has("runAsGroup"))] | length')" 0
eq "openshift: no fsGroup anywhere" "$(q "$OD" '[.. | objects | select(has("fsGroup"))] | length')" 0
eq "openshift: no hostPath, hostNetwork, hostPID or privileged anywhere" "$(q "$OD" '[.. | objects | select(has("hostPath") or has("hostNetwork") or has("hostPID") or (.privileged? == true))] | length')" 0
PODS='.[] | select(.kind=="Deployment" or .kind=="StatefulSet") | .spec.template.spec'
eq "openshift: every pod keeps runAsNonRoot and seccomp RuntimeDefault" "$(q "$OD" "[$PODS | select(.securityContext.runAsNonRoot==true and .securityContext.seccompProfile.type==\"RuntimeDefault\")] | length") $(q "$OD" "[$PODS] | length")" "$(q "$OD" "[$PODS] | length") $(q "$OD" "[$PODS] | length")"
CTRS='.[] | select(.kind=="Deployment" or .kind=="StatefulSet") | .spec.template.spec.containers[]'
eq "openshift: every container drops ALL, forbids escalation" "$(q "$OD" "[$CTRS | select(.securityContext.allowPrivilegeEscalation==false and .securityContext.capabilities.drop==[\"ALL\"])] | length") $(q "$OD" "[$CTRS] | length")" "$(q "$OD" "[$CTRS] | length") $(q "$OD" "[$CTRS] | length")"
eq "openshift: DNS egress goes to openshift-dns on 5353 in the control plane policy" "$(q "$OD" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-control-plane")|.spec.egress[0]|[.to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"], .to[0].podSelector.matchLabels["dns.operator.openshift.io/daemonset-dns"], (.ports|map(.port|tostring)|join(","))]|join(" ")')" "openshift-dns default 5353,5353"
eq "openshift: DNS egress goes to openshift-dns on 5353 in the console policy" "$(q "$OD" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|.spec.egress[0].to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"]')" openshift-dns
eq "openshift: DNS egress goes to openshift-dns in the notify policy" "$(q "$OD" '[.[]|select(.kind=="NetworkPolicy" and .metadata.namespace=="openagentix-notify")|.spec.egress[]?|.to[]?|.namespaceSelector.matchLabels["kubernetes.io/metadata.name"]]|map(select(.=="openshift-dns" or .=="kube-system"))|unique|join(",")')" openshift-dns
eq "default: DNS egress still goes to kube-system on 53" "$(q "$(docs "${OSALL[@]}")" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|.spec.egress[0]|[.to[0].namespaceSelector.matchLabels["kubernetes.io/metadata.name"], (.ports|map(.port|tostring)|join(","))]|join(" ")')" "kube-system 53,53"
eq "openshift: no Route unless asked" "$(count "$OD" '.kind=="Route"')" 0
eq "default: no Route either" "$(count "$(docs "${OSALL[@]}")" '.kind=="Route"')" 0
eq "console.route without platform=openshift fails, and says why" "$(render_err "${OSALL[@]}" --set console.route.enabled=true --set console.route.host=c.apps.example.com | /usr/bin/grep -c 'console.route needs platform: openshift')" 1
eq "console.route without a host fails, and says why" "$(render_err "${OSALL[@]}" --set platform=openshift --set console.route.enabled=true | /usr/bin/grep -c 'console.route.host')" 1
RD=$(docs "${OSALL[@]}" --set platform=openshift --set console.route.enabled=true --set console.route.host=oa-console.apps.example.com)
RT='.[]|select(.kind=="Route")'
eq "route: one Route in the console namespace" "$(count "$RD" '.kind=="Route"') $(q "$RD" "$RT|.metadata.namespace")" "1 openagentix-system"
eq "route: apiVersion route.openshift.io/v1" "$(q "$RD" "$RT|.apiVersion")" route.openshift.io/v1
eq "route: host, target service and port" "$(q "$RD" "$RT|[.spec.host,.spec.to.kind,.spec.to.name,.spec.port.targetPort]|join(\" \")")" "oa-console.apps.example.com Service openagentix-console http"
eq "route: edge TLS, plain HTTP redirected" "$(q "$RD" "$RT|[.spec.tls.termination,.spec.tls.insecureEdgeTerminationPolicy]|join(\" \")")" "edge Redirect"
eq "route: the host is on the console's allowed host list" "$(q "$RD" '.[]|select(.kind=="Deployment" and .metadata.name=="openagentix-console")|.spec.template.spec.containers[0].env[]|select(.name=="CONSOLE_ALLOWED_HOSTS")|.value')" "oa-console.apps.example.com"
eq "route: the console policy admits the router namespaces on 8080, and only then" "$(q "$RD" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|.spec.ingress|map(.ports|=map([.protocol,.port]))|tostring')" '[{"from":[{"namespaceSelector":{"matchLabels":{"network.openshift.io/policy-group":"ingress"}}}],"ports":[["TCP",8080]]}]'
eq "no route: the console policy still admits no ingress" "$(q "$OD" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="openagentix-console")|.spec.ingress|tostring')" '[]'
eq "container agents on openshift fail the render, and say why" "$(render_err "${CP9[@]}" "${CA[@]}" --set platform=openshift | /usr/bin/grep -c 'containerAgents is not supported with platform: openshift')" 1

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
