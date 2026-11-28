#!/usr/bin/env bash
# Tests for hack/kb-callers.sh with a fake `kubectl` and a fake `openssl` (no cluster): the value of each tool group for the knowledge base (ADR 0030
# section 2) and the refusal to turn enforce off (section 6). The value is a canary here, so that every recorded call, every line of output and
# every state file can be searched for it. Nothing may carry it except the two Secrets.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/state"
CANARY=canary0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab
cat > "$D/bin/openssl" <<EOS
#!/usr/bin/env bash
echo "openssl \$*" >> "$D/openssl-calls"
n=\$(wc -l < "$D/openssl-calls" | tr -d ' ')
echo ${CANARY}\$n
EOS
# kubectl: Secrets are files state/<ns>__<name>/<key> (the plain value). Every call is recorded, with its arguments.
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
S="$D/state"
case "\$*" in
  "get secret -n "*)
    ns=\$4; name=\$5; key=\${7#jsonpath=\{.data.}; key=\${key%\}}
    [ "\${FAKE_GET_FAIL:-0}" != 1 ] || { echo "Unable to connect to the server: dial tcp: i/o timeout" >&2; exit 1; }
    f="\$S/\${ns}__\${name}/\$key"; [ -f "\$f" ] || { [ -d "\$S/\${ns}__\${name}" ] && exit 0; echo "Error from server (NotFound): secrets \"\$name\" not found" >&2; exit 1; }
    base64 < "\$f" | tr -d '\n'; exit 0;;
  "create secret generic "*)
    name=\$4; ns=\$6; spec=\${7#--from-file=}; key=\${spec%%=*}; path=\${spec#*=}
    printf 'name=%s\nns=%s\nkey=%s\nvalue=%s\n' "\$name" "\$ns" "\$key" "\$(base64 < "\$path" | tr -d '\n')"; exit 0;;
  "apply "*)
    [ "\${FAKE_APPLY_FAIL:-0}" != 1 ] || { echo "error: the value CANARY-NOT-REAL is refused" >&2; exit 1; }
    in=\$(cat); name=\$(sed -n 's/^name=//p' <<<"\$in"); ns=\$(sed -n 's/^ns=//p' <<<"\$in"); key=\$(sed -n 's/^key=//p' <<<"\$in"); v=\$(sed -n 's/^value=//p' <<<"\$in")
    mkdir -p "\$S/\${ns}__\${name}"; printf '%s' "\$v" | base64 -d > "\$S/\${ns}__\${name}/\$key"; exit 0;;
esac
exit 0
EOS
chmod +x "$D/bin/"*
run() { : > "$D/calls"; PATH="$D/bin:$PATH" bash -c '. hack/kb-callers.sh; kb_callers_ensure kubectl openagentix-knowledge mcp-tools "$@"; r=$?; echo "changed=${KB_CALLERS_CHANGED:-unset}"; exit $r' _ "$@" 2>&1; echo "exit=$?"; }
K="$D/state/openagentix-knowledge__kb-callers"
M="$D/state/mcp-tools"
rm -rf "$D/state"; mkdir -p "$D/state"; : > "$D/openssl-calls"

echo "# a fresh install makes one value per group and writes it to both Secrets"
OUT=$(run tools disputes)
V1="Bearer ${CANARY}1"; V2="Bearer ${CANARY}2"
t "exit 0" "$(/usr/bin/grep -c '^exit=0$' <<<"$OUT")" 1
t "kb-callers key tools holds the whole header value" "$(cat "$K/tools" 2>/dev/null)" "$V1"
t "kb-callers key disputes holds its own value" "$(cat "$K/disputes" 2>/dev/null)" "$V2"
t "the tools namespace Secret of the shared group holds the same value" "$(cat "${M}__kb-caller-tools/value" 2>/dev/null)" "$V1"
t "the tools namespace Secret of disputes holds the same value" "$(cat "${M}__kb-caller-disputes/value" 2>/dev/null)" "$V2"
t "the two groups have different values" "$([ "$V1" != "$V2" ] && echo different)" different
t "one openssl call per group" "$(wc -l < "$D/openssl-calls" | tr -d ' ')" 2
t "no line of output holds a value" "$(/usr/bin/grep -c "$CANARY" <<<"$OUT")" 0
t "no kubectl call holds a value, in any argument" "$(/usr/bin/grep -c "$CANARY" "$D/calls")" 0
t "no kubectl call holds the scheme word (Bearer)" "$(/usr/bin/grep -c 'Bearer' "$D/calls")" 0
t "the Secrets are written with server-side apply, one field manager per group (a key never clobbers another)" "$(/usr/bin/grep -c '^kubectl apply --server-side --force-conflicts --field-manager=openagentix-kb-caller-disputes -f -$' "$D/calls")" 2
t "the Secrets are never made with --from-literal" "$(/usr/bin/grep -c 'from-literal' "$D/calls")" 0
t "the output says created, four times" "$(/usr/bin/grep -c 'created$' <<<"$OUT")" 4

echo "# a second run keeps everything and writes nothing"
: > "$D/openssl-calls"
OUT=$(run tools disputes)
t "kept, four times" "$(/usr/bin/grep -c 'kept$' <<<"$OUT")" 4
t "no apply, no new value" "$(/usr/bin/grep -c '^kubectl apply' "$D/calls")/$(wc -l < "$D/openssl-calls" | tr -d ' ')" 0/0
t "the values are unchanged" "$(cat "$K/tools") $(cat "$K/disputes")" "$V1 $V2"
t "changed=0" "$(/usr/bin/grep -c '^changed=0$' <<<"$OUT")" 1

echo "# a group added later gets its own value and leaves the others alone"
: > "$D/openssl-calls"
OUT=$(run tools disputes dealer)
t "the new group has a value" "$(cat "$K/dealer" 2>/dev/null)" "Bearer ${CANARY}1"
t "the old values are unchanged" "$(cat "$K/tools") $(cat "$K/disputes")" "$V1 $V2"

echo "# a missing Secret is rebuilt from the other one, never with a new value"
rm -rf "${M}__kb-caller-disputes"; : > "$D/openssl-calls"
OUT=$(run disputes)
t "the Secret in the tools namespace is back, with the same value" "$(cat "${M}__kb-caller-disputes/value" 2>/dev/null)" "$V2"
t "no new value was made" "$(wc -l < "$D/openssl-calls" | tr -d ' ')" 0
t "it says repaired, and that a value that existed was repaired (the vMCPs hold the old one)" "$(/usr/bin/grep -c 'repaired$' <<<"$OUT")/$(/usr/bin/grep -c '^changed=1$' <<<"$OUT")" 1/1
rm -rf "$K/disputes"; : > "$D/openssl-calls"
OUT=$(run disputes)
t "the key of kb-callers is back from the tools namespace Secret" "$(cat "$K/disputes" 2>/dev/null)" "$V2"
t "no new value was made either" "$(wc -l < "$D/openssl-calls" | tr -d ' ')" 0

echo "# failures stop the installer and say nothing about a value"
OUT=$(FAKE_GET_FAIL=1 run tools)
t "an unreadable API stops with exit 1" "$(/usr/bin/grep -c '^exit=1$' <<<"$OUT")" 1
t "and says nothing was changed" "$(/usr/bin/grep -c 'Nothing was changed' <<<"$OUT")" 1
rm -rf "$D/state"; mkdir -p "$D/state"
OUT=$(FAKE_APPLY_FAIL=1 run tools)
t "a refused write stops with exit 1" "$(/usr/bin/grep -c '^exit=1$' <<<"$OUT")" 1
t "and the output holds no value" "$(/usr/bin/grep -c "$CANARY" <<<"$OUT")" 0

echo "# the refusal to turn enforce off"
g() { bash -c '. hack/kb-callers.sh; kb_access_guard "$@"; echo "exit=$?"' _ "$@" 2>&1; }
t "enforce to enforce passes" "$(g enforce enforce "" | /usr/bin/grep -c '^exit=0$')" 1
t "report to empty passes (only enforce is guarded)" "$(g report "" "" | /usr/bin/grep -c '^exit=0$')" 1
t "empty to enforce passes" "$(g "" enforce "" | /usr/bin/grep -c '^exit=0$')" 1
OUT=$(g enforce "" "")
t "enforce to empty is refused" "$(/usr/bin/grep -c '^exit=1$' <<<"$OUT")" 1
t "the sentence names ALLOW_KB_ACCESS_OFF and says nothing was changed" "$(/usr/bin/grep -c 'ALLOW_KB_ACCESS_OFF=1.*Nothing was changed' <<<"$OUT")" 1
t "enforce to report is refused" "$(g enforce report "" | /usr/bin/grep -c '^exit=1$')" 1
OUT=$(g enforce "" 1)
t "ALLOW_KB_ACCESS_OFF=1 lets it through with a warning" "$(/usr/bin/grep -c '^exit=0$' <<<"$OUT")/$(/usr/bin/grep -c '^WARN' <<<"$OUT")" 1/1

echo "# install.sh wires it in"
t "install.sh sources hack/kb-callers.sh" "$(/usr/bin/grep -c '^[[:space:]]*\. hack/kb-callers.sh' install.sh)" 1
t "install.sh calls kb_callers_ensure and kb_access_guard" "$(/usr/bin/grep -c 'kb_callers_ensure\|kb_access_guard' install.sh | awk '{print ($1>=2)}')" 1
exit "$F"
