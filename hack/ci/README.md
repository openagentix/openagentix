# CI

Workflows are in `.github/workflows/`. Every check also runs locally through the root `Makefile` (`make help`).

## What runs where

| Job (`ci.yml`) | Does | Local equivalent | Typical time |
|---|---|---|---|
| `changes` | decides whether the change is docs-only; emits the Go module and Dockerfile matrices | `hack/ci/changes.sh`, `hack/ci/go-modules.sh --json` | under 1 min |
| `go` (one per module) | `gofmt`, `go vet`, `go test ./... -race -count=1`, coverage artifact | `make lint-go test-go` | 1-3 min each |
| `chart` | `helm lint`, `charts/openagentix/tests/run.sh` | `make test-chart` | 2 min |
| `guard` | the control plane's admission guard is **executed**: `helm template` of the demo values, the rendered ValidatingAdmissionPolicies evaluated with the Kubernetes CEL code (`hack/ci/guardtest`, its own Go module), cases from the kagent adapter's golden files (allowed writes of every kind and verb, one refusal per field of the security review) | `make test-guard` | 2 min |
| `apiserver` | the AgentDefinition CRD and the guard against a real API server: a throwaway kind cluster (`oa-ci-test`, one node, no controller image, no model), server-side validation, `status.typeChecking`, the example definition, invalid definitions, impersonated writes as the controller's ServiceAccount (`hack/ci/apiserver-test.sh`) | `make test-apiserver` | 3-5 min |
| `shell` | channels, dashboard and bench tests, shellcheck report (non-blocking) | `make test-shell lint-shell` | 2-3 min |
| `integration` | kb tests against PostgreSQL+pgvector, memory-expiry job (Docker) | `make test-integration` | 3-6 min |
| `secrets` | gitleaks over the pushed commit range, honours `.gitleaksignore` | `make secrets` | under 1 min |
| `python-samples` | the Python sample agent: its pinned requirements install with `--require-hashes`, 20 pytest tests, a contract test against a built `services/stub-model` | `make test-python-samples` | 1 min |
| `images` (one per Dockerfile) | `docker buildx build`, linux/amd64, nothing pushed (Dockerfiles with a Go build stage, or with the comment line `# ci-build:`, like the Python sample). The context is the Dockerfile's directory unless it has a `# build-context: <path>` comment line (the console image builds from the repo root `.`) | `docker build -f <dir>/Dockerfile <context>` | 1-3 min each |
| `console` | `pnpm install --frozen-lockfile`, `pnpm lint`, `pnpm check`, `pnpm test` (vitest), `pnpm build` | `make test-console` | 2-3 min |
| `console-audit` | `pnpm audit --prod` (blocking), full `pnpm audit` (report only) | `cd console && pnpm audit --prod` | under 1 min |
| `console-e2e` | builds the web app, installs Chromium with its libraries, runs Playwright against the Go binary in demo mode; uploads the report on failure | `make test-console-e2e` | 4-6 min |
| `docs` | builds the Docusaurus site (`npm ci && npm run build` in `website/`, Node 22) so a broken link or broken markdown link fails the pull request; nothing is deployed (`docs.yml` deploys from `main`). Runs when `docs/`, `website/`, `CHANGELOG.md`, `ci.yml` or `docs.yml` changed (the `docs` output of `changes`), docs-only changes included | `cd website && npm ci && npm run build` | 2-3 min |
| `ci-ok` | passes when every job above passed or was skipped | | seconds |

The branch protection rule for `main` requires **`ci-ok`** and **`DCO`** (the DCO check is its own workflow, not part of `ci-ok`). Docs-only changes (`docs/`, `website/`, `*.md`,
`LICENSE`) skip everything except `secrets` and `docs`; `ci-ok` still passes. Superseded runs of the same ref are cancelled.
`docs.yml` is separate and untouched. `e2e.yml` is the keyless end-to-end install (see "e2e" below); it is NOT in `ci-ok` yet.

## release (tag to images, chart and release)

`.github/workflows/release.yml` runs on a pushed tag `vX.Y.Z` and by hand (a manual run is always a dry run: it builds, and it never pushes or releases). Jobs: `verify` (`hack/release-notes.sh` checks the semantic version tag and the `## [X.Y.Z]` changelog section; the tag must be on `main`), `checks` (calls `ci.yml`), `images` (one per Dockerfile except `examples/`, pushed to `ghcr.io/openagentix/<name>:X.Y.Z`, digest kept as an artifact, linux/amd64), `chart` (`helm package --version --app-version` from the tag, `helm push` to `oci://ghcr.io/openagentix/charts`), `assets` (`SHA256SUMS` over the chart package, the SBOMs and the digest list, signed with `cosign sign-blob` and attested), `release` (runs `hack/verify-release.sh` on every image, the chart and `SHA256SUMS`, then `gh release create` with the changelog section and the digest list as the body and those files attached). Signing ([ADR 0018](../../docs/decisions/0018-release-signing-and-sbom.md)): `images` and `chart` sign each pushed digest with keyless cosign v3.1.4 (`sigstore/cosign-installer`), `images` makes an SPDX SBOM with syft 1.57.0 (`hack/ci/install-tools.sh syft`, SHA-256 checked) and attaches it with `cosign attest --type spdxjson`, and `actions/attest-build-provenance` adds SLSA provenance. The release images are built with `no-cache: true` (no cache from CI runs), buildx v0.39.0, BuildKit v0.35.0 by digest, and the Dockerfile frontend 1.29.0 by digest through the `BUILDKIT_SYNTAX` build argument. Permissions: `contents: read` everywhere, `packages: write` only in `images` and `chart`, `id-token: write` and `attestations: write` only in `images`, `chart` and `assets`, `contents: write` (plus `packages: read` and `attestations: read` for the check) only in `release`; the only secret is `GITHUB_TOKEN`. Local checks: `hack/ci/release-notes-test.sh` and `hack/ci/verify-release-test.sh` (fake cosign and gh; both in `make test-shell`), `hack/release-notes.sh v0.2.0` prints a section, `hack/verify-release.sh --dry-run --tag v0.3.0 <ref@sha256:...>` prints the verify commands. Users verify with [Verify a release](../../docs/diary/guide/verify-release.md). The whole process, step by step, is in [workflow.md](../../docs/contributing/workflow.md#releases). It has not run on a real tag yet.

## e2e (keyless quick start)

`.github/workflows/e2e.yml` installs the quick start on a hosted `ubuntu-24.04` runner with no key and no token (`PROFILE=quickstart ./install.sh`, the stub model; a matrix also runs `PROFILE=minimal`, issue #29), then runs `hack/ci/smoke.sh`: the agent is Ready, a question is answered through the A2A gate with a tool call, a tool outside the profile returns nothing, a forbidden definition is refused, the console API answers 401 without the token and lists the agent with it. It runs on pull requests that touch install-relevant paths, nightly, and by hand. The job summary has the time to the first working agent and the install steps with their times. After the smoke test it runs `hack/demo.sh` (the demo walkthrough, `docs/diary/guide/demo.md`) and prints the phases of the time to the first working agent (`hack/ci/phases.sh`; the offline tests are `hack/ci/phases-test.sh` and `hack/demo-test.sh`, both in `make test-shell`). Local equivalent: `PROFILE=quickstart ./install.sh && hack/ci/smoke.sh && hack/demo.sh`. The record of the runs, including gVisor on the runner, is below.

## e2e-k3s (the quick start on k3s)

`.github/workflows/e2e-k3s.yml` is the same install and smoke test as `e2e`, on k3s in Docker made by k3d (`CLUSTER_TYPE=k3d`, `hack/cluster.sh`), with the sample container agent (`QUICKSTART_BYO=1`, `SMOKE_BYO=1`). It then runs `hack/ci/netpol-test.sh`, which checks live whether the cluster enforces NetworkPolicy for ingress and for egress to the internet. The job shows its real result (issue #195: `continue-on-error` is gone, so it is no longer always green). It is not in `ci-ok` and is not a required check of `main` (those are `ci-ok` and `DCO`), so a red run does not block a merge. A red run means the install, the anonymous-access check (issue #189), the smoke test or the NetworkPolicy test failed on k3s: open the failed step and the job summary. Before this change the job was green even when it failed (13 of 23 completed runs failed unseen), so older runs of it say nothing; the four runs after the fix of #189 were green. Do not merge a pull request that touches the installer with this check red unless you know why. It runs nightly, by hand, and on pull requests that touch the installer or the cluster helper. Local equivalent: `CLUSTER_TYPE=k3d CLUSTER=oa-k3s-test PROFILE=quickstart ./install.sh && hack/ci/smoke.sh` (use a `KUBECONFIG` file of your own; do not run it beside another cluster in a small Docker VM). The record of the runs is in [Install on k3s](../../docs/diary/guide/install-k3s.md).

## Nightly runs and the green streak

`e2e.yml` (03:17 UTC) and `e2e-k3s.yml` (03:47 UTC) have a `schedule:` trigger. The cron lines are valid, both files are on `main`, Actions is enabled for the repository with all actions allowed, and both workflows are active. Even so, the Actions API listed no run with event `schedule` for either workflow on 2026-11-26, about 22 hours after the first possible tick. We could not find a setting that explains it. GitHub does not promise that a scheduled run starts on time, and it can drop one when its queue is busy. So the claim is only this: no nightly run has been seen yet. Check again after 03:50 UTC on the next day: `hack/ci/green-streak.sh` prints a warning for `e2e` and `e2e-k3s` while the window holds no `schedule` run, and it prints the date of the newest one when there is one. If a night passes with no run, start the workflow by hand (`gh workflow run e2e.yml`) and record the gap in issue #196.

`hack/ci/green-streak.sh` counts the green runs in a row on `main` for `ci`, `docs`, `e2e` and `e2e-k3s`. It is the check for the release 0.3 exit criterion "30 green runs on main".

```
hack/ci/green-streak.sh                    # text, one line per workflow
hack/ci/green-streak.sh --json             # the same as JSON
hack/ci/green-streak.sh --target 30 --check ci docs   # exit 1 when ci or docs is below 30
```

How to read a line, for example `ci  17 in a row  (target 30, not met)  counted 62  last red: <run url>`:

- The streak is the number of green runs before the first red one, newest first. The link is the run that ended it.
- Cancelled, skipped and still running runs are ignored. They do not add to the streak and they do not break it. Pull request runs are ignored too.
- `counted` is how many runs the window held (`--limit`, default 100). A streak equal to `counted` may be longer than shown.
- `e2e` and `e2e-k3s` run on `main` only at night or by hand, so 30 green runs of them take 30 nights. A manual run counts like a nightly one.

The offline test is `hack/ci/green-streak-test.sh` (in `make test-shell`).

## Tools and pins

`helm` v3.22.0 (`azure/setup-helm`), `jq` from the runner image (1.7.x), `yq` **kislyuk 3.4.3** (the Python jq wrapper that
the chart tests and `install.sh` use, never mikefarah's; `pip install yq==3.4.3`), gitleaks 8.30.1, shellcheck 0.11.0, kind 0.33.0, k3d 5.9.0, syft 1.57.0 (release only); cosign v3.1.4 comes from `sigstore/cosign-installer`, which checks it.
The five binaries are installed by `hack/ci/install-tools.sh` and verified by SHA-256. Go comes from each module's `go.mod`; Node is 22
(same as `docs.yml`, npm with `website/package-lock.json`). Actions are pinned by commit SHA with the version in a comment;
Dependabot (`.github/dependabot.yml`) proposes updates weekly, grouped.

## Run it locally

```
make test              # go + chart + shell, all offline
make test-integration  # needs a running Docker daemon
make test-guard        # the control plane's admission guard, executed (needs helm and go)
make test-apiserver    # the CRD and the guard on a real API server in a throwaway kind cluster (needs kind, kubectl, helm, docker, jq, yq)
make lint              # gofmt, go vet, shellcheck (shellcheck only reports until the tree is clean; SHELLCHECK_STRICT=1 enforces)
make secrets           # needs gitleaks
```

The dashboard test runs its jsdom part only when `website/node_modules` exists (`cd website && npm ci`).

## Add a Go service

Create the module (`go.mod`) and a Dockerfile. Nothing else: `hack/ci/go-modules.sh` finds every `go.mod` (not under `spikes/` or
`node_modules`), and `hack/ci/dockerfiles.sh` finds every Dockerfile with a `FROM golang... AS build` stage. Add the module's
directory to `.github/dependabot.yml` (it cannot discover modules). A module whose `go.mod` has a `replace` to a path outside the
repository is skipped with a message (today `bridges/ax-adapter`, which needs a local AX checkout and a prebuilt binary). To skip
something else, add its directory to `hack/ci/go-modules.skip`. `hack/ci/guardtest` is listed there on purpose: it is a test harness with
its own pinned dependencies (`k8s.io/apiserver`), run by `make test-guard`, never part of the service matrix.

For a service with PostgreSQL-backed tests, gate them on an environment variable and `t.Skip` when it is unset (as `services/kb`
does), then add a Docker-based target to the `integration` job.

## Not built yet

- **e2e as a required check.** It runs but is not in `ci-ok` until it has passed reliably (see "e2e").
- **arm64 images.** Only linux/amd64 is built. The Dockerfiles do not pin a platform, so arm64 on a hosted amd64 runner means QEMU
  emulation; use an arm64 runner (`ubuntu-24.04-arm`) in the `images` matrix when that is needed.
