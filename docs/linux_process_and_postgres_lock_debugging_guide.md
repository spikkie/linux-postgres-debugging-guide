# Debugging Linux Processes and PostgreSQL Locking During Development

A practical field guide for debugging:

- Linux process hangs
- parent/child process waits
- Python and pytest wrappers that look frozen
- PostgreSQL lock contention
- idle-in-transaction sessions
- blocked `TRUNCATE`, DDL, and fixture resets

> Core idea: a process that "hangs" is usually waiting on something specific:
> a child process, a database lock, a socket, a file descriptor, or a userspace condition variable.

---

## 1. Mental model

When a command appears frozen, start by classifying the wait.

| Symptom | Likely state | Meaning | Next move |
|---|---|---|---|
| No CPU, command still alive | Blocked wait | Usually waiting on child process, DB, or lock | Inspect parent/child and wait reason |
| High CPU | Busy loop / repeated retry | Not a lock problem first | Use `top`, `py-spy`, or `perf` |
| Python wrapper shows nothing | Child output buffered or captured | Parent may be fine | Run child test directly with `-vv -s -x` |
| Database DDL never finishes | Lock wait | `TRUNCATE` / `ALTER` / `DROP` blocked by readers | Inspect `pg_stat_activity` and `pg_locks` |

A common development chain is:

shell wrapper → Python supervisor → pytest child → database session

The outermost process looks hung, but the real blocker often lives one or two layers deeper.

---

## 2. Fast triage on Linux

## 2.1 Is the parent waiting on a child?

```bash
pgrep -a -P <PARENT_PID>
ps -o pid,ppid,stat,etime,wchan:24,cmd -p <PARENT_PID>,$(pgrep -P <PARENT_PID>)
pstree -ap <PARENT_PID>
```

What to look for:

- If the parent is in `wait4` or `poll_schedule_timeout`, it is usually supervising a child.
- If the child is `pytest`, debug the child directly instead of the wrapper.

## 2.2 What is the process waiting on?

```bash
strace -ff -p <PID> -s 200 -tt -o /tmp/trace.out
# let it run for 5–10 seconds, then Ctrl-C
tail -n 40 /tmp/trace.out*
```

How to read it:

- `wait4(...)` → parent is waiting for a child process to exit
- `futex(...)` → thread is parked on a userspace lock or condition variable
- `epoll_wait(...)` or `poll(...)` → waiting on I/O, often sockets or pipes
- Postgres socket reads/writes → active database communication

## 2.3 Show threads and wait channels

```bash
ps -T -p <PID> -o pid,spid,stat,wchan:24,comm
top -H -p <PID>
```

Useful when a multi-threaded Python process is blocked in one thread and supervising in another.

## 2.4 For Python specifically

```bash
PYTHONFAULTHANDLER=1 PYTHONUNBUFFERED=1 python -X faulthandler my_script.py
# if it stalls:
kill -USR1 <PID>
```

For pytest, rerun the exact child with live output:

```bash
python -m pytest -vv -s -x path/to/test.py
```

---

## 3. Debugging a process that uses a database

For DB-backed services, always debug both sides:

- application process
- database server

A blocked app often reflects a lock wait on the DB side.

## 3.1 Separate the layers

- **Application parent process**: shell script, supervisor, or task runner
- **Application child process**: pytest, gunicorn worker, uvicorn worker, migration command
- **Database session**: one or more SQL connections inside the child process

## 3.2 Inspect PostgreSQL directly

```bash
docker run --rm --network host -e PGPASSWORD=devpass postgres:16   psql -h 127.0.0.1 -p 5444 -U candlecast -d candlecast -c "
  select pid, usename, state, wait_event_type, wait_event,
         xact_start, query_start, left(query, 180) as query
  from pg_stat_activity
  where datname = 'candlecast'
  order by query_start;"
```

Interpretation:

- `active` = backend is running a query now
- `idle` = connected but not in a transaction
- `idle in transaction` = transaction opened and never closed; very common development bug
- `wait_event_type` and `wait_event` tell you whether the backend is waiting on a lock, client, I/O, and so on

---

## 4. How to look for PostgreSQL locks

Most development hangs around `TRUNCATE`, `ALTER TABLE`, `DROP TABLE`, migrations, and fixture resets are lock problems.

## 4.1 Quick lock view

```bash
docker run --rm --network host -e PGPASSWORD=devpass postgres:16   psql -h 127.0.0.1 -p 5444 -U candlecast -d candlecast -c "
  select a.pid,
         a.state,
         a.wait_event_type,
         a.wait_event,
         l.locktype,
         l.mode,
         l.granted,
         c.relname,
         left(a.query, 160) as query
  from pg_locks l
  join pg_stat_activity a on a.pid = l.pid
  left join pg_class c on c.oid = l.relation
  where a.datname = 'candlecast'
  order by a.pid, l.granted;"
```

## 4.2 Blocked vs blocking sessions

```bash
docker run --rm --network host -e PGPASSWORD=devpass postgres:16   psql -h 127.0.0.1 -p 5444 -U candlecast -d candlecast -c "
with blocked as (
  select a.pid, a.query, a.state, a.wait_event_type, a.wait_event
  from pg_stat_activity a
  where a.datname = 'candlecast'
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
```

## 4.3 Typical development lock pattern

| Action | What blocks it | Why it happens |
|---|---|---|
| `TRUNCATE TABLE events` | Reader still holds `AccessShareLock` | Old test session is idle in transaction after `SELECT` |
| `ALTER TABLE ...` | Long-running query or transaction | Migration runs while app session is still open |
| `DROP TABLE ...` | Open session touched the relation | Developer shell left a transaction open |
| Fixture cleanup | Connection pool has stale checked-out sessions | Failure path skipped rollback/close |

---

## 5. How these failures happen during development

These bugs are common because development environments are messy by default:

- a test opens a transaction and fails before rollback or close runs
- a developer shell or notebook leaves a transaction open after `SELECT`
- a connection pool keeps sessions alive longer than expected
- a fixture does cleanup with `TRUNCATE` while another session is still reading the same table
- a wrapper script captures child output, so a blocked child looks like a hung parent
- retries, task runners, and supervisors hide the real blocking layer unless you inspect the process tree

A concrete development failure chain:

1. shell wrapper calls Python verifier
2. verifier launches pytest
3. pytest opens a DB session
4. fixture tries to `TRUNCATE` tables to start clean
5. older session is still `idle in transaction` on one of those tables
6. `TRUNCATE` waits on relation lock
7. wrapper appears hung, but the real blocker is an old DB session

---

## 6. Small scripts you can keep in your repo

## 6.1 `debug-process.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

PID="${1:?usage: debug-process.sh <pid>}"

echo "== process tree =="
pstree -ap "$PID" || true
echo

echo "== parent + children =="
CHILDREN="$(pgrep -P "$PID" || true)"
ps -o pid,ppid,stat,etime,wchan:24,cmd -p "$PID"${CHILDREN:+,$(echo "$CHILDREN" | paste -sd, -)} || true
echo

echo "== threads =="
ps -T -p "$PID" -o pid,spid,stat,wchan:24,comm || true
```

## 6.2 `pg-activity.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5444}"
DB_USER="${DB_USER:-candlecast}"
DB_NAME="${DB_NAME:-candlecast}"
DB_PASSWORD="${DB_PASSWORD:-devpass}"

docker run --rm --network host -e PGPASSWORD="$DB_PASSWORD" postgres:16   psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
  select pid, usename, state, wait_event_type, wait_event,
         xact_start, query_start, left(query, 180) as query
  from pg_stat_activity
  where datname = '$DB_NAME'
  order by query_start;"
```

## 6.3 `pg-blockers.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-5444}"
DB_USER="${DB_USER:-candlecast}"
DB_NAME="${DB_NAME:-candlecast}"
DB_PASSWORD="${DB_PASSWORD:-devpass}"

docker run --rm --network host -e PGPASSWORD="$DB_PASSWORD" postgres:16   psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
with blocked as (
  select a.pid, a.query, a.state, a.wait_event_type, a.wait_event
  from pg_stat_activity a
  where a.datname = '$DB_NAME'
),
pairs as (
  select bl.pid as blocked_pid, ka.pid as blocking_pid
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
  left(b.query, 120) as blocked_query,
  p.blocking_pid,
  k.state as blocking_state,
  left(k.query, 120) as blocking_query
from pairs p
join blocked b on b.pid = p.blocked_pid
join blocked k on k.pid = p.blocking_pid
order by p.blocked_pid;"
```

## 6.4 `kill-idle-in-tx.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

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
```

Use this only on a local development database.

## 6.5 Rerun the exact child test with live output

```bash
PYTHONUNBUFFERED=1 ./api/.venv/bin/python -m pytest -vv -s -x   tests/integration/test_execution_bridge_runtime_checkpoint_contract_v1.py
```

---

## 7. Preventive practices

- set a small `lock_timeout` before destructive test reset steps such as `TRUNCATE`
- fail fast with blocker diagnostics instead of waiting forever
- always close or rollback DB sessions in test teardown and failure paths
- prefer running the exact child pytest file with `-vv -s -x` when the wrapper becomes opaque
- add DB activity and blocker scripts to the repo so the team uses the same debugging workflow
- for Python services, keep `faulthandler` enabled in difficult integration debugging sessions

---

## 8. Debugging checklist

1. Get the process tree. Confirm whether the parent is supervising a child.
2. Use `strace` for 5–10 seconds. Decide whether the process is in `wait4`, `futex`, or `epoll_wait`.
3. If there is a child pytest, run that exact child directly with `-vv -s -x`.
4. Inspect `pg_stat_activity`. Look for `active`, `idle`, and `idle in transaction`.
5. Inspect blockers with the blocked-vs-blocking query.
6. If safe in local dev, terminate stale idle-in-transaction backends.
7. Rerun and then patch the fixture or script so the next failure is fail-fast and self-diagnosing.

---

## 9. Repository metadata

### Where to put GitHub topics

Topics are **not stored inside the repository files**.

In GitHub:

1. open the repository page
2. on the right side, find **About**
3. click the **gear icon**
4. add these topics:

- `linux`
- `postgresql`
- `debugging`
- `locks`
- `pytest`
- `docker`
- `strace`
- `development-tools`

### Recommended repository description

**Hands-on lab for debugging Linux process hangs, PostgreSQL lock contention, idle transactions, and blocked pytest runs.**

---

## 10. Suggested repo layout

```text
docs/
  linux_process_and_postgres_lock_debugging_guide_v2.docx
  linux_process_and_postgres_lock_debugging_guide.md

scripts/
  create_debug_lab_docker.sh
  run_postgres_debug_cases.sh
```

Final rule:

Do not patch product code until you have proved whether the block lives in the parent wrapper, the child test process, or the database lock layer.
