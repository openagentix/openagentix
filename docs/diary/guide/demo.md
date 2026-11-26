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

## Real output

This is from the `e2e` CI job on a hosted runner (kind, stub model, [run 45663797281](https://github.com/openagentix/openagentix/actions/runs/45663797281)). Long lines are cut, and the user id is a salted hash that changes on each gate start.

```text
== Step 1: create an AgentDefinition
  ok    AgentDefinition demo-lookup is Ready
        Accepted=True
        KeyReady=True
        Applied=True
        Ready=True

== Step 2: the gateway key and the token budget
  ok    the model gateway knows the user kagent.demo-lookup (entry in ConfigMap llm-api-keys-control-plane; only a hash is stored there, and it is not printed)
  ok    token budget for each gateway key: 1000000 tokens per Hours (a key over its budget gets HTTP 429)

== Step 3: ask the agent quickstart a question through the A2A gate
        [stub model] I used the tool osv_query_vulnerability. It answered: {"output":{"text":"{ "vulns": [ ...
        (answered in 1s through the A2A gate)

== Step 4: the audit line of that call
        {
          "msg": "audit",
          "caller": "quickstart-ask",
          "agent": "kagent/quickstart",
          "user_id": "h:5fe05831",
          "status": 200,
          "duration_ms": 725,
          "method": "POST",
          "rpc": "SendMessage"
        }

== Step 5: a call that must be denied
        ask.sh: HTTP 403 from the gate: {"error":"forbidden"}
  ok    denied, as it should be (exit 1)
        { "msg": "audit", "agent": "kagent/demo-lookup", "status": 403, "duration_ms": 1, "reason": "agent" }
        [stub model] I used the tool fetch_fetch. It answered: {"error":"tool 'fetch_fetch' not found. Available tools: ... osv_query_vulnerability ...
  ok    no page came back: the tool profile does not offer a fetch tool

== Step 6: the console
  ok    GET /api/v1/agents without a token is 401
  ok    with the token the console lists demo-lookup

demo: every step showed what it should.
```

The whole walkthrough took about 15 s on the runner, after the install.

## Stop halfway

If you stop the script, one command removes what it made:

```sh
kubectl delete agentdefinition demo-lookup -n kagent
```

To remove the whole cluster, see [Quick start](./quick-start.md).

## What this shows and what it does not

It shows the controls on a single-node quick start with the stub model: a definition is checked by policy, an agent has its own gateway key and a token budget, a caller is checked by the gate, every call leaves an audit line without content, and a call outside the rule is refused.

It does not show a real model, a trace of one turn or an egress allowlist (the quick start agent has no egress). It does not show channels, schedules, the knowledge base or memory (they are off in the quick start). The quick start policy allows three definitions in all, so the demo needs one free slot. `hack/demo-test.sh` runs the script offline against a fake `kubectl`. The `e2e` job runs it on a cluster after the smoke test and passed on this run.

Throwaway proof: [broken](./this-page-does-not-exist.md)
