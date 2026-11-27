---
title: ToolHive spike for diagnostic tools
sidebar_position: 15
description: What a throwaway-cluster spike showed about ToolHive 0.67.1, for the read-only diagnostic tool servers of ADR 0025 (slice 2).
---

# ToolHive spike for diagnostic tools

Issue [#230](https://github.com/openagentix/openagentix/issues/230), ADR 0025 slice 2. This page is the record of one spike. It does not describe a feature of the product.

## What was run

A workflow, `.github/workflows/spike-toolhive.yml` (it runs only when its own files change, and by hand; it is not part of `ci-ok`), starts a throwaway kind cluster on a hosted runner. `hack/spikes/toolhive-diagnostics-spike.sh` then installs only the ToolHive operator 0.67.1 (the same chart pins as `components/tools/install.sh`), one small stand-in MCP server (`hack/spikes/spike-mcp-backend.py`, standard library only), a small identity provider that serves a JWKS over plain HTTP, and the objects in `hack/spikes/toolhive-diagnostics-spike.yaml`. `hack/spikes/toolhive_spike.py` runs one check per question, with a positive control for each, and writes `results.md` to the job summary.

The stand-in server answers many backends from one pod. The URL path picks the tool set. One backend (`dgs`, tools `pods_list` and `whoami`) plays the diagnostics server that must stay out of the shared vMCP. `whoami` reports a SHA-256 and the length of every request header, so the spike can see what ToolHive sent without printing a credential.

Objects: three MCPGroups (`shared`, `sepgrp`, `diag`), eight `MCPServerEntry` objects, three `MCPExternalAuthConfig` objects, and six vMCPs:

| vMCP | Group | What it tests |
|---|---|---|
| `sh-open` | shared | control: no filter, Cedar permit-all, audit with request and response data on |
| `sh-excl` | shared | `aggregation.tools: [{workload: dgs, excludeAll: true}]`, code mode on |
| `sh-deny` | shared | `defaultToolVisibility: deny` with only `ok` listed, code mode on |
| `sh-cedar` | shared | Cedar `permit(principal, action, resource)` plus a `forbid` on each `dgs` tool name, code mode on |
| `sh-sep` | sepgrp | a vMCP whose group holds no diagnostics backend |
| `diag` | diag | the dedicated vMCP: OIDC, audit with request and response data off, `passthroughHeaders: [X-Caller-Id]` |

Runs on the pull request (all on `ubuntu-24.04`, one kind node):

| Run | Result |
|---|---|
| [45975547517](https://github.com/openagentix/openagentix/actions/runs/45975547517) | First run. The checks ran, but the vMCP logs were empty: the script looked for pods named `vmcp-<name>`, and the operator names the pods `<name>-<hash>` (only the Service is `vmcp-<name>`). The audit checks were inconclusive and the "value not in logs" check was empty. |
| [45976119597](https://github.com/openagentix/openagentix/actions/runs/45976119597) | After the fix of the pod name. Audit checks conclusive. |
| [45976638690](https://github.com/openagentix/openagentix/actions/runs/45976638690) | Adds the audit event fields and a credential on a backend of the shared group. This is the run the tables below come from. |

## What was seen

### 1. Keeping the shared vMCP from exposing a backend's tools

On the unfiltered control (`sh-open`) the shared vMCP lists `dgs_pods_list` and `dgs_whoami` and a direct call returns the backend result, so the checks can see a leak.

| Way | Tool list | Direct call | Code mode script |
|---|---|---|---|
| `excludeAll: true` for the backend (`sh-excl`) | none of the `dgs` tools | refused, JSON-RPC error `tool "dgs_pods_list" not found` | refused, `undefined: dgs_pods_list` |
| `defaultToolVisibility: deny`, backend not listed (`sh-deny`) | none | refused, same error | refused, same error |
| Cedar `forbid` on the tool names, permit-all kept (`sh-cedar`) | none (Cedar also hides them from the list) | refused, HTTP 403 `call denied by authorization policy` | refused, `undefined` (the script cannot see the tool) |
| A group that does not hold the backend (`sh-sep`) | none | refused, not found | not run (the vMCP has no code mode) |

In every case the other tool (`ok_ping`) still worked, direct and from code mode. The dedicated vMCP lists the diagnostics tools. The `execute_tool_script` description does not mention the names of excluded tools.

### 2. Sending a bearer value from a Secret to a backend

| How | Result |
|---|---|
| `MCPServerEntry.spec.headerForward.addHeadersFromSecret` | works. The backend received `Authorization` equal to the Secret value, byte for byte. |
| `MCPExternalAuthConfig` `type: headerInjection` referenced by the entry | works, same result. |
| `MCPExternalAuthConfig` `type: bearerToken` referenced by the entry | does not work in 0.67.1. The vMCP drops the backend. Its `status` has the condition `DiscoveredAuthConfig-<entry>` False with `unsupported auth type: bearerToken`. The vMCP stays Ready with fewer backends. |
| `headerForward` on an entry with no `externalAuthConfigRef` | works. (The repository's note that an entry without a reference is dropped was written for entries with no auth at all; this case was not tested without `headerForward`.) |

The header went out on every request: discovery (`server/discover`, `initialize`, `tools/list`) and calls. The value was searched for, and not found, in the entries, auth configs, vMCPs, groups, ConfigMaps and pod specs of the namespace, in the logs of all six vMCP pods and in the operator log. The operator gives the vMCP pod the value as an environment variable with `secretKeyRef` (names like `TOOLHIVE_SECRET_HEADER_FORWARD_AUTHORIZATION_<ENTRY>`), so the kubelet resolves it and the pod spec holds only the reference.

**One result to design around.** With `headerForward` on `dgs`, which is in the shared group, the pods of `sh-open`, `sh-excl`, `sh-deny` and `sh-cedar` all got the environment variable, including the three that expose none of its tools. Only `sh-sep`, in another group, did not. So excluding a backend from the shared vMCP does not keep its credential out of the shared vMCP pod. A credential for a diagnostics server belongs on an entry in a group the shared vMCP does not use, or the shared vMCP pod has to be treated as holding it.

### 3. Caller identity at the backend

- The vMCP with OIDC refused a call with no token (HTTP 401), so the control is valid.
- The caller's token was not forwarded: no header the backend received had the hash of the token or of `Bearer <token>`, and no header held the `sub` or a claim value. The headers were `accept`, `accept-encoding`, `content-length`, `content-type`, `host`, `mcp-protocol-version`, `user-agent` and, only when the spec asks for it, the passthrough header.
- `spec.passthroughHeaders: [X-Caller-Id]` forwards that one header from the caller to the backend, on the calls that carry it. The calls without it carry none. It is a header the caller chooses, so it says nothing the backend can trust unless a trusted upstream sets it.
- The vMCP audit does name the caller: `subjects.user_id` was the `sub` of the token (`spike-agent-1`).

### 4. Does the vMCP audit hold tool results

ToolHive writes audit events as JSON lines on the vMCP's standard output (`level: AUDIT`, `msg: audit_event`; types `mcp_tool_call`, `mcp_tools_list`, `mcp_initialize` and others).

- With `includeRequestData: true` and `includeResponseData: true` (`sh-open`): the event has a `data` object with the request (the argument canary) and the response (the result canary). A script call through code mode is one event for `execute_tool_script`, with the script text and its result. The inner tool call has no event of its own (the log held three `mcp_tool_call` events for three calls: two direct and one script), so the audit does not show which tools a script used except through the script text, and only when request capture is on.
- With both `false` (`diag`): the result canary and the argument canary were in no vMCP log line. The event has `subjects`, `target.name`, `metadata.extra.backend_name` and `duration_ms`, and no `data`. `response_size_bytes` was present only in the capture-on event.
- The setting that turns capture off is `spec.config.audit.includeResponseData: false` (and `includeRequestData: false`). The chart renders both from `observability.capture.content` already.

### 5. Code mode

In the three exclusion variants the code mode tool `execute_tool_script` did not expose the excluded tools: a script that calls one fails with `undefined`, and the tool schema does not name them. The same script works on the unfiltered control. So code mode follows the aggregation filter and the Cedar policy, as the CRD text says.

## Stop rules of the ADR

| Rule | Satisfied | Evidence |
|---|---|---|
| Slice 2: "if neither (a) nor (b) holds, nothing is registered in the shared group" | Yes (not triggered) | (a) holds in two forms and (b) holds. |
| Slice 2: "if (b) holds and (a) does not, the forbid layer alone is accepted only with the independent reviewer's agreement" | Yes (not triggered) | (a) holds, so the forbid layer is a second layer, not the only one. |
| Section 6: both layers shown on 0.67.1 (list none, direct call refused, code mode call refused) | Yes | `excludeAll` and `defaultToolVisibility: deny` each pass list, call and code mode; the Cedar `forbid` passes call and code mode and also hides the tools from the list. |
| Section 6 fallback: a separate group | Not needed. It also works. | `sh-sep` lists none and refuses calls. |
| Decision 4 (bearer value becomes required once header injection works) | Condition met | `headerForward` and `headerInjection` both work. The slice that adds it must not use `bearerToken`. |
| Section 7: "the vMCP does not forward the caller" | Confirmed for 0.67.1 | The token and its claims did not reach the backend. The audit event names the `sub`. |
| Slice 2 (e): `includeResponseData: false` keeps output out of the audit | Confirmed | Control found the canary with it on, none with it off. |

No stop rule failed, so slice 4 can render the `MCPServerEntry` objects behind the two layers of section 6. The notes below should be folded into slice 4 and, where they change the text, into the ADR.

## What to change in slice 4 because of this

- Use `excludeAll: true` for each diagnostics backend in the shared vMCP's `aggregation.tools`, and the Cedar `forbid` per tool as the second layer. By its definition `excludeAll` hides a tool the backend adds later and a `forbid` that names tools does not; the spike did not add a tool to a running backend, so this is expected, not shown.
- For the bearer value, set `headerForward` on the entry or a `headerInjection` auth config. Do not use `bearerToken`. Add a chart or live check that reads the vMCP status for `DiscoveredAuthConfig-*` False conditions, because a dropped backend does not make the vMCP not Ready.
- Decide where the Secret goes. As the spike shows, every vMCP of a group gets the environment variable for every entry of that group that has a header Secret. If the shared vMCP pod must not hold the diagnostics credential, the diagnostics entries need their own group, and then profile vMCPs for diagnostics profiles would be built on that group. That is a larger change than the ADR draws, so it needs the maintainer's decision before slice 4.
- The server cannot learn which agent called it. The caller's `sub` is only in the vMCP audit line.

## Limits

- One ToolHive version (0.67.1), one single-node kind cluster, one run of each check. No repeat runs for flakiness.
- The shared-group vMCPs in the spike use anonymous callers so the exclusion checks do not depend on the identity provider. The chart's shared vMCP uses OIDC with a Cedar policy. A `forbid` on a tool name does not depend on the principal, and the OIDC path was tested on the `diag` vMCP only, but a shared vMCP with OIDC and Cedar `forbid` together was not run.
- Not run: the `-workload` variants of ADR 0019 (a second OIDC type), a profile vMCP that lists a diagnostics tool, NetworkPolicy, upgrade of a running vMCP when the filter changes (how long a tool stays visible), and tools added to a backend after the vMCP started.
- Code mode was tested with a one-call script, not with a script that tries to build a tool name at run time. Starlark in the sandbox has no way to call a function that is not defined, as seen, but this was not attacked further.
- The audit check looked at the vMCP's standard output only. The backend's own log was also searched; the stand-in logs no content. Traces and metrics were not enabled in the spike, so nothing was learned about content in telemetry (ADR 0025 section 6 keeps the render refusal for `observability.capture.content`).
- The stand-in backend is plain HTTP and speaks only JSON answers, no SSE and no sessions. A real server in Go may behave differently with a header it does not expect; that belongs to slices 3 and 4.
