#!/usr/bin/env bash
# Tests for hack/kb-graph-schema.sh with a fake `curl` and a fake `kubectl` (no cluster): the dry run, YAML and JSON, the token never in an argument, what each answer
# of the server turns into. The admin token is a canary here, so that every recorded call and every line of output can be searched for it.
set -u
cd "$(dirname "$0")/../.." || exit 1
F=0; t(){ if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (got '$2', want '$3')"; F=1; fi; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir -p "$D/bin"
CANARY=canary-admin-token-0123456789abcdef
S=hack/kb-graph-schema.sh
cat > "$D/schema.yaml" <<'EOF'
version: 3
entityTypes:
  - {name: case, key: "Case DSP-[0-9]{4}-[0-9]{4}", description: A dispute case}
  - {name: merchant}
relationTypes:
  - {name: disputes_charge_at, from: [case], to: [merchant]}
EOF
printf '{"version":3,"entityTypes":[{"name":"case"},{"name":"merchant"}]}' > "$D/schema.json"
# curl: records its arguments, and the header file given with -K; answers /readyz with 200, and the schema route with FAKE_CODE and FAKE_BODY
cat > "$D/bin/curl" <<EOS
#!/usr/bin/env bash
echo "curl \$*" >> "$D/calls"
out=""; hdr=""; want_code=0; prev=""
for a in "\$@"; do
  case "\$prev" in -o) out=\$a;; -K) hdr=\$(cat "\$a" 2>/dev/null);; esac
  [ "\$a" = "%{http_code}" ] && want_code=1
  prev=\$a
done
[ -z "\$hdr" ] || echo "\$hdr" >> "$D/headers"
case "\$*" in
  *"/readyz"*) exit 0;;
esac
[ -z "\$out" ] || printf '%s' "\${FAKE_BODY:-{\"collection\":\"c\",\"version\":3,\"sha256\":\"x\",\"changed\":true,\"entity_types\":2,\"relation_types\":1}}" > "\$out"
if [ "\$want_code" = 1 ]; then printf '%s' "\${FAKE_CODE:-200}"; fi
for a in "\$@"; do case "\$a" in @*) cp "\${a#@}" "$D/sent";; esac; done
exit 0
EOS
printf '#!/usr/bin/env bash\necho "kubectl $*" >> "%s/calls"\nexit 1\n' "$D" > "$D/bin/kubectl"
chmod +x "$D/bin/"*
run() { : > "$D/calls"; : > "$D/headers"; rm -f "$D/sent"; PATH="$D/bin:$PATH" KB_URL=http://kb.test:8080 KB_ADMIN_TOKEN=$CANARY bash "$S" "$@" 2>&1; echo "exit=$?"; }

echo "# arguments"
t "no argument is a usage error (exit 2)" "$(run | tail -1)" exit=2
t "a bad collection name is refused (exit 2) before anything is read" "$(run 'bad name' "$D/schema.yaml" | tail -1)" exit=2
t "a file that is not there is a usage error" "$(run c "$D/nope.yaml" | tail -1)" exit=2
t "a file that is not JSON or YAML by its name is refused" "$(cp "$D/schema.json" "$D/schema.txt"; run c "$D/schema.txt" | tail -1)" exit=2
printf '[1,2]' > "$D/arr.json"
t "a body that is not a schema object is refused (exit 2) and nothing is sent" "$(run c "$D/arr.json" | tail -1)/$(wc -l < "$D/calls" | tr -d ' ')" exit=2/0

echo "# dry run"
OUT=$(KB_GRAPH_SCHEMA_DRY_RUN=1 run c "$D/schema.yaml")
t "the dry run says what it would send" "$(/usr/bin/grep -c 'graph schema c: version 3, 2 entity types, 1 relation types' <<<"$OUT")" 1
t "the dry run sends nothing" "$(/usr/bin/grep -c 'dry run: nothing was sent' <<<"$OUT")/$(wc -l < "$D/calls" | tr -d ' ')" 1/0

echo "# YAML and JSON are sent as JSON"
OUT=$(run c "$D/schema.yaml")
t "YAML: exit 0" "$(/usr/bin/grep -c '^exit=0$' <<<"$OUT")" 1
t "YAML: the body that was sent is JSON with the key pattern intact" "$(jq -r '.entityTypes[0].key' "$D/sent")" 'Case DSP-[0-9]{4}-[0-9]{4}'
t "YAML: a PUT to the schema route of the collection" "$(/usr/bin/grep -c 'curl .*-X PUT .*http://kb.test:8080/v1/collections/c/graph/schema' "$D/calls")" 1
t "YAML: relationTypes is always sent" "$(jq -r '.relationTypes|length' "$D/sent")" 1
OUT=$(run c "$D/schema.json")
t "JSON: exit 0, and a missing relationTypes is sent as an empty list" "$(/usr/bin/grep -c '^exit=0$' <<<"$OUT")/$(jq -c '.relationTypes' "$D/sent")" "1/[]"
t "the answer is reported: stored, version, counts, replaced" "$(/usr/bin/grep -c 'stored the graph schema of c: version 3, 2 entity types, 1 relation types, replaced the previous one' <<<"$OUT")" 1
OUT=$(FAKE_BODY='{"collection":"c","version":3,"sha256":"x","changed":false,"entity_types":2,"relation_types":0}' run c "$D/schema.json")
t "an unchanged schema is reported as no change" "$(/usr/bin/grep -c 'no change (identical' <<<"$OUT")" 1

echo "# the token is never an argument and never printed"
run c "$D/schema.yaml" >/dev/null
t "no recorded call holds the token" "$(/usr/bin/grep -c "$CANARY" "$D/calls")" 0
t "the header reaches curl through a descriptor (the -K file holds it)" "$(/usr/bin/grep -c "Authorization: Bearer $CANARY" "$D/headers")" 1
OUT=$(run c "$D/schema.yaml")
t "no line of output holds the token" "$(/usr/bin/grep -c "$CANARY" <<<"$OUT")" 0

echo "# what the server answers"
OUT=$(FAKE_CODE=409 FAKE_BODY='{"error":"facts that are already in the collection do not fit the new graph schema: 2 violation(s)","violations":[{"at":"factsets/org/entities[2]","rule":"type"},{"at":"factsets/org/relations[1]","rule":"predicate"}],"more":3}' run c "$D/schema.yaml")
t "409: exit 1 and says the schema was NOT stored" "$(/usr/bin/grep -c '^exit=1$' <<<"$OUT")/$(/usr/bin/grep -c 'the schema was NOT stored' <<<"$OUT")" 1/1
t "409: the places and rules are listed, and the count of the rest" "$(/usr/bin/grep -c 'factsets/org/entities\[2\]: type' <<<"$OUT")/$(/usr/bin/grep -c 'factsets/org/relations\[1\]: predicate' <<<"$OUT")/$(/usr/bin/grep -c 'and 3 more' <<<"$OUT")" 1/1/1
OUT=$(FAKE_CODE=400 FAKE_BODY='{"error":"entityTypes[1].key is not a valid RE2 pattern"}' run c "$D/schema.yaml")
t "400: the server's sentence is shown" "$(/usr/bin/grep -c 'entityTypes\[1\].key is not a valid RE2 pattern' <<<"$OUT")" 1
t "401: the token was refused" "$(FAKE_CODE=401 FAKE_BODY='{}' run c "$D/schema.yaml" | /usr/bin/grep -c 'the admin token was refused')" 1
t "404: says the route may be off" "$(FAKE_CODE=404 FAKE_BODY='{}' run c "$D/schema.yaml" | /usr/bin/grep -c 'knowledge.kb.graph.schemas.enabled')" 1
t "413: exit 1" "$(FAKE_CODE=413 FAKE_BODY='{"error":"the schema is larger than 64 KiB"}' run c "$D/schema.yaml" | /usr/bin/grep -c '^exit=1$')" 1

echo "# delete"
OUT=$(FAKE_CODE=204 FAKE_BODY='' KB_GRAPH_SCHEMA_DELETE=1 run c)
t "delete needs no file, sends DELETE, and says the facts stay" "$(/usr/bin/grep -c '^exit=0$' <<<"$OUT")/$(/usr/bin/grep -c 'curl .*-X DELETE .*graph/schema' "$D/calls")/$(/usr/bin/grep -c 'its facts stay' <<<"$OUT")" 1/1/1
t "delete of a collection with no schema: exit 1 and says so" "$(FAKE_CODE=404 FAKE_BODY='{}' KB_GRAPH_SCHEMA_DELETE=1 run c | /usr/bin/grep -c 'has no graph schema')" 1
exit "$F"
