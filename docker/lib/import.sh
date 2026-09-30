#!/bin/bash
# Import of an existing KVS site into the Docker stack.
#
# The functions validate the site directory and the database dump of the
# old server, prepare the dump for the MariaDB init directory and place the
# site files where the containers expect them. The site and the dump can
# come from a directory, from an archive (zip, 7z, tar) or from the old
# server over SSH; every source ends as the same two local inputs. The
# functions take their inputs as arguments and print their results on
# stdout, so setup.sh and the standalone installer can share them and the
# tests can run them alone.

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

# import_url_domain <url>: the host of a project URL without scheme, port,
# path or a leading www.
import_url_domain() {
    local url="$1"

    url=${url#*://}
    url=${url%%/*}
    url=${url%%:*}
    url=${url#www.}
    printf '%s' "${url,,}"
}

# import_validate_site <site directory>
# Prints "<KVS version><TAB><project_path><TAB><table prefix>" for a
# directory that holds a KVS site the Docker init can adopt; explains the
# refusal on stderr. The prefix is whatever the site was installed with,
# limited to identifier characters since it lands inside SQL.
import_validate_site() {
    local dir="$1"
    local setup prefix multi path version

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
    if [[ ! "$prefix" =~ ^[A-Za-z0-9_]{1,32}$ ]]; then
        echo "ERROR: the site's table prefix '${prefix:-<empty>}' (tables_prefix in $setup) is not a usable identifier" >&2
        return 1
    fi
    # A clone shares its database with another site under a second prefix
    # (KVS is_clone_db); the stack hosts one site per database.
    multi=$(import_read_php_config_value "$setup" tables_prefix_multi)
    if [ -n "$multi" ] && [ "$multi" != "$prefix" ]; then
        echo "ERROR: the site is a clone sharing the database of another site (tables_prefix_multi '$multi' differs from tables_prefix '$prefix'); import the site that owns the database" >&2
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
    printf '%s\t%s\t%s\t%s\n' "$version" "$path" "$prefix" "$(import_site_ioncube "$dir")"
}

# import_site_ioncube <site directory>: yes, no or unknown, from the
# signatures ionCube leaves at the top of admin/include/functions_base.php
# (the "<?php //0xxxxx" header, the loader check), the file every request
# loads first. The PHP image is built with or without the loader from it
# when no KVS archive says.
import_site_ioncube() {
    local file="$1/admin/include/functions_base.php"
    local head="" first=""

    if [ ! -r "$file" ]; then
        printf 'unknown'
        return 0
    fi
    IFS= read -r -N 4096 head < "$file" || true
    first=${head%%$'\n'*}
    if [[ "$first" =~ ^[[:space:]]*\<\?php[[:space:]]+//[0-9a-f]{5,6} ]] ||
        [[ "$head" == *"extension_loaded('ionCube Loader')"* ]] ||
        [[ "$head" == *_il_exec* ]]; then
        printf 'yes'
    else
        printf 'no'
    fi
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

# import_kv <file> <key>: the value of a key=value line, the first one.
# The values come from another server and end up on the terminal, so
# control characters (terminal escapes among them) are dropped.
import_kv() {
    local file="$1"
    local key="$2"

    sed -n "s/^${key}=//p" "$file" 2>/dev/null | head -n 1 | tr -d '\000-\037\177'
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
# One pass over the dump. Prints "<tables><TAB><initial version><TAB><database statements><TAB><completed>":
# the number of CREATE TABLE statements for the prefix, the INITIAL_VERSION
# value found in the options rows (empty when absent), the number of
# CREATE DATABASE or USE statements, which the prepared dump drops, and
# yes when the dump ends with the "Dump completed" line the dump tools
# write, no otherwise (a streamed dump that broke off has no such line).
import_inspect_dump() {
    local dump="$1"
    local prefix="$2"
    local tool

    if import_is_native_dump "$dump"; then
        if ! declare -F native_import_inspect >/dev/null; then
            echo "ERROR: native MariaDB import support is missing from this checkout" >&2
            return 1
        fi
        native_import_inspect "$dump" "$prefix"
        return $?
    fi

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
        BEGIN { tables = 0; initial = ""; statements = 0; completed = "no" }
        /^-- Dump completed/ { completed = "yes"; next }
        NF { completed = "no" }
        $0 ~ ("^CREATE TABLE `?" prefix) { tables++; next }
        /^(CREATE DATABASE|USE )/ { statements++; next }
        initial == "" && match($0, /\x27INITIAL_VERSION\x27[[:space:]]*,[[:space:]]*\x27[^\x27]*\x27/) {
            value = substr($0, RSTART, RLENGTH)
            sub(/^\x27INITIAL_VERSION\x27[[:space:]]*,[[:space:]]*\x27/, "", value)
            sub(/\x27$/, "", value)
            initial = value
        }
        END { printf "%d\t%s\t%d\t%s\n", tables, initial, statements, completed }
    '
}

import_is_native_dump() {
    case "$1" in
        *.mariadb.tar.zst|*.mariadb.tar.gz) return 0 ;;
        *) return 1 ;;
    esac
}

# The source must still be the file inspected by setup before its full scan
# can be reused. Include nanosecond timestamps and inode identity.
import_dump_identity() {
    stat -Lc '%d:%i:%s:%y:%z' -- "$1"
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

# import_innodb_row_format <-|file...>: drop ROW_FORMAT=FIXED from the
# InnoDB table definitions of a dump, on stdin (-) or in the files given.
# A MyISAM table converted to InnoDB on a server with innodb_strict_mode off
# keeps the clause in its definition, with a warning, and is DYNAMIC all
# the same; the MariaDB of the stack is strict and refuses to create it
# ("Wrong create options"), which stopped the import. MyISAM keeps it.
import_innodb_row_format() {
    local expression="s/^(\\) ENGINE=InnoDB( [^']*)?) ROW_FORMAT=FIXED/\\1/"

    if [ "$1" = - ]; then
        sed -E "$expression"
    else
        sed -E -i "$expression" "$@"
    fi
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
# .env), the GTID and binary log session settings a MySQL 8 mysqldump
# writes dropped (MariaDB knows no GTID_PURGED and would stop the replay
# there), INITIAL_VERSION added when the old site never recorded it, server
# paths rewritten to the container path, DEFINER clauses of views and
# triggers dropped (their user does not exist here), and a completion marker row
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

    inspection=${8:-}
    if [ -z "$inspection" ]; then
        inspection=$(import_inspect_dump "$dump" "$prefix") || return 1
    fi
    tables=$(import_field "$inspection" 1)
    initial=$(import_field "$inspection" 2)
    statements=$(import_field "$inspection" 3)
    if [ "${tables:-0}" -lt 1 ]; then
        echo "ERROR: $dump holds no CREATE TABLE for the ${prefix} tables" >&2
        return 1
    fi
    {
        # shellcheck disable=SC2016  # The backticks are SQL quoting inside the sed program.
        import_dump_cat "$dump" | sed -E '/^(CREATE DATABASE|USE )/d; /^SET @@(GLOBAL|SESSION)\.(GTID_PURGED|SQL_LOG_BIN)/d; /^INSERT /!s/DEFINER=`[^`]*`@`[^`]*`//g' |
            import_innodb_row_format -
        echo
        echo "-- kvs-install import"
        # --no-autocommit dumps can leave this session in manual commit mode.
        # Commit their final transaction and persist the adjustments and
        # completion marker below, including after the client disconnects.
        printf '\nSET autocommit=1;\n'
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

# import_marker_file <destination>
# The file that names the source a destination was filled from. It lives
# in IMPORT_MARKER_DIR when set (the setup keeps it out of the webroot),
# in the destination itself otherwise.
import_marker_file() {
    local destination="$1"

    if [ -n "${IMPORT_MARKER_DIR:-}" ]; then
        printf '%s/%s.source\n' "$IMPORT_MARKER_DIR" "$(basename -- "$destination")"
    else
        printf '%s/.kvs-import-source\n' "$destination"
    fi
}

# import_take_over_site <previous site directory> <destination> <source>
# A site imported earlier under another domain (a development subdomain
# tried before the real one) moves into place instead of travelling again:
# the directory is renamed, its source marker follows, and the transfer
# that comes next carries the changes only. The earlier import must come
# from the same source and the destination must hold nothing yet.
import_take_over_site() {
    local previous="${1%/}"
    local destination="${2%/}"
    local source="$3"
    local previous_marker marker resolved_previous resolved_destination recorded

    if [ ! -d "$previous" ]; then
        echo "ERROR: IMPORT_REUSE_SITE_DIR is not a directory: $previous" >&2
        return 1
    fi
    resolved_previous=$(readlink -f -- "$previous") || return 1
    resolved_destination=$(readlink -f -- "$destination" 2>/dev/null) || resolved_destination=$destination
    if [ "$resolved_previous" = "$resolved_destination" ]; then
        return 0
    fi
    previous_marker=$(import_marker_file "$previous")
    if [ ! -f "$previous_marker" ]; then
        echo "ERROR: $previous was not filled by an import (no source marker); IMPORT_REUSE_SITE_DIR takes over the files of an earlier import only" >&2
        return 1
    fi
    recorded=$(cat "$previous_marker")
    if [ "$recorded" != "$source" ]; then
        echo "ERROR: $previous was imported from $recorded, not from $source" >&2
        return 1
    fi
    if [ -e "$destination" ] && { [ ! -d "$destination" ] || find "$destination" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; }; then
        echo "ERROR: $destination already holds something; IMPORT_REUSE_SITE_DIR needs an absent or empty destination" >&2
        return 1
    fi
    marker=$(import_marker_file "$destination")
    if [ -d "$destination" ] && ! rmdir -- "$destination"; then
        return 1
    fi
    mkdir -p "$(dirname -- "$destination")" "$(dirname -- "$marker")" || return 1
    if ! mv -- "$previous" "$destination"; then
        echo "ERROR: could not move $previous to $destination (a mount point has to be moved by hand)" >&2
        return 1
    fi
    mv -f -- "$previous_marker" "$marker" || return 1
    echo "Site files of $previous taken over as $destination; the transfer carries the changes only"
}

# import_destination_ready <destination> <source marker>
# True when the destination is absent, empty, or was filled from the same
# source: the marker names the source from the first attempt on, so a run
# that failed later, or a second pass that picks up the changes on the old
# server, repeats without deleting the files by hand, while another site
# is never overwritten.
import_destination_ready() {
    local destination="$1"
    local source="$2"
    local marker

    marker=$(import_marker_file "$destination")
    if [ -e "$destination" ] && [ ! -d "$destination" ]; then
        echo "ERROR: $destination exists and is not a directory" >&2
        return 1
    fi
    if [ -d "$destination" ] && find "$destination" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        if [ -f "$marker" ] && [ "$(cat "$marker")" = "$source" ]; then
            return 0
        fi
        echo "ERROR: $destination is not empty; import into an empty site directory, or point IMPORT_SITE_DIR at it when the files are already there" >&2
        return 1
    fi
}

# import_mark_destination <destination> <source marker>
import_mark_destination() {
    local destination="$1"
    local source="$2"
    local marker

    marker=$(import_marker_file "$destination")
    mkdir -p "$destination" "$(dirname -- "$marker")" || return 1
    printf '%s\n' "$source" > "$marker"
}

# import_external_search_host <site directory>
# The host the KVS External Search plugin of a site calls when the plugin
# is enabled (a Sphinx or Manticore API on the old server), nothing when
# the plugin is absent or disabled. The plugin keeps its settings in a PHP
# serialized file; only the enable flag and the video API URL matter here.
import_external_search_host() {
    local file="$1/admin/data/plugins/external_search/data.dat"
    local url

    [ -f "$file" ] || return 1
    tr -d '\000' < "$file" | grep -q 's:22:"enable_external_search";i:1;' || return 1
    url=$(tr -d '\000' < "$file" | grep -o 's:8:"api_call";s:[0-9]*:"[^"]*"' | head -n 1 | sed 's/.*:"\([^"]*\)"$/\1/')
    import_url_domain "$url"
}

# import_place_site <source> <destination>
# Copy the site into the destination unless the source already is the
# destination. Ownership is left to the init container, which sets the
# whole tree to the PHP user.
# import_external_links <directory>
# The symbolic links of a site that lead outside it or nowhere, one per
# line as "<link> -> <target>". The container mounts the site directory
# alone, so such a link resolves there only once its target is copied in
# its place (what rsync does with --copy-unsafe-links) or mounted too.
import_external_links() {
    local dir="$1"
    local resolved link target

    resolved=$(readlink -f -- "$dir") || return 1
    find "$dir" -type l -print0 2>/dev/null | while IFS= read -r -d '' link; do
        target=$(readlink -e -- "$link" 2>/dev/null) || target=""
        case "$target" in
            "$resolved"/*) ;;
            "") printf '%s -> %s (dangling)\n' "${link#"$dir"/}" "$(readlink -- "$link")" ;;
            *) printf '%s -> %s\n' "${link#"$dir"/}" "$(readlink -- "$link")" ;;
        esac
    done
}

import_place_site() {
    local source="$1"
    local destination="$2"
    local resolved_source resolved_destination

    resolved_source=$(readlink -f -- "$source") || return 1
    resolved_destination=$(readlink -f -- "$destination" 2>/dev/null) || resolved_destination=$destination
    if [ "$resolved_source" = "$resolved_destination" ]; then
        echo "Site files already in place at $destination"
    else
        import_destination_ready "$destination" "$resolved_source" || return 1
        if [ -f "$(import_marker_file "$destination")" ]; then
            echo "Resuming the copy of $source into $destination"
        fi
        import_mark_destination "$destination" "$resolved_source" || return 1
        # Links leaving the site are copied with their targets, which only
        # rsync does.
        if [ -n "$(import_external_links "$resolved_source" | head -n 1)" ]; then
            import_ensure_tool rsync || return 1
        fi
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --copy-unsafe-links -- "$resolved_source/" "$destination/" || return 1
        else
            cp -a -- "$resolved_source/." "$destination/" || return 1
        fi
        echo "Site files copied from $source to $destination"
    fi
    rm -f "$destination/.kvs-extraction-in-progress"
}

# import_free_space_mb_ok <needed MB> <destination>
# True when the filesystem holding the destination (or its nearest existing
# parent) has room for that many megabytes, with a tenth of margin.
import_free_space_mb_ok() {
    local needed="$1"
    local destination="$2"
    local probe available

    probe=$destination
    while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
        probe=$(dirname -- "$probe")
    done
    available=$(df -Pm -- "$probe" 2>/dev/null | awk 'NR==2 {print $4}')
    [ -n "$needed" ] && [ -n "$available" ] || return 1
    [ "$available" -ge $(( needed + needed / 10 )) ]
}

# import_free_space_ok <source> <destination>: room for a copy of the source.
import_free_space_ok() {
    local source="$1"
    local destination="$2"
    local needed

    needed=$(du -sLm -- "$source" 2>/dev/null | awk '{print $1}')
    [ -n "$needed" ] || return 1
    import_free_space_mb_ok "$needed" "$destination"
}

#################################################################
# Archives: the site directory and the dump in one file
#################################################################

# import_archive_kind <file>: zip, 7z or tar from the name.
import_archive_kind() {
    case "${1,,}" in
        *.zip) echo zip ;;
        *.7z) echo 7z ;;
        *.tar|*.tar.gz|*.tgz|*.tar.zst|*.tzst|*.tar.xz|*.txz|*.tar.bz2|*.tbz2) echo tar ;;
        *) return 1 ;;
    esac
}

# import_compressor_for <file>: the decompressor a name implies, empty for none.
import_compressor_for() {
    case "${1,,}" in
        *.gz|*.tgz) echo gzip ;;
        *.zst|*.tzst) echo zstd ;;
        *.xz|*.txz) echo xz ;;
        *.bz2|*.tbz2) echo bzip2 ;;
        *) echo "" ;;
    esac
}

# import_tool_package <command>: the Debian package that provides a command.
import_tool_package() {
    case "$1" in
        unzip) echo unzip ;;
        7zz|7z|7za) echo 7zip ;;
        zstd) echo zstd ;;
        xz) echo xz-utils ;;
        bzip2) echo bzip2 ;;
        gzip) echo gzip ;;
        rsync) echo rsync ;;
        ssh) echo openssh-client ;;
        sshpass) echo sshpass ;;
        *) return 1 ;;
    esac
}

# import_apt_install <package>: quiet install, the index refreshed once when
# the first attempt fails. The last lines of apt's output explain a failure.
import_apt_install() {
    local package="$1"
    local output

    if ! command -v apt-get >/dev/null 2>&1; then
        echo "ERROR: apt-get is not available; install $package by hand and run the setup again" >&2
        return 1
    fi
    if output=$(DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$package" 2>&1); then
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null 2>&1 || true
    if output=$(DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$package" 2>&1); then
        return 0
    fi
    printf '%s\n' "$output" | tail -n 5 >&2
    return 1
}

# import_ensure_tool <command>: install the package of a command that is
# missing. Only the tool an input needs is installed.
import_ensure_tool() {
    local command="$1"
    local package

    command -v "$command" >/dev/null 2>&1 && return 0
    if ! package=$(import_tool_package "$command"); then
        echo "ERROR: $command is missing and no package is known for it" >&2
        return 1
    fi
    echo "Installing $package ($command is needed for this import)..." >&2
    if import_apt_install "$package" && command -v "$command" >/dev/null 2>&1; then
        return 0
    fi
    echo "ERROR: could not install $package; install it and run the setup again" >&2
    return 1
}

# import_7z_command: the 7-Zip command present, or installed for the
# occasion: 7zip on current releases, p7zip-full where only the older port
# exists.
import_7z_command() {
    local command

    for command in 7zz 7z 7za; do
        if command -v "$command" >/dev/null 2>&1; then
            echo "$command"
            return 0
        fi
    done
    echo "Installing 7zip (needed for this archive)..." >&2
    if ! import_apt_install 7zip && ! import_apt_install p7zip-full; then
        echo "ERROR: could not install 7zip or p7zip-full; install one and run the setup again" >&2
        return 1
    fi
    for command in 7zz 7z 7za; do
        if command -v "$command" >/dev/null 2>&1; then
            echo "$command"
            return 0
        fi
    done
    echo "ERROR: no 7-Zip command found after the installation" >&2
    return 1
}

# import_archive_tools <file>
# Make sure the tools an archive needs are present and print the command
# that extracts it (unzip, 7zz, 7z, 7za or tar).
import_archive_tools() {
    local file="$1"
    local kind compressor

    if ! kind=$(import_archive_kind "$file"); then
        echo "ERROR: unsupported archive $file (zip, 7z, tar, tar.gz, tar.zst, tar.xz and tar.bz2 are accepted)" >&2
        return 1
    fi
    case "$kind" in
        zip)
            import_ensure_tool unzip || return 1
            echo unzip
            ;;
        7z)
            import_7z_command
            ;;
        tar)
            compressor=$(import_compressor_for "$file")
            if [ -n "$compressor" ]; then
                import_ensure_tool "$compressor" || return 1
            fi
            echo tar
            ;;
    esac
}

# import_archive_report_failure <archive> <tool output file>
# Why an archive tool failed: a password, which the setup never asks for
# (the archive tools would wait on a prompt nobody sees, so their stdin is
# closed and 7-Zip gets an empty password), or the tool's own last lines.
import_archive_report_failure() {
    local file="$1"
    local output="$2"

    if grep -qiE 'password|encrypted' "$output"; then
        echo "ERROR: $file is password protected; the setup never asks for a password, extract it yourself and use IMPORT_SITE_DIR with IMPORT_DB_DUMP" >&2
    else
        tail -n 5 "$output" >&2
    fi
}

# import_archive_list <file> <command>
# One line per member: "<type><TAB><size><TAB><name>", type f, d or l (zip
# and 7z listings do not tell symlinks apart from files, tar does). Names
# are as stored, without a leading "./" or trailing "/".
import_archive_list() {
    local file="$1"
    local command="$2"
    local raw

    case "$command" in
        unzip)
            # The long listing is uniform whatever made the zip; zipinfo's
            # short format changes with the origin of the archive.
            LC_ALL=C unzip -l "$file" | awk '
                /^ *[0-9]+ +[0-9][0-9][0-9-]* +[0-9][0-9]:[0-9][0-9] +/ {
                    size = $1
                    match($0, / +[0-9][0-9][0-9-]* +[0-9][0-9]:[0-9][0-9] +/)
                    name = substr($0, RSTART + RLENGTH)
                    sub(/^\.\//, "", name)
                    if (name == "" || name == ".") next
                    if (name ~ /\/$/) { sub(/\/+$/, "", name); printf "d\t0\t%s\n", name }
                    else printf "f\t%s\t%s\n", size, name
                }'
            ;;
        7zz|7z|7za)
            raw=$(mktemp) || return 1
            if ! LC_ALL=C "$command" l -slt -p "$file" > "$raw" 2>&1 < /dev/null; then
                import_archive_report_failure "$file" "$raw"
                rm -f "$raw"
                return 1
            fi
            awk '
                function emit() {
                    if (path == "") return
                    sub(/^\.\//, "", path)
                    if (path == "" || path == ".") return
                    if (folder == "+" || attributes ~ /^D/) printf "d\t0\t%s\n", path
                    else printf "f\t%s\t%s\n", size + 0, path
                }
                BEGIN { started = 0; path = ""; size = 0; folder = "-"; attributes = "" }
                /^----------$/ { started = 1; next }
                !started { next }
                /^Path = / { emit(); path = substr($0, 8); size = 0; folder = "-"; attributes = ""; next }
                /^Size = / { size = substr($0, 8); next }
                /^Folder = / { folder = substr($0, 10); next }
                /^Attributes = / { attributes = substr($0, 14); next }
                END { emit() }' "$raw"
            rm -f "$raw"
            ;;
        tar)
            LC_ALL=C tar -tvf "$file" | awk '
                {
                    type = substr($1, 1, 1)
                    size = $3
                    name = $0
                    sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", name)
                    if (type == "l") sub(/ -> .*$/, "", name)
                    if (type == "h") { sub(/ link to .*$/, "", name); type = "f" }
                    if (type == "-") type = "f"
                    if (type != "f" && type != "d" && type != "l") type = "o"
                    sub(/^\.\//, "", name)
                    sub(/\/+$/, "", name)
                    if (name == "" || name == ".") next
                    if (type == "d") size = 0
                    printf "%s\t%s\t%s\n", type, size, name
                }'
            ;;
        *)
            echo "ERROR: unknown extraction command $command" >&2
            return 1
            ;;
    esac
}

# import_archive_analyze <listing file>
# Reads the lines of import_archive_list and prints
# "<site root><TAB><dump><TAB><manifest><TAB><MB><TAB><ignored>": the
# directory prefix that holds admin/include/setup.php (empty when the site
# is at the top, "dir/" or deeper otherwise), the dump member outside the
# site, the kvs-export.manifest member, the uncompressed size in megabytes
# and the other top-level entries, which are extracted into the staging
# directory but never reach the site (a readme, a saved vhost, listing
# junk). Refuses members that would escape the destination, more or less
# than one site and more or less than one dump.
import_archive_analyze() {
    local listing="$1"

    awk -F'\t' '
        function base(name,    n, parts) { n = split(name, parts, "/"); return parts[n] }
        function ancestor_of(dir, member) { return index(member, dir "/") == 1 }
        {
            type = $1; size = $2; name = $3
            if (name ~ /^\// || name == ".." || name ~ /^\.\.\// || name ~ /\/\.\.\// || name ~ /\/\.\.$/) {
                unsafe++
                if (unsafe_first == "") unsafe_first = name
                next
            }
            if (name ~ /^__MACOSX(\/|$)/ || base(name) == ".DS_Store" || base(name) == "Thumbs.db") next
            if (type == "f") total += size
            if (name ~ /(^|\/)admin\/include\/setup\.php$/) {
                roots++
                root = substr(name, 1, length(name) - length("admin/include/setup.php"))
            }
            count++
            names[count] = name
            types[count] = type
        }
        END {
            if (unsafe) {
                printf "ERROR: the archive holds %d member(s) with an absolute path or \"..\" (%s)\n", unsafe, unsafe_first > "/dev/stderr"
                exit 1
            }
            if (roots == 0) {
                print "ERROR: the archive holds no KVS site (admin/include/setup.php is missing)" > "/dev/stderr"
                exit 1
            }
            if (roots > 1) {
                printf "ERROR: the archive holds %d KVS sites; it must hold one\n", roots > "/dev/stderr"
                exit 1
            }
            dumps = 0; dump = ""; manifest = ""; extras = 0; extra_list = ""
            for (i = 1; i <= count; i++) {
                name = names[i]
                if (root != "" && index(name, root) == 1) continue
                if (root == "" && index(name, "/") > 0) continue
                if (name ~ /(\.sql(\.gz|\.xz|\.zst)?|\.mariadb\.tar\.(gz|zst))$/ && types[i] == "f") {
                    dumps++
                    if (dumps == 1) dump = name; else dump_list = dump_list ", " name
                    continue
                }
                if (name == "kvs-export.manifest" && types[i] == "f") { manifest = name; continue }
                if (root == "") continue
                if (types[i] == "d") {
                    keep = ancestor_of(name, root)
                    for (j = 1; j <= count; j++) {
                        if (names[j] ~ /(\.sql(\.gz|\.xz|\.zst)?|\.mariadb\.tar\.(gz|zst))$/ && types[j] == "f" && ancestor_of(name, names[j])) keep = 1
                    }
                    if (keep) continue
                }
                if (index(name, "/") > 0) continue
                extras++
                if (extras <= 5) extra_list = extra_list (extra_list == "" ? "" : ", ") name
            }
            if (dumps == 0) {
                print "ERROR: the archive holds no database dump (.sql, compressed SQL or .mariadb.tar.gz/.zst) next to the site" > "/dev/stderr"
                exit 1
            }
            if (dumps > 1) {
                printf "ERROR: the archive holds %d database dumps (%s%s); it must hold one\n", dumps, dump, dump_list > "/dev/stderr"
                exit 1
            }
            if (extras > 5) extra_list = extra_list ", ..."
            printf "%s\t%s\t%s\t%d\t%s\n", root, dump, manifest, (total + 1048575) / 1048576, extra_list
        }' "$listing"
}

# import_stage_dir_for <destination>
# Where an archive is unpacked before the site moves into the destination:
# a private directory next to the destination, on the same filesystem so
# the move is a rename, inside the destination when that one is a mount
# point of its own.
import_stage_dir_for() {
    local destination="$1"
    local resolved parent stage

    resolved=$(readlink -f -- "$destination" 2>/dev/null) || resolved=$destination
    parent=$(dirname -- "$resolved")
    stage="$parent/.kvs-import-$(basename -- "$resolved")"
    if [ -d "$resolved" ] && [ "$(stat -c %d -- "$resolved")" != "$(stat -c %d -- "$parent")" ]; then
        stage="$resolved/.kvs-import-stage"
    fi
    printf '%s\n' "$stage"
}

# import_archive_extract <file> <command> <destination>
# Extract the whole archive into the destination. unzip returns 1 for
# warnings after a complete extraction, which is not a failure.
import_archive_extract() {
    local file="$1"
    local command="$2"
    local destination="$3"
    local status=0 output

    mkdir -p "$destination" || return 1
    case "$command" in
        unzip)
            # unzip reports an exclusion that matched nothing as a caution;
            # its output only matters when the extraction failed.
            output=$(mktemp) || return 1
            unzip -q -o "$file" -x '__MACOSX/*' -d "$destination" > "$output" 2>&1 < /dev/null || status=$?
            if [ "$status" -gt 1 ]; then
                import_archive_report_failure "$file" "$output"
                rm -f "$output"
                return "$status"
            fi
            rm -f "$output"
            ;;
        7zz|7z|7za)
            output=$(mktemp) || return 1
            if ! "$command" x -y -bd -bso0 -p -o"$destination" "$file" > "$output" 2>&1 < /dev/null; then
                import_archive_report_failure "$file" "$output"
                rm -f "$output"
                return 1
            fi
            rm -f "$output"
            ;;
        tar)
            tar -xf "$file" --no-same-owner -C "$destination" < /dev/null || return 1
            ;;
        *)
            echo "ERROR: unknown extraction command $command" >&2
            return 1
            ;;
    esac
}

# import_archive_settle <stage> <site root> <dump> <manifest> <dump staging> <destination>
# After the extraction into the stage: the dump and the manifest go to the
# dump staging directory, the site's entries move into the destination
# (renames on the same filesystem; an entry already there from an earlier
# attempt is replaced), listing junk and anything else in the archive stay
# behind and go with the stage. Prints "<dump path><TAB><manifest path>".
import_archive_settle() {
    local stage="$1"
    local root="$2"
    local dump="$3"
    local manifest="$4"
    local staging="$5"
    local destination="$6"
    local dump_path="" manifest_path="" site entry name

    mkdir -p "$staging" "$destination" || return 1
    if [ -n "$dump" ]; then
        dump_path="$staging/$(basename -- "$dump")"
        mv -f -- "$stage/$dump" "$dump_path" || return 1
    fi
    if [ -n "$manifest" ]; then
        manifest_path="$staging/$(basename -- "$manifest")"
        mv -f -- "$stage/$manifest" "$manifest_path" || return 1
    fi
    site="$stage/$root"
    find "$site" -name .DS_Store -type f -delete 2>/dev/null || true
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        name=$(basename -- "$entry")
        rm -rf -- "${destination:?}/$name" || return 1
        mv -- "$entry" "$destination/" || return 1
    done < <(find "$site" -mindepth 1 -maxdepth 1 -print)
    rm -rf -- "$stage"
    printf '%s\t%s\n' "$dump_path" "$manifest_path"
}

# import_archive_peek <file> <command> <site root> <output directory>
# Extract only the site's configuration files (setup.php, setup_db.php
# and version.php, plus functions_base.php for the encoding when it is
# there) so the site can be validated before the whole archive is
# unpacked. zip and 7z find members through their index; tar reads until
# it has found them.
import_archive_peek() {
    local file="$1"
    local command="$2"
    local root="$3"
    local output="$4"
    local member target errors status

    mkdir -p "$output/admin/include" || return 1
    errors=$(mktemp) || return 1
    for member in setup.php setup_db.php version.php functions_base.php; do
        target="$output/admin/include/$member"
        status=0
        case "$command" in
            unzip)
                unzip -p "$file" "${root}admin/include/$member" > "$target" 2> "$errors" < /dev/null || status=$?
                ;;
            7zz|7z|7za)
                "$command" e -so -p "$file" "${root}admin/include/$member" > "$target" 2> "$errors" < /dev/null || status=$?
                ;;
            tar)
                # tar matches the stored name; an archive made from inside
                # its directory stores "./" in front of every member.
                tar -xOf "$file" --occurrence=1 "${root}admin/include/$member" > "$target" 2> "$errors" < /dev/null ||
                    tar -xOf "$file" --occurrence=1 "./${root}admin/include/$member" > "$target" 2> "$errors" < /dev/null || status=$?
                ;;
            *)
                status=1
                ;;
        esac
        if [ "$status" -ne 0 ] || [ ! -s "$target" ]; then
            if [ "$member" = functions_base.php ]; then
                # Only the encoding comes from it: an archive without it
                # is still a site, of unknown encoding.
                rm -f "$target"
                continue
            fi
            if grep -qiE 'password|encrypted' "$errors"; then
                import_archive_report_failure "$file" "$errors"
            fi
            rm -f "$errors"
            return 1
        fi
    done
    rm -f "$errors"
}

#################################################################
# The web server configuration of the old server
#################################################################

# import_nginx_config_save <report> <output file>
# The nginx configuration of the old server, as the exporter's detect (or
# the manifest of its archive) carries it, one nginx_config_N line each,
# written back as text for the operator's custom rules and for the KVS
# rewrite rules. Prints the number of lines; fails when the report
# carries none.
import_nginx_config_save() {
    local report="$1" output="$2" lines

    sed -n 's/^nginx_config_[0-9][0-9]*=//p' "$report" 2>/dev/null | tr -d '\000-\010\013-\037\177' > "$output.tmp" || {
        rm -f "$output.tmp"
        return 1
    }
    if [ ! -s "$output.tmp" ]; then
        rm -f "$output.tmp"
        return 1
    fi
    chmod 600 "$output.tmp"
    mv -f "$output.tmp" "$output" || return 1
    lines=$(wc -l < "$output")
    printf '%s\n' "${lines//[!0-9]/}"
}

# import_nginx_rewrites_from_config <configuration> <site directory> [project path] [source] [source host]
# Recover server-level rewrites only. Rules inside another context cannot be
# flattened without changing request routing. Parse the dumped files and follow
# includes in their calling context; reject ambiguous input without emitting a
# partial result. The explicit source mode also imports complete routing
# fragments included at server level and adapts their local PHP backends.
import_nginx_rewrites_from_config() {
    local config="$1" site="${2%/}" project="${3:-}" mode="${4:-plain}" source_host="${5:-}"

    project=${project%/}
    awk -v site="$site" -v project="$project" -v mode="$mode" -v source_host="${source_host,,}" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        function unquote(s,    q) {
            q = substr(s, 1, 1)
            if ((q == "\"" || q == sprintf("%c", 39)) && substr(s, length(s), 1) == q)
                return substr(s, 2, length(s) - 2)
            return s
        }
        function serves_site(r) {
            sub(/\/$/, "", r)
            return r == site || (project != "" && r == project) || index(r, site "/") == 1 || (project != "" && index(r, project "/") == 1)
        }
        function describe_failure(f, id, reason) {
            if (failure == "") failure = (f == "" ? "<configuration>" : f) ":" node_line[f, id] ": " reason
        }
        function reject(f, id, reason) {
            unsafe = 1
            describe_failure(f, id, reason)
        }
        function node(f, s, kind, line_number,    id, name) {
            id = ++nodes[f]
            name = s
            sub(/[[:space:]].*$/, "", name)
            command[f, id] = unquote(name)
            argument[f, id] = trim(substr(s, length(name) + 1))
            raw[f, id] = s
            ending[f, id] = kind
            node_line[f, id] = line_number
            if (kind == "}") {
                if (s != "" || depth < 1) invalid = 1
                else closing[f, stack[depth--]] = id
            } else {
                if (s == "" || (kind == "{" && command[f, id] ~ /^(rewrite|root|include)$/)) invalid = 1
                if (kind == "{") stack[++depth] = id
            }
        }
        # Token boundaries follow nginx quoting, escaping and comments. A brace
        # in a quoted regex or in ${variable} is part of a word, not a block.
        function tokenize(f,    text, i, c, s, quote, escaped, comment, space, after_quote, line_number, first_line) {
            text = content[f]
            depth = 0
            space = 1
            line_number = 1
            for (i = 1; i <= length(text); i++) {
                c = substr(text, i, 1)
                if (c == "\n") line_number++
                if (comment) {
                    if (c != "\n") continue
                    comment = 0
                }
                if (escaped) { s = s c; escaped = 0; space = 0; continue }
                if (c == "\\") { s = s c; escaped = 1; space = 0; continue }
                if (quote != "") {
                    s = s c
                    if (c == quote) { quote = ""; after_quote = 1 }
                    continue
                }
                if (after_quote) {
                    if (c !~ /[[:space:];{)]/) invalid = 1
                    after_quote = 0
                }
                if (c == "#" && space) { comment = 1; continue }
                if (!first_line && c !~ /[[:space:]]/) first_line = line_number
                if ((c == "\"" || c == sprintf("%c", 39)) && space) {
                    quote = c; s = s c; space = 0; continue
                }
                if (c == "{" && !space && substr(s, length(s), 1) == "$") {
                    s = s c; continue
                }
                if (c == ";" || c == "{" || (c == "}" && space)) {
                    node(f, trim(s), c, first_line ? first_line : line_number)
                    s = ""; space = 1
                    first_line = 0
                    continue
                }
                if (c ~ /[[:space:]]/) {
                    if (!space) s = s " "
                    space = 1
                } else { s = s c; space = 0 }
            }
            if (quote != "" || escaped || trim(s) != "" || depth != 0) invalid = 1
        }
        # Match only dumped files. Never read source paths on the destination.
        function glob_regex(g,    re, i, c) {
            re = ""
            for (i = 1; i <= length(g); i++) {
                c = substr(g, i, 1)
                if (c == "*") re = re "[^/]*"
                else if (c == "?") re = re "[^/]"
                else if (c ~ /[.+(){}^$|\\]/) re = re "\\" c
                else re = re c
            }
            return re
        }
        function files_named(pattern, level,    n, i, j, re, value) {
            n = 0
            # Dynamic or escaped include paths cannot be resolved reliably.
            if (pattern ~ /[$\\]/) return 0
            if (mode == "source" && (index(pattern, "[") || index(pattern, "]"))) return 0
            re = "^" glob_regex(pattern ~ /^\// ? pattern : prefix "/" pattern) "$"
            for (i = 1; i <= nfiles; i++) if (files[i] ~ re) found[level, ++n] = files[i]
            if (n == 0 && pattern !~ /^\//) {
                re = "/" glob_regex(pattern) "$"
                for (i = 1; i <= nfiles; i++) if (files[i] ~ re) found[level, ++n] = files[i]
            }
            if (mode == "source" && n > 1 && !index(pattern, "*") && !index(pattern, "?")) return 0
            # nginx expands include globs in filename order.
            for (i = 2; i <= n; i++) {
                value = found[level, i]
                j = i - 1
                while (j > 0 && found[level, j] > value) {
                    found[level, j + 1] = found[level, j]; j--
                }
                found[level, j + 1] = value
            }
            return n
        }
        # Only an entire server-context routing fragment can be carried across.
        # A vhost or a general-purpose include is traversed for smaller fragments.
        function fragment_file(f, level,    result) {
            if (level > 32 || checking[f]) return 0
            checking[f] = 1
            result = fragment_nodes(f, level)
            delete checking[f]
            return result
        }
        function fragment_nodes(f, level,    i, name, kind, n, k, key) {
            key = "check" level
            for (i = 1; i <= nodes[f]; i++) {
                name = command[f, i]; kind = ending[f, i]
                if (kind == "{") {
                    if (name !~ /^(location|if)$/) return 0
                    i = closing[f, i]
                } else if (name == "include") {
                    n = files_named(unquote(argument[f, i]), key)
                    if (!n) return 0
                    for (k = 1; k <= n; k++) if (!fragment_file(found[key, k], level + 1)) return 0
                } else if (name == "access_log" && argument[f, i] != "off") return 0
                else if (name !~ /^(rewrite|set|return|break|error_page|add_header|expires|default_type|index|try_files|deny|allow|log_not_found|recursive_error_pages|access_log|auth_request|auth_request_set)$/) return 0
            }
            return 1
        }
        # Render complete blocks, including sibling handlers and access controls.
        # Expand dependencies from the dump, never from the destination filesystem.
        function render(f, first, last, indent, level, location_uri,    out, i, name, arg, kind, line, pad, n, k, key, child, backend, child_uri) {
            if (level > 32) { reject(f, first, "routing nesting exceeds the supported depth"); return "" }
            key = "render" level
            pad = sprintf("%*s", indent * 4, "")
            for (i = first; i <= last; i++) {
                name = command[f, i]; arg = argument[f, i]; kind = ending[f, i]
                line = raw[f, i]
                if (name == "include" && kind == ";") {
                    n = files_named(unquote(arg), key)
                    if (!n) reject(f, i, "include cannot be resolved from the source dump")
                    for (k = 1; k <= n; k++) {
                        child = found[key, k]
                        if (rendering[child]) { reject(f, i, "cyclic include"); continue }
                        rendering[child] = 1
                        out = out render(child, 1, nodes[child], indent, level + 1, location_uri)
                        delete rendering[child]
                    }
                    continue
                }
                if (kind == "{") {
                    if (name !~ /^(location|if)$/) { reject(f, i, "unsupported routing block: " name); return "" }
                    if (name == "location" && unquote(arg) == "/") reject(f, i, "root location conflicts with the destination vhost")
                    child_uri = location_uri
                    if (name == "location") {
                        child_uri = ""
                        if (arg ~ /^=[[:space:]]+/) {
                            child_uri = arg
                            sub(/^=[[:space:]]+/, "", child_uri)
                            child_uri = unquote(child_uri)
                            exact_locations[server_key, child_uri]++
                        }
                    }
                    out = out pad line " {\n" render(f, i + 1, closing[f, i] - 1, indent + 1, level + 1, child_uri) pad "}\n"
                    i = closing[f, i]
                    continue
                }
                if (name == "auth_request") {
                    backend = unquote(arg)
                    if (backend != "off") {
                        if (backend !~ /^\/[^[:space:]?$\\#]+$/) reject(f, i, "auth_request requires a literal local URI")
                        auth_uri[++auth_count] = backend
                        auth_file[auth_count] = f
                        auth_node[auth_count] = i
                    }
                } else if (name == "internal") {
                    if (location_uri != "") internal_locations[server_key, location_uri] = 1
                } else if (name == "fastcgi_pass") {
                    backend = unquote(arg)
                    if (backend !~ /^unix:[^[:space:]]*php[^[:space:]]*\.sock$/ &&
                        backend !~ /^(127\.0\.0\.1|localhost|\[::1\]|php-fpm):9000$/) reject(f, i, "fastcgi_pass is not a supported local PHP backend")
                    line = "fastcgi_pass php-fpm:9000"
                } else if (name == "fastcgi_param") {
                    if (arg ~ /^SCRIPT_FILENAME[[:space:]]+["\047]?\//) reject(f, i, "absolute SCRIPT_FILENAME requires an explicit path adaptation")
                } else if (name == "set" && arg ~ /^\$base[[:space:]]/) {
                    backend = arg
                    sub(/^\$base[[:space:]]+/, "", backend)
                    if (!serves_site(unquote(backend))) reject(f, i, "base path does not match the imported site")
                    line = "set $base /var/www/kvs"
                } else if (name == "access_log") {
                    if (arg != "off") reject(f, i, "access_log depends on source-specific logging")
                } else if (name !~ /^(rewrite|set|return|break|error_page|add_header|expires|default_type|index|try_files|deny|allow|log_not_found|recursive_error_pages|auth_request_set|fastcgi_index|fastcgi_read_timeout|fastcgi_send_timeout|fastcgi_connect_timeout|fastcgi_buffering|fastcgi_buffer_size|fastcgi_buffers|fastcgi_request_buffering|fastcgi_pass_request_body|fastcgi_pass_request_headers|fastcgi_intercept_errors|fastcgi_keep_conn|fastcgi_hide_header)$/) reject(f, i, "unsupported routing directive: " name)
                if (name == "rewrite") routing++
                out = out pad line ";\n"
            }
            return out
        }
        function collect(f, first, last, context, level,    i, name, arg, kind, n, k, child, rendered, base_path, names, parts, hostname) {
            if (level > 32) { reject(f, first, "include nesting exceeds the supported depth"); return }
            for (i = first; i <= last; i++) {
                name = command[f, i]; arg = argument[f, i]; kind = ending[f, i]
                if (name == "include" && kind == ";") {
                    n = files_named(unquote(arg), level)
                    if (!n) reject(f, i, "include cannot be resolved from the source dump")
                    for (k = 1; k <= n; k++) {
                        child = found[level, k]
                        if (active[child]) { reject(f, i, "cyclic include"); continue }
                        active[child] = 1
                        if (mode == "source" && context == 0 && fragment_file(child, 0)) {
                            rendering[child] = 1
                            rendered = render(child, 1, nodes[child], 0, 0)
                            delete rendering[child]
                            if (rendered != "") rules[++count] = rendered
                        } else collect(child, 1, nodes[child], context, level + 1)
                        delete active[child]
                    }
                } else if (kind == "{") {
                    if (name == "if" && context == 0) {
                        control = 1
                        describe_failure(f, i, "inline server-level if requires a complete routing fragment")
                    }
                    collect(f, i + 1, closing[f, i] - 1, context + 1, level + 1)
                    i = closing[f, i]
                } else if (name == "server_name" && context == 0) {
                    parts = split(arg, names, /[[:space:]]+/)
                    for (k = 1; k <= parts; k++) {
                        hostname = tolower(unquote(names[k]))
                        sub(/\.$/, "", hostname)
                        if (hostname == source_host || hostname == "www." source_host) host_matches = 1
                        else if (hostname ~ /^[a-z0-9][a-z0-9.-]*$/) other_host = 1
                        else any_host = 1
                    }
                } else if (name == "root" && context == 0 && serves_site(unquote(arg))) {
                    qualifies = 1
                } else if (mode == "source" && context == 0 && name == "root" && arg == "$base") {
                    uses_base = 1
                } else if (name == "rewrite") {
                    if (context != 0) reject(f, i, "nested rewrite requires its complete routing context")
                    routing++
                    rules[++count] = raw[f, i] ";"
                } else if (mode == "source" && context == 0 && name == "error_page") {
                    rules[++count] = raw[f, i] ";"
                } else if (mode == "source" && context == 0 && name ~ /^(auth_request|auth_request_set)$/) {
                    rules[++count] = render(f, i, i, 0, 0)
                } else if (name ~ /^(auth_request|auth_request_set)$/) {
                    control = 1
                    describe_failure(f, i, "authorization requires its complete routing context")
                } else if (mode == "source" && context == 0 && name == "set" && arg ~ /^\$base[[:space:]]/) {
                    base_path = arg
                    sub(/^\$base[[:space:]]+/, "", base_path)
                    if (serves_site(unquote(base_path))) base_matches = 1
                    else {
                        control = 1
                        describe_failure(f, i, "base path does not match the imported site")
                    }
                } else if (context == 0 && name ~ /^(set|return|break)$/) {
                    control = 1
                    describe_failure(f, i, "server-level " name " requires a complete routing fragment")
                }
            }
        }
        /^# configuration file .*:$/ {
            current = substr($0, 22, length($0) - 22)
            if (!(current in content)) {
                files[++nfiles] = current
                content[current] = ""
                if (nfiles == 1) {
                    prefix = current
                    sub(/\/[^\/]*$/, "", prefix)
                }
            }
            next
        }
        { content[current] = content[current] $0 "\n" }
        END {
            if (trim(content[""]) != "") files[++nfiles] = ""
            for (file_index = 1; file_index <= nfiles; file_index++) tokenize(files[file_index])
            if (invalid) {
                print "ERROR: nginx configuration syntax cannot be recovered safely; use IMPORT_NGINX_REWRITES." > "/dev/stderr"
                exit 1
            }
            # Whether a vhost named after the site serves its files: a vhost of
            # another host sharing them (a CDN origin) is then left out below.
            if (mode != "source" && source_host != "") {
                for (file_index = 1; file_index <= nfiles; file_index++) {
                    f = files[file_index]
                    for (entry = 1; entry <= nodes[f]; entry++) {
                        if (command[f, entry] != "server" || ending[f, entry] != "{" || argument[f, entry] != "") continue
                        qualifies = 0; host_matches = 0
                        active[f] = 1
                        collect(f, entry + 1, closing[f, entry] - 1, 0, 0)
                        delete active[f]
                        if (qualifies && host_matches) site_served = 1
                    }
                }
            }
            for (file_index = 1; file_index <= nfiles; file_index++) {
                f = files[file_index]
                for (entry = 1; entry <= nodes[f]; entry++) {
                    if (command[f, entry] != "server" || ending[f, entry] != "{" || argument[f, entry] != "") continue
                    qualifies = 0; unsafe = 0; control = 0; count = 0; routing = 0; uses_base = 0; base_matches = 0; host_matches = 0; failure = ""
                    other_host = 0; any_host = 0
                    server_key = f SUBSEP entry
                    auth_count = 0
                    active[f] = 1
                    collect(f, entry + 1, closing[f, entry] - 1, 0, 0)
                    delete active[f]
                    if (!qualifies && !(mode == "source" && uses_base && base_matches)) continue
                    # A CDN or development vhost can share the same filesystem.
                    # Never import its routing into the original public host. A
                    # catch-all, wildcard or regex name, or a site no vhost is
                    # named after, keeps the plain mode as it was.
                    if (source_host != "" && !host_matches && (mode == "source" || (site_served && other_host && !any_host))) continue
                    matched_servers++
                    if (mode == "source" && !routing) continue
                    # An omitted authorization endpoint might hit the destination
                    # front controller and return 200, accidentally granting access.
                    for (auth_index = 1; auth_index <= auth_count; auth_index++) {
                        if (exact_locations[server_key, auth_uri[auth_index]] != 1 || !internal_locations[server_key, auth_uri[auth_index]])
                            reject(auth_file[auth_index], auth_node[auth_index], "auth_request requires an imported exact internal location")
                    }
                    if (unsafe || (control && count > 0)) {
                        if (failure != "") print "ERROR: " failure > "/dev/stderr"
                        print "ERROR: nginx recovery requires a complete compatible routing fragment; set IMPORT_NGINX_REWRITES to a prepared file." > "/dev/stderr"
                        exit 1
                    }
                    if (mode == "source") {
                        candidate = ""
                        for (rule_index = 1; rule_index <= count; rule_index++) candidate = candidate rules[rule_index] "\n"
                        if (source_result != "" && source_result != candidate) {
                            print "ERROR: matching nginx servers use different routing rules; provide IMPORT_NGINX_REWRITES as a prepared file." > "/dev/stderr"
                            exit 1
                        }
                        source_result = candidate
                        continue
                    }
                    for (rule_index = 1; rule_index <= count; rule_index++) {
                        if (!seen[rules[rule_index]]++) output[++total] = rules[rule_index]
                    }
                }
            }
            if (mode == "source" && source_host != "" && !matched_servers) {
                print "ERROR: no exact source server_name with a matching site root; provide IMPORT_NGINX_REWRITES as a prepared file." > "/dev/stderr"
                exit 1
            }
            if (mode == "source") printf "%s", source_result
            else for (rule_index = 1; rule_index <= total; rule_index++) print output[rule_index]
        }' "$config"
}

#################################################################
# The old server over SSH
#################################################################

IMPORT_SSH_TARGET=""
IMPORT_SSH_OPTS=()
# ssh, or sshpass in front of it when the old server takes a password.
IMPORT_SSH_COMMAND=(ssh)
# shellcheck disable=SC2034  # Read by docker/setup.sh.
IMPORT_REMOTE_PRIVILEGES=none
IMPORT_REMOTE_SUDO_ERROR=""
IMPORT_REMOTE_SUDO=no
IMPORT_REMOTE_PREFIX=()

# import_remote_path_ok <path>: paths travel through the remote shell and
# through rsync, so they are limited to characters no shell interprets.
import_remote_path_ok() {
    case "$1" in
        /*) [[ "$1" =~ ^[A-Za-z0-9._/@+,:=-]+$ ]] ;;
        *) return 1 ;;
    esac
}

# import_remote_path_check <path>: the same check, with the refusal
# explained. The path is not always typed by the operator: the detection
# on the old server can answer with a directory the transfer refuses.
import_remote_path_check() {
    import_remote_path_ok "$1" && return 0
    echo "ERROR: the remote site directory must be an absolute path without spaces or shell characters: '$1'" >&2
    return 1
}

# import_ssh_setup <host> <port> <user> <identity file> <batch yes|no> <accept new host keys yes|no> [password]
# One multiplexed connection for the whole import: a password is typed
# once on ssh's own prompt, never read by the setup, and every later
# command and the file transfer reuse the connection. Batch mode makes a
# headless run fail at once instead of waiting on a prompt nobody sees.
# An unknown host key is shown and confirmed by ssh itself unless the
# caller opted into accepting it: the first connection is the one where
# the old server's password travels. A password given to the setup
# (IMPORT_REMOTE_PASSWORD, for runs nobody attends) is handed to sshpass
# through its environment, never on a command line.
import_ssh_setup() {
    local host="$1"
    local port="${2:-22}"
    local user="${3:-root}"
    local key="$4"
    local batch="${5:-no}"
    local accept_new="${6:-no}"
    local password="${7:-}"
    local control_dir="${IMPORT_SSH_CONTROL_DIR:-/run/kvs-install}"

    if [ -z "$host" ] || [[ "$host" =~ [[:space:]] ]]; then
        echo "ERROR: invalid SSH host: '$host'" >&2
        return 1
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "ERROR: invalid SSH port: '$port'" >&2
        return 1
    fi
    if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: invalid SSH user: '$user'" >&2
        return 1
    fi
    if [ -n "$key" ] && [ ! -r "$key" ]; then
        echo "ERROR: the SSH key $key is not readable" >&2
        return 1
    fi
    mkdir -p "$control_dir" && chmod 700 "$control_dir" || return 1
    IMPORT_SSH_TARGET="${user}@${host}"
    IMPORT_SSH_OPTS=(
        -o ControlMaster=auto
        -o "ControlPath=$control_dir/ssh-%C"
        -o ControlPersist=15m
        -o ServerAliveInterval=30
        -o ConnectTimeout=20
        -p "$port"
    )
    IMPORT_SSH_COMMAND=(ssh)
    if [ -n "$password" ]; then
        # sshpass answers ssh's password prompt from SSHPASS, so ssh's
        # prompts must stay (no batch mode, one attempt), and the host key
        # of a server not in known_hosts yet is accepted on this first
        # connection: the answer an operator gives on ssh's question,
        # which sshpass cannot relay.
        import_ensure_tool sshpass || return 1
        SSHPASS=$password
        export SSHPASS
        IMPORT_SSH_COMMAND=(sshpass -e ssh)
        IMPORT_SSH_OPTS+=(-o NumberOfPasswordPrompts=1)
        batch=no
        accept_new=yes
    fi
    if [ "$batch" = yes ]; then
        IMPORT_SSH_OPTS+=(-o BatchMode=yes)
    fi
    if [ "$accept_new" = yes ]; then
        IMPORT_SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
    fi
    if [ -n "$key" ]; then
        IMPORT_SSH_OPTS+=(-i "$key" -o IdentitiesOnly=yes)
    fi
}

# import_ssh <command...>: run a command on the old server.
import_ssh() {
    # shellcheck disable=SC2029  # The arguments are meant for the remote shell.
    "${IMPORT_SSH_COMMAND[@]}" "${IMPORT_SSH_OPTS[@]}" "$IMPORT_SSH_TARGET" "$@"
}

# import_ssh_close: end the multiplexed connection.
import_ssh_close() {
    [ -n "$IMPORT_SSH_TARGET" ] || return 0
    "${IMPORT_SSH_COMMAND[@]}" "${IMPORT_SSH_OPTS[@]}" -O exit "$IMPORT_SSH_TARGET" >/dev/null 2>&1 || true
}

# import_remote_privileges: what the SSH user may do on the old server.
# Sets IMPORT_REMOTE_PRIVILEGES to root, sudo (passwordless) or none (with
# sudo's last word in IMPORT_REMOTE_SUDO_ERROR: a password required, a tty
# required), and the prefix the remote commands and rsync run with. This
# is the first command on the connection: with a password, ssh asks for it
# here and the multiplexed connection keeps it for the rest of the import.
# shellcheck disable=SC2034  # The privilege variables are read by docker/setup.sh.
import_remote_privileges() {
    local uid

    IMPORT_REMOTE_PRIVILEGES=none
    IMPORT_REMOTE_SUDO_ERROR=""
    IMPORT_REMOTE_SUDO=no
    IMPORT_REMOTE_PREFIX=()
    uid=$(import_ssh id -u < /dev/null) || return 1
    uid=${uid//[!0-9]/}
    if [ "$uid" = 0 ]; then
        IMPORT_REMOTE_PRIVILEGES=root
        return 0
    fi
    if IMPORT_REMOTE_SUDO_ERROR=$(import_ssh sudo -n true < /dev/null 2>&1 >/dev/null); then
        IMPORT_REMOTE_PRIVILEGES=sudo
        IMPORT_REMOTE_SUDO=yes
        IMPORT_REMOTE_PREFIX=(sudo -n)
        IMPORT_REMOTE_SUDO_ERROR=""
    else
        IMPORT_REMOTE_SUDO_ERROR=$(printf '%s' "$IMPORT_REMOTE_SUDO_ERROR" | tr -d '\000-\037\177' | tail -c 120)
    fi
}

# import_ssh_rsh: the remote shell command for rsync, one string. rsync
# splits it on spaces and honours quotes, so an option holding a space
# (a key path) is single-quoted.
import_ssh_rsh() {
    local option result="${IMPORT_SSH_COMMAND[*]}"

    for option in "$@" "${IMPORT_SSH_OPTS[@]}"; do
        case "$option" in
            *[[:space:]\'\"]*) result="$result '${option//\'/\'\'}'" ;;
            *) result="$result $option" ;;
        esac
    done
    printf '%s' "$result"
}

# import_mb_text <megabytes>: a size for a summary line.
import_mb_text() {
    local mb="$1"

    [[ "$mb" =~ ^[0-9]+$ ]] || { echo "?"; return 0; }
    if [ "$mb" -lt 1024 ]; then
        echo "$mb MB"
    elif [ "$mb" -lt 1048576 ]; then
        echo "$((mb / 1024)).$(((mb * 10 / 1024) % 10)) GB"
    else
        echo "$((mb / 1048576)).$(((mb * 10 / 1048576) % 10)) TB"
    fi
}

# import_remote_paths_ok <space separated paths>
# Paths for the exporter's --exclude and --include: plain, relative to the
# site directory, no .. component, only characters that survive the
# command line the old server's shell splits.
import_remote_paths_ok() {
    local item

    for item in $1; do
        [[ "$item" =~ ^[A-Za-z0-9._@%+,=-][A-Za-z0-9._@%+,=/-]*$ ]] || return 1
        [[ "$item" != ".." && "$item" != ../* && "$item" != */.. && "$item" != */../* ]] || return 1
    done
    return 0
}

# import_remote_detect <exporter script> <site directory or empty> <output file> [size budget] [excluded paths] [included paths]
# Run the exporter's detection on the old server; the script travels on
# stdin, nothing is written there. The key=value report lands in the
# output file. The budget is how many seconds the exporter may spend
# measuring the site size (0: all of it); past it the report carries a
# lower bound and the filesystem usage. The paths, space separated and
# relative to the site directory, are what the transfer leaves behind on
# top of what the exporter leaves on its own, and what it takes along
# after all.
import_remote_detect() {
    local exporter="$1"
    local dir="$2"
    local output="$3"
    local budget="${4:-}"
    local excludes="${5:-}"
    local includes="${6:-}"
    local item
    local -a options=()

    if [ -n "$dir" ]; then
        import_remote_path_check "$dir" || return 1
    fi
    if [ -n "$budget" ]; then
        options=(--size-timeout "$budget")
    fi
    if [ -n "${IMPORT_DATABASE_FORMAT:-}" ]; then
        options+=(--database-format "$IMPORT_DATABASE_FORMAT")
    fi
    if [ -n "$excludes$includes" ] && ! import_remote_paths_ok "$excludes $includes"; then
        echo "ERROR: the paths to leave behind or take along must be plain paths relative to the site directory, space separated: '$excludes $includes'" >&2
        return 1
    fi
    for item in $excludes; do
        options+=(--exclude "$item")
    done
    for item in $includes; do
        options+=(--include "$item")
    done
    if [ -n "$dir" ]; then
        import_ssh "${IMPORT_REMOTE_PREFIX[@]}" bash -s -- "${options[@]}" detect "$dir" < "$exporter" > "$output"
    else
        import_ssh "${IMPORT_REMOTE_PREFIX[@]}" bash -s -- "${options[@]}" detect < "$exporter" > "$output"
    fi
}

# import_remote_dump <exporter script> <site directory> <output file>
# Stream the compressed dump from the old server into the output file.
import_remote_dump() {
    local exporter="$1"
    local dir="$2"
    local output="$3"
    local -a options=()

    import_remote_path_check "$dir" || return 1
    if [ -n "${IMPORT_REMOTE_DATABASE_FORMAT:-}" ]; then
        options+=(--database-format "$IMPORT_REMOTE_DATABASE_FORMAT")
    fi
    import_ssh "${IMPORT_REMOTE_PREFIX[@]}" bash -s -- "${options[@]}" dump "$dir" < "$exporter" > "$output"
}

#################################################################
# Transfer progress
#################################################################

# import_bytes_text <bytes>: a size for a summary line, in the units of
# import_mb_text; below a megabyte, in kilobytes.
import_bytes_text() {
    local bytes="$1"

    [[ "$bytes" =~ ^[0-9]+$ ]] || { echo "?"; return 0; }
    if [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024)) kB"
    else
        import_mb_text "$((bytes / 1048576))"
    fi
}

# import_count_text <number>: thousands separated, for a summary line.
import_count_text() {
    local n="$1" out=""

    [[ "$n" =~ ^[0-9]+$ ]] || { echo "?"; return 0; }
    while [ "${#n}" -gt 3 ]; do
        out=",${n: -3}$out"
        n=${n:0:${#n}-3}
    done
    echo "$n$out"
}

# import_rsync_stats_totals: reads the --stats block of an rsync dry run
# and prints "<files>\t<bytes>\t<site files>\t<site bytes>": what the
# transfer moves (regular files and their size) and what the site
# holds. Prints nothing without the two transfer figures.
import_rsync_stats_totals() {
    awk '
        function number(s) { gsub(/[^0-9]/, "", s); return s + 0 }
        /^Number of files: / {
            site_files = number($4)
            if (match($0, /reg: [0-9,.]+/)) site_files = number(substr($0, RSTART + 5, RLENGTH - 5))
        }
        /^Number of (regular )?files transferred: / { files = number($NF); have_files = 1 }
        /^Total file size: / { site_bytes = number($4) }
        /^Total transferred file size: / { bytes = number($5); have_bytes = 1 }
        END { if (have_files && have_bytes) printf "%.0f\t%.0f\t%.0f\t%.0f\n", files, bytes, site_files, site_bytes }
    '
}

# import_rsync_totals <rsync arguments...>
# The dry run of the transfer, its statistics reduced by
# import_rsync_stats_totals: a scan of the old server without a byte
# moved, its memory bounded by the incremental recursion as for the
# transfer itself. An optional count gets IMPORT_SIZE_TIMEOUT seconds
# (300; 0 for no limit). A parallel worker plan must scan the whole tree:
# truncating it would leave all undiscovered files to the single final
# mirror. Prints nothing when rsync gave no statistics; returns 124 when
# the optional count ran out of time.
import_rsync_totals() {
    local budget="${IMPORT_SIZE_TIMEOUT:-300}"
    local -a listing=() statuses=()

    [[ "$budget" =~ ^[0-9]+$ ]] || budget=300
    if [ -n "${IMPORT_RSYNC_PLAN:-}" ]; then
        budget=0
        listing=(--out-format='KVS-PLAN %i %l %n')
    fi
    # --foreground keeps the scan in the process group of the setup, the one
    # Ctrl-C reaches: timeout otherwise moves itself, rsync and ssh into a
    # group of their own, and the setup waited for the whole scan of the
    # old server, minutes on a large site, before it stopped.
    LC_ALL=C timeout --foreground "$budget" rsync --dry-run --stats "${listing[@]}" "$@" 2>"${IMPORT_RSYNC_COUNT_ERROR:-/dev/null}" |
        import_rsync_plan "${IMPORT_RSYNC_PLAN:-}" "${IMPORT_TRANSFER_JOBS:-4}" |
        import_rsync_stats_totals
    statuses=("${PIPESTATUS[@]}")
    [ "${statuses[1]}" -eq 0 ] || return "${statuses[1]}"
    [ "${statuses[2]}" -eq 0 ] || return "${statuses[2]}"
    return "${statuses[0]}"
}

# Split only the regular files needing data, using rsync's own exclusions
# and link traversal. Decode its documented octal filename escapes in the
# C locale, then write NUL-delimited lists. Each shard keeps traversal order
# and balances bytes plus a per-file cost without retaining names in RAM.
import_rsync_plan() {
    LC_ALL=C awk -v directory="$1" -v jobs="$2" '
        function decode(s,    result, code) {
            result = ""
            while (match(s, /\\#[0-7][0-7][0-7]/)) {
                code = substr(s, RSTART + 2, 1) * 64 + substr(s, RSTART + 3, 1) * 8 + substr(s, RSTART + 4, 1)
                result = result substr(s, 1, RSTART - 1) sprintf("%c", code)
                s = substr(s, RSTART + 5)
            }
            return result s
        }
        directory != "" && /^KVS-PLAN (<|>)f[^ ]* [0-9]+ / {
            size = $3 + 0
            name = $0
            sub(/^KVS-PLAN [^ ]+ [0-9]+ /, "", name)
            name = decode(name)
            if (name == "" || name ~ /^\// || name ~ /(^|\/)\.\.(\/|$)/) exit 1
            worker = 1
            for (i = 2; i <= jobs; i++) if (weight[i] + 0 < weight[worker] + 0) worker = i
            printf "./%s%c", name, 0 > (directory "/" worker ".list")
            weight[worker] += size + 65536
            files++
            bytes += size
            if (systime() - reported >= 10) {
                printf "  Planning parallel transfer: %.0f files to copy, %.2f GiB discovered; scan running.\n", files, bytes / 1073741824 > "/dev/stderr"
                fflush("/dev/stderr")
                reported = systime()
            }
            next
        }
        !/^KVS-PLAN / { print }
    '
}

# import_remote_plan_upload <plan directory> <jobs>
# rsync relays a --files-from list read on this side to the sender on the
# old server, and that relay grows with the square of the list: with the
# rsync of Debian 13, 50,000 names kept one worker from copying anything
# for 30 s where the same list read on the old server took 3 s, and the
# 2.6 million names of each of four workers on a site of ten million
# files held the transfer at 0 B for hours. Copies the worker lists to a
# new private directory of the old server, where each worker reads its
# own, and prints that directory.
import_remote_plan_upload() {
    local plan="$1" jobs="$2" remote worker

    # shellcheck disable=SC2016  # TMPDIR is the old server's.
    remote=$(import_ssh 'umask 077 && mktemp -d "${TMPDIR:-/var/tmp}/kvs-import-plan.XXXXXX"' < /dev/null 2>/dev/null) || return 1
    [[ "$remote" =~ ^/[A-Za-z0-9._/-]+/kvs-import-plan\.[A-Za-z0-9]+$ ]] || return 1
    for ((worker = 1; worker <= jobs; worker++)); do
        [ -s "$plan/$worker.list" ] || continue
        if ! import_ssh "cat > '$remote/$worker.list'" < "$plan/$worker.list" 2>/dev/null; then
            import_remote_plan_remove "$remote"
            return 1
        fi
    done
    printf '%s\n' "$remote"
}

# import_remote_plan_remove <directory>: the directory
# import_remote_plan_upload made on the old server goes, and nothing else.
import_remote_plan_remove() {
    [[ "$1" =~ ^/[A-Za-z0-9._/-]+/kvs-import-plan\.[A-Za-z0-9]+$ ]] || return 0
    import_ssh "rm -rf -- '$1'" < /dev/null > /dev/null 2>&1 || true
}

# A separate process group per rsync lets interruption stop its SSH child
# as well. Logs stay private; a bounded tail of each supplies one aggregate
# progress record per second to the existing progress renderer. With
# IMPORT_RSYNC_REMOTE_PLAN, each worker reads its list in that directory of
# the old server instead of having rsync relay it.
import_rsync_workers() (
    local plan="$1" jobs="$2" rsh="$3"
    shift 3
    local worker pid active result=0 status bytes files snapshot arg remote_program=rsync files_from
    local error_dir="${IMPORT_TRANSFER_LOG_DIR:-$plan}"
    local -a pids=() logs=() rsync_args=()
    # Keep the PID returned by $! as the session/process-group leader even
    # when a caller enabled shell job control (otherwise setsid may fork).
    set +m
    for arg in "$@"; do
        case "$arg" in
            --delete) ;;
            --rsync-path=*)
                remote_program=${arg#*=}
                [ "${IMPORT_RSYNC_SERIAL_AUTH:-no}" = yes ] || rsync_args+=("$arg")
                ;;
            *) rsync_args+=("$arg") ;;
        esac
    done
    if [ "${IMPORT_RSYNC_SERIAL_AUTH:-no}" = yes ]; then
        # This stderr marker comes from the remote shell after SSH has
        # authenticated, before rsync starts. Wait for it before opening
        # the next connection: established transfers remain concurrent,
        # but our unauthenticated connections never pile up at MaxStartups.
        rsync_args+=(--rsync-path="printf '%s\\n' KVS_IMPORT_SSH_READY >&2; exec $remote_program")
    fi
    trap 'for pid in "${pids[@]}"; do [ -z "$pid" ] || kill -TERM -- "-$pid" 2>/dev/null || true; done; wait' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    for ((worker = 1; worker <= jobs; worker++)); do
        [ -s "$plan/$worker.list" ] || continue
        logs+=("$plan/$worker.log")
        # --force permits a planned file to replace an obsolete nonempty
        # directory. It does not enable mirroring/deletion of sibling files.
        # A live site can remove a file after the plan was built. Missing
        # --files-from entries otherwise return 23 instead of vanished-file
        # status 24. The final whole-site pass still reconciles these paths.
        # Open both logs in the parent before forking. Redirections on the
        # background command itself run in the child, so readiness polling
        # can otherwise reach grep before the diagnostics file exists.
        files_from="$plan/$worker.list"
        if [ -n "${IMPORT_RSYNC_REMOTE_PLAN:-}" ]; then
            files_from=":$IMPORT_RSYNC_REMOTE_PLAN/$worker.list"
        fi
        if ! {
            setsid rsync "${rsync_args[@]}" --force --no-recursive --dirs --from0 \
                --ignore-missing-args --files-from="$files_from" -e "$rsh" --info=progress2 --outbuf=L \
                < /dev/null &
            pids[worker]=$!
        } > "$plan/$worker.log" 2> "$error_dir/$worker.err"; then
            echo "ERROR: could not open logs for transfer worker $worker" >&2
            return 1
        fi
        if [ "${IMPORT_RSYNC_SERIAL_AUTH:-no}" = yes ]; then
            while kill -0 "${pids[worker]}" 2>/dev/null &&
                ! grep -Fxq KVS_IMPORT_SSH_READY "$error_dir/$worker.err"; do
                sleep 0.05
            done
            if ! grep -Fxq KVS_IMPORT_SSH_READY "$error_dir/$worker.err"; then
                status=0
                wait "${pids[worker]}" || status=$?
                pids[worker]=""
                cat "$error_dir/$worker.err" >&2
                [ "$status" -ne 0 ] || status=1
                printf '%s\n' "$status" > "$error_dir/$worker.status"
                echo "ERROR: transfer worker $worker ended before SSH was ready (status $status)" >&2
                return "$status"
            fi
        fi
    done
    while :; do
        active=0
        for worker in "${!pids[@]}"; do
            pid=${pids[worker]}
            [ -n "$pid" ] || continue
            if kill -0 "$pid" 2>/dev/null; then
                active=$((active + 1))
            else
                status=0
                wait "$pid" || status=$?
                pids[worker]=""
                printf '%s\n' "$status" > "$error_dir/$worker.status"
                sed '/^KVS_IMPORT_SSH_READY$/d' "$error_dir/$worker.err" >&2
                case "$status" in
                    0) ;;
                    24) [ "$result" -ne 0 ] || result=24 ;;
                    *) echo "ERROR: transfer worker $worker failed (rsync status $status)" >&2; return "$status" ;;
                esac
            fi
        done
        snapshot=$(
            for worker in "${logs[@]}"; do
                tail -c 8192 "$worker" | LC_ALL=C awk '
                    BEGIN { RS = "\r|\n" }
                    /^ *[0-9][0-9,.]* +[0-9]+% / {
                        b = $1; gsub(/[,.]/, "", b)
                        if (match($0, /xfr#[0-9]+/)) f = substr($0, RSTART + 4, RLENGTH - 4)
                    }
                    END { printf "%.0f %.0f\n", b, f }
                '
            done | awk '{ bytes += $1; files += $2 } END { printf "%.0f %.0f\n", bytes, files }'
        )
        read -r bytes files <<< "$snapshot"
        printf ' %s 0%% 0.00B/s 0:00:00 (xfr#%s)\n' "$bytes" "$files"
        [ "$active" -gt 0 ] || break
        sleep 1
    done
    return "$result"
)

# import_rsync_progress <bytes to transfer> <files to transfer> [terminal yes|no]
# Reads the output of rsync --info=progress2 and shows the transfer
# against the totals of its dry run: bytes and files done out of the
# whole and the time left that follows the slower of the two, since the
# tail of a site is many small files where the bytes hardly move while
# the files go by; then the rates of the last twenty seconds, the
# entries rsync has checked of those its scan has found (a repeat of a
# large site spends most of its time there, moving nothing), and the
# time elapsed. Two lines rewritten in place on a terminal, one line
# every ten seconds otherwise (a log); no time left before five seconds
# have passed, the first rate says little. Without totals the counts
# show alone. Whatever else rsync prints passes through. rsync's own
# figures mislead here: the line it prints when a file completes carries
# the time elapsed and the average rate, not an estimate (its code
# switches to them on that line), and its percentage is relative to the
# files the scan has found so far. Use seconds from systime(), supported
# by Debian mawk and gawk. A random seed is not a portable timestamp.
import_rsync_progress() {
    local total_bytes="${1:-0}" total_files="${2:-0}" terminal="${3:-}"
    local -a awk_options=()

    if [ -z "$terminal" ]; then
        if [ -t 1 ]; then terminal=yes; else terminal=no; fi
    fi
    # mawk otherwise waits for a full input buffer. Its interactive mode
    # requires newline records, so normalize rsync carriage returns first.
    if awk -W version 2>&1 | grep -q '^mawk '; then awk_options=(-W interactive); fi
    stdbuf -o0 tr '\r' '\n' | awk "${awk_options[@]}" -v total_bytes="$total_bytes" -v total_files="$total_files" -v terminal="$terminal" '
        function now() { return systime() }
        function commas(n,    s, r) {
            s = sprintf("%.0f", int(n))
            r = ""
            while (length(s) > 3) {
                r = "," substr(s, length(s) - 2) r
                s = substr(s, 1, length(s) - 3)
            }
            return s r
        }
        function size(b) {
            if (b >= 1073741824) return sprintf("%.2f GB", b / 1073741824)
            if (b >= 1048576) return sprintf("%.1f MB", b / 1048576)
            if (b >= 1024) return sprintf("%.0f kB", b / 1024)
            return sprintf("%d B", b)
        }
        function clock(s,    h, m) {
            s = int(s + 0.5)
            h = int(s / 3600)
            m = int((s % 3600) / 60)
            return sprintf("%d:%02d:%02d", h, m, s % 60)
        }
        # Once a second on a terminal, every ten seconds otherwise, and at
        # the end. The rates are those of the last twenty seconds (the
        # average since the start before that); the time left is the longer
        # of the two they give.
        function report(final,    t, elapsed, i, o, byte_rate, file_rate, check_rate, checked, left, left_files, first, second, pct) {
            t = now()
            if (!final) {
                if (terminal == "yes" && t == shown) return
                if (terminal != "yes" && t - shown < 10) return
            }
            shown = t
            elapsed = t - start
            if (elapsed < 0) elapsed = 0
            checked = found - to_check
            seen_bytes[t] = bytes
            seen_files[t] = files
            seen_checked[t] = checked
            for (i in seen_bytes) if (i < t - 20 || i > t) {
                delete seen_bytes[i]
                delete seen_files[i]
                delete seen_checked[i]
            }
            o = -1
            for (i = t - 20; i < t; i++) if (i in seen_bytes) { o = i; break }
            if (o >= 0) {
                byte_rate = (bytes - seen_bytes[o]) / (t - o)
                file_rate = (files - seen_files[o]) / (t - o)
                check_rate = (checked - seen_checked[o]) / (t - o)
            } else if (elapsed > 0) {
                byte_rate = bytes / elapsed
                file_rate = files / elapsed
                check_rate = checked / elapsed
            } else {
                byte_rate = 0
                file_rate = 0
                check_rate = 0
            }
            if (check_rate < 0) check_rate = 0
            if (final) {
                if (elapsed > 0) {
                    byte_rate = bytes / elapsed
                    file_rate = files / elapsed
                }
                first = sprintf("  Transferred %s files, %s in %s (%s/s, %s files/s)", commas(files), size(bytes), clock(elapsed), size(byte_rate), commas(file_rate))
                if (found > 0) first = first sprintf("; %s entries checked", commas(checked))
                if (terminal == "yes") {
                    if (drawn) printf "\r\033[1A"
                    printf "%s\033[K\n\033[K", first
                } else {
                    printf "%s\n", first
                }
                fflush()
                return
            }
            if (total_bytes > 0 || total_files > 0) {
                left = -1
                if (total_bytes > bytes && byte_rate > 0) left = (total_bytes - bytes) / byte_rate
                if (total_files > files && file_rate > 0) {
                    left_files = (total_files - files) / file_rate
                    if (left_files > left) left = left_files
                }
                if (elapsed < 5) left = -1
                if (total_bytes > 0) pct = 100 * bytes / total_bytes
                else pct = 100 * files / total_files
                if (pct > 100) pct = 100
                first = sprintf("  %s of %s (%d%%), %s of %s files, %s left", size(bytes), size(total_bytes), pct, commas(files), commas(total_files), (left < 0 ? "?" : clock(left)))
            } else {
                first = sprintf("  %s, %s files", size(bytes), commas(files))
            }
            if (found > 0) {
                second = sprintf("  Copy: %s/s, %s files/s; check: %s entries/s, %s of %s discovered entries checked, scan %s, %s elapsed", size(byte_rate), commas(file_rate), (elapsed > 0 ? commas(check_rate) : "?"), commas(checked), commas(found), (scan_done ? "done" : "running"), clock(elapsed))
            } else {
                second = sprintf("  Copy: %s/s, %s files/s, %s elapsed", size(byte_rate), commas(file_rate), clock(elapsed))
            }
            if (terminal == "yes") {
                if (drawn) printf "\r\033[1A"
                printf "%s\033[K\n%s\033[K", first, second
                drawn = 1
            } else {
                printf "%s, %s\n", first, substr(second, 3)
            }
            fflush()
        }
        BEGIN { start = now(); shown = -100; bytes = 0; files = 0; found = 0; to_check = 0; scan_done = 0; drawn = 0 }
        /^ *[0-9][0-9,.]* +[0-9]+% +[0-9.]+[kMGT]?B\/s +[0-9]+:[0-9][0-9]:[0-9][0-9]/ {
            b = $1
            gsub(/[,.]/, "", b)
            bytes = b + 0
            if (match($0, /xfr#[0-9]+/)) files = substr($0, RSTART + 4, RLENGTH - 4) + 0
            if (match($0, /chk=[0-9]+\/[0-9]+/)) {
                split(substr($0, RSTART + 4, RLENGTH - 4), chk, "/")
                to_check = chk[1] + 0
                found = chk[2] + 0
                scan_done = ($0 ~ /to-chk=/)
            }
            report(0)
            next
        }
        /^[[:space:]]*$/ { next }
        {
            if (terminal == "yes" && drawn) {
                printf "\r\033[1A\033[K\n\033[K\r\033[1A"
                drawn = 0
            }
            print
            fflush()
        }
        END { report(1) }
    '
}

# import_remote_files <site directory> <destination> <rsync yes|no> [patterns...]
# Mirror the site files. rsync when both sides have it (resumable through
# the partial directory, a repeat only transfers the changes), a tar
# stream otherwise. The transfer is counted first, a dry run, and shown
# against that count by import_rsync_progress. Counting and the final
# mirror use incremental recursion. Parallel workers take disjoint lists
# from a complete count, stored on disk, and only handle their listed files. The
# patterns are the exporter's exclude_N lines, anchored at the site
# directory (/tmp/*, /backup): what stays behind. rsync takes them as they
# are; the tar on the old server gets them under its ./ prefix, which
# anchors them too, quoted for the shell that splits its command line.
# Symbolic links that leave the site (a contents directory on another
# disk) come as their targets, since the container only mounts the site;
# links inside it stay links. Files that vanish during the transfer are
# what a live site does and not a failure; files rsync could not read or
# links pointing nowhere are.
import_remote_files() (
    local dir="$1"
    local destination="$2"
    local use_rsync="$3"
    local status=0
    local pattern totals count_status files=0 bytes=0 site_files site_bytes
    local jobs="${IMPORT_TRANSFER_JOBS:-4}" worker_rsh worker_auth=no plan="" work error_dir remote_plan="" rsync_host
    local -a independent=(-o ControlMaster=no -o ControlPath=none -o Compression=no)
    local -a rsync_path=()
    local -a rsync_args=()
    local -a transfer_status=()
    local -a patterns=("${@:4}")
    local -a rsync_excludes=()
    local -a tar_excludes=()

    if [[ ! "$jobs" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]]; then
        echo "ERROR: IMPORT_TRANSFER_JOBS must be an integer from 1 to 32" >&2
        return 1
    fi
    import_remote_path_check "$dir" || return 1
    mkdir -p "$destination" || return 1
    for pattern in "${patterns[@]}"; do
        case "$pattern" in
            /*) ;;
            *)
                echo "ERROR: an exclusion pattern must start at the site directory, got '$pattern'" >&2
                return 1
                ;;
        esac
        rsync_excludes+=("--exclude=$pattern")
        tar_excludes+=("'--exclude=.$pattern'")
    done
    if [ "$use_rsync" = yes ]; then
        work=$(mktemp -d) || return 1
        trap 'rm -rf -- "$work"; import_remote_plan_remove "$remote_plan"' EXIT
        error_dir=${IMPORT_TRANSFER_LOG_DIR:-$work}
        # The caller owns the private persistent directory when diagnostics
        # must survive a failure; file lists and progress logs stay temporary.
        [ -d "$error_dir" ] || return 1
        umask 077
        if [ "$IMPORT_REMOTE_SUDO" = yes ]; then
            rsync_path=(--rsync-path="sudo -n rsync")
        fi
        # rsync reads host:path up to the first colon, so an IPv6 address
        # goes in brackets; ssh takes it without them.
        rsync_host=$IMPORT_SSH_TARGET
        case "$rsync_host" in
            *@*:*) rsync_host="${rsync_host%%@*}@[${rsync_host#*@}]" ;;
        esac
        # -H keeps a file linked under several names as one file: copied
        # once per name it would take more room than the site measured
        # and the free space checked. The plan leaves the other names of
        # a group to the final mirror, which links them without data.
        rsync_args=(-a -H -s --copy-unsafe-links --partial-dir=.rsync-partial --delete --no-human-readable
            "${rsync_excludes[@]}" "${rsync_path[@]}" -e "$(import_ssh_rsh)" "$rsync_host:$dir/" "$destination/")
        if [ "$jobs" -gt 1 ] && command -v setsid >/dev/null 2>&1; then
            plan=$work
        elif [ "$jobs" -gt 1 ]; then
            echo "  setsid is unavailable; using one transfer worker."
        fi
        if [ -n "$plan" ]; then
            echo "  Planning all files for $jobs parallel workers (complete scan; no size-count timeout)..."
        else
            echo "  Counting what the transfer moves (a scan of the old server, at most ${IMPORT_SIZE_TIMEOUT:-300} s)..."
        fi
        count_status=0
        totals=$(IMPORT_RSYNC_PLAN="$plan" IMPORT_RSYNC_COUNT_ERROR="$error_dir/count.err" import_rsync_totals "${rsync_args[@]}") || count_status=$?
        printf '%s\n' "$count_status" > "$error_dir/count.status"
        if [ -n "$plan" ]; then
            case "$count_status" in
                0|24) ;;
                *)
                    cat "$error_dir/count.err" >&2
                    echo "ERROR: parallel transfer planning failed (status $count_status); no partial plan or final mirror was started" >&2
                    return "$count_status"
                    ;;
            esac
        fi
        if [ -n "$totals" ]; then
            IFS=$'\t' read -r files bytes site_files site_bytes <<< "$totals"
            if [ "$files" -eq 0 ] && [ "$bytes" -eq 0 ]; then
                echo "  To transfer:     nothing, the site's $(import_count_text "$site_files") files ($(import_bytes_text "$site_bytes")) are already here; rsync checks them"
            else
                echo "  To transfer:     $(import_count_text "$files") files, $(import_bytes_text "$bytes") of the site's $(import_count_text "$site_files") files, $(import_bytes_text "$site_bytes")"
            fi
        elif [ "$count_status" -eq 124 ]; then
            echo "  The count did not finish in time (IMPORT_SIZE_TIMEOUT=${IMPORT_SIZE_TIMEOUT:-300}, 0 for no limit): the transfer shows its counts without a whole"
        fi
        if [ -n "$plan" ] && [ -s "$plan/1.list" ]; then
            # New SSH connections spread encryption across cores. A password
            # typed into the original master cannot be replayed unattended:
            # probe without prompts, then reuse that master when necessary.
            if [ "${IMPORT_SSH_COMMAND[0]}" != sshpass ]; then
                independent+=(-o BatchMode=yes)
            fi
            if "${IMPORT_SSH_COMMAND[@]}" "${independent[@]}" "${IMPORT_SSH_OPTS[@]}" "$IMPORT_SSH_TARGET" true < /dev/null 2>/dev/null; then
                worker_rsh=$(import_ssh_rsh "${independent[@]}")
                worker_auth=yes
                echo "  Transferring with up to $jobs workers on separate SSH connections."
            else
                # OpenSSH normally allows ten sessions per master. Refuse
                # a larger shared pool instead of dropping planned shards.
                worker_rsh=$(import_ssh_rsh)
                if [ "$jobs" -gt 8 ]; then
                    echo "ERROR: separate SSH authentication is unavailable; set IMPORT_TRANSFER_JOBS to 8 or less, or provide a key or IMPORT_REMOTE_PASSWORD" >&2
                    return 1
                fi
                echo "  Transferring with up to $jobs workers sharing the authenticated SSH connection."
            fi
            if remote_plan=$(import_remote_plan_upload "$plan" "$jobs"); then
                echo "  Worker lists copied to $remote_plan on the old server, where each worker reads its own."
            else
                remote_plan=""
                echo "  The worker lists could not be copied to the old server; rsync relays them, which delays the first copies on a large site."
            fi
            IMPORT_RSYNC_REMOTE_PLAN="$remote_plan" IMPORT_RSYNC_SERIAL_AUTH="$worker_auth" \
                import_rsync_workers "$plan" "$jobs" "$worker_rsh" "${rsync_args[@]}" |
                import_rsync_progress "$bytes" "$files"
            transfer_status=("${PIPESTATUS[@]}")
            import_remote_plan_remove "$remote_plan"
            remote_plan=""
            printf 'rsync=%s progress=%s\n' "${transfer_status[@]}" > "$error_dir/parallel.status"
            if [ "${transfer_status[1]}" -ne 0 ]; then
                echo "ERROR: parallel transfer progress failed (status ${transfer_status[1]})" >&2
                return "${transfer_status[1]}"
            fi
            status=${transfer_status[0]}
            case "$status" in
                0|24) ;;
                *) echo "ERROR: parallel file transfer failed (status $status)" >&2; return "$status" ;;
            esac
            echo "  Checking the whole site with one rsync, catching new changes and applying deletions..."
            # Workers never delete and never recurse into each other's lists.
            # This ordinary mirror restores directory metadata and links,
            # catches changes since planning, and removes stale files.
            bytes=0
            files=0
        fi
        rsync "${rsync_args[@]}" --info=progress2 2> "$error_dir/final-rsync.err" | import_rsync_progress "$bytes" "$files"
        transfer_status=("${PIPESTATUS[@]}")
        printf 'rsync=%s progress=%s\n' "${transfer_status[@]}" > "$error_dir/final.status"
        cat "$error_dir/final-rsync.err" >&2
        if [ "${transfer_status[1]}" -ne 0 ]; then
            echo "ERROR: final transfer progress failed (status ${transfer_status[1]})" >&2
            return "${transfer_status[1]}"
        fi
        status=${transfer_status[0]}
        case "$status" in
            24)
                echo "  Some files vanished on the old server during the transfer, as a live site does; the next pass carries what is left." >&2
                status=0
                ;;
            23)
                echo "ERROR: rsync completed only part of the transfer (status 23); see the errors above, fix the reported cause and run the same command again" >&2
                ;;
            0) ;;
            *) echo "ERROR: final rsync synchronization failed (status $status); see the errors above" >&2 ;;
        esac
        return "$status"
    fi
    # The pipeline answers for the local tar alone; the status of the tar
    # on the old server is read from the pipeline itself, since the setup
    # runs without pipefail. 1 is what a live site does (files changed or
    # removed while they were read), anything else is a file it could not
    # read or a connection that broke.
    local -a pipe_status=()
    import_ssh "${IMPORT_REMOTE_PREFIX[@]}" tar -C "$dir" "${tar_excludes[@]}" -chf - . | tar -xf - --no-same-owner -C "$destination"
    pipe_status=("${PIPESTATUS[@]}")
    case "${pipe_status[0]}" in
        0) ;;
        1)
            echo "  Some files changed or vanished on the old server during the transfer, as a live site does; the next pass carries what is left." >&2
            ;;
        *)
            echo "ERROR: the tar stream from $IMPORT_SSH_TARGET ended with status ${pipe_status[0]} (see the messages above): files unreadable by $IMPORT_SSH_TARGET, or the connection broke; fix them on the old server and run the same command again" >&2
            return 1
            ;;
    esac
    if [ "${pipe_status[1]}" -ne 0 ]; then
        echo "ERROR: the tar stream from $IMPORT_SSH_TARGET could not be unpacked into $destination (see the messages above)" >&2
        return "${pipe_status[1]}"
    fi
)

# import_watch_file_size <file> <pid> <label>
# Print the growing size of a file every few seconds while a process
# runs, on one line, so a long transfer shows it is alive. The cursor goes
# back to the start of that line after each redraw: a message the process
# prints meanwhile (the old server's "Dumping ...") covers the size and
# keeps its own line instead of following it ("Received 0 MBDumping ...").
import_watch_file_size() {
    local file="$1"
    local pid="$2"
    local label="$3"
    local size

    while kill -0 "$pid" 2>/dev/null; do
        size=$(du -m -- "$file" 2>/dev/null | awk '{print $1}')
        printf '\033[K  %s %s MB\r' "$label" "${size:-0}"
        sleep 3
    done
    printf '\033[K'
}
