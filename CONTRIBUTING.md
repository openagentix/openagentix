# Contributing to OpenAgentix

Thank you for looking. OpenAgentix is a new project with one maintainer, and it wants more. This page says how to build it, how to send a change, and how you can become a maintainer.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). How the project is run is in [GOVERNANCE.md](GOVERNANCE.md). Who the maintainers are is in [MAINTAINERS.md](MAINTAINERS.md).

## Where to start

New here? Follow [Your first contribution in an hour](docs/diary/guide/first-contribution.md): tools, offline tests, picking an issue, the DCO sign-off, and what review to expect. Ready-made starter tasks are listed in [docs/contributing/good-first-issues.md](docs/contributing/good-first-issues.md).

Good first contributions, from easiest to hardest:

- **Documentation.** Fix a wrong or unclear sentence in the README, the diary (`docs/diary`) or an ADR. Add a missing step to a how-to.
- **Tests.** Add a test for a case that is not covered. Chart render assertions (`charts/openagentix/tests/run.sh`) and Go unit tests are both welcome.
- **Adapters.** The platform puts upstream tools behind adapters so that one can be exchanged for another (see [ADR 0007](docs/decisions/0007-control-plane-and-agent-builder.md)). An adapter for another observability stack, vector store, sandbox or notification target is a self-contained piece of work.
- **Connectors and channels.** A new destination for the notify service, or a new channel next to Telegram and signed webhooks. Slack is written but untested: a tester with a Slack workspace helps a lot (see "Channels and triggers" in the README).
- **Bugs.** Run the platform, read "Known limitations" in the README, and report what you find.

If you are unsure where to begin, open a GitHub Discussion or an issue and ask. Small questions are welcome.

## How we work

Issues are the single backlog, grouped in milestones that match the releases in [docs/roadmap.md](docs/roadmap.md). Look for the labels `good first issue`, `help wanted` and `adapter`. How issues are triaged, how branches and pull requests are named and merged, which checks are required, how review works while there is one maintainer, how releases are cut, and how security fixes are handled is written in [docs/contributing/workflow.md](docs/contributing/workflow.md). Decision records have their own guide: [docs/decisions/README.md](docs/decisions/README.md).

[CLAUDE.md](CLAUDE.md) (also pointed to by [AGENTS.md](AGENTS.md)) is a short guide to the repository, its commands and its rules, for AI coding assistants and for new contributors.

## Build and test

You need Go (the modules use Go 1.25 or newer), plus `helm`, `jq` and `yq` for the chart tests. `yq` here is the Python wrapper (`pip install yq==3.4.3`), not mikefarah's `yq`. The full install needs Docker, `kind` and `kubectl`; see the README, "Prerequisites".

Everything that runs offline (no Docker, no cluster):

```sh
make test          # Go tests with -race for every module, the chart render tests, the shell tests
make help          # lists all targets
```

The same checks one at a time:

```sh
charts/openagentix/tests/run.sh               # shell assertions over `helm template`
helm lint charts/openagentix
(cd services/a2a-gate && make test)           # the A2A gate
(cd services/control-plane && make test)      # the control plane
(cd tools/a2a-call && make test)              # the schedule caller
(cd services/kb && go test -race ./...)       # the knowledge base
(cd services/notify && go test -race ./...)   # the notify service
(cd bridges/telegram && go test -race ./...)  # the Telegram bridge
```

Needs Docker:

```sh
charts/openagentix/tests/memory-expiry-integration.sh   # starts and stops its own PostgreSQL
```

Needs a cluster (a kind node, see the README "Try it in 10 minutes" and "Full demo install"). Run these only if your change touches the installer or the live behaviour, and say in the pull request what you ran and what you saw.

```sh
./install.sh
```

You do not need a cluster, a model key or a Telegram token to contribute code, tests or docs.

## Test first

New behaviour comes with a test, and the test is written first.

1. Write one test that fails. Run it. Check that it fails for the right reason.
2. Write the smallest change that makes it pass. Run all tests.
3. Clean up. Keep the tests green.

For a bug fix, write a test that reproduces the bug before you fix it. Chart changes need render assertions in `charts/openagentix/tests/run.sh`. A change that is off by default must leave the default render byte-identical to before, and the tests check that.

Do not claim "it works" without showing the command and its output. In the pull request, paste what you ran.

## Commits and pull requests

- Use [Conventional Commits](https://www.conventionalcommits.org/): `feat(chart): ...`, `fix(bridge): ...`, `docs: ...`, `test: ...`, `chore: ...`. Put the area in brackets. Keep the first line short.
- One logical change per pull request. Small pull requests get reviewed faster.
- Fill in the pull request template: what and why, the tests you ran, DCO sign-off, docs and changelog, security impact.
- Add a line to `CHANGELOG.md` under `[Unreleased]` for anything a user can see.
- Update the README or `docs/` when behaviour changes.
- Never put a secret, key or token in a commit, an issue or a log line. The repository has a secret scan (`gitleaks`).
- Defaults matter: new features are off by default, deny by default, and capture no content by default.

### Developer Certificate of Origin (DCO)

Every commit needs a `Signed-off-by` line. It says you wrote the change, or have the right to submit it, under the project's licence (Apache-2.0). The rules are the [Developer Certificate of Origin, version 1.1](https://developercertificate.org/). Read them there. This repository does not copy or change that text.

Add the line with `-s`:

```sh
git commit -s -m "fix(chart): short summary"
```

This adds `Signed-off-by: Your Name <your-address>` using your `user.name` and `user.email` from git. The address must be the one in your git configuration. To fix the last commit: `git commit --amend -s --no-edit`. For several commits: `git rebase --signoff main`.

Pull requests with unsigned commits cannot be merged. Commits before 2026-11-25 predate this rule.

## How decisions are recorded

Design decisions live as Architecture Decision Records in [`docs/decisions`](docs/decisions), one file per decision, numbered `NNNN-short-title.md`.

- Write an ADR before code for anything that changes a public resource (a kind in `openagentix.io`, a chart value, an API), adds a dependency, or changes a security default.
- An ADR has a status line, the context, the options with their costs, the decision, and what it rules out. Say what you measured and what you did not. Copy the shape of an existing one.
- ADRs are reviewed in a pull request like code. Maintainers decide by lazy consensus (see [GOVERNANCE.md](GOVERNANCE.md)).
- A decision is not final because it is accepted. A later ADR can replace it. Say which one it replaces.

## Proposing a larger change

1. Open an issue or Discussion with the problem first, not the solution. Say who has the problem and what you tried.
2. If maintainers agree it is worth doing, write an ADR as a pull request. Keep it short.
3. When the ADR is accepted, build it in slices. Each slice has its tests, its README or diary entry, and (where possible) a proof on a cluster with the limits written down.

Changes that touch the security model (ADR 0006), the resource kinds, or the editions rule ([ADR 0010](docs/decisions/0010-community-and-enterprise-editions.md)) need an ADR every time.

## Security problems

Do not open a public issue for a vulnerability. Follow [SECURITY.md](SECURITY.md).

## From contributor to maintainer

The full rules are in [GOVERNANCE.md](GOVERNANCE.md). In short:

1. **Contributor.** Anyone who sends a change, a review, a bug report or a doc fix.
2. **Reviewer.** After a steady record of good reviews and merged work, a maintainer can add you to reviewers for an area. Your approval then counts for that area (an area is a part of the repository, such as `charts/`, `services/kb`, or `docs/`).
3. **Maintainer.** Normally after about six months of regular work: several merged changes of substance, careful reviews of other people's changes, help in issues, and good judgement about security. Any maintainer can nominate you, or you can ask. Existing maintainers decide by lazy consensus, and vote if someone objects.

The project is looking for maintainers from other organisations. If you want that path, say so in an issue or Discussion and a maintainer will help you plan it.
