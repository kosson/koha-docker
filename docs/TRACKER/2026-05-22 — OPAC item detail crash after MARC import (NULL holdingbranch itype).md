---
title: OPAC item detail crash after MARC import (NULL holdingbranch / itype)
date: 2026.05.22
tags:
 - OPAC
 - MARC
 - import
 - holdingbranch
 - branchcode
 - holding_library
---
# 2026-05-22 — OPAC item detail crash after MARC import (NULL holdingbranch / itype)

## Problem

After a successful MARC import commit, opening an imported title in the OPAC produced:

```log
DBIC result _type  isn't of the _type Branch
at /kohadevbox/koha/opac/opac-detail.pl line 715.
at /usr/lib/x86_64-linux-gnu/perl-base/Carp.pm line 289
```

## Problem

After a MARC file was successfully staged (`stage_marc_for_import` job finished), the follow-up `marc_import_commit_batch` job consistently failed with:

```log
DBIx::Class::Storage::DBI::_dbh_execute(): DBI Exception: DBD::mysql::st execute failed:
Cannot add or update a child row: a foreign key constraint fails
(`koha_kohadev`.`items`, CONSTRAINT `items_ibfk_2`
```

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

```log
When `holdingbranch IS NULL`, the DBIx::Class relationship returns `undef`. `Koha::Object->new()` then checks `ref(undef) eq "Koha::Schema::Result::Branch"` → `"" ne "Branch"` → croaks. This is the double-space in the error message: `_type  isn't` — `ref(undef)` is the empty string.
```

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

```log
Memcached flushed afterwards (`echo flush_all | nc -w1 memcached 11211`).
FOREIGN KEY (`homebranch`) REFERENCES `branches` (`branchcode`) ON UPDATE CASCADE)
at /kohadevbox/koha/Koha/Object.pm line 174
Broken FK constraint at /kohadevbox/koha/Koha/BackgroundJob/MARCImportCommitBatch.pm line 93.
```

## Problem

After a successful MARC import commit, opening an imported title in the OPAC produced:

```log
DBIC result _type  isn't of the _type Branch
at /kohadevbox/koha/opac/opac-detail.pl line 715.
at /usr/lib/x86_64-linux-gnu/perl-base/Carp.pm line 289
```

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

When `holdingbranch IS NULL`, the DBIx::Class relation

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

```log
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

Memcached flushed afterwards (`echo flush_all | nc -w1 memcached 11211`).modification template** (Tools → MARC modification templates) to map or default these fields during staging before committing.

```log
When `holdingbranch IS NULL`, the DBIx::Class relationship returns `undef`. `Koha::Object->new()` then checks `ref(undef) eq "Koha::Schema::Result::Branch"` → `"" ne "Branch"` → croaks. This is the double-space in the error message: `_type  isn't` — `ref(undef)` is the empty string.
```

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

Memcached flushed afterwards (`echo flush_all | nc -w1 memcached 11211`).ship returns `undef`. `Koha::Object->new()` then checks `ref(undef) eq "Koha::Schema::Result::Branch"` → `"" ne "Branch"` → croaks. This is the double-space in the error message: `_type  isn't` — `ref(undef)` is the empty string.

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