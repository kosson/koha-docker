---
title: Protect OpenSearch SSL bootstrap from directory-vs-file path corruption
date: 2026.06.24
tags:
 - OpenSearch
 - SSL
 - path
---
# 2026-06-24 - Protect OpenSearch SSL bootstrap from directory-vs-file path corruption

## Problem

`./stack.sh start` failed during OpenSearch startup with:

```log
OpenSearchException: /usr/share/opensearch/config/root-ca.pem - is a directory
```

This happened inside `org.opensearch.security.OpenSearchSecurityPlugin` while loading SSL configuration, before the cluster could become healthy.

## Root cause

1. OpenSearch mounts `./OpenSearch-3.6/assets/ssl/root-ca.pem` and other certificate files directly into `/usr/share/opensearch/config/`.
2. If one of those host paths is missing when Docker Compose starts, Docker can create a directory at that path instead of a file.
3. Once the path has become a directory, the Security plugin aborts at startup because it expects a regular PEM file.
4. `stack.sh start` previously assumed the cert files were already present and did not verify or regenerate them before starting the cluster.

## Changes made

File updated: `stack.sh`

1. Added `ensure_opensearch_certs()`.
2. The new helper:
  - checks for the OpenSearch cert generator config file (`opensearch_installer_vars.cfg`),
  - creates `assets/ssl` if needed,
  - removes any directory accidentally created at a certificate path,
  - regenerates the cert set when any required PEM file is missing or invalid,
  - verifies that all expected cert files exist as regular files before startup.
3. `start` now calls `ensure_opensearch_certs()` before `start_traefik` and `start_opensearch`.

## Why these changes were needed

1. To stop Docker from bind-mounting directories where certificate files are expected.
2. To fail early with a clear message if the OpenSearch cert bootstrap inputs are missing.
3. To make `./stack.sh start` self-healing after a bad partial start or a host-side cleanup that leaves `assets/ssl` incomplete.

## Effect

1. OpenSearch startup no longer depends on the operator manually preparing PEM files first.
2. The script now repairs invalid certificate paths before Compose starts the cluster.
3. The Security plugin can load `/usr/share/opensearch/config/root-ca.pem` as a file, so plugin initialization proceeds normally.