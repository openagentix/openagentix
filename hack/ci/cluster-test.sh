#!/usr/bin/env bash
# Tests for hack/cluster.sh with fake `kind`, `k3d` and `docker` (no cluster): the commands the installer runs for each CLUSTER_TYPE.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
for c in kind k3d docker; do
  cat > "$D/bin/$c" <<EOS
#!/usr/bin/env bash
echo "$c \$*" >> "$D/calls"
if [ "$c" = kind ] && [ "\$1 \$2" = "get clusters" ]; then printf 'other\nalpha\n'; fi
if [ "$c" = k3d ] && [ "\$1 \$2" = "cluster list" ]; then echo '[{"name":"alpha"},{"name":"beta"}]'; fi
exit 0
EOS
  chmod +x "$D/bin/$c"
done
export PATH="$D/bin:$PATH"
: > "$D/calls"
calls(){ tr '\n' ';' < "$D/calls"; : > "$D/calls"; }
# run <type> <function> [args]: the function in a subshell with CLUSTER=${CLUSTER:-alpha}
run(){ local ty=$1; shift; ( CLUSTER_TYPE=$ty; CLUSTER=${CLUSTER:-alpha}; . hack/cluster.sh; "$@" ); }

echo "# kind (the default)"
t "default type is kind" "$(unset CLUSTER_TYPE; CLUSTER=alpha; . hack/cluster.sh; echo "$CLUSTER_TYPE")" kind
t "kind context" "$(run kind cluster_ctx)" kind-alpha
t "kind node" "$(run kind cluster_node)" alpha-control-plane
t "kind network" "$(run kind cluster_network)" kind
run kind cluster_exists; t "kind: alpha exists" "$?" 0
CLUSTER=gamma run kind cluster_exists; t "kind: gamma does not exist" "$?" 1
: > "$D/calls"; run kind cluster_create . >/dev/null; t "kind create uses the kind config" "$(calls)" "kind create cluster --name alpha --config ./hack/kind-config.yaml;"
run kind cluster_load_images a:1 b:2 >/dev/null; t "kind load" "$(calls)" "kind load docker-image a:1 b:2 --name alpha;"
run kind cluster_ctr images ls >/dev/null; t "kind ctr" "$(calls)" "docker exec alpha-control-plane ctr --namespace=k8s.io images ls;"
t "kind delete hint" "$(run kind cluster_delete_hint)" "kind delete cluster --name alpha"

echo "# k3d"
t "k3d context" "$(run k3d cluster_ctx)" k3d-alpha
t "k3d node" "$(run k3d cluster_node)" k3d-alpha-server-0
t "k3d network" "$(run k3d cluster_network)" k3d-alpha
run k3d cluster_exists; t "k3d: alpha exists" "$?" 0
CLUSTER=gamma run k3d cluster_exists; t "k3d: gamma does not exist" "$?" 1
: > "$D/calls"; run k3d cluster_create . >/dev/null
t "k3d create: one server, no Traefik, no ServiceLB" "$(calls)" "k3d cluster create alpha --image rancher/k3s:v1.37.2-k3s1 --servers 1 --agents 0 --no-lb --wait --timeout 300s --k3s-arg --disable=traefik@server:0 --k3s-arg --disable=servicelb@server:0;"
t "k3d create never turns the network policy controller off" "$(grep -c 'disable-network-policy' hack/cluster.sh)" 0
K3D_NODE_IMAGE=rancher/k3s:v9 run k3d cluster_create . >/dev/null; t "K3D_NODE_IMAGE overrides the image" "$(calls | grep -o 'rancher/k3s:v9')" rancher/k3s:v9
run k3d cluster_load_images a:1 b:2 >/dev/null; t "k3d image import" "$(calls)" "k3d image import a:1 b:2 --cluster alpha;"
run k3d cluster_ctr images ls >/dev/null; t "k3d ctr uses the k3s containerd socket" "$(calls)" "docker exec k3d-alpha-server-0 ctr --address /run/k3s/containerd/containerd.sock --namespace=k8s.io images ls;"
t "k3d delete hint" "$(run k3d cluster_delete_hint)" "k3d cluster delete alpha"

echo "# unknown type"
run podman cluster_check_type 2>/dev/null; t "unknown CLUSTER_TYPE is refused" "$?" 1
run k3d cluster_check_type; t "k3d is accepted" "$?" 0
exit $F
