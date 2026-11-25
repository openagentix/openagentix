# Governance

This page says how OpenAgentix is run. It is a minimum: enough to work with one maintainer today, and to grow into a project with maintainers from several organisations.

## Honest starting point

- The project has one maintainer ([MAINTAINERS.md](MAINTAINERS.md)). Today that person decides everything, within the rules below.
- The project is new. Its public history starts on 2026-11-24.
- The goal is to change this. Section "Growing the maintainer group" says how.
- Nothing here has been adopted by a foundation. If the project joins one, this document will be reviewed against that foundation's charter, and the charter wins where they differ.

## Values

- **Open.** Design, decisions and the roadmap are public, in this repository.
- **Neutral.** No company controls the project. See "Vendor neutrality".
- **Honest.** The README and the diary say what is proven, what is not, and what the limits are.
- **Secure by default.** Security is never held back for a paid edition ([ADR 0010](docs/decisions/0010-community-and-enterprise-editions.md)).

## Roles

### Contributor

Anyone who sends a pull request, a review, an issue, a doc fix or an answer in Discussions. No permission is needed. Contributors follow [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md).

### Reviewer

A contributor who reviews changes in one or more areas (an area is a path, such as `charts/`, `services/kb`, `docs/`). A reviewer's approval counts for the areas they are listed for, but a maintainer still merges. Reviewers are listed in `.github/CODEOWNERS` below the maintainers. A maintainer adds a reviewer after a record of good reviews and merged work in that area, and the reviewer agrees. There is no minimum time.

### Maintainer

Maintainers have write access to the repository. They review and merge, cut releases, handle security reports, enforce the Code of Conduct, and keep the project moving. They are listed in [MAINTAINERS.md](MAINTAINERS.md) with their organisation. A maintainer acts for the project, not for their employer.

Maintainer duties:

- Review pull requests in a reasonable time.
- Follow the security policy and keep reports private.
- Declare a conflict of interest and step out of that decision.
- Keep the project neutral (see below).

## Adding a maintainer

Criteria. A candidate has:

1. A record of merged changes of substance, over at least about six months. Docs, tests, adapters and reviews all count.
2. Careful reviews of other people's changes.
3. Good judgement on security and on keeping defaults safe.
4. Kept to the Code of Conduct, and works well with others.
5. Time to keep it up. This is a commitment, not a title.

Process:

1. Any maintainer can nominate a contributor, or a contributor can ask. This is done in a pull request that adds the person to `MAINTAINERS.md` (and `.github/CODEOWNERS`).
2. The pull request stays open at least 7 days.
3. **Lazy consensus.** If no maintainer objects in that time, it is approved.
4. If a maintainer objects, the maintainers discuss and then **vote**. The candidate needs a simple majority of maintainers (more than half, the candidate not voting). With one maintainer, that maintainer decides, and writes the reason in the pull request.
5. The new maintainer is given write access and told about the security channel.

While the project has fewer than three maintainers, a nomination from a person of the same organisation as every existing maintainer is allowed, but the maintainers will say in the pull request what they are doing to find maintainers elsewhere.

## Removing a maintainer

- **Step down.** A maintainer can leave at any time with a pull request that moves them to the Emeritus list. They are thanked.
- **Inactive.** A maintainer with no review, commit or issue activity for 6 months is asked if they want to stay. With no answer in 30 days they move to Emeritus. They can return by lazy consensus.
- **Removal for cause.** A serious breach of the Code of Conduct, or of the security policy, or repeated bad faith, can lead to removal. Any maintainer can propose it, privately if needed. The other maintainers vote, and a two-thirds majority (not counting the person concerned) removes them. The reason is recorded, in public unless a person's privacy needs otherwise.
- Emeritus maintainers keep no access. Their history stays in `MAINTAINERS.md`.

## Decision making

- **Pull requests and ADRs: lazy consensus.** A change is approved when a maintainer or a reviewer for that area approves it and nobody has objected after a fair time (at least 2 working days for a normal change, 7 days for an ADR or a change to a public resource, a default or the security model). Silence is agreement.
- **Objections** must give a reason and, if possible, an alternative. The people involved try to agree first.
- **When consensus fails: a vote of the maintainers.** One maintainer, one vote. A simple majority decides, unless this document asks for more. A tie means the change does not go ahead. The result and the reasons are written in the pull request or issue.
- **Decision records.** Anything with long-term effect is an ADR in `docs/decisions`. See [CONTRIBUTING.md](CONTRIBUTING.md).
- **Security fixes** may be merged by one maintainer without the waiting time, and explained afterwards.
- **Changing governance** has its own rule, see the last section.

## Technical Steering Committee

The Technical Steering Committee (TSC) is responsible for the technical direction of the project: the roadmap, the resource kinds, scope, releases, the maintainer list, and handling disputes.

- **Today the TSC is the maintainers.** Its members are the people in [MAINTAINERS.md](MAINTAINERS.md), so it has one member.
- **It is meant to include maintainers from more than one organisation.** The aim is that no single organisation holds more than one third of the TSC seats once there are three or more members.
- It decides in the open: its discussions and decisions are in issues, Discussions and pull requests. Meetings, once there are any, are announced in advance and have public notes.
- The TSC may choose a chair. Until then, the maintainers rotate the job for each decision.
- If the project joins a foundation, the TSC works inside that foundation's technical charter.

## Growing the maintainer group

The project wants maintainers from other organisations. The plan:

1. **Make it easy to start.** Keep a list of labelled "good first issue" tasks, favouring adapters, connectors, tests and docs, where nobody needs to know the whole system.
2. **Review fast and kindly.** First-time contributors get a first response in 3 working days.
3. **Name reviewers early.** After a few good contributions, offer the reviewer role for that area.
4. **Open the roadmap.** Roadmap items are public issues. Anyone can take one.
5. **Look outside.** Talk to the teams behind upstream projects and to users who run the platform, and ask whether someone wants to take an area.
6. **Report progress.** Once a year, the maintainers write a short note in `docs/` with the number of contributors, the organisations behind merged changes, and the number of maintainers.

Targets. By the first anniversary of the public repository: at least one merged change from someone outside the original author's organisation, and a second maintainer. Within two years: maintainers from at least two organisations. These are goals, not claims. The count of outside contributors is zero today.

## Vendor neutrality

These rules protect the project from being steered by one company. This includes the company of the original author.

1. **The roadmap is decided in the open by the maintainers** (the TSC). It is not set by a company's product plan. Companies can propose, with the same standing as any contributor.
2. **No feature in this repository may depend on a commercial product.** Nothing here checks a licence key, phones home to a vendor, or stops working without a paid component. Optional adapters for commercial systems are fine when the project works without them.
3. **Community stays community.** What is in this repository stays under the Apache-2.0 licence. Security is never reserved for a paid edition. Nothing moves from community to a paid edition later ([ADR 0010](docs/decisions/0010-community-and-enterprise-editions.md)).
4. **Same rules for the name.** The project name and logos may be used by anyone under the same trademark rules. A company, including the original author's, uses the project name under those rules and not under special rights. A commercial product does not carry the project name as its own name. The accepted form is "`<company or product name>` for OpenAgentix" ([ADR 0011](docs/decisions/0011-foundation-readiness.md)).
5. **Extension points, not forks.** If a vendor needs a change in the core, it is proposed as a general extension point, and it lands here first.
6. **Declare interests.** A maintainer says in a pull request when a change helps their employer, and the other maintainers decide it.
7. **No single-organisation control.** Once there are three or more maintainers, no one organisation may have more than half of the maintainer votes.

If the project joins a foundation, ownership of the name and other assets moves to that foundation as its policy requires.

## How the roadmap is set

- The roadmap is [docs/roadmap.md](docs/roadmap.md). The decisions behind it are the ADRs.
- Anyone can propose a change by an issue, a Discussion or a pull request on the roadmap file.
- Maintainers accept changes by the decision rules above. A release's theme and scope are an ADR-level decision.
- The roadmap says what is built, what is not, and what is planned, and it is updated when that changes.

## Releases

- Releases use [semantic versioning](https://semver.org/). While the version is 0.x, minor releases can change interfaces. Upgrade notes go in `CHANGELOG.md`.
- The changelog is updated before a release is made. A release is a git tag `vX.Y.Z` made by a maintainer.
- Only tested changes are released. Tests must pass (`make test`), and anything proven on a cluster has its limits written down.
- Security fixes may be released as a patch at any time.
- Release images and the chart are signed with keyless cosign, each image has an SPDX SBOM, and every artefact has build provenance ([ADR 0018](docs/decisions/0018-release-signing-and-sbom.md), [how to verify](docs/diary/guide/verify-release.md)). This has not run on a real tag yet. The git tag itself is not signed yet.

## Communication

The channels are GitHub issues, pull requests and Discussions in the repository. There is no chat server or mailing list. Others will be added here if they are created.

## Changing this document

Changes to `GOVERNANCE.md` are pull requests. They stay open at least 14 days, need approval from a majority of all maintainers (not only of those who vote), and any maintainer's objection must be answered in the pull request. With one maintainer, the maintainer decides and says why. Changes that follow from joining a foundation are made as that foundation's rules require.

## Related files

- [CONTRIBUTING.md](CONTRIBUTING.md): how to build, test and send changes.
- [MAINTAINERS.md](MAINTAINERS.md): who the maintainers are.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) and [SECURITY.md](SECURITY.md).
- [docs/foundation/sandbox-thesis.md](docs/foundation/sandbox-thesis.md): a draft thesis for a future foundation proposal.
