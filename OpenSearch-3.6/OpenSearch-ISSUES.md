# OpenSearch Cluster Incident Report (os01 startup/health failure)

Date: 2026-06-07  
Environment: Debian Trixie host, project originally prepared on Ubuntu.

## 1. Problem statement

`os01` appeared to "fail to start" when running `docker compose up -d` in `OpenSearch-3.6`, and this blocked dependent services (especially `dashboards`).

Observed error from compose:

```bash
dependency failed to start: container os01 is unhealthy
```

Important clarification discovered during investigation:

- `os01` process was actually running.
- The failure was a healthcheck/authentication failure, not a JVM/process crash.

---

## 2. Investigation stages and commands used

### Stage A: Initial state and config inspection

Checked project wiring first (compose, restart script, node config):

```bash
cd /home/nicolaie/Documents/DEVELOPMENT/koha-docker/OpenSearch-3.6
docker compose ps os01
docker logs --tail 200 os01
docker compose config | sed -n '1,220p'
```

Read/verified key files:

- `OpenSearch-3.6/docker-compose.yml`
- `OpenSearch-3.6/restart-to-clear-cluster.sh`
- `OpenSearch-3.6/assets/opensearch/Dockerfile`
- `OpenSearch-3.6/assets/opensearch/config/os01/opensearch.yml`

Notes from this stage:

- Healthcheck for `os01` uses:

	```bash
	curl -ks --fail https://os01:9200/_cat/nodes?pretty -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}"
	```

- No immediate compose syntax issues in rendered config.

### Stage B: Reproduce on host and check prerequisites

Reproduced service startup and checked host prerequisites:

```bash
docker compose up -d os01
docker ps -a --filter name=os01 --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
cat /proc/sys/vm/max_map_count
ls -ld assets/opensearch/data/os01data
stat -c '%U %G %a %n' assets/opensearch/data/os01data
```

Findings:

- `vm.max_map_count` was already good (`1048576`).
- Data dir existed and was writable enough for startup.
- `os01` container was up, but healthcheck remained failing.

### Stage C: Deep logs and healthcheck behavior

Captured full logs and state metadata:

```bash
docker logs --tail 250 os01
docker inspect os01 --format '{{json .State}}'
docker inspect os01 --format '{{json .State.Health.Log}}'
```

Validated endpoint behavior from inside container and host:

```bash
docker exec os01 sh -lc 'getent hosts os01 || true; \
	curl -ksS -u "admin:testSimplu" https://localhost:9200/_cluster/health?pretty || true; \
	curl -ksS -u "admin:testSimplu" https://os01:9200/_cluster/health?pretty || true'

curl -ksS -u 'admin:testSimplu' https://localhost:9200/_cluster/health?pretty || true
```

Critical finding:

- Healthcheck returned HTTP `401` (auth failure), producing unhealthy state.

### Stage D: Confirm root cause (credential drift)

Inspected credential sources:

```bash
# Read OpenSearch password from env
cat OpenSearch-3.6/.env

# Read security users hash file
cat OpenSearch-3.6/assets/opensearch/config/os01/opensearch-security/internal_users.yml
```

Then tested candidate credentials directly:

```bash
docker exec os01 sh -lc 'for p in "testSimplu" "test@Cici24#ANA" "admin"; do \
	code=$(curl -ks -o /tmp/out -w "%{http_code}" -u "admin:$p" https://os01:9200/_cat/nodes?pretty); \
	echo "$p => $code"; \
done'
```

Result:

- `testSimplu => 401`
- `test@Cici24#ANA => 401`
- `admin => 200`

This proved the mismatch: healthcheck uses `.env` password, but active admin credential was still `admin`.

### Stage E: Full stack behavior reproduction

Confirmed dependency impact in full compose startup:

```bash
docker compose up -d
docker compose ps
```

Observed:

- `os01` unhealthy
- `dashboards` blocked by `depends_on` health condition

---

## 3. Fix stages and commands used

### Fix 1: Add regression test for os01 auth mismatch

Created:

- `tests/test_opensearch_os01_auth_integration.sh`

Purpose:

- Validate that `OPENSEARCH_INITIAL_ADMIN_PASSWORD` can authenticate to `os01`.
- Detect mismatch condition where `.env` password fails but `admin:admin` still works.

First run (before final fix) intentionally failed and proved the bug:

```bash
bash tests/test_opensearch_os01_auth_integration.sh
```

### Fix 2: Attempt live API sync with existing password

Tried applying password via security API script:

```bash
cd OpenSearch-3.6
set -a && source .env && set +a && bash initial_api_calls.sh
```

Finding:

- OpenSearch rejected `testSimplu` due to password policy:

	- minimum length 10
	- uppercase + lowercase + digit + special character

So runtime password update with `testSimplu` was not possible.

### Fix 3: Switch to compliant password and align all configs

Generated new bcrypt hash using OpenSearch official `hash.sh`:

```bash
docker run --rm -e ADMIN_PASS='test@Cici24#ANA' \
	opensearchproject/opensearch:3.6.0 \
	bash -c '/usr/share/opensearch/plugins/opensearch-security/tools/hash.sh -p "$ADMIN_PASS" 2>/dev/null'
```

Updated the following files:

1. `OpenSearch-3.6/.env`

```dotenv
OPENSEARCH_INITIAL_ADMIN_PASSWORD=test@Cici24#ANA
```

2. `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml`

```yaml
opensearch.password: "test@Cici24#ANA"
```

3. `OpenSearch-3.6/assets/opensearch/config/os01/opensearch-security/internal_users.yml`

- Updated `admin`, `dashboards`, `kibanaserver` hashes to generated bcrypt hash.

### Fix 4: Apply changes live and refresh container env

Applied live security updates:

```bash
cd OpenSearch-3.6
set -a && source .env && set +a && bash initial_api_calls.sh
```

Recreated `os01` to refresh environment value used by healthcheck:

```bash
docker compose up -d --force-recreate os01
```

Checked in-container env and probe:

```bash
docker exec os01 sh -lc 'echo "env-pass=$OPENSEARCH_INITIAL_ADMIN_PASSWORD"; \
	curl -ks -o /dev/null -w "%{http_code}" -u "admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD" \
	https://os01:9200/_cat/nodes?pretty; echo'
```

Then verified service status:

```bash
docker compose ps os01
```

Result:

- `os01` became `healthy`.

### Fix 5: Bring dashboards up after os01 recovery

```bash
docker compose up -d dashboards
docker compose ps dashboards
```

Result:

- `dashboards` started successfully.

---

## 4. Final verification commands and outcomes

### Verification command set

```bash
# Verify auth with env password
curl -ks -u 'admin:test@Cici24#ANA' https://localhost:9200/_cluster/health?pretty

# Verify os01 health
cd OpenSearch-3.6 && docker compose ps os01

# Verify dashboards state
cd OpenSearch-3.6 && docker compose ps dashboards

# Run regression test
bash tests/test_opensearch_os01_auth_integration.sh
```

### Outcomes

- `.env` password now authenticates.
- `os01` healthcheck passes.
- `dashboards` can start (dependency satisfied).
- Regression test passes.

---

## 5. Root causes summary

1. **Credential mismatch** between `OPENSEARCH_INITIAL_ADMIN_PASSWORD` and active security user credentials/hashes.
2. **Password policy violation** for `testSimplu`, preventing live update via Security API.
3. **Operational nuance**: changing `.env` alone is not enough; container recreation is needed for healthcheck env refresh.

---

## 6. Files changed during fix

1. `OpenSearch-3.6/.env`
2. `OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml`
3. `OpenSearch-3.6/assets/opensearch/config/os01/opensearch-security/internal_users.yml`
4. `tests/test_opensearch_os01_auth_integration.sh` (new)

---

## 7. Quick runbook for future recurrence

```bash
cd OpenSearch-3.6

# 1) Verify current auth
curl -ks -o /dev/null -w '%{http_code}\n' -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" \
	https://localhost:9200/_cat/nodes?pretty

# 2) If 401, ensure password is policy-compliant and synced in:
#    - .env
#    - dashboards config
#    - internal_users.yml hashes

# 3) Apply live updates
set -a && source .env && set +a && bash initial_api_calls.sh

# 4) Recreate os01 to refresh env used by healthcheck
docker compose up -d --force-recreate os01

# 5) Validate
docker compose ps os01 dashboards
bash ../tests/test_opensearch_os01_auth_integration.sh
```