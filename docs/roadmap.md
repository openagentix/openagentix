# Roadmap

Written 2026-11-25. It replaces nothing: the changelog says what exists, the diary how it was proven. This page says what is planned and why, measured against the managed agent platforms that OpenAgentix wants to be an alternative to.

## Goal: adoption

Set by the project owner on 2026-11-25: the first goal is the widest possible adoption. Work is ordered by what brings users, contributors and named adopters, not by feature count.

What that means for every decision:

1. **Time to first working agent** matters most: an install that works in minutes on the clusters people have (kind, k3s, GKE, EKS, AKS, OpenShift), with or without a paid model key.
2. **A reason to try it today**: one clear use that it does better than the alternatives, shown in a demo anyone can run.
3. **Meet people where they are**: adapters for the frameworks and runtimes they already use, so their agents run here without a rewrite.
4. **Easy to contribute to**: small, well-marked places to add an adapter, a connector or a tool server, with tests that tell a contributor it works.
5. **Proof over promise**: every claim in the README is something a visitor can reproduce.
6. **Less, finished** beats more, half-built. A feature that does not serve adoption waits.

Measured by: installs that reach a working agent, people outside the project who open issues and pull requests, organisations that agree to be named, agents and adapters contributed by others. Stars are a weak signal.

## Aim

A Kubernetes-native agent platform that an organisation can run on its own clusters instead of Amazon Bedrock AgentCore, Microsoft Foundry Agent Service or Google's Gemini Enterprise Agent Platform (the former Vertex AI Agent Builder and Agent Engine).

## Where we stand

The comparison below was made from the vendors' public documentation on 2026-11-25. Those products change every month, so check the vendor pages before quoting any line. "Built" means the repository shows it working on a cluster; see `docs/diary/what-works.md`.

| Area | The managed platforms offer | OpenAgentix today |
|---|---|---|
| Runtime | hosted agents, an isolated sandbox per session, long-running sessions, many frameworks, your own container | **built**: kagent on Agent Substrate (gVisor, per-session identity); your own A2A 1.0 container, proven in CI on kind only (ADR 0015). **Missing**: long-running and resumable runs, a registry pull and private registries for your own container, other frameworks checked |
| Identity | an identity per agent, inbound authentication, a credential vault, acting on behalf of a user with OAuth | **partly**: per-session identity, tool-layer tokens, the A2A gate. **Missing**: credential vault, on-behalf-of-user |
| Tools | an MCP gateway, OpenAPI as tools, tool search, per-agent filtering, registries | **built**: MCP gateway, tool profiles, tool access rules. **Missing**: OpenAPI as tools, a registry |
| Built-in tools | code interpreter, browser, computer use, file search | **built**: knowledge search. **Missing**: code interpreter, browser |
| Memory and knowledge | short and long-term memory, retrieval, connectors | **built**: long-term memory with expiry, knowledge base, knowledge graph (the managed platforms list no graph). **Missing**: connectors to outside sources |
| Multi-agent | A2A, workflows | **built**: A2A through the gate. **Missing**: workflows |
| Builder | a no-code or low-code studio, a command-line tool, resources as code | **in progress**: ADR 0007 |
| Models | a catalog, routing, failover | **built**: gateway, keys, failover, prompt caching. **Planned**: routing by rules and by a router (ADR 0008) |
| Quality | evaluation, simulation, red teaming, prompt optimisation | **missing** |
| Safety | content safety, prompt-attack detection, PII handling, egress control, human approval, deterministic tool policy | **built**: egress allowlists, tool policy. **Missing**: content guardrails, PII. **Approvals**: in the system of record that owns the act (ADR 0028); the platform does not hold tool calls |
| Observability and cost | traces, metrics, cost, budgets, alerts | **built**: traces, cost and tokens per agent, token budgets. **Planned**: FinOps and budgets (ADR 0009) |
| Lifecycle | versions, environments, pinned endpoints | **missing** |
| Channels | chat products, schedules | **built**: Telegram, signed webhooks, schedules. **Untested**: Slack |
| Platform | tenancy, private networking, compliance attestations | **built**: network policies, one-command install. **Missing**: tenancy, more than one cluster. No attestations |

Short version: the plumbing works (runtime, gateways, tools, memory, knowledge, observability, egress control). What a buyer sees first does not exist yet: a builder, evaluation, guardrails, approvals, versions, teams. Everything proven so far ran on one kind node, or in CI on hosted runners (kind and k3s, one node each). Nothing ran on a managed cloud or OpenShift.

## Where this approach can be better, and where it cannot

Better, with the limit of each:

- **Data stays in your cluster.** Memory, knowledge, graph and traces are in your own databases. Model calls still leave unless you host the models.
- **Any model and provider** behind one gateway. You carry the keys and the rate limits.
- **No fee per session or per call.** The cost is your nodes, including idle ones.
- **GitOps.** Agents and their configuration are resources in Git, reviewed like code (after ADR 0007).
- **Canary releases** with standard Kubernetes traffic weights. Not built yet.
- **Portable**: any cloud, on-premises, and in principle air-gapped. Air-gap is not proven.
- **Cost you can read**: the gateway log and the node bill.

Not better:

- **Operations are yours.** Sizing, upgrades and scaling are the customer's work.
- **No scaling to zero per session** as a managed service gives it.
- **Connectors.** The managed platforms come with many business-system connectors. We have two channels.
- **No compliance attestations.** Self-hosting moves the audit to the customer.
- **Isolation is comparable, not stronger.** gVisor against micro virtual machines.
- **Open standards are parity, not a lead.** The managed platforms speak MCP, A2A and OpenTelemetry too, and they are starting to govern agents that run on other clusters.

## Principles

1. Every configurable thing is a resource in `openagentix.io`. The console, `kubectl` and Git write the same resources (ADR 0007).
2. Upstream tools sit behind adapters, so one can be exchanged. Adopt an existing open-source project before building.
3. Off by default, deny by default, no content capture by default.
4. Nothing counts as done until it is proven on a cluster and the limits are written down.

## Releases

> **Current plan: [ADR 0013](decisions/0013-focus-and-runtime-neutrality.md)** (2026-11-25). One focus, governed agent runs for platform teams; bring your own A2A agent in 0.3; identity adopted in 0.4. The table below is the earlier, wider plan; items not in ADR 0013 are postponed to the Backlog.

Each release is a [milestone](https://github.com/openagentix/openagentix/milestones) with a tracking issue, and the issues are the backlog: [0.3 Control plane and console](https://github.com/openagentix/openagentix/milestone/1), [0.4 Runs and trust](https://github.com/openagentix/openagentix/milestone/2), [0.5 Work](https://github.com/openagentix/openagentix/milestone/3), [0.6 Lifecycle and quality](https://github.com/openagentix/openagentix/milestone/4), [Backlog](https://github.com/openagentix/openagentix/milestone/5). Where the table below and the "Roadmap change" table of [ADR 0012](decisions/0012-platform-primitives-for-agentic-delivery.md) differ, ADR 0012 wins; the milestones follow it. How the work is run: [docs/contributing/workflow.md](contributing/workflow.md).

Sizes are relative. Each release has its own decision records before code.

| Release | Theme | Adds | Depends on |
|---|---|---|---|
| **0.3** | **Control plane and console** | `AgentDefinition`, the controller, platform policy, the web console with the agent builder and playground; then the other kinds: `Schedule`, `Channel` and `Trigger`, `ModelProvider` and `ModelRoute` (static and rules), `ToolServer` and `ToolProfile`, `KnowledgeCollection` and `KnowledgeSource`, `Skill` with the organisation registry, `ObservabilitySettings`, `Budget`, costs and traces pages | ADR 0007, 0008, 0009 |
| **0.4** | **Trust** | an identity per agent, a credential store for outbound access and acting on behalf of a user, guardrails (prompt attacks, content, PII) at the model and tool gateways, a convention for approvals in the system of record (ADR 0028; no platform hold on tool calls), console login with OpenID Connect | platform policy, gate rule reload |
| **0.5** | **Lifecycle** | immutable agent versions, environments, canary releases, registries for agents, tools and MCP servers, agent blueprints | stable `AgentDefinition`, skill registry |
| **0.6** | **Quality** | datasets, evaluation suites and runs, simulation, red-team runs, a release gate on evaluation results, the model router service with measured savings | versions, traces |
| **0.7** | **Teams** | tenants, quotas, budgets in money per team, showback, more than one namespace | identity and login |
| **0.8** | **Do more** | code interpreter and browser as sandboxed tool servers, OpenAPI as tools, durable multi-agent workflows, your own container and other agent frameworks behind an admission policy | credentials, approvals |
| **0.9** | **Fleet and developers** | several clusters, a command-line tool, SDKs, an air-gap bundle | versions, tenancy |

Candidates to adopt behind adapters (licences as read on 2026-11-25; check again before bundling): SPIFFE/SPIRE and Keycloak for identity, OpenBao with External Secrets for credentials, Presidio and NeMo Guardrails for safety, Argo Rollouts or Flagger for canary, promptfoo, DeepEval and Inspect for evaluation, garak and PyRIT for red teaming, Capsule or vCluster and Kueue for tenancy, OpenCost for cluster cost, `kubernetes-sigs/agent-sandbox` for code execution, Playwright MCP for the browser, Argo Workflows or Temporal for workflows, Karmada or Open Cluster Management for fleets. A broker for on-behalf-of-user OAuth with a consent step has no mature open-source project that we could confirm; expect to build a small one.

## After v1: a software factory on top (idea, not planned work)

Raised by the project owner on 2026-11-25: once v1 is done, support building a Kubernetes-native software factory, meaning agents that take a work item through plan, code, test, review and release, each step in a sandbox, governed and auditable.

Scope named by the owner: a software factory including the "dark factory" case (work runs unattended, people set goals and approve at gates), an agentic software development life cycle (requirements, design, code, test, review, release, operations), and agentic CI/CD (agents as pipeline steps, and pipelines that agents drive), "and more".

Working position, to be decided with its own decision record when v1 is done:

- **A separate project on top of OpenAgentix, not part of this repository.** Foundation reviewers have declined proposals for having too much in one repository. OpenAgentix stays the neutral platform; the factory is the first serious application built on it, with its own resource kinds (for example repository, work item, pipeline, review gate) in its own API group.
- **Shown inside the console through the plugin registry** that ADR 0010 already plans, so users see one product while the projects stay separate.
- **It sets priorities for the platform.** A factory needs things the roadmap has in later releases: durable workflows, a code sandbox, credentials for Git and registries, human approval, evaluation, long-running tasks. If the factory is the goal, those move earlier.
- **It is the adoption story.** The strongest evidence for a platform is a demanding application running on it, ideally building the platform itself.

Open: how it differs from existing coding agents and agent runners (to be researched then), and whether it is open, commercial, or both.

## Community and enterprise

Decided in [ADR 0010](decisions/0010-community-and-enterprise-editions.md). The rule: what one team needs to build, run and govern agents safely on one cluster is community; what an organisation needs because it has many teams, auditors, several clusters and a support contract is enterprise. Security is never an enterprise feature, the community edition has no limits by count, and nothing moves from community to enterprise later.
