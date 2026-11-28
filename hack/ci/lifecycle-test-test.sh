#!/usr/bin/env bash
# Offline tests for hack/ci/lifecycle-test.sh with a fake `kubectl` and `helm` and fake install, uninstall and smoke commands (no cluster).
# A "world" file lists the objects the fake cluster holds (kind.group, namespace, name, uid); the fake install and uninstall commands change it.
# Each scenario runs the real script and checks its exit code and what it says: the passing run, and one failing run for every kind of harm it must see.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"; T=$(printf '\t')
cat > "$D/manifest.yaml" <<'EOS'
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: control-plane, namespace: openagentix-system}
---
apiVersion: v1
kind: Service
metadata: {name: control-plane, namespace: openagentix-system}
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: agentdefinitions.openagentix.io, annotations: {"helm.sh/resource-policy": keep}}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: llm-api-keys-control-plane, namespace: agentgateway-system, annotations: {"helm.sh/resource-policy": keep}}
EOS
# the world after an install: one object per line
printf '%s\n' \
  "Deployment.apps${T}openagentix-system${T}control-plane${T}uid-d1" "Service${T}openagentix-system${T}control-plane${T}uid-s1" \
  "CustomResourceDefinition.apiextensions.k8s.io${T}-${T}agentdefinitions.openagentix.io${T}uid-c1" "ConfigMap${T}agentgateway-system${T}llm-api-keys-control-plane${T}uid-m1" \
  "AgentDefinition.openagentix.io${T}kagent${T}quickstart${T}uid-a1" "Agent.kagent.dev${T}kagent${T}quickstart${T}uid-a2" > "$D/world.full"
cat > "$D/bin/helm" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *"get manifest"*) [ -f "$D/released" ] && cat "$D/manifest.yaml"; exit 0;;
  *" status "*|"status "*) [ -f "$D/released" ] || exit 1; echo '{"version":1,"info":{"status":"deployed"}}';;
esac
EOS
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
a="\$*"
items(){ jq -Rn --arg kg "\$1" '[inputs|split("\t")|select(.[0]==\$kg)|{kind:(.[0]|split(".")[0]),metadata:{namespace:(if .[1]=="-" then null else .[1] end),name:.[2],uid:.[3]}}]|{items:.}' < "$D/world"; }
case "\$a" in
  "get agentdefinitions.openagentix.io,agents.api.kagent.dev -A -o json") jq -Rn '[inputs|split("\t")|select(.[0]|split(".")[0]|IN("AgentDefinition","Agent"))|{kind:(.[0]|split(".")[0]),metadata:{namespace:.[1],name:.[2],uid:.[3]}}]|{items:.}' < "$D/world";;
  "get deployments,statefulsets,daemonsets,cronjobs,services -A -o json") jq -Rn '[inputs|split("\t")|select(.[0]|split(".")[0]|IN("Deployment","Service"))|{kind:(.[0]|split(".")[0]),metadata:{namespace:.[1],name:.[2]}}]|{items:.}' < "$D/world";;
  "get secrets -A -o json") cat "$D/secrets.json";;
  "get pods -A -o json") cat "$D/pods.json";;
  "get pvc -A -o json") cat "$D/pvc.json";;
  "get pvc -A -o name") jq -r '.items[]|"persistentvolumeclaim/"+.metadata.name' "$D/pvc.json";;
  "get "*" -A -o json") items "\$2";;
esac
exit 0
EOS
# fake steps: install (counted in $D/n), uninstall, smoke. FAKE=<scenario> changes what they do
cat > "$D/install" <<EOS
#!/usr/bin/env bash
n=\$(( \$(cat "$D/n" 2>/dev/null || echo 0) + 1 )); echo \$n > "$D/n"
[ "\${FAKE:-}" = install-fails ] && [ \$n = 2 ] && { echo "boom: helm upgrade failed"; exit 1; }
touch "$D/released"; cp "$D/world.full" "$D/world"
[ "\${FAKE:-}" = uid-changes ] && [ \$n = 2 ] && sed -i.bak 's/uid-d1/uid-d2/' "$D/world"
[ "\${FAKE:-}" = extra-object ] && [ \$n = 2 ] && printf 'Service\topenagentix-system\tcontrol-plane-2\tuid-x\n' >> "$D/world"
[ "\${FAKE:-}" = agent-recreated ] && [ \$n = 2 ] && sed -i.bak 's/uid-a2/uid-a9/' "$D/world"
[ "\${FAKE:-}" = secret-rotated ] && [ \$n = 3 ] && cp "$D/secrets2.json" "$D/secrets.json"
[ "\${FAKE:-}" = crashloop ] && [ \$n = 2 ] && cp "$D/pods-bad.json" "$D/pods.json"
exit 0
EOS
cat > "$D/uninstall" <<EOS
#!/usr/bin/env bash
rm -f "$D/released"
grep -E '^(CustomResourceDefinition|ConfigMap)' "$D/world" > "$D/w2"; mv "$D/w2" "$D/world"
[ "\${FAKE:-}" = leftover ] && printf 'Deployment.apps\topenagentix-system\tcontrol-plane\tuid-d1\n' >> "$D/world"
[ "\${FAKE:-}" = agent-left ] && printf 'AgentDefinition.openagentix.io\tkagent\tquickstart\tuid-a1\n' >> "$D/world"
[ "\${FAKE:-}" = pvc-left ] && cp "$D/pvc-bad.json" "$D/pvc.json"
exit 0
EOS
printf '#!/usr/bin/env bash\nexit 0\n' > "$D/smoke"
chmod +x "$D/bin/"* "$D/install" "$D/uninstall" "$D/smoke"
# a quiet cluster: Secrets, healthy pods, one allowed PVC
cat > "$D/secrets-ok.json" <<'EOS'
{"items":[{"metadata":{"namespace":"openagentix-system","name":"console-token"},"type":"Opaque","data":{"token":"c2VjcmV0"}},
{"metadata":{"namespace":"openagentix-system","name":"sh.helm.release.v1.openagentix.v1"},"type":"helm.sh/release.v1","data":{"release":"eA=="}}]}
EOS
sed 's/c2VjcmV0/b3RoZXI=/' "$D/secrets-ok.json" > "$D/secrets2.json"
cat > "$D/pods-ok.json" <<'EOS'
{"items":[{"metadata":{"namespace":"openagentix-system","name":"control-plane-1"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}],"containerStatuses":[{"state":{"running":{}}}]}},
{"metadata":{"namespace":"kube-system","name":"unrelated"},"status":{"phase":"Pending","conditions":[{"type":"Ready","status":"False"}]}}]}
EOS
cat > "$D/pods-bad.json" <<'EOS'
{"items":[{"metadata":{"namespace":"openagentix-system","name":"control-plane-1"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False"}],"containerStatuses":[{"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}
EOS
echo '{"items":[{"metadata":{"namespace":"openagentix-observability","name":"victoria-metrics"}}]}' > "$D/pvc-ok.json"
echo '{"items":[{"metadata":{"namespace":"openagentix-knowledge","name":"mystery-volume"}}]}' > "$D/pvc-bad.json"

# L <scenario>: runs the script against the fakes; prints its output, then exit=<code>
L(){ rm -f "$D/n" "$D/released"; : > "$D/world"; cp "$D/pvc-ok.json" "$D/pvc.json"; cp "$D/secrets-ok.json" "$D/secrets.json"; cp "$D/pods-ok.json" "$D/pods.json"
  FAKE=$1 PATH="$D/bin:$PATH" KUBECTL="$D/bin/kubectl" HELM="$D/bin/helm" LIFECYCLE_INSTALL="$D/install" LIFECYCLE_UNINSTALL="$D/uninstall" LIFECYCLE_SMOKE="$D/smoke" HEALTH_WAIT=1 \
    bash hack/ci/lifecycle-test.sh 2>&1; echo "exit=$?"; }
n(){ grep -c -- "$1" <<<"$OUT"; }

echo "# the passing run"
OUT=$(L none)
t "exit 0" "$(n '^exit=0$')" 1
t "reports no failure" "$(n '^FAIL')" 0
t "same UIDs after the second install" "$(n 'ok    same objects, same UIDs')" 1
t "keep-policy objects are named" "$(n 'kept on purpose.*CustomResourceDefinition')" 1
t "reinstall checked" "$(n 'ok    smoke after the reinstall')" 1
t "no Secret value is printed" "$(n -e c2VjcmV0 -e b3RoZXI)" 0

echo "# each kind of harm is seen"
OUT=$(L uid-changes);      t "an object recreated by the second install fails" "$(n '^FAIL  same objects, same UIDs')/$(n '^exit=1$')" 1/1
OUT=$(L agent-recreated);  t "an agent rebuilt by the second install fails" "$(n '^FAIL  same AgentDefinitions and Agents')/$(n '^exit=1$')" 1/1
OUT=$(L extra-object);     t "a new object after the second install fails" "$(n '^FAIL  same workloads and Services by name')/$(n '^exit=1$')" 1/1
OUT=$(L install-fails);    t "a failing second install fails and stops" "$(n '^FAIL  install (second, same values) failed')/$(n 'boom: helm upgrade failed')/$(n '^exit=1$')" 1/1/1
t "... and the uninstall never ran" "$(n '^=== uninstall')" 0
OUT=$(L crashloop);        t "a pod in CrashLoopBackOff fails" "$(n '^FAIL  after the second install: unhealthy pods')/$(n '^exit=1$')" 1/1
OUT=$(L leftover);         t "a release object left by uninstall fails" "$(n '^FAIL  objects of the release left after uninstall')/$(n 'Deployment.apps/openagentix-system/control-plane')/$(n '^exit=1$')" 1/1/1
OUT=$(L agent-left);       t "an AgentDefinition left by uninstall fails" "$(n '^FAIL  no AgentDefinition and no kagent Agent is left')/$(n '^exit=1$')" 1/1
OUT=$(L pvc-left);         t "an undocumented PVC fails" "$(n 'mystery-volume')/$(n '^exit=1$')" 1/1
OUT=$(L secret-rotated);   t "a Secret that changes across uninstall and reinstall fails" "$(n 'Secrets whose content changed')/$(n '^exit=1$')" 1/1

echo "# the script never reaches a real cluster by accident (it installs and uninstalls): hermetic, with recording fakes and an empty kubeconfig"
mkdir -p "$D/real"
for c in helm kubectl install; do
  cat > "$D/real/$c" <<EOS
#!/usr/bin/env bash
if [ "$c" = kubectl ] && [ "\$1 \$2" = "config current-context" ]; then echo "\${FAKE_CTX:-kind-openagentix}"; echo "$c \$*" >> "$D/real/calls.ok"; exit 0; fi
echo "$c \$*" >> "$D/real/calls.REAL"; exit 1
EOS
  chmod +x "$D/real/$c"
done
G(){ rm -f "$D/real/calls.REAL" "$D/real/calls.ok"; env -u KUBECTL -u HELM -u GITHUB_ACTIONS KUBECONFIG="$D/empty-kubeconfig" HELM_KUBECONTEXT=none-such PATH="$D/real:$PATH" LIFECYCLE_INSTALL="$D/real/install" "$@" bash hack/ci/lifecycle-test.sh 2>&1; echo "exit=$?"; }
: > "$D/empty-kubeconfig"
OUT=$(G FAKE_CTX=kind-openagentix); t "a local run on the context kind-openagentix is refused (exit 2), naming the way to allow it" "$(n '^exit=2$')/$(n 'LIFECYCLE_CI_CONTEXT does not name this context')" 1/1
t "... and no helm, kubectl (apart from reading the context name) or install command was run" "$(cat "$D/real/calls.REAL" 2>/dev/null | wc -l | tr -d ' ')/$(cat "$D/real/calls.ok" | wc -l | tr -d ' ')" 0/1
OUT=$(G FAKE_CTX=gke_prod_cluster LIFECYCLE_CI_CONTEXT=gke_prod_cluster); t "a context that is not kind or k3d is refused even when named" "$(n '^exit=2$')/$(n 'not a kind or k3d context')" 1/1
t "... with no cluster call" "$(cat "$D/real/calls.REAL" 2>/dev/null | wc -l | tr -d ' ')" 0
OUT=$(G FAKE_CTX=kind-ci LIFECYCLE_CI_CONTEXT=kind-ci); t "a kind context named by LIFECYCLE_CI_CONTEXT passes the guard (the fake install then fails, exit 1, not 2)" "$(n '^exit=1$')/$(n 'refusing')" 1/0
OUT=$(G FAKE_CTX=kind-openagentix GITHUB_ACTIONS=true); t "on GitHub Actions the guard does not apply (the fake install fails, exit 1)" "$(n '^exit=1$')/$(n 'refusing')" 1/0
exit $F
