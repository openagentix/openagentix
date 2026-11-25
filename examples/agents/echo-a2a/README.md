# echo-a2a

A tiny sample "bring your own" A2A 1.0 agent in Go (standard library only). It serves an agent card and a JSON-RPC
`SendMessage`, sends the text to an OpenAI-compatible model, and answers `model <name> answered: <reply>`.
It is a sample, not production code. It does not stream (`SendStreamingMessage` returns -32004).

## Build

```sh
docker build -t echo-a2a examples/agents/echo-a2a
```

The image runs as UID 65532, listens on 8080, and works with a read-only root file system (it writes nothing) and no
Kubernetes API token.

## Environment

| Variable | Meaning |
|---|---|
| `OPENAI_BASE_URL` | OpenAI-compatible base URL; `/chat/completions` is appended |
| `OPENAI_API_KEY` | bearer key sent to the model (never logged or returned) |
| `OPENAGENTIX_MODEL` | model name to request |
| `LISTEN_ADDR` | optional, default `:8080` |

With any of the three missing the agent still starts and serves its card; `SendMessage` returns error -32000 naming the
missing variable.

## Sample AgentDefinition

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata:
  name: echo-go
  namespace: kagent
spec:
  description: Sample bring-your-own agent that echoes the model's answer.
  model: quickstart-model
  runtime:
    type: container
    container:
      image: <registry>/echo-a2a@sha256:<digest>
      port: 8080
```
