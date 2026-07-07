---
title: Fix intermittent ERROR 1045 during DB recreate after startup
date: 2026.06.07
tags:
 - error
 - database
 - recreate
 - access
---
# 2026-06-07 — Fix intermittent ERROR 1045 during DB recreate after startup

## Problem

`./stack.sh start` intermittently failed at:

```log
── Recreating Koha database ──
[hh:mm:ss] Dropping and recreating 'koha_kohadev'...
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)
```

This was observed even after `./stack.sh reset` (fresh volume), so it was not only a persisted-password drift case.

## Root cause

A startup race in MariaDB readiness checks:

- `wait_db_ready()` previously used `mysqladmin ping`, which can return success before authenticated SQL logins are consistently available during first init.
- `stack.sh` then immediately called `reset_database()` with authenticated root SQL, which could hit a short window returning `ERROR 1045`.

Additional inconsistency found in the same flow:

- One code path in `start` still used a hardcoded `-ppassword` for the pre-wipe detection query, which could diverge from `KOHA_DB_ROOT_PASSWORD`.

## Reproduction and detector test

Added integration test:

- `tests/test_mariadb_auth_readiness_integration.sh`

What it validates on a fresh DB volume:

1. Time when `mysqladmin ping` first succeeds.
2. Time when authenticated SQL (`mysql -uroot -p... -e 'SELECT 1;'`) first succeeds.

Observed result:

- Ping became ready before authenticated SQL (race window detected).

## Fix

File changed:

- `stack.sh`

Changes applied:

1. `wait_db_ready()` now waits for authenticated SQL readiness (`SELECT 1`) instead of `mysqladmin ping`.
2. Replaced remaining hardcoded `-ppassword` in the `start` branch data-existence probe with `-p"${KOHA_DB_ROOT_PASSWORD}"`.
3. Kept root auth operations consistently tied to `KOHA_DB_ROOT_PASSWORD` from `env/.env`.

## Validation commands used

```bash
./stack.sh reset
./stack.sh start --no-logs
bash tests/test_mariadb_auth_readiness_integration.sh
```

Outcome:

- Race condition reproduced by test and then mitigated in startup flow.
- `./stack.sh start --no-logs` completes DB recreate without intermittent `ERROR 1045`.