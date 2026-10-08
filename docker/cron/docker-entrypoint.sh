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
# typo is seen instead of quietly turning the loader off. The PHP-FPM image
# runs the same function: the two containers must agree, or cron.php and the
# site disagree about what they can read.
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
# added) is reported and keeps the release of the image. The PHP-FPM image
# runs the same function: both containers must run the same yt-dlp.
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

# cron jobs do not inherit the container environment, so the decision is
# taken on the crontab itself. With updates on, a container that runs cron
# also looks for a newer release now, in the background: a new or recreated
# container (an upgrade to new images recreates them) would otherwise wait
# for Sunday with an empty volume, or with an older release than its image.
schedule_yt_dlp_updates() {
    local cron_file="/etc/cron.d/yt-dlp-update"

    if [ "$YT_DLP_UPDATES" != on ]; then
        rm -f "$cron_file"
        return
    fi
    if [ "${1:-}" = cron ]; then
        echo "yt-dlp: looking for a newer release in the background (log: /var/log/yt-dlp-update.log)"
        /usr/local/bin/yt-dlp-update >> /var/log/yt-dlp-update.log 2>&1 &
    fi
}

start_memcache_loopback
apply_ioncube_setting
apply_yt_dlp_auto_update
schedule_yt_dlp_updates "$@"

if [ -f /usr/local/lib/kvs-tls/internal-trust.sh ]; then
    exec sh /usr/local/lib/kvs-tls/internal-trust.sh run "$@"
fi
exec "$@"
