# ADR 0027: event triggers, how a system starts an agent run through the A2A gate

Status: Proposed (the slice 2 spike ran; see "Spike results")
Date: 2026-11-28
Issue: https://github.com/openagentix/openagentix/issues/229 (reference use cases)
Replaces: none. Builds on ADR 0006 (the A2A gate and its caller rules), ADR 0002 (schedules), ADR 0013 (one focus) and ADR 0026 (use case wiring). Gives the first form of the `Trigger` that ADR 0012 reserved, without a new kind. Fits ADR 0016 (`AgentAccess`, proposed, PR #121) and ADR 0017 (`Schedule`, proposed, PR #123). See "Relation to other records".

A system of record (a case system, a machine fleet service, an alert router) starts an agent run by calling the A2A gate as a caller whose rule has a new, optional `event` block. The block pins the message to one short ASCII text that matches an operator's pattern in a narrow grammar the gate checks (an identifier, never free text). The gate rebuilds the message and its headers itself and never forwards the caller's bytes, asks the runtime to return at once, answers the sender with the task id and state only, limits the rate and the number of open calls per caller, and adds the event id to the audit line. Repeats of one event are left to the runtime, which keeps one run per message id (shown in the spike), and to the system of record. A sender that cannot speak A2A keeps the existing signed webhook path of the channels component. No new resource kind, no new service. Off by default. Nothing here is built. The runtime behaviour it relies on was shown in a spike ("Spike results"); the gate and chart parts are *unverified* until their slices are done.

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
2. **A repeat is a new run** when the sender makes a new message id per attempt, as `tools/a2a-call` does. A retry after a timeout, a restart of the sender, or a replayed request then each start a run and spend tokens.
3. **Nothing bounds a loop** except the agent's hourly token budget. A sender with a bug can start runs as fast as the gate admits them.
4. **The call blocks for the whole run.** `tools/a2a-call` waits for the task to end. A sender that keeps a connection open for minutes per event needs its own worker pool.
5. **The audit line cannot say which event started a run.** It has the caller and the conversation id, not the sender's event id.

The runtime facts that frame any design: a turn that is running when the runtime restarts is lost and reported as failed (ADR 0012, "Limits and risks"); `a2a-call` sends no `CancelTask` (ADR 0017). So delivery cannot be exactly once. The work an event starts must be safe to repeat, which ADR 0012 already asks of products.

## Spike results (slice 2)

Recorded in `docs/diary/features/adr-0027-runtime-spike.md` (PR #264, branch `test/260-262-adr-spikes`). Runs 46098251670, 46099570137 and 46100654827 of the `e2e` workflow (input `adr_spikes`), on a hosted runner, one kind node, kagent controller 1.0.1, the agent `quickstart`, the stub model behind a recording stand-in that holds a marked request for 25 s, no paid call. Most calls went straight to the runtime's A2A port, the port the gate forwards to; one check of the first question and the memory check went through the gate.

| Question | Answer |
|---|---|
| Does the runtime honour a non-blocking send? | `configuration.blocking: false` is **ignored**: the call returned after 25.4 s with the finished task, as with no configuration (also through the gate). `configuration.returnImmediately: true` **is honoured**: an answer after 0.3 to 0.6 s with `TASK_STATE_SUBMITTED` and a task id; `GetTask` then showed `WORKING` and, about 27 s after the send, `COMPLETED`. The run continued after the call returned |
| A blocking call whose client goes away? | The run continued: the model request finished with 200 about 21 s after the client left. The final state of the task was **not** read |
| The same `messageId` twice? | **One run.** The second call returned the same task id and answer (in 0.01 s after the first had finished; by waiting for the same run while it was still running). With the same id and a **different text**, the second call returned the first task, and the new text never reached the model |
| No `contextId`? | Not tested on its own. The one row with a `contextId` also had a made-up `taskId` and was refused (`task not found`) |
| Unknown keys and case variants? | Unknown keys at every level were accepted and ignored. Case variants (`Parts`, `MessageId`, `Params`, `Configuration`) were read as the known key. Of two keys with the same meaning (`parts` and `Parts`, or `text` twice), the later one won |
| Gate memory under a burst? | 15 MiB resident at the highest point, against the 64 MiB limit, for the gate as it is today (300 requests with distinct tokens, then 48 open calls held 25 s). The per-caller state of this record was not measured (it does not exist yet) |

A later check (2026-11-28, a kind cluster with kagent 1.0.1, one agent, one caller with a `prefix` user id rule, two user ids; not in the spike notes): the same `messageId` under two different user ids gave **two separate runs**, and each user got its own answer; the same user repeating the id got the first answer back. So on this version the runtime's check is scoped per user id. Not checked: two agents, a runtime restart.

Not covered: the final task state after a client leaves; `contextId` on its own (the one row with it also had a made-up `taskId`); a repeat sent with `returnImmediately: true` (the repeats of the spike were blocking calls); how long the runtime keeps a `messageId` and whether that survives a runtime restart; the per-user scope with two agents; the length limit of `messageId` in the runtime; the gate memory with per-caller state (16 × 4096 keys was not measured, and is moot now that the repeat window is dropped); a gate-side parser (it does not exist yet); distinct caller rules; a real model with tools; more than one kagent version.

What changed in the decision because of it: the gate asks for `returnImmediately: true`, not `blocking: false`; the gate parses the message, rebuilds it and forwards only its own bytes; the repeat window of the earlier draft is dropped, because the runtime already keeps one run per `messageId` and the gate's window would add only a little (see "Repeats").

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Do nothing; document the two paths | Nothing to build | The five faults above stay; the use cases keep a person in the loop for every event | This section |
| B. The channels webhook as the only event door | Exists and was proven live once (a signed webhook ran a turn, a bad signature got 401) | Duplicate check in memory and by body hash; excess dropped with 200, so a sender cannot back off; one user id per binding; chart agents only; a 0.x upstream on the path of every event; the sender's fields can reach the prompt template outside the data block if the template puts them there | `channels.md`, `channels.yaml` |
| C. An `event` block on a gate caller rule: a pinned message shape that the gate rebuilds, a rate and an open-call limit per caller, the event id in the audit line | Uses the identity, the agent list, the network policy and the audit the gate already has; the sender is a workload with a Kubernetes identity, no shared HMAC secret; the message carries an identifier, so free text stays in the system of record behind `untrusted_` labels; 429 with `Retry-After`, so the sender can back off | Code in the gate (it is standard library only and stays so); a small state per caller in the gate's memory (a rate bucket and a counter, lost on restart, per replica); a new field in the rules file and in chart values; the gate gets a parser for the message shape | `gate.go`, `rules.go`, `config.go`, the use case services |
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
          rate: {perMinute: 6, burst: 3}              # per caller, per gate replica
          maxInFlight: 2                              # open calls of this caller at the gate
```

| Field | Rule |
|---|---|
| `event` | Optional. Absent: the rule behaves as today and the rendered rules file is byte for byte what it is today |
| `event.text` | Required, at most 256 characters. The chart compiles it with `mustRegexMatch` (plain `regexMatch` hides compile errors) and refuses the tokens `|`, `*`, `+`, `.`, `{n,}`, `(?`, `\s`, `\S`, `\W`, `\D`, `\p`, `[^`. The chart is stricter than the gate: it refuses `(?` and an unescaped `.`, which the gate's grammar allows. The gate is the authority: it wraps the pattern as `^(?:<pattern>)$`, parses it with Go's `regexp/syntax`, and refuses to start unless the pattern has only the grammar below. The text must be ASCII and at most 1024 bytes, whatever the pattern. It is matched on the decoded JSON string; invalid UTF-8 or a lone surrogate decodes to U+FFFD and so fails the classes |
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

1. **Route.** Only the JSON-RPC route. The REST routes and the agent card answer 403, reason `path`. In 0.3 an event call to a container agent is refused, 403 reason `agent`: such a runtime may not keep one run per message id or honour `returnImmediately`, and the runtime conformance suite does not cover either yet.
2. **Message shape.** The body is parsed strictly: duplicate keys are refused. Keys are compared exactly; a key that differs from an allowed key only in case is refused (`"Parts"`, `"contextid"`). `id` is a string or an integer, `jsonrpc` is `"2.0"`, and nothing may follow the object. Allowed keys, and nothing else: at the top `jsonrpc`, `id`, `method`, `params`; in `params` only `message`; in `message` only `messageId`, `role` and `parts`. So `configuration` is refused too, with everything in it (`pushNotificationConfig` would make the runtime call a URL the caller chooses); the gate sets the configuration itself in step 3. `role` is `ROLE_USER`. `parts` has exactly one entry, with exactly one key, `text`, whose value matches `event.text`. `messageId` is 1 to 128 characters from `A-Z a-z 0-9 . _ : -`. So an event caller cannot send `contextId` (every event starts a new conversation and cannot join another), `taskId`, `referenceTaskIds`, `metadata`, `extensions`, files or data parts. A refusal is 403, reason `message_shape`, and names no part of the body. The field spelling follows the A2A 1.0 JSON that `tools/a2a-call` sends today (`internal/call/call.go`).
3. **Rebuild.** The gate never forwards the caller's bytes. It builds a new body from the values it parsed and forwards that, with a new `Content-Length`:

   ```json
   {"jsonrpc":"2.0","id":<id>,"method":"SendMessage","params":{"message":{"messageId":"<caller>:<messageId>:<first 16 hex of SHA-256 of the text>","role":"ROLE_USER","parts":[{"text":"<text>"}]},"configuration":{"returnImmediately":true}}}
   ```

   **Headers.** The gate also sets the request headers itself, from an allowlist: `Content-Type: application/json`, `A2A-Version: 1.0`, and the caller's `Traceparent` and `Tracestate` when they are well formed, plus the `X-User-Id` the gate sets as today. No other caller header is forwarded. A request with `Content-Encoding` is refused (reason `message_shape`).

   This is a requirement, because the runtime reads case variants as the known key and lets the later of two keys win (spike): a check on the caller's bytes and the runtime's reading of the same bytes could differ. The forwarded `messageId` carries the caller's name, so two callers never share one, and a hash of the text, so a repeated id with a different text starts its own run instead of returning an earlier task (the runtime returns the first task for a repeated id even when the text differs).
   **Response.** The gate rewrites the runtime's answer for an event caller to the task id and state only: `{"jsonrpc":"2.0","id":<id>,"result":{"id":"<task id>","status":{"state":"<state>"}}}`. A JSON-RPC error becomes its code with the message `refused`. An answer the gate cannot parse, or one over 1 MiB, becomes 502. So no answer text, which may be shaped by untrusted case text, reaches the sender or its logs, also when the runtime returns a finished task (a repeat, or a runtime that ignores `returnImmediately`).
4. **Rate.** A token bucket per caller with `perMinute` and `burst`. Every authenticated request of the caller counts, shape refusals included. Over the limit: 429 with `Retry-After` in whole seconds, reason `rate`.
5. **Open calls.** At most `maxInFlight` open requests of this caller. Over: 429 with `Retry-After: 1`, reason `caller_busy`. The open call takes one of the shared slots as today, so an event caller can never hold more than `maxInFlight` of them. The shared slot is taken before authentication, so this protects other callers from the event caller, not from everyone.

### Repeats

The runtime keeps one run per message id and user id: kagent 1.0.1 returned the same task for a repeated `messageId` from the same user, both after the first run had ended and while it was still running (spike, blocking calls), and kept separate runs for two user ids (later check). So a retry of the same event, with the same `messageId` and text, is expected not to start a second run; with `returnImmediately: true` this is not yet shown, and slice 3 shows it. A gate window would add only two things: protection if the runtime forgets an id (after a restart, or a runtime that does not keep ids, such as a container agent), and a `duplicate` reason in the audit line. Neither is worth the gate's first per-request state, so the earlier draft's window is dropped. The audit join does not need it: it uses `event_id` (below).

**Assumption: the runtime's check is per user id.** The event caller's fixed user id is exclusive (the chart refuses any other caller rule that covers it), so while the runtime scopes message ids per user id, no other caller can take an event's id first and have the real event answered with someone else's task. This record states that dependency instead of adding a gate rule: a gate refusal of foreign message ids would have to cover the REST routes too, and refusing those routes for agents that an event caller names could break existing callers. Slice 3 has a live test that sends one `messageId` under two user ids and fails if the runtime ever answers both with one task. If a runtime upgrade changes the scope, that rule (refuse, for every other caller, a `messageId` that starts with an event caller's name, and the REST message routes to agents an event caller names) becomes required before the upgrade.

What is not known: how long kagent keeps an id, and whether it keeps it across a restart. So the promise stays: **a repeated event may start a second run**, and the work must be safe to repeat in the system of record. In both records services it is: a second run of the same case reads the case as it is, a second approval request for a case that has one pending is refused, and a write after a request supersedes it, so the approver never decides on a stale payload. The runtime conformance suite (ADR 0013) should state whether a runtime keeps one run per message id.

**State and its limits.** The rate buckets and the open-call counters are in the gate's memory, per process: a few numbers per event caller. The chart runs one gate replica today (`replicas: 1`; more replicas are issue #199). With N replicas the limits are N times the values (`perMinute`, `burst`, `maxInFlight`). A gate restart, and every `helm upgrade` that changes the rules (the gate pods roll on the rules checksum), refills every bucket. Because the call returns at once, `maxInFlight` bounds submissions, not running tasks: concurrent runs are about the rate times the run length, and the gate does not bound them. The spike measured the gate as it is today at 15 MiB of its 64 MiB under a burst; the added state is a few numbers per caller.

### Blocking and the result

The gate sets `configuration.returnImmediately: true` (the A2A 1.0 name; kagent 1.0.1 ignores `blocking: false`, spike), so the call returns in under a second with the task in `TASK_STATE_SUBMITTED`, and the sender needs no connection for the length of a run. A 2xx then means "the task was accepted", not "the run happened". A runtime that ignores `returnImmediately` makes the call last as long as the run, which costs one of the caller's `maxInFlight` slots for that time; the docs say so. A client that leaves does not stop a run (spike), so the gate's open-call count is never the number of runs.

The result of an event run is what the agent writes in the system of record through its tools: a diagnosis, a draft, an approval request. The answer text is not sent back to the sender, because the gate rewrites the response to the task id and state (step 3), and it is not in any gate log.

### Payload, trust and what reaches the model

- The message is an identifier in an operator's pattern. The pattern is the whole input check the platform does. It is not a sanitiser, and the platform does not promise that a pattern written by the operator is narrow. The docs say: no whitespace classes, no `.*`, one identifier.
- Free text from people stays in the system of record and reaches the model only as a tool result, where the use cases label it `untrusted_`. The platform adds no path that puts event free text into the instruction part of a prompt.
- All events of one caller run as one user id, so they share one memory scope. The chart refuses an event caller for an agent with long-term memory on.
- A sender that must pass free text (an alert summary) uses the channels webhook, whose template places fields in an untrusted data block. That is weaker, and the docs say so.

### Audit

The gate's audit line gets one field, `event_id`: the `messageId` the caller sent (not the rebuilt one), written only after authentication and only when it passed the shape check (otherwise `invalid`). New reasons: `message_shape`, `rate`, `caller_busy`. No message text. `messageId` must not carry personal data. The trace id is recorded as today, so a sender that sends a `traceparent` can find its run's trace.

The audit table of a records service and the gate line can then be joined on the record id, which the sender puts in `messageId` (the gate does not log the text), and on time. A direct link from a tool call to the run is the subject of ADR 0028 (proposed).

### Network and authentication

The sender authenticates with a projected token for its own ServiceAccount, audience `openagentix-a2a`. Event callers use a ServiceAccount; the chart refuses a key (it cannot express one for an extra caller today, and a long-lived shared key is what this design avoids). The use cases mount the token with `expirationSeconds: 600`, because a captured request (token and body, plain HTTP inside the cluster) can be replayed while the token lives, and set `podLabels` in `networkPolicy.extraA2ACallers`, because without them every pod of the namespace may reach the gate. The sender's namespace must be in `networkPolicy.extraA2ACallers`; the render already fails when such a namespace has no rule. The gate is not exposed outside the cluster by this record. An outside source reaches its own system of record, which has its own API and its own authentication.

### Off by default

With no `event` block anywhere, the chart renders byte for byte what it renders today, for the default values and every demo and use case values file. The rules file gains an optional member. A gate image older than the rules file refuses to start on the unknown field: it fails closed. Gate image and rules file come from one chart release, so they change together.

### How the use cases use it

**Equipment: a machine fault opens a case and starts the service agent.**

1. Telematics posts the fault to the records service (`POST /faults`), as `ctl.sh fault` does now. The service opens a case or reuses the open one.
2. Only when it opened a new case (`deduplicated: false`), the service writes an outbox row "ask the agent to work SVC-2026-0007" in the same transaction as the case. Outbox rows are written only by the intake routes, never by an MCP tool (the agent's `open_proactive_case` writes none), so an agent cannot start a run for itself.
3. A sender loop in the service reads the outbox and calls the gate as `kestrel-fault-events` with text `Work case SVC-2026-0007` and `messageId` `fault-SVC-2026-0007`, and no configuration (the gate adds it). On 2xx with a state of submitted, working or completed the row is done. A 2xx with a failed, cancelled or rejected state (a repeat returns the first task, which may have failed) is retried with a new attempt id (`fault-SVC-2026-0007-r2`). On 429 or 5xx it waits for `Retry-After` and tries again with the same `messageId`. So delivery to the gate is at least once; a retry that reaches the runtime after the first call got through is expected to return the same task (shown for blocking calls; slice 3 shows it with `returnImmediately`), and a repeat the runtime does not catch is harmless in the record. A run that was accepted can still be lost when the runtime restarts, so the service also asks again for a case that is still unworked after a set time (with a new `messageId` that names the attempt, for example `fault-SVC-2026-0007-r2`).
4. A safety-critical fault gets the same message. The agent's step 2 escalates it to a person and drafts nothing (`examples/use-cases/equipment/values.yaml`).
5. A dealer's service request (`POST /requests`) carries a free-text note. The event message still carries only the case id. The note stays in the record and reaches the model as an `untrusted_` field.

The records pod mounts a projected token with the gate audience and gets an egress policy to the gate only. It still has no Kubernetes API right.

**Bank: a new dispute starts the dispute agent.**

The case system files the dispute through `POST /cases`. The records service writes the outbox row in the same transaction (only on this intake route) and sends `Work case DSP-2026-0042`, `messageId` `case-DSP-2026-0042`, as caller `fernvale-case-events` (`text: 'Work case DSP-[0-9]{4}-[0-9]{4}'`, `userId: {fixed: "event:fernvale-cases"}`, `agents: [dispute-agent]`). The dispute agent has no memory, as the chart requires for an event caller's agent. The agent works the case and stops at the approval request, as today. A burst of filings (a fraud ring of five cases) is held to the rate, and the sender backs off on 429.

**Software organisation: an alert.** Alertmanager sends its own JSON and cannot form an A2A message. It uses the channels webhook path (option B) with a token connection, a template that names the workload, and the binding's limits. The limits of that path apply and are stated in the use case's README.

## Consequences

- Possible: a system of record starts an agent run for one of its records, with its own Kubernetes identity, without a person, without free text in the instruction channel, with back-off and with the event id in the audit line.
- Ruled out by this record: free-text event payloads on the gate path; an event that continues an existing conversation; an event caller that picks a user id; streaming or task-reading methods for event callers; event calls to container agents (in 0.3); the gate exposed outside the cluster; exactly-once delivery.
- Harder: the gate keeps per-caller state for the first time (a rate bucket and a counter per event caller, at most 16). The gate must rebuild bodies for event callers, so its forwarding is no longer a plain pass-through on that path.
- Security impact: a new way for a workload to start agent runs without a person, but only with a caller rule the operator writes, a namespace the operator lists and an agent the rule names. Each event caller is bounded in rate and open calls. Nothing new leaves the cluster. The audit line gains the event id. An independent security review is required before the gate slice is merged.
- Compatibility: none for existing users. Default render unchanged. Existing callers unchanged.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0006 | The gate and its caller rules. This record adds one optional block to a rule |
| ADR 0012 | `Trigger` was reserved for 0.4, creating runs. This record is its first form, on the gate. When `AgentRun` exists, an event call may create a run; the `event` fields stay |
| ADR 0016 (proposed) | In 0.3 `event` stays a chart-only caller option, like `memory` in ADR 0016. Moving it into `AgentAccess` needs its own amendment: the grammar check in the controller, a guard denylist, and a reset of the rate buckets on a live reload. ADR 0016's reserved user ids derive from chart callers, so `event:` fixed ids are protected from overlap there too |
| ADR 0017 (proposed) | Schedules are the time door, events the system door. They share nothing new. A `Schedule` never sets `event` |
| ADR 0026 | The records services join through `mcp.endpoints`. This record adds the other direction: the service calls the gate |
| ADR 0028 (proposed) | Approval stays in the system of record; an event run ends at an approval request there |

## Slices

Each slice is one pull request that `Refs #229`, tests first, with a changelog line when users can see it.

1. **This record.** Docs build. At least 7 days of review (security model).
2. **Spike (done, see "Spike results").** On a throwaway kind cluster with its own kubeconfig (never the maintainer's cluster), quick start and stub model. Four of the six questions were answered in the diary, with the request, the response and the log lines as evidence; `contextId` on its own was not tested, and the 16 × 4096 memory case was not measured (moot now):
   - `blocking: false` at kagent 1.0.1: the exact A2A 1.0 field name, whether the call returns at once with a task id, whether the task finishes.
   - A blocking call whose client goes away: does the task finish, cancel or fail?
   - The same `messageId` twice: one task or two?
   - A message with no `contextId`: a new conversation each time? (expected)
   - A body with a case-variant key (`"Parts"`) and with an unknown key: what kagent does. This decides whether the parser differential is real.
   - Gate resident memory with 16 × 4096 keys under the 64Mi limit.
   The answers changed the configuration the gate sets, made the rebuild a requirement and removed the repeat window.
3. **Gate: the `event` block and the shape check** (security-relevant). Rules parsing and refusals, the strict parser (duplicate keys, key allowlist, one text part, pattern, length), the rebuild of the body, the route rule, the audit field and reasons; chart values, render checks and byte-identical default render. Also the grammar check on the `regexp/syntax` tree, exact and case-variant keys, ASCII, the caller-entry key allowlist, `mustRegexMatch` and the token denylist. Tests: one per refusal with its reason; the bytes the upstream receives equal the gate's own serialisation for every accepted body (a fake upstream records them), and none of the caller's extra bytes or keys reach it; the forwarded `messageId` has the caller's name and the text hash; only the allowlisted headers reach the upstream, and `Content-Encoding` is refused; the sender's answer has only the task id and state (a fake upstream that returns a finished task with answer text); an event call to a container agent is refused; live, on a throwaway cluster: one `messageId` under two user ids gives two runs (the test fails if the runtime answers both with one task), and a repeat with `returnImmediately` returns the same task; `configuration.returnImmediately` is always `true`; a body with a second `text` key; `"Parts"`; `parts` and `Parts` together; a `contextId`; any `configuration`; a data part; a 1025-byte text; `a|b` and `(?m)` refused at render and at start; `(` refused at render; a caller entry with `evnet:` refused at render; an event caller for an agent with memory refused; the canary text of a refused request in no log line. The chart refuses `event` until slice 4 is merged, or slices 3 and 4 merge before the same release, so no release has an event caller without limits.
4. **Gate: rate and open calls** (security-relevant). Tests with a fake clock: burst and refill; `Retry-After` values; a shape refusal counts for the rate; open calls released on every exit path, including a client that goes away; state lost on restart (a test that states it).
5. **Equipment use case on events.** Example code in the records service: the outbox row in the case transaction, the sender loop with back-off, the projected token, the egress policy; values with the caller rule. Live proof on a throwaway kind cluster with the stub model: a new fault starts one run; the reused case starts none; the same event sent twice gives one run (the second call returns the same task); a burst of ten faults is held to the rate and all ten cases are worked in the end; a case opened by an MCP tool writes no outbox row; a `helm upgrade` that changes the rules refills the rate bucket (a stated, tested limit); a free-text dealer note never appears in the gate's or the stub model's logs as part of a message; the audit line has the event id. Diary and `what-works.md` row with the limits.
6. **Bank use case on events.** The same for `POST /cases`, and the fraud ring burst.
7. **Docs for the channels path** for senders that cannot speak A2A (the software organisation alert), with its limits.

## Not checked / open points

- *Unverified*: what the spike did not cover (above); the runtime's length limit for `messageId` (the forwarded id can be up to about 209 characters: a 63-character caller name, the 128-character id, a 16-character hash and two colons); whether the strict parser stays inside the gate's 64 KiB read for every legal message (it should: the text is at most 1024 bytes).
- Run concurrency with `returnImmediately` depends on the runtime. With kagent one task runs per session, and every event is a new session.
- Read again before quoting: kagent's handling of `returnImmediately` and of repeated message ids in a later version.

## Questions for the maintainer

1. **Is "the system of record is the caller" the rule, with the channels webhook only for senders that cannot speak A2A?** Recommended: yes. It keeps input validation where the domain is and gives every event a Kubernetes identity.
2. **Should the gate path ever accept free text in an event?** Recommended: no, not in this record. If a use case needs it, a later record adds a data part that the gate wraps as untrusted, with its own review.
3. **May an event caller also read its task (`GetTask`)?** Recommended: not now. The result belongs in the system of record, and `GetTask` by id needs a check that the task belongs to the caller, which the gate cannot do today.
4. **Drop the gate's repeat window and rely on the runtime's one run per message id and user id, plus a system of record that is safe to repeat, with a live test of the per-user scope?** Recommended: yes. The spike showed the runtime returns the same task for a repeated id; the window would add only cover for a runtime restart and an audit reason.
5. **Static keys for event callers?** Recommended: no, ServiceAccount only. The chart cannot express a key for an extra caller today, and a long-lived shared key is what this design avoids.
6. **The 7-day review window.** Recommended: keep it. This changes who can start runs without a person.

## Review notes

An independent review (2026-11-28) asked for these changes, and this text takes all of them: the repeat key is reserved, kept only on a 2xx and released on every refusal; the gate anchors the pattern itself and checks a narrow grammar; `mustRegexMatch` at render; unknown keys in a caller entry are refused; event callers are ServiceAccount only; no event caller for an agent with memory; outbox rows only from intake routes, so an agent cannot start a run for itself; the stated limits (replicas, upgrades, `blocking: false`, at least once to the gate only); `messageId` carries the record id for the audit join; `event` stays chart only beside ADR 0016. No point of the review was rejected.

**After the spike (2026-11-28).** The spike changed three points that the review had shaped: the repeat window (reserve, commit, release) is dropped because the runtime already keeps one run per `messageId`; the gate rebuilds the body instead of only checking it, because the runtime reads case variants and the later of two keys; and the gate sets `returnImmediately: true` instead of the sender sending `blocking: false`, which the runtime ignores.

**Re-check (2026-11-28).** The re-check found three new blockers and smaller points, and this text takes them: the dependency on the runtime's per-user scope of message ids is stated as an assumption, with a live test in slice 3 and the gate rule that becomes required if the scope changes (the gate rule was not added now, because covering the REST routes could break existing callers); the gate rewrites the response to the task id and state; the gate sets the request headers from an allowlist and refuses `Content-Encoding`; event calls to container agents are refused in 0.3; a 2xx with a failed task is retried with a new attempt id; the chart's pattern check is stricter than the gate's; the spike claims are narrowed (`contextId` alone not tested, 16 × 4096 not measured, repeats shown for blocking calls only).
