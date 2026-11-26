#!/usr/bin/env bash
# How the installer builds its images (ADR 0022). Sourced by install.sh. Tests: hack/ci/images-test.sh (fake docker, no registry).
#
#   kind, k3d     docker build -q -t <image> [-f <Dockerfile>] <context>, then loaded into the nodes (hack/cluster.sh). As before.
#   remote        docker buildx build --platform $IMAGE_PLATFORM --push --provenance=false --sbom=false --metadata-file <file> ...
#                 to $IMAGE_REGISTRY/openagentix/<name>; the digest of the push is read from the metadata file and given to the chart.
#
#   IMAGE_REGISTRY=host[:port]/path   only with CLUSTER_TYPE=remote. Lower case, a host with a dot or a port, at least one path part, no scheme,
#                 no tag, no digest, no user:password@. ghcr.io/openagentix (the signed release images, ADR 0018) is refused.
#   IMAGE_PLATFORM=linux/amd64        only with CLUSTER_TYPE=remote (the default there). linux/arm64, or both comma separated.
#
# The installer never logs in to a registry and never handles a registry credential: the push uses the operator's own Docker login
# (Artifact Registry: gcloud auth configure-docker <region>-docker.pkg.dev). The nodes pull with their own credentials (no imagePullSecrets).
#
# Functions:
#   images_check                   refuses a bad combination or value (one line on stderr); sets IMAGE_PLATFORM=linux/amd64 on remote when unset
#   image_repo <name>              $IMAGE_REGISTRY/openagentix/<name> (name as in hack/ci/dockerfiles.sh, as the release uses)
#   image_example_repo <name>      $IMAGE_REGISTRY/openagentix-examples/<name> (container agent samples; a separate path, ADR 0022)
#   image_build <image> <context> <Dockerfile or ""> <metadata file>   builds (kind, k3d) or builds and pushes (remote); output to /dev/null
#   image_digest <metadata file>   prints containerimage.digest; fails unless it is sha256:<64 hex>

IMAGE_REGISTRY_RE='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
IMAGE_PLATFORM_RE='^linux/(amd64|arm64)(,linux/(amd64|arm64))?$'

images_check(){
  local ty=${CLUSTER_TYPE:-kind} reg=${IMAGE_REGISTRY:-} host lc
  if [ "$ty" != remote ]; then
    [ -z "$reg" ] || { echo "ERROR: IMAGE_REGISTRY is only for CLUSTER_TYPE=remote. On $ty the images are built locally and loaded into the nodes; unset IMAGE_REGISTRY. Nothing was changed." >&2; return 1; }
    [ -z "${IMAGE_PLATFORM:-}" ] || { echo "ERROR: IMAGE_PLATFORM is only for CLUSTER_TYPE=remote. On $ty the images are built for this machine's platform; unset IMAGE_PLATFORM. Nothing was changed." >&2; return 1; }
    return 0
  fi
  IMAGE_PLATFORM=${IMAGE_PLATFORM:-linux/amd64}
  [[ "$IMAGE_PLATFORM" =~ $IMAGE_PLATFORM_RE ]] || { echo "ERROR: IMAGE_PLATFORM must be linux/amd64, linux/arm64, or both comma separated (got '$IMAGE_PLATFORM'). Nothing was changed." >&2; return 1; }
  if [ -n "$reg" ]; then
    lc=$(printf '%s' "$reg" | tr '[:upper:]' '[:lower:]')
    case "$lc" in ghcr.io/openagentix|ghcr.io/openagentix/*)
      echo "ERROR: IMAGE_REGISTRY must not be ghcr.io/openagentix or under it: that path holds the signed release images (ADR 0018), and these are unsigned developer builds. Use a registry of your own. Nothing was changed." >&2; return 1;;
    esac
    case "$reg" in *@*) echo "ERROR: IMAGE_REGISTRY must be host[:port]/path, with no user, password, tag or digest (log in to the registry yourself, before the install). Nothing was changed." >&2; return 1;; esac
    host=${reg%%/*}
    if ! [[ "$reg" =~ $IMAGE_REGISTRY_RE ]] || { [[ "$host" != *.* ]] && [[ "$host" != *:* ]]; }; then
      echo "ERROR: IMAGE_REGISTRY must be host[:port]/path in lower case, the host with a dot or a port, at least one path part, no scheme, no trailing slash, no tag (got '$reg'; for example europe-west4-docker.pkg.dev/<project>/<repository>). Nothing was changed." >&2; return 1
    fi
  fi
  return 0
}
image_repo(){ printf '%s/openagentix/%s\n' "$IMAGE_REGISTRY" "$1"; }
image_example_repo(){ printf '%s/openagentix-examples/%s\n' "$IMAGE_REGISTRY" "$1"; }
image_build(){
  local img=$1 ctx=$2 df=${3:-} meta=$4
  if [ "${CLUSTER_TYPE:-kind}" = remote ]; then
    docker buildx build --platform "$IMAGE_PLATFORM" --push --provenance=false --sbom=false --metadata-file "$meta" -q -t "$img" ${df:+-f "$df"} "$ctx" >/dev/null
  else
    docker build -q -t "$img" ${df:+-f "$df"} "$ctx" >/dev/null
  fi
}
image_digest(){
  local d
  [ -s "$1" ] || { echo "ERROR: no build metadata file $1" >&2; return 1; }
  d=$(jq -r '."containerimage.digest" // empty' "$1" 2>/dev/null) || d=""
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: no image digest (sha256:<64 hex>) in the build metadata $1" >&2; return 1; }
  printf '%s\n' "$d"
}
