#!/usr/bin/env bash
# Offline test of hack/demo.sh (issue #36) with a fake kubectl, a fake hack/ask.sh and a fake curl. No cluster, no network.
set -u
cd "$(dirname "$0")/.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
has(){ if grep -qF -- "$2" <<<"$3"; then echo "  ok   $1"; else echo "  FAIL $1 (no '$2')"; F=1; fi; }
hasnt(){ if grep -qF -- "$2" <<<"$3"; then echo "  FAIL $1 ('$2' was printed)"; F=1; else echo "  ok   $1"; fi; }
[ -x hack/demo.sh ] || { echo "  FAIL hack/demo.sh is missing or not executable"; exit 1; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"

# fake kubectl: records every call in $D/calls, the stdin of `apply` in $D/applied; answers by pattern
cat > "$D/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_DIR/calls"
a="$*"
case "$a" in
  "get agentdefinition quickstart"*) [ "${FAKE_NO_QS:-0}" = 1 ] && exit 1; echo True;;
  "apply -f -"*) cat >> "$FAKE_DIR/applied";;
  "wait agentdefinition/demo-lookup"*) echo condition met;;
  "get agentdefinition demo-lookup"*) echo '{"status":{"conditions":[{"type":"Accepted","status":"True"},{"type":"KeyReady","status":"True"},{"type":"Ready","status":"True"}],"controller":{"gatewayUserId":"kagent.demo-lookup"}}}';;
  "get configmap llm-api-keys-control-plane"*) echo '{"data":{"keys.json":"{\"kagent.quickstart\":\"HASH1\",\"kagent.demo-lookup\":\"HASH2\"}"}}';;
  "get agentgatewaypolicies"*) echo '{"items":[{"metadata":{"name":"model-gateway-auth"},"spec":{"traffic":{"rateLimit":{"local":[{"tokens":100000,"unit":"Hours","key":"apiKey.user_id"}]}}}}]}';;
  "get pod -n openagentix-gateway"*) echo pod/a2a-gate-abc;;
  "logs -n openagentix-gateway"*)
    if [ -n "${FAKE_NO_AUDIT:-}" ]; then echo '{"msg":"started"}'; else
    echo '{"time":"2026-11-25T10:00:00Z","caller":"quickstart-ask","agent":"kagent/quickstart","user_id":"h:1a2b3c4d","status":200,"duration_ms":812,"rpc":"SendMessage"}'
    echo '{"time":"2026-11-25T10:00:05Z","caller":"quickstart-ask","agent":"kagent/demo-lookup","user_id":"h:1a2b3c4d","status":403,"duration_ms":1,"reason":"agent"}'; fi;;
  "get secret"*console-token*) echo U0VOVElORUwtVE9LRU4=;;   # base64 of SENTINEL-TOKEN
  "port-forward"*) exec sleep 30;;
  "delete agentdefinition demo-lookup"*) echo deleted;;
  *) echo "fake kubectl: unexpected: $a" >&2; exit 1;;
esac
EOF
# fake ask: the agent quickstart answers; any other agent is refused by the gate (exit 1)
cat > "$D/ask" <<'EOF'
#!/usr/bin/env bash
echo "$1 :: $2" >> "$FAKE_DIR/asks"
if [ "$1" = quickstart ]; then
  case "$2" in *example.com*) echo "I have no fetch tool, so I cannot open that page. (stub model)";; *) echo "Used the tool osv_query_vulnerability. (stub model)";; esac
  exit 0
fi
[ "${FAKE_ASK_ALLOWS_ALL:-0}" = 1 ] && { echo "answer"; exit 0; }
echo "ask.sh: HTTP 403 from the gate: {\"error\":\"forbidden\"}" >&2; exit 1
EOF
cat > "$D/bin/curl" <<'EOF'
#!/usr/bin/env bash
# fake curl: 401 without Authorization, a JSON list with it; healthz is fine
a="$*"; in=""
case "$a" in *"-K -"*) in=$(cat);; esac
a="$a $in"
case "$a" in
  *healthz*) exit 0;;
  *"-w"*"http_code"*) case "$a" in *Authorization*) printf 200;; *) printf 401;; esac;;
  *Authorization*) echo '{"items":[{"name":"quickstart"},{"name":"demo-lookup"}]}';;
  *) echo "{}";;
esac
EOF
chmod +x "$D/bin/kubectl" "$D/ask" "$D/bin/curl"
run() { : > "$D/calls"; : > "$D/applied"; : > "$D/asks"; PATH="$D/bin:$PATH" FAKE_DIR="$D" KUBECTL="$D/bin/kubectl" DEMO_ASK="$D/ask" DEMO_WAIT=5 DEMO_AUDIT_WAIT=2 hack/demo.sh 2>&1; }

echo "# a full run"
OUT=$(run); RC=$?
t "exit 0" "$RC" 0
for n in 1 2 3 4 5 6; do has "step $n is announced" "== Step $n" "$OUT"; done
has "each step says what to look for" "Look for:" "$OUT"
has "the AgentDefinition is created from a spec with the right name" "name: demo-lookup" "$(cat "$D/applied")"
has "it uses the model alias the policy allows" "model: quickstart-model" "$(cat "$D/applied")"
has "the answer is printed" "osv_query_vulnerability" "$OUT"
has "the gateway user is shown" "kagent.demo-lookup" "$OUT"
has "the budget is shown" "100000" "$OUT"
has "the audit line for the allowed call is shown" '"status": 200' "$OUT"
has "the audit line for the refused call is shown" '"reason": "agent"' "$OUT"
has "the refused call is reported as denied" "denied, as it should be" "$OUT"
has "the asks went to quickstart and to demo-lookup" "demo-lookup ::" "$(cat "$D/asks")"
has "the console answers 401 without a token" "401" "$OUT"
has "the console command to open it is printed" "port-forward -n openagentix-system svc/openagentix-console" "$OUT"
hasnt "the console token is never printed" "SENTINEL-TOKEN" "$OUT"
hasnt "the key hash is never printed" "HASH2" "$OUT"
has "the demo agent is removed at the end" "delete agentdefinition demo-lookup" "$(cat "$D/calls")"

echo "# idempotent: a second run gives the same result"
OUT=$(run); t "exit 0 again" "$?" 0

echo "# DEMO_KEEP=1 keeps the agent"
OUT=$(DEMO_KEEP=1 run); t "exit 0" "$?" 0
hasnt "no delete call" "delete agentdefinition" "$(cat "$D/calls")"

echo "# DEMO_CONSOLE=0 (PROFILE=minimal has no console): the other steps still run and the console step is skipped"
OUT=$(DEMO_CONSOLE=0 run); t "exit 0" "$?" 0
has "step 5 (the refused call) still ran" "denied, as it should be" "$OUT"
has "the console step says it was skipped" "skipped" "$(grep -A2 'Step 6' <<<"$OUT")"
hasnt "no console port-forward was tried" "port-forward" "$(cat "$D/calls")"

echo "# failures"
OUT=$(FAKE_NO_QS=1 run); t "no quick start installed: exit 1" "$?" 1
has "it says how to install" "PROFILE=quickstart ./install.sh" "$OUT"
OUT=$(FAKE_ASK_ALLOWS_ALL=1 run); t "a call that should be denied but is allowed: exit 1" "$?" 1
has "it says so" "FAIL" "$OUT"
OUT=$(FAKE_NO_AUDIT=1 run); t "no audit line found: exit 1" "$?" 1
OUT=$(hack/demo.sh --bogus 2>&1); t "unknown argument: exit 2" "$?" 2
exit $F
