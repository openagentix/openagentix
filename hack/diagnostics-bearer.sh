#!/usr/bin/env bash
# shellcheck disable=SC2034   # DIAG_BEARER_CHANGED is read by install.sh, hval by diag_bearer_put through its name
# The bearer value between the tool gateway and a diagnostics tool server (ADR 0025 section 5, Amendment 1). Sourced by install.sh.
# Tests: hack/ci/diagnostics-bearer-test.sh (fake kubectl, no cluster).
#
# One random value per server, kept as two Secrets with the same value:
#   <server>-bearer               key `bearer`         in the diagnostics namespace   the value alone; the server mounts it as a file (-bearer-file)
#   diagnostics-bearer-<server>   key `authorization`  in the tools namespace         "Bearer <value>"; the MCPServerEntry sends it as the Authorization
#                                                                                      header (headerForward.addHeadersFromSecret; ToolHive sends the Secret
#                                                                                      as it is, so the scheme word is in the Secret)
# The value is made with openssl rand, only when neither Secret holds one, and never rotated by a re-run. It is never an argument, never an
# environment value, never printed: it goes through process substitution and a pipe. A Secret that is missing or different is brought to the
# value of the other one; when both exist and differ, the server's own Secret wins. Server-side apply, so no last-applied annotation holds it.
# Only "not found" means absent: any other error while reading a Secret stops the run, so an API blip can never make a new value (review F4).
#
#   diag_bearer_ensure <kubectl command> <tools namespace> <diagnostics namespace> <server>
#       prints one line per Secret (kept, created or repaired), never the value; returns 1 with a fixed message on a failure.
#       Sets DIAG_BEARER_CHANGED=1 when a Secret was written while the other one already existed (the vMCP pods of the group then hold the old
#       value as an environment value: restart them with diag_bearer_restart), else 0.
#   diag_bearer_restart <kubectl command> <namespace/name>...
#       restarts each vMCP Deployment and waits for it, so the pods take the value of the Secret

# diag_bearer_read <kubectl command> <namespace> <name> <key>: prints the value; returns 0 when absent (not found, or the key is empty), 2 on any other error
diag_bearer_read() {
  local v err rc
  err=$(mktemp)
  v=$($1 get secret -n "$2" "$3" -o jsonpath="{.data.$4}" 2>"$err"); rc=$?
  if [ "$rc" != 0 ]; then
    if grep -q 'NotFound' "$err"; then rm -f "$err"; return 0; fi
    rm -f "$err"; return 2
  fi
  rm -f "$err"
  [ -n "$v" ] || return 0
  printf '%s' "$v" | base64 -d 2>/dev/null || true
}

diag_bearer_put() {    # <kubectl command> <namespace> <name> <key> <value var name>: create or replace one Secret
  local k=$1 ns=$2 name=$3 key=$4 var=$5
  # the value is read from the variable named in $5, inside the process substitution: it reaches no argument list
  $k create secret generic "$name" -n "$ns" --from-file="$key"=<(printf '%s' "${!var}") --dry-run=client -o yaml 2>/dev/null \
    | $k apply --server-side --force-conflicts --field-manager=openagentix-diagnostics -f - >/dev/null 2>&1
}

diag_bearer_ensure() {
  local k=$1 mcpns=$2 dns=$3 srv=$4
  local sname="$srv-bearer" hname="diagnostics-bearer-$srv"
  local sv hv val hval
  DIAG_BEARER_CHANGED=0
  sv=$(diag_bearer_read "$k" "$dns" "$sname" bearer) || { echo "ERROR: could not read the Secret $dns/$sname (is the API server reachable, may this identity read Secrets?). Nothing was changed." >&2; return 1; }
  hv=$(diag_bearer_read "$k" "$mcpns" "$hname" authorization) || { unset sv; echo "ERROR: could not read the Secret $mcpns/$hname (is the API server reachable, may this identity read Secrets?). Nothing was changed." >&2; return 1; }
  hv=${hv#Bearer }
  if [ -n "$sv" ]; then val=$sv
  elif [ -n "$hv" ]; then val=$hv
  else
    val=$(openssl rand -hex 32) && [ -n "$val" ] || { echo "ERROR: could not make a bearer value for $srv (is openssl installed?)" >&2; return 1; }
  fi
  if [ "$sv" = "$val" ]; then echo "secret $dns/$sname: kept"
  else
    diag_bearer_put "$k" "$dns" "$sname" bearer val || { unset val sv hv hval; echo "ERROR: could not write Secret $dns/$sname" >&2; return 1; }
    echo "secret $dns/$sname key bearer: $([ -n "$sv" ] && echo repaired || echo created)"
    { [ -n "$sv" ] || [ -n "$hv" ]; } && DIAG_BEARER_CHANGED=1
  fi
  if [ "$hv" = "$val" ]; then echo "secret $mcpns/$hname: kept"
  else
      hval="Bearer $val"
    diag_bearer_put "$k" "$mcpns" "$hname" authorization hval || { unset val sv hv hval; echo "ERROR: could not write Secret $mcpns/$hname" >&2; return 1; }
    echo "secret $mcpns/$hname key authorization: $([ -n "$hv" ] && echo repaired || echo created)"
    { [ -n "$sv" ] || [ -n "$hv" ]; } && DIAG_BEARER_CHANGED=1
  fi
  unset val sv hv hval
  return 0
}

diag_bearer_restart() {
  local k=$1 row ns name; shift
  for row in "$@"; do
    ns=${row%%/*}; name=${row##*/}
    $k rollout restart "deployment/$name" -n "$ns" >/dev/null || { echo "ERROR: could not restart $ns/$name" >&2; return 1; }
    $k rollout status "deployment/$name" -n "$ns" --timeout=180s >/dev/null || { echo "ERROR: $ns/$name did not become Ready after the restart" >&2; return 1; }
    echo "restarted vMCP $ns/$name (it holds the bearer value as an environment value)"
  done
}
