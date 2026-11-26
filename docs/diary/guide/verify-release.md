---
title: Verify a release
sidebar_position: 3.8
description: How to check that an OpenAgentix image, the chart and the release files were built and signed by the project's release workflow, with cosign and gh.
---

# Verify a release

Every release image, the Helm chart and the files attached to a GitHub release are signed by the release workflow of this repository. This page shows how to check that before you install. The decision behind it is [ADR 0018](https://github.com/openagentix/openagentix/blob/main/docs/decisions/0018-release-signing-and-sbom.md).

:::caution Not proven yet
The signing steps have not run on a real tag. The first release made with them is the first proof. Until then, this page describes what the workflow is built to do. See [what works](../what-works.md).
:::

## What is signed, and by whom

| Artefact | Where it is | Signature | Attestations |
|---|---|---|---|
| Each service image | `ghcr.io/openagentix/<name>@sha256:...` | cosign, keyless | SPDX SBOM (cosign, type `spdxjson`); SLSA build provenance (GitHub) |
| The Helm chart | `oci://ghcr.io/openagentix/charts/openagentix` | cosign, keyless | SLSA build provenance (GitHub) |
| Release files: `sbom-<name>-<version>.spdx.json`, `sbom-console-web-<version>.spdx.json`, `openagentix-<version>.tgz`, `image-digests-<version>.txt` | the GitHub release page | listed in `SHA256SUMS`, which is signed (`SHA256SUMS.sigstore.json`) | SLSA build provenance for each file (GitHub) |

"Keyless" means there is no long-lived project key. The workflow job asks GitHub for an identity token, and Sigstore's certificate authority (Fulcio) issues a certificate for ten minutes that names the workflow. The signature is written to Sigstore's public log (Rekor). When you verify, you check the name in that certificate. There is no public key to download.

The signer is always this identity:

| Field | Value |
|---|---|
| Certificate identity | `https://github.com/openagentix/openagentix/.github/workflows/release.yml@refs/tags/vX.Y.Z` |
| Identity, any release (regular expression) | `^https://github\.com/openagentix/openagentix/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$` |
| OIDC issuer | `https://token.actions.githubusercontent.com` |
| Workflow trigger | `push` (a release is made only by a tag push) |

A signature made by another workflow, a branch, a fork or a person does not match. Pin the exact tag when you can.

What the identity does not prove: the tag is on `main`. Anyone who may push a `v*` tag to this repository can push it on any commit, and the release workflow of that commit runs and gets a certificate with this identity. The workflow checks that the tag is on `main`, but that check is part of the commit that is run, so it cannot protect against its own commit. The control is a ruleset named `release-tags` on the repository for `refs/tags/v*` (set on 2026-11-26): only repository admins may create a tag, and updating, deleting and force-pushing one are blocked. No real tag has run yet, so this is not proven by a release. See "Limits".

## What you need

- [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) v3 or newer. The workflow signs with v3.1.4.
- [gh](https://cli.github.com/) 2.83.0 or newer (the version tested), logged in (`gh auth login`), for the provenance checks. They are optional.
- The digests. Take them from `image-digests-<version>.txt` after you have checked that file against `SHA256SUMS` (see "Check the release files"), not from text copied from the release page. The release notes list the same digests but are not signed. Always verify a digest, not a tag, and pull by that digest: a tag such as `:0.3.0` can be moved to another image, a digest cannot.
- `--tag` (or the exact identity) instead of the regular expression. With the regular expression, an older release that is still signed also passes, so a downgrade to a release with a known bug would not be noticed. A writer who overwrites a tag on ghcr.io from a branch run cannot make a matching signature, because a branch run has a different identity (`@refs/heads/...`) and trigger.

The examples use `v0.3.0` and the `kb` image. Put in your version and digest.

```sh
TAG=v0.3.0
IMG=ghcr.io/openagentix/kb@sha256:<digest from the release notes>
ID="https://github.com/openagentix/openagentix/.github/workflows/release.yml@refs/tags/$TAG"
ISSUER=https://token.actions.githubusercontent.com
```

## Check an image

The signature:

```sh
cosign verify \
  --certificate-identity "$ID" \
  --certificate-oidc-issuer "$ISSUER" \
  --certificate-github-workflow-trigger push \
  --certificate-github-workflow-repository openagentix/openagentix \
  "$IMG"
```

Expected: `The following checks were performed on each of these signatures` and a JSON list. Any error means do not use the image.

The SBOM attestation, and the SBOM itself:

```sh
cosign verify-attestation --type spdxjson \
  --certificate-identity "$ID" \
  --certificate-oidc-issuer "$ISSUER" \
  --certificate-github-workflow-trigger push \
  "$IMG" > /dev/null && echo "SBOM attestation ok"

# print the package names in the signed SBOM
cosign verify-attestation --type spdxjson \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$IMG" \
  | jq -r '.payload | @base64d | fromjson | .predicate.packages[].name' | sort -u | head
```

The build provenance (which workflow, commit and runner built it):

```sh
gh attestation verify "oci://$IMG" \
  --repo openagentix/openagentix \
  --cert-identity "$ID" \
  --source-ref "refs/tags/$TAG"
```

## Check the chart

The chart has a signature and provenance, but no SBOM (see "Limits" below). Get its digest first:

```sh
helm pull oci://ghcr.io/openagentix/charts/openagentix --version "${TAG#v}"   # prints "Digest: sha256:..."
CHART=ghcr.io/openagentix/charts/openagentix@sha256:<that digest>

cosign verify --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" \
  --certificate-github-workflow-trigger push "$CHART"
gh attestation verify "oci://$CHART" --repo openagentix/openagentix \
  --cert-identity "$ID" --source-ref "refs/tags/$TAG"
```

## Check the release files

Download all files of the release into an empty directory, check the signature of `SHA256SUMS`, then the files it lists:

```sh
mkdir openagentix-$TAG && cd openagentix-$TAG
gh release download "$TAG" --repo openagentix/openagentix

cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" \
  --certificate-github-workflow-trigger push SHA256SUMS
sha256sum -c SHA256SUMS          # macOS: shasum -a 256 -c SHA256SUMS
```

One file on its own, with its provenance:

```sh
gh attestation verify "openagentix-${TAG#v}.tgz" --repo openagentix/openagentix \
  --cert-identity "$ID" --source-ref "refs/tags/$TAG"
```

## All at once: `hack/verify-release.sh`

The script runs the same checks and prints one line per check. With `--checksums` it also checks the provenance of every file listed in `SHA256SUMS`. The release workflow runs it before it creates a release, so a release without a signature, an SBOM or provenance is not published.

```sh
hack/verify-release.sh --tag v0.3.0 \
  ghcr.io/openagentix/kb@sha256:<digest> ghcr.io/openagentix/a2a-gate@sha256:<digest>
hack/verify-release.sh --tag v0.3.0 --no-sbom ghcr.io/openagentix/charts/openagentix@sha256:<digest>
hack/verify-release.sh --tag v0.3.0 --checksums openagentix-v0.3.0/SHA256SUMS
```

- Without `--tag`, a signature from any release tag of this workflow is accepted (the regular expression above).
- `--no-provenance` skips `gh`, for a machine without a GitHub login.
- `--dry-run` prints the commands and runs nothing.
- `--repo owner/name` checks a fork that runs the same workflow.

Exit code 0: every check passed. 1: a check failed. 2: wrong usage or a missing tool. Its tests use a fake cosign and gh: `hack/ci/verify-release-test.sh`.

## Enforce it in a cluster

To refuse unsigned OpenAgentix images at admission time, use a policy engine with the same identity and issuer, for example a Sigstore policy-controller `ClusterImagePolicy` or a Kyverno `verifyImages` rule with `subject` set to the regular expression above and `issuer` set to `https://token.actions.githubusercontent.com`. The project does not ship such a policy and has not tested one.

## Limits

- **Who can make a release that verifies.** Since 2026-11-26 the `release-tags` ruleset for `refs/tags/v*` limits tag creation to repository admins and blocks updates, deletes and force-pushes. Still, anyone who can change `release.yml` on the commit that is tagged can change what the workflow does, so the signature proves "built by this repository's release workflow for this tag", not "approved by a maintainer". A protected `release` environment with required reviewers would add a second person before signing; it is not set up.
- **Floating inputs in the signed build.** buildx, BuildKit and the Dockerfile frontend are pinned (version or digest). The `golang:1.25` build images and the `distroless/static:nonroot` base images of most Dockerfiles are still pinned by tag only (the console's are pinned by digest). Pinning them by digest is pull request #83. This must be fixed before the first real tag, or the SBOM and provenance describe an image whose base can change between two builds of the same commit.
- **Unproven.** No tag has run the signing steps. The cosign v3 signature format on ghcr.io (OCI referrers, or the fallback tag), `gh attestation verify` on an OCI Helm chart, and the private-by-default visibility of new ghcr.io packages are untested.
- **The chart has no SBOM.** It holds templates and no third-party code. The software it runs is in the image SBOMs and, for the upstream components that `install.sh` adds, in [THIRD-PARTY.md](https://github.com/openagentix/openagentix/blob/main/THIRD-PARTY.md).
- **The SBOM is what syft finds in the image.** For a Go binary that is the module list compiled in; for the distroless base, the Debian packages it records. Files syft cannot identify are not listed. It is not a licence review.
- **The console's web app.** The console image embeds a built Svelte app. syft cannot see its npm packages in the Go binary, so they are not in the image SBOM. They are in a separate release file, `sbom-console-web-<version>.spdx.json`, made from `console/pnpm-lock.yaml`. That file lists the whole lockfile, build and test tools included, and is not attached to the image as an attestation.
- **Provenance is SLSA build level 2 at most:** a hosted runner and a signed statement made by the same workflow that built the image. It is not an isolated builder (SLSA build level 3).
- **Trust is in GitHub and in Sigstore's public instance.** Both issue and record the identity that is checked here.
- **The git tag itself is not signed yet.**
- **Images are linux/amd64 only.**
