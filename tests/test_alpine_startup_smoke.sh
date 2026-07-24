#!/usr/bin/env bash
# tests/test_alpine_startup_smoke.sh
#
# Alpine Koha startup smoke test:
# - verifies locale/timezone runtime prerequisites
# - verifies web runtime is active
# - verifies OPAC/Intranet endpoints are reachable and not 5xx
# - prints compact diagnostics on failure
#
# Usage:
#   cd koha-docker
#   bash tests/test_alpine_startup_smoke.sh
#
# Exit code: 0 = pass, 1 = fail, 2 = prerequisites missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose-alpinekoha.yml"
MAX_WAIT=${MAX_WAIT:-90}

PASS=0
FAIL=0
_N=0

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

compose() {
    docker compose -f "${COMPOSE_FILE}" "$@"
}

echo "TAP version 14"
echo "# Alpine startup smoke test (locale/tz/http)"
echo ""

if ! command -v docker >/dev/null 2>&1; then
    echo "Bail out! docker not found"
    exit 2
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo "Bail out! compose file not found: ${COMPOSE_FILE}"
    exit 2
fi

if ! compose ps --status running koha 2>/dev/null | grep -q "running\|Up"; then
    echo "Bail out! koha service is not running. Start it first with docker compose -f docker-compose-alpinekoha.yml up -d"
    exit 2
fi

ok "koha service is running"

elapsed=0
ready=false
while (( elapsed < MAX_WAIT )); do
    if compose exec -T koha sh -lc 'test -f /ktd_ready'; then
        ready=true
        break
    fi
    sleep 3
    elapsed=$(( elapsed + 3 ))
done

if [[ "${ready}" == true ]]; then
    ok "startup ready marker /ktd_ready present"
else
    not_ok "startup ready marker /ktd_ready present within ${MAX_WAIT}s"
fi

if compose exec -T koha sh -lc 'command -v locale >/dev/null 2>&1'; then
    ok "locale binary is available in container"
else
    not_ok "locale binary is available in container"
fi

if compose exec -T koha sh -lc 'test -f /usr/share/zoneinfo/UTC'; then
    ok "timezone data exists (/usr/share/zoneinfo/UTC)"
else
    not_ok "timezone data exists (/usr/share/zoneinfo/UTC)"
fi

if compose exec -T koha sh -lc '
    ps -o pid,args | grep -E "[h]ttpd( |$)|[a]pache2( |$)" >/dev/null \
    || curl -s -o /dev/null --max-time 2 http://127.0.0.1:8080 \
    || curl -s -o /dev/null --max-time 2 http://127.0.0.1:8081
'; then
    ok "web runtime is active (httpd process or local HTTP response)"
else
    not_ok "web runtime is active (httpd process or local HTTP response)"
fi

opac_code="$(compose exec -T koha sh -lc 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080 || true')"
intra_code="$(compose exec -T koha sh -lc 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8081 || true')"

if [[ "${opac_code}" =~ ^[0-9]{3}$ ]] && (( opac_code >= 200 && opac_code < 500 )); then
    ok "OPAC endpoint is reachable (HTTP ${opac_code})"
else
    not_ok "OPAC endpoint is reachable (HTTP ${opac_code:-n/a})"
fi

if [[ "${intra_code}" =~ ^[0-9]{3}$ ]] && (( intra_code >= 200 && intra_code < 500 )); then
    ok "Intranet endpoint is reachable (HTTP ${intra_code})"
else
    not_ok "Intranet endpoint is reachable (HTTP ${intra_code:-n/a})"
fi

if [[ ${FAIL} -gt 0 ]]; then
    echo "# diagnostics: recent koha logs"
    compose logs --tail=80 koha | sed 's/^/# /'
    echo "# diagnostics: opac/intranet error logs"
    compose exec -T koha sh -lc 'tail -n 60 /var/log/koha/kohadev/opac-error.log 2>/dev/null; echo "---"; tail -n 60 /var/log/koha/kohadev/intranet-error.log 2>/dev/null' | sed 's/^/# /'
fi

echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
