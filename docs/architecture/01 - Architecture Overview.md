---
title: "Architecture Overview"
tags: [architecture, topology, overview, services, data-flow]
---

# Architecture Overview

The Koha Docker project is a self-contained, multi-container development environment for Koha ILS (version 25/26). It packages the entire stack — database, search, caching, web server, reverse proxy — into a reproducible Docker Compose setup.

## Topology

```
                          ┌─────────────────────────────────────┐
                          │            Host Machine              │
                          │                                      │
   Browser ──────────► traefik (Traefik reverse proxy)          │
      │                         │                                │
      │   HTTP :8000 / HTTPS    │   HTTPS :443 (Let's Encrypt)  │
      │                         │                                │
      │              ┌──────────┼──────────┐                     │
      │              │          │          │                     │
      ▼              ▼          ▼          ▼                     │
   OPAC         Staff      Dashboards  Traefik Dashboard        │
   :8080         :8081      :5601       :8083                   │
      │              │          │          │                     │
      │         ┌────┴────┐    │          │                     │
      │         │  koha   │    │          │                     │
      │         │container│    │          │                     │
      │         └────┬────┘    │          │                     │
      │              │         │          │                     │
      │         ┌────┴─────────┴──────────┴───┐                │
      │         │    Docker Networks (5 total) │                │
      │         └────┬─────────┬──────────┬───┘                │
      │              │         │          │                     │
      ▼              ▼         ▼          ▼                     │
   ┌────────┐  ┌──────────┐  ┌───────────┐  ┌──────────┐       │
   │   db   │  │  memcached│  │  os01-os05 │  │ dashboards│      │
   │MariaDB │  │  (port 11211)│ │OS 3.6 cluster│ │  :5601   │      │
   │ :3306  │  │            │  │  :9200      │  │          │      │
   └────────┘  └──────────┘  └───────────┘  └──────────┘       │
                          └─────────────────────────────────────┘
```

## Four Compose Projects

The setup uses **four separate `docker compose` contexts**, not one monolithic file:

| # | Project Dir | Compose File | Purpose |
|---|---|---|---|
| 1 | `.` (root) | `docker-compose.yml` | Main stack: koha, db, memcached |
| 2 | `OpenSearch-3.6/` | `docker-compose.yml` | 5-node OpenSearch cluster + Dashboards |
| 3 | `traefik/` | `docker-compose.yaml` | Traefik reverse proxy |
| 4 | N/A | N/A | Koha image built from `Dockerfile` at root |

Each project has its own `.env` file and is orchestrated by `stack.sh`.

## Service Summary

| Service | Image | Role | Ports (host) | Health Check |
|---|---|---|---|---|
| `koha` | `kosson/koha-ubuntu:latest` | Koha ILS web app + Apache | 8080 (OPAC), 8081 (Staff) | Log scraping (stack.sh) |
| `db` | `mariadb:10.11` | Relational database | (internal only) | Authenticated SELECT 1 |
| `memcached` | `memcached` | Caching layer | (internal only) | Stats ping |
| `os01` | `kosson/opensearch-icu:3.6.0` | Cluster manager node | 9200 (REST), 9600 (PA) | curl + client cert |
| `os02` | same | Manager + data + ingest | (internal) | — |
| `os03` | same | Data + ingest | (internal) | — |
| `os04` | same | Data + ingest | (internal) | — |
| `os05` | same | Search node | (internal) | — |
| `dashboards` | `opensearch-dashboards:3.6.0` | Search UI | 5601 (host), via Traefik | depends_on os01 healthy |
| `traefik` | `traefik:v3.x` | Reverse proxy + HTTPS | 8000 (HTTP), 8443 (HTTPS), 8083 (dashboard) | wget /ping |

## Data Flow

```
Browser
   │
   ▼
Traefik (terminates HTTPS, routes by Host header)
   │
   ├── KOHA_INSTANCE.{domain}     → koha:8080 (OPAC)
   ├── KOHA_INSTANCE-intra.{domain} → koha:8081 (Staff)
   └── dashboards.{domain}        → dashboards:5601
   │
   ▼
koha container (Apache + Perl + Koha instance)
   │
   ├── MariaDB (db:3306)          ← catalog data, patron data, system preferences
   ├── Memcached (memcached:11211) ← session/cache storage
   └── OpenSearch (os01:9200)     ← full-text search index
```

## Key Design Decisions

- **nip.io for zero-config DNS**: KOHA_DOMAIN=.127.0.0.1.nip.io means kohadev.127.0.0.1.nip.io resolves to your machine automatically. No /etc/hosts edits needed.
- **Bind mount for Koha source**: The entire Koha git repo is bind-mounted into the container at `/kohadevbox/koha`. This means host-side git operations are immediately visible inside the container.
- **External networks**: `frontend`, `knonikl`, `opensearch-36_osearch` are declared external so multiple compose projects can share them. `stack.sh` auto-creates them if missing.
- **OpenSearch from scratch**: The 5-node cluster is built with a custom image (`kosson/opensearch-icu`) that includes the analysis-icu plugin for Unicode text analysis. Data is bind-mounted to host directories.
- **Credential sync**: `stack.sh` syncs OpenSearch admin password between `env/.env` and `OpenSearch-3.6/.env` before starting the stack, preventing credential drift.

## Resource Requirements

- **RAM**: ~12 GB comfortable for the running stack
- **Host RAM**: Minimum 22 GB (OpenSearch 5 nodes + MariaDB + Koha + host OS)
- **Disk**: ≥ 15 GB (images + Koha source + OS data directories)
- **Virtualization**: Must be enabled in BIOS (Docker needs nested virtualization for some features)

## Files at a Glance

| File | Lines | Purpose |
|---|---|---|
| `stack.sh` | 722 | Main orchestrator — start, stop, reset, build, logs |
| `files/run.sh` | 585 | Koha container entrypoint — init, config, startup |
| `Dockerfile` | 236 | Koha image definition — packages, tools, repos |
| `docker-compose.yml` | 150 | Main compose: koha, db, memcached |
| `OpenSearch-3.6/docker-compose.yml` | 299 | 5-node OS cluster + Dashboards |
| `netcheck.sh` | 711 | Network diagnostics — every connection path |
| `apply-patches.sh` | 33 | Patch management for Koha source |
| `README.md` | 1369 | Extensive documentation |
| `TRACKER.md` | 4257 | Change log with root cause analysis |
| `ISSUES.md` | 247 | Security and stability audit |
