#!/usr/bin/env bash
# shellcheck disable=SC2034  # the variables set here are used by the scripts that source this file
# Shared by hack/gke/up.sh, install.sh and down.sh. Sourced, not run.
# The state file is KEY=VALUE lines written by up.sh. It is read line by line, never sourced, and every value must
# match a strict pattern, so a changed file cannot run code or point the scripts at something unexpected.

GKE_LABEL=openagentix-gke-up   # the value of the label created-by on every project up.sh makes; down.sh deletes nothing else

die(){ echo "ERROR: $*" >&2; exit 1; }

RE_REGION='^[a-z]+-[a-z]+[0-9]+$'
RE_ZONE='^[a-z]+-[a-z]+[0-9]+-[a-z]$'
RE_CLUSTER='^[a-z][a-z0-9-]{0,38}[a-z0-9]$'
RE_PATH='^/[A-Za-z0-9._/-]+$'

# read_state <file>: sets PROJECT REGION ZONE CLUSTER REPO DEADLINE CREATED DELETED_AT, and STATE_DIR, KUBECONFIG_FILE and
# VALUES_FILE_GKE. The two file paths are never read from the file: they are always <directory of the state file>/kubeconfig
# and /gke-images.yaml, so a changed state file cannot point the scripts at your own kubeconfig.
read_state(){
  local f=$1 k v
  [ -f "$f" ] || die "no state file at $f (hack/gke/up.sh writes it)"
  PROJECT='' REGION='' ZONE='' CLUSTER='' REPO='' DEADLINE='' CREATED='' DELETED_AT=''
  while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue;; esac
    k=${line%%=*}; v=${line#*=}
    case "$k" in
      PROJECT)     [[ "$v" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || die "state file: bad PROJECT"; PROJECT=$v;;
      REGION)      [[ "$v" =~ $RE_REGION ]] || die "state file: bad REGION"; REGION=$v;;
      ZONE)        [[ "$v" =~ $RE_ZONE ]] || die "state file: bad ZONE"; ZONE=$v;;
      CLUSTER)     [[ "$v" =~ $RE_CLUSTER ]] || die "state file: bad CLUSTER"; CLUSTER=$v;;
      REPO)        [[ "$v" =~ ^[a-z0-9-]+-docker\.pkg\.dev/[a-z0-9-]+/[a-z0-9-]+$ ]] || die "state file: bad REPO"; REPO=$v;;
      DEADLINE|CREATED|DELETED_AT) [[ "$v" =~ ^[0-9]+$ ]] || die "state file: bad $k"; printf -v "$k" '%s' "$v";;
      *) die "state file: unknown key '$k'";;
    esac
  done < "$f"
  [ -n "$PROJECT" ] && [ -n "$ZONE" ] && [ -n "$CLUSTER" ] || die "state file $f is incomplete"
  STATE_DIR=$(cd "$(dirname "$f")" && pwd)
  [[ "$STATE_DIR" =~ $RE_PATH ]] || die "state directory $STATE_DIR has characters the scripts do not accept"
  KUBECONFIG_FILE=$STATE_DIR/kubeconfig VALUES_FILE_GKE=$STATE_DIR/gke-images.yaml
}

# project_is_ours: the project carries the label that up.sh sets (and so may be installed into or deleted)
project_is_ours(){ [ "$(gcloud projects describe "$PROJECT" --format='value(labels.created-by)' 2>/dev/null || true)" = "$GKE_LABEL" ]; }

# utc <epoch seconds>: a readable UTC time (GNU date or BSD date)
utc(){ date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -r "$1" '+%Y-%m-%d %H:%M UTC'; }

teardown_line(){ echo "TEARDOWN (run it when you are done, at the latest at $(utc "$2")): hack/gke/down.sh $1"; }
