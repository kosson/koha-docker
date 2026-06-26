---
title: "Demo Data & MARC Import"
tags: [demo-data, marc, marc21, insert_data.pl, opensearch-index, z3950, patron-credentials, sample-data, data-loading]
---

# Demo Data & MARC Import

How sample data is loaded and how to manage MARC records.

---

## Demo Data Loading

### How It Works

When `LOAD_DEMO_DATA=yes` (default), `stack.sh` triggers the demo data import after the Koha container starts.

### What Gets Loaded

- **436 MARC bibliographic records** — Sample books, articles, media
- **Authorities** — Name and subject authority records
- **Items** — Library items linked to bibliographic records
- **Patrons** — Sample library users (borrowers with cards)
- **Branches** — Sample library branches
- **Circulation rules** — Loan periods, fine schedules

### Size

- Approximately **400KB** of MARC data
- Takes a few minutes to import

### Import Process

1. Koha container starts (run.sh)
2. Koha instance is created (koha-create)
3. Schema is installed (hundreds of tables)
4. `misc4dev/insert_data.pl` is executed
5. MARC records are inserted into `biblio`, `items`, `authority` tables
6. Patrons are created in `borrowers` table

### Control Variables

| Variable | Purpose | Default |
|---|---|---|
| `LOAD_DEMO_DATA` | Enable demo data loading | `yes` |
| `KOHA_INSTANCE` | Instance name for data | `kohadev` |

### Disabling Demo Data

```bash
./stack.sh start --no-demo-data
```

Or set in `env/.env`:
```
LOAD_DEMO_DATA=no
```

### Re-loading Demo Data

```bash
# Stop the stack
./stack.sh stop

# Reset the database (drops all data)
./stack.sh reset

# Start fresh with demo data
./stack.sh start --build
```

---

## MARC Import Script

### Location

```
/misc4dev/insert_data.pl
```

The `misc4dev` repository is cloned into the Docker image at build time:
```dockerfile
RUN cd /kohadevbox \
    && git clone https://gitlab.com/koha-community/koha-misc4dev.git misc4dev
```

### Running insert_data.pl

```bash
# From inside the Koha container
docker exec koha-docker-koha-1 perl /kohadevbox/misc4dev/insert_data.pl

# With verbose output
docker exec koha-docker-koha-1 perl /kohadevbox/misc4dev/insert_data.pl --verbose

# For a specific instance
docker exec koha-docker-koha-1 perl /kohadevbox/misc4dev/insert_data.pl --instance kohadev
```

### What It Does

1. Connects to the Koha database
2. Reads MARC records from the sample data directory
3. Imports records using Koha's import API
4. Creates associated authorities, items, and patrons
5. Rebuilds the OpenSearch index (if enabled)

---

## OpenSearch Index Rebuilding

### Trigger Index Rebuild

```bash
# Via run.sh variable (on container start)
REBUILD_OPENSEARCH_INDEX=yes  # Set in env/.env

# Or manually after container is running
docker exec koha-docker-koha-1 koha-index-definition --rebuild --verbose
```

### Check Index Status

```bash
# From host
curl -sk -u admin:changeme https://localhost:9200/_cat/indices?v

# From inside Koha
docker exec koha-docker-koha-1 \
  curl -sk -u admin:changeme https://os01:9200/_cat/indices?v
```

### Index Names

Koha creates these indices in OpenSearch:
- `bibliographic` — Bibliographic records
- `authorities` — Authority records
- `items` — Library items
- Possibly others depending on Koha version and plugins

### Rebuild Speed

- First rebuild: slow (10+ minutes for 436 records with full text)
- Subsequent rebuilds: faster (incremental updates)

### Troubleshooting Index Issues

```bash
# Check OpenSearch cluster health
curl -sk -u admin:changeme https://localhost:9200/_cluster/health

# Check for errors in Koha logs
docker logs koha-docker-koha-1 | grep -i elastic

# Check if KOHA_ELASTICSEARCH is enabled
docker exec koha-docker-koha-1 echo $KOHA_ELASTICSEARCH
```

---

## Importing Custom MARC Records

### From a MARC File

```bash
# Copy MARC file into container
docker cp my-records.mrc koha-docker-koha-1:/tmp/my-records.mrc

# Use koha-marc-import (if available)
docker exec koha-docker-koha-1 koha-marc-import --file /tmp/my-records.mrc --instance kohadev
```

### From a MARCXML File

```bash
docker exec koha-docker-koha-1 koha-marc-import --file /tmp/my-records.xml --format marcxml --instance kohadev
```

### Via Koha Staff Interface

1. Log into Staff interface (http://localhost:8081)
2. Navigate to: **Administration** → **Import/Export** → **Z39.50/SRU Import**
3. Configure Z39.50 servers or upload MARC files
4. Import records

---

## Database Records After Import

### Check Record Count

```sql
-- Bibliographic records
SELECT COUNT(*) FROM biblio;

-- Authorities
SELECT COUNT(*) FROM authorities;

-- Items
SELECT COUNT(*) FROM items;

-- Patrons
SELECT COUNT(*) FROM borrowers;
```

### Sample Patron Credentials

```
Username: librarian
Password: librarian
(Admin/superlibrarian account)
```

---

## Pitfalls

1. **Slow first import** — The first import loads 436 records + authorities + items. This can take several minutes. Don't assume it's hung.

2. **OpenSearch index out of sync** — If records are imported but not indexed, they won't appear in search results. Rebuild the index after any bulk import.

3. **MARC encoding** — Ensure MARC files are in proper MARC-21 or MARCXML format. ISO-8859-1 encoding is standard for MARC-21.

4. **Authority control** — If authority control is enabled in Koha preferences, imported records may fail if authority records are missing. Check `AuthoritiesControl` system preference.

5. **MARC import without demo data** — If `LOAD_DEMO_DATA=no`, the sample MARC import step is skipped entirely. You'll need to import records manually.
