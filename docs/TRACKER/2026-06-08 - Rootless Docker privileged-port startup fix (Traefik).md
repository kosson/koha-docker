---
title: Rootless Docker privileged-port startup fix (Traefik)
date: 2026.06.08
tags:
 - rootless
 - docker
 - Traefik
 - ports
---
# 2026-06-08 - Rootless Docker privileged-port startup fix (Traefik)

## Problem

On first `./stack.sh start`, Traefik failed with:

```log
cannot expose privileged port 80 ...
net.ipv4.ip_unprivileged_port_start=1024
```

Host diagnostics confirmed Docker is running in rootless mode and cannot bind ports below 1024 by default.

## Root cause

Traefik was configured to publish privileged host ports (`80`/`443`) in `traefik/.env`, while the host kernel policy for unprivileged binds was `1024`.

## Changes made

Files updated:

- `traefik/.env`
  - `TRAEFIK_HTTP_PORT=80` -> `TRAEFIK_HTTP_PORT=8000`
  - `TRAEFIK_HTTPS_PORT=443` -> `TRAEFIK_HTTPS_PORT=8443`
- `env/.env`
  - `KOHA_PUBLIC_PORT=80` -> `KOHA_PUBLIC_PORT=8000`

## Effect

- Traefik now binds only non-privileged host ports in rootless Docker, so startup is deterministic and no longer fails on port-80 permission errors.
- Koha-generated public URLs remain consistent with Traefik by using port `8000`.
- Access endpoints become:
  - OPAC/Staff via Traefik HTTP: `http://<host-or-domain>:8000`
  - Traefik HTTPS: `https://<host-or-domain>:8443`

## Apply/run notes

Restart the stack so new env values are applied:

```bash
./stack.sh stop
./stack.sh start
```