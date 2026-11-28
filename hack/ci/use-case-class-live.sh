#!/usr/bin/env bash
# Live proof that a use case agent's key is refused at the limit of its budget class (ADR 0029, slice 5), through the policy the CHART rendered:
#   USE_CASE_CLASS_LIVE=1 hack/ci/use-case-class-live.sh <bank|equipment>
# Opt-in: it does nothing without USE_CASE_CLASS_LIVE=1. The e2e workflow runs it at the end of the bank job (after every other check).
#
# The use case was installed with its own values, so the cluster has the class (bank-case-agent or equipment-case-agent, 800,000 tokens an hour) in the
# one gateway policy, and install.sh wrote the class into the key entry of the agent. This script:
#   1 reads the key entry of the agent and the rendered policy: the entry carries the class, the policy has a conditional entry for it with the numbers of the values
#   2 lowers that ONE entry of the live policy to a tiny number (300 tokens an hour) so the stub model can spend it in a few calls (800,000 would take about ten
#     thousand calls). The numbers of the values are not what is exercised there; the conditional entry, the key's class and the 429 are
#   3 calls the model through the gateway with the agent's own key until the first 429, and checks that it was admitted first, that it stays refused, and that a
#     key of no class still passes
#   4 puts the entry back to the number of the values and checks that the policy is what it was
# It changes the live policy for a short time and puts it back on every way out. It refuses to run anywhere but a GitHub Actions run on a kind cluster whose
# context is named by USE_CASE_CLASS_CI_CONTEXT (the workflow sets both), and never on kind-openagentix. It prints no key and puts none on a command line (a
# header file is used). Exit 1 when a check fails, 2 when it refuses.
set -u
[ "${USE_CASE_CLASS_LIVE:-0}" = 1 ] || { echo "use-case-class-live: set USE_CASE_CLASS_LIVE=1 to run this against the current cluster (it is opt-in)"; exit 0; }
UCN=${1:-}
case "$UCN" in bank|equipment) ;; *) echo "usage: USE_CASE_CLASS_LIVE=1 use-case-class-live.sh <bank|equipment>" >&2; exit 2;; esac
K=${KUBECTL:-kubectl}
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in kind-*) ;; *) echo "use-case-class-live: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind context. Nothing was changed." >&2; exit 2;; esac
[ "$CTX_NOW" != kind-openagentix ] || { echo "use-case-class-live: refusing to run on kind-openagentix, the default cluster of a full demo. Nothing was changed." >&2; exit 2; }
[ "${GITHUB_ACTIONS:-}" = true ] || { echo "use-case-class-live: refusing to run outside GitHub Actions (not a CI run): it changes the live policy for a short time. Nothing was changed." >&2; exit 2; }
[ -n "${USE_CASE_CLASS_CI_CONTEXT:-}" ] && [ "$USE_CASE_CLASS_CI_CONTEXT" = "$CTX_NOW" ] || { echo "use-case-class-live: refusing to run: USE_CASE_CLASS_CI_CONTEXT ('${USE_CASE_CLASS_CI_CONTEXT:-}') does not name the current context '$CTX_NOW'. Nothing was changed." >&2; exit 2; }
K="$K --context=$CTX_NOW"

case "$UCN" in
  bank)      AGENT=dispute-agent; CLASS=bank-case-agent; WANT=800000 ;;
  equipment) AGENT=service-agent; CLASS=equipment-case-agent; WANT=800000 ;;
esac
GW_NS=${GW_NAMESPACE:-agentgateway-system}; KNS=${KAGENT_NAMESPACE:-kagent}
TD=$(mktemp -d); mkdir -p "$TD/r"; chmod 700 "$TD"
PF=""; ORIG_TOKENS=""; IDX=""; POLNAME=""
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
note() { printf '  --   %s\n' "$1"; }
restore() { [ -n "$IDX" ] && [ -n "$ORIG_TOKENS" ] && $K patch agentgatewaypolicy "$POLNAME" -n "$GW_NS" --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/traffic/rateLimit/conditional/$IDX/policy/local/0/tokens\",\"value\":$ORIG_TOKENS}]" >/dev/null 2>&1; }
cleanup() { [ -z "$PF" ] || kill "$PF" 2>/dev/null; restore; rm -rf "$TD"; }
trap cleanup EXIT

echo "# 1 the key entry of $AGENT and the rendered policy ($UCN)"
ENT=$($K get configmap llm-api-keys -n "$GW_NS" -o json | jq -c '.data|with_entries(.value|=(fromjson|.metadata))')
chk "the key entry of $AGENT carries the class $CLASS (install.sh wrote it from the chart's annotation)" "$(jq -r --arg a "$AGENT" '.[$a].budget_class // "none"' <<<"$ENT")" "$CLASS"
POLJSON=$($K get agentgatewaypolicy -n "$GW_NS" -o json | jq -c '[.items[]|select(.spec.traffic.rateLimit.conditional!=null)]|.[0]')
POLNAME=$(jq -r '.metadata.name' <<<"$POLJSON")
IDX=$(jq -r --arg c "apiKey.budget_class == \"$CLASS\"" '.spec.traffic.rateLimit.conditional|to_entries|map(select(.value.condition==$c))|.[0].key // empty' <<<"$POLJSON")
[ -n "$IDX" ] && ok "the policy $POLNAME has a conditional entry for the class $CLASS" || { bad "the policy has no conditional entry for the class $CLASS"; echo; echo "passed=$PASS failed=$FAIL"; exit 1; }
ORIG_TOKENS=$(jq -r --argjson i "$IDX" '.spec.traffic.rateLimit.conditional[$i].policy.local[0].tokens' <<<"$POLJSON")
chk "the entry has the number of the values ($WANT tokens an hour)" "$ORIG_TOKENS $(jq -r --argjson i "$IDX" '.spec.traffic.rateLimit.conditional[$i].policy.local[0].unit' <<<"$POLJSON") $(jq -r --argjson i "$IDX" '.spec.traffic.rateLimit.conditional[$i].policy.local[0].key // "no-key"' <<<"$POLJSON")" "$WANT Hours apiKey.user_id"
chk "the default entry (a key of no class) is last" "$(jq -r '.spec.traffic.rateLimit.conditional|last|has("condition")' <<<"$POLJSON")" false

echo "# 2 the keys and the gateway"
hdr() { # hdr <agent>: a header file with the agent's key (never printed, never on a command line)
  local f="$TD/h-$1"
  { printf 'Authorization: Bearer '; $K get secret -n "$KNS" "$1-virtual-key" -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d; printf '\n'; } > "$f"
  chmod 600 "$f"
}
hdr "$AGENT"
OTHER=""
for cand in $(jq -r 'to_entries|map(select(.value.budget_class==null))|.[].key' <<<"$ENT"); do
  if $K get secret -n "$KNS" "$cand-virtual-key" >/dev/null 2>&1; then OTHER=$cand; break; fi
done
[ -z "$OTHER" ] || hdr "$OTHER"
$K port-forward -n "$GW_NS" svc/model-gateway 18081:80 >/dev/null 2>&1 &
PF=$!
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/18081) 2>/dev/null && break; sleep 0.2; done
call() { # call <header file> <label>: one chat request; "<status> <tokens>" in $TD/r/<label>; the 429 headers in $TD/r/<label>.h
  local hf=$1 label=$2 code
  code=$(curl -s -m 30 -o "$TD/b-$label" -D "$TD/r/$label.h" -w '%{http_code}' -H "@$hf" -H 'Content-Type: application/json' \
    -d "{\"model\":\"quickstart-model\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"class-proof $label\"}]}" http://127.0.0.1:18081/v1/chat/completions)
  printf '%s %s\n' "$code" "$(jq -r '.usage.total_tokens // 0' "$TD/b-$label" 2>/dev/null || echo 0)" > "$TD/r/$label"
  rm -f "$TD/b-$label"
}
st() { cut -d' ' -f1 "$TD/r/$1"; }
tk() { cut -d' ' -f2 "$TD/r/$1"; }

echo "# 3 the entry of the class is lowered to 300 tokens an hour and the key of $AGENT is refused at it"
$K patch agentgatewaypolicy "$POLNAME" -n "$GW_NS" --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/traffic/rateLimit/conditional/$IDX/policy/local/0/tokens\",\"value\":300}]" >/dev/null && ok "the entry of $CLASS now says 300 tokens an hour (test only; restored below)" || bad "the entry could not be lowered"
# the gateway needs a moment to read the policy: a call that is not refused yet is admitted, so the limit is read from the first 429
n=0; tok=0; last=""
for i in $(seq 1 80); do
  call "$TD/h-$AGENT" "a$i"; last=$(st "a$i")
  [ "$last" = 200 ] && { n=$((n+1)); tok=$((tok+$(tk "a$i"))); }
  [ "$last" = 429 ] && break
  [ "$last" = 200 ] || sleep 2
done
note "$AGENT: $n calls admitted ($tok tokens counted), then HTTP $last"
chk "the key of $AGENT is refused with 429 at the limit of its class" "$last" 429
[ "$n" -ge 1 ] && ok "it was admitted first ($n call(s)): the class limit is not zero" || bad "the key was never admitted"
[ "$tok" -gt 0 ] && ok "tokens were counted ($tok): the stub model reports usage" || bad "no tokens were counted"
call "$TD/h-$AGENT" again; chk "the key stays refused" "$(st again)" 429
note "the 429 headers: $(tr -d '\r' < "$TD/r/a$i.h" 2>/dev/null | grep -iE '^(HTTP|x-ratelimit|retry-after)' | tr '\n' ' ')"
if [ -n "$OTHER" ]; then call "$TD/h-$OTHER" other; chk "the key of $OTHER (no class) still passes while $AGENT is refused" "$(st other)" 200
else note "no key of an agent without a class was found: that check is skipped"; fi

echo "# 4 the entry is put back"
restore && ok "the entry of $CLASS is back at $ORIG_TOKENS" || bad "the entry could not be put back"
ORIG_TOKENS_NOW=$($K get agentgatewaypolicy "$POLNAME" -n "$GW_NS" -o json | jq -r --argjson i "$IDX" '.spec.traffic.rateLimit.conditional[$i].policy.local[0].tokens')
chk "the live policy has the number of the values again" "$ORIG_TOKENS_NOW" "$ORIG_TOKENS"
IDX=""   # restored; nothing for the exit trap to do

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
