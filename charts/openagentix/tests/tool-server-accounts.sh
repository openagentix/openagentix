#!/usr/bin/env bash
# Chart tests of ADR 0031 slice 3: mcp.virtual.ownServiceAccounts, a ServiceAccount, a Role with no right on Secrets and a RoleBinding for every
# tool server (VirtualMCPServer) the chart renders. Sourced by run.sh (it shares eq, q, count, docs, render_err and the variables CHART, REPO, RC,
# RCDEMO, GKAPI). Every check here was written before the chart code and failed first (see the pull request).
echo "# tool server accounts (ADR 0031, slice 3): mcp.virtual.ownServiceAccounts, off by default"
TX="$(dirname "$0")/.tsa-values.yaml"
TX2="$(dirname "$0")/.tsa-values2.yaml"
# One install that renders every kind of tool server: the shared one, a profile on the shared group, a profile on a group of its own (an
# endpoint with a header Secret, the knowledge base and notify mirrors), a profile on the diagnostics group, and a -workload variant of each of
# the two profiles that container agents may use.
cat > "$TX" <<YAML
controlPlane:
  enabled: true
  apiServerCIDRs: [172.18.0.0/24]
  policy:
    allowedRuntimes: [builtin, container]
    runtimes:
      container:
        images: [registry.local/oa/]
  containerAgents:
    enabled: true
    toolProfiles: [lookup, rca]
governance:
  a2a:
    enabled: true
notify:
  enabled: true
diagnostics:
  enabled: true
  allowDefinitions: true
  apiServerCIDRs: [172.18.0.0/24]
  cluster:
    enabled: true
    logNamespaces: [rca-demo]
    statusNamespaces: [openagentix-knowledge, kagent]
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
    - name: rca
      codeMode: false
      tools:
        cluster-read: [pods_list_in_namespace, pods_get, pods_log, events_list, workloads_list, workloads_get, nodes_list, nodes_get]
        knowledge: [kb_search]
        delivery: [notify_send]
YAML
TA=(-f "$TX" --set diagnostics.allowAnyApiServerAddress=true)
TON=("${TA[@]}" --set mcp.virtual.ownServiceAccounts=true)
tv() { yq -y "$1" "$TX" > "$TX2"; }     # tv <jq filter>: the values with one edit in $TX2
ter() { local d=$1 s=$2; shift 2; eq "$d" "$(render_err "$@" | /usr/bin/grep -cF -- "$s")" 1; }
h256() { helm template openagentix "$CHART" -n openagentix-system "$@" 2>&1 | shasum -a 256; }

eq "default: ownServiceAccounts is false" "$(yq -c '.mcp.virtual.ownServiceAccounts' "$CHART/values.yaml")" false
echo "# tool server accounts: off renders byte for byte what it did before"
eq "default render = render with the value false" "$(h256 --set mcp.virtual.ownServiceAccounts=false)" "$(h256)"
eq "quick start render = render with the value false" "$(h256 -f "$RC/quickstart/values.yaml" --set mcp.virtual.ownServiceAccounts=false)" "$(h256 -f "$RC/quickstart/values.yaml")"
eq "full demo render = render with the value false" "$(h256 "${RCDEMO[@]}" $GKAPI --set mcp.virtual.ownServiceAccounts=false)" "$(h256 "${RCDEMO[@]}" $GKAPI)"
eq "every-kind render = render with the value false" "$(h256 "${TA[@]}" --set mcp.virtual.ownServiceAccounts=false)" "$(h256 "${TA[@]}")"
DOFF=$(docs "${TA[@]}")
eq "off: the every-kind render has the six tool servers" "$(q "$DOFF" '[.[]|select(.kind=="VirtualMCPServer")|.metadata.name]|sort|join(" ")')" "tools tools-disputes tools-lookup tools-lookup-workload tools-rca tools-rca-workload"
eq "off: no tool server names a ServiceAccount" "$(q "$DOFF" '[.[]|select(.kind=="VirtualMCPServer" and (.spec|has("serviceAccount")))]|length')" 0
eq "off: no ServiceAccount, Role or RoleBinding in the tools namespace" "$(q "$DOFF" '[.[]|select((.kind=="ServiceAccount" or .kind=="Role" or .kind=="RoleBinding") and .metadata.namespace=="mcp-tools")]|length')" 0

echo "# tool server accounts: on"
DON=$(docs "${TON[@]}")
eq "on: the every-kind values render" "$([ -z "$(render_err "${TON[@]}")" ] && echo rendered || echo failed)" rendered
VM='.[]|select(.kind=="VirtualMCPServer")'
eq "on: six tool servers still (the shared one, three profiles, two -workload variants)" "$(q "$DON" '[.[]|select(.kind=="VirtualMCPServer")|.metadata.name]|sort|join(" ")')" "tools tools-disputes tools-lookup tools-lookup-workload tools-rca tools-rca-workload"
eq "on: every tool server names the account openagentix-<its name>" "$(q "$DON" '[.[]|select(.kind=="VirtualMCPServer")|select(.spec.serviceAccount!=("openagentix-"+.metadata.name))|.metadata.name]|join(" ")')" ""
for K in ServiceAccount Role RoleBinding; do
  eq "on: one $K per tool server, in the tools namespace, named openagentix-<tool server>" "$(q "$DON" "[.[]|select(.kind==\"$K\" and .metadata.namespace==\"mcp-tools\")|.metadata.name]|sort|join(\" \")")" "$(q "$DON" '[.[]|select(.kind=="VirtualMCPServer")|"openagentix-"+.metadata.name]|sort|join(" ")')"
done
eq "on: those ServiceAccounts leave automountServiceAccountToken to the pod (the tool server needs its token)" "$(q "$DON" '[.[]|select(.kind=="ServiceAccount" and .metadata.namespace=="mcp-tools")|select(has("automountServiceAccountToken"))]|length')" 0
ROLE_RULES='[{"apiGroups":["toolhive.stacklok.dev"],"resources":["mcpgroups","mcpservers","mcpremoteproxies","mcpserverentries","mcpexternalauthconfigs","mcptoolconfigs"],"verbs":["get","list","watch"]},{"apiGroups":["toolhive.stacklok.dev"],"resources":["virtualmcpservers"],"verbs":["get"],"resourceNames":["NAME"]},{"apiGroups":["toolhive.stacklok.dev"],"resources":["virtualmcpservers/status"],"verbs":["update","patch"],"resourceNames":["NAME"]},{"apiGroups":[""],"resources":["configmaps"],"verbs":["get","list","watch"]}]'
for N in tools tools-disputes tools-lookup-workload tools-rca-workload; do
  eq "on: the Role of $N has exactly the rules of the ADR, its own name in resourceNames" "$(q "$DON" ".[]|select(.kind==\"Role\" and .metadata.name==\"openagentix-$N\")|.rules|tojson")" "${ROLE_RULES//NAME/$N}"
  eq "on: the RoleBinding of $N binds that Role to that ServiceAccount and nothing else" "$(q "$DON" ".[]|select(.kind==\"RoleBinding\" and .metadata.name==\"openagentix-$N\")|[(.roleRef|tojson),(.subjects|tojson)]|join(\" \")")" "{\"apiGroup\":\"rbac.authorization.k8s.io\",\"kind\":\"Role\",\"name\":\"openagentix-$N\"} [{\"kind\":\"ServiceAccount\",\"name\":\"openagentix-$N\",\"namespace\":\"mcp-tools\"}]"
done
eq "on: no Role of the chart's tool server accounts has a rule on secrets or on a wildcard" "$(q "$DON" '[.[]|select(.kind=="Role" and (.metadata.name|startswith("openagentix-tools")))|.rules[]|select((.resources|index("secrets")!=null) or (.resources|index("*")!=null) or (.verbs|index("*")!=null) or (.apiGroups|index("*")!=null))]|length')" 0
eq "on: a Role names only its own tool server in resourceNames (no other tool server, no wildcard)" "$(q "$DON" '[.[]|select(.kind=="Role" and (.metadata.name|startswith("openagentix-tools")))|. as $r|.rules[]|select(.resourceNames!=null)|.resourceNames|select(.!=[($r.metadata.name|ltrimstr("openagentix-"))])]|length')" 0
eq "on: nothing in the render gives a verb on secrets to a tool server account (any Role or ClusterRole bound to one of them)" "$(q "$DON" '[.[]|select(.kind=="Role" or .kind=="ClusterRole")] as $roles
  | [.[]|select(.kind=="RoleBinding" or .kind=="ClusterRoleBinding")|select([.subjects[]?|select(.kind=="ServiceAccount" and .namespace=="mcp-tools" and (.name|startswith("openagentix-tools")))]|length>0)] as $bs
  | [$bs[]|. as $b|$roles[]|select(.kind==$b.roleRef.kind and .metadata.name==$b.roleRef.name)|.rules[]|select((.resources|index("secrets")!=null) or (.resources|index("*")!=null))]|length')" 0
eq "on: only the chart's own RoleBinding binds each tool server account (no ClusterRoleBinding, no second RoleBinding)" "$(q "$DON" '[.[]|select(.kind=="RoleBinding" or .kind=="ClusterRoleBinding")|select([.subjects[]?|select(.kind=="ServiceAccount" and .namespace=="mcp-tools" and (.name|startswith("openagentix-tools")))]|length>0)|.kind+"/"+.metadata.name]|sort|join(" ")')" "$(q "$DON" '[.[]|select(.kind=="VirtualMCPServer")|"RoleBinding/openagentix-"+.metadata.name]|sort|join(" ")')"
eq "on: the three objects carry the platform labels" "$(q "$DON" '[.[]|select((.kind=="ServiceAccount" or .kind=="Role" or .kind=="RoleBinding") and .metadata.namespace=="mcp-tools")|select(.metadata.labels["app.kubernetes.io/part-of"]!="openagentix")]|length')" 0
eq "on: the rest of the render is unchanged apart from spec.serviceAccount and the nine objects (the render minus them equals the off render)" "$(q "$DON" '[.[]|select(((.kind=="ServiceAccount" or .kind=="Role" or .kind=="RoleBinding") and .metadata.namespace=="mcp-tools")|not)|if .kind=="VirtualMCPServer" then del(.spec.serviceAccount) else . end]|tojson' | shasum -a 256)" "$(q "$DOFF" 'tojson' | shasum -a 256)"
eq "on: the tool server pods of the render keep outgoingAuth discovered" "$(q "$DON" '[.[]|select(.kind=="VirtualMCPServer")|.spec.outgoingAuth.source]|unique|join(",")')" discovered

echo "# tool server accounts: no Secret value in a ConfigMap of the tools namespace"
eq "on: the header Secret names are in the entry and in no ConfigMap of the tools namespace" "$(q "$DON" '[.[]|select(.kind=="MCPServerEntry")|.spec.headerForward.addHeadersFromSecret[]?.valueSecretRef.name] as $names
  | [.[]|select(.kind=="ConfigMap" and .metadata.namespace=="mcp-tools")|tojson|select(. as $c|any($names[];. as $n|$c|contains($n)))]|length')" 0
eq "on: there is at least one header Secret reference (the check above is not vacuous)" "$(q "$DON" '[.[]|select(.kind=="MCPServerEntry")|.spec.headerForward.addHeadersFromSecret[]?]|length>0')" true
eq "the chart reads no Secret at render time (no lookup in any template): a rendered ConfigMap cannot carry a Secret value" "$(/usr/bin/grep -rEc '\blookup[[:space:]]+"?v1"?[[:space:]]+"?Secret' "$CHART/templates" | awk -F: '{s+=$2} END {print s+0}')" 0
eq "on: the render holds no Secret object and no data under a ConfigMap of the tools namespace that came from a Secret value (no data at all in the tools namespace)" "$(count "$DON" '.kind=="Secret"')+$(q "$DON" '[.[]|select(.kind=="ConfigMap" and .metadata.namespace=="mcp-tools")]|length')" "0+0"

echo "# tool server accounts: the refusals"
for T in tokenExchange headerInjection xaa; do
  tv ".mcp.endpoints[0].auth = {\"$T\": {\"secret\": {\"name\": \"x\", \"key\": \"y\"}}}"
  ter "on: an endpoint with auth type $T is refused, naming the switch and the type" "$T" -f "$TX2" --set diagnostics.allowAnyApiServerAddress=true --set mcp.virtual.ownServiceAccounts=true
  ter "on: ... the message says the type reads a Secret at run time" "reads a Secret at run time" -f "$TX2" --set diagnostics.allowAnyApiServerAddress=true --set mcp.virtual.ownServiceAccounts=true
  ter "off: the same endpoint is refused as before (only the key header is accepted)" "only the key header is accepted" -f "$TX2" --set diagnostics.allowAnyApiServerAddress=true
done
ter "a value that is not a boolean is refused" "mcp.virtual.ownServiceAccounts must be true or false" "${TA[@]}" --set-string mcp.virtual.ownServiceAccounts=yes
ter "null is refused too (an unset switch must not turn the reach back on silently)" "mcp.virtual.ownServiceAccounts must be true or false" "${TA[@]}" --set mcp.virtual.ownServiceAccounts=null
eq "mcp.enabled=false with the value on renders no tool server account" "$(count "$(docs --set mcp.enabled=false --set knowledge.enabled=false --set mcp.virtual.ownServiceAccounts=true)" '(.kind=="ServiceAccount" or .kind=="Role" or .kind=="RoleBinding") and .metadata.namespace=="mcp-tools"')" 0
DQ=$(docs -f "$RC/quickstart/values.yaml" --set mcp.virtual.ownServiceAccounts=true)
eq "quick start with the value on: the shared tool server and the profile lookup, three objects each" "$(q "$DQ" '[.[]|select(.metadata.namespace=="mcp-tools" and (.kind=="ServiceAccount" or .kind=="Role" or .kind=="RoleBinding"))|.kind+"/"+.metadata.name]|sort|join(" ")')" "Role/openagentix-tools Role/openagentix-tools-lookup RoleBinding/openagentix-tools RoleBinding/openagentix-tools-lookup ServiceAccount/openagentix-tools ServiceAccount/openagentix-tools-lookup"

echo "# tool server accounts: the warning of NOTES.txt (helm template never prints notes, so the file is rendered from a copy of the chart as a plain template)"
NC=$(mktemp -d)
cp -R "$CHART" "$NC/chart"
{ echo '{{- define "oa.notesCopy" -}}'; cat "$NC/chart/templates/NOTES.txt"; echo '{{- end -}}'; echo 'notes: {{ include "oa.notesCopy" . | toJson }}'; } > "$NC/chart/templates/notes-copy.yaml"
rm "$NC/chart/templates/NOTES.txt"
notes() { helm template openagentix "$NC/chart" -n openagentix-system --show-only templates/notes-copy.yaml "$@" 2>&1; }
eq "NOTES.txt exists in the chart" "$([ -f "$CHART/templates/NOTES.txt" ] && echo yes || echo no)" yes
N=$(notes "${TA[@]}")
eq "off with credentials: the warning names the endpoint header Secret" "$(printf '%s' "$N" | /usr/bin/grep -c 'records-mcp-auth (header of the endpoint records)')" 1
eq "off with credentials: the warning names the diagnostics bearer Secret" "$(printf '%s' "$N" | /usr/bin/grep -c 'diagnostics-bearer-cluster-read')" 1
eq "off with credentials: the warning says every tool server can read every Secret and names the switch" "$(printf '%s' "$N" | /usr/bin/grep -c 'WARNING: mcp.virtual.ownServiceAccounts is false. Every tool server')" 1
eq "on: no warning" "$(notes "${TON[@]}" | /usr/bin/grep -c 'WARNING')" 0
eq "off with no credential in the install (the default values): no warning" "$(notes | /usr/bin/grep -c 'WARNING')" 0
rm -rf "$NC"
rm -f "$TX" "$TX2"   # no trap: each sourced test file would replace the trap of the one before
