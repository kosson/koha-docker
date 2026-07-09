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
KOHA_GIT_TAG=v25.11.05-1
KOHA_GIT_DEPTH=1
```

For bleeding-edge testing:

```bash
KOHA_GIT_CLONE_MODE=branch
KOHA_GIT_BRANCH=main
KOHA_GIT_DEPTH=1
```

## Addendum - Same-day follow-up fixes

After initial integration, several runtime issues surfaced during real startup runs. The following fixes were applied and validated.

### A) Removed helper script to avoid script proliferation

Context:

1. `clone-koha.sh` had already been functionally superseded by `stack.sh`.
2. Keeping both paths created unnecessary maintenance overhead and duplicated operational guidance.

Changes:

1. Deleted `clone-koha.sh`.
2. Removed all references to it from `README.md` and `.gitignore` comments.
3. Kept `stack.sh` as the single source of truth for source bootstrap logic.

Effect:

1. One canonical startup path (`./stack.sh ...`).
2. Lower documentation drift risk between helper scripts and orchestrator behavior.

### B) Docker daemon preflight check in stack.sh

Problem observed:

Startup attempts could fail later with less clear Docker errors if the daemon was down.

Change:

1. Added explicit daemon check in `check_prereqs()`:
   - `docker info >/dev/null 2>&1 || die "Docker daemon is not running..."`

Effect:

1. Early and explicit failure mode.
2. Faster troubleshooting (`sudo systemctl start docker` guidance shown immediately).

### C) Tag lookup fix for Koha releases (`v` prefix compatibility)

Problem observed:

`KOHA_GIT_TAG=25.11.05-1` failed with:

1. `Koha tag '25.11.05-1' not found ...`

Root cause:

1. Upstream Koha release tags are commonly `v`-prefixed (for example `v25.11.05-1`).
2. Initial lookup expected only exact raw tag value.

Changes:

1. Enhanced `ensure_koha_source()` to auto-resolve both forms:
   - try `KOHA_GIT_TAG` as provided,
   - if missing and not prefixed, retry with `v${KOHA_GIT_TAG}`,
   - clone using the resolved tag.
2. Updated defaults/examples to canonical upstream format:
   - `env/.env`
   - `env/template.env`
   - `env/defaults.env`
   - `README.md`

Effect:

1. Backward-compatible behavior for users who enter tags with or without `v`.
2. Safer defaults aligned with current upstream naming.

### D) Compose network label mismatch fix (`opensearch-36_osearch`)

Problem observed at startup:

1. Existing network found but not created by current compose project.
2. Label mismatch error for `com.docker.compose.network` on `opensearch-36_osearch`.

Root cause:

1. `stack.sh` pre-creates shared Docker networks (`docker network create ...`).
2. OpenSearch compose still treated `osearch` as compose-managed, so Compose expected ownership labels.

Changes:

1. In `OpenSearch-3.6/docker-compose.yml`, converted shared networks to external:
   - `osearch` -> `name: opensearch-36_osearch`, `external: true`
   - `knonikl` -> `name: knonikl`, `external: true`
   - `frontend` remained `external: true`

Effect:

1. Compose now reuses existing shared networks instead of trying to claim ownership.
2. Eliminates recurring label mismatch failures for these stack-managed networks.

## Additional validation performed

1. `bash -n stack.sh` after each stack script change.
2. Remote tag probe verified `refs/tags/v25.11.05-1` exists upstream.
3. `docker compose -f OpenSearch-3.6/docker-compose.yml --env-file OpenSearch-3.6/.env config` confirmed network model resolves as external for `frontend`, `knonikl`, and `opensearch-36_osearch`.

## Final operational note for this day

The startup pipeline is now hardened across four layers:

1. daemon availability check,
2. resilient Koha tag resolution,
3. single orchestrator entrypoint,
4. deterministic shared-network ownership model.

This closes the main blockers encountered during fresh-source bootstrap and first-run stack startup on this date.
