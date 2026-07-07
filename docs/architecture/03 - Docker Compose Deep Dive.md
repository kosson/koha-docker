---
title: "Docker Compose Deep Dive"
tags: [docker-compose, orchestration, services, volumes, networks, compose-files]
---
# Docker Compose Deep Dive

How the three compose files work together.
## Main Compose (`docker-compose.yml`)

Location: `/home/kosson/Documents/koha-docker/docker-compose.yml`

### Structure

```yaml
services:
  db:
    image: ${DB_IMAGE:-mariadb:10.11}
    command: ["--sql-mode=..."]
    environment: { MYSQL_ROOT_PASSWORD, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD }
    volumes: [koha-db-data:/var/lib/mysql]
    networks: [kohanet]

  koha:
    image: ${KOHA_IMAGE_TAG:-kosson/koha-ubuntu:latest}
    pull_policy: missing        # Use local if present, pull if missing, never build
    build: { context: . }       # Fallback: build from Dockerfile
    cap_add: [ALL]              # ⚠️ security issue
    volumes:
      - ${SYNC_REPO}:/kohadevbox/koha
      - ${OPENSEARCH_CA_CERT:-/dev/null}:/kohadevbox/opensearch-root-ca.pem:ro
    tmpfs: [/cover_db, /tmp]
    env_file: [env/.env]
    environment: { ...many vars... }
    ulimits: { nofile: 65536 }
    depends_on: [db, memcached]
    networks: [kohanet, knonikl, opensearch-36_osearch, frontend]
    ports: [8080:8080, 8081:8081]    # Direct host bindings (fallback, not required with Traefik)
    labels: [traefik routing rules]

  memcached:
    image: ${MEMCACHED_IMAGE:-memcached}
    command: memcached -m 64m
    networks: [kohanet]

volumes:
  koha-db-data:

networks:
  kohanet:
    enable_ipv4: true
    enable_ipv6: false
  knonikl:     external: true
  opensearch-36_osearch: external: true
  frontend:    external: true
```

### Key Observations

1. **`pull_policy: missing`** on koha service means:
   - If image is local → use it (no network call)
   - If image is missing → pull from Docker Hub
   - If pull fails → fall back to local `build:` context
   - This lets users use pre-built images OR rebuild locally

2. **Mixed `image:` and `build:`** on koha service is confusing (ISSUES.md #12). The tag serves as both pull target and local-build label.

3. **Four networks** on koha container — it bridges all the compose projects:
   - `kohanet` → talk to db and memcached
   - `opensearch-36_osearch` → talk to OpenSearch nodes
   - `knonikl` → shared with Dashboards
   - `frontend` → Traefik routing

4. **Direct ports** (8080, 8081) are kept as fallback when Traefik is not used.

## OpenSearch Compose (`OpenSearch-3.6/docker-compose.yml`)

Location: `/home/kosson/Documents/koha-docker/OpenSearch-3.6/docker-compose.yml`

### Structure

```yaml
services:
  os01:                          # Cluster manager, has health check
    build: { context: ., dockerfile: assets/opensearch/Dockerfile }
    image: kosson/opensearch-icu:${OPEN_SEARCH_VERSION}
    pull_policy: never            # Never try to pull from Hub
    container_name: os01
    volumes:
      - ./assets/ssl/root-ca.pem: ...
      - ./assets/ssl/root-ca-key.pem: ...    # ⚠️ CA key exposed
      - ./assets/ssl/admin.pem: ...
      - ./assets/ssl/admin-key.pem: ...
      - ./assets/ssl/os01.pem: ...
      - ./assets/ssl/os01-key.pem: ...
      - ./assets/opensearch/config/os01/...  # jvm, log4j, opensearch.yml, security configs
      - ./assets/opensearch/data/os01data:/usr/share/opensearch/data:rw
      - ./assets/opensearch/performance-analyzer: ...
    environment:
      - node.roles=cluster_manager
      - node.name=os01
      - network.host=os01
      - cluster.name=${OS_CLUSTER_NAME}
      - discovery.seed_hosts=os01,os02,os03,os04,os05
      - cluster.initial_cluster_manager_nodes=os01,os02
      - bootstrap.memory_lock=true
      - OPENSEARCH_INITIAL_ADMIN_PASSWORD=...
      - OPENSEARCH_JAVA_OPTS=...
      - DISABLE_INSTALL_DEMO_CONFIG=true
    ulimits: { memlock: -1, nofile: 65536 }
    networks: [osearch]
    healthcheck: { curl + client cert }
    restart: on-failure

  os02-os05:                     # Similar structure, different roles
    image: kosson/opensearch-icu:${OPEN_SEARCH_VERSION}
    pull_policy: never
    volumes: [per-node SSL certs, configs, data dirs]
    environment:
      - node.roles=data,ingest     # or search for os05
      - node.name=osXX
      - network.host=osXX
      ...
    networks: [osearch]
    restart: on-failure

  dashboards:
    image: opensearchproject/opensearch-dashboards:${OPEN_SEARCH_VERSION}
    depends_on: { os01: { condition: service_healthy } }
    networks: [osearch, knonikl, frontend]
    labels: [traefik routing]

networks:
  osearch:
  knonikl:
    name: knonikl                # Explicit name pinning
  frontend:                      external: true
```

### Key Design Points

1. **os01 is the only node with `build:`** — its `image:` tag is shared by os02-os05. This means only one image needs to be built.

2. **`pull_policy: never`** on all nodes — the stack.sh script handles building if the image is missing (see `start_opensearch()`).

3. **Bind-mounted data** (`./assets/ssl/`, `./assets/opensearch/data/`) means:
   - Data persists across container recreation
   - Permissions must be correct (uid 1000)
   - Certs must exist before docker compose starts

4. **mTLS between nodes**: Each node gets its own PEM cert + key, plus the root CA. Node-to-node transport uses client certs.

5. **Network pinning**: `knonikl` has explicit `name: knonikl` to avoid Docker's automatic prefixing (e.g., `OpenSearch-3.6_knonikl`).

## Traefik Compose (`traefik/docker-compose.yaml`)

Location: `/home/kosson/Documents/koha-docker/traefik/docker-compose.yaml`

### Structure

```yaml
services:
  traefik:
    image: traefik
    container_name: traefik
    restart: unless-stopped
    network_mode: host           # or custom network? (check file)
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./config/traefik.yaml:/etc/traefik/traefik.yaml
      - ./acme.json:...          # Let's Encrypt certificates
    environment:
      - TRAEFIK_HTTP_PORT=${TRAEFIK_HTTP_PORT}
      - TRAEFIK_HTTPS_PORT=${TRAEFIK_HTTPS_PORT}
    ports:
      - "${TRAEFIK_HTTP_PORT}:80"
      - "${TRAEFIK_HTTPS_PORT}:443"
      - "${TRAEFIK_DASHBOARD_PORT}:8080"  # Dashboard
    labels:
      # Routing rules for koha-opac, koha-staff, dashboards
```

### Configuration

- `config/traefik.yaml` — Traefik static config (entrypoints, providers, SSL options)
- ACME `acme.json` — stores Let's Encrypt certificates (must be created with correct permissions)

### Key Points

- Reads Docker labels dynamically from other containers on the `frontend` network
- The `frontend` network must be created before Traefik starts (stack.sh handles this)
