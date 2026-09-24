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
COMPRESSOR=""
HAS_RSYNC="no"
HOST_NAME=""
SITE_CANDIDATES=()
DB_CONN_ARGS=()
DUMP_ARGS=()
COMPRESS_CMD=()

# Removed by the exit trap
STAGING_DIR=""
TEMP_ERR_FILE=""

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
  -y, --yes           Do not ask for confirmation
  -h, --help          Show this help

Environment
  KVS_SITE_DIR              Site directory, same as the argument
  KVS_EXPORT_SEARCH_ROOTS   Colon separated roots to search for the site
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
    else
        printf '%s.%s GB' "$((mb / 1024))" "$(((mb * 10 / 1024) % 10))"
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

# du follows the symbolic links, as the archive and the transfer do: a
# contents directory living on another disk counts with what it holds. The
# free space check keeps a tenth of margin on top.
kvs_measure_site() {
    local raw

    kvs_say "Measuring the site size, this can take a while on a large installation..."
    # shellcheck disable=SC2217  # stdin is the script itself under bash -s.
    raw=$(du -sLm -- "$SITE_DIR" 2> /dev/null < /dev/null || true)
    raw=${raw%%$'\n'*}
    raw=${raw%%[[:space:]]*}
    if kvs_is_number "$raw"; then
        SITE_SIZE_MB=$raw
    else
        SITE_SIZE_MB="0"
        kvs_warn "could not measure the size of $SITE_DIR"
    fi
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
    printf 'compressor=%s\n' "$COMPRESSOR"
    printf 'rsync=%s\n' "$HAS_RSYNC"
    printf 'hostname=%s\n' "$HOST_NAME"
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
    kvs_say "  Site directory:  $SITE_DIR ($(kvs_human_mb "$SITE_SIZE_MB"))"
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
    if [ "$measure_site" = "yes" ]; then
        kvs_measure_site
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
    if [ "$output" = "-" ]; then
        if ! tar -chf - -C "$STAGING_DIR" "$KVS_ARCHIVE_SITE_DIR" "$dump_name" "$KVS_MANIFEST_NAME" < /dev/null; then
            kvs_error "tar failed, the archive on stdout is incomplete"
            return 1
        fi
        return 0
    fi
    if ! tar -chf "$output" -C "$STAGING_DIR" "$KVS_ARCHIVE_SITE_DIR" "$dump_name" "$KVS_MANIFEST_NAME" < /dev/null; then
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
