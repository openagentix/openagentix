#!/usr/bin/env bash
# Live test of the runtime's scope for message ids (ADR 0027, "Assumption: the runtime's check is per user id"). Run after the quick start install
# (PROFILE=quickstart ./install.sh), on every change of the pinned kagent version, by the e2e workflow. Needs kubectl (pointing at a kind cluster
# of a hosted runner), curl, jq. It sends to the runtime's own A2A port (svc/kagent-controller in kagent, 8083) through a port-forward, with the stub model:
# no paid call, no gate, no token.
#
# The event gate forwards the caller's message id under the caller's fixed user id and relies on this: the same messageId under TWO user ids is two
# runs, so no other caller can take an event's message id and have the real event answered with someone else's task. This script FAILS when the runtime
# ever answers both user ids with one task, and when a repeat with returnImmediately does not return the same task.
#   1. one messageId, two user ids, different texts, blocking calls: two different tasks (this is the check that fails an upgrade that changes the scope)
#   2. the same user repeating the messageId with another text: the first task comes back (so the gate puts a hash of the text in the id it forwards)
#   3. a repeat with configuration.returnImmediately: the same task again, answered at once
# Prints one line per check; exit 1 if a check failed. It never prints a token (it uses none).
set -uo pipefail
K=${KUBECTL:-kubectl}
# the one guard of the live CI scripts (issue #212): kind or k3d only, a CI run or the named context, never kind-openagentix by hand; it reads the kubeconfig and nothing else
. "$(cd "$(dirname "$0")" && pwd)/lib/require-ci-context.sh"
KUBECTL=$K; export KUBECTL
require_ci_context msgid-scope MSGID_SCOPE_CI_CONTEXT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '      %s\n' "$2" >&2; }

PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
$K port-forward -n kagent svc/kagent-controller "$PORT:8083" >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null && break; sleep 0.2; done
URL="http://127.0.0.1:$PORT/agents/kagent/quickstart"
RUN="scope-$(date +%s)-$$"

# send <user id> <message id> <text> [returnImmediately]: prints "<http status> <task id or ->  <state or ->"
send() {
  local user=$1 mid=$2 text=$3 ri=${4:-} cfg='null'
  [ -z "$ri" ] || cfg='{"returnImmediately":true}'
  local body out
  body=$(jq -nc --arg m "$mid" --arg t "$text" --argjson c "$cfg" \
    '{jsonrpc:"2.0",id:1,method:"SendMessage",params:({message:{messageId:$m,role:"ROLE_USER",parts:[{text:$t}]}} + (if $c==null then {} else {configuration:$c} end))}')
  out=$(curl -sS --max-time 120 -w '\n%{http_code}' -X POST "$URL" -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' -H "X-User-Id: $user" -d "$body" 2>&1) || { echo "000 - -"; return; }
  local code=${out##*$'\n'} resp=${out%$'\n'*}
  echo "$code $(jq -r '[(.result.task.id // .result.id // "-"), (.result.task.status.state // .result.status.state // "-")] | join(" ")' <<<"$resp" 2>/dev/null || echo '- -')"
}

# the agent may need a moment after the install
for _ in $(seq 1 30); do
  r=$(send "$RUN-warm" "$RUN-warm" "scope warm-up"); [ "${r%% *}" = 200 ] && break; sleep 5
done

echo "# 1. one messageId under two user ids"
MID="$RUN-a"
A=$(send "$RUN-user-a" "$MID" "scope check from user a")
B=$(send "$RUN-user-b" "$MID" "scope check from user b")
read -r ca ta _ <<<"$A"; read -r cb tb _ <<<"$B"
echo "      user a: $A"; echo "      user b: $B"
if [ "$ca" = 200 ] && [ "$cb" = 200 ] && [ "$ta" != - ] && [ "$tb" != - ]; then
  if [ "$ta" != "$tb" ]; then ok "the same messageId under two user ids gave two tasks (the check is per user id)"
  else bad "the runtime answered two user ids with ONE task for the same messageId: the per-user scope that ADR 0027 relies on has changed" "task $ta"; fi
else
  bad "both calls must be answered with a task" "user a: $A; user b: $B"
fi

echo "# 2. the same user repeats the messageId with another text"
A2=$(send "$RUN-user-a" "$MID" "scope check from user a, another text")
read -r c2 t2 _ <<<"$A2"; echo "      user a again: $A2"
if [ "$c2" = 200 ] && [ "$t2" = "$ta" ]; then ok "the same user and messageId returned the first task, whatever the text (the gate adds a hash of the text to the id it forwards)"
else bad "a repeat by the same user did not return the first task" "first $ta, repeat $A2"; fi

echo "# 3. a repeat with returnImmediately"
MID3="$RUN-c"
R1=$(send "$RUN-user-a" "$MID3" "scope returnImmediately" 1)
R2=$(send "$RUN-user-a" "$MID3" "scope returnImmediately" 1)
read -r c1 t1 s1 <<<"$R1"; read -r c3 t3 _ <<<"$R2"
echo "      first: $R1"; echo "      repeat: $R2"
if [ "$c1" = 200 ] && [ "$t1" != - ]; then ok "returnImmediately returned a task (state $s1)"; else bad "returnImmediately did not return a task" "$R1"; fi
if [ "$c3" = 200 ] && [ "$t3" = "$t1" ] && [ "$t1" != - ]; then ok "a repeat with returnImmediately returned the same task"
else bad "a repeat with returnImmediately did not return the same task" "first $R1, repeat $R2"; fi

echo; echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
