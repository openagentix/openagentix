#!/usr/bin/env bash
# Offline test of hack/ci/green-streak.sh (issue #196): fixture run lists in, the streak per workflow out.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
[ -x hack/ci/green-streak.sh ] || { echo "  FAIL hack/ci/green-streak.sh is missing or not executable"; exit 1; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
# Newest first, as `gh run list` prints them. ci: a pull_request run, an in-progress run, a cancelled run and a skipped run do not
# count and do not break the streak; the first failure ends it.
cat > "$D/ci.json" <<'J'
[
 {"databaseId":9,"event":"pull_request","status":"completed","conclusion":"failure","createdAt":"2026-11-26T09:00:00Z","url":"u9"},
 {"databaseId":8,"event":"push","status":"in_progress","conclusion":"","createdAt":"2026-11-26T08:00:00Z","url":"u8"},
 {"databaseId":7,"event":"push","status":"completed","conclusion":"success","createdAt":"2026-11-26T07:00:00Z","url":"u7"},
 {"databaseId":6,"event":"push","status":"completed","conclusion":"cancelled","createdAt":"2026-11-26T06:00:00Z","url":"u6"},
 {"databaseId":5,"event":"push","status":"completed","conclusion":"success","createdAt":"2026-11-26T05:00:00Z","url":"u5"},
 {"databaseId":4,"event":"push","status":"completed","conclusion":"skipped","createdAt":"2026-11-26T04:00:00Z","url":"u4"},
 {"databaseId":3,"event":"push","status":"completed","conclusion":"success","createdAt":"2026-11-26T03:00:00Z","url":"u3"},
 {"databaseId":2,"event":"push","status":"completed","conclusion":"failure","createdAt":"2026-11-26T02:00:00Z","url":"u2"},
 {"databaseId":1,"event":"push","status":"completed","conclusion":"success","createdAt":"2026-11-26T01:00:00Z","url":"u1"}
]
J
# docs: the newest counted run failed, so the streak is 0
cat > "$D/docs.json" <<'J'
[
 {"databaseId":12,"event":"push","status":"completed","conclusion":"failure","createdAt":"2026-11-26T02:00:00Z","url":"u12"},
 {"databaseId":11,"event":"push","status":"completed","conclusion":"success","createdAt":"2026-11-26T01:00:00Z","url":"u11"}
]
J
# e2e: two scheduled runs and one manual run, all green; a timed_out run ends the streak
cat > "$D/e2e.json" <<'J'
[
 {"databaseId":23,"event":"schedule","status":"completed","conclusion":"success","createdAt":"2026-11-28T03:20:00Z","url":"u23"},
 {"databaseId":22,"event":"schedule","status":"completed","conclusion":"success","createdAt":"2026-11-27T03:20:00Z","url":"u22"},
 {"databaseId":21,"event":"workflow_dispatch","status":"completed","conclusion":"success","createdAt":"2026-11-26T03:20:00Z","url":"u21"},
 {"databaseId":20,"event":"schedule","status":"completed","conclusion":"timed_out","createdAt":"2026-11-25T03:20:00Z","url":"u20"}
]
J
echo '[]' > "$D/e2e-k3s.json"

out=$(hack/ci/green-streak.sh --from "$D" --target 3 --json 2>&1); rc=$?
t "exit code 0" "$rc" "0"
q(){ echo "$out" | jq -r "$1"; }
t "ci streak"            "$(q '.[]|select(.workflow=="ci").streak')" "3"
t "ci counted runs"      "$(q '.[]|select(.workflow=="ci").counted')" "5"
t "ci met (target 3)"    "$(q '.[]|select(.workflow=="ci").met')" "true"
t "ci breaker"           "$(q '.[]|select(.workflow=="ci").lastRed')" "u2"
t "docs streak"          "$(q '.[]|select(.workflow=="docs").streak')" "0"
t "docs met"             "$(q '.[]|select(.workflow=="docs").met')" "false"
t "e2e streak"           "$(q '.[]|select(.workflow=="e2e").streak')" "3"
t "e2e schedule runs"    "$(q '.[]|select(.workflow=="e2e").scheduleRuns')" "3"
t "e2e latest schedule"  "$(q '.[]|select(.workflow=="e2e").lastSchedule')" "2026-11-28T03:20:00Z"
t "e2e-k3s empty streak" "$(q '.[]|select(.workflow=="e2e-k3s").streak')" "0"
t "e2e-k3s no schedule"  "$(q '.[]|select(.workflow=="e2e-k3s").lastSchedule')" "null"

txt=$(hack/ci/green-streak.sh --from "$D" --target 3)
case "$txt" in *"3 in a row"*) t "text line has the streak" ok ok;; *) t "text line has the streak" "$txt" "a line with '3 in a row'";; esac
case "$txt" in *"no schedule run"*) t "text warns about missing schedule runs" ok ok;; *) t "text warns about missing schedule runs" "$txt" "no schedule run";; esac

hack/ci/green-streak.sh --from "$D" --target 3 --check >/dev/null 2>&1; t "--check fails when a target is not met" "$?" "1"
hack/ci/green-streak.sh --from "$D" --target 1 --check ci >/dev/null 2>&1; t "--check passes for a met workflow" "$?" "0"
hack/ci/green-streak.sh --bogus >/dev/null 2>&1; t "unknown flag is refused" "$?" "2"
exit $F
