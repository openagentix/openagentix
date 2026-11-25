---
title: Install on k3s
sidebar_position: 3.5
description: Run the quick start on a k3s cluster in Docker with k3d. The exact commands, what was proven, what differs from kind, and what was not tried.
---

# Install on k3s

This page runs the [quick start](./quick-start.md) on k3s instead of kind. k3s runs in Docker through [k3d](https://k3d.io), so you need no server. One option, `CLUSTER_TYPE=k3d`, tells the installer to make and use a k3s cluster.

## What was proven

| What | Result |
|---|---|
| k3s version | v1.37.2+k3s1 (image `rancher/k3s:v1.37.2-k3s1`), one server node, k3d 5.9.0 |
| Where | The `e2e-k3s` CI job: a GitHub-hosted `ubuntu-24.04` runner (amd64), nothing cached |
| Command | `CLUSTER_TYPE=k3d PROFILE=quickstart QUICKSTART_BYO=1 ./install.sh`, then `SMOKE_BYO=1 hack/ci/smoke.sh` (the quick start plus the sample container agent) |
| Install time | 5 min 51 s from the start of `install.sh` to both agents Ready (one run; 5 min 35 s for the quick start alone in the run before) |
| Smoke test | 28 checks passed, 0 failed (10 for the quick start alone): agent Ready, a question answered through the A2A gate with a tool call, a tool outside the profile refused, a forbidden definition refused, the console API answers 401 without the token and lists the agent with it; the sample container agent `echo-go` Ready, answering through the gate, and three bad container definitions refused |
| NetworkPolicy | Enforced for ingress and for egress to the internet (live test, below) |

The runs are on [pull request 117](https://github.com/openagentix/openagentix/pull/117). The stub model answered, not a language model.

## What you need

`docker`, `k3d` 5.x, `kubectl`, `helm` 3, `jq`, the Python `yq`, `openssl`, `curl` and `python3`. You do not need `kind`. Docker should have 4 CPU and 8 GB for this cluster alone. Do not run it beside a second cluster in the same 8 GB: on a laptop with one kind cluster already running, the two did not fit and both API servers timed out.

## Install

```sh
git clone https://github.com/openagentix/openagentix && cd openagentix
CLUSTER_TYPE=k3d PROFILE=quickstart ./install.sh
```

The installer creates a k3d cluster named `openagentix` (set `CLUSTER=<name>` to change it), switches your kubectl context to `k3d-<name>`, and runs the same steps as on kind. To keep the test apart from your own kubeconfig, give it a file:

```sh
export KUBECONFIG=$PWD/oa-k3s.kubeconfig
CLUSTER_TYPE=k3d CLUSTER=oa-k3s-test PROFILE=quickstart ./install.sh
hack/ci/smoke.sh
hack/ask.sh quickstart "Look up known vulnerabilities of lodash 4.17.20 (npm)"
```

To use another k3s version, set `K3D_NODE_IMAGE`, for example `K3D_NODE_IMAGE=rancher/k3s:v1.37.2-k3s1`. The runtime needs Kubernetes 1.37 or newer.

## Remove everything

```sh
k3d cluster delete openagentix && docker volume rm k3d-openagentix-ate
```

The second command removes the volume the installer made for the runtime (see below). Use your cluster name in both.

## How k3s differs from kind

| Thing | kind | k3s (k3d) | What the installer does |
|---|---|---|---|
| Create, load images | `kind create`, `kind load` | `k3d cluster create`, `k3d image import` | `hack/cluster.sh` has one function for each |
| Node name, context, Docker network | `<name>-control-plane`, `kind-<name>`, `kind` | `k3d-<name>-server-0`, `k3d-<name>`, `k3d-<name>` | derived from `CLUSTER_TYPE` |
| containerd socket | the default | `/run/k3s/containerd/containerd.sock` | `hack/kind-image-digest.sh` passes it to `ctr` (used by the sample container agent, which passed on k3s) |
| `/var/lib/ate` (the runtime builds sandbox root file systems here) | on a Docker volume, because kind mounts `/var` as one | in the container's overlay root | the installer adds a named Docker volume for it |
| Traefik and ServiceLB | none | on by default | the installer turns both off: nothing in the chart uses an Ingress or a LoadBalancer |
| Gateway API CRDs | none | k3s installs them itself (bundle v1.6.3, Helm release `gateway-api-crd` in `kube-system`) | the model gateway script sees them and leaves them alone |
| NetworkPolicy | kindnet does not enforce egress to the internet | enforced by k3s | nothing to do; see below |
| API server NetworkPolicy address | the node's `/24` | the exact node address (`/32`) | the same code path as any non-kind cluster |

### The volume for `/var/lib/ate`

The first CI run failed: the agent never became Ready, and the runtime said `golden build failed (GoldenActorCrashed) ... mknodat usr/lib/libz.so.1.3.2: operation not permitted`. The runtime makes overlay whiteouts (a character device 0/0) while it builds the sandbox root. A container's own overlay root file system refuses that, even for a privileged container. A Docker volume allows it. This was checked outside the cluster: `mknod c 0 0` in a privileged container fails on the container root and works on a volume. With the volume the second run passed.

### NetworkPolicy on k3s

k3s enforces NetworkPolicy with its built-in controller (kube-router). `hack/ci/netpol-test.sh` checks it live. A client pod reached a server pod; after a deny-all ingress policy on the server it did not. A client pod made a TCP connection to `1.1.1.1:80`; after a deny-all egress policy on the client it could not. Both are enforced on k3s in CI. This answers the open question in [ADR 0015](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0015-bring-your-own-agent.md) about egress on k3s for this setup. kind's default network plugin does not enforce egress to the internet.

## What was not proven

- Only k3s in Docker through k3d, on one amd64 runner. Not a k3s installed on a server or a Raspberry Pi with the k3s install script. Not arm64 on a real device.
- One server node. No agent nodes, no embedded etcd, no high availability.
- The CI job is not a required check. It ran three times (one failure, then the fix, then the sample container agent added); the record above is the third run, and the second one passed with the quick start alone.
- Full demo values (Telegram bridge, Kourier, schedules, knowledge base) were not run on k3s.
- The example skill registry (`SKIP_SKILL` unset) pulls from a plain HTTP registry on the Docker network. k3s needs a `registries.yaml` entry for that. The quick start does not use it. Not tried.
- Time on a laptop was not measured. On an Apple silicon laptop (arm64) the k3s node reached the point where Substrate, kagent and the model gateway were running, and then the machine ran out of memory beside an existing kind cluster. That run is not counted as a proof.
