#!/bin/bash
set -e

echo "=== KVS Docker Initialization ==="

KVS_PATH="/var/www/kvs"

# Check if KVS is already installed
if [ -f "$KVS_PATH/admin/include/setup.php" ]; then
    echo "KVS already installed, updating configuration..."
else
    echo "Installing KVS..."

    # Find KVS archive
    KVS_ARCHIVE=$(find /kvs-archive -name "KVS_*.zip" -type f 2>/dev/null | head -1)

    if [ -z "$KVS_ARCHIVE" ]; then
        echo "ERROR: No KVS archive found in /kvs-archive"
        echo "Please mount your KVS_X.X.X_[domain].zip file to /kvs-archive"
        exit 1
    fi

    echo "Found archive: $KVS_ARCHIVE"

    # Extract KVS
    mkdir -p "$KVS_PATH"
    unzip -o "$KVS_ARCHIVE" -d "$KVS_PATH"

    # Set permissions
    chown -R 1000:1000 "$KVS_PATH"
    chmod -R 755 "$KVS_PATH"

    # Run KVS permission script (without the problematic chmod 666)
    if [ -f "$KVS_PATH/_INSTALL/install_permissions.sh" ]; then
        sed -i '/xargs chmod 666/d' "$KVS_PATH/_INSTALL/install_permissions.sh"
        bash "$KVS_PATH/_INSTALL/install_permissions.sh" || true
    fi
fi

# Update setup.php paths
if [ -f "$KVS_PATH/admin/include/setup.php" ]; then
    echo "Configuring setup.php..."
    sed -i "s|/PATH|$KVS_PATH|g" "$KVS_PATH/admin/include/setup.php"

    # Update project title with domain
    if [ -n "$DOMAIN" ]; then
        sed -i "/\$config\[.project_title.\]=/s/KVS/${DOMAIN}/" "$KVS_PATH/admin/include/setup.php"
    fi

    # Configure project_url based on USE_WWW
    if [ "$USE_WWW" = "true" ]; then
        PROJECT_URL="https://www.${DOMAIN}"
    else
        PROJECT_URL="https://${DOMAIN}"
    fi
    sed -i "s|\$config\['project_url'\]=\"[^\"]*\"|\$config['project_url']=\"${PROJECT_URL}\"|" "$KVS_PATH/admin/include/setup.php"
    echo "Project URL set to: $PROJECT_URL"

    # Configure memcache to use Docker network alias
    sed -i "s|\$config\['memcache_server'\]=\"[^\"]*\"|\$config['memcache_server']=\"cache\"|" "$KVS_PATH/admin/include/setup.php"
    echo "Memcache configured to: cache:11211"
fi

# Configure database connection
if [ -f "$KVS_PATH/admin/include/setup_db.php" ]; then
    echo "Configuring database connection..."
    sed -i "s|'DB_HOST','[^']*'|'DB_HOST','kvs-mariadb'|" "$KVS_PATH/admin/include/setup_db.php"
    sed -i "s|'DB_LOGIN','[^']*'|'DB_LOGIN','$DOMAIN'|" "$KVS_PATH/admin/include/setup_db.php"
    sed -i "s|'DB_PASS','[^']*'|'DB_PASS','$MARIADB_PASSWORD'|" "$KVS_PATH/admin/include/setup_db.php"
    sed -i "s|'DB_DEVICE','[^']*'|'DB_DEVICE','$DOMAIN'|" "$KVS_PATH/admin/include/setup_db.php"
fi

# Wait for MariaDB (max 1 minute - should already be healthy)
TRIES=0
MAX_TRIES=30
until mariadb -h kvs-mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" -e "SELECT 1" "$DOMAIN" > /dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ $TRIES -ge $MAX_TRIES ]; then
        echo "ERROR: Cannot connect to MariaDB after 1 minute"
        echo "Check credentials: DOMAIN=$DOMAIN"
        exit 1
    fi
    echo "Waiting for MariaDB... ($TRIES/$MAX_TRIES)"
    sleep 2
done

# Check if database has tables
TABLE_COUNT=$(mariadb -h kvs-mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DOMAIN'" 2>/dev/null || echo "0")

if [ "$TABLE_COUNT" -eq 0 ]; then
    echo "Database is empty, need to import..."

    # If install_db.sql doesn't exist, re-extract from archive
    if [ ! -f "$KVS_PATH/_INSTALL/install_db.sql" ]; then
        KVS_ARCHIVE=$(find /kvs-archive -name "KVS_*.zip" -type f 2>/dev/null | head -1)
        if [ -n "$KVS_ARCHIVE" ]; then
            echo "Re-extracting _INSTALL from archive..."
            unzip -o "$KVS_ARCHIVE" "_INSTALL/*" -d "$KVS_PATH"
        fi
    fi

    if [ -f "$KVS_PATH/_INSTALL/install_db.sql" ]; then
        mariadb -h kvs-mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" < "$KVS_PATH/_INSTALL/install_db.sql"
        echo "Database imported successfully"
    else
        echo "ERROR: install_db.sql not found"
    fi
fi

# Clean up installation files
if [ -d "$KVS_PATH/_INSTALL" ]; then
    rm -rf "$KVS_PATH/_INSTALL"
    echo "Installation files cleaned up"
fi

# Clear stale cron locks (prevents "Duplicate cron operation" errors after container recreation)
# This is safe during init since cron container hasn't started yet
echo "Clearing cron locks..."
find "$KVS_PATH/admin/data" -name "*.lock" -type f -delete 2>/dev/null || true

# Clear CRON_UID from database so new container can register
# Table name may be ktvs_options or sys_options depending on KVS version
if mariadb -h kvs-mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" \
    -e "SELECT 1 FROM ktvs_options LIMIT 1;" >/dev/null 2>&1; then
    mariadb -h kvs-mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" \
        -e "DELETE FROM ktvs_options WHERE variable IN ('CRON_UID', 'CRON_TIME');" 2>/dev/null || true
    echo "Cleared cron registration from ktvs_options"
fi

# Final permissions
chown -R 1000:1000 "$KVS_PATH"

echo "=== KVS Initialization Complete ==="
