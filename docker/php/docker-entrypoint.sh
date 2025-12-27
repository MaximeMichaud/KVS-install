#!/bin/bash
set -e

# Apply PHP configuration from environment variables
PHP_INI="/usr/local/etc/php/conf.d/kvs.ini"

if [ -f "$PHP_INI" ]; then
    # Apply environment variable overrides
    [ -n "$PHP_MEMORY_LIMIT" ] && sed -i "s/memory_limit = .*/memory_limit = $PHP_MEMORY_LIMIT/" "$PHP_INI"
    [ -n "$PHP_UPLOAD_MAX_FILESIZE" ] && sed -i "s/upload_max_filesize = .*/upload_max_filesize = $PHP_UPLOAD_MAX_FILESIZE/" "$PHP_INI"
    [ -n "$PHP_POST_MAX_SIZE" ] && sed -i "s/post_max_size = .*/post_max_size = $PHP_POST_MAX_SIZE/" "$PHP_INI"
    [ -n "$PHP_MAX_EXECUTION_TIME" ] && sed -i "s/max_execution_time = .*/max_execution_time = $PHP_MAX_EXECUTION_TIME/" "$PHP_INI"
fi

exec "$@"
