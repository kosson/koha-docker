#!/usr/bin/env bash
# Bring OpenSearch-3.6 up from zero, then validate cluster/auth state.
#
# Flow:
# 1) Clean reset (containers/networks for this project + bind data + certs + local image tag)
# 2) Regenerate certs and internal user hashes
# 3) Rebuild image
# 4) Start os01-os05
# 5) Validate health/auth; auto-apply initial_api_calls.sh if auth drift is detected
# 6) Start dashboards
# 7) Run end-of-flow tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

OS_ENV_FILE="${SCRIPT_DIR}/.env"
AUTH_TEST_SCRIPT="${SCRIPT_DIR}/../tests/test_opensearch_os01_auth_integration.sh"
DATA_ROOT_DIR="${SCRIPT_DIR}/assets/opensearch/data"
NODE_DATA_DIRS=(
    "${DATA_ROOT_DIR}/os01data"
    "${DATA_ROOT_DIR}/os02data"
    "${DATA_ROOT_DIR}/os03data"
    "${DATA_ROOT_DIR}/os04data"
    "${DATA_ROOT_DIR}/os05data"
)

log() {
    printf '[raise-from-ground-up] %s\n' "$*"
}

die() {
    printf '[raise-from-ground-up] ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

prepare_node_data_dirs() {
    local dir
    for dir in "${NODE_DATA_DIRS[@]}"; do
        mkdir -p "${dir}"
    done
}

fix_node_data_permissions() {
    local image_tag
    image_tag="kosson/opensearch-icu:${OPEN_SEARCH_VERSION:-3.6.0}"

    prepare_node_data_dirs

    # Use a root process in the freshly built OpenSearch image to ensure bind mounts
    # are writable by the runtime user (uid:gid 1000:1000) on all hosts.
    docker run --rm --user 0 \
        -v "${DATA_ROOT_DIR}:/data" \
        "${image_tag}" \
        bash -lc 'chown -R 1000:1000 /data && chmod -R u+rwX,g+rwX,o-rwx /data'
}

wait_for_os01_healthy() {
    local timeout_s="${1:-300}"
    local start now elapsed status
    start="$(date +%s)"

    while true; do
        status="$(docker inspect os01 --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
        if [[ "${status}" == "healthy" ]]; then
            log "os01 is healthy."
            return 0
        fi

        if docker logs --tail 120 os01 2>/dev/null | grep -q 'AccessDeniedException: /usr/share/opensearch/data/nodes'; then
            docker compose ps os01 || true
            die "os01 cannot write to bind-mounted data path (/usr/share/opensearch/data). Check ownership/permissions of assets/opensearch/data/os0{1..5}data."
        fi

        now="$(date +%s)"
        elapsed=$(( now - start ))
        if (( elapsed >= timeout_s )); then
            docker compose ps os01 || true
            docker logs --tail 120 os01 || true
            die "Timed out waiting for os01 to become healthy (${timeout_s}s)."
        fi
        sleep 5
    done
}

wait_for_http_200_with_admin() {
    local timeout_s="${1:-180}"
    local start now elapsed code
    start="$(date +%s)"

    while true; do
        code="$(curl -ks -o /dev/null -w '%{http_code}' -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" \
            https://localhost:9200/_cat/nodes?pretty || true)"
        if [[ "${code}" == "200" ]]; then
            log "Admin auth probe succeeded (HTTP 200)."
            return 0
        fi

        now="$(date +%s)"
        elapsed=$(( now - start ))
        if (( elapsed >= timeout_s )); then
            die "Admin auth probe did not reach HTTP 200 within ${timeout_s}s (last HTTP ${code})."
        fi
        sleep 3
    done
}

require_cmd docker
require_cmd curl
require_cmd bash

[[ -f "${OS_ENV_FILE}" ]] || die "Missing ${OS_ENV_FILE}. Create/configure it before running this script."

set -a
# shellcheck disable=SC1091
source "${OS_ENV_FILE}"
set +a

[[ -n "${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}" ]] || die "OPENSEARCH_INITIAL_ADMIN_PASSWORD is not set in ${OS_ENV_FILE}."

log "Step 1/8: Reset OpenSearch project to zero state..."
bash ./restart-to-clear-cluster.sh

log "Step 2/8: Regenerate OpenSearch certs and internal user hashes..."
bash ./opensearch_local_certificates_creator.sh

log "Step 3/8: Build os01 image (shared by os01-os05)..."
docker compose build os01

log "Step 3b/8: Ensure bind-mounted node data dirs are writable by uid 1000..."
fix_node_data_permissions

log "Step 4/8: Start OpenSearch nodes os01-os05..."
docker compose up -d os01 os02 os03 os04 os05

log "Step 5/8: Wait for os01 healthcheck to pass..."
wait_for_os01_healthy 360

log "Step 6/8: Validate auth and auto-heal live security state if needed..."
auth_code="$(curl -ks -o /dev/null -w '%{http_code}' -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" \
    https://localhost:9200/_cat/nodes?pretty || true)"

if [[ "${auth_code}" != "200" ]]; then
    log "Auth returned HTTP ${auth_code}; applying initial_api_calls.sh then recreating os01..."
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    bash ./initial_api_calls.sh
    docker compose up -d --force-recreate os01
    wait_for_os01_healthy 240
    wait_for_http_200_with_admin 180
else
    log "Auth already healthy with .env admin password (HTTP 200)."
fi

log "Step 7/8: Start dashboards after node/auth validation..."
docker compose up -d dashboards

log "Step 8/8: Run final checks and tests..."

# Check 1: compose status snapshot
if ! docker compose ps os01 os02 os03 os04 os05 dashboards; then
    die "docker compose ps failed."
fi

# Check 2: cluster node count
node_count="$(curl -ks -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" https://localhost:9200/_cluster/health?pretty \
    | grep -o '"number_of_nodes"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*' | head -1)"
[[ "${node_count:-}" == "5" ]] || die "Expected number_of_nodes=5, got '${node_count:-unknown}'."

# Check 3: cluster status
cluster_status="$(curl -ks -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" https://localhost:9200/_cluster/health?pretty \
    | grep -o '"status"[[:space:]]*:[[:space:]]*"[a-z]*"' | cut -d'"' -f4 | head -1)"
if [[ "${cluster_status}" != "green" && "${cluster_status}" != "yellow" ]]; then
    die "Unexpected cluster status '${cluster_status:-unknown}'."
fi

# Check 4: existing auth integration test
if [[ -x "${AUTH_TEST_SCRIPT}" || -f "${AUTH_TEST_SCRIPT}" ]]; then
    bash "${AUTH_TEST_SCRIPT}"
else
    die "Missing auth test script at ${AUTH_TEST_SCRIPT}."
fi

log "SUCCESS: OpenSearch cluster raised from zero and validation tests passed."
log "Cluster status=${cluster_status}, nodes=${node_count}"
