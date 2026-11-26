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

echo "# a local Ollama on a remote cluster (issue #170)"
eq "remote + ollama without MODEL_BASE_URL is refused"     "$(pick CLUSTER_TYPE=remote MODEL_PROVIDER=ollama | /usr/bin/grep -c 'MODEL_PROVIDER=ollama with CLUSTER_TYPE=remote needs MODEL_BASE_URL')" 1
eq "the refusal names the stub and a provider key"         "$(pick CLUSTER_TYPE=remote MODEL_PROVIDER=ollama | /usr/bin/grep -c 'stub model.*provider key')" 1
eq "remote + ollama with MODEL_BASE_URL passes"            "$(pick CLUSTER_TYPE=remote MODEL_PROVIDER=ollama MODEL_BASE_URL=http://ollama.example:11434/v1)" ollama
eq "remote + ollama: MODEL_BASE_URL is the base URL"       "$(values CLUSTER_TYPE=remote MODEL_PROVIDER=ollama MODEL_BASE_URL=http://ollama.example:11434/v1 | jq -r '.gateway.models[0].baseURL')" http://ollama.example:11434/v1
eq "ollama with a bad MODEL_BASE_URL scheme fails"         "$(pick CLUSTER_TYPE=remote MODEL_PROVIDER=ollama MODEL_BASE_URL=ftp://h)" "MODEL_BASE_URL must start with http:// or https://"
eq "kind + ollama is unchanged"                            "$(pick CLUSTER_TYPE=kind MODEL_PROVIDER=ollama)/$(values CLUSTER_TYPE=kind MODEL_PROVIDER=ollama | jq -r '.gateway.models[0].baseURL')" ollama/http://host.docker.internal:11434/v1
eq "k3d + ollama is unchanged"                             "$(pick CLUSTER_TYPE=k3d MODEL_PROVIDER=ollama)" ollama
eq "remote with nothing set is still the stub"             "$(pick CLUSTER_TYPE=remote)" stub

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

echo "# install.sh with CLUSTER_TYPE=remote (issues #161, #170): no kind, no k3d on PATH; fake kubectl and docker record every call"
RT=$(mktemp -d); trap 'rm -rf "$RT"' EXIT
mkdir -p "$RT/bin"
for c in helm jq yq openssl shasum; do ln -s "$(command -v "$c")" "$RT/bin/$c"; done
cat > "$RT/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$RT/calls"
case "\$*" in *"get --raw /version"*) [ "\${FAKE_API:-}" = up ] || exit 1; echo '{}';; *"get secret"*) exit 1;; esac
exit 0
EOS
cat > "$RT/bin/docker" <<EOS
#!/usr/bin/env bash
echo "docker \$*" >> "$RT/calls"
exit 0
EOS
chmod +x "$RT/bin/kubectl" "$RT/bin/docker"
RPATH="$RT/bin:/usr/bin:/bin"
rinst() { : > "$RT/calls"; env -i PATH="$RPATH" HOME="$HOME" CLUSTER_TYPE=remote SKIP_PREFLIGHT=1 "$@" bash "$ROOT/install.sh" 2>&1; echo "exit=$?"; }
if PATH="$RPATH" command -v kind >/dev/null || PATH="$RPATH" command -v k3d >/dev/null; then
  echo "  skip the remote install.sh cases: kind or k3d is in /usr/bin or /bin"
else
  OUT=$(rinst PROFILE=quickstart); eq "remote without KUBE_CONTEXT stops with the reason" "$(/usr/bin/grep -c 'CLUSTER_TYPE=remote needs KUBE_CONTEXT' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "remote without KUBE_CONTEXT calls nothing" "$(cat "$RT/calls")" ""
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=kind-openagentix FAKE_API=up); eq "remote with a local kind context is refused" "$(/usr/bin/grep -c 'ALLOW_LOCAL_CONTEXT=1' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "a refused local context is never contacted" "$(cat "$RT/calls")" ""
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c); eq "remote, API server not reachable: stops, never creates" "$(/usr/bin/grep -c "cannot reach the API server of kube context 'gke_p_z_c'" <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "remote preflight does not ask for kind or k3d" "$(/usr/bin/grep -c 'missing tools' <<<"$OUT")" 0
  eq "remote asks the API server of the named context" "$(/usr/bin/grep -c '^kubectl --context gke_p_z_c get --raw /version$' "$RT/calls")" 1
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up); eq "remote quick start: refused before any build (no registry push yet)" "$(/usr/bin/grep -c 'IMAGE_REGISTRY, issue #162' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "remote quick start: the refusal names the images" "$(/usr/bin/grep -c 'These would be built:.*openagentix/stub-model:dev-' <<<"$OUT")" 1
  eq "remote quick start: no docker build, no docker exec, no load" "$(/usr/bin/grep -cE '^docker (build|exec)|^kind|^k3d' "$RT/calls")" 0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up QUICKSTART_BYO=1); eq "remote with QUICKSTART_BYO=1 is refused" "$(/usr/bin/grep -c 'QUICKSTART_BYO=1 does not work with CLUSTER_TYPE=remote yet' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up MODEL_PROVIDER=ollama); eq "remote with a local Ollama is refused (issue #170)" "$(/usr/bin/grep -c 'needs MODEL_BASE_URL' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  OUT=$(rinst KUBE_CONTEXT=gke_p_z_c FAKE_API=up ANTHROPIC_API_KEY=x TELEGRAM_BOT_TOKEN=y SKIP_BRIDGE_IMAGE=1 SKIP_KB_IMAGE=1); eq "remote with the example skill: refused, says SKIP_SKILL=1" "$(/usr/bin/grep -c 'example skill.*SKIP_SKILL=1' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  OUT=$(rinst KUBE_CONTEXT=gke_p_z_c FAKE_API=up)   # default chart, no key: the preflight looks for the key Secrets in the cluster
  eq "the preflight reads Secrets from the named context only (never the current one)" "$(/usr/bin/grep -c ' get secret ' "$RT/calls" | awk '{print ($1>0)?"some":"none"}')/$(/usr/bin/grep ' get secret ' "$RT/calls" | /usr/bin/grep -vc -- '--context=gke_p_z_c')" some/0
  # the preflight (issue #168) is skipped above (SKIP_PREFLIGHT=1) so these cases reach the refusals; here it runs, and the fake API server's answer ("{}") has no version
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up SKIP_PREFLIGHT=0); eq "remote: the preflight runs and a FAIL stops the install before any change" "$(/usr/bin/grep -c 'the preflight found a problem in cluster .gke_p_z_c.' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "remote: the preflight only reads (every kubectl call is a get)" "$(/usr/bin/grep -v '^kubectl --context gke_p_z_c get ' "$RT/calls" | /usr/bin/grep -c .)" 0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up NODE_SETTINGS=bogus); eq "an unknown NODE_SETTINGS is refused at the start" "$(/usr/bin/grep -c "unknown NODE_SETTINGS 'bogus'" <<<"$OUT")" 1
fi
eq "the install.sh header lists CLUSTER_TYPE=remote, ALLOW_LOCAL_CONTEXT and NODE_SETTINGS" "$(sed -n '1,/^set -euo pipefail/p' "$ROOT/install.sh" | /usr/bin/grep -cE 'CLUSTER_TYPE=remote|ALLOW_LOCAL_CONTEXT=1|NODE_SETTINGS=daemonset' | awk '{print ($1>=3)?"yes":"no"}')" yes

echo "# the minimal profile and the install order (issue #29)"
OUT=$(inst PROFILE=minimal); eq "PROFILE=minimal passes the preflight (stops only at the missing cluster)" "$(/usr/bin/grep -c 'does not exist and CREATE_CLUSTER=0' <<<"$OUT")" 1
OUT=$(inst PROFILE=minimal QUICKSTART_BYO=1); eq "PROFILE=minimal accepts QUICKSTART_BYO=1" "$(/usr/bin/grep -c 'does not exist and CREATE_CLUSTER=0' <<<"$OUT")" 1
OUT=$(inst PROFILE=minimal MODEL_PROVIDER=anthropic); eq "PROFILE=minimal uses the same model choice (anthropic without a key stops)" "$(/usr/bin/grep -c 'needs ANTHROPIC_API_KEY' <<<"$OUT")" 1
OUT=$(inst PROFILE=minimal SKIP_SKILL=1); eq "PROFILE=minimal needs no skill: SKIP_SKILL=1 is harmless" "$(/usr/bin/grep -c 'does not exist and CREATE_CLUSTER=0' <<<"$OUT")" 1
MINR=$(render -f "$ROOT/components/quickstart/values.yaml" -f "$ROOT/components/quickstart/minimal-values.yaml")
eq "minimal with the stub: no key, no token"              "$(spf "$MINR" true)" ""
INS="$ROOT/install.sh"
line() { /usr/bin/grep -n "$1" "$INS" | head -1 | cut -d: -f1; }
eq "image builds start before the cluster step"           "$([ "$(line '^start_builds$')" -lt "$(line '^log "cluster ')" ] && echo yes || echo no)" yes
eq "the build results are collected before the chart"     "$([ "$(line '^finish_builds   #')" -lt "$(line '^helm upgrade --install')" ] && echo yes || echo no)" yes
eq "the end summary names the console only when the chart renders it" "$(/usr/bin/grep -B2 'Open the console:' "$INS" | /usr/bin/grep -c 'if \[ -n "\$CN_DEP" \]')" 1
eq "install.sh waits for its own RemoteMCPServers, not for kagent's built-in ones" "$(/usr/bin/grep -c 'wait remotemcpserver --all' "$INS")/$(/usr/bin/grep -c 'select(.kind=="RemoteMCPServer")' "$INS")" 0/1
eq "the independent prerequisites overlap (PREREQS_PARALLEL)" "$(/usr/bin/grep -c 'PREREQS_PARALLEL' "$INS" | awk '{print ($1>0)?"yes":"no"}')" yes

echo "# kagent's own PostgreSQL is ready only when its final server is up"
RUNTIME="$(cd "$HERE/../runtime" && pwd)"
eq "readiness probe uses TCP (the first-boot temporary server has no TCP port)" "$(/usr/bin/grep -cE 'readinessProbe:.*pg_isready.*-h, 127\.0\.0\.1' "$RUNTIME/manifests/kagent-postgres.yaml")" 1
eq "up.sh waits for a working psql before the setup script" "$(/usr/bin/grep -n "select 1" "$RUNTIME/up.sh" | head -1 | cut -d: -f1 | awk -v s="$(/usr/bin/grep -n 'rollout status sts/kagent-pg' "$RUNTIME/up.sh" | cut -d: -f1)" '{print ($1>s && $1<s+3)?"yes":"no"}')" yes

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
