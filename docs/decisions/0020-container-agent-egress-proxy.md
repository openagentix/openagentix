# ADR 0020: outbound access for container agents through a platform egress proxy

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/105 (umbrella #43)
Replaces: none. Fills in "Outbound access" of ADR 0015 (slice 5) and changes one detail of it: identity at the proxy comes from the pod address and its admission label, not from one port per agent (see "Amendments").

A container agent may reach named outside hosts, and only those, through a small platform forward proxy. The operator defines the hosts as named destinations in the platform policy. A definition opts in by naming a destination, never by writing a host. The proxy tunnels TLS with HTTP `CONNECT`, does not decrypt, and writes one audit line per tunnel. It is off by default. Nothing here is built yet; everything is *unverified* until the slices below are done.

## Context

Today a container agent (ADR 0015) may reach only DNS, the model gateway and, with a profile, its workload tool server (ADR 0019). Many real agents need one or two outside APIs (an issue tracker, a vulnerability database, a weather service). The operator needs to allow exactly those, see what was used, and keep the rest of the internet closed.

Facts read in this repository on 2026-11-26:

- The container adapter writes one NetworkPolicy per agent: ingress only from the A2A gate pods on the agent's port; egress only to kube-dns on port 53 (UDP and TCP), to the model gateway pods on its port, and with a profile to the workload tool server (`services/control-plane/internal/adapters/container/container.go`, function that builds the `NetworkPolicy`). There is no `ipBlock`. The admission guard refuses `ipBlock` and empty peers (ADR 0015).
- The policy refuses `egress.allow` on a container agent with "egress.allow is not available yet for container agents" (`services/control-plane/internal/policy/container.go`).
- For built-in agents, `egress.allow` lists origins (`https://host[:port]`), each matched against the platform policy's `egress.allowedOrigins` patterns and checked against internal names (`services/control-plane/internal/policy/policy.go`, `catalog.PolicyEgress`). The chart and the controller turn them into a kagent `EgressPolicy`, which Agent Substrate's egress proxy `atenet-egress` enforces per sandbox actor. Proven on kind: an allowed host answered 200, others did not resolve or got 403 (ADR 0006, round 2).
- `atenet-egress` knows a caller as a Substrate actor (a sandbox session). It is configured through kagent `EgressPolicy` objects referenced by a kagent `Agent` (ADR 0006, F4 and F7). A container agent is neither.
- User env names that start with `OPENAGENTIX_`, `OPENAI_`, `OTEL_` or `KUBERNETES_` are refused (`ReservedEnvPrefixes` in `services/control-plane/internal/policy/container.go`). Proxy variables (`HTTPS_PROXY` and so on) are not refused today.
- Status already has a public list `effectiveEgress` (`services/control-plane/internal/api/types.go`).
- NetworkPolicy enforcement: kind's kindnet enforces policy toward cluster destinations but not toward the internet (`docs/diary/features/schedules.md`, `docs/diary/what-works.md`). k3s enforces ingress and internet egress; `hack/ci/netpol-test.sh` showed it in CI (`docs/diary/guide/install-k3s.md`). The platform does not check enforcement at install today.
- DNS: the agent's lookups go to kube-dns, which resolves outside names. ADR 0015 states this as an open outbound path.
- The gate's route list pattern (ADR 0015): the controller writes only names into a ConfigMap; the component builds addresses from a template fixed by the chart. A compromised controller or ConfigMap can then only choose among things the operator already allowed.

## Options

### Where the traffic goes

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. A new small Go forward proxy, `services/egress-proxy`, standard library only, `CONNECT` only | Exactly the checks this record needs (allowlist by name, resolve and dial itself, refuse private addresses, SNI equals the host, one audit line per tunnel, per-agent caps). Same style and review path as the A2A gate. Runs on any cluster | New code in the data path that we must maintain and get reviewed; about the size of the gate (*estimate*) | Design study only |
| B. Reuse Substrate's `atenet-egress` | Already installed; already enforces per-agent origin lists for built-in agents | Knows only Substrate actors; a plain pod has no actor identity. Configured by kagent objects bound to a kagent `Agent`. Would tie the container runtime to Substrate, against ADR 0013 (runtime neutrality). Whether it accepts a client that is not a sandbox was not checked | ADR 0006 (F4, F7, round 2) |
| C. agentgateway as a forward proxy | Already installed as the model gateway (v1.7.0) | Whether it terminates `CONNECT` with a host allowlist per client was not checked, *unverified*. Sharing the model gateway's process couples two failure domains; a second instance adds its CRD configuration behind an adapter | `components/model-gateway/NOTES.md` |
| D. Envoy with `CONNECT` termination and the dynamic forward proxy | Mature, fast, access logs | A new upstream component and image; per-client rules regenerated on every agent change; the SNI-equals-host check is not a built-in filter (*unverified*); a large configuration surface for a small job | Envoy documentation, not run |
| E. Squid with `peek` and `splice` | Mature; source-address and domain ACLs | Another large upstream component; SNI peeking needs a build with TLS support; configuration reloads | Not run |

### How a hostname is allowed without a proxy

| Option | What it gives | What it costs |
|---|---|---|
| F. Cilium `toFQDNs` policies | Host names in the kernel path, no proxy hop; Cilium's DNS proxy can also restrict which names may be looked up | Works only on Cilium. Upstream vocabulary; would be an adapter option. Not available on kind, k3s or most managed clusters by default |
| G. Istio egress gateway | Central egress with identity from the mesh | Needs a mesh and its sidecars or ambient mode. Far too heavy for one feature |
| H. Calico DNS policies | Host names in policy | Domain names in policy are a Calico Enterprise feature as far as we know, *unverified* |
| I. A proxy sidecar in each agent pod | No shared proxy | The sidecar shares the pod's network namespace, so NetworkPolicy cannot tell its traffic from the agent's. Forcing traffic through it needs `NET_ADMIN` or an init container with iptables, which Pod Security `restricted` refuses and ADR 0015 forbids |
| J. Do nothing (keep container agents closed) | Nothing to build | Agents that need one outside API cannot run as container agents |

### How the allowlist is written

| Option | What it gives | What it costs |
|---|---|---|
| K. Named destinations in the platform policy; the definition names them | The operator reviews a short list of exact hosts once; a definition can only point at it; no host text in a definition | One new definition field and one new policy key |
| L. Reuse `egress.allow` with origins matched against `allowedOrigins` | No new field | Policy patterns may hold wildcards, so each definition writes its own hosts inside them: per-agent free text, and an open-ended list for the proxy |

## Decision

Options A and K. F (Cilium) stays open as a later adapter option. The rest are rejected for the reasons in the tables.

### Public names

- **Chart switch** `controlPlane.containerAgents.egressProxy.enabled`, default `false`. It needs `controlPlane.containerAgents.enabled`. With it false nothing new renders: no namespace, no proxy, no roles, no guard change, and the default chart render is byte-identical to before.
- **Namespace** `openagentix-egress` (value `controlPlane.containerAgents.egressProxy.namespace`). One Deployment `egress-proxy`, one replica, one Service on TCP port 3128. Pod Security `restricted`; the same pod settings as the A2A gate (non-root, read-only root, no capabilities, `RuntimeDefault` seccomp).
- **Policy key** `controlPlane.policy.egress.destinations`, default `{}`:

  ```yaml
  controlPlane:
    policy:
      egress:
        destinations:
          osv:                              # a DNS label; the name a definition uses
            description: OSV vulnerability database
            hosts: ["api.osv.dev:443"]      # exact host:port, 1..16 entries
  ```

  A host is a lower case public DNS name with a dot, and a port. No wildcard, no address, no path, no scheme. The same internal-name rules as `egress.allow` apply (`catalog.InternalEgressHost`): `.svc`, `.cluster.local`, `.internal`, `.local` and the like are refused at render and when the controller loads the policy. At most 64 destinations. This key lives in the platform policy and moves with it into the `PlatformPolicy` kind (ADR 0007) when that kind is built.
- **Definition field** `spec.egress.destinations`: a list of destination names, at most 16, no duplicates.

  ```yaml
  spec:
    runtime: {type: container, container: {image: "...@sha256:..."}}
    egress:
      destinations: [osv]
  ```

  On a container agent each name must exist in the policy, and the chart switch must be on; otherwise the definition is refused with one sentence ("egress destination %q is not defined by the platform policy", "egress destinations are not available on this platform"). `egress.allow` stays refused for container agents. On a built-in agent `destinations` is refused for now ("egress.destinations is for container agents; use egress.allow"); expanding names into the kagent `EgressPolicy` can come later without a new field.
- **Status.** `effectiveEgress` lists the `host:port` entries the agent may reach. A new capability `status.capabilities.networkEnforcement` says `checked-at-install`, `not-enforced` or `unknown` (see "Enforcement check"). It is a fact the installer measured, with its limits; the controller never guesses it.
- **Route list.** A ConfigMap `egress-proxy-routes` in the proxy namespace with one file `routes.json`: `{"agents": {"<definition namespace>/<name>": ["osv", ...]}}`. It holds names only, never hosts. The proxy reads the hosts from its own configuration, rendered by the chart from the same policy key at install. So a compromised controller or ConfigMap can only give a listed agent a destination the operator already defined. The proxy mounts the directory (not `subPath`) and reloads on change, like the gate.
- **Pod label** `openagentix.io/egress-proxy: "true"` on the pod template of an agent with at least one destination.
- **Pod environment**, set by the controller only for such an agent: `HTTPS_PROXY` and `https_proxy` set to `http://egress-proxy.<namespace>.svc.cluster.local:3128`, and `NO_PROXY` and `no_proxy` set to the model gateway host and, with a profile, the tool server host. No `HTTP_PROXY` and no `ALL_PROXY`: plain HTTP to the internet is not offered.
- **Reserved env names.** User env names `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` and `NO_PROXY`, in any case, are refused on every container agent, with the switch on or off.

### What the proxy does

For each connection from an agent pod:

1. **Who is calling.** The proxy maps the source address to an agent. It watches the agent Services and their EndpointSlices in the workload namespace (a namespaced Role: get, list and watch on `services` and `endpointslices` there, nothing else) and keeps an address-to-agent table, including endpoints that are not ready yet. An address that is not in the table gets 403. There is no credential in the request: no proxy password, no token. Reason: an agent's HTTP client reads `HTTPS_PROXY` once and cannot refresh a token in it, and a static password would be one more long-lived secret.
2. **What is asked.** Only `CONNECT host:port`. Any other method gets 405. The `host:port` must be, character for character, one of the hosts of a destination the route list gives this agent. Otherwise 403.
3. **Where it goes.** The proxy resolves the name itself (through kube-dns) only after the check in step 2, so the agent cannot use the proxy as a lookup service. Every resolved address must be public: loopback, private, link-local (the cloud metadata address included), shared (100.64.0.0/10), multicast, unspecified and the IPv6 equivalents are refused, plus any range in `controlPlane.containerAgents.egressProxy.deniedCIDRs` (for clusters whose pod or Service ranges are public). The proxy dials the address it checked and never resolves again for that tunnel. This closes DNS rebinding toward the cluster.
4. **TLS only, no decryption.** After `200 Connection established` the proxy reads the first record from the agent and requires a TLS ClientHello whose server name (SNI) equals the requested host. No ClientHello, no SNI, or another name: the tunnel is closed. Then bytes are copied both ways unchanged. The proxy holds no certificate authority and never decrypts. This blocks the simple form of domain fronting (an allowed address with another name in SNI). It cannot see the `Host` header inside TLS, so fronting at that layer on a shared CDN remains possible; see "Residual risks".
5. **Caps per agent.** Defaults, all chart values under `controlPlane.containerAgents.egressProxy.limits`: 16 open tunnels per agent, 60 new tunnels per minute per agent, 1 GiB per agent per day in both directions together, 3600 s per tunnel, 300 s idle, 512 tunnels in all. A cap that is reached gets 429 for a new tunnel; the daily byte cap also closes open tunnels. Counters live in memory and start again when the proxy restarts (stated limit).
6. **Audit.** One JSON line on stdout when a tunnel ends or is refused: time, agent (`namespace/name`), destination name, `host:port`, the address dialled, outcome, a reason code for a refusal, bytes each way, duration. For an allowed tunnel the host comes from the operator's list. For a refused request the asked host is attacker-chosen text, and a log that is shipped elsewhere would be an outbound path, so the line holds a salted hash of it (like the gate's user id), never the text. No content, no headers, no SNI beyond the allowed host.
7. **Its own network.** The proxy's NetworkPolicy admits on port 3128 only pods of the workload namespace with the label `openagentix.io/egress-proxy: "true"`. Its egress is DNS to kube-dns and TCP to `0.0.0.0/0` and `::/0` except the private and special ranges of step 3, on the ports that appear in the policy's destinations only. This is a second layer under step 3, on a cluster that enforces NetworkPolicy.

The proxy does not serve built-in agents. They keep Substrate's egress proxy.

### The agent's NetworkPolicy

An agent with destinations gets one more egress rule: the proxy pods (namespace and pod selector from the catalog) on port 3128. No `ipBlock`. Without destinations the policy is unchanged.

### DNS

The agent's lookups to kube-dns stay open in the first build slice. That is an outbound path: data can be encoded in names that kube-dns forwards to outside resolvers. It is slow and small (a few hundred bytes per lookup) but real, and it exists today for every container agent. This record states it and plans a fix as its own slice:

- **DNS lockdown** (value `controlPlane.containerAgents.dns`, `cluster` by default, or `none`). With `none` the controller writes the pod with `dnsPolicy: None` and one nameserver `127.0.0.1` (nothing listens there, so a lookup fails at once), removes the kube-dns rule from the agent's NetworkPolicy, and adds `hostAliases` for the model gateway, the tool server and the proxy. Their Service addresses come from the catalog: `install.sh` reads them after the chart has created the Services and writes them in. The controller gains no read right. The guard pins `dnsPolicy`, the nameserver and each host alias to the catalog values. The agent then has no name resolution at all; the proxy resolves outside names for it. A Service that is deleted and created again gets a new address, and its agents fail closed until the next install (stated limit).
- A filtering DNS server inside the proxy was considered. It needs a DNS parser (not in Go's standard library) in a component that faces foreign code. Rejected for now.

### Enforcement check

None of this holds where NetworkPolicy is not enforced: the agent then ignores the proxy and connects anywhere. So:

- `install.sh` runs a live check (the steps of `hack/ci/netpol-test.sh`, moved to `hack/netpol-check.sh`) when the switch is on: a throwaway namespace, a client pod, a TCP connection to a public address, then a deny-all egress policy and the same connection.
- Blocked: the install goes on and writes `networkEnforcement: checked-at-install` with the date into the catalog.
- Not blocked (kind with kindnet, for example): the install stops with a message. `OA_ALLOW_UNENFORCED_EGRESS=1` lets it go on and writes `not-enforced`; the console and status then say so.
- No internet from the cluster at all, so the check proves nothing: `unknown`, with a warning.
- The check is a point in time. A network plugin changed later is not detected.

The quick start on kind therefore cannot turn this on without the override. Live proof runs on k3s.

### Admission guard

All rules are allowlists and are executed in the guard tests and on a real API server.

- **Deployment** (extends the ADR 0015 policy): the four proxy env values exactly as above, only on a pod with the label; the label value only `"true"`; with DNS lockdown, `dnsPolicy`, `dnsConfig` and `hostAliases` exactly the catalog values.
- **NetworkPolicy**: the proxy rule only toward the proxy namespace, pod selector and port; still no `ipBlock` and no empty peer.
- **Route list ConfigMap** `egress-proxy-routes`: one key, content matched by a strict pattern of names, at most 64 KiB; the controller's Role allows get and patch on that one name only. The pattern must fit the admission cost budget; the guard tests measure it.
- **Workload namespace**: like the two policies of ADR 0019, no Pod or pod-making object there may carry the label `openagentix.io/egress-proxy` unless the controller writes it. A cluster admin is refused too. This is what makes "a pod with that label at that address is that agent" true.
- **Proxy namespace**: the chart's objects only; nothing in the controller's roles touches it except the route list.

### Failure modes

| What fails | What the agent sees | Model and tools |
|---|---|---|
| Proxy down or restarting | Connection refused or reset for outside calls; open tunnels close | Unaffected (`NO_PROXY`) |
| Route list not yet reloaded (about a minute after a change, *unverified*) | 403 for a new destination; a removed one keeps working until reload | Unaffected |
| Destination removed from the policy (`helm upgrade`) | 403 for new tunnels; open tunnels to it are closed at reload | Unaffected |
| Name does not resolve, or resolves to a refused address | 502, or 403 with reason `private-address` | Unaffected |
| SNI missing or different | Tunnel closed after the first record | Unaffected |
| A cap reached | 429 for new tunnels; byte cap also closes open ones | Unaffected |
| Pod address not in the table yet (start-up race) | 403 until the EndpointSlice shows the address | Unaffected |
| NetworkPolicy not enforced | The proxy is bypassed; everything is reachable | The install check stops or marks `not-enforced` |

Every failure closes. None opens a path.

### Conformance contract (addition to ADR 0015)

8. With destinations, reach outside hosts only through `HTTPS_PROXY` with `CONNECT`, with TLS, and with SNI set to the host. Go's `net/http` and Python's `requests` and `httpx` read `HTTPS_PROXY` by default. Node.js `fetch` does not (it needs an explicit proxy agent), *unverified for current versions*. The conformance checker gets a case for this.

### Residual risks, stated

- DNS lookups to kube-dns are an outbound path until DNS lockdown is on.
- Inside an allowed TLS tunnel the proxy sees nothing. An allowed host that accepts uploads (any API with write calls) is an outbound path for whatever the agent sends there. The allowlist decides which such hosts exist; the byte cap limits the amount.
- `Host`-header fronting inside TLS on a shared CDN is not visible without decryption.
- Identity rests on the pod address, the admission label and NetworkPolicy. It assumes the network plugin stops a pod from sending with another pod's address. That is true of common plugins as far as we know, *unverified* for kube-router (k3s) and kindnet.
- Counters reset on restart; one replica means one failure point.

### Slice plan

Every slice is tested first, off by default, keeps the default render byte-identical, and has a live proof, a review, a diary entry and a changelog line. The proxy is security-relevant and gets an independent review before merge.

1. **5a, the proxy alone.** `services/egress-proxy` with table tests: `CONNECT` only, the allowlist by name, resolve-then-check (fake resolver: a name resolving to `10.0.0.1`, `169.254.169.254`, `::1`), SNI peek (none, other name, a non-TLS first record), caps, audit lines (a canary string in a refused host and in tunnel bytes must not appear in the log), route list reload, the address table from a fake EndpointSlice feed. Image with a content tag. No chart change.
2. **5b, wiring.** Chart (switch, namespace, Deployment, Service, both NetworkPolicies, Role, route list), the policy key and the definition field, validation and status, the controller's env, label and rule, the reserved env names, the guard and the workload-namespace label policy, the enforcement check in `install.sh`, the catalog fact. Live proof on k3s (`e2e-k3s`): an agent with `destinations: [osv]` reaches `https://api.osv.dev` through the proxy; `https://example.com` through the proxy gets 403; a direct connection to `1.1.1.1:443` from the agent pod times out; the audit line is present and holds no content; a second agent without the destination gets 403 for `api.osv.dev`; the model call still works.
3. **5c, DNS lockdown.** The `dns: none` mode, the installer step that writes the Service addresses, the guard rules. Live proof on k3s: a lookup of an outside name fails in the pod, the model call and the tool call work, the outside call through the proxy works.
4. **Later, not in 0.3.** Cilium `toFQDNs` as an adapter option; `destinations` for built-in agents; a credential grant per destination (0.4, with the identity adapter); wildcard hosts.

## Amendments

- **ADR 0015, "Outbound access"** said: "Per-agent allowlists come in slice 5 through a small platform forward proxy, one port per agent." This record keeps the small proxy and drops "one port per agent". Reason: a port per agent needs a port allocation contract and an ingress rule per agent in the proxy's namespace, written by the controller there. The address table needs one ingress rule and no allocation, and it depends on NetworkPolicy no more than the port scheme does (both need an enforcing plugin). Cost: identity now also depends on the network plugin refusing spoofed source addresses.

## Consequences

- A container agent can call a few outside APIs the operator named, and the operator sees every tunnel.
- Each opted-in agent's outside traffic goes through one proxy pod: one more hop and one more failure point for those calls, none for model and tool calls.
- An operator must write each host. There are no wildcards, so services with many host names are tedious to list. This is on purpose for 0.3.
- Security impact: a new component that faces foreign code and has internet egress. It is closed by default at three levels (chart switch, an empty destination list, no definition opting in). The proxy has read rights on Services and EndpointSlices of the workload namespace only, no Secrets, no write rights. The controller gains get and patch on one ConfigMap. What leaves the cluster: TLS to the listed hosts, and DNS lookups until DNS lockdown is on. What is recorded: one line per tunnel, without content.
- Compatibility: nothing changes for existing users. A container agent that set `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` or `NO_PROXY` itself is refused after the upgrade and must drop them; with the feature off those variables could only point at an address the NetworkPolicy already blocks.
- Proof needed: as listed in the slices, plus chart tests (byte-identical default render, the enabled render, render failures for a bad host, an internal name, a duplicate, an unknown destination name), guard tests with the controller's real output and each denial, and the API-server test.

## Not checked / open points

- *Unverified*: whether agentgateway v1.7 can terminate `CONNECT` with a per-client host allowlist. If it can, option C should be compared again before slice 5a starts.
- *Unverified*: that EndpointSlices list a pod address before the pod is ready on kind and k3s, and how fast an address change reaches a watch.
- *Unverified*: that kube-router (k3s) and kindnet refuse spoofed pod source addresses.
- *Unverified*: whether Calico's open-source edition supports domain names in policy.
- *Unverified*: which Node.js, Python and Go HTTP clients read `HTTPS_PROXY` and `NO_PROXY` the same way (case, port matching, suffix rules).
- Open: whether the default caps (16 tunnels, 60 per minute, 1 GiB per day) fit real agents. They are guesses until an agent runs with them.
- Open: whether DNS lockdown should become the default for container agents once it is proven, also for agents without destinations.
- Open: whether the proxy should run two replicas. Then the caps are per replica unless they are shared, which needs state.
- Open: whether to allow plain HTTP to a listed host (some internal mirrors). Not in 0.3.
- Open: whether the enforcement check should run again on a schedule, so a changed network plugin is noticed.
