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
# runtime setting, not a build argument: NO renames the ini so the loader is
# never loaded. It must match the PHP-FPM container, or cron.php and the site
# disagree about what they can read.
apply_ioncube_setting() {
    local enabled_ini="/usr/local/etc/php/conf.d/00-ioncube.ini"
    local disabled_ini="/usr/local/etc/php/conf.d/00-ioncube.ini.disabled"
    local choice

    choice=$(printf '%s' "${IONCUBE:-YES}" | tr '[:upper:]' '[:lower:]')
    case "$choice" in
        no|false|0|off|disabled)
            if [ -f "$enabled_ini" ]; then
                mv -f "$enabled_ini" "$disabled_ini" || {
                    echo "ERROR: cannot disable the IonCube loader: ${enabled_ini} is not writable" >&2
                    exit 1
                }
            fi
            echo "IonCube loader disabled (IONCUBE=${IONCUBE:-YES})"
            ;;
        *)
            if [ ! -f "$enabled_ini" ] && [ -f "$disabled_ini" ]; then
                mv -f "$disabled_ini" "$enabled_ini" || {
                    echo "ERROR: cannot enable the IonCube loader: ${disabled_ini} is not writable" >&2
                    exit 1
                }
            fi
            ;;
    esac
}

# A published image ships the yt-dlp its manifest names. The weekly job moves
# that binary forward, which is what an operator wants and a reproducible
# deployment does not, so it can be turned off. cron jobs do not inherit the
# container environment, so the decision is taken here, on the crontab itself.
apply_yt_dlp_auto_update() {
    local cron_file="/etc/cron.d/yt-dlp-update"
    local choice

    choice=$(printf '%s' "${YT_DLP_AUTO_UPDATE:-yes}" | tr '[:upper:]' '[:lower:]')
    case "$choice" in
        no|false|0|off|disabled)
            if [ -f "$cron_file" ]; then
                rm -f "$cron_file"
            fi
            echo "yt-dlp weekly update disabled (YT_DLP_AUTO_UPDATE=${YT_DLP_AUTO_UPDATE})"
            ;;
    esac
}

start_memcache_loopback
apply_ioncube_setting
apply_yt_dlp_auto_update

exec "$@"
