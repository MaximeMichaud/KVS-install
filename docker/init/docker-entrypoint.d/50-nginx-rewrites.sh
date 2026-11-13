#!/bin/bash
set -e

# Copy nginx rewrites from KVS archive
# shellcheck disable=SC1091
source /init/lib/common.sh

NGINX_INCLUDES="/nginx-includes"
REWRITES_FILE="$NGINX_INCLUDES/kvs-rewrites.conf"

# install_rewrites_file <file> [sha256]
# With a sha256, only rules that have it, checked on the copy: the file it
# comes from may change in the meantime.
install_rewrites_file() {
    local source_file="$1" expected="${2:-}"
    local temp_file sum

    [ -f "$source_file" ] || return 1
    temp_file=$(mktemp "$NGINX_INCLUDES/.kvs-rewrites.conf.XXXXXX")
    if ! cp "$source_file" "$temp_file" || [ ! -s "$temp_file" ]; then
        rm -f "$temp_file"
        return 1
    fi
    if [ -n "$expected" ]; then
        sum=$(sha256sum < "$temp_file") || sum=""
        if [ "${sum%% *}" != "$expected" ]; then
            rm -f "$temp_file"
            return 1
        fi
    fi

    mv -f "$temp_file" "$REWRITES_FILE"
}

# The site belongs to uid 1000, which PHP-FPM and cron run as, so this
# root container takes _INSTALL/nginx_config.txt only when setup.sh wrote
# it for this run, an import, and passes its sha256. Otherwise the rules
# of the archive this run extracted, the include already in place, or the
# archive, in that order.
if [ -n "${KVS_NGINX_REWRITES_SHA256:-}" ]; then
    if ! install_rewrites_file "$KVS_PATH/_INSTALL/nginx_config.txt" "$KVS_NGINX_REWRITES_SHA256"; then
        log_error "_INSTALL/nginx_config.txt is not the file setup.sh wrote for this run (sha256 $KVS_NGINX_REWRITES_SHA256)"
        exit 1
    fi
    log_info "Nginx rewrites copied from _INSTALL, as setup.sh wrote them"
    exit 0
fi

if [ -f "$KVS_INIT_RUN_DIR/nginx_config.txt" ]; then
    if ! install_rewrites_file "$KVS_INIT_RUN_DIR/nginx_config.txt"; then
        log_error "Nginx rewrites of the KVS archive are empty or unreadable"
        exit 1
    fi
    log_info "Nginx rewrites copied from the extracted archive"
    exit 0
fi

if [ -f "$KVS_PATH/_INSTALL/nginx_config.txt" ]; then
    log_info "Not using _INSTALL/nginx_config.txt: neither this run's extraction nor setup.sh wrote it"
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
    log_error "No nginx rewrites: setup.sh wrote none for this run and no KVS archive is mounted (an import writes them to _INSTALL/nginx_config.txt from IMPORT_NGINX_REWRITES or the old server's nginx configuration)"
    exit 1
fi
