#!/usr/bin/env bash
# The digest reference of an image that was loaded into a kind cluster with `kind load docker-image`.
#   hack/kind-image-digest.sh <cluster> <repository>        prints <repository>@sha256:<64 hex>
# A container agent's image must be pinned by digest (ADR 0015). An image that exists only on the nodes has no registry to ask, so this asks
# the node: kind imports images with `ctr images import --digests`, which records <repository>@sha256:<manifest digest> next to the tag.
# That reference is what a pod may name; the kubelet finds the image in the node's store and never pulls (the repository is a name
# nobody serves). For a real cluster push the image to your registry and read the digest it prints (docker push, crane digest).
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <kind cluster> <repository>" >&2; exit 2; }
CLUSTER=$1; REPO=$2
NODE="${CLUSTER}-control-plane"
OUT=$(docker exec "$NODE" ctr --namespace=k8s.io images ls -q 2>/dev/null) || { echo "kind-image-digest: cannot list the images of node $NODE" >&2; exit 1; }
REF=$(printf '%s\n' "$OUT" | grep -E "^${REPO}@sha256:[0-9a-f]{64}\$" | sort | head -1 || true)
[ -n "$REF" ] || { echo "kind-image-digest: node $NODE has no digest reference for $REPO (found: $(printf '%s\n' "$OUT" | grep -F "$REPO" | tr '\n' ' '))" >&2; exit 1; }
printf '%s\n' "$REF"
