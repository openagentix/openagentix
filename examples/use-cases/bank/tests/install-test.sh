#!/usr/bin/env bash
# Offline test of examples/use-cases/bank/install.sh with a fake kubectl, helm, docker, kind, platform installer and kb scripts. No cluster, no Docker, no network.
# Needs: bash, jq, yq (the Python wrapper), openssl, shasum or sha256sum. Usage: examples/use-cases/bank/tests/install-test.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
sha() { if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi; }
for t in jq yq openssl; do command -v "$t" >/dev/null || { echo "ERROR: $t is required" >&2; exit 2; }; done

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/log"; mkdir -p "$LOG"

# fake kubectl: every call is logged (arguments only), stdin of apply and create is kept, the state of each namespace and Secret lives in files.
# FAKE_NOCTX=1 (no such kube context), FAKE_NO_AGENT=1, FAKE_CODEMODE=true, FAKE_STUB=1, FAKE_SCENARIOS=1|wrongkey (the chart ConfigMap), FAKE_SECRETS=a|t|m|none
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE_LOG/calls"
case "$*" in
  *"config get-contexts"*) [ -n "${FAKE_NOCTX:-}" ] || echo "kind-oa-bank"; echo "kind-other"; exit 0 ;;
  *"get namespace fernvale-records"*) [ -f "$FAKE_LOG/ns" ] && exit 0 || exit 1 ;;
  *"get namespace mcp-tools"*) [ -f "$FAKE_LOG/ns_mcp" ] && exit 0 || exit 1 ;;
  *"create namespace fernvale-records"*) : > "$FAKE_LOG/ns" ;;
  *"create namespace mcp-tools"*) : > "$FAKE_LOG/ns_mcp" ;;
  *"get namespace openagentix-knowledge"*) exit 0 ;;
  *"get agents.api.kagent.dev dispute-agent"*) [ -z "${FAKE_NO_AGENT:-}" ] && exit 0 || exit 1 ;;
  *"get virtualmcpservers.toolhive.stacklok.dev tools-disputes"*) printf %s "${FAKE_CODEMODE:-false}"; exit 0 ;;
  *"get secret records-approvers "*|*"get secret records-approvers -n"*) [ -f "$FAKE_LOG/secret_a" ] && exit 0 || exit 1 ;;
  *"get secret records-approver-token"*) [ -f "$FAKE_LOG/secret_t" ] && exit 0 || exit 1 ;;
  *"get secret records-mcp-expected"*) [ -f "$FAKE_LOG/secret_e" ] && exit 0 || exit 1 ;;
  *"get secret records-mcp-auth"*) [ -f "$FAKE_LOG/secret_m" ] && exit 0 || exit 1 ;;
  *"get deployment stub-model"*) [ -n "${FAKE_STUB:-}" ] && exit 0 || exit 1 ;;
  *"get configmap stub-model-scenarios"*) case "${FAKE_SCENARIOS:-}" in "") exit 1 ;; wrongkey) echo '{"data":{"other.json":"{}"}}' ;; *) echo '{"data":{"scenario.json":"{}"}}' ;; esac; exit 0 ;;
  *"delete secret"*) rm -f "$FAKE_LOG/secret_a" "$FAKE_LOG/secret_t" "$FAKE_LOG/secret_e" "$FAKE_LOG/secret_m" ;;
  *"create secret generic records-approvers"*) cat > "$FAKE_LOG/approvers.stdin"; : > "$FAKE_LOG/secret_a" ;;
  *"create secret generic records-approver-token"*) cat > "$FAKE_LOG/token.stdin"; : > "$FAKE_LOG/secret_t" ;;
  *"create secret generic records-mcp-expected"*) cat > "$FAKE_LOG/expected.stdin"; : > "$FAKE_LOG/secret_e" ;;
  *"create secret generic records-mcp-auth"*) cat > "$FAKE_LOG/auth.stdin"; : > "$FAKE_LOG/secret_m" ;;
  *"apply -f -"*) cat >> "$FAKE_LOG/applied.yaml" ;;
  *"create "*"--dry-run=client -o yaml"*) echo "kind: Fake" ;;
esac
exit 0
EOF
# fake helm: `get values` answers FAKE_RELEASE (a JSON file name in $FAKE_LOG, or "notfound"); `template` prints a text that FAKE_RENDER_DIFF changes when the -f list is the merged one
cat > "$BIN/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >> "$FAKE_LOG/calls"
case "$1" in
  get) if [ -f "$FAKE_LOG/release.json" ]; then cat "$FAKE_LOG/release.json"; exit 0; fi; echo "Error: release: not found"; exit 1 ;;
  template) if [ -n "${FAKE_RENDER_DIFF:-}" ] && printf '%s' "$*" | grep -q 'your-values.yaml'; then echo "merged: different"; else echo "render: same"; fi; exit 0 ;;
esac
exit 0
EOF
for t in docker kind; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_LOG/calls"\nexit 0\n' "$t" > "$BIN/$t"
done
for t in kb-ingest kb-graph-load; do
  printf '#!/usr/bin/env bash\necho "%s $* KUBECTL=$KUBECTL" >> "$FAKE_LOG/calls"\nexit 0\n' "$t" > "$BIN/$t"
done
# fake platform installer: records the environment it is given and the values file it is given (a copy), and the order of calls
cat > "$BIN/platform-install" <<'EOF'
#!/usr/bin/env bash
echo "platform-install CLUSTER=${CLUSTER:-} KUBE_CONTEXT=${KUBE_CONTEXT:-} PROFILE=${PROFILE:-} STUB_SCENARIOS=${STUB_SCENARIOS:-} ANTHROPIC=${ANTHROPIC_API_KEY:+set} MODEL_NAME=${MODEL_NAME:-}" >> "$FAKE_LOG/calls"
[ -z "${VALUES_FILE:-}" ] || cp "$VALUES_FILE" "$FAKE_LOG/platform-values.yaml"
exit 0
EOF
chmod +x "$BIN"/*

run() { # run <args>... : the script with the fakes; stdout and stderr go to $LOG/out; returns its exit code
  FAKE_LOG="$LOG" CLUSTER="${CLUSTER-oa-bank}" KUBECTL="$BIN/kubectl" HELM="$BIN/helm" DOCKER="$BIN/docker" KIND="$BIN/kind" KB_INGEST="$BIN/kb-ingest" KB_GRAPH_LOAD="$BIN/kb-graph-load" \
    PLATFORM_INSTALL="$BIN/platform-install" PATH="$BIN:$PATH" bash "$HERE/install.sh" "$@" > "$LOG/out" 2>&1
}
reset() { rm -f "$LOG"/*; }
line_of() { /usr/bin/grep -n -m1 -- "$1" "$LOG/calls" | cut -d: -f1; }

echo "# a fresh install on a cluster that exists"
reset
FAKE_STUB=1 ANTHROPIC_API_KEY=should-not-reach-the-installer run; rc=$?
check "exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "every kubectl call names the kind context" "! grep '^kubectl' '$LOG/calls' | grep -v -- '--context kind-oa-bank' | grep -q ."
check "the cluster exists: none is created" "! grep -q '^kind create' '$LOG/calls'"
check "the image is built for the bank domain" "grep -q 'docker build -q --build-arg DOMAIN=bank -t registry.local/oa/records-bank:dev-' '$LOG/calls'"
check "the image is loaded into the named kind cluster" "grep -q 'kind load docker-image registry.local/oa/records-bank:dev-.* --name oa-bank' '$LOG/calls'"
IMG=$(sed -n 's/^docker build -q --build-arg DOMAIN=bank -t \([^ ]*\) .*/\1/p' "$LOG/calls")
check "the manifest is applied with that image and no placeholder" "grep -q 'image: $IMG' '$LOG/applied.yaml' && ! grep -q IMAGE_PLACEHOLDER '$LOG/applied.yaml'"
HASH=$(sed -n 's/.*"token_sha256":"\([0-9a-f]\{64\}\)".*/\1/p' "$LOG/approvers.stdin")
check "the approvers Secret holds one desk lead with a SHA-256, and the stored token hashes to it" "[ -n '$HASH' ] && [ \"\$(printf %s \"\$(cat '$LOG/token.stdin')\" | sha)\" = '$HASH' ]"
TOKEN=$(cat "$LOG/token.stdin")
EXP=$(cat "$LOG/expected.stdin")
check "the credential is the whole header value: Bearer and a token of at least 32 characters" "[[ \"$EXP\" =~ ^Bearer\\ [0-9a-f]{48}$ ]]" "got ${#EXP} characters"
check "the two credential Secrets hold the same value (the one the tool gateway sends and the one the records service expects)" "[ -n '$EXP' ] && [ \"\$(cat '$LOG/auth.stdin')\" = '$EXP' ]"
check "the credential Secret for the tool gateway is made in mcp-tools, the expected value in fernvale-records" "grep -q 'create secret generic records-mcp-auth -n mcp-tools' '$LOG/calls' && grep -q 'create secret generic records-mcp-expected -n fernvale-records' '$LOG/calls'"
check "the Secrets are created from stdin, never from a literal or an argument" "grep -c 'from-file=[a-z.]*=/dev/stdin' '$LOG/calls' | grep -qx 4 && ! grep -q 'from-literal' '$LOG/calls'"
check "no secret value is in any argument list, in the output, or in an applied manifest (the credential, the token, the hash)" "! grep -qF -e '${EXP#Bearer }' -e '$TOKEN' -e '$HASH' '$LOG/calls' '$LOG/out' '$LOG/applied.yaml'"
check "the namespace of the tool gateway is made when absent, before its Secret" "[ \"\$(line_of 'create namespace mcp-tools')\" -lt \"\$(line_of 'create secret generic records-mcp-auth')\" ]"
check "the records service and its Secrets come BEFORE the platform install (the chart renders a policy into the records namespace and needs the header Secret)" "[ \"\$(line_of 'create secret generic records-mcp-auth')\" -lt \"\$(line_of 'platform-install')\" ] && [ \"\$(line_of 'rollout status deployment/records')\" -lt \"\$(line_of 'platform-install')\" ]"
check "the platform installer gets the cluster, the quick start profile and the scenario file" "grep -q 'platform-install CLUSTER=oa-bank KUBE_CONTEXT=kind-oa-bank PROFILE=quickstart STUB_SCENARIOS=.*/examples/use-cases/bank/eval/scenario.json' '$LOG/calls'"
check "no provider key reaches the platform installer (the stub answers: a scripted run, no paid call)" "grep -q 'ANTHROPIC= ' '$LOG/calls'"
check "the composed values have the endpoint, the profile, the agent and the quick start's agent-free list" "yq -e '.mcp.endpoints[0].name == \"records\" and ([.mcp.profiles[].name] | sort == [\"disputes\",\"lookup\"]) and .agents[0].name == \"dispute-agent\"' '$LOG/platform-values.yaml' >/dev/null"
check "the knowledge base documents and the graph facts are loaded AFTER the platform install" "[ \"\$(line_of 'platform-install')\" -lt \"\$(line_of 'kb-ingest')\" ] && grep -q 'kb-ingest .*/seed/kb fernvale-disputes' '$LOG/calls' && grep -q 'kb-graph-load fernvale-disputes fernvale-bank .*/seed/graph/dispute-facts.yaml' '$LOG/calls'"
check "the kb scripts get the same kubectl and context" "grep -q 'KUBECTL=$BIN/kubectl' '$LOG/calls'"
check "the desk ServiceAccount is made" "grep -q 'create serviceaccount disputes-desk -n openagentix-system' '$LOG/calls'"
check "the script makes no MCPServerEntry, no registration and no patch of the stub model (the chart does it)" "! grep -Eq 'patch|mcpserverentry|tool-registration|create configmap' '$LOG/calls' | grep -v delete; ! grep -E 'patch|tool-registration|create configmap' '$LOG/calls' | grep -q ."
check "a stub model with the chart scenarios missing: a warning that names STUB_SCENARIOS" "grep -q 'WARN: the stub model has no scenarios' '$LOG/out'"
check "the script never reads a Secret value" "! grep -q 'get secret .*-o' '$LOG/calls'"
check "the output says what is next" "grep -q 'ctl.sh ask' '$LOG/out'"

echo "# a second run"
: > "$LOG/calls"; : > "$LOG/applied.yaml"
FAKE_STUB=1 run; rc=$?
check "exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "the Secrets are not made again, and nothing is restarted" "! grep -q 'create secret' '$LOG/calls' && ! grep -q 'delete secret' '$LOG/calls' && ! grep -q 'rollout restart' '$LOG/calls'"
check "the output says they exist" "grep -q 'Secrets exist' '$LOG/out'"

echo "# only some of the Secrets exist (an earlier run stopped half way)"
for have in a t e m; do
  reset; : > "$LOG/ns"; : > "$LOG/ns_mcp"; : > "$LOG/secret_$have"
  run; rc=$?
  check "only '$have': exits 0, all four Secrets are made again" "[ $rc = 0 ] && [ -f '$LOG/secret_a' ] && [ -f '$LOG/secret_t' ] && [ -f '$LOG/secret_e' ] && [ -f '$LOG/secret_m' ]" "exit $rc: $(tail -4 "$LOG/out")"
  check "only '$have': the new credential values match, and the new token matches the new hash" "[ \"\$(cat '$LOG/expected.stdin')\" = \"\$(cat '$LOG/auth.stdin')\" ] && [ \"\$(printf %s \"\$(cat '$LOG/token.stdin')\" | sha)\" = \"\$(sed -n 's/.*\"token_sha256\":\"\\([0-9a-f]\\{64\\}\\)\".*/\\1/p' '$LOG/approvers.stdin')\" ]"
  check "only '$have': the records pod is restarted to read the new files, and the tool server of the group after the platform install, to take the new header" "grep -q 'rollout restart deployment/records -n fernvale-records' '$LOG/calls' && grep -q 'rollout restart deployment/tools-disputes -n mcp-tools' '$LOG/calls'"
done

echo "# no default cluster, and only a local kind cluster"
reset
CLUSTER="" KUBE_CONTEXT="" run; rc=$?
check "with neither CLUSTER nor KUBE_CONTEXT the script refuses: there is no default cluster, and it calls nothing" "[ $rc = 1 ] && grep -q 'no default cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
CLUSTER="" KUBE_CONTEXT=kind-oa-bank run; rc=$?
check "KUBE_CONTEXT alone names the cluster" "[ $rc = 0 ] && grep -q 'kind load docker-image .* --name oa-bank' '$LOG/calls'" "exit $rc: $(tail -3 "$LOG/out")"
reset
KUBE_CONTEXT=gke_example_project run; rc=$?
check "a context that is not kind is refused before any call" "[ $rc = 1 ] && grep -q 'local kind cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
KUBE_CONTEXT=gke_example_project run --uninstall; rc=$?
check "--uninstall in a context that is not kind is refused before any call" "[ $rc = 1 ] && grep -q 'local kind cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
run --nonsense; rc=$?
check "an unknown argument is refused" "[ $rc = 1 ] && [ ! -s '$LOG/calls' ]"
reset
run --no-scenarios; rc=$?
check "--no-scenarios and --scenarios are gone: refused as unknown, with a pointer to STUB_SCENARIOS" "[ $rc = 1 ] && grep -q STUB_SCENARIOS '$LOG/out'"
reset
SKIP_BUILD=1 RECORDS_IMAGE='x#y&z' run; rc=$?
check "an image name with sed or shell characters is refused" "[ $rc = 1 ] && grep -q 'not allowed in an image reference' '$LOG/out' && ! grep -q 'apply -f -' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"

echo "# a new cluster is made when none of that name exists"
reset
FAKE_NOCTX=1 run; rc=$?
check "kind creates the cluster with the repository's kind config, before anything else is applied" "[ $rc = 0 ] && grep -q '^kind create cluster --name oa-bank --config .*/hack/kind-config.yaml' '$LOG/calls' && [ \"\$(line_of 'kind create cluster')\" -lt \"\$(line_of 'create namespace fernvale-records')\" ]" "exit $rc: $(tail -3 "$LOG/out")"

echo "# a release with more than the quick start is not replaced"
reset
cat > "$LOG/release.json" <<'JSON'
{"schedules":[{"name":"nightly"}],"bridge":{"enabled":true},"notify":{"enabled":true},"agents":[{"name":"assistant"},{"name":"dispute-agent"}],"mcp":{"profiles":[{"name":"lookup"},{"name":"extra"}]},"governance":{"a2a":{"callers":[{"name":"quickstart-ask"},{"name":"someone"}]}}}
JSON
run; rc=$?
check "refused, naming what would be lost, before any change" "[ $rc = 1 ] && grep -q 'more than the quick start' '$LOG/out' && grep -q 'schedules' '$LOG/out' && grep -q 'agents: assistant' '$LOG/out' && grep -q 'tool profiles: extra' '$LOG/out' && grep -q 'gate callers: someone' '$LOG/out' && grep -q -- '--beside-full-demo' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
cat > "$LOG/release.json" <<'JSON'
{"knowledge":{"enabled":true},"schedules":[{"name":"deadline-sweep"}],"agents":[{"name":"dispute-agent"}],"mcp":{"endpoints":[{"name":"records"}],"profiles":[{"name":"lookup"},{"name":"disputes"}],"servers":[{"name":"osv"}]},"governance":{"a2a":{"callers":[{"name":"quickstart-ask"},{"name":"disputes-desk"}]}}}
JSON
: > "$LOG/calls"
run; rc=$?
check "a release that holds exactly the quick start and this use case is updated" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
echo '{}' > "$LOG/release.json"
run --skip-platform; rc=$?
check "--skip-platform runs no platform installer and does not read the release" "[ $rc = 0 ] && ! grep -q 'platform-install' '$LOG/calls' && ! grep -q '^helm get' '$LOG/calls'" "exit $rc: $(tail -3 "$LOG/out")"

echo "# beside a full demo"
reset
mkdir -p "$TMP/vf"; printf 'agents:\n  - name: assistant\n    model: claude-haiku\nmcp:\n  virtual: {codeMode: {enabled: true}}\n' > "$TMP/vf/one.yaml"; printf 'schedules:\n  - name: nightly\n    agent: assistant\n    schedule: "0 1 * * *"\n    prompt: hi\n' > "$TMP/vf/two.yaml"
echo '{"agents":[{"name":"assistant"}],"schedules":[{"name":"nightly"}]}' > "$LOG/release.json"
VALUES_FILE="$TMP/vf/one.yaml $TMP/vf/two.yaml" ANTHROPIC_API_KEY=keep-me MODEL_NAME=keep-model run --beside-full-demo; rc=$?
check "exits 0 on a release with more than the quick start (no refusal)" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "the values given to the platform installer are your files first, then the bank's: your agent, your schedule and your code mode stay, the dispute agent and the endpoint are added" "yq -e '([.agents[].name] | sort == [\"assistant\",\"dispute-agent\"]) and ([.schedules[].name] | sort == [\"deadline-sweep\",\"nightly\"]) and .mcp.virtual.codeMode.enabled == true and .mcp.endpoints[0].name == \"records\" and (.agents[] | select(.name==\"dispute-agent\") | .model == \"claude-haiku\")' '$LOG/platform-values.yaml' >/dev/null" "$(cat "$LOG/platform-values.yaml" 2>&1 | head -5)"
check "your model, your provider key and no scenario file: nothing is unset or set for the stub" "grep -q 'platform-install .*PROFILE= STUB_SCENARIOS= ANTHROPIC=set MODEL_NAME=keep-model' '$LOG/calls'"
check "no cluster is made, and the quick start profile is not used" "! grep -q '^kind create' '$LOG/calls' && ! grep -q 'PROFILE=quickstart' '$LOG/calls'"
check "the records service is still installed before the platform" "[ \"\$(line_of 'rollout status deployment/records')\" -lt \"\$(line_of 'platform-install')\" ]"
reset
run --beside-full-demo; rc=$?
check "--beside-full-demo without VALUES_FILE is refused: Helm replaces the release values, so the list is needed" "[ $rc = 1 ] && grep -q 'needs VALUES_FILE' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
VALUES_FILE="$TMP/vf/one.yaml" run --beside-full-demo --skip-platform; rc=$?
check "--beside-full-demo with --skip-platform is refused" "[ $rc = 1 ] && [ ! -s '$LOG/calls' ]"
reset
VALUES_FILE="$TMP/vf/missing.yaml" run --beside-full-demo; rc=$?
check "a file of the list that cannot be read is refused before any change" "[ $rc = 1 ] && grep -q 'cannot read' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_RENDER_DIFF=1 VALUES_FILE="$TMP/vf/one.yaml $TMP/vf/two.yaml" run --beside-full-demo; rc=$?
check "when your list does not merge into one file that renders the same, the script stops and changes nothing" "[ $rc = 1 ] && grep -q 'does not merge' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_NOCTX=1 VALUES_FILE="$TMP/vf/one.yaml" run --beside-full-demo; rc=$?
check "beside a full demo needs the cluster to exist: none is made" "[ $rc = 1 ] && ! grep -q '^kind create' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
printf 'agents:\n  - name: dispute-agent\n    model: other\n' > "$TMP/vf/clash.yaml"
VALUES_FILE="$TMP/vf/clash.yaml" run --beside-full-demo; rc=$?
check "an agent of your own with the same name and other content is refused by the composer, nothing installed" "[ $rc = 1 ] && grep -q 'did not compose' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"

echo "# checks on the platform after the install"
reset
FAKE_NO_AGENT=1 run; rc=$?
check "a missing agent stops the script with a pointer to values.yaml" "[ $rc = 1 ] && grep -q 'examples/use-cases/bank/values.yaml' '$LOG/out'" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_CODEMODE=true run; rc=$?
check "code mode on the profile's tool server is refused" "[ $rc = 1 ] && grep -q 'code mode' '$LOG/out'" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "a stub model with the chart scenarios: no warning, one line that says runs are scripted" "[ $rc = 0 ] && ! grep -q WARN '$LOG/out' && grep -q 'scripted by the stub model' '$LOG/out'" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_STUB=1 FAKE_SCENARIOS=wrongkey run; rc=$?
check "a chart ConfigMap that does not hold scenario.json: a warning that names the key, exit 0" "[ $rc = 0 ] && grep -q 'WARN: the ConfigMap stub-model-scenarios has no scenario.json' '$LOG/out'" "exit $rc: $(cat "$LOG/out")"
reset
run; rc=$?
check "without a stub model nothing is patched and no warning is given" "[ $rc = 0 ] && ! grep -q 'patch' '$LOG/calls' && ! grep -q WARN '$LOG/out' && grep -q 'no stub model in this cluster' '$LOG/out'" "exit $rc"

echo "# objects of the earlier script (PR 239) are removed before the chart takes the names"
reset
run; rc=$?
check "the hand-made entry and auth config are deleted by label, never an object the chart made, before the platform install" "grep -q 'delete mcpserverentry records -n mcp-tools -l app.kubernetes.io/part-of=openagentix-use-case-bank --ignore-not-found' '$LOG/calls' && grep -q 'delete mcpexternalauthconfig records-noauth -n mcp-tools -l app.kubernetes.io/part-of=openagentix-use-case-bank --ignore-not-found' '$LOG/calls' && [ \"\$(line_of 'delete mcpserverentry records')\" -lt \"\$(line_of 'platform-install')\" ]"

echo "# uninstall"
reset
FAKE_STUB=1 run --uninstall; rc=$?
check "--uninstall deletes the records namespace, the credential Secret, the desk ServiceAccount and the old objects" "[ $rc = 0 ] && grep -q 'delete namespace fernvale-records' '$LOG/calls' && grep -q 'delete secret records-mcp-auth -n mcp-tools' '$LOG/calls' && grep -q 'delete serviceaccount disputes-desk' '$LOG/calls' && grep -q 'delete configmap bank-scenarios' '$LOG/calls'" "exit $rc"
check "--uninstall runs no platform installer, builds nothing and touches no stub model or chart object" "! grep -qE 'platform-install|docker|patch|stub-model' '$LOG/calls'"

echo "# the scripts themselves"
check "bash -n" "bash -n '$HERE/install.sh' && bash -n '$HERE/ctl.sh'"
if command -v shellcheck >/dev/null; then check "shellcheck (warning level)" "shellcheck -S warning '$HERE/install.sh' '$HERE/ctl.sh'"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
