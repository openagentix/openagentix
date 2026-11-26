#!/usr/bin/env bash
# Tests for hack/images.sh (ADR 0022) with a fake `docker` that records its arguments and writes a buildx metadata file. No Docker, no registry.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
DG=sha256:$(printf '%064d' 7)
cat > "$D/bin/docker" <<EOS
#!/usr/bin/env bash
echo "docker \$*" >> "$D/calls"
if [ "\$1 \$2" = "buildx build" ]; then
  m=""; while [ \$# -gt 0 ]; do [ "\$1" = --metadata-file ] && m=\$2; shift; done
  case "\${FAKE_META:-good}" in
    good) echo '{"containerimage.digest":"$DG","image.name":"x"}' > "\$m";;
    nodigest) echo '{"image.name":"x"}' > "\$m";;
    bad) echo '{"containerimage.digest":"sha256:abc"}' > "\$m";;
    none) ;;
  esac
fi
exit 0
EOS
chmod +x "$D/bin/docker"
export PATH="$D/bin:$PATH"
: > "$D/calls"
calls(){ tr '\n' ';' < "$D/calls"; : > "$D/calls"; }
# chk <env...>: images_check in a clean subshell; prints "ok <platform>" or the error line
chk(){ ( env -i PATH="$PATH" "$@" bash -c '. hack/images.sh; if images_check 2>"$0"; then echo "ok ${IMAGE_PLATFORM:-}"; else head -1 "$0"; fi' "$D/err" ); }

echo "# switches: kind and k3d"
t "kind, nothing set: ok, no platform" "$(chk CLUSTER_TYPE=kind)" "ok "
t "no CLUSTER_TYPE (kind): ok" "$(chk)" "ok "
t "kind + IMAGE_REGISTRY: refused" "$(chk CLUSTER_TYPE=kind IMAGE_REGISTRY=reg.example/p | grep -c 'IMAGE_REGISTRY is only for CLUSTER_TYPE=remote')" 1
t "k3d + IMAGE_REGISTRY: refused" "$(chk CLUSTER_TYPE=k3d IMAGE_REGISTRY=reg.example/p | grep -c 'IMAGE_REGISTRY is only for CLUSTER_TYPE=remote')" 1
t "kind + IMAGE_PLATFORM: refused" "$(chk CLUSTER_TYPE=kind IMAGE_PLATFORM=linux/amd64 | grep -c 'IMAGE_PLATFORM is only for CLUSTER_TYPE=remote')" 1
t "k3d + IMAGE_PLATFORM: refused" "$(chk CLUSTER_TYPE=k3d IMAGE_PLATFORM=linux/arm64 | grep -c 'IMAGE_PLATFORM is only for CLUSTER_TYPE=remote')" 1

echo "# switches: remote"
t "remote without IMAGE_REGISTRY: ok here (the installer refuses it when it has images to build)" "$(chk CLUSTER_TYPE=remote)" "ok linux/amd64"
t "remote: IMAGE_PLATFORM defaults to linux/amd64" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=europe-west4-docker.pkg.dev/proj/oa)" "ok linux/amd64"
t "remote: linux/arm64 accepted" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=reg.example/p IMAGE_PLATFORM=linux/arm64)" "ok linux/arm64"
t "remote: both platforms accepted" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=reg.example/p IMAGE_PLATFORM=linux/amd64,linux/arm64)" "ok linux/amd64,linux/arm64"
t "remote: a host with a port accepted" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=localhost:5000/oa)" "ok linux/amd64"
t "remote: ghcr.io/acme accepted" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=ghcr.io/acme)" "ok linux/amd64"
for bad in linux/386 amd64 "linux/amd64," "linux/amd64 linux/arm64" linux/amd64,linux/amd64x; do
  t "remote: IMAGE_PLATFORM='$bad' refused" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=reg.example/p IMAGE_PLATFORM="$bad" | grep -c 'IMAGE_PLATFORM')" 1
done
for bad in https://reg.example/p reg.example/p/ reg.example myname/repo Reg.example/p reg.example/p:tag reg.example/p@sha256:00 user:pw@reg.example/p "reg.example/p q" reg.example:99999x/p; do
  t "remote: IMAGE_REGISTRY='$bad' refused" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY="$bad" | grep -c 'IMAGE_REGISTRY')" 1
done
t "remote: the refusal does not print a user:password value" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=user:s3cr3t@reg.example/p | grep -c s3cr3t)" 0
for bad in ghcr.io/openagentix ghcr.io/openagentix/dev GHCR.io/openagentix; do
  t "remote: IMAGE_REGISTRY='$bad' (the release namespace) refused" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY="$bad" | grep -cE 'release images|IMAGE_REGISTRY')" 1
done
t "remote: ghcr.io/openagentix-fork is not the release namespace" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=ghcr.io/openagentix-fork)" "ok linux/amd64"
t "remote: the release refusal names ADR 0018" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=ghcr.io/openagentix | grep -c 'ADR 0018')" 1

echo "# repositories"
t "platform image repository" "$( IMAGE_REGISTRY=reg.example/p; . hack/images.sh; image_repo telegram)" reg.example/p/openagentix/telegram
t "example image repository (a separate path)" "$( IMAGE_REGISTRY=reg.example/p; . hack/images.sh; image_example_repo echo-a2a)" reg.example/p/openagentix-examples/echo-a2a

echo "# build: kind and k3d keep today's command"
( CLUSTER_TYPE=kind; . hack/images.sh; image_build openagentix/kb:dev-1 services/kb "" "$D/m.json" ); t "kind: docker build -q, no buildx, no push" "$(calls)" "docker build -q -t openagentix/kb:dev-1 services/kb;"
( CLUSTER_TYPE=k3d; . hack/images.sh; image_build openagentix/console:dev-1 . services/console/Dockerfile "$D/m.json" ); t "k3d: docker build -q -f" "$(calls)" "docker build -q -t openagentix/console:dev-1 -f services/console/Dockerfile .;"

echo "# build: remote pushes with buildx"
( CLUSTER_TYPE=remote; IMAGE_PLATFORM=linux/amd64; . hack/images.sh; image_build reg.example/p/openagentix/kb:dev-1 services/kb "" "$D/m.json" )
t "remote: buildx build --platform --push, provenance and sbom off, a metadata file" "$(calls)" "docker buildx build --platform linux/amd64 --push --provenance=false --sbom=false --metadata-file $D/m.json -q -t reg.example/p/openagentix/kb:dev-1 services/kb;"
( CLUSTER_TYPE=remote; IMAGE_PLATFORM=linux/amd64,linux/arm64; . hack/images.sh; image_build reg.example/p/openagentix/console:dev-1 . services/console/Dockerfile "$D/m.json" )
t "remote: two platforms, -f before the context" "$(calls)" "docker buildx build --platform linux/amd64,linux/arm64 --push --provenance=false --sbom=false --metadata-file $D/m.json -q -t reg.example/p/openagentix/console:dev-1 -f services/console/Dockerfile .;"

echo "# digest from the build metadata"
t "a digest is read" "$( CLUSTER_TYPE=remote; IMAGE_PLATFORM=linux/amd64; . hack/images.sh; image_build r/x:1 c "" "$D/g.json"; image_digest "$D/g.json")" "$DG"
t "no digest in the metadata: fails" "$( FAKE_META=nodigest; export FAKE_META; CLUSTER_TYPE=remote; IMAGE_PLATFORM=linux/amd64; . hack/images.sh; image_build r/x:1 c "" "$D/n.json"; image_digest "$D/n.json" >/dev/null 2>&1; echo $?)" 1
t "a malformed digest: fails" "$( FAKE_META=bad; export FAKE_META; CLUSTER_TYPE=remote; IMAGE_PLATFORM=linux/amd64; . hack/images.sh; image_build r/x:1 c "" "$D/b.json"; image_digest "$D/b.json" >/dev/null 2>&1; echo $?)" 1
t "no metadata file: fails" "$( . hack/images.sh; image_digest "$D/missing.json" >/dev/null 2>&1; echo $?)" 1
: > "$D/calls"

echo "# the installer uses the library"
t "install.sh sources hack/images.sh" "$(grep -c '^\. hack/images.sh' install.sh)" 1
t "install.sh never runs docker login" "$(grep -hv '^[[:space:]]*#' install.sh hack/images.sh | grep -c 'docker login')" 0
[ "$F" = 0 ] && echo "images-test: all passed" || { echo "images-test: FAILED"; exit 1; }
