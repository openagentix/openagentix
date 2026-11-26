#!/usr/bin/env bash
# Count the green runs in a row on main, per workflow (issue #196). Used for the release 0.3 exit criterion "30 green runs on main".
#
#   hack/ci/green-streak.sh [options] [workflow ...]
#
#   workflow        ci, docs, e2e, e2e-k3s (default: all four)
#   --repo OWNER/NAME   default: the repository of the current directory (gh decides)
#   --branch NAME       default: main
#   --limit N           runs to read per workflow, newest first (default 100)
#   --target N          streak that meets the criterion (default 30)
#   --json              print JSON instead of text
#   --check             exit 1 when a workflow is below the target
#   --from DIR          read DIR/<workflow>.json (the output of `gh run list --json ...`) instead of calling gh; used by the test
#
# Rules: newest run first; a run counts when it is completed and its conclusion is success (green) or failure, timed_out,
# startup_failure or action_required (red). Cancelled, skipped, neutral and still running runs are ignored: they neither add nor
# break the streak. Pull request runs are ignored (they are not on main). The streak is the number of green runs before the first red one.
# A workflow with a schedule (e2e, e2e-k3s) also prints how many `schedule` runs the window holds and the date of the newest, because
# a nightly that never fires gives no streak at all.
# Needs gh (logged in) and jq. Offline test: hack/ci/green-streak-test.sh.
set -euo pipefail

repo=""; branch="main"; limit=100; target=30; json=0; check=0; from=""; wfs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:?}; shift 2;;
    --branch) branch=${2:?}; shift 2;;
    --limit) limit=${2:?}; shift 2;;
    --target) target=${2:?}; shift 2;;
    --json) json=1; shift;;
    --check) check=1; shift;;
    --from) from=${2:?}; shift 2;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "unknown option $1" >&2; exit 2;;
    *) wfs+=("$1"); shift;;
  esac
done
[ ${#wfs[@]} -gt 0 ] || wfs=(ci docs e2e e2e-k3s)
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

fields=databaseId,event,status,conclusion,createdAt,url
rows=()
for wf in "${wfs[@]}"; do
  if [ -n "$from" ]; then
    runs=$(cat "$from/$wf.json")
  else
    command -v gh >/dev/null || { echo "gh is required" >&2; exit 2; }
    runs=$(gh run list ${repo:+--repo "$repo"} --workflow "$wf.yml" --branch "$branch" --limit "$limit" --json "$fields")
  fi
  row=$(echo "$runs" | jq -c --arg wf "$wf" --argjson target "$target" '
    def green: .conclusion == "success";
    def red: .conclusion | IN("failure", "timed_out", "startup_failure", "action_required");
    [ .[] | select(.event != "pull_request" and .status == "completed" and (green or red)) ] as $c
    | ($c | map(green) | index(false)) as $i
    | ($c | if $i == null then length else $i end) as $streak
    | [ .[] | select(.event == "schedule") ] as $s
    | { workflow: $wf, streak: $streak, target: $target, met: ($streak >= $target), counted: ($c | length),
        lastRed: (if $i == null then null else $c[$i].url end),
        scheduleRuns: ($s | length), lastSchedule: ($s | map(.createdAt) | max) }')
  rows+=("$row")
done
all=$(printf '%s\n' "${rows[@]}" | jq -s -c '.')

if [ "$json" = 1 ]; then
  echo "$all"
else
  echo "$all" | jq -r '.[] | [
      (.workflow | . + (" " * (8 - length))),
      ((.streak | tostring) + " in a row"),
      "(target \(.target), " + (if .met then "met" else "not met" end) + ")",
      "counted \(.counted)",
      (if .lastRed then "last red: " + .lastRed else "no red run in the window" end) ] | join("  ")'
  echo "$all" | jq -r '.[] | select(.workflow | startswith("e2e")) | select(.scheduleRuns == 0)
      | "warning: \(.workflow): no schedule run in the window, the nightly has not fired (see hack/ci/README.md)"'
  echo "$all" | jq -r '.[] | select(.workflow | startswith("e2e")) | select(.scheduleRuns > 0)
      | "\(.workflow): \(.scheduleRuns) schedule run(s), newest \(.lastSchedule)"'
fi

if [ "$check" = 1 ] && echo "$all" | jq -e 'any(.[]; .met | not)' >/dev/null; then exit 1; fi
exit 0
