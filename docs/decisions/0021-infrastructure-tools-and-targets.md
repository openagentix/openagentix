# ADR 0021: tools that act on infrastructure, behind MCP, with a scoped identity per target

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/141 (umbrella; requirement trail in the comments of #14)
Replaces: none. Extends ADR 0006 (tool profiles), ADR 0012 (`CredentialGrant`, `ApprovalRequest`, `Workspace`), ADR 0019 (projected tokens, Cedar rule) and the AgentAccess pattern of ADR 0016 (proposed, PR #121). Depends on ADR 0018 (signed images) and ADR 0020 (egress proxy, proposed, PR #135). See "Relation to other records and issues".

An agent never runs `kubectl`, `helm`, `aws`, `gcloud` or `az` itself, and never holds their credentials. These tools run in a platform tool server behind MCP. The tool server acts on named **targets** (a cluster or a cloud account), each with its own identity, scope and tier. A call always names its target. Credentials are short-lived and fetched for one target at a time by a pluggable credential provider. The permission boundary is the target's own RBAC or IAM; platform policy only narrows it. Read-only is the default, and a mutation needs an allowlist and, on production tiers, an approval. Nothing here is built. Everything is *unverified* until the slices below are done. Not in release 0.3.

## The question

The owner asked: can we use CLI tools and make them work, or must we rely only on MCP? A `kubectl` tool needs a kubeconfig and RBAC. `helm`, `aws` and the other cloud CLIs need the same kind of thing. Later questions added: what happens when the cluster or account is remote, and when there are many of them.

Short answer: yes, CLI tools can be used, but only behind MCP, inside a platform tool server that holds the identity. MCP is the only door. The agent sends a structured request; the tool server checks it, gets a short-lived credential for one target, runs the tool, filters the output and records what happened. Where a good MCP server already exists, we adopt it behind an adapter instead of wrapping the CLI.

## Context

### What exists today (read in this repository on 2026-11-26)

- Tool servers are ToolHive `MCPServer` objects in `mcp-tools`, all in one `MCPGroup` (`charts/openagentix/templates/mcp.yaml`, values `mcp.servers`). The shared vMCP aggregates every server of the group. A tool profile (`mcp.profiles`, ADR 0006 round 2) is one more vMCP on the **same group** with a tool filter, its own OIDC audience and its own RemoteMCPServer. A profile hides tools; it does not remove a backend from the shared vMCP's view (`docs/diary/features/security.md`).
- Built-in agents run in Agent Substrate sandboxes (gVisor). Egress is deny by default per actor; rules match host and port only (ADR 0006, F7). Every agent has a `bash` tool by default, and `bash` can call the agent's own profile vMCP with the session's token: the egress proxy replaces any `Authorization` header with the actor JWT (`docs/diary/features/security.md`, proven on kind). So anything a profile allows, a prompt-injected agent can call directly, without the agent loop. A control that lives in the agent loop is not a control.
- Container agents (ADR 0015, ADR 0019) reach a profile through a workload variant of the profile server that accepts a pod-bound projected ServiceAccount token with a per-profile audience, restricted by a Cedar rule on the namespace and the `pod` claim.
- The controller never reads Secrets. Its Roles are namespaced, with no ClusterRole and no wildcard (ADR 0007). Admission guard policies are key allowlists bound to the controller's identity.
- ADR 0007 plans the kinds `ToolServer` and `ToolProfile` (replacing `mcp.servers` and `mcp.profiles`) and says a new server image is a supply-chain decision: digest required, operator approval. The admission guard already refuses `kagent-tool-server` as an agent's tool server.
- ADR 0012 reserves `CredentialGrant` (0.4: a subject that is an agent or a run, a source, an audience, scopes, a lifetime, injected at the egress proxy for one host), `ApprovalRequest` (0.4), scoped `PlatformPolicy` with tool rules allow, require approval, deny (0.5) and `Workspace` (0.5).
- ADR 0010: security is never an enterprise feature. Approval workflows with routing and escalation, and on-behalf-of-user brokers for many providers, are listed as enterprise; one approver is community.
- ADR 0020 (proposed): container agents reach named outside hosts only through a platform CONNECT proxy that never decrypts TLS. A credential grant per destination is named there as later work.
- ToolHive `MCPServer.spec.serviceAccount` names an existing ServiceAccount for the server pod; without it one is created. `permissionProfile` "is not supported by the Kubernetes operator and has no effect" (ToolHive CRD reference, read 2026-11-26, https://docs.stacklok.com/toolhive/reference/crds/mcpserver). Whether the version we pin (v0.67.1) behaves the same is *unverified*.

### The market today (read 2026-11-26)

The full table with sources is in "Appendix: existing MCP servers". The facts that shape this decision:

- **Every serious server says RBAC or IAM is the real boundary.** containers/kubernetes-mcp-server: "Kubernetes RBAC on the identity this server authenticates as is the access control to rely on"; its `read_only` and `disable_destructive` "do not change the cluster permissions of the identity". Azure/aks-mcp calls its access levels "a guardrail, not a security boundary".
- **Read-only modes exist but are off by default** in most servers (kubernetes-mcp-server, Flux159, aws-api-mcp-server, Azure MCP Server, kagent-tools). Exceptions: awslabs eks-mcp-server and Azure/aks-mcp default to read-only.
- **Several servers shell out** to `kubectl`, `helm`, `az` or `gcloud` (Flux159, kagent-tools, aks-mcp, gcloud-mcp). Flux159/mcp-server-kubernetes has had at least four command or argument injection advisories in 2025 and 2026 (CVE-2025-53355, CVE-2025-66404, CVE-2026-47250, CVE-2026-61459), one of them a flag injection that can leak bearer tokens. kubernetes-mcp-server uses the Go client and does not shell out.
- **Token passthrough is a trap.** kubernetes-mcp-server's `cluster_auth_mode` defaults to passthrough: "forward Authorization header when present, fall back to kubeconfig when absent". The MCP authorization specification (2025-11-25) says a server "MUST NOT pass through the token it received from the MCP client". Behind our vMCP, the header would be the agent's actor or workload token. It must never reach an API server. Any adopted server is configured with its own identity explicitly, never in passthrough.
- **Acting as the calling user** is done by token exchange (kubernetes-mcp-server `rfc8693`, `entra-obo`; ToolHive RFC 8693), by the caller's own identity at managed remote servers (AWS MCP Server, Google's managed GKE MCP), or by Kubernetes impersonation (giantswarm/mcp-kubernetes, from a package listing only).
- **Managed remote servers** exist from AWS (GA 2026-05-06, from a search result) and Google (managed GKE MCP at `container.googleapis.com/mcp`, OAuth scopes `container.read-only` or `container`). They run outside the cluster and act as the caller's cloud identity.

### Kubernetes and cloud facts (read 2026-11-26)

- Structured authentication configuration (KEP-3331, `apiserver.config.k8s.io/v1`, `jwt` authenticators with CEL claim mappings and validation rules, reloaded without a restart) is stable in Kubernetes 1.34 (https://www.kubernetes.dev/resources/keps/3331/, https://kubernetes.io/blog/2025/08/27/kubernetes-v1-34-release). It replaces the `--oidc-*` flags. It lets a remote API server trust our home cluster's ServiceAccount issuer. It needs access to the API server's configuration, which managed clusters do not give in the same form (see "Remote Kubernetes").
- Constrained impersonation (KEP-5284) is alpha in 1.35 and beta, on by default, in 1.36 (https://www.kubernetes.dev/resources/keps/5284/). Classic impersonation needs the `impersonate` verb, which lets the holder act as every named user or group.
- AWS `AssumeRoleWithWebIdentity` with an IAM OIDC provider works from any cluster whose issuer discovery document and keys AWS can fetch. Self-managed clusters publish them, for example in a public bucket (guides from Sidero Labs and Canonical; no AWS page states the requirement directly, so *read again before quoting*).
- Google Workload Identity Federation accepts an uploaded JWKS file (`--jwk-json-path`, at most 8 keys) for an issuer that is not publicly reachable (https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-other-providers).
- Azure federated identity credentials match the token's issuer and exact subject. Whether a private issuer can be used with uploaded keys was not found; *unverified*.
- Argo CD Agent is a hub-and-spoke design in which "the agent initiates the connection to the principal, and the control plane cannot initiate connections to agents", over a bidirectional gRPC stream (https://argocd-agent.readthedocs.io/latest/concepts/components-terminology/, Red Hat OpenShift GitOps 1.19 docs).

## Options

### Where the CLI runs

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. A platform tool server behind MCP holds the binary and the identity; the agent sends structured requests | One door with authentication, policy, audit and output filtering. The credential never enters the agent. Same path for built-in and container agents | One more server per profile (memory not measured). Tools must be structured; free-form commands are refused | ADR 0006 and 0019 patterns; market facts above |
| B. A shell in the agent sandbox with a kubeconfig or cloud keys | Every CLI feature at once; no server to run | The credential is inside the component that reads untrusted text. `bash` already bypasses the agent loop. Any flag (`--server`, `--token`, `--as`, `--kubeconfig`) is open. No per-call policy, no reliable audit | ADR 0006 F5; diary security page |
| C. A sidecar per agent with the credential | Per-agent identity | The credential shares a pod and a trust domain with the agent; `exec` into the pod reaches both. Substrate sandboxes are not pod specs we write. One sidecar per agent costs more than one server per profile | ADR 0015 isolation list |
| D. A credential-injecting egress proxy: the agent runs the CLI, the proxy adds the credential | The agent never sees the key | Needs TLS interception (a CA trusted inside the agent) to add headers to HTTPS. ADR 0020 decided the proxy never decrypts. The agent still chooses every request. Not in 0.3 | ADR 0020 |
| E. Only MCP servers, no CLI anywhere | Simplest story | Some tasks (a `helm` operation, a cloud command with no structured server) would have no tool at all | Market table |

### How a target is described

| Option | What it gives | What it costs |
|---|---|---|
| F. Fields on the tool profile (`profile.targets[]` with endpoint and credentials) | No new kind | A target is shared by several profiles with different rights; the endpoint, trust and tier would be copied into each. The person who edits a profile would also edit where it reaches. No place for status per target |
| G. Reuse `CredentialGrant` (ADR 0012, #14) | One kind for "a credential for outbound access" | A grant's subject is an agent or a run and its injection point is the egress proxy for one host. A target is a place (endpoint, tier, owner, reachability) used by a tool server, not by the agent. Mixing them would put cluster endpoints and tiers into a credential object |
| H. A new kind `ToolTarget` (the place, its identity provider, tier, scope, owner, status) and a binding kind `TargetAccess` (which profile may use which targets, and how) | Status per target, a disable switch, one reviewable list of who may reach what, deny by default | Two more kinds to build and keep |
| I. Chart values only | Nothing new to build | No status, no change without `helm upgrade`, against "every configurable thing is a resource" |

### Whose identity a call uses

| Option | What it gives | What it costs |
|---|---|---|
| J. The tool server's own identity, one per profile and target | Works for every caller (chat, schedule, container agent). The boundary is a role an operator can read | Every agent of a profile acts the same; the target's audit shows the profile, not the person |
| K. The calling user, by Kubernetes impersonation | Target RBAC per person | The tool server needs `impersonate`, which is the power of every user it may name. Our user id (`X-User-Id`) is information set by the gate from caller rules, not proof (ADR 0015); a Telegram chat id is not a cluster user. Constrained impersonation needs Kubernetes 1.36 |
| L. The calling user, by token exchange (RFC 8693, OBO) | Real per-person rights without `impersonate` | Needs a verified login at the gate or console and an identity provider each target trusts. Belongs to the identity adapter (#13) |

## Decision

Options A, H and J, with E as the first choice inside A (adopt a structured server before wrapping a CLI). K and L are not built now; L is the planned path for acting on behalf of a user.

### 1. The position

- **MCP is the only door.** No agent, built-in or container, gets a kubeconfig, a cloud key, a cloud role or a CLI with credentials. The platform never mounts such a credential into a sandbox or an agent pod, and the admission guard refuses it.
- **CLIs run in a platform tool server**, not in the agent. The tool server is an adopted MCP server (preferred) or, only where none fits, a thin platform wrapper around the CLI. Either way it sits behind the **target gate** described below.
- **A shell is for compute only.** A sandbox shell (the existing `bash` of built-in agents, or the approved execution environments of #20) may be enabled for code execution and data work. It has no cluster or cloud credential, no route to a target, and goes through the egress controls (Substrate egress, ADR 0020). A `kubectl` binary in such a sandbox is harmless because it has nothing to authenticate with. Changing infrastructure goes through MCP tool servers with a scoped identity, not through a shell.

### 2. The shape of a tool server

```mermaid
flowchart LR
  A["agent (sandbox or container)"] -->|"MCP, profile token"| V["profile vMCP"]
  V --> G["target gate (platform)"]
  subgraph ts["tool server pod, one per profile and tier group"]
    G -->|"checked call, one target"| S["adopted MCP server or CLI wrapper"]
    G -->|"credential for this target"| P["credential provider"]
  end
  S -->|"short-lived credential"| T1["target dev-eu (cluster)"]
  S --> T2["target stage-aws-123 (account)"]
```

- One tool server instance serves **one profile**. It may serve several targets of that profile. Targets of the `prod` tier get a **dedicated instance** with its own home identity (see "Isolation").
- The instance runs in its own `MCPGroup` with only its profile's vMCP (and that profile's workload variant from ADR 0019, if opened to container agents). It is never part of the shared group, so the shared vMCP and other profiles cannot see it. This is a change from today's single group and is required: a profile filter only hides tools.
- The **target gate** is a small platform component in front of the server, in the same pod. It does what no adopted server does for us: requires the target argument, checks it against the profile's grants, applies argument policy and approval, fetches the credential for that one target, caps and scans the output, and writes the audit line. If ToolHive's Cedar authorizer can see tool arguments (*unverified*), the target allowlist is also written there as a second layer.

### 3. Targets

A target is a cluster or a cloud account the platform may act on. It is a new kind, `ToolTarget` (`openagentix.io/v1alpha1`), written by operators only (like `PlatformPolicy`). The controller reads it and never creates the trust it describes: the remote side (RBAC, IAM role, trust policy) is set up by the target's owner.

The shape (illustrative, fields fixed in the slice that builds the kind):

```yaml
apiVersion: openagentix.io/v1alpha1
kind: ToolTarget
metadata:
  name: stage-eu-cluster          # DNS label, starts with its tier (see "Names shown to the model")
  labels: {openagentix.io/tier: stage, team: payments}
spec:
  type: kubernetes                # kubernetes | aws | gcp | azure
  description: "Stage cluster of the payments team, eu region"
  owner: payments-platform        # a team name, not a person
  endpoint: {url: "https://stage-eu.example.internal:6443", caBundle: {configMap: stage-eu-ca, key: ca.crt}}
  credentials:                    # exactly one provider
    federation: {audience: "openagentix:stage-eu-cluster"}
  scope:                          # what the platform may ask for; the remote RBAC or IAM decides what it gets
    namespaces: [payments]
  disabled: false                 # the instant switch
status:
  observedGeneration: 1
  conditions: []                  # Accepted, Reachable, CredentialValid, Ready
  credentialExpiresAt: ""
  controller: {}
```

- **Words in the spec.** `kubernetes`, `aws`, `gcp` and `azure` name the kind of place, not an upstream component of OpenAgentix. Broker products (for example Vault), adopted server names and images stay out of the spec; they live in the catalog's adapter-owned section, as `docs/api-conventions.md` requires.
- **One identity per target.** Each target has its own remote subject: its own audience for federated tokens, its own IAM role, its own Secret for the fallback. No credential is shared between targets. Two targets that resolve to the same remote role are refused (where the controller can see it: same role ARN, same audience, same Secret).
- **Status.** Conditions follow `docs/api-conventions.md`. `Reachable` comes from a probe by the tool server that uses the target (a version or caller-identity call), not by the controller, which has no route and no credential. `CredentialValid` is `True` only when the last fetch succeeded, with `credentialExpiresAt`; `Unknown` when no instance has tried; never a guess. A target that has not been probed is not `Ready`.
- **Disable.** `spec.disabled: true` makes every gate that serves the target refuse it at the next rules reload (the same reload path as the gate route list, about a minute, *unverified*), and drops cached credentials for it. A faster path is to delete the `TargetAccess`, which has the same effect.
- **The home cluster** is a target too (`type: kubernetes`, `credentials.inCluster`), so there is no special case and no hidden default.

### 4. Which profiles may use which targets

A second kind, `TargetAccess`, follows the deny-by-default binding of `AgentAccess` (ADR 0016, #3): one subject per object, a list of granted targets, one place to review.

```yaml
apiVersion: openagentix.io/v1alpha1
kind: TargetAccess
metadata: {name: k8s-ops-stage}
spec:
  profile: k8s-ops                # the subject: one tool profile
  targets:                        # by name, or by label selector within a tier
    - name: stage-eu-cluster
    - selector: {matchLabels: {openagentix.io/tier: dev, team: payments}}
  access: read                    # read | write
  fanOut: {enabled: true, maxTargets: 10}
status:
  conditions: []
  effectiveTargets: []            # names after the selector is resolved
```

- **The chain is reviewable.** Agent to profile: the agent's definition (`toolProfile`) under `policy.allowedProfiles`. Profile to targets: `TargetAccess`. Target to remote rights: the target owner's RBAC or IAM. No other path exists. `kubectl get targetaccess` lists every grant.
- No `TargetAccess`, no target. A selector never crosses tiers by itself: a selector without a tier label is refused.
- Who may write it: in 0.x an operator Role, rendered without bindings, like the `AgentAccess` roles. Whether target owners can grant their own targets is an open question tied to tenancy.
- The controller resolves grants and writes the accepted list into the gate's rules file for that profile's instance. The gate reloads it. Same mechanism and limits as ADR 0016 option A.

### 5. Calls: explicit target, no hidden context

- **Every call is stateless and names its target.** Each tool of an infrastructure profile has a required `target` argument whose JSON schema is an enum of the profile's effective targets. There is no "current context", no `use-context` tool and no default target. A call without a target is refused. The gate ignores any context, server, token or profile argument and sets them itself.
- **Refused before the tool runs.** A target outside the grants, a disabled target, or one whose credential cannot be fetched is refused by the gate. The adopted server or CLI is not called.
- **Credentials per target.** Fetched for one target, used for that call, and cached at most for their own lifetime keyed by `(instance, target)`, never across targets. A mutating call always fetches fresh. When a target is disabled or removed, its cache entry is dropped.
- **Tiers drive defaults.** The label `openagentix.io/tier` is one of `prod`, `stage`, `dev` (quoted in YAML). Defaults, which an operator can tighten and, except for the first row, loosen per target:

| Tier | Access | Mutations | Rate cap (starting values, to be measured) | Instance |
|---|---|---|---|---|
| `prod` | read | only with an approval, every time; cannot be waived | 30 reads a minute, 5 mutations an hour per target | dedicated, own home identity |
| `stage` | read | with an approval by default; waivable per `TargetAccess` | 60 reads a minute, 30 mutations an hour | may share with `dev` |
| `dev` | read | allowed when `access: write` is granted | 120 reads a minute | may share with `stage` |

- **Fan-out reads.** A read tool may take `targets` (a list, or a group selector already allowed by the grant) instead of one target, for questions like "list failing pods in every stage cluster". Rules: read only (a fan-out mutation is refused; it would need one approval per target in a later slice); at most `fanOut.maxTargets` (default 10, hard limit 50); at most 4 targets in parallel; a timeout per target (10 s); one result object per target with `ok`, `denied`, `error` or `timeout`; a total output cap across all targets. Partial failure is a normal answer: the result names the failed targets and never retries with another target's credential. One audit line per target and one for the fan-out.
- **Cross-target flows.** Reading A and writing B are two calls; the platform cannot see what the model carries between them. So the combination itself needs permission: a profile whose grants include `write` on any target and `read` on a target of a higher tier (prod read with stage write, for example) is refused unless the `TargetAccess` that grants the write sets `crossTarget: allow` and names the source tier. Output scanning (below) removes secrets before they reach the model, so a secret read in A cannot be written to B in clear through the model. Data that is not a secret (names, configuration) can still move. That limit is stated, not solved.

### 6. Names shown to the model

- Target names are DNS labels (lower case ASCII letters, digits, `-`). No Unicode, so no homoglyphs.
- A target name starts with its tier (`prod-`, `stage-`, `dev-`), checked by admission, so the model, the approver and the audit reader see the tier in the name.
- The controller refuses a target whose name is within edit distance 1 of another target of a different tier (`prod-eu` next to `dev-eu` is fine; `prod-eu1` next to `prod-eu` in another tier is not).
- Tool descriptions list each allowed target as `name (tier, type, description)` from the registry. The description is operator text, limited to 200 characters, and is shown as data.
- A target name that appears in tool output or in a user message has no power: the gate accepts only names in the grants. An approval request shows the target, tier and owner from the registry, never from the model's text.

### 7. Credential providers

A new adapter interface, `Credentials`, returns a short-lived credential for one target and one call. The core sees only the provider type and the target. Providers, in order of preference:

| Provider | How it works | Where it fits | Limits |
|---|---|---|---|
| a. `inCluster` | A projected ServiceAccount token of the instance's own ServiceAccount, audience the API server, `expirationSeconds` 600 to 3600, refreshed by the kubelet. A kubeconfig is built as a file with `tokenFile:` pointing at the projected path, so it holds no secret. `automountServiceAccountToken: false` | The home cluster | Works only in the cluster that issued the token |
| b. `federation` | A projected token of the instance's ServiceAccount with the **target's own audience**, exchanged at the target: AWS `AssumeRoleWithWebIdentity` (the IRSA pattern; works from any cluster whose issuer AWS can read), EKS Pod Identity when the instance runs on EKS, GKE Workload Identity or Workload Identity Federation, Azure federated credentials; or presented directly to a remote API server that trusts the home issuer | Remote clusters and cloud accounts | The target must be able to read the home issuer's keys (see below). Set up on the target side |
| c. `broker` | A secret broker issues a dynamic credential per request: Vault dynamic AWS or Kubernetes secrets engines, or a cloud secret manager through External Secrets or the Secrets Store CSI driver. The instance authenticates to the broker with its own projected token | Where federation is not possible and a broker already exists | Another component to trust; through External Secrets the result lands in a Secret, which the kubelet mounts and the controller never reads |
| d. `secretRef` | A static credential (a remote kubeconfig with a bound token, a cloud key) in a Secret, mounted by `secretKeyRef` or a file, read by the kubelet | Last resort; laptops, air-gapped targets | Long-lived. Discouraged. Status says so (`CredentialValid` reason `StaticCredential`). Rotation is the owner's job: a new Secret version rolls the instance (fingerprint annotation, as ADR 0015 does for keys) |

Rules for every provider:

- The controller never reads a Secret, a token or a credential. It never writes a credential into a spec, a status, an event, an env value, an argument or a log.
- **The issuer must be readable by the target.** For federation, the target fetches the home cluster's discovery document and keys. On a cloud-managed home cluster this is public already. On kind, k3s on a laptop, or a private cluster, it is not: the options are to publish the discovery document and keys in a public bucket (and set the API server's issuer and key URL to match, which changes every token the cluster issues), to upload the keys to the target where it allows it (Google, at most 8 keys, by hand on rotation), or to use a broker or a pull-model runner instead. The platform reports which applies; it does not publish keys by itself.
- **Who acted, in the target's audit.** The federated subject is the instance's ServiceAccount (`system:serviceaccount:<tools namespace>:<instance>`), so the target's audit names the profile, which is a verified fact. Where the target accepts a session name or tags (AWS `RoleSessionName`, session tags), the gate sets them to the agent and run it was told by the vMCP. That part is information, not proof: the instance cannot prove which agent called it (*unverified* whether ToolHive forwards the caller's identity to a backend at all). Strict per-agent attribution needs one instance per agent, or identity per agent (#13).
- **Fallbacks are off.** Cloud SDKs try a chain of sources (environment, files, instance metadata). The instance is configured to use exactly the named provider. A failure is an error, never a silent fall back to the node's role through the metadata endpoint. How to pin each SDK's chain is listed per provider in the slice that builds it (*unverified* for the Azure and Google SDKs).

### 8. Remote Kubernetes clusters

In order of preference:

1. **External OIDC trust.** The remote API server trusts the home cluster's ServiceAccount issuer through structured authentication configuration (stable in 1.34): issuer URL, audience `openagentix:<target>`, a claim validation rule that allows only the instance ServiceAccounts, and a claim mapping to a user name such as `openagentix:<profile>` and a group `openagentix:tools`. The remote RBAC binds that user or group. The token is presented directly; no exchange. Needs control over the remote API server's configuration file. Self-managed clusters have it. On managed clusters, a similar feature exists in other forms (an OIDC identity provider association on EKS; an external identity provider page for AKS was found, status *unverified*; GKE *not checked*).
2. **Cloud identity, then cloud cluster auth (two hops).** For EKS, GKE and AKS: federation to the cloud (provider b), then the cloud's own cluster authentication (EKS access entries, GKE IAM, AKS with Entra ID), then the remote RBAC. Each hop is its own boundary and its own audit.
3. **Bound-token kubeconfig (fallback, provider d).** A token made in the remote cluster for a dedicated ServiceAccount there, stored in a Secret at home. Long-lived if made with a long duration; rotate with a job on the remote side.
4. **Pull-model runner (later).** For private API servers that nothing can reach: a small runner inside the target cluster, with its own in-cluster identity, connects outward to the home platform, like the Argo CD Agent hub and spoke design. The home side then needs an inbound endpoint, and the runner becomes the remote end of the target gate. New code with its own security review. Not designed here.

**Network reachability.** The tool server needs a route to the remote API server or cloud endpoint: public endpoint, VPN, peering or a private link. The tools namespace NetworkPolicy gets egress only to the endpoints of the targets its instances serve, and nothing else. Container agents never get this route; their egress stays as ADR 0015 and ADR 0020 decide.

### 9. Remote cloud accounts and scale

- **One account, one target.** Each account (or project, or subscription) is a target with its own role.
- **Many accounts without hand-written entries.** A target generator creates `ToolTarget` objects from an inventory: for AWS Organizations, one standard role name in every member account, assumed from a hub role; for Google, projects under a folder; for Azure, subscriptions in a management group. Generated targets carry a label naming the generator and are read-only unless a `TargetAccess` grants more. The generator is an operator-run job in the first slices, not a controller.
- **The hub role is the one shared piece.** In the AWS hub pattern, one federated hub session can assume many account roles. The hub role must have only `sts:AssumeRole` (and `sts:TagSession`) on the standard role pattern, and nothing else. A production hub is separate from the non-production hub, so a stolen non-production session cannot reach production. The per-account credential is still per target and short-lived (role chaining limits a chained session to one hour).
- **Limits.** At most 200 targets per instance and 1,000 per installation in the first version (starting values); the rate caps of the tier table per target; one STS call per target per credential lifetime at most.

### 10. Read-only by default, mutations, arguments, approval

- **Read-only on three layers.** The remote role is read-only (for Kubernetes, a RoleBinding to the built-in `view` ClusterRole in the listed namespaces, which excludes Secrets and `pods/exec`); the adopted server runs in its read-only mode; the profile's tool filter lists only read tools. The first layer is the boundary; the others reduce noise and the chance of a confusing error.
- **Mutation allowlists.** `access: write` in a `TargetAccess` needs a rule list: verbs, resources (group and kind) and namespaces for Kubernetes; actions and resource patterns for clouds. The gate checks each call against it before the tool runs; the remote role must match it. The render and the controller refuse rules that are an escalation path: `*` in verbs or resources, Secrets, `pods/exec`, `pods/attach`, `pods/portforward`, `serviceaccounts/token`, `nodes/proxy`, `impersonate`, `bind`, `escalate`, RBAC resources, admission webhooks and policies, CRDs, and cluster-scoped writes. Creating Pods or workloads in a namespace gives the power of every ServiceAccount in that namespace, and the rule list must say so in status (a warning reason).
- **Argument policy.** Arguments are structured and typed. Rules (Cedar where ToolHive can see arguments, otherwise in the gate) match on target, namespace, kind, name pattern and verb. No free-form command argument is accepted.
- **No raw shell.** Tools that take a command line (`kubectl_generic`, `call_aws` with a free command, a `gcloud` passthrough, `exec_in_pod`) are refused in an infrastructure profile. A CLI wrapper, where one is written, builds `argv` from typed fields, never through a shell, puts `--` before user values, and sets `--server`, `--token`, `--kubeconfig`, `--context`, `--as`, `--profile`, `--region` and similar flags itself. A user value that starts with `-` is refused. Pipes, redirects and globbing do not exist because there is no shell.
- **Approval.** A mutation that needs approval creates an `ApprovalRequest` (ADR 0012, #12) that shows the target, tier, owner, tool and the structured arguments (secrets masked). The call waits or fails with a clear reason until it is decided. Approval is enforced in the gate, not in the agent loop, because `bash` and code mode can call the tool directly. One approver is community; routing and escalation are the enterprise part (ADR 0010). Until `ApprovalRequest` exists, mutations are available only on `dev` targets with an explicit `access: write`.

### 11. Acting as the agent, not as the user

- **Now: the tool server's own identity** (option J), per profile and target. The calling user's id goes into the audit line as information.
- **Impersonation is not used.** The `impersonate` verb would make the tool server as strong as every user it may name, and the user id it would impersonate is not verified for most callers (chat ids, schedules). Constrained impersonation (beta in 1.36) narrows the verb but not the second problem. Revisit when both a verified user and 1.36 clusters are common.
- **Later: on behalf of a user by token exchange** (option L), in the identity adapter (#13). The rule then: the call has the intersection of the profile's grants and the user's own rights at the target, and the target sees the user. No token passthrough. Whether a Kubernetes on-behalf-of path is community (it is a security control) or part of the enterprise "brokers for many providers" row of ADR 0010 is an open question for the owner.
- **Delegation** (#23): a delegated run keeps the caller's narrower target set. An agent called by another agent never gains targets.

### 12. Isolation and multi-tenancy

- One tool server instance serves one profile and holds one home ServiceAccount. Instances never share a ServiceAccount, a Secret or a cache.
- Production targets get a dedicated instance with its own home identity. Reason: a bug or a takeover in an instance then reaches only one tier, and the prod rate caps and approval cannot be starved by dev traffic. Cost: one more pod (memory *unverified*, about 30 to 60 MiB expected for a Go server). Recommended default; a single instance for all tiers is refused for `prod`.
- Inside one profile every agent acts the same. That is the limit of ADR 0019 as well.
- The tools namespace becomes sensitive. Whoever can create pods, exec into pods or create tokens there gets an instance's identity. Admission policies (below) limit pod creation with an instance ServiceAccount to the ToolHive operator with the pinned image, and token requests for those ServiceAccounts to the kubelet, as ADR 0019 does for the workload namespace.

### 13. Audit, output limits and secret scanning

- **One audit line per call and target**, written by the gate: time, profile, instance, target, tier, tool, verb, resource kind, namespace and name, outcome, duration, output size, number of redactions, approval reference, the caller subject and user id as received, trace id. Argument **values** are recorded only for a fixed list of non-secret fields (target, namespace, kind, name, verb); other values are recorded as a hash. Never a credential, never content.
- **The target's own audit is the second record**: Kubernetes API audit logs (if the target owner enables them) show the mapped user; cloud audit logs show the role session. The gate sends a request id where the target accepts one, so both records can be joined (*unverified* for each target type).
- **Output limits.** At most 64 KiB per call and 256 KiB per fan-out by default, truncated with a marker. Pod logs and events are excluded from the first read profile: they are large, contain user data and are a common place for injected instructions.
- **Secret scanning before output returns to the model.** The gate removes Secret objects entirely (they should already be refused by RBAC), and replaces high-confidence patterns (private key blocks, JWTs, cloud access key formats, kubeconfig `token:` and `client-key-data:` fields, `password=` style pairs) with a marker. The count goes into the audit line. Output is marked as data in the tool result, like the kb and notify results today. Scanning reduces leaks; it does not prove there are none.

### 14. Build or adopt

- **Kubernetes: adopt containers/kubernetes-mcp-server** (Apache-2.0, Red Hat maintainers, Go client without shelling out, `read_only`, `disable_destructive`, toolsets, `denied_resources`, in-cluster mode). Configured with `cluster_auth_mode` set to its own identity, never passthrough; toolset `core` only at first. Its release cadence and version are *read again before pinning*. Flux159/mcp-server-kubernetes is not adopted (shells out, repeated injection advisories). kagent-tools is not used for this (shells out, one read-only switch, the guard already refuses kagent's tool server).
- **Helm: not in the first slices.** Helm stores release state in Secrets of the release namespace, so even `helm list` needs read access to Secrets there, which breaks the read-only boundary. Helm comes after a decision on that (open question).
- **Clouds: later, one at a time.** Candidates: awslabs `aws-api-mcp-server` with `READ_OPERATIONS_ONLY` and its deny list (its `call_aws` free command is refused, so only if structured tools are enough; *unverified*), awslabs `eks-mcp-server` (read-only by default); Azure MCP Server (MIT, SDK, `--read-only`, workload identity through the Azure SDK). Google's local servers are preview or experimental; Google's and AWS's managed remote servers act as the caller's cloud identity and run outside the cluster, so they are a separate path through egress, not a tool server we run.
- **Our own code is the target gate**, which every option needs, and a CLI wrapper only where no structured server fits. Images are pinned by digest and verified per ADR 0018. A new server image is an operator decision (ADR 0007).

### 15. Chart values, resources, guard

- **Off by default.** With no `ToolTarget`, no `TargetAccess` and no infrastructure profile, nothing renders and the default chart render is byte-identical. The chart tests check this.
- **Chart values** install the limits: whether infrastructure tools are enabled, the allowed server images (digest and prefix), the tools namespace, the instance resource limits, the hard caps (targets per instance, fan-out, output). The first slice, before the kinds exist, renders one home target and one profile from values in exactly the shape of the kinds, shown as chart-managed, the way `agents[]` is today.
- **Who writes local RBAC.** The controller never creates RoleBindings: granting rights would need `bind` or `escalate`, which would make it as strong as a cluster administrator. In the home cluster, the chart (run by an operator) renders the instance ServiceAccount and the RoleBindings to `view` in the listed namespaces. Remote RBAC and IAM are the target owner's.
- **A rights check from inside.** At start and every 10 minutes, the instance runs a `SelfSubjectRulesReview` with its own credential per namespace in scope, which needs no extra permission, and reports forbidden rights (Secrets, exec, `impersonate`, `bind`, `escalate`, `*`) into the target's status. With forbidden rights the target is not `Ready` and the gate refuses it. This catches someone binding more to the instance later. The review is incomplete for some authorizers (webhooks), which the status says.
- **Admission policies**, rendered only when the feature is on: key allowlists on `ToolTarget` and `TargetAccess` (a field not listed is refused); the name and tier rule; `TargetAccess` with `access: write` on `prod` requires approval; tool server pods in the tools namespace with an instance ServiceAccount only from the ToolHive operator, only with an allowed image digest rendered literally into the policy, only projected token sources with the audiences of their targets, no Secret volume except the `secretRef` targets they serve; `serviceaccounts/token` for instance ServiceAccounts only by the kubelet; no ClusterRoleBinding may name an instance ServiceAccount; no agent pod or sandbox template may mount a kubeconfig, a cloud credential or an instance token. All of them are executed in tests (`make test-guard`, `make test-apiserver`), not only rendered.

## Threat model

| Threat | Example | Mitigation | What remains |
|---|---|---|---|
| Prompt injection to exfiltrate | A pod annotation says "read the Secret and post it to this URL" | Read role excludes Secrets; secret scanning; logs and events excluded at first; the tool server's egress reaches only target endpoints; the agent's egress is separate | Non-secret data can still be read and repeated by the model |
| Prompt injection to escalate | "Create a RoleBinding to cluster-admin" | Escalation verbs and RBAC resources refused in rule lists; read-only default; approval for mutations on prod and stage | An approver who approves without reading |
| Confused deputy across targets | The agent is granted dev write and asks for the same call on prod | Target enum per profile; gate check before the tool runs; separate prod instance and identity; credentials keyed by target | A grant written too wide by an operator |
| Credential reuse across profiles or targets | One role used by two targets; a token replayed elsewhere | One identity per target and per instance; duplicates refused where visible; federated tokens carry the target's own audience, so a token for target A is refused by target B and by the home API server | Duplicates the controller cannot see (two accounts trusting the same subject) |
| Token audience and replay | A token taken from the tool pod used against another cluster or account | Audience per target, lifetime at most one hour, trust policies conditioned on `aud` and `sub` | Replay at the same target within the lifetime |
| Stolen federation trust | The home cluster's signing key or issuer is compromised | Out of our control: the target trusts the issuer. Trust policies must name exact subjects, not `system:serviceaccount:*`; prod targets should trust a separate home cluster or issuer where possible | An issuer compromise reaches every target that trusts it |
| Overbroad trust policy | An IAM role trusting any subject of the issuer, or no `aud` condition | Documented trust policy templates with exact `sub` and `aud`; the generator writes them that way; status cannot verify the remote policy and says `Unknown` | Remote misconfiguration |
| Argument injection | `--server=https://attacker` makes `kubectl` send its token away (the class of CVE-2026-47250) | Typed arguments, no free command, `--` before values, values starting with `-` refused, connection flags set by the wrapper | Bugs in the adopted server; pin and update |
| Output injection | Tool output contains instructions | Output marked as data, size caps, risky sources excluded at first | Not solved in general |
| SSRF to metadata endpoints | A tool that fetches a URL (a Helm repo, a webhook) asks `169.254.169.254` for the node's credentials | NetworkPolicy egress of the tools namespace only to target endpoints; IMDSv2 with hop limit 1 recommended on AWS nodes; SDK chains pinned to the named provider. On GKE the metadata server is the Workload Identity path and is allowed only there | Clusters that do not enforce NetworkPolicy (kindnet toward the internet) |
| Supply chain of the tool image | A compromised server image runs with a cluster identity | Digest pinning, signature verification (ADR 0018), operator approval of each image, admission policy with the literal digest | A signed but vulnerable version |
| Misuse inside the tools namespace | Someone with `pods/exec` there reads the instance token | Admission policies on pods and token requests; document that exec rights in the tools namespace equal the instances' rights | Cluster administrators are trusted |
| Rights added later | A namespace admin binds more to the instance ServiceAccount | Rights check from inside, every 10 minutes; target not Ready with forbidden rights | A 10 minute window; authorizers the review cannot see |

### Failure modes

| Failure | Behaviour |
|---|---|
| Target unreachable | The call fails with `unreachable`; `Reachable=False`; no retry with another target |
| Credential fetch fails or expires | The call fails with `credential`; `CredentialValid=False`; no fall back to another source |
| Rules file missing or malformed | The gate serves no target (fails closed) |
| Approval not decided in time | The call fails with `approval expired`; nothing is changed |
| Fan-out partly fails | Partial result with the failed targets named |
| Rate cap reached | The call fails with `rate limited` and the time to wait |
| Rights check finds forbidden rights | Target not Ready; calls refused until fixed |
| Adopted server crashes | The vMCP reports the backend down; no other instance takes over its targets |

## Alternatives rejected

| Alternative | Why not |
|---|---|
| A shell in the agent sandbox with a kubeconfig | The credential sits in the component that reads untrusted text; `bash` bypasses the agent loop; every flag is open |
| A credential-injecting egress proxy | Needs TLS interception and a CA in the agent; ADR 0020 decided never to decrypt; the agent still chooses each request. Not in 0.3; may be revisited with `CredentialGrant` for plain API hosts |
| A sidecar per agent with the credential | Same pod, same trust domain; not possible for Substrate sandboxes; more pods than one server per profile |
| Fields on the tool profile for targets | Duplicated endpoints and trust, no status per target, the profile editor would decide where it reaches |
| Reusing `CredentialGrant` for targets | Different subject (a tool server, not an agent or a run) and a different injection point (the tool server, not the egress proxy) |
| The controller writes RoleBindings | Needs `bind` or `escalate`; the controller would become as strong as a cluster administrator |
| Kubernetes impersonation now | `impersonate` is too strong, and the user id is not verified |
| Token passthrough to the API server | Forbidden by the MCP authorization specification; the token is the agent's, with the wrong audience |
| Free-form command tools | Argument injection; no structured policy |
| Our own Kubernetes MCP server first | A maintained Apache-2.0 server exists; our code is limited to the gate |
| A hidden current context per session | Calls would depend on earlier calls; a target switch by injection would be invisible |

## Relation to other records and issues

| Item | Relation |
|---|---|
| ADR 0006 (tool profiles) | Extends: an infrastructure profile gets its own group, not the shared one |
| ADR 0007 (`ToolServer`, `ToolProfile`) | Depends on: those kinds are built first or with this; `ToolTarget` and `TargetAccess` are added to its list of planned kinds |
| ADR 0010 (editions) | Follows: tier policy, approval by one approver, targets and audit are community; routing of approvals is enterprise; the on-behalf-of row is an open question |
| ADR 0012, #14 `CredentialGrant` | Overlaps in purpose, not in shape. A grant gives an agent or a run a credential at the egress proxy for one host. A target gives a tool server a place to act and a provider for its credential. The `Credentials` adapter of this record is the one both use: `CredentialGrant` sources and `ToolTarget` providers are the same list. This record does not change the grant's shape |
| ADR 0012, #12 `ApprovalRequest` | Depends on: mutations on prod and stage need it; enforced in the gate |
| ADR 0012, #20 `Workspace` and execution environments | Sets a rule for it: an execution environment with a shell gets no cluster or cloud credential |
| #13 identity per agent | Depends on for strict per-agent attribution and on-behalf-of-user calls |
| #23 delegation | A delegated run keeps the narrower target set |
| ADR 0016, #3 `AgentAccess` | `TargetAccess` reuses its pattern (one subject, deny by default, controller-written rules file, reload) |
| ADR 0018 | Tool images are signed and verified |
| ADR 0019 | Reuses projected tokens with per-profile audiences and the token request policy; container agents reach infrastructure profiles through the workload variant |
| ADR 0020 | The tool servers' egress is separate from the agents'; the agent proxy never decrypts |

## Consequences

- Agents can inspect, and later change, clusters and cloud accounts without holding a credential, with one reviewable chain from agent to remote role.
- The CLI question has a clear answer: CLIs behind MCP, in a tool server, with a gate. A shell in the agent stays for compute only.
- Harder or ruled out: an agent that runs `kubectl` itself with credentials; tools that take a free command; Helm until the Secret question is answered; acting as the calling user until #13.
- Security impact: a new kind of power in the platform (acting on infrastructure). It is off by default at four levels (chart switch, no target, no grant, no profile). The controller gains read access to two new kinds and the right to write one rules file per instance; it gains no RBAC on targets and reads no Secret. New outbound paths: from tool server pods to target endpoints only. New records: one audit line per call and target.
- Compatibility: none for existing users. The default render does not change. Existing profiles keep the shared group.
- Proof needed before this counts as done: chart tests (default render unchanged; a target renders the instance, its ServiceAccount, RoleBindings, group, vMCP and network rules), guard tests for each refusal, `make test-apiserver`, gate unit tests (missing target, unknown target, disabled target, a value starting with `-`, fan-out caps and partial failure, redaction with canary secrets that must not reach a log line, status or tool result), and a live proof per slice.

## Slices and test plan

Each slice is off by default, tested first, leaves the default render unchanged, and ends with a live proof, a review (security-relevant, so an independent one), a diary entry and a changelog line.

1. **Read-only Kubernetes, home cluster.** kubernetes-mcp-server pinned by digest, in its own group with one profile vMCP; instance ServiceAccount with a RoleBinding to `view` in one namespace; `inCluster` provider; `read_only`, toolset `core`, logs and events filtered out; the gate with the target argument (one target), audit line, output cap and secret scan. Live proof on k3s with the stub model: list pods in the granted namespace works; another namespace, a Secret and any mutation tool are refused; a call without a target is refused; a canary secret in a ConfigMap is redacted; the token cannot be requested by another pod in the tools namespace.
2. **Target registry.** `ToolTarget` and `TargetAccess` kinds, conditions, disable switch, the rights check from inside, name and tier rules, rules file reload.
3. **One federation path, proven live: Kubernetes to Kubernetes OIDC trust on two local clusters** (two kind or k3s clusters on one machine). Why this one first: no cloud account and no cost, so CI and contributors can run it; it tests the hard parts (per-target audience, issuer key access, claim mapping, remote RBAC as the boundary, replay refused at the wrong cluster and at the home API server); structured authentication is stable in 1.34. The remote cluster reads the home issuer's keys over the local network, using the public key binding of ADR 0019. AWS federation is the second path, because it needs a public issuer.
4. **Fan-out reads** across a target group, with caps and partial results.
5. **Mutations with approval** (after #12): rule lists, escalation refusals, approval in the gate.
6. **Cloud federation**, AWS first (IRSA pattern from a public issuer, hub and per-account roles, target generator), then Azure and Google.
7. **Credential-free sandbox shell** for compute (#20), with the guard rule that no credential can be mounted.
8. **Later:** broker provider, bound-token fallback, pull-model runner, on behalf of the user (#13), Helm.

## Not checked / open points

- Everything above is *unverified*: no part is built or run.
- *Unverified*: kubernetes-mcp-server behind a ToolHive vMCP; whether it can select a context per call; its memory; its exact version and release cadence.
- *Unverified*: whether ToolHive's Cedar authorizer sees tool arguments, and whether the vMCP forwards the caller's identity or `Authorization` header to a backend.
- *Unverified*: how each cloud SDK's credential chain is pinned to one source; whether Azure accepts a private issuer.
- *Unverified*: the managed-cluster forms of external OIDC trust (EKS, AKS, GKE); GKE was not checked.
- *Unverified*: the rules reload delay, and whether a target's audit accepts a request id we set.
- Facts to read again before quoting: every row of the appendix, the AWS issuer requirement, managed server status and dates.

### Open questions for the owner

1. Release: is the read-only Kubernetes slice wanted in 0.4, or earlier as an experiment behind a flag? (The trail on #14 says not in 0.3.)
2. Are unattended mutations ever allowed on `stage`, or does every stage mutation need an approval?
3. Helm: accept read access to Secrets in the release namespace for Helm tools, use a different storage driver, or leave Helm out?
4. Who may write `TargetAccess`: operators only, or target owners for their own targets once tenancy exists?
5. Is a Kubernetes on-behalf-of-user path community (a security control) or part of the enterprise broker row of ADR 0010?
6. Should managed remote cloud servers (AWS, Google) be supported as a separate path through egress, even though they act as the caller's cloud identity outside the cluster?
7. Is the pull-model runner for private clusters wanted, and when? It is new inbound surface.
8. Should agents with an infrastructure profile have `bash` turned off? Today the switch is controller-wide (ADR 0006).
9. Is one instance per profile and tier group the right cost, or should every target of `prod` get its own instance?

## Follow-up issues to create after acceptance

Not created yet. They are listed on the umbrella issue #141.

| Issue | Area | Depends on |
|---|---|---|
| Read-only Kubernetes tool server with a namespaced Role (home cluster, one target, gate, audit, output scan) | tools | ADR acceptance, `ToolServer` and `ToolProfile` shape (ADR 0007) |
| One federation path proven live: Kubernetes to Kubernetes OIDC trust on two local clusters | tools, governance | slice 1 |
| Target registry with status: `ToolTarget`, `TargetAccess`, conditions, disable switch, rights check | control-plane, tools | slice 1, ADR 0016 pattern |
| Fan-out reads across a target group | tools | registry |
| Sandbox shell without credentials for compute | runtime | #20 |
| Mutations with approval in the gate | tools, governance | #12 |
| Cloud federation, AWS first, with a target generator | tools | registry, #14 |

## Appendix: existing MCP servers

Read on 2026-11-26. Page summaries were made with a tool and some facts come from search results; anything marked uncertain must be read again before it is quoted.

| Server | Maintainer, licence | Read-only mode (default) | Credentials | Acting as the user | CLI or client | Maturity |
|---|---|---|---|---|---|---|
| [containers/kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server) | Red Hat maintainers, Apache-2.0 | `read_only`, `disable_destructive` in TOML (off); toolsets, `enabled_tools`, `disabled_tools`, `denied_resources` | kubeconfig or in-cluster; `cluster_auth_mode` defaults to passthrough | OAuth in HTTP mode, token exchange (`rfc8693`, `keycloak-v1`, `entra-obo`); no impersonation found | Go client | About 2.3k stars; version uncertain; Keycloak guide says preview |
| [Flux159/mcp-server-kubernetes](https://github.com/Flux159/mcp-server-kubernetes) | Community, MIT | `ALLOW_ONLY_READONLY_TOOLS`, `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS` (off) | `~/.kube/config` current context | None found | Shells out to `kubectl`, `helm` | About 1.6k stars; advisories CVE-2025-53355, CVE-2025-66404, CVE-2026-47250, CVE-2026-61459 ([OSV](https://osv.dev/vulnerability/CVE-2026-61459)) |
| [kagent-dev/tools](https://github.com/kagent-dev/tools) | kagent project, Apache-2.0 | `--read-only` (off) | Pod ServiceAccount or `KUBECONFIG` | None | Shells out to `kubectl`, `helm`, `istioctl`, `cilium` | Small; Go port |
| [awslabs aws-api-mcp-server](https://github.com/awslabs/mcp/tree/main/src/aws-api-mcp-server) | AWS Labs, Apache-2.0 | `READ_OPERATIONS_ONLY`, `REQUIRE_MUTATION_CONSENT` (off); deny and consent lists | Profile or the default credential chain | None; README says single customer | Runs AWS CLI commands (`call_aws`) | README says superseded by the managed AWS MCP Server |
| [awslabs eks-mcp-server](https://github.com/awslabs/mcp/tree/main/src/eks-mcp-server) | AWS Labs, licence likely Apache-2.0 (uncertain) | Read-only by default; `--allow-write`, `--allow-sensitive-data-access` | IAM (profile, needs an access entry) or kubeconfig | Only through a user kubeconfig | Python client | Version not found |
| [AWS MCP Server (managed)](https://aws.amazon.com/about-aws/whats-new/2026/05/aws-mcp-server/) | AWS, managed | A read-only mode is mentioned (how to enable: not found) | SigV4 through a local proxy, or OAuth | The caller's IAM identity | Managed | GA 2026-05-06 (search result) |
| [Azure MCP Server](https://github.com/microsoft/mcp) | Microsoft, MIT | `--read-only` (off; from mirrors of a beta reference, uncertain) | Azure Identity (managed identity, workload identity, service principal, `az login`) | Entra for remote use; on-behalf-of not found | SDK | About 3.9k stars; GA 2.0; 3.0 release blog dated 2026-10-14 (search result) |
| [Azure/aks-mcp](https://github.com/Azure/aks-mcp) | Microsoft Azure, MIT | `--access-level readonly`, `readwrite`, `admin` (readonly); "a guardrail, not a security boundary" | `az` CLI: service principal, workload identity, managed identity, `az login` | None found | Shells out to `az`, `kubectl`, `helm` | stdio only; about 150 stars |
| [googleapis/gcloud-mcp](https://github.com/googleapis/gcloud-mcp) | Google ("not an officially supported Google product"), Apache-2.0 | None; built-in deny list of commands | Active gcloud account; impersonation of a service account suggested | No | Runs `gcloud` | Preview |
| [GoogleCloudPlatform/gke-mcp](https://github.com/GoogleCloudPlatform/gke-mcp) | Google Cloud, Apache-2.0 | None found | Not stated | Not found | Not stated | "Experimental, not for production use" |
| [Managed GKE MCP](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/use-gke-mcp) | Google, managed | OAuth scope `container.read-only` or `container`; IAM deny on the read-only tool property | OAuth with IAM, no API keys | The caller's Google identity | Managed | Status on the page not stated |
| [giantswarm/mcp-kubernetes](https://pkg.go.dev/github.com/giantswarm/mcp-kubernetes) | Giant Swarm, licence not read | Not read | Admin credential with `impersonate` | `Impersonate-User` and `Impersonate-Group` (from a package listing) | Go client | Not assessed |
| [stacklok/toolhive](https://github.com/stacklok/toolhive) | Stacklok, Apache-2.0 | Not applicable (runner and gateway) | OIDC validation; token exchange with a client Secret | RFC 8693 exchange per server audience | Not applicable | In use here at v0.67.1 |

Other sources: [MCP authorization specification 2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization); [kubernetes-mcp-server configuration](https://raw.githubusercontent.com/containers/kubernetes-mcp-server/main/docs/configuration.md); [ToolHive MCPServer reference](https://docs.stacklok.com/toolhive/reference/crds/mcpserver); [KEP-3331](https://www.kubernetes.dev/resources/keps/3331/); [KEP-5284](https://www.kubernetes.dev/resources/keps/5284/); [Google Workload Identity Federation with other providers](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-other-providers); [Argo CD Agent terminology](https://argocd-agent.readthedocs.io/latest/concepts/components-terminology/); [AWS: IAM for managed MCP servers](https://aws.amazon.com/blogs/security/understanding-iam-for-managed-aws-mcp-servers).
