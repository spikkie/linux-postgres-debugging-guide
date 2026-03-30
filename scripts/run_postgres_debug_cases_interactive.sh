#!/usr/bin/env bash
set -euo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-candlecast}"
DB_NAME="${DB_NAME:-candlecast}"
DB_PASSWORD="${DB_PASSWORD:-devpass}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:16}"

WORKDIR="${WORKDIR:-/tmp/postgres_debug_lab}"
mkdir -p "$WORKDIR"

CHILD_PID=""

cleanup() {
  set +e
  if [[ -n "${CHILD_PID:-}" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  docker rm -f debug-lock-holder >/dev/null 2>&1 || true
}
trap cleanup EXIT

psql_run() {
  docker run --rm --network host -e PGPASSWORD="$DB_PASSWORD" "$POSTGRES_IMAGE" \
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" "$@"
}

psql_cmd() {
  psql_run -v ON_ERROR_STOP=1 -c "$1"
}

wait_for_enter() {
  printf '\nPress Enter to continue... '
  read -r _
}

ask_case() {
  local case_name="$1"
  local question="$2"
  local hint="$3"

  echo
  echo "=================================================================="
  echo "CASE: $case_name"
  echo "------------------------------------------------------------------"
  echo "$question"
  echo
  echo "Hint:"
  echo "$hint"
  echo "------------------------------------------------------------------"
  echo "Open a second terminal to investigate and solve/debug the case."
  echo "When you think you understand it, answer below."
  echo "=================================================================="
  echo

  local answer
  read -r -p "Your diagnosis: " answer
  echo
  echo "Recorded answer: $answer"
  wait_for_enter
}

show_activity() {
  echo
  echo "== pg_stat_activity =="
  psql_cmd "
  select pid, usename, state, wait_event_type, wait_event,
         xact_start, query_start, left(query, 140) as query
  from pg_stat_activity
  where datname = '$DB_NAME'
  order by query_start nulls last;"
}

show_locks() {
  echo
  echo "== pg_locks + pg_stat_activity =="
  psql_cmd "
  select a.pid,
         a.state,
         a.wait_event_type,
         a.wait_event,
         l.locktype,
         l.mode,
         l.granted,
         c.relname,
         left(a.query, 140) as query
  from pg_locks l
  join pg_stat_activity a on a.pid = l.pid
  left join pg_class c on c.oid = l.relation
  where a.datname = '$DB_NAME'
  order by a.pid, l.granted;"
}

show_blockers() {
  echo
  echo "== blocked vs blocking =="
  psql_cmd "
  with blocked as (
    select a.pid, a.query, a.state, a.wait_event_type, a.wait_event
    from pg_stat_activity a
    where a.datname = '$DB_NAME'
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
    left(b.query,120) as blocked_query,
    p.blocking_pid,
    k.state as blocking_state,
    left(k.query,120) as blocking_query
  from pairs p
  join blocked b on b.pid = p.blocked_pid
  join blocked k on k.pid = p.blocking_pid
  order by p.blocked_pid;"
}

ensure_table() {
  psql_cmd "
  create table if not exists debug_lock_demo (
    id serial primary key,
    note text not null
  );
  insert into debug_lock_demo(note)
  values ('seed row');"
}

kill_idle_in_transaction() {
  echo
  echo "Terminating idle-in-transaction backends..."
  psql_cmd "
  select pg_terminate_backend(pid)
  from pg_stat_activity
  where datname = '$DB_NAME'
    and pid <> pg_backend_pid()
    and state = 'idle in transaction';"
}

run_case_parent_waits_on_child() {
  echo
  echo "### CASE 1: Parent process waits on child"

  cat > "$WORKDIR/case1_child.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 600
EOF
  chmod +x "$WORKDIR/case1_child.sh"

  bash "$WORKDIR/case1_child.sh" &
  CHILD_PID=$!

  cat > "$WORKDIR/case1_parent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep_pid="$1"
wait "$sleep_pid"
EOF
  chmod +x "$WORKDIR/case1_parent.sh"

  bash "$WORKDIR/case1_parent.sh" "$CHILD_PID" &
  local parent_pid=$!

  echo "Parent PID: $parent_pid"
  echo "Child PID:  $CHILD_PID"
  echo "Try in another terminal:"
  echo "  pstree -ap $parent_pid"
  echo "  ps -o pid,ppid,stat,etime,wchan:24,cmd -p $parent_pid,$CHILD_PID"
  echo "  strace -p $parent_pid"

  ask_case \
    "Parent waiting on child" \
    "Why does the parent look hung even though it is not burning CPU?" \
    "Find the child process and identify the wait reason."

  kill "$CHILD_PID" 2>/dev/null || true
  wait "$CHILD_PID" 2>/dev/null || true
  wait "$parent_pid" 2>/dev/null || true
  CHILD_PID=""
  echo "Case 1 cleaned up."
}

run_case_idle_tx_blocks_truncate() {
  echo
  echo "### CASE 2: Idle transaction blocks TRUNCATE"
  ensure_table

  echo "Starting background session that opens a transaction and leaves it idle..."
  docker run --rm -d --name debug-lock-holder --network host \
    -e PGPASSWORD="$DB_PASSWORD" "$POSTGRES_IMAGE" \
    bash -lc "printf 'begin;\nselect * from debug_lock_demo;\nselect pg_backend_pid();\n' | psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME && sleep 600" >/dev/null

  sleep 2

  cat > "$WORKDIR/case2_truncate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker run --rm --network host -e PGPASSWORD="$DB_PASSWORD" "$POSTGRES_IMAGE" \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "truncate table debug_lock_demo;"
EOF
  chmod +x "$WORKDIR/case2_truncate.sh"

  DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" DB_PASSWORD="$DB_PASSWORD" POSTGRES_IMAGE="$POSTGRES_IMAGE" \
    bash "$WORKDIR/case2_truncate.sh" &
  CHILD_PID=$!
  sleep 2

  echo "Blocked TRUNCATE PID: $CHILD_PID"
  show_activity
  show_locks
  show_blockers

  echo
  echo "Suggested commands in another terminal:"
  echo "  docker ps"
  echo "  docker logs debug-lock-holder"
  echo "  psql queries against pg_stat_activity and pg_locks"
  echo "  strace -p $CHILD_PID"

  ask_case \
    "Idle transaction blocks TRUNCATE" \
    "Why does TRUNCATE not finish? Which session blocks it, and what lock pattern is involved?" \
    "Look for one session in 'idle in transaction' and another waiting on a relation lock."

  echo
  read -r -p "Type 'solve' to terminate idle-in-transaction sessions automatically, or press Enter to solve manually: " choice
  if [[ "${choice:-}" == "solve" ]]; then
    kill_idle_in_transaction
  else
    echo "Solve it manually in another terminal, then come back."
    wait_for_enter
  fi

  wait "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=""
  docker rm -f debug-lock-holder >/dev/null 2>&1 || true
  echo "Case 2 cleaned up."
}

run_case_fail_fast_with_lock_timeout() {
  echo
  echo "### CASE 3: Fail fast with lock_timeout"
  ensure_table

  docker run --rm -d --name debug-lock-holder --network host \
    -e PGPASSWORD="$DB_PASSWORD" "$POSTGRES_IMAGE" \
    bash -lc "printf 'begin;\nselect * from debug_lock_demo;\nselect pg_backend_pid();\n' | psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME && sleep 600" >/dev/null

  sleep 2

  echo "Running TRUNCATE with lock_timeout=2s..."
  set +e
  docker run --rm --network host -e PGPASSWORD="$DB_PASSWORD" "$POSTGRES_IMAGE" \
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -c "set lock_timeout = '2s'; truncate table debug_lock_demo;" \
    > "$WORKDIR/case3.out" 2>&1
  local rc=$?
  set -e

  cat "$WORKDIR/case3.out"
  echo "Exit code: $rc"

  ask_case \
    "Fail-fast lock timeout" \
    "Why is a short lock_timeout often better than waiting forever during development or CI?" \
    "A fast explicit failure is usually easier to diagnose than a silent hang."

  read -r -p "Type 'solve' to terminate idle-in-transaction sessions automatically, or press Enter to solve manually: " choice
  if [[ "${choice:-}" == "solve" ]]; then
    kill_idle_in_transaction || true
  else
    echo "Solve it manually in another terminal, then come back."
    wait_for_enter
  fi

  docker rm -f debug-lock-holder >/dev/null 2>&1 || true
  echo "Case 3 cleaned up."
}

echo "=============================================================="
echo "Interactive Postgres Debugging Lab"
echo "=============================================================="
echo "Database: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
echo "Each case pauses and asks you to explain what is happening."
echo "Use a second terminal to investigate before you continue."
echo "=============================================================="

run_case_parent_waits_on_child
run_case_idle_tx_blocks_truncate
run_case_fail_fast_with_lock_timeout

echo
echo "All cases completed."
