{{/* ADR 0026, slice 2: mcp.endpoints[], MCP endpoints that already run, in a tool group of their own with a header credential.
Everything here is off while mcp.endpoints is empty: the helpers return empty lists and the group of every profile is "". */}}

{{/* "true" when mcp.endpoints is set (a non-empty list; any other non-empty value is refused by oa.epCheck). */}}
{{- define "oa.epOn" -}}
{{- $m := .Values.mcp | default dict -}}
{{- if $m.endpoints -}}true{{- end -}}
{{- end -}}

{{/* The endpoint maps as JSON, [] when mcp.endpoints is not a list. Not validated: oa.epCheck does that. */}}
{{- define "oa.epRaw" -}}
{{- $m := .Values.mcp | default dict -}}
{{- if kindIs "slice" $m.endpoints -}}{{ $m.endpoints | toJson }}{{- else -}}[]{{- end -}}
{{- end -}}

{{/* JSON list of the endpoint names (tolerant: entries that are not maps with a string name are skipped). */}}
{{- define "oa.epNames" -}}
{{- $l := list -}}
{{- range $e := (include "oa.epRaw" . | fromJsonArray) -}}
{{- if and (kindIs "map" $e) (kindIs "string" $e.name) }}{{ $l = append $l $e.name }}{{ end -}}
{{- end -}}
{{- $l | toJson -}}
{{- end -}}

{{/* JSON map: endpoint name -> its group (endpoints with a group only). */}}
{{- define "oa.epGroupMap" -}}
{{- $d := dict -}}
{{- range $e := (include "oa.epRaw" . | fromJsonArray) -}}
{{- if and (kindIs "map" $e) (kindIs "string" $e.name) (kindIs "string" $e.group) $e.group }}{{ $_ := set $d $e.name $e.group }}{{ end -}}
{{- end -}}
{{- $d | toJson -}}
{{- end -}}

{{/* JSON list of the host forms of every endpoint with an in-cluster URL: <svc>.<ns>, <svc>.<ns>.svc, <svc>.<ns>.svc.cluster.local. They are the same
host, so a check on one form must see the other two (ADR 0026 A2). Tolerant: a URL that does not match is skipped (oa.epCheck refuses it). */}}
{{- define "oa.epHosts" -}}
{{- $out := list -}}
{{- range $e := (include "oa.epRaw" . | fromJsonArray) -}}
{{- if and (kindIs "map" $e) (kindIs "string" $e.url) (regexMatch "^https?://[^./:@?#]+[.][^./:@?#]+[.]svc([.]cluster[.]local)?([:/].*)?$" $e.url) -}}
{{- $s := regexReplaceAll "^https?://([^./:@?#]+)[.]([^./:@?#]+)[.]svc.*$" $e.url "${1}" -}}
{{- $n := regexReplaceAll "^https?://([^./:@?#]+)[.]([^./:@?#]+)[.]svc.*$" $e.url "${2}" -}}
{{- $out = concat $out (list (printf "%s.%s" $s $n) (printf "%s.%s.svc" $s $n) (printf "%s.%s.svc.cluster.local" $s $n)) -}}
{{- end -}}
{{- end -}}
{{- $out | uniq | toJson -}}
{{- end -}}

{{/* JSON list of the namespaces of the endpoints with an in-cluster URL, sorted. The catalog carries it, so that the guard and the controller refuse an egress host in any of
these namespaces in every form, whatever the shape of the namespace name (ADR 0026 review). Tolerant like oa.epHosts. */}}
{{- define "oa.epNamespaces" -}}
{{- $out := list -}}
{{- range $e := (include "oa.epRaw" . | fromJsonArray) -}}
{{- if and (kindIs "map" $e) (kindIs "string" $e.url) (regexMatch "^https?://[^./:@?#]+[.][^./:@?#]+[.]svc([.]cluster[.]local)?([:/].*)?$" $e.url) -}}
{{- $out = append $out (regexReplaceAll "^https?://([^./:@?#]+)[.]([^./:@?#]+)[.]svc.*$" $e.url "${2}") -}}
{{- end -}}
{{- end -}}
{{- $out | uniq | sortAlpha | toJson -}}
{{- end -}}

{{/* "true" when the host (lower case, no port, maybe starting with "*.") is one of the forms, or a wildcard that stands for exactly one label in front of
a suffix of one of them. Argument: dict "host" <host> "forms" <list of forms>. */}}
{{- define "oa.epHostNamed" -}}
{{- $h := .host -}}
{{- if hasPrefix "*." $h -}}
{{- $w := trimPrefix "*." $h -}}
{{- range $f := .forms -}}
{{- if and (hasSuffix (printf ".%s" $w) $f) (not (contains "." (trimSuffix (printf ".%s" $w) $f))) -}}true{{- end -}}
{{- end -}}
{{- else -}}
{{- if has $h .forms -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/* Every namespace the chart's values name: each value whose key ends in "namespace" (any case), at any depth, an empty value being the release
namespace. Recursive. Argument: dict "v" <value> "acc" <dict with the list "l"> "rel" <release namespace>. */}}
{{- define "oa.walkNs" -}}
{{- $acc := .acc -}}{{- $rel := .rel -}}
{{- if kindIs "map" .v -}}
{{- range $k, $x := .v -}}
{{- if and (hasSuffix "namespace" (lower (toString $k))) (or (kindIs "string" $x) (kindIs "invalid" $x)) -}}
{{- $_ := set $acc "l" (append $acc.l (default $rel (toString (default "" $x)))) -}}
{{- else -}}
{{- include "oa.walkNs" (dict "v" $x "acc" $acc "rel" $rel) -}}
{{- end -}}
{{- end -}}
{{- else if kindIs "slice" .v -}}
{{- range $x := .v -}}{{- include "oa.walkNs" (dict "v" $x "acc" $acc "rel" $rel) -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/* JSON list of the namespaces an endpoint may not be in: every namespace value of the chart (computed from the values, so a new one cannot be forgotten),
default, kube-system, kube-public and kube-node-lease. Names that start with openagentix- are refused by the caller. */}}
{{- define "oa.epPlatformNs" -}}
{{- $acc := dict "l" (list "default" "kube-system" "kube-public" "kube-node-lease") -}}
{{- $_ := include "oa.walkNs" (dict "v" .Values "acc" $acc "rel" .Release.Namespace) -}}
{{- $acc.l | uniq | sortAlpha | toJson -}}
{{- end -}}

{{/* The tool group a profile lives on: "diagnostics" (ADR 0025), the group of its endpoints (ADR 0026), or "" (the shared group).
Argument: dict "root" <top> "profile" <one mcp.profiles entry or {}>. */}}
{{- define "oa.profileGroup" -}}
{{- if include "oa.diagProfile" . -}}diagnostics
{{- else if and (kindIs "map" .profile) (kindIs "map" .profile.tools) -}}
{{- $gm := include "oa.epGroupMap" .root | fromJson -}}
{{- $g := "" -}}
{{- range $w := (keys .profile.tools | sortAlpha) -}}{{- if and (not $g) (hasKey $gm $w) }}{{ $g = get $gm $w }}{{ end -}}{{- end -}}
{{- $g -}}
{{- end -}}
{{- end -}}

{{/* The backend name a profile's filter uses for the key $w of its tools map, on the profile's own group. Argument: dict "root" "profile" "w". On the
diagnostics group every backend but cluster-read is the entry <w>-diagnostics; on an endpoint group every backend but an endpoint is the mirror <w>-<group>. */}}
{{- define "oa.groupWorkload" -}}
{{- $g := include "oa.profileGroup" (dict "root" .root "profile" .profile) -}}
{{- if eq $g "" -}}{{ .w }}
{{- else if eq $g "diagnostics" -}}{{ if ne .w "cluster-read" }}{{ printf "%s-diagnostics" .w }}{{ else }}{{ .w }}{{ end }}
{{- else -}}{{ if has .w (include "oa.epNames" .root | fromJsonArray) }}{{ .w }}{{ else }}{{ printf "%s-%s" .w $g }}{{ end }}
{{- end -}}
{{- end -}}

{{/* Rewrites the tool names of the knowledge base and notify in a text (a JSON list or a prompt) to the names the profile's group serves them under. Argument:
dict "root" "profile" "text". Text for a profile on the shared group is returned unchanged. */}}
{{- define "oa.groupRename" -}}
{{- $r := .root -}}
{{- $t := .text -}}
{{- $g := include "oa.profileGroup" (dict "root" $r "profile" .profile) -}}
{{- if $g -}}
{{- $kp := replace "{workload}" $r.Values.knowledge.mcp.entryName $r.Values.mcp.virtual.prefixFormat -}}
{{- $kn := replace "{workload}" (printf "%s-%s" $r.Values.knowledge.mcp.entryName $g) $r.Values.mcp.virtual.prefixFormat -}}
{{- $np := replace "{workload}" $r.Values.notify.mcp.entryName $r.Values.mcp.virtual.prefixFormat -}}
{{- $nn := replace "{workload}" (printf "%s-%s" $r.Values.notify.mcp.entryName $g) $r.Values.mcp.virtual.prefixFormat -}}
{{- $t | replace (printf "%skb_" $kp) (printf "%skb_" $kn) | replace (printf "%snotify_" $np) (printf "%snotify_" $nn) -}}
{{- else -}}{{ $t }}{{- end -}}
{{- end -}}

{{/* JSON list of the vMCP names of the profiles that live on the group (the container agent variants cannot exist: a profile with an endpoint tool is
refused in controlPlane.containerAgents.toolProfiles). Argument: dict "root" "group". */}}
{{- define "oa.epGroupVmcps" -}}
{{- $r := .root -}}{{- $g := .group -}}
{{- $out := list -}}
{{- range $p := ($r.Values.mcp.profiles | default list) -}}
{{- if eq (include "oa.profileGroup" (dict "root" $r "profile" $p)) $g }}{{ $out = append $out (printf "%s-%s" $r.Values.mcp.virtual.name $p.name) }}{{ end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/* JSON list of the platform backends (the knowledge and notify entry names) that a profile on the group lists, so the group needs a mirror of each. */}}
{{- define "oa.epMirrorKeys" -}}
{{- $r := .root -}}{{- $g := .group -}}
{{- $out := list -}}
{{- range $p := ($r.Values.mcp.profiles | default list) -}}
{{- if eq (include "oa.profileGroup" (dict "root" $r "profile" $p)) $g -}}
{{- range $w := (keys $p.tools | sortAlpha) -}}
{{- if or (and $r.Values.knowledge.enabled (eq $w $r.Values.knowledge.mcp.entryName)) (and $r.Values.notify.enabled (eq $w $r.Values.notify.mcp.entryName)) }}{{ $out = append $out $w }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | uniq | sortAlpha | toJson -}}
{{- end -}}

{{/* "true" when the profile lists no endpoint, or every endpoint it lists has allowDefinitions: true (then it may go into the control plane catalog).
Argument: dict "root" "profile". */}}
{{- define "oa.epOpen" -}}
{{- $open := true -}}
{{- if and (kindIs "map" .profile) (kindIs "map" .profile.tools) -}}
{{- range $e := (include "oa.epRaw" .root | fromJsonArray) -}}
{{- if and (kindIs "map" $e) (hasKey $.profile.tools (toString $e.name)) (not $e.allowDefinitions) }}{{ $open = false }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if $open -}}true{{- end -}}
{{- end -}}

{{/* Fails the render when mcp.endpoints (or mcp.endpointEntriesHeld) is malformed or breaks a rule of ADR 0026 section A. Prints nothing. It does not read the
control plane's lists (oa.epDefsCheck does), so oa.profilesCheck can include it. */}}
{{- define "oa.epCheck" -}}
{{- $m := .Values.mcp | default dict -}}
{{- $held := $m.endpointEntriesHeld | default list -}}
{{- if not (kindIs "slice" $held) }}{{ fail "mcp.endpointEntriesHeld must be a list of endpoint names (it is for the installer's two-step apply of the shared group mode, ADR 0026)" }}{{ end -}}
{{- $raw := $m.endpoints -}}
{{- $names := include "oa.epNames" . | fromJsonArray -}}
{{- range $h := $held -}}
{{- if not (has (toString $h) $names) }}{{ fail (printf "mcp.endpointEntriesHeld names %q, which is not an entry of mcp.endpoints" (toString $h)) }}{{ end -}}
{{- fail (printf "mcp.endpointEntriesHeld names %q, an endpoint with a group of its own: only an endpoint of the shared group mode can be held back (that mode is not available yet), and an own-group entry is applied as it is" (toString $h)) -}}
{{- end -}}
{{- if $raw -}}
{{- if not (kindIs "slice" $raw) }}{{ fail "mcp.endpoints must be a list of endpoint maps (name, url, group, auth, ingress)" }}{{ end -}}
{{- if not $m.enabled }}{{ fail "mcp.endpoints needs mcp.enabled=true: an endpoint is a backend of the tool gateway" }}{{ end -}}
{{- if not .Values.networkPolicy.enabled }}{{ fail "mcp.endpoints needs networkPolicy.enabled=true: the policies in front of the endpoint and on the vMCPs of its group are the boundary that keeps other pods away and keeps the name from leading anywhere else" }}{{ end -}}
{{- $cp := .Values.controlPlane | default dict -}}
{{- if not (kindIs "slice" ($cp.apiServerCIDRs | default list)) }}{{ fail "controlPlane.apiServerCIDRs must be a list of CIDRs" }}{{ end -}}
{{- if not $cp.apiServerCIDRs }}{{ fail "mcp.endpoints needs controlPlane.apiServerCIDRs (the API server addresses, for example 10.0.0.0/24; install.sh sets them): the egress policy of the group's vMCPs lets them reach the API server for discovery, and an empty list would open the API server ports to any address" }}{{ end -}}
{{- range $x := $cp.apiServerCIDRs }}
{{- if not (and (kindIs "string" $x) (or (regexMatch "^([0-9]{1,3}[.]){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$" $x) (regexMatch "^[0-9a-fA-F:]*:[0-9a-fA-F:.]*/([0-9]{1,2}|1[01][0-9]|12[0-8])$" $x))) }}{{ fail (printf "controlPlane.apiServerCIDRs entry %v is not a CIDR (for example 10.0.0.0/24)" $x) }}{{ end }}
{{- end -}}
{{- $plat := include "oa.epPlatformNs" . | fromJsonArray -}}
{{- $taken := dict -}}
{{- range $s := ($m.servers | default list) }}{{ $_ := set $taken (toString $s.name) "an entry of mcp.servers" }}{{ end -}}
{{- $_ := set $taken (toString .Values.knowledge.mcp.entryName) "the knowledge entry (knowledge.mcp.entryName)" -}}
{{- $_ := set $taken (toString .Values.notify.mcp.entryName) "the notify entry (notify.mcp.entryName)" -}}
{{- $_ := set $taken "cluster-read" "a reserved name (ADR 0025)" -}}
{{- $_ := set $taken "db-read" "a reserved name (ADR 0025)" -}}
{{- range $b := (keys (($.Values.diagnostics | default dict).allowWith | default dict)) }}{{ $_ := set $taken (printf "%s-diagnostics" $b) "an entry of the diagnostics group (diagnostics.allowWith)" }}{{ end -}}
{{- $_ := set $taken (printf "%s-diagnostics" .Values.knowledge.mcp.entryName) "an entry of the diagnostics group" -}}
{{- $_ := set $taken (printf "%s-diagnostics" .Values.notify.mcp.entryName) "an entry of the diagnostics group" -}}
{{- $allowed := list "name" "url" "transport" "group" "auth" "allowUnauthenticated" "ingress" "allowDefinitions" -}}
{{- $seen := list -}}
{{- $mirrors := dict -}}
{{- range $e := $raw -}}
{{- if and (kindIs "map" $e) (kindIs "string" $e.group) $e.group }}{{ $_ := set $mirrors (printf "%s-%s" $.Values.knowledge.mcp.entryName $e.group) (printf "the mirror of the knowledge entry in the group %s" $e.group) }}{{ $_ := set $mirrors (printf "%s-%s" $.Values.notify.mcp.entryName $e.group) (printf "the mirror of the notify entry in the group %s" $e.group) }}{{ end -}}
{{- end -}}
{{- range $i, $e := $raw -}}
{{- if not (kindIs "map" $e) }}{{ fail (printf "mcp.endpoints[%d] must be a map with name, url, group, auth and ingress" $i) }}{{ end -}}
{{- $n := toString (default "" $e.name) -}}
{{- $at := printf "mcp.endpoints[%s]" (default (toString $i) $n) -}}
{{- range $k, $_ := $e }}{{ if not (has $k $allowed) }}{{ fail (printf "%s: unknown key %q (allowed: %s)" $at $k (join ", " $allowed)) }}{{ end }}{{ end -}}
{{- if not (and (kindIs "string" $e.name) (regexMatch "^[a-z0-9]+(-[a-z0-9]+)*$" $e.name) (le (len $e.name) 30)) }}{{ fail (printf "%s: name must be lower case letters, digits and single dashes, at most 30 characters (it is the tool prefix, records_...)" $at) }}{{ end -}}
{{- if has $n $seen }}{{ fail (printf "mcp.endpoints: the name %q is used twice" $n) }}{{ end -}}
{{- $seen = append $seen $n -}}
{{- if hasKey $taken $n }}{{ fail (printf "%s: the name %q is already %s: choose another name" $at $n (get $taken $n)) }}{{ end -}}
{{- if hasKey $mirrors $n }}{{ fail (printf "%s: the name %q is already %s: choose another name" $at $n (get $mirrors $n)) }}{{ end -}}
{{- /* url */ -}}
{{- $u := $e.url -}}
{{- if not (and (kindIs "string" $u) $u) }}{{ fail (printf "%s.url is required: http(s)://<service>.<namespace>.svc.cluster.local[:port]/<path>" $at) }}{{ end -}}
{{- if contains "@" $u }}{{ fail (printf "%s.url may not hold a user name or password: the credential is auth.header, from a Secret" $at) }}{{ end -}}
{{- if contains "?" $u }}{{ fail (printf "%s.url may not hold a query" $at) }}{{ end -}}
{{- if contains "#" $u }}{{ fail (printf "%s.url may not hold a fragment" $at) }}{{ end -}}
{{- if not (regexMatch "^https?://" $u) }}{{ fail (printf "%s.url must start with http:// or https:// (got %q)" $at $u) }}{{ end -}}
{{- $auth := regexReplaceAll "^https?://([^/]*).*$" $u "${1}" -}}
{{- if or (hasPrefix "[" $auth) (regexMatch "^[0-9.]+(:[0-9]*)?$" $auth) }}{{ fail (printf "%s.url names an address (an IPv4 or IPv6 literal): use the Service name, <service>.<namespace>.svc.cluster.local" $at) }}{{ end -}}
{{- if not (regexMatch "^https?://([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)[.]([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)[.]svc([.]cluster[.]local)?(:[0-9]{1,5})?(/[A-Za-z0-9/._~-]*)?$" $u) -}}
{{- if regexMatch "^https?://([a-z0-9-]+[.])+[a-z]{2,63}(:[0-9]+)?(/.*)?$" $u }}{{ fail (printf "%s.url %q is outside the cluster: an internet endpoint is not available in this release (ADR 0026 slice 7)" $at $u) }}{{ end -}}
{{- fail (printf "%s.url %q must be http(s)://<service>.<namespace>.svc.cluster.local (or <service>.<namespace>.svc), an optional port, and a path of letters, digits and /._~-" $at $u) -}}
{{- end -}}
{{- $port := regexFind ":[0-9]+" $auth -}}
{{- if and $port (or (lt (int (trimPrefix ":" $port)) 1) (gt (int (trimPrefix ":" $port)) 65535)) }}{{ fail (printf "%s.url has the port %s: a port is 1 to 65535" $at (trimPrefix ":" $port)) }}{{ end -}}
{{- $svc := regexReplaceAll "^https?://([^./:]+)[.]([^./:]+)[.]svc.*$" $u "${1}" -}}
{{- $ns := regexReplaceAll "^https?://([^./:]+)[.]([^./:]+)[.]svc.*$" $u "${2}" -}}
{{- if and (eq $svc "kubernetes") (eq $ns "default") }}{{ fail (printf "%s.url is the Kubernetes API service, which can never be an endpoint" $at) }}{{ end -}}
{{- if or (has $ns $plat) (hasPrefix "openagentix-" $ns) }}{{ fail (printf "%s.url is in the namespace %q, a platform or system namespace (the namespaces of this chart's values, default, kube-system, kube-public, kube-node-lease, openagentix-*): an endpoint there would reach a platform service around its own controls" $at $ns) }}{{ end -}}
{{- /* transport */ -}}
{{- if and (hasKey $e "transport") (not (has $e.transport (list "streamable-http" "sse"))) }}{{ fail (printf "%s.transport must be streamable-http (the default) or sse, got %v" $at $e.transport) }}{{ end -}}
{{- /* group */ -}}
{{- $g := $e.group | default "" -}}
{{- if not (kindIs "string" $g) }}{{ fail (printf "%s.group must be a string" $at) }}{{ end -}}
{{- if not (kindIs "bool" (default false $e.allowUnauthenticated)) }}{{ fail (printf "%s.allowUnauthenticated must be true or false" $at) }}{{ end -}}
{{- if eq $g "" -}}
{{- if $e.allowUnauthenticated }}{{ fail (printf "%s: the shared group mode (allowUnauthenticated: true, no group, no credential) is not available in this release (ADR 0026 slice 6). Use a group of its own with auth.header" $at) }}{{ end -}}
{{- fail (printf "%s.group is empty: set group: <name> for a tool group of its own with auth.header (the reference mode). An empty group means the shared group, which needs allowUnauthenticated: true and is not available in this release" $at) -}}
{{- end -}}
{{- if $e.allowUnauthenticated }}{{ fail (printf "%s: allowUnauthenticated is for the shared group (an empty group) and has no meaning with a group of its own" $at) }}{{ end -}}
{{- if not (and (regexMatch "^[a-z][a-z0-9]*(-[a-z0-9]+)*$" $g) (le (len $g) 20) (ne $g $m.groupName) (ne $g "diagnostics")) }}{{ fail (printf "mcp.endpoints[%s].group %q is not valid: lower case letters, digits and single dashes, starting with a letter, at most 20 characters, and not %q (mcp.groupName) or \"diagnostics\"" $n $g $m.groupName) }}{{ end -}}
{{- /* credential */ -}}
{{- if not $e.auth }}{{ fail (printf "%s.auth is required: an endpoint needs a header credential from a Secret (auth.header.name and auth.header.secret). The chart renders only the reference" $at) }}{{ end -}}
{{- if not (kindIs "map" $e.auth) }}{{ fail (printf "%s.auth must be a map with the key header" $at) }}{{ end -}}
{{- range $k, $_ := $e.auth }}{{ if ne $k "header" }}{{ fail (printf "%s.auth: only the key header is accepted, got %q (a bearer token type is never rendered: ToolHive 0.67.1 drops such a backend)" $at $k) }}{{ end }}{{ end -}}
{{- $hd := $e.auth.header -}}
{{- if not (kindIs "map" $hd) }}{{ fail (printf "%s.auth.header must be a map with name and secret" $at) }}{{ end -}}
{{- range $k, $_ := $hd }}{{ if not (has $k (list "name" "secret")) }}{{ fail (printf "%s.auth.header: only name and secret are accepted, got %q (a header value is never taken from the values, only from a Secret)" $at $k) }}{{ end }}{{ end -}}
{{- $hn := toString (default "" $hd.name) -}}
{{- if not (and (kindIs "string" $hd.name) (regexMatch "^[A-Za-z0-9-]{1,64}$" $hn)) }}{{ fail (printf "%s.auth.header.name %q is not a valid header name: letters, digits and dashes, at most 64 characters" $at $hn) }}{{ end -}}
{{- if has (lower $hn) (list "host" "content-length" "content-type" "transfer-encoding" "connection" "cookie" "proxy-authorization" "mcp-session-id" "mcp-protocol-version" "metadata-flavor" "metadata" "x-aws-ec2-metadata-token") }}{{ fail (printf "%s.auth.header.name %q is a refused header name (it is set by the protocol or the transport, or it reads cloud metadata)" $at $hn) }}{{ end -}}
{{- $sr := $hd.secret -}}
{{- if not (and (kindIs "map" $sr) (kindIs "string" $sr.name) (kindIs "string" $sr.key) (regexMatch "^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$" $sr.name) (le (len $sr.name) 253) (regexMatch "^[-._a-zA-Z0-9]{1,253}$" $sr.key)) }}{{ fail (printf "%s.auth.header.secret must be {name: <Secret in %s>, key: <key>}: a DNS name and a key of letters, digits, '-', '_' and '.'" $at $m.namespace) }}{{ end -}}
{{- range $k, $_ := $sr }}{{ if not (has $k (list "name" "key")) }}{{ fail (printf "%s.auth.header.secret: only name and key are accepted, got %q" $at $k) }}{{ end }}{{ end -}}
{{- /* boundary */ -}}
{{- if not (kindIs "map" $e.ingress) }}{{ fail (printf "%s.ingress is required for an in-cluster endpoint: {podSelector: {<label>: <value>}, port: <the pod port>}. It limits who may call the endpoint and where the vMCPs may go" $at) }}{{ end -}}
{{- range $k, $_ := $e.ingress }}{{ if not (has $k (list "podSelector" "port")) }}{{ fail (printf "%s.ingress: only podSelector and port are accepted, got %q" $at $k) }}{{ end }}{{ end -}}
{{- $ps := $e.ingress.podSelector -}}
{{- if or (not (kindIs "map" $ps)) (not $ps) }}{{ fail (printf "%s.ingress.podSelector must be a non-empty map of pod labels (an empty selector would match every pod of the namespace)" $at) }}{{ end -}}
{{- range $k, $v := $ps }}{{ if not (and (kindIs "string" $v) $v (regexMatch "^[A-Za-z0-9]([-A-Za-z0-9_./]*[A-Za-z0-9])?$" (toString $k)) (le (len $v) 63)) }}{{ fail (printf "%s.ingress.podSelector label %q needs a non-empty string value of at most 63 characters" $at (toString $k)) }}{{ end }}{{ end -}}
{{- $ip := $e.ingress.port -}}
{{- if not (and (or (kindIs "float64" $ip) (kindIs "int64" $ip) (kindIs "int" $ip)) (ge (int $ip) 1) (le (int $ip) 65535)) }}{{ fail (printf "%s.ingress.port is required: the pod port (not the Service port), 1 to 65535" $at) }}{{ end -}}
{{- /* definitions */ -}}
{{- if and (hasKey $e "allowDefinitions") (not (kindIs "bool" $e.allowDefinitions)) }}{{ fail (printf "%s.allowDefinitions must be true or false" $at) }}{{ end -}}
{{- if $e.allowDefinitions }}{{ fail (printf "%s.allowDefinitions: true is not accepted on an endpoint with a group of its own: the control plane catalog holds one list of knowledge and notify tool names, and an own-group profile shows them under the mirror names (ADR 0026 A6). Definitions cannot use this profile" $at) }}{{ end -}}
{{- end -}}
{{- /* profiles that list an endpoint */ -}}
{{- $gm := include "oa.epGroupMap" . | fromJson -}}
{{- $serverNames := list -}}{{- range $s := ($m.servers | default list) }}{{ $serverNames = append $serverNames (toString $s.name) }}{{ end -}}
{{- $byGroup := dict -}}
{{- range $p := ($m.profiles | default list) -}}
{{- if and (kindIs "map" $p) (kindIs "map" $p.tools) -}}
{{- $epKeys := list -}}
{{- range $w := (keys $p.tools | sortAlpha) }}{{ if has $w $names }}{{ $epKeys = append $epKeys $w }}{{ end }}{{ end -}}
{{- if $epKeys -}}
{{- $groups := list -}}{{- range $w := $epKeys }}{{ $groups = append $groups (get $gm $w) }}{{ end -}}
{{- $groups = $groups | uniq | sortAlpha -}}
{{- if gt (len $groups) 1 }}{{ fail (printf "profile %q lists endpoints of two tool groups (%s): a profile is rendered on one group. Split it into one profile per group" $p.name (join ", " $groups)) }}{{ end -}}
{{- if include "oa.diagProfile" (dict "root" $ "profile" $p) }}{{ fail (printf "profile %q lists an endpoint of mcp.endpoints and a diagnostics tool: two tool groups. Split it into two profiles" $p.name) }}{{ end -}}
{{- range $w := (keys $p.tools | sortAlpha) }}{{ if has $w $serverNames }}{{ fail (printf "profile %q lists the endpoint %q and the entry %q of mcp.servers: an MCPServer has one group (%s) and the endpoint is in the group %q, so one profile cannot list both" $p.name (index $epKeys 0) $w $m.groupName (index $groups 0)) }}{{ end }}{{ end -}}
{{- if $p.codeMode }}{{ fail (printf "profile %q lists an endpoint tool, so codeMode must be false: code mode chains calls without the model's step in between, and an endpoint has write tools" $p.name) }}{{ end -}}
{{- $g := index $groups 0 -}}
{{- if not (hasKey $byGroup $g) }}{{ $_ := set $byGroup $g (dict) }}{{ end -}}
{{- $seenNames := get $byGroup $g -}}
{{- range $w := (keys $p.tools | sortAlpha) -}}
{{- $wl := include "oa.groupWorkload" (dict "root" $ "profile" $p "w" $w) -}}
{{- $pfx := replace "{workload}" $wl $.Values.mcp.virtual.prefixFormat -}}
{{- range $t := (index $p.tools $w) -}}
{{- if and (has $w $epKeys) (not (regexMatch "^[A-Za-z0-9_-]+$" (toString $t))) }}{{ fail (printf "profile %q: the tool %q of the endpoint %q uses a character other than letters, digits, '_' and '-' (a '.' is refused)" $p.name (toString $t) $w) }}{{ end -}}
{{- $full := printf "%s%s" $pfx $t -}}
{{- if gt (len $full) 64 }}{{ fail (printf "profile %q: the tool name %q is %d characters; the limit is 64 characters (model APIs refuse longer names)" $p.name $full (len $full)) }}{{ end -}}
{{- if and (hasKey $seenNames $full) (ne (get $seenNames $full) $wl) }}{{ fail (printf "profile %q: the tool name %q would come from the backends %q and %q of the group %q" $p.name $full (get $seenNames $full) $wl $g) }}{{ end -}}
{{- $_ := set $seenNames $full $wl -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* What the control plane's lists may name (needs oa.caToolProfiles, so it is not part of oa.epCheck): a profile with an endpoint tool stays out of the
catalog unless every endpoint has allowDefinitions, and may not be named in allowedProfiles or containerAgents.toolProfiles. */}}
{{- define "oa.epDefsCheck" -}}
{{- $_ := include "oa.epCheck" . -}}
{{- if include "oa.epOn" . -}}
{{- $m := .Values.mcp -}}
{{- $cp := .Values.controlPlane | default dict -}}
{{- $pol := $cp.policy | default dict -}}
{{- $allowedProfiles := $pol.allowedProfiles | default list -}}
{{- $caNames := list -}}{{- range $w := (include "oa.caToolProfiles" . | fromJsonArray) }}{{ $caNames = append $caNames $w.name }}{{ end -}}
{{- range $p := ($m.profiles | default list) -}}
{{- if and (include "oa.profileGroup" (dict "root" $ "profile" $p)) (not (include "oa.diagProfile" (dict "root" $ "profile" $p))) (not (include "oa.epOpen" (dict "root" $ "profile" $p))) -}}
{{- if and $cp.enabled (has $p.name $allowedProfiles) }}{{ fail (printf "controlPlane.policy.allowedProfiles names the profile %q, which lists a tool of mcp.endpoints: definitions cannot use it (allowDefinitions is refused on an endpoint with a group of its own, ADR 0026 A6). Take it out of the list; chart agents (agents[]) can use the profile. The single entry \"*\" is accepted: the catalog leaves the profile out" $p.name) }}{{ end -}}
{{- if has $p.name $caNames }}{{ fail (printf "controlPlane.containerAgents.toolProfiles names the profile %q, which lists a tool of mcp.endpoints: container agents cannot use it (ADR 0026 A6). Take it out of the list" $p.name) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
