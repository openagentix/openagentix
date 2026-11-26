#!/usr/bin/env bash
# Decide whether a change needs the heavy jobs. Writes `heavy=true|false` to $GITHUB_OUTPUT (or stdout when unset).
#   hack/ci/changes.sh <base-sha> <head-sha>
# Docs-only changes (docs/, website/, *.md, LICENSE, the docs workflow) skip the heavy jobs. An empty or all-zero base, or a
# base that is not in the clone, means "run everything".
set -euo pipefail
base=${1:-}; head=${2:-HEAD}
out=${GITHUB_OUTPUT:-/dev/stdout}
if [ -z "$base" ] || [ "${base//0/}" = "" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  echo "no usable base: running everything" >&2; echo "heavy=true" >>"$out"; echo "docs=true" >>"$out"; exit 0
fi
files=$(git diff --name-only "$base" "$head")
echo "changed files:" >&2; printf '%s\n' "$files" | sed 's/^/  /' >&2
if printf '%s\n' "$files" | grep -Evq '^(docs/|website/|.*\.md$|LICENSE$|\.github/workflows/docs\.yml$)'; then
  echo "heavy=true" >>"$out"
else
  echo "docs-only change: heavy jobs skipped" >&2; echo "heavy=false" >>"$out"
fi
# The docs site build runs when the site, its sources, the changelog or the workflows that build it changed.
if printf '%s\n' "$files" | grep -Eq '^(docs/|website/|CHANGELOG\.md$|\.github/workflows/(ci|docs)\.yml$)'; then
  echo "docs=true" >>"$out"
else
  echo "docs=false" >>"$out"
fi
