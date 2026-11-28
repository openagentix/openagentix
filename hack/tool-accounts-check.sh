#!/usr/bin/env bash
# Install checks for mcp.virtual.ownServiceAccounts (ADR 0031, slice 3). Sourced by install.sh. Tests: hack/ci/tool-accounts-check-test.sh (fake kubectl, no cluster).
# The rendered documents (one JSON object per line, as install.sh holds them in $RENDERED) come on standard input. Nothing here reads a Secret or prints a value.

# ta_vmcp_rows: <namespace> TAB <tool server> TAB <account>, for each tool server that names an account of the chart
ta_vmcp_rows() {
  jq -r 'select(.kind=="VirtualMCPServer" and ((.spec.serviceAccount // "") != ""))|[.metadata.namespace,.metadata.name,.spec.serviceAccount]|@tsv'
}

# ta_unowned_rows: <namespace> TAB <tool server>, for each tool server that names no account (the operator makes one, with the right to read Secrets)
ta_unowned_rows() {
  jq -r 'select(.kind=="VirtualMCPServer" and ((.spec.serviceAccount // "") == ""))|[.metadata.namespace,.metadata.name]|@tsv'
}

# ta_warn_off: while a tool server has no account of the chart and the install holds a header credential in the tools namespace, say who can read it.
# Names of Secrets only, never a value. To standard error.
ta_warn_off() {
  local docs unowned names
  docs=$(cat)
  unowned=$(ta_unowned_rows <<<"$docs")
  [ -n "$unowned" ] || return 0
  names=$(jq -r 'select(.kind=="MCPServerEntry")|.metadata.namespace as $ns|.spec.headerForward.addHeadersFromSecret[]?|$ns+"/"+.valueSecretRef.name' <<<"$docs" | sort -u)
  [ -n "$names" ] || return 0
  {
    echo "WARNING: mcp.virtual.ownServiceAccounts is false. Every tool server in the tools namespace can read every Secret there, so a tool server of one tool group can read"
    echo "the credential of another. Header credentials in this install (names only):"
    printf '  - %s\n' $names
    echo "Set mcp.virtual.ownServiceAccounts=true (components/tools/own-service-accounts-values.yaml) to take that right from the tool server accounts. See docs/decisions/0031-tool-server-secret-reach.md."
  } >&2
}

# ta_refuse_off <kubectl...>: standard input is the rendered documents. Fails when a tool server of the cluster runs on a chart account (its spec names openagentix-*)
# and this render names no account for it: the operator would make its own account again, with the right to read every Secret. ALLOW_TOOL_SECRET_READ=1 allows it.
ta_refuse_off() {
  local k=("$@") docs ns name rows live off=""
  docs=$(cat)
  rows=$(ta_unowned_rows <<<"$docs")
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r ns name; do
    [ -n "$ns" ] || continue
    live=$("${k[@]}" get virtualmcpserver -n "$ns" -o json 2>/dev/null) || continue
    if jq -e --arg n "$name" '.items[]?|select(.metadata.name==$n and ((.spec.serviceAccount // "")|startswith("openagentix-")))' <<<"$live" >/dev/null 2>&1; then off+=" $ns/$name"; fi
  done <<<"$rows"
  [ -n "$off" ] || return 0
  if [ "${ALLOW_TOOL_SECRET_READ:-0}" = 1 ]; then
    echo "WARNING: turning off mcp.virtual.ownServiceAccounts for${off} (ALLOW_TOOL_SECRET_READ=1): the operator makes their accounts again, with the right to read every Secret in the tools namespace." >&2
    return 0
  fi
  echo "ERROR: the tool server(s)${off} run on accounts of the chart, and this run's values turn mcp.virtual.ownServiceAccounts off (a values file left out of the list?). Helm replaces the release values on every run. That would give every tool server the right to read every Secret in the tools namespace again. Give the same list of values files, or set ALLOW_TOOL_SECRET_READ=1 if you mean it. Nothing was changed." >&2
  return 1
}

# ta_check_account <kubectl> <namespace> <account>: the account may not read a Secret or create a pod, a StatefulSet or a Deployment. Fails on a yes, and on an answer
# that is neither yes nor no (an API error): the check then cannot tell.
ta_check_account() {
  local k=$1 ns=$2 sa=$3 q verb res out bad=0
  for q in "get secrets" "list secrets" "create pods" "create statefulsets" "create deployments"; do
    verb=${q% *}; res=${q#* }
    out=$($k auth can-i "$verb" "$res" -n "$ns" --as="system:serviceaccount:$ns:$sa" 2>/dev/null)
    case "$out" in
      no) ;;
      yes) echo "ERROR: the account $sa in $ns can $verb $res. The tool server must not (ADR 0031). The Role of the account is the chart's; something else binds a right to it." >&2; bad=1;;
      *) echo "ERROR: cannot tell whether the account $sa in $ns can $verb $res (the answer was '${out:-none}'): the install check cannot tell, so the install fails." >&2; bad=1;;
    esac
  done
  [ "$bad" = 0 ] || return 1
  echo "$sa: no right on Secrets, and none to create pods, StatefulSets or Deployments"
}

# ta_wait_running <kubectl> <namespace> <tool server> <account> <seconds>: the Deployment of the tool server names the account, and its rollout is done
ta_wait_running() {
  local k=$1 ns=$2 name=$3 sa=$4 max=$5 waited=0 now=""
  while :; do
    now=$($k get deployment "$name" -n "$ns" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null) || now=""
    [ "$now" != "$sa" ] || break
    [ "$waited" -lt "$max" ] || { echo "ERROR: the Deployment $name in $ns runs as ${now:-an account that cannot be read}, not $sa, after ${max}s." >&2; return 1; }
    sleep 3; waited=$((waited + 3))
  done
  $k rollout status "deployment/$name" -n "$ns" --timeout=300s >/dev/null || { echo "ERROR: the Deployment $name in $ns did not finish its rollout under $sa." >&2; return 1; }
}

# ta_cleanup <kubectl> <namespace> <tool server> <account>: delete the ServiceAccount, Role and RoleBinding <tool server>-vmcp that the operator made, once the Deployment
# runs as the chart's account. Only these three kinds, only that name; the name is checked before it is used.
ta_cleanup() {
  local k=$1 ns=$2 name=$3 sa=$4 now kind
  [[ "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo "ERROR: the tool server name '$name' is not a DNS name: nothing is deleted." >&2; return 1; }
  [ "$sa" != "$name-vmcp" ] || { echo "ERROR: the account to keep is the operator's own ($sa): nothing is deleted." >&2; return 1; }
  now=$($k get deployment "$name" -n "$ns" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null) || now=""
  [ "$now" = "$sa" ] || { echo "ERROR: the Deployment $name in $ns runs as ${now:-an account that cannot be read}, not $sa: the operator's objects stay." >&2; return 1; }
  for kind in serviceaccount role rolebinding; do
    $k delete "$kind" "$name-vmcp" -n "$ns" --ignore-not-found >/dev/null || return 1
  done
}
