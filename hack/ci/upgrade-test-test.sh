#!/usr/bin/env bash
# Offline tests for hack/ci/upgrade-test.sh with a fake `kubectl` and `helm`, a fake kb and fake install steps (no cluster, no git tag needed).
# The fake cluster is a set of JSON files; the fake installs change them the way a bad upgrade would. One passing run and one failing run per kind of loss.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/g"
G=$D/g
cat > "$G/agents.json" <<'EOS'
{"items":[{"metadata":{"namespace":"kagent","name":"assistant","uid":"uid-agent-1"}}]}
EOS
cat > "$G/cronjobs.json" <<'EOS'
{"items":[{"metadata":{"namespace":"openagentix-schedules","name":"upgrade-canary","uid":"uid-cj-1"},"spec":{"suspend":true}}]}
EOS
cat > "$G/pvc.json" <<'EOS'
{"items":[{"metadata":{"namespace":"openagentix-knowledge","name":"data-kb-postgres-0","uid":"uid-pvc-1"}}]}
EOS
cat > "$G/secrets.json" <<'EOS'
{"items":[{"metadata":{"namespace":"kagent","name":"assistant-virtual-key"},"type":"Opaque","data":{"k":"a2V5MQ=="}},
{"metadata":{"namespace":"kagent","name":"kagent-controller-internal"},"type":"Opaque","data":{"k":"cm90YXRlcw=="}},
{"metadata":{"namespace":"openagentix-knowledge","name":"kb-admin"},"type":"Opaque","data":{"KB_ADMIN_TOKEN":"dG9rZW4x"}}]}
EOS
echo '{"data":{"keys.json":"{\"hash\":\"abc\"}"}}' > "$G/configmap.json"
echo '{"items":[{"metadata":{"namespace":"kagent","name":"a-1"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}' > "$G/pods.json"
echo '{"items":[{"metadata":{"namespace":"kagent","name":"a-1"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"False"}],"containerStatuses":[{"state":{"waiting":{"reason":"CrashLoopBackOff"}}}]}}]}' > "$D/pods-bad.json"
echo '{"collections":[{"name":"openagentix","documents":5},{"name":"upgrade-canary","documents":1}]}' > "$G/kb.json"
echo 'found' > "$G/canary"
echo '1 0123456789abcdef' > "$G/memory"
cat > "$D/bin/helm" <<EOS
#!/usr/bin/env bash
echo '{"version":2,"info":{"status":"deployed"}}'
EOS
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
a="\$*"
case "\$a" in
  "get agents.kagent.dev -n kagent -o json") cat "$D/w/agents.json";;
  "get cronjobs -A -o json") cat "$D/w/cronjobs.json";;
  "get pvc -A -o json") cat "$D/w/pvc.json";;
  "get secrets -A -o json") cat "$D/w/secrets.json";;
  "get configmap llm-api-keys -n agentgateway-system -o json") cat "$D/w/configmap.json";;
  "get pods -A -o json") cat "$D/w/pods.json";;
  "get crd agentdefinitions.openagentix.io -o jsonpath="*) [ -f "$D/w/crd" ] && printf True;;
  "get crd agentdefinitions.openagentix.io") [ -f "$D/w/crd" ] || exit 1;;
  "get agentdefinition upgrade-check"*) echo '{}';;
  "wait agent.kagent.dev/assistant"*) [ -f "$D/w/notready" ] && exit 1;;
  "wait agentdefinition/upgrade-check"*) [ -f "$D/w/defnotready" ] && exit 1;;
  *"kagent-pg-0 -- psql"*) case "\$a" in *"insert into"*) ;; *) cat "$D/w/memory";; esac;;
esac
exit 0
EOS
# the fake kb: GET /v1/collections, PUT a document, POST /mcp (the canary is in the answer when the file says so)
cat > "$D/kb" <<EOS
#!/usr/bin/env bash
case "\$1 \$2" in
  "GET /v1/collections") cat "$D/w/kb.json";;
  "PUT "*) echo '{"collection":"upgrade-canary","id":"canary-1","chunks":1}';;
  "POST /mcp") [ "\$(cat "$D/w/canary")" = found ] && echo 'upgrade-canary canary-1 zebra-orchid-7731' || echo 'no results';;
esac
EOS
cat > "$D/old" <<EOS
#!/usr/bin/env bash
[ "\${FAKE:-}" = old-fails ] && { echo "boom: old install failed"; exit 1; }
exit 0
EOS
cat > "$D/new-a" <<EOS
#!/usr/bin/env bash
w="$D/w"
case "\${FAKE:-}" in
  agent-recreated) sed -i.bak 's/uid-agent-1/uid-agent-2/' "\$w/agents.json";;
  schedule-recreated) sed -i.bak 's/uid-cj-1/uid-cj-2/' "\$w/cronjobs.json";;
  pvc-recreated) sed -i.bak 's/uid-pvc-1/uid-pvc-2/' "\$w/pvc.json";;
  key-rotated) sed -i.bak 's/a2V5MQ==/a2V5Mg==/' "\$w/secrets.json";;
  keys-cm-changed) sed -i.bak 's/abc/def/' "\$w/configmap.json";;
  kb-docs-lost) sed -i.bak 's/"documents":5/"documents":0/' "\$w/kb.json";;
  canary-lost) echo lost > "\$w/canary";;
  memory-lost) echo '0 ' > "\$w/memory";;
  crashloop) cp "$D/pods-bad.json" "\$w/pods.json";;
  agent-not-ready) touch "\$w/notready";;
  new-a-fails) echo "boom: helm upgrade failed"; exit 1;;
esac
# an unrelated Secret of the controller may rotate: it is not a fact the test keeps
sed -i.bak 's/cm90YXRlcw==/cm90YXRlczI=/' "\$w/secrets.json"
exit 0
EOS
cat > "$D/new-b" <<EOS
#!/usr/bin/env bash
[ "\${FAKE:-}" = crd-missing ] || touch "$D/w/crd"
[ "\${FAKE:-}" = definition-not-ready ] && touch "$D/w/defnotready"
[ "\${FAKE:-}" = pvc-lost-at-b ] && sed -i.bak 's/uid-pvc-1/uid-pvc-9/' "$D/w/pvc.json"
exit 0
EOS
chmod +x "$D/bin/"* "$D/kb" "$D/old" "$D/new-a" "$D/new-b"

U(){ rm -rf "$D/w"; cp -R "$G" "$D/w"
  FAKE=$1 PATH="$D/bin:$PATH" KUBECTL="$D/bin/kubectl" HELM="$D/bin/helm" KB_CALL="$D/kb" HEALTH_WAIT=1 \
    UPGRADE_OLD_INSTALL="$D/old" UPGRADE_NEW_INSTALL="$D/new-a" UPGRADE_NEW_INSTALL_B="$D/new-b" \
    bash hack/ci/upgrade-test.sh 2>&1; echo "exit=$?"; }
n(){ grep -c -- "$1" <<<"$OUT"; }

echo "# the passing run"
OUT=$(U none)
t "exit 0" "$(n '^exit=0$')" 1
t "no failure" "$(n '^FAIL')" 0
t "state kept after upgrade A" "$(n '^ok    state kept after upgrade A')" 1
t "the CRD is Established after upgrade B" "$(n '^ok    the CRD is Established')" 1
t "the not-checked list is printed" "$(n '^# not checked: an answer from the old agent')" 1
t "no Secret value is printed" "$(n -e a2V5MQ -e dG9rZW4x -e abc)" 0

echo "# each kind of loss is seen"
for s in agent-recreated:"agent/kagent/assistant" schedule-recreated:"cronjob/" pvc-recreated:"pvc/" key-rotated:"secret/kagent/assistant-virtual-key" keys-cm-changed:"configmap/" kb-docs-lost:"kb/collections" canary-lost:"kb/canary-found" memory-lost:"memory/upgrade-test"; do
  OUT=$(U "${s%%:*}"); t "${s%%:*}: the state check fails and names the fact" "$(n '^FAIL  state kept after upgrade A')/$(n "${s#*:}")/$(n '^exit=1$')" "1/$(grep -c -- "${s#*:}" <<<"$OUT")/1"
  t "${s%%:*}: names $(printf '%s' "${s#*:}")" "$([ "$(n "      ${s#*:}")" -ge 1 ] && echo yes || echo no)" yes
done
OUT=$(U crashloop);          t "a pod in CrashLoopBackOff after upgrade A fails" "$(n '^FAIL  after upgrade A: unhealthy pods')/$(n '^exit=1$')" 1/1
OUT=$(U agent-not-ready);    t "an agent that is not Ready after upgrade A fails" "$(n '^FAIL  agent assistant is not Ready after the upgrade')/$(n '^exit=1$')" 1/1
OUT=$(U old-fails);          t "a failing old install fails and stops" "$(n 'boom: old install failed')/$(n '^exit=1$')/$(n '^=== upgrade to this checkout')" 1/1/0
OUT=$(U new-a-fails);        t "a failing upgrade fails and stops" "$(n 'boom: helm upgrade failed')/$(n '^exit=1$')/$(n '^# 3. upgrade B')" 1/1/0
OUT=$(U crd-missing);        t "a CRD that did not arrive fails" "$(n '^FAIL  the CRD is Established')/$(n '^exit=1$')" 1/1
OUT=$(U definition-not-ready); t "a definition that never gets Ready fails" "$(n '^FAIL  the AgentDefinition did not become Ready')/$(n '^exit=1$')" 1/1
OUT=$(U pvc-lost-at-b);      t "state lost at upgrade B is seen" "$(n '^FAIL  state still kept after upgrade B')/$(n '^exit=1$')" 1/1
exit $F
