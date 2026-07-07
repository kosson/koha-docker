---
title: Strengthen db-detect probe: use root credentials via koha-common.cnf
date: 2026-06-04
tags:
 - koha-common
 - credentials
---
# 2026-06-04 — Strengthen db-detect probe: use root credentials via koha-common.cnf

## Problem

The auto-detection probe introduced on 2026-06-03 connected to MariaDB using the Koha application user (`${DB_USER}` / `${DB_PASSWORD}`, i.e. `koha_kohadev`). Two reliability risks existed:

1. The Koha user grants are applied by `do_all_you_can_do.pl` itself — on a very first installation the user may not yet have `INFORMATION_SCHEMA` SELECT privileges when the probe runs.
2. Using `DATABASE()` in the `WHERE table_schema = DATABASE()` clause returns `NULL` when no default database is selected on the connection, silently falling back to `no` (fresh install) even when data exists.

## Fix — `files/run.sh`

### Switched credentials to root via `/etc/mysql/koha-common.cnf`

`/etc/mysql/koha-common.cnf` is written at line ~145 of `run.sh`, well before the probe at line ~358. It contains:

```ini
[client]
host     = ${DB_HOSTNAME}
user     = root
password = ${KOHA_DB_ROOT_PASSWORD}
```

`KOHA_DB_ROOT_PASSWORD` is read from the container environment (set in `env/.env`; forwarded via `docker-compose.yml`'s `environment:` block). It must match the `MYSQL_ROOT_PASSWORD` used by the `db` service.
The probe was changed from connecting as the Koha application user:

```bash
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
```

to connecting as root via the cnf file:

```bash
_db_populated=$(mysql \
    --defaults-file=/etc/mysql/koha-common.cnf \
    --batch --skip-column-names \
    -e "SELECT IF(
          (SELECT COUNT(*) FROM information_schema.tables
           WHERE table_schema = '${DB_NAME}'
           AND table_name = 'systempreferences') > 0,
        'yes', 'no');" 2>/dev/null || echo "no")
```

Key differences:

| Aspect | Before | After |
|---|---|---|
| Credentials | `koha_kohadev` user (may not have grants yet) | `root` via `/etc/mysql/koha-common.cnf` (always available) |
| Schema reference | `DATABASE()` — returns NULL without a default DB | Literal `'${DB_NAME}'` — always correct |
| Tables checked | `systempreferences` OR `borrowers` | `systempreferences` only — sufficient signal, avoids edge cases |
| No default database passed | Via positional argument `"${DB_NAME}"` | No positional arg needed (schema in WHERE clause) |

### Explicit `USE_EXISTING_DB_FLAG=""` initialisation

`USE_EXISTING_DB_FLAG` is now explicitly initialised to the empty string immediately before the probe block, guaranteeing the variable is always defined even if Bash `set -u` is ever added:

```bash
USE_EXISTING_DB_FLAG=""
if [ "${USE_EXISTING_DB}" != "yes" ]; then
    …probe…
fi
if [ "${USE_EXISTING_DB}" = "yes" ]; then
    USE_EXISTING_DB_FLAG="--use-existing-db"
fi
```

### Version bump

`RUN_SH_VERSION` updated from `2026-05-22` to `2026-06-04`.

## Files changed

| File | Change |
|---|---|
| `files/run.sh` | Probe switched to `--defaults-file=/etc/mysql/koha-common.cnf` (root); password read from `${KOHA_DB_ROOT_PASSWORD}`; `WHERE table_schema = '${DB_NAME}'`; single table check (`systempreferences`); added `USE_EXISTING_DB_FLAG=""` initialisation; version bumped to `2026-06-04` |
| `docker-compose.yml` | Added `KOHA_DB_ROOT_PASSWORD: ${KOHA_DB_ROOT_PASSWORD:-password}` to `koha` service `environment:` block so the variable reaches `run.sh` |
| `env/defaults.env` | Added security warning comment on `KOHA_DB_ROOT_PASSWORD` |
| `env/template.env` | Added `KOHA_DB_ROOT_PASSWORD=change_me_before_first_start` with a security note prompting operators to set a strong password |

## How to apply

The image must be rebuilt for this change to take effect:

```bash
./stack.sh build --build-koha
docker tag kosson/koha-ubuntu:latest kosson/koha-ubuntu:26.05.01
docker push kosson/koha-ubuntu:26.05.01
```

On the production machine:

```bash
docker pull kosson/koha-ubuntu:26.05.01
# set KOHA_IMAGE_TAG=kosson/koha-ubuntu:26.05.01 in env/.env
docker compose stop koha && docker compose rm -f koha
./stack.sh start --no-fresh-db
```