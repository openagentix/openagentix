# ADR 0023: the model gateway Service type

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/165 (umbrella #31)
Replaces: none

A new chart value, `gateway.serviceType`, sets the type of the model gateway's Service through agentgateway's Gateway parameters. Its default is `ClusterIP` from release 0.3, with an upgrade note. A load balancer exists only when the operator writes `LoadBalancer`.

## Context

The model gateway is a Gateway API `Gateway` (`charts/openagentix/templates/gateway.yaml:4-19`, name `model-gateway` in `agentgateway-system`). The agentgateway controller reads it and creates the proxy Deployment and a Service of the same name. Facts:

- In this repository (commit `b6afd1d`): the Service is of type `LoadBalancer` and stays `<pending>` on kind (`components/model-gateway/NOTES.md:19`). Every client uses the cluster DNS name `model-gateway.agentgateway-system.svc.cluster.local` on port 80. Nothing in the chart or the installer uses a load balancer address. The chart renders no NetworkPolicy that limits who may reach the gateway's proxy pods.
- The first GKE run (`docs/diary/guide/install-gke.md`, 2026-11-26, remote mode from #176) gave the model gateway Service a public IP. It was the only public address of the install. A Helm-only install of the chart on a cloud gets the same from the default.
- On a managed cloud a `LoadBalancer` Service gets an external load balancer with a public IP, a firewall rule and an hourly charge. Virtual keys still apply (a call without a key gets 401, NOTES.md), but the gateway is open to key guessing, to load against the budgets, and to any bug in the proxy.
- `components/model-gateway/install.sh` and `components/model-gateway/manifests/00-gateway.yaml` (the standalone path of the first spike) apply a Gateway without `infrastructure`.
- ADR 0020 (proposed, pull request #135) pins the model gateway's Service address in the pod's `hostAliases` when DNS lockdown is on. A Service that keeps its cluster IP keeps that pin valid.

Facts read outside this repository on 2026-11-26, at the versions the installer pins:

- **agentgateway-crds v1.7.0** (chart `oci://cr.agentgateway.dev/charts/agentgateway-crds`, digest `sha256:946b739c0fcda4d47a72d1589d184b6fd507772e733cbedf02789bafd0468064`): kind `AgentgatewayParameters`, group `agentgateway.dev`, version `v1alpha1`, namespaced. `spec.service` has `metadata` (labels, annotations) and `spec`, "a complete or partial Kubernetes resource spec ... merged with the generated configuration using Strategic Merge Patch". The merge order is: class typed fields, Gateway typed fields, class overlays, Gateway overlays last. The CRD text names `Gateway.spec.infrastructure.parametersRef` as the way a Gateway points at it. There is no typed `service.type`; the type is set through the overlay `spec.service.spec.type`.
- **agentgateway chart v1.7.0**: `gatewayClassParametersRefs` defaults to `{}`, and `components/model-gateway/values.yaml` does not set it, so the class brings no parameters of its own.
- **agentgateway v1.7.0 source** (tag `v1.7.0`, commit `26f5aeb`), read, not run: the proxy Service template writes `type: {{ $gateway.service.type | default "LoadBalancer" }}`. The deployer test fixture `controller/test/deployer/testdata/agentgateway-both-gwc-and-gw-have-params.yaml` has a Gateway with `spec.infrastructure.parametersRef: {group: agentgateway.dev, kind: AgentgatewayParameters, name: gw-params}` and an `AgentgatewayParameters` with `spec.service.spec.type: ClusterIP`; its expected output is a Service of `type: ClusterIP`. A second way, `Gateway.spec.addresses[].routability: Cluster`, also gives `ClusterIP` in the code.
- **Gateway API v1.6.3 standard channel** (what the installer applies): `Gateway.spec.infrastructure` has `annotations`, `labels` and `parametersRef` (`group`, `kind`, `name`). `Gateway.spec.addresses[]` has only `type` and `value`; `routability` is not in the standard channel.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. A Gateway-level `AgentgatewayParameters` with `spec.service.spec.type`, referenced from `Gateway.spec.infrastructure.parametersRef`, from one chart value; default left to agentgateway (`LoadBalancer`) | A tested chart value; only our Gateway is affected; standard Gateway API field; default render unchanged | Every Helm-only cloud install, and the installer on remote unless it overrides, still gets a public IP | CRD schema and chart of v1.7.0 read; upstream fixture read; Gateway API v1.6.3 schema read |
| B. `Gateway.spec.addresses: [{routability: Cluster}]` | No extra object | Not in the standard-channel CRD; needs the experimental channel | agentgateway source and Gateway API schema read |
| C. Class-level parameters (`gatewayClassParametersRefs`) | One setting for the class | Lives in the upstream release, not our chart; a Helm-only install or `SKIP_PREREQS=1` does not get it | agentgateway chart read |
| D. A cloud annotation for an internal load balancer | No public IP | Still a load balancer with a charge and a VPC address; one annotation per cloud | not built |
| E. Patch the Service after the install | Nothing in the chart | The controller puts its own type back | rejected on reading |
| F. Option A with the default `ClusterIP`, in 0.3, with an upgrade note | Deny by default on every install path: installer, Helm only, every cloud; one code path on kind, k3d and remote | The default render changes; an existing user who reaches the gateway through its load balancer must set `LoadBalancer` on upgrade | as A |
| G. Do nothing | Nothing to build | A public IP in front of the model gateway on every cloud install | seen in the GKE run |

## Decision

Option F.

Why the default changes now. The project rule is deny by default, and a public load balancer in front of the model gateway is the opposite. The byte-identical rule protects users from a feature they did not turn on; here the default itself is the problem. Nothing in this project uses the load balancer: every client uses the cluster DNS name. Remote mode (#176) is in no release yet (not in v0.2.0), so no released installer path depends on the load balancer. The cost falls on a user who reaches the gateway from outside through its load balancer; the upgrade note tells them to write `LoadBalancer`.

### Chart value (public contract)

`gateway.serviceType`: `ClusterIP` (default) or `LoadBalancer`. Any other value fails the render with one sentence that names the two values: `""`, `NodePort`, `ExternalName` and a value with another case or spaces. `""` is refused because it would look like "unset" and silently give agentgateway's `LoadBalancer`. The only way to get a load balancer, on any cluster, is to write `LoadBalancer`.

With `gateway.enabled`, the chart renders one more object in `gateway.namespace`:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayParameters
metadata:
  name: <gateway.name>-parameters
  namespace: <gateway.namespace>
spec:
  service:
    spec:
      type: <gateway.serviceType>
```

and the Gateway gets
`spec.infrastructure.parametersRef: {group: agentgateway.dev, kind: AgentgatewayParameters, name: <gateway.name>-parameters}`.
The parameters object holds the Service type and nothing else. Proxy resources, replicas, `loadBalancerSourceRanges` and internal load balancer annotations are not part of this decision.

The value name is a Kubernetes word; no agentgateway word appears in the value.

### Installer

- No installer value is needed: the chart default covers kind, k3d and remote.
- After the chart is applied, the installer waits for `gateway/model-gateway` with `condition=Programmed`. If it does not come, the installer stops and prints the Gateway's `Accepted` condition. A `parametersRef` to a missing or bad object gives `Accepted=False` with reason `InvalidParameters`, and the message says to check `AgentgatewayParameters/<gateway.name>-parameters`.
- On remote, the checks after the install list every Service of type `LoadBalancer` in the cluster and warn for each, with the command that shows its address.
- `components/model-gateway/manifests/00-gateway.yaml` gets the same `AgentgatewayParameters` and `parametersRef`, and `NOTES.md:19` is updated, so the standalone path matches the chart.

### Upgrade note (CHANGELOG, 0.3)

"The model gateway Service is now `ClusterIP` (`gateway.serviceType`). On upgrade its load balancer is removed. If you reach the model gateway from outside the cluster through it, set `gateway.serviceType: LoadBalancer` before you upgrade, or use `kubectl port-forward`."

## Consequences

- A cloud install, through the installer or Helm only, creates no load balancer, no public IP, no firewall rule and no charge for them.
- Clients inside the cluster keep working: they use the DNS name and port 80, which a `ClusterIP` Service serves the same way, and the cluster IP stays the same on the type change (*unverified* on a cluster, see the test plan).
- **Security impact.** `ClusterIP` removes the public IP. It does not make the gateway private to the platform. Any pod in the cluster can connect, and on VPC-native GKE, pod and Service ranges can be reachable from the VPC and from peered networks. The virtual key is still the control. A NetworkPolicy that admits to the gateway's proxy pods only the agents, the platform components and the bundled metrics is a tracked follow-up, paired with ADR 0020's agent egress rules. On GKE a NetworkPolicy is enforced only with Dataplane V2 or with network policy enabled; `hack/preflight.sh` can check this. The new object holds no secret. Nothing new is recorded. `LoadBalancer` gives today's behaviour, written down.
- **Upstream contract.** The chart now depends on `AgentgatewayParameters` `v1alpha1` and its `spec.service.spec` overlay on every install. An agentgateway upgrade must read both again.
- **Compatibility.** The default render changes: one more object and one more Gateway field. The chart test that compares against a baseline render (`OA_BASELINE_RENDER`) is updated in the same pull request. On upgrade, the live Service changes type.

## Test plan

1. Chart tests (`charts/openagentix/tests/run.sh`), written first:
   - default: exactly one `AgentgatewayParameters` named `model-gateway-parameters` in `agentgateway-system` whose `spec` is exactly `{service: {spec: {type: ClusterIP}}}`; the Gateway's `spec.infrastructure.parametersRef` equals `{group: agentgateway.dev, kind: AgentgatewayParameters, name: model-gateway-parameters}`; apart from these two, the render is byte-identical to the previous default;
   - `LoadBalancer`: the same with that type;
   - `""`, `NodePort`, `ExternalName`, `clusterip` and `" ClusterIP"` each fail the render with the message;
   - `gateway.enabled=false`: nothing of this renders.
2. API-server test (`make test-apiserver`, throwaway kind cluster `oa-ci-test`): apply the Gateway API v1.6.3 standard CRDs and the agentgateway v1.7.0 CRDs, then `kubectl apply --dry-run=server` the two rendered objects. This proves the API server accepts the fields, not that the controller acts on them.
3. Upgrade test on a throwaway kind cluster: install with `gateway.serviceType=LoadBalancer`, record the Service's cluster IP, upgrade with the default; then check type `ClusterIP`, the same cluster IP, no `nodePort` on any port, and the Gateway `Programmed=True`.
4. Installer test (fake `kubectl`): a Gateway that never becomes `Programmed` stops the install with the `InvalidParameters` hint.
5. Live proof on a GKE run (#31): `kubectl get svc -n agentgateway-system model-gateway -o jsonpath='{.spec.type}'` prints `ClusterIP`; no Service of type `LoadBalancer` exists; `gcloud compute forwarding-rules list` is empty; the quick start smoke test passes. Not part of this record's acceptance.

## Slices

1. The chart value, its validation, the two rendered objects, the standalone manifest, `NOTES.md:19`, the changelog line with the upgrade note (tests 1 and 2). It does not wait for ADR 0022.
2. The `Programmed` wait and the remote `LoadBalancer` check in the installer (test 4).
3. The upgrade test on kind (test 3).
4. Follow-ups, each with its own change: the ingress NetworkPolicy for the gateway's proxy pods (with ADR 0020); a preflight check that NetworkPolicy is enforced on GKE; `loadBalancerSourceRanges` and an internal load balancer option for operators who set `LoadBalancer`.

## Not checked / open points

- *Unverified*: nothing has run on a cluster. The `ClusterIP` result comes from agentgateway's own deployer test fixture at tag v1.7.0, read, not run here. The CRD fields are confirmed from the v1.7.0 CRD chart.
- *Unverified*: the controller's behaviour on a live type change. Kubernetes drops fields that do not fit the new type (node ports) when the client did not set them; whether agentgateway's apply sets them, and whether GKE removes the load balancer and its firewall rule promptly, are what tests 3 and 5 show.
- *Unverified*: that the controller reports the Gateway `Accepted` and `Programmed` with the parameters. The fixture shows the rendered output, not the status.
- The CRD is `v1alpha1`. A newer agentgateway may rename or move the overlay. Read the CRD again on every agentgateway upgrade.
