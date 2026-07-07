---
title: Fix OpenSearch Dashboards routing through Traefik; add network diagnostic script
date: 2026-05-19
tags:
 - OpenSearch
 - Dashboards
 - Trefik
 - diagnostic
 - script
---
# 2026-05-19 — Fix OpenSearch Dashboards routing through Traefik; add network diagnostic script

## Goal

Diagnose and fix a 502 Bad Gateway error when accessing OpenSearch Dashboards through Traefik, document the OpenSearch TLS certificate setup in `README.md`, and create a
comprehensive network diagnostic script for ongoing operational use.

## Problem: Dashboards returned 502 via Traefik

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

### Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml` | Disabled server TLS (`server.ssl.enabled: false`); disabled secure cookie |
| `OpenSearch-3.6/docker-compose.yml` | Added explicit Traefik service labels and port for the `dashboards` service |
| `netcheck.sh` | New file — comprehensive 13-section network diagnostic script |
| `README.md` | Added OpenSearch TLS certificate setup section; updated repo layout tree |
