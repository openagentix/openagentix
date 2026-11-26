---
title: Built with
sidebar_position: 2.5
description: The open-source projects and standards OpenAgentix runs on, what it uses each one for, and the version it pins.
---

# Built with

OpenAgentix is built with the open-source projects and open standards below. It is not made by, and not endorsed by, any of them. They keep their own licences. OpenAgentix installs them and puts a policy and a control plane in front; it does not copy their code. [ADR 0013](/decisions/focus-and-runtime-neutrality) explains why runtimes stay replaceable behind adapters.

Versions are the ones pinned in this repository on 2026-11-25. The full list with licences and how each was checked is in [THIRD-PARTY.md](https://github.com/openagentix/openagentix/blob/main/THIRD-PARTY.md).

## Runtime and sandbox

| Project | Version | What OpenAgentix uses it for |
|---|---|---|
| [Agent Substrate](https://github.com/kagent-dev/substrate) | 1.0.1 | Runs each agent session in a gVisor sandbox with its own identity, takes snapshots of agent state, and denies outbound network access unless a rule allows it. |
| [kagent](https://github.com/kagent-dev/kagent) | 1.0.1 | The agent runtime and controller. It answers A2A requests and talks to models and tools. |

## Model and tool gateways

| Project | Version | What OpenAgentix uses it for |
|---|---|---|
| [agentgateway](https://github.com/agentgateway/agentgateway) | v1.7.0 | The model gateway: a virtual key and a token budget per agent, prompt caching, failover between models, and the access log that cost is counted from. |
| [Model Context Protocol (MCP)](https://modelcontextprotocol.io) | open standard, hosted by the Agentic AI Foundation (Linux Foundation) | How agents call tools. |
| [ToolHive](https://github.com/stacklok/toolhive) (virtual MCP server) | 0.67.1 | Serves tools to agents and builds tool profiles, so an agent sees only the tools approved for it. |
| [Agent2Agent (A2A) protocol](https://a2a-protocol.org) | open standard, a Linux Foundation project; 1.0 | How callers, the gate, schedules, channels and your own container agents talk to agents. |

## Triggers

| Project | Version | What OpenAgentix uses it for |
|---|---|---|
| [Agent Kourier](https://github.com/agentkourier/agent-kourier) | 0.6.0 | Receives signed webhooks and chat events and turns them into agent calls. |

## Telemetry

| Project | Version | What OpenAgentix uses it for |
|---|---|---|
| [OpenTelemetry](https://opentelemetry.io) | open standard | Metrics and traces across the gateway, tools and agents. |
| [VictoriaMetrics](https://github.com/VictoriaMetrics/VictoriaMetrics) | v1.156.0 | Stores metrics, for example cost per agent. |
| [Jaeger](https://github.com/jaegertracing/jaeger) | 2.23.0 | Stores and shows traces. |

## Kubernetes features and data stores

| Project | Version | What OpenAgentix uses it for |
|---|---|---|
| [Kubernetes ValidatingAdmissionPolicy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) with CEL | Kubernetes API | Rules that stop other actors from changing what the control plane owns. |
| [Gateway API](https://gateway-api.sigs.k8s.io) | 1.6.3 | The route and gateway resources the model gateway is configured with. |
| [PostgreSQL](https://www.postgresql.org) with [pgvector](https://github.com/pgvector/pgvector) | 17 | Storage for the knowledge base and for memory, with vector search. |
| [kind](https://kind.sigs.k8s.io) | 0.33 or newer | The local cluster the quick start creates. |

## Not shown here

The console and the control plane are OpenAgentix's own code. The model providers you connect, and the tool servers you add, are your choice and are not part of this list.
