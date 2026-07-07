---
title: Self-heal OpenSearch auth drift before Koha startup
date: 2026.06.24
tags:
 - OpenSearch
 - selfheal
 - auth
 - drift
 - startup
---
# 2026-06-24 - Self-heal OpenSearch auth drift before Koha startup

## Problem

`./stack.sh start` could reach a state where OpenSearch was green but the Koha container looped on:

```log
[elasticsearch] attempt 2/60: OpenSearch not ready yet (HTTP 401)
```

The cluster was reachable, but Koha could not authenticate to OpenSearch with the password it received from `env/.env`.

## Root cause

1. The startup flow only waited for cluster health, not for credential alignment.
2. Koha reads `OPENSEARCH_INITIAL_ADMIN_PASSWORD` and `ELASTIC_OPTIONS` from its own env file, while the cluster uses the password from `OpenSearch-3.6/.env`.
3. If the Security index was stale or if the passwords drifted, Koha would start with credentials that the cluster rejected with HTTP 401.
4. The failure was recurring because the startup script did not self-heal the auth state before handing control to the Koha container.

## Changes made

File updated: `stack.sh`

1. Added `sync_koha_opensearch_credentials()`.
2. The new helper:
  - reads the active OpenSearch admin password from `OpenSearch-3.6/.env`,
  - rewrites the Koha-side `ELASTIC_OPTIONS` userinfo to match that password,
  - exports the synced password into the startup environment so Compose passes a single consistent value to Koha.
3. Added `ensure_opensearch_auth()`.
4. The new auth guard:
  - probes `https://localhost:9200/_cluster/health` with the active admin credentials,
  - if the cluster returns HTTP 401, it runs `OpenSearch-3.6/initial_api_calls.sh`,
  - recreates `os01` so the node reloads the updated security state,
  - verifies auth again before Koha starts.
5. `start` now runs the auth guard after cluster health is green and before support services / Koha startup.

## Why these changes were needed

1. To stop Koha from entering a repeated 401 retry loop when the cluster security index drifts.
2. To make the startup path resilient after password changes or partially-applied security updates.
3. To remove the need for a manual `initial_api_calls.sh` invocation during normal development use.

## Effect

1. The stack now repairs common OpenSearch auth drift automatically during startup.
2. Koha starts only after the OpenSearch password used by the container matches the active cluster password.
3. If the cluster still rejects the credentials, the security config is reapplied and the cluster node is recreated before Koha is launched.