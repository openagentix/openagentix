---
title: AgentDefinition
sidebar_position: 2
description: Reference for the AgentDefinition resource (openagentix.io/v1alpha1) - every spec and status field, every condition reason, the objects the controller makes, the life cycle and the roles.
---

# AgentDefinition reference

`AgentDefinition` describes one agent in a few lines. The control plane controller reads it, checks it against the [platform catalog](./platform-catalog.md) and the [platform policy](./platform-policy.md), and builds the agent.

Status of this API: **available but off by default**. It needs the chart value `controlPlane.enabled: true`. The version is `v1alpha1`, so fields may change. Read the [API conventions](./api-conventions.md).

Parts of this page are generated from the code. They sit between `generated:begin` and `generated:end` comments in the source file. Do not edit them by hand: run `hack/docs/gen-reference.sh`. A test fails when a page and the code differ.

## The resource

<!-- generated:begin ad-names -->
| Item | Value |
|---|---|
| group | `openagentix.io` |
| version | `v1alpha1` (served: true, storage: true) |
| kind | `AgentDefinition` |
| plural | `agentdefinitions` |
| short names | `oad` |
| scope | Namespaced |
| subresources | `status` |
<!-- generated:end ad-names -->

You can write the full name `agentdefinitions.openagentix.io` or the short name `oad`. The definitions live in the agents namespace of the platform. In the default install that namespace is `kagent`.

## Examples

A minimal definition. It works with the policy of the quick start (one model, one profile, one tool):

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata:
  name: hello
  namespace: kagent
spec:
  model: quickstart-model
  instructions: You answer in one short sentence.
  toolProfile: lookup
```

A full definition. Every field that is available is set. It is accepted only if the platform policy allows each part (see [what the policy decides](#what-the-platform-decides)):

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata:
  name: release-helper
  namespace: kagent
  labels:
    openagentix.io/team: platform
    openagentix.io/project: releases
spec:
  description: Checks a package for known vulnerabilities and tells the team
  model: claude-haiku
  instructions: |
    You check software packages for known vulnerabilities with your tools.
    Say which tool you used. If a tool returns nothing, say so.
  toolProfile: lookup
  tools: [osv_query_vulnerability]
  knowledge:
    enabled: false
  notify:
    enabled: false
  memory:
    enabled: true
    ttlDays: 14
  skills:
    - name: openagentix-canary
  egress:
    allow:
      - https://api.osv.dev
      - https://*.example.org
  suspend: false
```

The same object with the `kubectl` commands that go with it is in `components/control-plane/researcher.yaml` and `components/quickstart/agent.yaml`.

## `spec`

A definition says only what the agent should do. There is no field for a model config, an image, a tool server, a namespace, a caller, a gateway user or a budget. Those come from the platform, so a definition cannot go around the policy.

Exactly one of `instructions` and `instructionsFrom` must be set. `instructionsFrom` is **reserved (designed, not built)**: this release refuses it.

The table is generated from the CRD. "Limits and checks" shows the schema limits. A schema rule that fails is refused by the API server at `kubectl apply` time, with the sentence shown. The controller checks all limits again and is the authority.

<!-- generated:begin ad-spec-fields -->
| Path | Type | Required | Limits and checks | Meaning |
|---|---|---|---|---|
| `spec.description` | string | no | max length 256 | One line about what the agent does. Not part of the revision. |
| `spec.model` | string | yes | min length 1; max length 63 | A gateway model the platform policy allows. |
| `spec.instructions` | string | no | min length 1; max length 16384; rule refuses with: "instructions must be at most 16384 bytes (UTF-8)" | The system prompt, at most 16384 bytes. Exactly one of instructions and instructionsFrom is set. It must not contain anything shaped like a secret. |
| `spec.instructionsFrom` | object | no |  | Reserved. A reference to the prompt in a ConfigMap of the same namespace; this release refuses a definition that sets it ("not available yet"). |
| `spec.instructionsFrom.configMap` | object | yes |  |  |
| `spec.instructionsFrom.configMap.name` | string | yes | min length 1; max length 253 |  |
| `spec.instructionsFrom.configMap.key` | string | yes | min length 1; max length 253 |  |
| `spec.toolProfile` | string | no | max length 20; pattern `^[a-z][a-z0-9]*(-[a-z0-9]+)*$` | Required when tools are listed. Names a tool profile of the platform catalog. |
| `spec.tools` | array of string | no | max 64 items | Agent-side tool names; each must be offered by the tool profile. |
| `spec.knowledge` | object | no |  | The knowledge tools and prompt, when the platform has them and the policy allows it. |
| `spec.knowledge.enabled` | boolean | no |  |  |
| `spec.knowledge.collections` | array of string | no | max 16 items | Reserved. Selecting collections is not available yet; a definition that lists some is refused. |
| `spec.notify` | object | no |  | The notify tools and prompt, when the platform has them and the policy allows it. |
| `spec.notify.enabled` | boolean | no |  |  |
| `spec.notify.destinations` | array of string | no | max 16 items | Reserved. Selecting destinations is not available yet; a definition that lists some is refused. |
| `spec.memory` | object | no |  |  |
| `spec.memory.enabled` | boolean | no |  |  |
| `spec.memory.ttlDays` | integer | no | min 1; max 3650 | How long a saved memory stays valid. The policy sets the maximum. |
| `spec.skills` | array of object | no | max 16 items | Skills of the platform catalog, never an image reference. |
| `spec.skills[].name` | string | yes | min length 1; max length 63 |  |
| `spec.skills[].version` | string | no | max length 128 | Optional. When set it must be a version the catalog offers (today: the digest sha256:&lt;hex&gt; of the catalog's reference); absent takes the catalog's. |
| `spec.egress` | object | no |  |  |
| `spec.egress.allow` | array of string | no | max 64 items | Origins (`https://host[:port]`) the sandbox may reach. Each must match the platform policy. |
| `spec.suspend` | boolean | no |  | Stops the agent (Ready=False, reason Suspended). The runtime has no pause, so suspend is a STOP - the runtime agent is removed and running conversations end - and the agent's gateway key is cut (it opens nothing until resume). Resume is a fresh start with the same definition, key and revision, and at most once per two minutes. The definition stays accepted. The operator's policy (suspendAll) can stop every definition too. |
| `spec.runtime` | object | no |  | How the agent is made. Absent means builtin (the platform builds it from the instructions). The operator's policy says which types a definition may use (allowedRuntimes, default only builtin). |
| `spec.runtime.type` | string | no | one of `builtin`, `container` | builtin (default) or container (the platform runs your digest-pinned image, which speaks A2A, as the agent). |
| `spec.runtime.container` | object | no |  | Set when type is container, and only then. |
| `spec.runtime.container.image` | string | yes | max length 300 | Your agent's image, pinned by digest: registry/path@sha256:&lt;64 hex&gt;. It must be under a registry prefix the operator's policy lists. |
| `spec.runtime.container.port` | integer | yes | min 1024; max 65535 | The port the container serves A2A on. |
| `spec.runtime.container.env` | array of object | no | max 32 items | Plain environment variables. Never a secret; names the platform owns (OPENAGENTIX_, OPENAI_, OTEL_, KUBERNETES_) are refused. |
| `spec.runtime.container.env[].name` | string | yes | min length 1; max length 63; pattern `^[A-Z_][A-Z0-9_]*$` |  |
| `spec.runtime.container.env[].value` | string | yes | max length 4096 |  |
| `spec.runtime.container.resources` | object | no |  | Optional. Requests default and limits are capped by the operator's policy. |
| `spec.runtime.container.resources.requests` | object | no |  |  |
| `spec.runtime.container.resources.requests.cpu` | string | no | max length 16 |  |
| `spec.runtime.container.resources.requests.memory` | string | no | max length 16 |  |
| `spec.runtime.container.resources.limits` | object | no |  |  |
| `spec.runtime.container.resources.limits.cpu` | string | no | max length 16 |  |
| `spec.runtime.container.resources.limits.memory` | string | no | max length 16 |  |
<!-- generated:end ad-spec-fields -->

Availability of each part of `spec`:

| Field | Availability |
|---|---|
| `description`, `model`, `instructions`, `toolProfile`, `tools`, `egress.allow`, `suspend` | available |
| `skills` | available but off by default (policy `allowedSkills` is empty; the chart catalog has the example skill `openagentix-canary`) |
| `knowledge.enabled`, `notify.enabled` | available but off by default (the policy `allowKnowledge` is true, `allowNotify` is false; each also needs its service installed) |
| `memory` | available but off by default (policy `memory.allowed` is false; it needs the memory stack) |
| `instructionsFrom`, `knowledge.collections`, `notify.destinations` | reserved (designed, not built): a value is refused with the words "not available yet" |
| `spec.runtime` (bring your own agent) | reserved (designed, not built): not part of the schema on `main`; see [Reserved kinds and fields](./reserved-kinds.md) |

### Rules on the whole object

These rules are in the CRD. The API server checks them before the controller sees the object.

<!-- generated:begin ad-object-rules -->
| Rule (CEL) | Applies to | Refusal sentence |
|---|---|---|
| `self.metadata.name.size() <= 40` | the object | name must be at most 40 characters |
| `self.metadata.name.matches('^[a-z]([-a-z0-9]*[a-z0-9])?$')` | the object | name must be a DNS label: lower case letters, digits and dashes, starting with a letter |
| `(has(self.runtime) && has(self.runtime.type) && self.runtime.type == 'container') || has(self.instructions) != has(self.instructionsFrom)` | `spec` | set exactly one of instructions and instructionsFrom |
<!-- generated:end ad-object-rules -->

### What the platform decides

The schema only checks shapes. The controller then checks the definition against the catalog and the policy. Each refusal is one sentence in `status.violations`. This table says which setting decides each part:

| Part of the definition | Decided by | Setting |
|---|---|---|
| name | DNS label of at most 40 characters; not reserved in the namespace | `policy.reservedNames`, the catalog's `reservedNames` (chart agents, `kb`, `kb-extract`, `memory`) |
| number of definitions | accepted definitions per namespace | `policy.maxAgents` (and the quota `controlPlane.maxDefinitions` for all objects) |
| `model` | must be in the catalog and allowed | `policy.allowedModels` |
| `toolProfile` | must be defined in the catalog and allowed; required when `tools` or `knowledge` or `notify` are used | `policy.allowedProfiles`, `policy.requireToolProfile` |
| `tools` | each tool must be offered by the profile; no duplicates | the catalog's profile |
| `knowledge.enabled` | the service must be installed; the profile must offer all knowledge tools | `policy.allowKnowledge` |
| `notify.enabled` | the service must be installed; the profile must offer all notify tools | `policy.allowNotify` |
| `memory` | the memory stack must be installed; expiry job on (when required); `ttlDays` at most the maximum (the catalog default counts when `ttlDays` is empty) | `policy.memory.allowed`, `policy.memory.maxTtlDays`, `policy.memory.requireExpiry` |
| `skills` | must be in the catalog and allowed; `version` must be the digest the catalog offers | `policy.allowedSkills` |
| `egress.allow` | each origin must match an allowed origin (a `*.` entry matches exactly one label); cluster-internal hosts are refused unless listed | `policy.egress.allowedOrigins`, `policy.egress.inClusterDestinations` |
| any text field | nothing shaped like a secret (see below) | fixed in code |
| all definitions | stopped | `policy.suspendAll` |

A text field is refused if it holds something shaped like a secret. The patterns are: `aws_access_key_id`, `bearer_token`, `github_token`, `google_api_key`, `jwt`, `private_key_header`, `provider_secret_key`, `slack_token`, `stripe_secret_key`, `telegram_bot_token`, `platform_virtual_key`. The sentence names the pattern and never repeats the text.

### Violation sentences

The controller returns these sentences in `status.violations`, in this order of checking. `%q`, `%d` and `%s` are filled in with the real values. Two more sentences come from the tools adapter, when a tool is missing from a profile:

- `the definition lists tool "T" but profile "P" has codeMode off (set codeMode: true on the profile)`
- `the definition lists tool "T" which is not in profile "P" (the profile offers: a, b)`

<!-- generated:begin ad-violations -->
| No. | Sentence (a verb such as %q or %d is filled in with the real value) |
|---|---|
| 1 | name %q is too long: at most %d characters |
| 2 | name %q must be a DNS label (lower case letters, digits and dashes, starting with a letter) |
| 3 | name %q is reserved in namespace %q (chart agents and platform services own it) |
| 4 | the platform policy allows at most %d agents in namespace %q and %d already exist |
| 5 | runtime.type %q is not known (use builtin or container) |
| 6 | runtime %s is not allowed by the platform policy |
| 7 | runtime %s is not available on this platform |
| 8 | runtime.container is set but runtime.type is builtin; set runtime.type to container or remove the block |
| 9 | label %s %q is not a valid label value (at most 63 characters: letters, digits, '-', '_' and '.', starting and ending with a letter or digit) |
| 10 | label %s contains something shaped like a secret (%s); remove it |
| 11 | description is %d characters; at most %d |
| 12 | set exactly one of instructions and instructionsFrom |
| 13 | instructionsFrom is not available yet; write the prompt in instructions |
| 14 | instructions are required: set exactly one of instructions and instructionsFrom |
| 15 | instructions are %d bytes; at most %d |
| 16 | instructions contain something shaped like a secret (%s); remove it |
| 17 | %s contains something shaped like a secret (%s); remove it |
| 18 | model %q is not in the platform catalog (%s) |
| 19 | model %q is not allowed by the platform policy |
| 20 | toolProfile %q is not defined (defined: %s) |
| 21 | toolProfile %q is not allowed by the platform policy |
| 22 | %s adds tools, so it needs a toolProfile: the shared tool server filters on the client side only |
| 23 | the definition lists tools but names no toolProfile: the shared tool server filters on the client side only |
| 24 | the platform policy requires a toolProfile |
| 25 | %s |
| 26 | the definition lists tool %q twice |
| 27 | %s is not allowed by the platform policy |
| 28 | %s is not available on this platform |
| 29 | knowledge.collections: selecting collections is not available yet; leave the list empty |
| 30 | notify.destinations: selecting destinations is not available yet; leave the list empty |
| 31 | memory is not allowed by the platform policy |
| 32 | memory is not installed on this platform |
| 33 | the memory expiry job is off, so the time limit would not be enforced; memory is refused until an operator turns it on |
| 34 | memory.ttlDays must be at least 1 |
| 35 | memory.ttlDays %d is above the platform maximum of %d |
| 36 | skill %q is listed twice |
| 37 | skill %q is not in the platform catalog |
| 38 | skill %q is not allowed by the platform policy |
| 39 | skill %q has no version %q in the platform catalog (it offers %q); leave version empty to take it |
| 40 | egress.allow has %d origins; at most %d are allowed |
| 41 | egress.allow entry %q is not an origin: use `https://host[:port]` or `http://host[:port]`, a lower case DNS name (a wildcard replaces exactly one leftmost label), no path, no query, no address |
| 42 | egress.allow lists %q twice |
| 43 | egress.allow entry %q is %s (it can never be listed) |
| 44 | egress.allow entry %q names a cluster-internal or local host (an address, a name without a dot, .svc or .cluster.local, or a last label such as .internal, .local, .lan or .corp that only looks public); the policy cannot allow it unless the operator lists exactly host:port in egress.inClusterDestinations |
| 45 | egress.allow entry %q is not matched by the platform policy |
<!-- generated:end ad-violations -->

## `status`

The public fields are the contract. A product may read them. They follow the deprecation rules in the [API conventions](./api-conventions.md). Everything under `status.controller` is internal.

What a client may rely on:

- `Ready=True` means: the agent is callable at `status.endpoint`, at `status.revision`. This is the one signal to wait for.
- The conditions `Accepted`, `KeyReady`, `Applied` and `Synced` say what happened. Do not use them to decide when to call the agent.
- `observedGeneration` is the newest generation the controller has looked at. If it is lower than `metadata.generation`, the status is old.
- `revision` is a stable hash (12 hex characters) of what was applied: the final prompt, the model, the tool profile and tools, the skills and their digests, the knowledge, notify and memory settings and the egress. Lists are sets. A change of `description`, labels, `suspend`, name or namespace does not change it. The CRD allows up to 64 characters.
- `endpoint` is empty while the agent is suspended or refused, and when the A2A gate is off.
- A fact the platform could not check is the word `unknown`, never a guess.

<!-- generated:begin ad-status-fields -->
| Path | Type | Required | Limits and checks | Meaning |
|---|---|---|---|---|
| `status.observedGeneration` | integer | no | format int64 |  |
| `status.conditions` | array of object | no | max 8 items; list type map | Ready=True means the agent is callable at status.endpoint, at status.revision. The other conditions are informational. Reasons by condition. Accepted: Accepted (the definition passes the catalog and the policy); PolicyViolation (one or more rules refused it; each is one sentence in status.violations). KeyReady: KeyReady (the key exists and its hash is registered); KeyFailed (the key could not be made or registered); KeySuspended (suspended: the key exists but the gateway does not know it, so it opens nothing until resume); NotAccepted (unknown: refused, so no key); NotApplied (unknown: an earlier step stopped the pass). Applied: Applied (the objects of this generation were written); PreviousGenerationRunning (this generation is refused, the previous one keeps running); NotAccepted (refused, nothing runs); NotApplied (a step before the write failed or waits); NameConflict (an object with a target name is not owned by this definition, nothing was written); CheckFailed (the name check could not read the cluster); RenderFailed (the objects could not be rendered); ApplyFailed (writing an object failed); PruneFailed (removing an unwanted object failed); RemoveFailed (removing the objects or the key failed); PolicyRemoved (the catalog or the policy changed and what ran is no longer allowed: objects and key were removed). Ready: Ready (callable at status.endpoint at status.revision); Suspended (suspended by spec.suspend or by the operator: the runtime agent is removed, conversations end, the key is cut; nothing is wrong); ResumeDelayed (resumed too soon after the runtime agent was created: it stays stopped until the minimum time between two creations has passed, the message says until when); NotAccepted (refused, or its objects were removed); NotApplied (the objects of this generation are not written yet); ReadinessUnknown (the runtime state could not be read); NoEndpoint (the runtime says ready but no endpoint is advertised); RuntimeNotCreated (the runtime has not created the agent yet); RuntimeStale (the runtime has not caught up with the latest spec); RuntimePending (the runtime reports no verdict yet); RuntimeNotReady (the runtime reports not ready, its words are in the message); RuntimeRejected (the runtime refused the agent, its words are in the message). Synced: Synced (the last pass could read everything); TransientError (a read failed; the other conditions are the last known state). |
| `status.conditions[].type` | string | yes | max length 32 |  |
| `status.conditions[].status` | string | yes | one of `True`, `False`, `Unknown` |  |
| `status.conditions[].reason` | string | yes | max length 64 |  |
| `status.conditions[].message` | string | no | max length 1024 |  |
| `status.conditions[].observedGeneration` | integer | no | format int64 |  |
| `status.conditions[].lastTransitionTime` | string | no | format date-time |  |
| `status.endpoint` | object | no |  | Where the agent is callable. Absent while suspended, refused or when the platform advertises no route. |
| `status.endpoint.protocol` | string | no |  | a2a today |
| `status.endpoint.url` | string | no |  |  |
| `status.endpoint.protocolVersion` | string | no |  |  |
| `status.revision` | string | no | max length 64 | A stable hash of what was applied (instructions, model, tool profile and tools, skill digests, knowledge, notify and memory settings, egress). A change of description or labels does not change it. |
| `status.effectiveTools` | array of string | no |  |  |
| `status.effectiveEgress` | array of string | no |  |  |
| `status.violations` | array of string | no |  |  |
| `status.capabilities` | object | no |  | What the runtime can do, reported by its adapter; "unknown" where it could not be verified. |
| `status.capabilities.approvals` | string | no | one of `yes`, `no`, `unknown` |  |
| `status.capabilities.durableWaits` | string | no | one of `yes`, `no`, `unknown` |  |
| `status.capabilities.workspacePersistence` | string | no | one of `none`, `snapshot`, `volume`, `unknown` |  |
| `status.capabilities.maxStepSeconds` | integer | no |  | 0 is unknown |
| `status.capabilities.cancelStopsLoop` | string | no | one of `yes`, `no`, `unknown` |  |
| `status.capabilities.perRunIdentity` | string | no | one of `none`, `session`, `run`, `unknown` |  |
| `status.capabilities.isolation` | string | no |  | How the agent is separated from others: sandbox-per-session, sandboxed-pod or container. Absent is unknown. |
| `status.agentRef` | object | no |  | One generic reference to the runtime's object, for people who debug. |
| `status.agentRef.apiVersion` | string | no |  |  |
| `status.agentRef.kind` | string | no |  |  |
| `status.agentRef.name` | string | no |  |  |
<!-- generated:end ad-status-fields -->

### `status.capabilities`

The runtime adapter reports what the runtime can do. A value that could not be checked is `unknown` (`maxStepSeconds: 0` means unknown). The values the kagent adapter reports today:

| Field | Values | kagent value now |
|---|---|---|
| `approvals` | `yes`, `no`, `unknown` | `yes` |
| `durableWaits` | `yes`, `no`, `unknown` | `yes` |
| `workspacePersistence` | `none`, `snapshot`, `volume`, `unknown` | `snapshot` |
| `maxStepSeconds` | integer, 0 is unknown | `600` |
| `cancelStopsLoop` | `yes`, `no`, `unknown` | `unknown` |
| `perRunIdentity` | `none`, `session`, `run`, `unknown` | `session` |

These values come from the kagent documents. They were not all tried on a cluster.

### `status.controller` (internal)

This block is what the controller remembers between passes. It holds nothing secret. It is **not part of the contract** and may change without notice. Nothing outside the controller may read it.

<!-- generated:begin ad-status-controller -->
| Path | Type | Required | Limits and checks | Meaning |
|---|---|---|---|---|
| `status.controller.keySecret` | string | no |  | Name of the key Secret in use: &lt;name&gt;-virtual-key-&lt;first 8 hex of the UID&gt;. |
| `status.controller.keyFingerprint` | string | no | max length 64 | Head of the registered key's hash; the same value is the annotation openagentix.io/key-fingerprint on the Secret and on the runtime objects. |
| `status.controller.appliedGeneration` | integer | no | format int64 | Generation of the spec whose objects exist; 0 when nothing runs. |
| `status.controller.appliedSpec` | string | no | max length 200000 | The spec that was applied, as JSON text. Lets the controller decide what to do when a later spec is refused. |
| `status.controller.gatewayUserId` | string | no |  | Opaque. &lt;namespace&gt;.&lt;name&gt; today. |
| `status.controller.toolServer` | string | no |  |  |
| `status.controller.heldKeyHash` | string | no | max length 80 | While suspended: the registered hash of the key (not a secret), kept so that resume registers the same key again. Empty otherwise. |
| `status.controller.agentStartedAt` | string | no | max length 40 | When the controller last created the runtime agent (RFC 3339); rate-limits suspend and resume. |
<!-- generated:end ad-status-controller -->

## Conditions

Five condition types can be present. `Accepted`, `KeyReady`, `Applied` and `Ready` are always set after the first pass. `Synced` is present only after a pass could not read something. The CRD allows at most 8 conditions. `reason` is cut to 64 characters and `message` to 1024.

Every reason the controller can set is in this table. It is generated from `services/control-plane/internal/api/reasons.go`. A test in the controller fails if the code sets a reason that is not in the table. A reason that comes from the runtime and is not in the table is mapped to `RuntimeNotReady`, with its own word at the start of the message.

<!-- generated:begin ad-reasons -->
| Condition | Reason | Status | Meaning |
|---|---|---|---|
| `Accepted` | `Accepted` | True | the definition passes the catalog and the policy |
| `Accepted` | `PolicyViolation` | False | one or more rules refused it; each is one sentence in status.violations |
| `KeyReady` | `KeyReady` | True | the agent's gateway key exists and its hash is registered |
| `KeyReady` | `KeyFailed` | False | the key could not be created or registered; the message says why |
| `KeyReady` | `KeySuspended` | False | the definition is suspended: the key exists but the gateway does not know it, so it opens nothing; it is registered again on resume |
| `KeyReady` | `NotAccepted` | Unknown | the definition is refused, so no key is made |
| `KeyReady` | `NotApplied` | Unknown | an earlier step (the name check) stopped the pass before the key |
| `Applied` | `Applied` | True | the runtime objects of this generation were written |
| `Applied` | `PreviousGenerationRunning` | True | this generation is refused; the previously applied one keeps running |
| `Applied` | `NotAccepted` | False | the definition is refused and nothing is running |
| `Applied` | `NotApplied` | False | a step before the write failed or is waiting (the key) |
| `Applied` | `NameConflict` | False | an object with a target name exists and is not owned by this definition; nothing was written |
| `Applied` | `CheckFailed` | False | the name check could not read the cluster |
| `Applied` | `RenderFailed` | False | the runtime adapter could not turn the plan into objects |
| `Applied` | `ApplyFailed` | False | writing an object failed |
| `Applied` | `PruneFailed` | False | removing an object that is no longer wanted failed |
| `Applied` | `RemoveFailed` | False | removing the objects or the key of a definition that is no longer allowed failed |
| `Applied` | `PolicyRemoved` | False | the catalog or the policy changed and what ran is no longer allowed: objects and key were removed |
| `Ready` | `Ready` | True | the agent is callable at status.endpoint at status.revision |
| `Ready` | `Suspended` | False | suspended by spec.suspend or by the operator (policy suspendAll): the runtime agent is removed (running conversations end) and the key is cut; nothing is wrong |
| `Ready` | `ResumeDelayed` | False | resumed too soon after the runtime agent was created: it stays stopped until the minimum time between two creations has passed; the message says until when |
| `Ready` | `NotAccepted` | False | the definition is refused (or its objects were removed) |
| `Ready` | `NotApplied` | False | the objects of this generation are not written yet or could not be |
| `Ready` | `ReadinessUnknown` | False | the runtime's state could not be read |
| `Ready` | `NoEndpoint` | False | the runtime reports the agent ready but the platform advertises no endpoint for it (the A2A gate is off), so it is not callable at status.endpoint |
| `Ready` | `RuntimeNotCreated` | False | the runtime has not created the agent yet |
| `Ready` | `RuntimeStale` | False | the runtime has not caught up with the latest spec yet |
| `Ready` | `RuntimePending` | False | the runtime reports no verdict yet |
| `Ready` | `RuntimeNotReady` | False | the runtime reports the agent not ready; its own words are in the message |
| `Ready` | `RuntimeRejected` | False | the runtime refused the agent; its own words are in the message |
| `Synced` | `Synced` | True | the last pass could read everything it needed |
| `Synced` | `TransientError` | False | a read failed; the other conditions are the last known state, not a new verdict |
<!-- generated:end ad-reasons -->

What to do when you see a reason:

| Reason | What to do |
|---|---|
| `PolicyViolation` | Read `status.violations`. Fix the definition, or ask the platform team to change the policy. |
| `KeyFailed` | Read the condition message. Check the controller log and the model gateway. The controller retries. |
| `KeySuspended` | Nothing is wrong. Set `suspend: false` (and check `policy.suspendAll`). |
| `NotAccepted` | The definition is refused. Fix `status.violations` first. |
| `NotApplied` | An earlier step stopped the pass (the key or the name check). Read the `KeyReady` and `Applied` messages. |
| `PreviousGenerationRunning` | Your last edit is refused, and the older version still runs. Read `status.violations`. |
| `NameConflict` | An object with the name the controller wants already exists and this definition does not own it. Rename the definition, or remove the other object. This lasts until the generation changes. |
| `CheckFailed`, `ApplyFailed`, `PruneFailed`, `RemoveFailed`, `RenderFailed` | A write or read failed. Read the message. The controller retries with a delay that doubles. Look at the controller log. |
| `PolicyRemoved` | The catalog or policy changed and what ran is no longer allowed. The objects and the key are removed. Change the definition or the policy. |
| `Suspended` | Nothing is wrong. `spec.suspend` or `policy.suspendAll` stops the agent. |
| `ResumeDelayed` | You resumed too soon. Wait until the time in the message (default two minutes between two creations). |
| `ReadinessUnknown` | The runtime state could not be read. Check the controller log. |
| `NoEndpoint` | The runtime says ready, but the A2A gate is off, so the platform has no address to give. Turn the gate on (`governance.a2a.enabled`). |
| `RuntimeNotCreated`, `RuntimeStale`, `RuntimePending` | The runtime is still working. Wait. |
| `RuntimeNotReady`, `RuntimeRejected` | The runtime's own words are in the message. Look at the runtime objects named in `status.agentRef`. |
| `TransientError` | A read failed. The other conditions show the last known state. It clears at the next good pass. |

## Names and ownership

For a definition named `NAME` with UID `UID`, in namespace `NS`, the kagent adapter makes these objects in the same namespace:

| Object | Name | Made when |
|---|---|---|
| ModelConfig | `gateway-NAME` | always |
| Harness | `NAME-harness` | always |
| AgentTemplate | `NAME-template` | always |
| EgressPolicy | `NAME-egress` | when the egress list is not empty |
| Agent | `NAME` | always, except while suspended |
| Secret (the agent's gateway key) | `NAME-virtual-key-` plus the first 8 hex characters of the UID (dashes removed) | when a key is needed |
| entry in the ConfigMap `llm-api-keys-control-plane` in the gateway namespace | `NS.NAME` | while the agent is not suspended |

The gateway user (and the cost label) is `NS.NAME`. Treat it as an opaque string. Do not parse it.

How ownership works:

- Every object carries the label `app.kubernetes.io/managed-by: openagentix-control-plane` and the label `openagentix.io/agent-definition: NAME`, and an owner reference to the definition (kind `AgentDefinition`, with `controller: true`).
- An object counts as owned only when it has **both labels and the owner reference**. Labels alone prove nothing.
- If an object with a target name exists and is not owned, the controller sets `Applied=False` with reason `NameConflict` and writes nothing.
- The controller writes with server-side apply, field manager `openagentix-control-plane`.
- The definition has the finalizer `openagentix.io/gateway-key`. On delete the controller removes its objects, then the key entry, then the finalizer. The key Secret goes with the definition through its owner reference.
- Every pass, the controller removes entries from the key ConfigMap whose user is not `NS.NAME` of a listed definition. Entries of another namespace's prefix are left alone.

## Labels and annotations

| Key | Where | Meaning |
|---|---|---|
| `openagentix.io/team` | definition label | Reserved. Informational. The controller checks it is a valid label value (at most 63 characters, not secret-shaped), copies it to every object it creates and to the key entry's metadata. |
| `openagentix.io/project` | definition label | Same as `team`. |
| `openagentix.io/work-item` | definition label | Reserved for products. Not copied. Not checked. |
| `app.kubernetes.io/managed-by` | created objects | Value `openagentix-control-plane`. |
| `openagentix.io/agent-definition` | created objects | The name of the definition. |
| `openagentix.io/key-fingerprint` | key Secret, Harness, Agent | The head (up to 16 hex characters) of the registered key hash. Changing the key changes it. |
| `openagentix.io/agent` | ModelConfig | The name of the definition. |

The reserved labels are **informational**. Anyone who can write the object can set them, so no access, policy or billing decision reads them. Other labels and annotations on a definition are ignored.

## Life cycle

The status shown is what a client sees after the controller finished the pass. Timings depend on the runtime. On the demo cluster a definition became ready in 13 to 31 seconds.

1. **Create, accepted.** The controller adds the finalizer. `Accepted=True` (reason `Accepted`), `KeyReady=True`, `Applied=True`. `Ready` is `False` with reasons such as `RuntimeNotCreated` or `RuntimePending` until the runtime is ready, then `Ready=True`. `endpoint`, `revision`, `effectiveTools`, `effectiveEgress` and `capabilities` are set.
2. **Create, refused.** `Accepted=False` (reason `PolicyViolation`), one sentence per rule in `status.violations`. `KeyReady=Unknown` (`NotAccepted`), `Applied=False` (`NotAccepted`), `Ready=False` (`NotAccepted`). Nothing is created.
3. **Edit, accepted.** The generation grows. The controller applies the new objects. `revision` changes if a field that is part of it changed. `Ready` may drop for a short time (`RuntimeStale`) while the runtime catches up.
4. **Edit, refused.** If the version that runs still passes the catalog and policy, it keeps running. `Accepted=False` (`PolicyViolation`, `violations` filled), `Applied=True` with reason `PreviousGenerationRunning`. `Ready`, `endpoint`, `revision` and the effective lists keep describing what runs.
5. **Policy or catalog tightened.** If what ran is no longer allowed, the controller removes the agent's objects and unregisters the key. The definition and its status stay. `Applied=False` (`PolicyRemoved`), `Ready=False` (`NotAccepted`). `endpoint`, `revision`, `effectiveTools`, `effectiveEgress`, `agentRef` and `status.controller` are cleared. If the policy allows it again, a new key replaces the old one.
6. **Suspend** (`spec.suspend: true` or `policy.suspendAll: true`). This is a **stop, not a pause**. The runtime agent is removed and running conversations end. The key entry is removed at the gateway, so the key opens nothing. The definition stays accepted. `Ready=False` (`Suspended`), `KeyReady=False` (`KeySuspended`). `endpoint` and `agentRef` are cleared.
7. **Resume** (`suspend: false`). The runtime agent is created again and the same key is registered again. A runtime agent is created at most once per `CONTROL_PLANE_MIN_RECREATE_INTERVAL` (default 2 minutes) per definition. A resume inside that time gives `Ready=False` (`ResumeDelayed`). The first start is never delayed. A resumed agent is a new agent to the runtime: old sessions may not resolve it.
8. **Delete.** The controller removes the owned objects, then the key entry, then the finalizer. The definition goes. The key Secret goes with it.

If a read fails while a definition runs, `Synced=False` (`TransientError`) is added and the other conditions keep the last known state.

## kubectl

The printer columns of `kubectl get oad`:

<!-- generated:begin ad-printer-columns -->
| Column | Type | Source |
|---|---|---|
| Model | string | `.spec.model` |
| Profile | string | `.spec.toolProfile` |
| Accepted | string | `.status.conditions[?(@.type=="Accepted")].status` |
| Ready | string | `.status.conditions[?(@.type=="Ready")].status` |
| Revision | string | `.status.revision` |
| Suspended | boolean | `.spec.suspend` |
| Age | date | `.metadata.creationTimestamp` |
<!-- generated:end ad-printer-columns -->

```sh
# list definitions and their state
kubectl get oad -n kagent

# apply, then wait until the agent is callable
kubectl apply -f components/control-plane/researcher.yaml
kubectl wait agentdefinition/researcher -n kagent --for=condition=Ready --timeout=900s

# wait until a definition is refused (useful in tests)
kubectl wait agentdefinition/researcher -n kagent --for=condition=Accepted=False --timeout=60s

# read the refusal sentences, one per line
kubectl get oad researcher -n kagent -o json | jq -r '.status.violations[]'

# where to call the agent, and which revision runs
kubectl get oad researcher -n kagent -o jsonpath='{.status.endpoint.url}{"\n"}{.status.revision}{"\n"}'

# every condition with its reason
kubectl get oad researcher -n kagent -o json | jq -r '.status.conditions[] | "\(.type)\t\(.status)\t\(.reason)\t\(.message)"'

# stop and start again
kubectl patch oad researcher -n kagent --type merge -p '{"spec":{"suspend":true}}'
kubectl patch oad researcher -n kagent --type merge -p '{"spec":{"suspend":false}}'
```

## Quotas and limits

| Limit | Value | Where it is set |
|---|---|---|
| name length | 40 characters, DNS label | CRD rule and controller |
| `description` | 256 characters | CRD and controller |
| `instructions` | 1 to 16384 bytes (UTF-8) | CRD and controller |
| `tools` | 64 items, each 1 to 128 characters | CRD |
| `skills` | 16 items | CRD |
| `egress.allow` | 64 origins, each at most 270 characters | CRD and controller |
| `memory.ttlDays` | 1 to 3650, and at most `policy.memory.maxTtlDays` | CRD and controller |
| definitions per namespace that hold a place | `controlPlane.policy.maxAgents` (default 5) | policy |
| definition objects in the agents namespace, refused ones too | `controlPlane.maxDefinitions` (default 50) | a `ResourceQuota` named `openagentix-agentdefinitions` on `count/agentdefinitions.openagentix.io` |
| time between two controller passes | `CONTROL_PLANE_MIN_INTERVAL` (default 1 s) | controller environment |
| longest time between full passes | `CONTROL_PLANE_RESYNC` (default 60 s) | controller environment |
| time between two creations of one runtime agent | `CONTROL_PLANE_MIN_RECREATE_INTERVAL` (default 2 minutes) | controller environment |

When `maxAgents` is reached, definitions that already run keep their place. Then the oldest come first. A definition that never ran and is refused holds no place.

## Roles for people

The chart renders two Roles in the agents namespace and binds them to nobody. An operator binds them.

| Role | Verbs on `agentdefinitions` | On `agentdefinitions/status` |
|---|---|---|
| `openagentix-agent-builder` | get, list, watch, create, update, patch, delete | get, list, watch |
| `openagentix-agent-viewer` | get, list, watch | get, list, watch |

Neither role gives access to Secrets, pods, `pods/exec` or kagent resources. Bind a role to a user or group:

```sh
kubectl create rolebinding alice-builds-agents -n kagent \
  --role openagentix-agent-builder --user alice

kubectl create rolebinding platform-views-agents -n kagent \
  --role openagentix-agent-viewer --group platform-team
```

The roles control who may write a definition. They do not control what a definition may ask for: the policy and the [admission guard](./admission-guard.md) do that.

## Where this page differs from other documents

The code wins. These differences were found while this page was written:

- The comment on `controlPlane.policy.allowKnowledge` in `charts/openagentix/values.yaml` says "`knowledge: true` is allowed". The field is an object, so the true form is `knowledge.enabled: true`.
- `status.revision` is 12 hex characters (`internal/plan`). The CRD allows up to 64.
- The printer columns come from the CRD. They match the README.
