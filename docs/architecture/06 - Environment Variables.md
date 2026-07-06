---
title: "Environment Variables"
tags: [environment, variables, .env, credentials, secrets, derived-variables, domain-strategy, nip.io, password-sync]
---

# Environment Variables

Three `.env` files control the entire stack. Each has a different scope.

---

## Main Config: `env/.env`

Used by: `docker-compose.yml` (koha service), `stack.sh`, `traefik/`

| Variable | Purpose | Default | Notes |
|---|---|---|---|
| `KOHA_DOMAIN` | Base domain for routing | `.myDNSname.org` | Use `.127.0.0.1.nip.io` for local dev |
| `KOHA_INSTANCE` | Koha instance name | `kohadev` | Becomes part of container name |
| `KOHA_OPAC_PORT` | OPAC HTTP port | `8080` | Exposed to host |
| `KOHA_INTRANET_PORT` | Staff HTTP port | `8081` | Exposed to host |
| `KOHA_DB_ROOT_PASSWORD` | MariaDB root password | `[REDACTED]` | ⚠️ plaintext in file |
| `KOHA_DB_PASSWORD` | Koha DB user password | `[REDACTED]` | ⚠️ plaintext in file |
| `KOHA_INTRANET_SUFFIX` | Staff URL suffix | `-intra` | Result: `kohadev-intra.myDNSname.org` |
| `KOHA_ELASTICSEARCH` | Enable OpenSearch | `no` | Set to `yes` to enable search |
| `REBUILD_OPENSEARCH_INDEX` | Rebuild index on startup | `yes` | Takes time on first run |
| `ELASTIC_OPTIONS` | OS connection + auth | See below | Password synced by stack.sh |
| `OPENSEARCH_CA_CERT` | Path to root CA cert | `/dev/null` | Enable TLS for Koha → OS |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | OS admin password | `[REDACTED]` | Must match OpenSearch-3.6/.env |
| `OS_CLUSTER_NAME` | OpenSearch cluster name | `koha-cluster` | — |
| `OS_SEARCH_SNAPSHOT_SIZE` | Search cache size | `5%` | os05 node only |
| `LOAD_DEMO_DATA` | Load MARC sample data | `yes` | 436 records, ~400KB |
| `SYNC_REPO` | Host Koha source path | `/home/kosson/Documents/koha` | Bind mount target |
| `OPENSEARCH_VERSION` | OS version tag | `3.6.0` | Used in image name |
| `KOHA_VERSION` | Koha version | `26.06.00.000` | — |
| `DB_IMAGE` | MariaDB image | `mariadb:10.11` | — |
| `KOHA_IMAGE_TAG` | Koha image tag | `kosson/koha-ubuntu:latest` | — |
| `MEMCACHED_IMAGE` | Memcached image | `memcached` | — |
| `TLS_CERTRESOLVER` | Traefik TLS cert | `""` (self-signed) | Use `letsencrypt` for Let's Encrypt |
| `ACME_EMAIL` | ACME email for LE | — | Required if TLS_CERTRESOLVER=letsencrypt |
| `DASHBOARDS_DOMAIN` | Dashboards host | `dashboards.localhost` | — |
| `STAFF_URL` | Staff URL template | — | — |
| `OPAC_URL` | OPAC URL template | — | — |
| `LOAD_PACKAGES` | Install packages at startup | `no` | — |
| `INSTALL_MISSING_FROM_CPMFILE` | Run cpanm --installdeps . | `no` | — |
| `KOHA_OPAC_URL` | Full OPAC URL | Generated | — |
| `KOHA_INTRANET_URL` | Full Staff URL | Generated | — |
| `KOHA_OPAC_HOSTNAME` | OPAC hostname | Generated | — |
| `KOHA_INTRANET_HOSTNAME` | Staff hostname | Generated | — |
| `KOHA_DB_HOST` | MariaDB host | `db` | Internal |
| `KOHA_DB_PORT` | MariaDB port | `3306` | Internal |
| `KOHA_DB_NAME` | Database name | `koha_kohadev` | — |
| `KOHA_DB_USER` | DB user | `koha_kohadev` | — |
| `MESSAGE_BROKER_HOST` | RabbitMQ host | `rabbitmq` | External broker container |
| `MESSAGE_BROKER_PORT` | RabbitMQ STOMP port | `61613` | External broker container |
| `MESSAGE_BROKER_USER` | RabbitMQ user | `koha` | External broker container |
| `MESSAGE_BROKER_PASS` | RabbitMQ password | `password` | External broker container |
| `MESSAGE_BROKER_VHOST` | RabbitMQ vhost | `koha_kohadev` | External broker container |
| `START_APACHE` | Start Apache | `yes` | — |
| `START_RABBITMQ` | Start RabbitMQ | `no-op` | Legacy toggle; broker now runs separately |
| `START_KOHA_SERVICE` | Start Koha | `yes` | — |
| `START_KOHA_JOB_WORKER` | Start job worker | `yes` | — |
| `ENABLE_APACHE` | Enable Apache config | `yes` | — |
| `ENABLE_APACHE_SSL` | Enable Apache SSL | `no` | — |

### ELASTIC_OPTIONS Structure

```xml
<elasticsearch>
  <config>
    <hosts>http://os01:9200</hosts>
    <userinfo><username>admin</username><password>changeme</password></userinfo>
  </config>
</elasticsearch>
```

The `<userinfo>` section is auto-synced by `stack.sh` to match `OPENSEARCH_INITIAL_ADMIN_PASSWORD`.

---

## OpenSearch Config: `OpenSearch-3.6/.env`

Used by: `OpenSearch-3.6/docker-compose.yml`

| Variable | Purpose | Default |
|---|---|---|
| `OPEN_SEARCH_VERSION` | Docker image tag | `3.6.0` |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | Admin password | `changeme` |
| `OS_CLUSTER_NAME` | Cluster name | `koha-cluster` |
| `OPENSEARCH_JAVA_OPTS` | JVM options | `-Xms1g -Xmx1g` (or larger) |

---

## Traefik Config: `traefik/.env`

Used by: `traefik/docker-compose.yaml`

| Variable | Purpose | Default |
|---|---|---|
| `TRAEFIK_HTTP_PORT` | HTTP entrypoint | `8000` |
| `TRAEFIK_HTTPS_PORT` | HTTPS entrypoint | `8443` |
| `TRAEFIK_DASHBOARD_PORT` | Dashboard API | `8083` |
| `ACME_EMAIL` | Let's Encrypt email | — |

---

## Generated (Derived) Variables

These are computed by `stack.sh` from the env files:

| Variable | Computed From | Example |
|---|---|---|
| `OPAC_HOST` | `${KOHA_INSTANCE}${KOHA_DOMAIN}` | `kohadev.myDNSname.org` |
| `STAFF_HOST` | `${KOHA_INSTANCE}${KOHA_INTRANET_SUFFIX}${KOHA_DOMAIN}` | `kohadev-intra.myDNSname.org` |
| `DB_CONTAINER` | `koha-docker-db-1` | — |
| `MEM_CONTAINER` | `koha-docker-memcached-1` | — |
| `KOHA_CONTAINER` | `koha-docker-koha-1` | — |
| `DB_NAME` | `koha_${KOHA_INSTANCE}` | `koha_kohadev` |
| `DB_USER` | `koha_${KOHA_INSTANCE}` | `koha_kohadev` |

---

## Secrets Management (⚠️ Critical)

All passwords are stored in **plaintext** in `.env` files. This is a documented security risk (ISSUES.md).

Current secrets:
- `KOHA_DB_ROOT_PASSWORD` — MariaDB root
- `KOHA_DB_PASSWORD` — Koha DB user
- `OPENSEARCH_INITIAL_ADMIN_PASSWORD` — OpenSearch admin
- Git Bugzilla password in `ELASTIC_OPTIONS` userinfo

**Recommendation from ISSUES.md**: Move all secrets to a gitignored `env/.env` file (or `env/secrets.env`) and keep `env/defaults.env` with only non-secret defaults.

---

## Domain Strategy

### nip.io (recommended for local dev)
Set `KOHA_DOMAIN=.127.0.0.1.nip.io`

This means:
- OPAC: `kohadev.127.0.0.1.nip.io` → resolves to 127.0.0.1 automatically
- Staff: `kohadev-intra.127.0.0.1.nip.io` → same
- No `/etc/hosts` edits needed
- Traefik routes by Host header

### Custom domain
Set `KOHA_DOMAIN=.myDNSname.org` and add entries to `/etc/hosts`:
```
127.0.0.1 kohadev.myDNSname.org
127.0.0.1 kohadev-intra.myDNSname.org
127.0.0.1 dashboards.myDNSname.org
```
