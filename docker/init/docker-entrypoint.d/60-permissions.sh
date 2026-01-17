#!/bin/bash
# Verify and fix KVS permissions
# This is a failsafe that mirrors install_permissions.sh from KVS
# shellcheck disable=SC1091
source /init/lib/common.sh

log_info "Verifying critical permissions..."

PERM_FIXED=0

# Helper: verify/fix directory permission, optionally create if missing
fix_dir() {
    local dir="$1" perm="$2" create="${3:-false}"
    local actual

    if [ ! -d "$dir" ]; then
        if [ "$create" = "true" ]; then
            mkdir -p "$dir"
            chmod "$perm" "$dir"
            chown 1000:1000 "$dir"
            log_info "Created: $dir"
        fi
        return
    fi

    actual=$(stat -c "%a" "$dir" 2>/dev/null)
    if [ "$actual" != "$perm" ]; then
        chmod "$perm" "$dir"
        PERM_FIXED=$((PERM_FIXED + 1))
    fi
}

# Helper: verify/fix file permission
fix_file() {
    local file="$1" perm="$2"
    local actual

    [ ! -f "$file" ] && return

    actual=$(stat -c "%a" "$file" 2>/dev/null)
    if [ "$actual" != "$perm" ]; then
        chmod "$perm" "$file"
        PERM_FIXED=$((PERM_FIXED + 1))
    fi
}

# --- Directories that must be 777 ---
fix_dir "$KVS_PATH/tmp" "777" "true"
fix_dir "$KVS_PATH/admin/smarty/cache" "777"
fix_dir "$KVS_PATH/admin/smarty/template-c" "777"
fix_dir "$KVS_PATH/admin/smarty/template-c-site" "777"
fix_dir "$KVS_PATH/langs" "777"

# --- Directories that must be 755 (root only, subdirs are 777) ---
fix_dir "$KVS_PATH/contents" "755"
fix_dir "$KVS_PATH/admin/data" "755"

# --- All subdirs in these paths must be 777 ---
find "$KVS_PATH/admin/logs" -type d -exec chmod 777 {} \; 2>/dev/null || true
find "$KVS_PATH/admin/data" -mindepth 1 -type d -exec chmod 777 {} \; 2>/dev/null || true
find "$KVS_PATH/contents" -mindepth 1 -type d -exec chmod 777 {} \; 2>/dev/null || true
find "$KVS_PATH/template" -type d -exec chmod 777 {} \; 2>/dev/null || true
find "$KVS_PATH/static" -type d -exec chmod 777 {} \; 2>/dev/null || true

# --- Files that must be 666 ---
find "$KVS_PATH/admin/logs" -type f ! -iname ".htaccess" -exec chmod 666 {} \; 2>/dev/null || true
find "$KVS_PATH/admin/data" -type f \( -iname "*.dat" -o -iname "*.pem" -o -iname "*.tpl" \) -exec chmod 666 {} \; 2>/dev/null || true
find "$KVS_PATH/contents" -type f ! -iname ".htaccess" -exec chmod 666 {} \; 2>/dev/null || true
find "$KVS_PATH/template" -type f ! -iname ".htaccess" -exec chmod 666 {} \; 2>/dev/null || true
find "$KVS_PATH/langs" -type f -iname "*.lang" -exec chmod 666 {} \; 2>/dev/null || true
find "$KVS_PATH/static" -type f -exec chmod 666 {} \; 2>/dev/null || true
fix_file "$KVS_PATH/robots.txt" "666"
fix_file "$KVS_PATH/favicon.ico" "666"

# --- Critical directories for theme installation (ensure they exist) ---
fix_dir "$KVS_PATH/admin/data/tmp" "777" "true"
fix_dir "$KVS_PATH/admin/data/engine" "777" "true"

# Final ownership
chown -R 1000:1000 "$KVS_PATH"

# Re-run KVS permission script if available
if [ -f "$KVS_PATH/_INSTALL/install_permissions.sh" ]; then
    (cd "$KVS_PATH/_INSTALL" && bash install_permissions.sh) || true
fi

if [ "$PERM_FIXED" -eq 0 ]; then
    log_info "All permissions OK"
else
    log_info "Fixed $PERM_FIXED permission issues"
fi
