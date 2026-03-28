#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-up}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-cc-postgres-debug}"
REDIS_CONTAINER="${REDIS_CONTAINER:-cc-redis-debug}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7}"
POSTGRES_PORT="${POSTGRES_PORT:-5444}"
REDIS_PORT="${REDIS_PORT:-6389}"
POSTGRES_USER="${POSTGRES_USER:-candlecast}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-devpass}"
POSTGRES_DB="${POSTGRES_DB:-candlecast}"

wait_for_postgres() {
  echo "Waiting for Postgres to become ready..."
  until docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; do
    sleep 1
  done
}

case "$ACTION" in
  up)
    docker rm -f "$POSTGRES_CONTAINER" "$REDIS_CONTAINER" >/dev/null 2>&1 || true

    docker run --name "$POSTGRES_CONTAINER" \
      -e POSTGRES_USER="$POSTGRES_USER" \
      -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
      -e POSTGRES_DB="$POSTGRES_DB" \
      -p "$POSTGRES_PORT":5432 \
      -d "$POSTGRES_IMAGE" >/dev/null

    docker run --name "$REDIS_CONTAINER" \
      -p "$REDIS_PORT":6379 \
      -d "$REDIS_IMAGE" >/dev/null

    wait_for_postgres

    echo
    echo "Debug lab is ready."
    echo "Postgres: postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@127.0.0.1:$POSTGRES_PORT/$POSTGRES_DB"
    echo "Redis:    redis://127.0.0.1:$REDIS_PORT/0"
    echo
    echo "Useful checks:"
    echo "  docker ps --filter name=$POSTGRES_CONTAINER --filter name=$REDIS_CONTAINER"
    echo "  docker exec -it $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $POSTGRES_DB"
    ;;

  down)
    docker rm -f "$POSTGRES_CONTAINER" "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    echo "Removed $POSTGRES_CONTAINER and $REDIS_CONTAINER"
    ;;

  status)
    docker ps --filter name="$POSTGRES_CONTAINER" --filter name="$REDIS_CONTAINER"
    ;;

  *)
    echo "Usage: $0 [up|down|status]"
    exit 2
    ;;
esac
