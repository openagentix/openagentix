#!/usr/bin/env bash
# CI ONLY. Sets up the two tiny MCP endpoints of the live check of mcp.endpoints (ADR 0026, slice 2) BEFORE the platform install, as ADR 0026 says: the endpoint's
# own namespace and workload first, the platform values second.
#   kind create cluster --name openagentix --config hack/kind-config.yaml
#   ENDPOINTS=1 hack/ci/endpoints-ci-setup.sh
#   PROFILE=quickstart VALUES_FILE=hack/ci/endpoints-ci-values.yaml ./install.sh
#   ENDPOINTS=1 hack/ci/endpoints-live.sh
# It makes the namespace endpoint-ci with two Deployments (echo and other, both hack/ci/endpoints-ci/echo-mcp.py from a ConfigMap), their Services, and for each
# one two Secrets with the same random header value: <name>-mcp-auth in the tools namespace (the chart's entry names it) and <name>-expected in endpoint-ci (the
# server reads it as a file). The values are made with openssl, never printed, never an argument. Like diagnostics-live.sh it refuses to run anywhere but a kind
# or k3d CI cluster: on GitHub Actions, or when ENDPOINTS_CI_CONTEXT names the current context exactly.
set -u
[ "${ENDPOINTS:-0}" = 1 ] || { echo "endpoints-ci-setup: set ENDPOINTS=1 to run this against the current cluster (it is opt-in)"; exit 0; }
K=${KUBECTL:-kubectl}
CTX_NOW=$($K config current-context 2>/dev/null || true)
case "$CTX_NOW" in
  kind-*|k3d-*) ;;
  *) echo "endpoints-ci-setup: refusing to run: the current kube context is '${CTX_NOW:-none}', not a kind or k3d context. Nothing was changed." >&2; exit 2;;
esac
if [ "${GITHUB_ACTIONS:-}" != true ] && [ "${ENDPOINTS_CI_CONTEXT:-}" != "$CTX_NOW" ]; then
  echo "endpoints-ci-setup: refusing to run on '$CTX_NOW': it is not a CI run (GITHUB_ACTIONS is not true) and ENDPOINTS_CI_CONTEXT does not name this context. Nothing was changed." >&2
  exit 2
fi
cd "$(dirname "$0")/../.." || exit 1
NS=endpoint-ci; MCPNS=${MCP_NAMESPACE:-mcp-tools}
for n in "$NS" "$MCPNS"; do $K get namespace "$n" >/dev/null 2>&1 || $K create namespace "$n" >/dev/null || exit 1; done
$K label namespace "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
$K create configmap echo-mcp-src -n "$NS" --from-file=echo-mcp.py=hack/ci/endpoints-ci/echo-mcp.py --dry-run=client -o yaml | $K apply -f - >/dev/null || exit 1

# one random header value per server, in two Secrets; created only when absent, so a re-run changes nothing
put_pair() {   # put_pair <name>
  local name=$1 v
  if $K get secret "$name-expected" -n "$NS" >/dev/null 2>&1 && $K get secret "$name-mcp-auth" -n "$MCPNS" >/dev/null 2>&1; then echo "secrets of $name: kept"; return 0; fi
  v="Bearer $(openssl rand -hex 24)" || return 1
  $K create secret generic "$name-expected" -n "$NS" --from-file=expected=<(printf '%s' "$v") --dry-run=client -o yaml | $K apply -f - >/dev/null || return 1
  $K create secret generic "$name-mcp-auth" -n "$MCPNS" --from-file=value=<(printf '%s' "$v") --dry-run=client -o yaml | $K apply -f - >/dev/null || return 1
  unset v
  echo "secrets of $name: created (values not shown)"
}
put_pair echo || exit 1
put_pair other || exit 1

for name in echo other; do
  $K apply -f - <<YAML >/dev/null || exit 1
apiVersion: apps/v1
kind: Deployment
metadata: {name: $name, namespace: $NS, labels: {app: $name}}
spec:
  replicas: 1
  selector: {matchLabels: {app: $name}}
  template:
    metadata: {labels: {app: $name}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65532, runAsGroup: 65532, fsGroup: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: echo
          image: python:3.12.7-slim
          command: ["python3", "-I", "/app/echo-mcp.py"]
          env:
            - {name: ECHO_NAME, value: $name}
            - {name: ECHO_EXPECTED_FILE, value: /etc/echo/auth/expected}
            - {name: PYTHONDONTWRITEBYTECODE, value: "1"}
          ports: [{name: http, containerPort: 8080}]
          readinessProbe: {httpGet: {path: /readyz, port: http}, periodSeconds: 3}
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          resources: {requests: {cpu: 10m, memory: 24Mi}, limits: {cpu: 200m, memory: 96Mi}}
          volumeMounts:
            - {name: src, mountPath: /app, readOnly: true}
            - {name: auth, mountPath: /etc/echo/auth, readOnly: true}
      volumes:
        - {name: src, configMap: {name: echo-mcp-src}}
        - {name: auth, secret: {secretName: $name-expected, defaultMode: 0440}}
---
apiVersion: v1
kind: Service
metadata: {name: $name, namespace: $NS, labels: {app: $name}}
spec:
  selector: {app: $name}
  ports: [{name: http, port: 8080, targetPort: http}]
YAML
done
for name in echo other; do
  $K rollout status "deployment/$name" -n "$NS" --timeout=180s || { echo "endpoints-ci-setup: $name did not become Ready"; $K describe pod -n "$NS" -l "app=$name" | tail -20; $K logs -n "$NS" "deploy/$name" --tail=30 2>&1 | cut -c1-200; exit 1; }
done
echo "endpoints-ci-setup: the endpoints echo and other are Ready in $NS"
