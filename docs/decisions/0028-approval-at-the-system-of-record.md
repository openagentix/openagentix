# ADR 0028: approval stays in the system of record; the platform gives a result contract and a trace link

Status: Proposed
Date: 2026-11-28
Issue: https://github.com/openagentix/openagentix/issues/12 (`ApprovalRequest`), reference use cases #229
Replaces: none. Changes the plan for `ApprovalRequest` in ADR 0012 ("Reserved") and ADR 0013 (release 0.4): the kind stays reserved, and the part "created by the controller when a run reaches a tool that needs approval" is deferred with the conditions in "When the platform kind comes back". See "Relation to other records".

The act that needs a person's approval (a credit, a parts order, a claim) is approved in the system that owns the record, as the reference use cases already do. The platform does not hold tool calls. It gives three small things: a documented shape for the approval a tool returns (`approval` with `id`, `status`, `payload_sha256` and a few more), the rules a system of record follows to be a safe approval point, and a trace link from an approval to the run that asked for it, if the tool server forwards the trace context. Nothing here is built. Everything is *unverified* until the slices below are done.

## Context

### What was built in the use cases

Read in `examples/use-cases/records/internal/core/approvals.go` and `auth.go` on 2026-11-28. One queue serves the bank and the equipment domains.

| Rule | How the records service does it |
|---|---|
| The approver reads what the record says, not what the model wrote | `Hooks.Describe` builds the payload (JSON text) from the record and returns the record's version. The queue stores the text, its SHA-256 and the version |
| The approver approves what they saw | `Approve` takes the hash the approver sends; it must equal the stored hash |
| Nothing changed since | At decision time `Describe` runs again; a different version or hash refuses the decision ("the record changed after this was proposed") |
| A change cancels the request | `SupersedePending` marks the pending request `superseded` in the same transaction as any write that changes what the approver was shown |
| One request at a time | A second proposal for a subject with a pending one is refused |
| A role per kind of act | `RoleFor(kind)`; a token whose role differs is refused |
| No self-approval | The proposer cannot decide; agents propose as `agent`, which can never be an approver id |
| Decision and act together | The status change is a conditional update in the same transaction as `Execute` (or `Reject`) |
| No tool decides | The decision routes are REST on the pod's loopback; no MCP tool approves or rejects |
| The approver is named | Bearer tokens checked in constant time against SHA-256 hashes in a file, each with an id and a role |

What the first real-model run showed (`examples/use-cases/bank/README.md`, "The first real-model run"): in case 0005 the agent requested approval and then retried a write. The write superseded the request, and the answer still said the request was pending. The fix put a notice in the write's result and told the agent to read `get_approval` before reporting. The evaluation set cannot say "when the answer says pending, the state must be pending" as one rule.

What the examples do not have, and say so: the approver is whoever holds a token from a Secret; a proposal from the pod's loopback without a token is not checked for separation of duties; the audit actor of every MCP call is `agent`, so the record cannot tell which agent or run proposed (`examples/use-cases/records/README.md`, "Safety design"; `internal/core/audit.go`).

### What the platform has

- ADR 0012 reserved `ApprovalRequest` for 0.4: "created by the controller when a run reaches a tool that needs approval, or by a product for its own gate". Issue #12 asks for the CRD, the controller and an expired request.
- `AgentRun` does not exist. A run is an A2A task in the runtime. kagent keeps a task that waits for input, but a turn that is running when the runtime restarts is lost (ADR 0012, "Limits and risks").
- The tool server (ToolHive vMCP 0.67.1) has no way to hold a call for a person. It does not forward the caller's identity to the backend (ADR 0025 Amendment 1, ADR 0026). Its audit line names the session actor and the tool, never arguments when content capture is off.
- The vMCP continues the incoming trace in its own span (ADR 0003, result C). Whether it sends `traceparent` on to the backend is *unverified*.
- `status.capabilities.approvals` is a reported runtime fact on `AgentDefinition` (`services/control-plane/internal/api/types.go`), meaning a tool call can wait for a person's decision. It is not set from anything in this record.
- No person has an identity at the platform today. Console login with OpenID Connect is planned for 0.4 (ADR 0013).

### What a hold at the tool gateway would have to solve

Compared honestly with the system of record:

1. **What the approver sees.** At the gateway the only facts are the tool's arguments, written by a model that may have read injected text. The record's own state (is the charge inside the scheme window, is the machine covered) is what the approver needs, and only the record can compute it. To show it, the gateway would have to ask the record to describe the act, which puts the approval logic back in the record.
2. **Time of check and time of use.** The record can change between the hold and the release. The records service handles this with the version and the hash at decision time. A gateway hold would need the same from the record.
3. **Waiting.** A held tool call keeps the model's turn open. A runtime restart loses the turn, and the call's timeout ends it. A hold of hours or days needs `AgentRun`, durable waits and a resume path, none of which exist.
4. **Release.** The gateway would replay the call later with the backend credential, so it must store the arguments (content the platform does not store today) and the act happens outside the record's own transaction.
5. **Identity.** Kubernetes RBAC could keep the requester and the approver apart on an `ApprovalRequest`, and an admission policy could check that a recorded `decidedBy` equals the user who wrote it. That works for people who use the Kubernetes API. Most approvers are not such people.
6. **Upstream.** ToolHive has no hold. It would be a fork, a new proxy in front of every endpoint, or MCP elicitation through the vMCP and the runtime, whose support is *unverified*.

Where a platform hold is the right answer: an act whose backend has no approval of its own (a chat message, a write to the cluster, a merge). For those, ADR 0012 already names the safer pattern: the agent gets the right to propose (a pull request, a change request), and the act happens in a system that has its own review.

General practice, stated without naming products because none were checked for this record: systems that move money or commit stock (core banking, ERP purchasing) keep the checker step next to the record, with limits per role and the decision tied to the record's state. The records service copies that shape.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `ApprovalRequest` kind, created by the controller when a run reaches a tool marked for approval; the tool server holds the call | One place for every approval; RBAC separates requester and approver | Points 1 to 6 above; needs `AgentRun`, durable waits, a store of held arguments, a release path with the backend credential, and a hold feature ToolHive does not have | `approvals.go`, ADR 0012, ADR 0025 Amendment 1, ADR 0026 |
| B. Approval in the system of record, nothing from the platform | Nothing to build; matches what was built | Every builder invents the result shape; evaluation and the console cannot read approvals in one way; nothing links an approval to its run | The three use cases |
| C. B, plus a result contract, a rule list and a trace link | Small; works with any runtime and any tool server; evaluation, the console and a later `AgentRun` can read one shape; the approver still sees the record's truth | One public contract (the JSON member names of the result); one doc to keep true; the trace link depends on an upstream fact that is *unverified* | This record |
| D. MCP elicitation: the tool server asks the user mid-call | In the protocol | A person must be in the conversation; the runtime and vMCP support is *unverified*; still a hold with points 3 and 5 | Not tried |

## Decision

Option C. Approval stays in the system of record. The platform owns the three parts below and nothing more in this record.

### 1. The approval result (a public contract)

A tool that asks for an approval, reads one, or changes a record in a way that cancels one returns these members in the JSON object of its result (the MCP `structuredContent`, and the same JSON as its text content):

```json
{
  "approval": {
    "id": "APR-0007",
    "status": "pending",
    "subject": "SVC-2026-0007",
    "kind": "parts_order_with_claim",
    "payload_sha256": "3f1c...e9",
    "proposed_by": "agent",
    "decided_by": "",
    "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"
  },
  "superseded_approvals": ["APR-0006"]
}
```

| Member | Rule |
|---|---|
| `approval` | Present in the result of a tool that creates or reads one request. Absent otherwise |
| `approval.id` | Opaque to the platform, 1 to 64 characters from `A-Z a-z 0-9 . _ : -` |
| `approval.status` | Exactly one of `pending`, `approved`, `rejected`, `superseded`, `expired`. Only `pending` waits for a person |
| `approval.subject` | The record the act is about, in the same alphabet, 1 to 64 characters |
| `approval.kind` | The kind of act, lower case, digits and `_`, 1 to 64 characters |
| `approval.payload_sha256` | 64 lower-case hex characters: the SHA-256 of the exact payload text the approver reads |
| `approval.proposed_by`, `approval.decided_by` | Opaque ids from the record's own authentication. `decided_by` is empty until a decision. The platform never treats them as verified people |
| `approval.trace_id` | The W3C trace id (32 lower-case hex) of the call that proposed it, or `unknown` when the record did not receive one |
| `superseded_approvals` | Present in the result of a write that superseded one or more pending requests: their ids. An agent that sees it must not report those requests as pending |

Text written by people stays outside these members or under names that start with `untrusted_`, as the records services do. The contract carries no payload text and no amount: those are the record's business and the approver reads them in the record.

The names use the snake case of the existing tool results. The platform reads only these members; a tool may return more.

### 2. The rules a system of record follows

A guide in `docs/diary/guide/` states the rules of the table in "What was built" as the conditions for calling a system "an approval point" in OpenAgentix docs, and names the records service as the reference implementation whose tests show each rule. Two rules are added from the review of the examples:

- A proposal from any door (REST, MCP, a script) carries an authenticated proposer, and the proposer can never decide it. (The examples' loopback exception is listed as an example limit.)
- No MCP tool of an agent's profile decides, releases or executes an approved act. The decision is a separate door with its own authentication.

The platform does not check these rules in a running system. They are what a use case must show before its docs may say "stops at an approval".

### 3. The trace link

The record stores the trace id of the request that proposed the act and returns it as `approval.trace_id`. With it, `hack/trace-turn.sh` finds the run (gate audit line, runtime spans, model calls) that asked for a given approval. This needs the tool server to send `traceparent` to the backend. Slice 3 checks it. If ToolHive 0.67.1 does not forward it, the field is `unknown` and the link waits for an upstream change; the record says so and nothing else changes. Baggage stays off (ADR 0003): `traceparent` holds ids only.

### What changes in the evaluation tool

`tools/oa-eval` gains one optional member on a state check, `when_answer`: a regular expression; the check runs only when the answer matches it. So "when the answer says pending, a pending request must exist" is one rule:

```yaml
state_checks:
  - {url: "/approvals?case_id=DSP-2026-0005&status=pending", path: approvals, count: 1, when_answer: "(?i)pending approval"}
```

This is a change of the evaluation file format, not of a resource.

### What must not be claimed

Docs, the README, the diary and talks say "the reference use cases stop at an approval request in their system of record". They must not say:

- that OpenAgentix has human approval, approval gates, or holds tool calls for approval;
- that an approver is a verified person (in the examples, an approver is whoever holds a token from a Secret);
- that separation of duties holds beyond what the record enforces;
- that the approver saw everything that matters (in the bank, gap items the agent writes are not in the hashed payload);
- that an agent cannot act without approval in general (only that the tools of these profiles cannot perform the act; an endpoint with a write tool and no approval is the builder's risk, ADR 0026 A8);
- that the approval audit is complete or tamper-evident;
- that `status.capabilities.approvals` is true for any runtime because of this record.

### When the platform kind comes back

`ApprovalRequest` stays reserved with the shape of ADR 0012. Issue #12 is re-scoped to this record. The controller-created hold is reconsidered when all of these hold:

1. a reference use case must act on a backend that has no approval of its own, and the propose-then-review pattern does not fit;
2. `AgentRun` exists and a run can wait across a runtime restart;
3. a person has an identity at the platform (console login, or Kubernetes users with an admission check that `decidedBy` equals the writer);
4. the tool server can hold a call without a fork, or a design shows how the act runs inside the backend's own transaction.

## Consequences

- Possible: any system of record that follows the rules can be the approval point for an agent, with any runtime; evaluation, a later console page and a later `AgentRun` read one shape; an approval can be traced to its run when the trace context reaches the record.
- Ruled out for now: a platform hold on tool calls; a controller-created `ApprovalRequest`; approval of acts whose backend has no approval of its own (use propose-then-review instead).
- Harder: every builder of a system of record must implement the queue. The records service is the copyable reference, under Apache-2.0 in this repository.
- Security impact: none at runtime. The platform enforces nothing new. The record gets the trace id of the proposing call, which is an id, not content. The claims list narrows what the docs may say.
- Compatibility: the records services rename `payload_hash` to `payload_sha256` and add `superseded_approvals` and `trace_id` (example code, slice 2). No platform user changes anything.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0012 | `ApprovalRequest` stays reserved; its "created by the controller" path is deferred under the four conditions above. "Approval: the object is platform, the routing is product" still holds for products that create their own requests later |
| ADR 0013 | Removes `ApprovalRequest` from what 0.4 must deliver; the release plan's other 0.4 items are unchanged |
| ADR 0003 | The trace link uses `traceparent` only; baggage stays off |
| ADR 0026 | The records services are the endpoints of `mcp.endpoints`; threat A8 (an endpoint write tool without approval) is the builder's risk |
| ADR 0027 (proposed) | An event run ends at an approval request in the record |

## Slices

Each slice is one pull request, tests first.

1. **This record.** Docs build. Issue #12 re-scoped in its text.
2. **The guide and the reference.** `docs/diary/guide/approval-at-the-system-of-record.md` with the contract and the rules; the records services return the members of section 1 (`payload_sha256`, `superseded_approvals`, `trace_id` as `unknown` until slice 3); a test per member and per status; the bank and equipment tool descriptions and prompts use the members; the claims list goes into the README section on use cases.
3. **Spike: does the vMCP forward `traceparent` to an endpoint?** On a throwaway kind cluster with its own kubeconfig: an echo endpoint behind `mcp.endpoints` logs whether a `traceparent` arrived and whether its trace id equals the gate's. If yes, the records service stores it with the proposal (example code) and `hack/trace-turn.sh` gains a lookup by approval id. If no, the diary says so and the field stays `unknown`.
4. **`oa-eval` `when_answer`.** Unit tests (matches, does not match, bad pattern refused with exit 2); the bank case 0005 gets the rule; replay tests in `examples/use-cases/records/replay` show it fails for the answer of the real-model defect.

## Not checked / open points

- *Unverified*: `traceparent` forwarding by ToolHive 0.67.1 to an `MCPServerEntry` backend; whether kagent puts a tool's `structuredContent` or its text content in front of the model (the use cases saw `{"output":{...}}`, ADR 0026 findings).
- *Unverified*: MCP elicitation support in kagent 1.0.1 and ToolHive 0.67.1 (option D).
- The general practice of core banking and ERP approval was not checked against any product's documentation for this record; read it before quoting.

## Questions for the maintainer

1. **Is approval in the system of record the platform's answer for 0.4, with `ApprovalRequest` deferred under the four conditions?** Recommended: yes. A gateway hold would show the approver the model's arguments, not the record's truth, and needs runs, durable waits and approver identity that do not exist.
2. **Re-scope issue #12 to this record, or close it and open a new one later?** Recommended: re-scope it, keep the reserved name, and list the four conditions in the issue.
3. **Make the result shape a platform contract now, with only example code using it?** Recommended: yes. The names are cheap to fix now and expensive once a console page and `AgentRun` read them.
4. **Does a "stops at an approval" claim need a security review of the system of record?** Recommended: yes, an independent review of the approval routes before a use case's docs say it.
5. **The software organisation's acting agents (wave 2 of #229)**: approval at a record, or propose a change for review in Git? Recommended: propose in Git (a pull request to a GitOps repository) with the forge's review as the approval point, per ADR 0012.
6. **Review window.** Recommended: 7 days. It changes a release promise of ADR 0013.
