# ADR 0016: AgentAccess, the A2A gate's caller rules as a resource

Status: Proposed
Date: 2026-11-25
Issue: #3
Replaces: none. Fills in the `AgentAccess` entry that ADR 0012 reserved for release 0.3. Changes one line of `services/control-plane/README.md` ("What it never does": write gate rules), see "Amendments".

A new namespaced kind, `AgentAccess` (`openagentix.io/v1alpha1`), says that one caller identity may call some agents of the same namespace, with which user ids and which A2A methods. The controller checks it against policy and writes the accepted rules into a ConfigMap that the A2A gate reloads. The gate checks again what it can see. It is off by default. Nothing here is built yet; everything is *unverified* until the slices below are done.

## Context

Today the A2A gate's caller rules are chart values. Facts read in this repository on 2026-11-25:

- The gate reads one rules file, `A2A_GATE_RULES`, once at start (`services/a2a-gate/cmd/a2a-gate/main.go`, `rules.Load`). A rule is a caller name, one identity (a ServiceAccount, or a static key whose hash is in a mounted Secret), a list of agents (`namespace/name`), a user id rule (exactly one of `exact`, `prefix`, `fixed`), optional `methods` (default `SendMessage`, `SendStreamingMessage`) and optional `memory` (`services/a2a-gate/internal/rules/rules.go`). Unknown fields are refused. One ServiceAccount belongs to at most one caller.
- The chart builds that file from the bridge, each schedule, each Kourier binding and `governance.a2a.callers[]` (helper `oa.a2aRules` in `charts/openagentix/templates/_helpers.tpl`), puts it in the ConfigMap `a2a-gate-rules`, and rolls the gate pod when it changes (`checksum/rules` in `charts/openagentix/templates/governance.yaml`).
- A caller must also pass the gate's NetworkPolicy. Extra callers are admitted by `networkPolicy.extraA2ACallers`, and the render fails when such a namespace has no matching caller rule.
- Authentication is a TokenReview of a projected token with the audience `openagentix-a2a` (positive answer cached 30 s, by token) or a static key. The cache holds the identity, not the rule: the rule is looked up on every request (`services/a2a-gate/internal/auth/auth.go`).
- ADR 0015 added a second, controller-written file to the gate: the route list `a2a-gate-routes` / `routes.json`. It is mounted as a directory, checked every 10 s and swapped atomically. The controller patches it through a Role limited to that one ConfigMap, and an admission policy limits the content with one regular expression over the whole value, at most 64 KiB (`charts/openagentix/templates/control-plane-guard-workload.yaml`).
- The control plane README lists "write gate rules" under "What it never does": "nobody may call a built agent until an operator adds a caller rule". Adding a caller today means a `helm upgrade` and a gate restart.
- ADR 0012 reserved `AgentAccess` for 0.3 with four parts: callers, agents, the user id rule, the allowed methods. `Schedule` (issue #4) needs it, and a product's controller becomes a caller with the task methods. `docs/diary/reference/reserved-kinds.md` says a schedule without an access rule fails with a clear condition.
- The admission policy cost of `matches()` grows with the length of the string times the length of the pattern (about `ceil(0.1 × string length) × ceil(0.25 × pattern length)`), and one expression may cost at most 1,000,000. One pattern over a large value does not fit.

The problem: a team that builds an agent with `AgentDefinition` cannot let anything call it without asking the operator for a chart change and a gate restart.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `AgentAccess` kind; the controller validates and writes a second gate source, `a2a-gate-access` | One writer that applies policy, status per rule, the gate stays a file reader with no new API rights, same mechanism as the route list | Reload delay of the kubelet volume refresh (about a minute, *unverified*); a second format to keep strict | Read the gate, the route list code and guard, and the chart, on `main` |
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
  agents:                      # 1..16, names of agents in this namespace
    - name: assistant
  userId:                      # exactly one of exact, prefix, fixed
    exact: "ci:smoke"
  methods: [SendMessage]       # required, 1..8 entries
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

**Scope.** An `AgentAccess` grants access only to agents in its own namespace. The caller may live in another namespace. This is the Kubernetes rule for RoleBindings: whoever controls the agents' namespace decides who calls them, and a team in one namespace cannot grant itself access to another's agents. In 0.3 the controller serves one agents namespace (ADR 0012, change 2). An admission policy for all users refuses an `AgentAccess` in any other namespace, so an object that would do nothing cannot be created.

**Agents are named.** Any agent of the namespace counts: an `AgentDefinition`, a container agent or a chart agent. A grant for a name with no agent yet is published and takes effect when the agent exists. Grants follow the name: an agent deleted and created again under the same name, even by another person or from another image, keeps every grant. Agent names are DNS labels (lower case letters, digits and `-`, at most 63, no dots), as in the gate's route list. An agent whose name has a dot cannot be granted by a resource; a chart caller can still reach it.

**Fields.**

| Field | Rule |
|---|---|
| `caller.serviceAccount.{namespace, name}` | Required in 0.3. DNS label and DNS subdomain. The namespace must be in the policy's `access.callerNamespaces`. A later identity source (the identity adapter of ADR 0013, release 0.4) is a new member of `caller`, exactly one set, so adding it does not break anyone. Static keys are not offered: they live in a Secret, and the controller never reads Secrets |
| `agents[].name` | 1 to 16 entries, DNS labels, no duplicates. A list of objects so that a selector or a version can follow |
| `userId.exact` | The caller may send this value or none; the gate fills it in |
| `userId.prefix` | The caller must send a value that starts with it and has more after it. The prefix must end with `:` |
| `userId.fixed` | The gate always sets this value and ignores what the caller sends |
| user id values | 1 to 128 characters from `a-z 0-9 . _ : @ + -`. Lower case only, so two values that differ only in case cannot exist and comparisons are exact. The same set applies to the value a caller sends under a resource grant: the gate refuses anything else with 403 `user_id` |
| `methods` | **Required**, 1 to 8 distinct entries from the policy's `access.allowedMethods` |

`methods` is required on purpose. With a default, a misspelt `methods` would be pruned by the API server and the rule would silently get the default methods. Without a default, the schema refuses the object.

Not in the kind: `memory` (the two kagent MemoryService calls of ADR 0006 round 3 are an upstream API, and only the bridge needs them; they stay a chart-only caller option), push notification configuration methods (they make the runtime call a URL the caller chooses), `ListTasks` (it may show tasks of other users, see "Not checked"), any URL, host, header or key.

**Unknown fields.** The API server prunes them. Every required field (`caller`, `agents`, `userId`, `methods`) fails the schema when misspelt; there is no optional field whose loss could widen a rule.

### Status

Public fields follow `docs/api-conventions.md`: `conditions`, `observedGeneration`, `caller` (the identity as the gate will match it, `serviceaccount:<ns>/<name>`, an opaque string), `agents` and `methods` as published, `violations` (one sentence per refused rule). `status.controller` holds the hash of the access list that was last written, and may change without notice.

`Ready=True` means: **this rule is in the gate's access list as written for `status.observedGeneration`**. It does not mean the gate has already loaded it. The gate checks the mount every 10 s, after the kubelet has refreshed the mounted ConfigMap, which can take about a minute (*unverified*, measured in slice 2). A client that needs certainty polls the agent.

| Condition | Reason | Status | Meaning |
|---|---|---|---|
| `Accepted` | `Accepted` | True | the rule passes the policy and conflicts with no other rule |
| `Accepted` | `ShadowedByChart` | True | a chart caller rule names the same ServiceAccount. The rule is published, and the gate uses the chart rule while it exists. When the chart entry is removed, the gate switches to this rule with no gap |
| `Accepted` | `PolicyViolation` | False | one or more policy rules refused it; each is in `status.violations` |
| `Accepted` | `Conflict` | False | another accepted rule already holds this identity for one of these agents, or its user id space overlaps another caller's; the message names the other rule |
| `Accepted` | `LimitReached` | False | accepting it would pass `access.maxGrants`, the entry ceiling or the size ceiling of the access list; older rules keep their place |
| `Ready` | `Ready` | True | the rule is in the published access list |
| `Ready` | `NotAccepted` | False | the rule is refused; it is not in the list (and was removed if it was there) |
| `Ready` | `PublishFailed` | False | writing the access list failed; the controller then wrote the empty list, or could not write at all. The message says which, never with an API error text |
| `Ready` | `NotSynced` | False | the controller has not finished reading all rules since it started; nothing is published yet |
| `Synced` | `Synced` | True | the last pass could read everything it needed |
| `Synced` | `TransientError` | False | a read failed; the other conditions are the last known state |

The same contract tests as for `AgentDefinition` apply: a test fails when the code sets a reason that is not in this table.

### Policy and chart values

Chart switch `controlPlane.agentAccess.enabled`, default `false`. It needs `controlPlane.enabled` and `governance.a2a.enabled`; the render fails otherwise. With it off, the chart renders exactly what it renders today, for the default values and for the control plane demo values: no CRD, no ConfigMap, no Role, no admission policy, no gate environment variable, no NetworkPolicy peer, no new policy keys.

Policy keys (chart values under `controlPlane.policy.access`, written into the existing policy ConfigMap):

| Key | Default | Meaning |
|---|---|---|
| `callerNamespaces` | `[]` | namespaces whose ServiceAccounts a rule may name. Empty: every rule is refused. Deny by default. The render fails for every namespace the chart installs anything into, and for `kube-system` |
| `allowedMethods` | `[SendMessage, SendStreamingMessage]` | the methods a rule may list. An operator may add `GetTask`, `CancelTask` and `SubscribeToTask`. The chart refuses `ListTasks`, the push notification configuration methods and any name it does not know |
| `maxGrants` | `30` | accepted rules in the namespace; the oldest keep their place. The chart refuses a value where `maxGrants × 16` (agents per rule) is above the entry ceiling of 500 |

Derived by the chart, not set by users: `access.reserved.serviceAccounts` (each `governance.a2a.callers[]` ServiceAccount; the bridge's and the schedules' are in chart namespaces and so already refused) and `access.reserved.userIds` (the bridge prefix, each `schedule:<name>`, each `kourier:<name>`, and each chart caller's user id rule). These reserved ids cover chart-rendered callers only. A future `Schedule` resource is not in them; its user ids must be kept apart by the overlap rule like any other resource grant.

The same `callerNamespaces` list adds namespace peers to the gate's ingress NetworkPolicy, so one value admits a namespace at the network and at the policy. The chart's check that every `extraA2ACallers` namespace has a chart rule accepts a namespace in `callerNamespaces` too.

### How the rules reach the gate

The controller never reads a Secret and the gate gets no new API rights.

1. The controller lists and watches `AgentAccess` in the agents namespace (new: today it watches only definitions), and watches the ConfigMap `a2a-gate-access`.
2. It publishes nothing until its first full list of `AgentAccess` objects is complete. Until then rules show `Ready=False`, reason `NotSynced`, and the gate keeps whatever list it has. Publishing from a half-read cache would drop grants that still exist, or keep a conflict undetected.
3. On every change, on a change of the ConfigMap by anyone else, and on a full resync every 5 minutes, it computes the access list from the accepted rules: a pure function of the current objects, the policy and the reserved lists. A removed or refused rule is simply absent. There is no finalizer; deletion needs no extra step. If the ConfigMap differs from what it should be (drift), the controller writes it again.
4. **Shape: one ConfigMap key per grant.** The key is `<access name>.<agent name>` (two DNS labels, at most 127 characters). The value is one short line of fields separated by single spaces, in a fixed order:

   ```
   caller=ci/smoke user=exact:ci:smoke methods=SendMessage
   ```

   One key per (rule, agent) pair. No URL, host, key or secret. A value is at most 512 bytes. Small values with simple fields let the admission policy check each one cheaply (see below).
5. **Ceilings.** The gate accepts at most 500 entries and 512 KiB in total. The controller counts both before it accepts a rule and stops below them: at most 500 entries and 448 KiB, and `maxGrants`. A rule that would pass any of them gets `LimitReached`. So a list the controller writes always fits the gate and the guard.
6. **Fail closed on a failed publish.** When a write is refused (by the guard or the API server), the controller next writes the empty list: every grant key removed. The empty list is always valid for the guard and the gate. An old list is never left in place on purpose. If the controller cannot write at all (the API server is down), the old list stays, and status says `PublishFailed`; see "Revocation" below.
7. The chart renders the ConfigMap once with no keys. It is **not** kept on uninstall (unlike the route list): a re-install must start with no grants and wait for the controller, never with a stale list. Helm's three-way merge leaves the controller's keys alone on upgrade while the chart's start value does not change (the same open point as the route list in ADR 0015).
8. The gate mounts the ConfigMap as a directory (not `subPath`), one file per key. It reads the directory through the kubelet's `..data` link, which the kubelet swaps atomically, so one read sees one consistent version. It checks every 10 s and swaps its in-memory list atomically.

**Gate settings.** Set by the chart only when the switch is on: `A2A_GATE_ACCESS_DIR` (the mount), `A2A_GATE_ACCESS_AGENTS_NAMESPACE` (the agents namespace) and `A2A_GATE_ACCESS_CALLER_NAMESPACES` (the same list as the policy). With `A2A_GATE_ACCESS_DIR` unset the gate behaves exactly as it does today.

**The gate checks what it can see.** At every load, and before it uses a list, the gate refuses the whole list when:

- a value does not parse (unknown or repeated field, wrong order, a method it does not know, a user id outside the character set), or a key is not two DNS labels;
- a grant names an agent outside the agents namespace, or a ServiceAccount outside the caller namespaces;
- two entries give one identity the same agent;
- the user id spaces of two different identities overlap, or a resource grant's space overlaps a chart rule of another identity (the same rule as in the controller, below);
- there are more than 500 entries or more than 512 KiB.

So a wrong list from a compromised controller, or a hand edit, is caught a second time, at the place that enforces it.

**Fail closed, revocation first.** This differs from the route list on purpose. A malformed route list keeps the last good one, because an old route list can only send a listed agent to the workload namespace. An old access list can keep a revoked grant alive. So:

- Missing or refused at start: the gate starts with no resource grants. Chart callers work as before.
- A refused update: the gate drops all resource grants, logs one line with the reason (never the content), and keeps chart callers. A later valid list restores them.
- A valid list that no longer names a grant removes it at the next check.

### How the gate decides

The gate's lookup changes from "one rule per identity" to "one rule per identity and agent". For each request, after authentication:

1. A static key matches a chart rule only, as today.
2. A ServiceAccount that a chart rule names uses that chart rule only. Resource grants for the same identity are ignored (they are `ShadowedByChart`).
3. Otherwise the gate looks up the grant for (identity, agent). None for this identity: 403 `unknown_caller`. None for this agent: 403 `agent`. Then the method and user id checks run as today, with the narrower character set for the sent user id.
4. The memory routes are refused with 403 `memory` for an identity that has only resource grants, before the gate reads the body.

There is no "first match wins": at most one rule can apply to an (identity, agent) pair, so the order of objects never changes a verdict. The controller makes that true and the gate refuses a list where it is not.

The audit line keeps its fields. For a resource grant, `caller` is `serviceaccount:<ns>/<name>` and a new field `access` holds `<namespace>/<name>` of the `AgentAccess`. Adding a field to the audit line is additive. The line still never holds message text, the body, a token or a key, and the user id stays a salted hash unless the operator chose `raw`.

### Admission policies

**What even a compromised controller can write.** New allowlist policies, bound to the controller's ServiceAccount, `failurePolicy: Fail`, executed in `make test-guard` and `make test-apiserver`:

- **The access list.** Update only, only `a2a-gate-access` in the gate namespace, only `data`, labels, annotations and owner references unchanged, at most 500 keys. Each key is two DNS labels joined by a dot. Each value is at most 512 bytes and is checked field by field: it is split at spaces into exactly three fields; the caller's namespace is in the operator's caller namespaces (rendered into the policy literally); the user id field has one of the three kinds and a value of the allowed characters; each method is in the operator's allowed methods. No pattern runs over the whole ConfigMap. So a compromised controller can grant only ServiceAccounts of namespaces the operator allowed, only with allowed methods, and never memory, never push notification configuration, never a URL.
- **AgentAccess status.** The controller may patch `agentaccesses/status` and nothing else of the kind: no create, update or delete, no finalizer. `guard-other` keeps refusing everything not listed.

The cost of the access list policy at its largest (500 keys of 512 bytes) must be measured within the limit in `make test-guard` before slice 3b starts. If it does not fit, the entry ceiling in the gate, the controller and the policy is lowered together until it does.

What the guard cannot check: that a grant matches an existing `AgentAccess` (the guard cannot see other objects), or the overlap of user ids across entries. The gate checks the overlap. A compromised controller can still grant any allowed-namespace ServiceAccount any agent of the namespace with allowed methods. That is the remaining blast radius and it is bounded by the operator's own lists.

**For all users.** One more policy refuses an `AgentAccess` outside the agents namespace. The CRD schema mirrors the simple rules (types, patterns, lengths, `maxItems`, exactly one member of `caller` and of `userId`, method enum). The controller is the authority for policy, conflicts and limits.

RBAC added for the controller, namespaced only:

| Namespace | Resource | Verbs |
|---|---|---|
| agents | `agentaccesses` | get, list, watch |
| agents | `agentaccesses/status` | patch |
| gate | `configmaps`, resource name `a2a-gate-access` | get, list, watch, patch |

Two Roles for people that nothing binds: `openagentix-access-admin` (create, update, delete `agentaccesses`) and `openagentix-access-viewer`. The existing `openagentix-agent-builder` Role does **not** get `agentaccesses`: building an agent and granting access to it are separate rights.

### Conflicts and user id spaces

A user id is what kagent keys sessions and memory by. If two callers can assert the same user id for the same agent, one can read the other's sessions. The controller therefore refuses, with `Conflict`:

- a second rule for the same (identity, agent) pair. The older rule wins (creation time, then name). A new object can never take over an existing grant;
- a rule whose user id space overlaps the space of a rule for a **different** identity, anywhere in the namespace, or a reserved chart user id of a different identity. Two spaces overlap when two `exact` or `fixed` values are equal, or one value starts with a prefix, or one prefix starts with the other. Same identity, different agents, overlapping spaces is allowed.

A rule for a ServiceAccount that a chart rule names is not a conflict. It is accepted with reason `ShadowedByChart` and published. The chart rule's own user ids are not checked against it, because they belong to the same identity. The gate ignores the published rule while the chart rule exists.

The check is namespace-wide, not per agent, because whether kagent scopes every store by agent as well as user id is *unverified*. Stricter is safer here.

### Schedules

Decided now: **the user creates the `AgentAccess`** for a schedule's ServiceAccount. Access stays explicit and deny by default. A `Schedule` controller never gets create or delete rights on `agentaccesses`; a schedule without a matching rule reports a clear condition. The chart-derived reserved user ids do not cover `Schedule` resources; a schedule's user id is protected only by the overlap rule. Where a schedule's pod runs is decided in the `Schedule` design: the chart's own schedules namespace is refused in `callerNamespaces`, so that design must choose another namespace or a narrow exception.

## Migration from `governance.a2a.callers[]`

- Chart callers keep working unchanged. `governance.a2a.callers[]`, the bridge, schedules and Kourier bindings stay chart rules for at least one release after `AgentAccess` ships. Deprecating `governance.a2a.callers[]` is a later changelog note, not part of this ADR. Static-key callers (Kourier) and `memory: true` callers stay chart-only. In 0.3 the chart warns when a chart caller's user id uses characters outside the new set; in 0.4 that becomes an error.
- To move a ServiceAccount caller:
  1. Add its namespace to `controlPlane.policy.access.callerNamespaces`.
  2. Create an `AgentAccess` with the same ServiceAccount, agents (same namespace), user id rule and methods. It is accepted with reason `ShadowedByChart` and published; the chart rule keeps working.
  3. Wait for `Ready=True`, then remove the `governance.a2a.callers[]` entry in a `helm upgrade`. The gate restarts with the new chart rules and uses the published rule at once. No calls are refused in between.
- A resource prefix must end with `:`, and user id values must be lower case from `a-z 0-9 . _ : @ + -`. A chart rule with a prefix such as `ci-` or with upper case letters must change its ids before it can move. The migration guide lists the check.

## Security considerations

- **Who can grant.** Anyone who may create `AgentAccess` in the agents namespace can let an allowed-namespace ServiceAccount call any agent there. That right is its own Role and nothing binds it by default.
- **Caller spoofing.** The identity is a projected ServiceAccount token checked by TokenReview with the gate's own audience. Anyone who can create pods with that ServiceAccount, or create tokens for it, in the caller's namespace acts as the caller. The boundary is RBAC in the caller's namespace (as ADR 0006 said for schedules), which is why `callerNamespaces` is an explicit operator list and every chart namespace is refused. A ServiceAccount deleted and created again with the same name keeps the grant, as a RoleBinding would: the rule follows the name, not the UID, because the controller cannot read ServiceAccounts in other namespaces. The same holds for agent names.
- **User id spoofing.** Handled by the overlap rule (in the controller and again in the gate), lower-case-only values, the same character set for sent values, and the gate setting `X-User-Id` itself, as today. A container agent still receives `X-User-Id` as information, not proof (ADR 0015).
- **Rule ordering.** No ordering exists to exploit: at most one rule applies per (identity, agent), chart rules win over resource rules for the same identity, and the older resource wins a conflict.
- **Revocation.** Deleting or narrowing a rule takes effect when the gate loads the new list: the kubelet refresh plus up to 10 s. A stream opened before that keeps running until it ends. An over-size or refused list never blocks revocation: the controller writes the empty list instead. While the controller cannot write at all, a deleted rule stays in the list; an operator can remove the keys by hand (`kubectl patch` the ConfigMap; the guard binds only the controller) or turn the switch off.
- **Tampering with the list.** Only the controller's Role may patch it, the guard checks each value, and the gate checks the whole list again. An administrator can still edit it; the controller sees the change and rewrites it.
- **Audit.** One line per request as today, plus the `access` field. Never message text.
- **What leaves the cluster.** Nothing new.
- An independent security review is required before slice 3b, the one that makes the controller a writer of gate rules, is merged.

## Alternatives considered and rejected

| Alternative | Why not |
|---|---|
| The gate watches `AgentAccess` (Option B) | New API rights and an API client in the request path; policy checks twice; no status. Faster revocation is the one real gain, kept as an open point |
| A field in `AgentDefinition` (Option C) | Merges the right to build with the right to grant |
| Write into the chart's rules file (Option D) | Helm overwrites it |
| One JSON document in one key, checked by one pattern | The admission cost grows with size times pattern length and does not fit the limit at a useful size |
| Several callers per object | Conflicts and status per caller get harder, and deleting one caller means editing a shared object |
| A label selector for agents | Labels are informational and anyone who can write an agent can set them (API conventions). Names only |
| Static keys as an identity source | The controller would have to handle a Secret. Keys stay chart callers |
| A default for `methods` | A misspelt field would be pruned and silently replaced by the default |
| Keep the last good access list on a refused update | Could keep a revoked grant alive |
| Leave the old list when a publish fails | Same; the empty list is written instead |
| Keep the ConfigMap on uninstall | A re-install would start with stale grants |
| "First match wins" over an ordered list | Order would decide security; overlapping rules are refused instead |
| Refuse a resource rule for a chart caller's ServiceAccount | Moving a caller would refuse calls between the two steps |
| A `Schedule` controller that creates its own access rules | It would hold the right to grant access, which is the right this kind separates |

## Amendments

- `services/control-plane/README.md`, "What it never does": "Write gate rules" becomes "Write gate rules other than the access list derived from accepted `AgentAccess` resources, and only when `controlPlane.agentAccess.enabled` is true". Changed in the slice that builds it, not in this pull request.
- `docs/diary/reference/reserved-kinds.md` points to this record.

## Consequences

- A team can let a service call its agent with `kubectl apply`, without a chart change or a gate restart, once the operator has allowed the caller's namespace. A product can ship an `AgentAccess` in its install, but someone with the access-admin Role applies it, and the operator's namespace list still decides.
- `Schedule` and later `AgentRun` have a resource to depend on.
- The gate gains a second controller-written source and a lookup per (identity, agent). Chart callers do not change.
- Becomes harder: the gate now has three sources (chart rules, route list, access list), and two of them come from the controller. Each has its own strict parser and its own guard.
- Ruled out for now: static keys and memory calls in a resource, `ListTasks`, push notification configuration, agents in another namespace, agent names with dots, selectors.
- Security impact: the controller becomes a writer of caller rules. Bounded by policy, RBAC, the guard checked per value against operator values, the gate's own checks, deny by default at two levels (chart switch, empty `callerNamespaces`), and an independent review.
- Compatibility: nothing changes for existing users. Default render unchanged. A user id with upper case or other characters outside the new set cannot move to a resource without changing.

## Test plan

Each slice is test first: the failing test is written and seen to fail before the code.

- **Gate** (`services/a2a-gate`): with `A2A_GATE_ACCESS_DIR` unset, the existing tests pass unchanged and the gate behaves exactly as today; strict parse table (unknown, repeated or reordered field, unknown method, a `memory` field, a URL, bad key, size and count limits); agent outside the agents namespace and caller outside the caller namespaces refused; overlap across resource grants and against chart rules refused; a refused list drops all resource grants and keeps chart callers; a missing directory at start; atomic reload under `-race`; a removed grant is refused after reload; a chart rule wins over a resource grant for the same ServiceAccount; `unknown_caller` versus `agent`; a sent user id with upper case is refused; the memory route refuses a resource-grant identity without reading the body; the audit `access` field and no body text in any line.
- **Control plane**: decode and schema tests for the kind; one policy case per refusal (`callerNamespaces`, method, agent name, counts, user id set and prefix end); the overlap rule as a table, including reserved chart ids; `ShadowedByChart`; `Conflict` with the older rule winning and the newer taking over after the older is deleted; `LimitReached` by rules, by entries and by bytes; the encoding is stable over input order; nothing is published before the first full list; publish on create, update, delete, policy change and drift of the ConfigMap; a removed rule leaves the list (the issue's "done when"); an over-size or guard-refused write ends with the empty list, never the old one; no request ever reads a Secret (`internal/kubetest`); the reason table matches the README; no upstream words in the new packages.
- **Guard** (`make test-guard`): the largest allowed list (500 keys of 512 bytes) is allowed and its measured cost is within the limit; each refusal (another ConfigMap, a caller namespace not allowed, a method not allowed, a fourth field, a `memory` field, a URL, a bad key, a label change, create or delete); status patch allowed, spec writes refused; an `AgentAccess` outside the agents namespace refused for any user.
- **API server** (`make test-apiserver`): the CRD applies; schema refusals (two `userId` members, no `caller`, no `methods`, unknown method, 17 agents, an upper case user id); status is a subresource; the guard refuses impersonated writes.
- **Chart** (`make test-chart`): default render and control plane demo render byte-identical with the switch off; the switch on renders the CRD, the ConfigMap, the Roles, the admission policies, the gate settings and mount, and the NetworkPolicy peers; the render fails for a chart namespace in `callerNamespaces`, for the switch without the control plane or the gate, for `ListTasks` or a push notification method, and for `maxGrants` above 31.
- **Live proof** (quick start, stub model, no paid call): a ServiceAccount in a test namespace calls an agent through the gate with an `AgentAccess` (200), is refused with another user id (403 `user_id`), and after the object is deleted is refused (403); the time from delete to refusal is measured and written in the diary. A move from `governance.a2a.callers[]` with no refused call. The same on k3s in the `e2e-k3s` job if time allows.

## Slices

- **Slice 1. This ADR**, reviewed for at least 7 days (it changes the security model).
- **Slice 2. Gate reads an access list.** `A2A_GATE_ACCESS_DIR`, `A2A_GATE_ACCESS_AGENTS_NAMESPACE` and `A2A_GATE_ACCESS_CALLER_NAMESPACES`, strict parser, the gate's own checks, reload, lookup per (identity, agent), audit field, fail closed. Only the gate's environment and test values; no public chart value. A test proves that with `A2A_GATE_ACCESS_DIR` unset the gate behaves exactly as today. The kubelet refresh delay is measured here. Before the kind is built, the open checks below are done: the A2A method names, kagent's scoping of sessions and tasks by user and agent, and Helm's handling of the ConfigMap.
- **Slice 3a. The kind, without publishing.** CRD, types, policy keys, conflict, overlap and limit rules, status with `Accepted` only, the admission policy for other namespaces, people's Roles. Nothing reaches the gate.
- **Slice 3b. Publishing.** The access list writer, the empty-list fallback, drift watch and resync, the guard policy (only after its cost is measured within the limit in `make test-guard`), the controller's RBAC, the NetworkPolicy peers, the public switch `controlPlane.agentAccess.enabled`, README, reference page, live proof. Independent security review required. This closes issue #3.
- **Slice 4. Migration guide** for `governance.a2a.callers[]`, a read-only list in the console, and the `Schedule` design using it (issue #4).

Later, by demand: identity sources from the 0.4 identity adapter, cutting open streams on revocation, a load acknowledgement from the gate, faster revocation (Option B) if the measured delay is too long.

## Not checked / open points

- *Unverified*: how long the kubelet takes to refresh the mounted ConfigMap on kind and k3s, and so how long revocation takes. Measured in slice 2. The mounted ConfigMap stays unless the delay is too long; then the gate moves to a watch.
- *Unverified*: the admission cost of the per-value checks at 500 keys. Measured before slice 3b; the ceilings shrink together if needed.
- *Unverified*: whether `GetTask`, `CancelTask` and `SubscribeToTask` are scoped to the user who created the task, in kagent and in container agents. If they are not, a caller with these methods can read or cancel another user's tasks on the same agent when it can guess or learn a task id. The same question for `ListTasks`, which is refused until it is answered.
- *Unverified*: the exact A2A 1.0 JSON-RPC method names for task listing and push notification configuration. Read the specification again before the method enum is written.
- *Unverified*: whether kagent scopes sessions and memory by agent as well as user id. The overlap rule is namespace-wide until this is known.
- *Unverified*: that a Helm upgrade leaves the controller's keys in `a2a-gate-access` alone (same as the route list).
- *Unverified*: that the kubelet's `..data` link swap gives the gate one consistent version of a directory with many keys.
- Decided with the owner's defaults: the user creates a schedule's `AgentAccess`; `callerNamespaces` stays a chart value in 0.3; chart callers get the narrower user id set as a warning in 0.3 and an error in 0.4.
