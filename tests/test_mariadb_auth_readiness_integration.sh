#!/usr/bin/env bash
# tests/test_mariadb_auth_readiness_integration.sh
#
# Integration test: detects MariaDB readiness race where mysqladmin ping can
# succeed before root auth is actually usable on a fresh volume initialization.
#
# Exit code: 0 = pass, 1 = fail, 2 = prerequisites not met.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
ENV_FILE="${REPO_ROOT}/env/.env"
DB_CONTAINER="$(basename "${REPO_ROOT}")-db-1"
MAX_WAIT=${MAX_WAIT:-120}

PASS=0; FAIL=0; _N=0
ok()     { _N=$(( _N + 1 )); echo "ok ${_N} - $1"; PASS=$(( PASS + 1 )); }
not_ok() { _N=$(( _N + 1 )); echo "not ok ${_N} - $1"; FAIL=$(( FAIL + 1 )); }
skip()   { _N=$(( _N + 1 )); echo "ok ${_N} - $1 # SKIP $2"; }

compose() {
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --project-directory "${REPO_ROOT}" "$@"
}

echo "TAP version 14"
echo "# MariaDB auth readiness integration check"
echo ""

if ! command -v docker >/dev/null 2>&1; then
  echo "Bail out! docker not found"
  exit 2
fi

if [[ ! -f "${COMPOSE_FILE}" || ! -f "${ENV_FILE}" ]]; then
  echo "Bail out! compose or env file not found"
  exit 2
fi

DB_PASS="$(grep -E '^KOHA_DB_ROOT_PASSWORD=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
if [[ -z "${DB_PASS}" ]]; then
  echo "Bail out! KOHA_DB_ROOT_PASSWORD is empty in env/.env"
  exit 2
fi
ok "KOHA_DB_ROOT_PASSWORD is set"

# Force fresh DB init for deterministic race detection.
compose down -v >/dev/null 2>&1 || true
compose up -d db >/dev/null
ok "DB container started with fresh volume"

ping_at=-1
auth_at=-1
elapsed=0
while (( elapsed < MAX_WAIT )); do
  if (( ping_at < 0 )); then
    if docker exec "${DB_CONTAINER}" mysqladmin ping -uroot -p"${DB_PASS}" --silent >/dev/null 2>&1; then
      ping_at=${elapsed}
    fi
  fi

  if (( auth_at < 0 )); then
    if docker exec "${DB_CONTAINER}" mysql -uroot -p"${DB_PASS}" -e 'SELECT 1;' >/dev/null 2>&1; then
      auth_at=${elapsed}
    fi
  fi

  if (( ping_at >= 0 && auth_at >= 0 )); then
    break
  fi

  sleep 1
  elapsed=$(( elapsed + 1 ))
done

if (( ping_at < 0 )); then
  not_ok "mysqladmin ping succeeds within ${MAX_WAIT}s"
else
  ok "mysqladmin ping succeeds within ${MAX_WAIT}s"
fi

if (( auth_at < 0 )); then
  not_ok "authenticated SQL query succeeds within ${MAX_WAIT}s"
else
  ok "authenticated SQL query succeeds within ${MAX_WAIT}s"
fi

if (( ping_at >= 0 && auth_at >= 0 )); then
  if (( ping_at < auth_at )); then
    ok "race detected: ping became ready ${auth_at-ping_at}s before auth (source of intermittent ERROR 1045)"
  else
    ok "no race observed in this run (auth readiness not behind ping)"
  fi
fi

echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
