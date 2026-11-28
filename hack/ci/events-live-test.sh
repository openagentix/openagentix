#!/usr/bin/env bash
# Offline test of the guards of hack/ci/events-live.sh (the live check of the event sender: it posts cases into the records service of a use case): it must do nothing
# without EVENTS_LIVE=1, refuse wrong arguments, refuse a context that is not kind, refuse a kind context outside GitHub Actions unless EVENTS_CI_CONTEXT names it,
# refuse kind-openagentix (the name of a full demo cluster) outside GitHub Actions, and never reach a kubectl call that changes anything when it refuses. A fake kubectl
# records every call. No cluster. Usage: hack/ci/events-live-test.sh   (exit 1 on any failure)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIVE="$ROOT/hack/ci/events-live.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\necho "kubectl $*" >> "$FAKE_LOG"\ncase "$*" in "config current-context") echo "$FAKE_CTX";; esac\nexit 0\n' > "$TMP/kubectl"
chmod +x "$TMP/kubectl"
run() { : > "$TMP/calls"; env -u GITHUB_ACTIONS -u EVENTS_CI_CONTEXT -u EVENTS_LIVE FAKE_LOG="$TMP/calls" KUBECTL="$TMP/kubectl" "$@" > "$TMP/out" 2>&1; }
one_call() { [ "$(wc -l < "$TMP/calls" | tr -d ' ')" = 1 ]; }

run FAKE_CTX=kind-x bash "$LIVE" equipment off; rc=$?
check "without EVENTS_LIVE=1 it does nothing, exits 0 and calls nothing" "[ $rc = 0 ] && grep -q 'EVENTS_LIVE=1' '$TMP/out' && [ ! -s '$TMP/calls' ]" "rc=$rc $(cat "$TMP/out")"
for args in "" "equipment" "equipment maybe" "zoo on" "equipment on extra-is-ignored-but-first-two-count"; do
  case "$args" in "equipment on extra-is-ignored-but-first-two-count") continue;; esac
  # shellcheck disable=SC2086
  run EVENTS_LIVE=1 FAKE_CTX=kind-x bash "$LIVE" $args; rc=$?
  check "arguments '$args' are refused (exit 2) before any call" "[ $rc = 2 ] && grep -q usage '$TMP/out' && [ ! -s '$TMP/calls' ]" "rc=$rc $(cat "$TMP/out")"
done
run EVENTS_LIVE=1 FAKE_CTX=gke_example_project bash "$LIVE" bank on; rc=$?
check "a context that is not kind is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a kind context' '$TMP/out' && one_call"
run EVENTS_LIVE=1 FAKE_CTX=kind-oa-bank-demo bash "$LIVE" bank on; rc=$?
check "a kind context outside GitHub Actions is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a CI run' '$TMP/out' && one_call"
run EVENTS_LIVE=1 EVENTS_CI_CONTEXT=kind-other FAKE_CTX=kind-oa-bank-demo bash "$LIVE" bank on; rc=$?
check "EVENTS_CI_CONTEXT naming another context does not allow it" "[ $rc = 2 ] && one_call"
run EVENTS_LIVE=1 FAKE_CTX=kind-openagentix bash "$LIVE" equipment off; rc=$?
check "the context kind-openagentix (the full demo cluster) is refused outside GitHub Actions" "[ $rc = 2 ] && grep -q 'full demo' '$TMP/out' && one_call"
run EVENTS_LIVE=1 EVENTS_CI_CONTEXT=kind-openagentix FAKE_CTX=kind-openagentix bash "$LIVE" equipment off; rc=$?
check "EVENTS_CI_CONTEXT cannot allow kind-openagentix" "[ $rc = 2 ] && grep -q 'full demo' '$TMP/out' && one_call"
check "every kubectl call of the script names the context it checked (K carries --context)" "grep -q '^K=\"\$KBASE --context=\$CTX_NOW\"' '$LIVE' && ! grep -nE '^[^#]*(\\\$KBASE|kubectl) ' '$LIVE' | grep -v 'KBASE config current-context' | grep -v '^[0-9]*:K=' | grep -v 'KBASE=' | grep -q ."
check "the port-forwards are stopped in the exit trap, and the trap is set" "grep -q '^trap cleanup EXIT' '$LIVE' && grep -q 'kill \"\$p\"' '$LIVE'"
check "the MCP credential is never written to a file or an argument (it goes to curl through process substitution and is unset)" "! grep -qE '(>|tee) *[^ ]*(HV|secret)' '$LIVE' && grep -q 'unset HV' '$LIVE'"
check "bash -n and shellcheck" "bash -n '$LIVE' && { ! command -v shellcheck >/dev/null || shellcheck -S warning '$LIVE'; }"
check "the e2e workflow runs it off, turns the sender on with EVENTS=1 and --skip-platform, and runs it on, for both use cases" "[ \"\$(grep -c 'hack/ci/events-live.sh equipment off\|hack/ci/events-live.sh equipment on\|hack/ci/events-live.sh bank off\|hack/ci/events-live.sh bank on' '$ROOT/.github/workflows/e2e.yml')\" = 4 ] && [ \"\$(grep -c 'EVENTS: \"1\"' '$ROOT/.github/workflows/e2e.yml')\" = 2 ]"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
