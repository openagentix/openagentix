#!/usr/bin/env bash
# Tests for the reader check of hack/compose-values.sh (ADR 0030, review L4): a later values file that adds a profile with knowledgeCollections naming a collection that an
# earlier file already lets another profile or the shared group read gives a new reader access to it. That is security relevant: it is refused unless the collection is new
# in the file that adds the profile (--later-wins takes it and reports it). No cluster. Needs: bash, jq, yq (the Python wrapper).
set -u
cd "$(dirname "$0")/../.." || exit 1
SCRIPT="$(pwd)/hack/compose-values.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-condition false: $2}"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
run() { bash "$SCRIPT" "$@" > "$T/out" 2> "$T/err"; RC=$?; }
w() { cat > "$T/$1"; }

w bank.yaml <<'EOF'
mcp:
  profiles:
    - {name: disputes, tools: {knowledge: [kb_search]}, knowledgeCollections: [coll-bank]}
EOF
w equip.yaml <<'EOF'
mcp:
  profiles:
    - {name: dealer, tools: {knowledge: [kb_search]}, knowledgeCollections: [coll-equip]}
EOF
w thief.yaml <<'EOF'
mcp:
  profiles:
    - {name: sneaky, tools: {knowledge: [kb_search]}, knowledgeCollections: [coll-bank, coll-new]}
EOF
w shared.yaml <<'EOF'
knowledge: {access: {mode: report, sharedGroupCollections: [coll-shared]}}
EOF
w sharedthief.yaml <<'EOF'
mcp:
  profiles:
    - {name: sneaky2, tools: {knowledge: [kb_search]}, knowledgeCollections: [coll-shared]}
EOF

echo "# two use case files that own their own collection compose"
run "$T/bank.yaml" "$T/equip.yaml"
check "bank then equipment: composed (exit 0), each profile keeps its own list" "[ $RC = 0 ] && yq -c '.mcp.profiles|map(.knowledgeCollections)' '$T/out' | grep -q '\[\[\"coll-bank\"\],\[\"coll-equip\"\]\]'"

echo "# a later file that names a collection another profile already reads is refused"
run "$T/bank.yaml" "$T/thief.yaml"
check "refused (exit 1), nothing on stdout" "[ $RC = 1 ] && [ ! -s '$T/out' ]"
check "the sentence names the file, the profile, the collection and the reader" "grep -q 'thief.yaml' '$T/err' && grep -q 'sneaky' '$T/err' && grep -q 'coll-bank' '$T/err' && grep -q 'disputes' '$T/err'"
check "it is called out as security relevant, and says --later-wins" "grep -q 'SECURITY-RELEVANT' '$T/err' && grep -q -- '--later-wins' '$T/err'"
check "the collection that is new in that file is not named as the problem" "! grep 'refused' '$T/err' | grep -q 'coll-new'"
run --later-wins "$T/bank.yaml" "$T/thief.yaml"
check "--later-wins takes it, and still says so" "[ $RC = 0 ] && grep -q 'SECURITY-RELEVANT' '$T/err'"

echo "# the shared group's list counts as a reader too"
run "$T/shared.yaml" "$T/sharedthief.yaml"
check "a profile that names a collection of sharedGroupCollections is refused" "[ $RC = 1 ] && grep -q 'sneaky2' '$T/err' && grep -q 'coll-shared' '$T/err' && grep -q 'shared group' '$T/err'"

echo "# one file may list its own collection in several profiles"
w own.yaml <<'EOF'
mcp:
  profiles:
    - {name: a, tools: {knowledge: [kb_search]}, knowledgeCollections: [coll-own]}
    - {name: b, tools: {knowledge: [kb_search]}, knowledgeCollections: [coll-own]}
EOF
run "$T/bank.yaml" "$T/own.yaml"
check "the collection is new in that file: composed" "[ $RC = 0 ]"
echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
