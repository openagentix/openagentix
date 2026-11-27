#!/usr/bin/env bash
# Chart tests of ADR 0025 slice 4: cluster-read in the chart. Sourced by run.sh (it shares eq, q, count, docs, render_err, probe_check and pdb_check).
# Every check here was written before the chart code and failed first (see the pull request).
echo "# diagnostics (ADR 0025, slice 4): cluster-read, off by default"
DX="$(dirname "$0")/.diag-values.yaml"
DX2="$(dirname "$0")/.diag-values2.yaml"
trap 'rm -f "$DX" "$DX2"' EXIT
DG_TOOLS='pods_list_in_namespace, pods_get, pods_log, events_list, workloads_list, workloads_get, nodes_list, nodes_get'
cat > "$DX" <<YAML
diagnostics:
  enabled: true
  apiServerCIDRs: [172.18.0.0/24]
  cluster:
    enabled: true
    logNamespaces: [rca-demo]
    statusNamespaces: [openagentix-knowledge, kagent]
notify:
  enabled: true
mcp:
  profiles:
    - name: rca
      codeMode: false
      tools:
        cluster-read: [$DG_TOOLS]
        knowledge: [kb_search]
        delivery: [notify_send]
    - name: lookup
      codeMode: false
      tools:
        osv: [query_vulnerability]
YAML
DA=(-f "$DX")
# vf <jq filter>: the dedicated values with one edit, written to $DX2 (use -f "$DX2" after calling it)
vf() { yq -y "$1" "$DX" > "$DX2"; }
# agent_file <jq filter on .agents>: the default agents list with one edit, written to $DX2 (put -f "$DX2" BEFORE -f "$DX")
agent_file() { yq -y "{agents: (.agents|$1)}" "$CHART/values.yaml" > "$DX2"; }
D0=$(helm template openagentix "$CHART" -n openagentix-system --set notify.enabled=true 2>&1 | shasum -a 256)   # the dedicated values also turn notify on
eq "diagnostics defaults: off, empty lists, nothing allowed" "$(yq -c '.diagnostics|[.enabled,.cluster.enabled,.cluster.logNamespaces,.cluster.statusNamespaces,.allowDefinitions,.allowWith]' "$CHART/values.yaml")" '[false,false,[],[],false,{}]'
eq "diagnostics: image has no digest by default" "$(yq -r '.diagnostics.image.digest' "$CHART/values.yaml")" ""
eq "diagnostics.enabled=false (all other values set) renders byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system -f "$DX" --set diagnostics.enabled=false --set 'mcp.profiles=null' 2>&1 | shasum -a 256)" "$D0"
D00=$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)
eq "diagnostics=null renders byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set diagnostics=null 2>&1 | shasum -a 256)" "$D00"
eq "diagnostics.enabled=true with cluster.enabled=false renders byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set diagnostics.enabled=true 2>&1 | shasum -a 256)" "$D00"
eq "the server switch alone (diagnostics.enabled=false) renders byte-identical to the default" "$(helm template openagentix "$CHART" -n openagentix-system --set diagnostics.cluster.enabled=true --set 'diagnostics.cluster.logNamespaces={x}' 2>&1 | shasum -a 256)" "$D00"
DD=$(docs)
eq "default: no diagnostics object (group, entry, policy, anything in the namespace)" "$(count "$DD" '(.metadata.namespace//"")=="openagentix-diagnostics" or (.metadata.name//""|test("cluster-read|diagnostics"))')" 0

D=$(docs "${DA[@]}")
eq "on: the dedicated values render" "$([ -z "$(render_err "${DA[@]}")" ] && echo rendered || echo failed)" rendered
NS=openagentix-diagnostics
echo "# diagnostics: the server (Deployment, Service, ServiceAccount, budget)"
DEP='.[]|select(.kind=="Deployment" and .metadata.name=="cluster-read")'
POD="$DEP|.spec.template.spec"
CTR="$POD|.containers[0]"
eq "Deployment cluster-read in $NS, one replica, Recreate" "$(q "$D" "$DEP|[.metadata.namespace,(.spec.replicas|tostring),.spec.strategy.type]|join(\" \")")" "$NS 1 Recreate"
eq "its Service is on 8080 and selects the pod" "$(q "$D" '.[]|select(.kind=="Service" and .metadata.name=="cluster-read")|[.metadata.namespace,(.spec.ports[0].port|tostring),.spec.selector.app]|join(" ")')" "$NS 8080 cluster-read"
eq "its own ServiceAccount, in $NS, used by the pod" "$(q "$D" '.[]|select(.kind=="ServiceAccount" and .metadata.name=="cluster-read")|.metadata.namespace')+$(q "$D" "$POD|.serviceAccountName")" "$NS+cluster-read"
eq "the pod keeps the default projected token (it needs the API)" "$(q "$D" "$POD|(.automountServiceAccountToken|tostring)")" true
eq "image openagentix/diagnostics:dev, binary /cluster-read" "$(q "$D" "$CTR|[.image,(.command|join(\" \"))]|join(\" \")")" "openagentix/diagnostics:dev /cluster-read"
eq "the lists reach the server as flags" "$(q "$D" "$CTR|.args|map(select(startswith(\"-deny-log-namespaces=\")|not))|join(\" \")")" "-addr=:8080 -log-namespaces=rca-demo -status-namespaces=openagentix-knowledge,kagent -nodes=true -bearer-file=/var/run/secrets/openagentix/bearer/bearer"
eq "the deny list names the platform namespaces (tools, agents, gateway, knowledge, notify, release, toolhive, substrate)" "$(q "$D" "$CTR|.args[]|select(startswith(\"-deny-log-namespaces=\"))|ltrimstr(\"-deny-log-namespaces=\")|split(\",\")|map(select(IN(\"mcp-tools\",\"kagent\",\"agentgateway-system\",\"openagentix-knowledge\",\"openagentix-notify\",\"openagentix-system\",\"toolhive-system\",\"ate-system\")))|sort|join(\",\")")" "agentgateway-system,ate-system,kagent,mcp-tools,openagentix-knowledge,openagentix-notify,openagentix-system,toolhive-system"
eq "nodes=false is passed as -nodes=false" "$(q "$(docs "${DA[@]}" --set diagnostics.cluster.nodes=false)" "$CTR|.args[]|select(startswith(\"-nodes=\"))")" "-nodes=false"
eq "bearer volume: Secret cluster-read-bearer, mode 288 (0440), the one key" "$(q "$D" "$POD|.volumes[]|select(.name==\"bearer\")|[.secret.secretName,(.secret.defaultMode|tostring),(.secret.items|tojson)]|join(\" \")")" 'cluster-read-bearer 288 [{"key":"bearer","path":"bearer"}]'
eq "bearer mount: read-only at /var/run/secrets/openagentix/bearer" "$(q "$D" "$CTR|.volumeMounts[]|select(.name==\"bearer\")|[.mountPath,(.readOnly|tostring)]|join(\" \")")" "/var/run/secrets/openagentix/bearer true"
eq "no environment value of the pod comes from a Secret (the value is a file, never an env value or an argument)" "$(q "$D" "$CTR|[(.env//[])[]|select(has(\"valueFrom\"))]|length")" 0
eq "no argument holds a credential-looking value" "$(q "$D" "$CTR|[.args[]|select(test(\"(?i)token|password|bearer-value\"))]|length")" 0
eq "pod security: non-root 65532, fsGroup, RuntimeDefault seccomp" "$(q "$D" "$POD|.securityContext|[(.runAsNonRoot|tostring),(.runAsUser|tostring),(.fsGroup|tostring),.seccompProfile.type]|join(\" \")")" "true 65532 65532 RuntimeDefault"
eq "container: read-only root, no escalation, all capabilities dropped" "$(q "$D" "$CTR|.securityContext|[(.readOnlyRootFilesystem|tostring),(.allowPrivilegeEscalation|tostring),(.capabilities.drop|join(\",\"))]|join(\" \")")" "true false ALL"
eq "probes: /healthz for startup and liveness, /readyz for readiness (the rights check)" "$(q "$D" "$CTR|[.startupProbe.httpGet.path,.livenessProbe.httpGet.path,.readinessProbe.httpGet.path]|join(\" \")")" "/healthz /healthz /readyz"
eq "resources: 10m / 24Mi requests, 100m / 64Mi limits" "$(q "$D" "$CTR|.resources|[.requests.cpu,.requests.memory,.limits.cpu,.limits.memory]|join(\" \")")" "10m 24Mi 100m 64Mi"
eq "a PodDisruptionBudget selects it" "$(q "$D" '.[]|select(.kind=="PodDisruptionBudget" and .metadata.name=="cluster-read")|[.metadata.namespace,.spec.selector.matchLabels.app]|join(" ")')" "$NS cluster-read"
eq "the sourceHash is stamped on the pod template when set" "$(q "$(docs "${DA[@]}" --set-string diagnostics.sourceHash=abc123)" "$DEP|.spec.template.metadata.annotations[\"openagentix.io/source-hash\"]")" abc123
eq "image.digest renders repository:tag@digest" "$(q "$(docs "${DA[@]}" --set-string diagnostics.image.digest=sha256:$(printf 'b%.0s' $(seq 64)))" "$CTR|.image")" "openagentix/diagnostics:dev@sha256:$(printf 'b%.0s' $(seq 64))"
eq "a bad image.digest fails the render and names diagnostics.image.digest" "$(render_err "${DA[@]}" --set-string diagnostics.image.digest=nope | /usr/bin/grep -c 'diagnostics.image.digest')" 1
probe_check "diagnostics on" "${DA[@]}"
pdb_check "diagnostics on" "${DA[@]}"
eq "OpenShift: no fixed user ids" "$(q "$(docs "${DA[@]}" --set platform=openshift)" "$POD|.securityContext|has(\"runAsUser\") or has(\"fsGroup\")")" false

echo "# diagnostics: roles and bindings (three ClusterRoles, no aggregationRule)"
CRN='.[]|select(.kind=="ClusterRole" and (.metadata.name|startswith("openagentix-cluster-read")))'
eq "three ClusterRoles" "$(q "$D" "[$CRN|.metadata.name]|sort|join(\" \")")" "openagentix-cluster-read openagentix-cluster-read-logs openagentix-cluster-read-nodes"
eq "no aggregationRule" "$(q "$D" "[$CRN|has(\"aggregationRule\")]|any")" false
eq "role 1: pods and events, events.k8s.io events, four workload kinds; get and list only" "$(q "$D" ".[]|select(.kind==\"ClusterRole\" and .metadata.name==\"openagentix-cluster-read\")|.rules|tojson")" '[{"apiGroups":[""],"resources":["pods","events"],"verbs":["get","list"]},{"apiGroups":["events.k8s.io"],"resources":["events"],"verbs":["get","list"]},{"apiGroups":["apps"],"resources":["deployments","replicasets","statefulsets","daemonsets"],"verbs":["get","list"]}]'
eq "role 2: pods/log get" "$(q "$D" ".[]|select(.kind==\"ClusterRole\" and .metadata.name==\"openagentix-cluster-read-logs\")|.rules|tojson")" '[{"apiGroups":[""],"resources":["pods/log"],"verbs":["get"]}]'
eq "role 3: nodes get and list" "$(q "$D" ".[]|select(.kind==\"ClusterRole\" and .metadata.name==\"openagentix-cluster-read-nodes\")|.rules|tojson")" '[{"apiGroups":[""],"resources":["nodes"],"verbs":["get","list"]}]'
eq "no rule grants a forbidden right (secrets, configmaps, exec, attach, portforward, proxies, token, impersonate, bind, escalate, watch, any write, or *)" "$(q "$D" "[$CRN|.rules[]|(.resources+.verbs+.apiGroups)[]|select(IN(\"secrets\",\"configmaps\",\"serviceaccounts\",\"serviceaccounts/token\",\"pods/exec\",\"pods/attach\",\"pods/portforward\",\"pods/proxy\",\"services/proxy\",\"nodes/proxy\",\"nodes/stats\",\"pods/ephemeralcontainers\",\"impersonate\",\"bind\",\"escalate\",\"watch\",\"create\",\"update\",\"patch\",\"delete\",\"deletecollection\",\"*\"))]|length")" 0
eq "the chart renders no Role in the diagnostics namespace" "$(count "$D" "(.kind==\"Role\" and .metadata.namespace==\"$NS\")")" 0
RBN='.[]|select(.kind=="RoleBinding" and (.metadata.name|startswith("openagentix-cluster-read")))'
eq "role 1 is bound by a RoleBinding in every listed namespace (log and status)" "$(q "$D" "[$RBN|select(.metadata.name==\"openagentix-cluster-read\")|.metadata.namespace]|sort|join(\" \")")" "kagent openagentix-knowledge rca-demo"
eq "role 2 (logs) is bound in the log namespaces only" "$(q "$D" "[$RBN|select(.metadata.name==\"openagentix-cluster-read-logs\")|.metadata.namespace]|sort|join(\" \")")" "rca-demo"
eq "every RoleBinding names exactly the ServiceAccount and a ClusterRole of its own name" "$(q "$D" "[$RBN|select((.subjects|tojson)!=\"[{\\\"kind\\\":\\\"ServiceAccount\\\",\\\"name\\\":\\\"cluster-read\\\",\\\"namespace\\\":\\\"$NS\\\"}]\" or .roleRef.kind!=\"ClusterRole\" or .roleRef.name!=.metadata.name)]|length")" 0
CRB='.[]|select(.kind=="ClusterRoleBinding" and (.metadata.name|startswith("openagentix-cluster-read")))'
eq "one ClusterRoleBinding, for nodes" "$(q "$D" "[$CRB|.metadata.name+\"->\"+.roleRef.name]|join(\" \")")" "openagentix-cluster-read-nodes->openagentix-cluster-read-nodes"
eq "nodes=false: no nodes role and no ClusterRoleBinding" "$(count "$(docs "${DA[@]}" --set diagnostics.cluster.nodes=false)" '(.kind=="ClusterRole" or .kind=="ClusterRoleBinding") and (.metadata.name=="openagentix-cluster-read-nodes")')" 0
eq "no binding in the diagnostics namespace" "$(count "$D" ".kind==\"RoleBinding\" and .metadata.namespace==\"$NS\"")" 0
eq "no binding names db-read (the server does not exist yet)" "$(q "$D" '[.[]|select(.kind=="RoleBinding" or .kind=="ClusterRoleBinding")|.subjects[]?|select(.name=="db-read")]|length')" 0
eq "status-only namespaces get no logs binding" "$(q "$(docs "${DA[@]}" --set 'diagnostics.cluster.logNamespaces={}' --set 'diagnostics.cluster.statusNamespaces={a,kagent}')" "[$RBN|select(.metadata.name==\"openagentix-cluster-read-logs\")]|length")" 0

echo "# diagnostics: the admission policy"
AP='.[]|select(.kind=="ValidatingAdmissionPolicy" and .metadata.name=="openagentix-diagnostics-rbac")'
eq "policy openagentix-diagnostics-rbac: failurePolicy Fail" "$(q "$D" "$AP|.spec.failurePolicy")" Fail
eq "its binding denies and names it" "$(q "$D" '.[]|select(.kind=="ValidatingAdmissionPolicyBinding" and .metadata.name=="openagentix-diagnostics-rbac")|[.spec.policyName,(.spec.validationActions|join(","))]|join(" ")')" "openagentix-diagnostics-rbac Deny"
eq "it matches the four RBAC kinds on create and update, for every user (no match condition on the user)" "$(q "$D" "$AP|[(.spec.matchConstraints.resourceRules|map(.resources[])|sort|join(\",\")),(.spec.matchConstraints.resourceRules|map(.operations[])|unique|join(\",\")),((.spec.matchConditions//[])|length|tostring)]|join(\" \")")" "clusterrolebindings,clusterroles,rolebindings,roles CREATE,UPDATE 0"

echo "# diagnostics: the tool group, the entries, the profile vMCP"
eq "one extra MCPGroup, diagnostics, in the tools namespace" "$(q "$D" '[.[]|select(.kind=="MCPGroup")|.metadata.namespace+"/"+.metadata.name]|sort|join(" ")')" "mcp-tools/diagnostics mcp-tools/tools"
ENT='.[]|select(.kind=="MCPServerEntry")'
eq "entries of the group: cluster-read, and knowledge and delivery named <entryName>-diagnostics (the shared group has knowledge and delivery already)" "$(q "$D" "[$ENT|select(.spec.groupRef.name==\"diagnostics\")|.metadata.name]|sort|join(\" \")")" "cluster-read delivery-diagnostics knowledge-diagnostics"
eq "no diagnostics entry outside the group: every other entry is a shared one" "$(q "$D" "[$ENT|select(.spec.groupRef.name!=\"diagnostics\")|.metadata.name]|sort|join(\" \")")" "delivery knowledge"
eq "the shared entries have no header (as before)" "$(q "$D" "[$ENT|select(.spec.groupRef.name==\"tools\")|.spec|has(\"headerForward\")]|any")" false
eq "the cluster-read entry points at the Service" "$(q "$D" "$ENT|select(.metadata.name==\"cluster-read\")|.spec.remoteUrl")" "http://cluster-read.$NS.svc.cluster.local:8080/mcp"
eq "knowledge-diagnostics and delivery-diagnostics point at kb and notify like the shared entries" "$(q "$D" "[$ENT|select(.metadata.name==\"knowledge-diagnostics\" or .metadata.name==\"delivery-diagnostics\")|.spec.remoteUrl]|sort|join(\" \")")" "http://kb.openagentix-knowledge.svc.cluster.local:8080/mcp http://notify.openagentix-notify.svc.cluster.local:8080/mcp"
eq "the bearer value is sent with headerForward from the Secret diagnostics-bearer-cluster-read in the tools namespace" "$(q "$D" "$ENT|select(.metadata.name==\"cluster-read\")|.spec.headerForward|tojson")" '{"addHeadersFromSecret":[{"headerName":"Authorization","valueSecretRef":{"name":"diagnostics-bearer-cluster-read","key":"authorization"}}]}'
eq "only the cluster-read entry has a header" "$(q "$D" "[$ENT|select(.spec|has(\"headerForward\"))|.metadata.name]|join(\",\")")" cluster-read
eq "every entry of the group uses an unauthenticated auth config of its own name" "$(q "$D" "[$ENT|select(.spec.groupRef.name==\"diagnostics\")|.spec.externalAuthConfigRef.name]|sort|join(\" \")")" "cluster-read-noauth delivery-diagnostics-noauth knowledge-diagnostics-noauth"
eq "no MCPExternalAuthConfig has type bearerToken (ToolHive 0.67.1 drops such a backend silently)" "$(q "$D" '[.[]|select(.kind=="MCPExternalAuthConfig")|.spec.type]|unique|join(",")')" unauthenticated
eq "bearerToken appears nowhere in the render" "$(printf '%s' "$D" | /usr/bin/grep -ci 'bearerToken')" 0
eq "the chart renders no Secret object (the installer creates both bearer Secrets)" "$(count "$D" '.kind=="Secret"')" 0
RCA='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-rca")'
eq "profile rca: its vMCP is on the diagnostics group" "$(q "$D" "$RCA|.spec.groupRef.name")" diagnostics
eq "profile rca: defaultToolVisibility deny" "$(q "$D" "$RCA|.spec.config.aggregation.defaultToolVisibility")" deny
eq "profile rca: the filter names the entries of the group, the eight tools, no more" "$(q "$D" "$RCA|.spec.config.aggregation.tools|map(.workload+\":\"+(.filter|sort|join(\",\")))|join(\" \")")" "cluster-read:events_list,nodes_get,nodes_list,pods_get,pods_list_in_namespace,pods_log,workloads_get,workloads_list delivery-diagnostics:notify_send knowledge-diagnostics:kb_search"
eq "profile rca: audit request and response data are false" "$(q "$D" "$RCA|.spec.config.audit|[(.enabled|tostring),(.includeRequestData|tostring),(.includeResponseData|tostring)]|join(\" \")")" "true false false"
eq "profile rca: audit data stays false with observability on and content capture off" "$(q "$(docs "${DA[@]}" --set observability.enabled=true --set observability.bundled.enabled=true)" "$RCA|.spec.config.audit|[(.includeRequestData|tostring),(.includeResponseData|tostring)]|join(\" \")")" "false false"
eq "profile rca: no code mode" "$(q "$D" "$RCA|.spec.config|has(\"codeMode\")")" false
eq "profile rca: its own audience, oidc" "$(q "$D" "$RCA|.spec.incomingAuth|[.type,.oidcConfigRef.audience]|join(\" \")")" "oidc openagentix-vmcp-rca"
eq "every vMCP of the group has audit data off" "$(q "$D" '[.[]|select(.kind=="VirtualMCPServer" and .spec.groupRef.name=="diagnostics")|.spec.config.audit|select(.includeRequestData!=false or .includeResponseData!=false)]|length')" 0
eq "no vMCP outside the group names the group, an entry of it or a diagnostics tool (apart from the shared vMCP's forbid policies)" "$(q "$D" '[.[]|select(.kind=="VirtualMCPServer" and .spec.groupRef.name!="diagnostics")|del(.spec.incomingAuth.authzConfig)|tojson|select(test("diagnostics|cluster-read"))]|length')" 0
eq "the shared-group profile lookup is untouched" "$(q "$D" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-lookup")|[.spec.groupRef.name,(.spec.config.aggregation.tools|tojson)]|join(" ")')" 'tools [{"workload":"osv","filter":["query_vulnerability"]}]'
DCP=$(docs "${DA[@]}" --set controlPlane.enabled=true --set diagnostics.allowDefinitions=true)
eq "the catalog's rca profile lists the tools as the vMCP serves them (entry names of the group)" "$(q "$DCP" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.tools.toolhive.profiles[]|select(.name=="rca")|.tools|sort|join(",")')" "cluster-read_events_list,cluster-read_nodes_get,cluster-read_nodes_list,cluster-read_pods_get,cluster-read_pods_list_in_namespace,cluster-read_pods_log,cluster-read_workloads_get,cluster-read_workloads_list,delivery-diagnostics_notify_send,knowledge-diagnostics_kb_search"
echo "# diagnostics: the shared vMCP lists none (own group, and a Cedar forbid in front of the permit)"
SH='.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools")'
eq "shared vMCP: still on the shared group" "$(q "$D" "$SH|.spec.groupRef.name")" tools
eq "shared vMCP: the first eight policies are forbids on cluster-read_ tools" "$(q "$D" "$SH|.spec.incomingAuth.authzConfig.inline.policies|.[0:8]|map(select(test(\"^forbid\\\\(principal, action == Action::\\\"call_tool\\\", resource == Tool::\\\"cluster-read_[a-z_]+\\\"\\\\);\$\")))|length")" 8
eq "shared vMCP: the forbids name exactly the eight tools" "$(q "$D" "$SH|.spec.incomingAuth.authzConfig.inline.policies|.[0:8]|map(capture(\"cluster-read_(?<t>[a-z_]+)\").t)|sort|join(\",\")")" "events_list,nodes_get,nodes_list,pods_get,pods_list_in_namespace,pods_log,workloads_get,workloads_list"
eq "shared vMCP: the permit-all policy follows, and is the only other policy" "$(q "$D" "$SH|.spec.incomingAuth.authzConfig.inline.policies|.[8:]|tojson")" '["permit(principal, action, resource);"]'
eq "shared vMCP: with toolAccess the forbids are still in front of the permits" "$(q "$(docs "${DA[@]}" --set 'mcp.virtual.incomingAuth.toolAccess[0].atespace=kagent' --set 'mcp.virtual.incomingAuth.toolAccess[0].tools={fetch_fetch}')" "$SH|.spec.incomingAuth.authzConfig.inline.policies|[(.[0:8]|map(startswith(\"forbid\"))|all|tostring),(.[8]|startswith(\"permit\")|tostring)]|join(\" \")")" "true true"
eq "shared vMCP: no tool filter was added (its group does not hold the backend)" "$(q "$D" "$SH|.spec.config.aggregation|has(\"tools\")")" false
eq "off: the shared vMCP has no forbid" "$(q "$DD" "$SH|.spec.incomingAuth.authzConfig.inline.policies|map(select(startswith(\"forbid\")))|length")" 0
eq "no object but the cluster-read Deployment and entry names a bearer Secret" "$(q "$D" '[.[]|select(tojson|test("diagnostics-bearer|cluster-read-bearer"))|.kind+"/"+.metadata.name]|sort|join(" ")')" "Deployment/cluster-read MCPServerEntry/cluster-read"
eq "the RemoteMCPServer of the profile exists, the shared one is unchanged" "$(q "$D" '[.[]|select(.kind=="RemoteMCPServer")|.metadata.name]|sort|join(" ")')" "toolhive-vmcp toolhive-vmcp-lookup toolhive-vmcp-rca"

echo "# diagnostics: network"
NP='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="cluster-read-ingress")'
eq "server ingress: port 8080 from the vMCP pods of the group's profiles only (not the shared vMCP)" "$(q "$D" "$NP|[.metadata.namespace,(.spec.policyTypes|join(\",\")),(.spec.ingress|length|tostring),(.spec.ingress[0].ports|tojson),([.spec.ingress[0].from[]|.namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"]+\"/\"+.podSelector.matchLabels[\"toolhive-name\"]]|join(\",\"))]|join(\" \")")" "$NS Ingress 1 [{\"protocol\":\"TCP\",\"port\":8080}] mcp-tools/tools-rca"
eq "server ingress never admits the shared vMCP or a shared-group profile" "$(q "$D" "$NP|[.spec.ingress[].from[].podSelector.matchLabels[\"toolhive-name\"]]|map(select(.==\"tools\" or .==\"tools-lookup\"))|length")" 0
EG='.[]|select(.kind=="NetworkPolicy" and .metadata.name=="cluster-read-egress")'
DC=(--set 'diagnostics.apiServerCIDRs={172.18.0.0/24}')
eq "server egress: only the API server CIDRs on 443 and 6443, no DNS, nothing else" "$(q "$(docs "${DA[@]}" "${DC[@]}")" "$EG|[(.spec.policyTypes|join(\",\")),(.spec.egress|length|tostring),(.spec.egress[0].to|tojson),(.spec.egress[0].ports|map(.port)|tojson)]|join(\" \")")" 'Egress 1 [{"ipBlock":{"cidr":"172.18.0.0/24"}}] [443,6443]'
DFB=$(docs "${DA[@]}" --set-json 'diagnostics.apiServerCIDRs=[]' --set diagnostics.allowAnyApiServerAddress=true)
eq "server egress without CIDRs but with the explicit opt-in: the API ports toward any address (stated fallback), still only those ports" "$(q "$DFB" "$EG|[(.spec.egress|length|tostring),(.spec.egress[0]|has(\"to\")|tostring),(.spec.egress[0].ports|map(.port)|tojson)]|join(\" \")")" '1 false [443,6443]'
eq "F6: empty API server CIDRs without the opt-in is refused, naming both values" "$(render_err "${DA[@]}" --set-json 'diagnostics.apiServerCIDRs=[]' | /usr/bin/grep -c 'diagnostics.apiServerCIDRs is empty.*diagnostics.allowAnyApiServerAddress')" 1
eq "F6: allowAnyApiServerAddress defaults to false" "$(yq -r '.diagnostics.allowAnyApiServerAddress' "$CHART/values.yaml")" false
eq "F6: with the CIDRs set the egress names them and the opt-in changes nothing" "$(q "$(docs "${DA[@]}" --set diagnostics.allowAnyApiServerAddress=true)" "$EG|.spec.egress[0].to|tojson")" '[{"ipBlock":{"cidr":"172.18.0.0/24"}}]'
eq "the ingress and egress policies select the server pod" "$(q "$D" "[($NP|.spec.podSelector.matchLabels.app),($EG|.spec.podSelector.matchLabels.app)]|join(\",\")")" "cluster-read,cluster-read"
eq "a malformed CIDR fails the render" "$(render_err "${DA[@]}" --set 'diagnostics.apiServerCIDRs={nope}' | /usr/bin/grep -c 'diagnostics.apiServerCIDRs')" 1
eq "the kb and notify ingress policies admit the profile vMCP of the group (as every profile vMCP)" "$(q "$D" '[.[]|select(.kind=="NetworkPolicy" and (.metadata.name=="kb-ingress" or .metadata.name=="notify-ingress"))|[.spec.ingress[0].from[]|.podSelector.matchLabels["toolhive-name"]]|index("tools-rca")!=null]|all')" true

echo "# diagnostics: render refusals"
ref() { render_err "${DA[@]}" "$@"; }
eq "networkPolicy off: refused, with the reason" "$(ref --set networkPolicy.enabled=false | /usr/bin/grep -c 'diagnostics.enabled needs networkPolicy.enabled=true')" 1
eq "networkPolicy off with only the master switch: refused too" "$(render_err --set diagnostics.enabled=true --set networkPolicy.enabled=false | /usr/bin/grep -c 'diagnostics.enabled needs networkPolicy.enabled=true')" 1
eq "content capture on: refused" "$(ref --set observability.enabled=true --set observability.bundled.enabled=true --set observability.capture.content=true | /usr/bin/grep -c 'diagnostics.enabled needs observability.capture.content=false')" 1
eq "mcp off: refused" "$(ref --set mcp.enabled=false --set 'mcp.profiles=null' | /usr/bin/grep -c 'diagnostics.enabled needs mcp.enabled=true')" 1
for BADNS in '*' 'Bad_Name' 'a.b' '-x'; do
  eq "logNamespaces entry '$BADNS' is refused" "$(ref --set "diagnostics.cluster.logNamespaces={$BADNS}" | /usr/bin/grep -c 'diagnostics.cluster.logNamespaces')" 1
done
eq "'*' in statusNamespaces is refused" "$(ref --set 'diagnostics.cluster.statusNamespaces={*}' | /usr/bin/grep -c 'diagnostics.cluster.statusNamespaces')" 1
eq "a duplicate in logNamespaces is refused" "$(ref --set 'diagnostics.cluster.logNamespaces={a,a}' | /usr/bin/grep -c 'lists "a" twice')" 1
eq "a duplicate in statusNamespaces is refused" "$(ref --set 'diagnostics.cluster.statusNamespaces={b,b}' | /usr/bin/grep -c 'lists "b" twice')" 1
eq "a namespace in both lists is refused" "$(ref --set 'diagnostics.cluster.logNamespaces={rca-demo}' --set 'diagnostics.cluster.statusNamespaces={rca-demo}' | /usr/bin/grep -c 'is in both')" 1
eq "openagentix-diagnostics in logNamespaces is refused" "$(ref --set 'diagnostics.cluster.logNamespaces={openagentix-diagnostics}' | /usr/bin/grep -c 'openagentix-diagnostics')" 1
eq "openagentix-diagnostics in statusNamespaces is refused" "$(ref --set 'diagnostics.cluster.statusNamespaces={openagentix-diagnostics}' | /usr/bin/grep -c 'diagnostics.cluster.statusNamespaces.*openagentix-diagnostics')" 1
for P in kube-system kube-public kube-node-lease mcp-tools kagent agentgateway-system openagentix-knowledge openagentix-notify openagentix-gateway openagentix-schedules openagentix-observability openagentix-memory openagentix-system toolhive-system ate-system openagentix-workloads openagentix-channels agent-kourier; do
  eq "$P in logNamespaces is refused (platform namespaces may be status-only)" "$(ref --set "diagnostics.cluster.logNamespaces={$P}" | /usr/bin/grep -c 'may not be a log namespace')" 1
done
eq "a values-defined namespace (knowledge.namespace renamed) is refused in logNamespaces too" "$(ref --set knowledge.namespace=kbspace --set 'diagnostics.cluster.statusNamespaces={}' --set 'diagnostics.cluster.logNamespaces={kbspace}' | /usr/bin/grep -c 'may not be a log namespace')" 1
eq "the control plane's own namespace (controlPlane.namespace) is refused in logNamespaces" "$(ref --set controlPlane.namespace=cpns --set 'diagnostics.cluster.logNamespaces={cpns}' | /usr/bin/grep -c 'may not be a log namespace')" 1
eq "kube-system is allowed in statusNamespaces" "$([ -z "$(ref --set 'diagnostics.cluster.statusNamespaces={kube-system}')" ] && echo rendered || echo failed)" rendered
eq "platform namespaces are allowed in statusNamespaces (kagent, mcp-tools, toolhive-system)" "$([ -z "$(ref --set 'diagnostics.cluster.statusNamespaces={kagent,mcp-tools,toolhive-system}')" ] && echo rendered || echo failed)" rendered
eq "more than 100 namespaces is refused" "$(ref --set "diagnostics.cluster.statusNamespaces={$(printf 'n%s,' $(seq 1 101) | sed 's/,$//')}" | /usr/bin/grep -c 'at most 100')" 1
eq "a namespace list that is not a list is refused" "$(ref --set diagnostics.cluster.logNamespaces=rca-demo | /usr/bin/grep -c 'diagnostics.cluster.logNamespaces must be a list')" 1

echo "# diagnostics: render refusals for profiles (code mode, outbound tools, allowWith)"
vf '.mcp.profiles[0].codeMode=true'
eq "code mode on a profile with a diagnostics tool is refused" "$(render_err -f "$DX2" | /usr/bin/grep -c 'profile "rca" lists a diagnostics tool, so codeMode must be false')" 1
eq "a code mode profile without diagnostics tools is fine next to it" "$([ -z "$(ref --set 'mcp.profiles[1].codeMode=true')" ] && echo rendered || echo failed)" rendered
vf '.mcp.profiles[0].tools.fetch=["fetch"]'
eq "fetch next to diagnostics tools is refused (it can carry data to any URL), naming the tool and the fix" "$(render_err -f "$DX2" | /usr/bin/grep -c 'profile "rca": the tool "fetch" of "fetch" may not sit next to diagnostics tools; the operator can write it into diagnostics.allowWith')" 1
eq "fetch written into allowWith is accepted" "$([ -z "$(render_err -f "$DX2" --set 'diagnostics.allowWith.fetch={fetch}')" ] && echo rendered || echo failed)" rendered
eq "allowing a different tool of the backend does not allow this one" "$(render_err -f "$DX2" --set 'diagnostics.allowWith.fetch={other}' | /usr/bin/grep -c 'may not sit next to diagnostics tools')" 1
DF=$(docs -f "$DX2" --set 'diagnostics.allowWith.fetch={fetch}')
eq "allowWith: an entry fetch-diagnostics points at the server's proxy Service, in the diagnostics group, unauthenticated" "$(q "$DF" "$ENT|select(.metadata.name==\"fetch-diagnostics\")|[.spec.groupRef.name,.spec.remoteUrl,.spec.externalAuthConfigRef.name]|join(\" \")")" "diagnostics http://mcp-fetch-proxy.mcp-tools.svc.cluster.local:8080/mcp fetch-diagnostics-noauth"
eq "allowWith: the profile vMCP lists the entry with its filter" "$(q "$DF" "$RCA|.spec.config.aggregation.tools[]|select(.workload==\"fetch-diagnostics\")|.filter|join(\",\")")" fetch
eq "allowWith: the shared group still has only its own entries" "$(q "$DF" "[$ENT|select(.spec.groupRef.name==\"tools\")|.metadata.name]|sort|join(\" \")")" "delivery knowledge"
vf '.mcp.profiles[0].tools.knowledge=["kb_search","kb_ingest"]'
eq "a knowledge tool off the fixed list is refused" "$(render_err -f "$DX2" | /usr/bin/grep -c 'the tool "kb_ingest" of "knowledge" may not sit next to diagnostics tools')" 1
vf '.mcp.profiles[0].tools.knowledge=["kb_search","kb_get_document","kb_list_collections","kb_graph_search","kb_graph_entity","kb_graph_paths"] | .mcp.profiles[0].tools.delivery=["notify_send","notify_list_destinations"]'
eq "the whole fixed list of knowledge and delivery tools is accepted" "$([ -z "$(render_err -f "$DX2")" ] && echo rendered || echo failed)" rendered
eq "allowWith names a backend that is not in mcp.servers: refused" "$(ref --set 'diagnostics.allowWith.nosuch={x}' | /usr/bin/grep -c 'diagnostics.allowWith: "nosuch" is not a backend')" 1
eq "allowWith names kagent-tools: refused" "$(ref --set 'diagnostics.allowWith.kagent-tools={x}' | /usr/bin/grep -c 'kagent-tools')" 1
eq "allowWith with an empty tool list is refused" "$(ref --set 'diagnostics.allowWith.fetch={}' | /usr/bin/grep -c 'diagnostics.allowWith')" 1
vf '.mcp.profiles[0].tools["cluster-read"]=["pods_get","pods_exec"]'
eq "a diagnostics tool that does not exist is refused" "$(render_err -f "$DX2" | /usr/bin/grep -c 'cluster-read has no tool "pods_exec"')" 1
vf '.mcp.servers=[{name:"fetch",image:"x:1",port:8080},{name:"kagent-tools",image:"x:1",port:8080}] | .mcp.profiles[0].tools["kagent-tools"]=["k8s_get"]'
eq "kagent-tools never sits in a diagnostics profile" "$(render_err -f "$DX2" | /usr/bin/grep -c 'kagent-tools')" 1

echo "# diagnostics: definitions, container agents and reply channels"
CPA=(--set controlPlane.enabled=true)
eq "a diagnostics profile in controlPlane.policy.allowedProfiles is refused without allowDefinitions" "$(ref "${CPA[@]}" --set 'controlPlane.policy.allowedProfiles={rca}' | /usr/bin/grep -c 'diagnostics.allowDefinitions')" 1
eq "... and accepted with allowDefinitions: true" "$([ -z "$(ref "${CPA[@]}" --set 'controlPlane.policy.allowedProfiles={rca}' --set diagnostics.allowDefinitions=true)" ] && echo rendered || echo failed)" rendered
eq "a shared-group profile in allowedProfiles is not affected" "$([ -z "$(ref "${CPA[@]}" --set 'controlPlane.policy.allowedProfiles={lookup}')" ] && echo rendered || echo failed)" rendered
eq "the wildcard in allowedProfiles is refused while a diagnostics profile exists (it would open it)" "$(ref "${CPA[@]}" --set 'controlPlane.policy.allowedProfiles={*}' | /usr/bin/grep -c 'diagnostics.allowDefinitions')" 1
CAV=(--set controlPlane.containerAgents.enabled=true --set governance.a2a.enabled=true --set 'controlPlane.policy.allowedRuntimes={builtin,container}' --set 'controlPlane.policy.runtimes.container.images={registry.local/oa/}')
eq "a diagnostics profile in containerAgents.toolProfiles is refused without allowDefinitions" "$(ref "${CPA[@]}" "${CAV[@]}" --set 'controlPlane.containerAgents.toolProfiles={rca}' | /usr/bin/grep -c 'diagnostics.allowDefinitions')" 1
DW=$(docs "${DA[@]}" "${CPA[@]}" "${CAV[@]}" --set 'controlPlane.containerAgents.toolProfiles={rca}' --set diagnostics.allowDefinitions=true)
eq "with allowDefinitions the -workload variant is on the diagnostics group, deny-default, audit data off" "$(q "$DW" '.[]|select(.kind=="VirtualMCPServer" and .metadata.name=="tools-rca-workload")|[.spec.groupRef.name,.spec.config.aggregation.defaultToolVisibility,(.spec.config.audit.includeRequestData|tostring),(.spec.config.audit.includeResponseData|tostring)]|join(" ")')" "diagnostics deny false false"
eq "with allowDefinitions the server admits the -workload variant too (and no other)" "$(q "$DW" "$NP|[.spec.ingress[0].from[].podSelector.matchLabels[\"toolhive-name\"]]|sort|join(\",\")")" "tools-rca,tools-rca-workload"
eq "without containerAgents the server admits only tools-rca" "$(q "$D" "$NP|[.spec.ingress[0].from[].podSelector.matchLabels[\"toolhive-name\"]]|join(\",\")")" "tools-rca"
RCAAGENT='{name:"rcaagent", model:"claude-haiku", systemPrompt:"You find root causes.", toolProfile:"rca", tools:[{tools:["cluster-read_pods_get"]}]}'
agent_file ". + [$RCAAGENT]"
DA2=$(docs -f "$DX2" -f "$DX")
eq "an agent on the diagnostics profile renders (it names a tool the profile offers, on its own RemoteMCPServer)" "$(q "$DA2" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="rcaagent-template")|.spec.tools[0].mcp.server.name+" "+(.spec.tools[0].mcp.tools|join(","))')" "toolhive-vmcp-rca cluster-read_pods_get"
RCAKN='{name:"rcaagent", model:"claude-haiku", systemPrompt:"You find root causes.", toolProfile:"rca", knowledge:true, notify:{enabled:true}, tools:[{tools:["cluster-read_pods_get"]}]}'
agent_file ". + [$RCAKN]"
DX3="$(dirname "$0")/.diag-values3.yaml"
yq -y '.mcp.profiles[0].tools.knowledge=["kb_search","kb_get_document","kb_list_collections"] | .mcp.profiles[0].tools.delivery=["notify_send","notify_list_destinations"]' "$DX" > "$DX3"
DA3=$(docs -f "$DX2" -f "$DX3")
eq "knowledge and notify tools of such an agent carry the entry names of the group" "$(q "$DA3" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="rcaagent-template")|.spec.tools[0].mcp.tools|sort|join(",")')" "cluster-read_pods_get,delivery-diagnostics_notify_list_destinations,delivery-diagnostics_notify_send,knowledge-diagnostics_kb_get_document,knowledge-diagnostics_kb_list_collections,knowledge-diagnostics_kb_search"
eq "the prompt of such an agent names the tools of the group, not the shared ones" "$(q "$DA3" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="rcaagent-template")|.spec.systemPrompt|(contains("knowledge-diagnostics_kb_search") and (contains("knowledge_kb_search")|not) and contains("delivery-diagnostics_notify_send"))')" true
eq "an agent on a shared-group profile keeps the shared names (knowledge_kb_search)" "$(q "$(with_agents '. + [{name:"other", model:"claude-haiku", systemPrompt:"x", toolProfile:"lookup", knowledge:false, tools:[{tools:["osv_query_vulnerability"]}]}]' -f "$DX3")" '.[]|select(.kind=="AgentTemplate" and .metadata.name=="other-template")|.spec.tools[0].mcp.tools|join(",")')" "osv_query_vulnerability"
rm -f "$DX3"
agent_file ". + [$RCAAGENT]"
eq "the Telegram bridge may serve such an agent (it sends without link previews since PR 234)" "$([ -z "$(render_err -f "$DX2" -f "$DX" --set bridge.agent=rcaagent)" ] && echo rendered || echo failed)" rendered
CHX="$(dirname "$0")/.diag-channel.yaml"
cat > "$CHX" <<YAML
channels:
  kourier: {enabled: true}
  connections:
    - {name: hook, platform: webhook, existingSecret: hook-secret, webhook: {identity: src, verify: {scheme: hmac-sha256, header: X-S, prefix: "sha256="}, channel: {from: [/c]}, actor: {from: [/u]}, thread: {field: conv, prefix: c-}, delivery: {header: X-D}, fields: [{name: conv, from: [/conv], kind: id}]}}
  bindings:
    - {name: b, connection: hook, channel: c, agent: rcaagent, output: none, triggers: [{type: webhookEvent, match: {event: x}, promptTemplate: "go", limits: {rateLimit: {maxRuns: 1, per: 1h, maxConcurrent: 1}, maxRunsPerDay: 1}}]}
YAML
eq "a channel binding for such an agent is refused (a binding is not on the no-preview list)" "$(render_err -f "$DX2" -f "$DX" -f "$CHX" --api-versions agentkourier.dev/v1alpha1 | /usr/bin/grep -c 'channels.bindings\[b\].*rcaagent.*no link previews')" 1
eq "a binding for another agent is not affected" "$([ -z "$(render_err -f "$DX2" -f "$DX" -f "$CHX" --api-versions agentkourier.dev/v1alpha1 --set 'channels.bindings[0].agent=assistant')" ] && echo rendered || echo failed)" rendered
rm -f "$CHX"
eq "the no-preview list is one helper (the bridge, nothing else: a new channel joins it only with a test)" "$(/usr/bin/grep -A2 'define "oa.diagNoPreviewPaths"' "$CHART/templates/_diagnostics.tpl" | /usr/bin/grep -c 'list "bridge" "notify" | toJson')" 1

echo "# diagnostics: an agent cannot reach a diagnostics profile's server without being on the profile (review F1)"
SRV='toolhive-vmcp-rca'
BYP='{name:"bypass", model:"claude-haiku", systemPrompt:"x", tools:[{server:"toolhive-vmcp-rca", tools:["cluster-read_pods_log"]},{server:"toolhive-vmcp-lookup", tools:["osv_query_vulnerability"]}]}'
agent_file ". + [$BYP]"
eq "an agent without toolProfile that names the server of a diagnostics profile is refused (outbound tools could sit next to log access)" "$(render_err -f "$DX2" -f "$DX" | /usr/bin/grep -c 'agent "bypass" names the tool server "toolhive-vmcp-rca" of the diagnostics profile "rca" without being on that profile')" 1
BYP1='{name:"bypass", model:"claude-haiku", systemPrompt:"x", tools:[{server:"toolhive-vmcp-rca", tools:["cluster-read_pods_log"]}]}'
agent_file ". + [$BYP1]"
eq "... also when it names only that server" "$(render_err -f "$DX2" -f "$DX" | /usr/bin/grep -c 'without being on that profile')" 1
BYP2='{name:"bypass", model:"claude-haiku", systemPrompt:"x", toolProfile:"lookup", tools:[{server:"toolhive-vmcp-rca", tools:["cluster-read_pods_log"]}]}'
agent_file ". + [$BYP2]"
eq "... and an agent on another profile that names it is refused too" "$([ -n "$(render_err -f "$DX2" -f "$DX")" ] && echo refused || echo rendered)" refused
BYP3='{name:"bypass", model:"claude-haiku", systemPrompt:"x", tools:[{server:"toolhive-vmcp-rca", tools:["cluster-read_pods_log"]}]}'
agent_file ". + [$BYP3]"
CHX2="$(dirname "$0")/.diag-channel2.yaml"
cat > "$CHX2" <<YAML
channels:
  kourier: {enabled: true}
  connections:
    - {name: hook, platform: webhook, existingSecret: hook-secret, webhook: {identity: src, verify: {scheme: hmac-sha256, header: X-S, prefix: "sha256="}, channel: {from: [/c]}, actor: {from: [/u]}, thread: {field: conv, prefix: c-}, delivery: {header: X-D}, fields: [{name: conv, from: [/conv], kind: id}]}}
  bindings:
    - {name: b, connection: hook, channel: c, agent: bypass, output: none, triggers: [{type: webhookEvent, match: {event: x}, promptTemplate: "go", limits: {rateLimit: {maxRuns: 1, per: 1h, maxConcurrent: 1}, maxRunsPerDay: 1}}]}
YAML
eq "a Kourier binding to such an agent cannot reach log access around the reply-path rule: the agent is refused first" "$(render_err -f "$DX2" -f "$DX" -f "$CHX2" --api-versions agentkourier.dev/v1alpha1 | /usr/bin/grep -c 'without being on that profile')" 1
rm -f "$CHX2"
agent_file ". + [$RCAAGENT]"
eq "an agent on the profile may name its own server explicitly" "$([ -z "$(render_err -f "$DX2" -f "$DX")" ] && echo rendered || echo failed)" rendered
eq "no diagnostics profile: naming toolhive-vmcp-lookup directly is still allowed (the rule is about diagnostics profiles)" "$([ -z "$(render_err -f <(yq -y '{agents: (.agents|. + [{name:"o", model:"claude-haiku", systemPrompt:"x", tools:[{server:"toolhive-vmcp-lookup", tools:["osv_query_vulnerability"]}]}])}' "$CHART/values.yaml") -f "$DX")" ] && echo rendered || echo failed)" rendered

echo "# diagnostics: profiles stay out of the control plane catalog and the AgentTemplate guard while allowDefinitions is false (review F2)"
DCP0=$(docs "${DA[@]}" --set controlPlane.enabled=true)
CATP='.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|[.tools.toolhive.profiles[]|.name]|sort|join(",")'
eq "catalog, allowDefinitions false: the diagnostics profile rca is absent, lookup is there" "$(q "$DCP0" "$CATP")" lookup
GUARDTXT='[.[]|select(.kind=="ValidatingAdmissionPolicy")|tojson]|join(" ")'
eq "the AgentTemplate guard names neither the server of rca nor a cluster-read tool" "$(q "$DCP0" "$GUARDTXT" | /usr/bin/grep -c 'toolhive-vmcp-rca\|cluster-read_')" 0
DCP1=$(docs "${DA[@]}" --set controlPlane.enabled=true --set diagnostics.allowDefinitions=true)
eq "catalog, allowDefinitions true: rca is listed, with its tools" "$(q "$DCP1" "$CATP")" "lookup,rca"
eq "the guard then knows the server of rca" "$(q "$DCP1" "$GUARDTXT" | /usr/bin/grep -c 'toolhive-vmcp-rca')" 1
eq "the control plane's own policy and the rest of the catalog are the same either way (only the profile list differs)" "$(q "$DCP0" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|del(.tools.toolhive.profiles)|tojson' | shasum -a 256)" "$(q "$DCP1" '.[]|select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|del(.tools.toolhive.profiles)|tojson' | shasum -a 256)"

echo "# diagnostics: the values of the live check (components/diagnostics/ci-values.yaml) on the quick start"
CIV=(-f "$REPO/components/quickstart/values.yaml" -f "$REPO/components/diagnostics/ci-values.yaml" --set diagnostics.allowAnyApiServerAddress=true)   # install.sh sets the addresses itself
eq "they render on the quick start, and with the sample container agent" "$([ -z "$(render_err "${CIV[@]}")" ] && [ -z "$(render_err "${CIV[@]}" -f "$REPO/components/quickstart/byo-values.yaml")" ] && echo rendered || echo failed)" rendered
DCI=$(docs "${CIV[@]}")
eq "lookup stays on the shared group, rca is on the diagnostics group" "$(q "$DCI" '[.[]|select(.kind=="VirtualMCPServer")|.metadata.name+"@"+.spec.groupRef.name]|sort|join(" ")')" "tools-lookup@tools tools-rca@diagnostics tools@tools"
eq "the group has the one entry cluster-read (knowledge and notify are off in the quick start)" "$(q "$DCI" '[.[]|select(.kind=="MCPServerEntry")|.metadata.name]|join(",")')" "cluster-read"
eq "the log namespace gets the logs binding, the status namespaces do not" "$(q "$DCI" '[.[]|select(.kind=="RoleBinding" and .metadata.name=="openagentix-cluster-read-logs")|.metadata.namespace]|join(",")')+$(q "$DCI" '[.[]|select(.kind=="RoleBinding" and .metadata.name=="openagentix-cluster-read")|.metadata.namespace]|sort|join(",")')" "diag-ci+diag-ci,kagent,kube-system"

echo "# diagnostics: the render equals the baseline of the chart before this slice"
if [ -n "${OA_BASELINE_DIR:-}" ]; then   # a directory with default.txt, qs.txt, byo.txt and full.txt: `helm template` output of the chart before slice 4
  RC2="$REPO/components"
  eq "default render is byte-identical to the baseline (OA_BASELINE_DIR)" "$(helm template openagentix "$CHART" -n openagentix-system 2>&1 | shasum -a 256)" "$(shasum -a 256 < "$OA_BASELINE_DIR/default.txt")"
  eq "quick start render is byte-identical to the baseline" "$(helm template openagentix "$CHART" -n openagentix-system -f "$RC2/quickstart/values.yaml" 2>&1 | shasum -a 256)" "$(shasum -a 256 < "$OA_BASELINE_DIR/qs.txt")"
  eq "quick start with the sample container agent: byte-identical to the baseline" "$(helm template openagentix "$CHART" -n openagentix-system -f "$RC2/quickstart/values.yaml" -f "$RC2/quickstart/byo-values.yaml" 2>&1 | shasum -a 256)" "$(shasum -a 256 < "$OA_BASELINE_DIR/byo.txt")"
  eq "full demo render is byte-identical to the baseline" "$(helm template openagentix "$CHART" -n openagentix-system "${RCDEMO[@]}" $GKAPI 2>&1 | shasum -a 256)" "$(shasum -a 256 < "$OA_BASELINE_DIR/full.txt")"
fi
rm -f "$DX" "$DX2"
