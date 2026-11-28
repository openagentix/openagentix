#!/usr/bin/env bash
# The ONE place that installs or upgrades the substrate Helm release (used by up.sh; run it by hand on a cluster that is already up to add the wait of issue #203).
# Always passes values/substrate.yaml, so an upgrade never drops our values, and the post-renderer that makes the Substrate API server wait for its PostgreSQL
# (substrate-postrender.sh). It touches no data: the release changes the Deployment ate-api-server only (a rolling restart), and nothing else.
# Run from anywhere. Needs helm, kubectl. The cluster is the current context (or KUBECONFIG); name another with --kube-context through HELM_ARGS.
set -euo pipefail
cd "$(dirname "$0")"
VER=${SUBSTRATE_VERSION:-1.0.1}
SUB_OCI=oci://ghcr.io/kagent-dev/substrate/helm
# shellcheck disable=SC2086
helm upgrade --install substrate "$SUB_OCI/substrate" --version "$VER" -n ate-system --wait --timeout 10m -f values/substrate.yaml \
  --post-renderer ./substrate-postrender.sh ${HELM_ARGS:-}
