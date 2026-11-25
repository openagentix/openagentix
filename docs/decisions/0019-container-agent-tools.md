# ADR 0019: tools for container agents through a workload tool server

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/103 (umbrella #43)
Replaces: none. Fills in "Tools" of ADR 0015 (slice 3) and names the public pieces it left open.

A container agent may name a tool profile in `spec.toolProfile`. It then reaches only that profile's tools, at one URL, with a short-lived Kubernetes token for its own ServiceAccount. The operator opens a profile to container agents by name. Nothing changes unless the operator does.

## Context

ADR 0015 decided the shape: "each opted-in profile gets a second server that validates a projected Kubernetes ServiceAccount token with its own audience", restricted by three things together (only the controller creates pods in the workload namespace, the network admits only pods labelled for that profile, the policy language admits only subjects of that namespace). It also fixed the agent's contract: `OPENAGENTIX_MCP_URL` and a token read fresh from `OPENAGENTIX_MCP_TOKEN_FILE`. It left the chart values, the catalog fields, the pod label and the guard rules to this slice.

Facts read on 2026-11-26 in the ToolHive source at tag v0.67.1 (commit 2d33d6b, the version `components/tools/install.sh` installs):

- `MCPOIDCConfig` has a type `kubernetesServiceAccount` with `issuer`, `jwksUrl` and `useClusterAuth` (default true: the server's own CA file and token are used to fetch the keys). Its `serviceAccount` and `namespace` fields are **not used** by the resolver (`cmd/thv-operator/pkg/oidc/resolver.go`, `resolveFromK8sServiceAccountConfig`). So they restrict nothing, and the subject must be restricted by the Cedar policy.
- The Cedar authorizer exposes JWT claims as `context.claim_<name>` and uses `sub` as the principal (`pkg/authz/authorizers/cedar/core.go`). The policy below was run through that authorizer with Kubernetes-shaped claims (a test added in a local copy, not upstream): a pod-bound token of a subject of the workload namespace is allowed to list and call; subjects of `kagent`, `openagentix-system` and `openagentix-workloads-evil`, a token without a pod claim, and a token without the `kubernetes.io` claim are refused.
- The existing profile servers accept only Substrate actor tokens (one OIDC config per server).
- For a `VirtualMCPServer` the operator does not pass the token file to the server (`cmd/thv-operator/pkg/vmcpconfig/converter.go`, `mapResolvedOIDCToVmcpConfigFromRef` copies the CA path but not `JWKSAuthTokenPath`), so the vMCP fetches the signing keys without a token. The first end-to-end run (k3s, 2026-11-26) showed every token refused with HTTP 401 for that reason.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. A second server per opted-in profile, Kubernetes ServiceAccount tokens, a projected token in the pod | No Secret, no long-lived credential, the token is useless at the Kubernetes API (own audience) and at the other servers (own audience per profile) | One more server pod per opted-in profile | ToolHive source read; Cedar policy run through ToolHive's authorizer |
| B. A static key per agent at the profile server, in a Secret | One server per profile | ToolHive has no fitting mode; another long-lived secret (rejected in ADR 0015) | ADR 0015 |
| C. Open every profile to container agents automatically | Nothing for the operator to do | A profile meant for built-in agents becomes reachable from foreign code without a decision | not built |

## Decision

Option A, with an explicit opt-in per profile.

### Public names

- **Chart values.** `controlPlane.containerAgents.toolProfiles` (default `[]`): names of `mcp.profiles` that container agents may use. `controlPlane.containerAgents.serviceAccountTokens.issuer` (default `https://kubernetes.default.svc.cluster.local`, what kind and k3s report) and `.jwksUrl` (default `https://kubernetes.default.svc/openid/v1/jwks`). The render fails for a name that is not a profile, without `mcp.enabled`, or when a workload server name would collide with a profile server name.
- **Objects the chart renders** for each listed profile `P`, only when container agents are on: a `VirtualMCPServer` `<mcp.virtual.name>-P-workload` with the same tool filter and code mode as `P`, the audience `<mcp.virtual.incomingAuth.oidc.audience>-P-workload`, and the Cedar policy `permit(principal, action, resource) when { context.claim_sub like "system:serviceaccount:<workload namespace>:*" && context has "claim_kubernetes.io" && context["claim_kubernetes.io"] has pod };` (a token the kubelet made for a pod, not one made with `kubectl create token`). One shared `MCPOIDCConfig` `openagentix-workload-sa` of type `kubernetesServiceAccount`; `useClusterAuth` is true only when `jwksUrl` is the in-cluster API server (`kubernetes.default.svc[.cluster.local]`), so the server's own token and the cluster CA are never sent to another host. With `networkPolicy.enabled`, a NetworkPolicy that admits to that server's port only pods of the workload namespace labelled `openagentix.io/tool-profile: P`.
- **Catalog.** `tools.toolhive.profiles[].workload` = `{url, audience, namespace, podSelector, port}`, present only for listed profiles. The tools adapter turns it into the platform's `ToolProfile.Workload`; the core and the plan see no upstream word.
- **Pod label.** `openagentix.io/tool-profile: P` on the pod template of a container agent with a profile.
- **Pod contents.** Env `OPENAGENTIX_MCP_URL` (the server URL) and `OPENAGENTIX_MCP_TOKEN_FILE=/var/run/secrets/openagentix/mcp/token`. One projected volume `mcp-token` with a single `serviceAccountToken` source: the profile's audience, `expirationSeconds: 3600`, path `token`, mounted read-only at `/var/run/secrets/openagentix/mcp`. The kubelet writes and refreshes the token. `automountServiceAccountToken` stays false, so the pod still has no token the Kubernetes API accepts.
- **NetworkPolicy of the agent.** A third egress rule: the server's pods (namespace and pod selector from the catalog) on its port. Without a profile the policy is unchanged (two rules).

- **Public signing keys.** `controlPlane.containerAgents.serviceAccountTokens.anonymousKeys` (default true): with a `jwksUrl` at the in-cluster API server, a ClusterRoleBinding `openagentix-workload-sa-keys` binds the built-in ClusterRole `system:service-account-issuer-discovery` (the issuer's discovery document and public keys, nothing else) to `system:unauthenticated`. It needs anonymous authentication on the API server. With false, the operator makes the keys reachable another way.
- **Admission policies for the workload namespace**, rendered only when the list is not empty. They judge every user except the controller (whose writes the workload guard judges) and the cluster's own controllers in kube-system (which only copy templates judged here). `openagentix-workload-tool-identity`: no Pod, ReplicationController, Deployment, ReplicaSet, StatefulSet, DaemonSet, Job or CronJob there may carry the `openagentix.io/tool-profile` label or a projected ServiceAccount token. `openagentix-workload-token-request`: only the kubelet (`system:node:*`) may create `serviceaccounts/token` there. A cluster admin is refused too.

### Rules

- `toolProfile` on a container agent must name a defined profile, allowed by `policy.allowedProfiles`, and listed in `toolProfiles`. Otherwise the definition is refused with one sentence. `tools` stays refused: the agent gets every tool of the profile.
- `policy.requireToolProfile` does not apply to container agents. Tools are off unless the definition names a profile.
- The controller never reads or writes a Secret for this. Its Role does not change.
- The admission guard pins, for the controller's writes in the workload namespace: the pod label value to a listed profile; the volume, mount, audience, path and an expiry between 600 and 3600 seconds to that profile; the two env values to that profile's URL and the fixed file; and the third egress rule to one of the listed servers. Any other projected source (a ConfigMap, a Secret, the downward API) is refused.

## Consequences

- A container agent can use tools under the same profile boundary as a built-in agent, with an identity per agent, not a shared key.
- One more server pod per opted-in profile (memory cost on the 6 CPU, 8 GB node *unverified*).
- Security impact: a new way in to the tool backends, from foreign code. It is closed by default (empty list). The token is per agent, bound to its pod, lasts at most one hour, and its audience is valid only at one server. Any pod in the cluster can ask the kubelet for a token with that audience for its own ServiceAccount, so the Cedar rule on the namespace keeps other namespaces out. Inside the workload namespace the two admission policies keep the label, the projected token and token requests to the controller's pods. The network rule is a second layer only where the cluster enforces NetworkPolicy. There is no filtering below the profile.
- The cluster's public ServiceAccount signing keys become readable without a token (cluster-wide, read only). They are public keys; anyone who can reach the API server can then read them.
- Limits that remain: a token is not revoked when its agent is removed or its pod stops; the server accepts it until it expires (at most one hour, and the server does not check that the pod still exists). Where NetworkPolicy is not enforced, a token that leaves the pod (for example through the agent's own logs) can be used from elsewhere until then. The cluster's controllers in kube-system, node credentials and anyone who can change the admission policies are trusted. Every agent of the workload namespace that names a profile gets every tool of it; the server cannot tell two agents on the same profile apart.
- Compatibility: no change for existing users. A container agent without `toolProfile` renders byte for byte as before, and so does the chart with `toolProfiles` empty.
- Proof needed: policy and plan tests, golden output of the adapter with a profile, guard tests with the adapter's output and each denial, the API-server test, chart tests (empty list renders nothing new; a listed profile renders the server, the config, the network rule and the catalog entry), and an end-to-end run with the stub model.

## Not checked / open points

- Run on kind in CI (2026-11-26): ToolHive 0.67.1 accepted the agent's pod-bound token with the key binding of this record, and refused another audience and another namespace. On k3s the keys could not be fetched; that k3s turns off anonymous authentication is the likely reason, *unverified*.
- *Unverified*: OpenShift (container agents are refused there anyway) and managed clusters whose issuer is not the in-cluster URL. The issuer and key URL are values for that reason.
- The agent's NetworkPolicy and the server's ingress rule are not cross-checked by the guard (the guard sees one object at a time). A mismatch fails closed.
