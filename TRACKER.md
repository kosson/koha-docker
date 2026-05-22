# Koha Docker — Change Tracker

## 2026-05-22 — Fix MARC import commit failure (missing branch FK constraint)

### Problem

After a MARC file was successfully staged (`stage_marc_for_import` job finished), the follow-up `marc_import_commit_batch` job consistently failed with:

```
DBIx::Class::Storage::DBI::_dbh_execute(): DBI Exception: DBD::mysql::st execute failed:
Cannot add or update a child row: a foreign key constraint fails
(`koha_kohadev`.`items`, CONSTRAINT `items_ibfk_2`
FOREIGN KEY (`homebranch`) REFERENCES `branches` (`branchcode`) ON UPDATE CASCADE)
at /kohadevbox/koha/Koha/Object.pm line 174
Broken FK constraint at /kohadevbox/koha/Koha/BackgroundJob/MARCImportCommitBatch.pm line 93.
```

**Root cause:** The imported MARC file (`CLINCIUAna-Maria.catalog.bib.acasa.mrc.mrc`) contained item records with MARC field `952$a` (homebranch) set to `MAIN`. The Koha database only contained the 12 default demo branches (CPL, FFL, FPL, etc.) loaded by `misc4dev/insert_data.pl` — `MAIN` was not among them.

The `import_items` table staged the items successfully (with `branchcode = NULL` in its own column — the actual branch code is embedded in the `marcxml` column). When the commit job tried to insert into the live `items` table, MariaDB rejected the insert because `homebranch = 'MAIN'` has no matching row in `branches`.

**Confirmed via:**
- `worker-output.log` showed the FK constraint error at `MARCImportCommitBatch.pm line 93`
- `SELECT marcxml FROM import_items LIMIT 1` showed `<subfield code="a">MAIN</subfield>` inside the `952` datafield
- `SELECT branchcode FROM branches` confirmed no `MAIN` branch existed

### Fix

Created the missing branch directly in the `branches` table:

```sql
INSERT INTO branches (branchcode, branchname, pickup_location, public)
VALUES ('MAIN', 'Main Library', 1, 1);
```

The import batch (`import_batch_id = 1`) remained in `staged` status with all 10 records intact — no re-staging needed. The commit can be retried from **Tools → Staged MARC Management → Import this batch**.

### Notes for production / real libraries

- Before importing MARC files from an external system, verify that all branch codes referenced in item fields (`952$a` homebranch, `952$b` holdingbranch) exist in **Administration → Libraries**.
- If the demo branches (CPL, FFL, etc.) are not needed, delete them via the Koha admin UI after the import succeeds.
- Alternatively, import without items by setting `item_action = ignore` on the staging form — this bypasses the FK constraint entirely.

---

## 2026-05-22 — OPAC item detail crash after MARC import (NULL holdingbranch / itype)

### Problem

After a successful MARC import commit, opening an imported title in the OPAC produced:

```
DBIC result _type  isn't of the _type Branch
at /kohadevbox/koha/opac/opac-detail.pl line 715.
at /usr/lib/x86_64-linux-gnu/perl-base/Carp.pm line 289
```

**Root cause (same MARC data gap):** The imported MARC file contained item records with only `952$a` (homebranch = `MAIN`). The subfields `952$b` (holdingbranch) and `952$y` (item type) were absent. Koha stored those columns as `NULL` in the `items` table.

`opac-detail.pl` iterates over every item and calls:
```perl
$item->holding_library->opac_info(...)   # line ~715
```
`Koha::Item->holding_library` does:
```perl
my $hb_rs = $self->_result->holdingbranch;   # DBIx::Class relationship accessor
return Koha::Library->_new_from_dbic($hb_rs);
```
When `holdingbranch IS NULL`, the DBIx::Class relationship returns `undef`. `Koha::Object->new()` then checks `ref(undef) eq "Koha::Schema::Result::Branch"` → `"" ne "Branch"` → croaks. This is the double-space in the error message: `_type  isn't` — `ref(undef)` is the empty string.

**Confirmed via:**
```sql
SELECT itemnumber, homebranch, holdingbranch, itype
FROM items ORDER BY itemnumber DESC LIMIT 10;
-- Result: homebranch=MAIN, holdingbranch=NULL, itype=NULL for all 10 imported items
```

### Fix applied

```sql
UPDATE items
SET   holdingbranch = homebranch,
      itype         = COALESCE(itype, 'BK')
WHERE holdingbranch IS NULL
  AND homebranch IS NOT NULL;
-- 10 rows updated
```

Memcached flushed afterwards (`echo flush_all | nc -w1 memcached 11211`).

---

### MARC item field requirements for successful Koha imports (MARC21 field 952)

When exporting MARC records from any ILS for import into Koha, **every item record must include at minimum** the following `952` subfields. Missing subfields are stored as `NULL` and will cause crashes or silent data problems.

| Subfield | Koha `items` column | Required | Notes |
|---|---|---|---|
| `952$a` | `homebranch` | **YES** | Branch code of the owning library. Must exist in `branches.branchcode` before import. FK constraint — import fails if absent. |
| `952$b` | `holdingbranch` | **YES** | Branch currently holding the item. Should equal `$a` when unknown. **NULL causes OPAC crash** (`Koha::Library->_new_from_dbic(undef)`). |
| `952$y` | `itype` | **YES** | Item type code (e.g. `BK`, `MU`, `VM`). Must exist in `itemtypes.itemtype`. NULL suppresses circulation rules and may cause display errors. |
| `952$p` | `barcode` | Recommended | Unique barcode. NULL is allowed but items without barcodes cannot be checked out. |
| `952$c` | `location` | Optional | Shelving location authorised value (e.g. `GEN`, `REF`). NULL is safe. |
| `952$o` | `itemcallnumber` | Optional | Call number string. NULL is safe. |
| `952$g` | `price` | Optional | Purchase price decimal. NULL is safe. |
| `952$d` | `dateaccessioned` | Optional | Acquisition date (YYYY-MM-DD). NULL defaults to no date. |

**Pre-import checklist:**

1. **Branches** — run `SELECT branchcode FROM branches` and confirm every `952$a`/`952$b` value in your MARC file is present. Add missing branches via **Administration → Libraries** or:
   ```sql
   INSERT INTO branches (branchcode, branchname, pickup_location, public)
   VALUES ('CODE', 'Branch Name', 1, 1);
   ```
2. **Item types** — run `SELECT itemtype FROM itemtypes` and confirm every `952$y` value is present. Add missing types via **Administration → Item types**.
3. **Authorised values** — if `952$c` (location) or `952$8` (collection code) are used, verify values exist in **Administration → Authorised values** under categories `LOC` and `CCODE`.
4. **Barcode uniqueness** — if barcodes are present, confirm none already exist in `items.barcode`:
   ```sql
   SELECT barcode FROM items WHERE barcode IN (...);
   ```

**If you cannot fix the export source**, use a **MARC modification template** (Tools → MARC modification templates) to map or default these fields during staging before committing.

---

## 2026-05-22 — Fix background job worker startup race condition (MARC import)

### Problem

Every batch background process (e.g. "Stage MARC for import", "Import staged MARC records") would behave unreliably because the background job workers started before RabbitMQ was ready to accept STOMP connections.

**Root cause:** In `files/run.sh` the startup order was:
1. `service koha-common start` — starts background job workers (which try to connect to STOMP on port 61613 exactly **once** at startup)
2. `service apache2 start`
3. `service rabbitmq-server start` — RabbitMQ (STOMP broker) starts **after** workers

Because workers attempt the STOMP connection only once, they always failed and fell back to polling `background_jobs` DB table every 10 seconds. While the DB-polling fallback does work (jobs are still processed), it means workers never benefit from instant Stomp notifications. More importantly, in some scenarios where the `JobsNotificationMethod` system preference is set to `STOMP`, the enqueue process sends a Stomp notification which is delivered to a RabbitMQ queue that nobody is subscribed to (workers are in poll mode), effectively losing the "push" trigger.

**Confirmed via:** `worker-output.log` showed repeated `Cannot connect to broker (Error connecting to localhost:61613: Connection refused)` on every container start.

### Fix

**File changed:** `files/run.sh`

Moved `service rabbitmq-server start` to run **before** `service koha-common start`, and added a 30-second wait loop for the STOMP port (61613) to become available before starting workers. If RabbitMQ does not come up within 30 seconds, workers still start but fall back to DB polling with a clear warning in the log.

```
Before:
  service koha-common start   ← workers start, STOMP fails, fallback to DB poll
  service apache2 start
  service rabbitmq-server start ← too late

After:
  service rabbitmq-server start ← broker starts first
  wait for port 61613 (up to 30 s)
  service koha-common start     ← workers start and connect to STOMP successfully
  service apache2 start
```

### How to apply

This change is in `files/run.sh`, which is **baked into the image at build time**. You must rebuild and restart the stack:

```bash
./stack.sh start -b
```

---

## 2026-04-22 — Inline Noble packages, remove install-packages script

### Goal

Simplify `koha-docker` for a single target platform (Ubuntu 24.04 Noble) by eliminating the dynamic `install-packages` Perl script and its YAML configuration in favour of plain
`apt-get install` statements directly in the Dockerfile.

---

### Context

The original Dockerfile was assembled from two sources:

1. A first `FROM ubuntu:24.04` block (maintainer: kosson) that called `install-packages all`
   — a Perl script that read `package-config.yaml`, resolved distro-specific overrides at runtime, and then ran `apt-get install`.
2. A second `FROM ubuntu:24.04` block (copied from `koha-testing-docker` as reference, maintainer: tomascohen) that called `install-packages <group>` once per package group.

Because Docker only executes the **last** `FROM` stage, the first block was silently ignored. Both blocks still depended on the scripting layer.
The `package-config.yaml` defines a `distro_specific.noble` section with Cypress overrides for Ubuntu 24.04:

```yaml
distro_specific:
  noble:
    cypress-overrides:
      libgtk2.0-0:  libgtk2.0-0t64
      libgtk-3-0:   libgtk-3-0t64
      libasound2:   libasound2t64
      libgconf-2-4: null          # remove — not available on Noble
```

Since the target is fixed to Noble, these overrides are known at authoring time and do not require a runtime resolver.

---

### Changes made to `Dockerfile`

#### 1. Merged into a single `FROM` stage

The two `FROM ubuntu:24.04` blocks were collapsed into one clean stage with the project maintainer label (`kosson@gmail.com`).

#### 2. Removed the scripting layer

The following lines were deleted:

```dockerfile
COPY files/install-packages /usr/local/bin/
COPY files/package-config.yaml /usr/local/bin/
RUN  chmod +x /usr/local/bin/install-packages

RUN apt-get update \
    && apt-get -y install \
        lsb-release \
        libmodern-perl-perl \
        libyaml-libyaml-perl \
    ...
```

`lsb-release`, `libmodern-perl-perl`, and `libyaml-libyaml-perl` were only needed as runtime dependencies of the Perl script. With the script gone they are not installed.

#### 3. Replaced `install-packages` calls with direct `apt-get install`

| Removed call | Replacement |
|---|---|
| `install-packages all` | Inlined `apt-get install` for every group |
| `install-packages base` | Inlined `apt-get install` for base packages |
| `install-packages koha-dev` | Inlined `apt-get install` for koha-dev packages |
| `install-packages nodejs` | `apt-get install nodejs yarn` (after repo setup) |
| `install-packages utility` | `apt-get install bugz inotify-tools` |
| `install-packages cypress` | Inlined `apt-get install` with Noble-specific names (see below) |
| `install-packages temp` | Removed — `temp: []` in the YAML (no-op) |
| `install-packages cpan` | Removed — no `cpan` key in the YAML (no-op) |

#### 4. Applied Noble distro overrides directly in the Cypress install step

| Original package | Noble replacement | Reason |
|---|---|---|
| `libgtk2.0-0` | `libgtk2.0-0t64` | Renamed in Ubuntu 24.04 |
| `libgtk-3-0` | `libgtk-3-0t64` | Renamed in Ubuntu 24.04 |
| `libasound2` | `libasound2t64` | Renamed in Ubuntu 24.04 |
| `libgconf-2-4` | *(not installed)* | Not available on Noble (`null` override) |

#### 5. Fixed yarn repository setup

The original had two conflicting `echo` statements writing to `yarn.list` — an unsigned entry first, then the signed one overwriting it. Reduced to a single signed `echo`.

#### 6. Removed `COPY` for files not yet present in `koha-docker/`

The reference block copied files that exist in `koha-testing-docker` but not here:

```dockerfile
COPY files/run.sh          /kohadevbox          # does not exist yet
COPY files/templates       /kohadevbox/templates # does not exist yet
COPY env/defaults.env      /kohadevbox/templates/defaults.env  # does not exist yet
COPY files/git_hooks       /kohadevbox/git_hooks # does not exist yet
```

These were removed. A placeholder `CMD ["/bin/bash"]` was added so the image is runnable; it should be replaced with a proper entrypoint once those files are created.

#### 7. Removed redundant `apt-cache policy` debug lines

The `koha-common` install step contained several `apt-cache policy` calls leftover from the reference Dockerfile. They produce output but have no side effect; removed for clarity.

---

### Files changed

| File | Change |
|---|---|
| `Dockerfile` | Rewritten — see above |

### Files unchanged (still present, no longer used at build time)

| File | Status |
|---|---|
| `files/install-packages` | Kept — can be removed when no longer needed for reference |
| `files/package-config.yaml` | Kept — documents the package intent; useful reference |

---

## 2026-04-22 — Copy runtime resources from koha-testing-docker

### Goal

Provide all files that `run.sh` references at container startup but that did not yet exist in `koha-docker/`.

### Files added

| File | Source | Purpose |
|---|---|---|
| `files/templates/apache2_envvars` | `koha-testing-docker` | Apache run-user/group config, substituted by `envsubst` |
| `files/templates/bash_aliases` | `koha-testing-docker` | Shell aliases for root and instance user |
| `files/templates/bin/dbic` | `koha-testing-docker` | DBIx::Class schema regeneration helper |
| `files/templates/bin/flush_memcached` | `koha-testing-docker` | Memcached flush helper |
| `files/templates/bin/bisect_with_test` | `koha-testing-docker` | Git bisect helper |
| `files/templates/gitconfig` | `koha-testing-docker` | Git aliases for the instance user |
| `files/templates/instance_bashrc` | `koha-testing-docker` | `.bashrc` for the `kohadev-koha` instance user |
| `files/templates/koha-conf-site.xml.in` | `koha-testing-docker` | Koha Zebra/config XML template |
| `files/templates/koha-sites.conf` | `koha-testing-docker` | `koha-create` site variables |
| `files/templates/root_bashrc` | `koha-testing-docker` | `.bashrc` for the root user |
| `files/templates/sudoers` | `koha-testing-docker` | Passwordless sudo for the instance user |
| `files/templates/vimrc` | `koha-testing-docker` | Vim configuration |
| `files/git_hooks/pre-commit` | `koha-testing-docker` | Perl syntax + CSS check before commit |
| `files/git_hooks/post-checkout` | `koha-testing-docker` | Sets `blame.ignoreRevsFile` after checkout |
| `env/defaults.env` | `koha-testing-docker` | Variable-name manifest for `envsubst` (see note below) |

### Dockerfile updated

Restored the `COPY` statements and the proper `CMD` entrypoint that had been left as a placeholder in the previous step:

```dockerfile
COPY files/run.sh          /kohadevbox/
COPY files/templates       /kohadevbox/templates
COPY files/git_hooks       /kohadevbox/git_hooks
COPY env/defaults.env      /kohadevbox/templates/defaults.env
CMD  ["/bin/bash", "/kohadevbox/run.sh"]
```

---

## 2026-04-22 — Clarification: role of `defaults.env` vs `env/.env`

These two files look similar but serve completely different purposes and **both must be kept**.

| File | Where it is read | By whom | Purpose |
|---|---|---|---|
| `env/.env` | On the **host**, before container starts | Docker Compose (`env_file:`) | Injects runtime values as container environment variables |
| `env/defaults.env` | **Inside the container** at startup | `run.sh` line 140 | Provides the list of variable *names* to pass to `envsubst` |

The critical line in `run.sh` is:

```bash
VARS_TO_SUB=`cut -d '=' -f1 ${BUILD_DIR}/templates/defaults.env | tr '\n' ':' | ...`
```

It reads only the **left-hand side** of each `VAR=value` entry in `defaults.env` to build the `$VAR1:$VAR2:...` string that `envsubst` uses to know which placeholders to expand in the template files (`koha-conf-site.xml.in`, `koha-sites.conf`, `apache2_envvars`, etc.).
Without `defaults.env` inside the container, `envsubst` would receive no variable list and all `${VAR}` placeholders in the generated config files would remain unexpanded.

---

## 2026-04-29 — OpenSearch integration with external cluster

### Goal

Connect the `koha-docker` Koha instance to the external 5-node OpenSearch 3.6 cluster that runs in a separate Docker Compose project (`cluster-opensearch/OpenSearch-3.6/`).

---

### Architecture overview

```
┌─────────────────────────────────┐       ┌──────────────────────────────────────────┐
│  koha-docker/                   │       │  cluster-opensearch/OpenSearch-3.6/      │
│                                 │       │                                          │
│  ┌─────────┐  ┌──────────────┐  │       │  ┌──────┐  ┌──────┐  ┌──────┐            │
│  │  koha   │  │  db          │  │       │  │ os01 │  │ os02 │  │ os03 │ ...        │
│  │container│  │  (MariaDB)   │  │       │  │(mgr) │  │(data)│  │(data)│            │
│  └────┬────┘  └──────────────┘  │       │  └──┬───┘  └──────┘  └──────┘            │
│       │     kohanet             │       │     │         osearch (internal)         │
│       │     (internal)          │       │     │knonikl (external bridge)           │
└───────┼─────────────────────────┘       └─────┼────────────────────────────────────┘
        │                                       │
        └───────────── knonikl ─────────────────┘
                   (shared Docker network)
```

- `os01` is the cluster manager node. It is the only OpenSearch node attached to both `osearch` (cluster-internal) and `knonikl` (shared external bridge).
- `dashboards` is also on `knonikl` (port 5601).
- `os02`–`os05` are data/ingest/search nodes on `osearch` only.
- Koha connects exclusively to `os01:9200` (HTTPS).

**Traefik** (`koha-docker/traefik/`) runs on the `frontend` Docker network and acts as a reverse proxy for web-facing services. It is not involved in the Koha→OpenSearch backend connection, which goes directly over `knonikl`.

---

### How Koha uses OpenSearch

1. `run.sh` checks: `if [ "${KOHA_ELASTICSEARCH}" = "yes" ]; then ES_FLAG="--elasticsearch"; fi`
2. `do_all_you_can_do.pl --elasticsearch` configures Koha's database to set the search engine to Elasticsearch/OpenSearch and triggers index creation.
3. The actual server URL comes from `koha-conf.xml`, which is generated at container startup via `envsubst` from the template `files/templates/koha-conf-site.xml.in`:

```xml
<elasticsearch>
    <server>${ELASTIC_SERVER}</server>
    <index_name>koha___KOHASITE__</index_name>
    ${ELASTIC_OPTIONS}
</elasticsearch>
```

4. `${ELASTIC_SERVER}` and `${ELASTIC_OPTIONS}` are substituted from the environment. `ELASTIC_SERVER` defaults to `es:9200` (the internal test container). For the external cluster it must point to `os01`.

---

### TLS / authentication

The OpenSearch 3.6 cluster runs with the Security plugin **enabled** and TLS on port 9200. Certificates are self-signed with a project-local CA (`assets/ssl/root-ca.pem`).

Connection credential: `admin` / value of `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in the cluster's `.env`.

For the Koha container to authenticate, the admin credentials are embedded directly in the `ELASTIC_SERVER` URL using standard HTTP Basic Auth URI syntax. Special characters in the password must be percent-encoded:

| Character | Encoded |
|-----------|---------|
| `@`       | `%40`   |
| `#`       | `%23`   |

Example: `ELASTIC_SERVER=https://admin:test%40Cici24%23ANA@os01:9200`

**SSL verification**: Koha's Perl HTTP client (`LWP::UserAgent`) validates TLS certificates by default. Two options are provided:

| Approach | How |
|----------|-----|
| **Dev: bypass verification** | Set `PERL_LWP_SSL_VERIFY_HOSTNAME=0` in the container environment (already wired in `docker-compose.yml`). |
| **Prod: proper CA trust** | Set `OPENSEARCH_CA_CERT` on the host (full path to `root-ca.pem`). The compose file mounts it into `/kohadevbox/opensearch-root-ca.pem`. Then set `PERL_LWP_SSL_CA_FILE=/kohadevbox/opensearch-root-ca.pem` instead of disabling verification. |

The default config in `env/.env` uses the bypass approach (`PERL_LWP_SSL_VERIFY_HOSTNAME=0`)
which is appropriate for local development.

---

### Docker network

The `knonikl` network is defined in the OpenSearch cluster's `docker-compose.yml`. Without an explicit `name:` it would be prefixed with the Docker Compose project name (e.g., `opensearch-36_knonikl`), making it impossible to reference predictably from another project.

**Fix applied to `cluster-opensearch/OpenSearch-3.6/docker-compose.yml`:**

```yaml
networks:
  osearch:
  knonikl:
    name: knonikl     # ← added: pins the Docker network name regardless of project prefix
```

After this change, `docker network ls | grep knonikl` will always show the network as `knonikl`. The OpenSearch cluster must be started **before** `koha-docker` so the network
exists when Koha's compose attempts to join it.

---

### Changes made

#### `cluster-opensearch/OpenSearch-3.6/docker-compose.yml`

Added `name: knonikl` to the `knonikl` network definition so it has a stable, project-independent name that other compose projects can reference with `external: true`.

#### `koha-docker/docker-compose.yml`

1. **Added `knonikl` as an external network** at the bottom of the `networks:` block:

```yaml
   knonikl:
       external: true
```

2. **Added `knonikl: {}` to the koha service networks** so the container joins the shared OpenSearch bridge at startup.
3. **Mounted the OpenSearch root CA** (optional, for proper TLS verification):

```yaml
   - ${OPENSEARCH_CA_CERT:-/dev/null}:/kohadevbox/opensearch-root-ca.pem:ro
```

When `OPENSEARCH_CA_CERT` is unset, `/dev/null` is mounted harmlessly.

4. **Exposed new environment variables** to the koha container:

```yaml
   ELASTIC_SERVER: ${ELASTIC_SERVER:-es:9200}
   ELASTIC_OPTIONS: ${ELASTIC_OPTIONS:-}
   OPENSEARCH_INITIAL_ADMIN_PASSWORD: ${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}
   PERL_LWP_SSL_VERIFY_HOSTNAME: ${PERL_LWP_SSL_VERIFY_HOSTNAME:-1}
```

#### `koha-docker/env/.env`

| Variable | Old value | New value |
|----------|-----------|-----------|
| `KOHA_ELASTICSEARCH` | ` ` (empty) | `yes` |
| `ELASTIC_SERVER` | `es:9200` | `https://admin:test%40Cici24%23ANA@os01:9200` |
| `PERL_LWP_SSL_VERIFY_HOSTNAME` | (absent) | `0` |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | `pu1kohphei4heeY4pai7ohp6vei4Ea6i` | `"test@Cici24#ANA"` |

`OPENSEARCH_CA_CERT` is documented as a comment for when proper cert verification is needed.

---

### Startup order

```
1. docker network create frontend       # only if not already present
2. cd koha-docker/traefik && docker compose up -d
3. cd cluster-opensearch/OpenSearch-3.6 && docker compose up -d
4. # Wait for cluster health: curl -k -u admin:'test@Cici24#ANA' https://localhost:9200/_cluster/health
5. cd koha-docker && docker compose up -d
```

Koha's `run.sh` calls `do_all_you_can_do.pl --elasticsearch` which creates the OpenSearch indexes (`koha_kohadev_biblios`, `koha_kohadev_authorities`, `koha_kohadev_items`) on first startup. Subsequent starts skip index creation if indexes already exist.

---

### Known limitations / future work

- The admin account is used for all Koha→OpenSearch operations. A dedicated `koha` service account with restricted permissions should be created for production use.
- `PERL_LWP_SSL_VERIFY_HOSTNAME=0` disables TLS verification globally for the Perl process. For production, mount the root CA and use `PERL_LWP_SSL_CA_FILE` instead.
- If the OpenSearch cluster is restarted and indexes are recreated, Koha's mappings must be reset via Koha admin → Search engine configuration → Reset mappings.

---

## 2026-05-02 — Runtime error analysis and UID 1000 fix

### Errors observed in `docker compose up` logs

```
koha-1  | Error: worker not running for kohadev (default)
koha-1  | Error: worker not running for kohadev (long_tasks)
koha-1  |    ...fail!
koha-1  |  * Restarting Apache httpd web server apache2
koha-1  |    ...done.
koha-1  | fatal: could not create work tree dir '/kohadevbox/koha/misc/translator/po': Permission denied
koha-1  | error: could not lock config file .git/config: Permission denied
koha-1  | error: could not lock config file .git/config: Permission denied
koha-1  | mkdir: cannot create directory '/kohadevbox/koha/.git/hooks/ktd': Permission denied
koha-1  | cp: target '/kohadevbox/koha/.git/hooks/ktd': No such file or directory
koha-1  | error: could not lock config file .git/config: Permission denied
koha-1 exited with code 255
```

---

### Analysis

#### Error 1 — "worker not running for kohadev" (cosmetic, non-fatal)

**Source**: `koha-create --request-db kohadev` (called in `run.sh`) internally calls `service koha-common restart` after writing config files. At that point, no database
exists yet, so the Koha background worker cannot start.

**Impact**: Informational only. `koha-create` exits with code 0; `run.sh` continues.
The database is populated later by `do_all_you_can_do.pl`.

**Fix**: None required.

#### Error 2 — All `Permission denied` errors on `/kohadevbox/koha/...` (fatal)

**Root cause**: `ubuntu:24.04` ships with a pre-created system user `ubuntu` at **UID 1000** (added to Ubuntu cloud/container images starting with Ubuntu 23.10). This is confirmed by:

```
$ docker run --rm ubuntu:24.04 id ubuntu
uid=1000(ubuntu) gid=1000(ubuntu) groups=1000(ubuntu),4(adm),...
```

When `koha-create` runs inside the container it calls `adduser` to create the instance user `kohadev-koha`. Because UID 1000 is already taken by `ubuntu`, `kohadev-koha` is
assigned **UID 1001**.

`run.sh` contains this guard:

```bash
if [[ ! -z "${LOCAL_USER_ID}" && "${LOCAL_USER_ID}" != "1000" ]]; then
    usermod -o -u ${LOCAL_USER_ID} "${KOHA_INSTANCE}-koha"
fi
```

Since `LOCAL_USER_ID=1000`, the condition `!= "1000"` is **false** and `usermod` is skipped. `kohadev-koha` remains at UID 1001.
The Koha source directory is mounted from the host:

```
${SYNC_REPO}:/kohadevbox/koha
```

The host files are owned by UID 1000 (host user `nicolaie`). Inside the container, `kohadev-koha` (UID 1001) has no write access, causing every operation that `run.sh`
performs as `kohadev-koha` (via `sudo koha-shell`) to fail with Permission denied.

The `set -e` in `run.sh` then causes the container to exit with code 255 when the first `sudo koha-shell` command under this mode fails.

**Affected operations**:

| Operation | Command in `run.sh` |
|---|---|
| Clone koha-l10n into `misc/translator/po` | `sudo koha-shell ${KOHA_INSTANCE} -c "git clone ..."` |
| Write git config locals | `sudo koha-shell ... -c "git config bz.default-tracker ..."` |
| Create `.git/hooks/ktd` directory | `sudo koha-shell ... -c "mkdir -p .git/hooks/ktd"` |
| Copy git hooks | `sudo koha-shell ... -c "cp git_hooks/* .git/hooks/ktd"` |

---

### Fix applied

Added `RUN userdel -r ubuntu` to `Dockerfile` **before the mirror redirect layer**, so UID 1000 is free when `koha-create` creates `kohadev-koha` during container startup:

```dockerfile
# ubuntu:24.04 ships with a pre-created 'ubuntu' user at UID 1000.
# koha-create assigns the next available UID to kohadev-koha, which becomes 1001.
# run.sh only calls usermod when LOCAL_USER_ID != 1000, so the mismatch is never fixed
# and kohadev-koha cannot write to the host-mounted Koha repo (owned by UID 1000).
# Removing the ubuntu user here frees UID 1000 for kohadev-koha.
RUN userdel -r ubuntu 2>/dev/null || true
```

**After this fix**:

- `kohadev-koha` gets UID 1000 (first available UID for a non-system user)
- `LOCAL_USER_ID=1000` → `run.sh` condition `!= "1000"` is false → no usermod needed
- `kohadev-koha` at UID 1000 can read/write the host-mounted Koha repo
- All `sudo koha-shell` operations succeed
- Container no longer exits with code 255

---

### Files changed

| File | Change |
|---|---|
| `Dockerfile` | Added `RUN userdel -r ubuntu 2>/dev/null \|\| true` before mirror-redirect layer |

---


## 2026-05-02 — OpenSearch network routing (koha → os01)

### Symptom

After the UID fix the container initialised successfully and all `sudo koha-shell` steps passed, but `rebuild_elasticsearch.pl` failed at the very end with:

```
[NoNodes] ** No nodes are available: [https://os01:9200]
```

The container then exited with code 0 (the error is non-fatal from `run.sh`'s perspective), but the search indexes were never built, meaning the catalogue would return no results.

---

### Analysis

#### How the OpenSearch cluster is structured

The OpenSearch 3.6 cluster (`koha-docker/OpenSearch-3.6/`) is a separate Docker Compose project. It creates two Docker networks:

| Network | Purpose | Who joins it |
|---|---|---|
| `opensearch-36_osearch` | Internal cluster traffic (port 9200, 9300) | os01, os02, os03, os04, os05 |
| `knonikl` | External bridge (exposed to other projects) | os01, dashboards |

`os01` is the cluster-manager node and it **listens for HTTP/HTTPS on port 9200 only on `172.28.0.3`**, which is its `opensearch-36_osearch` network address. It does **not** bind
to `0.0.0.0`.

#### Why the first approach failed

The koha container was attached to `koha-docker_kohanet` (internal) and `knonikl` (external bridge). The intent was to reach `os01` via `knonikl`.

Two problems:

1. **`os01` was not on `knonikl`**. The `knonikl` network was originally used in an older architecture to connect OpenSearch Dashboards to the Koha proxy. `os01` itself
   only had an IP on `opensearch-36_osearch`.

2. **Even after manually connecting `os01` to `knonikl`**, the connection still failed. When `os01` was added to `knonikl` at runtime (`docker network connect knonikl os01`),
   it got a `172.30.x.x` address on that network, but its OpenSearch process still only listened on `172.28.0.3:9200`. Any TCP SYN sent to `172.30.x.x:9200` went unanswered.

#### Root cause

The koha container needed to be on the **same network as the OpenSearch nodes**, i.e., `opensearch-36_osearch`. From that network, `os01` is reachable at `172.28.0.3:9200`
and its hostname `os01` resolves correctly via Docker's internal DNS.

---

### Fix

Declared `opensearch-36_osearch` as an **external** network in `koha-docker/docker-compose.yml` and attached the `koha` service to it:

```yaml
# koha service — networks section
networks:
  kohanet:
    aliases:
      - "${KOHA_INTRANET_PREFIX}${KOHA_INSTANCE}..."
      - "${KOHA_OPAC_PREFIX}${KOHA_INSTANCE}..."
  knonikl: {}
  opensearch-36_osearch: {}      # ← ADDED

# top-level networks declaration
networks:
  kohanet:
    enable_ipv4: true
    enable_ipv6: false
  knonikl:
    external: true
  opensearch-36_osearch:          # ← ADDED
    external: true
```

With this change:

- The koha container joins `opensearch-36_osearch` at startup.
- Docker's internal DNS resolves `os01` to `172.28.0.3`.
- TCP connections to `os01:9200` succeed.

**Startup order constraint**: The OpenSearch cluster (`koha-docker/OpenSearch-3.6/`) must be running **before** `docker compose up` is issued for `koha-docker`, because
Docker refuses to start a compose project that references a non-existent external network.

---

### Files changed

| File | Change |
|---|---|
| `koha-docker/docker-compose.yml` | Added `opensearch-36_osearch: {}` to `koha` service networks; added `opensearch-36_osearch: external: true` to top-level `networks:` block |

---

## 2026-05-02 — Search::Elasticsearch: SSL, URL-encoded credentials, and product check

### Symptom

After fixing the Docker network, the koha container could TCP-connect to `os01:9200`, but `rebuild_elasticsearch.pl` still failed with `[NoNodes]`. Three independent bugs in
the `Search::Elasticsearch` Perl library combined to cause this.

---

### Cause A — SSL certificate verification

**Error at HTTPS level**: `IO::Socket::SSL: SSL connect attempt failed … certificate verify failed`.

`ELASTIC_SERVER=https://os01:9200` triggers HTTPS. The `Search::Elasticsearch` Perl module (version 8.12) uses `Search::Elasticsearch::Cxn::HTTPTiny` as its HTTP backend,
**not** `LWP::UserAgent`. Therefore the environment variable `PERL_LWP_SSL_VERIFY_HOSTNAME=0` (which only affects `LWP`) has **no effect** here.

#### How the HTTPTiny backend handles SSL options

The relevant code in `HTTPTiny.pm` (lines 79–82):

```perl
if ( $self->is_https && $self->has_ssl_options ) {
    $args{SSL_options} = $self->ssl_options;
    if ( $args{SSL_options}{SSL_verify_mode} ) {   # 0 is falsy → this branch is skipped
        $args{verify_ssl} = 1;
    }
}
```

`SSL_options` is a hashref passed straight through to `IO::Socket::SSL`. Setting `SSL_verify_mode => 0` (falsy) leaves `verify_ssl` unset (defaulting to `0` = no hostname verify), and passes `SSL_options => { SSL_verify_mode => 0 }` to `IO::Socket::SSL`, which interprets `SSL_VERIFY_NONE`. This correctly disables certificate verification.

#### How to inject `ssl_options` into Koha's constructor call

Koha's `koha-conf.xml` has an `<elasticsearch>` block. Every XML child element in that block is collected into a hashref and passed as keyword arguments to `Search::Elasticsearch->new(...)`. The block is generated at startup from a template:

```xml
<!-- files/templates/koha-conf-site.xml.in -->
<elasticsearch>
    <server>${ELASTIC_SERVER}</server>
    <index_name>koha_${KOHA_INSTANCE}</index_name>
    ${ELASTIC_OPTIONS}
</elasticsearch>
```

`${ELASTIC_OPTIONS}` is expanded by `envsubst` from the container environment. So setting:

```bash
ELASTIC_OPTIONS=<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>
```

causes the generated `koha-conf.xml` to contain:

```xml
<elasticsearch>
    <server>https://os01:9200</server>
    <index_name>koha_kohadev</index_name>
    <ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>
</elasticsearch>
```

`C4::Context->config('elasticsearch')` parses this into:

```perl
{
  server       => 'https://os01:9200',
  index_name   => 'koha_kohadev',
  ssl_options  => { SSL_verify_mode => 0 },
}
```

…which is passed to `Search::Elasticsearch->new(ssl_options => { SSL_verify_mode => 0 })`, disabling certificate verification in the `HTTPTiny` backend.

**Fix**: Add `<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>` to `ELASTIC_OPTIONS` in `env/.env`.

---

### Cause B — URL-encoded credentials produce a wrong Authorization header

**Error**: HTTP 401 Unauthorized from OpenSearch → node marked dead → `[NoNodes]`.

The original `ELASTIC_SERVER` was:

```
ELASTIC_SERVER=https://admin:test%40Cici24%23ANA@os01:9200
```

The password `test@Cici24#ANA` was percent-encoded (`%40` for `@`, `%23` for `#`) because those characters have special meaning in URLs.

#### What goes wrong inside `Search::Elasticsearch`

`Role::Cxn` parses the node URL using a URI library. The URI library **decodes** percent-encoding during parsing, so the extracted `userinfo` becomes `admin:test@Cici24#ANA`.
However, `Role::Cxn` then base64-encodes the **already-decoded** string to build the `Authorization: Basic ...` header — so the header is correct.

**BUT**: when the URL contains special characters (`@`, `#`) in the password portion, some URI library versions do not reliably parse the authority component. The `@` sign is
the user-info/host separator, so `test@Cici24#ANA` in the password position confuses the parser. In the version installed, the password was extracted as `test%40Cici24%23ANA`
(the URL-encoded form, left un-decoded), and that literal string was base64-encoded and sent as the password — which OpenSearch rejected.

#### Fix

Remove the credentials from `ELASTIC_SERVER` entirely, and pass them via the `userinfo` constructor parameter instead:

```bash
ELASTIC_SERVER=https://os01:9200
```

`Role::Cxn` line 122 has a dedicated code path for the `userinfo` parameter:

```perl
if ( my $userinfo = $self->userinfo ) {
    $args{headers}{'Authorization'} = 'Basic ' . encode_base64($userinfo, '');
}
```

When `userinfo` is provided directly as a plain string (not via URL parsing), it is base64-encoded as-is — so `admin:test@Cici24#ANA` produces the correct header.

Add to `ELASTIC_OPTIONS`:

```
<userinfo>admin:test@Cici24#ANA</userinfo>
```

---

### Cause C — Elasticsearch 8.x product check rejects OpenSearch

**Error**: `[ProductCheck] ** The client noticed that the server is not Elasticsearch` → node marked dead → `[NoNodes]`.

The installed `Search::Elasticsearch` Perl module is version **8.12**. Starting from version 8, the library enforces a product-compatibility check in `Role::Cxn::process_response` (line 369):

```perl
if ( $self->client_version >= 8 and $code >= 200 and $code < 300 ) {
    my $product = $headers->{'x-elastic-product'} // '';
    if ( $product ne 'Elasticsearch' ) {
        throw(
            'ProductCheck',
            "The client noticed that the server is not Elasticsearch "
            . "and we do not support this server"
        );
    }
}
```

OpenSearch returns `x-elastic-product: OpenSearch` in its response headers (not `Elasticsearch`). Every successful HTTP 2xx response triggers the check, which throws
`ProductCheck`, which marks the node as dead. The very first request (`GET /`) already fails this way, so no index operations ever reach the server.

#### Fix

Pass `<client_version>7</client_version>` via `ELASTIC_OPTIONS`. When `client_version` is set to `7`, the condition `$self->client_version >= 8` is false and the product check
is entirely skipped. The rest of the 8.x API (request format, response parsing) continues to work normally with OpenSearch 3.6.

---

### Combined fix — `env/.env`

All three fixes combine into two environment variables:

```bash
# No credentials in the URL — avoids URI-parsing ambiguity with special chars (@, #)
ELASTIC_SERVER=https://os01:9200

# Three XML elements injected into koha-conf.xml's <elasticsearch> block:
#   ssl_options  → disables IO::Socket::SSL certificate verification
#   userinfo     → passes credentials as raw string, base64-encoded correctly
#   client_version → set to 7 to skip the ES 8.x product check that rejects OpenSearch
ELASTIC_OPTIONS=<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options><userinfo>admin:test@Cici24#ANA</userinfo><client_version>7</client_version>

# Kept for any LWP-based code paths (e.g., Koha's REST calls)
PERL_LWP_SSL_VERIFY_HOSTNAME=0
```

These values produce the following `<elasticsearch>` block in the generated `koha-conf.xml`:

```xml
<elasticsearch>
    <server>https://os01:9200</server>
    <index_name>koha_kohadev</index_name>
    <ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>
    <userinfo>admin:test@Cici24#ANA</userinfo>
    <client_version>7</client_version>
</elasticsearch>
```

Which translates to this `Search::Elasticsearch->new(...)` call at runtime:

```perl
Search::Elasticsearch->new(
    nodes          => 'https://os01:9200',
    ssl_options    => { SSL_verify_mode => 0 },
    userinfo       => 'admin:test@Cici24#ANA',
    client_version => 7,
);
```

Verification (manual test inside the running container):

```
SUCCESS: cluster=opensearch version=3.6.0
```

---

### Files changed

| File | Change |
|---|---|
| `koha-docker/env/.env` | `ELASTIC_SERVER`: stripped credentials from URL; `ELASTIC_OPTIONS`: added `ssl_options`, `userinfo`, `client_version`; `PERL_LWP_SSL_VERIFY_HOSTNAME=0` retained |

---

## 2026-05-02 — OpenSearch `analysis-icu` plugin missing

### Symptom

With all auth/SSL/product-check issues resolved, `rebuild_elasticsearch.pl` connected successfully but received HTTP 400 when trying to create the Koha search indexes:

```
[Request] ** [https://os01:9200]-[400] [illegal_argument_exception]
Custom Analyzer [icu_folding_normalizer] failed to find filter under name [icu_folding]
```

---

### Analysis

#### What Koha's Elasticsearch mappings require

Koha ships with a set of index configuration files under `koha/etc/searchengine/elasticsearch/`. These define custom analyzers for the `biblio` and `authority` indexes. The `marc21` mappings use three ICU analysis features:

| Feature | Type | Plugin component |
|---|---|---|
| `icu_tokenizer` | tokenizer | `analysis-icu` |
| `icu_folding` | token filter | `analysis-icu` |
| `icu_normalizer` | char filter | `analysis-icu` |

If any of these are referenced in the index settings but the plugin is not installed on OpenSearch, the index creation request returns HTTP 400 with `illegal_argument_exception`.

#### Which nodes were missing the plugin

The OpenSearch cluster uses a custom `Dockerfile` in `koha-docker/OpenSearch-3.6/assets/opensearch/Dockerfile`. In the original file, only **`os01`** used the `build:` directive pointing to this Dockerfile. **`os02`–`os05`** used `image: opensearchproject/opensearch:${OPEN_SEARCH_VERSION}` directly, meaning they were started from the unmodified base image with no custom packages.

Even if the Dockerfile had included the `analysis-icu` plugin, the four data/ingest/search nodes would not have it. OpenSearch requires all nodes in a cluster to have the same
plugins installed; a plugin must be present on every node that handles index shards.

Confirming with the OpenSearch API:

```bash
curl -sk -u 'admin:...' https://localhost:9200/_cat/plugins?v
# Result: (empty — no plugins on any node)
```

---

### Fix

#### 1. Add `analysis-icu` to the Dockerfile

`koha-docker/OpenSearch-3.6/assets/opensearch/Dockerfile`:

```dockerfile
ARG OPEN_SEARCH_VERSION
FROM opensearchproject/opensearch:${OPEN_SEARCH_VERSION}
USER root
RUN dnf -y install iputils net-tools curl procps --skip-broken

# Install analysis-icu plugin (required by Koha for icu_folding, icu_tokenizer, icu_normalizer)
USER opensearch
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu
USER root
```

The plugin is installed as the `opensearch` user (not `root`) because the plugin installer writes into `/usr/share/opensearch/plugins/`, which is owned by the `opensearch` user in the base image. Running it as `root` produces a permission warning and can leave the plugin directory with incorrect ownership.

#### 2. Switch `os02`–`os05` from `image:` to `build:`

`koha-docker/OpenSearch-3.6/docker-compose.yml` — for each of `os02`, `os03`, `os04`, `os05`, replaced:

```yaml
image: opensearchproject/opensearch:${OPEN_SEARCH_VERSION}
```

with:

```yaml
build:
  context: .
  dockerfile: assets/opensearch/Dockerfile
  args:
    - OPEN_SEARCH_VERSION=${OPEN_SEARCH_VERSION}
```

This ensures all five nodes are built from the same image with `analysis-icu` installed.

#### 3. Rebuild and restart the cluster

```bash
cd koha-docker/OpenSearch-3.6
docker compose build          # rebuilds all 5 images with the plugin
docker compose down           # removes running containers
docker compose up -d          # starts fresh with new images
```

Post-restart verification:

```bash
curl -sk -u 'admin:test@Cici24#ANA' https://localhost:9200/_cat/plugins?v | grep icu
# os01  analysis-icu  3.6.0
# os02  analysis-icu  3.6.0
# os03  analysis-icu  3.6.0
# os04  analysis-icu  3.6.0
# os05  analysis-icu  3.6.0
```

---

### Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/assets/opensearch/Dockerfile` | Added `USER opensearch` + `RUN opensearch-plugin install --batch analysis-icu` + `USER root` |
| `OpenSearch-3.6/docker-compose.yml` | Changed `os02`–`os05` from `image: opensearchproject/opensearch:...` to `build:` using the same Dockerfile |

---

## 2026-05-02 — Full stack startup: sequence and verification

### Complete startup sequence

The three projects must be started in order because each depends on Docker networks or services created by the previous one.

---

#### Step 1 — Build the OpenSearch cluster images (first time or after Dockerfile changes)

```bash
cd /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/OpenSearch-3.6
docker compose build
```

This builds the custom image (with `analysis-icu`) for all five nodes. Only needed after modifying the Dockerfile or upgrading the OpenSearch version. On subsequent runs, the
cached images are reused and this step can be skipped.

---

#### Step 2 — Start the OpenSearch cluster

```bash
cd /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/OpenSearch-3.6
docker compose up -d
```

Wait for the cluster to be green (all five nodes elected, leader chosen):

```bash
# Poll until status=green
until curl -sk -u 'admin:test@Cici24#ANA' \
    https://localhost:9200/_cluster/health | grep -q '"status":"green"'; do
  echo "Waiting for OpenSearch cluster..."; sleep 5
done
echo "Cluster is green"
```

The network `opensearch-36_osearch` is created by this compose project. Step 3 will fail with `network not found` if this step is skipped or if the cluster has not yet finished
initialising.

---

#### Step 3 — Initialise the Koha database (first run or to reset state)

The `koha` container's `run.sh` expects a **fresh, empty database** named `koha_${KOHA_INSTANCE}`. If the database already contains tables from a previous run, `do_all_you_can_do.pl` will report conflicts and the container may exit early.

```bash
docker exec koha-docker-db-1 mysql -uroot -ppassword -e "
  DROP DATABASE IF EXISTS koha_kohadev;
  CREATE DATABASE koha_kohadev
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON koha_kohadev.* TO 'koha_kohadev'@'%';
  FLUSH PRIVILEGES;
"
```

This requires the `db` container to already be running. On first launch, start it with:

```bash
docker compose \
  -f /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/docker-compose.yml \
  --env-file /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/env/.env \
  --project-directory /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker \
  up -d db memcached
```

Wait ~5 seconds for MariaDB to initialise before running the `mysql` command above.

---

#### Step 4 — Start (or restart) the Koha container

```bash
docker compose \
  -f /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/docker-compose.yml \
  --env-file /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/env/.env \
  --project-directory /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker \
  up -d --force-recreate koha
```

`--force-recreate` ensures the container picks up any changes to environment variables or bind mounts, and always starts with a clean container state (no leftover Plack PIDs,
stale sockets, etc.).

---

#### Step 5 — Follow the startup logs

```bash
docker compose \
  -f /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/docker-compose.yml \
  --env-file /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/env/.env \
  --project-directory /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker \
  logs -f koha
```

The startup script (`run.sh`) is long-running and produces extensive output. Key milestones to watch for, in sequence:

| Milestone | Log line |
|---|---|
| Instance configuration created | `koha-create --request-db kohadev` |
| Database populated | `Running do_all_you_can_do.pl` |
| L10n translation files cloned | `Cloning into 'po'...` |
| Git config and hooks set | `git config bz.default-tracker` |
| Source tree gitified | `gitify all` |
| Front-end assets compiled | `yarn build` / `rspack` |
| Search index built | `rebuild_elasticsearch.pl -v` |
| Plack OPAC started | `Plack enabled for kohadev OPAC` |
| Plack Intranet started | `Plack enabled for kohadev Intranet` |
| **Ready** | `koha-testing-docker has started up and is ready to be enjoyed!` |

The container exits with code 0 after printing the "ready" line — this is expected. The Plack workers continue running inside the container even after `run.sh` exits.

---

### What a successful run looks like (abridged log)

```
koha-1  | Running [sudo koha-shell kohadev -p -c 'koha-create --request-db kohadev']...
koha-1  |  * Error: worker not running for kohadev (default)      ← harmless, no DB yet
koha-1  |  * Error: worker not running for kohadev (long_tasks)   ← harmless
koha-1  | Running [sudo koha-shell kohadev -p -c 'perl .../do_all_you_can_do.pl --elasticsearch']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'git clone ... misc/translator/po']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'gitify all']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'yarn build']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'rebuild_elasticsearch.pl -v']...
koha-1  | :8: parser error : PCDATA invalid Char value 31         ← harmless, biblio 369
koha-1  | Something went wrong reading record for biblio 369 ...  ← harmless, corrupt sample data
koha-1  | Plack enabled for kohadev OPAC
koha-1  | Plack enabled for kohadev Intranet
koha-1  |  * Error: Plack already running for kohadev             ← harmless double-start attempt
koha-1  | koha-testing-docker has started up and is ready to be enjoyed!
koha-1 exited with code 0
```

#### Non-fatal warnings explained

| Warning | Cause | Impact |
|---|---|---|
| `Error: worker not running for kohadev` | `koha-create` tries to restart the worker before the DB is populated | None — worker starts fine later |
| `PCDATA invalid Char value 31` (biblio 369) | Sample MARC record in `misc4dev` test data contains a control character (0x1F) in an XML field | None — that one record is skipped; all others are indexed |
| `Error: Plack already running for kohadev` | `run.sh` calls `koha-plack --start` twice (once in `do_all_you_can_do.pl` and once at the end of the script) | None — second call is a no-op |

---

### Accessing Koha

After a successful start:

| Interface | URL |
|---|---|
| OPAC | http://kohadev.myDNSname.org:8080 |
| Staff interface (Intranet) | http://kohadev-intra.myDNSname.org:8081 |
| OpenSearch Dashboards | http://localhost:5601 (via `knonikl` network / Traefik) |

Default superlibrarian credentials are set by `create_superlibrarian.pl` during startup (see `env/.env` for `KOHA_ADMINUSER` / `KOHA_ADMINPASS`).

---

### Files changed in this session (summary)

| File | Change | Section |
|---|---|---|
| `Dockerfile` | `RUN userdel -r ubuntu` — frees UID 1000 for `kohadev-koha` | UID fix |
| `koha-docker/docker-compose.yml` | Added `opensearch-36_osearch` as external network; attached koha service to it | Network routing |
| `koha-docker/env/.env` | `ELASTIC_SERVER` stripped of credentials; `ELASTIC_OPTIONS` with `ssl_options` + `userinfo` + `client_version`; `PERL_LWP_SSL_VERIFY_HOSTNAME=0` | SSL/auth/product check |
| `OpenSearch-3.6/assets/opensearch/Dockerfile` | Added `analysis-icu` plugin install | ICU plugin |
| `OpenSearch-3.6/docker-compose.yml` | `os02`–`os05` switched from `image:` to `build:` | ICU plugin |


---

## 2026-05-02 — Traefik reverse-proxy integration (hostname routing, portability)

### Goal

Eliminate the requirement to add `127.0.0.1 kohadev.myDNSname.org` and `127.0.0.1 kohadev-intra.myDNSname.org` to the host machine's `/etc/hosts` file.
The solution must be portable — no per-machine DNS configuration should be needed.

The existing Traefik container (`koha-docker/traefik/`) is leveraged as the entry point for all HTTP traffic. Traefik routes incoming requests to the correct Koha port based on the `Host:` header, removing the need for direct port bindings in the browser.

---

### Architecture before this change

```
Browser
  └─► http://kohadev.myDNSname.org:8080  → requires /etc/hosts: 127.0.0.1 kohadev.myDNSname.org
  └─► http://kohadev-intra.myDNSname.org:8081  → requires /etc/hosts: 127.0.0.1 kohadev-intra.myDNSname.org

Docker host
  koha container :8080 (host binding) → OPAC
  koha container :8081 (host binding) → Staff interface
```

Problems:

- Non-standard ports in all URLs (`:8080`, `:8081`)
- `/etc/hosts` must be edited on every machine that accesses the stack
- Not portable to a remote server without changing DNS or `/etc/hosts` on every client

---

### Architecture after this change

```
Browser
  └─► http://kohadev.myDNSname.org  (port 80, standard)
  └─► http://kohadev-intra.myDNSname.org  (port 80, standard)
         │
         ▼
  Traefik container  (frontend network, port 80 on host)
  reads Host: header
         │
         ├─ Host: kohadev.myDNSname.org       → koha container :8080
         └─ Host: kohadev-intra.myDNSname.org → koha container :8081

Fallback (no DNS):
  http://localhost:8080  (direct, no Traefik)
  http://localhost:8081  (direct, no Traefik)
```

Networks involved:

- `frontend` — external Docker bridge; Traefik + koha join it; Traefik reads labels from it
- `kohanet` — internal; koha + db + memcached
- `knonikl` — shared bridge; koha + OpenSearch Dashboards
- `opensearch-36_osearch` — OpenSearch cluster internal; koha + os01–os05

---

### How Traefik Docker provider routing works

Traefik watches the Docker socket (`/var/run/docker.sock`) for container events. When a container with `traefik.enable=true` starts, Traefik reads its labels and dynamically creates:

1. **Router** — matches incoming HTTP requests by hostname (the `Host()` rule)
2. **Service** — defines where to forward matched requests (container IP + port)

The `traefik.docker.network` label tells Traefik which Docker network to use when resolving the container's IP. This is required when a container is attached to multiple networks (as `koha` is). Without it, Traefik may pick the wrong network's IP and the forwarded request would be unreachable.

Traefik's static config (`traefik/config/traefik.yaml`) already has:

```yaml
providers:
  docker:
    exposedByDefault: false
    network: frontend
```

The `network: frontend` here is the global default. The per-container `traefik.docker.network=frontend` label is an explicit override that ensures the correct network is used even if the global default is later changed.

---

### Changes made

#### 1. `koha-docker/docker-compose.yml` — Traefik labels and `frontend` network

Added a `labels:` block to the `koha` service with two Traefik routers and two services:

```yaml
labels:
    # traefik.enable=true — opt this container in (required because exposedByDefault: false)
    - "traefik.enable=true"
    # Override the network Traefik uses to reach this container
    - "traefik.docker.network=frontend"

    # ── OPAC router + service ──────────────────────────────────────────────
    # Host rule: matches requests where Host: == kohadev.myDNSname.org
    # (value built from KOHA_INSTANCE + KOHA_DOMAIN env vars at compose time)
    - "traefik.http.routers.koha-opac.rule=Host(`${KOHA_INSTANCE}${KOHA_DOMAIN}`)"
    - "traefik.http.routers.koha-opac.entrypoints=web"
    - "traefik.http.routers.koha-opac.service=koha-opac-svc"
    # Forward to the container's internal port 8080 (KOHA_OPAC_PORT)
    - "traefik.http.services.koha-opac-svc.loadbalancer.server.port=${KOHA_OPAC_PORT:-8080}"

    # ── Staff interface router + service ──────────────────────────────────
    # Host rule: kohadev-intra.myDNSname.org
    - "traefik.http.routers.koha-staff.rule=Host(`${KOHA_INSTANCE}${KOHA_INTRANET_SUFFIX}${KOHA_DOMAIN}`)"
    - "traefik.http.routers.koha-staff.entrypoints=web"
    - "traefik.http.routers.koha-staff.service=koha-staff-svc"
    # Forward to internal port 8081 (KOHA_INTRANET_PORT)
    - "traefik.http.services.koha-staff-svc.loadbalancer.server.port=${KOHA_INTRANET_PORT:-8081}"
```

**Why two explicit services are needed**: when a container exposes multiple ports (8080 and 8081), Traefik cannot infer which port to use for which router. Declaring named services with explicit `loadbalancer.server.port` values removes the ambiguity.

**Why `${KOHA_INSTANCE}${KOHA_DOMAIN}` expands at compose time**: Docker Compose interpolates `${VAR}` in label values from the `env_file` (here `env/.env`) before passing the label string to Docker. Traefik then reads the already-expanded label value.
This means changing `KOHA_INSTANCE` or `KOHA_DOMAIN` in `env/.env` automatically updates the routing rules on next `docker compose up` — no manual Traefik config editing needed.

Also added `frontend: {}` to the `koha` service's `networks:` block so the container joins the `frontend` network at startup:

```yaml
networks:
    kohanet:
        aliases: [...]
    knonikl: {}
    opensearch-36_osearch: {}
    frontend: {}            # ← ADDED: allows Traefik to reach the container
```

And added `frontend` to the top-level `networks:` declaration:

```yaml
networks:
    kohanet:
        enable_ipv4: ${ENABLE_IPV4:-true}
        enable_ipv6: ${ENABLE_IPV6:-false}
    knonikl:
        external: true
    opensearch-36_osearch:
        external: true
    frontend:               # ← ADDED
        external: true
```

The `ports:` host bindings (`8080:8080`, `8081:8081`) are **kept** as a fallback. They allow direct `http://localhost:8080` / `http://localhost:8081` access when Traefik is not running or DNS does not resolve. A comment documents that they can be removed once Traefik is the exclusive entry point.

---

#### 2. `koha-docker/traefik/docker-compose.yaml` — configurable host ports

The Traefik container previously had the HTTP port hard-coded to `83:80`. On a typical Linux server port 80 is the standard HTTP port. Changed all three port bindings to use environment variables with sensible defaults:

```yaml
# Before
ports:
  - "83:80"
  - "443:443"
  - "8083:8080"

# After
ports:
  - "${TRAEFIK_HTTP_PORT:-80}:80"
  - "${TRAEFIK_HTTPS_PORT:-443}:443"
  - "${TRAEFIK_DASHBOARD_PORT:-8083}:8080"
```

`:-80` / `:-443` / `:-8083` are Docker Compose default-value syntax: if the variable is unset or empty in the environment, the default after `:-` is used. This means the file works out-of-the-box with no `.env` required, but the ports can be overridden.

---

#### 3. `koha-docker/traefik/.env` — port defaults documented

The `.env` file previously contained only a comment line. Port variables added:

```bash
# Host port bindings for the Traefik proxy container.
# Change TRAEFIK_HTTP_PORT to a non-privileged port (e.g. 8000) if port 80 is
# already in use on the host, then access Koha as http://hostname:8000
TRAEFIK_HTTP_PORT=80
TRAEFIK_HTTPS_PORT=443
TRAEFIK_DASHBOARD_PORT=8083
```

If port 80 is already bound (e.g., another web server), change `TRAEFIK_HTTP_PORT=8000` here. The access URLs then become `http://kohadev.myDNSname.org:8000`.

---

#### 4. `koha-docker/stack.sh` — Traefik lifecycle management

Four additions:

**a) `TRAEFIK_DIR` path variable**

```bash
TRAEFIK_DIR="${SCRIPT_DIR}/traefik"
```

**b) Port variables read from `traefik/.env`**

```bash
TRAEFIK_HTTP_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTP_PORT 80)"
TRAEFIK_DASHBOARD_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_DASHBOARD_PORT 8083)"
```

These are used in the startup banner and in `start_traefik()`.

**c) `traefik_compose()` wrapper**

```bash
traefik_compose() {
  docker compose \
    -f "${TRAEFIK_DIR}/docker-compose.yaml" \
    --env-file "${TRAEFIK_DIR}/.env" \
    --project-directory "${TRAEFIK_DIR}" \
    "$@"
}
```

Consistent with the existing `koha_compose()` and `os_compose()` wrappers.

**d) `ensure_frontend_network()` function**

```bash
ensure_frontend_network() {
  if ! docker network inspect frontend >/dev/null 2>&1; then
    log "Creating 'frontend' Docker network (required by Traefik)..."
    docker network create frontend
    ok "Network 'frontend' created."
  else
    ok "Network 'frontend' already exists."
  fi
}
```

The `frontend` network is declared `external: true` in both the Traefik compose and the Koha compose. Docker refuses to start either project if the network doesn't exist. This function is called at the start of `start_traefik()` and creates the network idempotently (no error if it already exists).

**e) `start_traefik()` and `stop_traefik()` functions**

```bash
start_traefik() {
  hdr "Starting Traefik reverse proxy"
  ensure_frontend_network
  if traefik_compose ps --status running traefik 2>/dev/null | grep -q traefik; then
    ok "Traefik is already running."
  else
    traefik_compose up -d traefik
    ok "Traefik started (HTTP :${TRAEFIK_HTTP_PORT}, dashboard :${TRAEFIK_DASHBOARD_PORT})."
  fi
}

stop_traefik() {
  hdr "Stopping Traefik"
  traefik_compose stop traefik 2>/dev/null || true
  ok "Traefik stopped."
}
```

`start_traefik()` is idempotent: if Traefik is already up (e.g., from a previous run or because it is shared with other projects), it is left running.

**f) `check_prereqs()` updated**

Added validation that `traefik/docker-compose.yaml` exists:

```bash
[[ -f "${TRAEFIK_DIR}/docker-compose.yaml" ]] \
  || die "traefik/docker-compose.yaml not found"
```

**g) Startup sequence updated**

`start_traefik` is now the **first** step in `stack.sh start`, before OpenSearch:

```
1. start_traefik          ← NEW: ensures frontend network + Traefik container
2. start_opensearch
3. wait_opensearch_green
4. start_support_services
5. wait_db_ready
6. reset_database (if --no-fresh-db not set)
7. start_koha
8. follow_logs
```

`stop_traefik` is the **last** step in `stack.sh stop`:

```
1. stop_koha
2. stop_support_services
3. stop_opensearch
4. stop_traefik
```

**h) `show_status()` updated**

A Traefik section was added to the `status` command output:

```bash
echo -e "${BOLD}── Traefik ──...${RESET}"
traefik_compose ps 2>/dev/null || echo "  (not running)"
```

**i) Access banner in `follow_logs()` updated**

The "ready" banner now shows both access methods and all four service URLs:

```
╔══════════════════════════════════════════════════════════╗
║   Stack fully started and ready!                         ║
╠══════════════════════════════════════════════════════════╣
║  Via Traefik (recommended):
║    OPAC    : http://kohadev.myDNSname.org
║    Staff   : http://kohadev-intra.myDNSname.org
║  Direct (fallback, no DNS needed):
║    OPAC    : http://localhost:8080
║    Staff   : http://localhost:8081
║  Login     : koha / koha
║  Dashbrd   : http://dashboards.localhost
║  Traefik   : http://localhost:8083
╚══════════════════════════════════════════════════════════╝
```

If `TRAEFIK_HTTP_PORT` is not 80, the port suffix (e.g., `:8000`) is appended automatically to all Traefik-routed URLs.

---

### Hostname resolution — three options documented

The Traefik labels handle the routing side. For a browser to send a request with the correct `Host:` header to the Docker host, the hostnames must resolve. Three approaches
are documented in the README and below:

#### Option 1 — `/etc/hosts` (simple, single machine)

```
127.0.0.1  kohadev.myDNSname.org
127.0.0.1  kohadev-intra.myDNSname.org
```

Requires a one-time edit with `sudo` on every machine that needs access. Good enough for a single developer's workstation.

#### Option 2 — `nip.io` wildcard DNS (zero-config, portable)

[nip.io](https://nip.io) is a public DNS service that resolves any hostname containing an embedded IP address back to that IP. No registration, no local configuration.

Set in `env/.env`:

```bash
KOHA_DOMAIN=.127.0.0.1.nip.io       # local access
# or
KOHA_DOMAIN=.192.168.1.100.nip.io   # LAN/server access
```

Access URLs become:
- `http://kohadev.127.0.0.1.nip.io` (OPAC)
- `http://kohadev-intra.127.0.0.1.nip.io` (Staff)

The Traefik `Host()` rules and Koha's Apache virtual hosts are rebuilt from `KOHA_DOMAIN` automatically on next `docker compose up`. No other files need changing.
This is the most portable option for development. It works from any machine on the LAN (using the server's LAN IP) without touching DNS or `/etc/hosts` on any client.

#### Option 3 — Real DNS (production)

Create DNS A records for `kohadev.myDNSname.org` and `kohadev-intra.myDNSname.org` (or a wildcard `*.myDNSname.org`) pointing to the server's public IP. Traefik handles
routing; no client-side configuration needed.

---

### Why Traefik must join the `frontend` network (not just `knonikl`)

The Traefik static config (`traefik/config/traefik.yaml`) declares:

```yaml
providers:
  docker:
    network: frontend
```

This tells Traefik: "when forwarding requests to containers, use the IP address the container has on the `frontend` network." If the `koha` container is not attached to
`frontend`, Traefik cannot reach it even though the labels are visible via the Docker socket. Attaching `koha` to `frontend` solves this.

The `knonikl` network continues to serve its original purpose (Koha ↔ OpenSearch Dashboards communication) and is unrelated to Traefik routing.

---

### Files changed

| File | Change |
|---|---|
| `koha-docker/docker-compose.yml` | Added `labels:` block with Traefik routers/services; added `frontend: {}` to `koha` service networks; added `frontend: external: true` to top-level `networks:` |
| `koha-docker/traefik/docker-compose.yaml` | Changed hard-coded port `83:80` to `${TRAEFIK_HTTP_PORT:-80}:80`; same for HTTPS and dashboard ports |
| `koha-docker/traefik/.env` | Added `TRAEFIK_HTTP_PORT=80`, `TRAEFIK_HTTPS_PORT=443`, `TRAEFIK_DASHBOARD_PORT=8083` |
| `koha-docker/stack.sh` | Added `TRAEFIK_DIR`; added `TRAEFIK_HTTP_PORT` / `TRAEFIK_DASHBOARD_PORT` config reads; added `traefik_compose()`, `ensure_frontend_network()`, `start_traefik()`, `stop_traefik()`; updated `check_prereqs()`, `start` sequence, `stop` sequence, `show_status()`, access banner in `follow_logs()` |
| `koha-docker/README.md` | Replaced `/etc/hosts` section with Traefik routing explanation; documented all three hostname resolution options; updated service URL table (port-free Traefik URLs + direct fallback); updated `KOHA_DOMAIN` table row with nip.io hint |

---

## Session — nip.io Fix + Demo Data Flags (2026-05-02)

### Root Cause: nip.io / URL-in-database Bug

`files/run.sh` was constructing `KOHA_OPAC_URL=http://kohadev.127.0.0.1.nip.io:8080` — with the **internal** Apache port 8080. This URL is stored in the Koha database as `OPACBaseURL` and `staffClientBaseURL` via `populate_db.pl`. When users access Koha through Traefik on port 80, all Koha-generated links and login redirects pointed to `:8080`, bypassing Traefik entirely.

The nip.io DNS service itself was fine — `host kohadev.127.0.0.1.nip.io` → `127.0.0.1` worked correctly. The problem was purely the port baked into URLs stored in the DB.

### Fix: KOHA_PUBLIC_PORT

**New env var `KOHA_PUBLIC_PORT=80`** decouples the *public-facing* port (what users type in browser, served by Traefik) from the *internal Apache port* (`KOHA_OPAC_PORT=8080`, used for container-to-container routing and Traefik backend).

URL construction logic in `files/run.sh`:

- Port 80 or empty → URLs have **no port suffix**: `http://kohadev.127.0.0.1.nip.io`
- Any other port → suffix appended: `http://kohadev.127.0.0.1.nip.io:8000`

**Test result:**
```
OPACBaseURL:         http://kohadev.127.0.0.1.nip.io   ← no :8080 ✓
staffClientBaseURL:  http://kohadev-intra.127.0.0.1.nip.io  ← no :8081 ✓
OPAC via Traefik:    HTTP 200 ✓
Staff via Traefik:   HTTP 200 ✓
```

### New Feature: Demo Data Flags

`./stack.sh start --no-demo-data` starts Koha with an empty catalogue (superlibrarian account only).  
`./stack.sh start --with-demo-data` loads 436 MARC sample records, authority records, and items (default).

**Mechanism:** When `LOAD_DEMO_DATA=no`, `run.sh` replaces `misc4dev/insert_data.pl` with a Perl no-op script before calling `do_all_you_can_do.pl`. All other setup steps (schema, superlibrarian, gitify, yarn, ES rebuild) run normally.

**Test result:**
```
--no-demo-data:   biblio_count = 0  ✓
--with-demo-data: biblio_count = 436 ✓
```

### Files Changed

| File | Change |
|------|--------|
| `files/run.sh` | New `KOHA_PUBLIC_PORT` URL construction; new `LOAD_DEMO_DATA=no` no-op injection |
| `env/.env` | Added `KOHA_PUBLIC_PORT=80`, `LOAD_DEMO_DATA=yes` |
| `docker-compose.yml` | Added `LOAD_DEMO_DATA` and `KOHA_PUBLIC_PORT` to `environment:` block |
| `stack.sh` | New `--no-demo-data` / `--with-demo-data` flags; updated `start_koha()`; updated banner |

### Key Architecture Notes

- `files/run.sh` is **COPIED** into the Docker image during `docker build` — changes require `./stack.sh start --build-koha`.
- `KOHA_OPAC_PORT=8080` still controls internal Apache listen port and Traefik backend routing.
- `KOHA_PUBLIC_PORT=80` only affects URL construction for the Koha DB preferences.
- The `environment:` block in `docker-compose.yml` overrides `env_file:` values, enabling shell exports from `stack.sh` to flow through.

---

## 2026-05-15 — Port Windows version improvements to koha-ubuntu image

### Goal

Synchronise `koha-docker` (Linux/Ubuntu image) with the improvements developed in `koha-docker-windows` (https://github.com/kosson/koha-docker-windows) and prepare the
project for publishing a reusable `kosson/koha-ubuntu` image to Docker Hub, mirroring the existing `kosson/koha-windows` image.

---

### Source

All changes analysed from `koha-docker-windows` at commit `main` (2026-05-08).
Windows-specific workarounds (CRLF inotifywait watcher, `azure.archive.ubuntu.com` mirror swap, `--no-check-certificate` for nodesource) were deliberately **excluded**
as they address Hyper-V/WSL2 issues that do not apply to native Linux builds.

---

### Changes made to `Dockerfile`

#### 1. `PATH` — add `/usr/local/bin`

```dockerfile
# Before
ENV PATH=/usr/bin:/bin:/usr/sbin:/sbin

# After
ENV PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

`/usr/local/bin` is where the new `apt-install-retry` helper is placed. Without it at the front of `PATH`, subsequent `RUN` layers that call `apt-install-retry` by name would
not find it.

#### 2. `REFRESHED_AT` date

Updated to `2026-05-15`.

#### 3. Stronger apt resilience settings

`/etc/apt/apt.conf.d/80-retries` was expanded from two directives to five:

| Directive | Old | New | Reason |
|---|---|---|---|
| `Acquire::Retries` | `"5"` | `"8"` | More retry budget for slow mirrors |
| `Acquire::http::Timeout` | `"120"` | `"600"` | Generous timeout for large packages |
| `Acquire::https::Timeout` | *(absent)* | `"600"` | Same for HTTPS sources |
| `Acquire::Queue-Mode` | *(absent)* | `"host"` | One sequential queue per hostname — keeps connections active, prevents mid-download idle timeouts |
| `Acquire::Max-FutureTime` | *(absent)* | `"86400"` | Tolerates up to 24 h VM clock drift after host sleep |

#### 4. New `apt-install-retry` helper script

A small POSIX shell wrapper placed in `/usr/local/bin/apt-install-retry` replaces every bare `apt-get update && apt-get -y install` call in the Dockerfile. It:

- Runs `apt-get update` + `apt-get -y install "$@"` in a loop (up to 4 attempts)
- Passes `-o Acquire::Max-FutureTime=86400` inline on every attempt so the clock-skew tolerance applies even before the conf layer is cached by Docker
- Removes `/var/lib/apt/lists/*` between retries (forces a fresh index fetch) but does **not** `apt-get clean` (preserves partial `.deb` files so apt can resume via HTTP
  Range requests on the next attempt)
- Exits non-zero after the final attempt, causing the `RUN` layer to fail visibly

#### 5. All package install blocks converted to `apt-install-retry`

Every `RUN apt-get update && apt-get -y install ... && rm -rf /var/cache/apt/...` block was replaced with `RUN /bin/sh /usr/local/bin/apt-install-retry <packages>`. The
trailing `rm -rf` cleanup is handled inside the helper on success.

This also eliminates the `koha-common` special case that had a separate `apt-get -y update` before install.

#### 6. CRLF normalization after `COPY`

```dockerfile
# Ensure Linux line endings even when the repository is checked out or edited
# with CRLF (cross-platform contributors). Safe to run unconditionally.
RUN sed -i 's/\r$//' /kohadevbox/run.sh \
    && find /kohadevbox/templates -type f -exec sed -i 's/\r$//' {} + \
    && find /kohadevbox/git_hooks  -type f -exec sed -i 's/\r$//' {} + \
    && chmod +x /kohadevbox/run.sh
```

Applied immediately after the `COPY` statements so the files are clean before any container uses them, regardless of the editor or OS used by contributors.

#### 7. `CMD` directive

```dockerfile
CMD ["/bin/bash", "/kohadevbox/run.sh"]
```

Makes the built image directly runnable as `docker run kosson/koha-ubuntu` without requiring an explicit command override. This is required for the image to be usable as a
pull-and-run target from Docker Hub.

---

### Changes made to `files/run.sh`

#### 1. Header note and version stamp

```bash
# run.sh — Koha container entrypoint.
# NOTE: This file is BAKED INTO THE IMAGE at build time (see Dockerfile: COPY files/run.sh).
# Editing this file on the host has NO effect until the image is rebuilt:
#   ./stack.sh start -b   (or docker compose build)
# RUN_SH_VERSION=2026-05-15
```

Prevents the common mistake of editing `run.sh` on the host and expecting a running container to pick up the changes.

#### 2. OpenSearch wait loop (critical missing feature)

The Linux version had **no wait loop** for OpenSearch before calling `do_all_you_can_do.pl --elasticsearch`. The Perl script would immediately call `rebuild_elasticsearch.pl`, which would fail with `[NoNodes]` if the OpenSearch cluster was not yet ready (cold start, cluster election not complete).

A 60-attempt loop (5 s sleep each = 5 min maximum wait) was added:

- **TCP pre-check**: `nc -z -w 3 os01 9200` — avoids spending a costly curl attempt on a port that is not even open yet
- **HTTPS health check**: `curl` against `/_cluster/health?wait_for_status=yellow` with correct credentials and CA cert handling (uses mounted `opensearch-root-ca.pem` if
  present, falls back to `-k`)
- **Cluster status check**: waits for `"status":"yellow"` or `"status":"green"`
- **Progress logging**: prints attempt number and last curl response on attempt 1 and every 10th attempt

If OpenSearch does not become ready within 5 minutes, `run.sh` exits with code 1 (early abort) rather than silently continuing and producing an empty search index.

#### 3. Elasticsearch/Zebra sed hacks

Two `sed` patches applied to `misc4dev/do_all_you_can_do.pl` when `KOHA_ELASTICSEARCH=yes`:

**a) Skip `koha-rebuild-zebra` in ES mode:**

```bash
sed -i 's|\$cmd = "sudo koha-rebuild-zebra -f -v \$instance";|say "Skipping..."; \$cmd = "true";|' \
    "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"
```

`misc4dev` forces a full Zebra rebuild after ES indexing succeeds. On the current sample dataset (`misc4dev` test data), several MARC records contain malformed XML (control
characters, invalid UTF-8) that cause `koha-rebuild-zebra` to abort with an error.
Since Elasticsearch/OpenSearch is the active search backend, the Zebra index is unused; the rebuild failure would abort `do_all_you_can_do.pl` and the container.

**b) Suppress ES rebuild noise:**

```bash
sed -i "s|perl \$rebuild_es_path -v'|perl \$rebuild_es_path' 2>/tmp/rebuild_elasticsearch.stderr|" \
    "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"
```

Redirects the verbose output of `rebuild_elasticsearch.pl` to a temp file during setup so the startup log is readable. The file remains available for inspection.

#### 4. CRLF normalization for `migration_tools`

```bash
find "${BUILD_DIR}/koha/misc/migration_tools" -type f -name '*.pl' \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true
```

`koha-rebuild-zebra` calls these scripts directly. CRLF shebangs produce a misleading "No such file or directory" error (the shell looks for `/usr/bin/perl\r`). This
normalization runs even on Linux builds, as the Koha repo may include commits from Windows developers.

#### 5. CRLF normalization for `.pl` / `.cgi` after setup

```bash
find "${BUILD_DIR}/koha" -type f \( -name '*.pl' -o -name '*.cgi' \) \
        -exec sed -i 's/\r$//' {} + 2>/dev/null || true
```

Applied after all setup steps and before Apache is started. Apache's CGI mode runs each `.pl` directly via the shebang; a CRLF shebang causes the same "No such file or
directory" error silently at request time, producing HTTP 500.

#### 6. Graceful `koha-plack` and `koha-z3950-responder` enable

```bash
# Before (hard-fails if the service is unavailable in this profile)
koha-plack           --enable ${KOHA_INSTANCE}
koha-z3950-responder --enable ${KOHA_INSTANCE}
service koha-common start

# After (continues with Apache CGI mode if Plack is unavailable)
if ! koha-plack --enable ${KOHA_INSTANCE} >/dev/null 2>&1; then
    echo "[INFO] koha-plack not enabled in this profile; continuing with Apache CGI mode"
fi
if ! koha-z3950-responder --enable ${KOHA_INSTANCE} >/dev/null 2>&1; then
    echo "[INFO] koha-z3950-responder enable skipped; continuing"
fi
service koha-common start 2>&1 | grep -v "you must provide at least one instance name" || true
```

Prevents a hard exit when a Koha package profile does not include Plack or Z39.50, and suppresses the noisy "you must provide at least one instance name" message from
`koha-common start` during profile-less startup.

---

### Changes made to `docker-compose.yml`

#### 1. Pre-built image pull support

```yaml
koha:
    image: ${KOHA_IMAGE_TAG:-kosson/koha-ubuntu:latest}
    build:
        context: .
```

When `KOHA_IMAGE_TAG` is set in `env/.env` to a published tag (e.g., `kosson/koha-ubuntu:25.12.00`), Docker Compose will **pull** that image instead of building locally — identical to how `kosson/koha-windows` works. To force a local build, unset `KOHA_IMAGE_TAG` or run `docker compose build`.

#### 2. Parameterized DB root password

```yaml
# Before
MYSQL_ROOT_PASSWORD: password

# After
MYSQL_ROOT_PASSWORD: ${KOHA_DB_ROOT_PASSWORD:-password}
```

Allows overriding the MariaDB root password from `env/.env` without editing
`docker-compose.yml`.

#### 3. Named volume for MariaDB data

```yaml
db:
    volumes:
        - koha-db-data:/var/lib/mysql

volumes:
    koha-db-data:
```

Database data now survives `docker compose down` (without `-v`). Previously the DB was stored in an anonymous volume that Docker would remove on the next `down`, requiring a
full `do_all_you_can_do.pl` re-run on every restart.

---

### Changes made to `env/defaults.env`

| Variable added | Default | Purpose |
|---|---|---|
| `KOHA_DB_ROOT_PASSWORD` | `password` | MariaDB root password; forwarded to `MYSQL_ROOT_PASSWORD` in compose |
| `KOHA_IMAGE_TAG` | `kosson/koha-ubuntu:latest` | Docker Hub image tag; used by `image:` in compose |
| `ENABLE_PLUGINS` | `no` | Enables the plugin-install loop in `run.sh` when set to `yes` |

---

### Files changed

| File | Change |
|---|---|
| `Dockerfile` | PATH fix; stronger apt settings; `apt-install-retry` helper; all installs converted; CRLF normalization post-COPY; `CMD` directive |
| `files/run.sh` | Header note + version stamp; OpenSearch wait loop; ES/Zebra sed hacks; CRLF normalization for migration tools and .pl/.cgi; graceful koha-plack/koha-z3950 enable |
| `docker-compose.yml` | `image: ${KOHA_IMAGE_TAG}` for pull support; `MYSQL_ROOT_PASSWORD` parameterized; named `koha-db-data` volume |
| `env/defaults.env` | Added `KOHA_DB_ROOT_PASSWORD`, `KOHA_IMAGE_TAG`, `ENABLE_PLUGINS` |

---

## 2026-05-19 — Fix OpenSearch Dashboards routing through Traefik; add network diagnostic script

### Goal

Diagnose and fix a 502 Bad Gateway error when accessing OpenSearch Dashboards through Traefik, document the OpenSearch TLS certificate setup in `README.md`, and create a
comprehensive network diagnostic script for ongoing operational use.

---

### Problem: Dashboards returned 502 via Traefik

Traefik was proxying plain HTTP to the Dashboards container, but the container was listening on **HTTPS** (`server.ssl.enabled: true`). The Dashboards log showed:

```
SSL routines: tls_validate_record_header: http request
```

This is an `ERR_SSL_HTTP_REQUEST` — the container received an HTTP request on a port that expected TLS handshake bytes.

A secondary issue: `opensearch_security.cookie.secure: true` means the browser will only send the session cookie over HTTPS connections. Because Traefik acts as an HTTP proxy
(not TLS passthrough), the cookie would never be sent back, making login impossible even if the 502 were resolved at the TCP level.

---

### Fix 1 — Disable server-side TLS on Dashboards

**File:** `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml`

Disabled the server-facing TLS so that Dashboards listens on plain HTTP and Traefik's default HTTP proxy scheme works correctly. The Dashboards → OpenSearch **backend** TLS
(mutual authentication with the admin cert and root CA) remains fully active.

```yaml
# BEFORE
server.ssl.enabled: true
server.ssl.clientAuthentication: optional
server.ssl.certificate: /usr/share/opensearch-dashboards/config/dashboards.pem
server.ssl.key: /usr/share/opensearch-dashboards/config/dashboards-key.pem
opensearch_security.cookie.secure: true

# AFTER
server.ssl.enabled: false
# server.ssl.clientAuthentication: optional  (commented out)
# server.ssl.certificate: ...               (commented out)
# server.ssl.key: ...                       (commented out)
opensearch_security.cookie.secure: false
```

After this change the container log shows:
```
Server running at http://0.0.0.0:5601
```

---

### Fix 2 — Add explicit Traefik service labels for Dashboards

**File:** `OpenSearch-3.6/docker-compose.yml`

Without an explicit service name and port label, Traefik auto-detected the backend but used an incorrect scheme. Added a named service and the port to ensure correct HTTP
routing to port 5601.

```yaml
# Added to dashboards service labels:
- traefik.http.routers.dashboards.service=dashboards-svc
# Explicit port — required because server.ssl.enabled=false makes the container
# listen on plain HTTP; without this label Traefik may auto-detect the wrong port.
- traefik.http.services.dashboards-svc.loadbalancer.server.port=5601
```

---

### New file: `netcheck.sh`

A self-contained Bash diagnostic script that checks the entire stack's network connectivity in one pass. Run with:

```bash
cd koha-docker
bash netcheck.sh
```

Exit code: 0 = all passed, 1 = one or more failures.

The script reads environment from `env/.env`, `OpenSearch-3.6/.env`, and `traefik/.env`.
It performs 60 checks across 13 sections:

| Section | What is checked |
|---------|----------------|
| 1. Required tools | `docker`, `curl`, `nc`, `openssl`, `python3` |
| 2. Docker networks | Existence of `frontend`, `opensearch-36_osearch`, `knonikl`, `koha-docker_kohanet`; attached containers |
| 3. Container status | Running state and health for all 10 containers |
| 4. OpenSearch (host → os01:9200) | TCP :9200, cluster GREEN, 5 nodes, TLS cert expiry |
| 5. OpenSearch (Koha → os01:9200) | Cross-network TCP + HTTPS auth, `KOHA_ELASTICSEARCH` env |
| 6. MariaDB | `mysqladmin ping`, DB exists, table count, user exists, TCP from Koha |
| 7. Memcached | Container state, TCP from Koha, `stats` response |
| 8. Traefik | Internal ping, API, router registration for `koha-opac`/`koha-staff`/`dashboards`, port 80 |
| 9. Koha direct access | TCP + HTTP on :8080/:8081, Apache inside container, Plack process |
| 10. Koha via Traefik | Host-header routing for OPAC, Staff, Dashboards; DNS resolution |
| 11. OpenSearch Dashboards | TCP :5601, HTTP response |
| 12. Koha internals | `koha-conf.xml`, Zebra, Plack, `ELASTIC_SERVER` |
| 13. Network cross-check | Each container is attached to its required networks |

---

### README.md additions

- New section `## One-time setup — OpenSearch TLS certificates` (inserted before `## Prerequisites`). Covers: what files are pre-generated, cert validity (730 days), when/how to regenerate, warning about security plugin state on regeneration.
- Updated repository layout tree to include `opensearch_installer_vars.cfg` and   `opensearch_local_certificates_creator.sh`.

---

### Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml` | Disabled server TLS (`server.ssl.enabled: false`); disabled secure cookie |
| `OpenSearch-3.6/docker-compose.yml` | Added explicit Traefik service labels and port for the `dashboards` service |
| `netcheck.sh` | New file — comprehensive 13-section network diagnostic script |
| `README.md` | Added OpenSearch TLS certificate setup section; updated repo layout tree |

---

## 2026-05-20 — Single shared OpenSearch image for all cluster nodes

### Goal

Replace the five identical `build:` blocks in `OpenSearch-3.6/docker-compose.yml` (one per node) with a single named image so that Docker maintains only one image entry instead
of five.

---

### Problem

All five node services (`os01`–`os05`) had the same `build:` stanza pointing to the same `Dockerfile` with the same `OPEN_SEARCH_VERSION` build arg. Docker Compose names service
images after the project + service name (e.g., `opensearch-36-os01`, `opensearch-36-os02`, …), so `docker images` showed five separate entries even though the layers were byte-for-
byte identical. This wasted namespace, made cleanup harder, and caused `docker compose build` to run five separate build invocations (with cache hits from the second onwards, but still
redundant bookkeeping).

---

### Solution

Docker Compose supports specifying both `build:` and `image:` on the same service. When both are present, the built image is tagged with the `image:` name. Any other service that
lists the same `image:` value will use that already-built local image.

#### `OpenSearch-3.6/docker-compose.yml`

- **`os01`** — kept the `build:` block; added `image: kosson/opensearch-icu:${OPEN_SEARCH_VERSION}` alongside it. After `docker compose build os01`, the image is tagged as `kosson/opensearch-icu:3.6.0` (or whichever version is in `.env`).
- **`os02`–`os05`** — removed `build:` blocks entirely; replaced with:

  ```yaml
  image: kosson/opensearch-icu:${OPEN_SEARCH_VERSION}
  pull_policy: never
  ```

  `pull_policy: never` prevents Docker Compose from attempting to pull the image from a
  registry — it is a locally-built-only image and has not been pushed to Docker Hub.

#### `stack.sh`

- `build_opensearch()` now runs `docker compose build os01` instead of `docker compose build` (which would previously build all services that have a `build:` block).
- The `ok` confirmation message now reads the version from `OpenSearch-3.6/.env` via `_env_val` and prints `kosson/opensearch-icu:<version>`.
- Help text updated: `--build-opensearch` description now names the single image.

#### `README.md`

- Step 1 heading updated to singular ("Build the OpenSearch image").
- Build command changed to `docker compose build os01`.
- Description updated to explain the single-image / shared-reference pattern.
- Build options table entry for `--build-opensearch` updated to name `kosson/opensearch-icu`.

---

### Result

| Before | After |
|--------|-------|
| 5 image entries in `docker images` | 1 image entry (`kosson/opensearch-icu:3.6.0`) |
| `docker compose build` invoked for all 5 services | `docker compose build os01` only |
| Changing the Dockerfile required rebuilding 5 × | Rebuild once, all nodes pick it up automatically |

---

### Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/docker-compose.yml` | Added `image:` tag to `os01`; removed `build:` blocks from `os02`–`os05`; added `pull_policy: never` to `os02`–`os05` |
| `stack.sh` | `build_opensearch()` builds `os01` only; version read via `_env_val`; help text updated |
| `README.md` | Step 1 updated to reflect single-image approach |

---

## 2026-05-20 — Let's Encrypt / automatic public HTTPS via Traefik ACME

### Goal

Enable production-grade HTTPS with real, automatically-renewed certificates from Let's Encrypt for all public Traefik-exposed services (OPAC, Staff interface, OpenSearch Dashboards), while keeping local / offline development working unchanged with zero configuration.

---

### Architecture decision

The stack has two independent TLS layers. Only the public edge layer is affected by this change:

| Layer | Certificates | Change in this session |
|---|---|---|
| **Traefik edge** (browser ↔ Koha/Dashboards) | Let's Encrypt via ACME, or Traefik self-signed fallback | **Modified** |
| **OpenSearch internal** (node-to-node transport, admin API) | Self-signed with project-local CA, pre-generated in `assets/ssl/` | **Unchanged** |

OpenSearch internal certs cannot use Let's Encrypt because the mTLS identity is based on Distinguished Names (container hostnames like `os01`, `os02`) — not public domain names — and they authenticate node-to-node transport, which is never exposed to the internet.

---

### How it works

#### Conditional cert resolver pattern

Docker Compose labels cannot be conditionally present. The solution is to always define HTTPS router labels but make the `tls.certresolver` value an environment variable:

```yaml
- "traefik.http.routers.koha-opac-tls.tls.certresolver=${TLS_CERTRESOLVER:-}"
```

| `TLS_CERTRESOLVER` value | Effect |
|---|---|
| *(empty, default)* | Traefik's `tls.certresolver` is an empty string → Traefik uses its self-signed fallback cert; no ACME calls are made |
| `letsencrypt` | Traefik's ACME client contacts Let's Encrypt, issues a certificate for the router's `Host()` rule, and stores it in `acme.json` |

This means the stack is always HTTPS-capable (port 443 is always open), but only makes ACME requests when the operator explicitly opts in.

#### ACME configuration placement

The ACME parameters are passed as CLI flags via the `command:` block in `traefik/docker-compose.yaml`. This is more reliable than the static `traefik.yaml` because:
- Docker Compose env var substitution (`${ACME_EMAIL:-}`) is fully supported in the `command:` block
- No need to manage two config files with overlapping responsibilities

#### Certificate storage

A named Docker volume `traefik_certs` is mounted at `/var/traefik/certs/` inside the Traefik container. Traefik writes `acme.json` there. The volume persists across Traefik restarts and image updates.

#### HTTP → HTTPS redirect

The `redirect-to-https` middleware is defined in the Koha service labels but is **not applied** by default (the router middleware lines are commented out). This is intentional: enabling the redirect before Let's Encrypt certs are confirmed working creates a redirect loop that blocks the HTTP-01 challenge (which needs plain HTTP on port 80).

Operator workflow:

1. Enable `TLS_CERTRESOLVER=letsencrypt` and start the stack.
2. Confirm `https://` URLs work with a valid cert.
3. Uncomment the two redirect middleware lines in `docker-compose.yml`.
4. Restart the Koha service.

---

### Changes made

#### `traefik/.env`

Added `ACME_EMAIL` variable after `TRAEFIK_DASHBOARD_PORT`:

```bash
# ── Let's Encrypt (ACME) ─────────────────────────────────────────────────────
# Contact email for Let's Encrypt certificate registration.
# Requirements: valid monitored address; port 80 internet-reachable; real public
# KOHA_DOMAIN; TLS_CERTRESOLVER=letsencrypt in env/.env AND OpenSearch-3.6/.env.
# Leave empty for local/offline development (Traefik uses self-signed fallback).
ACME_EMAIL=
```

#### `traefik/docker-compose.yaml`

Added `command:` block to pass ACME resolver configuration as CLI flags:

```yaml
command:
  - "--configFile=/etc/traefik/traefik.yaml"
  - "--certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL:-}"
  - "--certificatesresolvers.letsencrypt.acme.storage=/var/traefik/certs/acme.json"
  - "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web"
```

Activated the previously-commented `traefik_certs` volume mount and volume definition:

```yaml
volumes:
  - traefik_certs:/var/traefik/certs/:rw

volumes:
  traefik_certs:
    driver: local
```

#### `env/.env`

Added `TLS_CERTRESOLVER` block at the end of the file:

```bash
# ── TLS / Let's Encrypt ───────────────────────────────────────────────────────
# (empty)     → Traefik self-signed fallback cert; no LE requests
# letsencrypt → Let's Encrypt cert acquisition for all websecure routers
# Prerequisites: ACME_EMAIL in traefik/.env, port 80 reachable, real KOHA_DOMAIN,
# same value in OpenSearch-3.6/.env
# NOTE: OpenSearch internal certs always self-signed — LE cannot replace them.
TLS_CERTRESOLVER=
```

#### `OpenSearch-3.6/.env`

Added `DASHBOARDS_DOMAIN` and `TLS_CERTRESOLVER` variables:

```bash
DASHBOARDS_DOMAIN=dashboards.localhost
TLS_CERTRESOLVER=
```

`DASHBOARDS_DOMAIN` makes the Dashboards hostname configurable (previously hardcoded in compose labels). For production, set both to real values:

```bash
DASHBOARDS_DOMAIN=dashboards.library.example.com
TLS_CERTRESOLVER=letsencrypt
```

#### `docker-compose.yml` (Koha stack)

Added HTTPS routers for OPAC and Staff after the existing HTTP routers:

```yaml
# ── HTTPS routers (websecure / :443) ──────────────────────────────
- "traefik.http.routers.koha-opac-tls.rule=Host(`${KOHA_INSTANCE}${KOHA_DOMAIN}`)"
- "traefik.http.routers.koha-opac-tls.entrypoints=websecure"
- "traefik.http.routers.koha-opac-tls.tls=true"
- "traefik.http.routers.koha-opac-tls.tls.certresolver=${TLS_CERTRESOLVER:-}"
- "traefik.http.routers.koha-opac-tls.service=koha-opac-svc"
- "traefik.http.routers.koha-staff-tls.rule=Host(`${KOHA_INSTANCE}${KOHA_INTRANET_SUFFIX}${KOHA_DOMAIN}`)"
- "traefik.http.routers.koha-staff-tls.entrypoints=websecure"
- "traefik.http.routers.koha-staff-tls.tls=true"
- "traefik.http.routers.koha-staff-tls.tls.certresolver=${TLS_CERTRESOLVER:-}"
- "traefik.http.routers.koha-staff-tls.service=koha-staff-svc"
# ── HTTP → HTTPS redirect (optional, disabled by default) ─────────
- "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
- "traefik.http.middlewares.redirect-to-https.redirectscheme.permanent=true"
# - "traefik.http.routers.koha-opac.middlewares=redirect-to-https"
# - "traefik.http.routers.koha-staff.middlewares=redirect-to-https"
```

#### `OpenSearch-3.6/docker-compose.yml`

Updated Dashboards HTTP router to use the new `DASHBOARDS_DOMAIN` variable instead of a hardcoded value, and added an HTTPS router:

```yaml
- traefik.http.routers.dashboards.rule=Host(`${DASHBOARDS_DOMAIN:-dashboards.localhost}`)
...
- traefik.http.routers.dashboards-tls.rule=Host(`${DASHBOARDS_DOMAIN:-dashboards.localhost}`)
- traefik.http.routers.dashboards-tls.entrypoints=websecure
- traefik.http.routers.dashboards-tls.tls=true
- traefik.http.routers.dashboards-tls.tls.certresolver=${TLS_CERTRESOLVER:-}
- traefik.http.routers.dashboards-tls.service=dashboards-svc
```

#### `stack.sh`

Added four new config variable reads:

```bash
TRAEFIK_HTTPS_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTPS_PORT 443)"
ACME_EMAIL="$(_env_val "${TRAEFIK_DIR}/.env" ACME_EMAIL "")"
DASHBOARDS_DOMAIN="$(_env_val "${OPENSEARCH_DIR}/.env" DASHBOARDS_DOMAIN "dashboards.localhost")"
TLS_CERTRESOLVER="$(_env_val "${KOHA_ENV_FILE}" TLS_CERTRESOLVER "")"
```

Updated `follow_logs()` access banner: when `TLS_CERTRESOLVER` is non-empty, the HTTPS protocol (`https://`) and HTTPS port suffix are used for the displayed URLs; Dashboards URL uses `${DASHBOARDS_DOMAIN}`.

---

### To enable Let's Encrypt in production

```bash
# traefik/.env
ACME_EMAIL=admin@library.example.com

# env/.env
KOHA_DOMAIN=.library.example.com
TLS_CERTRESOLVER=letsencrypt

# OpenSearch-3.6/.env
DASHBOARDS_DOMAIN=dashboards.library.example.com
TLS_CERTRESOLVER=letsencrypt

# Then
./stack.sh start
```

After the stack is running and HTTPS is confirmed working, optionally enable the HTTP→HTTPS redirect by uncommenting two lines in `docker-compose.yml` (see README for details).

---

### Files changed

| File | Change |
|---|---|
| `traefik/.env` | Added `ACME_EMAIL=` block with prerequisites documentation |
| `traefik/docker-compose.yaml` | Added `command:` with ACME CLI flags; activated `traefik_certs` volume |
| `env/.env` | Added `TLS_CERTRESOLVER=` at end with explanation |
| `OpenSearch-3.6/.env` | Added `DASHBOARDS_DOMAIN=dashboards.localhost` and `TLS_CERTRESOLVER=` |
| `docker-compose.yml` | Added `koha-opac-tls` / `koha-staff-tls` HTTPS routers; defined `redirect-to-https` middleware (disabled by default) |
| `OpenSearch-3.6/docker-compose.yml` | Dashboards hostname configurable via `DASHBOARDS_DOMAIN`; added `dashboards-tls` HTTPS router |
| `stack.sh` | Added `TRAEFIK_HTTPS_PORT`, `ACME_EMAIL`, `DASHBOARDS_DOMAIN`, `TLS_CERTRESOLVER` reads; startup banner shows `https://` when TLS is active |
| `README.md` | Added `TLS_CERTRESOLVER` to config table; rewrote TLS certificate quick-setup note; updated service URL table with HTTPS column; updated Traefik port config section; added full `## Let's Encrypt — automatic public HTTPS` section; split `## TLS certificate verification` section to clarify OpenSearch vs public HTTPS scope |
