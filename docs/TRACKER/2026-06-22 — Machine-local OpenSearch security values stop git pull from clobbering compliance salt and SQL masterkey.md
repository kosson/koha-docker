---
title: "Machine-local OpenSearch security values: stop git pull from clobbering compliance salt and SQL masterkey"
date: 2026-06-22
tags:
 - OpenSearch
 - security
 - salt
 - SQL
 - keys
---
# 2026-06-22 — Machine-local OpenSearch security values: stop git pull from clobbering compliance salt and SQL masterkey

## Problem

After every `git pull` from another workstation, the two security-critical settings in each node's `opensearch.yml` were overwritten with the values generated on a different machine:

```yaml
plugins.security.compliance.salt: "R77RJ8MoyToszzRk"
plugins.query.datasources.encryption.masterkey: "dd3128606f96784ad30e65c3ef165fb1"
```

Both values are machine-specific because `opensearch_local_certificates_creator.sh` generates them with `tr -dc 'A-Za-z0-9' < /dev/urandom` and `openssl rand -hex 16` on every run. Until now the script patched the values directly into all five `opensearch.yml` files — files that **are** tracked by git. As a result:

- Workstation A runs the cert creator → values A committed and pushed.
- Workstation B pulls → values A overwrite B's local values.
- Workstation B starts the cluster → the compliance salt and SQL masterkey in the running cluster no longer match what is in the `opensearch.yml` files on B.

## Root cause analysis

### Why are the values in `opensearch.yml` at all?

The compliance salt (`plugins.security.compliance.salt`) is required by the OpenSearch Security plugin for field-level masking. The SQL datasource master key (`plugins.query.datasources.encryption.masterkey`) is required by the SQL/PPL plugin to encrypt stored data-source credentials. Both must be **identical across all five nodes** in the cluster, but they need not be identical across different developer machines — each machine's cluster is independent.

### Why do the values need to survive `git pull`?

The SQL master key in particular is destructive to change on a live cluster: any data-source credentials stored in OpenSearch are AES-encrypted with that key. Changing it makes previously stored credentials unreadable. Even on a dev machine, this means losing any configured index datasources on every `git pull` that came from another machine.

### What makes the `opensearch.yml` approach wrong?

The five `opensearch.yml` files (`config/os01/opensearch.yml` through `config/os05/opensearch.yml`) are committed to git because they carry structural, non-secret configuration — TLS cert paths, Security plugin settings, node roles, system index lists, etc. Mixing machine-specific generated secrets into the same files makes the entire file perpetually dirty in `git status`, and every push/pull races between machines.

## Solution

**Move the generated values out of the tracked `opensearch.yml` files and into the gitignored `OpenSearch-3.6/.env`.**

OpenSearch natively supports `${VAR_NAME}` substitution in `opensearch.yml` from the container's environment. Since every node's service block in `docker-compose.yml` already declares `env_file: .env`, any variable written to `.env` is automatically available inside the container — no `docker-compose.yml` changes are required.

The approach is:

1. Replace the hardcoded values in all five `opensearch.yml` files with `${OS_COMPLIANCE_SALT}` and `${OS_QUERY_MASTERKEY}` placeholders.
2. Rewrite the cert creator script to write the generated values into `.env` instead of patching the YAML files.
3. Add `OpenSearch-3.6/.env` to `.gitignore` so it is machine-local and never pushed.
4. Add `OpenSearch-3.6/.env.example` (git-tracked) as a template for first-time setup on a new machine.
5. Remove `OpenSearch-3.6/.env` from git's index (`git rm --cached`) so the existing committed version no longer blocks the gitignore rule.

## Changes made

### 1. All five `opensearch.yml` files — replace hardcoded values with env-var placeholders

**Files:** `assets/opensearch/config/os01/opensearch.yml` through `os05/opensearch.yml`

Before (identical in all five files):

```yaml
# W2: compliance field-masking salt (must be identical on all nodes)
plugins.security.compliance.salt: "R77RJ8MoyToszzRk"
# W3: SQL plugin datasource encryption master key
plugins.query.datasources.encryption.masterkey: "dd3128606f96784ad30e65c3ef165fb1"
```

After (identical in all five files):

```yaml
# W2: compliance field-masking salt (must be identical on all nodes)
# Value is read from OS_COMPLIANCE_SALT in OpenSearch-3.6/.env (gitignored — machine-specific)
plugins.security.compliance.salt: "${OS_COMPLIANCE_SALT}"
# W3: SQL plugin datasource encryption master key
# Value is read from OS_QUERY_MASTERKEY in OpenSearch-3.6/.env (gitignored — machine-specific)
plugins.query.datasources.encryption.masterkey: "${OS_QUERY_MASTERKEY}"
```

The `${...}` syntax is OpenSearch's built-in env-var interpolation — it reads the value from the container's environment at startup, before the Security plugin processes the setting. No additional configuration is required to activate this feature.

### 2. `opensearch_local_certificates_creator.sh` — write to `.env` instead of patching YAML

The section that previously ran a `for cfg in .../os*/opensearch.yml` loop with `sed -i` has been replaced.

**Before:**

```bash
COMPLIANCE_SALT="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
SQL_MASTERKEY="$(openssl rand -hex 16)"
CONFIG_BASE="$SCRIPT_DIR/assets/opensearch/config"

for cfg in "$CONFIG_BASE"/os*/opensearch.yml; do
    if grep -q "^plugins.security.compliance.salt:" "$cfg"; then
        sed -i "s|^plugins.security.compliance.salt:.*|...$COMPLIANCE_SALT...|" "$cfg"
    else
        echo "plugins.security.compliance.salt: \"$COMPLIANCE_SALT\"" >> "$cfg"
    fi
    if grep -q "^plugins.query.datasources.encryption.masterkey:" "$cfg"; then
        sed -i "s|^plugins.query.datasources.encryption.masterkey:.*|...$SQL_MASTERKEY...|" "$cfg"
    else
        echo "plugins.query.datasources.encryption.masterkey: \"$SQL_MASTERKEY\"" >> "$cfg"
    fi
done
```

**After:**

```bash
# ENV_FILE is used by both the compliance-salt section and the hash section below.
ENV_FILE="$SCRIPT_DIR/.env"

COMPLIANCE_SALT="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
SQL_MASTERKEY="$(openssl rand -hex 16)"

_upsert_env() {
    local key="$1" value="$2" file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

_upsert_env "OS_COMPLIANCE_SALT" "$COMPLIANCE_SALT" "$ENV_FILE"
_upsert_env "OS_QUERY_MASTERKEY"  "$SQL_MASTERKEY"  "$ENV_FILE"
```

`_upsert_env` updates the key in-place if it already exists in `.env`, or appends it if not. This is idempotent and safe for repeated runs. The `ENV_FILE` variable definition was also moved up so it is shared by both the salt/masterkey section and the pre-existing password-hash section that runs later.

### 3. `OpenSearch-3.6/.env` — two new variables appended

A new section was added at the end of the file documenting the machine-local variables and seeding them with the current machine's values:

```bash
# ── Machine-local OpenSearch security values ─────────────────────────────────
# These are generated by opensearch_local_certificates_creator.sh and are
# MACHINE-SPECIFIC. This file is gitignored so each workstation retains its own
# values and git pull never overwrites them.
#
# Both values are referenced as ${OS_COMPLIANCE_SALT} / ${OS_QUERY_MASTERKEY}
# in every node's opensearch.yml; OpenSearch substitutes them at startup.
#
# WARNING: Do NOT change OS_QUERY_MASTERKEY on a running cluster — all previously
# stored SQL datasource credentials would become unreadable. Regenerate only
# when setting up a fresh cluster (after wiping os0{1..5}data/).
OS_COMPLIANCE_SALT=R77RJ8MoyToszzRk
OS_QUERY_MASTERKEY=dd3128606f96784ad30e65c3ef165fb1
```

### 4. `OpenSearch-3.6/.env.example` — new git-tracked template

A new file committed to git that serves as the setup template for any new workstation. It contains all variables from `.env` but with the machine-specific fields left blank and the password set to `changeme`:

```bash
OS_COMPLIANCE_SALT=
OS_QUERY_MASTERKEY=
```

First-time setup on a new machine:

```bash
cp OpenSearch-3.6/.env.example OpenSearch-3.6/.env
# Edit .env: set OPENSEARCH_INITIAL_ADMIN_PASSWORD and other site values
bash OpenSearch-3.6/opensearch_local_certificates_creator.sh
# The script generates and writes OS_COMPLIANCE_SALT and OS_QUERY_MASTERKEY
# into .env automatically.
```

### 5. `.gitignore` — `OpenSearch-3.6/.env` added, `.env.example` referenced in comment

```gitignore
# OpenSearch machine-local config (passwords, compliance salt, SQL masterkey).
# Each workstation generates its own values via opensearch_local_certificates_creator.sh.
# Copy OpenSearch-3.6/.env.example to OpenSearch-3.6/.env and run the script on first use.
OpenSearch-3.6/.env
```

### 6. `git rm --cached OpenSearch-3.6/.env`

The file was previously tracked by git. Running `git rm --cached` removes it from git's index without deleting the file on disk. After the next commit the gitignore rule takes effect permanently.

## Why this approach is correct

| Concern | How addressed |
|---|---|
| Values must be identical on all 5 nodes per cluster | Both variables come from `.env`, which is one shared file consumed by all five services via `env_file: .env` in `docker-compose.yml` |
| Values must survive `git pull` | `.env` is gitignored — git never reads or writes it after `git rm --cached` |
| `opensearch.yml` must stay clean/generic in git | Only `${OS_COMPLIANCE_SALT}` / `${OS_QUERY_MASTERKEY}` placeholders remain — identical on all machines, never dirty |
| New machines need a starting point | `.env.example` provides the template; cert creator script auto-populates the two fields |
| Changing values on a running cluster is dangerous | Warning documented in both `.env` and `.env.example`; the cert creator has always carried this warning |

## Files changed

| File | Change |
|---|---|
| `assets/opensearch/config/os01/opensearch.yml` | Replaced hardcoded salt and masterkey with `${OS_COMPLIANCE_SALT}` / `${OS_QUERY_MASTERKEY}` placeholders + explanatory comments |
| `assets/opensearch/config/os02/opensearch.yml` | Same as os01 |
| `assets/opensearch/config/os03/opensearch.yml` | Same as os01 |
| `assets/opensearch/config/os04/opensearch.yml` | Same as os01 |
| `assets/opensearch/config/os05/opensearch.yml` | Same as os01 |
| `opensearch_local_certificates_creator.sh` | `ENV_FILE` defined at top of post-cert section; salt/masterkey section replaced with `_upsert_env` calls that write to `.env`; YAML patching loop removed |
| `OpenSearch-3.6/.env` | Added `OS_COMPLIANCE_SALT` and `OS_QUERY_MASTERKEY` variables with full explanatory comment block; removed from git tracking via `git rm --cached` |
| `OpenSearch-3.6/.env.example` | New git-tracked template file for first-time setup on a new workstation |
| `.gitignore` | Added `OpenSearch-3.6/.env` with comment explaining purpose and pointing to `.env.example` |
