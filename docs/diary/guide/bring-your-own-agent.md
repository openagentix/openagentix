---
title: Bring your own agent
sidebar_position: 3.7
description: What a container agent must do, the environment the platform gives it, how to build and pin an image, how to test it with the conformance checker, and the common failures.
---

# Bring your own agent

You can run an agent you built yourself, in any language or framework, under the platform's key, budget, gate and audit. You give the platform a container image that speaks A2A 1.0. The platform runs it and governs the calls to and from it.

This page is for the person who builds that image. The decision behind it is [ADR 0015](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0015-bring-your-own-agent.md).

**What was checked.** The checker on this page ran against the sample agent `examples/agents/echo-a2a` (all checks that apply passed) and against broken fake servers in unit tests (each one fails with the message shown below). The checker has not been run against an agent built with a Python or other framework. Nothing here proves your agent is safe, only that it speaks the protocol the platform needs.

## What the platform expects

| The platform | Your image |
|---|---|
| Runs it as user 65532, with a read-only root file system, no Linux capabilities, no privilege escalation and no Kubernetes token | Must start and work under those limits. The only writable path is `/tmp` (an empty directory that is lost on restart) |
| Calls the port you name in the AgentDefinition (`spec.runtime.container.port`, 1024 to 65535) | Listens on that port, on all addresses (`0.0.0.0`, not `127.0.0.1`) |
| Probes `GET /.well-known/agent-card.json` for readiness and liveness | Answers it with HTTP 200 and JSON, within 2 seconds, at most 64 KiB |
| Sends A2A 1.0 JSON-RPC to `POST /` through the A2A gate | Serves `SendMessage` there, and `SendStreamingMessage` if the card says streaming is on |
| Lets it reach DNS and the model gateway only | Needs no other network: no model downloads, no telemetry, no package index at run time |

The platform does not set `PORT`. Listen on the port you wrote in the AgentDefinition. Many samples read a variable for that (the sample reads `LISTEN_ADDR`, default `:8080`). If you use one, set it yourself under `env`, or keep the default.

## The environment

The platform sets these three. They are the only variables it adds.

| Variable | Meaning |
|---|---|
| `OPENAI_BASE_URL` | The model gateway, an OpenAI-compatible base URL. Append `/chat/completions` |
| `OPENAI_API_KEY` | A key that works only at the gateway, only for this agent, under its budget |
| `OPENAGENTIX_MODEL` | The model name from the definition. It is a hint, not a limit |

You may add your own plain values under `spec.runtime.container.env` (up to 32). Names must be upper case and must not start with `OPENAGENTIX_`, `OPENAI_`, `OTEL_` or `KUBERNETES_`. Do not put a secret there. Values are scanned and a secret is refused.

Use the model only through these three variables. Do not hold a provider key in the image.

## What your agent must answer

1. **Agent card.** `GET /.well-known/agent-card.json` returns a JSON object with `name`, `description`, `version`, `supportedInterfaces`, `capabilities`, `defaultInputModes`, `defaultOutputModes` and `skills`. `supportedInterfaces` has one entry with `protocolBinding` `JSONRPC` and `protocolVersion` `1.0`. Older A2A versions are not translated.
2. **SendMessage.** `POST /` with `{"jsonrpc":"2.0","id":...,"method":"SendMessage","params":{"message":{...}}}`. The `result` holds `message` or `task`, not both. A task has an `id` and a `status.state`. If you return a task, `GetTask` with `{"id": ...}` works for it.
3. **Streaming.** If the card says `capabilities.streaming` is true, `SendStreamingMessage` answers with `Content-Type: text/event-stream`, one `data: {json-rpc object}` line per event, and a last event in a terminal or waiting state. If streaming is off, answer it with the error code `-32004`.
4. **Errors.** A body that is not JSON gets `-32700`. An unknown method gets `-32601`. A `SendMessage` with no parts gets `-32602`. Each is a JSON-RPC error object with a message. Do not crash and do not return an HTML page.

## Build the image

Use a small base and a non-root user. A Go example (the sample at `examples/agents/echo-a2a` does this):

```dockerfile
FROM golang:1.25 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -o /out/agent .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /out/agent /agent
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/agent"]
```

For Python or Node, set `USER 65532:65532`, make sure nothing writes outside `/tmp` (set `HOME=/tmp`, and for Python `PYTHONDONTWRITEBYTECODE=1`), and install every dependency at build time.

## Pin it by digest

The platform accepts an image only by digest, and only from a registry prefix the operator allowed (`controlPlane.policy.runtimes.container.images`). A tag next to the digest is refused.

```sh
docker build -t registry.example.com/team/my-agent:1 .
docker push registry.example.com/team/my-agent:1     # prints: digest: sha256:<64 hex>
```

Then use `registry.example.com/team/my-agent@sha256:<64 hex>` in the definition:

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata:
  name: my-agent
  namespace: kagent
spec:
  model: quickstart-model
  runtime:
    type: container
    container:
      image: registry.example.com/team/my-agent@sha256:<64 hex>
      port: 8080
```

Private registries are not supported yet (no pull secrets). Container agents are off by default: the operator turns them on with `controlPlane.containerAgents.enabled` and `allowedRuntimes`. To try the sample on a laptop, run `QUICKSTART_BYO=1 PROFILE=quickstart ./install.sh` (see [Quick start](./quick-start.md)).

## Test it with the conformance checker

The checker is a small Go program, `tools/a2a-conform`. It needs only Go to build.

```sh
cd tools/a2a-conform && go build -o a2a-conform ./cmd/a2a-conform
```

Start your image the way the platform will, and point its model at the checker's fake model so you need no paid key:

```sh
docker run --rm --user 65532:65532 --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges -p 8080:8080 \
  -e OPENAI_BASE_URL=http://host.docker.internal:9099 \
  -e OPENAI_API_KEY=test -e OPENAGENTIX_MODEL=test \
  my-agent
```

In another terminal:

```sh
./a2a-conform --fake-model :9099 http://localhost:8080
```

The fake model answers `/chat/completions` with a fixed sentence. The exit code is 0 when no check failed and 1 when one did. The output is a table, then a plain-English fix for every row that is not a pass. A run against the sample looks like this (shortened):

```text
RESULT  CHECK                                                 DETAIL
PASS    Agent card at /.well-known/agent-card.json            HTTP 200, 508 bytes, 2ms
PASS    Listens on a port of 1024 or higher                   port 18080
PASS    Card lists a JSONRPC interface, protocol version 1.0
PASS    SendMessage returns a message or a task               message
PASS    Streaming matches the card                            not claimed, refused with -32004
PASS    Unknown method gives error -32601                     error -32601
MANUAL  Runs as user 65532                                    docker run --user 65532:65532 ...
```

What the checker does and does not do:

- It checks the protocol over HTTP: the card, the port, `SendMessage`, `GetTask`, streaming and the error shapes.
- It cannot see inside the container. The user, the read-only root, the environment and the network are listed as `MANUAL` rows. The `docker run` flags above are how you test them: if the agent passes with those flags, it passes the platform's limits for those items. Run it also without internet access to check the network rule.
- It says nothing about the quality of the agent's answers, its prompts or its use of tools.
- The `docker run` command above was not run for this page (Docker was not available when it was written). The checker itself was run against a locally built sample binary.

## Common failures

| What the checker says | Likely cause | Fix |
|---|---|---|
| Card: could not connect | The agent listens on `127.0.0.1`, or on another port | Bind `0.0.0.0` and use the port you set in the definition |
| Card: HTTP 404 | The card is served at another path | Serve `/.well-known/agent-card.json` |
| Card: must answer within 2 seconds | The card calls the model or a database | Build it in memory at start |
| Card fields missing | An older card shape | Add the listed fields |
| No JSONRPC 1.0 interface | The agent speaks A2A 0.3 or only HTTP+JSON | Add a `JSONRPC` interface with `protocolVersion` `1.0` |
| SendMessage: error -32000 | The model variables are not set, or the model URL is unreachable | Start with the three variables; use `--fake-model` for a test |
| SendMessage: result has neither message nor task | The reply uses the 0.3 shape (a bare message with `kind`) | Wrap it as `{"message": {...}}` |
| Streaming: not `text/event-stream` | The card says streaming but the reply is plain JSON | Send SSE, or set streaming to false |
| Error shape: no JSON-RPC error | The server crashes or returns HTML on bad input | Validate input and return JSON-RPC errors |
| Port below 1024 | A non-root user cannot bind it | Use 8080 |

In a cluster, an agent that never becomes Ready usually fails the first row, the second row or a read-only root (for example a framework that writes a cache next to its code). The pod shows the reason in `kubectl describe pod -n openagentix-workloads`.

## Limits to know before you build

A container agent is less isolated than a built-in agent: it shares the node kernel, runs as one process for all conversations, and has one identity. Network limits hold only on a cluster whose network plugin enforces NetworkPolicy. Tools through a tool profile are not available yet, and per-agent egress allowlists are not available yet. The full list is in ADR 0015 and in [What works](../what-works.md).
