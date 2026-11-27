#!/usr/bin/env bash
# Scans what the live job is about to upload for the planted values (hack/ci/rca-canaries.sh), and fails when one is there.
#   hack/ci/rca-upload-scan.sh <report dir> <log file>... [--platform-logs <dir>]
# - the report dir (report.json, retries, audit file, eval output) and the log files (the job log, the install log): no planted value of ANY kind;
# - the platform logs (kind export logs): none of the values the server removes, except in the logs of the pods of rca-demo themselves, which print them
#   on purpose (that is where they come from). The two values that reach the model may be in the logs of the agent runtime, so they are not searched there.
# Prints file names and counts, never a match. Exit 1 when a value is found, 2 on a bad call. No cluster is needed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
MANIFEST=${RCA_MANIFEST:-$ROOT/examples/use-cases/software-org/manifests/rca-demo.yaml}
[ $# -ge 1 ] || { echo "usage: rca-upload-scan.sh <report dir> <log file>... [--platform-logs <dir>]" >&2; exit 2; }
REPORT=$1; shift
LOGS=(); PLATFORM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --platform-logs) [ $# -ge 2 ] || { echo "--platform-logs needs a directory" >&2; exit 2; }; PLATFORM=$2; shift ;;
    *) LOGS+=("$1") ;;
  esac
  shift
done
# shellcheck source=hack/ci/rca-canaries.sh
. "$HERE/rca-canaries.sh"
P=$(mktemp -d); trap 'rm -rf "$P"' EXIT
N=$(rca_canary_patterns "$MANIFEST" "$P" | grep -c .)
[ "$N" = 5 ] || { echo "rca-upload-scan: expected five planted values in $MANIFEST, found $N: the scan would prove nothing" >&2; exit 2; }
HITS=0
hit() { echo "rca-upload-scan: FOUND a planted value in $1 ($2 line(s))"; HITS=$((HITS+1)); }
if [ -d "$REPORT" ]; then
  while IFS= read -r f; do
    case "$f" in
      */report.json|*/retry-*.json)
        # an oa-eval report holds the answers and, for each check, the pattern it used (the patterns hold the random parts of the planted values, on purpose):
        # only the answers are searched. A file that is not the JSON of a report is searched whole.
        if jq -e '.cases' "$f" >/dev/null 2>&1; then n=$(jq -r '.cases[]?.answer // empty' "$f" | grep -ciF -f "$P/canary.all" 2>/dev/null)
        else n=$(grep -ciF -f "$P/canary.all" "$f" 2>/dev/null); fi ;;
      *) n=$(grep -ciF -f "$P/canary.all" "$f" 2>/dev/null) ;;
    esac
    [ "${n:-0}" = 0 ] || hit "$f" "$n"
  done < <(find "$REPORT" -type f | sort)
fi
for f in ${LOGS[@]+"${LOGS[@]}"}; do
  [ -f "$f" ] || continue
  n=$(grep -ciF -f "$P/canary.all" "$f" 2>/dev/null); [ "${n:-0}" = 0 ] || hit "$f" "$n"
done
if [ -n "$PLATFORM" ] && [ -d "$PLATFORM" ]; then
  while IFS= read -r f; do
    case "$f" in *_rca-demo_*|*/rca-demo_*|*/rca-demo/*) continue ;; esac   # the logs of the broken workloads: they print the values themselves
    n=$(grep -aiF -c -f "$P/canary.removed" "$f" 2>/dev/null); [ "${n:-0}" = 0 ] || hit "$f" "$n"
  done < <(find "$PLATFORM" -type f | sort)
fi
if [ "$HITS" = 0 ]; then echo "rca-upload-scan: no planted value in what is uploaded"; exit 0; fi
exit 1
