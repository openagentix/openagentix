#!/usr/bin/env bash
# Tests for hack/kind-image-digest.sh with a fake `docker` (no cluster). A kind node that was loaded with `kind load docker-image`
# lists the image under its TAG only (no name@digest), so the script must add the digest name itself and print it.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
H1=$(printf '1%.0s' $(seq 1 64)); H2=$(printf '2%.0s' $(seq 1 64))
mkdir -p "$D/bin"
cat > "$D/bin/docker" <<EOF
#!/usr/bin/env bash
# fake: docker exec <node> ctr --namespace=k8s.io images ls | images tag <src> <dst>
[ "\$1" = exec ] || exit 9
shift 2
[ -n "\${FAKE_FAIL:-}" ] && exit 1
if [ "\$4" = ls ]; then cat "$D/ls"; elif [ "\$4" = tag ]; then echo "\$5 \$6" >> "$D/tags"; else exit 9; fi
EOF
chmod +x "$D/bin/docker"
export PATH="$D/bin:$PATH"
HDR="REF TYPE DIGEST SIZE PLATFORMS LABELS"
# 1. tag only: the digest name is created from the DIGEST column and printed
printf '%s\n' "$HDR" "registry.local/oa/echo-a2a:dev-abc application/vnd.oci.image.index.v1+json sha256:$H1 1.8KiB linux/amd64 io.cri-containerd.image=managed" "docker.io/other/echo-a2a:x application/x sha256:$H2 1KiB linux/amd64 -" > "$D/ls"; : > "$D/tags"
t "tag only: prints name@digest" "$(hack/kind-image-digest.sh c registry.local/oa/echo-a2a 2>/dev/null)" "registry.local/oa/echo-a2a@sha256:$H1"
t "tag only: tags the digest name on the node" "$(cat "$D/tags")" "registry.local/oa/echo-a2a:dev-abc registry.local/oa/echo-a2a@sha256:$H1"
# 2. a digest name already there: printed, nothing tagged
printf '%s\n' "$HDR" "registry.local/oa/echo-a2a@sha256:$H2 application/x sha256:$H2 1KiB linux/amd64 -" > "$D/ls"; : > "$D/tags"
t "digest name present: printed as is" "$(hack/kind-image-digest.sh c registry.local/oa/echo-a2a 2>/dev/null)" "registry.local/oa/echo-a2a@sha256:$H2"
t "digest name present: nothing tagged" "$(wc -c < "$D/tags" | tr -d ' ')" 0
# 3. the repository is not on the node
printf '%s\n' "$HDR" "docker.io/other/x:1 application/x sha256:$H2 1KiB linux/amd64 -" > "$D/ls"
hack/kind-image-digest.sh c registry.local/oa/echo-a2a >/dev/null 2>&1; t "image absent: fails" "$?" 1
# 4. a repository that only shares a prefix is not matched
printf '%s\n' "$HDR" "registry.local/oa/echo-a2a-other:dev-x application/x sha256:$H2 1KiB linux/amd64 -" > "$D/ls"
hack/kind-image-digest.sh c registry.local/oa/echo-a2a >/dev/null 2>&1; t "prefix-only repository: fails" "$?" 1
# 5. the node cannot be listed
FAKE_FAIL=1 hack/kind-image-digest.sh c registry.local/oa/echo-a2a >/dev/null 2>&1; t "cannot list the node: fails" "$?" 1
# 6. a reused cluster: an older tag and its digest name are still on the node; the tag just loaded decides
H3=$(printf '3%.0s' $(seq 1 64))
printf '%s\n' "$HDR" "registry.local/oa/echo-a2a:dev-old application/x sha256:$H2 1KiB linux/amd64 -" "registry.local/oa/echo-a2a@sha256:$H2 application/x sha256:$H2 1KiB linux/amd64 -" "registry.local/oa/echo-a2a:dev-new application/x sha256:$H3 1KiB linux/amd64 -" > "$D/ls"; : > "$D/tags"
t "stale digest name on the node: the loaded tag wins" "$(hack/kind-image-digest.sh c registry.local/oa/echo-a2a dev-new 2>/dev/null)" "registry.local/oa/echo-a2a@sha256:$H3"
t "stale digest name on the node: new name tagged from the loaded tag" "$(cat "$D/tags")" "registry.local/oa/echo-a2a:dev-new registry.local/oa/echo-a2a@sha256:$H3"
# 7. several images and no tag named: ambiguous, so it fails instead of guessing
hack/kind-image-digest.sh c registry.local/oa/echo-a2a >/dev/null 2>&1; t "several digests, no tag: fails" "$?" 1
# 8. the tag is not on the node
hack/kind-image-digest.sh c registry.local/oa/echo-a2a dev-missing >/dev/null 2>&1; t "tag absent: fails" "$?" 1
# 9. the name for the loaded tag is already there: printed, nothing tagged
printf '%s\n' "$HDR" "registry.local/oa/echo-a2a:dev-new application/x sha256:$H3 1KiB linux/amd64 -" "registry.local/oa/echo-a2a@sha256:$H3 application/x sha256:$H3 1KiB linux/amd64 -" > "$D/ls"; : > "$D/tags"
t "tag with its name present: printed" "$(hack/kind-image-digest.sh c registry.local/oa/echo-a2a dev-new 2>/dev/null)" "registry.local/oa/echo-a2a@sha256:$H3"
t "tag with its name present: nothing tagged" "$(wc -c < "$D/tags" | tr -d ' ')" 0
exit $F
