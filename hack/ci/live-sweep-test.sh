#!/usr/bin/env bash
# The sweep of the scripts that can reach a real kubectl, helm, kind, k3d or docker (issue #212). Offline: fake tools on PATH record every call; no cluster, no network.
#   1. every script that names one of those tools (or an installer) is a row of hack/ci/live-scripts.tsv, with a class, and every row names a file that exists;
#   2. every row of class `guard` is run with the fakes, with an empty KUBECONFIG and the contexts kind-openagentix and prod, with its opt-in variable and with its CI
#      context variable naming that context, outside GitHub Actions: it must exit 2 and call nothing but `kubectl config current-context`;
#   3. the shared helper hack/ci/lib/require-ci-context.sh gives the rule it documents (kind and k3d, GitHub Actions, the named variable, never kind-openagentix by hand);
#   4. every row of class `own` runs only against a kubeconfig of its own: every kubectl and helm call it makes carries a KUBECONFIG that is not the caller's.
# A new live script that is not in the table, or a row of class guard with no guard, fails this test. Usage: hack/ci/live-sweep-test.sh   (exit 1 on any failure)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TABLE="$ROOT/hack/ci/live-scripts.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$ROOT" || exit 1

echo "# 1 the table covers every script that can reach a real tool"
find hack components examples tools services -type f \( -name '*.sh' -o -name Makefile -o -name '*.py' \) 2>/dev/null | grep -v node_modules | sort > "$TMP/all"
printf 'Makefile\ninstall.sh\nuninstall.sh\n' >> "$TMP/all"
: > "$TMP/found"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -qE '(^|[^A-Za-z_./-])(kubectl|helm|kind|k3d|docker)[ "$]|KUBECTL|install\.sh|uninstall\.sh|\$HELM|\$DOCKER|\$KIND' "$f" && printf '%s\n' "$f" >> "$TMP/found"
done < "$TMP/all"
grep -v '^#' "$TABLE" | cut -f1 | sort > "$TMP/rows"
sort "$TMP/found" > "$TMP/found.s"
check "no script that names kubectl, helm, kind, k3d, docker or an installer is missing from the table" "[ -z \"\$(comm -23 '$TMP/found.s' '$TMP/rows')\" ]" "missing rows: $(comm -23 "$TMP/found.s" "$TMP/rows" | tr '\n' ' ')"
check "every row of the table names a file that exists" "[ -z \"\$(while read -r p; do [ -f \"\$p\" ] || echo \"\$p\"; done < '$TMP/rows')\" ]" "no such file: $(while read -r p; do [ -f "$p" ] || echo "$p"; done < "$TMP/rows" | tr '\n' ' ')"
check "every row has a known class" "! grep -v '^#' '$TABLE' | cut -f2 | grep -qvxE 'guard|own|user|docker|offline|pending'"
check "a row of class guard names its opt-in variable (or -), its CI context variable and an arguments field" "! grep -v '^#' '$TABLE' | awk -F'\t' '\$2==\"guard\" && (NF<5 || \$4==\"-\")' | grep -q ."
check "every script of hack/ci that makes or changes things on a cluster is in class guard, own, pending or user (none is left unclassified)" "! grep -v '^#' '$TABLE' | grep -q UNCLASSIFIED"
grep -v '^#' "$TABLE" | awk -F'\t' '$2=="pending"{print "  --   pending (a guard comes with another pull request): " $1}'

echo "# fake tools: every call is recorded with the KUBECONFIG it saw"
BIN="$TMP/bin"; mkdir -p "$BIN"
for t in kubectl helm kind k3d docker gcloud curl; do
  cat > "$BIN/$t" <<'EOF'
#!/usr/bin/env bash
t=$(basename "$0")
echo "$t $* [KUBECONFIG=${KUBECONFIG:-}]" >> "$FAKE_CALLS"
if [ "$t" = kubectl ]; then case "$*" in "config current-context") echo "${FAKE_CTX:-}"; exit 0 ;; esac; fi
if [ "$t" = kind ]; then case "$*" in "get clusters"*) exit 0 ;; esac; fi
exit 0
EOF
  chmod +x "$BIN/$t"
done
runfake() { # runfake <context> <env var assignments...> -- <script> [args]: the script with the fakes, an empty KUBECONFIG, outside GitHub Actions
  local ctx=$1; shift
  : > "$TMP/calls"; : > "$TMP/kc"
  ( cd "$ROOT" && env -u GITHUB_ACTIONS -u HELM_KUBECONTEXT KUBECONFIG="$TMP/kc" FAKE_CTX="$ctx" FAKE_CALLS="$TMP/calls" KUBECTL="$BIN/kubectl" PATH="$BIN:$PATH" "$@" > "$TMP/out" 2>&1 < /dev/null )
}

echo "# 2 every guarded live script refuses kind-openagentix and a context of a person's cluster, and calls nothing but a read of the context"
while IFS=$'\t' read -r path cls opt var args _note; do
  [ "$cls" = guard ] || continue
  for ctx in kind-openagentix prod; do
    OPT=(); [ "$opt" = - ] || OPT=("$opt")
    for mode in plain named; do
      VARS=("${OPT[@]+"${OPT[@]}"}")
      [ "$mode" = plain ] || VARS+=("$var=$ctx")
      # shellcheck disable=SC2086
      runfake "$ctx" "${VARS[@]+"${VARS[@]}"}" timeout 60 bash "$path" $args; rc=$?
      check "$path on '$ctx' ($mode): exit 2, nothing but a read of the context" "[ $rc = 2 ] && [ \"\$(grep -vc '^kubectl config current-context ' '$TMP/calls')\" = 0 ] && grep -q 'Nothing was changed' '$TMP/out'" "rc=$rc calls: $(tr '\n' ';' < "$TMP/calls" | cut -c1-300) out: $(head -c 300 "$TMP/out")"
    done
  done
  # a context that is not named and not a CI run, on a throwaway kind name: refused as well (the variable is empty)
  runfake kind-throwaway "${OPT[@]+"${OPT[@]}"}" timeout 60 bash "$path" $args; rc=$?
  check "$path on 'kind-throwaway' with no CI context variable and no GitHub Actions: exit 2, nothing but a read of the context" "[ $rc = 2 ] && [ \"\$(grep -vc '^kubectl config current-context ' '$TMP/calls')\" = 0 ]" "rc=$rc calls: $(tr '\n' ';' < "$TMP/calls" | cut -c1-300)"
done < <(grep -v '^#' "$TABLE")

echo "# 3 the shared helper"
HELPER="$ROOT/hack/ci/lib/require-ci-context.sh"
h() { # h <context> <env...>: source the helper and call it; prints the exit code
  ( env -u GITHUB_ACTIONS FAKE_CTX="$1" FAKE_CALLS="$TMP/calls" KUBECTL="$BIN/kubectl" "${@:2}" bash -c '. "$0"; require_ci_context demo DEMO_CI_CONTEXT; echo passed' "$HELPER" ) > "$TMP/hout" 2>&1; echo $?
}
: > "$TMP/calls"
check "a context that is neither kind nor k3d is refused, also on GitHub Actions" "[ \"\$(h prod DEMO_CI_CONTEXT=prod)\" = 2 ] && [ \"\$(h prod GITHUB_ACTIONS=true)\" = 2 ]"
check "no context at all is refused" "[ \"\$(h '' GITHUB_ACTIONS=true)\" = 2 ]"
check "kind-openagentix is refused by hand, also when the variable names it" "[ \"\$(h kind-openagentix DEMO_CI_CONTEXT=kind-openagentix)\" = 2 ] && grep -q 'kind-openagentix' '$TMP/hout'"
check "a kind context with no variable is refused by hand; with the variable naming another context too" "[ \"\$(h kind-a)\" = 2 ] && [ \"\$(h kind-a DEMO_CI_CONTEXT=kind-b)\" = 2 ]"
check "a kind context that the variable names exactly is accepted by hand, so is a k3d one" "[ \"\$(h kind-a DEMO_CI_CONTEXT=kind-a)\" = 0 ] && [ \"\$(h k3d-a DEMO_CI_CONTEXT=k3d-a)\" = 0 ]"
check "on GitHub Actions a kind context is accepted, kind-openagentix included (the quick start jobs use that name on their own runner)" "[ \"\$(h kind-a GITHUB_ACTIONS=true)\" = 0 ] && [ \"\$(h kind-openagentix GITHUB_ACTIONS=true)\" = 0 ]"
check "the helper reads the context and nothing else" "[ \"\$(grep -vc '^kubectl config current-context ' '$TMP/calls')\" = 0 ]"
check "the refusal says that nothing was changed" "h prod >/dev/null; grep -q 'Nothing was changed' '$TMP/hout'"

echo "# 4 the scripts that make their own cluster use a kubeconfig of their own"
while IFS=$'\t' read -r path cls opt var args _note; do
  [ "$cls" = own ] || continue
  CALLER_KC="$TMP/callers-kubeconfig"; : > "$CALLER_KC"
  : > "$TMP/calls"
  ( cd "$ROOT" && env -u GITHUB_ACTIONS KUBECONFIG="$CALLER_KC" FAKE_CTX=prod FAKE_CALLS="$TMP/calls" PATH="$BIN:$PATH" SPIKE_OUT="$TMP/spike-out" timeout 90 bash "$path" > "$TMP/out" 2>&1 < /dev/null )
  check "$path: it ran the fakes (it made calls)" "[ -s '$TMP/calls' ]" "no call recorded: $(head -c 300 "$TMP/out")"
  check "$path: every kubectl and helm call carries a KUBECONFIG of its own, never the caller's and never empty" "! grep -E '^(kubectl|helm) ' '$TMP/calls' | grep -qF '[KUBECONFIG=$CALLER_KC]' && ! grep -E '^(kubectl|helm) ' '$TMP/calls' | grep -qF '[KUBECONFIG=]'" "$(grep -E '^(kubectl|helm) ' "$TMP/calls" | head -3 | tr '\n' ';')"
  check "$path: it never switches or sets the current context of anybody's kubeconfig" "! grep -q 'config use-context\|config set-context\|--set-context' '$TMP/calls'"
done < <(grep -v '^#' "$TABLE")

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
