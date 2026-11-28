#!/usr/bin/env bash
# Tests for what hack/kb-graph-load.sh prints when the kb refuses a fact set because it does not fit the graph schema of the collection (ADR 0030, 422), with a fake
# `curl` (no cluster). The admin token is a canary, so that every recorded call and every line of output can be searched for it.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
CANARY=canary-admin-token-0123456789abcdef
printf '{"entities":[{"name":"Basalt","type":"team"}],"relations":[]}' > "$D/set.json"
cat > "$D/bin/curl" <<EOS
#!/usr/bin/env bash
echo "curl \$*" >> "$D/calls"
out=""; want_code=0; prev=""
for a in "\$@"; do
  case "\$prev" in -o) out=\$a;; esac
  [ "\$a" = "%{http_code}" ] && want_code=1
  prev=\$a
done
case "\$*" in *"/readyz"*) exit 0;; esac
[ -z "\$out" ] || printf '%s' "\${FAKE_BODY:-{}}" > "\$out"
if [ "\$want_code" = 1 ]; then printf '%s' "\${FAKE_CODE:-200}"; fi
exit 0
EOS
chmod +x "$D/bin/curl"
run() { : > "$D/calls"; PATH="$D/bin:$PATH" KB_URL=http://kb.test:8080 KB_ADMIN_TOKEN=$CANARY bash hack/kb-graph-load.sh kg org "$D/set.json" 2>&1; echo "exit=$?"; }

OUT=$(FAKE_CODE=422 FAKE_BODY='{"error":"the fact set does not fit the graph schema of the collection: 3 violation(s)","violations":[{"at":"entities[1]","rule":"key"},{"at":"relations[0]","rule":"predicate"}],"more":1}' run)
t "422: exit 1" "$(/usr/bin/grep -c '^exit=1$' <<<"$OUT")" 1
t "422: says the fact set does not fit the schema and was not stored" "$(/usr/bin/grep -c 'http 422: the fact set was NOT stored' <<<"$OUT")" 1
t "422: lists the places and rules" "$(/usr/bin/grep -c 'entities\[1\]: key' <<<"$OUT")/$(/usr/bin/grep -c 'relations\[0\]: predicate' <<<"$OUT")" 1/1
t "422: counts the rest" "$(/usr/bin/grep -c 'and 1 more' <<<"$OUT")" 1
t "the token is in no line of output and no argument" "$(/usr/bin/grep -c "$CANARY" <<<"$OUT")/$(/usr/bin/grep -c "$CANARY" "$D/calls")" 0/0
OUT=$(FAKE_CODE=200 FAKE_BODY='{"collection":"kg","id":"org","entities":1,"relations":0,"changed":true}' run)
t "200 still works" "$(/usr/bin/grep -c 'loaded kg/org: 1 entities, 0 relations' <<<"$OUT")" 1
exit "$F"
