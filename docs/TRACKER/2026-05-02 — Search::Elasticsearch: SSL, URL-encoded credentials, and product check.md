---
title: "Search::Elasticsearch: SSL, URL-encoded credentials, and product check"
date: 2026.05.02
tags:
 - ElasticSearch
 - SSL
 - credentials
---
# 2026-05-02 — Search::Elasticsearch: SSL, URL-encoded credentials, and product check

## Symptom

After fixing the Docker network, the koha container could TCP-connect to `os01:9200`, but `rebuild_elasticsearch.pl` still failed with `[NoNodes]`. Three independent bugs in the `Search::Elasticsearch` Perl library combined to cause this.

## Cause A — SSL certificate verification

**Error at HTTPS level**: `IO::Socket::SSL: SSL connect attempt failed … certificate verify failed`.
`ELASTIC_SERVER=https://os01:9200` triggers HTTPS. The `Search::Elasticsearch` Perl module (version 8.12) uses `Search::Elasticsearch::Cxn::HTTPTiny` as its HTTP backend, **not** `LWP::UserAgent`. Therefore the environment variable `PERL_LWP_SSL_VERIFY_HOSTNAME=0` (which only affects `LWP`) has **no effect** here.

### How the HTTPTiny backend handles SSL options

The relevant code in `HTTPTiny.pm` (lines 79–82):

```perl
if ( $self->is_https && $self->has_ssl_options ) {
    $args{SSL_options} = $self->ssl_options;
    if ( $args{SSL_options}{SSL_verify_mode} ) {   # 0 is falsy → this branch is skipped
        $args{verify_ssl} = 1;
    }
}
```

`SSL_options` is a hashref passed straight through to `IO::Socket::SSL`. Setting `SSL_verify_mode => 0` (falsy) leaves `verify_ssl` unset (defaulting to `0` = no hostname verify), and passes `SSL_options => { SSL_verify_mode => 0 }` to `IO::Socket::SSL`, which interprets `SSL_VERIFY_NONE`. This correctly disables certificate verification.

### How to inject `ssl_options` into Koha's constructor call

Koha's `koha-conf.xml` has an `<elasticsearch>` block. Every XML child element in that block is collected into a hashref and passed as keyword arguments to `Search::Elasticsearch->new(...)`. The block is generated at startup from a template:

```xml
<!-- files/templates/koha-conf-site.xml.in -->
<elasticsearch>
    <server>${ELASTIC_SERVER}</server>
    <index_name>koha_${KOHA_INSTANCE}</index_name>
    ${ELASTIC_OPTIONS}
</elasticsearch>
```

`${ELASTIC_OPTIONS}` is expanded by `envsubst` from the container environment. So setting:

```bash
ELASTIC_OPTIONS=<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>
```

causes the generated `koha-conf.xml` to contain:

```xml
<elasticsearch>
    <server>https://os01:9200</server>
    <index_name>koha_kohadev</index_name>
    <ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>
</elasticsearch>
```

`C4::Context->config('elasticsearch')` parses this into:

```perl
{
  server       => 'https://os01:9200',
  index_name   => 'koha_kohadev',
  ssl_options  => { SSL_verify_mode => 0 },
}
```

…which is passed to `Search::Elasticsearch->new(ssl_options => { SSL_verify_mode => 0 })`, disabling certificate verification in the `HTTPTiny` backend.

**Fix**: Add `<ssl_options><SSL_verify_mode>0</SSL_verify_mode></ssl_options>` to `ELASTIC_OPTIONS` in `env/.env`.