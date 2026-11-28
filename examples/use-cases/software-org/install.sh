#!/usr/bin/env bash
# Installs the software organisation use case, first agent (pod root-cause analysis), on a LOCAL kind or k3d cluster:
#
#   CLUSTER=oa-rca-demo examples/use-cases/software-org/install.sh                 offline: the quick start with the stub model and the scenarios (no key, no token)
#   CLUSTER=oa-rca-demo examples/use-cases/software-org/install.sh --real-model    the same agent on a real model: needs a provider key in the environment, sets NO scenarios
#   CLUSTER=<name> examples/use-cases/software-org/install.sh --skip-platform      only the use case objects (the platform install ran already with values.yaml)
#   VALUES_FILE="<the list you installed the full demo with>" CLUSTER=<its cluster> \
#     examples/use-cases/software-org/install.sh --beside-full-demo                add the agent to an install you have (values-full-demo.yaml, composed AFTER your list)
#   CLUSTER=<name> examples/use-cases/software-org/install.sh --uninstall          removes what this script made (not the chart values: see README, "Uninstall")
#
# There is NO default cluster: set CLUSTER (the kind or k3d cluster name) or KUBE_CONTEXT, so that a script never acts on a cluster by guess (a name like
# "openagentix" is also the name of a full demo cluster). When both are set they must name the same cluster. The script refuses any context that is not
# kind-* or k3d-* (also for --uninstall). It never deletes a cluster; the platform installer makes the local cluster when no context of that name exists.
#
# What it does, in order. Every step can be run again.
#   0. the guards above; it needs helm (a missing helm never reads as "no release"); it refuses to run the platform installer on a release that has
#      anything the values it would hand over lack (see below);
#   1. composes the values: hack/compose-values.sh merges components/quickstart/values.yaml and values.yaml by entry name and reports what the second file
#      adds and changes (with --beside-full-demo: your files merged the way Helm merges them, checked to render exactly like your list, then
#      values-full-demo.yaml composed after them);
#   2. the release check, read only: the user-supplied values of the release (helm get values) are compared with the composed values, key paths and
#      named list entries, as an ALLOWLIST. Anything the release has that the composed values do not have is refused and named. The platform installer
#      replaces the release values on every run: it would drop it. Keys the installer sets itself are not compared (image tags, source hashes, API server
#      addresses). A second run, and a second --beside-full-demo run, pass. A scenario file of another use case (the bank's scenario.json) in the release is
#      refused unless STUB_SCENARIOS gives it again: give a DIRECTORY with both files, and nothing is dropped. Only helm's exact line
#      "Error: release: not found" means no release; any other failure stops;
#   3. runs the platform installer (./install.sh) with that file. Offline: PROFILE=quickstart and STUB_SCENARIOS=eval/software-org-rca.json (ADR 0026) and
#      every provider key removed from the environment of that run, so the stub answers. With --real-model: no scenarios, and one of ANTHROPIC_API_KEY,
#      OPENAI_API_KEY, GOOGLE_API_KEY or MODEL_BASE_URL (with MODEL_NAME) is needed. With --beside-full-demo: your environment goes through as it is;
#   4. checks that the platform has what the use case needs: the agent pod-rca, cluster-read, the tool server of the profile rca;
#   5. applies manifests/rca-demo.yaml and makes the ServiceAccount openagentix-system/rca-desk (the caller of the agent; the rule is in values.yaml);
#   6. offline: checks that the stub model has the scenarios, and warns when it has not.
# This script reads no Secret: the bearer Secrets of cluster-read are made by the platform installer.
#
# Env: CLUSTER (REQUIRED unless KUBE_CONTEXT is set)  KUBE_CONTEXT (default kind-$CLUSTER; k3d-<name> is accepted)  KUBECTL  HELM
#      VALUES_FILE (--beside-full-demo only: the files of the install you have, space separated, relative to the repository root or absolute)
#      ALSO_COMPOSE (--beside-full-demo only: the values-full-demo.yaml files of other use cases installed beside yours, composed by entry name after your
#      list and before this agent's file; no detection: a use case you leave out is refused by the release check, which says to add it here)
#      PLATFORM_INSTALL (the platform installer, default ./install.sh in the repository root; a test sets a fake)  COMPOSE (compose-values.sh)
#      Any other variable of the platform installer (SKIP_*, AGENT_WAIT, STUB_SCENARIOS with --beside-full-demo, ...) goes through to it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
# No default cluster: a script that changes a cluster must be told which one.
[ -n "${CLUSTER:-}${KUBE_CONTEXT:-}" ] || { echo "ERROR: set CLUSTER (the kind cluster name) or KUBE_CONTEXT: there is no default cluster. Nothing was changed." >&2; exit 1; }
# When both are set they must name the same cluster: kubectl and the platform installer use the context, kind and k3d use the name.
if [ -n "${CLUSTER:-}" ] && [ -n "${KUBE_CONTEXT:-}" ] && [ "$KUBE_CONTEXT" != "kind-$CLUSTER" ] && [ "$KUBE_CONTEXT" != "k3d-$CLUSTER" ]; then
  echo "ERROR: CLUSTER=$CLUSTER and KUBE_CONTEXT=$KUBE_CONTEXT name different clusters (the context of $CLUSTER is kind-$CLUSTER or k3d-$CLUSTER). Set one of them, or make them agree. Nothing was changed." >&2; exit 1
fi
if [ -z "${CLUSTER:-}" ]; then CLUSTER=${KUBE_CONTEXT#kind-}; CLUSTER=${CLUSTER#k3d-}; fi
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
    -h|--help) sed -n 2,40p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
[ -z "${ALSO_COMPOSE:-}" ] || [ "$BESIDE" = 1 ] || die "ALSO_COMPOSE is for --beside-full-demo only. Nothing was changed."
if [ "$BESIDE" = 1 ] && [ -z "${VALUES_FILE:-}" ]; then
  die "--beside-full-demo needs VALUES_FILE: the same list of files you installed the full demo with. Helm replaces the release values on every run, so a list that is missing would drop what it set. Nothing was changed."
fi
# Helm reads the release (and renders for --beside-full-demo): a missing helm must stop the install, never read as "no release".
if [ "$SKIP_PLATFORM" = 0 ]; then command -v "$HELM" >/dev/null 2>&1 || die "helm is required (HELM=$HELM is not a command). Nothing was changed."; fi

ctx_exists() { local c; c=$("$KUBECTL" config get-contexts -o name 2>/dev/null) || return 1; printf '%s\n' "$c" | grep -qx "$KUBE_CONTEXT"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---- 0b. the release (read only) ----------------------------------------------------------------------------------------------------------
release_values() { # prints the user-supplied values of the release as JSON, or nothing when there is no release; fails (stopping the install) when it cannot tell
  local out err; err="$TMP/helm.err"
  ctx_exists || return 0   # no such context yet: the platform installer makes the cluster, nothing can be lost
  if ! out=$("$HELM" get values "$RELEASE" -n "$RELEASE_NS" --kube-context "$KUBE_CONTEXT" -o json 2>"$err"); then
    # only helm's own, exact line means "no such release"; any other failure (a missing command, a wrong storage driver, an unreachable cluster) stops the install
    if [ "$(cat "$err" 2>/dev/null)" = "Error: release: not found" ]; then return 0; fi   # the whole of the error, exactly: one more line is a different failure
    echo "cannot read the values of the release $RELEASE in $KUBE_CONTEXT: $(head -n 1 "$err" 2>/dev/null | cut -c1-300)" >&2
    return 1
  fi
  printf '%s' "$out"
}
release_extras() { # release_extras <json file of the values this script will hand over>: prints the paths the release has and those values lack, one per line
  local rel; rel=$(release_values) || return 1
  [ -n "$rel" ] || return 0
  printf '%s' "$rel" | jq -r --argjson beside "$BESIDE" --slurpfile exp "$1" '
    def flat($pre):
      if type == "object" then (if length == 0 then $pre + "{}" else (to_entries[] | .key as $k | .value | flat($pre + "." + $k)) end)
      elif type == "array" then (if length == 0 then $pre + "[]" else (.[] | (if type == "object" and ((.name | type) == "string") then flat($pre + "[" + .name + "]") else flat($pre + "[]") end)) end)
      else $pre end;
    # the scenario file this script ships is software-org-rca.json: it is replaced without complaint when the release holds an earlier copy. A scenario.json (the
    # bank, or another use case) and any other file stay in the list, unless STUB_SCENARIOS gives them again (they are then in the expected values).
    ([. | flat("")] | unique) - ([$exp[0] | flat("")] | unique)
    | map(select((test("^[.](bridge|scheduling|governance[.]a2a|knowledge[.]kb|notify|gateway[.]stubModel|controlPlane|console|diagnostics)[.]image[.]tag$|^[.](bridge|console|controlPlane|diagnostics|gateway[.]stubModel|governance[.]a2a|knowledge[.]kb|notify|scheduling)[.]sourceHash$|^[.](controlPlane|console|diagnostics)[.]apiServerCIDRs(\\[\\])?$|^[.]controlPlane[.]containerAgents[.]serviceAccountTokens[.]issuer$|^[.]skills[.]openagentix-canary[.]oci$|^[.]notify[.]requireReady$|^[.]gateway[.]stubModel[.]scenarios[.]files[.]software-org-rca[.]json$|^\\{\\}$") or ($beside == 0 and test("^[.]gateway[.]models\\[quickstart-model\\]|^[.]gateway[.]stubModel[.]enabled$"))) | not))
    | .[]'
}

# ---- 1. compose the values (local work only: nothing in the cluster has changed yet) --------------------------------------------
VALUES_COMPOSED="$TMP/software-org-values.yaml"; VALUES_BASE="$TMP/your-values.yaml"
if [ "$SKIP_PLATFORM" != 1 ]; then
  if [ "$BESIDE" = 1 ]; then
    say "composing the values: your list ($VALUES_FILE) first, then examples/use-cases/software-org/values-full-demo.yaml (only the diagnostics block, the profile rca, the agent pod-rca and the caller rca-desk)"
    # Your own files are merged first, the way Helm merges them (maps deep, a later file wins, a list is REPLACED by a later file), into one file. That
    # is exactly your install, so compose-values.sh must not judge it. The merge is checked instead: the chart must render byte for byte the same from
    # your list and from the merged file. Only then is values-full-demo.yaml composed after it by compose-values.sh, without --later-wins: it joins
    # the lists by name and never drops an entry of yours, and a name or a security key that clashes is refused, and nothing is installed.
    cd "$ROOT"
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
    # The values-full-demo.yaml files of the other use cases that are installed beside yours (ALSO_COMPOSE, a space separated list) go AFTER your list and
    # BEFORE this agent's file, composed by entry name. There is no detection: the release check below names what is missing when you leave one out.
    ALSO=()
    for f in ${ALSO_COMPOSE:-}; do
      [ -r "$f" ] || die "cannot read $f (ALSO_COMPOSE is read from the repository root). Nothing was changed."
      case "$(basename "$f")" in values-full-demo.yaml) ;; *) die "ALSO_COMPOSE takes the values-full-demo.yaml files of other use cases, not $f. Nothing was changed." ;; esac
    [ ! "$f" -ef "$HERE/values-full-demo.yaml" ] || die "ALSO_COMPOSE lists this use case's own values-full-demo.yaml ($f): this script composes it itself. List the files of the OTHER use cases. Nothing was changed."
      ALSO+=("$f")
    done
    "$COMPOSE" -o "$VALUES_COMPOSED" "$VALUES_BASE" ${ALSO[@]+"${ALSO[@]}"} "$HERE/values-full-demo.yaml" || die "the values did not compose (the reason is above): your install, the files of ALSO_COMPOSE and this agent do not fit together as they are. Nothing was changed."
  else
    say "composing the values (components/quickstart/values.yaml and examples/use-cases/software-org/values.yaml)"
    "$COMPOSE" -o "$VALUES_COMPOSED" "$ROOT/components/quickstart/values.yaml" "$HERE/values.yaml" || die "the values did not compose (the reason is above). Nothing was changed."
  fi

  # ---- 2. the release must not lose anything ----------------------------------------------------------------------------------
  # Compare with what this script will hand over: the composed values, and the scenario files of this run (they are --set-file, not values). With
  # --beside-full-demo that is your list plus values-full-demo.yaml, so a second run (whose release already holds this agent) is not refused, and a file
  # left out of your list still is.
  yq . "$VALUES_COMPOSED" > "$TMP/expected.json" || die "cannot read the composed values. Nothing was changed."
  SCN_SRC=""
  if [ "$BESIDE" = 1 ]; then SCN_SRC=${STUB_SCENARIOS:-}; elif [ "$REAL" = 0 ]; then SCN_SRC="$HERE/eval/software-org-rca.json"; fi
  SCN_NAMES=()
  if [ -n "$SCN_SRC" ]; then
    if [ -d "$SCN_SRC" ]; then
      while IFS= read -r f; do SCN_NAMES+=("$(basename "$f")"); done < <(find "$SCN_SRC" -maxdepth 1 \( -type f -o -type l \) -name '*.json' | LC_ALL=C sort)
    elif [ -f "$SCN_SRC" ]; then SCN_NAMES+=("$(basename "$SCN_SRC")"); fi
  fi
  for n in ${SCN_NAMES[@]+"${SCN_NAMES[@]}"}; do
    jq --arg n "$n" '.gateway.stubModel.scenarios.files[$n] = "x"' "$TMP/expected.json" > "$TMP/expected.next" && mv "$TMP/expected.next" "$TMP/expected.json"
  done
  EXTRAS=$(release_extras "$TMP/expected.json") || die "refusing to run the platform installer on a release I cannot read. Nothing was changed."
  if [ -n "$EXTRAS" ]; then
    LIST=$(printf '%s' "$EXTRAS" | head -n 20 | tr '\n' ';' | sed 's/;/; /g')
    if [ "$BESIDE" = 1 ]; then
      die "the release $RELEASE in $KUBE_CONTEXT has values that your VALUES_FILE list (and STUB_SCENARIOS) do not have: $LIST. The platform installer replaces the release values with your list plus this agent, so it would drop them. Give the same list of files, and the same STUB_SCENARIOS (a directory with every scenario file), you installed with. If the release holds another use case (the bank, equipment), add its values-full-demo.yaml to ALSO_COMPOSE. Nothing was changed."
    else
      die "the release $RELEASE in $KUBE_CONTEXT has more than the quick start and this use case: $LIST. The platform installer would replace those values and drop them. Use a cluster of its own, or add the agent to your install with: VALUES_FILE=\"<your files>\" CLUSTER=<its cluster> $0 --beside-full-demo. Nothing was changed."
    fi
  fi
  if [ "$BESIDE" = 1 ] && ! ctx_exists; then die "--beside-full-demo needs the cluster of your install to exist: no kube context '$KUBE_CONTEXT'. Nothing was changed."; fi

  # ---- 3. the platform -------------------------------------------------------------------------------------------------------
  if [ "$BESIDE" = 1 ]; then
    say "platform install beside your install: your model, your provider keys, your PROFILE and your scenarios go through as they are (nothing is unset)"
    env CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" VALUES_FILE="$VALUES_COMPOSED" "$PLATFORM_INSTALL"
  elif [ "$REAL" = 1 ]; then
    say "platform install with a real model: no scenarios are set, the stub model is off"
    env -u STUB_SCENARIOS CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" PROFILE=quickstart VALUES_FILE="$VALUES_COMPOSED" "$PLATFORM_INSTALL"
  else
    say "platform install, offline: the stub model with the scenarios of eval/software-org-rca.json (a run with them is SCRIPTED, not the behaviour of a model)"
    env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY -u MODEL_BASE_URL -u MODEL_NAME -u MODEL_PROVIDER -u MODEL_API_KEY \
      CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" PROFILE=quickstart VALUES_FILE="$VALUES_COMPOSED" STUB_SCENARIOS="$HERE/eval/software-org-rca.json" "$PLATFORM_INSTALL"
  fi
elif ! ctx_exists; then
  die "--skip-platform needs the cluster to exist: no kube context '$KUBE_CONTEXT'. Nothing was changed."
fi

# ---- 4. the platform must have what the use case needs -------------------------------------------------------------------------
"${KC[@]}" get namespace mcp-tools >/dev/null 2>&1 || die "the tool gateway namespace mcp-tools does not exist: the platform is not installed (run this script without --skip-platform)"
"${KC[@]}" get agents.api.kagent.dev pod-rca -n kagent >/dev/null 2>&1 || die "the agent pod-rca does not exist: the platform install must use examples/use-cases/software-org/values.yaml"
"${KC[@]}" get deployment cluster-read -n openagentix-diagnostics >/dev/null 2>&1 || die "cluster-read is not installed: the platform install must use examples/use-cases/software-org/values.yaml (diagnostics.enabled)"
"${KC[@]}" get virtualmcpservers.toolhive.stacklok.dev tools-rca -n mcp-tools >/dev/null 2>&1 || die "the tool server of the profile rca (VirtualMCPServer tools-rca) does not exist: the platform install must use examples/use-cases/software-org/values.yaml"
CODEMODE=$("${KC[@]}" get virtualmcpservers.toolhive.stacklok.dev tools-rca -n mcp-tools -o jsonpath='{.spec.config.codeMode.enabled}' 2>/dev/null || true)
[ "$CODEMODE" != true ] || die "the tool server of the profile rca has code mode on: a script there could chain diagnostics calls without the model. Nothing was changed."

# ---- 5. the broken workloads and the caller ------------------------------------------------------------------------------------
say "applying the namespace $NS with its six broken workloads (they are broken on purpose; the namespace enforces restricted pod security)"
"${KC[@]}" apply --server-side --force-conflicts --field-manager=openagentix-software-org -f "$HERE/manifests/rca-demo.yaml" >/dev/null
"${KC[@]}" create serviceaccount rca-desk -n "$DESK_NS" --dry-run=client -o yaml | "${KC[@]}" apply -f - >/dev/null
say "ServiceAccount $DESK_NS/rca-desk is ready (the caller rule is in values.yaml: it may ask pod-rca and nothing else)"

# ---- 6. scenarios for the stub model: checked, not made --------------------------------------------------------------------------
if [ "$BESIDE" = 1 ]; then
  say "beside your install: the agent uses the model of your install (claude-haiku); no scenario was set by this script"
elif [ "$REAL" = 1 ]; then
  say "real model: no scenario is needed. Read pass rates over several runs, not one run (README)"
elif "${KC[@]}" get deployment stub-model -n agentgateway-system >/dev/null 2>&1; then
  if SCN_CM=$("${KC[@]}" get configmap stub-model-scenarios -n agentgateway-system -o json 2>/dev/null) && printf '%s' "$SCN_CM" | jq -e '.data["software-org-rca.json"] != null' >/dev/null 2>&1; then
    say "the stub model has the scenarios from the chart (runs with them are scripted by the stub model, not the behaviour of a model)"
  else
    echo "WARN: the stub model has no software-org-rca.json, so it will not work these cases. Run the platform install again with STUB_SCENARIOS=examples/use-cases/software-org/eval/software-org-rca.json (and the same values)." >&2
  fi
else
  say "no stub model in this cluster: no scenario is needed"
fi

cat <<EOF

The pod root-cause use case is installed. The six workloads need a minute or two to show their faults. Next (CLUSTER=$CLUSTER):
  examples/use-cases/software-org/ctl.sh pods                         # wait until each workload shows its fault
  examples/use-cases/software-org/ctl.sh analyze crash-start          # ask the agent; try img-typo, oom-kill, cfg-missing-key, probe-fail, pending-selector
  examples/use-cases/software-org/ctl.sh analyze ghost-worker         # a workload that does not exist: the answer is "inconclusive"
See examples/use-cases/software-org/README.md for the demo, the evaluation, what is proven and the live proof checklist.
EOF
