#!/usr/bin/env bash
# Tests for hack/verify-release.sh with a fake cosign and a fake gh (nothing is fetched, nothing is signed).
# The fakes log their arguments, one call per line, and fail when FAKE_FAIL is a substring of the call.
set -u
cd "$(dirname "$0")/../.." || exit 1
S=hack/verify-release.sh
[ -x "$S" ] || { echo "FAIL $S missing or not executable"; exit 1; }
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
for tool in cosign gh; do
  cat > "$D/bin/$tool" <<EOT
#!/usr/bin/env bash
echo "$tool \$*" >> "\$FAKE_LOG"
if [ -n "\${FAKE_FAIL:-}" ]; then case "$tool \$*" in *"\$FAKE_FAIL"*) echo "fake $tool: no matching signature" >&2; exit 1 ;; esac; fi
exit 0
EOT
  chmod +x "$D/bin/$tool"
done
export PATH="$D/bin:$PATH" FAKE_LOG="$D/log"
run(){ : > "$FAKE_LOG"; out=$("$S" "$@" 2>&1); rc=$?; }
calls(){ grep -c -- "$1" "$FAKE_LOG"; }

H=$(printf 'a%.0s' $(seq 64))
IMG="ghcr.io/openagentix/kb@sha256:$H"
CHART="ghcr.io/openagentix/charts/openagentix@sha256:$H"
ISSUER="--certificate-oidc-issuer https://token.actions.githubusercontent.com"
ID_TAG="https://github.com/openagentix/openagentix/.github/workflows/release.yml@refs/tags/v1.2.3"
ID_RE='^https://github\.com/openagentix/openagentix/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

# one image, pinned tag: signature, SBOM attestation, provenance, exact identity
run --tag v1.2.3 "$IMG"
t "image with tag: exit 0" "$rc" 0
t "cosign verify called once with the exact identity" "$(calls "cosign verify --certificate-identity $ID_TAG $ISSUER --certificate-github-workflow-repository openagentix/openagentix $IMG")" 1
t "SBOM attestation checked as spdxjson" "$(calls "cosign verify-attestation --type spdxjson --certificate-identity $ID_TAG $ISSUER")" 1
t "provenance checked with gh for the oci reference" "$(calls "gh attestation verify oci://$IMG --repo openagentix/openagentix --signer-workflow openagentix/openagentix/.github/workflows/release.yml --source-ref refs/tags/v1.2.3")" 1
t "summary says all checks passed" "$(printf '%s\n' "$out" | grep -c '^all 3 checks passed')" 1

# no tag: identity regexp for any release tag of the workflow, no --source-ref
run "$IMG"
t "no tag: exit 0" "$rc" 0
t "no tag: identity regexp" "$(grep -cF -- "cosign verify --certificate-identity-regexp $ID_RE" "$FAKE_LOG")" 1
t "no tag: no exact identity" "$(calls 'certificate-identity https')" 0
t "no tag: no source-ref" "$(calls 'source-ref')" 0

# another repository (a fork that releases): identity and repo follow, dots escaped in the regexp
run --repo some-org/open.agentix "$IMG"
t "repo flag: regexp escapes the dot (signature and SBOM)" "$(grep -cF 'some-org/open\.agentix/\.github' "$FAKE_LOG")" 2
t "repo flag: gh gets the repo" "$(calls 'gh attestation verify .* --repo some-org/open.agentix ')" 1

# the chart has no SBOM: --no-sbom skips that check only
run --tag v1.2.3 --no-sbom "$CHART"
t "chart: exit 0" "$rc" 0
t "chart: no verify-attestation" "$(calls 'verify-attestation')" 0
t "chart: signature still checked" "$(calls "cosign verify .*$CHART")" 1
t "chart: 2 checks" "$(printf '%s\n' "$out" | grep -c '^all 2 checks passed')" 1

# --no-provenance skips gh (for a user without a GitHub login)
run --tag v1.2.3 --no-provenance "$IMG"
t "no-provenance: gh not called" "$(calls '^gh ')" 0

# several references: every one is checked, and a failure in one is reported and fails the run
FAKE_FAIL="ghcr.io/openagentix/notify" run --tag v1.2.3 "$IMG" "ghcr.io/openagentix/notify@sha256:$H"
t "a missing signature fails the run" "$rc" 1
t "both references were checked" "$(calls '^cosign verify --certificate')" 2
t "the failure names the reference" "$(printf '%s\n' "$out" | grep -c "FAIL .*ghcr.io/openagentix/notify")" 3
t "the good reference is ok" "$(printf '%s\n' "$out" | grep -c "ok .*ghcr.io/openagentix/kb@")" 3
FAKE_FAIL="verify-attestation" run --tag v1.2.3 "$IMG"
t "a missing SBOM attestation fails" "$rc" 1
FAKE_FAIL="attestation verify" run --tag v1.2.3 "$IMG"
t "a missing provenance attestation fails" "$rc" 1

# dry run: prints the commands, runs nothing
run --dry-run --tag v1.2.3 "$IMG"
t "dry run: exit 0" "$rc" 0
t "dry run: nothing called" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 0
t "dry run: prints cosign verify" "$(printf '%s\n' "$out" | grep -c "would run: cosign verify --certificate-identity $ID_TAG")" 1
t "dry run: prints gh attestation verify" "$(printf '%s\n' "$out" | grep -c 'would run: gh attestation verify')" 1

# refusals: mutable tags, bad digests, bad versions, bad repos, nothing to check, unknown flags
for bad in ghcr.io/openagentix/kb:1.2.3 ghcr.io/openagentix/kb "ghcr.io/openagentix/kb@sha256:abc" "ghcr.io/openagentix/kb@sha256:${H}0" "-x"; do
  run --tag v1.2.3 "$bad"; t "refuses '$bad'" "$rc" 2
done
t "refusal: nothing called" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 0
for bad in 1.2.3 v1.2 v1.2.3+meta main; do run --tag "$bad" "$IMG"; t "refuses tag '$bad'" "$rc" 2; done
for bad in openagentix "a/b/c" "a b/c" "-r/x"; do run --repo "$bad" "$IMG"; t "refuses repo '$bad'" "$rc" 2; done
run --tag v1.2.3; t "refuses no reference and no checksums" "$rc" 2
run --help; t "help exits 0" "$rc" 0
t "help names the dry run" "$(printf '%s\n' "$out" | grep -q -- '--dry-run' && echo yes)" yes

# checksums file: the signature of the file (bundle next to it), then every listed file
mkdir -p "$D/assets"; printf 'one\n' > "$D/assets/a.spdx.json"; printf 'two\n' > "$D/assets/b.tgz"
( cd "$D/assets" && if command -v sha256sum >/dev/null; then sha256sum a.spdx.json b.tgz; else shasum -a 256 a.spdx.json b.tgz; fi > SHA256SUMS )
: > "$D/assets/SHA256SUMS.sigstore.json"
run --tag v1.2.3 --checksums "$D/assets/SHA256SUMS"
t "checksums: exit 0" "$rc" 0
t "checksums: verify-blob with the bundle" "$(calls "cosign verify-blob --bundle $D/assets/SHA256SUMS.sigstore.json --certificate-identity $ID_TAG $ISSUER $D/assets/SHA256SUMS")" 1
t "checksums: listed files ok" "$(printf '%s\n' "$out" | grep -c '^  ok   checksums of the files listed in')" 1
printf 'changed\n' > "$D/assets/b.tgz"
run --tag v1.2.3 --checksums "$D/assets/SHA256SUMS"
t "checksums: a changed file fails" "$rc" 1
printf 'two\n' > "$D/assets/b.tgz"; rm "$D/assets/SHA256SUMS.sigstore.json"
run --tag v1.2.3 --checksums "$D/assets/SHA256SUMS"
t "checksums: a missing bundle fails" "$rc" 1
t "checksums: missing bundle, cosign not called" "$(calls 'verify-blob')" 0
run --tag v1.2.3 --checksums "$D/nope"
t "checksums: a missing file is refused" "$rc" 2

# no cosign on PATH: a clear error, not a pass
PATH="/usr/bin:/bin" run --tag v1.2.3 "$IMG"
t "no cosign: exit 2" "$rc" 2
t "no cosign: says so" "$(printf '%s\n' "$out" | grep -c 'cosign is not installed')" 1

# the workflow and the docs use the same identity and workflow path as the script
t "workflow file the identity names exists" "$(test -f .github/workflows/release.yml && echo yes)" yes
t "guide names the same identity regexp" "$(grep -qF -- "$ID_RE" docs/diary/guide/verify-release.md 2>/dev/null && echo yes)" yes
t "workflow signs in the jobs the guide names" "$(grep -c 'cosign sign --yes' .github/workflows/release.yml)" 2

if [ "$F" = 0 ]; then echo "verify-release tests passed"; else echo "verify-release tests FAILED"; exit 1; fi
