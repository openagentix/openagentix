#!/usr/bin/env bash
# The model gateway's Service type on a remote cluster (gateway.serviceType, ADR 0023, issue #165). Sourced by install.sh.
# Tests: hack/ci/gateway-service-type-test.sh (JSON fixtures, no cluster).
#
#  gw_service_type_set_value <remote 0|1> <rendered documents, one JSON per line>
#      Prints ClusterIP when the cluster is remote and the chart renders a Gateway without infrastructure.parametersRef
#      (so no values file set a type). Prints nothing otherwise: kind and k3d, gateway.enabled=false, or a type already set
#      (ClusterIP or LoadBalancer: the operator's choice is never overridden).
#  gw_loadbalancer_warnings <kubectl get svc -A -o json> <kube context>
#      Prints one WARNING line per Service of type LoadBalancer, with the command that shows its address. Prints nothing
#      when there is none or the input is not usable. Always returns 0.

gw_service_type_set_value() {
  local remote=${1:-0} rendered=${2:-}
  [ "$remote" = 1 ] || return 0
  [ -n "$rendered" ] || return 0
  jq -e -s 'any(.[]; .kind=="Gateway" and ((.spec.infrastructure.parametersRef // null) == null))' <<<"$rendered" >/dev/null 2>&1 || return 0
  printf '%s\n' ClusterIP
}

gw_loadbalancer_warnings() {
  local svcs=${1:-} ctx=${2:-}
  [ -n "$svcs" ] || return 0
  jq -r --arg c "$ctx" '.items[]? | select(.spec.type=="LoadBalancer")
    | "WARNING: Service \(.metadata.namespace)/\(.metadata.name) is of type LoadBalancer: on a managed cloud it has a public IP, a firewall rule and a charge. Address: kubectl --context \($c) get svc -n \(.metadata.namespace) \(.metadata.name) -o wide"' <<<"$svcs" 2>/dev/null || true
  return 0
}
