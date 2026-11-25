#!/usr/bin/env bash
# The control plane's CRD and admission guard against a REAL API server (kind), with no controller image and no model.
#   hack/ci/apiserver-test.sh            (make test-apiserver)
#
# What it does, in order:
#   1. creates ONE throwaway kind cluster (default name oa-ci-test, one control-plane node) with a kubeconfig of its own in a temp file,
#      so the current kube context and every other cluster stay untouched; it deletes the cluster when it ends (KEEP=1 keeps it);
#   2. applies, with server-side validation, what `helm template` renders for the control plane: the AgentDefinition CRD, the eight
#      ValidatingAdmissionPolicies and their bindings, the ResourceQuota, the key ConfigMap, the ServiceAccount, Roles and RoleBindings;
#      the five kagent kinds are installed as schema-less stand-in CRDs (hack/ci/apiserver/kagent-crds.yaml), or the real ones when
#      KAGENT_CRDS_DIR names a directory with kagent's CRD templates (helm/kagent-crds/templates of a kagent checkout);
#   3. checks status.typeChecking of every policy (it must have no warning) and that the policies were accepted at their cost;
#   4. applies components/control-plane/researcher.yaml (the CRD's schema and rules must accept it);
#   5. applies invalid definitions (the old boolean shapes, both of instructions and instructionsFrom, over-long fields, instructions that are
#      over the limit in BYTES) and expects the right rejection of each;
#   6. runs writes as the controller's ServiceAccount (impersonated, --dry-run=server) against the guard: what the controller writes is
#      allowed, and one refused write per rule family (C1: an EgressPolicy authentication, a Harness command, a ModelConfig header, a foreign
#      key ConfigMap entry, a Secret that is not a key Secret, a takeover of a foreign object, any other resource).
# Needs: kind, kubectl, helm, docker, jq, yq (the Python jq wrapper), curl. Time: about 3-5 minutes.
# Environment: KIND_CLUSTER (default oa-ci-test), KIND_NODE_IMAGE (default: kind's own), KAGENT_CRDS_DIR, KEEP=1.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLUSTER="${KIND_CLUSTER:-oa-ci-test}"
[ "$CLUSTER" != "openagentix" ] || { echo "refusing to use the cluster 'openagentix': this test creates and deletes its own" >&2; exit 2; }
for t in kind kubectl helm jq yq docker curl; do command -v "$t" >/dev/null || { echo "ERROR: '$t' is required" >&2; exit 2; }; done
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  echo "ERROR: a kind cluster named $CLUSTER already exists; delete it first (kind delete cluster --name $CLUSTER)" >&2; exit 2
fi

TMP="$(mktemp -d)"
export KUBECONFIG="$TMP/kubeconfig"     # every kubectl below uses this file and nothing else
CREATED=0
cleanup() {
  if [ "$CREATED" = 1 ] && [ "${KEEP:-0}" != 1 ]; then kind delete cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" >/dev/null 2>&1 || true; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }

# allowed <desc> <command...>: the command must succeed
allowed() { local d=$1; shift; local out; if out=$("$@" 2>&1); then ok "$d"; else bad "$d" "$(printf '%s' "$out" | head -12 | cut -c1-400)"; fi; }
# refused <desc> <pattern> <command...>: the command must fail and its output must contain the pattern (fixed string)
refused() {
  local d=$1 pat=$2; shift 2; local out
  if out=$("$@" 2>&1); then bad "$d" "the API server accepted it"; return; fi
  if printf '%s' "$out" | grep -qF -- "$pat"; then ok "$d"; else bad "$d" "refused, but not with '$pat': $(printf '%s' "$out" | head -3 | cut -c1-300)"; fi
}

SA="system:serviceaccount:openagentix-system:openagentix-control-plane"
AS=(--as="$SA")
NODE_IMAGE=()
[ -z "${KIND_NODE_IMAGE:-}" ] || NODE_IMAGE=(--image "$KIND_NODE_IMAGE")

echo "# cluster $CLUSTER (kubeconfig $KUBECONFIG)"
kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 180s ${NODE_IMAGE[@]+"${NODE_IMAGE[@]}"} >/dev/null
CREATED=1
kubectl version 2>/dev/null | head -2
for n in kagent agentgateway-system openagentix-system; do kubectl create namespace "$n" >/dev/null; done

# ---- 1. render ----
cd "$ROOT"
ARGS=(template openagentix charts/openagentix -n openagentix-system)
for f in components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml \
         components/observability/demo-values.yaml components/knowledge/graph-demo-values.yaml components/governance/demo-values.yaml \
         components/governance/profiles-demo-values.yaml components/governance/memory-demo-values.yaml components/control-plane/demo-values.yaml; do
  ARGS+=(-f "$f")
done
ARGS+=(--set 'controlPlane.policy.egress.inClusterDestinations={registry.ci.svc:5000}' --set controlPlane.policy.memory.allowed=true --set observability.baggage=true)
helm "${ARGS[@]}" | yq -c 'select(.!=null)' > "$TMP/render.jsonl"
CAT=$(jq -r 'select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]' "$TMP/render.jsonl")
jq_cat() { jq -r "$1" <<<"$CAT"; }

echo "# the CRDs and the policy objects"
if [ -n "${KAGENT_CRDS_DIR:-}" ]; then
  for f in "$KAGENT_CRDS_DIR"/api.kagent.dev_{modelconfigs,harnesses,agenttemplates,egresspolicies,agents}.yaml; do kubectl apply --server-side -f "$f" >/dev/null; done
  echo "  (kagent's real CRDs from $KAGENT_CRDS_DIR)"
else
  kubectl apply --server-side -f hack/ci/apiserver/kagent-crds.yaml >/dev/null
fi
jq -c 'select(.kind=="CustomResourceDefinition")' "$TMP/render.jsonl" | kubectl apply --server-side --validate=strict -f - >/dev/null
for c in agentdefinitions.openagentix.io modelconfigs.api.kagent.dev harnesses.api.kagent.dev agenttemplates.api.kagent.dev egresspolicies.api.kagent.dev agents.api.kagent.dev; do
  # (kubectl wait fails while status.conditions does not exist yet, so the condition is polled)
  for _ in $(seq 1 90); do
    [ "$(kubectl get crd "$c" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" = True ] && break
    sleep 1
  done
done
jq -c 'select(.kind|IN("ServiceAccount","Role","RoleBinding","ResourceQuota","ConfigMap"))
       | select(.metadata.name|test("^(openagentix-control-plane|openagentix-agent-builder|openagentix-agent-viewer|openagentix-agentdefinitions|llm-api-keys-control-plane)$"))' "$TMP/render.jsonl" \
  | kubectl apply --server-side --validate=strict -f - >/dev/null
allowed "the AgentDefinition CRD is accepted (metadata schema is {type: object})" kubectl get crd agentdefinitions.openagentix.io
jq -c 'select(.kind=="ValidatingAdmissionPolicy" or .kind=="ValidatingAdmissionPolicyBinding")' "$TMP/render.jsonl" > "$TMP/policies.jsonl"
NPOL=$(jq -s '[.[]|select(.kind=="ValidatingAdmissionPolicy")]|length' "$TMP/policies.jsonl")
allowed "the $NPOL policies and their bindings are accepted with server-side validation" bash -c "kubectl apply --server-side --validate=strict -f - < '$TMP/policies.jsonl'"
[ "$NPOL" = 8 ] && ok "eight policies" || bad "eight policies" "got $NPOL"
allowed "the ResourceQuota counts AgentDefinitions" kubectl -n kagent get resourcequota openagentix-agentdefinitions

echo "# status.typeChecking of every policy"
for p in $(kubectl get validatingadmissionpolicy -o name | grep control-plane-guard); do
  j=""
  for _ in $(seq 1 90); do
    j=$(kubectl get "$p" -o json)
    jq -e '(.status.observedGeneration // 0) >= .metadata.generation' >/dev/null <<<"$j" && break
    sleep 1
  done
  if jq -e '(.status.observedGeneration // 0) >= .metadata.generation' >/dev/null <<<"$j"; then
    w=$(jq -c '[.status.typeChecking.expressionWarnings[]?|{fieldRef,warning}]' <<<"$j")
    [ "$w" = "[]" ] && ok "$p: no type-checking warning" || bad "$p: type-checking warnings" "$w"
  else
    bad "$p: the API server did not report typeChecking in 90 s" ""
  fi
done

# ---- the definition ----
echo "# the example definition and the invalid ones"
# the quota controller needs a while to learn the new resource: until then every create is refused with "status unknown for quota" (up to 4 minutes)
for _ in $(seq 1 120); do
  kubectl -n kagent get resourcequota openagentix-agentdefinitions -o jsonpath='{.status.used}' 2>/dev/null | grep -q 'count/agentdefinitions' && break
  sleep 2
done
apply_researcher() {
  local out
  for _ in $(seq 1 30); do
    out=$(kubectl apply --server-side -f components/control-plane/researcher.yaml 2>&1) && return 0
    printf '%s' "$out" | grep -q "status unknown for quota" || break
    sleep 4
  done
  printf '%s\n' "$out" >&2; return 1
}
allowed "components/control-plane/researcher.yaml is accepted" apply_researcher
DEF=$(yq -c . components/control-plane/researcher.yaml)
# variant <name> <jq filter>: the example definition under another name (so that nothing exists yet), changed by the filter, written to a file; prints the path
variant() { local f="$TMP/def-$1.json"; jq -c '.metadata.name="variant"' <<<"$DEF" | jq -c "$2" > "$f"; printf '%s' "$f"; }
dryapply() { kubectl create --dry-run=server -f "$1"; }
refused "old boolean shape: knowledge: true"      "spec.knowledge" dryapply "$(variant k '.spec.knowledge=true')"
refused "old boolean shape: notify: true"         "spec.notify" dryapply "$(variant n '.spec.notify=true')"
refused "old boolean shape: memory: true"         "spec.memory" dryapply "$(variant m '.spec.memory=true')"
refused "old shape: skills as a list of names"    "spec.skills" dryapply "$(variant s '.spec.skills=["openagentix-canary"]')"
refused "both instructions and instructionsFrom"  "set exactly one of instructions and instructionsFrom" dryapply "$(variant both '.spec.instructionsFrom={configMap:{name:"c",key:"k"}}')"
refused "neither instructions nor instructionsFrom" "set exactly one of instructions and instructionsFrom" dryapply "$(variant none 'del(.spec.instructions)')"
refused "a name that is longer than 40 characters" "name must be at most 40 characters" dryapply "$(variant long '.metadata.name=("a"*41)')"
refused "a name that starts with a digit"         "name must be a DNS label" dryapply "$(variant digit '.metadata.name="1agent"')"
refused "a description over 256 characters"       "spec.description" dryapply "$(variant desc '.spec.description=("d"*257)')"
refused "more than 64 egress origins"             "spec.egress.allow" dryapply "$(variant eg '.spec.egress.allow=[range(65)|"https://h\(.).example.org"]')"
refused "memory.ttlDays below 1"                  "spec.memory.ttlDays" dryapply "$(variant ttl '.spec.memory={enabled:true,ttlDays:0}')"
refused "a model name over 63 characters"         "spec.model" dryapply "$(variant model '.spec.model=("m"*64)')"
refused "a tool profile that is not a profile name" "spec.toolProfile" dryapply "$(variant prof '.spec.toolProfile="Bad Profile"')"
# the instruction limit is in BYTES: 8200 two-byte characters are under 16384 characters and over 16384 bytes
refused "instructions over 16384 BYTES (8200 two-byte characters)" "16384 bytes" dryapply "$(variant bytes '.spec.instructions=("\u00e9"*8200)')"
refused "instructions over 16384 characters" "spec.instructions" dryapply "$(variant chars '.spec.instructions=("x"*16385)')"
allowed "instructions of exactly 16384 bytes are accepted" dryapply "$(variant exact '.spec.instructions=("\u00e9"*8192)')"

# ---- the guard, as the controller ----
echo "# the output guard: writes as the controller's ServiceAccount (server-side dry run)"
UIDV=$(kubectl -n kagent get oad researcher -o jsonpath='{.metadata.uid}')
HEX8=$(printf '%s' "$UIDV" | tr -d - | cut -c1-8)
OWNER=$(jq -nc --arg u "$UIDV" '[{apiVersion:"openagentix.io/v1alpha1",kind:"AgentDefinition",name:"researcher",uid:$u,controller:true}]')
LABELS='{"app.kubernetes.io/managed-by":"openagentix-control-plane","openagentix.io/agent-definition":"researcher"}'
SERVER=$(jq_cat '.tools.toolhive.profiles[0].toolServer')
TOOL=$(jq_cat '.tools.toolhive.profiles[0].tools[0]')
mk() { # mk <kind> <name> <spec json> [annotations json]
  jq -nc --arg k "$1" --arg n "$2" --argjson spec "$3" --argjson ann "${4:-null}" --argjson l "$LABELS" --argjson o "$OWNER" \
    '{apiVersion:"api.kagent.dev/v1alpha3",kind:$k,metadata:({name:$n,namespace:"kagent",labels:$l,ownerReferences:$o}+(if $ann then {annotations:$ann} else {} end)),spec:$spec}'
}
MC_SPEC=$(jq -nc --arg m "$(jq_cat '.models[0]')" --arg u "$(jq_cat '.gatewayBaseUrl')" --arg s "researcher-virtual-key-$HEX8" \
  '{provider:"OpenAI",model:$m,apiKeySecret:$s,apiKeySecretKey:"OPENAI_API_KEY",stream:false,openAI:{baseUrl:$u}}')
HN_SPEC=$(jq -nc --arg i "$(jq_cat '.runtime.kagent.harnessImage')" --arg w "$(jq_cat '.runtime.kagent.workerPool')" --arg l "$(jq_cat '.runtime.kagent.snapshotLocation')" --argjson env "$(jq_cat '.runtime.kagent.harnessEnv')" \
  '{kagent:{},workload:{image:$i},substrate:{workerPoolRef:{name:$w},snapshotPolicy:{location:$l}}}+(if ($env|length)>0 then {env:$env} else {} end)')
TP_SPEC=$(jq -nc --arg s "$SERVER" --arg t "$TOOL" '{description:"d",systemPrompt:"p",modelConfig:{name:"gateway-researcher"},tools:[{mcp:{server:{kind:"RemoteMCPServer",name:$s},tools:[$t]}}]}')
EG_SPEC='{"destinations":[{"origin":"https://api.osv.dev"}]}'
AG_SPEC='{"template":{"ref":{"name":"researcher-template"}},"harnessRef":{"name":"researcher-harness"},"egressPolicyRefs":[{"name":"researcher-egress"}]}'
FP='{"openagentix.io/key-fingerprint":"0123456789abcdef"}'
mk ModelConfig gateway-researcher "$MC_SPEC" '{"openagentix.io/agent":"researcher"}' > "$TMP/modelconfig.json"
mk Harness researcher-harness "$HN_SPEC" "$FP" > "$TMP/harness.json"
mk AgentTemplate researcher-template "$TP_SPEC" > "$TMP/agenttemplate.json"
mk EgressPolicy researcher-egress "$EG_SPEC" > "$TMP/egresspolicy.json"
mk Agent researcher "$AG_SPEC" "$FP" > "$TMP/agent.json"
asctl() { kubectl "${AS[@]}" "$@"; }

# the guard needs a moment to be active after the bindings are created: wait until a known refusal is a refusal
jq -c '.spec.destinations[0].authentication={header:"Authorization",secretKeyRef:{name:"kagent-postgresql",key:"password"}}' "$TMP/egresspolicy.json" > "$TMP/eg-auth.json"
for _ in $(seq 1 60); do
  if asctl create --dry-run=server -f "$TMP/eg-auth.json" 2>&1 | grep -q "may only have destinations"; then break; fi
  sleep 1
done

for f in modelconfig harness agenttemplate egresspolicy agent; do
  allowed "the controller may create what it writes: $f" asctl create --dry-run=server -f "$TMP/$f.json"
done

# C1 and the fields of the review, one per kind (CREATE: nothing exists yet; the shapes are valid for kagent's own schema, so that the refusal is the guard's)
refused "C1: an EgressPolicy with authentication.secretKeyRef is refused" "may only have destinations" asctl create --dry-run=server -f "$TMP/eg-auth.json"
jq -c '.spec.destinations[0].origin="https://docs.kagent.dev"' "$TMP/egresspolicy.json" > "$TMP/eg-docs.json"
allowed "M5: https://docs.kagent.dev is a public name and is allowed" asctl create --dry-run=server -f "$TMP/eg-docs.json"
jq -c '.spec.destinations[0].origin="https://metadata.google.internal"' "$TMP/egresspolicy.json" > "$TMP/eg-int.json"
refused "M5: a name that only looks public (.internal) is refused" "may not name a host inside the cluster" asctl create --dry-run=server -f "$TMP/eg-int.json"
jq -c '.spec.destinations[0].origin="https://kubernetes.default.svc"' "$TMP/egresspolicy.json" > "$TMP/eg-k8s.json"
refused "M5: the Kubernetes API service is refused" "may not name a host inside the cluster" asctl create --dry-run=server -f "$TMP/eg-k8s.json"
jq -c '.spec.destinations[0].origin="https://registry.ci.svc:5000"' "$TMP/egresspolicy.json" > "$TMP/eg-listed.json"
allowed "an in-cluster destination the operator listed is allowed" asctl create --dry-run=server -f "$TMP/eg-listed.json"
jq -c '.spec.workload.command=["/bin/sh","-c","id"]' "$TMP/harness.json" > "$TMP/h-cmd.json"
refused "I1: a Harness command is refused" "may only have the keys" asctl create --dry-run=server -f "$TMP/h-cmd.json"
jq -c '.spec.kagent.compaction={tokenThreshold:100,eventRetentionSize:10,summarizer:{modelConfigRef:{name:"default-model-config",namespace:"kagent"}}}' "$TMP/harness.json" > "$TMP/h-comp.json"
refused "I1: a Harness compaction summarizer is refused" "may only have the keys" asctl create --dry-run=server -f "$TMP/h-comp.json"
jq -c '.spec.defaultHeaders={"x-leak":"y"}' "$TMP/modelconfig.json" > "$TMP/m-hdr.json"
refused "I1: a ModelConfig defaultHeaders is refused" "may only have the keys" asctl create --dry-run=server -f "$TMP/m-hdr.json"
jq -c '.spec.model="gpt-4o-not-in-the-catalog"' "$TMP/modelconfig.json" > "$TMP/m-model.json"
refused "I1: a model that is not in the catalog is refused" "model of the platform catalog" asctl create --dry-run=server -f "$TMP/m-model.json"
jq -c 'del(.spec.systemPrompt)|.spec.systemPromptFrom={name:"kagent-postgresql",key:"password"}' "$TMP/agenttemplate.json" > "$TMP/t-from.json"
refused "I1: an AgentTemplate systemPromptFrom is refused" "may only have the keys" asctl create --dry-run=server -f "$TMP/t-from.json"
jq -c '.spec.tools[0].mcp.tools=["k8s_delete_resource"]' "$TMP/agenttemplate.json" > "$TMP/t-tool.json"
refused "I1: a tool the profile does not offer is refused" "subset of that profile" asctl create --dry-run=server -f "$TMP/t-tool.json"
jq -c '.spec.template={inline:{systemPrompt:"x"}}' "$TMP/agent.json" > "$TMP/a-inline.json"
refused "I1: an Agent with an inline template is refused" "may only have template.ref.name" asctl create --dry-run=server -f "$TMP/a-inline.json"

# real objects now, created by the administrator, so that the UPDATE and DELETE paths have an existing object
for f in modelconfig harness agenttemplate egresspolicy agent; do kubectl create -f "$TMP/$f.json" >/dev/null; done
SSA=(apply --server-side --force-conflicts --field-manager=openagentix-control-plane --dry-run=server)
for f in modelconfig harness agenttemplate egresspolicy agent; do
  allowed "the controller may server-side apply its own $f (an UPDATE)" asctl "${SSA[@]}" -f "$TMP/$f.json"
done
refused "C1: ...also as an UPDATE of the existing EgressPolicy" "may only have destinations" asctl "${SSA[@]}" -f "$TMP/eg-auth.json"
jq -c '.spec.workload.command=["/bin/sh"]' "$TMP/harness.json" > "$TMP/h-cmd2.json"
refused "I1: ...a Harness command added by an UPDATE" "may only have the keys" asctl "${SSA[@]}" -f "$TMP/h-cmd2.json"
allowed "M5: an UPDATE to a public name is allowed" asctl "${SSA[@]}" -f "$TMP/eg-docs.json"
allowed "the controller may delete an object it owns" asctl delete --dry-run=server -n kagent egresspolicy researcher-egress

# Secrets
SECRET=$(jq -nc --arg n "researcher-virtual-key-$HEX8" --argjson l "$LABELS" --argjson o "$OWNER" '{apiVersion:"v1",kind:"Secret",type:"Opaque",immutable:true,metadata:{name:$n,namespace:"kagent",labels:$l,ownerReferences:$o},data:{OPENAI_API_KEY:"dmstMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDA="}}')
printf '%s' "$SECRET" > "$TMP/secret.json"
allowed "the controller may create its key Secret" asctl create --dry-run=server -f "$TMP/secret.json"
jq -c '.data.extra="eA=="' "$TMP/secret.json" > "$TMP/s-extra.json"
refused "a Secret with a second data key is refused" "single key OPENAI_API_KEY" asctl create --dry-run=server -f "$TMP/s-extra.json"
jq -c '.metadata.name="kagent-postgresql"' "$TMP/secret.json" > "$TMP/s-name.json"
refused "a Secret that is not a key Secret is refused" "must be <name>-virtual-key-" asctl create --dry-run=server -f "$TMP/s-name.json"
kubectl create -f "$TMP/secret.json" >/dev/null
kubectl -n kagent create secret generic kagent-postgresql --from-literal=password=x >/dev/null
allowed "the controller may delete its own key Secret" asctl delete --dry-run=server -n kagent secret "researcher-virtual-key-$HEX8"
refused "the controller may not delete another Secret of the namespace" "may only delete Secrets named" asctl delete --dry-run=server -n kagent secret kagent-postgresql

# the key ConfigMap
HASH="sha256:$(printf '0123456789abcdef%.0s' 1 2 3 4)"
GOOD=$(jq -nc --arg h "$HASH" '{"kagent.researcher": ({keyHash:$h,metadata:{user_id:"kagent.researcher"}}|tojson)}|{data:.}')
allowed "the controller may register its entry (kagent.researcher)" asctl -n agentgateway-system patch configmap llm-api-keys-control-plane --type merge --dry-run=server -p "$GOOD"
FOREIGN=$(jq -nc --arg h "$HASH" '{"admin": ({keyHash:$h,metadata:{user_id:"admin"}}|tojson)}|{data:.}')
refused "an entry for another user id is refused" "must be named kagent." asctl -n agentgateway-system patch configmap llm-api-keys-control-plane --type merge --dry-run=server -p "$FOREIGN"
MISMATCH=$(jq -nc --arg h "$HASH" '{"kagent.researcher": ({keyHash:$h,metadata:{user_id:"kagent.admin"}}|tojson)}|{data:.}')
refused "an entry whose user_id differs from its key is refused" "must be named kagent." asctl -n agentgateway-system patch configmap llm-api-keys-control-plane --type merge --dry-run=server -p "$MISMATCH"
refused "the key ConfigMap's labels may not change" "may only change the data" asctl -n agentgateway-system patch configmap llm-api-keys-control-plane --type merge --dry-run=server -p '{"metadata":{"labels":{"x":"y"}}}'

# ownership, and the last rule
kubectl -n kagent create -f - >/dev/null <<'YAML'
apiVersion: api.kagent.dev/v1alpha3
kind: EgressPolicy
metadata: {name: foreign-egress, namespace: kagent}
spec: {destinations: [{origin: "https://api.osv.dev"}]}
YAML
jq -c '.metadata.name="foreign-egress"' "$TMP/egresspolicy.json" > "$TMP/eg-foreign.json"
refused "an object the controller does not own cannot be taken over" "may only write kagent objects that it owns" asctl apply --server-side --force-conflicts --field-manager=openagentix-control-plane --dry-run=server -f "$TMP/eg-foreign.json"
refused "an object the controller does not own cannot be deleted" "may only write kagent objects that it owns" asctl delete --dry-run=server -n kagent egresspolicy foreign-egress
kubectl -n kagent create role cp-test-extra --verb=create,delete --resource=serviceaccounts,pods >/dev/null
kubectl -n kagent create rolebinding cp-test-extra --role=cp-test-extra --serviceaccount=openagentix-system:openagentix-control-plane >/dev/null
for _ in $(seq 1 30); do asctl auth can-i create serviceaccounts -n kagent 2>/dev/null | grep -q yes && break; sleep 1; done
refused "the last rule: any other resource is refused (a ServiceAccount, with RBAC widened)" "may only write Secrets" asctl create --dry-run=server -n kagent serviceaccount x
refused "the last rule: ...and a Pod" "may only write Secrets" asctl run --dry-run=server -n kagent --image=busybox x
# the controller patches the status with a bare PATCH (no GET), so this one is a PATCH with the ServiceAccount's own token
TOKEN=$(kubectl -n openagentix-system create token openagentix-control-plane)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
code=$(curl -sk -o "$TMP/status.out" -w '%{http_code}' -X PATCH -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/merge-patch+json' \
  --data '{"status":{"revision":"abc"}}' "$APISERVER/apis/openagentix.io/v1alpha1/namespaces/kagent/agentdefinitions/researcher/status?dryRun=All")
[ "$code" = 200 ] && ok "the controller may patch the status of its definition" || bad "the controller may patch the status of its definition" "HTTP $code: $(head -c 300 "$TMP/status.out")"
kubectl -n kagent get oad researcher -o json | jq -c '.metadata.finalizers=["openagentix.io/gateway-key"]' > "$TMP/def-finalizer.json"
allowed "...and update the definition (the finalizer: a full PUT)" asctl -n kagent replace --dry-run=server -f "$TMP/def-finalizer.json"
allowed "a user other than the controller is not restricted by the guard (admin writes a ConfigMap)" kubectl -n kagent create configmap free --from-literal=a=b

# ---- the container runtime (bring your own agent, ADR 0015): the workload namespace, its Role and its guard ----
echo "# the container runtime: Pod Security, RBAC and the workload guard (server-side dry run as the controller)"
CARGS=("${ARGS[@]}" --set controlPlane.containerAgents.enabled=true --set 'controlPlane.policy.allowedRuntimes={builtin,container}' --set 'controlPlane.policy.runtimes.container.images={registry.local/oa/}')
helm "${CARGS[@]}" | yq -c 'select(.!=null)' > "$TMP/render-ca.jsonl"
WNS=openagentix-workloads
GNS=openagentix-gateway
kubectl create namespace "$GNS" >/dev/null
jq -c 'select(.kind=="Namespace" and .metadata.name=="'$WNS'")' "$TMP/render-ca.jsonl" | kubectl apply --server-side -f - >/dev/null
jq -c 'select((.kind|IN("Role","RoleBinding","NetworkPolicy")) and (.metadata.namespace=="'$WNS'"))' "$TMP/render-ca.jsonl" | kubectl apply --server-side --validate=strict -f - >/dev/null
jq -c 'select(.kind=="ConfigMap" and .metadata.name=="a2a-gate-routes")' "$TMP/render-ca.jsonl" | kubectl apply --server-side --validate=strict -f - >/dev/null
jq -c 'select((.kind|IN("Role","RoleBinding")) and (.metadata.name=="openagentix-control-plane-routes"))' "$TMP/render-ca.jsonl" | kubectl apply --server-side --validate=strict -f - >/dev/null
jq -c 'select(.kind=="ValidatingAdmissionPolicy" or .kind=="ValidatingAdmissionPolicyBinding")' "$TMP/render-ca.jsonl" > "$TMP/policies-ca.jsonl"
NPOL=$(jq -s '[.[]|select(.kind=="ValidatingAdmissionPolicy")]|length' "$TMP/policies-ca.jsonl")
allowed "the $NPOL policies (the workload ones included) are accepted with server-side validation" bash -c "kubectl apply --server-side --force-conflicts --validate=strict -f - < '$TMP/policies-ca.jsonl'"
[ "$NPOL" = 14 ] && ok "fourteen policies with the container runtime on" || bad "fourteen policies with the container runtime on" "got $NPOL"
for p in $(kubectl get validatingadmissionpolicy -o name | grep control-plane-guard-workload); do
  j=""
  for _ in $(seq 1 90); do
    j=$(kubectl get "$p" -o json)
    jq -e '(.status.observedGeneration // 0) >= .metadata.generation' >/dev/null <<<"$j" && break
    sleep 1
  done
  w=$(jq -c '[.status.typeChecking.expressionWarnings[]?|{fieldRef,warning}]' <<<"$j")
  [ "$w" = "[]" ] && ok "$p: no type-checking warning" || bad "$p: type-checking warnings" "$w"
done
[ "$(kubectl get namespace "$WNS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted ] && ok "the workload namespace enforces Pod Security restricted" || bad "the workload namespace enforces Pod Security restricted" ""
for _ in $(seq 1 30); do asctl auth can-i create deployments.apps -n "$WNS" 2>/dev/null | grep -q yes && break; sleep 1; done
[ "$(asctl auth can-i get secrets -n "$WNS" 2>&1)" = no ] && ok "RBAC: the controller cannot get Secrets in the workload namespace" || bad "RBAC: the controller cannot get Secrets in the workload namespace" ""
[ "$(asctl auth can-i list secrets -n "$WNS" 2>&1)" = no ] && ok "RBAC: ...nor list them" || bad "RBAC: ...nor list them" ""
[ "$(asctl auth can-i create pods -n "$WNS" 2>&1)" = no ] && ok "RBAC: ...nor create Pods" || bad "RBAC: ...nor create Pods" ""
IMG="registry.local/oa/echo@sha256:$(printf 'a%.0s' $(seq 1 64))"
SUB='s#ghcr.io/acme/agents/echo-go@sha256:a*#'"$IMG"'#; s#openagentix-agents#'$WNS'#g; s#echo-go-virtual-key-0a1b2c3d#echo-go-virtual-key-'$HEX8'#; s#"app":"model-gateway"#"gateway.networking.k8s.io/gateway-name":"model-gateway"#'
jq -c '.items[]' services/control-plane/testdata/container-objects.json | sed -E "$SUB" > "$TMP/ca-objects.jsonl"
jq -c --argjson p "$(jq -r 'select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.runtime.container.gatewayPort' "$TMP/render-ca.jsonl")" 'if .kind=="NetworkPolicy" then .spec.egress[1].ports[0].port=$p else . end' "$TMP/ca-objects.jsonl" > "$TMP/ca-objects2.jsonl"
for k in ServiceAccount Deployment Service NetworkPolicy; do jq -c "select(.kind==\"$k\")" "$TMP/ca-objects2.jsonl" > "$TMP/ca-$k.json"; done
# The re-apply above UPDATES guard-other (with the container runtime on it stands aside for the workload kinds in the
# workload namespace). Admission does not use an updated policy at once: the API server recompiles its policies from an
# informer cache on a 1-second tick (k8s.io/apiserver policy/generic/policy_source.go, policyRefreshInterval), and
# status.observedGeneration does not tell when that happened. Writes in that window still meet the OLD guard-other
# ("the control plane may only write Secrets, ..."). So wait until probes show the new set is in force:
#  1. the controller's ServiceAccount is allowed: only the updated guard-other allows it (a refusal by any other policy
#     would not settle and is reported below). A bad Deployment is no probe for this step: the old guard-other and the
#     workload guard both refuse it, and which message the API server returns is not fixed.
#  2. then a Deployment with a hostPath volume is refused by the workload guard: guard-other now stands aside for it, so
#     this message proves the workload policy and its binding (applied after guard-other) are in force too.
jq -c '.spec.template.spec.volumes+=[{name:"h",hostPath:{path:"/"}}]' "$TMP/ca-Deployment.json" > "$TMP/ca-probe.json"
probe=""
for _ in $(seq 1 60); do
  if probe=$(asctl create --dry-run=server -f "$TMP/ca-ServiceAccount.json" 2>&1); then
    probe=$(asctl create --dry-run=server -f "$TMP/ca-probe.json" 2>&1 || true)
    grep -qF "the only volume is an emptyDir" <<<"$probe" && break
  fi
  probe="not settled: $probe"
  sleep 1
done
case "$probe" in
  "not settled: "*) bad "the updated policy set is in force (guard-other stands aside, the workload guard refuses)" "$(printf '%s' "$probe" | head -3 | cut -c1-300)" ;;
  *) ok "the updated policy set is in force (guard-other stands aside, the workload guard refuses)" ;;
esac
for k in ServiceAccount Deployment Service NetworkPolicy; do
  allowed "the controller may create its $k in the workload namespace" asctl create --dry-run=server -f "$TMP/ca-$k.json"
done
# The API server validates the object before admission runs, so each bad Deployment must be valid
# to it (a privileged container needs allowPrivilegeEscalation, a second container needs its own
# name); otherwise the refusal comes from validation and not from the guard under test.
dep_refused() { # dep_refused <desc> <pattern> <jq filter on the Deployment>
  jq -c "$3" "$TMP/ca-Deployment.json" > "$TMP/ca-dep-bad.json"
  refused "$1" "$2" asctl create --dry-run=server -f "$TMP/ca-dep-bad.json"
}
dep_refused "a Deployment with hostNetwork is refused" "must use only its own ServiceAccount" '.spec.template.spec.hostNetwork=true'
dep_refused "a Deployment with a privileged container is refused" "no privilege escalation" '.spec.template.spec.containers[0].securityContext|=(.privileged=true|.allowPrivilegeEscalation=true)'
dep_refused "a Deployment with another ServiceAccount is refused" "must use only its own ServiceAccount" '.spec.template.spec.serviceAccountName="default"'
dep_refused "a Deployment with a hostPath volume is refused" "the only volume is an emptyDir" '.spec.template.spec.volumes+=[{name:"h",hostPath:{path:"/"}}]'
dep_refused "a Deployment with an image by tag is refused" "digest-pinned image" '.spec.template.spec.containers[0].image="registry.local/oa/echo:v1"'
dep_refused "a Deployment with an image of another registry is refused" "digest-pinned image" '.spec.template.spec.containers[0].image="docker.io/evil/x@sha256:'$(printf 'a%.0s' $(seq 1 64))'"'
dep_refused "a Deployment with an extra container is refused" "digest-pinned image" '.spec.template.spec.containers+=[.spec.template.spec.containers[0]|.name="second"]'
SECRET_CA=$(jq -nc --arg n "echo-go-virtual-key-$HEX8" '{apiVersion:"v1",kind:"Secret",type:"Opaque",immutable:true,metadata:{name:$n,namespace:"'$WNS'",labels:{"app.kubernetes.io/managed-by":"openagentix-control-plane","openagentix.io/agent-definition":"echo-go","openagentix.io/definition-namespace":"kagent"}},data:{OPENAI_API_KEY:"dmstMDAwMDAw"}}')
printf '%s' "$SECRET_CA" > "$TMP/ca-secret.json"
allowed "the controller may create the key Secret in the workload namespace" asctl create --dry-run=server -f "$TMP/ca-secret.json"
jq -c '.metadata.ownerReferences=[{apiVersion:"openagentix.io/v1alpha1",kind:"AgentDefinition",name:"echo-go",uid:"x",controller:true}]' "$TMP/ca-secret.json" > "$TMP/ca-secret-own.json"
refused "a key Secret with an owner reference in the workload namespace is refused" "no owner reference" asctl create --dry-run=server -f "$TMP/ca-secret-own.json"
allowed "the controller may patch the route list" asctl -n "$GNS" patch configmap a2a-gate-routes --type merge --dry-run=server -p '{"data":{"routes.json":"{\"container\":[\"kagent/echo-go\"]}"}}'
refused "the route list may not hold a URL" "namespace/name entries" asctl -n "$GNS" patch configmap a2a-gate-routes --type merge --dry-run=server -p '{"data":{"routes.json":"{\"container\":[\"http://evil.example\"]}"}}'

# ---- tools for container agents (ADR 0019): the profile lookup opened; the guard then admits the token, the label, the env and the third rule ----
echo "# tools for container agents: the workload guard with an opened profile (server-side dry run as the controller)"
helm "${CARGS[@]}" --set 'controlPlane.containerAgents.toolProfiles={lookup}' | yq -c 'select(.!=null)' > "$TMP/render-tp.jsonl"
jq -c 'select((.kind=="ValidatingAdmissionPolicy" or .kind=="ValidatingAdmissionPolicyBinding") and (.metadata.name|startswith("openagentix-control-plane-guard-workload")))' "$TMP/render-tp.jsonl" > "$TMP/policies-tp.jsonl"
allowed "the workload policies with an opened profile are accepted with server-side validation" bash -c "kubectl apply --server-side --force-conflicts --validate=strict -f - < '$TMP/policies-tp.jsonl'"
for p in openagentix-control-plane-guard-workload-deployments openagentix-control-plane-guard-workload-networkpolicies; do
  j=""
  for _ in $(seq 1 90); do
    j=$(kubectl get validatingadmissionpolicy "$p" -o json)
    jq -e '(.status.observedGeneration // 0) >= .metadata.generation' >/dev/null <<<"$j" && break
    sleep 1
  done
  w=$(jq -c '[.status.typeChecking.expressionWarnings[]?|{fieldRef,warning}]' <<<"$j")
  [ "$w" = "[]" ] && ok "$p (opened profile): no type-checking warning" || bad "$p (opened profile): type-checking warnings" "$w"
done
jq -c '.items[]' services/control-plane/testdata/container-objects-tools.json | sed -E "$SUB" |
  jq -c --argjson p "$(jq -r 'select(.kind=="ConfigMap" and .metadata.name=="openagentix-control-plane-catalog")|.data["catalog.json"]|fromjson|.runtime.container.gatewayPort' "$TMP/render-tp.jsonl")" 'if .kind=="NetworkPolicy" then .spec.egress[1].ports[0].port=$p else . end' > "$TMP/tp-objects.jsonl"
for k in Deployment NetworkPolicy; do jq -c "select(.kind==\"$k\")" "$TMP/tp-objects.jsonl" > "$TMP/tp-$k.json"; done
# the updated policies reach admission within a few seconds (see above): wait until the Deployment with a profile is admitted
probe=""
for _ in $(seq 1 60); do
  probe=$(asctl create --dry-run=server -f "$TMP/tp-Deployment.json" 2>&1) && { probe=""; break; }
  sleep 1
done
[ -z "$probe" ] && ok "the controller may create a Deployment with a tool profile (token, label, env) once the profile is opened" || bad "the controller may create a Deployment with a tool profile once the profile is opened" "$(printf '%s' "$probe" | head -3 | cut -c1-300)"
allowed "the controller may create the NetworkPolicy with the third egress rule" asctl create --dry-run=server -f "$TMP/tp-NetworkPolicy.json"
allowed "an agent without a profile is still admitted" asctl create --dry-run=server -f "$TMP/ca-Deployment.json"
tp_refused() { # tp_refused <desc> <pattern> <jq filter on the Deployment>
  jq -c "$3" "$TMP/tp-Deployment.json" > "$TMP/tp-dep-bad.json"
  refused "$1" "$2" asctl create --dry-run=server -f "$TMP/tp-dep-bad.json"
}
tp_refused "a token for another audience is refused" "one projected token of that profile" '.spec.template.spec.volumes[1].projected.sources[0].serviceAccountToken.audience="openagentix-a2a"'
tp_refused "a token that lives a day is refused" "one projected token of that profile" '.spec.template.spec.volumes[1].projected.sources[0].serviceAccountToken.expirationSeconds=86400'
tp_refused "a projected Secret next to the token is refused" "one projected token of that profile" '.spec.template.spec.volumes[1].projected.sources+=[{secret:{name:"kagent-db-credentials"}}]'
tp_refused "a writable token mount is refused" "one projected token of that profile" '.spec.template.spec.containers[0].volumeMounts[1].readOnly=false'
tp_refused "a profile label that is not opened is refused" "selects only this agent's pod label" '.spec.template.metadata.labels["openagentix.io/tool-profile"]="other"'
tp_refused "another tool URL is refused" "the tool URL and token file of the labelled profile" '(.spec.template.spec.containers[0].env[]|select(.name=="OPENAGENTIX_MCP_URL")|.value)="http://vmcp-tools.mcp-tools.svc.cluster.local:4483/mcp"'
jq -c '.spec.egress[2].to[0].podSelector.matchLabels["toolhive-name"]="tools-lookup"' "$TMP/tp-NetworkPolicy.json" > "$TMP/tp-np-bad.json"
refused "egress to the profile's server for Substrate agents is refused" "the workload tool server of one opened profile" asctl create --dry-run=server -f "$TMP/tp-np-bad.json"

echo
echo "apiserver-test: passed=$PASS failed=$FAIL"
[ "$FAIL" = 0 ]
