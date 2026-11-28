---
title: Approval at the system of record
sidebar_position: 9.6
description: The result a tool returns for an approval (version v1alpha1, with a JSON Schema), the rules a system of record follows to be an approval point, which test in the reference use cases shows each rule, and what the docs must not claim.
---

# Approval at the system of record

The decision is [ADR 0028](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0028-approval-at-the-system-of-record.md). An act that needs a person (a credit, a parts order, a claim) is approved in the system that owns the record. The platform does not hold tool calls. It gives three small things: the result convention on this page, the rules below, and (later, see "Not built") a trace link.

Status: the convention is called `v1alpha1`. Nothing in the platform reads it yet. The two reference records services return it and are tested against its JSON Schema. It becomes a platform contract in the record that adds the first platform reader.

## The result convention (v1alpha1)

The JSON Schema is [`approval-result-v1alpha1.schema.json`](https://github.com/openagentix/openagentix/blob/main/docs/diary/guide/approval-result-v1alpha1.schema.json). A tool that asks for an approval, reads one, or changes a record in a way that cancels one returns these members in the JSON object of its result (the MCP structured content, and the same JSON as its text content):

```json
{
  "approval": {
    "id": "APR-0007",
    "status": "pending",
    "subject": "SVC-2026-0007",
    "kind": "parts_order_with_claim",
    "payload_hash": "3f1c...e9",
    "proposed_by": "agent",
    "decided_by": "",
    "trace_id": "unknown"
  },
  "superseded_approvals": ["APR-0006"]
}
```

| Member | Rule |
|---|---|
| `approval` | In the result of a tool that creates or reads one request (`request_approval`, `get_approval`). Absent otherwise |
| `approval.id` | Opaque to the platform. 1 to 64 characters from `A-Z a-z 0-9 . _ : -` |
| `approval.status` | One of `pending`, `approved`, `rejected`, `superseded`, `expired`. Only `pending` waits for a person. The reference records services never produce `expired` (they do not expire requests) |
| `approval.subject` | The record the act is about, same alphabet, 1 to 64 characters |
| `approval.kind` | The kind of act: lower case, digits and `_`, 1 to 64 characters |
| `approval.payload_hash` | 64 lower-case hex characters: the SHA-256 of the exact payload text the approver reads. The name is the one the records services, their REST decision body, `ctl.sh` and the evaluation files already use |
| `approval.proposed_by`, `approval.decided_by` | Opaque ids from the record's own authentication. `decided_by` is an empty string until a decision. The platform never treats them as verified people |
| `approval.trace_id` | The W3C trace id of the call that proposed the act, or `unknown`. The reference services return `unknown` today (see "Not built") |
| `superseded_approvals` | In the result of a write that superseded one or more pending requests: their ids. It is absent when none was. An agent that sees it must not report those requests as pending |

Text written by people stays outside these members or under names that start with `untrusted_`. The convention carries no payload text and no amount. A tool may return more members (the reference services also return the drafts and facts the approver reads, under `untrusted_` names, and `next`, `notice`, `amount_cents`). The platform reads only the members above.

Where the reference services return it: `request_approval` and `get_approval` of the bank (`records_*`) and the equipment (`dealer-records_*`) tools return `approval`. Every write tool of the bank that can cancel a request, and every write tool of the equipment service, returns `superseded_approvals` when it did. The bank also keeps its `notice` text for the model.

How it is tested: `examples/use-cases/records/replay/approval_convention_test.go` calls the real tools of both services through MCP and validates the structured content and the text content against the schema, for a new request, for a read of each status (`pending`, `approved`, `rejected`, `superseded`), and for a write that supersedes a request and one that does not. It also checks that `payload_hash` equals the SHA-256 of the payload the approver reads over REST, and that a schema with a wrong status, hash, id, kind or trace id refuses them.

## The rules of an approval point

A system may be called "an approval point" in OpenAgentix docs when it follows these rules. The reference implementation is the records service in `examples/use-cases/records` (one queue, `internal/core/approvals.go`, for the bank and the equipment domain). The platform does not check the rules in a running system. They are what a use case must show before its docs say "stops at an approval". The last column names the tests in `examples/use-cases/records` that show the examples meet the rule.

| # | Rule | How the examples meet it | Tests |
|---|---|---|---|
| 1 | The record, not the model, checks the act (window, coverage, stock, amount bound) | The payload is built from the record when the act is proposed and again when it is decided | bank `TestOutOfTimeChargeCannotBeCreditedOrChargedBack`, `TestOutOfTimeDeclineIsAllowedAndPayloadCarriesTheRecordFacts`; equipment `TestWarrantyIsDecidedByTheRecord`, `TestSupersededPartCannotBeOrdered`, `TestApprovalNeedsEveryPiece` |
| 2 | The approver approves what they saw | `Approve` takes the hash the approver sends and it must equal the stored hash of the stored payload | core `TestApprovalShowsFrozenPayloadAndHashMatches`, `TestApprovalGuards`; bank `TestApprovalViewCarriesWhatTheHashCovers`, `TestOldHashAfterReproposalFails`; replay `TestCtlRefusesAnApprovalWhoseHashDoesNotCoverThePayload` |
| 3 | Nothing changed since | At decision time the payload is built again; a different version or hash refuses the decision | core `TestApprovalStaleWhenSubjectChanged`; equipment `TestStockChangeAfterProposalRefusesApproval`, and `TestApprovalSurvivesMonthCountAndOtherCasesTakingStock` (a change that does not touch what the approver saw does not block) |
| 4 | A change cancels the request | A write that changes what the approver was shown marks the pending request `superseded` in the same transaction, and the tool result names it | core `TestSupersedeMarksPendingStale`; bank `TestAnyChangeAfterProposalSupersedesIt`, `TestRedraftAfterProposalInvalidatesApproval`, `TestAWriteAfterTheRequestTellsTheAgentThatItSupersededTheRequest`; equipment `TestAnyChangeAfterProposalSupersedesIt`; replay `TestBankApprovalResultsFollowTheConvention`, `TestEquipmentApprovalResultsFollowTheConvention` |
| 5 | One request at a time | A second proposal for a subject with a pending one is refused | core `TestApprovalGuards` |
| 6 | A role per kind of act | `RoleFor(kind)`; a token whose role differs is refused | core `TestApprovalGuards`; bank `TestRESTRejectNeedsTokenAndRole`, `TestRESTApprovalAuthentication`; equipment `TestRESTApprovalAuthentication` |
| 7 | No self-approval | The proposer cannot decide; agents propose as `agent`, which is never an approver id | core `TestApproverCannotDecideOwnProposal`; bank `TestApproverCannotApproveTheirOwnProposal`; equipment `TestRESTProposalNeedsATokenFromOutsideThePodAndOwnProposalsAreBlocked` |
| 8 | Decision and act together | The status change is a conditional update in the same transaction as the act (or the rejection) | core `TestApprovalExecuteFailureRollsBack`, `TestApprovalNothingExecutesBeforeApproval`; bank and equipment `TestTwoApprovalsAtOnceExecuteOnce` |
| 9 | No tool decides | The decision routes are REST on the pod's loopback; no MCP tool approves, rejects, releases or executes | bank `TestMCPToolsHaveNoMoneyOrSendTool`, `TestRESTHasNoUnauthenticatedMoneyRoute`; equipment `TestMCPToolsCannotReleaseAnything`, `TestRESTFaultEventsValidationAndNoReleaseRoutes` |
| 10 | The approver has an id and a role | Bearer tokens are compared in constant time with SHA-256 hashes in a file, each with an id and a role | core `TestApproversAuthenticate`, `TestLoadApproversRejectsBadFiles`, `TestFailedLoginsAreCountedAndNeverLockOutAValidToken` |
| 11 | A proposal from any door carries an authenticated proposer, and the proposer can never decide it | Partly met. A proposal from outside the pod over REST needs a token. A proposal over MCP is made as the fixed id `agent`, behind the endpoint credential. A proposal from the pod's loopback needs no token | core `TestProposerNeedsATokenUnlessLoopback`; bank `TestRESTProposalNeedsATokenFromOutsideThePod`; equipment `TestSpoofedForwardingHeadersDoNotMakeACallerLoopback`. The limit has its own test: equipment `TestLoopbackProposalThenSelfApprovalIsTheDocumentedLimit` |
| 12 | No MCP tool of an agent's profile decides, releases or executes an approved act. The decision is a separate door with its own authentication | Met by the same tests as rule 9, and by the tool profiles that list only the tools of the agent | bank `TestMCPToolsHaveNoMoneyOrSendTool`; equipment `TestMCPToolsCannotReleaseAnything`; the checks "no tool of the agent could move money or send a letter" (bank) and "no tool of the agent could release anything" (equipment) in `examples/use-cases/*/tests/run.sh` |

## What the examples do not meet

These are limits of the examples, not claims. Each one is shown by the code or the README of `examples/use-cases/records`.

- **Rule 11, the loopback door.** A proposal from the pod's loopback needs no token, and the same pod can then be used to decide it with a token it holds. Equipment `TestLoopbackProposalThenSelfApprovalIsTheDocumentedLimit` shows this. Agents do not use that door, but the record does not enforce it.
- **The proposer of an MCP call is `agent`.** The audit actor of every MCP call is `agent`, so the record cannot tell which agent or which run proposed.
- **The approver is whoever holds a token.** The token is read from a Secret. Nothing proves a person.
- **The approver does not see everything.** In the bank, gap items the agent writes are not in the hashed payload. The payload holds drafts and reasons the agent wrote, which may carry text aimed at the approver. The defence is the approver's own reading.
- **No expiry.** A pending request waits until someone decides it. The status `expired` is in the convention for other systems.
- **The approval audit is not complete and not tamper-evident.**

## What the docs must not claim

Docs, the README, the diary and talks may say "the reference use cases stop at an approval request in their system of record". They must not say:

- that OpenAgentix has human approval, approval gates, or holds tool calls for approval;
- that an approver is a verified person (an approver is whoever holds, or can read from a Secret, a token);
- that separation of duties holds beyond what the record enforces;
- that the approver saw everything that matters;
- that an agent cannot act without approval in general (only that the tools of these profiles cannot perform the act; an endpoint with a write tool and no approval is the builder's risk);
- that the approval audit is complete or tamper-evident;
- that `status.capabilities.approvals` is true for any runtime because of this;
- that the approver reads only the record's own facts;
- that a matching `payload_hash` shows a person read the payload (it shows only that the approver's client fetched the same text);
- that requests expire or are time-bound;
- that `trace_id` proves which run or which caller proposed (the caller of the gate chooses the trace id, so it is a lookup hint, not evidence);
- that every write of an agent waits for approval (in the equipment service, `create_work_order`, `open_proactive_case`, `set_diagnosis` and `set_timer` write without one).

## Where a platform hold would be the right answer

For an act whose backend has no approval of its own (a chat message, a write to the cluster, a merge), ADR 0012 names the safer pattern: the agent gets the right to propose (a pull request, a change request), and the act happens in a system that has its own review. ADR 0028 lists the four conditions under which a controller-created `ApprovalRequest` is reconsidered.

## Not built

- **The trace link** (ADR 0028, slice 3). The records services return `trace_id: unknown`. Storing the trace id of the proposing call needs the tool server to forward `traceparent` to the endpoint, which is not verified for ToolHive 0.67.1. It waits for the spike that checks it.
- **A platform reader.** Nothing in the platform reads the convention. The console, `AgentRun` or the evaluation tool will.
- **A check of a running system.** The platform does not test that a system follows the rules.
