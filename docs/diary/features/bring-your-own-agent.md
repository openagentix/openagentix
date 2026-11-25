---
title: Bring your own agent
sidebar_position: 14
description: Run your own A2A agent image under the platform's key, policy and gate. What slice 1 does, what it refuses and how isolation differs.
---

# Bring your own agent

## What it is for

Teams already have agents. This feature lets one of them run on OpenAgentix without being rebuilt from instructions. The decision and the options are in ADR 0015 (issue #43). This is slice 1: a container agent with model access only.

## How it works

```mermaid
flowchart LR
  U[Caller] --> G[A2A gate]
  G -->|fixed URL template| S[Service in openagentix-workloads]
  S --> P[Agent pod]
  P -->|own key| M[Model gateway]
  C[Control plane] -->|writes| D[Deployment, Service, ServiceAccount, NetworkPolicy, key Secret]
  C -->|writes route list| R[(a2a-gate-routes)]
  R --> G
```

- `spec.runtime.type: container` and `spec.runtime.container.image` (digest pinned, from an operator-approved registry) in an `AgentDefinition`.
- The control plane runs the image as a Deployment in the namespace `openagentix-workloads`. The namespace enforces Pod Security `restricted` and has a default-deny network policy.
- The key Secret is created in that namespace and mounted as `OPENAI_API_KEY`. The controller can create and delete Secrets there but never read them.
- The controller writes the list of container agents to a ConfigMap. The gate reads it and builds the upstream URL itself from a fixed template, so the list cannot point the gate at another host.
- An admission guard (allowlists on every field) limits what even a compromised controller can write.

## What is refused

`instructions`, `instructionsFrom`, `tools`, `toolProfile`, `egress.allow`, `memory`, `knowledge`, `notify`, `skills`; images without a digest or outside the allowed registries; the runtime itself when `allowedRuntimes` does not list it (the default is `[builtin]`).

## Isolation, plainly

Less isolated than the built-in runtime: shared kernel unless a RuntimeClass is set, one process for all conversations, one identity per agent, no persistent files. On kind, outbound traffic to the internet is not enforced by the network plugin. On k3s (k3d, in CI) a deny-all egress policy did block a connection to the internet, and the sample agent passed the smoke test there ([Install on k3s](../guide/install-k3s.md)).

## What was run

In the `e2e` job (GitHub-hosted runner, one kind node, stub model, no key): `QUICKSTART_BYO=1 PROFILE=quickstart ./install.sh` builds the sample, loads it into kind, reads its digest from the node (`hack/kind-image-digest.sh`; kind keeps only the tag, so the script adds the `name@sha256` name on the node) and applies the definition. `hack/ci/smoke.sh` then checked: Ready 10 s after creation, isolation `container`, user 65532 with a read-only root and no token, the endpoint through the gate, an answer through the gate and the model gateway, the gateway user `kagent.echo-go`, and three refused definitions. The gate began to route to the new agent about 39 s after it was Ready (one run), because the route list reaches it through a ConfigMap volume; the check asks again for up to two minutes.

Not shown: whether kind's network plugin enforces the NetworkPolicy (so the egress port to the model gateway is not shown to be right), pulling from a registry, a real model.

## Not done yet

Tools through a tool profile (slice 3), the conformance checker (slice 2), a Python sample (slice 4), an egress allowlist (slice 5), enrolling a workload you run yourself, private registries.
