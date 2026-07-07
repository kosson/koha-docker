---
title: Port Windows version improvements to koha-ubuntu image
date: 2026-05-15
tags:
 - Windows
 - porting
---
# 2026-05-15 — Port Windows version improvements to koha-ubuntu image

## Goal

Synchronise `koha-docker` (Linux/Ubuntu image) with the improvements developed in `koha-docker-windows` (https://github.com/kosson/koha-docker-windows) and prepare the project for publishing a reusable `kosson/koha-ubuntu` image to Docker Hub, mirroring the existing `kosson/koha-windows` image.

## Source

All changes analysed from `koha-docker-windows` at commit `main` (2026-05-08).
Windows-specific workarounds (CRLF inotifywait watcher, `azure.archive.ubuntu.com` mirror swap, `--no-check-certificate` for nodesource) were deliberately **excluded** as they address Hyper-V/WSL2 issues that do not apply to native Linux builds.

## Changes made to `Dockerfile`

### 1. `PATH` — add `/usr/local/bin`

```dockerfile
# Before
ENV PATH=/usr/bin:/bin:/usr/sbin:/sbin

# After
ENV PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
```

`/usr/local/bin` is where the new `apt-install-retry` helper is placed. Without it at the front of `PATH`, subsequent `RUN` layers that call `apt-install-retry` by name would not find it.

### 2. `REFRESHED_AT` date

Updated to `2026-05-15`.

### 3. Stronger apt resilience settings

`/etc/apt/apt.conf.d/80-retries` was expanded from two directives to five:

| Directive | Old | New | Reason |
|---|---|---|---|
| `Acquire::Retries` | `"5"` | `"8"` | More retry budget for slow mirrors |
| `Acquire::http::Timeout` | `"120"` | `"600"` | Generous timeout for large packages |
| `Acquire::https::Timeout` | *(absent)* | `"600"` | Same for HTTPS sources |
| `Acquire::Queue-Mode` | *(absent)* | `"host"` | One sequential queue per hostname — keeps connections active, prevents mid-download idle timeouts |
| `Acquire::Max-FutureTime` | *(absent)* | `"86400"` | Tolerates up to 24 h VM clock drift after host sleep |

### 4. New `apt-install-retry` helper script

A small POSIX shell wrapper placed in `/usr/local/bin/apt-install-retry` replaces every bare `apt-get update && apt-get -y install` call in the Dockerfile. It:

- Runs `apt-get update` + `apt-get -y install "$@"` in a loop (up to 4 attempts)
- Passes `-o Acquire::Max-FutureTime=86400` inline on every attempt so the clock-skew tolerance applies even before the conf layer is cached by Docker
- Removes `/var/lib/apt/lists/*` between retries (forces a fresh index fetch) but does **not** `apt-get clean` (preserves partial `.deb` files so apt can resume via HTTP
  Range requests on the next attempt)
- Exits non-zero after the final attempt, causing the `RUN` layer to fail visibly

### 5. All package install blocks converted to `apt-install-retry`

Every `RUN apt-get update && apt-get -y install ... && rm -rf /var/cache/apt/...` block was replaced with `RUN /bin/sh /usr/local/bin/apt-install-retry <packages>`. The trailing `rm -rf` cleanup is handled inside the helper on success.

This also eliminates the `koha-common` special case that had a separate `apt-get -y update` before install.

### 6. CRLF normalization after `COPY`

```dockerfile
# Ensure Linux line endings even when the repository is checked out or edited
# with CRLF (cross-platform contributors). Safe to run unconditionally.
RUN sed -i 's/\r$//' /kohadevbox/run.sh \
    && find /kohadevbox/templates -type f -exec sed -i 's/\r$//' {} + \
    && find /kohadevbox/git_hooks  -type f -exec sed -i 's/\r$//' {} + \
    && chmod +x /kohadevbox/run.sh
```

Applied immediately after the `COPY` statements so the files are clean before any container uses them, regardless of the editor or OS used by contributors.

### 7. `CMD` directive

```dockerfile
CMD ["/bin/bash", "/kohadevbox/run.sh"]
```

Makes the built image directly runnable as `docker run kosson/koha-ubuntu` without requiring an explicit command override. This is required for the image to be usable as a pull-and-run target from Docker Hub.

## Changes made to `files/run.sh`

### 1. Header note and version stamp

```bash
# run.sh — Koha container entrypoint.
# NOTE: This file is BAKED INTO THE IMAGE at build time (see Dockerfile: COPY files/run.sh).
# Editing this file on the host has NO effect until the image is rebuilt:
#   ./stack.sh start -b   (or docker compose build)
# RUN_SH_VERSION=2026-05-15
```

Prevents the common mistake of editing `run.sh` on the host and expecting a runni


## 2026-05-19 — Fix OpenSearch Dashboards routing through Traefik; add network diagnostic script

### Goal

Diagnose and fix a 502 Bad Gateway error when accessing OpenSearch Dashboards through Traefik, document the OpenSearch TLS certificate setup in `README.md`, and create a comprehensive network diagnostic script for ongoing operational use.

### Problem: Dashboards returned 502 via Traefik

Traefik was proxying plain HTTP to the Dashboards container, but the container was listening on **HTTPS** (`server.ssl.enabled: true`). The Dashboards log showed:

```log
SSL routines: tls_validate_record_header: http request
```

This is an `ERR_SSL_HTTP_REQUEST` — the container received an HTTP request on a port that expected TLS handshake bytes.

A secondary issue: `opensearch_security.cookie.secure: true` means the browser will only send the session cookie over HTTPS connections. Because Traefik acts as an HTTP proxy (not TLS passthrough), the cookie would never be sent back, making login impossible even if the 502 were resolved at the TCP level.

## Fix 1 — Disable server-side TLS on Dashboards

**File:** `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml`

Disabled the server-facing TLS so that Dashboards listens on plain HTTP and Traefik's default HTTP proxy scheme works correctly. The Dashboards → OpenSearch **backend** TLS (mutual authentication with the admin cert and root CA) remains fully active.

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

```log
Server running at http://0.0.0.0:5601
```

## Fix 2 — Add explicit Traefik service labels for Dashboards

**File:** `OpenSearch-3.6/docker-compose.yml`

Without an explicit service name and port label, Traefik auto-detected the backend but used an incorrect scheme. Added a named service and the port to ensure correct HTTP routing to port 5601.

```yaml
# Added to dashboards service labels:
- traefik.http.routers.dashboards.service=dashboards-svc
# Explicit port — required because server.ssl.enabled=false makes the container
# listen on plain HTTP; without this label Traefik may auto-detect the wrong port.
- traefik.http.services.dashboards-svc.loadbalancer.server.port=5601
```

## New file: `netcheck.sh`

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


## README.md additions

- New section `## One-time setup — OpenSearch TLS certificates` (inserted before `## Prerequisites`). Covers: what files are pre-generated, cert validity (730 days), when/how to regenerate, warning about security plugin state on regeneration.
- Updated repository layout tree to include `opensearch_installer_vars.cfg` and   `opensearch_local_certificates_creator.sh`.

## Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml` | Disabled server TLS (`server.ssl.enabled: false`); disabled secure cookie |
| `OpenSearch-3.6/docker-compose.yml` | Added explicit Traefik service labels and port for the `dashboards` service |
| `netcheck.sh` | New file — comprehensive 13-section network diagnostic script |
| `README.md` | Added OpenSearch TLS certificate setup section; updated repo layout tree |