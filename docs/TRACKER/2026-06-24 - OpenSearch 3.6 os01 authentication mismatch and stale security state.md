---
title: OpenSearch 3.6 os01 authentication mismatch and stale security state
date: 2026-06-24
tags:
 - OpenSearch
 - authentication
 - security
---
# 2026-06-24 - OpenSearch 3.6 os01 authentication mismatch and stale security state

## Problem

`docker compose up -d` in `OpenSearch-3.6` stalled on `os01` being unhealthy and blocked dependent services such as `dashboards`.

Observed behavior:

```log
dependency failed to start: container os01 is unhealthy
```

The healthcheck on `os01` was failing with HTTP 401 even though the node process itself was running.

## Root cause

Three settings were out of sync:

1. The compose healthcheck authenticated with `admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}` from `.env`, but the live security state in the persistent `assets/opensearch/data/os01data/` mount still had an older security index.
2. `initial_api_calls.sh` referenced `opensearch_dashboards_server`, but OpenSearch 3.6 exposed the Dashboards server role as `kibana_server` in the live security API.
3. `roles_mapping.yml` used the same wrong role name, so the bootstrap script and the repository config both pointed at a role that did not exist in the running cluster.

This caused two different failures at the same time:

- the `os01` container healthcheck never became green because Basic Auth for the configured admin password returned 401;
- the security bootstrap script reported `NOT_FOUND` for the Dashboards service-account mapping, which meant the security config was not being applied cleanly to the live cluster.

## Wrong settings found and their implications

- `OPENSEARCH_INITIAL_ADMIN_PASSWORD` in `.env` did not match the active security index state preserved in `os01data`, so changing the environment file alone was not enough to recover healthchecks.
- `opensearch_dashboards_server` was used where the live cluster expected `kibana_server`, so role mapping updates failed even though the cluster itself was healthy.
- The persisted `os01data` directory kept old cluster/security state across restarts, which meant stale credentials and role mappings could survive a `docker compose up -d` and keep reproducing the failure.

## Changes made

Files updated:

- `OpenSearch-3.6/initial_api_calls.sh`
  - Switched the Dashboards service-account mapping to `kibana_server`.
  - Updated the `dashboards` internal user mapping so the security bootstrap writes a role that the live 3.6 cluster actually exposes.
- `OpenSearch-3.6/assets/opensearch/config/os01/opensearch-security/roles_mapping.yml`
  - Renamed the Dashboards server role entry from `opensearch_dashboards_server` to `kibana_server`.
- `OpenSearch-3.6/assets/opensearch/config/os01/opensearch-security/internal_users.yml`
  - Updated the stored password hashes to match the current `OPENSEARCH_INITIAL_ADMIN_PASSWORD`.

## Effect

- `os01` now becomes healthy again under `docker compose up -d`.
- The auth regression test passes when validating `admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}` against the live cluster.
- `initial_api_calls.sh` no longer fails on the Dashboards role mapping and can be used to resync a running cluster after the security state drifts.
- The cluster now starts with consistent runtime credentials, repository config, and persisted security state.

## Validation run

```bash
cd OpenSearch-3.6
docker compose up -d
set -a && source .env && set +a && bash initial_api_calls.sh
bash ../tests/test_opensearch_os01_auth_integration.sh
docker compose ps os01 dashboards
```

Validation outcome:

- `initial_api_calls.sh` completed without `NOT_FOUND` errors.
- `tests/test_opensearch_os01_auth_integration.sh` passed.
- `os01` reported `healthy`.
