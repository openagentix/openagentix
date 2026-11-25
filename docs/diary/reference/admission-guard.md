---
title: Admission guard
sidebar_position: 5
description: Reference for the admission guard in front of the control plane controller - the eight policies, what the controller may write, how to read a denial and how to check the policies.
---

# Admission guard reference

The guard limits what the controller can write, even if the controller is compromised or has a bug. It is a set of Kubernetes `ValidatingAdmissionPolicy` objects (CEL rules) with one `ValidatingAdmissionPolicyBinding` each. The policies apply to the controller's own ServiceAccount only. No other user is affected.

Status: **available but off by default**. The chart renders the guard when `controlPlane.enabled: true`. It needs a cluster with `ValidatingAdmissionPolicy` (Kubernetes 1.30 and later).

The source is `charts/openagentix/templates/control-plane-guard.yaml`.

## How it works

- Every policy has `failurePolicy: Fail` and the binding action `Deny`. If a rule cannot be evaluated, the write is refused. It is never allowed.
- Every policy has one match condition: the request must come from `system:serviceaccount:NAMESPACE:openagentix-control-plane`.
- For the five kagent kinds, the guard is an **allowlist of keys at every level**. A key that the controller's kagent adapter does not write is refused, whatever its value. This keeps out fields nobody thought of: a Harness command, a ModelConfig header, an EgressPolicy `authentication.secretKeyRef`, an AgentTemplate plugin.
- On top of the keys, the values that matter are pinned to the [platform catalog](./platform-catalog.md): the model, the tool servers and each server's tools, the skills, the harness image, worker pool and snapshot location, the gateway URL, the key Secret and the names derived from the definition's name.
- The controller's Roles say the same thing with RBAC. The guard holds even if a Role is widened by mistake.

## The eight policies

Each policy has the name `openagentix-control-plane-guard-NAME` and a binding with the same name.

| Policy name | Resource | Verbs it judges | What the controller may write |
|---|---|---|---|
| `guard-secrets` | `secrets` | create, update, delete | **Create and delete only**, in the agents namespace. A created Secret must be named `AGENT-virtual-key-` plus 8 hex characters, carry exactly the two labels `app.kubernetes.io/managed-by` and `openagentix.io/agent-definition` (equal to the name's prefix), have one owner reference (kind `AgentDefinition`, `controller: true`, the same name), be `immutable: true`, type `Opaque`, with the single data key `OPENAI_API_KEY` of at most 64 bytes. The only annotation allowed is `openagentix.io/key-fingerprint`. A delete is allowed only for an existing Secret of that name pattern with both labels. An update is always refused. |
| `guard-configmaps` | `configmaps` | create, update, delete | **Update only**, of the one ConfigMap `llm-api-keys-control-plane` in the gateway namespace. Only `data` may change: not labels, annotations, owner references, finalizers, binary data or the immutable flag. A new or changed entry must be named `AGENTS_NAMESPACE.NAME` and hold exactly `{"keyHash":"sha256:HEX64","metadata":{"user_id":"AGENTS_NAMESPACE.NAME"[,"team":..][,"project":..]}}`. An unchanged old entry is kept as it is. |
| `guard-modelconfigs` | `modelconfigs` (kagent) | create, update, delete | `gateway-AGENT`. Spec keys only: `provider` (must be `OpenAI`), `model` (a catalog model), `apiKeySecret` (the agent's own key Secret), `apiKeySecretKey` (`OPENAI_API_KEY`), `stream` (false), `openAI.baseUrl` (the catalog's gateway URL), `openAI.apiFormat` (`chatCompletions`). |
| `guard-harnesses` | `harnesses` (kagent) | create, update, delete | `AGENT-harness`. Spec keys only: `kagent.memory.modelConfigRef.name`, `.namespace`, `kagent.memory.ttlDays`, `workload.image`, `substrate.workerPoolRef.name`, `substrate.snapshotPolicy.location`, `env[].name`, `env[].value`. Image, pool and location must equal the catalog. Memory only when the policy allows it, on the catalog's memory model config, with `ttlDays` from 1 to `memory.maxTtlDays`. `env` entries must be exactly the catalog's `harnessEnv`. |
| `guard-agenttemplates` | `agenttemplates` (kagent) | create, update, delete | `AGENT-template`. Spec keys only: `description`, `systemPrompt`, `modelConfig.name` (`gateway-AGENT`), `tools[].mcp.server.kind` (`RemoteMCPServer`), `tools[].mcp.server.name`, `tools[].mcp.tools`, `skills[].name`, `skills[].source.oci`. Every tool entry must use a profile's tool server and a subset of that server's tools. Skills must be the catalog's digest-pinned references. |
| `guard-egresspolicies` | `egresspolicies` (kagent) | create, update, delete | `AGENT-egress`. Spec key `destinations[].origin` only: no authentication, no header. Each origin must have the shape of an allowed origin and must not name a host inside the cluster, except exact `host:port` entries of `egress.inClusterDestinations`. Never allowed: a name inside the tools, agents or gateway namespace, `kube-system`, or the Kubernetes API service. |
| `guard-agents` | `agents` (kagent) | create, update, delete | `AGENT`. Spec keys only: `template.ref.name` (`AGENT-template`), `harnessRef.name` (`AGENT-harness`), `egressPolicyRefs[].name` (at most one, `AGENT-egress`). |
| `guard-other` | every other resource and subresource | all | **Nothing.** Any other write by the controller's ServiceAccount is refused. The exceptions are the other seven policies' resources and the controller's own `agentdefinitions` and `agentdefinitions/status` (update). |

For the five kagent kinds, these checks also apply to every one:

- The object is in the agents namespace.
- It is owned: both labels (`app.kubernetes.io/managed-by: openagentix-control-plane`, `openagentix.io/agent-definition: AGENT`) and an owner reference of kind `AgentDefinition` with `controller: true` and the same name. An update or delete needs the existing object to be owned too, by the same definition. The controller cannot move or touch an object it does not own.
- `AGENT` is a DNS label of at most 40 characters.
- Metadata keys are limited to the standard ones; labels to the two control plane labels plus `openagentix.io/team` and `openagentix.io/project` (each at most 63 characters, valid label value); annotations to the one the adapter sets for that kind (`openagentix.io/agent` on a ModelConfig; `openagentix.io/key-fingerprint` on a Harness and an Agent; none on an AgentTemplate or EgressPolicy).
- Top-level keys are `apiVersion`, `kind`, `metadata`, `spec` and `status` only.

## How to read a denial

A refused write has the message of the failing rule. The API server adds the policy and binding names. The controller shows it in the `Applied` condition message (reason `ApplyFailed`, `PruneFailed` or `RemoveFailed`) and in its log.

A denial looks like this (the exact prefix is made by the API server and may differ between Kubernetes versions):

```text
ValidatingAdmissionPolicy 'openagentix-control-plane-guard-egresspolicies' with binding
'openagentix-control-plane-guard-egresspolicies' denied request: an EgressPolicy written by
the control plane may only have destinations[]{origin}: no authentication, no header, no other key
```

How to work with it:

1. Take the policy name from the text. The last part (`egresspolicies`) tells you the kind.
2. Find the row in the table above. The message sentence is in the template, so you can also search for it in `charts/openagentix/templates/control-plane-guard.yaml`.
3. Compare the object the controller tried to write with the rule. A refusal on a field means the controller (or a changed adapter) writes a key the guard does not know. A refusal on a value (model, image, URL) usually means the catalog and the objects disagree, for example after a partial upgrade.
4. List what is installed:

```sh
kubectl get validatingadmissionpolicy,validatingadmissionpolicybinding | grep openagentix-control-plane-guard
```

Every message is one sentence. They are listed in the template. The most common ones:

| Message starts with | Meaning |
|---|---|
| `the control plane may only create or delete Secrets, in the namespace ...` | An update of a Secret, or a Secret outside the agents namespace. |
| `a Secret created by the control plane must be <name>-virtual-key-<8 hex>, ...` | The key Secret does not have the exact shape. |
| `the control plane may only update the ConfigMap ...` | A write to any other ConfigMap. |
| `an entry of the key ConfigMap must be named ...` | A key entry for another user id or with another shape. |
| `the control plane may only write kagent objects that it owns ...` | A missing label or owner reference, or another namespace. |
| `the control plane may only write Secrets, its key ConfigMap, the kagent kinds it owns ...` | `guard-other`: a kind the controller never writes. |

## How to check `status.typeChecking`

The API server checks the CEL of a policy and reports problems in the policy's `status.typeChecking`. An empty `typeChecking` means no problem was found. The guard reads the objects as `dyn` (untyped) on purpose, because its rules iterate over keys. This is a status field of the Kubernetes API, so see the Kubernetes documentation for its exact form.

```sh
# one policy
kubectl get validatingadmissionpolicy openagentix-control-plane-guard-agents \
  -o jsonpath='{.status.typeChecking}' | jq .

# all eight: print names that have a type checking warning
kubectl get validatingadmissionpolicy -o json | jq -r \
  '.items[] | select(.metadata.name | startswith("openagentix-control-plane-guard-"))
   | "\(.metadata.name)\t\(.status.typeChecking.expressionWarnings // [] | length) warnings"'
```

If a policy has an expression **error** (not a warning), the policy cannot be evaluated and, with `failurePolicy: Fail`, every write of the controller to that kind is refused. The controller then reports `ApplyFailed`. Fix the chart, or the Kubernetes version if it is too old.

## How the guard is tested

| Test | What it does | Run with |
|---|---|---|
| `hack/ci/guardtest` | Renders the guard with Helm and runs its CEL with the Kubernetes admission code, against a table of allowed and refused requests. Offline. | `make test-guard` |
| `hack/ci/apiserver-test.sh` | Runs the CRD and the guard against a real API server in a throwaway kind cluster, with writes made as the controller's ServiceAccount. | `make test-apiserver` |
