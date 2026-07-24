# Migration Summary: MariaDB SSL to Alpine-Native Structure

## Overview

Successfully migrated MariaDB SSL certificates from `files/mariadb-ssl/` to `files-alpine/mariadb-ssl/` and updated all project references. This makes the Alpine Docker setup more cohesive by keeping all Alpine-specific resources in a single directory structure.

## Changes Made

### 1. ✅ Folder Migration
- **Source:** `/files/mariadb-ssl/` (generic location)
- **Destination:** `/files-alpine/mariadb-ssl/` (Alpine-specific location)
- **Contents moved:**
  - `ca-cert.pem` — Root CA certificate
  - `ca-key.pem` — Root CA private key
  - `server-cert.pem` — Database server certificate
  - `server-key.pem` — Database server private key
  - `server-ext.cnf` — Certificate extensions (SANs)
  - `mariadb-ssl.cnf` — MySQL SSL configuration
  - `ca-cert.srl` — Certificate serial tracking

### 2. ✅ Docker Compose Updates
**File:** `docker-compose-alpinekoha.yml`

| Change | Location | Before | After |
|--------|----------|--------|-------|
| DB SSL volume | Line 15 | `./files/mariadb-ssl:/etc/mysql/ssl:ro` | `./files-alpine/mariadb-ssl:/etc/mysql/ssl:ro` |
| DB SSL config | Line 16 | `./files/mariadb-ssl/mariadb-ssl.cnf` | `./files-alpine/mariadb-ssl/mariadb-ssl.cnf` |
| Koha SSL mount | Line 51 | `./files/mariadb-ssl:/etc/mysql/ssl:ro` | `./files-alpine/mariadb-ssl:/etc/mysql/ssl:ro` |

### 3. ✅ Dockerfile Alpine Updates
**File:** `Dockerfile-Alpine`

Added new COPY command (line 437):
```dockerfile
COPY files-alpine/mariadb-ssl /etc/mysql/ssl
```

This bakes SSL certificates directly into the Docker image at build time.

### 4. ✅ Comprehensive Documentation
**File:** `README-ALPINE.md` (911 lines)

Complete guide covering:
- Quick start (3-step setup)
- SSL certificate management (generation, who/when/how)
- Project structure
- Environment configuration
- Starting and operating the system
- Architecture overview
- Troubleshooting guide
- Development workflow
- Production deployment

## Verification Results

### Build Status
```
✅ Image built successfully: kosson/koha-alpine:26.11
✅ All layers compiled without errors
✅ SSL certificates COPY stage successful (#63)
```

### Runtime Verification
```
✅ Containers running:
   - koha-docker-db-1 (MariaDB 10.11)
   - koha-docker-koha-1 (Koha Alpine)
   - koha-docker-memcached-1 (Cache)
   - koha-docker-rabbitmq-1 (Message broker)

✅ HTTP endpoints:
   - Port 8080 (OPAC): HTTP/1.1 200 OK
   - Port 8081 (Staff): HTTP/1.1 200 OK

✅ Bootstrap completion:
   "koha-testing-docker has started up and is ready to be enjoyed!"

✅ SSL certificates inside image:
   /etc/mysql/ssl/ contains all 7 required files
```

## Certificate Management Guide

### Who Creates SSL Certificates

| Role | Task | When | Method |
|------|------|------|--------|
| **First-time DevOps/Developer** | Generate root CA and server certs | During initial project setup | `openssl genrsa` + `openssl req` + `openssl x509` |
| **Image Builder** | Bake certs into Alpine image | During Docker build | `COPY files-alpine/mariadb-ssl /etc/mysql/ssl` |
| **Runtime** | Mount SSL files into MariaDB | At container startup | Docker compose volume mounts |
| **Certificate Renewal** | Replace expired certificates | Every 10 years or on expiration | Re-run generation process, rebuild image |

### Certificate Lifecycle

```
1. CREATION PHASE (One-time, first person)
   └─ Developer runs OpenSSL commands to generate CA and server certs
      (See README-ALPINE.md "Generating New Certificates")
      └─ Creates: ca-cert.pem, ca-key.pem, server-cert.pem, server-key.pem
      └─ Stores in: files-alpine/mariadb-ssl/

2. BUILD PHASE (Image builder)
   └─ Docker build process
      └─ COPY files-alpine/mariadb-ssl /etc/mysql/ssl
         └─ Certificates baked into image at /etc/mysql/ssl/

3. RUNTIME PHASE (Container startup)
   └─ Docker compose mounts certificates into MariaDB container
      └─ MariaDB loads SSL configuration from:
         - /etc/mysql/ssl/ca-cert.pem
         - /etc/mysql/ssl/server-cert.pem
         - /etc/mysql/ssl/server-key.pem
      └─ All connections encrypted with TLS

4. RENEWAL PHASE (When certificates expire)
   └─ DevOps/Developer re-generates new certificates
      └─ Replaces files in files-alpine/mariadb-ssl/
      └─ Rebuilds Docker image (docker compose build --no-cache)
      └─ Redeploys containers
```

## Documentation Structure

### README-ALPINE.md Sections

1. **Table of Contents** — Navigation
2. **Quick Start** — 3-step setup guide
3. **SSL Certificate Management** — Comprehensive certificate handling
   - Overview and certificate chain
   - Who creates certificates and when
   - Certificate locations and permissions
   - Step-by-step generation guide
   - Verification procedures
   - Troubleshooting
4. **Project Structure** — Directory layout with annotations
5. **Environment Configuration** — All configurable variables
6. **Starting the Project** — Bootstrap sequence and monitoring
7. **Operating the System** — Daily operations and maintenance
8. **Architecture** — System design and SSL/TLS flow
9. **Troubleshooting** — Common issues and solutions
10. **Development Workflow** — For contributing developers
11. **Production Deployment** — Pre-deployment checklist and steps
12. **Support & Documentation** — Resources and links

## Key Features of New Setup

| Feature | Benefit |
|---------|---------|
| **Alpine-only location** | All Alpine-specific files in one place (`files-alpine/`) |
| **Baked into image** | SSL certs included in Docker image, not just mounted |
| **Self-signed** | Development-friendly; safe for non-production |
| **Documented** | Clear instructions on certificate generation and renewal |
| **Encrypted by default** | Database connections always use SSL/TLS |
| **Easy renewal** | Single clear process for certificate updates |

## Future Certificate Updates

When SSL certificates expire or need renewal:

```bash
# 1. Generate new certificates (in files-alpine/mariadb-ssl/)
openssl genrsa -out ca-key.pem 2048
openssl req -new -x509 -nodes -days 3650 -key ca-key.pem -out ca-cert.pem \
  -subj "/CN=koha-mariadb-ca"
# ... (see full procedure in README-ALPINE.md)

# 2. Rebuild Docker image (automatically picks up new certs)
docker compose -f docker-compose-alpinekoha.yml build --no-cache

# 3. Restart services
docker compose -f docker-compose-alpinekoha.yml down
docker compose -f docker-compose-alpinekoha.yml up -d
```

## Testing Performed

✅ Build test: Image compiles successfully with COPY command  
✅ Image inspection: SSL files present at `/etc/mysql/ssl/` inside image  
✅ Volume mount test: Docker compose correctly references `files-alpine/` paths  
✅ Database connection: MariaDB starts with SSL enabled  
✅ HTTP endpoint: Both OPAC (8080) and Staff (8081) respond  
✅ Bootstrap completion: Full sequence completes with success message  
✅ SSL functionality: No SSL-related errors in logs  

## Files Modified

1. `/mnt/beckie2/DEVELOPMENT/koha-docker/docker-compose-alpinekoha.yml` — 3 line updates
2. `/mnt/beckie2/DEVELOPMENT/koha-docker/Dockerfile-Alpine` — 1 line addition
3. `/mnt/beckie2/DEVELOPMENT/koha-docker/files-alpine/mariadb-ssl/` — Created (7 files)
4. `/mnt/beckie2/DEVELOPMENT/koha-docker/README-ALPINE.md` — Created (911 lines)

## Next Steps

1. **Review README-ALPINE.md** — Share with team for reference
2. **Archive old location** — `files/mariadb-ssl/` can be deleted (copies now in `files-alpine/`)
3. **Document in git** — Commit these changes with message referencing SSL migration
4. **Update CI/CD** — If using automated builds, ensure they reference new paths
5. **Test certificate renewal** — Follow procedure in README to verify smooth renewal process

---

**Migration completed successfully!** ✅  
All Alpine Docker SSL certificate handling is now consolidated and documented.
