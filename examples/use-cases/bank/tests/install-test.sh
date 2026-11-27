#!/usr/bin/env bash
# Offline test of examples/use-cases/bank/install.sh with a fake kubectl, docker, kind and the two kb scripts. No cluster, no Docker, no network.
# Needs: bash, jq, openssl, shasum or sha256sum. Usage: examples/use-cases/bank/tests/install-test.sh   (exit 1 on any failure)
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

# fake kubectl: every call is logged (arguments only), stdin of apply and create is kept, the state of the namespace and of each Secret
# lives in files. FAKE_CODEMODE=true, FAKE_OTHER_AGENT=1, FAKE_NO_AGENT=1, FAKE_STUB=1, FAKE_SCENARIOS=1 (the chart ConfigMap stub-model-scenarios exists) and FAKE_SECRETS=a|t|both|none set the cluster.
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE_LOG/calls"
case "$*" in
  *"get namespace fernvale-records"*) [ -f "$FAKE_LOG/ns" ] && exit 0 || exit 1 ;;
  *"get namespace mcp-tools"*|*"get namespace openagentix-knowledge"*) exit 0 ;;
  *"get agents.api.kagent.dev dispute-agent"*) [ -z "${FAKE_NO_AGENT:-}" ] && exit 0 || exit 1 ;;
  *"get virtualmcpservers.toolhive.stacklok.dev tools"*) printf %s "${FAKE_CODEMODE:-false}"; exit 0 ;;
  *"get agenttemplates.api.kagent.dev"*)
    others='{"metadata":{"name":"quickstart-template"},"spec":{"tools":[{"mcp":{"server":{"name":"toolhive-vmcp-lookup"}}}]}}'
    [ -z "${FAKE_OTHER_AGENT:-}" ] || others='{"metadata":{"name":"assistant-template"},"spec":{"tools":[{"mcp":{"server":{"name":"toolhive-vmcp"}}}]}}'
    printf '{"items":[{"metadata":{"name":"dispute-agent-template"},"spec":{"tools":[{"mcp":{"server":{"name":"toolhive-vmcp"}}}]}},%s]}' "$others"; exit 0 ;;
  *"get secret records-approvers"*) [ -f "$FAKE_LOG/secret_a" ] && exit 0 || exit 1 ;;
  *"get secret records-approver-token"*) [ -f "$FAKE_LOG/secret_t" ] && exit 0 || exit 1 ;;
  *"get deployment stub-model"*) [ -n "${FAKE_STUB:-}" ] && exit 0 || exit 1 ;;
  *"get configmap stub-model-scenarios"*) case "${FAKE_SCENARIOS:-}" in "") exit 1 ;; wrongkey) echo '{"data":{"other.json":"{}"}}' ;; *) echo '{"data":{"scenario.json":"{}"}}' ;; esac; exit 0 ;;
  *"delete secret"*) rm -f "$FAKE_LOG/secret_a" "$FAKE_LOG/secret_t" ;;
  *"create namespace fernvale-records"*) : > "$FAKE_LOG/ns" ;;
  *"create secret generic records-approvers"*) cat > "$FAKE_LOG/approvers.stdin"; : > "$FAKE_LOG/secret_a" ;;
  *"create secret generic records-approver-token"*) cat > "$FAKE_LOG/token.stdin"; : > "$FAKE_LOG/secret_t" ;;
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
  FAKE_LOG="$LOG" CLUSTER="${CLUSTER-openagentix}" KUBECTL="$BIN/kubectl" DOCKER="$BIN/docker" KIND="$BIN/kind" KB_INGEST="$BIN/kb-ingest" KB_GRAPH_LOAD="$BIN/kb-graph-load" \
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
check "a fresh install does not restart the records pod" "! grep -q 'rollout restart' '$LOG/calls'"
check "the tool registration is applied" "grep -q 'apply -f .*/manifests/tool-registration.yaml' '$LOG/calls'"
check "the desk ServiceAccount is made" "grep -q 'create serviceaccount disputes-desk -n openagentix-system' '$LOG/calls'"
check "the documents go into the collection fernvale-disputes" "grep -q 'kb-ingest .*/seed/kb fernvale-disputes' '$LOG/calls'"
check "the graph facts go into the fact set fernvale-bank" "grep -q 'kb-graph-load fernvale-disputes fernvale-bank .*/seed/graph/dispute-facts.yaml' '$LOG/calls'"
check "the kb scripts get the same kubectl and context" "grep -q 'KUBECTL=$BIN/kubectl' '$LOG/calls'"
check "the script makes no scenario ConfigMap and does not patch the stub model (the chart ships them)" "! grep -q 'bank-scenarios' '$LOG/calls' && ! grep -q 'patch' '$LOG/calls' && ! grep -q 'create configmap' '$LOG/calls'"
check "a stub model without the chart ConfigMap: a warning that names STUB_SCENARIOS and the file, exit 0" "grep -q 'WARN: the stub model has no scenarios' '$LOG/out' && grep -q 'STUB_SCENARIOS=examples/use-cases/bank/eval/scenario.json' '$LOG/out'"
check "the script never reads a Secret" "! grep -q 'get secret .*-o' '$LOG/calls'"
check "the exposure checks are read only (get, no patch or delete before the build)" "awk '/docker build/{exit} /patch|delete|create|apply/{bad=1} END{exit bad}' '$LOG/calls'"

echo "# a second run"
: > "$LOG/calls"; : > "$LOG/applied.yaml"
FAKE_STUB=1 run; rc=$?
check "exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "the approver Secrets are not created again" "! grep -q 'create secret' '$LOG/calls' && ! grep -q 'delete secret' '$LOG/calls'"
check "the output says they exist" "grep -q 'Secrets exist' '$LOG/out'"

echo "# only one Secret exists (an earlier run stopped half way)"
for have in a t; do
  reset; : > "$LOG/ns"; : > "$LOG/secret_$have"
  run; rc=$?
  check "only '$have': exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
  check "only '$have': both Secrets are deleted and made again" "grep -q 'delete secret records-approvers records-approver-token' '$LOG/calls' && [ -f '$LOG/secret_a' ] && [ -f '$LOG/secret_t' ]"
  H=$(sed -n 's/.*"token_sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$LOG/approvers.stdin")
  check "only '$have': the new token matches the new hash" "[ \"\$(printf %s \"\$(cat '$LOG/token.stdin')\" | sha)\" = '$H' ]"
  check "only '$have': the records pod is restarted to read the new file" "grep -q 'rollout restart deployment/records -n fernvale-records' '$LOG/calls'"
done

echo "# the shared tool server must not expose the records tools"
reset
FAKE_CODEMODE=true run; rc=$?
check "code mode on: refused before any change, with the quick start only message" "[ $rc = 1 ] && grep -q 'code mode' '$LOG/out' && grep -q 'quick start only' '$LOG/out' && ! grep -q 'docker build' '$LOG/calls' && ! grep -q 'create ' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_OTHER_AGENT=1 run; rc=$?
check "another agent on the shared tool server: refused, names the agent" "[ $rc = 1 ] && grep -q 'assistant-template' '$LOG/out' && ! grep -q 'docker build' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
run; rc=$?
check "the quick start shape (a profile agent and the dispute agent only) passes" "[ $rc = 0 ]" "exit $rc: $(tail -3 "$LOG/out")"

echo "# options and refusals"
reset
FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "a stub model with the chart scenarios: no warning, one line that says runs are scripted" "[ $rc = 0 ] && ! grep -q WARN '$LOG/out' && grep -q 'scripted by the stub model' '$LOG/out' && ! grep -q 'patch' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_STUB=1 FAKE_SCENARIOS=wrongkey run; rc=$?
check "a chart ConfigMap that does not hold scenario.json: a warning that names the key, exit 0" "[ $rc = 0 ] && grep -q 'WARN: the ConfigMap stub-model-scenarios has no scenario.json' '$LOG/out'" "exit $rc: $(cat "$LOG/out")"
reset
run --no-scenarios; rc=$?
check "--no-scenarios and --scenarios are gone: refused as unknown, with a pointer to STUB_SCENARIOS" "[ $rc = 1 ] && grep -q 'unknown argument: --no-scenarios' '$LOG/out' && grep -q STUB_SCENARIOS '$LOG/out'" "exit $rc: $(cat "$LOG/out")"
reset
run; rc=$?
check "without a stub model nothing is patched" "[ $rc = 0 ] && ! grep -q 'patch deployment' '$LOG/calls' && ! grep -q WARN '$LOG/out' && grep -q 'no stub model in this cluster' '$LOG/out'" "exit $rc"
reset
CLUSTER= KUBE_CONTEXT= run; rc=$?
check "with neither CLUSTER nor KUBE_CONTEXT the script refuses: there is no default cluster" "[ $rc = 1 ] && grep -q 'no default cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
KUBE_CONTEXT=gke_example_project run; rc=$?
check "a context that is not kind is refused before any call" "[ $rc = 1 ] && grep -q 'local kind cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
KUBE_CONTEXT=gke_example_project run --uninstall; rc=$?
check "--uninstall in a context that is not kind is refused before any call" "[ $rc = 1 ] && grep -q 'local kind cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_NO_AGENT=1 run; rc=$?
check "a missing agent stops the script with a pointer to values.yaml" "[ $rc = 1 ] && grep -q 'examples/use-cases/bank/values.yaml' '$LOG/out' && ! grep -q 'docker build' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
run --nonsense; rc=$?
check "an unknown argument is refused" "[ $rc = 1 ]"
reset
SKIP_BUILD=1 RECORDS_IMAGE='x#y&z' run; rc=$?
check "an image name with sed or shell characters is refused" "[ $rc = 1 ] && grep -q 'not allowed in an image reference' '$LOG/out' && ! grep -q 'apply -f -' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"

echo "# uninstall"
reset
FAKE_STUB=1 run --uninstall; rc=$?
check "--uninstall deletes the namespace, the entry and the ServiceAccount" "[ $rc = 0 ] && grep -q 'delete namespace fernvale-records' '$LOG/calls' && grep -q 'delete -f .*tool-registration.yaml' '$LOG/calls' && grep -q 'delete serviceaccount disputes-desk' '$LOG/calls'" "exit $rc"
check "--uninstall does not patch the stub model or touch the chart scenarios" "! grep -q 'patch' '$LOG/calls' && ! grep -q 'stub-model-scenarios' '$LOG/calls' && ! grep -q 'deployment' '$LOG/calls'"
check "--uninstall deletes the ConfigMap bank-scenarios of the earlier script, with --ignore-not-found" "grep -q 'delete configmap bank-scenarios -n agentgateway-system --ignore-not-found' '$LOG/calls'"
reset
run --uninstall; rc=$?
check "--uninstall without a stub model does not patch" "[ $rc = 0 ] && ! grep -q 'patch deployment' '$LOG/calls'"

echo "# the scripts themselves"
check "bash -n" "bash -n '$HERE/install.sh' && bash -n '$HERE/ctl.sh'"
if command -v shellcheck >/dev/null; then check "shellcheck (warning level)" "shellcheck -S warning '$HERE/install.sh' '$HERE/ctl.sh'"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
