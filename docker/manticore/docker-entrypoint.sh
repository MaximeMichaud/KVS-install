#!/bin/bash
set -e
set -o pipefail

echo "=== Manticore Search Init for KVS ==="

# Convert domain to safe index name (replace dots/dashes with underscores)
DOMAIN_SAFE="${DOMAIN//[.-]/_}"
export DOMAIN_SAFE

echo "Domain: $DOMAIN"
echo "Index prefix: $DOMAIN_SAFE"

# Generate manticore.conf from template
echo "Generating configuration..."
# Keep the allowlist literal for envsubst.
# shellcheck disable=SC2016
envsubst '${DOMAIN_SAFE} ${DOMAIN} ${MARIADB_PASSWORD}' \
    < /etc/manticoresearch/manticore.conf.template \
    > /etc/manticoresearch/manticore.conf
chown -R manticore:manticore /var/lib/manticore /var/log/manticore
chown manticore:manticore /etc/manticoresearch/manticore.conf
chmod 600 /etc/manticoresearch/manticore.conf

# Wait for MariaDB to be ready
echo "Waiting for MariaDB..."
MAX_TRIES=30
TRIES=0
until MYSQL_PWD="$MARIADB_PASSWORD" \
    mariadb -h mariadb -u "$DOMAIN" -e "SELECT 1" "$DOMAIN" >/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ $TRIES -ge $MAX_TRIES ]; then
        echo "ERROR: Cannot connect to MariaDB after 1 minute"
        exit 1
    fi
    echo "  Waiting... ($TRIES/$MAX_TRIES)"
    sleep 2
done
echo "✓ MariaDB is ready"

# Initial index build
echo "Building initial indexes (this may take a while)..."
if gosu manticore bash -o pipefail -c \
    'indexer --all 2>&1 | tee /var/log/manticore/indexer-init.log'; then
    echo "✓ Initial indexes built successfully"
else
    echo "⚠ Initial indexing had warnings (check /var/log/manticore/indexer-init.log)"
fi

# Start cron for hourly updates
echo "Starting cron for hourly index updates..."
service cron start || echo "⚠ Cron not available (may need to install)"

echo "=== Starting Manticore Search ==="

# Delegate the final launch to the upstream entrypoint. It fixes ownership of
# Manticore runtime paths and re-executes searchd as the manticore user through
# gosu, so Buddy inherits the same unprivileged UID/GID.
exec /usr/local/bin/manticore-entrypoint.sh "$@"
