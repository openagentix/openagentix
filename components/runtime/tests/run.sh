#!/usr/bin/env bash
# Offline tests of the runtime bring-up helpers (components/runtime). No cluster, no network. Needs: bash, jq, yq (the Python jq wrapper).
#   - the Substrate API authentication file for an in-cluster and an external issuer (issue #164, auth-config.sh)
#   - the opt-in node-settings DaemonSet (issue #163, node-settings.yaml)
# Usage: components/runtime/tests/run.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }   # eq desc actual expected
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT

echo "# Substrate API authentication (issue #164)"
# shellcheck source=../auth-config.sh
. "$HERE/auth-config.sh"
KIND_ISSUER=https://kubernetes.default.svc.cluster.local
# The file up.sh wrote before issue #164, byte for byte (kind and k3s have the in-cluster issuer above).
cat > "$D/before.yaml" <<EOF
jwtProviders:
- name: kubernetes
  issuer: $KIND_ISSUER
  audiences: [api.ate-system.svc]
  # in-cluster issuer (kind): these two lines are required; on GKE-style external issuers they must be omitted
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
EOF
ate_auth_config "$KIND_ISSUER" > "$D/kind.yaml"
eq "in-cluster issuer: byte-identical to the file before" "$(cmp -s "$D/before.yaml" "$D/kind.yaml" && echo same || echo differs)" same
eq "in-cluster issuer without the cluster domain keeps both lines" "$(ate_auth_config https://kubernetes.default.svc | grep -cE '^  (certificateAuthorityFile|discoveryTokenFile):')" 2
GKE_ISSUER=https://container.googleapis.com/v1/projects/p/locations/us-central1-a/clusters/c
ate_auth_config "$GKE_ISSUER" > "$D/gke.yaml"
eq "external issuer: neither line" "$(grep -cE 'certificateAuthorityFile|discoveryTokenFile' "$D/gke.yaml")" 0
eq "external issuer: the issuer is written" "$(yq -r '.jwtProviders[0].issuer' "$D/gke.yaml")" "$GKE_ISSUER"
eq "external issuer: same audience" "$(yq -c '.jwtProviders[0].audiences' "$D/gke.yaml")" '["api.ate-system.svc"]'
eq "another cluster domain is still in-cluster" "$(ate_auth_config https://kubernetes.default.svc.corp.internal | grep -c certificateAuthorityFile)" 1
eq "a host that only starts with the name is not in-cluster" "$(ate_auth_config https://kubernetes.default.svcx | grep -c certificateAuthorityFile)" 0
ate_auth_config "" >/dev/null 2>&1; eq "an empty issuer is refused" "$?" 1
# the issuer comes from the cluster: a fake kubectl answers the discovery document
mkdir -p "$D/bin"
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
[ "\$*" = "get --raw /.well-known/openid-configuration" ] && printf '%s' "\${FAKE_OIDC:-}"
EOS
chmod +x "$D/bin/kubectl"
OIDC=$(jq -nc --arg i "$GKE_ISSUER" '{issuer:$i,jwks_uri:"x"}')
eq "ate_issuer reads the discovery document" "$(PATH="$D/bin:$PATH" FAKE_OIDC=$OIDC ate_issuer)" "$GKE_ISSUER"
eq "ate_issuer asks the API server" "$(cat "$D/calls")" "kubectl get --raw /.well-known/openid-configuration"
PATH="$D/bin:$PATH" FAKE_OIDC='{}' ate_issuer >/dev/null 2>&1; eq "ate_issuer fails without an issuer" "$?" 1
eq "up.sh writes the file through ate_auth_config" "$(grep -c 'ate_auth_config "$ISSUER" > "$TMP/authentication.yaml"' "$HERE/up.sh")" 1
eq "up.sh has no heredoc for the file left" "$(grep -c 'cat > "$TMP/authentication.yaml"' "$HERE/up.sh")" 0

echo "# node-settings DaemonSet (issue #163)"
M="$HERE/node-settings.yaml"
DOCS=$(yq -c 'select(.!=null)' "$M")
kinds() { jq -r '.kind' <<<"$DOCS" | tr '\n' ' '; }
ds() { jq -c 'select(.kind=="DaemonSet")' <<<"$DOCS"; }
eq "a Namespace and a DaemonSet, nothing else" "$(kinds)" "Namespace DaemonSet "
eq "the namespace is its own" "$(jq -r 'select(.kind=="Namespace")|.metadata.name' <<<"$DOCS")" openagentix-node-settings
eq "privileged is allowed only in that namespace" "$(jq -r 'select(.kind=="Namespace")|.metadata.labels["pod-security.kubernetes.io/enforce"]' <<<"$DOCS")" privileged
eq "the DaemonSet is in that namespace" "$(ds | jq -r '.metadata.namespace+"/"+.metadata.name')" openagentix-node-settings/node-settings
eq "hostNetwork (the node's network namespace)" "$(ds | jq -r '.spec.template.spec.hostNetwork')" true
eq "one init container, privileged; it does the work" "$(ds | jq -r '[.spec.template.spec.initContainers[].securityContext.privileged]|tostring')" '[true]'
eq "the running container is not privileged and not root" "$(ds | jq -c '.spec.template.spec.containers[0].securityContext|[.privileged//false,.runAsNonRoot,.allowPrivilegeEscalation,.readOnlyRootFilesystem,.capabilities.drop]')" '[false,true,false,true,["ALL"]]'
eq "one running container only" "$(ds | jq -r '.spec.template.spec.containers|length')" 1
eq "no API token in the pod" "$(ds | jq -r '.spec.template.spec.automountServiceAccountToken')" false
CMD=$(ds | jq -r '.spec.template.spec.initContainers[0].args|join(" ")')
eq "it sets proxy_arp" "$(grep -c 'sysctl -w net.ipv4.conf.all.proxy_arp=1' <<<"$CMD")" 1
eq "it sets proxy_ndp" "$(grep -c 'sysctl -w net.ipv6.conf.all.proxy_ndp=1' <<<"$CMD")" 1
eq "then the running container only sleeps" "$(ds | jq -r '.spec.template.spec.containers[0].args|join(" ")' | grep -c '^exec sleep')" 1
eq "both images are pinned by digest" "$(ds | jq -r '.spec.template.spec|(.initContainers+.containers)[].image' | grep -cE '@sha256:[0-9a-f]{64}$')" 2
eq "no toleration: tainted (dedicated) nodes are left alone" "$(ds | jq -c '.spec.template.spec.tolerations // []')" '[]'
eq "the selector matches the pod labels" "$(ds | jq -r '(.spec.selector.matchLabels|to_entries) - (.spec.template.metadata.labels|to_entries) == []')" true
eq "nothing applies it by default (only cluster_node_settings, behind NODE_SETTINGS=daemonset)" "$(grep -lE '^[^#]*node-settings\.yaml' "$HERE/../../install.sh" "$HERE/up.sh" "$HERE/../../hack/cluster.sh" | sed 's|.*/||' | tr '\n' ' ')" "cluster.sh "

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
