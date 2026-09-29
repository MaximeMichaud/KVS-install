#!/bin/bash
set -e

# Configure KVS PHP files (setup.php, setup_db.php)
# shellcheck disable=SC1091
source /init/lib/common.sh

# The literal value of a $config key in setup.php, from the first
# line that sets it, with any spacing around the brackets and the equal
# sign.
setup_php_value() {
    local key="$1"

    # shellcheck disable=SC2016  # The dollar sign is part of the PHP text.
    sed -n -E "s/^[[:space:]]*\\\$config[[:space:]]*\\[[[:space:]]*['\"]${key}['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"][[:space:]]*;.*/\\1/p" \
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
    set_setup_php_value "$key" "$container_path" || return 1
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

# Rewrite literal settings without evaluating the imported PHP file.
# Keep unsupported expressions unchanged and fail before claiming success.
set_setup_php_value() {
    local key="$1" value="$2" encoded
    encoded=${value//\\/\\\\}
    encoded=${encoded//\"/\\\"}
    encoded=${encoded//\$/\\\$}
    encoded=$(escape_sed_replacement "$encoded")
    # shellcheck disable=SC2016  # The dollar sign is part of the PHP text.
    sed -E -i "s#^([[:space:]]*\\\$config[[:space:]]*\\[[[:space:]]*['\"]${key}['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*)(\"[^\"]*\"|'[^']*')([[:space:]]*;)#\\1\"${encoded}\"\\3#" \
        "$KVS_PATH/admin/include/setup.php"
    if [ "$(setup_php_value "$key")" != "$value" ]; then
        log_error "Could not configure $key in setup.php"
        return 1
    fi
}

# adopt_user_ini_paths <old project path>
# PHP-FPM applies the .user.ini files of the site on every request. One that
# names a file under the directory the site had on the old server (an
# auto_prepend_file above all) fails every page once the site lives at
# KVS_PATH: point those paths at KVS_PATH. contents/ is not walked, PHP does
# not run there and it holds most of the files.
adopt_user_ini_paths() {
    local old="$1" old_pattern new file

    old_pattern=$(printf '%s' "$old" | sed -e 's/[][\\.^$*+?(){}|#]/\\&/g')
    new=$(escape_sed_replacement "$KVS_PATH")
    while IFS= read -r -d '' file; do
        grep -Eq "${old_pattern}([/\"' ;]|\$)" "$file" || continue
        sed -E -i "s#${old_pattern}([/\"' ;]|\$)#${new}\\1#g" "$file"
        log_info "${file#"$KVS_PATH"/}: paths under $old now under $KVS_PATH"
    done < <(find "$KVS_PATH" -path "$KVS_PATH/contents" -prune -o -name .user.ini -type f -print0)
}

# adopt_plugin_setting_paths <old project path>
# KVS plugins keep their settings as a serialized PHP array in
# admin/data/plugins/<plugin>/data.dat, absolute paths included: the backup
# plugin its backup directory, which would still name the old server's and
# list none of the backups the site brought along. Settings naming a path
# under the old project directory move under KVS_PATH; a file that is not a
# plain serialized array stays as it is.
adopt_plugin_setting_paths() {
    local old="$1" file result

    for file in "$KVS_PATH"/admin/data/plugins/*/data.dat; do
        [ -f "$file" ] || continue
        grep -Fq "$old" "$file" || continue
        # shellcheck disable=SC2016  # PHP code.
        if ! result=$(php -r '
            [, $file, $old, $new] = $argv;
            $data = @unserialize(file_get_contents($file), ["allowed_classes" => false]);
            if (!is_array($data)) {
                exit(0);
            }
            $changed = false;
            $plain = true;
            array_walk_recursive($data, function (&$value) use ($old, $new, &$changed, &$plain) {
                if (is_object($value)) {
                    $plain = false;
                } elseif (is_string($value) && ($value === $old || strncmp($value, "$old/", strlen($old) + 1) === 0)) {
                    $value = $new . substr($value, strlen($old));
                    $changed = true;
                }
            });
            if ($changed && $plain) {
                if (file_put_contents("$file.kvs-install", serialize($data)) === false || !rename("$file.kvs-install", $file)) {
                    exit(1);
                }
                echo "changed";
            }
        ' "$file" "$old" "$KVS_PATH"); then
            log_warn "${file#"$KVS_PATH"/}: could not move its settings under $old to $KVS_PATH"
            continue
        fi
        [ "$result" != changed ] || log_info "${file#"$KVS_PATH"/}: settings under $old now under $KVS_PATH"
    done
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

    # Imported files can use either quote style and ordinary PHP spacing.
    old_project_path=$(setup_php_value project_path)
    old_project_path=${old_project_path%/}
    set_setup_php_value project_path "$KVS_PATH"
    log_info "Project path: $KVS_PATH"
    if [ -n "$old_project_path" ] && [ "$old_project_path" != "$KVS_PATH" ]; then
        adopt_user_ini_paths "$old_project_path"
        adopt_plugin_setting_paths "$old_project_path"
    fi

    # Update project title with domain
    if [ -n "$DOMAIN" ]; then
        sed -i "/\$config\[.project_title.\]=/s/KVS/${DOMAIN}/" "$KVS_PATH/admin/include/setup.php"
    fi

    # Configure project_url based on USE_WWW
    PROJECT_URL=$(get_project_url)
    set_setup_php_value project_url "$PROJECT_URL"
    log_info "Project URL: $PROJECT_URL"

    # Keep KVS configured with localhost. Its audit plugin checks Memcached from
    # the PHP runtime as 127.0.0.1:11211; PHP and cron containers expose that
    # loopback via socat to the Docker cache service.
    if [ -n "$(setup_php_value memcache_server)" ]; then
        set_setup_php_value memcache_server 127.0.0.1
    fi
    log_info "Memcache: 127.0.0.1:11211 via container loopback"

    # The binaries as the PHP and cron images ship them (docker/php and
    # docker/cron Dockerfiles), with the links they add for KVS.
    adopt_setup_php_binary ffmpeg_path /usr/bin/ffmpeg /usr/local/bin/ffmpeg
    adopt_setup_php_binary php_path /usr/local/bin/php /usr/bin/php
    adopt_setup_php_binary image_magick_path /usr/bin/convert /usr/local/bin/convert
    adopt_setup_php_binary mysqldump_path /usr/bin/mysqldump /usr/bin/mariadb-dump

    # Two debug switches of setup.php fill admin/logs without limit:
    # $config['enable_debug'] ("for dev debugging" in the stock file) and
    # $config['sql_debug'], which the stock file does not carry (KVS support
    # adds the line by hand) and which writes every query into
    # debug_sql_get.txt and debug_sql_post.txt, gigabytes on a busy site. An
    # old server may have left either on; the site starts here without them.
    for debug_key in enable_debug sql_debug; do
        if [ "$(setup_php_value "$debug_key")" = true ]; then
            # shellcheck disable=SC2016  # The dollar sign is part of the PHP text.
            sed -E -i "s#^([[:space:]]*\\\$config[[:space:]]*\\[[[:space:]]*['\"]${debug_key}['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*)['\"]true['\"]#\\1\"false\"#" \
                "$KVS_PATH/admin/include/setup.php"
            log_info "KVS $debug_key was on in setup.php: turned off, it fills admin/logs on every request"
        fi
    done
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
