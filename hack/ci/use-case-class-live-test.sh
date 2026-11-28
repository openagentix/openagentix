#!/usr/bin/env bash
# Offline test of the guards of hack/ci/use-case-class-live.sh (the live proof that a use case agent's key is refused at its budget class): it must do nothing
# without USE_CASE_CLASS_LIVE=1, refuse wrong arguments, refuse a context that is not kind, refuse a kind context outside GitHub Actions or when
# USE_CASE_CLASS_CI_CONTEXT does not name it, refuse kind-openagentix, and never reach a kubectl call that changes anything when it refuses. A fake kubectl records every
# call. No cluster. Usage: hack/ci/use-case-class-live-test.sh   (exit 1 on any failure)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIVE="$ROOT/hack/ci/use-case-class-live.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\necho "kubectl $*" >> "$FAKE_LOG"\ncase "$*" in "config current-context") echo "$FAKE_CTX";; esac\nexit 0\n' > "$TMP/kubectl"
chmod +x "$TMP/kubectl"
run() { : > "$TMP/calls"; env -u GITHUB_ACTIONS -u USE_CASE_CLASS_CI_CONTEXT -u USE_CASE_CLASS_LIVE FAKE_LOG="$TMP/calls" KUBECTL="$TMP/kubectl" "$@" > "$TMP/out" 2>&1; }
one_call() { [ "$(wc -l < "$TMP/calls" | tr -d ' ')" = 1 ]; }

run FAKE_CTX=kind-x bash "$LIVE" bank; rc=$?
check "without USE_CASE_CLASS_LIVE=1 it does nothing, exits 0 and calls nothing" "[ $rc = 0 ] && grep -q 'USE_CASE_CLASS_LIVE=1' '$TMP/out' && [ ! -s '$TMP/calls' ]" "rc=$rc $(cat "$TMP/out")"
run USE_CASE_CLASS_LIVE=1 FAKE_CTX=kind-x bash "$LIVE"; rc=$?
check "no argument is refused (exit 2) before any call" "[ $rc = 2 ] && grep -q usage '$TMP/out' && [ ! -s '$TMP/calls' ]" "rc=$rc $(cat "$TMP/out")"
run USE_CASE_CLASS_LIVE=1 FAKE_CTX=kind-x bash "$LIVE" software-org; rc=$?
check "software-org is refused (exit 2) before any call: the proof is for the two case agents" "[ $rc = 2 ] && grep -q usage '$TMP/out' && [ ! -s '$TMP/calls' ]" "rc=$rc $(cat "$TMP/out")"
run USE_CASE_CLASS_LIVE=1 FAKE_CTX=gke_example_project bash "$LIVE" bank; rc=$?
check "a context that is not kind is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a kind context' '$TMP/out' && one_call"
run USE_CASE_CLASS_LIVE=1 FAKE_CTX=kind-oa-bank-demo bash "$LIVE" bank; rc=$?
check "a kind context outside GitHub Actions is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a CI run' '$TMP/out' && one_call"
run USE_CASE_CLASS_LIVE=1 USE_CASE_CLASS_CI_CONTEXT=kind-other FAKE_CTX=kind-oa-bank-demo bash "$LIVE" bank; rc=$?
check "USE_CASE_CLASS_CI_CONTEXT naming another context does not allow it" "[ $rc = 2 ] && one_call"
run USE_CASE_CLASS_LIVE=1 FAKE_CTX=kind-openagentix bash "$LIVE" equipment; rc=$?
check "the context kind-openagentix (the full demo cluster) is refused" "[ $rc = 2 ] && grep -q 'full demo' '$TMP/out' && one_call"
run USE_CASE_CLASS_LIVE=1 USE_CASE_CLASS_CI_CONTEXT=kind-openagentix FAKE_CTX=kind-openagentix bash "$LIVE" equipment; rc=$?
check "USE_CASE_CLASS_CI_CONTEXT cannot allow kind-openagentix" "[ $rc = 2 ] && grep -q 'full demo' '$TMP/out' && one_call"
check "the live policy is restored in the exit trap, and the trap is set" "grep -q '^trap cleanup EXIT' '$LIVE' && grep -q 'restore; rm -rf' '$LIVE'"
check "only the one entry of the class is patched, at an index found from its condition" "grep -q 'apiKey.budget_class == ' '$LIVE' && [ \"\$(grep -c 'patch agentgatewaypolicy' '$LIVE')\" = 2 ]"
check "a key is written only to a private header file, never put on a command line" "grep -q 'chmod 600' '$LIVE' && ! grep -nE 'echo .*(OPENAI_API_KEY|Bearer)' '$LIVE'"
check "the workflow runs it in the bank job with both guard variables" "grep -q 'hack/ci/use-case-class-live.sh bank' '$ROOT/.github/workflows/e2e.yml' && grep -q 'USE_CASE_CLASS_LIVE: \"1\"' '$ROOT/.github/workflows/e2e.yml' && grep -q 'USE_CASE_CLASS_CI_CONTEXT: kind-oa-bank-demo' '$ROOT/.github/workflows/e2e.yml'"
check "bash -n and shellcheck" "bash -n '$LIVE' && { ! command -v shellcheck >/dev/null || shellcheck -S warning '$LIVE'; }"
echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
