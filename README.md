# Koha Docker containers

This is a setup of Docker containers created to work with the latest Koha ILS, Koha 25.12.00.

A self-contained Docker Compose environment for **Koha ILS** development, backed by **MariaDB 10.11** and an external **OpenSearch 3.6** cluster.

---

## Repository layout

```
koha-docker/
├── stack.sh                     # Automated lifecycle manager (start/stop/restart/status/logs)
├── docker-compose.yml           # Main stack: koha, db (MariaDB), memcached
├── Dockerfile                   # Koha dev container (Ubuntu 24.04 Noble)
├── env/
│   └── .env                     # All runtime settings — edit before first start
├── files/
│   └── templates/
│       └── koha-conf-site.xml.in  # koha-conf.xml template (uses envsubst)
├── koha/                        # Host-mounted Koha source tree (git clone)
└── OpenSearch-3.6/              # External 5-node OpenSearch 3.6 cluster
    ├── docker-compose.yml
    ├── .env                     # OpenSearch version + admin password
    └── assets/
        ├── opensearch/
        │   └── Dockerfile       # Custom image with analysis-icu plugin
        └── ssl/                 # Self-signed TLS certificates
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Docker Engine | 24+ | `docker --version` |
| Docker Compose (plugin) | v2.20+ | `docker compose version` |
| Available disk space | ≥ 15 GB | Images + Koha source + OS data |
| Host user UID | **1000** | The Koha source dir must be owned by UID 1000 |

### Koha source tree

Clone the Koha source into `koha-docker/koha/` **as the host user (UID 1000)**:

```bash
cd koha-docker
git clone --depth=1 https://git.koha-community.org/Koha-community/Koha.git koha
```

The directory is bind-mounted into the container at `/kohadevbox/koha`. The container user `kohadev-koha` runs as UID 1000, so file ownership must match.

---

## Initial configuration

All settings live in **`env/.env`**. Copy or review the file before the first start.
Critical values to verify:

### Identity and paths

| Variable | Default | Description |
|---|---|---|
| `LOCAL_USER_ID` | `1000` | Must match the UID that owns the `koha/` source directory on the host |
| `SYNC_REPO` | `/media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/koha` | **Absolute path on the host** to the Koha source tree |
| `KOHA_INSTANCE` | `kohadev` | Name of the Koha instance created inside the container |

### Domain and ports

| Variable | Default | Description |
|---|---|---|
| `KOHA_DOMAIN` | `.myDNSname.org` | DNS domain suffix. Change to `.<ip>.nip.io` (e.g. `.127.0.0.1.nip.io`) for zero-config portable access — see **Accessing the stack** below |
| `KOHA_INTRANET_SUFFIX` | `-intra` | Staff interface hostname becomes `kohadev-intra.myDNSname.org` |
| `KOHA_OPAC_PORT` | `8080` | OPAC port exposed on the host (internal Apache port, also used by Traefik backend) |
| `KOHA_INTRANET_PORT` | `8081` | Staff interface port exposed on the host (internal Apache port) |
| `KOHA_PUBLIC_PORT` | `80` | **Public-facing HTTP port served by Traefik.** URLs stored in the Koha database (`OPACBaseURL`, `staffClientBaseURL`) use this port. Port 80 is the default for HTTP and is omitted from URLs — so links in Koha pages will not contain `:8080`. Change to match `TRAEFIK_HTTP_PORT` if Traefik runs on a non-standard port (e.g. `8000`). |

### Demo data

| Variable | Default | Description |
|---|---|---|
| `LOAD_DEMO_DATA` | `yes` | `yes` — load 436 sample MARC bibliographic records, authority records, items, and patron data during first startup (via `misc4dev/insert_data.pl`). `no` — skip sample data; the catalogue is empty and only the superlibrarian account is created. Override at runtime with `./stack.sh start --no-demo-data` or `--with-demo-data`. |

### Database

| Variable | Default | Description |
|---|---|---|
| `DB_IMAGE` | `mariadb:10.11` | MariaDB image |
| `DB_HOSTNAME` | `db` | Hostname of the MariaDB container |
| `KOHA_DB_PASSWORD` | `password` | Password for the `koha_kohadev` database user |

The root password is hard-coded to `password` in `docker-compose.yml` (`MYSQL_ROOT_PASSWORD`).

### OpenSearch connection

| Variable | Value | Description |
|---|---|---|
| `KOHA_ELASTICSEARCH` | `yes` | Enables OpenSearch-backed search in Koha |
| `ELASTIC_SERVER` | `https://os01:9200` | URL of the OpenSearch cluster manager — **no credentials in the URL** |
| `ELASTIC_OPTIONS` | *(see below)* | Extra XML elements injected into `koha-conf.xml`'s `<elasticsearch>` block |
| `PERL_LWP_SSL_VERIFY_HOSTNAME` | `0` | Disables LWP TLS certificate verification (dev only) |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | `"test@Cici24#ANA"` | Must match the password set in `OpenSearch-3.6/.env` |

Current `ELASTIC_OPTIONS` value (all on one line in `env/.env`):

```
ELASTIC_OPTIONS=<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options><userinfo>admin:test@Cici24#ANA</userinfo><client_version>7</client_version>
```

Each XML element maps to a keyword argument passed to `Search::Elasticsearch->new()`:

| Element | Purpose |
|---|---|
| `<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>` | Disables IO::Socket::SSL certificate verification in the HTTP::Tiny backend |
| `<userinfo>admin:test@Cici24#ANA</userinfo>` | Passes credentials as a raw string so special chars (`@`, `#`) are base64-encoded correctly — **do not put credentials in the URL** |
| `<client_version>7</client_version>` | Bypasses the Elasticsearch 8.x product check that rejects OpenSearch (`x-elastic-product: OpenSearch` ≠ `Elasticsearch`) |

### OpenSearch cluster settings

Edit `OpenSearch-3.6/.env` to change the cluster version or admin password:

```bash
OPEN_SEARCH_VERSION=3.6.0
OPENSEARCH_INITIAL_ADMIN_PASSWORD="test@Cici24#ANA"
```

The admin password must match `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in `koha-docker/env/.env`.

---

## Automated startup — `stack.sh`

`stack.sh` in the project root handles the entire lifecycle. It wraps all five manual steps below into single commands, waits for health checks between stages, and prints a summary box with URLs and credentials when the stack is ready.

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

# Stop everything
./stack.sh stop

# Check what is running + OpenSearch cluster health
./stack.sh status

# Attach to Koha startup logs at any time
./stack.sh logs
```

### Build options

| Flag | Effect |
|---|---|
| `--build` | Rebuild both OpenSearch and Koha images before starting |
| `--build-opensearch` | Rebuild only the OpenSearch images (5 nodes + analysis-icu) |
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

### What `start` does internally

1. Verifies prerequisites (`docker`, `docker compose`, `env/.env`).
2. Optionally rebuilds images.
3. Starts the OpenSearch cluster (`docker compose up -d` in `OpenSearch-3.6/`).
4. Polls `/_cluster/health` until status is `"green"` (up to 6 minutes).
5. Starts MariaDB and Memcached; waits for `mysqladmin ping` to succeed.
6. Drops and recreates the `koha_kohadev` database (skipped with `--no-fresh-db`).
7. Starts the Koha container with `--force-recreate`.
8. Tails the logs and prints a ready banner when the "started up" line appears.

### `restart` command

`restart` is for quick iteration when OpenSearch is already running. It resets the database and re-creates only the Koha container — OpenSearch and MariaDB are not restarted.

```bash
./stack.sh restart                # Reset DB + recreate Koha
./stack.sh restart --no-fresh-db  # Recreate Koha only (keep existing data)
```

---

## Startup sequence (manual steps)

The section below documents the individual steps that `stack.sh` automates. Use these if you need finer control, want to run only part of the stack, or are troubleshooting a specific stage.

The three components must be started **in this order**. The `koha-docker` compose project declares `opensearch-36_osearch` as an external network — Docker will refuse to start if that network does not exist yet.

---

### Step 1 — Build the OpenSearch images (first time, or after Dockerfile changes)

```bash
cd koha-docker/OpenSearch-3.6
docker compose build
```

This builds a custom image for all five nodes with the `analysis-icu` plugin installed.

#### What `analysis-icu` is and why Koha needs it

`analysis-icu` is an OpenSearch/Elasticsearch plugin that exposes the [ICU (International Components for Unicode)](https://icu.unicode.org/) library as analysis components. ICU provides locale-aware text processing that goes far beyond what the built-in ASCII-only analyzers offer.

Koha's Elasticsearch index configuration (`koha/etc/searchengine/elasticsearch/`) defines several custom analyzers for the `biblio` and `authority` indexes that rely on three ICU components:

| Component | Type | What it does |
|---|---|---|
| `icu_tokenizer` | Tokenizer | Splits text into tokens using Unicode text-segmentation rules. Unlike the simple whitespace tokenizer, it correctly handles scripts that do not use spaces (CJK, Thai, Khmer) and respects Unicode word-break rules for Latin scripts. |
| `icu_folding` | Token filter | Applies Unicode case-folding **and** accent/diacritic removal in a single pass. `café` → `cafe`, `Ångström` → `angstrom`, `ñ` → `n`. Essential for diacritic-insensitive catalogue searches across multilingual collections. |
| `icu_normalizer` | Character filter | Applies Unicode normalization (NFC/NFKC) to the character stream before tokenization. Ensures that visually identical characters encoded differently (e.g. composed vs. decomposed forms of accented letters) are treated as the same character. |

Without the plugin, any attempt to create the Koha search indexes fails immediately with:

```
[400] [illegal_argument_exception]
Custom Analyzer [icu_folding_normalizer] failed to find filter under name [icu_folding]
```

The plugin is installed into the custom `Dockerfile` under
`OpenSearch-3.6/assets/opensearch/Dockerfile`:

```dockerfile
USER opensearch
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu
USER root
```

It is installed as the `opensearch` user (not `root`) because the plugin directory `/usr/share/opensearch/plugins/` is owned by that user in the base image.

All five nodes (`os01`–`os05`) must have the plugin — OpenSearch requires uniform plugin installation across all cluster nodes that hold index shards. The `docker-compose.yml` therefore uses `build:` (not `image:`) for every node.

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

| Service | URL | Credentials |
|---|---|---|
| **OPAC** (public catalogue) | http://kohadev.myDNSname.org | — (public) |
| **Staff interface** | http://kohadev-intra.myDNSname.org | `koha` / `koha` |
| **OpenSearch Dashboards** | http://dashboards.localhost | `admin` / `test@Cici24#ANA` |
| **Traefik dashboard** | http://localhost:8083 | — |
| **OpenSearch REST API** | https://localhost:9200 | `admin` / `test@Cici24#ANA` |

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

The Traefik container's HTTP port defaults to **80**. If port 80 is already in use on the host, edit `traefik/.env`:

```bash
TRAEFIK_HTTP_PORT=8000   # or any free port
```

After changing the port, access URLs become `http://kohadev.myDNSname.org:8000`.

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

## Known non-fatal warnings

These messages appear in the logs on every clean start and can be ignored:

| Warning | Cause |
|---|---|
| `Error: worker not running for kohadev (default/long_tasks)` | `koha-create` restarts the worker before the DB schema is applied; worker starts fine later |
| `PCDATA invalid Char value 31` (biblio 369) | A sample MARC record in the `misc4dev` test data contains a control character; that one record is skipped, all others are indexed |
| `Error: Plack already running for kohadev` | `run.sh` calls `koha-plack --start` twice; the second call is a no-op |

---

## Rebuilding the Docker image

If you change `Dockerfile` or need to pull updated base layers:

```bash
docker compose \
  -f koha-docker/docker-compose.yml \
  --env-file koha-docker/env/.env \
  --project-directory koha-docker \
  build koha
```

Then follow the full startup sequence (Steps 3–5) again.

---

## TLS certificate verification (production)

The default setup bypasses TLS verification (`SSL_verify_mode => 0`, `PERL_LWP_SSL_VERIFY_HOSTNAME=0`). To use the OpenSearch self-signed CA instead:

1. Set in `env/.env`:

```bash
OPENSEARCH_CA_CERT=/media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/OpenSearch-3.6/assets/ssl/root-ca.pem
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
