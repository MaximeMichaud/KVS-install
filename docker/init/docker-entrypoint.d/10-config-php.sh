#!/bin/bash
# Configure KVS PHP files (setup.php, setup_db.php)
# shellcheck disable=SC1091
source /init/lib/common.sh

# Configure setup.php
if [ -f "$KVS_PATH/admin/include/setup.php" ]; then
    log_info "Configuring setup.php..."

    # Replace /PATH placeholder (fresh archives)
    sed -i "s|/PATH|$KVS_PATH|g" "$KVS_PATH/admin/include/setup.php"

    # Fix project_path if it was already configured for a different path
    sed -i "s|\$config\['project_path'\]=\"[^\"]*\"|\$config['project_path']=\"$KVS_PATH\"|" \
        "$KVS_PATH/admin/include/setup.php"
    log_info "Project path: $KVS_PATH"

    # Update project title with domain
    if [ -n "$DOMAIN" ]; then
        sed -i "/\$config\[.project_title.\]=/s/KVS/${DOMAIN}/" "$KVS_PATH/admin/include/setup.php"
    fi

    # Configure project_url based on USE_WWW
    PROJECT_URL=$(get_project_url)
    sed -i "s|\$config\['project_url'\]=\"[^\"]*\"|\$config['project_url']=\"${PROJECT_URL}\"|" \
        "$KVS_PATH/admin/include/setup.php"
    log_info "Project URL: $PROJECT_URL"

    # Configure memcache to use Docker network alias
    sed -i "s|\$config\['memcache_server'\]=\"[^\"]*\"|\$config['memcache_server']=\"cache\"|" \
        "$KVS_PATH/admin/include/setup.php"
    log_info "Memcache: cache:11211"
else
    log_warn "setup.php not found, skipping PHP configuration"
fi

# Configure database connection
if [ -f "$KVS_PATH/admin/include/setup_db.php" ]; then
    log_info "Configuring database connection..."
    sed -i "s|'DB_HOST','[^']*'|'DB_HOST','mariadb'|" "$KVS_PATH/admin/include/setup_db.php"
    sed -i "s|'DB_LOGIN','[^']*'|'DB_LOGIN','$DOMAIN'|" "$KVS_PATH/admin/include/setup_db.php"
    sed -i "s|'DB_PASS','[^']*'|'DB_PASS','$MARIADB_PASSWORD'|" "$KVS_PATH/admin/include/setup_db.php"
    sed -i "s|'DB_DEVICE','[^']*'|'DB_DEVICE','$DOMAIN'|" "$KVS_PATH/admin/include/setup_db.php"
    log_info "Database configured: mariadb/$DOMAIN"
else
    log_warn "setup_db.php not found, skipping database configuration"
fi
