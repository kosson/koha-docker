#!/usr/bin/env bash
# netcheck.sh — Network connectivity diagnostic for the Koha Docker stack
#
# Tests every connection path in the stack:
#   host → OpenSearch        host → Traefik        host → Koha (direct)
#   host → MariaDB ping      host → Dashboards
#   Koha → OpenSearch        Koha → MariaDB        Koha → Memcached
#   Traefik routing labels   DNS / nip.io resolution
#
# Usage:
#   cd koha-docker
#   bash netcheck.sh
#
# Exit code: 0 = all checks passed, 1 = one or more failures.

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KOHA_ENV_FILE="${SCRIPT_DIR}/env/.env"
OS_ENV_FILE="${SCRIPT_DIR}/OpenSearch-3.6/.env"
TRAEFIK_ENV_FILE="${SCRIPT_DIR}/traefik/.env"
OS_SSL_DIR="${SCRIPT_DIR}/OpenSearch-3.6/assets/ssl"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

ts()  { date '+%H:%M:%S'; }
hdr() { echo -e "\n${BOLD}${CYAN}════════════════════════════════════════${RESET}"; \
        echo -e "${BOLD}${CYAN}  $*${RESET}"; \
        echo -e "${BOLD}${CYAN}════════════════════════════════════════${RESET}"; }

# ---------------------------------------------------------------------------
# Result tracking
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
declare -a FAILURES=()
declare -a WARNINGS=()

pass() { echo -e "  ${GREEN}✓  PASS${RESET}  $*"; (( ++PASS_COUNT )); }
fail() { echo -e "  ${RED}✗  FAIL${RESET}  $*"; (( ++FAIL_COUNT )); FAILURES+=("$*"); }
warn() { echo -e "  ${YELLOW}⚠  WARN${RESET}  $*"; (( ++WARN_COUNT )); WARNINGS+=("$*"); }
info() { echo -e "  ${BLUE}ℹ  INFO${RESET}  $*"; }

# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------
_env_val() {
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^${key}=" "${file}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'" || true)
  echo "${val:-${default}}"
}

# Load config — fall back to defaults if env files are missing
if [[ -f "${KOHA_ENV_FILE}" ]]; then
  KOHA_INSTANCE="$(_env_val  "${KOHA_ENV_FILE}" KOHA_INSTANCE     kohadev)"
  KOHA_DOMAIN="$(_env_val    "${KOHA_ENV_FILE}" KOHA_DOMAIN       .myDNSname.org)"
  KOHA_INTRANET_SUFFIX="$(_env_val "${KOHA_ENV_FILE}" KOHA_INTRANET_SUFFIX -intra)"
  KOHA_OPAC_PORT="$(_env_val "${KOHA_ENV_FILE}" KOHA_OPAC_PORT    8080)"
  KOHA_INTRANET_PORT="$(_env_val "${KOHA_ENV_FILE}" KOHA_INTRANET_PORT 8081)"
  KOHA_DB_PASS="$(_env_val   "${KOHA_ENV_FILE}" KOHA_DB_ROOT_PASSWORD password)"
  KOHA_DB_PASS="${KOHA_DB_PASS:-$(_env_val "${KOHA_ENV_FILE}" KOHA_DB_PASSWORD password)}"
else
  KOHA_INSTANCE="kohadev"; KOHA_DOMAIN=".myDNSname.org"
  KOHA_INTRANET_SUFFIX="-intra"; KOHA_OPAC_PORT="8080"; KOHA_INTRANET_PORT="8081"
  KOHA_DB_PASS="password"
fi

if [[ -f "${OS_ENV_FILE}" ]]; then
  OS_ADMIN_PASS="$(_env_val "${OS_ENV_FILE}" OPENSEARCH_INITIAL_ADMIN_PASSWORD changeme)"
elif [[ -f "${KOHA_ENV_FILE}" ]]; then
  OS_ADMIN_PASS="$(_env_val "${KOHA_ENV_FILE}" OPENSEARCH_INITIAL_ADMIN_PASSWORD changeme)"
else
  OS_ADMIN_PASS="changeme"
fi

TRAEFIK_HTTP_PORT="$(_env_val  "${TRAEFIK_ENV_FILE}" TRAEFIK_HTTP_PORT  80)"
TRAEFIK_DASHBOARD_PORT="$(_env_val "${TRAEFIK_ENV_FILE}" TRAEFIK_DASHBOARD_PORT 8083)"

# Derived names
OPAC_HOST="${KOHA_INSTANCE}${KOHA_DOMAIN}"
STAFF_HOST="${KOHA_INSTANCE}${KOHA_INTRANET_SUFFIX}${KOHA_DOMAIN}"
KOHA_CONTAINER="koha-docker-koha-1"
DB_CONTAINER="koha-docker-db-1"
MEM_CONTAINER="koha-docker-memcached-1"
DB_NAME="koha_${KOHA_INSTANCE}"
DB_USER="koha_${KOHA_INSTANCE}"

echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║         Koha Stack — Network Diagnostics         ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
info "KOHA_INSTANCE   : ${KOHA_INSTANCE}"
info "KOHA_DOMAIN     : ${KOHA_DOMAIN}"
info "OPAC host       : ${OPAC_HOST}"
info "Staff host      : ${STAFF_HOST}"
info "OPAC direct     : http://localhost:${KOHA_OPAC_PORT}"
info "Staff direct    : http://localhost:${KOHA_INTRANET_PORT}"
info "Traefik HTTP    : :${TRAEFIK_HTTP_PORT}   dashboard :${TRAEFIK_DASHBOARD_PORT}"

# ---------------------------------------------------------------------------
# 1. Tool availability
# ---------------------------------------------------------------------------
hdr "1. Required tools"

for tool in docker curl nc openssl python3; do
  if command -v "${tool}" >/dev/null 2>&1; then
    pass "${tool} found: $(command -v "${tool}")"
  else
    warn "${tool} not found — some tests will be skipped"
  fi
done

# ---------------------------------------------------------------------------
# 2. Docker networks
# ---------------------------------------------------------------------------
hdr "2. Docker networks"

check_network() {
  local net="$1" desc="$2"
  if docker network inspect "${net}" >/dev/null 2>&1; then
    local containers
    containers=$(docker network inspect "${net}" \
      --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | tr ' ' '\n' \
      | grep -v '^$' | sort | tr '\n' ' ')
    pass "Network '${net}' exists  (${desc})"
    info "  attached: ${containers:-<none>}"
  else
    fail "Network '${net}' does NOT exist  (${desc})"
  fi
}

check_network frontend          "Traefik ↔ Koha ↔ Dashboards"
check_network opensearch-36_osearch "OpenSearch cluster — Koha joins this"
check_network knonikl           "Dashboards ↔ Koha extra link"

# kohanet may have a project prefix
KOHANET_NAME=""
for candidate in kohanet "koha-docker_kohanet" "koha_kohanet"; do
  if docker network inspect "${candidate}" >/dev/null 2>&1; then
    KOHANET_NAME="${candidate}"; break
  fi
done
if [[ -n "${KOHANET_NAME}" ]]; then
  check_network "${KOHANET_NAME}" "Koha internal: db + memcached + koha"
else
  fail "Internal koha network (kohanet) not found — Koha compose stack is down"
fi

# ---------------------------------------------------------------------------
# 3. Container status
# ---------------------------------------------------------------------------
hdr "3. Container status"

check_container() {
  local name="$1"
  local state
  state=$(docker inspect --format '{{.State.Status}}' "${name}" 2>/dev/null || echo "missing")
  local health
  health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
    "${name}" 2>/dev/null || echo "")
  case "${state}" in
    running)
      if [[ "${health}" == "unhealthy" ]]; then
        fail "Container '${name}' is running but UNHEALTHY"
      elif [[ "${health}" == "starting" ]]; then
        warn "Container '${name}' is running but health check still STARTING"
      else
        pass "Container '${name}' running  (health: ${health})"
      fi
      ;;
    missing)
      fail "Container '${name}' does not exist"
      ;;
    *)
      fail "Container '${name}' state=${state}  (expected: running)"
      ;;
  esac
}

check_container traefik
check_container os01
check_container os02
check_container os03
check_container os04
check_container os05
check_container dashboards
check_container "${DB_CONTAINER}"
check_container "${MEM_CONTAINER}"
check_container "${KOHA_CONTAINER}"

# ---------------------------------------------------------------------------
# 4. OpenSearch — host perspective
# ---------------------------------------------------------------------------
hdr "4. OpenSearch (host → os01:9200)"

echo "  Testing TCP connectivity to localhost:9200..."
if nc -z -w3 localhost 9200 2>/dev/null; then
  pass "TCP port 9200 is open on localhost"
else
  fail "TCP port 9200 is NOT reachable on localhost — os01 port binding missing or container down"
fi

echo "  Testing HTTPS health endpoint..."
OS_HEALTH=$(curl -sk -w "\n%{http_code}" \
  -u "admin:${OS_ADMIN_PASS}" \
  "https://localhost:9200/_cluster/health" 2>/dev/null || true)
OS_HTTP_CODE=$(echo "${OS_HEALTH}" | tail -1)
OS_BODY=$(echo "${OS_HEALTH}" | head -1)

if [[ "${OS_HTTP_CODE}" == "200" ]]; then
  OS_STATUS=$(echo "${OS_BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "parse-error")
  case "${OS_STATUS}" in
    green)  pass "OpenSearch cluster status: GREEN" ;;
    yellow) warn "OpenSearch cluster status: YELLOW (replica shards unassigned — normal for 5-node single-machine setup)" ;;
    red)    fail "OpenSearch cluster status: RED (primary shards missing — indices may be corrupted)" ;;
    *)      warn "OpenSearch cluster status: ${OS_STATUS} (could not parse)" ;;
  esac
  # Node count
  NODE_COUNT=$(echo "${OS_BODY}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('number_of_nodes',0))" 2>/dev/null || echo "0")
  if [[ "${NODE_COUNT}" -ge 5 ]]; then
    pass "OpenSearch nodes in cluster: ${NODE_COUNT}/5"
  else
    fail "OpenSearch nodes in cluster: ${NODE_COUNT}/5 — some nodes have not joined"
  fi
else
  case "${OS_HTTP_CODE}" in
    401) fail "OpenSearch returned 401 Unauthorized — check OPENSEARCH_INITIAL_ADMIN_PASSWORD in env files (used: ${OS_ADMIN_PASS:0:4}…)" ;;
    000) fail "OpenSearch HTTPS endpoint unreachable (curl returned 000) — container may be starting or TLS handshake failed" ;;
    *)   fail "OpenSearch returned HTTP ${OS_HTTP_CODE:-<no response>}" ;;
  esac
  info "  Response body: ${OS_BODY:0:200}"
fi

# TLS certificate expiry
echo "  Checking TLS certificate expiry..."
CERT_FILE="${OS_SSL_DIR}/root-ca.pem"
if [[ -f "${CERT_FILE}" ]]; then
  NOT_AFTER=$(openssl x509 -in "${CERT_FILE}" -noout -dates 2>/dev/null | grep notAfter | cut -d= -f2)
  NOT_AFTER_EPOCH=$(date -d "${NOT_AFTER}" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  DAYS_LEFT=$(( (NOT_AFTER_EPOCH - NOW_EPOCH) / 86400 ))
  if (( DAYS_LEFT > 30 )); then
    pass "Root CA cert expires in ${DAYS_LEFT} days  (${NOT_AFTER})"
  elif (( DAYS_LEFT > 0 )); then
    warn "Root CA cert expires in ${DAYS_LEFT} days — consider regenerating soon (see README, 'One-time setup' section)"
  else
    fail "Root CA cert has EXPIRED ${DAYS_LEFT#-} days ago — OpenSearch TLS will fail"
  fi
  # Also check the live TLS cert from os01
  LIVE_CERT=$(echo | openssl s_client -connect localhost:9200 \
    -servername os01 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || true)
  if [[ -n "${LIVE_CERT}" ]]; then
    LIVE_NOT_AFTER=$(echo "${LIVE_CERT}" | grep notAfter | cut -d= -f2)
    pass "Live TLS cert from os01:9200 valid until ${LIVE_NOT_AFTER}"
  else
    warn "Could not retrieve live TLS cert from os01:9200 (cluster may still be starting)"
  fi
else
  warn "Root CA cert not found at ${CERT_FILE} — certificates have not been generated yet"
  warn "  See README section 'One-time setup — OpenSearch TLS certificates'"
fi

# ---------------------------------------------------------------------------
# 5. OpenSearch — from inside the Koha container
# ---------------------------------------------------------------------------
hdr "5. OpenSearch (Koha container → os01:9200)"

if docker inspect "${KOHA_CONTAINER}" >/dev/null 2>&1; then
  # TCP via nc
  if docker exec "${KOHA_CONTAINER}" bash -c "nc -z -w3 os01 9200 2>/dev/null"; then
    pass "TCP: Koha → os01:9200 reachable"
  else
    fail "TCP: Koha cannot reach os01:9200 — network 'opensearch-36_osearch' may not be attached to Koha container"
  fi

  # HTTPS health
  INNER_OS=$(docker exec "${KOHA_CONTAINER}" bash -c \
    "curl -sk -w '\n%{http_code}' -u 'admin:${OS_ADMIN_PASS}' https://os01:9200/_cluster/health" \
    2>/dev/null || echo -e "\n000")
  INNER_CODE=$(echo "${INNER_OS}" | tail -1)
  INNER_BODY=$(echo "${INNER_OS}" | head -1)
  if [[ "${INNER_CODE}" == "200" ]]; then
    pass "HTTPS: Koha → os01:9200 authenticated OK"
  elif [[ "${INNER_CODE}" == "401" ]]; then
    fail "HTTPS: Koha → os01:9200 returned 401 — password mismatch between Koha env and OpenSearch"
    info "  OPENSEARCH_INITIAL_ADMIN_PASSWORD in env/.env must match OpenSearch-3.6/.env"
  elif [[ "${INNER_CODE}" == "000" ]]; then
    fail "HTTPS: Koha → os01:9200 unreachable (curl 000) — containers not on same network or TLS error"
    info "  Koha container must be on 'opensearch-36_osearch' network"
  else
    fail "HTTPS: Koha → os01:9200 returned HTTP ${INNER_CODE}"
    info "  Body: ${INNER_BODY:0:200}"
  fi

  # Check KOHA_ELASTICSEARCH env var inside container
  ES_ENABLED=$(docker exec "${KOHA_CONTAINER}" bash -c \
    'echo "${KOHA_ELASTICSEARCH}"' 2>/dev/null || echo "")
  if [[ "${ES_ENABLED}" == "yes" ]]; then
    pass "KOHA_ELASTICSEARCH=yes (OpenSearch is enabled in Koha)"
  else
    warn "KOHA_ELASTICSEARCH='${ES_ENABLED}' — should be 'yes' for OpenSearch search to work"
    info "  Set KOHA_ELASTICSEARCH=yes in env/.env"
  fi
else
  warn "Koha container not running — skipping cross-container OpenSearch tests"
fi

# ---------------------------------------------------------------------------
# 6. MariaDB
# ---------------------------------------------------------------------------
hdr "6. MariaDB"

if docker inspect "${DB_CONTAINER}" >/dev/null 2>&1; then
  # mysqladmin ping
  if docker exec "${DB_CONTAINER}" \
      mysqladmin ping -uroot -p"${KOHA_DB_PASS}" --silent 2>/dev/null; then
    pass "MariaDB mysqladmin ping OK"
  else
    fail "MariaDB mysqladmin ping FAILED — check KOHA_DB_ROOT_PASSWORD and container logs"
  fi

  # Database exists
  DB_LIST=$(docker exec "${DB_CONTAINER}" \
    mysql -uroot -p"${KOHA_DB_PASS}" -e "SHOW DATABASES;" 2>/dev/null || echo "")
  if echo "${DB_LIST}" | grep -q "^${DB_NAME}$"; then
    pass "Database '${DB_NAME}' exists"
    # Row count as sanity check
    TBL_COUNT=$(docker exec "${DB_CONTAINER}" \
      mysql -uroot -p"${KOHA_DB_PASS}" "${DB_NAME}" \
      -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" \
      --batch --skip-column-names 2>/dev/null || echo 0)
    if (( TBL_COUNT > 0 )); then
      pass "Database has ${TBL_COUNT} tables (Koha installer has run)"
    else
      warn "Database '${DB_NAME}' exists but has no tables — Koha has not initialised yet"
    fi
  else
    fail "Database '${DB_NAME}' does NOT exist — Koha has not been initialised"
    info "  Koha creates the DB on first startup. Check 'docker logs ${KOHA_CONTAINER}'"
  fi

  # Koha DB user exists
  USER_EXISTS=$(docker exec "${DB_CONTAINER}" \
    mysql -uroot -p"${KOHA_DB_PASS}" -e \
    "SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}';" \
    --batch --skip-column-names 2>/dev/null || echo 0)
  if (( USER_EXISTS > 0 )); then
    pass "MariaDB user '${DB_USER}' exists"
  else
    fail "MariaDB user '${DB_USER}' does NOT exist — DB was not initialised by stack.sh"
  fi
else
  fail "DB container '${DB_CONTAINER}' is not running — cannot test MariaDB"
fi

# TCP reachability from Koha container
if docker inspect "${KOHA_CONTAINER}" >/dev/null 2>&1 \
   && docker inspect "${DB_CONTAINER}" >/dev/null 2>&1; then
  if docker exec "${KOHA_CONTAINER}" bash -c "nc -z -w3 db 3306 2>/dev/null"; then
    pass "TCP: Koha → db:3306 reachable"
  else
    fail "TCP: Koha cannot reach db:3306 — 'kohanet' network may not be connecting the two"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Memcached
# ---------------------------------------------------------------------------
hdr "7. Memcached"

if docker inspect "${MEM_CONTAINER}" >/dev/null 2>&1; then
  pass "Memcached container is running"
  if docker inspect "${KOHA_CONTAINER}" >/dev/null 2>&1; then
    if docker exec "${KOHA_CONTAINER}" bash -c "nc -z -w3 memcached 11211 2>/dev/null"; then
      pass "TCP: Koha → memcached:11211 reachable"
    else
      fail "TCP: Koha cannot reach memcached:11211"
      info "  Both containers must be on the same 'kohanet' network"
    fi
    # Quick stats ping via printf (no extra tools needed)
    STATS=$(docker exec "${KOHA_CONTAINER}" bash -c \
      "printf 'stats\r\nquit\r\n' | nc -w2 memcached 11211 2>/dev/null | head -3" \
      2>/dev/null || echo "")
    if echo "${STATS}" | grep -q "^STAT "; then
      pass "Memcached responds to 'stats' command"
    else
      warn "Memcached did not return stats — may still be starting"
    fi
  fi
else
  fail "Memcached container '${MEM_CONTAINER}' is not running"
fi

# ---------------------------------------------------------------------------
# 8. Traefik
# ---------------------------------------------------------------------------
hdr "8. Traefik"

if docker inspect traefik >/dev/null 2>&1; then
  # Internal ping via exec (the ping entrypoint is :8082 inside the container, not exposed)
  PING_RESP=$(docker exec traefik \
    wget -q -O- "http://127.0.0.1:8082/ping" 2>/dev/null || echo "")
  if [[ "${PING_RESP}" == "OK" ]]; then
    pass "Traefik ping endpoint: OK"
  else
    warn "Traefik ping returned '${PING_RESP:-<empty>}' — may still be starting"
  fi

  # Dashboard API
  ROUTERS_JSON=$(curl -s "http://localhost:${TRAEFIK_DASHBOARD_PORT}/api/http/routers" 2>/dev/null || echo "")
  if [[ -n "${ROUTERS_JSON}" ]] && echo "${ROUTERS_JSON}" | python3 -m json.tool >/dev/null 2>&1; then
    ROUTER_COUNT=$(echo "${ROUTERS_JSON}" | python3 -c \
      "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo "?")
    pass "Traefik API reachable on :${TRAEFIK_DASHBOARD_PORT} — ${ROUTER_COUNT} HTTP router(s) registered"

    # Check Koha OPAC router
    if echo "${ROUTERS_JSON}" | grep -q "koha-opac"; then
      pass "Traefik router 'koha-opac' is registered"
    else
      fail "Traefik router 'koha-opac' NOT found — Koha container may not be on 'frontend' network or labels are missing"
      info "  Check: docker inspect ${KOHA_CONTAINER} | grep -A5 Networks"
    fi

    # Check Koha staff router
    if echo "${ROUTERS_JSON}" | grep -q "koha-staff"; then
      pass "Traefik router 'koha-staff' is registered"
    else
      fail "Traefik router 'koha-staff' NOT found"
    fi

    # Check Dashboards router
    if echo "${ROUTERS_JSON}" | grep -q "dashboards"; then
      pass "Traefik router 'dashboards' is registered"
    else
      warn "Traefik router 'dashboards' NOT found — check dashboards container labels and 'frontend' network"
    fi
  else
    warn "Traefik API not responding on :${TRAEFIK_DASHBOARD_PORT} — dashboard may still be starting"
    info "  curl http://localhost:${TRAEFIK_DASHBOARD_PORT}/api/http/routers"
  fi

  # Host port 80 / TRAEFIK_HTTP_PORT is actually reachable
  if nc -z -w3 localhost "${TRAEFIK_HTTP_PORT}" 2>/dev/null; then
    pass "TCP: host port ${TRAEFIK_HTTP_PORT} (Traefik HTTP) is open"
  else
    fail "TCP: host port ${TRAEFIK_HTTP_PORT} is NOT open — Traefik is not listening or port binding failed"
    info "  Traefik may need a non-privileged port if port 80 is taken. Check traefik/.env → TRAEFIK_HTTP_PORT"
  fi
else
  fail "Traefik container is not running"
fi

# ---------------------------------------------------------------------------
# 9. Koha — direct host access (Apache ports)
# ---------------------------------------------------------------------------
hdr "9. Koha direct access (host → Apache ports)"

check_koha_port() {
  local port="$1" name="$2"
  if nc -z -w3 localhost "${port}" 2>/dev/null; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 10 "http://localhost:${port}/" 2>/dev/null || echo "000")
    case "${HTTP_CODE}" in
      200|301|302|303)
        pass "HTTP ${name} (localhost:${port}) → ${HTTP_CODE}"
        ;;
      000)
        fail "HTTP ${name} (localhost:${port}) → no response (curl timeout)"
        info "  Koha Apache may still be starting. Check: docker logs ${KOHA_CONTAINER}"
        ;;
      503)
        warn "HTTP ${name} (localhost:${port}) → 503 Service Unavailable (Plack not yet up)"
        ;;
      *)
        warn "HTTP ${name} (localhost:${port}) → HTTP ${HTTP_CODE} (expected 200/30x)"
        ;;
    esac
  else
    fail "TCP: host port ${port} is NOT open — Koha container may not have bound the port"
    info "  Check: docker port ${KOHA_CONTAINER}"
  fi
}

check_koha_port "${KOHA_OPAC_PORT}"      "OPAC"
check_koha_port "${KOHA_INTRANET_PORT}"  "Staff"

# Apache inside the container
if docker inspect "${KOHA_CONTAINER}" >/dev/null 2>&1; then
  APACHE_STATUS=$(docker exec "${KOHA_CONTAINER}" bash -c \
    "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:${KOHA_OPAC_PORT}/" \
    2>/dev/null || echo "000")
  if [[ "${APACHE_STATUS}" =~ ^(200|301|302|303)$ ]]; then
    pass "Apache inside Koha container: HTTP ${APACHE_STATUS} on :${KOHA_OPAC_PORT}"
  else
    fail "Apache inside Koha container not responding on :${KOHA_OPAC_PORT} (got: ${APACHE_STATUS})"
    info "  Check: docker exec ${KOHA_CONTAINER} service apache2 status"
  fi

  # Plack
  PLACK_RUNNING=$(docker exec "${KOHA_CONTAINER}" bash -c \
    "pgrep -x plackup >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null || echo "unknown")
  if [[ "${PLACK_RUNNING}" == "yes" ]]; then
    pass "Plack is running inside Koha container"
  else
    warn "Plack (plackup) does not appear to be running inside Koha container"
    info "  If startup is still in progress, this is normal. Check: docker logs ${KOHA_CONTAINER} --tail 50"
  fi
fi

# ---------------------------------------------------------------------------
# 10. Koha — via Traefik (DNS routing)
# ---------------------------------------------------------------------------
hdr "10. Koha via Traefik (Host header routing)"

traefik_request() {
  local host="$1" label="$2"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    -H "Host: ${host}" \
    "http://localhost:${TRAEFIK_HTTP_PORT}/" 2>/dev/null || echo "000")
  case "${http_code}" in
    200|301|302|303)
      pass "Traefik → ${label} (Host: ${host}) → HTTP ${http_code}" ;;
    000)
      fail "Traefik → ${label} (Host: ${host}) → no response" ;;
    404)
      fail "Traefik → ${label} (Host: ${host}) → 404 Not Found — router rule may not match" ;;
    503)
      warn "Traefik → ${label} (Host: ${host}) → 503 (backend not ready yet)" ;;
    *)
      warn "Traefik → ${label} (Host: ${host}) → HTTP ${http_code}" ;;
  esac
}

if nc -z -w1 localhost "${TRAEFIK_HTTP_PORT}" 2>/dev/null; then
  traefik_request "${OPAC_HOST}"  "OPAC"
  traefik_request "${STAFF_HOST}" "Staff"
  traefik_request "dashboards.localhost" "OpenSearch Dashboards"
else
  warn "Skipping Traefik routing tests — port ${TRAEFIK_HTTP_PORT} not open"
fi

# DNS resolution check
echo ""
echo "  Checking DNS resolution for Koha hostnames..."
for fqdn in "${OPAC_HOST}" "${STAFF_HOST}"; do
  if getent hosts "${fqdn}" >/dev/null 2>&1; then
    RESOLVED_IP=$(getent hosts "${fqdn}" | awk '{print $1}')
    pass "DNS '${fqdn}' resolves to ${RESOLVED_IP}"
  else
    warn "DNS '${fqdn}' does NOT resolve on this host"
    info "  Options:"
    info "    1. Add to /etc/hosts:  127.0.0.1  ${OPAC_HOST}  ${STAFF_HOST}"
    info "    2. Use nip.io:  set KOHA_DOMAIN=.127.0.0.1.nip.io in env/.env (then restart)"
    info "    3. Or use direct ports: http://localhost:${KOHA_OPAC_PORT}  :${KOHA_INTRANET_PORT}"
  fi
done

# ---------------------------------------------------------------------------
# 11. OpenSearch Dashboards
# ---------------------------------------------------------------------------
hdr "11. OpenSearch Dashboards"

if nc -z -w3 localhost 5601 2>/dev/null; then
  DB_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://localhost:5601/" 2>/dev/null || echo "000")
  if [[ "${DB_CODE}" =~ ^(200|301|302|303)$ ]]; then
    pass "Dashboards direct (localhost:5601) → HTTP ${DB_CODE}"
  else
    warn "Dashboards direct (localhost:5601) → HTTP ${DB_CODE}"
    info "  Dashboards may still be loading (initial startup is slow)"
  fi
else
  fail "TCP: localhost:5601 is NOT open — dashboards container may not be running or port not bound"
fi

# ---------------------------------------------------------------------------
# 12. Koha internal service checks
# ---------------------------------------------------------------------------
hdr "12. Koha container — internal service checks"

if docker inspect "${KOHA_CONTAINER}" >/dev/null 2>&1; then
  # koha-conf.xml exists
  KOHA_CONF=$(docker exec "${KOHA_CONTAINER}" bash -c \
    'echo "${KOHA_CONF:-/etc/koha/sites/kohadev/koha-conf.xml}"' 2>/dev/null || echo "")
  CONF_EXISTS=$(docker exec "${KOHA_CONTAINER}" bash -c \
    "[[ -f '${KOHA_CONF}' ]] && echo yes || echo no" 2>/dev/null || echo "unknown")
  if [[ "${CONF_EXISTS}" == "yes" ]]; then
    pass "koha-conf.xml found at ${KOHA_CONF}"
  else
    fail "koha-conf.xml NOT found at ${KOHA_CONF} — Koha initialisation did not complete"
    info "  Check: docker logs ${KOHA_CONTAINER} | grep -i 'conf\|error'"
  fi

  # koha-z3950
  Z3950=$(docker exec "${KOHA_CONTAINER}" bash -c \
    "systemctl is-active koha-z3950-responder@kohadev 2>/dev/null || \
     pgrep -f z3950 >/dev/null 2>&1 && echo active || echo inactive" \
    2>/dev/null || echo "unknown")
  info "koha-z3950-responder: ${Z3950}"

  # Zebra / SearchEngine
  ZEBRA=$(docker exec "${KOHA_CONTAINER}" bash -c \
    "pgrep -f zebra >/dev/null 2>&1 && echo running || echo 'not running'" \
    2>/dev/null || echo "unknown")
  info "Zebra process: ${ZEBRA} (expected 'not running' when KOHA_ELASTICSEARCH=yes)"

  # Check ELASTIC_SERVER env
  ELASTIC_SERVER=$(docker exec "${KOHA_CONTAINER}" bash -c \
    'echo "${ELASTIC_SERVER}"' 2>/dev/null || echo "")
  if [[ -n "${ELASTIC_SERVER}" ]]; then
    pass "ELASTIC_SERVER is set to '${ELASTIC_SERVER}'"
    if [[ "${ELASTIC_SERVER}" == *"os01"* ]] || [[ "${ELASTIC_SERVER}" == *"localhost"* ]]; then
      :  # looks reasonable
    else
      warn "ELASTIC_SERVER '${ELASTIC_SERVER}' does not reference 'os01' — check env/.env"
    fi
  else
    warn "ELASTIC_SERVER is empty in the Koha container — OpenSearch will not be used"
  fi
else
  warn "Koha container not running — skipping internal checks"
fi

# ---------------------------------------------------------------------------
# 13. Network attachment cross-check
# ---------------------------------------------------------------------------
hdr "13. Network attachment cross-check"

check_attached() {
  local container="$1" network="$2"
  if docker inspect "${container}" >/dev/null 2>&1; then
    if docker inspect "${container}" \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
        2>/dev/null | grep -qw "${network}"; then
      pass "${container} ↔ network '${network}': attached"
    else
      fail "${container} is NOT attached to network '${network}'"
      info "  This container needs that network to communicate. Check docker-compose.yml networks section."
    fi
  else
    info "${container} not running — skipping network attachment check for '${network}'"
  fi
}

check_attached "${KOHA_CONTAINER}" "frontend"
check_attached "${KOHA_CONTAINER}" "opensearch-36_osearch"
check_attached "${KOHA_CONTAINER}" "knonikl"
check_attached traefik             "frontend"
check_attached dashboards          "frontend"
check_attached dashboards          "knonikl"
check_attached dashboards          "opensearch-36_osearch"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hdr "Summary"
TOTAL=$(( PASS_COUNT + FAIL_COUNT + WARN_COUNT ))
echo ""
echo -e "  Total checks : ${TOTAL}"
echo -e "  ${GREEN}Passed  : ${PASS_COUNT}${RESET}"
echo -e "  ${YELLOW}Warnings: ${WARN_COUNT}${RESET}"
echo -e "  ${RED}Failed  : ${FAIL_COUNT}${RESET}"
echo ""

if (( ${#WARNINGS[@]} > 0 )); then
  echo -e "${YELLOW}${BOLD}Warnings (non-blocking):${RESET}"
  for w in "${WARNINGS[@]}"; do
    echo -e "  ${YELLOW}⚠${RESET}  ${w}"
  done
  echo ""
fi

if (( ${#FAILURES[@]} > 0 )); then
  echo -e "${RED}${BOLD}Failures (need attention):${RESET}"
  for f in "${FAILURES[@]}"; do
    echo -e "  ${RED}✗${RESET}  ${f}"
  done
  echo ""
  echo -e "${BOLD}Quick remediation hints:${RESET}"
  echo "  • Stack not fully up?      ./stack.sh status"
  echo "  • Missing Docker networks?  ./stack.sh start  (creates frontend + starts all stacks)"
  echo "  • DNS not resolving?        Set KOHA_DOMAIN=.127.0.0.1.nip.io  OR add /etc/hosts entries"
  echo "  • OpenSearch unreachable?   Check: docker logs os01 --tail 50"
  echo "  • Koha not responding?      Check: docker logs ${KOHA_CONTAINER} --tail 50"
  echo "  • Auth failure (401)?       Ensure OPENSEARCH_INITIAL_ADMIN_PASSWORD matches in both env files"
  echo "  • Certs expired?            See README → 'One-time setup — OpenSearch TLS certificates'"
  echo ""
  exit 1
else
  echo -e "${GREEN}${BOLD}All checks passed!${RESET}"
  if (( WARN_COUNT > 0 )); then
    echo -e "${YELLOW}(${WARN_COUNT} warning(s) — see above)${RESET}"
  fi
  echo ""
  exit 0
fi
