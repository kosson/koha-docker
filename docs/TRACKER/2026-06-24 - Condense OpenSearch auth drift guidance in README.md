---
title: Condense OpenSearch auth drift guidance in README
date: 2026.06.24
tags:
 - OpenSearch
 - auth
 - errors
 - drift
---
# 2026-06-24 - Condense OpenSearch auth drift guidance in README

## Problem

The README's OpenSearch credential drift note had become repetitive: it described the same 401 failure several times across separate paragraphs, which made the recovery path harder to scan during startup troubleshooting.

## Root cause

1. The documentation repeated the same facts in multiple forms: cluster health can be green while Basic Auth still fails, and the password must stay aligned between `env/.env` and `OpenSearch-3.6/.env`.
2. The section mixed symptoms, causes, and recovery steps without a single concise summary.
3. That made the most important operational detail harder to spot: `stack.sh start` now self-heals the drift before Koha starts.

## Changes made

File updated: `README.md`

1. Replaced the long drift explanation with a shorter warning block.
2. Kept the essential symptoms:

  - `tests/test_opensearch_os01_auth_integration.sh` fails,
  - `curl -u admin:<password>` returns 401,
  - Koha or Dashboards show auth errors even while `os01` is up.

3. Added a direct note that `./stack.sh start` now syncs Koha's `ELASTIC_OPTIONS` from `OpenSearch-3.6/.env`, probes the cluster, and reruns `initial_api_calls.sh` when the cluster still answers 401.

## Why these changes were needed

1. To make the recovery path faster to read when troubleshooting startup failures.
2. To keep the documentation aligned with the new self-healing startup behavior.
3. To avoid burying the actual operational rule under duplicated prose.

## Effect

1. The README now presents the drift problem in one compact block.
2. The self-healing startup behavior remains documented where users look for OpenSearch troubleshooting.
3. The older recovery commands are still available, but the primary path is clearer.