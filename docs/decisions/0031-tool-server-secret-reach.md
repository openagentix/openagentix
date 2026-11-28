# ADR 0031: credentials of tool endpoints, and tool servers that cannot read the Secrets of the tools namespace

Status: Proposed
Date: 2026-11-28
Issue: https://github.com/openagentix/openagentix/issues/229 (reference use cases; the follow-up named in ADR 0026 decision 12)
Replaces: none. The follow-up record that ADR 0026 A3 and decision 12 name for the Secret reach of every tool server in `mcp.namespace`. Builds on ADR 0025 section 4 and Amendment 1, and ADR 0026 A3 and A4. Closes one open row of ADR 0030 (accepted, PR #275). See "Relation to other records".

Today every tool server (the ToolHive `VirtualMCPServer` pods) in `mcp.namespace` runs under a ServiceAccount whose Role, made by the ToolHive operator, can get, list and watch every Secret in that namespace. So the header credential of one use case's endpoint is readable by the tool server of another use case. This record gives each tool server a ServiceAccount and a Role that the chart writes, with no right on Secrets, so the tool server accounts lose their Secret reach, and names it in the tool server's spec, which makes the operator create no ServiceAccount and no Role for it. Credentials still reach the tool server as environment values from Secret references, which the kubelet resolves; the pod never needs to read a Secret through the API. Off by default; with the new value unset, the chart renders byte for byte what it renders today. A spike on a throwaway cluster answered the fifteen questions of "Spike" as expected, with one partial answer (the ConfigMap rule stays); see "Spike results". The chart render, the install check and the use cases are not built and stay *unverified* until the slices below are done.

## Context

### What the platform shows today

- **The live answer.** The bank and equipment live runs (`docs/diary/what-works.md`, rows "Bank use case on `mcp.endpoints`" and "Equipment use case on `mcp.endpoints`") recorded that `kubectl auth can-i get secret` for the shared tool server's ServiceAccount answers yes. ADR 0026 decision 12 accepted that as a stated risk for the reference use cases, with this record as the follow-up.
- **What lives in `mcp.namespace` as Secrets.** The header Secrets of `mcp.endpoints[].auth` (the records services of the bank and equipment use cases), the bearer values of the diagnostics servers (ADR 0025 section 5), the per-caller values of ADR 0030 once built, and Secrets the ToolHive operator makes for each tool server's own use.
- **How a credential reaches a tool server.** The chart renders `headerForward.addHeadersFromSecret` on an `MCPServerEntry` next to an `MCPExternalAuthConfig` of `type: unauthenticated` (`charts/openagentix/templates/endpoints.yaml`). The ADR 0025 spike showed that the operator puts the value into every tool server pod of the group as an environment value **by Secret reference**, which the kubelet resolves when it starts the container.
- **What the chart renders on every tool server.** `outgoingAuth: {source: discovered}` and no `serviceAccount` (`charts/openagentix/templates/mcp.yaml`, which renders all tool servers: the shared one, one per profile, and the `-workload` variants of ADR 0019).
- **Network policy** already keeps a tool server of another group from reaching an endpoint (ADR 0026 A5). The gap is the credential, not the connection.

### What ToolHive 0.67.1 does

The version is pinned by `components/tools/install.sh` (`TOOLHIVE_VERSION=0.67.1`). The CRDs and the operator are not vendored in this repository; `make test-apiserver` fetches the CRDs at that version. The facts below were read on 2026-11-28 in a clean checkout of the ToolHive source at tag v0.67.1 (tag object 807cace, commit 2d33d6b; Apache-2.0), files named relative to its root. They are readings of code, not runs.

- **The Role of a tool server.** `cmd/thv-operator/controllers/virtualmcpserver_deployment.go` defines two rule sets. `vmcpDiscoveredRBACRules`, used for `outgoingAuth.source: discovered` (our case): get, list and watch on `configmaps` and `secrets`; get, list and watch on `mcpgroups`, `mcpservers`, `mcpremoteproxies`, `mcpserverentries`, `mcpexternalauthconfigs`, `mcptoolconfigs`; get on `virtualmcpservers`; update and patch on `virtualmcpservers/status`. `vmcpInlineRBACRules`, used for `source: inline`: only the last two.
- **Who owns it.** `ensureRBACResources` in `virtualmcpserver_controller.go` creates the ServiceAccount `<name>-vmcp`, a Role and a RoleBinding with "create or update" calls (`cmd/thv-operator/pkg/kubernetes/rbac/rbac.go`), on every reconcile, with a periodic requeue as a safety net. The operator does not watch Roles, so **an edit to that Role is put back** at the next reconcile of the tool server (an event, or the 30 s requeue). The chart cannot narrow it in place.
- **The way out the CRD offers.** `VirtualMCPServer.spec.serviceAccount`: "the name of an already existing service account to use by the Virtual MCP server". When it is set, `ensureRBACResources` returns at once: the operator creates no ServiceAccount, Role or RoleBinding, and the Deployment runs under the named account (`serviceAccountNameForVmcp`).
- **What the tool server reads at run time.** In discovered mode the tool server watches its group's entries with a cache limited to its namespace (`pkg/vmcp/k8s/manager.go`), and watches ConfigMaps for the CA bundles of entries (`pkg/vmcp/k8s/backend_reconciler.go`). Header values of `headerForward.addHeadersFromSecret` are taken from environment names (`pkg/vmcp/workloads/k8s.go`), not read from the API. The tool server reads a Secret through the API only for auth types that need one at run time (`headerInjection`, `tokenExchange`, `xaa`, in `pkg/vmcp/auth/converters/`), and the chart renders none of these. The session key is an environment value from a Secret reference too (`virtualmcpserver_deployment.go`).
- **Other ToolHive pods.** The proxy of an `MCPServer` (the `fetch` and `osv` servers) gets a Role with no rule on Secrets, but with create on StatefulSets and Services in its namespace (`defaultRBACRules` in `mcpserver_controller.go`), which is pod creation. The operator itself has get, list and watch on Secrets (its RBAC markers) and, in the operator chart's default `operator.rbac.scope: cluster`, in every namespace.
- **Outgoing auth types.** The `MCPExternalAuthConfig` type is one of `tokenExchange`, `headerInjection`, `bearerToken`, `unauthenticated`, `embeddedAuthServer`, `awsSts`, `upstreamInject`, `obo`, `xaa` (`cmd/thv-operator/api/v1beta1/mcpexternalauthconfig_types.go`). None sends the tool server's own Kubernetes ServiceAccount token to a backend. `tokenExchange` exchanges the caller's incoming token at a token endpoint, with a client secret from a Secret.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Do nothing (ADR 0026 decision 12) | Nothing to build | A compromise of any tool server pod gives every credential in `mcp.namespace` | Live `auth can-i` answers |
| B. A namespace per credentialed tool group | Each tool server's Secret reach is its own group's Secrets, whatever the operator grants; the structural answer named in ADR 0026 | Moves tool servers out of `mcp.namespace`, which about 50 references in the chart templates key on (refusal lists, ingress and egress policies, the kb and notify ingress, the guard, the runtime's tool URLs); one OIDC config, telemetry config and default policy per namespace; every tool URL of a moved group changes | Read in the templates; nothing run |
| C1. Narrow the operator's Role in place | Small | The operator puts the Role back on the next reconcile. Rejected | Source, `ensureRBACResources` |
| C2. A ServiceAccount and Role the chart writes per tool server, named in `spec.serviceAccount`, with no rule on Secrets | Same pods, same namespace, same URLs; the operator creates no Role for it; the reach to every Secret goes | The chart owns rights that upstream defined; an upstream change of what the tool server reads can break it, so the spike and the install check are needed on every ToolHive version bump | Source, `ensureRBACResources` and the runtime readers; the spike (run 46131733146), Role applied by hand |
| C3. `outgoingAuth.source: inline` | The operator's own minimal Role, no Secret rule | A different upstream path than the one shown in the ADR 0025 spike and the two live use cases: backends are written statically by the operator, and every backend's auth is listed in each tool server's spec | Source; nothing run |
| D. No shared credential: the endpoint checks the tool server's own projected token (audience-bound), by TokenReview or by the cluster's keys | No header Secret at all; tokens expire and rotate | ToolHive 0.67.1 cannot send it. It would need an upstream auth type, or an extra container in each tool server pod that reads a token file and adds the header (not checked that the pod template accepts one); and every endpoint must check tokens: TokenReview needs a cluster-wide grant for the endpoint, the keys need egress to the API server. A third-party endpoint cannot do it at all | CRD enum; nothing run |

### Cost on an 8 GB single node

| Option | Pods | Memory | Objects |
|---|---|---|---|
| B | None new (tool servers move) | None new | Per moved group: a namespace, its default policies, an OIDC config and a telemetry config; the moved tool servers restart with new URLs |
| C2 | None | None | One ServiceAccount, one Role and one RoleBinding per tool server; tool servers restart once when the switch is turned on |
| C3 | None | None | None; tool servers restart once |
| D | One more container per tool server pod of a credentialed group | Not measured | A token audience per endpoint; a grant for each endpoint that uses TokenReview |

## Decision

**Option C2**, confirmed by the spike ("Spike results"). D stays the direction for later, together with the gate token of ADR 0021 (proposed, PR #142) and identity in 0.4.

Why C2: the tool server accounts lose their reach to every Secret, with no new pod, no move, no new URL and no change to the policies, the guard or the catalog. It uses a field the CRD offers for this purpose, and the upstream code skips its own Role when the field is set. It keeps the discovered mode that the spike and the live use cases run on. Its weakness is that the chart now owns the list of rights, so a future ToolHive version that needs more would fail; the install check below makes that loud instead of silent.

### Chart value

```yaml
mcp:
  virtual:
    ownServiceAccounts: false    # true: the chart writes a ServiceAccount, a Role with no right on Secrets and a RoleBinding for every
                                 # tool server in mcp.namespace, and names the account in it. false (default): the tool group operator
                                 # makes them, and every tool server can read every Secret in mcp.namespace
```

One boolean. No new field on a resource. The words are the chart's own; no upstream word is in the value name.

### Render with `ownServiceAccounts: true`

For every tool server the chart renders (the shared one, each profile, each `-workload` variant):

- a ServiceAccount `openagentix-<tool server name>` with `automountServiceAccountToken` left to the pod (the tool server needs its token for the API);
- a Role of the same name with exactly these rules: get, list and watch on the ToolHive resources the upstream discovered rules name (`mcpgroups`, `mcpservers`, `mcpremoteproxies`, `mcpserverentries`, `mcpexternalauthconfigs`, `mcptoolconfigs`); get on `virtualmcpservers` and update and patch on `virtualmcpservers/status`, both limited by `resourceNames` to its own object; get, list and watch on `configmaps` (the CA bundle watch; without it the spike saw repeated `configmaps is forbidden` watch errors). Nothing on `secrets`. Nothing else;
- a RoleBinding of the same name to that ServiceAccount;
- `spec.serviceAccount: openagentix-<tool server name>` on the tool server.

While it is on, the chart refuses an entry whose auth type reads a Secret at run time (`tokenExchange`, `headerInjection`, `xaa` in 0.67.1); such a type needs `get` on exactly its Secrets by `resourceNames`, in a later amendment.

Chart tests: the default, quick start and full demo renders byte-identical with the value false; with true, every tool server names an account of the chart, and no Role, ClusterRole or binding in the render gives such an account any verb on Secrets; a Role names only its own tool server in `resourceNames`; no rendered ConfigMap in `mcp.namespace` carries a value from a Secret; an entry with one of the three auth types above is refused while the switch is on.

### Install check and clean-up

- After the apply, `install.sh` runs `kubectl auth can-i get secrets`, `list secrets`, `create pods`, `create statefulsets` and `create deployments` in `mcp.namespace` as each tool server's account, and fails the install when any answers yes, with the account's name. It also runs the ADR 0026 A4 check (every backend `ready`, no `DiscoveredAuthConfig-*` False), because a missing right shows up as a dropped backend, not as a tool server that is not Ready.
- After the tool servers run under the new accounts, `install.sh` deletes the operator's old ServiceAccount, Role and RoleBinding of each (`<name>-vmcp`), which otherwise stay until the tool server is deleted (they carry an owner reference to it). With Helm alone, the operator's old `<name>-vmcp` objects stay until deleted; nothing runs as them. Turning the switch back to false makes the operator create them again.
- Turning the value from true to false on a live release is refused by `install.sh` unless `ALLOW_TOOL_SECRET_READ=1`, so a values file left out of a run cannot silently give the reach back.

### What this closes, and what stays

| Threat | After this record |
|---|---|
| A tool server pod of group A reads the header Secret of group B's endpoint through the API | Closed for the tool server accounts: they have no right on Secrets. Workloads whose upstream Role may create pods in `mcp.namespace` stay under the operator trust row |
| A tool server reads ADR 0025's bearer values or ADR 0030's per-caller values of another group | Closed for the tool server accounts, the same way |
| A tool server pod of group A reaches group B's endpoint | Already stopped by the egress and ingress policies (ADR 0026 A5) |
| Every tool server pod of a group holds, as environment values, the header values of every entry of the group | Stays (upstream behaviour, spike). The group is the unit of trust |
| Anyone who can create pods, or read Secrets, in `mcp.namespace` | Stays. That is operator trust |
| The proxies of `mcp.servers[]` can create pods in `mcp.namespace` (upstream Role) | Stays; a namespace of their own is a later step |
| The ToolHive operator reads Secrets in every namespace | Stays. It is trusted like a cluster component |
| The header value is static and needs a tool server restart to change | Stays (ADR 0026) |
| The endpoint cannot tell agents apart | Stays (ADR 0026 A8, until 0.4 identity) |

### Not added

- **No admission policy** that refuses a tool server in `mcp.namespace` without `spec.serviceAccount`. Whoever can create such an object there can also create a pod that mounts any Secret there, so the policy would add a rule without a boundary.
- **No status field.** The controller does not read RBAC of tool servers and cannot verify it; no status says the tool servers lack Secret reach. The evidence is the install check and the live proof, recorded in `what-works.md`.
- The control plane is not touched. It never reads Secrets, and it writes nothing in `mcp.namespace`.

### What must not be claimed

- that no one in the tools namespace can read a credential (operators, pods created there and the ToolHive operator can);
- that no workload in `mcp.namespace` can reach a credential (the `mcp.servers[]` proxies may create pods there);
- that credentials are isolated per tool server or per profile (they are per tool group, held as environment values by every pod of the group);
- that credentials are short-lived or rotated;
- that the endpoint knows which agent called;
- that the tool server accounts lack Secret reach on an install where the install check did not run, or on a ToolHive version other than the one the spike ran on.

### Migration: the three use cases beside a full demo

- The value is a platform switch. A file `components/tools/own-service-accounts-values.yaml` sets it; it goes into the full demo's `VALUES_FILE` list once and then on every run of every installer, the use case installers with `--beside-full-demo` and `ALSO_COMPOSE` included. `mcp.virtual.ownServiceAccounts` joins the security keys of `hack/compose-values.sh`, and the use case installers' release-values guard accepts it when it is in `VALUES_FILE`.
- Turning it on restarts every tool server once (a new account in the pod template). Agents in a run at that moment may see a failed tool call. Turn it on between runs.
- The use case live scripts (`hack/ci/endpoints-live.sh`, `hack/ci/bank-live.sh`, `hack/ci/equipment-live.sh`, `hack/ci/diagnostics-live.sh` and `hack/ci/rca-live.sh`) change their `auth can-i get secret` step from "yes, the accepted risk" to "no". The software organisation's diagnostics group is covered the same way, because its tool servers are rendered by the same template.
- `docs/diary/what-works.md` rows for the bank, equipment and diagnostics tool servers change "every tool server can read every header Secret" to the result of the live proof, with the limits above. ADR 0026 and ADR 0025 get a short dated note pointing here, each in its own pull request.

## Spike

On a throwaway kind cluster with its own kubeconfig (never the maintainer's cluster), ToolHive 0.67.1, the stub model, no paid call: the full demo values plus one endpoint group with a header credential, the diagnostics group, and one `-workload` variant, with `spec.serviceAccount` and the Role above applied by hand (the chart slice comes after). Each question is answered yes or no in the diary, with the commands and outputs.

1. With `spec.serviceAccount` set, does the operator create no ServiceAccount, Role or RoleBinding for that tool server, and leave the chart's alone across a reconcile, a spec change and an operator restart? (expected yes)
2. With a Role that has no rule on Secrets, does each tool server become Ready and list every backend of its group as `ready` in `status.discoveredBackends`: the endpoint with a header from a Secret, the kb mirror, notify, and in the shared group the `fetch` and `osv` servers? (expected yes)
3. Does `tools/list` and a call work through each, and does the endpoint receive the header value? (expected yes)
4. Do `kubectl auth can-i get secrets` and `list secrets` in `mcp.namespace`, as each account, answer no, and does a pod that runs as that account get 403 on a Secret read? (expected yes)
5. Does any log line of a tool server show a refused read (forbidden) during start, discovery, an entry added while it runs and a backend restart? (expected no)
6. Does the `-workload` variant still accept a pod-bound token of a container agent and refuse one with another audience? (expected yes)
7. Is the Role enough without the ConfigMap rule? (if yes, the chart drops it)
8. Does the status of the tool server keep updating with `virtualmcpservers/status` limited by `resourceNames` to its own object? (expected yes)
9. Do the operator's old `<name>-vmcp` account, Role and binding stay after the switch, and does deleting them make the operator create them again? (expected: they stay; not created again)
10. Node memory before and after, and the restart time of the tool servers when the switch is turned on.
11. As each tool server account: do `can-i create pods`, `create statefulsets`, `create deployments`, `get pods/exec` and `create pods/attach` in `mcp.namespace` all answer no? (expected yes)
12. As each account of an `mcp.servers[]` proxy: what does `can-i create statefulsets` answer? (recorded; expected yes, the upstream Role)
13. Is each tool server's own session Secret still created, and does the pod start? Does a session continue across a tool server restart, or fail cleanly?
14. Do a `helm upgrade` with the switch on, an operator restart and a re-install of the operator at the same version leave the chart's ServiceAccount, Role and RoleBinding as Helm wrote them?
15. Under the new account, are the pod's volumes and environment sources the same as today, with nothing new?

Stop rule: if question 1, 2, 3 or 4 is answered against the expectation, the chart slice does not start. (They were not; see "Spike results".)

## Spike results

Run [46131733146](https://github.com/openagentix/openagentix/actions/runs/46131733146) of the `e2e` workflow (input `adr0031`, job `e2e (adr 0031 spike, tool server accounts)`, PR #277), recorded in `docs/diary/features/adr-0031-tool-server-spike.md`. A kind cluster on a hosted runner, the quick start with the CI values of the endpoints job, the stub model, no paid call. ToolHive as running: operator image, both charts and the tool server image all v0.67.1. Four tool servers (`tools`, `tools-lookup`, `tools-lookup-cm` and `tools-disputes` with two endpoints that take a header from a Secret), each switched by hand to a ServiceAccount and the Role of "Render with `ownServiceAccounts: true`".

| # | Answer |
|---|---|
| 1 | Yes. No operator ServiceAccount, Role or RoleBinding for a tool server with the field set; the hand-written objects unchanged across an event, a spec change and an operator restart |
| 2 | Yes. Every backend `ready` on each tool server (`osv`, and both endpoints on `tools-disputes`) |
| 3 | Yes. Tool lists and answers identical before and after; the endpoint received its header on every request |
| 4 | Yes. `can-i get` and `list secrets` answered no for each account (yes for the operator's accounts before); a pod as the new account got 403 on a Secret read, a pod as the old account got 200 |
| 5 | No forbidden or RBAC line in any tool server log at start, with an entry added while running, and with a backend restart |
| 6 | Yes. A `-workload` variant accepted a pod-bound token with its audience and refused another audience (401 `invalid audience`) |
| 7 | Partly. Without the ConfigMap rule the tool server kept working, but its log filled with repeated `configmaps is forbidden` watch errors. The rule stays |
| 8 | Yes. Status kept updating with `resourceNames` on the own object; `can-i` no for another tool server's name |
| 9 | The old `<name>-vmcp` objects stay after the switch and are not created again once deleted |
| 10 | Node 2.479 GiB before, 2.537 GiB after (whole node, one more test tool server running); each tool server Ready with all backends about 16 s after the switch |
| 11 | No for create pods, statefulsets, deployments, `pods/exec` and `pods/attach`, for each account |
| 12 | Recorded for the one `mcp.servers[]` proxy of that install, as the upstream Role says |
| 13 | The session Secret is still made and reaches the pod as an environment value from a Secret reference; a session ends cleanly on a restart (404) and a new one works |
| 14 | A Helm upgrade and an operator restart changed nothing in the hand-written objects |
| 15 | No new or missing volume or environment source |

The stop rule did not trigger, so `outgoingAuth.source: inline` was not tried. **Limits:** one ToolHive version, one single-node kind cluster, one complete run; one shared-group server (`osv`) and one endpoint group, with no knowledge base mirror, notify or diagnostics group in the cluster; the incoming side used the API server's own tokens, not the identity provider of a real install; the Role was applied by hand, so the chart render, the admission policies and the install check were not exercised; memory is for the whole node; no `osv` tool call was made (the header was tested on `echo` only); question 7 ran with no CA bundle ConfigMap on any entry; in question 14 `spec.serviceAccount` survived a Helm upgrade only through the three-way merge of a field patched by hand, since the chart does not render it yet.

**If a later ToolHive version breaks this,** the fallbacks stay on record: `outgoingAuth.source: inline` (C3), then a namespace per credentialed group (B). Each would need its own amendment.

## Consequences

- Possible: credentials of several use cases in one tools namespace, where a compromise of one group's tool server does not give another group's credential through the API.
- Harder: the chart owns the rights of tool servers; each ToolHive version bump re-runs the spike's questions 2 to 5 and the install check.
- Ruled out for now: a shared credential that tool servers do not hold at all (option D); per-agent credentials.
- Security impact: narrows what every tool server account may read in `mcp.namespace` when the value is on. No new pod, no new network path, nothing new leaves the cluster, nothing new is logged. The control plane is unchanged and reads no Secret. Security-relevant: the chart slice gets an independent review before merge.
- Compatibility: none with the default. With the value on, every tool server restarts once; the old operator objects are removed by the installer.
- Proof needed: the spike (done, with the limits in "Spike results"), then the tests and live checks of the slices.

## Relation to other records

| Record | Relation |
|---|---|
| ADR 0026 | The follow-up of A3 and decision 12. This record narrows the reach in place; the namespace per credentialed group stays on record as a fallback |
| ADR 0025 | Amendment 1's note on Secret reach applies to the diagnostics bearer values; they are covered by the same switch |
| ADR 0030 (accepted, PR #275) | Its per-caller values for the knowledge base live in `mcp.namespace`; this record removes their reach from other groups' tool server accounts (row 5 of its section 7) |
| ADR 0021 (proposed, PR #142) | Its gate token and option D are the way to a credential the tool server does not hold as a static value |
| ADR 0019 | The `-workload` variants get accounts like every other tool server |

## Slices

Each slice is one pull request that `Refs #229`, tests first, off by default, with a changelog line when users can see it.

1. **This record.** Docs build.
2. **Spike** (done, PR #277, run 46131733146). Diary entry with each answer, the commands, the outputs and the limits; this record amended with the result. The chart slice's live check covers what the spike did not: the knowledge base mirror, notify and the diagnostics group.
3. **Chart and installer** (security-relevant, independent review). The value, the three objects per tool server, `spec.serviceAccount`, the install check, the clean-up of the operator's objects, the refusal to turn it off, the compose security key. Chart tests as above. `make test-apiserver`: the rendered objects pass a server-side dry run against the ToolHive CRDs at the pinned version, and `kubectl auth can-i` as each rendered account answers no for Secrets on the real API server. Installer tests with fakes: a yes from `can-i` fails the install with the account's name; the clean-up deletes only `<name>-vmcp` objects of tool servers the chart renders. Live, in CI on kind (the `e2e` workflow with endpoints and diagnostics, the knowledge base and notify on): every backend `ready` on every tool server the chart renders, the knowledge base mirror, notify and the diagnostics entries included, and on one `-workload` variant; the install check runs and passes; a call through each group reaches its endpoint with its header, `can-i` no for every account, no forbidden line in any tool server log.
4. **The use cases.** The switch in the full demo list; the bank, equipment and software organisation live scripts with it on, beside a full demo (`--beside-full-demo`, `ALSO_COMPOSE`), on a throwaway cluster, with the incoming side through the full demo's identity provider; `can-i` steps flipped to no; `what-works.md`, the use case READMEs and the diary with the limits.

## Not checked / open points

- *Unverified*: the chart render and install check; the knowledge base mirror, notify and the diagnostics group under the new accounts; the incoming side with the identity provider of a real install; whether a later ToolHive version adds a run-time read that this Role lacks; whether the pod template of a tool server accepts an extra container (option D).
- Read again before quoting: the ToolHive version in `components/tools/install.sh`, its discovered and inline rules, `spec.serviceAccount`, and the list of auth types.

### Settled by the spike

- **C2 or B.** C2: the spike answered questions 1 to 4 as expected.
- **The ConfigMap rule.** It stays (question 7).
- **Fallback order.** Not needed now; C3 and B stay on record in "Spike results".

### Open questions, with recommended answers

1. **Default.** *Recommended:* off in this record, as every new switch is. The reference use cases and the full demo turn it on in slice 4. A later record makes it the default after one release with the use cases on it.
2. **Refuse `mcp.endpoints[].auth`, the diagnostics bearer values and ADR 0030's values while the switch is off?** *Recommended:* not now; `install.sh` and the chart's `NOTES.txt` print a warning naming the credentials that every tool server can read. A refusal comes with the record that makes the switch the default.
3. **Option D upstream.** *Recommended:* record it as the direction, with ADR 0021, and let the maintainer decide whether to ask ToolHive for an outgoing auth type that sends the tool server's own projected token with an audience. Not part of this record's slices.

## Review notes

An independent review (2026-11-28) confirmed the ToolHive facts in a clean checkout of tag v0.67.1 and agreed with C2 and with every recommended answer. It asked for these changes, all taken: the threat rows say the tool server **accounts** lose Secret reach, not that the namespace is closed, because the proxies of `mcp.servers[]` have an upstream Role that may create pods there (a new row and a new item under "What must not be claimed"); while the switch is on, the chart refuses an entry whose auth type reads a Secret at run time; the operator does not watch Roles, so an edit returns at the next reconcile; the install check also asks about pod, StatefulSet and Deployment creation; the old operator objects stay with Helm alone; a chart test that no ConfigMap in `mcp.namespace` carries a Secret value; the warning also in `NOTES.txt`; spike questions 11 to 15; the status line says a spike is required. No point of the review was rejected.
