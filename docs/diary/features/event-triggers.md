---
title: Event callers on the A2A gate
sidebar_position: 15.96
description: "How a system of record starts one agent run through the A2A gate as an event caller (ADR 0027, slices 3 and 4): a pinned message shape, a body the gate rebuilds, a rate and an open-call limit, the event id in the audit line, and what is proven and what is not."
---

# Event callers on the A2A gate

Issue [#229](https://github.com/openagentix/openagentix/issues/229), [ADR 0027](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0027-event-triggers-through-the-gate.md), slices 3 and 4. The code is in `services/a2a-gate` (`internal/gate/event.go`, `internal/rules/event.go`, `internal/rules/eventtext.go`) and in the chart helper `oa.a2aRules`. The use cases send events as a second step (slices 5 to 7, below): the equipment and bank records services, and the docs for the channels path.

## What it is

A caller in `governance.a2a.callers[]` may have an `event` block. The caller is a system of record (a case system, a fleet service). It starts one agent run for one of its records by sending one short text that names the record, for example `Work case SVC-2026-0007`. The record itself, with the text of people in it, stays in the system of record and reaches the model through the agent's tools, where the use cases label it `untrusted_`.

```yaml
governance:
  a2a:
    callers:
      - name: kestrel-fault-events
        serviceAccount: {namespace: kestrel-records, name: records-events}
        agents: [service-agent]
        event:
          text: 'Work case SVC-[0-9]{4}-[0-9]{4}'
          rate: {perMinute: 6, burst: 3}
          maxInFlight: 2
```

## What the gate does for such a caller

1. It reads the body strictly. A repeated key, a key that differs in case, any key outside the allowed set, a second part, a `configuration`, a `contextId`, and a text that does not match the pattern are each a 403 with the reason `message_shape`. The answer names no part of the body.
2. It builds its own body and its own request headers. The caller's bytes never reach the runtime. The message id the runtime sees is `<caller>:<messageId>:<16 hex of the SHA-256 of the text>`, and `configuration.returnImmediately` is `true`.
3. It answers the sender with the task id and the state, and nothing else. A JSON-RPC error becomes its code with the message `refused`.
4. It limits the caller with a token bucket (`rate`) and a count of open calls (`maxInFlight`), before it reads the body. Over the limit is a 429 with `Retry-After`, whatever the body is, so a sender with slow bodies cannot hold more of the gate's shared slots than its own `maxInFlight`.
5. It adds `event_id` to the audit line: the `messageId` the caller sent, or `invalid` when the shape check did not pass. Never the text.

The chart checks the same things as the gate, so that a values file that renders should not stop the gate from starting: unknown keys in any caller entry, `methods`, `memory` or `key` with `event`, a user id that is not `fixed` or that another caller's rule covers, the pattern (the gate's alphabet, escapes only of `. - : _`, classes inside the alphabet, repeats of at most 64, no lazy repeat, no empty or unbalanced group, no space inside a group or before `?` or `{`, at most 3 spaces, at most 2 classes with letters, no empty match, and `mustRegexMatch`, so a pattern that does not compile fails the render), agents named only from `agents[]` and none with long-term memory, no container agent, and at most 16 event callers. The gate stays the authority and re-checks the pattern on its parse tree. The agreement is enforced by two lists that the chart tests and the gate's Go test both read: `event-patterns-accepted.txt` (every pattern must render and be accepted by the gate) and `event-patterns-refused.txt` (every pattern must fail the render and be refused by the gate). A pattern outside the two lists is not proven to agree.

## What is proven, and how

| Claim | Evidence |
|---|---|
| The grammar accepts the documented patterns and refuses the hostile ones | Go table tests 80 hostile patterns, a fuzz target that checks that an accepted pattern never matches the empty text, a newline or a non-ASCII text (`services/a2a-gate/internal/rules`) |
| The gate refuses every hostile body and forwards exactly its own serialisation | Go tests with a fake runtime that records the bytes and the headers: 99 hostile bodies (duplicate keys, case variants, unicode escapes, nested parts, a very long id, a lone surrogate), the allowlisted headers, `Content-Encoding`, the container agent, the rewritten answer for 19 kinds of runtime answer (`internal/gate/event_test.go`) |
| Rate and open calls | Go tests with a fake clock (burst, refill, `Retry-After`, a refusal counts for the rate), open calls released when the client goes away, and a test that states that a new gate starts with full buckets |
| The chart refuses what the ADR lists | 94 shell checks over `helm template` in `charts/openagentix/tests/run.sh` |
| The runtime keeps message ids per user id | `hack/ci/msgid-scope.sh`, run by every `e2e` job |
| Live: an event caller starts a run and the runtime side received exactly the gate's serialisation | The opt-in job `event_triggers`, run 46111543167: 48 checks passed, 0 failed |

## Limits, as stated in the ADR

- The rate buckets and the open-call counts are in the memory of one gate process. With N replicas the limits are N times the values. A gate restart, and every `helm upgrade` that changes the rules, refills the buckets.
- `maxInFlight` bounds the calls that are open at the gate. With `returnImmediately` a call is short, so it bounds submissions, not running tasks. The gate does not bound running tasks.
- Delivery to the gate is at least once. A repeat of the same event is expected to return the same task, because the runtime keeps one run per message id and user id (shown live, with `returnImmediately`, by `hack/ci/msgid-scope.sh`). The runtime may forget an id (a restart, or a runtime that keeps none), so the work an event starts must be safe to repeat in the system of record.
- The one-run-per-message-id rule holds only for calls through the gate. A workload of the `kagent` namespace can still reach the runtime's port and take an event's id first.
- A 2xx means that the task was accepted, not that the run happened. A run that was accepted can be lost when the runtime restarts.
- An event caller cannot read its task (no `GetTask`) and cannot join a conversation (no `contextId`).
- Container agents are refused for event callers in this release.
- An event caller may name only agents of the chart's `agents[]` (by name), so that the chart can check that none has long-term memory. The gate cannot tell which agents have memory and does not check it. An agent made by an `AgentDefinition` cannot be named by an event caller in this release.
- A JSON-RPC error from the runtime reaches the sender as its code with the message `refused` and the status 502, never the runtime's own status.

## The use cases send events (slices 5 to 7)

Off by default. `EVENTS=1 examples/use-cases/<use case>/install.sh` turns on the sender of the records service: a case that an intake route accepts (a fault, a service request, a new dispute) queues one event in the same transaction, and a sender loop calls the gate as the event caller `kestrel-fault-events` or `fernvale-case-events`, with the pod's own ServiceAccount `records-events` and a projected token for the gate's audience. Only an intake route writes an event; no MCP tool does, which a test checks by calling every tool. The records pod may reach DNS and the gate on 8080 and nothing else. The rate and limits are sized from the measured token cost of a case (about 70,000 tokens for equipment, 100,000 to 180,000 for the bank, against the gateway's 1,000,000 an hour): the event rate spreads a burst but cannot fund the budget, and the gateway's budget is the hard stop. The numbers and the reasons are in each use case's README, "Event triggers".

| Claim | Evidence |
|---|---|
| The sender sends the ADR's message, at least once and bounded | Go tests with a fake gate and a fake clock in `examples/use-cases/records/internal/core`: the body is the gate's input exactly, a 429 waits for `Retry-After` and uses no try, failures back off and are given up, a failed task gets a new attempt id, an unworked case is asked again up to the bound, the token is in no log or audit line, a redirect is not followed |
| Only an intake route writes an event, in the case's transaction | Tests in the equipment and bank modules: a new fault, a request and a dispute queue one row; a repeat, a refused case and every MCP tool queue none; a failed enqueue leaves no case; with the sender off there is no `events` table |
| The records service is off unless configured, and half a configuration stops it | `cmd/records` tests |
| The install is idempotent and the manifest is the same as before when `EVENTS` is unset | the install tests with fakes (first run, second run, back to unset, beside the other use case and the full demo) and the manifest tests of both use cases |
| Live: a real intake event starts the agent with no person; a repeat starts no second run; a burst is held to the rate and all are sent once; an agent tool causes no event; nothing is sent with the sender off | `hack/ci/events-live.sh`, opt-in jobs of the `e2e` workflow (run ids in the pull request and the what-works row) |

The channels path for senders that cannot speak A2A (slice 7), with what is weaker on it, is in [channels](./channels.md), "Events from a sender that cannot speak A2A". It is documentation only: no use case wires it.

Not done: the sweep for unworked cases was not run live (it waits 30 minutes; the unit tests cover it); a real model was not used; more than one gate replica and a runtime restart were not tried.
