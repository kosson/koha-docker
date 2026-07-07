---
title: Runtime error analysis and UID 1000 fix
date: 2026.05.02
tags:
 - UID
 - worker
 - user
 - runtime
---
# 2026-05-02 — Runtime error analysis and UID 1000 fix

## Errors observed in `docker compose up` logs

```log
koha-1  | Error: worker not running for kohadev (default)
koha-1  | Error: worker not running for kohadev (long_tasks)
koha-1  |    ...fail!
koha-1  |  * Restarting Apache httpd web server apache2
koha-1  |    ...done.
koha-1  | fatal: could not create work tree dir '/kohadevbox/koha/misc/translator/po': Permission denied
koha-1  | error: could not lock config file .git/config: Permission denied
koha-1  | error: could not lock config file .git/config: Permission denied
koha-1  | mkdir: cannot create directory '/kohadevbox/koha/.git/hooks/ktd': Permission denied
koha-1  | cp: target '/kohadevbox/koha/.git/hooks/ktd': No such file or directory
koha-1  | error: could not lock config file .git/config: Permission denied
koha-1 exited with code 255
```

## Analysis

### Error 1 — "worker not running for kohadev" (cosmetic, non-fatal)

**Source**: `koha-create --request-db kohadev` (called in `run.sh`) internally calls `service koha-common restart` after writing config files. At that point, no database exists yet, so the Koha background worker cannot start.
**Impact**: Informational only. `koha-create` exits with code 0; `run.sh` continues. The database is populated later by `do_all_you_can_do.pl`.
**Fix**: None required.

### Error 2 — All `Permission denied` errors on `/kohadevbox/koha/...` (fatal)

**Root cause**: `ubuntu:24.04` ships with a pre-created system user `ubuntu` at **UID 1000** (added to Ubuntu cloud/container images starting with Ubuntu 23.10). This is confirmed by:

```bash
$ docker run --rm ubuntu:24.04 id ubuntu
uid=1000(ubuntu) gid=1000(ubuntu) groups=1000(ubuntu),4(adm),...
```

When `koha-create` runs inside the container it calls `adduser` to create the instance user `kohadev-koha`. Because UID 1000 is already taken by `ubuntu`, `kohadev-koha` is
assigned **UID 1001**.

`run.sh` contains this guard:

```bash
if [[ ! -z "${LOCAL_USER_ID}" && "${LOCAL_USER_ID}" != "1000" ]]; then
    usermod -o -u ${LOCAL_USER_ID} "${KOHA_INSTANCE}-koha"
fi
```

Since `LOCAL_USER_ID=1000`, the condition `!= "1000"` is **false** and `usermod` is skipped. `kohadev-koha` remains at UID 1001.
The Koha source directory is mounted from the host:

```yaml
${SYNC_REPO}:/kohadevbox/koha
```

The host files are owned by UID 1000 (host user `nicolaie`). Inside the container, `kohadev-koha` (UID 1001) has no write access, causing every operation that `run.sh` performs as `kohadev-koha` (via `sudo koha-shell`) to fail with Permission denied. The `set -e` in `run.sh` then causes the container to exit with code 255 when the first `sudo koha-shell` command under this mode fails.

**Affected operations**:

| Operation | Command in `run.sh` |
|---|---|
| Clone koha-l10n into `misc/translator/po` | `sudo koha-shell ${KOHA_INSTANCE} -c "git clone ..."` |
| Write git config locals | `sudo koha-shell ... -c "git config bz.default-tracker ..."` |
| Create `.git/hooks/ktd` directory | `sudo koha-shell ... -c "mkdir -p .git/hooks/ktd"` |
| Copy git hooks | `sudo koha-shell ... -c "cp git_hooks/* .git/hooks/ktd"` |

## Fix applied

Added `RUN userdel -r ubuntu` to `Dockerfile` **before the mirror redirect layer**, so UID 1000 is free when `koha-create` creates `kohadev-koha` during container startup:

```yaml
# ubuntu:24.04 ships with a pre-created 'ubuntu' user at UID 1000.
# koha-create assigns the next available UID to kohadev-koha, which becomes 1001.
# run.sh only calls usermod when LOCAL_USER_ID != 1000, so the mismatch is never fixed
# and kohadev-koha cannot write to the host-mounted Koha repo (owned by UID 1000).
# Removing the ubuntu user here frees UID 1000 for kohadev-koha.
RUN userdel -r ubuntu 2>/dev/null || true
```

**After this fix**:

- `kohadev-koha` gets UID 1000 (first available UID for a non-system user)
- `LOCAL_USER_ID=1000` → `run.sh` condition `!= "1000"` is false → no usermod needed
- `kohadev-koha` at UID 1000 can read/write the host-mounted Koha repo
- All `sudo koha-shell` operations succeed
- Container no longer exits with code 255

## Files changed

| File | Change |
|---|---|
| `Dockerfile` | Added `RUN userdel -r ubuntu 2>/dev/null \|\| true` before mirror-redirect layer |