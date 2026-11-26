---
title: Your first contribution in an hour
sidebar_position: 9
description: How to clone OpenAgentix, run the offline tests without Docker or a cluster, pick an issue, open a pull request with a DCO sign-off, fix a failed DCO check, and what review to expect.
---

# Your first contribution in an hour

This page takes you from nothing to an open pull request. You do not need Docker, a cluster, a model key or a chat token. A documentation fix or a small test is enough for a first pull request.

The plan, with rough times:

| Step | What | Time |
|---|---|---|
| 1 | Install the tools | 10 minutes |
| 2 | Fork, clone, and run the offline tests | 15 minutes |
| 3 | Pick an issue | 5 minutes |
| 4 | Make the change, test first | 20 minutes |
| 5 | Commit with a sign-off and open the pull request | 10 minutes |

The rules in full are in [CONTRIBUTING.md](https://github.com/openagentix/openagentix/blob/main/CONTRIBUTING.md) and [How we work](https://github.com/openagentix/openagentix/blob/main/docs/contributing/workflow.md). If this page and those two differ, they win.

## 1. Install the tools

What you need depends on what you change. For a documentation change you need only `git`. For the offline tests below you need:

| Tool | Why | Check |
|---|---|---|
| `git` and the `gh` CLI (optional) | clone, fork and open the pull request | `git --version` |
| Go 1.25 or newer | the Go tests | `go version` |
| `helm` 3 | the chart tests | `helm version --short` |
| `jq` | the chart and docs tests | `jq --version` |
| `yq` 3.x, the Python wrapper | the chart and docs tests | `yq --version` shows `yq 3.4.3` |
| `python3` | the shell test suites | `python3 --version` |

Install `yq` with `pip install yq==3.4.3`. It must be the Python wrapper around `jq`, not the Go tool with the same name. `make test-chart` stops with a clear message if it finds the wrong one.

Docker, `kind` and `kubectl` are only for the full install. You do not need them to contribute. See the [quick start](quick-start.md) when you want to try the platform itself.

## 2. Fork, clone, and run the offline tests

Fork the repository on GitHub, then clone your fork and add the project as `upstream`:

```sh
gh repo fork openagentix/openagentix --clone
cd openagentix
git remote -v        # origin is your fork, upstream is openagentix/openagentix
```

Without the `gh` CLI, press "Fork" on GitHub and run `git clone https://github.com/<your-user>/openagentix.git`, then `git remote add upstream https://github.com/openagentix/openagentix.git`.

Run the checks that need no Docker and no cluster. Each one is a `make` target; `make help` lists them all.

```sh
make test-go       # go test -race in every Go module (a few minutes the first time: Go downloads modules)
make test-chart    # helm lint, then about 1,300 shell assertions over `helm template`
hack/docs/tests/run.sh   # the docs drift test: generated reference pages must match the code
```

What you should see:

- `make test-go` prints one `=== go test <module>` line per module and `ok` for each package. A good run has no `FAIL` line and the exit code is 0 (`echo $?`).
- `make test-chart` ends with a line like `passed=1309 failed=0`. The number grows over time; `failed=0` is what matters.
- `hack/docs/tests/run.sh` prints `docs reference tests passed`.

Two more targets are cheap and useful before you push:

```sh
make lint-go       # gofmt and go vet in every module
make lint-shell    # shellcheck on the scripts; a report, it does not fail the build today
```

Everything that runs offline is also available as one command, `make test`. It runs `test-go`, `test-chart` and `test-shell`. `test-shell` has the dashboard checks, and part of those needs `npm ci` in `website/`, which is a large download. Skip `make test-shell` for a first change unless you touch scripts or the dashboard. CI runs it for you.

To run one Go package while you work, go into its module:

```sh
(cd services/notify && go test -race ./internal/sanitize/)
```

The other targets (`test-console`, `test-integration`, `test-guard`, `test-apiserver`, `test-console-e2e`) need Node, Docker or a kind cluster. Run them only when your change touches that area. CI runs all of them on your pull request.

If one of the commands above fails on a clean checkout, that is a bug in the project, not in you. Open an issue with the command and the last lines of output.

## 3. Pick an issue

Issues are the only backlog. There is no second list.

1. Open [issues labelled `good first issue`](https://github.com/openagentix/openagentix/labels/good%20first%20issue). Each one should name the files to change and how to test.
2. Prefer one that says `area/docs` or `kind/test` for a first pull request. They are small, and a failing test tells you when you are done.
3. Comment on the issue: "I would like to take this." No one is assigned by the project. A comment is enough. If there is no news for a few weeks, anyone else may take it.
4. If the issue is unclear, ask in the issue. Small questions are welcome. First-time contributors get a first answer within 3 working days.

Is there no issue for what you want to fix? For a typo or a wrong sentence, open the pull request directly. For anything bigger, open an issue first and say what the problem is. A change to a public resource, a chart value, an API route or a security default needs a decision record (ADR) before code. See [docs/decisions/README.md](https://github.com/openagentix/openagentix/blob/main/docs/decisions/README.md).

Never report a security problem in a public issue or pull request. Use [private vulnerability reporting](https://github.com/openagentix/openagentix/blob/main/SECURITY.md).

## 4. Make the change, test first

Make a branch from the latest `main`. The name is `<type>/<issue-number>-<short-words>`:

```sh
git fetch upstream
git switch -c docs/150-glossary upstream/main
```

Then:

1. **Write one test that fails.** Run it and check that it fails for the right reason. Chart changes get an assertion in `charts/openagentix/tests/run.sh`. Go changes get a `_test.go` file next to the code. A bug fix starts with a test that reproduces the bug.
2. **Write the smallest change that makes it pass.** Run the tests again.
3. **Update the docs.** If a user can see the change, add one line under `[Unreleased]` in `CHANGELOG.md`. If behaviour changes, update the README or the page in `docs/`.

A documentation-only change has no test to write. Read the page again after your edit, and keep to the house style: plain, short sentences, no marketing words, no em dashes.

Do not put a secret, token, chat id, email address or other personal data in a file, a commit message or a pull request. The repository runs a secret scan.

## 5. Commit with a sign-off and open the pull request

Every commit needs a `Signed-off-by` line. It says you wrote the change, or have the right to send it, under the project's licence (Apache-2.0). It is the [Developer Certificate of Origin](https://developercertificate.org/), and it is not a signature or a key. Add it with `-s`:

```sh
git add -A
git commit -s -m "docs: add a glossary of project terms"
```

The title is a [conventional commit](https://www.conventionalcommits.org/): `docs: ...`, `test(notify): ...`, `fix(chart): ...`, `chore: ...`. The sign-off uses `user.name` and `user.email` from your git configuration, so check them first with `git config user.name` and `git config user.email`. The address in the sign-off must be the address of the commit's author.

Push to your fork and open the pull request:

```sh
git push -u origin docs/150-glossary
gh pr create --fill     # or use the link that git prints, or the GitHub web page
```

In the description:

- start with `Closes #150` (or `Refs #150`), with your issue number;
- paste the commands you ran and what you saw, for example `make test-chart` and its last line;
- fill in the checklist honestly. Say "none" under security impact if that is true, and say why.

Do not @-mention people. Keep one change in one pull request.

### What CI does

Two checks must be green before a merge:

| Check | What it checks |
|---|---|
| `ci-ok` | all the jobs of `ci.yml` passed or were skipped. A change that only touches docs skips almost everything and still passes. |
| `DCO` | every commit in the pull request has a `Signed-off-by` line that matches its author |

If `ci-ok` is red, open the failed job. Each job has a local equivalent in the table of [hack/ci/README.md](https://github.com/openagentix/openagentix/blob/main/hack/ci/README.md). Run that step on your machine, fix it, and push another commit.

### Fix a failed DCO check

The check fails when a commit has no `Signed-off-by` line, or when the line does not match the commit's author. Fix it on your own pull request branch only. Never touch `main`.

To fix the last commit:

```sh
git commit --amend -s --no-edit
git push --force-with-lease origin docs/150-glossary
```

To fix every commit of the branch:

```sh
git fetch upstream
git rebase --signoff upstream/main
git push --force-with-lease origin docs/150-glossary
```

`--force-with-lease` is the safe form: it refuses to overwrite commits you have not seen. It is allowed on your own branch, because rewriting your own pull request branch is how this fix works. The project's rule is no force-push to `main`.

If the sign-off line is there but still fails, the name or email on it differs from the commit's author. Run `git log --format='%an <%ae>%n%b' -3` and compare. Set the right values with `git config user.name` and `git config user.email`, then repeat the command above. Add `--reset-author` to the amend if the author itself is wrong.

## What review to expect

- **A first answer in 3 working days.** If you hear nothing after that, comment once on the pull request.
- **A maintainer or reviewer for the area must approve** a pull request from another person. Silence for the waiting time, with no objection, counts as agreement. The waiting time is at least 2 working days for a normal change and at least 7 days for a design change.
- **What a reviewer checks:** does it do what the issue says; is there a test that fails without it; is a new feature off by default; does a change in behaviour have docs and a changelog line; is there a secret or personal data in the change.
- **Feedback is plain.** Reviewers say what to change and why. If you think a comment is wrong, say so and say why. It is checked against the code.
- **Squash merge.** A maintainer merges your pull request as one commit, with a conventional title and your sign-off kept. Your branch is then deleted, and the issue closes from `Closes #N`.

The project has one maintainer today, and it wants more. After a few merged changes and good reviews you can become a reviewer for an area, and later a maintainer. The path is in [GOVERNANCE.md](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md).

## Where to get help

- Questions and ideas: GitHub Discussions.
- A command on this page that does not work as written: open an issue with the "Bug report" template. This page is meant to be exact.
- What each part of the repository is: the repository map in [CLAUDE.md](https://github.com/openagentix/openagentix/blob/main/CLAUDE.md), which also suits human readers.
