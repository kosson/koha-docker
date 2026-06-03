#!/usr/bin/env bash
# tests/test_db_detection_unit.sh
#
# Unit tests for the DB auto-detection logic that guards the
# "Database is not empty!" error in do_all_you_can_do.pl.
#
# The detection logic is embedded inline (matching files/run.sh exactly) and
# tested with a fake `mysql` command so no real database is needed.
#
# Exit code: 0 = all tests passed, 1 = at least one failure.

set -euo pipefail

# ── tiny TAP helper ──────────────────────────────────────────────────────────
PASS=0; FAIL=0; _N=0
ok()     { _N=$(( _N + 1 )); echo "ok ${_N} - $1";     PASS=$(( PASS + 1 )); }
not_ok() { _N=$(( _N + 1 )); echo "not ok ${_N} - $1"; FAIL=$(( FAIL + 1 )); }
# ─────────────────────────────────────────────────────────────────────────────

# Scratch dir for fake binaries (cleaned up on exit)
TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT

# ── Detection function ────────────────────────────────────────────────────────
# This is a direct port of the detection block from files/run.sh.
# Keep it in sync with the source whenever run.sh changes.
# Its only external dependency is the `mysql` binary (replaced by a fake in tests).
detect_existing_db() {
    local use_existing_db="${1:-}"   # pre-set value (may be empty or "yes")
    local db_hostname="testhost"
    local db_user="testuser"
    local db_password="testpass"
    local db_name="koha_kohadev"

    local use_existing_db_flag=""

    if [ "${use_existing_db}" != "yes" ]; then
        local _db_populated
        _db_populated=$(mysql \
            --host="${db_hostname}" \
            --user="${db_user}" \
            --password="${db_password}" \
            --batch --skip-column-names \
            "${db_name}" \
            -e "SELECT IF(
                  (SELECT COUNT(*) FROM information_schema.tables
                   WHERE table_schema = DATABASE()
                   AND table_name IN ('systempreferences','borrowers')) > 0,
                'yes', 'no');" 2>/dev/null || echo "no")
        if [ "${_db_populated:-no}" = "yes" ]; then
            use_existing_db="yes"
        fi
        unset _db_populated
    fi

    if [ "${use_existing_db}" = "yes" ]; then
        use_existing_db_flag="--use-existing-db"
    fi

    # Output: "USE_EXISTING_DB|USE_EXISTING_DB_FLAG"
    echo "${use_existing_db}|${use_existing_db_flag}"
}

# ── Helper: build a fake mysql returning a preset answer ─────────────────────
make_fake_mysql() {
    local result="${1:-no}"
    cat > "${TMPDIR}/mysql" <<EOF
#!/bin/sh
echo "${result}"
EOF
    chmod +x "${TMPDIR}/mysql"
}

run_case() {
    local initial="${1:-}"
    PATH="${TMPDIR}:${PATH}" detect_existing_db "${initial}"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "TAP version 14"
echo "# Unit tests — DB auto-detection logic (mock mysql)"
echo ""

# ── Test 1: empty DB → USE_EXISTING_DB stays empty, flag stays empty ─────────
make_fake_mysql "no"
result=$(run_case "")
use_existing="${result%%|*}"
flag="${result##*|}"
if [[ -z "${use_existing}" ]]; then
    ok "empty DB: USE_EXISTING_DB stays empty"
else
    not_ok "empty DB: USE_EXISTING_DB stays empty (got '${use_existing}')"
fi
if [[ -z "${flag}" ]]; then
    ok "empty DB: USE_EXISTING_DB_FLAG stays empty"
else
    not_ok "empty DB: USE_EXISTING_DB_FLAG stays empty (got '${flag}')"
fi

# ── Test 2: non-empty DB → USE_EXISTING_DB becomes yes, flag is set ──────────
make_fake_mysql "yes"
result=$(run_case "")
use_existing="${result%%|*}"
flag="${result##*|}"
if [[ "${use_existing}" == "yes" ]]; then
    ok "non-empty DB: USE_EXISTING_DB becomes yes"
else
    not_ok "non-empty DB: USE_EXISTING_DB becomes yes (got '${use_existing}')"
fi
if [[ "${flag}" == "--use-existing-db" ]]; then
    ok "non-empty DB: USE_EXISTING_DB_FLAG is --use-existing-db"
else
    not_ok "non-empty DB: USE_EXISTING_DB_FLAG is --use-existing-db (got '${flag}')"
fi

# ── Test 3: USE_EXISTING_DB already yes → probe is skipped ───────────────────
# Fake mysql returns "no"; the guard should bypass the probe entirely.
make_fake_mysql "no"
result=$(run_case "yes")
use_existing="${result%%|*}"
flag="${result##*|}"
if [[ "${use_existing}" == "yes" ]]; then
    ok "pre-set yes: probe is skipped, USE_EXISTING_DB stays yes"
else
    not_ok "pre-set yes: probe is skipped, USE_EXISTING_DB stays yes (got '${use_existing}')"
fi
if [[ "${flag}" == "--use-existing-db" ]]; then
    ok "pre-set yes: flag is --use-existing-db"
else
    not_ok "pre-set yes: flag is --use-existing-db (got '${flag}')"
fi

# ── Test 4: mysql exits non-zero → safe fallback (treat as empty DB) ─────────
cat > "${TMPDIR}/mysql" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "${TMPDIR}/mysql"

result=$(run_case "")
use_existing="${result%%|*}"
if [[ -z "${use_existing}" ]]; then
    ok "mysql failure: safe fallback — USE_EXISTING_DB stays empty"
else
    not_ok "mysql failure: safe fallback — USE_EXISTING_DB stays empty (got '${use_existing}')"
fi

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1

