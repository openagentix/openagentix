#!/usr/bin/env bash
# Which model backs the quick start agent (ADR 0014). Sourced by install.sh; tested offline by tests/run.sh.
# The gateway model alias is always `quickstart-model`, so the AgentDefinition and the control plane policy never change.
#
# Order (the first that applies wins):
#   MODEL_PROVIDER=<name>  explicit: anthropic | openai | gemini | ollama | custom | stub
#   1. MODEL_BASE_URL      any OpenAI-compatible endpoint (with MODEL_NAME, and MODEL_API_KEY when it needs one)  -> custom
#   2. ANTHROPIC_API_KEY   -> anthropic;  OPENAI_API_KEY -> openai;  GOOGLE_API_KEY -> gemini
#   3. nothing             -> stub (the built-in scripted stand-in, NOT a language model)
# A local Ollama is used only when asked for: MODEL_PROVIDER=ollama (OLLAMA_HOST, MODEL_NAME). With MODEL_BASE_URL set, that URL is the
# Ollama endpoint (its OpenAI-compatible base, for example http://ollama.example:11434/v1).
# CLUSTER_TYPE=remote (issue #170): a local Ollama is reached at host.docker.internal or the Docker network gateway, which a managed cluster
# cannot reach, so MODEL_PROVIDER=ollama needs MODEL_BASE_URL there.

QS_ALIAS=quickstart-model

# qs_pick_model: prints the provider name; on a configuration error prints the reason to stderr and returns 1.
qs_pick_model() {
  local p=${MODEL_PROVIDER:-}
  if [ -z "$p" ]; then
    if [ -n "${MODEL_BASE_URL:-}" ]; then p=custom
    elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then p=anthropic
    elif [ -n "${OPENAI_API_KEY:-}" ]; then p=openai
    elif [ -n "${GOOGLE_API_KEY:-}" ]; then p=gemini
    else p=stub; fi
  fi
  case "$p" in
    anthropic) [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "MODEL_PROVIDER=anthropic needs ANTHROPIC_API_KEY" >&2; return 1; } ;;
    openai)    [ -n "${OPENAI_API_KEY:-}" ] || { echo "MODEL_PROVIDER=openai needs OPENAI_API_KEY" >&2; return 1; } ;;
    gemini)    [ -n "${GOOGLE_API_KEY:-}" ] || { echo "MODEL_PROVIDER=gemini needs GOOGLE_API_KEY" >&2; return 1; } ;;
    custom)
      [ -n "${MODEL_BASE_URL:-}" ] || { echo "MODEL_PROVIDER=custom needs MODEL_BASE_URL (an OpenAI-compatible base URL, for example https://host/v1)" >&2; return 1; }
      [ -n "${MODEL_NAME:-}" ] || { echo "MODEL_BASE_URL needs MODEL_NAME (the model name that endpoint expects)" >&2; return 1; }
      case "$MODEL_BASE_URL" in http://*|https://*) ;; *) echo "MODEL_BASE_URL must start with http:// or https://" >&2; return 1 ;; esac ;;
    ollama)
      if [ "${CLUSTER_TYPE:-}" = remote ] && [ -z "${MODEL_BASE_URL:-}" ]; then
        echo "MODEL_PROVIDER=ollama with CLUSTER_TYPE=remote needs MODEL_BASE_URL (an Ollama URL the cluster can reach, for example http://ollama.example:11434/v1): a local Ollama on this machine is not reachable from a remote cluster. Or use the stub model (no MODEL_PROVIDER) or a provider key." >&2; return 1
      fi
      if [ -n "${MODEL_BASE_URL:-}" ]; then
        case "$MODEL_BASE_URL" in http://*|https://*) ;; *) echo "MODEL_BASE_URL must start with http:// or https://" >&2; return 1 ;; esac
      fi ;;
    stub) ;;
    *) echo "MODEL_PROVIDER must be one of anthropic, openai, gemini, ollama, custom, stub (got: $p)" >&2; return 1 ;;
  esac
  printf '%s\n' "$p"
}

# qs_ollama_url [default host]: the OpenAI-compatible base URL of Ollama as the cluster must reach it.
qs_ollama_url() {
  local h=${OLLAMA_HOST:-${1:-host.docker.internal}}
  case "$h" in http://*|https://*) ;; *) h="http://$h" ;; esac
  case "${h#*://}" in *:*) ;; *) h="$h:11434" ;; esac
  printf '%s/v1\n' "${h%/}"
}

# qs_model_values <provider> [default ollama host]: a JSON values file (valid YAML) that replaces the stub entry, or nothing for the stub.
qs_model_values() {
  local p=$1 entry
  case "$p" in
    stub) return 0 ;;
    anthropic) entry=$(jq -nc --arg n "$QS_ALIAS" --arg m "${MODEL_NAME:-claude-haiku-5-5}" '{name:$n,provider:"Anthropic",authSecret:"anthropic-api-key",upstreamModel:$m}') ;;
    openai)    entry=$(jq -nc --arg n "$QS_ALIAS" --arg m "${MODEL_NAME:-gpt-4o-mini}" '{name:$n,provider:"OpenAI",authSecret:"openai-api-key",upstreamModel:$m}') ;;
    gemini)    entry=$(jq -nc --arg n "$QS_ALIAS" --arg m "${MODEL_NAME:-gemini-3.5-flash-lite}" '{name:$n,provider:"Gemini",authSecret:"gemini-api-key",upstreamModel:$m}') ;;
    custom)    entry=$(jq -nc --arg n "$QS_ALIAS" --arg m "$MODEL_NAME" --arg u "$MODEL_BASE_URL" --arg k "${MODEL_API_KEY:-}" \
                 '{name:$n,provider:"OpenAI",baseURL:$u,upstreamModel:$m} + (if $k!="" then {authSecret:"quickstart-model-key"} else {} end)') ;;
    ollama)    entry=$(jq -nc --arg n "$QS_ALIAS" --arg m "${MODEL_NAME:-llama3.2}" --arg u "${MODEL_BASE_URL:-$(qs_ollama_url "${2:-}")}" '{name:$n,provider:"OpenAI",baseURL:$u,upstreamModel:$m}') ;;
    *) return 1 ;;
  esac
  jq -nc --argjson e "$entry" '{gateway:{stubModel:{enabled:false},models:[$e]}}'
}

# qs_model_label <provider>: one line for the final summary.
qs_model_label() {
  case "$1" in
    stub) echo "STUB (a scripted stand-in, NOT a language model: answers are canned)" ;;
    anthropic) echo "Anthropic ${MODEL_NAME:-claude-haiku-5-5} (your ANTHROPIC_API_KEY)" ;;
    openai) echo "OpenAI ${MODEL_NAME:-gpt-4o-mini} (your OPENAI_API_KEY)" ;;
    gemini) echo "Gemini ${MODEL_NAME:-gemini-3.5-flash-lite} (your GOOGLE_API_KEY)" ;;
    custom) echo "${MODEL_NAME} at ${MODEL_BASE_URL} (OpenAI-compatible endpoint)" ;;
    ollama) echo "Ollama ${MODEL_NAME:-llama3.2} on the host (local model)" ;;
  esac
}
