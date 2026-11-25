# Keyless end-to-end install in CI

Status: **built** (ADR 0014, issue #34). `.github/workflows/e2e.yml` installs the quick start on a GitHub-hosted runner with no key and
no chat token, then runs `hack/ci/smoke.sh`. It is not in the required `ci-ok` gate yet; the table below is the record that decides when it
goes in (several consecutive green runs on pull requests and nightly).

## What runs

1. `ubuntu-24.04` (4 vCPU, about 16 GB, `/dev/kvm` present), `helm`, `yq` (Python wrapper) and `kind` from `hack/ci/install-tools.sh`.
2. `PROFILE=quickstart ./install.sh` with no environment variables: the profile (`components/quickstart/values.yaml`), the stub model, the
   control plane, the console and the A2A gate, one `AgentDefinition`. `AGENT_WAIT=300s`. A step that fails fails the job (`pipefail`).
3. `hack/ci/smoke.sh`: the agent is Ready; a question goes through the A2A gate (`hack/ask.sh`) and the stub answers with a real tool
   call (the OSV tool through the tool profile, in the Substrate sandbox); a tool the profile does not offer returns no data; a definition
   with a model outside the policy gets `Accepted=False` and no agent; the console API answers 401 without the token and lists the agent
   with it.
4. The job summary has the time from the start of `install.sh` to the agent Ready, each install step with its time, and the smoke output.
   On any failure: pods, events, the agent objects, controller logs, the admission guard's answer for a key Secret
   (`hack/ci/guard-probe.sh`) and `kind export logs` as an artifact.

Triggers: pull requests that touch `install.sh`, `charts/`, `components/`, `services/`, `console/`, the smoke and ask scripts or the
workflow; nightly at 03:17 UTC; by hand.

## Record

| Run | Result | Time to first working agent | Notes |
|---|---|---|---|
| first (commit e7dadef) | install reached the agent step in 355 s, agent never Ready | n/a | found a real bug: the control plane's key Secret carried the definition's labels and the admission guard refused it (422); fixed in `services/control-plane` (test first) |
| second (commit 229e825) | **green, 10 of 10 smoke checks** | 366 s (6 min 6 s) from the start of `install.sh`; cold runner, nothing cached | see "Where the time goes" |

Where the time goes (second run, cumulative seconds from the start): kind cluster, CRDs, Substrate and its PostgreSQL, kagent and its
PostgreSQL 128 s; agentgateway 55 s more (183 s); the four image builds (a2a-gate, stub-model, control-plane, console; 3 at a time, the
console builds its web app inside Docker) 106 s (289 s); `helm upgrade --install` 7 s; the tool profile's vMCP 59 s (355 s); the agent
Ready 11 s (366 s). The node used 2.3 GiB at the end.

## gVisor on a hosted runner

Agent Substrate's gVisor sandbox **works** on `ubuntu-24.04` hosted runners with the default settings: the worker registered, the golden
snapshot was taken, and a turn ran in a sandbox (the agent was Ready in 11 s and answered through a tool call). The runner has `/dev/kvm`,
but the gVisor worker image used here does not need it (see `components/runtime/NOTES.md`: it ran on Docker Desktop without KVM).
Observability (VictoriaMetrics and Jaeger) is ON in the profile: one dispatched run with it took 390 s against 366 s without, and the node used 2.366 GiB against 2.326 GiB; the smoke test passed in both.

Because it works, no weaker runtime class setting was added: there is no `SANDBOX_RUNTIME` switch, and nothing weakens the default.

## What this does not prove

- A real model's answers (CI uses the stub); the Ollama path; the OpenAI and Gemini default model names.
- A second install on a cluster that already has the full demo, upgrades, uninstall.
- Behaviour under load, or on arm64 (the runner is amd64; the maintainer's laptop is arm64).
