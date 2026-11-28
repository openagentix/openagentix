---
title: Tool server accounts
sidebar_position: 15.98
description: Tool servers that run under accounts of the chart with no right on Secrets (ADR 0031, slices 3 and 4), what the live runs showed, and the limits.
---

# Tool server accounts

Issue [#229](https://github.com/openagentix/openagentix/issues/229), [ADR 0031](../../decisions/0031-tool-server-secret-reach.md), slices 3 and 4. Before this change every tool server (the ToolHive `VirtualMCPServer` pods in `mcp.namespace`) ran under an account that the tool group operator made, and that account could get, list and watch every Secret in the namespace. So the header credential of one use case could be read through the API by the tool server of another.

## What it does

The chart value `mcp.virtual.ownServiceAccounts` is off by default. With it on, the chart writes, for every tool server it renders (the shared one, each profile, each `-workload` variant), a ServiceAccount, a Role and a RoleBinding named `openagentix-<tool server>`, and names the account in the tool server's `spec.serviceAccount`. The tool group operator then makes none. The Role has the rules the ADR lists and no rule on Secrets. The header credentials still reach the tool server pods as environment values from Secret references, which the kubelet resolves, so the pod never reads a Secret through the API.

With the value off, the render is byte for byte the render before this change. This was checked against the chart on `main` for the default, the quick start, the full demo, the bank and equipment values and a values file that renders every kind of tool server.

`install.sh` does more while the value is on. As each account it asks `kubectl auth can-i` whether it can get or list Secrets or create pods, StatefulSets or Deployments, and fails the install on a yes, naming the account. It checks that every backend of every tool server is ready, because a missing right shows as a dropped backend and not as a tool server that is not Ready. Then it deletes the operator's old `<name>-vmcp` ServiceAccount, Role and RoleBinding, and only after the Deployment runs under the new account. Turning the value from true to false on a live release is refused unless `ALLOW_TOOL_SECRET_READ=1`. While it is off and the install holds header credentials, `install.sh` and the chart's `NOTES.txt` print a warning that names the Secrets (never a value).

`hack/compose-values.sh` treats the key as a security key that a later file may turn on and never off, with `--later-wins` too.

## Live proof

The job `e2e (tool server accounts)` (`tool_accounts` input of the `e2e` workflow, `hack/ci/tool-accounts-live.sh`) installs the quick start with the sample container agent, one endpoint with a header Secret, the knowledge base and its graph, notify and diagnostics. It renders five tool servers: `tools`, `tools-lookup`, `tools-lookup-workload` on the shared group, `tools-disputes` on a group of its own with the endpoint and the knowledge base and notify mirrors, and `tools-rca` on the diagnostics group with `cluster-read` and the two mirrors. It runs the installer five times as a user would.

| Phase | What it did | Result of run [46145968433](https://github.com/openagentix/openagentix/actions/runs/46145968433) |
|---|---|---|
| off | The old behaviour: the operator's accounts can read Secrets, every backend ready | 24 checks, 0 failed |
| on | Turned on over the existing install (the upgrade path) | 116 checks, 0 failed |
| refused | The values list without the switch: refused by `install.sh`, nothing changed | 8 checks, 0 failed |
| back-off | `ALLOW_TOOL_SECRET_READ=1`: the switch is off again, the operator's accounts are back and can read Secrets | 27 checks, 0 failed |
| on again | On once more: the operator's objects are deleted again | 116 checks, 0 failed |

In the on phases: every tool server runs as its `openagentix-<name>` account; its Role has no rule on Secrets; `can-i` answers no for get, list and watch of Secrets, for the named header Secret, for pods, StatefulSets and Deployments, and for `pods/exec` and `pods/attach`; a throwaway pod that runs as an account gets 403 on a Secret and the list of Secrets and 200 on a ConfigMap; every backend is ready on every tool server (the knowledge base mirror, notify, `cluster-read` and the endpoint included); no tool server log has a forbidden or RBAC line; a call through the endpoint group reaches the endpoint, whose log shows its own header value; calls through the diagnostics group and the knowledge base mirror answer; and the header and bearer values are in no tool server log, ConfigMap, Role or ToolHive object. The install log of each on phase shows the account check for all five accounts.

WORKLOAD_PLACEHOLDER

## What the live runs found

- **The knowledge base and notify refused the `-workload` tool servers.** With the switch off, `tools-lookup-workload` reported its knowledge and notify backends as not ready. The `kb-ingress` and `notify-ingress` network policies admitted each profile's tool server and not its `-workload` variant. Nothing used the backends through that variant, so nobody had seen it, and the spike cluster had neither service. With the switch on the install check would have failed on it, so both policies now admit the `-workload` variants. The default render does not change.
- **The calls needed a restart.** The first calls through the tool servers failed with 401 until the script restarted them after the CA ConfigMap and the key binding were in place, as `hack/ci/endpoints-live.sh` does. This is how the CI values work, not a property of the accounts.
- **A count of exactly one was wrong.** The tool server makes requests of its own with the header, so the endpoint's log gains more than one line for one call.

## Limits

- One ToolHive version (0.67.1), one single-node kind cluster, one complete run of the five phases. The incoming side uses the API server's own tokens, not the identity provider of a real install.
- Credentials are held as environment values by every pod of a tool group. The group is the unit of trust. They are not short-lived or rotated, and the endpoint does not know which agent called.
- The `mcp.servers[]` proxies (the `osv` server here) have an upstream Role that may create pods in the tools namespace. Operators, anyone who can create pods or read Secrets in the tools namespace, and the ToolHive operator itself can still read the credentials.
- The accounts lack Secret reach only on an install where the install check ran, and only on the ToolHive version of the runs.
- The use case live jobs run on the quick start (one cluster each). The `--beside-full-demo` and `ALSO_COMPOSE` paths are covered by offline composition tests only.
