#!/bin/bash
# Export an existing KVS installation for kvs-install.
#
# Run this on the OLD server, as a user that can read the site files and
# reach its database (root in practice: admin/include/setup_db.php is mode
# 600). The default run writes one tar archive holding the site directory, a
# compressed database dump and a manifest; copy that archive to the new
# server and let the kvs-install setup import it.
#
#   ./kvs-export.sh                        find the site, write ./<domain>-kvs-export-<date>.tar
#   ./kvs-export.sh /var/www/example.com   name the site directory
#   ./kvs-export.sh --dump-only            write only the database dump
#
# The Docker setup of kvs-install also pipes this file to the old server over
# SSH, as "ssh host bash -s -- detect [dir]" to show what it found before it
# transfers anything, then as "dump [dir]" to stream the database. bash then
# reads this script itself from stdin, which is why every command here that
# could read stdin is given < /dev/null, why the file is only function
# definitions followed by a single main line, and why detect and dump keep
# stdout for their payload and write every message on stderr.
#
# Nothing is installed or modified on the old server, and the database
# password is never printed, written to a file or passed on a command line:
# it reaches the client through MYSQL_PWD and is shown masked.
#
# KVS-install Copyright (c) 2020-2025 Maxime Michaud
# Licensed under GNU General Public License v3.0
#################################################################
set -u
set -o pipefail

# Roots walked when the caller names no site directory. Overridable with
# KVS_EXPORT_SEARCH_ROOTS, colon separated, so an install outside the usual
# places can still be found without editing this file.
KVS_DEFAULT_SEARCH_ROOTS="/var/www:/home:/srv:/usr/share/nginx:/usr/local/www"

# Names the importer looks for inside the archive; changing them breaks it.
KVS_MANIFEST_NAME="kvs-export.manifest"
KVS_ARCHIVE_SITE_DIR="www"

# Command line
OPT_COMMAND="archive"
OPT_SITE_DIR=""
OPT_OUTPUT=""
OPT_DUMP_ONLY="no"
OPT_FORCE_GZIP="no"
OPT_ASSUME_YES="no"
OPT_SIZE_TIMEOUT="${KVS_EXPORT_SIZE_TIMEOUT:-0}"
OPT_MEASURE_SIZE="yes"
OPT_EXCLUDES=()
OPT_INCLUDES=()

# Detection results, all filled by kvs_collect
SITE_DIR=""
KVS_VERSION=""
PROJECT_URL=""
DOMAIN=""
PROJECT_PATH=""
TABLES_PREFIX=""
TABLES_PREFIX_MULTI=""
DB_HOST_RAW=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_PASSWORD_HINT=""
DB_CLIENT=""
DB_DUMP_TOOL=""
DB_OK="no"
DB_ERROR=""
DB_SERVER_VERSION=""
DB_TABLES="0"
DB_SIZE_MB="0"
DB_NON_TRANSACTIONAL="0"
SITE_SIZE_MB="0"
SITE_SIZE_STATUS="skipped"
SITE_SIZE_SECONDS="0"
SITE_SIZE_ENTRIES="0"
SITE_SIZE_ENTRIES_TOTAL="0"
SITE_FS_USED_MB=""
# Everything the walk counted; SITE_SIZE_MB is what travels.
SITE_TOTAL_MB="0"
# The report of the directories, parallel arrays, and what stays behind as
# rsync patterns anchored at the site directory.
ENTRY_PATHS=()
ENTRY_MB=()
ENTRY_KIND=()
ENTRY_STATE=()
EXCLUDE_PATTERNS=()
SERVER_LINES=()
COMPRESSOR=""
HAS_RSYNC="no"
HOST_NAME=""
SITE_CANDIDATES=()
DB_CONN_ARGS=()
DUMP_ARGS=()
COMPRESS_CMD=()
TAR_EXCLUDES=()

# Removed by the exit trap
STAGING_DIR=""
TEMP_ERR_FILE=""
UNITS_FILE=""
# The size walk in progress: its lines arrive on descriptor 3.
MEASURE_PID=""
MEASURE_KB=0
MEASURE_COUNT=0
# Kilobytes by directory, one to three levels down, from the walk.
declare -A MEASURE_ENTRY_KB=()
MEASURE_PER_ENTRY="no"

kvs_usage() {
    cat <<'EOF'
Usage: kvs-export.sh [options] [command] [site-dir]

Runs on the server that holds the KVS site to move away.

Commands
  archive   Write an archive with the site files, the database dump and a
            manifest (default)
  detect    Print what was found as key=value lines on stdout
  dump      Write the compressed database dump on stdout

Options
  -o, --output PATH   Archive path, or - for stdout. Default:
                      ./<domain>-kvs-export-<YYYYMMDD-HHMM>.tar
      --dump-only     Write only the database dump
      --gzip          Compress the dump with gzip (default: zstd when
                      installed, else pigz, else gzip)
      --size-timeout SECONDS
                      Stop measuring the site size after that long and go
                      on with what was counted as a lower bound (0, the
                      default: measure it all)
      --no-size       Do not measure the site size
      --exclude PATH  Leave a directory behind, relative to the site
                      directory (contents/videos_sources, backup); repeatable.
                      Temporary files, compiled templates, hidden entries
                      and network mounts stay behind on their own
      --include PATH  Take a hidden entry or a network mount along after all
  -y, --yes           Do not ask for confirmation
  -h, --help          Show this help

Environment
  KVS_SITE_DIR              Site directory, same as the argument
  KVS_EXPORT_SEARCH_ROOTS   Colon separated roots to search for the site
  KVS_EXPORT_SIZE_TIMEOUT   Same as --size-timeout
  KVS_EXPORT_SIZE_JOBS      How many du measure the site at once (default:
                            the CPU count, at most 4)
  TMPDIR                    Where the dump is staged while the archive is
                            written (needs room for the compressed dump)

Exit codes
  0 success, 1 error, 2 no site found or several found,
  3 the database could not be reached
EOF
}

#################################################################
# Messages. Everything that is not the payload goes to stderr.
#################################################################

kvs_say() {
    printf '%s\n' "$*" >&2
}

kvs_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

kvs_warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

# shellcheck disable=SC2329  # Runs from the EXIT trap set at the bottom.
kvs_cleanup() {
    kvs_stop_measure
    if [ -n "$UNITS_FILE" ]; then
        rm -f -- "$UNITS_FILE"
    fi
    if [ -n "$TEMP_ERR_FILE" ]; then
        rm -f -- "$TEMP_ERR_FILE"
    fi
    if [ -n "$STAGING_DIR" ]; then
        rm -rf -- "$STAGING_DIR"
    fi
}

#################################################################
# Small helpers
#################################################################

kvs_is_number() {
    case ${1:-} in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Size of a file in bytes. stat spells this differently on every system,
# while wc -c reads the size from the descriptor everywhere.
kvs_file_size() {
    local size

    size=$(wc -c < "$1" 2> /dev/null) || return 1
    size=${size//[[:space:]]/}
    kvs_is_number "$size" || return 1
    printf '%s' "$size"
}

kvs_human_mb() {
    local mb="${1:-}"

    if ! kvs_is_number "$mb"; then
        printf 'unknown size'
        return 0
    fi
    if [ "$mb" -lt 1024 ]; then
        printf '%s MB' "$mb"
    elif [ "$mb" -lt 1048576 ]; then
        printf '%s.%s GB' "$((mb / 1024))" "$(((mb * 10 / 1024) % 10))"
    else
        printf '%s.%s TB' "$((mb / 1048576))" "$(((mb * 10 / 1048576) % 10))"
    fi
}

kvs_elapsed() {
    local seconds="${1:-0}"

    kvs_is_number "$seconds" || seconds=0
    if [ "$seconds" -ge 3600 ]; then
        printf '%sh%02dm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
    elif [ "$seconds" -ge 60 ]; then
        printf '%sm%02ds' "$((seconds / 60))" "$((seconds % 60))"
    else
        printf '%ss' "$seconds"
    fi
}

# Collapse a tool's error output into one line: the detect output is parsed
# line by line, so a value may never carry a newline.
kvs_one_line() {
    local text="${1:-}"

    text=${text//$'\r'/ }
    text=${text//$'\n'/ }
    text=${text//$'\t'/ }
    text=${text#"${text%%[![:space:]]*}"}
    text=${text%"${text##*[![:space:]]}"}
    if [ ${#text} -gt 200 ]; then
        text="${text:0:197}..."
    fi
    printf '%s' "$text"
}

kvs_hostname() {
    local name="${HOSTNAME:-}"

    if [ -z "$name" ]; then
        # shellcheck disable=SC2217  # stdin is the script itself under bash -s.
        name=$(uname -n < /dev/null 2> /dev/null) || name=""
    fi
    printf '%s' "$name"
}

#################################################################
# Reading the KVS configuration files
#################################################################

# The first $config['<key>'] = "<value>"; of a KVS config file, read the way
# KVS writes it. Same expression as docker/lib/import.sh, kept inline because
# this script runs alone on the old server with nothing else of kvs-install.
kvs_config_value() {
    local file="$1"
    local key="$2"
    local pattern
    local value

    [ -f "$file" ] || return 1
    pattern="s/^[[:space:]]*\\\$config\\[[[:space:]]*['\"]${key}['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p"
    value=$(sed -n -E "$pattern" "$file" 2> /dev/null)
    printf '%s' "${value%%$'\n'*}"
}

# The first define('<name>','<value>'); of setup_db.php. PHP single quoted
# strings escape the quote and the backslash, so the value pattern accepts
# \' and \\ inside and the caller unescapes what it gets back.
kvs_define_value() {
    local file="$1"
    local name="$2"
    local value

    [ -f "$file" ] || return 1
    value=$(sed -n -E "s/^.*define\\([[:space:]]*'${name}'[[:space:]]*,[[:space:]]*'((\\\\.|[^'\\\\])*)'.*/\\1/p" "$file" 2> /dev/null)
    printf '%s' "${value%%$'\n'*}"
}

# Undo the escaping of a PHP single quoted string. Only \' and \\ are
# escapes there: \n stays a backslash followed by an n, so a blind
# "drop every backslash" would corrupt the password.
kvs_php_unescape() {
    local value="${1:-}"
    local out=""
    local head
    local backslash=$'\\'
    local escaped_backslash="${backslash}${backslash}"
    local escaped_quote="${backslash}'"

    while [ -n "$value" ]; do
        head=${value:0:2}
        if [ "$head" = "$escaped_backslash" ]; then
            out=$out$backslash
            value=${value:2}
        elif [ "$head" = "$escaped_quote" ]; then
            out=$out"'"
            value=${value:2}
        else
            out=$out${value:0:1}
            value=${value:1}
        fi
    done
    printf '%s' "$out"
}

# What the summary and the detect output show instead of the password.
kvs_mask_password() {
    local value="${1:-}"

    [ -n "$value" ] || return 0
    # Under five characters the first two would give most of it away, and a
    # variable width would leak the length, so short ones are all asterisks.
    if [ ${#value} -lt 5 ]; then
        printf '********'
    else
        printf '%s********' "${value:0:2}"
    fi
}

# Host of a project_url, without the scheme, the port, the path and the
# leading www.: what the new server will be installed under.
kvs_url_domain() {
    local url="${1:-}"
    local host

    host=${url#*://}
    host=${host%%/*}
    host=${host%%\?*}
    host=${host##*@}
    host=${host%%:*}
    host=${host#www.}
    printf '%s' "$host"
}

#################################################################
# Finding the site
#################################################################

kvs_search_roots() {
    printf '%s' "${KVS_EXPORT_SEARCH_ROOTS:-$KVS_DEFAULT_SEARCH_ROOTS}"
}

kvs_candidate_known() {
    local wanted="$1"
    local count=${#SITE_CANDIDATES[@]}
    local i=0

    while [ "$i" -lt "$count" ]; do
        if [ "${SITE_CANDIDATES[$i]}" = "$wanted" ]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# Fill SITE_CANDIDATES with the directories holding admin/include/setup.php.
# contents/ is pruned: it holds the media files, and walking a few terabytes
# of them to find a config file would take minutes for nothing.
kvs_find_sites() {
    local rest
    local root
    local setup
    local candidate

    SITE_CANDIDATES=()
    rest=$(kvs_search_roots)
    while [ -n "$rest" ]; do
        case $rest in
            *:*)
                root=${rest%%:*}
                rest=${rest#*:}
                ;;
            *)
                root=$rest
                rest=""
                ;;
        esac
        if [ -z "$root" ] || [ ! -d "$root" ]; then
            continue
        fi
        while IFS= read -r setup; do
            [ -n "$setup" ] || continue
            candidate=${setup%/admin/include/setup.php}
            candidate=$(readlink -f -- "$candidate" < /dev/null 2> /dev/null) ||
                candidate=${setup%/admin/include/setup.php}
            if kvs_candidate_known "$candidate"; then
                continue
            fi
            SITE_CANDIDATES+=("$candidate")
        done < <(find "$root" -maxdepth 6 -name contents -prune -o -path '*/admin/include/setup.php' -print 2> /dev/null < /dev/null)
    done
}

kvs_resolve_site_dir() {
    local dir
    local resolved
    local count
    local i

    dir=${OPT_SITE_DIR:-${KVS_SITE_DIR:-}}
    if [ -n "$dir" ]; then
        if [ ! -d "$dir" ]; then
            kvs_error "not a directory: $dir"
            return 1
        fi
        if [ ! -f "$dir/admin/include/setup.php" ]; then
            kvs_error "$dir holds no KVS site (admin/include/setup.php is missing)"
            return 1
        fi
        resolved=$(readlink -f -- "$dir" < /dev/null 2> /dev/null) || resolved=$dir
        SITE_DIR=$resolved
        return 0
    fi
    kvs_say "Looking for a KVS site under $(kvs_search_roots) ..."
    kvs_find_sites
    count=${#SITE_CANDIDATES[@]}
    if [ "$count" -eq 1 ]; then
        SITE_DIR=${SITE_CANDIDATES[0]}
        kvs_say "Found $SITE_DIR"
        return 0
    fi
    if [ "$count" -eq 0 ]; then
        kvs_error "no KVS site found under $(kvs_search_roots); name its directory as an argument, or set KVS_SITE_DIR or KVS_EXPORT_SEARCH_ROOTS"
        return 2
    fi
    if [ "$OPT_COMMAND" = "detect" ]; then
        kvs_error "several KVS sites found, listed as site_candidate_N on stdout"
    else
        kvs_error "several KVS sites found; name the one to export as an argument:"
        i=0
        while [ "$i" -lt "$count" ]; do
            kvs_say "  ${SITE_CANDIDATES[$i]}"
            i=$((i + 1))
        done
    fi
    return 2
}

#################################################################
# Database
#################################################################

# Escape the fixed part of a LIKE pattern: the table prefix ends with an
# underscore, which is a single character wildcard.
kvs_sql_like_escape() {
    local value="${1:-}"

    value=${value//\\/\\\\}
    value=${value//\'/\\\'}
    value=${value//%/\\%}
    value=${value//_/\\_}
    printf '%s' "$value"
}

kvs_detect_tools() {
    DB_CLIENT=""
    DB_DUMP_TOOL=""
    if command -v mariadb > /dev/null 2>&1; then
        DB_CLIENT="mariadb"
    elif command -v mysql > /dev/null 2>&1; then
        DB_CLIENT="mysql"
    fi
    if command -v mariadb-dump > /dev/null 2>&1; then
        DB_DUMP_TOOL="mariadb-dump"
    elif command -v mysqldump > /dev/null 2>&1; then
        DB_DUMP_TOOL="mysqldump"
    fi
    if command -v rsync > /dev/null 2>&1; then
        HAS_RSYNC="yes"
    else
        HAS_RSYNC="no"
    fi
    kvs_choose_compressor
}

# DB_HOST is whatever the site was configured with: a bare host uses TCP,
# localhost uses the socket the client defaults to, host:port forces a port
# and host:/path names a socket, exactly like the PHP drivers read it. The
# arguments are shared by the client and the dump tool, so only what both
# accept goes here: the dump tool refuses the client's connect timeout.
# A port forces TCP: the clients take the host name localhost as the
# socket and would ignore the port, where PHP connects to it.
kvs_build_connection_args() {
    local port

    DB_CONN_ARGS=()
    case $DB_HOST_RAW in
        '' | localhost) ;;
        *:/*)
            DB_CONN_ARGS+=(-S "${DB_HOST_RAW#*:}")
            ;;
        *:*)
            port=${DB_HOST_RAW##*:}
            if kvs_is_number "$port"; then
                DB_CONN_ARGS+=(--protocol=tcp -h "${DB_HOST_RAW%:*}" -P "$port")
            else
                DB_CONN_ARGS+=(-h "$DB_HOST_RAW")
            fi
            ;;
        *)
            DB_CONN_ARGS+=(-h "$DB_HOST_RAW")
            ;;
    esac
    if [ -n "$DB_USER" ]; then
        DB_CONN_ARGS+=(-u "$DB_USER")
    fi
}

# A [client] password in ~/.my.cnf or in $MYSQL_HOME/my.cnf beats MYSQL_PWD
# (option files win over the environment), so a root box with its own
# .my.cnf would log in as the site's user with the wrong password. Point the
# clients at no home; the system option files, and their socket path, still
# apply. Called inside the subshell that exports the password.
kvs_ignore_user_option_files() {
    export HOME=/nonexistent
    unset MYSQL_HOME
}

# One query for the numbers the summary shows: server version, tables of
# the prefix, size, and the tables on a non-transactional engine (MyISAM,
# Aria), which decide how the dump keeps the data consistent. A failure is
# not fatal: detect reports db_ok=no and the caller decides what to do.
kvs_probe_database() {
    local like
    local query
    local out
    local err
    local status
    local line

    DB_OK="no"
    DB_ERROR=""
    DB_SERVER_VERSION=""
    DB_TABLES="0"
    DB_SIZE_MB="0"
    DB_NON_TRANSACTIONAL="0"
    if [ -z "$DB_CLIENT" ]; then
        DB_ERROR="no mariadb or mysql client on this server"
        return 0
    fi
    if [ -z "$DB_NAME" ]; then
        DB_ERROR="no DB_DEVICE in $SITE_DIR/admin/include/setup_db.php"
        return 0
    fi
    like=$(kvs_sql_like_escape "$TABLES_PREFIX")
    query="SELECT VERSION(), (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name LIKE '${like}%'), (SELECT ROUND(COALESCE(SUM(data_length + index_length), 0) / 1048576) FROM information_schema.tables WHERE table_schema = DATABASE()), (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' AND engine IS NOT NULL AND engine NOT IN ('InnoDB'))"
    TEMP_ERR_FILE=$(mktemp 2> /dev/null) || TEMP_ERR_FILE=""
    if [ -z "$TEMP_ERR_FILE" ]; then
        DB_ERROR="cannot create a temporary file"
        return 0
    fi
    # The password goes through the environment of the client and nowhere
    # else: an argument would show up in ps for every user on the box.
    out=$(
        # shellcheck disable=SC2030  # The subshell scope is the point: the
        # password must not stay in the environment of this script.
        export MYSQL_PWD="$DB_PASSWORD"
        kvs_ignore_user_option_files
        "$DB_CLIENT" --connect-timeout=10 "${DB_CONN_ARGS[@]}" -N -B -e "$query" "$DB_NAME" 2> "$TEMP_ERR_FILE" < /dev/null
    )
    status=$?
    err=$(< "$TEMP_ERR_FILE")
    rm -f -- "$TEMP_ERR_FILE"
    TEMP_ERR_FILE=""
    if [ "$status" -ne 0 ]; then
        DB_ERROR=$(kvs_one_line "$err")
        if [ -z "$DB_ERROR" ]; then
            DB_ERROR="$DB_CLIENT exited with status $status"
        fi
        return 0
    fi
    line=${out%%$'\n'*}
    IFS=$'\t' read -r DB_SERVER_VERSION DB_TABLES DB_SIZE_MB DB_NON_TRANSACTIONAL <<< "$line"
    if [ -z "$DB_SERVER_VERSION" ]; then
        DB_ERROR="the probe query returned nothing"
        return 0
    fi
    kvs_is_number "$DB_TABLES" || DB_TABLES="0"
    kvs_is_number "$DB_SIZE_MB" || DB_SIZE_MB="0"
    kvs_is_number "$DB_NON_TRANSACTIONAL" || DB_NON_TRANSACTIONAL="0"
    DB_OK="yes"
    return 0
}

#################################################################
# Sizes and free space
#################################################################

# Megabytes used on the filesystems holding the site: the one under the
# site directory, plus the one under contents when that is a link or a
# mount to another disk. df answers at once and the site cannot be bigger
# than that, so it is the figure shown before the walk starts and the one
# left when the walk is cut short.
kvs_site_filesystem_used() {
    local path
    local line
    local device
    local used
    local mount
    local seen=""
    local total=0

    SITE_FS_USED_MB=""
    for path in "$SITE_DIR" "$SITE_DIR/contents"; do
        [ -d "$path" ] || continue
        # shellcheck disable=SC2217  # stdin is the script itself under bash -s.
        line=$(df -Pm -- "$path" 2> /dev/null < /dev/null | sed -n '2p') || line=""
        [ -n "$line" ] || continue
        read -r device _ used _ _ mount <<< "$line"
        kvs_is_number "$used" || continue
        case $seen in
            *"|$device $mount|"*) continue ;;
        esac
        seen="$seen|$device $mount|"
        total=$((total + used))
    done
    if [ -n "$seen" ]; then
        SITE_FS_USED_MB=$total
    fi
}

# How many du walk the site at once: the CPU count, at most 4 so a live
# server keeps serving; KVS_EXPORT_SIZE_JOBS overrides (an SSD takes more).
kvs_measure_jobs() {
    local jobs="${KVS_EXPORT_SIZE_JOBS:-}"

    if kvs_is_number "$jobs" && [ "$jobs" -ge 1 ]; then
        printf '%s' "$jobs"
        return 0
    fi
    jobs=$(nproc 2> /dev/null < /dev/null) || jobs=""
    if ! kvs_is_number "$jobs"; then
        jobs=$(getconf _NPROCESSORS_ONLN 2> /dev/null) || jobs=""
    fi
    kvs_is_number "$jobs" || jobs=1
    [ "$jobs" -ge 1 ] || jobs=1
    [ "$jobs" -le 4 ] || jobs=4
    printf '%s' "$jobs"
}

# The entries the walk measures one by one: everything three levels down
# (the id buckets of contents/, admin/*/*, static/*/*) and the files above
# that level. Together they hold the whole site but the directory inodes
# above them, a few kilobytes. Three levels down is thousands of entries
# at most, which find lists in a moment even under contents/.
kvs_list_measure_units() {
    local file="$1"
    local depth="$2"

    {
        find -L "$SITE_DIR" -mindepth 1 -maxdepth "$((depth - 1))" ! -type d -print0 2> /dev/null
        find -L "$SITE_DIR" -mindepth "$depth" -maxdepth "$depth" -print0 2> /dev/null
    } > "$file" < /dev/null
}

# Start the du processes over the listed entries, their lines arriving on
# descriptor 3. False when xargs cannot take a NUL separated list.
kvs_start_measure() {
    local file="$1"
    local jobs="$2"

    # The probes run du on an empty list: the options are checked, nothing
    # is measured.
    if xargs -r -0 -n 1 -P "$jobs" du < /dev/null > /dev/null 2>&1; then
        exec 3< <(exec xargs -0 -n 1 -P "$jobs" du -sLk -- < "$file" 2> /dev/null)
    elif xargs -r -0 -n 1 du < /dev/null > /dev/null 2>&1; then
        exec 3< <(exec xargs -0 -n 1 du -sLk -- < "$file" 2> /dev/null)
    else
        return 1
    fi
    MEASURE_PID=$!
    return 0
}

# Stop the walk. xargs is held first so it starts no further du while the
# ones at work are killed, then it is released with its own signal.
kvs_stop_measure() {
    if [ -n "$MEASURE_PID" ]; then
        kill -STOP "$MEASURE_PID" 2> /dev/null
        pkill -TERM -P "$MEASURE_PID" 2> /dev/null
        kill -TERM "$MEASURE_PID" 2> /dev/null
        kill -CONT "$MEASURE_PID" 2> /dev/null
        MEASURE_PID=""
    fi
}

# One line of du -sk: kilobytes, a tab, the path. The kilobytes also go
# to the buckets of the directories above the entry, up to three levels
# down, which is what the report of the entries reads.
kvs_add_measure_line() {
    local size="${1%%$'\t'*}"
    local path="${1#*$'\t'}"
    local rel
    local key

    kvs_is_number "$size" || return 1
    MEASURE_KB=$((MEASURE_KB + size))
    MEASURE_COUNT=$((MEASURE_COUNT + 1))
    rel=${path#"$SITE_DIR/"}
    [ "$rel" != "$path" ] || return 0
    key=${rel%%/*}
    MEASURE_ENTRY_KB[$key]=$((${MEASURE_ENTRY_KB[$key]:-0} + size))
    [ "$key" != "$rel" ] || return 0
    rel=${rel#*/}
    key="$key/${rel%%/*}"
    MEASURE_ENTRY_KB[$key]=$((${MEASURE_ENTRY_KB[$key]:-0} + size))
    [ "${rel%%/*}" != "$rel" ] || return 0
    rel=${rel#*/}
    key="$key/${rel%%/*}"
    MEASURE_ENTRY_KB[$key]=$((${MEASURE_ENTRY_KB[$key]:-0} + size))
    return 0
}

# The site size, the way the archive and the transfer will read it (links
# followed). One du over a large site stats millions of inodes with no
# sign of life for as long as that takes, so the tree is split into the
# entries three levels down, a few du measure them at once and a line
# every ten seconds tells how far the walk is. A time budget cuts it
# short: the report then carries what was counted as a lower bound and
# the filesystem usage as the upper one, and the caller decides.
kvs_measure_site() {
    local depth=3
    local jobs
    local total=0
    local line
    local status
    local start
    local last
    local elapsed=0
    local timed_out="no"

    SITE_SIZE_MB="0"
    SITE_SIZE_STATUS="skipped"
    SITE_SIZE_SECONDS="0"
    SITE_SIZE_ENTRIES="0"
    SITE_SIZE_ENTRIES_TOTAL="0"
    MEASURE_KB=0
    MEASURE_COUNT=0
    MEASURE_ENTRY_KB=()
    MEASURE_PER_ENTRY="no"
    kvs_site_filesystem_used
    if [ "$OPT_MEASURE_SIZE" != "yes" ]; then
        kvs_say "Site size: not measured (--no-size); the filesystem holding the site uses $(kvs_human_mb "$SITE_FS_USED_MB")"
        return 0
    fi
    jobs=$(kvs_measure_jobs)
    UNITS_FILE=$(mktemp 2> /dev/null) || UNITS_FILE=""
    if [ -n "$UNITS_FILE" ]; then
        kvs_list_measure_units "$UNITS_FILE" "$depth"
        while IFS= read -r -d '' _; do
            total=$((total + 1))
        done < "$UNITS_FILE"
    fi
    if [ -n "$SITE_FS_USED_MB" ]; then
        kvs_say "The filesystem holding the site uses $(kvs_human_mb "$SITE_FS_USED_MB"); the site is at most that."
    fi
    if [ "$OPT_SIZE_TIMEOUT" -gt 0 ]; then
        kvs_say "Measuring the site size for at most $(kvs_elapsed "$OPT_SIZE_TIMEOUT") ($total entries, $jobs at a time)..."
    else
        kvs_say "Measuring the site size, this can take a while on a large installation ($total entries, $jobs at a time; --size-timeout bounds it, --no-size skips it)..."
    fi
    if [ "$total" -gt 0 ] && kvs_start_measure "$UNITS_FILE" "$jobs"; then
        MEASURE_PER_ENTRY="yes"
    else
        # Nothing listed or no usable xargs: one du over the site, with
        # the timer only.
        total=1
        exec 3< <(exec du -sLk -- "$SITE_DIR" 2> /dev/null)
        MEASURE_PID=$!
    fi
    start=$SECONDS
    last=$start
    while :; do
        line=""
        if IFS= read -r -t 1 line <&3; then
            kvs_add_measure_line "$line"
        else
            status=$?
            if [ "$status" -le 128 ]; then
                # End of the stream; a last line without newline counts.
                [ -z "$line" ] || kvs_add_measure_line "$line"
                break
            fi
        fi
        elapsed=$((SECONDS - start))
        if [ "$timed_out" = "no" ] && [ "$OPT_SIZE_TIMEOUT" -gt 0 ] && [ "$elapsed" -ge "$OPT_SIZE_TIMEOUT" ]; then
            timed_out="yes"
            kvs_stop_measure
        fi
        if [ $((SECONDS - last)) -ge 10 ]; then
            kvs_say "  $MEASURE_COUNT of $total entries, $(kvs_human_mb "$((MEASURE_KB / 1024))") so far, $(kvs_elapsed "$elapsed")"
            last=$SECONDS
        fi
    done
    exec 3<&-
    MEASURE_PID=""
    rm -f -- "$UNITS_FILE"
    UNITS_FILE=""
    SITE_SIZE_SECONDS=$((SECONDS - start))
    SITE_SIZE_MB=$((MEASURE_KB / 1024))
    SITE_SIZE_ENTRIES=$MEASURE_COUNT
    SITE_SIZE_ENTRIES_TOTAL=$total
    if [ "$timed_out" = "yes" ]; then
        SITE_SIZE_STATUS="incomplete"
        kvs_warn "site size measurement cut short after $(kvs_elapsed "$SITE_SIZE_SECONDS"): at least $(kvs_human_mb "$SITE_SIZE_MB") in $MEASURE_COUNT of $total entries, at most $(kvs_human_mb "$SITE_FS_USED_MB") (the filesystem usage); --size-timeout 0 measures it all"
        return 0
    fi
    if [ "$MEASURE_COUNT" -eq 0 ]; then
        SITE_SIZE_STATUS="failed"
        kvs_warn "could not measure the size of $SITE_DIR"
        return 0
    fi
    SITE_SIZE_STATUS="exact"
    if [ "$MEASURE_COUNT" -lt "$total" ]; then
        kvs_warn "$((total - MEASURE_COUNT)) of $total entries could not be measured (removed meanwhile, or unreadable)"
    fi
    kvs_say "Site size: $(kvs_human_mb "$SITE_SIZE_MB") ($total entries, $(kvs_elapsed "$SITE_SIZE_SECONDS"))"
}

#################################################################
# What the site holds, and what leaves with it
#################################################################

# The directories a stock KVS site has at its root. Anything else there is
# not KVS (an old backup, another site, a tool's scratch space): it is
# reported with its size and travels unless excluded, except hidden
# entries, which stay behind unless included.
KVS_ROOT_DIRS=" _INSTALL admin blocks contents langs player static template tmp "
# Directories KVS fills by itself, temporary files and compiled templates:
# their content never travels, the directories do, empty.
KVS_TRANSIENT_DIRS=" tmp admin/data/tmp admin/smarty/cache admin/smarty/template-c admin/smarty/template-c-site "
# Directories worth a line of their own in the report when present.
KVS_REPORTED_DIRS="admin/logs admin/data/backup"
# Filesystem types that mean the data lives on another machine: a storage
# server mounted here, most likely, which the new server has no use for.
KVS_NETWORK_FS=" nfs nfs4 cifs smb2 smb3 smbfs glusterfs ceph fuse.ceph fuse.sshfs fuse.rclone fuse.s3fs fuse.gcsfuse fuse.glusterfs fuse.curlftpfs fuse.davfs2 davfs 9p lustre afs "

kvs_in_word_list() {
    case " $2 " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# kvs_path_listed <relative path> <paths...>: the path, or a parent of it,
# is among the arguments.
kvs_path_listed() {
    local rel="$1"
    local item

    shift
    for item in "$@"; do
        if [ "$item" = "$rel" ]; then
            return 0
        fi
        case $rel in
            "$item"/*) return 0 ;;
        esac
    done
    return 1
}

kvs_path_under() {
    case $1 in
        "$2" | "$2"/*) return 0 ;;
    esac
    return 1
}

# The filesystem type holding a path, through the symbolic links: findmnt
# where util-linux is, the stat of the filesystem otherwise.
kvs_fs_type() {
    local path="$1"
    local type=""

    type=$(findmnt -T "$path" -n -o FSTYPE 2> /dev/null < /dev/null) || type=""
    type=${type%%$'\n'*}
    if [ -z "$type" ]; then
        type=$(stat -f -c %T "$path" 2> /dev/null < /dev/null) || type=""
    fi
    printf '%s' "$type"
}

# kvs_entry_kind <relative path>: transient, network:<fs>, hidden, extra
# or kvs.
kvs_entry_kind() {
    local rel="$1"
    local name="${rel##*/}"
    local fs

    if kvs_in_word_list "$rel" "$KVS_TRANSIENT_DIRS"; then
        printf 'transient'
        return 0
    fi
    fs=$(kvs_fs_type "$SITE_DIR/$rel")
    if [ -n "$fs" ] && kvs_in_word_list "$fs" "$KVS_NETWORK_FS"; then
        printf 'network:%s' "$fs"
        return 0
    fi
    case $rel in
        */*)
            printf 'kvs'
            return 0
            ;;
    esac
    case $name in
        .*)
            printf 'hidden'
            return 0
            ;;
    esac
    if kvs_in_word_list "$rel" "$KVS_ROOT_DIRS"; then
        printf 'kvs'
    else
        printf 'extra'
    fi
}

# The directories the report lists: the ones at the root, the ones under
# contents/, and the few under admin/ that grow on their own.
kvs_list_entry_candidates() {
    local path
    local rel

    {
        find -L "$SITE_DIR" -mindepth 1 -maxdepth 1 -type d -print 2> /dev/null | LC_ALL=C sort
        if [ -d "$SITE_DIR/contents" ]; then
            find -L "$SITE_DIR/contents" -mindepth 1 -maxdepth 1 -type d -print 2> /dev/null | LC_ALL=C sort
        fi
        for rel in $KVS_REPORTED_DIRS $KVS_TRANSIENT_DIRS; do
            if [ -d "$SITE_DIR/$rel" ]; then
                printf '%s/%s\n' "$SITE_DIR" "$rel"
            fi
        done
    } < /dev/null | while IFS= read -r path; do
        rel=${path#"$SITE_DIR/"}
        if [ -n "$rel" ] && [ "$rel" != "$path" ]; then
            printf '%s\n' "$rel"
        fi
    done | awk '!seen[$0]++'
}

# kvs_entry_index <relative path>: its position in the entry arrays.
kvs_entry_index() {
    local rel="$1"
    local i=0

    while [ "$i" -lt "${#ENTRY_PATHS[@]}" ]; do
        if [ "${ENTRY_PATHS[$i]}" = "$rel" ]; then
            printf '%s' "$i"
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

# kvs_entry_has_excluded_parent <index>: an excluded entry above it, so it
# leaves with that one and counts once.
kvs_entry_has_excluded_parent() {
    local i="$1"
    local j=0

    while [ "$j" -lt "${#ENTRY_PATHS[@]}" ]; do
        if [ "$j" -ne "$i" ] && [ "${ENTRY_STATE[$j]}" = "excluded" ]; then
            case ${ENTRY_PATHS[$i]} in
                "${ENTRY_PATHS[$j]}"/*) return 0 ;;
            esac
        fi
        j=$((j + 1))
    done
    return 1
}

# Fill the entry arrays and the exclusion patterns from the walk buckets
# and the options. What stays behind leaves the site size, once.
kvs_collect_entries() {
    local rel
    local kind
    local state
    local mb
    local i
    local excluded_mb=0

    ENTRY_PATHS=()
    ENTRY_MB=()
    ENTRY_KIND=()
    ENTRY_STATE=()
    EXCLUDE_PATTERNS=()
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        kind=$(kvs_entry_kind "$rel")
        state="copied"
        case $kind in
            transient | hidden | network:*) state="excluded" ;;
        esac
        if kvs_path_listed "$rel" "${OPT_EXCLUDES[@]}"; then
            state="excluded"
        fi
        if [ "$kind" != "transient" ] && kvs_path_listed "$rel" "${OPT_INCLUDES[@]}"; then
            state="copied"
        fi
        mb=""
        if [ "$MEASURE_PER_ENTRY" = "yes" ]; then
            mb=$((${MEASURE_ENTRY_KB[$rel]:-0} / 1024))
        fi
        ENTRY_PATHS+=("$rel")
        ENTRY_MB+=("$mb")
        ENTRY_KIND+=("$kind")
        ENTRY_STATE+=("$state")
    done < <(kvs_list_entry_candidates)
    # An excluded path that is no listed entry (one bucket of contents/, a
    # directory deeper down) still leaves, with its size when the walk
    # counted it apart.
    for rel in "${OPT_EXCLUDES[@]}"; do
        if kvs_entry_index "$rel" > /dev/null; then
            continue
        fi
        mb=""
        if [ "$MEASURE_PER_ENTRY" = "yes" ] && [ -n "${MEASURE_ENTRY_KB[$rel]:-}" ]; then
            mb=$((MEASURE_ENTRY_KB[$rel] / 1024))
        fi
        ENTRY_PATHS+=("$rel")
        ENTRY_MB+=("$mb")
        ENTRY_KIND+=("named")
        ENTRY_STATE+=("excluded")
    done
    i=0
    while [ "$i" -lt "${#ENTRY_PATHS[@]}" ]; do
        if [ "${ENTRY_STATE[$i]}" = "excluded" ] && ! kvs_entry_has_excluded_parent "$i"; then
            if [ "${ENTRY_KIND[$i]}" = "transient" ]; then
                EXCLUDE_PATTERNS+=("/${ENTRY_PATHS[$i]}/*")
            else
                EXCLUDE_PATTERNS+=("/${ENTRY_PATHS[$i]}")
            fi
            if kvs_is_number "${ENTRY_MB[$i]}"; then
                excluded_mb=$((excluded_mb + ENTRY_MB[i]))
            fi
        fi
        i=$((i + 1))
    done
    SITE_TOTAL_MB=$SITE_SIZE_MB
    if [ "$SITE_SIZE_MB" -gt "$excluded_mb" ]; then
        SITE_SIZE_MB=$((SITE_SIZE_MB - excluded_mb))
    else
        SITE_SIZE_MB=0
    fi
}

# The storage servers of the site, from its database: title, path, whether
# KVS reaches it remotely, where the path falls, first URL. A local storage
# server outside the site directory holds content this export does not
# carry and a path the import does not rewrite; a remote one stays where it
# is and keeps serving. Older schemas without these columns answer nothing.
kvs_probe_servers() {
    local query
    local out
    local title
    local path
    local remote
    local urls
    local placement

    SERVER_LINES=()
    [ "$DB_OK" = "yes" ] || return 0
    query="SELECT title, path, is_remote, SUBSTRING_INDEX(urls, '\\n', 1) FROM ${TABLES_PREFIX}admin_servers ORDER BY server_id"
    out=$(
        # shellcheck disable=SC2030,SC2031  # Same deliberate subshell as the probe.
        export MYSQL_PWD="$DB_PASSWORD"
        kvs_ignore_user_option_files
        "$DB_CLIENT" --connect-timeout=10 "${DB_CONN_ARGS[@]}" -N -B -e "$query" "$DB_NAME" 2> /dev/null < /dev/null
    ) || return 0
    while IFS=$'\t' read -r title path remote urls; do
        [ -n "$title$path" ] || continue
        placement="outside"
        if [ -n "$PROJECT_PATH" ] && kvs_path_under "$path" "$PROJECT_PATH"; then
            placement="inside"
        elif kvs_path_under "$path" "$SITE_DIR"; then
            placement="inside"
        fi
        SERVER_LINES+=("$(kvs_one_line "$title")|$(kvs_one_line "$path")|${remote:-0}|$placement|$(kvs_one_line "$urls")")
    done <<< "$out"
    return 0
}

# kvs_entry_line <index>: one line of the report.
kvs_entry_line() {
    local i="$1"
    local size
    local note=""

    if kvs_is_number "${ENTRY_MB[$i]}"; then
        size=$(kvs_human_mb "${ENTRY_MB[$i]}")
    else
        size="?"
    fi
    case ${ENTRY_KIND[$i]} in
        transient) note="temporary files or compiled templates, KVS rebuilds them" ;;
        hidden) note="hidden, not part of KVS" ;;
        extra) note="not part of KVS" ;;
        network:*) note="on a network filesystem (${ENTRY_KIND[$i]#network:}), a storage server most likely" ;;
        named) note="named with --exclude" ;;
    esac
    printf '%-10s %-34s %s%s' "$size" "${ENTRY_PATHS[$i]}" "${ENTRY_STATE[$i]}" "${note:+ ($note)}"
}

kvs_print_entries() {
    local i=0
    local order=""

    [ "${#ENTRY_PATHS[@]}" -gt 0 ] || return 0
    kvs_say "  Entries, largest first (--exclude PATH leaves one behind, --include PATH takes one along):"
    while [ "$i" -lt "${#ENTRY_PATHS[@]}" ]; do
        order="$order${ENTRY_MB[$i]:-0} $i"$'\n'
        i=$((i + 1))
    done
    while read -r _ i; do
        [ -n "$i" ] || continue
        kvs_say "    $(kvs_entry_line "$i")"
    done < <(printf '%s' "$order" | sort -k1,1nr -k2,2n)
}

kvs_print_servers() {
    local line
    local title
    local path
    local remote
    local placement
    local urls

    [ "${#SERVER_LINES[@]}" -gt 0 ] || return 0
    kvs_say "  Storage servers:"
    for line in "${SERVER_LINES[@]}"; do
        IFS='|' read -r title path remote placement urls <<< "$line"
        if [ "$remote" = "1" ]; then
            kvs_say "    $title: remote (${urls:-no URL}), stays where it is"
        elif [ "$placement" = "inside" ]; then
            kvs_say "    $title: $path, inside the site, moves with it"
        else
            kvs_say "    $title: $path, OUTSIDE the site directory: not transferred, and its path is not rewritten"
        fi
    done
}

# What the summary shows for the site size.
kvs_site_size_text() {
    case $SITE_SIZE_STATUS in
        exact)
            if [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ]; then
                printf '%s to transfer of %s' "$(kvs_human_mb "$SITE_SIZE_MB")" "$(kvs_human_mb "$SITE_TOTAL_MB")"
            else
                kvs_human_mb "$SITE_SIZE_MB"
            fi
            ;;
        incomplete)
            printf 'at least %s to transfer, at most %s, measurement cut short' "$(kvs_human_mb "$SITE_SIZE_MB")" "$(kvs_human_mb "$SITE_FS_USED_MB")"
            ;;
        *)
            printf 'not measured, at most %s' "$(kvs_human_mb "$SITE_FS_USED_MB")"
            ;;
    esac
}

# Free megabytes on the filesystem holding the path, or its nearest existing
# parent when the path is the file about to be created.
kvs_available_mb() {
    local path="$1"
    local probe
    local out
    local line
    local avail
    local rest

    probe=$path
    while [ -n "$probe" ] && [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
        if [ "${probe%/*}" = "$probe" ]; then
            probe="."
        else
            probe=${probe%/*}
            [ -n "$probe" ] || probe="/"
        fi
    done
    out=$(df -Pm -- "$probe" 2> /dev/null < /dev/null || true)
    line=${out#*$'\n'}
    line=${line%%$'\n'*}
    [ -n "$line" ] || return 1
    read -r _ _ _ avail _ <<< "$line"
    kvs_is_number "$avail" || return 1
    printf '%s' "$avail"
}

kvs_check_free_space() {
    local needed="$1"
    local path="$2"
    local available

    available=$(kvs_available_mb "$path") || {
        kvs_warn "could not read the free space of $path, writing anyway"
        return 0
    }
    needed=$((needed + needed / 10))
    if [ "$available" -lt "$needed" ]; then
        kvs_error "not enough free space for $path: $(kvs_human_mb "$needed") needed, $(kvs_human_mb "$available") available"
        return 1
    fi
    return 0
}

#################################################################
# Dump
#################################################################

kvs_choose_compressor() {
    if [ "$OPT_FORCE_GZIP" = "yes" ]; then
        COMPRESSOR="gzip"
    elif command -v zstd > /dev/null 2>&1; then
        COMPRESSOR="zstd"
    elif command -v pigz > /dev/null 2>&1; then
        COMPRESSOR="pigz"
    else
        COMPRESSOR="gzip"
    fi
}

kvs_dump_extension() {
    case $COMPRESSOR in
        zstd) printf 'sql.zst' ;;
        *) printf 'sql.gz' ;;
    esac
}

kvs_compressor_args() {
    case $COMPRESSOR in
        zstd) COMPRESS_CMD=(zstd -T0 -3 -q -c) ;;
        pigz) COMPRESS_CMD=(pigz -6 -c) ;;
        *) COMPRESS_CMD=(gzip -6 -c) ;;
    esac
}

kvs_tool_advertises() {
    local tool="$1"
    local needle="$2"
    local help

    help=$("$tool" --help < /dev/null 2>&1 || true)
    case $help in
        *"$needle"*) return 0 ;;
        *) return 1 ;;
    esac
}

kvs_build_dump_args() {
    # A single transaction gives a consistent dump of InnoDB tables without
    # blocking the site. It does nothing for MyISAM or Aria tables: those
    # are only consistent under a table lock, which holds the writes of the
    # site while the dump runs.
    if [ "$DB_NON_TRANSACTIONAL" -gt 0 ]; then
        DUMP_ARGS=(--lock-tables)
        kvs_warn "$DB_NON_TRANSACTIONAL tables use MyISAM or Aria: the dump locks the tables while it runs, writes on the site wait"
    else
        DUMP_ARGS=(--single-transaction)
    fi
    DUMP_ARGS+=(
        --quick
        --hex-blob
        --triggers
        --default-character-set=utf8mb4
        --no-tablespaces
        --max-allowed-packet=512M
    )
    # MySQL 8 writes column statistics a MariaDB server cannot read back, and
    # the option does not exist in the MariaDB tools, so it is passed only to
    # a tool that advertises it. The same tool records the GTID state of a
    # replication source as SET @@GLOBAL.GTID_PURGED, which MariaDB refuses.
    if kvs_tool_advertises "$DB_DUMP_TOOL" "column-statistics"; then
        DUMP_ARGS+=(--column-statistics=0)
    fi
    if kvs_tool_advertises "$DB_DUMP_TOOL" "set-gtid-purged"; then
        DUMP_ARGS+=(--set-gtid-purged=OFF)
    fi
    # No --routines: KVS has none and the site user rarely has the privilege.
    # No --databases: the importer drops CREATE DATABASE and USE anyway.
    DUMP_ARGS+=("${DB_CONN_ARGS[@]}" "$DB_NAME")
}

# Write the compressed dump on stdout. pipefail carries a failure of the
# dump tool through the compressor, so a truncated dump is an error.
kvs_stream_dump() {
    (
        # shellcheck disable=SC2031  # Same deliberate subshell as the probe.
        export MYSQL_PWD="$DB_PASSWORD"
        kvs_ignore_user_option_files
        "$DB_DUMP_TOOL" "${DUMP_ARGS[@]}" < /dev/null
    ) | "${COMPRESS_CMD[@]}"
}

kvs_require_dump_tool() {
    if [ "$DB_OK" != "yes" ]; then
        kvs_error "the database is not reachable: $DB_ERROR"
        return 3
    fi
    if [ -z "$DB_DUMP_TOOL" ]; then
        kvs_error "no mariadb-dump or mysqldump on this server, the database cannot be exported"
        return 3
    fi
    return 0
}

#################################################################
# Output
#################################################################

kvs_print_detect() {
    printf 'kvs_export=1\n'
    printf 'site_dir=%s\n' "$SITE_DIR"
    printf 'kvs_version=%s\n' "$KVS_VERSION"
    printf 'project_url=%s\n' "$PROJECT_URL"
    printf 'domain=%s\n' "$DOMAIN"
    printf 'project_path=%s\n' "$PROJECT_PATH"
    printf 'tables_prefix=%s\n' "$TABLES_PREFIX"
    printf 'tables_prefix_multi=%s\n' "$TABLES_PREFIX_MULTI"
    printf 'db_host=%s\n' "$DB_HOST_RAW"
    printf 'db_name=%s\n' "$DB_NAME"
    printf 'db_user=%s\n' "$DB_USER"
    printf 'db_password_hint=%s\n' "$DB_PASSWORD_HINT"
    printf 'db_client=%s\n' "$DB_CLIENT"
    printf 'db_dump_tool=%s\n' "$DB_DUMP_TOOL"
    printf 'db_ok=%s\n' "$DB_OK"
    if [ "$DB_OK" != "yes" ]; then
        printf 'db_error=%s\n' "$DB_ERROR"
    fi
    printf 'db_server_version=%s\n' "$DB_SERVER_VERSION"
    printf 'db_tables=%s\n' "$DB_TABLES"
    printf 'db_size_mb=%s\n' "$DB_SIZE_MB"
    printf 'db_non_transactional=%s\n' "$DB_NON_TRANSACTIONAL"
    printf 'site_size_mb=%s\n' "$SITE_SIZE_MB"
    printf 'site_size_status=%s\n' "$SITE_SIZE_STATUS"
    printf 'site_size_seconds=%s\n' "$SITE_SIZE_SECONDS"
    printf 'site_size_entries=%s\n' "$SITE_SIZE_ENTRIES"
    printf 'site_size_entries_total=%s\n' "$SITE_SIZE_ENTRIES_TOTAL"
    printf 'site_fs_used_mb=%s\n' "$SITE_FS_USED_MB"
    printf 'site_total_mb=%s\n' "$SITE_TOTAL_MB"
    printf 'compressor=%s\n' "$COMPRESSOR"
    printf 'rsync=%s\n' "$HAS_RSYNC"
    printf 'hostname=%s\n' "$HOST_NAME"
    kvs_print_entry_lines
}

# The entries, the patterns of what stays behind and the storage servers,
# numbered: entry_N=path|megabytes|kind|copied or excluded (the megabytes
# empty when the walk counted nothing apart), exclude_N=pattern,
# server_N=title|path|remote|inside or outside|url.
kvs_print_entry_lines() {
    local i=0

    while [ "$i" -lt "${#ENTRY_PATHS[@]}" ]; do
        printf 'entry_%s=%s|%s|%s|%s\n' "$((i + 1))" "${ENTRY_PATHS[$i]}" "${ENTRY_MB[$i]}" "${ENTRY_KIND[$i]}" "${ENTRY_STATE[$i]}"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "${#EXCLUDE_PATTERNS[@]}" ]; do
        printf 'exclude_%s=%s\n' "$((i + 1))" "${EXCLUDE_PATTERNS[$i]}"
        i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "${#SERVER_LINES[@]}" ]; do
        printf 'server_%s=%s\n' "$((i + 1))" "${SERVER_LINES[$i]}"
        i=$((i + 1))
    done
}

kvs_print_candidates() {
    local count=${#SITE_CANDIDATES[@]}
    local i=0

    while [ "$i" -lt "$count" ]; do
        printf 'site_candidate_%s=%s\n' "$((i + 1))" "${SITE_CANDIDATES[$i]}"
        i=$((i + 1))
    done
}

kvs_print_summary() {
    kvs_say ""
    kvs_say "Installation detected on ${HOST_NAME:-this server}"
    kvs_say "  KVS version:     ${KVS_VERSION:-unknown}"
    kvs_say "  Site directory:  $SITE_DIR ($(kvs_site_size_text))"
    kvs_print_entries
    kvs_print_servers
    kvs_say "  Project URL:     ${PROJECT_URL:-unknown}"
    kvs_say "  Table prefix:    ${TABLES_PREFIX:-unknown}"
    kvs_say "  Database:        ${DB_NAME:-unknown} on ${DB_HOST_RAW:-localhost}, user ${DB_USER:-unknown}, password ${DB_PASSWORD_HINT:-<empty>}"
    if [ "$DB_OK" = "yes" ]; then
        kvs_say "  Database access: OK ($DB_SERVER_VERSION, $DB_TABLES tables, $(kvs_human_mb "$DB_SIZE_MB"))"
        if [ "$DB_NON_TRANSACTIONAL" -gt 0 ]; then
            kvs_say "  Table engines:   $DB_NON_TRANSACTIONAL tables use MyISAM or Aria, the dump locks the tables while it runs"
        fi
    else
        kvs_say "  Database access: FAILED ($DB_ERROR)"
    fi
    kvs_say "  Dump:            ${DB_DUMP_TOOL:-no dump tool found}, compressed with $COMPRESSOR"
    kvs_say ""
}

# The archive default name, and the dump default name with --dump-only.
kvs_output_base() {
    local base

    base=$DOMAIN
    if [ -z "$base" ]; then
        base=${SITE_DIR##*/}
    fi
    if [ -z "$base" ]; then
        base="kvs"
    fi
    printf './%s' "$base"
}

# In archive mode stdout can be the archive itself, so the question is asked
# through /dev/tty and a terminal on stdin or stderr is what makes the run
# interactive. No terminal at all means an unattended run: go ahead.
kvs_confirm() {
    local prompt="$1"
    local answer

    if [ "$OPT_ASSUME_YES" = "yes" ]; then
        return 0
    fi
    if [ ! -t 0 ] && [ ! -t 2 ]; then
        return 0
    fi
    if ! (: < /dev/tty) 2> /dev/null; then
        return 0
    fi
    printf '%s ' "$prompt" > /dev/tty
    read -r answer < /dev/tty || return 0
    case $answer in
        '' | y | Y | yes | YES | Yes) return 0 ;;
        *) return 1 ;;
    esac
}

kvs_write_manifest() {
    local path="$1"
    local dump_name="$2"
    local bytes="$3"

    {
        printf 'format=1\n'
        kvs_print_detect
        printf 'site=%s\n' "$KVS_ARCHIVE_SITE_DIR"
        printf 'dump=%s\n' "$dump_name"
        printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'dump_bytes=%s\n' "$bytes"
    } > "$path"
}

kvs_report_archive() {
    local path="$1"
    local bytes
    local mb

    bytes=$(kvs_file_size "$path") || bytes=0
    mb=$((bytes / 1048576))
    kvs_say ""
    kvs_say "Archive written: $path ($(kvs_human_mb "$mb"))"
    kvs_say ""
    kvs_say "Next steps:"
    kvs_say "  1. Copy the archive to the new server, for example:"
    kvs_say "       scp $path root@NEW-SERVER:/root/"
    kvs_say "  2. Run the kvs-install setup there and answer the import question"
    kvs_say "     with \"Yes, from an archive on this server\", or headless:"
    kvs_say "       IMPORT_ARCHIVE=/root/${path##*/} ./setup.sh"
}

#################################################################
# Commands
#################################################################

kvs_collect() {
    local measure_site="${1:-yes}"
    local setup="$SITE_DIR/admin/include/setup.php"
    local setup_db="$SITE_DIR/admin/include/setup_db.php"
    local version_file="$SITE_DIR/admin/include/version.php"
    local raw

    PROJECT_PATH=$(kvs_config_value "$setup" project_path)
    PROJECT_URL=$(kvs_config_value "$setup" project_url)
    TABLES_PREFIX=$(kvs_config_value "$setup" tables_prefix)
    TABLES_PREFIX_MULTI=$(kvs_config_value "$setup" tables_prefix_multi)
    DOMAIN=$(kvs_url_domain "$PROJECT_URL")
    if [ -z "$TABLES_PREFIX" ]; then
        kvs_warn "no tables_prefix in $setup"
    fi
    if [ ! -f "$version_file" ]; then
        kvs_error "$version_file is missing, $SITE_DIR does not hold a complete KVS installation"
        return 1
    fi
    KVS_VERSION=$(kvs_config_value "$version_file" project_version)
    if [ -z "$KVS_VERSION" ]; then
        kvs_warn "no project_version in $version_file"
    fi
    if [ ! -f "$setup_db" ]; then
        kvs_error "$setup_db is missing, the database credentials live there"
        return 1
    fi
    if [ ! -r "$setup_db" ]; then
        kvs_error "$setup_db is not readable by $(id -un), run this as root or give this user passwordless sudo"
        return 1
    fi
    DB_HOST_RAW=$(kvs_define_value "$setup_db" DB_HOST)
    DB_USER=$(kvs_define_value "$setup_db" DB_LOGIN)
    DB_NAME=$(kvs_define_value "$setup_db" DB_DEVICE)
    raw=$(kvs_define_value "$setup_db" DB_PASS)
    DB_PASSWORD=$(kvs_php_unescape "$raw")
    DB_PASSWORD_HINT=$(kvs_mask_password "$DB_PASSWORD")
    HOST_NAME=$(kvs_hostname)
    kvs_detect_tools
    kvs_build_connection_args
    kvs_probe_database
    kvs_probe_servers
    if [ "$measure_site" = "yes" ]; then
        kvs_measure_site
        kvs_collect_entries
    fi
    return 0
}

kvs_command_detect() {
    local status

    kvs_resolve_site_dir
    status=$?
    if [ "$status" -ne 0 ]; then
        printf 'kvs_export=1\n'
        kvs_print_candidates
        return "$status"
    fi
    if ! kvs_collect yes; then
        printf 'kvs_export=1\n'
        return 1
    fi
    kvs_print_detect
    return 0
}

kvs_command_dump() {
    kvs_resolve_site_dir || return $?
    kvs_collect no || return 1
    kvs_require_dump_tool || return $?
    kvs_build_dump_args
    kvs_compressor_args
    kvs_say "Dumping ${DB_NAME} with ${DB_DUMP_TOOL}, compressed with ${COMPRESSOR}"
    if ! kvs_stream_dump; then
        kvs_error "the dump failed, the output is incomplete"
        return 1
    fi
    return 0
}

# The tar options that leave the excluded entries out of the archive. The
# members start with the site directory name, so the patterns are anchored
# there (GNU tar; a pattern would otherwise match anywhere down the tree).
kvs_archive_excludes() {
    local pattern

    TAR_EXCLUDES=()
    [ "${#EXCLUDE_PATTERNS[@]}" -gt 0 ] || return 0
    TAR_EXCLUDES=(--anchored)
    for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        TAR_EXCLUDES+=("--exclude=${KVS_ARCHIVE_SITE_DIR}${pattern}")
    done
}

kvs_command_archive() {
    local stamp
    local output
    local needed
    local dump_name
    local dump_path
    local bytes
    local mb

    kvs_resolve_site_dir || return $?
    kvs_collect yes || return 1
    kvs_print_summary
    kvs_require_dump_tool || return $?

    stamp=$(date +%Y%m%d-%H%M)
    output=$OPT_OUTPUT
    if [ -z "$output" ]; then
        if [ "$OPT_DUMP_ONLY" = "yes" ]; then
            output="$(kvs_output_base)-kvs-export-${stamp}.$(kvs_dump_extension)"
        else
            output="$(kvs_output_base)-kvs-export-${stamp}.tar"
        fi
    fi
    if [ "$output" != "-" ]; then
        kvs_say "Output: $output"
    fi
    if ! kvs_confirm "Continue? [Y/n]"; then
        kvs_say "Aborted, nothing was written."
        return 1
    fi
    if [ "$output" != "-" ]; then
        if [ "$OPT_DUMP_ONLY" = "yes" ]; then
            needed=$DB_SIZE_MB
        else
            needed=$((SITE_SIZE_MB + DB_SIZE_MB))
            case $SITE_SIZE_STATUS in
                exact) ;;
                incomplete) kvs_warn "the site size is a lower bound, the free space check can pass on a disk that is too small" ;;
                *) kvs_warn "the site size is unknown, the free space is only checked for the dump" ;;
            esac
        fi
        kvs_check_free_space "$needed" "$output" || return 1
    fi
    kvs_build_dump_args
    kvs_compressor_args

    if [ "$OPT_DUMP_ONLY" = "yes" ]; then
        if [ "$output" = "-" ]; then
            if ! kvs_stream_dump; then
                kvs_error "the dump failed, the output is incomplete"
                return 1
            fi
            return 0
        fi
        kvs_say "Dumping ${DB_NAME} into $output"
        if ! kvs_stream_dump > "$output"; then
            kvs_error "the dump failed"
            rm -f -- "$output"
            return 1
        fi
        bytes=$(kvs_file_size "$output") || bytes=0
        mb=$((bytes / 1048576))
        kvs_say "Dump written: $output ($(kvs_human_mb "$mb"))"
        return 0
    fi

    STAGING_DIR=$(mktemp -d 2> /dev/null) || STAGING_DIR=""
    if [ -z "$STAGING_DIR" ]; then
        kvs_error "cannot create a temporary directory, set TMPDIR to a writable filesystem"
        return 1
    fi
    dump_name="database.$(kvs_dump_extension)"
    dump_path="$STAGING_DIR/$dump_name"
    kvs_say "Dumping ${DB_NAME} into $STAGING_DIR"
    if ! kvs_stream_dump > "$dump_path"; then
        kvs_error "the dump failed, the archive was not written"
        return 1
    fi
    bytes=$(kvs_file_size "$dump_path") || bytes=0
    # The site travels as a symlink the tar dereferences, so a contents
    # directory that lives on another disk is archived with the rest.
    ln -s -- "$SITE_DIR" "$STAGING_DIR/$KVS_ARCHIVE_SITE_DIR" || return 1
    kvs_write_manifest "$STAGING_DIR/$KVS_MANIFEST_NAME" "$dump_name" "$bytes" || return 1
    kvs_say "Writing the archive, this takes as long as reading the site files..."
    kvs_archive_excludes
    if [ "$output" = "-" ]; then
        if ! tar -chf - "${TAR_EXCLUDES[@]}" -C "$STAGING_DIR" "$KVS_ARCHIVE_SITE_DIR" "$dump_name" "$KVS_MANIFEST_NAME" < /dev/null; then
            kvs_error "tar failed, the archive on stdout is incomplete"
            return 1
        fi
        return 0
    fi
    if ! tar -chf "$output" "${TAR_EXCLUDES[@]}" -C "$STAGING_DIR" "$KVS_ARCHIVE_SITE_DIR" "$dump_name" "$KVS_MANIFEST_NAME" < /dev/null; then
        kvs_error "tar failed"
        rm -f -- "$output"
        return 1
    fi
    kvs_report_archive "$output"
    return 0
}

#################################################################
# Entry point
#################################################################

# A path for --exclude or --include: relative to the site directory, plain
# (no .., no wildcard, no space or |, which the report and the transfer
# could not carry).
kvs_add_path_option() {
    local option="$1"
    local path="$2"

    path=${path#/}
    path=${path%/}
    if [ -z "$path" ] || [ "$path" = "." ]; then
        kvs_error "$option: the whole site cannot be named"
        return 1
    fi
    local forbidden='[]|*?[[:space:]]'
    if [[ "$path" =~ $forbidden ]] || [[ "$path" == ".." || "$path" == ../* || "$path" == */.. || "$path" == */../* ]]; then
        kvs_error "$option: '$path' must be a plain path relative to the site directory (no .., wildcard, space or |)"
        return 1
    fi
    if [ "$option" = "--exclude" ]; then
        OPT_EXCLUDES+=("$path")
    else
        OPT_INCLUDES+=("$path")
    fi
    return 0
}

kvs_parse_arguments() {
    local first=""
    local second=""
    local count=0

    while [ $# -gt 0 ]; do
        case $1 in
            -o | --output)
                if [ $# -lt 2 ]; then
                    kvs_error "$1 needs a path"
                    return 1
                fi
                OPT_OUTPUT=$2
                shift 2
                ;;
            --output=*)
                OPT_OUTPUT=${1#--output=}
                shift
                ;;
            --dump-only)
                OPT_DUMP_ONLY="yes"
                shift
                ;;
            --gzip)
                OPT_FORCE_GZIP="yes"
                shift
                ;;
            --size-timeout)
                if [ $# -lt 2 ]; then
                    kvs_error "$1 needs a number of seconds"
                    return 1
                fi
                OPT_SIZE_TIMEOUT=$2
                shift 2
                ;;
            --size-timeout=*)
                OPT_SIZE_TIMEOUT=${1#--size-timeout=}
                shift
                ;;
            --no-size)
                OPT_MEASURE_SIZE="no"
                shift
                ;;
            --exclude | --include)
                if [ $# -lt 2 ]; then
                    kvs_error "$1 needs a path relative to the site directory"
                    return 1
                fi
                kvs_add_path_option "$1" "$2" || return 1
                shift 2
                ;;
            --exclude=*)
                kvs_add_path_option --exclude "${1#--exclude=}" || return 1
                shift
                ;;
            --include=*)
                kvs_add_path_option --include "${1#--include=}" || return 1
                shift
                ;;
            -y | --yes)
                OPT_ASSUME_YES="yes"
                shift
                ;;
            -h | --help)
                kvs_usage
                exit 0
                ;;
            --)
                shift
                while [ $# -gt 0 ]; do
                    count=$((count + 1))
                    case $count in
                        1) first=$1 ;;
                        2) second=$1 ;;
                        *)
                            kvs_error "unexpected argument: $1"
                            return 1
                            ;;
                    esac
                    shift
                done
                ;;
            -*)
                kvs_error "unknown option: $1"
                kvs_usage >&2
                return 1
                ;;
            *)
                count=$((count + 1))
                case $count in
                    1) first=$1 ;;
                    2) second=$1 ;;
                    *)
                        kvs_error "unexpected argument: $1"
                        return 1
                        ;;
                esac
                shift
                ;;
        esac
    done
    if ! kvs_is_number "$OPT_SIZE_TIMEOUT"; then
        kvs_error "--size-timeout needs a number of seconds, got '$OPT_SIZE_TIMEOUT'"
        return 1
    fi
    case $first in
        archive | detect | dump)
            OPT_COMMAND=$first
            OPT_SITE_DIR=$second
            ;;
        '')
            if [ -n "$second" ]; then
                kvs_error "unexpected argument: $second"
                return 1
            fi
            ;;
        *)
            if [ -n "$second" ]; then
                kvs_error "unexpected argument: $second"
                return 1
            fi
            OPT_SITE_DIR=$first
            ;;
    esac
    return 0
}

main() {
    kvs_parse_arguments "$@" || return 1
    case $OPT_COMMAND in
        detect) kvs_command_detect ;;
        dump) kvs_command_dump ;;
        archive) kvs_command_archive ;;
        *)
            kvs_error "unknown command: $OPT_COMMAND"
            return 1
            ;;
    esac
}

trap kvs_cleanup EXIT
main "$@"; exit $?
