---
title: Rootless Docker rlimit memlock failure (OpenSearch)
date: 2026.06.08
tags:
 - docker
 - rlimit
 - memlock
 - OpenSearch
---
# 2026-06-08 - Rootless Docker rlimit memlock failure (OpenSearch)

## Problem

All five OpenSearch node containers failed to start with:

```log
failed to create shim task: OCI runtime create failed: runc create failed:
unable to start container process: error during container init:
error setting rlimits for ready process: error setting rlimit type 8: operation not permitted
```

`rlimit type 8` is `RLIMIT_MEMLOCK`. Rootless Docker (via RootlessKit) cannot raise the memlock limit to unlimited (`-1`) because it has no `CAP_SYS_RESOURCE` capability.

## Root cause

All five node services in `OpenSearch-3.6/docker-compose.yml` had:

```yaml
ulimits:
  memlock:
    soft: -1
    hard: -1
```