#!/usr/bin/env bash
# Discover the Dockerfiles CI builds to prove they build. Only self-contained ones: a Dockerfile with a Go build stage
# (`FROM golang... AS build`) or one with the comment line `# ci-build: <why>` (the Python sample). Its build context is its own directory unless the Dockerfile says otherwise with a comment line
# `# build-context: <path relative to the repository root>` (the console image copies console/ and services/console/, so it
# builds from the root `.`). Images that COPY a prebuilt binary or a local content directory (bridges/ax-adapter,
# components/tools/skills) are left out.
#   hack/ci/dockerfiles.sh           one Dockerfile directory per line
#   hack/ci/dockerfiles.sh --json    {"include":[{"dir","name","context","file"}]} for a matrix
set -euo pipefail
cd "$(dirname "$0")/../.."
rows=$(find . -name Dockerfile -not -path '*/node_modules/*' -not -path './spikes/*' -not -path './.git/*' | sort \
  | while read -r f; do
      grep -Eiq '^FROM[[:space:]]+golang[^[:space:]]*[[:space:]]+AS[[:space:]]+build|^# ci-build:' "$f" || continue
      d=$(dirname "$f"); d=${d#./}
      ctx=$(sed -n 's/^# build-context:[[:space:]]*//p' "$f" | head -1 | tr -d '[:space:]')
      printf '%s\t%s\t%s\n' "$d" "${ctx:-$d}" "${f#./}"
    done)
if [ "${1:-}" = "--json" ]; then
  printf '%s\n' "$rows" | jq -R -s -c 'split("\n") | map(select(length>0) | split("\t") | {dir: .[0], name: (.[0]|split("/")|last), context: .[1], file: .[2]}) | {include: .}'
else
  printf '%s\n' "$rows" | cut -f1
fi
