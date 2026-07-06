#!/usr/bin/env bash
# tests/test_stack_sh_static.sh
#
# Static checks for stack.sh backup/restore support.
# No Docker required.

set -euo pipefail

STACK_SH="$(cd "$(dirname "$0")/.." && pwd)/stack.sh"

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
    if grep -qF -- "${pattern}" "${STACK_SH}"; then
        ok "${desc}"
    else
        not_ok "${desc} (pattern not found: ${pattern})"
    fi
}

echo "TAP version 14"
echo "# Static checks on stack.sh backup/restore support"
echo ""

assert_contains "help mentions backup command" "backup      Create a tar.gz backup bundle for env files + MariaDB data"
assert_contains "help mentions restore command" "restore     Restore env files + MariaDB data from a backup bundle"
assert_contains "dispatcher handles backup" "backup)"
assert_contains "dispatcher handles restore" "restore)"
assert_contains "backup root is defined" 'BACKUP_ROOT="${SCRIPT_DIR}/backups"'
assert_contains "backup command supports --output" "--output)"
assert_contains "restore command supports --input" "--input)"
assert_contains "backup uses mysqldump" 'mysqldump -uroot -p"${KOHA_DB_ROOT_PASSWORD}"'
assert_contains "restore imports the dump" 'gzip -dc "${stage_dir}/database/${DB_NAME}.sql.gz"'
assert_contains "restore starts Traefik" "start_traefik"
assert_contains "restore starts Koha" "start_koha"

echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1