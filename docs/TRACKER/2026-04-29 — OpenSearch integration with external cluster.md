---
title: OpenSearch integration with external cluster
date: 2026.04.29
tags:
 - OpenSearch
 - cluster
 - knonikl
 - networking
 - connections
---
# 2026-04-29 — OpenSearch integration with external cluster

## Goal

Connect the `koha-docker` Koha instance to the external 5-node OpenSearch 3.6 cluster that runs in a separate Docker Compose project (`cluster-opensearch/OpenSearch-3.6/`).

## Architecture overview

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

## How Koha uses OpenSearch

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

## TLS / authentication

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

The default config in `env/.env` uses the bypass approach (`PERL_LWP_SSL_VERIFY_HOSTNAME=0`) which is appropriate for local development.

## Docker network

The `knonikl` network is defined in the OpenSearch cluster's `docker-compose.yml`. Without an explicit `name:` it would be prefixed with the Docker Compose project name (e.g., `opensearch-36_knonikl`), making it impossible to reference predictably from another project.

**Fix applied to `cluster-opensearch/OpenSearch-3.6/docker-compose.yml`:**

```yaml
networks:
  osearch:
  knonikl:
    name: knonikl     # ← added: pins the Docker network name regardless of project prefix
```

After this change, `docker network ls | grep knonikl` will always show the network as `knonikl`. The OpenSearch cluster must be started **before** `koha-docker` so the network exists when Koha's compose attempts to join it.

## Changes made

### `cluster-opensearch/OpenSearch-3.6/docker-compose.yml`

Added `name: knonikl` to the `knonikl` network definition so it has a stable, project-independent name that other compose projects can reference with `external: true`.

### `koha-docker/docker-compose.yml`

1. **Added `knonikl` as an external network** at the bottom of the `networks:` block:

---
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
---

4. **Exposed new environment variables** to the koha container:

```yaml
   ELASTIC_SERVER: ${ELASTIC_SERVER:-es:9200}
   ELASTIC_OPTIONS: ${ELASTIC_OPTIONS:-}
   OPENSEARCH_INITIAL_ADMIN_PASSWORD: ${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}
   PERL_LWP_SSL_VERIFY_HOSTNAME: ${PERL_LWP_SSL_VERIFY_HOSTNAME:-1}
```

### `koha-docker/env/.env`

| Variable | Old value | New value |
|----------|-----------|-----------|
| `KOHA_ELASTICSEARCH` | ` ` (empty) | `yes` |
| `ELASTIC_SERVER` | `es:9200` | `https://admin:test%40Cici24%23ANA@os01:9200` |
| `PERL_LWP_SSL_VERIFY_HOSTNAME` | (absent) | `0` |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | `pu1kohphei4heeY4pai7ohp6vei4Ea6i` | `"test@Cici24#ANA"` |

`OPENSEARCH_CA_CERT` is documented as a comment for when proper cert verification is needed.

## Startup order

1. docker network create frontend       # only if not already present
2. cd koha-docker/traefik && docker compose up -d
3. cd cluster-opensearch/OpenSearch-3.6 && docker compose up -d
4. # Wait for cluster health: curl -k -u admin:'test@Cici24#ANA' https://localhost:9200/_cluster/health
5. cd koha-docker && docker compose up -d

Koha's `run.sh` calls `do_all_you_can_do.pl --elasticsearch` which creates the OpenSearch indexes (`koha_kohadev_biblios`, `koha_kohadev_authorities`, `koha_kohadev_items`) on first startup. Subsequent starts skip index creation if indexes already exist.
d
## Known limitations / future work

- The admin account is used for all Koha→OpenSearch operations. A dedicated `koha` service account with restricted permissions should be created for production use.
- `PERL_LWP_SSL_VERIFY_HOSTNAME=0` disables TLS verification globally for the Perl process. For production, mount the root CA and use `PERL_LWP_SSL_CA_FILE` instead.
- If the OpenSearch cluster is restarted and indexes are recreated, Koha's mappings must be reset via Koha admin → Search engine configuration → Reset mappings.
