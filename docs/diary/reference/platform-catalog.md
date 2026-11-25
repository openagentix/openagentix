---
title: Platform catalog
sidebar_position: 4
description: Reference for the platform catalog, the file the chart gives the controller to say what exists on the platform. An internal contract between the chart and the controller.
---

# Platform catalog reference

The catalog says **what exists** on this platform: which models, which tool profiles, which skills, which services. The [policy](./platform-policy.md) says **what is allowed**. A definition must be in both.

Status: **available but off by default** (it is part of the control plane, `controlPlane.enabled: false`).

:::caution Internal contract
The catalog is an **internal contract between the chart and the controller**. It may change in any release, without a version bump. It is not an API for products. Do not write it by hand and do not read it from a product. This page exists for operators who debug a refusal, and for people who work on the controller. Products should read `AgentDefinition` status instead.
:::

## Who writes it

Nobody writes the catalog by hand. The Helm chart renders it from the same values that render the chart's own agents (`charts/openagentix/templates/_helpers.tpl`, the template `oa.cpCatalog`), so the two cannot drift. It holds no secret: names, URLs, tool names, prompts and digest-pinned skill references.

| Item | Value |
|---|---|
| ConfigMap | `openagentix-control-plane-catalog`, key `catalog.json`, in the controller's namespace |
| Read by the controller from | the file named in `CONTROL_PLANE_CATALOG_FILE` (the chart sets `/etc/control-plane/catalog/catalog.json`) |
| When | once, at start. A change of the catalog replaces the pod (a checksum annotation). |
| Unknown fields | refused. The controller does not start. |
| Trailing data after the JSON | refused |

To read the catalog of a running install:

```sh
kubectl get configmap openagentix-control-plane-catalog -n kagent \
  -o jsonpath='{.data.catalog\.json}' | jq .
```

Use the namespace where the controller runs. It is the release namespace unless `controlPlane.namespace` is set.

## Fields

The top level is platform level. What only one adapter needs is in that adapter's own section: `runtime.<adapter>` and `tools.<adapter>`. The section of the adapter named in `adapters` must be present.

| Field | Type | Meaning | Chart source |
|---|---|---|---|
| `adapters.runtime` | string | Runtime adapter. This build supports `kagent`. Required. | fixed |
| `adapters.modelGateway` | string | Model gateway adapter: `agentgateway`. Required. | fixed |
| `adapters.tools` | string | Tools adapter: `toolhive`. Required. | fixed |
| `namespaces.agents` | string | The namespace the controller lists and watches. Definitions and their objects live here. Required. | `kagent.namespace` |
| `namespaces.gateway` | string | Where the key ConfigMap `llm-api-keys-control-plane` lives. Required. | `gateway.namespace` |
| `namespaces.tools` | string | The tool servers' namespace. An egress origin inside it is refused. Required. | `mcp.namespace` |
| `gatewayBaseUrl` | string | The gateway's OpenAI base URL that an agent's model config points at. Must be an `http` or `https` URL. | `oa.gatewayBaseUrl` |
| `models` | list of strings | Gateway model names. At least one. | `gateway.models[].name` |
| `knowledge.available` | boolean | The knowledge service is installed. | `knowledge.enabled` and `mcp.enabled` |
| `knowledge.tools` | list of strings | The tools that `knowledge.enabled` adds, in order. | `oa.knowledgeTools` |
| `knowledge.prompt` | string | Text added to the system prompt. Tool names are already filled in. | `oa.knowledgeAgentPrompt` |
| `notify.available`, `notify.tools`, `notify.prompt` | | The same, for notify. | `notify.enabled` and `mcp.enabled` |
| `memory.available` | boolean | The memory stack is installed. | chart helper `oa.memoryEnabled` |
| `memory.expiryEnabled` | boolean | The job that enforces the memory time limit runs. | `memory.expiry.enabled` and `kagent.enabled` |
| `memory.defaultTtlDays` | integer, 1 or more when memory is available | The runtime's default when a definition sets no `ttlDays`. | `controlPlane.memoryDefaultTtlDays` |
| `memory.prompt` | string | Text added to the system prompt. Required when memory is available. | `memory.agentPrompt` |
| `skills` | map, name to reference | Skill name to an OCI reference. The reference must end in `@sha256:` and 64 hex characters, or the file is refused. The digest is the one `version` a definition may name. | top-level `skills` |
| `gateUrl` | string | Base URL of the A2A gate. Empty when the gate is off; then no definition has an `endpoint`. | `oa.a2aGateUrl` |
| `reservedNames` | list of strings | Names a definition may not use in the agents namespace: every chart agent, plus `kb`, `kb-extract`, `memory`, and the names derived from key and model config overrides. | `agents[]` and more |
| `runtime.kagent.harnessImage` | string | Image of the agent harness. Required for `kagent`. | `kagent.harnessImage` |
| `runtime.kagent.workerPool` | string | Worker pool. Required. | `kagent.workerPool` |
| `runtime.kagent.snapshotLocation` | string | Where snapshots go. Required. | `kagent.snapshotLocation` |
| `runtime.kagent.harnessEnv[]` | list of `{name, value}` | Environment of the harness. `OTEL_PROPAGATORS` when observability and baggage are on, else empty. | `observability.*` |
| `runtime.kagent.memoryModelConfig` | string | Name of the shared embedding model config. Required when memory is available. | `memory.modelConfig.name` |
| `tools.toolhive.codeModeTool` | string | Name of the code-mode tool (`execute_tool_script`). Required. | fixed |
| `tools.toolhive.profiles[].name` | string | Tool profile name. Not empty, not repeated. | `mcp.profiles[].name` |
| `tools.toolhive.profiles[].toolServer` | string | Name of the profile's tool server object, `REMOTE-PROFILE`. Required. | `kagent.remoteMCPServer.name` plus the profile |
| `tools.toolhive.profiles[].codeMode` | boolean | The profile offers code mode. It must be true exactly when `codeModeTool` is in `tools`. | `mcp.profiles[].codeMode` |
| `tools.toolhive.profiles[].tools` | list of strings | Agent-side tool names the profile offers. Not empty. The code-mode tool is last when `codeMode` is true. | `oa.profileToolNames` |

Rules the controller checks when it loads the file: required fields are not empty; `knowledge` and `notify` that are available have tools and a prompt; every skill reference is pinned by digest; the profile rules above hold.

## Example

This is a small but complete catalog. It is loaded by the controller's own loader in a Go test, so it is valid.

<!-- check:catalog -->
```json
{
  "adapters": {"runtime": "kagent", "modelGateway": "agentgateway", "tools": "toolhive"},
  "namespaces": {"agents": "kagent", "gateway": "agentgateway-system", "tools": "mcp-tools"},
  "gatewayBaseUrl": "http://model-gateway.agentgateway-system.svc.cluster.local/v1",
  "models": ["claude-haiku"],
  "runtime": {
    "kagent": {
      "harnessImage": "ghcr.io/example/harness@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "workerPool": "kagent-default",
      "snapshotLocation": "s3://snapshots/kagent/",
      "harnessEnv": [],
      "memoryModelConfig": ""
    }
  },
  "tools": {
    "toolhive": {
      "codeModeTool": "execute_tool_script",
      "profiles": [
        {
          "name": "lookup",
          "toolServer": "toolhive-vmcp-lookup",
          "codeMode": false,
          "tools": ["osv_query_vulnerability"]
        }
      ]
    }
  },
  "knowledge": {"available": false, "tools": [], "prompt": ""},
  "notify": {"available": false, "tools": [], "prompt": ""},
  "memory": {"available": false, "expiryEnabled": false, "defaultTtlDays": 15, "prompt": ""},
  "skills": {},
  "gateUrl": "http://a2a-gate.openagentix-gateway.svc.cluster.local:8080",
  "reservedNames": ["assistant", "kb", "kb-extract", "memory"]
}
```

A full example for the demo values is `services/control-plane/testdata/catalog.json`.

## Debugging with the catalog

| Symptom | Look at |
|---|---|
| `model "x" is not in the platform catalog (a, b)` | `models`. Add the model to `gateway.models` in the chart. |
| `toolProfile "x" is not defined (defined: ...)` | `tools.toolhive.profiles[].name`. The profile must be in `mcp.profiles`, and `mcp.enabled` and `kagent.remoteMCPServer.enabled` must be true. |
| a tool "is not in profile" | `tools.toolhive.profiles[].tools` for that profile. |
| `knowledge is not available on this platform` | `knowledge.available`. Turn on `knowledge.enabled` and `mcp.enabled`. |
| `memory is not installed on this platform` | `memory.available`. A chart agent needs `memory.enabled`. |
| name is reserved | `reservedNames` and `policy.reservedNames`. |
| `Ready=False`, reason `NoEndpoint` | `gateUrl` is empty. Turn on `governance.a2a.enabled`. |
| the controller does not start | The log names the field. An unknown field or a skill without a digest stops the start. |
