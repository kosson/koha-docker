---
title: "Security: stop hardcoding MariaDB root password in run.sh"
date: 2026.06.04
tags:
 - security
 - root
 - password
 - runsh
 - MariaDB
 - cnf
---
# 2026-06-04 — Security: stop hardcoding MariaDB root password in run.sh

## Problem

`files/run.sh` wrote `/etc/mysql/koha-common.cnf` with a hardcoded literal string:

```ini
[client]
host     = ${DB_HOSTNAME}
user     = root
password = password
```

The literal `password` was never read from any environment variable — it was baked into the image regardless of what `KOHA_DB_ROOT_PASSWORD` was set to in `env/.env`. This created two issues:

1. **Credential exposure** — the literal string `password` appeared in `run.sh`, in the built Docker image layer, and in this public TRACKER document. Anyone reading the repository or inspecting the image could infer the root password of every deployment that had not explicitly changed `MYSQL_ROOT_PASSWORD` on the `db` container.
2. **Functional mismatch** — if an operator changed `KOHA_DB_ROOT_PASSWORD` in `env/.env` (which correctly flowed to `MYSQL_ROOT_PASSWORD` on the `db` service), the `/etc/mysql/koha-common.cnf` inside the Koha container would still carry the old literal `password`, causing the db-detect probe and any other `--defaults-file` MySQL call to fail authentication silently.

`KOHA_DB_ROOT_PASSWORD` already existed in `defaults.env` and was already wired to `MYSQL_ROOT_PASSWORD` on the `db` service via `docker-compose.yml`. The `koha` service simply never received it, and `run.sh` never read it.

## Fix — four coordinated changes

### 1. `files/run.sh` — read variable instead of hardcoding

Line 148 changed from:

```bash
echo "password = password"       >> /etc/mysql/koha-common.cnf
```

to:

```bash
echo "password = ${KOHA_DB_ROOT_PASSWORD}"  >> /etc/mysql/koha-common.cnf
```

The cnf now always mirrors whatever root password the `db` container was initialised with.

### 2. `docker-compose.yml` — forward variable to the `koha` service

`KOHA_DB_ROOT_PASSWORD` was only consumed via `env_file: env/.env`; shell-exported values are not forwarded to containers unless also listed in `environment:`. Added to the `koha` service `environment:` block:

```yaml
# Root password for the MariaDB container — must match MYSQL_ROOT_PASSWORD
# on the db service. Set in env/.env as KOHA_DB_ROOT_PASSWORD.
KOHA_DB_ROOT_PASSWORD: ${KOHA_DB_ROOT_PASSWORD:-password}
```

The `:-password` fallback preserves backwards compatibility with existing deployments that never set the variable explicitly.

### 3. `env/defaults.env` — add security warning comment

```bash
# SECURITY: change this from the default before running in any non-throwaway environment.
# Must match MYSQL_ROOT_PASSWORD on the db service. Used by run.sh to write
# /etc/mysql/koha-common.cnf (root credentials for internal admin operations).
KOHA_DB_ROOT_PASSWORD=password
```

### 4. `env/template.env` — prompt operators to set a real password

Changed the template value from the implicit default to:

```bash
# SECURITY: set a strong password here. This becomes both MYSQL_ROOT_PASSWORD for
# the db container and the credential written to /etc/mysql/koha-common.cnf inside
# the Koha container. Never leave this as 'password' in a networked environment.
KOHA_DB_ROOT_PASSWORD=change_me_before_first_start
```

A `cp env/template.env env/.env` now forces the operator to actively choose a password before the stack will authenticate correctly.

## Important: changing the password on an existing stack

`MYSQL_ROOT_PASSWORD` is set once when the `koha-db-data` named volume is first created. Changing `KOHA_DB_ROOT_PASSWORD` in `env/.env` after that point updates the cnf file inside the Koha container, but MariaDB still uses the old password from the volume. To rotate the root password on an existing stack:

```bash
# 1. Connect with the current password
docker exec -it koha-db-1 mariadb -uroot -p<OLD_PASSWORD>

# 2. Inside MariaDB:
ALTER USER 'root'@'%' IDENTIFIED BY '<NEW_PASSWORD>';
FLUSH PRIVILEGES;
EXIT;

# 3. Update env/.env
# KOHA_DB_ROOT_PASSWORD=<NEW_PASSWORD>

# 4. Restart to pick up the new cnf
docker compose stop koha && docker compose rm -f koha
./stack.sh start --no-fresh-db
```

## Files changed

| File | Change |
|---|---|
| `files/run.sh` | Line 148: `password = ${KOHA_DB_ROOT_PASSWORD}` instead of literal `password` |
| `docker-compose.yml` | Added `KOHA_DB_ROOT_PASSWORD: ${KOHA_DB_ROOT_PASSWORD:-password}` to `koha` service `environment:` block |
| `env/defaults.env` | Added `# SECURITY:` warning comment on `KOHA_DB_ROOT_PASSWORD` |
| `env/template.env` | `KOHA_DB_ROOT_PASSWORD=change_me_before_first_start` with security note |

## How to apply

The image must be rebuilt for the `run.sh` change to take effect:

```bash
./stack.sh build --build-koha
docker tag kosson/koha-ubuntu:latest kosson/koha-ubuntu:26.05.01
docker push kosson/koha-ubuntu:26.05.01
```

On the production machine:

```bash
docker pull kosson/koha-ubuntu:26.05.01
# set KOHA_IMAGE_TAG=kosson/koha-ubuntu:26.05.01 in env/.env
# set KOHA_DB_ROOT_PASSWORD to your actual root password in env/.env
docker compose stop koha && docker compose rm -f koha
./stack.sh start --no-fresh-db
```