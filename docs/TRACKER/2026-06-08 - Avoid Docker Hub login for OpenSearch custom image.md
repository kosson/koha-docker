---
title: Avoid Docker Hub login for OpenSearch custom image
date: 2026.06.08
tags: 
 - login
 - docker
 - OpenSearch
---
# 2026-06-08 - Avoid Docker Hub login for OpenSearch custom image

## Problem

On a fresh machine, starting the stack could fail with:

```log
pull access denied for kosson/opensearch-icu, repository does not exist or may require 'docker login'
```

This happened when the custom OpenSearch image tag (`kosson/opensearch-icu:${OPEN_SEARCH_VERSION}`) was not available locally and Compose attempted an image pull path.

## Root cause

- OpenSearch services use a custom image tag shared by `os01`-`os05`.
- On first run, if that tag is missing locally, startup could try to resolve it via Docker Hub instead of ensuring a local build first.

## Changes made

Files updated:

- `OpenSearch-3.6/docker-compose.yml`
  - Added `pull_policy: never` to service `os01` (already present on `os02`-`os05`).
- `stack.sh`
  - In `start_opensearch()`, added a preflight image check.
  - If `kosson/opensearch-icu:${OPEN_SEARCH_VERSION}` is missing locally, `build_opensearch` is invoked automatically before `docker compose up -d`.

## Effect

- Users are no longer required to run `docker login` for this custom image.
- First startup auto-builds the image locally when needed, then starts the cluster.
- Subsequent starts reuse the local image and skip rebuild unless explicitly requested.