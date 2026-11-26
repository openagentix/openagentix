#!/usr/bin/env bash
# Flake sweep of one Go module (issue #194): `go test ./... -race -count=N` (N is 20 by default) and a list of the tests that failed, with
# how many of the N runs failed. The nightly workflow .github/workflows/flake-sweep.yml runs it once per module.
#
#   hack/ci/flake-sweep.sh <module-dir> [--count N] [--summary FILE]
#
#   --count N       runs of every test (default 20)
#   --summary FILE  append the report, as Markdown, to FILE (the workflow passes $GITHUB_STEP_SUMMARY)
#   SWEEP_TIMEOUT   go test -timeout for the whole run of a package (default 30m; with -count=20 the default of 10m is too short)
#
# Exit 0: every test passed in all N runs. Exit 1: a test failed, or go test failed for another reason (build error, timeout, panic
# outside a test). Exit 2: bad arguments. Local, every module: for m in $(hack/ci/go-modules.sh); do hack/ci/flake-sweep.sh "$m"; done
# (or `make flake-sweep`). Offline test: hack/ci/flake-sweep-test.sh.
set -uo pipefail

dir=""; count=20; summary=""
while [ $# -gt 0 ]; do
  case "$1" in
    --count) count=${2:?}; shift 2;;
    --summary) summary=${2:?}; shift 2;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) [ -z "$dir" ] || { echo "one module only" >&2; exit 2; }; dir=$1; shift;;
  esac
done
[ -n "$dir" ] && [ -f "$dir/go.mod" ] || { echo "usage: flake-sweep.sh <module-dir> [--count N] [--summary FILE]  (no go.mod in '${dir}')" >&2; exit 2; }
case "$count" in ''|*[!0-9]*|0) echo "--count must be a positive number" >&2; exit 2;; esac
for tool in go jq; do command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }; done

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
(cd "$dir" && go test ./... -race -count="$count" -timeout "${SWEEP_TIMEOUT:-30m}" -json >"$work/out.json" 2>"$work/err.txt"); rc=$?

# One line per failing test: package, test, failed runs. -R and fromjson? skip any line that is not JSON.
failed=$(jq -R -c 'fromjson? | select(.Action == "fail" and .Test != null) | {p: .Package, t: .Test}' "$work/out.json" \
  | jq -s -r --argjson n "$count" 'group_by([.p, .t]) | map({p: .[0].p, t: .[0].t, k: length}) | sort_by(-.k)[] | "| `\(.t)` | `\(.p)` | \(.k) of \($n) |"')
# Packages that failed as a whole (a panic, a data race outside a test, a timeout, a build error).
pkgfail=$(jq -R -r 'fromjson? | select(.Action == "fail" and .Test == null and .Package != null) | .Package' "$work/out.json" | sort -u)

report() {
  echo "### flake sweep: \`$dir\` (-race -count=$count)"
  echo
  if [ -n "$failed" ]; then
    echo "| test | package | failed runs |"
    echo "|---|---|---|"
    echo "$failed"
  elif [ "$rc" -eq 0 ]; then
    echo "no failing test in $count runs"
  else
    echo "go test failed without a failing test (exit $rc): a build error, a timeout, or a panic outside a test. Last lines:"
    echo '```'
    { tail -n 15 "$work/err.txt"; jq -R -r 'fromjson? | select(.Action == "build-output" or .Action == "output") | .Output // empty' "$work/out.json" | grep -v '^\(=== \|--- \|PASS\|ok \)' | tail -n 15; } | cut -c1-300
    echo '```'
  fi
  if [ -n "$pkgfail" ]; then echo; echo "packages that failed: $(echo "$pkgfail" | tr '\n' ' ')"; fi
  echo
}

report | tee -a "${summary:-/dev/null}"
[ "$rc" -eq 0 ] && [ -z "$failed" ] && exit 0
exit 1
