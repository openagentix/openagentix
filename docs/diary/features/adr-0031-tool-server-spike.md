---
title: Tool server accounts spike
sidebar_position: 15.97
description: What a throwaway-cluster spike showed about ToolHive 0.67.1 tool servers that run under hand-written ServiceAccounts with no right on Secrets (ADR 0031, proposed).
---

# Tool server accounts spike

Issue [#229](https://github.com/openagentix/openagentix/issues/229), ADR 0031 (proposed, PR #276), the section "Spike" and five questions added by its review. This page is the record of one spike. It does not describe a feature of the product. Nothing in the chart, the CRDs or the services was changed.

## What was run

The job `e2e (adr 0031 spike, tool server accounts)` of `.github/workflows/e2e.yml` (start it by hand with the input `adr0031`; it never runs on a pull request and never gates a merge) builds the cluster of the endpoints job: a kind cluster on a hosted runner, two tiny MCP endpoints (`echo` and `other`, each with a header Secret in `mcp-tools`), then `PROFILE=quickstart` with `hack/ci/endpoints-ci-values.yaml`, no key, the stub model. Then `hack/spikes/adr0031_tool_server_spike.py` runs. It refuses to run outside GitHub Actions or on a context that is not a kind context. Like `hack/ci/endpoints-live.sh`, it makes the tool servers trust the API server's own tokens so that it can call them.

- **ToolHive version, as running.** Operator image `ghcr.io/stacklok/toolhive/operator:v0.67.1`; Helm releases `toolhive-operator` chart `toolhive-operator-0.67.1` and `toolhive-operator-crds` chart `toolhive-operator-crds-0.67.1` (app version 0.67.1); tool server pod image `ghcr.io/stacklok/toolhive/vmcp:v0.67.1`.
- **Tool servers in the cluster:** `tools` (shared, group of the quick start with the `osv` server), `tools-lookup`, `tools-lookup-cm` (profiles on that group), `tools-disputes` (profile on the group `disputes`, with the endpoints `echo` and `other`). The quick start has the `osv` server and no `fetch` server in this install. The knowledge base mirror, notify and the diagnostics group are not in this cluster.
- **The hand-written objects**, for each tool server `<name>` (applied before the field is set):

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: {name: spike-<name>, namespace: mcp-tools}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: spike-<name>, namespace: mcp-tools}
rules:
  - apiGroups: [toolhive.stacklok.dev]
    resources: [mcpgroups, mcpservers, mcpremoteproxies, mcpserverentries, mcpexternalauthconfigs, mcptoolconfigs]
    verbs: [get, list, watch]
  - apiGroups: [toolhive.stacklok.dev]
    resources: [virtualmcpservers]
    verbs: [get]
    resourceNames: [<name>]
  - apiGroups: [toolhive.stacklok.dev]
    resources: [virtualmcpservers/status]
    verbs: [update, patch]
    resourceNames: [<name>]
  - apiGroups: [""]
    resources: [configmaps]
    verbs: [get, list, watch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: spike-<name>, namespace: mcp-tools}
subjects: [{kind: ServiceAccount, name: spike-<name>, namespace: mcp-tools}]
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: spike-<name>}
```

The switch is `kubectl patch virtualmcpserver <name> -n mcp-tools --type merge -p '{"spec":{"serviceAccount":"spike-<name>"}}'`, one tool server after the other. Calls to a tool server use `tools/list` and `tools/call` with a token of the `default` ServiceAccount of `mcp-tools` for the tool server's audience.

Runs on the pull request (all on `ubuntu-24.04`):

| Run | Result |
|---|---|
| [46129900658](https://github.com/openagentix/openagentix/actions/runs/46129900658) | First run. The script used the wrong Service name for the port-forwards (`svc/<name>`, the Service is `vmcp-<name>`), so the calls through the tool servers failed. The checks that need no call (Q1, Q4, Q5, Q9) gave the answers below and were not changed by the later runs. |
| [46131733146](https://github.com/openagentix/openagentix/actions/runs/46131733146) | Complete run, with questions 11 to 15. The tables come from this run. |

The full results (`results-adr0031.md`, with every request) are the artifact `adr0031-spike` of each run.

## Answers

The numbers 1 to 10 are those of the section "Spike" of the ADR, in its order. 11 to 15 are the questions its review added.

| # | Question | Answer |
|---|---|---|
| 1 | With `spec.serviceAccount` set, does the operator create no ServiceAccount, Role or RoleBinding, and leave the hand-written ones alone across a reconcile, a spec change and an operator restart? | Yes. A new tool server `probe-own` was created with the field set: no `probe-own-vmcp` object of any of the three kinds exists, and its Deployment runs as `spike-probe-own`. After an annotation event, a change of `spec.config.aggregation`, and `kubectl rollout restart deploy/toolhive-operator` (40 s after each), the uid, resourceVersion and rules of the hand-written objects had not changed. |
| 2 | With no Secret rule, is every backend ready? | Yes. After the switch each tool server was Ready with every backend `ready` (`osv` on three; `echo` and `other` on `tools-disputes`). One condition, `SessionStorageWarning`, is present with status False before and after the switch. |
| 3 | `tools/list`, a tool call, and the header | Yes. The tool lists and the answers were the same before and after the switch. `echo_echo` through `tools-disputes` returned "echo from echo: adr0031 check" and the endpoint's log showed its own header value on every request (6 requests in each run of the check). A call of an `osv` tool was not made. |
| 4 | `can-i get/list secrets` as each account, and a pod as the account | Yes. `kubectl auth can-i get secrets` and `list secrets` in `mcp-tools` answered `no` for each of the four accounts. Before the switch, the same two questions answered `yes` for each operator account (`<name>-vmcp`). A pod that runs as `spike-tools-disputes` and calls the API with its own token got HTTP 403 for `GET secrets/echo-mcp-auth` and for the list of Secrets. As the control, a pod as the operator's old account `tools-disputes-vmcp` got 200 for the list of Secrets. In the output of the pod commands some of the printed lines were lost (the harness attaches after the container starts), so not every line exists for every pod. |
| 5 | Forbidden or RBAC lines in the tool server logs | None. After the switch no log line of any tool server matched `forbidden`, `cannot get/list/watch`, `rbac`, `unauthorized` or `not allowed`, at start, with an entry added while the servers ran (`late`, a copy of `other`), and with a backend restart (`kubectl rollout restart deploy/echo`). The only forbidden lines are those of question 7, made on purpose. |
| 6 | Does a `-workload` variant accept a pod-bound token and refuse another audience? | Yes. A copy of `tools-disputes` named `tools-disputes-workload` (its own hand-written account, `MCPOIDCConfig` of type `kubernetesServiceAccount` with the cluster issuer and `useClusterAuth: true`, and the Cedar policy of the chart's workload variant for a namespace `spike-wl`). A token bound to a pod of that namespace, with the variant's audience: a session opened, `tools/list` gave `echo_echo` and `echo_list_notes`, and a call reached the endpoint with its header. The same with another audience: `initialize` refused with HTTP 401 `invalid audience`. A token with the right audience and no pod binding: a session opened, `tools/list` was empty and the call got "call denied by authorization policy". |
| 7 | Is the Role enough without ConfigMap rights? | Partly. Without the ConfigMap rule the tool server stayed Ready, every backend stayed `ready`, and the list and the call worked. But its log filled with `Failed to watch ... configmaps is forbidden ... cannot list resource "configmaps"` errors, which repeat while the rule is missing. So the ConfigMap rule is needed to keep the log clean; on this install nothing else was seen to break. This install has no CA bundle ConfigMap on an entry. |
| 8 | Does status keep updating with `resourceNames` limited to the own object? | Yes. `can-i update` and `patch` on `virtualmcpservers/status` answered yes for the own name and no for the name `tools`. After the entry `late` was deleted, the backend list of `tools-disputes` changed in under 40 s, and `managedFields` shows status updates by the managers `thv-operator` and `vmcp` (the tool server itself) at that time. No forbidden line. |
| 9 | The operator's old `<name>-vmcp` objects | They stay: after the switch all twelve (ServiceAccount, Role and RoleBinding of four tool servers) exist with the same uids and an owner reference to their tool server. After they were deleted, an annotation event on each tool server, a spec change, 60 s, a restart of the operator and 90 s later, none had been created again, and every tool server still had all backends ready. |
| 10 | Node memory before and after, and restart time | Memory: the runner showed 3362 MiB used and the kind node container 2.479 GiB before; 3427 MiB and 2.537 GiB after the switch. Restart: for each tool server the operator changed the Deployment within 0.1 s of the patch, and the new pod was Ready with all backends ready after 16 s (15.8 to 16.1 s); the four in a row took 67 s. |
| 11 | Can each account create pods, statefulsets, deployments, `pods/exec` or `pods/attach`? | No for all five, for each of the four accounts (`kubectl auth can-i create <resource> -n mcp-tools --as=system:serviceaccount:mcp-tools:spike-<name>`). |
| 12 | `create statefulsets` and `create services` for the proxy-runner accounts of `mcp.servers[]` | The only `mcp.servers[]` server in this install is `osv`. Account `osv-proxy-runner`: create statefulsets yes, create services yes. Account `osv-sa`: create statefulsets no, create services no. |
| 13 | Session secret, and a client session across a restart | The operator still makes a session secret for each tool server, named `<name>-hmac-secret`, also for `probe-own` and `tools-disputes-workload`, which have `spec.serviceAccount` set. The pod gets it as the environment value `VMCP_SESSION_HMAC_SECRET` from a `secretKeyRef`, so the kubelet resolves it; the account never reads it through the API. A session did not continue across a restart of the tool server: the old `Mcp-Session-Id` got HTTP 404 `Session terminated` at once, a clean failure, and a new `initialize` worked. |
| 14 | `helm upgrade` and an operator restart | The hand-written objects were left exactly as written. `./install.sh` again (a Helm upgrade of the release) and then a restart of the operator changed no uid, resourceVersion, rule or subject of the twelve objects, and `spec.serviceAccount` of each tool server was still set afterwards. |
| 15 | Volumes and env sources, new account against the default one | Nothing new and nothing missing, apart from the name of the generated service account token volume (`kube-api-access-<suffix>`, a new random suffix on each pod). The volumes of a tool server are that token volume, `oidc-ca-bundle-ci-apiserver-ca` (a ConfigMap) and `vmcp-config` (a ConfigMap). The environment values are plain values and one `secretKeyRef`, `VMCP_SESSION_HMAC_SECRET`. |

## Also recorded

- **Stop rule.** Questions 1 to 4 all came out as expected, so the repeat for `outgoingAuth.source: inline` was not run.
- **The session secret.** Named as in question 13; mounted by reference as an environment value, not read through the API.
- **Tool server accounts and Secrets.** Before the switch the operator's account can read every Secret in `mcp-tools` (the pod as `tools-disputes-vmcp` read the list of Secrets). After it the four accounts cannot.

## Limits of this spike

- One ToolHive version (0.67.1), one single-node kind cluster, one complete run. The calls through the tool servers use the API server's own tokens for the incoming side (the CI values of the endpoints job), not the identity provider of a real install.
- The shared group has only `osv`. There is no `fetch`, knowledge base mirror, `notify` or diagnostics group in this cluster, so question 2 covers `osv`, `echo` and `other`.
- The header credential was tested on `echo` through `tools-disputes` and the `-workload` variant. No `osv` tool call was made.
- Question 7 ran on an install with no CA bundle ConfigMap on an entry, which is the use the ADR names for the ConfigMap rule. The effect of its absence was seen on the ConfigMap watch only.
- The memory figures include the load of the whole runner and the kind node, not the tool server pods alone, and one more tool server (`probe-own`) was running by then.
- The Role was applied by hand. The chart's render, the admission policies, and the install check of the ADR were not exercised.
- Question 14 used `./install.sh` for the Helm upgrade. The Helm three-way merge kept `spec.serviceAccount`, which the chart does not render.
- The pod-as-account check printed only some of its lines (see question 4).
