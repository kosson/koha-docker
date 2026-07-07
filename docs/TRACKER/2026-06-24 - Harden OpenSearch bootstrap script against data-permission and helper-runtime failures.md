---
title: Harden OpenSearch bootstrap script against data-permission and helper-runtime failures
date: 2026.06.24
tags:
 - OpenSearch
 - bootstrap
 - runtime
---
# 2026-06-24 - Harden OpenSearch bootstrap script against data-permission and helper-runtime failures

## Problem

`OpenSearch-3.6/raise-from-ground-up.sh` timed out waiting for `os01` health even though the real failure happened much earlier in node startup:

```log
AccessDeniedException: /usr/share/opensearch/data/nodes
```

After adding a data-permission repair step, a second error appeared during that repair phase:

```log
bash: line 1: find: command not found
```

## Root cause

1. OpenSearch data is bind-mounted from host directories (`assets/opensearch/data/os01data` ... `os05data`) into `/usr/share/opensearch/data`.
2. The OpenSearch process runs as uid/gid `1000:1000`, so host-side ownership/mode drift causes immediate startup failure before auth checks.
3. The initial repair implementation in the script relied on `find` inside a helper container command; on the runtime image used during that step, `find` was not available on `PATH`.
4. Because the node crashed before API/auth probes, the script surfaced a misleading timeout symptom instead of the true filesystem error.

## Changes made

File updated: `OpenSearch-3.6/raise-from-ground-up.sh`

1. Added explicit data-d---irectory definitions and creation routine:
  - `DATA_ROOT_DIR` and `NODE_DATA_DIRS` for all node bind mounts.
  - `prepare_node_data_dirs()` to ensure directories exist before startup.

2. Added pre-start permission repair phase:
  - `fix_node_data_permissions()` now runs right after image build and before `docker compose up`.
  - It runs a root process in the built OpenSearch image and applies:
    - `chown -R 1000:1000 /data`
    - `chmod -R u+rwX,g+rwX,o-rwx /data`

3. Removed dependency on `find` in Step 3b:
  - Replaced `find ... -exec chmod ...` with a `find`-free recursive `chmod` expression.
  - This makes the script robust even when `findutils` is absent in the helper execution environment.

4. Added fail-fast detection for the known permission crash:
  - In `wait_for_os01_healthy()`, script now scans recent `os01` logs for `AccessDeniedException: /usr/share/opensearch/data/nodes`.
  - If found, it exits immediately with a targeted error message instead of waiting for full timeout.

## Why these changes were needed

1. To make cluster bootstrap deterministic on hosts where bind-mounted directory ownership is inconsistent after resets/rebuilds.
2. To ensure the script fixes the real prerequisite (filesystem writeability) before any health/auth validation logic runs.
3. To avoid false diagnostics (health timeout and later auth suspicion) when the actual blocker is storage permissions.
4. To remove brittle assumptions about helper-tool availability (`find`) inside container-side repair commands.

## Effect

1. `raise-from-ground-up.sh` now proactively normalizes node data ownership and permissions before starting containers.
2. Startup failures caused by data-path access problems are reported immediately and explicitly.
3. Step 3b no longer fails due to missing `find` in the helper container command.