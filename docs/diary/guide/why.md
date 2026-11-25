---
title: Why OpenAgentix
sidebar_position: 1
description: The problems a platform team meets when developers start to run AI agents, and how OpenAgentix answers each one, with links to the proof.
---

# Why OpenAgentix

Developers in your organisation start to run AI agents. At first each team does it its own way. After some weeks, the platform team sees the same problems again and again. This page lists them and says how OpenAgentix answers each one today. Every answer links to the record of how it was proven. Where something is not built yet, the page says so.

OpenAgentix is an early project. Everything here was proven on one single-node kind cluster, and the quick start also in CI on a hosted runner. Read [what works](../what-works.md) for the full status.

## 1. Provider keys sit in every agent pod

**The problem.** Each agent needs a model, so each team puts a provider API key in a Secret next to its agent. Keys spread, and you cannot tell which agent used which key.

**The answer.** Agents never hold a provider key. Each agent gets its own virtual key for the model gateway, and only the gateway holds the provider key. A call without a valid key gets HTTP 401.

**Proof.** [Model gateway](../features/model-gateway.md): real completions through the gateway, 401 without a key.

**Not yet.** Virtual keys are static (no rotation or expiry). One provider key is shared by all agents behind the gateway.

## 2. Nobody knows what each agent costs

**The problem.** The model bill arrives as one number. You cannot say which team or which agent spent it, and one agent in a loop can spend a lot before anyone sees it.

**The answer.** The gateway counts tokens and cost per virtual key, so per agent. Each key has a token budget; when it is used up, the gateway answers 429. With observability on, you can query tokens and cost per agent in the bundled metrics store. The console has spend pages that read the same store; they are built and tested, but not yet checked against a live cluster.

**Proof.** [Observability](../features/observability.md): the cost metric matched the gateway's access log for ten calls. [What works](../what-works.md): 429 when the budget ran out.

**Not yet.** Budgets are in tokens, not money, and are counted per gateway replica. Budgets per run are planned for 0.5.

## 3. Tools and the network are wide open

**The problem.** An agent with a shell or a generic fetch tool can call any tool and reach any host. A prompt hidden in a web page or a document can make it do so.

**The answer.** A tool profile gives an agent only the tools you approved; other tools are not found, even from code the agent runs. Each agent sandbox can reach only what its model and tools need, plus hosts you list for it. Everything else is refused.

**Proof.** [Security](../features/security.md), section "Tool profiles and egress per agent": a profile advertised only its tools, hidden tools were not found directly or in code mode, an allowed host answered and other hosts were refused.

**Not yet.** Tool servers themselves (for example `fetch`) run as normal pods; their internet access depends on your network plugin. The default kind network plugin does not enforce egress to the internet. Egress rules match host and port, not paths.

## 4. No record of who called which agent

**The problem.** Anything that can reach an agent's port can call it and claim to be any user. There is no record of who asked what.

**The answer.** The A2A gate stands in front of the agents. Each caller proves who it is with a Kubernetes ServiceAccount token or a key. A caller rule says which agents it may call and which user ids it may use. The gate writes one audit line per request, and the tool gateway writes one per tool call.

**Proof.** [Security](../features/security.md): no token gave 401, a caller claiming another caller's user id gave 403, schedule and webhook calls completed through the gate. [Observability](../features/observability.md): tool audit lines.

**Not yet.** The audit lines are pod logs, not a tamper-evident store. The gate runs as one replica. Identity per agent and human approval are planned for 0.4.

## 5. Every team wires its own stack

**The problem.** Each team picks a framework, a gateway, a tool runner and a way to log. The platform team cannot support ten different stacks, and cannot set one rule for all of them.

**The answer.** One install gives every team the same runtime, gateways, telemetry and console. A team describes its agent in a short `AgentDefinition`. The control plane checks it against the platform policy; a definition that breaks a rule is refused with a reason, and nothing is created. The definition is a plain Kubernetes resource, so it can live in Git with the rest of your manifests.

**Proof.** [Control plane](../features/control-plane.md): a definition became a Ready agent in 13 to 31 s, a refused definition created nothing, delete removed everything. The quick start does the same in CI ([Quick start](../features/quick-start.md)).

**Not yet.** Today the runtime is kagent on Agent Substrate. Bringing an agent built with another framework, as a container that speaks A2A, is planned for 0.3. Only one namespace was tested.

## Built from open parts

OpenAgentix does not replace the open-source projects it uses. It puts them behind adapters and adds the policy, the keys, the gate and the console. It uses open standards: MCP for tools, A2A for calling agents, OpenTelemetry for traces and metrics. The code is Apache-2.0, and the [governance rules](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md) keep the project vendor-neutral.

Next: [Concepts](./concepts.md), [Use cases](./use-cases.md), [FAQ](./faq.md).
