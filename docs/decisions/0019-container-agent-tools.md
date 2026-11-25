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
- The Cedar authorizer exposes JWT claims as `context.claim_<name>` and uses `sub` as the principal (`pkg/authz/authorizers/cedar/core.go`). The policy below was run through that authorizer with Kubernetes-shaped claims (a test added in a local copy, not upstream): a subject of the workload namespace is allowed to list and call; subjects of `kagent`, `openagentix-system` and `openagentix-workloads-evil` are refused.
- The existing profile servers accept only Substrate actor tokens (one OIDC config per server).

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
- **Objects the chart renders** for each listed profile `P`, only when container agents are on: a `VirtualMCPServer` `<mcp.virtual.name>-P-workload` with the same tool filter and code mode as `P`, the audience `<mcp.virtual.incomingAuth.oidc.audience>-P-workload`, and the Cedar policy `permit(principal, action, resource) when { context.claim_sub like "system:serviceaccount:<workload namespace>:*" };`. One shared `MCPOIDCConfig` `openagentix-workload-sa` of type `kubernetesServiceAccount`. With `networkPolicy.enabled`, a NetworkPolicy that admits to that server's port only pods of the workload namespace labelled `openagentix.io/tool-profile: P`.
- **Catalog.** `tools.toolhive.profiles[].workload` = `{url, audience, namespace, podSelector, port}`, present only for listed profiles. The tools adapter turns it into the platform's `ToolProfile.Workload`; the core and the plan see no upstream word.
- **Pod label.** `openagentix.io/tool-profile: P` on the pod template of a container agent with a profile.
- **Pod contents.** Env `OPENAGENTIX_MCP_URL` (the server URL) and `OPENAGENTIX_MCP_TOKEN_FILE=/var/run/secrets/openagentix/mcp/token`. One projected volume `mcp-token` with a single `serviceAccountToken` source: the profile's audience, `expirationSeconds: 3600`, path `token`, mounted read-only at `/var/run/secrets/openagentix/mcp`. The kubelet writes and refreshes the token. `automountServiceAccountToken` stays false, so the pod still has no token the Kubernetes API accepts.
- **NetworkPolicy of the agent.** A third egress rule: the server's pods (namespace and pod selector from the catalog) on its port. Without a profile the policy is unchanged (two rules).

### Rules

- `toolProfile` on a container agent must name a defined profile, allowed by `policy.allowedProfiles`, and listed in `toolProfiles`. Otherwise the definition is refused with one sentence. `tools` stays refused: the agent gets every tool of the profile.
- `policy.requireToolProfile` does not apply to container agents. Tools are off unless the definition names a profile.
- The controller never reads or writes a Secret for this. Its Role does not change.
- The admission guard pins, for the controller's writes in the workload namespace: the pod label value to a listed profile; the volume, mount, audience, path and an expiry between 600 and 3600 seconds to that profile; the two env values to that profile's URL and the fixed file; and the third egress rule to one of the listed servers. Any other projected source (a ConfigMap, a Secret, the downward API) is refused.

## Consequences

- A container agent can use tools under the same profile boundary as a built-in agent, with an identity per agent, not a shared key.
- One more server pod per opted-in profile (memory cost on the 6 CPU, 8 GB node *unverified*).
- Security impact: a new way in to the tool backends, from foreign code. It is closed by default (empty list). The token is per agent, lasts at most one hour, and its audience is valid only at one server. Any pod in the cluster can ask the kubelet for a token with that audience for its own ServiceAccount, so the Cedar rule on the namespace is what keeps other namespaces out, and the guard plus Pod Security is what keeps other pods out of the workload namespace. The network rule is a second layer only where the cluster enforces NetworkPolicy. There is no filtering below the profile.
- Compatibility: no change for existing users. A container agent without `toolProfile` renders byte for byte as before, and so does the chart with `toolProfiles` empty.
- Proof needed: policy and plan tests, golden output of the adapter with a profile, guard tests with the adapter's output and each denial, the API-server test, chart tests (empty list renders nothing new; a listed profile renders the server, the config, the network rule and the catalog entry), and an end-to-end run with the stub model.

## Not checked / open points

- *Unverified* on a cluster at the time of writing: that ToolHive 0.67.1 accepts the token (issuer, keys fetched from the API server with the server's own token, audience) and that the default RBAC binding `system:service-account-issuer-discovery` lets the server read the key set. The end-to-end job is the first place this runs; the pull request says what it showed.
- *Unverified*: OpenShift (container agents are refused there anyway) and managed clusters whose issuer is not the in-cluster URL. The issuer and key URL are values for that reason.
- The agent's NetworkPolicy and the server's ingress rule are not cross-checked by the guard (the guard sees one object at a time). A mismatch fails closed.
