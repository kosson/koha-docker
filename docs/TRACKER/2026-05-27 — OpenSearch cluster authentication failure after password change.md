---
title: OpenSearch cluster authentication failure after password change
date: 2026.05.27
tags:
 - OpenSearch
 - cluster
 - authentication
---
# 2026-05-27 — OpenSearch cluster authentication failure after password change

## Problem

After changing the admin password from `test@Cici24#ANA` to `testSimplu` in both `.env` files, the OpenSearch cluster failed to start cleanly. All authentication attempts returned HTTP 401 — including the `wait_opensearch_green` healthcheck in `stack.sh`, the Koha Elasticsearch connector, and the OpenSearch Dashboards backend. Every node eventually marked all others as dead and `stack.sh` would time out waiting for a green cluster.

## Root causes (three independent issues)

### Root cause 1 — Hash mismatch in `internal_users.yml`

`OpenSearch-3.6/assets/opensearch/config/os01/opensearch-security/internal_users.yml` stores bcrypt hashes for the built-in users (`admin`, `dashboards`, `kibanaserver`). The file still contained the bcrypt hash generated for the **old** password `test@Cici24#ANA` (entry C7 in `OpenSearch-3.6/FIXES.md`). The password values in `.env` were updated to `testSimplu`, but the `internal_users.yml` hashes were never regenerated.

With `DISABLE_INSTALL_DEMO_CONFIG=true`, the OpenSearch Docker entrypoint does **not** run `install_demo_configuration.sh` and does **not** auto-generate or validate password hashes. The hash in `internal_users.yml` is loaded as-is and must match the password used for authentication. Every request therefore received 401.

**Key insight**: `plugins.security.restapi.password_validation_regex` in `opensearch.yml` (the password complexity pattern `(?=.*[A-Z])(?=.*[^a-zA-Z\d])…`) applies **only to REST API password-change requests**, not to the initial hash loading from `internal_users.yml`. The Security plugin does not enforce complexity rules on hashes already present in the file.

### Root cause 2 — Stale cluster state from previous SSL certificate set

`OpenSearch-3.6/assets/opensearch/data/os0{2,3,4}data/` each contained ~11 MB of cluster state written under the previous SSL certificate identity (different node Subject/SAN values). After SSL certificates were regenerated, the new transport-layer node identities did not match the persisted state. The cluster elected os01 as cluster manager but the other nodes could not join — they were seen as different nodes.

`stack.sh reset` performs `docker compose down --volumes`, which removes **named Docker volumes** but does **not** wipe bind-mounted directories. The data directories are bind mounts, so stale data survives a `reset`.

### Root cause 3 — Literal double-quotes in `OPENSEARCH_INITIAL_ADMIN_PASSWORD`

Both `.env` files had:

```bash
OPENSEARCH_INITIAL_ADMIN_PASSWORD="testSimplu"
```

Docker Compose strips the double quotes during env-file parsing, so the effective value is `testSimplu` — functionally correct. However, the literal quotes were a latent confusion risk (especially in scripts that read the file with `grep`/`awk` without stripping quotes).

## Fix applied

### 1. Regenerate `internal_users.yml` hashes

Generated the correct bcrypt hash using OpenSearch's own `hash.sh` tool via a temporary container (avoids installing `htpasswd` or any external bcrypt tool, and ensures the hash format and cost factor exactly match what the Security plugin expects):

```bash
docker run --rm opensearchproject/opensearch:3.6.0 \
  bash -c '/usr/share/opensearch/plugins/opensearch-security/tools/hash.sh -p "testSimplu" 2>/dev/null'
# → $2y$12$.MrUYog2krxCrFiqWvTGy.eu.4VX8qb6UtiCfFxVwQtqzDSUOsmHa
```

Updated all three user entries (`admin`, `dashboards`, `kibanaserver`) in `internal_users.yml` with this hash.

### 2. Wipe stale data directories

```bash
cd koha-docker/OpenSearch-3.6
rm -rf assets/opensearch/data/os0{1,2,3,4,5}data/*
```

Forces a fresh cluster bootstrap under the new SSL certificate identities. All Koha Elasticsearch indexes are rebuilt by `rebuild_elasticsearch.pl` on next `stack.sh start`.
#### 3. Remove literal double-quotes from both `.env` files

```bash
# Before
OPENSEARCH_INITIAL_ADMIN_PASSWORD="testSimplu"

# After
OPENSEARCH_INITIAL_ADMIN_PASSWORD=testSimplu
```

Applied to both `OpenSearch-3.6/.env` and `koha-docker/env/.env`.

## Verification

After the three fixes, the cluster reached green status with 5/5 nodes and 0 unassigned shards:

```bash
curl -sk -u 'admin:testSimplu' https://localhost:9200/_cluster/health | python3 -m json.tool
# "status": "green", "number_of_nodes": 5, "unassigned_shards": 0
```

Authentication confirmed:

```bash
curl -sk -u 'admin:testSimplu' https://localhost:9200/ | grep number
# "number" : "3.6.0"
```

## Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/assets/opensearch/config/os01/opensearch-security/internal_users.yml` | All three user hashes (`admin`, `dashboards`, `kibanaserver`) updated to bcrypt hash for `testSimplu` |
| `OpenSearch-3.6/.env` | Removed literal double-quotes from `OPENSEARCH_INITIAL_ADMIN_PASSWORD` |
| `env/.env` | Removed literal double-quotes from `OPENSEARCH_INITIAL_ADMIN_PASSWORD`; `ELASTIC_OPTIONS` `<userinfo>` updated to `admin:testSimplu` |
| `OpenSearch-3.6/FIXES.md` | Entry C9 added documenting the hash mismatch, stale data, and quoted password issues |