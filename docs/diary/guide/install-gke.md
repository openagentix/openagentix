---
title: Install on GKE (run once)
sidebar_position: 3.7
description: The quick start was installed once on a GKE Standard cluster on 2026-11-26, with the images built in Cloud Build by hand. The runbook as it was run, the timings, what it proved and what it did not, the teardown, and the helper scripts in hack/gke.
---

# Install on GKE (run once)

**Status: run once on 2026-11-26; result recorded.** The quick start (stub model, no provider key) installed on one GKE Standard cluster and passed the smoke test, the NetworkPolicy test and the demo. The cluster lived about 21 minutes; then the whole project was deleted. This is [issue 31](https://github.com/openagentix/openagentix/issues/31).

Read the limits before you read this as "GKE is supported":

- **The images were a manual step.** They were built in Cloud Build and passed to the chart in a values file, and the installer was told not to build them (`SKIP_*_IMAGE=1`). The installer's own registry mode (`IMAGE_REGISTRY`, [issue 162](https://github.com/openagentix/openagentix/issues/162), ADR 0022) was added after this run and is tested offline only; it has not been run on GKE.
- **One manual `kubectl` patch was needed:** the new cluster had no default StorageClass, and the preflight stopped the install until one was marked.
- **The model gateway's Service got a public load balancer address.** This is the known gap ([issue 165](https://github.com/openagentix/openagentix/issues/165), ADR 0023 in [PR 173](https://github.com/openagentix/openagentix/pull/173)). Nothing else of the install was exposed.
- One run, one node, one zone, about 21 minutes. Not shown: a real model, bring your own agent, Autopilot, GKE Sandbox, arm64, a long run, the console in a browser. The full list is in [What was not shown](#what-was-not-shown).

The helper scripts in [`hack/gke/`](https://github.com/openagentix/openagentix/tree/main/hack/gke) repeat the run in a new project and delete it at the end. They were written from this run afterwards and are tested offline only (a fake `gcloud`); they have not been run against a real project yet.

## Result at a glance

| Item | Value |
|---|---|
| Cluster | GKE Standard, zonal, `us-central1-a`, release channel `rapid` |
| Kubernetes | `1.37.2-gke.1606000` |
| Node | 1 × `c3-standard-4` Spot, `COS_CONTAINERD`, `pd-balanced` 60 GB boot disk |
| Network | Dataplane V2; `hack/ci/netpol-test.sh`: ingress **enforced**, egress to the internet **enforced** |
| Control plane access | master authorized networks limited to the operator's address; managed Prometheus off |
| Images | 4 (`a2a-gate`, `stub-model`, `control-plane`, `console`) for `linux/amd64` from Cloud Build, in Artifact Registry, tag `gke1` |
| Preflight (`hack/preflight.sh`) | first: 8 pass, 1 warn, 1 fail (no default StorageClass); after the patch: 9 pass, 1 warn, 0 fail |
| Install | `install.sh` in remote mode, exit 0 in 625 s; `AgentDefinition quickstart` Ready at +625 s |
| Smoke test | `hack/ci/smoke.sh`: 13 passed, 0 failed, 32 s |
| Demo | `hack/demo.sh`: "every step showed what it should" |
| Pods | 49, all Running |
| Public addresses | one: the model gateway Service (type `LoadBalancer`, the known gap) |
| Teardown | `gcloud projects delete`: 37 s to `DELETE_REQUESTED`; billing disabled |
| Cost | not read yet (billing data comes with a delay); expected well under 1 USD, **not measured** |

## Timings

| Step | Time | Note |
|---|---|---|
| `gcloud container clusters create` | 7.4 min (about 442 s to `RUNNING`) | one node |
| Cloud Build, four images, built and pushed | 1 min 21 s | ran at the same time as the cluster create |
| `install.sh` (remote, quick start) | 625 s (10 min 26 s) | `AgentDefinition quickstart` Ready at +625 s |
| `hack/ci/smoke.sh` | 32 s | 13 passed, 0 failed |
| `gcloud projects delete` | 37 s | to `DELETE_REQUESTED` |
| Cluster lifetime | about 21 min | from the create command to the project delete |

For comparison, the same quick start reaches its first answer in 301 to 320 s on kind in CI. Why the install took longer on GKE was not analysed.

## Runbook, as it was run

Values in angle brackets are yours. Do not paste project ids, billing account ids, organisation ids, addresses or emails into issues. Use a **new, dedicated project**: deleting it removes everything, and the test cannot touch anything else. `hack/gke/up.sh` does steps 1 to 5 for you (see [Helper scripts](#helper-scripts)).

### 0. Tools on your machine

`gcloud` with the `gke-gcloud-auth-plugin` component, `kubectl` 1.37 or newer, `helm` 3, `jq`, the Python `yq`, `openssl`, `curl`, `python3`. No local Docker build is needed for this path: Cloud Build builds the images. You do not need `kind`.

### 1. A new project, billing, APIs and a budget

```sh
export PROJECT=<new-project-id> REGION=us-central1 ZONE=us-central1-a CLUSTER=<cluster>
gcloud projects create "$PROJECT" --organization=<organisation id>
gcloud billing projects link "$PROJECT" --billing-account=<billing account>
gcloud services enable container.googleapis.com compute.googleapis.com artifactregistry.googleapis.com \
  cloudbuild.googleapis.com billingbudgets.googleapis.com --project="$PROJECT"

gcloud billing budgets create --billing-account=<billing account> --display-name="$PROJECT" \
  --budget-amount=10USD --filter-projects="projects/$PROJECT" \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0 \
  --threshold-rule=percent=1.0,basis=forecasted-spend --billing-project="$PROJECT"
```

- `--billing-project="$PROJECT"` was needed. Without it, gcloud billed the budget API call to another project, the one set as its quota project.
- **A budget only sends alerts. It does not stop spending.** The teardown is the only thing that stops the cost.

### 2. Grants for the default compute service account

In a new project, Cloud Build and the nodes both run as the default compute service account, and it had none of the roles they need. Without the first grant, Cloud Build failed with a 403 on its source bucket.

```sh
NUM=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
SA=$NUM-compute@developer.gserviceaccount.com
for role in roles/storage.objectViewer roles/artifactregistry.writer roles/logging.logWriter roles/container.defaultNodeServiceAccount; do
  gcloud projects add-iam-policy-binding "$PROJECT" --member="serviceAccount:$SA" --role="$role" --condition=None
done
```

| Role | Why |
|---|---|
| `roles/storage.objectViewer` | Cloud Build reads the uploaded source from a bucket (403 without it) |
| `roles/artifactregistry.writer` | Cloud Build pushes the images |
| `roles/logging.logWriter` | build and node logs |
| `roles/container.defaultNodeServiceAccount` | what GKE nodes need; with it the node pulled the four images from Artifact Registry |

### 3. Start the cluster (in the background)

```sh
gcloud container clusters create "$CLUSTER" --project="$PROJECT" --zone="$ZONE" --release-channel=rapid \
  --machine-type=c3-standard-4 --num-nodes=1 --spot --image-type=COS_CONTAINERD --enable-dataplane-v2 \
  --disk-type=pd-balanced --disk-size=60 \
  --enable-master-authorized-networks --master-authorized-networks=<your IP>/32 \
  --no-enable-managed-prometheus > cluster-create.log 2>&1 &
```

- `rapid`: on 2026-11-26 it gave `1.37.2-gke.1606000`. Agent Substrate needs 1.37 or newer.
- `c3-standard-4`: Google's Substrate page refuses mixed CPU series such as E2.
- `--spot`: cheaper, and a preemption only ends a short test. Upstream advises against Spot and node auto-upgrade for nodes that run Substrate workers (a suspended actor can end up crashed). Use `SPOT=0` (on-demand) and think about the channel for anything longer than a short test.
- Master authorized networks: only your address reaches the control plane.

### 4. Build the four images in Cloud Build (at the same time)

Create an Artifact Registry repository and submit the build while the cluster is being made:

```sh
gcloud artifacts repositories create oa --repository-format=docker --location="$REGION" --project="$PROJECT"
REPO=$REGION-docker.pkg.dev/$PROJECT/oa
git archive --format=tar.gz -o source.tgz HEAD -- services/a2a-gate services/stub-model services/control-plane services/console console .dockerignore
gcloud builds submit source.tgz --project="$PROJECT" --config=hack/gke/cloudbuild.yaml --substitutions="_REPO=$REPO,_TAG=gke1"
```

The recipe (`hack/gke/cloudbuild.yaml`): four `docker build` steps that all start at once (`waitFor: ['-']`), on an `E2_HIGHCPU_8` build machine. Cloud Build workers are `linux/amd64`, which is what C3 nodes run.

```yaml
steps:
  - id: a2a-gate
    name: gcr.io/cloud-builders/docker
    waitFor: ['-']
    args: ['build', '-t', '${_REPO}/a2a-gate:${_TAG}', 'services/a2a-gate']
  - id: stub-model
    name: gcr.io/cloud-builders/docker
    waitFor: ['-']
    args: ['build', '-t', '${_REPO}/stub-model:${_TAG}', 'services/stub-model']
  - id: control-plane
    name: gcr.io/cloud-builders/docker
    waitFor: ['-']
    args: ['build', '-t', '${_REPO}/control-plane:${_TAG}', 'services/control-plane']
  - id: console
    name: gcr.io/cloud-builders/docker
    waitFor: ['-']
    args: ['build', '-t', '${_REPO}/console:${_TAG}', '-f', 'services/console/Dockerfile', '.']
images:
  - '${_REPO}/a2a-gate:${_TAG}'
  - '${_REPO}/stub-model:${_TAG}'
  - '${_REPO}/control-plane:${_TAG}'
  - '${_REPO}/console:${_TAG}'
options:
  machineType: E2_HIGHCPU_8
substitutions:
  _REPO: ''
  _TAG: gke1
```

The run used this recipe: four parallel steps, `E2_HIGHCPU_8`, tag `gke1`, done in 1 min 21 s. The file in `hack/gke/` and the `git archive` line were written down from it afterwards.

### 5. Credentials and the image values

Wait for the cluster create, then fetch its credentials into a **separate** kubeconfig, so your default one is not touched:

```sh
wait
export KUBECONFIG=$PWD/gke-kubeconfig
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" --project="$PROJECT"
export KUBE_CONTEXT=gke_${PROJECT}_${ZONE}_${CLUSTER}
```

A values file points the four chart images at Artifact Registry (`gke-images.yaml`):

```yaml
governance:
  a2a:
    image: {repository: <region>-docker.pkg.dev/<project>/oa/a2a-gate, tag: "gke1"}
gateway:
  stubModel:
    image: {repository: <region>-docker.pkg.dev/<project>/oa/stub-model, tag: "gke1"}
controlPlane:
  image: {repository: <region>-docker.pkg.dev/<project>/oa/control-plane, tag: "gke1"}
console:
  image: {repository: <region>-docker.pkg.dev/<project>/oa/console, tag: "gke1"}
```

### 6. Preflight, and the StorageClass workaround

```sh
hack/preflight.sh
```

The first run gave 8 pass, 1 warn, 1 fail:

- WARN NetworkPolicy: it found `anetd` (Dataplane V2). This line is always a warning; step 8 checks enforcement.
- **FAIL default StorageClass**: the cluster had 10 StorageClasses and none was marked default. (The message printed "10 classs", a plural bug.)

Workaround, one manual patch:

```sh
kubectl patch storageclass standard-rwo -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

Then the preflight gave 9 pass, 1 warn, 0 fail.

Since the run, the typo is fixed and the installer has an opt-in for this ([PR 185](https://github.com/openagentix/openagentix/pull/185)): add `SET_DEFAULT_STORAGECLASS=standard-rwo` to the install command and it marks the class itself, after a read-only check. That opt-in was not run on a cluster yet. `hack/gke/install.sh` sets it when the cluster has no default. The other checks that passed: Kubernetes 1.37 or newer, the `certificates.k8s.io` resources, `validatingadmissionpolicies` at `v1`, the Gateway API CRDs, node architecture, node capacity, Pod Security labels and the context name. Which `certificates.k8s.io` version was served, and whether GKE had its own Gateway API CRDs, was not written down.

### 7. Install

Remote mode, stub model, no provider key in the environment, and the images from step 4:

```sh
KUBE_CONTEXT=$KUBE_CONTEXT CLUSTER_TYPE=remote PROFILE=quickstart NODE_SETTINGS=daemonset SKIP_SKILL=1 \
SKIP_A2A_GATE_IMAGE=1 SKIP_STUB_MODEL_IMAGE=1 SKIP_CONTROL_PLANE_IMAGE=1 SKIP_CONSOLE_IMAGE=1 \
VALUES_FILE=gke-images.yaml ./install.sh 2>&1 | tee gke-install.log
```

- `NODE_SETTINGS=daemonset` applies the DaemonSet that sets `proxy_arp` and `proxy_ndp` on the node. It rolled out on GKE. Whether it is needed there was **not** tested (no run without it).
- `SKIP_SKILL=1`: the example skill needs a local registry; the quick start does not use it.
- Result: exit 0 after 625 s; `AgentDefinition quickstart` Ready at +625 s; 49 pods Running; the four images were pulled from Artifact Registry.

### 8. Checks

```sh
hack/ci/smoke.sh 2>&1 | tee gke-smoke.log
hack/ci/netpol-test.sh
hack/demo.sh
kubectl get svc -A -o json | jq -r '.items[]|select(.spec.type=="LoadBalancer")|.metadata.namespace+"/"+.metadata.name'
```

| Check | Result on GKE |
|---|---|
| `hack/ci/smoke.sh` | 13 passed, 0 failed, 32 s: `AgentDefinition` and agent `quickstart` Ready; `RemoteMCPServer kagent-api` Accepted; the A2A gate returned the stub's answer; the agent used `osv_query_vulnerability` through its tool profile; a tool outside the profile got no data; a definition with a model that is not allowed was refused (`Accepted=False`, no agent built); the console API answered 401 without a token and listed `quickstart` and one tool profile with it |
| `hack/ci/netpol-test.sh` | ingress ENFORCED, egress to the internet ENFORCED (Dataplane V2) |
| `hack/demo.sh` | "every step showed what it should" |
| LoadBalancer Services | the model gateway Service had a public IP: the known gap ([issue 165](https://github.com/openagentix/openagentix/issues/165)) |

## Teardown

The run deleted the **whole project**. That removes the cluster, the node, its disks, the load balancer, the images and the grants in one step, and disables billing for the project.

```sh
gcloud projects delete "$PROJECT" --quiet
gcloud projects describe "$PROJECT" --format='value(lifecycleState)'   # DELETE_REQUESTED
rm -f gke-kubeconfig
```

It took 37 s. After it, the project state was `DELETE_REQUESTED`, billing was disabled, and API calls to the project were refused with "billing must be enabled". Google keeps a deleted project recoverable for about 30 days. Delete the budget when the billing report shows no new charge for the project (`gcloud billing budgets list --billing-account=<billing account>`). `hack/gke/down.sh` does the delete, the check and the kubeconfig cleanup.

If you must keep the project, delete the LoadBalancer Services and the PVCs before the cluster (load balancers and disks outlive a cluster and cost money), delete the cluster, then check that `gcloud compute instances list`, `disks list`, `forwarding-rules list`, `addresses list` and `target-pools list` are empty for the project. That path was not run.

## Helper scripts

[`hack/gke/`](https://github.com/openagentix/openagentix/tree/main/hack/gke) has `up.sh` (steps 1 to 5), `install.sh` (steps 6 and 7; it sets `SET_DEFAULT_STORAGECLASS=standard-rwo` when the cluster has no default) and `down.sh` (the teardown). `up.sh` always makes a new project, refuses to run without `PROJECT_PREFIX`, `ORG_ID`, `BILLING_ACCOUNT`, `MAX_HOURS` and `AUTHORIZED_CIDR`, prints the teardown command before it creates anything, and prints no credential or billing id. `down.sh` deletes only a project with the label that `up.sh` sets. They are tested offline with a fake `gcloud` (`hack/gke/tests/run.sh`) and have **not** been run against a real project. See the [README](https://github.com/openagentix/openagentix/blob/main/hack/gke/README.md).

## What was proven

On one GKE Standard cluster (Kubernetes 1.37.2, one Spot `c3-standard-4`, Dataplane V2), once:

- `CLUSTER_TYPE=remote` with `KUBE_CONTEXT` installs the quick start on a managed cluster, when the images are given in a values file.
- `hack/preflight.sh` ran against a real cluster for the first time, and its FAIL for a missing default StorageClass was correct.
- Agent Substrate's node agent and its own gVisor ran on a COS node (the quick start agent became Ready and answered).
- The control plane, the A2A gate with the model gateway key, the tool profile, the policy refusal and the console API worked on GKE, through the NetworkPolicies the chart sets (the API server `/32` rule included).
- Dataplane V2 enforced the NetworkPolicy test for ingress and for egress to the internet.
- The node settings DaemonSet (`NODE_SETTINGS=daemonset`) rolls out on GKE.
- Deleting the project removed everything that costs money in 37 s.

## What was not shown

- A real model (the stub answered).
- Bring your own agent (container agents) on GKE: `QUICKSTART_BYO=1` is still refused in remote mode, and the service account issuer path for it was not exercised.
- The installer's registry mode ([issue 162](https://github.com/openagentix/openagentix/issues/162)); the images were a manual step. The mode exists now (`hack/gke/install.sh` with `GKE_IMAGES=installer`), tested offline only.
- Whether the node sysctls DaemonSet is needed on GKE (no run without it).
- The model gateway Service as `ClusterIP` (ADR 0023 is not merged).
- GKE Sandbox, Autopilot, arm64 nodes, more than one node, Calico.
- Long-run stability, node upgrades, Spot preemption.
- The console in a browser (only its API was checked).
- `uninstall.sh` on GKE (the project was deleted instead).
- The cost (not read from billing yet).
- `hack/gke/` scripts against a real project.

## How Agent Substrate's gVisor relates to GKE Sandbox

These are two different things. Do not mix them up.

- **Agent Substrate runs its own gVisor.** The atelet DaemonSet downloads a pinned gVisor release (`gs://gvisor/releases/release/20261026.0/...`, from the `substrate` chart's `sandboxconfig-gvisor.yaml`) and the worker pods (`ateworker-gvisor`) start sandboxes with it. Golden snapshots are taken and restored inside those workers. It needs no GKE feature.
- **GKE Sandbox** is a node pool option (`--sandbox type=gvisor`). It installs gVisor as the RuntimeClass `gvisor` on that pool. It needs `COS_CONTAINERD`, and it cannot be the only node pool or the default pool.
- **Where GKE Sandbox could fit:** only for bring-your-own container agents. The chart has `controlPlane.containerAgents.runtimeClassName` (empty by default). Setting it to `gvisor` on a cluster with a sandbox node pool would run container agents in GKE's gVisor. That needs a second node pool and is **not** part of the first run.
- *Unverified:* whether Substrate's workers start at all on a GKE Sandbox node pool (gVisor inside gVisor). Keep the worker node pool a normal pool.

## Current GKE facts, with sources

Read on 2026-11-26, before the run. The last column adds what the run showed, where it showed something. Google's pages do not show a "last updated" date, so the date is the day they were read. Third-party price pages give their own update dates.

| Fact | What the source says | Source | Status |
|---|---|---|---|
| Agent Substrate on GKE: cluster mode | "Agent Substrate on GKE is supported on Standard clusters only"; "Autopilot clusters aren't supported" | [Install overview, Agent Substrate on GKE](https://docs.cloud.google.com/kubernetes-engine/ai-ml/install-overview-substrate) | confirmed from the page |
| Version | 1.37 or later on the control plane and the node pools; not the Extended channel | same page; [substrate-gke setup-gcp README](https://github.com/ai-on-gke/substrate-gke/blob/main/tools/setup-gcp/README.md) | confirmed from the page. Run: the `rapid` channel gave `1.37.2-gke.1606000` |
| Machine type | `c3-standard-4` or larger; no mixed CPU series such as E2 | same page | confirmed from the page. Run: one Spot `c3-standard-4` with a `pd-balanced` boot disk was enough for the quick start |
| Dataplane V2 | listed as a requirement | same page | confirmed from the page. Run: `netpol-test.sh` showed ingress and egress enforced |
| PodCertificateRequest and ClusterTrustBundle | Google's installer "turns on the beta `podcertificaterequests` and `clustertrustbundles` APIs"; substrate-gke creates clusters "with ... required Kubernetes beta APIs" | same page; substrate-gke README | confirmed that Google's tool enables them. Our `components/runtime/NOTES.md` says kind 1.37 serves them as `certificates.k8s.io/v1`. Run: the preflight check passed on `1.37.2-gke.1606000` with no extra cluster flag; which version was served was not written down |
| Node auto-upgrade | "Turn node auto-upgrade off on any node pool that runs workers, and do not use spot or preemptible nodes for them" (a suspended actor can end up crashed) | substrate-gke setup-gcp README | confirmed from the page. The run used Spot and the `rapid` channel anyway, for 21 minutes; a longer test should not |
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
| Artifact Registry pulls | the node service account needs `roles/artifactregistry.reader`; then GKE pulls from repositories in the same project | [Artifact Registry: integrate with GKE](https://docs.cloud.google.com/artifact-registry/docs/integrate-gke) | from search result summaries. Run: `roles/container.defaultNodeServiceAccount` on the default compute service account was enough for the node to pull from a repository in the same project |
| Service account issuer | read it with `kubectl get --raw /.well-known/openid-configuration`; on GKE it is a `container.googleapis.com` URL for the project, location and cluster | [Workload Identity Federation with Kubernetes](https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-kubernetes), [Pulumi GKE guide](https://www.pulumi.com/docs/administration/guides/oidc-issuers/kubernetes-gke/) | *unverified* for the exact form; read it from the cluster |
| Budgets | `gcloud billing budgets create --billing-account=... --display-name=... --budget-amount=... --threshold-rule=percent=0.50 --threshold-rule=percent=0.75,basis=forecasted-spend`; `--filter-projects=projects/<id>` limits it to one project | [gcloud billing budgets create](https://docs.cloud.google.com/sdk/gcloud/reference/billing/budgets/create) | confirmed from the page. A budget sends alerts; it does **not** stop spending. Run: in a new project the command also needed `--billing-project=<new project>` |

Also read: the upstream [substrate-gke](https://github.com/ai-on-gke/substrate-gke) project, Google's installer for Substrate on GKE. It makes extra node pools for Substrate's own system parts and the bundled PostgreSQL by default (`e2-standard-4`), a `c3-standard-4` pool for workers, Workload Identity, GCS buckets for snapshots and a DNS-only control plane endpoint. Our quick start keeps Substrate's bundled RustFS for snapshots, so it does not need GCS or Workload Identity for a first run.

## Installer changes

This list was written before the run. The run used items 1, 3, 4 and 8 on a real cluster for the first time; item 2 was replaced by a manual Cloud Build step; item 5 was confirmed as a real gap (the Service got a public IP); items 6, 7 and 11 were not needed for the quick start (`SKIP_SKILL=1`, no container agent). The row by row result is in [Install: managed cloud](../features/install.md#managed-cloud-known-gaps-and-what-the-gke-run-showed).

Each item is a proposed issue: small, testable offline (fake `kubectl`, `docker` and `gcloud` like `hack/ci/cluster-test.sh`, or a chart render test), and needs no cluster. Items 1 to 5 block the quick start on GKE. Items 1, 3, 4, 7, 8, 9 and 10 are built and tested offline (marked **Built, offline only**); of them, items 1, 3, 4 and 8 then ran on GKE once, as described above. A change to a chart value or a public switch needs an ADR first ([ADR rules](https://github.com/openagentix/openagentix/blob/main/docs/decisions/README.md)); those are marked.

1. **`CLUSTER_TYPE=remote` in `hack/cluster.sh`.** No create; `KUBE_CONTEXT` is required; `cluster_exists` asks the API server; `cluster_load_images` pushes instead of loading; `cluster_ctr` and `cluster_node` fail with a clear message; `cluster_delete_hint` says to delete the cluster with the cloud's own tool. Preflight stops needing `kind`, `k3d` or a local cluster tool. Test: extend `hack/ci/cluster-test.sh`. Public switch: note it in the ADR of item 2.
   **Built, offline only** (issue #161): `CLUSTER_TYPE=remote` needs `KUBE_CONTEXT`, refuses a local context name (`kind-*`, `k3d-*`, `docker-desktop` and a few others) unless `ALLOW_LOCAL_CONTEXT=1`, and stops before any change when that context's API server does not answer. `cluster_load_images` stops with a message instead of pushing (the push is item 2), so until item 2 exists `install.sh` refuses, before any build, a run that would build images. The ADR of item 2 is not written yet.
2. **`IMAGE_REGISTRY` and `IMAGE_PLATFORM` (default `linux/amd64` for remote).** Build with `docker buildx build --platform ... --push`, tag as today (`dev-<hash of source>`), and pass `--set-string <component>.image.repository=$IMAGE_REGISTRY/openagentix/<name>` to the chart. Required with `remote`, refused with kind and k3d. Test: a fake `docker` records the arguments; assert the `--set-string` lines and that nothing calls `kind load`. Needs an ADR (new installer contract).
   **Built, offline only** (issue #162, ADR 0022, `hack/images.sh`): with `CLUSTER_TYPE=remote` and `IMAGE_REGISTRY`, each image is looked up in the registry, built with `docker buildx build --platform linux/amd64 --push --provenance=false --sbom=false --metadata-file` when the tag `dev-<hash>-amd64` is not there, checked by digest (`imagetools inspect --raw`, and its platform), and given to the chart as `image.repository`, `image.tag` and `image.digest`. Before `helm upgrade` no platform image may be an unqualified name, and with `IMAGE_REGISTRY` each must be under it; operator images by tag get a warning. `IMAGE_REGISTRY` is required only when the installer builds an image. The installer never runs `docker login`. Tested with fake `docker`, `kubectl` and `helm`; no image has been pushed by the installer, and the buildx output formats are read from its documentation.
3. **No `docker exec` on the node for remote.** `install.sh:270-271` and `components/runtime/up.sh:44-45` set `proxy_arp` and `proxy_ndp` through `docker exec` and stop the install (`set -e`) when there is no such container. For remote: skip them, and offer an opt-in DaemonSet `components/runtime/node-settings.yaml` (privileged, `hostNetwork`, sets the two sysctls, then sleeps) behind `NODE_SETTINGS=daemonset`. The first live run decides whether GKE needs it at all (NOTES.md says it was never proven necessary on kind). Test: the fake `docker` sees no `exec` with remote; `kubectl apply --dry-run=client` and a shell assert on the manifest.
   **Built, offline only** (issue #163): `cluster_node_settings` in `hack/cluster.sh`. Only the init container is privileged and only for the two writes; the container that stays is a non-root, read-only sleep. No API token, no toleration, its own namespace `openagentix-node-settings` (deleted by `uninstall.sh`). Not applied on any cluster; the `e2e` job checks it with a client dry run on kind.
4. **Substrate API authentication for an external issuer.** `components/runtime/up.sh:70-79` always writes `certificateAuthorityFile` and `discoveryTokenFile`. The comment at line 76 already says they must be omitted on GKE-style external issuers. Write them only when the issuer is `https://kubernetes.default.svc...`. Test: move the heredoc into a function and test both issuers.
   **Built, offline only** (issue #164): `components/runtime/auth-config.sh`, tested in `components/runtime/tests/run.sh` (kind's file byte-identical; a `container.googleapis.com` issuer without the two lines). Whether Substrate then accepts GKE tokens is *unverified*.
5. **The model gateway's Service must not become a public load balancer.** agentgateway makes the `model-gateway` Service of type `LoadBalancer` (`components/model-gateway/NOTES.md:19`; on kind it stays `<pending>`). On GKE that would create an external load balancer with a public IP in front of the model gateway, plus a firewall rule and an hourly charge. Set the Service to `ClusterIP` through agentgateway's Gateway parameters (`spec.infrastructure.parametersRef`; the exact field for agentgateway v1.7.0 is *unverified*). Test: chart render test that the Gateway references the parameters; byte-identical render when the value is unset. Needs an ADR (chart value).
6. **Bring your own agent on a registry.** `install.sh:254` names the sample image `registry.local/oa/echo-a2a` and `install.sh:807` reads its digest from the node with `hack/kind-image-digest.sh`. For remote: push to `$IMAGE_REGISTRY`, take the digest from the push, allow `$IMAGE_REGISTRY/` as the prefix instead of `registry.local/oa/`, and keep `imagePullPolicy: Always` (drop the `IfNotPresent` of `components/quickstart/byo-values.yaml:9`). Test: fake `docker` prints a digest; assert the AgentDefinition and the values.
   **Built, offline only** (issue #162, ADR 0022): the sample goes to `$IMAGE_REGISTRY/openagentix-examples/echo-a2a` (not `$IMAGE_REGISTRY/`, so platform images cannot run as container agents), the `AgentDefinition` gets `<repository>@<digest>`, the `IfNotPresent` is dropped, and an operator's own prefix list must name the prefix itself. Its Dockerfile is pinned by digest now. Not run on GKE.
7. **ServiceAccount issuer for the workload tool server.** `charts/openagentix/values.yaml:554-561` defaults the issuer to kind's `https://kubernetes.default.svc.cluster.local` and fetches the keys anonymously from the in-cluster API server. On GKE the issuer is a `container.googleapis.com` URL. The installer should read it from `/.well-known/openid-configuration` and set it, like the API server CIDRs today. Only needed with `QUICKSTART_BYO=1`. Test: a function over a JSON fixture. Whether GKE allows the anonymous key fetch is *unverified* (on k3s it failed, see `what-works.md`).
   **Built, offline only** (issue #167): `hack/sa-issuer.sh`, tested in `hack/ci/sa-issuer-test.sh` with the kind form and a GKE-style form. `install.sh` reads `/.well-known/openid-configuration`; if that gives nothing it reads the first `--service-account-issuer` flag of the kube-apiserver pod (a managed control plane has no such pod, so on GKE only the first source works); `SERVICE_ACCOUNT_ISSUER=<https URL>` overrides both. It sets `controlPlane.containerAgents.serviceAccountTokens.issuer` only when the chart renders its default (a values file that sets it wins) and the cluster's issuer is different, so kind and k3s renders do not change. It leaves `jwksUrl` alone: whether the keys can then be fetched anonymously from GKE's API server is the open question, and the run will show it. With `CLUSTER_TYPE=remote` the installer still refuses `QUICKSTART_BYO=1` (issue #162), so this step has no way to run on a remote cluster yet.
8. **Remote preflight.** Before anything changes: server version 1.37 or newer, the `certificates.k8s.io` resources `clustertrustbundles` and `podcertificaterequests` served, `validatingadmissionpolicies` served at `admissionregistration.k8s.io/v1`, a default StorageClass, no Gateway API CRDs at an older bundle than 1.6.3, and a warning that NetworkPolicy enforcement must be checked with `hack/ci/netpol-test.sh`. Test: fake `kubectl` outputs.
   **Built, offline only** (issue #168): `hack/preflight.sh`, tested in `hack/ci/preflight-test.sh` with a fake `kubectl` and JSON fixtures. `install.sh` runs it for `CLUSTER_TYPE=remote` before anything changes and stops on a FAIL (`SKIP_PREFLIGHT=1` skips it). You can run it alone: `KUBE_CONTEXT=<context> hack/preflight.sh`. It only reads (every call is `get`) and prints PASS, WARN or FAIL with a plain fix for each. FAIL: Kubernetes older than 1.37, `clustertrustbundles` or `podcertificaterequests` not served at `certificates.k8s.io` `v1` or `v1beta1`, `validatingadmissionpolicies` not served at `admissionregistration.k8s.io/v1`, no default StorageClass, no Ready node. WARN: a Gateway API bundle older than 1.6.3 or of unknown version, a node architecture that is not amd64, less than 3000m CPU or 6 GiB memory allocatable in total (an estimate, not measured), a target namespace that enforces `baseline` or `restricted`, a context that looks local, and always the NetworkPolicy line. That line names the dataplane DaemonSet it finds (for example `anetd`) and says a name is not proof; `hack/ci/netpol-test.sh` is the live check. Not run against any real cluster.
9. **`uninstall.sh` context.** `uninstall.sh:26` builds the context as `$CLUSTER_TYPE-$CLUSTER`. With remote it must use `KUBE_CONTEXT`. Test: shell test with a fake `kubectl`.
   **Built, offline only** (issue #169): every `kubectl` and `helm` call names the context; nothing is removed when the context is missing, not current after the switch, or (remote) not reachable; no cluster is deleted, and remote prints the teardown reminder. Test: `hack/ci/uninstall-test.sh`.
10. **Local-only model paths refused on remote.** `install.sh:130-133` points a local Ollama at `host.docker.internal` or the Docker network gateway. With remote, refuse `MODEL_PROVIDER=ollama` unless `MODEL_BASE_URL` is set. Test: shell test of `components/quickstart/model.sh`.
   **Built, offline only** (issue #170). With `MODEL_PROVIDER=ollama`, a set `MODEL_BASE_URL` is the Ollama URL.
11. **The example skill on remote (not needed for the quick start).** `install.sh:656-684` runs a `registry:2` container on the kind Docker network and pushes with `crane`. For remote: push the skill to `$IMAGE_REGISTRY` or require `SKIP_SKILL=1`. Test: fake `docker`.

## Cost estimate

The cost of the run was not read from billing yet (it appears with a delay). The estimate below was made before the run; for about 21 minutes on one Spot node it gives well under 1 USD. This is an estimate, not a measured cost. All prices are *unverified* (see the table of facts), and they are on-demand prices: Spot is cheaper. Region `us-central1`, on-demand, USD.

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
