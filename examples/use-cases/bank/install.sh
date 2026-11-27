#!/usr/bin/env bash
# Installs the bank use case (Fernvale Bank dispute and fraud-claim case agent) on a LOCAL kind cluster, end to end:
#
#   CLUSTER=oa-bank-demo examples/use-cases/bank/install.sh                    the quick start plus the use case, offline: the stub model with the scenarios (no key, no token)
#   VALUES_FILE="<the list you installed the full demo with>" CLUSTER=<its cluster> \
#     examples/use-cases/bank/install.sh --beside-full-demo                    add the agent to a full demo install (values-full-demo.yaml, composed AFTER your list)
#   CLUSTER=<name> examples/use-cases/bank/install.sh --skip-platform          only the records service, its Secrets, the desk caller and the documents (the platform install ran already)
#   CLUSTER=<name> examples/use-cases/bank/install.sh --uninstall              removes what this script made (not the chart values: see the README, "Uninstall")
#
# There is NO default cluster: set CLUSTER (the kind cluster name) or KUBE_CONTEXT, so that a script never acts on a cluster by guess (a name like
# "openagentix" is also the name of a full demo cluster). The script refuses any context that is not kind-* (also for --uninstall). It never deletes a
# cluster. It makes one, with the repository's kind config, only when no kube context of that name exists and --beside-full-demo is not given.
#
# What it does, in order (ADR 0026: the records service joins the platform through mcp.endpoints, so it and its Secrets come FIRST). Every step can be run again.
#   0. the guards above; refuses to run the quick start install on a release that has more than the quick start and this use case (the platform installer
#      replaces the release values on every run: it would drop them). On such a release use --beside-full-demo;
#   1. composes the values: hack/compose-values.sh merges components/quickstart/values.yaml and values.yaml by entry name and reports what the second adds
#      (with --beside-full-demo: your files merged the way Helm merges them, then values-full-demo.yaml composed after them, after a check that the merge
#      renders exactly like your list);
#   2. builds the records image (tag from a hash of its source) and loads it into the kind nodes;
#   3. creates the namespace fernvale-records and, only when ALL are absent, four Secrets from generated values, always through stdin, never printed, never an
#      argument: `records-approvers` (the SHA-256 of the desk lead's token) and `records-approver-token` (the token itself, read by ctl.sh) in fernvale-records;
#      `records-mcp-expected` (fernvale-records, read by the records service as a file) and `records-mcp-auth` (the tool namespace, read by the tool gateway)
#      with the SAME header value `Bearer <token>`. When only some exist (an earlier run stopped half way) all are made again with new values;
#   4. applies manifests/records.yaml (the service, a base policy that admits nothing) and waits for it;
#   5. removes the objects the first version of this use case made by hand (an MCPServerEntry and an auth config named records, by label), because Helm
#      refuses to take over an object it did not create;
#   6. runs the platform installer (./install.sh) with the composed values. Offline it sets PROFILE=quickstart and STUB_SCENARIOS=eval/scenario.json (ADR 0026)
#      and removes every provider key from the environment of that run, so the stub answers. The chart renders the endpoint, the group, the profile's tool
#      server and the policies; the platform installer checks that the tool server of the group sees the endpoint as ready;
#   7. makes the ServiceAccount openagentix-system/disputes-desk (the caller of the dispute agent; the rule is in values.yaml);
#   8. loads seed/kb into the collection fernvale-disputes and seed/graph into the graph (hack/kb-ingest.sh, hack/kb-graph-load.sh);
#   9. offline: checks that the stub model has the scenarios. A run with them is SCRIPTED by the stub model, not the behaviour of a model: say so wherever
#      you report it.
#
# Env: CLUSTER (kind cluster name, REQUIRED unless KUBE_CONTEXT is set)  KUBE_CONTEXT (default kind-$CLUSTER)  KUBECTL  HELM  DOCKER  KIND
#      VALUES_FILE (--beside-full-demo only: the files of the install you have, space separated, relative to the repository root or absolute)
#      PLATFORM_INSTALL (the platform installer, default ./install.sh in the repository root; a test sets a fake)  COMPOSE (compose-values.sh)
#      KB_INGEST, KB_GRAPH_LOAD (the two hack scripts)  SKIP_BUILD=1 (use RECORDS_IMAGE as it is)  RECORDS_IMAGE
#      Any other variable of the platform installer (SKIP_*, AGENT_WAIT, ...) goes through to it.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
# No default cluster: a script that changes a cluster must be told which one.
[ -n "${CLUSTER:-}${KUBE_CONTEXT:-}" ] || { echo "ERROR: set CLUSTER (the kind cluster name) or KUBE_CONTEXT: there is no default cluster. Nothing was changed." >&2; exit 1; }
# When both are set they must name the same cluster: kubectl and the platform installer use the context, kind uses the name.
if [ -n "${CLUSTER:-}" ] && [ -n "${KUBE_CONTEXT:-}" ] && [ "$KUBE_CONTEXT" != "kind-$CLUSTER" ]; then
  echo "ERROR: CLUSTER=$CLUSTER and KUBE_CONTEXT=$KUBE_CONTEXT name different clusters (the context of $CLUSTER is kind-$CLUSTER). Set one of them, or make them agree. Nothing was changed." >&2; exit 1
fi
CLUSTER=${CLUSTER:-${KUBE_CONTEXT#kind-}}
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-$CLUSTER}
KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
DOCKER=${DOCKER:-docker}
KIND=${KIND:-kind}
RELEASE=${RELEASE:-openagentix}
RELEASE_NS=${RELEASE_NS:-openagentix-system}
PLATFORM_INSTALL=${PLATFORM_INSTALL:-$ROOT/install.sh}
COMPOSE=${COMPOSE:-$ROOT/hack/compose-values.sh}
KB_INGEST=${KB_INGEST:-$ROOT/hack/kb-ingest.sh}
KB_GRAPH_LOAD=${KB_GRAPH_LOAD:-$ROOT/hack/kb-graph-load.sh}
NS=fernvale-records
MCPNS=mcp-tools
COLLECTION=fernvale-disputes
FACTSET=fernvale-bank
DESK_NS=openagentix-system
KC=("$KUBECTL" --context "$KUBE_CONTEXT")

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

# The guard comes first, before any option runs: --uninstall deletes things too.
case "$KUBE_CONTEXT" in
  kind-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind cluster (kind-<name>). Set CLUSTER or KUBE_CONTEXT. Nothing was changed." ;;
esac

MODE=install; SKIP_PLATFORM=0; BESIDE=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    --skip-platform) SKIP_PLATFORM=1 ;;
    --beside-full-demo) BESIDE=1 ;;
    -h|--help) sed -n 2,40p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (--beside-full-demo, --skip-platform, --uninstall, -h; the stub model scenarios are shipped by the platform install, STUB_SCENARIOS)" ;;
  esac
done

if [ "$MODE" = uninstall ]; then
  say "removing the bank use case objects from $KUBE_CONTEXT (the chart values stay: install the platform again without values.yaml and without STUB_SCENARIOS to remove the agent, the profile, the endpoint and the scenarios)"
  "${KC[@]}" delete configmap bank-scenarios -n agentgateway-system --ignore-not-found   # made by the first version of this script (a kubectl patch); the chart now ships the scenarios
  "${KC[@]}" delete mcpserverentry records -n "$MCPNS" -l app.kubernetes.io/part-of=openagentix-use-case-bank --ignore-not-found   # made by the first version of this script
  "${KC[@]}" delete mcpexternalauthconfig records-noauth -n "$MCPNS" -l app.kubernetes.io/part-of=openagentix-use-case-bank --ignore-not-found
  "${KC[@]}" delete secret records-mcp-auth -n "$MCPNS" --ignore-not-found
  "${KC[@]}" delete namespace "$NS" --ignore-not-found
  "${KC[@]}" delete serviceaccount disputes-desk -n "$DESK_NS" --ignore-not-found
  say "the knowledge base keeps the collection $COLLECTION and the fact set $FACTSET; remove them with the kb admin API if you want"
  exit 0
fi

command -v jq >/dev/null || die "jq is required"
[ -x "$PLATFORM_INSTALL" ] || [ -f "$PLATFORM_INSTALL" ] || die "the platform installer is not at $PLATFORM_INSTALL"
[ "$BESIDE" = 0 ] || [ "$SKIP_PLATFORM" = 0 ] || die "--beside-full-demo runs the platform installer: do not combine it with --skip-platform. Nothing was changed."
if [ "$BESIDE" = 1 ] && [ -z "${VALUES_FILE:-}" ]; then
  die "--beside-full-demo needs VALUES_FILE: the same list of files you installed the full demo with. Helm replaces the release values on every run, so a list that is missing would drop what it set. Nothing was changed."
fi

# Helm reads the release (and renders for --beside-full-demo): a missing helm must stop the install, never read as "no release".
if [ "$SKIP_PLATFORM" = 0 ]; then command -v "$HELM" >/dev/null 2>&1 || die "helm is required (HELM=$HELM is not a command). Nothing was changed."; fi

ctx_exists() { local c; c=$("${KC[@]}" config get-contexts -o name 2>/dev/null) || return 1; printf '%s\n' "$c" | grep -qx "$KUBE_CONTEXT"; }

# ---- 0b. the release must not lose anything -----------------------------------------------------------------------------------------
# The platform installer replaces the release values on every run. This script composes the values it hands over (the quick start plus this use case, or your own
# list plus values-full-demo.yaml). A release that holds a key path, or a named list entry, that those values lack would lose it (and, offline, every provider key
# is removed, so the model would become the stub). So the user-supplied values of the release are compared with the composed values as an ALLOWLIST: anything the
# release has that the composed values do not have is refused, and named. Keys the platform installer sets itself (image tag, digest and repository, source hashes,
# the API server addresses, the scenario files, the service account issuer, the skill reference, notify.requireReady) are not compared. It compares key paths and
# entry names, not values; a list of plain values counts as one path.
release_values() { # prints the user-supplied values of the release as JSON, or nothing when there is no release; fails (stopping the install) when it cannot tell
  local out err; err="$TMP/helm.err"
  ctx_exists || return 0   # no such context yet: the cluster is made below, nothing can be lost
  if ! out=$("$HELM" get values "$RELEASE" -n "$RELEASE_NS" --kube-context "$KUBE_CONTEXT" -o json 2>"$err"); then
    # only helm's own, exact line means "no such release"; any other failure (a missing command, a wrong storage driver, an unreachable cluster) stops the install
    if grep -qxF "Error: release: not found" "$err" 2>/dev/null; then return 0; fi
    echo "cannot read the values of the release $RELEASE in $KUBE_CONTEXT: $(head -n 1 "$err" 2>/dev/null | cut -c1-300)" >&2
    return 1
  fi
  printf '%s' "$out"
}
release_extras() { # release_extras <json file of the values this script will hand over>: prints the paths the release has and those values lack, one per line
  local rel; rel=$(release_values) || return 1
  [ -n "$rel" ] || return 0
  printf '%s' "$rel" | jq -r --slurpfile exp "$1" '
    def flat($pre):
      if type == "object" then (if length == 0 then $pre + "{}" else (to_entries[] | .key as $k | .value | flat($pre + "." + $k)) end)
      elif type == "array" then (if length == 0 then $pre + "[]" else (.[] | (if type == "object" and ((.name | type) == "string") then flat($pre + "[" + .name + "]") else flat($pre + "[]") end)) end)
      else $pre end;
    # the one scenario file this script ships is named scenario.json; it is replaced without complaint only when the release holds an earlier copy of it (it names
    # the dispute desk agent). A scenario.json of another use case, and any other file, stay in the list.
    (if ((.gateway.stubModel.scenarios.files["scenario.json"] // "") | test("fernvale dispute desk agent"; "i")) then "^[.]gateway[.]stubModel[.]scenarios[.]files[.]scenario[.]json$" else "^$" end) as $mine
    | ([. | flat("")] | unique) - ([$exp[0] | flat("")] | unique)
    | map(select((test("^[.](bridge|knowledge[.]kb|notify|gateway[.]stubModel|controlPlane|console|diagnostics)[.]image[.]tag$|^[.](bridge|console|controlPlane|diagnostics|gateway[.]stubModel|governance[.]a2a|knowledge[.]kb|notify|scheduling)[.]sourceHash$|^[.](controlPlane|console|diagnostics)[.]apiServerCIDRs(\\[\\])?$|^[.]controlPlane[.]containerAgents[.]serviceAccountTokens[.]issuer$|^[.]skills[.]openagentix-canary[.]oci$|^[.]notify[.]requireReady$") or test($mine)) | not))
    | .[]'
}

# ---- 1. compose the values (local work only: nothing in the cluster has changed yet) --------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VALUES_COMPOSED="$TMP/bank-values.yaml"; VALUES_BASE="$TMP/your-values.yaml"
if [ "$SKIP_PLATFORM" != 1 ]; then
  if [ "$BESIDE" = 1 ]; then
    say "composing the values: your list ($VALUES_FILE) first, then examples/use-cases/bank/values-full-demo.yaml (the endpoint, the profile disputes, the agent dispute-agent, the sweep and the caller)"
    # Your own files are merged first, the way Helm merges them (maps deep, a later file wins, a list is REPLACED by a later file), into one file. That is
    # exactly your install, so compose-values.sh must not judge it. The merge is checked instead: the chart must render byte for byte the same from your
    # list and from the merged file. Only then is values-full-demo.yaml composed after it by compose-values.sh, without --later-wins: it joins the lists by
    # name and never drops an entry of yours, and a name or a security key that clashes is refused, and nothing is installed.
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
    "$COMPOSE" -o "$VALUES_COMPOSED" "$VALUES_BASE" "$HERE/values-full-demo.yaml" || die "the values did not compose (the reason is above): your install and this agent do not fit together as they are. Nothing was changed."
  else
    say "composing the values (components/quickstart/values.yaml and examples/use-cases/bank/values.yaml)"
    "$COMPOSE" -o "$VALUES_COMPOSED" "$ROOT/components/quickstart/values.yaml" "$HERE/values.yaml" || die "the values did not compose (the reason is above). Nothing was changed."
  fi
fi

# ---- 1b. the release (read only; nothing in the cluster has changed yet) ------------------------------------------------------------------
if [ "$SKIP_PLATFORM" != 1 ]; then
  # Compare with what this script will hand over: the composed values. With --beside-full-demo that is your list plus values-full-demo.yaml, so a second run
  # (whose release already holds the bank's own entries) is not refused, and a file left out of your list still is.
  yq . "$VALUES_COMPOSED" > "$TMP/expected.json" || die "cannot read the composed values. Nothing was changed."; EXP_FILE="$TMP/expected.json"
  EXTRAS=$(release_extras "$EXP_FILE") || die "refusing to run the platform installer on a release I cannot read. Nothing was changed."
  if [ -n "$EXTRAS" ]; then
    if [ "$BESIDE" = 1 ]; then
      die "the release $RELEASE in $KUBE_CONTEXT has values that your VALUES_FILE list does not have: $(printf '%s' "$EXTRAS" | head -n 20 | tr '\n' ';' | sed 's/;/; /g'). The platform installer replaces the release values with your list plus this agent, so it would drop them. Give the same list of files you installed with. Nothing was changed."
    else
      die "the release $RELEASE in $KUBE_CONTEXT has more than the quick start and this use case: $(printf '%s' "$EXTRAS" | head -n 20 | tr '\n' ';' | sed 's/;/; /g'). The platform installer would replace those values and drop them. Use a cluster of its own, or add the agent to your install with: VALUES_FILE=\"<your files>\" CLUSTER=<its cluster> $0 --beside-full-demo. Nothing was changed."
    fi
  fi
fi

# ---- 2. the cluster, then the image --------------------------------------------------------------------------------------------
if ! ctx_exists; then
  [ "$BESIDE" = 0 ] || die "--beside-full-demo needs the cluster of your full demo to exist: no kube context '$KUBE_CONTEXT'. Nothing was changed."
  [ "$SKIP_PLATFORM" = 0 ] || die "--skip-platform needs the cluster to exist: no kube context '$KUBE_CONTEXT'. Nothing was changed."
  say "no kube context $KUBE_CONTEXT: making the kind cluster $CLUSTER (the repository's kind config)"
  "$KIND" create cluster --name "$CLUSTER" --config "$ROOT/hack/kind-config.yaml"
fi
if [ "${SKIP_BUILD:-0}" = 1 ]; then
  IMAGE=${RECORDS_IMAGE:?SKIP_BUILD=1 needs RECORDS_IMAGE}
else
  # shellcheck source=/dev/null
  . "$ROOT/hack/image-tag.sh"
  IMAGE=${RECORDS_IMAGE:-registry.local/oa/records-bank:$(src_tag "$ROOT/examples/use-cases/records")}
fi
[[ "$IMAGE" =~ ^[a-z0-9][A-Za-z0-9._/:@-]*$ ]] || die "the image name '$IMAGE' has characters that are not allowed in an image reference"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  say "building $IMAGE"
  "$DOCKER" build -q --build-arg DOMAIN=bank -t "$IMAGE" "$ROOT/examples/use-cases/records" >/dev/null
  say "loading it into the kind cluster $CLUSTER"
  "$KIND" load docker-image "$IMAGE" --name "$CLUSTER" >/dev/null
fi

# ---- 3. namespaces and Secrets -------------------------------------------------------------------------------------------------
say "namespaces $NS and $MCPNS"
"${KC[@]}" get namespace "$NS" >/dev/null 2>&1 || "${KC[@]}" create namespace "$NS" >/dev/null   # the labels (restricted pod security) come with the manifest below
"${KC[@]}" get namespace "$MCPNS" >/dev/null 2>&1 || "${KC[@]}" create namespace "$MCPNS" >/dev/null   # the chart's header Secret reference needs the Secret before the chart is applied
HAVE=0; ALL=1
# Only a NotFound answer means a Secret is absent. Any other error (a timeout, throttling, a restarted API server) stops the install before anything is
# deleted or made again: a read error must never rotate the values.
for sec in "records-approvers:$NS" "records-approver-token:$NS" "records-mcp-expected:$NS" "records-mcp-auth:$MCPNS"; do
  if sec_out=$("${KC[@]}" get secret "${sec%%:*}" -n "${sec##*:}" -o name 2>&1); then HAVE=1
  elif printf '%s' "$sec_out" | grep -q 'NotFound'; then ALL=0
  else die "cannot read the Secret ${sec%%:*} in ${sec##*:}: $(printf '%s' "$sec_out" | head -n 1 | cut -c1-300). Nothing was deleted or made again."; fi
done
REGENERATED=0
if [ "$ALL" = 1 ]; then
  say "the Secrets exist: not changed"
else
  if [ "$HAVE" = 1 ]; then
    say "only some of the four Secrets exist (an earlier run stopped half way): making all again with new values"
    "${KC[@]}" delete secret records-approvers records-approver-token records-mcp-expected -n "$NS" --ignore-not-found >/dev/null
    "${KC[@]}" delete secret records-mcp-auth -n "$MCPNS" --ignore-not-found >/dev/null
    REGENERATED=1
  fi
  command -v openssl >/dev/null || die "openssl is required to generate the tokens"
  TOKEN=$(openssl rand -hex 24)
  CRED="Bearer $(openssl rand -hex 24)"
  [ "${#TOKEN}" -ge 32 ] && [ "${#CRED}" -ge 39 ] || die "could not generate a token"
  SUM=$(printf %s "$TOKEN" | openssl dgst -sha256 | sed 's/^.* //')
  printf '[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"%s"}]\n' "$SUM" \
    | "${KC[@]}" create secret generic records-approvers -n "$NS" --from-file=approvers.json=/dev/stdin >/dev/null
  printf %s "$TOKEN" | "${KC[@]}" create secret generic records-approver-token -n "$NS" --from-file=token=/dev/stdin >/dev/null
  printf %s "$CRED" | "${KC[@]}" create secret generic records-mcp-expected -n "$NS" --from-file=value=/dev/stdin >/dev/null
  printf %s "$CRED" | "${KC[@]}" create secret generic records-mcp-auth -n "$MCPNS" --from-file=value=/dev/stdin >/dev/null
  unset TOKEN SUM CRED
  say "created the Secrets (approver id desk:lead-1, role desk-lead; the MCP header value for the tool gateway and the records service): the values are read by ctl.sh and the services, and are not shown"
fi

# ---- 4. the service ------------------------------------------------------------------------------------------------------------
say "applying the records service"
sed "s#IMAGE_PLACEHOLDER#$IMAGE#" "$HERE/manifests/records.yaml" | "${KC[@]}" apply -f - >/dev/null
# The service reads its files when it starts (the approvers) and per request (the MCP credential): a new token needs a new pod.
if [ "$REGENERATED" = 1 ]; then "${KC[@]}" rollout restart deployment/records -n "$NS" >/dev/null; fi
"${KC[@]}" rollout status deployment/records -n "$NS" --timeout=180s >/dev/null || die "the records pod did not become ready: kubectl --context $KUBE_CONTEXT describe pod -n $NS -l app=records"

# ---- 5. the objects of the first version of this use case ----------------------------------------------------------------------
# Helm refuses to take over an object it did not create. The first version registered the service with an MCPServerEntry and an auth config applied by hand
# (label part-of=openagentix-use-case-bank). The chart makes its own now; delete only objects that carry that label.
"${KC[@]}" delete mcpserverentry records -n "$MCPNS" -l app.kubernetes.io/part-of=openagentix-use-case-bank --ignore-not-found >/dev/null 2>&1 || true
"${KC[@]}" delete mcpexternalauthconfig records-noauth -n "$MCPNS" -l app.kubernetes.io/part-of=openagentix-use-case-bank --ignore-not-found >/dev/null 2>&1 || true

# ---- 6. the platform -----------------------------------------------------------------------------------------------------------
if [ "$SKIP_PLATFORM" != 1 ]; then
  if [ "$BESIDE" = 1 ]; then
    say "platform install beside the full demo: your model, your provider keys and your scenarios stay as they are (nothing is unset)"
    env -u PROFILE -u STUB_SCENARIOS CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" VALUES_FILE="$VALUES_COMPOSED" "$PLATFORM_INSTALL"
  else
    say "platform install, offline: the stub model with the scenarios of eval/scenario.json (a run with them is SCRIPTED, not the behaviour of a model)"
    env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY -u MODEL_BASE_URL -u MODEL_NAME -u MODEL_PROVIDER -u MODEL_API_KEY \
      CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" PROFILE=quickstart VALUES_FILE="$VALUES_COMPOSED" STUB_SCENARIOS="$HERE/eval/scenario.json" "$PLATFORM_INSTALL"
  fi
fi

# ---- 7. the platform must have what the use case needs ----------------------------------------------------------------------------
"${KC[@]}" get namespace openagentix-knowledge >/dev/null 2>&1 || die "the knowledge base is not installed: the platform install must use examples/use-cases/bank/values.yaml (it turns the knowledge base and the graph on)"
"${KC[@]}" get agents.api.kagent.dev dispute-agent -n kagent >/dev/null 2>&1 || die "the agent dispute-agent does not exist: the platform install must use examples/use-cases/bank/values.yaml"
CODEMODE=$("${KC[@]}" get virtualmcpservers.toolhive.stacklok.dev tools-disputes -n "$MCPNS" -o jsonpath='{.spec.config.codeMode.enabled}' 2>/dev/null) \
  || die "cannot read the tool server of the profile disputes (VirtualMCPServer tools-disputes in $MCPNS): the platform install must use examples/use-cases/bank/values.yaml"
[ "$CODEMODE" != true ] || die "the tool server of the profile disputes has code mode on: a script there could chain the records tools without the model. Nothing more was changed."
# A new header value: the tool server of the group holds the old one as an environment value until it restarts.
if [ "$REGENERATED" = 1 ]; then
  say "the header value changed: restarting the tool server of the group disputes"
  "${KC[@]}" rollout restart deployment/tools-disputes -n "$MCPNS" >/dev/null
  "${KC[@]}" rollout status deployment/tools-disputes -n "$MCPNS" --timeout=300s >/dev/null || die "the tool server tools-disputes did not become ready after the restart"
fi

# ---- 8. the desk caller, the knowledge base and the graph -------------------------------------------------------------------------
"${KC[@]}" create serviceaccount disputes-desk -n "$DESK_NS" --dry-run=client -o yaml | "${KC[@]}" apply -f - >/dev/null
say "ServiceAccount $DESK_NS/disputes-desk is ready (the caller rule is in values.yaml)"
say "loading the documents into the collection $COLLECTION"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_INGEST" "$HERE/seed/kb" "$COLLECTION"
say "loading the graph facts into the fact set $FACTSET"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_GRAPH_LOAD" "$COLLECTION" "$FACTSET" "$HERE/seed/graph/dispute-facts.yaml"

# ---- 9. scenarios for the stub model: checked, not made --------------------------------------------------------------------------
# The chart ships them (STUB_SCENARIOS on the platform install, ADR 0026): the ConfigMap stub-model-scenarios and the mount belong to the release.
if [ "$BESIDE" = 1 ]; then
  say "beside the full demo: the agent uses the model of your install (claude-haiku); no scenario was set"
elif "${KC[@]}" get deployment stub-model -n agentgateway-system >/dev/null 2>&1; then
  if SCN_CM=$("${KC[@]}" get configmap stub-model-scenarios -n agentgateway-system -o json 2>/dev/null); then
    if printf '%s' "$SCN_CM" | jq -e '.data["scenario.json"] != null' >/dev/null 2>&1; then
      say "the stub model has scenarios from the chart (runs with them are scripted by the stub model, not the behaviour of a model)"
    else
      echo "WARN: the ConfigMap stub-model-scenarios has no scenario.json, so the stub will not work the bank cases. Run the platform install again with STUB_SCENARIOS=examples/use-cases/bank/eval/scenario.json (and the same VALUES_FILE)." >&2
    fi
  else
    echo "WARN: the stub model has no scenarios, so it will not work the bank cases. Run the platform install again with STUB_SCENARIOS=examples/use-cases/bank/eval/scenario.json (and the same VALUES_FILE)." >&2
  fi
else
  say "no stub model in this cluster: no scenario is needed (a real model works the case from the agent instructions)"
fi

cat <<EOF

The bank use case is installed. Next (set CLUSTER=$CLUSTER on every call):
  examples/use-cases/bank/ctl.sh ask "Work case DSP-$(date +%Y)-0001"      # the agent works the case and stops at an approval request
  examples/use-cases/bank/ctl.sh approvals                                  # what waits for the desk lead
  examples/use-cases/bank/ctl.sh approve APR-0001                           # read the exact request, then decide as desk:lead-1
See examples/use-cases/bank/README.md for the six minute demo, the live proof checklist and what is not proven.
EOF
