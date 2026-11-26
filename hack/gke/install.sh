#!/usr/bin/env bash
# Install the quick start on the cluster that hack/gke/up.sh made, with the settings of the first GKE run (issue 31):
#   hack/gke/install.sh <state file>
# It uses the separate kubeconfig of the run (never your default one), refuses after the deadline in the state file,
# sets SET_DEFAULT_STORAGECLASS=standard-rwo when the cluster has no default StorageClass, so the installer marks it (a new
# GKE cluster had none in the first run; GKE_KEEP_STORAGECLASS=1 skips that), then runs ./install.sh with:
#   CLUSTER_TYPE=remote PROFILE=quickstart NODE_SETTINGS=daemonset SKIP_SKILL=1 and the four SKIP_*_IMAGE=1, because the
#   images come from Artifact Registry through the values file up.sh wrote (built by Cloud Build).
#   GKE_IMAGES=installer instead lets ./install.sh build and push them itself (IMAGE_REGISTRY=<the run's repository>, ADR 0022):
#   no SKIP_*_IMAGE and no image values file; docker must be logged in to the repository. Not run on GKE yet.
# NODE_SETTINGS and other installer variables you set are passed on (NODE_SETTINGS=none for a run without the DaemonSet).
# VALUES_FILE you set is added after the image values file.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=hack/gke/lib.sh
. hack/gke/lib.sh
[ $# -eq 1 ] || die "usage: hack/gke/install.sh <state file written by hack/gke/up.sh>"
read_state "$1"
STATE=$STATE_DIR/$(basename "$1")
[ -z "$DELETED_AT" ] || die "project $PROJECT was deleted (state file says so)"
if [ "$(date -u +%s)" -ge "$DEADLINE" ]; then
  echo "ERROR: the deadline of this run ($(utc "$DEADLINE")) has passed. Delete the project:" >&2
  teardown_line "$STATE" "$DEADLINE" >&2
  exit 1
fi
command -v gcloud >/dev/null || die "gcloud is not installed"
project_is_ours || die "project $PROJECT does not carry created-by=$GKE_LABEL (or cannot be read); hack/gke/install.sh installs only into a project up.sh made"
[ -f "$KUBECONFIG_FILE" ] || die "no kubeconfig at $KUBECONFIG_FILE (up.sh did not finish?)"
export KUBECONFIG=$KUBECONFIG_FILE
CTX="gke_${PROJECT}_${ZONE}_${CLUSTER}"
teardown_line "$STATE" "$DEADLINE"

SC=$(kubectl --context="$CTX" get storageclass -o json 2>/dev/null || true)
DEF=$(jq -r '[.items[]? | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true") | .metadata.name] | first // empty' <<<"$SC" 2>/dev/null || true)
if [ -z "$DEF" ] && [ "${GKE_KEEP_STORAGECLASS:-0}" != 1 ]; then
  if jq -e '.items[]? | select(.metadata.name == "standard-rwo")' <<<"$SC" >/dev/null 2>&1; then
    echo "== no default StorageClass: the installer will mark standard-rwo (SET_DEFAULT_STORAGECLASS=standard-rwo; GKE_KEEP_STORAGECLASS=1 skips this)"
    export SET_DEFAULT_STORAGECLASS=standard-rwo
  else
    echo "WARN: no default StorageClass and no standard-rwo; the preflight will stop the install" >&2
  fi
fi

NS=${NODE_SETTINGS:-daemonset}; [ "$NS" = none ] && NS=""   # none: the installer skips the node settings (its default on remote)
export CLUSTER_TYPE=remote KUBE_CONTEXT="$CTX" PROFILE=quickstart NODE_SETTINGS="$NS" SKIP_SKILL=1
case "${GKE_IMAGES:-cloudbuild}" in
  cloudbuild) export SKIP_A2A_GATE_IMAGE=1 SKIP_STUB_MODEL_IMAGE=1 SKIP_CONTROL_PLANE_IMAGE=1 SKIP_CONSOLE_IMAGE=1 \
                VALUES_FILE="$VALUES_FILE_GKE${VALUES_FILE:+ $VALUES_FILE}";;
  # the installer builds with docker buildx on this machine and pushes to the run's repository (ADR 0022); log in first:
  # gcloud auth configure-docker <region>-docker.pkg.dev. On Apple silicon the amd64 build is slow (emulation).
  installer) export IMAGE_REGISTRY="$REPO" IMAGE_PLATFORM=linux/amd64;;
  *) die "GKE_IMAGES must be cloudbuild (default: the images up.sh built) or installer (IMAGE_REGISTRY: install.sh builds and pushes)";;
esac
echo "== ./install.sh on $CTX (NODE_SETTINGS=${NODE_SETTINGS:-none})"
exec "${OA_INSTALL_SH:-./install.sh}"   # OA_INSTALL_SH exists for the offline tests
