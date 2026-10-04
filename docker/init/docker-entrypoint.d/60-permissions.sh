#!/bin/bash
set -e

# Verify and fix KVS permissions: the directories KVS writes to, the
# owner every container runs as, and the modes PHP and nginx need on the
# trees install_permissions.sh from KVS covers
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

# --- The roots of contents and admin/data stay 755, as KVS sets them ---
fix_dir "$KVS_PATH/contents" "755"
fix_dir "$KVS_PATH/admin/data" "755"

# Below them, and in admin/logs, template, static and langs, the install
# script of KVS sets 777 on every directory and 666 on every file, so
# that PHP can write files that belong to another account, such as the
# FTP account of a shared host. Here every KVS process runs as the owner
# of the site, 1000:1000: PHP-FPM, the cron container with the
# conversions, ffmpeg and ImageMagick it starts, and the scripts run with
# docker compose exec -u www-data. The owner's bits are what lets KVS
# write, replace and delete a file, so two things are needed: the owner
# reads and writes, and enters a directory; nginx, which runs as its own
# user, reads what it serves and enters the directories above it. What
# KVS creates is 666 and 777 anyway, its setup.php sets umask 0.
#
# These passes add those bits where one is missing (rw-r--r-- on a file,
# rwxr-xr-x on a directory) and leave every other entry as it is: they
# remove no bit, open nothing beyond the 666 and 777 of the install
# script, and write nothing on a site copied with its usual modes.
# chmod writes the inode even when the mode does not change: an import
# of millions of files must not leave millions of inode writes to this
# short-lived container, the start right after its last pass included.
add_missing_modes() {
    local tree="$1" min_depth="$2"
    shift 2

    [ -d "$tree" ] || return 0
    find "$tree" -mindepth "$min_depth" \
        \( -type d ! -perm -0755 -exec chmod u+rwx,go+rx {} + \) -o \
        \( -type f "$@" ! -perm -0644 -exec chmod u+rw,go+r {} + \) 2>/dev/null || true
}
add_missing_modes "$KVS_PATH/admin/logs" 0 ! -iname ".htaccess"
add_missing_modes "$KVS_PATH/admin/data" 1 \( -iname "*.dat" -o -iname "*.pem" -o -iname "*.tpl" \)
add_missing_modes "$KVS_PATH/contents" 1 ! -iname ".htaccess"
add_missing_modes "$KVS_PATH/template" 0 ! -iname ".htaccess"
add_missing_modes "$KVS_PATH/static" 0
find "$KVS_PATH/langs" -type f -iname "*.lang" ! -perm -0644 -exec chmod u+rw,go+r {} + 2>/dev/null || true
fix_file "$KVS_PATH/robots.txt" "666"
fix_file "$KVS_PATH/favicon.ico" "666"

# --- Critical directories for theme installation (ensure they exist) ---
fix_dir "$KVS_PATH/admin/data/tmp" "777" "true"
fix_dir "$KVS_PATH/admin/data/engine" "777" "true"

# Final ownership, as chown -R gives it (-h: a link itself, never what
# it points to), on the entries owned by anyone else only.
find "$KVS_PATH" \( ! -uid 1000 -o ! -gid 1000 \) -exec chown -h 1000:1000 {} +

# Run the archive's permission script once at the end, on a site this
# init extracted from the KVS archive (the cleanup step removes _INSTALL
# right after). An imported site that kept its _INSTALL directory brings
# the script along, and it sets 666 and 777 with chmod on every file and
# directory of contents, template, static, admin/data and admin/logs,
# whatever their mode: on a large site, millions of inode writes from
# this short-lived container for modes this stack does not need (see
# above). KVS releases use xargs without --no-run-if-empty, which calls
# chmod with no operands on fresh sites. Patch only that portability
# issue in the disposable _INSTALL copy.
if [ -f "$KVS_PATH/_INSTALL/install_permissions.sh" ]; then
    if [ -f "$KVS_PATH/.kvs-extraction-complete" ]; then
        sed -E -i 's/\|[[:space:]]*xargs[[:space:]]+chmod/| xargs -r chmod/g' \
            "$KVS_PATH/_INSTALL/install_permissions.sh"
        if ! (cd "$KVS_PATH/_INSTALL" && bash install_permissions.sh); then
            log_warn "KVS permission script reported an error after container safeguards were applied"
        fi
    else
        log_info "Not running _INSTALL/install_permissions.sh: the site was not extracted from the archive here, and the script would rewrite the mode of every file"
    fi
fi

# The archive permission script makes most PHP files world-readable. Database
# credentials only need to be readable by PHP-FPM's owner and root-run cron.
if [ -f "$KVS_PATH/admin/include/setup_db.php" ]; then
    if [ "$(stat -c '%u:%g' "$KVS_PATH/admin/include/setup_db.php")" != 1000:1000 ]; then
        chown 1000:1000 "$KVS_PATH/admin/include/setup_db.php"
    fi
    fix_file "$KVS_PATH/admin/include/setup_db.php" "600"
fi

if [ "$PERM_FIXED" -eq 0 ]; then
    log_info "All permissions OK"
else
    log_info "Fixed $PERM_FIXED permission issues"
fi
