---
title: Documentation: security-critical environment variables section in README.md
date: 2026.06.04
tags:
 - variables
 - documentation
---
# 2026-06-04 — Documentation: security-critical environment variables section in README.md

## What was added

A new subsection `### Security-critical environment variables` was added inside `## Prerequisites` in `README.md`, immediately after the `### Koha source tree` subsection. It is the first thing an operator reads before running the stack for the first time.

The section contains a table covering every variable whose default value is unsafe in a networked environment:

| Variable | Insecure default | Risk |
|---|---|---|
| `KOHA_DB_ROOT_PASSWORD` | `password` | MariaDB root; flows to both `MYSQL_ROOT_PASSWORD` on `db` and `/etc/mysql/koha-common.cnf` inside Koha |
| `KOHA_DB_PASSWORD` | `password` | Koha application DB user password |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | `test@Cici24#ANA` | OpenSearch cluster `admin`; must match in `env/.env` **and** `OpenSearch-3.6/.env` |
| `ELASTIC_OPTIONS` | contains `admin:test@Cici24#ANA` | The `<userinfo>` element must stay in sync with the OS admin password |
| `KOHA_PASS` | `koha` | Koha superlibrarian web account |

A callout block explains the three-way OpenSearch password consistency requirement (the same value must appear in `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, the `<userinfo>` element of `ELASTIC_OPTIONS`, and `OpenSearch-3.6/.env`).

The existing `### Database` section was also updated: the stale note "The root password is hard-coded to `password` in `docker-compose.yml`" was replaced with a correct description of `KOHA_DB_ROOT_PASSWORD` and a link back to the security section.

### Files changed

| File | Change |
|---|---|
| `README.md` | Added `### Security-critical environment variables` under `## Prerequisites`; updated `### Database` section |