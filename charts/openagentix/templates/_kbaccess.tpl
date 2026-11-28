{{/* ADR 0030, slices 2 and 3: which collections a tool group may read through the knowledge base. Everything here prints nothing, and no object
renders, while knowledge.access.mode is "" (the default), so the default render is byte-identical. */}}

{{/* The collection name rule of the knowledge base (services/kb ValidateCollection). */}}
{{- define "oa.kbCollectionRe" -}}^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$
{{- end -}}

{{/* The mode: "", "report" or "enforce". Fails for anything else. */}}
{{- define "oa.kbMode" -}}
{{- $a := (.Values.knowledge | default dict).access | default dict -}}
{{- $m := $a.mode | default "" -}}
{{- if not (kindIs "string" $m) }}{{ fail "knowledge.access.mode must be a quoted string: \"\" (off), \"report\" or \"enforce\"" }}{{ end -}}
{{- if not (has $m (list "" "report" "enforce")) }}{{ fail (printf "knowledge.access.mode %q is not valid: use \"\" (off, every caller reads every collection), \"report\" (log what enforce would refuse) or \"enforce\"" $m) }}{{ end -}}
{{- $m -}}
{{- end -}}

{{/* "true" when a profile lists the knowledge base's tools. Argument: dict "root" "profile". */}}
{{- define "oa.kbProfileLists" -}}
{{- if and (kindIs "map" .profile) (kindIs "map" .profile.tools) (hasKey .profile.tools .root.Values.knowledge.mcp.entryName) -}}true{{- end -}}
{{- end -}}

{{/* A list of collection names, checked: strings that match the rule, no duplicates. Argument: dict "v" <value> "what" <sentence start>. Prints the sorted list as JSON. */}}
{{- define "oa.kbCollectionList" -}}
{{- $v := .v | default list -}}
{{- if not (kindIs "slice" $v) }}{{ fail (printf "%s must be a list of collection names" .what) }}{{ end -}}
{{- range $c := $v -}}
{{- if not (and (kindIs "string" $c) (regexMatch (include "oa.kbCollectionRe" $) $c)) }}{{ fail (printf "%s lists %v, which is not a collection name: letters, digits, '.', '_' and '-', starting with a letter or digit, at most 128 characters" $.what $c) }}{{ end -}}
{{- end -}}
{{- if ne (len $v) (len (uniq $v)) }}{{ fail (printf "%s lists a collection twice" .what) }}{{ end -}}
{{- $v | sortAlpha | toJson -}}
{{- end -}}

{{/* The tool groups that hold an entry for the knowledge base, with the collections each may read, as JSON: [{"name": <group>, "collections": [...]}], sorted by
name. The shared group is named by mcp.groupName; the others are the groups of mcp.endpoints that a profile lists the knowledge base on, and diagnostics when the
diagnostics server is on (its mirror entry always renders). Every refusal of ADR 0030 section 1 is made here. Empty list ([]) while the mode is "" or there is no
entry; the refusals about the lists are made in every mode. */}}
{{- define "oa.kbCallers" -}}
{{- $mode := include "oa.kbMode" . -}}
{{- $k := .Values.knowledge -}}
{{- $m := .Values.mcp -}}
{{- $acc := $k.access | default dict -}}
{{- $shared := include "oa.kbCollectionList" (dict "v" $acc.sharedGroupCollections "what" "knowledge.access.sharedGroupCollections") | fromJsonArray -}}
{{- if and (ne $mode "") (not $k.enabled) }}{{ fail "knowledge.access.mode needs knowledge.enabled=true: the check is made by the knowledge base" }}{{ end -}}
{{- if and (ne $mode "") (not $m.enabled) }}{{ fail "knowledge.access.mode needs mcp.enabled=true: a caller is a tool group, and the tool gateway holds the groups" }}{{ end -}}
{{- $entry := $k.mcp.entryName -}}
{{- /* the list of each group that has profiles with one; a profile on the shared group may not carry one */ -}}
{{- $lists := dict -}}
{{- range $p := ($m.profiles | default list) -}}
{{- if kindIs "map" $p -}}
{{- $g := include "oa.profileGroup" (dict "root" $ "profile" $p) -}}
{{- $has := hasKey $p "knowledgeCollections" -}}
{{- $l := list -}}
{{- if $has }}{{ $l = include "oa.kbCollectionList" (dict "v" $p.knowledgeCollections "what" (printf "mcp.profiles[%s].knowledgeCollections" (toString $p.name))) | fromJsonArray }}{{ end -}}
{{- if and $has (eq $g "") }}{{ fail (printf "mcp.profiles[%s].knowledgeCollections: the profile is on the shared tool group %q, where callers cannot be told apart by profile. Use knowledge.access.sharedGroupCollections for the shared group, or give the profile a tool group of its own (mcp.endpoints)" (toString $p.name) $m.groupName) }}{{ end -}}
{{- if and (ne $g "") (or $has (include "oa.kbProfileLists" (dict "root" $ "profile" $p))) -}}
{{- if hasKey $lists $g -}}
{{- if ne (toJson (get $lists $g).list) (toJson $l) }}{{ fail (printf "the profiles %q and %q are on the tool group %q but list different knowledgeCollections: the knowledge base tells tool groups apart, not profiles. Give the profiles the same list, or put them on groups of their own" (get $lists $g).by (toString $p.name) $g) }}{{ end -}}
{{- else -}}
{{- $_ := set $lists $g (dict "list" $l "by" (toString $p.name)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /* the groups that hold a kb entry */ -}}
{{- $out := list -}}
{{- if and $k.enabled $m.enabled -}}
{{- $out = append $out (dict "name" $m.groupName "collections" $shared) -}}
{{- if include "oa.epOn" . -}}
{{- $seen := list -}}
{{- range $p := ($m.profiles | default list) -}}
{{- $g := include "oa.profileGroup" (dict "root" $ "profile" $p) -}}
{{- if and (ne $g "") (ne $g "diagnostics") (not (has $g $seen)) (has $entry (include "oa.epMirrorKeys" (dict "root" $ "group" $g) | fromJsonArray)) -}}
{{- $seen = append $seen $g -}}
{{- $l := list -}}{{- if hasKey $lists $g }}{{ $l = (get $lists $g).list }}{{ end -}}
{{- $out = append $out (dict "name" $g "collections" $l) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if include "oa.diagOn" . -}}
{{- $l := list -}}{{- if hasKey $lists "diagnostics" }}{{ $l = (get $lists "diagnostics").list }}{{ end -}}
{{- $out = append $out (dict "name" "diagnostics" "collections" $l) -}}
{{- end -}}
{{- end -}}
{{- /* enforce: a profile that lists a knowledge tool while its group may read nothing is refused */ -}}
{{- if eq $mode "enforce" -}}
{{- range $p := ($m.profiles | default list) -}}
{{- if and (kindIs "map" $p) (include "oa.kbProfileLists" (dict "root" $ "profile" $p)) -}}
{{- $g := include "oa.profileGroup" (dict "root" $ "profile" $p) -}}
{{- $name := ternary $m.groupName $g (eq $g "") -}}
{{- range $c := $out -}}
{{- if and (eq $c.name $name) (not $c.collections) }}{{ fail (printf "knowledge.access.mode is enforce and the profile %q lists the knowledge tools, but its tool group %q may read no collection. %s" (toString $p.name) $name (ternary "Set knowledge.access.sharedGroupCollections." (printf "Set mcp.profiles[%s].knowledgeCollections." (toString $p.name)) (eq $g ""))) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $names := list -}}{{- range $c := $out }}{{ $names = append $names $c.name }}{{ end -}}
{{- $sorted := list -}}
{{- range $n := ($names | sortAlpha) }}{{ range $c := $out }}{{ if eq $c.name $n }}{{ $sorted = append $sorted $c }}{{ end }}{{ end }}{{ end -}}
{{- if eq $mode "" -}}[]{{- else -}}{{ $sorted | toJson }}{{- end -}}
{{- end -}}

{{/* The groups (by name; the shared group is mcp.groupName) that have a profile listing the knowledge tools. JSON list, sorted. For the warning of NOTES.txt. */}}
{{- define "oa.kbListingGroups" -}}
{{- $out := list -}}
{{- if and .Values.knowledge.enabled .Values.mcp.enabled -}}
{{- range $p := (.Values.mcp.profiles | default list) -}}
{{- if and (kindIs "map" $p) (include "oa.kbProfileLists" (dict "root" $ "profile" $p)) -}}
{{- $g := include "oa.profileGroup" (dict "root" $ "profile" $p) -}}
{{- $out = append $out (ternary $.Values.mcp.groupName $g (eq $g "")) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | uniq | sortAlpha | toJson -}}
{{- end -}}

{{/* "true" when the check is on (mode report or enforce). */}}
{{- define "oa.kbAccessOn" -}}
{{- if ne (include "oa.kbMode" .) "" -}}true{{- end -}}
{{- end -}}

{{/* The kb-access ConfigMap's access.json, compact and stable. */}}
{{- define "oa.kbAccessJson" -}}
{{- dict "mode" (include "oa.kbMode" .) "callers" (include "oa.kbCallers" . | fromJsonArray) | toJson -}}
{{- end -}}

{{/* The headerForward block of a kb entry in the group <group>. Argument: the group name. */}}
{{- define "oa.kbHeader" -}}
headerForward:
  addHeadersFromSecret:
    - {headerName: Authorization, valueSecretRef: {name: {{ printf "kb-caller-%s" . | quote }}, key: value}}
{{- end -}}
