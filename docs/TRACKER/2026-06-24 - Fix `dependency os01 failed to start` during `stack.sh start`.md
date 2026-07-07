---
title: Fix `dependency os01 failed to start` during `stack.sh start`
date: 2026.06.24
tags:
 - OpenSearch
 - dependency
---
# 2026-06-24 - Fix `dependency os01 failed to start` during `stack.sh start`

## Problem

Running `./stack.sh start` could fail in the OpenSearch stage with:

```log
Error dependency os01 failed to start
dependency failed to start: container os01 is unhealthy
```

The failure happened while Compose was trying to start Dashboards, which depends on `os01` being healthy.

## Root cause

Two issues combined:

1. **Startup ordering race in** `stack.sh`:
  - `start_opensearch()` called `docker compose up -d` for all OpenSearch services at once, including Dashboards.
  - Dashboards has `depends_on: os01: condition: service_healthy`, so if `os01` was not yet healthy, Compose could abort with a dependency failure.

2. **Incorrect healthcheck target in** `OpenSearch-3.6/docker-compose.yml`:
  - The certificate-based `os01` healthcheck was pointing to `https://localhost:9200/...`.
  - Node config uses `network.host=os01`, so probing `localhost` could fail during runtime/startup and keep `os01` marked unhealthy.

## Changes made

### File: `stack.sh`

1. Updated `start_opensearch()` to start only core nodes first:

```bash
docker compose up -d os01 os02 os03 os04 os05
```

2. Added new function `start_opensearch_dashboards()`:

```bash
docker compose up -d dashboards
```

3. Updated `start` flow order:

- Start Traefik
- Start OpenSearch core nodes (`os01`-`os05`)
- Wait for green cluster (`wait_opensearch_green`)
- Start Dashboards
- Continue with DB/Memcached/Koha

This removes the dependency race by deferring Dashboards startup until after cluster readiness.

### File: `OpenSearch-3.6/docker-compose.yml`

Updated `os01` healthcheck endpoint from `localhost` to `os01`:

```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -ks --fail --cert /usr/share/opensearch/config/admin.pem --key /usr/share/opensearch/config/admin-key.pem 'https://os01:9200/_cluster/health?wait_for_status=yellow&timeout=2s'"]
```

This keeps the mTLS-based probe but targets the hostname bound by OpenSearch node settings.

## Effect

1. `stack.sh start` no longer fails at Dashboards dependency resolution due to premature startup.
2. `os01` health now reflects actual node readiness with a correct endpoint.
3. OpenSearch startup is deterministic:
  - core nodes first,
  - readiness check,
  - dashboards after health.

## Validation

Commands executed:

```bash
bash -n stack.sh
./stack.sh start --no-logs --no-fresh-db
```

Observed outcome:

1. OpenSearch nodes started.
2. Cluster reached green.
3. Dashboards started successfully after `os01` became healthy.
4. The previous `dependency os01 failed to start` error did not recur.