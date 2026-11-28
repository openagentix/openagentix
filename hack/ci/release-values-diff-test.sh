#!/usr/bin/env bash
# Tests for hack/release-values-diff.sh (issue #212) with a fake `helm` (no cluster): the installer must not drop values of the release without a word.
# Cases: first install; an unchanged list; a shorter list (paths and named list entries); keys the installer sets itself; helm errors (fail closed);
# --set-file keys; the --enforce mode (stop, ALLOW_VALUE_REMOVAL=1); and that install.sh calls the check before `helm upgrade`, and that every `--set` key
# of install.sh is in hack/release-values-ignore.txt.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       got:  $2"; echo "       want: $3"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
# helm: `get values` answers from $D/release.json (FAKE_HELM=notfound: helm's own line; FAKE_HELM=unreachable: another error); every call is recorded
cat > "$D/bin/helm" <<EOS
#!/usr/bin/env bash
echo "helm \$*" >> "$D/calls"
case "\${FAKE_HELM:-ok}" in
  notfound) echo "Error: release: not found" >&2; exit 1;;
  notfound-extra) echo "Error: release: not found: openagentix" >&2; exit 1;;
  unreachable) echo "Error: Kubernetes cluster unreachable: dial tcp 127.0.0.1:1: connect: connection refused" >&2; exit 1;;
esac
cat "$D/release.json"
EOS
chmod +x "$D/bin/helm"
export HELM="$D/bin/helm"
R=hack/release-values-diff.sh
rel(){ printf '%s\n' "$1" > "$D/release.json"; }            # rel '<json of the release values>'
vf(){ printf '%s\n' "$2" > "$D/$1"; }                       # vf name.yaml '<yaml>'
run(){ : > "$D/calls"; OUT=$(bash "$R" "$@" 2>"$D/err"); RC=$?; ERR=$(cat "$D/err"); }
FULL='{"gateway":{"stubModel":{"enabled":true,"image":{"tag":"dev-abc"}}},"mcp":{"endpoints":[{"name":"records","url":"http://r"},{"name":"dealer-records","url":"http://d"}]},"agents":[{"name":"a"},{"name":"b"}],"notify":{"enabled":true,"requireReady":false},"controlPlane":{"apiServerCIDRs":["10.0.0.1/32"],"sourceHash":"x"}}'
vf full.yaml 'gateway: {stubModel: {enabled: true}}
mcp: {endpoints: [{name: records, url: "http://r"}, {name: dealer-records, url: "http://d"}]}
agents: [{name: a}, {name: b}]
notify: {enabled: true}
controlPlane: {}'
vf short.yaml 'gateway: {stubModel: {enabled: true}}
mcp: {endpoints: [{name: records, url: "http://r"}]}
agents: [{name: a}]
notify: {enabled: true}
controlPlane: {}'
vf empty.yaml '{}'

echo "# first install: no release"
FAKE_HELM=notfound run -f "$D/full.yaml"
t "exit 0" "$RC" 0; t "silent" "$OUT$ERR" ""
echo "# the release has no user values at all (helm prints null)"
rel 'null'; run -f "$D/short.yaml"
t "exit 0" "$RC" 0; t "silent" "$OUT$ERR" ""

echo "# the same list again"
rel "$FULL"; run -f "$D/full.yaml"
t "exit 0 (image tag, source hash, API server addresses and requireReady are the installer's)" "$RC" 0
t "silent" "$OUT$ERR" ""
echo "# the helm call is read only and names the release, namespace and context"
run --release openagentix --namespace ns1 --kube-context kind-x -f "$D/full.yaml"
t "one call: get values" "$(cat "$D/calls")" "helm get values openagentix -n ns1 --kube-context kind-x -o json"

echo "# a shorter list: an endpoint and an agent would be dropped"
run -f "$D/short.yaml"
t "exit 1" "$RC" 1
t "lists the named endpoint" "$(grep -c '^\.mcp\.endpoints\[dealer-records\]\.url$' <<<"$OUT")" 1
t "lists the named agent" "$(grep -c '^\.agents\[b\]\.name$' <<<"$OUT")" 1
t "lists nothing the run still has" "$(grep -c 'endpoints\[records\]\|agents\[a\]' <<<"$OUT")" 0
t "does not list installer keys" "$(grep -cE 'image|sourceHash|apiServerCIDRs|requireReady' <<<"$OUT")" 0
t "prints nothing on stderr" "$ERR" ""

echo "# a whole feature missing"
run -f "$D/empty.yaml"
t "exit 1" "$RC" 1
t "lists the feature" "$(grep -c '^\.notify\.enabled$' <<<"$OUT")" 1
t "lists the stub model" "$(grep -c '^\.gateway\.stubModel\.enabled$' <<<"$OUT")" 1

echo "# a later file replaces a list (Helm semantics): the entry it leaves out is a loss"
vf more.yaml 'mcp: {endpoints: [{name: records, url: "http://r"}]}'
run -f "$D/full.yaml" -f "$D/more.yaml"
t "exit 1" "$RC" 1
t "dealer-records is lost" "$(grep -c "dealer-records" <<<"$OUT")" 2
echo "# a later file that only adds"
vf add.yaml 'extra: {x: 1}'
run -f "$D/full.yaml" -f "$D/add.yaml"
t "exit 0" "$RC" 0

echo "# lists of plain values count as one path"
rel '{"policy":{"images":["a","b","c"]},"empty":[],"obj":{}}'
vf plain.yaml 'policy: {images: ["z"]}
empty: []
obj: {}'
run -f "$D/plain.yaml"
t "a changed plain list is not a loss" "$RC" 0
vf plain2.yaml 'x: 1'
run -f "$D/plain2.yaml"
t "a missing plain list, empty list and empty map are named" "$(tr '\n' ' ' <<<"$OUT")" ".empty[] .obj{} .policy.images[] "

echo "# --set-file keys (dots in the name are escaped like Helm)"
rel '{"gateway":{"stubModel":{"scenarios":{"files":{"a.json":"x","b.json":"y"}}}}}'
echo '{}' > "$D/a.json"
run --set-file 'gateway.stubModel.scenarios.files.a\.json='"$D/a.json"
t "b.json is lost, a.json is not" "$OUT" ".gateway.stubModel.scenarios.files.b.json"
run --set-file 'gateway.stubModel.scenarios.files.a\.json='"$D/a.json" --set-file 'gateway.stubModel.scenarios.files.b\.json='"$D/a.json"
t "both passed: exit 0" "$RC" 0

echo "# helm errors fail closed"
FAKE_HELM=unreachable run -f "$D/full.yaml"
t "unreachable: exit 2" "$RC" 2; t "the reason is on stderr" "$(grep -c 'cannot read the values of the release' <<<"$ERR")" 1; t "nothing on stdout" "$OUT" ""
FAKE_HELM=notfound-extra run -f "$D/full.yaml"
t "a line that only starts like 'release: not found' is not 'no release'" "$RC" 2
HELM=/nonexistent/helm run -f "$D/full.yaml"
t "a missing helm is not 'no release'" "$RC" 2
rel 'not json'; run -f "$D/full.yaml"
t "output that is not JSON: exit 2" "$RC" 2
rel "$FULL"; run -f "$D/missing.yaml"
t "a values file that cannot be read: exit 2" "$RC" 2
run --bogus
t "an unknown argument: exit 2" "$RC" 2

echo "# --enforce: the installer's policy"
rel "$FULL"
run --enforce -f "$D/short.yaml"
t "stops with exit 1" "$RC" 1
t "names the lost path on stderr" "$(grep -c "dealer-records" <<<"$ERR")" 2
t "names the switch" "$(grep -c 'ALLOW_VALUE_REMOVAL=1' <<<"$ERR")" 1
t "says nothing was changed" "$(grep -c 'Nothing was changed' <<<"$ERR")" 1
ALLOW_VALUE_REMOVAL=1 run --enforce -f "$D/short.yaml"
t "ALLOW_VALUE_REMOVAL=1: exit 0" "$RC" 0
t "ALLOW_VALUE_REMOVAL=1: still prints the list" "$(grep -c "dealer-records" <<<"$ERR")" 2
t "ALLOW_VALUE_REMOVAL=1: says it will remove them" "$(grep -c 'ALLOW_VALUE_REMOVAL=1 is set' <<<"$ERR")" 1
ALLOW_VALUE_REMOVAL=0 run --enforce -f "$D/short.yaml"
t "ALLOW_VALUE_REMOVAL=0 does not allow it" "$RC" 1
ALLOW_VALUE_REMOVAL=yes run --enforce -f "$D/short.yaml"
t "only the value 1 allows it" "$RC" 1
run --enforce -f "$D/full.yaml"
t "unchanged: exit 0, silent" "$RC$OUT$ERR" 0
FAKE_HELM=notfound run --enforce -f "$D/full.yaml"
t "first install: exit 0, silent" "$RC$OUT$ERR" 0
FAKE_HELM=unreachable ALLOW_VALUE_REMOVAL=1 run --enforce -f "$D/full.yaml"
t "a release it cannot read stops it, even with ALLOW_VALUE_REMOVAL=1" "$RC" 2
t "and says so" "$(grep -c 'refusing to run' <<<"$ERR")" 1
many=$(jq -n '{k: ([range(0;80)] | map({key: ("k\(.)"), value: 1}) | from_entries)}'); rel "$many"
run --enforce -f "$D/empty.yaml"
t "a long list is cut after 30 entries" "$(grep -c '^  \.k\.' <<<"$ERR")/$(grep -c 'and 50 more' <<<"$ERR")" 30/1

echo "# install.sh wiring"
H=$(grep -n '^helm upgrade --install' install.sh | head -1 | cut -d: -f1)
C=$(grep -n 'release-values-diff.sh --enforce' install.sh | head -1 | cut -d: -f1)
t "install.sh runs the check" "$([ -n "$C" ] && echo yes || echo no)" yes
t "the check comes before helm upgrade" "$([ -n "$C" ] && [ -n "$H" ] && [ "$C" -lt "$H" ] && echo yes || echo no)" yes
t "the check is passed the same -f and --set-file list as helm (VALS)" "$(grep 'release-values-diff.sh --enforce' install.sh | grep -c 'VALS')" 1
t "the check is only run when a cluster exists" "$(sed -n "$((C-1)),${C}p" install.sh | grep -c 'CLUSTER_UP')" 1

echo "# every --set key of install.sh is in hack/release-values-ignore.txt (the --set-file keys are values of the run, not in the list)"
IGN=$(grep -vE '^[[:space:]]*(#|$)' hack/release-values-ignore.txt | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')
KEYS=$(grep -oE -- '--set(-string|-json)?[ =]+["'"'"']?[A-Za-z$][A-Za-z0-9_.${}-]*=' install.sh | sed -E 's/^--set(-string|-json)?[ =]+["'"'"']?//; s/=$//')
n=0; miss=""
while IFS= read -r k; do
  [ -n "$k" ] || continue; n=$((n+1))
  case "$k" in '$path.image.'*) continue;; esac   # expanded below from the tag_image calls
  grep -qxF "$k" <<<"$IGN" || miss="$miss $k"
done <<<"$KEYS"
t "found --set keys in install.sh (the extraction works)" "$([ "$n" -ge 10 ] && echo yes || echo "no ($n)")" yes
t "no --set key is missing from the list:$miss" "${miss:+missing}" ""
# the image keys: tag_image <var> <path> ...; each path gets .image.tag, .image.repository and .image.digest
PATHS=$(grep -oE '^[[:space:]]*tag_image [A-Z0-9_]+ [A-Za-z0-9.]+' install.sh | awk '{print $3}' | sort -u)
t "found the image paths in install.sh" "$([ "$(wc -l <<<"$PATHS")" -ge 9 ] && echo yes || echo no)" yes
miss=""
for p in $PATHS; do for s in image.tag image.repository image.digest; do grep -qxF "$p.$s" <<<"$IGN" || miss="$miss $p.$s"; done; done
t "no image key is missing from the list:$miss" "${miss:+missing}" ""
# queue_build's fourth argument is the same path: every one must be a tag_image path too
QB=$(grep -oE '^[[:space:]]*queue_build "[^"]*" [^ ]+ "[^"]*" [A-Za-z0-9.]+' install.sh | awk '{print $NF}' | sort -u)
miss=""; for p in $QB; do grep -qxF "$p" <<<"$PATHS" || miss="$miss $p"; done
t "every queue_build path is a tag_image path:$miss" "${miss:+missing}" ""
SF=$(grep -oE -- '--set-file "[A-Za-z.$]+' install.sh | sort -u | tr '\n' ' ')
t "the only --set-file of install.sh is the stub scenarios" "$SF" '--set-file "gateway.stubModel.scenarios.files.$ '
t "the ignore list has no pattern characters (exact keys)" "$(grep -c '[*?^$|()]' <<<"$IGN")" 0
# the check itself works: a key that is not in the list is reported
t "(self-test) an unknown key would be reported" "$(grep -qxF 'nope.sourceHash' <<<"$IGN" && echo listed || echo missing)" missing

[ "$F" = 0 ] && echo "release-values-diff tests: ok" || { echo "release-values-diff tests: FAILED"; exit 1; }
