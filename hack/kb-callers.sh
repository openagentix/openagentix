#!/usr/bin/env bash
# The installer's part of the knowledge base isolation (ADR 0030, section 2 and 6). Sourced by install.sh.
# Tests: hack/ci/kb-callers-test.sh (fake kubectl, no cluster).
#
#   kb_callers_ensure <kubectl command> <knowledge namespace> <tools namespace> <group>...
#       For each tool group, makes (only when absent, never printed, never in an argument) one random value and writes it, as the whole header
#       value "Bearer <value>", to two Secrets: the key <group> of the Secret kb-callers in the knowledge namespace (the knowledge base mounts it as
#       files) and the key value of the Secret kb-caller-<group> in the tools namespace (the MCPServerEntry sends it). When one of the two is
#       missing it is rebuilt from the other, never with a new value. Sets KB_CALLERS_CHANGED=1 when a value that existed was repaired, and KB_CALLERS_TOUCHED to the
#       groups whose value was created or repaired (a rotation deletes both Secrets, so the new value is 'created': the vMCPs that already run still hold the old one).
#   kb_access_guard <mode of the live release> <mode of this run> <ALLOW_KB_ACCESS_OFF>
#       returns 1 and says why when the live release enforces and this run does not, unless the third argument is 1.
#   The warning for an empty mode with profiles on two or more groups is the chart's NOTES.txt; install.sh prints it from a client-side dry run.
#
# Rotation (ADR 0030 section 3): both Secrets change together, then the tool servers of the group restart; calls get 401 in between.
# To rotate one group: delete its key from kb-callers and its Secret kb-caller-<group>, then run install.sh; it makes a new value, writes both, and
# the vMCP pods of the group (which hold the old value as an environment value) are restarted by the installer's check.

kb_callers_read() {   # <kubectl> <namespace> <secret> <key>: the decoded value, empty when absent; 2 when the API cannot be read
  local v err rc key=${4//./\\.}
  err=$(mktemp)
  v=$($1 get secret -n "$2" "$3" -o jsonpath="{.data.${key}}" 2>"$err"); rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$(head -n 1 "$err")" = "Error from server (NotFound): secrets \"$3\" not found" ]; then rm -f "$err"; return 0; fi
    rm -f "$err"; return 2
  fi
  rm -f "$err"
  [ -n "$v" ] || return 0
  printf '%s' "$v" | base64 -d 2>/dev/null || true
}

kb_callers_put() {    # <kubectl> <namespace> <secret> <key> <value var name> <field manager>: set one key of one Secret, nothing else in it
  local k=$1 ns=$2 name=$3 key=$4 var=$5 fm=$6
  $k create secret generic "$name" -n "$ns" --from-file="$key"=<(printf '%s' "${!var}") --dry-run=client -o yaml 2>/dev/null \
    | $k apply --server-side --force-conflicts --field-manager="$fm" -f - >/dev/null 2>&1
}

# shellcheck disable=SC2034   # KB_CALLERS_CHANGED and KB_CALLERS_TOUCHED are read by install.sh
kb_callers_ensure() {
  local k=$1 kns=$2 mns=$3 g; shift 3
  local sv hv val
  KB_CALLERS_CHANGED=0
  KB_CALLERS_TOUCHED=""   # the groups whose value was created or repaired: their vMCPs, if they already run, hold the old value
  for g in "$@"; do
    sv=$(kb_callers_read "$k" "$kns" kb-callers "$g") || { echo "ERROR: could not read the Secret $kns/kb-callers (is the API server reachable, may this identity read Secrets?). Nothing was changed." >&2; return 1; }
    hv=$(kb_callers_read "$k" "$mns" "kb-caller-$g" value) || { unset sv; echo "ERROR: could not read the Secret $mns/kb-caller-$g (is the API server reachable, may this identity read Secrets?). Nothing was changed." >&2; return 1; }
    if [ -n "$sv" ]; then val=$sv
    elif [ -n "$hv" ]; then val=$hv
    else
      val=$(openssl rand -hex 32) && [ -n "$val" ] || { unset val sv hv; echo "ERROR: could not make a value for the tool group $g (is openssl installed?)" >&2; return 1; }
      val="Bearer $val"
    fi
    if [ "$sv" = "$val" ]; then echo "secret $kns/kb-callers key $g: kept"
    else
      kb_callers_put "$k" "$kns" kb-callers "$g" val "openagentix-kb-caller-$g" || { unset val sv hv; echo "ERROR: could not write the key $g of the Secret $kns/kb-callers" >&2; return 1; }
      KB_CALLERS_TOUCHED="${KB_CALLERS_TOUCHED:+$KB_CALLERS_TOUCHED }$g"
      echo "secret $kns/kb-callers key $g: $({ [ -n "$sv" ] || [ -n "$hv" ]; } && echo repaired || echo created)"
      { [ -n "$sv" ] || [ -n "$hv" ]; } && KB_CALLERS_CHANGED=1
    fi
    if [ "$hv" = "$val" ]; then echo "secret $mns/kb-caller-$g: kept"
    else
      kb_callers_put "$k" "$mns" "kb-caller-$g" value val "openagentix-kb-caller-$g" || { unset val sv hv; echo "ERROR: could not write the Secret $mns/kb-caller-$g" >&2; return 1; }
      case " $KB_CALLERS_TOUCHED " in *" $g "*) ;; *) KB_CALLERS_TOUCHED="${KB_CALLERS_TOUCHED:+$KB_CALLERS_TOUCHED }$g";; esac
      echo "secret $mns/kb-caller-$g key value: $({ [ -n "$sv" ] || [ -n "$hv" ]; } && echo repaired || echo created)"
      { [ -n "$sv" ] || [ -n "$hv" ]; } && KB_CALLERS_CHANGED=1
    fi
  done
  unset val sv hv
  return 0
}

# kb_callers_restart <kubectl command> <namespace/name>...: restart each vMCP Deployment and wait for it (they hold the value as an environment value)
kb_callers_restart() {
  local k=$1 row ns name; shift
  for row in "$@"; do
    ns=${row%%/*}; name=${row##*/}
    $k rollout restart "deployment/$name" -n "$ns" >/dev/null || { echo "ERROR: could not restart $ns/$name" >&2; return 1; }
    $k rollout status "deployment/$name" -n "$ns" --timeout=180s >/dev/null || { echo "ERROR: $ns/$name did not become Ready after the restart" >&2; return 1; }
    echo "restarted vMCP $ns/$name (it holds the value of its tool group as an environment value)"
  done
}

# kb_callers_running <kubectl command> <rendered objects, one JSON per line>: the vMCPs of the rendered objects that already run in the cluster, as namespace/name words. Called before
# the chart is applied: after a rotation they hold the old value as an environment value, and a first install has none.
kb_callers_running() {
  local k=$1 rendered=$2 row
  for row in $(jq -r 'select(.kind=="VirtualMCPServer")|.metadata.namespace+"/"+.metadata.name' <<<"$rendered"); do
    $k get deployment "${row##*/}" -n "${row%%/*}" >/dev/null 2>&1 && printf '%s ' "$row"
  done
  return 0
}

# kb_callers_verify <kubectl command> <rendered objects, one JSON per line> <knowledge namespace> <groups whose value was created or repaired> <vMCPs that ran before the chart was applied> <group>...
# For every vMCP of every caller group: restart it when a value was repaired, wait for Ready, then fail when a condition DiscoveredAuthConfig-* is False or when the
# knowledge base entry of the group is not a ready backend. Needs hack/diagnostics-check.sh (diag_check_vmcps) and hack/endpoints-check.sh (ep_check_backends).
kb_callers_verify() {
  local k=$1 rendered=$2 kns=$3 touched=$4 before=$5 g row vmcps entries kbentry stale; shift 5
  type diag_check_vmcps >/dev/null 2>&1 || . hack/diagnostics-check.sh
  type ep_check_backends >/dev/null 2>&1 || . hack/endpoints-check.sh
  for g in "$@"; do
    vmcps=$(jq -r --arg g "$g" 'select(.kind=="VirtualMCPServer" and .spec.groupRef.name==$g)|.metadata.namespace+"/"+.metadata.name' <<<"$rendered")
    entries=$(jq -rs --arg g "$g" '[.[]|select(.kind=="MCPServerEntry" and .spec.groupRef.name==$g)|.metadata.name]|sort|join(" ")' <<<"$rendered")
    kbentry=$(jq -rs --arg g "$g" '[.[]|select(.kind=="MCPServerEntry" and .spec.groupRef.name==$g and ((.spec.headerForward.addHeadersFromSecret[0].valueSecretRef.name//"")=="kb-caller-"+$g))|.metadata.name]|first // ""' <<<"$rendered")
    stale=""
    case " $touched " in *" $g "*) for row in $vmcps; do case " $before " in *" $row "*) stale="$stale $row";; esac; done;; esac
    if [ -n "$stale" ]; then
      # shellcheck disable=SC2086   # one word per vMCP
      kb_callers_restart "$k" $stale || { echo "ERROR: could not restart the vMCPs of the group $g after the value of the knowledge base caller changed" >&2; return 1; }
    fi
    for row in $vmcps; do
      $k wait "virtualmcpserver/${row##*/}" -n "${row%%/*}" --for=condition=Ready --timeout=300s || { echo "ERROR: the vMCP ${row##*/} of the group $g is not Ready: $k get virtualmcpserver ${row##*/} -n ${row%%/*} -o yaml" >&2; return 1; }
      DIAG_CHECK_WHAT="the group $g (knowledge base isolation)" diag_check_vmcps "$k" "${KB_VMCP_SETTLE:-30}" "$(wc -w <<<"$entries" | tr -d ' ')" "$row" || return 1
      [ -n "$kbentry" ] || continue
      ep_check_backends "$k" "${KB_VMCP_SETTLE:-60}" "$row" "$kbentry" || { echo "ERROR: a vMCP of the group $g does not list the knowledge base as ready. Its value may be refused: $k logs -n $kns deploy/kb --tail=20 (no value is logged)." >&2; return 1; }
    done
  done
}

# kb_caller_header <kubectl command> <group> [tools namespace]: the whole header "Authorization: Bearer <value>" of a tool group, for a script that calls /mcp itself
# (hack/kb-graph-canary.sh, hack/ci/upgrade-test.sh) while knowledge.access.mode is set. Prints nothing when the group has no Secret (the mode is off). The caller keeps the
# header in a shell variable and hands it to curl through a descriptor (curl -K <(printf 'header = "%s"\n' "$H")), never in argv, never printed.
kb_caller_header() {
  local k=$1 g=$2 ns=${3:-mcp-tools} v
  v=$($k get secret -n "$ns" "kb-caller-$g" -o jsonpath='{.data.value}' 2>/dev/null | base64 -d 2>/dev/null) || return 0
  [ -z "$v" ] || printf 'Authorization: %s' "$v"
  return 0
}

# kb_live_mode <helm command> <release> <release namespace> <kube context> <kubectl command>: prints the knowledge.access.mode of the LIVE release ("" when it has none).
# The namespace of the knowledge base is read from the live release (helm get values -a), not from this run's values, so a run that moves it is still compared with what is
# running. Only helm's own line "Error: release: not found" (a first install) and the exact NotFound sentences for the ConfigMap kb-access or its namespace mean "no mode". Any other failure (Forbidden, a timeout, a wrong
# context, values that are not JSON) returns 2 with a sentence on standard error: the caller must stop, because a guess of "no mode" would let a run turn enforce off.
kb_live_mode() {
  local helm=$1 rel=$2 rns=$3 ctx=$4 k=$5 vals kns cm err rc mode
  err=$(mktemp)
  vals=$($helm get values "$rel" -n "$rns" --kube-context "$ctx" -a -o json 2>"$err"); rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$(head -n 1 "$err")" = "Error: release: not found" ]; then rm -f "$err"; return 0; fi
    echo "cannot read the values of the release $rel in namespace $rns: $(head -n 1 "$err" | cut -c1-300)" >&2; rm -f "$err"; return 2
  fi
  kns=$(jq -r '.knowledge.namespace // empty' <<<"$vals" 2>/dev/null) || kns=""
  if [ -z "$kns" ]; then echo "cannot read the values of the release $rel: no knowledge.namespace in them" >&2; rm -f "$err"; return 2; fi
  cm=$($k --context "$ctx" get configmap kb-access -n "$kns" -o jsonpath='{.data.access\.json}' 2>"$err"); rc=$?
  if [ "$rc" != 0 ]; then
    case "$(head -n 1 "$err")" in
      "Error from server (NotFound): configmaps \"kb-access\" not found"|"Error from server (NotFound): namespaces \"$kns\" not found") rm -f "$err"; return 0;;
    esac
    echo "cannot read the ConfigMap kb-access in namespace $kns: $(head -n 1 "$err" | cut -c1-300)" >&2; rm -f "$err"; return 2
  fi
  rm -f "$err"
  [ -n "$cm" ] || return 0
  mode=$(jq -r '.mode // ""' <<<"$cm" 2>/dev/null) || { echo "cannot read the ConfigMap kb-access in namespace $kns: it is not JSON" >&2; return 2; }
  printf '%s' "$mode"
}

kb_access_guard() {
  local live=${1:-} new=${2:-} allow=${3:-}
  [ "$live" = enforce ] && [ "$new" != enforce ] || return 0
  if [ "$allow" = 1 ]; then
    echo "WARN: knowledge.access.mode changes from enforce to \"${new:-}\" (ALLOW_KB_ACCESS_OFF=1): every caller will read every collection again." >&2
    return 0
  fi
  echo "ERROR: the live release has knowledge.access.mode=enforce and this run has \"${new:-}\" (a values file left out of VALUES_FILE would do this, because Helm replaces the release values on every run). That would turn the isolation of the knowledge base off. Pass the same values file again, or set ALLOW_KB_ACCESS_OFF=1 if you mean it. Nothing was changed." >&2
  return 1
}
