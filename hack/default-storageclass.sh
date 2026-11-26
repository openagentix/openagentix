#!/usr/bin/env bash
# Mark one StorageClass as the cluster default, only when you ask for it (part of #31).
#   KUBE_CONTEXT=<context> hack/default-storageclass.sh [--check] <storageclass>
# install.sh runs it when SET_DEFAULT_STORAGECLASS=<name> is set (any CLUSTER_TYPE): --check before the builds, then the change in step 1.
# Some clusters ship classes but mark none default (GKE 1.37 on the rapid channel has 10, none default), and the install needs one.
# It changes nothing when the class is missing, when it is already the default (so it can run again), or when another class is the default
# (it never makes a second default). The only write is one `kubectl patch` of that class's annotation. --check only reads.
# Exit 0 when the class is (or with --check, would be) the default, 1 when it refuses or kubectl fails, 2 on a usage error.
# Tests: hack/ci/default-storageclass-test.sh (fake kubectl, no cluster).
set -uo pipefail
K=${KUBECTL:-kubectl}
CTX=${KUBE_CONTEXT:-}
CHECK=0; if [ "${1:-}" = --check ]; then CHECK=1; shift; fi
NAME=${1:-}
ANN=storageclass.kubernetes.io/is-default-class
[ -n "$CTX" ] || { echo "ERROR: hack/default-storageclass.sh needs KUBE_CONTEXT, the kubectl context of the cluster" >&2; exit 2; }
[ -n "$NAME" ] || { echo "usage: KUBE_CONTEXT=<context> hack/default-storageclass.sh [--check] <storageclass>" >&2; exit 2; }
# a Kubernetes object name (DNS subdomain): checked before any call, so nothing odd reaches kubectl
if [ ${#NAME} -gt 253 ] || [[ ! $NAME =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
  echo "ERROR: '$NAME' is not a valid StorageClass name. Nothing was changed." >&2; exit 2
fi
kc(){ $K --context "$CTX" "$@"; }

SC=$(kc get storageclass -o json 2>/dev/null) || SC=""
if ! jq -e '.items' >/dev/null 2>&1 <<<"$SC"; then
  echo "ERROR: cannot list the StorageClasses of context $CTX (kubectl --context $CTX get storageclass). Nothing was changed." >&2; exit 1
fi
ALL=$(jq -r '[.items[].metadata.name] | join(" ")' <<<"$SC")
DEFAULTS=$(jq -r --arg a "$ANN" '[.items[] | select(.metadata.annotations[$a] == "true" or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true") | .metadata.name] | join(" ")' <<<"$SC")

if [[ " $ALL " != *" $NAME "* ]]; then
  echo "ERROR: no StorageClass $NAME in context $CTX (found: ${ALL:-none}). Nothing was changed." >&2; exit 1
fi
if [[ " $DEFAULTS " == *" $NAME "* ]]; then
  echo "default StorageClass: $NAME is already the default in context $CTX. Nothing was changed."; exit 0
fi
if [ -n "$DEFAULTS" ]; then
  others=${DEFAULTS// /, }
  echo "ERROR: $others is already the default StorageClass in context $CTX; marking $NAME too would make two defaults. Nothing was changed. Leave SET_DEFAULT_STORAGECLASS unset, or remove the default mark from $others yourself first." >&2
  exit 1
fi
if [ "$CHECK" = 1 ]; then
  echo "default StorageClass: $NAME will be marked as the default in context $CTX (SET_DEFAULT_STORAGECLASS)."; exit 0
fi
kc patch storageclass "$NAME" --type merge -p "{\"metadata\":{\"annotations\":{\"$ANN\":\"true\"}}}" >/dev/null || {
  echo "ERROR: kubectl could not mark $NAME as the default StorageClass in context $CTX." >&2; exit 1; }
echo "default StorageClass: marked $NAME as the default (annotation $ANN=true) in context $CTX. To undo: kubectl --context $CTX annotate storageclass $NAME $ANN-"
