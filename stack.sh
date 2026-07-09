#!/usr/bin/env bash
# stack.sh — Manage the full Koha ILS + OpenSearch 3.6 + MariaDB stack
#
# Usage: ./stack.sh <command> [options]
#   start     Build (if requested) and start the full stack (default)
#   stop      Stop all services gracefully
#   restart   Quick restart: reset DB + recreate Koha container (no OS restart)
#   status    Show running containers and OpenSearch cluster health
#   logs      Tail Koha container logs
#   build     Build images only (no start)
#   backup    Create a portable backup bundle for env files + MariaDB data
#   restore   Restore env files + MariaDB data from a backup bundle
#
# Run './stack.sh --help' for full usage.

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths — all derived from this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENSEARCH_DIR="${SCRIPT_DIR}/OpenSearch-3.6"
TRAEFIK_DIR="${SCRIPT_DIR}/traefik"
KOHA_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
KOHA_ENV_FILE="${SCRIPT_DIR}/env/.env"
KOHA_PROJECT_DIR="${SCRIPT_DIR}"
KOHA_DEFAULT_REPO_URL="https://git.koha-community.org/Koha-community/Koha.git"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

ts()   { date '+%H:%M:%S'; }
log()  { echo -e "${BLUE}[$(ts)]${RESET} $*"; }
ok()   { echo -e "${GREEN}[$(ts)] ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}[$(ts)] ⚠${RESET}  $*"; }
die()  { echo -e "${RED}[$(ts)] ✗  $*${RESET}" >&2; exit 1; }
hdr()  { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }

# ---------------------------------------------------------------------------
# Config — read from env files, with safe fallbacks
# ---------------------------------------------------------------------------
_env_val() {
  # Usage: _env_val FILE KEY [DEFAULT]
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^${key}=" "${file}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'" || true)
  echo "${val:-${default}}"
}

KOHA_INSTANCE="$(_env_val "${KOHA_ENV_FILE}" KOHA_INSTANCE kohadev)"
KOHA_DOMAIN="$(_env_val   "${KOHA_ENV_FILE}" KOHA_DOMAIN   .myDNSname.org)"
KOHA_INTRANET_SUFFIX="$(_env_val "${KOHA_ENV_FILE}" KOHA_INTRANET_SUFFIX -intra)"
KOHA_OPAC_PORT="$(_env_val      "${KOHA_ENV_FILE}" KOHA_OPAC_PORT      8080)"
KOHA_INTRANET_PORT="$(_env_val  "${KOHA_ENV_FILE}" KOHA_INTRANET_PORT  8081)"
KOHA_USER="$(_env_val "${KOHA_ENV_FILE}" KOHA_USER koha)"
KOHA_PASS="$(_env_val "${KOHA_ENV_FILE}" KOHA_PASS koha)"
KOHA_DB_ROOT_PASSWORD="$(_env_val "${KOHA_ENV_FILE}" KOHA_DB_ROOT_PASSWORD password)"
TRAEFIK_HTTP_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTP_PORT 80)"
TRAEFIK_HTTPS_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTPS_PORT 443)"
TRAEFIK_DASHBOARD_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_DASHBOARD_PORT 8083)"
ACME_EMAIL="$(_env_val "${TRAEFIK_DIR}/.env" ACME_EMAIL "")"
KOHA_ELASTICSEARCH="$(_env_val "${KOHA_ENV_FILE}" KOHA_ELASTICSEARCH no)"
# Admin password: prefer the OS .env file (source of truth for the cluster)
OS_ADMIN_PASS="$(_env_val "${OPENSEARCH_DIR}/.env" OPENSEARCH_INITIAL_ADMIN_PASSWORD \
  "$(_env_val "${KOHA_ENV_FILE}" OPENSEARCH_INITIAL_ADMIN_PASSWORD 'changeme')")"
KOHA_ELASTIC_OPTIONS="$(_env_val "${KOHA_ENV_FILE}" ELASTIC_OPTIONS "")"
DASHBOARDS_DOMAIN="$(_env_val "${OPENSEARCH_DIR}/.env" DASHBOARDS_DOMAIN "dashboards.localhost")"
TLS_CERTRESOLVER="$(_env_val "${KOHA_ENV_FILE}" TLS_CERTRESOLVER "")"
SYNC_REPO="$(_env_val "${KOHA_ENV_FILE}" SYNC_REPO "${SCRIPT_DIR}/koha")"
KOHA_GIT_URL="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_URL "${KOHA_DEFAULT_REPO_URL}")"
KOHA_GIT_CLONE_MODE="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_CLONE_MODE tag)"
KOHA_GIT_TAG="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_TAG "")"
KOHA_GIT_BRANCH="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_BRANCH main)"
KOHA_GIT_DEPTH="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_DEPTH 1)"

DB_NAME="koha_${KOHA_INSTANCE}"
DB_USER="koha_${KOHA_INSTANCE}"
KOHA_PROJECT="$(basename "${KOHA_PROJECT_DIR}")"   # → koha-docker
DB_CONTAINER="${KOHA_PROJECT}-db-1"
BACKUP_ROOT="${SCRIPT_DIR}/backups"

reload_runtime_config() {
  KOHA_INSTANCE="$(_env_val "${KOHA_ENV_FILE}" KOHA_INSTANCE "${KOHA_INSTANCE}")"
  KOHA_DOMAIN="$(_env_val "${KOHA_ENV_FILE}" KOHA_DOMAIN "${KOHA_DOMAIN}")"
  KOHA_INTRANET_SUFFIX="$(_env_val "${KOHA_ENV_FILE}" KOHA_INTRANET_SUFFIX "${KOHA_INTRANET_SUFFIX}")"
  KOHA_OPAC_PORT="$(_env_val "${KOHA_ENV_FILE}" KOHA_OPAC_PORT "${KOHA_OPAC_PORT}")"
  KOHA_INTRANET_PORT="$(_env_val "${KOHA_ENV_FILE}" KOHA_INTRANET_PORT "${KOHA_INTRANET_PORT}")"
  KOHA_USER="$(_env_val "${KOHA_ENV_FILE}" KOHA_USER "${KOHA_USER}")"
  KOHA_PASS="$(_env_val "${KOHA_ENV_FILE}" KOHA_PASS "${KOHA_PASS}")"
  KOHA_DB_ROOT_PASSWORD="$(_env_val "${KOHA_ENV_FILE}" KOHA_DB_ROOT_PASSWORD "${KOHA_DB_ROOT_PASSWORD}")"
  KOHA_ELASTICSEARCH="$(_env_val "${KOHA_ENV_FILE}" KOHA_ELASTICSEARCH "${KOHA_ELASTICSEARCH}")"
  KOHA_ELASTIC_OPTIONS="$(_env_val "${KOHA_ENV_FILE}" ELASTIC_OPTIONS "${KOHA_ELASTIC_OPTIONS}")"
  LOAD_DEMO_DATA="$(_env_val "${KOHA_ENV_FILE}" LOAD_DEMO_DATA "${LOAD_DEMO_DATA}")"
  SYNC_REPO="$(_env_val "${KOHA_ENV_FILE}" SYNC_REPO "${SYNC_REPO}")"
  KOHA_GIT_URL="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_URL "${KOHA_GIT_URL}")"
  KOHA_GIT_CLONE_MODE="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_CLONE_MODE "${KOHA_GIT_CLONE_MODE}")"
  KOHA_GIT_TAG="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_TAG "${KOHA_GIT_TAG}")"
  KOHA_GIT_BRANCH="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_BRANCH "${KOHA_GIT_BRANCH}")"
  KOHA_GIT_DEPTH="$(_env_val "${KOHA_ENV_FILE}" KOHA_GIT_DEPTH "${KOHA_GIT_DEPTH}")"
  TRAEFIK_HTTP_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTP_PORT "${TRAEFIK_HTTP_PORT}")"
  TRAEFIK_HTTPS_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTPS_PORT "${TRAEFIK_HTTPS_PORT}")"
  TRAEFIK_DASHBOARD_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_DASHBOARD_PORT "${TRAEFIK_DASHBOARD_PORT}")"
  ACME_EMAIL="$(_env_val "${TRAEFIK_DIR}/.env" ACME_EMAIL "${ACME_EMAIL}")"
  OS_ADMIN_PASS="$(_env_val "${OPENSEARCH_DIR}/.env" OPENSEARCH_INITIAL_ADMIN_PASSWORD "${OS_ADMIN_PASS}")"
  DASHBOARDS_DOMAIN="$(_env_val "${OPENSEARCH_DIR}/.env" DASHBOARDS_DOMAIN "${DASHBOARDS_DOMAIN}")"
  TLS_CERTRESOLVER="$(_env_val "${KOHA_ENV_FILE}" TLS_CERTRESOLVER "${TLS_CERTRESOLVER}")"
  DB_NAME="koha_${KOHA_INSTANCE}"
  DB_USER="koha_${KOHA_INSTANCE}"
}

# ---------------------------------------------------------------------------
# Compose wrappers
# ---------------------------------------------------------------------------
koha_compose() {
  docker compose \
    -f "${KOHA_COMPOSE_FILE}" \
    --env-file "${KOHA_ENV_FILE}" \
    --project-directory "${KOHA_PROJECT_DIR}" \
    "$@"
}

os_compose() {
  docker compose \
    -f "${OPENSEARCH_DIR}/docker-compose.yml" \
    --env-file "${OPENSEARCH_DIR}/.env" \
    --project-directory "${OPENSEARCH_DIR}" \
    "$@"
}

traefik_compose() {
  docker compose \
    -f "${TRAEFIK_DIR}/docker-compose.yaml" \
    --env-file "${TRAEFIK_DIR}/.env" \
    --project-directory "${TRAEFIK_DIR}" \
    "$@"
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prereqs() {
  log "Checking prerequisites..."
  command -v git      >/dev/null 2>&1 || die "git not found in PATH"
  command -v docker   >/dev/null 2>&1 || die "docker not found in PATH"
  docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start it first (for example: sudo systemctl start docker)."
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found"
  [[ -f "${KOHA_ENV_FILE}" ]] || die "env/.env not found — copy and configure it first"
  [[ -f "${OPENSEARCH_DIR}/docker-compose.yml" ]] \
    || die "OpenSearch-3.6/docker-compose.yml not found"
  [[ -f "${TRAEFIK_DIR}/docker-compose.yaml" ]] \
    || die "traefik/docker-compose.yaml not found"
  ok "Prerequisites OK"
}

ensure_koha_source() {
  hdr "Ensuring Koha source tree"

  local clone_mode repo_dir repo_parent resolved_tag
  clone_mode="$(echo "${KOHA_GIT_CLONE_MODE}" | tr '[:upper:]' '[:lower:]')"
  repo_dir="${SYNC_REPO}"

  [[ -n "${repo_dir}" ]] || die "SYNC_REPO is empty in env/.env"
  repo_parent="$(dirname "${repo_dir}")"
  mkdir -p "${repo_parent}"

  if [[ -d "${repo_dir}/.git" ]]; then
    ok "Koha source already present at ${repo_dir}"
    return 0
  fi

  if [[ -e "${repo_dir}" ]]; then
    die "SYNC_REPO path exists but is not a git repo: ${repo_dir}"
  fi

  if [[ ! "${KOHA_GIT_DEPTH}" =~ ^[1-9][0-9]*$ ]]; then
    die "KOHA_GIT_DEPTH must be a positive integer (current: '${KOHA_GIT_DEPTH}')"
  fi

  case "${clone_mode}" in
    tag)
      [[ -n "${KOHA_GIT_TAG}" ]] || die "KOHA_GIT_TAG is required when KOHA_GIT_CLONE_MODE=tag"
      resolved_tag="${KOHA_GIT_TAG}"
      if ! git ls-remote --tags --refs "${KOHA_GIT_URL}" "refs/tags/${resolved_tag}" | grep -q .; then
        if [[ "${resolved_tag}" != v* ]] && git ls-remote --tags --refs "${KOHA_GIT_URL}" "refs/tags/v${resolved_tag}" | grep -q .; then
          resolved_tag="v${resolved_tag}"
          warn "KOHA_GIT_TAG='${KOHA_GIT_TAG}' not found; using '${resolved_tag}' (v-prefixed upstream tag)."
        else
          die "Koha tag '${KOHA_GIT_TAG}' not found at ${KOHA_GIT_URL}"
        fi
      fi
      log "Cloning Koha tag '${resolved_tag}' into '${repo_dir}' (depth=${KOHA_GIT_DEPTH})..."
      git clone --branch "${resolved_tag}" --single-branch --depth "${KOHA_GIT_DEPTH}" "${KOHA_GIT_URL}" "${repo_dir}"
      ;;
    branch)
      [[ -n "${KOHA_GIT_BRANCH}" ]] || die "KOHA_GIT_BRANCH is required when KOHA_GIT_CLONE_MODE=branch"
      log "Cloning Koha branch '${KOHA_GIT_BRANCH}' into '${repo_dir}' (depth=${KOHA_GIT_DEPTH})..."
      git clone --branch "${KOHA_GIT_BRANCH}" --single-branch --depth "${KOHA_GIT_DEPTH}" "${KOHA_GIT_URL}" "${repo_dir}"
      ;;
    *)
      die "Invalid KOHA_GIT_CLONE_MODE='${KOHA_GIT_CLONE_MODE}'. Use 'tag' or 'branch'."
      ;;
  esac

  ok "Koha source prepared at ${repo_dir}"
}

# ---------------------------------------------------------------------------
# Docker network
# Create the frontend network. Used for the main Koha + Traefik paths.
ensure_frontend_network() {
  if ! docker network inspect frontend >/dev/null 2>&1; then
    log "Creating 'frontend' Docker network (required by Traefik)..."
    docker network create frontend
    ok "Network 'frontend' created."
  else
    ok "Network 'frontend' already exists."
  fi
}

# Ensure required external networks exist before starting any stack that references
# them. Used by the Koha and OpenSearch compose files.
ensure_extra_networks() {
  local net name
  for net in knonikl opensearch-36_osearch; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
      log "Creating '$net' Docker network..."
      docker network create "$net"
      ok "Network '$net' created."
    else
      ok "Network '$net' already exists."
    fi
  done
}

ensure_opensearch_certs() {
  hdr "Preparing OpenSearch certificates"

  local cert_dir="${OPENSEARCH_DIR}/assets/ssl"
  local generator="${OPENSEARCH_DIR}/opensearch_local_certificates_creator.sh"
  local config_file="${OPENSEARCH_DIR}/opensearch_installer_vars.cfg"
  local required_files=(
    root-ca.pem
    root-ca-key.pem
    admin.pem
    admin-key.pem
    os01.pem
    os01-key.pem
    os02.pem
    os02-key.pem
    os03.pem
    os03-key.pem
    os04.pem
    os04-key.pem
    os05.pem
    os05-key.pem
    dashboards.pem
    dashboards-key.pem
  )
  local file_path needs_regen=false

  [[ -f "${config_file}" ]] || die "Missing ${config_file}; OpenSearch certificates cannot be generated without it."
  mkdir -p "${cert_dir}"

  for file_name in "${required_files[@]}"; do
    file_path="${cert_dir}/${file_name}"
    if [[ -d "${file_path}" ]]; then
      warn "Removing directory at certificate path: ${file_path}"
      rm -rf "${file_path}"
      needs_regen=true
    elif [[ ! -f "${file_path}" ]]; then
      needs_regen=true
    fi
  done

  if [[ "${needs_regen}" == true ]]; then
    log "OpenSearch certs are missing or invalid; regenerating them now..."
    pushd "${OPENSEARCH_DIR}" > /dev/null
    bash ./opensearch_local_certificates_creator.sh
    popd > /dev/null
  else
    ok "OpenSearch certificates already present."
  fi

  for file_name in "${required_files[@]}"; do
    file_path="${cert_dir}/${file_name}"
    [[ -f "${file_path}" ]] || die "Expected OpenSearch certificate file missing or invalid: ${file_path}"
  done

  ok "OpenSearch certificates ready."
}

sync_koha_opensearch_credentials() {
  if [[ "${KOHA_ELASTICSEARCH}" != "yes" ]]; then
    return 0
  fi

  if [[ -z "${KOHA_ELASTIC_OPTIONS}" ]]; then
    warn "ELASTIC_OPTIONS is empty in env/.env; Koha may not be able to authenticate to OpenSearch."
    return 0
  fi

  ELASTIC_OPTIONS="$(OPENSEARCH_ADMIN_PASSWORD="${OS_ADMIN_PASS}" ELASTIC_OPTIONS="${KOHA_ELASTIC_OPTIONS}" python3 - <<'PY'
import os
import re

options = os.environ["ELASTIC_OPTIONS"]
password = os.environ["OPENSEARCH_ADMIN_PASSWORD"]
synced = re.sub(r'(<userinfo>admin:)[^<]*(</userinfo>)', r'\1' + password + r'\2', options, count=1)
print(synced)
PY
)"
  export OPENSEARCH_INITIAL_ADMIN_PASSWORD="${OS_ADMIN_PASS}"
  export ELASTIC_OPTIONS
  ok "Aligned Koha OpenSearch credentials with OpenSearch-3.6/.env."
}

ensure_opensearch_auth() {
  if [[ "${KOHA_ELASTICSEARCH}" != "yes" ]]; then
    return 0
  fi

  sync_koha_opensearch_credentials

  local auth_code
  auth_code="$(curl -ks -o /dev/null -w '%{http_code}' -u "admin:${OS_ADMIN_PASS}" \
    https://localhost:9200/_cluster/health?pretty || true)"

  if [[ "${auth_code}" == "200" ]]; then
    ok "OpenSearch auth probe succeeded (HTTP 200)."
    return 0
  fi

  if [[ "${auth_code}" == "401" ]]; then
    warn "OpenSearch returned HTTP 401. Reapplying security config and recreating os01..."
    pushd "${OPENSEARCH_DIR}" > /dev/null
    set -a
    source .env
    set +a
    bash ./initial_api_calls.sh
    docker compose up -d --force-recreate os01
    popd > /dev/null

    wait_opensearch_green

    auth_code="$(curl -ks -o /dev/null -w '%{http_code}' -u "admin:${OS_ADMIN_PASS}" \
      https://localhost:9200/_cluster/health?pretty || true)"
    [[ "${auth_code}" == "200" ]] || die "OpenSearch auth still returns HTTP ${auth_code} after security resync."
    ok "OpenSearch auth resynced and verified."
    return 0
  fi

  warn "OpenSearch auth probe returned HTTP ${auth_code}; continuing with current credentials."
}

# ---------------------------------------------------------------------------
# Traefik
# ---------------------------------------------------------------------------
start_traefik() {
  hdr "Starting Traefik reverse proxy"
  ensure_frontend_network
  # Bring up only if not already running
  if traefik_compose ps --status running traefik 2>/dev/null | grep -q traefik; then
    ok "Traefik is already running."
  else
    traefik_compose up -d traefik
    ok "Traefik started (HTTP :${TRAEFIK_HTTP_PORT}, dashboard :${TRAEFIK_DASHBOARD_PORT})."
  fi
}

stop_traefik() {
  hdr "Stopping Traefik"
  traefik_compose stop traefik 2>/dev/null || true
  ok "Traefik stopped."
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
build_opensearch() {
  local os_ver
  os_ver="$(_env_val "${OPENSEARCH_DIR}/.env" OPEN_SEARCH_VERSION 3.6.0)"
  hdr "Building OpenSearch image"
  log "Building single kosson/opensearch-icu:${os_ver} image with analysis-icu plugin..."
  pushd "${OPENSEARCH_DIR}" > /dev/null
  docker compose build os01
  popd > /dev/null
  ok "OpenSearch image built (kosson/opensearch-icu:${os_ver})."
}

build_koha() {
  hdr "Building Koha image"
  koha_compose build koha
  ok "Koha image built."
}

# ---------------------------------------------------------------------------
# OpenSearch
# ---------------------------------------------------------------------------
start_opensearch() {
  hdr "Starting OpenSearch 3.6 cluster"
  local os_ver os_img
  os_ver="$(_env_val "${OPENSEARCH_DIR}/.env" OPEN_SEARCH_VERSION 3.6.0)"
  os_img="kosson/opensearch-icu:${os_ver}"

  # Ensure first run works without Docker Hub access: build locally when missing.
  if ! docker image inspect "${os_img}" >/dev/null 2>&1; then
    log "Local image ${os_img} not found. Building it now (no Docker Hub login required)..."
    build_opensearch
  fi

  pushd "${OPENSEARCH_DIR}" > /dev/null
  # Start only core nodes first. dashboards depends_on os01:service_healthy;
  # starting everything at once can fail with "dependency os01 failed to start"
  # while the security plugin is still initializing.
  docker compose up -d os01 os02 os03 os04 os05
  popd > /dev/null
  ok "OpenSearch core nodes started (os01–os05)."
}

start_opensearch_dashboards() {
  hdr "Starting OpenSearch Dashboards"
  pushd "${OPENSEARCH_DIR}" > /dev/null
  docker compose up -d dashboards
  popd > /dev/null
  ok "OpenSearch Dashboards started."
}

wait_opensearch_green() {
  log "Waiting for OpenSearch cluster to reach green status..."
  warn "This may take up to 5 minutes on first start (security plugin initialises)."
  local attempts=0 max=72  # 6 minutes (72 × 5 s)
  while (( attempts < max )); do
    if curl -sk -u "admin:${OS_ADMIN_PASS}" \
        https://localhost:9200/_cluster/health 2>/dev/null \
        | grep -q '"status":"green"'; then
      echo ""
      ok "OpenSearch cluster is green."
      return 0
    fi
    (( ++attempts ))
    printf "\r  [%d/%d] waiting..." "${attempts}" "${max}"
    sleep 5
  done
  echo ""
  die "OpenSearch cluster did not reach green status after $(( max * 5 )) seconds."
}

stop_opensearch() {
  hdr "Stopping OpenSearch cluster"
  pushd "${OPENSEARCH_DIR}" > /dev/null
  docker compose down
  popd > /dev/null
  ok "OpenSearch stopped."
}

# ---------------------------------------------------------------------------
# MariaDB + Memcached
# ---------------------------------------------------------------------------
start_support_services() {
  hdr "Starting MariaDB + Memcached"
  ensure_extra_networks
  koha_compose up -d db memcached
  ok "Support services started."
}

wait_db_ready() {
  log "Waiting for MariaDB to accept connections..."
  local attempts=0 max=30  # 60 seconds
  while (( attempts < max )); do
    if docker exec "${DB_CONTAINER}" \
        mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
        --batch --skip-column-names -e 'SELECT 1;' >/dev/null 2>&1; then
      ok "MariaDB is ready."
      return 0
    fi
    (( ++attempts ))
    printf "\r  [%d/%d] waiting..." "${attempts}" "${max}"
    sleep 2
  done
  echo ""
  die "MariaDB did not become ready after $(( max * 2 )) seconds. Check KOHA_DB_ROOT_PASSWORD in env/.env. If koha-db-data already exists from an older password, run './stack.sh reset' (destructive) or restore the old password in env/.env."
}

reset_database() {
  hdr "Recreating Koha database"
  log "Dropping and recreating '${DB_NAME}'..."
  docker exec "${DB_CONTAINER}" mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" -e "
    DROP DATABASE IF EXISTS ${DB_NAME};
    CREATE DATABASE ${DB_NAME}
      CHARACTER SET utf8mb4
      COLLATE utf8mb4_unicode_ci;
    GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';
    FLUSH PRIVILEGES;" || die "MariaDB root authentication failed while recreating ${DB_NAME}. Verify KOHA_DB_ROOT_PASSWORD in env/.env matches the password used when the existing koha-db-data volume was first initialized."
  ok "Database '${DB_NAME}' ready."
}

create_backup_bundle() {
  hdr "Creating backup bundle"

  local output_path stage_dir timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  output_path="${BACKUP_OUTPUT:-${BACKUP_ROOT}/koha-backup-${timestamp}.tar.gz}"

  mkdir -p "${BACKUP_ROOT}" "$(dirname "${output_path}")"
  stage_dir="$(mktemp -d)"
  trap 'rm -rf "${stage_dir}"' RETURN

  start_support_services
  wait_db_ready

  mkdir -p "${stage_dir}/config" "${stage_dir}/database"
  cp "${KOHA_ENV_FILE}" "${stage_dir}/config/env.env"
  cp "${TRAEFIK_DIR}/.env" "${stage_dir}/config/traefik.env"
  cp "${OPENSEARCH_DIR}/.env" "${stage_dir}/config/opensearch.env"

  cat > "${stage_dir}/manifest.txt" <<EOF
created_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
repo_root=${SCRIPT_DIR}
koha_instance=${KOHA_INSTANCE}
database=${DB_NAME}
includes=env/.env, traefik/.env, OpenSearch-3.6/.env, database dump
EOF

  log "Dumping MariaDB database '${DB_NAME}'..."
  docker exec "${DB_CONTAINER}" \
    mysqldump -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
    --single-transaction --routines --triggers --events "${DB_NAME}" \
    | gzip -9 > "${stage_dir}/database/${DB_NAME}.sql.gz"

  log "Packing backup archive at ${output_path}..."
  tar -C "${stage_dir}" -czf "${output_path}" .

  rm -rf "${stage_dir}"
  trap - RETURN

  ok "Backup written to ${output_path}"
}

restore_backup_bundle() {
  hdr "Restoring backup bundle"

  local archive_path stage_dir
  [[ -n "${RESTORE_ARCHIVE}" ]] || die "restore requires a backup archive path. Use: ./stack.sh restore /path/to/koha-backup.tar.gz"
  archive_path="${RESTORE_ARCHIVE}"
  [[ -f "${archive_path}" ]] || die "Backup archive not found: ${archive_path}"

  warn "This will overwrite env/.env, traefik/.env and OpenSearch-3.6/.env, then recreate '${DB_NAME}'."
  warn "Any running containers should be stopped before restoring."
  echo ""
  read -rp "Type 'restore' to continue: " answer
  if [[ "${answer}" != "restore" ]]; then
    log "Restore cancelled."
    return 0
  fi

  stop_koha
  stop_support_services
  stop_opensearch
  stop_traefik

  stage_dir="$(mktemp -d)"
  trap 'rm -rf "${stage_dir}"' RETURN

  tar -xzf "${archive_path}" -C "${stage_dir}"

  [[ -f "${stage_dir}/config/env.env" ]] || die "Backup archive is missing config/env.env"
  [[ -f "${stage_dir}/config/traefik.env" ]] || die "Backup archive is missing config/traefik.env"
  [[ -f "${stage_dir}/config/opensearch.env" ]] || die "Backup archive is missing config/opensearch.env"

  cp "${stage_dir}/config/env.env" "${KOHA_ENV_FILE}"
  cp "${stage_dir}/config/traefik.env" "${TRAEFIK_DIR}/.env"
  cp "${stage_dir}/config/opensearch.env" "${OPENSEARCH_DIR}/.env"

  reload_runtime_config
  ensure_koha_source

  ok "Configuration files restored."

  start_support_services
  wait_db_ready
  reset_database

  if [[ -f "${stage_dir}/database/${DB_NAME}.sql.gz" ]]; then
    log "Importing MariaDB dump into '${DB_NAME}'..."
    gzip -dc "${stage_dir}/database/${DB_NAME}.sql.gz" | \
      docker exec -i "${DB_CONTAINER}" mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" "${DB_NAME}"
    ok "Database restored."
  else
    warn "No database dump found in the backup archive; the database was only reinitialized."
  fi

  ensure_opensearch_certs
  start_traefik
  start_opensearch
  wait_opensearch_green
  ensure_opensearch_auth
  start_opensearch_dashboards

  export USE_EXISTING_DB=yes
  start_koha

  rm -rf "${stage_dir}"
  trap - RETURN

  if [[ "${FOLLOW_LOGS}" == true ]]; then
    follow_logs
  fi

  ok "Restore complete. The stack has been brought back up."
}

stop_support_services() {
  hdr "Stopping MariaDB + Memcached"
  koha_compose stop db memcached 2>/dev/null || true
  ok "Support services stopped."
}

reset_all() {
  warn "This will stop ALL containers, remove them, and delete ALL named volumes."
  warn "Database data, OpenSearch indices, and Traefik state will be permanently lost."
  warn "Docker images will be preserved."
  echo ""
  read -rp "Type 'yes' to confirm: " answer
  if [[ "${answer}" != "yes" ]]; then
    log "Reset cancelled."
    return 0
  fi

  hdr "Removing Koha containers and volumes"
  koha_compose down --volumes 2>/dev/null || true
  ok "Koha stack removed."

  hdr "Removing OpenSearch containers and volumes"
  os_compose down --volumes 2>/dev/null || true
  ok "OpenSearch stack removed."

  hdr "Removing Traefik containers"
  # Traefik has no named volumes; --volumes is a no-op but included for consistency.
  traefik_compose down --volumes 2>/dev/null || true
  ok "Traefik removed."

  echo ""
  ok "Reset complete. All containers and volumes removed. Images are intact."
}

# ---------------------------------------------------------------------------
# Koha container
# ---------------------------------------------------------------------------
start_koha() {
  hdr "Starting Koha container"
  # Export LOAD_DEMO_DATA so Docker Compose picks it up via the environment: block
  # in docker-compose.yml, overriding whatever is in env/.env at this point.
  export LOAD_DEMO_DATA
  local demo_label; demo_label="$( [[ "${LOAD_DEMO_DATA}" == "no" ]] && echo "clean (no demo data)" || echo "with demo data" )"
  log "Demo data mode: ${demo_label}"
  koha_compose up -d --force-recreate koha
  ok "Koha container started (${demo_label})."
}

stop_koha() {
  hdr "Stopping Koha container"
  koha_compose stop koha 2>/dev/null || true
  ok "Koha container stopped."
}

follow_logs() {
  hdr "Koha startup logs"
  warn "Startup takes 5–15 minutes. Watching for key milestones..."
  warn "Press Ctrl-C at any time to detach — the stack will keep running."
  echo ""

  # Stream logs and annotate milestones on the fly
  koha_compose logs -f koha 2>&1 | while IFS= read -r line; do
    echo "${line}"
    case "${line}" in
      *"koha-testing-docker has started up"*)
        local proto="http"
        local port_suffix=""
        if [[ -n "${TLS_CERTRESOLVER}" ]]; then
          proto="https"
          [[ "${TRAEFIK_HTTPS_PORT}" != "443" ]] && port_suffix=":${TRAEFIK_HTTPS_PORT}"
        else
          [[ "${TRAEFIK_HTTP_PORT}" != "80" ]] && port_suffix=":${TRAEFIK_HTTP_PORT}"
        fi
        echo ""
        echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${GREEN}${BOLD}║   Stack fully started and ready!                         ║${RESET}"
        echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════╣${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}  Via Traefik (recommended):║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}    OPAC    : ${proto}://${KOHA_INSTANCE}${KOHA_DOMAIN}${port_suffix}║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}    Staff   : ${proto}://${KOHA_INSTANCE}${KOHA_INTRANET_SUFFIX}${KOHA_DOMAIN}${port_suffix}║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}  Direct (fallback, no DNS needed):║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}    OPAC    : http://localhost:${KOHA_OPAC_PORT}║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}    Staff   : http://localhost:${KOHA_INTRANET_PORT}║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}  Login     : ${KOHA_USER} / ${KOHA_PASS}║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}  Dashbrd   : ${proto}://${DASHBOARDS_DOMAIN}${port_suffix}║${RESET}"
        echo -e "${GREEN}${BOLD}║${RESET}  Traefik   : http://localhost:${TRAEFIK_DASHBOARD_PORT}║${RESET}"
        local demo_note; demo_note="$( [[ "${LOAD_DEMO_DATA:-yes}" == "no" ]] && echo "clean (no demo data)" || echo "with demo data" )"
        echo -e "${GREEN}${BOLD}║${RESET}  Catalogue : ${demo_note}║${RESET}"
        echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
  hdr "Container status"
  echo ""
  echo -e "${BOLD}── Koha stack ──────────────────────────────${RESET}"
  koha_compose ps 2>/dev/null || echo "  (not running)"
  echo ""
  echo -e "${BOLD}── OpenSearch cluster ──────────────────────${RESET}"
  os_compose ps 2>/dev/null || echo "  (not running)"
  echo ""
  echo -e "${BOLD}── OpenSearch health ───────────────────────${RESET}"
  local health
  health=$(curl -sk -u "admin:${OS_ADMIN_PASS}" \
    https://localhost:9200/_cluster/health 2>/dev/null || echo '{"error":"unreachable"}')
  echo "${health}" | python3 -m json.tool 2>/dev/null || echo "${health}"
  echo ""
  echo -e "${BOLD}── Traefik ──────────────────────────────────${RESET}"
  traefik_compose ps 2>/dev/null || echo "  (not running)"
  echo ""
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF

${BOLD}stack.sh${RESET} — Manage the Koha ILS + OpenSearch 3.6 + MariaDB stack

${BOLD}Usage:${RESET}
  $(basename "$0") <command> [options]

${BOLD}Commands:${RESET}
  start       Start the full stack (default when no command given)
  stop        Stop all services (OpenSearch + Koha stack)
  restart     Quick restart: reset DB + recreate Koha container only
              (skips OpenSearch restart — use when OS is already running)
  reset       Stop everything, remove all containers and named volumes
              (requires confirmation; images are preserved)
  status      Show running containers and OpenSearch cluster health
  logs        Tail Koha container logs
  build       Build images without starting anything
  backup      Create a tar.gz backup bundle for env files + MariaDB data
  restore     Restore env files + MariaDB data from a backup bundle

${BOLD}Options for 'start' and 'build':${RESET}
  --build-opensearch    Rebuild the kosson/opensearch-icu image (analysis-icu plugin)
  --build-koha          Rebuild the Koha dev container image
  --build               Rebuild both OpenSearch and Koha images
  --no-fresh-db         Skip the database drop/recreate (preserve existing data)
  --no-logs             Do not tail Koha startup logs after starting
  --with-demo-data      Load sample MARC records, items, and patron data (default)
  --no-demo-data        Start with an empty catalogue — superlibrarian account only

${BOLD}Koha source bootstrap (env/.env):${RESET}
  SYNC_REPO             Host path for Koha source (auto-cloned if missing)
  KOHA_GIT_CLONE_MODE   tag | branch
  KOHA_GIT_TAG          Required when clone mode is 'tag'
  KOHA_GIT_BRANCH       Required when clone mode is 'branch' (e.g. main)
  KOHA_GIT_DEPTH        Shallow clone depth (positive integer)
  KOHA_GIT_URL          Optional override for forks/mirrors

${BOLD}Examples:${RESET}
  $(basename "$0") start                    # Fresh DB + demo data, follow logs
  $(basename "$0") start --no-demo-data     # Fresh DB, clean catalogue (no sample records)
  $(basename "$0") start --with-demo-data   # Explicitly load demo data (same as default)
  $(basename "$0") start --build            # Rebuild all images, then start
  $(basename "$0") start --build-opensearch # Rebuild OS images only, then start
  $(basename "$0") start --no-fresh-db      # Restart without wiping the database
  $(basename "$0") start --no-logs          # Start without tailing logs
  $(basename "$0") restart                  # Quick restart (DB reset + koha only)
  $(basename "$0") restart --no-demo-data   # Quick restart, clean catalogue
  $(basename "$0") stop                     # Stop everything
  $(basename "$0") reset                    # Nuclear reset: remove all containers + volumes
  $(basename "$0") status                   # Check what's running
  $(basename "$0") logs                     # Attach to Koha logs
  $(basename "$0") build --build-opensearch # Build OS images only
  $(basename "$0") backup                   # Create a backup in ./backups
  $(basename "$0") backup --output /tmp/koha-backup.tar.gz
  $(basename "$0") restore backups/koha-backup-YYYYMMDDTHHMMSSZ.tar.gz

EOF
}

# ---------------------------------------------------------------------------
# Command dispatcher
# ---------------------------------------------------------------------------

# Default command
COMMAND="start"
BUILD_OPENSEARCH=false
BUILD_KOHA=false
FRESH_DB=true
FOLLOW_LOGS=true
BACKUP_OUTPUT=""
RESTORE_ARCHIVE=""
# Read LOAD_DEMO_DATA from env/.env (default 'yes'); --no-demo-data / --with-demo-data override
LOAD_DEMO_DATA="$(_env_val "${KOHA_ENV_FILE}" LOAD_DEMO_DATA yes)"

# Parse command (first positional arg)
if [[ $# -gt 0 ]]; then
  case "$1" in
    start|stop|restart|reset|status|logs|build|backup|restore) COMMAND="$1"; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) : ;;  # no subcommand given, use default "start"
    *) die "Unknown command: '$1'. Run '$(basename "$0") --help' for usage." ;;
  esac
fi

# Parse remaining options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-opensearch)  BUILD_OPENSEARCH=true ;;
    --build-koha)        BUILD_KOHA=true ;;
    --build)             BUILD_OPENSEARCH=true; BUILD_KOHA=true ;;
    --no-fresh-db)       FRESH_DB=false ;;
    --no-logs)           FOLLOW_LOGS=false ;;
    --no-demo-data)      LOAD_DEMO_DATA=no ;;
    --with-demo-data)    LOAD_DEMO_DATA=yes ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a file path"
      BACKUP_OUTPUT="$2"
      shift ;;
    --input)
      [[ $# -ge 2 ]] || die "--input requires a backup archive path"
      RESTORE_ARCHIVE="$2"
      shift ;;
    --help|-h)           usage; exit 0 ;;
    *)
      if [[ "${COMMAND}" == "restore" && -z "${RESTORE_ARCHIVE}" ]]; then
        RESTORE_ARCHIVE="$1"
      else
        die "Unknown option: '$1'. Run '$(basename "$0") --help' for usage."
      fi
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

echo ""
echo -e "${BOLD}${CYAN}╔════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║   Koha + OpenSearch Stack Manager  ║${RESET}"
echo -e "${BOLD}${CYAN}╚════════════════════════════════════╝${RESET}"
echo ""

case "${COMMAND}" in

  start)
    check_prereqs
    ensure_koha_source
    [[ "${BUILD_OPENSEARCH}" == true ]] && build_opensearch
    [[ "${BUILD_KOHA}"       == true ]] && build_koha
    ensure_opensearch_certs
    start_traefik
    start_opensearch
    wait_opensearch_green
    ensure_opensearch_auth
    start_opensearch_dashboards
    start_support_services
    wait_db_ready
    if [[ "${FRESH_DB}" == true ]]; then
      # Warn the user if the database already contains Koha data — an accidental
      # plain 'start' after a machine reboot would silently wipe everything.
      _existing=$(docker exec "${DB_CONTAINER}" mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
          --batch --skip-column-names \
          -e "SELECT IF(
                (SELECT COUNT(*) FROM information_schema.tables
                 WHERE table_schema = '${DB_NAME}'
                 AND table_name = 'systempreferences') > 0,
              'yes', 'no');" 2>/dev/null || echo "no")
      if [[ "${_existing}" == "yes" ]]; then
        echo ""
        warn "Database '${DB_NAME}' already contains Koha data."
        warn "Proceeding will DROP and recreate it — ALL DATA WILL BE PERMANENTLY LOST."
        warn "To resume without wiping, press n and run:  ./stack.sh start --no-fresh-db"
        echo ""
        read -rp "$(echo -e "${RED}Type 'yes' to wipe the database and continue, or anything else to cancel:${RESET} ")" _confirm
        echo ""
        if [[ "${_confirm}" != "yes" ]]; then
          log "Start cancelled. Resume with existing data: ./stack.sh start --no-fresh-db"
          exit 0
        fi
      fi
      unset _existing
      reset_database
    else
      # Tell run.sh the DB already has data — skip the probe and the fresh-install
      # path in do_all_you_can_do.pl.  Docker Compose picks this up via the
      # environment: section in docker-compose.yml (USE_EXISTING_DB: ${USE_EXISTING_DB}).
      export USE_EXISTING_DB=yes
      log "--no-fresh-db: USE_EXISTING_DB=yes exported to Koha container"
    fi
    start_koha
    echo ""
    log "Koha container is running and initialising."
    [[ "${FOLLOW_LOGS}" == true ]] && follow_logs
    ;;

  stop)
    stop_koha
    stop_support_services
    stop_opensearch
    stop_traefik
    ok "All services stopped."
    ;;

  reset)
    reset_all
    ;;

  restart)
    check_prereqs
    ensure_koha_source
    hdr "Quick restart (OpenSearch stays up)"
    warn "Assumes OpenSearch cluster is already running and green."
    wait_db_ready
    [[ "${FRESH_DB}" == true ]] && reset_database
    start_koha
    [[ "${FOLLOW_LOGS}" == true ]] && follow_logs
    ;;

  status)
    show_status
    ;;

  logs)
    follow_logs
    ;;

  build)
    check_prereqs
    if [[ "${BUILD_OPENSEARCH}" == false && "${BUILD_KOHA}" == false ]]; then
      # No specific target → build everything
      BUILD_OPENSEARCH=true; BUILD_KOHA=true
    fi
    [[ "${BUILD_KOHA}" == true ]] && ensure_koha_source
    [[ "${BUILD_OPENSEARCH}" == true ]] && build_opensearch
    [[ "${BUILD_KOHA}"       == true ]] && build_koha
    ok "Build complete."
    ;;

  backup)
    check_prereqs
    create_backup_bundle
    ;;

  restore)
    check_prereqs
    restore_backup_bundle
    ;;

esac

exit 0
