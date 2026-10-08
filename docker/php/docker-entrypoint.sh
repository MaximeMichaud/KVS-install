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

start_memcache_loopback
apply_ioncube_setting
apply_opcache_jit_setting
apply_yt_dlp_auto_update

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
