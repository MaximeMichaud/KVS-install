#!/bin/bash
# Import KVS database if empty
# shellcheck disable=SC1091
source /init/lib/common.sh

# Check if database has tables
TABLE_COUNT=$(db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DOMAIN'" || echo "0")

if [ "$TABLE_COUNT" -gt 0 ]; then
    log_info "Database already has $TABLE_COUNT tables, skipping import"
    exit 0
fi

log_info "Database is empty, importing..."

# If install_db.sql doesn't exist, re-extract from archive
if [ ! -f "$KVS_PATH/_INSTALL/install_db.sql" ]; then
    KVS_ARCHIVE=$(find_kvs_archive)
    if [ -n "$KVS_ARCHIVE" ]; then
        log_info "Re-extracting _INSTALL from archive..."
        unzip -o "$KVS_ARCHIVE" "_INSTALL/*" -d "$KVS_PATH"
    fi
fi

if [ ! -f "$KVS_PATH/_INSTALL/install_db.sql" ]; then
    log_error "install_db.sql not found"
    exit 1
fi

# Fix server URLs based on USE_WWW setting (KVS generates with www. by default)
if [ "$USE_WWW" != "true" ]; then
    sed -i "s|https://www\.${DOMAIN}|https://${DOMAIN}|g" "$KVS_PATH/_INSTALL/install_db.sql"
    log_info "Fixed server URLs to non-www"
fi

# Import database
mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" < "$KVS_PATH/_INSTALL/install_db.sql"
log_info "Database imported successfully"
