#!/usr/bin/env bash
# Tests for hack/images.sh (ADR 0022) with a fake `docker` that records its arguments, writes a buildx metadata file and answers
# `buildx imagetools inspect` from fixtures. No Docker, no registry.
#   FAKE_META=good|nodigest|bad|none   what `buildx build` writes into --metadata-file
#   FAKE_PUSH=fail                     `buildx build` fails (as a registry that refuses the push)
#   FAKE_EXIST=linux/amd64             the tag already exists in the registry, for that platform (unset: it does not exist)
#   FAKE_RAW=fail                      `imagetools inspect --raw <repo>@<digest>` fails (the digest is not in the registry)
#   FAKE_PUSHED=linux/arm64            the platform of the pushed digest (default: linux/amd64)
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
DG=sha256:$(printf '%064d' 7)
DE=sha256:$(printf 'e%.0s' $(seq 64))
cat > "$D/bin/docker" <<EOS
#!/usr/bin/env bash
echo "docker \$*" >> "$D/calls"
if [ "\$1 \$2" = "buildx build" ]; then
  [ "\${FAKE_PUSH:-}" != fail ] || { echo "push refused: tag is immutable" >&2; exit 1; }
  m=""; while [ \$# -gt 0 ]; do [ "\$1" = --metadata-file ] && m=\$2; shift; done
  case "\${FAKE_META:-good}" in
    good) echo '{"containerimage.digest":"$DG","image.name":"x"}' > "\$m";;
    nodigest) echo '{"image.name":"x"}' > "\$m";;
    bad) echo '{"containerimage.digest":"sha256:abc"}' > "\$m";;
    none) ;;
  esac
  exit 0
fi
if [ "\$1 \$2 \$3" = "buildx imagetools inspect" ]; then
  shift 3; raw=0; fmt=""; ref=""
  while [ \$# -gt 0 ]; do case "\$1" in --raw) raw=1;; --format) fmt=\$2; shift;; *) ref=\$1;; esac; shift; done
  if [[ "\$ref" == *@* ]]; then   # the pushed digest
    if [ \$raw = 1 ]; then [ "\${FAKE_RAW:-}" != fail ] || exit 1; echo '{"mediaType":"application/vnd.oci.image.manifest.v1+json"}'; exit 0; fi
    p=\${FAKE_PUSHED:-linux/amd64}; echo "{\"os\":\"\${p%/*}\",\"architecture\":\"\${p#*/}\"}"; exit 0
  fi
  [ -n "\${FAKE_EXIST:-}" ] || { echo "ERROR: \$ref: not found" >&2; exit 1; }
  case "\$fmt" in
    *.Manifest*) echo '{"digest":"$DE"}';;
    *.Image*) p=\$FAKE_EXIST; echo "{\"os\":\"\${p%/*}\",\"architecture\":\"\${p#*/}\"}";;
  esac
  exit 0
fi
exit 0
EOS
chmod +x "$D/bin/docker"
export PATH="$D/bin:$PATH"
: > "$D/calls"
calls(){ tr '\n' ';' < "$D/calls"; : > "$D/calls"; }
# chk <env...>: images_check in a clean subshell; prints "ok <platform>" or the error line
chk(){ ( env -i PATH="$PATH" "$@" bash -c '. hack/images.sh; if images_check 2>"$0"; then echo "ok ${IMAGE_PLATFORM:-}"; else head -1 "$0"; fi' "$D/err" ); }
# push <env...> -- <image> <context> <Dockerfile>: image_build on remote in a clean subshell; prints the exit code, then the digest it found
push(){ local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  ( env -i PATH="$PATH" CLUSTER_TYPE=remote IMAGE_PLATFORM=linux/amd64 ${e[@]+"${e[@]}"} bash -c '. hack/images.sh; image_build "$1" "$2" "$3" "$4" 2>"$5"; r=$?; echo "rc=$r"; [ $r = 0 ] && image_digest "$4" 2>/dev/null' _ "$1" "$2" "$3" "$D/m.json" "$D/err" ); }

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
t "remote: two platforms refused for now (ADR 0022 slice 5)" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=reg.example/p IMAGE_PLATFORM=linux/amd64,linux/arm64 | grep -c 'one platform')" 1
t "remote: a host with a port accepted" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=localhost:5000/oa)" "ok linux/amd64"
t "remote: ghcr.io/acme accepted" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=ghcr.io/acme)" "ok linux/amd64"
for bad in linux/386 amd64 "linux/amd64," "linux/amd64 linux/arm64" linux/arm64/v8; do
  t "remote: IMAGE_PLATFORM='$bad' refused" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=reg.example/p IMAGE_PLATFORM="$bad" | grep -c 'IMAGE_PLATFORM')" 1
done
for bad in https://reg.example/p reg.example/p/ reg.example myname/repo Reg.example/p reg.example/p:tag reg.example/p@sha256:00 user:pw@reg.example/p "reg.example/p q" reg.example:99999x/p; do
  t "remote: IMAGE_REGISTRY='$bad' refused" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY="$bad" | grep -c 'IMAGE_REGISTRY')" 1
done
t "remote: the refusal does not print a user:password value" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=user:s3cr3t@reg.example/p | grep -c s3cr3t)" 0
for bad in ghcr.io/openagentix ghcr.io/openagentix/dev ghcr.io:443/openagentix ghcr.io:443/openagentix/x ghcr.io:0443/openagentix ghcr.io:00443/openagentix/x; do
  t "remote: IMAGE_REGISTRY='$bad' (the release namespace) refused" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY="$bad" | grep -c 'signed release images')" 1
done
for good in ghcr.io/openagentix-dev ghcr.io/acme/openagentix ghcr.io:5000/openagentix ghcr.io:4430/openagentix; do
  t "remote: IMAGE_REGISTRY='$good' is not the release namespace" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY="$good")" "ok linux/amd64"
done
t "remote: the release refusal names ADR 0018" "$(chk CLUSTER_TYPE=remote IMAGE_REGISTRY=ghcr.io/openagentix | grep -c 'ADR 0018')" 1

echo "# repositories and tags"
t "platform image repository" "$( IMAGE_REGISTRY=reg.example/p; . hack/images.sh; image_repo telegram)" reg.example/p/openagentix/telegram
t "example image repository (a separate path)" "$( IMAGE_REGISTRY=reg.example/p; . hack/images.sh; image_example_repo echo-a2a)" reg.example/p/openagentix-examples/echo-a2a
t "remote tag carries the architecture" "$( IMAGE_PLATFORM=linux/amd64; . hack/images.sh; image_remote_tag dev-0123456789abcdef)" dev-0123456789abcdef-amd64
t "remote tag for arm64" "$( IMAGE_PLATFORM=linux/arm64; . hack/images.sh; image_remote_tag dev-0123456789abcdef)" dev-0123456789abcdef-arm64

echo "# build: kind and k3d keep today's command"
( CLUSTER_TYPE=kind; . hack/images.sh; image_build openagentix/kb:dev-1 services/kb "" "$D/m.json" ); t "kind: docker build -q, no buildx, no push" "$(calls)" "docker build -q -t openagentix/kb:dev-1 services/kb;"
( CLUSTER_TYPE=k3d; . hack/images.sh; image_build openagentix/console:dev-1 . services/console/Dockerfile "$D/m.json" ); t "k3d: docker build -q -f" "$(calls)" "docker build -q -t openagentix/console:dev-1 -f services/console/Dockerfile .;"

echo "# build: remote pushes with buildx, then checks the digest in the registry"
R=reg.example/p/openagentix/kb; IMG=$R:dev-1-amd64
t "remote, new tag: pushed, the digest from the metadata" "$(push -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=0 $DG "
t "remote, new tag: inspect the tag, build and push, then inspect --raw and the platform of the digest" "$(calls)" "docker buildx imagetools inspect $IMG --format {{json .Image}};docker buildx build --platform linux/amd64 --push --provenance=false --sbom=false --metadata-file $D/m.json -q -t $IMG services/kb;docker buildx imagetools inspect --raw $R@$DG;docker buildx imagetools inspect $R@$DG --format {{json .Image}};"
push -- reg.example/p/openagentix/console:dev-1-amd64 . services/console/Dockerfile >/dev/null
t "remote: -f before the context" "$(grep -c -- '-q -t reg.example/p/openagentix/console:dev-1-amd64 -f services/console/Dockerfile .$' "$D/calls")" 1; : > "$D/calls"
t "remote, tag exists for the same platform: its digest, no build" "$(push FAKE_EXIST=linux/amd64 -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=0 $DE "
t "remote, tag exists: no buildx build, no push" "$(grep -c 'buildx build' "$D/calls")" 0; : > "$D/calls"
t "remote, tag exists for another platform: stops" "$(push FAKE_EXIST=linux/arm64 -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=1 "
t "remote, tag exists for another platform: the message" "$(grep -c "tag $IMG exists for platform linux/arm64, not linux/amd64; delete it or set IMAGE_REBUILD=1" "$D/err")" 1
t "remote, tag exists for another platform: nothing built" "$(grep -c 'buildx build' "$D/calls")" 0; : > "$D/calls"
t "remote, IMAGE_REBUILD=1 on an existing tag: built and pushed again" "$(push FAKE_EXIST=linux/amd64 IMAGE_REBUILD=1 -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=0 $DG "
t "remote, IMAGE_REBUILD=1: one buildx build" "$(grep -c 'buildx build' "$D/calls")" 1; : > "$D/calls"
t "remote, IMAGE_REBUILD=1 and the registry refuses the push: stops" "$(push FAKE_EXIST=linux/amd64 IMAGE_REBUILD=1 FAKE_PUSH=fail -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=1 "
t "remote, IMAGE_REBUILD=1 refused: the registry's message and the hint" "$(grep -c 'tag is immutable' "$D/err")/$(grep -c 'this registry does not allow overwriting a tag; remove IMAGE_REBUILD' "$D/err")" 1/1; : > "$D/calls"
t "remote, a failed push without IMAGE_REBUILD: stops, no hint" "$(push FAKE_PUSH=fail -- "$IMG" services/kb "" | tr '\n' ' ')/$(grep -c 'remove IMAGE_REBUILD' "$D/err")" "rc=1 /0"; : > "$D/calls"
t "remote, no digest in the metadata: stops" "$(push FAKE_META=nodigest -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=1 "
t "remote, no digest: the message" "$(grep -c 'no image digest' "$D/err")" 1
t "remote, a malformed digest: stops" "$(push FAKE_META=bad -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=1 "
t "remote, the digest is not in the registry (inspect --raw fails): stops" "$(push FAKE_RAW=fail -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=1 "
t "remote, the digest is not in the registry: the message" "$(grep -c "$R@$DG is not in the registry" "$D/err")" 1
t "remote, the pushed image is arm64, not amd64: stops" "$(push FAKE_PUSHED=linux/arm64 -- "$IMG" services/kb "" | tr '\n' ' ')" "rc=1 "
t "remote, wrong platform: the message" "$(grep -c "$R@$DG is linux/arm64, not linux/amd64" "$D/err")" 1
t "no metadata file: image_digest fails" "$( . hack/images.sh; image_digest "$D/missing.json" >/dev/null 2>&1; echo $?)" 1
: > "$D/calls"
CANARY=canary-$RANDOM$RANDOM
push DOCKER_PASSWORD="$CANARY" REGISTRY_TOKEN="$CANARY" GOOGLE_OAUTH_ACCESS_TOKEN="$CANARY" -- "$IMG" services/kb "" >/dev/null
t "a credential in the environment never reaches an argument or a message" "$(grep -c "$CANARY" "$D/calls" "$D/err" | awk -F: '{s+=$2} END{print s}')" 0

echo "# the rule for platform images on remote (images_render_check, before helm upgrade)"
# rc <IMAGE_REGISTRY> <built paths> -- <path=image>...: a render with those images; prints the messages and rc, joined by |
wl(){ printf '{"kind":"Deployment","metadata":{"name":"%s"},"spec":{"template":{"spec":{"containers":[{"image":"%s"}]}}}}\n' "$1" "$2"; }
rc(){ local reg=$1 built=$2 r="" p i x; shift 3
  for x in "$@"; do p=${x%%=*}; i=${x#*=}
    case "$p" in
      bridge) r+=$(wl telegram-bridge "$i")$'\n';;
      scheduling) r+=$(printf '{"kind":"CronJob","metadata":{"name":"s1","labels":{"openagentix.io/schedule":"s1"}},"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"image":"%s"}]}}}}}}' "$i")$'\n';;
      controlPlane) r+=$(wl openagentix-control-plane "$i")$'\n';;
      console) r+=$(wl openagentix-console "$i")$'\n';;
      renamedConsole) r+=$(wl my-console "$i")$'\n';;
      diagnostics) r+=$(wl cluster-read "$i")$'\n';;
    esac
  done
  r+=$(wl other busybox:1)$'\n'
  r+='{"kind":"CronJob","metadata":{"name":"memory-expiry"},"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":[{"image":"postgres:17"}]}}}}}}'$'\n'
  ( IMAGE_REGISTRY=$reg; . hack/images.sh; images_render_check "$r" $built 2>&1; echo "rc=$?" ) | tr '\n' '|'; }
REG=reg.example/p; DGX=sha256:$(printf 'f%.0s' $(seq 64))
t "built images with digests from IMAGE_REGISTRY: passes, nothing said" "$(rc $REG "controlPlane console" -- controlPlane=$REG/openagentix/control-plane:dev-1-amd64@$DGX console=$REG/openagentix/console@$DGX)" "rc=0|"
t "an unqualified image (the default openagentix/<name>:dev) is refused, the path named" "$(rc "" "" -- controlPlane=openagentix/control-plane:dev | grep -c 'controlPlane: openagentix/control-plane:dev is an unqualified name')" 1
t "an unqualified image: rc 1" "$(rc "" "" -- controlPlane=openagentix/control-plane:dev | grep -o 'rc=[0-9]')" rc=1
t "with IMAGE_REGISTRY: an image outside it is refused" "$(rc $REG "" -- console=other.example/x/console:v1@$DGX | grep -c "console: other.example/x/console:v1@$DGX is not under IMAGE_REGISTRY=$REG/")" 1
t "a built image without a digest is refused" "$(rc $REG "console" -- console=$REG/openagentix/console:dev-1-amd64 | grep -c 'console: the installer built .* but it has no digest')" 1
t "an operator image by tag (no IMAGE_REGISTRY): a warning, passes" "$(rc "" "" -- controlPlane=europe-west4-docker.pkg.dev/p/oa/control-plane:gke1)" "WARN: controlPlane runs europe-west4-docker.pkg.dev/p/oa/control-plane:gke1 by tag; set controlPlane.image.digest to pin it|rc=0|"
t "an operator image by digest: no warning" "$(rc "" "" -- controlPlane=europe-west4-docker.pkg.dev/p/oa/control-plane:gke1@$DGX)" "rc=0|"
t "a host with a port is qualified" "$(rc "" "" -- bridge=localhost:5000/x/telegram:v1@$DGX)" "rc=0|"
t "the schedules CronJob image is checked (scheduling)" "$(rc "" "" -- scheduling=openagentix/a2a-call:dev | grep -c 'scheduling: openagentix/a2a-call:dev is an unqualified name')" 1
t "a built image path not found in the rendered workloads (a renamed Deployment) is refused, the path named" "$(rc $REG "console" -- renamedConsole=$REG/openagentix/console@$DGX | grep -c 'console: the installer built an image for this path but no rendered workload runs it')" 1
t "a built image path not found: rc 1" "$(rc $REG "console" -- renamedConsole=$REG/openagentix/console@$DGX | grep -o 'rc=[0-9]')" rc=1
t "diagnostics (cluster-read, ADR 0025): the built image with a digest from IMAGE_REGISTRY passes" "$(rc $REG "diagnostics" -- diagnostics=$REG/openagentix/diagnostics:dev-1-amd64@$DGX)" "rc=0|"
t "diagnostics: an unqualified image is refused, the path named" "$(rc "" "" -- diagnostics=openagentix/diagnostics:dev | grep -c 'diagnostics: openagentix/diagnostics:dev is an unqualified name')" 1
t "diagnostics: a built image with no rendered cluster-read Deployment is refused" "$(rc $REG "diagnostics" -- renamedConsole=$REG/openagentix/console@$DGX | grep -c 'diagnostics: the installer built an image for this path but no rendered workload runs it')" 1
t "a built image path not found next to one that is found: only that path is named" "$(rc $REG "controlPlane console" -- controlPlane=$REG/openagentix/control-plane@$DGX | grep -c 'console: the installer built an image')" 1
t "images of other workloads (a Deployment, the memory-expiry CronJob) are not checked" "$(rc "" "" -- | grep -cE 'busybox|postgres')" 0

echo "# every Dockerfile the installer pushes pins its base images by digest (ADR 0022)"
for f in bridges/telegram/Dockerfile tools/a2a-call/Dockerfile services/kb/Dockerfile services/notify/Dockerfile services/a2a-gate/Dockerfile services/stub-model/Dockerfile services/control-plane/Dockerfile services/console/Dockerfile services/diagnostics/Dockerfile examples/agents/echo-a2a/Dockerfile; do
  t "$f: every FROM is pinned by digest" "$(grep -E '^FROM[[:space:]]' "$f" | grep -vc '@sha256:[0-9a-f]\{64\}')" 0
done

echo "# the installer uses the library"
t "install.sh sources hack/images.sh" "$(grep -c '^\. hack/images.sh' install.sh)" 1
t "install.sh and hack/images.sh never run docker login" "$(grep -hv '^[[:space:]]*#' install.sh hack/images.sh | grep -c 'docker login')" 0
[ "$F" = 0 ] && echo "images-test: all passed" || { echo "images-test: FAILED"; exit 1; }
