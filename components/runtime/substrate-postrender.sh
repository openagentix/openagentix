#!/usr/bin/env bash
# Helm post-renderer for the substrate release (substrate-helm.sh passes it on every install and upgrade). Issue #203.
#
# The Substrate API server (ate-api-server) connects to its PostgreSQL, postgres.ate-system.svc, when it starts, tries 30 times at 2 s (60 s in all, fixed in the
# binary) and then exits. That Service is headless (components/runtime/manifests/substrate-postgres), so its name has no DNS record until postgres-0 is Ready.
# After a node restart both pods wait for a pod certificate before their projected volumes can be mounted (the kubelet retries the mount with a growing delay), and
# postgres-0 is often Ready a minute or more after the API server has started. The API server then logs "lookup postgres.ate-system.svc ... no such host" 30 times,
# exits, and its restart count rises a second time (the recovery test allows one restart per container, the node restart itself). On a laptop VM that is restarted
# often the count keeps rising.
# The substrate chart has no value for init containers on this Deployment (it only has its own), so this adds one: it waits until the name resolves and a TCP
# connect to the port succeeds, then the API server starts and its own 60 s are enough. It changes nothing else. It fails when the Deployment is not in the render,
# so a renamed object cannot drop the wait silently. Reads the rendered manifests on standard input, writes them to standard output. Needs kubectl (kustomize is built in).
set -euo pipefail
K=${KUBECTL:-kubectl}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/rendered.yaml"
# The image is the one the install already pulls for the Substrate PostgreSQL, so nothing new is pulled; its busybox nc has -z and -w. The deadline is longer than
# the recovery budget; after it the init container exits 1, so the pod shows Init:Error and restarts instead of hanging without a sign. Backticks, not $(...):
# Kubernetes expands $(NAME).
cat > "$T/wait-for-postgres.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ate-api-server
spec:
  template:
    spec:
      initContainers:
        - name: wait-for-postgres
          image: postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15
          command:
            - /bin/sh
            - -c
            - >-
              end=$((`date +%s` + 660));
              until nc -z -w 2 postgres.ate-system.svc 5432; do
              if [ `date +%s` -ge $end ]; then echo "PostgreSQL postgres.ate-system.svc:5432 not reachable after 660 s" >&2; exit 1; fi;
              sleep 2; done;
              echo "PostgreSQL postgres.ate-system.svc:5432 is reachable"
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
  - path: wait-for-postgres.yaml
    target: {group: apps, version: v1, kind: Deployment, name: ate-api-server}
EOF
OUT=$($K kustomize "$T")
grep -q 'name: wait-for-postgres' <<<"$OUT" || { echo "substrate-postrender: Deployment ate-api-server is not in the substrate render; the wait for PostgreSQL was not added" >&2; exit 1; }
printf '%s\n' "$OUT"
