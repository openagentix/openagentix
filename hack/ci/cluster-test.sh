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
t "k3d create: one server, a volume for /var/lib/ate, no Traefik, no ServiceLB, the authentication config" "$(calls)" "k3d cluster create alpha --image rancher/k3s:v1.37.2-k3s1 --servers 1 --agents 0 --no-lb --wait --timeout 300s --volume k3d-alpha-ate:/var/lib/ate@server:0 --volume $PWD/hack/k3s-authn.yaml:/etc/openagentix/k3s-authn.yaml:ro@server:0 --k3s-arg --disable=traefik@server:0 --k3s-arg --disable=servicelb@server:0 --k3s-arg --kube-apiserver-arg=authentication-config=/etc/openagentix/k3s-authn.yaml@server:0;"
# k3s turns anonymous authentication off (anonymous-auth=false) unless an authentication config is given. The workload tool server fetches the
# public signing keys without a token (ADR 0019), so the config admits anonymous callers on the two discovery paths and nowhere else.
run k3d cluster_create hack/.. >/dev/null; t "k3d create: a relative repo root becomes an absolute mount path" "$(calls | grep -o "\-\-volume $PWD/hack/k3s-authn.yaml" )" "--volume $PWD/hack/k3s-authn.yaml"
t "k3s authn config: anonymous on" "$(yq -r '.anonymous.enabled' hack/k3s-authn.yaml 2>/dev/null)" true
t "k3s authn config: only the issuer document and the public keys" "$(yq -r '[.anonymous.conditions[].path]|sort|join(",")' hack/k3s-authn.yaml 2>/dev/null)" "/.well-known/openid-configuration,/openid/v1/jwks"
t "k3s authn config: no other authenticator" "$(yq -r 'keys|sort|join(",")' hack/k3s-authn.yaml 2>/dev/null)" "anonymous,apiVersion,kind"
t "k3d create never turns the network policy controller off" "$(grep -c 'disable-network-policy' hack/cluster.sh)" 0
K3D_NODE_IMAGE=rancher/k3s:v9 run k3d cluster_create . >/dev/null; t "K3D_NODE_IMAGE overrides the image" "$(calls | grep -o 'rancher/k3s:v9')" rancher/k3s:v9
run k3d cluster_load_images a:1 b:2 >/dev/null; t "k3d image import" "$(calls)" "k3d image import a:1 b:2 --cluster alpha;"
run k3d cluster_ctr images ls >/dev/null; t "k3d ctr uses the k3s containerd socket" "$(calls)" "docker exec k3d-alpha-server-0 ctr --address /run/k3s/containerd/containerd.sock --namespace=k8s.io images ls;"
t "k3d delete hint removes the cluster and its volume" "$(run k3d cluster_delete_hint)" "k3d cluster delete alpha && docker volume rm k3d-alpha-ate"

echo "# unknown type"
run podman cluster_check_type 2>/dev/null; t "unknown CLUSTER_TYPE is refused" "$?" 1
run k3d cluster_check_type; t "k3d is accepted" "$?" 0

echo "# node settings (issue #163): the two sysctls of components/runtime/NOTES.md"
: > "$D/calls"; run kind cluster_node_settings . >/dev/null; t "kind sets both sysctls with docker exec, as before" "$(calls)" "docker exec alpha-control-plane sysctl -w net.ipv4.conf.all.proxy_arp=1;docker exec alpha-control-plane sysctl -e -w net.ipv6.conf.all.proxy_ndp=1;"
run k3d cluster_node_settings . >/dev/null; t "k3d sets both sysctls with docker exec, as before" "$(calls)" "docker exec k3d-alpha-server-0 sysctl -w net.ipv4.conf.all.proxy_arp=1;docker exec k3d-alpha-server-0 sysctl -e -w net.ipv6.conf.all.proxy_ndp=1;"
t "kind prints nothing for the node settings (output unchanged)" "$(run kind cluster_node_settings . 2>&1; : > "$D/calls")" ""
NODE_SETTINGS=bogus run kind cluster_check_type 2>/dev/null; t "an unknown NODE_SETTINGS is refused" "$?" 1
t "install.sh has no docker exec for the sysctls left" "$(grep -c 'docker exec "$NODE" sysctl' install.sh)" 0
t "up.sh has no docker exec for the sysctls left" "$(grep -c 'docker exec "$NODE" sysctl' components/runtime/up.sh)" 0
t "install.sh calls cluster_node_settings" "$(grep -c '^cluster_node_settings "$ROOT"' install.sh)" 1
t "up.sh calls cluster_node_settings" "$(grep -c '^cluster_node_settings ../..' components/runtime/up.sh)" 1

echo "# remote (issue #161): an existing cluster named by KUBE_CONTEXT; nothing is created, nothing runs on a node"
# fake kubectl: `get --raw /version` answers when FAKE_API=up; every call is recorded
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
case "\$*" in *"get --raw /version"*) [ "\${FAKE_API:-}" = up ] || exit 1; echo '{"gitVersion":"v1.37.0"}';; esac
exit 0
EOS
cat > "$D/bin/gcloud" <<EOS
#!/usr/bin/env bash
echo "gcloud \$*" >> "$D/calls"
exit 0
EOS
chmod +x "$D/bin/kubectl" "$D/bin/gcloud"
R=gke_p_z_c
: > "$D/calls"
run remote cluster_check_type 2>"$D/err"; t "remote without KUBE_CONTEXT is refused" "$?" 1
t "the message names KUBE_CONTEXT" "$(grep -c 'CLUSTER_TYPE=remote needs KUBE_CONTEXT' "$D/err")" 1
KUBE_CONTEXT=$R run remote cluster_check_type; t "remote with a context is accepted" "$?" 0
for c in kind-openagentix k3d-openagentix kind-oa-ci-test docker-desktop; do
  KUBE_CONTEXT=$c run remote cluster_check_type 2>"$D/err"; t "remote refuses the local context $c" "$?" 1
done
t "the message says how to confirm" "$(grep -c 'ALLOW_LOCAL_CONTEXT=1' "$D/err")" 1
ALLOW_LOCAL_CONTEXT=1 KUBE_CONTEXT=kind-openagentix run remote cluster_check_type 2>/dev/null; t "ALLOW_LOCAL_CONTEXT=1 confirms a local context" "$?" 0
t "remote context is KUBE_CONTEXT" "$(KUBE_CONTEXT=$R run remote cluster_ctx)" "$R"
FAKE_API=up KUBE_CONTEXT=$R run remote cluster_exists; t "remote: exists when the API server answers" "$?" 0
t "remote: cluster_exists asks the API server of that context" "$(calls)" "kubectl --context $R get --raw /version;"
KUBE_CONTEXT=$R run remote cluster_exists; t "remote: does not exist when the API server does not answer" "$?" 1
: > "$D/calls"
KUBE_CONTEXT=$R run remote cluster_create . 2>"$D/err"; t "remote: cluster_create fails" "$?" 1
t "remote: cluster_create says it never creates a cluster" "$(grep -c 'never creates a cluster' "$D/err")" 1
KUBE_CONTEXT=$R run remote cluster_node 2>"$D/err"; t "remote: cluster_node fails" "$?" 1
t "remote: cluster_node says there is no node shell" "$(grep -c 'no node shell on a remote cluster' "$D/err")" 1
KUBE_CONTEXT=$R run remote cluster_ctr images ls 2>"$D/err"; t "remote: cluster_ctr fails" "$?" 1
t "remote: cluster_ctr says there is no node shell" "$(grep -c 'no node shell on a remote cluster' "$D/err")" 1
KUBE_CONTEXT=$R run remote cluster_network 2>/dev/null; t "remote: cluster_network fails (no Docker network)" "$?" 1
KUBE_CONTEXT=$R run remote cluster_load_images a:1 2>"$D/err"; t "remote: cluster_load_images fails (no registry push yet)" "$?" 1
t "remote: the load message names the registry issue" "$(grep -c 'issue #162' "$D/err")" 1
t "remote: delete hint points at the cloud teardown" "$(KUBE_CONTEXT=$R run remote cluster_delete_hint | grep -c 'install-gke.md#teardown')" 1
t "remote: delete hint runs nothing" "$(KUBE_CONTEXT=$R run remote cluster_delete_hint >/dev/null; calls)" ""
KUBE_CONTEXT=$R run remote cluster_node_settings . >"$D/out"; t "remote: node settings exit 0 by default" "$?" 0
t "remote: node settings run no docker exec by default" "$(calls)" ""
t "remote: the skip is said" "$(grep -c 'skipped on a remote cluster' "$D/out")" 1
NODE_SETTINGS=daemonset KUBE_CONTEXT=$R run remote cluster_node_settings . >/dev/null
t "NODE_SETTINGS=daemonset applies the manifest and waits, no docker exec" "$(calls)" "kubectl --context $R apply -f ./components/runtime/node-settings.yaml;kubectl --context $R -n openagentix-node-settings rollout status ds/node-settings --timeout=180s;"
: > "$D/calls"
for f in cluster_check_type cluster_ctx cluster_exists cluster_create cluster_node cluster_network cluster_load_images cluster_ctr cluster_delete_hint cluster_node_settings; do
  KUBE_CONTEXT=$R run remote "$f" . >/dev/null 2>&1
done
t "remote never calls kind, k3d, docker or gcloud" "$(grep -cE '^(kind|k3d|docker|gcloud) ' "$D/calls")" 0
exit $F
