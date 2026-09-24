#!/bin/bash
set -e

# Import KVS database if empty
# shellcheck disable=SC1091
source /init/lib/common.sh
TABLES_PREFIX=$(get_tables_prefix)

extract_archive_project_url() {
    local archive="$1"
    local setup_php
    local line
    local project_url_re

    if ! setup_php=$(unzip -p "$archive" "admin/include/setup.php" 2>/dev/null); then
        return 1
    fi

    project_url_re="\\\$config[[:space:]]*\\[[[:space:]]*['\"]project_url['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"](https?://[^'\"]+)['\"]"
    while IFS= read -r line; do
        if [[ "$line" =~ $project_url_re ]]; then
            printf '%s\n' "${BASH_REMATCH[1]%/}"
            return 0
        fi
    done <<< "$setup_php"

    return 1
}

escape_sed_ere() {
    sed 's/[][\\.^$*+?(){}|~]/\\&/g'
}

escape_sed_replacement() {
    sed 's/[\\&~]/\\&/g'
}

is_valid_initial_version() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)+([._+-][A-Za-z0-9]+)*$ ]]
}

read_database_initial_version() {
    local table
    local version

    for table in "${TABLES_PREFIX}options" sys_options; do
        if version=$(db_query \
            "SELECT value FROM \`${table}\` WHERE variable='INITIAL_VERSION' LIMIT 1;"); then
            version=${version%$'\r'}
            if is_valid_initial_version "$version"; then
                printf '%s\t%s\n' "$table" "$version"
                return 0
            fi
        fi
    done

    return 1
}

extract_dump_initial_version() {
    local dump_file="$1"
    local last_sql_line
    local marker_re
    local table
    local version

    last_sql_line=$(awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*(--|#)/ { next }
        { sub(/\r$/, ""); line = $0 }
        END { print line }
    ' "$dump_file")
    marker_re="^[[:space:]]*insert[[:space:]]+into[[:space:]]+\`?([A-Za-z0-9_]+)\`?.*['\"]INITIAL_VERSION['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*\)[[:space:]]*;?[[:space:]]*$"

    shopt -s nocasematch
    if [[ ! "$last_sql_line" =~ $marker_re ]]; then
        return 1
    fi

    table=${BASH_REMATCH[1]}
    version=${BASH_REMATCH[2]}
    if [[ "$table" != "${TABLES_PREFIX}options" && "$table" != "sys_options" ]] ||
        ! is_valid_initial_version "$version"; then
        return 1
    fi

    printf '%s\t%s\n' "$table" "$version"
}

# Check the database before importing. Any existing schema without KVS's final
# INITIAL_VERSION row is ambiguous: importing again would overwrite evidence
# and collide with partially created tables.
if ! TABLE_COUNT=$(db_query \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DOMAIN'"); then
    log_error "Could not inspect the database before import"
    exit 1
fi
if [[ ! "$TABLE_COUNT" =~ ^[0-9]+$ ]]; then
    log_error "Database table count is invalid: $TABLE_COUNT"
    exit 1
fi

if [ "$TABLE_COUNT" -gt 0 ]; then
    if DATABASE_MARKER=$(read_database_initial_version); then
        DATABASE_INITIAL_VERSION=${DATABASE_MARKER#*$'\t'}
        log_info "Database import is complete (INITIAL_VERSION=$DATABASE_INITIAL_VERSION), skipping import"
        exit 0
    fi

    log_error "Database contains $TABLE_COUNT tables but has no valid INITIAL_VERSION marker"
    log_error "A previous import may be incomplete; refusing to re-import or modify existing data"
    exit 1
fi

log_info "Database is empty, importing..."

# If install_db.sql doesn't exist, re-extract from archive
KVS_ARCHIVE=$(find_kvs_archive)
if [ ! -f "$KVS_PATH/_INSTALL/install_db.sql" ]; then
    if [ -n "$KVS_ARCHIVE" ]; then
        log_info "Re-extracting _INSTALL from archive..."
        unzip -o "$KVS_ARCHIVE" "_INSTALL/*" -d "$KVS_PATH"
    fi
fi

if [ ! -f "$KVS_PATH/_INSTALL/install_db.sql" ]; then
    log_error "install_db.sql not found"
    exit 1
fi

# Seed archives contain absolute URLs for their licensed domain. Normalize
# those URLs for the requested installation host without changing any license
# metadata. Read the source URL from the untouched archive because setup.php
# in the extracted tree has already been configured for the target domain.
if [ -z "$KVS_ARCHIVE" ]; then
    log_error "KVS archive not found; cannot determine the source project URL"
    exit 1
fi

if ! SOURCE_PROJECT_URL=$(extract_archive_project_url "$KVS_ARCHIVE"); then
    log_error "Could not read a source project URL from the KVS archive"
    exit 1
fi
if [[ ! "$SOURCE_PROJECT_URL" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    log_error "Invalid source project URL in the KVS archive"
    exit 1
fi

TARGET_PROJECT_URL=$(get_project_url)
SOURCE_PROJECT_URL_RE=$(printf '%s' "$SOURCE_PROJECT_URL" | escape_sed_ere)
TARGET_PROJECT_URL_REPLACEMENT=$(printf '%s' "$TARGET_PROJECT_URL" | escape_sed_replacement)
IMPORT_SQL=$(mktemp /tmp/kvs-install-db.XXXXXX.sql)
chmod 600 "$IMPORT_SQL"
trap 'rm -f "$IMPORT_SQL"' EXIT

if ! sed -E \
    "s~${SOURCE_PROJECT_URL_RE}([^A-Za-z0-9._-]|$)~${TARGET_PROJECT_URL_REPLACEMENT}\\1~g" \
    "$KVS_PATH/_INSTALL/install_db.sql" > "$IMPORT_SQL"; then
    log_error "Could not normalize project URLs in install_db.sql"
    exit 1
fi
log_info "Normalized archive project URLs for $TARGET_PROJECT_URL"

if ! DUMP_MARKER=$(extract_dump_initial_version "$IMPORT_SQL"); then
    log_error "install_db.sql does not end with a valid INITIAL_VERSION marker"
    log_error "Refusing to import a dump without a reliable completion marker"
    exit 1
fi
INITIAL_VERSION_TABLE=${DUMP_MARKER%%$'\t'*}
EXPECTED_INITIAL_VERSION=${DUMP_MARKER#*$'\t'}

# Import database
if ! MYSQL_PWD="$MARIADB_PASSWORD" \
    mariadb -h mariadb -u "$DOMAIN" "$DOMAIN" < "$IMPORT_SQL"; then
    log_error "Database import failed; preserving $KVS_PATH/_INSTALL for troubleshooting"
    exit 1
fi

if ! IMPORTED_INITIAL_VERSION=$(db_query \
    "SELECT value FROM \`${INITIAL_VERSION_TABLE}\` WHERE variable='INITIAL_VERSION' LIMIT 1;"); then
    log_error "Database import returned success, but INITIAL_VERSION could not be verified"
    exit 1
fi
IMPORTED_INITIAL_VERSION=${IMPORTED_INITIAL_VERSION%$'\r'}
if [ "$IMPORTED_INITIAL_VERSION" != "$EXPECTED_INITIAL_VERSION" ]; then
    log_error "Database import completion marker mismatch"
    log_error "Expected INITIAL_VERSION=$EXPECTED_INITIAL_VERSION, got ${IMPORTED_INITIAL_VERSION:-<empty>}"
    exit 1
fi

log_info "Database imported successfully (INITIAL_VERSION=$EXPECTED_INITIAL_VERSION)"
