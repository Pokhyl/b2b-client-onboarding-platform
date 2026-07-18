#!/usr/bin/env bash
set -Eeuo pipefail

required_variables=(
  APP_DB_NAME
  APP_DB_USER
  APP_DB_PASSWORD
  N8N_DB_NAME
  N8N_DB_USER
  N8N_DB_PASSWORD
)

for variable in "${required_variables[@]}"; do
  if [[ -z "${!variable:-}" ]]; then
    printf 'Required environment variable is missing: %s\n' "$variable" >&2
    exit 1
  fi
done

psql \
  --set=ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=app_db_name="$APP_DB_NAME" \
  --set=app_db_user="$APP_DB_USER" \
  --set=app_db_password="$APP_DB_PASSWORD" \
  --set=n8n_db_name="$N8N_DB_NAME" \
  --set=n8n_db_user="$N8N_DB_USER" \
  --set=n8n_db_password="$N8N_DB_PASSWORD" <<'EOSQL'
SELECT format(
    'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
    :'app_db_user',
    :'app_db_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'app_db_user'
);
\gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'app_db_name',
    :'app_db_user'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = :'app_db_name'
);
\gexec

SELECT format(
    'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD %L',
    :'n8n_db_user',
    :'n8n_db_password'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = :'n8n_db_user'
);
\gexec

SELECT format(
    'CREATE DATABASE %I OWNER %I',
    :'n8n_db_name',
    :'n8n_db_user'
)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_database
    WHERE datname = :'n8n_db_name'
);
\gexec
EOSQL
