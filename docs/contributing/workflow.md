# How we work

This page says how work moves from an idea to a release. It follows [GOVERNANCE.md](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md) and [CONTRIBUTING.md](https://github.com/openagentix/openagentix/blob/main/CONTRIBUTING.md); if they differ, those two win. The project has one maintainer today, and this page says what that means.

## Issues are the backlog

Every piece of planned work is a GitHub issue. There is no second list. [docs/roadmap.md](../roadmap.md) says what each release is for; the issues, grouped in milestones, say what is left to do.

- **Milestones** are releases: `0.3 Control plane and console`, `0.4 Runs and trust`, `0.5 Work`, `0.6 Lifecycle and quality`, and `Backlog` for work that has no release yet. They have no due dates. Each release has one tracking issue, "Release 0.x tracking", with a task list.
- **Labels** are defined in [`.github/labels.yml`](https://github.com/openagentix/openagentix/blob/main/.github/labels.yml). Each issue has one `kind/...`, at least one `area/...`, and a `priority/...` once triaged.

| Label group | Meaning |
|---|---|
| `kind/bug`, `kind/feature`, `kind/design`, `kind/docs`, `kind/test`, `kind/chore`, `kind/security-hardening` | what sort of work it is. `kind/design` needs or is a decision record (see [docs/decisions](../decisions/README.md)). `kind/security-hardening` is for non-sensitive hardening only. |
| `area/...` | which part of the system: control plane, console, runtime, model gateway, tools, knowledge, memory, channels, schedules, governance, observability, install, ci, docs, community |
| `priority/p0` | blocks the current release or adoption |
| `priority/p1` | planned for the milestone |
| `priority/p2` | useful, can wait |
| `status/needs-triage` | set automatically on new issues from the templates |
| `status/needs-design` | a decision is needed before work starts |
| `status/accepted` | a maintainer accepted it; it is ready to be worked on |
| `status/blocked` | waiting on something else; the issue says what |
| `good first issue` | small and self-contained, with pointers to the files and how to test |
| `help wanted` | open to outside contributors |
| `adapter` | a place where an outside contributor can add an integration |

## Triage

New issues get `status/needs-triage`. A maintainer (or a reviewer, once there are some) goes through them and:

1. checks for a duplicate, and closes it with a link if so;
2. asks for what is missing (version, steps, logs without secrets);
3. sets one `kind`, one or more `area`, a `priority`, and a milestone;
4. replaces `status/needs-triage` with `status/accepted` or `status/needs-design`, or closes the issue with the reason;
5. adds `good first issue` or `help wanted` when it fits, after the issue says which files to change and how to test.

Who can do what, from [GOVERNANCE.md](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md): anyone can open issues, comment and send pull requests. Setting labels and milestones needs the triage or write role on the repository, which maintainers have. Reviewers listed in `.github/CODEOWNERS` approve changes in their areas. A maintainer merges.

First-time contributors get a first response in 3 working days. If you want to take an issue, say so in a comment. No one is assigned by the project; a comment is enough, and if there is no news for a few weeks anyone may take it.

A report of a security problem never goes in a public issue. See "Security fixes" below.

## Branches and pull requests

- **One pull request per issue.** The description starts with `Closes #123` or `Refs #123`. Keep it small.
- **Branch names**: `<type>/<issue-number>-<short-words>`, with the type from the conventional commit list: `feat/123-agent-access`, `fix/145-installer-digest`, `docs/150-glossary`. Work from a fork or from a branch; do not push to `main`.
- **Commits** use [Conventional Commits](https://www.conventionalcommits.org/) with the area in brackets, and carry a `Signed-off-by` line (`git commit -s`).
- **Tests first.** A new behaviour or a bug fix comes with a test that failed before the change. The pull request shows the command and its output.
- **Decisions first.** A change that needs an ADR (see [docs/decisions/README.md](../decisions/README.md)) is not merged before the ADR is accepted.

## Required checks

Two checks must pass before a merge:

| Check | What it does | If it fails |
|---|---|---|
| `ci-ok` | all the jobs in `ci.yml` passed or were skipped ([hack/ci/README.md](https://github.com/openagentix/openagentix/blob/main/hack/ci/README.md)) | open the failed job, run the same step locally with `make test` or `make lint` |
| `DCO` | every commit in the pull request has a `Signed-off-by` line that matches its author | `git rebase --signoff main` then `git push --force-with-lease`; for the last commit only: `git commit --amend -s --no-edit` |

The branch protection rule for `main` requires both `ci-ok` and `DCO`. The workflow files may change over time; the rule is the source of truth.

## Review

Be honest about the limits of a one-maintainer project:

- **The maintainer cannot approve their own pull request.** GitHub does not count it, and it would not be a review.
- **Until there is a second maintainer or a reviewer for the area**, pull requests by the maintainer are merged after `ci-ok` and DCO pass, and after a waiting time for comments:
  - at least 2 working days for a normal change;
  - at least 7 days for a design change: an ADR, a public resource, a default, or the security model (the same times as in [GOVERNANCE.md](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md));
  - a security fix may be merged at once and explained afterwards.
- The pull request says that this rule is being used, so nobody reads a merge as a review.
- **Pull requests from other people** need an approval from a maintainer or a reviewer for that area, and no unanswered objection. Silence for the waiting time is agreement (lazy consensus).
- Review checks: does it do what the issue says; is there a test that fails without it; is it off by default and deny by default where that applies; does a change in behaviour have docs and a changelog line; is there a secret or personal data in the change, the description or the logs.
- Feedback is checked against the code before it is applied. A reviewer who is wrong is told why, in plain words.

The goal is to end this exception. See "Growing the maintainer group" in [GOVERNANCE.md](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md).

## Merging

- **Squash merge** into `main`. The squashed title is a conventional-commit title, for example `feat(control-plane): add AgentAccess`. The issue number goes at the end: `(#123)`. Keep the sign-off line in the squashed message: the repository setting is "default to pull request title" for the title and "all commit messages" for the body, so the squash commit lists the pull request's own commits, with their `Signed-off-by` lines.
- **How the `DCO` check treats commits** (`hack/ci/dco-check.sh`, tested by `hack/ci/dco-test.sh`). A commit passes when (a) it has a `Signed-off-by` line that matches its author, (b) it is a merge commit, (c) its author is a bot, or (d) GitHub made it (committer `noreply@github.com`, a squash merge of another pull request into your branch) and its title ends in `(#N)` for a pull request of this repository that was merged as exactly this commit and whose own commits are all signed off. The workflow checks (d) through the API with the read-only default token; if it cannot, the commit fails. Typing `(#N)` in your own commit does not help.
- **Changelog.** Anything a user can see needs a line under `[Unreleased]` in [CHANGELOG.md](https://github.com/openagentix/openagentix/blob/main/CHANGELOG.md), in the pull request itself. Breaking changes and upgrade steps go under "Upgrade notes". Pure test, CI and internal changes do not need a line.
- Delete the branch after the merge. The issue closes from `Closes #123`; if it does not, close it and say which pull request fixed it.

## Releases

1. Check that the milestone's tracking issue has every item done, or moved to a later milestone with a comment.
2. Write the release section in `CHANGELOG.md` first: version, date, what was added, changed, fixed, upgrade notes, security. The changelog is updated before the release is made.
3. Run `make test` (and the cluster checks that the release claims). Anything proven on a cluster has its limits written down.
4. Choose the version by [semantic versioning](https://semver.org/). While the version is 0.x, a minor release can change interfaces and the upgrade notes say how.
5. Tag `vX.Y.Z` from `main` (the tag itself is not signed yet; the artefacts are, by the workflow) and push the tag. Any `v*` tag that is pushed, on any commit, runs the workflow of that commit and gets a signature that verifies, so the repository has a ruleset named `release-tags` for `refs/tags/v*` (set on 2026-11-26): only repository admins may create a tag, and update, delete and force-push are blocked. The tag push starts the release workflow (below); you do not create the GitHub release by hand.
6. Watch the `release` run. When it is green, check the release page, pull one image by digest and verify it as [Verify a release](../diary/guide/verify-release.md) says. New packages on ghcr.io may be private: make them public in the organisation's package settings, then verify again without a login.
7. Close the milestone and the tracking issue. Open the next tracking issue if there is none.

### What the release workflow does

`.github/workflows/release.yml` runs on a tag that looks like `vX.Y.Z` (or `vX.Y.Z-rc.1`). It uses only the `GITHUB_TOKEN`.

1. **verify.** `hack/release-notes.sh` checks that the tag is a semantic version and that `CHANGELOG.md` has a non-empty `## [X.Y.Z]` section for it. It fails if not, so write the section before you tag. It also checks that the tagged commit is on `main`.
2. **checks.** The same jobs as a pull request (`ci.yml`, called as a reusable workflow).
3. **images.** Each service image is built and pushed to `ghcr.io/openagentix/<name>` with the tag `X.Y.Z`, and its digest is recorded. The images are the Dockerfiles that `hack/ci/dockerfiles.sh` finds, except the samples under `examples/`. linux/amd64 only.
4. **chart.** `helm package` sets `version` and `appVersion` from the tag, then the chart is pushed to `oci://ghcr.io/openagentix/charts/openagentix`.
5. **Signing and SBOM** ([ADR 0018](../decisions/0018-release-signing-and-sbom.md)). Each image digest and the chart digest is signed with keyless cosign by the job that pushed it. syft makes an SPDX SBOM of each image, attached as a cosign attestation. Each image and the chart get a SLSA build provenance attestation. The `assets` job writes `SHA256SUMS` over the chart package, the SBOMs and the image digest list, signs it (`SHA256SUMS.sigstore.json`) and attests each file.
6. **release.** Before the GitHub release is created (the images and the chart are already pushed by then), `hack/verify-release.sh` checks every image, the chart and `SHA256SUMS`; one missing signature, SBOM or provenance stops the release. Then the GitHub release is created for the tag, with those files attached. Its body is the changelog section, then a list of the image references by digest, the chart reference and a link to [how to verify a release](../diary/guide/verify-release.md). A tag with a `-` in it (such as `-rc.1`) is marked as a pre-release.

If a job fails, nothing later runs. Fix the cause. Do not move or force-push a tag: if images were already pushed, make a new patch version. A tag whose release failed before the last step can be removed by a maintainer with the delete-tag permission and made again, only if no image was pushed.

**Dry run.** In the Actions tab, run `release` by hand ("Run workflow") on any branch and give a version that has a changelog section. A manual run builds every image and the chart and prints the release body in the job summary, but it never logs in to the registry, pushes, signs, or creates a release. It still makes the SBOMs from the built images and the `SHA256SUMS` file, and its summary says what would be signed and prints the verify commands. Do this before the first tag of a release.

**What is not here yet.** The signing steps have not run on a real tag. The git tag is not signed. There is no arm64 image. The chart's default image values still point at `openagentix/<name>:dev`, so install from the chart with the image values set until the chart defaults follow the release (see [what works](../diary/what-works.md): the workflow is unproven until a real tag runs).

## Security fixes

- A vulnerability is reported through [private vulnerability reporting](https://github.com/openagentix/openagentix/security/advisories/new), as [SECURITY.md](https://github.com/openagentix/openagentix/blob/main/SECURITY.md) says. It is never discussed in a public issue or pull request.
- The fix is prepared in the private advisory. A maintainer may merge a security fix without the waiting time.
- After the fix is released, the advisory is published and a public issue is opened that describes the problem, the fix and the version. Only then do details become public.
- Non-sensitive hardening (a pinned image, a missing test, a tighter default that closes no known hole) is a normal public issue with the `kind/security-hardening` label.
- If you are not sure whether something is sensitive, report it privately.

## Design proposals

Larger changes start with an issue from the "Design proposal" template, and an ADR when the rules in [docs/decisions/README.md](../decisions/README.md) say so. Integrations (a notify destination, a tool server entry, a knowledge loader, a runtime adapter) start with the "Adapter request" template. Work on them in slices, each with its tests and its entry in the diary.
