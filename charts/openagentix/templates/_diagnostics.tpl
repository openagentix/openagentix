{{/* ---- Diagnostics (ADR 0025, slice 4): cluster-read ----------------------------------------------------------------
Everything here prints nothing unless diagnostics.enabled and diagnostics.cluster.enabled are true, so the default render is byte-identical. */}}

{{/* "true" when the read-only cluster server is on (the block may be absent: `diagnostics: null`). */}}
{{- define "oa.diagOn" -}}
{{- $d := .Values.diagnostics | default dict -}}
{{- $c := $d.cluster | default dict -}}
{{- if and $d.enabled $c.enabled -}}true{{- end -}}
{{- end -}}

{{/* The tool names of cluster-read (services/diagnostics, ADR 0025 section 2), as a JSON list. */}}
{{- define "oa.diagClusterTools" -}}
{{- list "pods_list_in_namespace" "pods_get" "pods_log" "events_list" "workloads_list" "workloads_get" "nodes_list" "nodes_get" | toJson -}}
{{- end -}}

{{/* The chart's own reply paths that are known to send without link previews (ADR 0025 section 6, "Reply channels do not fetch links"):
the Telegram bridge since PR 234, and notify. A new path joins this list only with a test that it turns previews off. JSON list. */}}
{{- define "oa.diagNoPreviewPaths" -}}
{{- list "bridge" "notify" | toJson -}}
{{- end -}}

{{/* "true" when the profile lists a diagnostics tool and the server is on. Argument: dict "root" <top> "profile" <one mcp.profiles entry>. */}}
{{- define "oa.diagProfile" -}}
{{- if and (include "oa.diagOn" .root) (kindIs "map" .profile) (kindIs "map" .profile.tools) (hasKey .profile.tools "cluster-read") -}}true{{- end -}}
{{- end -}}

{{/* The name of a backend as the profile's vMCP knows it. A diagnostics profile lives on the group `diagnostics`, which holds its own entry for every
other backend it may list, named <entryName>-diagnostics (the shared group has the entries knowledge and delivery already). cluster-read keeps its name.
Argument: dict "root" <top> "profile" <profile> "w" <backend name>. */}}
{{- define "oa.diagWorkload" -}}
{{- if and (include "oa.diagProfile" .) (ne .w "cluster-read") -}}{{ printf "%s-diagnostics" .w }}{{- else -}}{{ .w }}{{- end -}}
{{- end -}}

{{/* Renames the tool names of the knowledge base and notify in a text (a prompt, or a JSON list of tool names) to the entries of the group
`diagnostics`. Argument: dict "root" <top> "text" <string>. */}}
{{- define "oa.diagRename" -}}
{{- $r := .root -}}
{{- $t := .text -}}
{{- $kp := replace "{workload}" $r.Values.knowledge.mcp.entryName $r.Values.mcp.virtual.prefixFormat -}}
{{- $kn := replace "{workload}" (printf "%s-diagnostics" $r.Values.knowledge.mcp.entryName) $r.Values.mcp.virtual.prefixFormat -}}
{{- $np := replace "{workload}" $r.Values.notify.mcp.entryName $r.Values.mcp.virtual.prefixFormat -}}
{{- $nn := replace "{workload}" (printf "%s-diagnostics" $r.Values.notify.mcp.entryName) $r.Values.mcp.virtual.prefixFormat -}}
{{- $t | replace (printf "%skb_" $kp) (printf "%skb_" $kn) | replace (printf "%snotify_" $np) (printf "%snotify_" $nn) -}}
{{- end -}}

{{/* Every namespace the chart itself uses or the platform runs in, plus the system ones: none of them may be a log namespace. JSON list, sorted, unique. */}}
{{- define "oa.diagPlatformNamespaces" -}}
{{- $v := .Values -}}
{{- $cp := $v.controlPlane | default dict -}}
{{- $ca := $cp.containerAgents | default dict -}}
{{- $cn := $v.console | default dict -}}
{{- $ch := ($v.channels | default dict).kourier | default dict -}}
{{- $np := $v.networkPolicy | default dict -}}
{{- $l := list "kube-system" "kube-public" "kube-node-lease" "openagentix-diagnostics" .Release.Namespace (default .Release.Namespace $cp.namespace) (default .Release.Namespace $cn.namespace) -}}
{{- range $x := list $v.mcp.namespace $v.kagent.namespace ($v.gateway | default dict).namespace ($v.knowledge | default dict).namespace ($v.notify | default dict).namespace ($v.memory | default dict).namespace ($v.scheduling | default dict).namespace ($v.observability | default dict).namespace ($v.bridge | default dict).namespace (($v.governance | default dict).a2a | default dict).namespace $ca.namespace $ch.namespace ($ch.broker | default dict).namespace $np.toolhiveNamespace ($np.substrate | default dict).namespace -}}
{{- if $x }}{{ $l = append $l $x }}{{ end -}}
{{- end -}}
{{- $l | uniq | sortAlpha | toJson -}}
{{- end -}}

{{/* The refusals of ADR 0025 sections 2, 5 and 6 for cluster-read. Prints nothing; fails the render with a sentence that names the fix.
Safe to include from several templates. */}}
{{- define "oa.diagCheck" -}}
{{- $d := .Values.diagnostics | default dict -}}
{{- $c := $d.cluster | default dict -}}
{{- if $d.enabled -}}
{{- if not .Values.networkPolicy.enabled }}{{ fail "diagnostics.enabled needs networkPolicy.enabled=true: the diagnostic tool servers have no authentication of their own besides one bearer value, and the NetworkPolicy keeps every other pod away from them" }}{{ end -}}
{{- $obs := .Values.observability | default dict -}}
{{- if ($obs.capture | default dict).content }}{{ fail "diagnostics.enabled needs observability.capture.content=false: with capture on, tool results (log lines, events) would be copied into the tool gateway's audit and the runtime's traces, where redaction is the only filter" }}{{ end -}}
{{- if not .Values.mcp.enabled }}{{ fail "diagnostics.enabled needs mcp.enabled=true: the tools are served through the tool gateway" }}{{ end -}}
{{- end -}}
{{- if include "oa.diagOn" . -}}
{{- $m := .Values.mcp -}}
{{- $_ := include "oa.profilesCheck" . -}}
{{- $log := $c.logNamespaces | default list -}}
{{- $st := $c.statusNamespaces | default list -}}
{{- if not (kindIs "slice" $log) }}{{ fail "diagnostics.cluster.logNamespaces must be a list of namespace names" }}{{ end -}}
{{- if not (kindIs "slice" $st) }}{{ fail "diagnostics.cluster.statusNamespaces must be a list of namespace names" }}{{ end -}}
{{- if gt (add (len $log) (len $st)) 100 }}{{ fail "diagnostics.cluster: at most 100 namespaces in logNamespaces and statusNamespaces together (the rights check costs one request per namespace)" }}{{ end -}}
{{- $platform := include "oa.diagPlatformNamespaces" . | fromJsonArray -}}
{{- range $key, $list := dict "logNamespaces" $log "statusNamespaces" $st -}}
{{- $seen := list -}}
{{- range $x := $list -}}
{{- if eq (toString $x) "*" }}{{ fail (printf "diagnostics.cluster.%s: \"*\" is not allowed: list every namespace by name" $key) }}{{ end -}}
{{- if not (and (kindIs "string" $x) (le (len $x) 63) (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $x)) }}{{ fail (printf "diagnostics.cluster.%s: %v is not a DNS label (lower case letters, digits and dashes, at most 63 characters)" $key $x) }}{{ end -}}
{{- if has $x $seen }}{{ fail (printf "diagnostics.cluster.%s lists %q twice" $key $x) }}{{ end -}}
{{- $seen = append $seen $x -}}
{{- if eq $x "openagentix-diagnostics" }}{{ fail (printf "diagnostics.cluster.%s: openagentix-diagnostics is the namespace of the tool server itself and may not be listed" $key) }}{{ end -}}
{{- if and (eq $key "logNamespaces") (has $x $platform) }}{{ fail (printf "diagnostics.cluster.logNamespaces: %q may not be a log namespace (it is a platform or system namespace, and an agent would read the platform's own logs). Put it in diagnostics.cluster.statusNamespaces to see its pods, events and workloads without logs" $x) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- range $x := $log }}{{ if has $x $st }}{{ fail (printf "diagnostics.cluster: namespace %q is in both logNamespaces and statusNamespaces: list it once (logs need logNamespaces)" $x) }}{{ end }}{{ end -}}
{{- if and (hasKey $c "nodes") (not (kindIs "bool" $c.nodes)) }}{{ fail "diagnostics.cluster.nodes must be true or false" }}{{ end -}}
{{- /* the API server addresses and ports of the egress policy */ -}}
{{- if not (kindIs "slice" ($d.apiServerCIDRs | default list)) }}{{ fail "diagnostics.apiServerCIDRs must be a list of CIDRs" }}{{ end -}}
{{- range $x := ($d.apiServerCIDRs | default list) }}
{{- if not (and (kindIs "string" $x) (or (regexMatch "^([0-9]{1,3}[.]){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$" $x) (regexMatch "^[0-9a-fA-F:]*:[0-9a-fA-F:.]*/([0-9]{1,2}|1[01][0-9]|12[0-8])$" $x))) }}{{ fail (printf "diagnostics.apiServerCIDRs entry %v is not a CIDR (for example 10.0.0.0/24)" $x) }}{{ end }}
{{- end -}}
{{- if and (not ($d.apiServerCIDRs | default list)) (not $d.allowAnyApiServerAddress) }}{{ fail "diagnostics.apiServerCIDRs is empty: the egress policy of cluster-read would then allow the API server ports towards ANY address. Set the API server addresses (install.sh does), or set diagnostics.allowAnyApiServerAddress=true to accept that on purpose" }}{{ end -}}
{{- if not (kindIs "slice" $d.apiServerPorts) }}{{ fail "diagnostics.apiServerPorts must be a list of port numbers" }}{{ end -}}
{{- range $x := $d.apiServerPorts }}
{{- if not (and (or (kindIs "float64" $x) (kindIs "int64" $x) (kindIs "int" $x)) (ge (int $x) 1) (le (int $x) 65535)) }}{{ fail (printf "diagnostics.apiServerPorts entry %v is not a port number" $x) }}{{ end }}
{{- end -}}
{{- /* allowWith: backend (mcp.servers) -> tool names */ -}}
{{- $aw := $d.allowWith | default dict -}}
{{- if not (kindIs "map" $aw) }}{{ fail "diagnostics.allowWith must be a map of backend name to a list of tool names" }}{{ end -}}
{{- $servers := list -}}{{- range $m.servers }}{{ $servers = append $servers .name }}{{ end -}}
{{- range $b, $tl := $aw -}}
{{- if eq $b "kagent-tools" }}{{ fail "diagnostics.allowWith: kagent-tools is never allowed: it is bound to a role that allows everything" }}{{ end -}}
{{- if not (has $b $servers) }}{{ fail (printf "diagnostics.allowWith: %q is not a backend of mcp.servers (%s)" $b (join ", " $servers)) }}{{ end -}}
{{- if or (not (kindIs "slice" $tl)) (not $tl) }}{{ fail (printf "diagnostics.allowWith.%s needs a non-empty list of tool names" $b) }}{{ end -}}
{{- range $t := $tl }}{{ if not (and (kindIs "string" $t) (regexMatch "^[A-Za-z0-9_.-]+$" $t)) }}{{ fail (printf "diagnostics.allowWith.%s lists a tool name that is not valid: %v" $b $t) }}{{ end }}{{ end -}}
{{- end -}}
{{- /* the profiles that list a diagnostics tool */ -}}
{{- $cp := .Values.controlPlane | default dict -}}
{{- $pol := $cp.policy | default dict -}}
{{- $allowedProfiles := $pol.allowedProfiles | default list -}}
{{- $caNames := list -}}{{- range $w := (include "oa.caToolProfiles" . | fromJsonArray) }}{{ $caNames = append $caNames $w.name }}{{ end -}}
{{- $knowledgeFixed := list "kb_search" "kb_get_document" "kb_list_collections" "kb_graph_search" "kb_graph_entity" "kb_graph_paths" -}}
{{- $notifyFixed := list "notify_send" "notify_list_destinations" -}}
{{- $noPreview := include "oa.diagNoPreviewPaths" . | fromJsonArray -}}
{{- $clusterTools := include "oa.diagClusterTools" . | fromJsonArray -}}
{{- /* an agent reaches a diagnostics profile's tools only through its own toolProfile: naming the profile's RemoteMCPServer in tools[].server would go around the rules below (outbound tools, reply paths) */ -}}
{{- range $p := ($m.profiles | default list) -}}
{{- if include "oa.diagProfile" (dict "root" $ "profile" $p) -}}
{{- $dsrv := printf "%s-%s" $.Values.kagent.remoteMCPServer.name $p.name -}}
{{- range $a := $.Values.agents -}}
{{- range $t := ($a.tools | default list) -}}
{{- if and (eq (toString $t.server) $dsrv) (ne (toString $a.toolProfile) $p.name) }}{{ fail (printf "agent %q names the tool server %q of the diagnostics profile %q without being on that profile: set toolProfile: %s (then its tools are checked against the profile), or take the server out of tools[].server" $a.name $dsrv $p.name $p.name) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $p := ($m.profiles | default list) -}}
{{- if include "oa.diagProfile" (dict "root" $ "profile" $p) -}}
{{- if $p.codeMode }}{{ fail (printf "profile %q lists a diagnostics tool, so codeMode must be false: code mode chains calls without the model's step in between" $p.name) }}{{ end -}}
{{- range $t := (index $p.tools "cluster-read") }}{{ if not (has $t $clusterTools) }}{{ fail (printf "profile %q: cluster-read has no tool %q (tools: %s)" $p.name $t (join ", " $clusterTools)) }}{{ end }}{{ end -}}
{{- range $w := (keys $p.tools | sortAlpha) -}}
{{- if ne $w "cluster-read" -}}
{{- $ok := list -}}
{{- if eq $w $.Values.knowledge.mcp.entryName }}{{ $ok = concat $ok $knowledgeFixed }}{{ end -}}
{{- if eq $w $.Values.notify.mcp.entryName }}{{ $ok = concat $ok $notifyFixed }}{{ end -}}
{{- if and (ne $w "kagent-tools") (hasKey $aw $w) }}{{ $ok = concat $ok (index $aw $w) }}{{ end -}}
{{- range $t := (index $p.tools $w) -}}
{{- if or (eq $w "kagent-tools") (not (has $t $ok)) }}{{ fail (printf "profile %q: the tool %q of %q may not sit next to diagnostics tools; the operator can write it into diagnostics.allowWith (outbound tools such as fetch could carry data from a log to any URL)" $p.name $t $w) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $d.allowDefinitions -}}
{{- if and $cp.enabled (or (has $p.name $allowedProfiles) (has "*" $allowedProfiles)) }}{{ fail (printf "controlPlane.policy.allowedProfiles opens the profile %q, which lists a diagnostics tool, to every AgentDefinition: set diagnostics.allowDefinitions=true to allow that on purpose (by default only chart agents can use it)" $p.name) }}{{ end -}}
{{- if has $p.name $caNames }}{{ fail (printf "controlPlane.containerAgents.toolProfiles opens the profile %q, which lists a diagnostics tool, to container agents: set diagnostics.allowDefinitions=true to allow that on purpose" $p.name) }}{{ end -}}
{{- end -}}
{{- /* reply paths that render a link: only the ones that send without link previews */ -}}
{{- range $a := $.Values.agents -}}
{{- if eq (toString $a.toolProfile) $p.name -}}
{{- if and $.Values.bridge.enabled (eq $.Values.bridge.agent $a.name) (eq $.Values.bridge.agentNamespace $.Values.kagent.namespace) (not (has "bridge" $noPreview)) }}{{ fail (printf "bridge.agent %q is on the diagnostics profile %q, and the bridge is not on the list of reply paths that send with no link previews" $a.name $p.name) }}{{ end -}}
{{- $kr := (($.Values.channels | default dict).kourier | default dict) -}}
{{- if $kr.enabled -}}
{{- range $b := ($.Values.channels.bindings | default list) -}}
{{- if and (eq (toString $b.agent) $a.name) (not (has "kourier" $noPreview)) }}{{ fail (printf "channels.bindings[%s]: the agent %q is on the diagnostics profile %q, and a channel binding is not one of the reply paths known to send with no link previews (the Telegram bridge is): a link in a reply could be fetched by the chat service and carry data out. Point the binding at another agent, or remove it" $b.name $a.name $p.name) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
