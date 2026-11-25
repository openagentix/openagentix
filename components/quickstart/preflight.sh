#!/usr/bin/env bash
# Preflight checks of install.sh, derived from what the chart RENDERS (ADR 0014; issues #33 and #9). Sourced by install.sh and tested offline
# by tests/run.sh. Each function reads the rendered documents (one JSON object per line) and prints one problem per line; no output means fine.

# preflight_secret_problems <rendered> <secret_exists_fn>: a Telegram token only when the chart renders the bridge, and a provider key only
# for a provider secret that a rendered gateway model uses. A Secret that already exists in the cluster counts as configured.
# <secret_exists_fn> <namespace> <name> succeeds when the Secret exists.
preflight_secret_problems() {
  local rendered=$1 exists=$2 ns name var
  ns=${GW_NS:-agentgateway-system}
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in
      anthropic-api-key) var=ANTHROPIC_API_KEY; hint="export ANTHROPIC_API_KEY=sk-ant-..." ;;
      gemini-api-key) var=GOOGLE_API_KEY; hint="export GOOGLE_API_KEY=..." ;;
      openai-api-key) var=OPENAI_API_KEY; hint="export OPENAI_API_KEY=sk-..." ;;
      quickstart-model-key) var=MODEL_API_KEY; hint="export MODEL_API_KEY=... (the key of your MODEL_BASE_URL endpoint)" ;;
      *) var=""; hint="create it with the key name Authorization" ;;
    esac
    if [ -n "$var" ] && [ -n "${!var:-}" ]; then continue; fi
    "$exists" "$ns" "$name" && continue
    if [ -n "$var" ]; then echo "$var is not set and Secret $ns/$name does not exist. A gateway model uses it. $hint"
    else echo "Secret $ns/$name does not exist. A gateway model uses it: $hint"; fi
  done < <(jq -r 'select(.kind=="AgentgatewayModel")|.spec.policies.auth.secretRef.name // empty' <<<"$rendered" | sort -u)
  if jq -e 'select(.kind=="Deployment" and .metadata.name=="telegram-bridge")' <<<"$rendered" >/dev/null 2>&1; then
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && ! "$exists" "${BRIDGE_NS:-openagentix-gateway}" "${BRIDGE_SECRET:-telegram-bridge}"; then
      echo "TELEGRAM_BOT_TOKEN is not set and Secret ${BRIDGE_NS:-openagentix-gateway}/${BRIDGE_SECRET:-telegram-bridge} does not exist. The Telegram bridge is on in these values. Create a bot with @BotFather, then: export TELEGRAM_BOT_TOKEN=...  (or turn the bridge off: bridge.enabled=false, or use PROFILE=quickstart)"
    fi
  fi
}

# preflight_skill_problems <rendered> <skip_skill>: a skill that would be deployed with the placeholder reference (registry.invalid, an
# all-zero digest). install.sh replaces it only for the example skill and only when it builds it (SKIP_SKILL is not 1).
preflight_skill_problems() {
  local rendered=$1 skip=${2:-0}
  jq -r --arg skip "$skip" '
    select(.kind=="AgentTemplate") | .metadata.name as $t | .spec.skills[]? | .source.oci as $o
    | select($o|test("registry\\.invalid|sha256:0{64}$"))
    | select($skip=="1" or ($o|test("/skills/openagentix-canary@")|not))
    | "agent template \($t) uses the skill \($o), a placeholder that cannot be pulled. "
      + (if $skip=="1" then "SKIP_SKILL=1 stops install.sh from building and pinning the example skill: unset SKIP_SKILL, or set skills.<name>.oci to a real digest-pinned reference (name@sha256:<64 hex>) in your values."
         else "Set skills.<name>.oci to a real digest-pinned reference (name@sha256:<64 hex>) in your values: install.sh pins only the example skill openagentix-canary." end)' <<<"$rendered" | sort -u
}
