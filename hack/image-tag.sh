# Sourced by install.sh. Content-derived image tags.
#
# kind load does not replace an image whose tag already exists on the node (containerd keeps the old one), and the
# pods use imagePullPolicy IfNotPresent. So an image built from changed source under a fixed tag such as "dev" never
# reaches the cluster. Every image the installer builds is therefore tagged dev-<hash of its source>: changed source
# means a new image reference, which the node does not have, which kind load imports and the Deployment rolls to.
#
# src_hash <dir>...  16 hex chars over the content of every source file under the directories (paths relative to each
#                    directory, so the hash does not depend on where the checkout lives). Build outputs, dependency
#                    trees, docs and test binaries are left out: they do not change what the Dockerfile builds.
# src_tag <dir>...   dev-<src_hash>
src_hash() {
  local d
  for d in "$@"; do
    (cd "$d" && find . -type f ! -path './bin/*' ! -path './node_modules/*' ! -path './build/*' ! -path './.svelte-kit/*' \
        ! -path './web/dist/*' ! -path './test-results/*' ! -path './playwright-report/*' ! -path './.vite/*' \
        ! -name '*.md' ! -name '*.test' ! -name 'coverage*' -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
  done | shasum -a 256 | cut -c1-16
}
src_tag() { printf 'dev-%s\n' "$(src_hash "$@")"; }
