---
title: Demo walkthrough
sidebar_position: 3.2
description: A scripted walk through the quick start in about ten minutes. Create an agent, ask it, see its gateway key and budget, read the audit line, hit a denied call, and open the console. No paid key.
---

# Demo walkthrough

This page shows what OpenAgentix does on the [quick start](./quick-start.md), step by step. One script, `hack/demo.sh`, runs every step and says what to look for. It needs no paid model key and no chat token. The stub model answers.

## Before you start

Install the quick start and keep the cluster:

```sh
PROFILE=quickstart ./install.sh
```

You need `kubectl` (pointing at that cluster), `jq`, `curl` and `python3`. The install takes about six minutes on a hosted CI runner (see [how it was measured](../features/quick-start.md)).

## Run it

```sh
hack/demo.sh
```

It is safe to run again. It applies a definition called `demo-lookup` and removes it at the end. `DEMO_KEEP=1 hack/demo.sh` keeps it, so you can look at it in the console.

## The six steps

### 1. Create an AgentDefinition

The script applies a short `AgentDefinition`: a model alias, a tool profile, one tool and some instructions. It does not say which model server, which key or which pod to use. The control plane checks the definition against the platform policy and builds the agent.

Look for: `AgentDefinition demo-lookup is Ready`, and the conditions `Accepted`, `KeyReady` and `Ready` all `True`.

### 2. See the gateway key and the budget

Every agent gets its own key for the model gateway. The script shows that the gateway knows the user `kagent.demo-lookup`, and the token budget that the gateway sets for each key.

Look for: the key entry is present, and a line such as `100000 tokens per Hours`. The script never prints a key or its hash. A key that goes over its budget gets HTTP 429.

### 3. Ask the agent

The script asks the agent `quickstart` about a vulnerable package, through the A2A gate (`hack/ask.sh`). The gate checks who is calling before the question reaches the agent.

Look for: an answer that names the tool `osv_query_vulnerability`. With the stub model the answer says it comes from the stub. The stub is a script, not a language model.

### 4. Read the audit line

The gate writes one JSON line for each call.

Look for: the agent, `status` 200, `rpc` `SendMessage`, a hashed `user_id` that starts with `h:`, and a duration. There is no message text in it.

### 5. Hit a denied call

The caller that `hack/ask.sh` uses may ask `quickstart` and nothing else. The script asks `demo-lookup`, which the gate must refuse. It also asks the agent to fetch a web page: the tool profile has no fetch tool, so no page comes back (stub model only).

Look for: the call fails, and a second audit line with `status` 403 and a `reason`.

### 6. Open the console

The script checks that the console API answers 401 without the token and lists the agent with it. It prints the command to open the console:

```sh
kubectl port-forward -n openagentix-system svc/openagentix-console 8080:8080
```

Then open `http://127.0.0.1:8080`. The sign-in token is in the Secret `openagentix-system/console-token`; the script prints the command to read it and never prints the token.

## Settings

| Variable | Default | What it does |
|---|---|---|
| `KUBECTL` | `kubectl` | the command to use, for example `kubectl --context kind-openagentix` |
| `DEMO_NAMESPACE` | `kagent` | the namespace of the definitions |
| `DEMO_WAIT` | `300` | seconds to wait for the agent to be Ready |
| `DEMO_AUDIT_WAIT` | `30` | seconds to wait for an audit line (it is written when the call ends) |
| `DEMO_KEEP` | `0` | `1` keeps `demo-lookup` |

## What this shows and what it does not

It shows the controls on a single-node quick start with the stub model: a definition is checked by policy, an agent has its own gateway key and a token budget, a caller is checked by the gate, every call leaves an audit line without content, and a call outside the rule is refused.

It does not show a real model. It does not show channels, schedules, the knowledge base or memory (they are off in the quick start). The quick start policy allows three definitions in all, so the demo needs one free slot. The demo script was run against fakes in `hack/demo-test.sh`, and on a cluster in the `e2e` CI job (see the [what works](../what-works.md) page for the record).
