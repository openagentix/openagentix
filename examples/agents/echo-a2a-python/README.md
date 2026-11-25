# echo-a2a-python

A small "bring your own" A2A 1.0 agent in Python. It does what the Go sample ([echo-a2a](../echo-a2a)) does: it sends the
text to an OpenAI-compatible model and answers `model <name> answered: <reply>`. It is a sample, not production code.
It does not stream, keeps no state between calls and writes no files.

It exists to show that a Python agent runs under the platform's rules (ADR 0015, issue #104): its own gateway key, the A2A
gate in front, a non-root user and a read-only root file system.

## Why the A2A Python SDK

The agent uses the official SDK, [`a2a-sdk`](https://pypi.org/project/a2a-sdk/) 1.3.1 (Apache-2.0, from the A2A project).
Reasons for this choice:

- It speaks A2A 1.0 by itself. The `1.0` JSON-RPC binding, the agent card and the `SendMessage` result (`{"message": ...}`)
  come from the SDK, so the sample has no protocol code of its own. I ran it with the `A2A-Version: 1.0` header and checked
  the card, `SendMessage`, an unknown method (`-32601`) and a streaming call (`-32004`, not claimed). The SDK reads a
  request without that header as version 0.3, so a client must send it. The gate and `hack/ask.sh` do.
- It is small. The agent is one file of about 170 lines, and the install is the SDK with its `http-server` extra plus
  `uvicorn`. Every package is pinned with its hashes (a few have one pin per Python version).
- It does not tie the sample to one model framework. A LangGraph, Google ADK or CrewAI agent only has to put its own call in
  `OpenAIChatModel.complete` (or replace it) and keep the server part. I did not check whether those frameworks serve A2A 1.0
  themselves; ADR 0015 lists that as open. The sample does not claim they do.

Limits of this choice: the SDK is a server toolkit, not an agent framework (there is no planning, memory or tool loop here).
Its version number is young, so the pins matter. It pulls in large dependencies (protobuf, pydantic, google-api-core,
cryptography), so the image is bigger than the Go sample's. I did not measure its size.

## Environment

The platform sets the first three. You do not need to.

| Variable | Meaning |
|---|---|
| `OPENAI_BASE_URL` | OpenAI-compatible base URL; `/chat/completions` is appended |
| `OPENAI_API_KEY` | bearer key for the model gateway (never logged or returned) |
| `OPENAGENTIX_MODEL` | model name to request |
| `PORT` | listen port, 1024 to 65535, default `8080`. `LISTEN_ADDR` (for example `:9090`) also works and wins |

With any of the three model variables missing the agent still starts and serves its card; `SendMessage` then fails with a
short error. Errors that reach the caller never contain the key, the model's reply body or an exception text.

## Test

```sh
make test-python-samples        # from the repository root
```

It creates a throwaway virtual environment, installs `requirements-dev.txt` with `--require-hashes`, and runs `pytest`:
20 tests with a fake model (settings, card, `SendMessage`, errors, the model call against a fake HTTP transport) and one
contract test that builds `services/stub-model` with Go and sends a message through the whole path. That test skips
itself when Go is not installed. Needs Python 3.10 or newer and access to PyPI. No paid model call is made.

## Build, load and deploy (kind, quick start)

You need a quick start with the container runtime on (`QUICKSTART_BYO=1`). It allows the image name prefix
`registry.local/oa/`, which is a name and not a server: nothing is pulled from it. Run these from the repository root.

1. Install the quick start with the sample container agent, and let the ask caller reach the new agent too. A list in a
   values file replaces the earlier list, so the caller is restated with both agents:

   ```sh
   cat > /tmp/echo-py-values.yaml <<'EOF'
   governance:
     a2a:
       callers:
         - name: quickstart-ask
           serviceAccount: {namespace: openagentix-system, name: quickstart-ask}
           agents: ["kagent/quickstart", "kagent/echo-go", "kagent/echo-py"]
           userId: {exact: "quickstart:ask"}
   EOF
   QUICKSTART_BYO=1 PROFILE=quickstart VALUES_FILE=/tmp/echo-py-values.yaml ./install.sh
   ```

   Policy `maxAgents` is 2 for container agents in this setup, which fits `echo-go` and `echo-py`.

2. Build the image and load it into the cluster (the default cluster name is `openagentix`):

   ```sh
   TAG=dev-$(git rev-parse --short HEAD)
   docker build -t registry.local/oa/echo-a2a-python:$TAG examples/agents/echo-a2a-python
   kind load docker-image registry.local/oa/echo-a2a-python:$TAG --name openagentix
   ```

3. Read the image digest from the node and write the definition with it. A container agent needs a digest, not a tag:

   ```sh
   REF=$(hack/kind-image-digest.sh openagentix registry.local/oa/echo-a2a-python $TAG)
   echo "$REF"        # registry.local/oa/echo-a2a-python@sha256:<64 hex>
   yq --arg i "$REF" '.spec.runtime.container.image=$i' examples/agents/echo-a2a-python/agent.yaml | kubectl apply -f -
   kubectl wait agentdefinition/echo-py -n kagent --for=condition=Ready --timeout=300s
   ```

   `yq` is the Python wrapper (`pip install yq==3.4.3`), as in the rest of the repository.

4. Ask it. The first call can fail for up to about a minute while the gate learns the new route; ask again:

   ```sh
   hack/ask.sh echo-py "Say hello"
   ```

   With the stub model the answer starts with `model quickstart-model answered: [stub model]`.

On a real cluster, push the image to your registry, list that registry's prefix in
`controlPlane.policy.runtimes.container.images`, and use `registry.example.com/team/echo-a2a-python@sha256:<digest>` in the
definition.

## The AgentDefinition

[`agent.yaml`](agent.yaml):

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata:
  name: echo-py
  namespace: kagent
spec:
  description: A sample agent built with the A2A Python SDK
  model: quickstart-model
  runtime:
    type: container
    container:
      image: IMAGE_REGISTRY/echo-a2a-python@sha256:IMAGE_DIGEST
      port: 8080
```

## What the image does to meet the platform's rules

| Rule (ADR 0015) | How |
|---|---|
| user 65532 | `USER 65532:65532` |
| read-only root file system | The packages are installed and compiled while building; `PYTHONDONTWRITEBYTECODE=1` stops writes at run time. The agent writes no files. `/tmp` is the only writable path the platform gives |
| port of 1024 or higher from the environment | `PORT`, default 8080 |
| no Kubernetes token | The agent never calls the Kubernetes API |
| model only at `OPENAI_BASE_URL` | The only outbound call is the one in `OpenAIChatModel` |
| digest-pinned base | `python:3.13-slim@sha256:7249d558...` (multi-arch index digest read on 2026-11-25) |
| pinned packages | `requirements.txt`, from `requirements.in`, with hashes for every package and platform |

## Update the pins

```sh
# the packages (needs uv; any pip-compile that writes hashes works)
uv pip compile --generate-hashes --universal --python-version 3.10 requirements.in -o requirements.txt
uv pip compile --generate-hashes --universal --python-version 3.10 requirements-dev.in -o requirements-dev.txt
# the base image: the index digest of the tag
TOK=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/python:pull" | jq -r .token)
curl -sI -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.oci.image.index.v1+json" \
  https://registry-1.docker.io/v2/library/python/manifests/3.13-slim | grep -i docker-content-digest
```

Then change `PYTHON_IMAGE` in the `Dockerfile` and run the tests. Dependabot proposes the package updates weekly.

## Not checked

See [what works](../../../docs/diary/what-works.md) for what was run. The image build, a run under the platform's
restrictions (read-only root, user 65532) and a deploy on a cluster were not run when this sample was written: the
Docker daemon on the author's machine was not reachable. CI builds the image; a cluster run is still to be recorded.
