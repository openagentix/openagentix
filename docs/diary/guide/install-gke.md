---
title: Install on GKE (draft, not run)
sidebar_position: 3.7
description: A desk study for issue 31. What a GKE Standard cluster needs that kind and k3s do not, current GKE facts with sources, the installer changes to make first, a runbook with teardown and a budget, and the live proof plan. Nothing on this page has been run.
---

# Install on GKE (draft, not run)

**Status: DRAFT. Not run. Nothing on this page has been tried on a GKE cluster.** It is a desk study for [issue 31](https://github.com/openagentix/openagentix/issues/31). It was written by reading the installer, the chart, the upstream charts (kagent 1.0.1, Agent Substrate 1.0.1) and Google's public documentation on 2026-11-26. No `gcloud`, `kubectl` or cluster command was run for it. Every command below is a plan. Every GKE fact is from a cited page, and the ones the sources did not confirm are marked *unverified*. Do not read this page as "GKE is supported".

The quick start does **not** install on GKE today. `install.sh` assumes a kind or k3d cluster in local Docker. The list of those assumptions, with file and line, is in [Install: managed cloud, known gaps](../features/install.md#managed-cloud-known-gaps-not-yet-run). The blockers must be fixed first (see [Installer changes to make first](#installer-changes-to-make-first)).

## The short answer

| Question | Answer from the desk study |
|---|---|
| Standard or Autopilot? | **Standard.** Google's Agent Substrate page says Autopilot is not supported. The atelet DaemonSet mounts host paths (`/var/lib/ate`, `/dev`, the kubelet plugin directories) and runs as root, which Autopilot refuses unless an allowlist covers it. |
| Node type | **`c3-standard-4`** (4 vCPU, 16 GB) or larger. Google's page says machine series with mixed CPU types, such as E2, cannot be used. So `e2-standard-4` is **not** a choice for the node that runs agents, although it is cheaper. |
| Node image | Container-Optimized OS with containerd (`COS_CONTAINERD`, the GKE default). Substrate's own guide talks about COS settings, so COS looks tested upstream. *Unverified* for our install. |
| Kubernetes version | 1.37 or newer on the control plane and every node pool (Substrate needs it; our installer pins 1.37 too). GKE 1.37 is in the Rapid channel since 2026-09-02 and in Regular since 2026-10-22 (release schedule page). |
| Network policy | GKE Dataplane V2 (Cilium based). Google's Substrate page lists it as a requirement, and NetworkPolicy is always enforced with it. |
| Images | Build for `linux/amd64`, push to Artifact Registry in the same project, give the node service account read access. No `imagePullSecrets` needed in that case. |
| Cost of one test | About 1.30 USD for a four-hour session on one `c3-standard-4` node (see [Cost estimate](#cost-estimate)). A cluster that is forgotten for a month costs about 230 USD (prices *unverified*). Use a budget alert and the teardown below. |

## How Agent Substrate's gVisor relates to GKE Sandbox

These are two different things. Do not mix them up.

- **Agent Substrate runs its own gVisor.** The atelet DaemonSet downloads a pinned gVisor release (`gs://gvisor/releases/release/20261026.0/...`, from the `substrate` chart's `sandboxconfig-gvisor.yaml`) and the worker pods (`ateworker-gvisor`) start sandboxes with it. Golden snapshots are taken and restored inside those workers. It needs no GKE feature.
- **GKE Sandbox** is a node pool option (`--sandbox type=gvisor`). It installs gVisor as the RuntimeClass `gvisor` on that pool. It needs `COS_CONTAINERD`, and it cannot be the only node pool or the default pool.
- **Where GKE Sandbox could fit:** only for bring-your-own container agents. The chart has `controlPlane.containerAgents.runtimeClassName` (empty by default). Setting it to `gvisor` on a cluster with a sandbox node pool would run container agents in GKE's gVisor. That needs a second node pool and is **not** part of the first run.
- *Unverified:* whether Substrate's workers start at all on a GKE Sandbox node pool (gVisor inside gVisor). Keep the worker node pool a normal pool.

## Current GKE facts, with sources

Read on 2026-11-26. Google's pages do not show a "last updated" date, so the date is the day they were read. Third-party price pages give their own update dates.

| Fact | What the source says | Source | Status |
|---|---|---|---|
| Agent Substrate on GKE: cluster mode | "Agent Substrate on GKE is supported on Standard clusters only"; "Autopilot clusters aren't supported" | [Install overview, Agent Substrate on GKE](https://docs.cloud.google.com/kubernetes-engine/ai-ml/install-overview-substrate) | confirmed from the page |
| Version | 1.37 or later on the control plane and the node pools; not the Extended channel | same page; [substrate-gke setup-gcp README](https://github.com/ai-on-gke/substrate-gke/blob/main/tools/setup-gcp/README.md) | confirmed from the page |
| Machine type | `c3-standard-4` or larger; no mixed CPU series such as E2 | same page | confirmed from the page |
| Dataplane V2 | listed as a requirement | same page | confirmed from the page |
| PodCertificateRequest and ClusterTrustBundle | Google's installer "turns on the beta `podcertificaterequests` and `clustertrustbundles` APIs"; substrate-gke creates clusters "with ... required Kubernetes beta APIs" | same page; substrate-gke README | confirmed that Google's tool enables them. Our `components/runtime/NOTES.md` says kind 1.37 serves them as `certificates.k8s.io/v1`. Whether GKE 1.37 serves v1 without the flag is *unverified* |
| Node auto-upgrade | "Turn node auto-upgrade off on any node pool that runs workers, and do not use spot or preemptible nodes for them" (a suspended actor can end up crashed) | substrate-gke setup-gcp README | confirmed from the page |
| Node sysctls | Google lists neighbour table and inotify limits only for more than about 800 sandboxes per node. `proxy_arp` and `proxy_ndp` are not mentioned | Substrate install overview; substrate-gke README | confirmed from the pages |
| `proxy_arp` through node system configuration | not in GKE's list of supported sysctls (the supported `net.ipv4.*` keys are TCP buffers and limits and `neigh.default.gc_thresh*`) | [Customizing node system configuration](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/node-system-config) | confirmed from the page. So if it is needed, a privileged DaemonSet must set it (substrate-gke names that option for its own sysctls) |
| Autopilot and privileged pods | Autopilot rejects privileged workloads and writable host paths unless a `WorkloadAllowlist` covers them; customer allowlists exist from GKE 1.35 and are installed from Cloud Storage | [Allowlists for privileged workloads in Autopilot](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/autopilot-privileged-allowlists), [About privileged workload admission](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-autopilot-privileged-workloads) | from search result summaries; the pages were not read in full. Moot, because Substrate does not support Autopilot |
| GKE Sandbox | `COS_CONTAINERD` only; not on the default pool; a pod picks it with RuntimeClass `gvisor` | [GKE Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/sandbox-pods), [Isolate workloads with GKE Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/sandbox-pods) | from search result summaries |
| Release schedule | 1.37: Rapid from 2026-09-02, Regular and Extended from 2026-10-22, Stable about 2027-01; end of standard support 2027-12-22. Clusters with no channel follow Regular availability | [GKE release schedule](https://docs.cloud.google.com/kubernetes-engine/docs/release-schedule) | confirmed from the page; the exact patch a new cluster gets is *unverified* |
| Management fee and free tier | 0.10 USD per cluster per hour; a credit of 74.40 USD per month per billing account, which covers one zonal Standard or one Autopilot cluster, not regional clusters and not compute | [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing), through search result summaries | *unverified*: the pricing page did not load for the fetch tool, and a Google blog says pricing tiers changed in September 2025 |
| `c3-standard-4` price | about 0.2016 USD per hour on demand in `us-central1` (about 147 USD per month) | [Holori](https://calculator.holori.com/gcp/vm/c3-standard-4/us-central1) (updated 2026-02-22), [Economize](https://www.economize.cloud/resources/gcp/pricing/compute-engine/c3-standard-4/) | *unverified*: third-party pages, not Google's price sheet |
| `e2-standard-4` price | about 0.134 USD per hour on demand in `us-central1` (about 98 USD per month) | [Holori](https://calculator.holori.com/gcp/vm/e2-standard-4) (updated 2026-03-03), [Economize](https://www.economize.cloud/resources/gcp/pricing/compute-engine/e2-standard-4/) (updated 2026-07-04) | *unverified*: third-party pages. Not usable for agent nodes (see above) |
| ValidatingAdmissionPolicy | GA in Kubernetes 1.30; GKE offers it from 1.30 at no extra cost | [Kubernetes blog](https://kubernetes.io/blog/2024/04/24/validating-admission-policy-ga/), [GKE: migrate from Policy Controller](https://docs.cloud.google.com/kubernetes-engine/docs/deprecations/policy-controller) | confirmed upstream; behaviour on GKE 1.37 with our guard policies is *unverified* |
| Pod Security admission | built in and on by default on GKE; namespaces without labels are not restricted | [GKE: PodSecurity admission](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/podsecurityadmission) | from search result summaries |
| Dataplane V2 and NetworkPolicy | built on Cilium; NetworkPolicy is always on; with Workload Identity and network policy, pods need egress to the metadata server | [Dataplane V2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2), [Network policy](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/network-policy) | from search result summaries. How a NetworkPolicy `ipBlock` matches the GKE control plane address was **not** found: *unverified* |
| Gateway API CRDs | `--gateway-api=standard` makes GKE install the standard CRDs; a third-party page says GKE 1.34.0-gke.1626000 and later install the GA CRDs on their own | [Deploying Gateways](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/deploying-gateways), [llm-d](https://llm-d.ai/docs/dev/resources/gateway/install-crds) | *unverified*: whether GKE 1.37 installs them by default, at which bundle version, and whether GKE reverts a self-applied bundle |
| Artifact Registry pulls | the node service account needs `roles/artifactregistry.reader`; then GKE pulls from repositories in the same project | [Artifact Registry: integrate with GKE](https://docs.cloud.google.com/artifact-registry/docs/integrate-gke) | from search result summaries |
| Service account issuer | read it with `kubectl get --raw /.well-known/openid-configuration`; on GKE it is a `container.googleapis.com` URL for the project, location and cluster | [Workload Identity Federation with Kubernetes](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes), [Pulumi GKE guide](https://www.pulumi.com/docs/administration/guides/oidc-issuers/kubernetes-gke/) | *unverified* for the exact form; read it from the cluster |
| Budgets | `gcloud billing budgets create --billing-account=... --display-name=... --budget-amount=... --threshold-rule=percent=0.50 --threshold-rule=percent=0.75,basis=forecasted-spend`; `--filter-projects=projects/<id>` limits it to one project | [gcloud billing budgets create](https://docs.cloud.google.com/sdk/gcloud/reference/billing/budgets/create) | confirmed from the page. A budget sends alerts; it does **not** stop spending |

Also read: the upstream [substrate-gke](https://github.com/ai-on-gke/substrate-gke) project, Google's installer for Substrate on GKE. It makes extra node pools for Substrate's own system parts and the bundled PostgreSQL by default (`e2-standard-4`), a `c3-standard-4` pool for workers, Workload Identity, GCS buckets for snapshots and a DNS-only control plane endpoint. Our quick start keeps Substrate's bundled RustFS for snapshots, so it does not need GCS or Workload Identity for a first run.

## Installer changes to make first

Each item is a proposed issue: small, testable offline (fake `kubectl`, `docker` and `gcloud` like `hack/ci/cluster-test.sh`, or a chart render test), and needs no cluster. Items 1 to 5 block the quick start on GKE. Items 1, 3, 4, 7, 8, 9 and 10 are now built and tested offline (marked **Built, offline only**); nothing of them was run on a cluster. A change to a chart value or a public switch needs an ADR first ([ADR rules](https://github.com/openagentix/openagentix/blob/main/docs/decisions/README.md)); those are marked.

1. **`CLUSTER_TYPE=remote` in `hack/cluster.sh`.** No create; `KUBE_CONTEXT` is required; `cluster_exists` asks the API server; `cluster_load_images` pushes instead of loading; `cluster_ctr` and `cluster_node` fail with a clear message; `cluster_delete_hint` says to delete the cluster with the cloud's own tool. Preflight stops needing `kind`, `k3d` or a local cluster tool. Test: extend `hack/ci/cluster-test.sh`. Public switch: note it in the ADR of item 2.
   **Built, offline only** (issue #161): `CLUSTER_TYPE=remote` needs `KUBE_CONTEXT`, refuses a local context name (`kind-*`, `k3d-*`, `docker-desktop` and a few others) unless `ALLOW_LOCAL_CONTEXT=1`, and stops before any change when that context's API server does not answer. `cluster_load_images` stops with a message instead of pushing (the push is item 2), so until item 2 exists `install.sh` refuses, before any build, a run that would build images. The ADR of item 2 is not written yet.
2. **`IMAGE_REGISTRY` and `IMAGE_PLATFORM` (default `linux/amd64` for remote).** Build with `docker buildx build --platform ... --push`, tag as today (`dev-<hash of source>`), and pass `--set-string <component>.image.repository=$IMAGE_REGISTRY/openagentix/<name>` to the chart. Required with `remote`, refused with kind and k3d. Test: a fake `docker` records the arguments; assert the `--set-string` lines and that nothing calls `kind load`. Needs an ADR (new installer contract).
3. **No `docker exec` on the node for remote.** `install.sh:270-271` and `components/runtime/up.sh:44-45` set `proxy_arp` and `proxy_ndp` through `docker exec` and stop the install (`set -e`) when there is no such container. For remote: skip them, and offer an opt-in DaemonSet `components/runtime/node-settings.yaml` (privileged, `hostNetwork`, sets the two sysctls, then sleeps) behind `NODE_SETTINGS=daemonset`. The first live run decides whether GKE needs it at all (NOTES.md says it was never proven necessary on kind). Test: the fake `docker` sees no `exec` with remote; `kubectl apply --dry-run=client` and a shell assert on the manifest.
   **Built, offline only** (issue #163): `cluster_node_settings` in `hack/cluster.sh`. Only the init container is privileged and only for the two writes; the container that stays is a non-root, read-only sleep. No API token, no toleration, its own namespace `openagentix-node-settings` (deleted by `uninstall.sh`). Not applied on any cluster; the `e2e` job checks it with a client dry run on kind.
4. **Substrate API authentication for an external issuer.** `components/runtime/up.sh:70-79` always writes `certificateAuthorityFile` and `discoveryTokenFile`. The comment at line 76 already says they must be omitted on GKE-style external issuers. Write them only when the issuer is `https://kubernetes.default.svc...`. Test: move the heredoc into a function and test both issuers.
   **Built, offline only** (issue #164): `components/runtime/auth-config.sh`, tested in `components/runtime/tests/run.sh` (kind's file byte-identical; a `container.googleapis.com` issuer without the two lines). Whether Substrate then accepts GKE tokens is *unverified*.
5. **The model gateway's Service must not become a public load balancer.** agentgateway makes the `model-gateway` Service of type `LoadBalancer` (`components/model-gateway/NOTES.md:19`; on kind it stays `<pending>`). On GKE that would create an external load balancer with a public IP in front of the model gateway, plus a firewall rule and an hourly charge. Set the Service to `ClusterIP` through agentgateway's Gateway parameters (`spec.infrastructure.parametersRef`; the exact field for agentgateway v1.7.0 is *unverified*). Test: chart render test that the Gateway references the parameters; byte-identical render when the value is unset. Needs an ADR (chart value).
6. **Bring your own agent on a registry.** `install.sh:254` names the sample image `registry.local/oa/echo-a2a` and `install.sh:807` reads its digest from the node with `hack/kind-image-digest.sh`. For remote: push to `$IMAGE_REGISTRY`, take the digest from the push, allow `$IMAGE_REGISTRY/` as the prefix instead of `registry.local/oa/`, and keep `imagePullPolicy: Always` (drop the `IfNotPresent` of `components/quickstart/byo-values.yaml:9`). Test: fake `docker` prints a digest; assert the AgentDefinition and the values.
7. **ServiceAccount issuer for the workload tool server.** `charts/openagentix/values.yaml:554-561` defaults the issuer to kind's `https://kubernetes.default.svc.cluster.local` and fetches the keys anonymously from the in-cluster API server. On GKE the issuer is a `container.googleapis.com` URL. The installer should read it from `/.well-known/openid-configuration` and set it, like the API server CIDRs today. Only needed with `QUICKSTART_BYO=1`. Test: a function over a JSON fixture. Whether GKE allows the anonymous key fetch is *unverified* (on k3s it failed, see `what-works.md`).
   **Built, offline only** (issue #167): `hack/sa-issuer.sh`, tested in `hack/ci/sa-issuer-test.sh` with the kind form and a GKE-style form. `install.sh` reads `/.well-known/openid-configuration`; if that gives nothing it reads the first `--service-account-issuer` flag of the kube-apiserver pod (a managed control plane has no such pod, so on GKE only the first source works); `SERVICE_ACCOUNT_ISSUER=<https URL>` overrides both. It sets `controlPlane.containerAgents.serviceAccountTokens.issuer` only when the chart renders its default (a values file that sets it wins) and the cluster's issuer is different, so kind and k3s renders do not change. It leaves `jwksUrl` alone: whether the keys can then be fetched anonymously from GKE's API server is the open question, and the run will show it. With `CLUSTER_TYPE=remote` the installer still refuses `QUICKSTART_BYO=1` (issue #162), so this step has no way to run on a remote cluster yet.
8. **Remote preflight.** Before anything changes: server version 1.37 or newer, the `certificates.k8s.io` resources `clustertrustbundles` and `podcertificaterequests` served, `validatingadmissionpolicies` served at `admissionregistration.k8s.io/v1`, a default StorageClass, no Gateway API CRDs at an older bundle than 1.6.3, and a warning that NetworkPolicy enforcement must be checked with `hack/ci/netpol-test.sh`. Test: fake `kubectl` outputs.
   **Built, offline only** (issue #168): `hack/preflight.sh`, tested in `hack/ci/preflight-test.sh` with a fake `kubectl` and JSON fixtures. `install.sh` runs it for `CLUSTER_TYPE=remote` before anything changes and stops on a FAIL (`SKIP_PREFLIGHT=1` skips it). You can run it alone: `KUBE_CONTEXT=<context> hack/preflight.sh`. It only reads (every call is `get`) and prints PASS, WARN or FAIL with a plain fix for each. FAIL: Kubernetes older than 1.37, `clustertrustbundles` or `podcertificaterequests` not served at `certificates.k8s.io` `v1` or `v1beta1`, `validatingadmissionpolicies` not served at `admissionregistration.k8s.io/v1`, no default StorageClass, no Ready node. WARN: a Gateway API bundle older than 1.6.3 or of unknown version, a node architecture that is not amd64, less than 3000m CPU or 6 GiB memory allocatable in total (an estimate, not measured), a target namespace that enforces `baseline` or `restricted`, a context that looks local, and always the NetworkPolicy line. That line names the dataplane DaemonSet it finds (for example `anetd`) and says a name is not proof; `hack/ci/netpol-test.sh` is the live check. Not run against any real cluster.
9. **`uninstall.sh` context.** `uninstall.sh:26` builds the context as `$CLUSTER_TYPE-$CLUSTER`. With remote it must use `KUBE_CONTEXT`. Test: shell test with a fake `kubectl`.
   **Built, offline only** (issue #169): every `kubectl` and `helm` call names the context; nothing is removed when the context is missing, not current after the switch, or (remote) not reachable; no cluster is deleted, and remote prints the teardown reminder. Test: `hack/ci/uninstall-test.sh`.
10. **Local-only model paths refused on remote.** `install.sh:130-133` points a local Ollama at `host.docker.internal` or the Docker network gateway. With remote, refuse `MODEL_PROVIDER=ollama` unless `MODEL_BASE_URL` is set. Test: shell test of `components/quickstart/model.sh`.
   **Built, offline only** (issue #170). With `MODEL_PROVIDER=ollama`, a set `MODEL_BASE_URL` is the Ollama URL.
11. **The example skill on remote (not needed for the quick start).** `install.sh:656-684` runs a `registry:2` container on the kind Docker network and pushes with `crane`. For remote: push the skill to `$IMAGE_REGISTRY` or require `SKIP_SKILL=1`. Test: fake `docker`.

## Runbook (not run)

Every step is a plan. Run it only after items 1 to 5 above are merged. Use a **new, dedicated project** so that deleting the project removes everything, and so the test cannot touch anything else. Values in angle brackets are yours. Do not paste project ids, billing account ids or emails into issue comments.

### 0. Tools on your machine

`gcloud` with the `gke-gcloud-auth-plugin` component, `kubectl` 1.37 or newer, `helm` 3, `docker` with `buildx`, `jq`, the Python `yq`, `openssl`, `curl`, `python3`. `components/runtime/up.sh` downloads `kubectl-ate` itself. You do not need `kind`.

### 1. A dedicated project and a budget

```sh
export PROJECT=<new-project-id> REGION=us-central1 ZONE=us-central1-a CLUSTER=oa-gke-test
gcloud projects create "$PROJECT"
gcloud billing projects link "$PROJECT" --billing-account=<billing-account-id>
gcloud services enable container.googleapis.com artifactregistry.googleapis.com billingbudgets.googleapis.com --project="$PROJECT"

# Alerts at 25, 50, 90 and 100 percent of 20 USD, and on the forecast. A budget only alerts; it does not stop spending.
gcloud billing budgets create --billing-account=<billing-account-id> --display-name="oa-gke-test" \
  --budget-amount=20USD --filter-projects="projects/$PROJECT" \
  --threshold-rule=percent=0.25 --threshold-rule=percent=0.50 --threshold-rule=percent=0.90 \
  --threshold-rule=percent=1.0 --threshold-rule=percent=1.0,basis=forecasted-spend
gcloud billing budgets list --billing-account=<billing-account-id> --filter="displayName=oa-gke-test"
```

Alerts go to the billing account's administrators by default. To send them elsewhere, add `--notifications-rule-monitoring-notification-channels`. Set yourself a deadline too: the teardown below is the only thing that stops the cost.

### 2. Node service account and image registry

```sh
gcloud iam service-accounts create oa-gke-node --project="$PROJECT"
SA=oa-gke-node@$PROJECT.iam.gserviceaccount.com
gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" --role=roles/container.defaultNodeServiceAccount
gcloud artifacts repositories create oa --repository-format=docker --location="$REGION" --project="$PROJECT"
gcloud artifacts repositories add-iam-policy-binding oa --location="$REGION" --project="$PROJECT" \
  --member="serviceAccount:$SA" --role=roles/artifactregistry.reader
gcloud auth configure-docker "$REGION-docker.pkg.dev"
```

*Unverified:* that `roles/container.defaultNodeServiceAccount` exists under this name and covers logging and monitoring for nodes. Without a dedicated account the nodes use the Compute Engine default account, whose roles depend on your organisation's policy.

### 3. The cluster: zonal, one node, Standard

```sh
gcloud container clusters create "$CLUSTER" --project="$PROJECT" --zone="$ZONE" \
  --release-channel=None --cluster-version=1.37 --no-enable-autoupgrade \
  --machine-type=c3-standard-4 --num-nodes=1 --image-type=COS_CONTAINERD \
  --disk-type=pd-balanced --disk-size=100 \
  --enable-dataplane-v2 --service-account="$SA" --workload-pool="$PROJECT.svc.id.goog" \
  --labels=purpose=oa-test
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" --project="$PROJECT"
export KUBE_CONTEXT=gke_${PROJECT}_${ZONE}_${CLUSTER}
```

Why each choice: zonal so the free tier credit can apply; one node because the quick start fits in 4 CPU and 8 GB on kind; `c3-standard-4` because E2 is refused; no release channel and no auto-upgrade because Substrate's workers should not be upgraded under a suspended actor; Dataplane V2 for NetworkPolicy and because Substrate on GKE requires it; on-demand, not spot.

*Unverified:* that `--cluster-version=1.37` resolves without a channel; that `--no-enable-autoupgrade` is allowed with `--release-channel=None`; that `pd-balanced` is allowed as the boot disk of a C3 node; and the CPU quota of a new project. If the certificate APIs are missing in step 4, add `--enable-kubernetes-unstable-apis=certificates.k8s.io/v1beta1/clustertrustbundles,certificates.k8s.io/v1beta1/podcertificaterequests` (flag and value *unverified*) and record that our scripts would then see `v1beta1`, not `v1`.

### 4. Read-only checks before the install

```sh
kubectl version -o json | jq -r .serverVersion.gitVersion
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{.items[*].spec.providerID}'; echo
kubectl api-resources --api-group=certificates.k8s.io
kubectl api-resources --api-group=admissionregistration.k8s.io
kubectl get storageclass
kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null; echo
kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes -o json | jq -r '.items[].endpoints[].addresses[]'
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
kubectl get pods -n kube-system -l k8s-app=kube-dns
hack/ci/netpol-test.sh
```

Expect: 1.37.x; one Ready node with a `gce://` provider id; `clustertrustbundles` and `podcertificaterequests` listed; `validatingadmissionpolicies` listed; a default StorageClass (marked `(default)`); kube-dns pods with the label the chart's DNS rules select; and `hack/ci/netpol-test.sh` exits 0 (ingress and egress enforced). Write every answer down for the report.

### 5. Install (target command, after the changes above)

```sh
CLUSTER_TYPE=remote KUBE_CONTEXT=$KUBE_CONTEXT \
IMAGE_REGISTRY=$REGION-docker.pkg.dev/$PROJECT/oa IMAGE_PLATFORM=linux/amd64 \
PROFILE=quickstart ./install.sh 2>&1 | tee gke-install.log
```

Then, once, `QUICKSTART_BYO=1` on top for the sample container agent. `CLUSTER_TYPE=remote` exists (item 1, tested offline only); `IMAGE_REGISTRY` and `IMAGE_PLATFORM` do not exist yet (item 2), so today this command stops before any build with a message that names the images. `NODE_SETTINGS=daemonset` may be added if the first run shows that sandboxes need the node sysctls (item 3).

### 6. Checks after the install

```sh
hack/ci/smoke.sh 2>&1 | tee gke-smoke.log                 # SMOKE_BYO=1 with the sample agent
hack/ask.sh quickstart "Look up known vulnerabilities of lodash 4.17.20 (npm)"
hack/demo.sh
kubectl get svc -A -o json | jq -r '.items[]|select(.spec.type=="LoadBalancer")|.metadata.namespace+"/"+.metadata.name+" "+((.status.loadBalancer.ingress//[])|tostring)'
kubectl get pods -A -o wide
kubectl get ds -n ate-system atelet
kubectl top nodes 2>/dev/null || true
```

The LoadBalancer line must print nothing. If it prints a Service with an address, delete that Service at once and record it as a failure.

## TEARDOWN

Do this the same day. Order matters: Services of type `LoadBalancer` and dynamically made disks can outlive a deleted cluster and keep costing money.

```sh
# 1. Inside the cluster: remove what makes cloud resources
kubectl get svc -A -o json | jq -r '.items[]|select(.spec.type=="LoadBalancer")|"-n "+.metadata.namespace+" "+.metadata.name' \
  | while read -r a b c; do kubectl delete svc $a $b $c; done
kubectl delete pvc --all -A --wait=true
kubectl get pv                                   # expect: No resources found

# 2. The cluster
gcloud container clusters delete "$CLUSTER" --zone="$ZONE" --project="$PROJECT" --quiet

# 3. Check that nothing billable is left
gcloud container clusters list --project="$PROJECT"                       # expect: empty
gcloud compute instances list --project="$PROJECT"                        # expect: empty
gcloud compute disks list --project="$PROJECT"                            # expect: empty
gcloud compute forwarding-rules list --project="$PROJECT"                 # expect: empty
gcloud compute addresses list --project="$PROJECT"                        # expect: empty
gcloud compute target-pools list --project="$PROJECT"                     # expect: empty
gcloud compute firewall-rules list --project="$PROJECT" --filter="name~^k8s"   # expect: empty

# 4. Images, then the project itself
gcloud artifacts repositories delete oa --location="$REGION" --project="$PROJECT" --quiet
gcloud billing projects unlink "$PROJECT"
gcloud projects delete "$PROJECT" --quiet
gcloud billing projects describe "$PROJECT"       # expect: billingEnabled false (or the project is not found)
gcloud billing budgets list --billing-account=<billing-account-id> --filter="displayName=oa-gke-test"
```

Delete the budget last (`gcloud billing budgets delete <budget-name>`), after the next day's billing data shows no new charges for the project. A deleted project stays recoverable for about 30 days; it is not billed in that time (*unverified*). Run the checks of step 3 again if you skip the project deletion.

## Cost estimate

All prices are *unverified* (see the table of facts). Region `us-central1`, on-demand, USD.

| Item | Unit price used | 4-hour session | Cluster forgotten for 30 days |
|---|---|---|---|
| Cluster management fee | 0.10 per hour | 0.40 (0 if the free tier credit is unused) | 72.00 (0 if the free tier credit is unused) |
| One `c3-standard-4` node | 0.2016 per hour | 0.81 | 145.15 |
| Boot disk, 100 GB `pd-balanced` | about 0.10 per GB per month | 0.06 | 10.00 |
| Volumes (Substrate PostgreSQL 5 GiB, kagent PostgreSQL 2 GiB, RustFS 1 GiB, bundled metrics; about 10 GiB `pd-balanced`) | about 0.10 per GB per month | 0.01 | 1.00 |
| Artifact Registry, about 2 GB of images | about 0.10 per GB per month after 0.5 GB free | 0.01 | 0.20 |
| An external load balancer, if gap 5 is not fixed | about 0.025 per hour per forwarding rule | 0.10 | 18.00 |
| **Total without the load balancer, without the free tier** | | **about 1.30** | **about 228** |
| **Total with the load balancer, without the free tier** | | **about 1.40** | **about 246** |

Assumptions: one zonal cluster, one node, no regional control plane, no GCS, no Cloud SQL, no logging beyond the free allotment, image pulls into Google Cloud free, little egress (the stub model makes no outside call). A real model key adds the provider's own charges. A 20 USD budget covers about ten sessions and alerts long before a forgotten cluster reaches the 30-day figure.

## Live proof plan

### What to record on issue 31

One comment, in this shape (no ids, no emails, no tokens):

```text
Cloud: GKE Standard, zonal, <region>
Kubernetes: <server gitVersion>   Node: c3-standard-4 x1, COS_CONTAINERD, <node version>
Network: Dataplane V2   netpol-test.sh: ingress <enforced|not>, egress <enforced|not>
Certificate APIs: <v1|v1beta1, enabled by flag or not>   Gateway API CRDs before install: <none|bundle x.y.z>
Repository commit: <sha>   Values: PROFILE=quickstart [QUICKSTART_BYO=1]
Command: <the exact install command>
Outcome: install <exit code> in <min:s>; quickstart Ready after <s>; smoke passed=<n> failed=<n>
Manual steps needed: <none | list>   LoadBalancer Services: <none | list>
Teardown: checks of step 3 empty <yes|no>; cost on the billing report: <USD>
```

Attach `gke-install.log` and `gke-smoke.log` after removing anything that names the project.

### What each check proves

| Check | What it proves on GKE |
|---|---|
| `hack/ci/netpol-test.sh` exits 0 | Dataplane V2 enforces NetworkPolicy for ingress and for egress to the internet, which the chart's isolation relies on |
| atelet DaemonSet Ready, worker pool Ready | Substrate's node agent runs on a COS node with its host paths, and its own gVisor starts |
| `AgentDefinition quickstart is Ready` | The control plane works, the runtime built a golden snapshot on the node (`/var/lib/ate` on COS), and the images came from Artifact Registry |
| "the gate returned an answer" and the tool call `osv_query_vulnerability` | A2A gate, TokenReview, model gateway virtual key and the tool profile work, and the policies let the control plane, gate and vMCP reach the API server at the derived `/32` |
| a tool outside the profile is refused | The tool profile holds on this cluster |
| a forbidden definition is refused, "no agent was built for it" | The control plane's policy and the ValidatingAdmissionPolicy guard run on GKE |
| console API: 401 without the token, lists `quickstart` with it, lists the profile | The console runs and reaches the API server through its NetworkPolicy |
| (with `QUICKSTART_BYO=1`) `echo-go` Ready, answers through the gate, pod settings as expected, bad images refused | A container agent pulled from a real registry by digest with `imagePullPolicy: Always`; the workload guard and Pod Security `restricted` on GKE |
| (with `QUICKSTART_BYO=1`) `tools: osv_query_vulnerability` from `echo-go` | The workload vMCP checks GKE's ServiceAccount tokens with the right issuer (gap 7) |
| no `LoadBalancer` Service, no external address | Nothing of the install is exposed to the internet |
| teardown checks all empty | The test left nothing that costs money |

### What counts as failure

- `install.sh` exits non-zero, or needs a manual `kubectl` patch, a deleted pod or a re-run to finish. Each manual step becomes its own issue.
- The quick start agent is not Ready within `AGENT_WAIT` (900 s), or any smoke check fails.
- `hack/ci/netpol-test.sh` reports that ingress or egress is not enforced.
- Any Service of type `LoadBalancer` with an external address, or any public endpoint other than the GKE control plane.
- Any step of the teardown leaves a disk, forwarding rule, address, instance or cluster, or the billing report shows more than the budget.
- Results that only hold with settings this page does not name.

Until that comment exists, GKE stays "not run" in `what-works.md` and the install page.
