---
title: Fix: comment lines in defaults.env broke VARS_TO_SUB pipeline, causing Apache startup failure
date: 2026.06.04
tags:
 - comments
 - Apache
 - failure
---
# 2026-06-04 — Fix: comment lines in defaults.env broke VARS_TO_SUB pipeline, causing Apache startup failure

## Problem

`run.sh` builds the `VARS_TO_SUB` string by reading variable names from `defaults.env` and formatting them for `envsubst`. The original pipeline was:

```bash
VARS_TO_SUB=`cut -d '=' -f1 defaults.env | tr '\n' ':' | sed -e 's/:/:$/g' | awk '{print "$"$1}' | sed -e 's/:\$$//'`
```

`awk '{print "$"$1}'` splits on whitespace and prints the first field. When the variable list was a single colon-separated string on one line this worked — `$1` was the entire string. However, once `defaults.env` contained a comment line such as:

```bash
# SECURITY: change this from the default before running in any non-throwaway environment.
```

the `cut -d '=' -f1` step emitted the full comment line (no `=` in it), and `awk '{print "$"$1}'` then split on the space after `#` and printed only `$#`. Everything after the comment line was processed as a second `awk` record and also truncated.

The result: `VARS_TO_SUB` contained only the three variable names that appeared before the first comment (`$DOCKER_BINARY:$DB_HOSTNAME:$DB_IMAGE:$#`). `KOHA_INSTANCE` and all subsequent variables were silently dropped. `envsubst` left `${KOHA_INSTANCE}` unexpanded in `/etc/apache2/envvars`, so Apache received:

```log
APACHE_RUN_USER=-koha
APACHE_RUN_GROUP=-koha
```

and refused to start:

```log
AH00543: apache2: bad user name -koha
koha-1 exited with code 1
```

## Root cause chain

1. Comment lines added to `defaults.env` (the `# SECURITY:` block for `KOHA_DB_ROOT_PASSWORD`) in the previous fix session.
2. `defaults.env` is a machine-read file copied into the image at build time; it was never designed to carry human-readable comments.
3. The `VARS_TO_SUB` pipeline had no guard against non-assignment lines.

## Fix

### 1. `files/run.sh` — harden the VARS_TO_SUB pipeline

Replaced the `cut | awk` pipeline with a `grep`-filtered version that skips blank and comment lines before any further processing:

```bash
# Before
VARS_TO_SUB=`cut -d '=' -f1 ${BUILD_DIR}/templates/defaults.env | tr '\n' ':' | sed -e 's/:/:$/g' | awk '{print "$"$1}' | sed -e 's/:\$$//'`

# After
VARS_TO_SUB=$(grep -v '^[[:space:]]*#' "${BUILD_DIR}/templates/defaults.env" | grep '=' | cut -d '=' -f1 | tr '\n' ':' | sed -e 's/:/:$/g' | sed -e 's/:\$$//' | sed -e 's/^/\$/') 
```

The two leading `grep` filters guarantee that only lines containing `=` and not starting with `#` reach the rest of the pipeline. `awk` is no longer used.

### 2. `env/defaults.env` — remove comments

Removed the three `# SECURITY:` comment lines from `defaults.env`. That file is a machine-read env file baked into the Docker image; documentation belongs in `env/template.env` (which the operator copies to `env/.env`) and in `README.md`. Both of those already carry the security guidance.

## Files changed

| File | Change |
|---|---|
| `files/run.sh` | `VARS_TO_SUB` pipeline: replaced `cut \| awk` with `grep -v '#' \| grep '=' \| cut` |
| `env/defaults.env` | Removed `# SECURITY:` comment block above `KOHA_DB_ROOT_PASSWORD` |

## How to apply

The image must be rebuilt for the `run.sh` change to take effect:

```bash
./stack.sh start --build-koha --no-fresh-db
```