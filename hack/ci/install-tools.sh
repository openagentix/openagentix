#!/usr/bin/env bash
# Install the pinned CI tools on a Linux amd64 GitHub runner (or any Linux amd64 box), each verified by SHA-256.
#   hack/ci/install-tools.sh gitleaks shellcheck yq [kind] [k3d]
# Binaries go to ${CI_BIN:-$HOME/.local/bin}, which is added to $GITHUB_PATH when set. helm is installed by its own action.
set -euo pipefail

GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb   # gitleaks_8.30.1_linux_x64.tar.gz
SHELLCHECK_VERSION=0.11.0
SHELLCHECK_SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 # file: shellcheck-v0.11.0.linux.x86_64.tar.xz
YQ_VERSION=3.4.3            # kislyuk/yq, the Python jq wrapper (NOT mikefarah/yq): `pip install yq`
KIND_VERSION=0.33.0
KIND_SHA256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d       # kind-linux-amd64
K3D_VERSION=5.9.0
K3D_SHA256=06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0         # k3d-linux-amd64

BIN=${CI_BIN:-$HOME/.local/bin}; mkdir -p "$BIN"
[ -z "${GITHUB_PATH:-}" ] || echo "$BIN" >>"$GITHUB_PATH"
export PATH="$BIN:$PATH"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

fetch() { # fetch <url> <sha256> <file>
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c - >/dev/null || { echo "checksum mismatch for $1" >&2; exit 1; }
}

for t in "$@"; do
  case "$t" in
    gitleaks)
      fetch "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" "$GITLEAKS_SHA256" "$TMP/gl.tgz"
      tar -xzf "$TMP/gl.tgz" -C "$BIN" gitleaks ;;
    shellcheck)
      fetch "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" "$SHELLCHECK_SHA256" "$TMP/sc.txz"
      tar -xJf "$TMP/sc.txz" -C "$TMP"; install "$TMP/shellcheck-v${SHELLCHECK_VERSION}/shellcheck" "$BIN/shellcheck" ;;
    yq)
      python3 -m pip install --user --quiet "yq==${YQ_VERSION}" ;;
    kind)
      fetch "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64" "$KIND_SHA256" "$TMP/kind"
      install "$TMP/kind" "$BIN/kind" ;;
    k3d)
      fetch "https://github.com/k3d-io/k3d/releases/download/v${K3D_VERSION}/k3d-linux-amd64" "$K3D_SHA256" "$TMP/k3d"
      install "$TMP/k3d" "$BIN/k3d" ;;
    *) echo "unknown tool: $t" >&2; exit 2 ;;
  esac
done
