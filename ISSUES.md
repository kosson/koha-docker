# Koha Docker Stack — Detected Issues

Last updated: 2026-06-08  
Scope: `/home/nicolaie/Documents/koha-docker` root-level Docker artefacts  
Files reviewed: `docker-compose.yml`, `Dockerfile`, `files/run.sh`, `stack.sh`,
`env/defaults.env`, `env/template.env`, `OpenSearch-3.6/docker-compose.yml`,
`traefik/docker-compose.yaml`

---

## CRITICAL — Security

### 1. Secrets committed to source control
**Files:** `env/defaults.env`  
The file contains plaintext credentials:
- `KOHA_DB_ROOT_PASSWORD` (has a placeholder but template looks realistic)
- `GIT_BZ_PASSWORD`
- `OPENSEARCH_INITIAL_ADMIN_PASSWORD` (hardcoded value in the committed file)
- `ELASTIC_OPTIONS` embeds `admin:<password>` in XML

**Impact:** Anyone with read access to the repository obtains these secrets.  
**Fix:** Move all secrets into `env/.env` (gitignored). `defaults.env` should contain
only safe placeholders.

---

### 2. `cap_add: ALL` on the Koha container
**File:** `docker-compose.yml` (koha service)  
Grants every Linux capability (`SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, etc.).

**Impact:** A compromise of the Koha web app escapes container isolation trivially.  
**Fix:** Drop to the minimum required capabilities. Likely candidates:
`SYS_NICE`, `IPC_LOCK` (for memlock), possibly `CHOWN` / `SETUID` if the
entrypoint actually needs them. Audit the exact ones and list them explicitly.

---

### 3. TLS verification disabled by default for OpenSearch
**Files:** `env/template.env`, `env/defaults.env`, `files/run.sh`  
`ELASTIC_OPTIONS` ships with `<SSL_verify_mode>0</SSL_verify_mode>` and
`PERL_LWP_SSL_VERIFY_HOSTNAME=0`. The `OPENSEARCH_CA_CERT` path is commented out,
so the safe configuration is never the default.

**Impact:** Man-in-the-middle attacks on the os01 → OpenSearch link; search
indexing can be silently subverted.  
**Fix:** Default to verified TLS. Refuse to start Koha if `KOHA_ELASTICSEARCH=yes`
and `OPENSEARCH_CA_CERT` is unset.

---

### 4. OpenSearch CA private key bind-mounted into containers
**File:** `OpenSearch-3.6/docker-compose.yml`  
`./assets/ssl/root-ca-key.pem` is mounted read-write into every OS node and the
Dashboards container.

**Impact:** If any node is compromised, the attacker can sign fraudulent node
certificates and join the cluster. The CA key should never leave the host.  
**Fix:** Remove `root-ca-key.pem` from every `volumes:` entry. Distribute only
the CA certificate.

---

## HIGH — Stability / Data Loss

### 5. `knonikl` and `opensearch-36_osearch` networks are not auto-created
**Files:** `docker-compose.yml`, `stack.sh`  
Both networks are declared `external: true`. `stack.sh` only auto-creates
`frontend`.

**Impact:** First-time `./stack.sh start` fails on the koha or OpenSearch
`docker compose up` calls because those networks don't yet exist.  
**Fix:** Add an `ensure_extra_networks()` function to `stack.sh` that creates
`knonikl` and `opensearch-36_osearch` when missing.

---

### 6. UID 1000 collision workaround via `userdel -r ubuntu`
**File:** `Dockerfile` line 15  
The comment explains that the pre-created `ubuntu` user at UID 1000 blocks the
intended `kohadev-koha` UID assignment. Deleting it only works on a clean base.

**Impact:** Any change to the base image (new Ubuntu point-release, alternate base
image) silently breaks `LOCAL_USER_ID=1000` and produces bind-mount permission
errors on the Koha repo directory.  
**Fix:** Use a build ARG to set the base UID dynamically, or create `kohadev-koha`
with an explicit UID before any system user at that UID is created.

---

### 7. No healthcheck on the Koha container
**File:** `docker-compose.yml` (koha service)  
Readiness detection is log-line scraping via `stack.sh`. `docker compose ps`
cannot distinguish "container started" from "Koha fully booted."

**Impact:** External orchestration (swarm, restart policies, monitors) has no
reliable signal. Stack scripts may race DB-dependent startup logic.  
**Fix:** Add a healthcheck that probes the internal Apache port, e.g.
`curl -fsS http://localhost:8080/cgi-bin/koha/mainpage.pl`.

---

### 8. Hard-coded Ubuntu mirror rewrite is non-portable
**File:** `Dockerfile` lines 20–23  
The image rewrites all APT sources to `mirrors.kernel.org` because the
`archive.ubuntu.com` CDN is allegedly unreachable from the author's network.

**Impact:** The image cannot be built on any network where `mirrors.kernel.org`
is slow, blocked, or down — which is the exact failure mode it was meant to
prevent. The retry helper in `apt-install-retry` is good, but the DNS rewrite
is the wrong default.  
**Fix:** Make the mirror an ARG with `archive.ubuntu.com` as the documented
default, and document the override for the specific broken network.

---

## MEDIUM — Operability / Hygiene

### 9. `sudo` assumed inside the Koha container
**File:** `files/run.sh` (multiple `sudo koha-shell` calls)  
`sudo` is not explicitly installed in the Dockerfile.

**Impact:** Works today because `koha-common` pulls it transitively. If the
dependency graph changes (unhold, downgrade, alternate package source) the
container fails at the first `sudo` call.  
**Fix:** Add `sudo` to the explicit `apt-install-retry` package list.

---

### 10. `root-ca-key.pem` mounted read-write
**Note:** overlap with #4 but from a permissions angle.  
The bind mount does not specify `:ro`. Any process inside the OS node or
Dashboards container that is breached can exfiltrate or overwrite the CA key.

---

### 11. OpenSearch builds skip pull via `pull_policy: never`
**File:** `OpenSearch-3.6/docker-compose.yml`  
All OS nodes and the image target use `pull_policy: never`.

**Impact:** CI/CD or a fresh developer machine that has not run `stack.sh build`
will attempt to build from source instead of using the pre-built published image.
That is intentional for offline-first operation but should be flagged: it rewards
building and makes `docker compose pull` a no-op.  
**Fix:** No code change needed — add a project README note that the first run or
`--build-opensearch` is required on new hosts.

---

### 12. `docker-compose.yml` mixes `image:` and `build:` for the koha service
**File:** `docker-compose.yml` lines 15–18  
`image: ${KOHA_IMAGE_TAG}` plus `build: context: .`.

**Impact:** Compatible with `pull_policy: missing`, but the semantics are
confusing: `KOHA_IMAGE_TAG` is both a pull target and a local-build target.
Changing the tag does not force a rebuild.  
**Fix:** Document that `KOHA_IMAGE_TAG` tags the locally-built image and that
`--build-koha` must accompany tag changes.

---

### 13. Traefik dashboard port hard-coded in `stack.sh` but set in `traefik/.env`
**File:** `stack.sh` line 64  
`TRAEFIK_DASHBOARD_PORT` is read from `traefik/.env` with a fallback of `8083`,
but there's no validation that it actually matches the Traefik container
configuration.

**Impact:** Operator renames the dashboard port in Traefik's `docker-compose.yaml`
but `stack.sh logs` output or manual checks will use the stale value from
`traefik/.env`.  
**Fix:** Read from a single source, or add a `docker compose port` query to
discover it dynamically.

---

## LOW — Cosmetic / Maintenance

### 14. CRLF normalization baked into the image at every build
**File:** `Dockerfile` lines 229–231 plus the identical run in `files/run.sh`
lines 448–449 and 494–495.  
Multiple unconditional `sed -i 's/\r$//'` invocations — once during image
build and twice at container startup.

**Impact:** Negligible; safe but redundant on a pure-Linux contributor base.
Build-time normalization should be sufficient.  
**Fix:** Remove the run-time normalizations if git config `core.autocrlf` is
enforced at the repo level.

---

### 15. IPv6 enabled by default in `env/template.env`
**File:** `env/template.env` line 12  
`ENABLE_IPV6=false` is the safe default, but `docker-compose.yml` references
the variable; a careless `cp env/template.env env/.env` edit to `true` on a
host without IPv6 routing causes Docker network creation to hang.

**Impact:** Stack start hangs at the `docker compose up` phase on IPv4-only hosts.  
**Fix:** Add a network-prerequisite check to `stack.sh` that warns when
`ENABLE_IPV6=true` and Docker cannot route `2001:db8::/32` or similar.

---

### 16. `KOHA_IMAGE` defaults to `main` instead of a locked version
**File:** `env/template.env`, `docker-compose.yml`  
`KOHA_IMAGE=main` and `KOHA_IMAGE_TAG=kosson/koha-ubuntu:latest`.

**Impact:** `latest` drift; two developers on different days may run different
images without changing any file.  
**Fix:** Pin to a date-tagged or commit-tagged image in production; keep
`latest` as the override for CI.

---

## Summary Table

| # | Severity | Title | File(s) |
|---|----------|-------|---------|
| 1 | CRITICAL | Secrets in source control | `env/defaults.env` |
| 2 | CRITICAL | `cap_add: ALL` | `docker-compose.yml` |
| 3 | CRITICAL | TLS verification disabled | `env/*.env`, `files/run.sh` |
| 4 | CRITICAL | CA private key mounted | `OpenSearch-3.6/docker-compose.yml` |
| 5 | HIGH | External networks missing | `docker-compose.yml`, `stack.sh` |
| 6 | HIGH | UID 1000 userdel hack | `Dockerfile` |
| 7 | HIGH | No Koha healthcheck | `docker-compose.yml` |
| 8 | HIGH | Hard-coded mirror rewrite | `Dockerfile` |
| 9 | MEDIUM | `sudo` not explicit | `Dockerfile`, `files/run.sh` |
| 10 | MEDIUM | CA key writeable | `OpenSearch-3.6/docker-compose.yml` |
| 11 | MEDIUM | `pull_policy: never` | `OpenSearch-3.6/docker-compose.yml` |
| 12 | MEDIUM | Mixed image/build semantics | `docker-compose.yml` |
| 13 | MEDIUM | Dashboard port single-source drift | `stack.sh` |
| 14 | LOW | Redundant CRLF stripping | `Dockerfile`, `files/run.sh` |
| 15 | LOW | IPv6 default risk | `env/template.env` |
| 16 | LOW | Floating `latest` tag | `env/template.env`, `docker-compose.yml` |

---

*End of ISSUES.md*


os01  | org.opensearch.bootstrap.StartupException: OpenSearchException[failed to bind service]; nested: AccessDeniedException[/usr/share/opensearch/data/nodes];

https://oneuptime.com/blog/post/2026-01-25-fix-docker-oci-runtime-create-failed-errors/view