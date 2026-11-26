#!/usr/bin/env bash
# Offline tests of hack/gateway-service-type.sh (issue #165, ADR 0023): the model gateway Service type the installer
# sets on a remote cluster, and the warning about LoadBalancer Services. No cluster, no kubectl: JSON fixtures.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
# shellcheck source=hack/gateway-service-type.sh
. hack/gateway-service-type.sh

GW='{"kind":"Gateway","metadata":{"name":"model-gateway","namespace":"agentgateway-system"},"spec":{"gatewayClassName":"agentgateway"}}'
GWP='{"kind":"Gateway","metadata":{"name":"model-gateway","namespace":"agentgateway-system"},"spec":{"infrastructure":{"parametersRef":{"group":"agentgateway.dev","kind":"AgentgatewayParameters","name":"model-gateway-parameters"}}}}'
OTHER='{"kind":"Service","metadata":{"name":"x"}}'
# the installer's RENDERED is one JSON document per line (yq -c)
R_EMPTY=$(printf '%s\n%s\n' "$OTHER" "$GW")
R_SET=$(printf '%s\n%s\n' "$OTHER" "$GWP")
R_OFF=$OTHER

echo "# the value the installer adds"
t "remote, value empty: ClusterIP" "$(gw_service_type_set_value 1 "$R_EMPTY")" ClusterIP
t "remote, a values file already sets a type (ClusterIP or LoadBalancer): nothing" "$(gw_service_type_set_value 1 "$R_SET")" ""
t "kind or k3d (not remote): nothing, even when empty" "$(gw_service_type_set_value 0 "$R_EMPTY")" ""
t "remote, no Gateway rendered (gateway.enabled=false): nothing" "$(gw_service_type_set_value 1 "$R_OFF")" ""
t "remote, empty render: nothing" "$(gw_service_type_set_value 1 "")" ""

echo "# the warning about LoadBalancer Services"
SVCS='{"items":[
 {"metadata":{"namespace":"agentgateway-system","name":"model-gateway"},"spec":{"type":"LoadBalancer"}},
 {"metadata":{"namespace":"kube-system","name":"kube-dns"},"spec":{"type":"ClusterIP"}},
 {"metadata":{"namespace":"web","name":"front"},"spec":{"type":"LoadBalancer"}},
 {"metadata":{"namespace":"web","name":"np"},"spec":{"type":"NodePort"}}]}'
OUT=$(gw_loadbalancer_warnings "$SVCS" gke_p_z_c)
t "one WARN line per LoadBalancer Service" "$(grep -c '^WARNING: Service ' <<<"$OUT")" 2
t "it names namespace and name" "$(grep -c 'agentgateway-system/model-gateway' <<<"$OUT")/$(grep -c 'web/front' <<<"$OUT")" 1/1
t "it names the command that shows the address" "$(grep -c "kubectl --context gke_p_z_c get svc -n web front -o wide" <<<"$OUT")" 1
t "ClusterIP and NodePort Services are not listed" "$(grep -c 'kube-dns\|web/np' <<<"$OUT")" 0
t "no LoadBalancer: no output" "$(gw_loadbalancer_warnings '{"items":[{"metadata":{"namespace":"a","name":"b"},"spec":{"type":"ClusterIP"}}]}' c)" ""
t "empty input: no output, no error" "$(gw_loadbalancer_warnings '' c; echo "rc=$?")" "rc=0"
t "garbage input: no output, no error" "$(gw_loadbalancer_warnings 'not json' c 2>/dev/null; echo "rc=$?")" "rc=0"
exit $F
