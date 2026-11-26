#!/usr/bin/env bash
# OpenAgentix installer: one command, idempotent, ordered.
#   1. cluster, kind or k3s (optional)    4. build/load the bridge and kb images, build/push the example skill
#   2. prerequisites (upstream Helm)      5. helm upgrade --install openagentix charts/openagentix
#   3. Secrets from the environment       6. ingest the sample knowledge corpus (when knowledge.enabled)
#
# Required env (unless the Secret already exists in the cluster):
#   ANTHROPIC_API_KEY       provider key for the claude-haiku model (-> agentgateway-system/anthropic-api-key)
#   TELEGRAM_BOT_TOKEN      bot token for the bridge             (-> openagentix-gateway/telegram-bridge)
# Optional env:
#   TELEGRAM_ALLOWED_CHAT_IDS  comma-separated chat ids allowed to talk to the agent (the bridge refuses to start without it, unless bridge.allowlist.enabled=false)
#   GOOGLE_API_KEY             creates agentgateway-system/gemini-api-key (for a gemini model you add to values)
#   NOTIFY_TELEGRAM_CHAT_ID    only with notify.enabled: creates (when absent, never printed, kept on re-runs) the Secret holding the
#                              destination `owner-telegram` (this chat) and copies the bridge's bot token next to it. This is the opt-in:
#                              installing never creates a way for agents to message someone without it.
#   NOTIFY_OWNER_TELEGRAM=1    the same, using the FIRST id of TELEGRAM_ALLOWED_CHAT_IDS when NOTIFY_TELEGRAM_CHAT_ID is not set
# Switches (all optional):
#   CLUSTER=openagentix  CREATE_CLUSTER=1  KUBE_CONTEXT=<type>-$CLUSTER
#   CLUSTER_TYPE=kind    kind (default) or k3d (k3s in Docker; docs/diary/guide/install-k3s.md). K3D_NODE_IMAGE=rancher/k3s:v1.37.2-k3s1 picks the k3s version.
#   CLUSTER_TYPE=remote  an EXISTING cluster (for example GKE), NOT run on a managed cluster yet (docs/diary/guide/install-gke.md). KUBE_CONTEXT is
#                        required and its API server must answer; no cluster is created, kind and k3d are not needed, nothing runs on a node
#                        (no docker exec, no ctr). Refused for now, before anything changes: locally built images (a registry push is issue #162:
#                        set the SKIP_*_IMAGE switches and point the image values at a registry), QUICKSTART_BYO=1, the example skill without
#                        SKIP_SKILL=1, and MODEL_PROVIDER=ollama without MODEL_BASE_URL.
#   ALLOW_LOCAL_CONTEXT=1  with CLUSTER_TYPE=remote, accept a KUBE_CONTEXT that is the name of a local cluster (kind-*, k3d-*, docker-desktop, ...)
#   NODE_SETTINGS=daemonset  set the two node sysctls for gVisor pod networking (components/runtime/NOTES.md) with the privileged DaemonSet
#                        components/runtime/node-settings.yaml (its own namespace) instead of docker exec. Default: docker exec on kind and k3d,
#                        nothing on remote. Not proven necessary, and not run on GKE.
#   SKIP_PREREQS=1       never touch kagent/Substrate/agentgateway/ToolHive
#   FORCE_PREREQS=1      re-run the upstream installers even if their Helm releases exist (this re-applies
#                        components/runtime/values/substrate.yaml and DROPS any Substrate additions made by spikes/ax)
#   SKIP_SKILL=1         do not build/push the example skill; use the digest in values.yaml
#   SKIP_BRIDGE_IMAGE=1  do not build/load the bridge image
#   SKIP_KB_IMAGE=1      do not build/load the knowledge base image (services/kb)
#   SKIP_A2A_CALL_IMAGE=1  do not build/load the schedule caller image (tools/a2a-call); it is only built when `schedules` is not empty
#   SKIP_KB_INGEST=1     do not ingest components/knowledge/sample into collection "openagentix"
#   SKIP_NOTIFY_IMAGE=1  do not build/load the notify image (services/notify); it is only built when notify.enabled is true
#   SKIP_A2A_GATE_IMAGE=1  do not build/load the A2A gate image (services/a2a-gate); it is only built when governance.a2a.enabled is true
#   SKIP_CONTROL_PLANE_IMAGE=1  do not build/load the control plane image (services/control-plane); it is only built when controlPlane.enabled is true
#   SKIP_CONSOLE_IMAGE=1  do not build/load the console image (services/console + console); it is only built when console.enabled is true
#   CONSOLE_APISERVER_CIDRS="10.0.0.0/24 ..."  the API server addresses the console's NetworkPolicy allows (comma or space separated);
#                        default: derived like the control plane's, unless console.apiServerCIDRs is set in a values file
#   CONTROL_PLANE_APISERVER_CIDRS="10.0.0.0/24 ..."  the API server addresses the control plane's NetworkPolicy allows (comma or space separated);
#                        default: derived like Agent Kourier's (components/channels/apiserver-cidrs.sh), unless controlPlane.apiServerCIDRs is set in a values file
#   VALUES_FILE="a.yaml b.yaml"  extra values files for the chart, space-separated, applied in order (maps are merged, lists
#                        such as agents[] or schedules[] are REPLACED by the later file) (e.g. more agents, schedules, networkPolicy.extraA2ACallers for a
#                        chat gateway of your own). Helm replaces rather than merges the release values, so pass the
#                        same files on every run, or the extras disappear.
#   KOURIER_VALUES_FILE="k.yaml"  extra values for the Agent Kourier release (see components/channels/kourier-values.yaml)
#   KOURIER_APISERVER_CIDRS="10.0.0.0/24 ..."  the API server addresses Kourier's NetworkPolicy allows (comma or space separated); default: on kind the
#                        /24 of the API server's node address, elsewhere the exact endpoint addresses (components/channels/apiserver-cidrs.sh)
# Observability is opt-in too: the ONE switch is the chart value observability.enabled (components/observability/demo-values.yaml). When the chart
# renders its marker ConfigMap (openagentix-observability) this script applies the same settings to what the chart does not own: the kagent
# controller and agent runtimes (components/runtime/kagent-helm.sh, only when they differ from the release) and the Agent Kourier release.
# Channels and triggers (Agent Kourier) are opt-in. The ONE switch is the chart value channels.kourier.enabled (default false), set
# in a VALUES_FILE, e.g. VALUES_FILE=components/channels/demo-values.yaml ./install.sh . When it is true this script installs the
# pinned Kourier release (components/channels/kourier.sh, cosign-verified when cosign exists) BEFORE the chart, generates the
# Secret of each webhook connection when absent (random, never printed), and the chart admits Kourier's pod to the kagent controller.
#   RELEASE_NS=openagentix-system  AGENT_WAIT=900s
# Tool profiles and per-agent egress (ADR 0006, round 2) are opt-in too: mcp.profiles, agents[].toolProfile and agents[].egress.allow
# (components/governance/profiles-demo-values.yaml, which must come LAST in VALUES_FILE because it restates the agents list). This script
# only waits for the extra vMCP of each profile; there is nothing else to create, and no Secret.
# The A2A gate (ADR 0006, round 1) is opt-in too: the ONE switch is the chart value governance.a2a.enabled (components/governance/demo-values.yaml).
# When the chart renders the gate, this script builds and loads its image, creates one static key per Kourier binding (Secret a2a-key-<binding> in the
# channels namespace, only when absent, random, never printed) and writes the SHA-256 of each key into the gate's hash Secret (a2a-gate-keys), all
# BEFORE the single helm upgrade that also moves the callers to the gate, so no caller is ever cut off.
# The control plane (ADR 0007, slice 1) is opt-in too: the ONE switch is the chart value controlPlane.enabled (components/control-plane/demo-values.yaml,
# which needs components/governance/profiles-demo-values.yaml). When the chart renders the controller, this script builds and loads its image, passes
# the hash of its source and the API server addresses to the chart, and waits for the Deployment. It does nothing per agent: an AgentDefinition
# (components/control-plane/researcher.yaml) is applied by you, and the controller makes its key, its objects and its registration. The installer never touches
# the controller's key ConfigMap (llm-api-keys-control-plane) nor the Secrets of built agents; the CRD stays when the release is uninstalled.
# The web console (ADR 0007, slice 3) is opt-in too: the ONE switch is the chart value console.enabled (components/console/demo-values.yaml, which needs the control plane).
# When the chart renders it, this script builds its image with the REPOSITORY ROOT as the build context (docker build -f services/console/Dockerfile .: the
# Dockerfile builds the web app, so Docker and network access are needed), loads it into the cluster, passes the hash of both sources and the API server addresses to the
# chart, creates the login token Secret console-token (48 random characters, only when absent, never printed, kept on re-runs), waits for the Deployment and tells
# you how to open it (kubectl port-forward; the token is read with a command it prints, never echoed by the installer). Nobody can connect to the console
# inside the cluster, and there is no Ingress.
# Long-term memory (agents[].memory.enabled): needs pgvector in kagent's PostgreSQL; step 3b below enables it. The embedding
# ModelConfig's gateway key (Secret memory-virtual-key in the kagent namespace) is created like the agents' keys.
# The knowledge block creates (only when absent, never overwritten, so they stay stable across re-runs) the Secrets
# kb-admin, kb-postgres, kb-database and, for gateway-routed embeddings, kb-virtual-key (and, with knowledge.kb.graph.enabled, the extraction key kb-extract-key) in openagentix-knowledge.
# Secret values are never echoed, never put in argv or written to disk.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CLUSTER=${CLUSTER:-openagentix}
# shellcheck source=hack/cluster.sh
. hack/cluster.sh   # CLUSTER_TYPE=kind (default) or k3d: what differs between the two (context, node, image load, creation)
cluster_check_type || exit 1
CTX=${KUBE_CONTEXT:-$(cluster_ctx)}
export CLUSTER CLUSTER_TYPE KUBE_CONTEXT=$CTX   # the component scripts (runtime, gateway, tools) read all three
REMOTE=0; NODE=""; CLUSTER_NET=""
if [ "$CLUSTER_TYPE" = remote ]; then REMOTE=1; else NODE=$(cluster_node); CLUSTER_NET=$(cluster_network); fi   # remote: no node container, no Docker network
K=${KUBECTL:-kubectl}
RELEASE=openagentix
RELEASE_NS=${RELEASE_NS:-openagentix-system}
CHART=charts/openagentix
AGENT_WAIT=${AGENT_WAIT:-900s}
CRANE_IMAGE=${CRANE_IMAGE:-gcr.io/go-containerregistry/crane:latest}
GW_NS=agentgateway-system
BRIDGE_NS=openagentix-gateway
BRIDGE_SECRET=telegram-bridge
KAGENT_NS=kagent

t0=$(date +%s)
log(){ printf '\n=== %s (+%ss)\n' "$*" "$(( $(date +%s) - t0 ))"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# --- 0. preflight: tools and env, before anything is changed ----------------------------------------------
need=(docker "$CLUSTER_TYPE" kubectl helm jq yq openssl shasum)
[ "$REMOTE" = 0 ] || need=(docker kubectl helm jq yq openssl shasum)   # remote: no kind, no k3d
missing=(); for c in "${need[@]}"; do command -v "$c" >/dev/null || missing+=("$c"); done
[ ${#missing[@]} -eq 0 ] || die "missing tools on PATH: ${missing[*]}"

CLUSTER_UP=0; cluster_exists && CLUSTER_UP=1
# remote: an existing cluster only. Stop here when its API server does not answer (nothing is created, nothing was changed).
[ "$REMOTE" = 0 ] || [ "$CLUSTER_UP" = 1 ] || die "cannot reach the API server of kube context '$CTX' (CLUSTER_TYPE=remote never creates a cluster; check: kubectl --context $CTX get --raw /version). Nothing was changed."
secret_exists(){ [ "$CLUSTER_UP" = 1 ] && $K --context="$CTX" get secret -n "$1" "$2" >/dev/null 2>&1; }   # named context: this runs before the switch below

# The quick start (ADR 0014): PROFILE=quickstart ./install.sh, or ./install.sh --quickstart. VALUES_FILE still works and comes after the profile.
for arg in "$@"; do case "$arg" in --quickstart) PROFILE=quickstart;; --minimal) PROFILE=minimal;; *) die "unknown argument: $arg (use --quickstart, --minimal, or the environment variables in the README)";; esac; done
PROFILE=${PROFILE:-}
QS=0; QS_MODEL=""; QS_TMP=$(mktemp -d); BUILD_PID=""; trap '[ -z "$BUILD_PID" ] || kill "$BUILD_PID" 2>/dev/null; rm -rf "$QS_TMP"' EXIT
VALS=()
case "$PROFILE" in
  "") ;;
  quickstart) QS=1; VALS+=(-f components/quickstart/values.yaml) ;;
  minimal) QS=1; VALS+=(-f components/quickstart/values.yaml -f components/quickstart/minimal-values.yaml) ;;   # issue #29: no console, no observability
  *) die "unknown PROFILE '$PROFILE' (known: quickstart, minimal)" ;;
esac
# QUICKSTART_BYO=1 adds the sample container agent (examples/agents/echo-a2a, ADR 0015): the runtime is switched on, one registry prefix is allowed.
QS_BYO=0
if [ "${QUICKSTART_BYO:-0}" = 1 ]; then
  [ "$QS" = 1 ] || die "QUICKSTART_BYO=1 needs PROFILE=quickstart or PROFILE=minimal"
  [ "$REMOTE" = 0 ] || die "QUICKSTART_BYO=1 does not work with CLUSTER_TYPE=remote yet: the sample image is loaded into the node and its digest read with ctr (a registry push is issue #162). Nothing was changed."
  QS_BYO=1; VALS+=(-f components/quickstart/byo-values.yaml)
fi
for f in ${VALUES_FILE:-}; do VALS+=(-f "$f"); done
if [ "$QS" = 1 ]; then
  . components/quickstart/model.sh
  QS_MODEL=$(qs_pick_model) || die "model configuration: see the line above"
  QS_OLLAMA_HOST=host.docker.internal
  if [ "$QS_MODEL" = ollama ] && [ "$REMOTE" = 0 ] && [ "$(uname -s)" = Linux ]; then   # no host.docker.internal on Linux: the cluster's Docker network gateway
    QS_OLLAMA_HOST=$(docker network inspect "$CLUSTER_NET" -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true); QS_OLLAMA_HOST=${QS_OLLAMA_HOST:-172.18.0.1}
  fi
  qs_model_values "$QS_MODEL" "$QS_OLLAMA_HOST" > "$QS_TMP/model-values.json"
  [ ! -s "$QS_TMP/model-values.json" ] || VALS+=(-f "$QS_TMP/model-values.json")
fi

# What is required is decided from what the chart renders, before anything is created.
render(){ helm template $RELEASE $CHART -n "$RELEASE_NS" --api-versions agentkourier.dev/v1alpha1 ${VALS[@]+"${VALS[@]}"} "$@" | yq -c 'select(.!=null)'; }
RENDERED=$(render) || die "chart does not render; run: helm template $RELEASE $CHART ${VALUES_FILE:+-f $VALUES_FILE}"
. components/quickstart/preflight.sh
problems=()
while IFS= read -r p; do [ -z "$p" ] || problems+=("$p"); done < <(preflight_secret_problems "$RENDERED" secret_exists; preflight_skill_problems "$RENDERED" "${SKIP_SKILL:-0}")
if [ ${#problems[@]} -gt 0 ]; then
  printf '\nERROR: cannot start, required configuration is missing:\n' >&2
  for p in "${problems[@]}"; do printf '  - %s\n' "$p" >&2; done
  printf 'Nothing was changed.\n' >&2; exit 1
fi
if jq -e 'select(.kind=="Deployment" and .metadata.name=="telegram-bridge")' <<<"$RENDERED" >/dev/null && [ -z "${TELEGRAM_ALLOWED_CHAT_IDS:-}" ]; then
  echo "WARN: TELEGRAM_ALLOWED_CHAT_IDS not set. The bridge refuses to start without an allowlist (unless the Secret already has one, or you set bridge.allowlist.enabled=false in your values, which opens the bot to anyone)."
fi

# --- 0b. images: the builds start now and run while the cluster and the prerequisites are installed (finish_builds, below, waits) ---
# (the Deployments that decide which images are needed, from what the chart renders)
BRIDGE_IMAGE=$(jq -r 'select(.kind=="Deployment" and .metadata.name=="telegram-bridge")|.spec.template.spec.containers[0].image' <<<"$RENDERED")
KB_DEP=$(jq -c 'select(.kind=="Deployment" and .metadata.name=="kb")' <<<"$RENDERED")   # empty when knowledge.enabled=false
NOTIFY_DEP=$(jq -c 'select(.kind=="Deployment" and .metadata.name=="notify")' <<<"$RENDERED")   # empty when notify.enabled=false
A2A_GATE_DEP=$(jq -c 'select(.kind=="Deployment" and .metadata.name=="a2a-gate")' <<<"$RENDERED")   # empty when governance.a2a.enabled=false
CP_DEP=$(jq -c 'select(.kind=="Deployment" and .metadata.name=="openagentix-control-plane")' <<<"$RENDERED")   # empty when controlPlane.enabled=false
CN_DEP=$(jq -c 'select(.kind=="Deployment" and .metadata.name=="openagentix-console")' <<<"$RENDERED")   # empty when console.enabled=false

# --- 5. images ----------------------------------------------------------------------------------------------
SET=()
# Images are queued here and built in parallel by run_builds (BUILD_JOBS at a time, default 3; 1 = one after the other).
BUILD_Q=()
queue_build(){ BUILD_Q+=("$1|$2|${3:-}"); }   # image | context | optional Dockerfile
# tag_image <image var> <chart value path> <source dir>...: retag the image with dev-<hash of its source> and hand the tag to the chart.
# kind load and k3d image import keep an existing tag on the node, so a fixed ":dev" would leave the OLD image running after a source change (hack/image-tag.sh).
# shellcheck source=hack/image-tag.sh
. hack/image-tag.sh
tag_image(){ local v=$1 path=$2 t; shift 2; t=$(src_tag "$@"); printf -v "$v" '%s:%s' "${!v%:*}" "$t"; SET+=(--set-string "$path.image.tag=$t"); }
# The builds do not need the cluster, so start_builds runs them in the background right away (BUILD_JOBS at a time) while the cluster and the
# prerequisites are installed (issue #29: the builds were about 100 s of a serial install). finish_builds waits for them and loads the images.
BUILD_PID=""; BUILD_STATUS="$QS_TMP/build.status"
start_builds(){
  [ ${#BUILD_Q[@]} -gt 0 ] || return 0
  local jobs=${BUILD_JOBS:-3}
  log "building ${#BUILD_Q[@]} image(s), $jobs at a time, in the background"
  (
    local spec img ctx df running=0 pids=() p fail=0   # no `wait -n`: macOS ships bash 3.2
    for spec in "${BUILD_Q[@]}"; do
      IFS='|' read -r img ctx df <<<"$spec"
      ( docker build -q -t "$img" ${df:+-f "$df"} "$ctx" >/dev/null ) &
      pids+=($!); running=$((running+1))
      if [ "$running" -ge "$jobs" ]; then for p in "${pids[@]}"; do wait "$p" || fail=1; done; pids=(); running=0; fi
    done
    for p in ${pids[@]+"${pids[@]}"}; do wait "$p" || fail=1; done
    echo "$fail" > "$BUILD_STATUS"
  ) &
  BUILD_PID=$!
}
finish_builds(){
  [ ${#BUILD_Q[@]} -gt 0 ] || return 0
  local spec img imgs=() fail=0
  log "images: waiting for the background builds"
  wait "$BUILD_PID" || fail=1
  BUILD_PID=""
  [ "$(cat "$BUILD_STATUS" 2>/dev/null || echo 1)" = 0 ] || fail=1
  for spec in "${BUILD_Q[@]}"; do imgs+=("${spec%%|*}"); done
  for img in "${imgs[@]}"; do docker image inspect "$img" >/dev/null 2>&1 || fail=1; done
  [ "$fail" = 0 ] || die "an image build failed: re-run with BUILD_JOBS=1 to see which one"
  cluster_load_images "${imgs[@]}"
}
if [ "${SKIP_BRIDGE_IMAGE:-0}" != 1 ] && [[ "$BRIDGE_IMAGE" == openagentix/telegram-bridge:* ]]; then
  tag_image BRIDGE_IMAGE bridge bridges/telegram
  log "bridge image $BRIDGE_IMAGE"
  queue_build "$BRIDGE_IMAGE" bridges/telegram
fi
# Schedules: the CronJobs run tools/a2a-call. The image is built only when the chart renders a CronJob for it (empty `schedules` = no
# build, no namespace, no pods), then keyed on the source hash like the bridge and the kb.
A2A_CALL_IMAGE=$(jq -r 'select(.kind=="CronJob")|.spec.jobTemplate.spec.template.spec.containers[0].image' <<<"$RENDERED" | sort -u | head -1)
if [ "${SKIP_A2A_CALL_IMAGE:-0}" != 1 ] && [[ "$A2A_CALL_IMAGE" == openagentix/a2a-call:* ]]; then
  tag_image A2A_CALL_IMAGE scheduling tools/a2a-call
  log "a2a-call image $A2A_CALL_IMAGE (schedules)"
  queue_build "$A2A_CALL_IMAGE" tools/a2a-call
fi
KB_IMAGE=$(jq -r '.spec.template.spec.containers[0].image' <<<"${KB_DEP:-null}" 2>/dev/null || true)
if [ "${SKIP_KB_IMAGE:-0}" != 1 ] && [[ "$KB_IMAGE" == openagentix/kb:* ]]; then
  tag_image KB_IMAGE knowledge.kb services/kb
  log "kb image $KB_IMAGE"
  queue_build "$KB_IMAGE" services/kb
fi
NOTIFY_IMAGE=$(jq -r '.spec.template.spec.containers[0].image' <<<"${NOTIFY_DEP:-null}" 2>/dev/null || true)
if [ "${SKIP_NOTIFY_IMAGE:-0}" != 1 ] && [[ "$NOTIFY_IMAGE" == openagentix/notify:* ]]; then
  tag_image NOTIFY_IMAGE notify services/notify
  log "notify image $NOTIFY_IMAGE"
  queue_build "$NOTIFY_IMAGE" services/notify
fi
A2A_GATE_IMAGE=$(jq -r '.spec.template.spec.containers[0].image' <<<"${A2A_GATE_DEP:-null}" 2>/dev/null || true)
if [ "${SKIP_A2A_GATE_IMAGE:-0}" != 1 ] && [[ "$A2A_GATE_IMAGE" == openagentix/a2a-gate:* ]]; then
  tag_image A2A_GATE_IMAGE governance.a2a services/a2a-gate
  log "a2a-gate image $A2A_GATE_IMAGE"
  queue_build "$A2A_GATE_IMAGE" services/a2a-gate
fi
STUB_IMAGE=$(jq -r 'select(.kind=="Deployment" and .metadata.name=="stub-model")|.spec.template.spec.containers[0].image' <<<"$RENDERED")   # empty when gateway.stubModel.enabled=false
if [ "${SKIP_STUB_MODEL_IMAGE:-0}" != 1 ] && [[ "$STUB_IMAGE" == openagentix/stub-model:* ]]; then
  tag_image STUB_IMAGE gateway.stubModel services/stub-model
  log "stub-model image $STUB_IMAGE"
  queue_build "$STUB_IMAGE" services/stub-model
fi
CP_IMAGE=$(jq -r '.spec.template.spec.containers[0].image' <<<"${CP_DEP:-null}" 2>/dev/null || true)
if [ "${SKIP_CONTROL_PLANE_IMAGE:-0}" != 1 ] && [[ "$CP_IMAGE" == openagentix/control-plane:* ]]; then
  tag_image CP_IMAGE controlPlane services/control-plane
  log "control-plane image $CP_IMAGE"
  queue_build "$CP_IMAGE" services/control-plane
fi
CN_IMAGE=$(jq -r '.spec.template.spec.containers[0].image' <<<"${CN_DEP:-null}" 2>/dev/null || true)
if [ "${SKIP_CONSOLE_IMAGE:-0}" != 1 ] && [[ "$CN_IMAGE" == openagentix/console:* ]]; then
  tag_image CN_IMAGE console services/console console
  log "console image $CN_IMAGE (build context: the repository root; it builds the web app inside Docker)"
  queue_build "$CN_IMAGE" . services/console/Dockerfile
fi
if [ "$QS_BYO" = 1 ]; then
  BYO_REPO=registry.local/oa/echo-a2a
  BYO_IMAGE="$BYO_REPO:$(src_tag examples/agents/echo-a2a)"
  queue_build "$BYO_IMAGE" examples/agents/echo-a2a
  log "sample container agent image $BYO_IMAGE"
fi
# Fail before the builds start, not after: no cluster and no permission to make one.
if [ "$REMOTE" = 1 ]; then   # remote: no step that needs the local Docker network or a node shell (issue #161)
  if [ "${SKIP_SKILL:-0}" != 1 ] && jq -e 'select(.kind=="AgentTemplate")|.spec.skills[]?|select(.source.oci|test("/skills/openagentix-canary@"))' <<<"$RENDERED" >/dev/null; then
    die "CLUSTER_TYPE=remote: the example skill is pushed to a registry container on the local Docker network, which a remote cluster cannot reach. Push it to a registry yourself, set skills.openagentix-canary.oci in a values file and SKIP_SKILL=1, or leave the skill out. Nothing was changed."
  fi
  if [ ${#BUILD_Q[@]} -gt 0 ]; then
    rimgs=(); for spec in "${BUILD_Q[@]}"; do rimgs+=("${spec%%|*}"); done
    die "CLUSTER_TYPE=remote cannot load locally built images into the nodes yet (a registry push, IMAGE_REGISTRY, issue #162, is not built). These would be built: ${rimgs[*]}. Set the matching SKIP_*_IMAGE=1 and point the chart's image values at a registry the nodes can pull from. Nothing was changed."
  fi
fi
[ "$CLUSTER_UP" = 1 ] || [ "${CREATE_CLUSTER:-1}" = 1 ] || die "$CLUSTER_TYPE cluster '$CLUSTER' does not exist and CREATE_CLUSTER=0"
start_builds

# --- 1. cluster (kind, or k3s through k3d) ------------------------------------------------------------------------------------
log "cluster $CLUSTER"
if [ "$CLUSTER_UP" = 0 ]; then
  [ "${CREATE_CLUSTER:-1}" = 1 ] || die "$CLUSTER_TYPE cluster '$CLUSTER' does not exist and CREATE_CLUSTER=0"
  cluster_create "$ROOT"
fi
$K config use-context "$CTX" >/dev/null || die "kube context $CTX not found"
# gVisor pod networking (components/runtime/NOTES.md): kind and k3d set two node sysctls with docker exec; remote skips them, or uses the
# DaemonSet components/runtime/node-settings.yaml with NODE_SETTINGS=daemonset (hack/cluster.sh)
cluster_node_settings "$ROOT"

# --- 2. prerequisites: reuse the component scripts, pinned versions live in those scripts ---------------------
helm_has(){ helm status "$1" -n "$2" >/dev/null 2>&1; }
want(){ [ "${SKIP_PREREQS:-0}" != 1 ] && { [ "${FORCE_PREREQS:-0}" = 1 ] || ! "$@"; }; }
log "prerequisites"
# kagent + Substrate, agentgateway and ToolHive do not depend on each other, so by default (PREREQS_PARALLEL=1; 0 = one after the other) the
# last two are installed in the background while kagent + Substrate (the longest) is installed in the foreground. Each background job has its
# own copy of the kubeconfig (two kubectl calls that switch the context at the same time can fail on the kubeconfig lock file) and its own
# log, which is printed when the job ends. A failed job stops the install.
PQ_PIDS=(); PQ_NAMES=()
prereq_bg(){   # name, then the command: run it in the background with a private kubeconfig and log
  local name=$1; shift; local kc="$QS_TMP/kubeconfig-$name"
  $K config view --raw --minify --flatten > "$kc"
  ( KUBECONFIG="$kc" "$@" ) > "$QS_TMP/prereq-$name.log" 2>&1 &
  PQ_PIDS+=($!); PQ_NAMES+=("$name")
}
prereq_wait(){
  local n=0 name fail=0
  for pid in ${PQ_PIDS[@]+"${PQ_PIDS[@]}"}; do
    name=${PQ_NAMES[$n]}; n=$((n+1))
    if wait "$pid"; then echo "-> $name finished"; else echo "ERROR: $name failed" >&2; fail=1; fi
    cat "$QS_TMP/prereq-$name.log"
  done
  PQ_PIDS=(); PQ_NAMES=()
  [ "$fail" = 0 ] || die "a prerequisite failed (see its log above); re-run with PREREQS_PARALLEL=0 to run them one after the other"
}
PARALLEL=0; [ "${PREREQS_PARALLEL:-1}" = 1 ] && PARALLEL=1
if want bash -c "$(declare -f helm_has); helm_has agentgateway $GW_NS"; then
  if [ "$PARALLEL" = 1 ]; then
    echo "-> Gateway API CRDs + agentgateway v1.7.0 (components/model-gateway/install.sh), in the background"
    prereq_bg agentgateway env PREREQS_ONLY=1 bash components/model-gateway/install.sh
  fi
  RUN_GW=1
else echo "agentgateway: present or skipped"; RUN_GW=0; fi
if want bash -c "$(declare -f helm_has); helm_has toolhive-operator toolhive-system"; then
  if [ "$PARALLEL" = 1 ]; then
    echo "-> ToolHive 0.67.1 (components/tools/install.sh), in the background"
    prereq_bg toolhive env PREREQS_ONLY=1 bash components/tools/install.sh
  fi
  RUN_TH=1
else echo "ToolHive: present or skipped"; RUN_TH=0; fi
if want bash -c "$(declare -f helm_has); helm_has kagent $KAGENT_NS && helm_has substrate ate-system"; then
  echo "-> kagent 1.0.1 + Agent Substrate 1.0.1 (components/runtime/up.sh)"
  SKIP_FIRST_AGENT=1 bash components/runtime/up.sh
else echo "kagent + Substrate: present or skipped"; fi
if [ "$PARALLEL" = 1 ]; then
  prereq_wait
else
  if [ "$RUN_GW" = 1 ]; then
    echo "-> Gateway API CRDs + agentgateway v1.7.0 (components/model-gateway/install.sh)"
    PREREQS_ONLY=1 bash components/model-gateway/install.sh
  fi
  if [ "$RUN_TH" = 1 ]; then
    echo "-> ToolHive 0.67.1 (components/tools/install.sh)"
    PREREQS_ONLY=1 bash components/tools/install.sh
  fi
fi
$K config use-context "$CTX" >/dev/null

# --- 3. what will the chart render? (agents, namespaces, images) -------------------------------------------
# --api-versions: the Agent Kourier CRDs are installed later in this run, but the objects they define must be planned now.
AGENT_KEYS=$(jq -r 'select(.kind=="ModelConfig")|[.metadata.annotations["openagentix.io/agent"],.spec.apiKeySecret,.metadata.namespace]|@tsv' <<<"$RENDERED")
# (not the namespaces the chart renders itself as a Namespace object, such as the container agents' workload namespace: Helm must create those, or it cannot adopt them)
NAMESPACES=$(jq -rs '[.[]|select(.kind=="Namespace")|.metadata.name] as $own | [.[]|select(.metadata.namespace!=null)|.metadata.namespace]|unique|.[]|select(. as $n|($own|index($n))|not)' <<<"$RENDERED")
# Consumers other than agents that need their own gateway virtual key (the kb, for embeddings): "user<TAB>secret<TAB>ns"
# A Deployment asks for one key per annotation SET: openagentix.io/gateway-user<sfx> (the user id), gateway-key-secret<sfx> (the Secret) and,
# optionally, gateway-key-name<sfx> (the Secret key, default OPENAI_API_KEY); <sfx> is empty for the first set, "-extract" for the kb's
# extraction key. Annotation names are unique per object, so a second key on one Deployment needs a second suffix: the earlier one-pair lookup
# is the same expression with an empty suffix.
KB_KEY=$(jq -r 'select(.kind=="Deployment")|.metadata as $m|($m.annotations//{})|to_entries[]|select(.key|test("^openagentix.io/gateway-user(-.+)?$"))|select(.value!="")|(.key|ltrimstr("openagentix.io/gateway-user")) as $sfx|[.value,$m.annotations["openagentix.io/gateway-key-secret"+$sfx],$m.namespace,($m.annotations["openagentix.io/gateway-key-name"+$sfx]//"OPENAI_API_KEY")]|@tsv' <<<"$RENDERED")
[ -z "$KB_KEY" ] || AGENT_KEYS=$(printf '%s\n%s' "$AGENT_KEYS" "$KB_KEY")

# --- 3b. long-term memory needs pgvector in kagent's PostgreSQL and config.database.vectorEnabled=true ------------------
# Only when some agent opts in (Harness spec.kagent.memory). Fresh installs get both from components/runtime/up.sh; this step
# brings an existing cluster up to date with the SAME scripts (pgvector.sh is idempotent, kagent-helm.sh is the one
# helm command that always carries values/kagent.yaml). It never touches kagent data. SKIP_PREREQS=1 skips it.
if [ "${SKIP_PREREQS:-0}" != 1 ] && jq -e -s 'any(.[]; .kind=="Harness" and (.spec.kagent.memory!=null))' <<<"$RENDERED" >/dev/null; then
  log "kagent long-term memory prerequisites (pgvector)"
  bash components/runtime/pgvector.sh
  if [ "$(helm get values kagent -n $KAGENT_NS -a -o json | jq -r '.config.database.vectorEnabled // false')" = true ]; then
    echo "kagent release: config.database.vectorEnabled already true"
  else
    echo "-> enabling config.database.vectorEnabled (components/runtime/kagent-helm.sh)"
    bash components/runtime/kagent-helm.sh
  fi
fi

# --- 3c. observability: kagent controller + agent runtimes, from the chart's marker ConfigMap ----------------------------------
# Desired state is computed from the same values the chart used (one switch). The kagent release is only touched when its
# telemetry settings differ from that state, in either direction (off removes them), so a re-run changes nothing.
OBS_CM=$(jq -c 'select(.kind=="ConfigMap" and .metadata.name=="openagentix-observability")' <<<"$RENDERED")
OBS_KOURIER_FILE=""
if [ "${SKIP_PREREQS:-0}" != 1 ] && helm_has kagent $KAGENT_NS; then
  if [ -n "$OBS_CM" ]; then
    O_EP=$(jq -r '.data.otlpEndpoint' <<<"$OBS_CM"); O_PROTO=$(jq -r '.data.otlpProtocol' <<<"$OBS_CM")
    O_TRACES=$(jq -r '.data.runtimeTraces' <<<"$OBS_CM"); O_CAP=$(jq -r '.data.captureContent' <<<"$OBS_CM"); O_BAG=$(jq -r '.data.baggage' <<<"$OBS_CM")
    O_PROP=$(jq -r '.data.propagators' <<<"$OBS_CM")
    # kagent: an http/protobuf FILE endpoint carries the signal path; grpc takes host:port as is.
    if [ "$O_PROTO" = grpc ]; then O_FILE_EP="$O_EP"; else O_FILE_EP="${O_EP%/}/v1/traces"; fi
    OBS_WANT=$(jq -nc --arg ep "$O_FILE_EP" --arg proto "$O_PROTO" --argjson on "$O_TRACES" --argjson cap "$O_CAP" --argjson bag "$O_BAG" --arg prop "$O_PROP" '
      if $on then {config:{telemetry:{traces:{endpoint:$ep,protocol:$proto}},
                           runtimeDefaults:{telemetry:{traces:{endpoint:$ep,protocol:$proto},captureContent:$cap}}}}
                  + (if $bag then {controller:{env:[{name:"OTEL_PROPAGATORS",value:$prop}]}} else {} end)
      else {} end')
  else
    OBS_WANT='{}'
  fi
  OBS_NORM='{t:(.config.telemetry//{}), r:(.config.runtimeDefaults.telemetry//{}), e:([.controller.env[]?|select(.name=="OTEL_PROPAGATORS")])}'
  OBS_HAVE=$(helm get values kagent -n $KAGENT_NS -o json | jq -cS "$OBS_NORM")
  OBS_WANT_N=$(jq -cS "$OBS_NORM" <<<"$OBS_WANT")
  if [ "$OBS_HAVE" = "$OBS_WANT_N" ]; then
    echo "kagent release: telemetry settings already as wanted"
  else
    log "kagent telemetry settings (components/runtime/kagent-helm.sh)"
    OBS_T=$(mktemp -d)
    jq -c . <<<"$OBS_WANT" > "$OBS_T/telemetry.json"
    if [ "$OBS_WANT" = '{}' ]; then bash components/runtime/kagent-helm.sh; else KAGENT_EXTRA_VALUES="$OBS_T/telemetry.json" bash components/runtime/kagent-helm.sh; fi
    rm -rf "$OBS_T"
  fi
fi
if [ -n "$OBS_CM" ]; then   # Agent Kourier: OTLP env and who may scrape / be reached (merged into its release values by kourier.sh)
  OBS_T=$(mktemp -d)
  jq -n --argjson env "$(jq -c '.data.kourierEnv|fromjson' <<<"$OBS_CM")" --argjson from "$(jq -c '.data.kourierMetricsFrom|fromjson' <<<"$OBS_CM")" --argjson eg "$(jq -c '.data.kourierEgress|fromjson' <<<"$OBS_CM")" \
    '(if ($env|length)>0 then {extraEnv:$env} else {} end) + (if ($from|length)>0 then {networkPolicy:{metricsFrom:$from}} else {} end)' > "$OBS_T/kourier-obs.json"
  # extraEgress is set by kourier.sh from the chart (KOURIER_EGRESS); add the OTLP rule to that same list.
  OBS_KOURIER_EGRESS=$(jq -c '.data.kourierEgress|fromjson' <<<"$OBS_CM")
  OBS_KOURIER_FILE="$OBS_T/kourier-obs.json"
fi

for ns in $RELEASE_NS $NAMESPACES; do
  $K get namespace "$ns" >/dev/null 2>&1 || $K create namespace "$ns" >/dev/null
done

# --- 4. secrets (values from env only) ------------------------------------------------------------------------
# put_secret ns name key ENVVAR: server-side apply with one field manager per key, so keys do not clobber each
# other and no last-applied annotation (which would contain the value) is written. Skipped when ENVVAR is unset.
put_secret(){
  local ns=$1 name=$2 key=$3 var=$4
  [ -n "${!var:-}" ] || return 0
  $K create secret generic "$name" -n "$ns" --from-file="$key"=<(printf '%s' "${!var}") --dry-run=client -o yaml \
    | $K apply --server-side --force-conflicts --field-manager="openagentix-$key" -f - >/dev/null
  echo "secret $ns/$name key $key applied from \$$var"
}
log "secrets"
put_secret $GW_NS anthropic-api-key Authorization ANTHROPIC_API_KEY    # key name must be 'Authorization'
put_secret $GW_NS gemini-api-key Authorization GOOGLE_API_KEY
put_secret $GW_NS openai-api-key Authorization OPENAI_API_KEY
put_secret $GW_NS quickstart-model-key Authorization MODEL_API_KEY
put_secret $BRIDGE_NS $BRIDGE_SECRET TELEGRAM_BOT_TOKEN TELEGRAM_BOT_TOKEN
put_secret $BRIDGE_NS $BRIDGE_SECRET TELEGRAM_ALLOWED_CHAT_IDS TELEGRAM_ALLOWED_CHAT_IDS

mk_random_secret(){  # ns name key [bytes]: created only if absent, value from openssl, never printed
  $K get secret -n "$1" "$2" >/dev/null 2>&1 && { echo "secret $1/$2: kept"; return 0; }
  $K create secret generic "$2" -n "$1" --from-file="$3"=<(printf '%s' "$(openssl rand -hex "${4:-24}")") >/dev/null && echo "secret $1/$2 key $3: generated"
}

# Knowledge base Secrets: each is created only if absent (so re-runs never rotate a password or token), values come
# from openssl and are never printed. kb-database is built from the kb-postgres password.
if [ -n "$KB_DEP" ]; then
  KB_NS=$(jq -r '.metadata.namespace' <<<"$KB_DEP")
  kb_secret_ref(){ jq -r --arg v "$1" '.spec.template.spec.containers[0].env[]|select(.name==$v)|.valueFrom.secretKeyRef|[.name,.key]|@tsv' <<<"$KB_DEP"; }
  IFS=$'\t' read -r ADM_S ADM_K <<<"$(kb_secret_ref KB_ADMIN_TOKEN)"
  IFS=$'\t' read -r DB_S DB_K <<<"$(kb_secret_ref KB_DATABASE_URL)"
  mk_random_secret "$KB_NS" "$ADM_S" "$ADM_K"
  PG_SS=$(jq -c 'select(.kind=="StatefulSet" and .metadata.name=="kb-postgres")' <<<"$RENDERED")
  if [ -n "$PG_SS" ]; then
    PG_S=$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="POSTGRES_PASSWORD")|.valueFrom.secretKeyRef.name' <<<"$PG_SS")
    PG_K=$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="POSTGRES_PASSWORD")|.valueFrom.secretKeyRef.key' <<<"$PG_SS")
    PG_U=$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="POSTGRES_USER")|.value' <<<"$PG_SS")
    PG_D=$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="POSTGRES_DB")|.value' <<<"$PG_SS")
    mk_random_secret "$KB_NS" "$PG_S" "$PG_K"
    if $K get secret -n "$KB_NS" "$DB_S" >/dev/null 2>&1; then echo "secret $KB_NS/$DB_S: kept"; else
      PGPW=$($K get secret -n "$KB_NS" "$PG_S" -o jsonpath="{.data.$PG_K}" | base64 -d)
      $K create secret generic "$DB_S" -n "$KB_NS" --from-file="$DB_K"=<(printf 'postgres://%s:%s@kb-postgres.%s.svc.cluster.local:5432/%s?sslmode=disable' "$PG_U" "$PGPW" "$KB_NS" "$PG_D") >/dev/null
      unset PGPW; echo "secret $KB_NS/$DB_S key $DB_K: generated"
    fi
  else
    $K get secret -n "$KB_NS" "$DB_S" >/dev/null 2>&1 || echo "WARN: knowledge.postgres.enabled=false and Secret $KB_NS/$DB_S does not exist: create it with the URL of your PostgreSQL (pgvector)"
  fi
fi

# One virtual key per agent (and per other gateway consumer, the kb), so gateway logs/metrics/budgets are attributed per agent. The raw key lives only in
# Secret <ns>/<agent>-virtual-key; the gateway ConfigMap llm-api-keys holds SHA-256 hashes.
NOTIFY_NO_DEST=0
if [ -n "$NOTIFY_DEP" ]; then
  log "notify destinations"
  N_NS=$(jq -r '.metadata.namespace' <<<"$NOTIFY_DEP")
  N_DEST_S=$(jq -r '.spec.template.spec.volumes[]|select(.name=="destinations")|.secret.secretName' <<<"$NOTIFY_DEP")
  N_DEST_K=$(jq -r '.spec.template.spec.volumes[]|select(.name=="destinations")|.secret.items[0].key' <<<"$NOTIFY_DEP")
  IFS=$'\t' read -r N_TOK_S N_TOK_K <<<"$(jq -r '.spec.template.spec.containers[0].env[]|select(.name=="NOTIFY_TELEGRAM_TOKEN")|.valueFrom.secretKeyRef|[.name,.key]|@tsv' <<<"$NOTIFY_DEP")"
  # The owner's chat id is personal data: it goes only into the destinations Secret, from the environment, never to output or files.
  # Creating a way for agents to message someone is deliberate: an explicit NOTIFY_TELEGRAM_CHAT_ID, or NOTIFY_OWNER_TELEGRAM=1
  # (use the first id of TELEGRAM_ALLOWED_CHAT_IDS). Without either, nothing is created.
  N_CREATED=0
  if $K get secret -n "$N_NS" "$N_DEST_S" >/dev/null 2>&1; then
    echo "secret $N_NS/$N_DEST_S: kept"
  else
    N_CHAT=${NOTIFY_TELEGRAM_CHAT_ID:-}
    if [ -z "$N_CHAT" ] && [ "${NOTIFY_OWNER_TELEGRAM:-0}" = 1 ]; then
      N_CHAT=${TELEGRAM_ALLOWED_CHAT_IDS:-$($K get secret -n $BRIDGE_NS $BRIDGE_SECRET -o jsonpath='{.data.TELEGRAM_ALLOWED_CHAT_IDS}' 2>/dev/null | base64 -d 2>/dev/null || true)}
      N_CHAT=${N_CHAT%%,*}; N_CHAT=${N_CHAT// /}
    fi
    if [ -z "$N_CHAT" ]; then
      echo "notify: no destination configured (set NOTIFY_TELEGRAM_CHAT_ID, or NOTIFY_OWNER_TELEGRAM=1 to use the first TELEGRAM_ALLOWED_CHAT_IDS entry). The service runs and refuses every notify call."
    elif [ -z "$N_TOK_S" ]; then
      echo "WARN: notify has no NOTIFY_TELEGRAM_TOKEN env var in these values (notify.tokens): not creating the owner-telegram destination"
    else
      [[ "$N_CHAT" =~ ^-?[0-9]+$ ]] || die "the notify chat id must be a number (NOTIFY_TELEGRAM_CHAT_ID)"
      $K create secret generic "$N_DEST_S" -n "$N_NS" --from-file="$N_DEST_K"=<(printf 'destinations:\n  - name: owner-telegram\n    description: "The platform owner'"'"'s Telegram chat"\n    platform: telegram\n    chatId: "%s"\n    tokenEnv: NOTIFY_TELEGRAM_TOKEN\n' "$N_CHAT") >/dev/null \
        && { echo "secret $N_NS/$N_DEST_S key $N_DEST_K: created with destination owner-telegram"; N_CREATED=1; }
    fi
    unset N_CHAT
  fi
  # The bot token is copied (a Secret cannot be mounted across namespaces) when this run created the destination, or when an
  # existing destinations file has owner-telegram and the copy is missing. Never printed.
  N_DEST_YAML=$($K get secret -n "$N_NS" "$N_DEST_S" -o json 2>/dev/null | jq -r --arg k "$N_DEST_K" '.data[$k]//""' | base64 -d 2>/dev/null || true)
  if [ -n "$N_TOK_S" ] && ! $K get secret -n "$N_NS" "$N_TOK_S" >/dev/null 2>&1 \
     && { [ "$N_CREATED" = 1 ] || yq -e '.destinations[]|select(.name=="owner-telegram")' >/dev/null 2>&1 <<<"$N_DEST_YAML"; }; then
    N_TOKEN=$($K get secret -n $BRIDGE_NS $BRIDGE_SECRET -o jsonpath='{.data.TELEGRAM_BOT_TOKEN}' | base64 -d)
    $K create secret generic "$N_TOK_S" -n "$N_NS" --from-file="$N_TOK_K"=<(printf '%s' "$N_TOKEN") >/dev/null && echo "secret $N_NS/$N_TOK_S key $N_TOK_K: copied from $BRIDGE_NS/$BRIDGE_SECRET"
    unset N_TOKEN
  fi
  [ "$(yq '.destinations|length' <<<"${N_DEST_YAML:-}" 2>/dev/null || echo 0)" -gt 0 ] 2>/dev/null || NOTIFY_NO_DEST=1
  unset N_DEST_YAML
fi

CM_ARGS=()
while IFS=$'\t' read -r agent secret ns vkey; do
  [ -n "$agent" ] || continue
  vkey=${vkey:-OPENAI_API_KEY}
  $K get secret -n "$ns" "$secret" >/dev/null 2>&1 || \
    $K create secret generic "$secret" -n "$ns" --from-file="$vkey"=<(printf 'vk-%s' "$(openssl rand -hex 16)") >/dev/null
  h=$($K get secret -n "$ns" "$secret" -o jsonpath="{.data.${vkey//./\\.}}" | base64 -d | shasum -a 256 | awk '{print "sha256:"$1}')
  CM_ARGS+=(--from-literal="$agent={\"keyHash\":\"$h\",\"metadata\":{\"user_id\":\"$agent\"}}")
  echo "virtual key for agent '$agent': Secret $ns/$secret"
done <<<"$AGENT_KEYS"
if [ ${#CM_ARGS[@]} -gt 0 ]; then
  $K create configmap llm-api-keys -n $GW_NS "${CM_ARGS[@]}" --dry-run=client -o yaml \
    | $K label --local -f - agentgateway.dev/apikey=true -o yaml | $K apply -f - >/dev/null
  echo "ConfigMap $GW_NS/llm-api-keys: ${#CM_ARGS[@]} hashed key(s)"
fi

# --- 4b. trust anchor for the vMCP's OIDC validation -------------------------------------------------------------
# The vMCP verifies Substrate actor JWTs against https://idp.ate-system.svc, whose TLS certificate is signed by
# Substrate's service-dns CA. Copy that CA (public certificate, not a key) into the ConfigMap the chart references.
CA_REF=$(jq -r 'select(.kind=="MCPOIDCConfig")|.spec.inline.caBundleRef.configMapRef|[.name,.key]|@tsv' <<<"$RENDERED" | head -1)
if [ -n "$CA_REF" ]; then
  log "IdP CA bundle for the vMCP"
  IFS=$'\t' read -r CA_CM CA_KEY <<<"$CA_REF"
  CA_NS=$(jq -r 'select(.kind=="MCPOIDCConfig")|.metadata.namespace' <<<"$RENDERED" | head -1)
  CTB=${IDP_CTB:-servicedns.podcert.ate.dev:identity:primary-bundle}
  CA_PEM=$($K get clustertrustbundle "$CTB" -o jsonpath='{.spec.trustBundle}' 2>/dev/null) || CA_PEM=""
  [ -n "$CA_PEM" ] || die "ClusterTrustBundle $CTB not found or empty (is Substrate installed?). Set mcp.virtual.incomingAuth.type=anonymous to skip OIDC."
  $K create configmap "$CA_CM" -n "$CA_NS" --from-file="$CA_KEY"=<(printf '%s\n' "$CA_PEM") --dry-run=client -o yaml | $K apply -f - >/dev/null
  echo "ConfigMap $CA_NS/$CA_CM key $CA_KEY from ClusterTrustBundle $CTB"
fi

# --- 4c. channels and triggers (Agent Kourier), only when the chart renders the marker (channels.kourier.enabled) ------------
CH_CM=$(jq -c 'select(.kind=="ConfigMap" and .metadata.name=="openagentix-channels")' <<<"$RENDERED")
if [ -n "$CH_CM" ]; then
  log "channels and triggers (Agent Kourier)"
  CH_NS=$(jq -r '.data.namespace' <<<"$CH_CM"); CH_BROKER_NS=$(jq -r '.data.brokerNamespace' <<<"$CH_CM")
  # Webhook connections: the Secret key follows the verify scheme (hmac-sha256: webhookSecret, token: token). Slack Secrets hold the
  # operator's own tokens: only checked, never created here.
  while IFS=$'\t' read -r cplat csec cscheme; do
    [ -n "$csec" ] || continue
    if [ "$cplat" = webhook ]; then
      case "$cscheme" in token) ckey=token;; *) ckey=webhookSecret;; esac
      mk_random_secret "$CH_NS" "$csec" "$ckey" 32
    else
      $K get secret -n "$CH_NS" "$csec" >/dev/null 2>&1 || echo "WARN: Secret $CH_NS/$csec for the $cplat connection does not exist: create it first (README \"Channels and triggers\", keys botToken and appToken)"
    fi
  done < <(jq -r 'select(.kind=="ChatConnection")|[.spec.platform,.spec.credentialsSecretRef.name,(.spec.webhook.verify.scheme//"")]|@tsv' <<<"$RENDERED")
  KOURIER_EGRESS_ALL=$(jq -c --argjson more "${OBS_KOURIER_EGRESS:-[]}" '.data.brokerEgress|fromjson + $more' <<<"$CH_CM")
  KOURIER_TEAM_NS="$CH_NS" KOURIER_NS="$CH_BROKER_NS" KOURIER_EGRESS="$KOURIER_EGRESS_ALL" KOURIER_VALUES_FILE="${KOURIER_VALUES_FILE:-}${OBS_KOURIER_FILE:+ $OBS_KOURIER_FILE}" \
    CLUSTER="$CLUSTER" KUBE_CONTEXT="$CTX" KUBECTL="$K" bash components/channels/kourier.sh install
elif helm status agent-kourier -n agent-kourier >/dev/null 2>&1; then
  echo "NOTE: Agent Kourier is installed but channels.kourier.enabled is false in these values: this run removes its connections and bindings. Pass the same VALUES_FILE as before to keep them, or ./uninstall.sh to remove Kourier."
fi

[ -z "$OBS_KOURIER_FILE" ] || rm -rf "$(dirname "$OBS_KOURIER_FILE")"

# --- 4d. A2A gate keys (only when the chart renders the gate) ---------------------------------------------------------
# One static key per Kourier binding: Secret <ns>/<name> key <key> (the chart's tokenSecretRef) holds the key, created only when absent. The gate's hash
# Secret holds SHA-256(key) per caller, applied with one field manager per key so a key never clobbers another and nothing else in the Secret is
# touched. The hash is derived from the key Secret on every run, so the two always agree. Values never reach output, argv or disk.
if [ -n "$A2A_GATE_DEP" ]; then
  log "A2A gate keys"
  GATE_NS=$(jq -r '.metadata.namespace' <<<"$A2A_GATE_DEP")
  GATE_KEYS_S=$(jq -r '.spec.template.spec.volumes[]|select(.name=="keys")|.secret.secretName' <<<"$A2A_GATE_DEP")
  GATE_KEYS_N=0
  while IFS=$'\t' read -r gcaller gns gsec gkey; do
    [ -n "$gcaller" ] || continue
    mk_random_secret "$gns" "$gsec" "$gkey" 32
    gh=$($K get secret -n "$gns" "$gsec" -o jsonpath="{.data.${gkey//./\\.}}" | base64 -d | shasum -a 256 | cut -d' ' -f1)
    $K create secret generic "$GATE_KEYS_S" -n "$GATE_NS" --from-file="$gcaller"=<(printf '%s' "$gh") --dry-run=client -o yaml \
      | $K apply --server-side --force-conflicts --field-manager="openagentix-a2a-key-$gcaller" -f - >/dev/null
    unset gh; GATE_KEYS_N=$((GATE_KEYS_N+1))
  done < <(jq -r 'select(.kind=="Binding" and .spec.identity.tokenSecretRef!=null)|[.metadata.annotations["openagentix.io/a2a-caller"],.metadata.namespace,.spec.identity.tokenSecretRef.name,(.spec.identity.tokenSecretRef.key//"token")]|@tsv' <<<"$RENDERED")
  echo "Secret $GATE_NS/$GATE_KEYS_S: $GATE_KEYS_N key hash(es) (one per Kourier binding)"
fi

# --- 4e. console login token (only when the chart renders the console) ----------------------------------------------------
# Secret <console ns>/<tokenSecret.name> key <tokenSecret.key>: 48 random characters (the console refuses fewer than 32), created only when absent, so a re-run
# never signs anybody out. The value never reaches output, argv or disk.
if [ -n "$CN_DEP" ]; then
  log "console token"
  CN_NS=$(jq -r '.metadata.namespace' <<<"$CN_DEP")
  CN_TOKEN_S=$(jq -r '.spec.template.spec.volumes[]|select(.name=="token")|.secret.secretName' <<<"$CN_DEP")
  CN_TOKEN_K=$(jq -r '.spec.template.spec.volumes[]|select(.name=="token")|.secret.items[0].key' <<<"$CN_DEP")
  mk_random_secret "$CN_NS" "$CN_TOKEN_S" "$CN_TOKEN_K" 24
fi

finish_builds   # wait for the background builds, then load the images into the cluster in one call
if [ -n "$STUB_IMAGE" ]; then
  STUB_HASH=$(cd services/stub-model && find . -type f ! -path './bin/*' ! -name '*.md' ! -name '*.test' ! -name '*_test.go' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "gateway.stubModel.sourceHash=$STUB_HASH")
fi
if [ -n "$BRIDGE_IMAGE" ]; then
  # Same for the bridge (image tag "dev"): the pod template carries a hash of bridges/telegram, so changed code replaces the pod.
  BRIDGE_HASH=$(cd bridges/telegram && find . -type f ! -path './bin/*' ! -name '*.md' ! -name '*.test' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "bridge.sourceHash=$BRIDGE_HASH")
fi
if [ -n "$A2A_CALL_IMAGE" ]; then
  A2A_HASH=$(cd tools/a2a-call && find . -type f ! -path './bin/*' ! -name '*.md' ! -name '*.test' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "scheduling.sourceHash=$A2A_HASH")
fi
if [ -n "$KB_DEP" ]; then
  # The image tag is "dev" and image ids change with every build, so key the rollout on the source content instead:
  # unchanged code = identical pod template = no restart; changed code = new hash = the pod is replaced.
  KB_HASH=$(cd services/kb && find . -type f ! -path './bin/*' ! -name '*.test' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "knowledge.kb.sourceHash=$KB_HASH")
fi
if [ -n "$NOTIFY_DEP" ]; then
  # Same for notify: a hash of services/notify rolls the pod on a code change although the tag stays "dev".
  NOTIFY_HASH=$(cd services/notify && find . -type f ! -path './bin/*' ! -name '*.md' ! -name '*.test' ! -name '*_test.go' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "notify.sourceHash=$NOTIFY_HASH")
  # No destination yet: the service is not Ready by design (it fails closed), and `helm --wait` must not wait for that.
  [ "$NOTIFY_NO_DEST" = 0 ] || SET+=(--set notify.requireReady=false)
fi
if [ -n "$A2A_GATE_DEP" ]; then
  # Same for the gate: a hash of services/a2a-gate rolls the pod on a code change although the tag stays "dev".
  A2A_GATE_HASH=$(cd services/a2a-gate && find . -type f ! -path './bin/*' ! -name '*.md' ! -name '*.test' ! -name '*_test.go' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "governance.a2a.sourceHash=$A2A_GATE_HASH")
fi
if [ -n "$CP_DEP" ]; then
  # Same for the control plane: a hash of services/control-plane rolls the pod on a code change although the tag stays "dev".
  CP_HASH=$(cd services/control-plane && find . -type f ! -path './bin/*' ! -name '*.md' ! -name '*.test' ! -name '*_test.go' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "controlPlane.sourceHash=$CP_HASH")
  # The API server addresses its NetworkPolicy lets it reach: found the way Agent Kourier's are. A values file that sets them (a real cluster) wins;
  # with the policy off there is nothing to set.
  if jq -e -s 'any(.[]; .kind=="NetworkPolicy" and .metadata.name=="openagentix-control-plane" and ([.spec.egress[]?.to[]?|select(has("ipBlock"))]|length)==0)' <<<"$RENDERED" >/dev/null; then
    # shellcheck source=components/channels/apiserver-cidrs.sh
    . components/channels/apiserver-cidrs.sh
    CP_EPS=""; CP_NODES=""
    if [ -z "$(printf '%s' "${CONTROL_PLANE_APISERVER_CIDRS:-}" | tr -d '[:space:],')" ]; then
      CP_EPS=$($K get endpointslices.discovery.k8s.io -n default -l kubernetes.io/service-name=kubernetes -o json)
      CP_NODES=$($K get nodes -o json 2>/dev/null || echo '{"items":[]}')   # only used to recognise kind
    fi
    CP_CIDRS=$(kourier_apiserver_cidrs "${CONTROL_PLANE_APISERVER_CIDRS:-}" "$CP_EPS" "$CP_NODES") || die "could not find the API server address for the control plane's NetworkPolicy; set CONTROL_PLANE_APISERVER_CIDRS"
    echo "control plane: its NetworkPolicy lets it reach the API server at $CP_CIDRS"
    SET+=(--set-json "controlPlane.apiServerCIDRs=$CP_CIDRS")
  fi
fi
if [ -n "$CN_DEP" ]; then
  # Same for the console: a hash of services/console AND console (the web app) rolls the pod on a code change although the tag stays "dev".
  # Build outputs (node_modules, console/build, .svelte-kit, web/dist) are left out: they follow from the sources.
  CN_HASH=$( {
    (cd services/console && find . -type f ! -path './bin/*' ! -path './web/dist/*' ! -name '*.md' ! -name '*.test' ! -name '*_test.go' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256); \
    (cd console && find . -type f ! -path './node_modules/*' ! -path './build/*' ! -path './.svelte-kit/*' ! -path './test-results/*' ! -path './playwright-report/*' ! -path './.vite/*' ! -name '*.md' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256); } | shasum -a 256 | cut -c1-16)
  SET+=(--set-string "console.sourceHash=$CN_HASH")
  if jq -e -s 'any(.[]; .kind=="NetworkPolicy" and .metadata.name=="openagentix-console" and ([.spec.egress[]?.to[]?|select(has("ipBlock"))]|length)==0)' <<<"$RENDERED" >/dev/null; then
    # shellcheck source=components/channels/apiserver-cidrs.sh
    . components/channels/apiserver-cidrs.sh
    CN_EPS=""; CN_NODES=""
    if [ -z "$(printf '%s' "${CONSOLE_APISERVER_CIDRS:-}" | tr -d '[:space:],')" ]; then
      CN_EPS=$($K get endpointslices.discovery.k8s.io -n default -l kubernetes.io/service-name=kubernetes -o json)
      CN_NODES=$($K get nodes -o json 2>/dev/null || echo '{"items":[]}')   # only used to recognise kind
    fi
    CN_CIDRS=$(kourier_apiserver_cidrs "${CONSOLE_APISERVER_CIDRS:-}" "$CN_EPS" "$CN_NODES") || die "could not find the API server address for the console's NetworkPolicy; set CONSOLE_APISERVER_CIDRS"
    echo "console: its NetworkPolicy lets it reach the API server at $CN_CIDRS"
    SET+=(--set-json "console.apiServerCIDRs=$CN_CIDRS")
  fi
fi
if [ "${SKIP_SKILL:-0}" != 1 ] && jq -e 'select(.kind=="AgentTemplate")|.spec.skills[]?|select(.source.oci|test("/skills/openagentix-canary@"))' <<<"$RENDERED" >/dev/null; then
  log "example skill openagentix-canary"
  # A registry:2 container of our own on the cluster's docker network (NOT in the node's network namespace: that dies
  # with the node and breaks on cluster recreation). The node pulls from its IP over plain HTTP (RFC1918 address).
  # The IP is looked up on every run and written into the skill ref, so nothing hard-codes it.
  REGISTRY=${REGISTRY_NAME:-openagentix-registry}
  if ! docker inspect "$REGISTRY" >/dev/null 2>&1; then
    docker run -d --name "$REGISTRY" --restart unless-stopped --network "$CLUSTER_NET" registry:2 >/dev/null
  else
    [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY")" = true ] || docker start "$REGISTRY" >/dev/null
    docker inspect -f '{{json .NetworkSettings.Networks}}' "$REGISTRY" | jq -e --arg n "$CLUSTER_NET" 'has($n)' >/dev/null || docker network connect "$CLUSTER_NET" "$REGISTRY"
  fi
  REG_IP=""
  for _ in $(seq 1 30); do
    REG_IP=$(docker inspect -f '{{with index .NetworkSettings.Networks "'"$CLUSTER_NET"'"}}{{.IPAddress}}{{end}}' "$REGISTRY")
    [ -n "$REG_IP" ] && break; sleep 1
  done
  [ -n "$REG_IP" ] || die "registry container $REGISTRY has no address on the $CLUSTER_NET network"
  REG="$REG_IP:5000"
  ARCH=$(docker exec "$NODE" uname -m); case "$ARCH" in aarch64) ARCH=arm64;; x86_64) ARCH=amd64;; esac
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  docker build -q --platform "linux/$ARCH" -t openagentix-canary-skill:1.0.0 -f components/tools/skills/Dockerfile components/tools/skills >/dev/null
  docker save -o "$T/skill.tar" openagentix-canary-skill:1.0.0
  DIGEST=$(docker run --rm --network "$CLUSTER_NET" -v "$T:/w" "$CRANE_IMAGE" push /w/skill.tar "$REG/skills/openagentix-canary:1.0.0" --insecure 2>&1 \
    | grep -Eo 'sha256:[0-9a-f]{64}' | tail -1)
  [ -n "$DIGEST" ] || die "could not push the skill image to $REG (is $REGISTRY reachable on the $CLUSTER_NET docker network?)"
  SET+=(--set-string "skills.openagentix-canary.oci=$REG/skills/openagentix-canary@$DIGEST")
  echo "skill pinned at $REG/skills/openagentix-canary@$DIGEST"
fi

# --- 6a. adopt hand-applied objects the chart now owns (label + annotations; nothing is deleted or recreated) ----
adopted=0
while IFS=$'\t' read -r res name ns; do
  [ -n "$res" ] || continue
  $K get "$res" "$name" -n "$ns" >/dev/null 2>&1 || continue
  [ "$($K get "$res" "$name" -n "$ns" -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')" = "$RELEASE" ] && continue
  $K label "$res" "$name" -n "$ns" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
  $K annotate "$res" "$name" -n "$ns" meta.helm.sh/release-name=$RELEASE meta.helm.sh/release-namespace="$RELEASE_NS" --overwrite >/dev/null
  echo "adopted $res/$name ($ns)"; adopted=$((adopted+1))
done < <(jq -r 'select(.metadata.namespace!=null)|[((.kind|ascii_downcase)+(if (.apiVersion|contains("/")) then "."+(.apiVersion|split("/")[0]) else "" end)),.metadata.name,.metadata.namespace]|@tsv' <<<"$RENDERED")
# The one cluster-scoped object the chart keeps on uninstall: the CRD of the control plane (helm.sh/resource-policy: keep). A later install finds it
# without Helm's ownership marks and would refuse it as foreign, so it is adopted like the namespaced objects above.
if [ -n "$CP_DEP" ] && $K get crd agentdefinitions.openagentix.io >/dev/null 2>&1 \
   && [ "$($K get crd agentdefinitions.openagentix.io -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}')" != "$RELEASE" ]; then
  $K label crd agentdefinitions.openagentix.io app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
  $K annotate crd agentdefinitions.openagentix.io meta.helm.sh/release-name=$RELEASE meta.helm.sh/release-namespace="$RELEASE_NS" --overwrite >/dev/null
  echo "adopted crd/agentdefinitions.openagentix.io"; adopted=$((adopted+1))
fi

# --- 6. the chart ---------------------------------------------------------------------------------------------
log "helm upgrade --install $RELEASE"  # (adoption happens just above)
helm upgrade --install $RELEASE $CHART -n "$RELEASE_NS" --create-namespace ${VALS[@]+"${VALS[@]}"} ${SET[@]+"${SET[@]}"} --wait --timeout 5m

if [ -n "$CH_CM" ]; then   # the broker's CRDs must have been there: the chart skips Kourier objects silently without them
  helm get manifest $RELEASE -n "$RELEASE_NS" | yq -e 'select(.kind=="AgentBackend")' >/dev/null || die "Agent Kourier CRDs were not found by Helm: the AgentBackend was not installed (kubectl get crd agentbackends.agentkourier.dev)"
fi

# Helm does not patch objects it merely adopted when old and new manifests are equal, so converge them once with
# server-side apply (no-op for objects Helm just created).
helm get manifest $RELEASE -n "$RELEASE_NS" | $K apply --server-side --force-conflicts --field-manager=openagentix-install -f - >/dev/null
[ "$adopted" -eq 0 ] || echo "reconciled $adopted adopted object(s) to the chart's desired state"

# --- 6b. knowledge base: wait, then ingest the sample corpus (idempotent PUTs, token read from the Secret) -------
if [ -n "$KB_DEP" ]; then
  log "knowledge base"
  for w in $(jq -r 'select((.kind=="Deployment" or .kind=="StatefulSet") and .metadata.namespace=="'"$KB_NS"'")|.kind+"/"+.metadata.name' <<<"$RENDERED"); do
    $K rollout status "$w" -n "$KB_NS" --timeout=600s
  done
  if [ "${SKIP_KB_INGEST:-0}" != 1 ]; then
    KUBECTL=$K KUBE_CONTEXT=$CTX KB_NAMESPACE=$KB_NS KB_ADMIN_SECRET=$ADM_S KB_ADMIN_KEY=$ADM_K bash hack/kb-ingest.sh components/knowledge/sample openagentix
  fi
fi

# --- 7. wait for the agents ---------------------------------------------------------------------------------
if [ -n "$NOTIFY_DEP" ]; then
  log "notify"
  $K rollout status deployment/notify -n "$N_NS" --timeout=180s
  [ "$NOTIFY_NO_DEST" = 0 ] || echo "notify has no destination: calls are refused until you create Secret $N_NS/$N_DEST_S (README "Notifications") and run: $K rollout restart deployment/notify -n $N_NS"
fi

if [ -n "$A2A_GATE_DEP" ]; then
  log "A2A gate"
  $K rollout status deployment/a2a-gate -n "$GATE_NS" --timeout=180s
fi

if [ -n "$CP_DEP" ]; then
  log "control plane"
  $K rollout status deployment/openagentix-control-plane -n "$(jq -r '.metadata.namespace' <<<"$CP_DEP")" --timeout=180s
  echo "AgentDefinitions: kubectl apply -f components/control-plane/researcher.yaml (the controller does the rest); $K get agentdefinitions -n $KAGENT_NS"
fi

if [ -n "$CN_DEP" ]; then
  log "console"
  $K rollout status deployment/openagentix-console -n "$CN_NS" --timeout=180s
  CN_VIEWER=""; jq -e '.spec.template.spec.containers[0].env[]?|select(.name=="CONSOLE_VIEWER")' <<<"$CN_DEP" >/dev/null 2>&1 && CN_VIEWER=" (read-only: console.viewer is true)"
  cat <<EOT
Console$CN_VIEWER: nobody can connect to it inside the cluster; open it from your machine:
  $K port-forward -n $CN_NS svc/openagentix-console 8080:8080        then open http://127.0.0.1:8080
Sign in with the token in Secret $CN_NS/$CN_TOKEN_S. This script does not print it; read it yourself (it lands in your terminal only):
  $K get secret -n $CN_NS $CN_TOKEN_S -o jsonpath='{.data.$CN_TOKEN_K}' | base64 -d; echo
EOT
fi

# Tool profiles (mcp.profiles, ADR 0006 round 2): each is one more vMCP pod; an agent on a profile finds no tools until its vMCP is Ready.
for row in $(jq -r 'select(.kind=="VirtualMCPServer" and (.metadata.annotations["openagentix.io/tool-profile"]//"")!="")|.metadata.namespace+"/"+.metadata.name' <<<"$RENDERED"); do
  log "tool profile vMCP ${row##*/}"
  $K wait "virtualmcpserver/${row##*/}" -n "${row%%/*}" --for=condition=Ready --timeout=300s || echo "WARN: ${row##*/} not Ready yet: $K get virtualmcpserver ${row##*/} -n ${row%%/*} -o yaml"
done

log "waiting for agents (first start builds a golden snapshot, ~1-2 min each)"
for a in $(jq -r 'select(.kind=="Agent")|.metadata.name' <<<"$RENDERED"); do
  $K wait "agent/$a" -n $KAGENT_NS --for=condition=Ready --timeout="$AGENT_WAIT" || echo "WARN: agent $a not Ready yet: $K get agent $a -n $KAGENT_NS -o yaml"
done
# Only the RemoteMCPServers this chart renders (the vMCPs): kagent's own built-in ones (kagent-api, kagent-tool-server) are not ours to wait for,
# and when one of them cannot connect, `wait --all` used to hold the install for the whole 120 s (seen in CI, issue #29).
for rm in $(jq -r 'select(.kind=="RemoteMCPServer")|.metadata.name' <<<"$RENDERED"); do
  $K wait "remotemcpserver/$rm" -n $KAGENT_NS --for=condition=Accepted --timeout=120s >/dev/null 2>&1 || echo "WARN: RemoteMCPServer $rm is not Accepted yet (vMCP may still be starting): $K get remotemcpserver $rm -n $KAGENT_NS"
done

if [ -n "$CH_CM" ]; then
  log "waiting for the Kourier bindings"
  $K wait bindings.agentkourier.dev --all -n "$CH_NS" --for=condition=Ready --timeout=180s || echo "WARN: a Binding is not Ready yet: $K get bindings.agentkourier.dev -n $CH_NS"
  $K get bindings.agentkourier.dev -n "$CH_NS"
fi

if [ "$QS" = 1 ]; then
  log "quick start agent"
  $K create serviceaccount quickstart-ask -n "$RELEASE_NS" --dry-run=client -o yaml | $K apply -f - >/dev/null   # the identity hack/ask.sh uses (the A2A gate rule is in the profile)
  QS_DESC="Looks up known vulnerabilities of a package. Model: $(qs_model_label "$QS_MODEL")"
  yq --arg d "$QS_DESC" '.spec.description=$d' components/quickstart/agent.yaml > "$QS_TMP/agent.json"
  # the ResourceQuota on definitions has no status for a moment after the chart is installed ("status unknown for quota"): retry
  for qs_try in $(seq 1 40); do
    $K apply -f "$QS_TMP/agent.json" >/dev/null 2>"$QS_TMP/apply.err" && break
    [ "$qs_try" -lt 40 ] && /usr/bin/grep -q "status unknown for quota" "$QS_TMP/apply.err" || { cat "$QS_TMP/apply.err" >&2; $K get resourcequota -n $KAGENT_NS -o yaml >&2 2>&1 || true; die "could not create the quickstart AgentDefinition"; }
    # The quota controller learns the new CRD only at its next discovery pass (30 s) and backs off after the failed first sync, so the
    # status can stay unknown for minutes. A change of the quota's spec makes it sync again at once: set the limit up by one and back.
    if [ $((qs_try % 10)) = 0 ]; then
      qs_hard=$($K get resourcequota openagentix-agentdefinitions -n $KAGENT_NS -o json 2>/dev/null | jq -r '.spec.hard["count/agentdefinitions.openagentix.io"] // empty')
      if [[ "$qs_hard" =~ ^[0-9]+$ ]]; then
        for qs_v in $((qs_hard + 1)) "$qs_hard"; do
          $K patch resourcequota openagentix-agentdefinitions -n $KAGENT_NS --type merge -p "{\"spec\":{\"hard\":{\"count/agentdefinitions.openagentix.io\":\"$qs_v\"}}}" >/dev/null 2>&1 || true
        done
      fi
    fi
    sleep 3
  done
  $K wait agentdefinition/quickstart -n $KAGENT_NS --for=condition=Ready --timeout="$AGENT_WAIT" \
    || { echo "WARN: the quickstart agent is not Ready yet: $K get agentdefinition quickstart -n $KAGENT_NS -o yaml" >&2; QS_NOT_READY=1; $K get agentdefinition quickstart -n $KAGENT_NS -o jsonpath='{.status}' >&2; echo >&2; }
  [ -n "${QS_NOT_READY:-}" ] || log "quick start agent Ready"   # a marker for hack/ci/phases.sh (time to first working agent)
  if [ "$QS_BYO" = 1 ]; then
    log "sample container agent (bring your own agent)"
    BYO_REF=$(hack/kind-image-digest.sh "$CLUSTER" "$BYO_REPO" "${BYO_IMAGE##*:}") || die "no digest for the sample image: see the line above"
    echo "image $BYO_REF"
    # the quick start opens the profile lookup to container agents (components/quickstart/byo-values.yaml, ADR 0019)
    yq --arg i "$BYO_REF" '.spec.runtime.container.image=$i | .spec.toolProfile="lookup"' examples/agents/echo-a2a/agent.yaml > "$QS_TMP/byo.json"
    $K apply -f "$QS_TMP/byo.json" >/dev/null || die "could not create the echo-go AgentDefinition"
    $K wait agentdefinition/echo-go -n $KAGENT_NS --for=condition=Ready --timeout="$AGENT_WAIT" \
      || { echo "WARN: the echo-go agent is not Ready yet: $K get agentdefinition echo-go -n $KAGENT_NS -o yaml" >&2; QS_NOT_READY=1; $K get agentdefinition echo-go -n $KAGENT_NS -o jsonpath='{.status}' >&2; echo >&2; }
  fi
fi

log "DONE"
if jq -e 'select(.kind=="Deployment" and .metadata.name=="telegram-bridge")' <<<"$RENDERED" >/dev/null; then $K get pods -n $BRIDGE_NS; fi
$K get agent -n $KAGENT_NS
if [ "$QS" = 1 ]; then
  QS_SECS=$(( $(date +%s) - t0 ))
  cat <<EOT

============================================================================
OpenAgentix quick start is up in $((QS_SECS/60)) min $((QS_SECS%60)) s.${QS_NOT_READY:+  (The agent was not Ready yet when the wait ended: see the WARN above.)}

  MODEL: $(qs_model_label "$QS_MODEL")
EOT
  if [ "$QS_MODEL" = stub ]; then cat <<EOT
         The stub is for trying the platform's controls (tool profile, egress, budgets, the gate). It is NOT a language model and its
         answers are canned. For real answers, run the same command with a model:
           ANTHROPIC_API_KEY=sk-ant-... PROFILE=quickstart ./install.sh        (or OPENAI_API_KEY, GOOGLE_API_KEY, MODEL_BASE_URL + MODEL_NAME [+ MODEL_API_KEY],
           MODEL_PROVIDER=ollama MODEL_NAME=<model>  for a local Ollama; see README "Try it in 10 minutes")
EOT
  fi
  cat <<EOT

  Ask the agent (no chat app needed):
    hack/ask.sh quickstart "Look up known vulnerabilities of lodash 4.17.20 (npm)"
EOT
  if [ -n "$CN_DEP" ]; then cat <<EOT
  Open the console:
    $K port-forward -n $CN_NS svc/openagentix-console 8080:8080       then open http://127.0.0.1:8080
    sign-in token (read it yourself; this script does not print it):
    $K get secret -n $CN_NS $CN_TOKEN_S -o jsonpath='{.data.$CN_TOKEN_K}' | base64 -d; echo
EOT
  fi
  cat <<EOT
  Remove everything:
    $(cluster_delete_hint)
============================================================================
EOT
fi
[ -z "${QS_NOT_READY:-}" ] || { echo "ERROR: the quickstart agent did not become Ready" >&2; exit 1; }
