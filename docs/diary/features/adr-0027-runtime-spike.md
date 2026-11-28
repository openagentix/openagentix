---
title: Runtime and gate spike for event triggers
sidebar_position: 15.95
description: What a throwaway-cluster spike showed about kagent 1.0.1 behind the A2A gate (non-blocking send, a client that leaves, a repeated messageId, unusual message keys) and about the gate's memory (ADR 0027, proposed).
---

# Runtime and gate spike for event triggers

Issue [#229](https://github.com/openagentix/openagentix/issues/229), ADR 0027 (proposed, PR #260), slice 2. This page is the record of one spike. It does not describe a feature of the product. Nothing in the chart, the CRDs or the services was changed.

## What was run

The same job as for [the model gateway spike](adr-0029-gateway-spike.md): the quick start on a kind cluster of a hosted runner (kagent controller `1.0.1`, the agent `quickstart`, the stub model, no paid call), then `hack/spikes/adr0027_gate_spike.py`. The script refuses to run outside GitHub Actions.

- A small recording stand-in (`hack/spikes/adr_slow_model.py`) sits between the model gateway and the stub model. It writes down every model request with its start and end time and the last user text. A request whose text holds `SLOWRUN` waits 25 seconds, so one run lasts long enough to watch. The spike points `quickstart-model` at the stand-in with a patch of its `baseURL`.
- The calls go to the kagent controller's A2A port (`POST /agents/kagent/quickstart`, headers `A2A-Version: 1.0` and `X-User-Id`) through a port-forward, which is the port the gate forwards to. One check also goes through the gate with a ServiceAccount token.
- Every request is JSON-RPC `SendMessage` with `{"message":{"messageId":"<id>","role":"ROLE_USER","parts":[{"text":"<text>"}]}}` in `params`, plus the variation named in each answer. The text carries a unique marker so the stand-in's record can be matched to the call.

Runs on the pull request:

| Run | Result |
|---|---|
| [46098251670](https://github.com/openagentix/openagentix/actions/runs/46098251670) | First complete run. B1 to B4. B5 measured the wrong process (the shell that looked for the gate) and is not used. |
| [46099570137](https://github.com/openagentix/openagentix/actions/runs/46099570137) | B5 on the gate process; B2 with the stand-in's record. Tables below. |
| [46100654827](https://github.com/openagentix/openagentix/actions/runs/46100654827) | Spike B alone, to read the runtime's task table. The table was found but the marker text was not in it (see B2). |

## Answers

| # | Question | Answer |
|---|---|---|
| 1 | Does the runtime honour a non-blocking send? | Partly. `configuration: {"blocking": false}` was **not** honoured: the call returned after 25.4 s, with the finished task, the same as with no configuration or `blocking: true`. `configuration: {"returnImmediately": true}` (the A2A 1.0 name) **was** honoured: the answer came after 0.3 to 0.6 s with `TASK_STATE_SUBMITTED` and a task id; `GetTask` then showed `TASK_STATE_WORKING` and, 26 to 27 s after the send, `TASK_STATE_COMPLETED`. So the run continued after the call returned. The key `Configuration` with a capital C was honoured too (see B4). Through the gate, `blocking: false` also waited 25.4 s. |
| 2 | What happens to a run when the client disconnects mid-call? | The run continues. A blocking call (no configuration) was dropped by the client after 4 s. The stand-in saw one model request that started 0.5 s after the send and finished at 25.5 s with status 200, 21 s after the client left. Not read: the final state of the task. The runtime's database has a table `session_task`, but a search for the marker text found no row, so the spike does not say whether the task ends as completed. |
| 3 | The same `messageId` sent twice: one run or two? | One run. Sent twice in a row, the second call returned in 0.01 s with the **same task id** and the same answer; the stand-in saw one model request. Sent again while the first still ran (5 s later), the second call waited for the same run (20.4 s) and returned the same task; one model request. Sent again with the same id and different text, the second call returned the first task, and the new text never reached the model. |
| 4 | How does the runtime treat unknown keys and case variants? | Unknown keys: accepted and ignored. Case variants: accepted, as if spelled right. Details below. |
| 5 | Memory of the gate pod under a burst? | Measured for the gate as it is today: 15 MiB resident at the highest point, against the limit of 64 MiB. Distinct callers and the 16 x 4096 keys of the ADR: not measured. Details below. |

## B1, detail

| Request (`params.configuration`, text `SLOWRUN ...`) | Answer |
|---|---|
| none | after 25.4 s: task `TASK_STATE_COMPLETED` |
| `{"blocking": false}` | after 25.4 s: `TASK_STATE_COMPLETED` |
| `{"returnImmediately": true}` | after 0.3 s: `TASK_STATE_SUBMITTED`; `GetTask` every 2 s: `WORKING` at +0 s, `COMPLETED` at +27 s |
| `{"blocking": true}` | after 25.5 s: `TASK_STATE_COMPLETED` |

The stand-in's record agrees: the model request started 0.4 s after the send and finished 25.4 s after it, in every row. The `GetTask` request is `{"jsonrpc":"2.0","id":2,"method":"GetTask","params":{"id":"<task id>"}}` and the runtime answered it directly on its own port. The default caller rule of the gate lists `SendMessage` and `SendStreamingMessage` only, so `GetTask` through the gate was not tried.

## B4, detail

Each row is one `SendMessage` to the controller. "Reached the model" means the stand-in saw the marker.

| Variation of the body | Answer | Reached the model |
|---|---|---|
| control | accepted | yes |
| `params.unknownKey`, `message.unknownKey`, a top-level `unknownKey`, a key inside a part | accepted | yes |
| `Parts` instead of `parts` | accepted | yes, the text of `Parts` |
| `parts` and `Parts` together (in that order) | accepted | only the text of `Parts`, the later key |
| `MessageId` instead of `messageId` | accepted | yes |
| `Params` instead of `params` | accepted | yes |
| `Configuration` instead of `configuration`, with `returnImmediately: true` | accepted and honoured (`SUBMITTED` after 0.6 s) | yes |
| a part with `text` twice | accepted | only the later `text` |
| `parts` twice | accepted | only the later `parts` |
| `configuration.unknownKey` | accepted | yes |
| `message.contextId` with a fresh UUID and `taskId` with a made-up id | refused: JSON-RPC error `-32001`, `task not found` | no |

The last row mixes two keys, so it does not show how `contextId` alone is treated. The `taskId` is the likely cause. Method names are PascalCase (`SendMessage`, `GetTask`); `tasks/list` answered `method not found`.

So key matching in the runtime does not follow the spelling rules a strict parser would apply: a different spelling of a known key is read as that key, and when a key appears twice, the last one wins.

## B5, detail

How: the gate process was read from the kind node (`docker exec <node>`, `/proc/<pid>/status` for `VmRSS` and `VmHWM`, and the pod's cgroup files `memory.current`, `memory.peak`, `memory.max`). `kubectl top` answered "Metrics API not available". The gate's container limit is 64Mi (`memory.max` 64 MiB), request 24Mi.

| Moment | VmRSS / VmHWM (MiB) | cgroup current / peak (MiB) |
|---|---|---|
| Idle, baseline | 11 / 11 | 5 / 6 |
| After 300 requests, each with its own projected ServiceAccount token (`kubectl create token`) and its own `messageId`, 6 at a time, to an agent the caller may not ask (255 got 403; 45 got no answer because a port-forward refused the connection) | 13 / 14 | 7 / 8 |
| After 48 blocking `SendMessage` calls at the same moment, each with its own token and `messageId`, each held about 25 s (40 answered 200; 8 got no answer from the port-forward); sampled every 2 s | highest sample 14; end 15 / 15 | 9 / 10 |

The gate keeps no per-caller state today, so this shows the cost of distinct tokens (its 30 s token review cache) and of open calls, not of the 4096 repeat keys of ADR 0027. That needs the code of the gate slices. Distinct caller rules (a chart values change) were not tried: the burst used one caller rule with many tokens.

## Limits of this spike

- One kagent version (1.0.1), one single-node kind cluster, one run of each check (B1 to B4 ran in two or three dispatches with the same result).
- The model is the stub; a run lasts 25 s because the stand-in waits. A real run with tools may behave differently when the client leaves.
- B2 does not say what state the task ends in. Reading it needs a method of the runtime that answers for a task whose id the client never got (a `contextId` the client chose was refused as an invalid session), or the right query on the runtime's database.
- The spike sent its calls to the runtime's port. The gate was in the path only for one check of B1 and for B5. The gate passes the body on after reading it; whether a gate-side parser would read the same keys as the runtime was not run, because that parser does not exist yet.
- B5 used port-forwards, which dropped some connections under load; the numbers are for the connections that were made.
- `blocking: false` is ignored by kagent 1.0.1. If the ADR needs the call to return at once, the field is `returnImmediately: true` in `configuration`. This needs the ADR's shape check to allow that key and not `blocking`.
