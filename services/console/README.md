# console

The OpenAgentix web console (ADR 0007, "Console"): a small Go service with a JSON API, and the single-page app (Svelte, in
`console/` at the repository root) embedded in the binary with `go:embed`. One image, no Node at run time. The design
contract is `docs/console/UI-SPEC.md`.

It has no dependency outside the Go standard library and no Kubernetes client library: `internal/kube` sends requests that
this program builds.

## The six rules of the ADR, and where they are kept

1. **No relay.** The routes below are the whole API; each is written out in `internal/server`. The Kubernetes client has no
   code path that copies a header from the browser's request. `TestNothingFromTheBrowserIsForwardedUpstream` asserts on
   what the fake API server received, and `TestOnlyFixedUpstreamPaths` on the paths.
2. **Narrow identity.** The console's ServiceAccount reads (see "Deploying") and writes only `agentdefinitions.openagentix.io`.
3. **Closed network.** There is no Ingress. The chart's NetworkPolicy (rendered when `networkPolicy.enabled` is true, the default) admits no ingress; the console is reached with `kubectl port-forward`, which a NetworkPolicy does not block.
4. **Login.** A bearer token from a mounted Secret, compared in constant time, read again when the file changes. Strict CSP. The
   real mode refuses to start with a token shorter than 32 characters or equal to `demo-token`; failed sign-ins are throttled; a
   Host allowlist closes DNS rebinding (see "Protections").
5. **One operator identity.** Every user acts as `console`.
6. **Only real data.** The API returns what the cluster and the two mounted files hold, nothing else. The demo mode says so.

## Routes

| Route | Does |
|---|---|
| `GET /healthz` | liveness and readiness; no token |
| `GET /api/v1/session` | who am I (`console`), role (`operator` or `viewer`), `canWrite`, `capabilities` (`create`, `update`, `delete`, `validate`: what the Authorizer allows for a bare resource; `canWrite` is true only when the first three are), `demo`, version, namespace |
| `GET /api/v1/platform` | catalog and policy summary read from the two mounted JSON files (the policy includes `suspendAll` and `egress.inClusterDestinations`); no secrets, no images |
| `GET /api/v1/agents` | built definitions (with `effectiveTools` and `effectiveEgress` from their status) plus chart agents (`source: "chart"`, read-only), `used` = built definitions counted by `maxAgents`; `truncated` and `cap` when the cluster holds more than the console reads (see "Bounded reads") |
| `GET /api/v1/metrics/summary` | spend, tokens, requests, cache-read share, spend per gateway user and a 24-point spend series for `?window=24h` (default) or `7d`, read from the metrics store named by `CONSOLE_METRICS_URL`. The queries are fixed text in `internal/observe` (the ones of README "Observability"); the browser chooses only the window name, nothing else reaches the store. Bounded: 8 s timeout, 1 MiB per answer, 100 series, 20 users. Any failure is 503 `metrics_unavailable` with one sentence; what the store said is only logged. `GET /api/v1/platform` carries `metrics.available` (true when a store is configured) |
| `GET /api/v1/schedules` | the chart's schedules, read from the CronJobs labelled `openagentix.io/schedule` in `CONSOLE_SCHEDULES_NAMESPACE`: name, agent, cron expression, time zone, concurrency policy, timeout, `state` (`active` or `suspended`), last scheduled and last successful time. No prompt, token or user id is read or copied. Without that variable the answer is `configured: false` and an empty list. A refused read is 502 `cluster_error` with one sentence (the Kubernetes text goes to the log) |
| `GET /api/v1/access` | the A2A gate's caller rules, read from the ConfigMap `a2a-gate-rules` in `CONSOLE_GATE_NAMESPACE`: caller name, `source` (`chart` for the bridge, schedule and channel callers, `values` for `governance.a2a.callers`), ServiceAccount, whether it uses a key, agents, methods (the gate's default when the rule has none), memory switch and the kind of user id rule (`exact`, `prefix` or `fixed`). Never a key, a hash or a user id value. Without the variable: `configured: false` and an empty list; a missing ConfigMap is 404 `gate_rules_missing` |
| `GET /api/v1/traces` | the most recent agent turns (time, agent, outcome, model calls, duration, tokens) read from the Jaeger query API named by `CONSOLE_TRACES_URL`. No input: the queries are fixed text in `internal/observe` (service list, then the `a2a.request` operation over a 6 h look-back, at most 20 services, 30 turns). 503 `traces_unavailable` when not configured or not answering |
| `GET /api/v1/traces/{traceId}` | the spans of one turn for the waterfall. The id must be 32 lower-case hex characters (400 otherwise, never sent to the store). Only an allowlist of span attributes is passed on (model, token counts, agent, tool name, task state, error type); prompts, answers, tool arguments and results, and headers are dropped whatever the trace holds |
| `POST /api/v1/agents` | create a definition: body `{name, spec}`; 201, 409 `exists`, 422 `invalid` |
| `POST /api/v1/agents/validate` | dry run: the API server's schema check with `dryRun=All` (nothing is written) and a **predicted** list. An identity that may not write (viewer) gets the predictions only (`schema.skipped: true`): no request reaches the cluster. Limited per identity per minute (429 `rate_limited`) |
| `GET /api/v1/agents/{name}` | spec, status, conditions, YAML text; for a chart agent what could be read of it, `readOnly: true`; `unmanaged` lists spec fields the console cannot edit (see "Saving keeps what it does not know") |
| `PUT /api/v1/agents/{name}` | update `spec`; body `{resourceVersion, spec}`; 409 `conflict` when the version is stale |
| `DELETE /api/v1/agents/{name}` | delete a definition; 202 (the controller's finalizer removes the rest) |
| `/` | any other path: the web app for `GET` and `HEAD` (files, then `index.html` for single-page routes), a JSON 404 or 405 otherwise |

Everything under `/api/` needs `Authorization: Bearer <token>` (401 otherwise, `WWW-Authenticate: Bearer`). Methods other than
GET, HEAD, POST, PUT and DELETE are 405. Errors are `{"error": {"code", "message"}}` with one plain sentence.

**Errors from the cluster.** Nothing the Kubernetes API server wrote (its message, a cause's message, the text of an admission
webhook or policy) is sent to the browser. A refusal is mapped to the console's own sentence: `not_found`, `conflict` or `exists`,
`cluster_forbidden` (the ServiceAccount may not), `quota_exceeded`, `admission_denied` ("a policy in the cluster refused it"),
and `invalid`, which names the field paths (`spec.instructions is required`) and nothing else. Anything the console cannot classify
is one generic sentence, `cluster_error`, with the request id (also the `X-Request-Id` header); the upstream status and a shortened
reason are in the console log under that id. Tests: `TestUpstreamErrorTextIsNeverEchoed`, `TestUpstreamErrorTextOnReadAndValidate`.

**Bounded reads.** Lists are read from the API server a page at a time (`limit=100` and `continue`), up to `CONSOLE_LIST_MAX`
objects per kind (500). When there is more, the answer says `truncated: true, cap: N` and the registry shows "Showing the first N
agents of each kind". `used`, which the policy limit `maxAgents` is compared with, then counts only what was read.

**Saving keeps what it does not know.** An update reads the stored object and replaces only the fields the console manages
(`description`, `model`, `instructions`, `toolProfile`, `tools`, `knowledge`, `notify`, `memory`, `skills`, `egress`, `suspend`; a
field the editor left empty is removed). Every other field of `spec`, and all metadata, is sent back as it was, so
`kubectl`-added fields survive; the same merged object is what the dry run of `validate` sends. A definition that takes its prompt
from a ConfigMap (`instructionsFrom`) is shown with the instructions read-only and a notice, a save sends no `instructions`, and
`instructions` typed next to it is refused with 422.

**Chart agents.** kagent `agents.api.kagent.dev` objects that carry no `openagentix.io/agent-definition` label are listed as
`source: chart`. Their template, harness and model config are read (best effort; a refusal becomes a `warnings` entry) to
fill in model, tools, skills and memory. They cannot be written: `PUT` and `DELETE` answer 403 `read_only`.

**What validate returns.** `schema` is the API server's own answer to a dry run (the CRD's limits and name rules). `predicted`
is a list computed by a **small rule set written for the console** (`internal/predict`): unknown model or profile, a tool the
profile does not offer, knowledge, notify or memory the policy forbids, a skill outside the catalog, an egress origin the policy
patterns do not match, a reserved name, the agent count. The response says `"prediction": true` and carries a note. The
controller's `status.violations` stay the authority. The controller's validator is in `services/control-plane/internal/policy`,
a Go internal package another module cannot import, and the console does not copy it. **Follow-up:** move the validator to a public
package so the console, the controller and the chart tests share one implementation, and the prediction becomes the real answer.

## Resource shape

The console reads and writes `AgentDefinition` in the shape of ADR 0012 ("Change now"): `spec.knowledge` and `spec.notify` are
`{enabled, collections|destinations}`, `spec.skills` is `[{name, version?}]`, `spec.suspend` pauses an agent (state `paused`).
The old boolean and string-list forms are refused (400, unknown or mistyped field). From `status` it reads only the public contract:
`conditions`, `observedGeneration`, `endpoint`, `revision`, `effectiveTools`, `effectiveEgress`, `violations`, `capabilities`,
`agentRef`; `status.controller` is passed on as opaque JSON for a collapsed "internal" section and nothing reads a named field of it
(the Deploy tab lists the runtime Agent from `status.agentRef`, not a Secret from the controller block). Labels `openagentix.io/team` and `openagentix.io/project`
are shown as tags. Chart agents are read from kagent objects and mapped to the same shape.

## Settings (environment)

| Variable | Default | Meaning |
|---|---|---|
| `CONSOLE_ADDR` | `:8080` (`127.0.0.1:8080` in demo mode) | listen address |
| `CONSOLE_TOKEN_FILE` | required | file holding the login token (the mounted Secret); read again when it changes. In the real mode at least 32 characters and not `demo-token`: the console will not start with a weaker one, and a rotation to a weaker one makes it refuse everybody. Generate one with `openssl rand -hex 32` |
| `CONSOLE_CATALOG_FILE` | required | the platform catalog JSON the controller reads |
| `CONSOLE_POLICY_FILE` | required | the platform policy JSON the controller reads |
| `CONSOLE_NAMESPACE` | the catalog's `namespaces.agents` | the only namespace the console reads and writes |
| `CONSOLE_VIEWER` | off | `1` makes every write 403 (one role, read only) |
| `CONSOLE_KUBE_API` | `https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT` | API server address |
| `CONSOLE_KUBE_TOKEN_FILE` | `/var/run/secrets/kubernetes.io/serviceaccount/token` | ServiceAccount token, read again for every request |
| `CONSOLE_KUBE_CA_FILE` | the ServiceAccount `ca.crt` when the address is in-cluster | cluster CA |
| `CONSOLE_KAGENT_API` | `api.kagent.dev/v1alpha3` | group and version of the kagent kinds read for chart agents |
| `CONSOLE_CONTEXT` | empty | text shown under the wordmark (for example `kind-openagentix · kagent`) |
| `CONSOLE_SCHEDULES_NAMESPACE` | empty | namespace of the chart's schedule CronJobs; the chart sets it when `schedules` is not empty. Empty means the Schedules page says no schedules are defined |
| `CONSOLE_GATE_NAMESPACE` | empty | namespace of the A2A gate's rules ConfigMap; the chart sets it when `governance.a2a.enabled` is true. Empty means the Access page says the gate is off |
| `CONSOLE_METRICS_URL` | empty | base URL of a Prometheus-compatible query API (the bundled VictoriaMetrics, `http://victoria-metrics.openagentix-observability.svc:8428`); empty means no metrics and the Overview and Costs pages say so. In demo mode (`CONSOLE_DEV_FAKE`) fixed, invented numbers are served instead |
| `CONSOLE_TRACES_URL` | empty | base URL of the bundled Jaeger query API (`http://jaeger.openagentix-observability.svc:16686`); empty means no traces. `GET /api/v1/platform` carries `traces.available` |
| `CONSOLE_REQUEST_TIMEOUT` | `15s` | per-request deadline, also passed to the Kubernetes calls |
| `CONSOLE_LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `CONSOLE_ALLOWED_HOSTS` | empty | comma-separated host names (optional `:port`) accepted in the `Host` header besides `localhost`, `127.0.0.1` and `[::1]`; set it for an Ingress name. Any other Host is answered `421` |
| `CONSOLE_AUTH_FAIL_LIMIT` | `10` | failed sign-ins per remote address per minute before `429` with `Retry-After`; the back-off doubles per round up to 15 minutes |
| `CONSOLE_AUTH_FAIL_LIMIT_GLOBAL` | `100` | the same cap over all addresses together |
| `CONSOLE_VALIDATE_PER_MINUTE` | `60` | `POST /agents/validate` per identity per minute |
| `CONSOLE_LIST_MAX` | `500` | most definitions (and most chart agents) a list reads |
| `CONSOLE_HSTS` | off | `1` sends `Strict-Transport-Security: max-age=31536000; includeSubDomains`; turn it on when the console is served behind TLS |
| `CONSOLE_ALLOW_INSECURE_KUBE_API` | off | development only: accept an `http://` `CONSOLE_KUBE_API`. Otherwise the console refuses to start, because the ServiceAccount token is sent with every request |
| `CONSOLE_DEV_FAKE` | off | demo mode, see below |
| `CONSOLE_DEV_FAKE_SETTLE` | `8` | demo mode: seconds before the fake controller gives a new or changed definition a verdict (0: never) |

## Extension points (ADR 0010)

In package `github.com/openagentix/openagentix/services/console/ext` (not `internal`, so a separate build can implement them and
call `server.New`, once that package is made public too; today only `ext` is public):

```go
type Authenticator interface { Authenticate(r *http.Request) (Identity, error) }      // error: 401
type Authorizer    interface { Authorize(ctx, Identity, Action, Resource) Decision }  // not allowed: 403 with Decision.Reason
type AuditSink     interface { Record(ctx, AuditEvent) error }                        // one call per write, best effort
type PreWriter     interface { PreWrite(ctx, AuditEvent) error }                      // optional, on the sink: refuse a write
```

**Authorizer.** `Resource` is `{Kind, Name, Spec *SpecSummary}`; `SpecSummary` is `{Model, ToolProfile, Team, Project}` (the labels
`openagentix.io/team` and `openagentix.io/project`; the console sets no labels, so on a create they are empty and on an update they
are the stored ones). For a create and an update the Authorizer is asked **twice**: first with the bare resource (no name for a
create, no spec), as a cheap gate before any body is read; then, after the body is decoded, with the name and the summary. Both must
allow; a refusal on the second is a 403 with the Authorizer's own `Reason`, audited as `denied`, and nothing reaches the cluster.
An implementation that decides on name or spec must therefore allow the bare question whenever the identity may create or update
something. `GET /api/v1/session` asks the bare question for create, update, delete and validate and reports `capabilities` and
`canWrite` from the answers, so the UI does not promise more than the Authorizer will give.

**AuditSink.** The audit line is written **after** the write, from the answer that is about to be sent, and is **best effort**: a
panic in `Record` is recovered and an error it returns is logged with the request id; neither can crash the request or change the
response. A write that happened and whose audit line failed still happened. A sink that must not lose a line implements
`PreWriter` as well: `PreWrite` runs after authentication and both authorizations and before the cluster is touched, with the event
(`Outcome: "pending"`, `Status: 0`). An error that is, or wraps, `ext.ErrRefused` answers 403; any other error, or a panic, answers
503 `audit_unavailable` (fail closed); the write is not made. The built-in sink does not implement it.

Community implementations (`internal/builtin`): `TokenAuth` (bearer token from a file, constant-time compare, optional minimum
length), `RoleAuthz` (one role that may do everything; `CONSOLE_VIEWER` makes writes 403) and `LogAudit` (one JSON log line per write
on stdout: `who`, `action`, `agent`, `outcome`, `status`, `request_id`). `AuditEvent` has no field for a body, an instruction text or a
token, so a sink cannot log them. Denied writes are audited too (`outcome: denied`).

## Protections

- **Host allowlist, before routing, on every request** (also `/healthz` and the app shell): `localhost`, `127.0.0.1` and `[::1]` with
  any port, plus `CONSOLE_ALLOWED_HOSTS`. Anything else is a bare `421`. A web page that rebinds its own name to `127.0.0.1` reaches a
  port-forward with that name in `Host` and in `Origin`, so comparing the two proves nothing; the list does. An `Origin` header, on any
  method, must be on the list and name the host and port of the request (`null` and the rest: 403 `cross_origin`).
  *Kubelet probes:* an `httpGet` probe sends the pod IP as `Host`, which is not on the list. The chart's probes for the console must
  carry `httpHeaders: [{name: Host, value: localhost}]`.
- **Failed-sign-in throttle:** after `CONSOLE_AUTH_FAIL_LIMIT` failed authentications from one remote address inside a minute, that
  address gets `429` (code `too_many_attempts`, `Retry-After`) for a minute, then two, four, up to fifteen; a global cap
  (`CONSOLE_AUTH_FAIL_LIMIT_GLOBAL`) does the same for all addresses together. During a back-off even the right token waits, so the
  answer is no oracle. Successful requests are not counted, the app shell and `/healthz` are never throttled, memory is bounded (at
  most 2048 addresses; beyond that new addresses share one entry), and the clock is injectable (`Options.Now`). The remote address is
  the TCP peer: `X-Forwarded-For` is not read. Behind a port-forward every client is `127.0.0.1`, so the per-address cap is then also a cap
  for everybody; that is why the lock-out is short at first.
- **Token strength:** the real mode refuses to start, with a message that says why, for a token shorter than 32 characters or equal to
  `demo-token`.
- `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, `Cross-Origin-Opener-Policy: same-origin`,
  `Cross-Origin-Resource-Policy: same-origin`, `X-Frame-Options: DENY`,
  `Permissions-Policy: camera=(), microphone=(), geolocation=()` and `X-Request-Id` on **every** answer the console writes (including the 421 and 403 above);
  `Cache-Control: no-store` on the API. **Exception:** the 400 and 431 answers that Go's `net/http` writes itself (a malformed request line, a header block over
  16 KiB) are produced before any handler runs and carry no console headers; they are a fixed plain-text line that reflects nothing
  of the request. **HSTS** (`Strict-Transport-Security`) is required whenever the console is served behind TLS (an Ingress, a mesh);
  set `CONSOLE_HSTS=1` there. It is off by default because a console on plain HTTP behind a port-forward must not tell browsers to
  insist on HTTPS for `localhost`.
- A `POST`, `PUT` or `DELETE` with `Sec-Fetch-Site` other than `same-origin` or `none`, or a foreign `Origin`, gets 403 `cross_origin`.
- Bodies must be `application/json` (415), at most 256 KiB (413), without unknown fields or trailing data (400).
- Header block at most 16 KiB (431), read deadline, per-request deadline (504), `{name}` in a path must be a definition name.
- A write is sent to the API server with the console's own ServiceAccount token and `fieldManager=openagentix-console`. The API
  address must be `https://` (the console refuses `http://` unless `CONSOLE_ALLOW_INSECURE_KUBE_API=1`, for a local development server).
- `POST /agents/validate` is limited per identity (`CONSOLE_VALIDATE_PER_MINUTE`), and sends no dry-run write for an identity that may not write.

## Demo mode

`CONSOLE_DEV_FAKE=1` serves an in-memory fake with the demo data of the design mockup: chart agents `assistant` and
`profile-demo`; built agents `researcher` (Ready), `cve-triage` (Refused, with the two violation sentences) and `release-notes`
(Pending). No cluster is read or written. The token is `demo-token` (printed in the log) unless `CONSOLE_TOKEN_FILE` is set.
`/api/v1/session` and `/api/v1/platform` report `demo: true`, and only then does the web app show its "Demo data" tag. The
service refuses to start when `CONSOLE_DEV_FAKE` is set together with `CONSOLE_KUBE_API`, `CONSOLE_CATALOG_FILE`,
`CONSOLE_POLICY_FILE`, `CONSOLE_KUBE_TOKEN_FILE`, `CONSOLE_KUBE_CA_FILE` or `KUBERNETES_SERVICE_HOST`.

```sh
./build-web.sh                                 # builds ../../console and copies it to web/dist (needs Node 22 and pnpm)
CONSOLE_DEV_FAKE=1 go run ./cmd/console        # open http://127.0.0.1:8080 and sign in with demo-token
```

## Build and test

```sh
make test          # go test ./... -race (the YAML tests use gopkg.in/yaml.v3, a test-only dependency)
make web           # ./build-web.sh
make build         # CGO_ENABLED=0 go build -o bin/console ./cmd/console (with the web app embedded)
make docker        # docker build; the Dockerfile builds the web app in a Node stage first
```

The image build (`docker build -f services/console/Dockerfile .`) uses the **repository root** as its context: it copies `console/`
and `services/console/`. A root `.dockerignore` sends nothing else. CI builds it that way (the Dockerfile carries the comment line
`# build-context: .`, which `hack/ci/dockerfiles.sh` reads). The base images are pinned by digest (the tag is in a comment above each
`FROM`); pnpm is the version pinned by `packageManager` in `console/package.json`. CI jobs for the web app: `console`,
`console-audit`, `console-e2e` (`make test-console`, `make test-console-e2e`).

`web/dist/` holds only `PLACEHOLDER` in Git; `build-web.sh` fills it (and keeps the placeholder). Before the first front-end build the binary still compiles, and
the app shell answers 503 with a hint.

## Deploying (what the chart needs)

The chart does all of this. It is opt-in: `console.enabled: true` (`components/console/demo-values.yaml`), and it needs `controlPlane.enabled` and the
same namespace as the control plane (the render fails otherwise: the console mounts the control plane's two ConfigMaps, and the chart does not copy them).
`install.sh` builds the image (`docker build -f services/console/Dockerfile .`, repository root as the context), loads it into kind, creates the token
Secret when absent (48 random characters, never printed) and prints how to open it:

```sh
kubectl port-forward -n openagentix-system svc/openagentix-console 8080:8080       # then open http://127.0.0.1:8080
kubectl get secret -n openagentix-system console-token -o jsonpath='{.data.token}' | base64 -d; echo    # the sign-in token
```

What the chart renders (`charts/openagentix/templates/console.yaml`, values block `console`):

- **Image** `openagentix/console`, port **8080** (`http`), one replica, non-root 65532, read-only root filesystem, all capabilities dropped, seccomp `RuntimeDefault`.
- **ServiceAccount** `openagentix-console` with one Role in the agents namespace (kagent), derived from what `internal/backend` really calls:
  `openagentix.io` `agentdefinitions`: get, list, create, update, delete (create and update also cover the dry run of `validate`); with
  `console.viewer: true` only get and list (a viewer sends no dry run). `api.kagent.dev` `agents`, `agenttemplates`, `harnesses`, `modelconfigs`: **list** only
  (the console lists them and never reads one by name). No watch, no patch, nothing on Secrets, nothing cluster-wide, no `agentdefinitions/status`. The
  control plane's admission guard matches the controller's username only, so it does not apply to this ServiceAccount; the console writes only
  `AgentDefinition`, which the controller validates. `tests/run.sh` asserts the exact rules.
- **Secret** `console-token`, key `token` (`console.tokenSecret`), mounted as a file, path in `CONSOLE_TOKEN_FILE`. The chart renders no Secret.
- **Mounts** the two ConfigMaps the controller reads (catalog and policy) read-only; paths in `CONSOLE_CATALOG_FILE` and `CONSOLE_POLICY_FILE`.
  A change of either (or a new `console.sourceHash`) replaces the pod.
- **Service** ClusterIP 8080; no Ingress. **NetworkPolicy** (only when `networkPolicy.enabled`) ingress: nobody (`kubectl port-forward` does not pass
  through it); egress: DNS, the Kubernetes API (`console.apiServerCIDRs`, which `install.sh` sets, and `console.apiServerPorts`, default 443 and 6443;
  empty CIDRs mean those ports towards any address), and, when the bundled observability stack is on and no URL overrides it, port 8428 of the
  bundled VictoriaMetrics and port 16686 of the bundled Jaeger, nothing else in that namespace. A `console.metrics.url` or `console.traces.url` of
  your own opens no egress: add it to the policy yourself.
- **Probes** (startup, liveness, readiness) `GET /healthz` on `http` with `httpHeaders: [{name: Host, value: localhost}]`: the Host allowlist answers 421 to the pod IP the kubelet sends otherwise.
- **Env** `CONSOLE_NAMESPACE` (the agents namespace), `CONSOLE_VIEWER=1` for `console.viewer`, `CONSOLE_ALLOWED_HOSTS` from `console.allowedHosts`,
  `CONSOLE_METRICS_URL` and `CONSOLE_TRACES_URL` from `console.metrics.url` and `console.traces.url`, or the bundled store when observability is on
  (and `CONSOLE_HSTS=1` is yours to add when an Ingress with TLS is). The token must be at least 32 characters; `install.sh` makes 48.
- The catalog may carry `"demo": true` (rendered from the demo values files); then the web app shows its "Demo data" tag.

The HTTP API, the extension interfaces and the OpenAPI file are in the [API reference](../../docs/diary/reference/console-api.md).
