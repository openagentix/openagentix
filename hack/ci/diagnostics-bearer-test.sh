#!/usr/bin/env bash
# Tests for hack/diagnostics-bearer.sh with a fake `kubectl` and a fake `openssl` (no cluster): the bearer value between the tool gateway and a
# diagnostics server (ADR 0025 section 5). The value is a canary here, so that every recorded call, every line of output and every state file
# can be searched for it. Nothing may carry it except the two Secrets.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin" "$D/state"
CANARY=canary0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab
# openssl: a fixed value, and a record that it was asked
cat > "$D/bin/openssl" <<EOS
#!/usr/bin/env bash
echo "openssl \$*" >> "$D/openssl-calls"
echo $CANARY
EOS
# kubectl: Secrets are files state/<ns>__<name>/<key> (the plain value). Every call is recorded, with its arguments.
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
S="$D/state"
case "\$*" in
  "get secret -n "*)
    ns=\$4; name=\$5; key=\${7#jsonpath=\{.data.}; key=\${key%\}}
    f="\$S/\${ns}__\${name}/\$key"; [ -f "\$f" ] || exit 1
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
run() { : > "$D/calls"; PATH="$D/bin:$PATH" bash -c '. hack/diagnostics-bearer.sh; diag_bearer_ensure kubectl mcp-tools openagentix-diagnostics cluster-read' 2>&1; echo "exit=$?"; }
SERVER="$D/state/openagentix-diagnostics__cluster-read-bearer/bearer"
HEADER="$D/state/mcp-tools__diagnostics-bearer-cluster-read/authorization"
rm -rf "$D/state"; mkdir -p "$D/state"; : > "$D/openssl-calls"

echo "# a fresh install creates both Secrets with one value"
OUT=$(run)
t "exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "the server Secret holds the value alone" "$(cat "$SERVER" 2>/dev/null)" "$CANARY"
t "the tool gateway's Secret holds 'Bearer <value>' (ToolHive sends the Secret as the header value)" "$(cat "$HEADER" 2>/dev/null)" "Bearer $CANARY"
t "the value was made once, with openssl rand -hex 32" "$(cat "$D/openssl-calls")" "openssl rand -hex 32"
t "the output says created, twice" "$(grep -c 'created$' <<<"$OUT")" 2
t "no line of output holds the value" "$(grep -c "$CANARY" <<<"$OUT")" 0
t "no kubectl call holds the value, in any argument" "$(grep -c "$CANARY" "$D/calls")" 0
t "no kubectl call holds the scheme word with a value (Bearer)" "$(grep -c 'Bearer' "$D/calls")" 0
t "the Secrets are written with server-side apply (no last-applied annotation can hold the value)" "$(grep -c '^kubectl apply --server-side --force-conflicts --field-manager=openagentix-diagnostics -f -$' "$D/calls")" 2
t "the Secrets are never made with --from-literal" "$(grep -c 'from-literal' "$D/calls")" 0

echo "# a second run keeps both and writes nothing"
: > "$D/openssl-calls"
OUT=$(run)
t "kept, twice" "$(grep -c 'kept$' <<<"$OUT")" 2
t "no apply, no new value" "$(grep -c '^kubectl apply' "$D/calls")/$(wc -l < "$D/openssl-calls" | tr -d ' ')" 0/0
t "the value is unchanged" "$(cat "$SERVER")" "$CANARY"

echo "# a missing Secret is rebuilt from the other one, never with a new value"
rm -rf "$D/state/openagentix-diagnostics__cluster-read-bearer"; : > "$D/openssl-calls"
OUT=$(run)
t "the server Secret is created again, with the same value" "$(cat "$SERVER" 2>/dev/null)" "$CANARY"
t "no new value was made" "$(wc -l < "$D/openssl-calls" | tr -d ' ')" 0
t "the tool gateway's Secret was kept" "$(grep -c 'diagnostics-bearer-cluster-read: kept' <<<"$OUT")" 1
rm -rf "$D/state/mcp-tools__diagnostics-bearer-cluster-read"
OUT=$(run)
t "the tool gateway's Secret is created again from the server's" "$(cat "$HEADER" 2>/dev/null)" "Bearer $CANARY"
t "no new value was made (again)" "$(wc -l < "$D/openssl-calls" | tr -d ' ')" 0

echo "# when the two differ, the server's own Secret wins"
printf 'Bearer someoneelse' > "$HEADER"
OUT=$(run)
t "the tool gateway's Secret is repaired" "$(cat "$HEADER")" "Bearer $CANARY"
t "it says repaired" "$(grep -c 'repaired$' <<<"$OUT")" 1
t "the server's Secret is not touched" "$(cat "$SERVER")" "$CANARY"

echo "# a failure says so in a fixed sentence and never repeats a value"
rm -rf "$D/state"; mkdir -p "$D/state"
OUT=$(FAKE_APPLY_FAIL=1 run)
t "exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "a fixed message names the Secret" "$(grep -c 'ERROR: could not write Secret openagentix-diagnostics/cluster-read-bearer' <<<"$OUT")" 1
t "the output holds neither the value nor the error text of kubectl" "$(grep -c "$CANARY\|CANARY-NOT-REAL" <<<"$OUT")" 0

echo "# the installer uses it"
t "install.sh sources hack/diagnostics-bearer.sh" "$(grep -c '^[[:space:]]*\. hack/diagnostics-bearer.sh' install.sh)" 1
t "install.sh calls diag_bearer_ensure for cluster-read" "$(grep -c 'diag_bearer_ensure ' install.sh)" 1
t "no other file of the installer writes a bearer value with --from-literal" "$(grep -hc 'from-literal=.*bearer' install.sh hack/diagnostics-bearer.sh | paste -sd+ - | bc)" 0
[ "$F" = 0 ] && echo "diagnostics-bearer-test: all passed" || { echo "diagnostics-bearer-test: FAILED"; exit 1; }
