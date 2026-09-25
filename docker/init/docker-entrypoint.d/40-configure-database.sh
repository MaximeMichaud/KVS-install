#!/bin/bash
set -e

# Configure database settings (cron, paths, SSL)
# shellcheck disable=SC1091
source /init/lib/common.sh
TABLES_PREFIX=$(get_tables_prefix)

# Clear stale cron locks (prevents "Duplicate cron operation" errors after container recreation)
log_info "Clearing cron locks..."
find "$KVS_PATH/admin/data" -name "*.lock" -type f -delete 2>/dev/null || true

# Clear CRON_UID from database so new container can register
# The options table carries the site prefix (very old versions used sys_options)
if db_exec "SELECT 1 FROM ${TABLES_PREFIX}options LIMIT 1;" >/dev/null 2>&1; then
    db_exec "DELETE FROM ${TABLES_PREFIX}options WHERE variable IN ('CRON_UID', 'CRON_TIME');" 2>/dev/null || true
    log_info "Cleared cron registration from ${TABLES_PREFIX}options"
fi

# Replace %PROJECT_PATH% placeholder in server paths
# This is normally done by post_install.php but may fail if project_path was wrong on first admin access
db_exec "UPDATE ${TABLES_PREFIX}admin_servers SET path = REPLACE(path, '%PROJECT_PATH%', '$KVS_PATH') WHERE path LIKE '%PROJECT_PATH%';" 2>/dev/null || true
db_exec "UPDATE ${TABLES_PREFIX}admin_conversion_servers SET path = REPLACE(path, '%PROJECT_PATH%', '$KVS_PATH') WHERE path LIKE '%PROJECT_PATH%';" 2>/dev/null || true
log_info "Server paths configured: $KVS_PATH"

# Keep persisted storage URLs synchronized when setup changes ports, canonical
# host selection, or direct/Caddy mode on an existing database.
PROJECT_URL=$(get_project_url)
DOMAIN_PATTERN=${DOMAIN//./[.]}
# An imported site keeps its storage URLs on the domain it was served
# from; when this installation runs under another one (a development
# subdomain tried before the real domain), those URLs move to the new
# host as well. URLs on any other host (a CDN) stay.
HOST_PATTERN=$DOMAIN_PATTERN
if [ -n "${IMPORT_SOURCE_DOMAIN:-}" ] && [ "$IMPORT_SOURCE_DOMAIN" != "$DOMAIN" ]; then
    if [[ "$IMPORT_SOURCE_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
        HOST_PATTERN="(${DOMAIN_PATTERN}|${IMPORT_SOURCE_DOMAIN//./[.]})"
        log_info "Storage URLs on $IMPORT_SOURCE_DOMAIN move to $PROJECT_URL"
    else
        log_warn "IMPORT_SOURCE_DOMAIN is not a domain name, ignored: $IMPORT_SOURCE_DOMAIN"
    fi
fi
if ! db_exec "UPDATE ${TABLES_PREFIX}admin_servers
    SET urls = REGEXP_REPLACE(
        urls,
        '^https?://(www[.])?${HOST_PATTERN}(:[0-9]+)?/contents/',
        '${PROJECT_URL}/contents/'
    )
    WHERE urls REGEXP '^https?://(www[.])?${HOST_PATTERN}(:[0-9]+)?/contents/';"; then
    log_error "Could not synchronize persisted server URLs"
    exit 1
fi
if ! MATCHING_URL_COUNT=$(db_query \
    "SELECT COUNT(*) FROM ${TABLES_PREFIX}admin_servers WHERE urls LIKE '${PROJECT_URL}/contents/%';") ||
    ! STALE_URL_COUNT=$(db_query \
    "SELECT COUNT(*) FROM ${TABLES_PREFIX}admin_servers WHERE urls REGEXP '^https?://(www[.])?${HOST_PATTERN}(:[0-9]+)?/contents/' AND urls NOT LIKE '${PROJECT_URL}/contents/%';"); then
    log_error "Could not verify persisted server URLs"
    exit 1
fi
if [[ ! "$MATCHING_URL_COUNT" =~ ^[0-9]+$ ]] ||
    [[ ! "$STALE_URL_COUNT" =~ ^[0-9]+$ ]] || [ "$STALE_URL_COUNT" -ne 0 ]; then
    log_error "Persisted server URLs do not match $PROJECT_URL"
    exit 1
fi
# An imported site may serve its storage from other hosts (a CDN, a
# separate storage server): those URLs stay as they are.
if [ "$MATCHING_URL_COUNT" -lt 1 ]; then
    if ! EXTERNAL_URL_COUNT=$(db_query \
        "SELECT COUNT(*) FROM ${TABLES_PREFIX}admin_servers WHERE urls NOT REGEXP '^https?://(www[.])?${HOST_PATTERN}(:[0-9]+)?/';") ||
        [[ ! "$EXTERNAL_URL_COUNT" =~ ^[0-9]+$ ]] || [ "$EXTERNAL_URL_COUNT" -lt 1 ]; then
        log_error "Persisted server URLs do not match $PROJECT_URL"
        exit 1
    fi
    log_warn "Storage servers use external hosts ($EXTERNAL_URL_COUNT), their URLs are left as they are"
else
    log_info "Server URLs configured: ${PROJECT_URL}/contents/..."
fi

# Synchronize TLS verification in both directions. Public certificates must
# not inherit the relaxed setting from an earlier self-signed deployment.
SSL_SKIP_VALUE=0
if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    SSL_SKIP_VALUE=1
fi
if ! db_exec \
    "UPDATE ${TABLES_PREFIX}admin_servers SET streaming_skip_ssl_check = ${SSL_SKIP_VALUE};"; then
    log_error "Could not synchronize server TLS verification"
    exit 1
fi
if ! SSL_MISMATCH_COUNT=$(db_query \
    "SELECT COUNT(*) FROM ${TABLES_PREFIX}admin_servers WHERE COALESCE(streaming_skip_ssl_check,-1)<>${SSL_SKIP_VALUE};") ||
    [[ ! "$SSL_MISMATCH_COUNT" =~ ^[0-9]+$ ]] ||
    [ "$SSL_MISMATCH_COUNT" -ne 0 ]; then
    log_error "Server TLS verification does not match the selected certificate mode"
    exit 1
fi
if [ "$SSL_SKIP_VALUE" -eq 1 ]; then
    log_info "SSL verification disabled for self-signed certificate"
else
    log_info "SSL verification enabled for public certificate"
fi
