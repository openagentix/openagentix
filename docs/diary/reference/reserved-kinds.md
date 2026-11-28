---
title: Reserved kinds and fields
sidebar_position: 6
description: Resource kinds, fields and events that OpenAgentix has designed but not built, with the planned shape and the issue that tracks each one.
---

# Reserved kinds and fields

Everything on this page has the status **reserved (designed, not built)**. No CRD, controller or event exists for it on `main`. Do not write a manifest for it and do not depend on it.

:::caution Fields may change
The shapes below are copied from the design records (ADR 0012 and ADR 0013). They show the plan. Names, fields and release numbers may change before anything is built. A kind that is built starts at `v1alpha1`, where the [API conventions](./api-conventions.md) allow changes.
:::

The platform group is `openagentix.io`. Each kind will have its own version. The release numbers are the plan of ADR 0012 and ADR 0013. The issue numbers are in the repository `openagentix/openagentix`.

| Name | Kind of thing | Planned release | Status | Tracking issue |
|---|---|---|---|---|
| `AgentRun` | resource | 0.4 | reserved | [#11](https://github.com/openagentix/openagentix/issues/11) |
| `ApprovalRequest` | resource | not before `AgentRun` and identity (ADR 0028) | reserved; approval stays in the system of record for now | [#12](https://github.com/openagentix/openagentix/issues/12) |
| `AgentAccess` | resource | 0.3 | reserved | [#3](https://github.com/openagentix/openagentix/issues/3) |
| `Schedule` | resource | 0.3 | reserved (schedules exist today only as chart values) | [#4](https://github.com/openagentix/openagentix/issues/4) |
| `Trigger` | resource | 0.4 | reserved (channels exist today only as chart values) | [#16](https://github.com/openagentix/openagentix/issues/16) |
| `CredentialGrant` | resource | 0.4 | reserved | [#14](https://github.com/openagentix/openagentix/issues/14) |
| `Workspace` | resource | 0.5 | reserved | [#20](https://github.com/openagentix/openagentix/issues/20) |
| `Budget` | resource | 0.5 | reserved | [#22](https://github.com/openagentix/openagentix/issues/22) |
| `PlatformPolicy` | resource (scoped policy) | 0.5 | reserved (the policy exists today as chart values, see [Platform policy](./platform-policy.md)) | no own issue; release tracking [#67](https://github.com/openagentix/openagentix/issues/67) |
| run and approval events | CloudEvents | 0.4 | reserved | [#15](https://github.com/openagentix/openagentix/issues/15) |
| `spec.delegates` on `AgentDefinition` | field | 0.5 | reserved | [#23](https://github.com/openagentix/openagentix/issues/23) |
| `spec.runtime` on `AgentDefinition` (bring your own agent) | field | 0.3 | reserved on `main` | [#43](https://github.com/openagentix/openagentix/issues/43), first slice [#106](https://github.com/openagentix/openagentix/issues/106) |
| run side of the runtime adapter, conformance suite | adapter contract | 0.4 | reserved | [#18](https://github.com/openagentix/openagentix/issues/18), [#27](https://github.com/openagentix/openagentix/issues/27) |

## `AgentRun`

Reserved. The unit a product creates, watches, cancels, approves against, bills and audits. Runs are for governed or unattended work. Chat stays plain A2A. The conversation stays in the runtime's task store, not in the resource. Finished runs are removed after a time to live.

Planned shape (ADR 0012):

```yaml
apiVersion: openagentix.io/v1alpha1
kind: AgentRun
metadata:
  name: wi-123-code
  labels: {openagentix.io/work-item: wi-123}
  ownerReferences: []           # the product's own object
spec:
  agentRef: {name: coder}       # same namespace
  input: {text: "..."}          # bounded; never a secret
  contextRef: {run: wi-123-plan}   # continue a conversation and its workspace
  parentRef: {name: wi-123}        # the run that delegated this one
  workspaceRef: {name: wi-123}
  onBehalfOf: {userId: ""}         # honoured only under an access rule
  limits: {deadline: 2h, maxTokens: 2000000, maxToolCalls: 500}
  budgetRef: {name: project-a}
  priority: 0
  suspend: false                # queued, not started
  cancel: false                 # set to true to cancel; a run is never deleted to cancel it
  ttlSecondsAfterFinished: 604800
status:
  phase: Queued                 # Queued, then the A2A task states
  conditions: []                # Admitted, Started, Finished
  task: {contextId: "", taskId: ""}
  agentRevision: ""
  usage: {inputTokens: 0, outputTokens: 0, costUSD: "0", toolCalls: 0}
  pendingInput: {kind: approval, requestRef: {name: ""}}
  provenance: {models: [], skills: [], toolProfile: "", traceId: ""}
  result: {summary: "", artifacts: []}
```

The text `"..."` is a placeholder, so this block is not a valid manifest. `status.agentRevision` is meant to hold the `status.revision` of the [AgentDefinition](./agentdefinition.md) that did the work.

## `ApprovalRequest`

Reserved. Created by the controller when a run reaches a tool that needs approval, or by a product for its own gate. It names what is to be approved, who may approve, when it expires and what happens then (deny, or escalate). The approver sets the decision and a reason. The controller records who decided. It is its own kind so that Kubernetes access rules can keep the person who starts a run apart from the person who approves.

No field list is decided yet.

## `AgentAccess`

Reserved. The A2A gate's caller rules as a resource: callers, agents, the user id rule and the allowed methods. `Schedule` needs it, and a product's controller becomes a caller with the task methods (get, cancel, subscribe).

Today the same rules are chart values, `governance.a2a.callers[]`. See the [A2A gate reference](./a2a-gate.md). No field list is decided yet beyond the four parts above.

## `Schedule`

Reserved. A schedule says which agent gets which message at which time. The controller will turn it into the CronJob and the access rule it needs. A schedule needs an `AgentAccess` rule and will fail with a clear condition if it has none. The chart values `schedules[]` keep working for at least one release after the kind exists (issue #4). No field list is decided yet. How delivery works today is in ADR 0002.

## `Trigger`

Reserved. Creates an `AgentRun` from a webhook, a schedule or another source. It will replace the Kourier channel values with a resource. It depends on `AgentRun`. No field list is decided yet.

## `CredentialGrant`

Reserved. A grant names a subject (an agent or a run), a source (a Secret, a vault path, a Git provider application), an audience, scopes, a lifetime and where it is injected (at the egress proxy, for one host). No value ever appears in a spec or a status. No field list is decided yet beyond this list of parts.

## `Workspace`

Reserved. A workspace has sources (Git, an OCI artifact, object storage), a size and a retention time. With the kagent adapter it is the session's durable directory. No field list is decided yet beyond this list of parts.

## `Budget`

Reserved. A budget can select runs by label, which gives cost per work item. Today a token budget is a setting of the model gateway key. No field list is decided yet.

## `PlatformPolicy`

Reserved. The policy gets a scope (a namespace or a label selector) and tool rules (allow, require approval, deny). The most restrictive rule wins. Today the policy is the set of chart values `controlPlane.policy` and applies to the whole platform. No field list is decided yet.

## Events

Reserved. Status and conditions are the contract. Kubernetes Events are informational only. For the outside world the platform will send CloudEvents through an event sink adapter. These types are reserved:

| Type | Meaning |
|---|---|
| `io.openagentix.run.v1alpha1.queued` | a run was accepted and waits |
| `io.openagentix.run.v1alpha1.started` | a run started |
| `io.openagentix.run.v1alpha1.input_required` | a run waits for input |
| `io.openagentix.run.v1alpha1.succeeded` | a run finished well |
| `io.openagentix.run.v1alpha1.failed` | a run failed |
| `io.openagentix.run.v1alpha1.canceled` | a run was canceled |
| `io.openagentix.approval.v1alpha1.requested` | an approval was asked for |
| `io.openagentix.approval.v1alpha1.decided` | an approval was decided |
| `io.openagentix.approval.v1alpha1.expired` | an approval ran out of time |

The one-line meanings are written for this page. The design record gives only the type names. An event carries the run's namespace and name and a trace reference, never content.

## `spec.delegates`

Reserved. `AgentDefinition.spec.delegates` will list the agents this one may call. The authority of a delegated run is the intersection of the caller's limits and the callee's definition. The user id passes through unchanged, and the chain is recorded in `parentRef` of the run. It needs an identity per agent. The runtime gives one per session today. Whether agent-to-agent calls pass around the gate's caller rules through the egress proxy is **not verified**, and is to be checked first.

## Bring your own agent: `spec.runtime`

Reserved on `main`. ADR 0013 plans that an `AgentDefinition` can describe an agent that is not built by the platform: a container that speaks A2A, built with any framework. The same policy, tool profile, egress rules, gateway key and status contract would apply. kagent stays the default runtime.

The work is on a branch (`byo-agent-slice1`) and has not been merged. The field is **not** in the schema on `main`, so a definition that sets it is refused by the API server as an unknown field. The design record for it, ADR 0015, is not on `main` yet, so the tracking issues are the reference: [#43](https://github.com/openagentix/openagentix/issues/43) and [#106](https://github.com/openagentix/openagentix/issues/106). When it is merged, this page and the [AgentDefinition reference](./agentdefinition.md) will change.

## Console plugins

Reserved. ADR 0012 plans first a generic read-only console page for any allowlisted resource kind, and later a `ConsolePlugin` kind that names navigation entries and one backend service. Neither exists.

## Other items that are not built

ADR 0013 postpones these. They are not reserved kinds, but you may meet their names:

- Editing models, tools, knowledge sources and skills from the console (the kinds `ModelProvider`, `ModelRoute`, `ToolServer`, `ToolProfile`, `KnowledgeCollection`, `KnowledgeSource`, `Skill`, `ObservabilitySettings`, `NotifyDestination`). The console shows these areas read-only or as not available.
- Identity per agent and token exchange, through an `Identity` adapter (release 0.4, issue [#13](https://github.com/openagentix/openagentix/issues/13)).
