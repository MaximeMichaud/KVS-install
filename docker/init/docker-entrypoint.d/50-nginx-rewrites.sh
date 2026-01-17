#!/bin/bash
# Copy nginx rewrites from KVS archive
# shellcheck disable=SC1091
source /init/lib/common.sh

NGINX_INCLUDES="/nginx-includes"

# Try to copy from _INSTALL directory first
if [ -f "$KVS_PATH/_INSTALL/nginx_config.txt" ]; then
    cp "$KVS_PATH/_INSTALL/nginx_config.txt" "$NGINX_INCLUDES/kvs-rewrites.conf"
    log_info "Nginx rewrites copied from _INSTALL"
    exit 0
fi

# Already exists?
if [ -f "$NGINX_INCLUDES/kvs-rewrites.conf" ]; then
    log_info "Nginx rewrites already configured"
    exit 0
fi

# Re-extract just nginx_config.txt if _INSTALL was already deleted
KVS_ARCHIVE=$(find_kvs_archive)
if [ -n "$KVS_ARCHIVE" ]; then
    unzip -p "$KVS_ARCHIVE" "_INSTALL/nginx_config.txt" > "$NGINX_INCLUDES/kvs-rewrites.conf" 2>/dev/null || true
    log_info "Nginx rewrites extracted from archive"
else
    log_warn "Could not find nginx rewrites configuration"
fi
