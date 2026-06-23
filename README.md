# Koha Docker containers

This is a setup of Docker containers created to work with the latest Koha ILS. Some very sound patterns and ideas were taken from the work done for the project at [koha-testing-docker (a.k.a. KTD)](https://gitlab.com/koha-community/koha-testing-docker). All the heavy lifting was done using AI agents via a Github subscription. Most of the avatars during development can be tracked if you look into the TRACKER.md file. The working version of Koha is 26.

Use the source code as is. Remember this is a development project to experiment with Koha, to migrate data, etc. This is not a production suite.

This setup creates a self-contained Docker Compose environment for **Koha ILS** development, backed by **MariaDB 10.11** and an external **OpenSearch 3.6** cluster.

You need to have a fairly well endowed computer to run these services. All the final product will need around 12Gb of RAM to run comfortably. The RAM of your computer needs to be at least 22Gb, which is not that rare these days. You need to activate virtualization in BIOS so that some cores of your processors may be "borrowed" for the containers we raise for each of the components. Also, you need to have a good Internet connection.

Koha needs a database (MariaDB), a caching mechanism (Memcache), an indexing engine (OpenSearch), and a proxy for accessing the installation in the browser (Traefik).

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Docker Engine | 24+ | `docker --version` |
| Docker Compose (plugin) | v2.20+ | `docker compose version` |
| Available disk space | ≥ 15 GB | Images + Koha source + OS data |
| Host user UID | **1000** | The Koha source dir must be owned by UID 1000 |

### Rootless Docker note

If Docker runs in rootless mode, two startup failures can occur out of the box.

**1. Privileged port bind failure (Traefik)**

Startup fails while starting Traefik:

```txt
cannot expose privileged port 80
net.ipv4.ip_unprivileged_port_start=1024
```

Fix: use non-privileged ports in `traefik/.env` — this is already the default in this repo (`TRAEFIK_HTTP_PORT=8000`, `TRAEFIK_HTTPS_PORT=8443`). Keep `KOHA_PUBLIC_PORT` in `env/.env` aligned with `TRAEFIK_HTTP_PORT`. If you need ports 80/443, lower the kernel threshold: `sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80`.

**2. Unlimited memlock rlimit failure (OpenSearch)**

Startup fails while creating any OpenSearch container:

```txt
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: error during container init:
error setting rlimits for ready process: error setting rlimit type 8: operation not permitted
```

`rlimit type 8` is `RLIMIT_MEMLOCK`. Rootless containers cannot set it to unlimited (`-1`). This is already fixed in this repo: all OpenSearch nodes use `bootstrap.memory_lock=false` and have no `memlock` ulimit entry. If you see this error after reverting or editing the compose file, ensure no `memlock:` block exists under `ulimits:` in `OpenSearch-3.6/docker-compose.yml`.

Quick check:

```bash
docker info --format '{{json .SecurityOptions}}'
sysctl net.ipv4.ip_unprivileged_port_start
```

## Security-critical environment variables

Rename the template.env file to `.env` before starting the stack for the first time. Open the `env/.env` file and change every variable marked below. Leaving any of them at the default value is safe only on a local throwaway machine with no external network access.

| Variable | Where | Default (insecure) | What to set |
|---|---|---|---|
| `KOHA_DB_ROOT_PASSWORD` | `env/.env` | `password` | Strong password for the MariaDB `root` account. Flows to `MYSQL_ROOT_PASSWORD` on the `db` container **and** to `/etc/mysql/koha-common.cnf` inside the Koha container. Must match on both sides — see [Changing the root password on an existing stack](#important-changing-the-password-on-an-existing-stack) in `TRACKER.md` if rotating after first start. |
| `KOHA_DB_PASSWORD` | `env/.env` | `password` | Password for the `koha_kohadev` MariaDB application user. |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | `env/.env` **and** `OpenSearch-3.6/.env` | `test@Cici24#ANA` | OpenSearch cluster `admin` password. **Must be identical in both files.** If you change it, re-run `OpenSearch-3.6/opensearch_local_certificates_creator.sh` to update the bcrypt hash in `internal_users.yml`, then wipe the OS data dirs and restart the cluster. |
| `ELASTIC_OPTIONS` | `env/.env` | contains `admin:test@Cici24#ANA` | Update the `<userinfo>admin:YOUR_PASSWORD</userinfo>` element to match `OPENSEARCH_INITIAL_ADMIN_PASSWORD`. |
| `KOHA_PASS` | `env/.env` | `koha` | Password for the Koha superlibrarian web account. |

> **OpenSearch password consistency:** `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in `env/.env`, the `<userinfo>` value inside `ELASTIC_OPTIONS`, and `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in `OpenSearch-3.6/.env` must all carry the same password. A mismatch causes the Koha container to fail the OpenSearch health check at startup.

More on the `Configuring the environment variables` section down bellow.

---

## Quick setup

Everything you need to go from a fresh clone to a running Koha stack. Each step links to the relevant section for full details. If any of these operations went wrong, there is a section bellow on how to start all the services manually.

### 1. Verify prerequisites

Docker Engine 24+ and Docker Compose v2.20+ must be installed. Your host user must have **UID 1000** (the bind-mounted Koha source directory must be owned by that UID).
First, go to the [Prerequisites](#prerequisites) section and read it carefully. Install and configure all the necessary software.

### 2. Clone the Koha source tree

Clone the Koha source into `koha-docker/koha/` **as the host user (UID 1000)**:

```bash
cd koha-docker
git clone --depth=1 https://git.koha-community.org/Koha-community/Koha.git koha
```

The directory is bind-mounted into the container at `/kohadevbox/koha`. The container user `kohadev-koha` runs as UID 1000, so file ownership must match. The versions that this solution works with are Koha 25 and 26.

### 3. Configure `env/.env`

Some of the settings were mentioned above in `Security-critical environment variables` section. Rename the template.env file to `.env`. Open `env/.env` and update **at minimum** these two values:

| Variable | What to change |
|---|---|
| `SYNC_REPO` | Set to the **absolute path** on your host to the `koha/` directory cloned above — e.g. `/home/youruser/koha-docker/koha` |
| `KOHA_DOMAIN` | Change to `.<ip>.nip.io` for zero-config portable DNS — the simplest choice is `.127.0.0.1.nip.io`, which makes the OPAC reachable at `http://kohadev.127.0.0.1.nip.io` with no `/etc/hosts` edits |

Everything else has workable defaults. See [Initial configuration](#initial-configuration). You MUST modify `SYNC_REPO` to reflect the path on your machine.

#### OpenSearch cluster forming details

First, create the necessary credential files. Run the `opensearch_local_certificates_creator.sh` script. This script will take into consideration the existing environment variables, and based on that will generate the necessary certificate files in the `./OpenSearch-3.6/assets/ssl` subfolder. At the moment of first run, the `.OpenSearch-3.6/assets/opensearch/data` subfolder will be created containing the corresponding data for each node of the cluster.

The following details are useful in case you run into trouble with the OpenSearch cluster.
If you modified the password used for OpenSearch, this meaning the values of `ELASTIC_OPTION` and as a consequence also the value of `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in the `env/.env` file, you need to make sure you modify the value of `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in the `.env` file in the OpenSearch-3.6 subfolder. Remember that if you have modified the password for the aforementioned environment variables you MUST run the `opensearch_local_certificates_creator.sh` script. Otherwise, the cluster is not forming. Node `os01` errors out. Create also the `OpenSearch-3.6/assets/ssl` subfolder if not found.

Requirments for a viable password for OpenSearch:

- minimum length 10
- uppercase + lowercase + digit + special character

**OpenSearch password:** `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in `env/.env` file and `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in the `OpenSearch-3.6/.env` file must match. Both files ship with the same default value: `test@Cici24#ANA`. Verify also the `./OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml` file to hve the same password: `opensearch.password: "test@Cici24#ANA"`. Otherwise you will get into a credential drift, and your OpenSearch cluster will not form.

#### OpenSearch credential drift note (important)

If `OPENSEARCH_INITIAL_ADMIN_PASSWORD` is changed in one place but not fully synced, `os01` may stay running but become `unhealthy` (healthcheck gets HTTP 401), and `dashboards` will fail to start because `depends_on` waits for `os01` health.

First delete all data associated with the OpenSearch cluster. Being positioned in the OpenSearch-3.6 folder run the command:

```bash
bash ./restart-to-clear-cluster.sh
```

This will clear all data of the previous cluster in the `./OpenSearch-3.6/assets/opensearch/data`. Will delete also all the certificates generated by running `opensearch_local_certificates_creator.sh`. Mind that the `./OpenSearch-3.6/.env` values will not be deleted. Be very thorough with this. It is usually the source of errors when forming the OpenSearch cluster. Now you are on a fresh start. Recreate the credentials first and check to see if the `./OpenSearch-3.6/assets/ssl` subfolder has been populated.

Keep these values aligned every time you rotate credentials:

- `env/.env` -> `OPENSEARCH_INITIAL_ADMIN_PASSWORD`
- `OpenSearch-3.6/.env` -> `OPENSEARCH_INITIAL_ADMIN_PASSWORD`
- `env/.env` -> `ELASTIC_OPTIONS` (`<userinfo>admin:...`)
- `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml` -> `opensearch.password`

After changing credentials, apply and refresh:

```bash
cd OpenSearch-3.6
set -a && source .env && set +a && bash initial_api_calls.sh
docker compose up -d --force-recreate os01
docker compose ps os01 dashboards
```

Recommended check after you start all the services:

```bash
bash tests/test_opensearch_os01_auth_integration.sh
```

As a rule of thumb it is wise to start the OpenSearch cluster. If it forms well, procede with the rest.

### 4. Start the stack

There are two methods. First, the recommended one is to build the images local. This implies running the following command which builds the `kosson/opensearch-icu` and `kosson/koha-ubuntu` images, then starts all services:

```bash
./stack.sh start --build
```

The second method is to run:

```bash
./stack.sh start
```

this will take care of all the operations needed to start.

#### Possible issues/errors at the first start

If you see this error during startup:

```log
── Recreating Koha database ──
[hh:mm:ss] Dropping and recreating 'koha_kohadev'...
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)
```

it means the MariaDB root password used by the script does not match the password stored in the current `koha-db-data` volume.

Quick checks and recovery:

1. Verify `KOHA_DB_ROOT_PASSWORD` in `env/.env`.
2. If the volume was created with an older password, either:

- restore that old password in `env/.env`, or
- run `./stack.sh reset` (destructive: removes DB/OpenSearch volumes) and start fresh.

`stack.sh` now uses `KOHA_DB_ROOT_PASSWORD` from `env/.env` for DB readiness and recreate steps; rerunning the same command without fixing password drift will not solve the issue.

#### Resuming after a machine reboot or a normal stop

The `koha-db-data` volume persists across reboots and `./stack.sh stop`. Use `--no-fresh-db` to resume without wiping the database:

```bash
./stack.sh start --no-fresh-db
```

> If you forget `--no-fresh-db` and run a plain `./stack.sh start` after a reboot, the database will be dropped and rebuilt from scratch, losing any data entered since the last `./stack.sh start --build` or `./stack.sh reset`. Only use the plain `./stack.sh start` (or `./stack.sh restart`) when you intentionally want a clean slate.

`stack.sh` waits for each service health check before proceeding and tails the logs automatically. Startup takes **3–8 minutes** on first run depending on hardware. When Koha is ready, a summary box is printed with all URLs and credentials.

Look into the structure of the management script: [Automated startup — `stack.sh`](#automated-startup----stacksh)

If you get the following error `IPv4 forwarding is disabled. Networking will not work.` whicj was signaled on a Linux Mint, then you need to edit `/etc/sysctl.conf` file, find the line which contains `net.ipv4.ip_forward=1` and uncomment. Run `sudo sysctl -p` commmand to reload the settings. Better: `systemctl restart network`.

### 5. Open Koha in the browser

With `KOHA_DOMAIN=.127.0.0.1.nip.io` (the recommended quick-start value):

| Service | URL | Credentials |
|---|---|---|
| OPAC (public catalogue) | http://kohadev.127.0.0.1.nip.io | — (public) |
| Staff interface | http://kohadev-intra.127.0.0.1.nip.io | `koha` / `koha` |
| OpenSearch Dashboards | http://dashboards.localhost | `admin` / *see `env/.env`* |
| Traefik dashboard | http://localhost:8083 | — |
| OpenSearch REST API | https://localhost:9200 | `admin` / *see `env/.env`* |

Look into the section [Accessing the stack](#accessing-the-stack).

### TLS certificates

The project has two independent TLS layers:

| Layer | What it secures | How certificates are provided |
|---|---|---|
| **OpenSearch cluster** | Node-to-node transport, admin API, Dashboards → OpenSearch backend | Self-signed certs, **pre-generated and committed** to the repo. No action needed on a fresh clone. See [One-time setup — OpenSearch TLS certificates](#one-time-setup--opensearch-tls-certificates). |
| **Public HTTPS** (Traefik edge) | Browser → OPAC, Browser → Staff interface, Browser → Dashboards | Let's Encrypt via ACME, or Traefik self-signed fallback. See [Let's Encrypt — automatic public HTTPS](#lets-encrypt--automatic-public-https). |

> **Why these are separate**: OpenSearch internal certs use Distinguished Name (DN) identity for mutual TLS between containers — Let's Encrypt domain-validation cannot and should not replace them. Traefik terminates public HTTPS at the edge; the backend connections use the self-signed OpenSearch CA.

---

## Configuring the environment variables

This section manages all the environment varaibles set for this project to run.

### Initial configuration

All settings live in **`env/.env`**. Rename the template.env file to `.env`. Copy or review the file before the first start.
Critical values to verify:

#### Identity and paths

| Variable | Default | Description |
|---|---|---|
| `LOCAL_USER_ID` | `1000` | Must match the UID that owns the `koha/` source directory on the host |
| `SYNC_REPO` | `/media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/koha` | **Absolute path on the host** to the Koha source tree |
| `KOHA_INSTANCE` | `kohadev` | Name of the Koha instance created inside the container |

#### Domain and ports

| Variable | Default | Description |
|---|---|---|
| `KOHA_DOMAIN` | `.myDNSname.org` | DNS domain suffix. Change to `.<ip>.nip.io` (e.g. `.127.0.0.1.nip.io`) for zero-config portable access — see **Accessing the stack** below |
| `KOHA_INTRANET_SUFFIX` | `-intra` | Staff interface hostname becomes `kohadev-intra.myDNSname.org` |
| `KOHA_OPAC_PORT` | `8080` | OPAC port exposed on the host (internal Apache port, also used by Traefik backend) |
| `KOHA_INTRANET_PORT` | `8081` | Staff interface port exposed on the host (internal Apache port) |
| `KOHA_PUBLIC_PORT` | `80` | **Public-facing HTTP port served by Traefik.** URLs stored in the Koha database (`OPACBaseURL`, `staffClientBaseURL`) use this port. Port 80 is the default for HTTP and is omitted from URLs — so links in Koha pages will not contain `:8080`. Change to match `TRAEFIK_HTTP_PORT` if Traefik runs on a non-standard port (e.g. `8000`). |
| `TLS_CERTRESOLVER` | *(empty)* | Certificate resolver name for Traefik HTTPS routers. Set to `letsencrypt` to request automatic certificates from Let's Encrypt. Requires `ACME_EMAIL` set in `traefik/.env`, a publicly reachable port 80, and a real public `KOHA_DOMAIN`. Leave empty for local dev — Traefik falls back to a self-signed certificate for HTTPS while HTTP continues to work normally. Also set the same value in `OpenSearch-3.6/.env` for the Dashboards service. |

#### Demo data

| Variable | Default | Description |
|---|---|---|
| `LOAD_DEMO_DATA` | `yes` | `yes` — load 436 sample MARC bibliographic records, authority records, items, and patron data during first startup (via `misc4dev/insert_data.pl`). `no` — skip sample data; the catalogue is empty and only the superlibrarian account is created. Override at runtime with `./stack.sh start --no-demo-data` or `--with-demo-data`. |

#### Database

| Variable | Default | Description |
|---|---|---|
| `DB_IMAGE` | `mariadb:10.11` | MariaDB image |
| `DB_HOSTNAME` | `db` | Hostname of the MariaDB container |
| `KOHA_DB_ROOT_PASSWORD` | `password` | Root password for the MariaDB container. Shared between the `db` service (`MYSQL_ROOT_PASSWORD`) and the Koha container (`/etc/mysql/koha-common.cnf`). **Change before first start** — see [Security-critical environment variables](#security-critical-environment-variables). |
| `KOHA_DB_PASSWORD` | `password` | Password for the `koha_kohadev` database user. **Change before first start.** |

#### Koha container image

| Variable | Default | Description |
|---|---|---|
| `KOHA_IMAGE_TAG` | `kosson/koha-ubuntu:latest` | Docker Hub image tag used by the `koha` service in `docker-compose.yml` |

The `koha` service in `docker-compose.yml` uses `pull_policy: missing`, which means:

| Situation | What Docker Compose does |
|---|---|
| Image tag is already in the local Docker cache | Use it — no network call |
| Image tag is **not** in the local cache | Pull from Docker Hub (`kosson/koha-ubuntu`) |
| Pull fails (tag not published, no network) | Fall back to building from the local `Dockerfile` |

This lets you use the pre-built image from [Docker Hub](https://hub.docker.com/repository/docker/kosson/koha-ubuntu) on any machine without needing to run a local build, while still allowing a local build as a fallback.

To pin to a specific released version instead of `latest`, set in `env/.env`:

```bash
KOHA_IMAGE_TAG=kosson/koha-ubuntu:latest
```

To force Docker Compose to re-check the Hub for a newer `latest` (bypassing the local cache):

```bash
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  pull koha
```

#### OpenSearch connection

| Variable | Value | Description |
|---|---|---|
| `KOHA_ELASTICSEARCH` | `yes` | Enables OpenSearch-backed search in Koha |
| `ELASTIC_SERVER` | `https://os01:9200` | URL of the OpenSearch cluster manager — **no credentials in the URL** |
| `ELASTIC_OPTIONS` | *(see below)* | Extra XML elements injected into `koha-conf.xml`'s `<elasticsearch>` block |
| `PERL_LWP_SSL_VERIFY_HOSTNAME` | `0` | Disables LWP TLS certificate verification (dev only) |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | `"test@Cici24#ANA"` | Must match the password set in `OpenSearch-3.6/.env` |

Current `ELASTIC_OPTIONS` value (all on one line in `env/.env`):

```txt
ELASTIC_OPTIONS=<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options><userinfo>admin:test@Cici24#ANA</userinfo><client_version>7</client_version>
```

Each XML element maps to a keyword argument passed to `Search::Elasticsearch->new()`:

| Element | Purpose |
|---|---|
| `<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>` | Disables IO::Socket::SSL certificate verification in the HTTP::Tiny backend |
| `<userinfo>admin:test@Cici24#ANA</userinfo>` | Passes credentials as a raw string so special chars (`@`, `#`) are base64-encoded correctly — **do not put credentials in the URL** |
| `<client_version>7</client_version>` | Bypasses the Elasticsearch 8.x product check that rejects OpenSearch (`x-elastic-product: OpenSearch` ≠ `Elasticsearch`) |

#### OpenSearch cluster settings

Edit `OpenSearch-3.6/.env` to change the cluster version or admin password:

```bash
OPEN_SEARCH_VERSION=3.6.0
OPENSEARCH_INITIAL_ADMIN_PASSWORD="test@Cici24#ANA"
```

The admin password must match `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in `koha-docker/env/.env`.

The OpenSearch cluster requires mutual TLS between all nodes, the admin client, and the Dashboards container. The necessary certificates are **pre-generated and committed** to the repository under `OpenSearch-3.6/assets/ssl/`:

```txt
root-ca.pem / root-ca-key.pem      ← self-signed root CA
admin.pem   / admin-key.pem        ← admin client cert (used by securityadmin.sh)
os01–os05.pem / os01–os05-key.pem  ← per-node transport + HTTP certs
client.pem  / dashboards.pem …     ← client and Dashboards certs
```

These files are mounted into each container at startup — **no certificate generation happens during `stack.sh start` or `docker compose up`**.

##### When to regenerate the certificates

The certificates are valid for **730 days (2 years)** from the date they were first created. You also need to regenerate them if:

- you are setting up the project on a new machine with a different hostname or organisation
- the existing certs have expired and OpenSearch refuses to start
- you ran `./stack.sh reset` and want a genuinely fresh cluster

##### How to regenerate the certificates

> **Warning:** regenerating certificates also regenerates the **compliance salt** and **SQL datasource master key** written into each node’s `opensearch.yml`. Any encrypted datasource credentials stored in an existing cluster become unreadable. Only do this on a fresh or fully-reset cluster.

```bash
cd koha-docker/OpenSearch-3.6

# Optional: edit subject fields (country, org, etc.) before running
# nano opensearch_installer_vars.cfg

sudo bash opensearch_local_certificates_creator.sh
```

The script will:

1. Create `assets/ssl/root-ca-key.pem` + `root-ca.pem` (self-signed root CA, 2048-bit RSA, SHA-256, 730-day validity)
2. Create `admin.pem` / `admin-key.pem` (PKCS8, signed by the root CA)
3. Create per-node certs for `os01`–`os05`, `client`, and `dashboards` — each with a `subjectAltName=DNS:<nodename>` extension so TLS hostname verification passes
4. Generate a fresh random **compliance salt** (16-char alphanumeric) and **SQL master key** (16-byte hex) and write them into every `assets/opensearch/config/os*/opensearch.yml`
5. Set strict file permissions: `600` on all `.pem` files, `700` on config directories, `600` on config files

After regenerating, rebuild the OpenSearch images (they bake the certs in) and do a full restart:

```bash
./stack.sh start --build-opensearch
```

#### Certificate subject configuration

The subject DN and output paths are defined in `OpenSearch-3.6/opensearch_installer_vars.cfg`:

```bash
CERT_DN="/C=RO/ST=ILFOV/L=MAGURELE/O=NIPNE/OU=DFCTI"
LOCAL_ROOT_CA="localrootca"
ADMIN_CA="admin"
OS_CERTS_PATH="./assets/ssl"
```

Change `CERT_DN` to match your organisation before running the script on a new deployment.

---

## Automated startup — `stack.sh`

The script `stack.sh` in the project root handles the entire lifecycle of the project. It wraps all five manual steps below into single commands, waits for health checks between stages, and prints a summary box with URLs and credentials when the stack is ready.

The following subcommands and options are available:

```bash
# First run — build both image sets, then start everything
./stack.sh start --build

# Subsequent runs — start without rebuilding
./stack.sh start

# After a code change — quick restart (OpenSearch stays up, DB is reset)
./stack.sh restart

# Start without wiping the database
./stack.sh start --no-fresh-db

# Start in the background (no log tailing)
./stack.sh start --no-logs

# Stop everything (containers stay; named volumes are preserved)
./stack.sh stop

# Nuclear reset — remove all containers AND named volumes (images kept)
./stack.sh reset

# Check what is running + OpenSearch cluster health
./stack.sh status

# Attach to Koha startup logs at any time
./stack.sh logs
```

### Build options

| Flag | Effect |
|---|---|
| `--build` | Rebuild both OpenSearch and Koha images before starting |
| `--build-opensearch` | Rebuild the single `kosson/opensearch-icu` image (analysis-icu plugin) |
| `--build-koha` | Rebuild only the Koha dev container image |

> **Important:** `files/run.sh` is copied into the Docker image at build time — it is **not** mounted at runtime. Any change to `run.sh` (including `KOHA_PUBLIC_PORT` or `LOAD_DEMO_DATA` logic) takes effect only after rebuilding with `./stack.sh start --build-koha`.

### Demo data options

| Flag | Effect |
|---|---|
| `--with-demo-data` | Load 436 sample MARC bibliographic records, authority records, items, and patron data (default) |
| `--no-demo-data` | Skip sample data — start with an empty catalogue (superlibrarian account only) |

These flags work with both `start` and `restart`:

```bash
./stack.sh start --no-demo-data      # Fresh install, empty catalogue
./stack.sh restart --with-demo-data  # Reset and reload demo data
```

### What `start` subcommand does internally

1. Verifies prerequisites (`docker`, `docker compose`, `env/.env`).
2. Optionally rebuilds images.
3. Starts the OpenSearch cluster (`docker compose up -d` in `OpenSearch-3.6/`).
4. Polls `/_cluster/health` until status is `"green"` (up to 6 minutes).
5. Starts MariaDB and Memcached; waits for `mysqladmin ping` to succeed.
6. Drops and recreates the `koha_kohadev` database (skipped with `--no-fresh-db`).
7. Starts the Koha container with `--force-recreate`.
8. Tails the logs and prints a ready banner when the "started up" line appears.

### `restart` subcommand

`restart` is for quick iteration when OpenSearch is already running. It resets the database and re-creates only the Koha container — OpenSearch and MariaDB are not restarted.

```bash
./stack.sh restart                # Reset DB + recreate Koha
./stack.sh restart --no-fresh-db  # Recreate Koha only (keep existing data)
```

## Restarting after a machine reboot

When the host machine is rebooted the `koha-db-data` Docker volume persists — the database is still fully populated. Starting the stack as usual with `./stack.sh start` would drop and recreate the database (default `FRESH_DB=true` behaviour). To resume where you left off **without wiping your data**, always use `--no-fresh-db`:

```bash
./stack.sh start --no-fresh-db
```

`run.sh` contains an auto-detection probe that queries `information_schema.tables` for the Koha tables (`systempreferences`, `borrowers`). If they are found it automatically passes `--use-existing-db` to `do_all_you_can_do.pl`, which skips the fresh-install path and reuses the existing schema. If `USE_EXISTING_DB=yes` is already set in the environment (as `stack.sh --no-fresh-db` exports it), the probe is skipped entirely for speed.

> **Why this matters:** without this detection, a plain `docker compose up` or `./stack.sh start` on a machine with an existing database volume would cause the Koha container to exit immediately with `Database is not empty! at do_all_you_can_do.pl line 89` (exit code 255), and the stack would not come up at all.

### `reset` command

`reset` performs a **full teardown** of the entire stack — all containers are removed and all named Docker volumes are deleted. This is the equivalent of starting completely from scratch.

> **Destructive — requires confirmation.** The MariaDB data volume (`koha-db-data`), all OpenSearch index volumes, and Traefik state are permanently removed. Docker images are **not** deleted.

```bash
./stack.sh reset
```

The command will prompt:

```log
[WARN] This will stop ALL containers, remove them, and delete ALL named volumes.
[WARN] Database data, OpenSearch indices, and Traefik state will be permanently lost.
[WARN] Docker images will be preserved.

Type 'yes' to confirm:
```

Type `yes` and press Enter to proceed; anything else cancels without making any changes.

After a successful reset, run a full start to reinitialise everything:

```bash
./stack.sh start          # start with demo data (default)
./stack.sh start --build  # also rebuild images before starting
```

**When to use `reset` vs `stop`:**

| Command | Containers | Named volumes | Use when |
|---|---|---|---|
| `stop` | Stopped (kept) | Preserved | Normal end-of-day shutdown; resume with `start --no-fresh-db` |
| `reset` | Removed | **Deleted** | Database is corrupt, you want a clean slate, or you are reclaiming disk space |

---

## Regression tests — `tests/`

The `tests/` directory contains a small TAP-format shell test suite. The tests guard against known regressions and can be run without a running stack (except the integration test, which auto-skips when the stack is down).

```bash
# Run the full suite from the koha-docker/ directory
bash tests/run_all_tests.sh
```

Expected output when the stack is not running:

```log
=== test_run_sh_static.sh ===
ok 1 - …
…
1..13
PASS: 13  FAIL: 0

=== test_db_detection_unit.sh ===
ok 1 - …
…
1..7
PASS: 7  FAIL: 0

=== test_restart_integration.sh ===
ok 1 - db container is running # SKIP stack not running
ok 2 - koha restarts without exit-255 # SKIP stack not running
ok 3 - koha startup banner appears # SKIP stack not running
1..3
PASS: 0  FAIL: 0  SKIP: 3

All test suites passed (or skipped).
```

### Test files

| File | Type | What it checks |
|---|---|---|
| `tests/test_run_sh_static.sh` | Static (grep) | 13 assertions that the DB auto-detection fix is correctly present in `files/run.sh` |
| `tests/test_db_detection_unit.sh` | Unit (mock `mysql`) | 7 assertions covering all branches of the detection logic: empty DB, non-empty DB, pre-set variable, `mysql` failure fallback |
| `tests/test_restart_integration.sh` | Integration (live Docker) | 3 assertions that the Koha container restarts cleanly without exit-255 when `USE_EXISTING_DB=yes`; auto-skips when the stack is not running |
| `tests/run_all_tests.sh` | Runner | Runs all suites, prints TAP summary, exits 1 on any failure |

The static and unit tests require no Docker; they run in under one second on any machine where `bash` and `mysql` (the MySQL client) are available.

---

## Startup sequence (manual steps)

The section below documents the individual steps that `stack.sh` automates. Use these if you need finer control, want to run only part of the stack, or are troubleshooting a specific stage.

The three components must be started **in this order**. The `koha-docker` compose project declares `opensearch-36_osearch` as an external network — Docker will refuse to start if that network does not exist yet.

---

### Step 1 — Build the OpenSearch image (first time, or after Dockerfile changes)

```bash
cd koha-docker/OpenSearch-3.6
docker compose build os01
```

This builds a single custom image (`kosson/opensearch-icu`) with the `analysis-icu` plugin installed.
All five cluster nodes share this image — `os01` owns the `build:` block and tags the result; `os02`–`os05` reference the same tag via `image:` with `pull_policy: never`.

#### What `analysis-icu` is and why Koha needs it

`analysis-icu` is an OpenSearch/Elasticsearch plugin that exposes the [ICU (International Components for Unicode)](https://icu.unicode.org/) library as analysis components. ICU provides locale-aware text processing that goes far beyond what the built-in ASCII-only analyzers offer.

Koha's Elasticsearch index configuration (`koha/etc/searchengine/elasticsearch/`) defines several custom analyzers for the `biblio` and `authority` indexes that rely on three ICU components:

| Component | Type | What it does |
|---|---|---|
| `icu_tokenizer` | Tokenizer | Splits text into tokens using Unicode text-segmentation rules. Unlike the simple whitespace tokenizer, it correctly handles scripts that do not use spaces (CJK, Thai, Khmer) and respects Unicode word-break rules for Latin scripts. |
| `icu_folding` | Token filter | Applies Unicode case-folding **and** accent/diacritic removal in a single pass. `café` → `cafe`, `Ångström` → `angstrom`, `ñ` → `n`. Essential for diacritic-insensitive catalogue searches across multilingual collections. |
| `icu_normalizer` | Character filter | Applies Unicode normalization (NFC/NFKC) to the character stream before tokenization. Ensures that visually identical characters encoded differently (e.g. composed vs. decomposed forms of accented letters) are treated as the same character. |

Without the plugin, any attempt to create the Koha search indexes fails immediately with:

```txt
[400] [illegal_argument_exception]
Custom Analyzer [icu_folding_normalizer] failed to find filter under name [icu_folding]
```

The plugin is installed into the custom `Dockerfile` under `OpenSearch-3.6/assets/opensearch/Dockerfile`:

```dockerfile
USER opensearch
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu
USER root
```

It is installed as the `opensearch` user (not `root`) because the plugin directory `/usr/share/opensearch/plugins/` is owned by that user in the base image.

All five nodes (`os01`–`os05`) must run the same image — OpenSearch requires uniform plugin installation across all cluster nodes that hold index shards. The `docker-compose.yml` builds the image once (via the `os01` service) and the other four nodes reference it by name.

Skip this step on subsequent runs if the Dockerfile has not changed.

---

### Step 2 — Start the OpenSearch cluster

```bash
cd koha-docker/OpenSearch-3.6
docker compose up -d
```

Wait for the cluster to reach **green** status before proceeding:

```bash
until curl -sk -u 'admin:test@Cici24#ANA' \
    https://localhost:9200/_cluster/health | grep -q '"status":"green"'; do
  echo "Waiting for OpenSearch cluster..."; sleep 5
done
echo "Cluster is green"
```

This creates two Docker networks:

- `opensearch-36_osearch` — internal; all five OS nodes join it
- `knonikl` — external bridge; used by Dashboards and the Koha container

---

### Step 3 — Start MariaDB and Memcached

On the first run (or to reset to a clean state), start the support services first:

```bash
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  --project-directory koha-docker \
  up -d db memcached
```

Wait ~5 seconds for MariaDB to initialise, then (re)create a fresh Koha database:

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

> **Why reset the database?** `run.sh` calls `do_all_you_can_do.pl` which expects an
> empty schema. If tables from a previous run exist, it reports conflicts. Always reset
> before starting the `koha` container for a clean install.

---

### Step 4 — Start (or restart) the Koha container

```bash
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  --project-directory koha-docker \
  up -d --force-recreate koha
```

`--force-recreate` ensures environment variable changes are picked up and no stale state (Plack PIDs, sockets) carries over from previous runs.

---

### Step 5 — Follow the startup logs

```bash
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  --project-directory koha-docker \
  logs -f koha
```

The container runs `run.sh` which performs a full Koha installation. Startup takes **5–15 minutes** depending on network speed (git clones) and hardware. Key milestones:

| Log line | Milestone |
|---|---|
| `koha-create --request-db kohadev` | Koha instance config created |
| `Running do_all_you_can_do.pl` | Database schema applied, admin user created |
| `Cloning into 'po'...` | L10n translation files fetched |
| `gitify all` | Source tree linked for development |
| `yarn build` / `rspack` | Front-end assets compiled |
| `rebuild_elasticsearch.pl -v` | Search indexes built in OpenSearch |
| `Plack enabled for kohadev OPAC` | OPAC Plack server started |
| `Plack enabled for kohadev Intranet` | Staff Plack server started |
| `koha-testing-docker has started up and is ready to be enjoyed!` | **Ready** |

The container exits with code 0 after printing the "ready" line — this is expected. The Plack workers continue running inside the container.

---

### Quick restart (after the first successful run)

To restart without rebuilding (e.g. after a code change):

```bash
# Reset DB
docker exec koha-docker-db-1 mysql -uroot -ppassword -e "
  DROP DATABASE IF EXISTS koha_kohadev;
  CREATE DATABASE koha_kohadev CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON koha_kohadev.* TO 'koha_kohadev'@'%';
  FLUSH PRIVILEGES;"

# Restart koha container
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  --project-directory koha-docker \
  up -d --force-recreate koha
```

---

## Accessing the stack

### Traefik reverse proxy (recommended)

The stack ships with a **Traefik** reverse proxy (`traefik/docker-compose.yaml`) that provides hostname-based routing on standard port 80 — no `:8080` / `:8081` port numbers in browser URLs, and no per-service port knowledge needed.

`stack.sh start` automatically creates the `frontend` Docker network and starts Traefik before everything else.

#### Service URLs via Traefik

| Service | HTTP URL | HTTPS URL (when `TLS_CERTRESOLVER=letsencrypt`) | Credentials |
|---|---|---|---|
| **OPAC** (public catalogue) | http://kohadev.myDNSname.org | https://kohadev.myDNSname.org | — (public) |
| **Staff interface** | http://kohadev-intra.myDNSname.org | https://kohadev-intra.myDNSname.org | `koha` / `koha` |
| **OpenSearch Dashboards** | http://dashboards.localhost | https://dashboards.myDNSname.org | `admin` / *see `env/.env`* |
| **Traefik dashboard** | http://localhost:8083 | — | — |
| **OpenSearch REST API** | — | https://localhost:9200 (self-signed) | `admin` / *see `env/.env`* |

HTTPS routers are always registered. When `TLS_CERTRESOLVER` is empty (default), Traefik serves HTTPS with a self-signed fallback certificate (browser shows a cert warning) and HTTP continues to work normally. Set `TLS_CERTRESOLVER=letsencrypt` to switch to trusted certificates — see [Let's Encrypt — automatic public HTTPS](#lets-encrypt--automatic-public-https).

> **Credentials are set in `env/.env`** (`KOHA_USER`, `KOHA_PASS`,
> `OPENSEARCH_INITIAL_ADMIN_PASSWORD`). The table above shows the defaults.
> The Koha superlibrarian account is created automatically by
> `create_superlibrarian.pl` during first startup.

#### Direct fallback (no DNS needed)

The Koha container still exposes ports directly for debugging or when Traefik is not running:

| Service | URL |
|---|---|
| OPAC | http://localhost:8080 |
| Staff interface | http://localhost:8081 |

### Hostname resolution — three options

The Traefik labels in `docker-compose.yml` route `kohadev.myDNSname.org` and `kohadev-intra.myDNSname.org` to the correct Koha ports. For a browser to reach those names, one of the following must be in place:

#### Option 1 — `/etc/hosts` (simplest for a single dev machine)

Add two lines to `/etc/hosts` on the **host machine** (requires `sudo`):

```
127.0.0.1  kohadev.myDNSname.org
127.0.0.1  kohadev-intra.myDNSname.org
```

#### Option 2 — `nip.io` wildcard DNS (zero-config, portable, no internet for access)

[nip.io](https://nip.io) is a free public DNS service that resolves any hostname containing an IP address back to that IP — no local configuration at all.

Change `KOHA_DOMAIN` in `env/.env` to embed the host IP:

```bash
# Local machine (loopback)
KOHA_DOMAIN=.127.0.0.1.nip.io

# Or your LAN / server IP so other machines on the network can also reach it:
KOHA_DOMAIN=.192.168.1.100.nip.io
```

The Traefik labels and Koha's Apache virtual hosts are rebuilt from `KOHA_DOMAIN` automatically, so no other files need changing.

Access URLs become:

- OPAC  → `http://kohadev.127.0.0.1.nip.io`
- Staff → `http://kohadev-intra.127.0.0.1.nip.io`

> **Why there is no `:8080` in the URL:** `KOHA_PUBLIC_PORT=80` (set in `env/.env`) tells `run.sh` what port to record in the Koha database as `OPACBaseURL` and `staffClientBaseURL`. Port 80 is the HTTP default and is omitted from URLs. The internal Apache port (`KOHA_OPAC_PORT=8080`) is only used for container-to-container routing via Traefik. If you change `TRAEFIK_HTTP_PORT` to a non-standard value (e.g. `8000`), set `KOHA_PUBLIC_PORT` to the same value and rebuild the Koha image with `./stack.sh start --build-koha`.

#### Option 3 — Real DNS (production)

Point real DNS A records for `kohadev.myDNSname.org` and `kohadev-intra.myDNSname.org` (or a wildcard `*.myDNSname.org`) to the server IP. Traefik handles the routing; no `/etc/hosts` entry needed on any client machine.

### Traefik port configuration

All Traefik ports are set in `traefik/.env`:

| Variable | Default | Description |
|---|---|---|
| `TRAEFIK_HTTP_PORT` | `80` | Host port bound to Traefik's `web` (HTTP) entrypoint. Change to a non-privileged port (e.g. `8000`) if port 80 is in use. |
| `TRAEFIK_HTTPS_PORT` | `443` | Host port bound to Traefik's `websecure` (HTTPS/TLS) entrypoint. |
| `TRAEFIK_DASHBOARD_PORT` | `8083` | Host port for the Traefik API dashboard. |
| `ACME_EMAIL` | *(empty)* | Contact email for Let's Encrypt certificate registration. Must be set to enable automatic TLS. See [Let's Encrypt — automatic public HTTPS](#lets-encrypt--automatic-public-https). |

After changing `TRAEFIK_HTTP_PORT`, access URLs become `http://kohadev.myDNSname.org:8000`. Set `KOHA_PUBLIC_PORT` to the same value in `env/.env` so Koha's stored URLs match.

### Quick health checks

```bash
# Koha OPAC via Traefik — expect HTTP 200 or 302
curl -sI http://kohadev.myDNSname.org | head -1

# Koha staff via Traefik — expect HTTP 200 or 302
curl -sI http://kohadev-intra.myDNSname.org | head -1

# Direct fallback (no DNS)
curl -sI http://localhost:8080 | head -1

# OpenSearch cluster health — expect {"status":"green",...}
curl -sk -u 'admin:test@Cici24#ANA' https://localhost:9200/_cluster/health | python3 -m json.tool

# OpenSearch Dashboards via Traefik — expect HTTP 302 (redirect to /app/home)
curl -sI http://dashboards.localhost | head -1
```
---

## Data preparation — things to take into consideration

This section covers what you must verify and prepare **before importing MARC records** into Koha. Skipping these checks will cause background jobs to fail with FK constraint errors or crash the OPAC with cryptic Perl exceptions.

### MARC item field requirements (MARC21 field 952)

When exporting MARC records from any ILS for import into Koha, **every item record must include at minimum** the following `952` subfields. Missing subfields are stored as `NULL` in the `items` table and will cause import failures or runtime crashes.

| Subfield | Koha `items` column | Required | Notes |
|---|---|---|---|
| `952$a` | `homebranch` | **YES** | Branch code of the owning library. Must exist in `branches.branchcode` **before** import. A missing value or an unknown code causes the `marc_import_commit_batch` background job to fail with a FK constraint error at commit time. |
| `952$b` | `holdingbranch` | **YES** | Branch currently holding the item. Set it equal to `$a` if unknown. When `NULL`, the OPAC crashes with `DBIC result _type isn't of the _type Branch` because `Koha::Item->holding_library` tries to inflate a `NULL` FK into a `Koha::Library` object. |
| `952$y` | `itype` | **YES** | Item type code (e.g. `BK`, `MU`, `VM`). Must exist in `itemtypes.itemtype`. A `NULL` value suppresses circulation rules and may produce display errors throughout the staff interface and OPAC. |
| `952$p` | `barcode` | Recommended | Unique barcode string. `NULL` is allowed but items without barcodes cannot be checked out. |
| `952$c` | `location` | Optional | Shelving location authorised value (e.g. `GEN`, `REF`). `NULL` is safe — location is simply not displayed. |
| `952$o` | `itemcallnumber` | Optional | Call number string. `NULL` is safe. |
| `952$g` | `price` | Optional | Purchase price as a decimal. `NULL` is safe. |
| `952$d` | `dateaccessioned` | Optional | Acquisition date in `YYYY-MM-DD` format. `NULL` defaults to no date. |

### Pre-import checklist

Run these checks against your Koha database **before** staging a MARC file.

**1. Verify branches exist**

```sql
SELECT branchcode, branchname FROM branches ORDER BY branchcode;
```

Every `952$a` (homebranch) and `952$b` (holdingbranch) value in your MARC file must appear in this list. Add any missing branch via **Administration → Libraries** in the staff interface, or directly:

```sql
INSERT INTO branches (branchcode, branchname, pickup_location, public)
VALUES ('CODE', 'Branch Name', 1, 1);
```

**2. Verify item types exist**

```sql
SELECT itemtype, description FROM itemtypes ORDER BY itemtype;
```

Every `952$y` value in your MARC file must appear here. Add missing types via **Administration → Item types**.

**3. Verify authorised values (if used)**

If your MARC file includes shelving locations (`952$c`) or collection codes (`952$8`), verify the values exist:

```sql
SELECT category, authorised_value, lib FROM authorised_values
WHERE category IN ('LOC', 'CCODE')
ORDER BY category, authorised_value;
```

Add missing values via **Administration → Authorised values**.

**4. Check for barcode conflicts**

If your MARC file includes barcodes (`952$p`), ensure none already exist in the database:

```sql
SELECT barcode FROM items WHERE barcode IS NOT NULL ORDER BY barcode;
```

Duplicates will cause individual item inserts to fail silently during the commit job.

### If you cannot fix the export source

Use a **MARC modification template** (Tools → MARC modification templates) to map, default, or rewrite `952` subfields **during the staging step**, before the commit job runs. This lets you transform branch codes, assign a default item type, or remove unknown subfields without touching the source file.

Alternatively, set `item_action = ignore` on the staging form to skip item import entirely — the bibliographic records will still be imported, and items can be added manually afterwards.

---

## Known non-fatal warnings

These messages appear in the logs on every clean start and can be ignored:

| Warning | Cause |
|---|---|
| `Error: worker not running for kohadev (default/long_tasks)` | `koha-create` restarts the worker before the DB schema is applied; worker starts fine later |
| `PCDATA invalid Char value 31` (biblio 369) | A sample MARC record in the `misc4dev` test data contains a control character; that one record is skipped, all others are indexed |
| `Error: Plack already running for kohadev` | `run.sh` calls `koha-plack --start` twice; the second call is a no-op |

---

## Koha image — Hub vs local build

The `koha` service resolves its image in this order:

1. **Local Docker cache** — if `kosson/koha-ubuntu:latest` (or the tag set in `KOHA_IMAGE_TAG`) is already present, it is used immediately.
2. **Docker Hub pull** — if the image is not cached, Compose pulls it from [hub.docker.com/r/kosson/koha-ubuntu](https://hub.docker.com/repository/docker/kosson/koha-ubuntu).
3. **Local build fallback** — if the pull fails for any reason (image not yet published, no internet access), Compose builds from the local `Dockerfile`.

This behaviour is controlled by `pull_policy: missing` in `docker-compose.yml`.

### Force a fresh pull (pick up a newer `latest`)

```bash
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  pull koha
```

Then start normally — Compose will use the freshly pulled image.

### Build the image locally

If you change `Dockerfile` or want to test local modifications without pushing to Hub:

```bash
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  --project-directory koha-docker \
  build koha
```

Or via `stack.sh`:

```bash
./stack.sh build --build-koha   # build only the Koha image
./stack.sh start --build-koha   # build then start
```

The locally built image is tagged as `kosson/koha-ubuntu:latest` (the value of `KOHA_IMAGE_TAG`), so it takes precedence over any Hub pull on the same machine until the local cache is cleared.

### Push a new release to Docker Hub

```bash
# Build and tag with both a version tag and latest
docker build \
  -t kosson/koha-ubuntu:latest \
  -t kosson/koha-ubuntu:25.12.00 \
  /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker

# Login and push
docker login
docker push kosson/koha-ubuntu --all-tags
```

Then follow the full startup sequence (Steps 3–5) again.

---

## Let's Encrypt — automatic public HTTPS

Traefik's built-in ACME client can request and renew certificates from Let's Encrypt automatically. This section explains how to enable it.

> **Scope**: Let's Encrypt certs cover only the public-facing Traefik edge (OPAC, Staff interface, Dashboards). The OpenSearch cluster's internal node-to-node TLS always uses the pre-generated self-signed CA — Let's Encrypt cannot replace it.

### Prerequisites

| Requirement | Details |
|---|---|
| Public domain | `KOHA_DOMAIN` in `env/.env` must be a real DNS domain that resolves to this server's public IP (e.g. `.library.example.com`, **not** `.127.0.0.1.nip.io`). |
| Port 80 open | Let's Encrypt uses HTTP-01 challenge: it sends an HTTP request on port 80 to verify domain ownership. `TRAEFIK_HTTP_PORT=80` and port 80 must be reachable from the internet. |
| Valid email | Used for Let's Encrypt account registration and expiry notices. |
| Rate limits | Let's Encrypt [rate-limits](https://letsencrypt.org/docs/rate-limits/) certificate issuance. Avoid restarting the stack repeatedly during testing — use the [staging environment](https://letsencrypt.org/docs/staging-environment/) first if needed. |

### Step-by-step

**1. Set a real public domain** in `env/.env`:

```bash
KOHA_DOMAIN=.library.example.com
```

Koha OPAC will be at `kohadev.library.example.com`, Staff at `kohadev-intra.library.example.com`.

**2. Set the Dashboards hostname** in `OpenSearch-3.6/.env`:

```bash
DASHBOARDS_DOMAIN=dashboards.library.example.com
```

**3. Set your ACME email** in `traefik/.env`:

```bash
ACME_EMAIL=admin@library.example.com
```

**4. Enable the cert resolver** in **both** `env/.env` and `OpenSearch-3.6/.env`:

```bash
TLS_CERTRESOLVER=letsencrypt
```

**5. Start the stack**:

```bash
./stack.sh start
```

On the first HTTPS request to each hostname, Traefik contacts Let's Encrypt, completes the HTTP-01 challenge (served automatically by Traefik on port 80), and stores the issued certificate in the `traefik_certs` Docker volume (`acme.json`). Subsequent requests use the cached certificate. Traefik renews certificates automatically before expiry.

### Verifying certificate issuance

```bash
# Expect a valid Let's Encrypt certificate (not "TRAEFIK DEFAULT CERT")
curl -sv https://kohadev.library.example.com 2>&1 | grep -E 'subject|issuer|expire'

# Inspect acme.json inside Traefik
docker exec traefik cat /var/traefik/certs/acme.json | python3 -m json.tool | grep -A5 '"domain"'
```

### Enabling HTTP → HTTPS redirect (optional)

By default both HTTP and HTTPS are served. To redirect all HTTP traffic to HTTPS, **after** Let's Encrypt certificates are confirmed working, uncomment four lines at the bottom of the `labels:` block in `docker-compose.yml`:

```yaml
- "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
- "traefik.http.middlewares.redirect-to-https.redirectscheme.permanent=true"
- "traefik.http.routers.koha-opac.middlewares=redirect-to-https"    # ← uncomment
- "traefik.http.routers.koha-staff.middlewares=redirect-to-https"   # ← uncomment
```

Then restart the Koha container:

```bash
docker compose -f docker-compose.yml --env-file env/.env up -d --force-recreate koha
```

> **Warning**: do not enable the redirect before certificates are working. An HTTP→HTTPS redirect without a valid cert creates a redirect loop that prevents certificate issuance (the HTTP-01 challenge itself uses port 80).

### Certificate storage and backup

Certificates are stored in the `traefik_certs` Docker named volume as `acme.json`. This file is created automatically on first run.

Back it up regularly — if it is lost, Traefik must re-issue all certificates, which counts against Let's Encrypt rate limits:

```bash
docker run --rm -v traefik_certs:/data alpine cat /data/acme.json > acme.json.backup
```

### Using Let's Encrypt staging (rate-limit safe testing)

Add the staging CA URL to the Traefik `command:` in `traefik/docker-compose.yaml`:

```yaml
command:
  - "--certificatesresolvers.letsencrypt.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory"
```

Staging certificates are not trusted by browsers (you will still see a cert warning) but issuance does not count against production rate limits. Remove the `caserver` line when you are ready to switch to production certificates.

---

## TLS certificate verification (production) — OpenSearch

The default setup bypasses TLS verification for the Koha → OpenSearch connection (`SSL_verify_mode => 0`, `PERL_LWP_SSL_VERIFY_HOSTNAME=0`). To use the OpenSearch self-signed CA instead:

1. Set in `env/.env`:

```bash
OPENSEARCH_CA_CERT=/path/to/koha-docker/OpenSearch-3.6/assets/ssl/root-ca.pem
PERL_LWP_SSL_VERIFY_HOSTNAME=1
```

2. Change `ELASTIC_OPTIONS` to remove `<ssl_options>` and instead let Koha use the mounted CA file at `/kohadevbox/opensearch-root-ca.pem`.

---

## Docker networks reference

| Network | Type | Created by | Who joins |
|---|---|---|---|
| `koha-docker_kohanet` | Internal bridge | `koha-docker` compose | `koha`, `db`, `memcached` |
| `opensearch-36_osearch` | Internal bridge | `OpenSearch-3.6` compose | `os01`–`os05` |
| `knonikl` | External bridge | `OpenSearch-3.6` compose | `os01`, `dashboards`, `koha` |
| `frontend` | External bridge | `stack.sh` / Traefik compose | `traefik`, `koha`, `dashboards` |

The `koha` container joins both `kohanet` (to reach `db`) and `opensearch-36_osearch` (to reach `os01:9200` for search). The `knonikl` network is retained for Dashboards access. The `frontend` network connects Traefik to every service it proxies — containers must have `traefik.docker.network=frontend` in their labels, and must also be attached to `frontend` in their `networks:` section.
