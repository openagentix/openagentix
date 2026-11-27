---
title: Diagnostic tools (cluster-read)
sidebar_position: 15.5
description: The read-only cluster tool server in the chart (ADR 0025, slice 4), how to turn it on, what the chart renders and refuses, and what is and is not proven.
---

# Diagnostic tools: `cluster-read`

Issue [#230](https://github.com/openagentix/openagentix/issues/230), [ADR 0025](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0025-read-only-diagnostic-tools.md), slice 4. The server code is slice 3 (`services/diagnostics`). This page is about the chart, the installer and the checks around it.

## What it is for

An agent that explains why a pod fails needs pods, events, logs, workloads and nodes. It must not read a Secret, run a command or change anything. `cluster-read` gives it eight read-only tools and nothing else. It is off by default, and with it off the chart renders byte for byte what it rendered before (checked against the render of the previous chart for the defaults, the quick start, the quick start with the sample container agent and the full demo).

## Turn it on

```yaml
diagnostics:
  enabled: true
  cluster:
    enabled: true
    logNamespaces: [rca-demo]                  # pods, events, workloads and pod logs
    statusNamespaces: [openagentix-knowledge]  # pods, events and workloads, never logs; a platform namespace may be here
mcp:
  profiles:
    - name: rca
      codeMode: false
      tools:
        cluster-read: [pods_list_in_namespace, pods_get, pods_log, events_list, workloads_list, workloads_get, nodes_list, nodes_get]
        knowledge: [kb_search]
```

`./install.sh` then builds the image from `services/diagnostics`, labels the namespace `openagentix-diagnostics` for Pod Security `restricted`, creates the bearer Secrets, and after the chart is applied waits for the server and reads the vMCPs of the group.

## What the chart renders

| Object | Where | Note |
|---|---|---|
| Deployment, Service, ServiceAccount, PodDisruptionBudget `cluster-read` | `openagentix-diagnostics` | one replica; the pod keeps the default projected token; the bearer value is a mounted Secret file, never an argument or an environment value |
| ClusterRoles `openagentix-cluster-read`, `-logs`, `-nodes` | cluster | get and list on pods, events, four workload kinds; get on `pods/log`; get and list on nodes. No `aggregationRule`, no Secret, no ConfigMap, no `exec`, no `watch`, no write verb |
| RoleBindings and one ClusterRoleBinding | listed namespaces | the first role in every listed namespace, the logs role in the log namespaces only, the nodes role bound cluster-wide (`diagnostics.cluster.nodes`, default true) |
| ValidatingAdmissionPolicy `openagentix-diagnostics-rbac` and its binding | cluster | for every user, fail-closed; see below |
| MCPGroup `diagnostics`, MCPServerEntry `cluster-read`, and an entry for knowledge, notify and each backend in `diagnostics.allowWith` | `mcp-tools` | the entries for other backends are named `<entryName>-diagnostics`, because the shared group has `knowledge` and `delivery` in the same namespace |
| A vMCP for each profile that lists a `cluster-read` tool | `mcp-tools` | on the group `diagnostics`, `defaultToolVisibility: deny`, audit with request and response data off whatever the observability values say |
| NetworkPolicies `cluster-read-ingress`, `cluster-read-egress` | `openagentix-diagnostics` | ingress only from the vMCP pods of those profiles (and their `-workload` variants with `allowDefinitions`), egress only to the API server addresses |
| Cedar `forbid` per tool | the shared vMCP | in front of the permit: a second layer, since the shared vMCP does not reference the group at all |

The tools of the knowledge base and notify, as an agent on such a profile sees them, are `knowledge-diagnostics_kb_search` and `delivery-diagnostics_notify_send`. The chart renames them in the agent's tool list and prompt for an agent on a diagnostics profile. The control plane catalog lists the same names.

The admission policy refuses, for every user: a rule outside the three roles' lists; an `aggregationRule`; a binding of `cluster-read` to any other role, in any of the three subject forms RBAC accepts (the ServiceAccount, the User `system:serviceaccount:openagentix-diagnostics:cluster-read`, the Group `system:serviceaccounts:openagentix-diagnostics`); a ClusterRoleBinding to anything but the nodes role; the logs role in `kube-system` and in the platform namespaces; any binding of `db-read`; any Role, and any RoleBinding the chart does not render, in `openagentix-diagnostics`. A binding to a cluster-wide group (`system:serviceaccounts`, `system:authenticated`) cannot be refused without breaking the cluster. Only the rights check of the server finds a right given that way.

## What the render refuses, with a sentence that names the fix

`diagnostics.enabled` with `networkPolicy.enabled` false, with `observability.capture.content` true, or with `mcp.enabled` false; `*`, a duplicate, a name that is not a DNS label, a namespace in both lists, `openagentix-diagnostics` in either list, more than 100 namespaces; `kube-system`, `kube-public`, `kube-node-lease` and every namespace the chart's own values name (tools, agents, gateway, knowledge, notify, memory, schedules, observability, bridge, gate, control plane, console, container agents, Kourier, ToolHive, Substrate and the release namespace) in `logNamespaces`; code mode on a profile with a diagnostics tool; a tool next to the diagnostics tools that is not on the fixed list (the knowledge tools, `notify_send` and `notify_list_destinations`) and not named in `diagnostics.allowWith` (a whole backend cannot be allowed at once); `kagent-tools` anywhere near them; a diagnostics profile in `controlPlane.policy.allowedProfiles` (the wildcard included) or `controlPlane.containerAgents.toolProfiles` without `diagnostics.allowDefinitions`; and a channel binding that serves an agent on such a profile.

The reply paths known to send without link previews are the Telegram bridge and notify (`oa.diagNoPreviewPaths`). The Kourier channel bindings are not on that list, so they are refused. A schedule sends the reply nowhere: its job log holds a one-line summary without the answer (`PRINT_ANSWER` is off by default), so schedules are not refused. A new channel joins the list only with a test that it turns previews off.

## The installer

- `hack/diagnostics-bearer.sh` creates two Secrets with one random value, only when absent, never printed: `cluster-read-bearer` in `openagentix-diagnostics` (key `bearer`, the value alone, for the server's `-bearer-file`) and `diagnostics-bearer-cluster-read` in `mcp-tools` (key `authorization`, `Bearer <value>`). ToolHive sends the Secret as the header value, so the scheme word has to be in the Secret that the entry references; the server compares the value after `Bearer `. The value goes through process substitution and a pipe, never an argument. A Secret that is missing or differs is repaired from the other one; the server's own Secret wins.
- `hack/diagnostics-check.sh` reads every vMCP of the group after it is Ready and fails the install when a `DiscoveredAuthConfig-*` condition is False. ToolHive 0.67.1 keeps such a vMCP Ready with fewer backends (the spike, [ToolHive spike for diagnostic tools](toolhive-spike-diagnostic-tools.md)).
- `install.sh` builds the image like the other services (`SKIP_DIAGNOSTICS_IMAGE=1` skips it), stamps a source hash, finds the API server addresses for the egress policy the way it does for the control plane (`DIAGNOSTICS_APISERVER_CIDRS`), and creates the namespace with the Pod Security labels (the bearer Secret must exist before the pod does).
- `uninstall.sh` with `PURGE_SECRETS=1` deletes the two Secrets. The namespace stays.

## How it was checked

| Check | Where | Result at the time of writing |
|---|---|---|
| Chart tests: every refusal, no diagnostics entry outside the group, no `bearerToken` anywhere, audit data off on the group's vMCPs, no Secret object, the shared vMCP and the shared-group profiles never name the group or a bearer Secret, probes and budgets, the default render byte-identical | `charts/openagentix/tests/diagnostics.sh` (run by `run.sh`) | 172 checks pass; the whole chart suite passes |
| The admission policy, executed with the Kubernetes CEL code: each role with each forbidden right, each subject form, the group, `db-read`, the logs role in platform namespaces, the diagnostics namespace | `hack/ci/guardtest/diagnostics_test.go` (`make test-guard`) | 190 cases (25 allowed, 165 refused) pass; a weakened policy fails them |
| The same refusals on a real API server, and `kubectl auth can-i` as the ServiceAccount (yes for pod logs in a log namespace, events in a status namespace, nodes; no for Secrets, ConfigMaps, `exec`, `attach`, `portforward`, the proxy subresources, `serviceaccounts/token`, `impersonate`, `watch`, writes, pod logs in a status namespace and in `kube-system`; and no for `db-read` everywhere) | `hack/ci/apiserver-test.sh` (`make test-apiserver`, CI) | see the pull request for the CI run |
| The installer steps with a fake `kubectl`: the bearer value is in no argument, no output line, no log; the check fails on a `False` condition | `hack/ci/diagnostics-bearer-test.sh`, `hack/ci/diagnostics-check-test.sh` | pass |
| Live, on a real API server: the server becomes Ready (its rights check passes), the dedicated profile lists the eight tools through kagent, the shared tool server lists none, the shared vMCP pod holds no bearer Secret, the server refuses a call without the value | `hack/ci/diagnostics-live.sh`, run by the `e2e` workflow on request (input `diagnostics`) | see the pull request for the CI run |

## Limits, stated

- The ToolHive operator gives every vMCP ServiceAccount, the shared one included, read access to Secrets in `mcp-tools`. The own group keeps the bearer values out of the shared vMCP's environment, not out of its reach through the API. ToolHive 0.67.1 offers no way to narrow this.
- Every vMCP of the group holds the bearer value as an environment value. The server cannot tell those vMCPs apart.
- kindnet does not enforce egress to the internet, so the egress policy is a second layer on kind. Ingress was shown to be enforced there for other services, not yet for these pods.
- The chart does not create the namespace `openagentix-diagnostics`: `install.sh` does, with the Pod Security labels. A plain `helm install` needs the namespace, the labels and the two Secrets made by hand.
- A ClusterRoleBinding of the ServiceAccount is refused for the first two roles as well, not only for other roles (ADR 0025 says a matched binding may reference only the three roles). Binding the first role cluster-wide would reach every namespace, which the namespace lists exist to prevent.
- Redaction, the field allowlist and the rest of the server are in `services/diagnostics/README.md`. An agent root-cause run, with canaries, is slice 5 and is not done.
