---
title: "Container Breakdown"
tags: [containers, koha, mariadb, memcached, opensearch, dashboards, traefik, resources, volumes, capabilities]
---

# Container Breakdown

Detailed breakdown of every container in the stack.

---

## koha (Main Application Container)

**Image**: `kosson/koha-ubuntu:latest` (custom-built from Dockerfile)
**Container user**: `kohadev-koha` (UID 1000)
**Host mount**: `${SYNC_REPO}` → `/kohadevbox/koha`

### What it runs

- **Apache2** (mod_mpm_prefork, not event) — serves OPAC (:8080) and Staff (:8081)
- **Koha instance** (`kohadev`) — Perl-based ILS
- **Background job workers** — via `koha-common`, connects to RabbitMQ STOMP (port 61613)
- **RabbitMQ** — message broker for background jobs (MARC import, indexing)
- **Node.js + Yarn** — JavaScript build tools for Koha frontend

### Volumes

| Mount | Purpose |
|---|---|
| `${SYNC_REPO}` → `/kohadevbox/koha` | Koha source tree (bind mount, read-write) |
| `${OPENSEARCH_CA_CERT}` → `/kohadevbox/opensearch-root-ca.pem` | Root CA for OS TLS |
| tmpfs `/cover_db` | Code coverage temp files |
| tmpfs `/tmp` | Temporary files |

### Capabilities

⚠️ `cap_add: ALL` — grants every Linux capability. See [[13 - Security Audit (ISSUES.md)]].

### Ulimits

- `nofile`: soft/hard 65536

### Key Environment Variables

See [[06 - Environment Variables]].

---

## db (MariaDB)

**Image**: `mariadb:10.11`
**Container name**: `koha-docker-db-1`

### Configuration

- SQL mode: `STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION`
- Database: `koha_kohadev`
- User: `koha_kohadev`
- Root password: from `KOHA_DB_ROOT_PASSWORD`

### Volumes

- `koha-db-data` → `/var/lib/mysql` (named volume, persists across restarts)

### Network

- `kohanet` only — not exposed to host

---

## memcached

**Image**: `memcached` (default, latest)
**Container name**: `koha-docker-memcached-1`

### Configuration

- Command: `memcached -m 64m` (64 MB limit)
- Port: 11211 (internal only)

### Network

- `kohanet` only

---

## OpenSearch Cluster (os01–os05)

**Image**: `kosson/opensearch-icu:3.6.0` (custom build from `OpenSearch-3.6/assets/opensearch/Dockerfile`)
**Data**: bind-mounted to `./assets/opensearch/data/osXXdata` on host

### Node Roles

| Node | Roles | Purpose |
|---|---|---|
| `os01` | `cluster_manager` | Cluster coordination, has health check |
| `os02` | `cluster_manager`, `data`, `ingest` | Coordinates + stores data |
| `os03` | `data`, `ingest` | Data storage + ingestion |
| `os04` | `data`, `ingest` | Data storage + ingestion |
| `os05` | `search` | Search-only node, has snapshot cache |

### Ports

| Port | Purpose | Exposed to Host? |
|---|---|---|
| 9200 | REST API | Yes (on os01) |
| 9600 | Performance Analyzer | Yes (on os01) |
| Internal | Transport (node-to-node) | No |

### Health Check (os01 only)

```
curl -ks --fail --cert admin.pem --key admin-key.pem \
  https://os01:9200/_cluster/health?wait_for_status=yellow&timeout=2s
```
Interval: 5s, Timeout: 10s, Retries: 30

### Ulimits

- `memlock`: soft/hard -1 (unlimited — requires rootful Docker)
- `nofile`: soft/hard 65536

### JVM Settings

- `bootstrap.memory_lock=true` (locks heap in RAM, no swap)
- `OPENSEARCH_JAVA_OPTS` (from `.env`)

---

## dashboards (OpenSearch Dashboards)

**Image**: `opensearchproject/opensearch-dashboards:3.6.0`
**Container name**: `dashboards`

### Configuration

- Connects to os01 and os02 via HTTPS
- Config: `opensearch_dashboards.yml` (bind-mounted)
- TLS certs: root-ca, admin, dashboards (all from `./assets/ssl/`)

### Ports

- 5601 → host
- Via Traefik with Host rule: `dashboards.{DASHBOARDS_DOMAIN}`

### Dependencies

- `os01` must be `service_healthy` before starting

---

## traefik (Reverse Proxy)

**Image**: `traefik:v3.x` (implied, version not in .env)
**Container name**: `traefik`

### Entrypoints

| Entry | Port | Purpose |
|---|---|---|
| `web` | `TRAEFIK_HTTP_PORT` (default 8000) | HTTP routing |
| `websecure` | `TRAEFIK_HTTPS_PORT` (default 8443) | HTTPS routing |

### Labels (from koha service)

- `traefik.http.routers.koha-opac` → Host: `kohadev.{domain}` → koha:8080
- `traefik.http.routers.koha-staff` → Host: `kohadev-intra.{domain}` → koha:8081
- `traefik.http.routers.dashboards` → Host: `dashboards.{domain}` → dashboards:5601
- Optional: HTTP → HTTPS redirect middleware (commented out by default)

### ACME / Let's Encrypt

- Configured in `traefik/.env` via `ACME_EMAIL`
- `TLS_CERTRESOLVER=letsencrypt` in `env/.env` enables it
- Requires port 80 reachable from internet + real public domain

### Dashboard API

- Internal ping: `wget -q -O- http://127.0.0.1:8082/ping`
- HTTP API: `localhost:TRAEFIK_DASHBOARD_PORT` (default 8083)
