#!/bin/bash
# Import of an existing KVS site into the Docker stack.
#
# The functions validate the site directory and the database dump of the
# old server, prepare the dump for the MariaDB init directory and place the
# site files where the containers expect them. They take their inputs as
# arguments and print their results on stdout, so setup.sh and the
# standalone installer can share them and the tests can run them alone.

# Print the value of $config['<key>'] from a KVS PHP config file read on
# stdin, as written by KVS: $config['project_path']="/var/www/kvs";
import_php_config_value() {
    local key="$1"

    sed -n -E "s/^[[:space:]]*\\\$config\\[[[:space:]]*['\"]${key}['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p" | head -n 1
}

# import_read_php_config_value <file> <key>
import_read_php_config_value() {
    local file="$1"
    local key="$2"

    import_php_config_value "$key" < "$file"
}

# import_read_kvs_version <site directory>: the version in admin/include/version.php.
import_read_kvs_version() {
    local dir="$1"

    [ -f "$dir/admin/include/version.php" ] || return 1
    import_read_php_config_value "$dir/admin/include/version.php" project_version
}

# import_archive_version <KVS zip>: the version of the archive's version.php.
import_archive_version() {
    local archive="$1"

    unzip -p "$archive" admin/include/version.php 2>/dev/null | import_php_config_value project_version
}

# import_validate_site <site directory>
# Prints "<KVS version><TAB><project_path>" for a directory that holds a
# KVS site the Docker init can adopt; explains the refusal on stderr.
import_validate_site() {
    local dir="$1"
    local setup prefix path version

    if [ ! -d "$dir" ]; then
        echo "ERROR: IMPORT_SITE_DIR is not a directory: $dir" >&2
        return 1
    fi
    setup="$dir/admin/include/setup.php"
    if [ ! -f "$setup" ]; then
        echo "ERROR: $dir holds no KVS site (admin/include/setup.php is missing)" >&2
        return 1
    fi
    if [ ! -f "$dir/admin/include/setup_db.php" ]; then
        echo "ERROR: $dir/admin/include/setup_db.php is missing" >&2
        return 1
    fi
    prefix=$(import_read_php_config_value "$setup" tables_prefix)
    if [ "$prefix" != "ktvs_" ]; then
        echo "ERROR: the site uses the table prefix '${prefix:-<empty>}'; the Docker init only supports ktvs_" >&2
        return 1
    fi
    path=$(import_read_php_config_value "$setup" project_path)
    if [ -z "$path" ]; then
        echo "ERROR: project_path was not found in $setup" >&2
        return 1
    fi
    version=$(import_read_kvs_version "$dir") || version=""
    if [ -z "$version" ]; then
        echo "ERROR: the KVS version was not found in $dir/admin/include/version.php" >&2
        return 1
    fi
    printf '%s\t%s\n' "$version" "$path"
}

# import_field <tab separated line> <index from 1>
# One field of a line printed by the functions below. read with a tab IFS
# collapses consecutive tabs and would drop an empty field.
import_field() {
    local line="$1"
    local index="$2"
    local i=1

    while [ "$i" -lt "$index" ]; do
        case "$line" in
            *$'\t'*) line=${line#*$'\t'} ;;
            *) line="" ;;
        esac
        i=$((i + 1))
    done
    printf '%s' "${line%%$'\t'*}"
}

# import_dump_cat <dump>: stream the dump decompressed.
import_dump_cat() {
    case "$1" in
        *.zst) zstd -dc -- "$1" ;;
        *.gz) gzip -dc -- "$1" ;;
        *.xz) xz -dc -- "$1" ;;
        *) cat -- "$1" ;;
    esac
}

# import_inspect_dump <dump> <table prefix>
# One pass over the dump. Prints "<tables><TAB><initial version><TAB><database statements>":
# the number of CREATE TABLE statements for the prefix, the INITIAL_VERSION
# value found in the options rows (empty when absent) and the number of
# CREATE DATABASE or USE statements, which the prepared dump drops.
import_inspect_dump() {
    local dump="$1"
    local prefix="$2"
    local tool

    if [ ! -f "$dump" ]; then
        echo "ERROR: IMPORT_DB_DUMP is not a file: $dump" >&2
        return 1
    fi
    case "$dump" in
        *.zst) tool=zstd ;;
        *.gz) tool=gzip ;;
        *.xz) tool=xz ;;
        *) tool="" ;;
    esac
    if [ -n "$tool" ] && ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: $tool is needed to read $dump" >&2
        return 1
    fi
    import_dump_cat "$dump" | awk -v prefix="$prefix" '
        BEGIN { tables = 0; initial = ""; statements = 0 }
        $0 ~ ("^CREATE TABLE `?" prefix) { tables++; next }
        /^(CREATE DATABASE|USE )/ { statements++; next }
        initial == "" && match($0, /\x27INITIAL_VERSION\x27[[:space:]]*,[[:space:]]*\x27[^\x27]*\x27/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/^\x27INITIAL_VERSION\x27[[:space:]]*,[[:space:]]*\x27/, "", value)
            sub(/\x27$/, "", value)
            initial = value
        }
        END { printf "%d\t%s\t%d\n", tables, initial, statements }
    '
}

# import_sql_escape <text>: escape a value for a single-quoted SQL string.
import_sql_escape() {
    local value="$1"

    value=${value//\\/\\\\}
    value=${value//\'/\\\'}
    printf '%s' "$value"
}

# import_sql_like_escape <text>: escape a value for the fixed part of a LIKE pattern.
import_sql_like_escape() {
    local value
    value=$(import_sql_escape "$1")

    value=${value//%/\\%}
    value=${value//_/\\_}
    printf '%s' "$value"
}

# import_path_rewrite_sql <table prefix> <old project path> <new project path>
# SQL that moves the storage and conversion server paths from the old
# project path to the container path, anchored on the path prefix.
import_path_rewrite_sql() {
    local prefix="$1"
    local old_path="$2"
    local new_path="$3"
    local old_sql new_sql old_like table

    old_sql=$(import_sql_escape "$old_path")
    new_sql=$(import_sql_escape "$new_path")
    old_like=$(import_sql_like_escape "$old_path")
    for table in admin_servers admin_conversion_servers; do
        printf "UPDATE \`%s%s\` SET path = CONCAT('%s', SUBSTRING(path, CHAR_LENGTH('%s') + 1)) WHERE path = '%s' OR path LIKE '%s/%%';\n" \
            "$prefix" "$table" "$new_sql" "$old_sql" "$old_sql" "$old_like"
    done
}

# import_dump_write <output>: write stdin to the output, zstd-compressed
# when the name ends in .zst.
import_dump_write() {
    case "$1" in
        *.zst) zstd -q -T0 -3 - -o "$1" ;;
        *) cat > "$1" ;;
    esac
}

# import_prepare_dump <dump> <table prefix> <KVS version> <old project path> <new project path> <output> <token>
# Write the dump the MariaDB init directory will replay: CREATE DATABASE
# and USE statements dropped (the init runs inside the database named in
# .env), INITIAL_VERSION added when the old site never recorded it, server
# paths rewritten to the container path, and a completion marker row
# KVS_INSTALL_IMPORT=<token> as the very last statement: the MariaDB image
# restarts on a failed init file and would serve the partial database, so
# the caller checks the marker before touching anything.
import_prepare_dump() {
    local dump="$1"
    local prefix="$2"
    local version="$3"
    local old_path="$4"
    local new_path="$5"
    local output="$6"
    local token="$7"
    local inspection tables initial statements

    inspection=$(import_inspect_dump "$dump" "$prefix") || return 1
    tables=$(import_field "$inspection" 1)
    initial=$(import_field "$inspection" 2)
    statements=$(import_field "$inspection" 3)
    if [ "${tables:-0}" -lt 1 ]; then
        echo "ERROR: $dump holds no CREATE TABLE for the ${prefix} tables" >&2
        return 1
    fi
    {
        import_dump_cat "$dump" | sed -E '/^(CREATE DATABASE|USE )/d'
        echo
        echo "-- kvs-install import"
        if [ -z "$initial" ]; then
            printf "INSERT INTO \`%soptions\` (variable, value) VALUES ('INITIAL_VERSION', '%s') ON DUPLICATE KEY UPDATE value = value;\n" \
                "$prefix" "$(import_sql_escape "$version")"
        fi
        if [ "$old_path" != "$new_path" ]; then
            import_path_rewrite_sql "$prefix" "$old_path" "$new_path"
        fi
        printf "INSERT INTO \`%soptions\` (variable, value) VALUES ('KVS_INSTALL_IMPORT', '%s') ON DUPLICATE KEY UPDATE value = VALUES(value);\n" \
            "$prefix" "$(import_sql_escape "$token")"
    } | import_dump_write "$output" || return 1
    printf '%s\t%s\t%s\n' "$tables" "$initial" "$statements"
}

# import_place_site <source> <destination>
# Copy the site into the destination unless the source already is the
# destination. The destination must be absent or empty. Ownership is left
# to the init container, which sets the whole tree to the PHP user.
import_place_site() {
    local source="$1"
    local destination="$2"
    local resolved_source resolved_destination

    resolved_source=$(readlink -f -- "$source") || return 1
    resolved_destination=$(readlink -f -- "$destination" 2>/dev/null) || resolved_destination=$destination
    if [ "$resolved_source" = "$resolved_destination" ]; then
        echo "Site files already in place at $destination"
    else
        if [ -e "$destination" ] && [ ! -d "$destination" ]; then
            echo "ERROR: $destination exists and is not a directory" >&2
            return 1
        fi
        if [ -d "$destination" ] && find "$destination" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
            echo "ERROR: $destination is not empty; import into an empty site directory, or point IMPORT_SITE_DIR at it when the files are already there" >&2
            return 1
        fi
        mkdir -p "$destination" || return 1
        if command -v rsync >/dev/null 2>&1; then
            rsync -a -- "$resolved_source/" "$destination/" || return 1
        else
            cp -a -- "$resolved_source/." "$destination/" || return 1
        fi
        echo "Site files copied from $source to $destination"
    fi
    rm -f "$destination/.kvs-extraction-in-progress"
}

# import_free_space_ok <source> <destination>
# True when the filesystem holding the destination (or its nearest existing
# parent) has room for a copy of the source, with a tenth of margin.
import_free_space_ok() {
    local source="$1"
    local destination="$2"
    local probe needed available

    probe=$destination
    while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
        probe=$(dirname -- "$probe")
    done
    needed=$(du -sm -- "$source" 2>/dev/null | awk '{print $1}')
    available=$(df -Pm -- "$probe" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -n "$needed" ] && [ -n "$available" ] || return 1
    [ "$available" -ge $(( needed + needed / 10 )) ]
}
