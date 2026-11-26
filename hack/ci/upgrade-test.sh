#!/usr/bin/env bash
# Upgrade test (issue #205): an install of release v0.2.0 is upgraded to this checkout (main) and keeps its state.
#   1. extract the tag (default v0.2.0) with `git archive` and run ITS ./install.sh there (no image of v0.2.0 is published: the tag builds its own),
#      with the values in UPGRADE_VALUES (bridge off, one schedule). Placeholder provider and chat tokens are used: nothing calls a paid model.
#   2. seed state the release can hold without a model call: a knowledge base document (collection upgrade-canary), a memory row for the agent
#      `assistant` (kagent's PostgreSQL), and read what the install made: the agent, the gateway virtual key and its hash, the schedule (CronJob),
#      the knowledge base and database Secrets and volumes.
#   3. run this checkout's ./install.sh with the SAME values ("upgrade A"). No manual step is allowed in between.
#   4. check the state is kept: UIDs of the agent, the schedule and the volumes; the content (hashes only) of the Secrets and the key ConfigMap;
#      the knowledge base documents and the canary search; the memory row; the agent is Ready; no pod crash-loops.
#   5. upgrade again with the control plane switched on ("upgrade B"): the CRD agentdefinitions.openagentix.io is new in this checkout (v0.2.0 has no
#      control plane), so this is the CRD upgrade check: the CRD is established, an AgentDefinition is accepted and its agent becomes Ready, and the
#      state of step 4 is still kept.
# Not checked, and said so in the output: an answer from the old agent (v0.2.0 has no stub model, and no paid model is called in tests), A2A gate audit
# lines (the gate is off in the v0.2.0 default values), and a real virtual-key request.
# Needs: git, kubectl, helm, jq, yq (Python wrapper), curl, docker and kind (the installers use them), the repository as the working directory
# with the tag fetched (git fetch --tags). Env: UPGRADE_FROM (v0.2.0), UPGRADE_OLD_INSTALL / UPGRADE_NEW_INSTALL / UPGRADE_SMOKE (the commands that run
# each step, the offline test replaces them), UPGRADE_SKIP_B=1 (stop after upgrade A), KUBECTL, HELM, KB_CALL (a command that prints the answer of
# `<METHOD> <path> [json body]` of the kb, default: port-forward and curl with the admin token, never printed).
# Prints one line per check; exit 1 when any failed. Never prints a Secret value.
set -uo pipefail
export LC_ALL=C
cd "$(dirname "$0")/../.." || exit 1
REPO=$PWD
K=${KUBECTL:-kubectl}; HELM=${HELM:-helm}
FROM=${UPGRADE_FROM:-v0.2.0}
RELEASE=${RELEASE:-openagentix}; RELEASE_NS=${RELEASE_NS:-openagentix-system}
KAGENT_NS=${KAGENT_NS:-kagent}; KB_NS=${KB_NS:-openagentix-knowledge}
AGENT=${UPGRADE_AGENT:-assistant}
NS_RE=${UPGRADE_NS_RE:-'^(openagentix-.*|agentgateway-system|kagent|toolhive-system|ate-system)$'}
CANARY='zebra-orchid-7731'
W=$(mktemp -d); trap 'rm -rf "$W"; [ -z "${PF:-}" ] || kill "$PF" 2>/dev/null' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /' >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
summary(){ echo; echo "upgrade: $pass ok, $fail failed"; [ "$fail" = 0 ] && exit 0 || exit 1; }
run(){ local label=$1; shift; local t0; t0=$(date +%s); echo "=== $label"
  "$@" >"$W/step.log" 2>&1; local rc=$?
  [ -z "${UPGRADE_LOG_DIR:-}" ] || cp "$W/step.log" "$UPGRADE_LOG_DIR/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' _).log"
  if [ $rc = 0 ]; then ok "$label ($(( $(date +%s) - t0 )) s)"; tail -n 5 "$W/step.log" | sed 's/^/      | /'
  else bad "$label failed ($(( $(date +%s) - t0 )) s): last lines of its output" "$(tail -n 60 "$W/step.log")"; summary; fi; }

# ---- values: the same file for the old install and for upgrade A (Helm replaces release values on each run, so both must pass it) -------------
VALUES_A="$W/values-a.yaml"; VALUES_B="$W/values-b.yaml"
cat > "$VALUES_A" <<'EOS'
# Values for the upgrade test: v0.2.0 defaults (agent `assistant` with knowledge base, memory and a skill), no Telegram bridge, one suspended schedule.
bridge:
  enabled: false
schedules:
  - name: upgrade-canary
    agent: assistant
    schedule: "0 8 * * 1-5"
    timeZone: UTC
    suspend: true
    prompt: "Say ok."
EOS
cat > "$VALUES_B" <<'EOS'
# Upgrade B adds the control plane (new since v0.2.0): one policy, no tool profile.
controlPlane:
  enabled: true
  policy:
    maxAgents: 3
    allowedModels: [claude-haiku]
    allowedProfiles: []
    allowKnowledge: false
    allowNotify: false
EOS
cat > "$W/definition.yaml" <<EOS
apiVersion: openagentix.io/v1alpha1
kind: AgentDefinition
metadata: {name: upgrade-check, namespace: $KAGENT_NS}
spec:
  description: Created after the upgrade from $FROM to prove the new CRD works
  model: claude-haiku
  instructions: Answer in one short sentence.
EOS

# placeholders only: the install needs a provider key and a bot token to exist, and nothing in this test calls a model or Telegram
PLACEHOLDERS=(ANTHROPIC_API_KEY=ci-placeholder-not-a-real-key TELEGRAM_BOT_TOKEN=0:ci-placeholder-not-a-real-token TELEGRAM_ALLOWED_CHAT_IDS=0)
extract_old(){ OLD="$W/old"; mkdir -p "$OLD" && git -C "$REPO" archive "$FROM" | tar -x -C "$OLD"; }
old_install(){ ( cd "$OLD" && env "${PLACEHOLDERS[@]}" VALUES_FILE="$VALUES_A" ./install.sh ); }
new_install_a(){ env "${PLACEHOLDERS[@]}" VALUES_FILE="$VALUES_A" ./install.sh; }
new_install_b(){ env "${PLACEHOLDERS[@]}" VALUES_FILE="$VALUES_A $VALUES_B" ./install.sh; }
OLD_INSTALL=${UPGRADE_OLD_INSTALL:-old_install}; NEW_INSTALL_A=${UPGRADE_NEW_INSTALL:-new_install_a}; NEW_INSTALL_B=${UPGRADE_NEW_INSTALL_B:-new_install_b}
SMOKE=${UPGRADE_SMOKE:-}

# ---- the knowledge base admin API and MCP, through a port-forward (the admin token is read into a variable, never printed) --------------------
kb_call(){ # kb_call <METHOD> <path> [json body]
  if [ -n "${KB_CALL:-}" ]; then $KB_CALL "$@"; return; fi
  local port tok
  port=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  tok=$($K get secret -n "$KB_NS" kb-admin -o jsonpath='{.data.KB_ADMIN_TOKEN}' | base64 -d)
  $K port-forward -n "$KB_NS" svc/kb "$port:8080" >/dev/null 2>&1 & PF=$!
  for _ in $(seq 1 50); do curl -fsS -o /dev/null "http://127.0.0.1:$port/healthz" 2>/dev/null && break; sleep 0.2; done
  if [ $# -ge 3 ]; then
    curl -sS -X "$1" "http://127.0.0.1:$port$2" --config <(printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\nheader = "Accept: application/json, text/event-stream"\n' "$tok") -d "$3"
  else
    curl -sS -X "$1" "http://127.0.0.1:$port$2" --config <(printf 'header = "Authorization: Bearer %s"\n' "$tok")
  fi
  local rc=$?; kill "$PF" 2>/dev/null; PF=""; return $rc
}
psql_kagent(){ $K exec -n "$KAGENT_NS" kagent-pg-0 -- psql --no-psqlrc -U postgres -d kagent -tA -v ON_ERROR_STOP=1 -c "$1"; }

seed(){
  # a document in its own collection, so the sample corpus stays as the installer left it
  kb_call PUT /v1/collections/upgrade-canary/documents/canary-1 \
    "{\"title\":\"Upgrade canary\",\"text\":\"The upgrade canary code is $CANARY. It must still be found after the upgrade.\"}" >"$W/seed-kb.json" || return 1
  grep -q '"chunks"' "$W/seed-kb.json" || { echo "kb ingest answered: $(head -c 300 "$W/seed-kb.json")"; return 1; }
  # a memory row for the agent (kagent's own table; the vector is a constant, the row only has to survive)
  psql_kagent "insert into kagent.memory (agent_name, user_id, content, embedding, expires_at) values ('$KAGENT_NS/$AGENT', 'upgrade-test', 'upgrade canary memory $CANARY', array_fill(0.01::real, array[768])::extensions.vector, now() + interval '30 days')" >/dev/null
}

# ---- state: one line per fact, "<key><TAB><value>"; hashes only for anything secret ----------------------------------------------------------
sha(){ shasum -a 256 | cut -c1-16; }
state(){
  {
    $K get agents.kagent.dev -n "$KAGENT_NS" -o json 2>/dev/null | jq -r '.items[]?|["agent/"+.metadata.namespace+"/"+.metadata.name,.metadata.uid]|@tsv'
    $K get cronjobs -A -o json 2>/dev/null | jq -r --arg re "$NS_RE" '.items[]?|select(.metadata.namespace|test($re))|["cronjob/"+.metadata.namespace+"/"+.metadata.name,.metadata.uid+" suspend="+(.spec.suspend|tostring)]|@tsv'
    $K get pvc -A -o json 2>/dev/null | jq -r --arg re "$NS_RE" '.items[]?|select(.metadata.namespace|test($re))|["pvc/"+.metadata.namespace+"/"+.metadata.name,.metadata.uid]|@tsv'
    # Secrets: content hashed. The agent's gateway key and the knowledge base's Secrets; kagent's own Secrets are excluded (the controller rotates them)
    $K get secrets -A -o json 2>/dev/null | jq -r --arg re "$NS_RE" '.items[]?|select((.metadata.namespace|test($re)) and .type!="helm.sh/release.v1" and .type!="kubernetes.io/service-account-token" and ((.metadata.namespace!="'"$KAGENT_NS"'") or (.metadata.name|test("virtual-key"))))|["secret/"+.metadata.namespace+"/"+.metadata.name,((.data//{})|tojson)]|@tsv' \
      | while IFS=$'\t' read -r k v; do printf '%s\t%s\n' "$k" "$(printf '%s' "$v" | sha)"; done
    # the gateway's key ConfigMap holds the hashes of every virtual key
    $K get configmap llm-api-keys -n agentgateway-system -o json 2>/dev/null | jq -r '.data|select(.!=null)|["configmap/agentgateway-system/llm-api-keys",(tojson)]|@tsv' | while IFS=$'\t' read -r k v; do printf '%s\t%s\n' "$k" "$(printf '%s' "$v" | sha)"; done
    kb_call GET /v1/collections 2>/dev/null | jq -cS '[.collections[]?|{name,documents}]|sort_by(.name)' 2>/dev/null | sed 's/^/kb\/collections\t/'
    n=$(kb_call POST /mcp "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"kb_search\",\"arguments\":{\"query\":\"$CANARY\",\"top_k\":3}}}" 2>/dev/null | grep -c "$CANARY" || true)
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then printf 'kb/canary-found\tyes\n'; else printf 'kb/canary-found\tno\n'; fi
    psql_kagent "select count(*) || ' ' || coalesce(md5(string_agg(content, '|' order by content)),'') from kagent.memory where agent_name='$KAGENT_NS/$AGENT' and user_id='upgrade-test'" 2>/dev/null | while IFS= read -r l; do printf 'memory/upgrade-test\t%s\n' "$l"; done
  } | sort
}
agent_ready(){ $K wait "agent.kagent.dev/$AGENT" -n "$KAGENT_NS" --for=condition=Ready --timeout="${AGENT_READY_WAIT:-300s}" >/dev/null 2>&1; }
healthy(){ # healthy <label>
  local out="" _
  for _ in $(seq 1 "${HEALTH_WAIT:-240}"); do
    out=$($K get pods -A -o json 2>/dev/null | jq -r --arg re "$NS_RE" '.items[]?|select(.metadata.namespace|test($re))|select(.status.phase!="Succeeded")
      |([.status.containerStatuses[]?,.status.initContainerStatuses[]?|select(.state.waiting.reason|IN("CrashLoopBackOff","ImagePullBackOff","ErrImagePull","CreateContainerConfigError","CreateContainerError","RunContainerError"))|.state.waiting.reason]) as $w
      |([.status.conditions[]?|select(.type=="Ready")|.status]|first//"False") as $r|select($r!="True" or ($w|length)>0)|.metadata.namespace+"/"+.metadata.name+" ready="+$r+" waiting="+($w|join(","))')
    [ -z "$out" ] && break; sleep 1
  done
  if [ -z "$out" ]; then ok "$1: every pod of the platform namespaces is Ready or finished, none in CrashLoopBackOff or ImagePullBackOff"; else bad "$1: unhealthy pods" "$out"; fi
}
kept(){ # kept <label> <before file> <after file>: every fact of "before" is unchanged in "after" (new keys are allowed and listed)
  local label=$1 a=$2 b=$3 lost
  lost=$(comm -23 "$a" "$b")
  if [ -z "$lost" ]; then ok "$label ($(wc -l < "$a" | tr -d ' ') facts)"; else
    bad "$label: a fact changed or went missing (before -> after)" "$(while IFS=$'\t' read -r k v; do printf '%s: %s -> %s\n' "$k" "$v" "$(awk -F'\t' -v k="$k" '$1==k{print $2}' "$b" | head -1)"; done <<<"$lost")"
  fi
  local added; added=$(comm -13 <(cut -f1 "$a" | sort -u) <(cut -f1 "$b" | sort -u) | tr '\n' ' ')
  [ -z "$added" ] || echo "      new after the upgrade (not a failure): $added"
}

# ---- 1. the old release ------------------------------------------------------------------------------------------------------------------
echo "# 1. install $FROM from its own tag"
if [ -z "${UPGRADE_OLD_INSTALL:-}" ]; then
  git rev-parse -q --verify "refs/tags/$FROM" >/dev/null || { bad "tag $FROM is not in this checkout (run: git fetch --tags)"; summary; }
  extract_old && ok "extracted $FROM with git archive ($(git rev-parse --short "$FROM^{commit}"))" || { bad "git archive $FROM failed"; summary; }
fi
run "install $FROM (placeholder keys, bridge off, one schedule)" $OLD_INSTALL
agent_ready && ok "agent $AGENT is Ready on $FROM" || bad "agent $AGENT is not Ready on $FROM (nothing to upgrade from)" "$($K get agent.kagent.dev "$AGENT" -n "$KAGENT_NS" -o jsonpath='{.status.conditions}' 2>&1 | cut -c1-600)"
healthy "on $FROM"
run "seed state (a knowledge base document, a memory row)" seed
state > "$W/state-old"
echo "      state before the upgrade: $(wc -l < "$W/state-old" | tr -d ' ') facts"
for need in "agent/$KAGENT_NS/$AGENT" "cronjob/.*upgrade-canary" "secret/$KAGENT_NS/.*virtual-key" "configmap/agentgateway-system/llm-api-keys" "kb/collections" "memory/upgrade-test"; do
  grep -Eq "^$need" "$W/state-old" && ok "seeded or created on $FROM: $need" || bad "state to keep is missing on $FROM: $need"
done
grep -Eq "^kb/canary-found	yes" "$W/state-old" && ok "the canary is found by kb_search on $FROM" || bad "kb_search does not find the canary on $FROM"
REV_OLD=$($HELM status "$RELEASE" -n "$RELEASE_NS" -o json 2>/dev/null | jq -r '.version // empty')
[ -z "$SMOKE" ] || run "smoke on $FROM" $SMOKE

# ---- 2. upgrade A: this checkout, same values -------------------------------------------------------------------------------------------
echo "# 2. upgrade A: ./install.sh of this checkout, same values, no manual step"
run "upgrade to this checkout ($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null))" $NEW_INSTALL_A
agent_ready && ok "agent $AGENT is Ready after the upgrade" || bad "agent $AGENT is not Ready after the upgrade" "$($K get agent.kagent.dev "$AGENT" -n "$KAGENT_NS" -o jsonpath='{.status.conditions}' 2>&1 | cut -c1-600)"
healthy "after upgrade A"
check "helm release is deployed" "$($HELM status "$RELEASE" -n "$RELEASE_NS" -o json 2>/dev/null | jq -r '.info.status // "unknown"')" deployed
REV_A=$($HELM status "$RELEASE" -n "$RELEASE_NS" -o json 2>/dev/null | jq -r '.version // empty')
echo "      helm revision: ${REV_OLD:-unknown} on $FROM, ${REV_A:-unknown} after upgrade A"
state > "$W/state-a"
kept "state kept after upgrade A" "$W/state-old" "$W/state-a"
[ -z "$SMOKE" ] || run "smoke after upgrade A" $SMOKE

# ---- 3. upgrade B: the control plane (new CRD) ---------------------------------------------------------------------------------------------
if [ "${UPGRADE_SKIP_B:-0}" != 1 ]; then
  echo "# 3. upgrade B: the same, with the control plane on (the CRD agentdefinitions.openagentix.io is new in this checkout)"
  $K get crd agentdefinitions.openagentix.io >/dev/null 2>&1 && bad "the CRD already exists before upgrade B (the test cannot show it arriving)" || ok "the CRD does not exist on $FROM or after upgrade A"
  run "upgrade B (control plane on)" $NEW_INSTALL_B
  check "the CRD is Established" "$($K get crd agentdefinitions.openagentix.io -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)" True
  $K apply -f "$W/definition.yaml" >"$W/apply.log" 2>&1 && ok "an AgentDefinition is accepted by the API server" || bad "kubectl apply of an AgentDefinition failed" "$(cat "$W/apply.log")"
  $K wait agentdefinition/upgrade-check -n "$KAGENT_NS" --for=condition=Ready --timeout=600s >/dev/null 2>&1 && ok "the AgentDefinition is Ready (the control plane built its agent)" \
    || bad "the AgentDefinition did not become Ready" "$($K get agentdefinition upgrade-check -n "$KAGENT_NS" -o jsonpath='{.status}' 2>&1 | cut -c1-800)"
  agent_ready && ok "the old agent $AGENT is still Ready" || bad "the old agent $AGENT is not Ready after upgrade B"
  healthy "after upgrade B"
  state > "$W/state-b"
  kept "state still kept after upgrade B" "$W/state-old" "$W/state-b"
  $K delete agentdefinition upgrade-check -n "$KAGENT_NS" --wait=true --timeout=300s >/dev/null 2>&1 && ok "the AgentDefinition is deleted again (its finalizer ran)" || bad "the AgentDefinition did not delete"
fi
echo "# not checked: an answer from the old agent (no model: v0.2.0 has no stub model and no paid call is made), A2A gate audit lines (gate off in the v0.2.0 defaults), a request with the virtual key"
summary
