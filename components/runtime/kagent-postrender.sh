#!/usr/bin/env bash
# Helm post-renderer for the kagent release (kagent-helm.sh passes it on every install and upgrade). Issue #178.
#
# kagent 1.0.1 dials the Substrate API (api.ate-system.svc:443) once at start-up with a fixed 10 s deadline (substrate.Dial in
# go/core/internal/substrate/client.go; app.go sets no DialTimeout and the controller config has no field for it) and exits when
# the API does not answer. After a node restart the Substrate API is often not serving for one to three minutes (its pod waits for
# a pod certificate), so the controller exited and crash-looped, and the back-off added about 100 s to the recovery.
# The kagent chart has no value for init containers, so this adds one to the kagent-controller Deployment: it waits until the
# API Service has a ready endpoint (a TCP connect succeeds), then the controller starts and its 10 s dial succeeds.
# It changes nothing else. It fails when the Deployment is not in the render, so a renamed object cannot drop the wait silently.
# Reads the rendered manifests on standard input, writes them to standard output. Needs kubectl (kustomize is built in).
set -euo pipefail
K=${KUBECTL:-kubectl}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/rendered.yaml"
# The image is the one the install already pulls for the Substrate PostgreSQL (manifests/substrate-postgres), so nothing new is
# pulled; its busybox nc has -z and -w. The deadline is a little longer than the recovery budget; after it the init container exits
# 1, so the pod shows Init:Error and restarts instead of hanging without a sign. Backticks, not $(...): Kubernetes expands $(NAME).
cat > "$T/wait-for-ate-api.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kagent-controller
spec:
  template:
    spec:
      initContainers:
        - name: wait-for-ate-api
          image: postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
          command:
            - /bin/sh
            - -c
            - >-
              end=$((`date +%s` + 660));
              until nc -z -w 2 api.ate-system.svc 443; do
              if [ `date +%s` -ge $end ]; then echo "Substrate API api.ate-system.svc:443 not reachable after 660 s" >&2; exit 1; fi;
              sleep 2; done;
              echo "Substrate API api.ate-system.svc:443 is reachable"
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            runAsGroup: 65532
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: {drop: [ALL]}
          resources:
            requests: {cpu: 5m, memory: 8Mi}
            limits: {cpu: 50m, memory: 32Mi}
EOF
cat > "$T/kustomization.yaml" <<'EOF'
resources: [rendered.yaml]
patches:
  - path: wait-for-ate-api.yaml
    target: {group: apps, version: v1, kind: Deployment, name: kagent-controller}
EOF
OUT=$($K kustomize "$T")
grep -q 'name: wait-for-ate-api' <<<"$OUT" || { echo "kagent-postrender: Deployment kagent-controller is not in the kagent render; the wait for the Substrate API was not added" >&2; exit 1; }
printf '%s\n' "$OUT"
