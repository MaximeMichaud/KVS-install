#!/bin/bash
# Configure database settings (cron, paths, SSL)
# shellcheck disable=SC1091
source /init/lib/common.sh

# Clear stale cron locks (prevents "Duplicate cron operation" errors after container recreation)
log_info "Clearing cron locks..."
find "$KVS_PATH/admin/data" -name "*.lock" -type f -delete 2>/dev/null || true

# Clear CRON_UID from database so new container can register
# Table name may be ktvs_options or sys_options depending on KVS version
if db_exec "SELECT 1 FROM ktvs_options LIMIT 1;" >/dev/null 2>&1; then
    db_exec "DELETE FROM ktvs_options WHERE variable IN ('CRON_UID', 'CRON_TIME');" 2>/dev/null || true
    log_info "Cleared cron registration from ktvs_options"
fi

# Replace %PROJECT_PATH% placeholder in server paths
# This is normally done by post_install.php but may fail if project_path was wrong on first admin access
db_exec "UPDATE ktvs_admin_servers SET path = REPLACE(path, '%PROJECT_PATH%', '$KVS_PATH') WHERE path LIKE '%PROJECT_PATH%';" 2>/dev/null || true
db_exec "UPDATE ktvs_admin_conversion_servers SET path = REPLACE(path, '%PROJECT_PATH%', '$KVS_PATH') WHERE path LIKE '%PROJECT_PATH%';" 2>/dev/null || true
log_info "Server paths configured: $KVS_PATH"

# Skip SSL verification for self-signed certificates
if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    db_exec "UPDATE ktvs_admin_servers SET streaming_skip_ssl_check = 1;" 2>/dev/null || true
    log_info "SSL verification disabled for self-signed certificate"
fi
