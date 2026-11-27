{{- define "oa.labels" -}}
app.kubernetes.io/part-of: openagentix
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* Base URL of the model gateway as seen from kagent sandboxes (FQDN: sandboxes do not apply search domains). */}}
{{- define "oa.gatewayBaseUrl" -}}
{{- if .Values.kagent.gatewayBaseUrl -}}{{ .Values.kagent.gatewayBaseUrl }}
{{- else -}}http://{{ .Values.gateway.name }}.{{ .Values.gateway.namespace }}.svc.cluster.local{{ if ne (int .Values.gateway.port) 80 }}:{{ .Values.gateway.port }}{{ end }}/v1
{{- end -}}
{{- end -}}

{{- define "oa.modelConfigName" -}}
{{- default (printf "gateway-%s" .name) .modelConfigName -}}
{{- end -}}

{{- define "oa.virtualKeySecret" -}}
{{- default (printf "%s-virtual-key" .name) .virtualKeySecret -}}
{{- end -}}

{{/* Tool names of the knowledge base as the vMCP exposes them: <prefix of the entry><kb tool>. JSON list. */}}
{{- define "oa.knowledgeTools" -}}
{{- $pfx := replace "{workload}" .Values.knowledge.mcp.entryName .Values.mcp.virtual.prefixFormat -}}
{{- $l := list (printf "%skb_search" $pfx) (printf "%skb_get_document" $pfx) (printf "%skb_list_collections" $pfx) -}}
{{- if .Values.knowledge.kb.graph.enabled }}{{ $l = concat $l (list (printf "%skb_graph_search" $pfx) (printf "%skb_graph_entity" $pfx) (printf "%skb_graph_paths" $pfx)) }}{{ end -}}
{{- $l | toJson -}}
{{- end -}}

{{- define "oa.knowledgeAgentPrompt" -}}
{{- $t := include "oa.knowledgeTools" . | fromJsonArray -}}
{{- $p := .Values.knowledge.agentPrompt | replace "{search}" (index $t 0) | replace "{get}" (index $t 1) -}}
{{- if .Values.knowledge.kb.graph.enabled }}{{ $p = printf "%s\n%s" (trim $p) (.Values.knowledge.kb.graph.agentPrompt | replace "{graph_search}" (index $t 3) | replace "{graph_entity}" (index $t 4) | replace "{graph_paths}" (index $t 5) | replace "{get}" (index $t 1) | trim) }}{{ end -}}
{{- $p -}}
{{- end -}}

{{/* "true" when at least one agent has long-term memory enabled (and kagent is deployed). */}}
{{- define "oa.memoryEnabled" -}}
{{- $on := false -}}
{{- if .Values.kagent.enabled }}{{ range .Values.agents }}{{ if and .memory .memory.enabled }}{{ $on = true }}{{ end }}{{ end }}{{ end -}}
{{- if $on -}}true{{- end -}}
{{- end -}}

{{/* Gateway base URL for the embedding ModelConfig: same gateway, different (alias) Service name, so a different origin. */}}
{{- define "oa.memoryBaseUrl" -}}
http://{{ .Values.memory.gatewayAlias }}.{{ .Values.gateway.namespace }}.svc.cluster.local{{ if ne (int .Values.gateway.port) 80 }}:{{ .Values.gateway.port }}{{ end }}/v1
{{- end -}}

{{/* JSON list: the distinct Secrets named by channels.connections[], sorted. */}}
{{- define "oa.channelSecrets" -}}
{{- $s := list -}}{{- range .Values.channels.connections }}{{ $s = append $s .existingSecret }}{{ end -}}
{{- if include "oa.a2aGateOn" . }}{{ range .Values.channels.bindings }}{{ $s = append $s (printf "a2a-key-%s" .name) }}{{ end }}{{ end -}}
{{- $s | uniq | sortAlpha | toJson -}}
{{- end -}}

{{/* Fails the render when .cron is not a 5-field cron expression (minute hour day-of-month month day-of-week) with in-range
numbers, month/weekday names, ranges, steps and lists. The API server validates again when the CronJob is applied. */}}
{{- define "oa.validateCron" -}}
{{- $fields := regexSplit "\\s+" (trim .cron) -1 -}}
{{- if ne (len $fields) 5 -}}{{ fail (printf "schedule %q: schedule %q must have 5 fields (minute hour day-of-month month day-of-week)" .name .cron) }}{{- end -}}
{{- $min := list 0 0 1 1 0 -}}
{{- $max := list 59 23 31 12 7 -}}
{{- $names := list "" "" "" "jan feb mar apr may jun jul aug sep oct nov dec" "sun mon tue wed thu fri sat" -}}
{{- range $i, $f := $fields -}}
{{- range $e := splitList "," $f -}}
{{- if not (regexMatch "^(\\*|([0-9]+|[A-Za-z]{3})(-([0-9]+|[A-Za-z]{3}))?)(/[1-9][0-9]*)?$" $e) -}}{{ fail (printf "schedule %q: field %d (%q) of schedule %q is not valid cron syntax" $.name (add $i 1) $e $.cron) }}{{- end -}}
{{- $base := regexReplaceAll "/.*$" $e "" -}}
{{- range $n := regexFindAll "[0-9]+" $base -1 -}}
{{- if or (lt (int $n) (index $min $i)) (gt (int $n) (index $max $i)) -}}{{ fail (printf "schedule %q: %s in schedule %q is out of range %d-%d for field %d" $.name $n $.cron (index $min $i) (index $max $i) (add $i 1)) }}{{- end -}}
{{- end -}}
{{- range $w := regexFindAll "[A-Za-z]+" $base -1 -}}
{{- if not (has (lower $w) (splitList " " (index $names $i))) -}}{{ fail (printf "schedule %q: %q is not valid in field %d of schedule %q" $.name $w (add $i 1) $.cron) }}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Tool names of the notify service as the vMCP exposes them: <prefix of the entry><service tool>. JSON list. */}}
{{- define "oa.notifyTools" -}}
{{- $pfx := replace "{workload}" .Values.notify.mcp.entryName .Values.mcp.virtual.prefixFormat -}}
{{- list (printf "%snotify_send" $pfx) (printf "%snotify_list_destinations" $pfx) | toJson -}}
{{- end -}}

{{- define "oa.notifyAgentPrompt" -}}
{{- $t := include "oa.notifyTools" . | fromJsonArray -}}
{{- .Values.notify.agentPrompt | replace "{send}" (index $t 0) | replace "{list}" (index $t 1) -}}
{{- end -}}

{{/* "true" when observability is switched on (the block may be absent: `observability: null`). */}}
{{- define "oa.obsOn" -}}
{{- $o := .Values.observability | default dict -}}
{{- if $o.enabled -}}true{{- end -}}
{{- end -}}

{{/* OTLP endpoint every component exports to: observability.otlp.endpoint, else the bundled Jaeger; fails when neither exists. */}}
{{- define "oa.obsEndpoint" -}}
{{- $o := .Values.observability -}}
{{- if $o.otlp.endpoint -}}{{ $o.otlp.endpoint }}
{{- else if $o.bundled.enabled -}}http://jaeger.{{ $o.namespace }}.svc.cluster.local:{{ if eq $o.otlp.protocol "grpc" }}4317{{ else }}4318{{ end }}
{{- else -}}{{ fail "observability.enabled needs observability.otlp.endpoint or observability.bundled.enabled" }}
{{- end -}}
{{- end -}}

{{/* Checked once per render when observability is on. */}}
{{- define "oa.obsValidate" -}}
{{- $o := .Values.observability -}}
{{- if not (has $o.otlp.protocol (list "http/protobuf" "grpc")) }}{{ fail (printf "observability.otlp.protocol must be http/protobuf or grpc, got %q" $o.otlp.protocol) }}{{ end -}}
{{- $r := float64 $o.tracing.samplingRate -}}
{{- if or (lt $r 0.0) (gt $r 1.0) }}{{ fail (printf "observability.tracing.samplingRate must be between 0 and 1, got %v" $o.tracing.samplingRate) }}{{ end -}}
{{- $_ := include "oa.obsEndpoint" . -}}
{{- end -}}

{{/* The metrics port of our own services ("knowledge" for the kb, "notify"), checked. Prints nothing while observability is off. Call: include "oa.obsMetricsPort" (dict "root" . "svc" "knowledge") */}}
{{- define "oa.obsMetricsPort" -}}
{{- if include "oa.obsOn" .root -}}
{{- $m := dict -}}
{{- if eq .svc "knowledge" }}{{ $m = .root.Values.knowledge.kb.metrics }}{{ else }}{{ $m = .root.Values.notify.metrics }}{{ end -}}
{{- $key := ternary "knowledge.kb.metrics.port" "notify.metrics.port" (eq .svc "knowledge") -}}
{{- if not (regexMatch "^[0-9]+$" (toString $m.port)) }}{{ fail (printf "%s must be a port number, got %v" $key $m.port) }}{{ end -}}
{{- $p := int $m.port -}}
{{- if or (lt $p 1024) (gt $p 65535) (eq $p 8080) }}{{ fail (printf "%s must be 1024..65535 and different from the API port 8080, got %d" $key $p) }}{{ end -}}
{{- $p -}}
{{- end -}}
{{- end -}}

{{/* Propagators: tracecontext only (no baggage) unless observability.baggage. */}}
{{- define "oa.obsPropagators" -}}
{{- if .Values.observability.baggage -}}tracecontext,baggage{{- else -}}tracecontext{{- end -}}
{{- end -}}

{{/* The single content switch. Prints "true" or "false". */}}
{{- define "oa.obsCapture" -}}
{{- if .Values.observability.capture.content -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/* {a: b, c: d} -> "a=b,c=d" (label selector string, keys sorted). */}}
{{- define "oa.selectorString" -}}
{{- $l := list -}}{{- range $k := keys . | sortAlpha }}{{ $l = append $l (printf "%s=%s" $k (get $ $k)) }}{{ end -}}
{{- join "," $l -}}
{{- end -}}

{{/* Jaeger v2 configuration of the bundled profile (used for the ConfigMap AND for the pod template hash, so a changed drop list restarts Jaeger). */}}
{{- define "oa.jaegerConfig" -}}
{{- $o := .Values.observability -}}
{{- $b := $o.bundled -}}
# Jaeger v2: OTLP in, in-memory store (capped), query UI. Nothing is persisted; a restart loses all traces.
service:
  extensions: [jaeger_storage, jaeger_query, healthcheckv2]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, {{ if not $o.capture.content }}attributes/drop-content, {{ end }}batch]
      exporters: [jaeger_storage_exporter]
  telemetry:
    resource: {service.name: jaeger}
    metrics: {level: none}
    logs: {level: info}
extensions:
  healthcheckv2:
    use_v2: true
    http: {endpoint: "0.0.0.0:13133"}
  jaeger_query:
    storage: {traces: memstore}
  jaeger_storage:
    backends:
      memstore:
        memory: {max_traces: {{ $b.traces.maxTraces }}}
receivers:
  otlp:
    protocols:
      grpc: {endpoint: "0.0.0.0:4317"}
      http: {endpoint: "0.0.0.0:4318"}
processors:
  memory_limiter: {check_interval: 1s, limit_mib: 150, spike_limit_mib: 30}
  batch: {}
  {{- if not $o.capture.content }}
  # The Go ADK writes tool arguments and results into spans whatever the capture setting (google/adk-go#1634), the vMCP writes
  # mcp.tool.arguments, and
  # the GenAI content keys exist only when capture is on, and user.id carries the caller's id. They are deleted here, before storage. Only
  # observability.capture.content=true removes this processor.
  attributes/drop-content:
    actions:
      - {key: gcp.vertex.agent.tool_call_args, action: delete}
      - {key: gcp.vertex.agent.tool_response, action: delete}
      - {key: gcp.vertex.agent.llm_request, action: delete}
      - {key: gcp.vertex.agent.llm_response, action: delete}
      - {key: gen_ai.input.messages, action: delete}
      - {key: gen_ai.output.messages, action: delete}
      - {key: gen_ai.system_instructions, action: delete}
      - {key: gen_ai.tool.call.arguments, action: delete}
      - {key: gen_ai.tool.call.result, action: delete}
      - {key: mcp.tool.arguments, action: delete}
      # user.id is the caller id the platform forwards (for the Telegram bridge: telegram:<chat id>), personal data that is
      # not needed to follow a request: the conversation id is the key. Kept only with capture.content=true.
      - {key: user.id, action: delete}
      - {key: enduser.id, action: delete}
      {{- range $o.bundled.traces.extraDropAttributes }}
      - {key: {{ . | quote }}, action: delete}
      {{- end }}
  {{- end }}
exporters:
  jaeger_storage_exporter: {trace_storage: memstore}
{{- end -}}

{{- define "oa.a2aGateOn" -}}
{{- $g := .Values.governance | default dict -}}
{{- $a := $g.a2a | default dict -}}
{{- if $a.enabled -}}true{{- end -}}
{{- end -}}

{{- define "oa.a2aGateUrl" -}}
http://a2a-gate.{{ .Values.governance.a2a.namespace }}.svc.cluster.local:8080
{{- end -}}

{{- /* The caller rules of the A2A gate, as JSON. Derived from the bridge, the schedules and the Kourier bindings, plus
       governance.a2a.callers. Each caller lists the JSON-RPC methods it may use: what the chart's own callers really send
       (the bridge and the schedules: SendMessage; Kourier: send, stream, read, subscribe, cancel). It holds no secret.
       Used for the rules ConfigMap and its checksum. */ -}}
{{- define "oa.a2aRules" -}}
{{- $a := .Values.governance.a2a -}}
{{- $kns := .Values.kagent.namespace -}}
{{- $agents := list -}}{{- range .Values.agents }}{{ $agents = append $agents .name }}{{ end -}}
{{- $callers := list -}}
{{- if .Values.bridge.enabled -}}
{{- $b := .Values.bridge -}}
{{- $bridge := dict "name" "bridge" "serviceAccount" (dict "namespace" $b.namespace "name" "telegram-bridge") "agents" (list (printf "%s/%s" $b.agentNamespace $b.agent)) "userId" (dict "prefix" (default "telegram:" $b.userIdPrefix)) "methods" (list "SendMessage") -}}
{{- if $b.memoryCommands }}{{ $_ := set $bridge "memory" true }}{{ end -}}
{{- $callers = append $callers $bridge -}}
{{- end -}}
{{- range .Values.schedules -}}
{{- $callers = append $callers (dict "name" (printf "schedule-%s" .name) "serviceAccount" (dict "namespace" $.Values.scheduling.namespace "name" (printf "schedule-%s" .name)) "agents" (list (printf "%s/%s" $kns .agent)) "userId" (dict "exact" (default (printf "schedule:%s" .name) .userId)) "methods" (list "SendMessage")) -}}
{{- end -}}
{{- if .Values.channels.kourier.enabled -}}
{{- range .Values.channels.bindings -}}
{{- $callers = append $callers (dict "name" (printf "kourier-%s" .name) "key" true "agents" (list (printf "%s/%s" $kns .agent)) "userId" (dict "fixed" (default (printf "kourier:%s" .name) .userId)) "methods" (list "SendMessage" "SendStreamingMessage" "GetTask" "SubscribeToTask" "CancelTask")) -}}
{{- end -}}
{{- end -}}
{{- $seen := list -}}
{{- range $i, $c := $a.callers -}}
{{- if not $c.name }}{{ fail (printf "governance.a2a.callers[%d]: name is required" $i) }}{{ end -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$" (toString $c.name)) }}{{ fail (printf "governance.a2a.callers[%d]: name %q must be letters, digits, '.', '_' or '-' (at most 63)" $i (toString $c.name)) }}{{ end -}}
{{- if or (eq $c.name "bridge") (hasPrefix "schedule-" $c.name) (hasPrefix "kourier-" $c.name) }}{{ fail (printf "governance.a2a.callers[%d]: name %q is reserved for the callers the chart derives (bridge, schedule-*, kourier-*)" $i $c.name) }}{{ end -}}
{{- if has $c.name $seen }}{{ fail (printf "governance.a2a.callers: name %q is used twice" $c.name) }}{{ end -}}
{{- $seen = append $seen $c.name -}}
{{- if not (and $c.serviceAccount $c.serviceAccount.namespace $c.serviceAccount.name) }}{{ fail (printf "governance.a2a.callers[%s]: serviceAccount needs namespace and name" $c.name) }}{{ end -}}
{{- if not $c.agents }}{{ fail (printf "governance.a2a.callers[%s]: agents must list at least one agent" $c.name) }}{{ end -}}
{{- $full := list -}}
{{- range $c.agents -}}
{{- if contains "/" (toString .) -}}{{- $full = append $full (toString .) -}}
{{- else -}}
{{- if not (has . $agents) }}{{ fail (printf "governance.a2a.callers[%s]: agent %q is not in agents[] (have: %s)" $c.name (toString .) (join ", " $agents)) }}{{ end -}}
{{- $full = append $full (printf "%s/%s" $kns .) -}}
{{- end -}}
{{- end -}}
{{- $u := $c.userId | default dict -}}
{{- $set := 0 -}}{{- range $k := list "exact" "prefix" "fixed" }}{{ if get $u $k }}{{ $set = add $set 1 }}{{ end }}{{ end -}}
{{- if ne (int $set) 1 }}{{ fail (printf "governance.a2a.callers[%s]: userId needs exactly one of exact, prefix and fixed" $c.name) }}{{ end -}}
{{- $methods := list -}}
{{- if hasKey $c "methods" -}}
{{- if or (not (kindIs "slice" $c.methods)) (not $c.methods) }}{{ fail (printf "governance.a2a.callers[%s]: methods must be a non-empty list (leave it out for the gate's default: SendMessage, SendStreamingMessage)" $c.name) }}{{ end -}}
{{- range $c.methods -}}
{{- if not (regexMatch "^[A-Za-z][A-Za-z0-9_./:-]{0,63}$" (toString .)) }}{{ fail (printf "governance.a2a.callers[%s]: method %q is not a valid method name" $c.name (toString .)) }}{{ end -}}
{{- if has (toString .) $methods }}{{ fail (printf "governance.a2a.callers[%s]: method %q is listed twice" $c.name (toString .)) }}{{ end -}}
{{- $methods = append $methods (toString .) -}}
{{- end -}}
{{- end -}}
{{- $entry := dict "name" $c.name "serviceAccount" (dict "namespace" $c.serviceAccount.namespace "name" $c.serviceAccount.name) "agents" $full "userId" (pick $u "exact" "prefix" "fixed") -}}
{{- if $methods }}{{ $_ := set $entry "methods" $methods }}{{ end -}}
{{- if hasKey $c "memory" -}}
{{- if not (kindIs "bool" $c.memory) }}{{ fail (printf "governance.a2a.callers[%s]: memory must be true or false" $c.name) }}{{ end -}}
{{- if $c.memory }}{{ $_ := set $entry "memory" true }}{{ end -}}
{{- end -}}
{{- $callers = append $callers $entry -}}
{{- end -}}
{{- /* a caller of the controller's port that was admitted by networkPolicy.extraA2ACallers must have a rule, or it would be cut off silently */ -}}
{{- range $x := .Values.networkPolicy.extraA2ACallers -}}
{{- $has := false -}}
{{- range $a.callers }}{{ if eq .serviceAccount.namespace $x.namespace }}{{ $has = true }}{{ end }}{{ end -}}
{{- if not $has }}{{ fail (printf "networkPolicy.extraA2ACallers: namespace %q has no matching entry in governance.a2a.callers (serviceAccount.namespace). With the A2A gate on every caller needs a rule." $x.namespace) }}{{ end -}}
{{- end -}}
{{- toJson (dict "callers" $callers) -}}
{{- end -}}

{{/* bridge.memoryCommands (ADR 0006, round 3): fails the render when the switch is not usable. Prints nothing.
Needs the A2A gate (the only way to the MemoryService), the bridge, and the bridge's agent in agents[] with memory on. */}}
{{- define "oa.bridgeMemoryCheck" -}}
{{- $b := .Values.bridge -}}
{{- if not (kindIs "bool" $b.memoryCommands) }}{{ fail "bridge.memoryCommands must be true or false" }}{{ end -}}
{{- if $b.memoryCommands -}}
{{- if not $b.enabled }}{{ fail "bridge.memoryCommands needs bridge.enabled=true" }}{{ end -}}
{{- if not (include "oa.a2aGateOn" .) }}{{ fail "bridge.memoryCommands needs governance.a2a.enabled=true: the gate is the only way to the memory service, and it decides who may list or delete" }}{{ end -}}
{{- $found := false -}}{{- $mem := false -}}
{{- if eq $b.agentNamespace .Values.kagent.namespace }}{{ range .Values.agents }}{{ if eq .name $b.agent }}{{ $found = true }}{{ if and .memory .memory.enabled }}{{ $mem = true }}{{ end }}{{ end }}{{ end }}{{ end -}}
{{- if not $found }}{{ fail (printf "bridge.memoryCommands needs bridge.agent %q to be in agents[] in the namespace %q" $b.agent .Values.kagent.namespace) }}{{ end -}}
{{- if not $mem }}{{ fail (printf "bridge.memoryCommands needs memory.enabled on the agent %q (agents[].memory.enabled): without memory there is nothing to list or forget" $b.agent) }}{{ end -}}
{{- end -}}
{{- end -}}

{{/* ---- Tool profiles (ADR 0006, round 2): mcp.profiles ------------------------------------------------------ */}}

{{/* JSON list of the backends (workloads) a profile may name: mcp.servers, plus the knowledge and notify MCPServerEntry when enabled. */}}
{{- define "oa.profileWorkloads" -}}
{{- $w := list -}}
{{- range .Values.mcp.servers }}{{ $w = append $w .name }}{{ end -}}
{{- if .Values.knowledge.enabled }}{{ $w = append $w .Values.knowledge.mcp.entryName }}{{ end -}}
{{- if .Values.notify.enabled }}{{ $w = append $w .Values.notify.mcp.entryName }}{{ end -}}
{{- if include "oa.diagOn" . }}{{ $w = append $w "cluster-read" }}{{ end -}}
{{- $w | toJson -}}
{{- end -}}

{{/* Names of the tools a profile advertises, as the agent sees them (prefixFormat applied), plus execute_tool_script with code mode. JSON list.
Argument: dict "root" <top-level context> "profile" <one mcp.profiles entry>. */}}
{{- define "oa.profileToolNames" -}}
{{- $root := .root -}}
{{- $names := list -}}
{{- range $w := (keys .profile.tools | sortAlpha) -}}
{{- $pfx := replace "{workload}" (include "oa.diagWorkload" (dict "root" $root "profile" $.profile "w" $w)) $root.Values.mcp.virtual.prefixFormat -}}
{{- range $t := (index $.profile.tools $w) }}{{ $names = append $names (printf "%s%s" $pfx $t) }}{{ end -}}
{{- end -}}
{{- if .profile.codeMode }}{{ $names = append $names "execute_tool_script" }}{{ end -}}
{{- $names | toJson -}}
{{- end -}}

{{/* Fails the render when mcp.profiles is malformed. Prints nothing. Safe to include from several templates. */}}
{{- define "oa.profilesCheck" -}}
{{- $m := .Values.mcp -}}
{{- if $m.profiles -}}
{{- if not (kindIs "slice" $m.profiles) }}{{ fail "mcp.profiles must be a list" }}{{ end -}}
{{- if ne $m.virtual.incomingAuth.type "oidc" }}{{ fail "mcp.profiles needs mcp.virtual.incomingAuth.type oidc: a profile is told apart by its own audience, and an anonymous vMCP has none" }}{{ end -}}
{{- $workloads := include "oa.profileWorkloads" . | fromJsonArray -}}
{{- $seen := list -}}
{{- $auds := list $m.virtual.incomingAuth.oidc.audience -}}
{{- range $p := $m.profiles -}}
{{- if not (kindIs "map" $p) }}{{ fail "every mcp.profiles entry must be a map with name and tools" }}{{ end -}}
{{- if not (and (kindIs "string" $p.name) (regexMatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$" $p.name) (le (len $p.name) 20)) }}{{ fail (printf "profile name %q is not valid: use lower case letters, digits and single dashes, starting with a letter, at most 20 characters" (toString $p.name)) }}{{ end -}}
{{- if has $p.name $seen }}{{ fail (printf "duplicate profile name %q in mcp.profiles" $p.name) }}{{ end -}}
{{- $seen = append $seen $p.name -}}
{{- $aud := printf "%s-%s" $m.virtual.incomingAuth.oidc.audience $p.name -}}
{{- if has $aud $auds }}{{ fail (printf "profile %q would use the audience %q, which another vMCP already has: audiences must be unique" $p.name $aud) }}{{ end -}}
{{- $auds = append $auds $aud -}}
{{- if and (hasKey $p "codeMode") (not (kindIs "bool" $p.codeMode)) }}{{ fail (printf "profile %q: codeMode must be true or false" $p.name) }}{{ end -}}
{{- if or (not (kindIs "map" $p.tools)) (not $p.tools) }}{{ fail (printf "profile %q needs a non-empty tools map (backend name: list of tool names)" $p.name) }}{{ end -}}
{{- range $w, $l := $p.tools -}}
{{- if not (has $w $workloads) }}{{ fail (printf "profile %q: workload %q is not a backend of the tool group (%s)" $p.name $w (join ", " $workloads)) }}{{ end -}}
{{- if or (not (kindIs "slice" $l)) (not $l) }}{{ fail (printf "profile %q: workload %q needs a non-empty tools list" $p.name $w) }}{{ end -}}
{{- range $t := $l }}{{ if not (and (kindIs "string" $t) (regexMatch "^[A-Za-z0-9_.-]+$" $t)) }}{{ fail (printf "profile %q: workload %q lists a tool name that is not valid: %v" $p.name $w $t) }}{{ end }}{{ end -}}
{{- if ne (len $l) (len (uniq $l)) }}{{ fail (printf "profile %q: workload %q lists a tool twice" $p.name $w) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* The agent's tool profile as JSON ({} when it has none). Fails for a profile that does not exist. Argument: dict "root" <top> "agent" <agent>. */}}
{{- define "oa.agentProfile" -}}
{{- $a := .agent -}}
{{- $found := dict -}}
{{- if $a.toolProfile -}}
{{- if not (kindIs "string" $a.toolProfile) }}{{ fail (printf "agent %q: toolProfile must be a profile name (a string)" $a.name) }}{{ end -}}
{{- if not .root.Values.mcp.enabled }}{{ fail (printf "agent %q uses toolProfile %q but mcp.enabled is false" $a.name $a.toolProfile) }}{{ end -}}
{{- if not .root.Values.kagent.remoteMCPServer.enabled }}{{ fail (printf "agent %q uses toolProfile %q but kagent.remoteMCPServer.enabled is false: a profile is reached through its own RemoteMCPServer" $a.name $a.toolProfile) }}{{ end -}}
{{- $names := list -}}
{{- range $p := .root.Values.mcp.profiles }}{{ $names = append $names $p.name }}{{ if eq $p.name $a.toolProfile }}{{ $found = $p }}{{ end }}{{ end -}}
{{- if not $found }}{{ fail (printf "agent %q: toolProfile %q is not defined in mcp.profiles (defined: %s)" $a.name $a.toolProfile (join ", " $names)) }}{{ end -}}
{{- end -}}
{{- $found | toJson -}}
{{- end -}}

{{/* Fails the render when agents[].egress is malformed; returns the allow list as JSON ([] when there is none).
Argument: dict "root" <top> "agent" <agent>. The entries follow kagent's EgressPolicy origin pattern: scheme, lower case DNS name
(a wildcard replaces one leftmost label), optional port, no path. Names inside the MCP tools namespace are refused: they would
reach a vMCP or an unauthenticated backend proxy around the profile. */}}
{{- define "oa.agentEgress" -}}
{{- $a := .agent -}}
{{- $m := .root.Values.mcp -}}
{{- $allow := list -}}
{{- if $a.egress -}}
{{- if not (kindIs "map" $a.egress) }}{{ fail (printf "agent %q: egress must be a map with an allow list" $a.name) }}{{ end -}}
{{- if hasKey $a.egress "allow" -}}
{{- if not (kindIs "slice" $a.egress.allow) }}{{ fail (printf "agent %q: egress.allow must be a list of origins" $a.name) }}{{ end -}}
{{- if gt (len $a.egress.allow) 64 }}{{ fail (printf "agent %q: egress.allow has %d origins; at most 64 are allowed" $a.name (len $a.egress.allow)) }}{{ end -}}
{{- range $o := $a.egress.allow -}}
{{- if not (and (kindIs "string" $o) (regexMatch "^https?://(\\*\\.([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.)+|([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\\.)*)[a-z]([-a-z0-9]{0,61}[a-z0-9])?(:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5]))?$" $o) (le (len $o) 270)) }}{{ fail (printf "agent %q: egress.allow entry %v is not an origin: use https://host[:port] or http://host[:port], a lower case DNS name (a wildcard replaces exactly one leftmost label, as in https://*.example.com), no path, no query, no address" $a.name $o) }}{{ end -}}
{{- if has $o $allow }}{{ fail (printf "agent %q: egress.allow lists %q twice" $a.name $o) }}{{ end -}}
{{- $host := regexReplaceAll "^https?://([^:/]+).*$" $o "${1}" | trimPrefix "*." -}}
{{- $ns := $m.namespace -}}
{{- if or (eq $host $ns) (eq $host (printf "%s.svc" $ns)) (eq $host (printf "%s.svc.cluster.local" $ns)) (hasSuffix (printf ".%s" $ns) $host) (hasSuffix (printf ".%s.svc" $ns) $host) (hasSuffix (printf ".%s.svc.cluster.local" $ns) $host) }}{{ fail (printf "agent %q: egress.allow entry %q is inside the tools namespace %q: that would reach a vMCP or a tool server around the profile" $a.name $o $ns) }}{{ end -}}
{{- $allow = append $allow $o -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $allow | toJson -}}
{{- end -}}

{{/* ---- Control plane (ADR 0007, slice 1): controlPlane ------------------------------------------------------- */}}

{{/* "true" when the control plane is switched on (the block may be absent: `controlPlane: null`). */}}
{{- define "oa.cpOn" -}}
{{- $c := .Values.controlPlane | default dict -}}
{{- if $c.enabled -}}true{{- end -}}
{{- end -}}

{{/* "true" when container agents (bring your own agent, ADR 0015) are switched on. Needs the control plane. */}}
{{- define "oa.caOn" -}}
{{- $c := .Values.controlPlane | default dict -}}
{{- $ca := $c.containerAgents | default dict -}}
{{- if and $c.enabled $ca.enabled -}}true{{- end -}}
{{- end -}}

{{/* The workload namespace of container agents. */}}
{{- define "oa.caNamespace" -}}
{{- .Values.controlPlane.containerAgents.namespace -}}
{{- end -}}

{{/* Tools for container agents (ADR 0019): the profiles opened to them, as a JSON list of {name, server, audience, url, port}. [] unless container
agents are on and controlPlane.containerAgents.toolProfiles lists a profile. Fails the render for a malformed list. Safe to include from several templates. */}}
{{- define "oa.caToolProfiles" -}}
{{- $out := list -}}
{{- if include "oa.caOn" . -}}
{{- $ca := .Values.controlPlane.containerAgents -}}
{{- $l := $ca.toolProfiles | default list -}}
{{- if not (kindIs "slice" $l) }}{{ fail "controlPlane.containerAgents.toolProfiles must be a list of mcp.profiles names" }}{{ end -}}
{{- if $l -}}
{{- if not .Values.mcp.enabled }}{{ fail "controlPlane.containerAgents.toolProfiles needs mcp.enabled=true: the profiles live on the tool gateway" }}{{ end -}}
{{- $_ := include "oa.profilesCheck" . -}}
{{- $m := .Values.mcp -}}
{{- $sat := $ca.serviceAccountTokens | default dict -}}
{{- range $f := list "issuer" "jwksUrl" -}}
{{- if not (regexMatch "^https://[a-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$" (toString (get $sat $f))) }}{{ fail (printf "controlPlane.containerAgents.serviceAccountTokens.%s must be an https URL without user, query or fragment" $f) }}{{ end -}}
{{- end -}}
{{- if ne (len $l) (len (uniq $l)) }}{{ fail "controlPlane.containerAgents.toolProfiles lists a profile twice" }}{{ end -}}
{{- $names := list -}}{{- range $p := ($m.profiles | default list) }}{{ $names = append $names $p.name }}{{ end -}}
{{- range $x := $l -}}
{{- if not (and (kindIs "string" $x) (has $x $names)) }}{{ fail (printf "controlPlane.containerAgents.toolProfiles lists %q, which is not in mcp.profiles (%s)" (toString $x) (join ", " $names)) }}{{ end -}}
{{- $srv := printf "%s-%s-workload" $m.virtual.name $x -}}
{{- range $n := $names }}{{ if eq (printf "%s-%s" $m.virtual.name $n) $srv }}{{ fail (printf "the workload tool server %q of profile %q collides with the server of profile %q: rename that profile" $srv $x $n) }}{{ end }}{{ end -}}
{{- $out = append $out (dict "name" $x "server" $srv "audience" (printf "%s-%s-workload" $m.virtual.incomingAuth.oidc.audience $x) "url" (printf "http://vmcp-%s.%s.svc.cluster.local:%d/mcp" $srv $m.namespace (int $m.virtual.port)) "port" (int $m.virtual.port)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/* Namespace of the controller: controlPlane.namespace, else the release namespace. */}}
{{- define "oa.cpNamespace" -}}
{{- default .Release.Namespace .Values.controlPlane.namespace -}}
{{- end -}}

{{/* The platform catalog the controller reads (services/control-plane/README.md, "The catalog"), as pretty JSON. It is derived from the
SAME values and helpers that render the chart agents (kagent.yaml), so the two cannot drift. What only one adapter needs is in that
adapter's own section (runtime.kagent, tools.toolhive). It holds no secret: names, URLs, tool names, prompts and digest-pinned skill references only. Fails the render for a skill that is not digest-pinned (the controller refuses the file). */}}
{{- define "oa.cpCatalog" -}}
{{- $k := .Values.kagent -}}
{{- $models := list -}}{{- range .Values.gateway.models }}{{ $models = append $models .name }}{{ end -}}
{{- $profiles := list -}}
{{- if and .Values.mcp.enabled $k.remoteMCPServer.enabled -}}
{{- $_ := include "oa.profilesCheck" . -}}
{{- $wl := dict -}}{{- range $w := (include "oa.caToolProfiles" . | fromJsonArray) }}{{ $_ := set $wl $w.name $w }}{{ end -}}
{{- range $p := (.Values.mcp.profiles | default list) -}}
{{- $e := dict "name" $p.name "toolServer" (printf "%s-%s" $k.remoteMCPServer.name $p.name) "codeMode" (eq (toString (default false $p.codeMode)) "true") "tools" (include "oa.profileToolNames" (dict "root" $ "profile" $p) | fromJsonArray) -}}
{{- with (get $wl $p.name) }}{{ $_ := set $e "workload" (dict "url" .url "audience" .audience "namespace" $.Values.mcp.namespace "podSelector" (dict "app" "virtualmcpserver" "toolhive-name" .server) "port" (int .port)) }}{{ end -}}
{{- $profiles = append $profiles $e -}}
{{- end -}}
{{- end -}}
{{- $knOn := and .Values.knowledge.enabled .Values.mcp.enabled -}}
{{- $knowledge := dict "available" false "tools" (list) "prompt" "" -}}
{{- if $knOn }}{{ $knowledge = dict "available" true "tools" (include "oa.knowledgeTools" . | fromJsonArray) "prompt" (include "oa.knowledgeAgentPrompt" . | trim) }}{{ end -}}
{{- $ntOn := and .Values.notify.enabled .Values.mcp.enabled -}}
{{- $notify := dict "available" false "tools" (list) "prompt" "" -}}
{{- if $ntOn }}{{ $notify = dict "available" true "tools" (include "oa.notifyTools" . | fromJsonArray) "prompt" (include "oa.notifyAgentPrompt" . | trim) }}{{ end -}}
{{- $memory := dict "available" (eq (include "oa.memoryEnabled" .) "true") "expiryEnabled" (ternary true false (and .Values.memory.expiry.enabled $k.enabled)) "defaultTtlDays" (int .Values.controlPlane.memoryDefaultTtlDays) "prompt" (trim .Values.memory.agentPrompt) -}}
{{- $skills := dict -}}
{{- range $n, $s := (.Values.skills | default dict) -}}
{{- if not (regexMatch "@sha256:[0-9a-f]{64}$" (toString $s.oci)) }}{{ fail (printf "skill %q must be a digest-pinned OCI ref (...@sha256:<64 hex>), got %q: the control plane catalog lists every skill" $n (toString $s.oci)) }}{{ end -}}
{{- $_ := set $skills $n $s.oci -}}
{{- end -}}
{{- $env := list -}}
{{- if and (include "oa.obsOn" .) .Values.observability.baggage }}{{ $env = append $env (dict "name" "OTEL_PROPAGATORS" "value" (include "oa.obsPropagators" .)) }}{{ end -}}
{{- $gate := "" -}}
{{- if include "oa.a2aGateOn" . }}{{ $gate = include "oa.a2aGateUrl" . }}{{ end -}}
{{- $reserved := list -}}
{{- range .Values.agents }}{{ $reserved = append $reserved .name }}{{ end -}}
{{- /* Names a definition may not take IN THE AGENTS NAMESPACE (the controller applies this list to namespaces.agents only), because its objects would
collide with chart objects. A definition's gateway user is "<namespace>.<name>", which can never equal a chart user (a plain name), so the gateway users
are no longer a reason; the list still covers every user the installer registers (ModelConfig annotation openagentix.io/agent: every agent and "memory";
Deployment annotations openagentix.io/gateway-user*: "kb" and "kb-extract"), because those names belong to the platform's services; tests/run.sh derives
the users from the render and fails if one is missing. */ -}}
{{- $reserved = concat $reserved (list "kb" "kb-extract" "memory") -}}
{{- /* the base name of every virtualKeySecret override (<base>-virtual-key; a name without that ending counts whole), memory's key included */ -}}
{{- range .Values.agents }}{{ if .virtualKeySecret }}{{ $reserved = append $reserved (trimSuffix "-virtual-key" (toString .virtualKeySecret)) }}{{ end }}{{ end -}}
{{- if eq (include "oa.memoryEnabled" .) "true" }}{{ $reserved = append $reserved (trimSuffix "-virtual-key" (toString .Values.memory.modelConfig.virtualKeySecret)) }}{{ end -}}
{{- /* the suffix (after gateway-) of every ModelConfig name that is not gateway-<agent>: a definition of that name would get that ModelConfig */ -}}
{{- range .Values.agents }}{{ if and .modelConfigName (ne (toString .modelConfigName) (printf "gateway-%s" .name)) }}{{ $reserved = append $reserved (trimPrefix "gateway-" (toString .modelConfigName)) }}{{ end }}{{ end -}}
{{- if eq (include "oa.memoryEnabled" .) "true" }}{{ $reserved = append $reserved (trimPrefix "gateway-" (toString .Values.memory.modelConfig.name)) }}{{ end -}}
{{- $reserved = uniq $reserved -}}
{{- $cat := dict
    "adapters" (dict "runtime" "kagent" "modelGateway" "agentgateway" "tools" "toolhive")
    "namespaces" (dict "agents" $k.namespace "gateway" .Values.gateway.namespace "tools" .Values.mcp.namespace)
    "gatewayBaseUrl" (include "oa.gatewayBaseUrl" .)
    "models" $models
    "runtime" (dict "kagent" (dict "harnessImage" $k.harnessImage "workerPool" $k.workerPool "snapshotLocation" $k.snapshotLocation "harnessEnv" $env "memoryModelConfig" .Values.memory.modelConfig.name))
    "tools" (dict "toolhive" (dict "codeModeTool" "execute_tool_script" "profiles" $profiles))
    "knowledge" $knowledge
    "notify" $notify
    "memory" $memory
    "skills" $skills
    "gateUrl" $gate
    "reservedNames" $reserved -}}
{{- if include "oa.caOn" . -}}
{{- $ca := .Values.controlPlane.containerAgents -}}
{{- $gp := int $ca.gatewayPodPort | default (int .Values.gateway.port) -}}
{{- $_ := set $cat.adapters "runtimes" (dict "builtin" "kagent" "container" "container") -}}
{{- $_ := set $cat.runtime "container" (dict "namespace" $ca.namespace "runtimeClassName" $ca.runtimeClassName "imagePullPolicy" ($ca.imagePullPolicy | default "Always") "gatewayNamespace" .Values.gateway.namespace "gatewayPodSelector" (dict "gateway.networking.k8s.io/gateway-name" .Values.gateway.name) "gatewayPort" $gp "gateNamespace" .Values.governance.a2a.namespace "gatePodSelector" (dict "app" "a2a-gate") "dnsNamespace" "kube-system") -}}
{{- end -}}
{{- $cat | toPrettyJson -}}
{{- end -}}

{{/* The policy file the controller reads (README, "The policy"), as pretty JSON, from controlPlane.policy. */}}
{{- define "oa.cpPolicy" -}}
{{- $p := .Values.controlPlane.policy -}}
{{- $m := $p.memory | default dict -}}
{{- $e := $p.egress | default dict -}}
{{- $pol := dict
    "maxAgents" (int $p.maxAgents)
    "allowedModels" ($p.allowedModels | default list)
    "requireToolProfile" $p.requireToolProfile
    "allowedProfiles" ($p.allowedProfiles | default list)
    "allowKnowledge" $p.allowKnowledge
    "allowNotify" $p.allowNotify
    "allowedSkills" ($p.allowedSkills | default list)
    "memory" (dict "allowed" $m.allowed "maxTtlDays" (int $m.maxTtlDays) "requireExpiry" $m.requireExpiry)
    "egress" (dict "allowedOrigins" ($e.allowedOrigins | default list) "inClusterDestinations" ($e.inClusterDestinations | default list))
    "reservedNames" ($p.reservedNames | default list)
    "suspendAll" (default false $p.suspendAll) -}}
{{- if include "oa.caOn" . -}}
{{- $c := $p.runtimes.container -}}
{{- $_ := set $pol "allowedRuntimes" ($p.allowedRuntimes | default (list "builtin")) -}}
{{- $_ := set $pol "runtimes" (dict "container" (dict "images" ($c.images | default list) "defaultResources" $c.defaultResources "maxResources" $c.maxResources "maxAgents" (int $c.maxAgents))) -}}
{{- end -}}
{{- $pol | toPrettyJson -}}
{{- end -}}

{{/* Fails the render when controlPlane is malformed or the catalog makes it meaningless. Prints nothing. */}}
{{- define "oa.cpCheck" -}}
{{- $c := .Values.controlPlane -}}
{{- $p := $c.policy | default dict -}}
{{- $m := $p.memory | default dict -}}
{{- $e := $p.egress | default dict -}}
{{- if not .Values.kagent.enabled }}{{ fail "controlPlane.enabled needs kagent.enabled=true (it writes kagent objects)" }}{{ end -}}
{{- if not .Values.gateway.enabled }}{{ fail "controlPlane.enabled needs gateway.enabled=true (every built agent gets a key at the model gateway)" }}{{ end -}}
{{- if not .Values.gateway.models }}{{ fail "controlPlane.enabled needs at least one entry in gateway.models: the catalog would have no model to offer" }}{{ end -}}
{{- if eq .Values.kagent.namespace .Values.gateway.namespace }}{{ fail "controlPlane.enabled needs kagent.namespace and gateway.namespace to differ: the controller's Roles are one per namespace" }}{{ end -}}
{{- range $f := list "requireToolProfile" "allowKnowledge" "allowNotify" "suspendAll" }}
{{- if not (kindIs "bool" (get $p $f)) }}{{ fail (printf "controlPlane.policy.%s must be true or false" $f) }}{{ end }}
{{- end }}
{{- if not (kindIs "bool" $m.allowed) }}{{ fail "controlPlane.policy.memory.allowed must be true or false" }}{{ end }}
{{- if not (kindIs "bool" $m.requireExpiry) }}{{ fail "controlPlane.policy.memory.requireExpiry must be true or false" }}{{ end }}
{{- range $f := list (dict "n" "maxAgents" "v" $p.maxAgents "min" 0) (dict "n" "memory.maxTtlDays" "v" $m.maxTtlDays "min" 0) (dict "n" "memoryDefaultTtlDays (controlPlane level)" "v" $c.memoryDefaultTtlDays "min" 1) }}
{{- if not (or (kindIs "float64" $f.v) (kindIs "int64" $f.v) (kindIs "int" $f.v)) }}{{ fail (printf "controlPlane %s must be a whole number" $f.n) }}{{ end }}
{{- if lt (int $f.v) $f.min }}{{ fail (printf "controlPlane %s must be at least %d, got %v" $f.n $f.min $f.v) }}{{ end }}
{{- end }}
{{- if and $m.allowed (lt (int $m.maxTtlDays) 1) }}{{ fail "controlPlane.policy.memory.maxTtlDays must be at least 1 when memory.allowed is true" }}{{ end }}
{{- $models := list -}}{{- range .Values.gateway.models }}{{ $models = append $models .name }}{{ end -}}
{{- $profiles := list -}}{{- range $x := (.Values.mcp.profiles | default list) }}{{ $profiles = append $profiles $x.name }}{{ end -}}
{{- $skills := keys (.Values.skills | default dict) -}}
{{- range $f := list (dict "n" "allowedModels" "have" $models "what" "a gateway.models name") (dict "n" "allowedProfiles" "have" $profiles "what" "an mcp.profiles name") (dict "n" "allowedSkills" "have" $skills "what" "a name of the top-level skills") }}
{{- $l := (get $p $f.n) | default list }}
{{- if not (kindIs "slice" $l) }}{{ fail (printf "controlPlane.policy.%s must be a list (an empty list allows nothing, the single entry \"*\" allows everything)" $f.n) }}{{ end }}
{{- range $x := $l }}
{{- if not (and (kindIs "string" $x) (or (eq $x "*") (has $x $f.have))) }}{{ fail (printf "controlPlane.policy.%s lists %v, which is not %s (have: %s). A typo here would silently allow nothing" $f.n $x $f.what (join ", " $f.have)) }}{{ end }}
{{- end }}
{{- end }}
{{- if not (kindIs "slice" ($p.reservedNames | default list)) }}{{ fail "controlPlane.policy.reservedNames must be a list of names" }}{{ end }}
{{- $o := $e.allowedOrigins | default list -}}
{{- if not (kindIs "slice" $o) }}{{ fail "controlPlane.policy.egress.allowedOrigins must be a list of origins (an empty list allows no egress)" }}{{ end -}}
{{- $_ := include "oa.agentEgress" (dict "root" . "agent" (dict "name" "controlPlane.policy.egress.allowedOrigins" "egress" (dict "allow" $o))) -}}
{{- $ic := $e.inClusterDestinations | default list -}}
{{- if not (kindIs "slice" $ic) }}{{ fail "controlPlane.policy.egress.inClusterDestinations must be a list of host:port (an empty list allows no in-cluster destination)" }}{{ end -}}
{{- range $x := $ic }}
{{- if not (and (kindIs "string" $x) (regexMatch "^[a-z]([-a-z0-9]{0,61}[a-z0-9])?([.][a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)+:([1-9][0-9]{0,3}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$" $x)) }}{{ fail (printf "controlPlane.policy.egress.inClusterDestinations entry %v must be host:port with a namespace-qualified service name (service.namespace.svc:5000) and a numeric port: no scheme, no wildcard, no address" $x) }}{{ end }}
{{- $h := first (splitList ":" $x) }}
{{- if regexMatch "^[0-9.]+$" $h }}{{ fail (printf "controlPlane.policy.egress.inClusterDestinations entry %v is an address, not a service name" $x) }}{{ end }}
{{- /* never listable, whatever the operator wants: a name inside the tools, agents or gateway namespace or kube-system (it would reach a platform service around its own controls), or the Kubernetes API service. The controller refuses the same at start-up and the admission guard refuses them too. */ -}}
{{- range $what, $fn := (dict "tools" $.Values.mcp.namespace "agents" $.Values.kagent.namespace "gateway" $.Values.gateway.namespace "kube-system" "kube-system") }}
{{- if or (hasSuffix (printf ".%s" $fn) $h) (hasSuffix (printf ".%s.svc" $fn) $h) (hasSuffix (printf ".%s.svc.cluster.local" $fn) $h) }}{{ fail (printf "controlPlane.policy.egress.inClusterDestinations entry %v is inside the %s namespace %q: that would reach a platform service around its own controls and can never be listed" $x $what $fn) }}{{ end }}
{{- end }}
{{- if or (eq $h "kubernetes") (eq $h "kubernetes.default") (hasPrefix "kubernetes.default." $h) }}{{ fail (printf "controlPlane.policy.egress.inClusterDestinations entry %v is the Kubernetes API service and can never be listed" $x) }}{{ end }}
{{- end }}
{{- if ne (len $ic) (len (uniq $ic)) }}{{ fail "controlPlane.policy.egress.inClusterDestinations lists an entry twice" }}{{ end -}}
{{- if and $p.allowNotify (not (and .Values.notify.enabled .Values.mcp.enabled)) }}{{ fail "controlPlane.policy.allowNotify needs notify.enabled=true and mcp.enabled=true: the catalog has no notify tools, so every definition asking for notify would be refused" }}{{ end -}}
{{- if $m.allowed -}}
{{- if not (include "oa.memoryEnabled" .) }}{{ fail "controlPlane.policy.memory.allowed needs the memory stack: it is installed only when a chart agent has memory.enabled (agents[].memory.enabled), see README Memory. Without it every definition asking for memory would be refused" }}{{ end -}}
{{- if and $m.requireExpiry (not .Values.memory.expiry.enabled) }}{{ fail "controlPlane.policy.memory.allowed with requireExpiry needs memory.expiry.enabled=true: without the expiry job the time limit of a memory is not enforced. Enable the job or set requireExpiry=false on purpose" }}{{ end -}}
{{- end -}}
{{- $ca := $c.containerAgents | default dict -}}
{{- if $ca.enabled -}}
{{- if not .Values.governance.a2a.enabled }}{{ fail "controlPlane.containerAgents.enabled needs governance.a2a.enabled=true: clients reach a container agent only through the A2A gate" }}{{ end -}}
{{- if not (regexMatch "^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$" (toString $ca.namespace)) }}{{ fail "controlPlane.containerAgents.namespace must be a namespace name" }}{{ end -}}
{{- range $what, $n := (dict "agents" .Values.kagent.namespace "gateway" .Values.gateway.namespace "tools" .Values.mcp.namespace "gate" .Values.governance.a2a.namespace "controller" (include "oa.cpNamespace" .) "kube-system" "kube-system" "release" .Release.Namespace) }}
{{- if eq $n $ca.namespace }}{{ fail (printf "controlPlane.containerAgents.namespace %q is the %s namespace: foreign code needs a namespace of its own" $ca.namespace $what) }}{{ end }}
{{- end }}
{{- $ar := $p.allowedRuntimes | default list -}}
{{- if not (kindIs "slice" $ar) }}{{ fail "controlPlane.policy.allowedRuntimes must be a list (builtin, container)" }}{{ end -}}
{{- range $x := $ar }}{{ if not (has $x (list "builtin" "container")) }}{{ fail (printf "controlPlane.policy.allowedRuntimes lists %v, which is not a runtime type (builtin, container)" $x) }}{{ end }}{{ end -}}
{{- range $x := (($p.runtimes | default dict).container | default dict).images | default list }}
{{- if not (regexMatch "^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+/$" (toString $x)) }}{{ fail (printf "controlPlane.policy.runtimes.container.images entry %v must be a registry prefix with a path and a trailing slash, for example ghcr.io/acme/agents/" $x) }}{{ end }}
{{- end }}
{{- end -}}
{{- if not (kindIs "slice" ($c.apiServerCIDRs | default list)) }}{{ fail "controlPlane.apiServerCIDRs must be a list of CIDRs" }}{{ end -}}
{{- range $x := ($c.apiServerCIDRs | default list) }}
{{- if not (and (kindIs "string" $x) (or (regexMatch "^([0-9]{1,3}[.]){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$" $x) (regexMatch "^[0-9a-fA-F:]*:[0-9a-fA-F:.]*/([0-9]{1,2}|1[01][0-9]|12[0-8])$" $x))) }}{{ fail (printf "controlPlane.apiServerCIDRs entry %v is not a CIDR (for example 10.0.0.0/24)" $x) }}{{ end }}
{{- end }}
{{- if not (or (kindIs "float64" $c.maxDefinitions) (kindIs "int64" $c.maxDefinitions) (kindIs "int" $c.maxDefinitions)) }}{{ fail "controlPlane.maxDefinitions must be a whole number" }}{{ end -}}
{{- if lt (int $c.maxDefinitions) 1 }}{{ fail (printf "controlPlane.maxDefinitions must be at least 1, got %v" $c.maxDefinitions) }}{{ end -}}
{{- if and $c.minRecreateInterval (not (regexMatch "^([0-9]+(\\.[0-9]+)?(ms|s|m|h))+$" (toString $c.minRecreateInterval))) }}{{ fail (printf "controlPlane.minRecreateInterval must be a duration with a unit, such as 90s or 5m (empty: the controller's default, 2m), got %v" $c.minRecreateInterval) }}{{ end -}}
{{- if and $c.minInterval (not (regexMatch "^([0-9]+(\\.[0-9]+)?(ms|s|m|h))+$" (toString $c.minInterval))) }}{{ fail (printf "controlPlane.minInterval must be a duration with a unit, such as 500ms or 2s (empty: the controller's default), got %v" $c.minInterval) }}{{ end -}}
{{- if not (kindIs "slice" $c.apiServerPorts) }}{{ fail "controlPlane.apiServerPorts must be a list of port numbers" }}{{ end -}}
{{- range $x := $c.apiServerPorts }}
{{- if not (and (or (kindIs "float64" $x) (kindIs "int64" $x) (kindIs "int" $x)) (ge (int $x) 1) (le (int $x) 65535)) }}{{ fail (printf "controlPlane.apiServerPorts entry %v is not a port number" $x) }}{{ end }}
{{- end }}
{{- end -}}

{{/* A string map as a CEL map literal: {"a": "b", ...} (used by the guard of the container runtime). */}}
{{- define "oa.celMap" -}}
{{- $p := list -}}{{- range $k, $v := . }}{{ $p = append $p (printf "%s: %s" (toJson $k) (toJson $v)) }}{{ end -}}
{ {{- join ", " $p -}} }
{{- end -}}

{{/* The platform the chart renders for: "" or "kubernetes" (the default) or "openshift". Anything else fails the render. */}}
{{- define "oa.platform" -}}
{{- $p := .Values.platform | default "" -}}
{{- if not (and (kindIs "string" $p) (has $p (list "" "kubernetes" "openshift"))) }}{{ fail (printf "platform must be empty, kubernetes or openshift, not %v" $p) }}{{ end -}}
{{- $p -}}
{{- end -}}

{{/* "true" on OpenShift, empty otherwise. On OpenShift no pod pins runAsUser, runAsGroup or fsGroup: the restricted-v2 SCC assigns them from the namespace range. */}}
{{- define "oa.openshift" -}}
{{- if eq (include "oa.platform" .) "openshift" }}true{{ end -}}
{{- end -}}

{{/* The image of a component the installer builds (ADR 0022): "repository:tag", "repository:tag@digest" when image.digest is set,
     "repository@digest" with an empty tag; an empty tag without a digest fails.
     image.digest must be sha256:<64 hex>; the render fails with the value path otherwise. Usage: include "oa.image" (list $x.image "bridge") */}}
{{- define "oa.image" -}}
{{- $i := index . 0 -}}{{- $path := index . 1 -}}
{{- $d := toString ($i.digest | default "") -}}{{- $t := toString ($i.tag | default "") -}}
{{- if $d -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $d) -}}{{- fail (printf "%s.image.digest must be sha256: followed by 64 lower case hex characters, got %q" $path $d) -}}{{- end -}}
{{- if $t -}}{{- printf "%s:%s@%s" $i.repository $t $d -}}{{- else -}}{{- printf "%s@%s" $i.repository $d -}}{{- end -}}
{{- else -}}
{{- if not $t -}}{{- fail (printf "%s.image.tag is empty and %s.image.digest is not set: set one of them" $path $path) -}}{{- end -}}
{{- printf "%s:%s" $i.repository $t -}}
{{- end -}}
{{- end -}}

{{/* ADR 0024: the PodDisruptionBudget of one Deployment or StatefulSet. Call it on its own line right after a "---" (or at the top of a file), with
dict "root" $ "name" <workload name> "app" <the app label of its selector> "ns" <its namespace>. It prints nothing when
availability.podDisruptionBudgets.enabled is false, so the render is then byte-identical to a render without it. The selector is the workload's own
selector plus the release and part-of labels, so a pod of another team with the same app label in the same namespace is not covered. */}}
{{- define "oa.pdb" -}}
{{- if .root.Values.availability.podDisruptionBudgets.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    app: {{ .app }}
    {{- include "oa.labels" .root | nindent 4 }}
spec:
  maxUnavailable: 1
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector:
    matchLabels:
      app: {{ .app }}
      app.kubernetes.io/instance: {{ .root.Release.Name }}
      app.kubernetes.io/part-of: openagentix
---
{{- end }}
{{- end -}}

{{/* ADR 0024: availability.priorityClassName for a pod template ("" when unset). Fails the render when it is not a DNS-1123 subdomain.
Used in each pod template as: with (include "oa.priorityClass" $), then the field priorityClassName. */}}
{{- define "oa.priorityClass" -}}
{{- $n := toString .Values.availability.priorityClassName -}}
{{- if $n -}}
{{- if or (gt (len $n) 253) (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" $n)) }}{{ fail (printf "availability.priorityClassName %q must be empty or a DNS-1123 subdomain (lower-case letters, digits, '-' and '.', at most 253 characters)" $n) }}{{ end -}}
{{- $n -}}
{{- end -}}
{{- end -}}
