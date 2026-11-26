# ADR 0024: availability defaults for platform workloads

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/197 (umbrella #212; slices #198, #199; tests #201, #204)
Replaces: none

Every Deployment and StatefulSet of the chart gets a PodDisruptionBudget with `maxUnavailable: 1`, on by default. The A2A gate and the console default to two replicas with a soft spread over nodes and zones; the quick start and minimal profiles keep one of each. Every other workload stays at one replica, for a reason named per workload below. The chart sets no priority class unless the operator names one. Four new chart values become public.

## Context

Release 0.3 has the exit criterion "probes, resources and a PodDisruptionBudget for every workload" (#212). Issue #197 asks, per workload, whether it can run more than one replica, which budget it gets, whether it is spread, whether it gets a priority class, and whether the default render changes.

What the chart renders today (main at `88a8b9c`, read with `helm template` on 2026-11-26 for four renders: the defaults, the quick start `components/quickstart/values.yaml`, the minimal profile on top of it, and the full demo with the ten values files from `CLAUDE.md`):

- 0 PodDisruptionBudgets, 0 priority classes, 0 affinity or topology rules, in every render.
- Every Deployment and StatefulSet has `replicas: 1`. Only `knowledge.kb.replicas` is a value; every other count is fixed in the template.
- Every workload selects its pods with one label, `app: <name>`, and the pod template carries that label (`spec.selector.matchLabels`).
- The default render (Helm only, no values) contains five workloads: `telegram-bridge`, `kb`, `kb-postgres`, `kb-embeddings` and `memory-embeddings`. The gate, the console, the control plane, notify and the observability backends are off by default.

Facts per workload, read in the templates and the service code:

| Workload | Namespace | Rendered in | Strategy today | What a second replica would break | Source |
|---|---|---|---|---|---|
| `openagentix-control-plane` | release namespace | quick start, minimal, full | Recreate | No leader election: two controllers would both reconcile and write. ADR 0007 decided one replica. | `templates/control-plane.yaml:189`; no Lease code in `services/control-plane` |
| `openagentix-console` | release namespace | quick start, full | Recreate | Nothing that breaks. Each request carries a bearer token checked against a mounted file; there is no session store. The failed-login throttle and the validate rate limit (60 per minute per identity) live in the process, so each replica counts on its own. | `services/console/internal/builtin/builtin.go:22`, `internal/server/guard.go:129`, `server.go:95` |
| `a2a-gate` | `openagentix-gateway` | quick start, minimal, full | RollingUpdate (25 %) | Nothing that breaks. Rules come from a ConfigMap and key hashes from a Secret, both read by every pod. Per process: the 30 s TokenReview cache, the in-flight cap (128), and the salt of the audit user id hash (random per process). | `templates/governance.yaml:47`, `services/a2a-gate/cmd/a2a-gate/main.go:71`, `internal/auth/auth.go` |
| `telegram-bridge` | `openagentix-gateway` | default, full | Recreate | Telegram allows one long poller per bot token; offsets are in memory. | `templates/bridge.yaml:15` |
| `kb` | `openagentix-knowledge` | default, full | RollingUpdate (25 %) | Nothing that breaks: migrations run under a PostgreSQL advisory lock and graph extraction jobs are leased with `FOR UPDATE SKIP LOCKED`. | `services/kb/internal/store/postgres/postgres.go:103`, `graph.go:729`, `services/kb/README.md:153` |
| `kb-postgres` (StatefulSet) | `openagentix-knowledge` | default, full | RollingUpdate | One primary, no replication. | `templates/knowledge.yaml:211` |
| `kb-embeddings` | `openagentix-knowledge` | default, full | Recreate | The model cache is a ReadWriteOnce PVC. | `templates/knowledge.yaml:332` |
| `memory-embeddings` | `openagentix-memory` | default, full | Recreate | The model cache is a ReadWriteOnce PVC. | `templates/memory.yaml:93` |
| `notify` | `openagentix-notify` | full | Recreate | Rate limits, the in-flight cap and idempotency keys are in the process: two replicas double every limit and can deliver a message twice. | `templates/notify.yaml:12` |
| `victoria-metrics` | `openagentix-observability` | quick start, full | Recreate | Single-node VictoriaMetrics on a ReadWriteOnce PVC. | `templates/observability.yaml:197` |
| `jaeger` | `openagentix-observability` | quick start, full | Recreate | Traces are in memory: two replicas split them. | `templates/observability.yaml:273` |
| `stub-model` | `agentgateway-system` | quick start, minimal | RollingUpdate (25 %) | Nothing, but it is a test fixture with scripted answers. | `templates/stub-model.yaml:29` |

Out of this decision: the CronJobs (`memory-expiry` and each schedule), the container agents that the control plane creates (the admission guard pins them to 0 or 1 replica, `templates/control-plane-guard-workload.yaml:161`, and the controller has no right to write a PodDisruptionBudget), and the upstream workloads that the installer adds (kagent, agentgateway including the model gateway proxy, ToolHive, Agent Substrate), which are tracked in #211.

Kubernetes behaviour this decision relies on, read in the Kubernetes documentation for the `policy/v1` API on 2026-11-26, not yet run in this repository (*unverified* until the tests below run):

- With `maxUnavailable: 1` and one replica, the budget allows one disruption while the pod is healthy, and an unhealthy or pending pod is never protected. A drain is never blocked by such a budget.
- With `minAvailable: 1` and one replica, the budget allows zero disruptions. `kubectl drain` retries the eviction forever. Managed upgrades wait and then force the drain (GKE documents a wait of up to one hour; read again before quoting).
- `unhealthyPodEvictionPolicy: AlwaysAllow` lets a pod that is Running but not Ready be evicted even when the budget is used up. Without it, two crash-looping replicas behind `minAvailable: 1` or `maxUnavailable: 1` block a drain.
- When a pod is selected by more than one PodDisruptionBudget, the eviction API refuses to evict it (HTTP 500). A user who already wrote a budget for one of our pods would see every drain fail once we add ours.
- A pod on a node that stops answering is evicted after the default tolerations of 300 s (`node.kubernetes.io/not-ready` and `unreachable`). A PodDisruptionBudget does not apply to this: it covers voluntary disruptions only.
- A topology spread constraint with `whenUnsatisfiable: ScheduleAnyway` is a scoring rule: on one node every replica still schedules.

The quick start runs on one kind node (README: Docker with 4 CPU and 8 GB; the full demo was installed on a 6 CPU, 8 GiB VM; ADR 0014 measured the quick start's cost). A second gate and console add 20m CPU and 56Mi memory in requests, and 500m and 192Mi in limits (`values.yaml`, `governance.a2a.resources` and `console.resources`). On one node a second replica protects against a crash or a rollout, not against the node.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Do nothing | Nothing to build | A drain, an upgrade or one crash of the gate cuts every caller off; the 0.3 exit criterion is not met | the four renders above |
| B. `minAvailable: 1` on every workload | A budget everywhere | Blocks every drain of a node with a single-replica pod; a managed upgrade waits, then forces | Kubernetes documentation |
| C. A budget only for workloads with two or more replicas | Fewer objects; nothing that looks like a no-op | The exit criterion is not met; a workload raised to two replicas later can be forgotten; no single invariant for a chart test | issue #198 |
| D. `maxUnavailable: 1` on every Deployment and StatefulSet, behind one switch that is on by default | One invariant, tested on every render; never blocks a drain on one replica; keeps one pod up when there are two or more | The default render gains five objects; a user with own budgets must turn ours off (double budgets break eviction); Helm needs rights on `poddisruptionbudgets` | Kubernetes documentation, the renders |
| E. As D, but off by default and turned on by the installer profiles | The default render stays byte-identical | A Helm-only install, which is the production path, gets nothing; profiles and chart differ for a safety property | the renders |
| F. Per-workload budget values (`enabled`, `minAvailable`, `maxUnavailable` for each) | Full control | Twelve more public values and their tests, for a need nobody has stated | not built |
| G. Two replicas for the gate and the console, soft spread over host and zone | The request path survives a drain, a rollout and a crash | 56Mi more requested memory; per-pod caches and limits (see Security) | the service code above |
| H. As G with a hard spread (`DoNotSchedule`) or required anti-affinity | A guarantee of two nodes | The second replica stays Pending on a one-node cluster (kind, k3d, a one-node GKE pool) | Kubernetes documentation |
| I. Two replicas for the gate and console in the quick start too | The quick start shows the production shape | Memory on the smallest machine, for a gain against crashes and rollouts only | ADR 0014 sizing |
| J. Leader election in the control plane, then two replicas | The controller survives a drain | Code, a Lease Role (an RBAC change, security-relevant), and a change of ADR 0007; while the controller is down, agents keep serving and only changes wait | ADR 0007 |
| K. The chart creates a PriorityClass and sets it on its pods | Platform pods are scheduled first and can preempt | A cluster-scoped object that preempts other teams' pods; that is the platform team's decision, not ours | not built |
| L. HorizontalPodAutoscaler for the gate | Scale with load | Needs metrics-server; no load data that asks for it | not built |

## Decision

Options D and G, with the quick start and minimal profiles at one replica (not I). Not now: J, K, L. Rejected: B, C, E, F, H.

### Per workload

| Workload | Replicas (chart default) | Quick start and minimal | Value | PodDisruptionBudget | Spread | Strategy |
|---|---|---|---|---|---|---|
| `a2a-gate` | 2 | 1 | `governance.a2a.replicas` (new) | `maxUnavailable: 1` | when replicas > 1 | RollingUpdate, `maxSurge: 1`, `maxUnavailable: 0` (made explicit) |
| `openagentix-console` | 2 | 1 (console is off in minimal) | `console.replicas` (new) | `maxUnavailable: 1` | when replicas > 1 | RollingUpdate, `maxSurge: 1`, `maxUnavailable: 0` (was Recreate) |
| `kb` | 1 | not rendered | `knowledge.kb.replicas` (exists) | `maxUnavailable: 1` | when replicas > 1 | unchanged |
| `openagentix-control-plane` | 1, fixed | 1 | none | `maxUnavailable: 1` | no | Recreate, unchanged |
| `telegram-bridge` | 1, fixed | not rendered | none | `maxUnavailable: 1` | no | Recreate, unchanged |
| `kb-postgres` | 1, fixed | not rendered | none | `maxUnavailable: 1` | no | unchanged |
| `kb-embeddings` | 1, fixed | not rendered | none | `maxUnavailable: 1` | no | Recreate, unchanged |
| `memory-embeddings` | 1, fixed | not rendered | none | `maxUnavailable: 1` | no | Recreate, unchanged |
| `notify` | 1, fixed | not rendered | none | `maxUnavailable: 1` | no | Recreate, unchanged |
| `victoria-metrics` | 1, fixed | 1 (quick start), not rendered (minimal) | none | `maxUnavailable: 1` | no | Recreate, unchanged |
| `jaeger` | 1, fixed | 1 (quick start), not rendered (minimal) | none | `maxUnavailable: 1` | no | Recreate, unchanged |
| `stub-model` | 1, fixed | 1 | none | `maxUnavailable: 1` | no | unchanged |

Why `maxUnavailable: 1` and not `minAvailable`: it is the same budget as `minAvailable: 1` at two replicas, it still keeps all but one pod up at three or more, and at one replica it never blocks a drain. A budget on a single replica changes no eviction; it is there so that one rule holds for every workload, so that a chart test can enforce it, and so that the budget is already in place when a count goes up.

Why the gate and the console: the gate is on the path of every A2A caller, and the console is the operator's view. Both hold no state that a second replica breaks. The kb could run two (it is safe, see Context) but its database and embedding server stay single, so a second kb gains little; it stays at one, and the value already lets an operator raise it.

Why one replica in the quick start and minimal profiles: they run on one node, where a second replica helps against a crash or a rollout but not a node, and ADR 0014 keeps the quick start small. `components/quickstart/values.yaml` sets `governance.a2a.replicas: 1` and `console.replicas: 1`; `minimal-values.yaml` inherits them. A user who starts from the quick start on a real cluster sets both to 2; the install guides get that line in the #199 slice.

### Chart values (public contract)

```yaml
# ---- Availability (ADR 0024) --------------------------------------------------------------------
availability:
  podDisruptionBudgets:
    enabled: true          # one PodDisruptionBudget (maxUnavailable: 1) per Deployment and StatefulSet of this chart.
                           # false: none. Turn it off when you write your own budgets for these pods: a pod selected by
                           # two budgets cannot be evicted at all.
  topologySpread:
    enabled: true          # soft spread (ScheduleAnyway) over nodes and zones, only for a workload with more than one replica
  priorityClassName: ""    # an existing PriorityClass for the pods of every Deployment and StatefulSet of this chart; empty: none

governance:
  a2a:
    replicas: 2            # new
console:
  replicas: 2              # new
knowledge:
  kb:
    replicas: 1            # exists; now validated
```

Rules for the render:

- `governance.a2a.replicas`, `console.replicas` and `knowledge.kb.replicas` must be whole numbers of at least 1. Anything else (0, a negative number, a string, a fraction) fails the render with one sentence that names the value and the range. Zero is refused because it looks like "off" and is not; the `enabled` switches turn a workload off.
- No other workload gets a replicas value. A workload is added to the list above only with a change of this ADR that names why a second replica is safe.
- `availability.priorityClassName` must be empty or a DNS-1123 subdomain; it is set as `spec.template.spec.priorityClassName` on every Deployment and StatefulSet of the chart and on nothing else (not on CronJobs, not on what the control plane creates). The chart does not create the class and cannot check that it exists: if it does not, the API server refuses the pods and the ReplicaSet events say so. The upgrade note names this.
- No value name uses an upstream word.

### Objects

One PodDisruptionBudget per Deployment and StatefulSet, in its namespace, with the workload's name, rendered by one helper (`oa.pdb`) next to each workload:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: <workload name>
  namespace: <workload namespace>
  labels: {app: <name>, <oa.labels>}
spec:
  maxUnavailable: 1
  unhealthyPodEvictionPolicy: AlwaysAllow
  selector:
    matchLabels: <exactly the workload's spec.selector.matchLabels>
```

The selector is copied from the same template value as the workload's selector, so the two cannot drift. A budget is rendered exactly when its workload is rendered.

For a workload with more than one replica and `availability.topologySpread.enabled`, the pod template gets:

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway
    labelSelector: {matchLabels: <the workload's selector>}
    matchLabelKeys: [pod-template-hash]
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway
    labelSelector: {matchLabels: <the workload's selector>}
    matchLabelKeys: [pod-template-hash]
```

`matchLabelKeys` counts only the pods of one ReplicaSet, so a rollout does not skew the spread of the new pods. Spread rather than pod anti-affinity: one shape covers nodes and zones, and it is a score, not a filter.

The gate and the console, at any replica count, also get `lifecycle.preStop.sleep: {seconds: 5}`. The sleep keeps a stopping pod serving while the Service endpoints drop it, so a rollout does not refuse new connections. It is the built-in sleep action, so it does not need a shell in the image. The grace period covers the sleep plus the drain each server already allows on SIGTERM: the gate drains for 25 s (`services/a2a-gate/cmd/a2a-gate/main.go:113`), so its `terminationGracePeriodSeconds` goes from 30 to 35; the console drains for 10 s (`services/console/cmd/console/main.go:152`), so its 30 s stays.

### What the default render changes, and why that is allowed

The rule is: with a feature off, the default render is byte-identical. Here the default changes on purpose, by exactly five objects: the PodDisruptionBudgets of `telegram-bridge`, `kb`, `kb-postgres`, `kb-embeddings` and `memory-embeddings`. Nothing else in the default render changes: the gate and console are off by default, spread is rendered only above one replica, and the priority class is empty.

Why this is accepted:

- The rule protects users from behaviour they did not ask for. A `maxUnavailable: 1` budget on one replica allows every eviction that the cluster allowed before. It refuses nothing.
- The 0.3 exit criterion asks for a budget on every workload, and a Helm-only install is the production path. Option E would leave that path without one.
- `availability.podDisruptionBudgets.enabled: false` gives back the old render byte for byte, and a chart test proves it against a render of the chart before this change.

The quick start, minimal and full demo renders also change: their budgets, the console's strategy (Recreate to RollingUpdate), the explicit gate strategy, the preStop sleep, the gate's grace period, and in the full demo the second replicas and spread rules.

### Upgrade note (CHANGELOG, 0.3)

"The chart now renders a PodDisruptionBudget (`maxUnavailable: 1`) for each of its Deployments and StatefulSets, on by default (`availability.podDisruptionBudgets.enabled`). Before you upgrade, run `kubectl get pdb -A`. If you wrote your own budgets for OpenAgentix pods, set `availability.podDisruptionBudgets.enabled: false` or delete yours: a pod that two budgets select cannot be evicted, so every node drain would fail. A budget with the same name in the same namespace stops the upgrade (Helm cannot take it over). The account that runs Helm needs `create`, `update` and `delete` on `poddisruptionbudgets` (group `policy`) in each platform namespace. The A2A gate and the console now run two replicas by default (`governance.a2a.replicas`, `console.replicas`); the quick start and minimal profiles keep one. The console now updates by rolling update instead of Recreate. `availability.priorityClassName` must name a PriorityClass that exists, or the pods are refused."

## Consequences

- A node drain, a cluster upgrade and a rollout no longer cut every A2A caller off when the gate runs two replicas on two nodes. With one node, two replicas still cover a crash and a rollout.
- Single-replica workloads are still down while they move. On a drain that is the time to start again elsewhere; on a node failure it is at least the 300 s toleration plus start time, and longer or until the node returns for anything on a ReadWriteOnce volume (`kb-postgres`, both embedding servers, `victoria-metrics`). Shorter tolerations are not part of this decision; #204 measures first.
- The model path is still single: the model gateway proxy (agentgateway, not our chart) runs one replica. That is #211, not this ADR.
- A long A2A stream through a gate pod that stops is cut after the 25 s drain; the caller must retry. Two replicas do not change that.
- Ruled out for now: a second control plane (needs leader election, a new ADR changing ADR 0007), a second bridge or notify (their state is in the process), per-workload budget values.
- Security impact:
  - Who may call what does not change: both gate pods read the same rules and keys, and a change of either rolls both.
  - Gate at two replicas: each pod has its own 30 s TokenReview cache (a revoked token can still pass for up to 30 s in each pod, the same bound as today) and its own in-flight cap (cluster total 256). The audit user id hash uses a salt that is random per process, so at the same time the two pods write different hashes for the same user. Today the hash already changes at every restart. Audit readers can join a user's lines only within one pod's life; `governance.a2a.audit.userId: raw` is unchanged. A shared salt (from a Secret) would make the hash stable over time and is a separate security decision (open point).
  - Console at two replicas: the failed-login throttle and the validate rate limit count per pod, so an attacker gets at most twice the attempts. install.sh makes the token from 48 random characters and the console refuses fewer than 32, so this does not change what guessing can reach.
  - The budgets, spread rules and an empty priority class change no permission. A priority class lets our pods preempt others only when the operator names one.
  - The controller gets no new RBAC. Helm needs rights on `poddisruptionbudgets` (upgrade note).
  - The gate slice (#199) changes how audit identities appear, so it gets an independent review before merge.
- Compatibility: see the upgrade note. OpenShift (`platform: openshift`) renders the same objects; nothing in them conflicts with restricted-v2.

### Tests and proof before this counts as done

Chart tests in `charts/openagentix/tests/run.sh`, each shown failing before the templates change:

1. For the default, quick start, minimal, full demo and `platform=openshift` renders: every Deployment and StatefulSet has exactly one PodDisruptionBudget in its namespace whose `selector.matchLabels` equals the workload's `spec.selector.matchLabels`; every rendered budget matches exactly one workload; no pod template is selected by two budgets (#198).
2. Every budget is `policy/v1`, has `maxUnavailable: 1`, has no `minAvailable`, and has `unhealthyPodEvictionPolicy: AlwaysAllow`.
3. `availability.podDisruptionBudgets.enabled=false` renders no budget, and the default render with it equals the baseline render of the chart before this change (`OA_BASELINE_RENDER`, as in the ADR 0023 test); the default render without the five budgets equals the baseline.
4. `availability.topologySpread.enabled=false` and `availability.priorityClassName=""` are byte-identical to the default render.
5. Full demo: `a2a-gate` and `openagentix-console` have 2 replicas, RollingUpdate with `maxSurge: 1` and `maxUnavailable: 0`, the two spread constraints with the workload's selector and `matchLabelKeys: [pod-template-hash]`, the preStop sleep of 5 s, and a grace period of 35 s for the gate and 30 s for the console (#199).
6. Quick start and minimal: the gate and the console have 1 replica and no spread constraint.
7. Every workload not in the replicas-value list renders `replicas: 1` in every render, so a count cannot be raised by accident.
8. `governance.a2a.replicas`, `console.replicas` and `knowledge.kb.replicas` set to `0`, `-1`, `1.5` and `"two"` each fail the render with the range in the message; `knowledge.kb.replicas=2` renders the spread constraints on `kb`.
9. `availability.priorityClassName=platform-high` sets the field on every Deployment and StatefulSet pod template and on no CronJob; an invalid name fails the render.

The probes and resources test of #201 is separate and unchanged by this ADR.

API server: `make test-apiserver` applies, with `--dry-run=server`, every budget of the full demo render and the gate and console Deployments (namespaces created in the throwaway cluster), so `unhealthyPodEvictionPolicy`, `matchLabelKeys` and the preStop sleep action are checked by a real API server, not only by the render.

On a cluster (each result goes into `docs/diary/what-works.md` with its limits):

- #198: a kind cluster with two worker nodes (its own name and kubeconfig, never the user's cluster), full demo values. `kubectl drain` of the node with the platform pods finishes, and is not blocked by a budget on a single replica. Output in the pull request.
- #199: a client sends one A2A request per second through the gate during `kubectl rollout restart deploy/a2a-gate`; no request fails. Script and output in the pull request.
- #204: stop the node with the platform pods (`docker stop`). Expected, to be confirmed or corrected by the run: the gate (two replicas) keeps answering after its endpoints drop the lost pod; stateless single replicas come back on the other node after about 300 s plus start time; `kb-postgres`, both embedding servers and `victoria-metrics` stay down until the node returns, because kind's local volumes cannot move. The test prints what recovered and how long it took.

## Not checked / open points

- Everything about Kubernetes behaviour in Context is read from documentation, not run here: *unverified* until the tests above run.
- The memory cost of the second gate and console in the full demo on a 6 CPU, 8 GiB VM is computed from requests, not measured.
- Should the quick start on a remote cluster (`CLUSTER_TYPE=remote PROFILE=quickstart`) run two gate replicas, since a real cluster often has more than one node? This ADR keeps one; the installer could set two on remote. Owner to decide.
- Should the audit hash salt be shared by the gate replicas (a Secret made by install.sh)? It makes hashes comparable across pods and over time, which helps audits and also makes a user easier to follow. Separate security decision.
- Should the kb run two replicas in the full demo? It is safe; the gain is small while its database is single.
- Should the stateless single replicas (control plane, console at one replica, stub model) get shorter not-ready tolerations than 300 s? Decide after #204 gives a number.
- Should the embedding model caches become `emptyDir`, so the embedding servers can move on a node failure at the cost of a download (about 120 MB for the memory model)? Linked to the volume keep decision of #206.
- A per-workload priority class, if a platform team asks for one.
- Replicas and budgets for the upstream workloads, above all the model gateway proxy: #211.
