---
title: "MariaDB & Database"
tags: [mariadb, database, schema, koha_kohadev, sql-mode, backup, restore, data-volume, initialization, connection-troubleshooting]
---
# MariaDB & Database

MariaDB 10.11 runs the relational data store for the Koha instance.

## Container Setup

| Property | Value |
|---|---|
| Image | `mariadb:10.11` |
| Container name | `koha-docker-db-1` |
| Volume | `koha-db-data` → `/var/lib/mysql` |
| Network | `kohanet` only |
| Ports | Not exposed to host |

### SQL Mode

```
STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
```

Set via `command:` in docker-compose.yml. This enforces strict SQL validation.

## Database Schema

| Property | Value |
|---|---|
| Database name | `koha_kohadev` |
| User | `koha_kohadev` |
| Charset | `utf8mb4` |
| Collation | `utf8mb4_unicode_ci` |

## Database Initialization Flow

### 1. Container Start

`docker compose up -d db memcached`

MariaDB starts and waits for the data volume to be initialized.

### 2. Ready Check (stack.sh)

```bash
wait_db_ready() {
  for i in $(seq 1 30); do
    if docker exec koha-docker-db-1 \
        mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
        -e 'SELECT 1' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "MariaDB failed to start within 60 seconds"
}
```

⚠️ Uses **authenticated SQL** (`SELECT 1`), NOT `mysqladmin ping`. This avoids a race condition documented in TRACKER.md where the TCP port opens but the database engine isn't ready yet.

### 3. Database Reset (stack.sh)

```bash
reset_database() {
  # Drop database
  docker exec koha-docker-db-1 \
    mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
    -e "DROP DATABASE IF EXISTS koha_kohadev"

  # Create database
  docker exec koha-docker-db-1 \
    mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
    -e "CREATE DATABASE koha_kohadev DEFAULT CHARACTER SET utf8mb4 DEFAULT COLLATE utf8mb4_unicode_ci"

  # Grant privileges
  docker exec koha-docker-db-1 \
    mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
    -e "GRANT ALL PRIVILEGES ON koha_kohadev.* TO 'koha_kohadev'@'%'"

  # Reload grant tables
  docker exec koha-docker-db-1 \
    mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES"
}
```

### 4. Koha Container Creates the Schema

When the Koha container starts (run.sh), it:
1. Checks if the DB is ready
2. Creates the Koha instance via `koha-create` (called by the Koha service)
3. Installs the schema (hundreds of tables)
4. Creates system preferences
5. Creates default users (superlibrarian, etc.)

## Koha Database Tables

The Koha database contains:

| Category | Examples |
|---|---|
| Bibliographic | `biblio`, `biblioitems`, `marcbiblionprimary`, `items` |
| Authority | `authorities`, `auth_fieldmap` |
| Circulation | `circulation`, `reserve`, `accountoffsets` |
| Patrons | `borrowers`, `borrowernum`, `address` |
| Acquisitions | `aqs`, `aqorders`, `aqbooksellers` |
| Serials | `serials`, `serialitems` |
| System | `systempreferences`, `branches`, `permissions` |
| Search/Discovery | `breadcrumb`, `koha_fields` |
| Reports | `reports`, `report_bundles` |

After loading demo data: ~400+ tables with sample records.

## Accessing the Database

### From Host (not recommended for production)

```bash
# Via docker exec
docker exec koha-docker-db-1 \
  mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" koha_kohadev

# Check databases
SHOW DATABASES;

# Check tables
USE koha_kohadev;
SHOW TABLES;

# Row count
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='koha_kohadev';
```

### From Koha Container

```bash
docker exec koha-docker-koha-1 \
  mysql -ukoha_kohadev -p"${KOHA_DB_PASSWORD}" -h db koha_kohadev
```

### From Koha Perl Scripts

```bash
# In Koha instance config:
# /etc/koha-kohadev/koha-conf.xml
# Contains DB connection: host=db, port=3306, db=koha_kohadev

# Via Koha CLI
koha-admin --db-host=db --db-port=3306 --db-name=koha_kohadev --db-user=koha_kohadev --db-pass=...
```

## Network Connectivity

### Koha → DB

Verified by `netcheck.sh`:

```bash
# From inside koha container
docker exec koha-docker-koha-1 bash -c "nc -z -w3 db 3306"
```

Expected: PASS (same `kohanet` network)

### DB → External

Not configured. The DB has no external network access — it's only reachable from containers on `kohanet` (i.e., koha and memcached).

## Troubleshooting

### Database Not Creating Tables

If `netcheck.sh` reports "Database has no tables", the Koha container hasn't finished initialization yet. Check:

```bash
docker logs koha-docker-koha-1
# Look for: "koha-testing-docker has started up"
```

### Connection Refused

If Koha cannot connect to DB:

```bash
# Check if DB is on the same network
docker network inspect kohanet --format '{{range .Containers}}{{.Name}} {{end}}'

# Check DB container logs
docker logs koha-docker-db-1

# Check if port is open from koha
docker exec koha-docker-koha-1 bash -c "nc -zv db 3306"
```

### Wrong Password

If `KOHA_DB_ROOT_PASSWORD` doesn't match the DB:

```bash
# Check what's in the env file
grep KOHA_DB_ROOT_PASSWORD env/.env

# Check the OpenSearch-3.6/.env for cross-sync
grep KOHA_DB_ROOT_PASSWORD OpenSearch-3.6/.env 2>/dev/null || echo "Not found"
```

## Backup

The database is persisted in the named volume `koha-db-data`. To back up:

```bash
# Dump to file
docker exec koha-docker-db-1 \
  mysqldump -uroot -p"${KOHA_DB_ROOT_PASSWORD}" \
  --single-transaction koha_kohadev > koha-backup.sql

# Restore from dump
cat koha-backup.sql | \
  docker exec -i koha-docker-db-1 \
  mysql -uroot -p"${KOHA_DB_ROOT_PASSWORD}" koha_kohadev
```

To persist the volume to disk:

```bash
docker run --rm -v koha-db-data:/data -v $(pwd):/backup alpine tar czf /backup/koha-db-backup.tar.gz -C /data .
```
