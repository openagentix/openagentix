#!/usr/bin/env bash
# Live check of the knowledge base isolation (ADR 0030, slice 3) on a cluster that ./install.sh set up with hack/ci/kb-access-ci-values.yaml. Run once per phase,
# after the install of that phase (see the header of hack/ci/kb-access-ci-values.yaml):
#   KB_ACCESS=1 KB_ACCESS_PHASE=off      with no mode:           as before, every group reads every collection (nothing is checked)
#   KB_ACCESS=1 KB_ACCESS_PHASE=report   with mode report:       the same reads, and the knowledge base logs the caller and what enforce would change
#   KB_ACCESS=1 KB_ACCESS_PHASE=enforce  with mode enforce:      each group reads only its collection
# Opt-in: it does nothing without KB_ACCESS=1, so a stray local run never touches the cluster you are on. The e2e workflow runs it on request (input kb_access).
#
# The calls are real MCP calls through the tool gateways (the vMCP of each profile), which is where the value of the group is added: the tool server of a group is
# the vMCP pod of that group. In this job the gateways trust the API server's own tokens (hack/ci/kb-access-ci-setup.sh), so the script can make a token.
# Groups: alpha (collection ci-alpha), beta (ci-beta) and the shared group `tools` (ci-shared). The documents are synthetic. Each holds a marker that must
# not appear in any log. It never prints a caller's value. Exit 1 when a check fails.
set -u
[ "${KB_ACCESS:-0}" = 1 ] || { echo "kb-access-live: set KB_ACCESS=1 to run this against the current cluster (it is opt-in)"; exit 0; }
PHASE=${KB_ACCESS_PHASE:-}
case "$PHASE" in off|report|enforce) ;; *) echo "kb-access-live: set KB_ACCESS_PHASE to off, report or enforce" >&2; exit 2;; esac
K=${KUBECTL:-kubectl}
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in
  kind-*|k3d-*) ;;
  *) echo "kb-access-live: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind or k3d context. Nothing was changed." >&2; exit 2;;
esac
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${KB_ACCESS_CI_CONTEXT:-}" != "$CTX_NOW" ]; then
  echo "kb-access-live: refusing to run on '$CTX_NOW': it is not a CI run (GITHUB_ACTIONS is not true) and KB_ACCESS_CI_CONTEXT does not name this context. Nothing was changed." >&2
  exit 2
fi
cd "$(dirname "$0")/../.." || exit 1
MCPNS=${MCP_NAMESPACE:-mcp-tools}; KBNS=openagentix-knowledge
PIDS=(); TD=$(mktemp -d)
cleanup() { for p in "${PIDS[@]:-}"; do [ -z "$p" ] || kill "$p" 2>/dev/null; done; rm -rf "$TD"; $K delete pod kb-probe -n kb-ci --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got '$2', want '$3'"; fi; }
obs() { printf '  observed: %s\n' "$1"; }
MARK_A=zebracrossing-ci-alpha-7f3a; MARK_B=zebracrossing-ci-beta-91c2; MARK_S=zebracrossing-ci-shared-5d0e

echo "# phase $PHASE: the documents (synthetic), loaded as the operator, through the admin API"
mkdocs() {   # mkdocs <dir> <marker> <repeat>: one document; the more often it says pelican, the better it ranks for the query "pelican"
  mkdir -p "$1"; { echo "# Note $2"; for _ in $(seq 1 "$3"); do echo "pelican harbour ledger $2"; done; } > "$1/note.md"
}
mkdocs "$TD/a" "$MARK_A" 1; mkdocs "$TD/b" "$MARK_B" 6; mkdocs "$TD/s" "$MARK_S" 1
hack/kb-ingest.sh "$TD/a" ci-alpha >/dev/null && hack/kb-ingest.sh "$TD/b" ci-beta >/dev/null && hack/kb-ingest.sh "$TD/s" ci-shared >/dev/null
check "the three collections were loaded" "$?" 0

echo "# the objects are as the phase says"
CM=$($K get configmap kb-access -n "$KBNS" -o json 2>/dev/null || echo '{}')
case "$PHASE" in
  off)
    check "no ConfigMap kb-access, no Secret kb-callers: the default render has no isolation objects" "$(jq -r '.metadata.name // "none"' <<<"$CM")/$($K get secret kb-callers -n "$KBNS" -o name 2>/dev/null || echo none)" "none/none" ;;
  *)
    check "the ConfigMap kb-access holds mode $PHASE" "$(jq -r '.data["access.json"]|fromjson|.mode' <<<"$CM")" "$PHASE"
    check "it names three callers: alpha, beta and the shared group tools" "$(jq -r '.data["access.json"]|fromjson|[.callers[].name]|sort|join(",")' <<<"$CM")" "alpha,beta,tools"
    check "each caller has its own collection, the shared group the shared list" "$(jq -r '.data["access.json"]|fromjson|[.callers[]|.name+"="+(.collections|join("+"))]|sort|join(" ")' <<<"$CM")" "alpha=ci-alpha beta=ci-beta tools=ci-shared"
    check "the Secret kb-callers has one key per group, and no other" "$($K get secret kb-callers -n "$KBNS" -o json | jq -r '.data|keys|join(",")')" "alpha,beta,tools"
    check "each tool group has its Secret kb-caller-<group> in the tools namespace" "$(for g in alpha beta tools; do $K get secret "kb-caller-$g" -n "$MCPNS" -o name 2>/dev/null; done | wc -l | tr -d ' ')" 3
    check "the two Secrets of a group hold the same value" "$([ "$($K get secret kb-callers -n "$KBNS" -o jsonpath='{.data.alpha}')" = "$($K get secret kb-caller-alpha -n "$MCPNS" -o jsonpath='{.data.value}')" ] && echo same || echo different)" same
    check "the values differ between groups" "$([ "$($K get secret kb-callers -n "$KBNS" -o jsonpath='{.data.alpha}')" != "$($K get secret kb-callers -n "$KBNS" -o jsonpath='{.data.beta}')" ] && echo different || echo same)" different ;;
esac
check "the knowledge base is Ready" "$($K get deploy kb -n "$KBNS" -o jsonpath='{.status.readyReplicas}')" 1
for v in tools-alpha tools-beta tools-sharedkb; do
  check "every backend of the vMCP $v is ready (the knowledge base still answers its entry)" "$($K get virtualmcpserver "$v" -n "$MCPNS" -o json | jq -r '[.status.discoveredBackends[]?|select(.status!="ready")|.name]|join(",")')" ""
done
check "no condition DiscoveredAuthConfig-* of any vMCP is False" "$($K get virtualmcpserver -n "$MCPNS" -o json | jq '[.items[].status.conditions[]?|select((.type|startswith("DiscoveredAuthConfig-")) and .status=="False")]|length')" 0

echo "# real calls through the gateways"
mcp_token() { $K create token default -n "$MCPNS" --audience "$1" --duration 20m 2>/dev/null; }
mcp_post() {  # mcp_post <port> <token file> <session id or -> <json>: prints the JSON-RPC answer
  local port=$1 tf=$2 sid=$3 body=$4 out hdr=()
  [ "$sid" = - ] || hdr=(-H "Mcp-Session-Id: $sid")
  out=$(curl -s -m 30 -D "$tf.h" -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$tf")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' ${hdr[@]+"${hdr[@]}"} -d "$body" "http://127.0.0.1:$port/mcp" 2>/dev/null)
  if grep -q '^data:' <<<"$out"; then sed -n 's/^data: *//p' <<<"$out" | tail -1; else printf '%s' "$out"; fi
}
mcp_open() {
  mcp_post "$1" "$2" - '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"kb-access-live","version":"0"}}}' >/dev/null
  local sid; sid=$(grep -i '^mcp-session-id:' "$2.h" | tr -d '\r' | awk '{print $2}')
  [ -z "$sid" ] || mcp_post "$1" "$2" "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  printf '%s' "${sid:--}"
}
# one port-forward, token and session per profile
declare -A PORT SID
n=0
for p in alpha beta sharedkb; do
  n=$((n+1)); PORT[$p]=$((30000 + RANDOM % 5000 + n * 7))
  $K port-forward -n "$MCPNS" "svc/vmcp-tools-$p" "${PORT[$p]}:4483" >/dev/null 2>&1 & PIDS+=($!)
  mcp_token "openagentix-vmcp-$p" > "$TD/tok-$p"
done
sleep 4
for p in alpha beta sharedkb; do
  SID[$p]=-
  for _ in $(seq 1 6); do SID[$p]=$(mcp_open "${PORT[$p]}" "$TD/tok-$p"); [ "${SID[$p]}" != - ] && break; sleep 5; done
  if [ "${SID[$p]}" = - ]; then
    # what the first attempt did, and what the vMCP says: the status and the start of the answer, never a token
    echo "       no session on $p: the answer to initialize was:"
    curl -s -i -m 20 -K <(printf 'header = "Authorization: Bearer %s"\n' "$(cat "$TD/tok-$p")") -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"kb-access-live","version":"0"}}}' "http://127.0.0.1:${PORT[$p]}/mcp" 2>&1 | head -c 600 | sed 's/^/         /'
    echo
    $K logs -n "$MCPNS" "deploy/tools-$p" --tail=15 2>&1 | cut -c1-300 | sed 's/^/         vmcp: /'
  fi
  check "a session on the vMCP of $p" "$([ "${SID[$p]}" != - ] && echo open || echo none)" open
done
tool_name() { case "$1" in sharedkb) echo "knowledge_$2";; *) echo "knowledge-$1_$2";; esac; }
CALLN=10
# call <profile> <tool without prefix> <arguments json>: the text of the result, and "ERR" first when the call failed
call() {
  local p=$1 t=$2 a=$3 r; CALLN=$((CALLN+1))
  r=$(mcp_post "${PORT[$p]}" "$TD/tok-$p" "${SID[$p]}" "{\"jsonrpc\":\"2.0\",\"id\":$CALLN,\"method\":\"tools/call\",\"params\":{\"name\":\"$(tool_name "$p" "$t")\",\"arguments\":$a}}")
  jq -r '((if (.error!=null) or (.result.isError==true) then "ERR " else "" end) + ([.result.content[]?.text]|join("\n")) + (.error.message // ""))' <<<"$r" 2>/dev/null
}
LIST_A=$(call alpha kb_list_collections '{}'); LIST_B=$(call beta kb_list_collections '{}'); LIST_S=$(call sharedkb kb_list_collections '{}')
SEARCH_A=$(call alpha kb_search '{"query":"pelican","top_k":10}'); SEARCH_B=$(call beta kb_search '{"query":"pelican","top_k":10}'); SEARCH_S=$(call sharedkb kb_search '{"query":"pelican","top_k":10}')
has() { grep -c -F -- "$2" <<<"$1"; }

case "$PHASE" in
  off|report)
    echo "# $PHASE: nothing is refused or filtered, as before"
    check "alpha lists all three collections" "$(has "$LIST_A" ci-alpha)/$(has "$LIST_A" ci-beta)/$(has "$LIST_A" ci-shared)" 1/1/1
    check "beta lists all three collections" "$(has "$LIST_B" ci-alpha)/$(has "$LIST_B" ci-beta)/$(has "$LIST_B" ci-shared)" 1/1/1
    check "a search with no collection by alpha reaches the other group's document (no isolation in this phase)" "$(has "$SEARCH_A" "$MARK_B")" 1
    check "the shared group reads the same" "$(has "$LIST_S" ci-beta)" 1
    ;;
  enforce)
    echo "# enforce: each group lists and searches only its own collection"
    check "alpha lists only ci-alpha" "$(has "$LIST_A" ci-alpha)/$(has "$LIST_A" ci-beta)/$(has "$LIST_A" ci-shared)" 1/0/0
    check "beta lists only ci-beta" "$(has "$LIST_B" ci-alpha)/$(has "$LIST_B" ci-beta)/$(has "$LIST_B" ci-shared)" 0/1/0
    check "the shared tool server lists only ci-shared" "$(has "$LIST_S" ci-alpha)/$(has "$LIST_S" ci-beta)/$(has "$LIST_S" ci-shared)" 0/0/1
    check "alpha: a search with no collection finds its own document, though beta's ranks better for the query" "$(has "$SEARCH_A" "$MARK_A")/$(has "$SEARCH_A" "$MARK_B")/$(has "$SEARCH_A" "$MARK_S")" 1/0/0
    check "beta: a search with no collection finds only its document" "$(has "$SEARCH_B" "$MARK_A")/$(has "$SEARCH_B" "$MARK_B")/$(has "$SEARCH_B" "$MARK_S")" 0/1/0
    check "the shared tool server: a search with no collection finds only its document" "$(has "$SEARCH_S" "$MARK_A")/$(has "$SEARCH_S" "$MARK_B")/$(has "$SEARCH_S" "$MARK_S")" 0/0/1
    OUT_A=$(call alpha kb_search '{"query":"pelican","collection":"ci-beta"}'); MISS_A=$(call alpha kb_search '{"query":"pelican","collection":"ci-nowhere"}')
    check "alpha searching ci-beta gets no result" "$(has "$OUT_A" "$MARK_B")" 0
    check "that answer is byte for byte the answer for a collection that does not exist" "$([ "$OUT_A" = "$MISS_A" ] && echo identical || echo different)" identical
    OUT_B=$(call beta kb_search '{"query":"pelican","collection":"ci-alpha"}'); MISS_B=$(call beta kb_search '{"query":"pelican","collection":"ci-nowhere"}')
    check "beta searching ci-alpha: the same, byte for byte" "$([ "$OUT_B" = "$MISS_B" ] && echo identical || echo different)" identical
    GET_OWN=$(call alpha kb_get_document '{"document_id":"note","collection":"ci-alpha"}')
    check "alpha reads its own document" "$(has "$GET_OWN" "$MARK_A")" 1
    GET_OUT=$(call alpha kb_get_document '{"document_id":"note","collection":"ci-beta"}'); GET_MISS=$(call alpha kb_get_document '{"document_id":"note","collection":"ci-nowhere"}')
    check "alpha opening beta's document: an error that does not show its text" "$(has "$GET_OUT" "$MARK_B")/$(printf '%s' "$GET_OUT" | grep -c '^ERR')" 0/1
    check "that answer is byte for byte the answer for a collection that does not exist" "$([ "$GET_OUT" = "$GET_MISS" ] && echo identical || echo different)" identical
    GET_NOCOLL=$(call alpha kb_get_document '{"document_id":"note"}')
    check "the same document id exists in all three collections: with no collection alpha gets its own, not 'more than one collection'" "$(has "$GET_NOCOLL" "$MARK_A")/$(has "$GET_NOCOLL" 'more than one')" 1/0
    ;;
esac

echo "# a pod that the network policy admits and that is not a tool server"
KBURL="http://kb.$KBNS.svc.cluster.local:8080"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
probe() {   # probe <authorization header value or ->: the HTTP status of an initialize from the probe pod
  local h=()
  [ "$1" = - ] || h=(-H "Authorization: $1")
  $K delete pod kb-probe -n kb-ci --ignore-not-found --wait=true >/dev/null 2>&1
  $K run kb-probe -n kb-ci --labels app=kb-probe --image=curlimages/curl:8.10.1 --restart=Never --rm -i --quiet --command -- \
    curl -s -m 10 -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' ${h[@]+"${h[@]}"} -d "$INIT" "$KBURL/mcp" 2>/dev/null | tail -c 3
}
case "$PHASE" in
  enforce)
    check "the probe pod with no value gets 401" "$(probe -)" 401
    check "the probe pod with a made-up value gets 401" "$(probe 'Bearer not-a-value-of-any-group')" 401
    ;;
  *)
    check "the probe pod with no value is answered (200): nothing is refused in phase $PHASE" "$(probe -)" 200
    ;;
esac

echo "# the admin API is unchanged: a caller's value does not write"
APORT=$((40000 + RANDOM % 5000))
$K port-forward -n "$KBNS" svc/kb "$APORT:8080" >/dev/null 2>&1 & PIDS+=($!)
sleep 3
if [ "$PHASE" != off ]; then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -K <(printf 'header = "Authorization: %s"\n' "$($K get secret kb-caller-alpha -n "$MCPNS" -o jsonpath='{.data.value}' | base64 -d)") -H 'Content-Type: application/json' -d '{"text":"x"}' "http://127.0.0.1:$APORT/v1/collections/ci-alpha/documents/should-not-exist")
  check "a PUT with the value of a tool group is refused (401): writes stay with the admin token" "$CODE" 401
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -K <(printf 'header = "Authorization: %s"\n' "$($K get secret kb-caller-alpha -n "$MCPNS" -o jsonpath='{.data.value}' | base64 -d)") "http://127.0.0.1:$APORT/v1/collections")
  check "a GET of the admin API with the value of a tool group is refused (401)" "$CODE" 401
fi
check "/healthz and /readyz answer with no value" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APORT/healthz")/$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APORT/readyz")" 200/200

echo "# the log of the knowledge base"
KBLOG=$($K logs -n "$KBNS" deploy/kb --tail=4000 2>/dev/null)
case "$PHASE" in
  off)    check "no tool call line carries a caller (the log is as before)" "$(grep -c '"msg":"tool call".*"caller"' <<<"$KBLOG")" 0 ;;
  report)
    # one call that enforce would leave as it is, and one that it would change, each read from the log by its time
    T0=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
    call alpha kb_search '{"query":"pelican","collection":"ci-alpha"}' >/dev/null; sleep 2
    L1=$($K logs -n "$KBNS" deploy/kb --since-time="$T0" 2>/dev/null | grep '"msg":"tool call"')
    check "a search of its own collection by alpha is logged with caller alpha, and not as outside the list" "$(grep -c '"caller":"alpha"' <<<"$L1")/$(grep -c 'outside_list' <<<"$L1")" 1/0
    T1=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
    call alpha kb_search '{"query":"pelican","collection":"ci-beta"}' >/dev/null; sleep 2
    L2=$($K logs -n "$KBNS" deploy/kb --since-time="$T1" 2>/dev/null | grep '"msg":"tool call"')
    check "a search of beta's collection by alpha is logged with caller alpha and outside_list true (and was answered)" "$(grep -c '"caller":"alpha"' <<<"$L2")/$(grep -c '"outside_list":true' <<<"$L2")" 1/1
    T2=$(date -u +%Y-%m-%dT%H:%M:%SZ); sleep 1
    call beta kb_search '{"query":"pelican"}' >/dev/null; call sharedkb kb_list_collections '{}' >/dev/null; sleep 2
    L3=$($K logs -n "$KBNS" deploy/kb --since-time="$T2" 2>/dev/null | grep '"msg":"tool call"')
    check "a search with no collection by beta (it would be filtered) is logged with caller beta and outside_list true" "$(grep '"tool":"kb_search"' <<<"$L3" | grep -c '"caller":"beta".*"outside_list":true')" 1
    check "the shared group is a caller too, named by its group (tools)" "$(grep -c '"caller":"tools"' <<<"$L3")" 1
    ;;
esac
LEAK=0
for g in alpha beta tools; do
  V=$($K get secret "kb-caller-$g" -n "$MCPNS" -o jsonpath='{.data.value}' 2>/dev/null | base64 -d 2>/dev/null); RAW=${V#Bearer }
  if [ -n "$RAW" ]; then
    for ns in "$KBNS" "$MCPNS" toolhive-system; do
      for p in $($K get pods -n "$ns" -o name 2>/dev/null); do LEAK=$((LEAK + $($K logs -n "$ns" "$p" --all-containers --tail=4000 2>/dev/null | grep -cF -e "$RAW"))); done
    done
    LEAK=$((LEAK + $($K get configmap,virtualmcpserver,mcpserverentry,mcpgroup,mcpexternalauthconfig,networkpolicy -A -o yaml 2>/dev/null | grep -cF -e "$RAW")))
  fi
  unset V RAW
done
check "no value of a tool group is in any log (the knowledge base, the tool gateways, the operator) or in any ConfigMap or ToolHive object" "$LEAK" 0
DOCLEAK=0
for ns in "$KBNS" "$MCPNS" toolhive-system; do
  for p in $($K get pods -n "$ns" -o name 2>/dev/null); do DOCLEAK=$((DOCLEAK + $($K logs -n "$ns" "$p" --all-containers --tail=4000 2>/dev/null | grep -cE "zebracrossing-ci|pelican harbour"))); done
done
check "no document text is in any log line" "$DOCLEAK" 0

echo "# what the isolation does not stop (ADR 0030 section 7), recorded"
SA=$($K get pods -n "$MCPNS" -l "app=virtualmcpserver,toolhive-name=tools-alpha" -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null)
obs "kubectl auth can-i get secret/kb-caller-beta -n $MCPNS, as the ServiceAccount of the alpha tool server ($SA): '$($K auth can-i get secret/kb-caller-beta -n "$MCPNS" --as="system:serviceaccount:$MCPNS:$SA" 2>/dev/null || true)' (ADR 0030 expects yes until ADR 0031 is built: isolation against a compromised tool server is not claimed)"

echo
echo "kb-access-live phase $PHASE: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
