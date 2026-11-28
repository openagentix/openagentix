#!/usr/bin/env bash
# Does this cluster enforce NetworkPolicy between pods? (issue #212; the installer runs it with CHECK_NETPOL=1)
#
# The isolation of OpenAgentix (tool servers, records endpoints, agent egress) is written as NetworkPolicy objects. They only hold when the cluster's network
# plugin enforces them: kind's default plugin (kindnet) and some others apply the objects and cut nothing. This script finds out in a short, live probe:
#   1. it starts two throwaway pods in the release namespace: a server (a small web server) and a client
#   2. the client reaches the server (the control: nothing blocks it yet)
#   3. it applies a deny-all ingress policy to the server
#   4. the client is cut off from the server -> PASS (the plugin enforces ingress policy between pods); it still reaches it -> FAIL
# If the control fails, or a pod does not start, the answer is INCONCLUSIVE and never a PASS.
# It says nothing about egress to the internet: that is a different rule, and hack/ci/netpol-test.sh checks it for a cluster you may change.
#
# The pods use a restricted security context (non-root, no privilege escalation, all capabilities dropped, seccomp RuntimeDefault, read-only root file
# system, no service account token) and an image pinned by digest. Everything the check creates carries the label app.kubernetes.io/name=oa-netpol-probe and
# is deleted on every way out (the end, an error, Ctrl-C, a termination signal); objects of an earlier, killed run are deleted first.
#
# Environment: KUBECTL (default kubectl), KUBE_CONTEXT, NETPOL_NAMESPACE (default openagentix-system), NETPOL_IMAGE (a busybox image with a digest),
#   NETPOL_WAIT (seconds to wait for the cut, default 60), NETPOL_POD_WAIT (seconds for the pods to be Ready, default 120), NETPOL_SLEEP (seconds between tries, default 2)
#   REQUIRE_NETPOL=1  exit 1 on FAIL and 2 on INCONCLUSIVE. Without it the script prints the verdict and exits 0 whatever it found.
set -uo pipefail
NS=${NETPOL_NAMESPACE:-openagentix-system}
IMG=${NETPOL_IMAGE:-busybox:1.37@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec}
WAIT=${NETPOL_WAIT:-60}; POD_WAIT=${NETPOL_POD_WAIT:-120}; NAP=${NETPOL_SLEEP:-2}
K=("${KUBECTL:-kubectl}"); [ -z "${KUBE_CONTEXT:-}" ] || K+=(--context "$KUBE_CONTEXT")
LABEL=app.kubernetes.io/name=oa-netpol-probe

verdict(){ # verdict <exit code if required> <text...>
  local rc=$1; shift
  printf '%s\n' "$@"
  [ "${REQUIRE_NETPOL:-}" = 1 ] && exit "$rc"
  exit 0
}
cleanup(){ "${K[@]}" delete pod,networkpolicy -n "$NS" -l "$LABEL" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM HUP
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP   # the EXIT trap above then runs the clean-up

NOTE="This probe tests pod to pod ingress inside the cluster. It says nothing about egress to the internet."
inconclusive(){ verdict 2 "NetworkPolicy check: INCONCLUSIVE ($1). It is not a pass: the isolation of OpenAgentix is not shown to hold on this cluster." "$NOTE"; }

case "$IMG" in *@sha256:????????????????????????????????????????????????????????????????) ;; *) inconclusive "NETPOL_IMAGE must be pinned by digest (name@sha256:<64 hex>), got $IMG";; esac

echo "NetworkPolicy check: probing namespace $NS (two throwaway pods and one deny-all ingress policy, all deleted afterwards)"
cleanup_stale(){ "${K[@]}" delete pod,networkpolicy -n "$NS" -l "$LABEL" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true; }
cleanup_stale

pod(){ # pod <component> <command...>
  local comp=$1; shift
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: oa-netpol-probe-$comp
  labels: {app.kubernetes.io/name: oa-netpol-probe, app.kubernetes.io/component: $comp}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: probe
      image: $IMG
      command: $1
      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 100m, memory: 32Mi}}
      securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: tmp, mountPath: /tmp}]
$2
  volumes: [{name: tmp, emptyDir: {sizeLimit: 1Mi}}]
EOF
}
MANIFEST=$({
  pod server '["sh","-c","mkdir -p /tmp/www; echo ok > /tmp/www/index.html; exec httpd -f -p 8080 -h /tmp/www"]' '      readinessProbe: {httpGet: {path: /, port: 8080}, periodSeconds: 2}'
  echo '---'
  pod client '["sleep","3600"]' ''
})
printf '%s\n' "$MANIFEST" | "${K[@]}" apply -n "$NS" -f - >/dev/null 2>"${TMPDIR:-/tmp}/oa-netpol-apply.$$" \
  || { r=$(head -n 1 "${TMPDIR:-/tmp}/oa-netpol-apply.$$" | cut -c1-200); rm -f "${TMPDIR:-/tmp}/oa-netpol-apply.$$"; inconclusive "the probe pods could not be created in $NS: $r"; }
rm -f "${TMPDIR:-/tmp}/oa-netpol-apply.$$"
"${K[@]}" wait -n "$NS" pod -l "$LABEL" --for=condition=Ready --timeout="${POD_WAIT}s" >/dev/null 2>&1 \
  || inconclusive "the probe pods did not become Ready in ${POD_WAIT}s (an image that cannot be pulled, a quota, or an admission rule)"
SIP=$("${K[@]}" get pod oa-netpol-probe-server -n "$NS" -o jsonpath='{.status.podIP}' 2>/dev/null)
[ -n "$SIP" ] || inconclusive "the server pod has no IP"
fetch(){ "${K[@]}" exec -n "$NS" oa-netpol-probe-client -- wget -q -T 5 -O - "http://$SIP:8080/" 2>/dev/null; }

# the control: without a policy the client must reach the server
reached=0
for _ in 1 2 3 4 5; do [ "$(fetch)" = ok ] && { reached=1; break; }; sleep "$NAP"; done
[ "$reached" = 1 ] || inconclusive "the client pod could not reach the server pod before any probe policy: another policy in $NS already blocks pod to pod traffic, or pod networking is broken"

# the policy
"${K[@]}" apply -n "$NS" -f - >/dev/null 2>&1 <<EOF || inconclusive "the deny-all ingress policy could not be created in $NS"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: oa-netpol-probe-deny
  labels: {app.kubernetes.io/name: oa-netpol-probe}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/name: oa-netpol-probe, app.kubernetes.io/component: server}}
  policyTypes: [Ingress]
EOF

# the cut: the plugin needs a moment to program the policy. A failed request counts as a cut only when the client pod itself still answers an exec.
tries=$(( WAIT / (NAP > 0 ? NAP : 1) )); [ "$tries" -ge 1 ] || tries=1
cut=0
for _ in $(seq 1 "$tries"); do
  if [ "$(fetch)" != ok ]; then
    "${K[@]}" exec -n "$NS" oa-netpol-probe-client -- true >/dev/null 2>&1 || inconclusive "a request failed but the client pod does not answer an exec, so the failure is not a block"
    cut=1; break
  fi
  sleep "$NAP"
done

if [ "$cut" = 1 ]; then
  printf '%s\n' "NetworkPolicy check: PASS. A pod in $NS was cut off from a server pod by a deny-all ingress policy, so this cluster's network plugin enforces ingress NetworkPolicy between pods." "$NOTE"
  exit 0
fi
verdict 1 "NetworkPolicy check: FAIL. After a deny-all ingress policy was applied, a pod in $NS still reached the server pod for ${WAIT}s." \
  "The network plugin of this cluster does not enforce NetworkPolicy (kind's default plugin does not, for example). The policies of OpenAgentix are applied and listed, but they cut nothing here:" \
  "the isolation claims of OpenAgentix (tool servers, records endpoints, agent egress) do NOT hold on this cluster. Use a cluster with a network plugin that enforces NetworkPolicy (Calico, Cilium) for any use that depends on them." "$NOTE"
