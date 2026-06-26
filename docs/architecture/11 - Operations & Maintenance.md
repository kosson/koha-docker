---
title: "Operations & Maintenance"
tags: [operations, maintenance, start, stop, restart, reset, logs, image-management, container-management, health-checks, disk-management, configuration-changes]
---

# Operations & Maintenance

Daily operations for the Koha Docker stack.

---

## Startup

### First-Time Start (with build)

```bash
cd ~/Documents/koha-docker
./stack.sh start --build
```

This will:
1. Check prerequisites (docker, compose, env files)
2. Create Docker networks if missing
3. Generate TLS certificates if missing
4. Sync credentials between env files
5. Build OpenSearch image (kosson/opensearch-icu)
6. Start 5-node OpenSearch cluster (wait for green)
7. Start MariaDB + Memcached (wait for ready)
8. Reset database (drop/create/grant)
9. Start Koha container
10. Tail logs, print URL summary on startup

**Time to first run**: 5-15 minutes (depends on OpenSearch build + startup)

### Resume (no rebuild)

```bash
./stack.sh start --no-fresh-db
```

Skips database reset. Useful when restarting after a `stop`.

### No Demo Data

```bash
./stack.sh start --no-demo-data
```

Faster startup. Skips loading 436 sample MARC records.

### Build Only

```bash
./stack.sh build
```

Builds the OpenSearch image without starting any services.

---

## Stopping

### Graceful Stop

```bash
./stack.sh stop
```

Stops all services in the right order:
1. Traefik (stop routing)
2. Koha (stop app)
3. OpenSearch cluster (stop nodes)
4. MariaDB (stop DB)
5. Memcached (stop cache)

Data is preserved in volumes and bind mounts.

### Quick Kill

```bash
docker compose -f docker-compose.yml down
docker compose -f OpenSearch-3.6/docker-compose.yml down
docker compose -f traefik/docker-compose.yaml down
```

⚠️ Not graceful. OpenSearch may need to recover on next start.

---

## Restart

### Quick Restart (DB reset + Koha only)

```bash
./stack.sh restart
```

- Resets the database (drop/create/grant)
- Recreates the Koha container
- Does NOT restart OpenSearch
- Fast (seconds, not minutes)

### Full Restart

```bash
./stack.sh stop
./stack.sh start --no-fresh-db
```

Graceful full-cycle restart.

---

## Reset (Destructive)

```bash
./stack.sh reset
```

Confirms with user ("Type 'yes' to confirm:"). Then:

1. `docker compose down --volumes` (koha stack)
2. `docker compose down --volumes` (OpenSearch stack)
3. `docker compose down --volumes` (Traefik)

**Result**: Everything removed. All containers, all volumes, all data. Images preserved.

**After reset**: Run `./stack.sh start --build` to rebuild from scratch.

---

## Logs

### Tail Koha Logs

```bash
./stack.sh logs
```

Runs `docker compose logs -f koha`.

### View OpenSearch Logs

```bash
docker compose -f OpenSearch-3.6/docker-compose.yml logs -f
docker compose -f OpenSearch-3.6/docker-compose.yml logs -f os01
docker compose -f OpenSearch-3.6/docker-compose.yml logs -f os02
```

### View Traefik Logs

```bash
docker compose -f traefik/docker-compose.yaml logs -f
```

### View DB Logs

```bash
docker compose -f docker-compose.yml logs -f db
```

### Specific Log Files

```bash
# Koha Apache error log
docker exec koha-docker-koha-1 tail -f /var/log/apache2/error.log

# Koha verbose log
docker exec koha-docker-koha-1 tail -f /var/log/koha/kohadev/koha-httpd-errorlog

# OpenSearch node logs
docker exec os01 tail -f /usr/share/opensearch/logs/koha-cluster.log

# OpenSearch audit log (security events)
docker exec os01 tail -f /usr/share/opensearch/logs/koha-cluster_audit.log

# MariaDB slow query log
docker exec koha-docker-db-1 tail -f /var/log/mysql/slow-query.log
```

---

## Image Management

### Check Images

```bash
docker images | grep -E 'koha|opensearch|mos'
```

Expected local images:
- `kosson/koha-ubuntu:latest`
- `kosson/opensearch-icu:3.6.0`

### Rebuild Koha Image

```bash
docker compose -f docker-compose.yml build koha
```

### Rebuild OpenSearch Image

```bash
docker compose -f OpenSearch-3.6/docker-compose.yml build os01
```

### Remove Stale Images

```bash
docker image prune -f
```

---

## Container Management

### Inspect Container

```bash
docker inspect koha-docker-koha-1
docker inspect os01
docker inspect koha-docker-db-1
```

### Shell into Container

```bash
docker exec -it koha-docker-koha-1 bash
docker exec -it koha-docker-db-1 bash
docker exec -it os01 bash
```

### Restart Individual Container

```bash
docker restart koha-docker-koha-1
docker restart os01
```

### View Resource Usage

```bash
docker stats
docker stats koha-docker-koha-1 os01 os02 os03 os04 os05 koha-docker-db-1
```

### View Disk Usage

```bash
docker system df
docker volume ls
docker volume inspect koha-db-data
```

---

## Configuration Changes

### After Modifying env/.env

```bash
./stack.sh restart
```

For env changes that affect OpenSearch (password changes), use:
```bash
./stack.sh stop
./stack.sh start --build
```

### After Modifying Dockerfile

```bash
docker compose -f docker-compose.yml build koha
./stack.sh restart
```

### After Modifying OpenSearch Configs

```bash
docker restart os01  # Graceful rolling restart
docker restart os02
docker restart os03
docker restart os04
docker restart os05
```

Or full restart for significant config changes:
```bash
./stack.sh stop
./stack.sh start --no-fresh-db
```

### After Modifying Traefik Config

```bash
docker restart traefik
```

Traefik picks up Docker label changes automatically, but static config changes require a restart.

---

## Health Checking

### Manual Health Checks

```bash
# OpenSearch cluster health
curl -sk -u admin:changeme https://localhost:9200/_cluster/health | python3 -m json.tool

# DB connectivity
docker exec koha-docker-db-1 mysql -uroot -p'password' -e 'SELECT 1'

# Koha OPAC
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/

# Koha Staff
curl -s -o /dev/null -w "%{http_code}" http://localhost:8081/

# Memcached stats
printf 'stats\r\nquit\r\n' | nc -w2 localhost 11211 | head -5

# Traefik ping
wget -q -O- http://127.0.0.1:8082/ping
```

### Full Diagnostic

```bash
./netcheck.sh
```

Runs all health checks for every connection path. See [[12 - Troubleshooting]].

---

## Disk Management

### OpenSearch Data Dirs

```bash
ls -la OpenSearch-3.6/assets/opensearch/data/
# os01data, os02data, os03data, os04data, os05data
```

Each dir contains the Lucene index. Deleting = losing search data.

### Clear Koha Cache

```bash
docker exec koha-docker-koha-1 koha-reload-cache kohadev
```

### Clear Memcached

```bash
docker exec koha-docker-memcached-1 echo "flush_all" | nc -w2 localhost 11211
```

### Monitor Disk Usage

```bash
du -sh ~/Documents/koha-docker/OpenSearch-3.6/assets/opensearch/data/*/
du -sh ~/Documents/koha-docker/koha/
du -sh ~/Documents/koha-docker/OpenSearch-3.6/assets/ssl/
```
