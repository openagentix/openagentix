#!/usr/bin/env bash
# The service account token issuer of the cluster, for the workload tool server (chart value
# controlPlane.containerAgents.serviceAccountTokens.issuer, ADR 0019). Sourced by install.sh. Tests: hack/ci/sa-issuer-test.sh (JSON fixtures, no cluster).
#
#   sa_issuer <override> <discovery-json> <apiserver-pods-json>
#       Prints the issuer, or prints an error to stderr and returns 1. The first of these that is not empty wins:
#         1. override        SERVICE_ACCOUNT_ISSUER, set by the user
#         2. discovery-json  `kubectl get --raw /.well-known/openid-configuration` (field .issuer). Works on kind, k3s and GKE.
#         3. apiserver-pods-json  `kubectl get pods -n kube-system -l component=kube-apiserver -o json`: the first --service-account-issuer
#            flag. Only for a cluster whose API server runs as a pod you can read (kubeadm style). A managed control plane (GKE) has none.
#       The issuer must be an https URL without user, query or fragment (the chart refuses anything else).
#   sa_issuer_set_value <cluster-issuer> <rendered-issuer> <chart-default>
#       Prints the issuer to pass to the chart, or nothing. It prints nothing when the rendered value is not the chart default (the user set
#       it, so it wins) or when the cluster's issuer is the default (kind, k3s: the default render stays byte-identical).
sa_issuer() {
  local override=${1:-} disc=${2:-} pods=${3:-} i=""
  if [ -n "$override" ]; then i=$override
  else
    [ -z "$disc" ] || i=$(jq -r '.issuer // empty' <<<"$disc" 2>/dev/null) || i=""
    if [ -z "$i" ] && [ -n "$pods" ]; then
      i=$(jq -r '[.items[]?.spec.containers[]? | ((.command // []) + (.args // []))[] | select(startswith("--service-account-issuer="))
                  | sub("^[^=]*="; "")] | first // empty' <<<"$pods" 2>/dev/null) || i=""
    fi
  fi
  [ -n "$i" ] || { echo "ERROR: no service account issuer found (no discovery document, no kube-apiserver flag, no SERVICE_ACCOUNT_ISSUER)" >&2; return 1; }
  [[ $i =~ ^https://[a-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$ ]] || { echo "ERROR: the service account issuer is not an https URL the chart accepts (no user, query or fragment)" >&2; return 1; }
  printf '%s\n' "$i"
}

sa_issuer_set_value() {
  local cluster=${1:-} rendered=${2:-} default=${3:-}
  [ "$rendered" = "$default" ] || return 0
  [ "$cluster" != "$default" ] || return 0
  printf '%s\n' "$cluster"
}
