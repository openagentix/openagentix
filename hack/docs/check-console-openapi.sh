#!/usr/bin/env bash
# Drift check: the paths and methods of docs/diary/reference/console-openapi.yaml must equal the routes the console registers
# in services/console/internal/server/server.go (the s.handle("METHOD /path", ...) calls). Offline: bash, sed, sort, diff, yq.
# The catch-all "/" (the web app) has no method and is not part of the API file.
# OPENAPI_FILE overrides the file to check (used to prove that the check fails).
set -euo pipefail
cd "$(dirname "$0")/../.."
GO=services/console/internal/server/server.go
YAML=${OPENAPI_FILE:-docs/diary/reference/console-openapi.yaml}
[ -f "$GO" ] && [ -f "$YAML" ] || { echo "FAIL: $GO or $YAML is missing" >&2; exit 2; }
command -v yq >/dev/null || { echo "FAIL: yq is required" >&2; exit 2; }

code=$(sed -n 's/^[[:space:]]*s\.handle("\([A-Z][A-Z]*\) \(\/[^"]*\)".*/\1 \2/p' "$GO" | sort)
spec=$(yq -r '.paths | to_entries[] | .key as $p | .value | keys[] | select(test("^(get|put|post|delete|head|patch|options|trace)$")) | (ascii_upcase + " " + $p)' "$YAML" | sort)

[ -n "$code" ] || { echo "FAIL: found no s.handle(\"METHOD /path\") call in $GO" >&2; exit 2; }
[ -n "$spec" ] || { echo "FAIL: found no paths in $YAML" >&2; exit 2; }

if diff_out=$(diff <(printf '%s\n' "$code") <(printf '%s\n' "$spec")); then
  echo "ok: $(printf '%s\n' "$code" | wc -l | tr -d ' ') routes in $GO match $YAML"
else
  echo "FAIL: the routes in $GO and the paths in $YAML differ."
  echo "      '<' only in the Go code (add it to the OpenAPI file), '>' only in the OpenAPI file (remove it or add the route):"
  printf '%s\n' "$diff_out"
  exit 1
fi
