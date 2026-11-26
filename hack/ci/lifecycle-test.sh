#!/usr/bin/env bash
# Lifecycle test (issue #206): the installer can run again and again without harm.
#   1. ./install.sh, then hack/ci/smoke.sh                                    (a first install works)
#   2. ./install.sh again with the same values (a helm upgrade)               (no error; nothing recreated, lost or doubled)
#   3. ./uninstall.sh                                                         (only what the docs say is kept stays behind)
#   4. ./install.sh once more, then hack/ci/smoke.sh                          (a reinstall works; kept Secrets are reused)
# What "nothing recreated, lost or doubled" means, checked after step 2 against step 1:
#   - every object of the Helm release (read from `helm get manifest`) is still there with the same UID, and none is new;
#   - every AgentDefinition and Agent has the same name and UID (the second run did not delete and rebuild the agent);
#   - every Secret in the OpenAgentix namespaces has the same content (checksum only: no value is read into the log), so keys were not rotated;
#   - every pod of the platform namespaces is Ready (or finished) and none waits in CrashLoopBackOff, ImagePullBackOff or similar.
# What "only what the docs say is kept" means, checked after step 3 (uninstall.sh header, no PURGE flags):
#   - no object of the release is left, except those with the annotation helm.sh/resource-policy=keep (the CRD, the key ConfigMap, ...);
#   - no AgentDefinition and no kagent Agent is left;
#   - the PVCs left are only the documented data volumes; Secrets and ConfigMaps in the OpenAgentix namespaces are listed, not failed
#     (uninstall.sh keeps them on purpose so a later install reuses them).
# Needs: kubectl (pointing at the cluster), helm, jq, yq (the Python wrapper), and the repository checkout as the working directory.
# Env: LIFECYCLE_INSTALL (default ./install.sh), LIFECYCLE_UNINSTALL (./uninstall.sh), LIFECYCLE_SMOKE (hack/ci/smoke.sh): the commands that run
# each step (the offline test replaces them), KUBECTL, HELM, RELEASE (openagentix), RELEASE_NS (openagentix-system),
# LIFECYCLE_NS_RE (platform namespaces for the pod and Secret checks, default ^(openagentix-.*|agentgateway-system|kagent|toolhive-system|ate-system)$),
# LIFECYCLE_STEPS (default "install smoke reinstall uninstall reinstall2": a subset, for a re-run of one part).
# Prints one line per check and a summary; exit 1 when any check failed. Never prints a Secret value.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
K=${KUBECTL:-kubectl}; HELM=${HELM:-helm}
RELEASE=${RELEASE:-openagentix}; RELEASE_NS=${RELEASE_NS:-openagentix-system}
NS_RE=${LIFECYCLE_NS_RE:-'^(openagentix-.*|agentgateway-system|kagent|toolhive-system|ate-system)$'}
SECRET_NS_RE=${LIFECYCLE_SECRET_NS_RE:-'^(openagentix-.*|agentgateway-system)$'}
PVC_ALLOWED=${LIFECYCLE_PVC_ALLOWED:-'^(data-kb-postgres-0|kb-embeddings-models|victoria-metrics|memory-embeddings-models)$'}
INSTALL=${LIFECYCLE_INSTALL:-./install.sh}
UNINSTALL=${LIFECYCLE_UNINSTALL:-./uninstall.sh}
SMOKE=${LIFECYCLE_SMOKE:-hack/ci/smoke.sh}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf 'FAIL  %s\n' "$1" >&2; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/      /' >&2; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
now(){ date +%s; }

# run <label> <command...>: runs a step with its time; a failing command is a FAIL and stops the test (later steps would mean nothing)
run(){
  local label=$1; shift; local t0; t0=$(now)
  echo "=== $label: $*"
  if "$@" >"$W/step.log" 2>&1; then ok "$label ($(( $(now) - t0 )) s)"; tail -n 5 "$W/step.log" | sed 's/^/      | /'
  else bad "$label failed (exit $?, $(( $(now) - t0 )) s): last lines of its output" "$(tail -n 40 "$W/step.log")"; summary; fi
}
summary(){ echo; echo "lifecycle: $pass ok, $fail failed"; [ "$fail" = 0 ] && exit 0 || exit 1; }

# ---- readers (every cluster read goes through $K; the offline test replaces it with a fake) ----------------------------------------------
# manifest_keys: one line per object of the release: <kind.group> <ns> <name> <keep|->
manifest_keys(){
  $HELM get manifest "$RELEASE" -n "$RELEASE_NS" 2>/dev/null | yq -r 'select(.kind!=null and .metadata.name!=null)|[(.kind + (if (.apiVersion|contains("/")) then "." + (.apiVersion|split("/")[0]) else "" end)), (.metadata.namespace//"-"), .metadata.name, (.metadata.annotations["helm.sh/resource-policy"]//"-")]|@tsv' 2>/dev/null | sort -u
}
# live_keys <manifest_keys file>: for each manifest object that exists: <kind.group> <ns> <name> <uid>, sorted. The manifest's namespace may be absent
# (cluster scoped, or the release namespace by default): then any namespace matches.
live_keys(){
  local keys=$1 kg
  : > "$W/live.all"
  for kg in $(cut -f1 "$keys" | sort -u); do
    $K get "$kg" -A -o json 2>/dev/null | jq -r --arg kg "$kg" '.items[]?|[$kg,(.metadata.namespace//"-"),.metadata.name,.metadata.uid]|@tsv' >> "$W/live.all" || true
  done
  # keep only the objects the manifest names
  awk -F'\t' 'NR==FNR{ if($2=="-") any[$1 FS $3]=1; else ns[$1 FS $2 FS $3]=1; next }
              { if (($1 FS $3) in any || ($1 FS $2 FS $3) in ns) print }' "$keys" "$W/live.all" | sort -u
}
agent_keys(){ $K get agentdefinitions.openagentix.io,agents.api.kagent.dev -A -o json 2>/dev/null | jq -r '.items[]?|[.kind,.metadata.namespace,.metadata.name,.metadata.uid]|@tsv' | sort; }
workloads(){  # every workload and Service of the platform namespaces, by name (not only the ones the manifest names: an extra copy shows here)
  $K get deployments,statefulsets,daemonsets,cronjobs,services -A -o json 2>/dev/null | jq -r --arg re "$NS_RE" '.items[]?|select(.metadata.namespace|test($re))|[.kind,.metadata.namespace,.metadata.name]|@tsv' | sort -u
}
secret_sums(){  # ns/name checksum of the data: the values are hashed, never printed
  $K get secrets -A -o json 2>/dev/null | jq -r --arg re "$SECRET_NS_RE" '.items[]?|select((.metadata.namespace|test($re)) and .type!="helm.sh/release.v1" and .type!="kubernetes.io/service-account-token")|[.metadata.namespace+"/"+.metadata.name,((.data//{})|tojson)]|@tsv' \
    | while IFS=$'\t' read -r n d; do printf '%s\t%s\n' "$n" "$(printf '%s' "$d" | shasum -a 256 | cut -c1-16)"; done | sort
}
pod_problems(){  # pods of the platform namespaces that are not Ready, finished, or that wait in a failing state
  $K get pods -A -o json 2>/dev/null | jq -r --arg re "$NS_RE" '.items[]?|select(.metadata.namespace|test($re))
    |select(.status.phase!="Succeeded")
    |. as $p|( [.status.containerStatuses[]?,.status.initContainerStatuses[]?|select(.state.waiting.reason|IN("CrashLoopBackOff","ImagePullBackOff","ErrImagePull","CreateContainerConfigError","CreateContainerError","RunContainerError"))|.state.waiting.reason] ) as $w
    |([.status.conditions[]?|select(.type=="Ready")|.status]|first//"False") as $r
    |select($r!="True" or ($w|length)>0)|.metadata.namespace+"/"+.metadata.name+" ready="+$r+" waiting="+($w|join(","))'
}
snapshot(){ # snapshot <dir>: everything compared between steps
  mkdir -p "$1"; manifest_keys > "$1/manifest"; live_keys "$1/manifest" > "$1/live"; agent_keys > "$1/agents"; workloads > "$1/workloads"; secret_sums > "$1/secrets"
}
healthy(){ # healthy <label>: no pod of the platform namespaces is unhealthy (waits up to HEALTH_WAIT seconds: pods roll after an upgrade)
  local label=$1 i out=""
  for _ in $(seq 1 "${HEALTH_WAIT:-180}"); do out=$(pod_problems); [ -z "$out" ] && break; sleep 1; done
  if [ -z "$out" ]; then ok "$label: every pod of the platform namespaces is Ready or finished, none in CrashLoopBackOff or ImagePullBackOff"; else bad "$label: unhealthy pods" "$out"; fi
}
same(){ # same <label> <file a> <file b>: the two listings are identical, else show what was lost, what is new
  local label=$1 a=$2 b=$3
  if cmp -s "$a" "$b"; then ok "$label ($(wc -l < "$a" | tr -d ' ') entries)"; else
    bad "$label" "only before: $(comm -23 "$a" "$b" | tr '\t' ' ' | head -20 | tr '\n' ';')
only after:  $(comm -13 "$a" "$b" | tr '\t' ' ' | head -20 | tr '\n' ';')"
  fi
}

has(){ case " ${LIFECYCLE_STEPS:-install smoke reinstall uninstall reinstall2} " in *" $1 "*) return 0;; esac; return 1; }

# ---- 1. first install -------------------------------------------------------------------------------------------------------------------
if has install; then
  echo "# 1. first install and smoke"
  run "install (first)" $INSTALL
  has smoke && run "smoke after the first install" $SMOKE
  healthy "after the first install"
  snapshot "$W/s1"
  [ -s "$W/s1/manifest" ] && ok "helm manifest read: $(wc -l < "$W/s1/manifest" | tr -d ' ') objects" || bad "helm get manifest $RELEASE returned no objects"
  [ -s "$W/s1/agents" ] && ok "agents present: $(cut -f1,3 "$W/s1/agents" | tr '\t' '/' | tr '\n' ' ')" || bad "no AgentDefinition or Agent after the first install"
  REV1=$($HELM status "$RELEASE" -n "$RELEASE_NS" -o json 2>/dev/null | jq -r '.version // empty')
  echo "      helm revision after the first install: ${REV1:-unknown}"
fi

# ---- 2. install again ------------------------------------------------------------------------------------------------------------------
if has reinstall; then
  echo "# 2. install again with the same values"
  run "install (second, same values)" $INSTALL
  healthy "after the second install"
  snapshot "$W/s2"
  check "helm release is deployed" "$($HELM status "$RELEASE" -n "$RELEASE_NS" -o json 2>/dev/null | jq -r '.info.status // "unknown"')" deployed
  REV2=$($HELM status "$RELEASE" -n "$RELEASE_NS" -o json 2>/dev/null | jq -r '.version // empty')
  echo "      helm revision after the second install: ${REV2:-unknown} (was ${REV1:-unknown}; helm upgrade adds one when anything differs)"
  same "same objects, same UIDs (nothing recreated, lost or doubled)" "$W/s1/live" "$W/s2/live"
  same "same workloads and Services by name (no second copy of anything)" "$W/s1/workloads" "$W/s2/workloads"
  same "same helm manifest (no object added or dropped)" "$W/s1/manifest" "$W/s2/manifest"
  same "same AgentDefinitions and Agents with the same UIDs" "$W/s1/agents" "$W/s2/agents"
  same "same Secret contents (no key rotated)" "$W/s1/secrets" "$W/s2/secrets"
  has smoke && run "smoke after the second install" $SMOKE
fi

# ---- 3. uninstall ----------------------------------------------------------------------------------------------------------------------
if has uninstall; then
  echo "# 3. uninstall (no PURGE flags)"
  [ -s "$W/s2/manifest" ] && cp "$W/s2/manifest" "$W/before-uninstall" || { manifest_keys > "$W/before-uninstall"; }
  [ -d "$W/s2" ] || snapshot "$W/s2"
  run "uninstall" $UNINSTALL
  $HELM status "$RELEASE" -n "$RELEASE_NS" >/dev/null 2>&1 && bad "the helm release $RELEASE is still there after uninstall" || ok "the helm release $RELEASE is gone"
  live_keys "$W/before-uninstall" > "$W/after-uninstall"
  left=$(awk -F'\t' 'NR==FNR{ if($4=="keep"){ if($2=="-") kany[$1 FS $3]=1; else k[$1 FS $2 FS $3]=1 } next }
                      !(($1 FS $3) in kany) && !(($1 FS $2 FS $3) in k){ print $1 "/" $2 "/" $3 }' "$W/before-uninstall" "$W/after-uninstall")
  [ -z "$left" ] && ok "no object of the release is left, except those with resource-policy keep" || bad "objects of the release left after uninstall (no keep policy)" "$left"
  kept=$(awk -F'\t' 'NR==FNR{ if($4=="keep"){ if($2=="-") kany[$1 FS $3]=1; else k[$1 FS $2 FS $3]=1 } next }
                      (($1 FS $3) in kany) || (($1 FS $2 FS $3) in k){ print $1 "/" $2 "/" $3 }' "$W/before-uninstall" "$W/after-uninstall")
  echo "      kept on purpose (resource-policy keep): $(printf '%s' "$kept" | tr '\n' ' ')"
  check "no AgentDefinition and no kagent Agent is left" "$(agent_keys | cut -f1,3 | tr '\t' '/' | tr '\n' ' ')" ""
  badpvc=$($K get pvc -A -o json 2>/dev/null | jq -r --arg re "$SECRET_NS_RE" --arg ok "$PVC_ALLOWED" '.items[]?|select((.metadata.namespace|test($re)) and (.metadata.name|test($ok)|not))|.metadata.namespace+"/"+.metadata.name')
  [ -z "$badpvc" ] && ok "PVCs left behind are only the documented data volumes ($($K get pvc -A -o name 2>/dev/null | wc -l | tr -d ' ') PVCs in the cluster)" || bad "PVCs left that uninstall.sh does not document" "$badpvc"
  echo "      Secrets kept (uninstall.sh keeps them so a reinstall reuses them): $(secret_sums | wc -l | tr -d ' ')"
  secret_sums > "$W/secrets-after-uninstall"
fi

# ---- 4. reinstall ----------------------------------------------------------------------------------------------------------------------
if has reinstall2; then
  echo "# 4. reinstall after the uninstall"
  run "install (after uninstall)" $INSTALL
  has smoke && run "smoke after the reinstall" $SMOKE
  healthy "after the reinstall"
  snapshot "$W/s3"
  [ -s "$W/s3/agents" ] && ok "agents present again: $(cut -f1,3 "$W/s3/agents" | tr '\t' '/' | tr '\n' ' ')" || bad "no AgentDefinition or Agent after the reinstall"
  if [ -d "$W/s1" ]; then
    # the kept Secrets must come back unchanged: install.sh creates a Secret only when it is absent
    comm -23 "$W/s1/secrets" "$W/s3/secrets" | cut -f1 > "$W/lost"
    comm -13 "$W/s1/secrets" "$W/s3/secrets" | cut -f1 > "$W/new"
    # Secrets the upstream agentgateway controller makes for the Gateway it serves (a session key) are made again when the Gateway is recreated:
    # not ours, not kept by uninstall.sh. LIFECYCLE_SECRET_IGNORE names them (default: a name ending in -session-key).
    changed=$(comm -12 "$W/lost" "$W/new" | grep -Ev "${LIFECYCLE_SECRET_IGNORE:--session-key\$}" || true)
    [ -z "$changed" ] && ok "no Secret changed its content across uninstall and reinstall" || bad "Secrets whose content changed across uninstall and reinstall (keys rotated)" "$changed"
  fi
fi
summary
