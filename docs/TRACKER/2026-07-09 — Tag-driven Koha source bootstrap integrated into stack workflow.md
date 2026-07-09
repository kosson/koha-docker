---
title: Tag-driven Koha source bootstrap integrated into stack workflow
date: 2026.07.09
tags:
 - Koha
 - stack.sh
 - git
 - release-testing
 - docs
---
# 2026-07-09 - Tag-driven Koha source bootstrap integrated into stack workflow

## Context

Starting from a fresh test environment required manually cloning Koha with a shallow `main` checkout. This made test runs less reproducible when validating against specific Koha releases.

## What changed

### 1) Clone logic consolidated into stack.sh

The standalone helper behavior is now fully integrated into `stack.sh` via `ensure_koha_source()`.

Capabilities retained in stack workflow:

1. Clones an exact Koha tag (shallow) in tag mode.
2. Validates tag existence before clone (`git ls-remote --tags --refs`).
3. Fails early if the target path already exists and is not a git repository.

### 2) `stack.sh` now auto-bootstraps Koha source

Updated file: `stack.sh`

New behavior:

1. Added `ensure_koha_source()`.
2. If `SYNC_REPO` does not exist, `stack.sh` clones Koha automatically.
3. Supports two modes:
   - `KOHA_GIT_CLONE_MODE=tag` for deterministic release testing.
   - `KOHA_GIT_CLONE_MODE=branch` for bleeding-edge shallow clone (e.g., `main`).
4. Added validation for clone depth (`KOHA_GIT_DEPTH` must be a positive integer).
5. Added tag existence validation in tag mode.
6. Added `git` to prerequisites (`check_prereqs()`).

Where `ensure_koha_source()` is invoked:

1. `start`
2. `restart`
3. `build` (only when Koha image build is requested)
4. `restore` (after restored env files are loaded)

### 3) New env variables for source strategy

Updated files:

1. `env/.env`
2. `env/template.env`
3. `env/defaults.env`

Added variables:

1. `KOHA_GIT_CLONE_MODE` (`tag` or `branch`)
2. `KOHA_GIT_TAG`
3. `KOHA_GIT_BRANCH`
4. `KOHA_GIT_DEPTH`
5. `KOHA_GIT_URL`

Also aligned `SYNC_REPO` path in `env/.env` to this workspace location.

### 4) Documentation updates

Updated files:

1. `README.md`
2. `docs/architecture/04 - Stack.sh Orchestrator.md`
3. `docs/architecture/06 - Environment Variables.md`
4. `docs/architecture/11 - Operations & Maintenance.md`
5. `.gitignore` comments

Docs now describe:

1. Deterministic tag testing workflow.
2. Bleeding-edge branch workflow.
3. Auto-clone behavior inside `stack.sh`.
4. Required env keys and examples.

## Implications

### Positive

1. Reproducible test baselines by pinning source to explicit tags.
2. Faster onboarding on clean hosts (no manual Koha clone step if `SYNC_REPO` is missing).
3. Maintains flexibility for shallow branch-based testing of upstream `main`.
4. Better operational consistency: clone strategy is now part of environment config and startup orchestration.

### Operational considerations

1. Existing repositories under `SYNC_REPO` are not overwritten; clone occurs only when absent.
2. Re-cloning with a different tag requires removing or relocating `SYNC_REPO` first.
3. `KOHA_GIT_TAG` must exist upstream in tag mode, or startup fails early by design.
4. Builds that only target OpenSearch do not force Koha source bootstrap.

## Validation performed

1. `bash -n stack.sh` completed successfully.
2. Verified variable/function wiring across script, env files, README, and architecture docs.
3. Verified stack script syntax and clone integration points.

## Scope note (projects)

Changes above were applied in `koha-docker`.
Equivalent propagation to sibling variants (`github/koha-docker`, `koha-docker-windows`) is pending as a follow-up task.

## Recommended defaults

For release-oriented testing:

```bash
KOHA_GIT_CLONE_MODE=tag
KOHA_GIT_TAG=25.11.05-1
KOHA_GIT_DEPTH=1
```

For bleeding-edge testing:

```bash
KOHA_GIT_CLONE_MODE=branch
KOHA_GIT_BRANCH=main
KOHA_GIT_DEPTH=1
```
