#!/usr/bin/env bash
# Offline tests of the quick start model choice (components/quickstart/model.sh). No cluster, no network. Needs: jq, bash.
# Usage: components/quickstart/tests/run.sh   (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }   # eq desc actual expected
# shellcheck source=/dev/null
. "$HERE/model.sh"

# pick <VAR=value>...: the provider chosen with only these variables set
pick() { env -i PATH="$PATH" "$@" bash -c ". '$HERE/model.sh'; qs_pick_model" 2>&1; }
values() { env -i PATH="$PATH" "$@" bash -c ". '$HERE/model.sh'; p=\$(qs_pick_model) && qs_model_values \"\$p\" host.docker.internal"; }

echo "# choice"
eq "nothing set -> stub"                                   "$(pick)" stub
eq "ANTHROPIC_API_KEY -> anthropic"                        "$(pick ANTHROPIC_API_KEY=x)" anthropic
eq "OPENAI_API_KEY -> openai"                              "$(pick OPENAI_API_KEY=x)" openai
eq "GOOGLE_API_KEY -> gemini"                              "$(pick GOOGLE_API_KEY=x)" gemini
eq "Anthropic wins over OpenAI and Gemini"                 "$(pick ANTHROPIC_API_KEY=x OPENAI_API_KEY=y GOOGLE_API_KEY=z)" anthropic
eq "MODEL_BASE_URL wins over provider keys"                "$(pick MODEL_BASE_URL=http://h/v1 MODEL_NAME=m ANTHROPIC_API_KEY=x)" custom
eq "MODEL_PROVIDER=stub wins over a key"                   "$(pick MODEL_PROVIDER=stub ANTHROPIC_API_KEY=x)" stub
eq "MODEL_PROVIDER=ollama is explicit only"                "$(pick MODEL_PROVIDER=ollama)" ollama
eq "a key alone never picks ollama"                        "$(pick OLLAMA_HOST=h)" stub
eq "explicit anthropic without a key fails"                "$(pick MODEL_PROVIDER=anthropic)" "MODEL_PROVIDER=anthropic needs ANTHROPIC_API_KEY"
eq "custom without MODEL_NAME fails"                       "$(pick MODEL_BASE_URL=http://h/v1)" "MODEL_BASE_URL needs MODEL_NAME (the model name that endpoint expects)"
eq "custom with a bad scheme fails"                        "$(pick MODEL_BASE_URL=ftp://h MODEL_NAME=m)" "MODEL_BASE_URL must start with http:// or https://"
eq "unknown provider fails"                                "$(pick MODEL_PROVIDER=foo | cut -c1-42)" "MODEL_PROVIDER must be one of anthropic, o"

echo "# values"
eq "stub: no overlay"                                      "$(values)" ""
eq "anthropic: Anthropic provider, chart secret"           "$(values ANTHROPIC_API_KEY=x | jq -c '.gateway.models[0]|[.name,.provider,.authSecret,.upstreamModel]')" '["quickstart-model","Anthropic","anthropic-api-key","claude-haiku-5-5"]'
eq "anthropic: the stub is turned off"                     "$(values ANTHROPIC_API_KEY=x | jq -c '.gateway.stubModel.enabled')" false
eq "MODEL_NAME overrides the upstream model"               "$(values OPENAI_API_KEY=x MODEL_NAME=gpt-x | jq -r '.gateway.models[0].upstreamModel')" gpt-x
eq "gemini: Gemini provider and secret"                    "$(values GOOGLE_API_KEY=x | jq -c '.gateway.models[0]|[.provider,.authSecret]')" '["Gemini","gemini-api-key"]'
eq "custom with a key: OpenAI provider, base URL, secret"  "$(values MODEL_BASE_URL=https://h/v1 MODEL_NAME=m MODEL_API_KEY=k | jq -c '.gateway.models[0]|[.provider,.baseURL,.authSecret,.upstreamModel]')" '["OpenAI","https://h/v1","quickstart-model-key","m"]'
eq "custom without a key: no auth secret"                  "$(values MODEL_BASE_URL=https://h/v1 MODEL_NAME=m | jq -c '.gateway.models[0]|has("authSecret")')" false
eq "ollama: default host and model"                        "$(values MODEL_PROVIDER=ollama | jq -c '.gateway.models[0]|[.baseURL,.upstreamModel,has("authSecret")]')" '["http://host.docker.internal:11434/v1","llama3.2",false]'
eq "ollama: OLLAMA_HOST without scheme or port"            "$(values MODEL_PROVIDER=ollama OLLAMA_HOST=172.18.0.1 | jq -r '.gateway.models[0].baseURL')" http://172.18.0.1:11434/v1
eq "ollama: OLLAMA_HOST as a full URL is kept"             "$(values MODEL_PROVIDER=ollama OLLAMA_HOST=http://box:9999/ MODEL_NAME=qwen | jq -c '.gateway.models[0]|[.baseURL,.upstreamModel]')" '["http://box:9999/v1","qwen"]'
eq "a key is never written into the overlay"               "$(values ANTHROPIC_API_KEY=SENTINEL-KEY MODEL_API_KEY=SENTINEL-KEY | /usr/bin/grep -c SENTINEL)" 0

echo "# label"
eq "stub label says it is not a model"                     "$(qs_model_label stub | /usr/bin/grep -c 'NOT a language model')" 1

echo "# preflight: secrets are derived from what the chart renders (issue #33)"
# shellcheck source=/dev/null
. "$HERE/preflight.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
render() { helm template openagentix "$ROOT/charts/openagentix" -n openagentix-system --api-versions agentkourier.dev/v1alpha1 "$@" | yq -c 'select(.!=null)'; }
none() { return 1; }                         # no Secret exists in the cluster
have() { return 0; }                         # every Secret exists
DEF=$(render); QSR=$(render -f "$ROOT/components/quickstart/values.yaml")
sp() { local r=$1; shift; env -i PATH="$PATH" "$@" bash -c ". '$HERE/preflight.sh'; preflight_secret_problems \"\$0\" none" "$r" 2>&1; }
spf() { local r=$1; shift; (unset ANTHROPIC_API_KEY TELEGRAM_BOT_TOKEN OPENAI_API_KEY GOOGLE_API_KEY MODEL_API_KEY; "$@" ; preflight_secret_problems "$r" none); }
eq "default chart, nothing set: asks for both"             "$(spf "$DEF" true | wc -l | tr -d ' ')" 2
eq "default chart: the Anthropic key is named"             "$(spf "$DEF" true | /usr/bin/grep -c '^ANTHROPIC_API_KEY is not set')" 1
eq "default chart: the Telegram token is named"            "$(spf "$DEF" true | /usr/bin/grep -c '^TELEGRAM_BOT_TOKEN is not set')" 1
eq "default chart, both set: nothing to say"               "$(spf "$DEF" export ANTHROPIC_API_KEY=x TELEGRAM_BOT_TOKEN=y)" ""
eq "default chart, Secrets exist in the cluster"           "$(preflight_secret_problems "$DEF" have)" ""
eq "quick start with the stub: no key, no token"           "$(spf "$QSR" true)" ""
QSA=$(render -f "$ROOT/components/quickstart/values.yaml" -f <(ANTHROPIC_API_KEY=x bash -c ". '$HERE/model.sh'; qs_model_values anthropic"))
eq "quick start with an Anthropic model: asks for the key" "$(spf "$QSA" true | /usr/bin/grep -c '^ANTHROPIC_API_KEY is not set')" 1
eq "quick start with an Anthropic model, key set"          "$(spf "$QSA" export ANTHROPIC_API_KEY=x)" ""
eq "quick start never asks for a Telegram token"           "$(spf "$QSA" true | /usr/bin/grep -c TELEGRAM)" 0

echo "# preflight: the placeholder skill digest (issue #9)"
eq "default chart, SKIP_SKILL unset: the installer pins it" "$(preflight_skill_problems "$DEF" 0)" ""
eq "default chart, SKIP_SKILL=1: refused with the reason"  "$(preflight_skill_problems "$DEF" 1 | /usr/bin/grep -c 'SKIP_SKILL=1 stops install.sh')" 1
eq "a real digest passes with SKIP_SKILL=1"                "$(preflight_skill_problems "$(render --set skills.openagentix-canary.oci=reg.example/s/x@sha256:$(printf "a%.0s" $(seq 1 64)))" 1)" ""
eq "quick start has no skill: SKIP_SKILL=1 is harmless"    "$(preflight_skill_problems "$QSR" 1)" ""
eq "another skill left at the placeholder is refused"      "$(preflight_skill_problems '{"kind":"AgentTemplate","metadata":{"name":"t"},"spec":{"skills":[{"source":{"oci":"registry.invalid:5000/skills/other@sha256:0000000000000000000000000000000000000000000000000000000000000000"}}]}}' 0 | /usr/bin/grep -c 'pins only the example skill')" 1

echo "# install.sh refuses early, before it touches a cluster (every case below must stop at the preflight)"
inst() { env -i PATH="$PATH" HOME="$HOME" CLUSTER=oa-unit-test-never-created CREATE_CLUSTER=0 "$@" bash "$ROOT/install.sh" 2>&1; echo "exit=$?"; }
OUT=$(inst); eq "default install, no key, no token: both asked"  "$(/usr/bin/grep -cE 'ANTHROPIC_API_KEY is not set|TELEGRAM_BOT_TOKEN is not set' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 2/1
OUT=$(inst ANTHROPIC_API_KEY=x TELEGRAM_BOT_TOKEN=y SKIP_SKILL=1); eq "SKIP_SKILL=1 with the placeholder skill stops early" "$(/usr/bin/grep -c 'SKIP_SKILL=1 stops install.sh' <<<"$OUT")/$(/usr/bin/grep -c 'Nothing was changed' <<<"$OUT")" 1/1
OUT=$(inst PROFILE=quickstart MODEL_PROVIDER=anthropic); eq "quickstart with MODEL_PROVIDER=anthropic and no key stops" "$(/usr/bin/grep -c 'needs ANTHROPIC_API_KEY' <<<"$OUT")" 1
OUT=$(inst PROFILE=nope); eq "an unknown profile is refused"      "$(/usr/bin/grep -c "unknown PROFILE 'nope'" <<<"$OUT")" 1
OUT=$(inst PROFILE=quickstart); eq "quickstart with no model env passes the preflight (stops only at the missing cluster)" "$(/usr/bin/grep -c 'does not exist and CREATE_CLUSTER=0' <<<"$OUT")" 1

echo "# kagent's own PostgreSQL is ready only when its final server is up"
RUNTIME="$(cd "$HERE/../runtime" && pwd)"
eq "readiness probe uses TCP (the first-boot temporary server has no TCP port)" "$(/usr/bin/grep -cE 'readinessProbe:.*pg_isready.*-h, 127\.0\.0\.1' "$RUNTIME/manifests/kagent-postgres.yaml")" 1
eq "up.sh waits for a working psql before the setup script" "$(/usr/bin/grep -n "select 1" "$RUNTIME/up.sh" | head -1 | cut -d: -f1 | awk -v s="$(/usr/bin/grep -n 'rollout status sts/kagent-pg' "$RUNTIME/up.sh" | cut -d: -f1)" '{print ($1>s && $1<s+3)?"yes":"no"}')" yes

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
