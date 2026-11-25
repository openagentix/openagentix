#!/usr/bin/env bash
# Release notes from CHANGELOG.md, and the tag check the release workflow runs first.
#
#   hack/release-notes.sh <tag|version> [CHANGELOG.md] [--digests FILE --registry PREFIX --chart OCI_REF]
#
# Prints the body of the "## [X.Y.Z]" section (without its heading). Exit 1 with a message on stderr when the tag is
# not a semantic version (vX.Y.Z or vX.Y.Z-prerelease; no build metadata), the changelog is missing, the section
# is missing or the section is empty. "Unreleased" is never a release.
# With --digests FILE (lines "<image name> sha256:<64 hex>") the body ends with a table of image references by digest;
# --registry gives the prefix (default ghcr.io/openagentix) and --chart the chart reference to list.
set -euo pipefail

die() { echo "release-notes: $*" >&2; exit 1; }

tag=${1:-}; [ $# -gt 0 ] && shift
changelog=CHANGELOG.md
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then changelog=$1; shift; fi
digests=''; registry=ghcr.io/openagentix; chart=''
while [ $# -gt 0 ]; do
  case $1 in
    --digests)  digests=${2:-}; shift 2 ;;
    --registry) registry=${2:-}; shift 2 ;;
    --chart)    chart=${2:-}; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

ver=${tag#v}
num='(0|[1-9][0-9]*)'
pre='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
re="^$num\\.$num\\.$num(-$pre(\\.$pre)*)?$"
[[ $ver =~ $re ]] || die "'$tag' is not a semantic version tag (want vX.Y.Z, for example v0.3.0)"

[ -f "$changelog" ] || die "$changelog not found"

# awk, not sed: take the lines after the exact heading until the next "## " heading or a link reference line.
body=$(awk -v h="## [$ver]" '
  index($0, h) == 1 && (length($0) == length(h) || substr($0, length(h) + 1, 1) == " ") { on = 1; next }
  on && /^## / { exit }
  on && /^\[[^]]+\]: / { exit }
  on { print }
' "$changelog")
# trim leading and trailing blank lines
body=$(printf '%s\n' "$body" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')
[ -n "$(printf '%s' "$body" | tr -d '[:space:]')" ] || die "$changelog has no non-empty '## [$ver]' section: write it before the tag"

printf '%s\n' "$body"

if [ -n "$digests" ]; then
  [ -f "$digests" ] || die "digest file $digests not found"
  echo
  echo "### Images"
  echo
  echo "Pull by digest. The tag \`$ver\` points at the same image."
  echo
  echo '```'
  while read -r name dg extra; do
    [ -n "${name:-}" ] || continue
    [ -z "${extra:-}" ] || die "bad line in $digests: '$name $dg $extra'"
    [[ $dg =~ ^sha256:[0-9a-f]{64}$ ]] || die "bad digest for '$name' in $digests"
    echo "$registry/$name@$dg"
  done < "$digests"
  echo '```'
  if [ -n "$chart" ]; then
    echo
    echo "### Chart"
    echo
    echo '```'
    echo "helm install openagentix $chart --version $ver"
    echo '```'
  fi
fi
