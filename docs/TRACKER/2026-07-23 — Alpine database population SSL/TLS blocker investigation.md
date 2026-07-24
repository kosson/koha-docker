# 2026-07-23 — Alpine Database Population SSL/TLS Blocker Investigation

**Status:** 🟡 IN PROGRESS - Blocking Issue Identified & Documented  
**Session Focus:** Resolving database population failures to enable full Koha application startup  

## Accomplishments Today

### ✅ Fixed Issues

1. **ZOOM::Event::ZEND Bareword Compilation Errors** (4 instances across 3 files)
   - **Root Cause:** Perl strict mode forbids bareword constants; ZOOM::Event::ZEND needed numeric constant value
   - **Files Fixed:**
     - `koha/C4/Search.pm` line 2347: Changed `ZOOM::Event::ZEND` → `11` with comment
     - `koha/C4/AuthoritiesMarc.pm` line 262: Changed `ZOOM::Event::ZEND` → `11` with comment  
     - `koha/C4/Breeding.pm` lines 166 & 590: Changed `ZOOM::Event::ZEND` → `11` with comments (2 instances)
   - **Verification:** `grep -r "ZOOM::Event::ZEND" --include="*.pm" .` confirms all barewords replaced, only comments remain
   - **Status:** ✅ COMPLETE - Image rebuilt with fixes

2. **Missing Search::Elasticsearch CPAN Module**
   - **Issue:** Alpine 3.24.1 doesn't package Search::Elasticsearch; populate_db.pl requires it
   - **Fix:** Added `RUN cpanm --notest Search::Elasticsearch` to Dockerfile-Alpine after Lingua::Stem (line 164)
   - **Status:** ✅ COMPLETE - Verified in rebuild output

3. **CGI Execution Layer Verification**
   - **Status:** ✅ CONFIRMED WORKING in previous session
   - Apache returns proper HTTP 302 redirects instead of serving Perl source code
   - Both OPAC (8080) and Intranet (8081) endpoints responding
   - mod_cgi module loaded and configured correctly

### 🟡 Current Blocker - Database Population SSL/TLS Conflict

**Current Error Message:**

```log
DBI connect('dbname=koha_kohadev;host=db;port=3306','koha_kohadev',...) failed: 
TLS/SSL error: SSL is required, but the server does not support it
```

**Root Cause Analysis:**

- Alpine's DBD::mysql module (v4.055) is compiled with mandatory SSL support
- Originally: MariaDB set to `--ssl=ON` + Perl DBI attempting to verify certificates = double TLS requirement causing certificate verification failures
- Changed MariaDB to `--ssl=OFF`, but DBI layer still attempting TLS negotiation at protocol level
- Issue appears to be system-level or compile-flag related in DBD::mysql on Alpine

**Fixes Attempted (All Applied):**

1. **MariaDB Configuration** (`docker-compose-alpinekoha.yml` line 5)
   - Changed: `--ssl=ON` → `--ssl=OFF`
   - Verified: `mysql --skip-ssl -h db` successfully connects

2. **Koha Configuration** (`files-alpine/run.sh` lines 204-209)
   - Set `<tls>no</tls>` in koha-conf.xml
   - Removed non-standard XML tags: `<ca>`, `<ssl_key>`, `<ssl_cert>`
   - Added environment variables: `MYSQL_OPT_SKIP_SSL=1`, `PERL_DBD_MYSQL_SSL_VERIFY_SERVER_CERT=0`

3. **Koha Database Module** (`koha/Koha/Database.pm` lines 208-232)
   - Modified DSN building logic: When TLS is NOT `yes`, don't append any SSL parameters
   - Previously: Only added `mysql_ssl=1` when TLS enabled; now avoids adding parameters entirely when disabled
   - Code: Removed `mysql_ssl=0` append (tested but didn't help; Alpine DBI still attempts handshake)

Online references to the issue (dig into it):

- DBD::mysql::INSTALL - How to install and configure DBD::mysql https://metacpan.org/dist/DBD-mysql/view/lib/DBD/mysql/INSTALL.pod
- https://github.com/perl5-dbi/DBD-mysql/issues/210
- MySQL certificate verification changes due to Alpine 3.21 https://docs.skpr.io/changelog/2026-01-23-ssl-verify-certificate/ -> "Alpine 3.21 and above have changed the default mysql client to the mariadb client. As part of this change, the client now verifies the connection certificates by default. The solution is to disable the certificate verification using the MYSQL_ATTR_SSL_VERIFY_SERVER_CERT PDO setting for development (local and preview) environments."

**Current State:**

- Database accessible via mysql CLI with `--skip-ssl` flag ✅
- MariaDB running without SSL ✅
- Koha config set to `<tls>no</tls>` ✅
- But Perl DBI/DBD still failing at protocol level 🔴
- Database remains empty: 0 tables (populate_db hasn't completed)

**Key Observations:**
1. Connection string shows `mysql_ssl` parameters are NOT being added (DSN fix working)
2. MariaDB is accepting unencrypted connections from CLI
3. Issue is **specifically with Perl's DBD::mysql DBI driver** on Alpine
4. Possibly:
   - DBD::mysql v4.055 on Alpine has compile flag forcing TLS
   - System-level libmysqlclient configuration enforcing TLS
   - DBI layer making second SSL negotiation attempt despite disabled config

## Files Modified

### Core Koha Source Code

- `koha/Koha/Database.pm` - DSN building logic (line 229 comment added)
- `koha/C4/Search.pm` - Bareword constant fix
- `koha/C4/AuthoritiesMarc.pm` - Bareword constant fix
- `koha/C4/Breeding.pm` - Bareword constant fixes (2 locations)

### Docker Configuration  
- `Dockerfile-Alpine` - Added Search::Elasticsearch CPAN module (line 164)
- `docker-compose-alpinekoha.yml` - Changed MariaDB from `--ssl=ON` to `--ssl=OFF` (line 5)

### Bootstrap Script
- `files-alpine/run.sh` - TLS config handling (lines 204-209)

## Current Application State

**✅ Working:**
- Alpine 3.24.1 base image builds successfully
- Koha 26.11 source compiles with 60+ build stages
- Apache 2.4.68 starts and listens on ports 8080/8081
- CGI execution layer functional (proven by HTTP 302 redirects)
- MariaDB 10.11 database container starts
- All SSL certificate infrastructure in place at `/etc/mysql/ssl/`

**🔴 Blocked:**
- Database population fails before table creation
- populate_db.pl exits at first DBIx::Class connection attempt
- Koha application returns HTTP 500 (no schema tables)
- Browser sees installer/maintenance redirect loops (expected when DB empty)

## Next Steps (For Future Session)

1. **Investigate DBD::mysql Compilation Flags**
   - Run `perl -MDBD::mysql -e 'print $DBD::mysql::VERSION; ...'` to confirm version
   - Check if `--enable-ssl` or similar flag was set during build
   - Verify if system libmysqlclient is enforcing TLS

2. **Alternative Connection Approach**
   - Test passing `mysql_unix_port` parameter to use socket instead of TCP
   - Explore if connection pooling (Memcached integration) has separate SSL requirements
   - Check if koha-shell environment sets additional DBI flags

3. **System-Level Configuration**
   - Verify `/etc/my.cnf` or `/etc/mysql/conf.d/` has no global SSL requirements
   - Check if MariaDB client wrapper scripts inject SSL parameters
   - Test raw DBI connection without Koha wrapper: `perl -MDBI -e 'DBI->connect(...)'`

4. **Workaround Option**
   - If DBD::mysql can't be configured: Consider using `system()` call to run bootstrap SQL scripts via `mysql --skip-ssl` CLI
   - Would bypass DBI/DBD layer entirely for initial schema population

## Technical Context

**Alpine 3.24.1 + Perl 5.42.2 + DBD::mysql 4.055 + MariaDB 10.11:**
- Alpine's minimal approach means compile flags differ from Debian
- Some packages (yaz, daemon, perl-search-elasticsearch) not available as Alpine packages; installed via cpanm instead
- SSL/TLS handling in Alpine is stricter; system services default to enabled security features

**Database Connection Path:**
- Koha bootstrap → `populate_db.pl` → `C4/Installer.pm` → `Koha/Database.pm::build_dsn()` → DBIx::Class → DBI → DBD::mysql → libmysqlclient → network → MariaDB

The failure is occurring between DBD::mysql and MariaDB at protocol negotiation, after DSN string is constructed correctly.

---

**Session Duration:** ~3 hours  
**Commits/Pushes:** Multiple Docker image rebuilds (no git commits made yet)  
**Image Built:** kosson/koha-alpine:26.11 (latest)  
**Containers Ready:** All 4 services running (db, koha, memcached, rabbitmq)
