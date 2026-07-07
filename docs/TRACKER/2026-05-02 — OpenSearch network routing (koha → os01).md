---
title: OpenSearch network routing (koha → os01)
date: 2026.05.02
tags:
 - OpenSearch
 - networking
 - routing
---
# 2026-05-02 — OpenSearch network routing (koha → os01)

## Symptom

After the UID fix the container initialised successfully and all `sudo koha-shell` steps passed, but `rebuild_elasticsearch.pl` failed at the very end with:

```log
[NoNodes] ** No nodes are available: [https://os01:9200]
```

The container then exited with code 0 (the error is non-fatal from `run.sh`'s perspective), but the search indexes were never built, meaning the catalogue would return no results.

## Analysis

### How the OpenSearch cluster is structured

The OpenSearch 3.6 cluster (`koha-docker/OpenSearch-3.6/`) is a separate Docker Compose project. It creates two Docker networ# 2026-05-02 — OpenSearch network routing (koha → os01)

## Symptom

After the UID fix the container initialised successfully and all `sudo koha-shell` steps passed, but `rebuild_elasticsearch.pl` failed at the very end with:

```log
[NoNodes] ** No nodes are available: [https://os01:9200]
```

The container then exited with code 0 (the error is non-fatal from `run.sh`'s perspective), but the search indexes were never built, meaning the catalogue would return no results.

## Analysis

### How the OpenSearch cluster is structured

The OpenSearch 3.6 cluster (`koha-docker/OpenSearch-3.6/`) is a separate Docker Compose project. It creates two Docker networks:

| Network | Purpose | Who joins it |
|---|---|---|
| `opensearch-36_osearch` | Internal cluster traffic (port 9200, 9300) | os01, os02, os03, os04, os05 |
| `knonikl` | External bridge (exposed to other projects) | os01, dashboards |

`os01` is the cluster-manager node and it **listens for HTTP/HTTPS on port 9200 only on `172.28.0.3`**, which is its `opensearch-36_osearch` network address. It does **not** bind to `0.0.0.0`.

### Why the first approach failed

The koha container was attached to `koha-docker_kohanet` (internal) and `knonikl` (external bridge). The intent was to reach `os01` via `knonikl`.

Two problems:

1. **`os01` was not on `knonikl`**. The `knonikl` network was originally used in an older architecture to connect OpenSearch Dashboards to the Koha proxy. `os01` itself    only had an IP on `opensearch-36_osearch`.
2. **Even after manually connecting `os01` to `knonikl`**, the connection still failed. When `os01` was added to `knonikl` at runtime (`docker network connect knonikl os01`), it got a `172.30.x.x` address on that network, but its OpenSearch process still only listened on `172.28.0.3:9200`. Any TCP SYN sent to `172.30.x.x:9200` went unanswered.

### Root cause

The koha container needed to be on the **same network as the OpenSearch nodes**, i.e., `opensearch-36_osearch`. From that network, `os01` is reachable at `172.28.0.3:9200`
and its hostname `os01` resolves correctly via Docker's internal DNS.

## Fix

Declared `opensearch-36_osearch` as an **external** network in `koha-docker/docker-compose.yml` and attached the `koha` service to it:

```yaml
# koha service — networks section
networks:
  kohanet:
    aliases:
      - "${KOHA_INTRANET_PREFIX}${KOHA_INSTANCE}..."
      - "${KOHA_OPAC_PREFIX}${KOHA_INSTANCE}..."
  knonikl: {}
  opensearch-36_osearch: {}      # ← ADDED

# top-level networks declaration
networks:
  kohanet:
    enable_ipv4: true
    enable_ipv6: false
  knonikl:
    external: true
  opensearch-36_osearch:          # ← ADDED
    external: true
```

With this change:

- The koha container joins `opensearch-36_osearch` at startup.
- Docker's internal DNS resolves `os01` to `172.28.0.3`.
- TCP connections to `os01:9200` succeed.

**Startup order constraint**: The OpenSearch cluster (`koha-docker/OpenSearch-3.6/`) must be running **before** `docker compose up` is issued for `koha-docker`, because Docker refuses to start a compose project that references a non-existent external network.

## Files changed

| File | Change |
|---|---|
| `koha-docker/docker-compose.yml` | Added `opensearch-36_osearch: {}` to `koha` service networks; added `opensearch-36_osearch: external: true` to top-level `networks:` block |ks:

| Network | Purpose | Who joins it |
|---|---|---|
| `opensearch-36_osearch` | Internal cluster traffic (port 9200, 9300) | os01, os02, os03, os04, os05 |
| `knonikl` | External bridge (exposed to other projects) | os01, dashboards |

`os01` is the cluster-manager node and it **listens for HTTP/HTTPS on port 9200 only on `172.28.0.3`**, which is its `opensearch-36_osearch` network address. It does **not** bind
to `0.0.0.0`.

### Why the first approach failed

The koha container was attached to `koha-docker_kohanet` (internal) and `knonikl` (external bridge). The intent was to reach `os01` via `knonikl`.

Two problems:

1. **`os01` was not on `knonikl`**. The `knonikl` network was originally used in an older architecture to connect OpenSearch Dashboards to the Koha proxy. `os01` itself only had an IP on `opensearch-36_osearch`.

2. **Even after manually connecting `os01` to `knonikl`**, the connection still failed. When `os01` was added to `knonikl` at runtime (`docker network connect knonikl os01`), it got a `172.30.x.x` address on that network, but its OpenSearch process still only listened on `172.28.0.3:9200`. Any TCP SYN sent to `172.30.x.x:9200` went unanswered.

### Root cause

The koha container needed to be on the **same network as the OpenSearch nodes**, i.e., `opensearch-36_osearch`. From that network, `os01` is reachable at `172.28.0.3:9200`
and its hostname `os01` resolves correctly via Docker's internal DNS.

## Fix

Declared `opensearch-36_osearch` as an **external** network in `koha-docker/docker-compose.yml` and attached the `koha` service to it:

```yaml
# koha service — networks section
networks:
  kohanet:
    aliases:
      - "${KOHA_INTRANET_PREFIX}${KOHA_INSTANCE}..."
      - "${KOHA_OPAC_PREFIX}${KOHA_INSTANCE}..."
  knonikl: {}
  opensearch-36_osearch: {}      # ← ADDED

# top-level networks declaration
networks:
  kohanet:
    enable_ipv4: true
    enable_ipv6: false
  knonikl:
    external: true
  opensearch-36_osearch:          # ← ADDED
    external: true
```

With this change:

- The koha container joins `opensearch-36_osearch` at startup.
- Docker's internal DNS resolves `os01` to `172.28.0.3`.
- TCP connections to `os01:9200` succeed.

**Startup order constraint**: The OpenSearch cluster (`koha-docker/OpenSearch-3.6/`) must be running **before** `docker compose up` is issued for `koha-docker`, because
Docker refuses to start a compose project that references a non-existent external network.

## Files changed

| File | Change |
|---|---|
| `koha-docker/docker-compose.yml` | Added `opensearch-36_osearch: {}` to `koha` service networks; added `opensearch-36_osearch: external: true` to top-level `networks:` block |