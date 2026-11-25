#!/usr/bin/env bash
# Verify OpenAgentix release artefacts: that each image and the chart was signed by the release workflow of this
# repository (keyless cosign, GitHub OIDC), that each image has its SPDX SBOM attestation, that each has a build
# provenance attestation (gh attestation verify), and that the release assets match the signed checksums file.
#
#   hack/verify-release.sh [--tag vX.Y.Z] [--repo owner/name] [--no-sbom] [--no-provenance] [--dry-run]
#                          [--checksums path/to/SHA256SUMS] [REF@sha256:<digest> ...]
#
#   REF            an image or OCI chart by digest, for example ghcr.io/openagentix/kb@sha256:<64 hex>. A tag such as
#                  :0.3.0 is refused: a tag can be moved, a digest cannot. The release notes list every digest.
#   --tag          accept only signatures made by the workflow run of this tag. Without it, a signature of the
#                  release workflow from any vX.Y.Z tag is accepted.
#   --repo         the repository that released it (default openagentix/openagentix).
#   --no-sbom      skip the SBOM attestation check (the chart has no SBOM).
#   --no-provenance skip `gh attestation verify` (it needs gh and a GitHub login).
#   --checksums    verify SHA256SUMS with the bundle next to it (SHA256SUMS.sigstore.json), then every file it lists,
#                  in the directory of SHA256SUMS. Download the assets first: gh release download vX.Y.Z
#   --dry-run      print the commands, run nothing.
#
# Needs cosign v3 (and gh for provenance). Exit 0: every check passed. 1: a check failed. 2: bad usage or a missing tool.
# Guide: docs/diary/guide/verify-release.md. Tests: hack/ci/verify-release-test.sh (fake cosign and gh).
set -uo pipefail

ISSUER=https://token.actions.githubusercontent.com
WORKFLOW=.github/workflows/release.yml
repo=openagentix/openagentix tag="" sbom=1 prov=1 dry=0 sums=""
refs=()

usage(){ sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; }
die(){ echo "verify-release: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --tag)           [ $# -ge 2 ] || die "--tag needs a value"; tag=$2; shift 2 ;;
    --repo)          [ $# -ge 2 ] || die "--repo needs a value"; repo=$2; shift 2 ;;
    --checksums)     [ $# -ge 2 ] || die "--checksums needs a file"; sums=$2; shift 2 ;;
    --no-sbom)       sbom=0; shift ;;
    --no-provenance) prov=0; shift ;;
    --dry-run)       dry=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              die "unknown option: $1 (see --help)" ;;
    *)               refs+=("$1"); shift ;;
  esac
done

num='(0|[1-9][0-9]*)'
[ -z "$tag" ] || [[ $tag =~ ^v$num\.$num\.$num(-[0-9A-Za-z.-]+)?$ ]] || die "'$tag' is not a release tag (want vX.Y.Z, for example v0.3.0)"
[[ $repo =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_.][A-Za-z0-9_.-]*$ ]] || die "'$repo' is not owner/name"
for r in "${refs[@]+"${refs[@]}"}"; do
  [[ $r =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+@sha256:[0-9a-f]{64}$ ]] \
    || die "'$r' is not a reference by digest (want registry/name@sha256:<64 hex>; a tag can be moved, a digest cannot)"
done
if [ -n "$sums" ]; then [ -f "$sums" ] || die "checksums file '$sums' not found"; fi
[ ${#refs[@]} -gt 0 ] || [ -n "$sums" ] || die "nothing to check: give a reference by digest or --checksums (see --help)"

# The signer: the release workflow of this repository, run for a tag. Same values as docs/diary/guide/verify-release.md.
if [ -n "$tag" ]; then
  identity=(--certificate-identity "https://github.com/$repo/$WORKFLOW@refs/tags/$tag")
else
  re_repo=$(printf '%s' "$repo" | sed 's/[.]/\\./g')
  identity=(--certificate-identity-regexp "^https://github\\.com/$re_repo/\\.github/workflows/release\\.yml@refs/tags/v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?\$")
fi
signer=("${identity[@]}" --certificate-oidc-issuer "$ISSUER")

if [ "$dry" = 0 ]; then
  command -v cosign >/dev/null 2>&1 || die "cosign is not installed (https://docs.sigstore.dev/cosign/system_config/installation/)"
  if [ "$prov" = 1 ] && [ ${#refs[@]} -gt 0 ]; then
    command -v gh >/dev/null 2>&1 || die "gh is not installed; install it or pass --no-provenance"
  fi
fi

passed=0 failed=0
check(){ # check <label> <command...>: run quietly, report one line
  local label=$1; shift
  if [ "$dry" = 1 ]; then echo "would run: $*"; return 0; fi
  local err; err=$(mktemp)
  if "$@" >/dev/null 2>"$err"; then
    echo "  ok   $label"; passed=$((passed + 1))
  else
    echo "  FAIL $label"; sed 's/^/       /' "$err" | tail -5; failed=$((failed + 1))
  fi
  rm -f "$err"
}

for r in "${refs[@]+"${refs[@]}"}"; do
  check "signature $r" cosign verify "${signer[@]}" --certificate-github-workflow-repository "$repo" "$r"
  [ "$sbom" = 0 ] || check "SBOM attestation (SPDX) $r" cosign verify-attestation --type spdxjson "${signer[@]}" --certificate-github-workflow-repository "$repo" "$r"
  if [ "$prov" = 1 ]; then
    gh_args=(attestation verify "oci://$r" --repo "$repo" --signer-workflow "$repo/$WORKFLOW")
    [ -z "$tag" ] || gh_args+=(--source-ref "refs/tags/$tag")
    check "build provenance $r" gh "${gh_args[@]}"
  fi
done

if [ -n "$sums" ]; then
  bundle="$sums.sigstore.json"
  if [ "$dry" = 1 ] || [ -f "$bundle" ]; then
    check "signature of $sums" cosign verify-blob --bundle "$bundle" "${signer[@]}" "$sums"
  else
    echo "  FAIL signature of $sums (no bundle $bundle; download it with the other assets)"; failed=$((failed + 1))
  fi
  if command -v sha256sum >/dev/null 2>&1; then shasum_cmd=(sha256sum -c); else shasum_cmd=(shasum -a 256 -c); fi
  dir=$(dirname "$sums") base=$(basename "$sums")
  if [ "$dry" = 1 ]; then echo "would run: (cd $dir && ${shasum_cmd[*]} $base)"
  elif (cd "$dir" && "${shasum_cmd[@]}" "$base") >/dev/null 2>&1; then
    echo "  ok   checksums of the files listed in $sums"; passed=$((passed + 1))
  else
    echo "  FAIL checksums of the files listed in $sums (a file is missing or changed)"; failed=$((failed + 1))
  fi
fi

[ "$dry" = 1 ] && { echo "dry run: nothing was verified"; exit 0; }
if [ "$failed" = 0 ]; then echo "all $passed checks passed"; exit 0; fi
echo "$failed of $((passed + failed)) checks failed"; exit 1
