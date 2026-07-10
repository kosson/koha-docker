---
title: "Env-driven Koha language automation in stack workflow"
date: 2026-07-10
tags:
 - i18n
 - translations
 - stack
 - automation
---
# 2026-07-10 — Env-driven Koha language automation in stack workflow

## Problem

Language enablement in the Koha container workflow was manual and easy to drift over time:

- Translation packs had to be installed by hand (`translate install <lang>`).
- `StaffInterfaceLanguages`, `OPACLanguages`, and `opaclanguagesdisplay` were not enforced by `stack.sh`.
- Rebuild/restart/restore scenarios could produce inconsistent language state between runs.
- Extending to additional languages required repeating ad-hoc shell commands.

Goal: make language setup repeatable, declarative, and extensible via `env/.env`, integrated directly into `stack.sh` lifecycle commands.

## Root cause

Before this change, `stack.sh` had no post-start i18n step. It managed services, DB lifecycle, and startup orchestration, but it did not:

- Normalize and validate a desired language list.
- Install missing translation packs automatically.
- Persist language preferences after container startup.
- Reapply language configuration after `restart` and `restore`.

## Solution summary

Implemented env-driven language automation in `stack.sh`, executed after Koha container startup.

New environment variables:

- `KOHA_DESIRED_LANGUAGES` (default: `en`)
- `KOHA_OPAC_LANGUAGES_DISPLAY` (default: `1`)
- `KOHA_TRANSLATIONS_REINSTALL` (default: `no`)

Behavior introduced:

1. Parse and normalize language list from env.
2. Validate language tags and deduplicate values.
3. Always include `en` first.
4. Wait until translator runtime exists in container (`misc/translator/translate` + `misc/translator/po`).
5. Install requested translation packs (excluding `en`):
   - install missing only (`KOHA_TRANSLATIONS_REINSTALL=no`)
   - or force reinstall on each run (`...=yes`)
6. Update DB system preferences:
   - `StaffInterfaceLanguages`
   - `OPACLanguages`
   - `opaclanguagesdisplay`
7. Attempt cache clear (`misc/bin/clear_cache.pl`) and continue with warning if unavailable.

Integration points:

- `start`
- `restart`
- `restore`

All now call the same post-start function to keep behavior consistent.

## Detailed code changes

### 1) `stack.sh` configuration inputs

Added env reads at startup and runtime reload:

- `KOHA_DESIRED_LANGUAGES`
- `KOHA_OPAC_LANGUAGES_DISPLAY`
- `KOHA_TRANSLATIONS_REINSTALL`

### 2) New helper functions in `stack.sh`

Added:

- `normalize_language_list()`
  - Trims spaces
  - Enforces `^[A-Za-z0-9_-]+$`
  - Deduplicates
  - Prepends `en`

- `wait_translation_runtime()`
  - Polls until translator script and PO directory are available inside `koha` container

- `configure_koha_languages()`
  - Core orchestration for pack install + syspref update + cache clear

### 3) Lifecycle wiring in `stack.sh`

Called `configure_koha_languages()` after `start_koha` in:

- `start` command path
- `restart` command path
- `restore_backup_bundle()` flow

### 4) Help/usage update in `stack.sh`

Extended `--help` output with a dedicated section:

- `Koha language automation (env/.env)`

Added an example invocation:

```bash
KOHA_DESIRED_LANGUAGES=en,es-ES,ro-RO ./stack.sh start
```

### 5) Environment templates

Updated `env/template.env` and `env/defaults.env` with defaults and comments for:

- `KOHA_DESIRED_LANGUAGES=en`
- `KOHA_OPAC_LANGUAGES_DISPLAY=1`
- `KOHA_TRANSLATIONS_REINSTALL=no`

### 6) README documentation

Updated:

- Quick-start env section to mention optional repeatable multi-language config.
- `Configuring the environment variables` with a dedicated `Language automation` subsection.
- Explicit note: keep `SKIP_L10N` empty/no, otherwise non-English installs fail.

## Files changed

| File | Change |
|---|---|
| `stack.sh` | Added env reads/reloads, language normalization, translation install orchestration, syspref update, cache clear, and start/restart/restore integration |
| `env/template.env` | Added documented language automation variables |
| `env/defaults.env` | Added language automation default values |
| `README.md` | Added language automation docs and examples |

## Example configuration (Spanish + Romanian)

```bash
KOHA_DESIRED_LANGUAGES=en,es-ES,ro-RO
KOHA_OPAC_LANGUAGES_DISPLAY=1
KOHA_TRANSLATIONS_REINSTALL=no
```

Then run:

```bash
./stack.sh start --no-fresh-db
```

## Validation performed

- `bash -n stack.sh` (syntax check): passed.
- Editor problems check on changed files:
  - `stack.sh`: no errors.
  - `env/template.env`: no errors.
  - `env/defaults.env`: no errors.
  - `README.md`: existing markdown style warnings present in file baseline; no functional impact on this runtime feature.

## Runtime follow-up fixes (same day)

During live startup validation, three sequencing/runtime problems were observed and fixed in `stack.sh`.

### 1) Koha instance race (`koha-shell` called too early)

Observed error:

```text
Error: The instance doesn't exist: kohadev
```

Fix applied:

- Extended `wait_translation_runtime()` to gate on actual instance readiness, not only translator file presence.
- Added checks for:
  - `/etc/koha/sites/${KOHA_INSTANCE}`
  - instance user `${KOHA_INSTANCE}-koha`
  - successful `sudo koha-shell ${KOHA_INSTANCE} -p -c 'true'`

### 2) Translation script Perl include path (`C4::Context` missing)

Observed error:

```text
Can't locate C4/Context.pm in @INC ... at LangInstaller.pm line 22
```

Fix applied:

- Translation install command now exports `PERL5LIB` with Koha source paths before running `./translate`:
  - `/kohadevbox/koha`
  - `/kohadevbox/koha/lib`

### 3) Translator writing too early / wrong privilege context

Observed symptoms:

- language directories reported missing under `/usr/share/koha/...`
- DB syspref update attempted before schema was fully ready in early startup path

Fix applied:

- Added full-startup readiness gate (`/ktd_ready`) to wait until container bootstrap is complete.
- Switched translator invocation from `koha-shell` user context to container root shell with explicit `KOHA_CONF` + `PERL5LIB`, so language output paths under `/usr/share/koha/...` are writable.
- Corrected “already installed” check paths to actual deployed template locations:
  - `/usr/share/koha/intranet/htdocs/intranet-tmpl/prog/<lang>`
  - `/usr/share/koha/opac/htdocs/opac-tmpl/bootstrap/<lang>`

## Final status for this task

- Env-driven language automation remains the primary approach.
- Startup sequencing issues found during live execution were resolved in `stack.sh`.
- Current behavior is stable for `start`, `restart`, and `restore` language reapplication workflows.

## Operational notes

- `SKIP_L10N=yes` disables l10n fetch in `run.sh`; translation install for non-English languages will fail by design.
- If a requested language is not present in available PO packs, translator install will fail early, making misconfiguration visible.
- `KOHA_TRANSLATIONS_REINSTALL=no` is recommended for normal usage to minimize repeated work on restarts.

## Outcome

Language setup is now deterministic and environment-driven across the full stack lifecycle, and adding new languages only requires editing `env/.env`.
