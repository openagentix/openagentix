# ADR 0027: event triggers, how a system starts an agent run through the A2A gate

Status: Proposed, spike required (slice 2 must be in the diary before this is accepted)
Date: 2026-11-28
Issue: https://github.com/openagentix/openagentix/issues/229 (reference use cases)
Replaces: none. Builds on ADR 0006 (the A2A gate and its caller rules), ADR 0002 (schedules), ADR 0013 (one focus) and ADR 0026 (use case wiring). Gives the first form of the `Trigger` that ADR 0012 reserved, without a new kind. Fits ADR 0016 (`AgentAccess`, proposed, PR #121) and ADR 0017 (`Schedule`, proposed, PR #123). See "Relation to other records".

A system of record (a case system, a machine fleet service, an alert router) starts an agent run by calling the A2A gate as a caller whose rule has a new, optional `event` block. The block pins the message to one short ASCII text that matches an operator's pattern in a narrow grammar the gate checks (an identifier, never free text), drops repeats of the same event id inside a window, limits the rate and the number of open calls per caller, and adds the event id to the audit line. A sender that cannot speak A2A keeps the existing signed webhook path of the channels component. No new resource kind, no new service. Off by default. Nothing here is built. Everything is *unverified* until the slices below are done.

## Context

### How a run starts today

Read in this repository on 2026-11-28.

| Door | What starts it | Payload | Where |
|---|---|---|---|
| A person | `hack/ask.sh` asks for a token with `kubectl create token` and opens a `kubectl port-forward` to the gate | any text the person types | `hack/ask.sh`; `ctl.sh ask` in each use case |
| A schedule | a CronJob runs `tools/a2a-call` | a fixed prompt from a ConfigMap, no payload | `charts/openagentix/templates/schedules.yaml`, ADR 0002 |
| A signed webhook | Agent Kourier 0.6.0 verifies an HMAC or a token, extracts fields, matches a trigger, renders a prompt template and calls the gate with the binding's key | named fields of the JSON body, placed by the template | `charts/openagentix/templates/channels.yaml`, `components/channels/demo-values.yaml`, `docs/diary/features/channels.md` |
| Any in-cluster workload | a caller rule in `governance.a2a.callers[]`, its namespace in `networkPolicy.extraA2ACallers`, a projected token with the audience `openagentix-a2a` | any text, up to the gate's body limit | `charts/openagentix/values.yaml` (`callers`), `services/a2a-gate/` |

What the three use cases do now:

- **Equipment.** `ctl.sh fault <serial> <code>` posts the telematics fault to the records service through a port-forward (REST listens on the pod's loopback), which opens a case or reuses the open one (`POST /faults`, answer `deduplicated: true|false`). The script then prints `next: ctl.sh ask "Work case SVC-..."`. A person, or the fleet sweep schedule, starts the run (`examples/use-cases/equipment/ctl.sh`, `send_event`; README "What is not proven").
- **Bank.** The records service has `POST /cases` (`examples/use-cases/records/internal/bank/rest.go`). Nothing tells the agent that a case was filed. The README lists "No event trigger (a signed webhook on `case.created`)" under "What is not proven".
- **Software organisation.** "No alert trigger (a signed webhook) and no incident record: the agent is started by a person through the gate" (`examples/use-cases/software-org/README.md`).

### What the gate checks today

From `services/a2a-gate/internal/gate/gate.go`, `rules/rules.go` and `config/config.go`:

- The caller authenticates with a projected ServiceAccount token (TokenReview, audience `openagentix-a2a`) or a static key whose SHA-256 is in a mounted Secret.
- The rule names the agents, a user id rule (exactly one of `exact`, `prefix`, `fixed`) and the A2A methods (default `SendMessage`, `SendStreamingMessage`). Unknown fields in the rules file are refused, so the gate does not start.
- On the JSON-RPC route the whole body must fit in the first 64 KiB the gate reads (`SniffBytes`), so the method is checked on the exact bytes the agent reads. The body limit is 8 MiB (`MaxBody`).
- At most 128 requests are open at once for all callers together (`MaxInFlight`); the next gets 503. Container agents have their own pool and a cap per agent.
- The gate keeps no state for each caller: no rate per caller and no memory of an earlier request. (It caches TokenReview answers for 30 s and keeps the open-call slots of each container agent.) The shared slot is taken before authentication.
- The audit line has caller, agent, user id (hashed by default), `contextId`, trace id, method, status, reason and duration (`auditRec`), never message text.

### What the channels webhook gives, and its limits

From `docs/diary/features/channels.md` and the Kourier spike recorded there:

- HMAC or token verification per connection, field extraction from the JSON body, a trigger `match`, a prompt template that puts the event's text in an untrusted data block, and limits per binding (`rateLimit.maxRuns`, `per`, `maxConcurrent`, `maxRunsPerDay`).
- The duplicate check lives in memory; its key is *unverified* in public notes. Excess events are dropped and the sender still gets 200.
- Every event of a binding runs as the binding's one fixed user id.
- A binding names a chart agent (`agents[].name`); the render fails otherwise. The chat listener is a ClusterIP Service; a sender outside the cluster needs an Ingress the operator adds.
- Kourier is 0.x with one maintainer.

### What an external system must do today, and what goes wrong

To start a run with a payload, a system must either sign a webhook to Kourier (and live with the limits above), or run in the cluster as a gate caller and send `SendMessage` with the payload as message text. In the second case:

1. **The payload becomes the instruction.** Whatever text the sender puts in the message is what the agent reads as the user's request. A case system that copies a customer's words into the message hands the customer the agent's instruction channel. Both records services label customer text `untrusted_` in their tool results; the message bypasses that.
2. **A repeat is a new run.** A retry after a timeout, a restart of the sender, or a replayed request each start a run and spend tokens.
3. **Nothing bounds a loop** except the agent's hourly token budget. A sender with a bug can start runs as fast as the gate admits them.
4. **The call blocks for the whole run.** `tools/a2a-call` waits for the task to end. A sender that keeps a connection open for minutes per event needs its own worker pool.
5. **The audit line cannot say which event started a run.** It has the caller and the conversation id, not the sender's event id.

The runtime facts that frame any design: a turn that is running when the runtime restarts is lost and reported as failed (ADR 0012, "Limits and risks"); `a2a-call` sends no `CancelTask` (ADR 0017). So delivery cannot be exactly once. The work an event starts must be safe to repeat, which ADR 0012 already asks of products.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Do nothing; document the two paths | Nothing to build | The five faults above stay; the use cases keep a person in the loop for every event | This section |
| B. The channels webhook as the only event door | Exists and was proven live once (a signed webhook ran a turn, a bad signature got 401) | Duplicate check in memory and by body hash; excess dropped with 200, so a sender cannot back off; one user id per binding; chart agents only; a 0.x upstream on the path of every event; the sender's fields can reach the prompt template outside the data block if the template puts them there | `channels.md`, `channels.yaml` |
| C. An `event` block on a gate caller rule: a pinned message shape, a duplicate window, a rate and an open-call limit per caller, the event id in the audit line | Uses the identity, the agent list, the network policy and the audit the gate already has; the sender is a workload with a Kubernetes identity, no shared HMAC secret; the message carries an identifier, so free text stays in the system of record behind `untrusted_` labels; 429 with `Retry-After`, so the sender can back off | Code in the gate (it is standard library only and stays so); state in the gate's memory (lost on restart, per replica); a new field in the rules file and in chart values; the gate gets a parser for the message shape | `gate.go`, `rules.go`, `config.go`, the use case services |
| D. A `Trigger` kind and an intake service that the controller writes | One object per trigger with status | A new kind, a new network service, a new adapter; the run it would create (`AgentRun`) does not exist (0.4); larger than the use cases need | ADR 0012 reservation, ADR 0013 release plan |
| E. The platform's own webhook receiver | No dependency on Kourier | A second webhook stack beside Kourier, with signatures, replay windows and an Ingress story to own | Compared with B |
| F. Wait for `AgentRun` (0.4) | One run record for every source | Leaves the use cases without triggers for a release; the gate checks of C are needed by any run source anyway | ADR 0013 |

## Decision

Option C, with B kept for senders that can only sign a webhook. No new kind.

The pattern is: **the event lands in the system of record first, and the system of record is the caller.** An outside source (a machine, a card network, an alert) talks to the system that owns the case, which validates it with its own rules and stores it. That system then asks the agent to work the case by its identifier. The agent reads the case through its tools, where text from people is labelled as untrusted. This keeps the platform out of every domain's input validation and keeps free text out of the instruction channel.

### The caller rule

A new optional member `event` of a caller in `governance.a2a.callers[]`:

```yaml
governance:
  a2a:
    callers:
      - name: kestrel-fault-events
        serviceAccount: {namespace: kestrel-records, name: records-events}
        agents: [service-agent]
        # no methods, no memory, no key: an event caller sends SendMessage only; userId is optional and fixed
        event:
          text: 'Work case SVC-[0-9]{4}-[0-9]{4}'     # the gate anchors it: the whole message text must match
          dedupeMinutes: 60                           # a repeated event id inside this window is not forwarded
          rate: {perMinute: 6, burst: 3}              # per caller, per gate replica
          maxInFlight: 2                              # open calls of this caller at the gate
```

| Field | Rule |
|---|---|
| `event` | Optional. Absent: the rule behaves as today and the rendered rules file is byte for byte what it is today |
| `event.text` | Required, at most 256 characters. The chart compiles it with `mustRegexMatch` (plain `regexMatch` hides compile errors) and refuses the tokens `|`, `*`, `+`, `.`, `{n,}`, `(?`, `\s`, `\S`, `\W`, `\D`, `\p`, `[^`. The gate is the authority: it wraps the pattern as `^(?:<pattern>)$`, parses it with Go's `regexp/syntax`, and refuses to start unless the pattern has only the grammar below. The text must be ASCII and at most 1024 bytes, whatever the pattern. It is matched on the decoded JSON string; invalid UTF-8 or a lone surrogate decodes to U+FFFD and so fails the classes |
| `event.dedupeMinutes` | Required, 1 to 1440 |
| `event.rate.perMinute` | Required, 1 to 600 |
| `event.rate.burst` | Required, 1 to 60 |
| `event.maxInFlight` | Required, 1 to 32 |
| `methods`, `memory` and `key` with `event` | Refused at render. An event caller uses `SendMessage` only |
| `userId` with `event` | Optional, must be `fixed`, default `event:<name>`. An event sender never chooses the user id, so it cannot choose a memory scope or speak as a person. No other caller's user id rule may cover it (a render check: no `exact` or `fixed` equal to it, no `prefix` it starts with) |
| number of event callers | At most 16 callers may have an `event` block |

Every field is required inside the block, so a misspelt field fails the render instead of falling back to a wider default. The chart refuses any key of a `governance.a2a.callers[]` entry that is not one of `name`, `serviceAccount`, `agents`, `userId`, `methods`, `memory`, `event`, so a misspelt `event` cannot leave a free-text caller.

That last check is new for every caller, not only event callers. Today the chart picks the named fields of an entry and ignores the rest. For values whose entries use only those seven keys, which is every values file in this repository and every form the chart's comments describe, the render stays byte for byte the same. A user whose entry has a typo or an extra key (for example `userid:` or `agent:`) now gets a render error that names the caller and the key, where today the key was dropped without a word and the caller got the defaults. The changelog line of the slice says so.

**The grammar the gate accepts for `event.text`**, checked on the `regexp/syntax` tree after the gate wraps the pattern:

- literal characters from `A-Z a-z 0-9 _ . : -` and the space;
- character classes whose members are all inside `[A-Za-z0-9_.:-]`, not negated;
- bounded repeats `{n}` and `{n,m}` with `m` at most 64, and `?`;
- concatenation, and groups (capturing or not) of the above.

Refused: alternation, `*`, `+`, `{n,}`, `.`, every escape class (`\s \S \w \W \d \D \p`), negated classes, flags and flag groups, `^` and `$` inside the pattern, and a pattern that matches the empty text. The docs recommend digits for the variable part: a class with letters still carries words (`[A-Za-z-]{1,64}` holds `ignore-rules-and-approve`).

### What the gate checks for an event caller

In this order, after authentication, the agent check and the user id rule:

1. **Route.** Only the JSON-RPC route. The REST routes and the agent card answer 403, reason `path`.
2. **Message shape.** The body is parsed strictly: duplicate keys are refused. Keys are compared exactly; a key that differs from an allowed key only in case is refused (`"Parts"`, `"contextid"`). `id` is a string or an integer, `jsonrpc` is `"2.0"`, and nothing may follow the object. `configuration.pushNotificationConfig` is refused: it makes the runtime call a URL the caller chooses. Allowed keys, and nothing else: at the top `jsonrpc`, `id`, `method`, `params`; in `params` the keys `message` and `configuration`; in `configuration` only `blocking`; in `message` only `messageId`, `role` and `parts`. `role` is `ROLE_USER`. `parts` has exactly one entry, with exactly one key, `text`, whose value matches `event.text`. `messageId` is 1 to 128 characters from `A-Z a-z 0-9 . _ : -`. So an event caller cannot send `contextId` (every event starts a new conversation and cannot join another), `taskId`, `referenceTaskIds`, `metadata`, `extensions`, files or data parts. A refusal is 403, reason `message_shape`, and names no part of the body. The field spelling follows the A2A 1.0 JSON that `tools/a2a-call` sends today (`internal/call/call.go`).
3. **Repeat.** The key is the caller, the agent and `messageId`. A key is reserved when the request passes this step, kept for `dedupeMinutes` only when the upstream answers 2xx, and released on every refusal of steps 4 and 5 and on every upstream error. A key that is kept gives 409, reason `duplicate`, and the sender treats 409 as delivered. A key that is reserved by a request still open gives 429 with `Retry-After: 1`, reason `duplicate_open`. The sender derives `messageId` from its record; a new id on every attempt (as `tools/a2a-call` makes) gets past the window. The gate keeps at most 4096 keys per caller; the oldest go first.
4. **Rate.** A token bucket per caller with `perMinute` and `burst`. Every authenticated request of the caller counts, duplicates and shape refusals included. Over the limit: 429 with `Retry-After` in whole seconds, reason `rate`.
5. **Open calls.** At most `maxInFlight` open requests of this caller. Over: 429 with `Retry-After: 1`, reason `caller_busy`. The open call takes one of the shared slots as today, so an event caller can never hold more than `maxInFlight` of them. The shared slot is taken before authentication, so this protects other callers from the event caller, not from everyone.

A repeat key is reserved only for a request that passed steps 1 and 2, so a malformed request does not use up the window of a good one. It still counts for the rate.

**State and its limits.** The repeat keys, the buckets and the counters are in the gate's memory, per process. The chart runs one gate replica today (`replicas: 1`; more replicas are issue #199). With N replicas the limits are N times the values (`perMinute`, `burst`, `maxInFlight`), and a repeat can land on another replica. A gate restart, and every `helm upgrade` that changes the rules (the gate pods roll on the rules checksum), clears every window. With `blocking: false`, `maxInFlight` bounds submissions, not running tasks: concurrent runs are about the rate times the run length, and the gate does not bound them. Memory is bounded by 16 event callers times 4096 keys; slice 2 measures it against the gate's 64Mi limit. That is why the window is a defence against bursts of retries, not a promise. The promise the platform makes is weaker and stated: **a repeated event may start a second run.** The work must be safe to repeat in the system of record. In both records services it is: a second run of the same case reads the case as it is, a second approval request for a case that has one pending is refused, and a write after a request supersedes it, so the approver never decides on a stale payload.

### Blocking and the result

The sender sends `configuration.blocking: false` (the exact A2A 1.0 field name is a spike question: `tools/a2a-call` sends no `configuration` today), so the call returns as soon as the runtime has accepted the task and the sender needs no connection for the length of a run. A 2xx then means "the task was accepted", not "the run happened". Whether kagent 1.0.1 honours `blocking: false`, and what it does with a blocking call whose client goes away, is *unverified*; slice 2 measures both before the gate code is written. If kagent ignores it, the record is amended (for example the gate answers for the sender and keeps the upstream call open, which costs a slot for the length of the run).

The result of an event run is what the agent writes in the system of record through its tools: a diagnosis, a draft, an approval request. The answer text is not sent back to the sender and is not in any log.

### Payload, trust and what reaches the model

- The message is an identifier in an operator's pattern. The pattern is the whole input check the platform does. It is not a sanitiser, and the platform does not promise that a pattern written by the operator is narrow. The docs say: no whitespace classes, no `.*`, one identifier.
- Free text from people stays in the system of record and reaches the model only as a tool result, where the use cases label it `untrusted_`. The platform adds no path that puts event free text into the instruction part of a prompt.
- All events of one caller run as one user id, so they share one memory scope. The chart refuses an event caller for an agent with long-term memory on.
- A sender that must pass free text (an alert summary) uses the channels webhook, whose template places fields in an untrusted data block. That is weaker, and the docs say so.

### Audit

The gate's audit line gets one field, `event_id`: the `messageId`, written only after authentication and only when it passed the shape check (otherwise `invalid`). New reasons: `message_shape`, `duplicate`, `duplicate_open`, `rate`, `caller_busy`. No message text. `messageId` must not carry personal data. The trace id is recorded as today, so a sender that sends a `traceparent` can find its run's trace.

The audit table of a records service and the gate line can then be joined on the record id, which the sender puts in `messageId` (the gate does not log the text), and on time. A direct link from a tool call to the run is the subject of ADR 0028 (proposed).

### Network and authentication

The sender authenticates with a projected token for its own ServiceAccount, audience `openagentix-a2a`. Event callers use a ServiceAccount; the chart refuses a key (it cannot express one for an extra caller today, and a long-lived shared key is what this design avoids). The use cases mount the token with `expirationSeconds: 600`, because a captured request (token and body, plain HTTP inside the cluster) can be replayed while the token lives, and set `podLabels` in `networkPolicy.extraA2ACallers`, because without them every pod of the namespace may reach the gate. The sender's namespace must be in `networkPolicy.extraA2ACallers`; the render already fails when such a namespace has no rule. The gate is not exposed outside the cluster by this record. An outside source reaches its own system of record, which has its own API and its own authentication.

### Off by default

With no `event` block anywhere, the chart renders byte for byte what it renders today, for the default values and every demo and use case values file. The rules file gains an optional member. A gate image older than the rules file refuses to start on the unknown field: it fails closed. Gate image and rules file come from one chart release, so they change together.

### How the use cases use it

**Equipment: a machine fault opens a case and starts the service agent.**

1. Telematics posts the fault to the records service (`POST /faults`), as `ctl.sh fault` does now. The service opens a case or reuses the open one.
2. Only when it opened a new case (`deduplicated: false`), the service writes an outbox row "ask the agent to work SVC-2026-0007" in the same transaction as the case. Outbox rows are written only by the intake routes, never by an MCP tool (the agent's `open_proactive_case` writes none), so an agent cannot start a run for itself.
3. A sender loop in the service reads the outbox and calls the gate as `kestrel-fault-events` with text `Work case SVC-2026-0007`, `messageId` `fault-SVC-2026-0007`, `blocking: false`. On 2xx or 409 the row is done. On 429 or 5xx it waits for `Retry-After` and tries again. So delivery to the gate is at least once, and repeats are dropped at the gate inside the window and are harmless in the record after it. A run that was accepted can still be lost when the runtime restarts, so the service also asks again for a case that is still unworked after a set time (with a new `messageId` that names the attempt, for example `fault-SVC-2026-0007-r2`).
4. A safety-critical fault gets the same message. The agent's step 2 escalates it to a person and drafts nothing (`examples/use-cases/equipment/values.yaml`).
5. A dealer's service request (`POST /requests`) carries a free-text note. The event message still carries only the case id. The note stays in the record and reaches the model as an `untrusted_` field.

The records pod mounts a projected token with the gate audience and gets an egress policy to the gate only. It still has no Kubernetes API right.

**Bank: a new dispute starts the dispute agent.**

The case system files the dispute through `POST /cases`. The records service writes the outbox row in the same transaction (only on this intake route) and sends `Work case DSP-2026-0042`, `messageId` `case-DSP-2026-0042`, as caller `fernvale-case-events` (`text: 'Work case DSP-[0-9]{4}-[0-9]{4}'`, `userId: {fixed: "event:fernvale-cases"}`, `agents: [dispute-agent]`). The dispute agent has no memory, as the chart requires for an event caller's agent. The agent works the case and stops at the approval request, as today. A burst of filings (a fraud ring of five cases) is held to the rate, and the sender backs off on 429.

**Software organisation: an alert.** Alertmanager sends its own JSON and cannot form an A2A message. It uses the channels webhook path (option B) with a token connection, a template that names the workload, and the binding's limits. The limits of that path apply and are stated in the use case's README.

## Consequences

- Possible: a system of record starts an agent run for one of its records, with its own Kubernetes identity, without a person, without free text in the instruction channel, with back-off and with the event id in the audit line.
- Ruled out by this record: free-text event payloads on the gate path; an event that continues an existing conversation; an event caller that picks a user id; streaming or task-reading methods for event callers; the gate exposed outside the cluster; exactly-once delivery.
- Harder: the gate keeps state for the first time. Its memory grows with the number of event callers (4096 keys each, bounded).
- Security impact: a new way for a workload to start agent runs without a person, but only with a caller rule the operator writes, a namespace the operator lists and an agent the rule names. Each event caller is bounded in rate and open calls. Nothing new leaves the cluster. The audit line gains the event id. An independent security review is required before the gate slice is merged.
- Compatibility: none for existing users. Default render unchanged. Existing callers unchanged.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0006 | The gate and its caller rules. This record adds one optional block to a rule |
| ADR 0012 | `Trigger` was reserved for 0.4, creating runs. This record is its first form, on the gate. When `AgentRun` exists, an event call may create a run; the `event` fields stay |
| ADR 0016 (proposed) | In 0.3 `event` stays a chart-only caller option, like `memory` in ADR 0016. Moving it into `AgentAccess` needs its own amendment: the grammar check in the controller, a guard denylist, and a reset of windows on a live reload. ADR 0016's reserved user ids derive from chart callers, so `event:` fixed ids are protected from overlap there too |
| ADR 0017 (proposed) | Schedules are the time door, events the system door. They share nothing new. A `Schedule` never sets `event` |
| ADR 0026 | The records services join through `mcp.endpoints`. This record adds the other direction: the service calls the gate |
| ADR 0028 (proposed) | Approval stays in the system of record; an event run ends at an approval request there |

## Slices

Each slice is one pull request that `Refs #229`, tests first, with a changelog line when users can see it.

1. **This record.** Docs build. At least 7 days of review (security model).
2. **Spike, on a throwaway kind cluster with its own kubeconfig** (never the maintainer's cluster), quick start and stub model. Each question is answered yes or no in the diary, with the request, the response and the log lines as evidence:
   - `blocking: false` at kagent 1.0.1: the exact A2A 1.0 field name, whether the call returns at once with a task id, whether the task finishes.
   - A blocking call whose client goes away: does the task finish, cancel or fail?
   - The same `messageId` twice: one task or two?
   - A message with no `contextId`: a new conversation each time? (expected)
   - A body with a case-variant key (`"Parts"`) and with an unknown key: what kagent does. This decides whether the parser differential is real.
   - Gate resident memory with 16 × 4096 keys under the 64Mi limit.
   The answers can change the shape check and the blocking rule.
3. **Gate: the `event` block and the shape check** (security-relevant). Rules parsing and refusals, the strict parser (duplicate keys, key allowlist, one text part, pattern, length), the route rule, the audit field and reasons; chart values, render checks and byte-identical default render. Also the grammar check on the `regexp/syntax` tree, exact and case-variant keys, ASCII, the caller-entry key allowlist, `mustRegexMatch` and the token denylist. Tests: one per refusal with its reason; a body with a second `text` key; `"Parts"`; a `contextId`; a data part; `pushNotificationConfig`; a 1025-byte text; `a|b` and `(?m)` refused at render and at start; `(` refused at render; a caller entry with `evnet:` refused at render; an event caller for an agent with memory refused; the canary text of a refused request in no log line. The chart refuses `event` until slice 4 is merged, or slices 3 and 4 merge before the same release, so no release has an event caller without limits.
4. **Gate: repeat window, rate and open calls** (security-relevant). Tests with a fake clock: reserve, commit on 2xx, release on 429, 5xx and every refusal; a repeat while the first is open gives 429 `duplicate_open`; a repeat inside and after the window; 4096 keys and the oldest dropped; burst and refill; `Retry-After` values; open calls released on every exit path, including a client that goes away; a malformed request counts for nothing; state lost on restart (a test that states it).
5. **Equipment use case on events.** Example code in the records service: the outbox row in the case transaction, the sender loop with back-off, the projected token, the egress policy; values with the caller rule. Live proof on a throwaway kind cluster with the stub model: a new fault starts one run; the reused case starts none; the same event sent twice gives one run and one 409; a burst of ten faults is held to the rate and all ten cases are worked in the end; a case opened by an MCP tool writes no outbox row; a `helm upgrade` that changes the rules clears the window (a stated, tested limit); a free-text dealer note never appears in the gate's or the stub model's logs as part of a message; the audit line has the event id. Diary and `what-works.md` row with the limits.
6. **Bank use case on events.** The same for `POST /cases`, and the fraud ring burst.
7. **Docs for the channels path** for senders that cannot speak A2A (the software organisation alert), with its limits.

## Not checked / open points

- *Unverified*: everything in slice 2; whether the strict parser stays inside the gate's 64 KiB read for every legal message (it should: the text is at most 1024 bytes).
- Run concurrency with `blocking: false` depends on the runtime. With kagent one task runs per session, and every event is a new session.
- Read again before quoting: the A2A 1.0 field names for `configuration.blocking`, and kagent's handling of them.

## Questions for the maintainer

1. **Is "the system of record is the caller" the rule, with the channels webhook only for senders that cannot speak A2A?** Recommended: yes. It keeps input validation where the domain is and gives every event a Kubernetes identity.
2. **Should the gate path ever accept free text in an event?** Recommended: no, not in this record. If a use case needs it, a later record adds a data part that the gate wraps as untrusted, with its own review.
3. **May an event caller also read its task (`GetTask`)?** Recommended: not now. The result belongs in the system of record, and `GetTask` by id needs a check that the task belongs to the caller, which the gate cannot do today.
4. **Is a window in memory, per replica, enough for 0.3?** Recommended: yes, with the stated promise that a repeat may start a second run, the N-replica multiplier, the reset on every rules change, and the reserve, commit and release order. A shared store would be the gate's first dependency and is out of proportion.
5. **Static keys for event callers?** Recommended: no, ServiceAccount only. The chart cannot express a key for an extra caller today, and a long-lived shared key is what this design avoids.
6. **The 7-day review window.** Recommended: keep it. This changes who can start runs without a person.

## Review notes

An independent review (2026-11-28) asked for these changes, and this text takes all of them: the repeat key is reserved, kept only on a 2xx and released on every refusal; the gate anchors the pattern itself and checks a narrow grammar; `mustRegexMatch` at render; unknown keys in a caller entry are refused; event callers are ServiceAccount only; no event caller for an agent with memory; outbox rows only from intake routes, so an agent cannot start a run for itself; the stated limits (replicas, upgrades, `blocking: false`, at least once to the gate only); `messageId` carries the record id for the audit join; `event` stays chart only beside ADR 0016. No point of the review was rejected.
