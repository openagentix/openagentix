#!/usr/bin/env bash
# What differs between the clusters the installer works with. Sourced by install.sh, components/runtime/up.sh and uninstall.sh.
# Tests: hack/ci/cluster-test.sh (fake kind, k3d, docker, kubectl and gcloud; no cluster).
#
#   CLUSTER_TYPE=kind (default)   a kind cluster named $CLUSTER, context kind-$CLUSTER
#   CLUSTER_TYPE=k3d              a k3s cluster in Docker made by k3d, named $CLUSTER, context k3d-$CLUSTER (see docs/diary/guide/install-k3s.md)
#   CLUSTER_TYPE=remote           an EXISTING cluster (for example GKE), context $KUBE_CONTEXT (required). Never created or deleted here, no
#                                 node shell (no docker exec, no ctr), images are not loaded (a registry push is issue #162, not built yet).
#                                 A local context name (kind-*, k3d-*, docker-desktop, ...) is refused unless ALLOW_LOCAL_CONTEXT=1.
#                                 Run once on GKE (images built by hand): docs/diary/guide/install-gke.md.
#   K3D_NODE_IMAGE=rancher/k3s:v1.37.2-k3s1   the k3s image k3d starts (the runtime needs Kubernetes 1.37 or newer)
#   NODE_SETTINGS=daemonset       set the node sysctls with components/runtime/node-settings.yaml (privileged DaemonSet in its own namespace)
#                                 instead of docker exec. Default: docker exec on kind and k3d, nothing on remote.
#
# Functions (all read CLUSTER and CLUSTER_TYPE; remote also KUBE_CONTEXT):
#   cluster_check_type            fails for a type that is not known (and, for remote, without a usable KUBE_CONTEXT)
#   cluster_ctx                   kube context name
#   cluster_node                  Docker container name of the (first) node (fails on remote)
#   cluster_network               Docker network of the nodes (fails on remote)
#   cluster_exists                0 when the cluster exists (remote: its API server answers)
#   cluster_create <repo root>    creates it (kind: hack/kind-config.yaml; k3d: one server, no Traefik, no ServiceLB, NetworkPolicy left on; remote: fails)
#   cluster_load_images <image>.. copies local Docker images into the nodes (fails on remote)
#   cluster_ctr <args>            runs `ctr` in the k8s.io namespace on the node (fails on remote)
#   cluster_delete_hint           the command that removes the cluster (remote: the cloud teardown, nothing is run)
#   cluster_node_settings <root>  the two sysctls of components/runtime/NOTES.md (proxy_arp, proxy_ndp); see NODE_SETTINGS

CLUSTER_TYPE=${CLUSTER_TYPE:-kind}
K3D_NODE_IMAGE=${K3D_NODE_IMAGE:-rancher/k3s:v1.37.2-k3s1}

cluster_remote_only_err(){ echo "ERROR: $1: no node shell on a remote cluster (CLUSTER_TYPE=remote)" >&2; return 1; }
cluster_check_type(){
  case "$CLUSTER_TYPE" in
    kind|k3d) ;;
    remote)
      [ -n "${KUBE_CONTEXT:-}" ] || { echo "ERROR: CLUSTER_TYPE=remote needs KUBE_CONTEXT, the kubectl context of the existing cluster (kubectl config get-contexts)" >&2; return 1; }
      case "$KUBE_CONTEXT" in
        kind-*|k3d-*|docker-desktop|rancher-desktop|minikube|orbstack|colima)
          [ "${ALLOW_LOCAL_CONTEXT:-0}" = 1 ] || { echo "ERROR: CLUSTER_TYPE=remote with KUBE_CONTEXT=$KUBE_CONTEXT, which is the name of a local cluster. For kind or k3d use CLUSTER_TYPE=kind or k3d. Set ALLOW_LOCAL_CONTEXT=1 if you really mean it." >&2; return 1; } ;;
      esac ;;
    *) echo "ERROR: unknown CLUSTER_TYPE '$CLUSTER_TYPE' (known: kind, k3d, remote)" >&2; return 1;;
  esac
  case "${NODE_SETTINGS:-}" in ""|daemonset) ;; *) echo "ERROR: unknown NODE_SETTINGS '$NODE_SETTINGS' (known: daemonset; leave it unset for the default)" >&2; return 1;; esac
}
cluster_ctx(){ if [ "$CLUSTER_TYPE" = remote ]; then echo "${KUBE_CONTEXT:-}"; else echo "$CLUSTER_TYPE-$CLUSTER"; fi; }
cluster_node(){
  case "$CLUSTER_TYPE" in kind) echo "$CLUSTER-control-plane";; k3d) echo "k3d-$CLUSTER-server-0";; remote) cluster_remote_only_err "the node container";; esac
}
cluster_network(){
  case "$CLUSTER_TYPE" in kind) echo kind;; k3d) echo "k3d-$CLUSTER";; remote) echo "ERROR: a remote cluster has no local Docker network" >&2; return 1;; esac
}
cluster_exists(){
  case "$CLUSTER_TYPE" in
    kind) kind get clusters 2>/dev/null | grep -qx "$CLUSTER";;
    k3d) k3d cluster list -o json 2>/dev/null | jq -e --arg c "$CLUSTER" 'any(.[]; .name==$c)' >/dev/null 2>&1;;
    remote) ${KUBECTL:-kubectl} --context "${KUBE_CONTEXT:-}" get --raw /version >/dev/null 2>&1;;
  esac
}
cluster_create(){
  case "$CLUSTER_TYPE" in
    kind) kind create cluster --name "$CLUSTER" --config "${1:-.}/hack/kind-config.yaml";;
    # Traefik and ServiceLB are off: nothing in the chart uses an Ingress or a LoadBalancer, and ServiceLB would claim host ports.
    # /var/lib/ate is a Docker volume: the runtime builds a sandbox root file system there and makes overlay whiteouts (mknod c 0 0), which the
    # container's own overlay root refuses ("operation not permitted", even with --privileged). kind mounts /var as a volume, k3d does not.
    # The k3s network policy controller stays ON (it is the point of the test: k3s enforces NetworkPolicy).
    k3d) k3d cluster create "$CLUSTER" --image "$K3D_NODE_IMAGE" --servers 1 --agents 0 --no-lb --wait --timeout 300s \
           --volume "k3d-$CLUSTER-ate:/var/lib/ate@server:0" \
           --k3s-arg "--disable=traefik@server:0" --k3s-arg "--disable=servicelb@server:0";;
    remote) echo "ERROR: CLUSTER_TYPE=remote never creates a cluster. Create it with the cloud's own tool (GKE: gcloud container clusters create, see docs/diary/guide/install-gke.md) and set KUBE_CONTEXT to its context." >&2; return 1;;
  esac
}
cluster_load_images(){
  case "$CLUSTER_TYPE" in
    kind) kind load docker-image "$@" --name "$CLUSTER";;
    k3d) k3d image import "$@" --cluster "$CLUSTER";;
    remote) echo "ERROR: CLUSTER_TYPE=remote cannot copy local images into the nodes. Pushing them to a registry (IMAGE_REGISTRY) is issue #162 and not built yet." >&2; return 1;;
  esac
}
cluster_ctr(){
  case "$CLUSTER_TYPE" in
    kind) docker exec "$(cluster_node)" ctr --namespace=k8s.io "$@";;
    k3d) docker exec "$(cluster_node)" ctr --address /run/k3s/containerd/containerd.sock --namespace=k8s.io "$@";;
    remote) cluster_remote_only_err "ctr";;
  esac
}
cluster_delete_hint(){
  case "$CLUSTER_TYPE" in
    kind) echo "kind delete cluster --name $CLUSTER";;
    k3d) echo "k3d cluster delete $CLUSTER && docker volume rm k3d-$CLUSTER-ate";;
    remote) echo "./uninstall.sh, then delete the LoadBalancer Services and the PVCs (cloud load balancers and disks outlive a cluster and cost money), then the cluster with the cloud's own tool: docs/diary/guide/install-gke.md#teardown";;
  esac
}
# The two sysctls upstream sets for gVisor pod networking (components/runtime/NOTES.md: never proven necessary here).
cluster_node_settings(){
  if [ "${NODE_SETTINGS:-}" = daemonset ]; then
    local ctx=${KUBE_CONTEXT:-$(cluster_ctx)}   # named, not the current context: this applies a privileged workload
    ${KUBECTL:-kubectl} --context "$ctx" apply -f "${1:-.}/components/runtime/node-settings.yaml" >/dev/null
    ${KUBECTL:-kubectl} --context "$ctx" -n openagentix-node-settings rollout status ds/node-settings --timeout=180s
    return
  fi
  if [ "$CLUSTER_TYPE" = remote ]; then
    echo "node settings: skipped on a remote cluster (no node shell). NODE_SETTINGS=daemonset sets them with components/runtime/node-settings.yaml."
    return 0
  fi
  local node; node=$(cluster_node)
  docker exec "$node" sysctl -w net.ipv4.conf.all.proxy_arp=1 >/dev/null
  docker exec "$node" sysctl -e -w net.ipv6.conf.all.proxy_ndp=1 >/dev/null
}
