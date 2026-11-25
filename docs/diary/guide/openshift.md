---
title: OpenShift
sidebar_position: 3.6
description: What the chart changes with platform openshift, what was checked, what cannot work on OpenShift today, and what only a real cluster can prove. Nothing here has been run on OpenShift.
---

# OpenShift

**Status: manifests render and follow restricted-v2; not run on OpenShift.** No OpenShift cluster was used. Every claim below comes from reading the manifests and from render tests (`charts/openagentix/tests/run.sh`). Do not read this page as "OpenShift is supported".

This page is the result of issue #32. It says what the chart does with `platform: openshift`, what it cannot do, and what a real cluster still has to show.

## Turn it on

```sh
helm upgrade --install openagentix charts/openagentix -n openagentix-system --set platform=openshift
```

`platform` is empty by default. An empty value and `kubernetes` give exactly the render the chart gave before (a test compares the hash of the render, with and without every demo feature on). Any other value fails the render.

## What `platform: openshift` changes

OpenShift's default SCC for ordinary pods is `restricted-v2`. It assigns the user id and the group id from a range that belongs to the namespace, and it refuses a pod that asks for an id outside that range.

| Area | Default | With `platform: openshift` |
|---|---|---|
| `runAsUser`, `runAsGroup` | Fixed ids (65532, 65534, 10001, 999) in every pod | Left out in every pod. `runAsNonRoot: true` stays |
| `fsGroup` | 65532 or 999 on pods with a volume | Left out. OpenShift assigns it from the namespace range |
| `seccompProfile` | `RuntimeDefault` | Same (restricted-v2 allows it) |
| `allowPrivilegeEscalation`, `capabilities.drop`, `readOnlyRootFilesystem` | `false`, `ALL`, `true` | Same. They already match restricted-v2 |
| DNS egress in the control plane, console and notify NetworkPolicies | `kube-system`, `k8s-app=kube-dns`, port 53 | `openshift-dns`, `dns.operator.openshift.io/daemonset-dns=default`, port 5353 (a NetworkPolicy sees the pod port, and the OpenShift DNS pods listen on 5353) |
| Console | ClusterIP, no ingress, `kubectl port-forward` | Same, plus an optional `Route` (below) |
| `controlPlane.containerAgents` | Optional | Refused: the render fails with a reason |

The chart has no `hostPath`, `hostNetwork`, `hostPID` or `privileged` anywhere, and a test checks this for the full demo render. Because of that, no `anyuid` or `privileged` SCC binding and no extra ServiceAccount binding is needed for the chart's own pods. The chart does not create any SCC and does not ask you to.

### Route for the console

```yaml
platform: openshift
console:
  route: {enabled: true, host: oa-console.apps.example.com}
```

This adds one `Route` (`route.openshift.io/v1`, edge TLS, plain HTTP redirected) to the console Service. The host is required. The chart adds it to the console's allowed host list (the console answers 421 to any other Host). The console NetworkPolicy then admits ingress on port 8080 from namespaces that carry the label `network.openshift.io/policy-group: ingress` (the router), and from nowhere else. Without the Route, the console still admits no ingress. `console.route` without `platform: openshift` fails the render.

There is no Route for the other services (the A2A gate, the model gateway). They are reached inside the cluster, as before.

## What cannot work on OpenShift today

These are findings from reading the code and the manifests. They are not test results.

1. **Container agents (`controlPlane.containerAgents`).** The controller writes the agent pod with `runAsUser: 65532`, and the admission guard accepts only that value. restricted-v2 refuses a pod with an id outside the namespace range, so the pod would not start. Fixing this means a code change in the controller adapter and in the guard (a platform setting that leaves the ids out), with tests and an ADR, because it changes a public contract. The chart refuses this combination for now.
2. **The sandbox runtime (kagent on Agent Substrate with gVisor).** The installer prepares a kind node with `docker exec ... sysctl net.ipv4.conf.all.proxy_arp=1` and the sandbox worker is a gVisor (`runsc`) worker. OpenShift nodes are not reachable that way. Setting the same sysctls needs a MachineConfig or a tuned profile, and gVisor needs a runtime handler on the node, which OpenShift does not offer (the supported sandbox on OpenShift is Kata, through the sandboxed containers operator, which is a different runtime that Substrate does not use). The Substrate and kagent charts are upstream. Their pods very likely need an SCC beyond restricted-v2. This was not checked against their manifests. Treat the sandbox runtime as not working on OpenShift until someone proves otherwise.
3. **`controlPlane.containerAgents.runtimeClassName`.** The chart passes the name through. OpenShift has no gVisor RuntimeClass. The name `kata` exists only with the sandboxed containers operator, and nothing here tested it.
4. **PostgreSQL pods with the stock images.** The knowledge base database (`knowledge.yaml`) and the installer's own databases (`components/runtime/manifests/kagent-postgres.yaml`, `substrate-postgres/postgres.yaml`) use the upstream `pgvector` and `postgres` images. These images expect a user that exists in `/etc/passwd` (999 or 70). On OpenShift the pod gets an arbitrary id that is not in the image, and `initdb` stops with "could not look up effective user ID". With `platform: openshift` the chart leaves the id out for the knowledge base database, so the pod is admitted, but it will probably fail to start with the stock image. An image built for arbitrary ids (or an external database) is needed. The installer's databases under `components/` are not changed by this work: `substrate-postgres/postgres.yaml` pins `runAsUser: 70` and `fsGroup: 70`, and `kagent-postgres.yaml` sets no security context and starts as the image's root user, which restricted-v2 does not allow.
5. **`install.sh`.** It creates kind or k3d clusters and builds images into them. It does not install on an existing OpenShift cluster. Use the chart directly, with images you push to a registry that the cluster can pull from (`image.repository` values; the defaults are short names such as `openagentix/console:dev`, which CRI-O may refuse or resolve to a registry you did not mean).
6. **Other upstream pieces** (kagent, agentgateway, ToolHive, Kourier and the Gateway API CRDs). Their OpenShift support was not looked at. The model gateway uses the Gateway API (`Gateway`, class `agentgateway`). OpenShift ships its own Gateway API implementation in recent releases, which could clash with these CRDs. Not checked.

## Other differences to know about

- **Namespace labels.** The NetworkPolicies select namespaces with `kubernetes.io/metadata.name`. OpenShift 4.x sets this label on every namespace, so the selectors work. It is not tested here.
- **Namespaces and ids.** The namespaces are made by you (the chart does not create them). On OpenShift a project gets its id range when it is created. A plain namespace made with `oc create namespace` gets one too.
- **API server egress.** The control plane and console policies need the API server addresses (`controlPlane.apiServerCIDRs`, `console.apiServerCIDRs`). `install.sh` fills these in on kind and k3d. On OpenShift you set them yourself to the control plane node addresses (port 6443). If you leave them empty, the policy opens the API server ports to any address (the existing fallback).
- **ValidatingAdmissionPolicy.** The admission guard uses `ValidatingAdmissionPolicy`, which needs a Kubernetes version that serves it (OpenShift 4.17 or newer).
- **Kubelet probes** are not blocked by NetworkPolicy, as on other clusters.

## What a real cluster has to prove

Nothing below has been done. Each item needs an OpenShift 4.17 or newer cluster, a project, and a registry.

1. `helm install --set platform=openshift` leaves every chart pod Running with restricted-v2 and no SCC change. Run `oc get pod -o yaml | grep openshift.io/scc` and expect `restricted-v2` for all of them.
2. Each pod runs as an id from the namespace range, and the Secret volumes that were read through `fsGroup` (the key hashes, the console token) are readable.
3. DNS works from the control plane, console and notify pods with the NetworkPolicies on (port 5353 to `openshift-dns`).
4. The console Route answers over TLS, a pod in another namespace cannot reach port 8080, and the router can.
5. The control plane reaches the API server with `controlPlane.apiServerCIDRs` set to the real addresses.
6. The knowledge base database starts with an arbitrary id (this needs a suitable image).
7. Whether the sandbox runtime has any path at all on OpenShift (see item 2 above).

When any of these is run, the result goes in [what works](../what-works.md) with the cluster version.
