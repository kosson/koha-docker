# Koha Ubuntu to Alpine Migration Plan

## Goal
Create an Alpine-based Koha container that preserves current developer workflow and startup behavior from `files/run.sh`, while replacing Ubuntu/Debian package assumptions.

## Current-State Findings

### 1) This repository currently depends on Debian packaging semantics
From `Dockerfile` and `files/run.sh`:
- Uses `apt`, `apt-get`, Debian repos, and `koha-common` Debian package install.
- Uses Debian/Ubuntu service control (`service ...`, `/etc/init.d/...`, `a2enmod`, `a2ensite`).
- Relies on koha-common-provided commands:
  - `koha-create`
  - `koha-shell`
  - `koha-enable`
  - `koha-plack`
  - `koha-z3950-responder`
  - `koha-rebuild-zebra`
  - `koha-gitify` (from cloned repo in this project)
- Relies on Debian filesystem conventions:
  - `/etc/koha/sites/<instance>`
  - `/etc/default/koha-common`
  - `/usr/share/koha/bin/koha-functions.sh`
  - `/var/lib/koha`, `/var/log/koha`, `/var/run/koha`, `/var/cache/koha`

### 2) Koha upstream keeps `koha-common` logic in `debian/`
From `https://github.com/Koha-Community/Koha/tree/main/debian`:
- Package definition: `debian/control.in` (`koha-common`, `koha-core`, `koha-full`).
- Runtime lifecycle scripts: `debian/koha-common.postinst`, `debian/koha-common.init`, `debian/koha-common.service`.
- Core commands: `debian/scripts/koha-create`, `koha-shell`, `koha-enable`, `koha-plack`, `koha-create-dirs`, `koha-list`, etc.
- Templates/config: `debian/templates/*`.
- Install manifest: `debian/koha-common.install`.

Conclusion: the key to Alpine is not "installing `.deb` on Alpine". The key is **porting/adapting the koha-common runtime layer** (scripts + paths + process control).

### 3) Service decoupling is a valid next step, but not for every service at once
The current repository already treats some infrastructure as separate services in compose (`db`, `memcached`, and the OpenSearch profile). That direction should continue, but the services should be split by coupling level:

- **Good first external-service candidate:** RabbitMQ. Koha already talks to it over the network using STOMP settings, so it can become a sibling container with minimal change if the broker host/port/user/pass values are made explicit.
- **Already external or easy to keep external:** MariaDB, Memcached, OpenSearch, and Traefik.
- **Not recommended as the first extraction target:** Apache. Koha’s Debian scripts currently mutate Apache site files and restart Apache as part of instance setup. Pulling Apache out too early means rewriting the koha-common web lifecycle before the Alpine port has proved itself.

Rule of thumb: externalize services that are already configured by environment variables and network addresses. Keep services in the Koha image only when the Koha instance lifecycle must edit their local config files directly.

## Migration Strategy (Recommended)

## Phase 0: Define the target architecture (decision gate)

Decision: adopt a **koha-common compatibility layer for Alpine**.

What this means:

- Keep Koha source-based workflow.
- Reuse upstream Debian scripts as source of truth.
- Patch only Debian-specific OS integration points.
- Do not depend on `dpkg` and maintainer scripts at runtime.

Why this is the best starting point:

- Lowest behavior drift vs current `run.sh`.
- Keeps existing instance model (`koha-create`, `koha-shell`, etc.).
- Allows incremental migration with measurable checkpoints.

Decoupling rule for this phase:

- Keep the Koha runtime image focused on Koha lifecycle tasks.
- Move any service that can be reached through a stable host/port contract into its own container.
- Do not externalize Apache until the web lifecycle can be expressed without Debian helper scripts.

## Phase 1: Build an Alpine base image that can host Koha tooling

Create a branch and a first non-functional Alpine image skeleton.

Base image:

- `alpine:3.20` or `perl:5.38-alpine` (preferred for Perl-heavy build).

Install minimum runtime/build packages (`apk add --no-cache`):

- Core: `bash`, `curl`, `wget`, `git`, `sudo`, `coreutils`, `findutils`, `grep`, `sed`, `gawk`, `gettext` (for `envsubst`).
- Build/perl: `perl`, `perl-dev`, `build-base`, `cpanminus`, `pkgconf`.
- Koha helpers: `xmlstarlet`, `pwgen`, `daemon`, `netcat-openbsd`, `yaz`, `zebra` (if available in chosen Alpine repos).
- Web/process: `apache2`, `apache2-utils`, `openrc`.
- DB clients: `mariadb-client`.
- Node toolchain (for assets): `nodejs`, `npm`, `yarn`.

Initial output of Phase 1:

- Image builds.
- Shell has all tool binaries required by migrated scripts.

Add a service boundary check here:

- The Koha image should be able to start with only external endpoints for DB, cache, broker, and search.
- The image should not require those services to be installed locally.
- Apache may remain local for the first working milestone if that is what keeps `koha-create` and `koha-plack` functional.

## Phase 2: Create `koha-common-alpine` compatibility layout

Implement the expected file layout directly in image build (or in a dedicated overlay dir copied into image):

- `/usr/sbin/koha-*` scripts
- `/usr/share/koha/bin/koha-functions.sh`
- `/etc/koha/*` templates and defaults
- `/etc/default/koha-common` compatibility config
- `/etc/koha/koha-sites.conf`, `/etc/koha/koha-conf-site.xml.in`, `plack.psgi`, Apache shared snippets

Source these from upstream `debian/scripts` and `debian/templates`.

Deliverable:

- A reproducible copy step in Dockerfile that installs the compatibility files.

## Phase 3: Patch koha-common scripts for Alpine (minimal invasive)

Patch points required for Alpine:

1. Service/init integration:

- Replace hard dependency on `/lib/lsb/init-functions` logging helpers.
- Replace SysV assumptions in `koha-common.init` and scripts using `start-stop-daemon` if behavior differs.
- Option: keep wrapper scripts and call process tools directly from `run.sh`.

2. Apache integration:

- Verify Alpine Apache paths and module enable mechanism.
- Adapt `a2enmod`/`a2ensite` usage to Alpine-compatible equivalents (or direct config include strategy).

3. User/group handling:

- Validate `adduser/useradd`, `groupadd` behavior and flags.
- Preserve `${instance}-koha` user model expected by `koha-shell` and `koha-create-dirs`.

4. Debian package manager calls inside scripts:

- Remove/guard `dpkg-query`, `apt-cache`, `apt-get` logic (for example, letsencrypt checks in `koha-create`).

5. Process-control dependencies:

- Validate commands that use `daemon` utility and pidfiles.

6. Service boundary extraction:

- Make broker/database/cache/search addresses explicit environment inputs.
- Remove assumptions that RabbitMQ, MariaDB, Memcached, or OpenSearch are local processes.
- Replace local service probing with connection checks against compose-provided hostnames.
- Preserve Apache-specific helper behavior until the compatibility layer can replace it.

Deliverable:

- A maintained patch set under this repo (example: `patches/alpine-koha-common/*.patch`).

## Phase 4: Dockerfile migration from Ubuntu to Alpine

Replace Debian-specific sections:

- Remove apt mirror/retry logic and `apt-install-retry` helper.
- Replace locale generation steps with Alpine-safe locale strategy.
- Replace Debian Koha package repository setup.

Add compatibility layer installation:

- Copy/pull `debian/scripts` and `debian/templates` artifacts.
- Apply local Alpine patch set.
- Install into expected paths.

Add a container split policy:

- Keep MariaDB, Memcached, OpenSearch, and Traefik external.
- Externalize RabbitMQ as soon as the broker configuration is wired into `run.sh` and `koha-create` without local package assumptions.
- Keep Apache inside the Koha image for the first Alpine milestone unless you are also ready to replace the Apache-specific koha-common lifecycle.

Deliverable:

- New Alpine-oriented Dockerfile builds successfully and starts shell.

## Phase 5: `files/run.sh` adaptation (keep behavior, reduce distro coupling)

`run.sh` should remain the orchestration entrypoint, but distro checks must be neutralized.

Required edits:

- Replace apt-based optional installs (`CPAN=yes`, `EXTRA_APT`, CI removal block) with adapter functions:
  - `install_os_packages()` that dispatches to `apk`.
  - `remove_os_packages()` optional/no-op where appropriate.
- Replace `service ...` calls with wrapper functions:
  - `svc_start`, `svc_stop`, `svc_status`.
- Keep koha command usage (`koha-create`, `koha-enable`, etc.) unchanged where possible.

Add explicit service wiring:

- Read database, cache, broker, and search endpoints from environment variables with sane defaults.
- Stop calling package-local service names for RabbitMQ or MariaDB if those services are moved outside the image.
- If Apache stays local, keep a local start/stop path only for Apache; if Apache is externalized later, `run.sh` should validate the HTTP listener instead of managing the process.

Recommended extraction order:

1. Externalize RabbitMQ first.
2. Keep Apache local while the Alpine compatibility layer still uses koha-common helper semantics.
3. Externalize Apache only after a dedicated web-container contract exists for vhosts, Plack startup, and instance enable/disable behavior.

Deliverable:

- `run.sh` works against compatibility layer and no longer assumes Debian tooling directly.

## Phase 6: Test gates and acceptance criteria

Use existing repo tests as migration gates, adding Alpine-specific checks:

Must pass:

- `tests/test_run_sh_static.sh`
- `tests/test_mariadb_auth_readiness_integration.sh`
- `tests/test_restart_integration.sh`
- `tests/test_authority_groupby_sqlmode_integration.sh`
- OpenSearch integration test if enabled profile is used.

Add new Alpine-focused checks:

- Validate required koha commands exist and are executable.
- Validate created instance paths/ownership.
- Validate Apache and Plack startup/stop behavior.
- Validate first boot and restart with existing DB path.

Definition of done for first successful milestone:

- Container creates and enables one Koha instance.
- Web endpoints respond.
- Restart path does not reinitialize non-empty DB.
- Core test suite remains green.

## Work Breakdown for a Solid Beginning (first 2-3 weeks)

Week 1:

- Build Alpine base image with all system tools.
- Import `debian/scripts` + `debian/templates` into compatibility layer paths.
- Smoke test command discovery (`koha-create --help`, `koha-shell --help`, `koha-plack --help`).

Week 2:

- Patch scripts for Alpine service/user/apache differences.
- Introduce `run.sh` service/package adapter functions.
- Reach "instance creation completes" milestone.

Week 3:

- Reach full startup with Apache + Plack + worker services.
- Stabilize permissions and restart behavior.
- Run and fix failing tests.

## High-Risk Areas

- Apache module/site enable flows differ from Debian helpers.
- `koha-plack` and worker daemons depend on pidfile/process semantics.
- Missing or behavior-different Alpine packages (`daemon`, Zebra stack variants).
- Hidden Debian assumptions in postinst-era scripts.
- Splitting Apache too early will likely force a rewrite of `koha-enable`, `koha-plack`, and the Apache template flow before the Alpine port is even bootable.
- RabbitMQ is a safer first external-service candidate because its contract is already network-based and Koha only needs broker connectivity, not local lifecycle control.

## Non-Goals for initial migration

- Building official Alpine `apk` packages for all Koha components.
- Refactoring all Koha service scripts to a new supervisor model in first pass.
- Moving Apache out of the Koha image before the koha-common compatibility layer is stable.

## Service Decoupling Roadmap

1. Keep external services external.
- MariaDB, Memcached, OpenSearch, and Traefik remain separate containers.
- Treat them as infrastructure services, not Koha runtime dependencies.

2. Externalize RabbitMQ next.
- Drive `MESSAGE_BROKER_HOST`, `MESSAGE_BROKER_PORT`, `MESSAGE_BROKER_USER`, `MESSAGE_BROKER_PASS`, and `MESSAGE_BROKER_VHOST` from compose.
- Replace any `service rabbitmq-server ...` logic with connection checks only.
- Verify workers can connect to the broker from the Koha container without local installation.

3. Keep Apache local for the first Alpine milestone.
- Preserve Apache lifecycle handling until `koha-create` and `koha-enable` are replaced or shimmed.
- This avoids turning the first Alpine migration into a full web-tier redesign.

4. Consider a separate web container only after the compatibility layer is stable.
- If Apache must move out later, introduce a sibling web container that consumes generated Koha vhost/config artifacts.
- At that point the migration is a two-container contract change, not just a base-image change.

Recommendation summary:

- RabbitMQ externalization: recommended.
- Apache externalization: possible later, not recommended as the first step.

## Immediate Next Actions in this repository

1. Review `docs/Alpine-migration/koha-common-alpine-gap-analysis.md` for the helper-script gap matrix and porting priorities.
2. Review `docs/Alpine-migration/external-service-layout.md` for the RabbitMQ-first externalization plan and the Apache deferral rationale.
3. Add `files/koha-common-alpine/` overlay directory containing upstream scripts/templates.
4. Introduce `files/run.sh` wrappers for package/service abstraction before changing command flow.
5. Create an `alpine` build target (or parallel Dockerfile) to allow side-by-side Ubuntu vs Alpine validation.

---

This plan intentionally starts by preserving the `koha-common` command contract and filesystem contract, then progressively replacing Debian-specific mechanics underneath. That gives the highest chance of reaching a working Alpine container early without rewriting the full Koha orchestration model from scratch.
