#!/usr/bin/env bash
# shellcheck disable=SC2034  # the variables set here are used by the scripts that source this file
# Shared by hack/gke/up.sh, install.sh and down.sh. Sourced, not run.
# The state file is KEY=VALUE lines written by up.sh. It is read line by line, never sourced, and every value must
# match a strict pattern, so a changed file cannot run code or point the scripts at something unexpected.

GKE_LABEL=openagentix-gke-up   # the value of the label created-by on every project up.sh makes; down.sh deletes nothing else

die(){ echo "ERROR: $*" >&2; exit 1; }

# read_state <file>: sets PROJECT REGION ZONE CLUSTER REPO STATE_DIR KUBECONFIG_FILE VALUES_FILE_GKE DEADLINE CREATED DELETED_AT
read_state(){
  local f=$1 k v
  [ -f "$f" ] || die "no state file at $f (hack/gke/up.sh writes it)"
  PROJECT='' REGION='' ZONE='' CLUSTER='' REPO='' KUBECONFIG_FILE='' VALUES_FILE_GKE='' DEADLINE='' CREATED='' DELETED_AT=''
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue;; esac
    k=${line%%=*}; v=${line#*=}
    case "$k" in
      PROJECT)     [[ "$v" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "state file: bad PROJECT"; PROJECT=$v;;
      REGION)      [[ "$v" =~ ^[a-z]+-[a-z]+[0-9]+$ ]] || die "state file: bad REGION"; REGION=$v;;
      ZONE)        [[ "$v" =~ ^[a-z]+-[a-z]+[0-9]+-[a-z]$ ]] || die "state file: bad ZONE"; ZONE=$v;;
      CLUSTER)     [[ "$v" =~ ^[a-z][a-z0-9-]{0,38}[a-z0-9]$ ]] || die "state file: bad CLUSTER"; CLUSTER=$v;;
      REPO)        [[ "$v" =~ ^[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/[a-z0-9-]+$ ]] || die "state file: bad REPO"; REPO=$v;;
      KUBECONFIG)  [[ "$v" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "state file: bad KUBECONFIG"; KUBECONFIG_FILE=$v;;
      VALUES_FILE) [[ "$v" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "state file: bad VALUES_FILE"; VALUES_FILE_GKE=$v;;
      DEADLINE|CREATED|DELETED_AT) [[ "$v" =~ ^[0-9]+$ ]] || die "state file: bad $k"; printf -v "$k" '%s' "$v";;
      *) die "state file: unknown key '$k'";;
    esac
  done < "$f"
  [ -n "$PROJECT" ] && [ -n "$ZONE" ] && [ -n "$CLUSTER" ] || die "state file $f is incomplete"
  STATE_DIR=$(cd "$(dirname "$f")" && pwd)
}

# utc <epoch seconds>: a readable UTC time (GNU date or BSD date)
utc(){ date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -r "$1" '+%Y-%m-%d %H:%M UTC'; }

teardown_line(){ echo "TEARDOWN (run it when you are done, at the latest at $(utc "$2")): hack/gke/down.sh $1"; }
