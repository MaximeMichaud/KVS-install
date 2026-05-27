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

start_memcache_loopback

exec "$@"
