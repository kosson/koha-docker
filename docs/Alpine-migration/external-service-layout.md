# External Service Layout for the Alpine Koha Migration

## Purpose
This document sketches a practical service split for the Alpine-based Koha version.

## Recommended Split

### Keep external from the beginning
- MariaDB
- Memcached
- OpenSearch
- Traefik

### Externalize next
- RabbitMQ

### Keep local for the first Alpine milestone
- Apache
- Koha instance lifecycle helpers
- Plack management logic

## Why RabbitMQ First
RabbitMQ is the best early candidate for externalization because:
- Koha already treats it as a networked broker.
- The main image only needs host/port/user/password/vhost.
- It does not require Apache-style file mutation or local service enable/disable logic.

## Why Apache Should Stay Local Initially
Apache is tightly coupled to the Koha helper scripts:
- `koha-enable` edits Apache site configuration.
- `koha-plack` assumes Apache-side state.
- the existing lifecycle flow expects local Apache enable/disable and restart behavior.

If Apache is externalized too early, the migration becomes a web-tier redesign instead of a container split.

## Compose Shape

### Main Koha container
The main Koha container should receive only hostnames and credentials for external services.

Required environment inputs:
- `DB_HOSTNAME`
- `DB_USER`
- `DB_PASSWORD`
- `DB_NAME`
- `MEMCACHED_SERVERS`
- `MESSAGE_BROKER_HOST`
- `MESSAGE_BROKER_PORT`
- `MESSAGE_BROKER_USER`
- `MESSAGE_BROKER_PASS`
- `MESSAGE_BROKER_VHOST`
- `ELASTIC_SERVER` or equivalent OpenSearch URL

### RabbitMQ sibling container
A simple broker container can live beside the Koha image.

Example shape:
```yaml
services:
  rabbitmq:
    image: rabbitmq:3-management
    environment:
      RABBITMQ_DEFAULT_USER: ${KOHA_RABBITMQ_USER:-guest}
      RABBITMQ_DEFAULT_PASS: ${KOHA_RABBITMQ_PASS:-guest}
      RABBITMQ_DEFAULT_VHOST: ${KOHA_RABBITMQ_VHOST:-koha_${KOHA_INSTANCE:-kohadev}}
    ports:
      - "5672:5672"
      - "15672:15672"
    networks:
      - kohanet
```

Example Koha-side inputs:
```yaml
services:
  koha:
    environment:
      MESSAGE_BROKER_HOST: rabbitmq
      MESSAGE_BROKER_PORT: 5672
      MESSAGE_BROKER_USER: ${KOHA_RABBITMQ_USER:-guest}
      MESSAGE_BROKER_PASS: ${KOHA_RABBITMQ_PASS:-guest}
      MESSAGE_BROKER_VHOST: ${KOHA_RABBITMQ_VHOST:-koha_${KOHA_INSTANCE:-kohadev}}
```

## Future Web-Tier Split
If Apache is ever externalized, it should be done as a second migration step.

That split would need:
- generated Koha vhost and site configuration artifacts
- a web container that mounts those artifacts
- a replacement for the current `a2ensite` and Apache restart flow
- a clear contract for Plack startup and reverse-proxy routing

Suggested pattern for a later stage:
- `koha-app` container: Koha app, lifecycle helpers, config generation
- `koha-web` container: Apache or another web server that reads generated artifacts
- `rabbitmq` container: broker
- `db`, `memcached`, `opensearch`: external infrastructure

## Operational Rule
Only externalize a service if the Koha image can talk to it through a stable network contract and does not need to mutate the service's local config files during instance creation.

By that rule:
- RabbitMQ: yes
- Apache: not yet
