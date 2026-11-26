#!/usr/bin/env bash
# The Substrate API authentication file (ConfigMap ate-system/ate-api-authentication). Sourced by up.sh. Tests: tests/run.sh.
#   ate_issuer               the service account token issuer of the current cluster (its OpenID discovery document)
#   ate_auth_config <issuer> the file. certificateAuthorityFile and discoveryTokenFile are written only for an in-cluster issuer
#                            (https://kubernetes.default.svc...: kind, k3s), where discovery goes to the API server with the pod's own CA and
#                            token. For an external issuer (GKE: https://container.googleapis.com/...) they are left out (issue #164).
#                            Used once on GKE (the quick start agent became Ready): docs/diary/guide/install-gke.md.

ate_issuer(){
  local i
  i=$(${KUBECTL:-kubectl} get --raw /.well-known/openid-configuration | jq -r '.issuer // empty') || return 1
  [ -n "$i" ] || { echo "ERROR: the cluster's OpenID discovery document has no issuer" >&2; return 1; }
  printf '%s\n' "$i"
}

ate_auth_config(){
  local issuer=${1:-}
  [ -n "$issuer" ] || { echo "ERROR: ate_auth_config needs the issuer" >&2; return 1; }
  cat <<EOF
jwtProviders:
- name: kubernetes
  issuer: $issuer
  audiences: [api.ate-system.svc]
EOF
  case "$issuer" in
    https://kubernetes.default.svc|https://kubernetes.default.svc/*|https://kubernetes.default.svc.*)
      cat <<EOF
  # in-cluster issuer (kind): these two lines are required; on GKE-style external issuers they must be omitted
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
EOF
      ;;
  esac
}
