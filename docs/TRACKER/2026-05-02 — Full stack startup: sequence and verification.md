---
title: Full stack startup: sequence and verification
date: 2026.05.02
tags:
 - startup
 - verification
---
# 2026-05-02 — Full stack startup: sequence and verification

## Complete startup sequence

The three projects must be started in order because each depends on Docker networks or services created by the previous one.

### Step 1 — Build the OpenSearch cluster images (first time or after Dockerfile changes)

```bash
cd /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/OpenSearch-3.6
docker compose build
```

This builds the custom image (with `analysis-icu`) for all five nodes. Only needed after modifying the Dockerfile or upgrading the OpenSearch version. On subsequent runs, the cached images are reused and this step can be skipped.

### Step 2 — Start the OpenSearch cluster

```bash
cd /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/OpenSearch-3.6
docker compose up -d
```

Wait for the cluster to be green (all five nodes elected, leader chosen):

```bash
# Poll until status=green
until curl -sk -u 'admin:test@Cici24#ANA' \
    https://localhost:9200/_cluster/health | grep -q '"status":"green"'; do
  echo "Waiting for OpenSearch cluster..."; sleep 5
done
echo "Cluster is green"
```

The network `opensearch-36_osearch` is created by this compose project. Step 3 will fail with `network not found` if this step is skipped or if the cluster has not yet finished initialising.

### Step 3 — Initialise the Koha database (first run or to reset state)

The `koha` container's `run.sh` expects a **fresh, empty database** named `koha_${KOHA_INSTANCE}`. If the database already contains tables from a previous run, `do_all_you_can_do.pl` will report conflicts and the container may exit early.

```bash
docker exec koha-docker-db-1 mysql -uroot -ppassword -e "
  DROP DATABASE IF EXISTS koha_kohadev;
  CREATE DATABASE koha_kohadev
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;
  GRANT ALL PRIVILEGES ON koha_kohadev.* TO 'koha_kohadev'@'%';
  FLUSH PRIVILEGES;
"
```

This requires the `db` container to already be running. On first launch, start it with:

```bash
docker compose \
  -f /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/docker-compose.yml \
  --env-file /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/env/.env \
  --project-directory /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker \
  up -d db memcached
```

Wait ~5 seconds for MariaDB to initialise before running the `mysql` command above.

### Step 4 — Start (or restart) the Koha container

```bash
docker compose \
  -f /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/docker-compose.yml \
  --env-file /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker/env/.env \
  --project-directory /media/expansion/DEVELOPMENT/KOHA-DOCKER-SOLUTIONS/koha-docker \
  up -d --force-recreate koha
```

`--force-recreate` ensures the container picks up any changes to environment variables or bind mounts, and always starts with a clean container state (no leftover Plack PIDs, stale sockets, etc.).

### Step 5 — Follow the startup logs

## Cause B — URL-encoded credentials produce a wrong Authorization header

**Error**: HTTP 401 Unauthorized from OpenSearch → node marked dead → `[NoNodes]`.

The original `ELASTIC_SERVER` was:

```ini
ELASTIC_SERVER=https://admin:test%40Cici24%23ANA@os01:9200
```

The password `test@Cici24#ANA` was percent-encoded (`%40` for `@`, `%23` for `#`) because those characters have special meaning in URLs.

### What goes wrong inside `Search::Elasticsearch`

`Role::Cxn` parses the node URL using a URI library. The URI library **decodes** percent-encoding during parsing, so the extracted `userinfo` becomes `admin:test@Cici24#ANA`.
However, `Role::Cxn` then base64-encodes the **already-decoded** string to build the `Authorization: Basic ...` header — so the header is correct.

**BUT**: when the URL contains special characters (`@`, `#`) in the password portion, some URI library versions do not reliably parse the authority component. The `@` sign is the user-info/host separator, so `test@Cici24#ANA` in the password position confuses the parser. In the version installed, the password was extracted as `test%40Cici24%23ANA` (the URL-encoded form, left un-decoded), and that literal string was base64-encoded and sent as the password — which OpenSearch rejected.

### Fix

Remove the credentials from `ELASTIC_SERVER` entirely, and pass them via the `userinfo` constructor parameter instead:

```bash
ELASTIC_SERVER=https://os01:9200
```

`Role::Cxn` line 122 has a dedicated code path for the `userinfo` parameter:

```perl
if ( my $userinfo = $self->userinfo ) {
    $args{headers}{'Authoriza---
title:
date:
tags:
---tion'} = 'Basic ' . encode_base64($userinfo, '');
}
```

When `userinfo` is provided directly as a plain string (not via URL parsing), it is base64-encoded as-is — so `admin:test@Cici24#ANA` produces the correct header.

Add to `ELASTIC_OPTIONS`:

```ini
<userinfo>admin:test@Cici24#ANA</userinfo>
```

## Cause C — Elasticsearch 8.x product check rejects OpenSearch

**Error**: `[ProductCheck] ** The client noticed that the server is not Elasticsearch` → node marked dead → `[NoNodes]`.

The installed `Search::Elasticsearch` Perl module is version **8.12**. Starting from version 8, the library enforces a product-compatibility check in `Role::Cxn::process_response` (line 369):

```perl
if ( $self->client_version >= 8 and $code >= 200 and $code < 300 ) {
    my $product = $headers->{'x-elastic-product'} // '';
    if ( $product ne 'Elasticsearch' ) {
        throw(
            'ProductCheck',
            "The client noticed that the server is not Elasticsearch "
            . "and we do not support this server"
        );
    }
}
```

OpenSearch returns `x-elastic-product: OpenSearch` in its response headers (not `Elasticsearch`). Every successful HTTP 2xx response triggers the check, which throws `ProductCheck`, which marks the node as dead. The very first request (`GET /`) already fails this way, so no index operations ever reach the server.

### Fix

Pass `<client_version>7</client_version>` via `ELASTIC_OPTIONS`. When `client_version` is set to `7`, the condition `$self->client_version >= 8` is false and the product check is entirely skipped. The rest of the 8.x API (request format, response parsing) continues to work normally with OpenSearch 3.6.

### Combined fix — `env/.env`

All three fixes combine into two environment variables:

```bash
# No credentials in the URL — avoids URI-parsing ambiguity with special chars (@, #)
ELASTIC_SERVER=https://os01:9200

# Three XML elements injected into koha-conf.xml's <elasticsearch> block:
#   ssl_options  → disables IO::Socket::SSL certificate verification
#   userinfo     → passes credentials as raw string, base64-encoded correctly
#   client_version → set to 7 to skip the ES 8.x product check that rejects OpenSearch
ELASTIC_OPTIONS=<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options><userinfo>admin:test@Cici24#ANA</userinfo><client_version>7</client_version>

# Kept for any LWP-based code paths (e.g., Koha's REST calls)
PERL_LWP_SSL_VERIFY_HOSTNAME=0
```

These values produce the following `<elasticsearch>` block in the generated `koha-conf.xml`:

```xml
<elasticsearch>
    <server>https://os01:9200</server>
    <index_name>koha_kohadev</index_name>
    <ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>
    <userinfo>admin:test@Cici24#ANA</userinfo>
    <client_version>7</client_version>
</elasticsearch>
```

Which translates to this `Search::Elasticsearch->new(...)` call at runtime:

```perl
Search::Elasticsearch->new(
    nodes          => 'https://os01:9200',
    ssl_options    => { SSL_verify_mode => 0 },
    userinfo       => 'admin:test@Cici24#ANA',
    client_version => 7,
);
```

Verification (manual test inside the running container):

```log
SUCCESS: cluster=opensearch version=3.6.0
```

## Files changed

| File | Change |
|---|---|
| `koha-docker/env/.env` | `ELASTIC_SERVER`: stripped credentials from URL; `ELASTIC_OPTIONS`: added `ssl_options`, `userinfo`, `client_version`; `PERL_LWP_SSL_VERIFY_HOSTNAME=0` retained |