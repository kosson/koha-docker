---
title: "OpenSearch Cluster"
tags: [opensearch, cluster, os01, os02, os03, os04, os05, mTLS, health-checks, performance-analyzer, dashboards, custom-image, analysis-icu, memlock, rootless-docker]
---
# OpenSearch Cluster

Five-node cluster running OpenSearch 3.6 with mTLS security and performance monitoring.

## Architecture

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│   os01   │    │   os02   │    │   os03   │    │   os04   │    │   os05   │
│ Cluster  │    │ Cluster  │    │          │    │          │    │          │
│ Manager  │    │ Manager  │    │ Data     │    │ Data     │    │ Search   │
│          │    │ + Data   │    │ + Ingest │    │ + Ingest │    │          │
│ :9200    │    │          │    │          │    │          │    │          │
│ :9600    │    │          │    │          │    │          │    │          │
└──────────┘    └──────────┘    └──────────┘    └──────────┘    └──────────┘
```

## Node Details

### os01 — Cluster Manager (with host exposure)

| Property | Value |
|---|---|
| Role | `cluster_manager` |
| Container | `os01` |
| Host Ports | 9200 (REST), 9600 (Performance Analyzer) |
| Health Check | curl + client cert, 5s interval, 30 retries |
| Data Dir | `./assets/opensearch/data/os01data` (bind mount) |
| Configs | `jvm.options`, `log4j2.properties`, `opensearch.yml`, security configs |

**Config files** (all bind-mounted from `OpenSearch-3.6/assets/opensearch/config/os01/`):
- `opensearch.yml` — cluster settings, network, security
- `jvm.options` — JVM heap, GC settings
- `log4j2.properties` — logging configuration
- `opensearch-security/config.yml` — RBAC config
- `opensearch-security/internal_users.yml` — user definitions
- `opensearch-security/roles.yml` — role definitions
- `opensearch-security/roles_mapping.yml` — role-to-user mapping
- `opensearch-security/nodes_dn.yml` — node certificate DN list

### os02 — Cluster Manager + Data + Ingest

| Property | Value |
|---|---|
| Role | `cluster_manager`, `data`, `ingest` |
| Container | `os02` |
| Host Ports | None (internal only) |
| Data Dir | `./assets/opensearch/data/os02data` |
| Configs | Per-node configs from `os02/` directory |

### os03 — Data + Ingest

| Property | Value |
|---|---|
| Role | `data`, `ingest` |
| Container | `os03` |
| Host Ports | None |
| Data Dir | `./assets/opensearch/data/os03data` |

### os04 — Data + Ingest

| Property | Value |
|---|---|
| Role | `data`, `ingest` |
| Container | `os04` |
| Host Ports | None |
| Data Dir | `./assets/opensearch/data/os04data` |

### os05 — Search Node

| Property | Value |
|---|---|
| Role | `search` |
| Container | `os05` |
| Host Ports | None |
| Search Cache | `node.search.cache.size=${OS_SEARCH_SNAPSHOT_SIZE}` (default 5%) |
| Data Dir | `./assets/opensearch/data/os05data` |

## Cluster Configuration

### Common Settings (all nodes)

```yaml
cluster.name: ${OS_CLUSTER_NAME}              # "koha-cluster"
discovery.seed_hosts: os01,os02,os03,os04,os05
cluster.initial_cluster_manager_nodes: os01,os02
bootstrap.memory_lock: true                    # Lock heap in RAM
network.host: <node-name>                      # e.g., os01
network.publish_host: <node-name>
DISABLE_INSTALL_DEMO_CONFIG: true              # No demo users
```

### JVM Settings

- `OPENSEARCH_JAVA_OPTS` from `.env`
- Default: `-Xms1g -Xmx1g` (1 GB heap)
- `bootstrap.memory_lock=true` prevents JVM from swapping

### Ulimits

```yaml
ulimits:
  memlock:
    soft: -1   # Unlimited — requires rootful Docker
    hard: -1
  nofile:
    soft: 65536
    hard: 65536
```

⚠️ **Rootless Docker incompatibility**: `memlock: -1` requires `CAP_SYS_RESOURCE`. In rootless mode this fails. TRACKER.md documents the workaround: remove the ulimit block and set `bootstrap.memory_lock=false` for rootless mode.

## Custom Image: `kosson/opensearch-icu`

Built from `OpenSearch-3.6/assets/opensearch/Dockerfile`. Includes:
- Base OpenSearch 3.6
- analysis-icu plugin (for ICU-based text analysis — handles Unicode, collation)

### Build Process

```bash
# Only os01 has build: in the compose file
# os02-os05 reference the same image without building

docker compose -f OpenSearch-3.6/docker-compose.yml build os01
```

The image tag is `${OPEN_SEARCH_VERSION}` (default: `3.6.0`).

### Pre-flight Check

`stack.sh` checks if the image exists before starting:

```bash
if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "kosson/opensearch-icu:3.6.0"; then
  build_opensearch
fi
```

This means:
- First start: builds the image locally (no Docker Hub login needed)
- Subsequent starts: uses local image (pull_policy: never)
- After rebuild: `stack.sh reset` then `stack.sh start`

## Security Configuration

### Internal Users

Defined in `opensearch-security/internal_users.yml`:

| User | Password | Roles |
|---|---|---|
| `admin` | `${OPENSEARCH_INITIAL_ADMIN_PASSWORD}` | admin |

### Roles

Defined in `opensearch-security/roles.yml`:
- `admin` — full cluster access
- `all_access` — all indices
- `read_only` — read-only access
- Custom roles for Koha use cases

### Node Authentication

Each node authenticates to the cluster using its TLS cert. Node DNs are listed in `opensearch-security/nodes_dn.yml`.

## Performance Analyzer

Enabled on os01, exposed at `http://localhost:9600/` (host port 9600).

Config mounted from `./assets/opensearch/performance-analyzer/`.

Useful for:
- JVM heap usage trends
- Indexing rate, search latency
- Shard distribution analysis

## Dashboards (OpenSearch Dashboards)

| Property | Value |
|---|---|
| Image | `opensearchproject/opensearch-dashboards:3.6.0` |
| Container | `dashboards` |
| Host Port | 5601 |
| Traefik Host | `dashboards.{DASHBOARDS_DOMAIN}` |
| Depends On | os01 must be `service_healthy` |
| Networks | osearch, knonikl, frontend |

### Configuration

Bind-mounted `opensearch_dashboards.yml`:

```yaml
opensearch.hosts: ["https://os01:9200", "https://os02:9200"]
server.ssl.enabled: true
opensearch.ssl.verificationMode: certificate
```

### TLS Certs

- `root-ca.pem` — verify OS node certs
- `admin.pem` + `admin-key.pem` — authenticate to OS
- `dashboards.pem` + `dashboards-key.pem` — client cert

### Traefik Labels

```yaml
traefik.http.services.dashboards-svc.loadbalancer.server.port=5601
traefik.http.routers.dashboards.rule=Host(`dashboards.{DASHBOARDS_DOMAIN}`)
traefik.http.routers.dashboards-tls.rule=Host(`dashboards.{DASHBOARDS_DOMAIN}`)
traefik.http.routers.dashboards-tls.tls.certresolver=${TLS_CERTRESOLVER}
```

⚠️ The explicit port label (`loadbalancer.server.port=5601`) is required because `server.ssl.enabled=false` makes the container listen on plain HTTP. Without this label, Traefik may detect the wrong port.

## Cluster Health

### Check from Host

```bash
# Full health
curl -sk -u admin:changeme https://localhost:9200/_cluster/health

# Green = all primaries + replicas active
# Yellow = primaries active, some replicas missing (normal for 5-node single-machine)
# Red = primary shards missing (data loss risk)
```

### Check from Inside Koha

```bash
docker exec koha-docker-koha-1 \
  curl -sk -u admin:changeme https://os01:9200/_cluster/health
```

### Cluster Status

```bash
# Node info
curl -sk -u admin:changeme https://localhost:9200/_cat/nodes?v

# Shard allocation
curl -sk -u admin:changeme https://localhost:9200/_cat/shards?v

# Index stats
curl -sk -u admin:changeme https://localhost:9200/_cat/indices?v
```
