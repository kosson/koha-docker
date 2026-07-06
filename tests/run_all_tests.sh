#!/usr/bin/env bash
# tests/run_all_tests.sh
#
# Runs every test suite in this directory in order:
#   1. Static analysis  (no Docker needed)
#   2. Unit tests       (no Docker needed)
#   3. Integration test (requires running stack — skipped automatically if not up)
#
# Usage:
#   cd koha-docker
#   bash tests/run_all_tests.sh
#
# Exit code: 0 = all tests passed/skipped, 1 = at least one test failed.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Colour helpers (suppressed when not a tty)
if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

SUITES=(
    "${TESTS_DIR}/test_stack_sh_static.sh"
    "${TESTS_DIR}/test_run_sh_static.sh"
    "${TESTS_DIR}/test_db_detection_unit.sh"
    "${TESTS_DIR}/test_restart_integration.sh"
)

SUITE_LABELS=(
    "Static analysis         (stack.sh backup/restore)"
    "Static analysis         (files/run.sh)"
    "Unit tests              (mock mysql)"
    "Integration test        (Docker restart)"
)

overall_pass=0
overall_fail=0
overall_skip=0

run_suite() {
    local script="$1"
    local label="$2"
    echo ""
    echo -e "${BOLD}── ${label} ──${RESET}"
    echo ""

    local out
    local rc=0
    out=$(bash "${script}" 2>&1) || rc=$?

    echo "${out}"

    local passed skipped failed
    passed=$(echo "${out}" | grep -c '^ok '    || true)
    failed=$(echo "${out}"  | grep -c '^not ok '|| true)
    skipped=$(echo "${out}" | grep -c '# SKIP'  || true)

    overall_pass=$(( overall_pass + passed ))
    overall_fail=$(( overall_fail + failed ))
    overall_skip=$(( overall_skip + skipped ))

    if [[ ${rc} -eq 0 ]]; then
        echo -e "${GREEN}  → PASS (${passed} ok, ${skipped} skipped)${RESET}"
    else
        echo -e "${RED}  → FAIL (${failed} failures, ${passed} ok, ${skipped} skipped)${RESET}"
    fi
    return ${rc}
}

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Koha-Docker test suite — restart + backup/restore checks    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

suite_failures=0
for i in "${!SUITES[@]}"; do
    run_suite "${SUITES[$i]}" "${SUITE_LABELS[$i]}" || suite_failures=$(( suite_failures + 1 ))
done

echo ""
echo "────────────────────────────────────────────────────────────────"
echo "  Total: ${overall_pass} passed  ${overall_fail} failed  ${overall_skip} skipped"
echo "────────────────────────────────────────────────────────────────"
echo ""

if [[ ${suite_failures} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All suites passed.${RESET}"
    exit 0
else
    echo -e "${RED}${BOLD}${suite_failures} suite(s) failed.${RESET}"
    exit 1
fi
