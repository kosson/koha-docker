---
title: "Networking"
tags: [networking, docker-networks, kohanet, knonikl, opensearch-36_osearch, frontend, osearch, dns, traefik-routing, nip.io, ipv6, host-ports]
---

# Networking

Five Docker networks interconnect the containers.

---

## Network List

| Network | Scope | Created By | Purpose |
|---|---|---|---|
| `kohanet` | Internal | `docker-compose.yml` | Koha internal: db + memcached + koha |
| `knonikl` | Shared | External (pinned name) | Dashboards ↔ Koha (cross-project) |
| `opensearch-36_osearch` | Shared | External (pinned name) | OpenSearch cluster + Koha joins |
| `frontend` | Shared | External (pinned name) | Traefik ↔ Koha ↔ Dashboards |
| `osearch` | Internal | `OpenSearch-3.6/docker-compose.yml` | OpenSearch cluster internal (aliased to `knonikl`) |

## Network Membership

### koha container (4 networks)
```
├── kohanet          → talk to: db:3306, memcached:11211
├── opensearch-36_osearch → talk to: os01-os05:9200
├── knonikl          → (shared with Dashboards)
└── frontend         → Traefik routing, access to Dashboards
```

### db container (1 network)
```
└── kohanet          → only reachable from koha
```

### memcached container (1 network)
```
└── kohanet          → only reachable from koha
```

### OpenSearch nodes (1 network each)
```
└── osearch          → node-to-node communication
    └── os01:9200    → only node with host port binding
```

### dashboards container (3 networks)
```
├── osearch          → talk to os01:9200, os02:9200
├── knonikl          → shared with koha
└── frontend         → Traefik routing
```

### traefik container
```
├── frontend         → read labels from koha, dashboards
└── host network     → listen on :8000, :8443
```

## Docker DNS

Docker Compose provides automatic DNS resolution within each network. Container names (or `container_name`) serve as hostnames:

- `db` → MariaDB (on kohanet)
- `memcached` → Memcached (on kohanet)
- `os01` through `os05` → OpenSearch nodes (on osearch)
- `dashboards` → OpenSearch Dashboards
- `koha` → Koha container

## Traefik Routing

Traefik uses **Docker labels** on the koha and dashboards containers to define routers:

### OPAC Router
```yaml
traefik.http.routers.koha-opac.rule=Host(`kohadev.{KOHA_DOMAIN}`)
traefik.http.routers.koha-opac.entrypoints=web
traefik.http.routers.koha-opac.service=koha-opac-svc
traefik.http.services.koha-opac-svc.loadbalancer.server.port=8080
```

### Staff Router
```yaml
traefik.http.routers.koha-staff.rule=Host(`kohadev-intra.{KOHA_DOMAIN}`)
traefik.http.routers.koha-staff.entrypoints=web
traefik.http.routers.koha-staff.service=koha-staff-svc
traefik.http.services.koha-staff-svc.loadbalancer.server.port=8081
```

### Dashboards Router
```yaml
traefik.http.routers.dashboards.rule=Host(`dashboards.{DASHBOARDS_DOMAIN}`)
traefik.http.routers.dashboards.entrypoints=web
traefik.http.routers.dashboards.service=dashboards-svc
traefik.http.services.dashboards-svc.loadbalancer.server.port=5601
```

### Optional HTTP → HTTPS Redirect
```yaml
# Commented out by default
traefik.http.middlewares.http-redirect.redirectscheme.scheme=https
traefik.http.middlewares.http-redirect.redirectscheme.permanent=true
```

## External Network Creation

`stack.sh` ensures the three external networks exist before starting:

```bash
ensure_frontend_network() {
  if ! docker network inspect frontend >/dev/null 2>&1; then
    docker network create frontend
  fi
}

ensure_extra_networks() {
  for net in knonikl opensearch-36_osearch; do
    if ! docker network inspect "$net" >/dev/null 2>&1; then
      docker network create "$net"
    fi
  done
}
```

## IPv6

The `kohanet` network explicitly has IPv6 **disabled**:
```yaml
networks:
  kohanet:
    enable_ipv4: true
    enable_ipv6: false
```

This is a precaution against IPv6-related issues documented in ISSUES.md.

## Host Network Access

| Service | Host Port | How to reach |
|---|---|---|
| OPAC | 8080 | `http://localhost:8080/` (direct) |
| Staff | 8081 | `http://localhost:8081/` (direct) |
| Traefik HTTP | TRAEFIK_HTTP_PORT (default 8000) | `http://localhost:8000/` |
| Traefik HTTPS | TRAEFIK_HTTPS_PORT (default 8443) | `https://localhost:8443/` |
| Traefik Dashboard | TRAEFIK_DASHBOARD_PORT (default 8083) | `http://localhost:8083/` |
| OpenSearch | 9200 | `https://localhost:9200/` (admin:password) |
| OpenSearch PA | 9600 | `http://localhost:9600/` |
| Dashboards | 5601 | `http://localhost:5601/` (direct) |
