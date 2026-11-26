# ADR 0022: build images for a remote cluster and push them to a registry

Status: Proposed
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/162 (umbrella #31, also covers the `CLUSTER_TYPE=remote` switch of #161)
Replaces: none. Adds to ADR 0014 (quick start) and ADR 0015 (container agents); does not change ADR 0018 (release signing).

With `CLUSTER_TYPE=remote`, the installer builds every image it needs with `docker buildx` for `IMAGE_PLATFORM` (default `linux/amd64`), pushes it to `IMAGE_REGISTRY`, and gives the chart the repository, the content tag and the pushed digest of each image. The node pulls by digest. On kind and k3d nothing changes.

## Context

`install.sh` builds the images of the platform on the local machine and copies them into the node. Facts read in this repository on 2026-11-26 (commit `662836c`):

- `install.sh:166-202`: `queue_build` collects images, `start_builds` runs `docker build -q -t <image> <context>` in the background, and `finish_builds` calls `cluster_load_images`, which is `kind load docker-image` or `k3d image import` (`hack/cluster.sh:50-55`). There is no push and no `--platform`, so the image has the architecture of the machine that runs the installer.
- `install.sh:171`: `tag_image` sets the tag to `dev-<hash of the source>` (`hack/image-tag.sh`) and passes `--set-string <path>.image.tag=<tag>` to the chart. The repository stays the chart default.
- The chart has eight images built by the installer, each `{repository, tag, pullPolicy}` and rendered as `repository:tag` (for example `templates/control-plane.yaml:231`): `bridge` (`openagentix/telegram-bridge`, `values.yaml:113`), `scheduling` (`openagentix/a2a-call`, `:162`), `gateway.stubModel` (`:215`), `knowledge.kb` (`:306`), `notify` (`:431`), `governance.a2a` (`:478`), `controlPlane` (`:509`) and `console` (`:611`). All use `pullPolicy: IfNotPresent`. No template has an `imagePullSecrets` field and none accepts a digest.
- `hack/cluster.sh` knows only `kind` and `k3d`. `cluster_ctr` and `cluster_node` run `docker exec` in the node container.
- The sample container agent (`QUICKSTART_BYO=1`, ADR 0015) is built as `registry.local/oa/echo-a2a:dev-<hash>` (`install.sh:254`), loaded into the node, and its digest is read back from the node with `hack/kind-image-digest.sh` (`install.sh:807`). `components/quickstart/byo-values.yaml` allows the prefix `registry.local/oa/` and sets `imagePullPolicy: IfNotPresent`, because the image exists only on the node.
- The example skill (`install.sh:656-684`) is pushed with `crane` to a `registry:2` container on the kind Docker network.
- The release workflow (`.github/workflows/release.yml:136-157`, ADR 0018) builds with buildx for `linux/amd64` only, with `provenance: false` and `sbom: false` so the digest is one plain image manifest, and pushes to `ghcr.io/openagentix/<name>`, where `<name>` comes from `hack/ci/dockerfiles.sh` (`telegram`, `a2a-call`, `kb`, `notify`, `a2a-gate`, `stub-model`, `control-plane`, `console`). It signs with the identity of that workflow. The released chart still names `openagentix/<name>:dev` by default.
- The Dockerfiles compile Go under the target platform (comment at `release.yml:138`), so a foreign platform runs the compiler under QEMU. The base images are pinned by digest (pull request #145, merged), except `examples/agents/echo-a2a/Dockerfile`.

A GKE node cannot receive an image through `kind load`, and the C3 machine type that the GKE guide needs is `linux/amd64` (`docs/diary/guide/install-gke.md`, "Installer changes to make first", items 1, 2, 6 and 11). A laptop with Apple silicon builds `linux/arm64` by default. Such an image does not start on that node.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `docker buildx build --platform --push` to a registry the operator names; the chart gets repository, content tag and the pushed digest | Works from any laptop for any node architecture; the node pulls by digest, so a later push under the same tag does not change what runs; no credential passes through the installer | A new chart value per image (`image.digest`); a registry and a login are needed before the install; a foreign platform is slow until the Dockerfiles cross-compile | Read `install.sh`, the chart and the release workflow; not run |
| B. Use the signed release images from `ghcr.io/openagentix` by digest | Best supply chain: signed, with SBOM and provenance (ADR 0018); no build at all | No tag has run the release yet; a change on a branch cannot be tried on a remote cluster; the released chart does not point at these images | ADR 0018, `release.yml` |
| C. `docker build`, `docker tag`, `docker push` per image | No buildx needed | Builds for the host's architecture unless `--platform` is set, and one platform only; an image index for two platforms is not possible | not built |
| D. Build inside the cluster (a BuildKit or kaniko pod) | No local Docker needed | A privileged or rootless builder in the cluster, registry write credentials inside the cluster, one more component | rejected on reading |
| E. Option A, but the digest is put into the tag value (`tag: dev-x@sha256:...`) | No chart change | A hidden convention that the chart cannot check; the rendered reference is not validated | rejected on reading |
| F. Option A without a digest, `pullPolicy: Always` | No new chart value | A tag in a registry can be moved; every restart pulls; a pod can start from a different image than the one the installer built | rejected on reading |

## Decision

Option A. Option B stays the target for users who install a release; it needs its own decision once a release exists (see open points).

### Switches

| Switch | Values | Default | Rule |
|---|---|---|---|
| `CLUSTER_TYPE` | `kind`, `k3d`, `remote` | `kind` | `remote` means an existing cluster the installer does not create or delete |
| `KUBE_CONTEXT` | a context name | `<type>-$CLUSTER` for kind and k3d | **required** with `remote`; there is no default |
| `IMAGE_REGISTRY` | `host[:port]/path` | none | **required** with `remote`; **refused** with `kind` and `k3d` |
| `IMAGE_PLATFORM` | `linux/amd64`, `linux/arm64`, or both, comma separated | `linux/amd64` with `remote` | **refused** with `kind` and `k3d` (the local build keeps the host's platform, as today) |

Refusals happen before anything changes, in the same preflight as today, with one sentence each:

- `CLUSTER_TYPE=remote` without `IMAGE_REGISTRY`, or without `KUBE_CONTEXT`.
- `IMAGE_REGISTRY` or `IMAGE_PLATFORM` with `kind` or `k3d`.
- `CREATE_CLUSTER=1` with `remote`.
- `IMAGE_REGISTRY` that does not match `^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+$`: lower case, a host with a dot or a port, at least one path part, no scheme, no trailing slash, no tag, no digest and no `user:password@`. A host without a dot or port would silently mean Docker Hub.
- `IMAGE_REGISTRY` equal to or under `ghcr.io/openagentix`. That path holds the signed release images (ADR 0018). An unsigned developer build must never sit next to them under a name a user could mistake for a release.
- With `remote`: a rendered skill without `SKIP_SKILL=1` (the skill push needs the kind Docker network), and `MODEL_PROVIDER=ollama` without `MODEL_BASE_URL` (the local Ollama addresses are Docker addresses).

### `CLUSTER_TYPE=remote` in `hack/cluster.sh`

`cluster_ctx` returns `KUBE_CONTEXT`. `cluster_exists` asks the API server of that context (`kubectl version`), so the installer never creates a cluster. `cluster_create` fails. `cluster_load_images` is replaced by the push below. `cluster_ctr`, `cluster_node` and `cluster_network` fail with "not available for CLUSTER_TYPE=remote", so every caller that needs the node container is found by the tests, not on a customer cluster. `cluster_delete_hint` says to delete the cluster with the cloud's own tool. Preflight no longer requires `kind` or `k3d` with `remote`, and requires `docker buildx`.

### Build and push

- **Repository.** `$IMAGE_REGISTRY/openagentix/<name>`, with `<name>` from `hack/ci/dockerfiles.sh`, the same name the release uses. So `IMAGE_REGISTRY=ghcr.io/acme` gives the same layout as the release, only in another namespace.
- **Tag.** The content tag of today, `dev-<hash of the source>` (`hack/image-tag.sh`). It names the source. It does not name the platform or prove the content; the digest does that.
- **Command.** For each queued image, in the same background queue and `BUILD_JOBS` as today:
  `docker buildx build --platform "$IMAGE_PLATFORM" --push --provenance=false --sbom=false --metadata-file <tmp>/<name>.json -t <repository>:<tag> [-f <Dockerfile>] <context>`.
  `--provenance=false` and `--sbom=false` keep one plain manifest for one platform, as in the release. With two platforms the result is an image index, and its digest is used.
- **Digest.** Read from the metadata file (`containerimage.digest`), checked against `^sha256:[0-9a-f]{64}$`. No digest means the install stops before the chart is applied.
- **Chart.** For each image path `P` the installer passes `--set-string P.image.repository=<repository>`, `P.image.tag=<tag>` and `P.image.digest=<digest>`. Nothing calls `kind load`, `k3d image import` or `docker exec`.
- **Later images.** Every image the installer builds later (for example the egress proxy of ADR 0020) follows the same rule. A new image path without a digest on `remote` fails the installer test.

### New chart values (public contract)

`image.digest` under each of the eight paths above: `bridge`, `scheduling`, `gateway.stubModel`, `knowledge.kb`, `notify`, `governance.a2a`, `controlPlane`, `console`. Default `""`. When set it must match `^sha256:[0-9a-f]{64}$`, or the render fails with the path in the message. The image is then rendered as `repository:tag@digest`; the kubelet pulls by the digest and the tag is only for people. With the default the render is byte for byte as before. `pullPolicy` stays `IfNotPresent`: a digest cannot point at a stale image, which was the reason for the content tag on kind.

### How the node pulls

- The installer never receives, stores or passes a registry credential. The push uses the operator's existing Docker login (for Artifact Registry: `gcloud auth configure-docker <region>-docker.pkg.dev`; for other registries: `docker login --password-stdin`, run by the operator). The installer does not run `docker login`.
- The node pulls with its own credentials. On GKE with Artifact Registry in the same project, the node service account gets `roles/artifactregistry.reader` and no `imagePullSecrets` is needed (`docs/diary/guide/install-gke.md`, table row "Artifact Registry pulls"). Workload Identity does not take part: it gives pods an identity for Google APIs, while the kubelet pulls images with the node's credentials.
- A registry that needs `imagePullSecrets` is not supported in this slice. The chart has no such value, and ADR 0015 refuses `imagePullSecrets` for container agents. A chart-wide pull secret is a separate decision.

### Container agents on a remote cluster (`QUICKSTART_BYO=1`)

- The sample is pushed like the others, to `$IMAGE_REGISTRY/openagentix-examples/echo-a2a:dev-<hash>`. The `AgentDefinition` gets `<repository>@<digest from the push>`. `hack/kind-image-digest.sh` is not called.
- The allowed prefix (`controlPlane.policy.runtimes.container.images`) becomes `$IMAGE_REGISTRY/openagentix-examples/` instead of `registry.local/oa/`. It is a separate path on purpose. A prefix of `$IMAGE_REGISTRY/` or `$IMAGE_REGISTRY/openagentix/` would let a user run a platform image, such as the control plane, as a container agent.
- `controlPlane.containerAgents.imagePullPolicy` stays `Always` (the chart default, ADR 0015). The `IfNotPresent` of `byo-values.yaml` is for kind only and is not applied with `remote`.
- `registry.local/oa/` stays the quick start prefix on kind and k3d.

### Defaults

Off and unchanged by default. Without `CLUSTER_TYPE=remote` the installer runs exactly the commands of today: the same `docker build`, the same `kind load`, the same `--set-string` lines. The quick start on kind and k3d is unchanged. The default chart render is byte-identical.

## Consequences

- The quick start can be installed on a cluster that is not on the local machine, from any laptop, for an `amd64` node. This unblocks the GKE run of #31.
- An operator needs a registry, write access to it from the laptop and read access from the nodes before the install.
- Building `linux/amd64` on Apple silicon runs the Go compiler under QEMU, which is slow (not measured). A later slice makes the Dockerfiles cross-compile.
- **Security impact.**
  - *Supply chain.* These are developer builds. They are not signed and do not carry the ADR 0018 identity, and nothing says they do. `ghcr.io/openagentix` is refused as a target. Pods run the exact digest the installer pushed, so a later push under the same tag, by anyone with write access to the registry, does not change a running or restarting pod. It does change what the next install builds on top of: the registry should be dedicated to this install. Base images stay pinned by digest.
  - *Credentials.* No registry credential in argv, environment output, files the installer writes, logs or the chart. The installer prints repositories and digests only. The metadata files hold no secret and are removed with the installer's temporary directory.
  - *What leaves the machine.* Built images go to the registry the operator names. They hold the platform's code and no secret: Secrets are created in the cluster, never built in.
  - *Container agents.* The allowed prefix is narrower than the registry, so platform images cannot be run as container agents. Pull policy stays `Always`.
- **Compatibility.** No change for existing users. The new chart values are additive and empty by default.

## Test plan

All offline, no cluster, no registry.

1. `hack/ci/cluster-test.sh`: `remote` returns `KUBE_CONTEXT`; `cluster_exists` calls a fake `kubectl` only; `cluster_create`, `cluster_ctr`, `cluster_node` and `cluster_network` fail with the message; kind and k3d unchanged.
2. A new installer test with fake `docker`, `helm`, `kubectl` and `kind` that record their arguments:
   - with `remote`: one `buildx build --platform linux/amd64 --push --provenance=false --sbom=false --metadata-file` per rendered image; the `--set-string` repository, tag and digest lines for every rendered image path; no `kind load`, no `k3d image import`, no `docker exec`;
   - each refusal above, with nothing recorded after the refusal;
   - kind and k3d: the recorded commands are the same as before this change;
   - a canary value in a credential-like environment variable never appears in any recorded argument or in the log;
   - a metadata file without a digest stops the install before `helm upgrade`.
3. `QUICKSTART_BYO=1` with `remote`: the fake push prints a digest; the applied `AgentDefinition` has `<repository>@<digest>`; the values overlay has the `openagentix-examples/` prefix and no `IfNotPresent`; `kind-image-digest.sh` is not called.
4. Chart tests (`charts/openagentix/tests/run.sh`): each of the eight `image.digest` values renders `repository:tag@digest`; a bad digest fails with its path; the default render is byte-identical (also with `OA_BASELINE_RENDER`).
5. Live proof with the GKE run of #31: every platform pod's image is `...@sha256:` from the registry; `kubectl get events` shows no pull error. Not part of this record's acceptance.

## Slices

1. `CLUSTER_TYPE=remote` and the refusal rules in `hack/cluster.sh` and the preflight (test 1 and the refusal part of test 2).
2. The eight `image.digest` chart values (test 4).
3. Build, push and the `--set-string` lines (test 2).
4. The sample container agent on `remote` (test 3).
5. Cross-compiling Dockerfiles (`FROM --platform=$BUILDPLATFORM`, `GOOS` and `GOARCH` from `TARGETOS` and `TARGETARCH`), so `linux/arm64` and builds on Apple silicon are fast. Optional; it also changes the release build, so the release dry run must pass.
6. Later, each with its own decision: the example skill pushed to `IMAGE_REGISTRY`; installing from signed release images (option B); registries that need pull secrets.

## Not checked / open points

- *Unverified*: nothing here has run. No image has been pushed by the installer and no GKE node has pulled one.
- *Unverified*: that `--metadata-file` writes `containerimage.digest` for a pushed single-platform image and for an image index with the buildx version on the operator's machine. Read in the buildx documentation, not run here. The test uses a fake.
- *Unverified*: that the base image digests pinned by #145 are image indexes that include `linux/amd64` and `linux/arm64`. If a digest names one platform's manifest only, a build for the other platform fails. Check with `docker buildx imagetools inspect` before slice 3.
- *Unverified*: that the node service account with `roles/artifactregistry.reader` is enough on GKE. Taken from search result summaries of Google's documentation (GKE guide).
- Open: should the installer skip the build and push when the tag already exists in the registry? It would save minutes, but the content tag does not include the platform or the builder, so a tag built for `arm64` would be taken for `amd64`. Not in slice 3.
- Open: should the tag include the platform (`dev-<hash>-amd64`) on `remote`? Today a second install with another `IMAGE_PLATFORM` overwrites the tag. Pods are safe because of the digest, but a person reading the tag is misled.
- Open: the released chart names `openagentix/<name>:dev`, which no registry serves. Pointing it at `ghcr.io/openagentix/<name>` by digest is part of option B and touches ADR 0018.
- Open: whether `examples/agents/echo-a2a/Dockerfile` should be pinned by digest like the services. It is a sample, but on `remote` it is pushed and run.
- Every image the installer pushes is public or private as the registry decides. The installer does not check it. A public repository exposes the platform's code only, which is public anyway.
