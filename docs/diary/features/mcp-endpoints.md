---
title: MCP endpoints (mcp.endpoints)
sidebar_position: 15.6
description: "An MCP service that already runs, in a tool profile, in a tool group of its own with a header credential from a Secret (ADR 0026, slice 2). How to turn it on, what the chart renders and refuses, and what is and is not proven."
---

# MCP endpoints that already run: `mcp.endpoints`

Issue [#229](https://github.com/openagentix/openagentix/issues/229), [ADR 0026](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0026-use-case-wiring-contracts.md), slice 2. This is the first of the contracts that the bank use case needs. The bank case (PR 239) had to apply an `MCPServerEntry` by hand and put the records service into the shared tool group. That gave the shared vMCP, and its code mode, the builder's write tools.

## What it is for

A tool server that needs a file, a variable or a Secret does not run in the tools namespace. It runs as its own Deployment in its own namespace. `mcp.endpoints` lets a tool profile list such a service. The chart does the rest: the tool group, the entry, the header credential, the vMCP of the profile and the network policies. Off by default. With the list empty the default render is byte for byte what it was.

## Turn it on

```yaml
controlPlane:
  apiServerCIDRs: [172.18.0.0/24]        # install.sh finds this itself
mcp:
  endpoints:
    - name: records
      url: http://records.fernvale-records.svc.cluster.local:8080/mcp
      group: disputes
      auth:
        header: {name: Authorization, secret: {name: records-mcp-auth, key: value}}
      ingress:
        podSelector: {app: records}
        port: 8080
  profiles:
    - name: disputes
      codeMode: false
      tools:
        records: [get_case, list_open_cases]
        knowledge: [kb_search]
```

The order matters. First the endpoint's namespace, its Deployment and its Service. Then the Secret `records-mcp-auth` in the tools namespace (the value is the whole header value, for example `Bearer <token>`; the endpoint checks the same value from its own Secret). Then the platform values. The chart never creates or labels a namespace it does not own, and it never renders a Secret.

## What the chart renders

| Object | Where | What it does |
|---|---|---|
| `MCPGroup` per `group` | tools namespace | A tool group of its own. The shared vMCP and the profiles on the shared group never name it |
| `MCPServerEntry` and `MCPExternalAuthConfig` (unauthenticated) | tools namespace, in the group | The endpoint. `headerForward.addHeadersFromSecret` sends the header on every request. The auth type `bearerToken` is never used: ToolHive 0.67.1 drops such a backend and the vMCP stays Ready |
| Mirror entries `<entryName>-<group>` | tools namespace, in the group | One for the knowledge base and one for notify, when the profile lists them. The model sees `knowledge-disputes_kb_search`. Entry names are unique in a namespace, so the shared names cannot be reused |
| `VirtualMCPServer` of the profile | tools namespace, on the group | Deny by default, the filter you wrote. Audit request and response data are always off. No code mode, no composite tools. A Cedar `forbid` on resource reads and prompt gets stands in front of the permit: the filter covers tools only, and the first live run showed a profile vMCP listing and reading the resources and prompts of a backend its profile does not list |
| Cedar `forbid` on the shared vMCP | in front of its policy | One per endpoint tool that a profile lists. A second layer in case an entry lands in the wrong group |
| `NetworkPolicy openagentix-endpoint-<name>` | the endpoint's namespace | Ingress to the endpoint's pods, on the pod port, from the vMCP pods of the group only |
| `NetworkPolicy openagentix-vmcp-egress-<group>` | tools namespace | Egress of the group's vMCPs: DNS, the endpoint's pods, the knowledge base and notify, the identity provider's namespace, the API server, the telemetry endpoint. Nothing else |

A profile that lists an endpoint tool stays out of the control plane catalog. So the admission guard, which is built from the catalog, refuses an `AgentTemplate` that names its server, for every tool, and `allowedProfiles: ["*"]` does not change that. Naming such a profile in `allowedProfiles` or in `containerAgents.toolProfiles` fails the render.

## What the chart refuses

Each refusal is a sentence that names the value. The tests have one case per refusal (`charts/openagentix/tests/endpoints.sh`).

- The URL: an address literal, a user name, a query, a fragment, a short form like `records.fernvale-records`, an internet name (a later slice), every namespace that a chart value names (computed from the values, so a new one cannot be forgotten), `default`, `kube-system`, `kube-public`, `kube-node-lease`, `openagentix-*` and the Kubernetes API service.
- The boundary: no `ingress`, an empty `podSelector`, no `port`, `networkPolicy.enabled: false`, an empty `controlPlane.apiServerCIDRs`.
- The credential: a header name that is not a token, or is one of `Host`, `Content-Length`, `Content-Type`, `Transfer-Encoding`, `Connection`, `Cookie`, `Proxy-Authorization`, `Mcp-Session-Id`, `Mcp-Protocol-Version`, `Metadata-Flavor`, `Metadata`, `X-aws-ec2-metadata-token`; a value in the values (only a Secret reference is possible).
- Names: a taken or reserved name, a tool name with a `.`, a prefixed tool name over 64 characters, two backends of one group with the same prefixed name, a reserved or invalid group name.
- Profiles: code mode, two groups in one profile, an `mcp.servers` entry next to an endpoint.
- Agents cannot go around the profile: `agents[].egress.allow`, `controlPlane.policy.egress.allowedOrigins` and `inClusterDestinations` that name the endpoint host as `service.namespace`, `service.namespace.svc` or the full name, or with a wildcard that covers it.
- `allowDefinitions: true` on an endpoint with a group, an empty `group` without `allowUnauthenticated`, and `allowUnauthenticated` itself (the shared group mode is slice 6).

The admission guard and the controller now treat the short form `<service>.<namespace>` as a cluster name when the namespace has a dash or a digit (`records.fernvale-records`). A namespace of letters only has the shape of a top level domain, and nothing offline tells the two apart. For an endpoint the chart refuses the host in every form, so that gap is closed there.

## The installer

`install.sh` stops before the chart when a header Secret is missing or has no such key. It finds the API server addresses for the egress policy when your values do not set them. After the chart it reads each vMCP of a group that holds an endpoint: a `DiscoveredAuthConfig-<entry>` condition that is False fails the install, and so does an endpoint or mirror that is missing from `status.discoveredBackends` or whose status is not `ready`. A dropped backend does not make a vMCP not Ready, so Ready is not enough. `hack/endpoints-check.sh`, tested with a fake `kubectl`.

## What is proven

*To be filled in from the live run of this slice (the `e2e` workflow, input `endpoints`).* Offline: 182 chart checks, the guard executed with the Kubernetes CEL code, the new objects and both policies on a real API server in `make test-apiserver`, and the installer checks with fakes.

## What is not proven

- The shared group mode, internet endpoints and the bank use case on these values (slices 5 to 7).
- That the vMCP follows no redirect, and what `overrides` does, are checked in the live run as observations. Read the result below before you rely on either.
- The egress policy on a network plugin that enforces egress. kindnet is the plugin of the CI cluster.
- Every vMCP of the tools namespace can read every Secret there through the API. The header Secret is as safe as that namespace. The follow-up in ADR 0026 (a namespace per credentialed group) is not built.
