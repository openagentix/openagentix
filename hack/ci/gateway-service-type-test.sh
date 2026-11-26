#!/usr/bin/env bash
# Offline tests of hack/gateway-service-type.sh (issue #165, ADR 0023): the check after a remote install for Services that open
# the cluster to the network (LoadBalancer, NodePort). A fake kubectl on PATH stands in for the cluster; nothing real is touched.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
# shellcheck source=hack/gateway-service-type.sh
. hack/gateway-service-type.sh
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
# the fake: records its arguments, answers `get svc -A -o json` from $FAKE_SVCS, fails when FAKE_FAIL=1
cat > "$TMP/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE_CALLS"
[ "${FAKE_FAIL:-0}" != 1 ] || { echo "Unable to connect to the server" >&2; exit 1; }
[ "$*" = "--context gke_p_z_c get svc -A -o json" ] && { printf '%s' "$FAKE_SVCS"; exit 0; }
echo "unexpected: $*" >&2; exit 2
FAKE
chmod +x "$TMP/bin/kubectl"
export FAKE_CALLS="$TMP/calls" PATH="$TMP/bin:$PATH"
: > "$FAKE_CALLS"
SVCS='{"items":[
 {"metadata":{"namespace":"agentgateway-system","name":"model-gateway"},"spec":{"type":"LoadBalancer"}},
 {"metadata":{"namespace":"kube-system","name":"kube-dns"},"spec":{"type":"ClusterIP"}},
 {"metadata":{"namespace":"web","name":"np"},"spec":{"type":"NodePort"}}]}'

echo "# the check reads the cluster and warns"
OUT=$(FAKE_SVCS="$SVCS" gw_exposure_check kubectl gke_p_z_c 2>&1)
t "one WARNING per LoadBalancer or NodePort Service" "$(grep -c '^WARNING: Service ' <<<"$OUT")" 2
t "the LoadBalancer one names namespace, name, type and the command for its address" "$(grep -c 'agentgateway-system/model-gateway is of type LoadBalancer.*kubectl --context gke_p_z_c get svc -n agentgateway-system model-gateway -o wide' <<<"$OUT")" 1
t "the NodePort one is named too" "$(grep -c 'web/np is of type NodePort' <<<"$OUT")" 1
t "ClusterIP is not listed" "$(grep -c kube-dns <<<"$OUT")" 0
t "the only call was a read: get svc -A -o json on the context" "$(cat "$FAKE_CALLS")" "kubectl --context gke_p_z_c get svc -A -o json"
echo "# nothing exposed"
OUT=$(FAKE_SVCS='{"items":[{"metadata":{"namespace":"a","name":"b"},"spec":{"type":"ClusterIP"}}]}' gw_exposure_check kubectl gke_p_z_c 2>&1)
t "no LoadBalancer or NodePort: says so, no WARNING" "$(grep -c '^WARNING' <<<"$OUT")/$(grep -c 'no Service of type LoadBalancer or NodePort' <<<"$OUT")" 0/1
echo "# the check cannot run"
OUT=$(FAKE_FAIL=1 gw_exposure_check kubectl gke_p_z_c 2>&1); RC=$?
t "kubectl fails: prints 'could not check for LoadBalancer Services'" "$(grep -c 'could not check for LoadBalancer Services' <<<"$OUT")" 1
t "and still returns 0 (it is a report, never a reason to fail)" "$RC" 0
OUT=$(FAKE_SVCS='not json' gw_exposure_check kubectl gke_p_z_c 2>&1)
t "unreadable answer: the same message" "$(grep -c 'could not check for LoadBalancer Services' <<<"$OUT")" 1
OUT=$(FAKE_SVCS='' gw_exposure_check kubectl gke_p_z_c 2>&1)
t "empty answer: the same message" "$(grep -c 'could not check for LoadBalancer Services' <<<"$OUT")" 1
exit $F
