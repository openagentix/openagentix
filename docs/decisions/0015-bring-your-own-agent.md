# ADR 0015: bring your own agent

Status: Accepted (2026-11-25). Release 0.3.
Date: 2026-11-25
Issue: #43
Replaces: none. Amends ADR 0007 and `docs/api-conventions.md` in one narrow way (see "Amendments").

A user can hand the platform a container image that speaks A2A. The platform runs it in a locked-down namespace and governs it: its own model key and budget, calls only through the A2A gate, tools only through a profile. It is less isolated than the built-in runtime, and this record says so.

## Context

ADR 0013 chose one focus: govern agents, whoever built them. "Bring your own agent" is the second half of that. Today an `AgentDefinition` always means "the platform builds an agent from instructions" on kagent and Agent Substrate (ADR 0007). A team that already has an agent in Go, Python or another framework cannot use the control plane, the gateway budgets or the gate.

Facts this record rests on, read on 2026-11-25:

- The A2A gate has one upstream (the kagent controller) and reads its rules once at start (`services/a2a-gate/internal/gate/gate.go`).
- The profile tool servers accept only a Substrate actor token. A container agent has none.
- On kind, kindnet enforces network policy toward cluster destinations but not toward the internet (`docs/diary/timeline.md` line 73, `docs/diary/what-works.md` line 56).
- ToolHive's `VirtualMCPServer` takes one OIDC config reference, so one server cannot accept two token issuers (ToolHive clone at commit 2d33d6b).
- `docs/api-conventions.md` says a spec names no image. ADR 0007 says there is no field for a harness or image.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `runtime.type: container`, the platform runs the image itself | The platform owns the pod, so it can guarantee non-root, no API token, the key, the network rules and the identity | A new adapter, a workload namespace, more guard rules, one image field in the spec | Design study of `main`, the ToolHive clone and the live kind cluster (read only) |
| B. `runtime.type: external` with `targetRef` to a workload the user runs | No image field, no new namespace | The platform cannot guarantee the key mount, the pod settings, the network rules or the identity without a mutating webhook on someone else's workload, and the controller would need write access to arbitrary Deployments | Compared with the Rossoctl `AgentRuntime` pattern (public docs) |
| C. Run the image as a `Sandbox` from kubernetes-sigs/agent-sandbox | Stronger isolation where a RuntimeClass exists | One more operator in the install; the isolation gain comes from a RuntimeClass, which a plain Deployment can use too | README read only |
| D. Do nothing | Nothing to build | The platform stays a builder for one kind of agent | not applicable |

## Decision

Option A.

### What it is

- An `AgentDefinition` gets an optional `spec.runtime` block. `type` is `builtin` (default, today's behaviour) or `container`. The word is a platform word. A later `external` or `sandbox` value can be added without breaking anyone.
- With `type: container` the controller runs the image itself. It writes a Deployment (one replica at most), a Service, a ServiceAccount, a NetworkPolicy and the agent's own gateway key Secret. All of them live in a separate workload namespace, `openagentix-workloads` (chart value `controlPlane.containerAgents.namespace`). That namespace carries Pod Security `restricted` and a default-deny network policy. Definitions stay in `kagent`.
- The platform does **not** enrol a workload the user runs (`targetRef`) in 0.3. Reason: it could not guarantee the key, the pod settings, the egress rules or the identity. Those guarantees are the point of the feature. `external` becomes sensible once the identity adapter (0.4, ADR 0013) exists.

### Resource shape

```yaml
spec:
  model: quickstart-model
  runtime:
    type: container
    container:
      image: ghcr.io/example/echo-go@sha256:<64 hex>   # digest required, matched against an operator allowlist
      port: 8080                                       # 1024..65535
      env: [{name: LOG_LEVEL, value: info}]            # plain values only, at most 32
      resources: {requests: {...}, limits: {...}}      # defaults and ceilings come from policy
```

There is no `args`, `command`, `volumes`, `securityContext`, `serviceAccountName`, `imagePullSecrets`, `envFrom` or `valueFrom`. Each is a way to reach around the platform. Private registries are therefore out of scope for now.

Which existing fields apply:

| Field | Container agent | Why |
|---|---|---|
| `model` | Required. Passed to the agent as `OPENAGENTIX_MODEL` | The gateway must know which model the key may use |
| `description`, `suspend` | Supported | Suspend sets replicas to 0 and removes the key at the gateway |
| `toolProfile` | Refused until slice 3 ("not available yet for container agents") | Needs the workload tool server |
| `egress.allow` | Must be empty until slice 5 ("not available yet for container agents") | Plain network policy has no host names |
| `instructions`, `instructionsFrom` | Refused | The platform cannot make a foreign agent obey a prompt. An env var would look like a control and not be one |
| `tools` | Refused | The platform cannot filter below the profile for a foreign caller. The agent gets the whole profile; make a narrower profile |
| `memory`, `knowledge`, `notify`, `skills` | Refused ("not available for container agents") | These are kagent features |

Validation rules (the controller is the authority; the admission policy mirrors the simple ones):

- `runtime.type` must be in the policy's `allowedRuntimes` and in the catalog.
- The image matches a digest-only pattern (no tag next to the digest) and starts with one of `runtimes.container.images`, a list of registry prefixes that is empty by default.
- `env` names are upper case, never start with `OPENAGENTIX_`, `OPENAI_`, `OTEL_` or `KUBERNETES_`, and values pass the same secret scan as instructions. A secret belongs in a credential grant (0.4).
- Resources never exceed the policy ceiling. Container agents count against `maxAgents`.

Status: `status.endpoint` is the gate URL for the agent. The pod's own Service address is never published, so calling around the gate is not the easy path. Capabilities are stated plainly: approvals, durable waits and cancel are `unknown`; workspace persistence is `none`; per-run identity is `none`. A new optional field `isolation` says `container`, or `sandboxed-pod` when a RuntimeClass is set. The kagent adapter reports `sandbox-per-session`. Adding the field is additive.

### Public names decided now (slice 1)

- Chart switch `controlPlane.containerAgents.enabled`, default false. With it false nothing new renders: no namespace, no roles, no guard policies, no gate change.
- Policy keys `allowedRuntimes` (default `[builtin]`) and `runtimes.container.{images, defaultResources, maxResources, maxAgents}`.
- Catalog: `adapters.runtimes` (a map from runtime type to adapter) and `runtime.container`. `adapters.runtime` stays, so an old catalog still validates. The catalog lists `container` only when the chart switch is on.
- Gate: environment variable `A2A_GATE_ROUTES_FILE`, and a ConfigMap `a2a-gate-routes` with one file, `routes.json`.
- Sample: `examples/agents/echo-a2a`. (The repository uses `examples/`, not `samples/`.)

### Governance

**Model access.** The core already creates a key Secret with a create call and never reads it. For a container agent the Secret is created in the workload namespace, because a pod can only use Secrets of its own namespace. The Deployment reads it through `secretKeyRef` as `OPENAI_API_KEY`, and sets `OPENAI_BASE_URL` and `OPENAGENTIX_MODEL`. The kubelet reads the Secret. The controller never does. The gateway user is `<namespace>.<name>`, so budgets and cost history work as before. When the key is replaced, a fingerprint annotation on the pod template rolls the Deployment. Suspend removes the key hash at the gateway, so a leaked key is useless while the agent is stopped.

The agent holds no provider credential. Its only key works only at the gateway, under its own budget. That holds on every cluster.

**Tools.** Only through a tool profile, in slice 3. The profile servers accept only Substrate tokens, so each opted-in profile gets a second server that validates a projected Kubernetes ServiceAccount token with its own audience. The issuer is set explicitly, because ToolHive's default does not match what kind reports. Access is restricted by three things together: only the controller creates pods in the workload namespace, the network admits only pods labelled for that profile, and the policy language admits only subjects of that namespace. There is no filtering below the profile. This is why `tools` is refused.

**Outbound access.** In 0.3 a container agent may reach only DNS, the model gateway and (slice 3) its profile server. `egress.allow` must be empty. Per-agent allowlists come in slice 5 through a small platform forward proxy, one port per agent. CNI-specific host policies may follow as an adapter option.

**Who may call it.** The A2A gate. The controller writes a route list, `{"container": ["kagent/echo-go", ...]}`, and nothing else, into the ConfigMap `a2a-gate-routes`. The gate reloads it when the file changes. The route list carries no URL. For a listed agent the gate builds the upstream itself from a template fixed by the chart at start: `http://<name>.<workload namespace>.svc.cluster.local:8080`. The name has already passed the gate's name check. So a compromised controller or ConfigMap can only choose which listed agent goes to the workload namespace, never an arbitrary host. Unlisted agents go to kagent as today. Caller rules, header stripping, the `X-User-Id` header and body limits are unchanged. The foreign agent gets `X-User-Id` as information, not proof. The gate also rewrites the agent card (at most 64 KiB, JSON only) so that clients are told the gate address and not the pod address.

### Isolation, stated honestly

A container agent is **less isolated** than a built-in kagent agent. Please read this list before you enable the feature.

- It shares the node kernel, unless an operator sets a RuntimeClass (for example gVisor). Agent Substrate runs each session in gVisor.
- It is one long-lived process for all conversations. One user's data can leak into another user's answer through the agent's own memory.
- It has one identity per agent, not one per session.
- Its outbound traffic is controlled only by NetworkPolicy. Kind's kindnet does not enforce that toward the internet. On kind, a container agent can reach any internet host. The platform cannot detect the network plugin reliably, so status does not claim otherwise. The README and the console must say so.
- It has no persistent files. `/tmp` is an `emptyDir` and is lost on restart.

What the platform does enforce: non-root user 65532, `RuntimeDefault` seccomp, no privilege escalation, read-only root file system, all capabilities dropped, no service account token mounted, no host namespaces or paths, one container, no init containers, limits always set, one replica at most, and readiness and liveness probes on the agent card. The `allowedRuntimes` switch (default `[builtin]`) is how an operator forbids or allows container agents. Later, scoped policy (0.5) can allow them per namespace, and a `requireIsolation` rule can demand `sandboxed-pod`.

### Admission guard and RBAC

The controller gets namespaced roles only. No ClusterRole, no wildcard.

| Where | Resources | Verbs |
|---|---|---|
| Workload namespace | `deployments`, `services`, `serviceaccounts`, `networkpolicies` | get, list, create, patch, delete |
| Workload namespace | `secrets` | **create and delete only**. Never get, list or watch |
| Gate namespace | `configmaps`, resource name `a2a-gate-routes` only | get, patch |

There is no read access to pods, no `pods/log` and no `pods/exec`. Readiness comes from Deployment status. That costs some detail in the `RuntimeNotReady` message. This is accepted.

Admission policies are allowlists at every level, bound to the controller's identity, and fail closed. They cover Deployments (key sets at each level equal to what the adapter writes; the image must match the digest pattern and one of the operator's prefixes, rendered literally into the policy so a compromised controller cannot run an image the operator did not allow; the security settings above exactly; only an `emptyDir` at `/tmp` and, in slice 3, one projected token with a fixed audience pattern and an expiry of at most one hour), Services (ClusterIP, one port, no external addresses), ServiceAccounts (no secrets, no token mount), NetworkPolicies (ingress only from the gate pods; egress only to DNS, the gateway and the profile server; no `ipBlock` and no empty peer), Secrets (same name suffix and label, create and delete only) and the route ConfigMap (one key, content must match a strict pattern). Pod Security `restricted` on the namespace is a second, independent layer. Because owner references cannot cross namespaces, the core's finalizer deletes the workload objects by label before it removes the key hash.

### Conformance contract

A container agent must:

1. Serve an A2A 1.0 agent card at `GET /.well-known/agent-card.json` on its port: HTTP 200, JSON, within 2 seconds, at most 64 KiB, with the required fields.
2. Implement the JSON-RPC binding at `POST /` with `SendMessage`. The card lists a `JSONRPC` interface with protocol version `1.0`. HTTP+JSON is optional.
3. Answer `SendMessage` with one text part by returning a message or a task that reaches a terminal or waiting state. `GetTask` works when a task id was returned.
4. If streaming is claimed, stream events that end in a terminal status. Otherwise answer an unsupported-operation error.
5. Answer an unknown method with JSON-RPC `-32601`.
6. Run as user 65532 with a read-only root file system and only `/tmp` writable, bind a port of 1024 or higher, and need no Kubernetes token.
7. Use the model only at `OPENAI_BASE_URL` with `OPENAI_API_KEY` and `OPENAGENTIX_MODEL`. With a profile, use tools only at `OPENAGENTIX_MCP_URL` with the token read fresh from `OPENAGENTIX_MCP_TOKEN_FILE`.

The controller checks only readiness (the kubelet probe on the card). It does not fetch or parse the card, because parsing foreign content in the most privileged component is a needless risk. A checker, `hack/conformance/a2a-check`, lets users test an image before deploying. It runs the image with the same restrictions and a fake model endpoint, so no paid key is needed.

### Slice plan

Every slice is tested first, off by default, leaves the default chart render unchanged, and has a live proof, a review, a diary entry and a changelog line.

1. **Container agent, model only.** The `runtime` field, validation and policy, catalog and adapter selection, the `container` adapter, finalizer cleanup, the `isolation` capability, the namespace, RBAC, the guard policies, the gate routes file with the fixed URL template, path mapping and card rewrite. Sample `examples/agents/echo-a2a`. Route list ConfigMap `a2a-gate-routes` with file `routes.json`. The gate is in slice 1 because without it the agent would be Ready but not callable.
2. **Conformance tool and a Go sample**, an installer flag and a docs page.
3. **Tools through a profile.**
4. **A Python sample** in a mainstream framework, after checking its A2A version.
5. **Egress allowlists** through the platform proxy (0.3 if time allows, else 0.4).

Deliberately left out of 0.3: `external` and `targetRef`, `sandbox`, private registry pulls (`imagePullSecrets`), per-agent tool filtering, `requireIsolation`, a RuntimeClass beyond passing a name, translation of older A2A versions.

### Rejected alternatives

| Alternative | Why not |
|---|---|
| `external` with `targetRef` as the first slice | The platform would not own the pod. See Option B |
| Run container agents in the `kagent` namespace | Shares a namespace with kagent's database Secrets and the controller. Pod Security cannot be `restricted` there |
| Pass `instructions` as an env var | Looks like a control and is not one |
| Accept `tools` and filter on the client side | The platform cannot make a foreign agent filter. The profile is the honest boundary |
| A static per-agent key at the tool server | No fitting ToolHive mode. Another long-lived secret |
| A token-exchange sidecar | Substrate issues actor tokens only to its own sessions. This belongs to the identity adapter in 0.4 |
| Gate routes with URLs written by the controller | A request-forgery surface if the controller or the ConfigMap is compromised. The fixed template removes it |
| The controller probes the agent card | Needs controller egress to foreign pods and parsing of foreign content |
| controller-runtime and a mutating webhook | Against ADR 0007's standard-library choice, and not needed when the controller writes the pod itself |

## Amendments

- **`docs/api-conventions.md`** said a spec names no image. One exception is added: `spec.runtime.container.image`, the user's own artifact, pinned by digest and matched against an operator allowlist. It exists nowhere else. The other rules stay.
- **ADR 0007** said there is no field for a harness or image. A dated amendment note now points here. What changed: one image field, for the user's own agent, only when the operator allows the `container` runtime. What did not change: no harness image, no platform component image and no other image field.
- **Implementation notes (slice 1, 2026-11-25).** The workload namespace is `openagentix-workloads` (chart value `controlPlane.containerAgents.namespace`). Because it differs from the definition's namespace, no owner reference can tie an object to its definition: every object carries both labels, the definition namespace as a label and the definition UID as an annotation, the controller deletes by name and by those labels, and the definition's finalizer holds until the workload objects and the key Secret are gone. The route list ConfigMap name is fixed (`a2a-gate-routes`). The guard checks that an image is digest-pinned and under an allowed prefix, not that it is the definition's image (the guard cannot see the definition); the controller derives the Deployment from the definition. The guard is six policies (Deployment, Service, ServiceAccount, NetworkPolicy, Secret, route list) next to the eight of ADR 0007; the three that would refuse these writes step aside for exactly these objects. A locally loaded kind image has no registry digest: the quick start reads `name@sha256:...` from the node (`hack/kind-image-digest.sh`; kind imports with digests) and allows the name-only prefix `registry.local/oa/` for the quick start only.

## Consequences

- Teams can run an agent built with any framework under the platform's key, budget, gate and audit.
- Container agents are weaker than built-in agents on isolation. An operator opts in on purpose. The default is off at two levels (chart switch and `allowedRuntimes`).
- A2A task state lives in one pod, so a restart loses in-flight tasks. Scaling is the author's problem.
- Security impact: a new namespace of foreign code; new namespaced roles with create and delete on Secrets but no read; new guard policies; the gate can now route to the workload namespace through a fixed template. Nothing new leaves the cluster by default. On clusters whose network plugin does not enforce egress, the agent can reach the internet.
- Compatibility: nothing changes for existing users. An absent `runtime` hashes to the old revision. An old catalog still validates.
- Proof needed: validation table tests, golden tests for the adapter output, a key canary test across the new manifests, gate tests (routes parse, reload, hostile names, card rewrite), guard tests with the adapter's real output and each denial, an API-server test, chart tests (default render unchanged, enabled render, failure on empty image prefixes), and an end-to-end run with the stub model.

## Not checked / open points

- *Unverified*: network policy egress enforcement on k3s. The k3s CI job must prove it first.
- *Unverified*: the claim name and principal format that ToolHive's Cedar authorizer uses for a Kubernetes service account token, and whether the `serviceAccount` and `namespace` fields of `MCPOIDCConfig` restrict the subject at run time (read only in the resolver, not in the validator).
- *Unverified*: whether the tool server's service account may need the service-account-issuer-discovery role to fetch the key set on all target clusters (OpenShift in particular).
- *Unverified*: that a mounted ConfigMap update reaches the gate fast enough. It can take about a minute, and never happens for `subPath` mounts, so the chart must mount the directory. `Ready=True` may come before the gate sees the route. The controller should set Ready only after the route patch succeeded, and the end-to-end test must poll.
- *Unverified*: that a Helm upgrade does not wipe `a2a-gate-routes` (same open point as the key ConfigMap in ADR 0007).
- The Deployment allowlist fits the admission policy cost budget as one policy (the guard tests execute it with the Kubernetes CEL code; the API-server test applies it to a real server). Results are in the pull request.
- *Unverified*: which mainstream frameworks serve A2A 1.0 today, including the current Google ADK release, and whether ADK runs with a read-only root file system. The gate does not translate older versions.
- *Unverified*: the A2A spec sections 5, 9.1 and 10.1 (whether one binding is mandatory), and how the gate's existing request checks behave against a foreign agent's responses (the gate inspects requests, not responses).
- *Unverified*: the exact tool-server memory cost on the 6 CPU, 8 GB node (one more server per opted-in profile).
- Not confirmed: whether Kagenti is a rename of Rossoctl. The Rossoctl operator repository is archived.
- The image allowlist in the guard comes from chart values, so a policy change needs a `helm upgrade`. This is accepted.
