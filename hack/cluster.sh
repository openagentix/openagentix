#!/usr/bin/env bash
# What differs between the local clusters the installer can create. Sourced by install.sh, components/runtime/up.sh and uninstall.sh.
# Tests: hack/ci/cluster-test.sh (fake kind, k3d and docker; no cluster).
#
#   CLUSTER_TYPE=kind (default)   a kind cluster named $CLUSTER, context kind-$CLUSTER
#   CLUSTER_TYPE=k3d              a k3s cluster in Docker made by k3d, named $CLUSTER, context k3d-$CLUSTER (see docs/guides/install-k3s.md)
#   K3D_NODE_IMAGE=rancher/k3s:v1.37.2-k3s1   the k3s image k3d starts (the runtime needs Kubernetes 1.37 or newer)
#
# Functions (all read CLUSTER and CLUSTER_TYPE):
#   cluster_check_type            fails for a type that is not known
#   cluster_ctx                   kube context name
#   cluster_node                  Docker container name of the (first) node
#   cluster_network               Docker network of the nodes
#   cluster_exists                0 when the cluster exists
#   cluster_create <repo root>    creates it (kind: hack/kind-config.yaml; k3d: one server, no Traefik, no ServiceLB, NetworkPolicy left on)
#   cluster_load_images <image>.. copies local Docker images into the nodes
#   cluster_ctr <args>            runs `ctr` in the k8s.io namespace on the node
#   cluster_delete_hint           the command that removes the cluster

CLUSTER_TYPE=${CLUSTER_TYPE:-kind}
K3D_NODE_IMAGE=${K3D_NODE_IMAGE:-rancher/k3s:v1.37.2-k3s1}

cluster_check_type(){
  case "$CLUSTER_TYPE" in kind|k3d) ;; *) echo "ERROR: unknown CLUSTER_TYPE '$CLUSTER_TYPE' (known: kind, k3d)" >&2; return 1;; esac
}
cluster_ctx(){ echo "$CLUSTER_TYPE-$CLUSTER"; }
cluster_node(){
  case "$CLUSTER_TYPE" in kind) echo "$CLUSTER-control-plane";; k3d) echo "k3d-$CLUSTER-server-0";; esac
}
cluster_network(){
  case "$CLUSTER_TYPE" in kind) echo kind;; k3d) echo "k3d-$CLUSTER";; esac
}
cluster_exists(){
  case "$CLUSTER_TYPE" in
    kind) kind get clusters 2>/dev/null | grep -qx "$CLUSTER";;
    k3d) k3d cluster list -o json 2>/dev/null | jq -e --arg c "$CLUSTER" 'any(.[]; .name==$c)' >/dev/null 2>&1;;
  esac
}
cluster_create(){
  case "$CLUSTER_TYPE" in
    kind) kind create cluster --name "$CLUSTER" --config "${1:-.}/hack/kind-config.yaml";;
    # Traefik and ServiceLB are off: nothing in the chart uses an Ingress or a LoadBalancer, and ServiceLB would claim host ports.
    # The k3s network policy controller stays ON (it is the point of the test: k3s enforces NetworkPolicy).
    k3d) k3d cluster create "$CLUSTER" --image "$K3D_NODE_IMAGE" --servers 1 --agents 0 --no-lb --wait --timeout 300s \
           --k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0";;
  esac
}
cluster_load_images(){
  case "$CLUSTER_TYPE" in
    kind) kind load docker-image "$@" --name "$CLUSTER";;
    k3d) k3d image import "$@" --cluster "$CLUSTER";;
  esac
}
cluster_ctr(){
  case "$CLUSTER_TYPE" in
    kind) docker exec "$(cluster_node)" ctr --namespace=k8s.io "$@";;
    k3d) docker exec "$(cluster_node)" ctr --address /run/k3s/containerd/containerd.sock --namespace=k8s.io "$@";;
  esac
}
cluster_delete_hint(){
  case "$CLUSTER_TYPE" in kind) echo "kind delete cluster --name $CLUSTER";; k3d) echo "k3d cluster delete $CLUSTER";; esac
}
