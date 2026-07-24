# 2026-07-24 — Alpine localization pack installation fix (Locale-PO)

**Status:** ✅ COMPLETED  
**Severity:** MEDIUM-HIGH (requested localization packs could not be installed)  
**Scope:** Alpine image dependencies (`Dockerfile-Alpine`), language automation reliability (`stack-alpine.sh`)

---

## Context

During Alpine stack startup, language automation attempted to install requested packs (`es-ES`, `ro-RO`, `ca-ES`, `hu-HU`, `de-DE`) but failed for each one with:

- `Can't locate Locale/PO.pm in @INC`

This blocked actual translation pack installation and left only warning-based fallback behavior.

---

## Root cause identified

The Koha translator path (`misc/translator/translate` -> `LangInstaller.pm`) requires:

- `Locale::PO`

Alpine runtime image did not include this module by default, so `./translate install <lang>` could not run.

---

## Fixes implemented

### 1) Add missing Perl dependency to Alpine image

Added `Locale::PO` installation to `Dockerfile-Alpine` using CPAN:

- `RUN cpanm --notest Locale::PO`

This makes localization support reproducible across machines through image build, not ad-hoc container mutation.

### 2) Reliability fix discovered during validation (`set -u` arrays)

After translation installs started succeeding, strict-mode bash surfaced an unrelated bug:

- `./stack-alpine.sh: line 228: failed_languages: unbound variable`

Cause:

- Arrays used with `${#array[@]}` under `set -u` were declared but not explicitly initialized.

Fix:

- Initialize arrays in `configure_koha_languages`:
  - `local -a languages=()`
  - `local -a install_languages=()`
  - `local -a failed_languages=()`

---

## Validation and results

### A) Dependency verification in running container

- Before rebuild: `Locale::PO` missing, while `YAML::XS`, `JSON`, `C4::Context`, `Modern::Perl` were present.
- After rebuild + recreate: `perl -e 'use Locale::PO'` succeeded.

### B) Translation installer verification

Executed translator commands inside Koha container:

- `./translate install es-ES`
- `./translate install ro-RO`

Result:

- successful (`TRANSLATE_PACKS_OK`)

### C) Stack-level startup flow verification

Command:

- `./stack-alpine.sh start --no-fresh-db --no-logs`

Final result:

- exit code `0`
- no `Can't locate Locale/PO.pm` errors
- language-pack installation phase runs for requested locales

Note:

- Existing non-fatal schema-timing guard remains: language preference DB writes can be skipped temporarily when `systempreferences` is not yet created on early bootstrap.

---

## Files changed

1. `Dockerfile-Alpine`
   - Added `Locale::PO` CPAN install step.

2. `stack-alpine.sh`
   - Initialized language arrays for strict-mode safety when no failures are collected.

---

## Outcome

Localization pack installation support is now present in the Alpine image and reproducible by build. The startup language automation no longer fails on missing `Locale::PO`, and strict-mode handling in the language loop is stable.