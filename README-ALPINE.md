# Alpine Linux Koha Docker Environment

A modern, lightweight Koha library management system runtime on Alpine Linux 3.24.1 with production-grade SSL/TLS database connectivity.

**Status:** ✅ HTTP-Ready Production Image `kosson/koha-alpine:26.11`

---

## Table of Contents

1. [Quick Start](#quick-start)
2. [Using stack-alpine.sh](#using-stack-alpinesh)
3. [SSL Certificate Management](#ssl-certificate-management)
4. [Project Structure](#project-structure)
5. [Environment Configuration](#environment-configuration)
6. [Starting the Project](#starting-the-project)
7. [Operating the System](#operating-the-system)
8. [Architecture](#architecture)
9. [Troubleshooting](#troubleshooting)
10. [Dockerfile-Alpine Shims (1-Minute Explainer)](#dockerfile-alpine-shims-1-minute-explainer)
11. [OpenSearch Maintenance Tasks](#opensearch-maintenance-tasks)
12. [Reproducible Rebuild and Validation (Clean Cycle)](#reproducible-rebuild-and-validation-clean-cycle)
13. [Development Workflow](#development-workflow)

---

## Quick Start

### Prerequisites

- Docker Engine 20.10+ with docker-compose support
- Sufficient disk space (1.8GB for base image + database volume)
- Network connectivity for initial image build

### Start the Stack in 3 Steps

```bash
cd /path/to/KOHA-DOCKER-SOLUTIONS/koha-docker

# 1. Copy environment template (if first time)
cp env/template.env env/.env

# 2. Build or pull the Alpine image
docker compose -f docker-compose-alpinekoha.yml build

# 3. Start all services
docker compose -f docker-compose-alpinekoha.yml up -d
```

### Verify Bootstrap Success

```bash
# Wait 120-140 seconds for full bootstrap, then check:
docker compose -f docker-compose-alpinekoha.yml logs koha | tail -n 5

# Should see: "koha-testing-docker has started up and is ready to be enjoyed!"
```

### Access the Application

| Service | URL | Port | Notes |
|---------|-----|------|-------|
| **OPAC** (patron interface) | http://localhost:8080 | 8080 | Public library catalog |
| **Staff/Intranet** (admin) | http://localhost:8081 | 8081 | Library staff interface |
| **Database** | localhost:3306 | 3306 | Internal only (SSL required) |
| **RabbitMQ Management** | http://localhost:15672 | 15672 | STOMP: localhost:61613 |
| **Memcached** | localhost:11211 | 11211 | Internal caching |

### Stop the Stack

```bash
docker compose -f docker-compose-alpinekoha.yml down

# To keep database between restarts, use: (data in koha-db-data volume persists)
docker compose -f docker-compose-alpinekoha.yml stop
```

## Using stack-alpine.sh

The `stack-alpine.sh` script is the Alpine-oriented orchestration wrapper for Koha + MariaDB + Memcached + RabbitMQ, with optional OpenSearch and Traefik lifecycle.

Run all commands from the `koha-docker` directory:

```bash
cd /path/to/KOHA-DOCKER-SOLUTIONS/koha-docker
```

Common commands:

```bash
# Start full stack (default command)
./stack-alpine.sh start

# Start and keep current DB contents
./stack-alpine.sh start --no-fresh-db

# Start without following logs
./stack-alpine.sh start --no-logs

# Quick restart of Koha path (OpenSearch remains up)
./stack-alpine.sh restart

# Stop everything managed by the script
./stack-alpine.sh stop

# Build images only
./stack-alpine.sh build --build

# Show status and health summary
./stack-alpine.sh status

# Follow Koha startup/runtime logs
./stack-alpine.sh logs
```

Alpine-specific startup profile:

```bash
# Fast resume path for existing DB (default)
./stack-alpine.sh start --bootstrap-profile resume --no-fresh-db

# Force full population/reindex path on existing DB
./stack-alpine.sh start --bootstrap-profile full --no-fresh-db
```

Safety notes:

1. `start` without `--no-fresh-db` may recreate the Koha DB (with confirmation if data is detected).
2. `reset` is destructive and removes containers plus named volumes.
3. Prefer `status` before and after operations to confirm OpenSearch/Koha health.

For full options:

```bash
./stack-alpine.sh --help
```

---

## SSL Certificate Management

### Overview

The Koha Alpine container uses **SSL/TLS encryption for all MariaDB database connections**. The certificates are pre-generated and included in the image at `/etc/mysql/ssl/`.

**Certificate Chain:**
- **CA Certificate** (`ca-cert.pem`, `ca-key.pem`): Self-signed Certificate Authority
- **Server Certificate** (`server-cert.pem`, `server-key.pem`): Database server certificate
- **Configuration** (`mariadb-ssl.cnf`): MySQL SSL configuration
- **Extensions** (`server-ext.cnf`): Certificate subject alternative names

### Who Creates Certificates and When

| Role | Task | Timing | How |
|------|------|--------|-----|
| **First-time Setup** (DevOps/Developer) | Generate root CA and server certificates | During initial project setup | See "Generating New Certificates" below |
| **Image Builder** | Bake certificates into Alpine image | During Docker image build | `COPY files-alpine/mariadb-ssl /etc/mysql/ssl` in Dockerfile-Alpine |
| **Runtime** | Mount SSL files into MariaDB container | At container startup | Via docker-compose volume mounts |
| **Certificate Renewal** (DevOps) | Replace expired certificates | Every 10 years (default) or on expiration | Generate new certs, rebuild image |

### Certificate Locations

```
files-alpine/mariadb-ssl/
├── ca-cert.pem              # Root CA public certificate
├── ca-key.pem               # Root CA private key (keep private!)
├── server-cert.pem          # Database server public certificate
├── server-key.pem           # Database server private key (keep private!)
├── server-ext.cnf           # Server certificate extensions (alt names)
├── ca-cert.srl              # CA serial number tracking
└── mariadb-ssl.cnf          # MySQL SSL configuration
```

All files are:
- ✅ Committed to git (self-signed, non-production safe)
- ✅ Baked into Docker image during build
- ✅ Mounted read-only into MariaDB container at `/etc/mysql/ssl`

### Generating New Certificates

**Use case:** Initial setup, certificate renewal, or custom hostname requirements.

**Prerequisites:**
```bash
# Alpine/Linux: ensure openssl is installed
apk add openssl

# Debian/Ubuntu:
sudo apt-get install openssl

# macOS:
brew install openssl
```

**Step 1: Create Certificate Authority (CA)**

```bash
cd files-alpine/mariadb-ssl

# Generate CA private key (RSA 2048-bit)
openssl genrsa -out ca-key.pem 2048

# Generate CA public certificate (valid 10 years)
openssl req -new -x509 -nodes -days 3650 -key ca-key.pem -out ca-cert.pem \
  -subj "/CN=koha-mariadb-ca"

# Initialize serial tracking
echo "01" > ca-cert.srl
```

**Step 2: Create Server Certificate Request**

```bash
# Generate server private key
openssl genrsa -out server-key.pem 2048

# Create server certificate request
openssl req -new \
  -key server-key.pem \
  -out server.csr \
  -subj "/CN=db"
```

**Step 3: Create Server Certificate Extensions**

Create `server-ext.cnf` with your hostnames:

```ini
subjectAltName=DNS:db,DNS:localhost,DNS:your-hostname.local,IP:127.0.0.1,IP:192.168.1.100
extendedKeyUsage=serverAuth
```

**Step 4: Sign Server Certificate with CA**

```bash
openssl x509 -req -in server.csr \
  -CA ca-cert.pem -CAkey ca-key.pem \
  -CAserial ca-cert.srl \
  -out server-cert.pem \
  -days 3650 \
  -extensions v3_ext -extfile server-ext.cnf

# Clean up request file
rm server.csr
```

**Step 5: Verify Certificates**

```bash
# Verify CA certificate
openssl x509 -in ca-cert.pem -text -noout

# Verify server certificate
openssl x509 -in server-cert.pem -text -noout

# Verify server certificate signed by CA
openssl verify -CAfile ca-cert.pem server-cert.pem
```

### Using Certificates in the Container

**The container automatically uses certificates:**

```yaml
# docker-compose-alpinekoha.yml
services:
  db:
    command:
      - "--ssl=ON"  # Enable SSL enforcement
    volumes:
      - ./files-alpine/mariadb-ssl:/etc/mysql/ssl:ro
      - ./files-alpine/mariadb-ssl/mariadb-ssl.cnf:/etc/mysql/conf.d/zz-koha-ssl.cnf:ro
```

**To connect from host with SSL:**

```bash
# Client SSL certificate bundle (if required)
# CA certificate must match the container's ca-cert.pem

mysql --ssl-ca=files-alpine/mariadb-ssl/ca-cert.pem \
      --ssl-mode=REQUIRED \
      -h 127.0.0.1 -u koha_kohadev -p
```

### Certificate Troubleshooting

**Issue: "SSL connection error"**

```bash
# Check if MariaDB started with SSL
docker compose -f docker-compose-alpinekoha.yml logs db | grep -i ssl

# Verify certificates are readable in container
docker compose -f docker-compose-alpinekoha.yml exec db ls -la /etc/mysql/ssl/
```

**Issue: "Certificate verification failed"**

- Ensure CA certificate matches between server and client
- Check certificate expiration: `openssl x509 -enddate -noout -in ca-cert.pem`
- Verify certificate chain: `openssl verify -CAfile ca-cert.pem server-cert.pem`

**Issue: "New certificates not picked up after rebuild"**

```bash
# Full rebuild clears build cache
docker compose -f docker-compose-alpinekoha.yml build --no-cache

# Then restart
docker compose -f docker-compose-alpinekoha.yml up -d
```

---

## Project Structure

```
koha-docker/
├── Dockerfile-Alpine              # Alpine 3.24.1 base image (60+ stages)
├── docker-compose-alpinekoha.yml  # Service orchestration
├── README-ALPINE.md               # This file
│
├── files-alpine/                  # Alpine-specific files (baked into image)
│   ├── run.sh                     # Container entrypoint script
│   ├── lib/
│   │   ├── run-sh-alpine.sh       # Alpine service shims
│   │   └── ...
│   ├── templates/
│   │   ├── defaults.env           # Default environment variables
│   │   └── ...
│   ├── git_hooks/                 # Git hooks for development
│   ├── mariadb-ssl/               # ← SSL certificates (NEW LOCATION)
│   │   ├── ca-cert.pem
│   │   ├── ca-key.pem
│   │   ├── server-cert.pem
│   │   ├── server-key.pem
│   │   ├── server-ext.cnf
│   │   ├── ca-cert.srl
│   │   └── mariadb-ssl.cnf
│   └── ...
│
├── files/                         # Generic files (not Alpine-specific)
│   ├── run.sh                     # Original Debian-based script
│   ├── git_hooks/
│   └── templates/
│
├── env/
│   ├── defaults.env               # Global defaults
│   ├── template.env               # User config template
│   └── .env                       # User config (gitignored)
│
├── koha/                          # Koha repository (mounted at runtime)
│   ├── Koha/                      # Perl modules
│   ├── koha-tmpl/                 # Templates
│   ├── api/                       # REST API
│   ├── C4/                        # Core modules
│   └── ...
│
├── OpenSearch-3.6/                # Search engine (optional)
├── traefik/                       # Reverse proxy (optional)
├── tests/                         # Test scripts
├── patches/                       # Koha patches
└── docs/                          # Documentation
    └── Alpine-migration/          # Alpine migration notes
```

---

## Environment Configuration

### Initial Setup

```bash
# Copy template (first time only)
cp env/template.env env/.env

# Edit with your settings
nano env/.env
```

### Essential Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SYNC_REPO` | `/mnt/beckie2/DEVELOPMENT/koha-docker/koha` | Path to Koha source code (mounted into container) |
| `KOHA_INSTANCE` | `kohadev` | Library instance name |
| `KOHA_DB_PASSWORD` | `password` | Database password (change in production!) |
| `KOHA_DB_ROOT_PASSWORD` | `password` | Database root password |
| `KOHA_OPAC_PORT` | `8080` | Public catalog port |
| `KOHA_INTRANET_PORT` | `8081` | Staff interface port |
| `KOHA_ALPINE_IMAGE_TAG` | `kosson/koha-alpine:26.11` | Docker image to use |
| `KOHA_ALPINE_SKIP_YARN_INSTALL` | `no` | Skip frontend build (set to `yes` for faster start) |
| `KOHA_ALPINE_ELASTICSEARCH` | `no` | Enable Elasticsearch search (requires additional setup) |
| `APPLY_KOHA_PATCHES` | `no` | Apply `patches/*.patch` to mounted Koha source at startup (opt-in) |
| `LOCAL_USER_ID` | (user's UID) | Linux user ID for file permissions |

### Advanced Variables

```bash
# Search/indexing
KOHA_ELASTICSEARCH=no              # Set to 'yes' for full-text search
ELASTIC_SERVER=es:9200             # Elasticsearch endpoint
OPENSEARCH_CA_CERT=                # OpenSearch SSL certificate path

# Frontend/build
COVERAGE=                           # Enable code coverage tracking
SKIP_YARN_INSTALL=no               # Install JavaScript dependencies
SKIP_L10N=no                        # Skip localization build
LOAD_DEMO_DATA=yes                 # Load sample library data

# Database
USE_EXISTING_DB=                    # Point to external database
ALPINE_BOOTSTRAP_PROFILE=resume     # resume=fast existing-DB startup, full=force full population/reindex
RUN_DB_POPULATION_ON_EXISTING_DB=   # optional explicit override (yes/no), usually leave empty
APPLY_KOHA_PATCHES=no               # optional startup patch application (default off)
PERL_LWP_SSL_VERIFY_HOSTNAME=1      # SSL verification for Koha

# CPAN modules (advanced)
CPAN=no                             # Install additional CPAN modules
EXTRA_CPAN=                         # Comma-separated module list
EXTRA_APT=                          # Additional Alpine packages
```

---

## Starting the Project

### Full Bootstrap Sequence

The container runs these phases automatically:

```
1. [db] Database initialization (MariaDB with SSL)
2. [env] Environment setup & validation
3. [perl] Perl module loading & verification
4. [sip] SIP2 server configuration (optional)
5. [yarn] Frontend asset build (CSS, JavaScript)
6. [apache] Web server startup (CGI mode)
7. [services] Background services (RabbitMQ, Memcached)
8. [bootstrap-complete] HTTP endpoints ready
```

**Timing:** ~140 seconds from `docker compose up` to "ready to be enjoyed!"

### Starting with Custom Configuration

```bash
# Start with custom environment
SYNC_REPO=/path/to/custom/koha \
KOHA_INSTANCE=mylib \
docker compose -f docker-compose-alpinekoha.yml up -d

# Or use .env file
cat > env/.env << EOF
SYNC_REPO=/path/to/custom/koha
KOHA_INSTANCE=mylib
KOHA_DB_PASSWORD=mysecretpassword
KOHA_ALPINE_SKIP_YARN_INSTALL=no
EOF

docker compose -f docker-compose-alpinekoha.yml up -d
```

### Building from Source

```bash
# Full rebuild (clears build cache)
docker compose -f docker-compose-alpinekoha.yml build --no-cache

# Incremental build (uses cache layers)
docker compose -f docker-compose-alpinekoha.yml build

# Build with additional packages
EXTRA_APK="git htop curl" docker compose build
```

### Monitoring the Bootstrap

```bash
# Real-time logs
docker compose -f docker-compose-alpinekoha.yml logs -f koha

# Last 50 lines
docker compose -f docker-compose-alpinekoha.yml logs --tail=50 koha

# Filter specific phase
docker compose -f docker-compose-alpinekoha.yml logs koha | grep "\[alpine\]"
```

---

## Operating the System

### Daily Operations

#### Check System Health

```bash
# All services status
docker compose -f docker-compose-alpinekoha.yml ps

# Service logs
docker compose -f docker-compose-alpinekoha.yml logs db        # Database
docker compose -f docker-compose-alpinekoha.yml logs memcached  # Cache
docker compose -f docker-compose-alpinekoha.yml logs rabbitmq   # Message queue

# HTTP response times
curl -w "Time: %{time_total}s\n" http://localhost:8080/
```

#### Database Management

```bash
# Connect to database (inside container)
docker compose -f docker-compose-alpinekoha.yml exec db mariadb -u root -p

# Backup database
docker compose -f docker-compose-alpinekoha.yml exec db \
  mysqldump -u root -p koha_kohadev > backup-$(date +%s).sql

# Access using SSL from host
mysql --ssl-ca=files-alpine/mariadb-ssl/ca-cert.pem \
      --ssl-mode=REQUIRED \
      -h 127.0.0.1 -u koha_kohadev -p koha_kohadev
```

#### View Application Logs

```bash
# Koha application logs (inside container)
docker compose -f docker-compose-alpinekoha.yml exec koha \
  tail -f /var/log/koha/kohadev/intranet-access.log

# Apache error logs
docker compose -f docker-compose-alpinekoha.yml exec koha \
  tail -f /var/log/apache2/error.log

# Perl compilation errors
docker compose -f docker-compose-alpinekoha.yml logs koha | grep -i "can't locate"
```

### Maintenance Tasks

#### Rebuild Search Indexes

```bash
# Inside container (if Elasticsearch enabled)
docker compose -f docker-compose-alpinekoha.yml exec koha \
  koha-rebuild-zebra -f kohadev

# Note: Currently returns warnings due to disabled Elasticsearch
# This is non-critical and does not affect HTTP operation
```

#### OpenSearch Maintenance Tasks

```bash
# 1) Verify OpenSearch node health (os01)
docker compose -f OpenSearch-3.6/docker-compose.yml exec -T os01 \
  curl -ks -u admin:"$OPENSEARCH_INITIAL_ADMIN_PASSWORD" \
  https://localhost:9200/_cluster/health?pretty

# 2) List indices and status
docker compose -f OpenSearch-3.6/docker-compose.yml exec -T os01 \
  curl -ks -u admin:"$OPENSEARCH_INITIAL_ADMIN_PASSWORD" \
  'https://localhost:9200/_cat/indices?v&s=health,index'

# 3) Restart OpenSearch nodes (cluster maintained outside Alpine stack)
docker compose -f OpenSearch-3.6/docker-compose.yml restart os01 os02 os03 os04 os05

# 4) Rebuild Koha search index after OpenSearch maintenance (if enabled)
docker compose -f docker-compose-alpinekoha.yml exec koha \
  koha-shell kohadev -p -c 'perl /kohadevbox/koha/misc/search_tools/rebuild_elasticsearch.pl'
```

Notes:

1. Use OpenSearch checks only when `KOHA_ELASTICSEARCH=yes` and the `OpenSearch-3.6` cluster is running.
2. Keep Alpine stack (`docker-compose-alpinekoha.yml`) and OpenSearch stack (`OpenSearch-3.6/docker-compose.yml`) lifecycle commands separate.

#### Reproducible Rebuild and Validation (Clean Cycle)

Use this sequence to reproduce a clean Alpine image rebuild and full verification on another machine:

```bash
cd /path/to/KOHA-DOCKER-SOLUTIONS/koha-docker

# 1) Stop Alpine services
docker compose -f docker-compose-alpinekoha.yml down --remove-orphans

# 2) Remove Alpine Koha image (if already present)
docker image rm -f kosson/koha-alpine:26.11 || true

# 3) Rebuild from Dockerfile-Alpine without cache
docker compose -f docker-compose-alpinekoha.yml build --no-cache koha

# 4) Start Alpine services
docker compose -f docker-compose-alpinekoha.yml up -d

# 5) Run aggregate suite
bash tests/run_all_tests.sh

# 6) Run deterministic integration suite
KOHA_ELASTICSEARCH=no APPLY_KOHA_PATCHES=no bash tests/run_integration_deterministic.sh
```

#### Clear Caches

```bash
# Memcached (automatic restart clears)
docker compose -f docker-compose-alpinekoha.yml restart memcached

# Application caches (inside container)
docker compose -f docker-compose-alpinekoha.yml exec koha \
  rm -rf /var/cache/koha/kohadev/*
```

#### Update Koha Code

```bash
# With live code mounting (via SYNC_REPO)
# Simply edit files in: /mnt/beckie2/DEVELOPMENT/koha-docker/koha/

# Changes are visible immediately (development mode)
# For production, rebuild image to bake in changes

docker compose -f docker-compose-alpinekoha.yml build
```

#### Restart Services

```bash
# Restart single service
docker compose -f docker-compose-alpinekoha.yml restart koha

# Restart all services
docker compose -f docker-compose-alpinekoha.yml restart

# Full teardown and restart
docker compose -f docker-compose-alpinekoha.yml down
docker compose -f docker-compose-alpinekoha.yml up -d
```

### Managing Users and Permissions

```bash
# Create library user (inside container)
docker compose -f docker-compose-alpinekoha.yml exec koha \
  koha-create-user --email=librarian@example.com --patron-type=staff

# Reset admin password
docker compose -f docker-compose-alpinekoha.yml exec koha \
  sudo -u kohadev perl -I/kohadevbox/koha/lib \
  -MKoha::Script::SetPassword \
  -e "Koha::Script::SetPassword->new( { koha_instance => 'kohadev', password => 'newpassword' } )"
```

---

## Architecture

### Container Stack

```
┌─────────────────────────────────────────────────────────────┐
│  Docker Host (Linux)                                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ Koha Container (Alpine 3.24.1)                       │   │
│  ├──────────────────────────────────────────────────────┤   │
│  │                                                      │   │
│  │  ┌─────────────────┐  ┌───────────────────────────┐  │   │
│  │  │ Apache2 (CGI)   │  │ Perl/Koha Application     │  │   │
│  │  │ :8080 (OPAC)    │  │ - run.sh entrypoint       │  │   │
│  │  │ :8081 (Staff)   │  │ - koha-create bootstrap   │  │   │
│  │  │                 │  │ - 38+ CPAN modules        │  │   │
│  │  │ mod_rewrite ✓   │  │ - Yarn/Node.js assets     │  │   │
│  │  │ mod_cgi ✓       │  │ - /kohadevbox/koha (mount)│  │   │
│  │  │ mod_cgid ✓      │  │                           │  │   │
│  │  └─────────────────┘  └───────────────────────────┘  │   │
│  │                                                      │   │
│  │  /etc/mysql/ssl/              (SSL certificates)     │   │
│  │  - ca-cert.pem, ca-key.pem                           │   │
│  │  - server-cert.pem, server-key.pem                   │   │
│  │  - mariadb-ssl.cnf (config)                          │   │
│  │                                                      │   │
│  └──────────────────────────────────────────────────────┘   │
│         │               │               │                   │
│         └───────┬───────┴───────┬───────┘                   │
│                 │               │                           │
│  ┌──────────────▼──┐  ┌─────────▼─────────┐  ┌────────────┐ │
│  │ MariaDB 10.11   │  │ RabbitMQ 3        │  │ Memcached  │ │
│  │ :3306 (SSL ✓)   │  │ :61613 (STOMP)    │  │ :11211     │ │
│  │                 │  │ :15672 (mgmt)     │  │            │ │
│  │ koha_kohadev    │  │                   │  │ Cache      │ │
│  │ koha_kohadev_* │  │ koha_kohadev queue │  │ Sessions   │ │
│  │                 │  │                   │  │            │ │
│  └─────────────────┘  └───────────────────┘  └────────────┘ │
│         │                       │                    │      │
│         └───────────────────────┼────────────────────┘      │
│                                 │                           │
└─────────────────────────────────┼───────────────────────────┘
                                  │ Network (bridge: kohanet)
                            Docker compose network
```

### Build Stages (Dockerfile-Alpine)

| Stage | Purpose | Packages | Modules |
|-------|---------|----------|---------|
| Base | Alpine 3.24.1 runtime | perl, apache2, nodejs, openssl | - |
| Build | Compilation tools | gcc, perl-dev, build-base | CPAN compilation |
| Perl | CPAN modules | 38+ modules | Text::CSV_XS, Email::*, XML::*, DBIx::*, MARC::*, JSON::* |
| Apache | Web server | apache2, apache2-utils, mod_rewrite, mod_cgi | CGI interface |
| Node.js | Frontend | nodejs, npm, yarn | asset build pipeline |
| Runtime | Final image | All above | Complete Koha stack |

### SSL/TLS Flow

```
Client Request
    ↓
[HTTP :8080 (OPAC) or :8081 (Staff)]
    ↓
Apache2 (CGI dispatcher)
    ↓
Koha Perl Application
    ↓
[SSL/TLS :3306]
    ↓
MariaDB Database
    ├─ CA verified: ca-cert.pem ✓
    ├─ Server verified: server-cert.pem (signed by CA) ✓
    └─ Connection encrypted: server-key.pem ✓
```

---

## Troubleshooting

### Bootstrap Issues

#### "Compilation failed" or "Can't locate Module"

**Cause:** Missing Perl module

**Solution:**

```bash
# Check image logs
docker compose -f docker-compose-alpinekoha.yml logs koha | grep "Can't locate"

# Add missing module to Dockerfile-Alpine:
# Option A: Alpine package (fastest)
apk search perl-MODULE*

# Option B: CPAN (if no Alpine package)
# Add to Dockerfile-Alpine: RUN cpanm --notest ModuleName

# Rebuild
docker compose -f docker-compose-alpinekoha.yml build --no-cache
docker compose -f docker-compose-alpinekoha.yml up -d
```

#### "Port already in use"

**Cause:** Service running on 8080/8081

**Solution:**

```bash
# Find process
lsof -i :8080
lsof -i :8081

# Use different ports
KOHA_OPAC_PORT=9080 KOHA_INTRANET_PORT=9081 \
  docker compose -f docker-compose-alpinekoha.yml up -d
```

#### "Database connection failed"

**Cause:** MariaDB SSL certificate mismatch or not ready

**Solution:**

```bash
# Check MariaDB status
docker compose -f docker-compose-alpinekoha.yml logs db | grep -i error

# Verify SSL files present
docker compose -f docker-compose-alpinekoha.yml exec db ls -la /etc/mysql/ssl/

# Rebuild with fresh certificates
docker compose -f docker-compose-alpinekoha.yml down -v
docker compose -f docker-compose-alpinekoha.yml build --no-cache
docker compose -f docker-compose-alpinekoha.yml up -d
```

### Runtime Issues

#### HTTP 500 errors in browser

**Check logs:**

```bash
docker compose -f docker-compose-alpinekoha.yml logs koha | tail -n 50
docker compose -f docker-compose-alpinekoha.yml exec koha \
  tail -f /var/log/koha/kohadev/intranet-error.log
```

Common 500 signatures and fixes:

1. `Can't locate Lingua/Stem/Snowball.pm`
  - Cause: missing CPAN dependency in the running image.
  - Fix: rebuild from updated `Dockerfile-Alpine` (which now installs `Lingua::Stem::Snowball`).

2. `ZOOM::Query::*->new` warnings or `create ZOOM::Connection` compile errors
  - Cause: incomplete/old ZOOM shim in older image layers.
  - Fix: rebuild `docker-compose-alpinekoha.yml` image to pick up current shim implementation.

#### Slow performance / High CPU

**Check resource usage:**

```bash
docker stats koha-docker-koha-1

# Increase container resources
# Edit docker-compose-alpinekoha.yml:
# services:
#   koha:
#     mem_limit: 4g
#     cpus: 2
```

#### "AssignUserID not recognized"

**This is expected on Alpine!** The run.sh script automatically comments out this Debian-specific directive:

```bash
# Seen in logs as:
# [alpine] Removing Debian-specific Apache suexec directives...

# This is NOT an error - it's required for Alpine compatibility
```

### Network Issues

#### Container can't reach host resources

**Enable host network (development only):**

```bash
# Edit docker-compose-alpinekoha.yml:
# services:
#   koha:
#     network_mode: host
```

#### DNS resolution failing

```bash
# Check container DNS
docker compose -f docker-compose-alpinekoha.yml exec koha cat /etc/resolv.conf

# Force specific DNS
# docker-compose-alpinekoha.yml:
# services:
#   koha:
#     dns:
#       - 8.8.8.8
#       - 8.8.4.4
```

## Dockerfile-Alpine Shims (1-Minute Explainer)

Why shims exist:

- Alpine 3.24 repositories currently do not provide YAZ/`Net::Z3950::ZOOM` in a way compatible with this Koha runtime.
- Koha still references ZOOM classes/constants in several search/bootstrap paths.

What the shim does:

1. Provides minimal `ZOOM` symbols Koha expects at compile/runtime:
  - `ZOOM::Query::CCL2RPN`, `ZOOM::Query::CQL`, `ZOOM::Query::PQF`
  - `ZOOM::Options`, `ZOOM::Connection`, `ZOOM::ResultSet`, `ZOOM::Record`
  - `ZOOM::Event::ZEND`, `ZOOM::event`, and `create` import bridge.
2. Returns safe no-op results where native Z39.50 behavior is unavailable.
3. Prevents fatal compile/runtime errors in CGI and startup paths while preserving HTTP service availability.

What the shim is not:

- It is not a full YAZ implementation.
- It is not intended to emulate full remote Z39.50 semantics.

Operational guidance:

1. Keep `APPLY_KOHA_PATCHES=no` by default and use only when explicitly needed.
2. Rebuild the Alpine image after any shim change:

```bash
docker compose -f docker-compose-alpinekoha.yml build koha
docker compose -f docker-compose-alpinekoha.yml up -d
```

3. Validate with:

```bash
bash tests/run_all_tests.sh
KOHA_ELASTICSEARCH=no APPLY_KOHA_PATCHES=no bash tests/run_integration_deterministic.sh
```

Related tracker entry:

- `docs/TRACKER/2026-07-24 — Alpine OPAC 500 remediation, ZOOM shim hardening, and test-suite stabilization.md`

---

## Development Workflow

### Setting Up Development Environment

```bash
# 1. Clone/checkout Koha repository
cd /mnt/beckie2/DEVELOPMENT/koha-docker
git clone https://github.com/Koha-Community/Koha.git koha
cd koha && git checkout -b develop origin/develop

# 2. Configure environment
cd ..
cp env/template.env env/.env
# Edit env/.env with local paths

# 3. Build and start
docker compose -f docker-compose-alpinekoha.yml build
docker compose -f docker-compose-alpinekoha.yml up -d

# 4. Monitor bootstrap
docker compose -f docker-compose-alpinekoha.yml logs -f koha
```

### Live Code Development

**With `SYNC_REPO` mount, your edits appear immediately:**

```bash
# Edit Koha files locally
nano /mnt/beckie2/DEVELOPMENT/koha-docker/koha/C4/SomeModule.pm

# Changes are visible in container at /kohadevbox/koha/C4/SomeModule.pm
# Perl scripts reload on next request (no restart needed)

# For CSS/JS changes, rebuild assets
docker compose -f docker-compose-alpinekoha.yml exec koha \
  bash -c 'cd /kohadevbox/koha && yarn build'
```

### Running Tests

```bash
# Run Koha test suite
docker compose -f docker-compose-alpinekoha.yml exec koha \
  prove -l /kohadevbox/koha/t/db_dependent/Auth.t

# Run specific test file
docker compose -f docker-compose-alpinekoha.yml exec koha \
  perl -I/kohadevbox/koha/lib -I/kohadevbox/koha/t/lib \
  /kohadevbox/koha/t/db_dependent/Api/Auth.t
```

### Debugging Perl Code

```bash
# Enable debugger in run.sh (edit and rebuild)
# Or use simple debugging:
docker compose -f docker-compose-alpinekoha.yml exec koha \
  perl -d -I/kohadevbox/koha/lib /kohadevbox/koha/svc/script.pl

# Print debugging
# Add to Perl code: warn "DEBUG: $variable";
# Check logs: docker compose logs koha | grep DEBUG
```

### Contributing Changes

```bash
# 1. Create feature branch
cd koha
git checkout -b feature/my-feature

# 2. Make changes and test locally
# ... edit files ...

# 3. Commit changes
git add .
git commit -m "Feature: description"

# 4. Push to fork
git push origin feature/my-feature

# 5. Create pull request on GitHub
```

## Production Deployment

### Pre-Deployment Checklist

- [ ] All modules compile without "Can't locate" errors
- [ ] Database migrates cleanly (check logs)
- [ ] Both HTTP ports respond with 200 OK
- [ ] SSL certificates are current and valid
- [ ] Environment variables are secured (change default passwords)
- [ ] Backup database connection string and certificates

### Deployment Steps

```bash
# 1. Update image tag in docker-compose-alpinekoha.yml
KOHA_ALPINE_IMAGE_TAG=kosson/koha-alpine:26.11-prod

# 2. Build final image
docker compose -f docker-compose-alpinekoha.yml build --no-cache

# 3. Tag and push to registry
docker tag kosson/koha-alpine:26.11 kosson/koha-alpine:26.11-prod
docker push kosson/koha-alpine:26.11-prod

# 4. Deploy on target host
docker compose -f docker-compose-alpinekoha.yml \
  -f docker-compose.prod.yml \
  up -d

# 5. Verify
docker compose -f docker-compose-alpinekoha.yml ps
curl http://localhost:8080/
curl http://localhost:8081/
```

### Scaling & Load Balancing

For multi-server deployment, use:
- **Traefik** (included in `traefik/`) for reverse proxy
- **Separate database** (external MariaDB or managed service)
- **Shared storage** (NFS for Koha files)
- **Session store** (Redis for distributed sessions)

See `traefik/README.md` for reverse proxy setup.

## Support & Documentation

| Resource | Location | Purpose |
|----------|----------|---------|
| Alpine Migration Notes | `docs/Alpine-migration/` | Historical development process |
| Koha Documentation | https://koha-community.org/documentation | Official Koha guides |
| Alpine Linux | https://alpinelinux.org/docs/ | Alpine-specific information |
| Docker Docs | https://docs.docker.com/ | Docker and compose reference |
| Koha Wiki | https://wiki.koha-community.org/ | Community knowledge base |


## Version Information

- **Alpine Base:** 3.24.1
- **Koha Image:** kosson/koha-alpine:26.11
- **MariaDB:** 10.11
- **RabbitMQ:** 3-management
- **Node.js:** Latest stable (Alpine apk)
- **Perl:** 5.x (Alpine apk)
- **Last Updated:** 2026-07-23

---

## License

This Alpine Docker setup follows Koha's licensing (GPL v3). SSL certificates are self-signed for development purposes.

## Contributing

Improvements, bug reports, and patches welcome! Submit to the koha-docker repository.