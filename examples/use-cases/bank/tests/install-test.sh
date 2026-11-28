#!/usr/bin/env bash
# Offline test of examples/use-cases/bank/install.sh with a fake kubectl, helm, docker, kind, platform installer and kb scripts. No cluster, no Docker, no network.
# Needs: bash, jq, yq (the Python wrapper), openssl, shasum or sha256sum. Usage: examples/use-cases/bank/tests/install-test.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
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
  *"get namespace kestrel-records"*) [ -n "${FAKE_NO_COMPANION_NS:-}" ] && exit 1 || exit 0 ;;
  *"get namespace openagentix-knowledge"*) exit 0 ;;
  *"get agents.api.kagent.dev dispute-agent"*) [ -z "${FAKE_NO_AGENT:-}" ] && exit 0 || exit 1 ;;
  *"get virtualmcpservers.toolhive.stacklok.dev tools-disputes"*) printf %s "${FAKE_CODEMODE:-false}"; exit 0 ;;
  *"get secret "*)
    n=$(printf '%s' "$*" | sed -n 's/.*get secret \([a-z-]*\) .*/\1/p')
    if [ -n "${FAKE_SECRET_ERR:-}" ] && [ "$n" = "$FAKE_SECRET_ERR" ]; then echo "Unable to connect to the server: net/http: TLS handshake timeout" >&2; exit 1; fi
    case "$n" in records-approvers) f=secret_a;; records-approver-token) f=secret_t;; records-mcp-expected) f=secret_e;; records-mcp-auth) f=secret_m;; *) f=none;; esac
    if [ -f "$FAKE_LOG/$f" ]; then echo "secret/$n"; exit 0; fi
    echo "Error from server (NotFound): secrets \"$n\" not found" >&2; exit 1 ;;
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
  get) if [ -n "${FAKE_HELM_MULTI:-}" ]; then printf 'WARNING: Kubernetes configuration file is group-readable\nError: release: not found\n' >&2; exit 1; fi
       if [ -n "${FAKE_HELM_ERR:-}" ]; then echo "Error: query: failed to query with labels: secrets is forbidden: the secret list was not found in this namespace" >&2; exit 1; fi
       if [ -f "$FAKE_LOG/release.json" ]; then cat "$FAKE_LOG/release.json"; exit 0; fi; echo "Error: release: not found" >&2; exit 1 ;;
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
if [ -n "${STUB_SCENARIOS:-}" ]; then
  if [ -d "$STUB_SCENARIOS" ]; then ls "$STUB_SCENARIOS" > "$FAKE_LOG/scenario-files"; else basename "$STUB_SCENARIOS" > "$FAKE_LOG/scenario-files"; fi
fi
exit 0
EOF
chmod +x "$BIN"/*

run() { # run <args>... : the script with the fakes; stdout and stderr go to $LOG/out; returns its exit code
  FAKE_LOG="$LOG" CLUSTER="${CLUSTER-oa-bank}" KUBECTL="$BIN/kubectl" HELM="${HELM_OVERRIDE:-$BIN/helm}" DOCKER="$BIN/docker" KIND="$BIN/kind" KB_INGEST="$BIN/kb-ingest" KB_GRAPH_LOAD="$BIN/kb-graph-load" \
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
check "the script never reads a Secret value" "! grep -Eq 'get secret .*-o (json|yaml|jsonpath)' '$LOG/calls'"
check "the output says what is next" "grep -q 'ctl.sh ask' '$LOG/out'"

echo "# a second run"
: > "$LOG/calls"; : > "$LOG/applied.yaml"
FAKE_STUB=1 run; rc=$?
check "exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "the Secrets are not made again, and nothing is restarted" "! grep -q 'create secret' '$LOG/calls' && ! grep -q 'delete secret' '$LOG/calls' && ! grep -q 'rollout restart' '$LOG/calls'"
check "the output says they exist" "grep -q 'Secrets exist' '$LOG/out'"

echo "# the event sender (EVENTS, ADR 0027): off by default, on with EVENTS=1, the same on a second run"
reset
FAKE_STUB=1 run; rc=$?
check "EVENTS unset: exits 0 and the manifest has no event setting, no gate token and no marker line" "[ $rc = 0 ] && ! grep -q -e RECORDS_EVENT -e gate-token -e openagentix-a2a -e 'EVENTS-' '$LOG/applied.yaml'" "exit $rc"
check "EVENTS unset: the pod still makes no connection (egress is the empty list) and runs as the ServiceAccount records, as before" "grep -q '^  egress: \[\]' '$LOG/applied.yaml' && grep -q 'serviceAccountName: records$' '$LOG/applied.yaml' && grep -q 'automountServiceAccountToken: false' '$LOG/applied.yaml'"
check "EVENTS unset: the platform values are what they were before the sender existed: no event caller, no namespace admitted to the gate" "yq -e '(.governance.a2a.callers | map(.name) | index(\"fernvale-case-events\")) == null and (.networkPolicy.extraA2ACallers == null)' '$LOG/platform-values.yaml' >/dev/null"
check "EVENTS unset: the ServiceAccount of the pod is records (as before), and the account of the other form, records-events, is deleted after the rollout" "grep -q 'name: records$' '$LOG/applied.yaml' && grep -q 'serviceAccountName: records$' '$LOG/applied.yaml' && ! grep -q 'records-events' '$LOG/applied.yaml' && grep -q 'delete serviceaccount records-events -n fernvale-records' '$LOG/calls' && ! grep -q 'delete serviceaccount records -n' '$LOG/calls'"
check "EVENTS unset: the output does not say the sender is on" "! grep -q 'event sender is ON' '$LOG/out'"
cp "$LOG/applied.yaml" "$TMP/applied-off.yaml"
reset
EVENTS=1 FAKE_STUB=1 run; rc=$?
check "EVENTS=1: exits 0 and says the sender is on" "[ $rc = 0 ] && grep -q 'event sender is ON' '$LOG/out'" "exit $rc: $(tail -4 "$LOG/out")"
check "EVENTS=1: the platform values add the event caller fernvale-case-events and the namespace fernvale-records for the gate (values-events.yaml), and nothing else of the platform values changes" "yq -e '(.governance.a2a.callers | map(.name) | index(\"fernvale-case-events\")) != null and (.networkPolicy.extraA2ACallers == [{\"namespace\":\"fernvale-records\",\"podLabels\":{\"app\":\"records\"}}])' '$LOG/platform-values.yaml' >/dev/null"
check "EVENTS=1: the ServiceAccount is records-events, and the account records of the other form is deleted after the rollout" "grep -q 'name: records-events' '$LOG/applied.yaml' && grep -q 'serviceAccountName: records-events' '$LOG/applied.yaml' && grep -q 'delete serviceaccount records -n fernvale-records' '$LOG/calls' && ! grep -q 'delete serviceaccount records-events' '$LOG/calls'"
check "EVENTS=1: the manifest is valid YAML and has no marker line" "yq -e . '$LOG/applied.yaml' >/dev/null && ! grep -q 'EVENTS-' '$LOG/applied.yaml'"
check "EVENTS=1: the service gets the gate URL of its agent and the token file, and nothing else about events" "grep -q 'RECORDS_EVENT_GATE_URL, value: \"http://a2a-gate.openagentix-gateway.svc.cluster.local:8080/agents/kagent/dispute-agent\"' '$LOG/applied.yaml' && grep -q 'RECORDS_EVENT_TOKEN_FILE, value: /var/run/records-events/token' '$LOG/applied.yaml' && [ \"\$(grep -c RECORDS_EVENT '$LOG/applied.yaml')\" = 2 ]"
check "EVENTS=1: the token is projected for the gate's audience, lives 600 seconds, and is mounted read only" "grep -q 'serviceAccountToken: {audience: openagentix-a2a, expirationSeconds: 600, path: token}' '$LOG/applied.yaml' && grep -q 'name: gate-token, mountPath: /var/run/records-events, readOnly: true' '$LOG/applied.yaml'"
check "EVENTS=1: the pod may reach DNS and the gate on 8080 and nothing else" "yq -c 'select(.spec.policyTypes != null) | ((.spec.egress | length) == 2 and (.spec.egress[0].to[0].podSelector.matchLabels[\"k8s-app\"] == \"kube-dns\") and (.spec.egress[1].to[0].namespaceSelector.matchLabels[\"kubernetes.io/metadata.name\"] == \"openagentix-gateway\") and (.spec.egress[1].to[0].podSelector.matchLabels.app == \"a2a-gate\") and (.spec.egress[1].ports | length == 1) and (.spec.egress[1].ports[0].port == 8080) and (.spec.ingress | length == 0))' '$LOG/applied.yaml' | grep -qx true"
check "EVENTS=1: no Kubernetes API token is mounted, and the manifest has no Role, ClusterRole or binding" "grep -q 'automountServiceAccountToken: false' '$LOG/applied.yaml' && [ \"\$(yq -r '.kind' '$LOG/applied.yaml' | grep -c -e Role -e Binding)\" = 0 ]"
check "EVENTS=1: no secret value is in the output or the manifest" "! grep -qi -e 'bearer ' '$LOG/out'"
cp "$LOG/applied.yaml" "$TMP/applied-on.yaml"
: > "$LOG/calls"; : > "$LOG/applied.yaml"
EVENTS=1 FAKE_STUB=1 run; rc=$?
check "EVENTS=1 again: exits 0, the same manifest, no Secret made again and nothing restarted" "[ $rc = 0 ] && cmp -s '$LOG/applied.yaml' '$TMP/applied-on.yaml' && ! grep -q 'create secret' '$LOG/calls' && ! grep -q 'rollout restart' '$LOG/calls'"
: > "$LOG/calls"; : > "$LOG/applied.yaml"
FAKE_STUB=1 run; rc=$?
check "EVENTS back to unset: the manifest is the one without the sender (a run turns it off again)" "[ $rc = 0 ] && cmp -s '$LOG/applied.yaml' '$TMP/applied-off.yaml'"
echo "# switching the sender off again: the release holds the event caller, and that removal is intended (only that)"
bash "$ROOT/hack/compose-values.sh" "$ROOT/components/quickstart/values.yaml" "$HERE/values.yaml" "$HERE/values-events.yaml" 2>/dev/null | yq . > "$TMP/expected-on.json"
jq '. * {"controlPlane":{"apiServerCIDRs":["172.18.0.0/24"],"sourceHash":"abc"},"knowledge":{"kb":{"sourceHash":"def","image":{"tag":"dev-1"}}},"gateway":{"stubModel":{"sourceHash":"x","scenarios":{"files":{"scenario.json":"fernvale dispute desk agent"}}}},"notify":{"requireReady":false}}' "$TMP/expected-on.json" > "$TMP/release-on.json"
reset; cp "$TMP/release-on.json" "$LOG/release.json"
FAKE_STUB=1 run; rc=$?
check "a release that holds this use case's event caller and namespace, with EVENTS unset: updated, with no ALLOW_VALUE_REMOVAL (the removal is intended)" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls' && ! grep -q 'more than the quick start' '$LOG/out'" "exit $rc: $(tail -4 "$LOG/out")"
check "and the platform installer gets values without the event entries" "yq -e '(.governance.a2a.callers | map(.name) | index(\"fernvale-case-events\")) == null and .networkPolicy.extraA2ACallers == null' '$LOG/platform-values.yaml' >/dev/null"
reset; jq '.networkPolicy.extraA2ACallers += [{"namespace":"somewhere-else","podLabels":{"app":"x"}}]' "$TMP/release-on.json" > "$LOG/release.json"
FAKE_STUB=1 run; rc=$?
check "the same release with ANOTHER namespace in extraA2ACallers: refused (only this use case's own entries may go), before any change" "[ $rc = 1 ] && grep -q 'more than the quick start' '$LOG/out' && grep -q 'extraA2ACallers' '$LOG/out' && ! grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(tail -4 "$LOG/out")"
reset; jq '.governance.a2a.callers += [{"name":"another-caller","serviceAccount":{"namespace":"x","name":"y"},"agents":["a"],"userId":{"exact":"z"}}]' "$TMP/release-on.json" > "$LOG/release.json"
FAKE_STUB=1 run; rc=$?
check "the same release with ANOTHER caller rule: refused, naming it" "[ $rc = 1 ] && grep -q 'another-caller' '$LOG/out' && ! grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(tail -4 "$LOG/out")"
reset; cp "$TMP/release-on.json" "$LOG/release.json"
EVENTS=1 FAKE_STUB=1 run; rc=$?
check "with EVENTS=1 the same release is simply updated (nothing is lost)" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(tail -4 "$LOG/out")"
echo "# beside the other use case with its sender on: its event caller and its namespace for the gate are in the release, so they are composed again (nothing of it is lost)"
reset
OTHER_UC="$ROOT/examples/use-cases/equipment"
bash "$ROOT/hack/compose-values.sh" "$ROOT/components/quickstart/values.yaml" "$OTHER_UC/values.yaml" "$OTHER_UC/values-events.yaml" 2>/dev/null | yq . > "$TMP/other-on.json"
jq '. * {"controlPlane":{"apiServerCIDRs":["172.18.0.0/24"],"sourceHash":"abc"},"gateway":{"stubModel":{"sourceHash":"x","scenarios":{"files":{"equipment.json":"Kestrel Valley service desk agent"}}}}}' "$TMP/other-on.json" > "$LOG/release.json"
FAKE_BANK=1 FAKE_STUB=1 run; rc=$?
check "the release holds the other use case with its sender on: exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "its event caller kestrel-fault-events and its namespace kestrel-records are in the values given to the platform installer, and this use case's own are not (EVENTS unset)" "yq -e '(.governance.a2a.callers | map(.name) | index(\"kestrel-fault-events\")) != null and (.governance.a2a.callers | map(.name) | index(\"fernvale-case-events\")) == null and (.networkPolicy.extraA2ACallers | map(.namespace)) == [\"kestrel-records\"]' '$LOG/platform-values.yaml' >/dev/null"
reset; cp "$TMP/other-on.json" "$LOG/release.json"; jq '. * {"controlPlane":{"apiServerCIDRs":["172.18.0.0/24"],"sourceHash":"abc"},"gateway":{"stubModel":{"sourceHash":"x","scenarios":{"files":{"equipment.json":"Kestrel Valley service desk agent"}}}}}' "$TMP/other-on.json" > "$LOG/release.json"
EVENTS=1 FAKE_BANK=1 FAKE_STUB=1 run; rc=$?
check "with EVENTS=1 beside it: both event callers and both namespaces are composed" "[ $rc = 0 ] && yq -e '(.networkPolicy.extraA2ACallers | map(.namespace) | sort) == [\"fernvale-records\",\"kestrel-records\"] and (.governance.a2a.callers | map(.name) | index(\"fernvale-case-events\")) != null and (.governance.a2a.callers | map(.name) | index(\"kestrel-fault-events\")) != null' '$LOG/platform-values.yaml' >/dev/null" "exit $rc: $(tail -5 "$LOG/out")"

for bad in 2 yes true ''; do
  [ -n "$bad" ] || continue
  reset
  EVENTS=$bad run; rc=$?
  check "EVENTS=$bad is refused before anything is changed" "[ $rc = 1 ] && grep -q 'EVENTS must be 0 or 1' '$LOG/out' && ! grep -q 'apply' '$LOG/calls' && ! grep -q 'create' '$LOG/calls'" "exit $rc: $(tail -3 "$LOG/out")"
done

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
CLUSTER=oa-bank KUBE_CONTEXT=kind-other run; rc=$?
check "CLUSTER and KUBE_CONTEXT that disagree are refused before any call" "[ $rc = 1 ] && grep -q 'different clusters' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
CLUSTER=oa-bank KUBE_CONTEXT=kind-oa-bank run; rc=$?
check "CLUSTER and KUBE_CONTEXT that agree are accepted" "[ $rc = 0 ]" "exit $rc: $(tail -3 "$LOG/out")"
reset
CLUSTER="" KUBE_CONTEXT=gke_example_project run; rc=$?
check "a context that is not kind is refused before any call" "[ $rc = 1 ] && grep -q 'local kind cluster' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
CLUSTER="" KUBE_CONTEXT=gke_example_project run --uninstall; rc=$?
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

echo "# the name of the full demo cluster is never reached by a default run"
reset
CLUSTER=openagentix run; rc=$?
check "the cluster openagentix (the full demo cluster) is refused without --beside-full-demo, before any call" "[ $rc = 1 ] && grep -q 'full demo' '$LOG/out' && grep -q -- '--beside-full-demo' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
CLUSTER="" KUBE_CONTEXT=kind-openagentix run; rc=$?
check "the same by KUBE_CONTEXT" "[ $rc = 1 ] && grep -q 'full demo' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
CLUSTER=openagentix run --uninstall; rc=$?
check "--uninstall and --skip-platform on that cluster are refused too" "[ $rc = 1 ] && grep -q 'full demo' '$LOG/out' && [ ! -s '$LOG/calls' ]"
reset
CLUSTER=openagentix run --skip-platform; rc=$?
check "--skip-platform on that cluster is refused" "[ $rc = 1 ] && grep -q 'full demo' '$LOG/out' && [ ! -s '$LOG/calls' ]"

echo "# a new cluster is made when none of that name exists"
reset
FAKE_NOCTX=1 run; rc=$?
check "kind creates the cluster with the repository's kind config, before anything else is applied" "[ $rc = 0 ] && grep -q '^kind create cluster --name oa-bank --config .*/hack/kind-config.yaml' '$LOG/calls' && [ \"\$(line_of 'kind create cluster')\" -lt \"\$(line_of 'create namespace fernvale-records')\" ]" "exit $rc: $(tail -3 "$LOG/out")"

echo "# a release with more than the quick start and this use case is not replaced (an allowlist of key paths)"
reset
echo '{"customThing":{"enabled":true},"agents":[{"name":"assistant"},{"name":"dispute-agent"}],"mcp":{"profiles":[{"name":"lookup"},{"name":"extra"}]},"observability":{"bundled":{"enabled":true,"extra":1}}}' > "$LOG/release.json"
run; rc=$?
check "refused, naming the paths and entries that would be lost, before any change" "[ $rc = 1 ] && grep -q 'more than the quick start' '$LOG/out' && grep -q '.customThing.enabled' '$LOG/out' && grep -q '.agents\[assistant\]' '$LOG/out' && grep -q '.mcp.profiles\[extra\]' '$LOG/out' && grep -q '.observability.bundled.extra' '$LOG/out' && grep -q -- '--beside-full-demo' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
echo '{"observability":{"enabled":true,"bundled":{"enabled":true}},"console":{"enabled":true,"theme":"x"}}' > "$LOG/release.json"
run; rc=$?
check "a small custom release (a key the quick start does not set) is refused too: the old list of full demo keys did not see it" "[ $rc = 1 ] && grep -q '.console.theme' '$LOG/out' && ! grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
# a release that is exactly the composed values plus what the platform installer sets itself
bash "$ROOT/hack/compose-values.sh" "$ROOT/components/quickstart/values.yaml" "$HERE/values.yaml" 2>/dev/null | yq . > "$TMP/expected.json"
jq '. * {"controlPlane":{"apiServerCIDRs":["172.18.0.0/24"],"sourceHash":"abc"},"knowledge":{"kb":{"sourceHash":"def","image":{"tag":"dev-1"}}},"gateway":{"stubModel":{"sourceHash":"x","scenarios":{"files":{"scenario.json":"{\"scenarios\":[{\"match\":{\"system\":\"(?i)fernvale dispute desk agent\"}}]}"}}}},"notify":{"requireReady":false}}' "$TMP/expected.json" > "$TMP/release-ok.json"
reset; cp "$TMP/release-ok.json" "$LOG/release.json"; : > "$LOG/calls"
run; rc=$?
check "a release that holds exactly the composed values plus what the platform installer sets itself is updated" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
echo '{}' > "$LOG/release.json"
run --skip-platform; rc=$?
check "--skip-platform runs no platform installer and does not read the release" "[ $rc = 0 ] && ! grep -q 'platform-install' '$LOG/calls' && ! grep -q '^helm get' '$LOG/calls'" "exit $rc: $(tail -3 "$LOG/out")"
reset
HELM_OVERRIDE=/nonexistent/helm run; rc=$?
check "a missing helm stops the install (it is not read as: no release), before any change" "[ $rc = 1 ] && grep -q 'helm is required' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
FAKE_HELM_ERR=1 run; rc=$?
check "a helm failure that only contains the words not found is not read as: no release, the install stops before any change" "[ $rc = 1 ] && grep -q 'cannot read the values of the release' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"

echo "# the equipment use case is installed beside this one (it is composed, not refused or dropped)"
reset
RT="$(cd "$HERE/../../.." && pwd)"
bash "$RT/hack/compose-values.sh" "$RT/components/quickstart/values.yaml" "$HERE/values.yaml" "$RT/examples/use-cases/equipment/values.yaml" 2>/dev/null | yq . > "$TMP/expected-both.json"
jq '. * {"controlPlane":{"apiServerCIDRs":["172.18.0.0/24"],"sourceHash":"abc"},"gateway":{"stubModel":{"sourceHash":"x","scenarios":{"files":{"scenario.json":"fernvale dispute desk agent","equipment.json":"Kestrel Valley service desk agent"}}}}}' "$TMP/expected-both.json" > "$LOG/release.json"
run; rc=$?
check "a release that holds the bank and the equipment use case is updated with both: no refusal, both agents, both scenario files" "[ $rc = 0 ] && yq -e '([.agents[].name] | sort == [\"dispute-agent\",\"service-agent\"]) and ([.mcp.endpoints[].name] | sort == [\"dealer-records\",\"records\"])' '$LOG/platform-values.yaml' >/dev/null && [ \"\$(tr '\n' ' ' < '$LOG/scenario-files')\" = 'equipment.json scenario.json ' ]" "exit $rc: $(tail -4 "$LOG/out")"
reset
cp "$TMP/release-ok.json" "$LOG/release.json" 2>/dev/null; jq '. * {"mcp":{"endpoints":[{"name":"records"},{"name":"dealer-records"}]}}' "$LOG/release.json" > "$LOG/release2.json" && mv "$LOG/release2.json" "$LOG/release.json"
FAKE_NO_COMPANION_NS=1 run; rc=$?
check "the equipment endpoint in the release but no namespace kestrel-records: refused before any change, with a pointer to the equipment install" "[ $rc = 1 ] && grep -q 'kestrel-records' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
check "the same refusal says how to get out: take the equipment use case out of the release by running the platform installer again without its values, and points at the README" "grep -q 'or take it out of the release' '$LOG/out' && grep -q 'Uninstall one of two use cases' '$LOG/out' && grep -q 'PROFILE=quickstart VALUES_FILE=' '$LOG/out'"
reset
cp "$TMP/release-ok.json" "$LOG/release.json" 2>/dev/null
run; rc=$?
check "without the equipment use case in the release the scenario stays the single file scenario.json" "[ $rc = 0 ] && [ \"\$(cat '$LOG/scenario-files')\" = 'scenario.json' ]" "exit $rc: $(tail -3 "$LOG/out")"

echo "# a Secret read that fails is not a Secret that is absent"
reset; : > "$LOG/ns"; : > "$LOG/ns_mcp"; : > "$LOG/secret_a"; : > "$LOG/secret_t"; : > "$LOG/secret_e"; : > "$LOG/secret_m"
FAKE_SECRET_ERR=records-mcp-expected run; rc=$?
check "an API error on one of the four Secrets stops the install: nothing is deleted, made again or restarted, and the platform is not touched" "[ $rc = 1 ] && grep -q 'cannot read the Secret records-mcp-expected' '$LOG/out' && ! grep -qE 'delete secret|create secret|rollout restart|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
check "the four Secrets are still there" "[ -f '$LOG/secret_a' ] && [ -f '$LOG/secret_t' ] && [ -f '$LOG/secret_e' ] && [ -f '$LOG/secret_m' ]"

echo "# the guard: what the installer sets is ignored, nothing else (a narrow list)"
reset
jq '. * {"controlPlane":{"apiServerCIDRs":["172.18.0.0/24"],"sourceHash":"a"},"knowledge":{"kb":{"image":{"tag":"dev-1"}}},"notify":{"image":{"tag":"dev-2"}},"governance":{"a2a":{"image":{"tag":"dev-3"}}},"scheduling":{"image":{"tag":"dev-4"}}}' "$TMP/expected.json" > "$LOG/release.json"
run; rc=$?
check "the image tag of a platform component and the API server addresses (anchored paths) are ignored: the release is updated" "[ $rc = 0 ]" "exit $rc: $(cat "$LOG/out" | head -5)"
reset
jq '. * {"mycomponent":{"image":{"repository":"example/x"}},"knowledge":{"kb":{"image":{"repository":"example/y"}}},"controlPlane":{"apiServerCIDRsExtra":["1.2.3.4/32"]}}' "$TMP/expected.json" > "$LOG/release.json"
run; rc=$?
check "an image repository, and a key that only starts like an ignored one, are not ignored: refused and named" "[ $rc = 1 ] && grep -q '.mycomponent.image.repository' '$LOG/out' && grep -q '.knowledge.kb.image.repository' '$LOG/out' && grep -q 'apiServerCIDRsExtra' '$LOG/out' && ! grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out" | head -8)"
reset
jq '. * {"skills":{"openagentix-canary":{"oci":"r/x@sha256:1","extra":true}}}' "$TMP/expected.json" > "$LOG/release.json"
run; rc=$?
check "only the skill reference the installer sets is ignored, not the rest of that block" "[ $rc = 1 ] && grep -q 'skills.openagentix-canary.extra' '$LOG/out' && ! grep -q 'skills.openagentix-canary.oci' '$LOG/out'" "exit $rc: $(cat "$LOG/out" | head -8)"
reset
jq '. * {"gateway":{"stubModel":{"scenarios":{"files":{"scenario.json":"{\"scenarios\":[{\"match\":{\"system\":\"Brambleworks pod agent\"}}]}","other-case.json":"{}"}}}}}' "$TMP/expected.json" > "$LOG/release.json"
run; rc=$?
check "scenario files of another use case are not replaced silently: a scenario.json that is not this one, and any other file, are refused and named" "[ $rc = 1 ] && grep -q 'scenarios.files.scenario.json' '$LOG/out' && grep -q 'scenarios.files.other-case.json' '$LOG/out' && ! grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out" | head -8)"
reset
jq '. * {"gateway":{"stubModel":{"scenarios":{"files":{"scenario.json":"{\"scenarios\":[{\"match\":{\"system\":\"(?i)fernvale dispute desk agent\"}}]}"}}}}}' "$TMP/expected.json" > "$LOG/release.json"
run; rc=$?
check "the scenario file of this use case (an earlier run of this script) is replaced without complaint" "[ $rc = 0 ]" "exit $rc: $(cat "$LOG/out" | head -5)"
reset; echo '{"customThing":{"enabled":true}}' > "$LOG/release.json"
FAKE_HELM_MULTI=1 run; rc=$?
check "helm's exact line 'Error: release: not found' counts as no release when it is not the first line of stderr" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out" | head -5)"

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
echo '{"agents":[{"name":"assistant"}],"schedules":[{"name":"nightly"}],"memory":{"enabled":true}}' > "$LOG/release.json"
VALUES_FILE="$TMP/vf/one.yaml $TMP/vf/two.yaml" run --beside-full-demo; rc=$?
check "beside a full demo: a key of the release that your VALUES_FILE list lacks (a file left out) is refused and named, before any change" "[ $rc = 1 ] && grep -q '.memory.enabled' '$LOG/out' && grep -q 'same list of files' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
# a second --beside-full-demo run: the release is the composed values (your list plus values-full-demo.yaml) and what the installer sets
jq -s 'reduce .[] as $x ({}; . * $x)' <(yq . "$TMP/vf/one.yaml") <(yq . "$TMP/vf/two.yaml") > "$TMP/yours.json"
bash "$ROOT/hack/compose-values.sh" "$TMP/yours.json" "$HERE/values-full-demo.yaml" 2>/dev/null | yq . > "$TMP/beside-composed.json"
jq '. * {"controlPlane":{"apiServerCIDRs":["172.18.0.0/24"],"sourceHash":"abc"},"notify":{"image":{"tag":"dev-2"}},"governance":{"a2a":{"image":{"tag":"dev-3"}}},"scheduling":{"image":{"tag":"dev-4"}}}' "$TMP/beside-composed.json" > "$TMP/beside-release.json"
reset; cp "$TMP/beside-release.json" "$LOG/release.json"
VALUES_FILE="$TMP/vf/one.yaml $TMP/vf/two.yaml" run --beside-full-demo; rc=$?
check "a SECOND --beside-full-demo run is not refused: the bank's own entries from the first run are in the composed values it compares with" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out" | head -6)"
reset; jq '. * {"memory":{"enabled":true}}' "$TMP/beside-release.json" > "$LOG/release.json"
VALUES_FILE="$TMP/vf/one.yaml $TMP/vf/two.yaml" run --beside-full-demo; rc=$?
check "and a file left out of VALUES_FILE is still refused and named on the second run" "[ $rc = 1 ] && grep -q '.memory.enabled' '$LOG/out' && ! grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out" | head -6)"
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

echo "# two use cases beside a full demo: ALSO_COMPOSE lists the other use case's values-full-demo.yaml"
reset
RT="$(cd "$HERE/../../.." && pwd)"
OTHER_FD="$RT/examples/use-cases/equipment/values-full-demo.yaml"
mkdir -p "$TMP/af"; printf 'agents:\n  - name: assistant\n    model: claude-haiku\nmcp:\n  virtual: {codeMode: {enabled: true}}\n' > "$TMP/af/one.yaml"; printf 'schedules:\n  - name: nightly\n    agent: assistant\n    schedule: "0 1 * * *"\n    prompt: hi\n' > "$TMP/af/two.yaml"
{ yq . "$TMP/af/one.yaml"; yq . "$TMP/af/two.yaml"; } | jq -s 'reduce .[] as $x ({}; . * $x)' > "$TMP/af/user.json"
bash "$RT/hack/compose-values.sh" -o "$TMP/af/release.yaml" "$TMP/af/user.json" "$OTHER_FD" 2>/dev/null
yq . "$TMP/af/release.yaml" > "$TMP/af/release.json"
cp "$TMP/af/release.json" "$LOG/release.json"
VALUES_FILE="$TMP/af/one.yaml $TMP/af/two.yaml" run --beside-full-demo; rc=$?
check "a full demo release that also holds the other use case is refused without ALSO_COMPOSE, naming what would be lost and telling to add its values-full-demo.yaml to ALSO_COMPOSE, before any change" "[ $rc = 1 ] && grep -q 'service-agent' '$LOG/out' && grep -q 'add its values-full-demo.yaml to ALSO_COMPOSE' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset; cp "$TMP/af/release.json" "$LOG/release.json"
ALSO_COMPOSE="$OTHER_FD" VALUES_FILE="$TMP/af/one.yaml $TMP/af/two.yaml" ANTHROPIC_API_KEY=keep-me run --beside-full-demo; rc=$?
check "with ALSO_COMPOSE the install passes" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(tail -4 "$LOG/out")"
check "the composed values keep every entry of the full demo list and of the other use case, and add this one: agents, schedules, endpoints, profiles, callers, code mode" "yq -e '([.agents[].name] | sort == [\"assistant\",\"dispute-agent\",\"service-agent\"]) and ([.schedules[].name] | sort == [\"deadline-sweep\",\"fleet-sweep\",\"nightly\"]) and ([.mcp.endpoints[].name] | sort == [\"dealer-records\",\"records\"]) and ([.mcp.profiles[].name] | sort == [\"dealer\",\"disputes\"]) and ([.governance.a2a.callers[].name] | sort == [\"disputes-desk\",\"service-desk\"]) and .mcp.virtual.codeMode.enabled == true' '$LOG/platform-values.yaml' >/dev/null" "$(yq -c '[.agents[].name, .schedules[].name, .mcp.endpoints[].name]' "$LOG/platform-values.yaml" 2>&1)"
check "the other use case's entry is composed before this one's: the other agent comes first in the agents list, then this one" "[ \"\$(yq -r '[.agents[].name] | index(\"service-agent\") < index(\"dispute-agent\")' '$LOG/platform-values.yaml')\" = true ]"
check "your provider key stays and no scenario file is set" "grep -q 'platform-install .*PROFILE= STUB_SCENARIOS= ANTHROPIC=set' '$LOG/calls'"
yq . "$LOG/platform-values.yaml" > "$TMP/af/release2.json"
reset; cp "$TMP/af/release2.json" "$LOG/release.json"
ALSO_COMPOSE="$OTHER_FD" VALUES_FILE="$TMP/af/one.yaml $TMP/af/two.yaml" run --beside-full-demo; rc=$?
check "a second run on the release it made passes" "[ $rc = 0 ] && grep -q 'platform-install' '$LOG/calls'" "exit $rc: $(tail -4 "$LOG/out")"
reset
ALSO_COMPOSE="$OTHER_FD" VALUES_FILE="$TMP/af/one.yaml" run; rc=$?
check "ALSO_COMPOSE without --beside-full-demo is refused before any call" "[ $rc = 1 ] && grep -q 'ALSO_COMPOSE' '$LOG/out' && [ ! -s '$LOG/calls' ]" "exit $rc: $(cat "$LOG/out")"
reset
ALSO_COMPOSE="$TMP/af/missing.yaml" VALUES_FILE="$TMP/af/one.yaml" run --beside-full-demo; rc=$?
check "an ALSO_COMPOSE file that cannot be read is refused before any change" "[ $rc = 1 ] && grep -q 'cannot read' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
mkdir -p "$TMP/af/c"; printf 'agents:\n  - name: dispute-agent\n    model: other\n' > "$TMP/af/c/values-full-demo.yaml"
ALSO_COMPOSE="$TMP/af/c/values-full-demo.yaml" VALUES_FILE="$TMP/af/one.yaml" run --beside-full-demo; rc=$?
check "a name that clashes between the composed files (same agent name, other content) is refused by the composer, nothing installed" "[ $rc = 1 ] && grep -q 'did not compose' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"

reset
ALSO_COMPOSE="$RT/examples/use-cases/equipment/values.yaml" VALUES_FILE="$TMP/af/one.yaml" run --beside-full-demo; rc=$?
check "an ALSO_COMPOSE file that is not named values-full-demo.yaml (the use case's own values.yaml would replace lists of the full demo) is refused before any change" "[ $rc = 1 ] && grep -q 'values-full-demo.yaml and values-events.yaml files of other use cases' '$LOG/out' && ! grep -qE 'docker|create |apply|platform-install' '$LOG/calls'" "exit $rc: $(cat "$LOG/out")"
reset
mkdir -p "$TMP/af/x"; cp "$RT/examples/use-cases/equipment/values-full-demo.yaml" "$TMP/af/x/values-full-demo.yaml"
ALSO_COMPOSE="$TMP/af/x/values-full-demo.yaml" VALUES_FILE="$TMP/af/one.yaml $TMP/af/two.yaml" run --beside-full-demo; rc=$?
check "a file with that name, wherever it is, is accepted" "[ $rc = 0 ]" "exit $rc: $(tail -3 "$LOG/out")"

reset; cp "$TMP/af/release.json" "$LOG/release.json"
bash "$RT/hack/compose-values.sh" -o "$TMP/af/release-ev.yaml" "$TMP/af/user.json" "$OTHER_FD" "$RT/examples/use-cases/equipment/values-events.yaml" 2>/dev/null && yq . "$TMP/af/release-ev.yaml" > "$LOG/release.json"
ALSO_COMPOSE="$OTHER_FD $RT/examples/use-cases/equipment/values-events.yaml" VALUES_FILE="$TMP/af/one.yaml $TMP/af/two.yaml" run --beside-full-demo; rc=$?
check "ALSO_COMPOSE may list the other use case's values-events.yaml: its event caller and namespace are kept, and this use case's own are not added (EVENTS unset)" "[ $rc = 0 ] && yq -e '(.governance.a2a.callers | map(.name) | index(\"kestrel-fault-events\")) != null and (.governance.a2a.callers | map(.name) | index(\"fernvale-case-events\")) == null and (.networkPolicy.extraA2ACallers | map(.namespace)) == [\"kestrel-records\"]' '$LOG/platform-values.yaml' >/dev/null" "exit $rc: $(tail -5 "$LOG/out")"
reset; cp "$TMP/af/release.json" "$LOG/release.json"
EVENTS=1 ALSO_COMPOSE="$OTHER_FD" VALUES_FILE="$TMP/af/one.yaml $TMP/af/two.yaml" run --beside-full-demo; rc=$?
check "EVENTS=1 beside a full demo: this use case's values-events.yaml is composed after its values-full-demo.yaml" "[ $rc = 0 ] && yq -e '(.governance.a2a.callers | map(.name) | index(\"fernvale-case-events\")) != null and (.networkPolicy.extraA2ACallers | map(.namespace)) == [\"fernvale-records\"]' '$LOG/platform-values.yaml' >/dev/null" "exit $rc: $(tail -5 "$LOG/out")"
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
