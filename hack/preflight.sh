#!/usr/bin/env bash
# Preflight for an existing (remote) cluster, before the installer changes anything (issue #168, part of #31).
#   KUBE_CONTEXT=<context> hack/preflight.sh
# install.sh runs it when CLUSTER_TYPE=remote (SKIP_PREFLIGHT=1 skips it). You can run it alone, for any cluster you can reach.
# It only reads: every call is `kubectl get` (or `get --raw`); it never creates, patches or deletes anything.
# Prints one line per check, PASS, WARN, FAIL or INFO, and a "fix:" line under each WARN and FAIL. Exit 0 when nothing fails (warnings do
# not fail), 1 when a check fails, 2 when KUBE_CONTEXT is not set. Tests: hack/ci/preflight-test.sh (fake kubectl, no cluster).
#
# Checks (the minimums come from docs/diary/guide/install-gke.md and docs/diary/features/install.md):
#   Kubernetes version           1.37 or newer (the sandbox runtime needs it)
#   certificates.k8s.io          clustertrustbundles and podcertificaterequests served, at v1 or v1beta1
#   ValidatingAdmissionPolicy    validatingadmissionpolicies served at admissionregistration.k8s.io/v1 (the admission guards)
#   Gateway API CRDs             none (the installer applies v1.6.3), or a bundle of 1.6.3 or newer (the installer keeps what it finds)
#   default StorageClass         one class is marked default (the databases and the snapshot store use it), or SET_DEFAULT_STORAGECLASS names an
#                                existing class and no other is default (the installer then marks it; hack/default-storageclass.sh)
#   node machine type            WARN on an E2 node (Google's Agent Substrate page: c3-standard-4 or larger, no E2); INFO when nodes carry no type label
#   Spot nodes, GKE mode         INFO only, never counted: Spot VMs (cloud.google.com/gke-spot=true) restart pods on preemption; on GKE, Autopilot is
#                                not supported and cannot be detected with reads, so the line says how to check it
#   NetworkPolicy                a HINT only: names the dataplane it finds. It never says "enforced"; hack/ci/netpol-test.sh checks that live
#   node architecture/capacity   Ready nodes; amd64 expected; allocatable CPU and memory in total (PREFLIGHT_MIN_CPU_M=3000, PREFLIGHT_MIN_MEM_GI=6)
#   Pod Security labels          the target namespaces (PREFLIGHT_NAMESPACES) must not enforce baseline or restricted
#   kube context                 warns when it looks like a local cluster (kind, k3d, Docker Desktop, ...)
# The minimums for CPU and memory are an estimate: one c3-standard-4 node (about 3900m and 13 GiB allocatable) is the planned first run.
set -uo pipefail
K=${KUBECTL:-kubectl}
CTX=${KUBE_CONTEXT:-}
[ -n "$CTX" ] || { echo "ERROR: hack/preflight.sh needs KUBE_CONTEXT, the kubectl context of the cluster to check (kubectl config get-contexts)" >&2; exit 2; }
MIN_MAJOR=1; MIN_MINOR=37; MIN_GATEWAY=1.6.3
MIN_CPU_M=${PREFLIGHT_MIN_CPU_M:-3000}; MIN_MEM_GI=${PREFLIGHT_MIN_MEM_GI:-6}
NAMESPACES=${PREFLIGHT_NAMESPACES:-"ate-system kagent agentgateway-system toolhive-system openagentix-system openagentix-gateway openagentix-knowledge"}
kc(){ $K --context "$CTX" "$@"; }

NP=0; NW=0; NF=0
row(){ printf '%-6s%-28s%s\n' "$1" "$2" "$3"; }   # status label detail
pass(){ NP=$((NP+1)); row PASS "$1" "$2"; }
warn(){ NW=$((NW+1)); row WARN "$1" "$2"; printf '      fix: %s\n' "$3"; }
fail(){ NF=$((NF+1)); row FAIL "$1" "$2"; printf '      fix: %s\n' "$3"; }
info(){ row INFO "$1" "$2"; }   # information only: not counted, never a fix
summary(){ echo "preflight: $NP pass, $NW warn, $NF fail"; [ "$NF" = 0 ]; }
# "1 class", "2 classes", "0 nodes", "3 Ready nodes"
plural(){ if [ "$1" = 1 ]; then echo "$1 $2"; else case "$2" in *s|*x|*ch|*sh) echo "$1 ${2}es";; *) echo "$1 ${2}s";; esac; fi; }

# --- Kubernetes version (when the API server does not answer, nothing else can be checked) ---
VJ=$(kc get --raw /version 2>/dev/null) || VJ=""
GV=$(jq -r '.gitVersion // empty' <<<"$VJ" 2>/dev/null || true)
if [[ ! $GV =~ ^v?([0-9]+)\.([0-9]+) ]]; then
  fail "Kubernetes version" "the API server of context $CTX did not answer" "check the context and your access: kubectl --context $CTX get --raw /version"
  summary; exit $?
fi
MAJOR=${BASH_REMATCH[1]}; MINOR=${BASH_REMATCH[2]}
if [ "$MAJOR" -gt "$MIN_MAJOR" ] || { [ "$MAJOR" = "$MIN_MAJOR" ] && [ "$MINOR" -ge "$MIN_MINOR" ]; }; then
  pass "Kubernetes version" "$GV ($MIN_MAJOR.$MIN_MINOR or newer is needed)"
else
  fail "Kubernetes version" "$GV is older than $MIN_MAJOR.$MIN_MINOR" "create or upgrade the cluster to Kubernetes $MIN_MAJOR.$MIN_MINOR or newer (control plane and every node pool)."
fi

# --- certificates.k8s.io ---
CERT_VER=""
for v in v1 v1beta1; do
  names=$(kc get --raw "/apis/certificates.k8s.io/$v" 2>/dev/null | jq -r '[.resources[]?.name] | join(" ")' 2>/dev/null || true)
  [ -n "$names" ] || continue
  m=""; for r in clustertrustbundles podcertificaterequests; do [[ " $names " == *" $r "* ]] || m="$m $r"; done
  if [ -z "$m" ]; then CERT_VER=$v; break; fi
done
if [ -n "$CERT_VER" ]; then
  pass "certificates.k8s.io" "clustertrustbundles and podcertificaterequests served ($CERT_VER)"
else
  # name what is missing at the best version found: both are reported when no version serves either
  have=""; for v in v1 v1beta1; do
    names=$(kc get --raw "/apis/certificates.k8s.io/$v" 2>/dev/null | jq -r '[.resources[]?.name] | join(" ")' 2>/dev/null || true)
    [[ " $names " == *" clustertrustbundles "* ]] && have="$have clustertrustbundles"
    [[ " $names " == *" podcertificaterequests "* ]] && have="$have podcertificaterequests"
  done
  miss=""; for r in clustertrustbundles podcertificaterequests; do [[ " $have " == *" $r "* ]] || miss="${miss:+$miss and }$r"; done
  fail "certificates.k8s.io" "$miss not served at v1 or v1beta1" "enable the certificates beta APIs when the cluster is created (GKE: see docs/diary/guide/install-gke.md, step 4), or use a cluster that serves them."
fi

# --- ValidatingAdmissionPolicy ---
if kc get --raw /apis/admissionregistration.k8s.io/v1 2>/dev/null | jq -e '[.resources[]?.name] | index("validatingadmissionpolicies")' >/dev/null 2>&1; then
  pass "ValidatingAdmissionPolicy" "validatingadmissionpolicies served at admissionregistration.k8s.io/v1"
else
  fail "ValidatingAdmissionPolicy" "validatingadmissionpolicies not served at admissionregistration.k8s.io/v1" "the admission guards need Kubernetes 1.30 or newer with this API enabled; check the cluster version and its API settings."
fi

# --- Gateway API CRDs ---
if GW=$(kc get crd gateways.gateway.networking.k8s.io -o json 2>/dev/null); then
  GWV=$(jq -r '.metadata.annotations["gateway.networking.k8s.io/bundle-version"] // empty' <<<"$GW" 2>/dev/null || true)
  if [ -z "$GWV" ]; then
    warn "Gateway API CRDs" "installed, bundle version unknown (no gateway.networking.k8s.io/bundle-version annotation)" "check the version yourself: it must be $MIN_GATEWAY or newer, because the installer keeps the CRDs it finds."
  elif [ "$(printf '%s\n%s\n' "${GWV#v}" "$MIN_GATEWAY" | sort -V | head -1)" = "$MIN_GATEWAY" ]; then
    pass "Gateway API CRDs" "bundle $GWV is installed ($MIN_GATEWAY or newer is needed)"
  else
    warn "Gateway API CRDs" "bundle $GWV is older than $MIN_GATEWAY, and the installer keeps the CRDs it finds" "upgrade the Gateway API CRDs to $MIN_GATEWAY or newer first (on GKE they may be managed: gcloud container clusters update --gateway-api=standard), then run again."
  fi
else
  pass "Gateway API CRDs" "not installed, the installer applies v$MIN_GATEWAY"
fi

# The nodes are read once here: the StorageClass hint and the node checks below use them.
ND=$(kc get nodes -o json 2>/dev/null || true)
# GKE: a node pool label or a gce:// provider id on any node
GKE=0; [ "$(jq -r '[.items[]? | select((.metadata.labels // {} | has("cloud.google.com/gke-nodepool")) or ((.spec.providerID // "") | startswith("gce://")))] | length' <<<"$ND" 2>/dev/null || echo 0)" = 0 ] || GKE=1

# --- default StorageClass (SET_DEFAULT_STORAGECLASS=<name>: the installer marks that class, see hack/default-storageclass.sh) ---
WANT_SC=${SET_DEFAULT_STORAGECLASS:-}
SC=$(kc get storageclass -o json 2>/dev/null || true)
SCN=$(jq -r '[.items[]? | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true" or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true") | .metadata.name] | first // empty' <<<"$SC" 2>/dev/null || true)
SC_ALL=$(jq -r '[.items[]?.metadata.name] | join(" ")' <<<"$SC" 2>/dev/null || true)
n=$(jq -r '.items | length' <<<"$SC" 2>/dev/null || echo 0); n=${n:-0}
if [ -n "$SCN" ] && { [ -z "$WANT_SC" ] || [ "$WANT_SC" = "$SCN" ]; }; then
  pass "default StorageClass" "$SCN"
elif [ -n "$SCN" ]; then
  fail "default StorageClass" "$SCN is already default; SET_DEFAULT_STORAGECLASS=$WANT_SC would make a second default" "leave SET_DEFAULT_STORAGECLASS unset ($SCN is used), or remove the default mark from $SCN yourself first."
elif [ -n "$WANT_SC" ] && [[ " $SC_ALL " == *" $WANT_SC "* ]]; then
  pass "default StorageClass" "none marked default yet; the installer marks $WANT_SC (SET_DEFAULT_STORAGECLASS)"
elif [ -n "$WANT_SC" ]; then
  fail "default StorageClass" "SET_DEFAULT_STORAGECLASS=$WANT_SC, but no StorageClass $WANT_SC exists ($(plural "$n" class))" "set SET_DEFAULT_STORAGECLASS to one of: ${SC_ALL:-none (create a StorageClass first)}"
else
  case "$n" in 0) d="no StorageClass exists";; 1) d="1 class, not marked default";; *) d="$(plural "$n" class), none marked default";; esac
  if [ "$n" = 0 ]; then
    hint="create a StorageClass for the cluster's disks and mark it default; the databases and the snapshot store need one."
  elif [ "$GKE" = 1 ] && [[ " $SC_ALL " == *" standard-rwo "* ]]; then
    hint="on GKE the usual choice is standard-rwo (pd-balanced): run the installer with SET_DEFAULT_STORAGECLASS=standard-rwo, which marks it default (nothing is marked without it), or alone: KUBE_CONTEXT=$CTX hack/default-storageclass.sh standard-rwo"
  else
    hint="run the installer with SET_DEFAULT_STORAGECLASS=<name> (one of: $SC_ALL), which marks it default (nothing is marked without it), or alone: KUBE_CONTEXT=$CTX hack/default-storageclass.sh <name>"
  fi
  fail "default StorageClass" "none ($d)" "$hint"
fi

# --- NetworkPolicy: a hint from the DaemonSet names in kube-system. A name is not proof, so this is always a warning. ---
DS=$(kc get daemonsets -n kube-system -o json 2>/dev/null || true)
FOUND=$(jq -r '[.items[]?.metadata.name] | map(
    if . == "anetd" then "anetd (GKE Dataplane V2, Cilium based)"
    elif test("^cilium") then . + " (Cilium)"
    elif test("^calico-node") then . + " (Calico)"
    elif test("^kindnet") then . + ". It does not enforce egress to the internet"
    elif test("^antrea-agent") then . + " (Antrea)"
    elif test("^kube-router") then . + " (kube-router)"
    else empty end) | join(", ")' <<<"$DS" 2>/dev/null || true)
if [ -n "$FOUND" ]; then
  warn "NetworkPolicy" "found $FOUND. A name is not proof that NetworkPolicy is enforced." "run hack/ci/netpol-test.sh against this cluster; it checks ingress and egress to the internet."
else
  warn "NetworkPolicy" "no known NetworkPolicy dataplane found in kube-system (some clusters enforce it in the kernel or the CNI without a DaemonSet there)" "run hack/ci/netpol-test.sh against this cluster; it checks ingress and egress to the internet."
fi

# --- nodes: Ready, architecture, allocatable CPU and memory, machine type, Spot ---
TOTAL=$(jq -r '.items | length' <<<"$ND" 2>/dev/null || echo 0); TOTAL=${TOTAL:-0}
RDY=$(jq -r '[.items[]? | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$ND" 2>/dev/null || echo 0); RDY=${RDY:-0}
if [ "$RDY" = 0 ]; then
  fail "node architecture" "no Ready node ($(plural "$TOTAL" node), 0 Ready)" "wait for a node to be Ready, or add a node pool: kubectl --context $CTX get nodes"
else
  ARCHES=$(jq -r '[.items[]? | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .status.nodeInfo.architecture] | unique | join(" and ")' <<<"$ND")
  if [ "$ARCHES" = amd64 ]; then
    pass "node architecture" "amd64 ($(plural "$RDY" "Ready node"))"
  else
    warn "node architecture" "$ARCHES ($(plural "$RDY" "Ready node")); the sandbox runtime was only planned for amd64 and images must be built for $ARCHES" "use amd64 nodes for the first run (GKE: c3-standard-4)."
  fi
  # allocatable totals of the Ready nodes: CPU in millicores, memory in GiB (rounded down)
  CAP=$(jq -r '
    def cpu: if endswith("m") then (.[:-1] | tonumber) else (tonumber * 1000) end;
    def mem: if endswith("Ki") then (.[:-2] | tonumber / 1048576)
             elif endswith("Mi") then (.[:-2] | tonumber / 1024)
             elif endswith("Gi") then (.[:-2] | tonumber)
             elif endswith("Ti") then (.[:-2] | tonumber * 1024)
             else (tonumber / 1073741824) end;
    [.items[]? | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .status.allocatable]
    | "\(map(.cpu | cpu) | add | floor) \(map(.memory | mem) | add | floor)"' <<<"$ND" 2>/dev/null || true)
  CPU=${CAP% *}; MEM=${CAP#* }
  if [[ $CPU =~ ^[0-9]+$ && $MEM =~ ^[0-9]+$ ]]; then
    if [ "$CPU" -ge "$MIN_CPU_M" ] && [ "$MEM" -ge "$MIN_MEM_GI" ]; then
      pass "node capacity" "${CPU}m CPU and $MEM GiB memory allocatable in total (${MIN_CPU_M}m and $MIN_MEM_GI GiB are needed)"
    else
      warn "node capacity" "${CPU}m CPU and $MEM GiB memory allocatable in total, ${MIN_CPU_M}m and $MIN_MEM_GI GiB are needed" "add nodes or use a larger machine type; the quick start needs about this much for its pods and one sandbox worker."
    fi
  else
    warn "node capacity" "could not read the allocatable CPU and memory of the nodes" "check: kubectl --context $CTX get nodes -o json"
  fi
  # Machine type. Google's Agent Substrate page asks for c3-standard-4 or larger and refuses E2 (mixed CPU architectures). That is the
  # only source, and it is about GKE, so an E2 node is a warning, not a failure.
  READY='[.items[]? | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))]'
  TYPES=$(jq -r "$READY | [.[].metadata.labels[\"node.kubernetes.io/instance-type\"] // empty] | unique | join(\" and \")" <<<"$ND" 2>/dev/null || true)
  if [ -z "$TYPES" ]; then
    info "node machine type" "no node.kubernetes.io/instance-type label on the Ready nodes, not checked"
  elif jq -e "$READY | any(.[]; (.metadata.labels[\"node.kubernetes.io/instance-type\"] // \"\") | startswith(\"e2-\"))" <<<"$ND" >/dev/null 2>&1; then
    warn "node machine type" "$TYPES: Google's Agent Substrate page refuses E2 machine types (mixed CPU architectures) and asks for c3-standard-4 or larger" "use a node pool of c3-standard-4 or larger (C3, C4, N2 or N4). Source: https://docs.cloud.google.com/kubernetes-engine/ai-ml/install-overview-substrate (GKE Standard only, not Autopilot); not verified for other install paths."
  else
    pass "node machine type" "$TYPES (no E2 machine type)"
  fi
  # Spot VMs: information only
  SPOT=$(jq -r "$READY | map(select(.metadata.labels[\"cloud.google.com/gke-spot\"] == \"true\")) | length" <<<"$ND" 2>/dev/null || echo 0)
  if [ "${SPOT:-0}" != 0 ]; then
    if [ "$SPOT" = 1 ]; then vm="is a Spot VM"; else vm="are Spot VMs"; fi
    info "Spot nodes" "$SPOT of $(plural "$RDY" "Ready node") $vm (cloud.google.com/gke-spot=true): a preemption restarts the install's pods on another node, and the Substrate golden snapshot is rebuilt"
  fi
fi

# --- GKE: Standard or Autopilot? No read-only signal for Autopilot was verified, so this only says what to check. ---
if [ "$GKE" = 1 ]; then
  info "GKE mode" "Agent Substrate on GKE needs a Standard cluster; Autopilot is not supported. Reads alone cannot tell Autopilot apart, so check it: gcloud container clusters describe <cluster> --format='value(autopilot.enabled)'"
fi

# --- Pod Security labels of the namespaces the installer uses ---
NSJ=$(kc get namespaces -o json 2>/dev/null || true)
PSA=$(jq -r --arg list "$NAMESPACES" '($list | split(" ")) as $t
  | [.items[]? | select(.metadata.name as $n | $t | index($n))
     | select((.metadata.labels["pod-security.kubernetes.io/enforce"] // "") | . == "baseline" or . == "restricted")
     | "\(.metadata.name) enforces \(.metadata.labels["pod-security.kubernetes.io/enforce"])"] | join(", ")' <<<"$NSJ" 2>/dev/null || true)
if [ -z "$PSA" ]; then
  pass "Pod Security labels" "no target namespace enforces baseline or restricted"
else
  warn "Pod Security labels" "$PSA" "the runtime's node agent mounts host paths and runs as root; remove the label (kubectl label namespace <name> pod-security.kubernetes.io/enforce-) or set it to privileged for that namespace."
fi

# --- is the context a local cluster? ---
LOCAL=0
case "$CTX" in kind-*|k3d-*|docker-desktop|rancher-desktop|minikube|orbstack|colima) LOCAL=1;; esac
[ "$(jq -r '[.items[]?.spec.providerID // ""] | map(select(startswith("kind://") or startswith("k3s://"))) | length' <<<"$ND" 2>/dev/null || echo 0)" = 0 ] || LOCAL=1
if [ "$LOCAL" = 1 ]; then
  warn "kube context" "$CTX is the name of a local cluster" "for kind or k3d use CLUSTER_TYPE=kind or CLUSTER_TYPE=k3d; CLUSTER_TYPE=remote is for a cluster that already exists elsewhere."
else
  pass "kube context" "$CTX does not look like a local cluster"
fi

summary
