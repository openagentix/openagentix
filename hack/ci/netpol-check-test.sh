#!/usr/bin/env bash
# Tests for hack/netpol-check.sh (issue #212, the installer's CHECK_NETPOL=1) with a fake `kubectl` (no cluster).
# The check puts two throwaway pods in the release namespace, applies a deny-all ingress policy to one of them, and says PASS only when the second pod
# is then cut off. Cases: enforced (PASS); not enforced (FAIL); the control request fails (INCONCLUSIVE, never a PASS); pods that never start; a pod that
# cannot be created; an exec that is broken (a failed request that is not a block); REQUIRE_NETPOL; the pod manifest; the clean-up on every path; and
# that install.sh runs the check only with CHECK_NETPOL=1.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
# kubectl: drops --context X; records every call; `apply -f -` stores stdin (a NetworkPolicy in it turns the policy on);
# exec wget answers by FAKE_NP: enforced (cut once the policy exists), open (always reached), cut (never reached);
# exec true fails when FAKE_EXEC=broken; wait fails when FAKE_WAIT=fail; apply of pods fails when FAKE_APPLY=fail
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
a=(); while [ \$# -gt 0 ]; do case "\$1" in --context) shift 2;; --context=*) shift;; *) a+=("\$1"); shift;; esac; done
echo "\${a[*]}" >> "$D/calls"
case "\${a[0]}" in
  apply) n=\$(cat "$D/napply" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$D/napply"; cat > "$D/applied.\$n"
         if grep -q 'kind: NetworkPolicy' "$D/applied.\$n"; then touch "$D/policy"; elif [ "\${FAKE_APPLY:-ok}" = fail ]; then echo "Error from server (Forbidden): pods is forbidden" >&2; exit 1; fi;;
  wait) [ "\${FAKE_WAIT:-ok}" != fail ] || { echo "error: timed out waiting for the condition" >&2; exit 1; };;
  get) echo 10.0.0.9;;
  exec) case "\${a[*]}" in
          *wget*) case "\${FAKE_NP:-enforced}" in
                    enforced) if [ -f "$D/policy" ]; then exit 1; else echo ok; fi;;
                    open) echo ok;;
                    cut) exit 1;;
                  esac;;
          *) [ "\${FAKE_EXEC:-ok}" != broken ] || { echo "error: unable to upgrade connection" >&2; exit 1; };;
        esac;;
  delete) : ;;
esac
exit 0
EOS
chmod +x "$D/bin/kubectl"
export KUBECTL="$D/bin/kubectl" NETPOL_SLEEP=0 NETPOL_WAIT=3
S=hack/netpol-check.sh
run(){ rm -f "$D/policy" "$D/napply" "$D"/applied.*; : > "$D/calls"; OUT=$(env "$@" bash "$S" 2>&1); RC=$?; }
last_is_cleanup(){ tail -n 1 "$D/calls" | grep -c '^delete .*-l app.kubernetes.io/name=oa-netpol-probe'; }

echo "# enforced: the deny policy cuts the client"
run FAKE_NP=enforced
t "exit 0" "$RC" 0
t "prints PASS" "$(grep -c '^NetworkPolicy check: PASS' <<<"$OUT")" 1
t "says what it proved: pod to pod, ingress, in the namespace" "$(grep '^NetworkPolicy check: PASS' <<<"$OUT" | grep -c 'openagentix-system')" 1
t "says plainly that it says nothing about egress to the internet" "$(grep -c 'nothing about egress to the internet' <<<"$OUT")" 1
t "cleans up last" "$(last_is_cleanup)" 1
A2=$(grep -n '^apply' "$D/calls" | sed -n 2p | cut -d: -f1); E1=$(grep -n '^exec.*wget' "$D/calls" | head -1 | cut -d: -f1)
t "the policy was applied only after the control request" "$([ -n "$E1" ] && [ -n "$A2" ] && [ "$E1" -lt "$A2" ] && echo yes || echo no)" yes
t "two applies: the pods, then the policy" "$(ls "$D"/applied.* | wc -l | tr -d ' ')" 2

echo "# not enforced: the request still reaches the server"
run FAKE_NP=open
t "exit 0 without REQUIRE_NETPOL" "$RC" 0
t "prints FAIL" "$(grep -c '^NetworkPolicy check: FAIL' <<<"$OUT")" 1
t "says the isolation claims do not hold on this cluster" "$(grep -c 'isolation claims .* do NOT hold on this cluster' <<<"$OUT")" 1
t "says nothing about egress to the internet" "$(grep -c 'nothing about egress to the internet' <<<"$OUT")" 1
t "cleans up last" "$(last_is_cleanup)" 1
run FAKE_NP=open REQUIRE_NETPOL=1
t "REQUIRE_NETPOL=1: exit 1" "$RC" 1
t "REQUIRE_NETPOL=1: still prints FAIL" "$(grep -c '^NetworkPolicy check: FAIL' <<<"$OUT")" 1
run FAKE_NP=enforced REQUIRE_NETPOL=1
t "REQUIRE_NETPOL=1 with PASS: exit 0" "$RC" 0
run FAKE_NP=open REQUIRE_NETPOL=0
t "REQUIRE_NETPOL=0 is not required" "$RC" 0

echo "# the control request fails before any policy: nothing can be said (never a PASS)"
run FAKE_NP=cut
t "prints INCONCLUSIVE" "$(grep -c '^NetworkPolicy check: INCONCLUSIVE' <<<"$OUT")" 1
t "no PASS" "$(grep -c 'NetworkPolicy check: PASS' <<<"$OUT")" 0
t "the policy is not even applied" "$(ls "$D"/applied.* | wc -l | tr -d ' ')" 1
t "exit 0 without REQUIRE_NETPOL" "$RC" 0
t "cleans up last" "$(last_is_cleanup)" 1
run FAKE_NP=cut REQUIRE_NETPOL=1
t "REQUIRE_NETPOL=1: an unproven check also stops the installer (exit 2)" "$RC" 2

echo "# the pods never become Ready"
run FAKE_WAIT=fail REQUIRE_NETPOL=1
t "INCONCLUSIVE" "$(grep -c '^NetworkPolicy check: INCONCLUSIVE' <<<"$OUT")" 1
t "exit 2 when required" "$RC" 2
t "cleans up last" "$(last_is_cleanup)" 1
echo "# a pod cannot be created (quota, admission)"
run FAKE_APPLY=fail
t "INCONCLUSIVE" "$(grep -c '^NetworkPolicy check: INCONCLUSIVE' <<<"$OUT")" 1
t "cleans up last" "$(last_is_cleanup)" 1
echo "# a failed request that is not a block (exec itself is broken)"
run FAKE_NP=enforced FAKE_EXEC=broken
t "no PASS" "$(grep -c 'NetworkPolicy check: PASS' <<<"$OUT")" 0
t "INCONCLUSIVE" "$(grep -c '^NetworkPolicy check: INCONCLUSIVE' <<<"$OUT")" 1

echo "# the pods: restricted, pinned by digest, not privileged"
run FAKE_NP=enforced
P="$D/applied.1"
t "image pinned by digest" "$(grep -cE 'image: [a-z0-9./:-]+@sha256:[0-9a-f]{64}$' "$P")" 2
t "runAsNonRoot" "$(grep -c 'runAsNonRoot: true' "$P")" 2
t "seccomp RuntimeDefault" "$(grep -c 'type: RuntimeDefault' "$P")" 2
t "allowPrivilegeEscalation false" "$(grep -c 'allowPrivilegeEscalation: false' "$P")" 2
t "all capabilities dropped" "$(grep -c 'drop: \[ALL\]' "$P")" 2
t "no service account token" "$(grep -c 'automountServiceAccountToken: false' "$P")" 2
t "read-only root file system" "$(grep -c 'readOnlyRootFilesystem: true' "$P")" 2
t "not privileged, no host network" "$(grep -cE 'privileged: true|hostNetwork|hostPID|hostPath' "$P")" 0
t "both carry the label that the clean-up selects" "$(grep -c 'app.kubernetes.io/name: oa-netpol-probe' "$P")" 2
t "the policy selects only the server" "$(grep -c 'component: server' "$D/applied.2")" 1
t "the policy carries the clean-up label" "$(grep -c 'app.kubernetes.io/name: oa-netpol-probe' "$D/applied.2")" 2
t "the policy is ingress only" "$(grep -c 'policyTypes: \[Ingress\]' "$D/applied.2")" 1
t "every call names the namespace" "$(grep -v '^delete\|^exec' "$D/calls" | grep -vc -- '-n openagentix-system')" 0
run FAKE_NP=enforced NETPOL_NAMESPACE=team-a NETPOL_IMAGE='busybox:1.37@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
t "NETPOL_NAMESPACE and NETPOL_IMAGE are read" "$(grep -c 'team-a' "$D/calls")/$(grep -c 'aaaaaaaa' "$D/applied.1")" "$(grep -c 'team-a' "$D/calls")/2"
run FAKE_NP=enforced NETPOL_IMAGE='busybox:latest'
t "an image without a digest is refused" "$(grep -c '^NetworkPolicy check: INCONCLUSIVE' <<<"$OUT")/$(ls "$D"/applied.* 2>/dev/null | wc -l | tr -d ' ')" "1/0"

echo "# stale probe objects from an earlier run are removed first, and the clean-up is on every exit path"
run FAKE_NP=enforced
t "first call is the removal of stale objects" "$(head -n 1 "$D/calls" | grep -c '^delete .*-l app.kubernetes.io/name=oa-netpol-probe')" 1
t "the clean-up is on EXIT, INT, TERM and HUP" "$(grep -c '^trap .* EXIT INT TERM HUP' "$S")" 1
t "the script only deletes by the probe's label" "$(grep '^delete' "$D/calls" | grep -vc 'app.kubernetes.io/name=oa-netpol-probe')" 0

echo "# the installer: off by default, on with CHECK_NETPOL=1, after the chart"
H=$(grep -n '^helm upgrade --install' install.sh | head -1 | cut -d: -f1)
C=$(grep -n 'netpol-check.sh' install.sh | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)
t "install.sh runs the check" "$([ -n "$C" ] && echo yes || echo no)" yes
t "after helm upgrade" "$([ -n "$C" ] && [ "$C" -gt "$H" ] && echo yes || echo no)" yes
t "only when CHECK_NETPOL=1" "$(sed -n "$((C-2)),${C}p" install.sh | grep -c 'CHECK_NETPOL:-0.* = 1')" 1
t "its failure stops the installer (exit non-zero)" "$(sed -n "${C}p" install.sh | grep -c '|| exit')" 1
t "the release namespace is passed" "$(sed -n "${C}p" install.sh | grep -c 'NETPOL_NAMESPACE=.\$RELEASE_NS')" 1

[ "$F" = 0 ] && echo "netpol-check tests: ok" || { echo "netpol-check tests: FAILED"; exit 1; }
