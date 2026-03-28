#!/usr/bin/env bash
set -euo pipefail

POSTGRES_PORT="${POSTGRES_PORT:-5444}"
POSTGRES_USER="${POSTGRES_USER:-candlecast}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-devpass}"
POSTGRES_DB="${POSTGRES_DB:-candlecast}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16}"
DB_HOST="${DB_HOST:-127.0.0.1}"

psql_docker() {
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_IMAGE" \
    psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"
}

require_postgres() {
  if ! psql_docker -c 'select 1;' >/dev/null 2>&1; then
    echo "Postgres is not reachable on $DB_HOST:$POSTGRES_PORT"
    echo "Start it first with: ./create_debug_lab_docker.sh up"
    exit 1
  fi
}

prepare_demo_table() {
  echo
  echo "== Preparing demo table =="
  psql_docker -c "
    create table if not exists events (
      id bigserial primary key,
      stream text not null,
      seq bigint not null,
      payload jsonb not null default '{}'::jsonb
    );
    truncate table events restart identity;
    insert into events (stream, seq, payload)
    values ('demo', 1, '{\"name\":\"one\"}'),
           ('demo', 2, '{\"name\":\"two\"}'),
           ('demo', 3, '{\"name\":\"three\"}');
  "
}

show_activity() {
  echo
  echo "== pg_stat_activity =="
  psql_docker -c "
    select pid, usename, state, wait_event_type, wait_event,
           left(query, 140) as query
    from pg_stat_activity
    where datname = '$POSTGRES_DB'
    order by query_start nulls last;
  "
}

show_locks() {
  echo
  echo "== pg_locks joined with activity =="
  psql_docker -c "
    select a.pid,
           a.state,
           a.wait_event_type,
           a.wait_event,
           l.locktype,
           l.mode,
           l.granted,
           c.relname,
           left(a.query, 120) as query
    from pg_locks l
    join pg_stat_activity a on a.pid = l.pid
    left join pg_class c on c.oid = l.relation
    where a.datname = '$POSTGRES_DB'
    order by a.pid, l.granted;
  "
}

show_blockers() {
  echo
  echo "== blocked vs blocking sessions =="
  psql_docker -c "
    with blocked as (
      select a.pid, a.query, a.state, a.wait_event_type, a.wait_event
      from pg_stat_activity a
      where a.datname = '$POSTGRES_DB'
    ),
    pairs as (
      select
        bl.pid as blocked_pid,
        ka.pid as blocking_pid
      from pg_locks bl
      join pg_locks kl
        on bl.locktype = kl.locktype
       and bl.database is not distinct from kl.database
       and bl.relation is not distinct from kl.relation
       and bl.page is not distinct from kl.page
       and bl.tuple is not distinct from kl.tuple
       and bl.virtualxid is not distinct from kl.virtualxid
       and bl.transactionid is not distinct from kl.transactionid
       and bl.classid is not distinct from kl.classid
       and bl.objid is not distinct from kl.objid
       and bl.objsubid is not distinct from kl.objsubid
       and bl.pid <> kl.pid
      join pg_stat_activity ka on ka.pid = kl.pid
      where not bl.granted and kl.granted
    )
    select
      p.blocked_pid,
      b.state as blocked_state,
      b.wait_event_type,
      b.wait_event,
      left(b.query, 100) as blocked_query,
      p.blocking_pid,
      k.state as blocking_state,
      left(k.query, 100) as blocking_query
    from pairs p
    join blocked b on b.pid = p.blocked_pid
    join blocked k on k.pid = p.blocking_pid
    order by p.blocked_pid;
  "
}

case_parent_waiting_on_child() {
  echo
  echo "================ CASE 1 ================"
  echo "Parent wrapper waiting on a child process"
  cat > /tmp/demo_wait_wrapper.py <<'PY'
import subprocess, time
child = subprocess.Popen(["python3", "-c", "import time; time.sleep(20)"])
print(f"WRAPPER_PID={__import__('os').getpid()}")
print(f"CHILD_PID={child.pid}")
time.sleep(20)
PY

  python3 /tmp/demo_wait_wrapper.py >/tmp/demo_wait_wrapper.log 2>&1 &
  local wrapper_pid=$!
  sleep 1
  echo "Wrapper PID: $wrapper_pid"
  cat /tmp/demo_wait_wrapper.log
  echo
  echo "pstree:"
  pstree -ap "$wrapper_pid" || true
  echo
  echo "ps view:"
  local children
  children="$(pgrep -P "$wrapper_pid" | paste -sd, - || true)"
  if [[ -n "$children" ]]; then
    ps -o pid,ppid,stat,etime,wchan:24,cmd -p "$wrapper_pid,$children"
  else
    ps -o pid,ppid,stat,etime,wchan:24,cmd -p "$wrapper_pid"
  fi
  kill "$wrapper_pid" >/dev/null 2>&1 || true
  wait "$wrapper_pid" >/dev/null 2>&1 || true
}

start_idle_tx_session() {
  BLOCKER_FIFO="$(mktemp -u)"
  BLOCKER_LOG="$(mktemp)"
  mkfifo "$BLOCKER_FIFO"

  docker run --rm -i --network host -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_IMAGE" \
    psql -v ON_ERROR_STOP=1 -t -A -h "$DB_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    < "$BLOCKER_FIFO" > "$BLOCKER_LOG" 2>&1 &
  BLOCKER_CLIENT_PID=$!
  exec 9>"$BLOCKER_FIFO"
  printf "BEGIN;\nSELECT 'BLOCKER_PID=' || pg_backend_pid();\nSELECT * FROM events LIMIT 1;\n" >&9
  sleep 2
  BLOCKER_DB_PID="$(grep -o 'BLOCKER_PID=[0-9]\+' "$BLOCKER_LOG" | head -1 | cut -d= -f2)"
  echo "Idle transaction backend PID: ${BLOCKER_DB_PID:-unknown}"
}

stop_idle_tx_session_with_rollback() {
  printf "ROLLBACK;\n\\q\n" >&9 || true
  exec 9>&- || true
  wait "$BLOCKER_CLIENT_PID" >/dev/null 2>&1 || true
  rm -f "$BLOCKER_FIFO" "$BLOCKER_LOG"
}

start_truncate() {
  TRUNCATE_LOG="$(mktemp)"
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" "$POSTGRES_IMAGE" \
    psql -v ON_ERROR_STOP=1 -h "$DB_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -c 'TRUNCATE TABLE events RESTART IDENTITY CASCADE;' > "$TRUNCATE_LOG" 2>&1 &
  TRUNCATE_CLIENT_PID=$!
  sleep 2
}

wait_for_truncate() {
  wait "$TRUNCATE_CLIENT_PID"
  cat "$TRUNCATE_LOG"
  rm -f "$TRUNCATE_LOG"
}

case_idle_tx_blocks_truncate_then_rollback() {
  echo
  echo "================ CASE 2 ================"
  echo "Idle in transaction blocks TRUNCATE; release it with ROLLBACK"
  prepare_demo_table
  start_idle_tx_session
  start_truncate
  show_activity
  show_locks
  show_blockers
  echo
  echo "Releasing blocker with ROLLBACK..."
  stop_idle_tx_session_with_rollback
  wait_for_truncate
}

case_idle_tx_blocks_truncate_then_terminate() {
  echo
  echo "================ CASE 3 ================"
  echo "Idle in transaction blocks TRUNCATE; release it with pg_terminate_backend()"
  prepare_demo_table
  start_idle_tx_session
  start_truncate
  show_activity
  show_blockers
  echo
  echo "Terminating backend $BLOCKER_DB_PID ..."
  psql_docker -c "select pg_terminate_backend($BLOCKER_DB_PID);"
  exec 9>&- || true
  wait "$BLOCKER_CLIENT_PID" >/dev/null 2>&1 || true
  rm -f "$BLOCKER_FIFO" "$BLOCKER_LOG"
  wait_for_truncate
}

main() {
  require_postgres
  case_parent_waiting_on_child
  case_idle_tx_blocks_truncate_then_rollback
  case_idle_tx_blocks_truncate_then_terminate
  echo
  echo "All demo cases completed."
}

main "$@"
