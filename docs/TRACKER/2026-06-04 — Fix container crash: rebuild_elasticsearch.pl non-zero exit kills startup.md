---
title: "Fix container crash: rebuild_elasticsearch.pl non-zero exit kills startup"
date: 2026-06-04
tags:
 - container
 - crash
 - elasticsearch
 - startup
---
# 2026-06-04 — Fix container crash: rebuild_elasticsearch.pl non-zero exit kills startup

## Problem

After the db-detect probe correctly identified the existing database and passed `--use-existing-db` to `do_all_you_can_do.pl`, the container still exited with code 1:

```log
koha-1  | Running [sudo koha-shell kohadev -p -c 'PERL5LIB=… perl …/rebuild_elasticsearch.pl' 2>/tmp/rebuild_elasticsearch.stderr]...
koha-1 exited with code 1
```

`do_all_you_can_do.pl` ends by calling `rebuild_elasticsearch.pl`. If the script exits non-zero (stale index, mapping mismatch, missing index after an image upgrade, etc.), it propagates the failure code. Because `run.sh` runs under `set -e`, any non-zero exit from `do_all_you_can_do.pl` immediately kills the container.

The error was completely invisible: stderr was redirected to `/tmp/rebuild_elasticsearch.stderr` inside the container with no mechanism to surface it in `docker compose logs`.

## Root cause in context

`rebuild_elasticsearch.pl` can legitimately fail after:
- Switching to a new Koha image version (index mappings change)
- The OpenSearch cluster restarting and index state being inconsistent
- A partial or interrupted previous indexing run

None of these are fatal — Koha continues to operate normally (it falls back to Zebra for searches), and the index can be rebuilt manually. Crashing the entire container on a transient ES error is disproportionate.

## Fix — `files/run.sh`

### 1. Made the ES rebuild non-fatal inside `do_all_you_can_do.pl`

The existing `sed` patch that mutes `rebuild_elasticsearch.pl` output was extended to append `; true` to the shell command string, so the overall exit code is always 0 regardless of whether indexing succeeds:

```bash
# Before:
sed -i "s|perl \$rebuild_es_path -v'|perl \$rebuild_es_path' 2>/tmp/rebuild_elasticsearch.stderr|" \
    "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"

# After:
sed -i "s|perl \$rebuild_es_path -v'|perl \$rebuild_es_path' 2>/tmp/rebuild_elasticsearch.stderr; true|" \
    "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"
```

The shell executes `perl …; true` — `true` always exits 0, so `do_all_you_can_do.pl` never sees a failure from this step.

### 2. Surface errors in container logs after `do_all_you_can_do.pl` finishes

After the `perl do_all_you_can_do.pl …` call, `run.sh` now checks whether `/tmp/rebuild_elasticsearch.stderr` is non-empty and prints its contents:

```bash
if [ -s /tmp/rebuild_elasticsearch.stderr ]; then
    echo "[elasticsearch] WARNING: Index rebuild encountered errors (startup continues):"
    cat /tmp/rebuild_elasticsearch.stderr
    echo "[elasticsearch] Koha is functional but searches may be incomplete."
    echo "[elasticsearch] To retry: koha-shell ${KOHA_INSTANCE} -p -c 'perl ${BUILD_DIR}/koha/misc/search_tools/rebuild_elasticsearch.pl'"
fi
```

This means:

- The container always starts successfully
- The operator can see the actual ES error in `docker compose logs koha`
- A ready-to-run retry command is printed alongside the error

## Behaviour summary

| Scenario | Before | After |
|---|---|---|
| `rebuild_elasticsearch.pl` exits 0 | Container starts | Container starts (unchanged) |
| `rebuild_elasticsearch.pl` exits non-zero | Container crashes (code 1), error invisible | Container starts; error printed to logs with retry hint |
| ES down or index missing | Container crashes | Container starts; Koha functional; warning in logs |

## Files changed

| File | Change |
|---|---|
| `files/run.sh` | `sed` patch for ES rebuild extended with `; true` (non-fatal exit); added post-`do_all_you_can_do.pl` block to surface errors from `/tmp/rebuild_elasticsearch.stderr` in container logs |

## How to apply

Same image rebuild as the db-detect probe improvement above — both changes are included in `RUN_SH_VERSION=2026-06-04`:

```bash
./stack.sh build --build-koha
docker tag kosson/koha-ubuntu:latest kosson/koha-ubuntu:26.05.01
docker push kosson/koha-ubuntu:26.05.01
```