# Koha Common Alpine Gap Analysis

## Purpose

This document breaks down what `koha-common` currently assumes about Debian/Ubuntu and what must change for Alpine.

## Executive Summary

The main blocker is not Koha application code itself. The blocker is the Debian packaging and helper layer that surrounds Koha:

- instance lifecycle helpers (`koha-create`, `koha-shell`, `koha-enable`, `koha-plack`, `koha-z3950-responder`, `koha-rebuild-zebra`)
- Apache integration helpers and config snippets
- Debian init/service conventions
- Debian package manager checks inside maintainer-era scripts

The most practical Alpine strategy is:

1. reuse Koha upstream Debian scripts as the source layer,
2. install them into an Alpine compatibility layout,
3. patch the OS-specific assumptions, and
4. externalize only services that already have a clean network contract.

## Gap Table

### 1) Package manager assumptions

Current Debian behavior:

- `apt`, `apt-get`, `apt-cache`, `dpkg-query`
- Debian repository setup in the image build
- package-based logic for optional installs and checks

Alpine target:

- `apk` for package install/remove
- no runtime dependency on Debian package metadata
- no `dpkg`-based feature detection inside the container

Required work:

- replace all `apt` calls in `files/run.sh`
- remove or guard `dpkg-query` and `apt-cache` checks inside ported helper scripts
- make optional packages go through an Alpine-specific installer function

### 2) Apache integration

Current Debian behavior:

- `a2enmod`, `a2ensite`, `a2dissite`
- Apache site files managed by `koha-enable`
- Apache restart/enable logic baked into Koha lifecycle commands

Alpine target:

- either keep Apache local for the first milestone, or
- define a separate web-container contract before externalizing it

Required work:

- preserve Apache locally during the first Alpine milestone unless helper scripts are rewritten
- if Apache is externalized later, generate vhost artifacts instead of editing local Apache state directly

Recommendation:

- do not externalize Apache first
- Apache is coupled to Koha instance enablement and will require more than a container split

### 3) RabbitMQ integration

Current behavior:

- Koha workers talk to RabbitMQ via network settings
- `run.sh` currently starts RabbitMQ as if it were local infrastructure

Alpine target:

- RabbitMQ should be a sibling container
- Koha should consume broker host/port/user/pass/vhost through environment variables

Required work:

- remove local `service rabbitmq-server ...` assumptions
- ensure `koha-create` and `run.sh` treat broker settings as external inputs
- validate worker startup against a broker container

Recommendation:

- RabbitMQ is the best first external-service candidate

### 4) MariaDB integration

Current behavior:

- the database is already externalized in compose
- `run.sh` still writes local config files for the Koha instance to use

Alpine target:

- keep MariaDB external
- ensure Koha only relies on host/port/user/pass

Required work:

- keep the compose DB service
- remove any hidden assumption that MariaDB is local to the Koha container

Recommendation:

- keep external from the start

### 5) Memcached integration

Current behavior:

- already runs as a separate container in compose
- Koha expects a host/port endpoint

Alpine target:

- keep external
- make sure `koha-sites.conf` and `run.sh` continue to accept host/port config

Recommendation:

- keep external from the start

### 6) OpenSearch integration

Current behavior:

- already external in the profile-based compose setup
- Koha uses URL and credential environment inputs

Alpine target:

- keep external
- validate the TLS/CA handling still works when the main image becomes Alpine

Recommendation:

- keep external from the start

### 7) Service lifecycle and init scripts

Current Debian behavior:

- `/etc/init.d/koha-common`
- `koha-common.service`
- LSB helper dependencies
- pidfile and daemon management built around Debian utilities

Alpine target:

- no dependency on Debian init scripts at runtime
- direct process control or Alpine-compatible wrappers

Required work:

- patch or replace `koha-common` init/service behavior
- avoid rewriting the web lifecycle in the first pass

### 8) Filesystem layout

Current Debian behavior:

- `/etc/default/koha-common`
- `/usr/share/koha/bin/koha-functions.sh`
- `/etc/koha/sites/<instance>`
- `/var/lib/koha`, `/var/cache/koha`, `/var/log/koha`, `/var/run/koha`

Alpine target:

- preserve the same layout where possible
- install a compatibility layer that mirrors these paths

Required work:

- copy upstream templates and scripts into Alpine-friendly locations
- keep the instance model stable so `run.sh` and the tests can remain recognizable

## What Should Move Out of the Main Image Early

Recommended external containers for the Alpine version:

- MariaDB
- Memcached
- RabbitMQ
- OpenSearch
- Traefik

Recommended to keep in the Koha image for the first Alpine milestone:

- Apache
- Koha instance lifecycle helpers
- Plack startup/shutdown logic
- any helper that still edits Apache site files or local instance config

## What to Avoid in the First Pass

- moving Apache into a separate web container before `koha-enable` and `koha-plack` are Alpine-safe
- relying on `dpkg` or Debian package state inside the runtime container
- introducing a new supervisor model before the compatibility layer is stable
- externalizing too many services before a first bootable Alpine image exists

## First Implementation Milestones

1. Build Alpine image with Koha helper commands available.
2. Externalize RabbitMQ and pass broker settings through compose.
3. Keep Apache local while porting the Koha lifecycle helpers.
4. Validate that Koha instance creation, startup, and restart still work.
5. Only then evaluate whether Apache should move to a dedicated web container.

## Practical Decision

If the goal is to reduce the main image quickly while keeping risk bounded, RabbitMQ is the right first split. Apache is not a good first split because it is part of the Koha instance lifecycle contract, not just a generic web server.
