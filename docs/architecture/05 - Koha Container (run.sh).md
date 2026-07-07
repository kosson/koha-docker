---
title: "Koha Container Entrypoint (run.sh)"
tags: [run.sh, entrypoint, initialization, crlf-normalization, package-installation, database-probe, elasticsearch-config, apache-setup, milestone-logging, envsubst]
---
# Koha Container Entrypoint (run.sh)

Location: `/home/kosson/Documents/koha-docker/files/run.sh` (585 lines)
This is the container's CMD: `["/bin/bash", "/kohadevbox/run.sh"]`

## Purpose

The entrypoint script performs all runtime initialization: URL generation, package installation, DB probing, OpenSearch readiness, config templating, and service startup. It runs once per container start.

## Startup Sequence

```
1. CRLF NORMALIZE
   └── sed -i 's/\r$//' all .sh, .pl, .cgi, .inc, .pm files
      └── Purpose: fix Windows line endings from git checkout or editor

2. URL GENERATION
   ├── KOHA_OPAC_URL = http://localhost:KOHA_OPAC_PORT
   ├── KOHA_INTRANET_URL = http://localhost:KOHA_INTRANET_PORT
   ├── KOHA_OPAC_HOSTNAME = KOHA_INSTANCE + KOHA_DOMAIN
   └── KOHA_INTRANET_HOSTNAME = KOHA_INSTANCE + KOHA_INTRANET_SUFFIX + KOHA_DOMAIN

3. INSTALL PACKAGES
   ├── if LOAD_PACKAGES=yes:
   │   ├── run.sh is the only package installer (NOT install-packages)
   │   ├── apt-install-retry for deb packages
   │   └── cpanm for Perl modules
   └── if INSTALL_MISSING_FROM_CPMFILE=yes:
       └── cpanm --installdeps .  (in Koha source dir)

4. CONFIG FILE GENERATION
   └── Template system:
       ├── env/defaults.env → /etc/koha-kohadev/koha-conf.xml (via envsubst)
       ├── env/defaults.env → Apache config (via envsubst)
       └── env/defaults.env → Koha instance config
       └── Templates live in /kohadevbox/templates/

5. DATABASE PROBE
   └── while ! mysql -uroot -p"KOHA_DB_ROOT_PASSWORD" -h db -e 'SELECT 1':
       └── sleep 2, max retries (60 seconds)
       └── Uses authenticated SQL (not mysqladmin ping — race condition fix)

6. ELASTICSEARCH/OPENSEARCH CONFIG
   ├── if KOHA_ELASTICSEARCH=yes:
   │   ├── set KOHA_ELASTICSEARCH_HOSTS=http://os01:9200 (or HTTPS with cert)
   │   ├── enable koha-elasticsearch in /etc/koha/kohadev/koha-sites.conf
   │   └── if OPENSEARCH_CA_CERT exists: copy to /kohadevbox/
   └── else:
       └── disable koha-elasticsearch

7. REBUILD OPENSEARCH INDEX
   └── if REBUILD_OPENSEARCH_INDEX=yes:
       └── koha-index-definition --rebuild --verbose
       └── Or: perl /usr/share/koha/misc/elasticsearch/rebuild_index.pl

8. CONFIGURE APACHE
   ├── if ENABLE_APACHE=yes:
   │   ├── envsubst on Apache template → /etc/koha-kohadev/apache.conf
   │   ├── a2ensite koha-kohadev
   │   └── a2enmod rewrite headers proxy_http cgi
   └── if ENABLE_APACHE_SSL=yes:
       └── (SSL config — commented out by default)

9. START SERVICES
   ├── if START_APACHE=yes:
   │   ├── service apache2 start
   │   └── service apache2 reload
   ├── wait for MESSAGE_BROKER_HOST:MESSAGE_BROKER_PORT to become available
   │   └── RabbitMQ is now an external sibling container
   ├── if START_KOHA_SERVICE=yes:
   │   └── koha-service kohadev start
   └── if START_KOHA_JOB_WORKER=yes:
       └── koha-job-worker kohadev start

10. MILESTONE LOG
    └── echo "koha-testing-docker has started up"
        └── This is the marker stack.sh waits for (log scraping)
```

## Package Installation Modes

### Mode A: LOAD_PACKAGES=yes
Uses the `run.sh` built-in installer (not the retired `install-packages` script).

### Mode B: INSTALL_MISSING_FROM_CPMFILE=yes
Runs `cpanm --installdeps .` from the Koha source directory. Installs all modules listed in `cpanfile`.

## Config System

The config files use **envsubst** for variable expansion. The template files are:

| Template Source | Output Target | Variables Expanded From |
|---|---|---|
| `/kohadevbox/templates/apache.conf` | `/etc/koha-kohadev/apache.conf` | env/.env vars |
| `/kohadevbox/templates/koha-conf.xml` | `/etc/koha-kohadev/koha-conf.xml` | env/.env vars |

The templates reference `${KOHA_INSTANCE}`, `${KOHA_DB_PASSWORD}`, `${KOHA_OPAC_PORT}`, etc.

## Key Design Decisions

1. **Single entrypoint, not multiple CMDs**: Everything runs in one script rather than using a process manager like supervisor. Services are started with `service` commands.
2. **CRLF normalization at runtime too**: Even though the Dockerfile normalizes at build time, run.sh does it again. This catches CRLF from git checkout or editor changes after the image was built.
3. **Authenticated SQL for DB probe**: Uses `mysql -uroot -p... -e 'SELECT 1'` instead of `mysqladmin ping`. This fixes a race condition where the port opens before the database is ready (documented in TRACKER.md).
4. **Milestone log for stack.sh**: The string `koha-testing-docker has started up` is the signal that `stack.sh` scans for. When found, it prints the URL summary.
5. **Opensearch CA cert handling**: If `OPENSEARCH_CA_CERT` is set, the cert is copied into the container and OpenSearch is configured with HTTPS.

## Important Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `LOAD_PACKAGES` | Install additional packages | no |
| `INSTALL_MISSING_FROM_CPMFILE` | Run cpanm --installdeps . | no |
| `KOHA_ELASTICSEARCH` | Enable OpenSearch search | no |
| `REBUILD_OPENSEARCH_INDEX` | Rebuild search index | yes |
| `START_APACHE` | Start Apache HTTPD | yes |
| `MESSAGE_BROKER_HOST` | RabbitMQ host | rabbitmq |
| `MESSAGE_BROKER_PORT` | RabbitMQ STOMP port | 61613 |
| `MESSAGE_BROKER_USER` | RabbitMQ user | koha |
| `MESSAGE_BROKER_PASS` | RabbitMQ password | password |
| `MESSAGE_BROKER_VHOST` | RabbitMQ vhost | koha_kohadev |
| `START_RABBITMQ` | Legacy local-broker toggle | no-op in external-broker mode |
| `START_KOHA_SERVICE` | Start Koha service | yes |
| `START_KOHA_JOB_WORKER` | Start job worker | yes |
| `SYNC_REPO` | Path to Koha source | /home/kosson/Documents/koha |
