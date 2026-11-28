#!/usr/bin/env bash
# Offline test of the guards of hack/ci/bank-live.sh (the live check that approves a credit and patches the identity settings of the tool servers):
# it must do nothing without BANK_LIVE=1, refuse a context that is not kind, refuse a kind context outside GitHub Actions unless BANK_CI_CONTEXT names it,
# and never reach a kubectl call that changes anything when it refuses. A fake kubectl records every call. No cluster.
# Usage: examples/use-cases/bank/tests/live-guard-test.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
printf '#!/usr/bin/env bash\necho "kubectl $*" >> "$FAKE_LOG"\ncase "$*" in "config current-context") echo "$FAKE_CTX";; esac\nexit 0\n' > "$TMP/kubectl"
chmod +x "$TMP/kubectl"
run() { : > "$TMP/calls"; env -u GITHUB_ACTIONS -u BANK_CI_CONTEXT -u BANK_LIVE FAKE_LOG="$TMP/calls" KUBECTL="$TMP/kubectl" "$@" bash "$ROOT/hack/ci/bank-live.sh" > "$TMP/out" 2>&1; }

run FAKE_CTX=kind-oa-bank; rc=$?
check "without BANK_LIVE=1 it does nothing, exits 0 and calls nothing" "[ $rc = 0 ] && grep -q 'BANK_LIVE=1' '$TMP/out' && [ ! -s '$TMP/calls' ]" "rc=$rc $(cat "$TMP/out")"
run BANK_LIVE=1 FAKE_CTX=gke_example_project; rc=$?
check "a context that is not kind is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a kind context' '$TMP/out' && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]" "rc=$rc $(cat "$TMP/out")"
run BANK_LIVE=1 FAKE_CTX=kind-openagentix; rc=$?
check "a kind context outside GitHub Actions is refused (exit 2), after reading the context only" "[ $rc = 2 ] && grep -q 'not a CI run' '$TMP/out' && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]" "rc=$rc $(cat "$TMP/out")"
run BANK_LIVE=1 BANK_CI_CONTEXT=kind-other FAKE_CTX=kind-openagentix; rc=$?
check "BANK_CI_CONTEXT naming another context does not allow it" "[ $rc = 2 ] && [ \"\$(wc -l < '$TMP/calls' | tr -d ' ')\" = 1 ]"
check "the script patches the identity settings only after the agent checks, and restores them in the exit trap" "grep -n 'restore_oidc' '$ROOT/hack/ci/bank-live.sh' | head -1 | grep -q . && grep -q '^trap cleanup EXIT' '$ROOT/hack/ci/bank-live.sh'"
L="$ROOT/hack/ci/bank-live.sh"
check "every kubectl call of the script names the context it checked (K carries --context)" "grep -q '^K=\"\$KBASE --context=\$CTX_NOW\"' '$L' && ! grep -nE '^[^#]*(\\\$KBASE|kubectl) ' '$L' | grep -v 'KBASE config current-context' | grep -v '^[0-9]*:K=' | grep -v 'obs \"kubectl' | grep -q ."
check "the leak patterns are never written to a file, and the cleanup removes the token files" "! grep -q '> *\"\$TD/secret' '$L' && grep -q 'rm -f \"\$TD/token\" \"\$TD/tg\" \"\$TD/ts\" \"\$TD/tl\"' '$L'"
check "the leak scan covers previous container logs, both install logs and the script's own log" "grep -q -- '--previous' '$L' && grep -q 'BANK_INSTALL_LOG2' '$L' && grep -q 'BANK_LIVE_LOG' '$L'"
check "the list of tool servers is read once, just before the identity patch, and the restore reuses it (a server that goes missing meanwhile is still restarted)" "[ \"\$(grep -c '^TOOL_SERVERS=\$(tool_servers)' '$L')\" = 1 ] && [ \"\$(grep -c 'for v in \$TOOL_SERVERS' '$L')\" = 4 ] && ! grep -q 'for v in \$(tool_servers)' '$L'"
check "the direct-call section stops when the original identity settings cannot be read, and a failed restore is a failed check with a message" "grep -q 'could not read the identity settings' '$L' && grep -q 'exit 1' '$L' && grep -q 'the identity settings were NOT restored' '$L'"
check "the identity settings are patched and restored for every tool server of the tools namespace, not for a fixed list" "grep -q '^tool_servers()' '$L' && ! grep -qE 'for v in tools \"tools-' '$L'"
check "bash -n and shellcheck" "bash -n '$ROOT/hack/ci/bank-live.sh' && { ! command -v shellcheck >/dev/null || shellcheck -S warning '$ROOT/hack/ci/bank-live.sh'; }"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
