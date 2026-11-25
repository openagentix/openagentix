---
title: Reference
sidebar_position: 1
description: Reference for the resources and APIs of OpenAgentix - AgentDefinition, platform policy and catalog, the console API, the A2A gate, the admission guard and the reserved kinds.
---

# Reference

Exact names, types, defaults and limits. Every item says if it is **available**, **available but off by default**, or **reserved (designed, not built)**. Where code and older prose disagree, the code wins.

| Page | What it covers | Status |
|---|---|---|
| [AgentDefinition](./agentdefinition.md) | The resource `openagentix.io/v1alpha1`: spec, status, conditions, life cycle, roles | available but off by default |
| [Platform policy](./platform-policy.md) | `controlPlane.policy`: what a definition may ask for | available but off by default |
| [Platform catalog](./platform-catalog.md) | What exists on the platform. Internal contract between chart and controller | available but off by default (internal) |
| [Console HTTP API](./console-api.md) | Routes, errors, limits, headers and extension interfaces of the console | available but off by default |
| [A2A gate](./a2a-gate.md) | How to call an agent, caller rules, the audit line | available but off by default |
| [Admission guard](./admission-guard.md) | The eight policies that limit the controller | available but off by default |
| [Reserved kinds and fields](./reserved-kinds.md) | `AgentRun`, `ApprovalRequest`, `AgentAccess`, `Schedule` and more | reserved |
| [API conventions and versioning](./api-conventions.md) | Stability levels and deprecation | available |

## Generated parts and tests

Field tables, condition reasons, violation sentences and policy defaults are generated from the code by `hack/docs/gen-reference.sh`. The blocks sit between `generated:begin` and `generated:end` comments. Run the script after you change the CRD, `reasons.go`, `policy.go` or `values.yaml`.

`hack/docs/tests/run.sh` (part of `make test-shell`) fails when a page differs from the generator, when a YAML example does not pass the CRD schema, and when the OpenAPI file and the console routes differ. A Go test loads the JSON policy and catalog examples with the controller's own loaders.

The machine-readable description of the console API is [`console-openapi.yaml`](https://github.com/openagentix/openagentix/blob/main/docs/diary/reference/console-openapi.yaml).
