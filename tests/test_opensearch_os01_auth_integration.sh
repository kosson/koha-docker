#!/usr/bin/env bash
# tests/test_opensearch_os01_auth_integration.sh
#
# Integration test for OpenSearch os01 health authentication.
# It verifies that OPENSEARCH_INITIAL_ADMIN_PASSWORD from OpenSearch-3.6/.env
# can successfully authenticate against os01's HTTPS API.
#
# Exit code: 0 = pass/skip, 1 = fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OS_DIR="${REPO_ROOT}/OpenSearch-3.6"
OS_ENV_FILE="${OS_DIR}/.env"

PASS=0; FAIL=0; _N=0
ok()     { _N=$(( _N + 1 )); echo "ok ${_N} - $1"; PASS=$(( PASS + 1 )); }
not_ok() { _N=$(( _N + 1 )); echo "not ok ${_N} - $1"; FAIL=$(( FAIL + 1 )); }
skip()   { _N=$(( _N + 1 )); echo "ok ${_N} - $1 # SKIP $2"; }

compose() {
    docker compose -f "${OS_DIR}/docker-compose.yml" --env-file "${OS_ENV_FILE}" "$@"
}

echo "TAP version 14"
echo "# OpenSearch os01 auth integration check"
echo ""

if ! command -v docker >/dev/null 2>&1; then
    skip "Docker available" "docker not installed"
    echo ""
    echo "1..${_N}"
    echo "# Passed: ${PASS}  Failed: ${FAIL}"
    exit 0
fi
ok "Docker available"

if [[ ! -f "${OS_ENV_FILE}" ]]; then
    not_ok "OpenSearch .env exists at ${OS_ENV_FILE}"
    echo ""
    echo "1..${_N}"
    echo "# Passed: ${PASS}  Failed: ${FAIL}"
    exit 1
fi
ok "OpenSearch .env exists"

if ! compose ps os01 2>/dev/null | grep -q '^os01'; then
    skip "os01 container exists" "OpenSearch stack is not running (start with: cd OpenSearch-3.6 && docker compose up -d os01 os02 os03 os04 os05)"
    echo ""
    echo "1..${_N}"
    echo "# Passed: ${PASS}  Failed: ${FAIL}"
    exit 0
fi
ok "os01 container exists"

ADMIN_PASS="$(grep -E '^OPENSEARCH_INITIAL_ADMIN_PASSWORD=' "${OS_ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '\"' | tr -d "'")"
if [[ -z "${ADMIN_PASS}" ]]; then
    not_ok "OPENSEARCH_INITIAL_ADMIN_PASSWORD is set in OpenSearch-3.6/.env"
    echo ""
    echo "1..${_N}"
    echo "# Passed: ${PASS}  Failed: ${FAIL}"
    exit 1
fi
ok "OPENSEARCH_INITIAL_ADMIN_PASSWORD is set"

code_env="$(curl -ks -o /dev/null -w '%{http_code}' -u "admin:${ADMIN_PASS}" https://localhost:9200/_cat/nodes?pretty || true)"
if [[ "${code_env}" == "200" ]]; then
    ok "os01 auth succeeds with OPENSEARCH_INITIAL_ADMIN_PASSWORD"
else
    not_ok "os01 auth succeeds with OPENSEARCH_INITIAL_ADMIN_PASSWORD (HTTP ${code_env})"

    code_admin="$(curl -ks -o /dev/null -w '%{http_code}' -u 'admin:admin' https://localhost:9200/_cat/nodes?pretty || true)"
    if [[ "${code_admin}" == "200" ]]; then
        not_ok "password mismatch detected: admin:admin works while .env password fails"
    else
        skip "fallback admin:admin probe" "admin:admin did not authenticate; issue may be unrelated to hash drift"
    fi
fi

echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
