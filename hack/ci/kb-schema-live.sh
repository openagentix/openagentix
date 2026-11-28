#!/usr/bin/env bash
# Live check of the graph schema of a collection (ADR 0030, slices 4 and 5) on the cluster of hack/ci/kb-access-live.sh, installed once more with
# hack/ci/kb-schema-ci-values.yaml (the knowledge graph and schemas on, mode enforce). Run after that install:
#   KB_SCHEMA=1 hack/ci/kb-schema-live.sh
# Opt-in: it does nothing without KB_SCHEMA=1. The e2e workflow runs it with the input kb_access.
#
# What it settles, with real calls: a schema is set with hack/kb-graph-schema.sh (YAML), a fact set that breaks it is refused (422) with the first violations
# named by place and rule, and nothing of it is stored; a fact set that fits is loaded; a schema change that the stored facts break is refused (409) with the
# same list and the old schema stays; the same body twice changes nothing; a version that is not higher is refused; a document loaded into a collection with a
# schema queues no extraction; deleting the schema keeps the facts; and the tool kb_graph_schema, called through the tool gateways, shows the schema of a
# collection the caller may read and answers for another group's collection byte for byte like a collection that has no schema. Synthetic data only.
# It never prints a value. Exit 1 when a check fails.
set -u
[ "${KB_SCHEMA:-0}" = 1 ] || { echo "kb-schema-live: set KB_SCHEMA=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
# the one guard of the live CI scripts (issue #212): kind or k3d only, a CI run or the named context, never kind-openagentix by hand; it reads the kubeconfig and nothing else
. "$(cd "$(dirname "$0")" && pwd)/lib/require-ci-context.sh"
require_ci_context kb-schema-live KB_ACCESS_CI_CONTEXT
cd "$(dirname "$0")/../.." || exit 1
MCPNS=${MCP_NAMESPACE:-mcp-tools}; KBNS=openagentix-knowledge
PIDS=(); TD=$(mktemp -d)
cleanup() { for p in "${PIDS[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done; rm -rf "$TD"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
obs() { printf '  observed: %s\n' "$1"; }
MARK=zebracrossing-ci-schema-3b9d

echo "# the objects"
check "the kb has KB_GRAPH_SCHEMAS_ENABLED=true" "$($K get deploy kb -n "$KBNS" -o json | jq -r '[.spec.template.spec.containers[0].env[]|select(.name=="KB_GRAPH_SCHEMAS_ENABLED")|.value]|join(",")')" true
check "the kb is Ready" "$($K get deploy kb -n "$KBNS" -o jsonpath='{.status.readyReplicas}')" 1
check "the mode is still enforce" "$($K get configmap kb-access -n "$KBNS" -o json | jq -r '.data["access.json"]|fromjson|.mode')" enforce
for v in tools-alpha tools-beta tools-sharedkb; do
  check "every backend of the vMCP $v is ready" "$($K get virtualmcpserver "$v" -n "$MCPNS" -o json | jq -r '[.status.discoveredBackends[]?|select(.status!="ready")|.name]|join(",")')" ""
done

echo "# the admin API, with the admin token (never printed)"
APORT=$((40000 + RANDOM % 5000))
$K port-forward -n "$KBNS" svc/kb "$APORT:8080" >/dev/null 2>&1 & PIDS+=($!)
sleep 4
ADM=$($K get secret kb-admin -n "$KBNS" -o jsonpath='{.data.KB_ADMIN_TOKEN}' | base64 -d)
api() {   # api <method> <path> [body file]: prints the status code, leaves the body in $TD/out
  local m=$1 p=$2 f=${3:-}
  if [ -n "$f" ]; then
    curl -s -m 60 -o "$TD/out" -w '%{http_code}' -X "$m" -K <(printf 'header = "Authorization: Bearer %s"\n' "$ADM") -H 'Content-Type: application/json' --data-binary @"$f" "http://127.0.0.1:$APORT$p"
  else
    curl -s -m 60 -o "$TD/out" -w '%{http_code}' -X "$m" -K <(printf 'header = "Authorization: Bearer %s"\n' "$ADM") "http://127.0.0.1:$APORT$p"
  fi
}
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$APORT/v1/collections/ci-schema/graph/schema")
check "the schema route refuses a call with no admin token (401)" "$CODE" 401

echo "# hack/kb-graph-schema.sh sets a schema from a YAML file"
cat > "$TD/schema.yaml" <<'EOF'
version: 1
entityTypes:
  - {name: case, key: "Case DSP-[0-9]{4}-[0-9]{4}", description: A dispute case of the records service}
  - {name: merchant, key: "M-[0-9]{3} .+"}
  - {name: rule}
relationTypes:
  - {name: disputes_charge_at, from: [case], to: [merchant]}
  - {name: applies_to, from: [rule], to: [case, merchant]}
EOF
export KB_URL="http://127.0.0.1:$APORT" KB_ADMIN_TOKEN="$ADM"
OUT=$(hack/kb-graph-schema.sh ci-schema "$TD/schema.yaml" 2>&1); RC=$?
check "the script stores the schema (exit 0)" "$RC" 0
check "and says what it stored" "$(grep -c 'stored the graph schema of ci-schema: version 1, 3 entity types, 2 relation types, replaced the previous one' <<<"$OUT")" 1
OUT=$(hack/kb-graph-schema.sh ci-schema "$TD/schema.yaml" 2>&1)
check "the same file again changes nothing" "$(grep -c 'no change (identical' <<<"$OUT")" 1
check "GET returns the body, the version and the hash" "$(api GET /v1/collections/ci-schema/graph/schema >/dev/null; jq -r '[.version, (.sha256|length), (.body.entityTypes|length)]|join(" ")' "$TD/out")" "1 64 3"
unset KB_URL KB_ADMIN_TOKEN

echo "# a fact set that breaks the schema is refused, with the violations named, and nothing is stored"
cat > "$TD/bad.json" <<'EOF'
{"entities":[
  {"name":"Case DSP-2025-0001","type":"case"},
  {"name":"Case 0002","type":"case"},
  {"name":"Corner Shop","type":"merchant"},
  {"name":"Gizmo","type":"gadget"}],
 "relations":[
  {"source":"Case DSP-2025-0001","predicate":"disputes_charge_at","target":"Corner Shop"},
  {"source":"Case DSP-2025-0001","predicate":"owns","target":"Gizmo"}]}
EOF
CODE=$(api PUT /v1/collections/ci-schema/graph/factsets/bad "$TD/bad.json")
check "the answer is 422" "$CODE" 422
check "it names the violations by place and rule: two keys, a type and a predicate" "$(jq -r '[.violations[]|.at+" "+.rule]|sort|join(",")' "$TD/out")" "entities[1] key,entities[2] key,entities[3] type,relations[1] predicate"
check "it repeats nothing the operator wrote" "$(grep -c -E 'Corner Shop|Gizmo|Case 0002' "$TD/out")" 0
check "nothing of the refused fact set is stored" "$(api GET /v1/collections/ci-schema/graph/factsets/bad)" 404
check "the collection has no manual entity" "$(api GET /v1/collections/ci-schema/graph/stats >/dev/null; jq -r '.manual.entities' "$TD/out")" 0

echo "# a fact set that fits is loaded"
cat > "$TD/good.json" <<'EOF'
{"entities":[
  {"name":"Case DSP-2025-0001","type":"case"},
  {"name":"M-560 Corner Shop","type":"merchant","aliases":["M-560"]},
  {"name":"Chargeback rule","type":"rule"}],
 "relations":[
  {"source":"Case DSP-2025-0001","predicate":"disputes_charge_at","target":"M-560 Corner Shop","note":"the case is about a charge at the shop"},
  {"source":"Chargeback rule","predicate":"applies_to","target":"Case DSP-2025-0001"}]}
EOF
check "the fitting fact set is stored (200)" "$(api PUT /v1/collections/ci-schema/graph/factsets/ok "$TD/good.json")" 200
check "its three entities and two relations are in the graph" "$(api GET /v1/collections/ci-schema/graph/stats >/dev/null; jq -r '[.manual.entities,.manual.relations]|join(" ")' "$TD/out")" "3 2"

echo "# a schema change that the stored facts break is refused, and the old schema stays"
cat > "$TD/v2.json" <<'EOF'
{"version":2,"entityTypes":[{"name":"case"},{"name":"merchant"}],"relationTypes":[{"name":"disputes_charge_at","from":["case"],"to":["merchant"]}]}
EOF
CODE=$(api PUT /v1/collections/ci-schema/graph/schema "$TD/v2.json")
check "removing the type rule and the relation applies_to is refused (409)" "$CODE" 409
check "the answer names the stored fact set and what breaks" "$(jq -r '[.violations[]|.at+" "+.rule]|sort|join(",")' "$TD/out")" "factsets/ok/entities[2] type,factsets/ok/relations[1] predicate"
check "the schema is still version 1" "$(api GET /v1/collections/ci-schema/graph/schema >/dev/null; jq -r '.version' "$TD/out")" 1
cat > "$TD/v1b.json" <<'EOF'
{"version":1,"entityTypes":[{"name":"case"}],"relationTypes":[]}
EOF
check "another body with a version that is not higher is refused (409)" "$(api PUT /v1/collections/ci-schema/graph/schema "$TD/v1b.json")" 409
check "and the sentence says it is the version" "$(jq -r '.error' "$TD/out" | grep -c 'version')" 1
echo "# the steps of the ADR: add what is needed (version 2), then drop the old, once nothing uses it"
cat > "$TD/v2ok.json" <<'EOF'
{"version":2,"entityTypes":[{"name":"case","key":"Case DSP-[0-9]{4}-[0-9]{4}"},{"name":"merchant","key":"M-[0-9]{3} .+"},{"name":"rule"},{"name":"note"}],
 "relationTypes":[{"name":"disputes_charge_at","from":["case"],"to":["merchant"]},{"name":"applies_to","from":["rule"],"to":["case","merchant"]}]}
EOF
check "a schema that the facts fit and that adds a type is taken (200)" "$(api PUT /v1/collections/ci-schema/graph/schema "$TD/v2ok.json")" 200

echo "# a collection with a schema gets no extraction"
mkdir -p "$TD/doc"; { echo "# Note"; echo "Case DSP-2025-0001 is about a charge at M-560 Corner Shop. $MARK"; } > "$TD/doc/note.md"
KB_URL="http://127.0.0.1:$APORT" KB_ADMIN_TOKEN="$ADM" hack/kb-ingest.sh "$TD/doc" ci-schema >/dev/null 2>&1
check "the document was loaded" "$?" 0
check "it is searchable (it is chunked and indexed as before)" "$(curl -s -m 20 -o /dev/null -w '%{http_code}' -K <(printf 'header = "Authorization: Bearer %s"\n' "$ADM") "http://127.0.0.1:$APORT/v1/collections")" 200
sleep 5
check "no extraction job was queued for it" "$(api GET /v1/collections/ci-schema/graph/stats >/dev/null; jq -r '.jobs|[.pending,.done,.failed]|join(" ")' "$TD/out")" "0 0 0"

echo "# the tool kb_graph_schema through the tool gateways"
for c in ci-alpha ci-beta; do
  cp "$TD/schema.yaml" "$TD/schema-$c.yaml"
  sed -i.bak "s/A dispute case of the records service/The schema of $c/" "$TD/schema-$c.yaml"
  KB_URL="http://127.0.0.1:$APORT" KB_ADMIN_TOKEN="$ADM" hack/kb-graph-schema.sh "$c" "$TD/schema-$c.yaml" >/dev/null 2>&1
  check "a schema is set on $c (the documents of the isolation check are there, with no extracted fact)" "$?" 0
done
mcp_token() { $K create token default -n "$MCPNS" --audience "$1" --duration 20m 2>/dev/null; }
mcp_post() {
  local port=$1 tf=$2 sid=$3 body=$4 out hdr=()
  [ "$sid" = - ] || hdr=(-H "Mcp-Session-Id: $sid")
  out=$(curl -s -m 30 -D "$tf.h" -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' ${hdr[@]+"${hdr[@]}"} -d "$body" "http://127.0.0.1:$port/mcp" 2>/dev/null)
  if grep -q '^data:' <<<"$out"; then sed -n 's/^data: *//p' <<<"$out" | tail -1; else printf '%s' "$out"; fi
}
mcp_open() {
  mcp_post "$1" "$2" - '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"kb-schema-live","version":"0"}}}' >/dev/null
  local sid; sid=$(grep -i '^mcp-session-id:' "$2.h" | tr -d '\r' | awk '{print $2}')
  [ -z "$sid" ] || mcp_post "$1" "$2" "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  printf '%s' "${sid:--}"
}
# install.sh replaces the CA ConfigMap that the values name on every run: put the cluster CA back, allow the keys to be read without a login, and restart the tool
# gateway to pick both up, as hack/ci/endpoints-live.sh does
$K get configmap kube-root-ca.crt -n "$MCPNS" -o json | jq --arg n ci-apiserver-ca '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:.metadata.namespace},data:{"ca.crt":.data["ca.crt"]}}' | $K apply -f - >/dev/null
$K create clusterrolebinding ci-jwks-anonymous --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated --dry-run=client -o yaml | $K apply -f - >/dev/null
$K rollout restart deployment/tools-alpha -n "$MCPNS" >/dev/null 2>&1
$K rollout status deployment/tools-alpha -n "$MCPNS" --timeout=180s >/dev/null 2>&1 || echo "       (vMCP tools-alpha: the restart was not confirmed)"
GPORT=$((30000 + RANDOM % 5000))
$K port-forward -n "$MCPNS" svc/vmcp-tools-alpha "$GPORT:4483" >/dev/null 2>&1 & PIDS+=($!)
mcp_token openagentix-vmcp-alpha > "$TD/tok"
sleep 4
SID=-
for _ in $(seq 1 6); do SID=$(mcp_open "$GPORT" "$TD/tok"); [ "$SID" != - ] && break; sleep 5; done
check "a session on the vMCP of alpha" "$([ "$SID" != - ] && echo open || echo none)" open
if [ "$SID" = - ]; then
  echo "       no session: the answer to initialize was:"
  curl -s -i -m 20 -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TD/tok")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"kb-schema-live","version":"0"}}}' "http://127.0.0.1:$GPORT/mcp" 2>&1 | head -c 500 | sed 's/^/         /'
  echo
fi
N=10
call() {   # call <arguments json>: the text of the result of kb_graph_schema as the alpha group sees it
  N=$((N+1))
  mcp_post "$GPORT" "$TD/tok" "$SID" "{\"jsonrpc\":\"2.0\",\"id\":$N,\"method\":\"tools/call\",\"params\":{\"name\":\"knowledge-alpha_kb_graph_schema\",\"arguments\":$1}}" \
    | jq -r '((if (.error!=null) or (.result.isError==true) then "ERR " else "" end) + ([.result.content[]?.text]|join("\n")) + (.error.message // ""))' 2>/dev/null
}
LIST=$(mcp_post "$GPORT" "$TD/tok" "$SID" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | jq -r '[.result.tools[]?.name]|join(" ")' 2>/dev/null)
check "the alpha profile lists the schema tool next to the other knowledge tools" "$(grep -c 'knowledge-alpha_kb_graph_schema' <<<"$LIST")" 1
OWN=$(call '{"collection":"ci-alpha"}')
check "alpha sees the schema of its own collection, with the version" "$(grep -c 'Graph schema of collection ci-alpha (version 1' <<<"$OWN")/$(grep -c 'The schema of ci-alpha' <<<"$OWN")/$(grep -c 'disputes_charge_at: case -> merchant' <<<"$OWN")" 1/1/1
OUT_B=$(call '{"collection":"ci-beta"}'); MISS=$(call '{"collection":"ci-nowhere"}')
check "alpha asking for the schema of beta's collection sees nothing of it" "$(grep -c -E 'The schema of ci-beta|disputes_charge_at' <<<"$OUT_B")" 0
check "that answer is byte for byte the answer for a collection that does not exist (the name asked for aside)" "$([ "${OUT_B//ci-beta/X}" = "${MISS//ci-nowhere/X}" ] && echo identical || echo different)" identical
ALL=$(call '{}')
check "with no collection alpha sees only the schemas of its own collections" "$(grep -q 'Graph schema of collection ci-alpha' <<<"$ALL" && echo own)/$(grep -q -E 'ci-beta|ci-schema' <<<"$ALL" && echo other || echo none)" "own/none"

echo "# delete keeps the facts"
check "DELETE of the schema is 204" "$(api DELETE /v1/collections/ci-schema/graph/schema)" 204
check "the fact set and its entities are still there" "$(api GET /v1/collections/ci-schema/graph/stats >/dev/null; jq -r '[.manual.factsets,.manual.entities,.manual.relations]|join(" ")' "$TD/out")" "1 3 2"
check "GET of the schema is now 404" "$(api GET /v1/collections/ci-schema/graph/schema)" 404

echo "# no value and no document text in any log"
LEAK=0
for ns in "$KBNS" "$MCPNS" toolhive-system; do
  for p in $($K get pods -n "$ns" -o name 2>/dev/null); do LEAK=$((LEAK + $($K logs -n "$ns" "$p" --all-containers --tail=4000 2>/dev/null | grep -cE "$MARK|zebracrossing-ci|pelican harbour|Corner Shop|$ADM"))); done
done
check "no document text, entity name or admin token in any log line" "$LEAK" 0

echo
echo "kb-schema-live: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
