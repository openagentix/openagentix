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

echo "# kagent database secrets: no password in a process argument"
# shellcheck source=../kagent-db.sh
. "$HERE/kagent-db.sh"
mkdir -p "$D/dbbin"
# The fake kubectl records every argument, the standard input of exec, and the files behind --from-file.
cat > "$D/dbbin/kubectl" <<EOS
#!/usr/bin/env bash
echo "ARGV: \$*" >> "$D/db-argv"
case "\$*" in *"get secret"*) exit 1;; esac
for a in "\$@"; do case "\$a" in --from-file=*) echo "FILE: \$(cat "\${a##*=}")" >> "$D/db-in";; esac; done
case "\$*" in *" exec "*) cat >> "$D/db-in";; esac
exit 0
EOS
# openssl gives a different canary on each call, so a leak of either password is found
cat > "$D/dbbin/openssl" <<EOS
#!/usr/bin/env bash
n=\$(cat "$D/dbn" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$D/dbn"
printf 'canary%02dcanary\n' "\$n"
EOS
chmod +x "$D/dbbin/kubectl" "$D/dbbin/openssl"
(cd "$HERE" && PATH="$D/dbbin:$PATH" KUBECTL="$D/dbbin/kubectl" kagent_pg_admin_secret && PATH="$D/dbbin:$PATH" KUBECTL="$D/dbbin/kubectl" kagent_db_secrets) >/dev/null 2>&1
eq "every kubectl call was recorded (2 gets, 3 creates, 1 exec)" "$(grep -c '^ARGV:' "$D/db-argv")" 6
eq "no password value in any argument" "$(grep -c 'canary' "$D/db-argv")" 0
eq "the admin password is passed as a file" "$(grep -c '^FILE: canary01canary$' "$D/db-in")" 1
eq "the owner password reaches psql on standard input" "$(grep -c "kagent_owner_password 'canary02canary'" "$D/db-in")" 1
eq "the read and write password reaches psql on standard input" "$(grep -c "kagent_readwrite_password 'canary03canary'" "$D/db-in")" 1
eq "the setup SQL follows on standard input" "$(grep -c 'kagent.setup_owner_password' "$D/db-in")" 2
eq "both connection strings are passed as files" "$(grep -cE '^FILE: postgresql://kagent_(owner|readwrite)_user:canary0[23]canary@' "$D/db-in")" 2
eq "no --from-literal is used" "$(grep -c -- '--from-literal' "$D/db-argv")" 0
eq "up.sh uses the helpers" "$(grep -cE '^kagent_(pg_admin_secret|db_secrets)$' "$HERE/up.sh")" 2

echo "# kagent controller waits for the Substrate API before it starts (issue #178)"
# kagent 1.0.1 gives the Substrate API 10 s at start-up (substrate.Dial, not configurable) and exits when it does not answer.
# The helm post-renderer adds an init container that waits for the API Service first. The fixture is the shape of the chart's output.
cat > "$D/rendered.yaml" <<'EOF'
---
# Source: kagent/templates/controller-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: kagent-controller
  namespace: kagent
data:
  controller.yaml: "substrate: {}"
---
# Source: kagent/templates/ui-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kagent-ui
  namespace: kagent
spec:
  selector: {matchLabels: {app: ui}}
  template:
    metadata: {labels: {app: ui}}
    spec:
      containers:
        - name: ui
          image: ghcr.io/kagent-dev/kagent/ui:1.0.1
---
# Source: kagent/templates/controller-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kagent-controller
  namespace: kagent
spec:
  selector: {matchLabels: {app: controller}}
  template:
    metadata: {labels: {app: controller}}
    spec:
      securityContext: {runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: controller
          image: ghcr.io/kagent-dev/kagent/controller:1.0.1
          args: ["--config=/etc/kagent/controller.yaml"]
EOF
PR="$HERE/kagent-postrender.sh"
OUT=$(bash "$PR" < "$D/rendered.yaml" 2>"$D/pr-err"); RC=$?
eq "the post-renderer succeeds" "$RC" 0
PDOCS=$(yq -c 'select(.!=null)' <<<"$OUT" 2>/dev/null)
ctl() { jq -c 'select(.kind=="Deployment" and .metadata.name=="kagent-controller")' <<<"$PDOCS"; }
INIT=$(ctl | jq -c '.spec.template.spec.initContainers[0] // {}')
eq "every object is still there" "$(jq -r '.kind+"/"+.metadata.name' <<<"$PDOCS" | sort | tr '\n' ' ')" "ConfigMap/kagent-controller Deployment/kagent-controller Deployment/kagent-ui "
eq "the controller gets one init container, wait-for-ate-api" "$(ctl | jq -r '[.spec.template.spec.initContainers[]?.name]|join(",")')" wait-for-ate-api
eq "it waits for the Substrate API Service address the controller dials" "$(jq -r '.command|join(" ")' <<<"$INIT" | grep -c 'nc -z -w 2 api.ate-system.svc 443')" 1
eq "it gives up after a bounded time (the pod then shows Init:Error, not a silent hang)" "$(jq -r '.command|join(" ")' <<<"$INIT" | grep -cE 'exit 1')" 1
eq "it uses the image the install already pulls (substrate postgres), pinned by digest" "$(jq -r '.image' <<<"$INIT")" "$(grep -m1 -oE 'postgres:18-alpine@sha256:[0-9a-f]{64}' "$HERE/manifests/substrate-postgres/postgres.yaml")"
eq "it is not root, cannot escalate, has a read-only root and no capabilities" "$(jq -c '.securityContext|[.runAsNonRoot,.runAsUser,.allowPrivilegeEscalation,.readOnlyRootFilesystem,.capabilities.drop]' <<<"$INIT")" '[true,65532,false,true,["ALL"]]'
eq "it has small resource requests and limits" "$(jq -c '[.resources.requests.cpu,.resources.limits.memory]' <<<"$INIT")" '["5m","32Mi"]'
eq "the controller container is unchanged" "$(ctl | jq -c '.spec.template.spec.containers')" '[{"args":["--config=/etc/kagent/controller.yaml"],"image":"ghcr.io/kagent-dev/kagent/controller:1.0.1","name":"controller"}]'
eq "the UI is unchanged" "$(jq -c 'select(.metadata.name=="kagent-ui")|.spec.template.spec|has("initContainers")' <<<"$PDOCS")" false
grep -v 'kagent-controller' "$D/rendered.yaml" | sed '/^# Source: kagent\/templates\/controller-deployment.yaml/,$d' > "$D/no-ctl.yaml"
bash "$PR" < "$D/no-ctl.yaml" >/dev/null 2>&1; eq "without the controller Deployment it fails (a renamed object must not drop the wait silently)" "$?" 1
eq "kagent-helm.sh always passes the post-renderer" "$(grep -c -- '--post-renderer ./kagent-postrender.sh' "$HERE/kagent-helm.sh")" 1

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
