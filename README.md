# postgres-debug-lab

A practical GitHub-ready lab for debugging Linux processes and PostgreSQL locking behavior during development.

## Included

- `docs/linux_process_and_postgres_lock_debugging_guide_v2.docx`
- `scripts/create_debug_lab_docker.sh`
- `scripts/run_postgres_debug_cases.sh`

## Quick start

```bash
chmod +x scripts/*.sh
./scripts/create_debug_lab_docker.sh up
./scripts/run_postgres_debug_cases.sh
```

## Suggested GitHub description

Small practical lab for debugging Linux processes, PostgreSQL locks, and blocked test runs during development.

## Push to GitHub

Create a new empty GitHub repo, then run:

```bash
git init
git add .
git commit -m "Initial commit: Linux/Postgres debugging lab"
git branch -M main
git remote add origin <YOUR_GITHUB_REPO_URL>
git push -u origin main
```

## Safety note

Scripts that terminate DB sessions should only be used on local or disposable environments.
