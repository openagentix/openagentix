#!/usr/bin/env bash
# Load a hand-written catalogue of entities and relations (a "fact set") into a collection's knowledge graph through the
# kb admin API. No model is involved: the facts are visible to kb_graph_search, kb_graph_entity and kb_graph_paths at once,
# marked "curated" and mixed with the facts extracted from documents.
#
#   hack/kb-graph-load.sh <collection> <factset-id> <file.yaml|file.yml|file.json>
#
# - The file is {source_uri?, entities:[{name,type,description?,aliases?}], relations:[{source,predicate,target,note?}]}
#   (components/knowledge/graph-sample/org-catalogue.yaml is an example). Every relation names two entities of the same file.
# - Idempotent: one PUT /v1/collections/<collection>/graph/factsets/<factset-id>, which replaces that fact set atomically.
#   The same file twice changes nothing; a changed file removes the facts that are no longer in it. Facts of the same
#   collection that came from documents, or from another fact set, are not touched. To remove a fact set:
#   curl -X DELETE .../graph/factsets/<id> (same auth), or KB_GRAPH_LOAD_DELETE=1 with this script (the file is then not read).
# - YAML is converted to JSON with `yq` (the jq wrapper `yq -c .`, or the Go `yq -o=json -I=0 .`); the script stops with a
#   clear message when yq is missing. JSON needs only jq.
# - Transport and auth are those of hack/kb-ingest.sh: `kubectl port-forward` to the kb Service, the admin token read from the
#   cluster Secret into a shell variable and handed to curl through a descriptor (never in argv, never printed). Set KB_URL
#   (and KB_ADMIN_TOKEN) to skip the port-forward.
# - Needs the knowledge graph on (knowledge.kb.graph.enabled); the route does not exist otherwise (the script then says so).
#
# Env: KB_NAMESPACE=openagentix-knowledge  KB_SERVICE=kb  KB_ADMIN_SECRET=kb-admin  KB_ADMIN_KEY=KB_ADMIN_TOKEN
#      KB_URL  KB_ADMIN_TOKEN  KUBECTL=kubectl  KUBE_CONTEXT (optional)
#      KB_GRAPH_LOAD_DRY_RUN=1 (convert and count, contact nothing)   KB_GRAPH_LOAD_DELETE=1 (delete the fact set instead)
# Exit: 0 done, 1 the server refused or could not be reached, 2 usage or environment problem.
set -euo pipefail

COLLECTION=${1:-}; ID=${2:-}; FILE=${3:-}
DELETE=${KB_GRAPH_LOAD_DELETE:-0}
usage(){ echo "usage: $0 <collection> <factset-id> <file.yaml|file.json>" >&2; exit 2; }
[ -n "$COLLECTION" ] && [ -n "$ID" ] || usage
[[ "$COLLECTION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || { echo "ERROR: invalid collection name '$COLLECTION'" >&2; exit 2; }
[[ "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$ ]] || { echo "ERROR: invalid fact set id '$ID' (letters, digits and . _ : -, at most 200)" >&2; exit 2; }

[ "$DELETE" = 1 ] || [ -f "$FILE" ] || { echo "ERROR: $FILE is not a file" >&2; usage; }

NS=${KB_NAMESPACE:-openagentix-knowledge}; SVC=${KB_SERVICE:-kb}
SECRET=${KB_ADMIN_SECRET:-kb-admin}; SKEY=${KB_ADMIN_KEY:-KB_ADMIN_TOKEN}
K=${KUBECTL:-kubectl}; KARGS=(); [ -z "${KUBE_CONTEXT:-}" ] || KARGS+=(--context "$KUBE_CONTEXT")
DRY=${KB_GRAPH_LOAD_DRY_RUN:-0}
command -v jq >/dev/null || { echo "ERROR: jq is required" >&2; exit 2; }
command -v curl >/dev/null || [ "$DRY" = 1 ] || { echo "ERROR: curl is required" >&2; exit 2; }

BODY=""; RESP=""
cleanup(){
  if [ -n "${PF_PID:-}" ]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi
  [ -z "${PF_LOG:-}" ] || rm -f "$PF_LOG"
  [ -z "$BODY" ] || rm -f "$BODY"
  [ -z "$RESP" ] || rm -f "$RESP"
}
PF_PID=""; PF_LOG=""
trap cleanup EXIT

if [ "$DELETE" != 1 ]; then
  BODY=$(mktemp)
  case $(printf '%s' "$FILE" | tr '[:upper:]' '[:lower:]') in
    *.yaml|*.yml)
      command -v yq >/dev/null || { echo "ERROR: yq is required to read a YAML file (pip install yq, or brew install yq); or give a .json file" >&2; exit 2; }
      if yq --version 2>&1 | grep -qi mikefarah; then yq -o=json -I=0 . "$FILE" > "$BODY"; else yq -c . "$FILE" > "$BODY"; fi \
        || { echo "ERROR: $FILE is not valid YAML" >&2; exit 2; } ;;
    *.json) cp "$FILE" "$BODY" ;;
    *) echo "ERROR: $FILE must end in .yaml, .yml or .json" >&2; exit 2 ;;
  esac
  jq -e 'type=="object" and (.entities|type=="array") and ((.relations // [])|type=="array")' "$BODY" >/dev/null 2>&1 \
    || { echo "ERROR: $FILE must be an object with an \"entities\" list (and optionally \"relations\" and \"source_uri\")" >&2; exit 2; }
  # the API wants both lists; a file without relations means none
  jq -c '.relations //= []' "$BODY" > "$BODY.n" && mv "$BODY.n" "$BODY"
  printf 'fact set %s/%s: %s entities, %s relations (%s bytes)\n' "$COLLECTION" "$ID" \
    "$(jq '.entities|length' "$BODY")" "$(jq '.relations|length' "$BODY")" "$(wc -c < "$BODY" | tr -d ' ')"
  [ "$DRY" != 1 ] || { echo "dry run: nothing was sent"; exit 0; }
elif [ "$DRY" = 1 ]; then
  echo "dry run: would delete fact set $COLLECTION/$ID"; exit 0
fi

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
    kill -0 "$PF_PID" 2>/dev/null || { echo "ERROR: port-forward failed: $(cat "$PF_LOG")" >&2; exit 1; }
    sleep 1
  done
  [ -n "$PORT" ] || { echo "ERROR: port-forward did not come up" >&2; exit 1; }
  KB_URL="http://127.0.0.1:$PORT"
fi
[ -n "$TOKEN" ] || { echo "ERROR: no admin token (set KB_ADMIN_TOKEN when you use KB_URL)" >&2; exit 2; }
KB_URL=${KB_URL%/}

for _ in $(seq 1 30); do curl -fsS -m 3 "$KB_URL/readyz" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS -m 3 "$KB_URL/readyz" >/dev/null || { echo "ERROR: kb at $KB_URL is not ready" >&2; exit 1; }

URL="$KB_URL/v1/collections/$COLLECTION/graph/factsets/$(jq -rn --arg v "$ID" '$v|@uri')"
RESP=$(mktemp)
# -K reads the header from a descriptor: the token is not in argv.
if [ "$DELETE" = 1 ]; then
  code=$(curl -sS -m 60 -o "$RESP" -w '%{http_code}' -X DELETE -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") "$URL") || code=000
else
  code=$(curl -sS -m 60 -o "$RESP" -w '%{http_code}' -X PUT -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") \
    -H 'Content-Type: application/json' --data-binary @"$BODY" "$URL") || code=000
fi
case $code in
  200) printf 'loaded %s/%s: %s entities, %s relations, %s\n' "$COLLECTION" "$ID" "$(jq -r .entities "$RESP")" "$(jq -r .relations "$RESP")" \
         "$(jq -r 'if .changed then "replaced the previous version" else "no change (identical to what is stored)" end' "$RESP")" ;;
  204) echo "deleted fact set $COLLECTION/$ID" ;;
  404) if [ "$DELETE" = 1 ]; then echo "fact set $COLLECTION/$ID does not exist"; exit 1; fi
       echo "ERROR: http 404: the kb has no fact set route; is the knowledge graph enabled (knowledge.kb.graph.enabled)?" >&2; exit 1 ;;
  401|403) echo "ERROR: http $code: the admin token was refused" >&2; exit 1 ;;
  400|413) echo "ERROR: http $code: $(jq -r '.error // "rejected"' "$RESP" 2>/dev/null || echo rejected)" >&2; exit 1 ;;
  409|422) # the collection has a graph schema (hack/kb-graph-schema.sh) and the fact set does not fit it: the places and rules of the first violations
       { echo "ERROR: http $code: the fact set was NOT stored: $(jq -r '.error // "rejected"' "$RESP" 2>/dev/null || echo rejected)"
         jq -r '(.violations // [])[] | "  \(.at): \(.rule)"' "$RESP" 2>/dev/null || true
         jq -r 'select((.more // 0) > 0) | "  and \(.more) more"' "$RESP" 2>/dev/null || true; } >&2
       exit 1 ;;
  *) echo "ERROR: http $code" >&2; exit 1 ;;
esac
