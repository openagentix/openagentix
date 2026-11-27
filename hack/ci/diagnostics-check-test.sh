#!/usr/bin/env bash
# Tests for hack/diagnostics-check.sh with a fake `kubectl` and a fake `sleep` (no cluster): the installer fails when a vMCP of the diagnostics
# group has a DiscoveredAuthConfig-* condition that is False (ToolHive keeps such a vMCP Ready with fewer backends).
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "%s/sleeps"\n' "$D" > "$D/bin/sleep"
# kubectl: `get virtualmcpserver <name> -n <ns> -o json` answers with the file $D/<name>.json (exit 1 when there is none); calls are recorded
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
[ "\$1 \$2" = "get virtualmcpserver" ] || exit 0
f="$D/\$3.json"; [ -f "\$f" ] || exit 1
# a file named <name>.json.2 is the answer from the second call on (conditions that show up late)
n=\$(cat "$D/n-\$3" 2>/dev/null || echo 0); echo \$((n+1)) > "$D/n-\$3"
if [ "\$n" -ge 1 ] && [ -f "\$f.2" ]; then cat "\$f.2"; else cat "\$f"; fi
EOS
chmod +x "$D/bin/"*
cond() { printf '{"type":"%s","status":"%s","reason":"%s","message":"the secret value is hunter2"}' "$1" "$2" "$3"; }
vmcp() { printf '{"status":{"conditions":[%s]}}\n' "$1"; }
run() { rm -f "$D/sleeps" "$D"/n-*; : > "$D/calls"; PATH="$D/bin:$PATH" bash -c '. hack/diagnostics-check.sh; diag_check_vmcps kubectl "$@"' _ "$@" 2>&1; echo "exit=$?"; }

echo "# every condition True: passes"
vmcp "$(cond Ready True ok),$(cond DiscoveredAuthConfig-cluster-read True ok),$(cond DiscoveredAuthConfig-knowledge-diagnostics True ok)" > "$D/tools-rca.json"
OUT=$(run 30 2 mcp-tools/tools-rca)
t "exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "it says two conditions, none False" "$(grep -c 'tools-rca: 2 DiscoveredAuthConfig condition(s), none False' <<<"$OUT")" 1
t "it did not wait (the conditions were there)" "$(cat "$D/sleeps" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "# one False: fails, names the vMCP, the type and the reason, and never repeats a message"
vmcp "$(cond Ready True ok),$(cond DiscoveredAuthConfig-cluster-read False 'unsupported auth type: bearerToken'),$(cond DiscoveredAuthConfig-knowledge-diagnostics True ok)" > "$D/tools-rca.json"
OUT=$(run 30 2 mcp-tools/tools-rca)
t "exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "it names the vMCP and the condition" "$(grep -c 'tools-rca dropped a backend of the diagnostics group: DiscoveredAuthConfig-cluster-read (unsupported auth type: bearerToken)' <<<"$OUT")" 1
t "it does not repeat the message of the condition" "$(grep -c hunter2 <<<"$OUT")" 0
t "it gave up at once, without waiting" "$(cat "$D/sleeps" 2>/dev/null | wc -l | tr -d ' ')" 0

echo "# a False among several vMCPs fails the whole check; the ones before it are reported"
vmcp "$(cond DiscoveredAuthConfig-cluster-read True ok)" > "$D/tools-a.json"
vmcp "$(cond DiscoveredAuthConfig-cluster-read False x)" > "$D/tools-b.json"
vmcp "$(cond DiscoveredAuthConfig-cluster-read True ok)" > "$D/tools-c.json"
OUT=$(run 30 1 mcp-tools/tools-a mcp-tools/tools-b mcp-tools/tools-c)
t "exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "the first is reported good, the second named, the third not reached" "$(grep -c 'tools-a: 1 Disc' <<<"$OUT")/$(grep -c 'tools-b dropped' <<<"$OUT")/$(grep -c 'tools-c' <<<"$OUT")" 1/1/0

echo "# conditions that show up late are waited for; a False that shows up late still fails"
vmcp "$(cond Ready True ok)" > "$D/tools-rca.json"
vmcp "$(cond DiscoveredAuthConfig-cluster-read True ok),$(cond DiscoveredAuthConfig-delivery-diagnostics True ok)" > "$D/tools-rca.json.2"
OUT=$(run 30 2 mcp-tools/tools-rca)
t "passes once both conditions show" "$(grep -c '^exit=0$' <<<"$OUT")/$(grep -c 'tools-rca: 2 Disc' <<<"$OUT")" 1/1
t "it waited one round (3 s)" "$(cat "$D/sleeps" | wc -l | tr -d ' ')" 1
vmcp "$(cond DiscoveredAuthConfig-cluster-read True ok)" > "$D/tools-rca.json"
vmcp "$(cond DiscoveredAuthConfig-cluster-read True ok),$(cond DiscoveredAuthConfig-delivery-diagnostics False 'unsupported auth type')" > "$D/tools-rca.json.2"
OUT=$(run 30 2 mcp-tools/tools-rca)
t "a False that shows up late fails" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'DiscoveredAuthConfig-delivery-diagnostics' <<<"$OUT")" 1/1
rm -f "$D/tools-rca.json.2"

echo "# conditions that never show: a warning, not a failure (a missing condition cannot be told from a slow one)"
vmcp "$(cond Ready True ok)" > "$D/tools-rca.json"
OUT=$(run 6 2 mcp-tools/tools-rca)
t "exit 0 with a WARN that says 0 of 2" "$(grep -c '^exit=0$' <<<"$OUT")/$(grep -c 'WARN: the vMCP tools-rca shows 0 of 2 DiscoveredAuthConfig conditions after 6s; none is False' <<<"$OUT")" 1/1
t "it waited in steps of 3 seconds, twice" "$(cat "$D/sleeps" | wc -l | tr -d ' ')" 2
rm -f "$D/tools-rca.json"
OUT=$(run 3 1 mcp-tools/tools-rca)
t "a vMCP that cannot be read is a warning too (not a failure), and no message is invented" "$(grep -c '^exit=0$' <<<"$OUT")/$(grep -c 'WARN' <<<"$OUT")" 1/1

echo "# the installer uses it"
t "install.sh sources hack/diagnostics-check.sh" "$(grep -c '^[[:space:]]*\. hack/diagnostics-check.sh' install.sh)" 1
t "install.sh calls diag_check_vmcps and stops the install on its failure" "$(grep -c 'diag_check_vmcps .* || die' install.sh)" 1
[ "$F" = 0 ] && echo "diagnostics-check-test: all passed" || { echo "diagnostics-check-test: FAILED"; exit 1; }
