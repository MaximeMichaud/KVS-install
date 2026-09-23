#!/bin/bash
# shellcheck disable=SC1091
set -e

#################################################################
# Debug Logging Setup
#################################################################
readonly LOG_DIR="/opt/kvs/logs"
readonly DEBUG_LOG="${LOG_DIR}/setup-debug.log"

# Import of an existing site (experimental): an archive, a directory plus a
# dump, or the old server over SSH. The functions live in lib/import.sh,
# shared with the standalone installer. Only an import needs the library,
# so a copy of this script running alone still installs a fresh site.
IMPORT_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/import.sh"
if [ -f "$IMPORT_LIB" ]; then
    # shellcheck source=lib/import.sh
    source "$IMPORT_LIB"
fi

#################################################################
# Dev mode flag parsing
# Usage: ./setup.sh --dev
# Enables: no-cache builds, self-signed SSL, skip GeoIP, auto-cleanup
DEV_MODE=false
DOCKER_BUILD_FLAGS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --dev)
            DEV_MODE=true
            shift
            ;;
        --help)
            cat << 'EOF'
KVS Docker Setup Script

USAGE:
    ./setup.sh [OPTIONS]

OPTIONS:
    --dev       Development mode (fast iteration)
                - Docker builds without cache
                - Self-signed SSL (no Let's Encrypt wait)
                - Skip GeoIP download
                - Auto-cleanup volumes
                - Skip Manticore (faster startup)
                - Bypass pre-flight warnings (disk space, internet)

    --help      Show this help message

ENVIRONMENT VARIABLES:
    PREFLIGHT_BYPASS=y    Bypass pre-flight warnings (disk space, internet)
                          Note: Critical checks (Docker, commands) cannot be bypassed
    Import an existing KVS site (experimental), one source at a time; the
    KVS archive of the same version must be in kvs-archive/. Interactive
    runs ask instead. See README, "Importing an existing site".
    IMPORT_ARCHIVE=FILE   An archive holding the site directory and its
                          database dump: zip, 7z, tar, tar.gz, tar.zst,
                          tar.xz or tar.bz2 (kvs-export.sh makes one)
    IMPORT_SITE_DIR=DIR   The site files (admin/include/setup.php), copied to
                          /var/www/<domain> unless they already are there...
    IMPORT_DB_DUMP=FILE   ... with the database dump (.sql, .sql.gz, .sql.xz
                          or .sql.zst). Both go together.
    IMPORT_REMOTE_HOST=H  The old server, reached over SSH; optional
                          IMPORT_REMOTE_PORT (22), IMPORT_REMOTE_USER (root),
                          IMPORT_REMOTE_DIR (site directory, searched for
                          when empty) and IMPORT_SSH_KEY (identity file).
                          Headless runs need key authentication, and
                          IMPORT_SSH_ACCEPT_NEW=y to trust a host key that
                          is not in known_hosts yet.

EXAMPLES:
    # Production installation
    ./setup.sh

    # Development mode (fast testing)
    ./setup.sh --dev

    # Headless production (CI/CD)
    HEADLESS=y DOMAIN=mysite.com EMAIL=admin@mysite.com ./setup.sh

    # Bypass pre-flight warnings (e.g., low disk space)
    PREFLIGHT_BYPASS=y ./setup.sh
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac
done

# Keep help and option validation available to every user, but reject any
# operational invocation before logs, network checks, or host changes.
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root" >&2
    exit 1
fi

# Create logs only after the privilege requirement has been satisfied.
mkdir -p "$LOG_DIR" 2>/dev/null || true
chmod 700 "$LOG_DIR" 2>/dev/null || true
# Remove traces created by older releases because they may contain credentials.
rm -f "${LOG_DIR}/setup-trace.log" 2>/dev/null || true

{
    echo "========================================"
    echo "KVS Docker Setup - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""
} >> "$DEBUG_LOG" 2>/dev/null || true
chmod 600 "$DEBUG_LOG" 2>/dev/null || true

if [ "$DEV_MODE" = true ]; then
    echo ""
    echo "🔧 DEV MODE ENABLED"
    echo "  • Docker builds without cache (force fresh build)"
    echo "  • Intelligent SSL: reuse Let's Encrypt if exists, else self-signed"
    echo "  • Skip GeoIP database download"
    echo "  • Auto-cleanup existing containers/volumes"
    echo "  • Skip Manticore Search (faster startup)"
    echo ""

    # Enable headless mode with dev-specific overrides
    export HEADLESS=y
    export DEV_SSL_INTELLIGENT=true  # Smart SSL detection (check existing cert)
    export GEOIP_CHOICE=2            # Skip GeoIP download
    export VOLUME_CHOICE=1           # Delete volumes (clean slate)
    export STOP_EXISTING=Y           # Always stop existing
    export DNS_CHOICE=2              # Continue anyway (localhost testing)
    export MANTICORE_CHOICE=2        # Skip Manticore
    export DOMAIN="${DOMAIN:-maximemichaud.ca}"  # Default test domain
    export EMAIL="${EMAIL:-dev@localhost.local}"

    # Docker build flags
    DOCKER_BUILD_FLAGS="--no-cache"
fi

#################################################################
# Headless mode defaults (inherit from parent kvs-install.sh)
if [[ "$HEADLESS" == "y" ]]; then
    PREFIX_CHOICE=${PREFIX_CHOICE:-1}       # 1=default (kvs-domain), 2=legacy (kvs), 3=custom
    SSL_CHOICE=${SSL_CHOICE:-1}             # 1=letsencrypt, 2=zerossl, 3=selfsigned
    DB_CHOICE=${DB_CHOICE:-1}               # 1=latest LTS (11.8)
    IONCUBE_CHOICE=${IONCUBE_CHOICE:-1}     # 1=yes, 2=no
    CACHE_CHOICE=${CACHE_CHOICE:-1}         # 1=dragonfly, 2=memcached
    VOLUME_CHOICE=${VOLUME_CHOICE:-2}       # For credential mismatch: 1=delete volume, 2=exit (safe default)
    STOP_EXISTING=${STOP_EXISTING:-Y}       # Y=stop existing containers
    DNS_CHOICE=${DNS_CHOICE:-2}             # 1=retry, 2=continue anyway, 3=exit
    GEOIP_CHOICE=${GEOIP_CHOICE:-1}         # 1=download GeoLite2-Country, 2=skip
    KEEP_VERSION=${KEEP_VERSION:-Y}         # Keep existing MariaDB version from .env by default
    SKIP_PRESS_ENTER=1                      # Skip "press enter" prompts
    # Note: PREFLIGHT_BYPASS can be set as environment variable (no default)
fi

# Import of an existing site: one source at a time (lib/import.sh).
# Interactive runs choose in the questionnaire; headless runs set the
# variables.
IMPORT_MODE=false
IMPORT_SOURCE=""
IMPORT_ARCHIVE="${IMPORT_ARCHIVE:-}"
IMPORT_SITE_DIR="${IMPORT_SITE_DIR:-}"
IMPORT_DB_DUMP="${IMPORT_DB_DUMP:-}"
IMPORT_REMOTE_HOST="${IMPORT_REMOTE_HOST:-}"
IMPORT_REMOTE_PORT="${IMPORT_REMOTE_PORT:-22}"
IMPORT_REMOTE_USER="${IMPORT_REMOTE_USER:-root}"
IMPORT_REMOTE_DIR="${IMPORT_REMOTE_DIR:-}"
IMPORT_SSH_KEY="${IMPORT_SSH_KEY:-}"
IMPORT_SSH_ACCEPT_NEW="${IMPORT_SSH_ACCEPT_NEW:-}"
IMPORT_CHOICE="${IMPORT_CHOICE:-}"
IMPORT_SOURCES_GIVEN=0
if [ -n "$IMPORT_ARCHIVE" ]; then
    IMPORT_SOURCE=archive
    IMPORT_SOURCES_GIVEN=$((IMPORT_SOURCES_GIVEN + 1))
fi
if [ -n "$IMPORT_SITE_DIR" ] || [ -n "$IMPORT_DB_DUMP" ]; then
    if [ -z "$IMPORT_SITE_DIR" ] || [ -z "$IMPORT_DB_DUMP" ]; then
        echo "ERROR: IMPORT_SITE_DIR and IMPORT_DB_DUMP must be set together" >&2
        exit 1
    fi
    IMPORT_SOURCE=directory
    IMPORT_SOURCES_GIVEN=$((IMPORT_SOURCES_GIVEN + 1))
fi
if [ -n "$IMPORT_REMOTE_HOST" ]; then
    IMPORT_SOURCE=remote
    IMPORT_SOURCES_GIVEN=$((IMPORT_SOURCES_GIVEN + 1))
fi
if [ "$IMPORT_SOURCES_GIVEN" -gt 1 ]; then
    echo "ERROR: IMPORT_ARCHIVE, IMPORT_SITE_DIR with IMPORT_DB_DUMP, and IMPORT_REMOTE_HOST are exclusive" >&2
    exit 1
fi
if [ -n "$IMPORT_SOURCE" ]; then
    IMPORT_MODE=true
fi
IMPORT_SITE_VERSION=""
IMPORT_OLD_PATH=""
IMPORT_DETECTED_DOMAIN=""
IMPORT_DUMP_TABLES=""
IMPORT_STAGED_DUMP=""
IMPORT_RAW_DUMP=""
IMPORT_TOKEN=""
IMPORT_VOLUME_TO_DELETE=""
IMPORT_ARCHIVE_COMMAND=""
IMPORT_ARCHIVE_ROOT=""
IMPORT_ARCHIVE_DUMP=""
IMPORT_ARCHIVE_MANIFEST=""
IMPORT_ARCHIVE_MB=""
IMPORT_ARCHIVE_IGNORED=""
IMPORT_REMOTE_RSYNC=""
IMPORT_REMOTE_COMPRESSOR=""
IMPORT_REMOTE_REPORT=""
# Raw dumps taken out of an archive or received from the old server wait
# here, outside the webroot, until they are prepared for MariaDB; the
# marker that binds /var/www/<domain> to its source lives here too.
IMPORT_STAGING="$(pwd)/import"
# shellcheck disable=SC2034  # Read by docker/lib/import.sh.
IMPORT_MARKER_DIR="$IMPORT_STAGING"
IMPORT_EXPORTER="$(dirname "${BASH_SOURCE[0]}")/../kvs-export.sh"

# A completed import recorded in .env turns a repeated command line into an
# ordinary re-run; the database is replaced only on explicit consent.
import_check_completed() {
    local completed_on answer

    [ "$IMPORT_MODE" = true ] || return 0
    completed_on=$(grep '^KVS_IMPORT_COMPLETED=' .env 2>/dev/null | cut -d= -f2-) || completed_on=""
    [ -n "$completed_on" ] || return 0
    if [ "${VOLUME_CHOICE:-}" = "1" ]; then
        echo ""
        echo -e "${YELLOW}An import already completed on ${completed_on}; importing again (VOLUME_CHOICE=1 replaces the database).${NC}"
        return 0
    fi
    if [ "${HEADLESS:-}" != "y" ]; then
        echo ""
        echo -e "${YELLOW}An import already completed on ${completed_on}.${NC}"
        echo -n "Import again and replace the database? [y/N]: "
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            VOLUME_CHOICE=1
            return 0
        fi
    fi
    echo ""
    echo -e "${YELLOW}An import already completed on ${completed_on}; the import source is ignored for this run.${NC}"
    echo "Run again with VOLUME_CHOICE=1 to replace the database and import again."
    IMPORT_MODE=false
    IMPORT_SOURCE=""
}

# The questionnaire: which source, then what it holds. Headless runs come
# here with the source already chosen through the environment.
select_import_source() {
    local answer

    if [ -z "$IMPORT_SOURCE" ] && [ "${HEADLESS:-}" != "y" ]; then
        echo ""
        echo -e "${CYAN}Import an existing KVS site (experimental)?${NC}"
        echo "  1) No, install a fresh site (default)"
        echo "  2) Yes, from an archive on this server (zip, 7z, tar)"
        echo "  3) Yes, from a directory and a database dump on this server"
        echo "  4) Yes, from the old server over SSH"
        if [[ ! "$IMPORT_CHOICE" =~ ^[1-4]$ ]]; then
            echo -n "Select [1-4] (default: 1): "
            read -r IMPORT_CHOICE
            IMPORT_CHOICE=${IMPORT_CHOICE:-1}
        fi
        case "$IMPORT_CHOICE" in
            2)
                IMPORT_SOURCE=archive
                while [ -z "$IMPORT_ARCHIVE" ]; do
                    echo -n "Path to the archive: "
                    read -r IMPORT_ARCHIVE
                done
                ;;
            3)
                IMPORT_SOURCE=directory
                while [ -z "$IMPORT_SITE_DIR" ]; do
                    echo -n "Path to the site directory (the one holding admin/include/setup.php): "
                    read -r IMPORT_SITE_DIR
                done
                while [ -z "$IMPORT_DB_DUMP" ]; do
                    echo -n "Path to the database dump (.sql, .sql.gz, .sql.xz or .sql.zst): "
                    read -r IMPORT_DB_DUMP
                done
                ;;
            4)
                IMPORT_SOURCE=remote
                while [ -z "$IMPORT_REMOTE_HOST" ]; do
                    echo -n "Old server host name or IP address: "
                    read -r IMPORT_REMOTE_HOST
                done
                echo -n "SSH port [22]: "
                read -r answer
                IMPORT_REMOTE_PORT=${answer:-22}
                echo -n "SSH user [root]: "
                read -r answer
                IMPORT_REMOTE_USER=${answer:-root}
                echo -n "SSH private key file (empty: your usual keys, or the password ssh asks for): "
                read -r IMPORT_SSH_KEY
                echo -n "Site directory on the old server (empty: search for it): "
                read -r IMPORT_REMOTE_DIR
                ;;
            *)
                return 0
                ;;
        esac
        IMPORT_MODE=true
    fi
    [ "$IMPORT_MODE" = true ] || return 0
    import_check_completed
    [ "$IMPORT_MODE" = true ] || return 0
    if ! declare -F import_validate_site >/dev/null; then
        echo -e "${RED}ERROR: the import library $IMPORT_LIB is missing; run setup.sh from a full checkout of the repository${NC}"
        exit 1
    fi
    echo ""
    echo -e "${CYAN}Import of an existing KVS site (experimental)${NC}"
    case "$IMPORT_SOURCE" in
        archive) import_inspect_archive ;;
        directory) import_inspect_directory ;;
        remote) import_inspect_remote ;;
    esac
    import_check_kvs_archive_version
    import_check_domain
    import_confirm
}

# The site and the dump, once both are on this server: version, prefix,
# tables, and whether the dump ends where the dump tool left it.
import_validate_local_materials() {
    local site_info dump_info dump_initial_version dump_statements dump_completed

    site_info=$(import_validate_site "$IMPORT_SITE_DIR") || exit 1
    IMPORT_SITE_VERSION=$(import_field "$site_info" 1)
    IMPORT_OLD_PATH=$(import_field "$site_info" 2)
    IMPORT_DETECTED_DOMAIN=$(import_url_domain "$(import_read_php_config_value "$IMPORT_SITE_DIR/admin/include/setup.php" project_url)")
    echo "  Site: $IMPORT_SITE_DIR (KVS $IMPORT_SITE_VERSION, project path $IMPORT_OLD_PATH)"
    import_check_site_links
    dump_info=$(import_inspect_dump "$IMPORT_DB_DUMP" ktvs_) || exit 1
    IMPORT_DUMP_TABLES=$(import_field "$dump_info" 1)
    dump_initial_version=$(import_field "$dump_info" 2)
    dump_statements=$(import_field "$dump_info" 3)
    dump_completed=$(import_field "$dump_info" 4)
    if [ "${IMPORT_DUMP_TABLES:-0}" -lt 1 ]; then
        echo -e "${RED}ERROR: $IMPORT_DB_DUMP holds no CREATE TABLE for the ktvs_ tables${NC}"
        exit 1
    fi
    echo "  Database dump: $IMPORT_DB_DUMP ($IMPORT_DUMP_TABLES tables, INITIAL_VERSION ${dump_initial_version:-missing, recorded as $IMPORT_SITE_VERSION})"
    if [ "$dump_completed" != yes ]; then
        if [ "$IMPORT_SOURCE" = remote ]; then
            echo -e "${RED}ERROR: the dump does not end with the completion line of the dump tool; the transfer broke off${NC}"
            exit 1
        fi
        echo -e "  ${YELLOW}The dump does not end with the 'Dump completed' line mariadb-dump writes; make sure it is complete.${NC}"
    fi
    if [ "${dump_statements:-0}" -gt 0 ]; then
        echo "  $dump_statements CREATE DATABASE/USE statements will be dropped (the dump loads into the $DOMAIN database)"
    fi
    if [ "$IMPORT_OLD_PATH" != "/var/www/kvs" ]; then
        echo "  Server paths: $IMPORT_OLD_PATH -> /var/www/kvs"
    fi
}

# Symbolic links that leave the site directory resolve on this server at
# best and never in the container, which mounts the site directory alone.
# The copy the setup makes from a directory follows them (rsync brings
# their targets); a site already in place or extracted from an archive
# keeps them as they are and has to be fixed first.
import_check_site_links() {
    local links count

    links=$(import_external_links "$IMPORT_SITE_DIR" | head -n 6)
    [ -n "$links" ] || return 0
    count=$(printf '%s\n' "$links" | wc -l)
    if [ "$count" -gt 5 ]; then
        links=$(printf '%s\n' "$links" | head -n 5; echo "...")
    fi
    if [ "$IMPORT_SOURCE" = directory ] && [ "$(readlink -f -- "$IMPORT_SITE_DIR")" != "$(readlink -f -- "/var/www/$DOMAIN" 2>/dev/null)" ] &&
        ! printf '%s\n' "$links" | grep -q '(dangling)$'; then
        echo "  Symbolic links leaving the site are copied with their targets:"
        printf '%s\n' "$links" | sed 's/^/    /'
        return 0
    fi
    echo -e "${RED}ERROR: symbolic links in $IMPORT_SITE_DIR point outside the site or nowhere; the container mounts the site directory alone, so they would break there:${NC}"
    printf '%s\n' "$links" | sed 's/^/    /'
    echo "Replace them by copies of their targets (cp -a --dereference), remove the dangling ones, or mount the targets in docker-compose.override.yml, then run the setup again."
    exit 1
}

import_inspect_directory() {
    import_validate_local_materials
    if [ "$(readlink -f -- "$IMPORT_SITE_DIR")" = "$(readlink -f -- "/var/www/$DOMAIN" 2>/dev/null)" ]; then
        echo "  Files: already in /var/www/$DOMAIN"
    else
        if ! import_free_space_ok "$IMPORT_SITE_DIR" "/var/www/$DOMAIN"; then
            echo -e "${RED}ERROR: not enough free space to copy $IMPORT_SITE_DIR to /var/www/$DOMAIN${NC}"
            exit 1
        fi
        import_destination_ready "/var/www/$DOMAIN" "$(readlink -f -- "$IMPORT_SITE_DIR")" || exit 1
        echo "  Files: copied to /var/www/$DOMAIN"
    fi
}

# An archive is listed and analysed before anything is extracted: the site
# root, the dump, the uncompressed size, and nothing else that would land
# in the webroot. The configuration files come out alone for the checks.
import_inspect_archive() {
    local listing analysis peek site_info

    if [ ! -f "$IMPORT_ARCHIVE" ]; then
        echo -e "${RED}ERROR: IMPORT_ARCHIVE is not a file: $IMPORT_ARCHIVE${NC}"
        exit 1
    fi
    IMPORT_ARCHIVE=$(readlink -f -- "$IMPORT_ARCHIVE")
    IMPORT_ARCHIVE_COMMAND=$(import_archive_tools "$IMPORT_ARCHIVE") || exit 1
    echo "  Reading the archive listing..."
    listing=$(mktemp) || exit 1
    if ! import_archive_list "$IMPORT_ARCHIVE" "$IMPORT_ARCHIVE_COMMAND" > "$listing"; then
        rm -f "$listing"
        echo -e "${RED}ERROR: could not list $IMPORT_ARCHIVE${NC}"
        exit 1
    fi
    analysis=$(import_archive_analyze "$listing") || { rm -f "$listing"; exit 1; }
    rm -f "$listing"
    IMPORT_ARCHIVE_ROOT=$(import_field "$analysis" 1)
    IMPORT_ARCHIVE_DUMP=$(import_field "$analysis" 2)
    IMPORT_ARCHIVE_MANIFEST=$(import_field "$analysis" 3)
    IMPORT_ARCHIVE_MB=$(import_field "$analysis" 4)
    IMPORT_ARCHIVE_IGNORED=$(import_field "$analysis" 5)
    peek=$(mktemp -d) || exit 1
    if ! import_archive_peek "$IMPORT_ARCHIVE" "$IMPORT_ARCHIVE_COMMAND" "$IMPORT_ARCHIVE_ROOT" "$peek"; then
        rm -rf "$peek"
        echo -e "${RED}ERROR: could not read admin/include/setup.php, setup_db.php and version.php from the archive${NC}"
        exit 1
    fi
    site_info=$(import_validate_site "$peek") || { rm -rf "$peek"; exit 1; }
    IMPORT_SITE_VERSION=$(import_field "$site_info" 1)
    IMPORT_OLD_PATH=$(import_field "$site_info" 2)
    IMPORT_DETECTED_DOMAIN=$(import_url_domain "$(import_read_php_config_value "$peek/admin/include/setup.php" project_url)")
    rm -rf "$peek"
    echo "  Archive: $IMPORT_ARCHIVE (${IMPORT_ARCHIVE_MB} MB uncompressed)"
    echo "  Site: ${IMPORT_ARCHIVE_ROOT:-at the top of the archive} (KVS $IMPORT_SITE_VERSION, project path $IMPORT_OLD_PATH)"
    echo "  Database dump: $IMPORT_ARCHIVE_DUMP"
    if [ -n "$IMPORT_ARCHIVE_IGNORED" ]; then
        echo "  Ignored (not part of the site): $IMPORT_ARCHIVE_IGNORED"
    fi
    if ! import_free_space_mb_ok "$IMPORT_ARCHIVE_MB" "/var/www/$DOMAIN"; then
        echo -e "${RED}ERROR: not enough free space to extract ${IMPORT_ARCHIVE_MB} MB into /var/www/$DOMAIN${NC}"
        exit 1
    fi
    import_destination_ready "/var/www/$DOMAIN" "archive:$IMPORT_ARCHIVE" || exit 1
    echo "  Files: extracted into /var/www/$DOMAIN"
    if [ "$IMPORT_OLD_PATH" != "/var/www/kvs" ]; then
        echo "  Server paths: $IMPORT_OLD_PATH -> /var/www/kvs"
    fi
}

# The old server answers through kvs-export.sh, piped over one SSH
# connection: what it holds, whether its database answers, what tools it
# has. Nothing is written or installed there.
import_inspect_remote() {
    local batch=no accept_new=no attempt=1 prefix db_ok

    if [ ! -f "$IMPORT_EXPORTER" ]; then
        echo -e "${RED}ERROR: $IMPORT_EXPORTER is missing; run setup.sh from a full checkout of the repository${NC}"
        exit 1
    fi
    if [ "${HEADLESS:-}" = "y" ]; then
        batch=yes
    fi
    import_ensure_tool ssh || exit 1
    case "${IMPORT_SSH_ACCEPT_NEW,,}" in
        y|yes|true) accept_new=yes ;;
        *) accept_new=no ;;
    esac
    import_ssh_setup "$IMPORT_REMOTE_HOST" "$IMPORT_REMOTE_PORT" "$IMPORT_REMOTE_USER" "$IMPORT_SSH_KEY" "$batch" "$accept_new" || exit 1
    trap import_ssh_close EXIT
    echo "  Connecting to $IMPORT_SSH_TARGET (port $IMPORT_REMOTE_PORT)..."
    if ! import_remote_privileges; then
        echo -e "${RED}ERROR: cannot run a command on $IMPORT_SSH_TARGET (see the messages above)${NC}"
        exit 1
    fi
    IMPORT_REMOTE_REPORT="$LOG_DIR/import-remote.txt"
    rm -f "$IMPORT_REMOTE_REPORT"
    while :; do
        echo "  Looking for the site on $IMPORT_SSH_TARGET..."
        if import_remote_detect "$IMPORT_EXPORTER" "$IMPORT_REMOTE_DIR" "$IMPORT_REMOTE_REPORT"; then
            break
        fi
        if grep -q '^site_candidate_1=' "$IMPORT_REMOTE_REPORT" 2>/dev/null; then
            echo -e "${YELLOW}Several KVS sites were found on the old server:${NC}"
            sed -n 's/^site_candidate_[0-9]*=/    /p' "$IMPORT_REMOTE_REPORT"
            if [ "${HEADLESS:-}" = "y" ] || [ "$attempt" -ge 3 ]; then
                echo -e "${RED}ERROR: set IMPORT_REMOTE_DIR to the one to import${NC}"
                exit 1
            fi
            echo -n "Site directory on the old server: "
            read -r IMPORT_REMOTE_DIR
            attempt=$((attempt + 1))
            continue
        fi
        echo -e "${RED}ERROR: the detection on $IMPORT_SSH_TARGET failed (see the messages above)${NC}"
        exit 1
    done
    chmod 600 "$IMPORT_REMOTE_REPORT" 2>/dev/null || true
    if [ "$(import_kv "$IMPORT_REMOTE_REPORT" kvs_export)" != "1" ]; then
        echo -e "${RED}ERROR: unexpected answer from the old server (kvs-export.sh did not run)${NC}"
        exit 1
    fi
    IMPORT_REMOTE_DIR=$(import_kv "$IMPORT_REMOTE_REPORT" site_dir)
    IMPORT_SITE_VERSION=$(import_kv "$IMPORT_REMOTE_REPORT" kvs_version)
    IMPORT_OLD_PATH=$(import_kv "$IMPORT_REMOTE_REPORT" project_path)
    IMPORT_DETECTED_DOMAIN=$(import_kv "$IMPORT_REMOTE_REPORT" domain)
    IMPORT_REMOTE_RSYNC=$(import_kv "$IMPORT_REMOTE_REPORT" rsync)
    IMPORT_REMOTE_COMPRESSOR=$(import_kv "$IMPORT_REMOTE_REPORT" compressor)
    prefix=$(import_kv "$IMPORT_REMOTE_REPORT" tables_prefix)
    db_ok=$(import_kv "$IMPORT_REMOTE_REPORT" db_ok)
    echo ""
    echo -e "${GREEN}Installation detected on $IMPORT_REMOTE_HOST${NC}"
    case "$IMPORT_REMOTE_PRIVILEGES" in
        root) echo "  SSH user:        $IMPORT_REMOTE_USER (root)" ;;
        sudo) echo "  SSH user:        $IMPORT_REMOTE_USER (passwordless sudo, used for the dump and the files)" ;;
        *) echo -e "  SSH user:        $IMPORT_REMOTE_USER ${YELLOW}(neither root nor passwordless sudo${IMPORT_REMOTE_SUDO_ERROR:+: $IMPORT_REMOTE_SUDO_ERROR}; files it cannot read stay behind)${NC}" ;;
    esac
    echo "  KVS version:     ${IMPORT_SITE_VERSION:-unknown}"
    echo "  Site directory:  $IMPORT_REMOTE_DIR ($(import_kv "$IMPORT_REMOTE_REPORT" site_size_mb) MB)"
    echo "  Project URL:     $(import_kv "$IMPORT_REMOTE_REPORT" project_url)"
    echo "  Table prefix:    ${prefix:-unknown}"
    echo "  Database:        $(import_kv "$IMPORT_REMOTE_REPORT" db_name) on $(import_kv "$IMPORT_REMOTE_REPORT" db_host), user $(import_kv "$IMPORT_REMOTE_REPORT" db_user), password $(import_kv "$IMPORT_REMOTE_REPORT" db_password_hint)"
    if [ "$db_ok" = yes ]; then
        echo "  Database access: OK ($(import_kv "$IMPORT_REMOTE_REPORT" db_server_version), $(import_kv "$IMPORT_REMOTE_REPORT" db_tables) tables, $(import_kv "$IMPORT_REMOTE_REPORT" db_size_mb) MB)"
    else
        echo -e "  Database access: ${RED}failed${NC} ($(import_kv "$IMPORT_REMOTE_REPORT" db_error))"
    fi
    if [ "$IMPORT_REMOTE_RSYNC" = yes ]; then
        echo "  Transfer:        rsync, dump compressed with ${IMPORT_REMOTE_COMPRESSOR:-gzip}"
    else
        echo "  Transfer:        tar over ssh (install rsync on the old server for progress and resumable transfers), dump compressed with ${IMPORT_REMOTE_COMPRESSOR:-gzip}"
    fi
    if [ "$(import_kv "$IMPORT_REMOTE_REPORT" db_non_transactional)" -gt 0 ] 2>/dev/null; then
        echo -e "  ${YELLOW}$(import_kv "$IMPORT_REMOTE_REPORT" db_non_transactional) tables use MyISAM or Aria: the dump locks the tables while it runs, writes on the old site wait.${NC}"
    fi
    if [ -z "$IMPORT_SITE_VERSION" ] || [ -z "$IMPORT_OLD_PATH" ]; then
        echo -e "${RED}ERROR: the KVS version or the project path could not be read on the old server${NC}"
        exit 1
    fi
    if [ "$prefix" != "ktvs_" ]; then
        echo -e "${RED}ERROR: the site uses the table prefix '${prefix:-<empty>}'; the Docker init only supports ktvs_${NC}"
        exit 1
    fi
    if [ "$db_ok" != yes ]; then
        echo -e "${RED}ERROR: the database of the old server does not answer; fix the access there, or dump it yourself and use IMPORT_SITE_DIR with IMPORT_DB_DUMP${NC}"
        exit 1
    fi
    if ! import_free_space_mb_ok "$(( $(import_kv "$IMPORT_REMOTE_REPORT" site_size_mb) + $(import_kv "$IMPORT_REMOTE_REPORT" db_size_mb) ))" "/var/www/$DOMAIN"; then
        echo -e "${RED}ERROR: not enough free space for the site and its dump under /var/www/$DOMAIN${NC}"
        exit 1
    fi
    import_destination_ready "/var/www/$DOMAIN" "ssh://$IMPORT_SSH_TARGET:$IMPORT_REMOTE_PORT$IMPORT_REMOTE_DIR" || exit 1
    if [ "$IMPORT_REMOTE_RSYNC" = yes ]; then
        import_ensure_tool rsync || exit 1
    fi
    if [ "$IMPORT_REMOTE_COMPRESSOR" = zstd ]; then
        import_ensure_tool zstd || exit 1
    fi
    if [ "$IMPORT_OLD_PATH" != "/var/www/kvs" ]; then
        echo "  Server paths:    $IMPORT_OLD_PATH -> /var/www/kvs"
    fi
}

# The nginx rewrites and the PHP version come from the KVS archive, so the
# archive in kvs-archive/ must be the version of the imported site.
import_check_kvs_archive_version() {
    local archive archive_version

    archive=$(find kvs-archive -maxdepth 1 -name 'KVS_*.zip' -type f 2>/dev/null | head -n 1)
    if [ -z "$archive" ]; then
        echo -e "${RED}ERROR: the KVS archive of version $IMPORT_SITE_VERSION must be in kvs-archive/ (nginx rewrites and PHP version come from it)${NC}"
        exit 1
    fi
    archive_version=$(import_archive_version "$archive")
    if [ "$archive_version" != "$IMPORT_SITE_VERSION" ]; then
        echo -e "${RED}ERROR: $(basename "$archive") is KVS ${archive_version:-of unknown version} while the site is KVS $IMPORT_SITE_VERSION; use the archive of the same version${NC}"
        exit 1
    fi
}

# The KVS license is bound to the domain: a site configured for another
# one is most likely a mistake, and needs a new archive otherwise.
import_check_domain() {
    local answer

    [ -n "$IMPORT_DETECTED_DOMAIN" ] || return 0
    [ "$IMPORT_DETECTED_DOMAIN" != "$DOMAIN" ] || return 0
    echo ""
    echo -e "${YELLOW}WARNING: the site is configured for $IMPORT_DETECTED_DOMAIN while this installation is for $DOMAIN.${NC}"
    echo "The KVS license is bound to the domain; the site keeps working only with an archive issued for $DOMAIN."
    if [ "${HEADLESS:-}" != "y" ]; then
        echo -n "Continue anyway? [y/N]: "
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            echo "Import cancelled."
            exit 0
        fi
    fi
}

import_confirm() {
    local answer

    echo ""
    echo "The files go to /var/www/$DOMAIN and the database replaces the one of this installation."
    echo "If the DNS still points at the old server, choose the self-signed certificate now and run the setup again after the switch."
    [ "${HEADLESS:-}" != "y" ] || return 0
    echo -n "Continue with this site? [Y/n]: "
    read -r answer
    if [[ "$answer" =~ ^[Nn]$ ]]; then
        echo "Import cancelled."
        exit 0
    fi
}

# The source is materialized before anything is built: a failed transfer
# or extraction then costs nothing else. The directory source is copied
# later, while MariaDB replays the dump.
import_fetch_source() {
    [ "$IMPORT_MODE" = true ] || return 0
    case "$IMPORT_SOURCE" in
        archive) import_fetch_archive ;;
        remote) import_fetch_remote ;;
        *) return 0 ;;
    esac
    echo ""
    import_validate_local_materials
}

# The archive is unpacked in a private directory next to the site, then
# the site's entries are renamed into place: nothing the archive holds
# besides the site ever sits in the webroot, and the dump never does.
import_fetch_archive() {
    local destination="/var/www/$DOMAIN" stage settled

    echo ""
    echo -e "${CYAN}Extracting $IMPORT_ARCHIVE into $destination...${NC}"
    import_destination_ready "$destination" "archive:$IMPORT_ARCHIVE" || exit 1
    import_mark_destination "$destination" "archive:$IMPORT_ARCHIVE" || exit 1
    stage=$(import_stage_dir_for "$destination")
    rm -rf -- "$stage"
    mkdir -p "$stage" && chmod 700 "$stage" || exit 1
    if ! import_archive_extract "$IMPORT_ARCHIVE" "$IMPORT_ARCHIVE_COMMAND" "$stage"; then
        echo -e "${RED}ERROR: the extraction failed${NC}"
        exit 1
    fi
    mkdir -p "$IMPORT_STAGING" && chmod 700 "$IMPORT_STAGING" || exit 1
    settled=$(import_archive_settle "$stage" "$IMPORT_ARCHIVE_ROOT" "$IMPORT_ARCHIVE_DUMP" "$IMPORT_ARCHIVE_MANIFEST" "$IMPORT_STAGING" "$destination") || exit 1
    IMPORT_DB_DUMP=$(import_field "$settled" 1)
    IMPORT_RAW_DUMP=$IMPORT_DB_DUMP
    IMPORT_SITE_DIR=$destination
    chmod 600 "$IMPORT_DB_DUMP" 2>/dev/null || true
    echo -e "  ${GREEN}✓${NC} Site files in $destination, dump in $IMPORT_DB_DUMP"
}

import_fetch_remote() {
    local destination="/var/www/$DOMAIN" source dump extension pid

    source="ssh://$IMPORT_SSH_TARGET:$IMPORT_REMOTE_PORT$IMPORT_REMOTE_DIR"
    extension=gz
    if [ "$IMPORT_REMOTE_COMPRESSOR" = zstd ]; then
        extension=zst
    fi
    mkdir -p "$IMPORT_STAGING" && chmod 700 "$IMPORT_STAGING" || exit 1
    dump="$IMPORT_STAGING/${DOMAIN}.sql.$extension"
    # The dump first, the files after: whatever the site creates during a
    # long transfer then exists as files the database does not know yet,
    # which is harmless, instead of rows whose files never came. A second
    # pass, once the old site is frozen, carries the changes made since.
    echo ""
    echo -e "${CYAN}Receiving the database dump from $IMPORT_SSH_TARGET...${NC}"
    rm -f "$dump"
    import_remote_dump "$IMPORT_EXPORTER" "$IMPORT_REMOTE_DIR" "$dump" &
    pid=$!
    if [ -t 1 ]; then
        import_watch_file_size "$dump" "$pid" "Received"
    fi
    if ! wait "$pid"; then
        echo -e "${RED}ERROR: the dump of the old database failed (see the messages above)${NC}"
        exit 1
    fi
    chmod 600 "$dump"
    echo -e "  ${GREEN}✓${NC} Dump received: $dump ($(du -h -- "$dump" | cut -f1))"
    echo -e "${CYAN}Transferring the site files from $IMPORT_SSH_TARGET:$IMPORT_REMOTE_DIR...${NC}"
    import_destination_ready "$destination" "$source" || exit 1
    import_mark_destination "$destination" "$source" || exit 1
    if ! import_remote_files "$IMPORT_REMOTE_DIR" "$destination" "$IMPORT_REMOTE_RSYNC"; then
        echo -e "${RED}ERROR: the file transfer failed; run the same command again to resume it${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Site files in $destination"
    import_ssh_close
    IMPORT_DB_DUMP=$dump
    IMPORT_RAW_DUMP=$dump
    IMPORT_SITE_DIR=$destination
}

KVS_ADMIN_PASSWORD_PROVIDED=false
if [ -n "${KVS_ADMIN_PASSWORD:-}" ]; then
    KVS_ADMIN_PASSWORD_PROVIDED=true
    if [ "${#KVS_ADMIN_PASSWORD}" -lt 20 ]; then
        echo "ERROR: KVS_ADMIN_PASSWORD must contain at least 20 characters" >&2
        exit 1
    fi
fi
KVS_ADMIN_PASSWORD_GENERATED=false

# KVS support access opt-out. The request is captured before .env is sourced
# so that a value stored by an earlier run cannot override an explicit one.
DISABLE_KVS_SUPPORT_ACCESS_REQUEST="${DISABLE_KVS_SUPPORT_ACCESS:-}"
case "$DISABLE_KVS_SUPPORT_ACCESS_REQUEST" in
    ''|true|false) ;;
    *)
        echo "ERROR: DISABLE_KVS_SUPPORT_ACCESS must be true or false" >&2
        exit 1
        ;;
esac

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

readonly DEBIAN_11_EOL_DATE="2026-08-31"
readonly DEBIAN_11_EOL_SOURCE="https://endoflife.date/debian"
readonly MAX_SITE_PREFIX_LENGTH=235

debian11_support_ended() {
    local today
    today=$(date +%F)
    [[ "$today" > "$DEBIAN_11_EOL_DATE" || "$today" == "$DEBIAN_11_EOL_DATE" ]]
}

check_debian11_host_support() {
    local ID=""
    local VERSION_ID=""

    if [[ ! -r /etc/os-release ]]; then
        return
    fi

    source /etc/os-release

    if [[ "$ID" != "debian" || "$VERSION_ID" != "11" ]]; then
        return
    fi

    if debian11_support_ended; then
        echo ""
        echo -e "${RED}Debian 11 (bullseye) is no longer supported by KVS-install Docker setup.${NC}"
        echo "Debian 11 LTS ended on ${DEBIAN_11_EOL_DATE}: ${DEBIAN_11_EOL_SOURCE}"
        echo "Please upgrade this host to Debian 12 (bookworm) or Debian 13 (trixie)."
        echo ""
        exit 1
    fi

    if [[ "${KVS_DEBIAN_11_NOTICE_SHOWN:-}" != "1" ]]; then
        echo ""
        echo -e "${YELLOW}Debian 11 (bullseye) is nearing end of life.${NC}"
        echo -e "${YELLOW}Debian 11 LTS ends on ${DEBIAN_11_EOL_DATE}: ${DEBIAN_11_EOL_SOURCE}${NC}"
        echo -e "${YELLOW}KVS-install support for Debian 11 will be removed on ${DEBIAN_11_EOL_DATE}.${NC}"
        echo -e "${YELLOW}Please upgrade to Debian 12 (bookworm) or Debian 13 (trixie).${NC}"
        echo ""
    fi
}

check_debian11_host_support

#################################################################
# Pre-flight Checks
#################################################################

# Check internet connectivity with multiple fallbacks
check_internet() {
    local endpoints=(
        "https://1.1.1.1"              # Cloudflare DNS (fast, reliable)
        "https://8.8.8.8"              # Google DNS (backup)
        "https://cloudflare.com/cdn-cgi/trace"  # Cloudflare trace (fast)
        "https://www.google.com"       # Google homepage (widely available)
    )

    for endpoint in "${endpoints[@]}"; do
        if curl -sf --connect-timeout 3 --max-time 5 "$endpoint" >/dev/null 2>&1; then
            return 0  # Internet OK
        fi
    done

    return 1  # All endpoints failed
}

# Detect if domain is using Cloudflare CDN (orange cloud proxy)
# NOTE: This detects PROXY (orange cloud), not just DNS nameservers
# Only orange cloud proxy provides CF-IPCountry header for GeoIP
detect_cloudflare() {
    local domain="$1"
    local cf_detected=0

    # Test multiple endpoints to avoid false negatives
    local endpoints=("$domain" "www.$domain")

    for endpoint in "${endpoints[@]}"; do
        # Try HTTPS first, fallback to HTTP
        local response
        response=$(curl -sI --max-time 5 "https://$endpoint" 2>/dev/null) || \
        response=$(curl -sI --max-time 5 "http://$endpoint" 2>/dev/null)

        if [ -z "$response" ]; then
            continue  # Try next endpoint
        fi

        # Check for Cloudflare proxy indicators (orange cloud only)
        # 1. CF-Ray - Most reliable, present on 99%+ of proxied requests
        if echo "$response" | grep -qi "^cf-ray:"; then
            cf_detected=1
            break
        fi

        # 2. Server header - Backup check (can be customized but usually present)
        if echo "$response" | grep -qi "^server:.*cloudflare"; then
            cf_detected=1
            break
        fi

        # 3. CF-Cache-Status - Present when caching is active
        if echo "$response" | grep -qi "^cf-cache-status:"; then
            cf_detected=1
            break
        fi
    done

    if [ "$cf_detected" -eq 1 ]; then
        return 0  # Cloudflare proxy detected (orange cloud)
    fi

    # Check if any endpoint was reachable
    for endpoint in "${endpoints[@]}"; do
        if curl -sf --max-time 5 "https://$endpoint" >/dev/null 2>&1 || \
           curl -sf --max-time 5 "http://$endpoint" >/dev/null 2>&1; then
            return 1  # Reachable but not using Cloudflare proxy
        fi
    done

    return 2  # Cannot reach domain
}

# Print "<free GB> <path>" for the tightest of the paths the installation
# writes to: the site directory under /var/www, the Docker root directory
# (volumes, build cache) and the containerd root (images on Docker 29). Each
# may live on a different filesystem than /, as on hosts with a small system
# disk and a large data disk. CONTAINERD_CONFIG_FILE exists for the tests.
preflight_free_disk_gb() {
    local path docker_root driver_type containerd_root free_gb min_gb="" min_path=""
    local -a paths=()
    for path in "/var/www/${DOMAIN:-}" /var/www /; do
        if [ -d "$path" ]; then
            paths+=("$path")
            break
        fi
    done
    docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
    if [ -n "$docker_root" ] && [ -d "$docker_root" ]; then
        paths+=("$docker_root")
    fi
    # Docker 29 stores images through the containerd snapshotter, under the
    # containerd root and not under the Docker root directory. Moving only
    # data-root leaves the image store on the system disk.
    driver_type=$(docker info --format '{{range .DriverStatus}}{{if eq (index . 0) "driver-type"}}{{index . 1}}{{end}}{{end}}' 2>/dev/null)
    if [[ "$driver_type" == io.containerd.snapshotter.* ]]; then
        containerd_root=$(sed -n 's/^root[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' \
            "${CONTAINERD_CONFIG_FILE:-/etc/containerd/config.toml}" 2>/dev/null | head -n 1)
        containerd_root=${containerd_root:-/var/lib/containerd}
        if [ -d "$containerd_root" ]; then
            paths+=("$containerd_root")
        fi
    fi
    for path in "${paths[@]}"; do
        free_gb=$(df -P "$path" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}')
        [ -n "$free_gb" ] || continue
        if [ -z "$min_gb" ] || (( free_gb < min_gb )); then
            min_gb=$free_gb
            min_path=$path
        fi
    done
    echo "${min_gb:-0} ${min_path:-/}"
}

# Pre-flight checks before installation
preflight_checks() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     Pre-flight Checks                            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local critical_failed=0
    local warnings=0

    # 1. Docker installed
    if command -v docker >/dev/null 2>&1; then
        local docker_version
        docker_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        echo -e "${GREEN}✓${NC} Docker installed: ${docker_version}"
    else
        echo -e "${RED}✗${NC} Docker not installed"
        echo "  Install: curl -fsSL https://get.docker.com | sh"
        critical_failed=$((critical_failed + 1))
    fi

    # 2. Docker Compose installed
    if docker compose version >/dev/null 2>&1; then
        local compose_version
        compose_version=$(docker compose version | grep -oP '\d+\.\d+\.\d+' | head -1)
        echo -e "${GREEN}✓${NC} Docker Compose installed: ${compose_version}"
    else
        echo -e "${RED}✗${NC} Docker Compose not installed"
        echo "  Docker Compose v2 is required (plugin, not standalone)"
        critical_failed=$((critical_failed + 1))
    fi

    # 3. Disk space check (can be bypassed). The site files live under
    # /var/www and the images and volumes under the Docker root directory;
    # either may sit on another filesystem than /, so measure the tightest.
    local free_gb disk_path
    read -r free_gb disk_path < <(preflight_free_disk_gb)
    if (( free_gb >= 20 )); then
        echo -e "${GREEN}✓${NC} Disk space: ${free_gb} GB available on ${disk_path}"
    elif (( free_gb >= 10 )); then
        echo -e "${YELLOW}⚠${NC} Disk space: ${free_gb} GB available on ${disk_path} (minimum 10 GB, recommended 20 GB)"
    else
        echo -e "${RED}✗${NC} Disk space: ${free_gb} GB available on ${disk_path} (need at least 10 GB)"
        warnings=$((warnings + 1))
    fi

    # 4. RAM check (informational only)
    local total_ram_mb free_ram_mb
    total_ram_mb=$(free -m | awk 'NR==2 {print $2}')
    free_ram_mb=$(free -m | awk 'NR==2 {print $7}')

    # Display in GB if >= 1024MB, otherwise in MB
    if (( total_ram_mb >= 1024 )); then
        local total_ram_gb free_ram_gb
        total_ram_gb=$((total_ram_mb / 1024))
        free_ram_gb=$((free_ram_mb / 1024))
        if (( total_ram_mb >= 2048 )); then
            echo -e "${GREEN}✓${NC} RAM: ${total_ram_gb} GB total, ${free_ram_gb} GB available"
        else
            echo -e "${YELLOW}⚠${NC} RAM: ${total_ram_gb} GB total (recommended 2 GB minimum)"
        fi
    else
        echo -e "${YELLOW}⚠${NC} RAM: ${total_ram_mb} MB total (recommended 2 GB minimum)"
    fi

    # 5. Internet connectivity (can be bypassed)
    echo -n "  Checking internet connectivity... "
    if check_internet; then
        echo -e "${GREEN}✓${NC} Connected"
    else
        echo -e "${RED}✗${NC} No internet connection"
        echo "  Internet required for downloading Docker images and dependencies"
        warnings=$((warnings + 1))
    fi

    # 6. Required commands
    local required_cmds=("curl" "unzip" "sed" "awk" "grep" "ss")
    local missing_cmds=()
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Required commands: all present"
    else
        echo -e "${RED}✗${NC} Missing commands: ${missing_cmds[*]}"
        echo "  Install: apt update && apt install -y ${missing_cmds[*]}"
        critical_failed=$((critical_failed + 1))
    fi

    echo ""

    # Handle critical failures (cannot bypass)
    if (( critical_failed > 0 )); then
        echo -e "${RED}Critical requirements missing. Cannot continue.${NC}"
        echo "Please install the missing requirements above."
        exit 1
    fi

    # Handle warnings (can bypass in dev mode or with confirmation)
    if (( warnings > 0 )); then
        if [ "$DEV_MODE" = true ]; then
            echo -e "${YELLOW}⚠ Warnings detected, but DEV_MODE enabled - continuing anyway${NC}"
            echo ""
        else
            echo -e "${YELLOW}⚠ Some checks have warnings.${NC}"
            echo ""
            echo "Note: KVS needs disk space for thumbnails, screenshots, and user uploads"
            echo "that cannot be delegated to external storage. Low disk space is acceptable"
            echo "for development/testing or sites with minimal content, but may become"
            echo "problematic for production sites with many videos and high traffic."
            echo ""
            # Skip prompt if headless mode
            if [[ -z "$PREFLIGHT_BYPASS" ]]; then
                echo -n "Continue anyway? [y/N]: "
                read -r PREFLIGHT_BYPASS
            fi

            if [[ "$PREFLIGHT_BYPASS" =~ ^[Yy]$ ]]; then
                echo -e "${YELLOW}Continuing with warnings...${NC}"
                echo ""
            else
                echo -e "${RED}Installation cancelled.${NC}"
                exit 1
            fi
        fi
    else
        echo -e "${GREEN}✓ All pre-flight checks passed${NC}"
        echo ""
    fi
}

# Install gum for better UX (if not present)
install_gum() {
    if command -v gum &>/dev/null; then
        return 0
    fi

    GUM_VERSION=$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null | grep '"tag_name"' | cut -d'"' -f4)

    if [ -z "$GUM_VERSION" ]; then
        return 1
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ARCH="x86_64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) return 1 ;;
    esac

    curl -fsSL "https://github.com/charmbracelet/gum/releases/download/${GUM_VERSION}/gum_${GUM_VERSION#v}_Linux_${ARCH}.tar.gz" \
        | tar -xzf - --strip-components=1 -C /usr/local/bin --wildcards '*/gum' 2>/dev/null

    chmod +x /usr/local/bin/gum 2>/dev/null
}

# Log a command's output without showing it to the user
# Usage: log_command <command> [args...]
log_command() {
    local logfile="/tmp/log_cmd_$$.log"
    local result=0

    {
        echo ">>> [$(date '+%Y-%m-%d %H:%M:%S')] EXECUTING: $*"
    } >> "$DEBUG_LOG" 2>/dev/null || true

    if "$@" >"$logfile" 2>&1; then
        result=0
    else
        result=$?
    fi

    {
        cat "$logfile" 2>/dev/null || echo "(no output)"
        echo "<<< EXIT CODE: $result"
        echo ""
    } >> "$DEBUG_LOG" 2>/dev/null || true

    rm -f "$logfile"
    return $result
}

# Run a command with spinner, showing title and result
# A failed step used to show its first ten lines, which for a Docker build
# is the BuildKit preamble while the cause sits at the end. Show the end,
# point at the debug log and name a full filesystem, the usual build killer.
report_step_failure() {
    local logfile="$1"

    [ -s "$logfile" ] || return 0
    echo "    Error (last lines, full output in ${DEBUG_LOG:-the debug log}):"
    tail -n 20 "$logfile" | sed 's/^/    /'
    if grep -q 'No space left on device' "$logfile"; then
        echo "    The filesystem is full: free space on the Docker image store (docker system df,"
        echo "    docker builder prune) or move it to a larger disk (README, Disk layout)."
    fi
}

run_step() {
    local title="$1"
    shift
    local logfile="/tmp/run_step_$$.log"
    local result=0

    if command -v gum &>/dev/null; then
        # With gum: show spinner, log output to file
        # Note: $@ and $0 must be expanded by sh -c, not the parent shell
        # shellcheck disable=SC2016
        if gum spin --spinner dot --title "$title" -- sh -c '"$@" >"$0" 2>&1' "$logfile" "$@"; then
            echo -e "  ${GREEN}✓${NC} $title"
            result=0
        else
            echo -e "  ${RED}✗${NC} $title"
            report_step_failure "$logfile"
            result=1
        fi
    else
        # Fallback without gum
        echo -n "  $title..."
        if "$@" >"$logfile" 2>&1; then
            echo -e " ${GREEN}✓${NC}"
            result=0
        else
            echo -e " ${RED}✗${NC}"
            report_step_failure "$logfile"
            result=1
        fi
    fi

    # Append step output to debug log with timestamp and title
    {
        echo "--- [$(date '+%Y-%m-%d %H:%M:%S')] $title $([ $result -eq 0 ] && echo '[SUCCESS]' || echo '[FAILED]') ---"
        cat "$logfile" 2>/dev/null || echo "(no output)"
        echo ""
    } >> "$DEBUG_LOG" 2>/dev/null || true

    rm -f "$logfile"
    return $result
}

#################################################################
# Progress Tracking
#################################################################
PROGRESS_TOTAL=11
PROGRESS_CURRENT=0

progress_bar() {
    local title="$1"
    local pct filled empty bar i
    PROGRESS_CURRENT=$((PROGRESS_CURRENT + 1))
    pct=$((PROGRESS_CURRENT * 100 / PROGRESS_TOTAL))
    filled=$((pct / 5))
    empty=$((20 - filled))
    bar=""
    for ((i=0; i<filled; i++)); do
        bar+="█"
    done
    for ((i=0; i<empty; i++)); do
        bar+="░"
    done

    echo ""
    if command -v gum &>/dev/null; then
        gum style --foreground 212 --border-foreground 99 --border rounded --width 50 --padding "0 1" \
            "[$bar] $pct% ($PROGRESS_CURRENT/$PROGRESS_TOTAL)" "→ $title"
    else
        echo -e "${CYAN}[$bar] $pct% ($PROGRESS_CURRENT/$PROGRESS_TOTAL)${NC}"
        echo -e "${CYAN}→ $title${NC}"
    fi
}

progress_header() {
    local title="$1"
    local subtitle="${2:-}"
    echo ""
    if command -v gum &>/dev/null; then
        if [[ -n "$subtitle" ]]; then
            gum style --foreground 212 --border-foreground 99 --border double --align center --width 60 --margin "1 2" --padding "1 2" "$title" "$subtitle"
        else
            gum style --foreground 212 --border-foreground 99 --border double --align center --width 60 --margin "1 2" --padding "1 2" "$title"
        fi
    else
        echo "========================================"
        echo "  $title"
        [[ -n "$subtitle" ]] && echo "  $subtitle"
        echo "========================================"
    fi
}

progress_success() {
    local msg="${1:-Setup Complete!}"
    echo ""
    if command -v gum &>/dev/null; then
        gum style --foreground 82 --border-foreground 82 --border double --align center --width 50 --padding "1 2" \
            "✓ $msg" "All $PROGRESS_TOTAL steps finished"
    else
        echo -e "${GREEN}========================================"
        echo "  ✓ $msg"
        echo "  All $PROGRESS_TOTAL steps finished"
        echo -e "========================================${NC}"
    fi
}

run_root_mariadb() {
    docker compose exec -T mariadb sh -c '
        [ -n "${MARIADB_ROOT_PASSWORD:-}" ] || exit 1
        MYSQL_PWD=$MARIADB_ROOT_PASSWORD
        export MYSQL_PWD
        exec mariadb "$@"
    ' sh "$@"
}

# Calculate and configure dynamic disk space limit for KVS
# Formula: MIN_FREE = MAX(2048, MIN(32768, TOTAL_DISK_MB × 5%))
configure_disk_space_limit() {
    echo ""
    echo -e "${CYAN}Configuring KVS disk space limit...${NC}"

    # Get total disk space in MB for the KVS directory
    # Use root partition as fallback if /var/www/$DOMAIN doesn't exist yet
    if [ -d "/var/www/$DOMAIN" ]; then
        TOTAL_DISK_MB=$(df -m "/var/www/$DOMAIN" 2>/dev/null | awk 'NR==2 {print $2}')
    else
        TOTAL_DISK_MB=$(df -m / 2>/dev/null | awk 'NR==2 {print $2}')
    fi

    # Validate we got a number before doing arithmetic
    # Use positive check to avoid issues with ! and set -e
    if [[ "$TOTAL_DISK_MB" =~ ^[0-9]+$ ]] && [ "$TOTAL_DISK_MB" -gt 0 ]; then
        TOTAL_DISK_GB=$((TOTAL_DISK_MB / 1024))
    else
        echo -e "${YELLOW}Could not detect disk size. Using KVS default (30 GB).${NC}"
        return
    fi

    # Formula: min_free = MAX(2048, MIN(32768, total_disk_mb × 5%))
    # Using binary units: 2 GB = 2048 MB, 32 GB = 32768 MB
    CALCULATED=$((TOTAL_DISK_MB * 5 / 100))
    MIN_FLOOR=2048    # 2 GB minimum
    MAX_CEIL=32768    # 32 GB maximum

    # Apply floor
    if [ "$CALCULATED" -lt "$MIN_FLOOR" ]; then
        MIN_FREE_SPACE=$MIN_FLOOR
    # Apply ceiling
    elif [ "$CALCULATED" -gt "$MAX_CEIL" ]; then
        MIN_FREE_SPACE=$MAX_CEIL
    else
        MIN_FREE_SPACE=$CALCULATED
    fi

    MIN_FREE_SPACE_GB=$((MIN_FREE_SPACE / 1024))
    PERCENT_OF_DISK=$((MIN_FREE_SPACE * 100 / TOTAL_DISK_MB))

    # Warning for small disks (< 20 GB)
    if [ "$TOTAL_DISK_GB" -lt 20 ]; then
        echo ""
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}⚠️  WARNING: Limited disk space detected (${TOTAL_DISK_GB} GB)${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}This configuration is suitable for development/testing only.${NC}"
        echo -e "${YELLOW}For production use, we recommend increasing your disk space${NC}"
        echo -e "${YELLOW}as KVS requires storage for:${NC}"
        echo -e "${YELLOW}  • Video thumbnails and screenshots${NC}"
        echo -e "${YELLOW}  • Temporary video processing files${NC}"
        echo -e "${YELLOW}  • Database and log files${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════════════════════${NC}"
        echo ""
    fi

    # Find the KVS options table and update the setting
    # KVS uses different table prefixes, so we detect it dynamically
    # Use || true to prevent set -e from crashing if DB query fails
    OPTIONS_TABLE=$(run_root_mariadb -u root "$DOMAIN" -N -e \
        "SHOW TABLES LIKE '%options%';" 2>/dev/null | grep -E 'options$' | head -1) || OPTIONS_TABLE=""

    if [ -n "$OPTIONS_TABLE" ]; then
        # Update the disk space limit setting (|| true to prevent set -e crash)
        # KVS uses 'variable' column, not 'name'
        run_root_mariadb -u root "$DOMAIN" -e \
            "UPDATE $OPTIONS_TABLE SET value='$MIN_FREE_SPACE' WHERE variable='MAIN_SERVER_MIN_FREE_SPACE_MB';" 2>/dev/null || true

        # Also update storage server group limit
        run_root_mariadb -u root "$DOMAIN" -e \
            "UPDATE $OPTIONS_TABLE SET value='$MIN_FREE_SPACE' WHERE variable='SERVER_GROUP_MIN_FREE_SPACE_MB';" 2>/dev/null || true

        echo -e "${GREEN}✓ KVS disk space limit configured${NC}"
    else
        echo -e "${YELLOW}Could not find KVS options table. You can configure this manually in:${NC}"
        echo -e "${YELLOW}  Admin Panel → Settings → System → Minimum free disc space${NC}"
    fi

    # Display information message
    echo ""
    echo -e "${CYAN}┌──────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│             KVS Disk Space Configuration                         │${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} KVS default alert threshold: ${RED}30000 MB${NC} (30 GB)                    ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC} Adjusted to: ${GREEN}${MIN_FREE_SPACE} MB${NC} (~${MIN_FREE_SPACE_GB} GB) based on your server         ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                                                                  ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC} Your disk: ${GREEN}${TOTAL_DISK_MB} MB${NC} (~${TOTAL_DISK_GB} GB)                                 ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC} Reserved:  ${GREEN}${PERCENT_OF_DISK}%${NC} of total disk                                  ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}                                                                  ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC} Formula: MAX(2048, MIN(32768, total_disk × 5%))                  ${CYAN}│${NC}"
    echo -e "${CYAN}├──────────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}│${NC} ${YELLOW}ℹ${NC}  KVS needs disk space for thumbnails, screenshots, and        ${CYAN}│${NC}"
    echo -e "${CYAN}│${NC}    temporary files. Upgrade disk if hosting many videos.        ${CYAN}│${NC}"
    echo -e "${CYAN}└──────────────────────────────────────────────────────────────────┘${NC}"
}

# Gum only improves the interactive output. Network or archive extraction
# failures must not prevent the plain-text fallback from running.
install_gum >/dev/null 2>&1 || true

# Run pre-flight checks
preflight_checks

echo -e "${CYAN}=== KVS Docker Setup ===${NC}"
echo ""

# Detect only resources owned by the final Compose project. The project name
# is not reliable until .env and the site prefix have been configured.
warn_if_existing_project_resources() {
    local project_name="$1"
    local container_ids=""
    local volume_names=""
    local container_count=0
    local volume_count=0

    if [[ ! "$project_name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        return
    fi

    if container_ids=$(docker ps -aq \
        --filter "label=com.docker.compose.project=${project_name}" \
        2>/dev/null); then
        container_count=$(printf '%s\n' "$container_ids" |
            awk 'NF { count++ } END { print count + 0 }')
    fi
    if volume_names=$(docker volume ls -q \
        --filter "label=com.docker.compose.project=${project_name}" \
        2>/dev/null); then
        volume_count=$(printf '%s\n' "$volume_names" |
            awk 'NF { count++ } END { print count + 0 }')
    fi

    if [ "$container_count" -gt 0 ] || [ "$volume_count" -gt 0 ]; then
        echo -e "${YELLOW}WARNING: Re-running on existing installation (${container_count} container(s), ${volume_count} volume(s))${NC}"
        echo -e "${YELLOW}Persisted data from a previous run may cause issues if it was misconfigured.${NC}"
        echo ""
    fi
}

# Preserve explicit environment overrides before loading .env. Docker Compose
# gives shell variables precedence over .env, so the setup script must do the
# same in headless mode.
KVS_DOMAIN_OVERRIDE="${DOMAIN:-}"
KVS_EMAIL_OVERRIDE_SET=false
KVS_EMAIL_OVERRIDE=""
if [[ -v EMAIL ]]; then
    KVS_EMAIL_OVERRIDE_SET=true
    KVS_EMAIL_OVERRIDE="$EMAIL"
fi
declare -A KVS_PORT_OVERRIDES=()
for KVS_PORT_VARIABLE in \
    HTTP_PORT HTTPS_PORT MARIADB_HOST_PORT CACHE_HOST_PORT \
    MANTICORE_MYSQL_HOST_PORT MANTICORE_HTTP_HOST_PORT; do
    if [[ -v "$KVS_PORT_VARIABLE" ]]; then
        KVS_PORT_OVERRIDES["$KVS_PORT_VARIABLE"]="${!KVS_PORT_VARIABLE}"
    fi
done

# Check if .env exists
if [ ! -f .env ]; then
    if [ -f .env.example ]; then
        cp .env.example .env
        echo -e "${GREEN}Created .env from .env.example${NC}"
    else
        echo -e "${RED}ERROR: .env.example not found${NC}"
        exit 1
    fi
fi
chmod 600 .env

# Load environment
source .env

# Domain validation
validate_domain() {
    local domain="$1"
    local label
    local -a labels

    # The domain is also used directly as the MariaDB database identifier.
    if [ -z "$domain" ] || [ "${#domain}" -gt 64 ]; then
        return 1
    fi
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi

    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [ "${#label}" -le 63 ] || return 1
    done
    return 0
}

validate_site_prefix() {
    local prefix="$1"

    [ -n "$prefix" ] && [ "${#prefix}" -le "$MAX_SITE_PREFIX_LENGTH" ] &&
        [[ "$prefix" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# Email validation
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

include_www_for_domain() {
    local dot_count

    [ "${USE_WWW:-false}" = "true" ] && return 0
    dot_count=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
    [ "$dot_count" -eq 1 ]
}

set_env_value() {
    local key="$1"
    local value="$2"
    local env_owner
    local temporary
    local temporary_owner
    local line
    local matches=0

    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    if ! env_owner=$(stat -c '%u:%g' .env) ||
        ! temporary=$(mktemp ./.env.tmp.XXXXXX); then
        return 1
    fi
    if ! sed "/^${key}=/d" .env > "$temporary" ||
        ! printf '%s=%s\n' "$key" "$value" >> "$temporary" ||
        ! chmod 600 "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! temporary_owner=$(stat -c '%u:%g' "$temporary"); then
        rm -f -- "$temporary"
        return 1
    fi
    if [ "$temporary_owner" != "$env_owner" ] &&
        ! chown "$env_owner" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "${key}=${value}" ]; then
            matches=$((matches + 1))
        fi
    done < "$temporary"
    if [ "$matches" -ne 1 ] || ! mv -f -- "$temporary" .env; then
        rm -f -- "$temporary"
        return 1
    fi
}

remove_env_value() {
    local key="$1"
    sed -i "/^${key}=/d" .env
}

add_compose_profile() {
    local profile="$1"
    local profiles

    profiles=$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tail -n 1)
    case ",${profiles}," in
        *",${profile},"*) ;;
        ",,") profiles="$profile" ;;
        *) profiles="${profiles},${profile}" ;;
    esac
    set_env_value COMPOSE_PROFILES "$profiles"
    COMPOSE_PROFILES="$profiles"
    export COMPOSE_PROFILES
}

remove_compose_profile() {
    local profile="$1"
    local profiles
    local filtered=""
    local item
    local -a profile_items

    profiles=$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tail -n 1)
    IFS=',' read -r -a profile_items <<< "$profiles"
    for item in "${profile_items[@]}"; do
        [ -n "$item" ] || continue
        [ "$item" = "$profile" ] && continue
        if [ -n "$filtered" ]; then
            filtered="${filtered},${item}"
        else
            filtered="$item"
        fi
    done
    set_env_value COMPOSE_PROFILES "$filtered"
    COMPOSE_PROFILES="$filtered"
    export COMPOSE_PROFILES
}

version_at_least() {
    local current="$1"
    local minimum="$2"

    [ "$(printf '%s\n' "$minimum" "$current" | sort -V | head -n 1)" = "$minimum" ]
}

parse_publish_endpoint() {
    local endpoint="$1"
    local host=""
    local port=""
    local octet
    local -a octets

    if [[ "$endpoint" =~ ^([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$endpoint" =~ ^\[([0-9A-Fa-f:.%]+)\]:([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
    elif [[ "$endpoint" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
        IFS='.' read -r -a octets <<< "$host"
        for octet in "${octets[@]}"; do
            [ "$((10#$octet))" -le 255 ] || return 1
        done
    else
        return 1
    fi

    [ "${#port}" -le 5 ] || return 1
    [ "$((10#$port))" -ge 1 ] || return 1
    [ "$((10#$port))" -le 65535 ] || return 1
    PUBLISH_HOST="$host"
    PUBLISH_PORT=$((10#$port))
}

publish_endpoint_is_listening() {
    local endpoint="$1"
    local protocol="${2:-tcp}"
    local local_address
    local listener_address
    local -a ss_args=(-H -ltn)

    parse_publish_endpoint "$endpoint" || return 2
    if [ "$protocol" = "udp" ]; then
        ss_args=(-H -lun)
    fi

    while read -r _ _ _ local_address _; do
        [ -n "$local_address" ] || continue
        listener_address=${local_address%:*}
        listener_address=${listener_address#[}
        listener_address=${listener_address%]}

        if [ -z "$PUBLISH_HOST" ] || [ "$PUBLISH_HOST" = "0.0.0.0" ] || \
            [ "$PUBLISH_HOST" = "::" ]; then
            return 0
        fi
        case "$listener_address" in
            '*'|'0.0.0.0'|'::') return 0 ;;
        esac
        if [ "$listener_address" = "$PUBLISH_HOST" ]; then
            return 0
        fi
    done < <(ss "${ss_args[@]}" "sport = :$PUBLISH_PORT" 2>/dev/null)

    return 1
}

container_publishes_host_port() {
    local container="$1"
    local container_port="$2"
    local protocol="$3"
    local expected_host_port="$4"
    local mapping
    local mapped_port

    while IFS= read -r mapping; do
        [ -n "$mapping" ] || continue
        mapped_port=${mapping##*:}
        if [ "$mapped_port" = "$expected_host_port" ]; then
            return 0
        fi
    done < <(docker port "$container" "${container_port}/${protocol}" 2>/dev/null || true)
    return 1
}

caddy_publishes_required_multi_site_ports() {
    docker ps --filter "name=^/kvs-caddy$" --format '{{.Names}}' 2>/dev/null |
        grep -Fxq kvs-caddy || return 1
    container_publishes_host_port kvs-caddy 80 tcp 80 &&
        container_publishes_host_port kvs-caddy 443 tcp 443 &&
        container_publishes_host_port kvs-caddy 443 udp 443
}

resolve_public_port_configuration() {
    if [ "$MODE" = "multi" ]; then
        PUBLIC_HTTP_ENDPOINT=80
        PUBLIC_HTTPS_ENDPOINT=443
    else
        PUBLIC_HTTP_ENDPOINT=${HTTP_PORT:-80}
        PUBLIC_HTTPS_ENDPOINT=${HTTPS_PORT:-443}
    fi

    if ! parse_publish_endpoint "$PUBLIC_HTTP_ENDPOINT"; then
        echo -e "${RED}ERROR: Invalid HTTP_PORT endpoint: ${PUBLIC_HTTP_ENDPOINT}${NC}"
        return 1
    fi
    PUBLIC_HTTP_PORT=$PUBLISH_PORT

    if ! parse_publish_endpoint "$PUBLIC_HTTPS_ENDPOINT"; then
        echo -e "${RED}ERROR: Invalid HTTPS_PORT endpoint: ${PUBLIC_HTTPS_ENDPOINT}${NC}"
        return 1
    fi
    PUBLIC_HTTPS_PORT=$PUBLISH_PORT
}

public_port_conflicts_exist() {
    PUBLIC_PORT_CONFLICTS=()

    if publish_endpoint_is_listening "$PUBLIC_HTTP_ENDPOINT" tcp; then
        PUBLIC_PORT_CONFLICTS+=("${PUBLIC_HTTP_ENDPOINT}/tcp")
    fi
    if publish_endpoint_is_listening "$PUBLIC_HTTPS_ENDPOINT" tcp; then
        PUBLIC_PORT_CONFLICTS+=("${PUBLIC_HTTPS_ENDPOINT}/tcp")
    fi
    if [ "$MODE" = "multi" ] && publish_endpoint_is_listening 443 udp; then
        PUBLIC_PORT_CONFLICTS+=("443/udp")
    fi

    [ "${#PUBLIC_PORT_CONFLICTS[@]}" -gt 0 ]
}

# Persist explicit port overrides before later `source .env` calls. This keeps
# setup behavior consistent with Docker Compose environment precedence.
for KVS_PORT_VARIABLE in "${!KVS_PORT_OVERRIDES[@]}"; do
    printf -v "$KVS_PORT_VARIABLE" '%s' "${KVS_PORT_OVERRIDES[$KVS_PORT_VARIABLE]}"
    export "${KVS_PORT_VARIABLE?}"
    set_env_value "$KVS_PORT_VARIABLE" "${KVS_PORT_OVERRIDES[$KVS_PORT_VARIABLE]}"
done

if [ -n "$KVS_DOMAIN_OVERRIDE" ]; then
    DOMAIN="$KVS_DOMAIN_OVERRIDE"
fi

# DNS names are case-insensitive. Keep a single canonical form so the setup
# and the multi-site manager generate identical paths, aliases, and routes.
DOMAIN=${DOMAIN,,}

if [ "$KVS_EMAIL_OVERRIDE_SET" = true ]; then
    EMAIL="$KVS_EMAIL_OVERRIDE"
fi

# Prompt for domain
if [ "$DOMAIN" = "example.com" ]; then
    if [ "${HEADLESS:-}" = "y" ]; then
        echo -e "${RED}ERROR: Set DOMAIN to a real domain in headless mode${NC}"
        exit 1
    fi

    while true; do
        echo -n "Enter your domain (e.g., mysite.com): "
        read -r DOMAIN
        DOMAIN=${DOMAIN,,}
        if validate_domain "$DOMAIN"; then
            break
        else
            echo -e "${RED}Invalid domain format. Please try again.${NC}"
        fi
    done
elif ! validate_domain "$DOMAIN"; then
    echo -e "${RED}ERROR: Invalid domain format: $DOMAIN${NC}"
    exit 1
fi

set_env_value DOMAIN "$DOMAIN"
export DOMAIN EMAIL

select_import_source

# Site prefix for container naming (multi-site support)
select_site_prefix() {
    local generated_prefix
    echo ""
    echo -e "${CYAN}Container Prefix (for multi-site support)${NC}"

    # Generate default from domain (remove TLD)
    # e.g., maximemichaud.ca -> maximemichaud, example.com -> example
    DEFAULT_PREFIX="${DOMAIN%.*}"
    # Sanitize: lowercase, replace dots/underscores with hyphens
    DEFAULT_PREFIX=$(echo "$DEFAULT_PREFIX" | tr '[:upper:]' '[:lower:]' | tr '._' '-')
    generated_prefix="kvs-${DEFAULT_PREFIX}"

    echo "Container names will be: {prefix}-php, {prefix}-mariadb, etc."
    echo "  Default: ${generated_prefix} (e.g., ${generated_prefix}-php)"

    # Skip prompt if already set (headless mode)
    if [[ -z "$PREFIX_CHOICE" ]]; then
        echo ""
        echo "Options:"
        echo "  1) Use default: kvs-${DEFAULT_PREFIX}"
        echo "  2) Use legacy: kvs (single-site, containers: kvs-php, kvs-mariadb)"
        echo "  3) Custom prefix"
        echo -n "Select [1-3] (default: 1): "
        read -r PREFIX_CHOICE
    fi

    case $PREFIX_CHOICE in
        2)
            SITE_PREFIX="kvs"
            echo -e "${GREEN}Using legacy prefix: kvs${NC}"
            ;;
        3)
            while true; do
                echo -n "Enter custom prefix (e.g., kvs-mysite): "
        read -r SITE_PREFIX
                # Validate: lowercase, alphanumeric and hyphens only
                if validate_site_prefix "$SITE_PREFIX"; then
                    break
                else
                    echo -e "${RED}Invalid prefix. Use up to ${MAX_SITE_PREFIX_LENGTH} lowercase letters, numbers, hyphens, or underscores.${NC}"
                fi
            done
            echo -e "${GREEN}Using custom prefix: ${SITE_PREFIX}${NC}"
            ;;
        *)
            SITE_PREFIX="$generated_prefix"
            echo -e "${GREEN}Using prefix: ${SITE_PREFIX}${NC}"
            ;;
    esac

    sed -i "s/^SITE_PREFIX=.*/SITE_PREFIX=$SITE_PREFIX/" .env
    # Set COMPOSE_PROJECT_NAME to match SITE_PREFIX for consistent volume naming
    if grep -q "^COMPOSE_PROJECT_NAME=" .env; then
        sed -i "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$SITE_PREFIX/" .env
    else
        echo "COMPOSE_PROJECT_NAME=$SITE_PREFIX" >> .env
    fi
}

# Only ask about prefix if using default
source .env
if [ "$KVS_EMAIL_OVERRIDE_SET" = true ]; then
    EMAIL="$KVS_EMAIL_OVERRIDE"
fi
if [ "$SITE_PREFIX" = "kvs" ]; then
    select_site_prefix
fi

if ! validate_site_prefix "$SITE_PREFIX"; then
    echo -e "${RED}ERROR: Invalid site prefix in .env: $SITE_PREFIX${NC}"
    exit 1
fi

# Ensure COMPOSE_PROJECT_NAME matches SITE_PREFIX (for existing .env files)
if [ "$COMPOSE_PROJECT_NAME" != "$SITE_PREFIX" ] 2>/dev/null; then
    if grep -q "^COMPOSE_PROJECT_NAME=" .env; then
        sed -i "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$SITE_PREFIX/" .env
    else
        echo "COMPOSE_PROJECT_NAME=$SITE_PREFIX" >> .env
    fi
fi
COMPOSE_PROJECT_NAME="$SITE_PREFIX"
export COMPOSE_PROJECT_NAME

warn_if_existing_project_resources "$COMPOSE_PROJECT_NAME"

# SSL provider selection FIRST (before email)
echo ""
echo -e "${CYAN}SSL Certificate Provider${NC}"
# Skip prompt if already set (headless mode)
if [[ -z "$SSL_CHOICE" ]]; then
    echo "  1) Let's Encrypt (recommended, default)"
    echo "  2) ZeroSSL"
    echo "  3) Self-signed (dev/testing or behind reverse proxy)"
    echo -n "Select SSL provider [1-3] (default: 1): "
        read -r SSL_CHOICE
fi

case $SSL_CHOICE in
    2)
        SSL_PROVIDER="zerossl"
        sed -i "s/SSL_PROVIDER=.*/SSL_PROVIDER=zerossl/" .env
        echo -e "${GREEN}Selected ZeroSSL${NC}"
        ;;
    3)
        SSL_PROVIDER="selfsigned"
        sed -i "s/SSL_PROVIDER=.*/SSL_PROVIDER=selfsigned/" .env
        echo -e "${YELLOW}Selected self-signed certificate${NC}"
        echo -e "${YELLOW}  → Use for: local development, or with a reverse proxy (Cloudflare, HAProxy, nginx, etc.)${NC}"
        echo -e "${YELLOW}  → SSL verification will be disabled for cron jobs and internal API calls${NC}"
        ;;
    *)
        SSL_PROVIDER="letsencrypt"
        sed -i "s/SSL_PROVIDER=.*/SSL_PROVIDER=letsencrypt/" .env
        echo -e "${GREEN}Selected Let's Encrypt${NC}"
        ;;
esac

# Email is optional for self-signed certificates. ACME providers require a
# valid address after all environment and legacy overrides have been applied.
if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    if [ -n "${EMAIL:-}" ] && ! validate_email "$EMAIL"; then
        echo -e "${RED}ERROR: Invalid email format: $EMAIL${NC}"
        exit 1
    fi
    set_env_value EMAIL "${EMAIL:-}"
else
    # The .env.example placeholder is well-formed but ACME providers reject
    # it, so treat it as unset.
    if [ "${EMAIL:-}" = "admin@example.com" ]; then
        EMAIL=""
    fi
    if [ -z "${EMAIL:-}" ] && [[ -n "${KVS_EMAIL:-}" ]]; then
        EMAIL="$KVS_EMAIL"
    fi

    if ! validate_email "${EMAIL:-}"; then
        if [ "${HEADLESS:-}" = "y" ]; then
            if [ -z "${EMAIL:-}" ]; then
                echo -e "${RED}ERROR: Set EMAIL to a valid address in headless mode${NC}"
            else
                echo -e "${RED}ERROR: Invalid email format: $EMAIL${NC}"
            fi
            exit 1
        fi

        while true; do
            echo -n "Enter your email (required for $SSL_PROVIDER): "
            read -r EMAIL
            if validate_email "$EMAIL"; then
                break
            fi
            echo -e "${RED}Invalid email format. Please try again.${NC}"
        done
    fi
    set_env_value EMAIL "$EMAIL"
fi
export EMAIL

# MariaDB version selection with endoflife.date API
select_mariadb_version() {
    echo ""
    echo -e "${CYAN}Fetching MariaDB LTS versions from endoflife.date...${NC}"

    # Fetch data from API. A lookup that times out must not end the setup
    # (set -e would exit on the failed assignment): the defaults apply.
    MARIADB_DATA=$(curl -s --connect-timeout 5 "https://endoflife.date/api/mariadb.json" 2>/dev/null) || MARIADB_DATA=""

    if [ -z "$MARIADB_DATA" ]; then
        echo -e "${YELLOW}Could not fetch version data. Using defaults.${NC}"
        return
    fi

    echo ""
    echo "Available MariaDB LTS versions:"
    echo ""

    # Parse and display LTS versions with status
    # LTS versions: 11.8, 11.4, 10.11, 10.6
    TODAY=$(date +%Y-%m-%d)

    i=1
    declare -a VERSIONS

    # Check each LTS version
    for version in "11.8" "11.4" "10.11" "10.6"; do
        # Get EOL and support dates for this version
        EOL=$(echo "$MARIADB_DATA" | grep -o "\"cycle\":\"$version\"[^}]*" | grep -o '"eol":"[^"]*"' | cut -d'"' -f4)
        SUPPORT=$(echo "$MARIADB_DATA" | grep -o "\"cycle\":\"$version\"[^}]*" | grep -o '"support":"[^"]*"' | cut -d'"' -f4)

        # Determine status color
        if [ -n "$EOL" ] && [ "$EOL" != "false" ]; then
            if [[ "$TODAY" > "$EOL" ]]; then
                STATUS="${RED}[EOL]${NC}"
            elif [ -n "$SUPPORT" ] && [[ "$TODAY" > "$SUPPORT" ]]; then
                STATUS="${YELLOW}[Security Only]${NC}"
            else
                STATUS="${GREEN}[Active]${NC}"
            fi
        else
            STATUS="${GREEN}[Active]${NC}"
        fi

        echo -e "  $i) MariaDB $version $STATUS"
        VERSIONS+=("$version")
        i=$((i + 1))
    done

    # Skip prompt if already set (headless mode)
    if [[ -z "$DB_CHOICE" ]]; then
        echo ""
        echo -n "Select MariaDB version [1-${#VERSIONS[@]}] (default: 1): "
        read -r DB_CHOICE
    fi

    if [ -z "$DB_CHOICE" ]; then
        DB_CHOICE=1
    fi

    if [ "$DB_CHOICE" -ge 1 ] && [ "$DB_CHOICE" -le "${#VERSIONS[@]}" ]; then
        SELECTED_VERSION="${VERSIONS[$((DB_CHOICE-1))]}"
        sed -i "s/MARIADB_VERSION=.*/MARIADB_VERSION=$SELECTED_VERSION/" .env
        echo -e "${GREEN}Selected MariaDB $SELECTED_VERSION${NC}"
    fi
}

# Auto-detect IonCube encoding in KVS archive
detect_ioncube() {
    echo ""
    echo -e "${CYAN}Detecting IonCube encoding...${NC}"

    # Find KVS archive
    local KVS_FILE
    KVS_FILE=$(find kvs-archive -maxdepth 1 -name 'KVS_*.zip' 2>/dev/null | head -n1)
    if [ -z "$KVS_FILE" ]; then
        echo -e "${YELLOW}KVS archive not found. Defaulting to IonCube=YES${NC}"
        return
    fi

    # Create temp directory for extraction
    local TEMP_DIR="/tmp/kvs-detect-$$"
    mkdir -p "$TEMP_DIR"

    # Extract a key PHP file for inspection (functions_base.php loads early)
    if unzip -q -j "$KVS_FILE" "admin/include/functions_base.php" -d "$TEMP_DIR" 2>/dev/null; then
        local TEST_FILE="$TEMP_DIR/functions_base.php"

        # Check for IonCube signatures (100% reliable)
        # 1. extension_loaded('ionCube Loader') - present in ALL IonCube files
        # 2. _il_exec - IonCube Loader execution function
        # 3. <?php //[hex] - IonCube file header pattern
        if grep -q "extension_loaded('ionCube Loader')" "$TEST_FILE" 2>/dev/null || \
           grep -q "_il_exec" "$TEST_FILE" 2>/dev/null || \
           head -n 1 "$TEST_FILE" | grep -qE '^\s*<\?php\s+//[0-9a-f]{5,6}'; then
            echo -e "${GREEN}✓ IonCube encoded files detected${NC}"
            sed -i "s/IONCUBE=.*/IONCUBE=YES/" .env
        else
            echo -e "${GREEN}✓ Plain PHP files detected (no IonCube)${NC}"
            sed -i "s/IONCUBE=.*/IONCUBE=NO/" .env
        fi
    else
        # Fallback: try admin/index.php
        if unzip -q -j "$KVS_FILE" "admin/index.php" -d "$TEMP_DIR" 2>/dev/null; then
            local TEST_FILE="$TEMP_DIR/index.php"

            if grep -q "extension_loaded('ionCube Loader')" "$TEST_FILE" 2>/dev/null || \
               grep -q "_il_exec" "$TEST_FILE" 2>/dev/null || \
               head -n 1 "$TEST_FILE" | grep -qE '^\s*<\?php\s+//[0-9a-f]{5,6}'; then
                echo -e "${GREEN}✓ IonCube encoded files detected${NC}"
                sed -i "s/IONCUBE=.*/IONCUBE=YES/" .env
            else
                echo -e "${GREEN}✓ Plain PHP files detected (no IonCube)${NC}"
                sed -i "s/IONCUBE=.*/IONCUBE=NO/" .env
            fi
        else
            echo -e "${YELLOW}Could not extract PHP files for inspection. Defaulting to IonCube=YES${NC}"
        fi
    fi

    # Cleanup
    rm -rf "$TEMP_DIR"

    # Reload .env to get detected value
    source .env
}

# PHP version selection based on KVS version
# Official requirements from kvs-cli CheckCommand.php
# Versions with an official php:<version>-fpm image this stack can build.
readonly SUPPORTED_PHP_VERSIONS="7.4 8.1 8.2 8.3 8.4"

php_version_is_supported() {
    local candidate="$1"
    local supported

    for supported in $SUPPORTED_PHP_VERSIONS; do
        [ "$candidate" = "$supported" ] && return 0
    done
    return 1
}

# Read the version KVS documents for the archive in kvs-archive/. Prints
# nothing and fails when the archive or its version cannot be read.
kvs_documented_php_version() {
    local kvs_file
    local kvs_version
    local major
    local minor
    local patch

    kvs_file=$(find kvs-archive -maxdepth 1 -name 'KVS_*.zip' 2>/dev/null | head -n1)
    [ -n "$kvs_file" ] || return 1

    kvs_version=$(basename "$kvs_file" | grep -oP 'KVS_\K[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    [ -n "$kvs_version" ] || return 1

    major=$(echo "$kvs_version" | cut -d. -f1)
    minor=$(echo "$kvs_version" | cut -d. -f2)
    patch=$(echo "$kvs_version" | cut -d. -f3)

    # 7.0.x, 6.4, 6.3, 6.2.1+ -> PHP 8.1
    # 6.2.0, 6.1, 6.0, 5.x    -> PHP 7.4
    if [ "$major" -lt 6 ] ||
        { [ "$major" -eq 6 ] && [ "$minor" -lt 2 ]; } ||
        { [ "$major" -eq 6 ] && [ "$minor" -eq 2 ] && [ "$patch" -eq 0 ]; }; then
        printf '%s\t%s\n' "$kvs_version" "7.4"
    else
        printf '%s\t%s\n' "$kvs_version" "8.1"
    fi
}

# Apply the PHP version to build the PHP-FPM and cron images with.
#
# An IonCube encoded archive is locked to the version its encoder targeted:
# the loader refuses a file encoded for any other one, so the documented
# version is enforced. An unencoded archive carries no such constraint, so
# the operator picks the version.
select_php_version() {
    local marker
    local kvs_version
    local documented
    local requested
    local choice

    # KVS_PHP_VERSION is the operator override. It carries the KVS_ prefix
    # every environment input uses, which also keeps `source .env` from
    # overwriting it with the stored PHP_VERSION.
    requested="${KVS_PHP_VERSION:-}"

    echo ""
    echo -e "${CYAN}Checking KVS version for PHP compatibility...${NC}"

    if marker=$(kvs_documented_php_version); then
        kvs_version=${marker%%$'\t'*}
        documented=${marker#*$'\t'}
        echo "Detected KVS version: $kvs_version"
    else
        kvs_version=""
        documented="8.1"
        echo -e "${YELLOW}Could not read the KVS version. Using PHP $documented${NC}"
    fi

    if [ -n "$requested" ] &&
        ! php_version_is_supported "$requested"; then
        echo -e "${RED}ERROR: Unsupported PHP version: $requested${NC}"
        echo "Supported versions: $SUPPORTED_PHP_VERSIONS"
        exit 1
    fi

    if [ "${IONCUBE:-YES}" = "YES" ]; then
        if [ -n "$requested" ] &&
            [ "$requested" != "$documented" ]; then
            echo -e "${YELLOW}WARNING: the archive is IonCube encoded and its files were${NC}"
            echo -e "${YELLOW}encoded for PHP $documented. Building PHP $requested makes${NC}"
            echo -e "${YELLOW}the loader refuse every encoded file, so the site returns 500.${NC}"
            echo -e "${YELLOW}Proceeding because KVS_PHP_VERSION was set explicitly.${NC}"
            set_env_value PHP_VERSION "$requested"
            echo "Set PHP version to $requested"
            return
        fi

        if [ "$documented" = "7.4" ]; then
            echo -e "${YELLOW}KVS $kvs_version requires PHP 7.4${NC}"
            echo -e "${YELLOW}Warning: PHP 7.x is EOL. Consider upgrading KVS.${NC}"
        else
            echo "KVS ${kvs_version:-archive} requires PHP $documented"
        fi
        set_env_value PHP_VERSION "$documented"
        echo -e "${GREEN}Set PHP $documented${NC}"
        return
    fi

    # Unencoded archive: no encoder to satisfy, so any supported version runs.
    echo ""
    echo -e "${CYAN}PHP Version${NC}"
    echo "The archive is not IonCube encoded, so any supported version can run it."
    echo "KVS documents PHP $documented for this release; newer versions are untested"
    echo "by Kernel Team."

    choice="$requested"
    if [ -z "$choice" ] && [ "${HEADLESS:-}" != "y" ]; then
        echo -n "PHP version to build [$SUPPORTED_PHP_VERSIONS] (default: $documented): "
        read -r choice
    fi
    choice=${choice:-$documented}

    if ! php_version_is_supported "$choice"; then
        echo -e "${RED}ERROR: Unsupported PHP version: $choice${NC}"
        echo "Supported versions: $SUPPORTED_PHP_VERSIONS"
        exit 1
    fi

    set_env_value PHP_VERSION "$choice"
    echo -e "${GREEN}Set PHP $choice${NC}"
}

# IonCube selection
select_ioncube() {
    echo ""
    echo -e "${CYAN}IonCube Loader${NC}"
    echo "KVS requires IonCube for encoded files."
    # Skip prompt if already set (headless mode)
    if [[ -z "$IONCUBE_CHOICE" ]]; then
        echo "  1) Yes - Install IonCube (required for KVS) (default)"
        echo "  2) No - Skip (only if you have unencoded KVS)"
        echo -n "Install IonCube? [1-2] (default: 1): "
        read -r IONCUBE_CHOICE
    fi

    case $IONCUBE_CHOICE in
        2)
            sed -i "s/IONCUBE=.*/IONCUBE=NO/" .env
            echo -e "${YELLOW}IonCube disabled${NC}"
            ;;
        *)
            sed -i "s/IONCUBE=.*/IONCUBE=YES/" .env
            echo -e "${GREEN}IonCube enabled${NC}"
            ;;
    esac
}

# Run version selections
# Always ask for MariaDB version in interactive mode (allow changing from previous install)
if [[ -z "$MARIADB_VERSION_CONFIRMED" ]]; then
    if [ "$MARIADB_VERSION" != "11.8" ]; then
        # Skip prompt if KEEP_VERSION already set (headless mode)
        if [[ -z "$KEEP_VERSION" ]]; then
            echo ""
            echo "Current MariaDB version in .env: ${MARIADB_VERSION}"
            echo -n "Keep this version? [Y/n]: "
            read -r KEEP_VERSION
        fi
        if [[ "$KEEP_VERSION" =~ ^[Nn]$ ]]; then
            select_mariadb_version
        else
            echo "Keeping MariaDB ${MARIADB_VERSION}"
        fi
    else
        select_mariadb_version
    fi
fi

# Check for KVS archive first (needed for PHP version detection)
echo ""
echo "Checking for KVS archive..."
mkdir -p kvs-archive

if ! ls kvs-archive/KVS_*.zip 1>/dev/null 2>&1; then
    echo -e "${RED}No KVS archive found in ./kvs-archive/${NC}"
    echo "Please copy your KVS_X.X.X_[domain.tld].zip file to ./kvs-archive/"
    # Skip prompt in headless mode
    if [[ -z "$SKIP_PRESS_ENTER" ]]; then
        echo -n "Press Enter when ready..."
        read -r
    fi

    if ! ls kvs-archive/KVS_*.zip 1>/dev/null 2>&1; then
        echo -e "${RED}ERROR: Still no KVS archive found. Exiting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}KVS archive found${NC}"

# Auto-detect IonCube encoding
detect_ioncube

# IonCube version selection (only if IonCube detected)
if [ "$IONCUBE" = "YES" ]; then
    select_ioncube
fi

# Reload .env to get user's IonCube choice
source .env

# Select PHP last: the IonCube decision above constrains which versions run.
select_php_version

# Configure JIT if IonCube is disabled (PHP 8.0+ only, incompatible with IonCube)
if [ "$IONCUBE" = "NO" ]; then
    echo ""
    echo -e "${CYAN}PHP JIT Configuration${NC}"
    echo "IonCube disabled - enabling JIT compilation for better performance"
    echo ""

    # Check if JIT config already exists
    if ! grep -q "opcache.jit_buffer_size" php/php.ini 2>/dev/null; then
        cat >> php/php.ini << 'EOF'

; JIT Configuration (PHP 8.0+ without IonCube)
; Note: JIT is incompatible with IonCube Loader
opcache.jit_buffer_size = 256M
opcache.jit = 1255
EOF
        echo -e "${GREEN}✓ JIT enabled${NC}"
        echo "  - Buffer: 256M"
        echo "  - Mode: 1255 (tracing with all optimizations)"
        echo ""
        echo -e "${YELLOW}Note: JIT provides 10-30% performance boost for compute-intensive code.${NC}"
    else
        echo -e "${GREEN}✓ JIT already configured in php.ini${NC}"
    fi
fi

# Dragonfly and memcached take CACHE_MEMORY as a hard ceiling. The value in
# .env.example suits hosts with 2 GB of RAM or more; below that, keep the
# cache at a quarter of the RAM so PHP-FPM and MariaDB keep theirs, and run
# Dragonfly on one thread: it refuses to start with less than 256 MB per
# proactor thread, so the ceiling never goes under that floor either.
# Prints "<memory MB> <threads>".
cache_settings_for_host() {
    local total_ram_mb="$1"
    local memory="$2"
    local threads="$3"
    local backend="$4"
    local cap floor

    [[ "$memory" =~ ^[0-9]+$ ]] || memory=512
    [[ "$threads" =~ ^[1-9][0-9]*$ ]] || threads=2
    if (( total_ram_mb < 2048 )); then
        cap=$(( total_ram_mb / 4 ))
        if (( cap < 64 )); then
            cap=64
        fi
        if (( memory > cap )); then
            memory=$cap
        fi
        [ "$backend" = dragonfly ] && threads=1
    fi
    if [ "$backend" = dragonfly ]; then
        floor=$(( threads * 256 ))
        if (( memory < floor )); then
            memory=$floor
        fi
    fi
    echo "$memory $threads"
}

# Cache selection (dragonfly/memcached)
select_cache() {
    echo ""
    echo -e "${CYAN}Cache Server${NC}"
    # Skip prompt if already set (headless mode)
    if [[ -z "$CACHE_CHOICE" ]]; then
        echo "  1) Dragonfly (faster, modern) (default)"
        echo "  2) Memcached (legacy, same as standalone)"
        echo -n "Select cache [1-2] (default: 1): "
        read -r CACHE_CHOICE
    fi

    case $CACHE_CHOICE in
        2)
            remove_compose_profile dragonfly
            add_compose_profile memcached
            echo -e "${GREEN}Selected Memcached${NC}"
            # Remove orphan dragonfly container if exists (port conflict)
            docker stop "${SITE_PREFIX}-dragonfly" 2>/dev/null || true
            docker rm "${SITE_PREFIX}-dragonfly" 2>/dev/null || true
            ;;
        *)
            remove_compose_profile memcached
            add_compose_profile dragonfly
            echo -e "${GREEN}Selected Dragonfly${NC}"
            # Remove orphan memcached container if exists (port conflict)
            docker stop "${SITE_PREFIX}-memcached" 2>/dev/null || true
            docker rm "${SITE_PREFIX}-memcached" 2>/dev/null || true
            ;;
    esac

    local total_ram_mb backend cache_memory cache_threads
    total_ram_mb=$(free -m | awk 'NR==2 {print $2}')
    backend=dragonfly
    [ "$CACHE_CHOICE" = 2 ] && backend=memcached
    read -r cache_memory cache_threads < <(cache_settings_for_host "$total_ram_mb" "${CACHE_MEMORY:-512}" "${CACHE_THREADS:-2}" "$backend")
    if [ "$cache_memory" != "${CACHE_MEMORY:-512}" ] || [ "$cache_threads" != "${CACHE_THREADS:-2}" ]; then
        set_env_value CACHE_MEMORY "$cache_memory" || return $?
        set_env_value CACHE_THREADS "$cache_threads" || return $?
        CACHE_MEMORY=$cache_memory
        CACHE_THREADS=$cache_threads
        echo -e "${YELLOW}Cache sized for ${total_ram_mb} MB of RAM: ${cache_memory} MB, ${cache_threads} thread(s) (CACHE_MEMORY and CACHE_THREADS in .env)${NC}"
    fi
}

select_cache

# Mode selection (single/multi)
require_multi_compose_version() {
    local compose_version

    compose_version=$(docker compose version | grep -oP '\d+\.\d+\.\d+' | head -n 1)
    if [ -z "$compose_version" ] || ! version_at_least "$compose_version" "2.24.4"; then
        echo -e "${RED}ERROR: Multi-site mode requires Docker Compose 2.24.4 or newer${NC}"
        return 1
    fi
}

select_mode() {
    local compose_files

    echo ""
    echo -e "${CYAN}Installation Mode${NC}"
    # Skip prompt if already set (headless mode)
    if [[ -z "$MODE_CHOICE" ]]; then
        if [ "${HEADLESS:-}" = "y" ]; then
            MODE_CHOICE=1
        else
            echo "  1) Single site (default) - direct nginx, best performance"
            echo "  2) Multi site - Caddy proxy (see multi-site/site-manager.sh)"
            echo -n "Select mode [1-2] (default: 1): "
            read -r MODE_CHOICE
        fi
    fi

    case $MODE_CHOICE in
        2)
            require_multi_compose_version || return $?

            echo -e "${YELLOW}Multi-site mode uses Caddy reverse proxy${NC}"
            MODE="multi"
            compose_files="docker-compose.yml"
            if [ -f docker-compose.override.yml ]; then
                compose_files="${compose_files}:docker-compose.override.yml"
            fi
            # Keep the hardening override last so a user override cannot
            # accidentally publish Nginx on Caddy's ports again.
            compose_files="${compose_files}:docker-compose.multi.yml"
            set_env_value MODE "$MODE"
            set_env_value COMPOSE_FILE "$compose_files"
            COMPOSE_FILE="$compose_files"
            export MODE COMPOSE_FILE
            echo -e "${GREEN}Multi-site mode configured for the primary site${NC}"
            ;;
        1|'')
            if [ "$MODE" = "multi" ] && \
               docker ps --filter "name=^/kvs-caddy$" --format '{{.Names}}' \
                   2>/dev/null | grep -Fxq 'kvs-caddy'; then
                echo -e "${RED}ERROR: Stop the shared Caddy proxy before switching to single-site mode${NC}"
                echo "Run: ./multi-site/site-manager.sh caddy-stop"
                return 1
            fi

            if [ "$MODE" = "multi" ]; then
                if ! ./multi-site/site-manager.sh primary-remove \
                    "$DOMAIN" "$SITE_PREFIX"; then
                    echo -e "${RED}ERROR: Failed to remove the primary Caddy route${NC}"
                    return 1
                fi
            fi

            MODE="single"
            set_env_value MODE "$MODE"
            remove_env_value COMPOSE_FILE
            unset COMPOSE_FILE
            export MODE
            echo -e "${GREEN}Single site mode (direct nginx)${NC}"
            ;;
        *)
            echo -e "${RED}ERROR: Invalid installation mode choice: ${MODE_CHOICE}${NC}"
            return 1
            ;;
    esac
}

configure_direct_tls_profile() {
    local acme_container_names

    case "${MODE}:${SSL_PROVIDER}" in
        single:letsencrypt|single:zerossl) add_compose_profile direct-tls ;;
        *)
            remove_compose_profile direct-tls
            if ! acme_container_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
                echo -e "${RED}ERROR: Could not inspect ACME containers${NC}"
                return 1
            fi
            if grep -Fxq "${SITE_PREFIX}-acme" <<< "$acme_container_names"; then
                if ! docker stop "${SITE_PREFIX}-acme" >/dev/null; then
                    echo -e "${RED}ERROR: Could not stop ${SITE_PREFIX}-acme${NC}"
                    return 1
                fi
                if ! docker rm "${SITE_PREFIX}-acme" >/dev/null; then
                    echo -e "${RED}ERROR: Could not remove ${SITE_PREFIX}-acme${NC}"
                    return 1
                fi
            fi
            if ! acme_container_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
                echo -e "${RED}ERROR: Could not verify ACME container removal${NC}"
                return 1
            fi
            if grep -Fxq "${SITE_PREFIX}-acme" <<< "$acme_container_names"; then
                echo -e "${RED}ERROR: ${SITE_PREFIX}-acme is still present${NC}"
                return 1
            fi
            ;;
    esac
}

configure_mode() {
    if [ -n "${MODE_CHOICE:-}" ] || [ "$MODE" = "single" ]; then
        select_mode || return $?
    elif [ "$MODE" = "multi" ]; then
        require_multi_compose_version || return $?
        COMPOSE_FILE="docker-compose.yml"
        if [ -f docker-compose.override.yml ]; then
            COMPOSE_FILE="${COMPOSE_FILE}:docker-compose.override.yml"
        fi
        COMPOSE_FILE="${COMPOSE_FILE}:docker-compose.multi.yml"
        set_env_value COMPOSE_FILE "$COMPOSE_FILE"
        export MODE COMPOSE_FILE
    else
        echo -e "${RED}ERROR: Invalid installation mode in .env: $MODE${NC}"
        return 1
    fi

    configure_direct_tls_profile || return $?

    if [ "$MODE" = "multi" ]; then
        PROGRESS_TOTAL=12
    else
        PROGRESS_TOTAL=11
    fi
}

configure_mode || exit $?

if [ "$MODE" = "multi" ] && [ "$SSL_PROVIDER" = "zerossl" ]; then
    echo -e "${RED}ERROR: Multi-site mode does not support selecting ZeroSSL explicitly${NC}"
    echo "Use Let's Encrypt, or self-signed certificates for local testing."
    exit 1
fi

prepare_multi_site_proxy() {
    local tls_mode="public"

    if [ "$SSL_PROVIDER" = "selfsigned" ]; then
        tls_mode="internal"
    fi

    ./multi-site/site-manager.sh primary-config \
        "$DOMAIN" "$SITE_PREFIX" "$tls_mode" "$USE_WWW"
    ./multi-site/site-manager.sh proxy-network
}

# GeoIP database selection
select_geoip() {
    echo ""
    echo -e "${CYAN}GeoIP Database${NC}"

    # Check if file already exists
    if [ -f geoip/GeoLite2-Country.mmdb ] || [ -f geoip/GeoLite2-City.mmdb ]; then
        echo -e "${GREEN}✓ GeoIP database already configured${NC}"
        echo -e "${YELLOW}Note: Admin → Settings → System → GEOIP info may show ❌ on first page load.${NC}"
        echo -e "${YELLOW}      Refresh (F5) to see ✔️ IP, Country.${NC}"
        return 0
    fi

    echo "Enables visitor geolocation (country/state detection) in KVS admin."
    echo ""

    # Auto-detect Cloudflare CDN
    local cf_detected=0
    if [ -n "$DOMAIN" ]; then
        echo -n "Checking if domain uses Cloudflare CDN... "
        if detect_cloudflare "$DOMAIN"; then
            echo -e "${GREEN}✓ Cloudflare detected${NC}"
            cf_detected=1
            echo ""
            echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${CYAN}║              Cloudflare CDN Detected (Orange Cloud)              ║${NC}"
            echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Your domain is using Cloudflare's proxy (orange cloud).${NC}"
            echo ""
            echo "Cloudflare provides GeoIP data automatically via CF-IPCountry header,"
            echo "so downloading MaxMind GeoLite2 database is ${YELLOW}NOT necessary${NC}."
            echo ""
            echo -e "${GREEN}Recommendation: Skip GeoIP download${NC}"
            echo ""
        elif [ $? -eq 2 ]; then
            echo -e "${YELLOW}Cannot reach domain (may not be configured yet)${NC}"
            echo ""
        else
            echo -e "Not using Cloudflare CDN"
            echo ""
        fi
    fi

    # Different prompts based on Cloudflare detection
    if [ "$cf_detected" -eq 1 ]; then
        echo -e "${YELLOW}Note: If using Cloudflare CDN (orange cloud), skip this.${NC}"
        echo -e "${YELLOW}Cloudflare provides GeoIP automatically via CF-IPCountry header.${NC}"
        echo ""
        # Skip prompt if already set (headless mode)
        if [[ -z "$GEOIP_CHOICE" ]]; then
            echo "Do you still want to download MaxMind GeoLite2 database?"
            echo "  1) No - Skip (recommended, Cloudflare handles GeoIP)"
            echo "  2) Yes - Download anyway (redundant but harmless)"
            echo ""
            echo -n "Choice [1]: "
            read -r CF_GEOIP_OVERRIDE
            CF_GEOIP_OVERRIDE=${CF_GEOIP_OVERRIDE:-1}
            if [ "$CF_GEOIP_OVERRIDE" = "1" ]; then
                GEOIP_CHOICE=2  # Skip
            else
                GEOIP_CHOICE=1  # Download
            fi
        fi
    else
        # Standard prompt (no Cloudflare)
        echo -e "${YELLOW}Note: If using Cloudflare CDN (orange cloud), you can skip this.${NC}"
        echo ""
        # Skip prompt if already set (headless mode)
        if [[ -z "$GEOIP_CHOICE" ]]; then
            echo "Options:"
            echo "  1) Download GeoLite2-Country database (default)"
            echo "  2) Skip (not needed if using Cloudflare, or add manually later)"
            echo ""
            echo -n "Choice [1]: "
            read -r GEOIP_CHOICE
            GEOIP_CHOICE=${GEOIP_CHOICE:-1}
        fi
    fi

    if [ "$GEOIP_CHOICE" = "1" ]; then
        echo -e "${GREEN}Downloading GeoLite2-Country.mmdb...${NC}"
        mkdir -p geoip
        GEOIP_URL="https://github.com/P3TERX/GeoLite.mmdb/releases/latest/download/GeoLite2-Country.mmdb"

        if curl -fsSL "$GEOIP_URL" -o geoip/GeoLite2-Country.mmdb; then
            echo -e "${GREEN}✓ GeoIP database downloaded${NC}"
            echo ""
            echo -e "${YELLOW}Note: After installation, Admin → Settings → System → GEOIP info may show ❌ on first load.${NC}"
            echo -e "${YELLOW}      This is cosmetic - refresh the page (F5) and it will show ✔️ IP, Country.${NC}"
        else
            echo -e "${YELLOW}⚠ Download failed - continuing without GeoIP${NC}"
            echo "  You can manually add it later to: $PWD/geoip/"
        fi
    else
        echo -e "${YELLOW}Skipped GeoIP download${NC}"
    fi
}

select_geoip

# Manticore Search selection
select_manticore() {
    echo ""
    echo -e "${CYAN}Manticore Search${NC}"
    echo "Enables full-text search and better related videos performance in KVS."
    echo "Manticore is a modern fork of Sphinx Search with improved performance."
    echo ""
    echo -e "${YELLOW}⚠ EXPERIMENTAL FEATURE${NC}"
    echo "  • Automatically configured but may need PHP adjustments for your use case"
    echo "  • Tested primarily with English-language video content"
    echo "  • Should work correctly for videos, albums, and searches"
    echo "  • Advanced users: review/modify PHP scripts in /var/www/\${DOMAIN}/ if needed"
    echo ""

    # Skip prompt if already set (headless mode)
    if [[ -z "$MANTICORE_CHOICE" ]]; then
        echo "Options:"
        echo "  1) Enable Manticore Search (recommended for large video libraries)"
        echo "  2) Skip (use default KVS search)"
        echo ""
        echo -n "Choice [2]: "
        read -r MANTICORE_CHOICE
        MANTICORE_CHOICE=${MANTICORE_CHOICE:-2}
    fi

    if [ "$MANTICORE_CHOICE" = "1" ]; then
        remove_env_value ENABLE_MANTICORE
        set_env_value ENABLE_MANTICORE true
        ENABLE_MANTICORE=true
        export ENABLE_MANTICORE
        add_compose_profile manticore
        echo -e "${GREEN}✓ Manticore Search enabled${NC}"
        echo "  External Search plugin will be auto-configured during installation"
    else
        remove_env_value ENABLE_MANTICORE
        set_env_value ENABLE_MANTICORE false
        ENABLE_MANTICORE=false
        export ENABLE_MANTICORE
        remove_compose_profile manticore
        docker stop "${SITE_PREFIX}-manticore" >/dev/null 2>&1 || true
        docker rm "${SITE_PREFIX}-manticore" >/dev/null 2>&1 || true
        echo -e "${YELLOW}Manticore Search disabled${NC}"
    fi
}

select_manticore

# Check for existing MariaDB volume and ask what to do
delete_database_volume() {
    local volume_name="$1"

    if ! docker compose down; then
        echo -e "${RED}ERROR: Could not stop this Compose project${NC}"
        return 1
    fi
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        if ! docker volume rm "$volume_name" >/dev/null; then
            echo -e "${RED}ERROR: Could not delete database volume ${volume_name}${NC}"
            return 1
        fi
    fi
    if docker volume inspect "$volume_name" >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Database volume still exists after deletion${NC}"
        return 1
    fi
}

# The MariaDB data volume of this Compose project, from the compose
# configuration, or computed from the directory name like Compose does.
compose_mariadb_volume_name() {
    local volume_name project_name

    volume_name=$(docker compose config 2>/dev/null | grep -A1 'mariadb-data:' | grep 'name:' | awk '{print $2}')
    if [ -z "$volume_name" ]; then
        project_name=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        volume_name="${project_name}_mariadb-data"
    fi
    printf '%s\n' "$volume_name"
}

# An import replays the dump when MariaDB initializes an empty volume, so a
# volume left by an earlier installation must go, and only on request. The
# consent is taken here; the deletion waits until the source is verified
# and MariaDB is about to start.
import_require_empty_volume() {
    local volume_name answer

    [ "$IMPORT_MODE" = true ] || return 0
    volume_name=$(compose_mariadb_volume_name)
    docker volume ls -q | grep -q "^${volume_name}$" || return 0
    if [ "${VOLUME_CHOICE:-}" != "1" ] && [ "${HEADLESS:-}" != "y" ]; then
        echo ""
        echo -e "${YELLOW}The database volume ${volume_name} exists; an import needs an empty one.${NC}"
        echo -n "Delete it before the import? [y/N]: "
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            VOLUME_CHOICE=1
        fi
    fi
    if [ "${VOLUME_CHOICE:-}" != "1" ]; then
        echo ""
        echo -e "${RED}ERROR: the database volume ${volume_name} already exists and an import needs an empty one.${NC}"
        echo "Back it up if it matters, then run again with VOLUME_CHOICE=1 to delete it, or remove it yourself."
        exit 1
    fi
    IMPORT_VOLUME_TO_DELETE=$volume_name
    echo ""
    echo -e "${YELLOW}The database volume ${volume_name} will be deleted right before MariaDB starts (VOLUME_CHOICE=1).${NC}"
}

ask_existing_volume() {
    echo ""
    echo -e "${CYAN}Checking for existing database...${NC}"

    # Get the volume name from docker compose config
    VOLUME_NAME=$(docker compose config 2>/dev/null | grep -A1 'mariadb-data:' | grep 'name:' | awk '{print $2}')

    # Fallback: compute from directory name
    if [ -z "$VOLUME_NAME" ]; then
        PROJECT_NAME=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        VOLUME_NAME="${PROJECT_NAME}_mariadb-data"
    fi

    # Check if volume exists
    if docker volume ls -q | grep -q "^${VOLUME_NAME}$"; then
        # Detect MariaDB version in volume by reading upgrade info file
        # MariaDB 11.0+ uses mariadb_upgrade_info, 10.x uses mysql_upgrade_info
        VOLUME_VERSION=$(docker run --rm -v "$VOLUME_NAME:/data:ro" alpine sh -c 'cat /data/mariadb_upgrade_info 2>/dev/null || cat /data/mysql_upgrade_info 2>/dev/null' || echo "")
        VOLUME_MAJOR_MINOR=""
        if [ -n "$VOLUME_VERSION" ]; then
            # Extract major.minor (e.g., "10.6.24-MariaDB" → "10.6")
            VOLUME_MAJOR_MINOR=$(echo "$VOLUME_VERSION" | grep -oP '^\d+\.\d+')
        fi

        # Compare versions (major.minor only)
        SELECTED_MAJOR_MINOR=$(echo "$MARIADB_VERSION" | grep -oP '^\d+\.\d+')
        VERSION_MISMATCH=false
        IS_DOWNGRADE=false

        if [ -n "$VOLUME_MAJOR_MINOR" ] && [ "$VOLUME_MAJOR_MINOR" != "$SELECTED_MAJOR_MINOR" ]; then
            VERSION_MISMATCH=true
            # Check if it's a downgrade (can't use bc, use version comparison)
            if printf '%s\n' "$VOLUME_MAJOR_MINOR" "$SELECTED_MAJOR_MINOR" | sort -V | head -1 | grep -q "^${SELECTED_MAJOR_MINOR}$"; then
                IS_DOWNGRADE=true
            fi
        fi

        echo ""
        echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║          Existing MariaDB Database Detected                      ║${NC}"
        echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "A previous KVS database was found:"
        echo "  Volume: ${VOLUME_NAME}"
        if [ -n "$VOLUME_MAJOR_MINOR" ]; then
            echo "  MariaDB version in volume: ${VOLUME_MAJOR_MINOR}"
            echo "  Selected MariaDB version: ${SELECTED_MAJOR_MINOR}"
        fi
        echo ""

        # Downgrade detection
        if [ "$IS_DOWNGRADE" = true ]; then
            echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║                  ⚠ VERSION DOWNGRADE DETECTED ⚠                  ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${RED}ERROR: Cannot downgrade MariaDB ${VOLUME_MAJOR_MINOR} → ${SELECTED_MAJOR_MINOR}${NC}"
            echo ""
            echo "MariaDB does not support downgrading between major versions."
            echo "The redo log format is incompatible and will cause startup failures."
            echo ""
            echo -e "${YELLOW}You MUST delete the existing database to use an older version.${NC}"
            echo ""
            echo "Your options:"
            echo ""
            echo "  1) Delete existing database and install fresh (data loss)"
            echo -e "     ${RED}⚠ All data will be lost${NC} (videos metadata, users, etc.)"
            echo ""
            echo "  2) Exit and keep MariaDB ${VOLUME_MAJOR_MINOR} (cancel downgrade)"
            echo "     Re-run setup and select MariaDB ${VOLUME_MAJOR_MINOR} or newer"
            echo ""
            echo "  3) Exit and backup database first"
            echo "     Then re-run setup with option 1 to delete and reinstall"
            echo ""

            if [[ -z "$VOLUME_CHOICE" ]]; then
                echo -n "Select [1-3] (default: 3): "
                read -r VOLUME_CHOICE
                VOLUME_CHOICE=${VOLUME_CHOICE:-3}
            fi

            case $VOLUME_CHOICE in
                1)
                    echo ""
                    echo -e "${YELLOW}Deleting existing database...${NC}"
                    delete_database_volume "$VOLUME_NAME" || exit 1
                    echo -e "${GREEN}✓ Database deleted. Will create fresh MariaDB ${SELECTED_MAJOR_MINOR} installation.${NC}"
                    KEEP_EXISTING_DB=false
                    ;;
                2)
                    echo ""
                    echo "Exiting. Re-run setup and select MariaDB ${VOLUME_MAJOR_MINOR} or newer."
                    exit 0
                    ;;
                *)
                    echo ""
                    echo "Exiting. Please backup your database before downgrading."
                    echo ""
                    echo "Backup example:"
                    echo "  docker run --rm -v ${VOLUME_NAME}:/var/lib/mysql:ro \\"
                    echo "    -v \$(pwd)/backup:/backup mariadb:${VOLUME_MAJOR_MINOR} \\"
                    echo "    mariadb-dump --all-databases > /backup/db-backup.sql"
                    exit 0
                    ;;
            esac
        elif [ "$VERSION_MISMATCH" = true ]; then
            # Upgrade detected (minor version change or major upgrade)
            echo -e "${YELLOW}You selected 'Restart installation' but a database already exists.${NC}"
            echo -e "${YELLOW}Note: MariaDB version will change from ${VOLUME_MAJOR_MINOR} → ${SELECTED_MAJOR_MINOR}${NC}"
            echo ""
            echo "What do you want to do with the existing database?"
            echo ""
            echo "  1) Fresh start - Delete old database (recommended for reinstall)"
            echo -e "     ${RED}⚠ All data will be lost${NC} (videos metadata, users, etc.)"
            echo ""
            echo "  2) Keep existing database and upgrade MariaDB"
            echo "     Use this if you want to keep your data"
            echo -e "     ${YELLOW}⚠ MariaDB will auto-upgrade the database format${NC}"
            echo ""
            echo "  3) Exit - Backup database first"
            echo "     Backup command: docker run --rm -v ${VOLUME_NAME}:/backup ..."
            echo ""

            if [[ -z "$VOLUME_CHOICE" ]]; then
                echo -n "Select [1-3] (default: 3): "
                read -r VOLUME_CHOICE
                VOLUME_CHOICE=${VOLUME_CHOICE:-3}
            fi

            case $VOLUME_CHOICE in
                1)
                    echo ""
                    echo -e "${YELLOW}Deleting existing database...${NC}"
                    delete_database_volume "$VOLUME_NAME" || exit 1
                    echo -e "${GREEN}✓ Database deleted. Will create fresh installation.${NC}"
                    KEEP_EXISTING_DB=false
                    ;;
                2)
                    echo ""
                    echo -e "${YELLOW}Keeping existing database for upgrade...${NC}"
                    echo "MariaDB will auto-upgrade from ${VOLUME_MAJOR_MINOR} to ${SELECTED_MAJOR_MINOR}"
                    KEEP_EXISTING_DB=true
                    ;;
                *)
                    echo ""
                    echo "Exiting. Please backup your database before making version changes."
                    echo ""
                    echo "Backup example:"
                    echo "  docker run --rm -v ${VOLUME_NAME}:/var/lib/mysql:ro \\"
                    echo "    -v \$(pwd)/backup:/backup mariadb:${VOLUME_MAJOR_MINOR} \\"
                    echo "    mariadb-dump --all-databases > /backup/db-backup.sql"
                    exit 0
                    ;;
            esac
        elif [ -z "$VOLUME_MAJOR_MINOR" ]; then
            # Unknown version - upgrade info file missing or unreadable
            echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║              ⚠ VOLUME VERSION UNKNOWN ⚠                          ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}Could not determine MariaDB version of the existing volume.${NC}"
            echo "Neither mariadb_upgrade_info nor mysql_upgrade_info could be read."
            echo ""
            echo "This may indicate a corrupted volume, a very old MariaDB, or a pull/run failure."
            echo "Keeping the volume without knowing its version could hide a downgrade and"
            echo "cause MariaDB ${SELECTED_MAJOR_MINOR} to fail on startup (data risk)."
            echo ""
            echo "Your options:"
            echo ""
            echo "  1) Delete existing database and install fresh (data loss, but safe)"
            echo -e "     ${RED}⚠ All data will be lost${NC} (videos metadata, users, etc.)"
            echo ""
            echo "  2) Keep existing database (at your own risk)"
            echo -e "     ${RED}⚠ MariaDB may fail to start if a downgrade is hidden${NC}"
            echo ""
            echo "  3) Exit - Investigate the volume or backup first"
            echo ""

            if [[ -z "$VOLUME_CHOICE" ]]; then
                echo -n "Select [1-3] (default: 3): "
                read -r VOLUME_CHOICE
                VOLUME_CHOICE=${VOLUME_CHOICE:-3}
            fi

            case $VOLUME_CHOICE in
                1)
                    echo ""
                    echo -e "${YELLOW}Deleting existing database...${NC}"
                    delete_database_volume "$VOLUME_NAME" || exit 1
                    echo -e "${GREEN}✓ Database deleted. Will create fresh installation.${NC}"
                    KEEP_EXISTING_DB=false
                    ;;
                2)
                    echo ""
                    echo -e "${YELLOW}Keeping existing database (version unknown)...${NC}"
                    echo "Will verify connection after MariaDB starts."
                    KEEP_EXISTING_DB=true
                    ;;
                *)
                    echo ""
                    echo "Exiting. Investigate the volume contents before proceeding."
                    exit 0
                    ;;
            esac
        else
            # Same version - standard flow
            echo -e "${YELLOW}You selected 'Restart installation' but a database already exists.${NC}"
            echo ""
            echo "What do you want to do with the existing database?"
            echo ""
            echo "  1) Fresh start - Delete old database (recommended for reinstall)"
            echo -e "     ${RED}⚠ All data will be lost${NC} (videos metadata, users, etc.)"
            echo ""
            echo "  2) Keep existing database (for Docker setup updates only)"
            echo "     Use this if you're just updating Docker config/versions"
            echo ""
            echo "  3) Exit - Backup database first"
            echo "     Backup command: docker run --rm -v ${VOLUME_NAME}:/backup ..."
            echo ""

            if [[ -z "$VOLUME_CHOICE" ]]; then
                echo -n "Select [1-3] (default: 3): "
                read -r VOLUME_CHOICE
                VOLUME_CHOICE=${VOLUME_CHOICE:-3}
            fi

            case $VOLUME_CHOICE in
                1)
                    echo ""
                    echo -e "${YELLOW}Deleting existing database...${NC}"
                    delete_database_volume "$VOLUME_NAME" || exit 1
                    echo -e "${GREEN}✓ Database deleted. Will create fresh installation.${NC}"
                    KEEP_EXISTING_DB=false
                    ;;
                2)
                    echo ""
                    echo -e "${YELLOW}Keeping existing database...${NC}"
                    echo "Will verify connection after MariaDB starts."
                    KEEP_EXISTING_DB=true
                    ;;
                *)
                    echo ""
                    echo "Exiting. Please backup your database before reinstalling."
                    echo ""
                    echo "Backup example:"
                    echo "  docker run --rm -v ${VOLUME_NAME}:/var/lib/mysql:ro \\"
                    echo "    -v \$(pwd)/backup:/backup mariadb:${SELECTED_MAJOR_MINOR} \\"
                    echo "    mariadb-dump --all-databases > /backup/db-backup.sql"
                    exit 0
                    ;;
            esac
        fi
    else
        echo "No existing database found - will create fresh installation."
        KEEP_EXISTING_DB=false
    fi
}

import_require_empty_volume
if [ "$IMPORT_MODE" = true ]; then
    KEEP_EXISTING_DB=false
else
    ask_existing_volume
fi

# A fresh database gets a one-time admin password. An imported database
# brings its own admin credentials: only the KVS default is rotated, by the
# check that runs once the database is up.
if [ "$KVS_ADMIN_PASSWORD_PROVIDED" != true ] &&
    [ "${KEEP_EXISTING_DB:-false}" != true ] &&
    [ "$IMPORT_MODE" != true ]; then
    KVS_ADMIN_PASSWORD=$(openssl rand -base64 30 | tr -d '/+=' | cut -c 1-32)
    KVS_ADMIN_PASSWORD_GENERATED=true
fi
export KVS_ADMIN_PASSWORD

# Generate passwords if still defaults
source .env
if [ "$MARIADB_ROOT_PASSWORD" = "CHANGE_ME_ROOT_PASSWORD" ]; then  # pragma: allowlist secret
    MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
    set_env_value MARIADB_ROOT_PASSWORD "$MARIADB_ROOT_PASSWORD"
    echo -e "${GREEN}Generated MariaDB root password${NC}"
fi

if [ "$MARIADB_PASSWORD" = "CHANGE_ME_KVS_PASSWORD" ]; then  # pragma: allowlist secret
    MARIADB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
    set_env_value MARIADB_PASSWORD "$MARIADB_PASSWORD"
    echo -e "${GREEN}Generated MariaDB KVS password${NC}"
fi

# Reload .env
source .env

# Persist the support access opt-out so later runs and the compose files see
# the same value; kvs-init acts on true only, false leaves KVS untouched.
if [ -n "$DISABLE_KVS_SUPPORT_ACCESS_REQUEST" ]; then
    set_env_value DISABLE_KVS_SUPPORT_ACCESS "$DISABLE_KVS_SUPPORT_ACCESS_REQUEST"
fi
DISABLE_KVS_SUPPORT_ACCESS=$(sed -n 's/^DISABLE_KVS_SUPPORT_ACCESS=//p' .env | head -n 1)
DISABLE_KVS_SUPPORT_ACCESS=${DISABLE_KVS_SUPPORT_ACCESS:-false}
case "$DISABLE_KVS_SUPPORT_ACCESS" in
    true|false) ;;
    *)
        echo -e "${RED}ERROR: DISABLE_KVS_SUPPORT_ACCESS in .env must be true or false${NC}"
        exit 1
        ;;
esac
export DISABLE_KVS_SUPPORT_ACCESS

resolve_public_port_configuration || exit $?
set_env_value PROJECT_HTTPS_PORT "$PUBLIC_HTTPS_PORT"
PROJECT_HTTPS_PORT="$PUBLIC_HTTPS_PORT"
export PROJECT_HTTPS_PORT
if [ "$MODE" = "single" ] && [ "$SSL_PROVIDER" != "selfsigned" ] &&
    [ "$PUBLIC_HTTP_PORT" -ne 80 ]; then
    echo -e "${RED}ERROR: Direct ACME HTTP-01 validation requires host TCP port 80${NC}"
    echo "Use HTTP_PORT with numeric port 80, or select self-signed/Caddy mode."
    exit 1
fi

# Open firewall ports if ufw is active
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo -e "${CYAN}Opening configured public firewall ports...${NC}"
    ufw allow "${PUBLIC_HTTP_PORT}/tcp" >/dev/null 2>&1
    if [ "$PUBLIC_HTTPS_PORT" != "$PUBLIC_HTTP_PORT" ]; then
        ufw allow "${PUBLIC_HTTPS_PORT}/tcp" >/dev/null 2>&1
    fi
    if [ "$MODE" = "multi" ]; then
        ufw allow 443/udp >/dev/null 2>&1
    fi
    echo -e "${GREEN}Firewall ports opened${NC}"
fi

# Check if configured ports are available
echo ""
echo -e "${CYAN}Checking configured public ports...${NC}"
if public_port_conflicts_exist; then
    if [ "$MODE" = "multi" ] && caddy_publishes_required_multi_site_ports; then
        echo -e "${GREEN}Caddy already publishes the required multi-site ports${NC}"
    else
        # Only manage containers from this Compose project. Name-prefix filters
        # can accidentally stop the central proxy or another KVS site.
        KVS_CONTAINERS=$(docker ps \
            --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
            --format '{{.Names}}' 2>/dev/null || true)
        if [ -n "$KVS_CONTAINERS" ]; then
            echo -e "${YELLOW}Existing KVS containers detected${NC}"
            docker ps \
                --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
                --format "table {{.Names}}\t{{.Status}}" 2>/dev/null
            echo ""
            # Skip prompt if already set (headless mode)
            if [[ -z "$STOP_EXISTING" ]]; then
                echo -n "Stop existing KVS containers? [Y/n]: "
                read -r STOP_EXISTING
            fi
            if [ "$STOP_EXISTING" != "n" ] && [ "$STOP_EXISTING" != "N" ]; then
                echo "Stopping existing containers..."
                docker compose down 2>/dev/null || true
                docker ps -q \
                    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" 2>/dev/null | \
                    xargs -r docker stop 2>/dev/null || true
                echo -e "${GREEN}Existing containers stopped${NC}"
            else
                echo -e "${RED}ERROR: Cannot continue while the configured ports remain in use${NC}"
                exit 1
            fi

            if public_port_conflicts_exist; then
                echo -e "${RED}ERROR: Configured ports are still in use after stopping this project:${NC}"
                printf '  - %s\n' "${PUBLIC_PORT_CONFLICTS[@]}"
                exit 1
            fi
        else
            echo -e "${RED}ERROR: Configured ports are in use by another process:${NC}"
            printf '  - %s\n' "${PUBLIC_PORT_CONFLICTS[@]}"
            exit 1
        fi
    fi
fi

# DNS Check Function
check_dns() {
    echo ""
    echo -e "${CYAN}Checking DNS configuration...${NC}"
    SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org) || SERVER_IP=""
    # Use getent instead of dig (more portable)
    DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1)
    WWW_IP=""
    if include_www_for_domain; then
        WWW_IP=$(getent hosts "www.$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1)
    fi

    dns_ok=true
    echo "Server IP: $SERVER_IP"
    if [ "$DOMAIN_IP" = "$SERVER_IP" ]; then
        echo -e "  $DOMAIN: ${GREEN}OK${NC} -> $DOMAIN_IP"
    else
        echo -e "  $DOMAIN: ${RED}MISMATCH${NC} -> $DOMAIN_IP (expected: $SERVER_IP)"
        dns_ok=false
    fi
    if include_www_for_domain; then
        if [ "$WWW_IP" = "$SERVER_IP" ]; then
            echo -e "  www.$DOMAIN: ${GREEN}OK${NC} -> $WWW_IP"
        else
            echo -e "  www.$DOMAIN: ${RED}MISMATCH${NC} -> $WWW_IP (expected: $SERVER_IP)"
            dns_ok=false
        fi
    fi

    if [ "$dns_ok" = false ]; then
        return 1
    fi
    return 0
}

# DNS Check with retry loop
while true; do
    if check_dns; then
        echo -e "${GREEN}DNS configuration OK${NC}"
        break
    else
        echo ""
        echo -e "${RED}DNS not configured correctly!${NC}"
        echo "Please configure your DNS records:"
        echo "  - A record for $DOMAIN -> $SERVER_IP"
        if include_www_for_domain; then
            echo "  - A record for www.$DOMAIN -> $SERVER_IP"
        fi
        echo ""
        echo "Options:"
        echo "  1) Retry DNS check"
        echo "  2) Continue anyway (SSL will fail)"
        echo "  3) Exit"
        # Skip prompt if already set (headless mode)
        if [[ -z "$DNS_CHOICE" ]]; then
            echo -n "Select [1-3]: "
        read -r DNS_CHOICE
        fi
        case $DNS_CHOICE in
            1) continue ;;
            2) echo "Continuing without valid DNS..."; break ;;
            3) exit 1 ;;
            *) continue ;;
        esac
    fi
done

if [ "$MODE" = "multi" ]; then
    prepare_multi_site_proxy
fi

import_fetch_source

# Show progress header
progress_header "KVS Docker Setup" "Building and deploying containers"

# Generate dhparam if not exists
progress_bar "Generating DH parameters"
if [ ! -f nginx/dhparam.pem ]; then
    run_step "Generating DH parameters (this may take a while)" openssl dhparam -out nginx/dhparam.pem 2048
else
    echo -e "  ${GREEN}✓${NC} DH parameters already exist"
fi

# Create bind mount directory if override file exists
if [ -f docker-compose.override.yml ]; then
    echo ""
    echo -e "${CYAN}Bind mount enabled - creating /var/www/${DOMAIN}...${NC}"
    mkdir -p "/var/www/${DOMAIN}"
    chown -R 1000:1000 "/var/www/${DOMAIN}"
    echo -e "${GREEN}Directory ready: /var/www/${DOMAIN}${NC}"
fi

# Create SSL directory structure (certificates will be generated later)
mkdir -p "nginx/ssl/${DOMAIN}"

# Step 1: Build images
progress_bar "Building PHP-FPM container"
# shellcheck disable=SC2086  # Intentional word splitting for optional --no-cache flag
if ! run_step "Building PHP-FPM container" docker compose build $DOCKER_BUILD_FLAGS php-fpm; then
    echo -e "${RED}Docker build failed${NC}"
    echo -e "${YELLOW}If error mentions 'parent snapshot does not exist', run:${NC}"
    echo "  docker builder prune -af"
    echo "Then re-run this script."
    exit 1
fi

progress_bar "Building Cron container"
# shellcheck disable=SC2086  # Intentional word splitting for optional --no-cache flag
run_step "Building Cron container" docker compose build $DOCKER_BUILD_FLAGS cron

progress_bar "Building Nginx and initialization containers"
BUILD_TARGETS=(nginx kvs-init)
if [ "${ENABLE_MANTICORE:-false}" = "true" ]; then
    BUILD_TARGETS+=(manticore)
fi
# shellcheck disable=SC2086  # Intentional word splitting for optional --no-cache flag
run_step "Building Nginx and initialization containers" \
    docker compose build $DOCKER_BUILD_FLAGS "${BUILD_TARGETS[@]}"

# Create bind mount directory
mkdir -p /var/www/"$DOMAIN"
chown 1000:1000 /var/www/"$DOMAIN"

# Step 2: Start infrastructure services
# The MariaDB image replays the *.sql, *.sql.gz, *.sql.xz and *.sql.zst
# files of mariadb/init when it initializes an empty volume, inside the
# database named in .env: an imported dump goes there, prepared for the
# container and readable by the database user of the image.
import_stage_dump() {
    local target

    [ "$IMPORT_MODE" = true ] || return 0
    if [ -n "$IMPORT_VOLUME_TO_DELETE" ]; then
        echo -e "  ${YELLOW}Deleting the database volume $IMPORT_VOLUME_TO_DELETE...${NC}"
        delete_database_volume "$IMPORT_VOLUME_TO_DELETE" || exit 1
        IMPORT_VOLUME_TO_DELETE=""
    fi
    mkdir -p mariadb/init || exit 1
    rm -f mariadb/init/*kvs-import*
    if command -v zstd >/dev/null 2>&1; then
        target=mariadb/init/10-kvs-import.sql.zst
    else
        target=mariadb/init/10-kvs-import.sql
    fi
    IMPORT_TOKEN="$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
    echo "  Preparing the database dump for MariaDB..."
    if ! import_prepare_dump "$IMPORT_DB_DUMP" ktvs_ "$IMPORT_SITE_VERSION" "$IMPORT_OLD_PATH" /var/www/kvs "$target" "$IMPORT_TOKEN" >/dev/null; then
        echo -e "${RED}ERROR: could not prepare $IMPORT_DB_DUMP${NC}"
        exit 1
    fi
    chmod 644 "$target"
    IMPORT_STAGED_DUMP=$target
    echo -e "  ${GREEN}✓${NC} Dump staged in $target"
}

# Copy the imported site into the bind-mounted directory while MariaDB
# replays the dump. Not a run_step: with gum, run_step executes its command
# in a separate shell where functions do not exist.
import_place_site_files() {
    [ "$IMPORT_MODE" = true ] || return 0
    echo "  Placing the imported site files..."
    if ! import_place_site "$IMPORT_SITE_DIR" "/var/www/$DOMAIN"; then
        echo -e "${RED}ERROR: could not place the site files${NC}"
        exit 1
    fi
}

# The dump ends with a marker row; without it MariaDB initialized from a
# dump that failed part way (the image restarts and serves what it has).
import_verify_database() {
    local marker

    [ "$IMPORT_MODE" = true ] || return 0
    marker=$(run_root_mariadb -u root "$DOMAIN" -N -e \
        "SELECT value FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';" 2>/dev/null | tr -d '\r')
    if [ "$marker" != "$IMPORT_TOKEN" ]; then
        echo -e "${RED}ERROR: the database import did not complete (completion marker ${marker:-missing}).${NC}"
        echo "Check: docker compose logs mariadb"
        echo "Then run the import again with VOLUME_CHOICE=1 so the partial volume is replaced."
        exit 1
    fi
    if ! run_root_mariadb -u root "$DOMAIN" -e "DELETE FROM ktvs_options WHERE variable='KVS_INSTALL_IMPORT';"; then
        echo -e "${RED}ERROR: could not remove the import completion marker${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Database imported ($IMPORT_DUMP_TABLES tables in the dump)"
}

progress_bar "Starting MariaDB"
import_stage_dump
run_step "Starting MariaDB" docker compose up -d --force-recreate mariadb
import_place_site_files

# Wait for MariaDB: 3 minutes, or MARIADB_WAIT_SECONDS. An import replays
# the dump during this time and waits up to an hour by default. A container
# that restarted or stopped failed its initialization: report it at once.
# The probe goes through TCP: while the image initializes the volume it runs
# a temporary server reachable on the socket only, and the socket would
# answer before the init files have been replayed.
echo -n "  Waiting for MariaDB..."
if [ "$IMPORT_MODE" = true ]; then
    MARIADB_WAIT_SECONDS=${MARIADB_WAIT_SECONDS:-3600}
else
    MARIADB_WAIT_SECONDS=${MARIADB_WAIT_SECONDS:-180}
fi
WAITED=0
while ! run_root_mariadb -u root -h 127.0.0.1 --protocol=tcp -e "SELECT 1" > /dev/null 2>&1; do
    MARIADB_CONTAINER=$(docker compose ps -q mariadb 2>/dev/null | head -n 1)
    MARIADB_STATE=$(docker inspect --format '{{.RestartCount}} {{.State.Status}}' "$MARIADB_CONTAINER" 2>/dev/null || echo "0 unknown")
    if [ "${MARIADB_STATE%% *}" != "0" ] || [ "${MARIADB_STATE#* }" = "exited" ]; then
        echo -e " ${RED}✗${NC}"
        echo -e "${RED}ERROR: the MariaDB container stopped during its initialization${NC}"
        docker compose logs --tail 20 mariadb 2>/dev/null | sed 's/^/    /'
        exit 1
    fi
    WAITED=$((WAITED + 2))
    if [ "$WAITED" -ge "$MARIADB_WAIT_SECONDS" ]; then
        echo -e " ${RED}✗${NC}"
        echo -e "${RED}ERROR: MariaDB not ready after ${MARIADB_WAIT_SECONDS} seconds${NC}"
        echo "Check logs: docker compose logs mariadb"
        exit 1
    fi
    sleep 2
done
echo -e " ${GREEN}✓${NC}"
import_verify_database

# Older installations may still contain the archive's default admin account.
# Rotate it during this run without changing an already-hardened credential.
if [ -z "${KVS_ADMIN_PASSWORD:-}" ]; then
    DEFAULT_ADMIN_COUNT=$(
        run_root_mariadb -u root "$DOMAIN" -N -e \
            "SELECT COUNT(*) FROM ktvs_admin_users WHERE user_id=1 AND login='admin' AND pass=MD5(CONCAT('pass:',MD5('123')));" \
            2>/dev/null || echo 0
    )
    if [ "$DEFAULT_ADMIN_COUNT" -gt 0 ]; then
        KVS_ADMIN_PASSWORD=$(openssl rand -base64 30 | tr -d '/+=' | cut -c 1-32)
        KVS_ADMIN_PASSWORD_GENERATED=true
        export KVS_ADMIN_PASSWORD
    fi
fi

# The MariaDB image creates the database and user named in .env only when it
# initializes an empty volume. A volume initialized for another domain keeps
# that domain's schema and user, and kvs-init later fails with an opaque
# connection error. Explain the mismatch here, while the fix is still cheap.
verify_existing_database_domain() {
    local schema_count
    local user_count

    if ! schema_count=$(run_root_mariadb -u root -N -e \
            "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='${DOMAIN}';" \
            2>/dev/null) ||
        ! user_count=$(run_root_mariadb -u root -N -e \
            "SELECT COUNT(*) FROM mysql.user WHERE user='${DOMAIN}';" \
            2>/dev/null); then
        echo -e "${YELLOW}Could not verify that the existing database belongs to ${DOMAIN}${NC}"
        return 0
    fi
    schema_count=${schema_count//[[:space:]]/}
    user_count=${user_count//[[:space:]]/}
    if [ "$schema_count" = "1" ] && [ "$user_count" = "1" ]; then
        echo -e "${GREEN}✓ Database and user for ${DOMAIN} are present${NC}"
        return 0
    fi

    echo -e "${RED}✗ The existing database volume was initialized for another domain${NC}"
    echo ""
    echo "MariaDB creates the ${DOMAIN} database and user only when it initializes"
    echo "an empty volume. This volume already belongs to a different site, so the"
    echo "KVS initialization would fail with a connection error."
    echo ""
    echo "Please either:"
    echo "  1. Restore the original DOMAIN in .env"
    echo "  2. Re-run setup and choose 'Delete old database' to start ${DOMAIN} from scratch"
    echo "  3. Create the ${DOMAIN} database and user in MariaDB before re-running setup"
    return 1
}

# Verify credentials if keeping existing database
if [ "${KEEP_EXISTING_DB:-false}" = "true" ]; then
    echo ""
    echo -e "${CYAN}Verifying existing database connection...${NC}"
    if run_root_mariadb -u root -e "SELECT 1" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Connection successful - using existing database${NC}"
    else
        echo -e "${RED}✗ Cannot connect with saved credentials${NC}"
        echo ""
        echo "The database exists but your .env credentials don't work."
        echo "This can happen if:"
        echo "  • Passwords were changed manually"
        echo "  • .env was reset but volume kept"
        echo "  • Database is corrupted"
        echo ""
        echo "Please either:"
        echo "  1. Restore correct passwords to .env"
        echo "  2. Re-run setup and choose 'Delete old database'"
        echo "  3. Manually reset password in MariaDB container"
        exit 1
    fi
    verify_existing_database_domain || exit $?
fi

# Step 3: Initialize phpMyAdmin and KVS
progress_bar "Initializing phpMyAdmin"
run_step "Initializing phpMyAdmin" \
    docker compose --profile setup run --rm --no-deps phpmyadmin-init

if [ "${KEEP_EXISTING_DB:-false}" = "true" ]; then
    echo -e "${YELLOW}Note: Keeping existing database - KVS settings will be updated but data preserved${NC}"
fi

# Record the import in .env, drop the staged dump and write the row counts
# of every table so they can be compared with the old server.
import_finish() {
    local report table_list table_name query

    [ "$IMPORT_MODE" = true ] || return 0
    report="$LOG_DIR/import-rows.txt"
    if ! table_list=$(run_root_mariadb -u root -N -e \
        "SELECT table_name FROM information_schema.tables WHERE table_schema='$DOMAIN' ORDER BY table_name;" | tr -d '\r'); then
        echo -e "${RED}ERROR: could not list the imported tables${NC}"
        exit 1
    fi
    query=""
    while IFS= read -r table_name; do
        [ -n "$table_name" ] || continue
        query="${query:+$query UNION ALL }SELECT '${table_name}', COUNT(*) FROM \`${table_name}\`"
    done <<< "$table_list"
    {
        echo "# Rows per table after the import of $IMPORT_SITE_DIR with $IMPORT_DB_DUMP, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Run the same SELECT COUNT(*) per table on the old server to compare."
        run_root_mariadb -u root -N "$DOMAIN" -e "${query};" | tr -d '\r'
    } > "$report" || {
        echo -e "${RED}ERROR: could not count the imported rows${NC}"
        exit 1
    }
    set_env_value KVS_IMPORT_COMPLETED "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 1
    [ -n "$IMPORT_STAGED_DUMP" ] && rm -f "$IMPORT_STAGED_DUMP"
    # The raw dump served its purpose; the old server keeps the original.
    # The source marker stays: a later pass from the same source is how the
    # changes made on the old server in the meantime are picked up.
    [ -n "$IMPORT_RAW_DUMP" ] && rm -f "$IMPORT_RAW_DUMP"
    rm -f "$IMPORT_STAGING/kvs-export.manifest"
    echo -e "  ${GREEN}✓${NC} Import complete: $(grep -c -v '^#' "$report") tables, row counts in $report"
}

progress_bar "Initializing KVS"
run_step "Initializing KVS" \
    docker compose --profile setup run --rm --no-deps kvs-init
import_finish
if [ "$KVS_ADMIN_PASSWORD_GENERATED" = true ]; then
    echo -e "  ${CYAN}Admin login:${NC} admin"
    echo -e "  ${CYAN}One-time admin password:${NC} $KVS_ADMIN_PASSWORD"
    echo -e "  ${YELLOW}Save it now. It is not written to .env or the setup log.${NC}"
elif [ "$KVS_ADMIN_PASSWORD_PROVIDED" = true ]; then
    echo -e "  ${GREEN}The password supplied through KVS_ADMIN_PASSWORD was applied.${NC}"
fi
unset KVS_ADMIN_PASSWORD

# Step 4: Configure KVS disk space limit
progress_bar "Configuring disk space limit"
configure_disk_space_limit

# Step 5: Start nginx and get certificate
progress_bar "Starting Nginx"
run_step "Starting Nginx" docker compose up -d --force-recreate nginx

if [ "$MODE" = "multi" ]; then
    progress_bar "Starting Caddy"
    run_step "Starting Caddy reverse proxy" \
        env ACME_EMAIL="${EMAIL:-admin@example.com}" \
        ./multi-site/site-manager.sh caddy-start
fi

# SSL Certificate based on SSL_PROVIDER
SSL_PROVIDER="${SSL_PROVIDER:-letsencrypt}"

# Dev mode: intelligent SSL detection (reuse existing cert if available)
nginx_has_public_certificate() {
    local expected_provider="${1:-public}"

    docker compose exec -T -e KVS_CERT_PROVIDER="$expected_provider" nginx sh -c '
        cert="/etc/nginx/ssl/${DOMAIN}/cert.pem"
        key="/etc/nginx/ssl/${DOMAIN}/key.pem"
        [ -s "$cert" ] && [ -s "$key" ] || exit 1
        san_entries=$(
            openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null |
                sed "1d; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d" |
                tr "," "\n" |
                sed "s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d"
        ) || exit 1
        [ -n "$san_entries" ] || exit 1
        if printf "%s\n" "$san_entries" | grep -Ev "^DNS:" >/dev/null; then
            exit 1
        fi
        actual_dns_names=$(
            printf "%s\n" "$san_entries" |
                sed -n "s/^DNS://p" | LC_ALL=C sort
        ) || exit 1
        expected_dns_names=$(
            printf "%s\n" "$DOMAIN"
            dot_count=$(printf %s "$DOMAIN" | tr -cd . | wc -c)
            if [ "${USE_WWW:-false}" = true ] || [ "$dot_count" -eq 1 ]; then
                printf "%s\n" "www.${DOMAIN}"
            fi
        )
        expected_dns_names=$(
            printf "%s\n" "$expected_dns_names" | LC_ALL=C sort
        ) || exit 1
        [ "$actual_dns_names" = "$expected_dns_names" ] || exit 1
        not_before=$(openssl x509 -in "$cert" -noout -startdate) || exit 1
        not_before=${not_before#notBefore=}
        not_before_epoch=$(LC_ALL=C date -u -d "$not_before" +%s) || exit 1
        now_epoch=$(date -u +%s) || exit 1
        [ "$not_before_epoch" -le "$now_epoch" ] || exit 1
        openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || exit 1
        openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 || exit 1
        dot_count=$(printf %s "$DOMAIN" | tr -cd . | wc -c)
        if [ "${USE_WWW:-false}" = true ] || [ "$dot_count" -eq 1 ]; then
            openssl x509 -in "$cert" -noout -checkhost "www.${DOMAIN}" \
                >/dev/null 2>&1 || exit 1
        fi
        subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253) || exit 1
        issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253) || exit 1
        [ "${subject#subject=}" != "${issuer#issuer=}" ] || exit 1
        ca_bundle=/etc/ssl/certs/ca-certificates.crt
        [ -s "$ca_bundle" ] || exit 1
        openssl verify -purpose sslserver -CAfile "$ca_bundle" \
            -untrusted "$cert" "$cert" >/dev/null 2>&1 || exit 1
        case "$KVS_CERT_PROVIDER" in
            public) ;;
            letsencrypt)
                case "$issuer" in
                    *"O=Let"*"s Encrypt"*) ;;
                    *) exit 1 ;;
                esac
                ;;
            zerossl)
                case "$issuer" in
                    *"O=ZeroSSL"*|*"CN=ZeroSSL"*) ;;
                    *) exit 1 ;;
                esac
                ;;
            *) exit 1 ;;
        esac
        cert_public_key=$(openssl x509 -in "$cert" -pubkey -noout) || exit 1
        private_public_key=$(openssl pkey -in "$key" -pubout -passin pass:) || exit 1
        [ "$cert_public_key" = "$private_public_key" ]
    ' >/dev/null 2>&1
}

get_configured_acme_api() {
    docker compose exec -T acme sh -c '
        domain=$1
        config_file="/acme.sh/${domain}_ecc/${domain}.conf"
        if [ ! -e "$config_file" ]; then
            printf "%s\n" __KVS_ABSENT__
            exit 0
        fi
        [ -f "$config_file" ] && [ -r "$config_file" ] || exit 1
        api=$(sed -n "s/^Le_API=//p" "$config_file" | tail -n 1)
        [ -n "$api" ] || {
            printf "%s\n" __KVS_UNKNOWN__
            exit 0
        }
        single_quote=$(printf "\047")
        api=${api#"$single_quote"}
        api=${api%"$single_quote"}
        api=${api#\"}
        api=${api%\"}
        printf "%s\n" "$api"
    ' sh "$DOMAIN"
}

acme_api_matches_provider() {
    local api="$1"

    case "$SSL_PROVIDER:$api" in
        letsencrypt:*letsencrypt*) return 0 ;;
        zerossl:*zerossl*) return 0 ;;
        *) return 1 ;;
    esac
}

configure_direct_acme_certificate() {
    local acme_output
    local acme_status=0
    local configured_acme_api
    local force_issuance=false
    local -a acme_args

    run_step "Starting ACME" docker compose up -d --force-recreate acme || return $?
    sleep 3
    echo "Issuing SSL certificate for $DOMAIN..."

    acme_args=(
        acme.sh --issue
        -d "$DOMAIN"
        --webroot /var/www/_letsencrypt
        --keylength ec-256
        --accountemail "$EMAIL"
    )
    if include_www_for_domain; then
        acme_args+=( -d "www.${DOMAIN}" )
    fi
    if [ "$SSL_PROVIDER" = "letsencrypt" ]; then
        acme_args+=( --server letsencrypt )
    else
        acme_args+=( --server zerossl )
    fi
    if ! configured_acme_api=$(get_configured_acme_api); then
        echo -e "${RED}Could not inspect the configured ACME provider${NC}"
        return 1
    fi
    if [ "$configured_acme_api" != __KVS_ABSENT__ ] &&
        ! acme_api_matches_provider "$configured_acme_api"; then
        force_issuance=true
    fi
    if ! nginx_has_public_certificate "$SSL_PROVIDER"; then
        force_issuance=true
    fi
    if [ "$force_issuance" = true ]; then
        acme_args+=( --force )
    fi

    if acme_output=$(docker compose exec -T acme "${acme_args[@]}" 2>&1); then
        acme_status=0
    else
        acme_status=$?
    fi
    if [ "$acme_status" -ne 0 ] &&
        ! { [ "$acme_status" -eq 2 ] &&
            grep -Fq 'Domains not changed.' <<< "$acme_output" &&
            grep -Eq 'Skipping|Skip' <<< "$acme_output"; }; then
        echo -e "${RED}SSL certificate issue failed${NC}"
        printf '%s\n' "$acme_output"
        return 1
    fi
    if ! configured_acme_api=$(get_configured_acme_api) ||
        ! acme_api_matches_provider "$configured_acme_api"; then
        echo -e "${RED}ACME did not persist the requested certificate provider${NC}"
        return 1
    fi
    if ! docker compose exec -T acme acme.sh --install-cert \
        -d "$DOMAIN" \
        --ecc \
        --key-file "/etc/nginx/ssl/${DOMAIN}/key.pem" \
        --fullchain-file "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
        --reloadcmd true; then
        echo -e "${RED}SSL certificate installation failed${NC}"
        return 1
    fi
    if ! nginx_has_public_certificate "$SSL_PROVIDER"; then
        echo -e "${RED}Installed SSL certificate was not issued by the requested provider${NC}"
        return 1
    fi
    run_step "Reloading Nginx after certificate installation" \
        docker compose exec -T nginx nginx -s reload || return $?
    echo -e "${GREEN}SSL certificate installed and validated${NC}"
}

if [ "${DEV_SSL_INTELLIGENT:-false}" = "true" ]; then
    echo ""
    echo "🔍 Dev mode: Checking for existing SSL certificate..."

    if nginx_has_public_certificate; then
        SSL_PROVIDER="letsencrypt"
        echo -e "  ${GREEN}✓${NC} Found a valid non-self-signed certificate - reusing it"
    else
        SSL_PROVIDER="selfsigned"
        echo -e "  ${YELLOW}✓${NC} No valid public certificate - using self-signed TLS"
    fi
    set_env_value SSL_PROVIDER "$SSL_PROVIDER"
    export SSL_PROVIDER
    configure_direct_tls_profile
    echo ""
fi

if [ "$MODE" = "multi" ]; then
    echo -e "  ${GREEN}✓${NC} Caddy manages TLS for the multi-site stack"
elif [ "$SSL_PROVIDER" = "selfsigned" ]; then
    echo -e "  ${GREEN}✓${NC} Using self-signed certificate"
else
    configure_direct_acme_certificate || exit $?
fi

# Step 6: Pull images and start all services
progress_bar "Starting all services"
# Don't use gum spin for docker compose up - it can timeout on slow operations
echo -n "  Starting all services..."
log_command docker compose pull --quiet || true
if log_command docker compose up -d --force-recreate; then
    echo -e " ${GREEN}✓${NC}"
else
    echo -e " ${RED}✗${NC}"
    echo "    Check: docker compose logs"
    echo "    Debug: tail -50 $DEBUG_LOG"
    exit 1
fi

progress_bar "Reloading Nginx"
run_step "Reloading Nginx" docker compose exec nginx nginx -s reload

# Done
progress_success "KVS Docker Setup Complete!"
echo ""
PUBLIC_HTTPS_PORT_SUFFIX=""
if [ "$PUBLIC_HTTPS_PORT" != "443" ]; then
    PUBLIC_HTTPS_PORT_SUFFIX=":${PUBLIC_HTTPS_PORT}"
fi
if [ "$USE_WWW" = "true" ]; then
    PUBLIC_PROJECT_URL="https://www.${DOMAIN}${PUBLIC_HTTPS_PORT_SUFFIX}"
else
    PUBLIC_PROJECT_URL="https://${DOMAIN}${PUBLIC_HTTPS_PORT_SUFFIX}"
fi
echo -e "${CYAN}Website:${NC}     ${PUBLIC_PROJECT_URL}"
echo -e "${CYAN}phpMyAdmin:${NC}  ${PUBLIC_PROJECT_URL}/phpmyadmin"
echo -e "${CYAN}Database:${NC}    $DOMAIN"
echo -e "${CYAN}DB User:${NC}     $DOMAIN"
echo -e "${CYAN}Database credentials:${NC} saved in the mode-0600 .env file"
echo ""
if [ -f docker-compose.override.yml ]; then
    echo -e "${CYAN}KVS Files:${NC}   /var/www/$DOMAIN"
    echo -e "${CYAN}kvs-cli:${NC}     kvs-cli --path=/var/www/$DOMAIN"
    echo ""
fi
echo "To view logs: docker compose logs -f"
echo "To stop: docker compose down"
echo "To restart: docker compose up -d"
if [ "$MODE" = "multi" ]; then
    echo "Caddy logs: docker logs kvs-caddy"
    echo "Stop Caddy: ./multi-site/site-manager.sh caddy-stop"
    echo "Add a site: ./multi-site/site-manager.sh add <domain>"
fi
echo ""
if [ "$IMPORT_MODE" = true ]; then
    case "$IMPORT_SOURCE" in
        archive) echo -e "${CYAN}Imported site:${NC} $IMPORT_ARCHIVE (KVS $IMPORT_SITE_VERSION)" ;;
        remote) echo -e "${CYAN}Imported site:${NC} $IMPORT_SSH_TARGET:$IMPORT_REMOTE_DIR (KVS $IMPORT_SITE_VERSION)" ;;
        *) echo -e "${CYAN}Imported site:${NC} $IMPORT_SITE_DIR (KVS $IMPORT_SITE_VERSION), database from $IMPORT_DB_DUMP" ;;
    esac
    echo "  Row counts: $LOG_DIR/import-rows.txt"
    echo ""
fi
echo -e "${CYAN}Debug logs:${NC}"
echo "  Setup:  $DEBUG_LOG"
echo ""
echo -e "${CYAN}Admin account:${NC}"
if [ "$KVS_ADMIN_PASSWORD_GENERATED" = true ] ||
    [ "$KVS_ADMIN_PASSWORD_PROVIDED" = true ]; then
    echo "  Non-default password applied and reported after initialization."
else
    echo "  Existing non-default password preserved and verified."
fi
if [ "$DISABLE_KVS_SUPPORT_ACCESS" = "true" ]; then
    echo "  KVS support access disabled (ENABLE_KVS_SUPPORT_ACCESS=0); the admin dashboard can re-enable it."
else
    echo "  KVS support access left as configured in KVS (enabled by default). Set DISABLE_KVS_SUPPORT_ACCESS=true to turn it off."
fi
unset PUBLIC_PROJECT_URL

# Mark end of installation in logs
{
    echo "========================================"
    echo "KVS Docker Setup Completed - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
} >> "$DEBUG_LOG" 2>/dev/null || true
