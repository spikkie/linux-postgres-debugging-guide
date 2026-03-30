#!/usr/bin/env bash
set -xeuo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5444}"
DB_USER="${DB_USER:-candlecast}"
DB_NAME="${DB_NAME:-candlecast}"
DB_PASSWORD="${DB_PASSWORD:-devpass}"

docker run --rm --network host -e PGPASSWORD="$DB_PASSWORD" postgres:16   psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
select pg_terminate_backend(pid)
from pg_stat_activity
where datname = '$DB_NAME'
  and pid <> pg_backend_pid()
  and state = 'idle in transaction';"
