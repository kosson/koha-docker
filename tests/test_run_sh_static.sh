#!/usr/bin/env bash
# tests/test_run_sh_static.sh
#
# Static analysis tests for files/run.sh.
# No Docker, no database, no network required.
# Every assertion verifies that the fix for the "Database is not empty!" restart
# bug (do_all_you_can_do.pl line 89) is correctly present in the source file.
#
# Exit code: 0 = all tests passed, 1 = at least one failure.

set -euo pipefail

RUN_SH="$(cd "$(dirname "$0")/.." && pwd)/files/run.sh"

# ── tiny TAP-style helper ────────────────────────────────────────────────────
PASS=0; FAIL=0; _N=0
ok() {
    _N=$(( _N + 1 ))
    echo "ok ${_N} - $1"
    PASS=$(( PASS + 1 ))
}
not_ok() {
    _N=$(( _N + 1 ))
    echo "not ok ${_N} - $1"
    FAIL=$(( FAIL + 1 ))
}
assert_contains() {
    local desc="$1"; local pattern="$2"
    if grep -qF -- "${pattern}" "${RUN_SH}"; then
        ok "${desc}"
    else
        not_ok "${desc} (pattern not found: ${pattern})"
    fi
}
assert_not_contains() {
    local desc="$1"; local pattern="$2"
    if ! grep -qF -- "${pattern}" "${RUN_SH}"; then
        ok "${desc}"
    else
        not_ok "${desc} (unexpected pattern found: ${pattern})"
    fi
}
# ─────────────────────────────────────────────────────────────────────────────

echo "TAP version 14"
echo "# Static checks on files/run.sh"
echo "# Verifying the 'Database is not empty!' restart fix"
echo ""

# 1. The auto-detection block must exist
assert_contains \
    "run.sh contains DB auto-detection probe" \
    "[db-detect] Probing"

# 2. The probe must query information_schema for the right tables
assert_contains \
    "probe checks systempreferences table" \
    "systempreferences"

assert_contains \
    "probe checks borrowers table" \
    "borrowers"

# 3. The probe must use the correct credentials variables
assert_contains \
    "probe uses DB_HOSTNAME" \
    '--host="${DB_HOSTNAME}"'

assert_contains \
    "probe uses DB_USER" \
    '--user="${DB_USER}"'

assert_contains \
    "probe uses DB_PASSWORD" \
    '--password="${DB_PASSWORD}"'

# 4. On a positive probe result, USE_EXISTING_DB must be set to yes
assert_contains \
    "positive probe sets USE_EXISTING_DB=yes" \
    'USE_EXISTING_DB="yes"'

# 5. The old unconditional check must be replaced by (or preceded by) the probe
assert_contains \
    'USE_EXISTING_DB_FLAG is still set when USE_EXISTING_DB=yes' \
    'USE_EXISTING_DB_FLAG="--use-existing-db"'

# 6. do_all_you_can_do.pl must still receive the flag variable (not a hard-coded flag)
assert_contains \
    "do_all_you_can_do.pl receives USE_EXISTING_DB_FLAG" \
    '${USE_EXISTING_DB_FLAG}'

# 7. The probe must be guarded so it is skipped when USE_EXISTING_DB is already yes
assert_contains \
    'probe is skipped when USE_EXISTING_DB already equals yes' \
    '[ "${USE_EXISTING_DB}" != "yes" ]'

# 8. Temporary variable is cleaned up
assert_contains \
    "temporary _db_populated variable is unset" \
    "unset _db_populated"

# 9. Informational messages help operators understand what is happening
assert_contains \
    "log message on existing-data detection" \
    "Existing Koha data found"

assert_contains \
    "log message on empty database" \
    "Database is empty"

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
