# ADR 0022: build images for a remote cluster and push them to a registry

Status: Accepted (2026-11-26)
Date: 2026-11-26
Issue: https://github.com/openagentix/openagentix/issues/162 (umbrella #31)
Replaces: none. Adds to ADR 0014 (quick start) and ADR 0015 (container agents); does not change ADR 0018 (release signing).

The 7-day review period was waived by the maintainer on 2026-11-26 after a real GKE run (#31); an independent review was done and its changes are in this text.

With `CLUSTER_TYPE=remote`, the installer builds every image it needs with `docker buildx` for `IMAGE_PLATFORM` (default `linux/amd64`), pushes it to `IMAGE_REGISTRY`, checks what it pushed, and gives the chart the repository, the tag and the pushed digest of each image. The node pulls by digest. No platform image on a remote cluster comes from an unqualified default name. On kind and k3d nothing changes.

## Context

Facts read in this repository on 2026-11-26 (commit `b6afd1d`):

- **Remote mode exists** (#176, #179, #185). `CLUSTER_TYPE=remote` needs `KUBE_CONTEXT`; `cluster_exists` asks `get --raw /version`; `cluster_create`, `cluster_node`, `cluster_network`, `cluster_ctr` and `cluster_load_images` fail with a message (`hack/cluster.sh`); a local context name is refused unless `ALLOW_LOCAL_CONTEXT=1`; node settings are opt-in (`NODE_SETTINGS`); `hack/preflight.sh` checks the cluster read-only. The installer already refuses, on remote, `QUICKSTART_BYO=1` (`install.sh:151`), the example skill without `SKIP_SKILL=1` (`install.sh:287-289`), `MODEL_PROVIDER=ollama` without `MODEL_BASE_URL`, and any locally built image (`install.sh:290-295`, "a registry push, IMAGE_REGISTRY, issue #162, is not built").
- **Builds.** `install.sh:194-231`: `queue_build` collects images, `tag_image` (`:199`) sets the tag to `dev-<hash of the source>` (`hack/image-tag.sh`) and passes `--set-string <path>.image.tag=<tag>`, `start_builds` runs `docker build -q -t <image> <context>` in the background, and `finish_builds` calls `cluster_load_images`. There is no push and no `--platform`. The installer decides which images to build by matching the rendered image against the default name (`openagentix/<name>:*`), and `tag_image` keeps the repository part (`${!v%:*}`).
- **Chart images.** Eight images are built by the installer, each `{repository, tag, pullPolicy}`, rendered with `printf "%s:%s"`: `bridge.yaml:42`, `schedules.yaml:89`, `stub-model.yaml:52` (without `toString` on the tag), `knowledge.yaml:113`, `notify.yaml:51`, `governance.yaml:86`, `control-plane.yaml:231`, `console.yaml:198`. The defaults are `openagentix/<name>:dev`. A container runtime reads such an unqualified name as `docker.io/openagentix/<name>:dev`. No template accepts a digest or `imagePullSecrets`.
- **The first GKE run** (`docs/diary/guide/install-gke.md`, 2026-11-26) built the four images the quick start needs (`governance.a2a`, `gateway.stubModel`, `controlPlane`, `console`) in Cloud Build for `linux/amd64`, pushed them to Artifact Registry with the tag `gke1`, and passed them in a values file with `SKIP_*_IMAGE=1`. The nodes ran as the default compute service account with `roles/container.defaultNodeServiceAccount` and pulled the images.
- **Container agents.** The sample is `registry.local/oa/echo-a2a`, loaded into the node, its digest read with `hack/kind-image-digest.sh`. `components/quickstart/byo-values.yaml` sets the prefix list `["registry.local/oa/"]` and `imagePullPolicy: IfNotPresent`. The guard accepts `^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}$` (`control-plane-guard-workload.yaml:203`): Artifact Registry paths pass, and a tag next to the digest is refused. `examples/agents/echo-a2a/Dockerfile` is not pinned by digest.
- **Release.** The release workflow (ADR 0018) builds with buildx for `linux/amd64`, `provenance: false`, `sbom: false`, pushes to `ghcr.io/openagentix/<name>` (`<name>` from `hack/ci/dockerfiles.sh`) and signs. The released chart still names `openagentix/<name>:dev`.
- **Base images.** `golang:1.25`, `gcr.io/distroless/static:nonroot` and `node:22`, at the digests pinned by #145, are OCI image indexes that include `linux/amd64` and `linux/arm64/v8` (read with `docker buildx imagetools inspect --raw` on 2026-11-26).

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. `docker buildx build --platform --push` to a registry the operator names; the installer checks the pushed digest and gives the chart repository, tag and digest | Works from any laptop for any node architecture; pods run the exact digest; no credential passes through the installer | A new chart value per image (`image.digest`); a registry and a login are needed first; a foreign platform is slow on a local builder | Read `install.sh`, the chart and the release workflow; the GKE run used the same registry with images built elsewhere |
| B. Use the signed release images from `ghcr.io/openagentix` by digest | Signed, with SBOM and provenance (ADR 0018); no build | No release has run; a branch cannot be tried; the released chart does not point there | ADR 0018 |
| C. `docker build`, `docker tag`, `docker push` per image | No buildx | One platform, the host's unless set; no image index | not built |
| D. Build inside the cluster (BuildKit or kaniko pod) | No local Docker | A builder and registry write credentials in the cluster | rejected on reading |
| E. Put the digest into the tag value | No chart change | A convention the chart cannot check | rejected on reading |
| F. No digest, `pullPolicy: Always` | No new value | A moved tag changes what a restarting pod runs | rejected on reading |

## Decision

Option A. Option B stays the target for users who install a release; it needs its own decision once a release exists.

### New switches

| Switch | Values | Default | Rule |
|---|---|---|---|
| `IMAGE_REGISTRY` | `host[:port]/path` | none | **required** with `remote` when the installer builds at least one image; **refused** with `kind` and `k3d` |
| `IMAGE_PLATFORM` | `linux/amd64` or `linux/arm64` (slice 3); both, comma separated (slice 5) | `linux/amd64` with `remote` | **refused** with `kind` and `k3d` |
| `IMAGE_REBUILD` | `1` | unset | build and push even when the tag already exists in the registry |
| `BUILDX_BUILDER` | a buildx builder name | the current builder | read by buildx itself; a remote amd64 builder is the fast path on Apple silicon |

Refusals happen before anything changes, with one sentence each:

- `IMAGE_REGISTRY` or `IMAGE_PLATFORM` with `kind` or `k3d`.
- `IMAGE_REGISTRY` that does not match `^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]+([._-][a-z0-9]+)*)+$`: lower case, a host with a dot or a port, at least one path part, no scheme, no trailing slash, no tag, no digest, no `user:password@`.
- `IMAGE_REGISTRY` whose normalised host is `ghcr.io` (a `:443` port removed) and whose first path part is exactly `openagentix`. So `ghcr.io/openagentix` and `ghcr.io:443/openagentix/x` are refused, and `ghcr.io/openagentix-dev` is allowed. That path holds the signed release images. The rule prevents a mistake: it is not a security control, since anyone with write access there could push without the installer.
- No `docker buildx` (`docker buildx version` fails), when an image is to be built.
- `IMAGE_PLATFORM` with a value not in the table, or with two platforms before slice 5.

`install.sh:290-295`, the stop for locally built images on remote, is replaced by the build and push below.

### Build, push and check

- **Repository.** `$IMAGE_REGISTRY/openagentix/<name>`, with `<name>` from `hack/ci/dockerfiles.sh`. The installer still chooses what to build by matching the default name `openagentix/<name>:*` in the render, then sets the repository.
- **Tag on remote.** `dev-<hash of the source>-<arch>`, for example `dev-3f2a…-amd64`. The platform is in the tag, so two installs for different platforms never share a tag. On kind and k3d the tag stays `dev-<hash>`.
- **Existing tag.** Before a build, the installer reads the tag with `docker buildx imagetools inspect`. If it exists and its platform matches `IMAGE_PLATFORM`, the installer uses that digest and does not build or push. The content tag names the source; the registry is trusted to hold what was pushed under it, so the registry should be dedicated to this install. If it exists with another platform, the installer stops: "tag X exists for platform Y, not Z; delete it or set IMAGE_REBUILD=1". With `IMAGE_REBUILD=1` the installer pushes again: a mutable registry moves the tag to the new digest, an immutable one refuses the push and the installer stops with the registry's message and "this registry does not allow overwriting a tag; remove IMAGE_REBUILD".
- **Command.** In the same background queue and `BUILD_JOBS` as today:
  `docker buildx build --platform "$IMAGE_PLATFORM" --push --provenance=false --sbom=false --metadata-file <tmp>/<name>.json -t <repository>:<tag> [-f <Dockerfile>] <context>`.
  One platform gives one plain manifest, as in the release.
- **Digest.** From the metadata file (`containerimage.digest`), checked against `^sha256:[0-9a-f]{64}$`.
- **Check after the push.** `docker buildx imagetools inspect --raw <repository>@<digest>` must succeed, so the digest exists in the registry. The image config's `os` and `architecture` must equal `IMAGE_PLATFORM`. For two platforms (slice 5) the digest must be an index whose `manifests[].platform` lists exactly those platforms. A failed check stops the install before `helm upgrade`.
- **Chart.** For each built image path `P`: `--set-string P.image.repository=<repository>`, `P.image.tag=<tag>`, `P.image.digest=<digest>`. Nothing calls `kind load`, `k3d image import` or `docker exec`.
- **Two platforms** (slice 5) need a builder that can hold an image index: the `docker-container` driver, a remote builder, or Docker with the containerd image store. Preflight reads `docker buildx inspect` and refuses two platforms on a plain `docker` driver without that store.
- **Later images.** Every image the installer builds later (for example the egress proxy of ADR 0020) follows the same rule and uses the same chart helper.

The build, push, existing-tag and check steps live in a sourced file, `hack/images.sh`, so they can be tested alone.

### The rule for platform images on remote

After the final render, and before `helm upgrade`, the installer checks every image of the eight paths above that the render contains:

- No image may be an unqualified name. The first part must contain a dot or a port, or the install stops. So the default `openagentix/<name>:dev`, which would mean Docker Hub, is never pulled on a remote cluster.
- With `IMAGE_REGISTRY` set, every such image must start with `$IMAGE_REGISTRY/`.
- An image the installer built must have a digest.
- An image the operator supplies (the build skipped with `SKIP_*_IMAGE=1`, the repository set in a values file, as in the GKE run) may be given by tag. The installer then warns once per image: "P runs X by tag; set P.image.digest to pin it". With `P.image.digest` set it is pinned like a built image.

### New chart values (public contract)

- `image.digest` under each of `bridge`, `scheduling`, `gateway.stubModel`, `knowledge.kb`, `notify`, `governance.a2a`, `controlPlane`, `console`. Default `""`. When set it must match `^sha256:[0-9a-f]{64}$`, or the render fails with the path.
- One helper, `oa.image`, renders every one of the eight images (and ADR 0020's egress proxy image) and validates them:
  - tag set, no digest: `"repository:tag"`, the same quoted string as today, so the default render is byte-identical;
  - tag and digest: `"repository:tag@digest"`;
  - empty tag and digest: `"repository@digest"`, never `repository:@digest`;
  - empty tag and no digest: the render fails.
  The tag is passed through `toString` in all eight, which changes nothing for the string defaults.
- `pullPolicy` stays `IfNotPresent`. A digest cannot point at a stale image.
- The kind path stays the same, because the installer sets `image.digest` only on remote.

### How the node pulls

- The installer never receives, stores or passes a registry credential and never runs `docker login`. The push uses the operator's existing Docker login (for Artifact Registry: `gcloud auth configure-docker <region>-docker.pkg.dev`).
- The node pulls with its own credentials. On GKE, the GKE run pulled from Artifact Registry in the same project with the default compute service account and `roles/container.defaultNodeServiceAccount`. The recommendation is a dedicated node service account with `roles/container.defaultNodeServiceAccount` and `roles/artifactregistry.reader` on the one repository. No `imagePullSecrets` is needed in that case. Workload Identity does not take part: it gives pods an identity for Google APIs, while the kubelet pulls with the node's credentials.
- A registry that needs `imagePullSecrets` is not supported. ADR 0015 refuses them for container agents. A chart-wide pull secret is a separate decision.

### Container agents on a remote cluster (`QUICKSTART_BYO=1`)

The refusal at `install.sh:151` is replaced by this, in slice 4:

- The sample is pushed like the others, to `$IMAGE_REGISTRY/openagentix-examples/echo-a2a`, and checked the same way. The `AgentDefinition` gets `<repository>@<digest>` with no tag, which is what the guard accepts.
- `controlPlane.policy.runtimes.container.images` is a list, and Helm replaces lists. The installer sets it to `["$IMAGE_REGISTRY/openagentix-examples/"]` only when the merged list is empty or is the quick start's own `["registry.local/oa/"]`. Any other list is the operator's, and the installer stops: "your values set runtimes.container.images; add $IMAGE_REGISTRY/openagentix-examples/ to it yourself". The path is separate on purpose: a prefix of `$IMAGE_REGISTRY/` or `$IMAGE_REGISTRY/openagentix/` would let a user run a platform image as a container agent.
- `controlPlane.containerAgents.imagePullPolicy` stays `Always`. The `IfNotPresent` of `byo-values.yaml` is not applied on remote. `hack/kind-image-digest.sh` is not called.
- `examples/agents/echo-a2a/Dockerfile` is pinned by digest before slice 4, like the services.

### Defaults

Off and unchanged by default. Without `CLUSTER_TYPE=remote` the installer runs exactly the commands of today. The quick start on kind and k3d is unchanged. The default chart render is byte-identical.

## Consequences

- The quick start installs on a remote cluster from one command, with the four images it needs built and pushed by the installer.
- An operator needs a registry, write access from the laptop and read access from the nodes.
- Building `linux/amd64` on Apple silicon with the local builder runs the Go compiler under QEMU (slow, not measured). A remote builder (`BUILDX_BUILDER`) or building elsewhere and supplying the images, as in the GKE run, avoids that. Slice 6 makes the Dockerfiles cross-compile.
- **Security impact.**
  - *Supply chain.* These are developer builds. They are not signed and carry no ADR 0018 identity. Pods run the digest the installer pushed and checked, so a later push under the same tag does not change a running or restarting pod. Reusing an existing tag trusts the registry; use one dedicated to the install. No platform image comes from an unqualified name on remote. Base images are pinned by digest.
  - *Credentials.* No registry credential in argv, environment output, files the installer writes, logs or the chart. The installer prints repositories, tags and digests only. The metadata files hold no secret and are removed with the installer's temporary directory.
  - *What leaves the machine.* Built images go to the registry the operator names. They hold the platform's code and no secret.
  - *Container agents.* The allowed prefix is narrower than the registry. Pull policy stays `Always`.
- **Compatibility.** No change for existing users. The new chart values are additive and empty by default. Operator-supplied images by tag, as in the GKE run, keep working, with a warning.

## Test plan

All offline, no cluster, no registry.

1. `hack/images.sh` with a fake `docker` that records its arguments and answers `imagetools inspect` and `--metadata-file` from fixtures:
   - one `buildx build --platform linux/amd64 --push --provenance=false --sbom=false --metadata-file` per image, tag `dev-<hash>-amd64`;
   - an existing tag with the right platform: no build, its digest is used; with another platform: stop with the message; `IMAGE_REBUILD=1` on a registry that refuses: stop with the message;
   - a metadata file without a digest, an `inspect --raw` failure, and a config with the wrong `architecture` each stop before `helm upgrade`;
   - a canary value in a credential-like environment variable never appears in a recorded argument or the log.
2. Installer test with fake `docker`, `helm`, `kubectl`: on remote, the `--set-string` repository, tag and digest lines for every built path; no `kind load`, `k3d image import` or `docker exec`; the final render check refuses an unqualified image, an image outside `$IMAGE_REGISTRY/`, and a built image without a digest; an operator image by tag gives the warning; each refusal under "New switches", with nothing recorded after it, including the `ghcr.io` cases (`ghcr.io:443/openagentix` refused, `ghcr.io/openagentix-dev` allowed).
3. Golden test: on kind and k3d the recorded commands equal a stored list from before this change.
4. `QUICKSTART_BYO=1` on remote: the applied `AgentDefinition` has `<repository>@<digest>`; the prefix is set only for an empty or quick-start list and refused for an operator list; no `IfNotPresent`; `kind-image-digest.sh` not called.
5. Chart tests: each of the eight paths renders `repository:tag@digest` and `repository@digest`; empty tag without digest fails; a bad digest fails with its path; the default render is byte-identical (also with `OA_BASELINE_RENDER`).
6. Live proof with a GKE run (#31): every platform pod's image is `…@sha256:` from the registry; no pull error. Not part of this record's acceptance.

## Slices

1. `IMAGE_REGISTRY`, `IMAGE_PLATFORM` (one platform) and the refusal rules, the buildx check in preflight (part of test 2).
2. The `oa.image` helper and the eight `image.digest` values (test 5).
3. `hack/images.sh`: build, push, existing tag, check; replace the stop at `install.sh:290-295`; the final render rule (tests 1 to 3).
4. Pin `examples/agents/echo-a2a/Dockerfile`; the sample container agent on remote (test 4).
5. Two platforms, with the builder check.
6. Cross-compiling Dockerfiles (`FROM --platform=$BUILDPLATFORM`, `GOOS` and `GOARCH` from `TARGETOS` and `TARGETARCH`). It also changes the release build, so the release dry run must pass.
7. Later, each with its own decision: the example skill pushed to `IMAGE_REGISTRY`; installing from signed release images (option B); registries that need pull secrets.

## Not checked / open points

- *Unverified*: the installer has pushed no image. The GKE run pushed with Cloud Build, by hand.
- *Unverified*: that `--metadata-file` writes `containerimage.digest` for a pushed image with the buildx version on the operator's machine, and the exact output of `imagetools inspect` for the platform check. Read in the buildx documentation; the tests use fixtures.
- *Unverified*: that `roles/artifactregistry.reader` alone (with `roles/container.defaultNodeServiceAccount`) is enough for a dedicated node service account. The GKE run used the default compute service account, which also had project roles.
- The released chart names `openagentix/<name>:dev`. A Helm-only install of the released chart therefore points at Docker Hub. Pointing it at `ghcr.io/openagentix/<name>` by digest is part of option B and touches ADR 0018.
- Whether built images are public or private is the registry's setting. The installer does not check it. They hold only the platform's public code.
