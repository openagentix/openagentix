#!/usr/bin/env bash
# The installer's part of the knowledge base isolation (ADR 0030, section 2 and 6). Sourced by install.sh.
# Tests: hack/ci/kb-callers-test.sh (fake kubectl, no cluster).
#
#   kb_callers_ensure <kubectl command> <knowledge namespace> <tools namespace> <group>...
#       For each tool group, makes (only when absent, never printed, never in an argument) one random value and writes it, as the whole header
#       value "Bearer <value>", to two Secrets: the key <group> of the Secret kb-callers in the knowledge namespace (the knowledge base mounts it as
#       files) and the key value of the Secret kb-caller-<group> in the tools namespace (the MCPServerEntry sends it). When one of the two is
#       missing it is rebuilt from the other, never with a new value. Sets KB_CALLERS_CHANGED=1 when a value that existed was repaired.
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
    if /usr/bin/grep -q 'NotFound' "$err"; then rm -f "$err"; return 0; fi
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

# shellcheck disable=SC2034   # KB_CALLERS_CHANGED is read by install.sh
kb_callers_ensure() {
  local k=$1 kns=$2 mns=$3 g; shift 3
  local sv hv val
  KB_CALLERS_CHANGED=0
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
      echo "secret $kns/kb-callers key $g: $({ [ -n "$sv" ] || [ -n "$hv" ]; } && echo repaired || echo created)"
      { [ -n "$sv" ] || [ -n "$hv" ]; } && KB_CALLERS_CHANGED=1
    fi
    if [ "$hv" = "$val" ]; then echo "secret $mns/kb-caller-$g: kept"
    else
      kb_callers_put "$k" "$mns" "kb-caller-$g" value val "openagentix-kb-caller-$g" || { unset val sv hv; echo "ERROR: could not write the Secret $mns/kb-caller-$g" >&2; return 1; }
      echo "secret $mns/kb-caller-$g key value: $({ [ -n "$sv" ] || [ -n "$hv" ]; } && echo repaired || echo created)"
      { [ -n "$sv" ] || [ -n "$hv" ]; } && KB_CALLERS_CHANGED=1
    fi
  done
  unset val sv hv
  return 0
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
