#!/usr/bin/env bash
# Tests for hack/preflight.sh (issue #168) with a fake `kubectl` that answers from JSON fixtures (no cluster).
# One pass and one non-pass case per check, with the exact message, and a check that the script only ever reads.
set -u
cd "$(dirname "$0")/../.." || exit 1
# Column padding is cosmetic: runs of spaces are squeezed on both sides before comparing.
F=0; t(){ local g w; g=$(printf '%s' "$2" | tr -s ' '); w=$(printf '%s' "$3" | tr -s ' '); set -- "$1" "$g" "$w"; if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/fx"
# The fake kubectl: drops `--context X`, turns the other arguments into a file name, prints that fixture (exit 1 when there is none), records the call.
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
a=(); while [ \$# -gt 0 ]; do case "\$1" in --context) shift 2;; --context=*) shift;; *) a+=("\$1"); shift;; esac; done
echo "\${a[*]}" >> "$D/calls"
f="$D/fx/\$(printf '%s' "\${a[*]}" | tr -c 'A-Za-z0-9' _)"
[ -f "\$f" ] || { echo "Error from server (NotFound): fake kubectl has no fixture for: \${a[*]}" >&2; exit 1; }
cat "\$f"
EOS
chmod +x "$D/bin/kubectl"
export KUBECTL="$D/bin/kubectl"
fx(){ printf '%s\n' "$2" > "$D/fx/$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }   # fx "<kubectl arguments>" <json>
reset(){ rm -f "$D"/fx/*; : > "$D/calls"; }
GOOD_VERSION='{"major":"1","minor":"37","gitVersion":"v1.37.2-gke.1000"}'
CERT_V1='{"resources":[{"name":"clustertrustbundles"},{"name":"podcertificaterequests"}]}'
VAP='{"resources":[{"name":"validatingadmissionpolicies"},{"name":"validatingadmissionpolicybindings"}]}'
SC_DEFAULT='{"items":[{"metadata":{"name":"standard-rwo","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}'
DS_ANETD='{"items":[{"metadata":{"name":"anetd"}},{"metadata":{"name":"kube-proxy"}}]}'
NODE_OK='{"items":[{"metadata":{"name":"n1"},"spec":{"providerID":"gce://p/z/n1"},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"architecture":"amd64"},"allocatable":{"cpu":"3920m","memory":"14000000Ki"}}}]}'
NS_NONE='{"items":[{"metadata":{"name":"default"}},{"metadata":{"name":"kube-system"}}]}'
good(){   # a cluster where every check passes (the network policy line is always a warning)
  reset
  fx "get --raw /version" "$GOOD_VERSION"
  fx "get --raw /apis/certificates.k8s.io/v1beta1" "$CERT_V1"
  fx "get --raw /apis/admissionregistration.k8s.io/v1" "$VAP"
  fx "get storageclass -o json" "$SC_DEFAULT"
  fx "get daemonsets -n kube-system -o json" "$DS_ANETD"
  fx "get nodes -o json" "$NODE_OK"
  fx "get namespaces -o json" "$NS_NONE"
}
run(){ KUBE_CONTEXT=${CTX:-gke_p_z_c} bash hack/preflight.sh 2>&1; }
line(){ printf '%s\n' "$1" | grep -F -- "$2" | head -1; }   # the output line that holds a text

echo "# a cluster where everything passes"
good; OUT=$(run); RC=$?
t "exit 0 when nothing fails (warnings do not fail)" "$RC" 0
t "version" "$(line "$OUT" 'Kubernetes version')" "PASS  Kubernetes version        v1.37.2-gke.1000 (1.37 or newer is needed)"
t "certificates (beta served)" "$(line "$OUT" 'certificates.k8s.io')" "PASS  certificates.k8s.io         clustertrustbundles and podcertificaterequests served (v1beta1)"
t "admission policy" "$(line "$OUT" 'ValidatingAdmissionPolicy')" "PASS  ValidatingAdmissionPolicy   validatingadmissionpolicies served at admissionregistration.k8s.io/v1"
t "gateway api not installed" "$(line "$OUT" 'Gateway API')" "PASS  Gateway API CRDs            not installed, the installer applies v1.6.3"
t "default storage class" "$(line "$OUT" 'StorageClass')" "PASS  default StorageClass       standard-rwo"
t "node architecture" "$(line "$OUT" 'node architecture')" "PASS  node architecture          amd64 (1 Ready node)"
t "node capacity" "$(line "$OUT" 'node capacity')" "PASS  node capacity              3920m CPU and 13 GiB memory allocatable in total (3000m and 6 GiB are needed)"
t "pod security, nothing enforced" "$(line "$OUT" 'Pod Security')" "PASS  Pod Security labels       no target namespace enforces baseline or restricted"
t "remote context" "$(line "$OUT" 'kube context')" "PASS  kube context              gke_p_z_c does not look like a local cluster"
t "network policy: always a warning, names what was found, claims nothing" "$(line "$OUT" 'NetworkPolicy')" "WARN  NetworkPolicy            found anetd (GKE Dataplane V2, Cilium based). A name is not proof that NetworkPolicy is enforced."
t "network policy fix names the live check" "$(printf '%s\n' "$OUT" | grep -A1 'WARN  NetworkPolicy' | tail -1)" "      fix: run hack/ci/netpol-test.sh against this cluster; it checks ingress and egress to the internet."
t "summary" "$(line "$OUT" 'preflight:')" "preflight: 9 pass, 1 warn, 0 fail"
t "only reads: every call is get" "$(awk '$1!="get"' "$D/calls" | wc -l | tr -d ' ')" 0
# shellcheck disable=SC2016  # the pattern is for grep
t "no write verbs anywhere in the script" "$(grep -vE '^ *(warn|fail|#)' hack/preflight.sh | grep -cE '(kc|\$K|\$KUBECTL|kubectl) +(--context +[^ ]+ +)?(apply|create|delete|patch|replace|label|annotate|edit|exec|run|scale|drain|cordon|taint)( |$)')" 0

echo "# version"
good; fx "get --raw /version" '{"major":"1","minor":"36","gitVersion":"v1.36.4"}'; OUT=$(run); RC=$?
t "1.36 fails" "$(line "$OUT" 'Kubernetes version')" "FAIL  Kubernetes version        v1.36.4 is older than 1.37"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'FAIL  Kubernetes version' | tail -1)" "      fix: create or upgrade the cluster to Kubernetes 1.37 or newer (control plane and every node pool)."
t "exit 1 on a FAIL" "$RC" 1
good; fx "get --raw /version" '{"major":"1","minor":"37+","gitVersion":"v1.37.0-gke.5"}'; t "a minor with a plus sign passes" "$(line "$(run)" 'Kubernetes version' | cut -c1-5)" "PASS "
good; fx "get --raw /version" '{"major":"2","minor":"0","gitVersion":"v2.0.0"}'; t "a higher major passes" "$(line "$(run)" 'Kubernetes version' | cut -c1-5)" "PASS "
good; rm "$D/fx/"*version*; OUT=$(run); RC=$?
t "an API server that does not answer stops at once" "$(line "$OUT" 'Kubernetes version')" "FAIL  Kubernetes version        the API server of context gke_p_z_c did not answer"
t "and exits 1" "$RC" 1
t "and makes no other call" "$(wc -l < "$D/calls" | tr -d ' ')" 1

echo "# certificates.k8s.io"
good; fx "get --raw /apis/certificates.k8s.io/v1" "$CERT_V1"; rm "$D/fx/"*v1beta1*; t "v1 served" "$(line "$(run)" 'certificates.k8s.io')" "PASS  certificates.k8s.io         clustertrustbundles and podcertificaterequests served (v1)"
good; fx "get --raw /apis/certificates.k8s.io/v1beta1" '{"resources":[{"name":"clustertrustbundles"}]}'; OUT=$(run)
t "podcertificaterequests missing" "$(line "$OUT" 'certificates.k8s.io')" "FAIL  certificates.k8s.io         podcertificaterequests not served at v1 or v1beta1"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'FAIL  certificates.k8s.io' | tail -1)" "      fix: enable the certificates beta APIs when the cluster is created (GKE: see docs/diary/guide/install-gke.md, step 4), or use a cluster that serves them."
good; rm "$D/fx/"*certificates*; t "no certificates API at all" "$(line "$(run)" 'certificates.k8s.io' | cut -c1-5)" "FAIL "

echo "# ValidatingAdmissionPolicy"
good; fx "get --raw /apis/admissionregistration.k8s.io/v1" '{"resources":[{"name":"mutatingwebhookconfigurations"}]}'; OUT=$(run)
t "not served" "$(line "$OUT" 'ValidatingAdmissionPolicy')" "FAIL  ValidatingAdmissionPolicy   validatingadmissionpolicies not served at admissionregistration.k8s.io/v1"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'FAIL  ValidatingAdmissionPolicy' | tail -1)" "      fix: the admission guards need Kubernetes 1.30 or newer with this API enabled; check the cluster version and its API settings."

echo "# Gateway API CRDs"
good; fx "get crd gateways.gateway.networking.k8s.io -o json" '{"metadata":{"annotations":{"gateway.networking.k8s.io/bundle-version":"v1.6.3"}}}'; t "1.6.3 passes" "$(line "$(run)" 'Gateway API')" "PASS  Gateway API CRDs            bundle v1.6.3 is installed (1.6.3 or newer is needed)"
good; fx "get crd gateways.gateway.networking.k8s.io -o json" '{"metadata":{"annotations":{"gateway.networking.k8s.io/bundle-version":"v1.7.0"}}}'; t "1.7.0 passes" "$(line "$(run)" 'Gateway API' | cut -c1-5)" "PASS "
good; fx "get crd gateways.gateway.networking.k8s.io -o json" '{"metadata":{"annotations":{"gateway.networking.k8s.io/bundle-version":"v1.5.1"}}}'; OUT=$(run); RC=$?
t "1.5.1 warns" "$(line "$OUT" 'Gateway API')" "WARN  Gateway API CRDs            bundle v1.5.1 is older than 1.6.3, and the installer keeps the CRDs it finds"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'WARN  Gateway API' | tail -1)" "      fix: upgrade the Gateway API CRDs to 1.6.3 or newer first (on GKE they may be managed: gcloud container clusters update --gateway-api=standard), then run again."
t "a warning alone exits 0" "$RC" 0
good; fx "get crd gateways.gateway.networking.k8s.io -o json" '{"metadata":{"annotations":{}}}'; t "no bundle annotation warns" "$(line "$(run)" 'Gateway API')" "WARN  Gateway API CRDs            installed, bundle version unknown (no gateway.networking.k8s.io/bundle-version annotation)"

echo "# default StorageClass"
good; fx "get storageclass -o json" '{"items":[{"metadata":{"name":"fast"}}]}'; OUT=$(run)
t "none is a FAIL" "$(line "$OUT" 'StorageClass')" "FAIL  default StorageClass       none (1 class, none marked default)"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'FAIL  default StorageClass' | tail -1)" "      fix: mark one as default: kubectl patch storageclass <name> -p '{\"metadata\":{\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'"
good; fx "get storageclass -o json" '{"items":[{"metadata":{"name":"old","annotations":{"storageclass.beta.kubernetes.io/is-default-class":"true"}}}]}'; t "the beta annotation counts" "$(line "$(run)" 'StorageClass')" "PASS  default StorageClass       old"

echo "# NetworkPolicy dataplane (a hint, never a pass)"
good; fx "get daemonsets -n kube-system -o json" '{"items":[{"metadata":{"name":"calico-node"}}]}'; t "calico" "$(line "$(run)" 'NetworkPolicy' | tr -s ' ' | cut -c1-66)" "WARN  NetworkPolicy            found calico-node (Calico). A name is not proof"
good; fx "get daemonsets -n kube-system -o json" '{"items":[{"metadata":{"name":"kindnet"}}]}'; t "kindnet says what is known" "$(line "$(run)" 'NetworkPolicy')" "WARN  NetworkPolicy            found kindnet. It does not enforce egress to the internet. A name is not proof that NetworkPolicy is enforced."
good; fx "get daemonsets -n kube-system -o json" '{"items":[{"metadata":{"name":"kube-proxy"}}]}'; t "nothing known" "$(line "$(run)" 'NetworkPolicy')" "WARN  NetworkPolicy            no known NetworkPolicy dataplane found in kube-system (some clusters enforce it in the kernel or the CNI without a DaemonSet there)"
good; rm "$D/fx/"*daemonsets*; t "daemonsets unreadable is still only a warning" "$(line "$(run)" 'NetworkPolicy' | cut -c1-5)" "WARN "

echo "# nodes"
good; fx "get nodes -o json" '{"items":[{"metadata":{"name":"n1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"False"}],"nodeInfo":{"architecture":"amd64"},"allocatable":{"cpu":"4","memory":"16Gi"}}}]}'; OUT=$(run); RC=$?
t "no Ready node fails" "$(line "$OUT" 'node architecture')" "FAIL  node architecture          no Ready node (1 node, 0 Ready)"
t "exit 1" "$RC" 1
good; fx "get nodes -o json" '{"items":[{"metadata":{"name":"n1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"architecture":"arm64"},"allocatable":{"cpu":"4","memory":"16Gi"}}}]}'; OUT=$(run)
t "arm64 warns" "$(line "$OUT" 'node architecture')" "WARN  node architecture          arm64 (1 Ready node); the sandbox runtime was only planned for amd64 and images must be built for arm64"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'WARN  node architecture' | tail -1)" "      fix: use amd64 nodes for the first run (GKE: c3-standard-4)."
t "4 CPU and 16Gi pass" "$(line "$OUT" 'node capacity')" "PASS  node capacity              4000m CPU and 16 GiB memory allocatable in total (3000m and 6 GiB are needed)"
good; fx "get nodes -o json" '{"items":[{"metadata":{"name":"a"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"architecture":"amd64"}, "allocatable":{"cpu":"1930m","memory":"2Gi"}}},{"metadata":{"name":"b"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"architecture":"arm64"},"allocatable":{"cpu":"1","memory":"2097152Ki"}}}]}'; OUT=$(run)
t "small nodes warn" "$(line "$OUT" 'node capacity')" "WARN  node capacity              2930m CPU and 4 GiB memory allocatable in total, 3000m and 6 GiB are needed"
t "mixed architectures warn" "$(line "$OUT" 'node architecture')" "WARN  node architecture          amd64 and arm64 (2 Ready nodes); the sandbox runtime was only planned for amd64 and images must be built for amd64 and arm64"

echo "# Pod Security labels of the target namespaces"
good; fx "get namespaces -o json" '{"items":[{"metadata":{"name":"ate-system","labels":{"pod-security.kubernetes.io/enforce":"baseline"}}},{"metadata":{"name":"kagent","labels":{"pod-security.kubernetes.io/enforce":"privileged"}}},{"metadata":{"name":"other","labels":{"pod-security.kubernetes.io/enforce":"restricted"}}}]}'; OUT=$(run)
t "a restrictive label on a target namespace warns" "$(line "$OUT" 'Pod Security')" "WARN  Pod Security labels       ate-system enforces baseline"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'WARN  Pod Security' | tail -1)" "      fix: the runtime's node agent mounts host paths and runs as root; remove the label (kubectl label namespace <name> pod-security.kubernetes.io/enforce-) or set it to privileged for that namespace."

echo "# local context"
good; OUT=$(CTX=kind-openagentix run)
t "a local context name warns" "$(line "$OUT" 'kube context')" "WARN  kube context              kind-openagentix is the name of a local cluster"
t "fix text" "$(printf '%s\n' "$OUT" | grep -A1 'WARN  kube context' | tail -1)" "      fix: for kind or k3d use CLUSTER_TYPE=kind or CLUSTER_TYPE=k3d; CLUSTER_TYPE=remote is for a cluster that already exists elsewhere."
good; fx "get nodes -o json" '{"items":[{"metadata":{"name":"n1"},"spec":{"providerID":"kind://docker/oa/n1"},"status":{"conditions":[{"type":"Ready","status":"True"}],"nodeInfo":{"architecture":"amd64"},"allocatable":{"cpu":"4","memory":"16Gi"}}}]}'
t "a kind:// provider id warns even under another name" "$(line "$(run)" 'kube context' | cut -c1-5)" "WARN "

echo "# the entry points"
good; OUT=$(KUBE_CONTEXT='' bash hack/preflight.sh 2>&1); RC=$?
t "no KUBE_CONTEXT is refused, nothing is called" "$RC $(wc -l < "$D/calls" | tr -d ' ')" "2 0"
t "with the message" "$OUT" "ERROR: hack/preflight.sh needs KUBE_CONTEXT, the kubectl context of the cluster to check (kubectl config get-contexts)"
t "install.sh calls it, for CLUSTER_TYPE=remote only" "$(grep -c 'REMOTE.*= 1.*hack/preflight.sh\|hack/preflight.sh.*REMOTE' install.sh)" 1
t "install.sh has the SKIP_PREFLIGHT switch" "$(grep -c 'SKIP_PREFLIGHT' install.sh)" 3
exit $F
