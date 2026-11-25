---
title: A2A gate
sidebar_position: 2
description: How to call an agent through the A2A gate, the caller rules format, the audit line, limits, status codes and environment variables.
---

# A2A gate

The A2A gate is a small reverse proxy in front of the kagent controller's A2A port (8083). It checks who the caller is, which agent the caller may reach, which user id the caller may use, and which A2A method the caller may call. It writes one audit line for each request. This page was written from the code in `services/a2a-gate`. If this page and the code differ, the code is right.

Status words used on this page:

- **available**: built and working in the default build.
- **available but off by default**: built, but you must turn it on.
- **reserved (designed, not built)**: planned, but there is no code yet.

The gate is **available but off by default**: the chart value `governance.a2a.enabled` is `false`. With the gate off, every caller that the NetworkPolicy admits can call the controller and name its own user. For why the gate exists and what it does not protect, read [Security](../features/security.md).

## How to call an agent

### Endpoint

| Item | Value |
|---|---|
| In-cluster address | `http://a2a-gate.openagentix-gateway.svc.cluster.local:8080` (namespace from `governance.a2a.namespace`) |
| Agent route | `POST /agents/<namespace>/<name>` |
| Agent card | `GET /agents/<namespace>/<name>/.well-known/agent-card.json` (also `agent.json`) |
| Health | `GET /healthz` and `GET /readyz`, no token, answer `ok` |

`<namespace>` and `<name>` are Kubernetes names: lower case letters, digits, `-` and `.`, at most 253 characters each. For a chart agent the namespace is the kagent namespace (`kagent` by default).

### Request headers

| Header | Needed | Meaning |
|---|---|---|
| `Authorization: Bearer <token>` | yes | One header only. See Tokens below. Over 8 KiB: refused |
| `Content-Type: application/json` | for POST | The body is JSON-RPC |
| `X-User-Id: <id>` | depends on the rule | The user id. Max 256 bytes, no control characters. Rules decide if it is needed (see User id rules) |
| `A2A-Version: 1.0` | by convention | The tools in this repository send it. The gate does not check it |
| `Traceparent` | optional | A W3C trace header. The trace id goes in the audit line |

### Tokens

| Kind | How it is checked |
|---|---|
| Projected ServiceAccount token | Audience must be `openagentix-a2a` (`A2A_GATE_AUDIENCE`). The gate checks it with a Kubernetes TokenReview. A good answer is cached 30 s, a refusal 5 s. The ServiceAccount must have a rule |
| Static key | The SHA-256 of the key is compared with the files in the keys Secret. The file name is the caller name. Used by Agent Kourier bindings |

Make a token for a ServiceAccount:

```sh
kubectl create token quickstart-ask -n openagentix-system --audience openagentix-a2a --duration 10m
```

### Allowed routes

The gate passes only these routes, and only for an agent that the caller's rule lists. Everything else is 403.

| Method and path | A2A method |
|---|---|
| `POST /agents/<ns>/<name>` | The `method` member of the JSON-RPC body |
| `POST /agents/<ns>/<name>/message:send` (also under `/v1/`) | `SendMessage` |
| `POST /agents/<ns>/<name>/message:stream` (also under `/v1/`) | `SendStreamingMessage` |
| `GET /agents/<ns>/<name>/.well-known/agent-card.json` (also `agent.json`) | none |
| `POST /kagent.runtime.v1.MemoryService/List` | memory RPC, only for `memory: true` |
| `POST /kagent.runtime.v1.MemoryService/Delete` | memory RPC, only for `memory: true` |

The path must be plain: no `%` escapes, no `//`, no backslash, no query string use. The gate removes the whole query string before it sends the request on.

### Which A2A methods are allowed

A rule lists the methods that a caller may use in `methods`. If the rule has no `methods`, the default list is:

| Default method | Meaning |
|---|---|
| `SendMessage` | Send a message and wait |
| `SendStreamingMessage` | Send a message and stream the answer (SSE) |

Any other method is refused with 403 and reason `method` unless the rule lists it. For example `GetTask`, `SubscribeToTask` and `CancelTask` must be listed. A method name must match `^[A-Za-z][A-Za-z0-9_./:-]{0,63}$`. The chart's own callers get these lists:

| Caller | Methods |
|---|---|
| The Telegram bridge (`bridge`) | `SendMessage` |
| A schedule (`schedule-<name>`) | `SendMessage` |
| A Kourier binding (`kourier-<name>`) | `SendMessage`, `SendStreamingMessage`, `GetTask`, `SubscribeToTask`, `CancelTask` |
| One of your own callers | what you list, or the default list |

How the method is found on the JSON-RPC route:

- The whole body must fit in `A2A_GATE_SNIFF_BYTES` (64 KiB by default, at most 1 MiB).
- The body must be one JSON object with exactly one `method` string. Names are compared without case, so `method` and `Method` together are refused.
- If the method cannot be found, the gate **fails closed**: 403, reason `method`, and nothing goes to the agent. This happens for a larger body, a batch (a JSON array), no `method`, two `method` members, text that is not JSON, or data after the object.

gRPC and gRPC-Web (`Content-Type: application/grpc*`) are refused on every route, except the two memory RPCs for a caller with `memory: true`. A request with an `Upgrade` header is refused.

### Example call

This is what `hack/ask.sh` sends. Run it from your laptop with a port-forward:

```sh
kubectl port-forward -n openagentix-gateway svc/a2a-gate 8080:8080 &
TOKEN=$(kubectl create token quickstart-ask -n openagentix-system --audience openagentix-a2a --duration 10m)
curl -sS -X POST http://127.0.0.1:8080/agents/kagent/assistant \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'A2A-Version: 1.0' \
  -H 'X-User-Id: quickstart:ask' \
  -d '{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"messageId":"m-1","role":"ROLE_USER","parts":[{"text":"Say hello in one sentence."}]}}}'
```

For this call to work, the ServiceAccount `openagentix-system/quickstart-ask` needs a rule (the quick start profile adds one), and the agent `kagent/assistant` must be in the rule's `agents`.

Read the agent card:

```sh
curl -sS http://127.0.0.1:8080/agents/kagent/assistant/.well-known/agent-card.json \
  -H "Authorization: Bearer $TOKEN"
```

The answer is the agent's own answer. It is passed on as it comes, with an immediate flush, so a streaming answer (SSE) arrives piece by piece.

Easier ways to call it:

| Tool | What it does |
|---|---|
| `hack/ask.sh <agent> "<question>"` | Makes a token for `openagentix-system/quickstart-ask`, opens a port-forward to the gate, sends `SendMessage`, prints the answer text. Settings: `ASK_NAMESPACE` (default `kagent`), `ASK_SA` (default `openagentix-system/quickstart-ask`), `GATE_NAMESPACE` (default `openagentix-gateway`), `ASK_TIMEOUT` (default 300 seconds), `ASK_USER` (default `quickstart:ask`), `ASK_PORT`, `KUBECTL`, `KUBE_CONTEXT`. Exit 0 only when the task state is `TASK_STATE_COMPLETED` |
| `tools/a2a-call` | A small A2A 1.0 caller. It runs as the pod of each schedule. Settings: `A2A_URL`, `A2A_USER_ID`, `A2A_TOKEN_FILE`, `PROMPT_FILE` or `PROMPT`, `A2A_TIMEOUT` (default `300s`), `MAX_RESPONSE_BYTES` (default 4 MiB), `PRINT_ANSWER` (off), `TRACEPARENT`. Exit 0 for a completed task, 1 for a failed one, 2 for a bad configuration |

## What the gate does to a request

1. Reads the bearer token and finds the caller's rule. No rule: 403.
2. Checks the path against the allowed routes, and the agent against the rule.
3. Decides the user id (see User id rules).
4. For POST, reads the start of the body (at most `A2A_GATE_SNIFF_BYTES`, within 10 seconds) to learn the JSON-RPC method and the `contextId`. The rest streams through untouched.
5. Removes these headers: `Authorization`, `Proxy-Authorization`, `Cookie`, `X-User-Id`, `X-Agent-Name`, `X-Share-Token`, `X-Kagent-Insecure-Runtime-Identity`, `Baggage`, `Forwarded`, `X-Real-Ip` and every `X-Forwarded-*`. It removes the whole query string. Then it sets `X-User-Id` itself from the rule.
6. Sends the request to `A2A_GATE_UPSTREAM`. The controller stays in `insecure` mode and never sees a caller credential.
7. Writes one audit line.

## Caller rules

The rules are a JSON file, rendered by the chart from its values and mounted from a ConfigMap (`a2a-gate-rules`). It holds no secret. The gate reads it once, at start. A change of the rules replaces the pod. Unknown fields are an error, so a typo cannot loosen a rule.

### Fields of one caller

| Field | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | Letters, digits, `.`, `_`, `-`. At most 63 characters, must start with a letter or digit. Unique |
| `serviceAccount` | object | one of two | `namespace` and `name` of the Kubernetes ServiceAccount whose projected token the caller uses. Each ServiceAccount belongs to one caller |
| `key` | boolean | one of two | `true`: the caller uses a static key. The SHA-256 is in the keys Secret, in a file named like the caller |
| `agents` | array of string | yes, not empty | Each is `namespace/name` in the rules file |
| `userId` | object | yes | Exactly one of `exact`, `prefix`, `fixed` |
| `methods` | array of string | no | The A2A methods the caller may use. Not empty if given. No duplicates. Default: `SendMessage`, `SendStreamingMessage` |
| `memory` | boolean | no | Default `false`. `true` allows the two MemoryService calls |

Set exactly one of `serviceAccount` and `key`.

### User id rules

| Rule | Caller sends | Gate does |
|---|---|---|
| `exact: "ci:smoke"` | Nothing, or exactly that value | Uses that value. Another value: 403 `user_id` |
| `prefix: "ci:"` | A value that starts with the prefix and has something after it | Uses the value. Nothing, or no match: 403 `user_id` |
| `fixed: "ci:smoke"` | Anything | Ignores what was sent. Always uses that value |

For all rules: two `X-User-Id` headers are refused (except with `fixed`), and a value over 256 bytes or with control characters is refused. A rule value follows the same limit. For the agent card route, no user is needed. The gate sets one only for `exact` and `fixed`.

kagent keys sessions and long-term memory by the user id. So the user id decides whose memory an agent reads.

### Valid example: your own caller (chart values)

```yaml
governance:
  a2a:
    enabled: true
    callers:
      - name: ci-smoke
        serviceAccount: {namespace: ci, name: smoke}
        agents: [assistant]
        userId: {exact: "ci:smoke"}
        methods: [SendMessage, SendStreamingMessage]
        memory: false
networkPolicy:
  extraA2ACallers:
    - namespace: ci
```

Notes for the chart:

- In `callers[].agents` a bare name must be in the chart's `agents[]` list. The chart turns it into `<kagent namespace>/<name>`. A value with `/` is used as it is.
- The name must not be `bridge`, and must not start with `schedule-` or `kourier-`. The chart makes those callers itself.
- `callers[]` entries need `serviceAccount`. The chart does not render a `key` caller from values. Key callers are made only for Agent Kourier bindings.
- Every namespace in `networkPolicy.extraA2ACallers` needs a matching `callers[]` entry, or the render fails.
- Without `networkPolicy.extraA2ACallers`, the NetworkPolicy of the gate does not admit your pod.

The chart renders this rules JSON for the example:

```json
{
  "callers": [
    {
      "name": "ci-smoke",
      "serviceAccount": {"namespace": "ci", "name": "smoke"},
      "agents": ["kagent/assistant"],
      "userId": {"exact": "ci:smoke"},
      "methods": ["SendMessage", "SendStreamingMessage"]
    }
  ]
}
```

Make a token for it:

```sh
kubectl create token smoke -n ci --audience openagentix-a2a
```

### Callers the chart makes for you

| Caller | When | Auth | Agents | User id rule |
|---|---|---|---|---|
| `bridge` | `bridge.enabled` | ServiceAccount `<bridge namespace>/telegram-bridge` | the bridge agent | `prefix`: `bridge.userIdPrefix`, default `telegram:`. Gets `memory: true` when `bridge.memoryCommands` is on |
| `schedule-<name>` | each entry in `schedules` | ServiceAccount `<scheduling namespace>/schedule-<name>` | the schedule's agent | `exact`: the schedule's `userId`, default `schedule:<name>` |
| `kourier-<name>` | each Kourier binding (`channels.kourier.enabled`) | static key | the binding's agent | `fixed`: the binding's `userId`, default `kourier:<name>` |

### Memory calls

A caller with `memory: true` may call two RPCs of kagent's MemoryService over binary gRPC-Web, and nothing else of any gRPC service.

| Item | Rule |
|---|---|
| Paths | `POST /kagent.runtime.v1.MemoryService/List` and `POST /kagent.runtime.v1.MemoryService/Delete` |
| Content type | `application/grpc-web` or `application/grpc-web+proto` |
| Not allowed | native gRPC, base64 text mode, compression (`Grpc-Encoding` other than `identity`), `Search`, `AddSession`, `AddSessionBatch` and every other RPC |
| Which user | Not in the message. The gate sets `X-User-Id` from the rule, as for A2A |
| Body | One frame, at most 600 bytes of message. It must hold exactly one string field, number 1 (`agent_name`), and nothing else. The agent must be one the rule lists |
| Without `memory: true` | 403, reason `memory` |

## Audit line

The gate writes one JSON line to standard output for each request (not for `/healthz` and `/readyz`). The log message is `audit`. It never holds message text.

| Field | Type | Meaning |
|---|---|---|
| `time`, `level`, `msg` | string | Standard log fields. `msg` is `audit` |
| `caller` | string | The caller name. Empty when the caller was not identified |
| `agent` | string | `namespace/name`. Empty when the request did not name an agent |
| `user_id` | string | A salted hash by default: `h:` and 8 hex digits. The salt is random for each process. With `A2A_GATE_AUDIT_USER_ID=raw`, the id itself. The id the caller claims is recorded only after the caller is identified, and is cut to 128 bytes. For an allowed request it is the id the gate sent on |
| `context_id` | string | The `contextId` of the message. Empty when absent. `invalid` when it is not a plain id (1 to 128 of letters, digits, `.`, `_`, `:`, `-`) |
| `trace_id` | string | From `Traceparent`. Empty when absent or not valid |
| `status` | integer | The HTTP status sent |
| `duration_ms` | integer | Time taken, in milliseconds |
| `method` | string | The HTTP method |
| `rpc` | string | Only on POST. The A2A method, for example `SendMessage`. `unknown` when it could not be found. `invalid` when it does not look like a method name. For memory calls: `MemoryService/List` or `MemoryService/Delete` |
| `reason` | string | Only on a refusal or failure. See the reason table |

The audit user id is a hash so that the log does not hold personal ids. The hash changes when the pod restarts.

## Status codes and reasons

The body of an error is `{"error":"<text>"}`, with `Content-Type: application/json`. The text is only one of the words below. The `reason` word is written in the audit line and is not in the body.

| Status | `error` text | Audit `reason` | When |
|---|---|---|---|
| 401 | `unauthorized` | `no_token` | No `Authorization` header, more than one, not `Bearer`, or empty token |
| 401 | `unauthorized` | `bad_token` | A key that matches no hash, a token that is not a valid projected token (wrong audience, no `iss`, expired), or one that TokenReview refuses. Also a token over 8 KiB |
| 403 | `forbidden` | `unknown_caller` | The token is valid, but no rule names that ServiceAccount or key |
| 403 | `forbidden` | `path` | Not an allowed route or method, a bad path, or an `Upgrade` header |
| 403 | `forbidden` | `grpc` | gRPC or gRPC-Web on an A2A route, or a bad memory call content type or encoding |
| 403 | `forbidden` | `agent` | The agent is not in the caller's `agents` |
| 403 | `forbidden` | `user_id` | The user id rule refuses the `X-User-Id` |
| 403 | `forbidden` | `method` | The A2A method is not in the caller's list, or the method cannot be found |
| 403 | `forbidden` | `memory` | A memory call from a caller without `memory: true` |
| 403 | `forbidden` | `frame` | A memory call whose frame is not exactly one valid `agent_name` |
| 408 | `request timeout` | `body_timeout` | The start of the body did not arrive within 10 seconds. The connection is closed |
| 413 | `request too large` | `body_too_large` | Body over `A2A_GATE_MAX_BODY`, or a memory call body over 605 bytes |
| 431 | none (plain text from Go) | none | Header block over 16 KiB |
| 502 | `bad gateway` | `upstream` | The controller did not answer |
| 503 | `service unavailable` | `auth_unavailable` | The token check could not run (TokenReview failed, or too many checks at once) |
| 503 | `service unavailable` | `busy` | `A2A_GATE_MAX_INFLIGHT` requests are in progress. Header `Retry-After: 1` |

A 401 also has the header `WWW-Authenticate: Bearer realm="a2a-gate"`. Otherwise the status and body come from the agent.

## Limits

| Limit | Value | Setting |
|---|---|---|
| Header block | 16 KiB (431) | fixed |
| Header read | 10 s | fixed |
| Body start must arrive | 10 s (408) | fixed |
| Idle connection | 120 s | fixed |
| Write timeout | none, so a stream can run for minutes | fixed |
| Body read for method and `contextId` | 64 KiB, at most 1 MiB | `A2A_GATE_SNIFF_BYTES` |
| Largest request body | 8 MiB (413) | `A2A_GATE_MAX_BODY` |
| Requests at once | 128 (503 `busy`) | `A2A_GATE_MAX_INFLIGHT`, 1 to 10000. Chart: `governance.a2a.maxInFlight` |
| Bearer value | 8 KiB | fixed |
| TokenReview cache | 30 s for a good answer, 5 s for a refusal | fixed |
| TokenReview calls at once | at most 8, one for each token at a time | fixed |
| Key hash files | read again at most every 10 s | fixed |
| User id | 256 bytes | fixed |
| Memory call frame | 600 bytes | fixed |
| Health probes | do not count in the request limit | fixed |

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `A2A_GATE_UPSTREAM` | none, required | The controller, for example `http://kagent-controller.kagent.svc.cluster.local:8083` |
| `A2A_GATE_RULES` | none, required | Path of the rules JSON |
| `A2A_GATE_KEYS_DIR` | `/etc/a2a-gate/keys` | The key hashes, one file for each caller. Each file holds a SHA-256 as 64 hex characters |
| `A2A_GATE_AUDIENCE` | `openagentix-a2a` | The audience a projected token must carry |
| `A2A_GATE_AUDIT_USER_ID` | `hash` | `hash` or `raw` |
| `A2A_GATE_SNIFF_BYTES` | `65536` | Body bytes read to find the method and `contextId`. 1 to 1048576 |
| `A2A_GATE_MAX_BODY` | `8388608` | Largest request body in bytes |
| `A2A_GATE_MAX_INFLIGHT` | `128` | Requests handled at once |
| `A2A_GATE_ADDR` | `:8080` | Listen address |
| `A2A_GATE_LOG_LEVEL` | `info` | Log level of the process log (not the audit line) |

The chart sets `A2A_GATE_ADDR`, `A2A_GATE_UPSTREAM`, `A2A_GATE_AUDIENCE`, `A2A_GATE_RULES`, `A2A_GATE_KEYS_DIR`, `A2A_GATE_AUDIT_USER_ID` and `A2A_GATE_MAX_INFLIGHT`. It has no value for `A2A_GATE_SNIFF_BYTES`, `A2A_GATE_MAX_BODY` or `A2A_GATE_LOG_LEVEL`.

## What is off by default

| Item | Status | How to turn on |
|---|---|---|
| The gate itself | **available but off by default** | `governance.a2a.enabled: true`. Needs `kagent.enabled: true` |
| Caller rules for your own services | **available but off by default** | `governance.a2a.callers[]` and `networkPolicy.extraA2ACallers` |
| Memory calls | **available but off by default** | `memory: true` in a caller rule. For the bridge: `bridge.memoryCommands: true` |
| Raw user ids in the audit line | **available but off by default** | `governance.a2a.audit.userId: raw` |
| Static key callers made from your own values | **reserved (designed, not built)** | The rules format has `key: true`, but the chart makes key callers only for Agent Kourier bindings |
| Per-method or per-agent rate limits | **reserved (designed, not built)** | There is only the global `maxInFlight` limit |

Chart values of `governance.a2a`:

| Value | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Render the gate |
| `namespace` | `openagentix-gateway` | Where the gate runs |
| `image` | `openagentix/a2a-gate`, tag `dev` | Image |
| `audience` | `openagentix-a2a` | Token audience |
| `keysSecret` | `a2a-gate-keys` | Secret with the key hashes. Optional: the gate starts without it |
| `maxInFlight` | `128` | Requests at once |
| `audit.userId` | `hash` | `hash` or `raw` |
| `callers` | `[]` | Your own callers |
| `resources` | requests 10m CPU and 24Mi, limits 250m CPU and 64Mi | Pod resources |

With the gate on, the controller's port 8083 admits only the gate and a few system pods. The gate has the cluster role `system:auth-delegator`, for TokenReview. It runs as user 65532 with a read-only root filesystem and no capabilities.
