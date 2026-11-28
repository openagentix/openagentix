#!/usr/bin/env bash
# Which values does the Helm release hold that this run would drop? (issue #212)
#
# Helm replaces the user-supplied values of a release on every `helm upgrade`. A re-run with a shorter VALUES_FILE list therefore removes whole features and
# agents without a word. This script compares, as an ALLOWLIST, the key paths and the named list entries of the existing release with the values that are
# about to be applied, and prints every path the release has and the new values lack. It compares paths and entry names, not values. A list of plain
# values counts as one path; a list of objects that have a string `name` is compared entry by entry (".mcp.endpoints[records].url").
#
# Keys the installer sets itself (image tag, digest and repository, source hashes, the API server addresses, ...) are not compared. They are listed, one
# exact key per line, in hack/release-values-ignore.txt next to this script. A test (hack/ci/release-values-diff-test.sh) fails when install.sh gains a
# `--set` key that is not in that list.
#
# Usage: hack/release-values-diff.sh [--enforce] [--release NAME] [--namespace NS] [--kube-context CTX] [--ignore-file FILE] [-f FILE]... [--set-file KEY=PATH]...
#   -f FILE            a values file the run will pass (YAML or JSON); merged in order the way Helm does it (maps deep, a later file wins, a list is replaced)
#   --set-file KEY=PATH  a value the run passes with --set-file (only the key counts; dots in a name are escaped as \. like Helm)
#   --enforce          the installer's policy (install.sh): print the list on stderr and stop (exit 1) unless ALLOW_VALUE_REMOVAL=1, then print it and go on
# Environment: HELM (default helm), ALLOW_VALUE_REMOVAL (only the value 1 counts).
# Exit codes: 0 nothing would be lost, or there is no release (first install): nothing is printed. With --enforce also: the loss is allowed.
#             1 the release holds paths the new values lack. Without --enforce they are printed one per line on stdout.
#             2 the release could not be read, or an argument or file is wrong: the reason is on stderr. The caller must stop (fail closed, also with
#               ALLOW_VALUE_REMOVAL=1: a release that cannot be read cannot be compared).
set -uo pipefail
HELM=${HELM:-helm}
HERE=$(cd "$(dirname "$0")" && pwd)
REL=openagentix; NS=openagentix-system; CTXARG=(); IGNORE="$HERE/release-values-ignore.txt"
FILES=(); SETFILES=(); ENFORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --enforce) ENFORCE=1; shift;;
    --release) REL=${2:?}; shift 2;;
    --namespace) NS=${2:?}; shift 2;;
    --kube-context) CTXARG=(--kube-context "${2:?}"); shift 2;;
    --ignore-file) IGNORE=${2:?}; shift 2;;
    -f) FILES+=("${2:?}"); shift 2;;
    --set-file) SETFILES+=("${2:?}"); shift 2;;
    *) echo "release-values-diff: unknown argument: $1" >&2; exit 2;;
  esac
done
command -v jq >/dev/null || { echo "release-values-diff: jq is required" >&2; exit 2; }
command -v yq >/dev/null || { echo "release-values-diff: yq is required" >&2; exit 2; }
[ -r "$IGNORE" ] || { echo "release-values-diff: cannot read the ignore list $IGNORE" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1. the release (read only). Only helm's own, exact line means "no such release"; any other failure (a missing command, an unreachable cluster) is exit 2.
if ! "$HELM" get values "$REL" -n "$NS" ${CTXARG[@]+"${CTXARG[@]}"} -o json >"$T/release.json" 2>"$T/helm.err"; then
  if grep -qxF "Error: release: not found" "$T/helm.err" 2>/dev/null; then exit 0; fi
  echo "cannot read the values of the release $REL in namespace $NS: $(head -n 1 "$T/helm.err" 2>/dev/null | cut -c1-300)" >&2
  [ "$ENFORCE" = 0 ] || echo "ERROR: refusing to run on a release I cannot read, so that nothing is dropped without a word. Nothing was changed." >&2
  exit 2
fi
if ! jq empty "$T/release.json" >/dev/null 2>&1; then
  echo "cannot read the values of the release $REL in namespace $NS: helm did not print JSON" >&2
  [ "$ENFORCE" = 0 ] || echo "ERROR: refusing to run on a release I cannot read, so that nothing is dropped without a word. Nothing was changed." >&2
  exit 2
fi

# 2. the values this run will apply, merged the way Helm merges them
: > "$T/exp.jsonl"
for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -r "$f" ] || { echo "release-values-diff: cannot read $f" >&2; exit 2; }
  yq . "$f" >> "$T/exp.jsonl" 2>"$T/yq.err" || { echo "release-values-diff: cannot read $f as YAML: $(head -n 1 "$T/yq.err")" >&2; exit 2; }
done
for s in ${SETFILES[@]+"${SETFILES[@]}"}; do
  case "$s" in *=*) ;; *) echo "release-values-diff: --set-file wants KEY=PATH, got $s" >&2; exit 2;; esac
  jq -n --arg k "${s%%=*}" '[$k | scan("(?:\\\\\\.|[^.])+") | gsub("\\\\\\.";".")] as $p | {} | setpath($p; "x")' >> "$T/exp.jsonl" || { echo "release-values-diff: bad --set-file key ${s%%=*}" >&2; exit 2; }
done
jq -s 'reduce .[] as $x ({}; if ($x | type) == "object" then . * $x else . end)' "$T/exp.jsonl" > "$T/exp.json" || { echo "release-values-diff: the values did not merge" >&2; exit 2; }

# 3. the allowlist comparison
grep -vE '^[[:space:]]*(#|$)' "$IGNORE" | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//' | jq -R . | jq -s . > "$T/ignore.json"
jq -r --slurpfile exp "$T/exp.json" --slurpfile ign "$T/ignore.json" '
  def flat($pre):
    if type == "object" then (if length == 0 then $pre + "{}" else (to_entries[] | .key as $k | .value | flat($pre + "." + $k)) end)
    elif type == "array" then (if length == 0 then $pre + "[]" else (.[] | (if type == "object" and ((.name | type) == "string") then flat($pre + "[" + .name + "]") else flat($pre + "[]") end)) end)
    else $pre end;
  def key: ltrimstr(".") | sub("(\\[\\])+$"; "");
  [(if . == null or . == {} then empty else flat("") end) | select(. != "")] | unique as $have
  | ([$exp[0] | flat("") | select(. != "")] | unique) as $want
  | ($have - $want) | map(select((key as $k | $ign[0] | index($k)) == null)) | .[]' "$T/release.json" > "$T/lost.txt" || { echo "release-values-diff: the comparison failed" >&2; exit 2; }
[ -s "$T/lost.txt" ] || exit 0
if [ "$ENFORCE" = 0 ]; then cat "$T/lost.txt"; exit 1; fi

# 4. the installer's policy
N=$(wc -l < "$T/lost.txt" | tr -d ' ')
{
  if [ "${ALLOW_VALUE_REMOVAL:-}" = 1 ]; then
    echo "WARNING: ALLOW_VALUE_REMOVAL=1 is set. The release $REL in namespace $NS has $N value(s) that this run does not have, so Helm removes them:"
  else
    echo "ERROR: the release $REL in namespace $NS has $N value(s) that this run does not have:"
  fi
  head -n 30 "$T/lost.txt" | sed 's/^/  /'
  [ "$N" -le 30 ] || echo "  ... and $((N-30)) more"
  if [ "${ALLOW_VALUE_REMOVAL:-}" != 1 ]; then
    echo "Helm replaces the values of a release on every run, so this run would remove them (features, agents, settings) without any other message."
    echo "Pass the same VALUES_FILE list as before (and the same STUB_SCENARIOS). To remove them on purpose, run again with ALLOW_VALUE_REMOVAL=1. Nothing was changed."
  fi
} >&2
[ "${ALLOW_VALUE_REMOVAL:-}" = 1 ] && exit 0
exit 1
