---
title: Follow-up: applied Koha source fix + regression test for strict GROUP BY
date: 2026.06.26
tags:
 - Koha
 - regression
 - testing
---
# 2026-06-26 - Follow-up: applied Koha source fix + regression test for strict GROUP BY

## Why this follow-up was needed

Despite the DB-side mitigation, the runtime still surfaced the same error in the authority-type flow. To remove dependency on environment SQL policy and make the behavior correct in strict mode, we applied the source-level fix and added a test.

## Source fix applied

File updated: `koha/admin/auth_tag_structure.pl`

Change:

```sql
-- from
GROUP BY auth_tag_structure.authtypecode

-- to
GROUP BY auth_tag_structure.authtypecode, 
---authtypetext
```

This makes the query compliant with `ONLY_FULL_GROUP_BY`.

## New regression test added

File updated: `koha/t/db_dependent/Authority/Tags.t`

New subtest: `auth_tag_structure query is strict GROUP BY compliant`

What it validates:

1. The source file still contains the compliant `GROUP BY ... authtypecode, authtypetext` shape.
2. Under session SQL mode that explicitly includes `ONLY_FULL_GROUP_BY`, the authority-tag query executes successfully.
3. Session SQL mode is restored after the subtest.

## Effect

1. The fix now works regardless of DB container sql_mode defaults.
2. Future regressions in this query path are caught by automated DB-dependent tests.

This seems to be linked with the following Bugzilla bugs:

- https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=42148 and
- https://bugs.koha-community.org/bugzilla3/show_bug.cgi?id=41406