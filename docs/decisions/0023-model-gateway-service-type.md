# ADR 0023: the model gateway Service type

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/165 (umbrella #31)
Replaces: none

A new chart value, `gateway.serviceType`, lets the operator make the model gateway's Service `ClusterIP` through agentgateway's Gateway parameters. The chart default stays as today. The installer sets `ClusterIP` on remote clusters, so a cloud install gets no public IP unless the operator asks for one.

## Context

The model gateway is a Gateway API `Gateway` (`charts/openagentix/templates/gateway.yaml:4-19`, name `model-gateway` in `agentgateway-system`). The agentgateway controller reads it and creates the proxy Deployment and a Service of the same name. Facts:

- In this repository (commit `662836c`): the Service is of type `LoadBalancer` and stays `<pending>` on kind (`components/model-gateway/NOTES.md:19`). Every client uses the cluster DNS name `model-gateway.agentgateway-system.svc.cluster.local` on port 80. Nothing in the chart or the installer uses a load balancer address. The chart renders no NetworkPolicy that limits who may reach the gateway's proxy pods.
- On a managed cloud a `LoadBalancer` Service gets an external load balancer with a public IP, a firewall rule and an hourly charge (`docs/diary/guide/install-gke.md`, "Installer changes to make first", item 5). The gateway then answers the internet. Virtual keys still apply (a call without a key gets 401, NOTES.md), but the gateway is open to key guessing, to load against the budgets, and to every bug in the proxy.

Facts read outside this repository on 2026-11-26, at the versions the installer pins:

- **agentgateway v1.7.0 CRDs** (chart `oci://cr.agentgateway.dev/charts/agentgateway-crds`, version `v1.7.0`, digest `sha256:946b739c0fcda4d47a72d1589d184b6fd507772e733cbedf02789bafd0468064`): kind `AgentgatewayParameters`, group `agentgateway.dev`, version `v1alpha1`, namespaced. `spec.service` has `metadata` (labels, annotations) and `spec`, "a complete or partial Kubernetes resource spec ... merged with the generated configuration using Strategic Merge Patch". The CRD text names `Gateway.spec.infrastructure.parametersRef` as the way a Gateway points at it. There is no typed `service.type` field; the type is set through the overlay `spec.service.spec.type`.
- **agentgateway v1.7.0 source** (tag `v1.7.0`, commit `26f5aeb`): the proxy Service template writes `type: {{ $gateway.service.type | default "LoadBalancer" }}` (`controller/pkg/helm/agentgateway/templates/service.yaml`). The deployer test `controller/test/deployer/testdata/agentgateway-both-gwc-and-gw-have-params.yaml` has a Gateway with `spec.infrastructure.parametersRef: {group: agentgateway.dev, kind: AgentgatewayParameters, name: gw-params}` and an `AgentgatewayParameters` with `spec.service.spec.type: ClusterIP`; its expected output (`...-out.yaml`) is a Service of `type: ClusterIP`. `controller/pkg/deployer/strategicpatch/strategicpatch_test.go` tests the same overlay turning a `LoadBalancer` Service into `NodePort`.
- **agentgateway v1.7.0 source**, second way: `SetServiceFromGatewayAddresses` (`controller/pkg/deployer/values_helpers.go`) makes a `ClusterIP` Service when `Gateway.spec.addresses` has one entry with `routability: Cluster`.
- **Gateway API v1.6.3 standard channel** (`standard-install.yaml` of the release, what `components/model-gateway/install.sh` applies): `Gateway.spec.infrastructure` has `annotations`, `labels` and `parametersRef` (`group`, `kind`, `name`) in `v1` and `v1beta1`. `Gateway.spec.addresses[]` has only `type` and `value`; there is no `routability` in the standard channel.
- The agentgateway Helm release the installer makes sets no `gatewayClassParametersRefs` (`components/model-gateway/values.yaml`), so the class brings no parameters of its own.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. A Gateway-level `AgentgatewayParameters` with `spec.service.spec.type`, referenced from `Gateway.spec.infrastructure.parametersRef`, rendered by our chart from one value | A chart value, so it is tested like every other; only our Gateway is affected; standard Gateway API field | One more object kind in the chart; the overlay is a strategic merge patch, not a typed field, so a typo in the type is not caught by the CRD | CRD schema of v1.7.0 read; upstream test fixture with exactly this input and a `ClusterIP` output read at tag v1.7.0; Gateway API v1.6.3 schema read. Not run on a cluster |
| B. `Gateway.spec.addresses: [{routability: Cluster}]` | No extra object | `routability` is not in the standard-channel CRD the installer applies, so the API server prunes or refuses it; would need the experimental channel for the whole cluster | agentgateway source and Gateway API v1.6.3 schema read |
| C. GatewayClass-level parameters through the agentgateway Helm value `gatewayClassParametersRefs` | One setting for every Gateway of the class | Lives in the upstream release the installer manages, not in our chart: a Helm-only install or `SKIP_PREREQS=1` does not get it; affects every Gateway of the class | agentgateway chart v1.7.0 `values.yaml` read |
| D. A cloud annotation for an internal load balancer (for example GKE's) | No public IP | Still a load balancer with a charge and a VPC address; cloud specific; one annotation per cloud | not built |
| E. Patch the Service after the install | Nothing in the chart | The controller owns the Service and puts its own type back | rejected on reading |
| F. Option A and change the chart default to `ClusterIP` now | Safe for everyone at once | Breaks the rule that the default render stays byte-identical; an existing user who reaches the gateway through its load balancer loses it on upgrade without asking | not built |
| G. Do nothing | Nothing to build | A public IP in front of the model gateway on every cloud install | not applicable |

## Decision

Option A. Option F is deferred (see open points).

### Chart value (public contract)

`gateway.serviceType`: `""` (default), `ClusterIP` or `LoadBalancer`. Any other value, `NodePort` and `ExternalName` included, fails the render with one sentence that names the allowed values. Case matters.

- `""`: nothing new renders. The Gateway has no `infrastructure` block. agentgateway picks the type as today (`LoadBalancer`). The default render is byte for byte as before.
- `ClusterIP` or `LoadBalancer`: the chart renders one more object in `gateway.namespace`,

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
  The parameters object holds the Service type and nothing else. Other proxy settings (resources, replicas, image) are not part of this decision.

`LoadBalancer` exists so that an operator who wants a load balancer says so in a values file, and the choice is visible in review. The word is a Kubernetes word; no agentgateway word appears in the value.

### Installer

- With `CLUSTER_TYPE=remote` (ADR 0022) the installer renders the chart first. When the merged values leave `gateway.serviceType` empty, it adds `--set-string gateway.serviceType=ClusterIP`. A value set in a `VALUES_FILE` (also `LoadBalancer`) is never overridden.
- The installer's checks after a remote install list every Service of type `LoadBalancer` in the cluster and warn for each, with the command that shows its address. The GKE guide already treats a `LoadBalancer` line as a failure.
- kind and k3d: unchanged in this slice. The quick start render on kind does not change.

### Defaults

Off by default. The chart default render and the kind and k3d installs are unchanged. The secure behaviour, no public IP, is the default for remote clusters through the installer, which is the only supported way onto a remote cluster today.

## Consequences

- A cloud install of the quick start does not create a load balancer, a public IP, a firewall rule or the charge for them.
- Clients inside the cluster keep working: they use the DNS name and port 80, which a `ClusterIP` Service serves the same way (*unverified* on a cluster).
- A user who reaches the model gateway from outside the cluster through its load balancer must set `gateway.serviceType: LoadBalancer`, or use `kubectl port-forward`. On remote clusters this is a change from what agentgateway alone would do; the installer says so in its final output.
- **Security impact.** `ClusterIP` removes the internet path to the model gateway. It does not limit who inside the cluster may call it: any pod can still connect, and the virtual key is still the control. A NetworkPolicy for the gateway's proxy pods is a separate question (open points). The new object holds no secret. Nothing new is recorded. The value cannot open anything that the default does not already open: `LoadBalancer` is today's behaviour, stated explicitly.
- **Upstream contract.** The chart now depends on `AgentgatewayParameters` `v1alpha1` and its `spec.service.spec` overlay. An agentgateway upgrade must check both again. With the value empty the chart uses neither.
- **Compatibility.** Nothing changes for existing installs. An operator who later sets `ClusterIP` on a running install changes the type of a live Service. Kubernetes keeps the cluster IP and drops the node ports on such a change, and the cloud removes the load balancer (*unverified*, see open points).

## Test plan

1. Chart tests (`charts/openagentix/tests/run.sh`), written first:
   - default: no `AgentgatewayParameters`; the Gateway has no `infrastructure`; the whole default render is byte-identical (also with `OA_BASELINE_RENDER`);
   - `gateway.serviceType=ClusterIP`: exactly one `AgentgatewayParameters` named `model-gateway-parameters` in `agentgateway-system` whose `spec` is exactly `{service: {spec: {type: ClusterIP}}}`; the Gateway's `spec.infrastructure.parametersRef` equals `{group: agentgateway.dev, kind: AgentgatewayParameters, name: model-gateway-parameters}`; nothing else in the render changes;
   - `LoadBalancer`: the same with that type;
   - `NodePort`, `ExternalName`, `clusterip` and `" ClusterIP"` each fail the render with the message;
   - `gateway.enabled=false`: nothing of this renders.
2. Installer test (fake `helm`, `kubectl`, `docker`): with `remote` and no value, the `helm upgrade` arguments contain `--set-string gateway.serviceType=ClusterIP`; with `LoadBalancer` in a values file, they do not; with kind and k3d, the arguments are the same as before.
3. API-server test (`make test-apiserver`, throwaway kind cluster `oa-ci-test`): apply the Gateway API v1.6.3 standard CRDs and the agentgateway v1.7.0 CRDs, then `kubectl apply --dry-run=server` the two rendered objects. This proves the API server accepts the fields, not that the controller acts on them.
4. Live proof with the GKE run of #31: `kubectl get svc -n agentgateway-system model-gateway -o jsonpath='{.spec.type}'` prints `ClusterIP`; no Service of type `LoadBalancer` exists; the quick start smoke test passes. Not part of this record's acceptance.

## Slices

1. The chart value, its validation and the two rendered changes (test 1). Changelog line.
2. The installer default for remote and the `LoadBalancer` check after the install (test 2), with ADR 0022 slice 1.
3. The API-server schema check (test 3).
4. Later, each after a live check: the quick start sets `ClusterIP` on kind and k3d too; the chart default becomes `ClusterIP` in a release, with an upgrade note.

## Not checked / open points

- *Unverified*: nothing has run on a cluster. The `ClusterIP` result comes from agentgateway's own deployer test at tag v1.7.0, read, not run here.
- *Unverified*: changing a live `LoadBalancer` Service to `ClusterIP` through the controller. Kubernetes drops fields that do not fit the new type (node ports) when the client did not set them; whether agentgateway's apply sets them, and whether GKE removes the load balancer and its firewall rule promptly, needs the live run.
- *Unverified*: that the controller reports the Gateway `Accepted` with the parameters and does not set `InvalidParameters`. The test fixture shows the rendered output, not the status.
- Open: should the chart default become `ClusterIP`? It is the safer default and nothing in this project uses the load balancer. It breaks the byte-identical rule and could cut off an existing external user, so it needs a release with an upgrade note and a decision of its own.
- Open: should the quick start on kind and k3d set `ClusterIP` too, so every install has the same Service? On kind the pending load balancer is harmless. It needs a live upgrade test on kind first.
- Open: a NetworkPolicy that admits to the gateway's proxy pods only the agents, the platform components and the bundled metrics. Today any pod in the cluster may connect. Out of scope here.
- Open: ADR 0020 reads every `LoadBalancer` ingress address into the egress proxy's denied ranges. With `ClusterIP` there is none; nothing to change, noted so the two records agree.
- The CRD is `v1alpha1`. A newer agentgateway may rename or move the overlay. Read the CRD again on every agentgateway upgrade.
