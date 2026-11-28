#!/usr/bin/env bash
# Knowledge-graph canary: ingest the fictional corpus, wait for entity extraction, then check that the graph links
# facts that no single document states together. Prints PASS or FAIL.
#
#   hack/kb-graph-canary.sh
#
# Needs the knowledge graph on (VALUES_FILE=components/knowledge/graph-demo-values.yaml ./install.sh). Spends tokens of
# the extraction model (a model call per document window) and sends the corpus text to it.
#
# What it does, in order:
#   1. ingests components/knowledge/graph-sample/docs into the collection `graph-canary` (hack/kb-ingest.sh; the only write)
#   2. polls GET /v1/collections/graph-canary/graph/stats until no extraction job is pending
#   3. prints the stats and, when the kb log is readable, the tokens the extraction calls reported
#   4. kb_search with the canary question (vector baseline: printed, never judged)
#   5. kb_graph_search for the question, then kb_graph_paths from the service to the person
#   6. PASS when the chain Orion -> Quill -> Teal -> Vane-3 and Orion -> Basalt -> Mira Okafor are found and the edges
#      cite the five chain documents
#
# Transport is the one hack/kb-ingest.sh uses: `kubectl port-forward` to the kb Service (it arrives on the pod's loopback, so no
# NetworkPolicy entry is needed), the admin token read from the cluster Secret into a variable and passed to curl through a file
# descriptor. Set KB_URL (and KB_ADMIN_TOKEN) to skip the port-forward.
#
# Env: KB_NAMESPACE=openagentix-knowledge  KB_SERVICE=kb  KB_ADMIN_SECRET=kb-admin  KB_ADMIN_KEY=KB_ADMIN_TOKEN
#      KB_URL  KB_ADMIN_TOKEN  KUBECTL=kubectl  KUBE_CONTEXT  CANARY_COLLECTION=graph-canary  CANARY_TIMEOUT=900 (seconds)
#      CANARY_SKIP_INGEST=1 (query what is already there)
# Exit: 0 PASS, 1 FAIL, 2 usage or environment problem.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DIR="$HERE/../components/knowledge/graph-sample/docs"
COLL=${CANARY_COLLECTION:-graph-canary}
TIMEOUT=${CANARY_TIMEOUT:-900}
NS=${KB_NAMESPACE:-openagentix-knowledge}; SVC=${KB_SERVICE:-kb}
SECRET=${KB_ADMIN_SECRET:-kb-admin}; SKEY=${KB_ADMIN_KEY:-KB_ADMIN_TOKEN}
K=${KUBECTL:-kubectl}; KARGS=(); [ -z "${KUBE_CONTEXT:-}" ] || KARGS+=(--context "$KUBE_CONTEXT")
QUESTION="A cluster in region Vane-3 had a disk outage. Which service calls the API that stores its data in that cluster, and who is the on-call engineer of the team that owns that service?"
CHAIN_DOCS="orion-ownership orion-dependencies quill-storage basalt-on-call teal-region-incident"

die(){ echo "ERROR: $*" >&2; exit 2; }
[[ "$COLL" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || die "invalid collection name '$COLL'"
[ -d "$DIR" ] || die "corpus not found: $DIR"
for c in jq curl; do command -v "$c" >/dev/null || die "$c is required"; done

PF_PID=""; PF_LOG=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup(){
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi
  [ -z "$PF_LOG" ] || rm -f "$PF_LOG"
}
trap cleanup EXIT

TOKEN=${KB_ADMIN_TOKEN:-}
if [ -z "${KB_URL:-}" ]; then
  [ -n "$TOKEN" ] || TOKEN=$($K ${KARGS[@]+"${KARGS[@]}"} get secret "$SECRET" -n "$NS" -o jsonpath="{.data.$SKEY}" | base64 -d)
  PF_LOG=$(mktemp)
  $K ${KARGS[@]+"${KARGS[@]}"} port-forward -n "$NS" "svc/$SVC" :8080 >"$PF_LOG" 2>&1 &
  PF_PID=$!
  PORT=""
  for _ in $(seq 1 30); do
    PORT=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$PF_LOG" | head -1)
    [ -n "$PORT" ] && break
    kill -0 "$PF_PID" 2>/dev/null || die "port-forward failed: $(cat "$PF_LOG")"
    sleep 1
  done
  [ -n "$PORT" ] || die "port-forward did not come up"
  KB_URL="http://127.0.0.1:$PORT"
fi
[ -n "$TOKEN" ] || die "no admin token (set KB_ADMIN_TOKEN when you use KB_URL)"
KB_URL=${KB_URL%/}
for _ in $(seq 1 30); do curl -fsS -m 3 "$KB_URL/readyz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS -m 3 "$KB_URL/readyz" >/dev/null || die "kb at $KB_URL is not ready"

# admin GET: the token goes through a descriptor, never argv
admin_get(){ curl -sS -m 20 -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") "$KB_URL$1"; }
# mcp_call <tool> <json arguments> -> the JSON-RPC result object (stateless endpoint: no session needed)
# With knowledge.access.mode set (ADR 0030) /mcp needs the value of a tool group: the shared group's, from its Secret in the tools namespace, unless KB_MCP_AUTHORIZATION
# ("Bearer <value>") is given. The collection of the canary must then be in knowledge.access.sharedGroupCollections. The header goes to curl through a descriptor.
KB_MCP_HDR=""
if [ -n "${KB_MCP_AUTHORIZATION:-}" ]; then KB_MCP_HDR="Authorization: $KB_MCP_AUTHORIZATION"
else
  # shellcheck source=hack/kb-callers.sh
  . "$HERE/kb-callers.sh"
  KB_MCP_HDR=$(kb_caller_header "$K ${KARGS[*]+${KARGS[*]}}" "${KB_MCP_GROUP:-tools}" "${MCP_NAMESPACE:-mcp-tools}")
fi
mcp_cfg(){ [ -z "$KB_MCP_HDR" ] || printf 'header = "%s"\n' "$KB_MCP_HDR"; }
mcp_call(){
  jq -n --arg t "$1" --argjson a "$2" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$t,arguments:$a}}' \
    | curl -sS -m 60 -K <(mcp_cfg) -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data-binary @- "$KB_URL/mcp" \
    | jq -c '.result // {isError:true,content:[{type:"text",text:"no result"}]}'
}
tool_text(){ jq -r '[.content[]?|select(.type=="text")|.text]|join("\n")' <<<"$1"; }

# --- 0. the graph must be on: the stats route exists only then --------------------------------------------------
code=$(curl -sS -m 20 -o /dev/null -w '%{http_code}' -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") "$KB_URL/v1/collections/$COLL/graph/stats" || true)
[ "$code" = 200 ] || die "GET graph/stats answered $code: is knowledge.kb.graph.enabled true? (VALUES_FILE=components/knowledge/graph-demo-values.yaml ./install.sh)"

# --- 1. ingest ---------------------------------------------------------------------------------------------------
START=$(date +%s)
if [ "${CANARY_SKIP_INGEST:-0}" != 1 ]; then
  echo "== ingest components/knowledge/graph-sample/docs into '$COLL'"
  KB_URL="$KB_URL" KB_ADMIN_TOKEN="$TOKEN" bash "$HERE/kb-ingest.sh" "$DIR" "$COLL"
fi

# --- 2. wait for extraction ---------------------------------------------------------------------------------------
echo "== waiting for extraction jobs (up to ${TIMEOUT}s)"
stats='{}'
deadline=$((START + TIMEOUT))
while :; do
  stats=$(admin_get "/v1/collections/$COLL/graph/stats") || stats='{}'
  pending=$(jq -r '.jobs.pending // -1' <<<"$stats")
  [ "$pending" = 0 ] && break
  [ "$(date +%s)" -lt "$deadline" ] || { echo "FAIL: $pending extraction job(s) still pending after ${TIMEOUT}s"; jq -c . <<<"$stats"; exit 1; }
  printf '   pending=%s done=%s failed=%s\n' "$pending" "$(jq -r '.jobs.done' <<<"$stats")" "$(jq -r '.jobs.failed' <<<"$stats")"
  sleep 5
done

# --- 3. stats and tokens ------------------------------------------------------------------------------------------
echo "== graph stats"
jq . <<<"$stats"
if [ -n "$PF_PID" ]; then
  # the worker logs one line per finished window with the tokens the gateway reported (no content)
  tokens=$($K ${KARGS[@]+"${KARGS[@]}"} logs -n "$NS" "deploy/$SVC" --since "$(( $(date +%s) - START + 120 ))s" 2>/dev/null \
    | jq -R -s -r --arg c "$COLL" '[split("\n")[]|fromjson?|select(.msg=="extraction done" and .collection==$c)|.tokens]|if length==0 then "unknown (no extraction log line in range)" else (add|tostring)+" in "+(length|tostring)+" model call(s)" end' 2>/dev/null) || tokens="unknown (kb log not readable)"
  echo "tokens used by extraction (from the kb log): $tokens"
else
  echo "tokens used by extraction: unknown when KB_URL is given (read the kb log lines 'extraction done')"
fi
failed=$(jq -r '.jobs.failed' <<<"$stats")
if [ "$failed" != 0 ]; then echo "FAIL: $failed extraction job(s) failed; last error code: $(jq -r '.last_error_code' <<<"$stats")"; exit 1; fi

# --- 4. vector baseline (printed, never judged) ----------------------------------------------------------------------
echo "== baseline: kb_search \"$QUESTION\""
r=$(mcp_call kb_search "$(jq -nc --arg q "$QUESTION" --arg c "$COLL" '{query:$q,collection:$c,top_k:5}')")
jq -r '.structuredContent.results[]?|"  \(.score*1000|round/1000)  \(.document_id)  \(.title)"' <<<"$r"
[ "$(jq -r '(.structuredContent.results // [])|length' <<<"$r")" != 0 ] || echo "  (no results)"

# --- 5. graph queries --------------------------------------------------------------------------------------------
echo "== graph: kb_graph_search \"$QUESTION\" (3 hops)"
g1=$(mcp_call kb_graph_search "$(jq -nc --arg q "$QUESTION" --arg c "$COLL" '{query:$q,collection:$c,hops:3}')")
tool_text "$g1" | sed -n '1,40p'
echo "== graph: kb_graph_paths from Orion to Mira Okafor"
g2=$(mcp_call kb_graph_paths "$(jq -nc --arg c "$COLL" '{from:"Orion",to:"Mira Okafor",collection:$c,max_hops:3}')")
tool_text "$g2" | sed -n '1,30p'

# --- 6. verdict --------------------------------------------------------------------------------------------------------
# A path "matches" a chain when its entities, in order or reversed, name the chain's entities one by one (case-insensitive,
# a name may carry a word such as "cluster"). Citations are the document ids on the matching path's edges.
match_chain(){  # <result json> <name1> <name2> ... -> prints the cited document ids, one per line; empty if no path matches
  jq -r --args '
    def hit($names): . as $e | ($e|length) == ($names|length) and ([range(0; $names|length)] | all(. as $i | ($e[$i]|ascii_downcase|contains($names[$i]))));
    ([$ARGS.positional[]|ascii_downcase]) as $n
    | [.structuredContent.paths[]? | select((.entities|hit($n)) or (.entities|reverse|hit($n)))] | first // empty
    | .edges[].document_id' "${@:2}" <<<"$1"
}
c1=$(match_chain "$g1" "vane-3" "teal" "quill" "orion")
c2=$(match_chain "$g2" "orion" "basalt" "mira okafor")
cited=$(printf '%s\n%s\n' "$c1" "$c2" | sort -u | sed '/^$/d')
missing=""
for d in $CHAIN_DOCS; do grep -qx "$d" <<<"$cited" || missing+="$d "; done
echo "== verdict"
echo "path Vane-3 <- Teal <- Quill <- Orion: $([ -n "$c1" ] && echo found || echo NOT FOUND)"
echo "path Orion -> Basalt -> Mira Okafor:   $([ -n "$c2" ] && echo found || echo NOT FOUND)"
echo "documents cited by those edges: $(tr '\n' ' ' <<<"$cited")"
if [ -n "$c1" ] && [ -n "$c2" ] && [ -z "$missing" ]; then
  echo "PASS: the graph connects the Vane-3 outage to Mira Okafor through five documents, each cited"
  exit 0
fi
why=""
[ -n "$c1" ] || why+="the Vane-3 to Orion path is missing; "
[ -n "$c2" ] || why+="the Orion to Mira Okafor path is missing; "
[ -z "$missing" ] || why+="documents not cited: $missing"
echo "FAIL: $why"
exit 1
