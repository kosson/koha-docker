# Alpine Package Dependencies for Koha

## Purpose

This document maps the Debian package names found in [koha/debian/control.in](../../koha/debian/control.in) and [koha/debian/control](../../koha/debian/control) to the closest Alpine Linux counterparts for a Koha container image.

The mapping is intentionally best-effort:

- some Debian packages have direct Alpine equivalents,
- some need a different package name,
- some are better handled by CPAN instead of the Alpine package manager, and
- some Debian packaging concepts have no direct Alpine analogue and should be replaced by image logic or runtime configuration.

## How to read the table

- **Debian package** is the name in Koha's Debian packaging metadata.
- **Alpine correspondence** is the closest package name or implementation strategy for Alpine.
- **Notes** explain whether the item belongs in the image, should stay external, or should be handled another way.

## Core runtime correspondences

| Debian package | Alpine correspondence | Notes |
| --- | --- | --- |
| `apache2` | `apache2` | Direct equivalent. Keep local for the first Alpine milestone because Koha helper scripts still expect Apache lifecycle control. |
| `apache2-mpm-itk` | no direct equivalent | Alpine Apache does not ship the same MPM ITK packaging model. Use the default Apache worker/event setup and review Koha vhost/user isolation separately. |
| `libapache2-mpm-itk` | no direct equivalent | Same issue as above; this is a Debian/Ubuntu packaging concept, not a Koha requirement by itself. |
| `at` | `at` | Direct equivalent. |
| `cron-daemon` | `dcron` or `cronie` | Use the cron daemon available in the target Alpine repository. Koha only needs scheduled execution, not Debian-specific cron packaging. |
| `daemon` | `daemon` | Direct equivalent if available in the chosen Alpine repository. |
| `debconf` | none | Debian package configuration helpers do not exist in Alpine in the same form. Replace with build-time templating and environment-variable-driven setup. |
| `idzebra-2.0` | `zebra` or `idzebra` | Use the Zebra package available in Alpine repositories. The exact name may vary, but Koha still needs the Zebra toolchain/runtime for legacy indexing paths. |
| `koha-l10n` | bundled translation files or a local Koha asset step | This is Koha content, not an Alpine system package. Keep it in the image or source tree as part of the Koha runtime payload. |
| `memcached` | `memcached` | Direct equivalent. Keep external in compose; Koha should only need the endpoint. |
| `mysql-client` | `mariadb-client` | Best practical Alpine replacement for Koha's MySQL client usage. |
| `virtual-mysql-client` | `mariadb-client` | Same as above; the Debian virtual package maps to the MariaDB client implementation on Alpine. |
| `mysql-server` | `mariadb-server` | Direct operational replacement if a local DB server is ever required. The current stack already externalizes the database. |
| `virtual-mysql-server` | `mariadb-server` | Same mapping as above. |
| `perl-doc` | `perl-doc` | Useful for parity with Debian builds and local developer tooling. |
| `pwgen` | `pwgen` | Direct equivalent. |
| `rabbitmq-server` | `rabbitmq-server` | Direct equivalent. Keep it external rather than local if the Alpine migration follows the current split plan. |
| `sudo` | `sudo` | Direct equivalent. |
| `fonts-dejavu` | `ttf-dejavu` | Direct font-family equivalent in Alpine repositories. |
| `ttf-dejavu` | `ttf-dejavu` | Same package already used as a Debian fallback. |
| `unzip` | `unzip` | Direct equivalent. |
| `weasyprint` | `weasyprint` or `py3-weasyprint` | Package naming can vary by Alpine branch. If the package is unavailable, install the Python stack needed by WeasyPrint instead. |
| `xmlstarlet` | `xmlstarlet` | Direct equivalent. |
| `yaz` | `yaz` | Direct equivalent. |

## Build-time and helper correspondences

| Debian package | Alpine correspondence | Notes |
| --- | --- | --- |
| `debhelper` | no direct equivalent | Debian build helper only. Not needed inside Alpine runtime images. |
| `gettext` | `gettext` | Used for `envsubst` and templating. |
| `xsltproc` | `libxslt` | The binary is provided by the `libxslt` package on Alpine. |
| `docbook-xsl` | `docbook-xsl` | Direct equivalent. |
| `docbook-xsl-ns` | `docbook-xsl-ns` | Direct equivalent if available; otherwise use the docbook stylesheets package present in the repository. |
| `libxml2-utils` | `libxml2-utils` | Direct equivalent. |
| `bash-completion` | `bash-completion` | Direct equivalent. |
| `perl-modules-5.26` | `perl` core modules | Alpine does not track Debian's Perl module split. Use the Perl runtime plus CPAN or Alpine Perl module packages as needed. |
| `build-essential` | `build-base` | Alpine's toolchain bundle. |
| `libexpat1-dev` | `expat-dev` | Useful for Perl modules that build against Expat. |
| `libxml2-dev` | `libxml2-dev` | Needed for XML-related CPAN modules. |
| `libxslt1-dev` | `libxslt-dev` | Needed when building XS modules around XSLT. |
| `libssl-dev` style dependencies | `openssl-dev` | Required by some CPAN modules that talk TLS. |
| `zlib1g-dev` style dependencies | `zlib-dev` | Common C-extension dependency. |

## Koha Perl module correspondences

Koha's Debian `control.in` lists a large set of Perl dependencies. On Alpine they are best handled in one of three ways:

1. use an Alpine Perl package if it exists,
2. install the module from CPAN with `cpanm`, or
3. keep the module inside the Koha source/runtime tree if Koha already vendors the required code.

The following Debian module names are the ones Koha declares most visibly in `control.in` and therefore matter most for Alpine parity:

| Debian module/package | Alpine approach | Notes |
| --- | --- | --- |
| `libalgorithm-checkdigits-perl` | CPAN or Alpine Perl package | Numeric/checkdigit helpers used by Koha. |
| `libalgorithm-munkres-perl` | CPAN or Alpine Perl package | Assignment/optimization helper. |
| `libanyevent-http-perl` | CPAN or Alpine Perl package | Async HTTP client support. |
| `libanyevent-perl` | CPAN or Alpine Perl package | Event loop support. |
| `libarchive-extract-perl` | CPAN or Alpine Perl package | Archive extraction support. |
| `libarchive-zip-perl` | CPAN or Alpine Perl package | ZIP archive handling. |
| `libarray-utils-perl` | CPAN or Alpine Perl package | Array helper utilities. |
| `libauthen-cas-client-perl` | CPAN or Alpine Perl package | CAS integration. |
| `libauth-googleauth-perl` | CPAN or Alpine Perl package | Google auth helper. |
| `libbiblio-endnotestyle-perl` | CPAN or Alpine Perl package | Bibliographic formatting support. |
| `libbusiness-isbn-perl` | CPAN or Alpine Perl package | ISBN validation. |
| `libbusiness-issn-perl` | CPAN or Alpine Perl package | ISSN validation. |
| `libbytes-random-secure-perl` | CPAN or Alpine Perl package | Secure random byte generation. |
| `libcache-memcached-fast-safe-perl` | CPAN or Alpine Perl package | Memcached client integration. |
| `libcache-memcached-perl` | CPAN or Alpine Perl package | Memcached client integration. |
| `libcgi-compile-perl` | CPAN or Alpine Perl package | CGI compilation helper. |
| `libcgi-emulate-psgi-perl` | CPAN or Alpine Perl package | PSGI/CGI bridge. |
| `libcgi-pm-perl` | CPAN or Alpine Perl package | Classic CGI support. |
| `libcgi-session-driver-memcached-perl` | CPAN or Alpine Perl package | Session backend. |
| `libcgi-session-perl` | CPAN or Alpine Perl package | Session management. |
| `libclass-accessor-perl` | CPAN or Alpine Perl package | Object accessor helpers. |
| `libclass-factory-util-perl` | CPAN or Alpine Perl package | Factory utilities. |
| `libclass-inspector-perl` | CPAN or Alpine Perl package | Class introspection. |
| `libclone-perl` | CPAN or Alpine Perl package | Deep clone support. |
| `libcrypt-cbc-perl` | CPAN or Alpine Perl package | Crypto helper. |
| `libcrypt-eksblowfish-perl` | CPAN or Alpine Perl package | Password hashing support. |
| `libcrypt-openssl-bignum-perl` | CPAN or Alpine Perl package | OpenSSL numeric helper. |
| `libcrypt-openssl-rsa-perl` | CPAN or Alpine Perl package | RSA support. |
| `libdata-ical-perl` | CPAN or Alpine Perl package | iCal data support. |
| `libdate-calc-perl` | CPAN or Alpine Perl package | Date math. |
| `libdate-manip-perl` | CPAN or Alpine Perl package | Date parsing/formatting. |
| `libdatetime-*` family | CPAN or Alpine Perl package | Alpine may package parts of DateTime, but CPAN is the fallback for parity. |
| `libdbd-mysql-perl` | `perl-dbd-mysql` or CPAN | Needed for DBI/MySQL access. |
| `libdbd-sqlite3-perl` | `perl-dbd-sqlite` or CPAN | SQLite driver. |
| `libdbi-perl` | `perl-dbi` or CPAN | Core DBI layer. |
| `libdbix-class-schema-loader-perl` | CPAN or Alpine Perl package | Schema generation helpers. |
| `libdevel-cover-perl` | CPAN or Alpine Perl package | Coverage tooling. |
| `libdigest-sha-perl` | Perl core / Alpine package | Usually already available. |
| `libemail-*` family | CPAN or Alpine Perl package | Mail-related utilities. |
| `libexception-class-perl` | CPAN or Alpine Perl package | Exception objects. |
| `libfile-libmagic-perl` | `file`/`libmagic` related package plus Perl binding | Used for MIME/type detection. |
| `libfile-slurp-perl` | CPAN or Alpine Perl package | File helpers. |
| `libfont-ttf-perl` | CPAN or Alpine Perl package | Font handling. |
| `libgd-perl` | `perl-gd` or CPAN | Graphics/barcode support. |
| `libgit-wrapper-perl` | CPAN or Alpine Perl package | Git integration. |
| `libgraphics-magick-perl` | `perl-graphics-magick` or CPAN | Image manipulation. |
| `libhttp-*` family | CPAN or Alpine Perl package | HTTP client and cookie support. |
| `libintl-perl` | CPAN or Alpine Perl package | Localization helpers. |
| `libjson-perl` | Perl core / Alpine package | JSON support. |
| `libjson-validator-perl` | CPAN or Alpine Perl package | JSON schema/validation. |
| `liblibrary-callnumber-lc-perl` | CPAN or Alpine Perl package | Library call number formatting. |
| `liblingua-*` family | CPAN or Alpine Perl package | Language/stemming/ispell helpers. |
| `liblist-moreutils-perl` | CPAN or Alpine Perl package | Collection helpers. |
| `liblocale-*` family | CPAN or Alpine Perl package | Formatting and PO file support. |
| `liblog-log4perl-perl` | CPAN or Alpine Perl package | Logging framework. |
| `liblwp-protocol-https-perl` | CPAN or Alpine Perl package | HTTPS support. |
| `libmarc-*` family | CPAN or Alpine Perl package | MARC record processing is central to Koha, so these modules matter a lot. |
| `libmodern-perl-perl` | CPAN or Alpine Perl package | Perl pragmas convenience layer. |
| `libmodule-*` family | CPAN or Alpine Perl package | Module loading/bundling helpers. |
| `libmojo-*` and `libmojolicious*` family | CPAN or Alpine Perl package | Mojolicious stack used by Koha API/web helpers. |
| `libmoo-perl` | CPAN or Alpine Perl package | Object system support. |
| `libnet-*` family | CPAN or Alpine Perl package | LDAP, SMTP, STOMP, Z39.50, SFTP, etc. |
| `libnumber-format-perl` | CPAN or Alpine Perl package | Numeric formatting. |
| `libopenoffice-oodoc-perl` | CPAN or Alpine Perl package | Office document support. |
| `libparallel-forkmanager-perl` | CPAN or Alpine Perl package | Parallel job handling. |
| `libpdf-*` family | CPAN or Alpine Perl package | PDF generation/reporting. |
| `libplack-*` family | CPAN or Alpine Perl package | PSGI/Plack web stack. |
| `libreadonly-perl` | CPAN or Alpine Perl package | Read-only data helpers. |
| `libsereal-*` family | CPAN or Alpine Perl package | Serialization. |
| `libsms-send-perl` | CPAN or Alpine Perl package | SMS integration. |
| `libsql-translator-perl` | CPAN or Alpine Perl package | SQL translation layer. |
| `libstring-random-perl` | CPAN or Alpine Perl package | Random string generation. |
| `libstruct-diff-perl` | CPAN or Alpine Perl package | Structure diffing. |
| `libsys-cpu-perl` | CPAN or Alpine Perl package | CPU info. |
| `libtemplate-perl` | `perl-template-toolkit` or CPAN | Template Toolkit for Koha pages and reports. |
| `libtemplate-plugin-*` family | CPAN or Alpine Perl package | Template plugins used by Koha. |
| `libtest-*` family | CPAN or Alpine Perl package | Test-only dependencies. Useful in dev images, not always runtime. |
| `libtext-*` family | CPAN or Alpine Perl package | CSV, bidi, iconv, PDF, and transliteration helpers. |
| `libtime-fake-perl` | CPAN or Alpine Perl package | Test utility. |
| `libtry-tiny-perl` | Perl core / Alpine package | Exception handling utility. |
| `libuniversal-*` family | CPAN or Alpine Perl package | Module loading helpers. |
| `liburi-perl` | Perl core / Alpine package | URI handling. |
| `libuuid-perl` | CPAN or Alpine Perl package | UUID support. |
| `libwebservice-ils-perl` | CPAN or Alpine Perl package | ILS web service layer. |
| `libwww-perl` | `perl-lwp-protocol-https` plus CPAN/LWP stack | General web client support. |
| `libwww-csrf-perl` | CPAN or Alpine Perl package | CSRF helper. |
| `libxml-*` family | CPAN or Alpine Perl package | XML parsing, SAX, writer, and XSLT glue. |
| `libyaml-libyaml-perl` | CPAN or Alpine Perl package | YAML serialization. |
| `starman` | `starman` | Direct equivalent. Koha uses it for Plack-based service handling. |

## Packages that should probably stay external in Alpine

These were already externalized or are better handled as separate services in the Alpine migration plan:

| Debian package | Alpine correspondence | Notes |
| --- | --- | --- |
| `mysql-client` / `mysql-server` | `mariadb-client` / `mariadb-server` | Keep the database outside the Koha image unless there is a strong local-dev reason to bundle it. |
| `memcached` | `memcached` | Keep external. Koha only needs the endpoint. |
| `rabbitmq-server` | `rabbitmq-server` | Keep external as a sibling container when the broker contract is wired in. |
| OpenSearch runtime pieces | `opensearch` container | Not part of `control.in`, but relevant to the Alpine migration. Keep external. |
| Traefik | `traefik` container | Not part of `control.in`, but part of the compose stack. Keep external. |

## Practical Alpine package set for the image

For the first Alpine image, the most defensible operating-system package set is:

```dockerfile
RUN apk add --no-cache \
    apache2 \
    apache2-utils \
    bash \
    bash-completion \
    build-base \
    coreutils \
    cpanminus \
    curl \
    daemon \
    docbook-xsl \
    docbook-xsl-ns \
    expat-dev \
    findutils \
    gawk \
    gettext \
    git \
    grep \
    libxml2 \
    libxml2-utils \
    libxslt \
    libxslt-dev \
    lsb-release \
    mariadb-client \
    memcached \
    netcat-openbsd \
    nodejs \
    npm \
    openrc \
    perl \
    perl-doc \
    perl-utils \
    pwgen \
    rabbitmq-server \
    sed \
    shadow \
    sudo \
    ttf-dejavu \
    unzip \
    wget \
    xmlstarlet \
    yaz
```

That set is not a perfect one-to-one copy of Debian. It is the closest practical base for the Alpine image while Koha's Debian helper layer is still being ported.

## Recommended follow-up rule

When a Debian package from `control.in` is not listed here or does not have a stable Alpine package name, treat it as one of these:

1. a CPAN module to install with `cpanm`,
2. a Koha source-tree dependency that should stay mounted in the repo, or
3. a runtime service that should be externalized instead of bundled into the image.

That rule keeps the Alpine image focused on the Koha runtime contract rather than on Debian packaging semantics.