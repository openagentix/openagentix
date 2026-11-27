#!/usr/bin/env bash
# Installs the equipment use case (Kestrel Valley Machinery service event agent) on a LOCAL kind cluster, end to end:
#
#   CLUSTER=oa-equipment-demo examples/use-cases/equipment/install.sh         the quick start plus the use case, offline: the stub model with the scenarios (no key, no token)
#   VALUES_FILE="<the list you installed the full demo with>" CLUSTER=<its cluster> \
#     examples/use-cases/equipment/install.sh --beside-full-demo              add the agent to a full demo install (values-full-demo.yaml, composed AFTER your list)
#   CLUSTER=<the bank cluster> examples/use-cases/equipment/install.sh --with-bank
#                                                                             add the agent to a cluster that has the quick start and the bank use case (both agents
#                                                                             on one platform install; the bank must be installed first, with its own install.sh)
#   CLUSTER=<name> examples/use-cases/equipment/install.sh --skip-platform    only the records service, its Secrets, the desk caller and the documents (the platform install ran already)
#   CLUSTER=<name> examples/use-cases/equipment/install.sh --uninstall        removes what this script made (not the chart values: see the README, "Uninstall")
#
# There is NO default cluster: set CLUSTER (the kind cluster name) or KUBE_CONTEXT, so that a script never acts on a cluster by guess. The script refuses any
# context that is not kind-* (also for --uninstall), and it refuses the context kind-openagentix, the name of a full demo cluster, unless --beside-full-demo is
# given: a default run never touches the cluster you run a full demo on. It never deletes a cluster. It makes one, with the repository's kind config, only when no
# kube context of that name exists and --beside-full-demo is not given.
#
# What it does, in order (ADR 0026: the records service joins the platform through mcp.endpoints, so it and its Secrets come FIRST). Every step can be run again.
#   0. the guards above; refuses to run the quick start install on a release that has more than the quick start and this use case (the platform installer
#      replaces the release values on every run: it would drop them). On such a release use --beside-full-demo, or --with-bank for the bank use case;
#   1. composes the values: hack/compose-values.sh merges components/quickstart/values.yaml and values.yaml by entry name and reports what the second adds
#      (with --with-bank: the quick start, the bank's values.yaml, then this one; with --beside-full-demo: your files merged the way Helm merges them, then
#      values-full-demo.yaml composed after them, after a check that the merge renders exactly like your list);
#   2. builds the records image (tag from a hash of its source) and loads it into the kind nodes;
#   3. creates the namespace kestrel-records and, only when ALL are absent, four Secrets from generated values, always through stdin, never printed, never an
#      argument: `records-approvers` (the SHA-256 of the dealer manager's token) and `records-approver-token` (the token itself, read by ctl.sh) in kestrel-records;
#      `records-mcp-expected` (kestrel-records, read by the records service as a file) and `dealer-records-mcp-auth` (the tool namespace, read by the tool gateway)
#      with the SAME header value `Bearer <token>`. When only some exist (an earlier run stopped half way) all are made again with new values;
#   4. applies manifests/records.yaml (the service, a base policy that admits nothing) and waits for it;
#   5. runs the platform installer (./install.sh) with the composed values. Offline it sets PROFILE=quickstart and STUB_SCENARIOS=eval/scenario.json (ADR 0026)
#      and removes every provider key from the environment of that run, so the stub answers. The chart renders the endpoint, the group, the profile's tool
#      server and the policies; the platform installer checks that the tool server of the group sees the endpoint as ready;
#   6. makes the ServiceAccount openagentix-system/service-desk (the caller of the service agent; the rule is in values.yaml);
#   7. loads seed/kb into the collection kestrel-service and seed/graph into the graph (hack/kb-ingest.sh, hack/kb-graph-load.sh);
#   8. offline: checks that the stub model has the scenarios. A run with them is SCRIPTED by the stub model, not the behaviour of a model: say so wherever
#      you report it.
#
# One records deployment each: this use case runs its own records service (domain equipment) in kestrel-records, with its own endpoint (dealer-records), group
# (dealer), profile (dealer) and Secrets. The bank use case runs another one in fernvale-records. The two share no record, no Secret and no tool.
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
BANK=$ROOT/examples/use-cases/bank
NS=kestrel-records
BANK_NS=fernvale-records
MCPNS=mcp-tools
AUTH_SECRET=dealer-records-mcp-auth
COLLECTION=kestrel-service
FACTSET=kestrel-fleet
DESK_NS=openagentix-system
FULL_DEMO_CONTEXT=kind-openagentix
KC=("$KUBECTL" --context "$KUBE_CONTEXT")

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

# The guard comes first, before any option runs: --uninstall deletes things too.
case "$KUBE_CONTEXT" in
  kind-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind cluster (kind-<name>). Set CLUSTER or KUBE_CONTEXT. Nothing was changed." ;;
esac

MODE=install; SKIP_PLATFORM=0; BESIDE=0; WITH_BANK=0
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    --skip-platform) SKIP_PLATFORM=1 ;;
    --beside-full-demo) BESIDE=1 ;;
    --with-bank) WITH_BANK=1 ;;
    -h|--help) sed -n 2,52p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (--beside-full-demo, --with-bank, --skip-platform, --uninstall, -h; the stub model scenarios are shipped by the platform install, STUB_SCENARIOS)" ;;
  esac
done

# The name of the full demo cluster: a default run must never reach it. Only --beside-full-demo says "yes, this is my full demo cluster".
if [ "$KUBE_CONTEXT" = "$FULL_DEMO_CONTEXT" ] && [ "$BESIDE" != 1 ]; then
  die "KUBE_CONTEXT is '$KUBE_CONTEXT', the name of a full demo cluster. This script does not act on it unless you give --beside-full-demo (and the VALUES_FILE list you installed the full demo with). For a cluster of its own use another name, for example CLUSTER=oa-equipment-demo. Nothing was changed."
fi

if [ "$MODE" = uninstall ]; then
  say "removing the equipment use case objects from $KUBE_CONTEXT (the chart values stay: install the platform again without values.yaml and without STUB_SCENARIOS to remove the agent, the profile, the endpoint and the scenarios)"
  "${KC[@]}" delete secret "$AUTH_SECRET" -n "$MCPNS" --ignore-not-found
  "${KC[@]}" delete namespace "$NS" --ignore-not-found
  "${KC[@]}" delete serviceaccount service-desk -n "$DESK_NS" --ignore-not-found
  say "the knowledge base keeps the collection $COLLECTION and the fact set $FACTSET; remove them with the kb admin API if you want"
  exit 0
fi

command -v jq >/dev/null || die "jq is required"
[ -x "$PLATFORM_INSTALL" ] || [ -f "$PLATFORM_INSTALL" ] || die "the platform installer is not at $PLATFORM_INSTALL"
[ "$BESIDE" = 0 ] || [ "$SKIP_PLATFORM" = 0 ] || die "--beside-full-demo runs the platform installer: do not combine it with --skip-platform. Nothing was changed."
[ "$WITH_BANK" = 0 ] || [ "$BESIDE" = 0 ] || die "--with-bank and --beside-full-demo are two different installs: give one of them. Nothing was changed."
[ "$WITH_BANK" = 0 ] || [ "$SKIP_PLATFORM" = 0 ] || die "--with-bank composes the platform values: do not combine it with --skip-platform. Nothing was changed."
if [ "$BESIDE" = 1 ] && [ -z "${VALUES_FILE:-}" ]; then
  die "--beside-full-demo needs VALUES_FILE: the same list of files you installed the full demo with. Helm replaces the release values on every run, so a list that is missing would drop what it set. Nothing was changed."
fi

ctx_exists() { local c; c=$("${KC[@]}" config get-contexts -o name 2>/dev/null) || return 1; printf '%s\n' "$c" | grep -qx "$KUBE_CONTEXT"; }

# ---- 0a. with the bank: the bank use case must be there (this script only reads it) ----------------------------------------------
if [ "$WITH_BANK" = 1 ]; then
  [ -f "$BANK/values.yaml" ] || die "cannot find $BANK/values.yaml. Nothing was changed."
  if ! ctx_exists; then die "--with-bank needs the cluster of your bank use case to exist: no kube context '$KUBE_CONTEXT'. Nothing was changed."; fi
  if ! "${KC[@]}" get namespace "$BANK_NS" >/dev/null 2>&1 || ! "${KC[@]}" get secret records-mcp-auth -n "$MCPNS" >/dev/null 2>&1; then
    die "the bank use case is not installed in $KUBE_CONTEXT (no namespace $BANK_NS or no Secret records-mcp-auth in $MCPNS). Install it first with examples/use-cases/bank/install.sh, then run this with --with-bank. Nothing was changed."
  fi
fi

# ---- 0b. the release must not lose anything -----------------------------------------------------------------------------------------
# The platform installer replaces the release values. Without --beside-full-demo this script installs the quick start plus this use case (plus the bank's
# with --with-bank), so a release that has more than that would lose it (and, offline, every provider key is removed, so the model would become the stub).
# Refuse, and say what would be lost.
release_extras() { # prints what the existing release has beyond the quick start and this use case, one thing per line; fails when it cannot tell
  local out
  ctx_exists || return 0   # no such context yet: the cluster is made below, nothing can be lost
  if ! out=$("$HELM" get values "$RELEASE" -n "$RELEASE_NS" --kube-context "$KUBE_CONTEXT" -o json 2>&1); then
    case "$out" in *"not found"*) return 0 ;; esac
    echo "cannot read the values of the release $RELEASE in $KUBE_CONTEXT: $(printf '%s' "$out" | head -1)" >&2
    return 1
  fi
  printf '%s' "$out" | jq -r --argjson bank "$WITH_BANK" '
    ($bank == 1) as $b
    | [ (if ((.schedules // []) | map(.name) - ["fleet-sweep"] - (if $b then ["deadline-sweep"] else [] end) | length) > 0 then "schedules" else empty end),
      (if (.bridge.enabled // false) == true then "the Telegram bridge" else empty end),
      (if ((.channels.kourier.enabled // false) == true) or (((.channels.bindings // []) | length) > 0) then "channels" else empty end),
      (if (.notify.enabled // false) == true then "notify" else empty end),
      (if (.memory.enabled // false) == true then "memory" else empty end),
      (if (.diagnostics.enabled // false) == true then "diagnostics" else empty end),
      (if (.mcp.virtual.codeMode.enabled // false) == true then "code mode on the shared tool server" else empty end),
      (((.agents // []) | map(.name) - ["service-agent"] - (if $b then ["dispute-agent"] else [] end)) | if length > 0 then "agents: " + join(", ") else empty end),
      (((.mcp.profiles // []) | map(.name) - ["lookup", "dealer"] - (if $b then ["disputes"] else [] end)) | if length > 0 then "tool profiles: " + join(", ") else empty end),
      (((.mcp.servers // []) | map(.name) - ["osv"]) | if length > 0 then "tool servers: " + join(", ") else empty end),
      (((.mcp.endpoints // []) | map(.name) - ["dealer-records"] - (if $b then ["records"] else [] end)) | if length > 0 then "endpoints: " + join(", ") else empty end),
      (((.governance.a2a.callers // []) | map(.name) - ["quickstart-ask", "service-desk"] - (if $b then ["disputes-desk"] else [] end)) | if length > 0 then "gate callers: " + join(", ") else empty end)
    ] | .[]'
}
if [ "$SKIP_PLATFORM" != 1 ] && [ "$BESIDE" != 1 ]; then
  EXTRAS=$(release_extras) || die "refusing to run the platform installer on a release I cannot read. Nothing was changed."
  if [ -n "$EXTRAS" ]; then
    die "the release $RELEASE in $KUBE_CONTEXT has more than the quick start: $(printf '%s' "$EXTRAS" | tr '\n' ';' | sed 's/;/; /g'). The platform installer would replace those values and drop them. Use a cluster of its own, add the agent to your install with: VALUES_FILE=\"<your files>\" CLUSTER=<its cluster> $0 --beside-full-demo, or, when the extra is the bank use case, run $0 --with-bank. Nothing was changed."
  fi
fi

# ---- 1. compose the values (local work only: nothing in the cluster has changed yet) --------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
VALUES_COMPOSED="$TMP/equipment-values.yaml"
SCENARIOS="$HERE/eval/scenario.json"
SCN_KEY=scenario.json
if [ "$SKIP_PLATFORM" != 1 ]; then
  if [ "$BESIDE" = 1 ]; then
    say "composing the values: your list ($VALUES_FILE) first, then examples/use-cases/equipment/values-full-demo.yaml (the endpoint, the profile dealer, the agent service-agent, the sweep and the caller)"
    # Your own files are merged first, the way Helm merges them (maps deep, a later file wins, a list is REPLACED by a later file), into one file. That is
    # exactly your install, so compose-values.sh must not judge it. The merge is checked instead: the chart must render byte for byte the same from your
    # list and from the merged file. Only then is values-full-demo.yaml composed after it by compose-values.sh, without --later-wins: it joins the lists by
    # name and never drops an entry of yours, and a name or a security key that clashes is refused, and nothing is installed.
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
  elif [ "$WITH_BANK" = 1 ]; then
    say "composing the values (components/quickstart/values.yaml, examples/use-cases/bank/values.yaml and examples/use-cases/equipment/values.yaml)"
    "$COMPOSE" -o "$VALUES_COMPOSED" "$ROOT/components/quickstart/values.yaml" "$BANK/values.yaml" "$HERE/values.yaml" || die "the values did not compose (the reason is above). Nothing was changed."
    # Both use cases ship scenarios: one directory, two files (the stub model reads every *.json of it; each scenario matches its own agent prompt).
    mkdir "$TMP/scenarios"
    cp "$BANK/eval/scenario.json" "$TMP/scenarios/bank.json"
    cp "$HERE/eval/scenario.json" "$TMP/scenarios/equipment.json"
    SCENARIOS="$TMP/scenarios"; SCN_KEY=equipment.json
  else
    say "composing the values (components/quickstart/values.yaml and examples/use-cases/equipment/values.yaml)"
    "$COMPOSE" -o "$VALUES_COMPOSED" "$ROOT/components/quickstart/values.yaml" "$HERE/values.yaml" || die "the values did not compose (the reason is above). Nothing was changed."
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
  IMAGE=${RECORDS_IMAGE:-registry.local/oa/records-equipment:$(src_tag "$ROOT/examples/use-cases/records")}
fi
[[ "$IMAGE" =~ ^[a-z0-9][A-Za-z0-9._/:@-]*$ ]] || die "the image name '$IMAGE' has characters that are not allowed in an image reference"
if [ "${SKIP_BUILD:-0}" != 1 ]; then
  say "building $IMAGE"
  "$DOCKER" build -q --build-arg DOMAIN=equipment -t "$IMAGE" "$ROOT/examples/use-cases/records" >/dev/null
  say "loading it into the kind cluster $CLUSTER"
  "$KIND" load docker-image "$IMAGE" --name "$CLUSTER" >/dev/null
fi

# ---- 3. namespaces and Secrets -------------------------------------------------------------------------------------------------
say "namespaces $NS and $MCPNS"
"${KC[@]}" get namespace "$NS" >/dev/null 2>&1 || "${KC[@]}" create namespace "$NS" >/dev/null   # the labels (restricted pod security) come with the manifest below
"${KC[@]}" get namespace "$MCPNS" >/dev/null 2>&1 || "${KC[@]}" create namespace "$MCPNS" >/dev/null   # the chart's header Secret reference needs the Secret before the chart is applied
HAVE=0; ALL=1
for s in "records-approvers:$NS" "records-approver-token:$NS" "records-mcp-expected:$NS" "$AUTH_SECRET:$MCPNS"; do
  if "${KC[@]}" get secret "${s%%:*}" -n "${s##*:}" >/dev/null 2>&1; then HAVE=1; else ALL=0; fi
done
REGENERATED=0
if [ "$ALL" = 1 ]; then
  say "the Secrets exist: not changed"
else
  if [ "$HAVE" = 1 ]; then
    say "only some of the four Secrets exist (an earlier run stopped half way): making all again with new values"
    "${KC[@]}" delete secret records-approvers records-approver-token records-mcp-expected -n "$NS" --ignore-not-found >/dev/null
    "${KC[@]}" delete secret "$AUTH_SECRET" -n "$MCPNS" --ignore-not-found >/dev/null
    REGENERATED=1
  fi
  command -v openssl >/dev/null || die "openssl is required to generate the tokens"
  TOKEN=$(openssl rand -hex 24)
  CRED="Bearer $(openssl rand -hex 24)"
  [ "${#TOKEN}" -ge 32 ] && [ "${#CRED}" -ge 39 ] || die "could not generate a token"
  SUM=$(printf %s "$TOKEN" | openssl dgst -sha256 | sed 's/^.* //')
  printf '[{"id":"dealer:svc-mgr-02","role":"dealer-manager","token_sha256":"%s"}]\n' "$SUM" \
    | "${KC[@]}" create secret generic records-approvers -n "$NS" --from-file=approvers.json=/dev/stdin >/dev/null
  printf %s "$TOKEN" | "${KC[@]}" create secret generic records-approver-token -n "$NS" --from-file=token=/dev/stdin >/dev/null
  printf %s "$CRED" | "${KC[@]}" create secret generic records-mcp-expected -n "$NS" --from-file=value=/dev/stdin >/dev/null
  printf %s "$CRED" | "${KC[@]}" create secret generic "$AUTH_SECRET" -n "$MCPNS" --from-file=value=/dev/stdin >/dev/null
  unset TOKEN SUM CRED
  say "created the Secrets (approver id dealer:svc-mgr-02, role dealer-manager; the MCP header value for the tool gateway and the records service): the values are read by ctl.sh and the services, and are not shown"
fi

# ---- 4. the service ------------------------------------------------------------------------------------------------------------
say "applying the records service"
sed "s#IMAGE_PLACEHOLDER#$IMAGE#" "$HERE/manifests/records.yaml" | "${KC[@]}" apply -f - >/dev/null
# The service reads its files when it starts (the approvers) and per request (the MCP credential): a new token needs a new pod.
if [ "$REGENERATED" = 1 ]; then "${KC[@]}" rollout restart deployment/records -n "$NS" >/dev/null; fi
"${KC[@]}" rollout status deployment/records -n "$NS" --timeout=180s >/dev/null || die "the records pod did not become ready: kubectl --context $KUBE_CONTEXT describe pod -n $NS -l app=records"

# ---- 5. the platform -----------------------------------------------------------------------------------------------------------
if [ "$SKIP_PLATFORM" != 1 ]; then
  if [ "$BESIDE" = 1 ]; then
    say "platform install beside the full demo: your model, your provider keys and your scenarios stay as they are (nothing is unset)"
    env -u PROFILE -u STUB_SCENARIOS CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" VALUES_FILE="$VALUES_COMPOSED" "$PLATFORM_INSTALL"
  else
    say "platform install, offline: the stub model with the scenarios of ${SCENARIOS#"$ROOT"/} (a run with them is SCRIPTED, not the behaviour of a model)"
    env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GOOGLE_API_KEY -u MODEL_BASE_URL -u MODEL_NAME -u MODEL_PROVIDER -u MODEL_API_KEY \
      CLUSTER="$CLUSTER" KUBE_CONTEXT="$KUBE_CONTEXT" PROFILE=quickstart VALUES_FILE="$VALUES_COMPOSED" STUB_SCENARIOS="$SCENARIOS" "$PLATFORM_INSTALL"
  fi
fi

# ---- 6. the platform must have what the use case needs ----------------------------------------------------------------------------
"${KC[@]}" get namespace openagentix-knowledge >/dev/null 2>&1 || die "the knowledge base is not installed: the platform install must use examples/use-cases/equipment/values.yaml (it turns the knowledge base and the graph on)"
"${KC[@]}" get agents.api.kagent.dev service-agent -n kagent >/dev/null 2>&1 || die "the agent service-agent does not exist: the platform install must use examples/use-cases/equipment/values.yaml"
CODEMODE=$("${KC[@]}" get virtualmcpservers.toolhive.stacklok.dev tools-dealer -n "$MCPNS" -o jsonpath='{.spec.config.codeMode.enabled}' 2>/dev/null) \
  || die "cannot read the tool server of the profile dealer (VirtualMCPServer tools-dealer in $MCPNS): the platform install must use examples/use-cases/equipment/values.yaml"
[ "$CODEMODE" != true ] || die "the tool server of the profile dealer has code mode on: a script there could chain the records tools without the model. Nothing more was changed."
# A new header value: the tool server of the group holds the old one as an environment value until it restarts.
if [ "$REGENERATED" = 1 ]; then
  say "the header value changed: restarting the tool server of the group dealer"
  "${KC[@]}" rollout restart deployment/tools-dealer -n "$MCPNS" >/dev/null
  "${KC[@]}" rollout status deployment/tools-dealer -n "$MCPNS" --timeout=300s >/dev/null || die "the tool server tools-dealer did not become ready after the restart"
fi

# ---- 7. the service desk caller, the knowledge base and the graph -----------------------------------------------------------------
"${KC[@]}" create serviceaccount service-desk -n "$DESK_NS" --dry-run=client -o yaml | "${KC[@]}" apply -f - >/dev/null
say "ServiceAccount $DESK_NS/service-desk is ready (the caller rule is in values.yaml)"
say "loading the documents into the collection $COLLECTION"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_INGEST" "$HERE/seed/kb" "$COLLECTION"
say "loading the graph facts into the fact set $FACTSET"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_GRAPH_LOAD" "$COLLECTION" "$FACTSET" "$HERE/seed/graph/service-facts.yaml"

# ---- 8. scenarios for the stub model: checked, not made --------------------------------------------------------------------------
# The chart ships them (STUB_SCENARIOS on the platform install, ADR 0026): the ConfigMap stub-model-scenarios and the mount belong to the release.
if [ "$BESIDE" = 1 ]; then
  say "beside the full demo: the agent uses the model of your install (claude-haiku); no scenario was set"
elif "${KC[@]}" get deployment stub-model -n agentgateway-system >/dev/null 2>&1; then
  if SCN_CM=$("${KC[@]}" get configmap stub-model-scenarios -n agentgateway-system -o json 2>/dev/null); then
    if printf '%s' "$SCN_CM" | jq -e --arg k "$SCN_KEY" '.data[$k] != null' >/dev/null 2>&1; then
      say "the stub model has scenarios from the chart (runs with them are scripted by the stub model, not the behaviour of a model)"
    else
      echo "WARN: the ConfigMap stub-model-scenarios has no $SCN_KEY, so the stub will not work the equipment cases. Run the platform install again with STUB_SCENARIOS=examples/use-cases/equipment/eval/scenario.json (and the same VALUES_FILE)." >&2
    fi
  else
    echo "WARN: the stub model has no scenarios, so it will not work the equipment cases. Run the platform install again with STUB_SCENARIOS=examples/use-cases/equipment/eval/scenario.json (and the same VALUES_FILE)." >&2
  fi
else
  say "no stub model in this cluster: no scenario is needed (a real model works the case from the agent instructions)"
fi

cat <<EOF

The equipment use case is installed. Next (set CLUSTER=$CLUSTER on every call):
  examples/use-cases/equipment/ctl.sh fault KH4120-00317 E-317 --ask       # a machine event: the case is opened and the agent works it, then stops at an approval request
  examples/use-cases/equipment/ctl.sh approvals                            # what waits for the dealer manager
  examples/use-cases/equipment/ctl.sh approve APR-0001                     # read the exact request, then decide as dealer:svc-mgr-02
See examples/use-cases/equipment/README.md for the six minute demo, the live proof checklist and what is not proven.
EOF
