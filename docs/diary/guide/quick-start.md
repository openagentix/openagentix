---
title: Quick start
sidebar_position: 3
description: Install OpenAgentix on a local kind cluster with one command, with no paid model key and no chat token, and ask a governed agent a question.
---

# Quick start

This page gets you from nothing to a governed agent on your own machine. It needs no paid model key and no chat token. A scripted stub model answers until you give it a real one.

## What you need

`docker`, `kind`, `kubectl`, `helm`, `jq`, the Python `yq`, `openssl`, `curl` and `python3`. Docker should have 4 CPU and 8 GB.

## Install

```sh
git clone https://github.com/openagentix/openagentix && cd openagentix
PROFILE=quickstart ./install.sh
```

The install ends with a summary: how long it took, which model is active, and the commands to ask the agent and open the console. In CI on a hosted runner, with nothing cached, it took 366 to 394 seconds. A laptop was not timed.

## Ask the agent

```sh
hack/ask.sh quickstart "Look up known vulnerabilities of lodash 4.17.20 (npm)"
```

The question goes through the A2A gate, which checks the caller. The agent calls one tool, the OSV lookup, through its tool profile. It prints the answer and how long it took.

With the stub, the answer says it comes from the stub. The stub is a script, not a language model: it answers two kinds of prompt and nothing else. Use it to see the controls, not to get answers.

## Use a real model

Run the install again with a key or an OpenAI-compatible endpoint:

```sh
ANTHROPIC_API_KEY=sk-ant-... PROFILE=quickstart ./install.sh
```

`OPENAI_API_KEY` and `GOOGLE_API_KEY` work the same way. For an endpoint, set `MODEL_BASE_URL`, `MODEL_NAME` and, if needed, `MODEL_API_KEY`. A local Ollama path exists (`MODEL_PROVIDER=ollama`) but has not been run yet.

## Open the console

```sh
kubectl port-forward -n openagentix-system svc/openagentix-console 8080:8080
```

Then open `http://127.0.0.1:8080`. The sign-in token is in the Secret `openagentix-system/console-token`; the installer prints the command to read it.

## Remove everything

```sh
kind delete cluster --name openagentix
```

## What you got

kagent and Agent Substrate for sandboxed agents, the model gateway with a virtual key and token budget per agent, the tool gateway with one tool server and one tool profile, the control plane, the console, the A2A gate, and a metrics store and Jaeger. The agent `quickstart` is built from an `AgentDefinition`. The Telegram bridge, channels, schedules, notify, the knowledge base and memory are off.

## Where to go next

- [How the quick start is built and measured](../features/quick-start.md)
- [What works](../what-works.md), to see what is proven and what is not
- [Concepts](./concepts.md), for the words used here
