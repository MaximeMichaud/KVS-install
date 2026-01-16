#!/bin/bash
set -e

echo "=== Manticore Search Init for KVS ==="

# Convert domain to safe index name (replace dots/dashes with underscores)
DOMAIN_SAFE="${DOMAIN//[.-]/_}"
export DOMAIN_SAFE

echo "Domain: $DOMAIN"
echo "Index prefix: $DOMAIN_SAFE"

# Generate manticore.conf from template
echo "Generating configuration..."
envsubst < /etc/manticoresearch/manticore.conf.template > /etc/manticoresearch/manticore.conf

# Wait for MariaDB to be ready
echo "Waiting for MariaDB..."
MAX_TRIES=30
TRIES=0
until mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" -e "SELECT 1" "$DOMAIN" >/dev/null 2>&1; do
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
if indexer --all 2>&1 | tee /var/log/manticore/indexer-init.log; then
    echo "✓ Initial indexes built successfully"
else
    echo "⚠ Initial indexing had warnings (check /var/log/manticore/indexer-init.log)"
fi

# Start cron for hourly updates
echo "Starting cron for hourly index updates..."
service cron start || echo "⚠ Cron not available (may need to install)"

echo "=== Starting Manticore Search ==="

# Execute original command
exec "$@"
