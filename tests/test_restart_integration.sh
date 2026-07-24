#!/usr/bin/env bash
# tests/test_restart_integration.sh
#
# Integration test: verifies that restarting just the Koha container against a
# persistent database does NOT fail with "Database is not empty!".
#
# Prerequisites
#   - A running stack (./stack.sh start or docker compose up -d has been run)
#   - The koha-db-data volume must be populated (i.e. Koha has been set up)
#   - Docker must be accessible from the current user
#
# What it does
#   1. Confirms the stack is healthy before the test.
#   2. Stops the Koha container (DB + Memcached stay up).
#   3. Restarts the Koha container via docker compose up --force-recreate.
#   4. Waits up to MAX_WAIT seconds for "koha-testing-docker has started up".
#   5. Checks the container did not exit with code 255 ("Database is not empty!").
#
# Exit code: 0 = test passed, 1 = test failed, 2 = prerequisite not met.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
ENV_FILE="${REPO_ROOT}/env/.env"
MAX_WAIT=${MAX_WAIT:-300}   # seconds to wait for Koha to finish re-initialising

# ── tiny TAP helper ──────────────────────────────────────────────────────────
PASS=0; FAIL=0; _N=0
ok()     { _N=$(( _N + 1 )); echo "ok ${_N} - $1";     PASS=$(( PASS + 1 )); }
not_ok() { _N=$(( _N + 1 )); echo "not ok ${_N} - $1"; FAIL=$(( FAIL + 1 )); }
skip()   { _N=$(( _N + 1 )); echo "ok ${_N} - $1 # SKIP $2"; }
# ─────────────────────────────────────────────────────────────────────────────

compose() {
    docker compose \
        -f "${COMPOSE_FILE}" \
        --env-file "${ENV_FILE}" \
        --project-directory "${REPO_ROOT}" \
        "$@"
}

echo "TAP version 14"
echo "# Integration test — Koha container restart with persistent database"
echo ""

# ── Prerequisite: Docker available ──────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    echo "Bail out! docker not found — cannot run integration tests"
    exit 2
fi

# ── Prerequisite: compose file exists ───────────────────────────────────────
if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo "Bail out! docker-compose.yml not found at ${COMPOSE_FILE}"
    exit 2
fi

# ── Prerequisite: env file exists ───────────────────────────────────────────
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Bail out! env/.env not found at ${ENV_FILE}"
    exit 2
fi

# ── Prerequisite: DB container running ───────────────────────────────────────
if ! compose ps --status running db 2>/dev/null | grep -q "running\|Up"; then
    skip "DB container is running" "stack is not started — run ./stack.sh start first"
    skip "Koha container restart succeeds" "stack is not started"
    skip "Container does not exit with code 255" "stack is not started"
    echo ""
    echo "1..${_N}"
    echo "# Skipped: stack is not running"
    exit 0
fi
ok "DB container is running"

# ── Prerequisite: Koha DB has existing data ──────────────────────────────────
KOHA_INSTANCE=$(grep -E '^KOHA_INSTANCE=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '"'"'" || echo "kohadev")
DB_NAME="koha_${KOHA_INSTANCE}"
DB_CONTAINER="$(basename "${REPO_ROOT}")-db-1"

DB_ROOT_PASS="$(grep -E '^KOHA_DB_ROOT_PASSWORD=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
DB_ROOT_PASS="${DB_ROOT_PASS:-password}"

tables=$(docker exec "${DB_CONTAINER}" \
    mysql -uroot -p"${DB_ROOT_PASS}" "${DB_NAME}" \
    -sse "SELECT COUNT(*) FROM information_schema.tables
          WHERE table_schema='${DB_NAME}'
          AND table_name='systempreferences';" 2>/dev/null || echo 0)

if [[ "${tables:-0}" -eq 0 ]]; then
    skip "Database has existing Koha data" "systempreferences not found — cannot test restart against empty DB"
    skip "Koha container restart succeeds" "no existing data"
    skip "Container does not exit with code 255" "no existing data"
    echo ""
    echo "1..${_N}"
    echo "# Skipped: Koha database is empty (run the stack fully first)"
    exit 0
fi
ok "Database '${DB_NAME}' has existing Koha data (systempreferences present)"

# ── Stop the Koha container ───────────────────────────────────────────────────
echo "# Stopping Koha container..."
compose stop koha 2>&1 | sed 's/^/# /'

# ── Restart Koha without wiping the DB ───────────────────────────────────────
echo "# Restarting Koha container with USE_EXISTING_DB=yes (simulating production restart)..."
USE_EXISTING_DB=yes compose up -d --force-recreate koha 2>&1 | sed 's/^/# /'

# ── Wait for startup to complete ─────────────────────────────────────────────
echo "# Waiting up to ${MAX_WAIT}s for Koha to finish re-initialising..."
elapsed=0
startup_ok=false
error_255=false

while (( elapsed < MAX_WAIT )); do
    sleep 5
    elapsed=$(( elapsed + 5 ))

    # Check whether the container exited (code 255 = "Database is not empty!")
    state=$(docker inspect --format '{{.State.Status}}' "$(basename "${REPO_ROOT}")-koha-1" 2>/dev/null || echo "unknown")
    exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$(basename "${REPO_ROOT}")-koha-1" 2>/dev/null || echo -1)

    if [[ "${state}" == "exited" && "${exit_code}" == "255" ]]; then
        error_255=true
        break
    fi

    # Check logs for the success banner
    if compose logs --tail=50 koha 2>/dev/null | grep -q "koha-testing-docker has started up"; then
        startup_ok=true
        break
    fi

    # Check logs for the fatal error (fail fast)
    if compose logs --tail=50 koha 2>/dev/null | grep -q "Database is not empty!"; then
        error_255=true
        break
    fi

    printf "\r# [%ds] waiting..." "${elapsed}"
done
echo ""

# ── Assertions ───────────────────────────────────────────────────────────────
if [[ "${error_255}" == true ]]; then
    not_ok "Koha container restart succeeds (FATAL: 'Database is not empty!' detected)"
    not_ok "Container does not exit with code 255"
else
    ok "Koha container restart succeeds (no 'Database is not empty!' error)"
    if [[ "${startup_ok}" == true ]]; then
        ok "Container started up fully (success banner found in logs)"
    else
        not_ok "Container started up fully within ${MAX_WAIT}s (banner not seen — check logs)"
    fi
fi

# ── Cleanup note ─────────────────────────────────────────────────────────────
echo ""
echo "# NOTE: the stack was restarted but NOT reset."
echo "# Run './stack.sh start' to get a fresh database, or"
echo "# './stack.sh start --no-fresh-db' to keep the current data."

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
