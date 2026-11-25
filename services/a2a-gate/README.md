# a2a-gate

A small authenticating reverse proxy in front of the kagent controller's A2A port (8083). It is off by default
and is switched on with the chart value `governance.a2a.enabled`. Why it exists, and what it does and does not
protect: `docs/decisions/0006-governance.md` (Question 1) and `docs/diary/features/security.md`.

What it does for each request:

1. Reads `Authorization: Bearer <token>`. Two kinds of token are accepted:
   - a projected ServiceAccount token with the audience `openagentix-a2a`, checked with a Kubernetes
     TokenReview (a positive answer is cached for 30 seconds, a refusal for 5);
   - a static key. Its SHA-256 (64 hex characters) is compared with the files in the mounted keys Secret; the
     file name is the caller name. Agent Kourier sends the key as the Binding's `identity.tokenSecretRef`.
2. Finds the caller's rule in the rules file (JSON, rendered by the chart, holds no secret): the agents the
   caller may reach (`namespace/name`) and the user ids it may assert (`exact`, `prefix` or `fixed`).
3. Passes only these routes, for an allowed agent, and answers 403 for everything else (gRPC and gRPC-Web
   included, content type `application/grpc*`, except the two memory RPCs below for a caller with `memory: true`):
   - `POST /agents/<ns>/<name>` (JSON-RPC) and `POST .../message:send`, `message:stream` (also under `/v1/`);
   - `GET /agents/<ns>/<name>/.well-known/agent-card.json` (and `agent.json`).

   **Methods.** A caller may use only the JSON-RPC methods in its rule (`methods`; without it
   `SendMessage` and `SendStreamingMessage`). The chart sets what its own callers really send: the bridge and each
   schedule `SendMessage`; a Kourier binding `SendMessage`, `SendStreamingMessage`, `GetTask`, `SubscribeToTask` and
   `CancelTask`. A method outside the list gets 403 with `reason: method`. The two REST routes count as
   `SendMessage` and `SendStreamingMessage`. The method is read from the body, so on the JSON-RPC route the **whole
   body must fit in `A2A_GATE_SNIFF_BYTES`** (64 KiB by default, at most 1 MiB) and must be one JSON object with
   exactly one `method` string (names compared without case, as the agent side does, so duplicates cannot hide one).
   If the method cannot be determined (a larger body, a batch, no or two `method` members, text that is not JSON,
   data after the object) the gate **fails closed**: 403, `reason: method`, and nothing reaches the agent.
   The audit field `rpc` carries the method.
   **Memory RPCs (opt-in per caller).** A caller whose rule has `memory: true` may also call two RPCs of kagent's
   `MemoryService` over binary gRPC-Web, and nothing else of any gRPC service: `POST /kagent.runtime.v1.MemoryService/List` and
   `POST /kagent.runtime.v1.MemoryService/Delete` (content type `application/grpc-web` or `application/grpc-web+proto`; no native
   gRPC, no base64 text mode, no compression). Every other path, method, content type and RPC stays 403, `Search`, `AddSession` and
   `AddSessionBatch` included. Which user is meant is **not in the message**: kagent takes it from the authenticated principal, which in
   `insecure` mode is `X-User-Id` (kagent `go/core/internal/service/memory/service.go` `managementScope`, `go/core/internal/grpcserver/interceptors.go`
   forwards the `x-user-id` metadata). The gate therefore sets `X-User-Id` from the caller's rule exactly as for A2A (a user id outside
   the rule gets 403, `reason: user_id`). The message holds only `agent_name`; the gate reads the one frame (at most 600 bytes, within the sniff
   timeout), requires exactly one string field number 1 and nothing else (a second, repeated or unknown field, a trailer or compressed
   frame, a wrong length, bytes after the frame, invalid UTF-8 are all refused with `reason: frame`), requires the agent to be one the rule allows
   (`reason: agent`), and forwards exactly the bytes it verified. The audit line has `rpc` = `MemoryService/List` or `MemoryService/Delete`, the agent, the
   hashed user id and never any content. Without `memory: true`: 403, `reason: memory`.
4. Removes `Authorization`, `Cookie`, `X-User-Id`, `X-Agent-Name`, `X-Share-Token`, `Baggage`, the `X-Forwarded-*`
   headers and the whole query string (kagent reads `?user_id=` before `X-User-Id`), then sets `X-User-Id`
   itself from the rule. The controller stays in `insecure` mode and never sees a caller credential.
5. Streams the response with an immediate flush (SSE).
6. Writes one JSON audit line to stdout: `time`, `caller`, `agent`, `user_id`, `context_id`, `trace_id`, `status`,
   `duration_ms`, `method` (HTTP), `rpc` (JSON-RPC method) and, for a refusal, `reason`. The user id the caller claims is
   recorded only after the caller is authenticated, and cut to 128 bytes. `user_id` is a salted hash by default (`h:` and 8 hex
   digits; the salt is random per process); `A2A_GATE_AUDIT_USER_ID=raw` logs the id itself. The gate reads at
   most `A2A_GATE_SNIFF_BYTES` of a request body to find `contextId`, and never logs or keeps the body.

## Settings (environment)

| Variable | Default | Meaning |
|---|---|---|
| `A2A_GATE_UPSTREAM` | required | the controller, `http://kagent-controller.kagent.svc.cluster.local:8083` |
| `A2A_GATE_RULES` | required | path of the rules JSON |
| `A2A_GATE_KEYS_DIR` | `/etc/a2a-gate/keys` | the key hashes (one file per caller) |
| `A2A_GATE_AUDIENCE` | `openagentix-a2a` | audience projected tokens must carry |
| `A2A_GATE_AUDIT_USER_ID` | `hash` | `hash` or `raw` |
| `A2A_GATE_SNIFF_BYTES` | `65536` | body bytes read to find `contextId` (at most 1 MiB) |
| `A2A_GATE_MAX_BODY` | `8388608` | largest request body (REST routes; JSON-RPC bodies are limited by the line above) |
| `A2A_GATE_MAX_INFLIGHT` | `128` | requests handled at once; the next gets 503 with `Retry-After` and `reason: busy` |
| `A2A_GATE_ADDR` | `:8080` | listen address |
| `A2A_GATE_ROUTES_FILE` | empty | path of the controller-written routes file; empty switches "bring your own agent" off and the gate behaves exactly as before |
| `A2A_GATE_WORKLOAD_NAMESPACE` | required with the routes file | DNS label of the namespace container agents run in |
| `A2A_GATE_WORKLOAD_PORT` | `8080` | port of those agents |
| `A2A_GATE_PUBLIC_URL` | required with the routes file | address clients use for the gate (`https://a2a.example.com`); used in rewritten agent cards |

## Bring your own A2A agent (container agents)

An agent that runs as its own container (not in kagent) is listed in the routes file. The **controller** writes it; the
gate only reads it. The chart mounts the ConfigMap as a **directory** (not `subPath`), because the kubelet updates a
directory mount in place and never updates a `subPath` mount; `A2A_GATE_ROUTES_FILE` points at the file inside it.

```json
{"container": ["kagent/echo-go", "kagent/other"]}
```

That member and nothing else. Parsing is strict: any other or repeated key, a wrong type, an entry that is not
`<namespace>/<name>` with both parts lowercase DNS labels (1-63 characters, `a-z0-9-`, no dots), a duplicate entry,
more than 1000 entries, a file over 256 KiB, or data after the object rejects the whole file.

- **No host in the list.** For a listed agent the gate builds the upstream itself:
  `http://<name>.<A2A_GATE_WORKLOAD_NAMESPACE>.svc.cluster.local:<port>`. The list chooses only *which* agent goes to
  the workload namespace; whoever can write it cannot point the gate at another host. Agents not listed go to
  `A2A_GATE_UPSTREAM` exactly as before.
- **Paths.** JSON-RPC `POST /agents/<ns>/<name>` goes to `POST /` on the agent; `message:send` and `message:stream`
  (with or without the `v1/` alias) go to `POST /message:send` and `/message:stream`; the card path goes to
  `GET /.well-known/agent-card.json`. The query is wiped and headers are stripped as for any agent.
- **Callers.** Rules are unchanged: a caller needs the agent in its `agents` list, and the agent receives the
  resolved `X-User-Id` (information, not proof).
- **Reload.** The file is checked every 10 s and swapped atomically when its content changes. No restart.
- **Fail closed.** Missing or malformed at start: the feature stays on with an empty list, so a listed agent is not
  routed to the workload namespace; it goes to the kagent upstream like an unlisted one (a 404 there). The gate does
  not refuse to start, because that would take every kagent agent down for one bad file, and an empty list can never
  add a route. A malformed update keeps the last good list and logs one line (the reason, never the file content).
  The rule: a malformed list never adds a route. A *valid* list that no longer names an agent removes its route.
- **Agent card.** The card of a listed agent is parsed (at most 64 KiB; it must be one JSON object, else
  `502 {"error":"agent card ..."}`). `supportedInterfaces` is replaced with the gate's own two (`JSONRPC` and `HTTP+JSON`,
  `url` = `A2A_GATE_PUBLIC_URL/agents/<ns>/<name>`, `protocolVersion` `1.0`); `securitySchemes`, `security`,
  `securityRequirements` (the gate is the authentication) and the legacy `url`, `preferredTransport`,
  `additionalInterfaces` are dropped; all other members pass through. Without this a client would call the pod directly.
  A non-200 answer from the agent passes through unchanged.

The gate needs the `system:auth-delegator` ClusterRole for TokenReview (the chart binds it). It has no
dependency outside the Go standard library.

## Limits that protect the gate itself

- Header block at most 16 KiB (431 above); header read within 10 s.
- The start of a body must arrive within 10 s (408, `reason: body_timeout`); the deadline is cleared before the
  request is proxied, so a long upload or an SSE stream is not cut. The buffer is sized by `Content-Length`.
- At most `A2A_GATE_MAX_INFLIGHT` requests at once. Probes do not count. A flood from a pod that may reach the gate
  still uses these slots, which is why the gate's NetworkPolicy lists its callers.
- A bearer value over 8 KiB is refused. Before a TokenReview the gate reads the unverified payload and skips the
  call unless the audience is ours, `iss` is present and `exp` is in the future. One review per token at a time
  (singleflight), at most 8 reviews at once, and a refusal cache that is kept apart from the good answers, so a
  flood of bad tokens cannot push a valid caller out of the cache.

## Tests

`make test` runs everything with `-race` and needs nothing but Go.
