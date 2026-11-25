---
title: Console HTTP API
sidebar_position: 1
description: Every route of the OpenAgentix console API, with request and response fields, error codes, limits, security headers, environment variables, extension interfaces and curl examples.
---

# Console HTTP API

This page lists everything the console service answers over HTTP. It was written from the code in `services/console`. If this page and the code differ, the code is right.

Status words used on this page:

- **available**: built and working in the default build.
- **available but off by default**: built, but you must turn it on.
- **reserved (designed, not built)**: planned, but there is no code yet.

A machine-readable copy of the routes is in the [OpenAPI file](https://github.com/openagentix/openagentix/blob/main/docs/diary/reference/console-openapi.yaml) (`docs/diary/reference/console-openapi.yaml` in the repository). A script, `hack/docs/check-console-openapi.sh`, fails the test run when the file and the Go routes differ.

For what the console is and how to install it, read [Console](../features/console.md).

## Basics

| Item | Value |
|---|---|
| Base path | `/api/v1` |
| Port | `8080` (set with `CONSOLE_ADDR`) |
| Body format | JSON, `application/json` |
| Authentication | `Authorization: Bearer <token>` header |
| Error format | `{"error": {"code": "...", "message": "..."}}` |
| Every answer has | the header `X-Request-Id` (16 hex characters) |
| In the chart | **available but off by default** (`console.enabled: false`) |

The console has no cookie and no session. The token goes in the `Authorization` header of every request. The web app keeps the token in memory only.

## Authentication

1. The operator token is a file, mounted from a Secret. The path is in `CONSOLE_TOKEN_FILE`.
2. The console reads the file again when it changes. You can rotate the token without a restart.
3. The real mode needs a token of at least 32 characters. It must not be `demo-token`. The console will not start with a weaker token. If you rotate to a weaker one, the console refuses every request.
4. The console compares a SHA-256 hash of the token in constant time.
5. The header must be `Authorization: Bearer <token>`. The word `Bearer` is not case sensitive. A header longer than 8 KiB is refused.
6. A request with no valid token gets 401 and the header `WWW-Authenticate: Bearer realm="openagentix-console"`.
7. Every user is the same identity: subject `console`, role `operator`. There are no per-user roles.

Which routes need the token:

| Route | Token needed |
|---|---|
| `GET /healthz` | no |
| Any other path that is not under `/api/` (the web app) | no |
| Every route under `/api/v1` | yes |
| An unknown path under `/api/` | no (it answers 404 or 405 at once) |

### Sign-in throttle

Only failed sign-ins count. A good request does not count.

| Setting | Value |
|---|---|
| Limit per remote address | `CONSOLE_AUTH_FAIL_LIMIT`, default 10 failures in one minute |
| Limit for all addresses together | `CONSOLE_AUTH_FAIL_LIMIT_GLOBAL`, default 100 |
| What happens at the limit | 429, code `too_many_attempts`, header `Retry-After` |
| First lock-out | 1 minute |
| Next lock-outs | double each time, up to 15 minutes |
| During a lock-out | even the right token waits |
| Address used | the TCP peer. `X-Forwarded-For` is not read |
| Memory | at most 2048 addresses. More addresses share one entry |

Behind `kubectl port-forward`, every client has the address `127.0.0.1`. The per-address limit is then a limit for everybody.

## Order of checks

For a route under `/api/v1`, the console checks in this order. The first check that fails ends the request.

1. Security headers are set.
2. Host check. Not on the list: 421, empty body.
3. `Origin` check, on every method. Not allowed: 403 `cross_origin`.
4. Method check. Not GET, HEAD, POST, PUT or DELETE: 405.
5. For POST, PUT and DELETE: `Sec-Fetch-Site` and `Origin` check. Foreign: 403 `cross_origin`.
6. Sign-in throttle. Locked: 429 `too_many_attempts`.
7. Token check. Bad: 401 `unauthenticated`.
8. First authorization (no body read yet). No: 403 `forbidden`.
9. For validate only: rate limit. Over: 429 `rate_limited`.
10. Body checks (type, size, JSON shape).
11. For create and update: second authorization, with the name and a summary of the spec. No: 403 `forbidden`.
12. For writes: the audit sink `PreWrite`, if the sink has one.
13. The call to the cluster.
14. For writes: one audit record.

## Routes

All routes are **available** unless the table says otherwise.

| Method | Path | Token | Action (for the Authorizer) | What it does |
|---|---|---|---|---|
| GET | `/healthz` | no | none | Liveness and readiness |
| GET | `/api/v1/session` | yes | read | Who you are and what you may do |
| GET | `/api/v1/platform` | yes | read | Catalog and policy summary |
| GET | `/api/v1/agents` | yes | read | List agents |
| POST | `/api/v1/agents` | yes | create | Create an agent definition |
| POST | `/api/v1/agents/validate` | yes | validate | Dry run, writes nothing |
| GET | `/api/v1/agents/{name}` | yes | read | Read one agent |
| PUT | `/api/v1/agents/{name}` | yes | update | Change an agent definition |
| DELETE | `/api/v1/agents/{name}` | yes | delete | Delete an agent definition |
| GET | `/api/v1/metrics/summary` | yes | read | Spend and tokens (**available but off by default**) |
| GET | `/api/v1/traces` | yes | read | Recent agent turns (**available but off by default**) |
| GET | `/api/v1/traces/{traceId}` | yes | read | The spans of one turn (**available but off by default**) |
| GET, HEAD | any other path | no | none | The web app (see below) |

Metrics and traces need a store. Without one, those routes answer 503. The chart sets the store address when the bundled observability stack is on.

### GET /healthz

Answer 200: `{"status": "ok"}`. No token. The Host check still applies. A kubelet probe must send `Host: localhost` (the chart does this).

### GET /api/v1/session

Answer 200:

| Field | Type | Meaning |
|---|---|---|
| `subject` | string | Always `console` in the community build |
| `role` | string | `operator`, or `viewer` when the Authorizer refuses create, update or delete |
| `canWrite` | boolean | True only when `capabilities.create`, `update` and `delete` are all true |
| `capabilities` | object of booleans | Keys `create`, `update`, `delete`, `validate`. What the Authorizer allows for a bare resource |
| `demo` | boolean | True in demo mode, or when the catalog says `"demo": true` |
| `version` | string | Build version, `dev` for a local build |
| `edition` | string | Always `community` |
| `namespace` | string | The one namespace the console reads and writes |
| `context` | string | Text from `CONSOLE_CONTEXT`, may be empty |

### GET /api/v1/platform

Answer 200. It is built from the two mounted files (catalog and policy). It has no secrets and no image names.

| Field | Type | Meaning |
|---|---|---|
| `demo` | boolean | Demo data |
| `adapters` | object | `runtime`, `modelGateway`, `tools` (strings) |
| `namespaces` | object | `agents`, `gateway`, `tools` (strings) |
| `gatewayBaseUrl` | string | Model gateway base URL |
| `gateEnabled` | boolean | True when the catalog has a gate URL |
| `models` | array of string | Model names |
| `toolServer` | string | Tool server name |
| `profiles` | array of object | Each has `name`, `toolServer`, `codeMode` (boolean), `tools` (array of string) |
| `knowledge` | object | `available` (boolean), `tools` (array), `prompt` (string) |
| `notify` | object | Same fields as `knowledge` |
| `memory` | object | `available`, `expiryEnabled` (boolean), `defaultTtlDays` (integer), `prompt` |
| `skills` | array of object | Each has `name` and `ref`. Sorted by name |
| `reservedNames` | array of string | Names an agent may not use |
| `policy` | object | See the policy table below |
| `metrics` | object | `available` (boolean): true when `CONSOLE_METRICS_URL` is set |
| `traces` | object | `available` (boolean): true when `CONSOLE_TRACES_URL` is set |

Policy object:

| Field | Type | Meaning |
|---|---|---|
| `maxAgents` | integer | Limit of accepted built definitions |
| `allowedModels` | array of string | Allowed models |
| `requireToolProfile` | boolean | A definition must name a tool profile |
| `allowedProfiles` | array of string | Allowed profiles |
| `allowKnowledge` | boolean | Knowledge allowed |
| `allowNotify` | boolean | Notify allowed |
| `allowedSkills` | array of string | Allowed skills |
| `memory` | object | `allowed` (boolean), `maxTtlDays` (integer), `requireExpiry` (boolean) |
| `egress` | object | `allowedOrigins` (array), `inClusterDestinations` (array) |
| `reservedNames` | array of string | Reserved names |
| `suspendAll` | boolean | All agents are paused |

Arrays are never `null`. They are empty arrays.

Errors: 503 `platform_unavailable` when the console cannot read the mounted files.

### GET /api/v1/agents

Answer 200:

| Field | Type | Meaning |
|---|---|---|
| `items` | array of Agent | See the Agent table |
| `used` | integer | Built definitions read. The policy `maxAgents` is compared with this |
| `warnings` | array of string | Parts that could not be read (for example a chart agent) |
| `truncated` | boolean | True when the cluster holds more objects than the console reads |
| `cap` | integer | The most objects read for one kind (`CONSOLE_LIST_MAX`, default 500) |

The console reads lists 100 objects at a time, up to `cap` for each kind.

Agent object:

| Field | Type | Meaning |
|---|---|---|
| `name` | string | Agent name |
| `namespace` | string | Namespace |
| `source` | string | `built` (made with the console or an AgentDefinition) or `chart` (made by chart values, read only) |
| `description` | string | Text |
| `model` | string | Model name |
| `toolProfile` | string | Tool profile name |
| `toolsCount` | integer | Number of tools |
| `knowledge` | boolean | Knowledge on |
| `notify` | boolean | Notify on |
| `memory` | object or absent | `enabled` (boolean), `ttlDays` (integer, may be absent) |
| `suspended` | boolean | Paused |
| `team` | string or absent | From label `openagentix.io/team` |
| `project` | string or absent | From label `openagentix.io/project` |
| `skills` | array of string | Skill names |
| `egressCount` | integer | Number of egress entries |
| `effectiveTools` | array of string | Tools the controller allowed |
| `effectiveEgress` | array of string | Egress the controller allowed |
| `state` | string | `ready`, `pending`, `refused`, `error` or `paused` |
| `stateReason` | string | One sentence, may be empty |
| `deleting` | boolean | Being deleted |
| `conditions` | array of Condition | See below |
| `generation` | integer | Object generation |
| `updated` | string | Time of last update |
| `resourceVersion` | string or absent | Send it back in an update |

How `state` is chosen, in this order:

| Order | If | State |
|---|---|---|
| 1 | The object is being deleted | `pending` |
| 2 | Condition `Accepted` is `False` | `refused` |
| 3 | `spec.suspend` is true | `paused` |
| 4 | Condition `Ready` is `True` | `ready` |
| 5 | `KeyReady` is `False`, or `Applied` is `False` with reason `ApplyFailed`, `RenderFailed`, `CheckFailed`, `PruneFailed` or `NameConflict` | `error` |
| 6 | Anything else | `pending` |

Condition object: `type`, `status`, `reason` (strings), and optional `message`, `observedGeneration` (integer), `lastTransitionTime`.

### GET /api/v1/agents/`{name}`

`name` must be a DNS label: lower case letters, digits and dashes, start with a letter, at most 40 characters. Another value gives 404.

Answer 200: all the Agent fields, and:

| Field | Type | Meaning |
|---|---|---|
| `readOnly` | boolean | True for a chart agent |
| `spec` | Spec or absent | Built agents only |
| `status` | Status or absent | The controller status |
| `yaml` | string | The definition as YAML text |
| `chart` | object or absent | Chart agents: what could be read of their runtime objects |
| `objects` | array of object | Owned objects: `kind`, and optional `name`, `state`, `note` |
| `unmanaged` | array of string or absent | Spec fields the console cannot edit. They are kept on save |

Spec object (the fields the console manages):

| Field | Type | Required | Meaning |
|---|---|---|---|
| `description` | string | no | Text |
| `model` | string | yes | Model name from the catalog |
| `instructions` | string | yes | The system prompt |
| `toolProfile` | string | no | Tool profile name (the policy may require it) |
| `tools` | array of string | no | Tool names |
| `knowledge` | object | no | `enabled` (boolean), `collections` (array of string) |
| `notify` | object | no | `enabled` (boolean), `destinations` (array of string) |
| `memory` | object | no | `enabled` (boolean), `ttlDays` (integer) |
| `skills` | array of object | no | Each has `name` and optional `version` |
| `egress` | object | no | `allow` (array of string, origins such as `https://api.example.org`) |
| `suspend` | boolean | no | Pause the agent |

Status object: `observedGeneration`, `conditions`, `effectiveTools`, `effectiveEgress`, `violations` (arrays), and optional `endpoint` (`protocol`, `url`, `protocolVersion`), `revision`, `capabilities`, `agentRef` (`apiVersion`, `kind`, `name`), `controller`. The `controller` object is passed on as it is. Nothing reads a field of it.

Errors: 404 `not_found`.

### POST /api/v1/agents

Request body (the console refuses unknown fields):

| Field | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | yes | DNS label, at most 40 characters, not `new` and not `playground` |
| `spec` | Spec | yes | See the Spec table |
| `resourceVersion` | string | no | Ignored on create |

Answer 201 with the Detail object, and the header `Location: /api/v1/agents/<name>`.

Errors:

| Status | Code | When |
|---|---|---|
| 422 | `invalid` | The name is not valid, or the cluster refused a field |
| 409 | `exists` | An agent with that name exists (built, or from chart values) |
| 403 | `forbidden` | The Authorizer or the audit sink refused |
| 415, 413, 400 | see Errors | Body problems |

### POST /api/v1/agents/validate

A dry run. Nothing is saved. The body is the same as the create body. `name` may be empty.

Answer 200:

| Field | Type | Meaning |
|---|---|---|
| `schema` | object | `ok` (boolean), `skipped` (boolean), `errors` (array of string) |
| `predicted` | array of object | Each has `field` and `message`. A guess from the console's small rule set |
| `prediction` | boolean | Always true |
| `note` | string | `These are predictions from the console's small rule set. The controller's status.violations after saving are the authority.` |

`schema.skipped` is true when:

- the identity may not write (a viewer). No request goes to the cluster.
- `name` is empty. There is nothing to check yet.

The `predicted` list is not the controller's answer. After you save, `status.violations` is the authority.

Limit: `CONSOLE_VALIDATE_PER_MINUTE` per identity, default 60. Over the limit: 429 `rate_limited` and `Retry-After`.

### PUT /api/v1/agents/`{name}`

Request body:

| Field | Type | Required | Meaning |
|---|---|---|---|
| `name` | string | no | If present, it must equal the name in the path |
| `resourceVersion` | string | yes | The value you read. A stale value gives 409 |
| `spec` | Spec | yes | The fields to set |

The console reads the stored object and replaces only the fields it manages. Other spec fields and all metadata stay as they were. A field you leave out of the managed list is removed.

Answer 200 with the Detail object.

Errors: 400 `bad_request` (no `resourceVersion`), 403 `read_only` (chart agent), 404 `not_found`, 409 `conflict`, 422 `invalid`.

A definition that takes its prompt from a ConfigMap (`instructionsFrom`) cannot have `instructions` set here. That gives 422 `invalid`.

### DELETE /api/v1/agents/`{name}`

Answer 202: `{"name": "<name>", "deleting": true}`. The controller's finalizer removes what it made.

Errors: 403 `read_only` (chart agent), 404 `not_found`.

### GET /api/v1/metrics/summary

**Available but off by default.** Needs `CONSOLE_METRICS_URL`.

Query: `window=24h` (default) or `window=7d`. Other values give 400 `invalid`.

Answer 200:

| Field | Type | Meaning |
|---|---|---|
| `window` | string | `24h` or `7d` |
| `spendUsd` | number | Spend in the window |
| `spendTodayUsd` | number | Spend today |
| `tokensIn` | number | Input tokens |
| `tokensOut` | number | Output tokens |
| `requests` | number | Model requests counted by the gateway |
| `cacheReadShare` | number or absent | Cache-read tokens over input tokens. Absent when the gateway reports no cache-read type |
| `byUser` | array of object | At most 20. Each has `user`, `costUsd`, `tokensIn`, `tokensOut`, `tokensCacheRead` |
| `series` | array of number | Spend per step, 24 points, oldest first |
| `generatedAt` | string | Time |

The queries are fixed text. The browser chooses only the window name.

Limits: 8 second timeout, 1 MiB read per answer, 100 series. Any failure is 503 `metrics_unavailable`.

### GET /api/v1/traces

**Available but off by default.** Needs `CONSOLE_TRACES_URL`.

Answer 200: `{"items": [Turn]}`. At most 30 turns, from at most 20 services, over the last 6 hours.

| Turn field | Type | Meaning |
|---|---|---|
| `traceId` | string | 32 hex characters |
| `conversationId` | string or absent | Conversation id |
| `start` | string | Time |
| `agent` | string | Agent name |
| `outcome` | string | Result of the turn |
| `modelCalls` | integer | Number of model calls |
| `durationMs` | integer | Duration in milliseconds |
| `tokensIn` | integer | Input tokens |
| `tokensOut` | integer | Output tokens |

Errors: 503 `traces_unavailable`.

### GET /api/v1/traces/`{traceId}`

**Available but off by default.** Needs `CONSOLE_TRACES_URL`.

`traceId` must be 32 lower-case hex characters. Otherwise 400 `invalid`, and nothing goes to the store.

Answer 200:

| Field | Type | Meaning |
|---|---|---|
| `traceId` | string | The id |
| `durationMs` | integer | Total duration |
| `spans` | array of Span | See below |

Span: `id`, `service`, `name` (strings), optional `parentId`, `offsetMs`, `durationMs` (integers), `error` (boolean), `attrs` (object of strings). Only a fixed list of attributes is passed on: model, token counts, agent, tool name, task state and error type. Prompts, answers, tool arguments, tool results and headers are always dropped.

Errors: 400 `invalid`, 503 `traces_unavailable`.

### Any other path (the web app)

| Case | Answer |
|---|---|
| Under `/api/`, path unknown | 404 `not_found`: `There is no such route.` |
| Under `/api/`, path known, wrong method | 405 `method_not_allowed`: `This route does not answer <METHOD>.` with the header `Allow` |
| Not under `/api/`, method is not GET or HEAD | 405 `method_not_allowed`: `This route only answers GET.` with `Allow: GET, HEAD` |
| Not under `/api/`, file exists | The file |
| Not under `/api/`, no file, no extension | `index.html` (single page app routes) |
| Not under `/api/`, no file, has an extension or starts with `_app/` | 404, plain text |
| Web app not built into the binary | 503, plain text: `The web app is not built into this binary. Run services/console/build-web.sh, then rebuild the console.` |

## Errors

Every error body is `{"error": {"code": "<code>", "message": "<one sentence>"}}`. The text of a Kubernetes API error is never sent to the caller. It goes to the console log with the request id.

| Status | Code | Message | When |
|---|---|---|---|
| 400 | `bad_request` | `The request body is not valid JSON for this route: <detail>.` | Bad JSON, unknown field, wrong type |
| 400 | `bad_request` | `The request body has data after the JSON value.` | Extra data after the JSON |
| 400 | `bad_request` | `resourceVersion is required to update <name>: send the one you read.` | PUT without `resourceVersion` |
| 400 | `invalid` | `window must be 24h or 7d.` | Metrics window |
| 400 | `invalid` | `A trace id is 32 lower-case hexadecimal characters.` | Trace id |
| 401 | `unauthenticated` | `Sign in with the console token.` | No or wrong token |
| 403 | `forbidden` | The Authorizer's reason. Built in, viewer mode: `This console is read-only (viewer mode). Ask an operator to turn off viewer mode in the console settings.` | Authorizer says no |
| 403 | `forbidden` | `This change was refused by the console's audit policy.` | `PreWrite` returned `ErrRefused` |
| 403 | `cross_origin` | `This request came from another origin. The console answers only its own pages.` | `Origin` header not on the host list |
| 403 | `cross_origin` | `This request came from another origin. The console accepts changes only from its own pages.` | POST, PUT or DELETE with a foreign `Sec-Fetch-Site` or `Origin` |
| 403 | `read_only` | `<name> comes from chart values (agents[]). Change it in your values file and run install.sh.` (for DELETE: `Remove it from your values file and run install.sh.`) | PUT or DELETE of a chart agent |
| 404 | `not_found` | `There is no agent with that name.` | `{name}` is not a valid name |
| 404 | `not_found` | `There is no agent named <name> in namespace <ns>.` | GET of a missing agent |
| 404 | `not_found` | `There is no built agent named <name> in namespace <ns>.` | PUT or DELETE of a missing agent |
| 404 | `not_found` | `There is no such route.` | Unknown `/api/` path |
| 405 | `method_not_allowed` | `The console API answers GET, HEAD, POST, PUT and DELETE only.` | Other method. Header `Allow: GET, HEAD, POST, PUT, DELETE` |
| 405 | `method_not_allowed` | `This route does not answer <METHOD>.` | Known path, wrong method |
| 409 | `exists` | `An agent named <name> already exists. Pick another name.` | Create |
| 409 | `exists` | `An agent named <name> already exists: it comes from chart values. Pick another name.` | Create over a chart agent |
| 409 | `conflict` | `<name> was changed by someone else (or by the controller) since you opened it. Reload it, then apply your changes again.` | Stale `resourceVersion` |
| 413 | `too_large` | `The request body is larger than 256 KiB.` | Body over the limit |
| 415 | `unsupported_media_type` | `Send the body as application/json.` | Wrong `Content-Type` |
| 421 | none | empty body | Host not on the list |
| 422 | `invalid` | `The name is not valid: <problem>.` | Bad name on create |
| 422 | `invalid` | `Names cannot change; create a new agent instead.` | PUT with a different `name` |
| 422 | `invalid` | `The Kubernetes API refused <name> as invalid: <field paths>.` | The cluster refused a field |
| 422 | `invalid` | `The Kubernetes API refused <name> as invalid, and named no field the console can show. Check the values you entered against the form's limits.` | Same, without field names |
| 422 | `invalid` | `This agent takes its instructions from a ConfigMap (instructionsFrom). The console cannot edit them: change the ConfigMap, or remove instructionsFrom with kubectl first.` | PUT of such an agent |
| 422 | `admission_denied` | `A policy in the cluster (an admission webhook or an admission policy) refused <name>. Ask a cluster operator which policy applies; its reason is in the cluster's own log, not here.` | Admission refused |
| 422 | `quota_exceeded` | `The resource quota of namespace <ns> is used up, so <name> could not be saved. Delete something you no longer need or ask an operator to raise the quota.` | Quota |
| 429 | `too_many_attempts` | `Too many failed sign-in attempts. Wait before you try again.` | Sign-in throttle. Header `Retry-After` |
| 429 | `rate_limited` | `Too many checks in a minute. Wait a moment, then try again.` | Validate limit. Header `Retry-After` |
| 499 | `canceled` | `The request was canceled.` | Client left |
| 500 | `internal` | `The console failed to handle this request. Check the console log for the request id <id>.` | Unexpected error |
| 502 | `cluster_forbidden` | `Could not <what>: the Kubernetes API returned <401 or 403>. The console's ServiceAccount may not do this in namespace <ns>. Ask an operator to bind the openagentix-agent-builder Role.` | The cluster said no to the console |
| 502 | `cluster_missing` | `Could not <what>: the Kubernetes API returned 404. The AgentDefinition kind may not be installed. Check that controlPlane.enabled is true in chart values.` | CRD missing |
| 502 | `cluster_unreachable` | `Could not <what>: the Kubernetes API is not reachable from the console pod. Check the cluster and the network.` | Network |
| 502 | `cluster_error` | `Could not <what>: ...` and `Request id: <id>.` | Any other cluster failure. Details are in the log |
| 503 | `audit_unavailable` | `The console cannot record this change right now, so it did not make it. Try again later.` | `PreWrite` failed. The write is not made |
| 503 | `platform_unavailable` | `Could not read the platform catalog and policy: the console cannot open its mounted files. Check that controlPlane.enabled is true and that the console mounts the control-plane ConfigMaps.` | Mounted files unreadable |
| 503 | `metrics_unavailable` | `Metrics are not available: the console cannot read the metrics store. Check that observability is on and that console.metrics.url is set in chart values.` | No store, or it failed |
| 503 | `traces_unavailable` | `Traces are not available: the console cannot read the trace store. Check that observability is on and that console.traces.url is set in chart values.` | No store, or it failed |
| 504 | `timeout` | `The console did not get an answer in time. Try again.` | Request deadline |

Valid agent name for a create: 1 to 40 characters, matching `^[a-z]([-a-z0-9]*[a-z0-9])?$`. The `<problem>` text is one of: `name is required`, `name must be at most 40 characters`, `name must be a DNS label: lower case letters, digits and dashes, starting with a letter`, or `name "<name>" is used by a page of the console; pick another`.

## Limits

| Limit | Value | Setting |
|---|---|---|
| Request body | 256 KiB (413 above) | fixed |
| Body content type | `application/json` only (415) | fixed |
| Unknown JSON fields | refused (400) | fixed |
| Header block | 16 KiB (431 above, plain text, no console headers) | fixed |
| Bearer header | 8 KiB | fixed |
| Per-request deadline | 15 s (504) | `CONSOLE_REQUEST_TIMEOUT`, 1 s to 5 m |
| Header read | 10 s | fixed |
| Request read | 30 s | fixed |
| Response write | 60 s | fixed |
| Idle connection | 120 s | fixed |
| Failed sign-ins | 10 per address per minute, 100 in all | `CONSOLE_AUTH_FAIL_LIMIT`, `CONSOLE_AUTH_FAIL_LIMIT_GLOBAL` |
| Validate calls | 60 per identity per minute | `CONSOLE_VALIDATE_PER_MINUTE` |
| Objects read per kind | 500 | `CONSOLE_LIST_MAX` |
| Metrics and traces store calls | 8 s each | fixed |
| Methods | GET, HEAD, POST, PUT, DELETE | fixed |

There is no general rate limit on read routes, and none on writes except the validate limit.

## Security headers

The console sets these on every answer, including 421 and 403:

| Header | Value |
|---|---|
| `Content-Security-Policy` | `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `no-referrer` |
| `Cross-Origin-Opener-Policy` | `same-origin` |
| `Cross-Origin-Resource-Policy` | `same-origin` |
| `X-Frame-Options` | `DENY` |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=()` |
| `X-Request-Id` | 16 hex characters, new for each request |
| `Cache-Control` | `no-store` on `/api/` and `/healthz` |
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains`. **Available but off by default**: set `CONSOLE_HSTS=1` |

Go's own 400 and 431 answers (a broken request line, a header block over 16 KiB) are written before the console runs. They have no console headers.

## Host allowlist

The console checks the `Host` header on every request, also `/healthz` and the web app. This closes DNS rebinding.

| Rule | Detail |
|---|---|
| Always allowed | `localhost`, `127.0.0.1` and `[::1]`, any port |
| Extra names | `CONSOLE_ALLOWED_HOSTS`, comma separated. A name with no port allows any port. `name:port` allows that port only |
| Not allowed | Answer 421 with an empty body |
| Names | Lower-cased. A trailing dot is removed |
| `Origin` header | On any method, it must be an `http` or `https` origin with no path, user or query, on the list, and with the same host and port as the request. Otherwise 403 `cross_origin` |

A kubelet probe sends the pod IP as `Host`. The chart's probes send `Host: localhost` for this reason.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CONSOLE_ADDR` | `:8080` (`127.0.0.1:8080` in demo mode) | Listen address |
| `CONSOLE_TOKEN_FILE` | none, required | File with the login token. At least 32 characters, not `demo-token` |
| `CONSOLE_CATALOG_FILE` | none, required | Platform catalog JSON |
| `CONSOLE_POLICY_FILE` | none, required | Platform policy JSON |
| `CONSOLE_NAMESPACE` | the catalog's agents namespace | The one namespace the console reads and writes |
| `CONSOLE_VIEWER` | off | `1`, `true`, `yes` or `on`: every write is refused with 403 |
| `CONSOLE_KUBE_API` | `https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT` | Kubernetes API address. Must be `https://` |
| `CONSOLE_KUBE_TOKEN_FILE` | `/var/run/secrets/kubernetes.io/serviceaccount/token` | ServiceAccount token, read for every request |
| `CONSOLE_KUBE_CA_FILE` | the ServiceAccount `ca.crt` when the address is in-cluster | Cluster CA |
| `CONSOLE_KAGENT_API` | `api.kagent.dev/v1alpha3` | Group and version of the kagent kinds read for chart agents |
| `CONSOLE_CONTEXT` | empty | Text shown under the wordmark |
| `CONSOLE_METRICS_URL` | empty | Base URL of a Prometheus-compatible query API. Empty: no metrics |
| `CONSOLE_TRACES_URL` | empty | Base URL of a Jaeger query API. Empty: no traces |
| `CONSOLE_REQUEST_TIMEOUT` | `15s` | Per-request deadline, 1 s to 5 m |
| `CONSOLE_LOG_LEVEL` | `info` | `debug`, `info`, `warn` or `error` |
| `CONSOLE_ALLOWED_HOSTS` | empty | Extra Host names. Not URLs. A value with `/`, space, `@`, `?` or `#` stops the start |
| `CONSOLE_AUTH_FAIL_LIMIT` | `10` | 1 to 1000 |
| `CONSOLE_AUTH_FAIL_LIMIT_GLOBAL` | `100` | 1 to 100000 |
| `CONSOLE_VALIDATE_PER_MINUTE` | `60` | 1 to 10000 |
| `CONSOLE_LIST_MAX` | `500` | 1 to 5000 |
| `CONSOLE_HSTS` | off | `1`, `true`, `yes` or `on` sends the HSTS header |
| `CONSOLE_ALLOW_INSECURE_KUBE_API` | off | Development only. Accept an `http://` API address |
| `CONSOLE_DEV_FAKE` | off | Demo mode with invented data. **Available but off by default**. Refuses to start with any real cluster setting |
| `CONSOLE_DEV_FAKE_SETTLE` | `8` | Demo mode: seconds before the fake controller gives a verdict. 0 means never |

The metrics and traces URLs must be `http` or `https`, with no user, query or fragment. The write calls to the cluster use the console's own ServiceAccount and the field manager `openagentix-console`.

## What the chart turns on

The chart renders the console only when `console.enabled: true`. It is **available but off by default**. It needs `controlPlane.enabled: true` and the same namespace as the control plane.

| Item | Detail |
|---|---|
| Workload | One replica, image `openagentix/console`, port 8080, user 65532, read-only root filesystem, no capabilities, seccomp `RuntimeDefault` |
| ServiceAccount and Role | `openagentix-console`. One Role in the agents namespace. On `agentdefinitions.openagentix.io`: get, list, create, update, delete (viewer mode: get and list only). On `agents`, `agenttemplates`, `harnesses`, `modelconfigs` of `api.kagent.dev`: list only. No cluster-wide rule. No Secret access |
| Token Secret | `console.tokenSecret`, default name `console-token`, key `token`. The chart does not render the Secret. `install.sh` creates it when it is missing, with 48 random characters. Mounted as a file |
| Mounted files | The control plane's catalog and policy ConfigMaps, read only |
| Service | ClusterIP, port 8080. There is no Ingress |
| NetworkPolicy | Only when `networkPolicy.enabled`. Ingress: nobody (`kubectl port-forward` is not blocked by it). Egress: DNS, the Kubernetes API (`console.apiServerCIDRs`, `console.apiServerPorts`), and the bundled metrics store (port 8428) and Jaeger (port 16686) when they are on |
| Probes | `GET /healthz` with `Host: localhost` |
| Environment | `CONSOLE_TOKEN_FILE`, `CONSOLE_CATALOG_FILE`, `CONSOLE_POLICY_FILE`, `CONSOLE_NAMESPACE`. Added when set: `CONSOLE_VIEWER=1` (`console.viewer`), `CONSOLE_ALLOWED_HOSTS` (`console.allowedHosts`), `CONSOLE_METRICS_URL` and `CONSOLE_TRACES_URL` (`console.metrics.url`, `console.traces.url`, or the bundled stores) |
| Not set by the chart | `CONSOLE_HSTS`. Serving the console over TLS behind an Ingress is **reserved (designed, not built)**: it is not built into the chart and not tested |

Chart values of the `console:` block:

| Value | Default | Meaning |
|---|---|---|
| `enabled` | `false` | Render the console |
| `namespace` | empty | Release namespace. Must equal the control plane namespace |
| `tokenSecret.name` | `console-token` | Secret name |
| `tokenSecret.key` | `token` | Key in the Secret |
| `viewer` | `false` | Read-only mode, and a Role with no write verb |
| `allowedHosts` | `[]` | More Host names |
| `apiServerCIDRs` | `[]` | API server addresses for egress. Empty: the API server ports to any address |
| `apiServerPorts` | `[443, 6443]` | API server ports |
| `metrics.url` | empty | Your own metrics store. Empty: the bundled one if on |
| `traces.url` | empty | Your own Jaeger query API. Empty: the bundled one if on |
| `resources` | requests 10m CPU and 32Mi, limits 250m CPU and 128Mi | Pod resources |

## Extension interfaces

The package `github.com/openagentix/openagentix/services/console/ext` is public. It has four small interfaces and no dependency outside the Go standard library. The community build uses the built-in versions from `internal/builtin`.

Status: the `ext` package is **available**. A separate build of the console that supplies its own versions is **reserved (designed, not built)**, because the `server` package is still internal. Login with OIDC, per-user roles and an audit store are also **reserved (designed, not built)**.

### Authenticator

```go
type Authenticator interface {
    Authenticate(r *http.Request) (Identity, error)
}
```

| Rule | Detail |
|---|---|
| Input | The request. It must not read the body |
| Output | `Identity{Subject string, Roles []string}` |
| On error | The server answers 401 and never shows the error text. Return `ext.ErrUnauthenticated` |
| Roles | Free text for an Authorizer. The built-in one ignores them |

Built in: `TokenAuth` (bearer token from a file, constant-time compare, minimum length). Demo mode uses `StaticAuth` with `demo-token` when no token file is set.

### Authorizer

```go
type Authorizer interface {
    Authorize(ctx context.Context, id Identity, action Action, res Resource) Decision
}
```

| Type | Fields |
|---|---|
| `Action` | `read`, `validate`, `create`, `update`, `delete`. Only create, update and delete are writes (`Action.Writes()`) |
| `Resource` | `Kind` (always `agentdefinition`), `Name`, `Spec` (`*SpecSummary`) |
| `SpecSummary` | `Model`, `ToolProfile`, `Team`, `Project`. Team and project are the labels `openagentix.io/team` and `openagentix.io/project`. They are empty on create and the stored values on update |
| `Decision` | `Allowed` (boolean), `Reason` (string). The reason is the 403 message. It must be one plain sentence with no secrets |

Contract:

- For create and update the server asks **twice**. First with the bare resource (no name for a create, no `Spec`), before any body is read. Then, after the body is decoded, with the name and a `SpecSummary`. Both must allow.
- So an implementation that decides on the name or the spec must allow the first (bare) question whenever the identity may create or update something. It refuses in the second one.
- `GET /api/v1/session` asks the bare question for create, update, delete and validate. It reports what is allowed.
- `Name` is empty for list and platform reads.

Built in: `RoleAuthz`. One role that may do everything. With `CONSOLE_VIEWER`, every write is refused.

### AuditSink

```go
type AuditSink interface {
    Record(ctx context.Context, e AuditEvent) error
}
```

`AuditEvent` fields: `Time`, `Subject`, `Action`, `Resource`, `Outcome`, `Status`, `RequestID`. There is no field for a body, instructions, a header or a token. A sink cannot log what it never gets.

`Outcome` is one of `ok`, `denied`, `conflict`, `not_found`, `invalid`, `error`, or `pending` (in a `PreWrite` call only).

Contract:

- One call per write (create, update, delete). Reads and validate are not audited.
- The call comes **after** the write, once the answer is decided. It is best effort. A panic is recovered. A returned error is logged. Neither changes the answer.
- `Record` must not block for long.
- A refused write (403) is audited with outcome `denied`. A resource name is cut to 64 characters.

Built in: `LogAudit`. It writes one JSON log line to standard output, message `audit`, with these fields:

| Field | Meaning |
|---|---|
| `audit` | `true` |
| `who` | Subject, `console` |
| `action` | `create`, `update` or `delete` |
| `kind` | `agentdefinition` |
| `agent` | Agent name |
| `outcome` | See above |
| `status` | HTTP status sent |
| `request_id` | The `X-Request-Id` value |

The log line also has the usual `time` and `level` fields.

### PreWriter

```go
type PreWriter interface {
    PreWrite(ctx context.Context, e AuditEvent) error
}
```

Optional. A sink that must never lose a line (fail closed) also implements it. The server calls `PreWrite` after authentication and both authorizations, and before the cluster is touched. The event has `Outcome: "pending"` and `Status: 0`.

| Return | Result |
|---|---|
| `nil` | The write goes on |
| An error that is, or wraps, `ext.ErrRefused` | 403 `forbidden`: `This change was refused by the console's audit policy.` |
| Any other error, or a panic | 503 `audit_unavailable`. The cluster is not touched |

The built-in sink does not implement `PreWriter`.

## How to call it

These examples work against a console in demo mode, or a real one reached with a port-forward.

Start a demo console (no cluster):

```sh
cd services/console
./build-web.sh
CONSOLE_DEV_FAKE=1 go run ./cmd/console
```

Or reach a console in a cluster:

```sh
kubectl port-forward -n openagentix-system svc/openagentix-console 8080:8080
```

Set the base address and the token. In demo mode the token is `demo-token`. In a cluster, read it from the Secret:

```sh
BASE=http://127.0.0.1:8080
TOKEN=demo-token
# in a cluster:
TOKEN=$(kubectl get secret -n openagentix-system console-token -o jsonpath='{.data.token}' | base64 -d)
```

Health (no token):

```sh
curl -s "$BASE/healthz"
```

Session:

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/session"
```

List agents:

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/agents" | jq '.items[] | {name, source, state}'
```

Validate a definition (dry run):

```sh
curl -s -X POST "$BASE/api/v1/agents/validate" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"demo-agent","spec":{"model":"claude-haiku","instructions":"Answer in one sentence.","toolProfile":"lookup"}}'
```

Create an agent. The model and profile names (`claude-haiku` and `lookup` are the demo ones) must exist in the catalog and be allowed by the policy:

```sh
curl -s -i -X POST "$BASE/api/v1/agents" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"demo-agent","spec":{"model":"claude-haiku","instructions":"Answer in one sentence.","toolProfile":"lookup"}}'
```

Read it, then change it. A change needs the `resourceVersion` you just read:

```sh
RV=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/agents/demo-agent" | jq -r .resourceVersion)
curl -s -X PUT "$BASE/api/v1/agents/demo-agent" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"resourceVersion\":\"$RV\",\"spec\":{\"model\":\"stub\",\"instructions\":\"Answer in two sentences.\",\"toolProfile\":\"basic\"}}"
```

Delete it:

```sh
curl -s -i -X DELETE -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/agents/demo-agent"
```

Metrics for the last 7 days, and the recent turns (only when a store is set):

```sh
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/metrics/summary?window=7d" | jq .
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/traces" | jq '.items[0]'
```

A call through an Ingress name needs that name in `console.allowedHosts` (or `CONSOLE_ALLOWED_HOSTS`). Otherwise the answer is 421.

Command line calls do not send an `Origin` or a `Sec-Fetch-Site` header, so the cross-origin checks do not stop them. A browser page from another origin is stopped.
