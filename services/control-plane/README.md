# control-plane

The controller of the agent builder (ADR 0007, `docs/decisions/0007-control-plane-and-agent-builder.md`; the platform-level changes of
ADR 0012 are in). It watches `AgentDefinition` resources (`openagentix.io/v1alpha1`, short name `oad`) and turns each one into what an
agent needs: the runtime objects (for kagent: ModelConfig, Harness, AgentTemplate, an optional EgressPolicy and the Agent), a gateway
virtual key, and the key's registration at the model gateway. It writes the result back as conditions and facts in `status`.

It is off by default (chart value `controlPlane.enabled`). It has no dependency outside the Go standard library and no client library:
`internal/kube` is a small REST client. The platform-wide API rules (one group, versions per kind, deprecation, reserved labels) are in
`docs/api-conventions.md`; the parts that belong to this kind are below.

## The spec

A definition is the whole builder surface. There is deliberately no field for a model config, image, tool server, egress policy,
namespace, caller, gateway user or budget, and no upstream product is named in a field or in a text of the spec.

| Field | Type | Meaning |
|---|---|---|
| `description` | string, at most 256 | one line; not part of the revision |
| `model` | string | a gateway model the policy allows (required) |
| `instructions` | string, 1 to 16384 **bytes** (UTF-8) | the system prompt. One limit, in bytes: the CRD has a rule `bytes(self).size() <= 16384` next to a `maxLength` of 16384 characters (never looser), and the controller counts bytes |
| `instructionsFrom` | `{configMap: {name, key}}` | **reserved**: exactly one of `instructions` and `instructionsFrom` must be set (a CEL rule in the CRD and a check in the controller), and this release refuses `instructionsFrom` with "not available yet" |
| `toolProfile`, `tools` | string, [string] | a tool profile of the catalog and the tools of it the agent may use |
| `knowledge` | `{enabled: bool, collections: [string]}` | the knowledge tools and prompt; `collections` is **reserved**: a non-empty list is refused with "selecting collections is not available yet" |
| `notify` | `{enabled: bool, destinations: [string]}` | the delivery tools and prompt; `destinations` is **reserved** in the same way |
| `memory` | `{enabled: bool, ttlDays: int}` | long-term memory; `ttlDays` at least 1, at most the policy maximum |
| `skills` | [`{name, version?}`] | skills of the catalog. `version`, when set, must be one the catalog offers: today the digest `sha256:<64 hex>` of the catalog's reference (one digest per skill); absent takes the catalog's. An unknown version is refused with a sentence that says what the catalog offers |
| `egress.allow` | [origin] | origins the sandbox may reach, checked against the policy |
| `suspend` | bool | a **stop**: the runtime agent is removed, running conversations end, the gateway key is cut; see "Suspend" |

A definition's rules are **per namespace**: reserved names, `maxAgents` and every object and key name are scoped to the definition's own
namespace, and nothing in the code assumes the namespace is called `kagent` (the name comes from the catalog, `namespaces.agents`). The
controller still lists and watches one namespace, the catalog's.

## What it does, per definition

1. **Adds the finalizer** `openagentix.io/gateway-key`.
2. **Validates** the definition against the platform catalog (what exists) and the policy (what is allowed), see "Refusals".
   A refusal sets `Accepted=False` and puts one sentence per rule into `status.violations`. Nothing else is written.
3. **Checks names.** An object is *owned* by a definition only when it carries both labels
   (`app.kubernetes.io/managed-by: openagentix-control-plane`, `openagentix.io/agent-definition: <name>`) **and** an owner
   reference to this very definition (kind `AgentDefinition`, its UID, `controller: true`); labels alone prove nothing. If an
   object with one of the target names exists and is not owned, the condition `Applied=False`, reason `NameConflict`, names
   it and **nothing is written** (no key, no object). A conflict is terminal until the definition's generation changes (the
   resync pass looks again, but it is not retried in between). A 404 on the check (the kind is not installed) is "does not exist".
4. **Makes the key.** `vk-` plus 16 random bytes in hex, in memory only, and only when needed. The Secret is named
   **`<name>-virtual-key-<first 8 hex characters of the definition's UID, dashes removed>`** (the data key is the runtime adapter's,
   `OPENAI_API_KEY` for kagent; `immutable: true`, labels, owner reference, annotation `openagentix.io/key-fingerprint`). Because the
   name carries the UID, a Secret of that name was made for this very definition, so the controller may replace it without reading
   it; a foreign Secret called `<name>-virtual-key` is never touched. The **gateway user** of the key is **`<namespace>.<name>`**
   (`status.controller.gatewayUserId`): treat it as an opaque string. It is also the name of the entry in the key ConfigMap
   `llm-api-keys-control-plane`, so two definitions with one name in two namespaces never share a key or a cost history, and a chart
   agent's user (a plain name, no dot) can never equal it. A ConfigMap key may hold `.`, and the gateway never reads the key's text
   (it reads the entry's JSON: agentgateway `controller/pkg/agentgateway/plugins/traffic_plugin.go`, `processAPIKeyAuthenticationPolicy`,
   and `crates/agentgateway/src/http/apikey.rs`, where `metadata` is a free map), so `user_id` carries the same string. The controller
   reads the gateway's key ConfigMap once per pass and compares the hash registered for the user with the fingerprint it recorded in
   `status.controller.keyFingerprint` (the first 16 hex characters of the hash, which is public in that ConfigMap):
   - registered hash present and equal to the recorded fingerprint: nothing to do, no mint, no request (if only the `team` or `project`
     label changed, the entry is rewritten with the same hash);
   - registered hash present but not the recorded one (an older entry was restored): the Secret is deleted, a new key is
     created and its hash written (the fingerprint on the runtime objects changes with it);
   - nothing recorded or no entry: `POST` the Secret. 201: write the hash. 409 and an entry exists: adopt it. 409 and no
     entry: delete the Secret, create a new one, write the hash.
   The controller never GETs or LISTs a Secret. Consequence: a Secret deleted by hand is not noticed until the hash or the
   definition changes.
5. **Applies** the runtime's objects with server-side apply (field manager `openagentix-control-plane`, force), each with the
   two labels and the owner reference above (and the reserved labels `team` and `project`, see "Reserved labels"). The kagent adapter
   also puts the annotation `openagentix.io/key-fingerprint` on the Harness and the Agent so that replacing the key changes them;
   whether kagent recreates the agent's pod on that annotation is **not verified on a live cluster**.
6. **Prunes** owned objects (labels and owner reference) that are no longer wanted. A kind the cluster does not know (404 on
   the list, for example a CRD that is not installed) has nothing to prune; it never blocks a pass or a deletion.
7. **Reports** the status contract (below). `observedGeneration` is the newest generation the controller has looked at; each condition's
   `observedGeneration` is the generation that condition describes. Reasons are cut to 64 and messages to 1024 characters (the CRD
   limits), on a character boundary. A status the API server refuses as invalid (422) is logged and not retried.
8. **On delete**: removes the owned objects, removes the key hash from the gateway, then the finalizer. The key Secret goes
   by its owner reference.
9. **Sweeps** every pass: an entry in the controller's key ConfigMap whose user is not `<namespace>.<name>` of a listed definition is
   removed (a definition created in the same pass is in the list, so it is never swept; a failed or partial list sweeps nothing). An
   entry of the previous format (the plain name, no dot) is nobody's user and goes too. An entry whose user starts with **another**
   namespace's prefix is left alone. **One controller per gateway:** the key ConfigMap `llm-api-keys-control-plane` belongs to one
   controller (the chart renders one ConfigMap, one Role for it and one admission guard that lets only that ServiceAccount write it, and the
   guard accepts only entries named `<agents namespace>.<name>`). A second controller for another agents namespace needs its own gateway
   ConfigMap; two controllers writing one ConfigMap would not corrupt each other's entries (the sweep touches only its own prefix) but the
   chart does not render that setup.

The loop is level-triggered. It lists (in pages of 100, at most 10 000 items), reconciles every definition one at a time,
then watches from the list's resourceVersion. A new definition, a changed spec (generation) or a requested deletion ends
the watch and starts the next pass; so does a change of the `openagentix.io/team` or `openagentix.io/project` label (it does not change the
generation, but it reaches the gateway entry and the objects), the resync timer (60 s), a retry that is due, or `410 Gone` (it lists again).
Its own status and finalizer writes do not start a pass. Passes start at least `CONTROL_PLANE_MIN_INTERVAL` (1 s) apart. The
watch has an open deadline (30 s) and the resync timer runs while it is being opened, so a hung API connection ends in a new
pass. One object that cannot be decoded, or that panics, is skipped and logged; the others are reconciled.

Order and limit: definitions that **run** (objects applied, even when the latest edit is refused and only the previous generation runs) come
first, then those accepted now, then the oldest (creation time, namespace, name). `maxAgents` counts the definitions that hold a place
**per namespace**: accepted ones, and refused ones whose previous generation keeps running. A definition that never ran and is refused
holds no place, and a definition that is fixed or created later never displaces one that already holds a place (with `maxAgents: 2`, A and B
running, A edited into a refused spec and C created, C is refused for capacity and A keeps running). When the limit is lowered below the
number that hold a place, the last ones in that order are refused.

Retries are per definition: a failure retries after `CONTROL_PLANE_BACKOFF` and the delay doubles per failure up to 30 times
that value; a runtime that is not ready yet is retried at the base interval; a new generation resets it. The other
definitions are not held back.

**Transient read errors.** When a read fails (the name check, the key registrations, the runtime's readiness) for a
definition that runs, `Applied`, `Ready` and the facts keep their last known state and a separate condition `Synced=False`
(reason `TransientError`, message the error) says the pass could not finish. It turns `True` when a pass succeeds.

## The status contract

The public fields are what products may read; they follow the deprecation rules of `docs/api-conventions.md`. Everything the
controller keeps for itself is under `status.controller` and may change without notice.

| Field | Meaning |
|---|---|
| `conditions` | `Accepted`, `KeyReady`, `Applied`, `Ready` (and `Synced`), see "Conditions" |
| `observedGeneration` | the newest generation the controller has looked at |
| `endpoint` | `{protocol: "a2a", url, protocolVersion}`: where the agent is callable; absent while suspended or refused, and when the platform advertises no route (the A2A gate is off). A second protocol or version needs no new field |
| `revision` | a stable hash (12 hex characters) of what was applied: the final prompt, the model, the tool profile and the effective tools, the skills with their digests, the knowledge, notify and memory settings, and the egress. Lists are sets (sorted before hashing). A change of `description`, labels, `suspend`, name or namespace does not change it. The runtime adapter's own settings (image, worker pool) are not in it |
| `effectiveTools`, `effectiveEgress` | the tools and egress origins as applied |
| `violations` | one sentence per refused rule |
| `capabilities` | what the runtime can do, see "Runtime capabilities" |
| `agentRef` | one generic reference to the runtime's object, for people who debug |
| `controller` | `keySecret`, `keyFingerprint`, `appliedGeneration`, `appliedSpec` (that spec as JSON text), `gatewayUserId`, `toolServer` (the backend the profile resolved to). Internal |

`kubectl get oad` shows Model, Profile, Accepted, Ready, Revision, Suspended and Age.

## Conditions

`Ready=True` means: **the agent is callable at `status.endpoint`, at `status.revision`.** A runtime that reports the agent ready while the
platform advertises no endpoint (the A2A gate is off) gives `Ready=False`, reason `NoEndpoint`: the promise cannot be made. The other
conditions (`Accepted`, `KeyReady`, `Applied`, `Synced`) are informational: say what happened, never gate on them. Every reason the controller
can set is in this table, and nowhere else; a test (`internal/core/contract_test.go`) fails when the code sets a reason that is not here,
and another (`internal/api`) fails when this table and the code differ. A reason that comes from the runtime adapter and is not in the table is
mapped to `RuntimeNotReady` with its own word at the start of the message.

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

## Suspend

**Suspend is a stop.** `spec.suspend: true` (or the policy's `suspendAll: true`, the operator's stop switch, which does the same for every
definition, also for one whose edit is refused while its previous generation runs) does four things:

1. **removes the runtime agent**, so running conversations end (kagent has no pause: see below);
2. **cuts model access**: the key's entry is removed from the gateway's key ConfigMap, so the key opens nothing at the model gateway while
   suspended. A leaked key is useless meanwhile. The Secret stays;
3. keeps the definition **accepted**, the other runtime objects, the key Secret and the status facts (`revision`, effective lists); `Ready=False`
   with reason `Suspended`, `KeyReady=False` with reason `KeySuspended`, `endpoint` and `agentRef` cleared;
4. on **resume** (`suspend: false`, or the switch off) the runtime agent is created again and the **same key** is registered again: a fresh start
   with the same definition, key and revision. No key is minted and no Secret is written.

**Where the hash is kept.** The controller never reads Secrets, so it cannot read the key back to register it again. It does not need to: the
gateway stores only the SHA-256 of the key, and that hash is public (it is what the ConfigMap holds). On suspend the controller writes the hash
to `status.controller.heldKeyHash` first, removes the entry second (an interruption in between loses nothing), and on resume registers the
held hash again. Status is the place because it is an object the controller may already read and patch; a builder role can only read it, so the
hash cannot be planted by the people who write definitions. If the held hash is ever lost (status wiped while suspended) the resume finds no
entry and no record and makes a new key the usual way: the key is replaced, which is safe, only not "the same key". A definition created while
`suspendAll` is on gets its key Secret made and its hash held, but nothing is ever registered.

**Rate limit.** A runtime agent is created at most once per `CONTROL_PLANE_MIN_RECREATE_INTERVAL` (default 2 minutes) per definition, counted
from the previous creation (`status.controller.agentStartedAt`). A resume inside the interval stays stopped with `Ready=False`, reason
`ResumeDelayed`, and a message that says until when; the key stays cut meanwhile; the controller retries by itself. The first start of a
definition is never delayed. A suspend and resume loop therefore cannot thrash the runtime's snapshots (a golden snapshot build is the
expensive thing on the demo node).

**How the stop is done:** kagent 1.0.1's `Agent` and `Harness` have no suspend, pause, replicas or desired-state field (read in the kagent API
types, `go/api/v1alpha3/agent_types.go` and `harness_types.go`, and `docs/architecture/runtime-and-lifecycle.md`, which says session
suspension is platform-managed with no public controls). So the runtime adapter, asked for a suspended plan, produces every object
**except the `Agent`**; the core prunes the `Agent` like any object no longer wanted. **What this costs, from the kagent documents (not tried on a cluster):** deleting an Agent "retires its
definition; sessions and checkpoints retain their pinned revisions", and "recreating the same name creates a new identity"
(`docs/architecture/configuration-and-compilation.md`); the identity lookup of an Actor JWT requires the Agent to have the same UID
(`docs/architecture/agent-identity-lookup.md`). So a resumed agent is a new Agent for new sessions, and an old session's tool calls that resolve
the agent by identity may fail. Suspend is therefore a stop with a fresh start, never a pause of running conversations. If a runtime offers a real
pause, only its adapter changes (and then the key cut could stay: it is the core's).

## Runtime capabilities

The `Runtime` adapter reports a small struct; the core copies it to `status.capabilities`. A value the adapter could not verify is
`unknown` (`maxStepSeconds: 0`). The kagent adapter's values, each from the kagent documents or API types (cited in
`internal/adapters/kagent/kagent.go`):

| Field | kagent | Source (in the kagent repository) |
|---|---|---|
| `approvals` | `yes` | `docs/architecture/human-in-the-loop.md`; `go/api/v1alpha3/agenttemplate_types.go` (`RequireApproval`) |
| `durableWaits` | `yes` | `docs/architecture/persistence-checkpoints-and-forks.md` ("Input-required and auth-required tasks are durably suspended") |
| `workspacePersistence` | `snapshot` | `docs/architecture/runtime-and-lifecycle.md` (snapshot fidelity; suspending an Actor preserves files, not running commands) |
| `maxStepSeconds` | `600` | `docs/architecture/runtime-and-lifecycle.md` (bash: 60 s default, `timeout_seconds` up to 600) |
| `cancelStopsLoop` | `unknown` | the docs speak of "the interrupted execution" but nothing states that a cancel ends the loop in every harness; not tried on a cluster |
| `perRunIdentity` | `session` | `docs/architecture/agent-identity-lookup.md` (one Actor JWT per Session; runs are not a runtime concept yet) |

No run-side methods exist yet.

## Runtimes: builtin and container (ADR 0015)

`spec.runtime.type` is `builtin` (default: the platform builds the agent from `instructions` on the catalog's runtime) or `container`
(the platform runs your digest-pinned image, which speaks A2A, as the agent). The core keeps one runtime adapter per type.

Catalog (all optional; an old catalog is `{builtin: adapters.runtime}`):

```json
"adapters": {"runtime": "kagent", "runtimes": {"builtin": "kagent", "container": "container"}, ...},
"runtime": {"container": {"namespace": "openagentix-workloads", "runtimeClassName": "", "gatewayNamespace": "...",
  "gatewayPodSelector": {"app": "..."}, "gatewayPort": 8080, "gateNamespace": "...", "gatePodSelector": {"app": "a2a-gate"},
  "dnsNamespace": "kube-system"}}
```

Policy (`allowedRuntimes` absent or empty means only `builtin`):

```json
"allowedRuntimes": ["builtin", "container"],
"runtimes": {"container": {"images": ["ghcr.io/acme/agents/"], "defaultResources": {"requests": {"cpu": "100m", "memory": "256Mi"},
  "limits": {"cpu": "500m", "memory": "512Mi"}}, "maxResources": {"cpu": "1", "memory": "1Gi"}, "maxAgents": 3}}
```

A container agent is refused (one sentence each, in `status.violations`) when: the runtime is not allowed or not offered; the image is not
`registry/path@sha256:<64 hex>` or not under a policy prefix; the port is outside 1024..65535; an env name is malformed, platform owned
(`OPENAGENTIX_`, `OPENAI_`, `OTEL_`, `KUBERNETES_`), too many (32), too big (4 KiB a value, 16 KiB in all) or a value looks like a secret;
resources are above `maxResources` or requests above limits; it sets `instructions`, `instructionsFrom`, `tools`,
`egress.allow`, `memory`, `knowledge`, `notify` or `skills`; or it names a `toolProfile` that is not defined, not allowed by
`allowedProfiles`, or not open to container agents.

Tools (ADR 0019): a container agent may name a `toolProfile` that the catalog opens to container agents (`tools.toolhive.profiles[].workload`,
from the chart value `controlPlane.containerAgents.toolProfiles`). The pod then gets `OPENAGENTIX_MCP_URL` (the profile's workload tool
server), `OPENAGENTIX_MCP_TOKEN_FILE=/var/run/secrets/openagentix/mcp/token` (a projected ServiceAccount token with the profile's
audience, one hour, written and refreshed by the kubelet; no Secret, and `automountServiceAccountToken` stays false), the pod label
`openagentix.io/tool-profile: <profile>`, and a third egress rule to that server's pods and port. The workload tool server admits only pod-bound tokens of the workload namespace, and the chart's
admission policies `openagentix-workload-tool-identity` and `-token-request` keep such tokens there to the controller's pods. `requireToolProfile` does not apply
to container agents: without a profile there are no tools. The agent gets every tool of the profile; `tools` stays refused.

What the controller writes, in the workload namespace: ServiceAccount, Deployment, Service, NetworkPolicy (same name as the agent; the pod,
selectors and policy use the label `openagentix.io/agent: <name>`), and the key Secret (created and deleted only, never read). Owner
references cannot cross namespaces, so these objects carry the labels `app.kubernetes.io/managed-by`, `openagentix.io/agent-definition`,
`openagentix.io/definition-namespace` and the annotation `openagentix.io/definition-uid`; the controller treats an object as its own only
when all four match, and removes them by label (union of every runtime's owned kinds) on delete, type switch and prune. The finalizer also
deletes the key Secret by name and removes the gate route; a failure keeps the finalizer. A type switch makes the key Secret in the new
namespace and deletes the old one by name.

The gate route list is the ConfigMap `a2a-gate-routes` (key `routes.json`, exactly `{"container":["ns/name",...]}`, sorted). A route is
listed after the objects are applied and before readiness (a failure is `Applied=False/ApplyFailed`, "route list: ..."), and removed on
delete, suspend and type switch; each pass ends by syncing it with the statuses.

RBAC (exactly): in the workload namespace `deployments`, `services`, `serviceaccounts`, `networkpolicies`: get, list, create, patch, delete;
`secrets`: create, delete only; in the gate namespace the ConfigMap `a2a-gate-routes`: get, patch.

`status.capabilities.isolation`: `sandbox-per-session` (builtin on Agent Substrate), `container` (container agent), `sandboxed-pod` (a container
agent when the catalog names a RuntimeClass); absent means unknown. Honest notes: a container agent shares the node kernel unless a
RuntimeClass is set; one long-lived process serves every conversation and has one identity; `/tmp` is an emptyDir; outbound traffic is
limited by NetworkPolicy only (DNS, the model gateway and, with a profile, its tool server), which kindnet does not enforce toward the internet; capabilities `approvals`,
`durableWaits` and `cancelStopsLoop` are `unknown`. Readiness comes from the Deployment status only (no Pod is read).

## Reserved labels

`openagentix.io/team`, `openagentix.io/project` and `openagentix.io/work-item` are reserved. They are **informational**: anyone who can write
the object can set them, so **no access, policy or billing decision ever reads them** (a test asserts that the policy's verdict is the same with
and without them). The controller validates `team` and `project` as Kubernetes label values (at most 63 characters, not secret-shaped) and copies
them from the definition onto every object it creates and into the gateway key entry's metadata (`{"user_id": ..., "team": ..., "project": ...}`),
so that cost metrics can carry them later. `work-item` is for products and is not copied.

## When a definition that runs is refused

Status records what is applied (`status.controller.appliedGeneration` and `appliedSpec`). When a definition that was accepted is refused later:

- **The author edited it** into something refused, and the previously applied spec still passes the current catalog and
  policy: that version keeps running. `Accepted=False` (reason `PolicyViolation`, violations listed), `Applied=True` with
  reason `PreviousGenerationRunning`, `Ready` read from the runtime for the running version; `endpoint`, `effectiveTools` and
  the rest keep describing what runs; the `Applied` and `Ready` conditions carry the running generation in their
  `observedGeneration`.
- **The catalog or the policy changed** (the spec is the one that was applied), **or** the author edited it and the
  previously applied spec no longer passes, **or** what was applied is unknown (a status written by an older controller):
  the agent's objects are removed (all owned kinds, as on delete) and its key hash is unregistered; the definition and its
  status stay. `Applied=False` reason `PolicyRemoved`, `Ready=False` reason `NotAccepted`, and `agentRef`, `endpoint`,
  `revision`, `effectiveTools`, `effectiveEgress` and everything under `status.controller` are cleared. The
  key Secret stays until the definition goes (its owner reference); when the definition is accepted again a new key replaces it.
- Nothing ran before: only the status changes.

While the author's edit stands refused and the previous generation runs, that generation is **rendered again against the current catalog
on every pass** (a new harness image, a new skill digest or a moved gateway reach it) with the key fingerprint of the running key, so what runs
does not go stale while `Applied=True`.

## Structure

```
cmd/control-plane          env, wiring, /healthz and /readyz, graceful shutdown
internal/api               AgentDefinition types, status contract, conditions and their reason table
internal/catalog           loads catalog.json and policy.json; the types of both, adapter-owned sections included
internal/policy            pure validation: definition + catalog + policy -> violations
internal/plan              definition + catalog -> Plan (final prompt, tools, skills, egress, memory, revision), no upstream words
internal/core              the loop; declares Runtime, ModelGateway, Kube; imports no adapter (a test enforces it)
internal/adapters/kagent        Runtime: Plan -> the kagent objects, readiness, endpoint, capabilities; derives its own names
internal/adapters/agentgateway  ModelGateway: entries in the ConfigMap llm-api-keys-control-plane
internal/adapters/toolhive      Tools: profile -> backend and tool names, read from the catalog; explains a missing tool
internal/keys              mint, hash, and the create/409 logic
internal/kube              REST client (get, list, watch, apply, merge patch, create, update, delete)
internal/kubetest          fake API server for tests
crd/agentdefinition.yaml   the CustomResourceDefinition
testdata/                  example catalog.json and policy.json, golden Helm output, regen-golden.sh
```

**The adapter boundary.** `plan`, `policy` and `api` name no upstream product (a test, `internal/core/vocabulary_test.go`, refuses the words
kagent, toolhive, vmcp, harness and ModelConfig in them outside comments that cite an ADR). The runtime adapter derives its own object names
from the definition's name (kagent: ModelConfig `gateway-<name>`, Harness `<name>-harness`, AgentTemplate `<name>-template`, EgressPolicy
`<name>-egress`, Agent `<name>`) and the data key of the key Secret; the gateway adapter derives the user id's use; the tools adapter says
what a profile offers and why a tool is missing (the code-mode tool's name is catalog data). What only one adapter needs is in that
adapter's section of the catalog (`runtime.kagent`, `tools.toolhive`). One thing is still kagent-shaped on purpose: the key lives in a
Kubernetes Secret named with the UID, which is a core rule.

The `Runtime` adapter produces the same objects as `charts/openagentix/templates/kagent.yaml`; the parity tests
(`internal/adapters/kagent`) compare them field by field with `helm template` output for two demo agents (`profile-demo`,
`assistant`). The ignored paths are the four Helm-only labels, listed in the test; the one name that differs is the chart's hand-set
ModelConfig name of `assistant`, replaced in the golden before the comparison. `testdata/regen-golden.sh` regenerates the golden files
(needs helm, yq, jq).

## Settings (environment)

| Variable | Default | Meaning |
|---|---|---|
| `CONTROL_PLANE_CATALOG_FILE` | required | path of the catalog JSON |
| `CONTROL_PLANE_POLICY_FILE` | required | path of the policy JSON |
| `CONTROL_PLANE_HEALTH_ADDR` | `:8081` | listen address of `/healthz` (always 200) and `/readyz` (200 after the first full pass) |
| `CONTROL_PLANE_RESYNC` | `60s` | longest time between full passes (at least 1 s) |
| `CONTROL_PLANE_BACKOFF` | `10s` | per-definition retry delay while it is not finished (key or apply failed, runtime not ready); doubles on failures up to 30 times |
| `CONTROL_PLANE_MIN_INTERVAL` | `1s` | shortest time between the starts of two passes, however many events arrive (new, optional; at least 1 ms) |
| `CONTROL_PLANE_MIN_RECREATE_INTERVAL` | `2m` | shortest time between two creations of one definition's runtime agent: a suspend and resume loop waits (`ResumeDelayed`) instead of thrashing snapshots (at least 1 s) |
| `CONTROL_PLANE_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |

It uses the pod's ServiceAccount token (read again on every request) and CA. The catalog and the policy are read once at
start; the chart rolls the pod when either changes (checksum annotation). Only the namespace `namespaces.agents` of the
catalog is listed and watched; every rule and name is still per namespace.

Logs are JSON on stderr: agent name, object names, outcome. A log line, a condition message or an error never contains a
key, and never an API error body: errors carry the HTTP status and the API's reason word only.

## The catalog (`CONTROL_PLANE_CATALOG_FILE`)

What exists on the platform. The chart renders it from the same values that render chart agents. No secret in it. Unknown
fields are refused. `testdata/catalog.json` is a full example for the demo values. The top level is platform-level; what only one
adapter needs is in that adapter's own section, `runtime.<adapter>` and `tools.<adapter>`, and the section of the adapter named in
`adapters` must be there.

| Field | Type | Meaning |
|---|---|---|
| `adapters.runtime` | string | active runtime adapter; this build supports `kagent` |
| `adapters.modelGateway` | string | active gateway adapter; `agentgateway` |
| `adapters.tools` | string | active tools adapter; `toolhive` |
| `namespaces.agents` | string | the namespace listed and watched, and where the chart's agents live (`kagent.namespace`); the memory model config is read there |
| `namespaces.gateway` | string | namespace of the gateway, where `llm-api-keys-control-plane` lives |
| `namespaces.tools` | string | the tool servers' namespace (`mcp.namespace`); an egress origin inside it is refused, and it can never be listed in `inClusterDestinations` (nor can a name in the agents namespace, the gateway namespace, `kube-system`, or the Kubernetes API service `kubernetes.default`) |
| `gatewayBaseUrl` | string | the gateway's OpenAI base URL an agent's model config points at (as `oa.gatewayBaseUrl`) |
| `models` | [string] | gateway model names (`gateway.models[].name`) |
| `knowledge.available` | bool | `knowledge.enabled` and `mcp.enabled` |
| `knowledge.tools` | [string] | the tools `knowledge.enabled` adds (`oa.knowledgeTools`: three, six with the graph) |
| `knowledge.prompt` | string | the addition to the system prompt, tool names already substituted (`oa.knowledgeAgentPrompt`) |
| `notify.available` | bool | `notify.enabled` and `mcp.enabled` |
| `notify.tools` / `notify.prompt` | | as above (`oa.notifyTools`, `oa.notifyAgentPrompt`) |
| `memory.available` | bool | the memory stack is installed |
| `memory.expiryEnabled` | bool | `memory.expiry.enabled`: the job that enforces the time limit |
| `memory.defaultTtlDays` | int | the runtime's default when a definition sets no `ttlDays` (kagent: 15) |
| `memory.prompt` | string | addition to the system prompt (`memory.agentPrompt`) |
| `skills` | map name -> ref | skill name to OCI ref; the ref must end in `@sha256:<64 hex>` (the file is refused otherwise); the digest is the one version a definition may name |
| `gateUrl` | string | base URL of the A2A gate (`oa.a2aGateUrl`); empty when the gate is off (then no definition has an `endpoint`) |
| `reservedNames` | [string] | names taken in the agents namespace by every chart agent plus `kb`, `kb-extract`, `memory` |
| `runtime.kagent.harnessImage`, `.workerPool`, `.snapshotLocation` | string | `kagent.harnessImage`, `kagent.workerPool`, `kagent.snapshotLocation` |
| `runtime.kagent.harnessEnv[]` | list of `{name, value}` | environment of the harness: `OTEL_PROPAGATORS` when observability and baggage are on, else `[]` |
| `runtime.kagent.memoryModelConfig` | string | name of the shared embedding model config (`memory.modelConfig.name`) |
| `tools.toolhive.codeModeTool` | string | the name of the code-mode tool (`execute_tool_script`) |
| `tools.toolhive.profiles[]` | list | tool profiles (`mcp.profiles`): `name`, `toolServer` (name of the profile's server object, `<remoteMCPServer.name>-<profile>`), `codeMode`, `tools` (agent-side names, as the chart's `oa.profileToolNames`; the code-mode tool last when `codeMode`), and `workload` only for a profile open to container agents (ADR 0019): `url`, `audience`, `namespace` (must be `namespaces.tools`), `podSelector`, `port` |

Derived names (not in the file; the kagent adapter's): ModelConfig `gateway-<name>`, Harness `<name>-harness`, AgentTemplate `<name>-template`,
EgressPolicy `<name>-egress`, Agent `<name>`, all in the definition's namespace; Secret `<name>-virtual-key-<8 hex of the UID>` (at most 40 + 13
+ 8 characters; the UID is a UUID, dashes removed, first 8 characters); gateway user `<namespace>.<name>`.

## The policy (`CONTROL_PLANE_POLICY_FILE`)

What the operator allows (chart values `controlPlane.policy`). An allow-list that is empty allows nothing; the single entry
`"*"` allows everything the catalog has. `testdata/policy.json` is an example.

| Field | Type | Meaning |
|---|---|---|
| `maxAgents` | int >= 0 | number of accepted definitions **per namespace**; those already accepted keep their place, then the oldest; the rest are refused |
| `allowedModels` | [string] | models a definition may name |
| `requireToolProfile` | bool | every definition must name a `toolProfile` |
| `allowedProfiles` | [string] | tool profiles a definition may name |
| `allowKnowledge` | bool | `knowledge.enabled: true` is allowed |
| `allowNotify` | bool | `notify.enabled: true` is allowed |
| `allowedSkills` | [string] | skills a definition may name |
| `memory.allowed` | bool | `memory.enabled` is allowed |
| `memory.maxTtlDays` | int >= 1 when memory is allowed | largest `ttlDays` (the catalog default counts when none is set) |
| `memory.requireExpiry` | bool | refuse memory while `catalog.memory.expiryEnabled` is false |
| `egress.allowedOrigins` | [string] | origins (`https://host[:port]`); a host may start with one `*.`, which stands for exactly one label. A definition's origin must equal an entry or match a wildcard entry (scheme and port must be equal). A wildcard origin in a definition matches only an identical entry. Empty: no egress |
| `egress.inClusterDestinations` | [string] | default empty. Exact `host:port` entries: the one exception to the rule that refuses every in-cluster destination. Each is a namespace-qualified service (`registry.ci.svc:5000`, `db.data.svc.cluster.local:5432`, `svc.ns:80`) and a numeric port: no scheme, no wildcard, no address, no entry twice, and **never** a name inside the tools, agents or gateway namespace, `kube-system`, or the Kubernetes API service (`kubernetes.default`, `.svc`, `.svc.cluster.local`): the controller refuses to start and the chart refuses to render. The platform admission guard refuses these hosts even if they were listed. An origin is allowed when its host and port (the scheme's default port when it names none) are exactly an entry, whatever scheme; the platform admission guard's EgressPolicy rule allows exactly these and nothing else in the cluster. kagent needs full DNS names in its egress policies (its docs), so use the `.svc` forms |
| `reservedNames` | [string] | more reserved names: `name` in every namespace, `namespace/name` in one (the catalog's names are reserved in the agents namespace) |
| `suspendAll` | bool | the operator's stop switch: every definition is treated as suspended |

## Refusals

Each is one sentence in `status.violations`, with `Accepted=False` (reason `PolicyViolation`):

- name not a DNS label, longer than 40, reserved in its namespace (catalog or policy), or more definitions than `maxAgents` in its namespace;
- `team` or `project` label that is not a valid label value, or shaped like a secret;
- description over 256 characters; neither or both of `instructions` and `instructionsFrom`; `instructionsFrom` at all ("not available yet");
  instructions over 16384 bytes; instructions, description, model, toolProfile, tools, skills (name and version), knowledge collections, notify
  destinations or egress entries shaped like a secret (the ten patterns of `charts/openagentix/files/memory-expiry.sh`, same names,
  plus `platform_virtual_key`, `vk-` and 32 hex characters; the sentence names the pattern, never the text, and any other
  sentence that quotes a value has secret-shaped parts replaced by `[redacted]`);
- a model not in the catalog or not allowed; a profile not in the catalog or not allowed; a skill not in the catalog or not allowed, or a skill
  version the catalog does not offer;
- tools without a `toolProfile` (the shared tool server filters on the client side only), no profile when the policy requires
  one, a tool the profile does not offer (the tools adapter words it, including its code-mode case), a tool listed twice;
- `knowledge.enabled` or `notify.enabled` when the policy does not allow it, when the service is off, **without a profile**, or when the profile
  does not offer their tools; `knowledge.collections` or `notify.destinations` non-empty ("selecting ... is not available yet");
- memory when the policy does not allow it, the stack is not installed, the expiry job is off (with `requireExpiry`), or `ttlDays` is above the maximum or below 1;
- an egress origin that is malformed (an origin is `https://host[:port]` or `http://host[:port]`, a lower case DNS name, one leading `*.` label
  allowed, no path, no user, no address), listed twice, not matched by the policy, or more than 64 origins; and, whatever the policy patterns say:
  - **never allowed, listed or not:** a host inside the tools, agents or gateway namespace or `kube-system`, or the Kubernetes API service. A host
    is *inside* a namespace `ns` only when it ends with `.ns`, `.ns.svc` or `.ns.svc.cluster.local`: `docs.kagent.dev` is a public name, `x.kagent` is not;
  - **allowed only when the operator lists exactly its `host:port`** in `egress.inClusterDestinations`: a name that is not public from the
    cluster's point of view: an IP address, a name without a dot, a name with a `.svc.` label, and a name whose **last label** is `internal`,
    `local`, `localhost`, `svc`, `cluster`, `lan`, `home`, `corp`, `test`, `invalid` or `example` (`metadata.google.internal`, `printer.local`,
    `wiki.corp`). The last-label list is small on purpose: whether `foo.bar` is a real TLD cannot be known offline. `example.org`, `example.com`
    and `example.net` are real names and stay allowed.
  The Go check and the admission guard's CEL implement these rules identically; one table of cases (`testdata/egress-hosts.json`) drives both tests.
  **Not handled here:** DNS rebinding. An allowed public name can resolve to an address inside the cluster or in a private range at connection time;
  a name-based rule cannot see that, and it needs enforcement at the egress proxy (resolve, then refuse private and link-local addresses).

## RBAC it needs

Namespaced Roles only, no ClusterRole, no wildcard (rendered by the chart):

| Namespace | Resource | Verbs |
|---|---|---|
| agents (the catalog's `namespaces.agents`) | `agentdefinitions` | get, list, watch, update |
| agents | `agentdefinitions/status` | patch |
| agents | `modelconfigs`, `harnesses`, `agenttemplates`, `egresspolicies`, `agents` (`api.kagent.dev`) | get, list, create, patch, delete (never `watch`: it only ever watches definitions) |
| agents | `secrets` | **create, delete** only |
| gateway | `configmaps`, resourceName `llm-api-keys-control-plane` | get, patch |

`update` on definitions is the finalizer (a full PUT); `patch` on the kagent kinds is server-side apply; `get` and `list` on them are the name check
and the pruning by label. On the key ConfigMap it only reads and patches single entries (no `update`, `create` or `delete`). It creates no
Events (it has no `events` right): the conditions are the record.

## The output guard

What even a compromised controller can write is limited by **eight ValidatingAdmissionPolicies** (`charts/openagentix/templates/control-plane-guard.yaml`),
each with its own `Deny` binding, `failurePolicy: Fail`, evaluated for the controller's ServiceAccount only. It is an **allowlist of keys at every level**,
derived from what the kagent adapter writes (`internal/adapters/kagent`, the golden files): a key the adapter does not set is refused, whatever its value.

| Policy | Allowed (everything else is refused) |
|---|---|
| `guard-secrets` | create and delete only, in the agents namespace. Create: name `<agent>-virtual-key-<8 hex>`, labels exactly managed-by and agent-definition, one owner reference, `immutable`, `Opaque`, the one data key `OPENAI_API_KEY`, annotation `openagentix.io/key-fingerprint` only. Delete: only a Secret with that name and both labels |
| `guard-configmaps` | update of `llm-api-keys-control-plane` at the gateway only. Labels, annotations, owner references and finalizers unchanged, no `binaryData`. Entries: key `<agents namespace>.<name>`, value exactly `{"keyHash":"sha256:<64 hex>","metadata":{"user_id":<its key>[,"team":..][,"project":..]}}`. An entry that is already there and unchanged (the previous format) is kept as it is; a new or changed one must have that shape |
| `guard-modelconfigs` | `spec.{provider, model, apiKeySecret, apiKeySecretKey, stream, openAI.{baseUrl, apiFormat}}`; provider `OpenAI`, `model` one of the catalog's models, the gateway URL, `stream` false, `apiFormat` the CRD default, the agent's own `<agent>-virtual-key-<8 hex>` Secret. **Not:** `defaultHeaders`, `tls`, `actorJwt`, `tokenPassthrough`, `allowedNamespaces`, another provider block |
| `guard-harnesses` | `spec.{kagent.memory.{modelConfigRef.{name, namespace}, ttlDays}, workload.image, substrate.{workerPoolRef.name, snapshotPolicy.location}, env[].{name, value}}`; the catalog's image, worker pool, snapshot location and env; memory only when the policy allows it, only on the catalog's memory ModelConfig in the agents namespace, `ttlDays` within the policy maximum. **Not:** `workload.command` or `args`, `byo`, `claude`, `codex`, `kagent.compaction` (its summarizer names a ModelConfig) |
| `guard-agenttemplates` | `spec.{description, systemPrompt, modelConfig.name, tools[].mcp.{server.{kind, name}, tools}, skills[].{name, source.oci}}`; `modelConfig.name` `gateway-<agent>`; each tool entry a `RemoteMCPServer` of a profile, its `tools` a **subset of that profile's tools** (never absent); skills only the catalog's digest-pinned references. **Not:** `plugins`, `promptTemplate`, `systemPromptFrom`, `outputSchema`, `outputSchemaFrom`, a namespace or apiGroup on a reference, `requireApproval`, `subAgent` tools |
| `guard-egresspolicies` | `spec.destinations[].origin` **only**. **Not `authentication`** (the egress gateway sends the value of the Secret it names as a header to the origin: a compromised controller could send any Secret of the namespace to an outside host) and no other key. The origin has the accepted shape and passes the host rules of "Refusals" |
| `guard-agents` | `spec.{template.ref.name, harnessRef.name, egressPolicyRefs[].name}`, all derived from the agent's own name (at most one egress ref). **Not:** an inline template, a namespace on a reference |
| `guard-other` | the last rule: **any other resource, verb or subresource** the ServiceAccount reaches is refused (its RBAC says the same; this holds even if a Role is widened). Its own definitions' finalizer (`UPDATE`) and status are excluded |

On the five kagent kinds there are three more rules: the object is in the agents namespace, carries both labels and an `AgentDefinition` owner reference with `controller: true`
(on the new object and, for update and delete, on the one that exists, with the same definition), the definition name is a DNS label of at most 40 characters; and metadata has
only the keys the API server adds plus the controller's labels (and the reserved `team` and `project`, as label values) and the annotation the adapter sets on that kind (`openagentix.io/agent` on a
ModelConfig, `openagentix.io/key-fingerprint` on a Harness and an Agent, none on the others). `status`, `finalizers` and `managedFields` may be there: the API server and kagent add them.
If kagent starts to add an annotation of its own to its objects, the apply of that object is refused until the guard lists it: the apiserver test would not see it (it has no kagent controller), so
check `kubectl get oad` after a kagent upgrade.

**Tests that run it.** `make test-guard` (`hack/ci/guardtest`, its own Go module with the Kubernetes admission CEL code) renders the chart with the demo values and evaluates the rendered
policies over about 400 cases made from the golden files: every kind and verb the controller writes is allowed, and one refusal per field of the security review, per rule family and for
foreign objects and Secrets is refused (by a rule, not by an evaluation error). `make test-apiserver` (`hack/ci/apiserver-test.sh`) applies the CRD and the policies to a real API server in a
throwaway kind cluster, checks `status.typeChecking` (no warning), applies the example definition and invalid ones, and runs impersonated writes against the guard. Both run in CI.

## What it never does

- Read, list or watch a Secret; print, log, put into status or return a key (the key is in the body of one `POST`).
- Touch the installer's ConfigMap `llm-api-keys`, a chart agent's objects, or any object it does not own (it stops on a name conflict).
- Write outside the agents namespace and the one gateway ConfigMap; use a ClusterRole.
- Accept a field that names a model config, image, tool server, egress policy, namespace, caller, gateway user or budget (the CRD has none).
- Write gate rules: nobody may call a built agent until an operator adds a caller rule.
- Copy an API error message into a log line or a condition.
- Delete an agent just because an edit was refused: it removes one only when the previously applied spec itself no longer passes (see above).

## Upgrading from the first shape (before ADR 0012)

Nothing was released with the first shape, so the CRD changed in place (still `v1alpha1`, no conversion). On a cluster that runs the previous controller:

1. Build and load the new image and apply the new chart (`./install.sh` does both); the CRD is part of the release and is replaced by `helm upgrade`
   (a CRD is applied by the chart's template, not by Helm's `crds/` rules, so it is updated).
2. A stored definition keeps its old `status` fields until the controller writes them again; the API server prunes fields the new schema does not
   know. `spec` that only uses fields whose shape did not change (no `knowledge`, `notify`, `skills`) is read as it is. A stored `knowledge: true`,
   `notify: true` or `skills: [name]` no longer decodes: that definition is skipped and logged until it is edited to the new shape.
3. The new controller does not know the previous one's bookkeeping (it was at the top level of `status`) and finds the key's hash under the old
   entry name. With no entry under the new name it tries to create the key Secret: if the Secret exists (`409`, the usual case: its name is the same),
   the old hash is moved to the entry `<namespace>.<name>` and **the key is not replaced**; if it does not exist, a new key is made. Either way the old
   entry `researcher` is swept at the end of the pass and `status.controller` is filled again. No rollout is expected unless the Secret was missing.

## Tests

`make test` (`go test ./... -race -count=1`). They need nothing but Go (the CRD test also uses `yq` and skips without it):
the Kubernetes API is `internal/kubetest`, a fake that records every request so tests can assert what was sent and what was not. It paginates (`limit`/`continue`) and models server-side apply for the fields a client sends (a field no longer sent is removed); it does not model several field managers, conflicts, list merge keys or defaulting.

- policy: one case per refusal, and accepted cases; labels never change a verdict; the example definition in `components/control-plane/` is accepted and strictly decodable;
- plan: the revision is stable across list orders and changes with what was applied; the user id is `<namespace>.<name>`;
- kube and core: list and watch resume, 410 Gone (HTTP and event form) and re-list, server-side apply bodies, status patch, finalizer, pruning, name conflicts, serialized reconciles, per-namespace rules (a second namespace), suspend and the stop switch, the status contract, and a scan of `core.go` that fails when the code sets a condition reason that is not in the table;
- keys: 201, 409 with the hash present, 409 without, a restored older hash, no request when the key is in order, label-only changes, never a GET on Secrets;
- suspend and resume: the key entry is cut and comes back as the same hash, no key is minted, resume inside the interval waits (`ResumeDelayed`), the stop switch cuts every key; `maxAgents` holds a place for a running definition whose edit is refused; the previous generation is rendered again against the current catalog; a label change starts a pass; the sweep leaves another namespace's entries alone; the CRD's metadata schema is exactly `{type: object}` and the instruction limit is in bytes;
- egress hosts: one table (`testdata/egress-hosts.json`) drives the Go check and the guard's CEL test, so the two cannot disagree;
- canary: a planted key value appears in no log line, status, error string or request body except the one Secret create, over several passes, also with the real adapters (`cmd/control-plane`);
- parity with `helm template` (golden files); the core imports no adapter package; `plan`, `policy` and `api` hold no upstream vocabulary; the README's reason table matches the code.

`make docker` builds the image (distroless, non-root, port 8081 for the probes).

## Known limits

- Suspend is a stop (kagent has no pause field): conversations end and a resume is a new Agent identity for new sessions (see "Suspend").
- DNS rebinding of an allowed public egress name is not handled by the policy or the guard; it needs enforcement at the egress proxy.
- `cancelStopsLoop` is `unknown`; there are no run-side methods yet (`AgentRun` is reserved by ADR 0012).
- The admission guard is an allowlist of keys at every level (see "The output guard"). A key the adapter does not write is refused, so a new kagent
  field the adapter starts to write needs the guard changed in the same change; the guard test (`make test-guard`) and the API-server test
  (`make test-apiserver`) say so.
