#!/usr/bin/env bash
# Tests for uninstall.sh with fake `kubectl`, `helm`, `kind`, `k3d`, `docker` and `gcloud` (no cluster): which kube context it acts on,
# and that it removes nothing when that context is not the one named (issue #169).
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
# kubectl: contexts in FAKE_CONTEXTS (space separated); use-context records the current one unless FAKE_STUCK=1;
# `get --raw /version` answers when FAKE_API=up; reads return nothing; every call is recorded
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
case "\$*" in
  "config use-context "*) for c in \${FAKE_CONTEXTS:-}; do if [ "\$c" = "\$3" ]; then [ "\${FAKE_STUCK:-0}" = 1 ] || echo "\$3" > "$D/current"; exit 0; fi; done
                          echo "error: no context exists with the name: \"\$3\"" >&2; exit 1;;
  "config current-context") cat "$D/current" 2>/dev/null; exit 0;;
  *"get --raw /version"*) [ "\${FAKE_API:-}" = up ] || exit 1; echo '{}';;
  *" get "*) exit 1;;
esac
exit 0
EOS
cat > "$D/bin/helm" <<EOS
#!/usr/bin/env bash
echo "helm \$*" >> "$D/calls"
case "\$*" in *"get manifest"*) [ -z "\${FAKE_MANIFEST:-}" ] || cat "\$FAKE_MANIFEST"; exit 0;; esac
case "\$*" in *" status "*|"status "*) exit 1;; esac
exit 0
EOS
for c in kind k3d docker gcloud; do printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls"\nexit 0\n' "$c" "$D" > "$D/bin/$c"; done
chmod +x "$D/bin/"*
# u <VAR=value>...: uninstall.sh with only these variables (and the fakes first on PATH); prints its output and exit=<code>
u(){ : > "$D/calls"; echo "${FAKE_START:-elsewhere}" > "$D/current"; env -i PATH="$D/bin:$PATH" HOME="$HOME" "$@" bash uninstall.sh 2>&1; echo "exit=$?"; }
calls(){ cat "$D/calls"; }
R=gke_p_z_c

echo "# kind (the default): unchanged"
OUT=$(u FAKE_CONTEXTS="kind-openagentix $R")
t "kind: exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "kind: switches to kind-openagentix" "$(calls | grep -c '^kubectl config use-context kind-openagentix$')" 1
t "kind: every other kubectl call names kind-openagentix" "$(calls | grep '^kubectl ' | grep -v '^kubectl config ' | grep -vc -- '--context=kind-openagentix')" 0
t "kind: every helm call names kind-openagentix" "$(calls | grep '^helm ' | grep -vc -- '--kube-context kind-openagentix')" 0
OUT=$(u FAKE_CONTEXTS="k3d-openagentix" CLUSTER_TYPE=k3d)
t "k3d: switches to k3d-openagentix" "$(calls | grep -c '^kubectl config use-context k3d-openagentix$')" 1
t "nothing deletes a cluster (kind)" "$(u FAKE_CONTEXTS=kind-openagentix PURGE_SECRETS=1 PURGE_DATA=1 >/dev/null; calls | grep -cE '^(kind|k3d|gcloud|docker) ')" 0

echo "# remote: KUBE_CONTEXT is the context, and only that one"
OUT=$(u CLUSTER_TYPE=remote FAKE_CONTEXTS="kind-openagentix")
t "remote without KUBE_CONTEXT: refused" "$(grep -c 'CLUSTER_TYPE=remote needs KUBE_CONTEXT' <<<"$OUT")/$(grep -c '^exit=1$' <<<"$OUT")" 1/1
t "remote without KUBE_CONTEXT: no call at all" "$(calls)" ""
OUT=$(u CLUSTER_TYPE=remote KUBE_CONTEXT=kind-openagentix FAKE_CONTEXTS="kind-openagentix" FAKE_API=up)
t "remote with the local kind context: refused" "$(grep -c 'ALLOW_LOCAL_CONTEXT=1' <<<"$OUT")/$(grep -c '^exit=1$' <<<"$OUT")" 1/1
t "remote with the local kind context: no call at all" "$(calls)" ""
OUT=$(u CLUSTER_TYPE=remote KUBE_CONTEXT=$R FAKE_CONTEXTS="kind-openagentix" FAKE_API=up)
t "remote, context not in the kubeconfig: refused, nothing removed" "$(grep -c 'Nothing was removed' <<<"$OUT")/$(grep -c '^exit=1$' <<<"$OUT")" 1/1
t "remote, context not in the kubeconfig: no delete, no helm" "$(calls | grep -cE ' delete |^helm ')" 0
OUT=$(u CLUSTER_TYPE=remote KUBE_CONTEXT=$R FAKE_CONTEXTS="$R" FAKE_STUCK=1 FAKE_API=up)
t "the current context is not the one named after the switch: refused" "$(grep -c "current context is 'elsewhere', not '$R'" <<<"$OUT")/$(grep -c '^exit=1$' <<<"$OUT")" 1/1
t "... and nothing was deleted" "$(calls | grep -cE ' delete |^helm ')" 0
OUT=$(u CLUSTER_TYPE=remote KUBE_CONTEXT=$R FAKE_CONTEXTS="$R")
t "remote, API server not reachable: refused, nothing removed" "$(grep -c "cannot reach the API server of kube context '$R'" <<<"$OUT")/$(calls | grep -cE ' delete |^helm ')" 1/0
OUT=$(u CLUSTER_TYPE=remote KUBE_CONTEXT=$R FAKE_CONTEXTS="kind-openagentix $R" FAKE_API=up PURGE_SECRETS=1 PURGE_DATA=1)
t "remote: exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "remote: switches to KUBE_CONTEXT" "$(calls | grep -c "^kubectl config use-context $R\$")" 1
t "remote: never names the kind context" "$(calls | grep -c 'kind-openagentix')" 0
t "remote: every other kubectl call names KUBE_CONTEXT" "$(calls | grep '^kubectl ' | grep -v '^kubectl config ' | grep -vc -- "--context=$R\|--context $R")" 0
t "remote: the deletes happen, on KUBE_CONTEXT" "$(calls | grep '^kubectl ' | grep ' delete ' | grep -c -e "--context=$R" -e "--context $R")" "$(calls | grep '^kubectl ' | grep -c ' delete ')"
t "remote: at least one delete was attempted" "$(calls | grep '^kubectl ' | grep -c ' delete ' | awk '{print ($1>0)?"yes":"no"}')" yes
t "remote: every helm call names KUBE_CONTEXT" "$(calls | grep '^helm ' | grep -vc -- "--kube-context $R")" 0
t "remote: no cluster delete is attempted (no kind, k3d, docker, gcloud)" "$(calls | grep -cE '^(kind|k3d|docker|gcloud) ')" 0
t "remote: removes the opt-in node-settings namespace (privileged DaemonSet) on that context" "$(calls | grep -c "^kubectl --context=$R delete namespace openagentix-node-settings --ignore-not-found")" 1
t "remote: prints the cloud teardown reminder" "$(grep -c 'load balancers and disks' <<<"$OUT")" 1
echo "# diagnostics (cluster-read, ADR 0025): the two bearer Secrets go with PURGE_SECRETS=1 only"
cat > "$D/manifest.yaml" <<'YAML'
---
apiVersion: toolhive.stacklok.dev/v1beta1
kind: MCPServerEntry
metadata: {name: cluster-read, namespace: mcp-tools}
spec:
  groupRef: {name: diagnostics}
  headerForward:
    addHeadersFromSecret:
      - {headerName: Authorization, valueSecretRef: {name: diagnostics-bearer-cluster-read, key: authorization}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: cluster-read, namespace: openagentix-diagnostics}
spec:
  template:
    spec:
      volumes:
        - {name: bearer, secret: {secretName: cluster-read-bearer}}
YAML
OUT=$(u FAKE_CONTEXTS="kind-openagentix" FAKE_MANIFEST="$D/manifest.yaml")
t "no purge: no Secret is deleted" "$(calls | grep -c ' delete secret ')" 0
OUT=$(u FAKE_CONTEXTS="kind-openagentix" FAKE_MANIFEST="$D/manifest.yaml" PURGE_SECRETS=1)
t "PURGE_SECRETS=1: the entry's header Secret in the tools namespace is deleted" "$(calls | grep -c 'delete secret -n mcp-tools diagnostics-bearer-cluster-read --ignore-not-found')" 1
t "PURGE_SECRETS=1: the server's own Secret is deleted" "$(calls | grep -c 'delete secret -n openagentix-diagnostics cluster-read-bearer --ignore-not-found')" 1
t "the namespace openagentix-diagnostics is not deleted" "$(calls | grep -c 'delete namespace openagentix-diagnostics')" 0
exit $F
