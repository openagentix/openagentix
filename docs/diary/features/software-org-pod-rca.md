---
title: Pod root-cause agent (software organisation use case)
sidebar_position: 15.6
description: The first agent of the software organisation reference use case, on the read-only diagnostic tools. What it does, what the live run showed, and what is not proven.
---

# Pod root-cause agent

Issue [#229](https://github.com/openagentix/openagentix/issues/229). The code and the full README are in `examples/use-cases/software-org`. It needs the `cluster-read` tool server of [ADR 0025](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0025-read-only-diagnostic-tools.md) and nothing else new: no chart value was added.

## What it is

A chart agent, `pod-rca`, on the tool profile `rca` (the eight read tools of `cluster-read` and nothing else). Asked about a workload, it lists the pods, reads the pod, its events, a capped log and the owning workload and node, then writes a report: evidence, likely cause, confidence, recommended actions for a person. It says "inconclusive" and what is missing when the evidence is thin. It has no write tool and no egress, and it treats every log line and event text as data.

The namespace `rca-demo` holds six workloads that are broken on purpose (an image tag that does not exist, a crash on start, an out of memory kill, a missing ConfigMap key, a failing readiness probe, a node selector no node has), three planted canaries (a made-up secret in an environment value, in a log line and in a probe header) and one log line that tries to give the agent an instruction.

## What the live run showed

The opt-in job `e2e (software-org, pod RCA)` runs the use case on kind through a real agent session: the question goes through the A2A gate, kagent runs the agent, the agent calls the tools through the vMCP of its profile, and `tools/oa-eval` checks the answers. The model is the stub model with scripted scenarios, so the run proves the wiring, not a model.

- All eight cases of the evaluation set passed, with the real kubelet's states and events: the six causes, the injected log line reported and not obeyed, and a workload that does not exist answered with "inconclusive".
- The agent's tool calls reached `cluster-read` (about fifty audited calls, all of them `cluster-read` tools). The shared tool server saw none.
- kagent reports the tool server of the profile with the reason `DiscoveryDisabled` and no tools, because agents resolve their tool list at run time with the session's actor token. The calls work. This is the answer to the open question of the earlier slice.
- kagent gives the model a tool result as `{"output":{"text":"<JSON as a string>"}}`. The stub model had to learn to read JSON inside a string. This was the one thing that failed in the first live run.
- No canary, in plain, base64 or hex form, was in any answer or in the logs of `cluster-read`, of the tool servers, of the gate, of the kagent controller or of the stub model.
- The gate refused the callers it should refuse (403).

## What is not proven

- How a real model behaves. Pass rates, cost and the wording of its reports are not measured; `install.sh --real-model` sets up the same agent with no scenario.
- That redaction catches every secret in a log. It is a scanner. The canaries are in forms it knows, or in fields the server never returns.
- Memory of the new pods, and NetworkPolicy enforcement on the kind network plugin (the pod in `default` check of `hack/ci/diagnostics-live.sh` covers ingress only).
- An alert trigger and an incident record: a person starts the agent. A person reads the report before acting.
