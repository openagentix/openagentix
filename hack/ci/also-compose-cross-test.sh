#!/usr/bin/env bash
# Cross-check of the three use case installers (bank, equipment, software-org): each one, run beside the full demo with fakes, must accept EVERY optional file of the
# other two in ALSO_COMPOSE (their values-full-demo.yaml and, where the use case has one, their values-events.yaml), compose them, and pass its release guard on a first run
# and on a second run on the release it made. A run that leaves one events file out must be refused, naming the event caller that would be lost. The list of optional files
# is read from the directories, so a new optional file of a use case is covered without an edit here, and an installer that does not accept it fails this test.
# No cluster, no Docker, no network. Needs bash, jq and the Python yq. Usage: hack/ci/also-compose-cross-test.sh   (exit 1 on any failure)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
UC="$ROOT/examples/use-cases"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
for t in jq yq; do command -v "$t" >/dev/null || { echo "ERROR: $t is required" >&2; exit 2; }; done
unset ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY MODEL_BASE_URL MODEL_NAME MODEL_PROVIDER MODEL_API_KEY STUB_SCENARIOS
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"; LOG="$TMP/log"; mkdir -p "$LOG"

# one set of fakes for the three installers: every read of the cluster answers "there", Secrets exist, helm get values answers $FAKE_LOG/release.json (or not found)
cat > "$BIN/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$FAKE_LOG/calls"
case "$*" in
  *"config get-contexts"*) echo "kind-openagentix"; exit 0 ;;
  *"get secret "*) n=$(printf '%s' "$*" | sed -n 's/.*get secret \([a-z-]*\) .*/\1/p'); echo "secret/$n"; exit 0 ;;
  *"get virtualmcpservers"*) case "$*" in *jsonpath*) printf false ;; esac; exit 0 ;;
  *"get configmap stub-model-scenarios"*) echo '{"data":{"scenario.json":"{}","equipment.json":"{}","software-org-rca.json":"{}"}}'; exit 0 ;;
  *"apply -f -"*|*"apply -f"*"-"*) cat >> "$FAKE_LOG/applied.yaml" ;;
  *"create "*"--dry-run=client -o yaml"*) echo "kind: Fake" ;;
esac
exit 0
EOF
cat > "$BIN/helm" <<'EOF'
#!/usr/bin/env bash
echo "helm $*" >> "$FAKE_LOG/calls"
case "$1" in
  get) if [ -f "$FAKE_LOG/release.json" ]; then cat "$FAKE_LOG/release.json"; exit 0; fi; echo "Error: release: not found" >&2; exit 1 ;;
  template) echo "render: same"; exit 0 ;;
esac
exit 0
EOF
for t in docker kind; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_LOG/calls"\nexit 0\n' "$t" > "$BIN/$t"; done
for t in kb-ingest kb-graph-load; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_LOG/calls"\nexit 0\n' "$t" > "$BIN/$t"; done
cat > "$BIN/platform-install" <<'EOF'
#!/usr/bin/env bash
echo "platform-install" >> "$FAKE_LOG/calls"
[ -z "${VALUES_FILE:-}" ] || cp "$VALUES_FILE" "$FAKE_LOG/platform-values.yaml"
exit 0
EOF
chmod +x "$BIN"/*

FDLIST="components/channels/demo-values.yaml components/schedules/demo-values.yaml components/notify/demo-values.yaml components/observability/demo-values.yaml components/knowledge/graph-demo-values.yaml components/governance/demo-values.yaml components/governance/profiles-demo-values.yaml components/governance/memory-demo-values.yaml components/control-plane/demo-values.yaml components/console/demo-values.yaml"
KEYS='{"controlPlane":{"sourceHash":"x","apiServerCIDRs":["172.18.0.0/24"]},"diagnostics":{"sourceHash":"abc","apiServerCIDRs":["172.18.0.0/24"],"image":{"tag":"dev"}},"knowledge":{"kb":{"sourceHash":"d","image":{"tag":"dev-1"}}},"notify":{"requireReady":false}}'
USECASES="bank equipment software-org"
CALLER_OF() { case "$1" in bank) echo fernvale-case-events;; equipment) echo kestrel-fault-events;; esac; }
optional_files() { # optional_files <use case>: the optional values files of a use case that another installer lists in ALSO_COMPOSE, relative to the repository root
  local f
  for f in values-full-demo.yaml values-events.yaml; do [ ! -f "$UC/$1/$f" ] || printf 'examples/use-cases/%s/%s\n' "$1" "$f"; done
}
run() { # run <use case> <extra env...> : the installer of that use case beside the full demo, with the fakes; output in $LOG/out
  local uc=$1; shift
  ( cd "$ROOT" && env "$@" FAKE_LOG="$LOG" KUBECTL="$BIN/kubectl" HELM="$BIN/helm" DOCKER="$BIN/docker" KIND="$BIN/kind" KB_INGEST="$BIN/kb-ingest" KB_GRAPH_LOAD="$BIN/kb-graph-load" \
      PLATFORM_INSTALL="$BIN/platform-install" PATH="$BIN:$PATH" CLUSTER=openagentix VALUES_FILE="$FDLIST" bash "$UC/$uc/install.sh" --beside-full-demo > "$LOG/out" 2>&1 )
}

for uc in $USECASES; do
  echo "# $uc beside the other two, every optional file of the others listed"
  ALSO=""; EVWANT=""
  for o in $USECASES; do
    [ "$o" != "$uc" ] || continue
    ALSO="$ALSO $(optional_files "$o" | tr '\n' ' ')"
    [ -z "$(CALLER_OF "$o")" ] || EVWANT="$EVWANT $o"
  done
  ALSO=$(printf '%s' "$ALSO" | xargs)
  EV=0; [ "$uc" = software-org ] || EV=1
  rm -f "$LOG"/*
  run "$uc" EVENTS=$EV ALSO_COMPOSE="$ALSO"; rc=$?
  check "$uc: the first run is accepted: exit 0, the platform installer ran once" "[ $rc = 0 ] && [ \"\$(grep -c '^platform-install' '$LOG/calls')\" = 1 ]" "rc=$rc $(tail -4 "$LOG/out")"
  names='[.governance.a2a.callers[].name]'
  for o in $EVWANT; do
    check "$uc: the event caller $(CALLER_OF "$o") of $o is in the composed values" "yq -e '$names | index(\"$(CALLER_OF "$o")\") != null' '$LOG/platform-values.yaml' >/dev/null"
  done
  if [ "$EV" = 1 ]; then check "$uc: its own event caller $(CALLER_OF "$uc") is in the composed values (EVENTS=1)" "yq -e '$names | index(\"$(CALLER_OF "$uc")\") != null' '$LOG/platform-values.yaml' >/dev/null"; fi
  check "$uc: the composed values hold one class for each of the three use cases" "[ \"\$(yq -r '.gateway.policy.budgetClasses | length' '$LOG/platform-values.yaml')\" = 3 ]"
  yq . "$LOG/platform-values.yaml" > "$TMP/composed.json"
  jq -c ". * $KEYS" "$TMP/composed.json" > "$TMP/release.json"
  rm -f "$LOG"/calls "$LOG"/platform-values.yaml; cp "$TMP/release.json" "$LOG/release.json"
  run "$uc" EVENTS=$EV ALSO_COMPOSE="$ALSO"; rc=$?
  check "$uc: a second run on the release it made passes its release guard" "[ $rc = 0 ] && [ \"\$(grep -c '^platform-install' '$LOG/calls')\" = 1 ]" "rc=$rc $(tail -4 "$LOG/out")"
  for o in $EVWANT; do
    rest=$(printf '%s\n' $ALSO | grep -v "examples/use-cases/$o/values-events.yaml" | tr '\n' ' ' | xargs)
    rm -f "$LOG"/calls "$LOG"/platform-values.yaml; cp "$TMP/release.json" "$LOG/release.json"
    run "$uc" EVENTS=$EV ALSO_COMPOSE="$rest"; rc=$?
    check "$uc: leaving the values-events.yaml of $o out is refused, naming $(CALLER_OF "$o"), and nothing is installed" "[ $rc = 1 ] && grep -qF '$(CALLER_OF "$o")' '$LOG/out' && ! grep -q '^platform-install' '$LOG/calls'" "rc=$rc $(tail -4 "$LOG/out")"
  done
done

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
