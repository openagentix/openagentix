# ADR 0007: control plane and agent builder

Status: Accepted (2026-11-25). Slices are built one at a time; results are added below as they land.

## Context

The product brief asks for an agent builder ("configure agents by providing agent config, instructions and more") and an agent control plane.

Today an agent exists only as an entry of `agents[]` in the chart values. Adding or changing one means editing values and running `install.sh` again, which also creates the agent's gateway key, registers its hash and waits. Nothing shows in one place which agents exist, whether they are healthy and what each may do.

A design study of the code and the running cluster found a second, stronger reason to act. kagent's own resources are an unguarded builder API. Anyone who may write `agents.api.kagent.dev`, `AgentTemplate` or `ModelConfig` in the `kagent` namespace can give an agent:

- the `kagent-tool-server` RemoteMCPServer, whose ServiceAccount is bound to a cluster-admin role;
- the `default-model-config`, which uses a provider key directly and so goes around the gateway's per-agent keys and budgets;
- any harness image and any EgressPolicy.

So "let users create kagent agents" is not a safe builder. The kagent UI could do exactly this, which is one reason it is closed (ADR 0006).

## Options

| | A. CLI edits values, runs `install.sh` | B. Controller watches one ConfigMap | C. kagent resources directly plus a key provisioner | D. Own resource kind plus a narrow controller |
|---|---|---|---|---|
| Effort | small | medium | small, plus many admission rules to make it safe | medium |
| Who may create agents | whoever can run the installer (cluster admin) | whoever may write that ConfigMap, all or nothing | whoever may write kagent resources, with the three problems above | whoever may write the new kind, nothing else |
| Validation | at render time only | asynchronous, one status for all | none | schema, admission policy, controller, shown in status |
| GitOps | poor | conflicts on one object | good, but keys still imperative | one YAML per agent, `Ready` condition |
| Later enterprise split | none | weak | tied to kagent's schema | new kinds in our API group |

## Decision

Option D, in four parts.

1. **A resource kind `AgentDefinition`** in the API group `openagentix.io/v1alpha1` (plural `agentdefinitions`, short name `oad`). It is not called `Agent`, because `kubectl get agent` and `kubectl wait agent/<name>` already mean kagent's kind.
2. **A controller**, `services/control-plane`, that turns one `AgentDefinition` into what an agent needs: the five kagent objects, a gateway virtual key and its registration. It writes status back and removes everything on delete.
3. **A platform policy** owned by the operator (chart values `controlPlane.policy`): which models, tool profiles, skills and egress origins a definition may use, and how many agents may exist. A definition outside the policy is refused.
4. **A web console** (Svelte) and its small API, for building agents and for seeing the platform in one place. The study recommended a command-line tool and a read-only page; the project owner asked for a studio-style web console with a builder, so the console writes. The rules that keep it from becoming a relay like the kagent UI are in "Console" below.

Everything is off by default (`controlPlane.enabled`, `console.enabled`). With both off the chart renders byte-identically to before.

The chart's `agents[]` stay as they are: rendered by Helm, keys made by `install.sh`. They are not migrated in this ADR. The console lists them next to the built ones, marked as chart-managed and read-only.

## Scope: everything is configurable through the control plane

The project owner set the target on 2026-11-25: every configuration the platform has (agents, model routing, channels and triggers, scheduled jobs, knowledge base and graph, connectors, tools, skills) must be doable from the console.

Today most of that is chart values plus imperative installer steps. A console cannot safely edit Helm values. So the rule for the whole programme is:

> Each configurable thing becomes a resource in `openagentix.io`. The control plane reconciles it into the upstream objects. The console, `kubectl` and Git all write the same resources, and nothing else.

The chart keeps installing the platform itself (operators, gateway, services, policies) and the limits inside which those resources may be used. Values lists such as `agents[]` or `schedules[]` keep working and are shown in the console as chart-managed.

Planned kinds, one per slice, in this order:

| Kind | Replaces (today) | Reconciles into | Notes |
|---|---|---|---|
| `AgentDefinition` | `agents[]` | kagent objects, gateway key | this ADR, slice 1 |
| `Schedule` | `schedules[]` | prompt ConfigMap, CronJob, ServiceAccount, gate caller rule | needs the gate to load rules without a restart |
| `Channel` and `Trigger` | `channels.connections[]`, `channels.bindings[]`, the Telegram bridge settings | Kourier ChatConnection and Binding, gate caller rule | credentials are entered once and stored as a Secret, never shown again |
| `ModelProvider` and `ModelRoute` | `gateway.models`, provider key Secrets, the one shared budget | agentgateway models, policy, per-agent budgets | provider keys are write-only in the console |
| `ToolServer` and `ToolProfile` | `mcp.servers`, `mcp.profiles` | ToolHive MCPServer or MCPServerEntry, VirtualMCPServer, RemoteMCPServer | a new server image is a supply-chain decision: digest required, operator approval |
| `KnowledgeCollection` and `KnowledgeSource` | `hack/kb-ingest.sh`, `hack/kb-graph-load.sh` | kb collections, ingest jobs, graph settings, fact sets | connectors (Git, web, object storage) are sources with a sync schedule |
| `Skill` | `skills` map of digests in values | entry in the organisation's skill registry | see "Skill registry" |
| `ObservabilitySettings` | the `observability` values block | gateway tracing, vMCP telemetry, runtime and channel OTLP settings, scrape targets | content capture stays off unless the operator's policy allows it |
| `NotifyDestination` | the destinations Secret created by the installer | notify service destinations | creating a way to message a person stays an explicit opt-in |
| `PlatformPolicy` | `controlPlane.policy`, gate caller rules, egress limits | the policy the controllers enforce | written by operators only; the console shows it and, later, edits it under a separate role |

Each kind gets its own short decision record when its slice starts, because each has its own security questions (who may add a provider key, who may add a tool server image, what a connector may fetch). The mechanism is the one decided here: schema, policy, narrow controller, status, admission guard.

Two changes to the existing platform follow from this and are part of the slices that need them:

- **The A2A gate reads its rules from resources or reloads its file**, so that a new schedule or trigger does not need a gate restart, and the control plane can add the caller rule for a schedule or channel it creates. Until then, an operator adds caller rules in values.
- **Secrets entered in the console are write-only**: sent once over the port-forward to the console API, stored as a Kubernetes Secret, never returned, logged or shown. The console shows only that a credential exists and when it was set.

### Standard resources, upstream tools as adapters

The project owner also asked (2026-11-25) that these resources standardise the platform, and that the upstream tools sit behind adapters so that one can be exchanged later, for example the agent runtime (kagent today, Google AX as the recorded alternative of ADR 0005).

So the `openagentix.io` kinds are the platform's own contract and carry no upstream vocabulary:

- A spec names platform concepts only (model, tool profile, skill, knowledge, memory, egress). It has no kagent, agentgateway, ToolHive or Kourier field, name or reference.
- Status reports platform facts (ready, endpoint to call, effective tools). The upstream object is named in one generic reference, for people who debug.
- The controller is split into a core (validation against catalog and policy, status, keys, ownership) and adapters behind small Go interfaces. The core never imports an adapter's types.

| Adapter interface | Does | First implementation | Could be exchanged for |
|---|---|---|---|
| `Runtime` | turns an agent definition into running-agent objects, reports readiness and the call endpoint | kagent 1.0.1 with Agent Substrate | Google AX, another A2A runtime |
| `ModelGateway` | registers a per-agent key, later models and budgets | agentgateway | another OpenAI-compatible gateway |
| `Tools` | resolves a tool profile to a tool server the runtime can use, later servers and profiles | ToolHive vMCP | another MCP gateway |
| `Channels` | connections and triggers | Agent Kourier, the Telegram bridge | another channel gateway |
| `Scheduler` | timed runs | Kubernetes CronJob with `a2a-call` | a workflow engine |
| `Knowledge` | collections, sources, graph | `services/kb` | an external knowledge service |
| `SkillStore` | stores and resolves skill artifacts | in-cluster OCI registry | an external registry |
| `Observability` | where traces and metrics go, and where the console reads turns, cost and usage from | bundled VictoriaMetrics and Jaeger, or an OTLP endpoint | Prometheus, Tempo, Grafana, a vendor backend |
| `Memory` | long-term memory settings, expiry, a user's list and forget | kagent memory in PostgreSQL with pgvector | another memory service |
| `Sandbox` | isolation, per-session identity, egress rules | Agent Substrate (gVisor) | another sandbox runtime |
| `Notify` | destinations an agent may message | `services/notify` | another notification service |
| `Governance` | who may call an agent, audit | the A2A gate | a service mesh or API gateway policy |

The list is open: a new area of the platform comes with its kind and its adapter interface.

The platform catalog names the active adapter of each interface (`runtime: kagent`, and so on). One adapter per interface is active in a cluster in this version; running two runtimes side by side is not a goal now.

What this does not promise: that a second runtime is a drop-in. Features differ (kagent's memory, Substrate's per-session identity and egress control have no exact AX equivalent, see ADR 0005). An adapter reports what it cannot do, and a definition that needs it is refused with a clear reason. The adapters make an exchange a contained piece of work instead of a rewrite of every values file and every console page.

### Skill registry

Skills are OCI images today: `install.sh` builds the example skill, pushes it and writes its digest into values. For an organisation that is not enough: there is no place to see which skills exist, who published a version, or which agents use it.

Decision: the platform gets an organisation skill registry.

- **Storage:** an OCI registry inside the cluster (one small pod, one volume), or an external registry the operator names. Skills stay OCI artifacts, so kagent's skill loading does not change.
- **Catalogue:** a `Skill` resource per skill: name, description, versions with digests, source (Git URL and commit, or upload), publisher, and a state (`draft`, `approved`, `retired`).
- **Use:** an `AgentDefinition` names a skill and optionally a version. The controller resolves it to a digest. Only `approved` versions resolve. The policy can narrow the set further.
- **Publish:** from Git (the controller builds the artifact from a repository path at a commit) or by upload through the console. A skill runs code in the agent's sandbox, so approval is a separate, deliberate step and is recorded.
- **Console:** the Skills page lists skills, versions, agents that use each one, and shows `SKILL.md`.

Signing of skill artifacts and per-team visibility are later steps (enterprise candidates).

## `AgentDefinition`

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata:
  name: researcher        # DNS label, at most 40 characters
  namespace: kagent       # only the kagent namespace is reconciled in v1alpha1
spec:
  description: Looks things up            # at most 256 characters
  model: claude-haiku                     # a gateway model the policy allows
  instructions: |                         # the system prompt; required, at most 16 KiB
    You are a careful research assistant...
  toolProfile: lookup                     # required when tools are listed
  tools: [osv_query_vulnerability]        # agent-side names; each must be offered by the profile
  knowledge: false                        # adds the knowledge tools and prompt
  notify: false                           # adds the notify tools and prompt
  memory: {enabled: false, ttlDays: 30}
  skills: []                              # names from the platform catalog, never an image reference
  egress: {allow: []}                     # origins; each must match the policy
status:
  observedGeneration: 3
  conditions:                             # Accepted, KeyReady, Applied, Ready
  agentRef: {apiVersion: api.kagent.dev/v1alpha3, kind: Agent, name: researcher}
  gatewayUserId: researcher
  toolServer: toolhive-vmcp-lookup
  effectiveTools: []
  effectiveEgress: []
  a2aUrl: ""                              # the gate URL when the gate is on
  violations: []                          # one sentence per refused rule
```

There is deliberately no field for a ModelConfig reference, a harness or image, a RemoteMCPServer name, an EgressPolicy reference, an output namespace, A2A callers, a gateway user id or a budget. Those come from the platform, so a definition cannot reach around the policy.

> Amendment (2026-11-25, [ADR 0015](0015-bring-your-own-agent.md)): "no field for a harness or image" is now narrowed by one exception. `spec.runtime.container.image` is the user's own agent image, pinned by digest and matched against an operator allowlist. What changed: a definition may name that one image when the operator allows the `container` runtime. What did not change: there is still no field for a harness image, a platform component image, a ModelConfig, a RemoteMCPServer, an EgressPolicy reference, a gateway user or a budget, and no other image field is added.

Refused, with `Accepted=False` and a sentence in `violations`:

- a model, profile or skill that the catalog does not have or the policy does not allow;
- tools without a tool profile (the shared vMCP filters on the client side only, ADR 0006), and a tool the profile does not offer;
- `knowledge` or `notify` when the policy does not allow it or the service is off;
- memory when the memory stack is not installed, when the expiry job is off (the time limit would not be enforced), or with `ttlDays` above the policy maximum;
- an egress origin that is malformed, inside the tools namespace, or not matched by the policy's allowed patterns (default: none);
- instructions that contain something shaped like a secret (the ten patterns of the memory secret scan);
- a name that is reserved (every chart agent, `kb`, `kb-extract`, `memory`) or already used by an object the controller does not own;
- more definitions than `maxAgents`.

## Controller

- **Structure.** A core plus adapters (see "Standard resources, upstream tools as adapters"). Slice 1 has the `Runtime` adapter for kagent and the `ModelGateway` adapter for agentgateway; the tool profile lookup is a `Tools` adapter that reads the catalog.
- **Shape.** Go, standard library only, like the A2A gate: a small REST client for the Kubernetes API (list, watch with re-list on 410, server-side apply, status patch, delete). One replica, strategy `Recreate`, no leader election. controller-runtime was not chosen: about seven kinds in one namespace and no webhook server do not justify its memory and dependency cost. This is revisited when tenancy needs more than one namespace.
- **Loop.** Level-triggered: on a watch event or every 60 s, list the definitions, compute the desired objects, apply them with server-side apply (field manager `openagentix-control-plane`), delete owned objects that are no longer wanted. Reconciles are serialized, so only one agent at a time builds its snapshot.
- **Platform catalog.** A ConfigMap rendered by the chart from the same values that render chart agents: models, profiles and their tool names, the knowledge, notify and memory prompts and tool names, skills with digests, harness image, worker pool, snapshot location, gateway URL, RemoteMCPServer names, tools namespace, gate URL. Mounted as a file, no secret in it. A checksum annotation rolls the controller when it changes.
- **Policy.** A second ConfigMap rendered from `controlPlane.policy`, mounted as a file.
- **Outputs.** The same five objects as `templates/kagent.yaml` (ModelConfig, Harness, AgentTemplate, optional EgressPolicy, Agent), each with the labels `app.kubernetes.io/managed-by: openagentix-control-plane` and `openagentix.io/agent-definition: <name>` and an owner reference to the definition. A golden test compares the Go renderer with `helm template` for the same agent, so the two cannot drift apart unnoticed.
- **Deletion.** A finalizer removes the key hash from the gateway; owner references remove the rest.

### Virtual keys

`install.sh` creates each chart agent's key Secret, reads it back, hashes it and rewrites the whole `llm-api-keys` ConfigMap. The controller does this differently:

- The key (`vk-` plus 16 random bytes in hex) exists only in process memory and in the body of one `POST` that creates the Secret. The Secret is immutable, labelled and owned by the definition.
- The hash goes into the controller's **own** ConfigMap `llm-api-keys-control-plane` in the gateway namespace, labelled `agentgateway.dev/apikey=true` (the gateway policy selects key ConfigMaps by that label). The installer's ConfigMap is never touched, and the installer never touches this one.
- The controller never reads a Secret. Create answers 201 (write the hash), or 409 with the hash present (nothing to do), or 409 with no hash (delete its own Secret, create a new one, write the hash).
- Logs carry the agent name, the Secret name and the outcome. A test plants a canary key and asserts that it reaches no log line, status or event.

### Permissions

Namespaced Roles only. No ClusterRole, no wildcard.

- In `kagent`: `agentdefinitions` get, list, watch, update; `agentdefinitions/status` patch; the five kagent kinds get, list, watch, create, patch, delete; `secrets` **create and delete only**.
- In the gateway namespace: `configmaps` get, patch, update on the one name `llm-api-keys-control-plane`.

A ValidatingAdmissionPolicy bound to the controller's ServiceAccount (`control-plane-output-guard`) limits what even a compromised controller can write:

- Secrets it creates or deletes must be named `<something>-virtual-key` and carry its label (so it can never delete kagent's database Secrets);
- an AgentTemplate's tool server must be a profile server (never `kagent-tool-server` or `kagent-api`);
- a ModelConfig must point at the gateway with provider OpenAI;
- a Harness must use the catalog image.

A second policy (`agentdefinition-policy`, slice 2) refuses the simple violations at `kubectl apply` time. The controller checks everything again and is the authority.

Two Roles are rendered without bindings: `openagentix-agent-builder` (write `agentdefinitions`) and `openagentix-agent-viewer` (read). Operators bind them. Nobody who builds agents should get write access to kagent resources, Secrets or `pods/exec` in `kagent`.

### Governance for built agents

- **Who may call it.** Nobody, until an operator adds a gate caller rule with `agents: [kagent/<name>]`. The controller does not write gate rules.
- **Tools.** Only through a tool profile.
- **Egress.** Default none; only origins the policy allows.
- **Memory.** Only with the expiry job on; time limit capped.
- **Budget.** The gateway's per-key token budget applies, because each agent gets its own gateway user.

## Console

A Svelte single-page application, built to static files, served by a small Go service `services/console` together with a JSON API. The layout follows common agent-studio products (navigation by area on the left, a registry table, a builder with a form on one side and capabilities on the other, detail panels on the right). The name and the visual design are OpenAgentix's own.

Rules:

1. **No relay.** The console API has a fixed list of routes, each implemented explicitly. There is no generic proxy to the Kubernetes API, to the kagent controller or to any service. It never forwards `Authorization` or `X-User-Id` from the browser.
2. **Narrow identity.** The console's ServiceAccount has the viewer rights plus the builder Role (write on `agentdefinitions` only). So the most a console user can do is create a definition, and the policy and the output guard bound what that produces.
3. **Closed network.** Its NetworkPolicy admits nobody. It is reached with `kubectl port-forward`, which needs an operator's rights.
4. **Login.** A bearer token from a Secret that `install.sh` generates when absent and never prints (the pattern of `kb-admin`). The browser keeps it in memory for the session. Requests without it get 401. Strict Content-Security-Policy, no third-party requests, same-origin only.
5. **One operator identity.** Every console user acts as the console. Per-user identity (OIDC, impersonation), teams and approvals are the enterprise line.
6. **Only real data.** A page exists when the platform has the thing behind it. No page with invented numbers.

Pages. "Now" means the first console slices; "with its kind" means the page becomes editable when the kind of the table above exists, and is read-only before that.

| Area | Page | Source | Editable |
|---|---|---|---|
| Agents | Registry | `AgentDefinition` plus chart agents | - |
| Agents | Builder: instructions, model, capabilities, YAML view, status | `AgentDefinition`, catalog, policy | now |
| Agents | Playground | A2A gate, as caller `console` with user id `console:<session>` | now (sends a message) |
| Models | Providers, models, routing, budgets, usage per agent | gateway resources, metrics | with `ModelProvider`, `ModelRoute` |
| Tools | MCP servers, tools of each, tool profiles | ToolHive resources | with `ToolServer`, `ToolProfile` |
| Skills | Registry: skills, versions, users, `SKILL.md` | `Skill`, registry | with `Skill` |
| Knowledge | Collections, documents, sources and connectors, graph statistics and search, fact sets | kb service | with `KnowledgeCollection`, `KnowledgeSource` |
| Channels | Connections, triggers, the Telegram bridge | Kourier resources | with `Channel`, `Trigger` |
| Schedules | Schedules, last runs | CronJobs | with `Schedule` |
| Memory | Which agents remember, expiry job and its last run | catalog, CronJob | settings with `AgentDefinition`; a user's memories are never listed here |
| Governance | Gate callers, egress per agent, platform policy | ConfigMaps | policy stays operator-owned (values or Git), shown read-only |
| Traces | Recent turns, cost | Jaeger, VictoriaMetrics | - |

**Stack.** Svelte 5 (runes) with SvelteKit and the static adapter (a single-page application, fallback `index.html`), Vite, TypeScript in strict mode, Tailwind 4 with design tokens in `@theme` and a `.dark` class for the dark theme, pnpm, Vitest with Testing Library for components, Playwright for one end-to-end path. No component kit at the start; a small set of own components (button, field, switch, table, panel, tabs). The built files are embedded in the `services/console` Go binary, so the console is one image with no Node at run time.

Not built, because the platform has nothing behind them yet: voice, a semantic data model, a simulation or improvement engine, third-party guardrail providers, compliance frameworks, PII redaction, blueprints.

## Slices

1. **Control plane core.** CRD, controller, catalog and policy ConfigMaps, the controller's gateway key ConfigMap, Roles, the output guard, Deployment, NetworkPolicy, installer and uninstaller support. Proof on kind: a definition becomes a Ready agent that answers through the gate under its own gateway user; a definition with a tool outside its profile is refused without a model call; the key registration survives `helm upgrade` and a second installer run; delete removes everything; the output guard refuses a Secret delete outside the controller's own.
2. **Admission policy and roles.** `agentdefinition-policy`, builder and viewer Roles, demo values, README section.
3. **Console API and shell.** `services/console` (routes, login, hardening), the Svelte application shell, the agents registry and the builder.
4. **Console pages.** Playground, then the read-only pages of the table above, in the order tools, models, skills, knowledge, channels and schedules, memory, governance, traces.
5. **The other kinds**, one slice each with its own decision record, in the order of the table in "Scope": `Schedule` (with the gate rule reload), `Channel` and `Trigger`, `ModelProvider` and `ModelRoute`, `ToolServer` and `ToolProfile`, `KnowledgeCollection` and `KnowledgeSource`, `Skill` and the registry. Each makes its console page editable.

Each slice: tests first, chart render assertions (default render unchanged), Go unit tests with `-race`, one live proof, review, diary entry.

## Out of scope

- Migrating chart `agents[]` to definitions.
- In slices 1 to 4: schedules, Kourier bindings and the Telegram bridge pointing at built agents (they still validate against `agents[]`), and the controller writing gate rules. Both come with slice 5.
- More than one namespace, a team policy kind, per-user identity in the console, approval workflows beyond skill approval, version history, key rotation on demand, harness or image overrides.
- A command-line tool `oa`. `kubectl` and the console cover the first use; it can follow.

## Open points, with the chosen default

| Point | Default |
|---|---|
| The gateway reading more than one labelled key ConfigMap is not yet proven | Prove in slice 1. If it fails, the controller patches single keys of `llm-api-keys` and the installer stops rewriting the whole object |
| `helm upgrade` or the installer's apply might wipe the controller's ConfigMap data | The chart renders it without `data`; proof in slice 1. Fallback: the controller creates it itself |
| kagent accepting owner references to a foreign kind, and clean garbage collection | Prove in slice 1. Fallback: delete by label in the finalizer |
| Snapshot CPU on the 6 CPU / 8 GB node | `maxAgents: 5`, serialized reconciles |
| Disabling the switch must not delete agents | CRD kept on uninstall of the switch; the uninstaller deletes definitions first, on purpose |
| Open core | Open: CRD, controller, policy, console as described. Enterprise later: team policy and tenancy, single sign-on and per-user writes, approvals, audit history, key rotation, as new kinds, without changing `AgentDefinition` fields |
