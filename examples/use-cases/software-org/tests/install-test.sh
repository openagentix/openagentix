#!/usr/bin/env bash
# Offline test of examples/use-cases/software-org/install.sh and ctl.sh with a fake kubectl and a fake platform installer. No cluster, no Docker,
# no network. Needs: bash, jq, yq (the Python wrapper, for compose-values.sh). Usage: examples/use-cases/software-org/tests/install-test.sh
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
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
  *"get configmap stub-model-scenarios"*) [ -n "${FAKE_SCENARIOS:-}" ] && { echo '{"data":{"software-org-rca.json":"{}"}}'; exit 0; } || exit 1 ;;
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
  # the script has no default cluster: the test names one, unless the case sets CLUSTER or KUBE_CONTEXT itself
  local RUN_CLUSTER=${CLUSTER-}; if [ -z "${CLUSTER+x}" ] && [ -z "${KUBE_CONTEXT:-}" ]; then RUN_CLUSTER=oa-rca-demo; fi
  FAKE_LOG="$LOG" CLUSTER="$RUN_CLUSTER" KUBECTL="$BIN/kubectl" HELM="${HELM:-$BIN/helm}" PLATFORM_INSTALL="$BIN/platform-install" PATH="$BIN:$PATH" bash "$HERE/install.sh" "$@" > "$LOG/out" 2>&1
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
check "it got STUB_SCENARIOS=eval/software-org-rca.json (the file of this use case)" "grep -qx \"STUB_SCENARIOS=$HERE/eval/software-org-rca.json\" '$LOG/platform.env'"
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
check "a stub model without the scenarios gives a warning, not a failure" "[ $rc = 0 ] && grep -q 'WARN: the stub model has no software-org-rca.json' '$LOG/out'"

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


echo "# there is no default cluster, and the guards of the bank install apply (helm, the exact not-found line, the allowlist of the release, the scenario files)"
reset
CLUSTER= KUBE_CONTEXT= run; rc=$?
check "with neither CLUSTER nor KUBE_CONTEXT the script refuses: there is no default cluster, and nothing runs" "[ $rc = 1 ] && grep -q 'no default cluster' '$LOG/out' && [ ! -e '$LOG/calls' ] && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -2 "$LOG/out")"
reset
CLUSTER=oa-one KUBE_CONTEXT=kind-oa-two run; rc=$?
check "CLUSTER and KUBE_CONTEXT that name different clusters are refused, and nothing runs" "[ $rc = 1 ] && grep -q 'name different clusters' '$LOG/out' && [ ! -e '$LOG/calls' ]"
reset
CLUSTER= KUBE_CONTEXT=kind-oa-rca-demo FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "KUBE_CONTEXT alone is enough: the cluster name is taken from it" "[ $rc = 0 ] && grep -qx 'CLUSTER=oa-rca-demo' '$LOG/platform.env' && grep -qx 'KUBE_CONTEXT=kind-oa-rca-demo' '$LOG/platform.env'"
reset
CLUSTER=demo KUBE_CONTEXT=k3d-demo FAKE_CONTEXTS=k3d-demo FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "CLUSTER=demo with KUBE_CONTEXT=k3d-demo agree (a k3d cluster is accepted)" "[ $rc = 0 ]" "rc=$rc $(tail -2 "$LOG/out")"
reset
HELM=/nonexistent/helm run; rc=$?
check "a missing helm stops the install: it never reads as no release" "[ $rc = 1 ] && grep -q 'helm is required' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
FAKE_STUB=1 FAKE_SCENARIOS=1 HELM=/nonexistent/helm run --skip-platform; rc=$?
check "--skip-platform does not need helm" "[ $rc = 0 ]"
reset
FAKE_CONTEXTS="" FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "a cluster that does not exist yet is fine (the platform installer makes it; nothing can be lost): helm is not asked" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ] && ! grep -q '^helm get' '$LOG/calls'"
reset
FAKE_HELM_ERR="Error: release: not found" FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "helm's exact line 'Error: release: not found' means no release: the install goes on" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]"
for err in "Error: release: not found (a guess)" "Error: Kubernetes cluster unreachable: connection refused" "Error: release: not found
Error: more"; do
  reset
  FAKE_HELM_ERR="$err" run; rc=$?
  check "any other helm failure stops the install ($(printf '%s' "$err" | head -1 | cut -c1-48))" "[ $rc = 1 ] && grep -q 'cannot read the values' '$LOG/out' && [ ! -e '$LOG/platform.calls' ] && ! grep -q 'apply' '$LOG/calls'" "rc=$rc $(tail -3 "$LOG/out")"
done

# the values a run hands over, as JSON: what the release would hold after it (plus the keys the platform installer sets itself)
reset
FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
yq . "$LOG/platform.values" > "$TMP/composed-default.json"
installer_keys='{"diagnostics":{"sourceHash":"abc","apiServerCIDRs":["172.18.0.0/24"],"image":{"tag":"dev"}},"controlPlane":{"sourceHash":"x","apiServerCIDRs":["172.18.0.0/24"]},"gateway":{"stubModel":{"sourceHash":"y","scenarios":{"files":{"software-org-rca.json":"{}"}}}}}'
jq -c ". * $installer_keys" "$TMP/composed-default.json" > "$TMP/release-default.json"
reset
FAKE_HELM_VALUES="$(cat "$TMP/release-default.json")" FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "a second run passes: the release holds exactly what the first run handed over, plus the keys the platform installer sets itself" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
while IFS='|' read -r what json; do
  reset
  FAKE_HELM_VALUES="$(jq -c ". * $json" "$TMP/release-default.json")" run; rc=$?
  check "a release with $what beyond the composed values is refused naming the path, nothing is installed, nothing is applied" "[ $rc = 1 ] && grep -q 'has more than the quick start' '$LOG/out' && grep -qF -e '$what' '$LOG/out' && [ ! -e '$LOG/platform.calls' ] && ! grep -q 'apply' '$LOG/calls'" "rc=$rc $(tail -2 "$LOG/out")"
done <<'LIST'
.schedules[demo-brief].name|{"schedules":[{"name":"demo-brief"}]}
.bridge.agent|{"bridge":{"agent":"assistant"}}
.channels.kourier.enabled|{"channels":{"kourier":{"enabled":true}}}
.notify.enabled|{"notify":{"enabled":true}}
.knowledge.kb.extractModel|{"knowledge":{"kb":{"extractModel":"x"}}}
.memory.enabled|{"memory":{"enabled":true}}
.agents[assistant].name|{"agents":[{"name":"assistant"}]}
.mcp.profiles[db].name|{"mcp":{"profiles":[{"name":"db"}]}}
.mcp.servers[fetch].name|{"mcp":{"servers":[{"name":"fetch"}]}}
.governance.a2a.callers[bridge].name|{"governance":{"a2a":{"callers":[{"name":"bridge"}]}}}
.mcp.virtual.codeMode.tools|{"mcp":{"virtual":{"codeMode":{"tools":["x"]}}}}
.somethingnew.x|{"somethingnew":{"x":1}}
LIST
reset
FAKE_HELM_VALUES="$(jq -c '. * {"gateway":{"stubModel":{"scenarios":{"files":{"scenario.json":"{\"scenarios\":[{\"match\":{\"system\":\"Fernvale dispute desk agent\"}}]}"}}}}}' "$TMP/release-default.json")" run; rc=$?
check "a scenario file of another use case (the bank's scenario.json) in the release is NOT replaced silently: refused and named" "[ $rc = 1 ] && grep -qF 'scenarios.files.scenario.json' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -2 "$LOG/out")"
reset
FAKE_HELM_VALUES="$(jq -c '. * {"gateway":{"stubModel":{"scenarios":{"files":{"other-case.json":"{}"}}}}}' "$TMP/release-default.json")" run; rc=$?
check "any other scenario file of the release is refused too" "[ $rc = 1 ] && grep -qF 'scenarios.files.other-case.json' '$LOG/out'"
reset
FAKE_HELM_VALUES="$(jq -c '. * {"gateway":{"stubModel":{"scenarios":{"files":{"software-org-rca.json":"an earlier copy"}}}}}' "$TMP/release-default.json")" FAKE_STUB=1 FAKE_SCENARIOS=1 run; rc=$?
check "an earlier copy of this use case's own scenario file is replaced without complaint" "[ $rc = 0 ]"
reset
FAKE_HELM_VALUES="$(jq -c '. * {"gateway":{"stubModel":{"scenarios":{"files":{"software-org-rca.json":"an earlier copy"}}}}}' "$TMP/release-default.json")" ANTHROPIC_API_KEY=$SECRET_KEY run --real-model; rc=$?
check "--real-model on a release that holds this use case's scenario file passes (the file goes away with the stub)" "[ $rc = 0 ]" "rc=$rc $(tail -2 "$LOG/out")"

echo "# --beside-full-demo"
FDLIST="components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml components/observability/demo-values.yaml components/knowledge/graph-demo-values.yaml components/governance/demo-values.yaml components/governance/profiles-demo-values.yaml components/governance/memory-demo-values.yaml components/control-plane/demo-values.yaml components/console/demo-values.yaml"
reset
CLUSTER=openagentix ANTHROPIC_API_KEY=$SECRET_KEY STUB_SCENARIOS=/tmp/mine.json VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix FAKE_STUB=1 FAKE_SCENARIOS=1 run --beside-full-demo; rc=$?
check "beside the full demo: exits 0, the platform installer runs once, on the cluster the caller named" "[ $rc = 0 ] && [ \"\$(wc -l < '$LOG/platform.calls' | tr -d ' ')\" = 1 ] && grep -qx 'CLUSTER=openagentix' '$LOG/platform.env' && grep -qx 'KUBE_CONTEXT=kind-openagentix' '$LOG/platform.env'" "rc=$rc $(tail -4 "$LOG/out")"
check "beside the full demo: nothing is unset (the provider key and the scenarios stay as the caller gave them), and PROFILE is not forced" "grep -qx 'HAS ANTHROPIC_API_KEY' '$LOG/platform.env' && grep -qx 'STUB_SCENARIOS=/tmp/mine.json' '$LOG/platform.env' && grep -qx 'PROFILE=<unset>' '$LOG/platform.env'"
check "beside the full demo: the values file is the composed one: the caller's lists are all in it (the schedule, the bridge, the memory caller) with the new agent and caller added" "grep -q 'pod-rca' '$LOG/platform.values' && grep -q 'rca-desk' '$LOG/platform.values' && grep -q 'memory-canary' '$LOG/platform.values' && grep -q 'demo-brief' '$LOG/platform.values' && grep -q 'claude-haiku' '$LOG/platform.values' && ! grep -q 'quickstart-ask' '$LOG/platform.values'"
check "beside the full demo: the release is read (helm get values), and both renders were asked of helm (your list and the merged file)" "grep -q '^helm get values' '$LOG/calls' && [ \"\$(grep -c '^helm template' '$LOG/calls')\" = 2 ] && grep -q 'beside your install: the agent uses the model of your install' '$LOG/out'"
yq . "$LOG/platform.values" > "$TMP/composed-beside.json"
jq -c ". * $installer_keys" "$TMP/composed-beside.json" > "$TMP/release-beside.json"
reset
FAKE_HELM_VALUES="$(cat "$TMP/release-beside.json")" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "a SECOND --beside-full-demo run passes: the release holds your list plus this agent, and nothing else" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
FAKE_HELM_VALUES="$(jq -c '. * {"somethingnew":{"x":1},"mcp":{"profiles":[{"name":"left-out-of-your-list"}]}}' "$TMP/release-beside.json")" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "beside the full demo: a key the release has and your list plus this agent lack (a file left out of the list) is refused and named, nothing is installed" "[ $rc = 1 ] && grep -qF '.somethingnew.x' '$LOG/out' && grep -qF '.mcp.profiles[left-out-of-your-list].name' '$LOG/out' && grep -q 'VALUES_FILE list' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -2 "$LOG/out")"
reset
FAKE_HELM_ERR="Error: Kubernetes cluster unreachable" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "beside the full demo: a release that cannot be read stops the install" "[ $rc = 1 ] && grep -q 'cannot read the values' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS="" run --beside-full-demo; rc=$?
check "beside the full demo needs the cluster of your install to exist" "[ $rc = 1 ] && grep -q 'to exist' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
HELM=/nonexistent/helm CLUSTER=openagentix VALUES_FILE="$FDLIST" run --beside-full-demo; rc=$?
check "beside the full demo without helm stops" "[ $rc = 1 ] && grep -q 'helm is required' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
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
CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix FAKE_HELM_DIFF=1 run --beside-full-demo; rc=$?
check "beside the full demo: when the merge of the caller's list does not render the same as the list, nothing is installed" "[ $rc = 1 ] && grep -q 'does not merge into one file that renders the same' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -2 "$LOG/out")"
reset
printf 'agents:\n  - name: pod-rca\n    model: other\n    systemPrompt: x\n    tools: []\n' > "$TMP/clash.yaml"
CLUSTER=openagentix VALUES_FILE="$FDLIST $TMP/clash.yaml" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "beside the full demo: a name that clashes (an agent pod-rca of other content) makes compose refuse, and nothing is installed" "[ $rc = 1 ] && grep -q 'did not compose' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
CLUSTER=openagentix VALUES_FILE="components/nope.yaml" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "beside the full demo: a file of the list that cannot be read is refused" "[ $rc = 1 ] && grep -q 'cannot read' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
KUBE_CONTEXT=gke_proj_zone_prod VALUES_FILE="$FDLIST" run --beside-full-demo; rc=$?
check "beside the full demo still refuses a context that is not kind or k3d" "[ $rc = 1 ] && grep -q 'local kind or k3d' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"

echo "# ALSO_COMPOSE refuses this use case's own values-full-demo.yaml, by full path"
reset
ALSO_COMPOSE="$HERE/values-full-demo.yaml" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "ALSO_COMPOSE listing the use case's own values-full-demo.yaml is refused before the platform installer runs" "[ $rc = 1 ] && grep -q \"own values-full-demo.yaml\" '$LOG/out' && [ ! -s '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
echo "# ALSO_COMPOSE: this agent beside the full demo AND the bank (and any other use case with a values-full-demo.yaml)"
BANKFD="examples/use-cases/bank/values-full-demo.yaml"
reset
ALSO_COMPOSE="$BANKFD" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "ALSO_COMPOSE with the bank's values-full-demo.yaml: exits 0 and the platform installer runs once" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]" "rc=$rc $(tail -4 "$LOG/out")"
check "the composed values keep every full demo list entry (the schedule, the memory caller, the bridge), every bank entry (agent, profile, caller) and this agent" "grep -q 'demo-brief' '$LOG/platform.values' && grep -q 'memory-canary' '$LOG/platform.values' && grep -q 'dispute-agent' '$LOG/platform.values' && grep -q 'disputes-desk' '$LOG/platform.values' && grep -q 'name: disputes' '$LOG/platform.values' && grep -q 'pod-rca' '$LOG/platform.values' && grep -q 'rca-desk' '$LOG/platform.values'"
yq . "$LOG/platform.values" > "$TMP/composed-also.json"
check "every entry name of every list of the full demo and of the bank file is still in the composed values (nothing was dropped by the order of composition)" "python3 -I - '$TMP/composed-also.json' '$FDLIST' '$ROOT/$BANKFD' <<'PY'
import sys, json, subprocess
comp = json.load(open(sys.argv[1]))
def names(d, path=''):
    out = set()
    if isinstance(d, dict):
        for k, v in d.items(): out |= names(v, path + '.' + k)
    elif isinstance(d, list):
        for e in d:
            if isinstance(e, dict) and isinstance(e.get('name'), str): out.add(path + '[' + e['name'] + ']')
            out |= names(e, path + '[]' if not (isinstance(e, dict) and isinstance(e.get('name'), str)) else path + '[' + e['name'] + ']')
    return out
have = names(comp)
def merge(a, b):
    if isinstance(a, dict) and isinstance(b, dict):
        r = dict(a)
        for k, v in b.items(): r[k] = merge(a[k], v) if k in a else v
        return r
    return b
base = {}
for f in sys.argv[2].split():
    base = merge(base, json.loads(subprocess.check_output(['yq', '.', '$ROOT/' + f])))
bank = json.loads(subprocess.check_output(['yq', '.', sys.argv[3]]))
miss = sorted(n for d in (base, bank) for n in names(d) if n not in have)
print(miss[:10]) if miss else None
sys.exit(1 if miss else 0)
PY"
jq -c ". * $installer_keys" "$TMP/composed-also.json" > "$TMP/release-also.json"
reset
FAKE_HELM_VALUES="$(cat "$TMP/release-also.json")" ALSO_COMPOSE="$BANKFD" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "a second run with the same ALSO_COMPOSE passes" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
FAKE_HELM_VALUES="$(cat "$TMP/release-also.json")" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "the release holds the bank and ALSO_COMPOSE is not given: refused, the bank's entries are named, and the message says to add its values-full-demo.yaml to ALSO_COMPOSE; nothing is installed" "[ $rc = 1 ] && grep -qF '.agents[dispute-agent]' '$LOG/out' && grep -qF 'add its values-full-demo.yaml to ALSO_COMPOSE' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
printf 'agents:\n  - name: dispute-agent\n    model: other\n    systemPrompt: x\n    tools: []\n' > "$TMP/clash2/values-full-demo.yaml" 2>/dev/null || { mkdir -p "$TMP/clash2"; printf 'agents:\n  - name: dispute-agent\n    model: other\n    systemPrompt: x\n    tools: []\n' > "$TMP/clash2/values-full-demo.yaml"; }
ALSO_COMPOSE="$BANKFD $TMP/clash2/values-full-demo.yaml" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "two composed files that clash (the same agent name with other content) are refused by compose, and nothing is installed" "[ $rc = 1 ] && grep -q 'did not compose' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
ALSO_COMPOSE="$BANKFD" CLUSTER=oa-rca-demo run; rc=$?
check "ALSO_COMPOSE without --beside-full-demo is refused" "[ $rc = 1 ] && grep -q 'beside-full-demo only' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
ALSO_COMPOSE="components/quickstart/values.yaml" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "ALSO_COMPOSE takes values-full-demo.yaml files only: another file is refused" "[ $rc = 1 ] && grep -q 'values-full-demo.yaml files' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"
reset
ALSO_COMPOSE="examples/use-cases/nope/values-full-demo.yaml" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "a file of ALSO_COMPOSE that cannot be read is refused" "[ $rc = 1 ] && grep -q 'cannot read' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]"

echo "# the model keys of the quick start are ignored only in the default modes"
reset
FAKE_HELM_VALUES="$(jq -c '. * {"gateway":{"models":[{"name":"quickstart-model","provider":"Anthropic"}],"stubModel":{"enabled":false}}}' "$TMP/release-default.json")" ANTHROPIC_API_KEY=$SECRET_KEY run --real-model; rc=$?
check "default mode: the quickstart-model entry and stubModel.enabled that a provider key makes the installer set are not extras" "[ $rc = 0 ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
FAKE_HELM_VALUES="$(jq -c '. * {"gateway":{"models":[{"name":"quickstart-model","provider":"Anthropic"}]}}' "$TMP/release-also.json")" ALSO_COMPOSE="$BANKFD" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "--beside-full-demo: a quickstart-model entry of the release that your list lacks is refused and named (a model choice would be lost)" "[ $rc = 1 ] && grep -qF '.gateway.models[quickstart-model]' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
FAKE_HELM_VALUES="$(jq -c '. * {"gateway":{"stubModel":{"enabled":false}}}' "$TMP/release-also.json")" ALSO_COMPOSE="$BANKFD" CLUSTER=openagentix VALUES_FILE="$FDLIST" FAKE_CONTEXTS=kind-openagentix run --beside-full-demo; rc=$?
check "--beside-full-demo: a stubModel.enabled of the release that your list lacks is refused and named" "[ $rc = 1 ] && grep -qF '.gateway.stubModel.enabled' '$LOG/out'"

echo "# beside an installed bank: the bank is composed, never dropped"
ROOT_UC="$HERE/../bank"
mkdir -p "$TMP/scn"
cp "$HERE/../bank/eval/scenario.json" "$TMP/scn/scenario.json"; cp "$HERE/eval/software-org-rca.json" "$TMP/scn/software-org-rca.json"
BANKLIST="components/quickstart/values.yaml examples/use-cases/bank/values.yaml"
reset
PROFILE=quickstart STUB_SCENARIOS="$TMP/scn" CLUSTER=oa-both VALUES_FILE="$BANKLIST" FAKE_CONTEXTS=kind-oa-both run --beside-full-demo; rc=$?
check "beside an installed bank (its own values list, the quick start profile, both scenario files in one directory): exits 0, one platform install" "[ $rc = 0 ] && [ -s '$LOG/platform.calls' ]" "rc=$rc $(tail -4 "$LOG/out")"
check "the composed values hold the bank (its agent, its endpoint, its profile) AND this agent, and the quick start caller once" "grep -q 'dispute-agent' '$LOG/platform.values' && grep -q 'pod-rca' '$LOG/platform.values' && grep -q 'disputes-desk' '$LOG/platform.values' && grep -q 'rca-desk' '$LOG/platform.values' && [ \"\$(grep -c '^      - name: quickstart-ask' '$LOG/platform.values')\" = 1 ]"
check "the platform installer got PROFILE=quickstart and the directory with both scenario files, as the caller gave them" "grep -qx 'PROFILE=quickstart' '$LOG/platform.env' && grep -qx 'STUB_SCENARIOS=$TMP/scn' '$LOG/platform.env'"
yq . "$LOG/platform.values" > "$TMP/composed-both.json"
reset
FAKE_HELM_VALUES="$(jq -c ". * $installer_keys * {\"gateway\":{\"stubModel\":{\"scenarios\":{\"files\":{\"scenario.json\":\"{}\"}}}}}" "$TMP/composed-both.json")" PROFILE=quickstart STUB_SCENARIOS="$TMP/scn" CLUSTER=oa-both VALUES_FILE="$BANKLIST" FAKE_CONTEXTS=kind-oa-both run --beside-full-demo; rc=$?
check "a second run beside the bank passes: the release holds the bank's scenario.json, and STUB_SCENARIOS gives it again" "[ $rc = 0 ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
FAKE_HELM_VALUES="$(jq -c ". * $installer_keys * {\"gateway\":{\"stubModel\":{\"scenarios\":{\"files\":{\"scenario.json\":\"{}\"}}}}}" "$TMP/composed-both.json")" PROFILE=quickstart STUB_SCENARIOS="$HERE/eval/software-org-rca.json" CLUSTER=oa-both VALUES_FILE="$BANKLIST" FAKE_CONTEXTS=kind-oa-both run --beside-full-demo; rc=$?
check "beside the bank with only this use case's scenario file: the bank's scenario.json would be dropped, so it is refused and named" "[ $rc = 1 ] && grep -qF 'scenarios.files.scenario.json' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"
reset
FAKE_HELM_VALUES="$(jq -c ". * $installer_keys" "$TMP/composed-both.json")" CLUSTER=oa-both FAKE_CONTEXTS=kind-oa-both run; rc=$?
check "the plain install (quick start plus this use case only) on a release that holds the bank is refused: dispute-agent is named" "[ $rc = 1 ] && grep -qF '.agents[dispute-agent]' '$LOG/out' && [ ! -e '$LOG/platform.calls' ]" "rc=$rc $(tail -3 "$LOG/out")"

echo "# ctl.sh"
cat > "$BIN/ask" <<'EOF'
#!/usr/bin/env bash
echo "ask $1 :: $2 :: SA=${ASK_SA-} USER=${ASK_USER-} CTX=${KUBE_CONTEXT-}" >> "$FAKE_LOG/asks"
echo "an answer"
EOF
chmod +x "$BIN/ask"
ctl() { CLUSTER="${CLUSTER-oa-rca-demo}" FAKE_LOG="$LOG" KUBECTL="$BIN/kubectl" ASK="$BIN/ask" PATH="$BIN:$PATH" bash "$HERE/ctl.sh" "$@" > "$LOG/out" 2>&1; }
reset
ctl analyze crash-start; rc=$?
check "analyze asks the agent pod-rca as the caller rca-desk and as an analyst, never as another desk" "[ $rc = 0 ] && grep -q 'ask pod-rca :: Pod root-cause analysis for workload crash-start in namespace rca-demo. :: SA=openagentix-system/rca-desk USER=sre:analyst-1' '$LOG/asks'" "rc=$rc $(cat "$LOG/asks" 2>/dev/null)"
reset
ctl analyze not-a-workload; rc=$?
check "analyze refuses a name that is not a workload of the demo" "[ $rc = 1 ] && [ ! -e '$LOG/asks' ]"
reset
CLUSTER= KUBE_CONTEXT=prod ctl analyze crash-start; rc=$?
check "ctl.sh refuses a context that is not kind or k3d" "[ $rc = 1 ] && [ ! -e '$LOG/asks' ]"
reset
CLUSTER= KUBE_CONTEXT= ctl pods; rc=$?
check "ctl.sh has no default cluster: with neither CLUSTER nor KUBE_CONTEXT it refuses and calls nothing" "[ $rc = 1 ] && grep -q 'no default cluster' '$LOG/out' && [ ! -e '$LOG/calls' ]"
reset
CLUSTER=a KUBE_CONTEXT=kind-b ctl pods; rc=$?
check "ctl.sh refuses a CLUSTER and a KUBE_CONTEXT that name different clusters" "[ $rc = 1 ] && grep -q 'different clusters' '$LOG/out' && [ ! -e '$LOG/calls' ]"
reset
ctl pods; rc=$?
check "pods reads the namespace rca-demo and nothing else" "[ $rc = 0 ] && grep -q 'get pods -n rca-demo' '$LOG/calls' && [ \"\$(grep -c 'kubectl' '$LOG/calls')\" = 1 ]"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
