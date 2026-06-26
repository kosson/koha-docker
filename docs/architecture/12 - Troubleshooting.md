---
title: "Troubleshooting"
tags: [troubleshooting, diagnostics, netcheck.sh, opensearch-errors, mariadb-errors, koha-errors, network-issues, traefik-issues, recovery, password-sync, memlock, oom]
---

# Troubleshooting

Common issues and how to diagnose/fix them.

---

## Diagnostic Tool: netcheck.sh

The `netcheck.sh` script tests every connection path in the stack.

```bash
cd ~/Documents/koha-docker
bash netcheck.sh
```

### Output Summary

- PASS (green) — connection verified
- FAIL (red) — connection failed, likely root cause
- WARN (yellow) — unexpected but may be normal
- INFO (blue) — context information

### What It Tests (10 sections)

1. **Required tools** — docker, curl, nc, openssl, python3
2. **Docker networks** — frontend, opensearch-36_osearch, knonikl, kohanet
3. **Container status** — traefik, os01-os05, dashboards, db, memcached, koha
4. **OpenSearch (host → os01:9200)** — TCP, HTTPS, cluster health, node count, TLS expiry
5. **OpenSearch (Koha → os01:9200)** — TCP from inside koha, HTTPS auth, KOHA_ELASTICSEARCH flag
6. **MariaDB** — mysqladmin ping, database exists, tables present, user exists, TCP from koha
7. **Memcached** — running, TCP from koha, stats response
8. **Traefik** — ping endpoint, API reachable, router registration (koha-opac, koha-staff, dashboards), port open
9. **Koha direct (OPAC/Staff)** — TCP + HTTP response on ports 8080/8081

---

## Common Errors

### OpenSearch Won't Start / Cluster Stuck Yellow

**Symptoms**: OpenSearch nodes don't join, cluster health stays yellow or red, or os01 never becomes healthy.

**Causes**:

1. **insufficient RAM** — 5 nodes + MariaDB + Koha needs 22+ GB host RAM
   ```bash
   # Check available RAM
   free -h
   # OpenSearch heap: 1g per node x 5 = 5GB minimum
   ```

2. **memlock ulimit failure** — rootless Docker can't set unlimited memlock
   ```bash
   # Fix in OpenSearch-3.6/docker-compose.yml:
   # Remove the ulimits block (memlock)
   # Set bootstrap.memory_lock=false in opensearch.yml
   # See TRACKER.md 2026-06-08 entry
   ```

3. **Certificate issues** — TLS handshake fails
   ```bash
   # Check cert expiry
   openssl x509 -in OpenSearch-3.6/assets/ssl/root-ca.pem -noout -dates

   # Check cert format (not a directory)
   file OpenSearch-3.6/assets/ssl/os01.pem
   # Should say "PEM certificate", NOT "directory"

   # Regenerate certs
   ./stack.sh start  # triggers ensure_opensearch_certs()
   ```

4. **Port conflict** — 9200 or 9600 already in use
   ```bash
   lsof -i :9200
   lsof -i :9600
   ```

5. **Disk space** — insufficient disk for OpenSearch data
   ```bash
   df -h ~/Documents/koha-docker/OpenSearch-3.6/assets/opensearch/data/
   ```

### MariaDB Takes Forever to Start

**Symptoms**: `wait_db_ready()` loops for the full 60 seconds, or fails.

**Causes**:

1. **Volume initialization** — First run needs to initialize the data dir
   ```bash
   # Just wait. First run takes longer.
   # Subsequent starts are fast.
   ```

2. **Permission issues on volume**
   ```bash
   # Check volume permissions
   docker run --rm -v koha-db-data:/data alpine ls -la /data/
   ```

3. **Wrong password in env file**
   ```bash
   grep KOHA_DB_ROOT_PASSWORD env/.env
   ```

### Koha Container Crashes on Startup

**Symptoms**: `docker logs koha-docker-koha-1` shows a crash or exit.

**Causes**:

1. **DB not ready** — Koha starts before DB is up
   ```bash
   # The wait_db_ready() function should prevent this
   # Check if DB is running:
   docker ps | grep db
   ```

2. **OpenSearch not ready** — Koha can't connect to OS
   ```bash
   # Check OS is running:
   curl -sk -u admin:changeme https://localhost:9200/_cluster/health
   ```

3. **Missing config files** — Template files missing or CRLF broken
   ```bash
   docker exec koha-docker-koha-1 ls -la /kohadevbox/templates/
   docker exec koha-docker-koha-1 file /kohadevbox/run.sh
   ```

4. **Insufficient RAM** — Out of memory killer
   ```bash
   dmesg | grep -i oom
   ```

5. **Wrong SYNC_REPO path**
   ```bash
   grep SYNC_REPO env/.env
   # Should point to an existing directory with Koha source
   ls -la ~/Documents/koha/
   ```

### Can't Access Koha Web UI

**Symptoms**: Browser shows connection refused or timeout.

**Causes**:

1. **Koha not fully started** — Apache might still be booting
   ```bash
   docker logs koha-docker-koha-1 | tail -20
   # Wait for: "koha-testing-docker has started up"
   ```

2. **Wrong port** — Check which port is configured
   ```bash
   grep KOHA_OPAC_PORT env/.env   # OPAC default: 8080
   grep KOHA_INTRANET_PORT env/.env  # Staff default: 8081
   ```

3. **Traefik not routing** — If using Traefik, check routing
   ```bash
   # Check Traefik dashboard
   curl http://localhost:8083/api/http/routers | python3 -m json.tool
   # Look for koha-opac and koha-staff routers
   ```

4. **Wrong Host header** — If using Traefik, the Host header must match
   ```bash
   # Check KOHA_DOMAIN
   grep KOHA_DOMAIN env/.env
   # Default: .myDNSname.org
   # Access via: http://kohadev.myDNSname.org:8000
   ```

5. **Port blocked** — Port already in use
   ```bash
   lsof -i :8080
   lsof -i :8081
   ```

### OpenSearch Authentication Fails (401)

**Symptoms**: `curl -u admin:password https://localhost:9200` returns 401.

**Causes**:

1. **Password mismatch** — `env/.env` and `OpenSearch-3.6/.env` have different passwords
   ```bash
   # Stack.sh should sync these, but check:
   grep OPENSEARCH_INITIAL_ADMIN_PASSWORD OpenSearch-3.6/.env
   grep KOHA_DB_PASSWORD env/.env   # (synced from OS password)
   ```

2. **Password was changed but not synced**
   ```bash
   # Force resync by restarting:
   ./stack.sh stop
   ./stack.sh start
   ```

3. **Initial admin wasn't set up** — Fresh start without auth bootstrap
   ```bash
   # Run initial API calls:
   curl -X PUT -u admin:changeme https://localhost:9200/_cluster/settings \
     -H 'Content-Type: application/json' \
     -d '{"persistent": {"authcz.admin_dn": [...]}}'
   ```

### Network Issues

**Symptoms**: Containers can't reach each other.

**Causes**:

1. **External networks missing**
   ```bash
   docker network ls | grep -E 'frontend|knonikl|opensearch'
   # If missing: stack.sh should auto-create them
   # Manual fix:
   docker network create frontend
   docker network create knonikl
   docker network create opensearch-36_osearch
   ```

2. **Koha not on opensearch-36_osearch**
   ```bash
   docker inspect koha-docker-koha-1 --format '{{range .NetworkSettings.Networks}}{{.NetworkName}}{{println}}{{end}}'
   # Should list: kohanet, knonikl, opensearch-36_osearch, frontend
   ```

3. **DNS resolution fails**
   ```bash
   docker exec koha-docker-koha-1 nslookup os01
   docker exec koha-docker-koha-1 nslookup db
   ```

4. **Firewall blocking ports**
   ```bash
   # Check if ports are open
   nc -zv localhost 9200
   nc -zv localhost 3306
   nc -zv localhost 8080
   ```

### Traefik Not Routing

**Symptoms**: All requests through Traefik time out or return 404.

**Causes**:

1. **Koha not on frontend network**
   ```bash
   docker inspect koha-docker-koha-1 --format '{{range .NetworkSettings.Networks}}{{.NetworkName}}{{println}}{{end}}'
   ```

2. **Labels missing**
   ```bash
   docker inspect koha-docker-koha-1 --format '{{json .Config.Labels}}' | python3 -m json.tool | grep traefik
   ```

3. **Traefik not started**
   ```bash
   docker ps | grep traefik
   docker logs traefik | tail -30
   ```

4. **Wrong entrypoint**
   ```bash
   grep TRAEFIK_HTTP_PORT traefik/.env
   # Default: 8000
   ```

---

## Recovery Procedures

### Full Recovery (Everything Broken)

```bash
# 1. Stop everything
./stack.sh reset

# 2. Clean up dangling resources
docker system prune -f
docker volume prune -f

# 3. Start fresh
./stack.sh start --build
```

### Recover OpenSearch Cluster

```bash
# 1. Stop OpenSearch
docker compose -f OpenSearch-3.6/docker-compose.yml down

# 2. Check data integrity
ls -la OpenSearch-3.6/assets/opensearch/data/

# 3. Start only os01 first (it's the cluster manager)
docker compose -f OpenSearch-3.6/docker-compose.yml up -d os01

# 4. Wait for green
# 5. Start remaining nodes
docker compose -f OpenSearch-3.6/docker-compose.yml up -d os02 os03 os04 os05
```

### Recover MariaDB

```bash
# 1. Stop koha
docker compose -f docker-compose.yml down koha

# 2. Restart DB
docker compose -f docker-compose.yml up -d db

# 3. Wait for ready
# 4. Restart koha
docker compose -f docker-compose.yml up -d koha
```

### Reset Just the Koha Instance

```bash
# 1. Stop koha
docker compose -f docker-compose.yml stop koha

# 2. Reset DB
./stack.sh restart   # This resets DB + recreates koha

# OR manually:
docker exec koha-docker-db-1 \
  mysql -uroot -p'password' -e "DROP DATABASE koha_kohadev"
docker exec koha-docker-db-1 \
  mysql -uroot -p'password' \
  -e "CREATE DATABASE koha_kohadev DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci"
```
