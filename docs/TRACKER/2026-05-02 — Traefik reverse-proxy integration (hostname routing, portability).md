---
title: Traefik reverse-proxy integration (hostname routing, portability)
date: 2026-05-02
tags:
 - Traefik
 - reverse-proxy
 - routing
---
# 2026-05-02 — Traefik reverse-proxy integration (hostname routing, portability)

## Goal

Eliminate the requirement to add `127.0.0.1 kohadev.myDNSname.org` and `127.0.0.1 kohadev-intra.myDNSname.org` to the host machine's `/etc/hosts` file.
The solution must be portable — no per-machine DNS configuration should be needed.

The existing Traefik container (`koha-docker/traefik/`) is leveraged as the entry point for all HTTP traffic. Traefik routes incoming requests to the correct Koha port based on the `Host:` header, removing the need for direct port bindings in the browser.

## Architecture before this change

```log
Browser
  └─► http://kohadev.myDNSname.org:8080  → requires /etc/hosts: 127.0.0.1 kohadev.myDNSname.org
  └─► http://kohadev-intra.myDNSname.org:8081  → requires /etc/hosts: 127.0.0.1 kohadev-intra.myDNSname.org

Docker host
  koha container :8080 (host binding) → OPAC
  koha container :8081 (host binding) → Staff interface
```

Problems:

- Non-standard ports in all URLs (`:8080`, `:8081`)
- `/etc/hosts` must be edited on every machine that accesses the stack
- Not portable to a remote server without changing DNS or `/etc/hosts` on every client

## Architecture after this change

```log
Browser
  └─► http://kohadev.myDNSname.org  (port 80, standard)
  └─► http://kohadev-intra.myDNSname.org  (port 80, standard)
         │
         ▼
  Traefik container  (frontend network, port 80 on host)
  reads Host: header
         │
         ├─ Host: kohadev.myDNSname.org       → koha container :8080
         └─ Host: kohadev-intra.myDNSname.org → koha container :8081

Fallback (no DNS):
  http://localhost:8080  (direct, no Traefik)
  http://localhost:8081  (direct, no Traefik)
```

Networks involved:

- `frontend` — external Docker bridge; Traefik + koha join it; Traefik reads labels from it
- `kohanet` — internal; koha + db + memcached
- `knonikl` — shared bridge; koha + OpenSearch Dashboards
- `opensearch-36_osearch` — OpenSearch cluster internal; koha + os01–os05

## How Traefik Docker provider routing works

Traefik watches the Docker socket (`/var/run/docker.sock`) for container events. When a container with `traefik.enable=true` starts, Traefik reads its labels and dynamically creates:

1. **Router** — matches incoming HTTP requests by hostname (the `Host()` rule)
2. **Service** — defines where to forward matched requests (container IP + port)

The `traefik.docker.network` label tells Traefik which Docker network to use when resolving the container's IP. This is required when a container is attached to multiple networks (as `koha` is). Without it, Traefik may pick the wrong network's IP and the forwarded request would be unreachable.

Traefik's static config (`traefik/config/traefik.yaml`) already has:

```yaml
providers:
  docker:
    exposedByDefault: false
    network: frontend
```

The `network: frontend` here is the global default. The per-container `traefik.docker.network=frontend` label is an explicit override that ensures the correct network is used even if the global default is later changed.

## Changes made

### 1. `koha-docker/docker-compose.yml` — Traefik labels and `frontend` network

Added a `labels:` block to the `koha` service with two Traefik routers and two services:

```yaml
labels:
    # traefik.enable=true — opt this container in (required because exposedByDefault: false)
    - "traefik.enable=true"
    # Override the network Traefik uses to reach this container
    - "traefik.docker.network=frontend"

    # ── OPAC router + service ──────────────────────────────────────────────
    # Host rule: matches requests where Host: == kohadev.myDNSname.org
    # (value built from KOHA_INSTANCE + KOHA_DOMAIN env vars at compose time)
    - "traefik.http.routers.koha-opac.rule=Host(`${KOHA_INSTANCE}${KOHA_DOMAIN}`)"
    - "traefik.http.routers.koha-opac.entrypoints=web"
    - "traefik.http.routers.koha-opac.service=koha-opac-svc"
    # Forward to the container's internal port 8080 (KOHA_OPAC_PORT)
    - "traefik.http.services.koha-opac-svc.loadbalancer.server.port=${KOHA_OPAC_PORT:-8080}"

    # ── Staff interface router + service ──────────────────────────────────
    # Host rule: kohadev-intra.myDNSname.org
    - "traefik.http.routers.koha-staff.rule=Host(`${KOHA_INSTANCE}${KOHA_INTRANET_SUFFIX}${KOHA_DOMAIN}`)"
    - "traefik.http.routers.koha-staff.entrypoints=web"
    - "traefik.http.routers.koha-staff.service=koha-staff-svc"
    # Forward to internal port 8081 (KOHA_INTRANET_PORT)
    - "traefik.http.services.koha-staff-svc.loadbalancer.server.port=${KOHA_INTRANET_PORT:-8081}"
```

**Why two explicit services are needed**: when a container exposes multiple ports (8080 and 8081), Traefik cannot infer which port to use for which router. Declaring named services with explicit `loadbalancer.server.port` values removes the ambiguity.

**Why `${KOHA_INSTANCE}${KOHA_DOMAIN}` expands at compose time**: Docker Compose interpolates `${VAR}` in label values from the `env_file` (here `env/.env`) before passing the label string to Docker. Traefik then reads the already-expanded label value.
This means changing `KOHA_INSTANCE` or `KOHA_DOMAIN` in `env/.env` automatically updates the routing rules on next `docker compose up` — no manual Traefik config editing needed.

Also added `frontend: {}` to the `koha` service's `networks:` block so the container joins the `frontend` network at startup:

```yaml
networks:
    kohanet:
        aliases: [...]
    knonikl: {}
    opensearch-36_osearch: {}
    frontend: {}            # ← ADDED: allows Traefik to reach the container
```

And added `frontend` to the top-level `networks:` declaration:

```yaml
networks:
    kohanet:
        enable_ipv4: ${ENABLE_IPV4:-true}
        enable_ipv6: ${ENABLE_IPV6:-false}
    knonikl:
        external: true
    opensearch-36_osearch:
        external: true
    frontend:               # ← ADDED
        external: true
```

The `ports:` host bindings (`8080:8080`, `8081:8081`) are **kept** as a fallback. They allow direct `http://localhost:8080` / `http://localhost:8081` access when Traefik is not running or DNS does not resolve. A comment documents that they can be removed once Traefik is the exclusive entry point.

### 2. `koha-docker/traefik/docker-compose.yaml` — configurable host ports

The Traefik container previously had the HTTP port hard-coded to `83:80`. On a typical Linux server port 80 is the standard HTTP port. Changed all three port bindings to use environment variables with sensible defaults:

```yaml
# Before
ports:
  - "83:80"
  - "443:443"
  - "8083:8080"

# After
ports:
  - "${TRAEFIK_HTTP_PORT:-80}:80"
  - "${TRAEFIK_HTTPS_PORT:-443}:443"
  - "${TRAEFIK_DASHBOARD_PORT:-8083}:8080"
```

`:-80` / `:-443` / `:-8083` are Docker Compose default-value syntax: if the variable is unset or empty in the environment, the default after `:-` is used. This means the file works out-of-the-box with no `.env` required, but the ports can be overridden.

### 3. `koha-docker/traefik/.env` — port defaults documented

The startup script (`run.sh`) is long-running and produces extensive output. Key milestones to watch for, in sequence:

```log
| Milestone | Log line |
|---|---|
| Instance configuration created | `koha-create --request-db kohadev` |
| Database populated | `Running do_all_you_can_do.pl` |
| L10n translation files cloned | `Cloning into 'po'...` |
| Git config and hooks set | `git config bz.default-tracker` |
| Source tree gitified | `gitify all` |
| Front-end assets compiled | `yarn build` / `rspack` |
| Search index built | `rebuild_elasticsearch.pl -v` |
| Plack OPAC started | `Plack enabled for kohadev OPAC` |
| Plack Intranet started | `Plack enabled for kohadev Intranet` |
| **Ready** | `koha-testing-docker has started up and is ready to be enjoyed!` |
```

The container exits with code 0 after printing the "ready" line — this is expected. The Plack workers continue running inside the container even after `run.sh` exits.

## What a successful run looks like (abridged log)

```log
koha-1  | Running [sudo koha-shell kohadev -p -c 'koha-create --request-db kohadev']...
koha-1  |  * Error: worker not running for kohadev (default)      ← harmless, no DB yet
koha-1  |  * Error: worker not running for kohadev (long_tasks)   ← harmless
koha-1  | Running [sudo koha-shell kohadev -p -c 'perl .../do_all_you_can_do.pl --elasticsearch']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'git clone ... misc/translator/po']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'gitify all']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'yarn build']...
koha-1  | Running [sudo koha-shell kohadev -p -c 'rebuild_elasticsearch.pl -v']...
koha-1  | :8: parser error : PCDATA invalid Char value 31         ← harmless, biblio 369
koha-1  | Something went wrong reading record for biblio 369 ...  ← harmless, corrupt sample data
koha-1  | Plack enabled for kohadev OPAC
koha-1  | Plack enabled for kohadev Intranet
koha-1  |  * Error: Plack already running for kohadev             ← harmless double-start attempt
koha-1  | koha-testing-docker has started up and is ready to be enjoyed!
koha-1 exited with code 0
```

### Non-fatal warnings explained

| Warning | Cause | Impact |
|---|---|---|
| `Error: worker not running for kohadev` | `koha-create` tries to restart the worker before the DB is populated | None — worker starts fine later |
| `PCDATA invalid Char value 31` (biblio 369) | One bibliographic row in `biblio_metadata` contains a literal ASCII 31 control character inside stored MARCXML. In the current database it is `biblio_metadata.id=368` / `biblionumber=369`, and the malformed byte is visible in the XML payload itself. This matches the known sample-data record shipped through `misc4dev` and not an OpenSearch cluster failure. | None — Koha skips that one record during indexing; the rest of the bibliographic index continues to build. |
| `Cannot determine authority type for record: 1` | The authority indexer can parse `authid=1`, but `Koha::SearchEngine::Elasticsearch` cannot infer an authority type from that record while building `match-heading`. The record exists as `authtypecode=PERSO_NAME`, but its MARCXML has no normal heading field to classify from, so `GuessAuthTypeCode()` returns nothing. | None — that authority record is skipped for match-heading generation; the rest of the authority index continues. |
| `Error: Plack already running for kohadev` | `run.sh` calls `koha-plack --start` twice (once in `do_all_you_can_do.pl` and once at the end of the script) | None — second call is a no-op |

The important distinction is that these are data-quality warnings, not OpenSearch service faults. The cluster can still be healthy while Koha reports missing indexed records if one or more source records are malformed or not classifiable for index generation.

## Accessing Koha

After a successful start:

| Interface | URL |
|---|---|
| OPAC | http://kohadev.myDNSname.org:8080 |
| Staff interface (Intranet) | http://kohadev-intra.myDNSname.org:8081 |
| OpenSearch Dashboards | http://localhost:5601 (via `knonikl` network / Traefik) |

Default superlibrarian credentials are set by `create_superlibrarian.pl` during startup (see `env/.env` for `KOHA_ADMINUSER` / `KOHA_ADMINPASS`).

## Files changed in this session (summary)

| File | Change | Section |
|---|---|---|
| `Dockerfile` | `RUN userdel -r ubuntu` — frees UID 1000 for `kohadev-koha` | UID fix |
| `koha-docker/docker-compose.yml` | Added `opensearch-36_osearch` as external network; attached koha service to it | Network routing |
| `koha-docker/env/.env` | `ELASTIC_SERVER` stripped of credentials; `ELASTIC_OPTIONS` with `ssl_options` + `userinfo` + `client_version`; `PERL_LWP_SSL_VERIFY_HOSTNAME=0` | SSL/auth/product check |
| `OpenSearch-3.6/assets/opensearch/Dockerfile` | Added `analysis-icu` plugin install | ICU plugin |
| `OpenSearch-3.6/docker-compose.yml` | `os02`–`os05` switched from `image:` to `build:` | ICU plugin |

The `.env` file previously contained only a comment line. Port variables added:

```bash
# Host port bindings for the Traefik proxy container.
# Change TRAEFIK_HTTP_PORT to a non-privileged port (e.g. 8000) if port 80 is
# already in use on the host, then access Koha as http://hostname:8000
TRAEFIK_HTTP_PORT=80
TRAEFIK_HTTPS_PORT=443
TRAEFIK_DASHBOARD_PORT=8083
```

If port 80 is already bound (e.g., another web server), change `TRAEFIK_HTTP_PORT=8000` here. The access URLs then become `http://kohadev.myDNSname.org:8000`.

### 4. `koha-docker/stack.sh` — Traefik lifecycle management

Four additions:

**a) `TRAEFIK_DIR` path variable**

```bash
TRAEFIK_DIR="${SCRIPT_DIR}/traefik"
```

**b) Port variables read from `traefik/.env`**

```bash
TRAEFIK_HTTP_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_HTTP_PORT 80)"
TRAEFIK_DASHBOARD_PORT="$(_env_val "${TRAEFIK_DIR}/.env" TRAEFIK_DASHBOARD_PORT 8083)"
```

These are used in the startup banner and in `start_traefik()`.

**c) `traefik_compose()` wrapper**

```bash
traefik_compose() {
  docker compose \
---
    -f "${TRAEFIK_DIR}/docker-compose.yaml" \
    --env-file "${TRAEFIK_DIR}/.env" \
    --project-directory "${TRAEFIK_DIR}" \
    "$@"
}
```

Consistent with the existing `koha_compose()` and `os_compose()` wrappers.

**d) `ensure_frontend_network()` function**

```bash
ensure_frontend_network() {
  if ! docker network inspect frontend >/dev/null 2>&1; then
    log "Creating 'frontend' Docker network (required by Traefik)..."
    docker network create frontend
    ok "Network 'frontend' created."
  else
    ok "Network 'frontend' already exists."
  fi
}
```

The `frontend` network is declared `external: true` in both the Traefik compose and the Koha compose. Docker refuses to start either project if the network doesn't exist. This function is called at the start of `start_traefik()` and creates the network idempotently (no error if it already exists).

**e) `start_traefik()` and `stop_traefik()` functions**

```bash
start_traefik() {
  hdr "Starting Traefik reverse proxy"
  ensure_frontend_network
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
```

`start_traefik()` is idempotent: if Traefik is already up (e.g., from a previous run or because it is shared with other projects), it is left running.

**f) `check_prereqs()` updated**

Added validation that `traefik/docker-compose.yaml` exists:

```bash
[[ -f "${TRAEFIK_DIR}/docker-compose.yaml" ]] \
  || die "traefik/docker-compose.yaml not found"
```

**g) Startup sequence updated**

`start_traefik` is now the **first** step in `stack.sh start`, before OpenSearch:

```
1. start_traefik          ← NEW: ensures frontend network + Traefik container
2. start_opensearch
3. wait_opensearch_green
4. start_support_services
5. wait_db_ready
6. reset_database (if --no-fresh-db not set)
7. start_koha
8. follow_logs
```

`stop_traefik` is the **last** step in `stack.sh stop`:

```
1. stop_koha
2. stop_support_services
3. stop_opensearch
4. stop_traefik
```

**h) `show_status()` updated**

A Traefik section was added to the `status` command output:

```bash
echo -e "${BOLD}── Traefik ──...${RESET}"
traefik_compose ps 2>/dev/null || echo "  (not running)"
```

**i) Access banner in `follow_logs()` updated**

The "ready" banner now shows both access methods and all four service URLs:

```
╔══════════════════════════════════════════════════════════╗
║   Stack fully started and ready!                         ║
╠══════════════════════════════════════════════════════════╣
║  Via Traefik (recommended):
║    OPAC    : http://kohadev.myDNSname.org
║    Staff   : http://kohadev-intra.myDNSname.org
║  Direct (fallback, no DNS needed):
║    OPAC    : http://localhost:8080
║    Staff   : http://localhost:8081
║  Login     : koha / koha
║  Dashbrd   : http://dashboards.localhost
║  Traefik   : http://localhost:8083
╚══════════════════════════════════════════════════════════╝
```

If `TRAEFIK_HTTP_PORT` is not 80, the port suffix (e.g., `:8000`) is appended automatically to all Traefik-routed URLs.

## Hostname resolution — three options documented

The Traefik labels handle the routing side. For a browser to send a request with the correct `Host:` header to the Docker host, the hostnames must resolve. Three approaches are documented in the README and below:

### Option 1 — `/etc/hosts` (simple, single machine)

```
127.0.0.1  kohadev.myDNSname.org
127.0.0.1  kohadev-intra.myDNSname.org
```

Requires a one-time edit with `sudo` on every machine that needs access. Good enough for a single developer's workstation.

### Option 2 — `nip.io` wildcard DNS (zero-config, portable)

[nip.io](https://nip.io) is a public DNS service that resolves any hostname containing an embedded IP address back to that IP. No registration, no local configuration.

Set in `env/.env`:

```bash
KOHA_DOMAIN=.127.0.0.1.nip.io       # local access
# or
KOHA_DOMAIN=.192.168.1.100.nip.io   # LAN/server access
```

Access URLs become:

- `http://kohadev.127.0.0.1.nip.io` (OPAC)
- `http://kohadev-intra.127.0.0.1.nip.io` (Staff)

The Traefik `Host()` rules and Koha's Apache virtual hosts are rebuilt from `KOHA_DOMAIN` automatically on next `docker compose up`. No other files need changing.
This is the most portable option for development. It works from any machine on the LAN (using the server's LAN IP) without touching DNS or `/etc/hosts` on any client.

### Option 3 — Real DNS (production)

Create DNS A records for `kohadev.myDNSname.org` and `kohadev-intra.myDNSname.org` (or a wildcard `*.myDNSname.org`) pointing to the server's public IP. Traefik handles
routing; no client-side configuration needed.

## Why Traefik must join the `frontend` network (not just `knonikl`)

The Traefik static config (`traefik/config/traefik.yaml`) declares:

```yaml
providers:
  docker:
    network: frontend
```

This tells Traefik: "when forwarding requests to containers, use the IP address the container has on the `frontend` network." If the `koha` container is not attached to
`frontend`, Traefik cannot reach it even though the labels are visible via the Docker socket. Attaching `koha` to `frontend` solves this.

The `knonikl` network continues to serve its original purpose (Koha ↔ OpenSearch Dashboards communication) and is unrelated to Traefik routing.

## Files changed

| File | Change |
|---|---|
| `koha-docker/docker-compose.yml` | Added `labels:` block with Traefik routers/services; added `frontend: {}` to `koha` service networks; added `frontend: external: true` to top-level `networks:` |
| `koha-docker/traefik/docker-compose.yaml` | Changed hard-coded port `83:80` to `${TRAEFIK_HTTP_PORT:-80}:80`; same for HTTPS and dashboard ports |
| `koha-docker/traefik/.env` | Added `TRAEFIK_HTTP_PORT=80`, `TRAEFIK_HTTPS_PORT=443`, `TRAEFIK_DASHBOARD_PORT=8083` |
| `koha-docker/stack.sh` | Added `TRAEFIK_DIR`; added `TRAEFIK_HTTP_PORT` / `TRAEFIK_DASHBOARD_PORT` config reads; added `traefik_compose()`, `ensure_frontend_network()`, `start_traefik()`, `stop_traefik()`; updated `check_prereqs()`, `start` sequence, `stop` sequence, `show_status()`, access banner in `follow_logs()` |
| `koha-docker/README.md` | Replaced `/etc/hosts` section with Traefik routing explanation; documented all three hostname resolution options; updated service URL table (port-free Traefik URLs + direct fallback); updated `KOHA_DOMAIN` table row with nip.io hint |

## Session — nip.io Fix + Demo Data Flags (2026-05-02)

### Root Cause: nip.io / URL-in-database Bug

`files/run.sh` was constructing `KOHA_OPAC_URL=http://kohadev.127.0.0.1.nip.io:8080` — with the **internal** Apache port 8080. This URL is stored in the Koha database as `OPACBaseURL` and `staffClientBaseURL` via `populate_db.pl`. When users access Koha through Traefik on port 80, all Koha-generated links and login redirects pointed to `:8080`, bypassing Traefik entirely.

The nip.io DNS service itself was fine — `host kohadev.127.0.0.1.nip.io` → `127.0.0.1` worked correctly. The problem was purely the port baked into URLs stored in the DB.

### Fix: KOHA_PUBLIC_PORT

**New env var `KOHA_PUBLIC_PORT=80`** decouples the *public-facing* port (what users type in browser, served by Traefik) from the *internal Apache port* (`KOHA_OPAC_PORT=8080`, used for container-to-container routing and Traefik backend).

URL construction logic in `files/run.sh`:

- Port 80 or empty → URLs have **no port suffix**: `http://kohadev.127.0.0.1.nip.io`
- Any other port → suffix appended: `http://kohadev.127.0.0.1.nip.io:8000`

**Test result:**

```log
OPACBaseURL:         http://kohadev.127.0.0.1.nip.io   ← no :8080 ✓
staffClientBaseURL:  http://kohadev-intra.127.0.0.1.nip.io  ← no :8081 ✓
OPAC via Traefik:    HTTP 200 ✓
Staff via Traefik:   HTTP 200 ✓
```

### New Feature: Demo Data Flags

`./stack.sh start --no-demo-data` starts Koha with an empty catalogue (superlibrarian account only).  
`./stack.sh start --with-demo-data` loads 436 MARC sample records, authority records, and items (default).

**Mechanism:** When `LOAD_DEMO_DATA=no`, `run.sh` replaces `misc4dev/insert_data.pl` with a Perl no-op script before calling `do_all_you_can_do.pl`. All other setup steps (schema, superlibrarian, gitify, yarn, ES rebuild) run normally.

**Test result:**

```log
--no-demo-data:   biblio_count = 0  ✓
--with-demo-data: biblio_count = 436 ✓
```

### Files Changed

| File | Change |
|------|--------|
| `files/run.sh` | New `KOHA_PUBLIC_PORT` URL construction; new `LOAD_DEMO_DATA=no` no-op injection |
| `env/.env` | Added `KOHA_PUBLIC_PORT=80`, `LOAD_DEMO_DATA=yes` |
| `docker-compose.yml` | Added `LOAD_DEMO_DATA` and `KOHA_PUBLIC_PORT` to `environment:` block |
| `stack.sh` | New `--no-demo-data` / `--with-demo-data` flags; updated `start_koha()`; updated banner |

### Key Architecture Notes

- `files/run.sh` is **COPIED** into the Docker image during `docker build` — changes require `./stack.sh start --build-koha`.
- `KOHA_OPAC_PORT=8080` still controls internal Apache listen port and Traefik backend routing.
- `KOHA_PUBLIC_PORT=80` only affects URL construction for the Koha DB preferences.
- The `environment:` block in `docker-compose.yml` overrides `env_file:` values, enabling shell exports from `stack.sh` to flow through.
