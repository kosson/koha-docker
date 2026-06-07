#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="$SCRIPT_DIR/opensearch_installer_vars.cfg"

if [ -f "$config_file" ]; then
    source "$config_file"
    # Root CA key creation
    openssl genrsa -out $OS_CERTS_PATH/root-ca-key.pem 2048
    openssl req -new -x509 -sha256 -key $OS_CERTS_PATH/root-ca-key.pem -subj "$CERT_DN/CN=$LOCAL_ROOT_CA" -out $OS_CERTS_PATH/root-ca.pem -days 730
    # TSL certificate for the administrator
    openssl genrsa -out $OS_CERTS_PATH/$ADMIN_CA-key-temp.pem 2048
    openssl pkcs8 -inform PEM -outform PEM -in $OS_CERTS_PATH/$ADMIN_CA-key-temp.pem -topk8 -nocrypt -v1 PBE-SHA1-3DES -out $OS_CERTS_PATH/$ADMIN_CA-key.pem
    openssl req -new -key $OS_CERTS_PATH/$ADMIN_CA-key.pem -subj "$CERT_DN/CN=$ADMIN_CA" -out $OS_CERTS_PATH/$ADMIN_CA.csr
    openssl x509 -req -in $OS_CERTS_PATH/$ADMIN_CA.csr -CA $OS_CERTS_PATH/root-ca.pem -CAkey $OS_CERTS_PATH/root-ca-key.pem -CAcreateserial -sha256 -out $OS_CERTS_PATH/$ADMIN_CA.pem -days 730
    # TLS certificate for the nodes
    for NODE_NAME in "os01" "os02" "os03" "os04" "os05" "client" "dashboards"
    do
        openssl genrsa -out $OS_CERTS_PATH/$NODE_NAME-key-temp.pem 2048
        openssl pkcs8 -inform PEM -outform PEM -in $OS_CERTS_PATH/$NODE_NAME-key-temp.pem -topk8 -nocrypt -v1 PBE-SHA1-3DES -out $OS_CERTS_PATH/$NODE_NAME-key.pem
        openssl req -new -key $OS_CERTS_PATH/$NODE_NAME-key.pem -subj $CERT_DN/CN=$NODE_NAME -out $OS_CERTS_PATH/$NODE_NAME.csr
        echo "subjectAltName=DNS:$NODE_NAME" > $OS_CERTS_PATH/$NODE_NAME.ext
        openssl x509 -req -in $OS_CERTS_PATH/$NODE_NAME.csr -CA $OS_CERTS_PATH/root-ca.pem -CAkey $OS_CERTS_PATH/root-ca-key.pem -CAcreateserial -sha256 -out $OS_CERTS_PATH/$NODE_NAME.pem -days 730 -extfile $OS_CERTS_PATH/$NODE_NAME.ext
        rm $OS_CERTS_PATH/$NODE_NAME-key-temp.pem $OS_CERTS_PATH/$NODE_NAME.csr $OS_CERTS_PATH/$NODE_NAME.ext
        chown -R 1000:1000 $OS_CERTS_PATH/$NODE_NAME-key.pem $OS_CERTS_PATH/$NODE_NAME.pem
    done
else
    echo "$config_file not found."    
fi

rm -f $OS_CERTS_PATH/$ADMIN_CA.csr $OS_CERTS_PATH/$ADMIN_CA-key-temp.pem
rm -f $OS_CERTS_PATH/root-ca.srl

# --- Compliance salt and SQL datasource master key ---------------------------------
# Both values must be identical on every node. They are generated once here and
# written into all os*/opensearch.yml files so the cluster is consistent.
#
# WARNING: Do NOT regenerate the SQL masterkey after the cluster has been used to
# store datasource credentials — re-running this script on an existing cluster will
# produce a new key and make any previously stored encrypted credentials unreadable.
# Run this script only when setting up a fresh cluster (after restart-to-clear-cluster.sh).

COMPLIANCE_SALT="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
SQL_MASTERKEY="$(openssl rand -hex 16)"
CONFIG_BASE="$SCRIPT_DIR/assets/opensearch/config"

for cfg in "$CONFIG_BASE"/os*/opensearch.yml; do
    if grep -q "^plugins.security.compliance.salt:" "$cfg"; then
        sed -i "s|^plugins.security.compliance.salt:.*|plugins.security.compliance.salt: \"$COMPLIANCE_SALT\"|" "$cfg"
    else
        echo "plugins.security.compliance.salt: \"$COMPLIANCE_SALT\"" >> "$cfg"
    fi
    if grep -q "^plugins.query.datasources.encryption.masterkey:" "$cfg"; then
        sed -i "s|^plugins.query.datasources.encryption.masterkey:.*|plugins.query.datasources.encryption.masterkey: \"$SQL_MASTERKEY\"|" "$cfg"
    else
        echo "plugins.query.datasources.encryption.masterkey: \"$SQL_MASTERKEY\"" >> "$cfg"
    fi
done
echo "Compliance salt and SQL master key written to all node configs."
echo "  compliance salt : $COMPLIANCE_SALT"
echo "  SQL master key  : $SQL_MASTERKEY"
echo "Store these values securely — they are required to restore the cluster."

# --- Secure file permissions -------------------------------------------------------
# Config files and private keys must not be world-readable. The Security plugin will
# log permission warnings at startup if these are not set correctly.
find "$SCRIPT_DIR/assets/ssl"                        -type f -name "*.pem" | xargs chmod 775
find "$SCRIPT_DIR/assets/opensearch/config"          -type d               | xargs chmod 775
find "$SCRIPT_DIR/assets/opensearch/config"          -type f               | xargs chmod 775
find "$SCRIPT_DIR/assets/opensearch/performance-analyzer" -type f          | xargs chmod 775 2>/dev/null || true
echo "File permissions set (certs: 775, config dirs: 775, config files: 775)."

# --- Update internal_users.yml password hash ----------------------------------------
# Read OPENSEARCH_INITIAL_ADMIN_PASSWORD from .env and regenerate the bcrypt hash for
# every user entry in os01's internal_users.yml using OpenSearch's own hash.sh tool.
# This keeps the file in sync whenever the password is changed and certs are regenerated —
# a stale hash is the most common cause of 401 / healthcheck failures on fresh starts.

INTERNAL_USERS_YML="$SCRIPT_DIR/assets/opensearch/config/os01/opensearch-security/internal_users.yml"
ENV_FILE="$SCRIPT_DIR/.env"

# Read password; strip surrounding single/double quotes (handles KEY=value and KEY="value")
ADMIN_PASS="$(grep -E '^OPENSEARCH_INITIAL_ADMIN_PASSWORD=' "$ENV_FILE" 2>/dev/null \
    | head -1 | cut -d= -f2- | tr -d '"'"'")"

if [ -z "$ADMIN_PASS" ]; then
    echo "WARNING: OPENSEARCH_INITIAL_ADMIN_PASSWORD not found in $ENV_FILE — skipping hash update."
elif ! command -v docker >/dev/null 2>&1; then
    echo "WARNING: docker not found — cannot regenerate hash. Update $INTERNAL_USERS_YML manually."
else
    OS_VER="$(grep -E '^OPEN_SEARCH_VERSION=' "$ENV_FILE" 2>/dev/null \
        | head -1 | cut -d= -f2- | tr -d '"'"'")"
    OS_VER="${OS_VER:-3.6.0}"

    echo "Generating bcrypt hash via opensearch:${OS_VER} hash.sh ..."
    # Pass password via env variable so shell-special characters in the password are safe.
    NEW_HASH="$(docker run --rm \
        -e "ADMIN_PASS=${ADMIN_PASS}" \
        "opensearchproject/opensearch:${OS_VER}" \
        bash -c '/usr/share/opensearch/plugins/opensearch-security/tools/hash.sh -p "$ADMIN_PASS" 2>/dev/null')"

    if [ -z "$NEW_HASH" ]; then
        echo "ERROR: hash.sh returned an empty result — $INTERNAL_USERS_YML NOT updated."
    else
        # Replace every  hash: "$2x$..."  line (covers admin, dashboards, kibanaserver users).
        # Uses Python to avoid sed delimiter conflicts with the hash's special characters.
        python3 - "$NEW_HASH" "$INTERNAL_USERS_YML" << 'PYEOF'
import re, sys
new_hash, filepath = sys.argv[1], sys.argv[2]
content = open(filepath).read()
content = re.sub(r'(  hash: )"\$2[aby]\$[^"]+"', rf'\1"{new_hash}"', content)
open(filepath, 'w').write(content)
PYEOF
        chmod 600 "$INTERNAL_USERS_YML"
        echo "internal_users.yml — all user hashes updated."
        echo "  hash : $NEW_HASH"
        echo ""
        echo "NOTE: New certificates invalidate any existing cluster data."
        echo "      Wipe data directories before the next cluster start:"
        echo "      rm -rf $SCRIPT_DIR/assets/opensearch/data/os0{1,2,3,4,5}data/*"
    fi
fi