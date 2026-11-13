#!/bin/bash
set -e

start_memcache_loopback() {
    if [ "${KVS_MEMCACHE_LOOPBACK:-true}" != "true" ]; then
        return
    fi

    local host="${KVS_MEMCACHE_HOST:-cache}"
    local port="${KVS_MEMCACHE_PORT:-11211}"

    case "$port" in
        ''|*[!0-9]*)
            echo "WARNING: invalid KVS_MEMCACHE_PORT '${port}', skipping Memcached loopback" >&2
            return
            ;;
    esac

    if [ "$host" = "127.0.0.1" ] || [ "$host" = "localhost" ]; then
        return
    fi

    if ! command -v socat >/dev/null 2>&1; then
        echo "WARNING: socat is not installed, cannot expose Memcached on 127.0.0.1:${port}" >&2
        return
    fi

    if php -r "\$s=@fsockopen('127.0.0.1',(int)${port},\$e,\$m,1); exit(\$s ? 0 : 1);" >/dev/null 2>&1; then
        echo "Memcache loopback already listening on 127.0.0.1:${port}"
        return
    fi

    socat "TCP4-LISTEN:${port},bind=127.0.0.1,reuseaddr,fork" "TCP:${host}:${port}" &
    echo "Memcache loopback: 127.0.0.1:${port} -> ${host}:${port}"
}

# The ionCube loader is installed in every image, because the build does not
# know whether the site it will serve is encoded. IONCUBE is therefore a
# runtime setting, not a build argument. yes, true, 1 and on, in any case,
# keep the loader, and so does an unset or empty IONCUBE, the default of the
# stack. Anything else renames the ini so the loader is never loaded, and a
# word that is not one of no, false, 0, off and disabled is reported, so a
# typo is seen instead of quietly turning the loader off. The cron image runs
# the same function.
apply_ioncube_setting() {
    local enabled_ini="/usr/local/etc/php/conf.d/00-ioncube.ini"
    local disabled_ini="/usr/local/etc/php/conf.d/00-ioncube.ini.disabled"
    local value="${IONCUBE:-yes}"

    case "${value,,}" in
        yes|true|1|on)
            if [ ! -f "$enabled_ini" ] && [ -f "$disabled_ini" ]; then
                mv -f "$disabled_ini" "$enabled_ini" || {
                    echo "ERROR: cannot enable the IonCube loader: ${disabled_ini} is not writable" >&2
                    exit 1
                }
            fi
            return
            ;;
        no|false|0|off|disabled)
            ;;
        *)
            echo "WARNING: IONCUBE='${value}' is not one of yes, true, 1, on, no, false, 0, off or disabled, so the IonCube loader is disabled" >&2
            ;;
    esac

    if [ -f "$enabled_ini" ]; then
        mv -f "$enabled_ini" "$disabled_ini" || {
            echo "ERROR: cannot disable the IonCube loader: ${enabled_ini} is not writable" >&2
            exit 1
        }
    fi
    echo "IonCube loader disabled (IONCUBE=${value})"
}

# Opcache JIT follows the loader. With the ionCube loader loaded, PHP turns
# JIT off and warns at start that JIT is incompatible with extensions that
# set up user opcode handlers, so JIT is configured exactly when the loader
# is off. setup.sh used to append these two settings to php.ini, which left
# the tracked file modified; they are written here instead, to an ini that
# sorts before kvs.ini (the stack's php.ini), so a JIT setting written there
# still wins. JIT arrived with PHP 8.0, so a 7.4 image gets no file.
apply_opcache_jit_setting() {
    local loader_ini="/usr/local/etc/php/conf.d/00-ioncube.ini"
    local jit_ini="/usr/local/etc/php/conf.d/10-opcache-jit.ini"

    if [ -f "$loader_ini" ] || ! php -r 'exit(PHP_MAJOR_VERSION >= 8 ? 0 : 1);'; then
        rm -f "$jit_ini"
        return
    fi
    {
        echo "; Written by docker-entrypoint.sh because the IonCube loader is disabled."
        echo "opcache.jit_buffer_size = 256M"
        echo "opcache.jit = 1255"
    } > "$jit_ini"
    echo "Opcache JIT enabled (opcache.jit = 1255, opcache.jit_buffer_size = 256M)"
}

# yt-dlp can be there twice: the release the image was built with, and the
# newer one the cron container keeps in the yt-dlp volume, which the yt-dlp
# command runs when it is newer (yt-dlp.sh). YT_DLP_AUTO_UPDATE is read like
# IONCUBE: yes, true, 1 and on, in any case, and an unset or empty value, keep
# the link to the volume; no, false, 0, off and disabled remove it, so yt-dlp
# stays at the release of the image; any other word is reported and removes
# it too, so a typo never turns updates on. Updates also need the volume:
# without it the cron container would install them in its own layer, which
# PHP-FPM never sees and a recreated container loses, so a compose file older
# than the volume (the copy an additional multi-site site got when it was
# added) is reported and keeps the release of the image. The cron image runs
# the same function: both containers must run the same yt-dlp.
# shellcheck disable=SC2034  # YT_DLP_UPDATES is what the cron image reads.
apply_yt_dlp_auto_update() {
    local link="/usr/local/lib/yt-dlp/updates"
    local value="${YT_DLP_AUTO_UPDATE:-yes}"
    local reason="YT_DLP_AUTO_UPDATE=${value}"

    case "${value,,}" in
        yes|true|1|on)
            if awk '$5 == "/var/lib/yt-dlp" { found = 1 } END { exit !found }' /proc/self/mountinfo; then
                YT_DLP_UPDATES=on
                if [ ! -L "$link" ]; then
                    ln -s /var/lib/yt-dlp "$link" ||
                        echo "WARNING: cannot turn the yt-dlp updates on: ${link} is not writable" >&2
                fi
                return
            fi
            echo "WARNING: no volume is mounted on /var/lib/yt-dlp, so yt-dlp is not updated: the docker-compose.yml of this stack is older than the yt-dlp volume (an additional multi-site site: copy multi-site/docker-compose.site.yml.template over it again)" >&2
            reason="no yt-dlp volume"
            ;;
        no|false|0|off|disabled)
            ;;
        *)
            echo "WARNING: YT_DLP_AUTO_UPDATE='${value}' is not one of yes, true, 1, on, no, false, 0, off or disabled, so yt-dlp is not updated" >&2
            ;;
    esac
    YT_DLP_UPDATES=off
    if [ -L "$link" ]; then
        rm -f "$link" ||
            echo "WARNING: cannot turn the yt-dlp updates off: ${link} is not writable" >&2
    fi
    echo "yt-dlp updates disabled (${reason}): yt-dlp stays at the release of the image"
}

# PHP sessions are files, and in /tmp they live in the layer of the
# container: the container an upgrade recreates starts without them, which
# logs out every visitor and admin. docker-compose.yml mounts the
# php-sessions volume on /var/lib/php/sessions, and the sessions are kept
# there instead. Docker gives the volume the owner and mode of that
# directory in the image, but only while the volume is empty: they are set
# again here, for a volume that holds files already. A compose file older
# than the volume (the copy an additional multi-site site got when it was
# added) keeps the sessions in /tmp, as before, and is reported. The ini
# sorts before kvs.ini (the stack's php.ini), so a session.save_path
# written there still wins.
apply_session_storage() {
    local directory="/var/lib/php/sessions"
    local session_ini="/usr/local/etc/php/conf.d/10-sessions.ini"

    rm -f "$session_ini"
    if ! awk -v directory="$directory" '$5 == directory { found = 1 } END { exit !found }' /proc/self/mountinfo; then
        echo "WARNING: no volume is mounted on ${directory}, so the PHP sessions stay in /tmp and a recreated container logs everyone out: the docker-compose.yml of this stack is older than the php-sessions volume (an additional multi-site site: copy multi-site/docker-compose.site.yml.template over it again)" >&2
        return
    fi
    if ! chown www-data:www-data "$directory" || ! chmod 0700 "$directory"; then
        echo "WARNING: cannot give ${directory} to www-data, so the PHP sessions stay in /tmp" >&2
        return
    fi
    {
        echo "; Written by docker-entrypoint.sh because the php-sessions volume is mounted."
        echo "session.save_path = \"${directory}\""
    } > "$session_ini"
    echo "PHP sessions kept in the php-sessions volume (${directory})"
}

# phpMyAdmin is where the MariaDB root password is typed, so it does not run
# as the site's www-data: PHP code of the site (a hole in KVS or in a plugin)
# could rewrite config.inc.php, or a template phpMyAdmin compiled to PHP in
# tmp/, and keep the password of the next login, or read the sessions and
# config.inc.php, which hold the keys of phpMyAdmin's login cookies. It runs
# in a PHP-FPM pool of its own as kvs-phpmyadmin, which listens on a socket
# only the group of nginx's workers may open: on a port, PHP code of the site
# could send that pool FastCGI requests of its own, with the PHP settings it
# likes. The two pools share the OPcache memory, where the site's PHP would
# run phpMyAdmin's cached config.inc.php though it may not read the file:
# validate_permission makes OPcache check that first. config.inc.php and
# tmp/ belonged to www-data in earlier releases. A tmp/ owned by anyone else
# than kvs-phpmyadmin is emptied and taken over at every start. A
# config.inc.php that root alone may not have written is not: the site's PHP
# could have added code to it, which this pool would run, so phpMyAdmin is
# not served until docker/phpmyadmin/init.sh writes it anew (status 2). That
# script installs phpMyAdmin with the same owners.
prepare_phpmyadmin_files() {
    local directory="$1"
    local uid="$2"
    local gid="$3"
    local socket_directory="${directory}/.kvs-fpm"
    local config="${directory}/config.inc.php"
    local tmp="${directory}/tmp"

    chown 0:0 "$directory" && chmod 0755 "$directory" || return 1
    if [ -L "$socket_directory" ] || { [ -e "$socket_directory" ] && [ ! -d "$socket_directory" ]; }; then
        rm -f -- "$socket_directory" || return 1
    fi
    mkdir -p "$socket_directory" && chown 0:0 "$socket_directory" &&
        chmod 0755 "$socket_directory" || return 1
    if [ -L "$config" ]; then
        return 1
    fi
    if [ -f "$config" ]; then
        local config_owner config_mode
        config_owner=$(stat -c %u "$config") && config_mode=$(stat -c %a "$config") || return 1
        if [ "$config_owner" != 0 ] || (( 8#$config_mode & 8#022 )); then
            return 2
        fi
        chown "0:${gid}" "$config" && chmod 0640 "$config" || return 1
    fi
    if [ -L "$tmp" ] || { [ -e "$tmp" ] && { [ ! -d "$tmp" ] ||
        [ "$(stat -c %u:%g "$tmp")" != "${uid}:${gid}" ]; }; }; then
        rm -rf -- "$tmp" && mkdir "$tmp" || return 1
    fi
    if [ -d "$tmp" ]; then
        chown "${uid}:${gid}" "$tmp" && chmod 0700 "$tmp" || return 1
    fi
}

apply_phpmyadmin_pool() {
    local directory=/usr/share/phpmyadmin
    local pool_conf=/usr/local/etc/php-fpm.d/zz-kvs-phpmyadmin.conf
    local opcache_ini=/usr/local/etc/php/conf.d/zz-kvs-phpmyadmin.ini
    local uid
    local gid
    local prepared=0

    rm -f "$pool_conf" "$opcache_ini"
    if [ ! -d "$directory" ]; then
        echo "phpMyAdmin is not mounted on ${directory}, so its PHP-FPM pool is not started"
        return
    fi
    if ! uid=$(id -u kvs-phpmyadmin) || ! gid=$(id -g kvs-phpmyadmin); then
        prepared=1
    else
        prepare_phpmyadmin_files "$directory" "$uid" "$gid" || prepared=$?
    fi
    if [ "$prepared" -eq 2 ]; then
        echo "WARNING: ${directory}/config.inc.php may have been written by another user than root, as earlier releases let the site's PHP do, so phpMyAdmin is not served until phpmyadmin-init writes it anew: run setup.sh, or docker compose --profile setup run --rm phpmyadmin-init, then docker compose restart php-fpm" >&2
        return
    fi
    if [ "$prepared" -ne 0 ]; then
        echo "WARNING: cannot give ${directory} to kvs-phpmyadmin, so phpMyAdmin is not served" >&2
        return
    fi
    # Before the pool: without it, the site's PHP reads what the pool caches.
    {
        echo "; Written by docker-entrypoint.sh with the phpMyAdmin pool."
        echo "opcache.validate_permission = 1"
    } > "$opcache_ini"
    # nginx's workers run as the nginx user of its image, GID 101.
    cat > "$pool_conf" << EOF
; Written by docker-entrypoint.sh: phpMyAdmin, apart from the site's PHP.
[phpmyadmin]
user = kvs-phpmyadmin
group = kvs-phpmyadmin
listen = ${directory}/.kvs-fpm/php-fpm.sock
listen.owner = kvs-phpmyadmin
listen.group = 101
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 60s
security.limit_extensions = .php
php_admin_value[session.save_path] = /var/lib/kvs-phpmyadmin/sessions
php_admin_value[upload_tmp_dir] = /var/lib/kvs-phpmyadmin/tmp
php_admin_value[sys_temp_dir] = /var/lib/kvs-phpmyadmin/tmp
EOF
    echo "phpMyAdmin runs in its own PHP-FPM pool as kvs-phpmyadmin"
}

case "${1:-}" in
    php-fpm|/usr/local/sbin/php-fpm)
        # shellcheck source=docker/php/fpm-config.sh
        source /usr/local/lib/kvs/fpm-config.sh
        configure_php_fpm
        apply_phpmyadmin_pool
        ;;
esac

start_memcache_loopback
apply_ioncube_setting
apply_opcache_jit_setting
apply_yt_dlp_auto_update
apply_session_storage

# Apply PHP configuration from environment variables
# Write to a separate file (zzz- prefix loads last, overrides kvs.ini)
ENV_INI="/usr/local/etc/php/conf.d/zzz-env.ini"

{
    echo "; Environment variable overrides"
    [ -n "$PHP_MEMORY_LIMIT" ] && echo "memory_limit = $PHP_MEMORY_LIMIT"
    [ -n "$PHP_UPLOAD_MAX_FILESIZE" ] && echo "upload_max_filesize = $PHP_UPLOAD_MAX_FILESIZE"
    [ -n "$PHP_POST_MAX_SIZE" ] && echo "post_max_size = $PHP_POST_MAX_SIZE"
    [ -n "$PHP_MAX_EXECUTION_TIME" ] && echo "max_execution_time = $PHP_MAX_EXECUTION_TIME"
} > "$ENV_INI"

if [ -f /usr/local/lib/kvs-tls/internal-trust.sh ]; then
    exec sh /usr/local/lib/kvs-tls/internal-trust.sh run "$@"
fi
exec "$@"
