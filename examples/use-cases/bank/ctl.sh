#!/usr/bin/env bash
# The desk's commands for the bank use case. Local kind cluster, after examples/use-cases/bank/install.sh. Set CLUSTER=<kind cluster name> on every call.
#
#   ctl.sh ask "Work case DSP-2026-0001"     ask the dispute agent through the A2A gate, as the desk (ServiceAccount disputes-desk)
#   ctl.sh cases                             open cases (id, claim, status, route)
#   ctl.sh case DSP-2026-0001                one case with its evidence, as the REST API shows it
#   ctl.sh approvals                         approval requests (id, case, kind, amount, status)
#   ctl.sh show APR-0001                     one request: the exact payload the approver decides, and its hash
#   ctl.sh approve APR-0001 [--yes] [note]   read the request, then approve it as desk:lead-1 (asks first unless --yes)
#   ctl.sh reject APR-0001 [note]            reject it: the case goes back to an analyst
#   ctl.sh outbox | ledger                   what was queued to leave the bank, and what was posted to an account
#
# REST is reached only through `kubectl port-forward` to the pod (it listens on the pod's loopback). The approver token is read from the
# Secret records-approver-token into a shell variable and given to curl through a file descriptor: never printed, never in an argument list.
# The port-forward is opened once, in the main shell, before any command reads. A forward opened inside a pipeline or $(...) would be
# lost when that subshell ends and would stay up after the script. The script refuses a context that is not kind-*.
# Env: CLUSTER (REQUIRED unless KUBE_CONTEXT is set)  KUBE_CONTEXT (default kind-$CLUSTER)  KUBECTL  RECORDS_NAMESPACE (default fernvale-records)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
# No default cluster: a script that acts on a cluster must be told which one, so it never runs on a cluster by guess (a name like "openagentix" is
# also the name of a full demo cluster).
[ -n "${CLUSTER:-}${KUBE_CONTEXT:-}" ] || { echo "ERROR: set CLUSTER (the kind cluster name) or KUBE_CONTEXT: there is no default cluster. Nothing was changed." >&2; exit 1; }
CLUSTER=${CLUSTER:-${KUBE_CONTEXT#kind-}}
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-$CLUSTER}
KUBECTL=${KUBECTL:-kubectl}
NS=${RECORDS_NAMESPACE:-fernvale-records}
KC=("$KUBECTL" --context "$KUBE_CONTEXT")

die(){ echo "ERROR: $*" >&2; exit 1; }
case "$KUBE_CONTEXT" in
  kind-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind cluster (kind-<name>). Set CLUSTER or KUBE_CONTEXT." ;;
esac
usage(){ sed -n 2,13p "$0" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
for c in jq curl; do command -v "$c" >/dev/null || die "$c is required"; done
[ $# -ge 1 ] || usage

PF_PID=""; PF_LOG=""; BASE=""
cleanup(){
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; fi
  if [ -n "$PF_LOG" ]; then rm -f "$PF_LOG"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

connect(){
  PF_LOG=$(mktemp)
  "${KC[@]}" port-forward -n "$NS" deploy/records :8081 >"$PF_LOG" 2>&1 &
  PF_PID=$!
  local port=""
  for _ in $(seq 1 30); do
    port=$(sed -nE 's/^Forwarding from 127\.0\.0\.1:([0-9]+) .*/\1/p' "$PF_LOG" | head -1)
    [ -n "$port" ] && break
    kill -0 "$PF_PID" 2>/dev/null || die "port-forward failed: $(cat "$PF_LOG")"
    sleep 1
  done
  [ -n "$port" ] || die "port-forward did not come up"
  BASE="http://127.0.0.1:$port"
  for _ in $(seq 1 30); do curl -fsS -m 3 "$BASE/readyz" >/dev/null 2>&1 && return 0; sleep 1; done
  die "the records service is not ready"
}

get(){ curl -fsS -m 15 "$BASE$1"; }

sha256(){ if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
valid_id(){ [[ "$2" =~ $1 ]] || die "'$2' is not a valid id"; }
CASE_RE='^DSP-[0-9]{4}-[0-9]{4}$'; APR_RE='^APR-[0-9]{4,}$'

# decide <approve|reject> <APR-id> <note>
decide(){
  local what=$1 id=$2 note=$3 token body code resp
  token=$("${KC[@]}" get secret records-approver-token -n "$NS" -o jsonpath='{.data.token}' | base64 -d)
  [ -n "$token" ] || die "no approver token in the Secret records-approver-token"
  if [ "$what" = approve ]; then
    body=$(jq -nc --arg h "$HASH" --arg n "$note" '{payload_hash:$h,note:$n}')
  else
    body=$(jq -nc --arg n "$note" '{note:$n}')
  fi
  resp=$(mktemp)
  code=$(curl -sS -m 30 -o "$resp" -w '%{http_code}' -X POST -K <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
    -H 'Content-Type: application/json' -d "$body" "$BASE/approvals/$id/$what") || code=000
  unset token
  if [ "$code" = 200 ]; then jq -r '"\(.id): \(.status) by \(.decided_by)"' "$resp"; rm -f "$resp"
  else echo "ERROR: http $code: $(jq -r '.error // "refused"' "$resp" 2>/dev/null || echo refused)" >&2; rm -f "$resp"; exit 1; fi
}

cmd=$1; shift
case "$cmd" in
  ask)
    [ $# -eq 1 ] || usage
    ASK_SA=openagentix-system/disputes-desk ASK_USER=desk:analyst-1 KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$ROOT/hack/ask.sh" dispute-agent "$1" ;;
  cases)
    connect; get /cases | jq -r '.cases[] | [.id, .claim_type, .status, (.route // "-")] | @tsv' ;;
  case)
    [ $# -eq 1 ] || usage; valid_id "$CASE_RE" "$1"; connect; get "/cases/$1" | jq . ;;
  approvals)
    connect; get /approvals | jq -r '.approvals[] | [.id, .subject, .kind, .amount_cents, .status] | @tsv' ;;
  show)
    [ $# -eq 1 ] || usage; valid_id "$APR_RE" "$1"
    connect; get "/approvals/$1" | jq -r '"proposed by: \(.proposed_by)\nstatus: \(.status)\npayload_hash: \(.payload_hash)\npayload:\n\(.payload)"' ;;
  approve|reject)
    [ $# -ge 1 ] || usage
    id=$1; shift; valid_id "$APR_RE" "$id"
    yes=0; note=""
    for a in "$@"; do if [ "$a" = --yes ]; then yes=1; else note="$a"; fi; done
    connect
    ar=$(get "/approvals/$id")
    status=$(jq -r .status <<<"$ar")
    [ "$status" = pending ] || die "$id is $status, not pending"
    HASH=$(jq -r .payload_hash <<<"$ar")
    LOCAL=$(jq -j .payload <<<"$ar" | sha256)
    [ "$LOCAL" = "$HASH" ] || die "the payload_hash the service sent does not match the SHA-256 of the payload it sent: nothing was decided"
    echo "$id was proposed by $(jq -r .proposed_by <<<"$ar"). The payload you decide:"
    jq -r .payload <<<"$ar"
    echo "payload_hash: $HASH"
    if [ "$yes" != 1 ]; then
      printf '%s %s as desk:lead-1? [y/N] ' "$cmd" "$id"
      read -r answer </dev/tty || die "no terminal to ask on: pass --yes to decide without asking"
      [ "$answer" = y ] || [ "$answer" = Y ] || die "not confirmed: nothing changed"
    fi
    [ -n "$note" ] || note="decided with ctl.sh"
    decide "$cmd" "$id" "$note" ;;
  outbox) connect; get /outbox | jq -r '.outbox[] | [.id, .subject, .kind, .status] | @tsv' ;;
  ledger) connect; get /ledger | jq -r '.ledger[] | [.case_id, .kind, .amount_cents, .approval_id, .posted_at] | @tsv' ;;
  -h|--help|help) usage 0 ;;
  *) usage ;;
esac
