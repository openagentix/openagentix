# ADR 0016: AgentAccess, the A2A gate's caller rules as a resource

Status: Proposed
Date: 2026-11-25
Issue: #3
Replaces: none. Fills in the `AgentAccess` entry that ADR 0012 reserved for release 0.3. Changes one line of `services/control-plane/README.md` ("What it never does": write gate rules), see "Amendments".

A new namespaced kind, `AgentAccess` (`openagentix.io/v1alpha1`), says that one caller identity may call some agents of the same namespace, with which user ids and which A2A methods. The controller checks it against policy and writes the accepted rules into a ConfigMap that the A2A gate reloads. It is off by default. Nothing here is built yet; everything is *unverified* until the slices below are done.

## Context

Today the A2A gate's caller rules are chart values. Facts read in this repository on 2026-11-25:

- The gate reads one rules file, `A2A_GATE_RULES`, once at start (`services/a2a-gate/cmd/a2a-gate/main.go`, `rules.Load`). A rule is a caller name, one identity (a ServiceAccount, or a static key whose hash is in a mounted Secret), a list of agents (`namespace/name`), a user id rule (exactly one of `exact`, `prefix`, `fixed`), optional `methods` (default `SendMessage`, `SendStreamingMessage`) and optional `memory` (`services/a2a-gate/internal/rules/rules.go`). Unknown fields are refused. One ServiceAccount belongs to at most one caller.
- The chart builds that file from the bridge, each schedule, each Kourier binding and `governance.a2a.callers[]` (helper `oa.a2aRules` in `charts/openagentix/templates/_helpers.tpl`), puts it in the ConfigMap `a2a-gate-rules`, and rolls the gate pod when it changes (`checksum/rules` in `charts/openagentix/templates/governance.yaml`).
- A caller must also pass the gate's NetworkPolicy. Extra callers are admitted by `networkPolicy.extraA2ACallers`, and the render fails when such a namespace has no matching caller rule.
- Authentication is a TokenReview of a projected token with the audience `openagentix-a2a` (positive answer cached 30 s, by token) or a static key. The cache holds the identity, not the rule: the rule is looked up on every request (`services/a2a-gate/internal/auth/auth.go`).
- ADR 0015 added a second, controller-written file to the gate: the route list `a2a-gate-routes` / `routes.json`. It is mounted as a directory, checked every 10 s and swapped atomically. The controller patches it through a Role limited to that one ConfigMap, and an admission policy limits the content to a strict pattern (`charts/openagentix/templates/control-plane-guard-workload.yaml`).
- The control plane README lists "write gate rules" under "What it never does": "nobody may call a built agent until an operator adds a caller rule". Adding a caller today means a `helm upgrade` and a gate restart.
- ADR 0012 reserved `AgentAccess` for 0.3 with four parts: callers, agents, the user id rule, the allowed methods. `Schedule` (issue #4) needs it, and a product's controller becomes a caller with the task methods. `docs/diary/reference/reserved-kinds.md` says a schedule without an access rule fails with a clear condition.

The problem: a team that builds an agent with `AgentDefinition` cannot let anything call it without asking the operator for a chart change and a gate restart. A product cannot grant its own controller access as part of its install.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `AgentAccess` kind; the controller validates and writes a second gate file, `a2a-gate-access` | One writer that applies policy, status per rule, the gate stays a file reader with no new API rights, same proven mechanism as the route list | Reload delay of the kubelet volume refresh (about a minute, *unverified*); a second file format to keep strict | Read the gate, the route list code and guard, and the chart, on `main` |
| B. `AgentAccess` kind; the gate watches the resources itself | Revocation in seconds; no intermediate file | The gate gets list and watch on a CRD and its own API client (it is standard library only), duplicates the policy checks, has no place to write status, and a request path that depends on the API server | Same reading; compared with how the gate calls TokenReview |
| C. `spec.access` inside `AgentDefinition` | No new kind | The person who builds an agent also decides who calls it; Kubernetes RBAC cannot separate the two. Chart agents and container agents are covered only through a definition | ADR 0012's reason for a separate `ApprovalRequest` kind applies here too |
| D. The controller writes into the chart's `a2a-gate-rules` | One file | Helm owns that ConfigMap and would overwrite it on every upgrade; chart rules and resource rules mix | `governance.yaml` renders the whole file |
| E. Do nothing, keep chart values | Nothing to build | Every new caller needs an operator and a gate restart; `Schedule` and products are blocked | Not applicable |

## Decision

Option A.

### The resource

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentAccess
metadata:
  name: ci-smoke
  namespace: kagent            # the agents namespace; the rule covers agents of this namespace only
spec:
  caller:                      # exactly one identity source
    serviceAccount: {namespace: ci, name: smoke}
  agents:                      # 1..64, names of agents in this namespace
    - name: assistant
  userId:                      # exactly one of exact, prefix, fixed
    exact: "ci:smoke"
  methods: [SendMessage]       # optional; default [SendMessage, SendStreamingMessage]
status:
  observedGeneration: 1
  conditions: []               # Accepted, Ready, Synced
  caller: "serviceaccount:ci/smoke"
  agents: ["kagent/assistant"]
  methods: ["SendMessage"]
  violations: []
  controller: {}               # private
```

Short name `oaa`. `kubectl get oaa` shows Caller, Agents, Accepted, Ready and Age.

**One caller per object.** ADR 0012 wrote "callers" in the plural. One identity per object keeps conflicts, status and removal simple: deleting the object removes exactly that caller's access. A caller that needs different user id rules for different agents uses two objects.

**Scope.** An `AgentAccess` grants access only to agents in its own namespace. The caller may live in another namespace. This is the Kubernetes rule for RoleBindings: whoever controls the agents' namespace decides who calls them, and a team in one namespace cannot grant itself access to another's agents. In 0.3 the controller serves one agents namespace (ADR 0012, change 2); an `AgentAccess` elsewhere is ignored and gets no status. Agents are named, not selected. Any agent of the namespace counts: an `AgentDefinition`, a container agent or a chart agent. A grant for a name with no agent yet is published; it takes effect when the agent exists.

**Fields.**

| Field | Rule |
|---|---|
| `caller.serviceAccount.{namespace, name}` | Required in 0.3. DNS label and DNS subdomain. The namespace must be in the policy's `access.callerNamespaces`. A later identity source (the identity adapter of ADR 0013, release 0.4) is a new member of `caller`, exactly one set, so adding it does not break anyone. Static keys are not offered: they live in a Secret, and the controller never reads Secrets |
| `agents[].name` | 1 to 64 entries, DNS labels, no duplicates. A list of objects so that a selector or a version can follow |
| `userId.exact` | The caller may send this value or none; the gate fills it in |
| `userId.prefix` | The caller must send a value that starts with it and has more after it. The prefix must end with `:` |
| `userId.fixed` | The gate always sets this value and ignores what the caller sends |
| user id values | 1 to 128 characters from `A-Z a-z 0-9 . _ : @ + -`. Narrower than the gate's current rule (any printable text) so that the guard can match the published file with a plain pattern |
| `methods` | Optional, 1 to 16 distinct entries from the policy's `access.allowedMethods`. Absent means `SendMessage`, `SendStreamingMessage` |

Not in the kind: `memory` (the two kagent MemoryService calls of ADR 0006 round 3 are an upstream API, and only the bridge needs them; they stay a chart-only caller option), push notification configuration methods (they make the runtime call a URL the caller chooses; refused until reviewed), any URL, host, header or key.

**Defaults are the narrowest.** The API server prunes unknown fields. A misspelt `methods` falls back to the two send methods; a misspelt `userId` or `caller` fails the schema. A typo can make a rule narrower, never wider.

### Status

Public fields follow `docs/api-conventions.md`: `conditions`, `observedGeneration`, `caller` (the identity as the gate will match it, `serviceaccount:<ns>/<name>`, an opaque string), `agents` and `methods` as published, `violations` (one sentence per refused rule). `status.controller` holds the hash of the access list that was last written, and may change without notice.

`Ready=True` means: **this rule is in the gate's access list as written for `status.observedGeneration`**. It does not mean the gate has already loaded it. The gate checks the file every 10 s, after the kubelet has refreshed the mounted ConfigMap, which can take about a minute (*unverified*, measured in slice 2). A client that needs certainty polls the agent.

| Condition | Reason | Status | Meaning |
|---|---|---|---|
| `Accepted` | `Accepted` | True | the rule passes the policy and conflicts with no other rule |
| `Accepted` | `PolicyViolation` | False | one or more policy rules refused it; each is in `status.violations` |
| `Accepted` | `Conflict` | False | another accepted rule, or a chart caller, already holds this identity for one of these agents, or its user id space overlaps another caller's; the message names the other rule |
| `Accepted` | `LimitReached` | False | `access.maxGrants` accepted rules exist; older rules keep their place |
| `Ready` | `Ready` | True | the rule is in the published access list |
| `Ready` | `NotAccepted` | False | the rule is refused; it is not in the list (and was removed if it was there) |
| `Ready` | `PublishFailed` | False | writing the access list failed; the gate keeps the previous list. The message says why, never with an API error text |
| `Synced` | `Synced` | True | the last pass could read everything it needed |
| `Synced` | `TransientError` | False | a read failed; the other conditions are the last known state |

The same contract tests as for `AgentDefinition` apply: a test fails when the code sets a reason that is not in this table.

### Policy and chart values

Chart switch `controlPlane.agentAccess.enabled`, default `false`. It needs `controlPlane.enabled` and `governance.a2a.enabled`; the render fails otherwise. With it off, the chart renders exactly what it renders today, for the default values and for the control plane demo values: no CRD, no ConfigMap, no Role, no guard policy, no gate environment variable, no NetworkPolicy peer, no new policy keys.

Policy keys (chart values under `controlPlane.policy.access`, written into the existing policy ConfigMap):

| Key | Default | Meaning |
|---|---|---|
| `callerNamespaces` | `[]` | namespaces whose ServiceAccounts a rule may name. Empty: every rule is refused. Deny by default. The render fails for the agents, gateway, gate, workload, control plane and tools namespaces and `kube-system` |
| `allowedMethods` | `[SendMessage, SendStreamingMessage, GetTask, CancelTask, SubscribeToTask]` | the methods a rule may list. The chart refuses a name outside the A2A 1.0 method set it knows, and always refuses the push notification configuration methods |
| `maxGrants` | `100` | accepted rules in the namespace; the oldest keep their place |

Derived by the chart, not set by users: `access.reserved.serviceAccounts` (the bridge's, each schedule's and each `governance.a2a.callers[]` ServiceAccount) and `access.reserved.userIds` (the bridge prefix, each `schedule:<name>`, each `kourier:<name>`, and each chart caller's user id rule). A rule that names a reserved ServiceAccount or whose user id space overlaps a reserved one is refused with `Conflict`.

The same `callerNamespaces` list adds namespace peers to the gate's ingress NetworkPolicy, so one value admits a namespace at the network and at the policy. The chart's check that every `extraA2ACallers` namespace has a chart rule accepts a namespace in `callerNamespaces` too.

### How the rules reach the gate

The controller never reads a Secret and the gate gets no new API rights.

1. The controller lists and watches `AgentAccess` in the agents namespace (new: today it watches only definitions).
2. On every change, and on a resync, it computes the full access list from the accepted rules: a pure function of the current objects, the policy and the reserved lists. A removed or refused rule is simply absent. There is no finalizer; deletion needs no extra step.
3. It writes the list to the ConfigMap `a2a-gate-access` in the gate namespace, one key, `access.json`, in one canonical form: compact JSON, sorted, no duplicates.

   ```json
   {"grants":[{"access":"kagent/ci-smoke","agent":"kagent/assistant","caller":"serviceaccount:ci/smoke","methods":["SendMessage"],"userId":{"exact":"ci:smoke"}}]}
   ```

   One entry per (caller, agent) pair. No URL, host, key or secret. The members are fixed and in this order.
4. The chart renders the ConfigMap once with `{"grants":[]}`. It is **not** kept on uninstall (unlike the route list): a re-install must start with no grants and wait for the controller, never with a stale list. Helm's three-way merge leaves the controller's content alone on upgrade while the chart's start value does not change (the same open point as the route list in ADR 0015).
5. The gate gets `A2A_GATE_ACCESS_FILE`, set by the chart only when the switch is on, and mounts the ConfigMap as a directory (not `subPath`). It checks the file every 10 s and swaps it atomically, as for routes.

**Fail closed, revocation first.** This differs from the route list on purpose. A malformed route list keeps the last good one, because an old route list can only send a listed agent to the workload namespace. An old access list can keep a revoked grant alive. So:

- Missing or malformed at start: the gate starts with no resource grants. Chart callers work as before.
- A malformed update: the gate drops all resource grants, logs one line with the reason (never the file content), and keeps chart callers. A later valid file restores them.
- A valid file that no longer names a grant removes it at the next check.

Parsing is strict: unknown or repeated members, a wrong type, two entries for one (caller, agent), a method outside the gate's known list, more than 2000 entries, a file over 256 KiB, or data after the object reject the whole file.

### How the gate decides

The gate's lookup changes from "one rule per identity" to "one rule per identity and agent". For each request, after authentication:

1. A static key matches a chart rule only, as today.
2. A ServiceAccount that a chart rule names uses that chart rule only. Resource grants for the same identity are ignored (the controller already refuses them; the gate checks again).
3. Otherwise the gate looks up the grant for (identity, agent). None for this identity: 403 `unknown_caller`. None for this agent: 403 `agent`. Then the method and user id checks run exactly as today.

There is no "first match wins": at most one rule can apply to an (identity, agent) pair, so the order of objects never changes a verdict. The controller makes that true and the gate refuses a file where it is not.

The audit line keeps its fields. For a resource grant, `caller` is `serviceaccount:<ns>/<name>` and a new field `access` holds `<namespace>/<name>` of the `AgentAccess`. Adding a field to the audit line is additive. The line still never holds message text, the body, a token or a key, and the user id stays a salted hash unless the operator chose `raw`.

### Admission guard (what even a compromised controller can write)

New allowlist policies, bound to the controller's ServiceAccount, `failurePolicy: Fail`, executed in `make test-guard` and `make test-apiserver`:

- **The access list.** Update only, only `a2a-gate-access` in the gate namespace, only `data` with the one key `access.json`, labels, annotations and owner references unchanged, size at most 256 KiB, and the content matches one pattern built from the canonical form above. The pattern is rendered with the operator's values literally: the agents namespace, the allowed caller namespaces, the allowed methods. So a compromised controller can grant only ServiceAccounts of namespaces the operator allowed, only to agents of the agents namespace, only with allowed methods, and never memory, never push notification configuration, never a URL.
- **AgentAccess status.** The controller may patch `agentaccesses/status` and nothing else of the kind: no create, update or delete, no finalizer. `guard-other` keeps refusing everything not listed.

What the guard cannot check: that a grant matches an existing `AgentAccess` (the guard cannot see other objects), or that reserved identities and overlapping user ids are left out. A compromised controller can therefore grant any allowed-namespace ServiceAccount any agent of the namespace with allowed methods. That is the remaining blast radius and it is bounded by the operator's own lists.

RBAC added for the controller, namespaced only:

| Namespace | Resource | Verbs |
|---|---|---|
| agents | `agentaccesses` | get, list, watch |
| agents | `agentaccesses/status` | patch |
| gate | `configmaps`, resource name `a2a-gate-access` | get, patch |

Two Roles for people that nothing binds: `openagentix-access-admin` (create, update, delete `agentaccesses`) and `openagentix-access-viewer`. The existing `openagentix-agent-builder` Role does **not** get `agentaccesses`: building an agent and granting access to it are separate rights.

The CRD schema mirrors the simple rules (types, patterns, lengths, `maxItems`, exactly one member of `caller` and of `userId`, method enum). The controller is the authority for policy, conflicts and limits.

### Conflicts and user id spaces

A user id is what kagent keys sessions and memory by. If two callers can assert the same user id for the same agent, one can read the other's sessions. The controller therefore refuses, with `Conflict`:

- a second rule for the same (identity, agent) pair. The older rule wins (creation time, then name). A new object can never take over an existing grant;
- a rule whose user id space overlaps the space of a rule for a **different** identity, anywhere in the namespace, or a reserved chart user id. Two spaces overlap when two `exact` or `fixed` values are equal, or one value starts with a prefix, or one prefix starts with the other. Same identity, different agents, overlapping spaces is allowed;
- a rule that names a reserved chart ServiceAccount.

The check is namespace-wide, not per agent, because whether kagent scopes every store by agent as well as user id is *unverified*. Stricter is safer here.

## Migration from `governance.a2a.callers[]`

- Chart callers keep working unchanged. `governance.a2a.callers[]`, the bridge, schedules and Kourier bindings stay chart rules for at least one release after `AgentAccess` ships. Deprecating `governance.a2a.callers[]` is a later changelog note, not part of this ADR. Static-key callers (Kourier) and `memory: true` callers stay chart-only.
- To move a ServiceAccount caller: add its namespace to `controlPlane.policy.access.callerNamespaces`, create an `AgentAccess` with the same ServiceAccount, agents (same namespace), user id rule and methods, then remove the `governance.a2a.callers[]` entry in a `helm upgrade`. While the chart entry exists the resource is refused with `Conflict`, and the chart rule keeps working. After the upgrade the gate pod restarts (the chart rules changed) and the controller accepts and publishes the resource. Calls can be refused for the time between the two, about a minute (*unverified*). Do it in a quiet period.
- A user id value outside the narrower character set must change. The migration guide lists the check.
- `Schedule` (issue #4) will need an `AgentAccess` for its ServiceAccount. Whether the schedule controller creates it or the user does is decided in the `Schedule` design, not here. `reserved-kinds.md` currently says the user does.

## Security considerations

- **Who can grant.** Anyone who may create `AgentAccess` in the agents namespace can let an allowed-namespace ServiceAccount call any agent there. That right is its own Role and nothing binds it by default.
- **Caller spoofing.** The identity is a projected ServiceAccount token checked by TokenReview with the gate's own audience. Anyone who can create pods with that ServiceAccount, or create tokens for it, in the caller's namespace acts as the caller. The boundary is RBAC in the caller's namespace (as ADR 0006 said for schedules), which is why `callerNamespaces` is an explicit operator list and platform namespaces are refused. A ServiceAccount deleted and created again with the same name keeps the grant, as a RoleBinding would: the rule follows the name, not the UID, because the controller cannot read ServiceAccounts in other namespaces.
- **User id spoofing.** Handled by the overlap rule above and by the gate setting `X-User-Id` itself, as today. A container agent still receives `X-User-Id` as information, not proof (ADR 0015).
- **Rule ordering.** No ordering exists to exploit: at most one rule applies per (identity, agent), chart rules win over resource rules for the same identity, and the older resource wins a conflict.
- **Revocation.** Deleting or narrowing a rule takes effect when the gate loads the new file: the kubelet refresh plus up to 10 s. A stream opened before that keeps running until it ends. While the controller is down, a deleted rule stays in the file; an operator can empty it by hand (`kubectl patch` the ConfigMap; the guard binds only the controller) or turn the switch off.
- **Tampering with the file.** Only the controller's Role may patch it, and the guard limits the content. An administrator can still edit it; the controller rewrites it on its next pass.
- **Audit.** One line per request as today, plus the `access` field. Never message text.
- **What leaves the cluster.** Nothing new.
- An independent security review is required before the slice that turns the controller into a writer of gate rules is merged.

## Alternatives considered and rejected

| Alternative | Why not |
|---|---|
| The gate watches `AgentAccess` (Option B) | New API rights and an API client in the request path; policy checks twice; no status. Faster revocation is the one real gain, kept as an open point |
| A field in `AgentDefinition` (Option C) | Merges the right to build with the right to grant |
| Write into the chart's rules file (Option D) | Helm overwrites it |
| Several callers per object | Conflicts and status per caller get harder, and deleting one caller means editing a shared object |
| A label selector for agents | Labels are informational and anyone who can write an agent can set them (API conventions). Names only |
| Static keys as an identity source | The controller would have to handle a Secret. Keys stay chart callers |
| Keep the last good access list on a malformed update | Could keep a revoked grant alive |
| Keep the ConfigMap on uninstall | A re-install would start with stale grants |
| "First match wins" over an ordered list | Order would decide security; overlapping rules are refused instead |

## Amendments

- `services/control-plane/README.md`, "What it never does": "Write gate rules" becomes "Write gate rules other than the access list derived from accepted `AgentAccess` resources, and only when `controlPlane.agentAccess.enabled` is true". Changed in the slice that builds it, not in this pull request.
- `docs/diary/reference/reserved-kinds.md` points to this record.

## Consequences

- A team can let a service call its agent with `kubectl apply`, no chart change and no gate restart. A product can ship its own access rule.
- `Schedule` and later `AgentRun` have a resource to depend on.
- The gate gains a second file and a lookup per (identity, agent). Chart callers do not change.
- Becomes harder: the gate now has three sources (chart rules, route list, access list), and two of them come from the controller. Each has its own strict parser and its own guard.
- Ruled out for now: static keys and memory calls in a resource, push notification configuration, agents in another namespace, selectors.
- Security impact: the controller becomes a writer of caller rules. Bounded by policy, RBAC, the guard pattern rendered from operator values, deny by default at two levels (chart switch, empty `callerNamespaces`), and an independent review.
- Compatibility: nothing changes for existing users. Default render unchanged. A user id with characters outside the new set cannot move to a resource without changing.

## Test plan

Each slice is test first: the failing test is written and seen to fail before the code.

- **Gate** (`services/a2a-gate`): strict parse table (unknown member, repeated member, wrong type, duplicate pair, unknown method, a `memory` or URL member, size and count limits, trailing data); atomic reload under `-race`; a removed grant is refused after reload; a malformed update drops all resource grants and keeps chart callers; a missing file at start; a chart rule wins over a resource grant for the same ServiceAccount; `unknown_caller` versus `agent`; the audit `access` field and no body text in any line.
- **Control plane**: decode and schema tests for the kind; one policy case per refusal (`callerNamespaces`, method, agent name, counts, user id set and prefix end); the overlap rule as a table, including reserved chart ids; `Conflict` with the older rule winning and the newer taking over after the older is deleted; `maxGrants`; canonical encoding is stable over input order; publish on create, update, delete and policy change; a removed rule leaves the list (the issue's "done when"); `PublishFailed` keeps the status honest; no request ever reads a Secret (`internal/kubetest`); the reason table matches the README; no upstream words in the new packages.
- **Guard** (`make test-guard`): the canonical list allowed at its maximum size; each refusal (another ConfigMap, a caller namespace not allowed, a method not allowed, a `memory` member, a URL, an extra data key, a label change, create or delete); status patch allowed, spec writes refused; the CEL cost stays within the budget at 256 KiB.
- **API server** (`make test-apiserver`): the CRD applies; schema refusals (two `userId` members, no `caller`, unknown method, 65 agents); status is a subresource; the guard refuses impersonated writes.
- **Chart** (`make test-chart`): default render and control plane demo render byte-identical with the switch off; the switch on renders the CRD, the ConfigMap, the Roles, the guard, the gate environment and mount, and the NetworkPolicy peers; the render fails for a platform namespace in `callerNamespaces`, for the switch without the control plane or the gate, and for a push notification method.
- **Live proof** (quick start, stub model, no paid call): a ServiceAccount in a test namespace calls an agent through the gate with an `AgentAccess` (200), is refused with another user id (403 `user_id`), and after the object is deleted is refused (403); the time from delete to refusal is measured and written in the diary. The same on k3s in the `e2e-k3s` job if time allows.

## Slices

1. **This ADR**, reviewed for at least 7 days (it changes the security model).
2. **Gate reads an access list.** `A2A_GATE_ACCESS_FILE`, strict parser, reload, lookup per (identity, agent), audit field, fail closed. The chart renders the empty ConfigMap, the mount and the environment variable only with the switch on. Testable with a hand-written file; nothing writes it yet.
3. **The kind and the controller.** CRD, types, policy keys, conflict and overlap rules, publishing, RBAC, guard policies, people's Roles, NetworkPolicy peers, status contract, README, reference page, live proof, independent security review. This closes issue #3.
4. **Migration guide** for `governance.a2a.callers[]`, a read-only list in the console, and the `Schedule` design using it (issue #4).

Later, by demand: identity sources from the 0.4 identity adapter, cutting open streams on revocation, a load acknowledgement from the gate, faster revocation (Option B) if the measured delay is too long.

## Not checked / open points

- *Unverified*: how long the kubelet takes to refresh the mounted ConfigMap on kind and k3s, and so how long revocation takes. Measured in slice 3.
- *Unverified*: the CEL cost of one regular expression over a 256 KiB string within the admission policy budget. If it does not fit, the limits shrink.
- *Unverified*: the exact A2A 1.0 JSON-RPC method names for task listing and push notification configuration. Read the specification again before the method enum is written.
- *Unverified*: whether kagent scopes sessions and memory by agent as well as user id. The overlap rule is namespace-wide until this is known.
- *Unverified*: that a Helm upgrade leaves `a2a-gate-access` alone (same as the route list).
- Open for the owner: is about a minute of revocation delay acceptable for 0.3, or should the gate watch the ConfigMap through the API (one more Role for the gate) from the start?
- Open for the owner: should `Schedule` create its own `AgentAccess`, or should the user create it? This ADR does not decide.
- Open for the owner: should the user id character set be narrowed for chart callers too, so that both sources follow one rule?
- Open for the owner: keep `callerNamespaces` as a chart value (an operator change needs `helm upgrade`), or make it part of a later `PlatformPolicy` kind?
