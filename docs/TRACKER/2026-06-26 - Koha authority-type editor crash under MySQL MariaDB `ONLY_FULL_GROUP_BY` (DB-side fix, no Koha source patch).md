---
title: Koha authority-type editor crash under MySQL/MariaDB `ONLY_FULL_GROUP_BY` (DB-side fix, no Koha source patch)
date: 2026.06.26
tags:
 - authority
 - Koha
 - MariaDB
 - patch
 - source
 - authtypetext
---
# 2026-06-26 - Koha authority-type editor crash under MySQL/MariaDB `ONLY_FULL_GROUP_BY` (DB-side fix, no Koha source patch)

## Problem

Editing MARC authority structure after creating a new authority type triggered a hard 500 with DBIx/DBD::mysql exception:

```txt
'koha_kohadev.auth_types.authtypetext' isn't in GROUP BY
```

The stack trace pinpointed `koha/admin/auth_tag_structure.pl` around this query shape:

```sql
select count(*), auth_tag_structure.authtypecode, authtypetext
from auth_tag_structure, auth_types
where auth_types.authtypecode = auth_tag_structure.authtypecode
group by auth_tag_structure.authtypecode;
```

This query is tolerated by permissive SQL modes, but rejected by strict `ONLY_FULL_GROUP_BY` because `authtypetext` is selected without being aggregated or fully grouped.

## Root cause analysis

1. The runtime DB container was running in SQL mode strict enough to enforce full group-by semantics.
2. Koha admin path `authtype_create` still contains legacy SQL relying on older permissive MySQL behavior.
3. The combination caused deterministic failure exactly when the authority-type listing query executed.

In short: this was not a random data corruption issue; it was SQL mode incompatibility between legacy query semantics and strict server policy.

## Decision

Two valid repair paths were evaluated:

1. **Application patch**: change the Koha query to group by both columns (or rewrite with explicit JOIN + deterministic aggregation).
2. **Database policy patch**: keep Koha source untouched and remove `ONLY_FULL_GROUP_BY` from MariaDB `sql_mode`.

Per current requirement, we used **path 2** and explicitly avoided modifying Koha source as the final state.

## Proposed Koha patch for Bugzilla (not applied in this repo)

The following source patch was validated conceptually as the minimal standards-compliant fix for strict GROUP BY mode. It is included here for upstream issue submission.

### Option A (minimal-risk patch)

Patch target: `koha/admin/auth_tag_structure.pl` inside the `authtype_create` branch.

```diff
diff --git a/admin/auth_tag_structure.pl b/admin/auth_tag_structure.pl
--- a/admin/auth_tag_structure.pl
+++ b/admin/auth_tag_structure.pl
@@
-    $sth = $dbh->prepare(
-        "select count(*),auth_tag_structure.authtypecode,authtypetext from auth_tag_structure,auth_types where auth_types.authtypecode=auth_tag_structure.authtypecode group by auth_tag_structure.authtypecode"
-    );
+    $sth = $dbh->prepare(
+        "select count(*),auth_tag_structure.authtypecode,authtypetext from auth_tag_structure,auth_types where auth_types.authtypecode=auth_tag_structure.authtypecode group by auth_tag_structure.authtypecode,authtypetext"
+    );
```

Why this works:

1. Keeps existing behavior and selected columns unchanged.
2. Satisfies `ONLY_FULL_GROUP_BY` by grouping all non-aggregated selected columns.
3. Lowest blast radius for stable/backport branches.

### Option B (readability/modern SQL variant)

Same behavior, explicit `JOIN` style:

```sql
SELECT COUNT(*), ats.authtypecode, at.authtypetext
FROM auth_tag_structure ats
JOIN auth_types at ON at.authtypecode = ats.authtypecode
GROUP BY ats.authtypecode, at.authtypetext;
```

This can be proposed as a follow-up cleanup if maintainers prefer explicit joins.

### Suggested Bugzilla note

"The admin authority-type creation flow fails under `ONLY_FULL_GROUP_BY` because `authtypetext` is selected without full grouping in `admin/auth_tag_structure.pl` (`authtype_create` path). Proposed minimal patch adds `authtypetext` to GROUP BY."

## Changes made

### 1. `docker-compose.yml` (db service)

Added an explicit MariaDB startup mode override:

```yaml
command: ["--sql-mode=${DB_SQL_MODE:-STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION}"]
```

Effect: the DB server starts without `ONLY_FULL_GROUP_BY`, while still keeping other useful strict checks.

### 2. `env/defaults.env`

Added default:

```dotenv
DB_SQL_MODE=STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
```

### 3. `env/template.env`

Added the same `DB_SQL_MODE` variable plus explanatory comments for future operators.

### 4. `env/.env` (active deployment env)

Added:

```dotenv
DB_SQL_MODE=STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
```

This makes the behavior explicit for this workstation/runtime and reproducible across restarts.

### 5. Koha source status

Any temporary edit to `koha/admin/auth_tag_structure.pl` was reverted. Final remediation is DB-side only.

## Validation performed

After restarting the DB service, authenticated SQL checks confirmed effective runtime modes:

```sql
SELECT @@GLOBAL.sql_mode, @@SESSION.sql_mode;
```

Observed result (both global and session):

```log
STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
```

`ONLY_FULL_GROUP_BY` is absent, which removes the immediate trigger for this Koha admin query failure.

## Why this resolves the crash

The failing query depends on permissive grouping behavior. By disabling only the `ONLY_FULL_GROUP_BY` component, MariaDB accepts the query again and the authority-type MARC editor flow no longer aborts with the DBI exception.

## Trade-offs and follow-up recommendation

1. This is an operational compatibility fix, not a semantic SQL cleanup in Koha itself.
2. It is appropriate for this Docker dev/runtime stack where source immutability was requested.
3. Long-term upstream hygiene still favors patching the query in Koha to be standards-compliant, then optionally re-enabling `ONLY_FULL_GROUP_BY` later.

## Operator notes

1. If you change `DB_SQL_MODE`, recreate the DB container so startup args are re-applied.
2. If the error reappears, verify active mode first with `SELECT @@GLOBAL.sql_mode, @@SESSION.sql_mode;` before debugging application code.
3. Keep this DB policy aligned across developer machines to avoid environment-specific regressions.