#!/usr/bin/env bash
# Idempotent bring-up of kagent 1.0.1 + Agent Substrate 1.0.1 on a local kind cluster (pure Helm path).
# Reads GOOGLE_API_KEY from the environment; never writes it to disk.
# Requires: docker, kind>=0.33, kubectl>=1.37, helm 3, jq, openssl, curl, shasum.
set -euo pipefail
cd "$(dirname "$0")"
# GOOGLE_API_KEY is optional when called from ../../install.sh (SKIP_FIRST_AGENT=1): without it the
# default Gemini ModelConfig exists but cannot call the API. Standalone runs still need it for my-first-agent.
GOOGLE_API_KEY=${GOOGLE_API_KEY:-}
SKIP_FIRST_AGENT=${SKIP_FIRST_AGENT:-0}
[ "$SKIP_FIRST_AGENT" = 1 ] || : "${GOOGLE_API_KEY:?export GOOGLE_API_KEY first (or SKIP_FIRST_AGENT=1)}"

CLUSTER=${CLUSTER:-openagentix}
VER=1.0.1                      # kagent + substrate charts (docs say 1.0.0; 1.0.1 is the latest patch)
KAGENT_OCI=oci://ghcr.io/kagent-dev/kagent/helm
SUB_OCI=oci://ghcr.io/kagent-dev/substrate/helm
# shellcheck source=../../hack/cluster.sh
. ../../hack/cluster.sh   # CLUSTER_TYPE=kind (default) or k3d
cluster_check_type || exit 1
NODE=$(cluster_node)
# rtk (user's shell hook) rewrites some kubectl invocations; use the real binary when run interactively.
K=${KUBECTL:-kubectl}
t0=$(date +%s)
log(){ printf '\n=== %s (+%ss)\n' "$*" "$(( $(date +%s) - t0 ))"; }

# --- 0. kubectl-ate plugin (needed to mint CA/JWT pools) -------------------------------------
if ! command -v kubectl-ate >/dev/null; then
  BIN=${KUBECTL_ATE_DIR:-$HOME/.local/bin}; mkdir -p "$BIN"
  OS=$(uname -s | tr '[:upper:]' '[:lower:]'); ARCH=$(uname -m); case "$ARCH" in x86_64) ARCH=amd64;; aarch64) ARCH=arm64;; esac
  # Plain curl of the public release asset plus its .sha256: no GitHub login needed.
  ASSET="kubectl-ate-$OS-$ARCH"; URL="https://github.com/kagent-dev/substrate/releases/download/v$VER/$ASSET"
  DL=$(mktemp -d)
  curl -fsSL -o "$DL/$ASSET" "$URL" && curl -fsSL -o "$DL/$ASSET.sha256" "$URL.sha256"
  [ "$(shasum -a 256 "$DL/$ASSET" | awk '{print $1}')" = "$(awk '{print $1}' "$DL/$ASSET.sha256")" ] \
    || { echo "kubectl-ate checksum mismatch" >&2; exit 1; }
  install -m 0755 "$DL/$ASSET" "$BIN/kubectl-ate"; rm -rf "$DL"; export PATH="$BIN:$PATH"
fi

# --- 1. kind cluster: v1.37 node, no feature gates needed (CTB/PodCertificateRequest are GA in certificates.k8s.io/v1)
log "$CLUSTER_TYPE cluster"
cluster_exists || cluster_create ../..
$K config use-context "$(cluster_ctx)" >/dev/null
# Upstream hack/create-kind-cluster.sh does this for gVisor loopback pod networking. Not in the docs.
docker exec "$NODE" sysctl -w net.ipv4.conf.all.proxy_arp=1 >/dev/null
docker exec "$NODE" sysctl -e -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null

# --- 2. CRDs ----------------------------------------------------------------------------------
log "CRDs"
helm upgrade --install kagent-crds $KAGENT_OCI/kagent-crds --version $VER -n kagent --create-namespace --wait
helm upgrade --install substrate-crds $SUB_OCI/substrate-crds --version $VER -n ate-system --create-namespace --wait

# --- 3. identity pools (create only if missing; the command fails when the Secret exists) -----
log "identity pools"
$K create ns podcertificate-controller-system --dry-run=client -o yaml | $K apply -f - >/dev/null
mkpool(){ # name namespace keytype
  $K -n "$2" get secret "$1" >/dev/null 2>&1 || kubectl-ate admin make-ca-pool --name="$1" --secret-namespace="$2" --ca-id=1 --key-type="$3"; }
mkpool service-dns-ca-pool   podcertificate-controller-system ED25519
mkpool postgres-ca-pool      podcertificate-controller-system ED25519
mkpool pod-identity-ca-pool  podcertificate-controller-system ED25519
mkpool actor-id-ca-pool      ate-system ED25519
mkpool egress-mitm-ca-pool   ate-system ECDSAP256
$K -n ate-system get secret actor-id-jwt-pool >/dev/null 2>&1 || \
  kubectl-ate admin make-jwt-pool --name=actor-id-jwt-pool --secret-namespace=ate-system --key-id=1

# --- 4. API authentication --------------------------------------------------------------------
log "API authentication"
TMP=$(mktemp -d)
$K get secret -n ate-system actor-id-ca-pool -o json | jq -r '.data["tls.crt"]' | base64 -d > "$TMP/ca.crt"
$K -n ate-system create secret generic actor-id-ca-certs --from-file=ca.crt="$TMP/ca.crt" --dry-run=client -o yaml | $K apply -f -
ISSUER=$($K get --raw /.well-known/openid-configuration | jq -r .issuer)
cat > "$TMP/authentication.yaml" <<EOF
jwtProviders:
- name: kubernetes
  issuer: $ISSUER
  audiences: [api.ate-system.svc]
  # in-cluster issuer (kind): these two lines are required; on GKE-style external issuers they must be omitted
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
EOF
$K -n ate-system create configmap ate-api-authentication --from-file=authentication.yaml="$TMP/authentication.yaml" --dry-run=client -o yaml | $K apply -f -

# --- 5. pod-certificate controller ------------------------------------------------------------
log "substrate-podcert"
helm upgrade --install substrate-podcert $SUB_OCI/substrate-podcert --version $VER -n podcertificate-controller-system --create-namespace --wait --timeout 5m

# --- 6. Substrate's bundled mTLS PostgreSQL (vendored upstream manifest, shrunk) --------------
log "substrate postgres"
$K apply -k manifests/substrate-postgres
$K -n ate-system rollout status statefulset/postgres --timeout=5m
$K -n ate-system exec -i postgres-0 -c postgres -- psql --no-psqlrc --set=ON_ERROR_STOP=1 --single-transaction -U postgres -d atepg \
  --set=substrate_schema=substrate --set=substrate_owner_role=substrate_owner --set=substrate_owner_user=substrate_owner_user --set=substrate_owner_password= \
  --set=substrate_readwrite_role=substrate_readwrite --set=substrate_readwrite_user=substrate_readwrite_user --set=substrate_readwrite_password= < dl/substrate-setup.sql
TLS='sslmode=verify-full&sslrootcert=/run/servicedns.podcert.ate.dev/trust-bundle.pem'
for pair in "readwrite:readWrite" "owner:owner"; do r=${pair%%:*}; key=${pair##*:}
  $K -n ate-system create secret generic "substrate-postgres-$r" \
    --from-literal="${key}ConnectionString=postgresql://substrate_${r}_user@postgres.ate-system.svc:5432/atepg?${TLS}&sslcert=/run/postgres.podcert.ate.dev/substrate_${r}_user.pem&sslkey=/run/postgres.podcert.ate.dev/substrate_${r}_user.pem" \
    --dry-run=client -o yaml | $K apply -f -
done

# --- 7. Substrate: atelet (node agent), then control plane ------------------------------------
log "substrate-atelet + substrate"
$K -n ate-system create secret generic kagent-rustfs-credentials \
  --from-literal=AWS_ACCESS_KEY_ID=rustfsadmin --from-literal=AWS_SECRET_ACCESS_KEY=rustfsadmin --dry-run=client -o yaml | $K apply -f -
helm upgrade --install substrate-atelet $SUB_OCI/substrate-atelet --version $VER -n ate-system --wait --timeout 10m -f values/substrate-atelet.yaml
$K -n ate-system rollout status daemonset/atelet --timeout=5m
helm upgrade --install substrate $SUB_OCI/substrate --version $VER -n ate-system --wait --timeout 10m -f values/substrate.yaml

# --- 8. kagent's own PostgreSQL (pgvector image, password auth; spike-only) -------------------
log "kagent postgres"
$K create ns kagent --dry-run=client -o yaml | $K apply -f - >/dev/null
if ! $K -n kagent get secret kagent-pg-admin >/dev/null 2>&1; then
  $K -n kagent create secret generic kagent-pg-admin --from-literal=password="$(openssl rand -hex 12)"
fi
$K apply -f manifests/kagent-postgres.yaml
$K -n kagent rollout status sts/kagent-pg --timeout=3m
for _ in $(seq 30); do $K -n kagent exec kagent-pg-0 -- psql --no-psqlrc -U postgres -d kagent -tAc 'select 1' >/dev/null 2>&1 && break; sleep 2; done   # belt and braces after the TCP readiness probe
if ! $K -n kagent get secret kagent-postgres-owner >/dev/null 2>&1; then
  OW=$(openssl rand -hex 12); RW=$(openssl rand -hex 12)
  $K -n kagent exec -i kagent-pg-0 -- psql --no-psqlrc -U postgres -d kagent --set=ON_ERROR_STOP=1 --single-transaction \
    --set=kagent_schema=kagent --set=kagent_owner_role=kagent_owner --set=kagent_owner_user=kagent_owner_user --set=kagent_owner_password="$OW" \
    --set=kagent_readwrite_role=kagent_readwrite --set=kagent_readwrite_user=kagent_readwrite_user --set=kagent_readwrite_password="$RW" < dl/kagent-setup.sql
  $K -n kagent create secret generic kagent-postgres-owner --from-literal=ownerConnectionString="postgresql://kagent_owner_user:$OW@kagent-pg.kagent.svc:5432/kagent?sslmode=disable"
  $K -n kagent create secret generic kagent-postgres-readwrite --from-literal=readWriteConnectionString="postgresql://kagent_readwrite_user:$RW@kagent-pg.kagent.svc:5432/kagent?sslmode=disable"
fi

# --- 9. kagent --------------------------------------------------------------------------------
log "kagent"
if [ -n "$GOOGLE_API_KEY" ]; then
  $K -n kagent create secret generic kagent-gemini --from-literal=GOOGLE_API_KEY="$GOOGLE_API_KEY" --dry-run=client -o yaml | $K apply -f -
fi
$K label namespace kagent ate.dev/api-access=true --overwrite
bash pgvector.sh                      # extension must exist before the controller starts with vectorEnabled=true
KAGENT_VERSION=$VER bash kagent-helm.sh

[ "$SKIP_FIRST_AGENT" = 1 ] && { log "READY (first agent skipped)"; exit 0; }
# --- 10. first agent --------------------------------------------------------------------------
log "agent"
$K apply -f manifests/first-agent.yaml
$K wait agent/my-first-agent -n kagent --for=condition=Ready --timeout=900s
log "READY"
