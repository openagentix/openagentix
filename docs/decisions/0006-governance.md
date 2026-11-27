# ADR 0006: Governance (who may call an agent, which tools it may use, where it may connect, what it remembers, what is recorded)

- **Status:** Round 1 (the A2A gate), round 2 (tool profiles and egress values) and round 3 (memory governance) are implemented, opt-in and proven on kind: see "Round 1 results", "Round 2 results" and "Round 3 results" at the end. The ADR records what the upstream code really does today and a small first slice to build, behind switches that are off by default.
- **Date:** 2026-11-24
- **Evidence:** source of the pinned releases, read in local clones: kagent v1.0.1 (commit `558e3d7`), Agent Substrate v1.0.1 (`7ce6f439`), agentgateway v1.7.0 (`26f5aeb`), ToolHive v0.67.1 (tag clone). Paths below are relative to each repository root and prefixed with the project name. Read-only `kubectl` on the kind cluster `kind-openagentix` for three facts (marked "live"). No model call, no Telegram message, no database connection was made for this record.

## Context

OpenAgentix now has agents, tools, memory, channels, schedules and notify, all wired by one chart. The security page (`docs/diary/features/security.md:65-83`) lists what is not protected. The biggest gaps:

1. The kagent controller port 8083 accepts any caller the NetworkPolicy lets through, and the caller names its own user with `X-User-Id`.
2. Every agent can call every tool of the vMCP.
3. Memory never expires, and nobody but an operator with `psql` can remove it.
4. There is no audit trail that says which person (or system) made an agent do what.

This ADR answers five questions. For each it gives the options, the evidence, a recommendation and an effort (S: up to a day, M: 2 to 4 days, L: a week or more). The MVP slice, values, compatibility rules and tests follow at the end.

## Findings that shape every answer

These are the facts the options depend on. Several of them correct what we believed before.

**F1. kagent's controller authentication is a chain, and the user part has only two modes.** The binary accepts `server.auth.mode` `insecure` or `trusted-proxy` and nothing else (kagent `go/core/cmd/controller/main.go:95-104`, `proto/kagent/config/v1/config.proto:154-163`). On top of that mode, two verifiers are stacked (kagent `go/core/pkg/app/app.go:338-346`):

- a ServiceAccount verifier, only when `server.auth.serviceAccount.authority` is set;
- the Substrate actor verifier, always.

Each verifier looks at the unverified token only to decide whether it is "its" token. If not, it passes the request down to the next verifier, and in the end to the user mode.

- The ServiceAccount verifier claims a token only when its `sub` starts with `system:serviceaccount:` or it has a `kubernetes.io` claim. Anything else falls through (kagent `go/core/internal/httpserver/auth/serviceaccount.go:32-44`). A token it claims is checked by a TokenReview for the fixed audience `kagent-invocation` (`serviceaccount.go:16`, `tokenreview.go:88-111`).
- `insecure` takes the user from `?user_id=`, then from `X-User-Id`, and otherwise uses `admin@kagent.dev` (`authn.go:24-31`).
- `trusted-proxy` needs exactly one `Authorization: Bearer` JWT. It reads `sub` (or a configured claim) **without checking the signature** (`proxy_authn.go:28-53`, `:72-79`).

This is why the earlier try with `serviceAccount.authority: kubernetes` still answered 200 without a token or with a garbage token. Neither token looks like a ServiceAccount token, so both fell through to `insecure`.

**F2. A verified ServiceAccount caller is one user.** The principal is `kubernetes:<authority>` plus the ServiceAccount UID (`tokenreview.go:69-75`). Memory and sessions are keyed by that principal. The bridge would lose its per-chat memory scope, and no header can override this.

**F3. The rest of port 8083 is just as open.** Port 8083 also serves gRPC and gRPC-Web for every kagent API, told apart by content type (kagent `go/core/internal/grpcserver/grpcweb.go:50-69`, `server.go:157`). That includes `MemoryService.List` and `MemoryService.Delete`, which act for the authenticated user (`proto/kagent/runtime/v1/memory.proto:10-16`). The default authorizer permits everything (`go/core/pkg/app/app.go:95-97`, `:140-147`). So in `insecure` mode, any admitted pod can list or delete any user's memories, and read any user's sessions, by naming that user.

**F4. Sandboxes reach the controller with a verified identity, not a header.** For the controller origin, kagent always injects an actor JWT (audience `kagent-runtime`, 300 s) into the sandbox's egress policy. A sandbox cannot supply that header itself: it is reserved (kagent `go/core/internal/substrate/policy.go:31-55`). The egress proxy overwrites or adds it (substrate `cmd/atenet/internal/router/egress/credentials.go:123`). The controller verifies actor tokens and never falls back to the user mode for them (kagent `go/core/internal/runtimeauth/provider.go:24-51`). So the `atenet-egress` peer on port 8083 is not a hole for user impersonation, as long as the egress injection works as read. Not tested live.

**F5. The agent's tool list is enforced inside the sandbox, by the agent's own process.** The Go ADK filters `tools/list` on the client side (kagent `go/adk/pkg/mcp/discovery.go:116-160`, `registry.go:180-193`). The vMCP is not told about it. Every agent also has a `bash` tool by default (kagent `go/adk/pkg/tools/builtin.go:276-315`). The switch is controller-wide, `runtimeDefaults.builtinTools.disableBash`, default false (kagent `helm/kagent/values.yaml:214-217`).

The egress proxy puts the actor JWT on any request to the vMCP origin (substrate `cmd/atenet/internal/router/egress/credentials.go:68-125`, kagent `go/core/internal/substrate/policy.go:18-30`). So a prompt-injected agent can use `bash` to call any vMCP tool directly. It needs no token of its own: the proxy adds the JWT. The `execute_tool_script` tool does the same from inside the vMCP. Its inner calls are checked only by Cedar (toolhive `pkg/vmcp/codemode/decorator.go:91-102`), and Cedar cannot tell agents apart (F6).

**F6. The actor JWT names a session, not an agent.** Its claims are `sub` = `actor/<atespace>/<name>` and `actor.ate.dev` = atespace, actor name and actor UID, with no template, label or agent claim (substrate `cmd/ateapi/internal/controlapi/actor.go:563-615`, `internal/actoridjwt/actoridjwt.go:84-128`). kagent names the actor `session-<id>` (kagent `go/core/internal/substrate/client.go:284`). The atespace is the Agent's Kubernetes namespace and cannot be configured (kagent `go/core/internal/substrate/actor_template.go:110`).

**F7. Substrate egress is deny-by-default per actor, and kagent already fills the allowlist.** With no policy, or a policy without rules, the egress proxy answers 403 (substrate `cmd/atenet/internal/router/egress/egress.go:259-270`, `api/ateapi/v1/ateapi.proto:604`). kagent compiles one rule per origin, from:

- the agent's models and tools ("Integration access inferred from models and tools is always included", kagent `go/api/v1alpha3/agent_types.go:56-65`);
- the controller origin;
- any `EgressPolicy` objects that the Agent lists in `spec.egressPolicyRefs` (kagent `go/core/internal/substrate/policy.go:21-68`, `go/core/internal/controller/reconciler.go:112`).

Rules match host (or SNI) and port only. They cannot match methods or paths (substrate `api/ateapi/v1/ateapi.proto:699`, `:733`, `:762`, kagent `go/api/v1alpha3/egresspolicy_types.go:25`). Live: the cluster has the `egresspolicies.api.kagent.dev` CRD and no `EgressPolicy` objects. Every agent therefore reaches only what its own models and tools imply.

**F8. A ToolHive vMCP really blocks the tools it filters out.** `aggregation.tools[].filter` hides a tool from `tools/list` (toolhive `pkg/vmcp/config/config.go:607-614`). `CallTool` returns not-found for any name that is not advertised (toolhive `pkg/vmcp/core/core_calls.go:25`, `:62-63`, `:90`). Code-mode inner calls go through the same `CallTool` (toolhive `pkg/vmcp/codemode/decorator.go:91-95`). Each VirtualMCPServer has its own `groupRef` and its own aggregation config. Nothing prevents two of them from serving one MCPGroup (toolhive `cmd/thv-operator/controllers/virtualmcpserver_controller.go:1083-1130`). The OIDC audience must be unique per server (toolhive `cmd/thv-operator/api/v1beta1/mcpoidcconfig_types.go:221-231`).

**F9. Memory expiry is not enforced, but upstream already has a per-user delete.**

- `PruneExpiredMemories` exists, but nothing in kagent calls it (kagent `go/core/internal/database/memory.go:125-139`; a search of the source finds only the definition).
- The search query does not filter on `expires_at` ("Expired rows remain searchable until pruned", `memory.go:53-66`).
- `MemoryService.List` and `Delete` act on the caller's own user id, for one agent. `Delete` removes all of that user's rows for the agent (kagent `go/core/internal/service/memory/service.go:176-211`, `memory.go:113-122`).
- Nothing on the write path filters the content (`service.go:254-274`).

## Question 1: A2A caller authentication

### Who calls port 8083 today

| Caller | Where | How it identifies itself today | Evidence |
|---|---|---|---|
| Telegram bridge | `openagentix-gateway`, pod label `app: telegram-bridge` | `X-User-Id: telegram:<chat id>`; it can already send a static `Authorization: Bearer` | `bridges/telegram/internal/a2a/client.go:66-77`, `charts/openagentix/templates/networkpolicy.yaml:88-91` |
| Agent Kourier broker | `agent-kourier` | `X-User-Id` = the Binding's `identity.userId` (default `kourier:<binding>`); a Binding can also carry `identity.tokenSecretRef`, an OIDC bearer token | `charts/openagentix/templates/channels.yaml:111`; live: `kubectl explain bindings.spec.identity` |
| Schedule CronJobs | `openagentix-schedules`, label `openagentix.io/component: schedule` | `X-User-Id: schedule:<name>` | `tools/a2a-call/internal/call/call.go:144`, `networkpolicy.yaml:97-101` |
| Agent sandboxes | through `atenet-egress` | actor JWT injected by the egress proxy (F4) | `networkpolicy.yaml:85-87` |
| Anything in namespace `kagent` | the controller, `kagent-ui`, `kagent-tools`, the worker pool `kagent-default` (live: deployments) | whatever it sends | `networkpolicy.yaml:84` |
| `networkPolicy.extraA2ACallers` | operator-chosen | whatever it sends | `networkpolicy.yaml:102-108` |
| An operator testing by hand | a throw-away pod in an admitted namespace | `X-User-Id` or nothing | `docs/diary/features/runtime.md:70-80` |

### Options

| | A. kagent `trusted-proxy` plus `serviceAccount.authority` | B. Our own small authenticating proxy ("A2A gate") in front of an `insecure` controller | C. agentgateway route in front of the controller | D. Our own controller build with a custom authenticator |
|---|---|---|---|---|
| What verifies the caller | TokenReview for ServiceAccount tokens (F1). Any other JWT is accepted unverified | TokenReview for projected ServiceAccount tokens with our own audience, plus hashed static keys for callers that only have a Secret (Kourier) | `jwtAuthentication` (issuer, audiences, JWKS inline or remote; agentgateway `controller/api/v1alpha1/agentgateway/agentgateway_policy_types.go:1212-1330`) or `apiKeyAuthentication` with per-key metadata (`:1426-1470`) | anything we write, plugged in through `app.Options.Authenticator` (kagent `go/core/pkg/app/app.go:95-97`) |
| Where `X-User-Id` comes from | the ServiceAccount UID: one user per caller (F2). The bridge loses per-chat memory | the gate sets it. Rules per caller say which values are allowed (bridge: prefix `telegram:`; schedule `x`: exactly `schedule:x`; Kourier key: one fixed id) | a CEL `transformation` can `set` and `remove` headers (`agentgateway_policy_types.go:2737-2814`). Checking a header against the caller's allowed prefix in `authorization` CEL was not verified | anything |
| Blocks the other APIs on 8083 (F3) | no | yes: it passes only the A2A paths | yes, if routes match only A2A paths. Not verified how gRPC-Web would look to the route |
| Forgery by an admitted pod | still possible: an unsigned JWT is accepted | possible only from pods that the NetworkPolicy still admits directly (namespace `kagent`, see below) | same as B |
| Streaming (`SendStreamingMessage`, SSE) | native | must flush. Go `httputil.ReverseProxy` with `FlushInterval: -1`, to be tested | not verified: the A2A plugin does not inspect `text/event-stream` (agentgateway `crates/agentgateway/src/a2a/mod.rs:240-246`); pass-through is inferred |
| Kubernetes token check | built in | TokenReview (needs the `system:auth-delegator` binding) | remote JWKS from the API server needs credentials; whether agentgateway can send them is not verified |
| Moving parts | none new, but it breaks per-chat memory | one small Go Deployment (about 300 lines plus tests), same style as `services/notify` | a second Gateway and policy on agentgateway, CEL rules that are hard to test offline |
| Upgrade risk | low | low: it speaks plain HTTP to kagent | medium: two products' semantics combined |
| Effort | S, but not acceptable alone | M | M, with more unknowns |

D gives the cleanest result: a verified caller and an allowed delegated user id inside kagent itself. But it means owning a controller image. The authenticators live in kagent's `internal` packages, so we would rewrite them. Every kagent upgrade then becomes our build. Effort L. Rejected for now. It stays the upstream ask (below).

### Recommendation: B, the A2A gate

1. A Deployment `a2a-gate` in `openagentix-gateway` (new code in `services/a2a-gate`) with a ServiceAccount bound to `system:auth-delegator`. This is the only cluster-scoped permission it needs. It is a reverse proxy to `kagent-controller:8083`.
2. **Authentication.** A request must carry `Authorization: Bearer <token>`. The gate accepts two kinds:
   - a projected ServiceAccount token with the audience `openagentix-a2a` (TokenReview, cached for up to 30 s, the same as kagent's own cache in `tokenreview.go:18-21`);
   - a static key whose SHA-256 is listed in a Secret. `install.sh` creates these keys, the way it creates the gateway virtual keys, and never prints them.
3. **Authorization, per caller.** Rules come from values and are rendered into a ConfigMap:
   - which agents the caller may call (`POST /agents/<namespace>/<name>` and the agent card `GET`);
   - which user ids it may assert: an exact value, a prefix, or "fixed" (the gate sets it).

   Anything else gets 403. That includes gRPC (`application/grpc*`), gRPC-Web and the REST API.
4. **Identity.** The gate deletes the caller's `Authorization`, any `X-User-Id` that breaks the caller's rule, and the `user_id` query parameter. The query parameter matters: `insecure` reads it before the header (`authn.go:25-28`). The gate then sets `X-User-Id` itself. The controller stays in `insecure` mode and never sees a caller credential.
5. **NetworkPolicy.** With the gate on, port 8083 admits only:
   - the gate pod;
   - `atenet-egress` (F4);
   - namespace `kagent`.

   The bridge, Kourier, schedule and `extraA2ACallers` peers move to the gate's own ingress policy. The `kagent` namespace peer stayed in round 1 and was narrowed to the UI pods after the review (see "Round 1 review and fixes").
6. **How each caller authenticates:**
   - **Bridge:** a projected token volume (audience `openagentix-a2a`, `expirationSeconds: 3600`). The client reads the token file again on every request, because the kubelet rotates it. The bridge already sends a bearer token when one is set (`client.go:75-77`); it needs a file source instead of a fixed string. Rule: agent `bridge.agent`, user id prefix `bridge.userIdPrefix` (default `telegram:`).
   - **Schedules:** one ServiceAccount per schedule (`schedule-<name>`) and a projected token volume. The pod keeps `automountServiceAccountToken: false` (`charts/openagentix/templates/schedules.yaml:76`); the projected volume is explicit. `tools/a2a-call` gets `A2A_TOKEN_FILE`. Rule: agent = the schedule's agent, user id exactly `schedule:<name>`. (Corrected after the round 1 review: this does **not** close "anyone who can create a labelled pod there can call any agent". Whoever may create pods in `openagentix-schedules` can mount a projected token of any ServiceAccount in that namespace and so act as any schedule. The boundary is the RBAC for creating pods in that namespace and in the bridge's. A per-schedule ServiceAccount only limits what one stolen token can do and makes the audit line name the schedule.)
   - **Kourier:** one static key per Binding, in a Secret in `openagentix-channels`, referenced by `identity.tokenSecretRef`. Rule: agent = the Binding's agent, user id fixed to the Binding's `userId`. The gate ignores whatever `X-User-Id` Kourier sends. Kourier refuses static `Authorization` and `X-User-Id` headers on the AgentBackend (live: `kubectl explain agentbackends.spec.headers`), so `tokenSecretRef` is the only way. Kourier's documentation calls it an "OIDC bearer token". Whether Kourier sends a non-JWT value unchanged is **not verified**. If it does not, the gate also accepts an HS256 JWT signed with a per-Binding key.
   - **Operator by hand:** `kubectl create token <sa> --audience openagentix-a2a` for a ServiceAccount listed in `a2aGate.callers`.
   - **Sandboxes:** unchanged (F4).
7. **Audit line.** The gate writes one JSON line per request: time, caller (ServiceAccount or key name), agent, the user id (see the open decision on hashing), `contextId` from the request, trace id from `traceparent`, status and duration. It never logs the message text.
8. **Upstream asks.** (a) `trusted-proxy` should verify the JWT signature against a configured JWKS. (b) A verified ServiceAccount should be allowed to act for a delegated user id under a rule. Either one would let the gate shrink or go away.

Effort: M for the gate (code and Go tests), S for the chart, S for the bridge and `a2a-call` changes, S for the Kourier keys in `install.sh`.

## Question 2: per-agent tool permissions

### What exists, and what enforces it

| Mechanism | Enforced where | Can a prompt-injected agent get around it? | Evidence |
|---|---|---|---|
| `AgentTemplate.spec.tools[].mcp.tools` (our `agents[].tools`) | in the sandbox, by the Go ADK filtering `tools/list` | **yes**: `bash` reaches the vMCP origin with the injected JWT; `execute_tool_script` calls any tool the vMCP advertises | F5 |
| Cedar `toolAccess` on the one vMCP | in the vMCP | no, but it can only key on atespace or session, and all agents share the atespace `kagent` | F6, `charts/openagentix/templates/mcp.yaml:30-35` |
| One VirtualMCPServer per permission group ("tool profile"), each with a tool `filter`, each agent pointing at its own profile's RemoteMCPServer | in the vMCP (filtered tools are not-found, also inside code mode) and in Substrate egress (the agent's allowlist contains only the origins its tools imply, so other profiles' vMCPs answer 403) | no, as far as the source shows. Not tested live | F7, F8 |
| One Kubernetes namespace per agent, hence one atespace per agent, plus Cedar keyed on the atespace | in the vMCP | no | F6; the chart puts every agent in `kagent.namespace` |
| `MCPToolConfig` (`toolsFilter`, `toolsOverride`) | in the vMCP, per workload | as the profile option; it is the reusable form of the inline filter | toolhive `cmd/thv-operator/api/v1beta1/toolconfig_types.go:25-35`, `pkg/vmcp/config/config.go:602` |

### Recommendation: tool profiles

A values block `mcp.profiles`. Each profile renders:

- one more VirtualMCPServer `tools-<profile>` on the same MCPGroup, with `aggregation.tools[]` filters that list its tools per workload;
- an MCPOIDCConfig audience `openagentix-vmcp-<profile>` (audiences must be unique, F8);
- a RemoteMCPServer `toolhive-vmcp-<profile>` in `kagent` with `actorJwt` for that audience;
- its share of the vMCP NetworkPolicy and observability scrape targets.

An agent sets `toolProfile: <name>`, and its tools then come only from that server. The render fails if an agent lists a tool that is not in its profile. This keeps the ADK list as a convenience and moves the real limit to the vMCP and the egress proxy.

Agents without `toolProfile` keep the shared vMCP, which stays as it is. So the default render does not change.

`execute_tool_script` is a per-profile switch (`codeMode`), because code mode is granted by the vMCP config, not per principal (toolhive `pkg/vmcp/config/config.go:1206-1213`). Inside a profile it can call only that profile's advertised tools.

Cost: one vMCP pod per profile. Its memory was not measured; the whole tool layer idles at about 112 MiB over 6 pods (`docs/diary/features/tools.md:70`). On the fixed 6 CPU / 8 GB demo VM, plan for one or two profiles.

The namespace-per-agent option is cleaner for Cedar, but it moves Secrets, ModelConfigs, RemoteMCPServers and NetworkPolicies into many namespaces. Effort L. Deferred.

Separately, `disableBash` is controller-wide. Turning it off shrinks what an injected agent can do, but only for every agent at once, and skills that run scripts would break. That is a decision for the owner (below). With profiles, `bash` no longer widens tool access. It can still reach the other origins the agent's own allowlist holds, such as the model gateway with the agent's own key.

Effort: M (chart, render-time checks, tests). The vMCP-per-profile pattern needs one live proof before the switch is documented as supported.

## Question 3: egress control per agent

**Today** (F7):

- **Sandboxes.** They reach only the origins their agent's models and tools imply: the model gateway (and the memory alias), the vMCP, the controller, and the OTLP endpoint when tracing is on (ADR 0003, round 1, "no egress policy had to be written by hand"). Everything else gets 403 from `atenet-egress`. That is already per agent.
- **Tool servers.** The real internet egress happens in the tool servers, which are ordinary pods outside Substrate:
  - `fetch` in `mcp-tools` can reach any URL. kindnet does not enforce internet egress (`docs/diary/features/security.md:71-72`).
  - `notify` posts to chat APIs by design.

**What Substrate offers:** host (exact or leftmost wildcard) and port per rule, with `http`, `https` or `tls_passthrough`, and header injection with a secret or an actor JWT. It offers no methods, paths or CIDRs (F7; substrate `api/ateapi/v1/ateapi.proto:796-860`). The per-agent object is kagent's `EgressPolicy` (`destinations[].origin`, optional `authentication`), referenced by `Agent.spec.egressPolicyRefs` (kagent `go/api/v1alpha3/egresspolicy_types.go:17-78`).

**Recommendation:**

1. **Extra origins.** `agents[].egress.allow` (a list of `https://host[:port]` origins) renders one `EgressPolicy` named `<agent>-egress` and adds it to the Agent's `egressPolicyRefs`. Absent means nothing renders and nothing changes. Effort S. It matters only when a skill or `bash` needs an outside API. Tools that reach the internet do so from their own pods.
2. **Internet egress of `fetch`.** Restricting `fetch` per agent means one `fetch` server per profile with an allowlist. Whether gofetch has a host allowlist is not verified. Otherwise it takes a NetworkPolicy egress rule on an enforcing CNI, or an HTTP egress proxy. Deferred: it is a tool-server question, not a Substrate question.
3. **Live canary for the claim in F7.** `bash` in a sandbox does `curl https://example.com`, and the expected answer is 403 from the egress proxy. Not run.

## Question 4: memory governance

| Need | Today | Options | Recommendation | Effort |
|---|---|---|---|---|
| Expiry | `ttlDays` only sets `expires_at`; nothing prunes and search ignores it (F9) | (a) a CronJob in `kagent` that runs the same SQL as `PruneExpiredMemories` (extends rows read at least 10 times by 15 days, deletes the rest; `memory.go:125-139`) with kagent's database Secret; (b) upstream: call the prune function on a timer and filter expired rows in search | (a) behind `memory.expiry.enabled`, plus the upstream issue (b). Using upstream's own statement keeps the behaviour the same when upstream turns it on | S |
| "Forget me" | operator `psql` (`docs/diary/features/memory.md:56-63`) | `MemoryService.Delete` for the caller's own user and one agent (F9), reached through the A2A gate | after Q1: a bridge command `/forget` that calls `Delete` for the chat's own user id through the gate (gRPC-Web on 8083, as ADR 0002 used). The gate allows that RPC only for callers whose rule sets `memory: true` and only with their own user id | M |
| Listing | `psql` | `MemoryService.List`, same scoping | a bridge command `/memories` (shows the user's own memory texts in their own chat), same gate rule | S after the above |
| Secrets in memory | prompt advice only; no filter on the write path (`service.go:254-274`) | (a) a scan in the expiry job that deletes rows matching a short list of high-confidence patterns (private-key headers, provider key prefixes) and logs only a count; (b) a filter in the save path (needs kagent changes) | (a) as a later step, opt-in | S |
| Memory of a Kourier Binding or schedule | one scope per Binding or schedule (`memory.md:79-80`) | unchanged | no change; documented | none |

Without Q1, list and delete are unsafe: anyone admitted could forget or read another user's memories (F3). So Q4 comes after Q1.

## Question 5: audit

**What we already have** (ADR 0003, `docs/decisions/0003-observability.md:15-23`, `:52-66`):

- gateway cost and tokens per agent virtual key;
- vMCP `AUDIT` lines with the tool, the outcome and `subjects.user_id` = the session actor (toolhive `pkg/audit/auditor.go:537-555`);
- the bridge's `turn` line with a salted chat hash;
- the `a2a-call` summary;
- traces joined by `contextId` and trace id (`hack/trace-turn.sh`).

**What is missing for an audit trail:**

1. **Who called.** Today nothing authenticated records which caller started a turn. The gate line (Q1) is that record.
2. **Which agent used a tool.** The vMCP subject is the session, not the agent (F6). With tool profiles, the vMCP server name says the profile. The join from session to agent and user lives in kagent's session table, or in traces through `gen_ai.conversation.id`. The vMCP can add more subject fields only from Go code (`WithSubjectEnricher`, toolhive `pkg/audit/subject_enricher.go:10-70`), not from config.
3. **Cost per person.** The gateway counts per agent key. Per-user cost needs a join on the trace or `contextId`. The bundled Jaeger drops `user.id` on purpose (ADR 0003).
4. **Durability.** Everything is pod stdout. A log shipper or a persistent store is an operator choice; we document the fields.

**Recommendation:** the gate line in round 1, and a documented join recipe that extends `hack/trace-turn.sh` (caller → `contextId` → tools → cost) in round 2. A durable or tamper-evident store is deferred.

## Proposed MVP slice

Three rounds, in this order:

1. **Round 1: the A2A gate** (Q1, plus the audit line of Q5). `services/a2a-gate`, chart block `governance.a2a`, bridge and `a2a-call` token files, per-schedule ServiceAccounts, Kourier Binding keys from `install.sh`, NetworkPolicy switch. Live canary on kind.
2. **Round 2: tool profiles** (Q2) and the egress values (Q3, item 1). `mcp.profiles`, `agents[].toolProfile`, `agents[].egress.allow`, render-time checks, live canary of `bash` and code mode against a second profile.
3. **Round 3: memory governance** (Q4). The expiry CronJob, `/forget` and `/memories` in the bridge through the gate, and the opt-in secret scan. The upstream issues for prune and `trusted-proxy` verification are filed by then.

### Values sketch

```yaml
governance:
  a2a:
    enabled: false                 # off: nothing below renders, port 8083 policy unchanged
    namespace: openagentix-gateway
    image: {repository: openagentix/a2a-gate, tag: dev, pullPolicy: IfNotPresent}
    audience: openagentix-a2a      # projected ServiceAccount tokens must carry it
    keysSecret: a2a-gate-keys      # SHA-256 hashes of static keys (install.sh, never printed)
    audit:
      userId: hash                 # hash | raw  (owner decision, see below)
    # Rules for the chart's own callers are derived (bridge, schedules, bindings). Extra callers:
    callers: []
    #  - name: ci-smoke
    #    serviceAccount: {namespace: ci, name: smoke}
    #    agents: [assistant]
    #    userId: {exact: "ci:smoke"}          # or {prefix: "..."} or {fixed: "..."}
    #    memory: false                        # may call MemoryService List/Delete for its own ids
mcp:
  profiles: []                     # empty: only the shared vMCP, as today
  #  - name: research
  #    codeMode: false
  #    tools:
  #      fetch: [fetch]
  #      osv: [query_vulnerability, get_vulnerability]
agents:
  - name: assistant
    # toolProfile: research          # tools then come only from vMCP tools-research
    # egress:
    #   allow: ["https://api.github.com"]   # renders EgressPolicy assistant-egress
memory:
  expiry:
    enabled: false
    schedule: "17 3 * * *"
    secretScan: false
```

### Default-off and compatibility rules

- With `governance.a2a.enabled: false`, `mcp.profiles: []`, no `toolProfile`, no `egress`, and `memory.expiry.enabled: false`:
  - the default render must be byte-identical to the commit before (`cmp`);
  - every demo values file must render byte-identically too;
  - the same rule as ADR 0003.
- Turning the gate on changes how callers are reached:
  - the bridge's and `a2a-call`'s A2A URL becomes the gate Service;
  - the controller NetworkPolicy loses those peers.

  `install.sh` must apply the gate and the token volumes in one `helm upgrade`, so there is no window where callers are cut off. It needs no kagent Helm change and no controller restart. This matters, because rolling the controller is risky on this node (ADR 0003).
- `extraA2ACallers` keeps working with the gate off. With it on, the chart fails the render if `extraA2ACallers` is set without a matching `governance.a2a.callers` entry, so a caller is never silently cut off.
- Memory scopes do not change. The user ids the gate allows are the ones the callers send today (`telegram:`, `schedule:`, `kourier:`), so existing memories stay reachable.

### Test plan

- **Chart tests** (`charts/openagentix/tests/run.sh`), written first:
  - default and demo renders byte-identical;
  - gate on renders a Deployment, a ServiceAccount, a ClusterRoleBinding to `system:auth-delegator`, a rules ConfigMap without secrets, and a gate ingress NetworkPolicy;
  - port 8083 peers are exactly the gate, `atenet-egress` and `kagent`;
  - the bridge has a projected token volume with the audience;
  - each schedule has its own ServiceAccount and keeps `automountServiceAccountToken: false`;
  - Bindings get `tokenSecretRef`;
  - profiles render a vMCP, an OIDC config with a unique audience and a RemoteMCPServer;
  - the render fails for a tool that is not in the profile, for an unknown profile, and for `extraA2ACallers` without a rule;
  - `egress.allow` renders an `EgressPolicy` and `egressPolicyRefs`;
  - no Secret values anywhere.
- **Go unit tests for the gate** (`-race`, standard library plus `client-go` for TokenReview with a fake):
  - no token, a wrong audience or an expired token gets 401;
  - an agent outside the rule gets 403;
  - a user id outside the prefix, exact or fixed rule gets 403 (fixed overwrites);
  - the `user_id` query parameter is removed;
  - `Authorization` is never forwarded;
  - gRPC, gRPC-Web and non-A2A paths get 403, except the memory RPCs for callers with `memory: true`;
  - SSE is flushed per event;
  - canary strings in the message text never reach the audit line.
- **Go tests for the bridge and `a2a-call`:** the token file is re-read on each request, and a missing file is a clear error.
- **Live canary on kind**, at most three model calls:
  1. A direct call to 8083 from the bridge pod times out. A call to the gate without a token gets 401.
  2. A bridge-ServiceAccount token that claims `schedule:demo-brief` gets 403.
  3. A manual schedule Job reaches `TASK_STATE_COMPLETED` through the gate (one model call).
  4. A signed demo webhook ends with `outcome=completed` through the gate (one model call).
  5. In round 2, `bash` in a sandbox of a profile agent calls the shared vMCP and gets 403 from the egress proxy, and `execute_tool_script` calling a tool outside the profile gets not-found (stub model, no paid call).
  6. In round 3, `/forget` and `/memories` are covered by unit tests only (no Telegram messages). The expiry job is run once by hand. It must finish and log only counts. A row cannot be made to expire sooner than `ttlDays: 1` without editing the database, so the deletion of an expired row is proven by a Go or SQL test against a throw-away PostgreSQL, not on the cluster.

## Out of scope and deferred

- One namespace or atespace per agent and Cedar keyed on it (L).
- A custom kagent controller build (option D).
- Narrowing the `kagent` namespace peer on port 8083 to pod labels (needs a log check first).
- Restricting `fetch` per host.
- A tamper-evident or durable audit store; per-user cost dashboards; USD budgets.
- Content filters on prompts or tool results (prompt injection is still not solved).
- Revocation of actor JWTs before expiry; rotation of virtual keys and gate keys.
- Slack-specific identity: in a bound Slack channel, everyone shares the Binding's identity.
- Multi-tenant hardening (ADR 0001 says neither runtime is ready for hostile tenants).

## Decisions only the owner can make

1. **User ids in the gate's audit line:** raw (`telegram:<chat id>` is personal data, but it is what an audit needs) or a salted hash, as in the bridge's log. Settled for round 1: `hash` is the default, because a chat id must not appear in logs; `raw` stays an explicit operator switch.
2. **`bash` for every agent:** keep it (skills can run scripts) or set `disableBash` controller-wide. The switch is not per agent, and turning it on rolls the controller.
3. **Memory expiry by our own CronJob** with kagent's database credentials, or wait for upstream to call its own prune function.
4. **Pod budget for tool profiles** on the fixed 6 CPU / 8 GB VM: how many extra vMCP pods are acceptable.

Settled on 2026-11-24. The owner asked for sane defaults on all four:

- Decision 1: the audit line stores a salted hash of the user id; `raw` is an explicit switch.
- Decision 2: `bash` stays on. Skills run scripts through it, and the switch is controller-wide. The risk is contained by tool profiles and the deny-by-default egress of round 2.
- Decision 3: our own expiry CronJob, off by default, reusing kagent's prune statement. It is removed when upstream calls its own prune function.
- Decision 4: the chart sets no limit on tool profiles. The demo values ship exactly one, which is what the 6 CPU / 8 GB node can carry.


## Not verified

- The egress proxy's actor-JWT injection on the controller origin (F4), and the 403 for undeclared origins (F7), were read in the source, not observed live.
- Kourier's handling of a non-JWT value in `identity.tokenSecretRef`, and whether it still sends `X-User-Id` when a token is set.
- Which pods in namespace `kagent` call port 8083.
- SSE through a Go reverse proxy to kagent; SSE through agentgateway.
- agentgateway: remote JWKS from the Kubernetes API server, CEL on request headers in `authorization`, and the order of `transformation` against `jwtAuthentication`.
- That `aggregation.tools[].filter` applies to `MCPServerEntry` backends (`knowledge`, `delivery`) as it does to `MCPServer` workloads.
- The memory and CPU of one extra vMCP pod.
- Whether gofetch can be limited to a host allowlist.

## Round 1 results (2026-11-24)

Round 1 is built, tested and run on the kind cluster. Rounds 2 and 3 are not started. The gate is **off by default** and is **on** in the demo cluster after this run.

### What was built

- `services/a2a-gate`: a Go reverse proxy with no dependency outside the standard library (33 tests with `-race`; coverage 90% for the proxy, 80% for authentication). It follows Question 1, items 2 to 5 and 7:
  - A projected ServiceAccount token is checked by a TokenReview for the audience `openagentix-a2a` (a good answer cached 30 s, a refusal 5 s). A static key is matched by its SHA-256 against the files of a mounted Secret.
  - Each caller has a rule: the agents it may reach and a user id rule (`exact`, `prefix` or `fixed`). The rules file is strict JSON; an unknown field stops the gate at start.
  - Only `POST /agents/<ns>/<name>` (also `message:send` and `message:stream`, with or without `/v1`) and the agent card `GET` pass. Everything else gets 403, `application/grpc*` included. The gate removes `Authorization`, the whole query string, `Cookie`, `Baggage`, the `X-Forwarded-*` headers and a few identity headers, and sets `X-User-Id` itself.
  - SSE passes with `FlushInterval: -1`; a test proves that the first event arrives before the second is written.
  - One audit line per request: time, caller, agent, user id (salted hash `h:` and 8 hex digits, or raw), `contextId`, trace id, status, duration, method and, for a refusal, a `reason` from a closed set. At most 64 KiB of the body is read to find `contextId` (`A2A_GATE_SNIFF_BYTES`); the body is never logged and is passed on whole.
- Chart: `governance.a2a` and `templates/governance.yaml`, as in the values sketch, with one addition: `sourceHash` (the same rollout trick as the other services). Callers authenticate as designed: projected token volumes for the bridge and for each schedule (one ServiceAccount per schedule, `automountServiceAccountToken: false` kept), `tokenSecretRef` on every Kourier Binding, AgentBackend, bridge and schedule URLs at the gate, the changed port-8083 policy, the gate ingress policy, and the render failure for `extraA2ACallers` without a rule. 78 new chart assertions (703 in all, 0 failing).
- `bridges/telegram` and `tools/a2a-call`: `A2A_TOKEN_FILE`, read again on every request; a missing or empty file is a clear error and nothing is sent.
- `install.sh` and `uninstall.sh`: image build and load, one key Secret per Kourier binding (`a2a-key-<binding>`, created only when absent) and the hash Secret `a2a-gate-keys` (derived from the key Secrets on every run, one field manager per key), all before the one `helm upgrade`. `PURGE_SECRETS=1` removes them.
- `components/governance/demo-values.yaml` turns the gate on.

### Compatibility check

The default render and nine demo or option renders (default, channels, schedules, notify, observability, graph, all five demo files together, bench, `extraA2ACallers`, and `networkPolicy.enabled=false` with channels and schedules), each with and without the Kourier API version, were rendered from `HEAD` (a `git archive` copy) and from the working tree and compared with `cmp`: 20 of 20 identical.

### Live canary (kind, context `kind-openagentix`)

Steps 1 to 4 of the canary. Two model calls were made in all (the agent turn of step 3 and the one of step 4; the gateway log shows two chat completions).

1. **Direct call and no token.** A pod with the bridge's labels calling `kagent-controller:8083` timed out (curl exit 28 after 6 s). The gate answered 401 without a token and 401 with a garbage token. Passed.
2. **A bridge token claiming another identity.** A token of the bridge's ServiceAccount (`kubectl create token`, audience `openagentix-a2a`) that sent `X-User-Id: schedule:demo-brief` got 403 (audit `reason: user_id`). The same token got 403 with no user id, 200 for the agent card of `assistant`, 403 for the card of another agent, 403 for gRPC to `MemoryService/List`, 403 for gRPC-Web on the agent path and 403 for `/api/sessions`. A token with the default audience got 401. Passed.
3. **A schedule through the gate.** A Job built from the CronJob `demo-brief` (its ServiceAccount, projected token, A2A URL and user id `schedule:demo-brief`) reached `TASK_STATE_COMPLETED` in 21.7 s. Audit line: `caller: schedule-demo-brief`, `agent: kagent/assistant`, `user_id: h:713e157c`, status 200, 21555 ms, and the trace id the Job printed. Passed (see the deviation below).
4. **A signed webhook through the gate.** A signed `question.asked` event to `demo-webhook` was accepted (HTTP 200), Kourier logged `session turn ended` with `outcome: completed`, and the gate logged `caller: kourier-demo-assistant`, user id `h:98845f7b` (the gate fixed it to the Binding's id), status 200, 10459 ms, the same trace id as Kourier's. Before that, both Bindings went `Ready=True` through the gate with their static keys (the agent card, status 200). Passed.

After the run the gate is on and healthy: `a2a-gate` 1/1 with no restart, the bridge 1/1 with its projected token and the gate URL, both Bindings Ready, the agent Ready.

### Findings

- **Kourier 0.6.0 sends the static key unchanged.** In its source (`internal/identity/token.go`, `internal/dialect/kagentv1/kagentv1.go`) the value of `identity.tokenSecretRef` is read from the Secret on every call (any non-empty value without control characters) and sent as `Authorization: Bearer <value>`. It sends `X-User-Id` only when there is no token, never both. So no JWT is needed and the HS256 fallback was not built. The live run confirmed it.
- **A Secret mounted for a non-root user needs `fsGroup`.** The first gate pod had no `fsGroup`, so the key hashes (mode 0440) were unreadable and every Kourier call got 401. Root cause found from the audit line (`reason: bad_token`), fixed with `fsGroup: 65532`, a chart test, and a warning in the gate for any key file it cannot use (`key hash file unusable`, once per file).
- **Kourier checks a Binding only every 5 minutes.** After the fix the Bindings turned Ready about 5 minutes later, not at once.
- The Kourier broker needs `list` and `watch` on the key Secrets: the chart adds `a2a-key-<binding>` to the `resourceNames` of the existing Role.
- The Kourier egress policy (marker ConfigMap) and the schedule egress policy had to point at the gate, or the callers would have been cut off by their own policies.

### Deviations from this ADR, and why

- **No `client-go`.** The gate calls the TokenReview REST endpoint with the standard library. That keeps the image and the module free of dependencies, and the fake is a plain `httptest` server.
- **JSON rules, no YAML.** The rules ConfigMap is JSON, so the gate needs no YAML library.
- **The whole query string is dropped,** not only `user_id`. A2A uses no query, and an allow-nothing rule is easier to trust.
- **Canary step 3 used a different prompt.** The demo schedule's own prompt ends by delivering a message to the owner's Telegram chat through notify. No Telegram message was to be sent, so the Job was made from the CronJob's pod template with the same ServiceAccount, token, URL and user id, but the prompt "Reply with exactly one word: pong. Do not use any tool." and no prompt volume. The path through the gate is the same. Canary step 4 used the same short question for the same reason.
- **Metrics were not added** to the gate (the audit line is the record for round 1).
- **The agent card `GET` carries no user id** upstream when the rule is `prefix`; with `exact` or `fixed` the gate sets it.
- Added beyond the ADR, to close small holes: `Cookie`, `Baggage`, `X-Agent-Name`, `X-Share-Token`, `X-Kagent-Insecure-Runtime-Identity` and `X-Forwarded-*` are removed; request bodies over 8 MiB get 413; the gate answers 503 when TokenReview itself fails (it fails closed).

### Not verified

- The bridge calling the gate end to end. The bridge pod runs with the projected token and the gate URL and is Ready, and its ServiceAccount's token is accepted by the gate (step 2), but no Telegram message was sent, so a real chat turn through the gate was not run. It is covered by the client tests (token re-read, missing file).
- Token rotation by the kubelet (the file is read again on every request; no one-hour wait was done).
- SSE through the real controller. Flushing is tested against a fake upstream; no streaming request was sent live.
- Which `message:send` and `message:stream` REST paths kagent really serves. They are allowed because A2A 1.0 defines them; only the JSON-RPC `POST` and the card `GET` were seen live.
- That the Substrate egress proxy still reaches port 8083 (F4) with the new policy. The agents answered in steps 3 and 4, which suggests the sandboxes still reach the controller through `atenet-egress`, but the actor-JWT injection itself was not inspected.
- Behaviour with more than one gate replica, a gate restart during a long stream, and rotation of a Kourier key (a new key Secret value needs the hash Secret updated by `install.sh`, then the gate reads it within about a minute).
- The `kagent` namespace peer on port 8083 is unchanged: a pod there can still impersonate a user.
- A fresh install from an empty cluster with the gate on.

## Round 1 review and fixes (2026-11-24)

A security review of round 1 found one critical hole, three important problems and two smaller ones. All are fixed and were run on the kind cluster. Each fix started with a test that failed.

### Findings and fixes

**C1, critical: the kagent UI was an open relay around the gate.** No NetworkPolicy selected the `kagent-ui` pods. Its nginx proxies `/api/`, `/a2a/` and `/mcp` to the controller and passes `X-User-Id`, and the controller serves every API (memory, sessions, A2A) over gRPC-Web on that path. A pod in `default` got HTTP 200 from `POST /api/kagent.runtime.v1.MemoryService/List` on `kagent-ui:8080`. The hole existed with the gate off too, and the gate's own policy work did not touch it. The `kagent` namespace peer on port 8083 also admitted every pod of that namespace.

- Fix: a new NetworkPolicy `openagentix-kagent-ui` selects the UI pods (`app.kubernetes.io/component=ui`, `app.kubernetes.io/name=kagent`) and admits nobody. `networkPolicy.kagentUI.allowFrom` lists peers (`namespace`, optional `podLabels`) for the UI port. It renders whenever `networkPolicy.enabled` is true, which is the default, so **the default render changed on purpose**. The 8083 policy now admits the UI pods by label instead of the whole `kagent` namespace.
- Evidence for the narrowing: in the kagent source only the UI proxies to the controller from inside the namespace; `kagent-tools` has no controller URL (its settings are the tools port, metrics and Prometheus and Grafana URLs); the sandboxes get the controller URL as their control plane address and their traffic leaves through `atenet-egress`, which stays a peer. Live: after the change an agent turn through the gate completed, so the sandbox path works.
- Proof on the cluster: the List probe with `X-User-Id: probe:none` and an empty body, from a pod in `default`, in `openagentix-gateway` and in `kagent`, timed out (curl exit 28, no HTTP status). `kubectl port-forward` to the UI still works with kindnet (root page and `/health` answered 200, `/api/version` through the UI answered 200, the UI pod stayed Ready with no new restart). Port-forward is the way to open the UI. A CNI that also filters the kubelet's connection would need `allowFrom`.
- Not covered: the UI still proxies `/a2a/` and `/mcp` to the controller for anyone who may reach it, which is why the UI is closed rather than the gate being relied on. A pod of the controller calling its own Service was not seen in the source; if a future version does that, the narrowed policy would need the controller pods as a peer.

**I1, important: cheap memory exhaustion of the gate.** Only `ReadHeaderTimeout` was set, headers could be 1 MiB, the body sniff took 64 KiB per request and waited with no deadline, and the pod limit is 64 MiB.

- Fix: `MaxHeaderBytes` 16 KiB (431 above it); a read deadline of 10 s for the start of the body, set with `http.NewResponseController` and cleared before the request is proxied, so long uploads and streams are not cut (408, `reason: body_timeout`); at most `A2A_GATE_MAX_INFLIGHT` (default 128, chart `governance.a2a.maxInFlight`) requests at once, the next gets 503 with `Retry-After` and `reason: busy`; the sniff buffer follows `Content-Length`.
- A bug found on the way: after a read timeout the server waited for the rest of the body before it answered, so the 408 never arrived. The gate now sets `Connection: close` on that answer.
- Live: a 30000 byte header got 431.

**I2, important: TokenReview amplification and cache flush.** Any three-part string cost an API call, there was no limit, and the cache emptied itself at 2048 entries.

- Fix: bearer values over 8 KiB are refused; the unverified payload must name our audience, have `iss` and a future `exp` before a TokenReview is made; one review per token at a time (singleflight), at most 8 at once with a 2 s wait that then fails closed with 503; good and refused answers live in separate bounded maps, so a flood of bad tokens cannot evict a good entry.

**I3, important, documentation: a wrong claim.** The ADR said a ServiceAccount per schedule closes "any labelled pod can call any agent". It does not. Whoever can create pods in `openagentix-schedules` (or in the bridge's namespace) can mount a projected token of any ServiceAccount there. The ADR, `security.md`, `schedules.md` and the README now say the boundary is the RBAC for creating pods in those namespaces. A per-schedule ServiceAccount limits what one token can do and puts the schedule's name in the audit line. A ValidatingAdmissionPolicy that ties a pod to its own ServiceAccount is a possible later step and is **not built**.

**M1: the claimed user id was audited before authentication.** It is now recorded only after the caller is authenticated (an unauthenticated line carries none), and cut to 128 bytes.

**M2: every JSON-RPC method passed.** Each caller now has a method list; the default is `SendMessage` and `SendStreamingMessage`. Evidence for what the chart's own callers use: the bridge and `a2a-call` send `SendMessage` only; Kourier 0.6.0 (read in its source: `internal/agent/agent.go`) sends `SendStreamingMessage`, and also uses `GetTask`, `SubscribeToTask` and `CancelTask`. The chart sets those lists, and `governance.a2a.callers[].methods` can set a list for an extra caller. A method outside the list gets 403 with `reason: method`; the audit line has the method in `rpc`.

- The method is read from the body, so on the JSON-RPC route the whole body must fit in the sniff window (64 KiB by default, `A2A_GATE_SNIFF_BYTES` up to 1 MiB) and be one object with exactly one `method` string. Anything else fails closed (403, `reason: method`): a larger body, a batch, a body that is not JSON, no or two `method` members (names are compared without case, as Go's decoder does, so a second member cannot hide one), data after the object. This also closes a trick where a second `method` member after the window would be read by the agent. Messages above the window can use the REST routes (`message:send`, `message:stream`), which name their method in the path and are not limited by the window.
- Live: `GetTask` as a schedule got 403 with `reason: method` and `rpc: GetTask`.

**Extra: the audit `context_id` was always empty.** The extraction itself works for the real request shape. A test with the body the bridge builds (a map with `jsonrpc`, `id`, `method` and `params.message`, where `contextId` is left out for a first message) shows the id for a follow-up. It was empty in the live logs because every live request was a first message (schedules always start a new conversation; the bridge had no traffic). Live proof: a follow-up with the `contextId` of the first answer showed that id in the audit line. The extraction is now exact (it reads `params.message.contextId` from the parsed body), so an id in metadata or in the text is not taken.

### What was proven live

- The canary: the UI List probe from `default`, `openagentix-gateway` and `kagent` timed out; the UI answered through port-forward; the UI pod kept running.
- Two model calls in all: a schedule's turn through the gate (`TASK_STATE_COMPLETED`, 18.9 s) and one follow-up in the same conversation (HTTP 200, the id in the audit line).
- Through the gate: `GetTask` 403 (`method`), a 30000 byte header 431, no token 401, the agent card of both Kourier bindings 200 after the new pod started.
- Tests: chart 722 assertions, gate 51 tests with `-race`, no failures.

### Not verified

- A Kourier turn after the change. The Kourier bindings call the agent card through the new gate (200), but no signed webhook was sent after the roll-out, so the exact methods Kourier sends during a turn are taken from its source, not from a live run. A binding that needs a method outside its list shows up as `reason: method` in the audit line.
- Memory use of the gate under load (the cap was tested, not the 64 MiB limit).
- The narrowed 8083 policy with a feature that calls the controller from a `kagent` pod other than the UI. None was found in the source or in the cluster.
- Whether the UI works for a user who reaches it by a route other than port-forward (an ingress needs `allowFrom`).
- A ValidatingAdmissionPolicy for pod ServiceAccounts: not built.

## Round 2 results (2026-11-24)

Round 2 is built, tested and run on the kind cluster: tool profiles (`mcp.profiles`, `agents[].toolProfile`) and per-agent egress (`agents[].egress.allow`). Round 3 is not started. Everything is **off by default**: with no profile, no `toolProfile` and no `egress`, 28 renders (the default, each demo values file, all together, the gate on, the bench values, the `networkPolicy` and `mcp` and `kagent` switches, each with and without the Kourier API version) were saved before the change and compared with `cmp` afterwards: 28 of 28 byte-identical.

### The open points, answered by evidence

Source reading first (ToolHive v0.67.1), then a live run on the kind cluster with the demo profile.

**(a) Do tool filters apply to `MCPServerEntry` backends? Yes.**

- Source: the filter is keyed on the backend id, and the id of an `MCPServerEntry` is the entry name (toolhive `pkg/vmcp/workloads/k8s.go:546`, `pkg/vmcp/aggregator/default_aggregator.go:720-740`). The same code path serves `MCPServer` and `MCPServerEntry`.
- Live: the profile `lookup` lists `knowledge: [kb_search]` and `osv: [query_vulnerability, get_vulnerability]`. Its `tools/list` returned exactly `knowledge_kb_search`, `osv_get_vulnerability`, `osv_query_vulnerability` and `execute_tool_script`. The knowledge entry offers six tools with the graph on and the other five were absent. `delivery` (also an entry) and `fetch` were absent.
- A detail that matters: `aggregation.tools[].filter` names the backend's own tool name (`kb_search`), not the prefixed name the agent sees (`knowledge_kb_search`). The chart takes the backend names in the profile and builds the agent-side names itself.
- Another detail: a filter alone only hides a backend's own tools from the list. A backend with no entry would stay fully visible. The chart therefore also sets `defaultToolVisibility: deny` on every profile vMCP, so a backend that the profile does not name contributes nothing, and a backend added to the group later is not exposed by accident.

**(b) Is a hidden tool unreachable through code mode? Yes.**

- Source: ToolHive keeps hidden tools in the routing table for composite workflows, but `CallTool` refuses a name that is not advertised (`pkg/vmcp/core/core_calls.go:62-100`), and the code-mode script is bound only to the advertised tools of the caller.
- Live, from the sandbox of the profile agent, with the real actor JWT: a direct `tools/call` for `fetch_fetch`, `knowledge_kb_get_document`, `delivery_notify_list_destinations` and the alias form `fetch.fetch` all answered JSON-RPC error `-32602 tool ... not found`. `execute_tool_script` with a script calling `fetch_fetch`, `knowledge_kb_get_document` or `delivery_notify_list_destinations` failed with `script execution failed: undefined: <name>`: the hidden tool is not even bound in the script. The allowed tools worked directly and from a script (`osv_get_vulnerability`, `knowledge_kb_search`). The profile vMCP audit log recorded each refusal as `application_error` with the session actor as the subject.

**(c) Does a profile agent have any path to the shared vMCP? No, and not through its own egress policy.**

- The sandbox of `profile-demo` was driven by the stub model (no paid call) through `bash`. Its egress allowlist holds only the origins its own tools imply (its profile vMCP), the model gateway, the controller and the `egress.allow` origin.
- By name, the shared vMCP does not resolve (`wget: bad address`). By Service IP with the correct `Host` header, the answer was `403 Forbidden` from the egress proxy, with a placeholder `Authorization` header present. The same 403 came for the `fetch` tool server's proxy and for the kb (both are unauthenticated and protected only by NetworkPolicy), and for the profile vMCP's own IP with a wrong `Host`.
- Its own profile vMCP answered 200 for the same kind of request. So the 403 comes from the allowlist, not from a broken request.
- **A correction to F5.** F5 says the egress proxy puts the actor JWT on any request to the vMCP origin. Live, it does not add one: a request without an `Authorization` header reached the profile vMCP anonymous and got 401. The proxy **replaces** an `Authorization` header that the request already carries (the kagent type says so: "Requests must send the header"). So `bash` needs one placeholder header to be authenticated as the session, which is no real obstacle, but it is not "no token at all". The conclusion of F5 stands: a prompt-injected agent on the shared vMCP can call every tool on it. With a profile, it can call only the profile's tools.

**(d) Cost of one extra vMCP pod.** Measured from the node (`crictl stats`, the metrics API is not installed): working set 30.0 MB and resident 29.2 MB for `tools-lookup`, against 30.8 MB working set and 27.9 MB resident for the shared `tools`, over three samples taken a few seconds apart; CPU 2 to 6 millicores while idle or answering a handful of calls. The operator gives each vMCP requests of 100 millicores and 128 MiB and limits of 500 millicores and 512 MiB, so the scheduler counts 100m and 128 MiB per profile. After the install: node requests 2720m CPU (45%) and 4322 MiB (54%) of the 6 CPU / 8 GB node, 46 running pods (one more than before), load average 0.7 to 2.1 over the run. One profile is cheap; several would add up in requests rather than in use.

### What was built

- Chart `mcp.profiles`. Each profile renders:
  - a VirtualMCPServer `<virtual.name>-<profile>` on the same MCPGroup, with `defaultToolVisibility: deny` and one `aggregation.tools` entry per backend;
  - the `codeMode` block when the profile sets `codeMode: true` (the limits are the shared ones);
  - the audit and telemetry settings of the shared vMCP;
  - an `incomingAuth` that reuses the one MCPOIDCConfig (issuer, keys and CA are the same) with its **own audience** `<oidc.audience>-<profile>`;
  - a RemoteMCPServer `<remoteMCPServer.name>-<profile>` whose `actorJwt.audiences` is that audience;
  - an ingress NetworkPolicy equal to the shared one, and a metrics policy when observability is on.
- Chart `agents[].toolProfile`: the agent's tools come only from the profile's RemoteMCPServer. The render fails for an unknown profile, for a tool the profile does not offer (and says what it offers), for `execute_tool_script` on a profile without `codeMode`, for an extra tool that `knowledge: true` or `notify` adds and the profile lacks, and for a tool entry that names another server.
- Chart `agents[].egress.allow`: an `EgressPolicy` `<agent>-egress` in the agent's namespace and `egressPolicyRefs` on the Agent. Entries follow the kagent CRD pattern (`https` or `http`, a lower case DNS name, an optional port, a wildcard only for one leftmost label, no path, no address) and the render fails for any other entry, a duplicate, more than 64, and an origin inside the tools namespace (that would reach a vMCP or an unauthenticated tool proxy around the profile).
- Render failures also cover: duplicate profile names, an invalid profile name, an unknown backend, an empty tool list, a profile with `incomingAuth.type` other than `oidc`, `toolProfile` with `mcp.enabled` or `kagent.remoteMCPServer.enabled` off.
- The kb and notify ingress policies admit every profile vMCP (see the finding below).
- `install.sh` waits for each profile vMCP to be Ready; `uninstall.sh` needs nothing (the objects go with the release).
- `components/governance/profiles-demo-values.yaml`: one profile `lookup`, the `assistant` agent restated unchanged (the agents list is replaced by a later file, so the file must come last), a small agent `profile-demo` on the profile with `egress.allow: ["https://api.osv.dev"]`, and a caller `profile-canary` for the gate (inert with the gate off).
- 103 new chart assertions (827 in all, 0 failing).

### Live canary (kind, `kind-openagentix`)

Install with the six current demo files plus the profiles file, without rebuilding the unchanged images (`SKIP_*_IMAGE=1`). Two model calls were made in all (the budget was four); the refusals were proven without a paid call.

1. **A profile agent answers with an allowed tool.** `profile-demo`, called through the gate as the caller `profile-canary` (a projected token and `X-User-Id: canary:profiles`), completed (`TASK_STATE_COMPLETED`, 21.9 s) and said it used `osv_get_vulnerability` for the Log4Shell advisory. One model call.
2. **A tool outside the profile cannot be used.** Stub model, no paid call, same real objects: the ModelConfig of `profile-demo` was patched to a stub for the test and patched back. Through `bash` in the real sandbox: the direct and code-mode refusals listed under (b).
3. **Egress.** From the same sandbox: `https://api.osv.dev` answered 200 (inside `egress.allow`); `https://example.com` and `https://api.github.com` did not resolve; example.com by IP was refused (403 over http, a reset over https); the shared vMCP, the `fetch` proxy and the kb by IP with their real `Host` header got 403. No paid call.
4. **`assistant` is unchanged.** It completed (10.4 s) through the gate and used `osv_get_vulnerability` on the shared vMCP; the shared vMCP audit shows that call and the profile vMCP shows none for it. One model call.

After the run: both agents Ready, both vMCPs Ready with four backends, the stub, the test ServiceAccount and the test Jobs removed, every pod Running.

### Findings

- **Every vMCP of a group connects to every backend.** The first profile install showed `Degraded`: the profile did not list a notify tool, the notify ingress policy had admitted only the shared vMCP pod, and the profile's health check of `delivery` timed out for about eight minutes before it recovered once the policy was fixed. A profile hides tools; it does not remove a backend from the vMCP's view. The kb and notify policies now admit every profile vMCP. The hidden tools are still not callable (b).
- The agent-side tool filter is client side (F5), so a hidden tool cannot be tried through the model: the stub only calls a tool the ADK advertises. The proofs above therefore go through `bash`, which is the realistic path for an injected agent.
- The sandbox has `wget` and `sh`, no `curl`, no `python3`.
- Outside hosts that are not on the allowlist usually fail at DNS inside the sandbox (`bad address`). The 403 appears when the address is used directly.
- An `egress.allow` entry takes effect without a restart: `EgressPoliciesApplied` was `True` and the allowed host answered in the first test.

### Deviations from this ADR, and why

- **One OIDC config, not one per profile.** The ADR said an MCPOIDCConfig audience per profile. In ToolHive the audience is a field of the reference (`oidcConfigRef.audience`, "must be unique per server"), not of the MCPOIDCConfig. The issuer, keys and CA are the same for every vMCP, so one MCPOIDCConfig is reused and each profile gets its own audience. The chart fails if two vMCPs would share an audience.
- **`defaultToolVisibility: deny`** was added (not in the ADR): see (a).
- **Cedar is permit-all on a profile.** `toolAccess` names tools of the shared vMCP and would silently remove tools from a profile; the filter is the limit.
- **No `fetch` host allowlist and no `MCPToolConfig`.** Not part of this round.
- The profile agents' tool names for a backend are written with the shared `prefixFormat`; the chart builds them from the profile.
- The stub test changed a ModelConfig by hand for a few minutes and restored it; a Helm upgrade would also have restored it.

### Not verified

- More than one profile on the node, and what a pod budget of several profiles does to the node under load. Only one profile ran.
- A Cedar `toolAccess` on the shared vMCP together with profiles (profiles ignore it by design; no test with it set).
- The demo run with a fresh install from an empty cluster.
- Whether a future ToolHive version keeps hidden tools out of `CallTool` and code mode: this is source and live behaviour of v0.67.1.
- A hidden tool through a composite tool (the chart defines none).
- `egress.allow` with a wildcard or with `http` live (only the exact `https` origin was run); `EgressPolicy` credentials are not rendered by the chart at all.
- The model gateway origin and the other always-allowed origins are still reachable from a profile agent's sandbox by design (its own key); `bash` stays on (owner decision).
- Token revocation: an actor JWT of a profile works until it expires.
- That a model, not a stub, can be talked into a refused call: the refusals were proven at the vMCP and the proxy, which are the same whoever asks.

## Round 3 results (2026-11-24)

Round 3 is built, tested and run on the kind cluster: the memory expiry CronJob (`memory.expiry`), the `/memories` and `/forget` commands of the bridge through the gate (`bridge.memoryCommands`, `memory: true` in a gate rule) and the opt-in secret scan (`memory.expiry.secretScan`, `secretScanDelete`). Everything is **off by default**: 26 renders (the default, every demo values file singly, all together, the gate on, the gate and profiles on, the bench values, `networkPolicy.enabled=false`, each with and without the Kourier API version) were saved from `HEAD` before the change and compared with `cmp` afterwards: 26 of 26 byte-identical. No kagent Helm change, no controller roll by us.

### What was built

- **Gate** (`services/a2a-gate`, `memory.go`, `rules.go`): a caller whose rule has `memory: true` may call `POST /kagent.runtime.v1.MemoryService/List` and `/Delete` over binary gRPC-Web, and nothing else of gRPC. The method list of the rule does not apply to them. Details in "How the user id is bound" below. 11 new Go tests, 62 in all, with `-race`; coverage of the gate package 93%.
- **Bridge** (`bridges/telegram`): a small gRPC-Web client (`internal/memory`, no protobuf library, errors with numbers only), the commands `/memories` and `/forget` (then `/forget confirm`), and the settings `MEMORY_GATE_URL` and `MEMORY_AGENT`. About 25 new tests, 122 in all, with `-race`. The reply of `/memories` shows at most 10 items of 200 characters, at most 3500 characters, and a count of the rest. A failing call gives a generic reply; the log has the outcome (`memories`, `forget`, `forget_ask`, `memory_error`), a count, and for an error only the HTTP and gRPC status numbers. A test plants a canary string in the memory content and in the error text and asserts that neither reaches the reply or the log, nor the chat id.
- **Expiry job** (`charts/openagentix/files/memory-expiry.sh`, `templates/memory-expiry.yaml`): a CronJob `memory-expiry` in the `kagent` namespace (schedule `17 3 * * *`, `concurrencyPolicy: Forbid`, `backoffLimit: 2`, 300 s deadline; it was 0 until issue #202: the script now waits for DNS and the database for half the deadline, a refused login exits 78 and a pod failure policy fails the job at once with no retry). It runs the two statements of kagent's `PruneExpiredMemories` (`go/core/internal/database/memory.go` lines 125-139, kagent v1.0.1 commit `558e3d7`; the predicates are the same, wrapped in a counting CTE) with psql from the image of kagent's own database (`pgvector/pgvector:pg17`, by digest, already on the node). The login is the existing Secret `kagent-postgres-readwrite` key `readWriteConnectionString`, by `secretKeyRef`; no value is copied, rendered or logged. The pod is non-root, read-only, drops all capabilities and mounts no ServiceAccount token. The log is two lines of counts. A NetworkPolicy `openagentix-kagent-pg` (only with `networkPolicy.enabled`) lets only the controller pods and the job's pods reach kagent's PostgreSQL, which was open to every pod before.
- **Secret scan** (same script): ten patterns with fixed names (AWS access key id, bearer token, GitHub token, Google API key, JWT, private key header, provider `sk-` key, Slack token, Stripe key, Telegram bot token). The log gives a count per name and the number of matching rows, never text. Report only by default; `secretScanDelete: true` deletes the matching rows and needs `secretScan: true`.
- **Chart**: `memory.expiry`, `networkPolicy.kagentPostgres`, `bridge.memoryCommands`, `governance.a2a.callers[].memory`. The render fails for `memoryCommands` without the gate, without the bridge, without the agent in `agents[]` (in the kagent namespace) or with `memory.enabled` off on it; for non-boolean switches; for `secretScanDelete` without `secretScan`; for a bad schedule, schema, role, Secret or deadline; and for a non-boolean `memory` on an extra caller. 74 new assertions (901 in all, 0 failing).
- **SQL test** (`charts/openagentix/tests/memory-expiry-integration.sh`, 29 assertions): starts a throw-away `pgvector/pgvector:pg17` container itself (`docker run --rm`, stopped by a trap, the way `services/kb` does `make test-integration`), builds kagent's roles and schema with the repository's own `components/runtime/dl/kagent-setup.sql`, creates the `memory` table like kagent's vector migration, and runs the job script exactly as mounted, as the read/write login. It is the only database the test connects to.
- `components/governance/memory-demo-values.yaml`: expiry on, secret scan report only, `bridge.memoryCommands`, and a caller `memory-canary` (`memory: true`, user ids with the prefix `probe:` only, inert without a ServiceAccount). `install.sh` and `uninstall.sh` needed no change: the existing image build and source hashes roll the gate and the bridge.

### How the user id is bound for the memory RPCs

Decided by evidence, not by assumption.

- The request messages are `MemoryServiceListRequest` and `MemoryServiceDeleteRequest`, each with the single field `agent_name = 1` (`proto/kagent/runtime/v1/memory.proto`). There is no user field.
- In the service, `managementScope` takes the user from the authenticated principal (`go/core/internal/service/memory/service.go`); the gRPC interceptor builds the principal from the forwarded metadata `x-user-id` (`go/core/internal/grpcserver/interceptors.go`), which the `insecure` authenticator reads (`go/core/internal/httpserver/auth/authn.go`; for gRPC the query is empty).
- So the user id is **the `X-User-Id` header**, not the message. The gate sets it from the caller's rule exactly as for A2A: `exact`, `prefix` or `fixed`, two values refused, the query string dropped, `Authorization` and the other identity headers removed.
- The message is still checked, because it names the agent and a later API version could add a field. The gate reads the one frame (at most 600 bytes, within the sniff timeout), requires exactly one string field number 1 and nothing else, requires the agent to be in the caller's rule, and forwards the bytes it verified (not the original reader). Refused with 403 and a `reason`: not POST or another path (`path`), another content type, base64 text mode or a compression header (`grpc`), no `memory: true` (`memory`), a user id outside the rule (`user_id`), a bad frame (`frame`), an agent outside the rule (`agent`). Too large: 413. Slow: 408.
- The bridge sends `X-User-Id` = prefix + chat id, from the chat id Telegram puts on the update, never from text.

Live evidence (below) shows the same: a request that names a user id in the message (field 2) gets 403 `frame`; one that names another user id in the header gets 403 `user_id`; neither reached the controller.

### Does search return expired rows before the job runs? Yes

`SearchAgentMemory` and `ListAgentMemories` have no `expires_at` filter (`memory.go` lines 53-66 and 85-101: "Expired rows remain searchable until pruned"). The integration test shows it with the statement of `SearchAgentMemory` against the throw-away database: a user with two expired and two valid rows gets four rows back before the job and two after. Effects:

- An expired memory is still recalled into the model's context, and still listed by `/memories`, until the next run of the job (up to a day with the default schedule). With the job off, for ever.
- A memory that is recalled often does not die: kagent's rule gives fifteen more days to an expired row that was read ten times, and each recall is one read.
- The delete that `/forget confirm` does is immediate and does not depend on the job.

### Live canary (kind, context `kind-openagentix`)

Install with the eight demo files (the command of the task, with `SKIP_KB_IMAGE=1 SKIP_NOTIFY_IMAGE=1 SKIP_A2A_CALL_IMAGE=1`); it took 191 s, every pod Running afterwards. **Two model calls** (one agent turn, two chat completions in the gateway log).

1. **Expiry job by hand** (`kubectl create job --from=cronjob/memory-expiry`): it completed in 4 s. Log: `total_before=9 expired=0 extended=0 deleted=0 total_after=9`, then `secret_scan=on delete=off rows_matching=0 rows_deleted=0 patterns=` and ten names with count 0. Counts only. After the probes below a second run showed `total_before=9 ... total_after=9`: the nine existing rows were untouched.
2. **Bridge** Ready with `memory_commands: true` in its start line and the gate URL and agent in its environment. No Telegram message was sent.
3. **Through the gate** with a test caller `memory-canary` (`memory: true`, prefix `probe:`), from a pod in the schedules namespace with a projected token, using a small throw-away client that prints status numbers and counts only:
   - `List` and `Delete` for its own made-up id `probe:own-1`: HTTP 200, gRPC status 0, zero items.
   - `List` naming an id with the prefix `telegram:`, `List` naming `schedule:demo-brief` (the id of the real demo schedule), `Delete` naming a `bench:` id and `List` without a user id: 403 each, audit `reason: user_id`, so nothing was forwarded. `List` naming another agent: 403 `agent`. A message with a second field: 403 `frame`. `Search` and `AddSession`: 403 `path`. Those ids were named only in the header of requests that the gate refused before anything was forwarded (the audit lines show status 403 and no agent), so no real user's memory was listed or deleted; but one of them was a real schedule's id, which the task asked to avoid even as a name.
   - A caller without the flag (a schedule's own ServiceAccount, sending `probe:own-1`): `List` and `Delete` both 403, `reason: memory`.
   - **One model turn** as `probe:own-3` ("remember that my probe codename is ..."): the agent saved a memory (200, `TASK_STATE_COMPLETED`, 24 s). `List` for `probe:own-3` then returned one item with HTTP 200. Its answer, captured as hex, decodes to the saved sentence and an `expires_at` 30 days later (it is now a test fixture of the bridge). `Delete` for `probe:own-3`, then `List`: zero items. This is the full path: gate, controller, database, and back.
   - Audit lines carry `rpc` (`MemoryService/List` or `Delete`), the agent when allowed, the hashed user id and the status; no content.
4. **The database policy** (`openagentix-kagent-pg`) was active during all this: the controller read and wrote through it, and the expiry job connected through it.

The test ServiceAccounts and jobs were removed. The throw-away client image `openagentix/memprobe:dev` stays in the node's image store (nothing runs it).

### Findings

- **kagent's database logins are `NOINHERIT`.** The login `kagent_readwrite_user` has no privileges of its own; kagent itself runs `set_config('role', 'kagent_readwrite')` after every connect (`go/core/pkg/postgres/pool.go`). The first run of the SQL test failed with "no schema has been selected" and "permission denied": the job now runs `SET ROLE` first (`memory.expiry.role`). Found by the test, not on the cluster.
- **The first live probe of a caller without the flag returned `unknown_caller`**, not `memory`: the memory demo file replaces the `governance.a2a.callers` list of the profiles demo file (lists are replaced, not merged), so `profile-canary` was no longer a caller. The demo file says so; the live test used a schedule's ServiceAccount instead.
- **The kagent controller restarted once during the canary** (exit code 1 at 13:49, back Ready after about 20 seconds, restart count 143). It had restarted 142 times in the 32 hours before (leader election and start-up races were noted in round 1 and in ADR 0003). The previous log was not available; the cause was not found, and nothing links it to the new policy (it reconnected to the database and answered later calls).
- The node's load average stayed between 4 and 7 for about half an hour after the previous round with the CPU 90% idle (a node with many processes); builds waited for the one-minute value under 4.

### Deviations from this ADR, and why

- **Image:** the ADR says "a tiny image already on the node or a pinned `postgres` client image matching the server major version". The job uses the server's own image, `pgvector/pgvector:pg17` by digest: it is already on the node, has the same major version and has psql. It is large (676 MB on disk) and not tiny.
- **`SET ROLE`** (see Findings). The SQL is kagent's statements with a counting wrapper (`WITH x AS (UPDATE ... RETURNING 1) SELECT count(*)`), so the log can have counts; the predicates are unchanged.
- **The SQL test is a shell script with `docker exec psql`, not a Go test**, because the job is a psql script and the chart ships it. It publishes no port (the kb test publishes one on 127.0.0.1); the start, readiness wait and trap-stop follow the kb test.
- **Policy on kagent's PostgreSQL** is added only with `memory.expiry.enabled` (it is open to every pod otherwise, as before). The task text allowed reading "only this job's pods in addition to today's peers"; the only peer found in the cluster is the controller, so those two are the peers. Not verified: that nothing else of kagent connects (the controller's own migrations and pools were not disturbed).
- **gRPC-Web only.** The gate listens on HTTP/1.1, so native gRPC cannot reach it and the memory RPCs are open for binary gRPC-Web only; base64 text mode and compression are refused.
- **The upstream issues** (call the prune function, filter `expires_at` in search, verify `trusted-proxy` signatures) are **not filed**; the ADR said they would be by round 3. They need your decision and an account.
- `bridge.memoryCommands` needs the bridge's agent in `agents[]` in the kagent namespace; a bridge that talks to an agent outside this chart cannot use it.

### Not verified

- A real Telegram `/memories` and `/forget confirm` (no Telegram message was sent). The bridge side is covered by unit tests with a fake gate, and one of them decodes a real controller answer; the gate side was run live with the same protocol.
- The deletion of an **expired** row on the cluster. Expiry is proven in the throw-away database only (a row cannot expire on the cluster before its `ttlDays`, and the cluster has no expired row); the cluster run found `expired=0`.
- A cron-fired run of the CronJob (only a manual run), the secret scan deleting rows on the cluster, and the scan patterns on real text (false positives and misses were not measured).
- PostgreSQL versions other than 17, and a fresh cluster pulling the job image from a registry.
- Many parallel memory calls through the gate, group chats, and a user id with unusual characters through the bridge.
- That nothing else in the cluster needs kagent's PostgreSQL than the controller and the job.
- The cause of the controller restart.


## Round 3 review and fixes

An independent security review of the round 3 change found no critical or important issue. The gate opening for the two memory calls held: a differential fuzz test of the frame parser against a protobuf decoder found no difference, and cross-user access, other calls and leaks into logs were all refused on the gate side. It also confirmed from the kagent source that the controller is the only client of kagent's PostgreSQL, so the new database policy cuts off nothing.

Three minor findings, all fixed test-first:

- **Database password in the process arguments.** The expiry script passed the whole connection string to `psql`, so the password was readable in the process list of the node while the job ran. The script now splits the string: the password goes into the `PGPASSWORD` environment variable (percent-decoded) and `psql` gets the string without it. The integration test checks both the script text and a percent-encoded password.
- **Group chats.** A group shares one memory scope, so any member could delete it for all. `/forget` is now refused outside a private chat, `/memories` in a group says "from the members in this chat", and a forwarded message is never taken as a memory command.
- **Reply length.** Telegram counts its message limit in UTF-16 code units. The `/memories` reply is now bounded in those units, so a list of emoji-heavy memories cannot make the reply fail.

Not verified after these fixes: the commands in a real Telegram group, and the forward markers of Telegram clients older than Bot API 7.0 other than `forward_date`.
