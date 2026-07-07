---
title: OpenSearch zero-state rebuild tooling and healthcheck hardening
date: 2026.06.24
tags:
 - OpenSearch
 - healthcheck
 - tooling
---
# 2026-06-24 - OpenSearch zero-state rebuild tooling and healthcheck hardening

## Scope

After fixing credential drift, additional work was done to make OpenSearch recovery deterministic and safer for repeated clean starts:

1. Reworked the reset script to avoid host-wide Docker destruction.
2. Added an end-to-end bootstrap script for raising the cluster from zero.
3. Hardened `os01` healthchecks to remove dependency on password-based Basic Auth.
4. Updated README runbooks to match the new runtime behavior.

## Problem A: reset script was globally destructive

The original `OpenSearch-3.6/restart-to-clear-cluster.sh` used commands equivalent to:

- stop all containers on the host
- remove all containers on the host
- remove dangling volumes globally

This was unsafe for multi-project machines and could interrupt unrelated workloads.

## Root cause

The script was written with global Docker operations instead of being scoped to the `OpenSearch-3.6` compose project.

## Fix applied

`OpenSearch-3.6/restart-to-clear-cluster.sh` was rewritten to:

1. `docker compose down --remove-orphans` (project-scoped teardown)
2. remove only OpenSearch bind data: `assets/opensearch/data/os0{1..5}data/*`
3. remove only generated credentials: `assets/ssl/*`
4. remove only local OpenSearch image tag: `kosson/opensearch-icu:${OPEN_SEARCH_VERSION}`

It now also prints explicit next steps for rebuilding and restarting.

## Effect

- Clean reset now affects only `OpenSearch-3.6` resources.
- No unrelated containers/volumes are touched.
- Rebuild-from-scratch flow is repeatable.

## Problem B: no single command to raise cluster from zero with validation

Recovery required many manual commands and could still leave hidden drift if one step was skipped.

## Fix applied

New script created: `OpenSearch-3.6/raise-from-ground-up.sh`

This script implements the full flow:

1. run `restart-to-clear-cluster.sh`
2. regenerate certs/hashes via `opensearch_local_certificates_creator.sh`
3. rebuild image via `docker compose build os01`
4. start nodes `os01..os05`
5. wait for `os01` health
6. verify auth with `.env` password
7. auto-heal with `initial_api_calls.sh` + `--force-recreate os01` if auth is not HTTP 200
8. start `dashboards`
9. run final checks:
  - compose status snapshot
  - cluster node count = 5
  - cluster status in {green, yellow}
  - regression test `tests/test_opensearch_os01_auth_integration.sh`

## Effect

- One command performs full zero-state rebuild and validation.
- Auth drift is auto-corrected in-script when detected.
- Operator error from manual step ordering is reduced.

## Problem C: recurring BackendRegistry warning for admin auth during bootstrap

Observed warning pattern in `os01` logs:

```txt
[WARN ][o.o.s.a.BackendRegistry] Authentication finally failed for admin from 172.28.0.x:port
```

## Investigation summary

- Full ground-up rebuild succeeded with healthy cluster and passing auth integration test.
- Runtime check confirmed `.env` admin password authenticated successfully (HTTP 200).
- Warning was not persistent in healthy steady-state; behavior aligned with startup/probe timing and password-dependent checks.

## Root cause

`os01` healthcheck was based on Basic Auth with `admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}`. This created unnecessary coupling between container health and password synchronization timing.

## Fix applied

File updated: `OpenSearch-3.6/docker-compose.yml`

`os01` healthcheck changed from password-based probe to certificate-based mTLS probe:

- old: `curl ... -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" https://os01:9200/_cat/nodes`
- new: `curl ... --cert admin.pem --key admin-key.pem https://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=2s`

## Effect

- `os01` health no longer depends directly on Basic Auth password consistency.
- Startup warning noise tied to password auth probes is reduced.
- Healthcheck now validates local TLS/admin-cert path and cluster readiness.

## Documentation alignment

File updated: `README.md`

Sections revised:

1. OpenSearch manual Step 1 and Step 2 sequence (cleanup/build/start/verify).
2. Explicit guidance on when `initial_api_calls.sh` should be run.
3. Credential drift notes updated to clarify:
  - password drift still breaks Basic Auth flows
  - `os01` healthcheck is now certificate-based mTLS
4. Wording adjusted to avoid implying that `os01` healthcheck performs password auth.

## Effect

- Runtime behavior and docs are now consistent.
- Operators get a clearer decision tree for recovery actions.

## Files changed in this phase

1. `OpenSearch-3.6/restart-to-clear-cluster.sh` (rewritten)
2. `OpenSearch-3.6/raise-from-ground-up.sh` (new)
3. `OpenSearch-3.6/docker-compose.yml` (os01 healthcheck hardening)
4. `README.md` (OpenSearch startup/recovery documentation)

## Validation performed

1. `bash -n OpenSearch-3.6/restart-to-clear-cluster.sh`
2. `bash -n OpenSearch-3.6/raise-from-ground-up.sh`
3. `./OpenSearch-3.6/raise-from-ground-up.sh` end-to-end run
4. `tests/test_opensearch_os01_auth_integration.sh` pass
5. runtime checks:
  - `curl -ks -u admin:<env-pass> https://localhost:9200/_cat/nodes?pretty`
  - `docker compose ps os01 dashboards`
  - `docker inspect os01 ...` health history