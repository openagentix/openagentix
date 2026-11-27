# ADR 0024: availability defaults for platform workloads

Status: Accepted (2026-11-27)
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/197 (umbrella #212; slices #198, #199; tests #201, #204)
Replaces: none

The 7-day review period was waived by the maintainer on 2026-11-27; an independent review was done and its changes are in this text.

Every Deployment and StatefulSet of the chart gets a PodDisruptionBudget with `maxUnavailable: 1`, on by default. This is a stated exception to the rule "off by default, byte-identical default render". The A2A gate and the console default to two replicas with a soft spread over nodes and zones; the quick start and minimal profiles keep one of each. Every other workload stays at one replica, for a reason named per workload below. The chart sets no priority class unless the operator names one. Four new chart values become public.

## Context

Release 0.3 has the exit criterion "probes, resources and a PodDisruptionBudget for every workload" (#212). Issue #197 asks, per workload, whether it can run more than one replica, which budget it gets, whether it is spread, whether it gets a priority class, and whether the default render changes.

What the chart renders today (main at `88a8b9c`, read with `helm template` on 2026-11-26 for four renders: the defaults, the quick start `components/quickstart/values.yaml`, the minimal profile on top of it, and the full demo with the ten values files from `CLAUDE.md`):

- 0 PodDisruptionBudgets, 0 priority classes, 0 affinity or topology rules, in every render.
- Every Deployment and StatefulSet has `replicas: 1`. Only `knowledge.kb.replicas` is a value; every other count is fixed in the template.
- Every workload selects its pods with one label, `app: <name>` (`spec.selector.matchLabels`). The pod templates also carry `app.kubernetes.io/instance` and `app.kubernetes.io/part-of` (from the `oa.labels` helper, `templates/_helpers.tpl:1`), except `victoria-metrics` and `jaeger`, whose pod templates carry only `app` (`templates/observability.yaml:202` and `:278`).
- The control plane and the console run in the release namespace, which is `default` for a plain `helm install`. Other teams' pods there can carry the same `app` label.
- The default render (Helm only, no values) contains five workloads: `telegram-bridge`, `kb`, `kb-postgres`, `kb-embeddings` and `memory-embeddings`. The gate, the console, the control plane, notify and the observability backends are off by default.

Facts per workload, read in the templates and the service code:

| Workload | Namespace | Rendered in | Strategy today | What a second replica would change | Source |
|---|---|---|---|---|---|
| `openagentix-control-plane` | release namespace | quick start, minimal, full | Recreate | No leader election: two controllers would both reconcile and write. ADR 0007 decided one replica. | `templates/control-plane.yaml:189`; no Lease code in `services/control-plane` |
| `openagentix-console` | release namespace | quick start, full | Recreate | Each request carries a bearer token checked against a mounted file; there is no session store. The failed-login limits (per address and over all addresses) and the validate rate limit (60 per minute per identity) live in the process, so each replica counts on its own. | `services/console/internal/builtin/builtin.go:22`, `internal/server/guard.go:129` and `:153`, `server.go:95` |
| `a2a-gate` | `openagentix-gateway` | quick start, minimal, full | RollingUpdate (25 %) | The rules come from a ConfigMap whose checksum is on the pod template. The key hashes (a Secret) and the routes of container agents (a ConfigMap the controller writes) are mounted files that each pod reads on its own. Per process: the 30 s TokenReview cache, the TokenReviews at once (8), the in-flight cap (128), the cap per container agent (32), and the salt of the audit user id hash. | `templates/governance.yaml:47`, `:67`, `:140`; `services/a2a-gate/cmd/a2a-gate/main.go:71`, `:77`; `internal/gate/gate.go:48`, `:57`; `internal/auth/auth.go:70` |
| `telegram-bridge` | `openagentix-gateway` | default, full | Recreate | Telegram allows one long poller per bot token; offsets are in memory. | `templates/bridge.yaml:15` |
| `kb` | `openagentix-knowledge` | default, full | RollingUpdate (25 %) | Migrations run under a PostgreSQL advisory lock and graph extraction jobs are leased with `FOR UPDATE SKIP LOCKED`, so two replicas do not corrupt data. The graph extraction token budget (`knowledge.kb.graph.tokensPerHour`) is kept in each process, so two replicas may spend twice the budget. | `services/kb/internal/store/postgres/postgres.go:103`, `graph.go:729`, `services/kb/README.md:153`, `services/kb/internal/graph/worker.go:33`, `:84` |
| `kb-postgres` (StatefulSet) | `openagentix-knowledge` | default, full | RollingUpdate | One primary, no replication. | `templates/knowledge.yaml:211` |
| `kb-embeddings` | `openagentix-knowledge` | default, full | Recreate | The model cache is a ReadWriteOnce PVC. | `templates/knowledge.yaml:332` |
| `memory-embeddings` | `openagentix-memory` | default, full | Recreate | The model cache is a ReadWriteOnce PVC. | `templates/memory.yaml:93` |
| `notify` | `openagentix-notify` | full | Recreate | Rate limits, the in-flight cap and idempotency keys are in the process: two replicas double every limit and can deliver a message twice. | `templates/notify.yaml:12` |
| `victoria-metrics` | `openagentix-observability` | quick start, full | Recreate | Single-node VictoriaMetrics on a ReadWriteOnce PVC. | `templates/observability.yaml:197` |
| `jaeger` | `openagentix-observability` | quick start, full | Recreate | Traces are in memory: two replicas split them. | `templates/observability.yaml:273` |
| `stub-model` | `agentgateway-system` | quick start, minimal | RollingUpdate (25 %) | Nothing, but it is a test fixture with scripted answers. | `templates/stub-model.yaml:29` |

Out of this decision: the CronJobs (`memory-expiry` and each schedule), the container agents that the control plane creates (the admission guard pins them to 0 or 1 replica, `templates/control-plane-guard-workload.yaml:161`, and the controller has no right to write a PodDisruptionBudget), and the upstream workloads that the installer adds (kagent, agentgateway including the model gateway proxy, ToolHive, Agent Substrate), which are tracked in #211.

Kubernetes behaviour this decision relies on, read in the Kubernetes documentation on 2026-11-26, not yet run in this repository (*unverified* until the tests below run):

- With `maxUnavailable: 1` and one replica, the budget allows one disruption while the pod is healthy, and an unhealthy or pending pod is never protected. A drain is not blocked by such a budget.
- With two replicas and nowhere to place a replacement (a one-node cluster, or a second node without room), a drain evicts one pod, its replacement stays Pending, and every further eviction is answered with HTTP 429 until a replacement is Ready. `kubectl drain` retries forever. The same holds for `minAvailable: 1` on one replica on any cluster.
- Managed upgrades wait on a budget and then force the drain (GKE documents a wait of up to one hour; read again before quoting).
- `unhealthyPodEvictionPolicy: AlwaysAllow` lets a pod that is Running but not Ready be evicted even when the budget is used up. Without it, two crash-looping replicas block a drain.
- When a pod is selected by more than one PodDisruptionBudget, the eviction API refuses to evict it (HTTP 500).
- Node failure is not a voluntary disruption, and budgets do not apply to it. A node is marked NotReady after the node monitor grace period (about 40 to 50 s). Only then do the default tolerations of 300 s (`node.kubernetes.io/not-ready` and `unreachable`) start, so a pod on a lost node is marked for deletion after about 6 minutes. The pod then stays Terminating until the node answers again.
  - A Deployment creates the replacement as soon as the old pod is marked for deletion. If the replacement needs a ReadWriteOnce volume, it waits for the volume: on a cloud disk the attach/detach controller force-detaches it after about 6 more minutes; a node-local volume (kind's local-path) never moves.
  - A StatefulSet does not create the replacement while the old pod is Terminating, whatever the volume type, until the node returns, someone force-deletes the pod, or the node gets the `node.kubernetes.io/out-of-service` taint.
- A topology spread constraint with `whenUnsatisfiable: ScheduleAnyway` is a scoring rule used only when a pod is scheduled: on one node every replica still schedules, and nothing moves pods back when a node returns.
- Minimum versions, from the Kubernetes feature gate table: the preStop `sleep` action (`PodLifecycleSleepAction`) is beta and on by default from 1.30, stable from 1.34; `matchLabelKeys` in topology spread (`MatchLabelKeysInPodTopologySpread`) is beta and on by default from 1.27; `unhealthyPodEvictionPolicy` is on by default from 1.27 (beta; read again before quoting its stable version). The objects of this ADR therefore need Kubernetes 1.30 or newer. The project already requires 1.37 (README), so no supported cluster is excluded.

The quick start runs on one kind node (README: Docker with 4 CPU and 8 GB; the full demo was installed on a 6 CPU, 8 GiB VM; ADR 0014 measured the quick start's cost). A second gate and console add 20m CPU and 56Mi memory in requests, and 500m and 192Mi in limits (`values.yaml`, `governance.a2a.resources` and `console.resources`). On one node a second replica protects against a crash or a rollout, not against the node.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Do nothing | Nothing to build | A drain, an upgrade or one crash of the gate cuts every caller off; the 0.3 exit criterion is not met | the four renders above |
| B. `minAvailable: 1` on every workload | A budget everywhere | Blocks every drain of a node with a single-replica pod; a managed upgrade waits, then forces | Kubernetes documentation |
| C. A budget only for workloads with two or more replicas | Fewer objects; nothing that looks like a no-op | The exit criterion is not met; a workload raised to two replicas later can be forgotten; no single invariant for a chart test | issue #198 |
| D. `maxUnavailable: 1` on every Deployment and StatefulSet, behind one switch that is on by default | One invariant, tested on every render; does not block a drain on one replica; keeps one pod up when there are two or more | The default render gains five objects (an exception to the byte-identical rule); a user with own budgets must turn ours off (double budgets break eviction); Helm needs rights on `poddisruptionbudgets` | Kubernetes documentation, the renders |
| E. As D, but off by default and turned on by the installer profiles | The default render stays byte-identical | A Helm-only install, which is the production path, gets nothing; profiles and chart differ for a safety property | the renders |
| F. Per-workload budget values (`enabled`, `minAvailable`, `maxUnavailable` for each) | Full control | Twelve more public values and their tests, for a need nobody has stated | not built |
| G. Two replicas for the gate and the console, soft spread over host and zone | The request path survives a drain, a rollout and a crash on a cluster with room on a second node | 56Mi more requested memory; per-pod caches and limits (see Security); on one node, a drain of that node blocks | the service code above |
| H. As G with a hard spread (`DoNotSchedule`) or required anti-affinity | A guarantee of two nodes | The second replica stays Pending on a one-node cluster (kind, k3d, a one-node GKE pool) | Kubernetes documentation |
| I. Two replicas for the gate and console in the quick start too | The quick start shows the production shape | Memory on the smallest machine, for a gain against crashes and rollouts only; a one-node drain blocks | ADR 0014 sizing |
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

Why `maxUnavailable: 1` and not `minAvailable`: it is the same budget as `minAvailable: 1` at two replicas, it still keeps all but one pod up at three or more, and at one replica it does not block a drain. A budget on a single replica changes no eviction; it is there so that one rule holds for every workload, so that a chart test can enforce it, and so that the budget is already in place when a count goes up.

Why the gate and the console: the gate is on the path of every A2A caller, and the console is the operator's view. Neither keeps state that a second replica corrupts; what changes with a second replica is listed under Security impact. The kb can run two replicas without corrupting data, but its graph extraction budget is per process and its database and embedding server stay single, so a second kb gains little and costs budget. It stays at one; the existing value lets an operator raise it, and the values comment says the extraction budget is per replica.

Why one replica in the quick start and minimal profiles: they run on one node, where a second replica helps against a crash or a rollout but not a node, a drain of that node would block (see Consequences), and ADR 0014 keeps the quick start small. `components/quickstart/values.yaml` sets `governance.a2a.replicas: 1` and `console.replicas: 1`; `minimal-values.yaml` inherits them. A user who starts from the quick start on a real cluster with two or more nodes sets both to 2; the install guides get that line in the #199 slice.

Changing the console from Recreate to RollingUpdate is harmless for policy: during a rollout two console pods may serve at once, and every write from either still passes the controller's policy and the admission guard.

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
    replicas: 2            # new. Limits held in the process (in-flight caps, TokenReview concurrency) apply per replica.
                           # On a one-node cluster set 1: two replicas there block a drain of the node.
console:
  replicas: 2              # new. The failed-login and validate limits apply per replica. One-node cluster: set 1.
knowledge:
  kb:
    replicas: 1            # exists; now validated. graph.tokensPerHour is counted per replica.
```

Rules for the render:

- `governance.a2a.replicas`, `console.replicas` and `knowledge.kb.replicas` must be whole numbers of at least 1. Anything else (0, a negative number, a string, a fraction) fails the render with one sentence that names the value and the range. Zero is refused because it looks like "off" and is not; the `enabled` switches turn a workload off.
- No other workload gets a replicas value. A workload is added to the list above only with a change of this ADR that names what a second replica changes.
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
    matchLabels:
      <the workload's spec.selector.matchLabels>     # app: <name>
      app.kubernetes.io/instance: <release name>
      app.kubernetes.io/part-of: openagentix
```

The budget selects the workload's own selector plus the release and part-of labels, so a pod of another team with the same `app` label in the same namespace (the release namespace can be `default`) is not covered. The `app` part comes from the same template value as the workload's selector, so the two cannot drift. The workload selectors themselves do not change (a Deployment selector cannot be changed in place). The pod templates of `victoria-metrics` and `jaeger` gain `app.kubernetes.io/instance` and `app.kubernetes.io/part-of`, as every other pod template already has; this rolls those two pods once on upgrade. A budget is rendered exactly when its workload is rendered.

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

`matchLabelKeys` counts only the pods of one ReplicaSet, so a rollout does not skew the spread of the new pods. Spread rather than pod anti-affinity: one shape covers nodes and zones, and it is a score, not a filter. It acts only when a pod is scheduled: after a node failure and return, both replicas can stay on one node until the next rollout.

The gate and the console, at any replica count, also get `lifecycle.preStop.sleep: {seconds: 5}`. The sleep keeps a stopping pod serving while the Service endpoints drop it, so a rollout does not refuse new connections. It is the built-in sleep action, so it does not need a shell in the image. The grace period covers the sleep plus the drain each server already allows on SIGTERM: the gate drains for 25 s (`services/a2a-gate/cmd/a2a-gate/main.go:114`), so its `terminationGracePeriodSeconds` goes from 30 to 35; the console drains for 10 s (`services/console/cmd/console/main.go:152`), so its 30 s stays.

### Installer check for budgets that already exist

Two budgets on one pod make that pod impossible to evict. Before `helm upgrade`, with `availability.podDisruptionBudgets.enabled` on, `install.sh` runs a read-only check on every cluster type:

1. It renders the chart with the values of this run and collects, per namespace, the pod template labels of every Deployment and StatefulSet.
2. It lists the PodDisruptionBudgets in those namespaces (`kubectl get pdb -n <ns> -o json`) and drops the ones this release owns (annotation `meta.helm.sh/release-name` equal to the release name).
3. For each remaining budget whose selector matches the labels of one of our pod templates, it prints the budget, the workload it matches, and the fix: "delete that budget, or set `availability.podDisruptionBudgets.enabled: false`". It then stops before any change, with exit code 1.

The check uses only `get`. It runs on a fresh install too (it compares against the rendered templates, not running pods). `SKIP_PREFLIGHT=1` does not skip it; turning the budgets off does. It handles `matchLabels` and `matchExpressions` (`In`, `NotIn`, `Exists`, `DoesNotExist`); an empty selector (`{}`, every pod in the namespace) counts as a match.

### What the default render changes: an exception to the rule

The project rule is "off by default, deny by default: with a feature off, the default chart render is byte-identical to before" (`CLAUDE.md`, design rules). This ADR breaks that rule on purpose, and says so: the budgets are on by default, so the default render changes by exactly five objects, the PodDisruptionBudgets of `telegram-bridge`, `kb`, `kb-postgres`, `kb-embeddings` and `memory-embeddings`. Nothing else in the default render changes: the gate and console are off by default, spread is rendered only above one replica, the priority class is empty, and the two pod templates that gain labels are not in the default render.

Why the exception:

- The rule protects users from behaviour they did not ask for. A `maxUnavailable: 1` budget on one replica allows every eviction that the cluster allowed before.
- The 0.3 exit criterion asks for a budget on every workload, and a Helm-only install is the production path. Option E would leave that path without one.
- `availability.podDisruptionBudgets.enabled: false` gives back the old default render byte for byte, and a chart test proves it against a render of the chart before this change.
- The one way the budgets can refuse an eviction that worked before (a second budget on the same pod) is caught by the installer check above and named in the upgrade note.

This pull request adds the exception to the design rules in `CLAUDE.md`, so the rule and its one exception are read together.

The quick start, minimal and full demo renders also change: their budgets, the console's strategy (Recreate to RollingUpdate), the explicit gate strategy, the preStop sleep, the gate's grace period, the labels of the `victoria-metrics` and `jaeger` pod templates, and in the full demo the second replicas and spread rules.

### Upgrade note (CHANGELOG, 0.3)

"The chart now renders a PodDisruptionBudget (`maxUnavailable: 1`) for each of its Deployments and StatefulSets, on by default (`availability.podDisruptionBudgets.enabled`). If you wrote your own budgets for OpenAgentix pods, delete yours or set `availability.podDisruptionBudgets.enabled: false`: a pod that two budgets select cannot be evicted, so every node drain would fail. `install.sh` finds such budgets and stops; with Helm only, check `kubectl get pdb -A` yourself. A budget with the same name in the same namespace stops the upgrade (Helm cannot take it over). The account that runs Helm needs `create`, `update` and `delete` on `poddisruptionbudgets` (group `policy`) in each platform namespace. The A2A gate and the console now run two replicas by default (`governance.a2a.replicas`, `console.replicas`); the quick start and minimal profiles keep one. On a cluster with one node, set both to 1, or a drain of that node will not finish. The console now updates by rolling update instead of Recreate. The `victoria-metrics` and `jaeger` pods restart once (new labels). `availability.priorityClassName` must name a PriorityClass that exists, or the pods are refused."

## Consequences

- A node drain, a cluster upgrade and a rollout no longer cut every A2A caller off when the gate runs two replicas and a second node has room.
- On a one-node cluster with two replicas of the gate or the console (chart defaults, not the quick start), a drain of that node does not finish: one pod is evicted, its replacement stays Pending, and every further eviction gets HTTP 429. The operator sets the replicas to 1 first, or drains with a timeout and accepts the cut. A managed upgrade on a one-node pool waits and then forces the drain. The upgrade note and the values comments say this.
- Single-replica workloads are still down while they move. On a drain that is the time to start again elsewhere. On a node failure it is the time to NotReady (about 40 to 50 s) plus the 300 s toleration plus start time; then:
  - a Deployment without a volume starts on another node;
  - a Deployment on a cloud ReadWriteOnce disk waits for the forced detach (about 6 more minutes);
  - a Deployment on a node-local volume (kind) stays Pending until the node returns;
  - the `kb-postgres` StatefulSet pod is not recreated at all, whatever its volume, until the node returns, the pod is force-deleted, or the node gets the out-of-service taint.

  Shorter tolerations are not part of this decision; #204 measures first.
- The model path is still single: the model gateway proxy (agentgateway, not our chart) runs one replica. That is #211, not this ADR.
- A long A2A stream through a gate pod that stops is cut after the 25 s drain; the caller must retry. Two replicas do not change that.
- With two gate pods, a new container agent's route reaches each pod when that pod's kubelet syncs the routes ConfigMap (up to about two minutes, `hack/ci/smoke.sh:113`). For that time a call can be routed by one pod and answered 404 by the other. Two scripts assume one gate pod and are fixed in the #199 slice: `hack/ci/smoke.sh:113` stops waiting at the first answer, which may come from the pod that already has the route; `hack/demo.sh:37` reads `kubectl logs -l app=a2a-gate --tail=400 | ... | tail -1`, which mixes the lines of both pods.
- Ruled out for now: a second control plane (needs leader election, a new ADR changing ADR 0007), a second bridge or notify (their state is in the process), per-workload budget values.
- Security impact:
  - Who may call what does not change: both gate pods use the same rules, key hashes and routes. How a change reaches the pods differs per source. A change of the rules changes the pod template checksum and rolls the pods. A change of the key hashes Secret or the routes ConfigMap reaches each pod on its own, when the kubelet of its node syncs the mounted file, plus up to 10 s for the key hashes (`main.go:77`). Until both pods have it, the two pods can answer the same request differently. The upper bound is the same as with one pod today. To apply such a change to every pod at once, restart the Deployment (`kubectl rollout restart deploy/a2a-gate -n openagentix-gateway`); the #199 slice writes this in the gate guide.
  - A limit kept in the process is multiplied by the replica count. Gate: the in-flight cap (128, `gate.go:48`), the cap per container agent (32, `gate.go:57`) and the shared container agent pool (half of the in-flight cap), and the TokenReviews at once (8, `auth.go:70`). Each pod also has its own 30 s TokenReview cache (a revoked token can still pass for up to 30 s in each pod, the same bound as today). Console: the failed-login limit per address, the failed-login cap over all addresses (`guard.go:153`) and the validate rate limit. kb (when raised above 1): the graph extraction token budget (`worker.go:84`); the gateway's per-key token budget still applies on top.
  - Console: install.sh makes the login token from 48 random characters and the console refuses fewer than 32, so twice the failed-login attempts does not change what guessing can reach.
  - The audit user id hash uses a salt that is random per process, so at the same time the two gate pods write different hashes for the same user. Today the hash already changes at every restart. Audit readers can join a user's lines only within one pod's life; `governance.a2a.audit.userId: raw` is unchanged.
  - The budgets, spread rules and an empty priority class change no permission. A priority class lets our pods preempt others only when the operator names one.
  - The controller gets no new RBAC. Helm needs rights on `poddisruptionbudgets` (upgrade note). The installer check only reads.
  - The gate slice (#199) changes how audit identities and limits behave per pod, so it gets an independent review before merge.
- Compatibility: see the upgrade note. The chart's new objects need Kubernetes 1.30 or newer; the project requires 1.37. OpenShift (`platform: openshift`) renders the same objects; nothing in them conflicts with restricted-v2.

### Tests and proof before this counts as done

Chart tests in `charts/openagentix/tests/run.sh`, each shown failing before the templates change:

1. For the default, quick start, minimal, full demo and `platform=openshift` renders: every Deployment and StatefulSet has exactly one PodDisruptionBudget in its namespace that matches its pod template labels; every rendered budget matches exactly one workload; no pod template is selected by two budgets (#198).
2. Selector shape: every budget's `selector.matchLabels` has exactly the keys `app`, `app.kubernetes.io/instance` and `app.kubernetes.io/part-of`, with `app` equal to the workload's `spec.selector.matchLabels.app`, the release name and `openagentix`; it has no `matchExpressions`. Every pod template of a Deployment and StatefulSet carries all three labels (this fails today for `victoria-metrics` and `jaeger`). Rendered with a release name other than `openagentix`, the instance label follows it.
3. Every budget is `policy/v1`, has `maxUnavailable: 1`, has no `minAvailable`, and has `unhealthyPodEvictionPolicy: AlwaysAllow`.
4. `availability.podDisruptionBudgets.enabled=false` renders no budget, and the default render with it equals the baseline render of the chart before this change (`OA_BASELINE_RENDER`, as in the ADR 0023 test); the default render without the five budgets equals the baseline.
5. `availability.topologySpread.enabled=false` and `availability.priorityClassName=""` are byte-identical to the default render.
6. Full demo: `a2a-gate` and `openagentix-console` have 2 replicas, RollingUpdate with `maxSurge: 1` and `maxUnavailable: 0`, the two spread constraints with the workload's selector and `matchLabelKeys: [pod-template-hash]`, the preStop sleep of 5 s, and a grace period of 35 s for the gate and 30 s for the console (#199).
7. Quick start and minimal: the gate and the console have 1 replica and no spread constraint.
8. Every workload not in the replicas-value list renders `replicas: 1` in every render, so a count cannot be raised by accident.
9. `governance.a2a.replicas`, `console.replicas` and `knowledge.kb.replicas` set to `0`, `-1`, `1.5` and `"two"` each fail the render with the range in the message; `knowledge.kb.replicas=2` renders the spread constraints on `kb`.
10. `availability.priorityClassName=platform-high` sets the field on every Deployment and StatefulSet pod template and on no CronJob; an invalid name fails the render.

The probes and resources test of #201 is separate and unchanged by this ADR.

Installer check (shell test against a fake `kubectl` with JSON fixtures, in the style of `hack/ci/preflight-test.sh`):

- a foreign budget with `matchLabels: {app: console}` in the console's namespace stops the install with exit code 1, names the budget and the workload, and prints both fixes;
- a foreign budget with `matchExpressions` that match, and one with an empty selector, stop it too;
- a foreign budget that matches no pod template, and the release's own budgets, pass;
- with `availability.podDisruptionBudgets.enabled=false` the check is not run;
- every recorded call is a `get`, and nothing is changed before the check passes.

API server: `make test-apiserver` applies, with `--dry-run=server`, every budget of the full demo render and the gate and console Deployments (namespaces created in the throwaway cluster), so `unhealthyPodEvictionPolicy`, `matchLabelKeys` and the preStop sleep action are checked by a real API server, not only by the render. The test pins its node image to the installer's `kindest/node:v1.37.0` instead of kind's own default, and refuses a `KIND_NODE_IMAGE` older than 1.30.

On a cluster (each result goes into `docs/diary/what-works.md` with its limits; every cluster has its own name and kubeconfig, never the user's cluster):

- #198, two worker nodes, full demo values: before the drain, print where every platform pod runs (`kubectl get pods -o wide` for the platform namespaces), so the spread of the gate and console replicas is shown, not assumed. `kubectl drain` of the node with the platform pods finishes and is not blocked by a budget on a single replica. Print the placement again after the drain. Output in the pull request.
- #198, one node, full demo values with the chart's default of two gate and console replicas: `kubectl drain --timeout=120s` does not finish, the output shows the 429 answer for the second replica, and the replacement is Pending. With `governance.a2a.replicas=1` and `console.replicas=1` the same drain finishes. This proves the one-node consequence above.
- #199: a client sends one A2A request per second through the gate during `kubectl rollout restart deploy/a2a-gate`; no request fails. Then, with two gate pods: remove one caller key from the key hashes Secret and print, per pod, the time until that pod refuses the key; and create a container agent and print, per pod, the time until that pod routes to it. `hack/ci/smoke.sh` and `hack/demo.sh` are changed to wait for and read every gate pod. Scripts and output in the pull request.
- #204: stop the node with the platform pods (`docker stop`). Expected, to be confirmed or corrected by the run: the gate (two replicas) keeps answering once its endpoints drop the lost pod; stateless single replicas come back on the other node after about 6 minutes (NotReady plus the 300 s toleration) plus start time; `kb-embeddings`, `memory-embeddings` and `victoria-metrics` stay Pending because kind's local volumes cannot move; `kb-postgres` is not recreated until the node returns. The test prints what recovered and how long it took.

## Not checked / open points

- Everything about Kubernetes behaviour in Context is read from documentation, not run here: *unverified* until the tests above run.
- The memory cost of the second gate and console in the full demo on a 6 CPU, 8 GiB VM is computed from requests, not measured.

### Decisions (owner, 2026-11-27)

1. Should the quick start on a remote cluster (`CLUSTER_TYPE=remote PROFILE=quickstart`) run two gate replicas? Decided: yes, only when the installer's preflight sees two or more Ready, schedulable nodes; otherwise one, so a drain is never blocked by our default.
2. Should the gate replicas share one audit hash salt (a Secret made by install.sh)? Decided: not in this ADR. It changes what the audit record lets a reader link over time, so it needs its own security ADR.
3. Should the kb run two replicas in the full demo? Decided: no. The extraction budget is per process, and its database and embedding server stay single.
4. Should stateless single replicas get shorter not-ready tolerations than 300 s? Decided: decide after #204 gives numbers, and never for a workload on a ReadWriteOnce volume.
5. Should the embedding model caches become `emptyDir`, so the embedding servers can move on a node failure at the cost of a download (about 120 MB for the memory model)? Decided: decide in #206 (volume keep policy), and only as an opt-in value.
6. A priority class per workload? Decided: no. One value for all chart pods until a platform team asks with a reason.

Also open, outside this ADR: replicas and budgets for the upstream workloads, above all the model gateway proxy (#211).
