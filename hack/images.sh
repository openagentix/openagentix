#!/usr/bin/env bash
# How the installer builds its images (ADR 0022). Sourced by install.sh. Tests: hack/ci/images-test.sh (fake docker, no registry).
#
#   kind, k3d     docker build -q -t <image> [-f <Dockerfile>] <context>, then loaded into the nodes (hack/cluster.sh). As before.
#   remote        to $IMAGE_REGISTRY/openagentix/<name>:dev-<hash of the source>-<arch>. When that tag is already in the registry for
#                 IMAGE_PLATFORM, its digest is used and nothing is built (IMAGE_REBUILD=1 builds and pushes again). Otherwise:
#                 docker buildx build --platform $IMAGE_PLATFORM --push --provenance=false --sbom=false --metadata-file <file> ...
#                 The digest comes from the metadata file and is checked in the registry (it exists, and it is IMAGE_PLATFORM).
#
#   IMAGE_REGISTRY=host[:port]/path   only with CLUSTER_TYPE=remote. Lower case, a host with a dot or a port, at least one path part, no scheme,
#                 no tag, no digest, no user:password@. ghcr.io/openagentix (the signed release images, ADR 0018) is refused.
#   IMAGE_PLATFORM=linux/amd64        only with CLUSTER_TYPE=remote (the default there), or linux/arm64. One platform only for now.
#   IMAGE_REBUILD=1                   build and push even when the tag is already in the registry.
#   BUILDX_BUILDER                    read by buildx itself (a remote amd64 builder is the fast path on Apple silicon).
#
# The installer never logs in to a registry and never handles a registry credential: the push uses the operator's own Docker login
# (Artifact Registry: gcloud auth configure-docker <region>-docker.pkg.dev). The nodes pull with their own credentials (no imagePullSecrets).
# The output format of `buildx imagetools inspect --format` and the metadata file are taken from the buildx documentation; the tests use fixtures.
#
# Functions:
#   images_check                   refuses a bad combination or value (one line on stderr); sets IMAGE_PLATFORM=linux/amd64 on remote when unset
#   image_repo <name>              $IMAGE_REGISTRY/openagentix/<name> (name as in hack/ci/dockerfiles.sh, as the release uses)
#   image_example_repo <name>      $IMAGE_REGISTRY/openagentix-examples/<name> (container agent samples; a separate path)
#   image_remote_tag <tag>         <tag>-<arch of IMAGE_PLATFORM>
#   image_build <image> <context> <Dockerfile or ""> <metadata file>   kind, k3d: build. remote: reuse or build and push, then check;
#                                  the metadata file then holds containerimage.digest
#   image_digest <metadata file>   prints containerimage.digest; fails unless it is sha256:<64 hex>

IMAGE_REGISTRY_RE='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'

images_check(){
  local ty=${CLUSTER_TYPE:-kind} reg=${IMAGE_REGISTRY:-} host first
  if [ "$ty" != remote ]; then
    [ -z "$reg" ] || { echo "ERROR: IMAGE_REGISTRY is only for CLUSTER_TYPE=remote. On $ty the images are built locally and loaded into the nodes; unset IMAGE_REGISTRY. Nothing was changed." >&2; return 1; }
    [ -z "${IMAGE_PLATFORM:-}" ] || { echo "ERROR: IMAGE_PLATFORM is only for CLUSTER_TYPE=remote. On $ty the images are built for this machine's platform; unset IMAGE_PLATFORM. Nothing was changed." >&2; return 1; }
    return 0
  fi
  IMAGE_PLATFORM=${IMAGE_PLATFORM:-linux/amd64}
  case "$IMAGE_PLATFORM" in
    linux/amd64|linux/arm64) ;;
    linux/amd64,linux/arm64|linux/arm64,linux/amd64) echo "ERROR: IMAGE_PLATFORM takes one platform for now (linux/amd64 or linux/arm64); two platforms are a later step of ADR 0022. Nothing was changed." >&2; return 1;;
    *) echo "ERROR: IMAGE_PLATFORM must be linux/amd64 or linux/arm64 (got '$IMAGE_PLATFORM'). Nothing was changed." >&2; return 1;;
  esac
  [ -n "$reg" ] || return 0
  case "$reg" in *@*) echo "ERROR: IMAGE_REGISTRY must be host[:port]/path, with no user, password, tag or digest (log in to the registry yourself, before the install). Nothing was changed." >&2; return 1;; esac
  host=${reg%%/*}
  if ! [[ "$reg" =~ $IMAGE_REGISTRY_RE ]] || { [[ "$host" != *.* ]] && [[ "$host" != *:* ]]; }; then
    echo "ERROR: IMAGE_REGISTRY must be host[:port]/path in lower case, the host with a dot or a port, at least one path part, no scheme, no trailing slash, no tag (got '$reg'; for example europe-west4-docker.pkg.dev/<project>/<repository>). Nothing was changed." >&2; return 1
  fi
  first=${reg#*/}; first=${first%%/*}
  if [ "${host%:443}" = ghcr.io ] && [ "$first" = openagentix ]; then
    echo "ERROR: IMAGE_REGISTRY must not be ghcr.io/openagentix or under it: that path holds the signed release images (ADR 0018), and these are unsigned developer builds. Use a registry of your own. Nothing was changed." >&2; return 1
  fi
  return 0
}
image_repo(){ printf '%s/openagentix/%s\n' "$IMAGE_REGISTRY" "$1"; }
image_example_repo(){ printf '%s/openagentix-examples/%s\n' "$IMAGE_REGISTRY" "$1"; }
image_remote_tag(){ printf '%s-%s\n' "$1" "${IMAGE_PLATFORM#*/}"; }
# image_platform <ref>: os/architecture of a single-platform image in the registry; fails when the reference is not there
image_platform(){ docker buildx imagetools inspect "$1" --format '{{json .Image}}' 2>/dev/null | jq -er '"\(.os)/\(.architecture)"' 2>/dev/null; }
image_build(){
  local img=$1 ctx=$2 df=${3:-} meta=$4 have="" d repo
  if [ "${CLUSTER_TYPE:-kind}" != remote ]; then docker build -q -t "$img" ${df:+-f "$df"} "$ctx" >/dev/null; return; fi
  repo=${img%:*}
  have=$(image_platform "$img") || have=""
  if [ -n "$have" ] && [ "${IMAGE_REBUILD:-0}" != 1 ]; then
    [ "$have" = "$IMAGE_PLATFORM" ] || { echo "ERROR: tag $img exists for platform $have, not $IMAGE_PLATFORM; delete it or set IMAGE_REBUILD=1" >&2; return 1; }
    d=$(docker buildx imagetools inspect "$img" --format '{{json .Manifest}}' 2>/dev/null | jq -r '.digest // empty' 2>/dev/null) || d=""
    printf '{"containerimage.digest":"%s"}\n' "$d" > "$meta"
    echo "image $img is in the registry for $IMAGE_PLATFORM: not rebuilt (IMAGE_REBUILD=1 rebuilds)" >&2
  elif ! docker buildx build --platform "$IMAGE_PLATFORM" --push --provenance=false --sbom=false --metadata-file "$meta" -q -t "$img" ${df:+-f "$df"} "$ctx" >/dev/null; then
    [ -z "$have" ] || echo "ERROR: the push of $img failed while the tag already existed: this registry does not allow overwriting a tag; remove IMAGE_REBUILD" >&2
    return 1
  fi
  d=$(image_digest "$meta") || return 1
  docker buildx imagetools inspect --raw "$repo@$d" >/dev/null 2>&1 || { echo "ERROR: $repo@$d is not in the registry after the push" >&2; return 1; }
  have=$(image_platform "$repo@$d") || have="unknown"
  [ "$have" = "$IMAGE_PLATFORM" ] || { echo "ERROR: $repo@$d is $have, not $IMAGE_PLATFORM" >&2; return 1; }
}
image_digest(){
  local d
  [ -s "$1" ] || { echo "ERROR: no build metadata file $1" >&2; return 1; }
  d=$(jq -r '."containerimage.digest" // empty' "$1" 2>/dev/null) || d=""
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "ERROR: no image digest (sha256:<64 hex>) in the build metadata $1" >&2; return 1; }
  printf '%s\n' "$d"
}
# images_render_check <rendered documents, one JSON per line> [<built path>...]: the rule for platform images on remote (ADR 0022), run on the
# final render before helm upgrade. For the images of the eight installer-built paths: an unqualified name (no dot or port in the first part,
# so Docker Hub) is refused; with IMAGE_REGISTRY every one must be under it; an image the installer built must have a digest; an image the
# operator supplies by tag is allowed with a warning. Errors and warnings go to stderr; returns 1 on an error.
images_render_check(){
  local rendered=$1 path img first bad=0 built
  shift; built=" $* "
  while IFS=$'\t' read -r path img; do
    [ -n "$path" ] || continue
    first=${img%%/*}
    if [ "$first" = "$img" ] || { [[ "$first" != *.* ]] && [[ "$first" != *:* ]]; }; then
      echo "ERROR: $path: $img is an unqualified name, which a remote cluster pulls from Docker Hub. Let the installer build it (IMAGE_REGISTRY) or set $path.image.repository to your registry." >&2; bad=1; continue
    fi
    if [ -n "${IMAGE_REGISTRY:-}" ] && [[ "$img" != "$IMAGE_REGISTRY/"* ]]; then
      echo "ERROR: $path: $img is not under IMAGE_REGISTRY=$IMAGE_REGISTRY/." >&2; bad=1; continue
    fi
    if [[ "$built" == *" $path "* ]]; then
      [[ "$img" == *@sha256:* ]] || { echo "ERROR: $path: the installer built $img but it has no digest." >&2; bad=1; }
    elif [[ "$img" != *@sha256:* ]]; then
      echo "WARN: $path runs $img by tag; set $path.image.digest to pin it" >&2
    fi
  done < <(jq -r 'select(type=="object")
      | (if .kind=="CronJob" and .metadata.labels["openagentix.io/schedule"]!=null then ["scheduling", .spec.jobTemplate.spec.template.spec.containers[0].image]
         elif .kind=="Deployment" then
           ({"telegram-bridge":"bridge","stub-model":"gateway.stubModel","kb":"knowledge.kb","notify":"notify","a2a-gate":"governance.a2a",
             "openagentix-control-plane":"controlPlane","openagentix-console":"console"}[.metadata.name]) as $p
           | if $p then [$p, .spec.template.spec.containers[0].image] else empty end
         else empty end) | select(.[1]!=null) | @tsv' <<<"$rendered" | sort -u)
  return "$bad"
}
