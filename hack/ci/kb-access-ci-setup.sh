#!/usr/bin/env bash
# CI ONLY. Sets up what the live check of the knowledge base isolation needs BEFORE the platform install (ADR 0030, slice 3): the two tiny MCP endpoints of
# hack/ci/endpoints-ci-setup.sh (they make the groups alpha and beta) and the namespace of the probe pod. Refuses to run anywhere but a kind or k3d CI cluster:
# on GitHub Actions, or when KB_ACCESS_CI_CONTEXT names the current context exactly.
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
ENDPOINTS=1 ENDPOINTS_CI_CONTEXT=${KB_ACCESS_CI_CONTEXT:-} hack/ci/endpoints-ci-setup.sh || exit 1
$K get namespace kb-ci >/dev/null 2>&1 || $K create namespace kb-ci >/dev/null || exit 1
# The CA ConfigMap and the right to read the keys are made by hack/ci/kb-access-live.sh after each install: install.sh replaces that ConfigMap on every run.
echo "kb-access-ci-setup: the endpoints and the namespace kb-ci are in place"
