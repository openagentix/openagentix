# ADR 0017: Schedule, scheduled agent runs as a resource

Status: Proposed
Date: 2026-11-25
Issue: #4
Replaces: none. Fills in the `Schedule` entry that ADR 0012 reserved for release 0.3. Builds on ADR 0002 (the CronJob approach) and ADR 0016 (`AgentAccess`, still proposed).

A new namespaced kind, `Schedule` (`openagentix.io/v1alpha1`), says which agent gets which message at which times. The controller checks it against policy and writes one CronJob per schedule that calls the agent through the A2A gate. The schedule runs as its own ServiceAccount, and it fires only when an `AgentAccess` that the user created grants that identity the agent. It is off by default. Nothing here is built yet; everything is *unverified* until the slices below are done.

## Context

Facts read in this repository on 2026-11-25:

- Schedules today are the chart values `schedules[]` and `scheduling` (`charts/openagentix/templates/schedules.yaml`, ADR 0002). Each entry renders a prompt ConfigMap `schedule-<name>`, a CronJob `<name>` and, with the A2A gate on, a ServiceAccount `schedule-<name>`, all in `scheduling.namespace` (`openagentix-schedules`). The pod runs `tools/a2a-call`, which sends one `SendMessage` with `X-User-Id: schedule:<name>` and a projected token (audience `openagentix-a2a`, one hour), waits for the task to end and exits 0 only for `TASK_STATE_COMPLETED`.
- The chart derives one gate caller rule per schedule (`oa.a2aRules` in `charts/openagentix/templates/_helpers.tpl`): the ServiceAccount, exactly its agent, user id `exact: schedule:<name>`, method `SendMessage` only.
- Render-time checks: name a DNS label of at most 40 characters, a 5-field cron expression (`oa.validateCron`), an IANA-shaped time zone, `concurrencyPolicy` one of `Forbid`, `Allow`, `Replace`, a timeout in seconds or minutes. Defaults (`scheduling.defaults`): timeout 300 s, `Forbid`, `backoffLimit: 0` (a retry repeats cost and side effects), `startingDeadlineSeconds: 300`, `ttlSecondsAfterFinished: 86400`, history 3 and 3.
- The pod is hardened: non-root 65532, read-only root file system, no capabilities, `RuntimeDefault` seccomp, no default token. Its egress policy allows DNS and the gate (or the kagent controller when the gate is off).
- Every firing costs at least one model call. A run uses the **agent's** gateway key, so its tokens count against that agent's budget (`gateway.policy.tokenBudget`, per key, per hour, per proxy replica). Nothing limits how often a schedule fires except the cron expression (`docs/diary/features/schedules.md`, "Known limits").
- `a2a-call` does not cancel the agent's task when it times out. When the Job's deadline ends the pod, the agent may keep working (read in `tools/a2a-call/internal/call/call.go`: no `CancelTask`).
- Whoever can create pods in `openagentix-schedules` can mount the token of any schedule ServiceAccount there and act as that schedule (ADR 0006, round 1 review; CHANGELOG).
- ADR 0016 proposes `AgentAccess`: one caller identity per object, agents of the object's own namespace, a user id rule, methods. Caller namespaces must be in the policy list `access.callerNamespaces`. Chart schedule ServiceAccounts and `schedule:<name>` user ids are reserved there. ADR 0016 leaves open whether a schedule creates its own `AgentAccess`.
- The control plane watches one namespace (the catalog's `namespaces.agents`), never reads Secrets, writes only what an admission guard allows, and for container agents already writes objects into a second namespace, tied to the definition by labels, an annotation with the UID and a finalizer (ADR 0015).
- `docs/api-conventions.md`: `suspend` is documented per kind; a fact that cannot be verified is `unknown`; reasons are listed in one table per kind.

The problem: a team that builds an agent cannot schedule it without an operator's chart change, the console cannot edit schedules, and nothing stops a schedule from firing so often that it drains the agent's budget.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `Schedule` kind; the controller writes a CronJob, a ConfigMap and a ServiceAccount in the schedules namespace | Same proven run path as today (CronJob, `a2a-call`, gate); policy before anything runs; status; the guard limits what the controller writes; no new component | The controller gets write rights in one more namespace; CronJob behaviour (missed runs, time zones, DST) is Kubernetes' | Read the chart, `a2a-call`, the container adapter and its guard on `main` |
| B. Users write CronJobs themselves (no new kind) | Nothing to build | Users need pod create rights in the schedules namespace, so they can act as any schedule; no policy, no rate limit, no status; the console cannot edit safely | The pod-create boundary above |
| C. The controller runs the timer and calls the gate itself | No pods; fastest start | The controller needs a token for every schedule identity (TokenRequest on every ServiceAccount, which is impersonation), becomes an A2A client in the most privileged component, and loses firings while it restarts | Compared with how the controller is built (ADR 0007) |
| D. Argo Workflows `CronWorkflow`, or Tekton | Retries, DAGs, a UI | A new upstream component in the install; heavy for one HTTP call; still needs identity and policy around it | Not tried. Can be a later scheduler adapter |
| E. kagent's `ScheduledRunService` | Native to the runtime | Broken for memory agents in 1.0.1, runs stuck on a cold agent, gRPC only, ties the kind to one runtime (ADR 0002, ADR 0013) | ADR 0002 live test |
| F. Wait for `AgentRun` (0.4) and create runs | One run record for every source | Blocks 0.3; `AgentRun` has no design yet | ADR 0013 release plan |

## Decision

Option A. The spec is written so that a later version of the controller can create an `AgentRun` (Option F) instead of a Job without changing the spec: nothing in the spec names a CronJob, a Job, an image or a namespace.

### The resource

```yaml
apiVersion: openagentix.io/v1alpha1
kind: Schedule
metadata:
  name: daily-brief
  namespace: kagent              # the agents namespace; the agent must be in the same namespace
spec:
  agent: {name: assistant}       # an AgentDefinition, a container agent or a chart agent of this namespace
  cron: "0 8 * * 1-5"            # 5 fields, no macros, no seconds
  timeZone: Europe/Berlin        # IANA name; default UTC
  message:
    text: |                      # 1 to 16384 bytes, never a secret
      Summarise yesterday's open incidents in five lines.
  userId: "schedule:kagent.daily-brief"   # optional; this is the default
  concurrencyPolicy: Forbid      # Forbid (default) or Allow
  timeoutSeconds: 300            # 30 .. policy maximum; default 300
  startingDeadlineSeconds: 300   # 10 .. 3600; default 300
  retries: {limit: 0}            # 0 .. policy maximum (default maximum 0): off
  history: {successful: 3, failed: 3}   # 0 .. 10 each
  suspend: false
status:
  observedGeneration: 1
  conditions: []                 # Accepted, AccessGranted, Applied, Ready, Synced
  agent: kagent/assistant
  caller: serviceaccount:openagentix-schedules/kagent.daily-brief
  userId: schedule:kagent.daily-brief
  maxRunsPerDay: 1
  minIntervalMinutes: 1440
  nextRunTime: "2026-11-26T07:00:00Z"   # or "unknown"
  lastRun:
    scheduledTime: "2026-11-25T07:00:00Z"
    result: Succeeded            # Succeeded, Failed, TimedOut, Running or unknown
    completionTime: "2026-11-25T07:00:41Z"
  lastSuccessfulTime: "2026-11-25T07:00:41Z"
  consecutiveFailures: 0
  workloadRef: {kind: CronJob, namespace: openagentix-schedules, name: daily-brief-1a2b3c4d}
  violations: []
  controller: {}                 # private
```

Short name `oas`. `kubectl get oas` shows Agent, Cron, TimeZone, Suspended, Ready, Last result, Next run and Age.

**Fields.**

| Field | Rule |
|---|---|
| `metadata.name` | DNS label, at most 40 characters. A name of a chart schedule (`schedules[].name`) is refused while that chart entry exists, so people do not confuse the two |
| `agent.name` | DNS label. An object, so that a version can follow. The agent must exist in the namespace (an `AgentDefinition` the controller sees, or a chart agent listed in the catalog); otherwise `Ready=False`, `AgentNotFound`, and the CronJob stays suspended |
| `cron` | Exactly 5 fields (minute, hour, day of month, month, day of week), numbers, ranges, lists, steps and the three-letter names. No `@` macros, no `TZ=` or `CRON_TZ=` prefix (the time zone has its own field). The same grammar as `oa.validateCron`, implemented once in Go and tested against the chart's cases |
| `timeZone` | An IANA name the controller can load (`Europe/Berlin`). Default `UTC`, written explicitly into the CronJob so the controller-manager's local time never applies |
| `message.text` | 1 to 16384 bytes (UTF-8, counted as bytes, as for instructions). Passes the same secret scan as `AgentDefinition` instructions. A refusal names the pattern, never the text |
| `message.fromConfigMap` | **Reserved**: `{name, key}`, refused with "not available yet". There is no field for a Secret, now or later: a message goes to the model provider, so it must never hold one |
| `userId` | Optional. 1 to 128 characters from `A-Z a-z 0-9 . _ : @ + -` (the ADR 0016 set). Default `schedule:<namespace>.<name>`. A chart schedule's id has no dot, so the default never equals one. The gate decides whether the identity may use it (see "Identity") |
| `concurrencyPolicy` | `Forbid` (default) or `Allow`. `Allow` needs the policy's `schedules.allowConcurrentRuns`. `Replace` is not offered: it ends the pod, not the agent's task, so the old task keeps running and costing while a new one starts |
| `timeoutSeconds` | 30 to `schedules.maxTimeoutSeconds` (default 900). The Job's `activeDeadlineSeconds` is this plus 60, as today |
| `startingDeadlineSeconds` | 10 to 3600, default 300. A firing that cannot start in time is skipped, not run late |
| `retries.limit` | 0 to `schedules.maxRetries`. The policy default is 0, so retries are off unless the operator allows them. An object so that a backoff can follow |
| `history.{successful, failed}` | 0 to 10, defaults 3 and 3. Finished Jobs are removed after `schedules.finishedJobTtlSeconds` (policy, default 86400) |
| `suspend` | No new firings. See "Suspend" |

Not in the kind: an image, a namespace, a ServiceAccount name, resources, a URL, a header, a context id (every run is a new conversation, as today), a model, a budget. The pod's resources come from policy. The API server prunes unknown fields; every default is the narrowest choice, so a misspelt field makes a schedule narrower, never wider.

### Identity: who runs it, and its relation to AgentAccess

**The user creates the `AgentAccess`.** The controller never creates or edits one. Scheduling an agent and granting a caller access to it are separate rights, as ADR 0016 keeps building and granting apart: `openagentix-schedule-editor` does not imply `openagentix-access-admin`. This is the maintainer's default for this design.

- Each schedule runs as its own ServiceAccount in the schedules namespace. Its name is fixed and known before the schedule exists: **`<agents namespace>.<schedule name>`** (for example `kagent.daily-brief`; a dotted name is a valid ServiceAccount name, and a chart schedule's `schedule-<name>` has no dot, so the two never clash). The name is published as `status.caller` in the gate's form, `serviceaccount:<schedules namespace>/<agents namespace>.<name>`; treat it as opaque.
- The user writes an `AgentAccess` in the agents namespace for that ServiceAccount, for the schedule's agent, with `SendMessage` in `methods`, and a user id rule that admits the schedule's user id (`exact` or `fixed` with the same value, or a `prefix` such as `schedule:` that it starts with). The operator must have put the schedules namespace into `access.callerNamespaces` (ADR 0016).
- The controller reads `AgentAccess` objects (it already watches them for ADR 0016) and sets **`AccessGranted`**: True when an `AgentAccess` that is `Accepted=True` and `Ready=True` names exactly this ServiceAccount, this agent, `SendMessage`, and a user id rule that admits `status.userId`. Otherwise False with reason `NoAccess`, and a message that names what is missing (no rule for the identity, not this agent, no `SendMessage`, the user id is not admitted). This is the "clear condition" the issue asks for.
- **Without a grant the CronJob is written suspended.** A run that the gate would refuse costs no model call, but it would fail every time and fill the audit with 403 lines. The schedule fires once the grant is there, at the next pass (resync 60 s) after the `AgentAccess` becomes `Ready`. The gate may load the grant up to about a minute later than that (ADR 0016, *unverified*), so the first firing can still be refused; it is a failed run with result `Failed`, not a hidden one.
- When a grant is removed, the next pass suspends the CronJob. The gate refuses calls as soon as it has loaded the new access list, whichever comes first.
- One schedule, one identity. Two schedules never share a ServiceAccount, so one `AgentAccess` per schedule, or one per schedule identity with several agents if the user wants. ADR 0016 refuses overlapping user id spaces across identities, so two schedules cannot share a memory scope unless they are one identity.

What this costs: one more object for the user to write. The console can offer both at once (create the `Schedule` and, for a user who holds the access right, the matching `AgentAccess`), which keeps the two rights separate and still makes it one step for an administrator.

### How it maps to Kubernetes objects

The controller writes three objects per schedule into the schedules namespace (chart value `scheduling.namespace`, today `openagentix-schedules`), all with the labels `app.kubernetes.io/managed-by: openagentix-control-plane`, `openagentix.io/schedule: <name>` and `openagentix.io/schedule-namespace: <agents namespace>`, and the annotation `openagentix.io/schedule-uid`:

| Object | Name | Content |
|---|---|---|
| ConfigMap | `<name>-<8 hex of the UID>` | one key `prompt.txt` with `message.text` |
| ServiceAccount | `<agents namespace>.<name>` | `automountServiceAccountToken: false`, nothing else |
| CronJob | `<name>-<8 hex of the UID>` (at most 49 characters, under the CronJob limit of 52) | the same pod as the chart's schedules today: `a2a-call` image from the chart (with its source hash), `A2A_URL` = the gate URL for the agent, `A2A_USER_ID`, `A2A_TIMEOUT`, `PROMPT_FILE`, `A2A_TOKEN_FILE`, the projected token (gate audience, one hour), the hardened security context, the pod label `scheduling.podLabel` (so the existing gate ingress and schedule egress policies apply), resources from policy |

Owner references cannot cross namespaces, so the schedule gets the finalizer `openagentix.io/schedule-objects`. On delete the controller removes the three objects by name and labels, then the finalizer. Running Jobs are deleted with the CronJob (foreground propagation), which ends their pods but, as today, not the agent's task.

A name check like `AgentDefinition`'s applies: an object with a target name that does not carry both labels and the UID annotation of this schedule is not touched; `Applied=False`, reason `NameConflict`.

The spec maps to the CronJob as follows: `cron` to `schedule`, `timeZone` to `timeZone`, `concurrencyPolicy`, `startingDeadlineSeconds`, `history` to the two history limits, `retries.limit` to `backoffLimit`, `timeoutSeconds + 60` to `activeDeadlineSeconds`. `suspend` on the CronJob is the **effective** suspend: true when `spec.suspend`, the policy's `schedules.suspendAll`, no grant, the agent missing or suspended, or the failure limit is reached.

### Status

Public fields follow `docs/api-conventions.md`:

| Field | Meaning |
|---|---|
| `conditions`, `observedGeneration` | see the table below |
| `agent` | `<namespace>/<name>` of the target |
| `caller` | the identity as the gate matches it; opaque |
| `userId` | the user id every run sends |
| `maxRunsPerDay`, `minIntervalMinutes` | computed from `cron` (see "Cost guard"); facts about the expression, not about runs |
| `nextRunTime` | the next time the expression matches in `timeZone`, RFC 3339 in UTC. Absent while the effective suspend is on. `unknown` when the controller cannot load the time zone. It is a prediction: the CronJob controller may start up to `startingDeadlineSeconds` later or skip the firing |
| `lastRun` | `scheduledTime`, `result`, `completionTime` of the newest Job the controller can read. `result` is `Succeeded` (the Job completed: `a2a-call` exits 0 only for a completed task), `Failed`, `TimedOut` (the Job's deadline was reached), `Running`, or `unknown` when the Job is gone and only the CronJob's times remain |
| `lastSuccessfulTime` | from the CronJob status |
| `consecutiveFailures` | failed Jobs since the last success that the controller has seen. A Job removed before the controller read it is not counted, so this is a lower bound |
| `workloadRef` | one generic reference for people who debug, like `agentRef` |
| `violations` | one sentence per refused rule |
| `controller` | private: applied generation and spec, object names, the time the failure limit was reached |

The controller reads CronJobs and Jobs (get and list, no watch) on every pass. It reads no pods and no logs, so the reason a run failed is not in status. The run's one-line summary (task state, trace id, no answer text) is in the Job's log, and the gate's audit line has the caller, agent and status.

`Ready=True` means: **the CronJob of this generation exists, is not suspended, and the caller has an accepted, published grant for the agent.** It does not mean the next run will succeed.

| Condition | Reason | Status | Meaning |
|---|---|---|---|
| `Accepted` | `Accepted` | True | the schedule passes the policy |
| `Accepted` | `PolicyViolation` | False | one or more rules refused it; each is in `status.violations` |
| `Accepted` | `LimitReached` | False | `schedules.maxSchedules` accepted schedules exist in the namespace; the older keep their place |
| `AccessGranted` | `Granted` | True | an accepted, published `AgentAccess` covers caller, agent, `SendMessage` and user id |
| `AccessGranted` | `NoAccess` | False | none does; the message says what is missing |
| `AccessGranted` | `NotAccepted` | Unknown | the schedule is refused, so access is not checked |
| `Applied` | `Applied` | True | the objects of this generation were written |
| `Applied` | `NotAccepted` | False | refused; nothing is written (objects of an earlier generation were removed) |
| `Applied` | `NameConflict` | False | an object with a target name exists and is not this schedule's |
| `Applied` | `ApplyFailed` | False | writing an object failed |
| `Applied` | `RemoveFailed` | False | removing objects failed |
| `Ready` | `Ready` | True | see the promise above |
| `Ready` | `Suspended` | False | `spec.suspend` or the operator's `schedules.suspendAll` |
| `Ready` | `NoAccess` | False | no grant; the CronJob is suspended |
| `Ready` | `AgentNotFound` | False | no agent of that name in the namespace; the CronJob is suspended |
| `Ready` | `AgentSuspended` | False | the target `AgentDefinition` is suspended; the CronJob is suspended so that runs are not refused one by one |
| `Ready` | `FailureLimit` | False | `schedules.maxConsecutiveFailures` runs failed in a row; the CronJob is suspended until the spec changes (a new generation) |
| `Ready` | `NotAccepted` | False | the schedule is refused |
| `Ready` | `NotApplied` | False | the objects of this generation are not written yet or could not be |
| `Synced` | `Synced` | True | the last pass could read everything it needed |
| `Synced` | `TransientError` | False | a read failed; the other conditions are the last known state |

The same contract tests as for `AgentDefinition` apply: a test fails when the code sets a reason that is not in this table.

### Suspend

For a `Schedule`, `suspend` stops **new firings**. A run in progress continues until it ends or reaches its deadline, because the Job cannot reliably stop the agent's task (see "Not checked"). Resume is immediate; the CronJob controller does not run firings that were missed while suspended beyond `startingDeadlineSeconds`. Status: `Ready=False`, reason `Suspended`, no `nextRunTime`. Suspending the target agent (`AgentDefinition.spec.suspend`) also suspends its schedules (reason `AgentSuspended`); they resume with the agent.

### Cost guard: a runaway schedule must not drain the budget

A run spends the agent's tokens. The gateway budget is per agent key, per hour, so a schedule that fires too often or runs too long takes the budget from the agent's interactive users. The guard has four layers, all from policy, all checked before anything is written:

1. **Rate from the expression.** The controller computes, from `cron` alone, the most firings in one day (`maxRunsPerDay` = matching minutes times matching hours, when any day matches) and the shortest gap between two firings (`minIntervalMinutes`, inside a day and across midnight, assuming two matching days can be adjacent). Policy `schedules.maxRunsPerDay` (default 24) and `schedules.minIntervalMinutes` (default 15) refuse a faster schedule with `PolicyViolation`. `* * * * *` is refused by default. This needs no counting at run time and cannot drift.
2. **Length and overlap.** `timeoutSeconds` up to `schedules.maxTimeoutSeconds` (default 900), `concurrencyPolicy: Forbid` unless the operator allows `Allow`, retries off unless the operator allows them. So by default at most one run per schedule at a time, and at most `maxRunsPerDay` runs a day.
3. **Count.** `schedules.maxSchedules` (default 10) accepted schedules per namespace, so the worst case is bounded: 10 schedules times 24 runs times 15 minutes of model time.
4. **Failure stop.** After `schedules.maxConsecutiveFailures` (default 3) failed or timed-out runs in a row, the controller suspends the CronJob (`FailureLimit`). A failing agent can still spend tokens before it fails; this stops it doing that every hour. A spec change, such as setting and clearing `suspend`, starts counting again.

Plus the operator's stop switch `schedules.suspendAll`, and the gateway's own per-key token budget, which remains the hard limit. Not in 0.3: a token budget per schedule. The gateway counts tokens per agent key, not per caller, so a token limit for one schedule needs either a key per schedule (the key belongs to the agent runtime, not the caller) or the `Budget` kind (0.5). Cost per schedule is therefore approximate: runs are counted in the gate audit (caller is the schedule), and a run's tokens can be found through its trace id. The docs must say this.

### Policy and chart values

Chart switch `controlPlane.schedules.enabled`, default `false`. It needs `controlPlane.enabled`, `controlPlane.agentAccess.enabled` (ADR 0016) and `governance.a2a.enabled`; the render fails otherwise. A schedule without the gate would call the runtime with no identity check, so that combination is not offered. With the switch off the chart renders exactly what it renders today, for the default values and for every demo values file: no CRD, no Roles, no guard policies, no new policy keys, no new NetworkPolicy peer, no catalog change.

Policy keys (chart values `controlPlane.policy.schedules`, written into the existing policy ConfigMap):

| Key | Default | Meaning |
|---|---|---|
| `maxSchedules` | `10` | accepted schedules per namespace; the oldest keep their place |
| `maxRunsPerDay` | `24` | the largest `status.maxRunsPerDay` allowed |
| `minIntervalMinutes` | `15` | the smallest `status.minIntervalMinutes` allowed |
| `maxTimeoutSeconds` | `900` | largest `timeoutSeconds` |
| `maxRetries` | `0` | largest `retries.limit`; 0 means retries are off |
| `allowConcurrentRuns` | `false` | whether `concurrencyPolicy: Allow` is allowed |
| `maxConsecutiveFailures` | `3` | failed runs in a row before the controller suspends the schedule; 0 turns the stop off |
| `finishedJobTtlSeconds` | `86400` | how long finished Jobs are kept |
| `resources` | the chart's `scheduling.defaults.resources` | requests and limits of every schedule pod |
| `suspendAll` | `false` | the operator's stop switch for every schedule |

The catalog gets `schedules.namespace`, `schedules.image` (repository, tag or digest, source hash), `schedules.reservedNames` (the chart's `schedules[].name`) and `schedules.podLabels`. The image is the platform's own `a2a-call`, never a value from a spec.

`install.sh` builds and loads the `a2a-call` image when the switch is on, not only when `schedules[]` is non-empty. The gate ingress NetworkPolicy and the schedule egress NetworkPolicy render when the switch is on, with the same selectors as today.

### Admission guard and RBAC

RBAC added for the controller, namespaced only:

| Namespace | Resource | Verbs |
|---|---|---|
| agents | `schedules` | get, list, watch, update (the finalizer) |
| agents | `schedules/status` | patch |
| schedules | `cronjobs` | get, list, create, patch, delete |
| schedules | `jobs` | get, list (status only; never create) |
| schedules | `configmaps`, `serviceaccounts` | get, list, create, patch, delete |

No pods, no `pods/log`, no `pods/exec`, no Secrets, no `serviceaccounts/token`. Two Roles for people that nothing binds: `openagentix-schedule-editor` (create, update, delete `schedules`) and `openagentix-schedule-viewer`. `openagentix-agent-builder` does not get `schedules`.

New allowlist policies, bound to the controller's ServiceAccount, `failurePolicy: Fail`, executed in `make test-guard` and `make test-apiserver`:

- **CronJobs** in the schedules namespace: key sets at every level equal to what the controller writes. The image equals the chart's `a2a-call` image, rendered literally. `serviceAccountName` matches `<agents namespace>.<DNS label>` (so never a chart schedule's account or any other account of the namespace) and equals the `openagentix.io/schedule-namespace` and `openagentix.io/schedule` labels joined by a dot. `A2A_USER_ID` matches the user id pattern; `A2A_URL` equals the gate URL followed by `/agents/<agents namespace>/<DNS label>`; the environment has exactly the five names above. One projected token with the gate audience and an expiry of at most 3600 s, one ConfigMap volume whose name equals the CronJob's name. The security context exactly as today. `concurrencyPolicy` is `Forbid` unless the operator allowed `Allow`; `backoffLimit` at most `maxRetries`; `activeDeadlineSeconds` at most `maxTimeoutSeconds + 60`; resources equal the policy's. The pod label is `scheduling.podLabel`.
- **ConfigMaps** in the schedules namespace: only the controller's labels, one key `prompt.txt`, at most 16 KiB of data, no `binaryData`; only objects with the controller's labels may be patched or deleted. The chart's `schedule-<name>` ConfigMaps are not reachable.
- **ServiceAccounts** in the schedules namespace: name pattern as above, `automountServiceAccountToken: false`, no `secrets`, no `imagePullSecrets`.
- **Schedule status**: the controller may patch `schedules/status` and update only the finalizer list.
- `guard-other` keeps refusing everything not listed.

What the guard cannot check: the cron expression's rate (CEL has no cron parser; a pattern on the string would be weaker than the Go check), that a CronJob matches an existing `Schedule`, and the message text beyond its size. So a compromised controller can make a schedule identity call the agents its own grants allow, as often as every minute, with any text. The gate still checks every call against the user's `AgentAccess`, and the agent's gateway budget still caps the tokens. That is the remaining blast radius.

A second layer: the schedules namespace gets Pod Security `restricted` when the switch is on (*unverified* that the chart today labels it; checked in slice 3).

### Audit

- The gate writes its usual line per run: `caller` is `serviceaccount:<schedules namespace>/<agents namespace>.<name>`, plus the `access` field of ADR 0016 naming the `AgentAccess`, the agent, the hashed user id, the trace id and the status. No message text, no answer.
- `a2a-call` prints its one-line summary without the answer, as today (`PRINT_ANSWER` is never set by the controller).
- The controller logs the schedule name, the outcome of a pass and object names, never the message text. A condition message or violation never quotes the message.
- Status never holds the message text or an answer. The message is visible to anyone who can read `Schedule` objects in the agents namespace or ConfigMaps in the schedules namespace. The docs say so.

### Migration from chart-defined schedules

- `schedules[]` and `scheduling` keep working unchanged for at least one release after `Schedule` ships (0.3 and 0.4). Deprecation is a changelog note in 0.4; removal is a later decision with its own note.
- Both can run side by side. They use different names for every object (the chart: `<name>`, `schedule-<name>`; the resource: `<name>-<8 hex>`, `<agents namespace>.<name>`), and the guard keeps the controller off the chart's objects. A `Schedule` with the name of a chart schedule is refused, to avoid confusion.
- To move one schedule:
  1. Add the schedules namespace to `controlPlane.policy.access.callerNamespaces`.
  2. Create the `Schedule` with `suspend: true` and the same agent, cron, time zone and message. To keep the memory scope, set `userId: schedule:<name>` (the chart's id).
  3. Remove the chart entry in a `helm upgrade`. This frees the reserved `schedule:<name>` user id in ADR 0016's list. While the chart entry exists, an `AgentAccess` that admits `schedule:<name>` is refused with `Conflict`, so steps 3 and 4 cannot be done the other way round.
  4. Create the `AgentAccess` for `<agents namespace>.<name>` with that user id, and wait for `AccessGranted=True`.
  5. Set `suspend: false`.
  Between steps 3 and 5 no firing happens. Choose a time between two firings.
- A schedule that keeps the default user id starts with an empty memory scope. That is the safe default and the migration guide says it.
- `upgrade notes` in `CHANGELOG.md` say all of this in the slice that ships the kind.

## Security considerations

- **Who can schedule.** Anyone with `openagentix-schedule-editor` in the agents namespace can make an agent run with a text of their choice, but only through an identity that someone with the access right has granted. Nothing binds either Role by default.
- **Who can act as a schedule.** As today, anyone who can create pods in the schedules namespace can mount any schedule ServiceAccount's token. The boundary is pod-create RBAC there, plus Pod Security. This ADR does not widen it: the controller gets CronJob rights, and the guard limits the ServiceAccount, image, environment and volumes of every pod those CronJobs make.
- **Prompt injection by schedule.** A schedule's message reaches the agent with the agent's tools. That is the same as any caller; tool profiles and egress rules apply. A schedule editor cannot pick a tool or a destination that the agent does not already have.
- **Cost.** Bounded by the four layers above and the gateway budget. A compromised controller can bypass the rate layer (see the guard section) but not the gateway budget.
- **Revocation.** Deleting the `AgentAccess` stops runs at the gate within the ADR 0016 delay, and the next pass suspends the CronJob. Deleting the `Schedule` removes its objects.
- **What leaves the cluster.** The message goes to the model provider through the gateway, as every message does.
- An independent security review is required before the slice that lets the controller write CronJobs is merged.

## Alternatives considered and rejected

| Alternative | Why not |
|---|---|
| Users write CronJobs (Option B) | Pod-create rights let them act as any schedule; no policy or status |
| Controller-side timer (Option C) | Needs tokens for every schedule identity, which is impersonation in the most privileged component |
| Argo or Tekton (Option D) | New upstream component for one HTTP call; possible later as a scheduler adapter |
| kagent's scheduler (Option E) | Broken for memory agents and cold agents in 1.0.1; runtime-specific |
| The controller creates the `AgentAccess` for each schedule | Merges the right to schedule with the right to grant: anyone who may write a schedule could give a new identity access to any agent of the namespace. Kept as an open point for a narrower form |
| `spec.access` inside the `Schedule` | Same reason |
| One shared ServiceAccount for all resource schedules | One stolen token acts as every schedule, and the audit line no longer names the schedule |
| `concurrencyPolicy: Replace` | Ends the pod but not the task, so it doubles cost instead of replacing a run |
| A message from a Secret | Every message goes to the model provider; a secret in it is leaked by design |
| A rate limit in the gate per caller | The gate does not count over time today and keeps no state; the expression check is exact and needs no state. Kept as a later option for all callers |
| Counting tokens per schedule in 0.3 | The gateway counts per agent key; needs `Budget` (0.5) |

## Consequences

- A team can schedule its agent with `kubectl apply` and the console can edit schedules. An operator sets the limits once in policy.
- A schedule fails visibly (`AccessGranted=False`, `NoAccess`) until someone with the access right grants it.
- The controller gets write rights in a third namespace and four more guard policies. Its "What it never does" list changes: it writes CronJobs, ConfigMaps and ServiceAccounts in the schedules namespace, only in the shapes the guard allows, only with the switch on.
- Becomes harder: two ways to schedule exist for at least two releases; two user id forms exist (`schedule:<name>` and `schedule:<namespace>.<name>`).
- Ruled out for now: a message from a Secret or a template, `Replace`, a context id that carries a conversation over runs, a token budget per schedule, schedules for agents in another namespace, a "run now" action from the controller (a person can still `kubectl create job --from=cronjob/...` where RBAC allows).
- Security impact: a new writer of pod templates (through CronJobs) in the schedules namespace, bounded by the guard and Pod Security; deny by default at three levels (chart switch, empty `callerNamespaces`, no `AgentAccess`).
- Compatibility: nothing changes for existing users. Default render unchanged.

## Test plan

Each slice is test first: the failing test is written and seen to fail before the code.

- **Cron and time** (pure Go, no cluster): the grammar, with every case of the chart's `oa.validateCron` tests as a shared table; `maxRunsPerDay` and `minIntervalMinutes` as a table (`* * * * *`, `*/15 * * * *`, `0 8 * * 1-5`, `0,30 23 * * *` across midnight, `0 0 31 2 *` which never matches); `nextRunTime` in several time zones, across a DST change, and `unknown` for a zone that cannot be loaded.
- **Policy**: one case per refusal (name, reserved chart name, agent name, cron, time zone, message size and secret scan, user id set, each limit, `Replace`, `Allow` without permission, retries above the maximum, `fromConfigMap` "not available yet"); `maxSchedules` keeps the older.
- **Controller**: create, update, suspend, resume and delete (the issue's "done when") with `internal/kubetest`; `AccessGranted` for each missing piece (no rule, other agent, no `SendMessage`, user id not admitted, rule not accepted, rule not ready) and the CronJob suspended in each case; grant added and removed; agent missing, suspended and back; `FailureLimit` after three failed Jobs and reset on a new generation; `lastRun` and `consecutiveFailures` from Job status, `unknown` when the Job is gone; name conflict with a foreign object; the finalizer removes all three objects; never a request for a Secret, a pod or a log; the message text in no log line, condition or violation (a canary text); the reason table matches the README; no upstream words in the new packages.
- **Guard** (`make test-guard`): the controller's real output allowed; each refusal (another image, a chart schedule's ServiceAccount, a ServiceAccount that does not match the labels, an extra env name, another URL, a second token or a longer expiry, a host path, `Allow` when not permitted, a larger `backoffLimit`, other resources, a ConfigMap of the chart, a ServiceAccount with `secrets`); status patch allowed, spec writes refused.
- **API server** (`make test-apiserver`): the CRD applies; schema refusals (6-field cron, `Replace`, no `agent`, message over the limit); status is a subresource; impersonated writes refused by the guard.
- **Chart** (`make test-chart`): default and every demo render byte-identical with the switch off; the switch on renders the CRD, the Roles, the guard, the policy keys, the catalog section and the NetworkPolicy peers; the render fails without the control plane, without `agentAccess`, without the gate.
- **Live proof** (quick start, stub model, no paid call): a `Schedule` every minute is refused by default policy; one every 15 minutes with policy lowered for the test (`minIntervalMinutes: 1`) shows `NoAccess` and a suspended CronJob; after the `AgentAccess` it fires, the stub model answers, `lastRun.result` is `Succeeded`, the gate audit line names the schedule identity; deleting the `AgentAccess` suspends it; deleting the `Schedule` removes its objects. Measured: time from grant to first successful run. Written in the diary with the limits.

## Slices

1. **This ADR**, reviewed for at least 7 days (new kind, security model).
2. **Pure parts.** Types, CRD, cron grammar, rate analysis, next-run computation, policy checks, reason table. Nothing is written to a cluster. Can be built before ADR 0016's controller.
3. **The controller writes schedules.** Objects, finalizer, `AccessGranted` from `AgentAccess` (needs ADR 0016 slice 3), status from CronJobs and Jobs, RBAC, guard policies, Roles, chart switch, `install.sh`, Pod Security on the namespace, live proof, independent security review. This closes issue #4 except the migration.
4. **Cost and stop.** `FailureLimit`, `suspendAll`, coupling with a suspended agent, and `a2a-call` sending `CancelTask` when it times out (only if the grant allows it and the runtime honours it; see below).
5. **Migration guide, console and deprecation note** for `schedules[]`.

## Not checked / open points

- *Unverified*: how the Kubernetes CronJob controller handles a DST change for a `timeZone` (a skipped or repeated hour). The rate check assumes the expression's own gaps; a repeated hour could fire one extra time. Tested on kind in slice 3.
- *Unverified*: whether kagent stops a task on A2A `CancelTask`. Until it does, a timed-out run can keep spending tokens after its Job ends, and the docs must say so.
- *Unverified*: the delay from a new `AgentAccess` to the gate loading it (ADR 0016), and so the time to a schedule's first successful run.
- *Unverified*: whether the chart labels the schedules namespace for Pod Security today, and how it is created.
- *Unverified*: that a dotted ServiceAccount name works everywhere it is used (the projected token's subject, TokenReview, the gate's identity string, NetworkPolicy does not use it). Checked by the live proof; if it fails, the name becomes `<agents namespace>-<name>` with a length rule, before the kind ships.
- This ADR depends on ADR 0016. If ADR 0016 changes (for example the gate watches `AgentAccess` itself), `AccessGranted` follows the new "published" signal.
- Open for the owner: should a narrow form of automatic access be allowed later, for example the controller creating an `AgentAccess` only when the schedule's creator also holds the access right (checked with a SubjectAccessReview)? Not in 0.3.
- Open for the owner: are the default limits right (24 runs a day, 15 minutes apart, 10 schedules, 900 s, 3 failures)? They are chosen to keep a forgotten schedule cheap, not to fit every use.
- Open for the owner: should a resource schedule's default user id be `schedule:<namespace>.<name>` (chosen here; unique per namespace) or `schedule:<name>` (shorter, same as the chart, but needs the reserved list to keep the two apart)?
- Open for the owner: keep the schedules namespace shared with chart schedules, or give resource schedules their own namespace so that pod-create rights for the two can differ?
