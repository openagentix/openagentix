#!/usr/bin/env bash
# After an install on a remote cluster: report every Service that opens the cluster to the network (ADR 0023, issue #165).
# Sourced by install.sh. Tests: hack/ci/gateway-service-type-test.sh (a fake kubectl, no cluster).
#
#  gw_exposure_check <kubectl command> <kube context>
#      Reads `get svc -A -o json` (nothing else, nothing is changed). Prints one WARNING line per Service of type LoadBalancer or
#      NodePort, with the command that shows its address. Prints "could not check for LoadBalancer Services" when the read fails
#      or its answer is not a Service list. Always returns 0: it is a report, never a reason to fail an install.
#      The model gateway Service is ClusterIP by default (gateway.serviceType), so a LoadBalancer here is a choice or another workload.

gw_exposure_check() {
  local kc=${1:-kubectl} ctx=${2:-} svcs out
  if ! svcs=$($kc --context "$ctx" get svc -A -o json 2>/dev/null) || ! jq -e '.items|type=="array"' <<<"$svcs" >/dev/null 2>&1; then
    echo "WARNING: could not check for LoadBalancer Services (kubectl --context $ctx get svc -A -o json failed). Check by hand: kubectl --context $ctx get svc -A | grep -E 'LoadBalancer|NodePort'" >&2
    return 0
  fi
  out=$(jq -r --arg c "$ctx" '.items[] | select(.spec.type=="LoadBalancer" or .spec.type=="NodePort")
    | "WARNING: Service \(.metadata.namespace)/\(.metadata.name) is of type \(.spec.type): on a managed cloud a LoadBalancer is a public IP, a firewall rule and a charge, and a NodePort opens a port on every node. Address: kubectl --context \($c) get svc -n \(.metadata.namespace) \(.metadata.name) -o wide"' <<<"$svcs")
  if [ -n "$out" ]; then printf '%s\n' "$out" >&2; else echo "no Service of type LoadBalancer or NodePort in cluster context $ctx"; fi
  return 0
}
