#!/usr/bin/env bash
# CI ONLY. Sets up what the live check of the knowledge base isolation needs BEFORE the platform install (ADR 0030, slice 3): the two tiny MCP endpoints of
# hack/ci/endpoints-ci-setup.sh (they make the groups alpha and beta), the namespace of the probe pod, and what lets the tool gateways trust the API server's own
# tokens (the CA ConfigMap that hack/ci/kb-access-ci-values.yaml names, and the right to read the key set without a login). Refuses to run anywhere but a kind
# or k3d CI cluster: on GitHub Actions, or when KB_ACCESS_CI_CONTEXT names the current context exactly.
#   kind create cluster --name openagentix --config hack/kind-config.yaml
#   KB_ACCESS=1 hack/ci/kb-access-ci-setup.sh
set -u
[ "${KB_ACCESS:-0}" = 1 ] || { echo "kb-access-ci-setup: set KB_ACCESS=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in
  kind-*|k3d-*) ;;
  *) echo "kb-access-ci-setup: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind or k3d context. Nothing was changed." >&2; exit 2;;
esac
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${KB_ACCESS_CI_CONTEXT:-}" != "$CTX_NOW" ]; then
  echo "kb-access-ci-setup: refusing to run on '$CTX_NOW': it is not a CI run (GITHUB_ACTIONS is not true) and KB_ACCESS_CI_CONTEXT does not name this context. Nothing was changed." >&2
  exit 2
fi
cd "$(dirname "$0")/../.." || exit 1
MCPNS=${MCP_NAMESPACE:-mcp-tools}
ENDPOINTS=1 ENDPOINTS_CI_CONTEXT=${KB_ACCESS_CI_CONTEXT:-} hack/ci/endpoints-ci-setup.sh || exit 1
$K get namespace kb-ci >/dev/null 2>&1 || $K create namespace kb-ci >/dev/null || exit 1
$K get configmap kube-root-ca.crt -n "$MCPNS" -o json | jq --arg n ci-apiserver-ca '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:$n,namespace:.metadata.namespace},data:{"ca.crt":.data["ca.crt"]}}' | $K apply -f - >/dev/null || exit 1
$K create clusterrolebinding ci-jwks-anonymous --clusterrole=system:service-account-issuer-discovery --group=system:unauthenticated --dry-run=client -o yaml | $K apply -f - >/dev/null || exit 1
echo "kb-access-ci-setup: the endpoints, the namespace kb-ci and the trust of the API server's tokens are in place"
