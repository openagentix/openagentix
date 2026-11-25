#!/usr/bin/env bash
# Does this cluster enforce NetworkPolicy? A live check, for the cluster kubectl points at (used by the e2e-k3s job; run it on kind to compare).
#   1. a client reaches a server pod (nothing blocks it)
#   2. after a deny-all ingress policy on the server, the same request fails          -> ingress is enforced
#   3. a client reaches an address on the internet (a TCP connection to 1.1.1.1 port 80)
#   4. after a deny-all egress policy on the client, the same request fails           -> egress is enforced
# Prints one line per step and a verdict line for each of ingress and egress. Exit 0 when both are enforced, 1 when one is not, 2 on a setup problem.
# It creates the namespace oa-netpol-test and deletes it at the end. Needs kubectl only (the pods use busybox).
set -uo pipefail
K=${KUBECTL:-kubectl}; NS=${NETPOL_NAMESPACE:-oa-netpol-test}; IMG=${NETPOL_IMAGE:-busybox:1.37}
trap '$K delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1' EXIT
$K create namespace "$NS" >/dev/null || { echo "cannot create namespace $NS" >&2; exit 2; }
$K apply -n "$NS" -f - >/dev/null <<EOF || exit 2
apiVersion: v1
kind: Pod
metadata: {name: server, labels: {app: server}}
spec:
  containers:
    - name: s
      image: $IMG
      command: [sh, -c, "mkdir -p /www; echo ok > /www/index.html; httpd -f -p 8080 -h /www"]
---
apiVersion: v1
kind: Pod
metadata: {name: client, labels: {app: client}}
spec:
  containers:
    - name: c
      image: $IMG
      command: [sleep, "3600"]
EOF
$K wait -n "$NS" pod --all --for=condition=Ready --timeout=180s >/dev/null || { echo "pods are not Ready" >&2; $K get pods -n "$NS" >&2; exit 2; }
SIP=$($K get pod server -n "$NS" -o jsonpath='{.status.podIP}')
fetch(){ $K exec -n "$NS" client -- wget -q -T 5 -O - "$1" 2>/dev/null; }
tcp(){ $K exec -n "$NS" client -- nc -w 5 "$1" "$2" </dev/null >/dev/null 2>&1; }   # 0 when the connection was made
step(){ printf '%-62s %s\n' "$1" "$2"; }

[ "$(fetch "http://$SIP:8080/")" = ok ] && step "1. client reaches the server (no policy)" "reached" || { step "1. client reaches the server (no policy)" "FAILED (setup problem)"; exit 2; }
$K apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-ingress}
spec:
  podSelector: {matchLabels: {app: server}}
  policyTypes: [Ingress]
EOF
INGRESS=not-enforced
for _ in $(seq 1 20); do   # the policy controller needs a moment
  [ "$(fetch "http://$SIP:8080/")" = ok ] || { INGRESS=enforced; break; }; sleep 2
done
step "2. deny-all ingress on the server: client request" "$([ "$INGRESS" = enforced ] && echo blocked || echo reached)"

NET_OK=no; tcp 1.1.1.1 80 && NET_OK=yes
step "3. client reaches 1.1.1.1 (no egress policy)" "$([ "$NET_OK" = yes ] && echo reached || echo 'not reached (no internet from the runner? egress test is void)')"
$K apply -n "$NS" -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-egress}
spec:
  podSelector: {matchLabels: {app: client}}
  policyTypes: [Egress]
EOF
EGRESS=not-enforced
for _ in $(seq 1 20); do
  tcp 1.1.1.1 80 || { EGRESS=enforced; break; }; sleep 2
done
[ "$NET_OK" = yes ] || EGRESS=unknown
step "4. deny-all egress on the client: connection to 1.1.1.1" "$([ "$EGRESS" = enforced ] && echo blocked || { [ "$EGRESS" = unknown ] && echo 'unknown' || echo reached; })"

echo "NetworkPolicy ingress: $INGRESS"
echo "NetworkPolicy egress to the internet: $EGRESS"
[ "$INGRESS" = enforced ] && [ "$EGRESS" = enforced ]
