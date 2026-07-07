---
title: "Security Audit (ISSUES.md)"
tags: [security-audit, vulnerability-assessment, cap-add, plaintext-secrets, tls-disabled, ca-key-exposure, external-networks, uid-collision, healthcheck, ipv6, rate-limiting, network-policy, remediation]
---
# Security Audit (ISSUES.md)

Full catalog of known security, stability, and operational issues.

## Critical Issues

### 1. `cap_add: ALL` on Koha Container

**Location**: `docker-compose.yml`, koha service
**Risk**: Container has every Linux capability — if compromised, attacker has root-level control over the host.

```yaml
cap_add:
  - ALL
```

**Remediation**:
- Audit what the Koha container actually needs
- Replace `ALL` with specific capabilities:
  ```yaml
  cap_add:
    - SYS_NICE    # Set process priority, CPU affinity
    - IPC_LOCK    # Lock memory (needed by services)
  ```
- Test thoroughly after change

### 2. Plaintext Secrets in defaults.env

**Location**: `env/defaults.env`
**Risk**: All passwords stored in plaintext, potentially committed to git.

```
KOHA_DB_ROOT_PASSWORD=[REDACTED]
KOHA_DB_PASSWORD=[REDACTED]
OPENSEARCH_INITIAL_ADMIN_PASSWORD=[REDACTED]
```

**Remediation**:
- Move secrets to a gitignored file (e.g., `env/.env` or `env/secrets.env`)
- Keep `env/defaults.env` with non-secret defaults only
- Add `env/.env` and `env/secrets.env` to `.gitignore`
- Use `env/template.env` as a reference for required variables

### 3. TLS Verification Disabled by Default

**Location**: `env/.env`, `OPENSEARCH_CA_CERT=/dev/null`
**Risk**: Koha → OpenSearch connection is plaintext even though OS has TLS enabled.

**Remediation**:
- Set `OPENSEARCH_CA_CERT=/path/to/root-ca.pem` in `env/.env`
- Or mount the cert:
  ```yaml
  - ${OPENSEARCH_CA_CERT}:/kohadevbox/opensearch-root-ca.pem:ro
  ```

### 4. CA Private Key Exposed in Containers

**Location**: `OpenSearch-3.6/docker-compose.yml`, all OS node volumes
**Risk**: `root-ca-key.pem` is bind-mounted into every OS node and Dashboards container. If any container is compromised, the CA private key is exposed.

```yaml
volumes:
  - ./assets/ssl/root-ca-key.pem:/usr/share/opensearch/config/root-ca-key.pem
```

**Remediation**:
- Remove the bind mount from all containers except the one that generates certs
- Only `root-ca.pem` (public) should be shared across nodes
- `root-ca-key.pem` (private) should stay on the host only

## High Issues

### 5. External Networks Not Auto-Created

**Location**: `docker-compose.yml` (knonikl, opensearch-36_osearch)
**Risk**: Compose fails if networks don't exist. `stack.sh` creates them, but the compose files themselves are incomplete without manual setup.

```yaml
networks:
  knonikl:     external: true
  opensearch-36_osearch: external: true
  frontend:    external: true
```

**Remediation**:
- ✅ Mostly fixed in `stack.sh` (auto-creates networks)
- Document the requirement in README.md
- Consider using `name:` field to pin network names (partially done)

### 6. UID 1000 Collision Workaround

**Location**: `Dockerfile`, line 15
**Risk**: `userdel -r ubuntu` removes the Ubuntu base image user to free UID 1000 for `kohadev-koha`. This is a hack that could break with base image updates.

```dockerfile
RUN userdel -r ubuntu 2>/dev/null || true
```

**Remediation**:
- Use a different UID for `kohadev-koha` (e.g., 1001)
- Or run the container as a different UID
- Or use `usermod` in `run.sh` to change the existing ubuntu user's UID

### 7. No Healthcheck on Koha Container

**Location**: `docker-compose.yml`, koha service
**Risk**: Docker doesn't know when Koha is actually ready. No automatic restart on failure.

**Remediation**:
```yaml
healthcheck:
  test: ["CMD", "curl", "-sf", "http://localhost:8080/"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 30s
```

### 8. Git-Sensitive Files in Git

**Location**: Various files reference credentials
**Risk**: Credentials may be committed to the git repository.

**Remediation**:
- Audit all files for hardcoded secrets
- Use environment variables or mounted secrets instead
- Add `.gitignore` patterns for sensitive files

## Medium Issues

### 9. Mixed Image/Build Semantics

**Location**: `docker-compose.yml`, koha service
**Risk**: Has both `image:` and `build:` which creates confusion about which takes precedence.

```yaml
image: ${KOHA_IMAGE_TAG:-kosson/koha-ubuntu:latest}
pull_policy: missing
build: { context: . }
```

**Remediation**:
- Choose one: either `image:` only (pull from registry) OR `build:` only (build locally)
- Document the behavior clearly

### 10. Dashboard Port Drift

**Location**: `OpenSearch-3.6/docker-compose.yml`, dashboards labels
**Risk**: Label hard-codes port 5601 but `OPENSEARCH_DASHBOARDS_PORT` env var might differ.

```yaml
- traefik.http.services.dashboards-svc.loadbalancer.server.port=5601
```

**Remediation**:
- Use env var interpolation in labels (if supported) or document that the port must match

### 11. CRLF Normalization Redundancy

**Location**: `Dockerfile` + `files/run.sh`
**Risk**: CRLF normalization runs at both build time AND container start. Redundant but not harmful.

**Remediation**:
- Remove the build-time normalization (Dockerfile RUN sed commands)
- Keep runtime normalization only (in run.sh)
- OR vice versa, depending on which is more important

### 12. Missing Koha Healthcheck

**Location**: `docker-compose.yml`, koha service
**Risk**: Docker has no way to determine if Koha is healthy.

**Remediation**: Same as #7 above.


## Low Issues

### 13. sudo Not Explicitly Configured

**Risk**: Koha container may need sudo for certain operations, but it's not explicitly configured.

### 14. Mixed Build/Pull Image Semantics

**Risk**: See #9.

### 15. IPv6 Risk

**Location**: `docker-compose.yml`
**Risk**: Some services have no IPv6 controls. Koha and memcached don't set `enable_ipv6`.

```yaml
networks:
  kohanet:
    enable_ipv4: true
    enable_ipv6: false   # Good: kohanet has IPv6 disabled
```

But the other networks don't set this explicitly.

### 16. Floating `latest` Tag

**Location**: `docker-compose.yml`, memcached image
**Risk**: `MEMCACHED_IMAGE: memcached` (no tag) resolves to `memcached:latest`. Image behavior could change over time.

**Remediation**: Pin to specific version:
```yaml
MEMCACHED_IMAGE: memcached:1.6
```

### 17. No Rate Limiting on OpenSearch

**Risk**: OpenSearch has no rate limiting configured. Could be abused for DoS.

**Remediation**: Configure OpenSearch rate limiting in `opensearch.yml`.

### 18. No Network Policy Between Containers

**Risk**: All containers on the same network can reach each other. No micro-segmentation.

**Remediation**: Use Docker network policies or separate networks for stricter isolation.

## Summary Matrix

| # | Issue | Severity | Effort to Fix | Status |
|---|---|---|---|---|
| 1 | cap_add: ALL | Critical | Medium | Open |
| 2 | Plaintext secrets | Critical | Low | Open |
| 3 | TLS disabled by default | Critical | Low | Open |
| 4 | CA key exposed | Critical | Low | Open |
| 5 | Missing external networks | High | Low | Mostly fixed |
| 6 | UID collision workaround | High | Medium | Open |
| 7 | No Koha healthcheck | High | Low | Open |
| 8 | Git-sensitive files | High | Medium | Open |
| 9 | Mixed image/build | Medium | Low | Open |
| 10 | Dashboard port drift | Medium | Low | Open |
| 11 | CRLF redundancy | Low | Low | Open |
| 12 | Missing healthcheck | Medium | Low | Open |
| 13 | sudo not explicit | Low | Low | Open |
| 14 | Floating latest tag | Low | Low | Open |
| 15 | IPv6 risk | Low | Low | Open |
| 16 | No rate limiting | Medium | Medium | Open |
| 17 | No network policy | Low | High | Open |
