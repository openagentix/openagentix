#!/usr/bin/env bash
# Chart tests of ADR 0030, slice 3: knowledge.access and mcp.profiles[].knowledgeCollections. Sourced by run.sh (it shares eq, q, count, docs,
# render_err, and the variables CHART, REPO). Every check here was written before the chart code and failed first (see the pull request).
echo "# kb access (ADR 0030, slice 3): per tool group lists, the callers' values by reference, off by default"
KX="$(dirname "$0")/.kb-values.yaml"
KX2="$(dirname "$0")/.kb-values2.yaml"
trap 'rm -f "$KX" "$KX2"' EXIT
cat > "$KX" <<YAML
controlPlane:
  apiServerCIDRs: [172.18.0.0/24]
notify:
  enabled: true
knowledge:
  access:
    mode: enforce
    sharedGroupCollections: [openagentix, graph-canary]
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
    - name: parts
      url: http://parts.parts-ns.svc.cluster.local:8080/mcp
      group: dealer
      auth:
        header: {name: Authorization, secret: {name: parts-mcp-auth, key: value}}
      ingress:
        podSelector: {app: parts}
        port: 8080
  profiles:
    - name: disputes
      codeMode: false
      knowledgeCollections: [coll-disputes]
      tools:
        records: [get_case]
        knowledge: [kb_search]
    - name: dealer
      codeMode: false
      knowledgeCollections: [coll-dealer]
      tools:
        parts: [get_part]
        knowledge: [kb_search]
    - name: lookup
      codeMode: false
      tools:
        knowledge: [kb_search]
YAML
KA=(-f "$KX")
# kv <yq filter>: the dedicated values with one edit, written to $KX2 (use -f "$KX2")
kv() { rm -f "$KX2"; yq -y "$1" "$KX" > "$KX2"; }
# kr <description> <sentence part> <helm args...>: the render must fail and the error must contain the sentence part
kr() { local d=$1 s=$2; shift 2; eq "$d" "$(render_err "$@" | /usr/bin/grep -cF -- "$s")" 1; }
sha() { helm template openagentix "$CHART" -n openagentix-system "$@" 2>&1 | shasum -a 256; }

echo "# kb access: off by default, byte-identical"
K0=$(sha)
eq "defaults: mode empty, no shared list" "$(yq -c '.knowledge.access' "$CHART/values.yaml")" '{"mode":"","sharedGroupCollections":[]}'
eq "mode \"\" with every other access value set renders byte-identical to the default" "$(sha --set 'knowledge.access.mode=' --set 'knowledge.access.sharedGroupCollections={a,b}')" "$K0"
eq "knowledge.access=null renders byte-identical to the default" "$(sha --set knowledge.access=null)" "$K0"
KP0=$(sha -f "$KX" --set knowledge.access.mode=)
KP1=$(yq -y '.mcp.profiles |= map(del(.knowledgeCollections))' "$KX" | yq -y '.knowledge.access.mode=""' > "$KX2" && sha -f "$KX2")
eq "mode \"\": the profile lists have no effect on the render (byte-identical to the render without them)" "$KP0" "$KP1"
DD=$(docs)
eq "default: no kb-access ConfigMap, no kb-callers volume, no KB_ACCESS env, no header on a knowledge entry" "$(count "$DD" '(.metadata.name=="kb-access") or (tojson|test("kb-callers|KB_ACCESS|kb-caller-"))')" 0
DR=$(helm template openagentix "$CHART" -n openagentix-system -f "$KX" --set knowledge.access.mode= 2>&1)
eq "mode \"\" with the full values: no object of the check" "$(printf '%s' "$DR" | /usr/bin/grep -c 'kb-caller\|KB_ACCESS\|kb-access')" 0

echo "# kb access: the render with mode enforce"
D=$(docs "${KA[@]}")
eq "on: the dedicated values render" "$([ -z "$(render_err "${KA[@]}")" ] && echo rendered || echo failed)" rendered
ACC=$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="kb-access")|.data["access.json"]')
eq "ConfigMap kb-access is in the knowledge namespace" "$(q "$D" '.[]|select(.kind=="ConfigMap" and .metadata.name=="kb-access")|.metadata.namespace')" openagentix-knowledge
eq "access.json: the mode" "$(jq -r '.mode' <<<"$ACC")" enforce
eq "access.json: one caller per tool group that holds a knowledge entry, sorted by name" "$(jq -r '[.callers[].name]|join(" ")' <<<"$ACC")" "dealer disputes tools"
eq "access.json: the shared group (mcp.groupName) reads sharedGroupCollections" "$(jq -r '.callers[]|select(.name=="tools")|.collections|join(" ")' <<<"$ACC")" "graph-canary openagentix"
eq "access.json: a group of its own reads the list of its profile (disputes)" "$(jq -r '.callers[]|select(.name=="disputes")|.collections|join(" ")' <<<"$ACC")" coll-disputes
eq "access.json: a group of its own reads the list of its profile (dealer)" "$(jq -r '.callers[]|select(.name=="dealer")|.collections|join(" ")' <<<"$ACC")" coll-dealer
eq "access.json holds names and lists only: its keys" "$(jq -c '[keys, (.callers|map(keys)|unique)]' <<<"$ACC")" '[["callers","mode"],[["collections","name"]]]'
KBD='.[]|select(.kind=="Deployment" and .metadata.name=="kb")'
KBC="$KBD|.spec.template.spec"
eq "kb: KB_ACCESS_FILE and the callers directory are set" "$(q "$D" "$KBC|.containers[0].env|map(select(.name==\"KB_ACCESS_FILE\" or .name==\"KB_ACCESS_CALLERS_DIR\")|.name+\"=\"+.value)|join(\" \")")" "KB_ACCESS_FILE=/etc/openagentix/kb-access/access.json KB_ACCESS_CALLERS_DIR=/var/run/secrets/openagentix/kb-callers"
eq "kb: access.json is a read-only ConfigMap mount" "$(q "$D" "$KBC|.containers[0].volumeMounts|map(select(.name==\"kb-access\")|.mountPath+\" \"+(.readOnly|tostring))|join(\"\")")" "/etc/openagentix/kb-access true"
eq "kb: the callers are a read-only mount of the Secret kb-callers" "$(q "$D" "$KBC|[(.containers[0].volumeMounts|map(select(.name==\"kb-callers\")|.mountPath+\" \"+(.readOnly|tostring))|join(\"\")),(.volumes|map(select(.name==\"kb-callers\")|.secret.secretName)|join(\"\"))]|join(\" \")")" "/var/run/secrets/openagentix/kb-callers true kb-callers"
eq "kb: one file per tool group, named by the group, no more" "$(q "$D" "$KBC|.volumes|map(select(.name==\"kb-callers\")|.secret.items|map(.key+\"=\"+.path)|join(\" \"))|join(\"\")")" "dealer=dealer disputes=disputes tools=tools"
eq "kb: the pod template carries a checksum of access.json (a changed list rolls the pod)" "$(q "$D" "$KBD|.spec.template.metadata.annotations[\"openagentix.io/kb-access-checksum\"]|test(\"^[0-9a-f]{64}\$\")")" true
kv '.knowledge.access.sharedGroupCollections=["only-one"]'
eq "the checksum changes with a list" "$([ "$(q "$(docs -f "$KX2")" "$KBD|.spec.template.metadata.annotations[\"openagentix.io/kb-access-checksum\"]")" != "$(q "$D" "$KBD|.spec.template.metadata.annotations[\"openagentix.io/kb-access-checksum\"]")" ] && echo changed || echo same)" changed
ENT='.[]|select(.kind=="MCPServerEntry")'
hdr() { q "$D" "$ENT|select(.metadata.name==\"$1\")|.spec.headerForward.addHeadersFromSecret|map(.headerName+\" \"+.valueSecretRef.name+\" \"+.valueSecretRef.key)|join(\";\")"; }
eq "the shared entry sends Authorization from the Secret of the shared group" "$(hdr knowledge)" "Authorization kb-caller-tools value"
eq "the mirror of group disputes sends the value of that group" "$(hdr knowledge-disputes)" "Authorization kb-caller-disputes value"
eq "the mirror of group dealer sends the value of that group" "$(hdr knowledge-dealer)" "Authorization kb-caller-dealer value"
eq "every knowledge entry has the header (none without)" "$(q "$D" "[$ENT|select(.spec.remoteUrl|test(\"/kb[.]\"))|select(.spec.headerForward==null)|.metadata.name]|length")" 0
eq "the endpoint entries keep exactly their own header, nothing else" "$(q "$D" "[$ENT|select(.metadata.name==\"records\" or .metadata.name==\"parts\")|.spec.headerForward.addHeadersFromSecret|length]|join(\",\")")" "1,1"
eq "the delivery entries have no header" "$(q "$D" "[$ENT|select(.metadata.name|test(\"^delivery\"))|select(.spec.headerForward!=null)]|length")" 0
eq "every auth config stays unauthenticated" "$(q "$D" '[.[]|select(.kind=="MCPExternalAuthConfig")|.spec.type]|unique|join(",")')" unauthenticated
echo "# kb access: no value in the render, no pass-through of caller headers"
eq "the chart renders no Secret object (the values are the installer's)" "$(count "$D" '.kind=="Secret"')" 0
eq "no pass-through of the caller's headers on any object (no plaintext header, no forward-all)" "$(count "$D" 'tojson|test("Plaintext|passThrough|passthrough|forwardAll|forwardHeaders|trustedHeaders";"i")')" 0
eq "every headerForward in the render uses addHeadersFromSecret and nothing else" "$(q "$D" '[.[]|select(.spec.headerForward!=null)|.spec.headerForward|keys[]]|unique|join(",")')" addHeadersFromSecret
eq "the Secret names kb-caller-* appear only in MCPServerEntry objects" "$(q "$D" '[.[]|select(tojson|test("kb-caller-"))|.kind]|unique|join(",")')" MCPServerEntry
eq "the Secret kb-callers appears only in the kb Deployment" "$(q "$D" '[.[]|select(tojson|test("kb-callers"))|.kind+"/"+.metadata.name]|join(",")')" Deployment/kb
eq "a plain 'Bearer' value is in no object that the checks added (access.json, the kb pod)" "$(printf '%s' "$ACC" | /usr/bin/grep -c 'Bearer')" 0
D2=$(docs --set knowledge.access.mode=report -f "$KX")
eq "report: the same objects render with mode report" "$(jq -r '.mode' <<<"$(q "$D2" '.[]|select(.kind=="ConfigMap" and .metadata.name=="kb-access")|.data["access.json"]')")" report

echo "# kb access: the ingress policy of the kb stays as it was"
eq "kb-ingress admits the same peers with the check on and off" "$(q "$D" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-ingress")|.spec.ingress')" "$(q "$(docs -f "$KX" --set knowledge.access.mode=)" '.[]|select(.kind=="NetworkPolicy" and .metadata.name=="kb-ingress")|.spec.ingress')"

echo "# kb access: the admin token and a group's value must not be the same Secret (review L3)"
kr "the admin Secret may not be the Secret of the callers" 'knowledge.kb.adminSecret.name' -f "$KX" --set knowledge.kb.adminSecret.name=kb-callers
kr "the admin Secret may not be the Secret of a group either" 'knowledge.kb.adminSecret.name' -f "$KX" --set knowledge.kb.adminSecret.name=kb-caller-tools
eq "while the mode is empty the admin Secret name is not checked (the render is as before)" "$([ -z "$(render_err -f "$KX" --set knowledge.access.mode= --set knowledge.kb.adminSecret.name=kb-callers)" ] && echo rendered || echo failed)" rendered

echo "# kb access: a mode of report allows empty lists, enforce does not for a profile that lists the tools"
kv '.knowledge.access.mode="report" | .knowledge.access.sharedGroupCollections=[]'
eq "report with an empty shared list renders" "$([ -z "$(render_err -f "$KX2")" ] && echo rendered || echo failed)" rendered

echo "# kb access: the refusals, each names its fix"
kv '.knowledge.access.mode="enfroce"'
kr "a mode that is not \"\", report or enforce is refused" 'knowledge.access.mode "enfroce" is not valid' -f "$KX2"
kv '.knowledge.access.mode=true'
kr "a mode that is not a string (yes/true) is refused: quote it" 'knowledge.access.mode must be a quoted string' -f "$KX2"
kr "the mode needs knowledge.enabled" 'knowledge.access.mode needs knowledge.enabled=true' -f "$KX" --set knowledge.enabled=false --set 'mcp.endpoints=null' --set 'mcp.profiles=null'
kr "the mode needs mcp.enabled" 'knowledge.access.mode needs mcp.enabled=true' -f "$KX" --set mcp.enabled=false --set 'mcp.endpoints=null' --set 'mcp.profiles=null'
kv '.knowledge.access.sharedGroupCollections=["good","bad name"]'
kr "a shared collection name that the knowledge base would not accept is refused" 'which is not a collection name' -f "$KX2"
kv '.knowledge.access.sharedGroupCollections=["a","a"]'
kr "a shared collection listed twice is refused" 'knowledge.access.sharedGroupCollections lists a collection twice' -f "$KX2"
kv '.knowledge.access.sharedGroupCollections="a"'
kr "a shared list that is not a list is refused" 'knowledge.access.sharedGroupCollections must be a list' -f "$KX2"
kv '.mcp.profiles[0].knowledgeCollections=["Bad Name"]'
kr "a profile collection name that is not valid is refused" 'mcp.profiles[disputes].knowledgeCollections lists Bad Name' -f "$KX2"
kv '.mcp.profiles[0].knowledgeCollections=["a","a"]'
kr "a profile collection listed twice is refused" 'mcp.profiles[disputes].knowledgeCollections lists a collection twice' -f "$KX2"
kv '.mcp.profiles[2].knowledgeCollections=["x"]'
kr "a list on a profile of the shared group is refused, and the sentence names sharedGroupCollections" 'Use knowledge.access.sharedGroupCollections' -f "$KX2"
kr "the same refusal applies while the mode is empty (a use case cannot ship a list that means nothing)" 'Use knowledge.access.sharedGroupCollections' -f "$KX2" --set knowledge.access.mode=
kv '.mcp.profiles += [{"name":"disputes2","codeMode":false,"knowledgeCollections":["other"],"tools":{"records":["get_case"],"knowledge":["kb_search"]}}]'
kr "two profiles on one tool group with different lists are refused" 'are on the tool group "disputes" but list different knowledgeCollections' -f "$KX2"
kv '.mcp.profiles += [{"name":"disputes2","codeMode":false,"tools":{"records":["get_case"],"knowledge":["kb_search"]}}]'
kr "a second profile on the group that lists the tools and has no list differs from a group list: refused" 'but list different knowledgeCollections' -f "$KX2"
kv '.mcp.profiles += [{"name":"disputes2","codeMode":false,"knowledgeCollections":["coll-disputes"],"tools":{"records":["get_case"],"knowledge":["kb_search"]}}]'
eq "two profiles on one group with the same list render" "$([ -z "$(render_err -f "$KX2")" ] && echo rendered || echo failed)" rendered
kv '.knowledge.access.sharedGroupCollections=[]'
kr "enforce: a profile on the shared group lists the tools and the shared list is empty: refused, names sharedGroupCollections" 'its tool group "tools" may read no collection. Set knowledge.access.sharedGroupCollections.' -f "$KX2"
kv '.mcp.profiles[0].knowledgeCollections=[]'
kr "enforce: a profile of a group of its own lists the tools and its list is empty: refused, names the profile's list" 'its tool group "disputes" may read no collection. Set mcp.profiles[disputes].knowledgeCollections.' -f "$KX2"
kv 'del(.mcp.profiles[0].knowledgeCollections)'
kr "enforce: a profile of a group of its own with no list at all: refused" 'its tool group "disputes" may read no collection' -f "$KX2"
kv '.mcp.profiles[0].knowledgeCollections=[] | .knowledge.access.mode=""'
eq "an empty list is accepted while the mode is empty, with no effect (a use case ships its list first)" "$([ -z "$(render_err -f "$KX2")" ] && echo rendered || echo failed)" rendered

echo "# kb access: the diagnostics group is a caller when its server is on"
kv '.diagnostics={"enabled":true,"apiServerCIDRs":["172.18.0.0/24"],"cluster":{"enabled":true,"logNamespaces":["rca-demo"],"statusNamespaces":[]}}'
DG=$(docs -f "$KX2")
eq "diagnostics on: the render succeeds with the check on" "$([ -z "$(render_err -f "$KX2")" ] && echo rendered || echo failed)" rendered
eq "diagnostics on: its knowledge mirror sends the value of the group diagnostics" "$(q "$DG" "$ENT|select(.metadata.name==\"knowledge-diagnostics\")|.spec.headerForward.addHeadersFromSecret|map(.valueSecretRef.name)|join(\",\")")" kb-caller-diagnostics
eq "diagnostics on: the group is a caller with an empty list (nothing to read), so its backend stays ready" "$(jq -r '.callers[]|select(.name=="diagnostics")|(.collections|length|tostring)' <<<"$(q "$DG" '.[]|select(.kind=="ConfigMap" and .metadata.name=="kb-access")|.data["access.json"]')")" 0

echo "# kb access: the warning for installs with Helm alone (NOTES.txt)"
# NOTES.txt is not part of the render and `helm install --dry-run` needs a cluster, so the test renders it as a template of a copy of the chart
notes() { local T; T=$(mktemp -d); cp -R "$CHART" "$T/c"; mv "$T/c/templates/NOTES.txt" "$T/c/templates/notes-test.yaml"; helm template openagentix "$T/c" -n openagentix-system -s templates/notes-test.yaml "$@" 2>&1; rm -rf "$T"; }
kv '.knowledge.access.mode=""'
eq "mode empty and profiles on three tool groups list the knowledge tools: the warning names the groups" "$(notes -f "$KX2" | /usr/bin/grep -c 'WARNING: no isolation in the knowledge base.*3 tool groups (dealer, disputes, tools)')" 1
eq "mode report: no warning" "$(notes -f "$KX" --set knowledge.access.mode=report | /usr/bin/grep -c WARNING)" 0
eq "mode enforce: no warning" "$(notes -f "$KX" | /usr/bin/grep -c WARNING)" 0
eq "the defaults (one group at most): no warning" "$(notes | /usr/bin/grep -c WARNING)" 0
eq "helm template does not print the notes, so the render is the one compared above" "$(helm template openagentix "$CHART" -n openagentix-system -f "$KX2" 2>&1 | /usr/bin/grep -c 'no isolation')" 0

echo "# kb access: the values of the live job render (hack/ci/kb-access-ci-values.yaml)"
CIQ=(-f "$REPO/components/quickstart/values.yaml" -f "$REPO/hack/ci/kb-access-ci-values.yaml" --set 'controlPlane.apiServerCIDRs={10.0.0.0/24}')
for m in report enforce; do
  DC=$(docs "${CIQ[@]}" -f "$REPO/hack/ci/kb-access-$m-values.yaml")
  eq "the live job's values with mode $m render, with three callers (alpha, beta, tools) and their lists" "$(jq -r '.mode+" "+([.callers[]|.name+"="+(.collections|join("+"))]|join(" "))' <<<"$(q "$DC" '.[]|select(.kind=="ConfigMap" and .metadata.name=="kb-access")|.data["access.json"]')")" "$m alpha=ci-alpha beta=ci-beta tools=ci-shared"
done
DC=$(docs "${CIQ[@]}")
eq "the live job's values with no mode render no isolation object" "$(count "$DC" '.metadata.name=="kb-access" or (tojson|test("kb-caller"))')" 0
