#!/usr/bin/env bash
# Generates the parts of the reference pages that must follow the code (docs/diary/reference/*.md).
#
#   hack/docs/gen-reference.sh            rewrite every generated block in place
#   hack/docs/gen-reference.sh --check    change nothing; exit 1 and show a diff when a page differs from the generator
#   hack/docs/gen-reference.sh block NAME print one block (for debugging)
#
# A generated block in a page looks like this, and nothing between the two lines is edited by hand:
#   <!-- generated:begin NAME -->
#   ...
#   <!-- generated:end NAME -->
# Sources: services/control-plane/crd/agentdefinition.yaml (fields, limits, printer columns), services/control-plane/internal/api/reasons.go
# (reasons), services/control-plane/internal/policy/policy.go (violation sentences), charts/openagentix/values.yaml (policy defaults).
# Needs: jq, yq (the Python wrapper, 3.x), perl, awk.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRD="$ROOT/services/control-plane/crd/agentdefinition.yaml"
REASONS="$ROOT/services/control-plane/internal/api/reasons.go"
POLICY_GO="$ROOT/services/control-plane/internal/policy/policy.go"
VALUES="$ROOT/charts/openagentix/values.yaml"
PAGES="$ROOT/docs/diary/reference"

crd_json() { yq '.' "$CRD"; }

# One table of fields from an OpenAPI schema node. $1 = jq path of the node, $2 = prefix shown in the table.
fields_table() {
  local node="$1" prefix="$2"
  echo "| Path | Type | Required | Limits and checks | Meaning |"
  echo "|---|---|---|---|---|"
  crd_json | jq -r --arg prefix "$prefix" "include \"fields\"; $node | rows(\$prefix; (.required // []))" -L "$ROOT/hack/docs"
}

block_ad_spec_fields() {
  fields_table '.spec.versions[0].schema.openAPIV3Schema.properties.spec' spec
}
block_ad_status_fields() {
  fields_table '.spec.versions[0].schema.openAPIV3Schema.properties.status | .properties |= del(.controller)' status
}
block_ad_status_controller() {
  fields_table '.spec.versions[0].schema.openAPIV3Schema.properties.status.properties.controller' status.controller
}
block_ad_object_rules() {
  echo "| Rule (CEL) | Applies to | Refusal sentence |"
  echo "|---|---|---|"
  crd_json | jq -r '
    .spec.versions[0].schema.openAPIV3Schema as $s
    | (($s["x-kubernetes-validations"] // [])[] | "| `\(.rule)` | the object | \(.message) |"),
      (($s.properties.spec["x-kubernetes-validations"] // [])[] | "| `\(.rule)` | `spec` | \(.message) |")'
}
block_ad_printer_columns() {
  echo "| Column | Type | Source |"
  echo "|---|---|---|"
  crd_json | jq -r '.spec.versions[0].additionalPrinterColumns[] | "| \(.name) | \(.type) | `\(.jsonPath)` |"'
}
block_ad_names() {
  echo "| Item | Value |"
  echo "|---|---|"
  crd_json | jq -r '.spec as $s
    | "| group | `\($s.group)` |",
      "| version | `\($s.versions[0].name)` (served: \($s.versions[0].served), storage: \($s.versions[0].storage)) |",
      "| kind | `\($s.names.kind)` |",
      "| plural | `\($s.names.plural)` |",
      "| short names | \($s.names.shortNames | map("`\(.)`") | join(", ")) |",
      "| scope | \($s.scope) |",
      "| subresources | \($s.versions[0].subresources | keys | map("`\(.)`") | join(", ")) |"'
}
block_ad_reasons() {
  echo "| Condition | Reason | Status | Meaning |"
  echo "|---|---|---|---|"
  perl -ne '
    if (/^\s*Cond(\w+):\s*\{\s*$/) { $c = $1; next }
    if ($c && /^\s*\{"([^"]+)",\s*"([^"]+)",\s*"((?:[^"\\]|\\.)*)"\},?\s*$/) { my ($re,$s,$m)=($1,$2,$3); $m =~ s/\|/\\|/g; print "| `$c` | `$re` | $s | $m |\n"; }' "$REASONS"
}
block_ad_violations() {
  echo "| No. | Sentence (a verb such as %q or %d is filled in with the real value) |"
  echo "|---|---|"
  perl -ne '
    while (/\badd\("((?:[^"\\]|\\.)*)"/g) { my $s = $1; $s =~ s/\\"/"/g; $s =~ s/\|/\\|/g; $s =~ s{(https?://[^ ,)]+)}{`$1`}g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $n++; print "| $n | $s |\n"; }' "$POLICY_GO"
}
block_policy_defaults() {
  echo "| Key | Default |"
  echo "|---|---|"
  yq '.controlPlane.policy' "$VALUES" | jq -r '
    def flat($p): to_entries[] | .key as $k | .value as $v
      | if ($v | type) == "object" then ($v | flat($p + $k + ".")) else "| `controlPlane.policy.\($p + $k)` | `\($v | tojson)` |" end;
    flat("")'
}
block_cp_defaults() {
  echo "| Key | Default |"
  echo "|---|---|"
  yq '.controlPlane | del(.policy) | del(.resources) | del(.image)' "$VALUES" | jq -r 'to_entries[] | "| `controlPlane.\(.key)` | `\(.value | tojson)` |"'
}

emit_block() {
  local fn="block_${1//-/_}"
  if ! declare -F "$fn" >/dev/null; then echo "gen-reference: unknown block $1" >&2; return 2; fi
  "$fn"
}

rewrite_page() { # $1 page; writes the new text to stdout
  local page="$1" name tmp
  tmp="$(mktemp -d)"
  while IFS= read -r name; do
    emit_block "$name" > "$tmp/$name.txt"
  done < <(sed -n 's/^<!-- generated:begin \([a-z0-9-]*\) -->$/\1/p' "$page")
  awk -v dir="$tmp" '
    /^<!-- generated:begin [a-z0-9-]+ -->$/ { print; name=$3; f=dir "/" name ".txt"; while ((getline line < f) > 0) print line; close(f); skip=1; next }
    /^<!-- generated:end [a-z0-9-]+ -->$/ { skip=0 }
    !skip { print }' "$page"
  rm -rf "$tmp"
}

case "${1:-}" in
  block) emit_block "${2:?block name}" ;;
  --check)
    status=0
    tmpdiff="$(mktemp)"
    for page in "$PAGES"/*.md; do
      grep -q '^<!-- generated:begin ' "$page" || continue
      if ! diff -u "$page" <(rewrite_page "$page") >"$tmpdiff"; then
        echo "DRIFT: ${page#"$ROOT"/} differs from the generator. Run hack/docs/gen-reference.sh and commit the result." >&2
        head -60 "$tmpdiff" >&2
        status=1
      fi
    done
    rm -f "$tmpdiff"
    [ "$status" = 0 ] && echo "reference pages match the generator"
    exit "$status" ;;
  "")
    for page in "$PAGES"/*.md; do
      grep -q '^<!-- generated:begin ' "$page" || continue
      rewrite_page "$page" > "$page.new" && mv "$page.new" "$page"
    done ;;
  *) echo "usage: $0 [--check | block NAME]" >&2; exit 2 ;;
esac
