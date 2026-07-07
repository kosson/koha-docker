---
title: Let's Encrypt / automatic public HTTPS via Traefik ACME
date: 2026.05.20
tags:
 - encryption
 - https
 - Traefik
---
# 2026-05-20 — Let's Encrypt / automatic public HTTPS via Traefik ACME

## Goal

Enable production-grade HTTPS with real, automatically-renewed certificates from Let's Encrypt for all public Traefik-exposed services (OPAC, Staff interface, OpenSearch Dashboards), while keeping local / offline development working unchanged with zero configuration.

## Architecture decision

The stack has two independent TLS layers. Only the public edge layer is affected by this change:

| Layer | Certificates | Change in this session |
|---|---|---|
| **Traefik edge** (browser ↔ Koha/Dashboards) | Let's Encrypt via ACME, or Traefik self-signed fallback | **Modified** |
| **OpenSearch internal** (node-to-node transport, admin API) | Self-signed with project-local CA, pre-generated in `assets/ssl/` | **Unchanged** |

OpenSearch internal certs cannot use Let's Encrypt because the mTLS identity is based on Distinguished Names (container hostnames like `os01`, `os02`) — not public domain names — and they authenticate node-to-node transport, which is never exposed to the internet.

## How it works

### Conditional cert resolver pattern

Docker Compose labels cannot be conditionally present. The solution is to always define HTTPS router labels but make the `tls.certresolver` value an environment variable:

```yaml
- "traefik.http.routers.koha-opac-tls.tls.certresolver=${TLS_CERTRESOLVER:-}"
```

| `TLS_CERTRESOLVER` value | Effect |
|---|---|
| *(empty, default)* | Traefik's `tls.certresolver` is an empty string → Traefik uses its self-signed fallback cert; no ACME calls are made |
| `letsencrypt` | Traefik's ACME client contacts Let's Encrypt, issues a certificate for the router's `Host()` rule, and stores it in `acme.json` |

This means the stack is always HTTPS-capable (port 443 is always open), but only makes ACME requests when the operator explicitly opts in.

### ACME configuration placement

The ACME parameters are passed as CLI flags via the `command:` block in `traefik/docker-compose.yaml`. This is more reliable than the static `traefik.yaml` because:
- Docker Compose env var substitution (`${ACME_EMAIL:-}`) is fully supported in the `command:` block
- No need to manage two config files with overlapping responsibilities

### Certificate storage

A named Docker volume `traefik_certs` is mounted at `/var/traefik/certs/` inside the Traefik container. Traefik writes `acme.json` there. The volume persists across Traefik restarts and image updates.

### HTTP → HTTPS redirect
ng container to pick up the changes.

### 2. OpenSearch wait loop (critical missing feature)

The Linux version had **no wait loop** for OpenSearch before calling `do_all_you_can_do.pl --elasticsearch`. The Perl script would immediately call `rebuild_elasticsearch.pl`, which would fail with `[NoNodes]` if the OpenSearch cluster was not yet ready (cold start, cluster election not complete).

A 60-attempt loop (5 s sleep each = 5 min maximum wait) was added:

- **TCP pre-check**: `nc -z -w 3 os01 9200` — avoids spending a costly curl attempt on a port that is not even open yet
- **HTTPS health check**: `curl` against `/_cluster/health?wait_for_status=yellow` with correct credentials and CA cert handling (uses mounted `opensearch-root-ca.pem` if
  present, falls back to `-k`)
- **Cluster status check**: waits for `"status":"yellow"` or `"status":"green"`
- **Progress logging**: prints attempt number and last curl response on attempt 1 and every 10th attempt

If OpenSearch does not become ready within 5 minutes, `run.sh` exits with code 1 (early abort) rather than silently continuing and producing an empty search index.

### 3. Elasticsearch/Zebra sed hacks

Two `sed` patches applied to `misc4dev/do_all_you_can_do.pl` when `KOHA_ELASTICSEARCH=yes`:

**a) Skip `koha-rebuild-zebra` in ES mode:**

```bash
sed -i 's|\$cmd = "sudo koha-rebuild-zebra -f -v \$instance";|say "Skipping..."; \$cmd = "true";|' \
    "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"
```

`misc4dev` forces a full Zebra rebuild after ES indexing succeeds. On the current sample dataset (`misc4dev` test data), several MARC records contain malformed XML (control characters, invalid UTF-8) that cause `koha-rebuild-zebra` to abort with an error.
Since Elasticsearch/OpenSearch is the active search backend, the Zebra index is unused; the rebuild failure would abort `do_all_you_can_do.pl` and the container.

**b) Suppress ES rebuild noise:**

```bash
sed -i "s|perl \$rebuild_es_path -v'|perl \$rebuild_es_path' 2>/tmp/rebuild_elasticsearch.stderr|" \
    "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"
```

Redirects the verbose output of `rebuild_elasticsearch.pl` to a temp file during setup so the startup log is readable. The file remains available for inspection.

### 4. CRLF normalization for `migration_tools`

```bash
find "${BUILD_DIR}/koha/misc/migration_tools" -type f -name '*.pl' \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true
```

`koha-rebuild-zebra` calls these scripts directly. CRLF shebangs produce a misleading "No such file or directory" error (the shell looks for `/usr/bin/perl\r`). This normalization runs even on Linux builds, as the Koha repo may include commits from Windows developers.

### 5. CRLF normalization for `.pl` / `.cgi` after setup

```bash
find "${BUILD_DIR}/koha" -type f \( -name '*.pl' -o -name '*.cgi' \) \
        -exec sed -i 's/\r$//' {} + 2>/dev/null || true
```

Applied after all setup steps and before Apache is started. Apache's CGI mode runs each `.pl` directly via the shebang; a CRLF shebang causes the same "No such file or directory" error silently at request time, producing HTTP 500.

### 6. Graceful `koha-plack` and `koha-z3950-responder` enable

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

Prevents a hard exit when a Koha package profile does not include Plack or Z39.50, and suppresses the noisy "you must provide at least one instance name" message from `koha-common start` during profile-less startup.

## Changes made to `docker-compose.yml`

### 1. Pre-built image pull support

```yaml
koha:
    image: ${KOHA_IMAGE_TAG:-kosson/koha-ubuntu:latest}
    build:
        context: .
```

When `KOHA_IMAGE_TAG` is set in `env/.env` to a published tag (e.g., `kosson/koha-ubuntu:25.12.00`), Docker Compose will **pull** that image instead of building locally — identical to how `kosson/koha-windows` works. To force a local build, unset `KOHA_IMAGE_TAG` or run `docker compose build`.

### 2. Parameterized DB root password

```yaml
# Before
MYSQL_ROOT_PASSWORD: password

# After
MYSQL_ROOT_PASSWORD: ${KOHA_DB_ROOT_PASSWORD:-password}
```

Allows overriding the MariaDB root password from `env/.env` without editing
`docker-compose.yml`.

### 3. Named volume for MariaDB data

```yaml
db:
    volumes:
        - koha-db-data:/var/lib/mysql

volumes:
    koha-db-data:
```

Database data now survives `docker compose down` (without `-v`). Previously the DB was stored in an anonymous volume that Docker would remove on the next `down`, requiring a full `do_all_you_can_do.pl` re-run on every restart.

## Changes made to `env/defaults.env`

| Variable added | Default | Purpose |
|---|---|---|
| `KOHA_DB_ROOT_PASSWORD` | `password` | MariaDB root password; forwarded to `MYSQL_ROOT_PASSWORD` in compose |
| `KOHA_IMAGE_TAG` | `kosson/koha-ubuntu:latest` | Docker Hub image tag; used by `image:` in compose |
| `ENABLE_PLUGINS` | `no` | Enables the plugin-install loop in `run.sh` when set to `yes` |

## Files changed

| File | Change |
|---|---|
| `Dockerfile` | PATH fix; stronger apt settings; `apt-install-retry` helper; all installs converted; CRLF normalization post-COPY; `CMD` directive |
| `files/run.sh` | Header note + version stamp; OpenSearch wait loop; ES/Zebra sed hacks; CRLF normalization for migration tools and .pl/.cgi; graceful koha-plack/koha-z3950 enable |
| `docker-compose.yml` | `image: ${KOHA_IMAGE_TAG}` for pull support; `MYSQL_ROOT_PASSWORD` parameterized; named `koha-db-data` volume |
| `env/defaults.env` | Added `KOHA_DB_ROOT_PASSWORD`, `KOHA_IMAGE_TAG`, `ENABLE_PLUGINS` |

Revisited later on

### HTTP → HTTPS redirect

The `redirect-to-https` middleware is defined in the Koha service labels but is **not applied** by default (the router middleware lines are commented out). This is intentional: enabling the redirect before Let's Encrypt certs are confirmed working creates a redirect loop that blocks the HTTP-01 challenge (which needs plain HTTP on port 80).

Operator workflow:

1. Enable `TLS_CERTRESOLVER=letsencrypt` and start the stack.
2. Confirm `https://` URLs work with a valid cert.
3. Uncomment the two redirect middleware lines in `docker-compose.yml`.
4. Restart the Koha service.

## Changes made

### `traefik/.env`

Added `ACME_EMAIL` variable after `TRAEFIK_DASHBOARD_PORT`:

```bash
# ── Let's Encrypt (ACME) ─────────────────────────────────────────────────────
# Contact email for Let's Encrypt certificate registration.
# Requirements: valid monitored address; port 80 internet-reachable; real public
# KOHA_DOMAIN; TLS_CERTRESOLVER=letsencrypt in env/.env AND OpenSearch-3.6/.env.
# Leave empty for local/offline development (Traefik uses self-signed fallback).
ACME_EMAIL=
```

### `traefik/docker-compose.yaml`

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

### `env/.env`

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

### `OpenSearch-3.6/.env`

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

### `docker-compose.yml` (Koha stack)

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

### `OpenSearch-3.6/docker-compose.yml`

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

### `stack.sh`

Added four new config variable reads:

```bash
TRAEFIK_HTTPS_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTPS_PORT 443)"
ACME_EMAIL="$(_env_val "${TRAEFIK_DIR}/.env" ACME_EMAIL "")"
DASHBOARDS_DOMAIN="$(_env_val "${OPENSEARCH_DIR}/.env" DASHBOARDS_DOMAIN "dashboards.localhost")"
TLS_CERTRESOLVER="$(_env_val "${KOHA_ENV_FILE}" TLS_CERTRESOLVER "")"
```

Updated `follow_logs()` access banner: when `TLS_CERTRESOLVER` is non-empty, the HTTPS protocol (`https://`) and HTTPS port suffix are used for the displayed URLs; Dashboards URL uses `${DASHBOARDS_DOMAIN}`.

## To enable Let's Encrypt in production

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

## Files changed

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