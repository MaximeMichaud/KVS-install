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
    printf '%s\t%s\t%s\n' "$version" "$path" "$prefix"
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

    inspection=$(import_inspect_dump "$dump" "$prefix") || return 1
    tables=$(import_field "$inspection" 1)
    initial=$(import_field "$inspection" 2)
    statements=$(import_field "$inspection" 3)
    if [ "${tables:-0}" -lt 1 ]; then
        echo "ERROR: $dump holds no CREATE TABLE for the ${prefix} tables" >&2
        return 1
    fi
    {
        # shellcheck disable=SC2016  # The backticks are SQL quoting inside the sed program.
        import_dump_cat "$dump" | sed -E '/^(CREATE DATABASE|USE )/d; /^SET @@(GLOBAL|SESSION)\.(GTID_PURGED|SQL_LOG_BIN)/d; /^INSERT /!s/DEFINER=`[^`]*`@`[^`]*`//g'
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
                if (name ~ /\.sql(\.gz|\.xz|\.zst)?$/ && types[i] == "f") {
                    dumps++
                    if (dumps == 1) dump = name; else dump_list = dump_list ", " name
                    continue
                }
                if (name == "kvs-export.manifest" && types[i] == "f") { manifest = name; continue }
                if (root == "") continue
                if (types[i] == "d") {
                    keep = ancestor_of(name, root)
                    for (j = 1; j <= count; j++) {
                        if (names[j] ~ /\.sql(\.gz|\.xz|\.zst)?$/ && types[j] == "f" && ancestor_of(name, names[j])) keep = 1
                    }
                    if (keep) continue
                }
                if (index(name, "/") > 0) continue
                extras++
                if (extras <= 5) extra_list = extra_list (extra_list == "" ? "" : ", ") name
            }
            if (dumps == 0) {
                print "ERROR: the archive holds no database dump (.sql, .sql.gz, .sql.xz or .sql.zst) next to the site" > "/dev/stderr"
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
# and version.php) so the site can be validated before the whole archive
# is unpacked. zip and 7z find members through their index; tar reads
# until it has found them.
import_archive_peek() {
    local file="$1"
    local command="$2"
    local root="$3"
    local output="$4"
    local member target errors status

    mkdir -p "$output/admin/include" || return 1
    errors=$(mktemp) || return 1
    for member in setup.php setup_db.php version.php; do
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
# The old server over SSH
#################################################################

IMPORT_SSH_TARGET=""
IMPORT_SSH_OPTS=()
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

# import_ssh_setup <host> <port> <user> <identity file> <batch yes|no> <accept new host keys yes|no>
# One multiplexed connection for the whole import: a password is typed
# once on ssh's own prompt, never read by the setup, and every later
# command and the file transfer reuse the connection. Batch mode makes a
# headless run fail at once instead of waiting on a prompt nobody sees.
# An unknown host key is shown and confirmed by ssh itself unless the
# caller opted into accepting it: the first connection is the one where
# the old server's password travels.
import_ssh_setup() {
    local host="$1"
    local port="${2:-22}"
    local user="${3:-root}"
    local key="$4"
    local batch="${5:-no}"
    local accept_new="${6:-no}"
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
    ssh "${IMPORT_SSH_OPTS[@]}" "$IMPORT_SSH_TARGET" "$@"
}

# import_ssh_close: end the multiplexed connection.
import_ssh_close() {
    [ -n "$IMPORT_SSH_TARGET" ] || return 0
    ssh "${IMPORT_SSH_OPTS[@]}" -O exit "$IMPORT_SSH_TARGET" >/dev/null 2>&1 || true
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
    local option result="ssh"

    for option in "${IMPORT_SSH_OPTS[@]}"; do
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

    import_remote_path_check "$dir" || return 1
    import_ssh "${IMPORT_REMOTE_PREFIX[@]}" bash -s -- dump "$dir" < "$exporter" > "$output"
}

# import_remote_files <site directory> <destination> <rsync yes|no> [patterns...]
# Mirror the site files. rsync when both sides have it (resumable through
# the partial directory, shows progress, a repeat only transfers the
# changes), a tar stream otherwise. The incremental recursion stays on: a
# full scan before the first byte holds the whole file list in memory on
# both sides, which a small server cannot afford for a large site. The
# patterns are the exporter's exclude_N lines, anchored at the site
# directory (/tmp/*, /backup): what stays behind. rsync takes them as they
# are; the tar on the old server gets them under its ./ prefix, which
# anchors them too, quoted for the shell that splits its command line.
# Symbolic links that leave the site (a contents directory on another
# disk) come as their targets, since the container only mounts the site;
# links inside it stay links. Files that vanish during the transfer are
# what a live site does and not a failure; files rsync could not read or
# links pointing nowhere are.
import_remote_files() {
    local dir="$1"
    local destination="$2"
    local use_rsync="$3"
    local status=0
    local pattern
    local -a rsync_path=()
    local -a patterns=("${@:4}")
    local -a rsync_excludes=()
    local -a tar_excludes=()

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
        if [ "$IMPORT_REMOTE_SUDO" = yes ]; then
            rsync_path=(--rsync-path="sudo -n rsync")
        fi
        rsync -a -s --copy-unsafe-links --partial-dir=.rsync-partial --delete --info=progress2 --human-readable \
            "${rsync_excludes[@]}" "${rsync_path[@]}" -e "$(import_ssh_rsh)" "$IMPORT_SSH_TARGET:$dir/" "$destination/" || status=$?
        case "$status" in
            24)
                echo "  Some files vanished on the old server during the transfer, as a live site does; the next pass carries what is left." >&2
                status=0
                ;;
            23)
                echo "ERROR: rsync could not transfer some files (listed above): unreadable by $IMPORT_SSH_TARGET, or symbolic links pointing nowhere; fix them on the old server and run the same command again" >&2
                ;;
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
}

# import_watch_file_size <file> <pid> <label>
# Print the growing size of a file every few seconds while a process
# runs, on one line, so a long transfer shows it is alive.
import_watch_file_size() {
    local file="$1"
    local pid="$2"
    local label="$3"
    local size

    while kill -0 "$pid" 2>/dev/null; do
        size=$(du -m -- "$file" 2>/dev/null | awk '{print $1}')
        printf '\r  %s %s MB' "$label" "${size:-0}"
        sleep 3
    done
    printf '\r'
}
