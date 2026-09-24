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
# never loaded, which is also what makes opcache JIT usable.
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

start_memcache_loopback
apply_ioncube_setting

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

exec "$@"
