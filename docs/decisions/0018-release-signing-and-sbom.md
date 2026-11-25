# ADR 0018: how release artefacts are signed, described and verified

Status: Proposed
Date: 2026-11-25
Issue: https://github.com/openagentix/openagentix/issues/7
Replaces: none

Every release image and the chart are signed with keyless cosign by the release workflow, each image carries an SPDX SBOM, everything gets SLSA build provenance, and the signer identity below becomes a public contract that users and admission policies check.

## Context

The release workflow (`.github/workflows/release.yml`, issue #6) pushes one image per service to `ghcr.io/openagentix/<name>`, the chart to `oci://ghcr.io/openagentix/charts/openagentix`, and creates a GitHub release. Nothing was signed and there was no SBOM. ADR 0011 lists signed artefacts and an SBOM as a foundation readiness item for 0.3, and they are inputs to the OpenSSF Scorecard checks.

The installer already checks a third party this way: `components/channels/kourier.sh` verifies Agent Kourier's chart and image with `cosign verify` against the identity `.../.github/workflows/release.yml@refs/tags/vX.Y.Z`. We follow the same pattern, so a user checks our artefacts the way we check theirs.

Facts read on 2026-11-25: cosign v3.1.4 (2026-10-20), sigstore/cosign-installer v4.1.3, actions/attest-build-provenance v4.2.2, syft v1.57.0. Newer releases from the last two days were not chosen.

## Options

| Option | What it gives | What it costs | Checked how |
|---|---|---|---|
| A. Keyless cosign (GitHub OIDC, public Sigstore) + syft SBOM as a cosign attestation + GitHub build provenance | No key to store, rotate or leak. Signatures in the public log. Same tooling as Kourier, Kyverno and policy-controller understand it. `gh attestation verify` works without cosign | Trust in GitHub's OIDC and in the public Sigstore instance. Two places for attestations (registry and GitHub) | `cosign verify` with the script's flags passed against Agent Kourier's real image and chart; wrong tag refused |
| B. cosign with a long-lived key in a repository secret | Verification needs only the public key | A secret to protect and rotate; a leak signs anything. The workflow uses no secret today | not built |
| C. buildx `--sbom` and `--provenance` | One step, BuildKit attestations | The pushed digest becomes an image index, so the digest in the release notes is not the image you pull; tools read these attestations less widely than cosign ones | rejected on reading |
| D. Do nothing | nothing to build | 0.3 foundation item not met | - |

## Decision

Option A.

1. **Signatures.** Each image digest and the OCI chart digest is signed with `cosign sign --yes` in the job that pushed it. The signer identity is the release workflow run for a tag:
   - certificate identity `https://github.com/openagentix/openagentix/.github/workflows/release.yml@refs/tags/vX.Y.Z`;
   - OIDC issuer `https://token.actions.githubusercontent.com`.
   This identity is the public contract. Changing the workflow path, the repository or the tag pattern breaks every user's policy, so it needs a new ADR.
2. **SBOM.** syft makes an SPDX JSON SBOM of each pushed image (by digest). It is attached with `cosign attest --type spdxjson` and published as the release asset `sbom-<name>-<version>.spdx.json`. The chart has no SBOM: it holds templates and no third-party code.
3. **Provenance.** `actions/attest-build-provenance` makes a SLSA v1 provenance statement for each image and the chart (stored with GitHub and pushed to the registry), and for each release asset.
4. **Release files.** `SHA256SUMS` lists the chart package, the SBOMs and the image digest list. It is signed with `cosign sign-blob` into `SHA256SUMS.sigstore.json`.
5. **Gate.** Before the release is created, the release job runs `hack/verify-release.sh` on every image, the chart and `SHA256SUMS`. If one check fails, no release is created (images already pushed stay, as today).
6. **Least privilege.** `id-token: write` and `attestations: write` only in the three jobs that sign (`images`, `chart`, `assets`). The release job gets `packages: read` and `attestations: read` for the gate. All actions are pinned by commit SHA. syft is downloaded by `hack/ci/install-tools.sh` and checked by SHA-256.
7. **Dry run.** A manual run signs nothing. It still makes the SBOMs from the locally built images and `SHA256SUMS`, and prints what would be signed and the exact verify commands.

The guide for users is `docs/diary/guide/verify-release.md`.

## Consequences

- Users can check, before install, that an image or the chart came from this repository's release workflow for a given tag, and see what is inside an image.
- Admission policies (Kyverno, Sigstore policy-controller) can be written against the identity above. The project does not ship one yet.
- Security impact: the jobs that sign can get a signing certificate for the release workflow identity. Anyone who can push a `v*` tag on `main` or change `release.yml` on `main` can make a release that verifies, so the trust rests on branch protection and on who may push tags. Nothing secret is added; the only token is still `GITHUB_TOKEN`. Signatures and SBOMs are public (the Rekor log, the registry), and they hold no secret: package names, versions and the workflow identity.
- Compatibility: no change for users who do not verify. The image digests do not change (no image index).
- Tests: `hack/ci/verify-release-test.sh` (fake cosign and gh) in `make test-shell` and the `shell` job; `actionlint`. Proof needed before this counts as done: one real tag run, then the commands of the guide run against its output.

## Not checked / open points

- *Unverified*: no tag has run the signing steps. cosign v3 writes the new Sigstore bundle format through the OCI referrers API or its fallback tag; whether ghcr.io serves it to every verifier is untested here.
- *Unverified*: `gh attestation verify oci://...` for an OCI Helm chart.
- New ghcr.io packages may be private at first. The gate logs in read only, so it works, but users cannot pull or verify until a maintainer makes the packages public.
- The git tag is not signed. A signed tag (`git tag -s`) or a tag ruleset is a separate step.
- The SBOM lists what syft finds. It is not a licence review; `THIRD-PARTY.md` stays the licence record.
- SLSA build level 3 (an isolated builder, for example the SLSA GitHub generator) is not reached and not planned for 0.3.
