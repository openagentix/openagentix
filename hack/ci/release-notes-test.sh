#!/usr/bin/env bash
# Tests for hack/release-notes.sh: the tag check, the changelog section lookup and the release body.
set -u
cd "$(dirname "$0")/../.." || exit 1
S=hack/release-notes.sh
[ -x "$S" ] || { echo "FAIL $S missing or not executable"; exit 1; }
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/CHANGELOG.md" <<'EOT'
# Changelog

## [Unreleased]

### Added
- Not released yet.

## [1.2.3] - 2026-12-01

Intro line.

### Added
- Thing A.

### Fixed
- Thing B.

## [1.2.4-rc.1] - 2026-12-02

### Added
- Candidate.

## [1.2.5] - 2026-12-03

## [0.9.0] - 2026-01-01

### Added
- Old.

[Unreleased]: https://example.invalid/compare
EOT
out=$("$S" v1.2.3 "$D/CHANGELOG.md" 2>&1); rc=$?
t "section of 1.2.3 starts with its intro" "$(printf '%s\n' "$out" | sed -n 1p)" "Intro line."
t "section of 1.2.3 holds Thing B" "$(printf '%s\n' "$out" | grep -c 'Thing B')" 1
t "section of 1.2.3 stops at the next heading" "$(printf '%s\n' "$out" | grep -c 'Candidate')" 0
t "section of 1.2.3 does not include Unreleased" "$(printf '%s\n' "$out" | grep -c 'Not released yet')" 0
t "exit 0 for a good tag" "$rc" 0
t "version without v is accepted" "$("$S" 1.2.3 "$D/CHANGELOG.md" | sed -n 1p)" "Intro line."
t "prerelease section found" "$("$S" v1.2.4-rc.1 "$D/CHANGELOG.md" | grep -c Candidate)" 1
t "last section stops before link references" "$("$S" v0.9.0 "$D/CHANGELOG.md" | grep -c 'example.invalid')" 0
for bad in v1.2 1.2.3.4 v01.2.3 vX.Y.Z v1.2.3+meta main ""; do
  "$S" "$bad" "$D/CHANGELOG.md" >/dev/null 2>&1; t "refuses tag '$bad'" "$?" 1
done
"$S" v9.9.9 "$D/CHANGELOG.md" >/dev/null 2>&1; t "refuses a version with no section" "$?" 1
"$S" v1.2.5 "$D/CHANGELOG.md" >/dev/null 2>&1; t "refuses an empty section" "$?" 1
"$S" v1.2.3 "$D/nope.md" >/dev/null 2>&1; t "refuses a missing changelog file" "$?" 1
t "message names the missing section" "$("$S" v9.9.9 "$D/CHANGELOG.md" 2>&1 | grep -c '## \[9.9.9\]')" 1
# digests table
printf 'a2a-gate sha256:%064d\nkb sha256:%064d\n' 1 2 > "$D/digests.txt"
body=$("$S" v1.2.3 "$D/CHANGELOG.md" --digests "$D/digests.txt" --registry ghcr.io/openagentix --chart oci://ghcr.io/openagentix/charts/openagentix)
t "body lists a digest line" "$(printf '%s\n' "$body" | grep -c "ghcr.io/openagentix/a2a-gate@sha256:0*1")" 1
t "body lists the second image" "$(printf '%s\n' "$body" | grep -c "ghcr.io/openagentix/kb@sha256:0*2")" 1
t "body names the chart" "$(printf '%s\n' "$body" | grep -c 'oci://ghcr.io/openagentix/charts/openagentix')" 1
t "body keeps the changelog text first" "$(printf '%s\n' "$body" | sed -n 1p)" "Intro line."
printf 'kb notadigest\n' > "$D/bad.txt"
"$S" v1.2.3 "$D/CHANGELOG.md" --digests "$D/bad.txt" >/dev/null 2>&1; t "refuses a malformed digest" "$?" 1
"$S" v1.2.3 "$D/CHANGELOG.md" --digests "$D/none.txt" >/dev/null 2>&1; t "refuses a missing digest file" "$?" 1
# the real changelog: Unreleased is never a release
"$S" vUnreleased CHANGELOG.md >/dev/null 2>&1; t "refuses Unreleased" "$?" 1
"$S" v0.2.0 CHANGELOG.md >/dev/null 2>&1; t "real changelog has a 0.2.0 section" "$?" 0
exit $F
