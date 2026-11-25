---
title: FAQ
sidebar_position: 4
description: Short, honest answers to the questions platform engineers ask first about OpenAgentix.
---

# FAQ

## Do I need a specific agent framework?

Today, yes, in one sense. Agents run on kagent with Agent Substrate. You do not write framework code: you describe the agent (model, instructions, tool profile, tools) in an `AgentDefinition` or in the chart values, and the platform builds it. Bringing an agent built with another framework, as a container that speaks A2A, is planned for release 0.3 ([ADR 0013](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0013-focus-and-runtime-neutrality.md)).

The callers do not need any framework. Anything that can send an A2A request over HTTP can call an agent through the A2A gate. `hack/ask.sh` is a short shell script that does it with `curl`.

## Which models can I use?

Every model call goes through the model gateway (agentgateway). The quick start installer picks the model in this order:

- a key in the environment: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `GOOGLE_API_KEY`;
- any OpenAI-compatible endpoint: `MODEL_BASE_URL`, `MODEL_NAME`, and `MODEL_API_KEY` if it needs one;
- a local Ollama when you ask for it: `MODEL_PROVIDER=ollama MODEL_NAME=llama3.2`;
- otherwise a built-in stub. The stub is a scripted stand-in for trying the platform's controls, not a language model.

What is proven: Anthropic models, many times. The stub, in CI. Not yet proven: the OpenAI and Gemini paths (their default model names are not verified; set `MODEL_NAME`), and the Ollama path. A Gemini key in this project never produced a completion because the test key had no credits. See [Quick start](../features/quick-start.md) and [Model gateway](../features/model-gateway.md).

## Does data leave my cluster?

Some does, and you choose where it goes:

- **Prompts, answers and tool results** go to the model provider you configure. With the stub nothing goes out. With a local model it stays on your machine.
- **Tool servers** reach the outside services they wrap. For example, the OSV tool asks the public OSV vulnerability database.
- **Embeddings** for the knowledge base and memory are made in the cluster. Nothing leaves for them. The embedding model is downloaded from Hugging Face on the first start.
- **The knowledge graph** (off by default) sends the text of every ingested document to the extraction model.
- **Notifications** (off by default) post to the Telegram or Slack destinations you list.
- **Telemetry** stays in the cluster with the bundled VictoriaMetrics and Jaeger. Content capture is off by default. Some tool arguments reach trace spans anyway; the bundled Jaeger deletes them before storage. For your own trace endpoint, read [Observability](../features/observability.md) first.

The install itself pulls container images and the `kubectl-ate` plugin from public sources.

## What runs in my cluster, and how heavy is it?

The quick start installs: kagent and Agent Substrate (the runtime, with gVisor sandboxes), agentgateway (the model gateway), ToolHive with one tool server and one tool profile, the control plane, the console, the A2A gate, VictoriaMetrics and Jaeger. Upstream versions are pinned (kagent and Substrate 1.0.1, agentgateway v1.7.0, ToolHive 0.67.1).

Measured in CI on a hosted runner with 4 vCPU and about 16 GB: the install took 6 min 34 s from nothing, and the node used about 2.4 GiB of memory afterwards. On your machine, give Docker 4 CPU and 8 GB or more. The full demo, with every optional part, was run on a 6 CPU and 8 GB VM. Kubernetes 1.37 or newer is needed (the installer creates a kind cluster with it).

## Is it production ready?

No. It is an early project with one maintainer. It was proven on one single-node kind cluster, and the quick start in CI on a hosted runner. It was not tested on k3s, a managed cloud, OpenShift, several nodes, or under load. Databases are development setups, most services run one replica, and there are no backups. Read [what works](../what-works.md) and the "Known limitations" section of the README before you point anything real at it.

## How is this different from running an agent as a plain Deployment?

With a plain Deployment, the platform team has to build each of these by hand, for each team:

- The agent holds no provider key. It gets its own gateway key, with a token budget and cost per agent.
- The agent sees only the tools in its approved profile.
- The agent's sandbox reaches only what its model and tools need, plus hosts you list.
- Callers must prove who they are at the A2A gate, and each request is written to an audit line.
- Each conversation runs in its own gVisor sandbox.
- A platform policy checks every `AgentDefinition` before anything is created, and refuses one that breaks a rule, with the reason in its status.
- Traces and metrics per agent turn, without capturing content by default.

## What is the licence, and who controls the project?

The code is Apache-2.0. The [governance rules](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md) say how decisions are made and keep the project vendor-neutral: the roadmap is decided in the open, no feature may depend on a commercial product, and security is never held back. Today there is one maintainer, and the project is looking for maintainers from other organisations. Upstream components and their licences are listed in [THIRD-PARTY.md](https://github.com/openagentix/openagentix/blob/main/THIRD-PARTY.md).

## How can I contribute?

Read [CONTRIBUTING.md](https://github.com/openagentix/openagentix/blob/main/CONTRIBUTING.md). Good places to start: documentation, tests, an adapter for another observability stack, vector store or notification target, and testing the Slack path if you have a workspace. Every commit is signed off (`git commit -s`). You do not need a cluster or a model key to contribute code, tests or docs. Questions are welcome in GitHub Discussions.
