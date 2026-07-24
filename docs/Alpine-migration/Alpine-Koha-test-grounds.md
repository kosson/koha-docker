# Alpine Koha Test Grounds

## Purpose

This document defines a repeatable test ground for the Alpine-based Koha experiment.

The goal is not to prove the full migration in one step. The goal is to make each future session produce a small, measurable result:

- a build result,
- a startup result,
- a runtime result,
- and a short report that says what changed.

## Compose Entry Point

Use [docker-compose-alpinekoha.yml](../../docker-compose-alpinekoha.yml) as the Alpine test stack.

It keeps the current service topology but builds the `koha` service from [Dockerfile-Alpine](../../Dockerfile-Alpine):

- `db` remains MariaDB-backed,
- `rabbitmq` remains external,
- `memcached` remains external,
- `koha` is the Alpine build target.

The file is intentionally separate from [docker-compose.yml](../../docker-compose.yml) so the Alpine work can evolve without disturbing the existing Ubuntu-based path.

## Working Assumptions

The test ground should assume the following until proven otherwise:

- the Alpine image may fail at package-install time,
- helper scripts may fail because they still expect Debian semantics,
- `run.sh` may need adapter logic for Alpine-specific tooling,
- and service split assumptions may need to change as the image matures.

That means the first aim of each session is discovery, not completion.

## Session Routine

Use this same flow in every Alpine session.

### 1) Prepare the workspace

Confirm which files changed since the last session:

```bash
git status --short
```

Then inspect the Alpine-specific files only:

```bash
git diff -- docker-compose-alpinekoha.yml Dockerfile-Alpine docs/Alpine-migration/
```

If the working tree contains unrelated changes, ignore them unless they block the Alpine work.

### 2) Build the Alpine image

Run the Alpine compose file explicitly:

```bash
docker compose -f docker-compose-alpinekoha.yml build koha
```

If Docker Compose is not suitable for a narrow check, build the image directly:

```bash
docker build -f Dockerfile-Alpine .
```

Record:

- whether the build reached the package-install stage,
- which package or file caused failure,
- and whether the failure is a Dockerfile issue or a missing Alpine package issue.

### 3) Start the Alpine stack

Bring up the Alpine test ground with the same compose file:

```bash
docker compose -f docker-compose-alpinekoha.yml up -d db rabbitmq memcached
```

Then start `koha` separately so its logs are isolated:

```bash
docker compose -f docker-compose-alpinekoha.yml up koha
```

Record:

- whether the container reaches `run.sh`,
- whether helper commands exist,
- whether startup fails before or after source validation,
- and whether the failure is a runtime dependency or a service connectivity problem.

### 4) Run narrow checks first

The first checks should be cheap and local.

Suggested order:

1. `docker compose -f docker-compose-alpinekoha.yml config`
2. `docker compose -f docker-compose-alpinekoha.yml build koha`
3. `docker compose -f docker-compose-alpinekoha.yml up -d db rabbitmq memcached`
4. `docker compose -f docker-compose-alpinekoha.yml logs --no-color koha`
5. `docker compose -f docker-compose-alpinekoha.yml exec koha /bin/bash -lc 'command -v koha-create && command -v koha-shell && command -v koha-enable'`

If the build is failing, stop there and fix the build before chasing runtime behavior.

## What to Test in the Alpine Image

These are the test layers for future sessions.

### Layer A: Dockerfile and package layer

Goal:

- confirm the Alpine image can be built reliably.

Checks:

- `docker build -f Dockerfile-Alpine .`
- package installation succeeds,
- helper repositories clone successfully,
- the image starts with the expected entrypoint.

### Layer B: Compose wiring layer

Goal:

- confirm the Alpine compose file is structurally valid.

Checks:

- `docker compose -f docker-compose-alpinekoha.yml config`
- service names resolve correctly,
- volumes and networks are still valid,
- the Koha service points at the Alpine Dockerfile.

### Layer C: Bootstrap layer

Goal:

- confirm the Alpine Koha container can start far enough to validate source and helper availability.

Checks:

- `run.sh` starts,
- source tree validation runs,
- Koha helper scripts are present,
- database and broker variables are wired.

### Layer D: Service-split layer

Goal:

- confirm the image can talk to the services that remain external.

Checks:

- MariaDB readiness,
- RabbitMQ STOMP reachability,
- Memcached connectivity,
- optional OpenSearch if the stack includes it.

### Layer E: Koha behavior layer

Goal:

- confirm the Alpine image can eventually execute the same instance lifecycle as the current stack.

Checks:

- `koha-create` succeeds,
- `koha-enable` succeeds,
- `koha-plack` and `koha-z3950-responder` behave as expected,
- the instance survives a restart without reinitializing an existing database.

## Reporting Routine

Every future Alpine session should end with a short report using this template.

### Session report template

- Date:
- Files touched:
- Compose state:
- Dockerfile state:
- Build result:
- Runtime result:
- First failure point:
- Most likely root cause:
- Next smallest fix:
- Validation performed:
- Validation still missing:

### How to classify outcomes

Use one of these labels for the main result:

- `blocked` if the build cannot proceed,
- `buildable` if the Dockerfile builds but the container cannot start,
- `bootable` if the container starts but Koha setup fails,
- `operational` if the container reaches a useful Koha runtime state.

### Evidence to capture

When a test fails, capture only the narrowest useful proof:

- the first failing command,
- the first failing log snippet,
- the exact package name or script that failed,
- and the smallest possible next edit.

Do not collect broad logs unless the narrow failure is ambiguous.

## Recommended Future Session Order

When resuming the work later, use this order:

1. Rebuild the Alpine image.
2. Re-run the Alpine compose config check.
3. Start the supporting services.
4. Boot the Koha container.
5. Record the first failure point.
6. Fix only that failure.
7. Re-run the same check.

That cycle keeps the Alpine migration controlled and prevents unrelated changes from accumulating.

## Exit Criteria for a Session

A session is complete when one of the following is true:

- the Alpine build regressed and the regression is documented,
- the Alpine image got one step further than the previous session and the delta is recorded,
- or the current failure is understood well enough that the next session can begin with a specific fix.

If none of those are true, the session ended too early.
