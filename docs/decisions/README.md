# Decision records

This directory holds the Architecture Decision Records (ADRs) of OpenAgentix. An ADR is a short document that says what was decided, why, what else was considered, and what is still open. It is the place to look when someone asks "why is it like this?".

## When an ADR is required

Write an ADR before code when a change:

- adds or changes a **resource kind** in `openagentix.io`, or an **adapter interface** (the places where an upstream tool can be exchanged);
- is **security-relevant**: it changes who can call what, a default, what is recorded, what leaves the cluster, or the trust between components;
- changes a **public contract**: a field of a resource, a chart value, an API route, an event type, a label key;
- **adopts or replaces an upstream component** (a runtime, a gateway, a database, an identity or policy engine);
- changes the **scope of a release** or the editions rule.

Bug fixes, tests, documentation and changes that follow an accepted ADR do not need one. If you are not sure, open an issue and ask.

## Life cycle

1. **Issue.** Open an issue with the `kind/design` label (use the "Design proposal" template). It states the problem, not the solution. Triage adds `status/needs-design` while the question is open.
2. **Draft.** Copy [`0000-template.md`](0000-template.md) to the next free number, `NNNN-short-title.md`, set the status to `Proposed`, and open a pull request. One ADR per pull request. Link the issue.
3. **Discussion.** Review happens in the pull request. Objections give a reason and, if possible, an alternative. The pull request stays open at least 7 days for a change to a public resource, a default or the security model (see [GOVERNANCE.md](https://github.com/openagentix/openagentix/blob/main/GOVERNANCE.md)).
4. **Decision.** A maintainer merges the pull request with the status set to one of:
   - `Accepted`: the direction is decided. Slices are then built, each with tests.
   - `Rejected`: kept in the repository, with the reasons, so the question is not asked again from scratch.
   - `Superseded by ADR NNNN`: a later ADR replaced it. The old file stays and gets a note at the top that links the new one.
5. **After acceptance.** Results of each slice are added to the ADR or to the diary. A status such as "Accepted as direction" means nothing has been built yet; the text then says what is *unverified*.

An accepted ADR is not final. Change it with a new ADR that says which one it replaces.

## Numbering and names

- Four digits, in the order the pull requests are opened: `0013-...`. Take the next free number when you open the pull request; if two pull requests collide, the later one renumbers.
- File name: `NNNN-short-title.md`, lower case, words joined by hyphens.
- The first line is `# ADR NNNN: title`. Then the status, the date, and the sections of the template.
- Do not renumber or delete an accepted ADR.

## What to write

Follow the style of the existing records:

- Plain words. Short sentences.
- Say what you measured and what you did not. Mark anything not yet run on a cluster as *unverified*.
- Give each option its cost, not only its benefit.
- Say what the decision rules out.
- No secrets, personal data or private plans in an ADR. It is public.

## Index

| No. | Title | Status | Date |
|---|---|---|---|
| [0001](0001-agent-runtime-kagent-vs-ax.md) | Agent runtime for the MVP: kagent over Google AX | Accepted for the MVP | 2026-11-22 |
| [0002](0002-schedules-and-trigger-delivery.md) | Scheduled runs and delivery of results from triggered agents | Accepted (schedules and notify implemented) | 2026-11-22 |
| [0003](0003-observability.md) | Observability: cost per agent, one trace per turn, tool audit | Accepted for the first slice | 2026-11-23 |
| [0004](0004-knowledge-graph.md) | Knowledge graph in the knowledge base | Implemented and tested | 2026-11-23 |
| [0005](0005-runtime-speed-kagent-vs-ax.md) | Runtime speed, kagent versus AX, and whether to build on AX | Accepted: continue with kagent | 2026-11-23 |
| [0006](0006-governance.md) | Governance: who may call an agent, which tools, where it may connect, what it remembers, what is recorded | Rounds 1 to 3 implemented, opt-in | 2026-11-24 |
| [0007](0007-control-plane-and-agent-builder.md) | Control plane and agent builder | Accepted | 2026-11-25 |
| [0008](0008-model-routing-and-gateways.md) | Model routing, and one gateway or two | Accepted as direction | 2026-11-25 |
| [0009](0009-finops-and-agent-tracing.md) | Cost, FinOps and agent tracing | Accepted as direction | 2026-11-25 |
| [0010](0010-community-and-enterprise-editions.md) | Community and enterprise editions | Accepted as direction (changed by 0011) | 2026-11-25 |
| [0011](0011-foundation-readiness.md) | Readiness for a foundation | Accepted as direction | 2026-11-25 |
| [0012](0012-platform-primitives-for-agentic-delivery.md) | Platform primitives for products built on OpenAgentix | Accepted | 2026-11-25 |
| [0013](0013-focus-and-runtime-neutrality.md) | One focus, bring your own agent, adopted identity | Accepted | 2026-11-25 |
| [0014](0014-quick-start-profile.md) | A quick start profile that needs no paid key and no chat token | Accepted | 2026-11-25 |

Dates and statuses are copied from the first lines of each file. If they differ, the file is right; fix this table.
