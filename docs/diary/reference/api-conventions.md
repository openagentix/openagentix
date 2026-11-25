---
title: API conventions and versioning
sidebar_position: 7
description: Stability levels, what may change in v1alpha1, how deprecations are announced, and the rules every OpenAgentix resource follows.
---

# API conventions and versioning

The full rules are in [`docs/api-conventions.md`](https://github.com/openagentix/openagentix/blob/main/docs/api-conventions.md) in the repository (ADR 0012, changes 5 to 13). This page is the short form for people who read the reference.

## Stability levels

Each kind has its own version and moves on its own. Every platform kind is in the group `openagentix.io`.

| Level | Example | What may change | Notice |
|---|---|---|---|
| alpha | `v1alpha1` | Anything. A field may change, move or go. | A note in `CHANGELOG.md`. Possibly no earlier warning. |
| beta | `v1beta1` | Fields do not change in a breaking way. A version is served for at least three platform releases after it is deprecated. | A deprecation note in `CHANGELOG.md` and in the reference pages. |
| stable | `v1` | Not removed within a major release. | Same as beta. |

Today every kind that exists is `v1alpha1`. That is the case for `AgentDefinition`.

## What may change in `v1alpha1`

- Before the first release that contains a kind, its schema may change in place. This is how `AgentDefinition` got the shapes of ADR 0012 without a new version.
- After that, alpha rules apply: a change or removal is possible without a conversion. It is announced in `CHANGELOG.md`.
- Adding an optional field is always allowed, in every version.
- Changing a field's type, name or meaning, or removing a field a product may read, needs a new version and a conversion once the kind is beta or stable.
- `status.controller` and the platform catalog are internal. They may change in any release.
- The Console HTTP API is `/api/v1`. It follows the same idea: the [Console API](./console-api.md) page says what is stable.

## What a product can rely on

For `AgentDefinition`, the public status fields are the contract: `conditions`, `observedGeneration`, `endpoint`, `revision`, `effectiveTools`, `effectiveEgress`, `violations`, `capabilities`, `agentRef`. `Ready=True` means the agent is callable at `status.endpoint`, at `status.revision`. Every condition reason is listed in the [reference](./agentdefinition.md#conditions).

Identifiers the platform makes, such as the gateway user `NAMESPACE.NAME` and the key Secret name, are opaque. Do not parse them.

## How deprecations are announced

1. A line in `CHANGELOG.md` under the release that deprecates or changes the item.
2. The reference page marks the item as deprecated, with the release.
3. For beta and stable versions, the old version is served for the period in the table above.

## Rules every kind follows

- A spec names no upstream product. Planned but unbuilt fields are **reserved**: the schema allows them and the controller refuses a value with the words "not available yet". See [Reserved kinds and fields](./reserved-kinds.md).
- Lists and objects that may grow are objects, not booleans.
- Reserved label keys: `openagentix.io/team`, `openagentix.io/project`, `openagentix.io/work-item`. They are informational and never decide access, policy or billing.
- `spec.suspend` is a stop, not a pause.
- Each kind gets its own Roles (a builder and a viewer) that nothing binds. The admission guard in front of the controller is an allowlist of keys at every level.
