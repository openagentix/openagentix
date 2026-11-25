---
title: Platform policy
sidebar_position: 3
description: Reference for the platform policy that decides what an AgentDefinition may ask for - every key, type, default, effect, list rules and examples.
---

# Platform policy reference

The platform policy is the operator's answer to the question "what may a definition ask for?". The controller checks every [AgentDefinition](./agentdefinition.md) against it. A definition that breaks a rule is refused with one sentence per rule in `status.violations`, and nothing is created.

Status: **available but off by default**. The policy is part of the control plane (`controlPlane.enabled: false` by default). The defaults are closed on purpose: a fresh install accepts no definition until the operator opens a model and a tool profile.

The policy is a platform setting. It is not a Kubernetes resource today. A `PlatformPolicy` kind with scopes is **reserved (designed, not built)**; see [Reserved kinds and fields](./reserved-kinds.md).

## Where it lives

| Item | Value |
|---|---|
| Chart values | `controlPlane.policy` in `charts/openagentix/values.yaml` |
| Rendered into | the ConfigMap `openagentix-control-plane-policy`, key `policy.json`, in the controller's namespace |
| Read by the controller from | the file named in `CONTROL_PLANE_POLICY_FILE` (the chart sets `/etc/control-plane/policy/policy.json`) |
| When it is read | once, at start. The chart puts a checksum on the pod, so a change of the policy replaces the pod. |
| Unknown keys | refused: the controller does not start |

The chart checks the policy when it renders. A wrong type, a list entry that is not in the catalog, or a bad origin fails `helm template` and `helm install`. The controller checks the same file again at start and refuses to start if it is wrong.

## List rules

Three keys are allow-lists of names: `allowedModels`, `allowedProfiles` and `allowedSkills`. The rule for an allow-list is:

| Value | Meaning |
|---|---|
| `[]` (empty, the default) | allows **nothing** |
| `["*"]` (one entry `"*"`) | allows **everything the catalog has** |
| `[a, b]` | allows exactly `a` and `b` |

The chart refuses a name that is not a model, a tool profile or a skill of the chart (`gateway.models`, `mcp.profiles`, the top-level `skills`). A typo fails the render. It does not silently allow nothing.

`"*"` is not a wildcard for egress. In `egress.allowedOrigins` only a leading `*.` in a host is a wildcard, and it stands for exactly one label.

## Keys

The values below are the defaults from `charts/openagentix/values.yaml`. They are generated.

<!-- generated:begin policy-defaults -->
| Key | Default |
|---|---|
| `controlPlane.policy.maxAgents` | `5` |
| `controlPlane.policy.allowedModels` | `[]` |
| `controlPlane.policy.requireToolProfile` | `true` |
| `controlPlane.policy.allowedProfiles` | `[]` |
| `controlPlane.policy.allowKnowledge` | `true` |
| `controlPlane.policy.allowNotify` | `false` |
| `controlPlane.policy.allowedSkills` | `[]` |
| `controlPlane.policy.memory.allowed` | `false` |
| `controlPlane.policy.memory.maxTtlDays` | `30` |
| `controlPlane.policy.memory.requireExpiry` | `true` |
| `controlPlane.policy.egress.allowedOrigins` | `[]` |
| `controlPlane.policy.egress.inClusterDestinations` | `[]` |
| `controlPlane.policy.allowedRuntimes` | `["builtin"]` |
| `controlPlane.policy.runtimes.container.images` | `[]` |
| `controlPlane.policy.runtimes.container.defaultResources.requests.cpu` | `"100m"` |
| `controlPlane.policy.runtimes.container.defaultResources.requests.memory` | `"256Mi"` |
| `controlPlane.policy.runtimes.container.defaultResources.limits.cpu` | `"500m"` |
| `controlPlane.policy.runtimes.container.defaultResources.limits.memory` | `"512Mi"` |
| `controlPlane.policy.runtimes.container.maxResources.cpu` | `"1"` |
| `controlPlane.policy.runtimes.container.maxResources.memory` | `"1Gi"` |
| `controlPlane.policy.runtimes.container.maxAgents` | `3` |
| `controlPlane.policy.reservedNames` | `[]` |
| `controlPlane.policy.suspendAll` | `false` |
<!-- generated:end policy-defaults -->

| Key | Type | Effect |
|---|---|---|
| `maxAgents` | integer, 0 or more | How many accepted definitions may hold a place **per namespace**. Definitions that run keep their place. After them the oldest come first. The rest are refused with a capacity sentence. `0` means no definition is accepted. |
| `allowedModels` | list of strings | Gateway model names (`gateway.models[].name`) a definition may use in `spec.model`. |
| `requireToolProfile` | boolean | When true, every definition must name a `spec.toolProfile`. |
| `allowedProfiles` | list of strings | Tool profiles (`mcp.profiles[].name`) a definition may name. |
| `allowKnowledge` | boolean | Allows `spec.knowledge.enabled: true`. It also needs the knowledge service and a profile that offers all knowledge tools. |
| `allowNotify` | boolean | Allows `spec.notify.enabled: true`. It needs `notify.enabled` and `mcp.enabled`; the chart refuses `allowNotify: true` without them. Off by default because it creates a way to message a person. |
| `allowedSkills` | list of strings | Skills (names of the top-level `skills`) a definition may name. |
| `memory.allowed` | boolean | Allows `spec.memory.enabled: true`. It needs the memory stack, which exists only when a chart agent has `memory.enabled`. |
| `memory.maxTtlDays` | integer | The largest `spec.memory.ttlDays`. When a definition sets none, the catalog default (`controlPlane.memoryDefaultTtlDays`, 15) counts. Must be at least 1 when `memory.allowed` is true. |
| `memory.requireExpiry` | boolean | When true, memory is refused while the memory expiry job is off, because the time limit would not be enforced. The chart also refuses `memory.allowed` with `requireExpiry` and no `memory.expiry.enabled`. |
| `egress.allowedOrigins` | list of origins | Origins a definition's `egress.allow` may name. Form `https://host[:port]` (or `http://`), lower case DNS name, no path. A leading `*.` stands for exactly one label. A definition's origin must equal an entry, or match a `*.` entry with the same scheme and port. A wildcard in a definition matches only an identical entry. Empty means no egress. |
| `egress.inClusterDestinations` | list of `host:port` | Exact in-cluster destinations that `egress.allow` may name. Each is a namespace-qualified service name and a number, such as `registry.ci.svc:5000`. No scheme, no wildcard, no address, no duplicate. Empty means none. Never allowed: a name inside the tools, agents or gateway namespace, `kube-system`, or the Kubernetes API service. |
| `reservedNames` | list of names | More names a definition may not use. `name` applies in every namespace and `namespace/name` in one. The chart always reserves its own agent names, `kb`, `kb-extract` and `memory` in the agents namespace. |
| `suspendAll` | boolean | The operator's stop switch. Every definition is treated as suspended: runtime agents are removed and keys are cut. |

### Hosts that egress can name

Even when the origin matches `allowedOrigins`, a host is refused if it is not public:

- **Never allowed**: a host that ends with `.NS`, `.NS.svc` or `.NS.svc.cluster.local` for the tools, agents or gateway namespace or `kube-system`, and the Kubernetes API service (`kubernetes`, `kubernetes.default` and its forms). The admission guard refuses the same.
- **Allowed only if listed** in `inClusterDestinations` as exact `host:port`: an IP address, a name with no dot, a name with a `.svc.` label, and a name whose last label is `internal`, `local`, `localhost`, `svc`, `cluster`, `lan`, `home`, `corp`, `test`, `invalid` or `example`. The names `example.org`, `example.com` and `example.net` are real names and stay allowed.
- **Not handled**: DNS rebinding. A public name may resolve to a private address when the agent connects. Only the egress proxy can stop that.

## Other control plane values

These values are not part of the policy file. They sit next to it in `controlPlane`.

<!-- generated:begin cp-defaults -->
| Key | Default |
|---|---|
| `controlPlane.enabled` | `false` |
| `controlPlane.namespace` | `""` |
| `controlPlane.sourceHash` | `""` |
| `controlPlane.apiServerCIDRs` | `[]` |
| `controlPlane.maxDefinitions` | `50` |
| `controlPlane.minInterval` | `""` |
| `controlPlane.minRecreateInterval` | `""` |
| `controlPlane.apiServerPorts` | `[443,6443]` |
| `controlPlane.containerAgents` | `{"enabled":false,"namespace":"openagentix-workloads","runtimeClassName":"","publicUrl":"","gatewayPodPort":0,"imagePullPolicy":"Always","responseTimeoutSeconds":300,"maxInFlightPerAgent":32,"toolProfiles":[],"serviceAccountTokens":{"issuer":"https://kubernetes.default.svc.cluster.local","jwksUrl":"https://kubernetes.default.svc/openid/v1/jwks"}}` |
| `controlPlane.memoryDefaultTtlDays` | `15` |
<!-- generated:end cp-defaults -->

| Key | Effect |
|---|---|
| `enabled` | Turns the control plane on. It needs `kagent.enabled`, `gateway.enabled`, at least one gateway model, and different namespaces for kagent and the gateway. |
| `maxDefinitions` | A `ResourceQuota` on the number of `AgentDefinition` objects in the agents namespace. Refused definitions count too. Keep it above `maxAgents`. |
| `minInterval` | Sets `CONTROL_PLANE_MIN_INTERVAL` when given. A Go duration such as `500ms`. Empty uses the controller default (1 s). |
| `minRecreateInterval` | Sets `CONTROL_PLANE_MIN_RECREATE_INTERVAL` when given. A Go duration such as `90s`. Empty uses the controller default (2 minutes). |
| `apiServerCIDRs`, `apiServerPorts` | Where the controller's NetworkPolicy lets it reach the API server. With no CIDRs the policy allows the ports towards any address. Set the CIDRs on a real cluster. |
| `memoryDefaultTtlDays` | What the runtime uses as memory lifetime when a definition sets none. The controller needs it to check `ttlDays`. |

## The JSON the controller loads

This is the shape of `policy.json`. It is the same data as the chart values, with the same key names.

<!-- check:policy -->
```json
{
  "maxAgents": 5,
  "allowedModels": [],
  "requireToolProfile": true,
  "allowedProfiles": [],
  "allowKnowledge": true,
  "allowNotify": false,
  "allowedSkills": [],
  "memory": {"allowed": false, "maxTtlDays": 30, "requireExpiry": true},
  "egress": {"allowedOrigins": [], "inClusterDestinations": []},
  "reservedNames": [],
  "suspendAll": false
}
```

This example is the default: nothing is allowed. Every key may be left out; a missing key takes the Go zero value (false, 0, empty list), which is not always the chart default. When you write the file yourself, write all keys.

## Examples for common setups

### Locked down (the default)

No model, no profile, no skill, no notify, no memory and no egress. Every definition is refused. Use it until you have decided what to open.

```yaml
controlPlane:
  enabled: true
  policy:
    maxAgents: 5
    allowedModels: []
    allowedProfiles: []
```

### One team

One model, one tool profile, one skill, two outside hosts, a short memory. At most ten agents.

```yaml
controlPlane:
  enabled: true
  maxDefinitions: 30
  policy:
    maxAgents: 10
    allowedModels: [claude-haiku]
    requireToolProfile: true
    allowedProfiles: [lookup]
    allowKnowledge: true
    allowNotify: false
    allowedSkills: []
    memory:
      allowed: true
      maxTtlDays: 14
      requireExpiry: true
    egress:
      allowedOrigins:
        - https://api.osv.dev
        - https://*.example.org
      inClusterDestinations: []
    reservedNames: [shared-bot]
```

The same policy as the JSON the controller loads:

<!-- check:policy -->
```json
{
  "maxAgents": 10,
  "allowedModels": ["claude-haiku"],
  "requireToolProfile": true,
  "allowedProfiles": ["lookup"],
  "allowKnowledge": true,
  "allowNotify": false,
  "allowedSkills": [],
  "memory": {"allowed": true, "maxTtlDays": 14, "requireExpiry": true},
  "egress": {
    "allowedOrigins": ["https://api.osv.dev", "https://*.example.org"],
    "inClusterDestinations": []
  },
  "reservedNames": ["shared-bot"],
  "suspendAll": false
}
```

### Open demo

Everything the catalog has is allowed. Use it on a local cluster only. Notify needs `notify.enabled` and `mcp.enabled` in the chart, and memory needs a chart agent with `memory.enabled` and `memory.expiry.enabled`.

```yaml
controlPlane:
  enabled: true
  policy:
    maxAgents: 20
    allowedModels: ["*"]
    requireToolProfile: false
    allowedProfiles: ["*"]
    allowKnowledge: true
    allowNotify: true
    allowedSkills: ["*"]
    memory: {allowed: true, maxTtlDays: 30, requireExpiry: false}
    egress:
      allowedOrigins: ["https://*.example.org", "https://api.osv.dev"]
      inClusterDestinations: ["registry.ci.svc:5000"]
```

<!-- check:policy -->
```json
{
  "maxAgents": 20,
  "allowedModels": ["*"],
  "requireToolProfile": false,
  "allowedProfiles": ["*"],
  "allowKnowledge": true,
  "allowNotify": true,
  "allowedSkills": ["*"],
  "memory": {"allowed": true, "maxTtlDays": 30, "requireExpiry": false},
  "egress": {
    "allowedOrigins": ["https://*.example.org", "https://api.osv.dev"],
    "inClusterDestinations": ["registry.ci.svc:5000"]
  },
  "reservedNames": [],
  "suspendAll": false
}
```

### Stop everything

`suspendAll` stops every definition, also those whose latest edit is refused while the older one runs. Keys are cut. Set it back to `false` to start them again (a runtime agent is created at most once per two minutes per definition).

```yaml
controlPlane:
  policy:
    suspendAll: true
```

## How the examples were checked

The JSON blocks above, marked with `check:policy`, are loaded by the controller's own policy loader in a Go test (`services/control-plane/internal/catalog/docs_test.go`). The test fails when an example is not accepted.
