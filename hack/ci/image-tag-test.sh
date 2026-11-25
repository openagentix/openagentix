#!/usr/bin/env bash
# Tests for hack/image-tag.sh and for install.sh's use of it: every image the installer builds is tagged dev-<source hash>
# and that tag is handed to the chart, so a changed source is always a NEW image reference on the kind node.
set -u
cd "$(dirname "$0")/../.."
. hack/image-tag.sh 2>/dev/null || { echo "FAIL hack/image-tag.sh missing"; exit 1; }
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/a/bin" "$D/a/node_modules/x" "$D/b"
echo one > "$D/a/main.go"; echo b > "$D/b/f.txt"
H1=$(src_hash "$D/a" "$D/b")
t "tag has the dev- prefix and 16 hex chars" "$(src_tag "$D/a" "$D/b" | grep -cE '^dev-[0-9a-f]{16}$')" 1
t "same content, same hash" "$(src_hash "$D/a" "$D/b")" "$H1"
echo junk > "$D/a/bin/out"; echo junk > "$D/a/node_modules/x/y"; echo doc > "$D/a/README.md"
t "bin/, node_modules and *.md do not change the hash" "$(src_hash "$D/a" "$D/b")" "$H1"
echo two > "$D/a/main.go"
t "a source change changes the hash" "$([ "$(src_hash "$D/a" "$D/b")" != "$H1" ] && echo yes)" yes
H2=$(src_hash "$D/a" "$D/b"); echo c > "$D/b/new.txt"
t "a NEW file changes the hash" "$([ "$(src_hash "$D/a" "$D/b")" != "$H2" ] && echo yes)" yes
t "hash does not depend on the directory path" "$(cp -R "$D/b" "$D/b2"; src_hash "$D/b2")" "$(src_hash "$D/b")"
# install.sh wiring: each built image is retagged by tag_image, which passes <path>.image.tag to the chart
for k in bridge.image.tag scheduling.image.tag gateway.stubModel.image.tag knowledge.kb.image.tag notify.image.tag governance.a2a.image.tag controlPlane.image.tag console.image.tag; do
  t "install.sh tags the image of ${k%.image.tag}" "$(grep -cE "^  tag_image [A-Z0-9_]+ ${k%.image.tag} " install.sh)" 1
done
exit $F
