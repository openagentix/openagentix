#!/usr/bin/env bash
# The planted values of the pod root-cause use case, as search patterns (sourced by hack/ci/rca-live.sh and hack/ci/rca-upload-scan.sh).
#   . hack/ci/rca-canaries.sh; rca_canary_patterns <manifest> <output dir>
# writes two files of fixed strings, one per line, never an empty line (an empty line in a pattern file matches every line):
#   canary.removed  the values the server removes (env, log, probe, arg): plain, base64, hex, and the random part. They must be in NO log of the platform.
#   canary.all      those, and the two that reach the model (the exec probe output; the base64 value of a log line) and the common prefix in its encodings:
#                   they must be in no answer, no audit file and no log of the servers and the gate.
# The values are read from the manifest, so a new one is covered by editing the manifest only. The base64 value is read as it stands in the manifest.
rca_canary_patterns() {
  local manifest=$1 out=$2 c
  mkdir -p "$out"
  local plain; plain=$(grep -ohE 'rcacanary-(env|log|probe|arg|exec)-[0-9a-f]{8}' "$manifest" | sort -u)
  local blobs; blobs=$(grep -ohE 'blob=[A-Za-z0-9+/]+={0,2}' "$manifest" | sed 's/^blob=//' | sort -u)
  {
    for c in $(printf '%s\n' "$plain" | grep -E 'rcacanary-(env|log|probe|arg)-'); do
      printf '%s\n' "$c"
      printf '%s' "$c" | base64 | tr -d '\n='; echo
      printf '%s' "$c" | od -An -tx1 | tr -d ' \n'; echo
      printf '%s\n' "${c##*-}"
    done
  } | grep -v '^$' > "$out/canary.removed"
  {
    cat "$out/canary.removed"
    for c in $(printf '%s\n' "$plain" | grep -E 'rcacanary-exec-'); do printf '%s\n' "$c"; printf '%s\n' "${c##*-}"; done
    for c in $blobs; do printf '%s\n' "${c%%=*}"; printf '%s' "$c" | base64 -d 2>/dev/null; echo; done
    printf '%s\n' rcacanary cmNhY2FuYXJ5 YWNhbmFy Y2FjYW5h 7263616361
  } | grep -v '^$' > "$out/canary.all"
  printf '%s\n' "$plain"
}
