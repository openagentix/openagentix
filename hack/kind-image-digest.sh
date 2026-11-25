#!/usr/bin/env bash
# The digest reference of an image that was loaded into a kind cluster with `kind load docker-image`.
#   hack/kind-image-digest.sh <cluster> <repository> [<tag>]     prints <repository>@sha256:<64 hex>
# `kind load` imports the image under its tag only; the node has no <repository>@sha256 name (Docker with the containerd image
# store, which GitHub's runners and recent Docker Desktop use, does not add one). So this script reads the digest of the tagged
# image from the node (the DIGEST column of `ctr images ls`) and adds the digest name next to the tag on the node. A pod that uses
# <repository>@sha256:<digest> with imagePullPolicy IfNotPresent then starts from the node's copy; nothing is pulled.
# Pass the tag that was just loaded. A reused cluster keeps older tags and digest names of the same repository, and only the tag
# you loaded says which digest is meant. Without a tag the script works only when the node holds exactly one digest of the
# repository; with several it stops instead of guessing.
set -euo pipefail
[ $# -eq 2 ] || [ $# -eq 3 ] || { echo "usage: $0 <cluster> <repository> [<tag>]" >&2; exit 2; }
CLUSTER=$1; REPO=$2; TAG=${3:-}
cd "$(dirname "$0")/.." && . hack/cluster.sh   # CLUSTER_TYPE=kind (default) or k3d: the node name and the containerd socket differ
NODE=$(cluster_node)
OUT=$(cluster_ctr images ls 2>/dev/null) || { echo "kind-image-digest: cannot list the images of node $NODE" >&2; exit 1; }
FOUND=$(printf '%s\n' "$OUT" | awk -v r="$REPO" 'index($1, r) == 1 {print $1}' | tr '\n' ' ')
if [ -n "$TAG" ]; then
  LINE=$(printf '%s\n' "$OUT" | awk -v r="$REPO" -v t="$TAG" '$1 == r ":" t {print $1, $3}' | head -1 || true)
else
  # no tag named: every tag and digest name of the repository must agree on one digest
  ALL=$(printf '%s\n' "$OUT" | awk -v r="$REPO" 'index($1, r ":") == 1 || (index($1, r "@sha256:") == 1 && length($1) == length(r) + 72) {print $1, $3}' | sort || true)
  if [ "$(printf '%s\n' "$ALL" | awk 'NF {print $2}' | sort -u | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "kind-image-digest: node $NODE has several digests of $REPO; name the tag that was loaded (found: $FOUND)" >&2; exit 1
  fi
  LINE=$(printf '%s\n' "$ALL" | head -1)
fi
REF=${LINE%% *}; DIGEST=${LINE##* }
if [ -z "$LINE" ] || ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "kind-image-digest: node $NODE has no usable image for $REPO${TAG:+:$TAG} (found: $FOUND)" >&2; exit 1
fi
NAME="${REPO}@${DIGEST}"
# the name is already there: nothing to add
if printf '%s\n' "$OUT" | awk -v n="$NAME" '$1 == n {f=1} END {exit !f}'; then printf '%s\n' "$NAME"; exit 0; fi
cluster_ctr images tag "$REF" "$NAME" >/dev/null 2>&1 || { echo "kind-image-digest: cannot add the name $NAME on node $NODE" >&2; exit 1; }
printf '%s\n' "$NAME"
