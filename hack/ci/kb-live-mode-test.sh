#!/usr/bin/env bash
# Tests for kb_live_mode of hack/kb-callers.sh (ADR 0030, section 6) with a fake `helm` and a fake `kubectl` (no cluster): the guard against turning enforce off must read the mode of
# the LIVE release, where the live release keeps it, and must stop when it cannot tell. Only "release: not found" and a NotFound ConfigMap mean "no mode".
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
# helm get values: HELM_MODE=notfound | fail | json <namespace of the knowledge base in the live release>
cat > "$D/bin/helm" <<'EOS'
#!/usr/bin/env bash
echo "helm $*" >> "$CALLS"
case "${HELM_MODE:-json}" in
  notfound) echo "Error: release: not found" >&2; exit 1;;
  fail) echo "Error: Kubernetes cluster unreachable: dial tcp: i/o timeout" >&2; exit 1;;
  *) printf '{"knowledge":{"namespace":"%s","enabled":true}}' "${LIVE_KNS:-live-knowledge}"; exit 0;;
esac
EOS
# kubectl get configmap kb-access: the ConfigMap exists only in LIVE_KNS, with the mode LIVE_MODE; KUBECTL_MODE=forbidden | timeout makes the read fail
cat > "$D/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "kubectl $*" >> "$CALLS"
case "${KUBECTL_MODE:-ok}" in
  forbidden) echo 'Error from server (Forbidden): configmaps "kb-access" is forbidden: User "x" cannot get resource "configmaps" in API group "" in the namespace "live-knowledge"' >&2; exit 1;;
  timeout) echo 'Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)' >&2; exit 1;;
esac
ns=""; prev=""; for a in "$@"; do [ "$prev" = -n ] && ns=$a; prev=$a; done
if [ "$ns" = "${LIVE_KNS:-live-knowledge}" ] && [ -n "${LIVE_MODE:-}" ]; then printf '{"mode":"%s","callers":[]}' "$LIVE_MODE"; exit 0; fi
echo "Error from server (NotFound): configmaps \"kb-access\" not found" >&2; exit 1
EOS
chmod +x "$D/bin/"*
live() { : > "$D/calls"; CALLS="$D/calls" PATH="$D/bin:$PATH" bash -c '. hack/kb-callers.sh; out=$(kb_live_mode helm openagentix openagentix-system ctx1 kubectl); rc=$?; echo "mode=[$out] rc=$rc"' 2>&1; }

echo "# the live release enforces, and keeps the knowledge base in a namespace that this run does not name"
t "the mode is read where the live release keeps the ConfigMap" "$(LIVE_MODE=enforce live | tail -1)" "mode=[enforce] rc=0"
t "the namespace comes from the release (helm get values -a), with the context of the run" "$(LIVE_MODE=enforce live >/dev/null; /usr/bin/grep -c 'get values openagentix -n openagentix-system --kube-context ctx1 -a -o json' "$D/calls")/$(/usr/bin/grep -c -- '-n live-knowledge' "$D/calls")" 1/1
t "report is read as report" "$(LIVE_MODE=report live | tail -1)" "mode=[report] rc=0"

echo "# only a missing release or a missing ConfigMap means no mode"
t "no release: no mode, rc 0" "$(HELM_MODE=notfound live | tail -1)" "mode=[] rc=0"
t "a release without the ConfigMap: no mode, rc 0" "$(LIVE_MODE='' live | tail -1)" "mode=[] rc=0"

echo "# anything else is 'cannot tell', and the caller must stop"
OUT=$(KUBECTL_MODE=forbidden LIVE_MODE=enforce live)
t "Forbidden on the ConfigMap: rc 2, no mode printed" "$(tail -1 <<<"$OUT")" "mode=[] rc=2"
t "and it says why, with the sentence of the cluster and no value" "$(/usr/bin/grep -c 'cannot read the ConfigMap kb-access' <<<"$OUT")" 1
t "a timeout on the ConfigMap: rc 2" "$(KUBECTL_MODE=timeout LIVE_MODE=enforce live | tail -1)" "mode=[] rc=2"
t "helm cannot reach the cluster: rc 2" "$(HELM_MODE=fail live | tail -1)" "mode=[] rc=2"
printf '#!/usr/bin/env bash\necho "Error: release: not found extra" >&2; exit 1\n' > "$D/bin/helm"
t "a line that only looks like 'not found': rc 2" "$(live | tail -1)" "mode=[] rc=2"
printf '#!/usr/bin/env bash\nprintf "not json"\n' > "$D/bin/helm"
t "values that are not JSON: rc 2" "$(live | tail -1)" "mode=[] rc=2"

echo "# install.sh uses it, and stops"
t "install.sh calls kb_live_mode and stops when it cannot tell" "$(/usr/bin/grep -c 'kb_live_mode .*|| die' install.sh)" 1
t "the planned namespace of this run is not what it reads" "$(/usr/bin/grep -c 'get configmap kb-access -n "\$KB_PLAN_NS"' install.sh)" 0
exit "$F"
