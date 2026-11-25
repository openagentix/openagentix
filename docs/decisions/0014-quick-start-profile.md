# ADR 0014: a quick start profile that needs no paid key and no chat token

Status: Accepted (2026-11-25)
Date: 2026-11-25
Issue: #28 (with #29, #33, #34, #35, #9)
Replaces: none

One command, no account, a working governed agent in under 10 minutes on a laptop-size kind cluster, and the same thing proven in CI. A real model is the headline; a built-in stub model is the fallback for visitors who have no key yet.

## Context

Until now a first install needed `ANTHROPIC_API_KEY` and `TELEGRAM_BOT_TOKEN` (`install.sh` asked for both before anything else) and took about 23 minutes with every demo values file (README "Quickstart", measured 2026-11-25). The first goal of the project is adoption (`docs/roadmap.md`, ADR 0013), and time to first working agent matters most. An OpenAI-compatible stub exists only as a spike manifest (`components/runtime/manifests/mock-llm.yaml`), which the chart does not render. `.github/workflows/e2e.yml` was a scaffold that failed on purpose for lack of a keyless profile (`hack/ci/E2E-PLAN.md`).

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Only a stub, no real-model path | Simplest | A demo that never shows a real answer; the stub becomes the headline | rejected by the owner (a real agent setup needs a real model) |
| B. Profile file + model chosen by the installer: your key or endpoint first, a local Ollama on request, the stub as fallback | One command for every visitor; the same agent definition on every path | A small model-selection script to test | `components/quickstart/tests/run.sh` (offline) |
| C. A second installer for the quick start | Free to shape | Two scripts to keep in step | not chosen |

## Decision

Option B.

- **Profile.** `PROFILE=quickstart ./install.sh` (or `./install.sh --quickstart`) adds `components/quickstart/values.yaml` in front of any `VALUES_FILE`. ON: the runtime (kagent and Substrate), the model gateway (virtual key and token budget), the tool gateway with one tool server (`osv`) and one tool profile (`lookup`, one tool), the control plane, the console and the A2A gate. OFF: the Telegram bridge, Kourier channels, schedules, notify, the observability bundle, the knowledge base and graph, memory. There is no chart agent: the installer applies one `AgentDefinition` (`components/quickstart/agent.yaml`) at the end, so the visitor sees the builder path, and the console shows it.
- **Model, in this order.** The gateway alias is always `quickstart-model`, so the definition and the policy never change. (1) A provider key in the environment: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or `GOOGLE_API_KEY` (Gemini), or any OpenAI-compatible endpoint with `MODEL_BASE_URL` + `MODEL_NAME` (+ `MODEL_API_KEY`). `MODEL_NAME` overrides the upstream model name. (2) A local Ollama on request only: `MODEL_PROVIDER=ollama` with `OLLAMA_HOST` and `MODEL_NAME`. (3) Otherwise the stub, and the installer says so in its final summary together with the one-line command that switches to a real model. `MODEL_PROVIDER=<name>` forces a path. Implemented in `components/quickstart/model.sh`; it writes a values overlay that replaces `gateway.models` and turns the stub off, and never writes a key into any file.
- **Stub.** `gateway.stubModel.enabled` (default false, so the default render is unchanged) renders a Deployment, Service and NetworkPolicy in the gateway namespace for `services/stub-model`, a Go server with only the standard library. It is routed through the model gateway as a normal `gateway.models` entry (provider OpenAI, `baseURL` the in-cluster Service), so virtual keys, budgets and metrics work as with a provider. Hardened pod (non-root, read-only filesystem, no capabilities, no token), and a NetworkPolicy that admits only the gateway's proxy pods and allows no egress. It is deterministic: a prompt about vulnerabilities becomes one call of `*query_vulnerability` with the package, ecosystem and version read from the prompt; a prompt that names a URL or says "fetch" becomes a call of `fetch_fetch` even when the agent's profile does not offer it (the platform, not the model, refuses). After a tool result it reports the result in one sentence. Every answer says it comes from the stub. It is for trying the platform's controls, not for answers.
- **Installer.** What is required is derived from what the chart renders (#33): a Telegram token only when the bridge is rendered; a provider key only for a provider Secret that a rendered gateway model uses. A placeholder skill digest (`registry.invalid`, `sha256:0...0`) that the installer would not replace (`SKIP_SKILL=1`, or a skill other than the example) stops the install before anything changes (#9). Image builds run in parallel (`BUILD_JOBS`, default 3) and load into kind in one call. `components/runtime/up.sh` now honours `CLUSTER`, so a second kind cluster can be installed without touching the first.
- **Asking without a chat app.** `hack/ask.sh <agent> "<question>"` port-forwards the A2A gate and signs in as the ServiceAccount `openagentix-system/quickstart-ask` with a 10-minute token; the profile's gate rule lets that caller ask the agent `kagent/quickstart` only.
- **CI.** `.github/workflows/e2e.yml` runs the profile with the stub on `ubuntu-24.04` and `hack/ci/smoke.sh`. It is not in the required `ci-ok` gate until it has passed reliably.
- **Observability.** The bundled observability stays out of the profile until its cost is measured on the 10-minute and laptop target; the extra values file is `components/observability/demo-values.yaml`. (Updated in the pull request with the numbers; see the diary page.)

## Consequences

- A visitor needs only Docker, kind, kubectl, helm, jq, python yq and openssl. No account.
- Security: the stub has no credentials and no egress; the only new caller of the A2A gate is a ServiceAccount token the profile's rule limits to one agent. The profile's policy allows one model alias, one tool profile and no egress. The installer's final output never prints a secret.
- The default install and the default render do not change (the chart tests keep their byte-identical checks). The installer's preflight messages for the default install are the same text; the check moved after the render.
- A stub answer is never a language model's answer. The final summary and every stub answer say so.
- Proof needed: chart tests (`charts/openagentix/tests/run.sh`), model and preflight tests (`components/quickstart/tests/run.sh`), the stub's Go tests, and the e2e job.

## Not checked / open points

- A local Ollama path is built from the documented host addresses (`host.docker.internal` on Docker Desktop, the kind network gateway on Linux) and is *unverified* on a cluster.
- The OpenAI and Gemini default model names are *unverified* defaults; `MODEL_NAME` overrides them.
- A `stubModel: true` flag in the control plane's catalog and a console banner are follow-up work.
- Whether Substrate's gVisor sandbox runs on a GitHub-hosted runner: see the e2e record in `hack/ci/README.md`.
