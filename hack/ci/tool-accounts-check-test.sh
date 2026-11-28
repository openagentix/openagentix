#!/usr/bin/env bash
# Tests for hack/tool-accounts-check.sh (ADR 0031, slice 3), with a fake `kubectl` and a fake `sleep` (no cluster): the install check (a yes from `can-i` fails
# the install and names the account), the clean-up (only the operator's `<name>-vmcp` objects of the tool servers the chart renders, and only once the
# tool server runs under the chart's account), the refusal to turn the switch off, the warning, and that no call reads a Secret.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
printf '#!/usr/bin/env bash\necho "sleep $*" >> "%s/sleeps"\n' "$D" > "$D/bin/sleep"
# kubectl: `auth can-i <verb> <resource> -n <ns> --as=system:serviceaccount:<ns>:<sa>` answers yes when the file $D/yes-<sa>-<verb>-<resource> exists, "error" (exit 2,
# no yes/no on stdout) when $D/err-<sa> exists, else no (exit 1, as the real one). `get deployment <name> -n <ns> -o jsonpath=...` answers with $D/sa-<name>.
# `get virtualmcpserver -n <ns> -o json` answers with $D/live-<ns>.json (exit 1 when there is none). `rollout status` and `delete` are recorded.
cat > "$D/bin/kubectl" <<EOS
#!/usr/bin/env bash
echo "kubectl \$*" >> "$D/calls"
case "\$1 \$2" in
  "auth can-i")
    sa=\${@: -1}; sa=\${sa##*:}
    if [ -f "$D/err-\$sa" ]; then echo "error: boom" >&2; exit 2; fi
    if [ -f "$D/yes-\$sa-\$3-\$4" ]; then echo yes; exit 0; fi
    echo no; exit 1;;
  "get serviceaccount"|"get role"|"get rolebinding") f="$D/own-\$2-\$3.json"; [ -f "\$f" ] || { echo "Error from server (NotFound): \$2 \\"\$3\\" not found" >&2; exit 1; }; cat "\$f";;
  "get deployment") [ -f "$D/sa-\$3" ] || exit 1; cat "$D/sa-\$3";;
  "get virtualmcpserver") f="$D/live-\$4.json"
    if [ -f "$D/apierr-\$4" ]; then cat "$D/apierr-\$4" >&2; exit 1; fi
    if [ ! -f "\$f" ]; then echo "error: the server doesn't have a resource type \"virtualmcpserver\"" >&2; exit 1; fi; cat "\$f";;
  "rollout status") [ -f "$D/norollout-\${3#deployment/}" ] && exit 1; echo "rolled out";;
esac
exit 0
EOS
chmod +x "$D/bin/"*
run() { rm -f "$D/sleeps"; : > "$D/calls"; PATH="$D/bin:$PATH" bash -c '. hack/tool-accounts-check.sh; '"$1" _ "${@:2}" 2>&1; echo "exit=$?"; }
vm() { printf '{"kind":"VirtualMCPServer","metadata":{"name":"%s","namespace":"mcp-tools"},"spec":{"groupRef":{"name":"%s"}%s}}\n' "$1" "$2" "${3:+,\"serviceAccount\":\"$3\"}"; }
entry() { printf '{"kind":"MCPServerEntry","metadata":{"name":"%s","namespace":"mcp-tools"},"spec":{"groupRef":{"name":"%s"},"headerForward":{"addHeadersFromSecret":[{"headerName":"Authorization","valueSecretRef":{"name":"%s","key":"value"}}]}}}\n' "$1" "$2" "$3"; }
ON="$(vm tools tools openagentix-tools; vm tools-disputes disputes openagentix-tools-disputes; vm tools-disputes-workload disputes openagentix-tools-disputes-workload; entry records disputes records-mcp-auth)"
OFF="$(vm tools tools; vm tools-disputes disputes; entry records disputes records-mcp-auth)"
NOCRED="$(vm tools tools; vm tools-lookup tools)"

echo "# the rows of the tool servers that have a chart account, and those that have none"
OUT=$(run 'ta_vmcp_rows <<<"$1"' "$ON")
t "three tool servers with their accounts" "$(grep -c $'^mcp-tools\t' <<<"$OUT")" 3
t "a row is namespace, name, account" "$(grep -c $'^mcp-tools\ttools-disputes\topenagentix-tools-disputes$' <<<"$OUT")" 1
t "the -workload variant has its own account" "$(grep -c $'^mcp-tools\ttools-disputes-workload\topenagentix-tools-disputes-workload$' <<<"$OUT")" 1
OUT=$(run 'ta_unowned_rows <<<"$1"' "$OFF")
t "off: two tool servers without an account" "$(grep -c $'^mcp-tools\t' <<<"$OUT")" 2
OUT=$(run 'ta_unowned_rows <<<"$1"' "$ON")
t "on: none without an account" "$(grep -c $'^mcp-tools\t' <<<"$OUT")" 0

echo "# the install check: five questions as each account, all no"
OUT=$(run 'ta_check_account kubectl mcp-tools openagentix-tools')
t "all no: exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "it asked get secrets, list secrets, create pods, statefulsets and deployments, as that account in that namespace" "$(grep -c '^kubectl auth can-i \(get secrets\|list secrets\|create pods\|create statefulsets\|create deployments\) -n mcp-tools --as=system:serviceaccount:mcp-tools:openagentix-tools$' "$D/calls")" 5
t "it says the account has no such right" "$(grep -c 'openagentix-tools: no right on Secrets, and none to create pods, StatefulSets or Deployments' <<<"$OUT")" 1
for q in 'get secrets' 'list secrets' 'create pods' 'create statefulsets' 'create deployments'; do
  rm -f "$D"/yes-*; : > "$D/yes-openagentix-tools-disputes-${q% *}-${q#* }"
  OUT=$(run 'ta_check_account kubectl mcp-tools openagentix-tools-disputes')
  t "a yes for '$q': exit 1, naming the account and the question" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c "ERROR: the account openagentix-tools-disputes in mcp-tools can $q" <<<"$OUT")" 1/1
done
rm -f "$D"/yes-*
: > "$D/err-openagentix-tools"
OUT=$(run 'ta_check_account kubectl mcp-tools openagentix-tools')
t "an answer that is neither yes nor no (an API error) fails: the check cannot tell" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'cannot tell' <<<"$OUT")" 1/5
rm -f "$D/err-openagentix-tools"

echo "# waiting until a tool server runs under the chart's account"
printf 'openagentix-tools' > "$D/sa-tools"
OUT=$(run 'ta_wait_running kubectl mcp-tools tools openagentix-tools 30')
t "the Deployment names the account and rolled out: exit 0, no wait" "$(grep -c '^exit=0$' <<<"$OUT")/$(cat "$D/sleeps" 2>/dev/null | wc -l | tr -d ' ')" 1/0
printf 'tools-vmcp' > "$D/sa-tools"
OUT=$(run 'ta_wait_running kubectl mcp-tools tools openagentix-tools 6')
t "the Deployment still names the old account after the time: exit 1, naming both" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'runs as tools-vmcp, not openagentix-tools' <<<"$OUT")" 1/1
t "it waited in steps of 3 seconds" "$(wc -l < "$D/sleeps" | tr -d ' ')" 2
printf 'openagentix-tools' > "$D/sa-tools"; : > "$D/norollout-tools"
OUT=$(run 'ta_wait_running kubectl mcp-tools tools openagentix-tools 0')
t "a rollout that does not finish fails" "$(grep -c '^exit=1$' <<<"$OUT")" 1
rm -f "$D/norollout-tools"

owned() { for kd in serviceaccount role rolebinding; do printf '{"metadata":{"name":"%s-vmcp","ownerReferences":[{"apiVersion":"toolhive.stacklok.dev/v1beta1","kind":"VirtualMCPServer","name":"%s","controller":true}]}}\n' "$1" "$1" > "$D/own-$kd-$1-vmcp.json"; done; }
owned tools-disputes
echo "# clean-up of the operator's objects"
printf 'openagentix-tools-disputes' > "$D/sa-tools-disputes"
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes openagentix-tools-disputes')
t "exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
t "it deletes the ServiceAccount, the Role and the RoleBinding tools-disputes-vmcp" "$(grep -c '^kubectl delete \(serviceaccount\|role\|rolebinding\) tools-disputes-vmcp -n mcp-tools --ignore-not-found$' "$D/calls")" 3
t "it deletes nothing else" "$(grep -c '^kubectl delete' "$D/calls")" 3
t "it read each of the three objects before it deleted it" "$(grep -c '^kubectl get \(serviceaccount\|role\|rolebinding\) tools-disputes-vmcp -n mcp-tools -o json$' "$D/calls")" 3
t "it never touches the chart's own objects" "$(grep -c 'delete.*openagentix-' "$D/calls")" 0
printf 'tools-disputes-vmcp' > "$D/sa-tools-disputes"
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes openagentix-tools-disputes')
t "while the tool server still runs as the old account: nothing is deleted, exit 1" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c '^kubectl delete' "$D/calls")" 1/0
printf 'openagentix-tools-disputes' > "$D/sa-tools-disputes"
echo "# an object of that name that is not the operator's is left alone, and said"
for kd in serviceaccount role rolebinding; do printf '{"metadata":{"name":"tools-disputes-vmcp","ownerReferences":[{"kind":"Deployment","name":"somebody"}]}}\n' > "$D/own-$kd-tools-disputes-vmcp.json"; done
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes openagentix-tools-disputes')
t "owned by something else: nothing is deleted, three WARNING lines, exit 0 (the install goes on)" "$(grep -c '^kubectl delete' "$D/calls")/$(grep -c 'is not owned by the VirtualMCPServer tools-disputes: left alone' <<<"$OUT")/$(grep -c '^exit=0$' <<<"$OUT")" 0/3/1
for kd in serviceaccount role rolebinding; do printf '{"metadata":{"name":"tools-disputes-vmcp"}}\n' > "$D/own-$kd-tools-disputes-vmcp.json"; done
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes openagentix-tools-disputes')
t "no owner reference at all: left alone too" "$(grep -c '^kubectl delete' "$D/calls")/$(grep -c 'left alone' <<<"$OUT")" 0/3
printf '{"metadata":{"name":"tools-disputes-vmcp","ownerReferences":[{"kind":"VirtualMCPServer","name":"tools"}]}}\n' > "$D/own-role-tools-disputes-vmcp.json"
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes openagentix-tools-disputes')
t "owned by ANOTHER tool server (the name differs): left alone" "$(grep -c '^kubectl delete' "$D/calls")/$(grep -c 'role tools-disputes-vmcp in mcp-tools is not owned' <<<"$OUT")" 0/1
rm -f "$D"/own-*; : > /dev/null
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes openagentix-tools-disputes')
t "objects that do not exist (the operator never made them): nothing to delete, exit 0" "$(grep -c '^kubectl delete' "$D/calls")/$(grep -c '^exit=0$' <<<"$OUT")" 0/1
owned tools-disputes
rm -f "$D/sa-tools-disputes"
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes openagentix-tools-disputes')
t "a Deployment that cannot be read: nothing is deleted, exit 1" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c '^kubectl delete' "$D/calls")" 1/0
OUT=$(run 'ta_cleanup kubectl mcp-tools "tools disputes" openagentix-x')
t "a name with a space is refused (nothing is deleted)" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c '^kubectl delete' "$D/calls")" 1/0
OUT=$(run 'ta_cleanup kubectl mcp-tools tools-disputes tools-disputes-vmcp')
t "the account to keep may not be the operator's own name (nothing is deleted)" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c '^kubectl delete' "$D/calls")" 1/0

echo "# turning the switch off on a live release is refused"
printf '{"items":[{"metadata":{"name":"tools"},"spec":{"serviceAccount":"openagentix-tools"}},{"metadata":{"name":"tools-disputes"},"spec":{}}]}\n' > "$D/live-mcp-tools.json"
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "live tool server on a chart account, rendered without: exit 1" "$(grep -c '^exit=1$' <<<"$OUT")" 1
t "the message names the tool server, the switch and the way out" "$(grep -c 'tools' <<<"$OUT")/$(grep -c 'mcp.virtual.ownServiceAccounts' <<<"$OUT")/$(grep -c 'ALLOW_TOOL_SECRET_READ=1' <<<"$OUT")" 1/1/1
OUT=$(ALLOW_TOOL_SECRET_READ=1 run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "with ALLOW_TOOL_SECRET_READ=1: exit 0 and a WARNING" "$(grep -c '^exit=0$' <<<"$OUT")/$(grep -c 'WARNING' <<<"$OUT")" 1/1
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$ON")
t "rendered with the accounts: exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
printf '{"items":[{"metadata":{"name":"tools"},"spec":{}}]}\n' > "$D/live-mcp-tools.json"
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "live tool servers without accounts, rendered without: exit 0 (nothing is turned off)" "$(grep -c '^exit=0$' <<<"$OUT")" 1
rm -f "$D/live-mcp-tools.json"
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "no tool server in the cluster yet (a first install): exit 0" "$(grep -c '^exit=0$' <<<"$OUT")" 1
printf '{"items":[{"metadata":{"name":"somebody-else"},"spec":{"serviceAccount":"openagentix-somebody-else"}}]}\n' > "$D/live-mcp-tools.json"
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "a live tool server the chart does not render does not count" "$(grep -c '^exit=0$' <<<"$OUT")" 1
rm -f "$D/live-mcp-tools.json"

echo "# an API error is not a reason to skip the refusal: only a missing resource type is"
printf '{"items":[{"metadata":{"name":"tools"},"spec":{"serviceAccount":"openagentix-tools"}}]}\n' > "$D/live-mcp-tools.json"
printf 'Unable to connect to the server: net/http: request canceled (Client.Timeout exceeded while awaiting headers)\n' > "$D/apierr-mcp-tools"
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "a timeout on the read of the tool servers: exit 1, cannot tell, nothing was changed" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'cannot tell' <<<"$OUT")/$(grep -c 'Nothing was changed' <<<"$OUT")" 1/1/1
printf 'Error from server (Forbidden): virtualmcpservers.toolhive.stacklok.dev is forbidden: User "x" cannot list resource in the namespace "mcp-tools"\n' > "$D/apierr-mcp-tools"
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "a Forbidden on the read: exit 1, cannot tell" "$(grep -c '^exit=1$' <<<"$OUT")/$(grep -c 'cannot tell' <<<"$OUT")" 1/1
OUT=$(ALLOW_TOOL_SECRET_READ=1 run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "... also with ALLOW_TOOL_SECRET_READ=1 (the override is for a decision, not for a read that failed)" "$(grep -c '^exit=1$' <<<"$OUT")" 1
rm -f "$D/apierr-mcp-tools" "$D/live-mcp-tools.json"
OUT=$(run 'ta_refuse_off kubectl <<<"$1"' "$OFF")
t "the resource type does not exist (no ToolHive CRDs yet): exit 0, nothing to turn off" "$(grep -c '^exit=0$' <<<"$OUT")" 1

echo "# the warning while the switch is off and credentials exist"
OUT=$(run 'ta_warn_off <<<"$1"' "$OFF")
t "off with a header Secret: a WARNING naming the Secret and the switch" "$(grep -c 'WARNING' <<<"$OUT")/$(grep -c 'mcp-tools/records-mcp-auth' <<<"$OUT")/$(grep -c 'mcp.virtual.ownServiceAccounts' <<<"$OUT")" 1/1/2
OUT=$(run 'ta_warn_off <<<"$1"' "$ON")
t "on: no warning" "$(grep -c 'WARNING' <<<"$OUT")" 0
OUT=$(run 'ta_warn_off <<<"$1"' "$NOCRED")
t "off, no credential in the install: no warning" "$(grep -c 'WARNING' <<<"$OUT")" 0

echo "# no call reads a Secret"
: > "$D/calls"
PATH="$D/bin:$PATH" bash -c '. hack/tool-accounts-check.sh; ta_check_account kubectl mcp-tools a; ta_wait_running kubectl mcp-tools tools openagentix-tools 0; ta_refuse_off kubectl <<<"$1"; ta_cleanup kubectl mcp-tools tools openagentix-tools' _ "$OFF" >/dev/null 2>&1
t "no recorded call is a get, describe or list of a Secret (the can-i questions about secrets are not reads)" "$(grep -c '^kubectl \(get\|describe\) secret' "$D/calls")" 0

[ "$F" = 0 ] && echo "tool-accounts-check-test: all passed" || { echo "tool-accounts-check-test: FAILED"; exit 1; }
