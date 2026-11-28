# ADR 0029: per-agent token budgets in the one gateway policy, by budget class

Status: Proposed (the slice 2 spike ran; see "Spike results")
Date: 2026-11-28
Issue: https://github.com/openagentix/openagentix/issues/229 (reference use cases; the follow-up named in ADR 0026 section D)
Replaces: none. The first slice of the `Budget` kind of ADR 0009, done as chart values and operator policy, with no new kind, no new resource field and no new component. See "Relation to other records".

The operator names a few budget classes in chart values, each a token limit per time unit, counted per agent or shared by every agent of the class. A chart agent names a class in its values; every `AgentDefinition` gets the one class the operator sets for definitions. A definition cannot choose its class. The chart renders one conditional rate limit entry per class in the one gateway policy, and the agent's key entry carries the class name. Agents that name no class keep today's budget. Off by default: with no class, the chart renders byte for byte what it renders today. Nothing here is built. The gateway behaviour it relies on was shown in a spike on a throwaway cluster ("Spike results"); the chart render, the guard and the controller are *unverified* until their slices are done.

## Context

Read in this repository on 2026-11-28.

- **One budget for every key.** The one `AgentgatewayPolicy` (`charts/openagentix/templates/gateway.yaml`) has `spec.traffic.rateLimit.local` with one entry: `tokens` and `unit` from `gateway.policy.tokenBudget` (default 1,000,000 per hour), `key: apiKey.user_id`. Every virtual key gets its own bucket of the same size, per proxy replica.
- **Key entries.** `install.sh` writes one entry per chart agent into the ConfigMap `llm-api-keys`: `{"keyHash":"sha256:...","metadata":{"user_id":"<agent>"}}`. The control plane writes the entries of definitions into `llm-api-keys-control-plane` (`services/control-plane/internal/adapters/agentgateway/agentgateway.go`), with optional `team` and `project` copied from the reserved labels. The admission guard pins each entry to one exact form with a regular expression (`charts/openagentix/templates/control-plane-guard.yaml`, the key ConfigMap rule). The metadata is a free map for the gateway (comment in the adapter).
- **The gateway's schema allows more.** The file `agentgateway.dev_agentgatewaypolicies.yaml` in the `agentgateway-crds` chart v1.7.0, the version `components/model-gateway/install.sh` pins (the chart pins nothing, and the CRD is not vendored in this repository), has `spec.traffic.rateLimit.conditional`: a list of at most 16 entries, each a CEL `condition` and a `policy` with `local` limits; the first matching entry applies; one entry without a condition may be last, as the fallback. Each `local` entry has `tokens` or `requests`, `unit` (`Hours`, `Minutes`, `Seconds`) and an optional CEL `key`; "when unset, all requests share one bucket". The same description says token counts are known only when a request completes, so a token limit applies to later requests, and that each proxy instance keeps a bounded number of buckets per rule and drops the least used ones. This was read in a locally downloaded copy of that chart, in the schema only, and an independent review read the same file from the Helm cache. The slice 2 spike then applied such a policy to agentgateway v1.7.0 on a cluster; see "Spike results".
- **The use cases.** Each runs under the one budget. The bank README: "No per-agent budget: the gateway has one token budget number for every key". ADR 0026 section D named this record as the follow-up, "starting with a spike on whether agentgateway v1.7.0 can set a local token limit per key value". ADR 0017 (proposed) leaves a budget per schedule to the `Budget` kind.
- **Labels decide nothing.** ADR 0012, change 12: anyone who can write an object can set `openagentix.io/team` and `openagentix.io/project`, so they never decide access or billing on their own. A budget must not follow from them.

The problem: a platform team cannot give the bank's dispute agent a smaller budget than the demo assistant, or cap the three agents of one use case together. A runaway agent on a real model spends up to the shared default per hour.

## Spike results (slice 2)

Recorded in `docs/diary/features/adr-0029-gateway-spike.md` (PR #264, branch `test/260-262-adr-spikes`). Runs 46098251670 and 46099570137 of the `e2e` workflow (input `adr_spikes`), on a hosted runner, one kind node, agentgateway v1.7.0, the stub model behind a recording stand-in, no paid call. The spike patched `spec.traffic.rateLimit` of the live policy by hand with four conditional entries (two per-key classes, one shared class, a fallback) and left `apiKeyAuthentication` and `retry` as the chart renders them.

| Question | Answer |
|---|---|
| Does a policy expression see a per-key metadata member? | Yes. `apiKey.budget_class == "alpha"` matched; the policy was `Accepted` and `Attached`; each key was refused at its own class limit |
| A key without the member? | The fallback entry, with its own bucket per key. A class that matches no condition behaved the same. No error, no deny |
| A class change? | A fresh full bucket the **first** time a key meets a class (the first call was admitted about 2 s after the ConfigMap edit). Moving back to a class the key has used gives no refill: the gateway keeps a bucket per class and key |
| `per: class` with no `key`? | One bucket for the class: after one key was refused, the other key of the class was refused too |
| With API key auth and retry in one policy? | Yes. No key or an unknown key: 401. A spent bucket: 429 with `x-ratelimit-limit`, `x-ratelimit-remaining: 0` and `retry-after`, one gateway log line, and no request reached the model, so the policy's retry did not resend a gateway 429 |
| K parallel calls against a nearly empty bucket? | **All admitted**: 5 of 5, 10 of 10, 20 of 20 (twice) with one call of headroom left. A sequential caller got one. After the bucket was refused, 10 parallel calls got 10 times 429 |
| Restart and replicas? | A deleted proxy pod came back with full buckets. With two pods, each counted alone (each admitted the full limit when addressed directly) |

Not covered by the spike: the chart render and the admission guard of this record (the policy was patched by hand); retry of an **upstream** 429 together with a conditional limit (the stub never answers 429); how many buckets a replica keeps before it drops the least used; two replicas behind the Service (each pod was addressed directly); a slow or streaming model (the stub answers at once, so real overlap is larger); more than one run of most checks; small limits only (a stub call counts about 74 tokens).

What this means: option C stands, and the fallback to option D is not needed. The limit is real but soft: per replica, emptied on restart, counted after a call, and open to every call already in flight.

### What a budget class is good for, and what it is not

Good for:

- **Stopping a runaway agent within about one burst.** An agent that loops spends its class and then gets 429 on every call until the window refills, without any controller action.
- **Keeping tenants roughly apart.** One agent of a per-agent class cannot spend the hour of another key. Agents of a shared class can.
- **Making the spend of a use case predictable to within one burst**, per replica.

Not good for:

- **A spend cap.** It is not one. The overshoot is the calls in flight when the bucket runs out, a restart refills every bucket, and N replicas allow N times the class. Money stays out (ADR 0009).
- **A limit per run or per schedule** (ADR 0012, ADR 0017).

### Can the overshoot be made smaller cheaply?

Only partly. The overshoot is "model calls in flight for this key when the bucket runs out, times the size of a call". One run of an agent is expected to make its model calls one after another (not measured; parallel tool calls inside one run were not looked at), so the calls in flight are roughly the runs of that agent running at the same time. Two cheap brakes exist:

- **Fewer runs at once.** ADR 0027 (proposed) gives event callers a `rate` and a `maxInFlight` at the A2A gate. `rate` bounds how many runs an event caller starts per minute, and that is the brake to reuse. `maxInFlight` does not bound running tasks once the call returns at once (ADR 0027's spike: `returnImmediately` returns in under a second), so it does not help here. A per-agent limit on runs that are running needs the runtime, not the gate; it is left to `AgentRun` (0.4) and queueing (0.5).
- **A shorter window beside the hourly one.** A class could carry a second, per-minute entry in the same `local` list, so a burst is refused within a minute instead of after the hour's budget is gone. Whether two `local` entries in one conditional policy both apply was **not** tested; it is question 3 below and a check of slice 3.

### Example classes, from measured demand

Recorded per-run totals on a real model, from the gateway's token metric (the use case READMEs, sections on measuring a pass rate, and the row "Real-model evaluation path for the three use cases" of `what-works.md`, PR #263):

- **Bank** (`dispute-agent`, five cases): run 1 used 636,561 input tokens (517,233 of them cache reads) and 24,936 output, about 660,000 in all. Run 2 used 351,505 input and 11,232 output before the budget ended it. The README: one key cannot do two full runs in an hour.
- **Equipment** (`service-agent`, seven cases): 440,375 input and 16,281 output in run 1, 471,973 and 16,885 in run 2, so about 460,000 to 490,000 per run. Two runs fit in an hour, a third does not.
- **Software organisation** (`pod-rca`, eight cases): input 186,672, 226,312 and 210,169, output 15,008, 16,700 and 15,103, so about 200,000 to 240,000 per run.

Cache reads count against the budget: the bank's second run was stopped by the hourly budget after the first. Per case was not measured, and these are a few runs each, not a rate. Examples the use case values can start from:

| Class | `tokens` per `Hours` | `per` | Meant for |
|---|---|---|---|
| `case-agent` | 800000 | `agent` | one case agent: one bank run (about 660,000) or one equipment run (about 490,000) an hour, and a loop is stopped inside the second run |
| `case-agents-shared` | 1500000 | `class` | the bank and equipment agents together: one cap for both use cases |
| `diagnostic-agent` | 300000 | `agent` | the read-only root-cause agent: one run of eight cases (about 200,000 to 240,000) an hour |
| `demo` | 100000 | `agent` | the quick start agent, where a person asks a few questions |

These are starting points from those few runs, not fits. They are read again when tokens per case are measured.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Do nothing | Nothing to build | Every agent has the same budget; a use case cannot be capped | `gateway.yaml` |
| B. One `AgentgatewayPolicy` per agent | Simple per agent | The values already warn that several policies can overwrite each other; the controller would write a gateway policy, which the guard and ADR 0007 do not allow | `values.yaml` comment on `gateway.policy.name` |
| C. Conditional entries in the one policy, one per budget class, keyed on a class name in the key's metadata; chart agents name a class, definitions get the operator's one class for definitions | One policy, still owned by Helm; the controller writes only a class name into an entry it already writes; a class can be per agent or shared, which gives a per-use-case cap for chart agents | CEL sees `apiKey.budget_class` (spike, v1.7.0); at most 15 classes; local limits per replica, lost on restart | The v1.7.0 CRD schema |
| D. Conditional entries keyed on `apiKey.user_id` lists | No metadata field needed | Helm must list every agent; definitions are created after the render, so they cannot be listed | Same schema |
| E. Global rate limiting with an external rate limit service (`rateLimit.global`) | Shared across replicas, survives restarts | A new upstream component (a rate limit server and its store) | Same schema; out of scope by the rule of this record |
| F. The full `Budget` kind of ADR 0009 now | Scope, window, action, alerts, money | A new kind, a reconciler for spend, alert rules; larger than the use cases need | ADR 0009 |

## Decision

Option C. The spike showed that CEL reads the metadata member, so option D is not needed.

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
      definitions: ""          # the class of every AgentDefinition; empty: the default budget; must be a per: agent class
```

| Value | Rule |
|---|---|
| `budgetClasses[].name` | DNS label, at most 40 characters, unique. `default` is reserved |
| `budgetClasses[].tokens` | 1 to 2,147,483,647 (the CRD's 32-bit integer) |
| `budgetClasses[].unit` | `Hours`, `Minutes` or `Seconds`, as the CRD. Quoted in values |
| `budgetClasses[].per` | `agent` or `class`, required. No default, so a misspelt field fails the render |
| list length | At most 15, so that the classes and the fallback fit the CRD's 16 entries |
| `agents[].budgetClass` | Must name a class; the render fails otherwise |
| `controlPlane.policy.budgetClasses.definitions` | Empty, or the name of a class with `per: agent`. A class with `per: class` is refused here (see "Shared classes"). One value, because definitions live in exactly one agents namespace today (the guard pins entry names to `<agents namespace>.<name>`); a map by namespace comes with more than one namespace (roadmap 0.7) |

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
- **Definitions.** The controller writes the class of `controlPlane.policy.budgetClasses.definitions` as `"budget_class":"<name>"` at the end of the metadata of the entry it already writes. It reads no Secret. A definition cannot choose its class: a class chosen in a spec could be switched to get a full bucket, because each class is a separate rule, and any author could pick the largest class on the list. No new spec field; one can come with the `Budget` kind.
- **The guard.** When `definitions` is set, the key ConfigMap rule accepts one more optional member at the end of the metadata, `"budget_class"`, whose value must be exactly that one class, rendered literally into the rule. When it is empty, the rule is rendered exactly as today.
- **Status.** A new public fact, `status.budget.class`: the class written to the key entry, or `default`. It says what was written, not that the gateway enforces it. Enforcement is shown only by the live proof.
- Labels (`openagentix.io/team`, `openagentix.io/project`) never choose a class.

### Shared classes

A class with `per: class` has one bucket for every key that names it. That is how a use case gets one cap for all its chart agents. It is also how one agent of the class can spend the others' budget. So in this record only the operator's chart agents may name a shared class; `definitions` refuses one. A later record can open it with a per-namespace or per-team scope, when the `Budget` kind exists.

### Limits, stated plainly

- **Local, per replica.** Each gateway proxy replica counts on its own (shown with two pods). Two replicas double the budget. The installs proven so far run one proxy replica; the number is set by the gateway, not by this record.
- **Lost on restart.** A gateway restart empties the counters, so every bucket is full again (shown).
- **Late.** Tokens are counted when a call completes, so the call that crosses the limit is allowed, and the next is refused with 429 (shown: two calls of 74 tokens passed a limit of 100).
- **Parallel calls.** Calls in flight are all admitted before their tokens are counted: in the spike 20 of 20 parallel calls passed with one call of headroom left. So K parallel calls can pass a limit by up to K times the largest call. With a slow or streaming model the overlap is larger.
- **Class changes.** A key that moves to a class it has not used starts with a full bucket; moving back to a class it has used does not refill (shown). That is why a definition cannot choose its class.
- **Per tenant.** A class for each agent gives every definition its own bucket, so it does not cap a namespace: N definitions may spend N times the class. N is bounded by the definitions quota (`controlPlane.maxDefinitions`, a ResourceQuota on `count/agentdefinitions.openagentix.io`, default 50).
- **Soft across restarts and replicas.** With every item of this list, the budget is a soft bound, not a hard limit. The docs say "per key, per gateway replica, refilled on restart".
- **Bucket eviction.** The CRD says each replica keeps a bounded number of buckets per rule and drops the least used. How many is *unverified*. A dropped bucket starts full again.
- **Tokens only.** No money, no day or month window (the units stop at hours), no per-run or per-schedule limit (ADR 0012, ADR 0017). Cost per agent stays visible in the gateway metrics (ADR 0003).
- **Not a security boundary on its own.** It bounds spend by a mistaken or misled agent. Together with the A2A gate and the per-caller limits of ADR 0027 (proposed) it bounds how fast a caller can make an agent spend.

## Consequences

- Possible: a smaller budget for an agent that acts on records, a larger one for a busy assistant, one cap for all chart agents of a use case, a budget for definitions chosen by the operator.
- Ruled out for now: money limits; day or month windows; budgets shared across replicas; shared classes for definitions; a class chosen in a definition's spec or by a label.
- Harder: the one gateway policy gets a list the operator must keep under 16 entries.
- Security impact: the operator decides every limit; a definition cannot choose a class; the controller writes one more name into an entry it already writes, checked by the guard. Nothing new leaves the cluster. No secret is read.
- Compatibility: none for existing installs. Default render unchanged. An agent that gains a class gets a new key entry text; its key value does not change.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0009 | `Budget` (scope, limit, window, action) is still the later kind. A `Budget` object will map to a class (scope to the keys, limit and window to `tokens` and `unit`) and add alerts and money. This record is its adapter primitive |
| ADR 0012 | Labels never decide billing; the operator chooses the class (chart values for chart agents, `definitions` for definitions) |
| ADR 0017 (proposed) | A schedule runs on its agent's key, so it spends from its agent's class. A budget per schedule is still out. ADR 0017 calls the per-key budget a hard limit; with the limits above it is not, and 0017's text should say "the per-key budget, per gateway replica". That correction belongs in PR #123, by its author |
| ADR 0026 | Section D named this follow-up |
| ADR 0027 (proposed) | Per-caller rate and open-call limits at the gate bound how fast runs start; this record bounds what an agent spends |

## Slices

Each slice is one pull request, tests first.

1. **This record.** Docs build.
2. **Spike (done, see "Spike results").** On a throwaway kind cluster with its own kubeconfig, stub model, no paid call. It patched a hand-written conditional policy into the live gateway policy; the chart render is checked in slice 3. Then each question is answered yes or no in the diary, with the requests, the 429 answers and the gateway log as evidence:
   - Does CEL see `apiKey.budget_class`?
   - A key **without** the member: fallback, error, deny, or a shared bucket?
   - A key whose class changes: a fresh bucket? (A fresh bucket the first time a key meets a class; no refill on a move back.)
   - `per: class` with no `key`: one bucket.
   - Restart: buckets full again.
   - `conditional` together with `apiKeyAuthentication` and `retry` in one policy: is a gateway 429 retried by the same policy?
   - Overshoot: 5 calls in parallel against a small limit. How many are admitted?
   CEL sees the member, so option D is not needed.
3. **Chart and installer.** Values, refusals, the conditional render, the fallback, the annotation, `install.sh` metadata, the guard's optional member. Chart tests: byte-identical default, quick start and full demo renders; one test per refusal; 15 classes render and 16 fail; the guard's rule is unchanged with `definitions` empty. `make test-apiserver`: the rendered policy passes a server-side dry run against the v1.7.0 CRDs. If question 3 is answered yes: a class with a per-minute entry beside the hourly one, checked live with the stub model (both entries apply).
4. **Controller.** The class from `definitions`, the entry, `status.budget.class`. Unit tests, guard tests (an entry with a class other than `definitions` is refused; a `per: class` class is refused at render), the field in the console's read-only view.
5. **Use cases.** The three reference agents get classes in their values (a per-agent class each, one shared class for the bank and equipment agents together as an example). Live proof with the stub model: each agent gets 429 at its own limit; the full demo assistant is unaffected. Diary and `what-works.md` row with the limits above.

## Not checked / open points

- *Unverified*: the number of buckets a replica keeps; retry of an upstream 429 with a conditional limit; two replicas behind the Service; overshoot with a slow or streaming model; two `local` entries in one conditional policy; the chart render and the guard of this record.
- Read again before quoting: the agentgateway version pinned by the installer and its `rateLimit` fields.

## Questions for the maintainer

1. **Budget classes now, as the first slice of `Budget`, instead of waiting for the kind?** Recommended: yes. The spike shows the gateway does it in the one policy, and the reference use cases need a brake before a real model runs unattended. Docs call it a soft limit, never a spend cap.
2. **One operator-chosen class for all definitions, no spec field?** Recommended: yes. The spike confirmed that a key gets a fresh bucket the first time it meets a class, so a class chosen in a spec could be switched to get more.
3. **An optional per-minute entry in a class, beside the hourly one, to stop bursts sooner?** Recommended: yes if slice 3 shows that two `local` entries in one conditional policy both apply; otherwise drop it.
4. **The default budget stays 1,000,000 tokens per hour per key?** Recommended: yes for compatibility. The recorded runs fit it (one bank run, two equipment runs or about four root-cause runs an hour per key); the use case values set a class.
5. **Money limits.** Recommended: out of this record. They need spend read back from the gateway's metrics and a controller that lowers a limit, which ADR 0009 describes; and any price list is owner-gated.

## Review notes

An independent review (2026-11-28) asked to drop `spec.budget.class` and the global allowed list (a definition author could pick the largest class, and switching classes refills the bucket), to map classes per namespace instead, to add the parallel, class change and per tenant limits, to say where the schema was read and that the CRD is not in this repository, to note the "hard limit" wording of ADR 0017, and to require the spike before acceptance. This text takes all of it. No point of the review was rejected.

**Re-check (2026-11-28).** The reviewer's re-check asked for seven text changes after the spike, and all seven are in: stale "unverified" and fallback wording removed; slice 2 says the spike patched a hand-written policy; `byNamespace` and `default` replaced by one value, `controlPlane.policy.budgetClasses.definitions`, because definitions live in one namespace; the per-tenant limit names the definitions quota; the example classes cite the recorded per-run totals (PR #263) instead of unrecorded figures; the "tenants apart" line is limited to per-agent classes.
