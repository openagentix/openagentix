#!/usr/bin/env bash
# Offline test of the guards of hack/ci/equipment-live.sh (the live check that approves an order and patches the identity settings of the tool servers):
# it must do nothing without EQUIPMENT_LIVE=1, refuse a context that is not kind, refuse a kind context outside GitHub Actions unless EQUIPMENT_CI_CONTEXT
# names it, refuse the context kind-openagentix (the name of a full demo cluster) outside GitHub Actions even when EQUIPMENT_CI_CONTEXT names it, and never
# reach a kubectl call that changes anything when it refuses. A fake kubectl records every call. No cluster.
# Usage: examples/use-cases/equipment/tests/live-guard-test.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
LIVE="$ROOT/hack/ci/equipment-live.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\necho "kubectl $*" >> "$FAKE_LOG"\ncase "$*" in "config current-context") echo "$FAKE_CTX";; esac\nexit 0\n' > "$TMP/kubectl"
chmod +x "$TMP/kubectl"
run() { : > "$TMP/calls"; env -u GITHUB_ACTIONS -u EQUIPMENT_CI_CONTEXT -u EQUIPMENT_LIVE FAKE_LOG="$TMP/calls" KUBECTL="$TMP/kubectl" "$@" bash "$LIVE" > "$TMP/out" 2>&1; }

run FAKE_CTX=kind-oa-equipment; rc=$?
check "without EQUIPMENT_LIVE=1 it does nothing, exits 0 and calls nothing" "[ $rc = 0 ] && grep -q 'EQUIPMENT_LIVE=1' '$TMP/out' && [ ! -s '$TMP/calls' ]" "rc=$rc $(cat "$TMP/out")"
run EQUIPMENT_LIVE=1 FAKE_CTX=gke_example_project; rc=$?
check "a context that is not kind is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a kind context' '$TMP/out' && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]" "rc=$rc $(cat "$TMP/out")"
run EQUIPMENT_LIVE=1 FAKE_CTX=kind-oa-equipment-demo; rc=$?
check "a kind context outside GitHub Actions is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a CI run' '$TMP/out' && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]" "rc=$rc $(cat "$TMP/out")"
run EQUIPMENT_LIVE=1 EQUIPMENT_CI_CONTEXT=kind-other FAKE_CTX=kind-oa-equipment-demo; rc=$?
check "EQUIPMENT_CI_CONTEXT naming another context does not allow it" "[ $rc = 2 ] && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]"
run EQUIPMENT_LIVE=1 FAKE_CTX=kind-openagentix; rc=$?
check "the context kind-openagentix (the full demo cluster) is refused outside GitHub Actions, after reading the context only" "[ $rc = 2 ] && grep -q 'full demo' '$TMP/out' && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]" "rc=$rc $(cat "$TMP/out")"
run EQUIPMENT_LIVE=1 EQUIPMENT_CI_CONTEXT=kind-openagentix FAKE_CTX=kind-openagentix; rc=$?
check "EQUIPMENT_CI_CONTEXT cannot allow kind-openagentix: the name is refused outside GitHub Actions whatever the variable says" "[ $rc = 2 ] && grep -q 'full demo' '$TMP/out' && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]" "rc=$rc $(cat "$TMP/out")"
check "the script restores the identity settings in the exit trap, and the trap is set" "grep -n 'restore_oidc' '$LIVE' | head -1 | grep -q . && grep -q '^trap cleanup EXIT' '$LIVE'"
check "bash -n and shellcheck" "bash -n '$LIVE' && { ! command -v shellcheck >/dev/null || shellcheck -S warning '$LIVE'; }"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
