---
title: OpenSearch `analysis-icu` plugin missing
date: 2026.05.02
tags:
 - analysis-icu
 - OpenSearch
 - plugin
---
# 2026-05-02 — OpenSearch `analysis-icu` plugin missing

## Symptom

With all auth/SSL/product-check issues resolved, `rebuild_elasticsearch.pl` connected successfully but received HTTP 400 when trying to create the Koha search indexes:

```log
[Request] ** [https://os01:9200]-[400] [illegal_argument_exception]
Custom Analyzer [icu_folding_normalizer] failed to find filter under name [icu_folding]
```

## Analysis

### What Koha's Elasticsearch mappings require

Koha ships with a set of index configuration files under `koha/etc/searchengine/elasticsearch/`. These define custom analyzers for the `biblio` and `authority` indexes. The `marc21` mappings use three ICU analysis features:

| Feature | Type | Plugin component |
|---|---|---|
| `icu_tokenizer` | tokenizer | `analysis-icu` |
| `icu_folding` | token filter | `analysis-icu` |
| `icu_normalizer` | char filter | `analysis-icu` |

If any of these are referenced in the index settings but the plugin is not installed on OpenSearch, the index creation request returns HTTP 400 with `illegal_argument_exception`.

### Which nodes were missing the plugin

The OpenSearch cluster uses a custom `Dockerfile` in `koha-docker/OpenSearch-3.6/assets/opensearch/Dockerfile`. In the original file, only **`os01`** used the `build:` directive pointing to this Dockerfile. **`os02`–`os05`** used `image: opensearchproject/opensearch:${OPEN_SEARCH_VERSION}` directly, meaning they were started from the unmodified base image with no custom packages.

Even if the Dockerfile had included the `analysis-icu` plugin, the four data/ingest/search nodes would not have it. OpenSearch requires all nodes in a cluster to have the same plugins installed; a plugin must be present on every node that handles index shards.

Confirming with the OpenSearch API:

```bash
curl -sk -u 'admin:...' https://localhost:9200/_cat/plugins?v
# Result: (empty — no plugins on any node)
```

## Fix

### 1. Add `analysis-icu` to the Dockerfile

`koha-docker/OpenSearch-3.6/assets/opensearch/Dockerfile`:

```dockerfile
ARG OPEN_SEARCH_VERSION
FROM opensearchproject/opensearch:${OPEN_SEARCH_VERSION}
USER root
RUN dnf -y install iputils net-tools curl procps --skip-broken

# Install analysis-icu plugin (required by Koha for icu_folding, icu_tokenizer, icu_normalizer)
USER opensearch
RUN /usr/share/opensearch/bin/opensearch-plugin install --batch analysis-icu
USER root
```

The plugin is installed as the `opensearch` user (not `root`) because the plugin installer writes into `/usr/share/opensearch/plugins/`, which is owned by the `opensearch` user in the base image. Running it as `root` produces a permission warning and can leave the plugin directory with incorrect ownership.

### 2. Switch `os02`–`os05` from `image:` to `build:`

`koha-docker/OpenSearch-3.6/docker-compose.yml` — for each of `os02`, `os03`, `os04`, `os05`, replaced:

```yaml
image: opensearchproject/opensearch:${OPEN_SEARCH_VERSION}
```

with:

```yaml
build:
  context: .
  dockerfile: assets/opensearch/Dockerfile
  args:
    - OPEN_SEARCH_VERSION=${OPEN_SEARCH_VERSION}
```

This ensures all five nodes are built from the same image with `analysis-icu` installed.

### 3. Rebuild and restart the cluster

```bash
cd koha-docker/OpenSearch-3.6
docker compose build          # rebuilds all 5 images with the plugin
docker compose down           # removes running containers
docker compose up -d          # starts fresh with new images
```

Post-restart verification:

```bash
curl -sk -u 'admin:test@Cici24#ANA' https://localhost:9200/_cat/plugins?v | grep icu
# os01  analysis-icu  3.6.0
# os02  analysis-icu  3.6.0
# os03  analysis-icu  3.6.0
# os04  analysis-icu  3.6.0
# os05  analysis-icu  3.6.0
```

## Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/assets/opensearch/Dockerfile` | Added `USER opensearch` + `RUN opensearch-plugin install --batch analysis-icu` + `USER root` |
| `OpenSearch-3.6/docker-compose.yml` | Changed `os02`–`os05` from `image: opensearchproject/opensearch:...` to `build:` using the same Dockerfile |