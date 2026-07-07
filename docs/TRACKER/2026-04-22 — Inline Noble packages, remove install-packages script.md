---
title: Inline Noble packages, remove install-packages script
date: 2026.04.22
tags:
 - packages
 - script
 - Dockerfile
---
# 2026-04-22 — Inline Noble packages, remove install-packages script

## Goal

Simplify `koha-docker` for a single target platform (Ubuntu 24.04 Noble) by eliminating the dynamic `install-packages` Perl script and its YAML configuration in favour of plain `apt-get install` statements directly in the Dockerfile.

## Context

The original Dockerfile was assembled from two sources:

1. A first `FROM ubuntu:24.04` block (maintainer: kosson) that called `install-packages all`
   — a Perl script that read `package-config.yaml`, resolv### Changes made to `Dockerfile`

log` showed repeated `Cannot connect to broker (Error connecting to localhost:61613: Connection refused)` on every container start.

## Fix

**File changed:** `files/run.sh`

Moved `service rabbitmq-server start` to run **before** `service koha-common start`, and added a 30-second wait loop for the STOMP port (61613) to become available before starting workers. If RabbitMQ does not come up within 30 seconds, workers still start but fall back to DB polling with a clear warning in the log.

```log
Before:
  service koha-common start   ← workers start, STOMP fails, fallback to DB poll
  service apache2 start
  service rabbitmq-server start ← too late

After:
  service rabbitmq-server start ← broker starts first
  wait for port 61613 (up to 30 s)
  service koha-common start     ← workers start and connect to STOMP successfully
  service apache2 start
```

## How to apply

This change is in `files/run.sh`, which is **baked into the image at build time**. You must rebuild and restart the stack:

```bash
./stack.sh start -b
```

2. A second `FROM ubuntu:24.04` block (copied from `koha-testing-docker` as reference, maintainer: tomascohen) that called `install-packages <group>` once per package group.

Because Docker only executes the **last** `FROM` stage, the first block was silently ignored. Both blocks still depended on the scripting layer. The `package-config.yaml` defines a `distro_specific.noble` section with Cypress overrides for Ubuntu 24.04:

```yaml
distro_specific:
  noble:
    cypress-overrides:
      libgtk2.0-0:  libgtk2.0-0t64
      libgtk-3-0:   libgtk-3-0t64
      libasound2:   libasound2t64
      libgconf-2-4: null          # remove — not available on Noble
```

Since the target is fixed to Noble, these overrides are known at authoring time and do not require a runtime resolver.


## Changes made to `Dockerfile`

### 1. Merged into a single `FROM` stage

The two `FROM ubuntu:24.04` blocks were collapsed into one clean stage with the project maintainer label (`kosson@gmail.com`).

### 2. Removed the scripting layer

The following lines were deleted:

```yaml
COPY files/install-packages /usr/local/bin/
COPY files/package-config.yaml /usr/local/bin/
RUN  chmod +x /usr/local/bin/install-packages

RUN apt-get update \
    && apt-get -y install \
        lsb-release \
        libmodern-perl-perl \
        libyaml-libyaml-perl \
    ...
```

`lsb-release`, `libmodern-perl-perl`, and `libyaml-libyaml-perl` were only needed as runtime dependencies of the Perl script. With the script gone they are not installed.

### 3. Replaced `install-packages` calls with direct `apt-get install`

| Removed call | Replacement |
|---|---|
| `install-packages all` | Inlined `apt-get install` for every group |
| `install-packages base` | Inlined `apt-get install` for base packages |
| `install-packages koha-dev` | Inlined `apt-get install` for koha-dev packages |
| `install-packages nodejs` | `apt-get install nodejs yarn` (after repo setup) |
| `install-packages utility` | `apt-get install bugz inotify-tools` |
| `install-packages cypress` | Inlined `apt-get install` with Noble-specific names (see below) |
| `install-packages temp` | Removed — `temp: []` in the YAML (no-op) |
| `install-packages cpan` | Removed — no `cpan` key in the YAML (no-op) |

### 4. Applied Noble distro overrides directly in the Cypress install step

| Original package | Noble replacement | Reason |
|---|---|---|
| `libgtk2.0-0` | `libgtk2.0-0t64` | Renamed in Ubuntu 24.04 |
| `libgtk-3-0` | `libgtk-3-0t64` | Renamed in Ubuntu 24.04 |
| `libasound2` | `libasound2t64` | Renamed in Ubuntu 24.04 |
| `libgconf-2-4` | *(not installed)* | Not available on Noble (`null` override) |

### 5. Fixed yarn repository setup

The original had two conflicting `echo` statements writing to `yarn.list` — an unsigned entry first, then the signed one overwriting it. Reduced to a single signed `echo`.

### 6. Removed `COPY` for files not yet present in `koha-docker/`

The reference block copied files that exist in `koha-testing-docker` but not here:

```yaml
COPY files/run.sh          /kohadevbox          # does not exist yet
COPY files/templates       /kohadevbox/templates # does not exist yet
COPY env/defaults.env      /kohadevbox/templates/defaults.env  # does not exist yet
COPY files/git_hooks       /kohadevbox/git_hooks # does not exist yet
```

These were removed. A placeholder `CMD ["/bin/bash"]` was added so the image is runnable; it should be replaced with a proper entrypoint once those files are created.

### 7. Removed redundant `apt-cache policy` debug lines

The `koha-common` install step contained several `apt-cache policy` calls leftover from the reference Dockerfile. They produce output but have no side effect; removed for clarity.

## Files changed

| File | Change |
|---|---|
| `Dockerfile` | Rewritten — see above |

## Files unchanged (still present, no longer used at build time)

| File | Status |
|---|---|
| `files/install-packages` | Kept — can be removed when no longer needed for reference |
| `files/package-config.yaml` | Kept — documents the package intent; useful reference |
