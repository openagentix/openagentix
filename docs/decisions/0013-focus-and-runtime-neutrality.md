# ADR 0013: one focus, bring your own agent, adopted identity

Status: Accepted (2026-11-25). Decided by the project owner. It changes the order of work in ADR 0007 and ADR 0012; their designs stay valid.

## Context

The first goal of the project is adoption (`docs/roadmap.md`). A review of the plan against that goal found three problems:

- The roadmap had about twenty resource kinds over nine releases, too much for one maintainer to finish and prove.
- Agents could only be kagent agents. People who already have agents built with another framework could not bring them, and a project tied to one runtime is hard to call neutral (ADR 0011).
- The platform has no identity per agent and cannot act on behalf of a user. Other projects already do this with existing open-source parts.

## Decision

1. **One focus: governed agent runs for platform teams.** Any agent that speaks A2A, with tools, outbound access and budget denied by default, human approval, an audit record, and an install that works in minutes on kind, k3s, a managed cloud and OpenShift.
2. **Bring your own agent moves to release 0.3.** An `AgentDefinition` can describe an agent that is not built by the platform: a container that speaks A2A, built with any framework. The same policy, tool profile, egress rules, gateway key and status contract apply. kagent on Agent Substrate stays the default runtime. This is the plain A2A runtime adapter that ADR 0012 planned for 0.6, brought forward; the conformance suite follows it.
3. **Identity is adopted, not built.** Identity per agent and token exchange (a tool call that carries both the user and the agent) use existing open-source projects behind an `Identity` adapter: SPIFFE/SPIRE for workload identity and an RFC 8693 token exchange such as Keycloak's. A design record comes first; it stays in release 0.4.

## What is postponed

These stay as issues in the Backlog milestone and come back when users or contributors ask for them:

- Editing models, tools, knowledge sources and skills from the console (the resource kinds `ModelProvider`, `ModelRoute`, `ToolServer`, `ToolProfile`, `KnowledgeCollection`, `KnowledgeSource`, `Skill`, `ObservabilitySettings`, `NotifyDestination`). The console shows these areas read-only or as not available.
- The organisation skill registry.
- The model router service (rules and a learned router). Static routing and fallback stay.
- New knowledge-graph work beyond maintenance.
- The Microsoft Teams channel (it needs a new connector), the AX adapter.
- Fleet, air-gap, tenancy beyond one namespace.
- Products on top (software factory, agentic delivery) until runs and approvals exist.

## Channels

Changed on 2026-11-25 by the project owner: Telegram is useful for a demo and for one person, but most organisations use Slack or Microsoft Teams. So:

- The quick start has no chat channel at all. A first message goes through the console or a command.
- **Slack is the first channel for organisations.** The Slack path through Agent Kourier exists in the chart but has never been run against a real workspace; proving it moves to release 0.4.
- Telegram stays as an optional bridge for demos and personal use.
- Microsoft Teams is wanted and is not built: it needs its own connector and stays in the Backlog until Slack is proven.

## Release plan

| Release | Content |
|---|---|
| 0.3 | Control plane and console proven on a cluster. Bring your own A2A agent. A quick start that needs no paid model key and no chat token. A small, fast install profile. Install tested on kind and k3s in CI, then a managed cloud, with OpenShift-compatible manifests. `AgentAccess`, `Schedule`. |
| 0.4 | Slack channel proven on a real workspace. `AgentRun`, `ApprovalRequest`, identity per agent and token exchange (adopted), `CredentialGrant`, event sink, console login with OpenID Connect. Runtime conformance suite. |
| 0.5 | `Workspace`, long steps, budgets per run, queueing, delegation. |
| Later | The postponed list, by demand. |

## Consequences

- An agent that is not a kagent agent does not get what Agent Substrate gives (a sandbox per session, an identity per session, snapshots). The runtime adapter reports its capabilities in `status.capabilities`, and policy can refuse such agents for sensitive work.
- The platform's own value must be clear without any one runtime: policy, gateway keys and budgets, tool profiles, egress rules, runs, approvals, audit.
- Less is promised. What is promised is proven on more than one kind of cluster.
