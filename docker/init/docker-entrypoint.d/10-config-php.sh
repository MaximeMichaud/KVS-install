#!/bin/bash
set -e

# Configure KVS PHP files (setup.php, setup_db.php)
# shellcheck disable=SC1091
source /init/lib/common.sh

# The double-quoted value of a $config key in setup.php, from the first
# line that sets it, with any spacing around the brackets and the equal
# sign.
setup_php_value() {
    local key="$1"

    # shellcheck disable=SC2016  # The dollar sign is part of the PHP text.
    sed -n -E "s/^[[:space:]]*\\\$config[[:space:]]*\\[[[:space:]]*['\"]${key}['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\\1/p" \
        "$KVS_PATH/admin/include/setup.php" | head -n 1
}

# adopt_setup_php_binary <key> <container path> [other path in the image...]
# KVS runs every background task through $config['php_path'], every
# screenshot through image_magick_path, conversions through ffmpeg_path and
# backups through mysqldump_path. A site imported from another server names
# them where that server had them; anything the PHP and cron images do not
# ship at that path is pointed at the container path. A key the file does
# not set is left alone.
adopt_setup_php_binary() {
    local key="$1"
    local container_path="$2"
    local current
    local known
    shift 2

    current=$(setup_php_value "$key")
    [ -n "$current" ] || return 0
    for known in "$container_path" "$@"; do
        [ "$current" != "$known" ] || return 0
    done
    # shellcheck disable=SC2016  # The dollar sign is part of the PHP text.
    sed -E -i "s#^([[:space:]]*\\\$config[[:space:]]*\\[[[:space:]]*['\"]${key}['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*)\"[^\"]*\"#\\1\"$(escape_sed_replacement "$container_path")\"#" \
        "$KVS_PATH/admin/include/setup.php"
    if [ "$(setup_php_value "$key")" != "$container_path" ]; then
        log_error "Could not point $key at $container_path in setup.php"
        return 1
    fi
    log_info "${key%_path} path: $current is not in the container, set to $container_path"
}

escape_php_single_quoted() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\'/\\\'}
    printf '%s' "$value"
}

escape_sed_replacement() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//&/\\&}
    value=${value//#/\\#}
    printf '%s' "$value"
}

# The single-quoted text of a define in setup_db.php, escapes included, as
# the first line that defines the name carries it, with any spacing after
# the comma.
setup_db_value() {
    local name="$1"

    sed -n -E "s/^[[:space:]]*define\\('${name}',[[:space:]]*'(([^'\\\\]|\\\\.)*)'\\).*/\\1/p" \
        "$KVS_PATH/admin/include/setup_db.php" | head -n 1
}

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

    # Keep KVS configured with localhost. Its audit plugin checks Memcached from
    # the PHP runtime as 127.0.0.1:11211; PHP and cron containers expose that
    # loopback via socat to the Docker cache service.
    sed -i "s|\$config\['memcache_server'\]=\"[^\"]*\"|\$config['memcache_server']=\"127.0.0.1\"|" \
        "$KVS_PATH/admin/include/setup.php"
    log_info "Memcache: 127.0.0.1:11211 via container loopback"

    # The binaries as the PHP and cron images ship them (docker/php and
    # docker/cron Dockerfiles), with the links they add for KVS.
    adopt_setup_php_binary ffmpeg_path /usr/bin/ffmpeg /usr/local/bin/ffmpeg
    adopt_setup_php_binary php_path /usr/local/bin/php /usr/bin/php
    adopt_setup_php_binary image_magick_path /usr/bin/convert /usr/local/bin/convert
    adopt_setup_php_binary mysqldump_path /usr/bin/mysqldump /usr/bin/mariadb-dump

    # KVS debug mode ($config['enable_debug'], "for dev debugging" in the
    # stock file) writes every request and query into admin/logs
    # (debug_sql_get.txt and friends), files that grow without limit. An
    # old server may have left it on; the site starts here without it.
    if [ "$(setup_php_value enable_debug)" = true ]; then
        # shellcheck disable=SC2016  # The dollar sign is part of the PHP text.
        sed -E -i "s#^([[:space:]]*\\\$config[[:space:]]*\\[[[:space:]]*['\"]enable_debug['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*)\"true\"#\\1\"false\"#" \
            "$KVS_PATH/admin/include/setup.php"
        log_info "KVS debug mode (enable_debug in setup.php) was on: turned off, it logs every query into admin/logs"
    fi
else
    log_warn "setup.php not found, skipping PHP configuration"
fi

# Configure database connection
if [ -f "$KVS_PATH/admin/include/setup_db.php" ]; then
    log_info "Configuring database connection..."
    DB_PASSWORD_PHP=$(escape_php_single_quoted "$MARIADB_PASSWORD")
    DB_PASSWORD_SED=$(escape_sed_replacement "$DB_PASSWORD_PHP")

    # Owners write this file by hand, so the comma is followed by any
    # spacing; every value is read back afterwards, a define the sed did
    # not reach would leave the site on the old server's database.
    sed -E -i \
        -e "s#('DB_HOST',[[:space:]]*)'[^']*'#\\1'mariadb'#" \
        -e "s#('DB_LOGIN',[[:space:]]*)'[^']*'#\\1'${DOMAIN}'#" \
        -e "s#('DB_PASS',[[:space:]]*)'([^'\\\\]|\\\\.)*'#\\1'${DB_PASSWORD_SED}'#" \
        -e "s#('DB_DEVICE',[[:space:]]*)'[^']*'#\\1'${DOMAIN}'#" \
        "$KVS_PATH/admin/include/setup_db.php"
    for setting in "DB_HOST=mariadb" "DB_LOGIN=${DOMAIN}" "DB_PASS=${DB_PASSWORD_PHP}" "DB_DEVICE=${DOMAIN}"; do  # pragma: allowlist secret
        if [ "$(setup_db_value "${setting%%=*}")" != "${setting#*=}" ]; then
            log_error "setup_db.php does not define ${setting%%=*} as expected after the rewrite"
            log_error "Check the define('${setting%%=*}', '...') line of admin/include/setup_db.php"
            exit 1
        fi
    done
    chown 1000:1000 "$KVS_PATH/admin/include/setup_db.php"
    chmod 600 "$KVS_PATH/admin/include/setup_db.php"
    log_info "Database configured: mariadb/$DOMAIN"
else
    log_warn "setup_db.php not found, skipping database configuration"
fi
