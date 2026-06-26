---
title: "Stack.sh Orchestrator"
tags: [stack.sh, startup, commands, build, deploy, network-creation, log-scraping, credential-sync]
---

# Stack.sh Orchestrator

The main management script. Location: `/home/kosson/Documents/koha-docker/stack.sh` (722 lines)

## Usage

```bash
./stack.sh <command> [options]

Commands:
  start       Build (if requested) and start the full stack
  stop        Stop all services gracefully
  restart     Quick restart: reset DB + recreate Koha container
  status      Show running containers and OpenSearch cluster health
  logs        Tail Koha container logs
  build       Build images only (no start)
  reset       Destructive: remove all containers AND volumes
  --help      Full usage
```

### Startup Options

```bash
./stack.sh start --build        # Build images then start
./stack.sh start --no-fresh-db  # Resume without dropping database
./stack.sh start --no-demo-data # Skip sample data loading
./stack.sh start --with-demo-data   # Force sample data loading
./stack.sh start --no-logs      # Start without tailing logs
```

## Startup Sequence (start --build)

```
1. check_prereqs()
   ├── docker in PATH?
   ├── docker compose plugin?
   └── env/.env exists?

2. ensure_frontend_network()
   └── docker network create frontend (if missing)

3. ensure_extra_networks()
   └── docker network create knonikl, opensearch-36_osearch (if missing)

4. ensure_opensearch_certs()
   ├── Check config file exists
   ├── Check all 18 cert files exist and are files (not dirs)
   ├── Regenerate if any missing (run opensearch_local_certificates_creator.sh)
   └── Verify all certs present after generation

5. sync_koha_opensearch_credentials()
   ├── Read OS_ADMIN_PASS from OpenSearch-3.6/.env (source of truth)
   ├── Use Python to update ELASTIC_OPTIONS userinfo in env/.env
   ├── Export synced values

6. ensure_opensearch_auth()
   ├── curl -u admin:password https://localhost:9200/_cluster/health
   ├── If 401: run initial_api_calls.sh + force-recreate os01 + wait for green
   └── If other: warn and continue

7. start_opensearch()
   ├── Check if kosson/opensearch-icu:3.6.0 exists locally
   ├── If missing: build_opensearch() (docker compose build os01)
   ├── docker compose up -d os01 os02 os03 os04 os05
   └── wait_opensearch_green() (poll _cluster/health, up to 6 minutes)

8. start_support_services()
   ├── koha_compose up -d db memcached
   └── wait_db_ready() (poll mysql -uroot -p... 'SELECT 1;', up to 60s)

9. reset_database()
   ├── DROP DATABASE IF EXISTS koha_kohadev
   ├── CREATE DATABASE koha_kohadev (utf8mb4, utf8mb4_unicode_ci)
   ├── GRANT ALL ON koha_kohadev.* TO koha_kohadev@'%'
   └── FLUSH PRIVILEGES

10. start_koha()
    ├── export LOAD_DEMO_DATA
    └── koha_compose up -d --force-recreate koha

11. follow_logs() (default behavior)
    └── docker compose logs -f koha
        └── On milestone "koha-testing-docker has started up":
            print summary box with URLs and credentials
```

## Key Helper Functions

### `_env_val(FILE KEY [DEFAULT])`

Reads a value from an env file. Uses grep + cut, NOT `source`.

```bash
_env_val() {
  local file="$1" key="$2" default="${3:-}"
  val=$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' "'" || true)
  echo "${val:-${default}}"
}
```

### Compose Wrappers

Each wrapper sets the right compose file, env file, and project directory:

```bash
koha_compose()    # docker compose -f docker-compose.yml --env-file env/.env --project-directory .
os_compose()      # docker compose -f OpenSearch-3.6/docker-compose.yml --env-file OpenSearch-3.6/.env --project-directory OpenSearch-3.6
traefik_compose() # docker compose -f traefik/docker-compose.yaml --env-file traefik/.env --project-directory traefik
```

### Credential Sync (Python)

The OpenSearch credential sync uses an embedded Python script:

```bash
sync_koha_opensearch_credentials() {
  ELASTIC_OPTIONS="$(python3 - <<'PY'
import os, re
options = os.environ["ELASTIC_OPTIONS"]
password = os.environ["OPENSEARCH_INITIAL_ADMIN_PASSWORD"]
synced = re.sub(r'(<userinfo>admin:)[^<]*(</userinfo>)', r'\1' + password + r'\2', options, count=1)
print(synced)
PY
)"
  export ELASTIC_OPTIONS
}
```

This replaces the admin password in the XML-style ELASTIC_OPTIONS with the current password from `OpenSearch-3.6/.env`.

## Color Output

```bash
ts()   { date '+%H:%M:%S'; }
log()  { echo -e "${BLUE}[$(ts)]${RESET} $*"; }
ok()   { echo -e "${GREEN}[$(ts)] ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}[$(ts)] ⚠${RESET}  $*"; }
die()  { echo -e "${RED}[$(ts)] ✗  $*${RESET}" >&2; exit 1; }
hdr()  { echo -e "\n${BOLD}${CYAN}── $* ──${RESET}"; }
```

## Reset Flow

```bash
./stack.sh reset
```

1. Confirms with user ("Type 'yes' to confirm:")
2. `docker compose down --volumes` (koha stack)
3. `docker compose down --volumes` (OpenSearch stack)
4. `docker compose down --volumes` (Traefik)
5. Result: all containers + data removed, images preserved

⚠️ **Destructive**: deletes database, OpenSearch indices, everything.

## Restart Flow

```bash
./stack.sh restart
```

Quick restart: resets DB + recreates Koha container (doesn't restart OpenSearch).

## OpenSearch Green Wait

```bash
wait_opensearch_green() {
  # Polls _cluster/health every 5 seconds
  # Max 72 attempts = 6 minutes
  curl -sk -u admin:password https://localhost:9200/_cluster/health
  # Checks for "status":"green"
}
```

## MariaDB Ready Wait

```bash
wait_db_ready() {
  # Polls mysql -uroot -p... 'SELECT 1;' every 2 seconds
  # Max 30 attempts = 60 seconds
}
```

Uses **authenticated SQL** (not `mysqladmin ping`) to avoid the race condition documented in TRACKER.md.
