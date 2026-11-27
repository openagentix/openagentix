#!/usr/bin/env bash
# Tests for hack/endpoints-check.sh and for the install checks of mcp.endpoints (ADR 0026, slice 2), with a fake `kubectl` and a fake `sleep` (no cluster):
# the installer fails when a vMCP of a group that holds an endpoint has a DiscoveredAuthConfig-* condition that is False, has a backend missing from
# status.discoveredBackends, or has one whose status is not "ready"; each failure names the backend; the Secret value is in no recorded argument.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "%s/sleeps"\n' "$D" > "$D/bin/sleep"
# kubectl: `get virtualmcpserver <name> -n <ns> -o json` answers with $D/<name>.json (exit 1 when there is none); `get secret <name> -n <ns> -o json` answers with
# $D/secret-<ns>-<name>.json (exit 1 when there is none). Every call is recorded.
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
case "\$1 \$2" in
  "get virtualmcpserver") f="$D/\$3.json"; [ -f "\$f" ] || exit 1
    n=\$(cat "$D/n-\$3" 2>/dev/null || echo 0); echo \$((n+1)) > "$D/n-\$3"
    if [ "\$n" -ge 1 ] && [ -f "\$f.2" ]; then cat "\$f.2"; else cat "\$f"; fi;;
  "get secret") f="$D/secret-\$5-\$3.json"; [ -f "\$f" ] || { echo 'Error from server (NotFound)' >&2; exit 1; }; cat "\$f";;
esac
exit 0
EOS
chmod +x "$D/bin/"*
cond() { printf '{"type":"%s","status":"%s","reason":"%s","message":"the secret value is hunter2"}' "$1" "$2" "$3"; }
back() { printf '{"name":"%s","status":"%s","message":"%s"}' "$1" "$2" "$3"; }
vmcp() { printf '{"status":{"conditions":[%s],"discoveredBackends":[%s]}}\n' "$1" "$2"; }
run() { rm -f "$D/sleeps" "$D"/n-*; : > "$D/calls"; PATH="$D/bin:$PATH" bash -c '. hack/diagnostics-check.sh; . hack/endpoints-check.sh; '"$1" _ "${@:2}" 2>&1; echo "exit=$?"; }

echo "# every backend ready: passes, and says which"
vmcp "" "$(back records ready ok),$(back knowledge-disputes ready ok)" > "$D/tools-disputes.json"
OUT=$(run 'ep_check_backends kubectl "$@"' 30 mcp-tools/tools-disputes records knowledge-disputes)
t "exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "it names the vMCP and the backends" "$(grep -c 'vMCP tools-disputes: every backend of its group is ready (records knowledge-disputes)' <<<"$OUT")" 1
t "it did not wait" "$(cat "$D/sleeps" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "# a backend missing from status.discoveredBackends: fails with its name (after waiting the settle time)"
vmcp "" "$(back knowledge-disputes ready ok)" > "$D/tools-disputes.json"
OUT=$(run 'ep_check_backends kubectl "$@"' 6 mcp-tools/tools-disputes records knowledge-disputes)
t "exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "it names the missing backend" "$(grep -c 'records: not in status.discoveredBackends' <<<"$OUT")" 1
t "it does not name the one that is there" "$(grep -c 'knowledge-disputes: ' <<<"$OUT")" 0
t "it waited in steps of 3 seconds, twice" "$(wc -l < "$D/sleeps" | tr -d ' ')" 2

echo "# a backend with a status other than ready: fails with its name, the status and the message"
vmcp "" "$(back records unavailable 'dial tcp: connection refused'),$(back knowledge-disputes ready ok)" > "$D/tools-disputes.json"
OUT=$(run 'ep_check_backends kubectl "$@"' 0 mcp-tools/tools-disputes records knowledge-disputes)
t "exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "it names the backend, the status and the message" "$(grep -c 'records: status unavailable (dial tcp: connection refused)' <<<"$OUT")" 1
vmcp "" "$(back records '' '')" > "$D/tools-disputes.json"
OUT=$(run 'ep_check_backends kubectl "$@"' 0 mcp-tools/tools-disputes records)
t "an empty status is not ready" "$(grep -c 'records: status none (no message)' <<<"$OUT")" 1

echo "# a backend that becomes ready within the settle time passes"
vmcp "" "$(back records unavailable starting)" > "$D/tools-disputes.json"
vmcp "" "$(back records ready ok)" > "$D/tools-disputes.json.2"
OUT=$(run 'ep_check_backends kubectl "$@"' 30 mcp-tools/tools-disputes records)
t "exit 0 after one wait" "$(grep -c '^exit=0$' <<<"$OUT")/$(wc -l < "$D/sleeps" | tr -d ' ')" 1/1
rm -f "$D/tools-disputes.json.2"

echo "# a vMCP that cannot be read fails (a missing vMCP is not a pass)"
rm -f "$D/tools-disputes.json"
OUT=$(run 'ep_check_backends kubectl "$@"' 0 mcp-tools/tools-disputes records)
t "exit 1 and the backend is named" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'records: not in status.discoveredBackends' <<<"$OUT")" 1/1

echo "# DiscoveredAuthConfig-<entry> False: the install fails and says it is an endpoint group"
vmcp "$(cond Ready True ok),$(cond DiscoveredAuthConfig-records False 'unsupported auth type: bearerToken')" "$(back records ready ok)" > "$D/tools-disputes.json"
OUT=$(run 'DIAG_CHECK_WHAT="a group of mcp.endpoints" diag_check_vmcps kubectl "$@"' 30 1 mcp-tools/tools-disputes)
t "exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "it names the vMCP, the condition of the entry and the reason" "$(grep -c 'tools-disputes dropped a backend of a group of mcp.endpoints: DiscoveredAuthConfig-records (unsupported auth type: bearerToken)' <<<"$OUT")" 1
t "it does not repeat the message of the condition" "$(grep -c hunter2 <<<"$OUT")" 0
OUT=$(run 'diag_check_vmcps kubectl "$@"' 30 1 mcp-tools/tools-disputes)
t "without DIAG_CHECK_WHAT the diagnostics wording is unchanged" "$(grep -c 'dropped a backend of the diagnostics group: DiscoveredAuthConfig-records' <<<"$OUT")" 1
vmcp "$(cond DiscoveredAuthConfig-records True ok)" "$(back records ready ok)" > "$D/tools-disputes.json"
OUT=$(run 'DIAG_CHECK_WHAT="a group of mcp.endpoints" diag_check_vmcps kubectl "$@"' 30 1 mcp-tools/tools-disputes)
t "all True passes" "$(grep -c '^exit=0$' <<<"$OUT")" 1

echo "# the header Secret must exist with its key before the chart is applied"
printf '{"data":{"value":"Qm9ndXM="}}' > "$D/secret-mcp-tools-records-mcp-auth.json"
OUT=$(run 'printf "mcp-tools\trecords-mcp-auth\tvalue\n" | ep_check_secrets kubectl')
t "a Secret with the key passes" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "it never prints the value" "$(grep -c 'Qm9ndXM=\|Bogus' <<<"$OUT")" 0
OUT=$(run 'printf "mcp-tools\trecords-mcp-auth\tother\n" | ep_check_secrets kubectl')
t "a Secret without the key fails and names Secret and key" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'mcp-tools/records-mcp-auth has no key other' <<<"$OUT")" 1/1
OUT=$(run 'printf "mcp-tools\tnope\tvalue\n" | ep_check_secrets kubectl')
t "a Secret that does not exist fails and names it" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'the Secret mcp-tools/nope' <<<"$OUT")" 1/1
printf '{"data":{"value":""}}' > "$D/secret-mcp-tools-empty.json"
OUT=$(run 'printf "mcp-tools\tempty\tvalue\n" | ep_check_secrets kubectl')
t "an empty value fails" "$(grep -c '^exit=1$' <<<"$OUT")" 1
OUT=$(run 'printf "mcp-tools\trecords-mcp-auth\tvalue\nmcp-tools\tnope\tvalue\n" | ep_check_secrets kubectl')
t "with two Secrets the missing one fails the check" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "no recorded kubectl argument holds a Secret value" "$(grep -c 'Qm9ndXM=\|Bogus\|hunter2' "$D/calls")" 0

echo "# the live script and its setup refuse a cluster that is not a CI cluster"
cat > "$D/bin/kubectl-ctx" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/live-calls"
[ "\$1 \$2" = "config current-context" ] && { echo "\$FAKE_CTX"; exit 0; }
exit 0
EOS
chmod +x "$D/bin/kubectl-ctx"
live() { local script=$1; shift; : > "$D/live-calls"; env -i PATH="$PATH" HOME="$HOME" KUBECTL="$D/bin/kubectl-ctx" "$@" bash "$script" 2>&1; echo "exit=$?"; }
for S in hack/ci/endpoints-live.sh hack/ci/endpoints-ci-setup.sh; do
  OUT=$(live "$S" ENDPOINTS=0 FAKE_CTX=kind-openagentix)
  t "$S: without ENDPOINTS=1 it does nothing (exit 0, no call)" "$(grep -c '^exit=0$' <<<"$OUT")/$(wc -l < "$D/live-calls" | tr -d ' ')" 1/0
  OUT=$(live "$S" ENDPOINTS=1 FAKE_CTX=gke_prod_europe_main GITHUB_ACTIONS=true)
  t "$S: a context that is not kind or k3d is refused, even on Actions" "$(grep -c '^exit=2$' <<<"$OUT")/$(grep -c 'not a kind or k3d context' <<<"$OUT")" 1/1
  OUT=$(live "$S" ENDPOINTS=1 FAKE_CTX=kind-openagentix)
  t "$S: a kind context outside CI is refused (it could be the owner's cluster)" "$(grep -c '^exit=2$' <<<"$OUT")/$(grep -c 'not a CI run' <<<"$OUT")" 1/1
  t "$S: a refusal changes nothing: the only call was reading the context" "$(grep -vc '^kubectl config current-context$' "$D/live-calls")" 0
  OUT=$(live "$S" ENDPOINTS=1 FAKE_CTX=kind-openagentix ENDPOINTS_CI_CONTEXT=kind-other)
  t "$S: ENDPOINTS_CI_CONTEXT must name the current context exactly" "$(grep -c '^exit=2$' <<<"$OUT")" 1
done
t "the live script deletes what it made on exit (the cluster role binding, the ConfigMap and the probe objects)" "$(grep -c 'delete clusterrolebinding ci-jwks-anonymous' hack/ci/endpoints-live.sh)/$(grep -c 'delete configmap ci-apiserver-ca' hack/ci/endpoints-live.sh)/$(grep -c 'delete virtualmcpserver tools-ovr probe-redir' hack/ci/endpoints-live.sh)" 1/1/1
t "the live values are under hack/ci and say they are for CI only" "$(grep -c 'CI ONLY' hack/ci/endpoints-ci-values.yaml | awk '{print ($1>0)?1:0}')" 1
t "the live script never echoes a header value (a value goes only into a process substitution, a grep pattern or a Secret)" "$(grep -cE 'echo[^|]*\$(V|RV|RAW|VAL)\b' hack/ci/endpoints-live.sh)" 0
t "the endpoint server reads its value from a file and never logs it" "$(grep -c 'EXPECTED' hack/ci/endpoints-ci/echo-mcp.py | awk '{print ($1>0)?1:0}')/$(grep -c 'log(.*EXPECTED' hack/ci/endpoints-ci/echo-mcp.py)" 1/0

echo "# the installer uses them"
t "install.sh sources hack/endpoints-check.sh" "$(grep -c '^[[:space:]]*\. hack/endpoints-check.sh' install.sh)" 1
t "install.sh stops the install when a Secret is missing" "$(grep -c 'ep_check_secrets .* || die' install.sh)" 1
t "install.sh stops the install when a condition is False" "$(grep -c 'DIAG_CHECK_WHAT=.* diag_check_vmcps .* || die' install.sh)" 1
t "install.sh stops the install when a backend is missing or not ready" "$(grep -c 'ep_check_backends .* || die' install.sh)" 1
[ "$F" = 0 ] && echo "endpoints-check-test: all passed" || { echo "endpoints-check-test: FAILED"; exit 1; }
