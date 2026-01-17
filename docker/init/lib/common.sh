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
    mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" -e "$1" 2>/dev/null
}

# Execute SQL query and capture output
# Usage: result=$(db_query "SELECT COUNT(*) FROM table")
db_query() {
    mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" -N -e "$1" "$DOMAIN" 2>/dev/null
}

# Check if database connection works
db_is_ready() {
    mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" -e "SELECT 1" "$DOMAIN" > /dev/null 2>&1
}

# Get project URL based on USE_WWW setting
get_project_url() {
    if [ "$USE_WWW" = "true" ]; then
        echo "https://www.${DOMAIN}"
    else
        echo "https://${DOMAIN}"
    fi
}

# Safe domain name for use in identifiers (replaces . and - with _)
get_safe_domain() {
    echo "${DOMAIN//[.-]/_}"
}
