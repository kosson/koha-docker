#!/usr/bin/env bash
# tests/run_integration_deterministic.sh
#
# Deterministic integration runner:
# - isolates test phases by preparing known stack state
# - enforces an execution order that avoids cross-test contamination
# - stores individual logs and prints a final stable summary
#
# Usage:
#   cd koha-docker
#   bash tests/run_integration_deterministic.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LEGACY_COMPOSE="${REPO_ROOT}/docker-compose.yml"
ALPINE_COMPOSE="${REPO_ROOT}/docker-compose-alpinekoha.yml"
ENV_FILE="${REPO_ROOT}/env/.env"

KOHA_INSTANCE="$(grep -E '^KOHA_INSTANCE=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
KOHA_INSTANCE="${KOHA_INSTANCE:-kohadev}"
DB_NAME="koha_${KOHA_INSTANCE}"
DB_PASS="$(grep -E '^KOHA_DB_ROOT_PASSWORD=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
DB_PASS="${DB_PASS:-password}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARTIFACT_DIR="${SCRIPT_DIR}/artifacts/integration-${STAMP}"
mkdir -p "${ARTIFACT_DIR}"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)]${RESET} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${RESET} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)]${RESET} $*"; }

legacy_compose() {
    docker compose -f "${LEGACY_COMPOSE}" --env-file "${ENV_FILE}" --project-directory "${REPO_ROOT}" "$@"
}

alpine_compose() {
    docker compose -f "${ALPINE_COMPOSE}" --env-file "${ENV_FILE}" --project-directory "${REPO_ROOT}" "$@"
}

wait_for_systempreferences() {
    local max_wait="${1:-420}"
    local elapsed=0

    while (( elapsed < max_wait )); do
        if legacy_compose exec -T db sh -lc "mysql -uroot -p\"${DB_PASS}\" -Nse \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}' AND table_name='systempreferences';\"" 2>/dev/null | grep -qx '1'; then
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    return 1
}

bootstrap_legacy_populated_db() {
    log "Preparing legacy stack with populated database for restart/authority tests"
    # Force non-ES bootstrap in this preparation phase so population is not
    # blocked by unavailable OpenSearch in local CI/dev environments.
    KOHA_ELASTICSEARCH=no legacy_compose up -d db memcached koha >/dev/null

    if wait_for_systempreferences 480; then
        ok "Legacy DB is populated (${DB_NAME}.systempreferences exists)"
    else
        err "Legacy DB was not populated in time"
        legacy_compose logs --tail=120 koha | sed 's/^/[legacy-koha] /' || true
        return 1
    fi
}

ensure_alpine_ready() {
    log "Preparing Alpine stack state for Alpine smoke test"
    alpine_compose up -d db memcached rabbitmq koha >/dev/null

    local max_wait=180
    local elapsed=0
    while (( elapsed < max_wait )); do
        if alpine_compose exec -T koha sh -lc 'test -f /ktd_ready' >/dev/null 2>&1; then
            ok "Alpine koha container reached /ktd_ready"
            return 0
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done

    err "Alpine koha container did not reach /ktd_ready in ${max_wait}s"
    return 1
}

TOTAL=0
FAILED=0
PASSED=0
SKIPPED=0

run_test() {
    local script="$1"
    local name
    local out_file
    local rc=0

    name="$(basename "${script}" .sh)"
    out_file="${ARTIFACT_DIR}/${name}.log"

    TOTAL=$(( TOTAL + 1 ))

    log "Running ${script}"
    set +e
    bash "${script}" >"${out_file}" 2>&1
    rc=$?
    set -e

    if [[ ${rc} -eq 0 ]]; then
        if grep -q '# SKIP' "${out_file}"; then
            SKIPPED=$(( SKIPPED + 1 ))
            warn "${name}: pass-with-skip (rc=${rc})"
        else
            PASSED=$(( PASSED + 1 ))
            ok "${name}: pass"
        fi
    else
        FAILED=$(( FAILED + 1 ))
        err "${name}: fail (rc=${rc})"
    fi

    echo "----- ${name} output -----"
    sed -n '1,80p' "${out_file}"
    echo "----- end ${name} -----"
    echo ""
}

main() {
    if ! command -v docker >/dev/null 2>&1; then
        err "docker not found"
        exit 2
    fi

    log "Integration artifacts directory: ${ARTIFACT_DIR}"

    # Phase 1: DB readiness race test (self-isolates with down -v)
    run_test "${SCRIPT_DIR}/test_mariadb_auth_readiness_integration.sh"

    # Phase 2: Populate legacy DB so restart + authority tests run deterministically
    bootstrap_legacy_populated_db || FAILED=$(( FAILED + 1 ))

    # Phase 3: Legacy integration tests that require populated DB
    run_test "${SCRIPT_DIR}/test_restart_integration.sh"
    run_test "${SCRIPT_DIR}/test_authority_groupby_sqlmode_integration.sh"

    # Phase 4: OpenSearch auth check (pass or pass-with-skip if cluster absent)
    run_test "${SCRIPT_DIR}/test_opensearch_os01_auth_integration.sh"

    # Phase 5: Re-align to Alpine runtime and run smoke checks
    ensure_alpine_ready || FAILED=$(( FAILED + 1 ))
    run_test "${SCRIPT_DIR}/test_alpine_startup_smoke.sh"

    echo ""
    echo "============================================================"
    echo "Integration summary"
    echo "  total tests:   ${TOTAL}"
    echo "  passed:        ${PASSED}"
    echo "  pass-with-skip:${SKIPPED}"
    echo "  failed:        ${FAILED}"
    echo "  artifacts:     ${ARTIFACT_DIR}"
    echo "============================================================"

    if [[ ${FAILED} -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
