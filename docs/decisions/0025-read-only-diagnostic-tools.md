# ADR 0025: read-only cluster and database tools for diagnostic agents, and how a tool server gets a credential

Status: Accepted (2026-11-27)
Date: 2026-11-27
Issue: https://github.com/openagentix/openagentix/issues/230 (use cases #229)
Replaces: none. Narrows one case of ADR 0021 (proposed, PR #142): reads on the home cluster in a fixed list of namespaces. Follows ADR 0006 (tool profiles), ADR 0007 (`ToolServer` later), ADR 0019 (container agents) and ADR 0024 (a PodDisruptionBudget per workload). See "Relation to other records".

The 7-day review period was waived by the maintainer on 2026-11-27 because the reference use cases (#229) need this record; an independent review was done and its changes are in this text. The independent reviewer recommended keeping the 7 days, and the maintainer waived them.

Two small tool servers, written in this repository, give agents read-only facts for root-cause analysis and for database tuning. `cluster-read` reads pods, events, pod logs, workloads and nodes of the cluster the platform runs on, in namespaces the operator lists, through its own ServiceAccount with a fixed set of rules. `db-read` reads statistics and settings of named PostgreSQL databases through a role that holds `pg_monitor` and no right on any table. Neither server can write, run commands or read a Secret through the Kubernetes API. A tool server gets a credential only as a reference to a Secret that the installer (or the operator) creates and the kubelet mounts as a file in that server's pod. The chart renders the reference; the control plane never reads the Secret. Both are off by default, and with them off the chart renders byte for byte what it renders today. Nothing here is built. Everything is *unverified* until the slices below are done, and the first slice is a spike whose stop rules can change this decision.

## Amendment 1 (2026-11-27), after the slice 2 spike

The spike of slice 2 ran on a throwaway kind cluster with ToolHive 0.67.1 ([diary](https://github.com/openagentix/openagentix/blob/main/docs/diary/features/toolhive-spike-diagnostic-tools.md), PR #236). No stop rule failed. Facts it showed:

- **Exclusion works.** `excludeAll: true` for a backend, `defaultToolVisibility: deny`, a Cedar `forbid` on the tool names, and a group that does not hold the backend each keep a vMCP from listing the backend's tools and refuse a direct call and a code mode call. Other tools keep working.
- **Header injection works.** `MCPServerEntry.spec.headerForward.addHeadersFromSecret` and an `MCPExternalAuthConfig` of `type: headerInjection` both send the Secret value on every request. `type: bearerToken` is not supported in 0.67.1: the vMCP drops the backend, sets the condition `DiscoveredAuthConfig-<entry>` to False, and **stays Ready** with fewer backends.
- **Every vMCP of a group gets the credential.** The operator gives every vMCP pod of the group the header value as an environment value from the Secret (by reference), including vMCPs that expose none of the backend's tools. Only a vMCP of another group did not get it.
- **The caller is not forwarded.** The backend received neither the caller's token nor its claims. The vMCP audit line names the caller's `sub`.
- **Audit data.** With `includeRequestData` and `includeResponseData` true, tool arguments and results are in the vMCP audit line; with both false, they are not.

**Decision (maintainer, 2026-11-27).** The diagnostics server entries get their **own tool group**, so the shared vMCP never holds the diagnostics credential. The aggregation filter and the Cedar `forbid` stay as extra layers where they still apply. The bearer value is now required (decision 4). Sections 1, 5, 6, 7 and 8, slice 4 and the decisions below are updated to match.

**Note (2026-11-27), from the independent review of ADR 0026 (PR #242).** Two facts that this record did not state. First, the ToolHive operator gives every vMCP ServiceAccount, the shared vMCP's included, read access to Secrets in `mcp.namespace`. The own group keeps the diagnostics bearer values out of the shared vMCP's environment, not out of its reach through the API; ToolHive 0.67.1 offers no way to narrow this, so it is a remaining risk (section 5 "Stated limit" and the threat table, "Another caller reaches the server"). Second, the `diagnostics` group's entries for the knowledge base and notify cannot be named `knowledge` and `delivery`, because the shared group's entries have those names in the same namespace; ADR 0026 names such entries `<entryName>-<group>`, and slice 4 follows it. Nothing else in this record changes.

## Context

Release 0.3 aims at adoption, and the reference use cases of #229 must run on a single-node kind cluster with what is already installed. Two of the agents there have no tools:

1. **Pod root-cause analysis** on the cluster itself. It needs pods, events, pod logs, deployments and nodes. It must not see Secrets, must not run `exec`, and must not change anything.
2. **Database tuning suggestions** for the PostgreSQL the platform already runs: `kb-postgres` (knowledge base) and `kagent-pg` (the agent runtime's sessions and memory). It needs statement statistics, table and index usage and settings. It must not read table rows: the runtime's database holds conversation text and memories.

Facts read on 2026-11-27 in this repository and, read-only, on the maintainer's kind cluster:

- **The only Kubernetes tool server installed today, `kagent-tools`, is bound to a role that allows everything.** The admission guard already keeps it out of every `AgentTemplate` the controller writes (`charts/openagentix/templates/control-plane-guard.yaml`, policy for agent templates: only the `RemoteMCPServer` of a tool profile, with a subset of that profile's tools). That must not change.
- **`mcp.servers[]` takes `name`, `image`, `port`, `transport`, `proxyPort` and `resources`, nothing else** (`charts/openagentix/templates/mcp.yaml`). An upstream server cannot be given arguments, environment values, a ServiceAccount or a Secret through the chart.
- **The platform's own tool servers, `kb` and `notify`, follow another pattern.** The chart renders a Deployment in the service's own namespace, with credentials by `secretKeyRef` to Secrets that `install.sh` creates and never prints (`kb-database`, `kb-admin`). It registers the service in the tool group as a ToolHive `MCPServerEntry` with an `unauthenticated` external auth config; the vMCP connects to the URL itself, and a NetworkPolicy admits only the vMCP pods of the group (`charts/openagentix/templates/knowledge.yaml`). `what-works.md` records that a pod in `default` timed out against kb and notify on kind. Every one of these policies is rendered only with `networkPolicy.enabled`.
- **Every vMCP of the group connects to every backend** for discovery and health, whichever tools it advertises (comment in `knowledge.yaml`, kb ingress policy). Profile vMCPs advertise only their listed tools (`defaultToolVisibility: deny`). The shared vMCP `tools` has no filter and a permit-all Cedar policy: it advertises every backend's tools, and its code mode can call them.
- **Tool output can reach the observability store.** The vMCP audit copies request and response data when `observability.capture.content` is true, and the runtime's traces then hold model input and output, which includes tool results (`mcp.yaml`, observability values).
- **Definitions may use only listed profiles.** `controlPlane.policy.allowedProfiles` (default empty) and `requireToolProfile: true` (`charts/openagentix/values.yaml`). Container agents reach a profile only when the operator lists it in `controlPlane.containerAgents.toolProfiles` (ADR 0019).
- **Both databases are `pgvector/pgvector:pg17`** (PostgreSQL 17). `kb-postgres` is a chart StatefulSet started with `-c shared_buffers=64MB -c max_connections=50`; `kagent-pg` comes from `components/runtime/manifests/kagent-postgres.yaml` with no extra arguments. Neither loads `pg_stat_statements` (`shared_preload_libraries` is not set). The installer already reaches both databases as superuser through `kubectl exec` and the local socket (`components/runtime/up.sh`, `install.sh` step for kb Secrets).
- **Database ingress today.** `kb-postgres` admits only the `kb` pods. `kagent-pg` admits only the runtime's controller and the memory expiry job, and only when the chart renders `openagentix-kagent-pg` (with memory expiry on); otherwise it is open.
- **The API server egress rule exists.** The control plane's policy uses `controlPlane.apiServerCIDRs` and `apiServerPorts` (443, 6443), set by `install.sh`.
- **Node headroom.** One reading on the maintainer's kind cluster (use-case plan, 2026-11-27): 4.1 of 7.7 GiB in use with the full demo. One profile vMCP pod uses 65 to 68 MB.

Upstream servers read on 2026-11-27 (GitHub API: licence, last push, last release):

| Server | Licence | Activity | Fit |
|---|---|---|---|
| [containers/kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server) | Apache-2.0, Go | pushed 2026-11-27, release v0.1.3 on 2026-11-13 | Read-only mode, toolsets, denied resources, `pods_log` with a tail. ADR 0021 picks it behind its target gate |
| [crystaldba/postgres-mcp](https://github.com/crystaldba/postgres-mcp) | MIT, Python | pushed 2026-11-26, last release v0.3.0 on 2025-05-16 | Top queries, health checks, explain, index advice. Has a free SQL tool, restricted mode is a read-only transaction |
| [googleapis/mcp-toolbox](https://github.com/googleapis/mcp-toolbox) | Apache-2.0, Go | pushed 2026-11-26, release v1.18.0 on 2026-11-20 | Fixed parameterised SQL tools from a config file; also ships prebuilt PostgreSQL tools |

## Options

### Where the tools run

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Wait for ADR 0021 slice 1 (kubernetes-mcp-server behind the target gate) | One design for all infrastructure tools, remote targets later | The gate is not built; its first step is a spike on whether ToolHive v0.67.1 can send a token to the gate, and slice 1 stops if it cannot. No database path. Events and logs are left out of its read role | ADR 0021 text on PR #142 |
| B. Upstream servers as plain `mcp.servers[]` entries | Little code of our own | Needs arguments, environment values, a ServiceAccount and a Secret per server, which the chart cannot pass. The token would sit next to a generic resource reader. No output cap, no redaction, env values of pods returned as they are. Every pod in `mcp-tools` can reach every server there | `mcp.yaml`; use-case plan "Read-only Kubernetes tools" |
| C. Small servers in this repository, deployed like `kb` and `notify` | A fixed, typed tool list; namespace list, caps, redaction and audit in code we test; credentials by Secret reference, a pattern already proven live; no new upstream component; works on kind now | Code to write and maintain (two binaries, one image). Our own redaction can miss formats an upstream project would also miss | `knowledge.yaml`, `notify.yaml`, `install.sh` |
| D. The agent runs `kubectl` or `psql` in its sandbox | Nothing to build | Gives the agent a credential and a shell. Refused by ADR 0021 and by the platform rules | ADR 0021 |

### Kubernetes reads

| Option | What it gives | What it costs |
|---|---|---|
| kubernetes-mcp-server with `read_only`, toolset `core`, Secrets denied | Maintained, wide coverage | `core` also has `pods_exec`, `pods_run`, `pods_delete`, stopped only by a flag and the role. Generic `resources_get` for any kind. Pod env values and `last-applied-configuration` returned in clear. Needs the chart settings above |
| A thin server of our own | Eight tools with typed arguments; results built from an allowlist of fields; no generic reader | Our code; new kinds need a change |

### PostgreSQL reads

| Option | What it gives | What it costs |
|---|---|---|
| postgres-mcp in restricted mode, with a profile filter that hides `execute_sql` | Good tuning advice, hypothetical indexes | Python image and memory on a small node; no release for 18 months; `explain_query` takes free SQL; a role that can see `pg_stat_activity.query` sees live statement text with literal values; needs a Secret in the environment |
| mcp-toolbox with our own fixed queries | Maintained Go binary, fixed SQL | Needs a config file, arguments and a Secret through the chart; no redaction of query text; prebuilt tools must stay unloaded |
| A thin server of our own with fixed queries | Same fixed SQL, plus redaction, caps and a self-check of the role | Our code |

### The credential path

| Option | What it gives | What it costs |
|---|---|---|
| Secret reference, mounted as a file in the tool server's own pod; Secret created by the installer or the operator | The control plane never sees it; the kubelet refreshes the file, so rotation needs no restart; child processes do not inherit it | The installer reaches the database as superuser through `kubectl exec` once, as it already does |
| Secret reference as an environment value | The kb pattern | Every child process inherits it; a new value needs a pod restart |
| The control plane copies a Secret it reads | Nothing for the operator to do | Breaks "the controller never reads Secrets". Refused |
| A credential provider and federation (ADR 0021) | Short-lived credentials | Not built; PostgreSQL has no federation on kind. Later |

## Decision

Option C: two thin, read-only servers in this repository, deployed and registered like `kb` and `notify`, off by default. The credential rule in section 4 applies to every new platform tool server, and it is the rule a later ADR on settings for `mcp.servers[]` must follow. The decision holds only if the spike of slice 2 passes its stop rules.

### 1. Shape

- One Go module `services/diagnostics` with two commands, `cluster-read` and `db-read`, and one shared package for output building, redaction and audit. One image (distroless static, non-root user 65532, by digest from the base), built and tagged like every platform image (`hack/image-tag.sh`, ADR 0022). Dependencies: `client-go` (Apache-2.0) and `pgx` (MIT).
- Namespace `openagentix-diagnostics`, labelled for Pod Security `restricted`. Two Deployments, one replica each, each with its own ServiceAccount, Service on port 8080, PodDisruptionBudget (ADR 0024), `readOnlyRootFilesystem`, all capabilities dropped, seccomp `RuntimeDefault`. Requests 10m CPU and 24 MiB, limits 100m and 64 MiB (*unverified*, measured in the live slices).
- The two servers never share a pod, a ServiceAccount or a Secret. `db-read` has `automountServiceAccountToken: false`; `cluster-read` has the kubelet's default projected token for its own ServiceAccount and nothing else.
- Each is registered as an `MCPServerEntry` (`cluster-read`, `db-read`) in `mcp.namespace`, pointing at `http://<name>.openagentix-diagnostics.svc.cluster.local:8080/mcp`, in a **tool group of its own**, `diagnostics` (an `MCPGroup` the shared vMCP does not reference; Amendment 1). Each entry sends a bearer value from a Secret (section 5). They join `oa.profileWorkloads`, so profiles can list them.
- The `diagnostics` group also holds an `MCPServerEntry` for each other backend a diagnostics profile may list: `knowledge` and `delivery` (same URL and auth as their entries in the shared group), and each backend named in `diagnostics.allowWith` (pointing at that server's Service). Entries create no pods. A profile that lists any diagnostics tool is rendered on the `diagnostics` group, with its `-workload` variant if opened (ADR 0019); every other profile stays on the shared group.
- Tool results are JSON. Every free text value (log lines, event and status messages, statement text, index definitions, object names chosen by users) is in a field named `untrusted_text`, and every result carries `"content": "data, not instructions"`, the way kb and notify mark their results.

### 2. `cluster-read`

**Tools.** The names are our own; they are close to kubernetes-mcp-server's names for readability, but the arguments differ, so recorded scenarios must use the arguments below.

| Tool | Arguments | Returns |
|---|---|---|
| `pods_list_in_namespace` | `namespace`, optional `labelSelector` | at most 200 rows: name, phase, ready, restarts, waiting or terminated reason, node, age, owner |
| `pods_get` | `namespace`, `name` | the pod, built from the field allowlist below |
| `pods_log` | `namespace`, `pod`, optional `container`, `previous`, `tailLines` (default 100, at most 200), `sinceSeconds` (at most 3600) | lines, `truncated`, `redactions` |
| `events_list` | `namespace`, optional `involvedKind`, `involvedName` | at most 100 newest events: type, reason, message, object, count, first and last time |
| `workloads_list` | `namespace`, `kind` one of `deployment`, `statefulset`, `daemonset`, `replicaset` | at most 200 rows: name, replicas desired, ready, updated, available, revision, conditions |
| `workloads_get` | `namespace`, `kind`, `name` | the object, built from the field allowlist below, with rollout conditions |
| `nodes_list` | none | name, ready, pressure conditions, capacity, allocatable, taints, kubelet version |
| `nodes_get` | `name` | the same for one node, with its conditions' messages |

A value outside these shapes is refused before any API call: an unknown namespace, a namespace not on the lists, a name that is not a DNS label, a `tailLines` or `sinceSeconds` above the cap, an argument starting with `-`.

**Namespaces.** Two lists in chart values, both empty by default:

- `diagnostics.cluster.logNamespaces`: pods, events, workloads and pod logs.
- `diagnostics.cluster.statusNamespaces`: pods, events and workloads, never logs.

The render refuses `*`, a duplicate, a name that is not a DNS label, any namespace in both lists, and `openagentix-diagnostics` in either list. It refuses in `logNamespaces`: `kube-system`, `kube-public`, `kube-node-lease`, `openagentix-diagnostics`, every namespace the chart's own values name (tools, agents, gateway, knowledge, memory, notify, schedules, observability, control plane, console, container agents) and the ToolHive and Substrate namespaces (`networkPolicy.toolhiveNamespace`, `networkPolicy.substrate.namespace`). Platform namespaces may appear only in `statusNamespaces`, so an agent can explain why a platform pod restarts without reading its output. The server enforces the same two lists in code, from its own flags, and RBAC enforces them again.

**Results are built from an allowlist of fields.** The server never returns an API object as it came. For each kind it copies only the fields listed in its code, and every string it copies goes through redaction. A field not on the list is absent, whatever it holds.

- **Pods:** name, namespace, labels, owner references, node, phase, conditions, QoS class, start time; for each container, init container and ephemeral container: name, image, image ID, ports, resource requests and limits, ready, started, restart count, state and last state (reason, exit code, signal, times, message as below), probe and lifecycle handler *type*, port and path only (no headers, no exec command); env variable names and, for `valueFrom`, only the source kind, object name and key; `envFrom` object names; volume names with their source type and object name (no CSI `volumeAttributes`, no other source fields).
- **Annotations:** only names, never values.
- **Container `command` and `args`:** in `logNamespaces`, each element after redaction and cut at 512 bytes, with the element after a secret-like flag name (`--password`, `--token`, `--secret`, `--key`, `--api-key` and similar, and `-p`) replaced by `[redacted]`. In `statusNamespaces`, the count of elements only.
- **Workloads (`deployment`, `statefulset`, `daemonset`, `replicaset`):** name, labels, owner references, replicas and their status counts, selector, strategy, revision, conditions, and `spec.template` built with the pod rules above.
- **Messages:** event, condition and container `state.waiting.message` texts are kept after redaction and cut at 512 bytes in both lists. `lastState.terminated.message` and `state.terminated.message` are kept after redaction only in `logNamespaces` and removed in `statusNamespaces`: a pod with `terminationMessagePolicy: FallbackToLogsOnError` copies log lines there.
- **Events that carry container output:** the kubelet copies exec probe output into `Unhealthy` events and hook output into `FailedPostStartHook` and `FailedPreStopHook` events. In `statusNamespaces` these events keep only reason, type, object, count and times, never the message. In `logNamespaces` the message is kept after redaction.
- **Logs:** requested with `limitBytes` 65536 at the API; each line cut at 2048 bytes; ANSI escape sequences and control characters other than tab removed; then redaction.

**Redaction.** One scanner for both servers. It starts from the list of ADR 0021 section 17, so the gate can reuse it, and adds what the review found:

- PEM private key blocks, JWTs, kubeconfig `token:` and `client-key-data:`;
- cloud access key id formats and secret-shaped pairs;
- `Authorization`, `Proxy-Authorization`, `Cookie` and `Set-Cookie` values, `Bearer` and `Basic` credentials, in free text and as structured header name and value pairs (`{"name": "Authorization", "value": ...}`, `X-API-Key: ...`);
- `password`, `passwd`, `secret`, `token`, `api_key`, `apikey`, `access_key`, `client_secret`, `private_key` pairs in `key=value`, `key: value`, JSON, YAML and flag forms (`--password=x`, `--password x`);
- URLs with a password in the user part;
- common token prefixes of code hosts, package registries, chat services and model providers (for example `ghp_`, `gho_`, `github_pat_`, `glpat-`, `xoxb-`, `xoxp-`, `sk-`, `sk-ant-`), chat bot tokens of the form `<digits>:<35 characters>`, and the platform's own gateway key prefix `vk-`. A prefix matches only at a word boundary and only when it is followed by at least 16 characters from the token's own character set (letters, digits, `_` and `-`), so ordinary words such as `disk-pressure` or `task-runner` are not redacted;
- the same patterns once encoded in base64 or hex.

A match becomes `[redacted]` and is counted. Remaining exposure, stated: a value split across lines or fields in a way the pair rules do not see, encoded twice, or in a format the scanner does not know passes. Redaction reduces leaks; it does not prove there are none.

**ServiceAccount and RBAC.** ServiceAccount `cluster-read` in `openagentix-diagnostics`. Three ClusterRoles, with no `aggregationRule`, which grant nothing until bound:

```yaml
# openagentix-cluster-read: bound by a RoleBinding in every logNamespaces and statusNamespaces entry
- apiGroups: [""]
  resources: [pods, events]
  verbs: [get, list]
- apiGroups: [events.k8s.io]
  resources: [events]
  verbs: [get, list]
- apiGroups: [apps]
  resources: [deployments, replicasets, statefulsets, daemonsets]
  verbs: [get, list]
# openagentix-cluster-read-logs: bound by a RoleBinding in every logNamespaces entry only
- apiGroups: [""]
  resources: [pods/log]
  verbs: [get]
# openagentix-cluster-read-nodes: one ClusterRoleBinding, only with diagnostics.cluster.nodes (default true when cluster-read is on)
- apiGroups: [""]
  resources: [nodes]
  verbs: [get, list]
```

**Forbidden rights.** The list of ADR 0021 section 11, plus what a read server never needs. No role used by either server may grant, with any verb, in any namespace or at cluster scope: `secrets`, `configmaps`, `serviceaccounts`, `serviceaccounts/token`, `pods/exec`, `pods/attach`, `pods/portforward`, `pods/proxy`, `services/proxy`, `nodes/proxy`, `nodes/stats`, `pods/ephemeralcontainers`, `impersonate`, `bind`, `escalate`, `watch`, any write verb (`create`, `update`, `patch`, `delete`, `deletecollection`) on any resource, or `*` in verbs, resources or API groups. Not the built-in `view` role (it includes ConfigMaps). ConfigMaps stay out: a "missing configuration key" failure shows in events by key name, and ConfigMap values are often literal settings.

**An admission policy for these objects.** `openagentix-diagnostics-rbac`, a `ValidatingAdmissionPolicy` rendered only when `cluster-read` or `db-read` is on, evaluated for every user (Helm included), `failurePolicy: Fail`:

- The three ClusterRoles may contain only the rules above: a key allowlist on each rule, resources and verbs from the exact lists, and no `aggregationRule` key.
- A RoleBinding or ClusterRoleBinding is matched when any subject names one of the two ServiceAccounts in any of the three forms RBAC accepts: `kind: ServiceAccount` with that name and namespace; `kind: User` with the full name `system:serviceaccount:openagentix-diagnostics:<name>`; `kind: Group` `system:serviceaccounts:openagentix-diagnostics`. A matched binding may reference only the three ClusterRoles; a RoleBinding to `openagentix-cluster-read-logs` is refused in the namespaces the render refuses for logs; any binding that names `db-read` is refused; and a binding to the namespace group is refused.
- In `openagentix-diagnostics`, a `Role` is refused, and so is every `RoleBinding` whose name is not one the chart renders there (the names are rendered into the policy).
- Stated limit: bindings to cluster-wide groups (`system:serviceaccounts`, `system:authenticated`) cannot be refused without breaking the cluster. Only the rights check below finds a right given that way.

**Rights check, at start and every 5 minutes.** `cluster-read` runs `SelfSubjectAccessReview` for every forbidden right above, in each listed namespace, in `kube-system`, in `openagentix-diagnostics` and at cluster scope (namespace empty), and `SelfSubjectRulesReview` in each listed namespace. If any forbidden right is allowed, or a listed namespace grants nothing, readiness drops with the reason and no tool is served until a later check passes. The check finds a right added outside the chart; it cannot stop one.

### 3. `db-read`

**Tools.** Fixed SQL only. No tool takes SQL text.

| Tool | Arguments | Reads |
|---|---|---|
| `databases_list` | none | configured target names, reachable or not, server version, whether statement statistics are on |
| `settings_get` | `database` | about 40 tuning settings from `pg_settings` by a fixed name list (memory, connections, planner costs, WAL and checkpoints, autovacuum, statistics): value, unit, source, `pending_restart`. Never `primary_conninfo`, `archive_command`, `restore_command`, `ssl_passphrase_command` or any setting off the list |
| `statements_top` | `database`, `orderBy` one of `total_time`, `mean_time`, `calls`, `shared_blks_read`, `temp_blks_written`, `limit` at most 20 | `pg_stat_statements` for the current database: query id, statement text (rules below), calls, times, rows, buffer and temp counts |
| `tables_stats` | `database`, `limit` at most 50 | `pg_stat_user_tables` and sizes: scans, tuples live and dead, vacuum and analyze times |
| `indexes_stats` | `database` | `pg_stat_user_indexes`, sizes, never-used and duplicate candidates, and definitions from `pg_indexes` as untrusted text after redaction (a partial index predicate can hold literal values) |
| `database_health` | `database` | cache hit ratio, connections by state and wait event (counts only), transaction id age, checkpoints, temp files, deadlocks, count of transactions open longer than 5 minutes, and `pg_stat_statements_info.dealloc` when statement statistics are on |

**Statement text.** PostgreSQL replaces constants with `$n` in most statements it tracks, but its documentation says constant values may still appear, especially when entries are often deallocated, and comments are kept as written. So the server:

- never selects `pg_stat_activity.query` (live statement text with literal values);
- strips comments, then classifies: only text that starts with `SELECT`, `INSERT`, `UPDATE`, `DELETE`, `MERGE` or `WITH` (after any opening parentheses) is a candidate; utility statements, which can hold a password (`ALTER ROLE ... PASSWORD`), are dropped;
- returns the text, without its comments, only when it then holds no quote character (`'`, `E'`, a dollar quote); otherwise it returns the query id and the counts with the text `[withheld]`;
- redacts the text and cuts it at 1000 characters.

Remaining risk, stated: a numeric literal that PostgreSQL did not normalise (for example after a deallocation) has no quote, so it is returned. A number such as an account or card number in such a text can reach the model.

When `pg_stat_statements` is not loaded or not created in the database, `statements_top` answers `unknown` with the reason and the fix, never a guess. `EXPLAIN` is not in this decision (item 7 of "Decisions on the open points").

**Targets.** `diagnostics.databases.targets[]`, empty by default:

```yaml
diagnostics:
  databases:
    enabled: false
    targets:
      - name: kb                   # what the agent passes as `database`
        platform: knowledge        # the chart knows host, port, database and pod labels; install.sh creates the role and the Secret
      - name: runtime
        platform: agent-runtime    # the agent runtime's own database; install.sh creates the role and the Secret
      # - name: orders             # an external database: the operator creates the role and the Secret
      #   host: orders-db.shop.svc.cluster.local
      #   port: 5432
      #   database: orders
      #   namespace: shop          # for the NetworkPolicy
      #   podLabels: {app: orders-db}
      #   passwordSecret: {name: db-read-orders, key: password}
```

The render refuses a duplicate name, a name that is not a DNS label, `platform: knowledge` without `knowledge.postgres.enabled`, a `platform` value other than `knowledge` and `agent-runtime`, an external target without host, database, namespace and pod labels, and a `passwordSecret` with a key other than a plain key name. At most 8 targets. The role name, host, port and database reach the server as flags; only the password is in the Secret, as a file that holds nothing else.

**The read role.** The same on every target, idempotent:

```sql
-- the role (created if absent, then always brought to this state); the password is set separately, see section 4
ALTER ROLE openagentix_dbread WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT CONNECTION LIMIT 2;
GRANT pg_monitor TO openagentix_dbread;
ALTER ROLE openagentix_dbread SET default_transaction_read_only = on;
ALTER ROLE openagentix_dbread SET statement_timeout = '5s';
ALTER ROLE openagentix_dbread SET lock_timeout = '1s';
ALTER ROLE openagentix_dbread SET idle_in_transaction_session_timeout = '10s';
```

No `GRANT` on any schema, table, sequence or function. `pg_monitor` gives the statistics views, all settings and `pg_stat_statements` of all users; it does not give `SELECT` on tables. `default_transaction_read_only` is a guard rail, not a boundary: a session may turn it off. The boundary is the privilege set, and the server never offers free SQL. For external targets the same SQL ships as `components/diagnostics/db-read-role.sql`, and the README says how to set the password without putting it on a command line.

**Rights check at every connect and every 5 minutes.** `db-read` checks its own role in each database and refuses with `unsafe-role` (readiness drops for that target) if:

- it is superuser, or has `CREATEROLE`, `CREATEDB`, `REPLICATION` or `BYPASSRLS`;
- it is a member of `pg_read_server_files`, `pg_write_server_files`, `pg_execute_server_program`, `pg_read_all_data`, `pg_write_all_data`, `pg_signal_backend`, `pg_maintain`, `pg_create_subscription` or `pg_use_reserved_connections`;
- `has_table_privilege` is true for any privilege (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `TRUNCATE`, `REFERENCES`, `TRIGGER`, `MAINTAIN`) on any user table, view or materialised view outside `pg_catalog` and `information_schema`, including grants to `PUBLIC`;
- it has `CREATE` on any schema;
- it can execute any `SECURITY DEFINER` function outside `pg_catalog` and `information_schema` (functions are executable by `PUBLIC` by default, so one such function owned by a privileged role is a read path); the names are reported.

A target where `PUBLIC` was given `SELECT` on a table fails this check, which is the intent. Stated: `TEMP` on the database is granted to `PUBLIC` by default and is not revoked, because that would change every other role. A session that has the password and turns read-only off can create temporary tables. The server offers no such statement.

**Statement statistics.** Off by default, because they need a restart:

- `kb-postgres`: chart value `knowledge.postgres.statementStats` (default false). True adds `-c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track_utility=off -c pg_stat_statements.max=5000` to the StatefulSet (one restart), and `install.sh` runs `CREATE EXTENSION IF NOT EXISTS pg_stat_statements` as superuser.
- `kagent-pg`: `STATEMENT_STATS=1` for `components/runtime/up.sh` and the same step in `install.sh`, with the same three settings (one restart of the runtime's database). Off until the operator asks. The new step sends its SQL on standard input and puts no value in a process argument. The existing steps of `up.sh` that passed database passwords as arguments are moved to the same pattern in PR #235.

### 4. Credentials: the rule for new platform tool servers

- A tool server gets a credential only as a reference to a Secret **in its own namespace**. The chart renders the reference (a Secret volume with `defaultMode: 0440` and the pod's `fsGroup`, mounted read-only at `/var/run/secrets/openagentix/<purpose>/`), and the server reads the file when it connects. The path is passed as a flag; the value never is. A file, not an environment value, because child processes do not inherit it and the kubelet refreshes it, so a new value needs no restart.
- **`kb` and `notify` are not changed by this record.** They keep their environment references; moving them to files is a follow-up for their own pull requests. Every new platform tool server follows this rule.
- The Secret is created by `install.sh` for platform targets, or by the operator for external ones. It holds the password only.
- **How the installer sets the password.** It generates the password with `openssl rand` and creates the Secret with `--from-file` from a process substitution, never printing it. It never sends the plain password to the database: a small helper in this repository computes a SCRAM-SHA-256 verifier on the installer's side, reading the password on standard input, and the installer sends `ALTER ROLE openagentix_dbread PASSWORD '<verifier>'` on standard input through `kubectl exec`. In the same superuser session, before that statement, it sets `log_statement = 'none'`, `log_min_error_statement = 'panic'` and `pg_stat_statements.track_utility = off`. The standard error of that step is discarded and the installer prints a fixed message on failure. The verifier uses the iteration count the server is set to (`scram_iterations`, read first through the same superuser session) and a random salt. How the helper runs on the installer host is settled in slice 7, from these options: a Go program under `hack/` run with the Go toolchain the repository already needs; the same code as a subcommand of the `db-read` binary run in a short-lived container on the host; or a subcommand run in the database pod with the password on standard input. In every option the password and the verifier reach no process argument and no file outside a temporary directory that is removed.
- An existing Secret is kept on re-runs (no silent rotation). `DB_READ_ROTATE=1` makes a new password, sets the role's verifier, then updates the Secret with `kubectl replace` (from a client dry run) or server-side apply, never client-side apply, which would store the value in an annotation. The kubelet refreshes the file and the server reconnects on the next call.
- The control plane never reads, copies or names these Secrets; its RBAC and the guard stay as they are. The Secret name and key appear in chart values and the rendered pod spec; the value appears in no file of the repository, no argument, no environment value, no log line, no status and no tool result. The server's own errors are tested with a canary password and must not contain it.
- Secrets do not cross namespaces. The `db-read-<target>` Secrets live in `openagentix-diagnostics`, never in the database's namespace, so a compromise of `kb` does not give the read role and a compromise of `db-read` does not give `kb`'s owner role.
- `uninstall.sh` drops the role `openagentix_dbread` on platform targets (SQL on standard input) and deletes the Secrets with the namespace. For external targets it prints the statement to run.

### 5. Network

- **NetworkPolicy is required.** The render refuses `diagnostics.enabled: true` with `networkPolicy.enabled: false`, because the servers have no authentication of their own (item 4 of "Decisions on the open points").
- **Ingress** to both servers: only the vMCP pods of the `diagnostics` group in `mcp.namespace` (the profile vMCPs of diagnostics profiles and their `-workload` variants of ADR 0019, because each one discovers every backend of its group), on 8080. Not the shared vMCP. A `-workload` variant exists only when `diagnostics.allowDefinitions` is true (section 6). The ingress policies of `kb` and `notify` admit these vMCPs too, as they admit every profile vMCP today.
- **Egress** of `cluster-read`: the API server only, through `controlPlane.apiServerCIDRs` and `apiServerPorts` with the same fallback as the control plane's policy. No DNS is needed (in-cluster configuration uses the service IP).
- **Egress** of `db-read`: kube-dns on 53 and each target's pods on its port (namespace and pod selector). Nothing else.
- **Database ingress, only when a target is on:** `kb-postgres-ingress` gains the `db-read` pods; `openagentix-kagent-pg` gains them too, and the chart renders that policy from one shared helper when the `agent-runtime` target is on even if memory expiry is off. That closes the runtime's database to every other pod, which matches the intent of the existing policy. The live slice checks that the runtime still writes sessions and memories with the policy in place.
- **Limits.** Ingress was shown to be enforced on kind for kb and notify. kindnet does not enforce egress to the internet, so the egress rules are a second layer on kind and the boundary only where the network plugin enforces them (k3s, Calico, Cilium).
- **A bearer value between vMCP and server, required.** The installer creates one random value per server (never printed, kept on re-runs) as two Secrets with the same value: `diagnostics-bearer-<server>` in `mcp.namespace`, which the entry references with `headerForward.addHeadersFromSecret` (or an `MCPExternalAuthConfig` of `type: headerInjection`), and `<server>-bearer` in `openagentix-diagnostics`, mounted as a file in the server's pod. The server refuses every request without the exact `Authorization: Bearer <value>` (constant-time comparison) and never logs the header. `type: bearerToken` is never used: ToolHive 0.67.1 drops such a backend silently.
- **Stated limit.** Every vMCP pod of the `diagnostics` group holds both servers' bearer values as environment values, including a profile that lists only one server's tools. The shared vMCP and the profiles on the shared group hold neither as environment values, but every vMCP ServiceAccount can read Secrets in `mcp.namespace` (note at the top).

### 6. Tool profiles and who may use them

Example values for the two use cases:

```yaml
diagnostics:
  enabled: true
  cluster:
    enabled: true
    logNamespaces: [rca-demo]
    statusNamespaces: [openagentix-knowledge, kagent]
  databases:
    enabled: true
    targets:
      - {name: kb, platform: knowledge}
      - {name: runtime, platform: agent-runtime}
mcp:
  profiles:
    - name: rca
      codeMode: false
      tools:
        cluster-read: [pods_list_in_namespace, pods_get, pods_log, events_list, workloads_list, workloads_get, nodes_list, nodes_get]
        knowledge: [kb_search]
        delivery: [notify_send]
    - name: db
      codeMode: false
      tools:
        db-read: [databases_list, settings_get, statements_top, tables_stats, indexes_stats, database_health]
        knowledge: [kb_search]
```

Render rules, all refusals with a sentence that names the fix:

- **No code mode** on a profile that lists a `cluster-read` or `db-read` tool. Code mode chains calls without the model's step in between.
- **No mixing with outbound tools, per tool.** In a profile that lists any diagnostics tool, every other tool must be on a fixed list (the knowledge tools `kb_search`, `kb_get_document`, `kb_list_collections` and the graph reads; the delivery tools `notify_send` and `notify_list_destinations`; the other diagnostics server's tools) or be named in `diagnostics.allowWith`, a map of backend name to tool names (default empty). A whole backend cannot be allowed at once. So `fetch`, which can carry data to any URL, is refused next to log access unless the operator writes its tool down. `notify_send` sends only to named destinations.
- **No content capture.** The render refuses `diagnostics.enabled: true` while `observability.capture.content` is true. With capture on, tool results would be copied into the vMCP audit and into the runtime's traces, where redaction is the only filter.
- **The shared vMCP gets none of their tools, in layers** (Amendment 1). First, the diagnostics entries are in their own group, which the shared vMCP and the profiles on the shared group do not reference; a chart test refuses a diagnostics entry with any other `groupRef`. Second, the shared vMCP's Cedar policies get one `forbid(principal, action == Action::"call_tool", resource == Tool::"<prefixed name>")` per diagnostics tool, in front of the permit (or of the `toolAccess` rules), so a diagnostics entry placed in the shared group by mistake is still refused. Third, every vMCP of the `diagnostics` group is a profile vMCP with `defaultToolVisibility: deny`: it lists only its profile's tools, so a diagnostics profile for databases cannot call `cluster-read` tools.
- **No audit data on the `diagnostics` group.** Its vMCPs always render `includeRequestData: false` and `includeResponseData: false`, whatever the observability values, in addition to the refusal of content capture above.
- **Definitions and container agents.** A profile with a diagnostics tool may be named in `controlPlane.policy.allowedProfiles` or `controlPlane.containerAgents.toolProfiles` only with `diagnostics.allowDefinitions: true` (default false). By default only chart agents (`agents[]`), which the operator writes, can use them. The controller guard is unchanged: it already limits a definition to its profile's server and tools.
- **Reply channels do not fetch links.** The render refuses a Telegram bridge, a channel binding or any other chart-rendered reply path that targets an agent on a profile with a diagnostics tool, unless that path is on the chart's list of paths that send without link previews (today the Telegram bridge since PR #234, and notify). A new channel joins the list only with a test that it turns previews off.
- **`kagent-tools` stays out.** A chart test keeps it out of every profile and of `diagnostics.allowWith`.

### 7. Audit and limits

- One line per call on the server's standard output: time, server, tool, target (namespace or database), object name for `pods_get`, `pods_log` and `workloads_get`, outcome, duration, output bytes, lines, redaction count. Never log content, event or status text, statement text or a credential. Argument values other than those fields are not logged.
- The vMCP audit line names the session actor and the tool; the server does not learn which agent called (the vMCP does not forward the caller's token or claims, shown in the slice 2 spike; `passthroughHeaders` is not used, because the caller chooses that header). Correlation is by time, one case at a time, as in the use-case evaluation harness.
- Rate limits in code: `cluster-read` 60 calls per minute, of which 20 `pods_log`; `db-read` 30 per minute. API calls time out after 5 seconds, log calls after 10. A refused call costs no API request.

### 8. Threat model

| Threat | Example | Mitigation | Remaining risk |
|---|---|---|---|
| Prompt injection through logs, events or status | A workload in a log namespace writes an instruction for the model | Text is in `untrusted_text` fields marked as data; the profile has no tool that acts on infrastructure; `notify_send` sends only to named destinations; no code mode; outbound tools refused per tool unless the operator lists them | The model can still be misled in what it writes. A person reads the report before acting (use case rule) |
| Data leaving through the agent's reply | The model is led to put data from a log into its answer, for example inside a link | The reply goes only to the caller through the A2A gate or a named channel. Channels that render replies must not fetch links in them (link previews off). The Telegram bridge turns previews off since PR #234, as notify already did. The render refuses a channel binding or bridge that serves an agent on a diagnostics profile unless that channel is one known to send without previews (slice 4), and the live proof checks it (slice 5) | A person who receives the reply sees what the model wrote |
| Prompt injection through database objects or statement text | A table or index named with an instruction; a comment in a query | Same marking; comments stripped from statement text; no write tool in the `db` profile | Same |
| Secret exfiltration through Kubernetes reads | Model asked to print a pod's env, a probe header or a Secret | No Secret or ConfigMap rights; results built from a field allowlist; headers and exec commands never returned; annotation values never returned; arguments pair-redacted and only counted in status namespaces; redaction of every kept string; container output removed from status namespaces | A secret printed to a log in a form the scanner does not know |
| Row data exfiltration through the database | Reading the runtime's memory table | No table privilege, checked at every connect; no free SQL; `pg_stat_activity.query` never read; utility statements dropped; statement text with a quote withheld | Statistics reveal sizes and row counts. Normalised statement text reveals table and column names |
| Confused deputy | A user asks the agent for logs of a platform namespace | Namespace lists enforced in code, by RBAC and by the admission policy; platform namespaces never in `logNamespaces` | Every agent on the profile has the same rights: one server per install, not per agent or per user |
| Another caller reaches the server | A pod in another namespace, or an agent on the shared vMCP | Ingress only from vMCP pods of the `diagnostics` group; NetworkPolicy required by the render; required bearer value; own group, Cedar `forbid` on the shared vMCP and deny-default profile filters | Every vMCP of the `diagnostics` group holds both bearer values; the server cannot tell those vMCPs apart |
| Widened rights | A role gains `secrets`, or a ServiceAccount is bound to a broad role | Admission policy on the three roles, on all three subject forms and on bindings in the diagnostics namespace; rights check at start and every 5 minutes | A cluster admin can remove the policy; a binding to a cluster-wide group is found only by the rights check |
| Tool output in observability | Log lines in the audit store or in traces | The render refuses diagnostics while content capture is on | An operator who turns capture on later must turn diagnostics off first; the render enforces it on each install |
| Credential leak of the read role | The Secret or the server pod is read | Secret only in `openagentix-diagnostics`; file mount; password only; never logged; plain password never sent to the database; connection limit 2 | With the password, a person can read live statement text in `pg_stat_activity`, every setting including superuser-only ones such as `primary_conninfo` (which holds a password on a standby), `archive_command`, `restore_command` and `ssl_passphrase_command`, list the server's log, WAL, temporary and archive status directories (`pg_ls_logdir` and the like), create temporary tables after turning read-only off, and run any `SECURITY DEFINER` function that `PUBLIC` may execute (the rights check refuses to serve where one exists). They still cannot read or write tables |
| Load on the database or the API server | A loop of calls | Rate limits, statement timeout 5 s, connection limit 2, row caps, no `watch` | A slow statistics query on a very large catalogue |
| Supply chain | A dependency changes | One image built from this repository, pinned base digest, two well-known libraries | Normal dependency risk |

**Note (2026-11-27), from the independent review of slice 4 (PR #248): what the chart does differently from the text above, and what the admission policy does not cover.**

Three departures, none of them a widening:

1. The Secret in `mcp.namespace` holds `Bearer <value>`, and the server's own Secret holds `<value>`. Section 5 says "two Secrets with the same value": the value is the same, the form differs, because ToolHive sends a header Secret as the header value as it is, so the scheme word has to be in it. Both are equally sensitive, both are kept on re-runs, and `uninstall.sh` with `PURGE_SECRETS=1` deletes both.
2. A ClusterRoleBinding of the ServiceAccount may reference only `openagentix-cluster-read-nodes`. Section 2 says a matched binding may reference only the three ClusterRoles. The first two roles are bound by a RoleBinding in each listed namespace, so a cluster-wide binding of them would reach every namespace, which the namespace lists exist to prevent. This is stricter than the text.
3. The chart does not render the namespace `openagentix-diagnostics`. `install.sh` creates it and labels it for Pod Security `restricted`, because the bearer Secret must exist before the pod does. A helm-only install must create the namespace and the labels first, then the two Secrets (see the comment of the `diagnostics` values).

What the admission policy `openagentix-diagnostics-rbac` does not cover, in addition to the cluster-wide groups stated in section 2:

- Anyone who can create a Pod in `openagentix-diagnostics`, or a token for the ServiceAccount (`serviceaccounts/token`), runs with the rights of `cluster-read`: pod logs of the log namespaces and the reads of the first role. A cluster-wide `edit` or `admin` binding gives that, and the policy does not see it, because it checks RBAC objects only. Pod Security `restricted` does not stop it. The rights check of the server only finds rights that are too wide, not a second pod that uses the narrow ones. Treat the right to create Pods in that namespace as the right to read those logs.
- A binding that existed before the policy was applied is never evaluated, because the policy checks CREATE and UPDATE. Only the rights check of the server finds it.
- Whoever can change or delete the policy and its binding (write on `validatingadmissionpolicies` and their bindings, in practice cluster admins) can remove it. The policy does not protect itself.

Two changes of the chart follow from the same review: an agent may name the RemoteMCPServer of a diagnostics profile in `tools[].server` only when its `toolProfile` is that profile, so the per-tool mixing rule and the reply-path rule of section 6 cannot be bypassed; and a diagnostics profile is left out of the control plane catalog, and so out of the AgentTemplate guard, while `diagnostics.allowDefinitions` is false. The render also refuses an empty `diagnostics.apiServerCIDRs` unless `diagnostics.allowAnyApiServerAddress` is true, because the egress of the server would otherwise be open to any address on the API ports.

## Consequences

- Possible: the pod root-cause agent and the database tuning agent of #229 run on the existing kind cluster with real data, without ADR 0021's gate, and without any change to the control plane.
- Possible: the credential rule gives the later settings ADR for `mcp.servers[]` (use-case plan, connected mode) a fixed answer for Secrets.
- Harder or ruled out: an agent cannot read Secrets, ConfigMaps or logs of platform namespaces, cannot watch, cannot run `EXPLAIN`, cannot use free SQL, and cannot reach a remote cluster or database outside the cluster network. A namespace or a database is added by the operator through values, and one list serves all agents of the install. Diagnostics cannot be on together with content capture or without NetworkPolicy.
- Security impact: a new read path from agents into the cluster and into two databases. Off at four levels (the `diagnostics` switch, a switch per server, empty namespace and target lists, no profile). New RBAC: one ServiceAccount with get and list on pods, events, workloads, nodes and, in listed namespaces, pod logs. New database role with `pg_monitor`. New admission policy. New records: one audit line per call, without content. Nothing new leaves the cluster.
- Compatibility: with `diagnostics.enabled: false` (the default) the chart render is byte-identical, and `knowledge.postgres.statementStats: false` leaves `kb-postgres` unchanged. Enabling the `agent-runtime` target closes `kagent-pg` to pods other than the runtime's controller, the memory expiry job and `db-read`; a user with another client must add it to that policy.
- Proof needed before this counts as done: the spike's results; unit tests per tool and per refusal; redaction tests with canaries; chart tests; guard tests executing `openagentix-diagnostics-rbac`; `make test-apiserver`; a PostgreSQL integration test of the role and of the rights check; installer and uninstaller tests; an upgrade test with diagnostics on; a live proof per server on kind. The details are in the slices.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0021 (proposed, PR #142) | This record serves the home cluster, read-only, in fixed namespaces, with no target argument, no remote cluster, no cloud and no writes. It adopts 0021's list of forbidden rights and starts from its redaction list, and adds events and pod logs with the caps above, which 0021's read role left out. When 0021's gate exists, `cluster-read` can become its home target or stay as the small home-cluster case; that is decided then. Databases are not in 0021 |
| ADR 0006, ADR 0007 | Tool profiles as they are. `diagnostics.*` values map to the planned `ToolServer` kind, which decides how operators add namespaces and targets as resources |
| ADR 0019 | Container agents reach a diagnostics profile only with `diagnostics.allowDefinitions` and the existing opt-in |
| ADR 0024 | Both Deployments get a PodDisruptionBudget when they are rendered |
| Use-case plan, gap "tool server settings" | Arguments, environment values and Secret references for third-party `mcp.servers[]` stay for their own record; it must follow section 4 |

## Slices and test plan

Each slice is one pull request that `Refs #230`, tests first, off by default, and adds a changelog line when users can see it. Slices 3, 4, 6 and 7 are security-relevant and get an independent review; the spike's results are reviewed with slice 4.

1. **This record.** Docs build.
2. **ToolHive spike, first, on a separately named throwaway cluster** (never the maintainer's cluster), results posted to #230, not merged as code. On ToolHive v0.67.1 with a stub `MCPServerEntry` backend: (a) which aggregation form makes the shared vMCP list none of a backend's tools; (b) whether a Cedar `forbid` on a tool name refuses a direct call and a code mode call while a permit-all policy is present; (c) whether a header from a Secret can be injected into calls to an `MCPServerEntry`; (d) whether the vMCP forwards any caller identity to the backend; (e) that `includeResponseData` false keeps tool output out of the audit. **Stop rules:** if neither (a) nor (b) holds, nothing is registered in the shared group and this record is amended for a separate group before slice 4; if (b) holds and (a) does not, the forbid layer alone is accepted only with the independent reviewer's agreement.
3. **`cluster-read` server.** `services/diagnostics`, command `cluster-read`, with the shared result building, redaction and audit package. Tests first, with the fake client of `client-go`:
   - each tool; a namespace not listed refused; logs refused for a status namespace; `tailLines` 201 and `sinceSeconds` 3601 refused; an argument with a leading `-` refused;
   - field allowlist: a pod and each of the four workload kinds carrying canaries in env values, probe and lifecycle `httpHeaders`, exec probe and hook commands, a short annotation, an init container, an ephemeral container, a CSI `volumeAttributes`, `spec.template`, `managedFields` and `last-applied-configuration`: no canary in the result;
   - status namespaces: `terminated.message` removed, `waiting.message` kept after redaction, `Unhealthy` and hook events without message, arguments only counted; log namespaces: the element after `--password` and `-p` redacted;
   - redaction canaries (PEM key, JWT, cloud key, `password=`, `--password x`, URL with password, bearer and structured headers, cookie, `client_secret`, the token prefixes above, a chat bot token, a `vk-` key; each also in base64 and hex) absent from results and from the audit line; ordinary words that start like a prefix (`disk-pressure`, `task-runner`, `sk-` followed by a short word) left as they are; ANSI and control characters removed; line and byte caps; rate limit;
   - rights check: serving stops when any forbidden right is allowed in a listed namespace, in `kube-system` or at cluster scope, and resumes after a later check passes.
   The image builds in CI.
4. **`cluster-read` in the chart.** Values, namespace, ServiceAccount, the three ClusterRoles and their bindings, Deployment, Service, PodDisruptionBudget, NetworkPolicies, the `diagnostics` `MCPGroup` with the `cluster-read` entry and the `knowledge`, `delivery` and `allowWith` entries, diagnostics profiles rendered on that group, the bearer Secrets created by the installer and referenced by `headerForward` (or `headerInjection`), entry in `oa.profileWorkloads`, the Cedar `forbid` on the shared vMCP, audit data off on the group's vMCPs, the render refusals of sections 2, 5 and 6 (including `networkPolicy.enabled: false` and content capture on), and `openagentix-diagnostics-rbac`.
   - Chart tests: default render byte-identical; no diagnostics entry outside the `diagnostics` group; the shared vMCP and shared-group profiles never reference that group or a bearer Secret; a profile with a diagnostics tool rendered on the `diagnostics` group with `defaultToolVisibility: deny`; no `bearerToken` auth type anywhere; `includeRequestData` and `includeResponseData` false on every vMCP of the group; each refusal with its sentence (including `openagentix-diagnostics` in either namespace list); the per-tool mixing rule; a bridge or channel binding for an agent on a diagnostics profile refused unless the path is on the no-preview list.
   - `make test-guard`: the policy refuses `secrets`, `configmaps`, `pods/exec`, `watch`, `*`, a write verb and an `aggregationRule` in each ClusterRole; a binding to `view` or `cluster-admin` for each of the three subject forms; a binding to the namespace group; a logs binding in `kube-system` or a platform namespace; any binding of `db-read`; a Role, and a RoleBinding the chart does not render, in the diagnostics namespace; it admits the rendered objects.
   - `make test-apiserver` (CI, throwaway cluster `oa-ci-test`): the same refusals on a real API server, one per subject form; and `kubectl auth can-i --as=system:serviceaccount:openagentix-diagnostics:cluster-read` gives yes for `get pods/log -n <log ns>`, `list events -n <status ns>`, `list nodes`, and no for `get secrets`, `list configmaps`, `create pods/exec`, `create pods/attach`, `create pods/portforward`, `get pods/proxy`, `get services/proxy`, `get nodes/proxy`, `get nodes/stats`, `create serviceaccounts/token`, `impersonate users`, `watch pods`, `delete pods`, `patch deployments`, `get pods/log -n <status ns>` and `get pods/log -n kube-system`, in every listed namespace, in `kube-system` and at cluster scope; for `db-read` every one of these, including the yes cases above, gives no.
   - Server and live checks: a request without the bearer value, or with a wrong one, is refused and the value is in no log line; the install waits for the diagnostics profile vMCPs and fails if any has a `DiscoveredAuthConfig-*` condition that is False (a dropped backend does not make a vMCP not Ready); the shared vMCP pod has no environment value that references a diagnostics bearer Secret; the shared vMCP lists no diagnostics tool and refuses a direct call and a code mode call.
5. **Live proof of `cluster-read` on kind** (with the maintainer's go-ahead, through `install.sh`, never by hand edits). `examples/use-cases/rca-demo`: a namespace with broken workloads (OOMKilled, image tag typo, missing ConfigMap key, wrong probe port, pending PVC, a crash loop). Canaries: in a log line, plain and base64; in a literal env value; in an argument after `--password`; in a probe header; in the output of a failing exec probe; and a log line that tries to steer the model into a tool call or a link. A chart agent on profile `rca` (stub model scenario, then the real model with a spend cap). Show: the agent names the cause for each scenario with quoted evidence; no canary in any tool result, in the agent's reply, in the server's log or in the vMCP's log; the injected line causes no extra tool call; a reply that contains a link, sent through the Telegram bridge, shows no link preview; a call for logs in a platform namespace is refused; the shared vMCP lists no `cluster-read` tool and refuses a call; a pod in `default` times out against the server; `kubectl auth can-i` as above; memory of the new pod. Diary entry, `what-works.md` row with limits.
6. **`db-read` server.** Command `db-read`. Tests first, against PostgreSQL 17 in the integration suite (`make test-integration`, Docker, CI):
   - each tool; settings only from the fixed list; utility statements dropped; text with a leading comment classified after stripping; text that still holds a quote withheld (including after a forced deallocation); comments stripped; `dealloc` reported; partial index definitions redacted;
   - `unknown` when `pg_stat_statements` is missing;
   - the rights check refuses: a superuser; a role with `SELECT` or `MAINTAIN` on one table; membership of `pg_read_all_data`, `pg_maintain` or `pg_create_subscription`; a database where `PUBLIC` has `SELECT` on a table; `CREATE` on a schema; an executable `SECURITY DEFINER` function in a user schema;
   - no query in the code selects `pg_stat_activity.query` (a test over the SQL constants); timeouts; rate limit; a canary password in the credential file is absent from every error, log line and result.
7. **`db-read` in the chart, the installer and the uninstaller.** Values, Deployment with the Secret volume, ServiceAccount without a token, NetworkPolicies, additions to `kb-postgres-ingress` and `openagentix-kagent-pg` only when a target is on, `MCPServerEntry`, render refusals, `knowledge.postgres.statementStats`.
   - Installer shell tests with a fake `kubectl`: the role SQL and the verifier go to standard input; no recorded argument holds the canary password or its verifier; the session settings come before `ALTER ROLE`; the step's standard error is not printed; a second run keeps the Secret and changes nothing; `DB_READ_ROTATE=1` sets the role before the Secret and uses replace or server-side apply; `STATEMENT_STATS` off by default and using standard input.
   - Uninstaller test: the role is dropped on platform targets through standard input; for an external target the statement is printed and nothing runs.
   - Chart tests: default render byte-identical; `kb-postgres` unchanged with `statementStats: false`.
   - Upgrade test (`hack/ci/upgrade-test.sh`) with diagnostics on: the role, the Secret and the policies survive an upgrade unchanged.
8. **Live proof of `db-read` on kind.** Targets `kb` and `runtime`; `statementStats` on for `kb-postgres` only (one restart, with the go-ahead). A chart agent on profile `db` gives tuning suggestions whose numbers equal the tool output (harness check). As the read role through `psql`: `SELECT` on the runtime's memory table and on a kb table is refused, `CREATE TABLE` is refused after `SET default_transaction_read_only = off` (temporary tables are not, as stated). After install and after `DB_READ_ROTATE=1`: no canary password in `pg_stat_statements` and none in the database pods' logs. A pod in `default` cannot reach `db-read` or `kagent-pg`. The runtime still writes sessions and memories with the `openagentix-kagent-pg` policy in place. Diary entry, `what-works.md` row with limits.

## Decisions on the open points

These were open while the record was proposed. They are decided with its acceptance, following the independent review.

1. **Upstream or our own.** Our own servers for these two read cases. Revisit kubernetes-mcp-server when ADR 0021's gate exists, and mcp-toolbox when `mcp.servers[]` can take settings.
2. **Platform namespaces.** Allowed in `statusNamespaces` only, never with logs, with the stricter status rules of section 2 (no container output, arguments only counted). `kube-system` may be listed in `statusNamespaces` on the same terms.
3. **Statement statistics.** Off by default. On for `kb-postgres` by value (`knowledge.postgres.statementStats`), which the live proof uses. `kagent-pg` stays off until the operator asks.
4. **Authentication between vMCP and server.** Required, together with NetworkPolicy. The slice 2 spike showed that ToolHive 0.67.1 can inject a header into calls to an `MCPServerEntry`, so each server requires its bearer value from the first chart slice (section 5, Amendment 1). Network policy alone is never accepted for these servers.
5. **One server for all profiles.** One per install, with one set of namespace lists: every agent of the install that may use a diagnostics profile has the same access level. A server per profile (about 25 MB each, *unverified*) comes when two profiles need different lists.
6. **Definitions and container agents.** Refused unless `diagnostics.allowDefinitions: true`. This covers the `-workload` vMCP variants of ADR 0019: without that value, a diagnostics profile is never opened to container agents.
7. **`EXPLAIN`.** Not offered in these slices. `EXPLAIN` checks table privileges, so it needs `SELECT` on the tables it plans, which the role must not have on tables such as the runtime's memory table. A later slice may offer `EXPLAIN (GENERIC_PLAN)` by query id only, for tables in an explicit allowlist with their own grant.
8. **Review window.** The reviewer recommends keeping 7 days; the owner decides. The maintainer waived the window on 2026-11-27 (see the top of this record).

## Not checked

- *Unverified* (not run in the slice 2 spike): a shared vMCP with OIDC and a Cedar `forbid` together; the `-workload` variants on the `diagnostics` group; a profile vMCP that lists a diagnostics tool; how long a tool stays visible after a filter change; tools a backend adds after the vMCP started. Also unverified: resource use of both servers; that `pgx` errors never include the password (tested in slice 6); that kindnet enforces ingress for these pods as it did for kb and notify.
- Read again before quoting: the licences and release dates in the upstream table; the member roles of `pg_monitor` and the predefined roles of the PostgreSQL version in use.
