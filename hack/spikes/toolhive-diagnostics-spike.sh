#!/usr/bin/env bash
# ToolHive spike for the diagnostic tools (issue #230, ADR 0025 slice 2). Runs on a THROWAWAY kind cluster, normally in GitHub Actions
# (.github/workflows/spike-toolhive.yml). It installs only the ToolHive operator 0.67.1 (the same chart pins as components/tools/install.sh),
# one stand-in MCP backend and a small identity provider, then runs hack/spikes/toolhive_spike.py: one check per question of the slice.
#
#   hack/spikes/toolhive-diagnostics-spike.sh            create the cluster, run, print the results, delete the cluster
#   SPIKE_KEEP=1 ...                                     keep the cluster (for a look by hand)
#   SPIKE_CLUSTER=name ...                               kind cluster name (default oa-spike-toolhive; never `openagentix`)
#   SPIKE_OUT=dir ...                                    where results.json, results.md and the dumps go (default ./spike-out)
#
# It uses its own kubeconfig file and never touches the current kube context. It sets no secret value on a command line or in a log.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
CLUSTER=${SPIKE_CLUSTER:-oa-spike-toolhive}
OUT=${SPIKE_OUT:-$PWD/spike-out}
TOOLHIVE_VERSION=0.67.1
NS=spike-mcp
case "$CLUSTER" in openagentix|kind|"") echo "refusing to use the cluster name '$CLUSTER'" >&2; exit 2;; esac
for t in kind kubectl helm openssl python3 sed; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d); chmod 700 "$WORK"
export KUBECONFIG="$WORK/kubeconfig"
created=0
cleanup() {
  rc=$?
  [ "${SPIKE_KEEP:-0}" = 1 ] || { [ "$created" = 1 ] && kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true; }
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT
say() { printf '\n==> %s\n' "$*"; }

say "kind cluster $CLUSTER"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  [ "${SPIKE_REUSE:-0}" = 1 ] || { echo "cluster $CLUSTER exists; set SPIKE_REUSE=1 to use it or SPIKE_CLUSTER to pick another name" >&2; exit 2; }
  kind get kubeconfig --name "$CLUSTER" > "$KUBECONFIG"
else
  kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s; created=1
fi
case "$(kubectl config current-context)" in "kind-$CLUSTER") ;; *) echo "unexpected kube context $(kubectl config current-context)" >&2; exit 2;; esac

say "ToolHive operator $TOOLHIVE_VERSION"
helm upgrade --install toolhive-operator-crds oci://ghcr.io/stacklok/toolhive/toolhive-operator-crds --version "$TOOLHIVE_VERSION" \
  -n toolhive-system --create-namespace --wait
helm upgrade --install toolhive-operator oci://ghcr.io/stacklok/toolhive/toolhive-operator --version "$TOOLHIVE_VERSION" \
  -n toolhive-system --wait --timeout 5m
kubectl get pods -n toolhive-system

say "inputs: signing key, JWKS, header values, canaries"
openssl genrsa -out "$WORK/key.pem" 2048 2>/dev/null
KID=spike-key-1
ISSUER="http://idp.$NS.svc.cluster.local:8080"
AUDIENCE=spike-diag
python3 -I "$here/toolhive_spike.py" jwks "$WORK/key.pem" "$KID" > "$WORK/jwks.json"
printf '{"issuer":"%s","jwks_uri":"%s/jwks.json","id_token_signing_alg_values_supported":["RS256"]}\n' "$ISSUER" "$ISSUER" > "$WORK/openid-configuration"
HEX=$(openssl rand -hex 24)
echo "::add-mask::$HEX" 2>/dev/null || true
printf 'Bearer %s' "$HEX" > "$WORK/hdr-value"
printf '%s' "$HEX" > "$WORK/hdr-raw"
RESULT_CANARY="RESULT-CANARY-$(openssl rand -hex 6)"
REQUEST_CANARY="REQ-CANARY-$(openssl rand -hex 6)"

say "objects"
sed -e "s|__RESULT_CANARY__|$RESULT_CANARY|g" -e "s|__ISSUER__|$ISSUER|g" -e "s|__AUDIENCE__|$AUDIENCE|g" \
  "$here/toolhive-diagnostics-spike.yaml" > "$WORK/objects.yaml"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
EOF
kubectl create configmap spike-backend -n "$NS" --from-file=server.py="$here/spike-mcp-backend.py"
kubectl create configmap spike-idp -n "$NS" --from-file=jwks.json="$WORK/jwks.json" --from-file=openid-configuration="$WORK/openid-configuration"
kubectl create secret generic hdr-token -n "$NS" --from-file=value="$WORK/hdr-value"
kubectl create secret generic hdr-token-raw -n "$NS" --from-file=value="$WORK/hdr-raw"
kubectl apply -f "$WORK/objects.yaml"
kubectl rollout status deploy/mcpstub deploy/idp -n "$NS" --timeout=240s || true

say "wait for the vMCPs"
for v in sh-open sh-excl sh-deny sh-cedar sh-sep diag; do
  kubectl wait "virtualmcpserver/$v" -n "$NS" --for=jsonpath='{.status.phase}'=Ready --timeout=300s \
    || { echo "vMCP $v not Ready:"; kubectl get "virtualmcpserver/$v" -n "$NS" -o jsonpath='{.status}'; echo; }
done
sleep 20   # backend discovery
{
  echo "--- toolhive objects"; kubectl get mcpgroups,mcpserverentries,mcpexternalauthconfigs,mcpoidcconfigs,virtualmcpservers -n "$NS" 2>&1
  echo "--- pods"; kubectl get pods -n "$NS" -o wide 2>&1
  echo "--- services"; kubectl get svc -n "$NS" 2>&1
} | tee "$OUT/cluster-state.txt"

say "checks"
rc=0
SPIKE_NS=$NS SPIKE_KEY="$WORK/key.pem" SPIKE_KID=$KID SPIKE_ISSUER=$ISSUER SPIKE_AUDIENCE=$AUDIENCE \
SPIKE_HDR_VALUE_FILE="$WORK/hdr-value" SPIKE_HDR_RAW_FILE="$WORK/hdr-raw" \
SPIKE_RESULT_CANARY=$RESULT_CANARY SPIKE_REQUEST_CANARY=$REQUEST_CANARY SPIKE_OUT="$OUT" \
  python3 -I "$here/toolhive_spike.py" run || rc=$?

say "dumps (no Secret objects)"
kubectl get mcpgroups,mcpserverentries,mcpexternalauthconfigs,mcpoidcconfigs,virtualmcpservers,configmaps -n "$NS" -o yaml > "$OUT/objects-live.yaml" 2>&1 || true
for v in sh-open sh-excl sh-deny sh-cedar sh-sep diag; do
  for p in $(kubectl get pods -n "$NS" -o name | grep "^pod/$v-" || true); do kubectl logs -n "$NS" "$p" --all-containers --tail=3000 > "$OUT/log-vmcp-$v.txt" 2>&1 || true; done
done
kubectl logs -n "$NS" deploy/mcpstub --tail=5000 > "$OUT/log-backend.txt" 2>&1 || true
kubectl logs -n toolhive-system deploy/toolhive-operator --tail=5000 > "$OUT/log-operator.txt" 2>&1 || true
# the dumps must not hold the header value
if grep -rlF "$HEX" "$OUT" >/dev/null 2>&1; then echo "NOTE: the header value is in: $(grep -rlF "$HEX" "$OUT" | tr '\n' ' ') (removed)"; grep -rlF "$HEX" "$OUT" | xargs -r sed -i "s/$HEX/REDACTED-HEADER-VALUE/g"; fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$OUT/results.md" ]; then
  { echo "## ToolHive $TOOLHIVE_VERSION spike for diagnostic tools (issue #230)"; echo; cat "$OUT/results.md"; } >> "$GITHUB_STEP_SUMMARY"
fi
[ -f "$OUT/results.md" ] && cat "$OUT/results.md"
exit "$rc"
