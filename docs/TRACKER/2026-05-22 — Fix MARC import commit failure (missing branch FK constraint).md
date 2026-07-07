---
title: Fix MARC import commit failure (missing branch FK constraint)
date: 2026.05.22
tags:
 - MARC
 - import
 - FK
 - constraint
 - stage_marc_for_import
 - marc_import_commit_batch
 - 952$a
---
# 2026-05-22 — Fix MARC import commit failure (missing branch FK constraint)

## Problem

After a MARC file was successfully staged (`stage_marc_for_import` job finished), the follow-up `marc_import_commit_batch` job consistently failed with:

```log
DBIx::Class::Storage::DBI::_dbh_execute(): DBI Exception: DBD::mysql::st execute failed:
Cannot add or update a child row: a foreign key constraint fails
(`koha_kohadev`.`items`, CONSTRAINT `items_ibfk_2`
FOREIGN KEY (`homebranch`) REFERENCES `branches` (`branchcode`) ON UPDATE CASCADE)
at /kohadevbox/koha/Koha/Object.pm line 174
Broken FK constraint at /kohadevbox/koha/Koha/BackgroundJob/MARCImportCommitBatch.pm line 93.
```

**Root cause:** The imported MARC file (`CLINCIUAna-Maria.catalog.bib.acasa.mrc.mrc`) contained item records with MARC field `952$a` (homebranch) set to `MAIN`. The Koha database only contained the 12 default demo branches (CPL, FFL, FPL, etc.) loaded by `misc4dev/insert_data.pl` — `MAIN` was not among them.

The `import_items` table staged the items successfully (with `branchcode = NULL` in its own column — the actual branch code is embedded in the `marcxml` column). When the commit job tried to insert into the live `items` table, MariaDB rejected the insert because `homebranch = 'MAIN'` has no matching row in `branches`.

### MARC item field requirements for successful Koha imports (MARC21 field 952)

When exporting MARC records from any ILS for import into Koha, **every item record must include at minimum** the following `952` subfields. Missing subfields are stored as `NULL` and will cause crashes or silent data problems.

| Subfield | Koha `items` column | Required | Notes |
|---|---|---|---|
| `952$a` | `homebranch` | **YES** | Branch code of the owning library. Must exist in `branches.branchcode` before import. FK constraint — import fails if absent. |
| `952$b` | `holdingbranch` | **YES** | Branch currently holding the item. Should equal `$a` when unknown. **NULL causes OPAC crash** (`Koha::Library->_new_from_dbic(undef)`). |
| `952$y` | `itype` | **YES** | Item type code (e.g. `BK`, `MU`, `VM`). Must exist in `itemtypes.itemtype`. NULL suppresses circulation rules and may cause display errors. |
| `952$p` | `barcode` | Recommended | Unique barcode. NULL is allowed but items without barcodes cannot be checked out. |
| `952$c` | `location` | Optional | Shelving location authorised value (e.g. `GEN`, `REF`). NULL is safe. |
| `952$o` | `itemcallnumber` | Optional | Call number string. NULL is safe. |
| `952$g` | `price` | Optional | Purchase price decimal. NULL is safe. |
| `952$d` | `dateaccessioned` | Optional | Acquisition date (YYYY-MM-DD). NULL defaults to no date. |

**Pre-import checklist:**

1. **Branches** — run `SELECT branchcode FROM branches` and confirm every `952$a`/`952$b` value in your MARC file is present. Add missing branches via **Administration → Libraries** or:
   ```sql
   INSERT INTO branches (branchcode, branchname, pickup_location, public)
   VALUES ('CODE', 'Branch Name', 1, 1);
   ```
2. **Item types** — run `SELECT itemtype FROM itemtypes` and confirm every `952$y` value is present. Add missing types via **Administration → Item types**.
3. **Authorised values** — if `952$c` (location) or `952$8` (collection code) are used, verify values exist in **Administration → Authorised values** under categories `LOC` and `CCODE`.
4. **Barcode uniqueness** — if barcodes are present, confirm none already exist in `items.barcode`:
   ```sql
   SELECT barcode FROM items WHERE barcode IN (...);
   ```

**If you cannot fix the export source**, use a **MARC modification template** (Tools → MARC modification templates) to map or default these fields during staging before committing.

**Root cause (same MARC data gap):** The imported MARC file contained item records with only `952$a` (homebranch = `MAIN`). The subfields `952$b` (holdingbranch) and `952$y` (item type) were absent. Koha stored those columns as `NULL` in the `items` table.

`opac-detail.pl` iterates over every item and calls:

```perl
$item->holding_library->opac_info(...)   # line ~715
```

`Koha::Item->holding_library` does:

```perl
my $hb_rs = $self->_result->holdingbranch;   # DBIx::Class relationship accessor
return Koha::Library->_new_from_dbic($hb_rs);
```

When `holdingbranch IS NULL`, the DBIx::Class relationship returns `undef`. `Koha::Object->new()` then checks `ref(undef) eq "Koha::Schema::Result::Branch"` → `"" ne "Branch"` → croaks. This is the double-space in the error message: `_type  isn't` — `ref(undef)` is the empty string.

**Confirmed via:**

```sql
SELECT itemnumber, homebranch, holdingbranch, itype
FROM items ORDER BY itemnumber DESC LIMIT 10;
-- Result: homebranch=MAIN, holdingbranch=NULL, itype=NULL for all 10 imported items
```

## Fix applied

```sql
UPDATE items
SET   holdingbranch = homebranch,
      itype         = COALESCE(itype, 'BK')
WHERE holdingbranch IS NULL
  AND homebranch IS NOT NULL;
-- 10 rows updated
```

Memcached flushed afterwards (`echo flush_all | nc -w1 memcached 11211`).

- `worker-output.log` showed the FK constraint error at `MARCImportCommitBatch.pm line 93`
- `SELECT marcxml FROM import_items LIMIT 1` showed `<subfield code="a">MAIN</subfield>` inside the `952` datafield
- `SELECT branchcode FROM branches` confirmed no `MAIN` branch existed


## MARC item field requirements for successful Koha imports (MARC21 field 952)

When exporting MARC records from any ILS for import into Koha, **every item record must include at minimum** the following `952` subfields. Missing subfields are stored as `NULL` and will cause crashes or silent data problems.

| Subfield | Koha `items` column | Required | Notes |
|---|---|---|---|
| `952$a` | `homebranch` | **YES** | Branch code of the owning library. Must exist in `branches.branchcode` before import. FK constraint — import fails if absent. |
| `952$b` | `holdingbranch` | **YES** | Branch currently holding the item. Should equal `$a` when unknown. **NULL causes OPAC crash** (`Koha::Library->_new_from_dbic(undef)`). |
| `952$y` | `itype` | **YES** | Item type code (e.g. `BK`, `MU`, `VM`). Must exist in `itemtypes.itemtype`. NULL suppresses circulation rules and may cause display errors. |
| `952$p` | `barcode` | Recommended | Unique barcode. NULL is allowed but items without barcodes cannot be checked out. |
| `952$c` | `location` | Optional | Shelving location authorised value (e.g. `GEN`, `REF`). NULL is safe. |
| `952$o` | `itemcallnumber` | Optional | Call number string. NULL is safe. |
| `952$g` | `price` | Optional | Purchase price decimal. NULL is safe. |
| `952$d` | `dateaccessioned` | Optional | Acquisition date (YYYY-MM-DD). NULL defaults to no date. |

**Pre-import checklist:**

1. **Branches** — run `SELECT branchcode FROM branches` and confirm every `952$a`/`952$b` value in your MARC file is present. Add missing branches via **Administration → Libraries** or:
   ```sql
   INSERT INTO branches (branchcode, branchname, pickup_location, public)
   VALUES ('CODE', 'Branch Name', 1, 1);
   ```
2. **Item types** — run `SELECT itemtype FROM itemtypes` and confirm every `952$y` value is present. Add missing types via **Administration → Item types**.
3. **Authorised values** — if `952$c` (location) or `952$8` (collection code) are used, verify values exist in **Administration → Authorised values** under categories `LOC` and `CCODE`.
4. **Barcode uniqueness** — if barcodes are present, confirm none already exist in `items.barcode`:
   ```sql
   SELECT barcode FROM items WHERE barcode IN (...);
   ```

**If you cannot fix the export source**, use a **MARC modification template** (Tools → MARC modification templates) to map or default these fields during staging before committing.
```
When `holdingbranch IS NULL`, the DBIx::Class relationship returns `undef`. `Koha::Object->new()` then checks `ref(undef) eq "Koha::Schema::Result::Branch"` → `"" ne "Branch"` → croaks. This is the double-space in the error message: `_type  isn't` — `ref(undef)` is the empty string.

**Confirmed via:**
```sql
SELECT itemnumber, homebranch, holdingbranch, itype
FROM items ORDER BY itemnumber DESC LIMIT 10;
-- Result: homebranch=MAIN, holdingbranch=NULL, itype=NULL for all 10 imported items
```

## Fix applied

```sql
UPDATE items
SET   holdingbranch = homebranch,
      itype         = COALESCE(itype, 'BK')
WHERE holdingbranch IS NULL
  AND homebranch IS NOT NULL;
-- 10 rows updated
```

Memcached flushed afterwards (`echo flush_all | nc -w1 memcached 11211`).

### Fix

Created the missing branch directly in the `branches` table:

```sql
INSERT INTO branches (branchcode, branchname, pickup_location, public)
VALUES ('MAIN', 'Main Library', 1, 1);
```

The import batch (`import_batch_id = 1`) remained in `staged` status with all 10 records intact — no re-staging needed. The commit can be retried from **Tools → Staged MARC Management → Import this batch**.

### Notes for production / real libraries

- Before importing MARC files from an external system, verify that all branch codes referenced in item fields (`952$a` homebranch, `952$b` holdingbranch) exist in **Administration → Libraries**.
- If the demo branches (CPL, FFL, etc.) are not needed, delete them via the Koha admin UI after the import succeeds.
- Alternatively, import without items by setting `item_action = ignore` on the staging form — this bypasses the FK constraint entirely.