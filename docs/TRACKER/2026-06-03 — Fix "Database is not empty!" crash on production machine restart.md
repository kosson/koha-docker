---
title: Fix "Database is not empty!" crash on production machine restart
date: 2026.06.03
tags:
 - database
 - reboot
 - koha-db-data
---
# 2026-06-03 — Fix "Database is not empty!" crash on production machine restart

## Problem

After a normal machine reboot (or any `docker compose up` that recreates only the Koha container while the named volume `koha-db-data` persists), the Koha container exited immediately with:

```log
koha-1  | Database is not empty! at /kohadevbox/misc4dev/do_all_you_can_do.pl line 89.
koha-1 exited with code 255
```

The stack would not come up at all until the database was manually wiped — defeating the purpose of a persistent volume.

## Root cause

`misc4dev/do_all_you_can_do.pl` begins by probing the database:

```perl
my ( $prefs_count ) = $dbh->selectrow_array(q|SELECT COUNT(*) FROM systempreferences|);
my ( $patrons_count ) = $dbh->selectrow_array(q|SELECT COUNT(*) FROM borrowers|);
my $db_exists = $prefs_count || $patrons_count;
if ( $db_exists && !$use_existing_db ) {
    die "Database is not empty!";
}
```

If either table is non-empty **and** the `--use-existing-db` flag was not passed, it calls `die` which causes the process to exit with code 255.

`files/run.sh` passed `--use-existing-db` only when the environment variable `USE_EXISTING_DB` was explicitly set to `yes` in `env/.env`. There was no mechanism to auto-detect an existing database on restart — the variable was empty by default, so every container start (including plain restarts after reboots) attempted a fresh installation and crashed when it found the populated database that lived in the persistent volume.

The `koha-db-data` named Docker volume survives all of the following events:

- `docker compose stop` / `docker compose up`
- Host machine power-off / reboot
- `./stack.sh stop` followed by `./stack.sh start`

Only `docker compose down --volumes` (or `./stack.sh reset`) removes it. So on every production restart the container would crash unless the operator remembered to pass `USE_EXISTING_DB=yes` by hand.

## Fix — three coordinated changes

### 1. `files/run.sh` — auto-detection probe

The single `if [ "${USE_EXISTING_DB}" = "yes" ]` guard was replaced with a two-step block:

```bash
# Auto-detect an existing (non-empty) Koha database …
if [ "${USE_EXISTING_DB}" != "yes" ]; then
    echo "[db-detect] Probing '${DB_NAME}' for existing Koha data..."
    _db_populated=$(mysql \
        --host="${DB_HOSTNAME}" \
        --user="${DB_USER}" \
        --password="${DB_PASSWORD}" \
        --batch --skip-column-names \
        "${DB_NAME}" \
        -e "SELECT IF(
              (SELECT COUNT(*) FROM information_schema.tables
               WHERE table_schema = DATABASE()
               AND table_name IN ('systempreferences','borrowers')) > 0,
            'yes', 'no');" 2>/dev/null || echo "no")
    if [ "${_db_populated:-no}" = "yes" ]; then
        echo "[db-detect] Existing Koha data found — enabling --use-existing-db automatically"
        USE_EXISTING_DB="yes"
    else
        echo "[db-detect] Database is empty — proceeding with fresh Koha installation"
    fi
    unset _db_populated
fi

if [ "${USE_EXISTING_DB}" = "yes" ]; then
    USE_EXISTING_DB_FLAG="--use-existing-db"
fi
```

Logic:

| Condition | Outcome |
|---|---|
| `USE_EXISTING_DB=yes` already set (by env or `stack.sh --no-fresh-db`) | Probe is skipped entirely; `--use-existing-db` is passed to `do_all_you_can_do.pl` |
| `USE_EXISTING_DB` empty, `mysql` probe returns `yes` | Variable is set to `yes` automatically; `--use-existing-db` is passed |
| `USE_EXISTING_DB` empty, `mysql` probe returns `no` | Fresh installation proceeds normally |
| `USE_EXISTING_DB` empty, `mysql` exits non-zero (DB unreachable) | Fallback to `no`; fresh installation proceeds (safe default) |

The probe queries `information_schema.tables` (available in any MariaDB/MySQL regardless of whether the Koha schema has been applied) rather than querying `systempreferences` directly — which would fail with a table-not-found error on a genuinely empty database.

**Important:** `files/run.sh` is **baked into the Docker image** at build time. This fix only takes effect after rebuilding the image:

```bash
./stack.sh start --build-koha
```

### 2. `docker-compose.yml` — expose `USE_EXISTING_DB` to the container

`USE_EXISTING_DB` existed only in `env_file: env/.env`. Docker Compose does not forward a shell-level exported variable into a container unless it is also listed in the `environment:` block. Added:

```yaml
environment:
    # …existing entries…
    USE_EXISTING_DB: ${USE_EXISTING_DB:-}
```

The `:-` default means the variable is always present in the container environment — either with the value exported by the shell (e.g. `yes` when `stack.sh --no-fresh-db` runs) or as an empty string, which triggers the auto-detection probe in `run.sh`.

### 3. `stack.sh` — export `USE_EXISTING_DB=yes` for `--no-fresh-db`

The `start --no-fresh-db` branch was updated to export the variable before calling `start_koha`:

```bash
if [[ "${FRESH_DB}" == true ]]; then
    reset_database
else
    export USE_EXISTING_DB=yes
    log "--no-fresh-db: USE_EXISTING_DB=yes exported to Koha container"
fi
```

This makes the `--no-fresh-db` flag reliable as an explicit operator override: it skips both the database drop/recreate in `stack.sh` **and** the auto-detection probe inside the container, jumping directly to the `--use-existing-db` path in `do_all_you_can_do.pl`.

## Test suite — `tests/`

A `tests/` directory was created with three test scripts and a runner. No Docker or internet access is required for the static and unit tests; the integration test auto-skips when the stack is not running.

### `tests/test_run_sh_static.sh` — Static analysis (13 assertions)

Verifies that the fix is correctly present in `files/run.sh` by text search. Assertions cover:

- Presence of the `[db-detect] Probing` auto-detection block
- The probe queries `information_schema.tables` for both `systempreferences` and `borrowers`
- The probe uses the correct credential variables (`DB_HOSTNAME`, `DB_USER`, `DB_PASSWORD`)
- A positive result sets `USE_EXISTING_DB="yes"`
- `USE_EXISTING_DB_FLAG="--use-existing-db"` is still emitted and forwarded to `do_all_you_can_do.pl`
- The outer guard (`[ "${USE_EXISTING_DB}" != "yes" ]`) prevents redundant probing when the variable is already set
- The temporary `_db_populated` variable is cleaned up with `unset`
- Log messages for both the "existing data" and "empty database" cases are present

### `tests/test_db_detection_unit.sh` — Unit tests (7 assertions)

Uses a fake `mysql` binary injected at the front of `PATH` to simulate different database states. Tests:

1. **Empty DB** (`mysql` returns `no`): `USE_EXISTING_DB` stays empty, `USE_EXISTING_DB_FLAG` stays empty
2. **Non-empty DB** (`mysql` returns `yes`): `USE_EXISTING_DB` becomes `yes`, flag becomes `--use-existing-db`
3. **Pre-set `USE_EXISTING_DB=yes`**: the probe is skipped (fake `mysql` returns `no` but the variable stays `yes`)
4. **`mysql` exits non-zero**: safe fallback — `USE_EXISTING_DB` stays empty (fresh install proceeds)

### `tests/test_restart_integration.sh` — Integration test (3 assertions)

Runs against a live Docker stack. Stops the Koha container, restarts it with `USE_EXISTING_DB=yes` (simulating what happens on a plain machine reboot with `--no-fresh-db` semantics), then waits up to `MAX_WAIT` seconds (default: 300) for the startup banner. Asserts:

1. The DB container is running
2. The Koha container does not exit with code 255 ("Database is not empty!")
3. The "started up" banner appears in the logs within the timeout

Auto-skips gracefully when the stack is not started or when `systempreferences` is not yet present (genuinely empty DB).

### `tests/run_all_tests.sh` — Runner

Runs all three suites in order, accumulates pass/fail/skip counts, prints a summary, and exits with code 0 (all pass/skip) or 1 (at least one failure).

```bash
bash tests/run_all_tests.sh
```

## Files changed

| File | Change |
|---|---|
| `files/run.sh` | Replaced single `USE_EXISTING_DB` guard with auto-detection probe using `mysql`/`information_schema.tables`; probe is guarded and skipped when variable is already set; safe fallback on `mysql` failure |
| `docker-compose.yml` | Added `USE_EXISTING_DB: ${USE_EXISTING_DB:-}` to the `environment:` block of the `koha` service so shell-exported values reach the container |
| `stack.sh` | `start --no-fresh-db` path now exports `USE_EXISTING_DB=yes` before starting the Koha container; `start` (default `FRESH_DB=true`) now probes the database with `information_schema` and asks for explicit confirmation before dropping it — preventing accidental wipes on restart |
| `tests/test_run_sh_static.sh` | **New** — 13 static assertions that the fix is present in `run.sh` |
| `tests/test_db_detection_unit.sh` | **New** — 7 unit assertions covering all detection branches via a mock `mysql` |
| `tests/test_restart_integration.sh` | **New** — Integration test for live stack restart without DB wipe |
| `tests/run_all_tests.sh` | **New** — Orchestrates all test suites with TAP output and summary |

## How to apply

1. Rebuild the Koha image (required — `run.sh` is baked in at build time):

   ```bash
   ./stack.sh start --build-koha
   ```

2. For normal day-to-day restarts after a machine reboot, just run:

   ```bash
   ./stack.sh start --no-fresh-db
   ```

   The container will detect the existing database automatically, or respect `USE_EXISTING_DB=yes` if exported.

3. To verify the fix is in place:

   ```bash
   bash tests/run_all_tests.sh
   ```