#!/usr/bin/env bash
# Installs the parts of the bank use case that are not chart values: the records service, its tool registration, the desk's
# ServiceAccount, the knowledge base documents and the graph facts. Run it AFTER the platform install that used values.yaml:
#
#   PROFILE=quickstart VALUES_FILE=examples/use-cases/bank/values.yaml STUB_SCENARIOS=examples/use-cases/bank/eval/scenario.json ./install.sh
#   examples/use-cases/bank/install.sh
#   examples/use-cases/bank/install.sh --uninstall        # removes what this script made (not the chart values)
#
# Local kind cluster only: the script refuses any context that is not kind-* (also for --uninstall). It never creates or deletes a
# cluster. Every step can be run again.
#   1. builds the records image (tag from a hash of its source) and loads it into the kind nodes;
#   2. creates the namespace fernvale-records, then (only when absent) two Secrets from a generated token: `records-approvers` holds the
#      SHA-256 hash of the desk lead's token and is mounted into the pod; `records-approver-token` holds the token itself for
#      examples/use-cases/bank/ctl.sh. The token is never printed, never put in a file or in an argument list. When only one of the two
#      exists (an earlier run stopped half way), both are made again with a new token, because the token cannot be read back from a hash;
#   3. applies manifests/records.yaml and manifests/tool-registration.yaml (an MCPServerEntry, like the chart's knowledge entry);
#   4. creates the ServiceAccount openagentix-system/disputes-desk, the caller of the dispute agent (the rule is in values.yaml);
#   5. loads seed/kb into the collection fernvale-disputes and seed/graph into the graph (hack/kb-ingest.sh, hack/kb-graph-load.sh);
#   6. when the stub model is the model: only CHECKS that it has scenarios. The scenarios are not made here: the platform install ships
#      eval/scenario.json through the chart (STUB_SCENARIOS, ADR 0026), so a chart upgrade keeps them. A stub without them gets a warning.
#      A run with them is SCRIPTED by the stub model, not the behaviour of a model: say so wherever you report it.
#
# It REFUSES to install when the shared tool server (the vMCP `tools`) has code mode on, or when any agent other than dispute-agent uses
# it: the records tools join that shared server, and a script run there could call the write tools. Quick start only (README).
#
# Env: CLUSTER (kind cluster name, default openagentix)  KUBE_CONTEXT (default kind-$CLUSTER)  KUBECTL  DOCKER  KIND
#      KB_INGEST, KB_GRAPH_LOAD (the two hack scripts)  SKIP_BUILD=1 (use RECORDS_IMAGE as it is)  RECORDS_IMAGE
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
CLUSTER=${CLUSTER:-openagentix}
KUBE_CONTEXT=${KUBE_CONTEXT:-kind-$CLUSTER}
KUBECTL=${KUBECTL:-kubectl}
DOCKER=${DOCKER:-docker}
KIND=${KIND:-kind}
KB_INGEST=${KB_INGEST:-$ROOT/hack/kb-ingest.sh}
KB_GRAPH_LOAD=${KB_GRAPH_LOAD:-$ROOT/hack/kb-graph-load.sh}
NS=fernvale-records
COLLECTION=fernvale-disputes
FACTSET=fernvale-bank
DESK_NS=openagentix-system
KC=("$KUBECTL" --context "$KUBE_CONTEXT")

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

# The guard comes first, before any option runs: --uninstall deletes things too.
case "$KUBE_CONTEXT" in
  kind-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind cluster (kind-<name>). Set CLUSTER or KUBE_CONTEXT." ;;
esac

MODE=install
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    -h|--help) sed -n 2,26p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (--uninstall; the stub model scenarios are shipped by the platform install, STUB_SCENARIOS)" ;;
  esac
done

if [ "$MODE" = uninstall ]; then
  say "removing the bank use case objects from $KUBE_CONTEXT (the chart values stay: install the platform again without values.yaml and without STUB_SCENARIOS to remove the agent and the scenarios)"
  "${KC[@]}" delete configmap bank-scenarios -n agentgateway-system --ignore-not-found   # made by the first version of this script (a kubectl patch); the chart now ships the scenarios
  "${KC[@]}" delete -f "$HERE/manifests/tool-registration.yaml" --ignore-not-found
  "${KC[@]}" delete namespace "$NS" --ignore-not-found
  "${KC[@]}" delete serviceaccount disputes-desk -n "$DESK_NS" --ignore-not-found
  say "the knowledge base keeps the collection $COLLECTION and the fact set $FACTSET; remove them with the kb admin API if you want"
  exit 0
fi

# ---- 0. the platform must be there, with values.yaml --------------------------------------------------------------------
command -v jq >/dev/null || die "jq is required"
"${KC[@]}" get namespace mcp-tools >/dev/null 2>&1 || die "the namespace mcp-tools does not exist: install the platform first (PROFILE=quickstart VALUES_FILE=examples/use-cases/bank/values.yaml ./install.sh)"
"${KC[@]}" get namespace openagentix-knowledge >/dev/null 2>&1 || die "the knowledge base is not installed: the platform install must use examples/use-cases/bank/values.yaml (it turns the knowledge base and the graph on)"
"${KC[@]}" get agents.api.kagent.dev dispute-agent -n kagent >/dev/null 2>&1 || die "the agent dispute-agent does not exist: the platform install must use examples/use-cases/bank/values.yaml"

# The records tools join the shared tool server. Nothing there limits who may call them, so refuse a cluster where another agent could.
CODEMODE=$("${KC[@]}" get virtualmcpservers.toolhive.stacklok.dev tools -n mcp-tools -o jsonpath='{.spec.config.codeMode.enabled}' 2>/dev/null) \
  || die "cannot read the shared tool server (VirtualMCPServer tools in mcp-tools): nothing was changed"
[ "$CODEMODE" != true ] || die "the shared tool server has code mode on (the full demo does). A script run there could call the records write tools. This use case supports the quick start only (README, 'Quick start only'). Nothing was changed."
TEMPLATES=$("${KC[@]}" get agenttemplates.api.kagent.dev -n kagent -o json 2>/dev/null) || die "cannot list the agent templates in kagent: nothing was changed"
OTHERS=$(printf '%s' "$TEMPLATES" | jq -r '[.items[] | select(.metadata.name != "dispute-agent-template") | select(any(.spec.tools[]?; .mcp.server.name == "toolhive-vmcp")) | .metadata.name] | join(", ")') \
  || die "cannot read the agent templates: nothing was changed"
[ -z "$OTHERS" ] || die "other agents use the shared tool server ($OTHERS). They could call the records write tools. This use case supports the quick start only (README, 'Quick start only'). Nothing was changed."

# ---- 1. image ------------------------------------------------------------------------------------------------------------
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

# ---- 2. namespace and Secrets --------------------------------------------------------------------------------------------
say "namespace $NS"
"${KC[@]}" get namespace "$NS" >/dev/null 2>&1 || "${KC[@]}" create namespace "$NS" >/dev/null   # the labels (restricted pod security) come with the manifest below
HAVE_A=0; HAVE_T=0; REGENERATED=0
"${KC[@]}" get secret records-approvers -n "$NS" >/dev/null 2>&1 && HAVE_A=1
"${KC[@]}" get secret records-approver-token -n "$NS" >/dev/null 2>&1 && HAVE_T=1
if [ "$HAVE_A" = 1 ] && [ "$HAVE_T" = 1 ]; then
  say "the approver Secrets exist: not changed"
else
  if [ "$HAVE_A$HAVE_T" != 00 ]; then
    say "only one of the two approver Secrets exists (an earlier run stopped half way): making both again with a new token"
    "${KC[@]}" delete secret records-approvers records-approver-token -n "$NS" --ignore-not-found >/dev/null
    REGENERATED=1
  fi
  command -v openssl >/dev/null || die "openssl is required to generate the approver token"
  TOKEN=$(openssl rand -hex 24)
  [ "${#TOKEN}" -ge 32 ] || die "could not generate a token"
  SUM=$(printf %s "$TOKEN" | openssl dgst -sha256 | sed 's/^.* //')
  printf '[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"%s"}]\n' "$SUM" \
    | "${KC[@]}" create secret generic records-approvers -n "$NS" --from-file=approvers.json=/dev/stdin >/dev/null
  printf %s "$TOKEN" | "${KC[@]}" create secret generic records-approver-token -n "$NS" --from-file=token=/dev/stdin >/dev/null
  unset TOKEN SUM
  say "created the approver Secrets (approver id desk:lead-1, role desk-lead); the token is read by ctl.sh and is not shown"
fi

# ---- 3. the service and its registration --------------------------------------------------------------------------------
say "applying the records service"
sed "s#IMAGE_PLACEHOLDER#$IMAGE#" "$HERE/manifests/records.yaml" | "${KC[@]}" apply -f - >/dev/null
# The service reads the approvers file when it starts: a new token needs a new pod.
if [ "$REGENERATED" = 1 ]; then "${KC[@]}" rollout restart deployment/records -n "$NS" >/dev/null; fi
"${KC[@]}" rollout status deployment/records -n "$NS" --timeout=180s >/dev/null || die "the records pod did not become ready: kubectl --context $KUBE_CONTEXT describe pod -n $NS -l app=records"
say "registering it with the tool gateway (MCPServerEntry records in mcp-tools)"
"${KC[@]}" apply -f "$HERE/manifests/tool-registration.yaml" >/dev/null || die "could not apply the tool registration (are the ToolHive CRDs installed?)"

# ---- 4. the desk caller --------------------------------------------------------------------------------------------------
"${KC[@]}" create serviceaccount disputes-desk -n "$DESK_NS" --dry-run=client -o yaml | "${KC[@]}" apply -f - >/dev/null
say "ServiceAccount $DESK_NS/disputes-desk is ready (the caller rule is in values.yaml)"

# ---- 5. knowledge base and graph -----------------------------------------------------------------------------------------
say "loading the documents into the collection $COLLECTION"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_INGEST" "$HERE/seed/kb" "$COLLECTION"
say "loading the graph facts into the fact set $FACTSET"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_GRAPH_LOAD" "$COLLECTION" "$FACTSET" "$HERE/seed/graph/dispute-facts.yaml"

# ---- 6. scenarios for the stub model: checked, not made --------------------------------------------------------------------
# The chart ships them (STUB_SCENARIOS on the platform install, ADR 0026): the ConfigMap stub-model-scenarios and the mount belong to the release.
if "${KC[@]}" get deployment stub-model -n agentgateway-system >/dev/null 2>&1; then
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

The bank use case is installed. Next:
  examples/use-cases/bank/ctl.sh ask "Work case DSP-$(date +%Y)-0001"      # the agent works the case and stops at an approval request
  examples/use-cases/bank/ctl.sh approvals                                  # what waits for the desk lead
  examples/use-cases/bank/ctl.sh approve APR-0001                           # read the exact request, then decide as desk:lead-1
See examples/use-cases/bank/README.md for the six minute demo, the live proof checklist and what is not proven.
EOF
