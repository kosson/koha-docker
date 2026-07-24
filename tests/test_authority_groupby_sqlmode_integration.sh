#!/usr/bin/env bash
# tests/test_authority_groupby_sqlmode_integration.sh
#
# Integration guard for Koha authority-type GROUP BY behavior under SQL modes.
# This test does not modify Koha source code.
#
# Exit code: 0 = pass, 1 = fail, 2 = prerequisites not met.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
ENV_FILE="${REPO_ROOT}/env/.env"
DB_CONTAINER="$(basename "${REPO_ROOT}")-db-1"
KOHA_CONTAINER="$(basename "${REPO_ROOT}")-koha-1"
KOHA_INSTANCE="$(grep -E '^KOHA_INSTANCE=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true)"
KOHA_INSTANCE="${KOHA_INSTANCE:-kohadev}"

PASS=0; FAIL=0; _N=0
ok()     { _N=$(( _N + 1 )); echo "ok ${_N} - $1"; PASS=$(( PASS + 1 )); }
not_ok() { _N=$(( _N + 1 )); echo "not ok ${_N} - $1"; FAIL=$(( FAIL + 1 )); }
skip()   { _N=$(( _N + 1 )); echo "ok ${_N} - $1 # SKIP $2"; }

compose() {
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" --project-directory "${REPO_ROOT}" "$@"
}

echo "TAP version 14"
echo "# Authority GROUP BY / SQL mode integration guard"
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

# Ensure DB is available for the query checks.
compose up -d db >/dev/null
ok "DB service is up"

QUERY="select count(*),auth_tag_structure.authtypecode,authtypetext from auth_tag_structure,auth_types where auth_types.authtypecode=auth_tag_structure.authtypecode group by auth_tag_structure.authtypecode"
STRICT_MODE="ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
NON_STRICT_MODE="IGNORE_SPACE,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"

# 1) Strict mode must fail with this legacy query shape.
if docker exec "${DB_CONTAINER}" sh -lc \
  "mysql -uroot -p\"${DB_PASS}\" koha_kohadev -Nse \"SET SESSION sql_mode='${STRICT_MODE}'; ${QUERY};\"" \
  >/tmp/authority_groupby_strict.out 2>/tmp/authority_groupby_strict.err; then
  not_ok "Legacy authority query should fail under ONLY_FULL_GROUP_BY"
else
  if grep -q "isn't in GROUP BY" /tmp/authority_groupby_strict.err; then
    ok "Legacy authority query fails under ONLY_FULL_GROUP_BY (expected)"
  else
    not_ok "Strict mode failed, but not with expected GROUP BY diagnostic"
  fi
fi

# 2) Non-strict mode must pass without source modifications.
if docker exec "${DB_CONTAINER}" sh -lc \
  "mysql -uroot -p\"${DB_PASS}\" koha_kohadev -Nse \"SET SESSION sql_mode='${NON_STRICT_MODE}'; ${QUERY};\"" \
  >/tmp/authority_groupby_nonstrict.out 2>/tmp/authority_groupby_nonstrict.err; then
  ok "Legacy authority query succeeds under non-strict app mode"
else
  not_ok "Legacy authority query should succeed under non-strict app mode"
fi

# 3) Stack template should keep strict_sql_modes disabled to avoid runtime regression.
if grep -q '<strict_sql_modes>0</strict_sql_modes>' "${REPO_ROOT}/files/templates/koha-conf-site.xml.in"; then
  ok "koha-conf template has strict_sql_modes disabled"
else
  not_ok "koha-conf template should set strict_sql_modes to 0"
fi

# 4) If koha container is running, verify live instance config too.
if docker ps --format '{{.Names}}' | grep -qx "${KOHA_CONTAINER}"; then
  live_conf="/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
  max_wait=180
  elapsed=0
  while (( elapsed < max_wait )); do
    if docker exec "${KOHA_CONTAINER}" sh -lc "test -f '${live_conf}'" >/dev/null 2>&1; then
      break
    fi
    sleep 3
    elapsed=$(( elapsed + 3 ))
  done

  if docker exec "${KOHA_CONTAINER}" sh -lc "test -f '${live_conf}'" >/dev/null 2>&1; then
    if docker exec "${KOHA_CONTAINER}" sh -lc "grep -q '<strict_sql_modes>0</strict_sql_modes>' '${live_conf}'"; then
      ok "live koha instance config has strict_sql_modes disabled"
    else
      not_ok "live koha instance config should set strict_sql_modes to 0"
    fi
  else
    skip "live koha instance config check" "koha-conf.xml not generated yet after ${max_wait}s"
  fi
else
  skip "live koha instance config check" "koha container is not running"
fi

echo ""
echo "1..${_N}"
echo "# Passed: ${PASS}  Failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
