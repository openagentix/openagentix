# ADR 0017: Schedule, scheduled agent runs as a resource

Status: Proposed
Date: 2026-11-25
Issue: #4
Replaces: none. Fills in the `Schedule` entry that ADR 0012 reserved for release 0.3. Builds on ADR 0002 (the CronJob approach) and ADR 0016 (`AgentAccess`, still proposed), and amends ADR 0016 in two narrow ways (see "Amendments").

A new namespaced kind, `Schedule` (`openagentix.io/v1alpha1`), says which agent gets which message at which times. The controller checks it against policy and writes one CronJob per schedule into a namespace of its own, and that CronJob calls the agent through the A2A gate. The schedule runs as its own ServiceAccount, bound to the schedule's UID, and it fires only when an `AgentAccess` that the user created grants that identity the agent. It is off by default. Nothing here is built yet; everything is *unverified* until the slices below are done.

## Context

Facts read in this repository on 2026-11-25:

- Schedules today are the chart values `schedules[]` and `scheduling` (`charts/openagentix/templates/schedules.yaml`, ADR 0002). Each entry renders a prompt ConfigMap `schedule-<name>`, a CronJob `<name>` and, with the A2A gate on, a ServiceAccount `schedule-<name>`, all in `scheduling.namespace` (`openagentix-schedules`). The pod runs `tools/a2a-call`, which sends one `SendMessage` with `X-User-Id` and a projected token (audience `openagentix-a2a`, one hour), waits for the task to end and exits 0 only for `TASK_STATE_COMPLETED`.
- `install.sh` creates that namespace with `kubectl create namespace` (line 257), without Pod Security labels. Helm does not own it.
- The chart derives one gate caller rule per schedule (`oa.a2aRules` in `charts/openagentix/templates/_helpers.tpl`): the ServiceAccount, exactly its agent, user id `exact`, method `SendMessage` only. The user id is `schedules[].userId`, free text, default `schedule:<name>`.
- Render-time checks: name a DNS label of at most 40 characters, a 5-field cron expression (`oa.validateCron`), an IANA-shaped time zone, `concurrencyPolicy` one of `Forbid`, `Allow`, `Replace`, a timeout. Defaults (`scheduling.defaults`): timeout 300 s, `Forbid`, `backoffLimit: 0` (a retry repeats cost and side effects), `startingDeadlineSeconds: 300`, `ttlSecondsAfterFinished: 86400`, history 3 and 3.
- The pod is hardened: non-root 65532, read-only root file system, no capabilities, `RuntimeDefault` seccomp, no default token. Its egress policy allows DNS and the gate (or the kagent controller when the gate is off).
- `a2a-call` reads these environment variables: `A2A_URL`, `A2A_USER_ID`, `A2A_TOKEN_FILE`, `PROMPT_FILE`, `PROMPT`, `A2A_TIMEOUT`, `MAX_RESPONSE_BYTES`, `PRINT_ANSWER`, `TRACEPARENT` (`tools/a2a-call/README.md`). It does not cancel the agent's task when it times out (no `CancelTask` in `tools/a2a-call/internal/call/call.go`). When the Job's deadline ends the pod, the agent may keep working.
- Every firing costs at least one model call. A run uses the **agent's** gateway key, so its tokens count against that agent's budget (`gateway.policy.tokenBudget`, per key, per hour, per proxy replica). Nothing limits how often a schedule fires except the cron expression (`docs/diary/features/schedules.md`, "Known limits").
- Whoever can create pods in a schedules namespace can mount the token of any ServiceAccount there and act as that schedule (ADR 0006, round 1 review; CHANGELOG).
- ADR 0016 (revised on its branch, `docs/3-agent-access-adr`) proposes `AgentAccess`: one caller identity per object, agents of the object's own namespace, a user id rule, methods. User id values are lower case only, from `a-z 0-9 . _ : @ + -`, and the gate refuses a sent value outside that set with 403 `user_id`. Caller namespaces must be listed in `access.callerNamespaces`, and the render fails for every namespace the chart installs anything into. The reserved user ids cover chart callers only. It decides that the user creates a schedule's `AgentAccess`, and leaves the namespace where schedule pods run to this design. Grants follow names, not UIDs.
- The control plane watches one namespace (the catalog's `namespaces.agents`), never reads Secrets, writes only what an admission guard allows, and for container agents already writes objects into a second namespace, tied to the definition by labels, an annotation with the UID and a finalizer (ADR 0015, `charts/openagentix/templates/control-plane-guard-workload.yaml`).
- `docs/api-conventions.md`: `suspend` is a stop and a kind documents it; a fact that cannot be verified is `unknown`; reasons are listed in one table per kind.
- Kubernetes parses CronJob schedules with `github.com/robfig/cron/v3` (`ParseStandard`). Its grammar has quirks (for example `5/15` means "from 5, every 15"), so a second parser must be tested against it.

The problem: a team that builds an agent cannot schedule it without an operator's chart change, the console cannot edit schedules, and nothing stops a schedule from firing so often that it drains the agent's budget.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `Schedule` kind; the controller writes a CronJob, a ConfigMap and a ServiceAccount in a namespace of its own | Same proven run path as today (CronJob, `a2a-call`, gate); policy before anything runs; status; the guard limits what the controller writes; no new component | The controller gets write rights in one more namespace; CronJob behaviour (missed runs, time zones, DST) is Kubernetes' | Read the chart, `a2a-call`, the container adapter and its guard on `main` |
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
  history: {successful: 3, failed: 3}   # 0 .. 10 each; see the floor below
  suspend: false
status:
  observedGeneration: 1
  conditions: []                 # Accepted, AccessGranted, Applied, Ready, Synced
  agent: kagent/assistant
  caller: serviceaccount:openagentix-schedule-runs/kagent.daily-brief-1a2b3c4d
  userId: schedule:kagent.daily-brief
  maxRunsPerDay: 1
  minIntervalMinutes: 1440
  nextRunTime: "2026-11-26T07:00:00Z"   # a string: RFC 3339 or "unknown"
  lastRun:
    scheduledTime: "2026-11-25T07:00:00Z"
    result: Succeeded            # Succeeded, Failed, TimedOut, Running or unknown
    completionTime: "2026-11-25T07:00:41Z"
  lastSuccessfulTime: "2026-11-25T07:00:41Z"
  consecutiveFailures: "0"       # a string: a decimal number or "unknown"
  workloadRef: {kind: CronJob, namespace: openagentix-schedule-runs, name: daily-brief-1a2b3c4d}
  violations: []
  controller: {}                 # private
```

Short name `oas`. `kubectl get oas` shows Agent, Cron, TimeZone, Suspended, Ready, Last result, Next run and Age.

**Fields.**

| Field | Rule |
|---|---|
| `metadata.name` | DNS label, at most 40 characters. A name of a chart schedule (`schedules[].name`) is refused while that chart entry exists, so people do not confuse the two |
| `agent.name` | DNS label. An object, so that a version can follow. The agent must exist in the namespace (an `AgentDefinition` the controller sees, or a chart agent listed in the catalog); otherwise `Ready=False`, `AgentNotFound`, and the CronJob stays suspended |
| `cron` | Exactly 5 fields (minute, hour, day of month, month, day of week): numbers, ranges, lists, steps and the three-letter names. No `@` macros, no `TZ=` or `CRON_TZ=` prefix (the time zone has its own field). The grammar is implemented once in Go, tested against the chart's `oa.validateCron` cases and against the Kubernetes parser (see "Test plan"). An expression that never matches (`0 0 31 2 *`) has zero runs and is refused: "the expression never matches" |
| `timeZone` | An IANA name the controller can load (`Europe/Berlin`). Default `UTC`, written explicitly into the CronJob so the controller-manager's local time never applies |
| `message.text` | 1 to 16384 bytes (UTF-8, counted as bytes, as for instructions; the controller is the authority, see the guard). Passes the same secret scan as `AgentDefinition` instructions. A refusal names the pattern, never the text |
| `message.fromConfigMap` | **Reserved**: `{name, key}`, refused with "not available yet". When it is built, the controller must not read a ConfigMap on behalf of someone who could not read it (the controller can read more than the schedule's author). It then needs either a SubjectAccessReview of the author or an opt-in label on the ConfigMap; that is decided before it is built. There is no field for a Secret, now or later: a message goes to the model provider, so it must never hold one |
| `userId` | Optional. 1 to 128 characters from `a-z 0-9 . _ : @ + -`, lower case only (the ADR 0016 set; the gate refuses anything else with 403 `user_id`). Default `schedule:<namespace>.<name>`. Refused early, with a clear violation, when it equals or overlaps a reserved chart user id (`access.reserved.userIds`), or when an accepted `AgentAccess` of a different identity admits it. The gate still decides at run time (see "Identity") |
| `concurrencyPolicy` | `Forbid` (default) or `Allow`. `Allow` needs the policy's `schedules.allowConcurrentRuns`. `Replace` is not offered: it ends the pod, not the agent's task, so the old task keeps running and costing while a new one starts |
| `timeoutSeconds` | 30 to `schedules.maxTimeoutSeconds` (default 600). The Job's `activeDeadlineSeconds` is this plus 60, as today. It must also satisfy `timeoutSeconds + 60 < minIntervalMinutes × 60` for this schedule's own expression, so one run's Job ends before the next firing |
| `startingDeadlineSeconds` | 10 to 3600, default 300. A firing that cannot start in time is skipped, not run late |
| `retries.limit` | 0 to `schedules.maxRetries`. The policy default is 0, so retries are off unless the operator allows them. An object so that a backoff can follow |
| `history.{successful, failed}` | 0 to 10, defaults 3 and 3. The controller writes `failedJobsHistoryLimit` as at least `schedules.maxConsecutiveFailures`, whatever the spec says, so the failure stop can always see enough Jobs |
| `suspend` | No new firings. See "Suspend" |

Not in the kind: an image, a namespace, a ServiceAccount name, resources, a URL, a header, a context id (every run is a new conversation, as today), a model, a budget. The pod's resources come from policy. The API server prunes unknown fields; every default is the narrowest choice, so a misspelt field makes a schedule narrower, never wider.

### Where schedule pods run

Resource schedules get **their own namespace**, `controlPlane.schedules.namespace`, default `openagentix-schedule-runs`. It is separate from the chart schedules' `scheduling.namespace`:

- The chart renders the Namespace object only when the switch is on, with Pod Security `restricted` (enforce, audit and warn labels). The old namespace is created by `install.sh` without those labels and is not owned by Helm; making Helm take it over would conflict with the existing object on upgrade.
- Its pods carry their own label, `openagentix.io/component: schedule-run`, not the chart schedules' `scheduling.podLabel`. The chart renders, in that namespace, a default-deny ingress policy and an egress policy that allows only DNS and the gate, and adds one peer (this namespace and this label) to the gate's ingress policy. All only with the switch on.
- Only the controller writes there (CronJobs, ConfigMaps, ServiceAccounts, through the guard). The Kubernetes CronJob controller creates the Jobs and pods. No Role for people gives create rights on pods, ServiceAccounts or tokens in this namespace. The boundary of ADR 0006 (pod-create rights act as any schedule) therefore holds only for cluster administrators here, not for teams.
- ADR 0016 refuses every chart namespace in `access.callerNamespaces`. This ADR makes one named exception (see "Amendments"): the schedule runs namespace may be listed, and only while `controlPlane.schedules.enabled` is true. The operator must still list it explicitly; nothing adds it by itself.

### Identity: who runs it, and its relation to AgentAccess

**The user creates the `AgentAccess`.** The controller never creates or edits one (ADR 0016, "Schedules"). Scheduling an agent and granting a caller access to it are separate rights: `openagentix-schedule-editor` does not imply `openagentix-access-admin`.

**The identity is bound to the schedule's UID.** Each schedule runs as its own ServiceAccount in the schedule runs namespace, named **`<agents namespace>.<schedule name>-<first 8 hex characters of the schedule's UID, dashes removed>`** (for example `kagent.daily-brief-1a2b3c4d`). The controller creates it after the schedule exists and publishes it as `status.caller` in the gate's form, `serviceaccount:<runs namespace>/<that name>`; treat it as opaque.

ADR 0016 grants follow names. A ServiceAccount name without the UID would let anyone who may create a `Schedule` with a deleted schedule's name inherit every grant that was written for the old one. With the UID in the name, a new schedule of the same name is a new identity, and the old grant matches no ServiceAccount the controller will create again. The trade-off: no grant can be written before the schedule exists, and a schedule that is deleted and created again needs a new grant. The user copies `status.caller` into the `AgentAccess`.

- The user writes an `AgentAccess` in the agents namespace for that ServiceAccount, for the schedule's agent, with `SendMessage` in `methods`, and the user id rule **`exact`** with the schedule's `status.userId`. `exact` is the recommended form. A `prefix` such as `schedule:` would overlap every reserved chart schedule id and is refused by ADR 0016's overlap rule; a narrower prefix is allowed but buys nothing for one schedule.
- The operator must have listed the schedule runs namespace in `access.callerNamespaces`.
- The controller reads `AgentAccess` objects (it already watches them for ADR 0016) and sets **`AccessGranted`**: True when an `AgentAccess` that is `Accepted=True` and `Ready=True` names exactly this ServiceAccount, this agent, `SendMessage`, and a user id rule that admits `status.userId`. Otherwise False with reason `NoAccess`, and a message that names what is missing (no rule for the identity, not this agent, no `SendMessage`, the user id is not admitted). This is the "clear condition" the issue asks for.
- **Without a grant the CronJob is written suspended.** A run that the gate would refuse costs no model call, but it would fail every time and fill the audit with 403 lines. The schedule fires once the grant is there, at the next pass (resync 60 s) after the `AgentAccess` becomes `Ready`. The gate may load the grant up to about a minute later than that (ADR 0016, *unverified*), so the first firing can still be refused; it is a failed run with result `Failed`, not a hidden one.
- When a grant is removed, the next pass suspends the CronJob. The gate refuses calls as soon as it has loaded the new access list, whichever comes first.
- **A grant with no schedule.** An `AgentAccess` whose caller is in the schedule runs namespace but matches no current schedule's ServiceAccount (the schedule was deleted, or the name was typed by hand) gets an informational condition `CallerKnown=False`, reason `NoSchedule`, on the `AgentAccess` (an additive amendment to ADR 0016's condition table). It stays harmless, because only the controller creates ServiceAccounts there and it never reuses a UID, but it should be cleaned up.
- One schedule, one identity. Two schedules never share a ServiceAccount. ADR 0016 refuses overlapping user id spaces across identities, so two schedules cannot share a memory scope.

**The console.** The console writes with its own ServiceAccount and does no per-user authorization check today. So in 0.3 it does not create `AgentAccess` objects: that would let every console user grant access. It may create and edit `Schedule` objects under the same rule that governs its edits of `AgentDefinition`, and it shows the `AgentAccess` the user must apply, with `status.caller` and `status.userId` filled in. Creating the grant from the console needs a per-user check (a SubjectAccessReview, or impersonation of the logged-in user), which comes with console login in 0.4.

### How it maps to Kubernetes objects

The controller writes three objects per schedule into the schedule runs namespace. "The controller's labels" means all of: `app.kubernetes.io/managed-by: openagentix-control-plane`, `openagentix.io/schedule: <name>`, `openagentix.io/schedule-namespace: <agents namespace>`, and the annotation `openagentix.io/schedule-uid: <UID>`. (Chart schedule objects also carry `openagentix.io/schedule`, so that label alone proves nothing; they live in another namespace anyway.)

| Object | Name | Content |
|---|---|---|
| ConfigMap | `<name>-<8 hex of the UID>` | one key `prompt.txt` with `message.text` |
| ServiceAccount | `<agents namespace>.<name>-<8 hex of the UID>` | `automountServiceAccountToken: false`, nothing else |
| CronJob | `<name>-<8 hex of the UID>` (at most 49 characters, under the CronJob limit of 52) | the same pod as the chart's schedules today: the `a2a-call` image from the chart (with its source hash), `A2A_URL` = the gate URL for the agent, `A2A_USER_ID`, `A2A_TIMEOUT`, `PROMPT_FILE`, `A2A_TOKEN_FILE`, the projected token (gate audience, one hour), the hardened security context, the pod label `openagentix.io/component: schedule-run`, resources from policy |

Owner references cannot cross namespaces, so the schedule gets the finalizer `openagentix.io/schedule-objects`. On delete the controller removes the three objects by name and labels, then the finalizer. Running Jobs are deleted with the CronJob (foreground propagation), which ends their pods but, as today, not the agent's task.

A name check like `AgentDefinition`'s applies: an object with a target name that does not carry the controller's labels and the UID annotation of this schedule is not touched; `Applied=False`, reason `NameConflict`.

The spec maps to the CronJob as follows: `cron` to `schedule`, `timeZone` to `timeZone`, `concurrencyPolicy`, `startingDeadlineSeconds`, `history` to the two history limits (failed raised to the floor), `retries.limit` to `backoffLimit`, `timeoutSeconds + 60` to `activeDeadlineSeconds`, `schedules.finishedJobTtlSeconds` to `ttlSecondsAfterFinished`. `suspend` on the CronJob is the **effective** suspend: true when `spec.suspend`, the policy's `schedules.suspendAll`, no grant, the agent missing or suspended, or the failure stop is reached.

### Status

Public fields follow `docs/api-conventions.md`:

| Field | Meaning |
|---|---|
| `conditions`, `observedGeneration` | see the table below |
| `agent` | `<namespace>/<name>` of the target |
| `caller` | the identity as the gate matches it; opaque; set once the ServiceAccount exists |
| `userId` | the user id every run sends |
| `maxRunsPerDay`, `minIntervalMinutes` | computed from `cron` (see "Cost guard"); facts about the expression, not about runs |
| `nextRunTime` | a string, not a `date-time` field, so that it can hold `unknown`. The next time the expression matches in `timeZone`, RFC 3339 in UTC. Absent while the effective suspend is on. `unknown` when the controller cannot load the time zone. It is a prediction: the CronJob controller may start up to `startingDeadlineSeconds` later or skip the firing |
| `lastRun` | `scheduledTime`, `result`, `completionTime` of the newest Job the controller can read. `result` is `Succeeded` (the Job completed: `a2a-call` exits 0 only for a completed task), `Failed`, `TimedOut` (the Job's deadline was reached), `Running`, or `unknown` when the Job is gone and only the CronJob's times remain |
| `lastSuccessfulTime` | from the CronJob status |
| `consecutiveFailures` | a string. A decimal number when every Job since the last success is still readable (the history floor and the TTL floor make that the normal case); otherwise `unknown`. Never a guess |
| `workloadRef` | one generic reference for people who debug, like `agentRef` |
| `violations` | one sentence per refused rule |
| `controller` | private: applied generation and spec, object names, the firing count used by the failure stop, the time the stop was reached |

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

`docs/api-conventions.md` says `suspend` is a stop. `Schedule` is a documented exception: its `suspend` stops **new firings**, and a run in progress continues until it ends or reaches its deadline. The reason is that the Job cannot reliably stop the agent's task (no `CancelTask` yet, see "Not checked"), so ending the pod would only hide a task that keeps running. Resume is immediate. Status: `Ready=False`, reason `Suspended`, no `nextRunTime`. Suspending the target agent (`AgentDefinition.spec.suspend`) also suspends its schedules (reason `AgentSuspended`); they resume with the agent. A product must not promise that suspending a schedule ends a running run.

### Cost guard: a runaway schedule must not drain the budget

A run spends the agent's tokens. The gateway budget is per agent key, per hour, so a schedule that fires too often or runs too long takes the budget from the agent's interactive users. The guard has four layers, all from policy, all checked before anything is written. None can be turned off from a spec:

1. **Rate from the expression.** The controller computes, from `cron` alone, the most firings in one day (`maxRunsPerDay` = matching minutes times matching hours, when any day matches) and the shortest gap between two firings (`minIntervalMinutes`, inside a day and across midnight, assuming two matching days can be adjacent). Policy `schedules.maxRunsPerDay` (default 24) and `schedules.minIntervalMinutes` (default 15) refuse a faster schedule with `PolicyViolation`. `* * * * *` is refused by default. This needs no counting at run time and cannot drift.
2. **Length and overlap.** `timeoutSeconds` up to `schedules.maxTimeoutSeconds` (default 600), and `timeoutSeconds + 60` below the schedule's own `minIntervalMinutes`. The chart refuses a policy where `maxTimeoutSeconds + 60 >= minIntervalMinutes × 60`. `concurrencyPolicy: Forbid` unless the operator allows `Allow`; retries off unless the operator allows them. So by default there is **at most one Job per schedule at a time**. `Forbid` works on pods, not on the agent: since `a2a-call` sends no `CancelTask`, an agent task whose Job timed out can still be running when the next Job starts, so agent tasks may overlap until `CancelTask` exists (slice 4).
3. **Count.** `schedules.maxSchedules` (default 10) accepted schedules per namespace, so the worst case is bounded: 10 schedules times 24 runs a day times the timeout.
4. **Failure stop.** After `schedules.maxConsecutiveFailures` (default 3, at least 1; the policy cannot set 0) failed or timed-out runs in a row, the controller suspends the CronJob (`FailureLimit`). A failing agent can still spend tokens before it fails; this stops it doing that again and again. It counts in two ways and stops on either: the Jobs it can read (the history floor keeps enough failed Jobs, and `finishedJobTtlSeconds` must be at least two resync periods, so a Job is never removed before a pass has seen it), and, when Jobs are gone, the number of times the expression matched between `lastSuccessfulTime` and `lastScheduleTime` in the CronJob status. A spec change, such as setting and clearing `suspend`, starts counting again.

Plus the operator's stop switch `schedules.suspendAll`, and the gateway's own per-key token budget, which remains the hard limit.

**Bursts.** Several schedules with the same time (`0 8 * * *`) start together against one agent. After a resume, a new grant or a controller restart, the CronJob controller may start one missed firing at once, if it is still inside `startingDeadlineSeconds`. Both can spend a large part of one agent's hourly budget in a few minutes. The limits above bound the total, not the burst; spreading start times is the user's job, and the docs say so.

**While the controller is down.** CronJobs keep firing, because the Kubernetes CronJob controller runs them. The failure stop and the access check pause until the controller is back. The gate still checks every call against the published access list. Stops that work without the controller:

- suspend every resource schedule: `kubectl patch` each CronJob with the label `app.kubernetes.io/managed-by=openagentix-control-plane` in the schedule runs namespace with `{"spec":{"suspend":true}}` (the guard binds only the controller, so an administrator may do this; the controller writes its own value again when it is back, so also set `schedules.suspendAll`);
- cut the network: remove the schedule runs namespace from `access.callerNamespaces` in a `helm upgrade`, which removes the gate ingress peer;
- empty the gate access list by hand (ADR 0016).

Not in 0.3: a token budget per schedule. The gateway counts tokens per agent key, not per caller, so a token limit for one schedule needs either a key per schedule (the key belongs to the agent runtime, not the caller) or the `Budget` kind (0.5). Cost per schedule is therefore approximate: runs are counted in the gate audit (the caller is the schedule), and a run's tokens can be found through its trace id. The docs must say this.

### Policy and chart values

Chart switch `controlPlane.schedules.enabled`, default `false`. It needs `controlPlane.enabled`, `controlPlane.agentAccess.enabled` (ADR 0016) and `governance.a2a.enabled`; the render fails otherwise. A schedule without the gate would call the runtime with no identity check, so that combination is not offered. With the switch off the chart renders exactly what it renders today, for the default values and for every demo values file: no CRD, no namespace, no Roles, no guard policies, no new policy keys, no new NetworkPolicy, no catalog change.

**Turning the switch off.** With the switch off, Helm would remove the namespace (and with it every CronJob) and the controller's rights, while `Schedule` objects keep a finalizer that nothing removes. So the chart refuses an install or upgrade with the switch off while `Schedule` objects exist: a `lookup` of the kind fails the render with "delete every Schedule first (the controller cleans up), then turn controlPlane.schedules.enabled off". `lookup` returns nothing in `helm template`, so the default render stays byte-identical. Someone who bypasses this (for example applying a `helm template` output) loses the namespace, which stops every run, and must remove the finalizers by hand; the upgrade notes say how.

Policy keys (chart values `controlPlane.policy.schedules`, written into the existing policy ConfigMap):

| Key | Default | Meaning |
|---|---|---|
| `maxSchedules` | `10` | accepted schedules per namespace; the oldest keep their place |
| `maxRunsPerDay` | `24` | the largest `status.maxRunsPerDay` allowed |
| `minIntervalMinutes` | `15` | the smallest `status.minIntervalMinutes` allowed |
| `maxTimeoutSeconds` | `600` | largest `timeoutSeconds`; `maxTimeoutSeconds + 60` must be below `minIntervalMinutes × 60` |
| `maxRetries` | `0` | largest `retries.limit`; 0 means retries are off |
| `allowConcurrentRuns` | `false` | whether `concurrencyPolicy: Allow` is allowed |
| `maxConsecutiveFailures` | `3` | failed runs in a row before the controller suspends the schedule; at least 1, at most 10 |
| `finishedJobTtlSeconds` | `86400` | how long finished Jobs are kept; at least two resync periods (the chart refuses less than 600) |
| `resources` | the chart's `scheduling.defaults.resources` | requests and limits of every schedule pod |
| `suspendAll` | `false` | the operator's stop switch for every schedule |

The catalog gets `schedules.namespace`, `schedules.image` (repository, tag or digest, source hash), `schedules.reservedNames` (the chart's `schedules[].name`) and `schedules.reservedUserIds` (the same list as ADR 0016's `access.reserved.userIds`). The image is the platform's own `a2a-call`, never a value from a spec.

`install.sh` builds and loads the `a2a-call` image when the switch is on, not only when `schedules[]` is non-empty.

### Admission guard and RBAC

RBAC added for the controller, namespaced only:

| Namespace | Resource | Verbs |
|---|---|---|
| agents | `schedules` | get, list, watch, update (the finalizer) |
| agents | `schedules/status` | patch |
| schedule runs | `cronjobs` | get, list, create, patch, delete |
| schedule runs | `jobs` | get, list (status only; never create) |
| schedule runs | `configmaps`, `serviceaccounts` | get, list, create, patch, delete |

No pods, no `pods/log`, no `pods/exec`, no `serviceaccounts/token`, and **no rights on Secrets** in the schedule runs namespace. Two Roles for people that nothing binds: `openagentix-schedule-editor` (create, update, delete `schedules`) and `openagentix-schedule-viewer`. `openagentix-agent-builder` does not get `schedules`.

New allowlist policies, bound to the controller's ServiceAccount, `failurePolicy: Fail`, executed in `make test-guard` and `make test-apiserver`. Each covers CREATE, UPDATE and DELETE, in the pattern of `control-plane-guard-workload.yaml`:

- **All three kinds, metadata.** Only in the schedule runs namespace. CREATE: the object carries the controller's labels (all four parts above) and no other label or annotation key. UPDATE: the existing object (`oldObject`) and the new one both carry them, with the same values. DELETE: the existing object carries them, and its `openagentix.io/schedule-namespace` is the agents namespace. So the controller can never change or remove an object it did not create.
- **CronJobs.** Key sets at every level equal to what the controller writes. The image equals the chart's `a2a-call` image, rendered literally. `serviceAccountName` matches `<agents namespace>.<DNS label>-<8 hex>` and equals the `openagentix.io/schedule-namespace` and `openagentix.io/schedule` labels joined by a dot, plus `-` and the first 8 hex characters of the UID annotation. The pod template's labels are exactly `openagentix.io/component: schedule-run` and the controller's three labels; its annotations are exactly `openagentix.io/source-hash`. The environment has exactly the names `A2A_URL`, `A2A_USER_ID`, `A2A_TIMEOUT`, `PROMPT_FILE`, `A2A_TOKEN_FILE`; `PROMPT`, `TRACEPARENT`, `MAX_RESPONSE_BYTES`, `PRINT_ANSWER` and every other name are refused. `A2A_USER_ID` matches the lower-case user id set; `A2A_URL` equals the gate URL followed by `/agents/<agents namespace>/<DNS label>`. One projected token with the gate audience and an expiry of at most 3600 s, one ConfigMap volume whose name equals the CronJob's name. The security context exactly as today. `concurrencyPolicy` is `Forbid` unless the operator allowed `Allow`; `backoffLimit` at most `maxRetries`; `activeDeadlineSeconds` at most `maxTimeoutSeconds + 60`; `failedJobsHistoryLimit` at least `maxConsecutiveFailures`; `ttlSecondsAfterFinished` equal to the policy's; resources equal the policy's.
- **ConfigMaps.** One key `prompt.txt`, no `binaryData`, a value of at most 16384 characters. CEL `size()` counts characters, not bytes, so the guard is a ceiling; the controller is the authority for the 16384-byte limit.
- **ServiceAccounts.** Name pattern as above, `automountServiceAccountToken: false`, no `secrets`, no `imagePullSecrets`.
- **Schedule status.** The controller may patch `schedules/status` and update only the finalizer list.
- `guard-other` keeps refusing everything not listed.

What the guard cannot check: the cron expression's rate (CEL has no cron parser; a pattern on the string would be weaker than the Go check), that a CronJob matches an existing `Schedule`, and the message text beyond its size. So a compromised controller can make a schedule identity call the agents its own grants allow, as often as every minute, with any text. The gate still checks every call against the user's `AgentAccess`, and the agent's gateway budget still caps the tokens. That is the remaining blast radius. Pod Security `restricted` on the namespace is a second, independent layer for the pods.

### Audit

- The gate writes its usual line per run: `caller` is `serviceaccount:<runs namespace>/<ServiceAccount name>`, plus the `access` field of ADR 0016 naming the `AgentAccess`, the agent, the hashed user id, the trace id and the status. No message text, no answer.
- `a2a-call` prints its one-line summary without the answer, as today; the guard refuses `PRINT_ANSWER`.
- The controller logs the schedule name, the outcome of a pass and object names, never the message text. A condition message or violation never quotes the message.
- Status never holds the message text or an answer. The message is visible to anyone who can read `Schedule` objects in the agents namespace or ConfigMaps in the schedule runs namespace. The docs say so.

### Migration from chart-defined schedules

- `schedules[]` and `scheduling` keep working unchanged for at least one release after `Schedule` ships (0.3 and 0.4). Deprecation is a changelog note in 0.4; removal is a later decision with its own note.
- Both can run side by side. They use different namespaces, names and ServiceAccounts, and the guard keeps the controller off the chart's objects. A `Schedule` with the name of a chart schedule is refused, and so is a user id that a chart schedule holds.
- To move one schedule and keep its memory scope (its user id):
  1. Add the schedule runs namespace to `controlPlane.policy.access.callerNamespaces`.
  2. Remove the chart entry in a `helm upgrade`. This frees its reserved user id. While the chart entry exists, a `Schedule` or an `AgentAccess` with that user id is refused, so this step comes first.
  3. Create the `Schedule` under a **different name** from the chart entry (for example `<name>-v2`). The chart name is reserved in the catalog until the controller restarts with the new catalog after step 2; a new name does not depend on that timing. Create it with `suspend: true`, the same agent, cron, time zone and message, and `userId` set to the chart's id (lower case; a chart id with upper case letters cannot move unchanged).
  4. Copy `status.caller` into a new `AgentAccess` with `exact` and that user id, and wait for `AccessGranted=True`.
  5. Set `suspend: false`.
  Between steps 2 and 5 no firing happens. Choose a time between two firings.
- A schedule that keeps the default user id starts with an empty memory scope. That is the safe default and the migration guide says it.
- The upgrade notes in `CHANGELOG.md` say all of this in the slice that ships the kind.

## Amendments

These change ADR 0016 (still proposed) in the slice that builds this kind, not in this pull request:

- **One namespace exception.** `access.callerNamespaces` may list `controlPlane.schedules.namespace`, and only while `controlPlane.schedules.enabled` is true. Every other chart namespace stays refused.
- **One informational condition.** `AgentAccess` gets `CallerKnown`, reasons `Known` (True) and `NoSchedule` (False), set only for callers in the schedule runs namespace. It changes no verdict.
- `docs/api-conventions.md`, "Stop, not pause": `Schedule` is named as the kind whose `suspend` stops new firings only.
- `services/control-plane/README.md`, "What it never does": it writes CronJobs, ConfigMaps and ServiceAccounts in the schedule runs namespace, only in the shapes the guard allows, only with the switch on.

## Security considerations

- **Who can schedule.** Anyone with `openagentix-schedule-editor` in the agents namespace can make an agent run with a text of their choice, but only through an identity that someone with the access right has granted after the schedule existed. Nothing binds either Role by default.
- **Grants and names.** The ServiceAccount carries the schedule's UID, so deleting a schedule and creating another with the same name never inherits the old grant. A grant left behind is reported (`CallerKnown=False`) and matches no ServiceAccount the controller will create.
- **Who can act as a schedule.** Anyone who can create pods, ServiceAccount tokens or ServiceAccounts in the schedule runs namespace. No Role for people grants that there; the controller can create CronJobs, and the guard limits the ServiceAccount, image, environment, labels and volumes of every pod those CronJobs make. Pod Security `restricted` applies.
- **Prompt injection by schedule.** A schedule's message reaches the agent with the agent's tools. That is the same as any caller; tool profiles and egress rules apply. A schedule editor cannot pick a tool or a destination that the agent does not already have.
- **Cost.** Bounded by the four layers above and the gateway budget. Bursts are bounded in total, not in time. A compromised controller can bypass the rate layer (see the guard section) but not the gateway budget.
- **Revocation.** Deleting the `AgentAccess` stops runs at the gate within the ADR 0016 delay, and the next pass suspends the CronJob. Deleting the `Schedule` removes its objects. Without the controller, the stops listed under "While the controller is down" apply.
- **What leaves the cluster.** The message goes to the model provider through the gateway, as every message does.
- An independent security review is required before the slice that lets the controller write CronJobs is merged.

## Alternatives considered and rejected

| Alternative | Why not |
|---|---|
| Users write CronJobs (Option B) | Pod-create rights let them act as any schedule; no policy or status |
| Controller-side timer (Option C) | Needs tokens for every schedule identity, which is impersonation in the most privileged component |
| Argo or Tekton (Option D) | New upstream component for one HTTP call; possible later as a scheduler adapter |
| kagent's scheduler (Option E) | Broken for memory agents and cold agents in 1.0.1; runtime-specific |
| Reuse the chart schedules' namespace | ADR 0016 refuses it as a caller namespace; it has no Pod Security labels and Helm does not own it |
| A ServiceAccount name without the UID | Lets a schedule created later under the same name inherit the old grant |
| The controller creates the `AgentAccess` for each schedule | Merges the right to schedule with the right to grant: anyone who may write a schedule could give a new identity access to any agent of the namespace |
| `spec.access` inside the `Schedule` | Same reason |
| One shared ServiceAccount for all resource schedules | One stolen token acts as every schedule, and the audit line no longer names the schedule |
| `concurrencyPolicy: Replace` | Ends the pod but not the task, so it doubles cost instead of replacing a run |
| A message from a Secret | Every message goes to the model provider; a secret in it is leaked by design |
| A failure stop that a spec can turn off | A schedule's author is the person the stop protects the budget from |
| A rate limit in the gate per caller | The gate does not count over time today and keeps no state; the expression check is exact and needs no state. Kept as a later option for all callers |
| Counting tokens per schedule in 0.3 | The gateway counts per agent key; needs `Budget` (0.5) |

## Consequences

- A team can schedule its agent with `kubectl apply` and the console can edit schedules. An operator sets the limits once in policy.
- A schedule fails visibly (`AccessGranted=False`, `NoAccess`) until someone with the access right grants it. A grant can be written only after the schedule exists.
- The controller gets write rights in a third namespace and more guard policies.
- Becomes harder: two ways to schedule and two schedules namespaces exist for at least two releases; two default user id forms exist (`schedule:<name>` and `schedule:<namespace>.<name>`).
- Ruled out for now: a message from a Secret or a template, `Replace`, a context id that carries a conversation over runs, a token budget per schedule, schedules for agents in another namespace, grants created by the console, a "run now" action from the controller.
- Security impact: a new writer of pod templates (through CronJobs) in one new namespace, bounded by the guard and Pod Security; deny by default at three levels (chart switch, the namespace not listed in `callerNamespaces`, no `AgentAccess`).
- Compatibility: nothing changes for existing users. Default render unchanged.

## Test plan

Each slice is test first: the failing test is written and seen to fail before the code.

- **Cron and time** (pure Go, no cluster): the grammar, with every case of the chart's `oa.validateCron` tests as a shared table; `maxRunsPerDay` and `minIntervalMinutes` as a table (`* * * * *`, `*/15 * * * *`, `5/15 * * * *`, `0 8 * * 1-5`, `0,30 23 * * *` across midnight, `0 0 31 2 *` with zero runs); `nextRunTime` in several time zones, across a DST change, and `unknown` for a zone that cannot be loaded.
- **Differential test against the Kubernetes parser.** A test-only module (like `hack/ci/guardtest`, so the controller stays standard library only) runs `robfig/cron/v3` `ParseStandard` and the platform's parser over the shared table and a generated set of expressions (steps with a start, ranges with steps, names, day-of-month with day-of-week). For each it compares "accepted or refused" and the firing times over one leap year. Any difference fails CI.
- **Policy**: one case per refusal (name, reserved chart name, agent name, cron, never-matching cron, time zone, message size in bytes and secret scan, user id set and case, reserved or taken user id, each limit, `timeoutSeconds + 60` against the interval, `Replace`, `Allow` without permission, retries above the maximum, `fromConfigMap` "not available yet"); `maxSchedules` keeps the older.
- **Controller**: create, update, suspend, resume and delete (the issue's "done when") with `internal/kubetest`; the ServiceAccount name carries the UID and a schedule created again gets a new one; `AccessGranted` for each missing piece (no rule, other agent, no `SendMessage`, user id not admitted, rule not accepted, rule not ready) and the CronJob suspended in each case; grant added and removed; `CallerKnown=False` for a grant without a schedule; agent missing, suspended and back; `FailureLimit` after three failed Jobs, and again from CronJob times alone when the Jobs are gone, and reset on a new generation; the history floor whatever the spec says; `lastRun` and `consecutiveFailures` from Job status, `unknown` when the Jobs are gone; name conflict with a foreign object; the finalizer removes all three objects; never a request for a Secret, a pod or a log; the message text in no log line, condition or violation (a canary text); the reason table matches the README; no upstream words in the new packages.
- **Guard** (`make test-guard`): the controller's real output allowed; each refusal (another image, a chart schedule's ServiceAccount, a ServiceAccount that does not match the labels and UID, each of `PROMPT`, `TRACEPARENT`, `MAX_RESPONSE_BYTES`, `PRINT_ANSWER` and an unknown env name, another URL, an upper-case user id, a second token or a longer expiry, a host path, an extra pod label or annotation, `Allow` when not permitted, a larger `backoffLimit`, a lower failed history, other resources, a ConfigMap with a second key, a ServiceAccount with `secrets`); UPDATE and DELETE refused for objects without the controller's labels or with another `schedule-namespace`; status patch allowed, spec writes refused.
- **API server** (`make test-apiserver`): the CRD applies; schema refusals (6-field cron, `Replace`, no `agent`, message over the limit); status is a subresource; impersonated writes refused by the guard; the namespace's Pod Security refuses a privileged pod.
- **Chart** (`make test-chart`): default and every demo render byte-identical with the switch off; the switch on renders the CRD, the namespace with Pod Security labels, the Roles, the guard, the policy keys, the catalog section and the NetworkPolicies; the render fails without the control plane, without `agentAccess`, without the gate, for `maxTimeoutSeconds + 60 >= minIntervalMinutes × 60`, and for `finishedJobTtlSeconds` below 600. ADR 0016's chart test gains the one namespace exception.
- **Live proof** (quick start, stub model, no paid call): with default policy, a `* * * * *` schedule is refused. Then, with the policy lowered for the test (`minIntervalMinutes: 2`, `maxTimeoutSeconds: 30`, written in the diary), a `*/2 * * * *` schedule shows `NoAccess` and a suspended CronJob; after the `AgentAccess` it fires, the stub model answers, `lastRun.result` is `Succeeded`, the gate audit line names the schedule identity; deleting the `AgentAccess` suspends it; deleting and creating the schedule again gives a new identity that the old grant does not cover; deleting the `Schedule` removes its objects. Measured: time from grant to first successful run. Written in the diary with the limits.

## Slices

1. **This ADR**, reviewed for at least 7 days (new kind, security model).
2. **Pure parts.** Types, CRD, cron grammar and the differential test, rate analysis, next-run computation, policy checks, reason table. Nothing is written to a cluster; no chart switch. Can be built before ADR 0016's controller.
3. **The controller writes schedules, with the public switch.** The namespace, objects, finalizer, `AccessGranted` from `AgentAccess` (needs ADR 0016 slice 3), the two ADR 0016 amendments, status from CronJobs and Jobs, the failure stop with both counts, `suspendAll`, coupling with a suspended agent, RBAC, guard policies, Roles, the switch-off refusal, `install.sh`, live proof, independent security review. The switch `controlPlane.schedules.enabled` becomes public in this slice and not before, so it never exists without the cost stops. This closes issue #4 except the migration.
4. **Cancel on timeout.** `a2a-call` sends `CancelTask` when it times out, only if the grant allows that method and the runtime honours it (see below). Then the "agent tasks may overlap" limit is removed from the docs.
5. **Migration guide, console and deprecation note** for `schedules[]`.

## Not checked / open points

- *Unverified*: how the Kubernetes CronJob controller handles a DST change for a `timeZone` (a skipped or repeated hour). The rate check assumes the expression's own gaps; a repeated hour could fire one extra time. Tested on kind in slice 3.
- *Unverified*: whether kagent stops a task on A2A `CancelTask`. Until it does, a timed-out run can keep spending tokens after its Job ends, and the docs must say so.
- *Unverified*: the delay from a new `AgentAccess` to the gate loading it (ADR 0016), and so the time to a schedule's first successful run.
- *Unverified*: that a dotted ServiceAccount name works everywhere it is used (the projected token's subject, TokenReview, the gate's identity string). Checked by the live proof; if it fails, the name becomes `<agents namespace>-<name>-<8 hex>` with a length rule, before the kind ships.
- *Unverified*: that `lookup` of a custom resource works for every way the chart is installed (it needs list rights for the person running Helm). If not, the switch-off path becomes a pre-upgrade check in `install.sh`.
- *Unverified*: where `robfig/cron/v3` differs from the chart's `oa.validateCron` today. The differential test shows it; the chart check follows the Kubernetes parser where they differ.
- This ADR depends on ADR 0016. If ADR 0016 changes (for example the gate watches `AgentAccess` itself), `AccessGranted` follows the new "published" signal.
- Open for the owner: are the default limits right (24 runs a day, 15 minutes apart, 10 schedules, 600 s, 3 failures)? They are chosen to keep a forgotten schedule cheap, not to fit every use.
- Open for the owner: should a later release allow the console, after console login, to create the matching `AgentAccess` for a user who holds the access right (checked with a SubjectAccessReview)?
- Open for the owner: should there be a limit per agent (schedules per agent, or runs per agent per hour) against bursts, or is the gateway budget enough?
