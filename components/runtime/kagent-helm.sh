#!/usr/bin/env bash
# The ONE place that installs/upgrades the kagent Helm release (used by up.sh and by install.sh when memory needs a
# values change). Always passes values/kagent.yaml, so an upgrade never drops our values.
set -euo pipefail
cd "$(dirname "$0")"
K=${KUBECTL:-kubectl}
VER=${KAGENT_VERSION:-1.0.1}
# KAGENT_EXTRA_VALUES: optional extra values files (space separated, applied after values/kagent.yaml); install.sh passes the
# telemetry settings derived from the chart's observability block. Without it the release carries only values/kagent.yaml.
EXTRA=(); for f in ${KAGENT_EXTRA_VALUES:-}; do EXTRA+=(-f "$f"); done
# The post-renderer makes the controller wait for the Substrate API before it starts (issue #178, see kagent-postrender.sh).
helm upgrade --install kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent --version "$VER" -n kagent --timeout 12m -f values/kagent.yaml ${EXTRA[@]+"${EXTRA[@]}"} \
  --post-renderer ./kagent-postrender.sh
$K rollout status deployment/kagent-controller -n kagent --timeout=300s
