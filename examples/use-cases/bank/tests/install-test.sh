#!/usr/bin/env bash
# Offline test of examples/use-cases/bank/install.sh with a fake kubectl, docker, kind and the two kb scripts. No cluster, no Docker, no network.
# Needs: bash, openssl, shasum or sha256sum. Usage: examples/use-cases/bank/tests/install-test.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
sha() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/log"; mkdir -p "$LOG"

# fake kubectl: every call is logged (arguments only), stdin of apply and create is kept, state of the Secrets lives in files
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE_LOG/calls"
case "$*" in
  *"get namespace fernvale-records"*) [ -f "$FAKE_LOG/ns" ] && exit 0 || exit 1 ;;
  *"get namespace mcp-tools"*|*"get namespace openagentix-knowledge"*) exit 0 ;;
  *"get agents.api.kagent.dev dispute-agent"*) [ -z "${FAKE_NO_AGENT:-}" ] && exit 0 || exit 1 ;;
  *"get secret records-approvers"*) [ -f "$FAKE_LOG/secret" ] && exit 0 || exit 1 ;;
  *"get deployment stub-model"*) [ -n "${FAKE_STUB:-}" ] && exit 0 || exit 1 ;;
  *"create namespace fernvale-records"*) : > "$FAKE_LOG/ns" ;;
  *"create secret generic records-approvers"*) cat > "$FAKE_LOG/approvers.stdin"; : > "$FAKE_LOG/secret" ;;
  *"create secret generic records-approver-token"*) cat > "$FAKE_LOG/token.stdin" ;;
  *"apply -f -"*) cat >> "$FAKE_LOG/applied.yaml" ;;
  *"create "*"--dry-run=client -o yaml"*) echo "kind: Fake" ;;
esac
exit 0
EOF
for t in docker kind; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_LOG/calls"\nexit 0\n' "$t" > "$BIN/$t"
done
for t in kb-ingest kb-graph-load; do
  printf '#!/usr/bin/env bash\necho "%s $* KUBECTL=$KUBECTL" >> "$FAKE_LOG/calls"\nexit 0\n' "$t" > "$BIN/$t"
done
chmod +x "$BIN"/*

run() { # run <args>... : the script with the fakes; stdout and stderr go to $LOG/out; returns its exit code
  FAKE_LOG="$LOG" KUBECTL="$BIN/kubectl" DOCKER="$BIN/docker" KIND="$BIN/kind" KB_INGEST="$BIN/kb-ingest" KB_GRAPH_LOAD="$BIN/kb-graph-load" \
    PATH="$BIN:$PATH" bash "$HERE/install.sh" "$@" > "$LOG/out" 2>&1
}
reset() { rm -f "$LOG"/*; }

echo "# a fresh install"
reset
FAKE_STUB=1 run; rc=$?
check "exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "every kubectl call names the kind context" "! grep -v -- '--context kind-openagentix' '$LOG/calls' | grep -q '^kubectl'"
check "the image is built for the bank domain" "grep -q 'docker build -q --build-arg DOMAIN=bank -t registry.local/oa/records-bank:dev-' '$LOG/calls'"
check "the image is loaded into the named kind cluster" "grep -q 'kind load docker-image registry.local/oa/records-bank:dev-.* --name openagentix' '$LOG/calls'"
IMG=$(sed -n 's/^docker build -q --build-arg DOMAIN=bank -t \([^ ]*\) .*/\1/p' "$LOG/calls")
check "the manifest is applied with that image and no placeholder" "grep -q 'image: $IMG' '$LOG/applied.yaml' && ! grep -q IMAGE_PLACEHOLDER '$LOG/applied.yaml'"
check "the approvers Secret is created" "[ -s '$LOG/approvers.stdin' ]"
HASH=$(sed -n 's/.*"token_sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$LOG/approvers.stdin")
check "it holds one approver with the role desk-lead and a SHA-256" "grep -q '\"role\":\"desk-lead\"' '$LOG/approvers.stdin' && [ -n '$HASH' ]"
check "the stored token hashes to that value" "[ \"\$(printf %s \"\$(cat '$LOG/token.stdin')\" | sha)\" = '$HASH' ]"
TOKEN=$(cat "$LOG/token.stdin")
check "the token has at least 32 characters" "[ \${#TOKEN} -ge 32 ]"
check "the token is not in any argument list" "! grep -q -- '$TOKEN' '$LOG/calls'"
check "the token is not in the output" "! grep -q -- '$TOKEN' '$LOG/out'"
check "the token is not in the applied manifests" "! grep -q -- '$TOKEN' '$LOG/applied.yaml'"
check "the Secrets are created from stdin, not from a file or a literal" "grep -q 'from-file=approvers.json=/dev/stdin' '$LOG/calls' && grep -q 'from-file=token=/dev/stdin' '$LOG/calls' && ! grep -q 'from-literal' '$LOG/calls'"
check "the tool registration is applied" "grep -q 'apply -f .*/manifests/tool-registration.yaml' '$LOG/calls'"
check "the desk ServiceAccount is made" "grep -q 'create serviceaccount disputes-desk -n openagentix-system' '$LOG/calls'"
check "the documents go into the collection fernvale-disputes" "grep -q 'kb-ingest .*/seed/kb fernvale-disputes' '$LOG/calls'"
check "the graph facts go into the fact set fernvale-bank" "grep -q 'kb-graph-load fernvale-disputes fernvale-bank .*/seed/graph/dispute-facts.yaml' '$LOG/calls'"
check "the kb scripts get the same kubectl and context" "grep -q 'KUBECTL=$BIN/kubectl' '$LOG/calls'"
check "the stub model gets the scenario (ConfigMap and patch)" "grep -q 'create configmap bank-scenarios' '$LOG/calls' && grep -q 'patch deployment stub-model' '$LOG/calls'"
check "the patch mounts the file read only and sets STUB_MODEL_SCENARIOS" "grep 'patch deployment stub-model' '$LOG/calls' | grep -q 'STUB_MODEL_SCENARIOS' && grep 'patch deployment stub-model' '$LOG/calls' | grep -q 'readOnly'"
check "the script never reads a Secret" "! grep -q 'get secret .*-o' '$LOG/calls'"

echo "# a second run"
: > "$LOG/calls"; : > "$LOG/applied.yaml"
FAKE_STUB=1 run; rc=$?
check "exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "the approver Secrets are not created again" "! grep -q 'create secret' '$LOG/calls'"
check "the output says they exist" "grep -q 'Secrets exist' '$LOG/out'"

echo "# options and refusals"
reset
run --no-scenarios; rc=$?
check "--no-scenarios: no ConfigMap and no patch" "[ $rc = 0 ] && ! grep -q 'bank-scenarios' '$LOG/calls' && ! grep -q 'patch deployment' '$LOG/calls'"
reset
run; rc=$?
check "without a stub model nothing is patched" "[ $rc = 0 ] && ! grep -q 'patch deployment' '$LOG/calls'" "exit $rc"
reset
KUBE_CONTEXT=gke_example_project run; rc=$?
check "a context that is not kind is refused before any call" "[ $rc = 1 ] && grep -q 'local kind cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_NO_AGENT=1 run; rc=$?
check "a missing agent stops the script with a pointer to values.yaml" "[ $rc = 1 ] && grep -q 'examples/use-cases/bank/values.yaml' '$LOG/out' && ! grep -q 'docker build' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
run --nonsense; rc=$?
check "an unknown argument is refused" "[ $rc = 1 ]"
reset
run --uninstall; rc=$?
check "--uninstall deletes the namespace, the entry and the ServiceAccount" "[ $rc = 0 ] && grep -q 'delete namespace fernvale-records' '$LOG/calls' && grep -q 'delete -f .*tool-registration.yaml' '$LOG/calls' && grep -q 'delete serviceaccount disputes-desk' '$LOG/calls'" "exit $rc"

echo "# the script itself"
check "bash -n" "bash -n '$HERE/install.sh'"
if command -v shellcheck >/dev/null; then check "shellcheck (warning level)" "shellcheck -S warning '$HERE/install.sh' '$HERE/ctl.sh'"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
