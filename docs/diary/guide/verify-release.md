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
| Release files: `sbom-<name>-<version>.spdx.json`, `openagentix-<version>.tgz`, `image-digests-<version>.txt` | the GitHub release page | listed in `SHA256SUMS`, which is signed (`SHA256SUMS.sigstore.json`) | SLSA build provenance for each file (GitHub) |

"Keyless" means there is no long-lived project key. The workflow job asks GitHub for an identity token, and Sigstore's certificate authority (Fulcio) issues a certificate for ten minutes that names the workflow. The signature is written to Sigstore's public log (Rekor). When you verify, you check the name in that certificate. There is no public key to download.

The signer is always this identity:

| Field | Value |
|---|---|
| Certificate identity | `https://github.com/openagentix/openagentix/.github/workflows/release.yml@refs/tags/vX.Y.Z` |
| Identity, any release (regular expression) | `^https://github\.com/openagentix/openagentix/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$` |
| OIDC issuer | `https://token.actions.githubusercontent.com` |

A signature made by any other workflow, branch, fork or person does not match. Pin the exact tag when you can.

## What you need

- [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) v3 or newer. The workflow signs with v3.1.4.
- [gh](https://cli.github.com/), a version with `gh attestation verify --signer-workflow`, logged in (`gh auth login`), for the provenance checks. They are optional.
- The digests. The release notes list every image as `ghcr.io/openagentix/<name>@sha256:...`, and the file `image-digests-<version>.txt` holds the same list. Always verify a digest, not a tag: a tag can be moved, a digest cannot.

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
  --certificate-github-workflow-repository openagentix/openagentix \
  "$IMG"
```

Expected: `The following checks were performed on each of these signatures` and a JSON list. Any error means do not use the image.

The SBOM attestation, and the SBOM itself:

```sh
cosign verify-attestation --type spdxjson \
  --certificate-identity "$ID" \
  --certificate-oidc-issuer "$ISSUER" \
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
  --signer-workflow openagentix/openagentix/.github/workflows/release.yml \
  --source-ref "refs/tags/$TAG"
```

## Check the chart

The chart has a signature and provenance, but no SBOM (see "Limits" below). Get its digest first:

```sh
helm pull oci://ghcr.io/openagentix/charts/openagentix --version "${TAG#v}"   # prints "Digest: sha256:..."
CHART=ghcr.io/openagentix/charts/openagentix@sha256:<that digest>

cosign verify --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" "$CHART"
gh attestation verify "oci://$CHART" --repo openagentix/openagentix \
  --signer-workflow openagentix/openagentix/.github/workflows/release.yml --source-ref "refs/tags/$TAG"
```

## Check the release files

Download all files of the release into an empty directory, check the signature of `SHA256SUMS`, then the files it lists:

```sh
mkdir openagentix-$TAG && cd openagentix-$TAG
gh release download "$TAG" --repo openagentix/openagentix

cosign verify-blob --bundle SHA256SUMS.sigstore.json \
  --certificate-identity "$ID" --certificate-oidc-issuer "$ISSUER" SHA256SUMS
sha256sum -c SHA256SUMS          # macOS: shasum -a 256 -c SHA256SUMS
```

One file on its own, with its provenance:

```sh
gh attestation verify "openagentix-${TAG#v}.tgz" --repo openagentix/openagentix \
  --signer-workflow openagentix/openagentix/.github/workflows/release.yml
```

## All at once: `hack/verify-release.sh`

The script runs the same checks and prints one line per check. The release workflow runs it before it creates a release, so a release without a signature, an SBOM or provenance is never published.

```sh
hack/verify-release.sh --tag v0.3.0 \
  ghcr.io/openagentix/kb@sha256:<digest> ghcr.io/openagentix/a2a-gate@sha256:<digest>
hack/verify-release.sh --tag v0.3.0 --no-sbom ghcr.io/openagentix/charts/openagentix@sha256:<digest>
hack/verify-release.sh --tag v0.3.0 --no-provenance --checksums openagentix-v0.3.0/SHA256SUMS
```

- Without `--tag`, a signature from any release tag of this workflow is accepted (the regular expression above).
- `--no-provenance` skips `gh`, for a machine without a GitHub login.
- `--dry-run` prints the commands and runs nothing.
- `--repo owner/name` checks a fork that runs the same workflow.

Exit code 0: every check passed. 1: a check failed. 2: wrong usage or a missing tool. Its tests use a fake cosign and gh: `hack/ci/verify-release-test.sh`.

## Enforce it in a cluster

To refuse unsigned OpenAgentix images at admission time, use a policy engine with the same identity and issuer, for example a Sigstore policy-controller `ClusterImagePolicy` or a Kyverno `verifyImages` rule with `subject` set to the regular expression above and `issuer` set to `https://token.actions.githubusercontent.com`. The project does not ship such a policy and has not tested one.

## Limits

- **Unproven.** No tag has run the signing steps. The cosign v3 signature format on ghcr.io (OCI referrers, or the fallback tag), `gh attestation verify` on an OCI Helm chart, and the private-by-default visibility of new ghcr.io packages are untested.
- **The chart has no SBOM.** It holds templates and no third-party code. The software it runs is in the image SBOMs and, for the upstream components that `install.sh` adds, in [THIRD-PARTY.md](https://github.com/openagentix/openagentix/blob/main/THIRD-PARTY.md).
- **The SBOM is what syft finds in the image.** For a Go binary that is the module list compiled in; for the distroless base, the Debian packages it records. Files syft cannot identify are not listed. It is not a licence review.
- **Provenance is SLSA build level 2 at most:** a hosted runner and a signed statement made by the same workflow that built the image. It is not an isolated builder (SLSA build level 3).
- **Trust is in GitHub and in Sigstore's public instance.** A person who can push a `v*` tag to `main`, or who can change `release.yml` on `main`, can make a release that verifies. Branch protection and the tag rules are what stop that.
- **The git tag itself is not signed yet.**
- **Images are linux/amd64 only.**
