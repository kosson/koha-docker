---
title: "opensearch_local_certificates_creator.sh: automatic internal_users.yml hash update"
date: 2026-05-27
tags:
 - opensearch
 - certificates
 - hashes
---
# 2026-05-27 — opensearch_local_certificates_creator.sh: automatic internal_users.yml hash update

## Goal

Eliminate the manual step of regenerating `internal_users.yml` hashes after a password change. Previously, running the certificate creator script regenerated SSL certificates but left the Security plugin user hashes unchanged — requiring a separate manual hash generation and file edit whenever the password was rotated.

## Problem

The certificate creator script (`OpenSearch-3.6/opensearch_local_certificates_creator.sh`) regenerates all SSL certificates (root CA, admin cert, per-node certs, dashboards cert) on each run. However, changing the admin password (in `.env`) did not automatically update the bcrypt hashes in `internal_users.yml`.

The disconnect meant that:

1. SSL certs and `.env` password could be updated together in one operation.
2. But `internal_users.yml` hashes remained stale — pointing to the old password.
3. The cluster would start, accept the new certs, but reject all authentication (401) because the stored hash did not match the new password.

This is exactly what caused the outage documented in the previous entry.

## Changes made to `opensearch_local_certificates_creator.sh`

A new section was appended at the end of the script (after certificate generation and `opensearch.yml` patching) that:

1. **Reads `OPENSEARCH_INITIAL_ADMIN_PASSWORD`** from `OpenSearch-3.6/.env` using `grep`/`cut` (same pattern used elsewhere in the script).
2. **Reads `OPEN_SEARCH_VERSION`** from `.env` to know which image to run for hash generation.
3. **Generates the bcrypt hash** by running OpenSearch's own `hash.sh` tool in a temporary container. The password is passed via an environment variable (not a command-line argument) so that special characters (`@`, `#`, `$`, etc.) are handled safely without any shell quoting issues:

```bash
ADMIN_PASS="$OPENSEARCH_INITIAL_ADMIN_PASSWORD" \
docker run --rm \
  -e "ADMIN_PASS=${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" \
  "opensearchproject/opensearch:${OS_VER}" \
  bash -c '/usr/share/opensearch/plugins/opensearch-security/tools/hash.sh -p "$ADMIN_PASS" 2>/dev/null'
```

4. **Updates all `hash:` entries in `internal_users.yml`** using Python's `re.sub` to replace any existing bcrypt hash (pattern `\$2[aby]\$\d+\$[./A-Za-z0-9]+`) with the freshly generated one. Python is used instead of `sed` because bcrypt hashes contain `/`, `$`, and `.` — all of which conflict with common `sed` delimiters:

```bash
python3 -c "
import re, sys
content = open('${INTERNAL_USERS_FILE}').read()
new_content = re.sub(
    r'(hash:\s*\")[^\$]*(\\\$2[aby]\\\$[^\"]+)(\")',
    r'\1${NEW_HASH}\3',
    content
)
open('${INTERNAL_USERS_FILE}', 'w').write(new_content)
"
```

5. **Prints a reminder** to wipe the OpenSearch data directories before restarting:

```log
[REMINDER] Wipe data directories before restarting OpenSearch:
  rm -rf assets/opensearch/data/os0{1,2,3,4,5}data/*
```

## Verification

After running the script with password `testSimplu`:
- `internal_users.yml` hash entries changed from `$2y$12$.MrUYog2krxCrFiqWvTGy…` (hash for `testSimplu` from previous run) to `$2y$12$ihOmRJyfhO7xJCwsIDJL5…` (new hash for same password, different random salt — confirming the update fired).
- Cluster restarted with the new certs and the new hash, reached green status, `admin:testSimplu` authenticated successfully.

## Files changed

| File | Change |
|---|---|
| `OpenSearch-3.6/opensearch_local_certificates_creator.sh` | New section at end of script: reads password and OS version from `.env`, generates bcrypt hash via `docker run opensearchproject/opensearch hash.sh`, updates all `hash:` entries in `internal_users.yml` using Python regex, prints data-dir wipe reminder |
