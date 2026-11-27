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
case "\$*" in *"get --raw /version"*) [ "\${FAKE_API:-}" = up ] || exit 1; echo '{}';; *"get secret"*"-o jsonpath"*) echo ZmFrZQ==;; *"get secret"*) exit 1;;
  *"get storageclass -o json"*) [ -n "\${FAKE_SC:-}" ] || exit 1; echo "\$FAKE_SC";;
  *"get clustertrustbundle"*) echo FAKE-PUBLIC-CA;;
  *"apply -f "*byo.json*) cp "\${@: -1}" "$RT/byo-applied.json";; esac
exit 0
EOS
# fake docker: buildx build writes the metadata file a real push writes (FAKE_META=nodigest: one without a digest); buildx version fails with FAKE_BUILDX=no
cat > "$RT/bin/docker" <<EOS
#!/usr/bin/env bash
echo "docker \$*" >> "$RT/calls"
case "\$1 \$2" in
  "buildx version") [ "\${FAKE_BUILDX:-}" != no ] || exit 1;;
  "buildx build") m=""; for a in "\$@"; do [ "\$m" = next ] && m=\$a; [ "\$a" = --metadata-file ] && m=next; done
    if [ "\${FAKE_META:-}" = nodigest ]; then echo '{}' > "\$m"; else echo '{"containerimage.digest":"sha256:$(printf 'b%.0s' $(seq 64))"}' > "\$m"; fi;;
  "buildx imagetools") case "\$*" in *@sha256:*) case "\$*" in *--raw*) echo '{}';; *) echo '{"os":"linux","architecture":"amd64"}';; esac;; *) exit 1;; esac;;   # a tag: not in the registry
esac
exit 0
EOS
# fake helm: template and lint are the real helm; upgrade records its arguments and a copy of each values file, then fails (the install stops there)
REAL_HELM=$(command -v helm); rm -f "$RT/bin/helm"
cat > "$RT/bin/helm" <<EOS
#!/usr/bin/env bash
case "\$1" in template|lint|version) exec "$REAL_HELM" "\$@";; esac
echo "helm \$*" >> "$RT/calls"
if [ "\$1" = upgrade ]; then n=0; prev=""; for a in "\$@"; do [ "\$prev" = -f ] && { n=\$((n+1)); cp "\$a" "$RT/values-\$n"; }; prev=\$a; done
  # the same arguments rendered by the real helm: the images the cluster would get
  a=(); skip=0; for x in "\${@:3}"; do [ \$skip = 1 ] && { skip=0; continue; }; case "\$x" in --wait|--create-namespace) ;; --timeout) skip=1;; *) a+=("\$x");; esac; done
  "$REAL_HELM" template "\${a[@]}" | yq -r 'select(.!=null)|(.spec.template.spec.containers[]?.image, .spec.jobTemplate.spec.template.spec.containers[]?.image)' | sort -u > "$RT/rendered-images"
  exit "\${FAKE_HELM_UPGRADE:-1}"
fi
[ "\$1 \$2" = "get manifest" ] && [ "\${FAKE_HELM_UPGRADE:-1}" = 0 ] && exit 0   # after a good upgrade: an empty manifest
exit 1
EOS
chmod +x "$RT/bin/kubectl" "$RT/bin/docker" "$RT/bin/helm"
RPATH="$RT/bin:/usr/bin:/bin"
rinst() { : > "$RT/calls"; rm -f "$RT"/values-* "$RT/byo-applied.json"; env -i PATH="$RPATH" HOME="$HOME" CLUSTER_TYPE=remote SKIP_PREFLIGHT=1 "$@" bash "$ROOT/install.sh" 2>&1; echo "exit=$?"; }
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
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up); eq "remote quick start without IMAGE_REGISTRY: refused before any build" "$(/usr/bin/grep -c 'CLUSTER_TYPE=remote needs IMAGE_REGISTRY' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "remote quick start: the refusal names the images" "$(/usr/bin/grep -c 'These would be built:.*openagentix/stub-model:dev-' <<<"$OUT")" 1
  eq "remote quick start: no docker build, no docker exec, no load" "$(/usr/bin/grep -cE '^docker (build|exec)|^kind|^k3d' "$RT/calls")" 0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up QUICKSTART_BYO=1); eq "remote with QUICKSTART_BYO=1 and no IMAGE_REGISTRY is refused, names the sample" "$(/usr/bin/grep -c 'needs IMAGE_REGISTRY.*registry.local/oa/echo-a2a:dev-' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up MODEL_PROVIDER=ollama); eq "remote with a local Ollama is refused (issue #170)" "$(/usr/bin/grep -c 'needs MODEL_BASE_URL' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  OUT=$(rinst KUBE_CONTEXT=gke_p_z_c FAKE_API=up ANTHROPIC_API_KEY=x TELEGRAM_BOT_TOKEN=y SKIP_BRIDGE_IMAGE=1 SKIP_KB_IMAGE=1); eq "remote with the example skill: refused, says SKIP_SKILL=1" "$(/usr/bin/grep -c 'example skill.*SKIP_SKILL=1' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  OUT=$(rinst KUBE_CONTEXT=gke_p_z_c FAKE_API=up)   # default chart, no key: the preflight looks for the key Secrets in the cluster
  eq "the preflight reads Secrets from the named context only (never the current one)" "$(/usr/bin/grep -c ' get secret ' "$RT/calls" | awk '{print ($1>0)?"some":"none"}')/$(/usr/bin/grep ' get secret ' "$RT/calls" | /usr/bin/grep -vc -- '--context=gke_p_z_c')" some/0
  # the preflight (issue #168) is skipped above (SKIP_PREFLIGHT=1) so these cases reach the refusals; here it runs, and the fake API server's answer ("{}") has no version
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up SKIP_PREFLIGHT=0); eq "remote: the preflight runs and a FAIL stops the install before any change" "$(/usr/bin/grep -c 'the preflight found a problem in cluster .gke_p_z_c.' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "remote: the preflight only reads (every kubectl call is a get)" "$(/usr/bin/grep -v '^kubectl --context gke_p_z_c get ' "$RT/calls" | /usr/bin/grep -c .)" 0
  # SET_DEFAULT_STORAGECLASS: a read-only check before anything changes; a refusal stops the install with no write
  SC_NONE='{"items":[{"metadata":{"name":"standard-rwo"}},{"metadata":{"name":"premium-rwo"}}]}'
  SC_OTHER='{"items":[{"metadata":{"name":"standard-rwo"}},{"metadata":{"name":"premium-rwo","annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}'
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up SET_DEFAULT_STORAGECLASS=nope FAKE_SC="$SC_NONE"); eq "remote, SET_DEFAULT_STORAGECLASS names a missing class: refused, exit 1" "$(/usr/bin/grep -c 'SET_DEFAULT_STORAGECLASS=nope was refused' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")" 1/1
  eq "remote, a refused class: no patch and no build" "$(/usr/bin/grep -cE ' patch |^docker build' "$RT/calls")" 0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up SET_DEFAULT_STORAGECLASS=standard-rwo FAKE_SC="$SC_OTHER"); eq "remote, another class is already default: refused" "$(/usr/bin/grep -c 'premium-rwo is already the default StorageClass' <<<"$OUT")/$(/usr/bin/grep -c 'SET_DEFAULT_STORAGECLASS=standard-rwo was refused' <<<"$OUT")" 1/1
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up SET_DEFAULT_STORAGECLASS=standard-rwo FAKE_SC="$SC_NONE"); eq "remote, a class that can be marked: the check passes, the later refusal still stops before any change" "$(/usr/bin/grep -c 'standard-rwo will be marked as the default in context gke_p_z_c' <<<"$OUT")/$(/usr/bin/grep -c 'CLUSTER_TYPE=remote needs IMAGE_REGISTRY' <<<"$OUT")" 1/1
  eq "remote, the check only reads: no patch before step 1" "$(/usr/bin/grep -c ' patch ' "$RT/calls")" 0
  eq "remote, the check names the context" "$(/usr/bin/grep -c '^kubectl --context gke_p_z_c get storageclass -o json$' "$RT/calls")" 1
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up FAKE_SC="$SC_NONE"); eq "without SET_DEFAULT_STORAGECLASS the storage classes are not touched" "$(/usr/bin/grep -c 'storageclass' "$RT/calls")" 0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up NODE_SETTINGS=bogus); eq "an unknown NODE_SETTINGS is refused at the start" "$(/usr/bin/grep -c "unknown NODE_SETTINGS 'bogus'" <<<"$OUT")" 1

  echo "# install.sh with CLUSTER_TYPE=remote and IMAGE_REGISTRY (ADR 0022): build with buildx, push, the chart gets repository, tag and digest"
  REG=europe-west4-docker.pkg.dev/proj/oa; DGB=sha256:$(printf 'b%.0s' $(seq 64)); CANARY=canary-$RANDOM$RANDOM
  PUSH=(SKIP_PREREQS=1 CONTROL_PLANE_APISERVER_CIDRS=10.0.0.1/32 CONSOLE_APISERVER_CIDRS=10.0.0.1/32)   # no prerequisites; the API server addresses a fake cluster cannot give
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG DOCKER_PASSWORD=$CANARY REGISTRY_TOKEN=$CANARY GOOGLE_OAUTH_ACCESS_TOKEN=$CANARY)
  NB=$(/usr/bin/grep -c '^docker buildx build ' "$RT/calls")
  eq "remote push: the install reaches helm upgrade" "$(/usr/bin/grep -c '^helm upgrade --install openagentix' "$RT/calls")" 1
  eq "remote push: buildx is checked before the builds" "$(/usr/bin/grep -c '^docker buildx version' "$RT/calls")" 1
  eq "remote push: each tag is looked up in the registry first, each pushed digest checked after" "$(/usr/bin/grep -c "^docker buildx imagetools inspect $REG/openagentix/[a-z0-9-]*:dev-[0-9a-f]\{16\}-amd64 " "$RT/calls")/$(/usr/bin/grep -c "^docker buildx imagetools inspect --raw $REG/openagentix/[a-z0-9-]*@$DGB$" "$RT/calls")" "$NB/$NB"
  eq "remote push: at least the stub model and the control plane are built" "$([ "$NB" -ge 2 ] && echo yes || echo "no ($NB)")" yes
  eq "remote push: every build is buildx --platform linux/amd64 --push, provenance and sbom off, with a metadata file" "$(/usr/bin/grep -c "^docker buildx build --platform linux/amd64 --push --provenance=false --sbom=false --metadata-file [^ ]*/build-[0-9]*.json -q -t $REG/openagentix/[a-z0-9-]*:dev-[0-9a-f]\{16\}-amd64 " "$RT/calls")" "$NB"
  eq "remote push: one 'pushed' line per build, with the digest" "$(/usr/bin/grep -c "^pushed $REG/openagentix/[a-z0-9-]*@$DGB " <<<"$OUT")" "$NB"
  UP=$(/usr/bin/grep '^helm upgrade' "$RT/calls")
  for pn in "gateway.stubModel stub-model" "controlPlane control-plane" "console console" "governance.a2a a2a-gate"; do
    set -- $pn
    if /usr/bin/grep -q "openagentix/$2:dev-" "$RT/calls"; then
      eq "remote push: $1 gets repository, tag and digest" "$(/usr/bin/grep -c -- "--set-string $1.image.repository=$REG/openagentix/$2 .*--set-string $1.image.tag=dev-[0-9a-f]\{16\}-amd64 .*--set-string $1.image.digest=$DGB" <<<"$UP")" 1
    fi
  done
  eq "remote push: as many digests as builds go to the chart" "$(/usr/bin/grep -o -- "--set-string [a-zA-Z0-9.]*\.image\.digest=$DGB" <<<"$UP" | wc -l | tr -d ' ')" "$NB"
  eq "remote push: every image the chart renders from IMAGE_REGISTRY is repository:tag@digest" "$(/usr/bin/grep "^$REG/" "$RT/rendered-images" | /usr/bin/grep -vc "^$REG/openagentix/[a-z0-9-]*:dev-[0-9a-f]\{16\}-amd64@$DGB$")/$(/usr/bin/grep -c "^$REG/" "$RT/rendered-images")" "0/$NB"
  eq "remote push: no image of the chart is left on the openagentix/ default" "$(/usr/bin/grep -c '^openagentix/' "$RT/rendered-images")" 0
  eq "remote push: no kind, no k3d, no docker exec, no plain docker build, no image inspect, no docker login" "$(/usr/bin/grep -cE '^kind|^k3d|^docker (exec|build |image|login|push|tag)' "$RT/calls")" 0
  eq "remote push: a credential in the environment never reaches an argument or the log" "$(cat "$RT/calls" | /usr/bin/grep -c "$CANARY")/$(/usr/bin/grep -c "$CANARY" <<<"$OUT")" 0/0
  # every image the installer builds (the full demo values, plus the stub model): all eight chart paths get repository, tag and digest
  printf 'gateway: {stubModel: {enabled: true}}\nskills:\n  openagentix-canary:\n    oci: reg.example/skills/openagentix-canary@sha256:%s\n' "$(printf 'c%.0s' $(seq 64))" > "$RT/all.yaml"
  ALLV="$RT/all.yaml"; for f in schedules/demo-values.yaml notify/demo-values.yaml governance/demo-values.yaml governance/profiles-demo-values.yaml control-plane/demo-values.yaml console/demo-values.yaml; do ALLV="$ALLV $ROOT/components/$f"; done
  OUT=$(rinst KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" KOURIER_APISERVER_CIDRS=10.0.0.1/32 SKIP_SKILL=1 ANTHROPIC_API_KEY=x TELEGRAM_BOT_TOKEN=y TELEGRAM_ALLOWED_CHAT_IDS=1 IMAGE_REGISTRY=$REG VALUES_FILE="$ALLV")
  eq "remote push, all images: eight buildx pushes" "$(/usr/bin/grep -c "^docker buildx build --platform linux/amd64 --push --provenance=false --sbom=false --metadata-file .* -t $REG/openagentix/" "$RT/calls")" 8
  UP=$(/usr/bin/grep '^helm upgrade' "$RT/calls")
  for pn in "bridge telegram" "scheduling a2a-call" "gateway.stubModel stub-model" "knowledge.kb kb" "notify notify" "governance.a2a a2a-gate" "controlPlane control-plane" "console console"; do
    set -- $pn
    eq "remote push, all images: $1 gets $REG/openagentix/$2, the tag and the digest" "$(/usr/bin/grep -c -- "--set-string $1.image.repository=$REG/openagentix/$2 .*--set-string $1.image.tag=dev-[0-9a-f]\{16\}-amd64 .*--set-string $1.image.digest=$DGB" <<<"$UP")" 1
  done
  eq "remote push, all images: the chart renders eight images from IMAGE_REGISTRY, each repository:tag@digest" "$(/usr/bin/grep -c "^$REG/openagentix/[a-z0-9-]*:dev-[0-9a-f]\{16\}-amd64@$DGB$" "$RT/rendered-images")/$(/usr/bin/grep -c "^$REG/" "$RT/rendered-images")" 8/8
  eq "remote push, all images: no image of the chart is left on the openagentix/ default" "$(/usr/bin/grep -c '^openagentix/' "$RT/rendered-images")" 0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG FAKE_META=nodigest)
  eq "remote push: no digest in the build metadata stops the install before helm upgrade" "$(/usr/bin/grep -q 'no image digest' <<<"$OUT" && echo 1)/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")/$(/usr/bin/grep -c '^helm upgrade' "$RT/calls")" 1/1/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up IMAGE_REGISTRY=$REG FAKE_BUILDX=no)
  eq "remote push: without docker buildx, refused before any build" "$(/usr/bin/grep -c 'needs docker buildx' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")/$(/usr/bin/grep -c '^docker buildx build' "$RT/calls")" 1/1/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up IMAGE_REGISTRY=ghcr.io/openagentix)
  eq "remote push: ghcr.io/openagentix is refused, nothing called" "$(/usr/bin/grep -c 'signed release images' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/1/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up IMAGE_REGISTRY=https://reg.example/p)
  eq "remote push: a registry with a scheme is refused, nothing called" "$(/usr/bin/grep -c 'IMAGE_REGISTRY must be host' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up IMAGE_REGISTRY=$REG IMAGE_PLATFORM=linux/s390x)
  eq "remote push: an unknown platform is refused, nothing called" "$(/usr/bin/grep -c 'IMAGE_PLATFORM must be' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up IMAGE_REGISTRY=$REG CREATE_CLUSTER=1)
  eq "remote: CREATE_CLUSTER=1 is refused, nothing called" "$(/usr/bin/grep -c 'CREATE_CLUSTER=1 with CLUSTER_TYPE=remote' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/0
  OUT=$(rinst PROFILE=quickstart CLUSTER_TYPE=kind IMAGE_REGISTRY=$REG)
  eq "kind + IMAGE_REGISTRY is refused, nothing called" "$(/usr/bin/grep -c 'IMAGE_REGISTRY is only for CLUSTER_TYPE=remote' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/0
  OUT=$(rinst PROFILE=quickstart CLUSTER_TYPE=k3d IMAGE_PLATFORM=linux/amd64)
  eq "k3d + IMAGE_PLATFORM is refused, nothing called" "$(/usr/bin/grep -c 'IMAGE_PLATFORM is only for CLUSTER_TYPE=remote' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG IMAGE_PLATFORM=linux/amd64,linux/arm64)
  eq "remote push: two platforms are refused for now, nothing called" "$(/usr/bin/grep -c 'IMAGE_PLATFORM takes one platform' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up IMAGE_REGISTRY=ghcr.io:443/openagentix/x)
  eq "remote push: ghcr.io:443/openagentix/x is refused too" "$(/usr/bin/grep -c 'signed release images' <<<"$OUT")/$(/usr/bin/grep -c . "$RT/calls")" 1/0

  echo "# install.sh on remote: the rule for platform images before helm upgrade (ADR 0022)"
  QSKIP=(SKIP_A2A_GATE_IMAGE=1 SKIP_STUB_MODEL_IMAGE=1 SKIP_CONTROL_PLANE_IMAGE=1 SKIP_CONSOLE_IMAGE=1)
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" "${QSKIP[@]}")
  eq "remote, builds skipped, the default openagentix/<name>:dev left: refused before helm upgrade" "$(/usr/bin/grep -c 'controlPlane: openagentix/control-plane:dev is an unqualified name' <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")/$(/usr/bin/grep -c '^helm upgrade' "$RT/calls")" 1/1/0
  eq "remote, builds skipped: nothing built, buildx not asked for" "$(/usr/bin/grep -c '^docker buildx' "$RT/calls")" 0
  printf 'governance: {a2a: {image: {repository: %s/a2a-gate, tag: gke1}}}\ngateway: {stubModel: {image: {repository: %s/stub-model, tag: gke1}}}\ncontrolPlane: {image: {repository: %s/control-plane, tag: gke1}}\nconsole: {image: {repository: %s/console, tag: gke1, digest: "%s"}}\n' "$REG" "$REG" "$REG" "$REG" "$DGB" > "$RT/own-images.yaml"
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" "${QSKIP[@]}" VALUES_FILE="$RT/own-images.yaml")
  eq "remote, the operator's own images by tag (the GKE run): reaches helm upgrade" "$(/usr/bin/grep -c '^helm upgrade' "$RT/calls")" 1
  eq "remote, the operator's own images: one warning per image given by tag, none for the one with a digest" "$(/usr/bin/grep -c 'WARN: [a-zA-Z0-9.]* runs .*:gke1 by tag; set [a-zA-Z0-9.]*.image.digest to pin it' <<<"$OUT")/$(/usr/bin/grep -c 'WARN: console runs' <<<"$OUT")" 3/0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" SKIP_CONSOLE_IMAGE=1 IMAGE_REGISTRY=other.example/x VALUES_FILE="$RT/own-images.yaml")
  eq "remote with IMAGE_REGISTRY: an operator image outside it is refused before helm upgrade" "$(/usr/bin/grep -c "console: $REG/console:gke1@$DGB is not under IMAGE_REGISTRY=other.example/x/" <<<"$OUT")/$(/usr/bin/grep -c '^helm upgrade' "$RT/calls")" 1/0

  echo "# install.sh: QUICKSTART_BYO=1 on remote (ADR 0022)"
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG QUICKSTART_BYO=1)
  eq "byo remote: the sample is pushed under openagentix-examples/" "$(/usr/bin/grep -c "^docker buildx build --platform linux/amd64 --push .* -t $REG/openagentix-examples/echo-a2a:dev-[0-9a-f]\{16\}-amd64 examples/agents/echo-a2a$" "$RT/calls")" 1
  eq "byo remote: its digest is printed" "$(/usr/bin/grep -c "^pushed $REG/openagentix-examples/echo-a2a@$DGB " <<<"$OUT")" 1
  BV=$(for f in "$RT"/values-*; do yq -c '.' "$f" 2>/dev/null; done | jq -s 'reduce .[] as $v ({}; . * $v)')   # merged like helm (lists replaced)
  eq "byo remote: the only allowed prefix is IMAGE_REGISTRY/openagentix-examples/" "$(jq -c '.controlPlane.policy.runtimes.container.images' <<<"$BV")" "[\"$REG/openagentix-examples/\"]"
  eq "byo remote: no IfNotPresent (the chart default Always stays)" "$(jq -r '.controlPlane.containerAgents|has("imagePullPolicy")' <<<"$BV")" false
  eq "byo remote: byo-values.yaml itself (registry.local/oa/) is not passed" "$(/usr/bin/grep '^helm upgrade' "$RT/calls" | /usr/bin/grep -c 'byo-values.yaml')" 0
  eq "byo remote: the sample has no chart value path (no image.digest for it)" "$(/usr/bin/grep '^helm upgrade' "$RT/calls" | /usr/bin/grep -c 'echo-a2a')" 0
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG QUICKSTART_BYO=1 FAKE_HELM_UPGRADE=0 SKIP_KB_INGEST=1 AGENT_WAIT=1s)
  eq "byo remote: the AgentDefinition gets IMAGE_REGISTRY/openagentix-examples/echo-a2a@<digest of the push>" "$(jq -r '.spec.runtime.container.image' "$RT/byo-applied.json" 2>/dev/null)" "$REG/openagentix-examples/echo-a2a@$DGB"
  eq "byo remote: hack/kind-image-digest.sh is not called (no docker exec, no ctr)" "$(/usr/bin/grep -cE '^docker exec|ctr ' "$RT/calls")" 0
  printf 'controlPlane: {policy: {runtimes: {container: {images: ["registry.acme.example/agents/"]}}}}\n' > "$RT/own-prefix.yaml"
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG QUICKSTART_BYO=1 VALUES_FILE="$RT/own-prefix.yaml")
  eq "byo remote: an operator's own prefix list is refused, with what to add, nothing built" "$(/usr/bin/grep -c "your values set runtimes.container.images; add $REG/openagentix-examples/ to it yourself" <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")/$(/usr/bin/grep -c '^docker buildx build' "$RT/calls")" 1/1/0
  printf 'controlPlane: {policy: {runtimes: {container: {images: ["registry.acme.example/agents/", "%s/openagentix-examples/"]}}}}\n' "$REG" > "$RT/own-prefix.yaml"
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG QUICKSTART_BYO=1 VALUES_FILE="$RT/own-prefix.yaml")
  eq "byo remote: an operator list that already has the prefix is kept as it is" "$(/usr/bin/grep -c '^helm upgrade' "$RT/calls")/$(for f in "$RT"/values-*; do yq -c '.controlPlane.policy.runtimes.container.images // empty' "$f"; done | tail -1)" "1/[\"registry.acme.example/agents/\",\"$REG/openagentix-examples/\"]"
  printf 'controlPlane: {policy: [unclosed\n' > "$RT/bad-values.yaml"
  OUT=$(rinst PROFILE=quickstart KUBE_CONTEXT=gke_p_z_c FAKE_API=up "${PUSH[@]}" IMAGE_REGISTRY=$REG QUICKSTART_BYO=1 VALUES_FILE="$RT/bad-values.yaml")
  eq "byo remote: a values file yq cannot read stops the install, names the file, nothing built" "$(/usr/bin/grep -c "cannot read .*bad-values.yaml" <<<"$OUT")/$(/usr/bin/grep -c 'exit=1' <<<"$OUT")/$(/usr/bin/grep -c '^docker buildx build' "$RT/calls")" 1/1/0

  echo "# install.sh on kind with a fake kind (ADR 0022: nothing changes there)"
  mkdir -p "$RT/kbin"; printf '#!/usr/bin/env bash\necho "kind $*" >> "%s/calls"\n[ "$1 $2" = "get clusters" ] && echo openagentix\nexit 0\n' "$RT" > "$RT/kbin/kind"; chmod +x "$RT/kbin/kind"
  : > "$RT/calls"; OUT=$(env -i PATH="$RT/kbin:$RPATH" HOME="$HOME" CLUSTER_TYPE=kind PROFILE=quickstart QUICKSTART_BYO=1 SKIP_PREREQS=1 CONTROL_PLANE_APISERVER_CIDRS=10.0.0.1/32 CONSOLE_APISERVER_CIDRS=10.0.0.1/32 bash "$ROOT/install.sh" 2>&1)
  eq "kind: plain docker build -q for every image, no buildx" "$(/usr/bin/grep -c '^docker build -q -t ' "$RT/calls")/$(/usr/bin/grep -c 'buildx' "$RT/calls")" 5/0
  eq "kind: one kind load with every image, the sample under registry.local/oa/" "$(/usr/bin/grep -c '^kind load docker-image .*registry.local/oa/echo-a2a:dev-.* --name openagentix$' "$RT/calls")" 1
  eq "kind: the chart gets only the tags (no repository, no digest)" "$(/usr/bin/grep '^helm upgrade' "$RT/calls" | /usr/bin/grep -cE 'image\.(repository|digest)=')/$(/usr/bin/grep '^helm upgrade' "$RT/calls" | /usr/bin/grep -o 'image\.tag=' | wc -l | tr -d ' ')" 0/4
  eq "kind: byo-values.yaml (registry.local/oa/, IfNotPresent) is passed as before" "$(/usr/bin/grep '^helm upgrade' "$RT/calls" | /usr/bin/grep -c -- '-f components/quickstart/byo-values.yaml')" 1
  # Golden (ADR 0022 test 3): the commands on kind and k3d equal the list recorded with install.sh from before the change, up to helm upgrade
  # (the fake fails there). Hashes, temporary paths and the order of the parallel steps are normalised. After an intended change to the
  # installer's commands, regenerate with OA_UPDATE_GOLDEN=1 components/quickstart/tests/run.sh and review the diff.
  printf '#!/usr/bin/env bash\necho "k3d $*" >> "%s/calls"\n[ "$1 $2" = "cluster list" ] && echo %s\nexit 0\n' "$RT" "'[{\"name\":\"openagentix\"}]'" > "$RT/kbin/k3d"; chmod +x "$RT/kbin/k3d"
  norm(){ sed -E 's#[^ =]*/tmp\.[A-Za-z0-9]+#TMP#g; s/dev-[0-9a-f]{16}/dev-HASH/g; s/sourceHash=[0-9a-f]{16}/sourceHash=HASH/g' "$RT/calls" | LC_ALL=C sort; }
  for ty in kind k3d; do
    : > "$RT/calls"; env -i PATH="$RT/kbin:$RPATH" HOME="$HOME" CLUSTER_TYPE=$ty PROFILE=quickstart QUICKSTART_BYO=1 SKIP_PREREQS=1 CONTROL_PLANE_APISERVER_CIDRS=10.0.0.1/32 CONSOLE_APISERVER_CIDRS=10.0.0.1/32 bash "${OA_GOLDEN_INSTALL:-$ROOT/install.sh}" >/dev/null 2>&1
    G="$ROOT/components/quickstart/tests/golden/$ty-quickstart-byo.calls"
    if [ "${OA_UPDATE_GOLDEN:-0}" = 1 ]; then mkdir -p "$(dirname "$G")"; norm > "$G"; fi
    eq "$ty: the recorded commands equal the golden list ($(wc -l < "$G" | tr -d ' ') calls, components/quickstart/tests/golden/)" "$(norm | diff "$G" - >/dev/null && echo same || { norm | diff "$G" - | head -5; })" same
    # ADR 0024: the installer reads the budgets of the namespaces (get pdb, a read) but never adopts one: a budget that is not the release's is
    # not hand-applied chart state (no earlier chart had budgets), and adopting it would let Helm overwrite someone else's budget.
    eq "$ty: no PodDisruptionBudget is labelled, annotated or read by name (adoption skips them)" "$(norm | /usr/bin/grep -ci 'poddisruptionbudget')" 0
    eq "$ty: the check reads the budgets of every namespace with a workload, with get only" "$(norm | /usr/bin/grep -c '^kubectl --context [a-z0-9-]* get pdb -n [a-z-]* -o json$')" 4
  done
fi
eq "install.sh (ADR 0023): no installer value for the Service type, the exposure check runs after a remote install and from die() once the chart is applied, header documents it" "$(/usr/bin/grep -c 'gateway.serviceType=' "$ROOT/install.sh" | awk '{print ($1<=1)?"header-only":"more"}')/$(/usr/bin/grep -c 'gw_exposure_check "\$K" "\$CTX"' "$ROOT/install.sh")/$(/usr/bin/grep -c 'GW_CHECK_ON_DIE=1' "$ROOT/install.sh")/$(sed -n '1,/^set -euo pipefail/p' "$ROOT/install.sh" | /usr/bin/grep -c 'gateway.serviceType')" header-only/2/1/1
eq "install.sh (ADR 0023): the helm upgrade --wait step goes through die, so a timeout also prints the exposure report" "$(/usr/bin/grep -cE '^helm upgrade --install .* --wait --timeout 5m \|\| die "' "$ROOT/install.sh")" 1
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
