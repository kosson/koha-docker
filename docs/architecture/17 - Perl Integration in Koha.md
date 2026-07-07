---
title: "Perl Integration in Koha"
tags: [perl, cpan, perltidy, perlcritic, prove, dbi, dbd-mysql, moose, template, elasticsearch, cache-memcached, rabbitmq, stomp, git-bz, qa-tools, testing]
---
# Perl Integration in Koha

How Perl ties the Koha stack together — from runtime scripts to build tools.

## Overview

Koha is fundamentally a Perl application. The stack integrates Perl at multiple layers:

1. **Koha core** — Perl-based ILS (thousands of .pl, .pm, .cgi files)
2. **Development tooling** — Perl linters, formatters, test harnesses
3. **Runtime scripts** — Instance creation, config, service management
4. **Background jobs** — MARC import, indexing, notifications (via RabbitMQ)

## Perl in the Docker Image

### Installed Perl Packages

From Layer 7-8 of Dockerfile:

| Package | Purpose |
|---|---|
| `koha-common` | Core Koha (Perl ILS engine) |
| `libcarp-always-perl` | Debugging (always Carp on errors) |
| `libgit-repository-perl` | Git integration |
| `libmodule-install-perl` | Module build system |
| `libperl-critic-perl` | Code style checking |
| `libtest-differences-perl` | Test comparison utilities |
| `libtest-perl-critic-perl` | PerlCritic test harness |
| `libtest-perl-critic-progressive-perl` | Progressive policy testing |
| `libfile-chdir-perl` | Working directory management |
| `libdata-printer-perl` | Data dumping for debugging |
| `pmtools` | Perl module inspection tools |
| `perltidy` | Perl code formatter |
| `libtemplate-plugin-gettext-perl` | Template localization |
| `libdevel-cover-perl` | Code coverage |
| `libmoosex-attribute-env-perl` | MooseX attribute handling |
| `libtest-dbix-class-perl` | DBIx::Class testing |
| `libtap-harness-junit-perl` | JUnit test output |
| `libtext-csv-unicode-perl` | Unicode CSV handling |
| `libdevel-cover-report-clover-perl` | Clover coverage reports |
| `libwebservice-ils-perl` | ILS web services |
| `libselenium-remote-driver-perl` | Browser automation |

### CPAN Module Installation

At runtime (`run.sh`), if `LOAD_PACKAGES=yes`:
```bash
cpanm --installdeps /kohadevbox/koha
```

If `INSTALL_MISSING_FROM_CPMFILE=yes`:
```bash
cd /kohadevbox/koha
cpanm --installdeps .
```

This reads the `cpanfile` in the Koha source directory and installs any missing CPAN modules.

## Perl Runtime Scripts

### run.sh (Entrypoint)

Location: `files/run.sh` (585 lines, bash script)

Despite being a bash script, it orchestrates Perl processes:

```bash
# Start Koha service (Perl daemon)
service koha-common restart

# Start Koha job worker (Perl)
koha-job-worker kohadev start

# Rebuild search index (Perl)
perl /usr/share/koha/misc/elasticsearch/rebuild_index.pl

# Install packages (Perl CPAN)
cpanm --installdeps .
```

### Key Perl Files in Koha

| File | Location | Purpose |
|---|---|---|
| `koha-common` | `/usr/sbin/koha-common` | Service management daemon |
| `koha-admin` | `/usr/sbin/koha-admin` | Koha administration CLI |
| `koha-index-definition` | `/usr/sbin/koha-index-definition` | Search index management |
| `koha-job-worker` | `/usr/sbin/koha-job-worker` | Background job worker |
| `do_all_you_can_do.pl` | `/usr/share/koha/misc/translator/do_all_you_can_do.pl` | Translation tools |
| `insert_data.pl` | `/kohadevbox/misc4dev/insert_data.pl` | Demo data import |
| `rebuild_index.pl` | `/usr/share/koha/misc/elasticsearch/rebuild_index.pl` | Index rebuild |
| `koha-reload-starman` | `/kohadevbox/koha-reload-starman` | Hot reload utility |

## Perl Development Workflow

### Code Formatting

```bash
# Format a file
perltidy koha/admin/some_file.pl

# Check style (PerlCritic)
perlcritic koha/admin/some_file.pl

# Progressive criticism (ensures no regression in coding standards)
prove -l t/db.t
```

### Testing

```bash
# Run all tests
prove -l t/

# Run specific test file
prove -l t/koha/admin/auth_tag_structure.t

# Run with coverage
perl -Ilib -MDevel::Cover t/some_test.t

# JUnit output
prove -l -j TAP::Harness::JUnit t/
```

### Git + Bugzilla Integration

```bash
# Create a Bugzilla ticket from the current branch
git bz bug 12345

# Push changes to Bugzilla
git bz push

# Create a patch file
git bz create
```

The `git-bz` tool is symlinked to `/usr/bin/git-bz` in the Dockerfile.

## How Perl Scripts Connect to the Stack

### Perl → MariaDB

Koha uses `DBI` + `DBD::mysql` to connect to MariaDB:

```perl
# From koha-conf.xml:
# <db_name>koha_kohadev</db_name>
# <db_host>db</db_host>
# <db_port>3306</db_port>

use DBI;
my $dbh = DBI->connect(
    "DBI:mysql:koha_kohadev:db:3306",
    "koha_kohadev",
    $password,
    { AutoCommit => 1, RaiseError => 1 }
);
```

### Perl → OpenSearch

Koha uses `Elasticsearch::X::Koha` (or similar) to talk to OpenSearch:

```perl
# From ELASTIC_OPTIONS in koha-conf.xml:
# <hosts>http://os01:9200</hosts>
# <userinfo>
#   <username>admin</username>
#   <password>changeme</password>
# </userinfo>

use Elasticsearch;
my $es = Elasticsearch->new(
    hosts => ['https://os01:9200'],
    ssl => 1,
    username => 'admin',
    password => $password,
);
```

### Perl → Memcached

Koha uses `Cache::Memcached` for session and data caching:

```perl
use Cache::Memcached;
my $memd = Cache::Memcached->new({
    'servers' => ['memcached:11211'],
    'default_expires' => 3600,
});
```

### Perl → RabbitMQ (Background Jobs)

Koha uses STOMP protocol to talk to RabbitMQ:

```perl
# Koha job workers consume from RabbitMQ queues:
# - koha_import_records
# - koha_notify
# - koha_send_statistics
# etc.
```

## Perl Version

Ubuntu 24.04 ships with Perl 5.38.x.

Koha's specific Perl requirements are in the `cpanfile`:

```perl
# cpanfile excerpt:
requires 'Mojo::IOLoop';
requires 'Mojo::DOM';
requires 'DBI';
requires 'DBD::mysql';
requires 'Moose';
requires 'MooseX::NonMoose';
requires 'Template';
requires 'Elasticsearch';
requires 'Cache::Memcached';
# ... hundreds more
```

## Common Perl Issues in the Stack

### CRLF Line Endings

Perl scripts fail with `C:\r\n` line endings on Linux. The stack handles this in two places:

1. **Build time** (`Dockerfile`):
   ```dockerfile
   RUN sed -i 's/\r$//' /kohadevbox/run.sh
   ```

2. **Runtime** (`run.sh`):
   ```bash
   find /kohadevbox -name '*.pl' -exec sed -i 's/\r$//' {} +
   ```

### Missing CPAN Modules

If a Perl script fails with `Can't locate Some/Module.pm`:

```bash
# Check what's installed
cpan-outdated

# Install missing module
cpanm Some::Module

# Or install all missing from cpanfile
cpanm --installdeps /kohadevbox/koha
```

### Perl Warnings

`libcarp-always-perl` is installed to ensure all Perl warnings are visible (not silently ignored):

```bash
# Check Perl warnings in logs
docker logs koha-docker-koha-1 | grep -i "warning\|error\|fatal"
```
