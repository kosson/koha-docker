<!-- markdownlint-disable MD032 MD029 -->

# Koha Container Version Migration Report (Based on run.sh Analysis)

## Scope

This report answers two questions:

1. What `files/run.sh` does in detail during container startup.
2. What must be preserved to migrate a running Koha container to a newer container version (including Ubuntu -> Alpine image transitions).

Repository analyzed:
- `koha-docker/files/run.sh`
- `koha-docker/stack.sh`
- `koha-docker/docker-compose.yml`
- `koha-docker/OpenSearch-3.6/docker-compose.yml`

---

## 1) Detailed run.sh Startup Flow

`run.sh` is the Koha container entrypoint and runs with `set -e` (fail-fast). It is baked into the image at build time.

### 1.1 Environment and URL bootstrap

- Builds Koha FQDNs from instance/domain prefixes/suffixes.
- Computes `KOHA_OPAC_URL` and `KOHA_INTRANET_URL` from `KOHA_PUBLIC_PORT`.
- Defaults message broker connection values.
- Extends `PATH` and `NODE_PATH` for local tooling.

Operational impact:
- URL values written here become the base URLs used by Koha setup scripts.
- Wrong `KOHA_PUBLIC_PORT` can store wrong external URLs in Koha configuration.

### 1.2 Optional runtime package/library installs

Conditional sections:
- `CPAN=yes`: installs CPAN tooling and updates Perl deps.
- `INSTALL_MISSING_FROM_CPANFILE=yes`: installs missing dependencies from `cpanfile`.
- `EXTRA_APT` and `EXTRA_CPAN`: installs extra OS/Perl dependencies.
- `CI_RUN=yes`: removes developer-oriented Debian packages.

Operational impact:
- These branches mutate runtime tooling but are not data-bearing migration state.

### 1.3 Repository preparation and Debian-file sync

- Validates `SYNC_REPO` by checking `koha/about.pl` exists.
- Optionally clones debug repos (`misc4dev`, `qa-test-tools`).
- Executes `misc4dev/cp_debian_files.pl` to stage instance/debian templates.

Operational impact:
- This prepares startup scripts/templates for instance creation and upgrade.

### 1.4 Database connectivity and credentials materialization

- Waits for MariaDB TCP readiness on `db:3306`.
- Defines:
  - `DB_NAME=koha_${KOHA_INSTANCE}`
  - `DB_USER=koha_${KOHA_INSTANCE}`
  - `DB_PASSWORD=${KOHA_DB_PASSWORD}`
- Writes:
  - `/etc/koha/passwd`
  - `/etc/mysql/koha-common.cnf` (root access)
  - `/etc/mysql/koha_${KOHA_INSTANCE}.cnf` (instance user)

Operational impact:
- This is the core DB contract. Migration must preserve data and matching credentials.

### 1.5 Config templating and system-level setup

- Builds `VARS_TO_SUB` from `templates/defaults.env` and extra variables.
- Runs `envsubst` into multiple target configs (shell rc, Koha XML template, site conf, sudoers, helper scripts).
- Ensures Apache listen ports and host entries.
- Runs distro-specific fixups (`trixie` SSL-off for MySQL client behavior).

Operational impact:
- Most outputs are recreated at each container start and are not durable migration payload.

### 1.6 koha-create (instance creation/upgrade path bootstrap)

- Runs `koha-create --request-db ${KOHA_INSTANCE}` with memcached and message-broker options.
- Creates/chowns per-instance shell/vim config.

Operational impact:
- This is a major lifecycle step for creating/maintaining instance wiring.

### 1.7 Developer ergonomics and source control setup

- Optional l10n clone/fetch/checkout.
- Git config for instance user and hook setup.
- `koha-gitify` execution.

Operational impact:
- Important for dev workflow, not usually critical production migration state.

### 1.8 Assets and runtime prep

- Enables site (`koha-enable`, `a2ensite`).
- Runs `yarn install` in mounted workspace.
- Writes user shell aliases and hosts entries.

Operational impact:
- Reproducible setup from source; generally not data migration payload.

### 1.9 Existing DB detection (critical for migration)

- If `USE_EXISTING_DB` is not preset to `yes`, probes `information_schema.tables` using root credentials.
- If `systempreferences` exists, it auto-sets `USE_EXISTING_DB=yes`.
- Translates that into `USE_EXISTING_DB_FLAG=--use-existing-db`.

Operational impact:
- This is the key mechanism that allows reusing an existing populated Koha DB across container recreations/upgrades.

### 1.10 Demo-data control

- `LOAD_DEMO_DATA=no` rewrites `misc4dev/insert_data.pl` to a no-op.

Operational impact:
- Avoids reseeding sample records when migrating real data.

### 1.11 OpenSearch readiness and non-fatal ES rebuild behavior

When `KOHA_ELASTICSEARCH=yes`:
- Waits for OpenSearch health (`yellow`/`green`) with retries.
- Applies runtime patches to `misc4dev/do_all_you_can_do.pl`:
  - skips zebra rebuild in ES mode,
  - makes ES rebuild non-fatal (`; true`),
  - captures rebuild stderr to `/tmp/rebuild_elasticsearch.stderr`.

Operational impact:
- Search index failures should not block container startup.
- Search may be degraded after migration until rebuild is corrected.

### 1.12 Main installer execution

Runs:
- `perl misc4dev/do_all_you_can_do.pl`
  - with `--use-existing-db` when appropriate,
  - with user/password/marc flavour/base URLs,
  - with optional `--elasticsearch`.

Operational impact:
- This is the central installation/upgrade orchestration call.

### 1.13 Service startup and steady state

- Stops and restarts Apache.
- Normalizes CRLF for CGI/PL scripts.
- Optional plugin registration.
- Enables plack and z3950 responder (best effort).
- Waits for RabbitMQ STOMP endpoint.
- Starts `koha-common` and Apache.
- Writes `/ktd_ready` and keeps container alive with `sleep infinity`.

Operational impact:
- Runtime service state is ephemeral; durable data lives outside the container filesystem.

---

## 2) What Must Be Preserved for Container-Version Migration

## Mandatory (must preserve)

1. MariaDB data for `koha_${KOHA_INSTANCE}`.
2. The DB credential contract:
   - `KOHA_DB_ROOT_PASSWORD`
   - `KOHA_DB_PASSWORD`
   - `KOHA_INSTANCE` (because it defines DB/schema/user names).
3. Core environment configuration files:
   - `env/.env`
   - `traefik/.env`
   - `OpenSearch-3.6/.env`
4. Koha version/source mapping used by the new image:
   - `KOHA_GIT_CLONE_MODE`, `KOHA_GIT_TAG` or `KOHA_GIT_BRANCH`, `SYNC_REPO`.

Reason:
- `run.sh` can recreate most runtime files, but cannot recreate business/library data without the DB dump/volume.

## Strongly recommended (preserve unless intentionally resetting)

1. RabbitMQ data volume (`koha-rabbitmq-data`) if queued messages/state matter in your workflow.
2. OpenSearch data directories under `OpenSearch-3.6/assets/opensearch/data/` if you want to preserve existing indexes and avoid full rebuild.

Note:
- OpenSearch indexes are rebuildable from Koha data, so they are usually recoverable if lost.

## Usually not required to preserve

1. Container internal generated files under `/etc/koha`, `/var/run/koha`, `/var/cache/koha`.
2. Package caches and temporary files.
3. Runtime logs (unless needed for audit/debug).

They are regenerated on startup by `run.sh` and Koha helper commands.

---

## 3) Migration Procedure: Running Old Container -> Newer Container

This is the safest path for same-host migration and also applies to Ubuntu-image -> Alpine-image replacement.

### Step 0: Preconditions

- Confirm old stack is healthy.
- Ensure database root password in `env/.env` matches the existing DB volume.

### Step 1: Create a portable backup bundle (recommended baseline)

Run from `koha-docker/`:
- `./stack.sh backup`

This captures:
- `env/.env`
- `traefik/.env`
- `OpenSearch-3.6/.env`
- gzipped MariaDB dump of `koha_${KOHA_INSTANCE}`

### Step 2: Switch target Koha version/image

Update one of:
- `KOHA_GIT_TAG` or `KOHA_GIT_BRANCH` (source-level upgrade), and/or
- `KOHA_IMAGE_TAG` / Dockerfile changes for new base image (for example Alpine migration).

### Step 3: Build the new Koha container

- `./stack.sh build --build-koha`

### Step 4: Start with existing DB (do not wipe)

- `./stack.sh start --no-fresh-db`

Why:
- `stack.sh` exports `USE_EXISTING_DB=yes`, and `run.sh` passes `--use-existing-db`, preventing the fresh-install path.

### Step 5: Observe startup logs and verify upgrade path

- `./stack.sh logs`

Look for:
- DB-detect reuse behavior (or explicit existing-db flag usage).
- `do_all_you_can_do.pl` completion.
- readiness banner: "koha-testing-docker has started up and is ready to be enjoyed!"

### Step 6: Validate application and background services

- OPAC and staff endpoints open.
- Login succeeds.
- Background jobs execute (RabbitMQ + workers).
- Search works; if search is incomplete, run explicit ES rebuild.

---

## 4) Migration Failure Modes to Avoid

1. Starting without `--no-fresh-db`:
- `stack.sh start` default path drops/recreates DB.
- This destroys existing Koha data.

2. Password drift in DB root credential:
- If `KOHA_DB_ROOT_PASSWORD` changed but existing `koha-db-data` volume was initialized with another password, DB operations fail.

3. Treating search index errors as data loss:
- Search index may fail while Koha DB remains valid.
- Rebuild index after boot if needed.

4. Assuming all state is in DB:
- If your deployment stores custom artifacts outside DB on container-local paths, add explicit volumes or external backup for those paths before migration.

---

## 5) Minimal Save Set (Short Answer)

For migration from one running Koha container version to another newer one, save at minimum:

1. MariaDB Koha schema/data (`koha_${KOHA_INSTANCE}`).
2. `env/.env` (especially instance name and DB credentials).
3. `traefik/.env` and `OpenSearch-3.6/.env` (network/TLS/auth consistency).

Then rebuild the new image and start with:
- `./stack.sh start --no-fresh-db`

This reuses existing data and lets `run.sh` execute upgrade-safe startup via `--use-existing-db`.

---

## 6) Alpine-Specific Note

If the new target image is Alpine-based, the migration payload above does not change. The critical difference is compatibility of lifecycle tooling (`koha-create`, service wrappers, Apache integration). Data preservation requirements remain centered on DB + environment contract.
