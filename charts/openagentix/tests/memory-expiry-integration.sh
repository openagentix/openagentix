#!/usr/bin/env bash
# Proves the memory expiry job's SQL (charts/openagentix/files/memory-expiry.sh) against a throw-away PostgreSQL that THIS
# script starts and always stops again (docker run --rm, the way services/kb does `make test-integration`). It is the only
# database it connects to. Unlike the kb test it publishes no port: every statement runs inside the container
# (docker exec), so nothing listens on the host.
#
# The database is built like kagent's: the image kagent-pg uses (pgvector/pgvector:pg17), the roles and schema from
# components/runtime/dl/kagent-setup.sql, the extension in schema "extensions", and the memory table from kagent's own vector
# migration (go/core/pkg/migrations/vector/000001_initial.sql, v1.0.1), created by the owner role. The job runs as the
# read/write role, exactly as in the cluster.
#
# Usage: charts/openagentix/tests/memory-expiry-integration.sh        (exit 1 on any failure)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
JOB="$HERE/../files/memory-expiry.sh"
SETUP="$REPO/components/runtime/dl/kagent-setup.sql"
IMAGE="${PG_IMAGE:-pgvector/pgvector:pg17}"
NAME="${PG_NAME:-memexp-test-pg}"
DOCKER="${DOCKER:-docker}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$1" "$3" "$2"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }

cleanup() { "$DOCKER" stop "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
"$DOCKER" run -d --rm --name "$NAME" -e POSTGRES_PASSWORD=memexptest -e POSTGRES_DB=kagent "$IMAGE" >/dev/null || { echo "cannot start $IMAGE" >&2; exit 1; }
i=0; until "$DOCKER" exec "$NAME" psql -U postgres -d kagent -tAc 'select 1' >/dev/null 2>&1; do
  i=$((i+1)); [ $i -lt 120 ] || { echo "$NAME did not become ready" >&2; exit 1; }; sleep 1; done
# the image restarts once during its first init: wait until it answers twice in a row
sleep 2; until "$DOCKER" exec "$NAME" psql -U postgres -d kagent -tAc 'select 1' >/dev/null 2>&1; do sleep 1; done

admin() { "$DOCKER" exec -i "$NAME" psql --no-psqlrc -q -U postgres -d kagent -v ON_ERROR_STOP=1 "$@"; }
OW=ow$(date +%s)a; RW=rw$(date +%s)b
admin --single-transaction --set=kagent_schema=kagent --set=kagent_owner_role=kagent_owner --set=kagent_owner_user=kagent_owner_user \
  --set=kagent_owner_password="$OW" --set=kagent_readwrite_role=kagent_readwrite --set=kagent_readwrite_user=kagent_readwrite_user \
  --set=kagent_readwrite_password="$RW" < "$SETUP" >/dev/null || { echo "kagent-setup.sql failed" >&2; exit 1; }
admin >/dev/null <<'SQL' || exit 1
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA extensions;
GRANT USAGE ON SCHEMA extensions TO kagent_owner, kagent_readwrite;
SQL
OWNER_URL="postgresql://kagent_owner_user:$OW@127.0.0.1:5432/kagent?sslmode=disable"
RW_URL="postgresql://kagent_readwrite_user:$RW@127.0.0.1:5432/kagent?sslmode=disable"
as_owner() { "$DOCKER" exec -i "$NAME" psql --no-psqlrc -q -X -v ON_ERROR_STOP=1 -tA "$OWNER_URL" "$@"; }
# kagent's logins are NOINHERIT: it runs set_config('role', ...) after each connect, and so does the job
as_rw()    { "$DOCKER" exec -i "$NAME" psql --no-psqlrc -q -X -v ON_ERROR_STOP=1 -tA "$RW_URL" -c "SET ROLE kagent_readwrite" "$@"; }
as_owner >/dev/null <<'SQL' || exit 1
SET ROLE kagent_owner;
SET search_path TO kagent;
CREATE TABLE memory (
    id           TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_name   TEXT,
    user_id      TEXT,
    content      TEXT,
    metadata     TEXT,
    created_at   TIMESTAMPTZ,
    expires_at   TIMESTAMPTZ,
    access_count BIGINT DEFAULT 0
);
CREATE INDEX idx_memory_agent_user ON memory(agent_name, user_id);
CREATE INDEX idx_memory_expires_at ON memory(expires_at);
ALTER TABLE memory ADD COLUMN embedding extensions.vector(768);
CREATE INDEX idx_memory_embedding_hnsw ON memory USING hnsw (embedding extensions.vector_cosine_ops);
SQL

# the job exactly as the chart mounts it, run inside the container as the read/write role
run_job() { "$DOCKER" exec -i -e KAGENT_DB_URL="$RW_URL" -e SECRET_SCAN="${1:-0}" -e SECRET_SCAN_DELETE="${2:-0}" "$NAME" sh -s < "$JOB"; }
count() { as_rw -c "SELECT count(*) FROM kagent.memory ${1:-}"; }
VEC="array_fill(0.1::float4, ARRAY[768])::extensions.vector"
# row(user, content, expires, access_count): content here is test data only
ins() { as_rw -c "INSERT INTO kagent.memory (agent_name, user_id, content, metadata, created_at, expires_at, access_count, embedding) VALUES ('kagent/assistant', '$1', \$c\$$2\$c\$, '{}', NOW(), $3, $4, $VEC)" >/dev/null; }
reset() { as_owner -c "SET ROLE kagent_owner" -c "TRUNCATE kagent.memory" >/dev/null; }   # the read/write role has no TRUNCATE

echo "# expiry"
reset
ins probe:a "expired and unread"          "NOW() - INTERVAL '2 days'"  0
ins probe:a "expired, read 9 times"       "NOW() - INTERVAL '1 hour'"  9
ins probe:b "expired, read 10 times"      "NOW() - INTERVAL '1 hour'"  10
ins probe:b "expired, read 50 times"      "NOW() - INTERVAL '1 day'"   50
ins probe:a "still valid"                 "NOW() + INTERVAL '3 days'"  0
ins probe:a "valid and popular"           "NOW() + INTERVAL '3 days'"  99
ins probe:c "never expires (NULL)"        "NULL"                       0
eq "7 rows before" "$(count)" 7
# what kagent's search does BEFORE the job: it ignores expires_at and returns expired rows (memory.go lines 53-66). This is
# the statement text of SearchAgentMemory (cosine operator <=>, as kagent uses with pgvector in "extensions").
SEARCH="SELECT count(*) FROM (SELECT id FROM kagent.memory WHERE agent_name = 'kagent/assistant' AND user_id = 'probe:a' ORDER BY embedding OPERATOR(extensions.<=>) $VEC LIMIT 5) s"
eq "search before the job still returns the expired rows of probe:a (4 rows: expired x2, valid x2)" "$(as_rw -c "$SEARCH")" 4
OUT=$(run_job 0 0 2>&1); RC=$?
eq "job exit code" "$RC" 0
eq "log line has counts only" "$OUT" "memory-expiry: total_before=7 expired=4 extended=2 deleted=2 total_after=5
memory-expiry: secret_scan=off"
eq "the two unread expired rows are gone" "$(count "WHERE content IN ('expired and unread','expired, read 9 times')")" 0
eq "the two popular expired rows were extended" "$(count "WHERE content LIKE 'expired, read %0 times' AND expires_at > NOW() + INTERVAL '14 days' AND access_count = 0")" 2
eq "valid and NULL rows untouched" "$(count "WHERE content IN ('still valid','valid and popular','never expires (NULL)') AND access_count IN (0,99)")" 3
eq "search after the job: probe:a has its 2 valid rows only" "$(as_rw -c "$SEARCH")" 2
OUT=$(run_job 0 0 2>&1)
eq "second run changes nothing" "$OUT" "memory-expiry: total_before=5 expired=0 extended=0 deleted=0 total_after=5
memory-expiry: secret_scan=off"
if printf '%s' "$OUT" | grep -q -e 'probe:' -e 'unread' -e 'kagent/assistant'; then bad "log never names a user, an agent or a text" "$OUT" "none of those"; else ok "log never names a user, an agent or a text"; fi

echo "# secret scan (report only, then delete)"
reset
ins probe:s "an ordinary fact about tea"                                  "NOW() + INTERVAL '1 day'" 0
ins probe:s "key AKIAIOSFODNN7EXAMPLE in a note"                          "NOW() + INTERVAL '1 day'" 0
ins probe:s "-----BEGIN RSA PRIVATE KEY----- MIIE"                        "NOW() + INTERVAL '1 day'" 0
ins probe:s "token ghp_0123456789abcdefghijklmnopqrstuvwxyzAB"            "NOW() + INTERVAL '1 day'" 0
ins probe:s "Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345"      "NOW() + INTERVAL '1 day'" 0
ins probe:s "sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789"           "NOW() + INTERVAL '1 day'" 0
ins probe:s "xoxb-1234567890-abcdefghij"                                  "NOW() + INTERVAL '1 day'" 0
ins probe:s "AIzaSyA-1234567890abcdefghijklmnopqrstuv"                    "NOW() + INTERVAL '1 day'" 0
ins probe:s "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk" "NOW() + INTERVAL '1 day'" 0
ins probe:s "bot 123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw1 here"       "NOW() + INTERVAL '1 day'" 0
ins probe:s "sk_test_abcdefghijklmnop0123"                                "NOW() + INTERVAL '1 day'" 0
ins probe:s "the sk-learn library and a bearer of bad news"               "NOW() + INTERVAL '1 day'" 0
ins probe:s "AKIA is a prefix; so is ghp_ and xoxb-"                      "NOW() + INTERVAL '1 day'" 0
eq "13 rows before the scan" "$(count)" 13
OUT=$(run_job 1 0 2>&1); RC=$?
eq "report-only exit code" "$RC" 0
eq "report-only: nothing deleted" "$(count)" 13
LINE=$(printf '%s\n' "$OUT" | sed -n 2p)
eq "report-only: counts per pattern" "$LINE" "memory-expiry: secret_scan=on delete=off rows_matching=10 rows_deleted=0 patterns=aws_access_key_id=1 bearer_token=1 github_token=1 google_api_key=1 jwt=1 private_key_header=1 provider_secret_key=1 slack_token=1 stripe_secret_key=1 telegram_bot_token=1"
for secret in AKIAIOSFODNN7EXAMPLE ghp_0123 abcdefghijklmnopqrstuvwxyz012345 BEGIN MIIE AAHdqTcv; do
  if printf '%s' "$OUT" | grep -q -- "$secret"; then bad "log never carries the text ($secret)" "$OUT" "no match"; else ok "log never carries the text ($secret)"; fi
done
OUT=$(run_job 1 1 2>&1); RC=$?
eq "delete mode exit code" "$RC" 0
eq "delete mode: the 10 matching rows are gone" "$(count)" 3
eq "delete mode: the 3 harmless rows stay" "$(count "WHERE content IN ('an ordinary fact about tea','the sk-learn library and a bearer of bad news','AKIA is a prefix; so is ghp_ and xoxb-')")" 3
eq "delete mode: counted and deleted" "$(printf '%s\n' "$OUT" | sed -n 2p | cut -d' ' -f1-4)" "memory-expiry: secret_scan=on delete=on rows_matching=10"
case "$(printf '%s\n' "$OUT" | sed -n 2p)" in *rows_deleted=10*) ok "delete mode: rows_deleted=10";; *) bad "delete mode: rows_deleted=10" "$OUT" "rows_deleted=10";; esac
OUT=$(run_job 0 1 2>&1); RC=$?
eq "delete without scan is refused" "$RC" 2

echo "# failure modes"
# the password must not be in a process argument (argv is readable by other users on the node; the environment is not)
if grep -qE 'psql[^|]*"\$KAGENT_DB_URL"' "$JOB"; then bad "the connection string with the password is not passed as an argument" "psql \"\$KAGENT_DB_URL\"" "PGPASSWORD"; else ok "the connection string with the password is not passed as an argument"; fi
ins u-enc 'encoded password case' "NOW() + INTERVAL '1 day'" 0
OUT=$("$DOCKER" exec -i -e KAGENT_DB_URL="postgresql://kagent_readwrite_user:p%40ss%3Aw%2Ford@127.0.0.1:5432/kagent?sslmode=disable" "$NAME" sh -s < "$JOB" 2>&1); RC=$?
eq "a percent-encoded password still connects" "$RC" 0
reset
# (the image trusts 127.0.0.1, so a wrong password cannot be tested here: a closed port stands in for any connection failure)
OUT=$("$DOCKER" exec -i -e WAIT_SECONDS=2 -e WAIT_INTERVAL=1 -e KAGENT_DB_URL="postgresql://kagent_readwrite_user:wrong@127.0.0.1:1/kagent?sslmode=disable" "$NAME" sh -s < "$JOB" 2>&1); RC=$?
[ "$RC" = 1 ] && ok "a connection failure fails the job (exit 1, after the wait)" || bad "a connection failure fails the job (exit 1, after the wait)" "$RC" 1
if printf '%s' "$OUT" | grep -q wrong; then bad "the connection error does not echo the password" "$OUT" "no password"; else ok "the connection error does not echo the password"; fi
OUT=$("$DOCKER" exec -i "$NAME" sh -s < "$JOB" 2>&1); RC=$?
[ "$RC" != 0 ] && ok "no connection string fails the job" || bad "no connection string fails the job" "exit 0" "non-zero"

echo
echo "memory-expiry integration: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
