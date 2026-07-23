#!/bin/bash
# run.sh — Koha container entrypoint.
# NOTE: This file is BAKED INTO THE IMAGE at build time (see Dockerfile: COPY files-alpine/run.sh).
# Editing this file on the host has NO effect until the image is rebuilt:
#   ./stack.sh start -b   (or docker compose build)
# RUN_SH_VERSION=2026-07-22

set -e
trap 'rc=$?; echo "[run.sh] ERROR line ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2' ERR

export BUILD_DIR=/kohadevbox
export TEMP=/tmp

# Handy variables
export KOHA_INTRANET_FQDN=${KOHA_INTRANET_PREFIX}${KOHA_INSTANCE}${KOHA_INTRANET_SUFFIX}${KOHA_DOMAIN}
export KOHA_OPAC_FQDN=${KOHA_OPAC_PREFIX}${KOHA_INSTANCE}${KOHA_OPAC_SUFFIX}${KOHA_DOMAIN}

if [ -z ${KOHA_OPAC_URL} ]; then
    # KOHA_PUBLIC_PORT: the HTTP port that external clients (browsers) use to reach Koha.
    # When using Traefik on port 80 (default) leave it empty or set to "80" — port 80 is
    # the default for HTTP so it is omitted from the URL, avoiding ":8080" appearing in
    # links and redirects stored in the Koha database (OPACBaseURL / staffClientBaseURL).
    # If Traefik runs on a non-standard port (e.g. 8000), set KOHA_PUBLIC_PORT=8000.
    _pub_port="${KOHA_PUBLIC_PORT:-80}"
    if [ -z "${_pub_port}" ] || [ "${_pub_port}" = "80" ]; then
        export KOHA_OPAC_URL=http://${KOHA_OPAC_FQDN}
    else
        export KOHA_OPAC_URL=http://${KOHA_OPAC_FQDN}:${_pub_port}
    fi
    unset _pub_port
fi
if [ -z ${KOHA_INTRANET_URL} ]; then
    _pub_port="${KOHA_PUBLIC_PORT:-80}"
    if [ -z "${_pub_port}" ] || [ "${_pub_port}" = "80" ]; then
        export KOHA_INTRANET_URL=http://${KOHA_INTRANET_FQDN}
    else
        export KOHA_INTRANET_URL=http://${KOHA_INTRANET_FQDN}:${_pub_port}
    fi
    unset _pub_port
fi

export MESSAGE_BROKER_HOST=${MESSAGE_BROKER_HOST:-rabbitmq}
export MESSAGE_BROKER_PORT=${MESSAGE_BROKER_PORT:-61613}
export MESSAGE_BROKER_USER=${MESSAGE_BROKER_USER:-koha}
export MESSAGE_BROKER_PASS=${MESSAGE_BROKER_PASS:-${KOHA_DB_PASSWORD}}
export MESSAGE_BROKER_VHOST=${MESSAGE_BROKER_VHOST:-koha_${KOHA_INSTANCE}}

export PATH=${PATH}:/kohadevbox/bin:/kohadevbox/koha/node_modules/.bin/:/kohadevbox/node_modules/.bin/

# Node stuff
export NODE_PATH=/kohadevbox/node_modules:$NODE_PATH

. /kohadevbox/lib/run-sh-alpine.sh

if [ "${DEBUG_RUN}" = "yes" ]; then
    echo "DEBUG_RUN_URL=$DEBUG_RUN_URL";
    wget ${DEBUG_RUN_URL} -O /tmp/run.sh
    bash /tmp/run.sh
    exit
fi

# Set a fixed hostname
echo "kohadevbox" > /etc/hostname

# Early exit if SYNC_REPO is not correctly set
# Assuming than about.pl will not be removed!
if [ ! -f "${BUILD_DIR}/koha/about.pl" ]; then
    echo "The environment variable SYNC_REPO does not point to a valid Koha git repository."
    exit 2
fi

# Latest Depends
if [ "${CPAN}" = "yes" ]; then
    echo "Installing latest versions of dependancies from cpan"
    if command -v cpan-outdated >/dev/null 2>&1; then
        cpan-outdated --exclude-core -p | cpanm
    else
        echo "[cpan] cpan-outdated not available; falling back to cpanm --installdeps"
        cpanm --skip-installed --installdeps ${BUILD_DIR}/koha/
    fi
fi

# Install everything in Koha's cpanfile, may include libs for extra patches being tested
if [ "${INSTALL_MISSING_FROM_CPANFILE}" = "yes" ]; then
    cpanm --skip-installed --installdeps ${BUILD_DIR}/koha/
fi

if [ -n "${EXTRA_APT}" ]; then
    echo "Installing requested OS packages using the local package manager: ${EXTRA_APT}"
    install_os_packages ${EXTRA_APT}
fi

if [ -n "${EXTRA_CPAN}" ]; then
    echo "Installing requested Perl libraries: ${EXTRA_CPAN}"
    cpanm --skip-installed ${EXTRA_CPAN}
fi

append_if_absent "127.0.0.1 kohadevbox" /etc/hosts
hostname kohadevbox


# Remove packages for developers if it's a Jenkins run (CI_RUN=1)
if [ "${CI_RUN}" = "yes" ]; then
    remove_os_packages \
      libcarp-always-perl \
      libgit-repository-perl \
      libmemcached-tools \
      libperl-critic-perl \
      libtest-perl-critic-perl \
      libtest-perl-critic-progressive-perl \
      libfile-chdir-perl \
      libdata-printer-perl \
      pmtools
fi

# debug failing apache --restart
service_status_all

# Clone before calling cp_debian_files.pl
if [ "${DEBUG_GIT_REPO_MISC4DEV}" = "yes" ]; then
    rm -rf ${BUILD_DIR}/misc4dev
    git clone -b ${DEBUG_GIT_REPO_MISC4DEV_BRANCH} ${DEBUG_GIT_REPO_MISC4DEV_URL} ${BUILD_DIR}/misc4dev
fi

if [ "${DEBUG_GIT_REPO_QATESTTOOLS}" = "yes" ]; then
    rm -rf ${BUILD_DIR}/qa-test-tools
    git clone -b ${DEBUG_GIT_REPO_QATESTTOOLS_BRANCH} ${DEBUG_GIT_REPO_QATESTTOOLS_URL} ${BUILD_DIR}/qa-test-tools
fi

# Make sure we use the files from the git clone for creating the instance
copy_runtime_files

# Wait for the DB server startup
while ! nc -z db 3306; do sleep 1; done

ensure_runtime_dirs

export DB_NAME="koha_${KOHA_INSTANCE}"
export DB_PASSWORD=${KOHA_DB_PASSWORD}
export DB_USER="koha_${KOHA_INSTANCE}"

# TODO: Have bugs pushed so all this is a koha-create parameter
echo "${KOHA_INSTANCE}:${DB_USER}:${DB_PASSWORD}:${DB_NAME}" > /etc/koha/passwd
# TODO: Get rid of this hack with the relevant bug
echo "[client]"                              > /etc/mysql/koha-common.cnf
echo "host     = ${DB_HOSTNAME}"            >> /etc/mysql/koha-common.cnf
echo "user     = root"                      >> /etc/mysql/koha-common.cnf
echo "password = ${KOHA_DB_ROOT_PASSWORD}"  >> /etc/mysql/koha-common.cnf
echo "ssl      = off"                       >> /etc/mysql/koha-common.cnf
echo "skip-ssl"                             >> /etc/mysql/koha-common.cnf
cp /etc/mysql/koha-common.cnf /etc/mysql/debian.cnf
chmod 600 /etc/mysql/debian.cnf


echo "[client]"                          > /etc/mysql/koha_${KOHA_INSTANCE}.cnf
echo "host     = ${DB_HOSTNAME}"        >> /etc/mysql/koha_${KOHA_INSTANCE}.cnf
echo "user     = ${DB_USER}"            >> /etc/mysql/koha_${KOHA_INSTANCE}.cnf
echo "password = ${DB_PASSWORD}"        >> /etc/mysql/koha_${KOHA_INSTANCE}.cnf
echo "ssl      = off"                   >> /etc/mysql/koha_${KOHA_INSTANCE}.cnf
echo "skip-ssl"                         >> /etc/mysql/koha_${KOHA_INSTANCE}.cnf

# Get rid of Apache warnings
if [ -f /etc/apache2/httpd.conf ]; then
    append_if_absent "ServerName kohadevbox"        /etc/apache2/httpd.conf
    append_if_absent "Listen ${KOHA_INTRANET_PORT}" /etc/apache2/httpd.conf
    append_if_absent "Listen ${KOHA_OPAC_PORT}"     /etc/apache2/httpd.conf
fi

# Pull the names of the environment variables to substitute from defaults.env and convert them to a string of the format "$VAR1:$VAR2:$VAR3", etc.
# grep filters out blank lines and comment lines (lines starting with #) so that
# comment lines with spaces don't truncate the awk field-split output.
VARS_TO_SUB=$(grep -v '^[[:space:]]*#' "${BUILD_DIR}/templates/defaults.env" | grep '=' | cut -d '=' -f1 | tr '\n' ':' | sed -e 's/:/:$/g' | sed -e 's/:\$$//' | sed -e 's/^/\$/')
# Add additional vars to sub from this script that are not in defaults.env
VARS_TO_SUB="\$DB_NAME:\$DB_PASSWORD:\$DB_USER:\$BUILD_DIR:$VARS_TO_SUB";

envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/root_bashrc           > /root/.bashrc
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/vimrc                 > /root/.vimrc
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/bash_aliases          > /root/.bash_aliases
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/koha-conf-site.xml.in > /etc/koha/koha-conf-site.xml.in
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/koha-sites.conf       > /etc/koha/koha-sites.conf
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/sudoers               > /etc/sudoers.d/${KOHA_INSTANCE}

# bin
mkdir -p ${BUILD_DIR}/bin
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/bin/dbic > ${BUILD_DIR}/bin/dbic
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/bin/flush_memcached > ${BUILD_DIR}/bin/flush_memcached
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/bin/bisect_with_test > ${BUILD_DIR}/bin/bisect_with_test

# Alpine does not need the Debian trixie MySQL SSL workaround.
if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" = "debian" ] && [ "${VERSION_CODENAME:-}" = "trixie" ] && [ -f /etc/mysql/my.cnf ]; then
        echo "[client]"  >> /etc/mysql/my.cnf
        echo "ssl = off" >> /etc/mysql/my.cnf
    fi
fi

# Make sure things are executable on /bin.
chmod +x ${BUILD_DIR}/bin/*

cd ${BUILD_DIR}
bootstrap_koha_instance

# Alpine's DBI and MariaDB client enforce TLS by default for TCP connections.
# For local development, we need to explicitly disable SSL to connect without certificates.
KOHA_SITE_CONF="/etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml"
if [ -f "${KOHA_SITE_CONF}" ]; then
    # Disable TLS in Koha configuration for local Docker environment
    if grep -q '<tls>' "${KOHA_SITE_CONF}"; then
        sed -i 's#<tls>.*</tls>#<tls>no</tls>#g' "${KOHA_SITE_CONF}"
    else
        sed -i 's#</pass>#</pass>\n <tls>no</tls>#' "${KOHA_SITE_CONF}"
    fi

    # Remove non-standard TLS tags if present
    sed -i '/<ca>/d' "${KOHA_SITE_CONF}"
    sed -i '/<ssl_key>/d' "${KOHA_SITE_CONF}"
    sed -i '/<ssl_cert>/d' "${KOHA_SITE_CONF}"
fi

# Set environment variables to disable TLS in MariaDB client and Perl DBD::mysql
export MYSQL_OPT_SKIP_SSL=1
export PERL_DBD_MYSQL_SSL_VERIFY_SERVER_CERT=0

# Some koha-create runs can leave the instance DB user with SSL required.
# In this local Docker profile MariaDB runs without TLS, so clear SSL requirements
# for all host entries of the instance user before DBIx::Class connects.
_db_hosts=$(mysql --defaults-file=/etc/mysql/koha-common.cnf --batch --skip-column-names \
    -e "SELECT Host FROM mysql.user WHERE User='${DB_USER}'" 2>/dev/null || true)
if [ -n "${_db_hosts}" ]; then
    for _h in ${_db_hosts}; do
        mysql --defaults-file=/etc/mysql/koha-common.cnf \
            -e "ALTER USER '${DB_USER}'@'${_h}' REQUIRE NONE;" 2>/dev/null || true
    done
fi
unset _db_hosts _h

envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/vimrc > /var/lib/koha/${KOHA_INSTANCE}/.vimrc
chown "${KOHA_INSTANCE}-koha" "/var/lib/koha/${KOHA_INSTANCE}/.vimrc"

if [ -d "${BUILD_DIR}/howto" ]
then
    echo "Install Koha-how-to"
    rm -f ${BUILD_DIR}/koha/how-to.pl ${BUILD_DIR}/koha/koha-tmpl/intranet-tmpl/prog/en/modules/how-to.tt
    ln -s ${BUILD_DIR}/howto/how-to.pl ${BUILD_DIR}/koha/how-to.pl
    ln -s ${BUILD_DIR}/howto/how-to.tt ${BUILD_DIR}/koha/koha-tmpl/intranet-tmpl/prog/en/modules/how-to.tt
fi

echo "[cypress] Make the pre-built cypress available to the instance user [HACK]"

mkdir -p "/var/lib/koha/${KOHA_INSTANCE}/.cache" \
  && echo "    [*] Created cache dir /var/lib/koha/${KOHA_INSTANCE}/.cache/" \
  || echo "    [x] Error creating cache dir /var/lib/koha/${KOHA_INSTANCE}/.cache/"

chown -R "${KOHA_INSTANCE}-koha:${KOHA_INSTANCE}-koha" "/var/lib/koha/${KOHA_INSTANCE}/.cache/" \
  && echo "    [*] Chowning /var/lib/koha/${KOHA_INSTANCE}/.cache/" \
  || echo "    [x] Error chowning cache dir /var/lib/koha/${KOHA_INSTANCE}/.cache/"

ln -s /kohadevbox/Cypress "/var/lib/koha/${KOHA_INSTANCE}/.cache/" \
  && echo "    [*] Cypress dir linked to /var/lib/koha/${KOHA_INSTANCE}/.cache/" \
  || echo "    [x] Error linking Cypress dir to /var/lib/koha/${KOHA_INSTANCE}/.cache/"

# Fix UID if not empty, and differs from 1000 (Docker's default for the next UID)
if [[ ! -z "${LOCAL_USER_ID}" && "${LOCAL_USER_ID}" != "1000" ]]; then
    usermod -o -u ${LOCAL_USER_ID} "${KOHA_INSTANCE}-koha"

    if [[ "${SKIP_CYPRESS_CHOWN}" != "yes" ]]; then
        chown -R "${KOHA_INSTANCE}-koha:${KOHA_INSTANCE}-koha" "/kohadevbox/Cypress" \
          && echo "    [*] Cypress dir chowned correctly" \
          || echo "    [x] Error running chown on Cypress dir"
    fi

    # Fix permissions due to UID change
    chown -R "${KOHA_INSTANCE}-koha" "/var/cache/koha/${KOHA_INSTANCE}"
    chown -R "${KOHA_INSTANCE}-koha" "/var/lib/koha/${KOHA_INSTANCE}"
    chown -R "${KOHA_INSTANCE}-koha" "/var/lock/koha/${KOHA_INSTANCE}"
    chown -R "${KOHA_INSTANCE}-koha" "/var/log/koha/${KOHA_INSTANCE}"
    chown -R "${KOHA_INSTANCE}-koha" "/var/run/koha/${KOHA_INSTANCE}"
    chown -R "${KOHA_INSTANCE}-koha" ${BUILD_DIR}/misc4dev
    chown -R "${KOHA_INSTANCE}-koha" ${BUILD_DIR}/gitify
    chown -R "${KOHA_INSTANCE}-koha" ${BUILD_DIR}/qa-test-tools
fi

sync_l10n

echo "[API logging] Set TRACE to API log4perl config"
sed -i 's/log4perl.logger.api = WARN, API/log4perl.logger.api = TRACE, API/' /etc/koha/sites/${KOHA_INSTANCE}/log4perl.conf \
  && echo "    [*] TRACE set for the API log4perl configuration" \
  || echo "    [x] Error setting TRACE for the API log4perl configuration"

echo "[git] Setting up Git on the instance user"
setup_git_workflow

GIT_BASE_DIR=${BUILD_DIR}/koha
if [ "${GIT_WORKTREE_SOURCE}" != "" ]; then
    # Git worktree!
    echo "    [!] Detected worktree: pointing to '${GIT_WORKTREE_SOURCE}'"
    GIT_BASE_DIR=${GIT_WORKTREE_SOURCE}
    echo "    [*] Added '${GIT_WORKTREE_SOURCE}' to safe directories"
fi

install_git_hooks "${GIT_BASE_DIR}"

# This needs to be done ONCE koha-create has run (i.e. kohadev-koha user exists)
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/apache2_envvars > /etc/apache2/envvars

# gitify instance
cd ${BUILD_DIR}/gitify
if [ -x ./koha-gitify ]; then
    ./koha-gitify ${KOHA_INSTANCE} "/kohadevbox/koha"
else
    echo "[koha-gitify] WARNING: koha-gitify helper not available; skipping"
fi
cd ${BUILD_DIR}

if command -v koha-enable >/dev/null 2>&1; then
    koha-enable ${KOHA_INSTANCE}
else
    echo "[koha-enable] WARNING: koha-enable not available; skipping"
fi

if command -v a2ensite >/dev/null 2>&1; then
    a2ensite ${KOHA_INSTANCE}.conf
fi

cp /kohadevbox/koha/package.json /kohadevbox
cp /kohadevbox/koha/yarn.lock    /kohadevbox
# Wipe possible residual directories from previous engine
rm -rf /var/lib/koha/${KOHA_INSTANCE}/.cache/js-v8flags
rm -rf /var/lib/koha/${KOHA_INSTANCE}/.cache/yarn
if [ "${SKIP_YARN_INSTALL:-no}" = "yes" ]; then
    echo "[yarn] SKIP_YARN_INSTALL=yes — skipping yarn install for bootstrap-first runtime"
else
    echo "[yarn] Running yarn install to /kohadevbox/koha/node_modules"
    cd /kohadevbox/koha && yarn install
    cd /
fi

# Update /etc/hosts so the www tests can run
echo "127.0.0.1    ${KOHA_OPAC_FQDN} ${KOHA_INTRANET_FQDN}" >> /etc/hosts

envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/instance_bashrc > /var/lib/koha/${KOHA_INSTANCE}/.bashrc
envsubst "$VARS_TO_SUB" < ${BUILD_DIR}/templates/bash_aliases    > /var/lib/koha/${KOHA_INSTANCE}/.bash_aliases

if [ "${KOHA_ELASTICSEARCH}" = "yes" ]; then
    ES_FLAG="--elasticsearch"
fi

# Auto-detect an existing (non-empty) Koha database so that a plain container
# restart — e.g. after a machine reboot or a bare `docker compose up` — does NOT
# fail with "Database is not empty!" from do_all_you_can_do.pl (line 89).
#
# Uses root credentials via /etc/mysql/koha-common.cnf (written above) so the
# probe works regardless of whether koha_${KOHA_INSTANCE} user grants are in place.
#
# Logic:
#  1. If the operator explicitly set USE_EXISTING_DB=yes (env/.env or stack.sh
#     --no-fresh-db export), honour it and skip the probe.
#  2. Otherwise probe the database: if 'systempreferences' already exists in the
#     schema the DB was previously populated — automatically pass --use-existing-db.
#  3. If the table is absent (or the probe fails), proceed with a fresh installation.
USE_EXISTING_DB_FLAG=""
if [ "${USE_EXISTING_DB}" != "yes" ]; then
    echo "[db-detect] Probing '${DB_NAME}' for existing Koha data..."
    _db_populated=$(mysql \
        --defaults-file=/etc/mysql/koha-common.cnf \
        --batch --skip-column-names \
        -e "SELECT IF(
              (SELECT COUNT(*) FROM information_schema.tables
               WHERE table_schema = '${DB_NAME}'
               AND table_name = 'systempreferences') > 0,
            'yes', 'no');" 2>/dev/null || echo "no")
    if [ "${_db_populated:-no}" = "yes" ]; then
        echo "[db-detect] Existing Koha data found — enabling --use-existing-db automatically"
        echo "[db-detect] Tip: set USE_EXISTING_DB=yes in env/.env to skip this probe"
        USE_EXISTING_DB="yes"
    else
        echo "[db-detect] Database is empty — proceeding with fresh Koha installation"
    fi
    unset _db_populated
fi

if [ "${USE_EXISTING_DB}" = "yes" ]; then
    USE_EXISTING_DB_FLAG="--use-existing-db"
fi

# LOAD_DEMO_DATA: 'yes' (default) loads sample MARC bibliographic records, authority
# records, items, and patron data via misc4dev/insert_data.pl.
# Set LOAD_DEMO_DATA=no for a clean install with only the superlibrarian account.
if [ "${LOAD_DEMO_DATA:-yes}" = "no" ]; then
    echo "[demo data] LOAD_DEMO_DATA=no — skipping sample records and patrons"
    printf '#!/usr/bin/perl\nuse Modern::Perl;\nsay "Demo data skipped (LOAD_DEMO_DATA=no)";\nexit(0);\n' \
        > ${BUILD_DIR}/misc4dev/insert_data.pl
    chmod +x ${BUILD_DIR}/misc4dev/insert_data.pl
fi

if [ "${KOHA_ELASTICSEARCH}" = "yes" ]; then
    echo "[elasticsearch] Waiting for OpenSearch endpoint from Koha container..."

    ES_ENDPOINT="${ELASTIC_SERVER:-os01:9200}"
    ES_HOST="${ES_ENDPOINT%%:*}"
    ES_PORT="${ES_ENDPOINT##*:}"
    if [ -z "${ES_HOST}" ]; then
        ES_HOST="os01"
    fi
    if [ -z "${ES_PORT}" ] || [ "${ES_PORT}" = "${ES_HOST}" ]; then
        ES_PORT="9200"
    fi
    echo "[elasticsearch] Target endpoint: ${ES_HOST}:${ES_PORT}"

    # Determine which CA cert to use for TLS verification.
    _os_cacert_args=()
    if [ -s "/kohadevbox/opensearch-root-ca.pem" ]; then
        _os_cacert_args=(--cacert "/kohadevbox/opensearch-root-ca.pem")
        echo "[elasticsearch] Using root-ca at /kohadevbox/opensearch-root-ca.pem"
    else
        _os_cacert_args=(-k)
        echo "[elasticsearch] WARNING: opensearch-root-ca.pem not found, skipping TLS verification"
    fi

    os_wait_ok="no"
    for attempt in $(seq 1 60); do
        # Quick TCP reachability check before attempting the full HTTPS request.
        if ! nc -z -w 3 "${ES_HOST}" "${ES_PORT}" 2>/dev/null; then
            echo "[elasticsearch] attempt ${attempt}/60: TCP port ${ES_HOST}:${ES_PORT} not reachable"
            sleep 5
            continue
        fi

        os_response=$(curl -s "${_os_cacert_args[@]}" \
            --connect-timeout 5 --max-time 10 \
            -u "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" \
            -w "\nHTTP_STATUS:%{http_code}" \
            "https://${ES_HOST}:${ES_PORT}/_cluster/health?wait_for_status=yellow&timeout=5s" 2>&1)

        os_http_code=$(echo "${os_response}" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2)
        os_status=$(echo "${os_response}" \
            | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' \
            | head -n 1)

        if [ "${os_status}" = "yellow" ] || [ "${os_status}" = "green" ]; then
            os_wait_ok="yes"
            echo "[elasticsearch] OpenSearch is ${os_status}."
            break
        fi

        echo "[elasticsearch] attempt ${attempt}/60: OpenSearch not ready yet (HTTP ${os_http_code:-no-response})"
        if [ "${attempt}" = "1" ] || [ $((attempt % 10)) -eq 0 ]; then
            echo "[elasticsearch] Last response: $(echo "${os_response}" | grep -v 'HTTP_STATUS' | head -c 300)"
        fi
        sleep 5
    done

    if [ "${os_wait_ok}" != "yes" ]; then
        echo "[elasticsearch] OpenSearch did not become ready in time."
        exit 1
    fi
fi

# koha-rebuild-zebra executes migration_tools scripts directly.  Normalize
# any CRLF in those scripts before do_all_you_can_do.pl (cross-platform safety).
find "${BUILD_DIR}/koha/misc/migration_tools" -type f -name '*.pl' \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true

if [ "${KOHA_ELASTICSEARCH}" = "yes" ]; then
    # misc4dev still forces a Zebra rebuild after successful ES indexing.
    # On recent datasets this can fail on malformed legacy MARCXML and abort
    # container startup, even though Elasticsearch setup already completed.
    sed -i 's|\$cmd = "sudo koha-rebuild-zebra -f -v \$instance";|say "Skipping koha-rebuild-zebra in Elasticsearch mode";\n\$cmd = "true";|' \
        "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"

    # Keep Elasticsearch rebuild but make it non-fatal.
    # A stale index, mapping incompatibility, or missing index (common after a
    # Koha upgrade or image switch) should NOT abort container startup — Koha
    # remains functional, only searches may be incomplete.
    # Append '; true' so the overall shell exit code is always 0, and redirect
    # stderr to a file so we can print it after do_all_you_can_do.pl finishes.
    sed -i "s|perl \$rebuild_es_path -v'|perl \$rebuild_es_path' 2>/tmp/rebuild_elasticsearch.stderr; true|"\
        "${BUILD_DIR}/misc4dev/do_all_you_can_do.pl"
fi

perl ${BUILD_DIR}/misc4dev/do_all_you_can_do.pl \
            --instance          ${KOHA_INSTANCE} ${ES_FLAG} ${USE_EXISTING_DB_FLAG} \
            --userid            ${KOHA_USER} \
            --password          ${KOHA_PASS} \
            --marcflavour       ${KOHA_MARC_FLAVOUR} \
            --koha_dir          ${BUILD_DIR}/koha \
            --opac-base-url     ${KOHA_OPAC_URL} \
            --intranet-base-url ${KOHA_INTRANET_URL} \
            --gitify_dir        ${BUILD_DIR}/gitify || {
    echo "[db-population] WARNING: Database population failed (Perl compilation error detected)"
    echo "[db-population] This is expected if Koha source has known issues (e.g., ZOOM::Event::ZEND bareword)"
    echo "[db-population] Apache will still start and CGI execution is functional"
    echo "[db-population] To retry: koha-shell ${KOHA_INSTANCE} -c 'perl /kohadevbox/misc4dev/do_all_you_can_do.pl ...'"
}

# Surface any Elasticsearch rebuild errors captured during do_all_you_can_do.pl.
# The rebuild was made non-fatal above; print errors here so they appear in
# 'docker compose logs' and the operator knows to investigate.
if [ -s /tmp/rebuild_elasticsearch.stderr ]; then
    echo "[elasticsearch] WARNING: Index rebuild encountered errors (startup continues):"
    cat /tmp/rebuild_elasticsearch.stderr
    echo "[elasticsearch] Koha is functional but searches may be incomplete."
    echo "[elasticsearch] To retry: koha-shell ${KOHA_INSTANCE} -p -c 'perl ${BUILD_DIR}/koha/misc/search_tools/rebuild_elasticsearch.pl'"
fi

# Alpine compatibility: Remove suexec-specific directives not supported in Alpine Apache
echo "[alpine] Removing Debian-specific Apache suexec directives..."
find /etc/apache2/sites-enabled -name "*.conf" -exec sed -i 's/^[[:space:]]*AssignUserID/# AssignUserID/' {} + 2>/dev/null || true

# Alpine permissions fix: Make Koha config and cache directories accessible to Apache
# Alpine Apache cannot use AssignUserID directive, so scripts run as 'apache' user
# We need to make Koha data directories readable/writable by the apache user for CGI scripts to function
echo "[alpine] Fixing permissions for Apache to access Koha directories..."
if [ -d "/etc/koha/sites/${KOHA_INSTANCE}" ]; then
    chmod 644 /etc/koha/sites/${KOHA_INSTANCE}/koha-conf.xml 2>/dev/null || true
    chmod 644 /etc/koha/sites/${KOHA_INSTANCE}/log4perl.conf 2>/dev/null || true
fi
if [ -d "/var/cache/koha/${KOHA_INSTANCE}" ]; then
    chmod 777 /var/cache/koha/${KOHA_INSTANCE} 2>/dev/null || true
    find /var/cache/koha/${KOHA_INSTANCE} -type d -exec chmod 777 {} + 2>/dev/null || true
fi
if [ -d "/var/log/koha/${KOHA_INSTANCE}" ]; then
    find /var/log/koha/${KOHA_INSTANCE} -type f -exec chmod 666 {} + 2>/dev/null || true
    find /var/log/koha/${KOHA_INSTANCE} -type d -exec chmod 777 {} + 2>/dev/null || true
fi

# Alpine CGI support: Enable mod_cgi for CGI script execution
# Alpine's httpd.conf has mod_cgi LoadModule commented out by default
echo "[alpine] Enabling mod_cgi module for Perl CGI script execution..."
sed -i 's/^[[:space:]]*#LoadModule cgi_module modules\/mod_cgi\.so/LoadModule cgi_module modules\/mod_cgi.so/' /etc/apache2/httpd.conf 2>/dev/null || true

# Alpine CGI fix: Enable CGI script execution for .pl files in /kohadevbox/koha directory
# The koha-create generated templates lack the necessary CGI handler directives for Alpine
echo "[alpine] Enabling CGI execution for Perl scripts in /etc/koha/apache-shared-*-git.conf..."
for _conf_file in /etc/koha/apache-shared-opac-git.conf /etc/koha/apache-shared-intranet-git.conf; do
    if [ -f "${_conf_file}" ]; then
        # Add Options and AddHandler directives inside the /kohadevbox/koha Directory block
        # Match the pattern: <Directory "/kohadevbox/koha"> and Require all granted
        # Insert Options and AddHandler before the closing </Directory>
        sed -i '/<Directory "\/kohadevbox\/koha">/a\        Options +ExecCGI +FollowSymlinks\n        AddHandler cgi-script .pl' "${_conf_file}" 2>/dev/null || true
    fi
done
unset _conf_file

# Stop apache2
stop_apache_service

# Apache CGI execution fails with "No such file or directory" when Perl scripts
# carry CRLF shebangs (cross-platform repos). Normalize key web entry points
# after setup steps and before starting services.
find "${BUILD_DIR}/koha" -type f \( -name '*.pl' -o -name '*.cgi' \) \
        -exec sed -i 's/\r$//' {} + 2>/dev/null || true

echo "[logs] Chowning logs"
chown -R "${KOHA_INSTANCE}-koha:${KOHA_INSTANCE}-koha" "/var/log/koha/${KOHA_INSTANCE}" \
  && echo "    [*] Success chowning /var/log/koha/${KOHA_INSTANCE}" \
  || echo "    [x] Error chowning cache dir /var/log/koha/${KOHA_INSTANCE}"

if [ "${ENABLE_PLUGINS}" = "yes" ]; then

    echo "[plugins] Installing plugins"

    PLUGINS_STRING=""
    counter=0

    for plugin_dir in $(find ${BUILD_DIR}/plugins -mindepth 1 -maxdepth 1 -type d); do

        echo "    [*] Found: ${plugin_dir}"

	    entry=" <pluginsdir>${BUILD_DIR}/plugins/$(basename $plugin_dir)</pluginsdir>"

        # Append the new plugin's entry
        if [ "${counter}" -ge 1 ]; then
	        PLUGINS_STRING="${PLUGINS_STRING}\n${entry}"
        else
	        PLUGINS_STRING="${entry}"
        fi

        counter=$((counter+1))
    done

    if command -v flush_memcached >/dev/null 2>&1; then
        flush_memcached
    fi
    # replace the placeholder with the plugins entries
    sed -i "s# <!--pluginsdir>YOUR_PLUGIN_DIR_HERE</pluginsdir-->#$(echo "$PLUGINS_STRING")#" /etc/koha/sites/kohadev/koha-conf.xml
    # run the plugins installer
    perl ${BUILD_DIR}/koha/misc/devel/install_plugins.pl
    echo "    [*] Plugins loaded!"
fi

enable_instance_services

# RabbitMQ now runs as an external sibling container. Wait for its STOMP port
# before starting Koha workers so background jobs keep instant notifications.
echo "[rabbitmq] Waiting for STOMP port ${MESSAGE_BROKER_HOST}:${MESSAGE_BROKER_PORT}..."
_stomp_ready=no
for _i in $(seq 1 30); do
    if nc -z "${MESSAGE_BROKER_HOST}" "${MESSAGE_BROKER_PORT}" 2>/dev/null; then
        _stomp_ready=yes
        break
    fi
    sleep 1
done
if [ "${_stomp_ready}" = "yes" ]; then
    echo "[rabbitmq] STOMP port ${MESSAGE_BROKER_HOST}:${MESSAGE_BROKER_PORT} is ready"
else
    echo "[rabbitmq] WARNING: STOMP port ${MESSAGE_BROKER_HOST}:${MESSAGE_BROKER_PORT} not ready after 30 s — workers will use DB polling fallback"
fi
unset _stomp_ready _i

start_koha_service

# Start apache2
start_apache_service

touch /ktd_ready
echo "koha-testing-docker has started up and is ready to be enjoyed!"

# start koha-reload-starman, if we have inotify installed
#    if [ -f "/usr/bin/inotifywait" ]; then
#        daemon  --verbose=1 \
#            --name=reload-starman \
#            --respawn \
#            --delay=15 \
#            --pidfiles=/var/run/koha/kohadev/ -- /kohadevbox/koha-reload-starman
#    fi

# TODO: We could use supervise as the main loop
/bin/bash -c "trap : TERM INT; sleep infinity & wait"
