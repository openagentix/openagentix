#!/usr/bin/env bash
# The installer's check of the vMCPs of the diagnostics tool group (ADR 0025, slice 4). Sourced by install.sh.
# Tests: hack/ci/diagnostics-check-test.sh (fake kubectl, no cluster).
#
# Why: ToolHive 0.67.1 does not stop a vMCP that cannot use the auth of one of its backends. It drops the backend, sets the condition
# DiscoveredAuthConfig-<entry> to False and stays Ready with fewer tools (the spike, docs/diary/features/toolhive-spike-diagnostic-tools.md). A
# wait for Ready would pass. So after Ready, every vMCP of the group is read until it shows the condition of each of its entries, and the install
# FAILS when any DiscoveredAuthConfig-* condition is False.
#
#   diag_check_vmcps <kubectl command> <seconds to wait for the conditions> <entries expected> <namespace/name>...
#       returns 1 and says which vMCP and condition (type and reason only: never a message) when one is False.
#       When fewer conditions than entries show up in the time, it only warns: a condition that never shows cannot be told from a slow one.

diag_check_vmcps() {
  local k=$1 settle=$2 want=$3; shift 3
  local row ns name j bad seen waited
  for row in "$@"; do
    ns=${row%%/*}; name=${row##*/}; waited=0
    while :; do
      j=$($k get virtualmcpserver "$name" -n "$ns" -o json 2>/dev/null) || j='{}'
      bad=$(jq -r '[.status.conditions[]?|select((.type|startswith("DiscoveredAuthConfig-")) and .status=="False")|.type+" ("+(.reason//"no reason")+")"]|join(", ")' <<<"$j" 2>/dev/null)
      if [ -n "$bad" ]; then
        echo "ERROR: the vMCP $name dropped a backend of ${DIAG_CHECK_WHAT:-the diagnostics group}: $bad. ToolHive keeps such a vMCP Ready with fewer tools. Check the entry's auth: the type bearerToken is not supported by ToolHive 0.67.1 (the chart sends the bearer value with headerForward)." >&2
        return 1
      fi
      seen=$(jq '[.status.conditions[]?|select(.type|startswith("DiscoveredAuthConfig-"))]|length' <<<"$j" 2>/dev/null || echo 0)
      [ "${seen:-0}" -lt "$want" ] || break
      [ "$waited" -lt "$settle" ] || break
      sleep 3; waited=$((waited + 3))
    done
    if [ "${seen:-0}" -lt "$want" ]; then
      echo "WARN: the vMCP $name shows ${seen:-0} of $want DiscoveredAuthConfig conditions after ${settle}s; none is False. Check: $k get virtualmcpserver $name -n $ns -o yaml" >&2
    else
      echo "vMCP $name: ${seen} DiscoveredAuthConfig condition(s), none False"
    fi
  done
}
