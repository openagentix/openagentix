# ADR 0020: outbound access for container agents through a platform egress proxy

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/105 (umbrella #43)
Replaces: none. Fills in "Outbound access" of ADR 0015 (slice 5) and changes two passages of it: identity at the proxy comes from the pod address and its admission label, not from one port per agent, and the guard's NetworkPolicy and Deployment rules gain the proxy (see "Amendments").

A container agent may reach named outside hosts, and only those, through a small platform forward proxy. The operator defines the hosts as named destinations in the platform policy. A definition opts in by naming a destination, never by writing a host. The proxy tunnels TLS with HTTP `CONNECT`, does not decrypt, and writes one audit line per tunnel. It is off by default. Nothing here is built yet; everything is *unverified* until the slices below are done.

## Context

Today a container agent (ADR 0015) may reach only DNS, the model gateway and, with a profile, its workload tool server (ADR 0019). Many real agents need one or two outside APIs (an issue tracker, an advisory database, a weather service). The operator needs to allow exactly those, see what was used, and keep the rest of the internet closed.

Facts read in this repository on 2026-11-26:

- The container adapter writes one NetworkPolicy per agent: ingress only from the A2A gate pods on the agent's port; egress only to kube-dns on port 53 (UDP and TCP), to the model gateway pods on its port, and with a profile to the workload tool server (`services/control-plane/internal/adapters/container/container.go`, function that builds the `NetworkPolicy`). There is no `ipBlock`. The admission guard refuses `ipBlock` and empty peers (ADR 0015).
- The adapter also writes one ClusterIP Service per agent in the workload namespace, selecting the pods by the label `openagentix.io/agent: <name>`. The Deployment guard pins the pod template labels to `{openagentix.io/agent}` or `{openagentix.io/agent, openagentix.io/tool-profile}` (`charts/openagentix/templates/control-plane-guard-workload.yaml`). Nothing stops another user from creating a bare Pod with `openagentix.io/agent: <name>` in the workload namespace today; it would be selected by that agent's Service.
- ADR 0019's two policies (`charts/openagentix/templates/container-agents.yaml`) judge every user except the controller and the cluster's own controllers in kube-system (`system:kube-controller-manager` and `system:serviceaccount:kube-system:*`). They cover create and update of Pods and every kind that makes pods. They do not cover the `pods/ephemeralcontainers` subresource.
- The policy refuses `egress.allow` on a container agent with "egress.allow is not available yet for container agents" (`services/control-plane/internal/policy/container.go`).
- For built-in agents, `egress.allow` lists origins (`https://host[:port]`), each matched against the platform policy's `egress.allowedOrigins` patterns and checked against internal names (`services/control-plane/internal/policy/policy.go`, `catalog.PolicyEgress`). Status `effectiveEgress` holds those origins (`services/control-plane/internal/core/core.go`, `setFacts`). The chart and the controller turn them into a kagent `EgressPolicy`, which Agent Substrate's egress proxy `atenet-egress` enforces per sandbox actor. Proven on kind: an allowed host answered 200, others did not resolve or got 403 (ADR 0006, round 2).
- `atenet-egress` knows a caller as a Substrate actor (a sandbox session). It is configured through kagent `EgressPolicy` objects referenced by a kagent `Agent` (ADR 0006, F4 and F7). A container agent is neither.
- User env names that start with `OPENAGENTIX_`, `OPENAI_`, `OTEL_` or `KUBERNETES_` are refused (`ReservedEnvPrefixes` in `services/control-plane/internal/policy/container.go`). Proxy variables (`HTTPS_PROXY` and so on) are not refused today.
- Agent pods drop all capabilities, run as non-root and have no privilege escalation (ADR 0015). Without `NET_RAW` a process cannot open a raw socket, so it cannot write a packet with another source address.
- NetworkPolicy enforcement: kind's kindnet enforces policy toward cluster destinations but not toward the internet (`docs/diary/features/schedules.md`, `docs/diary/what-works.md`). k3s enforces ingress and internet egress; `hack/ci/netpol-test.sh` showed it in CI with a `busybox:1.37` client (`docs/diary/guide/install-k3s.md`). The platform does not check enforcement at install today.
- `install.sh` already derives API server addresses for NetworkPolicies: `CONTROL_PLANE_APISERVER_CIDRS`, `CONSOLE_APISERVER_CIDRS` and `KOURIER_APISERVER_CIDRS`, each with a value-file override (`components/channels/apiserver-cidrs.sh`). Its options are plain environment names; none starts with `OA_`.
- DNS: the agent's lookups go to kube-dns, which resolves outside names. ADR 0015 states this as an open outbound path. Pods get `ndots:5` and the cluster search path by default.
- The gate's route list pattern (ADR 0015): the controller writes only names into a ConfigMap; the component builds addresses from a template fixed by the chart. A compromised controller or ConfigMap can then only choose among things the operator already allowed. ADR 0016 (agent access, proposed on its branch) changes two details for a list that grants access: one ConfigMap key per grant with a short value, and a malformed or refused list means no grants, never the last good list.

## Options

### Where the traffic goes

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. A new small Go forward proxy, `services/egress-proxy`, standard library plus client-go for one watch, `CONNECT` only | Exactly the checks this record needs (allowlist by name, resolve and dial itself, refuse private addresses, SNI equals the host, one audit line per tunnel, per-agent caps). Same style as the A2A gate. Runs on any cluster | New code in the data path that we must maintain; about the size of the gate (*estimate*) | Design study only |
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
| K. Named destinations in the platform policy; the definition names them | The operator checks a short list of exact origins once; a definition can only point at it; no host text in a definition | One new definition field and one new policy key |
| L. Reuse `egress.allow` with origins matched against `allowedOrigins` | No new field | Policy patterns may hold wildcards, so each definition writes its own hosts inside them: per-agent free text, and an open-ended list for the proxy |

### How the proxy knows the caller

| Option | What it gives | What it costs |
|---|---|---|
| M. Source address, mapped through the agent's Service and the EndpointSlices the endpointslice controller writes | Addresses and the pod UID (`targetRef`) in one small object per Service; no read of pod specs | EndpointSlices and Services can be written by other users; this needs an admission policy on them (below) |
| N. Source address, mapped through a watch on Pods (UID, `status.podIPs`, labels) | One object kind; labels are visible directly | The proxy would read full pod specs of foreign agents, including literal env values, in a component that faces foreign code. `pods/status` is written by the kubelet, so a status policy is needed in any case. No smaller than M |
| O. A credential per agent (proxy password or token in `HTTPS_PROXY`) | Identity independent of addresses | HTTP clients read `HTTPS_PROXY` once and cannot refresh a token in it; a static password is one more long-lived secret, and the controller cannot read a Secret back |
| P. One proxy port per agent (ADR 0015's first idea) | Identity from the port | A port allocation contract and one ingress rule per agent in the proxy's namespace, written by the controller there; still depends on an enforcing network plugin |

## Decision

Options A, K and M. F (Cilium) stays open as a later adapter option. The rest are rejected for the reasons in the tables.

### Public names

- **Chart switch** `controlPlane.containerAgents.egressProxy.enabled`, default `false`. It needs `controlPlane.containerAgents.enabled`. With it false nothing new renders: no namespace, no proxy, no roles, no guard change, and the default chart render is byte-identical to before.
- **Namespace** `openagentix-egress` (value `controlPlane.containerAgents.egressProxy.namespace`). One Deployment `egress-proxy`, one replica, one Service on TCP port 3128. Pod Security `restricted`; the same pod settings as the A2A gate (non-root, read-only root, all capabilities dropped, `RuntimeDefault` seccomp). The proxy pod sets `dnsConfig.options: [{name: ndots, value: "1"}]`. No PodDisruptionBudget: with one replica a budget of one would block every node drain. A drain closes open tunnels (stated limit).
- **Policy key** `controlPlane.policy.egress.destinations`, default `{}`:

  ```yaml
  controlPlane:
    policy:
      egress:
        destinations:
          osv:                                  # a DNS label; the name a definition uses
            description: OSV open source advisories
            origins: ["https://api.osv.dev"]    # exact origins, 1..16 entries
  ```

  An origin has the same form as in `egress.allow` and `effectiveEgress`: `https://host` or `https://host:port`, nothing else. The host is a lower case public DNS name with a dot, without a trailing dot. No wildcard, no address, no path, no user info. Port 443 is implied when it is absent. The same internal-name rules as `egress.allow` apply (`catalog.InternalEgressHost`): `.svc`, `.cluster.local`, `.internal`, `.local` and the like are refused at render and when the controller loads the policy. At most 64 destinations. This key lives in the platform policy and moves with it into the `PlatformPolicy` kind (ADR 0007) when that kind is built.
- **Definition field** `spec.egress.destinations`: a list of destination names, at most 16, no duplicates.

  ```yaml
  spec:
    runtime: {type: container, container: {image: "...@sha256:..."}}
    egress:
      destinations: [osv]
  ```

  On a container agent each name must exist in the policy, and the chart switch must be on; otherwise the definition is refused with one sentence ("egress destination %q is not defined by the platform policy", "egress destinations are not available on this platform"). `egress.allow` stays refused for container agents. On a built-in agent `destinations` is refused for now ("egress.destinations is for container agents; use egress.allow"); expanding names into the kagent `EgressPolicy` can come later without a new field.
- **Status.** `effectiveEgress` lists the origins the agent may reach, in the same form as for built-in agents. A new capability `status.capabilities.networkEnforcement` says `checked-at-install`, `not-enforced` or `unknown` (see "Enforcement check"). It is set for every container agent, with or without destinations. It is a fact the installer measured, with its limits; the controller never guesses it.
- **Route list.** A ConfigMap `egress-proxy-routes` in the proxy namespace, one key per agent with destinations, in the layout of ADR 0016. The key is `<definition namespace>.<agent name>` (two DNS labels). The value is the agent's destination names separated by single spaces, sorted, at most 16 names. It holds names only, never hosts. The proxy reads the origins from its own configuration, rendered by the chart from the same policy key at install. So a compromised controller or ConfigMap can only give a listed agent a destination the operator already defined. The proxy mounts the directory (not `subPath`), reads it through the kubelet's `..data` link, checks it every 10 s and swaps its table atomically.
- **Pod labels.** `openagentix.io/egress-proxy: "true"` on the pod template of an agent with at least one destination. The existing `openagentix.io/agent: <name>` label becomes a protected label (see "Admission policies").
- **Pod environment**, set by the controller only for such an agent: `HTTPS_PROXY` and `https_proxy` set to `http://egress-proxy.<namespace>.svc.cluster.local:3128`, and `NO_PROXY` and `no_proxy` set to `.svc,.cluster.local`, the model gateway host and, with a profile, the tool server host. No `HTTP_PROXY` and no `ALL_PROXY`: plain HTTP to the internet is not offered.
- **Reserved env names.** User env names `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` and `NO_PROXY` are refused on every container agent, in upper, lower or mixed case, with the switch on or off. This is for clarity, so that an agent does not run with a proxy setting the platform did not write. It is not what keeps traffic in: the NetworkPolicy does that, whatever the agent sets.
- **Installer values**, written by `install.sh` when the switch is on, each with a value-file override: `egressProxy.apiServerCIDRs` (option `EGRESS_PROXY_APISERVER_CIDRS`, derived like `CONTROL_PLANE_APISERVER_CIDRS`) and `egressProxy.clusterCIDRs` (the pod CIDR, the Service CIDR, every node's internal and external address, and every LoadBalancer ingress address, read at install). With a Helm-only install the operator sets both; the render fails when the switch is on and `apiServerCIDRs` is empty.

### What the proxy does

For each connection from an agent pod:

1. **Before anything is read.** At most 8 connections per source address may be open without a finished `CONNECT`; more are closed at once. A source address that is not in the table (step 2) is closed after the refusal is counted. The request line and headers must arrive within 5 s and fit in 4 KiB.
2. **Who is calling.** The proxy maps the source address to an agent. It trusts only these objects, in the workload namespace:
   - Services whose name is an agent named in the route list and whose labels are the controller's (`app.kubernetes.io/managed-by: openagentix-control-plane`, the agent and definition labels);
   - EndpointSlices with `kubernetes.io/service-name` equal to such a Service and `endpointslice.kubernetes.io/managed-by: endpointslice-controller.k8s.io`;
   - endpoints in them whose `targetRef` is a Pod of the workload namespace.

   It watches both kinds with a namespaced Role (get, list and watch on `services` and `endpointslices` there, nothing else) and keeps a table from address to (agent, pod UID). Every address of an endpoint counts, IPv4 and IPv6 on a dual-stack cluster. Source addresses of the form `::ffff:a.b.c.d` are turned into `a.b.c.d` before the lookup. Endpoints that are not ready yet are included. The rules for change:
   - An address that two agents claim at once is refused for both (reason `address-conflict`) until only one claims it.
   - A terminating endpoint stays mapped to its original pod UID until it leaves the slice.
   - An address that leaves the table is quarantined for 60 s: requests from it are refused even if another pod gets it, so a watch that lags cannot hand a new pod the old pod's rights. Quarantine ends early only when the address comes back for the same pod UID.
   - An address that is not in the table gets 403.

   The labels alone do not make this true; the admission policies below do. There is no credential in the request (option O). This identity is weaker than the cryptographic token of ADR 0019, on purpose: to be taken for agent A, a caller must send from A's address. Only pods labelled by the controller reach port 3128 (the proxy's NetworkPolicy), only the controller can make such pods (the admission policies), and agent pods cannot forge source addresses (see "Residual risks"). So the caller must already be another opted-in agent pod on the same cluster, and the most it gains is A's destinations, which the operator already allowed for some agent.
3. **What is asked.** Only `CONNECT` in authority form (`host:port`) over HTTP/1.1. Any other method gets 405. Refused with 400: absolute or origin form, user info, an IP literal, percent-encoding, a missing port, a second request line, HTTP/1.0 or HTTP/2. The host is compared in lower case without a trailing dot. `host:port` must equal one of the origins of a destination the route list gives this agent (`https://api.osv.dev` means `api.osv.dev:443`). Otherwise 403.
4. **Where it goes.** The proxy resolves the name itself only after the check in step 3, so the agent cannot use the proxy as a lookup service. It asks for the fully qualified name with a trailing dot (`api.osv.dev.`), so the cluster search path is never tried. Every address it gets back must be outside the denied set; otherwise 403 with reason `private-address`. The denied set is:
   - IPv4: `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.0.0.0/24`, `192.0.2.0/24`, `192.168.0.0/16`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4`, `240.0.0.0/4`, and `168.63.129.16/32` (the Azure host address).
   - IPv6: `::/128`, `::1/128`, `fc00::/7`, `fe80::/10`, `ff00::/8`, `2001:db8::/32`, `100::/64`. An address in `::ffff:0:0/96` is unmapped and checked as IPv4. Addresses in NAT64 (`64:ff9b::/96`, `64:ff9b:1::/48`), 6to4 (`2002::/16`) and Teredo (`2001::/32`) are refused outright, because they carry an IPv4 address the proxy would otherwise not see.
   - The cluster: `egressProxy.clusterCIDRs`, `egressProxy.apiServerCIDRs`, and the ClusterIP of the `kubernetes` Service in `default` (read at install into the catalog).
   - Anything in `controlPlane.containerAgents.egressProxy.deniedCIDRs`.

   The same check runs again at socket time, in `net.Dialer.Control`, for every address the dialler tries. So no path inside the standard library can dial an address that was not checked. The proxy never resolves again for that tunnel. This closes DNS rebinding toward the cluster.
5. **TLS only, no decryption.** After `200 Connection established` the proxy reads the first TLS record from the agent: at most 5 s, at most one record (16 KiB plus header). It requires a ClientHello whose server name (SNI), in lower case and without a trailing dot, equals the requested host. No ClientHello, no SNI, another name, a ClientHello split across more than one record, or an Encrypted Client Hello extension: the tunnel is closed. Refusing a split ClientHello and ECH is intended; common clients send one record and no ECH to these hosts (*unverified* for clients with large post-quantum key shares). The bytes already read, and any bytes read with them, are written to the upstream before the two-way copy starts. Then bytes are copied both ways unchanged. The proxy holds no certificate authority and never decrypts. This blocks the simple form of domain fronting (an allowed address with another name in SNI). It cannot see the `Host` header inside TLS, so fronting at that layer on a shared CDN remains possible; see "Residual risks".
6. **Caps.** Defaults, all chart values under `controlPlane.containerAgents.egressProxy.limits`: 16 open tunnels per agent, 60 new tunnels per minute per agent, 1 GiB per agent per day in both directions together and, inside that, 256 MiB per day from agent to host, 3600 s per tunnel, 300 s idle, 512 tunnels in all. The global cap is shared fairly: once 80 % of it is in use, an agent gets a new tunnel only while it holds fewer than its share (the global cap divided by the agents with open tunnels). So one agent cannot take the whole proxy by staying under its own cap. A cap that is reached gets 429 for a new tunnel; the daily byte caps also close open tunnels. Counters live in memory and start again when the proxy restarts (stated limit, see one replica).
7. **Audit.** One JSON line on stdout when an allowed tunnel ends: time, agent (`namespace/name`), pod UID (from `targetRef`), destination name, origin, the address dialled, outcome, bytes each way, duration. The origin comes from the operator's list. Refusals are counted, not logged one by one: one line per agent per minute with the count per reason code, at most 120 refusal lines per minute in all, then one line that says how many were dropped. A refusal line never holds the asked host or any other text from the request. Reason: the asked host is chosen by the agent, and a log that is shipped elsewhere would be an outbound path. No content, no headers, no SNI beyond the allowed host.
8. **Its own network.** The proxy's NetworkPolicy admits on port 3128 only pods of the workload namespace with the label `openagentix.io/egress-proxy: "true"`. Its egress: DNS to kube-dns; TCP to `egressProxy.apiServerCIDRs` on 443 and 6443 (for its watch); and TCP to `0.0.0.0/0` and `::/0` except the denied set of step 4, on the ports that appear in the policy's destinations only. This is a second layer under step 4, on a cluster that enforces NetworkPolicy.

The proxy does not serve built-in agents. They keep Substrate's egress proxy.

### The agent's NetworkPolicy

An agent with destinations gets one more egress rule: the proxy pods (namespace and pod selector from the catalog) on port 3128. No `ipBlock`. Without destinations the policy is unchanged.

### DNS

The agent's lookups to kube-dns stay open until slice 5c. That is an outbound path: data can be encoded in names that kube-dns forwards to outside resolvers. It is slow and small (a few hundred bytes per lookup) but real, and it exists today for every container agent. This record states it and plans a fix as its own slice:

- **DNS lockdown** (value `controlPlane.containerAgents.dns`, `cluster` or `none`). With `none` the controller writes the pod with `dnsPolicy: None` and one nameserver `127.0.0.1` (nothing listens there, so a lookup fails at once), removes the kube-dns rule from the agent's NetworkPolicy, and adds `hostAliases` for the model gateway, the tool server and the proxy. Their Service addresses come from the catalog: `install.sh` reads them after the chart has created the Services and writes them in. The controller gains no read right. The guard pins `dnsPolicy`, the nameserver and each host alias to the catalog values. The agent then has no name resolution at all; the proxy resolves outside names for it. A Service that is deleted and created again gets a new address, and its agents fail closed until the next install (stated limit).
- When 5c lands, `none` becomes the default for every agent with destinations; `cluster` stays the default for agents without them until the open point below is settled.
- A filtering DNS server inside the proxy was considered. It needs a DNS parser (not in Go's standard library) in a component that faces foreign code. Rejected for now.

### Enforcement check

None of this holds where NetworkPolicy is not enforced: the agent then ignores the proxy and connects anywhere. The same is true today for every container agent, with or without the proxy. So the check runs whenever `controlPlane.containerAgents.enabled` is true:

- `install.sh` runs a live check (the steps of `hack/ci/netpol-test.sh`, moved to `hack/netpol-check.sh`) in a throwaway namespace. The client and target pods use the image in `controlPlane.containerAgents.networkCheck.image`, `busybox` pinned by digest by default; an air-gapped cluster sets a mirror. The steps:
  1. a TCP connection to a public address works, then fails under a deny-all egress policy;
  2. a TCP connection to a second pod in the namespace works, then fails under the same policy;
  3. on a dual-stack cluster, the same as step 1 over IPv6;
  4. with the proxy switch on, a pod without the `openagentix.io/egress-proxy` label cannot reach the proxy on port 3128.
- All blocked: the install goes on and writes `networkEnforcement: checked-at-install` with the date into the catalog.
- Any step not blocked (kind with kindnet, for example): the install stops with a message that names the step. `ALLOW_UNENFORCED_EGRESS=1` lets it go on and writes `not-enforced`; the console and status then say so.
- No internet from the cluster, so step 1 proves nothing: `unknown`, with a warning. The other steps still run and must pass.
- A Helm-only install, without `install.sh`: `unknown`.
- The check is a point in time. A network plugin changed later is not detected.

The quick start on kind therefore cannot turn the proxy on without the override. Live proof runs on k3s.

### Admission policies

All rules are allowlists and are executed in the guard tests and on a real API server.

**The controller's writes** (extends the ADR 0015 guard):

- **Deployment.** The pod template labels are one of four sets: `{agent}`, `{agent, tool-profile}`, `{agent, egress-proxy}`, `{agent, tool-profile, egress-proxy}`. The four proxy env names, upper and lower case, only on a pod with the `egress-proxy` label and with exactly the values above. The pod key allowlist gains `dnsPolicy`, `dnsConfig` and `hostAliases`; with DNS lockdown they hold exactly the catalog values, without it they are absent.
- **NetworkPolicy.** Egress has one to four rules in a fixed order: kube-dns (absent with DNS lockdown), the model gateway, the tool server (with a profile), the proxy (with destinations). The proxy rule names only the proxy namespace, pod selector and port. Still no `ipBlock` and no empty peer.
- **Route list ConfigMap** `egress-proxy-routes`: each key two DNS labels, each value a short pattern of names (at most 16, single spaces), at most 500 keys. The controller's Role allows get and patch on that one name only. Small values keep the cost of each check low; the guard tests measure it against the admission cost budget.
- The guard sees one object at a time, so it cannot check that a Deployment with the `egress-proxy` label has the matching NetworkPolicy rule and a route list entry. A mismatch fails closed: a label without the rule cannot reach the proxy; a rule without the label is refused by the proxy's ingress rule; an address without a route list entry gets 403.

**Everyone else in the workload namespace.** Like the policies of ADR 0019, these judge every user except the controller (whose writes the guard above judges) and the cluster's own controllers in kube-system (`system:kube-controller-manager` and `system:serviceaccount:kube-system:*`, which only copy templates judged here or write EndpointSlices from pods):

- `openagentix-workload-agent-identity`: no Pod, ReplicationController, Deployment, ReplicaSet, StatefulSet, DaemonSet, Job or CronJob may carry the label `openagentix.io/agent` or `openagentix.io/egress-proxy`, on create and on update (so an existing pod cannot be re-labelled). It also refuses `pods/ephemeralcontainers`, and optionally `pods/exec` and `pods/attach` (value `egressProxy.refuseExec`, default `true`), so no one can run a second process inside an opted-in agent pod and use its address.
- `openagentix-workload-endpoints`: no create, update or delete of `services`, `endpointslices` or `endpoints`, except Services by the controller and EndpointSlices and Endpoints by the kube-system controllers. This is what makes the proxy's trust in "Services named in the route list" and "EndpointSlices managed by the endpointslice controller" true.
- A cluster admin is refused by both. A cluster admin can still edit or delete the policies themselves; anyone with that right is trusted, as in ADR 0019.

**Proxy namespace.** The chart's objects only; nothing in the controller's roles touches it except the route list.

### Route list failure mode

The route list grants outbound access, so it follows ADR 0016, not the gate's route list:

- Missing, unreadable, or any key or value that does not parse, or more than 500 keys: the proxy uses an empty table (every request 403) and logs one line with the reason, never the content. A later valid list restores the table. It never keeps the last good list, because that could keep a removed destination alive.
- When a write is refused (by the guard or the API server), the controller next writes the empty list and sets the agent's condition. If it cannot write at all, the old list stays and status says so.

### Failure modes

| What fails | What the agent sees | Model and tools |
|---|---|---|
| Proxy down or restarting | Connection refused or reset for outside calls; open tunnels close; counters start again | Unaffected (`NO_PROXY`) |
| Route list not yet reloaded (kubelet refresh plus up to 10 s, *unverified*) | 403 for a new destination; a removed one keeps working until reload | Unaffected |
| Route list malformed, unreadable or missing | 403 for every agent | Unaffected |
| Destination removed from the policy (`helm upgrade`) | 403 for new tunnels; open tunnels to it are closed at reload | Unaffected |
| Name does not resolve, or resolves to a denied address | 502, or 403 with reason `private-address` | Unaffected |
| SNI missing, different, split, or ECH | Tunnel closed after the first record | Unaffected |
| A cap reached | 429 for new tunnels; byte caps also close open ones | Unaffected |
| Pod address not in the table yet (start-up race) | 403 until the EndpointSlice shows the address | Unaffected |
| Address claimed by two agents, or in quarantine | 403 with reason `address-conflict` or `quarantine` | Unaffected |
| Proxy cannot reach the API server | The table stops changing: new pods get 403, removed pods stay mapped. After 5 minutes without a working watch the proxy drops the whole table, and every request gets 403 | Unaffected |
| NetworkPolicy not enforced | The proxy is bypassed; everything is reachable | The install check stops or marks `not-enforced` |

Every failure closes. None opens a path.

### Conformance contract (addition to ADR 0015)

8. With destinations, reach outside hosts only through `HTTPS_PROXY` with `CONNECT`, with TLS, and with SNI set to the host. Go's `net/http` and Python's `requests` and `httpx` read `HTTPS_PROXY` by default. Node.js `fetch` does not (it needs an explicit proxy agent), *unverified for current versions*. The conformance checker gets a case for this.

### Residual risks, stated

- DNS lookups to kube-dns are an outbound path until DNS lockdown is on.
- Inside an allowed TLS tunnel the proxy sees nothing. An allowed host that accepts uploads is an outbound path for whatever the agent sends there. The allowlist decides which such hosts exist; the upload cap limits the amount.
- Shared-tenant hosts are the worst case of the point above: anyone can own a bucket, a repository or a webhook behind the same name. Examples: `s3.amazonaws.com`, `storage.googleapis.com`, `api.github.com`, `raw.githubusercontent.com`, `hooks.slack.com`. Allowing one of them lets the agent send data to any tenant of that host, not only the operator's. Guidance for operators: prefer a host name that belongs to one tenant (a bucket-specific or region-specific endpoint, a company domain); keep such destinations on few agents; watch the audit bytes for them. The chart prints a warning when a destination names one of a short built-in list of shared-tenant hosts.
- `Host`-header fronting inside TLS on a shared CDN is not visible without decryption.
- Identity rests on the pod address, the admission policies and NetworkPolicy. An agent pod cannot send with another pod's address: it has no capabilities, so no `NET_RAW` and no raw socket; and a TCP tunnel needs the SYN-ACK to come back, which the network sends to the real owner of the address. A plugin that also refuses spoofed source addresses is a further layer (*unverified* for kube-router on k3s and for kindnet).
- If the network applies source NAT on the path from a pod to a Service address, every caller looks like the node address. That address is not in the table, so every request gets 403: this fails closed, but the feature does not work there (*unverified* which plugins do this).
- Counters reset on restart; one replica means one failure point, and a node drain closes open tunnels.

### Slice plan

Every slice is tested first, off by default, keeps the default render byte-identical, and has a live proof, a diary entry and a changelog line. The proxy is security-relevant and gets an independent check by a person or a separate agent before merge.

1. **5a, the proxy alone.** `services/egress-proxy` with table tests: strict `CONNECT` parsing (each refused form), the allowlist by name, case and trailing dot, resolve-then-check (fake resolver: a name resolving to `10.0.0.1`, `169.254.169.254`, `::1`, `::ffff:10.0.0.1`, `64:ff9b::a00:1`, the API server address) and the dial-time check, SNI peek (none, other name, upper case, split record, ECH, a non-TLS first record, buffered bytes passed on), deadlines and size limits, per-source and per-agent caps, fair share of the global cap, the upload cap, audit lines (a canary string in a refused host and in tunnel bytes must not appear in the log; refusal lines are aggregated and capped), route list reload and every malformed case giving an empty table, the address table from a fake Service and EndpointSlice feed (a slice not managed by the endpointslice controller is ignored; a Service not in the route list is ignored; a conflict; quarantine; terminating endpoints; `::ffff:` sources). Image with a content tag. No chart change.
2. **5b-1, enforcement check and capability.** `hack/netpol-check.sh` with its four steps, the `ALLOW_UNENFORCED_EGRESS` override, the catalog fact, and `status.capabilities.networkEnforcement` for every container agent. Useful on its own: it closes the "the platform does not check for enforcement" gap of ADR 0015.
3. **5b-2, admission policies.** `openagentix-workload-agent-identity` and `openagentix-workload-endpoints`, with guard tests for each refusal and each allowed writer, and the API-server test. Live check on k3s of the kube-system user names that write EndpointSlices.
4. **5b-3, wiring.** Chart (switch, namespace, Deployment, Service, both NetworkPolicies, Role, route list, installer values), the policy key and the definition field, validation and status, the controller's env, label and rule, the reserved env names, the guard's Deployment, NetworkPolicy and route list rules. Live proof on k3s (`e2e-k3s`): an agent with `destinations: [osv]` reaches `https://api.osv.dev` through the proxy; `https://example.com` through the proxy gets 403; a direct connection to `1.1.1.1:443` from the agent pod times out; the audit line is present and holds no content; a second agent without the destination gets 403 for `api.osv.dev`; the model call still works; the time from a pod delete to the removal of its address from the table is measured and written down. The calls to `api.osv.dev` and `example.com` need the internet, so this proof runs as a manual or scheduled job and is not part of required CI.
5. **5c, DNS lockdown.** The `dns: none` mode, the installer step that writes the Service addresses, the guard rules, and `none` as the default for agents with destinations. Live proof on k3s: a lookup of an outside name fails in the pod, the model call and the tool call work, the outside call through the proxy works. The feature is not called done, in the README, the diary or `what-works.md`, before 5c is merged.
6. **Later, not in 0.3.** Cilium `toFQDNs` as an adapter option; `destinations` for built-in agents; a credential grant per destination (0.4, with the identity adapter); wildcard hosts.

## Amendments

- **ADR 0015, "Outbound access"** said: "Per-agent allowlists come in slice 5 through a small platform forward proxy, one port per agent." This record keeps the small proxy and drops "one port per agent" (option P). Reason: a port per agent needs a port allocation contract and an ingress rule per agent in the proxy's namespace, written by the controller there. The address table needs one ingress rule and no allocation, and it depends on NetworkPolicy no more than the port scheme does (both need an enforcing plugin). Cost: identity now also depends on the Service and EndpointSlice objects, which the new admission policies protect.
- **ADR 0015, "Admission guard and RBAC"** said NetworkPolicies have "egress only to DNS, the gateway and the profile server". With this record they may also have one rule toward the proxy, and with DNS lockdown the DNS rule is absent. Deployments may also carry the proxy env, the `egress-proxy` label and, with DNS lockdown, `dnsPolicy`, `dnsConfig` and `hostAliases`, each pinned as above.
- **ADR 0015, "Isolation, stated honestly"** said the platform does not check for enforcement. With slice 5b-1 it checks at install and reports the result as a capability.

## Consequences

- A container agent can call a few outside APIs the operator named, and the operator sees every tunnel.
- Each opted-in agent's outside traffic goes through one proxy pod: one more hop and one more failure point for those calls, none for model and tool calls.
- An operator must write each origin. There are no wildcards, so services with many host names are tedious to list. This is on purpose for 0.3.
- Every container agent gets an enforcement fact in status, and two new admission policies apply in the workload namespace when the proxy is on. Users who create Services, EndpointSlices or labelled pods there by hand are refused.
- Security impact: a new component that faces foreign code and has internet egress. It is closed by default at three levels (chart switch, an empty destination list, no definition opting in). The proxy has read rights on Services and EndpointSlices of the workload namespace only, no Secrets, no write rights. The controller gains get and patch on one ConfigMap. What leaves the cluster: TLS to the listed hosts, and DNS lookups until DNS lockdown is on. What is recorded: one line per tunnel and aggregated refusal counts, without content.
- Compatibility: nothing changes for existing users with the switch off, except the reserved env names. A container agent that set `HTTPS_PROXY`, `HTTP_PROXY`, `ALL_PROXY` or `NO_PROXY` itself, in any case, is refused after the upgrade and must drop them; with the feature off those variables could only point at an address the NetworkPolicy already blocks.
- Proof needed: as listed in the slices, plus chart tests (byte-identical default render, the enabled render, render failures for a bad origin, an internal name, a duplicate, an unknown destination name, an empty `apiServerCIDRs`), guard tests with the controller's real output and each denial, and the API-server test.

## Not checked / open points

- *Unverified*: whether agentgateway v1.7 can terminate `CONNECT` with a per-client host allowlist. If it can, option C should be compared again before slice 5a starts.
- *Unverified*: that EndpointSlices list a pod address before the pod is ready on kind and k3s, and how fast an address change reaches a watch.
- *Unverified*: the time from a pod delete to the removal of its address from the proxy's table on k3s. Measured in the 5b-3 proof; the 60 s quarantine may need to change.
- *Unverified*: the user names of the kube-system controllers that write EndpointSlices and copy pod templates on k3s (k3s runs them in one process; whether it uses `system:kube-controller-manager` or per-controller ServiceAccounts).
- *Unverified*: that kube-router (k3s) and kindnet refuse spoofed pod source addresses (a further layer; not relied on).
- *Unverified*: which network plugins apply source NAT on the pod-to-Service path, which would make every caller look like the node.
- *Unverified*: whether Calico's open-source edition supports domain names in policy.
- *Unverified*: which Node.js, Python and Go HTTP clients read `HTTPS_PROXY` and `NO_PROXY` the same way (case, port matching, suffix rules, a leading dot).
- *Unverified*: whether common clients ever split a ClientHello across records toward these hosts.
- Open: whether the default caps (16 tunnels, 60 per minute, 1 GiB and 256 MiB per day) fit real agents. They are guesses until an agent runs with them.
- Open: whether DNS lockdown should become the default for all container agents once it is proven, also for agents without destinations.
- Open: whether the proxy should run two replicas. Then the caps are per replica unless they are shared, which needs state; and a PodDisruptionBudget becomes possible.
- Open: whether to allow plain HTTP to a listed host (some internal mirrors). Not in 0.3.
- Open: whether the enforcement check should run again on a schedule, so a changed network plugin is noticed.
