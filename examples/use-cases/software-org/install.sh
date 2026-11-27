#!/usr/bin/env bash
# Installs the software organisation use case, first agent (pod root-cause analysis), on a LOCAL kind or k3d cluster:
#
#   examples/use-cases/software-org/install.sh                 offline: the quick start with the stub model and the scenarios (no key, no token)
#   examples/use-cases/software-org/install.sh --real-model    the same agent on a real model: needs a provider key in the environment, sets NO scenarios
#   examples/use-cases/software-org/install.sh --skip-platform only the use case objects (the platform install ran already with values.yaml)
#   VALUES_FILE="<the list you installed the full demo with>" CLUSTER=<its cluster> \
#     examples/use-cases/software-org/install.sh --beside-full-demo    add the agent to a full demo install (values-full-demo.yaml, composed AFTER your list)
#   examples/use-cases/software-org/install.sh --uninstall     removes what this script made (not the chart values: see README, "Uninstall")
#
# What it does, in order. Every step can be run again.
#   0. refuses any kube context that is not kind-* or k3d-* (the platform installer is given the same context and cluster name, and creates the
#      local cluster when it is not there; this script never deletes one). This guard comes first, also for --uninstall;
#   1. composes the values: hack/compose-values.sh merges components/quickstart/values.yaml and values.yaml by entry name and reports what the
#      second file adds and changes (a plain `VALUES_FILE=examples/use-cases/software-org/values.yaml` gives the same render: a test compares);
#   2. runs the platform installer (./install.sh) with PROFILE=quickstart and that file. Offline it also sets STUB_SCENARIOS=eval/scenario.json
#      (ADR 0026) and removes every provider key from the environment of that run, so the stub answers. With --real-model it sets no scenarios
#      and needs one of ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY or MODEL_BASE_URL (with MODEL_NAME). The installer builds the
#      diagnostics image, makes the bearer Secrets (never printed) and the namespaces, and waits for cluster-read and its tool server;
#   3. checks that the platform has what the use case needs: the agent pod-rca, cluster-read, the tool server of the profile rca;
#   4. applies manifests/rca-demo.yaml (the namespace with restricted pod security, six workloads that are broken on purpose, one ConfigMap);
#   5. makes the ServiceAccount openagentix-system/rca-desk, the caller of the agent (the rule is in values.yaml);
#   6. offline: checks that the stub model has the scenarios, and warns when it has not.
#
# The default cluster is a cluster of its own, oa-rca-demo (kind-oa-rca-demo). It is NOT your full demo cluster. The platform installer replaces the
# release values on every run, so this script REFUSES to run the quick start install on a release that already has more than the quick start
# (schedules, a bridge, channels, notify, knowledge, memory, more agents or profiles than this use case): it would drop them. On such a release use
# --beside-full-demo, with VALUES_FILE set to the same list of files you installed with.
#
# Env: CLUSTER (kind cluster name, default oa-rca-demo)  KUBE_CONTEXT (default kind-$CLUSTER; k3d-<name> is accepted)  KUBECTL  HELM
#      VALUES_FILE (--beside-full-demo only: the files of the install you have, space separated)
#      PLATFORM_INSTALL (the platform installer, default ./install.sh in the repository root; a test sets a fake)  COMPOSE (compose-values.sh)
#      Any other variable of the platform installer (SKIP_*, AGENT_WAIT, ...) goes through to it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
CLUSTER=${CLUSTER:-oa-rca-demo}   # a cluster of its own, never the name of a full demo cluster
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-$CLUSTER}
KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
RELEASE=${RELEASE:-openagentix}
RELEASE_NS=${RELEASE_NS:-openagentix-system}
PLATFORM_INSTALL=${PLATFORM_INSTALL:-$ROOT/install.sh}
COMPOSE=${COMPOSE:-$ROOT/hack/compose-values.sh}
KC=("$KUBECTL" --context "$KUBE_CONTEXT")
DESK_NS=openagentix-system
NS=rca-demo

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

# The guard comes first, before any option runs: --uninstall deletes things too.
case "$KUBE_CONTEXT" in
  kind-*|k3d-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind or k3d cluster (kind-<name> or k3d-<name>). Set CLUSTER or KUBE_CONTEXT. Nothing was changed." ;;
esac

MODE=install; REAL=0; SKIP_PLATFORM=0; BESIDE=0
for arg in "$@"; do
  case "$arg" in
    --real-model) REAL=1 ;;
    --skip-platform) SKIP_PLATFORM=1 ;;
    --beside-full-demo) BESIDE=1 ;;
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n 2,34p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (--real-model, --skip-platform, --beside-full-demo, --uninstall, -h)" ;;
  esac
done

if [ "$MODE" = uninstall ]; then
  say "removing the software organisation use case objects from $KUBE_CONTEXT (the chart values stay: install the platform again without values.yaml to remove the agent, the profile and cluster-read)"
  "${KC[@]}" delete -f "$HERE/manifests/rca-demo.yaml" --ignore-not-found
  "${KC[@]}" delete serviceaccount rca-desk -n "$DESK_NS" --ignore-not-found
  exit 0
fi

command -v jq >/dev/null || die "jq is required"
[ -x "$PLATFORM_INSTALL" ] || [ -f "$PLATFORM_INSTALL" ] || die "the platform installer is not at $PLATFORM_INSTALL"

if [ "$REAL" = 1 ]; then
  if [ -z "${ANTHROPIC_API_KEY:-}${OPENAI_API_KEY:-}${GOOGLE_API_KEY:-}${MODEL_BASE_URL:-}" ]; then
    die "--real-model needs a model: set ANTHROPIC_API_KEY, OPENAI_API_KEY, GOOGLE_API_KEY, or MODEL_BASE_URL with MODEL_NAME. Nothing was changed."
  fi
fi

[ "$BESIDE" = 0 ] || [ "$REAL" = 0 ] || die "--beside-full-demo keeps the model of your full demo: do not combine it with --real-model. Nothing was changed."
[ "$BESIDE" = 0 ] || [ "$SKIP_PLATFORM" = 0 ] || die "--beside-full-demo runs the platform installer: do not combine it with --skip-platform. Nothing was changed."
if [ "$BESIDE" = 1 ] && [ -z "${VALUES_FILE:-}" ]; then
  die "--beside-full-demo needs VALUES_FILE: the same list of files you installed the full demo with. Helm replaces the release values on every run, so a list that is missing would drop what it set. Nothing was changed."
fi

# ---- 0b. the release must not lose anything -----------------------------------------------------------------------------------------
# The platform installer replaces the release values. Without --beside-full-demo this script installs the quick start plus this use case, so a release that
# has more than that would lose it (and, offline, every provider key is removed, so the model would become the stub). Refuse, and say what would be lost.
release_extras() { # prints what the existing release has beyond the quick start and this use case, one thing per line; fails when it cannot tell
  local ctxs out
  ctxs=$("$KUBECTL" config get-contexts -o name 2>/dev/null || true)
  printf '%s\n' "$ctxs" | grep -qx "$KUBE_CONTEXT" || return 0   # no such context yet: the platform installer makes the cluster, nothing can be lost
  if ! out=$("$HELM" get values "$RELEASE" -n "$RELEASE_NS" --kube-context "$KUBE_CONTEXT" -o json 2>&1); then
    case "$out" in *"not found"*) return 0 ;; esac
    echo "cannot read the values of the release $RELEASE in $KUBE_CONTEXT: $(printf '%s' "$out" | head -1)" >&2
    return 1
  fi
  printf '%s' "$out" | jq -r '
    [ (if ((.schedules // []) | length) > 0 then "schedules" else empty end),
      (if (.bridge.enabled // false) == true then "the Telegram bridge" else empty end),
      (if ((.channels.kourier.enabled // false) == true) or (((.channels.bindings // []) | length) > 0) then "channels" else empty end),
      (if (.notify.enabled // false) == true then "notify" else empty end),
      (if (.knowledge.enabled // false) == true then "the knowledge base" else empty end),
      (if (.memory.enabled // false) == true then "memory" else empty end),
      (if (.mcp.virtual.codeMode.enabled // false) == true then "code mode on the shared tool server" else empty end),
      (((.agents // []) | map(.name) - ["pod-rca"]) | if length > 0 then "agents: " + join(", ") else empty end),
      (((.mcp.profiles // []) | map(.name) - ["lookup", "rca"]) | if length > 0 then "tool profiles: " + join(", ") else empty end),
      (((.mcp.servers // []) | map(.name) - ["osv"]) | if length > 0 then "tool servers: " + join(", ") else empty end),
      (((.governance.a2a.callers // []) | map(.name) - ["quickstart-ask", "rca-desk"]) | if length > 0 then "gate callers: " + join(", ") else empty end)
    ] | .[]'
}
if [ "$SKIP_PLATFORM" != 1 ] && [ "$BESIDE" != 1 ]; then
  EXTRAS=$(release_extras) || die "refusing to run the platform installer on a release I cannot read. Nothing was changed."
  if [ -n "$EXTRAS" ]; then
    die "the release $RELEASE in $KUBE_CONTEXT has more than the quick start: $(printf '%s' "$EXTRAS" | tr '\n' ';' | sed 's/;/; /g'). The platform installer would replace those values and drop them. Use a cluster of its own (CLUSTER=oa-rca-demo), or add the agent to your install with: VALUES_FILE=\"<your files>\" CLUSTER=<its cluster> $0 --beside-full-demo. Nothing was changed."
  fi
fi

# ---- 1. compose the values ---------------------------------------------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VALUES_COMPOSED="$TMP/software-org-values.yaml"
if [ "$SKIP_PLATFORM" != 1 ]; then
  if [ "$BESIDE" = 1 ]; then
    say "composing the values: your list ($VALUES_FILE) first, then examples/use-cases/software-org/values-full-demo.yaml (only the diagnostics block, the profile rca, the agent pod-rca and the caller rca-desk)"
    # Your own files are merged first, the way Helm merges them (maps deep, a later file wins, a list is REPLACED by a later file), into one file. That
    # is exactly your install, so compose-values.sh must not judge it. The merge is checked instead: the chart must render byte for byte the same from
    # your list and from the merged file. Only then is values-full-demo.yaml composed after it by compose-values.sh, without --later-wins: it joins
    # the lists by name and never drops an entry of yours, and a name or a security key that clashes is refused, and nothing is installed.
    cd "$ROOT"
    VALUES_BASE="$TMP/your-values.yaml"
    command -v yq >/dev/null || die "yq (the Python wrapper) is required for --beside-full-demo"
    : > "$TMP/your-values.json"
    for f in $VALUES_FILE; do
      [ -r "$f" ] || die "cannot read $f (VALUES_FILE is read from the repository root). Nothing was changed."
      yq . "$f" >> "$TMP/your-values.json" || die "cannot read $f as YAML. Nothing was changed."
    done
    jq -s 'reduce .[] as $x ({}; . * $x)' "$TMP/your-values.json" > "$VALUES_BASE" || die "your VALUES_FILE list did not merge. Nothing was changed."
    HELM_ARGS=(template check "$ROOT/charts/openagentix" -n "$RELEASE_NS" --api-versions agentkourier.dev/v1alpha1)
    VF_ARGS=(); for f in $VALUES_FILE; do VF_ARGS+=(-f "$f"); done
    "$HELM" "${HELM_ARGS[@]}" "${VF_ARGS[@]}" > "$TMP/render.yours" 2>"$TMP/render.err" || { cat "$TMP/render.err" >&2; die "the chart does not render from your VALUES_FILE list as given (the reason is above). Nothing was changed."; }
    "$HELM" "${HELM_ARGS[@]}" -f "$VALUES_BASE" > "$TMP/render.merged" 2>"$TMP/render.err" || { cat "$TMP/render.err" >&2; die "the chart does not render from your merged values. Nothing was changed."; }
    cmp -s "$TMP/render.yours" "$TMP/render.merged" || die "your VALUES_FILE list does not merge into one file that renders the same (a later file of yours replaces a list the merge would join). I will not guess: add the agent by hand with your list and values-full-demo.yaml. Nothing was changed."
    "$COMPOSE" -o "$VALUES_COMPOSED" "$VALUES_BASE" "$HERE/values-full-demo.yaml" || die "the values did not compose (the reason is above): your install and this agent do not fit together as they are. Nothing was changed."
  else
    say "composing the values (components/quickstart/values.yaml and examples/use-cases/software-org/values.yaml)"
    "$COMPOSE" -o "$VALUES_COMPOSED" "$ROOT/components/quickstart/values.yaml" "$HERE/values.yaml" || die "the values did not compose (the reason is above). Nothing was changed."
  fi

  # ---- 2. the platform -------------------------------------------------------------------------------------------------------
  if [ "$BESIDE" = 1 ]; then
    say "platform install beside the full demo: your model, your provider keys and your scenarios stay as they are (nothing is unset)"
    env CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" VALUES_FILE="$VALUES_COMPOSED" "$PLATFORM_INSTALL"
  elif [ "$REAL" = 1 ]; then
    say "platform install with a real model: no scenarios are set, the stub model is off"
    env -u STUB_SCENARIOS CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" PROFILE=quickstart VALUES_FILE="$VALUES_COMPOSED" "$PLATFORM_INSTALL"
  else
    say "platform install, offline: the stub model with the scenarios of eval/scenario.json (a run with them is SCRIPTED, not the behaviour of a model)"
    env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY -u MODEL_BASE_URL -u MODEL_NAME -u MODEL_PROVIDER -u MODEL_API_KEY \
      CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" PROFILE=quickstart VALUES_FILE="$VALUES_COMPOSED" STUB_SCENARIOS="$HERE/eval/scenario.json" "$PLATFORM_INSTALL"
  fi
fi

# ---- 3. the platform must have what the use case needs -------------------------------------------------------------------------
"${KC[@]}" get namespace mcp-tools >/dev/null 2>&1 || die "the tool gateway namespace mcp-tools does not exist: the platform is not installed (run this script without --skip-platform)"
"${KC[@]}" get agents.api.kagent.dev pod-rca -n kagent >/dev/null 2>&1 || die "the agent pod-rca does not exist: the platform install must use examples/use-cases/software-org/values.yaml"
"${KC[@]}" get deployment cluster-read -n openagentix-diagnostics >/dev/null 2>&1 || die "cluster-read is not installed: the platform install must use examples/use-cases/software-org/values.yaml (diagnostics.enabled)"
"${KC[@]}" get virtualmcpservers.toolhive.stacklok.dev tools-rca -n mcp-tools >/dev/null 2>&1 || die "the tool server of the profile rca (VirtualMCPServer tools-rca) does not exist: the platform install must use examples/use-cases/software-org/values.yaml"
CODEMODE=$("${KC[@]}" get virtualmcpservers.toolhive.stacklok.dev tools-rca -n mcp-tools -o jsonpath='{.spec.config.codeMode.enabled}' 2>/dev/null || true)
[ "$CODEMODE" != true ] || die "the tool server of the profile rca has code mode on: a script there could chain diagnostics calls without the model. Nothing was changed."

# ---- 4. the broken workloads ---------------------------------------------------------------------------------------------------
say "applying the namespace $NS with its six broken workloads (they are broken on purpose; the namespace enforces restricted pod security)"
"${KC[@]}" apply --server-side --force-conflicts --field-manager=openagentix-software-org -f "$HERE/manifests/rca-demo.yaml" >/dev/null

# ---- 5. the caller ----------------------------------------------------------------------------------------------------------
"${KC[@]}" create serviceaccount rca-desk -n "$DESK_NS" --dry-run=client -o yaml | "${KC[@]}" apply -f - >/dev/null
say "ServiceAccount $DESK_NS/rca-desk is ready (the caller rule is in values.yaml: it may ask pod-rca and nothing else)"

# ---- 6. scenarios for the stub model: checked, not made --------------------------------------------------------------------------
if [ "$BESIDE" = 1 ]; then
  say "beside the full demo: the agent uses the model of your install (claude-haiku); no scenario was set"
elif [ "$REAL" = 1 ]; then
  say "real model: no scenario is needed. Read pass rates over several runs, not one run (README)"
elif "${KC[@]}" get deployment stub-model -n agentgateway-system >/dev/null 2>&1; then
  if SCN_CM=$("${KC[@]}" get configmap stub-model-scenarios -n agentgateway-system -o json 2>/dev/null) && printf '%s' "$SCN_CM" | jq -e '.data["scenario.json"] != null' >/dev/null 2>&1; then
    say "the stub model has the scenarios from the chart (runs with them are scripted by the stub model, not the behaviour of a model)"
  else
    echo "WARN: the stub model has no scenario.json, so it will not work these cases. Run the platform install again with STUB_SCENARIOS=examples/use-cases/software-org/eval/scenario.json (and the same values)." >&2
  fi
else
  say "no stub model in this cluster: no scenario is needed"
fi

cat <<EOF

The pod root-cause use case is installed. The six workloads need a minute or two to show their faults. Next:
  examples/use-cases/software-org/ctl.sh pods                         # wait until each workload shows its fault
  examples/use-cases/software-org/ctl.sh analyze crash-start          # ask the agent; try img-typo, oom-kill, cfg-missing-key, probe-fail, pending-selector
  examples/use-cases/software-org/ctl.sh analyze ghost-worker         # a workload that does not exist: the answer is "inconclusive"
See examples/use-cases/software-org/README.md for the demo, the evaluation, what is proven and the live proof checklist.
EOF
