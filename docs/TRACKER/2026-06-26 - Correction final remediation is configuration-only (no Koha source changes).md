---
title: Correction: final remediation is configuration-only (no Koha source changes)
date: 2026.06.26
tags:
 - configuration
 - patching
 - source
---
# 2026-06-26 - Correction: final remediation is configuration-only (no Koha source changes)

The follow-up section above captured an intermediate attempt. Final state was adjusted per operational requirement to avoid Koha source modifications.

## Final adopted approach

1. Reverted all local Koha source edits in `koha/admin/auth_tag_structure.pl` and `koha/t/db_dependent/Authority/Tags.t`.
2. Kept DB/container-level mitigation (`DB_SQL_MODE` without `ONLY_FULL_GROUP_BY`).
3. Disabled Koha app-level strict SQL override in this stack template by setting:

```xml
<strict_sql_modes>0</strict_sql_modes>
```

in `files/templates/koha-conf-site.xml.in`.

## Why this was necessary

`Koha::Database` sets session SQL mode per connection. When `strict_sql_modes=1`, it forces `ONLY_FULL_GROUP_BY` even if DB global mode is permissive, which re-triggers the authority-type query failure.

## Validation

New wrapper-level integration guard added:

`tests/test_authority_groupby_sqlmode_integration.sh`

It verifies:

1. The legacy authority query fails in strict `ONLY_FULL_GROUP_BY` mode (expected).
2. The same query succeeds in non-strict app mode (expected workaround behavior).
3. Stack template keeps `strict_sql_modes` disabled.

This keeps the mitigation outside Koha source while providing repeatable detection.