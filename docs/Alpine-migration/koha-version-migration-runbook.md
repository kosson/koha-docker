<!-- markdownlint-disable MD032 MD029 -->

# Koha Version Migration Runbook (Container to Container)

## Purpose

This runbook is for migrating a running Koha stack to a newer Koha container version (including Ubuntu -> Alpine image changes) while preserving data and allowing rollback.

It assumes this repository layout and tooling (`stack.sh`, compose files, env files).

---

## Safety Model

The migration is safe if all 3 are true:

1. You have a fresh backup bundle (`./stack.sh backup`).
2. You start the new container with existing DB reuse (`--no-fresh-db`).
3. You do not run `reset` during the migration window.

---

## Inputs You Must Decide Before Start

- Target Koha version strategy:
  - `KOHA_GIT_CLONE_MODE=tag` with a new `KOHA_GIT_TAG`, or
  - `KOHA_GIT_CLONE_MODE=branch` with a new `KOHA_GIT_BRANCH`.
- Target image/base change (if any):
  - `KOHA_IMAGE_TAG` or Dockerfile updates.
- Maintenance window length (recommended: enough for DB schema upgrade + search rebuild checks).

---

## Pre-Checks (Mandatory)

Run from `koha-docker/`.

1. Confirm current stack status:

```bash
./stack.sh status
```

2. Confirm no destructive action is pending:
- Do not run `./stack.sh reset`.
- Do not start without `--no-fresh-db` during migration testing.

3. Confirm DB root password consistency in `env/.env`:
- `KOHA_DB_ROOT_PASSWORD` must match the existing `koha-db-data` volume.

4. Confirm instance naming consistency in `env/.env`:
- `KOHA_INSTANCE` unchanged unless this is an intentional new-instance migration.

5. Confirm OpenSearch credentials alignment:
- `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in `env/.env` matches OpenSearch config.

---

## Backup (Mandatory)

Create a timestamped recovery artifact immediately before any version change:

```bash
./stack.sh backup
```

Optional explicit path:

```bash
./stack.sh backup --output backups/pre-upgrade-$(date -u +%Y%m%dT%H%M%SZ).tar.gz
```

Expected backup contents:
- `env/.env`
- `traefik/.env`
- `OpenSearch-3.6/.env`
- DB dump (`koha_${KOHA_INSTANCE}.sql.gz`)

---

## Migration Procedure (Primary Path)

## Phase A: Prepare target version

1. Update version selectors in `env/.env`:
- `KOHA_GIT_CLONE_MODE`
- `KOHA_GIT_TAG` or `KOHA_GIT_BRANCH`
- optional `KOHA_IMAGE_TAG`

2. Build target Koha container image:

```bash
./stack.sh build --build-koha
```

## Phase B: Start using existing database

Start with DB preservation enabled:

```bash
./stack.sh start --no-fresh-db
```

Why this flag is mandatory:
- It exports `USE_EXISTING_DB=yes`, causing the Koha startup path to reuse the existing populated schema.

## Phase C: Observe startup

Follow logs:

```bash
./stack.sh logs
```

Look for:
- existing DB reuse path active,
- `do_all_you_can_do.pl` completes,
- ready banner appears.

---

## Post-Migration Validation Checklist

## A. Access and login

1. OPAC page reachable.
2. Staff interface reachable.
3. Superlibrarian/staff login works.

## B. Core function sanity

1. Search returns expected records.
2. Patron lookup works.
3. Circulation action (test checkout/checkin) works in test environment.

## C. Background processing

1. Worker services start without fatal loops.
2. RabbitMQ STOMP reachability warnings are absent or understood.

## D. Schema/version sanity

1. No repeated schema-upgrade crash loops in logs.
2. No immediate startup exit after `do_all_you_can_do.pl`.

## E. Search backend sanity (if enabled)

1. OpenSearch cluster healthy.
2. No persistent ES auth errors.
3. If search issues appear, trigger a controlled index rebuild.

---

## Optional: Controlled Rebuild of Search Indexes

If Koha is up but search is inconsistent after upgrade:

```bash
docker exec -it koha-docker-koha-1 bash -lc "koha-shell ${KOHA_INSTANCE} -p -c 'perl /kohadevbox/koha/misc/search_tools/rebuild_elasticsearch.pl'"
```

Use only after confirming DB migration itself is healthy.

---

## Rollback Runbook (Fast Path)

Use this if validation fails and you must return to pre-upgrade state quickly.

1. Stop current services:

```bash
./stack.sh stop
```

2. Restore from the backup created before migration:

```bash
./stack.sh restore backups/<your-pre-upgrade-backup>.tar.gz
```

3. Confirm restored stack health:

```bash
./stack.sh status
./stack.sh logs
```

Rollback result:
- env files restored,
- DB restored,
- stack brought up with existing data path.

---

## Rollback Decision Triggers (Use Immediately)

Rollback is recommended if any of the following persist after one focused fix attempt:

1. Koha container repeatedly exits during startup.
2. Schema/upgrade step fails and blocks service readiness.
3. Authentication failures prevent operational use.
4. Critical staff operations unavailable.

---

## Anti-Patterns (Do Not Do During Migration)

1. Running `./stack.sh start` without `--no-fresh-db` on a populated environment.
2. Running `./stack.sh reset` unless you intentionally want full data loss.
3. Changing `KOHA_INSTANCE` mid-upgrade without a separate data migration plan.
4. Rotating DB root password without coordinated volume/password handling.

---

## Special Notes for Ubuntu -> Alpine Image Migration

Data-preservation steps remain identical:

1. Backup.
2. Build new image.
3. Start with `--no-fresh-db`.
4. Validate.
5. Roll back via restore if needed.

What changes in Alpine migration is runtime compatibility of helper/tooling, not the core migration payload.

---

## Change Record Template (Fill During Execution)

- Date/UTC:
- Operator:
- Source version/image:
- Target version/image:
- Backup archive path:
- Start time:
- End time:
- Validation result: pass/fail
- Rollback performed: yes/no
- Notes:
