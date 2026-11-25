#!/usr/bin/env bash
# The digest reference of an image that was loaded into a kind cluster with `kind load docker-image`.
#   hack/kind-image-digest.sh <cluster> <repository>        prints <repository>@sha256:<64 hex>
# `kind load` imports the image under its tag only; the node has no <repository>@sha256 name (Docker with the containerd image
# store, which GitHub's runners and recent Docker Desktop use, does not add one). So this script reads the digest of the tagged
# image from the node (the DIGEST column of `ctr images ls`) and adds the digest name next to the tag on the node. A pod that uses
# <repository>@sha256:<digest> with imagePullPolicy IfNotPresent then starts from the node's copy; nothing is pulled.
# If several tags of the repository are on the node, the first in sort order is used.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <kind cluster> <repository>" >&2; exit 2; }
CLUSTER=$1; REPO=$2
NODE="${CLUSTER}-control-plane"
OUT=$(docker exec "$NODE" ctr --namespace=k8s.io images ls 2>/dev/null) || { echo "kind-image-digest: cannot list the images of node $NODE" >&2; exit 1; }
# a digest name that is already there wins
REF=$(printf '%s\n' "$OUT" | awk -v r="$REPO" 'index($1, r "@sha256:") == 1 && length($1) == length(r) + 72 {print $1}' | sort | head -1 || true)
if [ -n "$REF" ]; then printf '%s\n' "$REF"; exit 0; fi
LINE=$(printf '%s\n' "$OUT" | awk -v r="$REPO" 'index($1, r ":") == 1 {print $1, $3}' | sort | head -1 || true)
TAGGED=${LINE%% *}; DIGEST=${LINE##* }
if [ -z "$LINE" ] || ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "kind-image-digest: node $NODE has no usable image for $REPO (found: $(printf '%s\n' "$OUT" | awk -v r="$REPO" 'index($1, r) == 1 {print $1}' | tr '\n' ' '))" >&2; exit 1
fi
docker exec "$NODE" ctr --namespace=k8s.io images tag "$TAGGED" "${REPO}@${DIGEST}" >/dev/null 2>&1 || { echo "kind-image-digest: cannot add the name ${REPO}@${DIGEST} on node $NODE" >&2; exit 1; }
printf '%s\n' "${REPO}@${DIGEST}"
