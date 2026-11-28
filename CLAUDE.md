# OpenAgentix: guide for AI coding assistants and new contributors

Read this first. It is short on purpose. The linked files are the source of truth; if they differ from this file, they win.

## What this is

OpenAgentix is an open-source control plane for running AI agents on Kubernetes under the rules your platform team sets ([README](README.md)).
Agents are Kubernetes resources (`AgentDefinition`, group `openagentix.io`). Policy, gateway keys and budgets, tool profiles, egress rules, an audit record and a console come from one install.
Upstream projects (kagent, agentgateway, ToolHive and others) sit behind adapters.

Current focus ([ADR 0013](docs/decisions/0013-focus-and-runtime-neutrality.md)): governed agent runs for platform teams, adoption first. Release 0.3 is the target: control plane and console proven on a cluster, bring your own A2A agent, a quick start with no paid key and no chat token.

## Read first

- [docs/decisions/README.md](docs/decisions/README.md): the ADR index and when an ADR is required.
- [docs/roadmap.md](docs/roadmap.md): the goal (adoption) and the release plan.
- [docs/diary/what-works.md](docs/diary/what-works.md): the strict record of what is proven, and its limits. Public claims must match it.
- [docs/contributing/workflow.md](docs/contributing/workflow.md): issues, labels, branches, review, merge, releases.
- [docs/api-conventions.md](docs/api-conventions.md): rules every resource follows (spec, status, versions).
- [CONTRIBUTING.md](CONTRIBUTING.md), [GOVERNANCE.md](GOVERNANCE.md), [SECURITY.md](SECURITY.md), [hack/ci/README.md](hack/ci/README.md).
- Release 0.3 tracking issue: <https://github.com/openagentix/openagentix/issues/65>.

## Repository map

| Path | What it is | Tests |
|---|---|---|
| `charts/openagentix/` | The Helm chart (the whole platform) | `charts/openagentix/tests/run.sh` (shell asserts over `helm template`) |
| `services/control-plane/` | Go controller for `AgentDefinition`; CRD, kagent adapter, catalog | `go test ./...` in the module |
| `services/a2a-gate/` | Go auth proxy and audit in front of the A2A port | same |
| `services/console/` | Go JSON API; embeds the web app | same |
| `services/kb/` | Go knowledge base, an MCP server (PostgreSQL + pgvector) | same; `make -C services/kb test-integration` needs Docker |
| `services/notify/` | Go MCP server that delivers to named destinations | same |
| `services/stub-model/` | Go scripted model for tests and the quick start (no paid calls) | same |
| `console/` | Svelte single-page app (pnpm, Node 22) | vitest and Playwright in `console/` |
| `bridges/telegram/` | Go Telegram bridge (optional) | `go test` in the module |
| `bridges/ax-adapter/` | AX adapter experiment; needs a local AX checkout, skipped by CI | none in CI |
| `tools/a2a-call/` | Go caller image used by schedules | `make -C tools/a2a-call test` |
| `components/` | Values files, manifests and scripts per area (runtime, model-gateway, tools, knowledge, channels, governance, quickstart, schedules, notify, observability, console, control-plane, agents, bench) | `components/*/tests/`, `components/bench` (Python) |
| `hack/` | Helper scripts; `hack/ci/` holds CI scripts, `guardtest/` (admission guard test), `apiserver-test.sh` | `make test-guard`, `make test-apiserver` |
| `docs/` | Roadmap, ADRs (`decisions/`), diary (`diary/`), console design (`console/`), API conventions | `website/` builds `diary` and `decisions` |
| `website/` | Docusaurus docs site | `npm ci && npm run build` in `website/` |
| `install.sh`, `uninstall.sh` | The installer (options are in the header of `install.sh`) | `hack/ci/smoke.sh` after install |

Every Go service is its own module (Go 1.25 or newer). `hack/ci/go-modules.sh` discovers them, so a new module needs no Makefile edit.

## Commands

Run `make help` for the targets. Prerequisites that trip people up:

- `yq` must be the Python jq wrapper (`pip install yq==3.4.3`), not mikefarah's Go `yq`. `make test-chart` checks this.
- Go 1.25 or newer (each `go.mod` says). `pnpm` and Node 22 for `console/`. Docker for integration tests and installs (4 CPU, 8 GB for the full install).
- `helm`, `jq`, `shellcheck`, `gitleaks`, `kind` and `kubectl` for the targets that name them.

```sh
make test              # offline: go (-race) + chart + shell suites
make test-go           # go test ./... -race -count=1 in every module
make test-chart        # helm lint + charts/openagentix/tests/run.sh (same as: bash charts/openagentix/tests/run.sh)
make test-shell        # channels, quickstart, dashboard, bench, image-tag tests
make test-guard        # admission guard executed with the Kubernetes CEL code (hack/ci/guardtest)
make test-apiserver    # CRD and guard on a real API server in a throwaway kind cluster "oa-ci-test"
make test-integration  # needs Docker: kb on PostgreSQL+pgvector, memory-expiry job
make test-python-samples  # Python sample agent: hash-checked venv, pytest, contract test (needs python3)
make test-console      # pnpm install --frozen-lockfile, lint, svelte-check, vitest
make test-console-e2e  # Playwright in Chromium against the Go binary in demo mode
make lint              # gofmt, go vet, shellcheck (shellcheck is a report unless SHELLCHECK_STRICT=1)
make secrets           # gitleaks over the git history
(cd website && npm ci && npm run build)   # docs site (Node 22)
```

Install on a cluster (only when your change touches the installer or live behaviour):

```sh
PROFILE=quickstart ./install.sh        # no key, no chat token: the stub model answers; then hack/ask.sh quickstart "..."
hack/ci/smoke.sh                       # checks the quick start end to end
VALUES_FILE="components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml components/observability/demo-values.yaml components/knowledge/graph-demo-values.yaml components/governance/demo-values.yaml components/governance/profiles-demo-values.yaml components/governance/memory-demo-values.yaml components/control-plane/demo-values.yaml components/console/demo-values.yaml components/tools/own-service-accounts-values.yaml" ./install.sh
```

The full demo needs `ANTHROPIC_API_KEY` and, with the Telegram bridge, `TELEGRAM_BOT_TOKEN`. Helm replaces release values on every run, so pass the same `VALUES_FILE` each time. See the README, "Full demo install".

## How work is done here (binding)

- `main` is protected. Every change is a branch and a pull request with `ci-ok` and `DCO` green. Squash merge. Never push to `main`, never force-push.
- One pull request per issue where possible. Branch name `<type>/<issue>-<short-words>`; the description starts with `Closes #N` or `Refs #N`.
- Commit with `git commit -s` (DCO) every time. Titles are conventional commits with the area: `feat(chart): ...`, `fix(bridge): ...`, `docs: ...`.
- A user-visible change adds a line under `[Unreleased]` in `CHANGELOG.md`, in the same pull request.
- Releases: semantic version tags (`vX.Y.Z`), and the changelog section is written before the tag.
- Test first. Write the failing test, run it, see it fail for the right reason, then write the smallest code that passes. A bug fix starts with a test that reproduces the bug.
- Verify before you claim. Run the command and show the output. Never write "should work".
- Root cause before fixes. Read the error, reproduce, trace back, then change one thing. After three failed fixes, question the design.
- An ADR comes before code for: a new resource kind, a new adapter interface, a public contract change (resource field, chart value, API route, event type, label key), a security-relevant change, or a new upstream component. See `docs/decisions/README.md`.
- Security-relevant changes get an independent review (a person or a separate agent that does not share your assumptions) before merge.
- Live proof on a cluster before a feature is called done. Write what you ran, what you saw, and the limits.
- Update the README, the diary (`docs/diary`) and `what-works.md` with the truth, including what does not work.

## Design rules code must follow

- Every configurable thing is an `openagentix.io` resource. No hidden config in a ConfigMap that users edit by hand.
- Upstream projects live only behind adapters. No upstream vocabulary in core packages or in a spec; tests enforce it (see `services/control-plane/internal/core/vocabulary_test.go`).
- Off by default, deny by default. With a feature off, the default chart render is byte-identical to before; the chart tests check this. One stated exception: the PodDisruptionBudgets are on by default ([ADR 0024](docs/decisions/0024-availability-defaults.md)), so the default render gains one budget per Deployment and StatefulSet. `availability.podDisruptionBudgets.enabled=false` gives back the old render byte for byte, and a chart test checks that.
  One recorded exception ([ADR 0024](docs/decisions/0024-availability-defaults.md)): the PodDisruptionBudgets are on by default; `availability.podDisruptionBudgets.enabled=false` gives back the earlier render, and a chart test checks that. A new exception needs its own ADR.
- The controller never reads Secrets. It cannot read a key back, so design around that.
- No secret values in files, argv, logs, status or reports. Audit lines never hold message text.
- Admission guard policies are key allowlists (a field not listed is refused) and are executed in tests, not only rendered.
- Status: public fields are a contract (`conditions`, `observedGeneration`, the kind's facts); everything private goes under `status.controller`. A fact that cannot be verified is `unknown`, never a guess.
- Docs use plain, simple English: short sentences, no marketing words, no em dashes.
- Public claims only for what `docs/diary/what-works.md` supports. Name the limits.

## Safety rules for automated agents

- Never print, log or commit a secret or token. Do not paste environment values into output.
- No personal identifiers (chat ids, email addresses, phone numbers) in files, logs, issues or pull requests.
- An unfixed security finding never goes in a public issue or pull request. Use private vulnerability reporting ([SECURITY.md](SECURITY.md)).
- `spikes/` and `WHAT.txt` are local scratch, gitignored, never commit them.
- Live CI scripts refuse a context that is not a named throwaway cluster; do not run them by hand against the current context (the table is in `hack/ci/README.md`).
- Do not delete or recreate a cluster the user is using. Use a separately named kind cluster with its own kubeconfig for tests.
- Do not run `install.sh` while another process edits a service's source (image tags come from a hash of the source).
- One writer per working tree. Use a git worktree for parallel work.
- No paid model calls in tests. Use `services/stub-model`.
- Do not contact other projects or people on the maintainer's behalf. Do not @-mention anyone in issues or pull requests.

## Pitfalls found so far

- kind keeps an old image when a tag is reused, so images get content-derived tags (`hack/image-tag.sh`, `dev-<hash of source>`).
- The API server refuses a CRD schema that describes `metadata`. Only a real API server shows this (`make test-apiserver`).
- YAML 1.1 reads unquoted `yes` and `no` as booleans. Quote enum values.
- A pod can report Ready during a database's first-boot restart. Wait for the dependent step, not only for Ready.
- Audit lines are written when a handler returns, so tests must wait for the line instead of reading at once.
- kind's network plugin (kindnet) does not enforce egress to the internet. Calico or Cilium do.
- `SKIP_SKILL=1` deploys a placeholder skill digest; agents that use a skill then stay not Ready.
- Helm replaces release values on each run, and lists in values files are replaced, not merged.
- Go modules with a `replace` to a path outside the repo are skipped by CI (`bridges/ax-adapter`).

## Where things are tracked

- Issues are the single backlog. Milestones are releases (0.3 to 0.6 and Backlog); each has a tracking issue.
- Labels (`.github/labels.yml`): one `kind/...`, at least one `area/...`, a `priority/p0..p2`, and `status/...`; plus `good first issue`, `help wanted`, `adapter`.
- Decisions: `docs/decisions` (ADRs). History and proof: `docs/diary` (`timeline.md`, `features/`, `what-works.md`). Changes: `CHANGELOG.md`.
- Maintainers: [MAINTAINERS.md](MAINTAINERS.md). Decisions follow [GOVERNANCE.md](GOVERNANCE.md).
