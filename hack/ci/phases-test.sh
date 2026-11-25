#!/usr/bin/env bash
# Offline test of hack/ci/phases.sh (issue #35): fixture logs in, the phase table and JSON out.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
[ -x hack/ci/phases.sh ] || { echo "  FAIL hack/ci/phases.sh is missing or not executable"; exit 1; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/install.log" <<'LOG'

=== cluster oa-ci (+0s)
creating cluster

=== prerequisites (+41s)
-> kagent

=== secrets (+130s)

=== helm upgrade --install openagentix (+290s)

=== tool profile vMCP lookup (+350s)

=== waiting for agents (first start builds a golden snapshot, ~1-2 min each) (+360s)

=== quick start agent (+361s)

=== quick start agent Ready (+372s)

=== sample container agent (bring your own agent) (+373s)

=== DONE (+385s)
LOG
printf 'ok    something\nTIMING first_answer_epoch=1000395\nok    other\n' > "$D/smoke.log"

echo "# a full run"
OUT=$(hack/ci/phases.sh --install-log "$D/install.log" --smoke-log "$D/smoke.log" --install-start 1000000 --json "$D/out.json" --title "Quick start on kind")
t "exit 0" "$?" 0
t "the table has a heading with the title" "$(grep -c '^## Quick start on kind' <<<"$OUT")" 1
t "cluster ready is 41 s" "$(jq -r '.phases.cluster_ready_s' "$D/out.json")" 41
t "install done is 360 s (agents wait starts after helm and the tool profile)" "$(jq -r '.phases.install_done_s' "$D/out.json")" 360
t "first agent Ready is 372 s" "$(jq -r '.phases.first_agent_ready_s' "$D/out.json")" 372
t "first answer is 395 s (from the epoch in the smoke log)" "$(jq -r '.phases.first_answer_s' "$D/out.json")" 395
t "install.sh total is 385 s" "$(jq -r '.phases.install_total_s' "$D/out.json")" 385
t "the markdown shows 372 s" "$(grep -c '372' <<<"$OUT")" 1
t "the JSON has a schema field" "$(jq -r '.schema' "$D/out.json")" "openagentix.phases/v1"

echo "# a missing phase is n/a, not a failure"
printf '\n=== cluster x (+0s)\n\n=== prerequisites (+20s)\n' > "$D/short.log"
OUT=$(hack/ci/phases.sh --install-log "$D/short.log" --install-start 1000000 --json "$D/short.json")
t "exit 0 with a short log" "$?" 0
t "cluster ready is kept" "$(jq -r '.phases.cluster_ready_s' "$D/short.json")" 20
t "first agent Ready is null" "$(jq -r '.phases.first_agent_ready_s' "$D/short.json")" null
t "first answer is null without a smoke log" "$(jq -r '.phases.first_answer_s' "$D/short.json")" null
t "the table says n/a" "$([ "$(grep -c 'n/a' <<<"$OUT")" -ge 1 ] && echo yes)" yes

echo "# bad input"
hack/ci/phases.sh --install-start 1 >/dev/null 2>&1; t "no install log: exit 2" "$?" 2
hack/ci/phases.sh --install-log "$D/install.log" >/dev/null 2>&1; t "no start epoch: exit 2" "$?" 2
hack/ci/phases.sh --install-log "$D/nope" --install-start 1 >/dev/null 2>&1; t "missing file: exit 2" "$?" 2
hack/ci/phases.sh --install-log "$D/install.log" --install-start abc >/dev/null 2>&1; t "start epoch not a number: exit 2" "$?" 2
exit $F
