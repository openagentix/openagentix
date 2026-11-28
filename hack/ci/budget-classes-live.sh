#!/usr/bin/env bash
# Live proof of budget classes (ADR 0029, slice 3) on a cluster that ./install.sh set up with hack/ci/budget-classes-ci-values.yaml:
#   PROFILE=quickstart VALUES_FILE=hack/ci/budget-classes-ci-values.yaml ./install.sh
#   BUDGET_CLASSES_LIVE=1 hack/ci/budget-classes-live.sh
# Opt-in: it does nothing without BUDGET_CLASSES_LIVE=1. The e2e workflow runs it on request (input `budget_classes`).
#
# The policy under test is the one the CHART rendered (two classes and the default), and the keys are the ones install.sh wrote for three chart agents:
# budget-tight (class tight, 300 tokens an hour), budget-wide (class wide, 100000) and budget-none (no class, the default of 800). The model is the stub
# model behind a recording stand-in (hack/ci/budget-classes-recorder.py), so no paid call is made and every request that reaches the model is counted.
# What it settles:
#   1 the rendered policy has the conditional entries, and the key entries of install.sh carry the class only for the agents that name one
#   2 a key of class tight is refused with 429 after its limit while a key of class wide still passes
#   3 a key with no class gets the default budget (it is refused later than tight, earlier than never)
#   4 a refused call never reaches the model (the stand-in counts the same number of requests as there were 200 answers)
#   5 the overshoot with parallel calls: how many calls pass a bucket that has room for one more (the number is printed, not hidden)
# It changes the cluster it runs on (the model's base URL, a stand-in, a ConfigMap of test keys) and puts both back. It refuses to run anywhere but a
# GitHub Actions run on a kind cluster. It prints no key and puts none on a command line (a header file is used). Exit 1 when a check fails.
set -u
[ "${BUDGET_CLASSES_LIVE:-0}" = 1 ] || { echo "budget-classes-live: set BUDGET_CLASSES_LIVE=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
here=$(cd "$(dirname "$0")" && pwd)
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in kind-*) ;; *) echo "budget-classes-live: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind context. Nothing was changed." >&2; exit 2;; esac
[ "${GITHUB_ACTIONS:-}" = true ] || { echo "budget-classes-live: refusing to run outside GitHub Actions: it changes the cluster it runs on. Nothing was changed." >&2; exit 2; }
# shellcheck source=hack/key-entry.sh
. "$here/../key-entry.sh"

GW_NS=${GW_NAMESPACE:-agentgateway-system}; KNS=${KAGENT_NAMESPACE:-kagent}; PNS=budget-proof
TD=$(mktemp -d); mkdir -p "$TD/r"; chmod 700 "$TD"
PF=""; ORIG_URL=""
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
note() { printf '  --   %s\n' "$1"; }
cleanup() {
  [ -z "$PF" ] || kill "$PF" 2>/dev/null
  $K delete configmap budget-proof-keys -n "$GW_NS" --ignore-not-found >/dev/null 2>&1
  if [ -n "$ORIG_URL" ]; then
    $K patch agentgatewaymodel quickstart-model -n "$GW_NS" --type merge -p "{\"spec\":{\"baseURL\":\"$ORIG_URL\"}}" >/dev/null 2>&1
  fi
  $K delete namespace "$PNS" --ignore-not-found --wait=false >/dev/null 2>&1
  $K delete networkpolicy budget-proof-allow-recorder -n "$GW_NS" --ignore-not-found >/dev/null 2>&1
  rm -rf "$TD"
}
trap cleanup EXIT

echo "# 1 the rendered policy and the key entries"
POL=$($K get agentgatewaypolicy -n "$GW_NS" -o json | jq -c '.items[]|select(.spec.traffic.apiKeyAuthentication!=null)')
chk "one gateway policy has the conditional rate limit of the chart (two classes, then the default)" "$(jq -c '.spec.traffic.rateLimit.conditional|map(.condition//"default")' <<<"$POL")" '["apiKey.budget_class == \"tight\"","apiKey.budget_class == \"wide\"","default"]'
chk "the limits are 300, 100000 and 800 tokens an hour" "$(jq -c '[.spec.traffic.rateLimit.conditional[].policy.local[0]|[.tokens,.unit]]' <<<"$POL")" '[[300,"Hours"],[100000,"Hours"],[800,"Hours"]]'
note "policy status (Accepted and Attached, as the gateway reports it): $(jq -c '[.status.ancestors[]?.conditions[]?|select(.type=="Accepted" or .type=="Attached")|{type,status}]' <<<"$POL")"
ENT=$($K get configmap llm-api-keys -n "$GW_NS" -o json | jq -c '.data|with_entries(.value|=(fromjson|.metadata))')
note "key entries (hashes left out): $ENT"
chk "budget-tight's entry carries class tight" "$(jq -r '.["budget-tight"].budget_class' <<<"$ENT")" tight
chk "budget-wide's entry carries class wide" "$(jq -r '.["budget-wide"].budget_class' <<<"$ENT")" wide
chk "budget-none's entry has no class member" "$(jq -r '.["budget-none"]|has("budget_class")' <<<"$ENT")" false

echo "# the keys, the stand-in and the gateway"
hdr() { # hdr <agent>: a header file with the agent's key (never printed, never on a command line)
  local f="$TD/h-$1"
  { printf 'Authorization: Bearer '; $K get secret -n "$KNS" "$1-virtual-key" -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d; printf '\n'; } > "$f"
  chmod 600 "$f"
}
for a in budget-tight budget-wide budget-none; do hdr "$a"; done
$K create namespace "$PNS" >/dev/null 2>&1 || true
$K create configmap budget-recorder-src -n "$PNS" --from-file=recorder.py="$here/budget-classes-recorder.py" >/dev/null
$K apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: budget-recorder, namespace: $PNS}
spec:
  replicas: 1
  selector: {matchLabels: {app: budget-recorder}}
  template:
    metadata: {labels: {app: budget-recorder}}
    spec:
      containers:
        - name: m
          image: python:3.12-alpine
          command: [python, -u, /src/recorder.py]
          ports: [{containerPort: 8080}]
          readinessProbe: {httpGet: {path: /healthz, port: 8080}}
          volumeMounts: [{name: src, mountPath: /src}]
      volumes: [{name: src, configMap: {name: budget-recorder-src}}]
---
apiVersion: v1
kind: Service
metadata: {name: budget-recorder, namespace: $PNS}
spec:
  selector: {app: budget-recorder}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: budget-proof-allow-recorder, namespace: $GW_NS}
spec:
  podSelector: {matchLabels: {app: stub-model}}
  policyTypes: [Ingress]
  ingress:
    - ports: [{protocol: TCP, port: 8080}]
      from:
        - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: $PNS}}
          podSelector: {matchLabels: {app: budget-recorder}}
YAML
$K rollout status deploy/budget-recorder -n "$PNS" --timeout=240s >/dev/null || { bad "the recording stand-in did not start"; exit 1; }
ORIG_URL=$($K get agentgatewaymodel quickstart-model -n "$GW_NS" -o jsonpath='{.spec.baseURL}')
$K patch agentgatewaymodel quickstart-model -n "$GW_NS" --type merge -p "{\"spec\":{\"baseURL\":\"http://budget-recorder.$PNS.svc.cluster.local:8080/v1\"}}" >/dev/null
$K port-forward -n "$GW_NS" svc/model-gateway 18080:80 >/dev/null 2>&1 &
PF=$!
for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/18080) 2>/dev/null && break; sleep 0.2; done

# call <header file> <label>: one chat request, the result in $TD/r/<label> as "<status> <tokens>"; the 429 headers in $TD/r/<label>.h
call() {
  local hf=$1 label=$2 code
  code=$(curl -s -m 30 -o "$TD/b-$label" -D "$TD/r/$label.h" -w '%{http_code}' -H "@$hf" -H 'Content-Type: application/json' \
    -d "{\"model\":\"quickstart-model\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"budget-proof $label\"}]}" http://127.0.0.1:18080/v1/chat/completions)
  printf '%s %s\n' "$code" "$(jq -r '.usage.total_tokens // 0' "$TD/b-$label" 2>/dev/null || echo 0)" > "$TD/r/$label"
  rm -f "$TD/b-$label"
}
st() { cut -d' ' -f1 "$TD/r/$1"; }
tk() { cut -d' ' -f2 "$TD/r/$1"; }
# drain <header file> <prefix> <max>: calls one at a time until the first 429; prints "<admitted> <tokens counted> <last status>"
drain() {
  local hf=$1 p=$2 max=$3 n=0 tok=0 s=""
  for i in $(seq 1 "$max"); do
    call "$hf" "$p-$i"; s=$(st "$p-$i")
    [ "$s" = 200 ] && { n=$((n+1)); tok=$((tok+$(tk "$p-$i"))); }
    [ "$s" = 429 ] && break
    [ "$s" = 200 ] || { sleep 2; }
  done
  echo "$n $tok $s"
}
# the gateway needs a moment to pick up the model's new base URL; the stand-in must see the first call
for i in $(seq 1 60); do
  call "$TD/h-budget-wide" "warm-$i"
  [ "$(st "warm-$i")" = 200 ] && [ "$($K get --raw "/api/v1/namespaces/$PNS/services/budget-recorder:8080/proxy/events" | jq 'length')" -ge 1 ] && break
  sleep 2
done
chk "the first call through the stand-in is answered (the model path works)" "$(st "warm-$i")" 200

echo "# 2 a key of class tight is refused after its limit, a key of class wide still passes"
read -r TA TTOK TLAST < <(drain "$TD/h-budget-tight" tight 40)
note "tight: $TA calls admitted ($TTOK tokens counted), then HTTP $TLAST"
chk "the key of class tight is refused with 429" "$TLAST" 429
[ "$TA" -ge 1 ] && ok "the key of class tight was admitted at first ($TA call(s)): the class limit is not zero" || bad "the key of class tight was never admitted"
call "$TD/h-budget-wide" wide-after; chk "the key of class wide still passes while tight is refused" "$(st wide-after)" 200
call "$TD/h-budget-tight" tight-again; chk "the key of class tight stays refused" "$(st tight-again)" 429
note "the 429 headers: $(tr -d '\r' < "$TD/r/tight-$((TA+1)).h" 2>/dev/null | grep -iE '^(HTTP|x-ratelimit|retry-after)' | tr '\n' ' ')"
WA=0; for i in $(seq 1 30); do call "$TD/h-budget-wide" "wide-$i"; [ "$(st "wide-$i")" = 200 ] && WA=$((WA+1)); done
chk "30 more calls with the key of class wide all pass (100000 tokens an hour)" "$WA" 30

echo "# 3 a key with no class gets the default budget (800 tokens an hour here)"
read -r NA NTOK NLAST < <(drain "$TD/h-budget-none" none 80)
note "none: $NA calls admitted ($NTOK tokens counted), then HTTP $NLAST"
chk "the key with no class is refused with 429 at the default budget" "$NLAST" 429
[ "$NA" -gt "$TA" ] && ok "the default budget lasted longer than the class tight ($NA calls against $TA)" || bad "the default budget did not last longer than the class tight ($NA against $TA)"
[ "$NA" -lt 80 ] && ok "and it is a limit ($NA calls), not unlimited" || bad "the key with no class was never refused"

echo "# 4 a refused call never reaches the model"
REF=0; for i in $(seq 1 10); do call "$TD/h-budget-tight" "refused-$i"; [ "$(st "refused-$i")" = 429 ] && REF=$((REF+1)); done
chk "10 more calls with the spent key of class tight: all refused" "$REF" 10
EVT=$($K get --raw "/api/v1/namespaces/$PNS/services/budget-recorder:8080/proxy/events")
chk "the model saw none of those 10 calls" "$(jq '[.[]|select(.text|test("budget-proof refused-"))]|length' <<<"$EVT")" 0
OK200=0; for f in "$TD"/r/*; do case "$f" in *.h) continue;; esac; [ "$(cut -d' ' -f1 "$f")" = 200 ] && OK200=$((OK200+1)); done
note "calls answered 200 in this run: $OK200; requests the model saw: $(jq 'length' <<<"$EVT")"
chk "the model saw exactly as many requests as there were 200 answers (no 429 was sent on)" "$(jq '[.[]|select(.text|test("^budget-proof "))]|length' <<<"$EVT")" "$OK200"

echo "# 5 the overshoot with parallel calls (class tight, a bucket that has room for one more call)"
OVK=(ov1 ov2 ov3)
OVD=()
for n in "${OVK[@]}"; do
  key="vk-ov-$(openssl rand -hex 12)"
  { printf 'Authorization: Bearer %s\n' "$key"; } > "$TD/h-$n"; chmod 600 "$TD/h-$n"
  h="sha256:$(printf '%s' "$key" | shasum -a 256 | awk '{print $1}')"
  OVD+=(--from-literal="$n=$(key_entry "$n" "$h" tight)")
  unset key
done
$K create configmap budget-proof-keys -n "$GW_NS" "${OVD[@]}" --dry-run=client -o yaml | $K label --local -f - agentgateway.dev/apikey=true -o yaml | $K apply -f - >/dev/null
K1=5; K2=10; K3=20
i=0
for n in "${OVK[@]}"; do
  i=$((i+1)); par=$K1; [ $i = 2 ] && par=$K2; [ $i = 3 ] && par=$K3
  # the gateway needs a moment to read the new ConfigMap: a 401 spends no tokens
  for w in $(seq 1 45); do call "$TD/h-$n" "$n-first"; [ "$(st "$n-first")" != 401 ] && break; sleep 2; done
  used=1
  while [ "$used" -lt $((TA-1)) ]; do used=$((used+1)); call "$TD/h-$n" "$n-seq-$used"; done
  pids=(); for j in $(seq 1 "$par"); do call "$TD/h-$n" "$n-par-$j" & pids+=($!); done; wait "${pids[@]}"
  adm=0; r429=0; other=0
  for j in $(seq 1 "$par"); do case "$(st "$n-par-$j")" in 200) adm=$((adm+1));; 429) r429=$((r429+1));; *) other=$((other+1));; esac; done
  call "$TD/h-$n" "$n-after"
  note "key $n (class tight, $TA calls fit one at a time): $((TA-1)) sequential calls, then $par at the same moment: $adm admitted, $r429 refused (429), $other other; the next call: HTTP $(st "$n-after")"
  eval "OV$i=$adm"
done
[ "$OV1" -ge 1 ] && [ "$OV2" -ge 1 ] && [ "$OV3" -ge 1 ] && ok "at least one parallel call was admitted each time (a sequential caller gets one)" || bad "no parallel call was admitted"
OVMAX=$OV1; [ "$OV2" -gt "$OVMAX" ] && OVMAX=$OV2; [ "$OV3" -gt "$OVMAX" ] && OVMAX=$OV3
note "OVERSHOOT: $OV1 of $K1, $OV2 of $K2, $OV3 of $K3 parallel calls were admitted with room for one more call (largest $OVMAX). The limit is soft: the calls in flight when the bucket runs out all pass."
$K get --raw "/api/v1/namespaces/$PNS/services/budget-recorder:8080/proxy/events" | jq 'length' | xargs -I{} echo "  --   requests the model saw in all: {}"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
