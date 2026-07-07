---
title: Single shared OpenSearch image for all cluster nodes
date: 2026.05.20
tags:
 - OpenSearch
 - image
 - cluster
---
# 2026-05-20 — Single shared OpenSearch image for all cluster nodes

## Goal

Replace the five identical `build:` blocks in `OpenSearch-3.6/docker-compose.yml` (one per node) with a single named image so that Docker maintains only one image entry instead of five.

## Problem

All five node services (`os01`–`os05`) had the same `build:` stanza pointing to the same `Dockerfile` with the same `OPEN_SEARCH_VERSION` build arg. Docker Compose names service images after the project + service name (e.g., `opensearch-36-os01`, `opensearch-36-os02`, …), so `docker images` showed five separate entries even though the layers were byte-for-byte identical. This wasted namespace, made cleanup harder, and caused `docker compose build` to run five separate build invocations (with cache hits from the second onwards, but still redundant bookkeeping).

## Solution

Docker Compose supports specifying both `build:` and `image:` on the same service. When both are present, the built image is tagged with the `image:` name. Any other service that
lists the same `image:` value will use that already-built local image.

### `OpenSearch-3.6/docker-compose.yml`

- **`os01`** — kept the `build:` block; added `image: kosson/opensearch-icu:${OPEN_SEARCH_VERSION}` alongside it. After `docker compose build os01`, the image is tagged as `kosson/opensearch-icu:3.6.0` (or whichever version is in `.env`).
- **`os02`–`os05`** — removed `build:` blocks entirely; replaced with:

  ```yaml
  image: kosson/opensearch-icu:${OPEN_SEARCH_VERSION}
  pull_policy: never
  ```

  `pull_policy: never` prevents Docker Compose from attempting to pull the image from a
  registry — it is a locally-built-only image and has not been pushed to Docker Hub.

### `stack.sh`

- `build_opensearch()` now runs `docker compose build os01` instead of `docker compose build` (which would previously build all services that have a `build:` block).
- The `ok` confirmation message now reads the version from `OpenSearch-3.6/.env` via `_env_val` and prints `kosson/opensearch-icu:<version>`.
- Help text updated: `--build-opensearch` description now names the single image.

### `README.md`

- Step 1 heading updated to singular ("Build the OpenSearch image").
- Build command changed to `docker compose build os01`.
- Description updated to explain the single-image / shared-reference pattern.
- Build options table entry for `--build-opensearch` updated to name `kosson/opensearch-icu`.

## Result

| Before | After |
|--------|-------|
| 5 image entries in `docker images` | 1 image entry (`kosson/opensearch-icu:3.6.0`) |
| `docker compose build` invoked for all 5 services | `docker compose build os01` only |
| Changing the Dockerfile required rebuilding 5 × | Rebuild once, all nodes pick it up automatically |

## Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/docker-compose.yml` | Added `image:` tag to `os01`; removed `build:` blocks from `os02`–`os05`; added `pull_policy: never` to `os02`–`os05` |
| `stack.sh` | `build_opensearch()` builds `os01` only; version read via `_env_val`; help text updated |
| `README.md` | Step 1 updated to reflect single-image approach |
