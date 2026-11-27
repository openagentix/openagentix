#!/usr/bin/env bash
# Install checks for mcp.endpoints (ADR 0026, slice 2). Sourced by install.sh. Tests: hack/ci/endpoints-check-test.sh (fake kubectl, no cluster).
#
# ToolHive keeps a vMCP Ready when it drops a backend (an auth type it cannot use, a backend it cannot reach), so Ready says nothing about the endpoint.
# Two checks read the vMCPs of each group that holds an endpoint:
#   ep_check_secrets <kubectl>            reads "<namespace>\t<Secret>\t<key>" lines on stdin: each Secret must exist and hold the key, before the chart is applied
#                                         (a vMCP pod that names a missing Secret as an environment value does not start). Never prints a value.
#   ep_check_backends <kubectl> <settle seconds> <vMCP as namespace/name> <backend>...
#                                         every named backend (the endpoints of the group and the mirror entries) must be in status.discoveredBackends of
#                                         the vMCP with status "ready"; waits up to <settle> seconds; fails with the backend's name and message
# The condition check on DiscoveredAuthConfig-* is diag_check_vmcps of hack/diagnostics-check.sh (with DIAG_CHECK_WHAT set).

ep_check_secrets() {
  local k=$1 ns name key j bad=0
  while IFS=$'\t' read -r ns name key; do
    [ -n "$name" ] || continue
    if ! j=$($k get secret "$name" -n "$ns" -o json 2>/dev/null); then
      echo "ERROR: the Secret $ns/$name (the header credential of an entry of mcp.endpoints) does not exist. Create it before the install; the chart renders only the reference. For example: $k create secret generic $name -n $ns --from-file=$key=<(printf 'Bearer %s' \"\$TOKEN\")" >&2
      bad=1; continue
    fi
    if ! jq -e --arg k "$key" '(.data[$k] // "")|length>0' <<<"$j" >/dev/null 2>&1; then
      echo "ERROR: the Secret $ns/$name has no key $key (or it is empty): that is the header value mcp.endpoints names." >&2
      bad=1
    fi
  done
  unset j
  return "$bad"
}

ep_check_backends() {
  local k=$1 settle=$2 row=$3; shift 3
  local ns=${row%%/*} name=${row##*/} waited=0 j bad want
  want=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  while :; do
    j=$($k get virtualmcpserver "$name" -n "$ns" -o json 2>/dev/null) || j='{}'
    bad=$(jq -r --argjson want "$want" '
      (.status.discoveredBackends // []) as $d
      | [ $want[] as $b | ($d | map(select(.name == $b)) | first) as $x
          | if $x == null then "\($b): not in status.discoveredBackends"
            elif ($x.status // "") != "ready" then "\($b): status \(if ($x.status // "") == "" then "none" else $x.status end) (\((if ($x.message // "") == "" then "no message" else $x.message end) | tostring | .[0:200]))"
            else empty end ] | join("; ")' <<<"$j" 2>/dev/null)
    [ -n "$bad" ] || { echo "vMCP $name: every backend of its group is ready ($*)"; return 0; }
    [ "$waited" -lt "$settle" ] || break
    sleep 3; waited=$((waited + 3))
  done
  echo "ERROR: the vMCP $name has a backend that is not ready: $bad. ToolHive keeps such a vMCP Ready with fewer tools. Check the entry, its header Secret and the endpoint's pods: $k get virtualmcpserver $name -n $ns -o yaml" >&2
  return 1
}
