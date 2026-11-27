#!/usr/bin/env bash
# Installs the parts of the bank use case that are not chart values: the records service, its tool registration, the desk's
# ServiceAccount, the knowledge base documents and the graph facts. Run it AFTER the platform install that used values.yaml:
#
#   PROFILE=quickstart VALUES_FILE=examples/use-cases/bank/values.yaml ./install.sh
#   examples/use-cases/bank/install.sh
#   examples/use-cases/bank/install.sh --uninstall        # removes what this script made (not the chart values)
#
# Local kind cluster only. It never creates or deletes a cluster. Every step can be run again.
#   1. builds the records image (tag from a hash of its source) and loads it into the kind nodes;
#   2. creates the namespace fernvale-records, then (only when absent) two Secrets from a generated token: `records-approvers` holds the
#      SHA-256 hash of the desk lead's token and is mounted into the pod; `records-approver-token` holds the token itself for
#      examples/use-cases/bank/ctl.sh. The token is never printed, never put in a file or in an argument list;
#   3. applies manifests/records.yaml and manifests/tool-registration.yaml (an MCPServerEntry, like the chart's knowledge entry);
#   4. creates the ServiceAccount openagentix-system/disputes-desk, the caller of the dispute agent (the rule is in values.yaml);
#   5. loads seed/kb into the collection fernvale-disputes and seed/graph into the graph (hack/kb-ingest.sh, hack/kb-graph-load.sh);
#   6. when the stub model is the model: mounts eval/scenario.json into it (a stopgap, see README "What could not be wired"). Helm undoes it
#      on the next chart upgrade; run this script again then. --no-scenarios skips it (a real model needs no scenario).
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
K="$KUBECTL --context $KUBE_CONTEXT"

die(){ echo "ERROR: $*" >&2; exit 1; }
say(){ echo "==> $*"; }

MODE=install; SCENARIOS=auto
for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    --no-scenarios) SCENARIOS=no ;;
    --scenarios) SCENARIOS=yes ;;
    -h|--help) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $arg (--uninstall, --no-scenarios, --scenarios)" ;;
  esac
done

if [ "$MODE" = uninstall ]; then
  say "removing the bank use case objects (the chart values stay: install the platform again without values.yaml to remove the agent)"
  $K delete -f "$HERE/manifests/tool-registration.yaml" --ignore-not-found
  $K delete namespace "$NS" --ignore-not-found
  $K delete serviceaccount disputes-desk -n "$DESK_NS" --ignore-not-found
  $K delete configmap bank-scenarios -n agentgateway-system --ignore-not-found
  say "the knowledge base keeps the collection $COLLECTION and the fact set $FACTSET; remove them with the kb admin API if you want"
  exit 0
fi

# ---- 0. the platform must be there, with values.yaml --------------------------------------------------------------------
case "$KUBE_CONTEXT" in
  kind-*) ;;
  *) die "KUBE_CONTEXT is '$KUBE_CONTEXT': this script is for a local kind cluster (kind-<name>). Set CLUSTER or KUBE_CONTEXT." ;;
esac
$K get namespace mcp-tools >/dev/null 2>&1 || die "the namespace mcp-tools does not exist: install the platform first (PROFILE=quickstart VALUES_FILE=examples/use-cases/bank/values.yaml ./install.sh)"
$K get namespace openagentix-knowledge >/dev/null 2>&1 || die "the knowledge base is not installed: the platform install must use examples/use-cases/bank/values.yaml (it turns the knowledge base and the graph on)"
$K get agents.api.kagent.dev dispute-agent -n kagent >/dev/null 2>&1 || die "the agent dispute-agent does not exist: the platform install must use examples/use-cases/bank/values.yaml"

# ---- 1. image ------------------------------------------------------------------------------------------------------------
if [ "${SKIP_BUILD:-0}" = 1 ]; then
  IMAGE=${RECORDS_IMAGE:?SKIP_BUILD=1 needs RECORDS_IMAGE}
else
  # shellcheck source=/dev/null
  . "$ROOT/hack/image-tag.sh"
  IMAGE=${RECORDS_IMAGE:-registry.local/oa/records-bank:$(src_tag "$ROOT/examples/use-cases/records")}
  say "building $IMAGE"
  $DOCKER build -q --build-arg DOMAIN=bank -t "$IMAGE" "$ROOT/examples/use-cases/records" >/dev/null
  say "loading it into the kind cluster $CLUSTER"
  $KIND load docker-image "$IMAGE" --name "$CLUSTER" >/dev/null
fi

# ---- 2. namespace and Secrets --------------------------------------------------------------------------------------------
say "namespace $NS"
$K get namespace "$NS" >/dev/null 2>&1 || $K create namespace "$NS" >/dev/null   # the labels (restricted pod security) come with the manifest below
if $K get secret records-approvers -n "$NS" >/dev/null 2>&1; then
  say "the approver Secrets exist: not changed"
else
  command -v openssl >/dev/null || die "openssl is required to generate the approver token"
  TOKEN=$(openssl rand -hex 24)
  [ "${#TOKEN}" -ge 32 ] || die "could not generate a token"
  SUM=$(printf %s "$TOKEN" | openssl dgst -sha256 | sed 's/^.* //')
  printf '[{"id":"desk:lead-1","role":"desk-lead","token_sha256":"%s"}]\n' "$SUM" \
    | $K create secret generic records-approvers -n "$NS" --from-file=approvers.json=/dev/stdin >/dev/null
  printf %s "$TOKEN" | $K create secret generic records-approver-token -n "$NS" --from-file=token=/dev/stdin >/dev/null
  unset TOKEN SUM
  say "created the approver Secrets (approver id desk:lead-1, role desk-lead); the token is read by ctl.sh and is not shown"
fi

# ---- 3. the service and its registration --------------------------------------------------------------------------------
say "applying the records service"
sed "s#IMAGE_PLACEHOLDER#$IMAGE#" "$HERE/manifests/records.yaml" | $K apply -f - >/dev/null
$K rollout status deployment/records -n "$NS" --timeout=180s >/dev/null || die "the records pod did not become ready: $K describe pod -n $NS -l app=records"
say "registering it with the tool gateway (MCPServerEntry records in mcp-tools)"
$K apply -f "$HERE/manifests/tool-registration.yaml" >/dev/null || die "could not apply the tool registration (are the ToolHive CRDs installed?)"

# ---- 4. the desk caller --------------------------------------------------------------------------------------------------
$K create serviceaccount disputes-desk -n "$DESK_NS" --dry-run=client -o yaml | $K apply -f - >/dev/null
say "ServiceAccount $DESK_NS/disputes-desk is ready (the caller rule is in values.yaml)"

# ---- 5. knowledge base and graph -----------------------------------------------------------------------------------------
say "loading the documents into the collection $COLLECTION"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_INGEST" "$HERE/seed/kb" "$COLLECTION"
say "loading the graph facts into the fact set $FACTSET"
KUBECTL="$KUBECTL" KUBE_CONTEXT="$KUBE_CONTEXT" "$KB_GRAPH_LOAD" "$COLLECTION" "$FACTSET" "$HERE/seed/graph/dispute-facts.yaml"

# ---- 6. scenarios for the stub model -------------------------------------------------------------------------------------
if [ "$SCENARIOS" = auto ]; then
  if $K get deployment stub-model -n agentgateway-system >/dev/null 2>&1; then SCENARIOS=yes; else SCENARIOS=no; say "no stub model in this cluster: no scenario is mounted (a real model works the case from the agent instructions)"; fi
fi
if [ "$SCENARIOS" = yes ]; then
  say "mounting eval/scenario.json into the stub model (a stopgap outside the chart: Helm removes it on the next upgrade, run this script again then)"
  $K create configmap bank-scenarios -n agentgateway-system --from-file=scenario.json="$HERE/eval/scenario.json" --dry-run=client -o yaml | $K apply -f - >/dev/null
  $K patch deployment stub-model -n agentgateway-system --type strategic -p '{"spec":{"template":{"spec":{"volumes":[{"name":"bank-scenarios","configMap":{"name":"bank-scenarios"}}],"containers":[{"name":"stub-model","env":[{"name":"STUB_MODEL_SCENARIOS","value":"/scenarios/scenario.json"}],"volumeMounts":[{"name":"bank-scenarios","mountPath":"/scenarios","readOnly":true}]}]}}}}' >/dev/null
  $K rollout status deployment/stub-model -n agentgateway-system --timeout=120s >/dev/null || die "the stub model did not restart with the scenarios: check the file with: $K logs -n agentgateway-system deploy/stub-model"
fi

cat <<EOF

The bank use case is installed. Next:
  examples/use-cases/bank/ctl.sh ask "Work case DSP-$(date +%Y)-0001"      # the agent works the case and stops at an approval request
  examples/use-cases/bank/ctl.sh approvals                                  # what waits for the desk lead
  examples/use-cases/bank/ctl.sh approve APR-0001                           # read the exact request, then decide as desk:lead-1
See examples/use-cases/bank/README.md for the six minute demo and what is not proven.
EOF
