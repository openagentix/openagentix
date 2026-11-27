#!/usr/bin/env bash
# Offline test of examples/use-cases/software-org/install.sh and ctl.sh with a fake kubectl and a fake platform installer. No cluster, no Docker,
# no network. Needs: bash, jq, yq (the Python wrapper, for compose-values.sh). Usage: examples/use-cases/software-org/tests/install-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# the test sets the model variables itself where it needs them; whatever is in the caller's environment must not count
unset ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY MODEL_BASE_URL MODEL_NAME MODEL_PROVIDER MODEL_API_KEY STUB_SCENARIOS
BIN="$TMP/bin"; mkdir -p "$BIN"
LOG="$TMP/log"; mkdir -p "$LOG"

# fake kubectl: every call is logged (arguments only); stdin of apply is kept.
# FAKE_CODEMODE=true, FAKE_NO_AGENT=1, FAKE_NO_DIAG=1, FAKE_NO_VMCP=1, FAKE_STUB=1, FAKE_SCENARIOS=1 set the cluster.
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE_LOG/calls"
case "$*" in
  "config get-contexts -o name") printf '%s\n' "${FAKE_CONTEXTS-kind-oa-rca-demo}"; exit 0 ;;
  *"get namespace mcp-tools"*) exit 0 ;;
  *"get agents.api.kagent.dev pod-rca"*) [ -z "${FAKE_NO_AGENT:-}" ] && exit 0 || exit 1 ;;
  *"get deployment cluster-read"*) [ -z "${FAKE_NO_DIAG:-}" ] && exit 0 || exit 1 ;;
  *"get virtualmcpservers.toolhive.stacklok.dev tools-rca"*)
    [ -z "${FAKE_NO_VMCP:-}" ] || exit 1
    case "$*" in *jsonpath*) printf %s "${FAKE_CODEMODE:-false}" ;; esac; exit 0 ;;
  *"get deployment stub-model"*) [ -n "${FAKE_STUB:-}" ] && exit 0 || exit 1 ;;
  *"get configmap stub-model-scenarios"*) [ -n "${FAKE_SCENARIOS:-}" ] && { echo '{"data":{"scenario.json":"{}"}}'; exit 0; } || exit 1 ;;
  *"apply"*"-f -"*) cat >> "$FAKE_LOG/applied.yaml" ;;
  *"create serviceaccount"*"--dry-run=client -o yaml"*) echo "kind: ServiceAccount" ;;
esac
exit 0
EOF
# fake platform installer: records the environment it was given (names of the variables that matter, never a value of a key) and the composed values
cat > "$BIN/platform-install" <<'EOF'
#!/usr/bin/env bash
{
  echo "PROFILE=${PROFILE-<unset>}"
  echo "VALUES_FILE=${VALUES_FILE-<unset>}"
  echo "STUB_SCENARIOS=${STUB_SCENARIOS-<unset>}"
  echo "KUBE_CONTEXT=${KUBE_CONTEXT-<unset>}"
  echo "CLUSTER=${CLUSTER-<unset>}"
  for v in ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY MODEL_BASE_URL MODEL_NAME MODEL_PROVIDER MODEL_API_KEY; do
    if [ -n "${!v+x}" ]; then echo "HAS $v"; fi
  done
} > "$FAKE_LOG/platform.env"
[ -f "${VALUES_FILE:-/nonexistent}" ] && cp "$VALUES_FILE" "$FAKE_LOG/platform.values"
echo called >> "$FAKE_LOG/platform.calls"
exit "${FAKE_PLATFORM_RC:-0}"
EOF
# fake helm: `get values` answers FAKE_HELM_VALUES (JSON), or the error FAKE_HELM_ERR; `template` prints a fixed text (FAKE_HELM_DIFF=1: another text when it is given the merged file)
cat > "$BIN/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >> "$FAKE_LOG/calls"
case "$1" in
  get) if [ -n "${FAKE_HELM_ERR:-}" ]; then echo "$FAKE_HELM_ERR" >&2; exit 1; fi; v=${FAKE_HELM_VALUES:-}; [ -n "$v" ] || v='{}'; printf '%s' "$v"; exit 0 ;;
  template) if [ -n "${FAKE_HELM_DIFF:-}" ] && printf '%s' "$*" | grep -q 'your-values.yaml'; then echo "merged: different"; else echo "rendered: same"; fi; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN"/*

run() { # run <args>... : install.sh with the fakes; stdout and stderr go to $LOG/out
  FAKE_LOG="$LOG" KUBECTL="$BIN/kubectl" HELM="$BIN/helm" PLATFORM_INSTALL="$BIN/platform-install" PATH="$BIN:$PATH" bash "$HERE/install.sh" "$@" > "$LOG/out" 2>&1
}
reset() { rm -f "$LOG"/*; }
nocalls() { [ ! -s "$LOG/platform.calls" ] && ! grep -q 'apply\|delete\|create' "$LOG/calls" 2>/dev/null; }
SECRET_KEY="sk-test-this-is-a-fake-key-0123456789"

echo "# the context guard"
reset
KUBE_CONTEXT=gke_proj_zone_prod run; rc=$?
check "a context that is not kind or k3d is refused (exit 1) before anything runs" "[ $rc = 1 ] && grep -q 'local kind or k3d' '$LOG/out' && [ ! -e '$LOG/calls' ] && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
KUBE_CONTEXT=gke_proj_zone_prod run --uninstall; rc=$?
check "the guard also refuses --uninstall" "[ $rc = 1 ] && [ ! -e '$LOG/calls' ]" "rc=$rc"
reset
KUBE_CONTEXT=k3d-demo FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "a k3d context is accepted" "[ $rc = 0 ]" "rc=$rc $(tail -3 "$LOG/out")"

echo "# a fresh offline install"
reset
ANTHROPIC_API_KEY=$SECRET_KEY OPENAI_API_KEY=$SECRET_KEY FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "exits 0" "[ $rc = 0 ]" "exit $rc: $(tail -5 "$LOG/out")"
check "the platform installer ran once, with PROFILE=quickstart" "[ \"\$(wc -l < '$LOG/platform.calls' | tr -d ' ')\" = 1 ] && grep -qx 'PROFILE=quickstart' '$LOG/platform.env'"
check "it got STUB_SCENARIOS=eval/scenario.json (the file of this use case)" "grep -qx \"STUB_SCENARIOS=$HERE/eval/scenario.json\" '$LOG/platform.env'"
check "no provider key reached the platform installer (the stub answers, so the scenarios apply)" "! grep -q '^HAS ' '$LOG/platform.env'"
check "the key value is not in the output" "! grep -q '$SECRET_KEY' '$LOG/out' '$LOG/calls'"
check "the values file it got is the composed file: it holds the agent, the profile, the quick start caller and the new caller" "grep -q 'pod-rca' '$LOG/platform.values' && grep -q 'name: rca' '$LOG/platform.values' && grep -q 'quickstart-ask' '$LOG/platform.values' && grep -q 'rca-desk' '$LOG/platform.values' && grep -q 'lookup' '$LOG/platform.values'"
check "the composed values keep the quick start caller once" "[ \"\$(grep -c '^      - name: quickstart-ask' '$LOG/platform.values')\" = 1 ]"
check "the manifests of rca-demo were applied (server side, with a field manager)" "grep -q 'apply --server-side --force-conflicts --field-manager=openagentix-software-org -f $HERE/manifests/rca-demo.yaml' '$LOG/calls'"
check "every kubectl call names the context" "! grep '^kubectl' '$LOG/calls' | grep -v 'config get-contexts' | grep -qv -- '--context kind-oa-rca-demo'"
check "the platform installer is given the same context and cluster name" "grep -qx 'KUBE_CONTEXT=kind-oa-rca-demo' '$LOG/platform.env' && grep -qx 'CLUSTER=oa-rca-demo' '$LOG/platform.env'"
check "the ServiceAccount rca-desk is made in openagentix-system" "grep -q 'create serviceaccount rca-desk -n openagentix-system' '$LOG/calls'"
check "it says the stub model has the scenarios, and that runs are scripted" "grep -q 'scripted' '$LOG/out' && grep -q 'scenarios from the chart' '$LOG/out'"
check "it checks the tool server of the profile rca and refuses code mode" "grep -q 'tools-rca' '$LOG/calls'"
check "nothing but the use case namespace, the caller and reads are written: no delete, no patch, no secret" "! grep -Eq ' (delete|patch|replace) |create secret|apply -f .*secret' '$LOG/calls'"

echo "# the real model flag"
reset
run --real-model; rc=$?
check "--real-model without a key is refused and nothing runs" "[ $rc = 1 ] && grep -q 'needs a model' '$LOG/out' && nocalls"
reset
ANTHROPIC_API_KEY=$SECRET_KEY STUB_SCENARIOS=/tmp/leftover.json run --real-model; rc=$?
check "--real-model with a key: exits 0, sets no scenarios (even when the caller had STUB_SCENARIOS) and keeps the key for the platform installer" "[ $rc = 0 ] && grep -qx 'STUB_SCENARIOS=<unset>' '$LOG/platform.env' && grep -qx 'HAS ANTHROPIC_API_KEY' '$LOG/platform.env'" "rc=$rc $(cat "$LOG/platform.env" 2>/dev/null)"
check "--real-model does not look for the stub model's scenarios" "! grep -q 'stub-model-scenarios' '$LOG/calls'"
check "the key value is not in the output (real model run)" "! grep -q '$SECRET_KEY' '$LOG/out' '$LOG/calls'"

echo "# --skip-platform and the platform checks"
reset
FAKE_STUB=1 FAKE_SCENARIOS=1 run --skip-platform; rc=$?
check "--skip-platform does not run the platform installer, and still applies the use case" "[ $rc = 0 ] && [ ! -e '$LOG/platform.calls' ] && grep -q 'rca-demo.yaml' '$LOG/calls'" "rc=$rc"
reset
FAKE_NO_AGENT=1 run --skip-platform; rc=$?
check "no agent pod-rca: refused, nothing applied" "[ $rc = 1 ] && grep -q 'pod-rca does not exist' '$LOG/out' && ! grep -q 'apply' '$LOG/calls'"
reset
FAKE_NO_DIAG=1 run --skip-platform; rc=$?
check "no cluster-read: refused, nothing applied" "[ $rc = 1 ] && grep -q 'cluster-read is not installed' '$LOG/out' && ! grep -q 'apply' '$LOG/calls'"
reset
FAKE_NO_VMCP=1 run --skip-platform; rc=$?
check "no tool server for the profile rca: refused" "[ $rc = 1 ] && grep -q 'tools-rca' '$LOG/out' && ! grep -q 'apply' '$LOG/calls'"
reset
FAKE_CODEMODE=true run --skip-platform; rc=$?
check "code mode on the tool server of the profile: refused, nothing applied" "[ $rc = 1 ] && grep -q 'code mode' '$LOG/out' && ! grep -q 'apply' '$LOG/calls'"
reset
FAKE_PLATFORM_RC=1 run; rc=$?
check "a failed platform install stops the script before the use case objects" "[ $rc != 0 ] && ! grep -q 'rca-demo.yaml' '$LOG/calls'"
reset
FAKE_STUB=1 run --skip-platform; rc=$?
check "a stub model without the scenarios gives a warning, not a failure" "[ $rc = 0 ] && grep -q 'WARN: the stub model has no scenario.json' '$LOG/out'"

echo "# runs again, uninstall, unknown argument"
reset
FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc1=$?
cp "$LOG/applied.yaml" "$TMP/first.applied" 2>/dev/null
FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc2=$?
check "a second run gives no error and applies the same objects (the apply is declarative)" "[ $rc1 = 0 ] && [ $rc2 = 0 ] && [ \"\$(grep -c 'rca-demo.yaml' '$LOG/calls')\" = 2 ]"
reset
run --uninstall; rc=$?
check "--uninstall deletes the manifests and the caller, and nothing else" "[ $rc = 0 ] && grep -q 'delete -f $HERE/manifests/rca-demo.yaml --ignore-not-found' '$LOG/calls' && grep -q 'delete serviceaccount rca-desk -n openagentix-system --ignore-not-found' '$LOG/calls' && [ \"\$(grep -c 'delete' '$LOG/calls')\" = 2 ] && [ ! -e '$LOG/platform.calls' ]"
reset
run --nope; rc=$?
check "an unknown argument is refused" "[ $rc = 1 ] && grep -q 'unknown argument' '$LOG/out'"


echo "# the default cluster is a cluster of its own, and a release with more than the quick start is never replaced"
reset
FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "with no CLUSTER and no KUBE_CONTEXT the target is kind-oa-rca-demo, not kind-openagentix (the name of a full demo cluster)" "[ $rc = 0 ] && grep -q -- '--context kind-oa-rca-demo' '$LOG/calls' && ! grep -q 'kind-openagentix' '$LOG/calls' && grep -qx 'CLUSTER=oa-rca-demo' '$LOG/platform.env'"
check "the script says in its header that the default is a cluster of its own" "grep -q 'default oa-rca-demo' '$HERE/install.sh'"
reset
FAKE_CONTEXTS="" FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "a cluster that does not exist yet is fine (the platform installer makes it; nothing can be lost): helm is not asked" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ] && ! grep -q '^helm get' '$LOG/calls'"
reset
FAKE_HELM_ERR="Error: release: not found" FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "a cluster with no release is fine" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]"
reset
FAKE_HELM_VALUES='{"agents":[{"name":"pod-rca"}],"mcp":{"profiles":[{"name":"lookup"},{"name":"rca"}],"servers":[{"name":"osv"}]},"governance":{"a2a":{"callers":[{"name":"quickstart-ask"},{"name":"rca-desk"}]}},"bridge":{"enabled":false},"knowledge":{"enabled":false}}' FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "an earlier run of this use case (the quick start, this agent, nothing more) is replaced as before" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]"
reset
FAKE_HELM_ERR="Error: Kubernetes cluster unreachable: connection refused" run; rc=$?
check "a release that cannot be read is refused, and the platform installer does not run" "[ $rc = 1 ] && grep -q 'cannot read the values' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
while IFS='|' read -r what json; do
  reset
  FAKE_HELM_VALUES="$json" run; rc=$?
  check "a release with $what is refused with that word, nothing is installed, nothing is applied" "[ $rc = 1 ] && grep -q 'has more than the quick start' '$LOG/out' && grep -q -i -e '$what' '$LOG/out' && [ ! -e '$LOG/platform.calls' ] && ! grep -q 'apply' '$LOG/calls'" "rc=$rc $(tail -2 "$LOG/out")"
done <<'LIST'
schedules|{"schedules":[{"name":"demo-brief"}]}
the Telegram bridge|{"bridge":{"enabled":true}}
channels|{"channels":{"kourier":{"enabled":true}}}
notify|{"notify":{"enabled":true}}
the knowledge base|{"knowledge":{"enabled":true}}
memory|{"memory":{"enabled":true}}
agents: assistant|{"agents":[{"name":"assistant"},{"name":"pod-rca"}]}
tool profiles: db|{"mcp":{"profiles":[{"name":"lookup"},{"name":"db"}]}}
tool servers: fetch|{"mcp":{"servers":[{"name":"osv"},{"name":"fetch"}]}}
gate callers: bridge|{"governance":{"a2a":{"callers":[{"name":"bridge"}]}}}
code mode|{"mcp":{"virtual":{"codeMode":{"enabled":true}}}}
LIST
reset
FAKE_HELM_VALUES='{"schedules":[{"name":"x"}]}' run --real-model --skip-platform; rc=$?
check "--skip-platform does not run the platform installer, so it does not need the check" "[ $rc != 1 ] || ! grep -q 'has more than' '$LOG/out'"

echo "# --beside-full-demo"
FDLIST="components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml components/observability/demo-values.yaml components/knowledge/graph-demo-values.yaml components/governance/demo-values.yaml components/governance/profiles-demo-values.yaml components/governance/memory-demo-values.yaml components/control-plane/demo-values.yaml components/console/demo-values.yaml"
reset
FAKE_HELM_VALUES='{"schedules":[{"name":"demo-brief"}],"bridge":{"enabled":true}}' CLUSTER=openagentix ANTHROPIC_API_KEY=$SECRET_KEY STUB_SCENARIOS=/tmp/mine.json VALUES_FILE="$FDLIST" FAKE_STUB=1 FAKE_SCENARIOS=1 run --beside-full-demo; rc=$?
check "beside the full demo: exits 0, the platform installer runs once, on the cluster the caller named" "[ $rc = 0 ] && [ \"\$(wc -l < '$LOG/platform.calls' | tr -d ' ')\" = 1 ] && grep -qx 'CLUSTER=openagentix' '$LOG/platform.env' && grep -qx 'KUBE_CONTEXT=kind-openagentix' '$LOG/platform.env'" "rc=$rc $(tail -4 "$LOG/out")"
check "beside the full demo: nothing is unset (the provider key and the scenarios stay as the caller gave them), and PROFILE is not forced" "grep -qx 'HAS ANTHROPIC_API_KEY' '$LOG/platform.env' && grep -qx 'STUB_SCENARIOS=/tmp/mine.json' '$LOG/platform.env' && grep -qx 'PROFILE=<unset>' '$LOG/platform.env'"
check "beside the full demo: the values file is the composed one: the caller's lists are all in it (the schedule, the bridge, the memory caller) with the new agent and caller added" "grep -q 'pod-rca' '$LOG/platform.values' && grep -q 'rca-desk' '$LOG/platform.values' && grep -q 'memory-canary' '$LOG/platform.values' && grep -q 'demo-brief' '$LOG/platform.values' && grep -q 'claude-haiku' '$LOG/platform.values' && ! grep -q 'quickstart-ask' '$LOG/platform.values'"
check "beside the full demo: the release is not refused for having more than the quick start, and no release check is made" "! grep -q 'has more than' '$LOG/out' && ! grep -q '^helm get' '$LOG/calls'"
check "beside the full demo: both renders were asked of helm (your list and the merged file), and the model line says it is your model" "[ \"\$(grep -c '^helm template' '$LOG/calls')\" = 2 ] && grep -q 'beside the full demo: the agent uses the model of your install' '$LOG/out'"
reset
CLUSTER=openagentix run --beside-full-demo; rc=$?
check "beside the full demo without VALUES_FILE is refused (a missing list would drop what it set)" "[ $rc = 1 ] && grep -q 'needs VALUES_FILE' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
CLUSTER=openagentix VALUES_FILE="$FDLIST" ANTHROPIC_API_KEY=$SECRET_KEY run --beside-full-demo --real-model; rc=$?
check "beside the full demo with --real-model is refused" "[ $rc = 1 ] && grep -q 'do not combine' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
CLUSTER=openagentix VALUES_FILE="$FDLIST" run --beside-full-demo --skip-platform; rc=$?
check "beside the full demo with --skip-platform is refused" "[ $rc = 1 ] && grep -q 'do not combine' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_HELM_DIFF=1 run --beside-full-demo; rc=$?
check "beside the full demo: when the merge of the caller's list does not render the same as the list, nothing is installed" "[ $rc = 1 ] && grep -q 'does not merge into one file that renders the same' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -2 "$LOG/out")"
reset
printf 'agents:\n  - name: pod-rca\n    model: other\n    systemPrompt: x\n    tools: []\n' > "$TMP/clash.yaml"
CLUSTER=openagentix VALUES_FILE="$FDLIST $TMP/clash.yaml" run --beside-full-demo; rc=$?
check "beside the full demo: a name that clashes (an agent pod-rca of other content) makes compose refuse, and nothing is installed" "[ $rc = 1 ] && grep -q 'did not compose' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
CLUSTER=openagentix VALUES_FILE="components/nope.yaml" run --beside-full-demo; rc=$?
check "beside the full demo: a file of the list that cannot be read is refused" "[ $rc = 1 ] && grep -q 'cannot read' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
KUBE_CONTEXT=gke_proj_zone_prod VALUES_FILE="$FDLIST" run --beside-full-demo; rc=$?
check "beside the full demo still refuses a context that is not kind or k3d" "[ $rc = 1 ] && grep -q 'local kind or k3d' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"

echo "# ctl.sh"
cat > "$BIN/ask" <<'EOF'
#!/usr/bin/env bash
echo "ask $1 :: $2 :: SA=${ASK_SA-} USER=${ASK_USER-} CTX=${KUBE_CONTEXT-}" >> "$FAKE_LOG/asks"
echo "an answer"
EOF
chmod +x "$BIN/ask"
ctl() { FAKE_LOG="$LOG" KUBECTL="$BIN/kubectl" ASK="$BIN/ask" PATH="$BIN:$PATH" bash "$HERE/ctl.sh" "$@" > "$LOG/out" 2>&1; }
reset
ctl analyze crash-start; rc=$?
check "analyze asks the agent pod-rca as the caller rca-desk and as an analyst, never as another desk" "[ $rc = 0 ] && grep -q 'ask pod-rca :: Pod root-cause analysis for workload crash-start in namespace rca-demo. :: SA=openagentix-system/rca-desk USER=sre:analyst-1' '$LOG/asks'" "rc=$rc $(cat "$LOG/asks" 2>/dev/null)"
reset
ctl analyze not-a-workload; rc=$?
check "analyze refuses a name that is not a workload of the demo" "[ $rc = 1 ] && [ ! -e '$LOG/asks' ]"
reset
KUBE_CONTEXT=prod ctl analyze crash-start; rc=$?
check "ctl.sh refuses a context that is not kind or k3d" "[ $rc = 1 ] && [ ! -e '$LOG/asks' ]"
reset
ctl pods; rc=$?
check "pods reads the namespace rca-demo and nothing else" "[ $rc = 0 ] && grep -q 'get pods -n rca-demo' '$LOG/calls' && [ \"\$(grep -c 'kubectl' '$LOG/calls')\" = 1 ]"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
