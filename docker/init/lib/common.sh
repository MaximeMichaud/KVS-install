#!/bin/bash
# Common functions for KVS initialization scripts

# Paths
export KVS_PATH="/var/www/kvs"
export KVS_ARCHIVE_DIR="/kvs-archive"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo ""
    echo -e "${GREEN}=== $1 ===${NC}"
}

# Find KVS archive (used in multiple scripts)
# Returns path to archive or empty string if not found
find_kvs_archive() {
    find "$KVS_ARCHIVE_DIR" -name "KVS_*.zip" -type f 2>/dev/null | head -1
}

# Check if KVS is already installed
kvs_is_installed() {
    [ -f "$KVS_PATH/admin/include/setup.php" ]
}

# Execute SQL query against MariaDB
# Usage: db_exec "SELECT 1"
db_exec() {
    MYSQL_PWD="$MARIADB_PASSWORD" \
        mariadb -h mariadb -u "$DOMAIN" "$DOMAIN" -e "$1" 2>/dev/null
}

# Execute SQL query and capture output
# Usage: result=$(db_query "SELECT COUNT(*) FROM table")
db_query() {
    MYSQL_PWD="$MARIADB_PASSWORD" \
        mariadb -h mariadb -u "$DOMAIN" -N -e "$1" "$DOMAIN" 2>/dev/null
}

# Check if database connection works
db_is_ready() {
    MYSQL_PWD="$MARIADB_PASSWORD" \
        mariadb -h mariadb -u "$DOMAIN" -e "SELECT 1" "$DOMAIN" > /dev/null 2>&1
}

# Get project URL based on USE_WWW setting
get_project_url() {
    local host
    local port="${PROJECT_HTTPS_PORT:-443}"
    local port_suffix=""

    case "$port" in
        ''|*[!0-9]*)
            log_error "PROJECT_HTTPS_PORT must be a numeric TCP port"
            return 1
            ;;
    esac
    if ((10#$port < 1 || 10#$port > 65535)); then
        log_error "PROJECT_HTTPS_PORT must be between 1 and 65535"
        return 1
    fi
    port=$((10#$port))
    if [ "$port" -ne 443 ]; then
        port_suffix=":${port}"
    fi

    if [ "$USE_WWW" = "true" ]; then
        host="www.${DOMAIN}"
    else
        host="$DOMAIN"
    fi
    printf 'https://%s%s\n' "$host" "$port_suffix"
}

# Safe domain name for use in identifiers (replaces . and - with _)
get_safe_domain() {
    echo "${DOMAIN//[.-]/_}"
}

# The table prefix of the site, as KVS wrote it in setup.php: ktvs_ for
# every archive KVS ships, whatever the old server used for an imported
# site. The value lands inside SQL, so only identifier characters pass;
# anything else falls back to ktvs_ with a warning on stderr.
get_tables_prefix() {
    local pattern prefix

    pattern="s/^[[:space:]]*\\\$config\\[[[:space:]]*['\"]tables_prefix['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p"
    prefix=$(sed -n -E "$pattern" "$KVS_PATH/admin/include/setup.php" 2>/dev/null | head -n 1)
    if [[ ! "$prefix" =~ ^[A-Za-z0-9_]{1,32}$ ]]; then
        log_warn "No usable tables_prefix in setup.php (got '${prefix}'), using ktvs_" >&2
        prefix=ktvs_
    fi
    printf '%s\n' "$prefix"
}
