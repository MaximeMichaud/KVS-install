#!/bin/bash
set -e

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
