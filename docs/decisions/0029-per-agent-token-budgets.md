# ADR 0029: per-agent token budgets in the one gateway policy, by budget class

Status: Proposed
Date: 2026-11-28
Issue: https://github.com/openagentix/openagentix/issues/229 (reference use cases; the follow-up named in ADR 0026 section D)
Replaces: none. The first slice of the `Budget` kind of ADR 0009, done as chart values and one optional `AgentDefinition` field, with no new kind and no new component. See "Relation to other records".

The operator names a few budget classes in chart values, each a token limit per time unit, counted per agent or shared by every agent of the class. A chart agent or an `AgentDefinition` names a class. The chart renders one conditional rate limit entry per class in the one gateway policy, and the agent's key entry carries the class name. Agents that name no class keep today's budget. Off by default: with no class, the chart renders byte for byte what it renders today. Nothing here is built. Everything is *unverified* until the slices below are done.

## Context

Read in this repository on 2026-11-28.

- **One budget for every key.** The one `AgentgatewayPolicy` (`charts/openagentix/templates/gateway.yaml`) has `spec.traffic.rateLimit.local` with one entry: `tokens` and `unit` from `gateway.policy.tokenBudget` (default 1,000,000 per hour), `key: apiKey.user_id`. Every virtual key gets its own bucket of the same size, per proxy replica.
- **Key entries.** `install.sh` writes one entry per chart agent into the ConfigMap `llm-api-keys`: `{"keyHash":"sha256:...","metadata":{"user_id":"<agent>"}}`. The control plane writes the entries of definitions into `llm-api-keys-control-plane` (`services/control-plane/internal/adapters/agentgateway/agentgateway.go`), with optional `team` and `project` copied from the reserved labels. The admission guard pins each entry to one exact form with a regular expression (`charts/openagentix/templates/control-plane-guard.yaml`, the key ConfigMap rule). The metadata is a free map for the gateway (comment in the adapter).
- **The gateway's schema allows more.** The agentgateway v1.7.0 CRD chart (`agentgateway.dev_agentgatewaypolicies.yaml`, the version the chart pins) has `spec.traffic.rateLimit.conditional`: a list of at most 16 entries, each a CEL `condition` and a `policy` with `local` limits; the first matching entry applies; one entry without a condition may be last, as the fallback. Each `local` entry has `tokens` or `requests`, `unit` (`Hours`, `Minutes`, `Seconds`) and an optional CEL `key`; "when unset, all requests share one bucket". The same description says token counts are known only when a request completes, so a token limit applies to later requests, and that each proxy instance keeps a bounded number of buckets per rule and drops the least used ones. This was read in the schema only. Nothing was run.
- **The use cases.** Each runs under the one budget. The bank README: "No per-agent budget: the gateway has one token budget number for every key". ADR 0026 section D named this record as the follow-up, "starting with a spike on whether agentgateway v1.7.0 can set a local token limit per key value". ADR 0017 (proposed) leaves a budget per schedule to the `Budget` kind.
- **Labels decide nothing.** ADR 0012, change 12: anyone who can write an object can set `openagentix.io/team` and `openagentix.io/project`, so they never decide access or billing on their own. A budget must not follow from them.

The problem: a platform team cannot give the bank's dispute agent a smaller budget than the demo assistant, or cap the three agents of one use case together. A runaway agent on a real model spends up to the shared default per hour.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Do nothing | Nothing to build | Every agent has the same budget; a use case cannot be capped | `gateway.yaml` |
| B. One `AgentgatewayPolicy` per agent | Simple per agent | The values already warn that several policies can overwrite each other; the controller would write a gateway policy, which the guard and ADR 0007 do not allow | `values.yaml` comment on `gateway.policy.name` |
| C. Conditional entries in the one policy, one per budget class, keyed on a class name in the key's metadata; agents name a class | One policy, still owned by Helm; the controller writes only a class name into an entry it already writes; definitions and chart agents alike; a class can be per agent or shared, which gives a per-use-case cap | Depends on CEL seeing `apiKey.budget_class` (*unverified*); at most 15 classes; local limits per replica, lost on restart; a new optional spec field | The v1.7.0 CRD schema |
| D. Conditional entries keyed on `apiKey.user_id` lists | No metadata field needed | Helm must list every agent; definitions are created after the render, so they cannot be listed | Same schema |
| E. Global rate limiting with an external rate limit service (`rateLimit.global`) | Shared across replicas, survives restarts | A new upstream component (a rate limit server and its store) | Same schema; out of scope by the rule of this record |
| F. The full `Budget` kind of ADR 0009 now | Scope, window, action, alerts, money | A new kind, a reconciler for spend, alert rules; larger than the use cases need | ADR 0009 |

## Decision

Option C, with D as the stated fallback if the spike shows that CEL cannot read the metadata field.

### Chart values

```yaml
gateway:
  policy:
    tokenBudget: {tokens: 1000000, unit: Hours}   # unchanged: the budget of every key with no class
    budgetClasses: []                             # default: none, the render is unchanged
    #  - name: bank-agents
    #    tokens: 300000
    #    unit: Hours
    #    per: agent          # agent: one bucket per key of the class; class: one bucket shared by every key of the class

agents:
  - name: dispute-agent
    budgetClass: bank-agents   # optional; must name a class; absent: the default budget

controlPlane:
  policy:
    budgetClasses:
      allowed: []              # class names an AgentDefinition may name; default none
      default: ""              # the class of a definition that names none; "" means the default budget
```

| Value | Rule |
|---|---|
| `budgetClasses[].name` | DNS label, at most 40 characters, unique. `default` is reserved |
| `budgetClasses[].tokens` | 1 to 2,147,483,647 (the CRD's 32-bit integer) |
| `budgetClasses[].unit` | `Hours`, `Minutes` or `Seconds`, as the CRD. Quoted in values |
| `budgetClasses[].per` | `agent` or `class`, required. No default, so a misspelt field fails the render |
| list length | At most 15, so that the classes and the fallback fit the CRD's 16 entries |
| `agents[].budgetClass` | Must name a class; the render fails otherwise |
| `controlPlane.policy.budgetClasses.allowed` | Each must name a class. A class with `per: class` is refused here (see "Shared classes") |
| `controlPlane.policy.budgetClasses.default` | Empty, or a name in `allowed` |

### Render

With at least one class, `spec.traffic.rateLimit` of the one policy becomes:

```yaml
rateLimit:
  conditional:
    - condition: 'apiKey.budget_class == "bank-agents"'
      policy:
        local:
          - {tokens: 300000, unit: Hours, key: apiKey.user_id}    # per: agent
    - condition: 'apiKey.budget_class == "fernvale-all"'
      policy:
        local:
          - {tokens: 500000, unit: Hours}                         # per: class, no key: one shared bucket
    - policy:                                                     # the fallback: today's budget
        local:
          - {tokens: 1000000, unit: Hours, key: apiKey.user_id}
```

With no class, the render is today's `rateLimit.local` entry, byte for byte.

### Key entries

- **Chart agents.** The chart adds the annotation `openagentix.io/budget-class` to the agent's model object when `budgetClass` is set. `install.sh` writes `"budget_class":"<name>"` after `user_id` in the metadata of that agent's entry. Without the annotation, the entry is unchanged.
- **Definitions.** A new optional field `spec.budget.class` on `AgentDefinition` (an object, so that a limit or a reference to a later `Budget` can follow). The controller checks it against `controlPlane.policy.budgetClasses.allowed`; a name not allowed is a violation, `Accepted=False`, reason `PolicyViolation`, and nothing is written. With no field, the policy's `default` applies. The controller writes `"budget_class":"<name>"` at the end of the metadata of the entry it already writes. It reads no Secret.
- **The guard.** When `allowed` is not empty, the key ConfigMap rule accepts one more optional member at the end of the metadata, `"budget_class"`, whose value must be one of `allowed`, rendered literally into the rule. When `allowed` is empty, the rule is rendered exactly as today.
- **Status.** A new public fact, `status.budget.class`: the class written to the key entry, or `default`. It says what was written, not that the gateway enforces it. Enforcement is shown only by the live proof.
- Labels (`openagentix.io/team`, `openagentix.io/project`) never choose a class.

### Shared classes

A class with `per: class` has one bucket for every key that names it. That is how a use case gets one cap for all its agents. It is also how one agent of the class can spend the others' budget. So in this record only the operator's chart agents may name a shared class; definitions may not (`allowed` refuses it). A later record can open it with a per-namespace or per-team scope, when the `Budget` kind exists.

### Limits, stated plainly

- **Local, per replica.** Each gateway proxy replica counts on its own. Two replicas double the budget. The installs proven so far run one proxy replica; the number is set by the gateway, not by this record.
- **Lost on restart.** A gateway restart empties the buckets.
- **Late.** Tokens are counted when a call completes, so the call that crosses the limit is allowed, and the next is refused with 429.
- **Bucket eviction.** The CRD says each replica keeps a bounded number of buckets per rule and drops the least used. How many is *unverified*. A dropped bucket starts full again.
- **Tokens only.** No money, no day or month window (the units stop at hours), no per-run or per-schedule limit (ADR 0012, ADR 0017). Cost per agent stays visible in the gateway metrics (ADR 0003).
- **Not a security boundary on its own.** It bounds spend by a mistaken or misled agent. Together with the A2A gate and the per-caller limits of ADR 0027 (proposed) it bounds how fast a caller can make an agent spend.

## Consequences

- Possible: a smaller budget for an agent that acts on records, a larger one for a busy assistant, one cap for all agents of a use case, a budget for definitions chosen from what the operator allows.
- Ruled out for now: money limits; day or month windows; budgets shared across replicas; shared classes for definitions; a class chosen by a label.
- Harder: the one gateway policy gets a list the operator must keep under 16 entries.
- Security impact: the operator decides every limit; a definition can only pick a class the operator allowed; the controller writes one more name into an entry it already writes, checked by the guard. Nothing new leaves the cluster. No secret is read.
- Compatibility: none for existing installs. Default render unchanged. An agent that gains a class gets a new key entry text; its key value does not change.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0009 | `Budget` (scope, limit, window, action) is still the later kind. A `Budget` object will map to a class (scope to the keys, limit and window to `tokens` and `unit`) and add alerts and money. This record is its adapter primitive |
| ADR 0012 | Labels never decide billing; a class is chosen in a spec field checked by policy |
| ADR 0017 (proposed) | A schedule runs on its agent's key, so it spends from its agent's class. A budget per schedule is still out |
| ADR 0026 | Section D named this follow-up |
| ADR 0027 (proposed) | Per-caller rate and open-call limits at the gate bound how fast runs start; this record bounds what an agent spends |

## Slices

Each slice is one pull request, tests first.

1. **This record.** Docs build.
2. **Spike, on a throwaway kind cluster with its own kubeconfig, stub model, no paid call.** Two keys in two classes with different limits and a third with none: 429 after the right number of tokens for each; a `per: class` class shared by two keys; a key entry whose metadata changes class (how long until the new limit applies); a gateway restart (buckets empty). The question that decides the design: does CEL see `apiKey.budget_class`? If not, the record is amended to option D for chart agents, and definitions keep the default.
3. **Chart and installer.** Values, refusals, the conditional render, the fallback, the annotation, `install.sh` metadata, the guard's optional member. Chart tests: byte-identical default, quick start and full demo renders; one test per refusal; 15 classes render and 16 fail; the guard's rule is unchanged with `allowed` empty. `make test-apiserver`: the rendered policy passes a server-side dry run against the v1.7.0 CRDs.
4. **Controller.** `spec.budget.class`, the policy check, the entry, `status.budget.class`. Unit tests, guard tests (an entry with a class not allowed is refused; a `per: class` class is refused), the field in the console's read-only view.
5. **Use cases.** The three reference agents get classes in their values (a per-agent class each, one shared class for the bank and equipment agents together as an example). Live proof with the stub model: each agent gets 429 at its own limit; the full demo assistant is unaffected. Diary and `what-works.md` row with the limits above.

## Not checked / open points

- *Unverified*: everything in slice 2; the number of buckets a replica keeps; whether a `conditional` entry and the existing `retry` and `apiKeyAuthentication` of the same policy work together as the schema suggests.
- Read again before quoting: the agentgateway version pinned by the installer and its `rateLimit` fields.

## Questions for the maintainer

1. **Budget classes now, as the first slice of `Budget`, instead of waiting for the kind?** Recommended: yes. The reference use cases need a cap before a real model runs unattended, and the class maps onto the later kind.
2. **A new optional field `spec.budget.class` on `AgentDefinition`?** Recommended: yes, as an object so a reference to a `Budget` can follow.
3. **Shared classes for definitions?** Recommended: no, not until a `Budget` scope can say whose agents share a bucket.
4. **The default budget stays 1,000,000 tokens per hour per key?** Recommended: yes for compatibility; the use case docs recommend a class for any agent on a real model.
5. **If the spike shows CEL cannot read the metadata: ship option D for chart agents only?** Recommended: yes, and say in the docs that definitions keep the default until an upstream change.
6. **Money limits.** Recommended: out of this record. They need spend read back from the gateway's metrics and a controller that lowers a limit, which ADR 0009 describes; and any price list is owner-gated.
