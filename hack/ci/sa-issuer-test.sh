#!/usr/bin/env bash
# Offline tests of hack/sa-issuer.sh (issue #167): the service account issuer the installer passes to the workload tool server.
# No cluster, no kubectl: the functions read JSON fixtures.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
# shellcheck source=hack/sa-issuer.sh
. hack/sa-issuer.sh
KIND=https://kubernetes.default.svc.cluster.local
GKE=https://container.googleapis.com/v1/projects/my-proj/locations/europe-west4-a/clusters/oa-test
DISC_KIND="{\"issuer\":\"$KIND\",\"jwks_uri\":\"https://172.18.0.2:6443/openid/v1/jwks\"}"
DISC_GKE="{\"issuer\":\"$GKE\",\"jwks_uri\":\"https://container.googleapis.com/v1/projects/my-proj/locations/europe-west4-a/clusters/oa-test/jwks\"}"
PODS='{"items":[{"spec":{"containers":[{"command":["kube-apiserver","--service-account-issuer=https://oidc.example.org","--service-account-issuer=https://old.example.org"]}]}}]}'

echo "# the discovery document (first choice)"
t "kind form" "$(sa_issuer "" "$DISC_KIND" "")" "$KIND"
t "GKE form" "$(sa_issuer "" "$DISC_GKE" "")" "$GKE"
echo "# the API server flag (fallback, when there is no discovery document)"
t "no discovery document: the first --service-account-issuer flag of the kube-apiserver pod" "$(sa_issuer "" "" "$PODS")" "https://oidc.example.org"
t "an empty discovery document falls back too" "$(sa_issuer "" "{}" "$PODS")" "https://oidc.example.org"
t "the discovery document wins over the flag" "$(sa_issuer "" "$DISC_GKE" "$PODS")" "$GKE"
echo "# the override"
t "SERVICE_ACCOUNT_ISSUER (argument 1) wins over both" "$(sa_issuer https://mine.example.com "$DISC_GKE" "$PODS")" "https://mine.example.com"
echo "# nothing found, or not usable"
sa_issuer "" "" "" >/dev/null 2>&1; t "nothing found fails" "$?" 1
sa_issuer "" "" '{"items":[]}' >/dev/null 2>&1; t "no kube-apiserver pod fails" "$?" 1
sa_issuer "" '{"issuer":"http://plain.example.org"}' "" >/dev/null 2>&1; t "an http issuer is refused (the chart wants https)" "$?" 1
sa_issuer "" '{"issuer":"https://a.example.org/x?y=1"}' "" >/dev/null 2>&1; t "an issuer with a query is refused" "$?" 1
sa_issuer "" "not json" "" >/dev/null 2>&1; t "garbage is not an issuer" "$?" 1
echo "# only when the user has not set it, and only when it differs from the default"
t "default issuer on the cluster: nothing to pass" "$(sa_issuer_set_value "$KIND" "$KIND" "$KIND")" ""
t "GKE issuer, chart default rendered: pass it" "$(sa_issuer_set_value "$GKE" "$KIND" "$KIND")" "$GKE"
t "the user set another issuer: pass nothing" "$(sa_issuer_set_value "$GKE" "https://mine.example.com" "$KIND")" ""
t "the user set the issuer to the cluster's own: pass nothing" "$(sa_issuer_set_value "$GKE" "$GKE" "$KIND")" ""
echo "# install.sh wires it"
t "install.sh sources hack/sa-issuer.sh" "$(grep -c '^ *\. hack/sa-issuer.sh' install.sh)" 1
t "install.sh passes serviceAccountTokens.issuer with --set-string" "$(grep -c 'set-string "controlPlane.containerAgents.serviceAccountTokens.issuer=' install.sh)" 1
exit $F
