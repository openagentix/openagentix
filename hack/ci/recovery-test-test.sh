#!/usr/bin/env bash
# Offline test of hack/ci/recovery-test.sh (issue #203) with fake kubectl, docker, kind, sleep, clock and smoke command (no cluster, no Docker,
# no waiting). It checks the budget, the restart counting, the allowlist, failed jobs, the agent and the smoke retry.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"

# the clock: a file that the fake sleep advances; it starts at a real-looking epoch (2027-01-15)
cat > "$D/now" <<EOS
#!/usr/bin/env bash
cat "$D/clock"
EOS
cat > "$D/sleep" <<EOS
#!/usr/bin/env bash
echo \$(( \$(cat "$D/clock") + \${1:-1} )) > "$D/clock"
EOS
# pods as JSON: mkpods <restarts of the controller> <started: stale|fresh> <ready: True|False>
cat > "$D/mkpods" <<'EOS'
#!/usr/bin/env bash
S=2020-01-01T00:00:00Z; [ "$2" = fresh ] && S=2030-01-01T00:00:00Z
jq -n --arg s "$S" --arg r "$3" --argjson c "$1" '
 def pod($ns;$n;$rc;$ready): {metadata:{namespace:$ns,name:$n}, spec:{containers:[{name:"a"}]},
   status:{phase:"Running", conditions:[{type:"Ready",status:$ready}], containerStatuses:[{restartCount:$rc, state:{running:{startedAt:$s}}}]}};
 {items:[pod("kagent";"kagent-controller-x";$c;$r), pod("kube-system";"etcd-node";(if $c>0 then 1 else 0 end);"True"),
         {metadata:{namespace:"x",name:"done-job-1"},spec:{containers:[{name:"a"}]},status:{phase:"Succeeded"}}]}'
EOS
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
bump(){ n=\$(cat "$D/\$1" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$D/\$1"; echo \$n; }
case "\$*" in
  "get --raw /readyz") [ -f "$D/restarted" ] || exit 0; n=\$(bump api); [ "\$n" -gt "\${FAKE_API_DOWN:-0}" ] || exit 1; echo ok;;
  "get pods -A -o json")
    if [ ! -f "$D/restarted" ]; then "$D/mkpods" 0 stale True; exit 0; fi
    n=\$(bump pods)
    if [ "\$n" -le "\${FAKE_NOTREADY:-0}" ]; then "$D/mkpods" 1 stale False
    else "$D/mkpods" \$((1 + \${FAKE_EXTRA:-0})) fresh True; fi;;
  "get jobs -A -o json") if [ "\${FAKE_JOB_FAILED:-0}" = 1 ]; then echo '{"items":[{"metadata":{"namespace":"kagent","name":"memory-expiry-1"},"status":{"failed":1}}]}'; else echo '{"items":[{"metadata":{"namespace":"x","name":"ok"},"status":{"succeeded":1}}]}'; fi;;
  wait\ *) [ "\${FAKE_AGENT_NOTREADY:-0}" = 1 ] && exit 1; exit 0;;
esac
exit 0
EOS
cat > "$D/bin/docker" <<EOS
#!/usr/bin/env bash
echo "docker \$*" >> "$D/calls"; touch "$D/restarted"
EOS
cat > "$D/bin/kind" <<EOS
#!/usr/bin/env bash
echo "kind \$*" >> "$D/calls"
EOS
# the smoke command: fails the first FAKE_SMOKE_FAIL calls after the restart (always, when 999); every call takes 20 s of fake time
cat > "$D/smoke" <<EOS
#!/usr/bin/env bash
echo "smoke" >> "$D/calls"
echo \$(( \$(cat "$D/clock") + 20 )) > "$D/clock"
[ -f "$D/restarted" ] || exit 0
n=\$(cat "$D/smoke-n" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$D/smoke-n"
[ "\$n" -gt "\${FAKE_SMOKE_FAIL:-0}" ]
EOS
chmod +x "$D/bin/"* "$D/now" "$D/sleep" "$D/mkpods" "$D/smoke"

# r <VAR=value>...: one run with a fresh state; prints the output and exit=<code>; the summary is in $D/summary.md
r(){ rm -f "$D/calls" "$D/restarted" "$D/api" "$D/pods" "$D/smoke-n" "$D/summary.md"; echo 1800000000 > "$D/clock"; : > "$D/calls"
  env -i PATH="$D/bin:$PATH" HOME="$HOME" CLUSTER=oa-rec RECOVERY_NOW_CMD="cat $D/clock" RECOVERY_SLEEP="$D/sleep" RECOVERY_SMOKE_CMD="$D/smoke" \
    RECOVERY_SUMMARY="$D/summary.md" RECOVERY_ALLOW="$D/allow" RECOVERY_SETTLE=60 RECOVERY_POLL=10 "$@" bash hack/ci/recovery-test.sh 2>&1; echo "exit=$?"; }
: > "$D/allow"
calls(){ cat "$D/calls"; }
sum(){ cat "$D/summary.md" 2>/dev/null; }

echo "# a clean recovery"
OUT=$(r)
t "clean: exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "clean: restarts exactly the node container oa-rec-control-plane" "$(calls | grep -c '^docker restart oa-rec-control-plane$')" 1
t "clean: the smoke test ran before and after (2 calls)" "$(calls | grep -c '^smoke$')" 2
t "clean: the summary says PASS" "$(sum | grep -c '| result | PASS |')" 1
t "clean: the node restart (1 per container) is listed with extra 0" "$(sum | grep -c '^kagent/kagent-controller-x  *1  *1  *0')" 1
t "clean: a finished pod is not listed" "$(sum | grep -c 'done-job')" 0
t "clean: the recovery time is in the summary" "$(sum | grep -c 'smoke test passes again | [0-9]* s')" 1

echo "# the API server comes back late: the kubeconfig is exported again"
OUT=$(r FAKE_API_DOWN=3)
t "api late: exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "api late: kind export kubeconfig was run for the cluster" "$(calls | grep -c '^kind export kubeconfig --name oa-rec$')" 3

echo "# pods are not Ready (or still hold a container from before the restart) for a while"
OUT=$(r FAKE_NOTREADY=4)
t "slow pods: exit 0, waited" "$(grep -c '^exit=0$' <<<"$OUT")" 1
OUT=$(r FAKE_NOTREADY=1000 RECOVERY_BUDGET=100)
t "pods never Ready: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "pods never Ready: names the pod" "$(sum | grep -c 'pods not Ready after 100s: kagent/kagent-controller-x')" 1

echo "# a crash loop after the restart"
OUT=$(r FAKE_EXTRA=3)
t "crash loop: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "crash loop: the pod and its extra restarts are named" "$(sum | grep -c 'kagent/kagent-controller-x 3')" 1
t "crash loop: listed with restarts 4 and extra 3" "$(sum | grep -c '^kagent/kagent-controller-x  *4  *1  *3')" 1
echo "restarts kagent/kagent-controller  # #178" > "$D/allow"
OUT=$(r FAKE_EXTRA=3)
t "allowlist entry with an issue: exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "allowlist entry with an issue: the summary still shows it" "$(sum | grep -c 'allowlisted')" 1
echo "restarts kagent/kagent-controller  # no issue here" > "$D/allow"
OUT=$(r FAKE_EXTRA=3)
t "allowlist entry without an issue number is ignored: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
: > "$D/allow"

echo "# failed Job, agent not Ready, smoke never passes, budget"
OUT=$(r FAKE_JOB_FAILED=1)
t "failed job: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "failed job: named" "$(sum | grep -c 'failed jobs: kagent/memory-expiry-1')" 1
OUT=$(r FAKE_AGENT_NOTREADY=1)
t "agent not Ready: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "agent not Ready: said" "$(sum | grep -c 'AgentDefinition quickstart is not Ready=True')" 1
OUT=$(r FAKE_SMOKE_FAIL=2)
t "smoke fails twice then passes: exit 0 with 3 attempts" "$(grep -c '^exit=0$' <<<"$OUT")/$(sum | grep -c 'attempts: 3, passed: yes')" 1/1
OUT=$(r FAKE_SMOKE_FAIL=999 RECOVERY_BUDGET=200)
t "smoke never passes: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "smoke never passes: said" "$(sum | grep -c 'the smoke test did not pass within 200s')" 1
OUT=$(r FAKE_SMOKE_FAIL=1 RECOVERY_BUDGET=100)
t "smoke passes but after the budget: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "smoke passes but after the budget: says the budget" "$(sum | grep -c 'budget 100s')" 1

echo "# the smoke test fails before the restart: nothing is restarted"
OUT=$(r RECOVERY_SMOKE_CMD=false)
t "smoke fails first: exit 2, no docker restart" "$(grep -c '^exit=2$' <<<"$OUT")/$(calls | grep -c 'docker restart')" 1/0

echo "# the default cluster name is the owner's cluster: refused"
OUT=$(r CLUSTER=openagentix)
t "CLUSTER=openagentix: exit 2, no docker call, no smoke" "$(grep -c '^exit=2$' <<<"$OUT")/$(calls | grep -c 'docker\|smoke')" 1/0
OUT=$(r CLUSTER=openagentix RECOVERY_ALLOW_DEFAULT_CLUSTER=1)
t "CLUSTER=openagentix with RECOVERY_ALLOW_DEFAULT_CLUSTER=1: runs" "$(grep -c '^exit=0$' <<<"$OUT")" 1
exit $F
