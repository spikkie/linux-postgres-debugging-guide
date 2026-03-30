# postgres-debug-lab

A practical GitHub-ready lab for debugging Linux processes and PostgreSQL locking behavior during development.

## Included

- `docs/linux_process_and_postgres_lock_debugging_guide.md`
- `docs/linux_process_and_postgres_lock_debugging_guide_v2.docx`
- `scripts/create_debug_lab_docker.sh`
- `scripts/run_postgres_debug_cases_interactive.sh`
- `scripts/run_postgres_debug_cases.sh` (optional non-interactive variant)

## Scope

This lab focuses on:

- Linux process hangs
- parent/child wait relationships
- `strace`-based triage
- PostgreSQL session activity
- PostgreSQL locks and blockers
- `idle in transaction` failures
- blocked `TRUNCATE` and fail-fast `lock_timeout`



## Quick start

```bash
chmod +x scripts/*.sh
./scripts/create_debug_lab_docker.sh up
./scripts/run_postgres_debug_cases.sh
./scripts/run_postgres_debug_cases_interactive.sh
```

## Safety note
Scripts that terminate DB sessions should only be used on local or disposable environments.



## Most important Linux commands for these debugging problems

These are the commands that matter most when a process looks hung, a wrapper is waiting on a child, or a database-backed test is blocked.

### 1. Find child processes and process tree

```bash
pgrep -a -P <PARENT_PID>
pstree -ap <PARENT_PID>
ps -o pid,ppid,stat,etime,wchan:24,cmd -p <PARENT_PID>,$(pgrep -P <PARENT_PID>)
```

Use these first when a shell script or Python wrapper appears frozen.

What they tell you:

- whether the parent is supervising a child process
- which PID is the real worker
- whether the parent is waiting in `wait4`, `poll`, or another wait channel

### 2. Inspect thread-level wait state

```bash
ps -T -p <PID> -o pid,spid,stat,wchan:24,comm
top -H -p <PID>
```

Use these when the process is multi-threaded and you need to see whether one thread is blocked while another remains idle.

### 3. Trace system calls

```bash
strace -ff -p <PID> -s 200 -tt -o /tmp/trace.out
tail -n 40 /tmp/trace.out*
```

This is one of the fastest ways to classify a “hang”.

Typical patterns:

- `wait4(...)` → parent is waiting for a child process
- `futex(...)` → thread is parked on a lock or condition variable
- `epoll_wait(...)` or `poll(...)` → process is waiting on I/O
- reads/writes on DB sockets → database activity is happening

### 4. Dump Python stack traces

```bash
PYTHONFAULTHANDLER=1 PYTHONUNBUFFERED=1 python -X faulthandler my_script.py
kill -USR1 <PID>
```

Use this when the stuck process is Python and you want stack traces without attaching a debugger.

### 5. Rerun the real child directly

```bash
PYTHONUNBUFFERED=1 python -m pytest -vv -s -x path/to/test_file.py
```

When a wrapper hides progress, rerun the exact child process with live output.
This often solves the “looks hung” problem faster than debugging the wrapper.

### 6. Inspect PostgreSQL activity

```bash
docker run --rm --network host -e PGPASSWORD=devpass postgres:16 \
  psql -h 127.0.0.1 -p 5432 -U candlecast -d candlecast -c "
  select pid, usename, state, wait_event_type, wait_event,
         xact_start, query_start, left(query, 180) as query
  from pg_stat_activity
  where datname = 'candlecast'
  order by query_start;"
```

Use this when the app might be blocked on the database.

Most important states:

- `active`
- `idle`
- `idle in transaction`

`idle in transaction` is especially important because it often blocks cleanup, migrations, and `TRUNCATE`.

### 7. Inspect locks

```bash
docker run --rm --network host -e PGPASSWORD=devpass postgres:16 \
  psql -h 127.0.0.1 -p 5432 -U candlecast -d candlecast -c "
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

Use this when `TRUNCATE`, `ALTER TABLE`, `DROP TABLE`, or fixture cleanup appears stuck.

### 8. Find blockers vs blocked sessions

```bash
docker run --rm --network host -e PGPASSWORD=devpass postgres:16 \
  psql -h 127.0.0.1 -p 5432 -U candlecast -d candlecast -c "
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

This is the highest-value Postgres query when you need to answer:

- what is blocked
- what is blocking it
- which PID must be investigated or terminated

### 9. Terminate stale idle-in-transaction sessions (local dev only)

```bash
docker run --rm --network host -e PGPASSWORD=devpass postgres:16 \
  psql -h 127.0.0.1 -p 5432 -U candlecast -d candlecast -c "
select pg_terminate_backend(pid)
from pg_stat_activity
where datname = 'candlecast'
  and pid <> pg_backend_pid()
  and state = 'idle in transaction';"
```

Use this only on local or disposable environments.

### Practical order of use

When something looks hung, use this sequence:

1. `pgrep` / `pstree` / `ps` to find the real child process
2. `strace` to classify the wait
3. rerun the exact child test with `pytest -vv -s -x`
4. inspect `pg_stat_activity`
5. inspect `pg_locks`
6. run the blocker query
7. terminate stale sessions only if safe in local development


```

## Safety note

Scripts that terminate DB sessions should only be used on local or disposable environments.

## Utility script

To create a clean zip of the repository without the `.git` directory, use:

```bash
./scripts/zip_repo_except_git.sh .
```

Or specify both source and output:

```bash
./scripts/zip_repo_except_git.sh . /tmp/my-repo.zip
```
