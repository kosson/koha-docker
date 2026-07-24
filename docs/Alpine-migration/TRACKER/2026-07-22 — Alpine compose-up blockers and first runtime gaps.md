---
title: "Alpine compose-up blockers and first runtime gaps"
date: 2026-07-22
tags:
  - alpine
  - compose
  - runtime
  - tracker
---
# 2026-07-22 — Alpine compose-up blockers and first runtime gaps

## What I ran

I brought up the Alpine test stack with `docker-compose-alpinekoha.yml` and then reran it with the workspace Koha checkout mounted as `SYNC_REPO` so the container could get past source validation.

## Issues observed

### 1) Missing external Docker networks

The Alpine compose file requires these external networks:

- `knonikl`
- `opensearch-36_osearch`

On the first compose-up attempt, Docker failed before the Koha container could start:

- `network knonikl not found`

A quick network check also showed:

- `frontend` existed
- `knonikl` did not exist
- `opensearch-36_osearch` did not exist

Those networks had to be created manually before the stack could progress further.

### 2) Invalid `SYNC_REPO` in the loaded env file

After the networks were created, the Koha container still exited early because the source mount path coming from `env/.env` did not exist in this workspace.

Observed log line:

- `The environment variable SYNC_REPO does not point to a valid Koha git repository`

This is an environment mismatch, not an Alpine code failure, but it blocks startup until the bind mount points at a real Koha checkout.

### 3) Missing Perl runtime dependency in the Alpine image

With `SYNC_REPO` overridden to the workspace Koha checkout, the Koha container started farther and then failed inside `cp_debian_files.pl`.

Observed error:

- `Can't locate Modern/Perl.pm in @INC`

This means the Alpine image still lacks at least one Perl dependency required by the Koha Debian staging script. The failure happens while running:

- `/kohadevbox/misc4dev/cp_debian_files.pl`

So the current Alpine runtime can start, but it is still missing enough Perl modules to complete the Koha file-staging phase.

## Informational warnings seen but not treated as blockers

- MariaDB logged `create_uring failed: falling back to libaio`
- RabbitMQ logged a deprecation warning for `management_metrics_collection`

These did not stop startup.

## Current interpretation

The Alpine test ground is now past Docker network setup and past the source-validation gate. The next real blocker is the missing Perl module set inside the Alpine image, starting with `Modern::Perl`.

## Next step

Add the missing Perl runtime dependencies to the Alpine image, then rerun the same compose-up path with the workspace `SYNC_REPO` override until `cp_debian_files.pl` gets past the current dependency wall.

## Rerun update (2026-07-22 16:17:57Z)

After adding `Modern::Perl` via `cpanm`, the stack moved past the first Perl dependency error and exposed the next blocker set.

### 4) Debian staging script expects filesystem paths not present in Alpine image

The Koha container now reaches `cp_debian_files.pl`, but that script expects Debian-like target directories that do not exist yet in this Alpine image.

Observed failures include:

- `cp: target '/etc/koha': No such file or directory`
- `cp: cannot create regular file '/usr/share/koha/intranet/htdocs': No such file or directory`
- `cp: cannot create regular file '/usr/share/koha/opac/htdocs': No such file or directory`
- `cp: cannot create regular file '/usr/share/koha/bin': No such file or directory`
- `cp: cannot create regular file '/etc/cron.d/koha-common': No such file or directory`
- `cp: cannot create regular file '/etc/default/koha-common': No such file or directory`

### 5) Docbook tooling path mismatch

`xsltproc` also fails while trying to generate manpages because the expected stylesheet path is missing:

- `failed to load external entity /usr/share/xml/docbook/stylesheet/docbook-xsl-ns/manpages/docbook.xsl`

### 6) Koha helper bootstrap stops on missing koha-functions.sh

After partial staging, startup fails with:

- `Error: /usr/share/koha/bin/koha-functions.sh not present.`

This confirms the current blocking layer is no longer `Modern::Perl`; it is Debian-layout compatibility in the Alpine image.

## Updated next step

Create the required Debian-expected directories in `Dockerfile-Alpine` before runtime staging, then rerun compose-up to see whether `cp_debian_files.pl` can fully stage `/usr/share/koha/bin/koha-functions.sh` and let `koha-create` continue.

## Rerun update (2026-07-22 16:26:22Z)

Multiple iterative reruns were executed, and the blocker frontier moved significantly forward.

### 7) `Modern::Perl` package naming on Alpine

`perl-modern-perl` was not available from `apk` for this base image. The module was installed via `cpanm` instead.

### 8) Debian layout compatibility layer expanded

To let Debian-oriented staging scripts progress, Alpine image compatibility was expanded with:

- Debian-expected directories (`/etc/koha`, cron/default/logrotate paths, `/usr/share/koha/*`, Apache site dirs)
- DocBook stylesheet tree mapping (`docbook-xsl-ns` expected path to Alpine package layout)
- Apache control/tooling shims (`apachectl`, `apache2ctl`, `a2ensite`, `a2dissite`, `a2enmod`, `a2dismod`)
- User/service helper shims (`adduser`, `daemon`, `/lib/lsb/init-functions`, `service`, `rc-service`, `/etc/init.d/apache2`)

Result: `cp_debian_files.pl` now completes far enough to generate Koha manpages successfully.

### 9) Database bootstrap progression

`koha-create` moved through several blockers during reruns:

- local socket fallback due missing `/etc/mysql/debian.cnf`
- TLS requirement mismatch (`SSL is required, but the server does not support it`)
- non-idempotent re-runs (`database exists`)

Mitigations applied:

- generated `/etc/mysql/debian.cnf` from `/etc/mysql/koha-common.cnf`
- explicitly disabled client SSL in generated MySQL config files
- Alpine bootstrap now auto-switches to `--use-db` when `koha_kohadev` already exists

### 10) Current runtime state

Current container status is `running` (not exiting immediately anymore).

Observed at latest tail:

- `[koha-create] Detected existing database koha_kohadev; using --use-db`
- `[service shim] apache2 restart (no-op in container)`
- `[koha-create] WARNING: bootstrap failed in Alpine compatibility mode; continuing to surface downstream blockers`
- followed by later startup tasks (`koha-l10n` handling) without an immediate fatal exit.

### Residual known warnings

- OpenRC still prints non-fatal environment warnings (`hwdrivers/dev` and `machine-id/dev`)
- `rm /usr/share/man/man8/koha-*.8.gz` may still report no matches before gzip

## Updated next step

Continue runtime validation with functional probes (web endpoints, Koha worker/plack behavior, DB schema readiness) now that startup no longer fails at the early Debian-compatibility gates.

## Functional probe update (2026-07-22 16:28:27Z)

Functional probes were executed against the currently running Alpine stack.

### Probe results

- Container status: `koha` service is `Up` in `docker compose ps`.
- HTTP endpoints: `http://127.0.0.1:8080` and `http://127.0.0.1:8081` both return `000` with `Recv failure: Connection reset by peer`.
- Process snapshot: only `/bin/bash /kohadevbox/run.sh` is active in the Koha container; no `httpd`, `starman`, or worker process was observed during probe time.
- DB readiness: schema exists and is populated enough to report `295` tables in `koha_kohadev`.

### Current functional blocker frontier

Startup is presently blocked in the OpenSearch wait phase:

- `Waiting for OpenSearch endpoint from Koha container...`
- repeated `attempt N/60: TCP port os01:9200 not reachable`

This prevents Apache/Plack service start, which explains why mapped host ports reset connections even though the container itself stays up.

## Updated next step

Decide one of two paths for Alpine test-ground readiness:

1. Ensure an OpenSearch endpoint is reachable at `os01:9200` from the Koha container; or
2. Run the Alpine Koha profile with OpenSearch disabled for bootstrap (`KOHA_ELASTICSEARCH=no`) so web service startup can proceed and HTTP probes can pass.

## Option-2 execution update (2026-07-22 16:35:21Z)

Bootstrap-first path was executed with explicit runtime overrides:

- `SYNC_REPO=/mnt/beckie2/DEVELOPMENT/koha-docker/koha`
- `KOHA_ALPINE_ELASTICSEARCH=no`

### What changed in configuration

- Alpine compose now defaults this profile’s search toggle from `KOHA_ALPINE_ELASTICSEARCH`.
- OpenSearch wait logic in `files-alpine/run.sh` now uses `ELASTIC_SERVER` host:port when search is enabled, instead of a hardcoded `os01:9200` target.

This keeps OpenSearch wiring explicit and testable while allowing bootstrap-first operation.

### Current observed behavior

- No OpenSearch wait-loop messages are emitted in option-2 mode.
- Container remains running while startup provisioning continues.
- Provisioning is currently in the `yarn install` phase (`node /usr/local/bin/yarn install --modules-folder /kohadevbox/node_modules`).
- HTTP probes still return connection reset at this stage (expected while startup provisioning has not reached web-service launch).

## Updated next step

After yarn/provisioning completes, rerun HTTP/process probes. If needed, explicitly trigger Apache startup step and verify 8080/8081 response codes.

OpenSearch wiring path remains available for later integration runs by setting:

- `KOHA_ALPINE_ELASTICSEARCH=yes`
- `ELASTIC_SERVER=os01:9200` (or another reachable endpoint)

## Option-2 dependency-closure update (2026-07-22 16:53Z)

Continued bootstrap-first reruns were executed with:

- `SYNC_REPO=/mnt/beckie2/DEVELOPMENT/koha-docker/koha`
- `KOHA_ALPINE_ELASTICSEARCH=no`
- `KOHA_ALPINE_SKIP_YARN_INSTALL=yes`

### Added Alpine Perl runtime dependencies during this cycle

- `perl-list-moreutils` (fixes `List::MoreUtils`)
- `perl-sereal-encoder`, `perl-sereal-decoder` (fixes `Sereal::Encoder` chain)
- `perl-class-accessor` (fixes `Koha::Cache::Object` base class)
- `perl-xml-libxml` (fixes `XML::LibXML` in `Koha::Config`)
- `perl-dbi`, `perl-dbd-mysql` (fixes DBI driver layer import failures)
- `perl-json` (fixes `JSON.pm` in `C4::Log`)
- `cpanm Struct::Diff` (Alpine has no `perl-struct-diff` package)
- `perl-log-log4perl` (fixes `Log::Log4perl` in `Koha::Logger`)
- `perl-class-inspector` (fixes `Class::Inspector`)
- `perl-mojolicious` (fixes `Mojo::JSON`)
- `cpanm DateTime::Format::MySQL` with preinstalled Alpine deps (`perl-datetime`, `perl-datetime-format-builder`, `perl-datetime-format-strptime`, `perl-params-validate`)

### Failure frontier progression observed

The runtime moved through these fatal compile blockers in order:

1. `List::MoreUtils`
2. `Sereal::Encoder`
3. `Class::Accessor`
4. `XML::LibXML`
5. `DBI`
6. `JSON.pm`
7. `Struct::Diff`
8. `Log::Log4perl`
9. `Class::Inspector`
10. `Mojo::JSON`
11. `DateTime::Format::MySQL`
12. current blocker: `CGI.pm`

Current fatal tail:

- `Can't locate CGI.pm in @INC ... at /kohadevbox/koha/C4/Templates.pm line 6`
- `BEGIN failed--compilation aborted ...`
- `do_all_you_can_do.pl` exits `2`

### Current interpretation

Option-2 wiring is behaving as intended (OpenSearch gating disabled for bootstrap), and dependency closure is consistently pushing the startup further into Koha runtime initialization. HTTP ports `8080/8081` remain unavailable only because bootstrap still exits at Perl module resolution time.

### Next step

Add CGI runtime support (`perl-cgi`) and rerun the same option-2 cycle to continue advancing toward first HTTP readiness.

## Service restart + issue tracking update (2026-07-22 17:06Z)

Services were started again with the same bootstrap-first profile:

- `SYNC_REPO=/mnt/beckie2/DEVELOPMENT/koha-docker/koha`
- `KOHA_ALPINE_ELASTICSEARCH=no`
- `KOHA_ALPINE_SKIP_YARN_INSTALL=yes`

### Restart status

- `docker compose -f docker-compose-alpinekoha.yml up -d --build` completed successfully.
- `db`, `rabbitmq`, and `memcached` remained `Up`.
- `koha` container restarted and entered runtime bootstrap again.

### Fresh blocker observation

The runtime progressed past the prior `CGI.pm` frontier and now fails at:

- `Can't locate Template.pm in @INC ... at /kohadevbox/koha/C4/Templates.pm line 33`
- `BEGIN failed--compilation aborted ...`
- `do_all_you_can_do.pl` exits `2`

### Endpoint state after restart

- `http://127.0.0.1:8080 -> 000` (connection reset)
- `http://127.0.0.1:8081 -> 000` (connection reset)

### Interpretation

Service restart was successful and issue tracking confirms forward dependency progress: the blocker chain advanced from `CGI.pm` to `Template.pm`. HTTP availability is still gated by the unresolved Perl module frontier in `do_all_you_can_do.pl`.

### Next step

Add Template Toolkit runtime support (`perl-template-toolkit`) and rerun the same option-2 cycle.

## Template Toolkit follow-up (2026-07-22 17:10Z)

`perl-template-toolkit` was added and the stack was restarted with the same option-2 profile:

- `SYNC_REPO=/mnt/beckie2/DEVELOPMENT/koha-docker/koha`
- `KOHA_ALPINE_ELASTICSEARCH=no`
- `KOHA_ALPINE_SKIP_YARN_INSTALL=yes`

### Result

- `Template.pm` blocker is resolved.
- Bootstrap now fails later at Koha schema loading:

  - `Base class package "DBIx::Class::Schema" is empty ... at /kohadevbox/koha/Koha/Schema.pm line 10`
  - `BEGIN failed--compilation aborted at /kohadevbox/koha/Koha/Schema.pm line 10`
  - `Compilation failed in require at /kohadevbox/koha/Koha/Database.pm line 115`
  - `do_all_you_can_do.pl` exits `2`

### Endpoint probes

- `http://127.0.0.1:8080 -> 000` (connection reset)
- `http://127.0.0.1:8081 -> 000` (connection reset)

### Next step

Add DBIx::Class runtime support (`perl-dbix-class`) and rerun the same option-2 cycle.

## DBIx::Class + TLS behavior update (2026-07-22 17:16Z)

Follow-up work was completed to move beyond `Template.pm` and `DBIx::Class::Schema` blockers.

### What changed

- Added `cpanm DBIx::Class` in the Alpine image.
- Stabilized the CPAN build by preinstalling packaged deps:
  - `perl-dbd-sqlite`
  - `perl-sub-name`
- Added Alpine compatibility overrides to attempt plain-TCP DBI connects:
  - force `KOHA_ALPINE_FORCE_MYSQL_NO_SSL=yes`
  - append `mysql_ssl=0` in DSN generation for Alpine path

### What was validated

- `DBIx::Class` now installs successfully during image build.
- Runtime moved past the missing-DBIx class frontier.
- The generated Koha DSN is now explicit:
  - `dbi:mysql:database=koha_kohadev;host=db;port=3306;mysql_ssl=0`

### Current blocker (still fatal)

Despite the DSN override, runtime still fails at DB connect in `do_all_you_can.pl`:

- `DBI connect(...;mysql_ssl=0, ...) failed: TLS/SSL error: SSL is required, but the server does not support it`
- error surfaced from `Koha/Database.pm` / DBIx::Class connection path
- container exits before web services become available

### Endpoint probes

- `http://127.0.0.1:8080 -> 000`
- `http://127.0.0.1:8081 -> 000`

### Interpretation

Module-closure progress is real (DBIx stack now present), but Alpine DBD::mysql behavior is currently enforcing TLS in practice, even with explicit no-SSL DSN intent. This is now a driver/runtime compatibility issue rather than a missing-module issue.

### Next step

Evaluate one of these targeted remediations:

1. Switch to a DBI driver path that permits non-TLS MariaDB connections in this image; or
2. Enable TLS support on the MariaDB container so the enforced SSL client path succeeds.

## TLS remediation + new runtime frontier (2026-07-22 17:26Z)

The DBI TLS blocker was moved forward by enabling server-side TLS in the Alpine compose profile and wiring Koha to trust the local CA.

### What changed

- Added MariaDB TLS assets under `files/mariadb-ssl/`:
  - `ca-cert.pem`, `ca-key.pem`, `server-cert.pem`, `server-key.pem`
  - `mariadb-ssl.cnf`
- Updated `docker-compose-alpinekoha.yml`:
  - `db` now runs with `--ssl=ON`
  - DB service mounts TLS certs and conf file
  - `koha` service now mounts DB CA cert path read-only
- Updated Alpine entrypoint handling in `files-alpine/run.sh`:
  - post-bootstrap `koha-conf.xml` rewrite now enforces `<tls>yes</tls>`
  - injects `<ca>/etc/mysql/ssl/ca-cert.pem</ca>` when missing
- Removed Alpine DSN override in `Koha/Database.pm` that appended `mysql_ssl=0`
  (that override produced certificate trust failures once server TLS existed).

### What was validated

- DB service now reports:
  - `have_ssl=YES`
  - `require_secure_transport=OFF`
- Koha bootstrap progressed beyond the previous DB connect failure in `do_all_you_can_do.pl`.
- New frontend blocker moved to later bootstrap stages.

### New blockers after TLS fix

1. Missing runtime module chain in `setup_sip.pl`:

  - `Crypt::Eksblowfish::Bcrypt` (fixed by adding `perl-crypt-eksblowfish`)
  - `String::Random` (fixed by adding `perl-string-random`)
  - `Date::Calc` (fixed by adding `perl-date-calc`)
  - `Date::Manip` (fixed by adding `perl-date-manip`)
  - `Locale::Currency::Format` (fixed via `cpanm Locale::Currency::Format`)
  - `Array::Utils` (fixed via `cpanm Array::Utils`)
  - `MARC::Record` (fixed via `cpanm MARC::Record`)
  - `MARC::Record::MiJ` (fixed via `cpanm MARC::Record::MiJ`)
  - `MARC::File::XML` (fixed via `cpanm MARC::File::XML`)
  - `CGI::Session` (fixed via `perl-cgi-session`)
  - `GD::Barcode` (fixed via `cpanm GD::Barcode`)
  - `Class::Factory::Util` (fixed via `perl-class-factory-util`)
  - `Number::Format` (fixed via `cpanm Number::Format`)
  - `Readonly` (fixed via `perl-readonly`)
  - `Algorithm::Munkres` (fixed via `cpanm Algorithm::Munkres`)
  - `Parallel::ForkManager` (fixed via `perl-parallel-forkmanager`)
  - `Net::Stomp` (fixed via `cpanm Net::Stomp`)
  - `Mojolicious::Plugin::OAuth2` (fixed via `cpanm Mojolicious::Plugin::OAuth2`)
  - `JSON::Validator` (fixed via `cpanm JSON::Validator`)
  - `LWP::UserAgent` (fixed via `perl-libwww`)
  - `GD` / `GD.pm` (fixed via `perl-gd`)
  - `Text::Iconv` (fixed via `perl-text-iconv`)
  - `Algorithm::CheckDigits` (fixed via `cpanm Algorithm::CheckDigits`)
  - `Locale::Messages` / `Locale/Messages.pm` (fixed via `cpanm Locale::Messages`)
  - `DBIx::RunSQL` / `DBIx/RunSQL.pm` (fixed via `cpanm DBIx::RunSQL`)
  - `File::Slurp` / `File/Slurp.pm` (fixed via `perl-file-slurp`)
  - `HTML::Scrubber` / `HTML/Scrubber.pm` (fixed via `perl-html-scrubber`)
  - `Crypt::CBC` (fixed via `perl-crypt-cbc`)
  - `Bytes::Random::Secure` / `Bytes/Random/Secure.pm` (fixed via `perl-bytes-random-secure`)
  - `WWW::CSRF` / `WWW/CSRF.pm` (fixed via `cpanm WWW::CSRF`)
  - `Mojo::JWT` / `Mojo/JWT.pm` (fixed via `cpanm Mojo::JWT`)
  - `Net::CIDR` / `Net/CIDR.pm` (fixed via `perl-net-cidr`)
  - `Text::CSV_XS` / `Text/CSV_XS.pm` (fixed via `perl-text-csv_xs`)
  - `Business::ISBN` / `Business/ISBN.pm` (fixed via `perl-business-isbn`)
  - `Business::ISSN` / `Business/ISSN.pm` (fixed via `perl-business-issn`)
  - `Email::Address` / `Email/Address.pm` (fixed via `perl-email-address`)
  - `Email::MessageID` / `Email/MessageID.pm` (fixed via `perl-email-messageid`)
  - `Email::MIME` / `Email/MIME.pm` (fixed via `perl-email-mime`)
  - `Email::Stuffer` / `Email/Stuffer.pm` (fixed via `cpanm Email::Stuffer`)
  - current frontier: Bootstrap progresses past `setup_sip.pl` to SIP config, Apache restart; now fails on yarn build (frontend assets).

2. Zebra copy path expectation:
   - `/etc/koha/zebradb/marc_defs` was missing in one pass and is now precreated in Alpine runtime helpers.

### Endpoint probes (latest)

- `http://127.0.0.1:8080 -> 000`
- `http://127.0.0.1:8081 -> 000`

### Next step

Continue the same dependency-closure loop after adding `Date::Calc` and rerun compose-up to reach the next executable blocker.
