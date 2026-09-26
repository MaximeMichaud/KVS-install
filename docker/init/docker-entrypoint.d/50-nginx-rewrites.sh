#!/bin/bash
set -e

# Copy nginx rewrites from KVS archive
# shellcheck disable=SC1091
source /init/lib/common.sh

NGINX_INCLUDES="/nginx-includes"
REWRITES_FILE="$NGINX_INCLUDES/kvs-rewrites.conf"

install_rewrites_file() {
    local source_file="$1"
    local temp_file

    temp_file=$(mktemp "$NGINX_INCLUDES/.kvs-rewrites.conf.XXXXXX")
    if ! cp "$source_file" "$temp_file" || [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        return 1
    fi

    mv -f "$temp_file" "$REWRITES_FILE"
}

# Try to copy from _INSTALL directory first
if [ -f "$KVS_PATH/_INSTALL/nginx_config.txt" ]; then
    if ! install_rewrites_file "$KVS_PATH/_INSTALL/nginx_config.txt"; then
        log_error "Nginx rewrites in _INSTALL are empty or unreadable"
        exit 1
    fi
    log_info "Nginx rewrites copied from _INSTALL"
    exit 0
fi

# Already exists?
if [ -s "$REWRITES_FILE" ]; then
    log_info "Nginx rewrites already configured"
    exit 0
fi

# Remove an empty file left by an interrupted or older initialization.
rm -f "$REWRITES_FILE"

# Re-extract just nginx_config.txt if _INSTALL was already deleted
KVS_ARCHIVE=$(find_kvs_archive)
if [ -n "$KVS_ARCHIVE" ]; then
    TEMP_REWRITES=$(mktemp "$NGINX_INCLUDES/.kvs-rewrites.conf.XXXXXX")
    if ! unzip -p "$KVS_ARCHIVE" "_INSTALL/nginx_config.txt" > "$TEMP_REWRITES" 2>/dev/null || \
        [ ! -s "$TEMP_REWRITES" ]; then
        rm -f "$TEMP_REWRITES"
        log_error "Could not extract a non-empty nginx rewrites configuration"
        exit 1
    fi
    mv -f "$TEMP_REWRITES" "$REWRITES_FILE"
    log_info "Nginx rewrites extracted from archive"
else
    log_error "No nginx rewrites: the site has no _INSTALL/nginx_config.txt and no KVS archive is mounted (an import writes that file from IMPORT_NGINX_REWRITES or the old server's nginx configuration)"
    exit 1
fi
