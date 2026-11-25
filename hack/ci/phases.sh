#!/usr/bin/env bash
# Time to first working agent, by phase (issue #35). Reads the log of `./install.sh` (its `=== step (+Ns)` lines count seconds from the start
# of the install) and the log of hack/ci/smoke.sh (one `TIMING first_answer_epoch=<epoch>` line, written when the first answer arrived).
# Prints a Markdown table and, with --json, a small JSON file. A phase it cannot find is n/a (null), never a guess.
#   hack/ci/phases.sh --install-log install.log --install-start <epoch> [--smoke-log smoke.log] [--json out.json] [--title "..."]
# Phases, in seconds from the start of ./install.sh (git clone and tool installs are NOT included):
#   cluster_ready      the cluster exists (the step `prerequisites` starts)
#   install_done       the chart and the tool profile are installed (the step `waiting for agents` starts)
#   first_agent_ready  the quick start AgentDefinition is Ready (the step `quick start agent Ready`)
#   first_answer       the first answer came back through the A2A gate (smoke test, check 2)
#   install_total      the install ended (the step `DONE`)
set -euo pipefail
LOG=""; SMOKE=""; START=""; JSON=""; TITLE="Time to first working agent"
while [ $# -gt 0 ]; do
  case $1 in
    --install-log) LOG=${2:-}; shift 2;;
    --smoke-log) SMOKE=${2:-}; shift 2;;
    --install-start) START=${2:-}; shift 2;;
    --json) JSON=${2:-}; shift 2;;
    --title) TITLE=${2:-}; shift 2;;
    *) echo "phases.sh: unknown argument $1" >&2; exit 2;;
  esac
done
[ -n "$LOG" ] && [ -n "$START" ] || { echo "usage: phases.sh --install-log FILE --install-start EPOCH [--smoke-log FILE] [--json FILE] [--title TEXT]" >&2; exit 2; }
[ -f "$LOG" ] || { echo "phases.sh: no such file: $LOG" >&2; exit 2; }
[ -z "$SMOKE" ] || [ -f "$SMOKE" ] || SMOKE=""
[[ "$START" =~ ^[0-9]+$ ]] || { echo "phases.sh: --install-start must be an epoch in seconds" >&2; exit 2; }

# offset <regex on the step text>: seconds of the first `=== <text> (+Ns)` line whose text matches, or empty
offset() { sed -nE 's/^=== (.*) \(\+([0-9]+)s\)$/\1\t\2/p' "$LOG" | awk -F'\t' -v re="$1" '$1 ~ re {print $2; exit}'; }
CL=$(offset '^prerequisites$'); ID=$(offset '^waiting for agents'); AR=$(offset '^quick start agent Ready$'); TT=$(offset '^DONE$')
FA=""
if [ -n "$SMOKE" ]; then
  E=$(sed -nE 's/^.*TIMING first_answer_epoch=([0-9]+).*$/\1/p' "$SMOKE" | head -1)
  [ -z "$E" ] || FA=$((E - START))
fi

JSONOUT=$(jq -nc --arg cl "$CL" --arg id "$ID" --arg ar "$AR" --arg fa "$FA" --arg tt "$TT" \
  'def n: if . == "" then null else tonumber end;
   {schema:"openagentix.phases/v1",
    phases:{cluster_ready_s:($cl|n), install_done_s:($id|n), first_agent_ready_s:($ar|n), first_answer_s:($fa|n), install_total_s:($tt|n)}}')
[ -z "$JSON" ] || printf '%s\n' "$JSONOUT" > "$JSON"

row() { local v; v=$(jq -r --arg k "$2" '.phases[$k] | if . == null then "n/a" else "\(.)" end' <<<"$JSONOUT"); printf '| %s | %s | %s |\n' "$1" "$v" "$3"; }
printf '## %s\n\n' "$TITLE"
# shellcheck disable=SC2016  # the backticks are Markdown
echo 'Seconds from the start of `./install.sh`. A hosted runner, no model key (stub model). Git clone and tool installs are not included.'
echo
echo '| Phase | Seconds | What it marks |'
echo '|---|---|---|'
row 'cluster ready' cluster_ready_s 'the cluster exists; the prerequisites step starts'
row 'install done' install_done_s 'chart and tool profile installed; the wait for agents starts'
row 'first agent Ready' first_agent_ready_s 'the quickstart AgentDefinition is Ready'
row 'first answer' first_answer_s 'the first answer came back through the A2A gate (smoke test)'
row 'install.sh finished' install_total_s 'the install printed its summary (includes the sample container agent when it is on)'
