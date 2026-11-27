#!/usr/bin/env bash
# kagent's database secrets and roles. Sourced by up.sh. Tests: tests/run.sh.
#   kagent_pg_admin_secret  the admin password of kagent's own PostgreSQL, once
#   kagent_db_secrets       the roles and the two connection-string secrets, once. Run it from components/runtime.
# Values never go in a process argument: secrets are made with --from-file from a process substitution
# (printf is a shell builtin) and the psql variables for the two passwords are \set lines on standard input.

kagent_pg_admin_secret(){
  local K=${KUBECTL:-kubectl}
  if ! $K -n kagent get secret kagent-pg-admin >/dev/null 2>&1; then
    $K -n kagent create secret generic kagent-pg-admin --from-file=password=<(printf '%s' "$(openssl rand -hex 12)")
  fi
}

kagent_db_secrets(){
  local K=${KUBECTL:-kubectl} OW RW
  if ! $K -n kagent get secret kagent-postgres-owner >/dev/null 2>&1; then
    OW=$(openssl rand -hex 12); RW=$(openssl rand -hex 12)
    { printf '\\set kagent_owner_password %s\n' "'$OW'"; printf '\\set kagent_readwrite_password %s\n' "'$RW'"; cat dl/kagent-setup.sql; } \
      | $K -n kagent exec -i kagent-pg-0 -- psql --no-psqlrc -U postgres -d kagent --set=ON_ERROR_STOP=1 --single-transaction \
        --set=kagent_schema=kagent --set=kagent_owner_role=kagent_owner --set=kagent_owner_user=kagent_owner_user \
        --set=kagent_readwrite_role=kagent_readwrite --set=kagent_readwrite_user=kagent_readwrite_user
    $K -n kagent create secret generic kagent-postgres-owner \
      --from-file=ownerConnectionString=<(printf '%s' "postgresql://kagent_owner_user:$OW@kagent-pg.kagent.svc:5432/kagent?sslmode=disable")
    $K -n kagent create secret generic kagent-postgres-readwrite \
      --from-file=readWriteConnectionString=<(printf '%s' "postgresql://kagent_readwrite_user:$RW@kagent-pg.kagent.svc:5432/kagent?sslmode=disable")
  fi
}
