#!/bin/bash
# =============================================================================
# KVS Multi-Site Manager
# =============================================================================
#
# DESCRIPTION:
#   Manages multiple KVS sites running behind Caddy reverse proxy.
#
# USAGE:
#   ./site-manager.sh add <domain>      # Add a new site
#   ./site-manager.sh remove <domain>   # Remove a site
#   ./site-manager.sh start <domain>    # Start a site
#   ./site-manager.sh stop <domain>     # Stop a site
#   ./site-manager.sh list              # List all sites
#   ./site-manager.sh status            # Show status of all sites
#
# PREREQUISITES:
#   - Docker and Docker Compose installed
#   - Caddy proxy running (docker-compose.caddy.yml)
#   - KVS archive in ../kvs-archive/
#
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SITES_DIR="${SCRIPT_DIR}/sites"
CADDY_SITES_DIR="${SCRIPT_DIR}/caddy/sites"
PRIMARY_SITE_FILE="${SITES_DIR}/.primary.env"
# The .env setup.sh writes for the installation, beside multi-site/.
INSTALLATION_ENV_FILE="$(dirname -- "$SCRIPT_DIR")/.env"
KVS_ARCHIVE_DIR="${KVS_ARCHIVE_DIR:-${SCRIPT_DIR}/../kvs-archive}"
WEBROOT_BASE="${KVS_WEBROOT_BASE:-/var/www}"
MAX_DOMAIN_LENGTH=64
# Reserve 20 characters for the longest generated volume suffix.
MAX_SITE_PREFIX_LENGTH=235

# =============================================================================
# Helper Functions
# =============================================================================

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

validate_domain() {
    local domain="$1"
    local label
    local -a labels

    if [ -z "$domain" ] || [ "${#domain}" -gt "$MAX_DOMAIN_LENGTH" ]; then
        log_error "Domain must contain between 1 and ${MAX_DOMAIN_LENGTH} characters"
        return 1
    fi

    if [[ ! "$domain" =~ ^[a-z0-9.-]+$ ]] ||
        [[ "$domain" == .* ]] ||
        [[ "$domain" == *. ]] ||
        [[ "$domain" == *..* ]]; then
        log_error "Invalid domain: ${domain}"
        return 1
    fi

    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        if [ "${#label}" -gt 63 ] ||
            [[ ! "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
            log_error "Invalid domain label in: ${domain}"
            return 1
        fi
    done
}

validate_site_prefix() {
    local prefix="$1"

    if [ -z "$prefix" ] || [ "${#prefix}" -gt "$MAX_SITE_PREFIX_LENGTH" ] ||
        [[ ! "$prefix" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        log_error "Invalid site prefix: ${prefix}"
        return 1
    fi
}

primary_site_value() {
    local key="$1"

    [ -f "$PRIMARY_SITE_FILE" ] || return 0
    sed -n "s/^${key}=//p" "$PRIMARY_SITE_FILE" | head -n 1
}

validate_primary_site_file() {
    local line_count
    local domain_count
    local prefix_count
    local reserved_domain
    local reserved_prefix

    if [ ! -e "$PRIMARY_SITE_FILE" ] && [ ! -L "$PRIMARY_SITE_FILE" ]; then
        return 0
    fi
    if [ -L "$PRIMARY_SITE_FILE" ] || [ ! -f "$PRIMARY_SITE_FILE" ]; then
        log_error "Primary site reservation must be a regular file"
        return 1
    fi
    if [ "$(stat -c '%a' "$PRIMARY_SITE_FILE")" != 600 ]; then
        log_error "Primary site reservation must have mode 0600"
        return 1
    fi

    line_count=$(awk 'END { print NR + 0 }' "$PRIMARY_SITE_FILE")
    domain_count=$(grep -c '^DOMAIN=' "$PRIMARY_SITE_FILE" || true)
    prefix_count=$(grep -c '^SITE_PREFIX=' "$PRIMARY_SITE_FILE" || true)
    if [ "$line_count" -ne 2 ] || [ "$domain_count" -ne 1 ] ||
        [ "$prefix_count" -ne 1 ] ||
        [ "$(tail -c 1 "$PRIMARY_SITE_FILE" | od -An -t x1 | tr -d '[:space:]')" != 0a ]; then
        log_error "Primary site reservation must contain exactly DOMAIN and SITE_PREFIX"
        return 1
    fi

    reserved_domain=$(sed -n 's/^DOMAIN=//p' "$PRIMARY_SITE_FILE")
    reserved_prefix=$(sed -n 's/^SITE_PREFIX=//p' "$PRIMARY_SITE_FILE")
    validate_domain "$reserved_domain" || return 1
    validate_site_prefix "$reserved_prefix" || return 1
}

domain_to_safe() {
    local safe="$1"

    # DNS names cannot contain underscores, so these two substitutions are
    # reversible: original hyphens become underscores and dots become hyphens.
    safe=${safe//-/_}
    safe=${safe//./-}
    printf '%s\n' "$safe"
}

# The table prefix a site runs with, for the scripts outside the container:
# the value the site's .env carries, ktvs_ until one is written.
site_tables_prefix() {
    local prefix

    prefix=$(sed -n 's/^TABLES_PREFIX=//p' .env 2>/dev/null | head -n 1)
    [[ "$prefix" =~ ^[A-Za-z0-9_]{1,32}$ ]] || prefix=ktvs_
    printf '%s\n' "$prefix"
}

# The table prefix written in the setup.php of <archive>, the KVS archive a
# new site starts from, or ktvs_ (the prefix of every archive KVS ships) when
# there is none to read.
archive_tables_prefix() {
    local archive="$1" pattern prefix

    pattern="s/^[[:space:]]*\\\$config\\[[[:space:]]*['\"]tables_prefix['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p"
    prefix=""
    if [ -n "$archive" ] && command -v unzip >/dev/null 2>&1; then
        prefix=$(unzip -p "$archive" admin/include/setup.php 2>/dev/null | sed -n -E "$pattern" | head -n 1)
    fi
    [[ "$prefix" =~ ^[A-Za-z0-9_]{1,32}$ ]] || prefix=ktvs_
    printf '%s\n' "$prefix"
}

# The single-mode primary records its identity in docker/.env, next to the
# multi-site directory, not in the .primary.env reservation (which exists only
# once multi mode is set up). Read its Compose project name so a new site
# cannot take the same project and, on remove, tear the primary's data down.
single_mode_primary_prefix() {
    local env_file="${SCRIPT_DIR}/../.env" prefix=""
    [ -f "$env_file" ] || return 0
    prefix=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$env_file" | head -n 1)
    [ -n "$prefix" ] || prefix=$(sed -n 's/^SITE_PREFIX=//p' "$env_file" | head -n 1)
    printf '%s\n' "$prefix"
}

# Whether any container or volume already belongs to a Compose project of this
# name. It covers a single-mode primary whose prefix matches, a stopped stack
# and an earlier site, so add never adopts another stack's containers or
# volumes by reusing its project name.
compose_project_exists() {
    local project="$1"
    [ -n "$project" ] || return 1
    if [ -n "$(docker ps -a \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.ID}}' 2>/dev/null)" ]; then
        return 0
    fi
    if [ -n "$(docker volume ls \
        --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Name}}' 2>/dev/null)" ]; then
        return 0
    fi
    return 1
}

# The directories the containers of a Compose project were created from, one
# per line and de-duplicated. remove reads them to be sure a down -v tears down
# this site's own stack and not a primary that shares the project name.
compose_project_working_dirs() {
    local project="$1"
    docker ps -a --filter "label=com.docker.compose.project=${project}" \
        --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null |
        sort -u
}

# The Compose projects of the containers created from <dir>, one per line and
# de-duplicated. Compose records the directory it ran in as it was reached,
# symlinks included, so both sides are compared resolved. Fails when Docker
# cannot list the containers.
dir_compose_projects() {
    local dir_real listing project wd wd_real

    dir_real=$(cd "$1" && pwd -P) || return 1
    listing=$(docker ps -a --format \
        '{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}') ||
        return 1
    while IFS=$'\t' read -r project wd; do
        [ -n "$project" ] && [ -n "$wd" ] || continue
        wd_real=$(cd "$wd" 2>/dev/null && pwd -P) || wd_real=$wd
        if [ "$wd_real" = "$dir_real" ]; then
            printf '%s\n' "$project"
        fi
    done <<< "$listing" | sort -u
}

# The project name Compose gives a directory when nothing names one: the
# directory's name, lowercased, keeping only a-z, 0-9, _ and -, without a
# leading _ or -. sites/<domain> gets <domain> without its dots.
compose_default_project() {
    local name="${1,,}"

    name=${name//[^a-z0-9_-]/}
    while [[ "$name" == [_-]* ]]; do
        name=${name#?}
    done
    printf '%s\n' "$name"
}

# The Compose project of a site whose .env names none. add has written
# COMPOSE_PROJECT_NAME since the primary site joined the Caddy routes; a site
# added before has only SITE_PREFIX, and start, a plain docker compose in its
# directory, runs it under the name Compose derives from that directory. The
# containers created from the directory tell the project; without them, the
# volumes held under SITE_PREFIX or under the derived name do. Prints the
# project, or the derived name when neither holds anything. Fails, with the
# reason on stderr, when Docker cannot be asked or two projects claim the site.
site_project_without_name() {
    local domain="$1" site_dir="$2" site_prefix="$3"
    local projects default candidate volumes owners=""

    if ! projects=$(dir_compose_projects "$site_dir"); then
        log_error "Could not list the containers created from ${site_dir}" >&2
        return 1
    fi
    if [[ "$projects" == *$'\n'* ]]; then
        log_error "Containers of several Compose projects were created from ${site_dir}: ${projects//$'\n'/, }" >&2
        log_error "remove cannot tell which one is the site's: write it as COMPOSE_PROJECT_NAME in ${site_dir}/.env, then run remove again" >&2
        return 1
    fi
    if [ -n "$projects" ]; then
        printf '%s\n' "$projects"
        return 0
    fi

    default=$(compose_default_project "$domain")
    [ "$site_prefix" != "$default" ] || site_prefix=""
    for candidate in "$site_prefix" "$default"; do
        [ -n "$candidate" ] || continue
        if ! volumes=$(docker volume ls --filter "label=com.docker.compose.project=${candidate}" \
            --format '{{.Name}}'); then
            log_error "Could not list the volumes of ${candidate}" >&2
            return 1
        fi
        [ -z "$volumes" ] || owners="${owners:+${owners} and }${candidate}"
    done
    if [[ "$owners" == *' and '* ]]; then
        log_error "No container of ${domain} exists, and both ${owners} hold volumes: remove cannot tell which project is the site's" >&2
        log_error "Write it as COMPOSE_PROJECT_NAME in ${site_dir}/.env, then run remove again" >&2
        return 1
    fi
    printf '%s\n' "${owners:-$default}"
}

ensure_site_prefix_available() {
    local requested_domain="$1"
    local requested_prefix="$2"
    local env_file
    local existing_domain
    local existing_prefix

    validate_primary_site_file || return 1
    existing_domain=$(primary_site_value DOMAIN)
    existing_prefix=$(primary_site_value SITE_PREFIX)
    if [ -n "$existing_prefix" ] && [ "$existing_prefix" = "$requested_prefix" ] &&
        [ "$existing_domain" != "$requested_domain" ]; then
        log_error "Site prefix ${requested_prefix} is reserved by primary site ${existing_domain}"
        return 1
    fi

    [ -d "$SITES_DIR" ] || return 0

    for env_file in "$SITES_DIR"/*/.env; do
        [ -f "$env_file" ] || continue
        existing_prefix=$(sed -n 's/^SITE_PREFIX=//p' "$env_file" | head -n 1)
        [ "$existing_prefix" = "$requested_prefix" ] || continue

        existing_domain=$(basename "$(dirname "$env_file")")
        if [ "$existing_domain" != "$requested_domain" ]; then
            log_error "Site prefix ${requested_prefix} is already used by ${existing_domain}"
            return 1
        fi
    done
}

# A new site's project must belong to no other stack. The primary's own
# registration (primary-config) does not come here: its prefix is the one
# docker/.env records and its containers already exist on a single to multi
# switch, so these checks would refuse the primary itself.
ensure_new_site_project_free() {
    local requested_domain="$1"
    local requested_prefix="$2"
    local single_primary

    # A single-mode primary has no .primary.env, only docker/.env. Its project
    # can equal a new site's kvs-<domain>, and remove would then down -v it.
    single_primary=$(single_mode_primary_prefix)
    if [ -n "$single_primary" ] && [ "$single_primary" = "$requested_prefix" ]; then
        log_error "Site prefix ${requested_prefix} is used by the primary site recorded in docker/.env"
        return 1
    fi

    # Whatever the mode, never reuse a Compose project that already has
    # containers or volumes: that is how a new site would adopt and later
    # delete the primary's stack.
    if compose_project_exists "$requested_prefix"; then
        log_error "A Docker Compose project named ${requested_prefix} already exists (containers or volumes); refusing to reuse it for ${requested_domain}"
        return 1
    fi
}

check_caddy_running() {
    if ! docker ps --format '{{.Names}}' | grep -Fxq "kvs-caddy"; then
        log_error "Caddy is not running. Start it first:"
        echo "  cd ${SCRIPT_DIR} && ./site-manager.sh caddy-start"
        exit 1
    fi
}

reload_caddy() {
    log_info "Reloading Caddy configuration..."
    # Force reprovisioning even when the route text is unchanged. Site
    # containers can receive a new Docker IP after recreation, and an
    # unchanged reload would otherwise keep an upstream marked unhealthy until
    # the next active-health interval.
    if ! docker exec kvs-caddy caddy reload --force \
        --config /etc/caddy/Caddyfile; then
        log_error "Failed to reload Caddy configuration"
        return 1
    fi
    log_success "Caddy reloaded"
}

wait_for_caddy() {
    local attempt

    for ((attempt = 1; attempt <= 30; attempt++)); do
        if docker exec kvs-caddy \
            wget -T 2 -qO- http://127.0.0.1:2019/config/ >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    log_error "Caddy did not become ready within 30 seconds"
    return 1
}

ensure_proxy_network() {
    if docker network inspect kvs-proxy >/dev/null 2>&1; then
        return 0
    fi

    log_info "Creating shared proxy network..."
    docker network create kvs-proxy >/dev/null
    log_success "Created network: kvs-proxy"
}

# caddy_hosts_in_use prints every host the current site configs serve, one
# per line and in lowercase, skipping the file named (the one about to be
# rewritten). A Caddy site block starts with a line at column zero that ends
# in "{" and lists one or more addresses, separated by commas or spaces; a
# hand-written route may give an address a scheme, a port or capitals, which
# are dropped or folded here. Used to refuse a host two sites would both claim.
caddy_hosts_in_use() {
    local exclude="$1"
    local file

    [ -d "$CADDY_SITES_DIR" ] || return 0
    for file in "$CADDY_SITES_DIR"/*.caddy; do
        [ -e "$file" ] || continue
        [ "$file" = "$exclude" ] && continue
        awk '/^[^[:space:]#].*\{[[:space:]]*$/ {
            line = $0
            sub(/\{[[:space:]]*$/, "", line)
            gsub(/,/, " ", line)
            count = split(line, addresses, /[[:space:]]+/)
            for (i = 1; i <= count; i++) {
                host = tolower(addresses[i])
                sub(/^[a-z][a-z0-9+.-]*:\/\//, "", host)
                sub(/\/.*$/, "", host)
                sub(/:[0-9]+$/, "", host)
                if (host != "") print host
            }
        }' "$file"
    done
}

# caddy_route_hosts settles the route of a site: it checks the TLS and www
# settings and sets canonical_host, alternate_host (empty without a www route)
# and tls_directive, which the caller declares local. It refuses a host
# another site already serves, skipping the site's own file so a rewrite does
# not clash with itself. Nothing is written, so add runs it before creating
# anything and a refusal leaves no half-made site.
caddy_route_hosts() {
    local domain="$1"
    local tls_mode="${2:-public}"
    local use_www="${3:-false}"
    local include_www="${4:-auto}"
    local dot_count
    local in_use host

    validate_domain "$domain" || return 1
    case "$tls_mode" in
        public)
            tls_directive=""
            ;;
        internal)
            tls_directive="    tls internal"
            ;;
        *)
            log_error "Invalid Caddy TLS mode: ${tls_mode}"
            return 1
            ;;
    esac
    case "$use_www" in
        true|false)
            ;;
        *)
            log_error "Invalid USE_WWW value: ${use_www}"
            return 1
            ;;
    esac
    case "$include_www" in
        true|false)
            ;;
        auto)
            dot_count=$(tr -cd '.' <<< "$domain" | wc -c)
            if [ "$dot_count" -eq 1 ]; then
                include_www=true
            else
                include_www=false
            fi
            ;;
        *)
            log_error "Invalid Caddy www routing mode: ${include_www}"
            return 1
            ;;
    esac

    # A canonical www host necessarily requires a route and certificate for it.
    alternate_host=""
    if [ "$use_www" = true ]; then
        canonical_host="www.${domain}"
        alternate_host="$domain"
    else
        canonical_host="$domain"
        if [ "$include_www" = true ]; then
            alternate_host="www.${domain}"
        fi
    fi

    # Two Caddy site blocks for the same host make the config ambiguous:
    # every reload then fails and a restart takes all sites down. The www
    # redirect is a claimed host too, so a plain "a.example" (which also
    # serves www.a.example) and a later "www.a.example" collide.
    in_use=$(caddy_hosts_in_use "${CADDY_SITES_DIR}/${domain}.caddy")
    for host in "$canonical_host" "$alternate_host"; do
        [ -n "$host" ] || continue
        if grep -Fxq "$host" <<< "$in_use"; then
            log_error "Host ${host} is already served by another Caddy site; refusing an ambiguous route for ${domain}"
            return 1
        fi
    done
}

write_caddy_site_config() {
    local domain="$1"
    local canonical_host
    local alternate_host=""
    local tls_directive=""
    local temp_file
    local write_failed=false

    caddy_route_hosts "$@" || return 1

    # Callers test this function in a condition, which turns set -e off
    # inside it: every step checks its own status, so a route that cannot be
    # written is never reported as generated. Each write is checked on its
    # own, because a block of writes only reports the status of its last
    # command (an "if" that exits 0 when the route has no www host).
    mkdir -p "$CADDY_SITES_DIR" || return 1
    temp_file=$(mktemp "${CADDY_SITES_DIR}/.${domain}.caddy.XXXXXX") || return 1
    cat > "$temp_file" << EOF || write_failed=true
# KVS Site: ${domain}
${canonical_host} {
    reverse_proxy n.${domain}:80 {
        health_uri /health
        health_interval 30s
        health_headers {
            Host ${canonical_host}
        }
        header_up X-Real-IP {remote_host}
    }
${tls_directive}

    encode gzip zstd

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        -Server
    }

    log {
        output file /data/logs/${domain}.log {
            roll_size 10mb
            roll_keep 5
        }
    }
}
EOF
    if [ -n "$alternate_host" ]; then
        cat >> "$temp_file" << EOF || write_failed=true

${alternate_host} {
    redir https://${canonical_host}{uri} permanent
${tls_directive}
}
EOF
    fi
    if [ "$write_failed" = true ] ||
        ! mv -f "$temp_file" "${CADDY_SITES_DIR}/${domain}.caddy"; then
        rm -f "$temp_file"
        log_error "Could not write the Caddy route for ${domain}"
        return 1
    fi
    log_success "Generated Caddy config: ${CADDY_SITES_DIR}/${domain}.caddy"
}

configure_primary_site() {
    local domain="$1"
    local site_prefix="$2"
    local tls_mode="${3:-public}"
    local use_www="${4:-false}"
    local existing_domain
    local existing_prefix
    local temp_file
    local created_registration=false

    validate_domain "$domain" || return 1
    validate_site_prefix "$site_prefix" || return 1

    validate_primary_site_file || return 1
    existing_domain=$(primary_site_value DOMAIN)
    existing_prefix=$(primary_site_value SITE_PREFIX)
    if [ -n "$existing_domain" ] || [ -n "$existing_prefix" ]; then
        if [ "$existing_domain" != "$domain" ] || [ "$existing_prefix" != "$site_prefix" ]; then
            log_error "Primary site is already reserved as ${existing_domain} (${existing_prefix})"
            return 1
        fi
    else
        [ ! -d "${SITES_DIR}/${domain}" ] || {
            log_error "A managed site already uses primary domain ${domain}"
            return 1
        }
        ensure_site_prefix_available "$domain" "$site_prefix" || return 1

        mkdir -p "$SITES_DIR"
        temp_file=$(mktemp "${SITES_DIR}/.primary.env.XXXXXX")
        chmod 600 "$temp_file"
        {
            printf 'DOMAIN=%s\n' "$domain"
            printf 'SITE_PREFIX=%s\n' "$site_prefix"
        } > "$temp_file"
        mv -f "$temp_file" "$PRIMARY_SITE_FILE"
        created_registration=true
    fi

    if ! write_caddy_site_config "$domain" "$tls_mode" "$use_www" auto; then
        if [ "$created_registration" = true ]; then
            rm -f "$PRIMARY_SITE_FILE"
        fi
        return 1
    fi
}

remove_primary_site() {
    local domain="$1"
    local site_prefix="$2"
    local existing_domain
    local existing_prefix
    local route_file="${CADDY_SITES_DIR}/${domain}.caddy"
    local managed_site_dir="${SITES_DIR}/${domain}"

    validate_domain "$domain" || return 1
    validate_site_prefix "$site_prefix" || return 1

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "kvs-caddy"; then
        log_error "Stop Caddy before removing the primary route"
        return 1
    fi
    if [ -d "$managed_site_dir" ]; then
        log_error "Refusing to remove a primary route used by a managed site: ${domain}"
        return 1
    fi
    validate_primary_site_file || return 1
    existing_domain=$(primary_site_value DOMAIN)
    existing_prefix=$(primary_site_value SITE_PREFIX)
    if [ -z "$existing_domain" ] && [ -z "$existing_prefix" ]; then
        if [ -e "$route_file" ] || [ -L "$route_file" ]; then
            log_error "Refusing to remove an orphaned Caddy route without a reservation"
            return 1
        fi
        log_success "Primary Caddy route is already absent for ${domain}"
        return 0
    fi
    if [ "$existing_domain" != "$domain" ] || [ "$existing_prefix" != "$site_prefix" ]; then
        log_error "Primary site reservation does not match ${domain} (${site_prefix})"
        return 1
    fi

    if [ -e "$route_file" ] || [ -L "$route_file" ]; then
        if [ -L "$route_file" ] || [ ! -f "$route_file" ] ||
            ! grep -Fxq "# KVS Site: ${domain}" "$route_file" ||
            ! grep -Fq "reverse_proxy n.${domain}:80" "$route_file"; then
            log_error "Refusing to remove an unexpected primary Caddy route"
            return 1
        fi
        rm -f "$route_file" || return 1
    fi
    rm -f "$PRIMARY_SITE_FILE" || return 1
    log_success "Removed primary Caddy route and reservation for ${domain}"
}

# =============================================================================
# Add Site
# =============================================================================

# Sets site_archive in the caller (add_site): the KVS archive a new site is
# made from, when kvs-archive/ holds exactly one, and fails when it holds
# none. The archives are what the site's init can install, the regular files
# named KVS_*.zip directly in that directory, which its find_kvs_archive
# lists with find -type f: a symlink or a directory of that name is not one.
# find -H follows kvs-archive/ itself when it is a symlink, as the bind mount
# of the init container does. The init installs the first archive find
# lists, an order nothing fixes, so with several add reads none of them and
# leaves site_archive empty, with a warning that names them.
select_site_archive() {
    local domain="$1"
    local -a archives

    site_archive=""
    mapfile -t archives < <(find -H "$KVS_ARCHIVE_DIR" -maxdepth 1 -name 'KVS_*.zip' -type f 2>/dev/null)
    if [ "${#archives[@]}" -eq 0 ]; then
        log_error "No KVS archive found in ${KVS_ARCHIVE_DIR}/"
        return 1
    fi
    if [ "${#archives[@]}" -eq 1 ]; then
        site_archive=${archives[0]}
        return 0
    fi
    log_warn "${KVS_ARCHIVE_DIR}/ holds ${#archives[@]} KVS archives; the new site's init installs the first one it lists, which add cannot tell:"
    printf '  %s\n' "${archives[@]##*/}"
    log_warn "add reads none of them: where the archive would decide, the new site gets PHP 8.1 unless KVS_PHP_VERSION is set, IONCUBE=YES unless IONCUBE is set, and the table prefix ktvs_"
    log_warn "Keep only the new site's archive in ${KVS_ARCHIVE_DIR}/ until the site's first start. Give add its values on the add command line only, for example: KVS_PHP_VERSION=8.3 IONCUBE=NO ./site-manager.sh add ${domain}"
}

# Sets php_version and ioncube in the caller (add_site) for a new site made
# from <archive> into <webroot>. A webroot an earlier remove kept holds the
# KVS the site's init will run, since the init keeps an installed site and
# extracts no archive over it: when it has admin/include/functions_base.php,
# its files decide, its version.php the series and functions_base.php
# IONCUBE, as setup.sh decides for a site in place. What they cannot tell
# comes from the archive: the series KVS documents for the release in its
# name and IONCUBE from its own files. KVS_PHP_VERSION names the series
# instead, as in setup.sh. A release that needs PHP 7.4, which this stack
# does not build, is refused as setup.sh refuses it. What neither can tell,
# all of it when there is no archive to read, comes from KVS_PHP_VERSION and
# IONCUBE, or else is PHP 8.1 and IONCUBE=YES, what add wrote before it read
# the archive.
select_site_php() {
    local archive="$1" webroot="$2"
    local kvs_php_lib="${SCRIPT_DIR}/../lib/kvs-php.sh"
    local kvs_version="" documented="" encoded="" version_source="" ioncube_source=""

    if [ ! -r "$kvs_php_lib" ]; then
        log_error "Missing ${kvs_php_lib}: it tells which PHP a KVS release needs"
        return 1
    fi
    # shellcheck source=docker/lib/kvs-php.sh
    source "$kvs_php_lib"

    if [ -n "${KVS_PHP_VERSION:-}" ] && [[ ! "$KVS_PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        log_error "KVS_PHP_VERSION=${KVS_PHP_VERSION} is not a PHP series such as 8.3"
        return 1
    fi
    if [ -n "${IONCUBE:-}" ] && [ "$IONCUBE" != YES ] && [ "$IONCUBE" != NO ]; then
        log_error "IONCUBE=${IONCUBE} is neither YES nor NO"
        return 1
    fi

    if [ -f "${webroot}/admin/include/functions_base.php" ]; then
        log_info "${webroot} holds a KVS site, which the new site's init keeps and runs: its files decide"
        if kvs_version=$(kvs_site_version "$webroot") && documented=$(kvs_php_series "$kvs_version"); then
            version_source=$webroot
        else
            kvs_version=""
            documented=""
            log_warn "Could not read the KVS version of ${webroot}"
        fi
        if encoded=$(kvs_site_ioncube "$webroot"); then
            ioncube_source=$webroot
        else
            encoded=""
            log_warn "Could not read ${webroot}/admin/include/functions_base.php"
        fi
    fi
    if [ -n "$archive" ] && [ -z "$version_source" ]; then
        if kvs_version=$(kvs_archive_version "$archive") && documented=$(kvs_php_series "$kvs_version"); then
            version_source=${archive##*/}
        else
            kvs_version=""
            documented=""
            log_warn "Could not read the KVS version from ${archive##*/}"
        fi
    fi
    if [ -n "$archive" ] && [ -z "$ioncube_source" ]; then
        if encoded=$(kvs_archive_ioncube "$archive"); then
            ioncube_source=${archive##*/}
        else
            encoded=""
            log_warn "Could not inspect the PHP files of ${archive##*/}"
        fi
    fi
    [ -z "$version_source" ] ||
        log_info "KVS ${kvs_version} (${version_source}): PHP ${documented} is the documented runtime"
    [ -z "$ioncube_source" ] || log_info "IonCube encoded files (${ioncube_source}): ${encoded}"

    case "$encoded" in
        yes) ioncube=YES ;;
        no) ioncube=NO ;;
        *) ioncube=${IONCUBE:-YES} ;;
    esac
    if [ -n "$encoded" ] && [ -n "${IONCUBE:-}" ] && [ "$IONCUBE" != "$ioncube" ]; then
        log_warn "IONCUBE=${IONCUBE} is not used: the files of ${ioncube_source} give IONCUBE=${ioncube}"
    fi

    if [ -n "${KVS_PHP_VERSION:-}" ]; then
        if [ -n "$documented" ] && [ "$ioncube" = YES ] && [ "$KVS_PHP_VERSION" != "$documented" ]; then
            log_warn "With IONCUBE=YES, PHP ${documented} is the recommended runtime for KVS ${kvs_version}; PHP ${KVS_PHP_VERSION} must be compatible with the encoding of its files"
        fi
        php_version=$KVS_PHP_VERSION
    elif [ "$documented" = 7.4 ]; then
        log_error "KVS ${kvs_version} needs PHP 7.4, which this Docker installation does not build"
        if [ "$version_source" = "$webroot" ]; then
            log_error "That is the site kept in ${webroot}: move it away to install from an archive of KVS 6.2.1 or newer, or, only if its files are not IonCube encoded, set KVS_PHP_VERSION to a series docker/images.lock pins"
        else
            log_error "Use an archive of KVS 6.2.1 or newer, or, only if its files are not IonCube encoded, set KVS_PHP_VERSION to a series docker/images.lock pins"
        fi
        return 1
    else
        php_version=${documented:-8.1}
    fi
    log_info "New site: PHP ${php_version}, IONCUBE=${ioncube}"
}

add_site() {
    local domain="$1"
    validate_domain "$domain" || return 1
    validate_primary_site_file || return 1

    local domain_safe
    domain_safe=$(domain_to_safe "$domain")
    local site_dir="${SITES_DIR}/${domain}"
    local site_prefix="kvs-${domain_safe}"
    local primary_domain
    local php_version
    local ioncube
    local resolver="${SCRIPT_DIR}/../bin/resolve-bases.sh"
    local php_fpm_base php_cli_base

    primary_domain=$(primary_site_value DOMAIN)
    if [ "$primary_domain" = "$domain" ]; then
        log_error "Domain ${domain} is reserved by the primary site"
        return 1
    fi

    log_info "Adding site: ${domain}"

    # Check if site already exists
    if [ -d "$site_dir" ]; then
        log_error "Site ${domain} already exists at ${site_dir}"
        if [ ! -f "${site_dir}/docker-compose.yml" ]; then
            log_error "It has no docker-compose.yml: an earlier add stopped before it finished. Run './site-manager.sh remove ${domain}', which checks that nothing of it runs before it deletes it"
        fi
        exit 1
    fi

    if [ -e "${CADDY_SITES_DIR}/${domain}.caddy" ]; then
        log_error "A Caddy route already exists for ${domain}"
        return 1
    fi

    ensure_site_prefix_available "$domain" "$site_prefix" || return 1
    ensure_new_site_project_free "$domain" "$site_prefix" || return 1

    # Refuse the route before anything is created: a host another site
    # already serves (or an invalid CADDY_TLS_MODE) must not cost a webroot
    # that remove kept or an operator prepared.
    local canonical_host alternate_host tls_directive
    caddy_route_hosts "$domain" "${CADDY_TLS_MODE:-public}" false auto || return 1

    # The PHP series, the IonCube setting and the table prefix come from the
    # archive, by the rules setup.sh applies to the primary site, before
    # anything is created; the series and IonCube from a webroot an earlier
    # remove kept, when it holds a KVS site.
    local site_archive
    local webroot="${WEBROOT_BASE}/${domain}"
    select_site_archive "$domain" || return 1
    select_site_php "$site_archive" "$webroot" || return 1

    # The build bases of the PHP series, pinned by digest in
    # docker/images.lock, as setup.sh writes them for the primary site
    # (set_php_bases): without them the template builds PHP-FPM and cron
    # from the moving php:<series> tags. Read before anything is created,
    # so a series the lock does not know leaves no half-made site behind.
    if ! php_fpm_base=$("$resolver" --get php-fpm "$php_version") ||
        ! php_cli_base=$("$resolver" --get php-cli "$php_version"); then
        log_error "PHP ${php_version} has no pinned base in docker/images.lock"
        return 1
    fi

    # Create site directory
    mkdir -p "$SITES_DIR" "$CADDY_SITES_DIR"
    mkdir -p "${site_dir}"
    log_success "Created site directory: ${site_dir}"

    # Create webroot directory
    local webroot_created=false
    [ -e "$webroot" ] || webroot_created=true
    mkdir -p "${webroot}"
    chown 1000:1000 "${webroot}"
    log_success "Created webroot: ${webroot}"

    # Generate .env file. The table prefix is the one of the archive's
    # setup.php (ktvs_ for every archive KVS ships); the init reads it from
    # the site itself, .env carries it for the scripts outside the container.
    local tables_prefix
    tables_prefix=$(archive_tables_prefix "$site_archive")
    (
        umask 077
        cat > "${site_dir}/.env" << EOF
# Site configuration for ${domain}
DOMAIN=${domain}
SITE_PREFIX=${site_prefix}
COMPOSE_PROJECT_NAME=${site_prefix}
USE_WWW=false
TABLES_PREFIX=${tables_prefix}

# Database
MARIADB_VERSION=12.3
# Per-site budgets; adjust before start instead of claiming half the host per site.
MARIADB_BUFFER_POOL_SIZE=128M
MARIADB_REDO_LOG_SIZE=128M
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
MARIADB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')

# PHP. PHP-FPM and cron build from the bases docker/images.lock pins for
# PHP_VERSION; after a change of PHP_VERSION, set PHP_FPM_BASE and
# PHP_CLI_BASE to what ../../../bin/resolve-bases.sh --get php-fpm <series>
# and --get php-cli <series> print.
PHP_VERSION=${php_version}
PHP_FPM_BASE=${php_fpm_base}
PHP_CLI_BASE=${php_cli_base}
IONCUBE=${ioncube}
PHP_MEMORY_LIMIT=512M
PHP_UPLOAD_MAX_FILESIZE=2048M
PHP_POST_MAX_SIZE=2048M
PHP_MAX_EXECUTION_TIME=300

# KVS support access (Kernel Team login with the kvs_support account).
# KVS ships it enabled; true turns it off, the admin dashboard re-enables it.
DISABLE_KVS_SUPPORT_ACCESS=false

# Cache
COMPOSE_PROFILES=dragonfly
CACHE_MEMORY=512
EOF
    )
    log_success "Generated .env file"

    # Copy docker-compose template
    cp "${SCRIPT_DIR}/docker-compose.site.yml.template" "${site_dir}/docker-compose.yml"
    log_success "Created docker-compose.yml"

    # Generate Caddy site config. A route that cannot be written leaves no
    # half-made site behind: the site directory goes, and the webroot too
    # when this add created it, so the add can be retried. A webroot that
    # existed before (one remove kept) is left as it was.
    if ! write_caddy_site_config "$domain" "${CADDY_TLS_MODE:-public}" false auto; then
        rm -rf "${site_dir}"
        [ "$webroot_created" = false ] || rm -rf "${webroot}"
        log_error "Removed the half-created site ${domain}"
        return 1
    fi

    echo ""
    log_success "Site ${domain} created successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Start Caddy (if not running):"
    echo "     cd ${SCRIPT_DIR} && ./site-manager.sh caddy-start"
    echo ""
    echo "  2. Start the site:"
    echo "     ./site-manager.sh start ${domain}"
    echo ""
    echo "  3. Access your site at: https://${domain}"
}

# =============================================================================
# Start Site
# =============================================================================

# A start that ends between the cron stop and the "up -d" that starts the
# site again leaves cron stopped, and restart: unless-stopped keeps it
# stopped after a reboot too: the exit says so. Run from the EXIT trap.
STOPPED_CRON_SITE=""
stopped_cron_notice() {
    [ -n "$STOPPED_CRON_SITE" ] || return 0
    log_warn "cron of ${STOPPED_CRON_SITE} is stopped: docker compose start cron in ${SITES_DIR}/${STOPPED_CRON_SITE}, or re-run ./site-manager.sh start ${STOPPED_CRON_SITE}"
}

start_site() {
    local domain="$1"
    local admin_password="${KVS_ADMIN_PASSWORD:-}"
    local generated_admin_password=false
    local attempt
    local admin_table_count
    local default_admin_login
    local admin_login=admin
    validate_domain "$domain" || return 1

    local site_dir="${SITES_DIR}/${domain}"

    if [ ! -d "$site_dir" ]; then
        log_error "Site ${domain} does not exist. Create it first with: ./site-manager.sh add ${domain}"
        exit 1
    fi

    check_caddy_running

    log_info "Starting site: ${domain}"
    cd "$site_dir"

    # kvs-init clears KVS's cron locks and its cron registration
    # (40-configure-database.sh): a cron.php still running on a started
    # site must not see that. The "up -d" below starts cron again.
    log_info "Stopping cron for the initialization..."
    docker compose stop cron
    STOPPED_CRON_SITE=$domain
    trap stopped_cron_notice EXIT

    # Run init containers first
    log_info "Running initialization..."
    docker compose up -d mariadb
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if docker compose exec -T mariadb \
            healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done
    if ! docker compose exec -T mariadb \
        healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1; then
        log_error "MariaDB did not become healthy before site initialization"
        return 1
    fi
    docker compose --profile setup run --rm --no-deps phpmyadmin-init
    if [ -z "$admin_password" ]; then
        if ! admin_table_count=$(docker compose exec -T -e "TABLES_PREFIX=$(site_tables_prefix)" mariadb sh -c '
            MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -N -e \
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"$MARIADB_DATABASE\" AND table_name=\"${TABLES_PREFIX}admin_users\";"
        ' 2>/dev/null); then
            log_error "Could not inspect the KVS admin account before initialization"
            return 1
        fi
        case "$admin_table_count" in
            ''|*[!0-9]*)
                log_error "Invalid KVS admin table count"
                return 1
                ;;
        esac
        if [ "$admin_table_count" -eq 0 ]; then
            generated_admin_password=true
        else
            # The primary account is user_id 1 whatever its login, the one
            # 35-harden-admin-users.sh refuses to leave on the default; a
            # renamed one keeps its login, which the password goes with.
            if ! default_admin_login=$(docker compose exec -T -e "TABLES_PREFIX=$(site_tables_prefix)" mariadb sh -c '
                MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -N "$MARIADB_DATABASE" -e \
                    "SELECT login FROM ${TABLES_PREFIX}admin_users WHERE user_id=1 AND pass=MD5(CONCAT(\"pass:\",MD5(\"123\")));"
            ' 2>/dev/null); then
                log_error "Could not verify the KVS admin account before initialization"
                return 1
            fi
            if [ -n "$default_admin_login" ]; then
                generated_admin_password=true
                admin_login=$default_admin_login
            fi
        fi
        if [ "$generated_admin_password" = true ]; then
            admin_password=$(openssl rand -base64 30 | tr -d '/+=' | cut -c 1-32)
        fi
    fi
    KVS_ADMIN_PASSWORD="$admin_password" \
        docker compose --profile setup run --rm --no-deps kvs-init
    if [ "$generated_admin_password" = true ]; then
        echo "Admin login: ${admin_login}"
        echo "One-time admin password: ${admin_password}"
        echo "Save it now; it is not written to the site .env file."
    fi
    unset admin_password

    # Start all services
    log_info "Starting services..."
    docker compose up -d
    STOPPED_CRON_SITE=""

    # Reload Caddy to pick up the new site
    reload_caddy

    log_success "Site ${domain} started!"
    echo ""
    echo "Access your site at: https://${domain}"
    echo "Admin panel: https://${domain}/admin/"
    echo "phpMyAdmin: https://${domain}/phpmyadmin/"
}

# =============================================================================
# Stop Site
# =============================================================================

stop_site() {
    local domain="$1"
    validate_domain "$domain" || return 1

    local site_dir="${SITES_DIR}/${domain}"

    if [ ! -d "$site_dir" ]; then
        log_error "Site ${domain} does not exist"
        exit 1
    fi

    log_info "Stopping site: ${domain}"
    cd "$site_dir"
    docker compose down

    log_success "Site ${domain} stopped"
}

# =============================================================================
# Remove Site
# =============================================================================

# remove of a site directory without docker-compose.yml, which an add that
# stopped early leaves (without an .env too when it stopped at the webroot).
# Compose cannot take such a site down, and run there it would look in the
# parent directories and find the primary's docker-compose.yml. While a
# container created from the directory, or a volume of a project the site's
# .env or directory name gives, exists, nothing is deleted. Otherwise
# nothing of the site runs: an empty directory is deleted, rmdir refusing
# any other, and for a directory with files left the command that deletes
# it is printed.
remove_incomplete_site() {
    local domain="$1" site_dir="$2"
    local projects candidate volumes held="" seen=" "
    local -a names=()

    if ! projects=$(dir_compose_projects "$site_dir"); then
        log_error "Could not list the containers created from ${site_dir}"
        return 1
    fi
    [ -z "$projects" ] || held="containers of ${projects//$'\n'/, }"
    if [ -f "${site_dir}/.env" ]; then
        names+=("$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "${site_dir}/.env" | head -n 1)")
        names+=("$(sed -n 's/^SITE_PREFIX=//p' "${site_dir}/.env" | head -n 1)")
    fi
    names+=("$(compose_default_project "$domain")")
    for candidate in "${names[@]}"; do
        [ -n "$candidate" ] && [[ "$seen" != *" ${candidate} "* ]] || continue
        seen="${seen}${candidate} "
        if ! volumes=$(docker volume ls --filter "label=com.docker.compose.project=${candidate}" \
            --format '{{.Name}}'); then
            log_error "Could not list the volumes of ${candidate}"
            return 1
        fi
        [ -z "$volumes" ] || held="${held:+${held}; }volumes of ${candidate}: ${volumes//$'\n'/, }"
    done
    if [ -n "$held" ]; then
        log_error "${site_dir} has no docker-compose.yml, but Docker still holds ${held}"
        log_error "Copy the site's docker-compose.yml back, then run remove again: cp ${SCRIPT_DIR}/docker-compose.site.yml.template ${site_dir}/docker-compose.yml"
        return 1
    fi

    log_info "Nothing of ${domain} runs: ${site_dir} has no docker-compose.yml, and no container or volume belongs to it (an add stopped before it finished)"
    if rmdir "$site_dir" 2>/dev/null; then
        log_success "Removed the empty site directory ${site_dir}"
        return 0
    fi
    log_error "${site_dir} is not empty: check what it holds, then delete it with:"
    printf '  rm -r -- %q\n' "$site_dir"
    return 1
}

remove_site() {
    local domain="$1"
    validate_domain "$domain" || return 1

    local site_dir="${SITES_DIR}/${domain}"
    local caddy_config="${CADDY_SITES_DIR}/${domain}.caddy"
    local webroot="${WEBROOT_BASE}/${domain}"

    if [ ! -d "$site_dir" ]; then
        log_error "Site ${domain} does not exist"
        exit 1
    fi

    # Compose takes the site down from its docker-compose.yml, which an add
    # that stopped early never wrote.
    if [ ! -f "${site_dir}/docker-compose.yml" ]; then
        local incomplete_status=0
        remove_incomplete_site "$domain" "$site_dir" || incomplete_status=$?
        exit "$incomplete_status"
    fi

    echo -e "${YELLOW}WARNING: This will remove all data for ${domain}!${NC}"
    echo "  - Docker containers and volumes"
    echo "  - Site configuration"
    [ -d "$webroot" ] && echo "  - Webroot: ${webroot}"
    echo ""
    read -rp "Are you sure? (type 'yes' to confirm): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Aborted"
        exit 0
    fi

    log_info "Removing site: ${domain}"

    # Only tear down a Compose project that is this site's own. A site created
    # before add refused the primary's project can share its name, and down -v
    # on it would delete the primary's containers and volumes. Refuse a project
    # the primary records (docker/.env, .primary.env): with the primary stopped
    # by 'docker compose down' only its volumes remain and no container label
    # tells the two apart. Refuse too when the project has containers created
    # from another directory, comparing resolved paths because Compose records
    # the path it was started from, symlinks included.
    local remove_project site_prefix working_dirs primary_prefix site_real wd wd_real foreign_dir=""
    remove_project=$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$site_dir/.env" | head -n 1)
    # A site added before add wrote COMPOSE_PROJECT_NAME runs under the
    # project Compose derives from its directory, not under its SITE_PREFIX:
    # down -v on SITE_PREFIX found nothing, and the site's containers and
    # volumes stayed with no configuration left.
    if [ -z "$remove_project" ]; then
        site_prefix=$(sed -n 's/^SITE_PREFIX=//p' "$site_dir/.env" | head -n 1)
        if ! remove_project=$(site_project_without_name "$domain" "$site_dir" "$site_prefix"); then
            exit 1
        fi
        log_info "${site_dir}/.env names no COMPOSE_PROJECT_NAME; the site runs as project ${remove_project}"
    fi
    for primary_prefix in "$(single_mode_primary_prefix)" "$(primary_site_value SITE_PREFIX)"; do
        if [ -n "$primary_prefix" ] && [ "$primary_prefix" = "$remove_project" ]; then
            log_error "Refusing 'docker compose down -v' for project ${remove_project}: the primary site uses that project name"
            log_error "Remove aborted to protect the primary's containers and volumes"
            exit 1
        fi
    done
    working_dirs=$(compose_project_working_dirs "$remove_project")
    if [ -n "$working_dirs" ]; then
        site_real=$(cd "$site_dir" && pwd -P)
        while IFS= read -r wd; do
            if [ -z "$wd" ]; then
                foreign_dir="(a container with no working directory label)"
                continue
            fi
            wd_real=$(cd "$wd" 2>/dev/null && pwd -P) || wd_real=$wd
            [ "$wd_real" = "$site_real" ] || foreign_dir=$wd
        done <<< "$working_dirs"
    fi
    if [ -n "$foreign_dir" ]; then
        log_error "Refusing 'docker compose down -v' for project ${remove_project}: it has containers from ${foreign_dir}, not ${site_dir}"
        log_error "The primary site may share this project name; remove aborted to protect its data"
        exit 1
    fi

    # Stop containers and remove volumes. The project is named explicitly so
    # a COMPOSE_PROJECT_NAME exported in the operator's shell, which Compose
    # prefers over the site's .env, cannot point down -v at another stack.
    # Compose finds the files itself, in the site directory, as it does for
    # start and stop: the site's docker-compose.yml, checked above, so it
    # never looks in the parent directories, and the override next to it
    # (README.md recommends docker-compose.override.yml), whose services and
    # volumes are the site's too. --remove-orphans takes the containers of
    # services no longer in those files. The removal stops here, with the
    # site directory and its route kept, when down -v fails, leaves volumes
    # of the project behind or they cannot be listed: deleting the
    # configuration anyway orphaned those volumes.
    cd "$site_dir"
    local down_status=0 left_volumes
    docker compose -p "$remove_project" down -v --remove-orphans || down_status=$?
    if [ "$down_status" -ne 0 ]; then
        log_error "'docker compose down -v' failed (status ${down_status}); the site directory and its route are kept"
        log_error "Fix the error above and run remove again"
        exit 1
    fi
    if ! left_volumes=$(docker volume ls --filter "label=com.docker.compose.project=${remove_project}" \
        --format '{{.Name}}'); then
        log_error "Could not list the volumes of ${remove_project} after 'docker compose down -v'; the site directory and its route are kept"
        log_error "Fix the error above and run remove again"
        exit 1
    fi
    if [ -n "$left_volumes" ]; then
        log_error "Volumes of project ${remove_project} are still present after 'docker compose down -v':"
        printf '%s\n' "$left_volumes" | sed 's/^/  /' >&2
        log_error "The site directory and its route are kept; remove those volumes, then run remove again"
        exit 1
    fi

    # Remove Caddy config
    rm -f "$caddy_config"
    log_success "Removed Caddy config"

    # Remove site directory
    rm -rf "$site_dir"
    log_success "Removed site directory"

    # Remove webroot (ask first)
    if [ -d "$webroot" ]; then
        # EOF answers no: the removal must still reach the Caddy reload.
        read -rp "Also remove webroot ${webroot}? [y/N]: " remove_webroot || remove_webroot=""
        if [ "$remove_webroot" = "y" ] || [ "$remove_webroot" = "Y" ]; then
            rm -rf "$webroot"
            log_success "Removed webroot: ${webroot}"
        else
            log_info "Webroot preserved at: ${webroot}"
        fi
    fi

    # Reload Caddy
    if docker ps --format '{{.Names}}' | grep -Fxq "kvs-caddy"; then
        reload_caddy
    fi

    log_success "Site ${domain} removed completely"
}

# =============================================================================
# List Sites
# =============================================================================

list_sites() {
    echo -e "${CYAN}=== KVS Sites ===${NC}"
    echo ""

    if [ ! -d "$SITES_DIR" ] || [ -z "$(ls -A "$SITES_DIR" 2>/dev/null)" ]; then
        log_info "No sites configured yet"
        echo "Add a site with: ./site-manager.sh add <domain>"
        return
    fi

    for site_dir in "$SITES_DIR"/*/; do
        if [ -d "$site_dir" ]; then
            local domain
            domain=$(basename "$site_dir")
            local domain_safe
            domain_safe=$(domain_to_safe "$domain")
            local site_prefix="kvs-${domain_safe}"

            if [ -f "${site_dir}/.env" ]; then
                local configured_prefix
                configured_prefix=$(sed -n 's/^SITE_PREFIX=//p' "${site_dir}/.env" | head -n 1)
                [ -n "$configured_prefix" ] && site_prefix="$configured_prefix"
            fi

            # Check if running
            if docker ps --format '{{.Names}}' | grep -Fxq "${site_prefix}-nginx"; then
                echo -e "  ${GREEN}●${NC} ${domain} (running)"
            else
                echo -e "  ${RED}○${NC} ${domain} (stopped)"
            fi
        fi
    done
    echo ""
}

# =============================================================================
# Status
# =============================================================================

show_status() {
    echo -e "${CYAN}=== KVS Multi-Site Status ===${NC}"
    echo ""

    # Caddy status
    if docker ps --format '{{.Names}}' | grep -Fxq "kvs-caddy"; then
        echo -e "Caddy Proxy: ${GREEN}running${NC}"
    else
        echo -e "Caddy Proxy: ${RED}stopped${NC}"
    fi
    echo ""

    # Sites status
    list_sites

    # Show Caddy configs
    echo -e "${CYAN}=== Caddy Site Configs ===${NC}"
    ls -la "$CADDY_SITES_DIR"/*.caddy 2>/dev/null || echo "  No site configs"
    echo ""
}

# =============================================================================
# Start Caddy
# =============================================================================

# installation_email prints the EMAIL of the installation's docker/.env, the
# one setup.sh saves: the last EMAIL line, as Compose and the shell take it,
# with an optional "export " prefix, quotes, an inline comment or a CRLF line
# ending. Nothing when the file or the line is missing.
installation_email() {
    local value

    [ -f "$INSTALLATION_ENV_FILE" ] || return 0
    value=$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?EMAIL=//p' "$INSTALLATION_ENV_FILE" | tail -n 1)
    # A quoted value ends at its closing quote; an unquoted one at an inline
    # comment, without the trailing blanks (a CRLF line's carriage return).
    case "$value" in
        \"*)
            value=${value#\"}
            value=${value%%\"*}
            ;;
        \'*)
            value=${value#\'}
            value=${value%%\'*}
            ;;
        *)
            value=${value%%[[:space:]]#*}
            value=${value%"${value##*[![:space:]]}"}
            ;;
    esac
    printf '%s\n' "$value"
}

# An address an ACME CA takes as the contact of an account, as setup.sh
# checks it; the .env.example placeholder is well formed, but Let's Encrypt
# refuses example.com.
usable_acme_email() {
    [ "$1" != "admin@example.com" ] &&
        [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.([a-zA-Z]{2,}|xn--[a-zA-Z0-9-]+)$ ]]
}

# caddy_routes_use_acme: whether a route in caddy/sites gets its certificate
# through Caddy's automatic HTTPS, from an ACME CA: a route file with no tls
# directive. "tls internal" and a certificate of its own need no account.
caddy_routes_use_acme() {
    local file

    [ -d "$CADDY_SITES_DIR" ] || return 1
    for file in "$CADDY_SITES_DIR"/*.caddy; do
        [ -e "$file" ] || continue
        grep -Eq '^[[:space:]]*tls[[:space:]]' "$file" || return 0
    done
    return 1
}

# resolve_caddy_acme_email sets CADDY_ACME_EMAIL to the contact caddy-start
# gives Caddy. setup.sh passes its EMAIL as ACME_EMAIL, empty when it has
# none. Run by hand, caddy-start had none, and Compose recreated Caddy with
# admin@example.com, which Let's Encrypt refuses: no new certificate, no
# renewal. Without ACME_EMAIL, the installation's EMAIL is used. An address
# from either that is not usable counts as none: CADDY_ACME_EMAIL is then
# empty (the compose file default) when no route needs an ACME certificate,
# and the function fails, saying what to set, when one does.
resolve_caddy_acme_email() {
    CADDY_ACME_EMAIL="${ACME_EMAIL:-}"
    if [ -z "$CADDY_ACME_EMAIL" ]; then
        CADDY_ACME_EMAIL=$(installation_email)
    fi
    usable_acme_email "$CADDY_ACME_EMAIL" && return 0
    CADDY_ACME_EMAIL=""
    caddy_routes_use_acme || return 0
    if [ -n "${ACME_EMAIL:-}" ]; then
        log_error "No ACME email for Caddy: ACME_EMAIL (${ACME_EMAIL}) is the admin@example.com placeholder or invalid, and the routes in ${CADDY_SITES_DIR} need certificates from Let's Encrypt, which refuses that contact"
        echo "  Set a valid EMAIL in ${INSTALLATION_ENV_FILE} (setup.sh passes it as ACME_EMAIL), or export a valid ACME_EMAIL, then run: cd ${SCRIPT_DIR} && ./site-manager.sh caddy-start"
    else
        log_error "No ACME email for Caddy: EMAIL in ${INSTALLATION_ENV_FILE} is missing, the admin@example.com placeholder or invalid, and the routes in ${CADDY_SITES_DIR} need certificates from Let's Encrypt, which refuses that contact"
        echo "  Set EMAIL there (or export ACME_EMAIL), then run: cd ${SCRIPT_DIR} && ./site-manager.sh caddy-start"
    fi
    return 1
}

start_caddy() {
    resolve_caddy_acme_email || return 1

    log_info "Starting Caddy proxy..."
    mkdir -p "$CADDY_SITES_DIR"
    ensure_proxy_network
    cd "$SCRIPT_DIR"
    # Preserve the historical implicit Compose project and its certificate
    # volumes while still using the externally managed kvs-proxy network.
    # An empty ACME_EMAIL leaves the compose file default, for routes that
    # need no ACME account.
    ACME_EMAIL="$CADDY_ACME_EMAIL" docker compose -p multi-site -f docker-compose.caddy.yml up -d
    wait_for_caddy
    reload_caddy
    log_success "Caddy proxy started"
}

# =============================================================================
# Stop Caddy
# =============================================================================

stop_caddy() {
    log_info "Stopping Caddy proxy..."
    cd "$SCRIPT_DIR"
    docker compose -p multi-site -f docker-compose.caddy.yml down
    log_success "Caddy proxy stopped"
}

# =============================================================================
# Usage
# =============================================================================

usage() {
    echo "KVS Multi-Site Manager"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  add <domain>       Add a new KVS site"
    echo "  remove <domain>    Remove a site (with data!)"
    echo "  start <domain>     Start a site"
    echo "  stop <domain>      Stop a site"
    echo "  list               List all sites"
    echo "  status             Show status of all sites"
    echo "  proxy-config <domain> [public|internal] [true|false] [auto|true|false]"
    echo "                     Generate only the central Caddy route"
    echo "  primary-config <domain> <site-prefix> [public|internal] [true|false]"
    echo "                     Reserve and route the primary Compose site"
    echo "  primary-remove <domain> <site-prefix>"
    echo "                     Remove the primary route after Caddy is stopped"
    echo "  proxy-network      Create the shared proxy network"
    echo "  caddy-start        Start Caddy proxy"
    echo "  caddy-acme-check   Check that Caddy has the ACME email its routes need"
    echo "  caddy-stop         Stop Caddy proxy"
    echo ""
    echo "Examples:"
    echo "  $0 add example.com"
    echo "  $0 start example.com"
    echo "  $0 list"
}

# =============================================================================
# Main
# =============================================================================

# Only add reads IONCUBE from the environment, for the .env of the site it
# creates. Compose prefers a variable of the environment over the site's
# .env, so an IONCUBE exported for an add would set the loader of every site
# started or stopped from the same shell: the other commands drop it.
[ "${1:-}" = add ] || unset IONCUBE

case "${1:-}" in
    add)
        [ -z "${2:-}" ] && { log_error "Domain required"; usage; exit 1; }
        add_site "$2"
        ;;
    remove)
        [ -z "${2:-}" ] && { log_error "Domain required"; usage; exit 1; }
        remove_site "$2"
        ;;
    start)
        [ -z "${2:-}" ] && { log_error "Domain required"; usage; exit 1; }
        start_site "$2"
        ;;
    stop)
        [ -z "${2:-}" ] && { log_error "Domain required"; usage; exit 1; }
        stop_site "$2"
        ;;
    list)
        list_sites
        ;;
    status)
        show_status
        ;;
    proxy-config)
        [ -z "${2:-}" ] && { log_error "Domain required"; usage; exit 1; }
        write_caddy_site_config "$2" "${3:-public}" "${4:-false}" "${5:-auto}"
        ;;
    primary-config)
        [ -z "${2:-}" ] && { log_error "Domain required"; usage; exit 1; }
        [ -z "${3:-}" ] && { log_error "Site prefix required"; usage; exit 1; }
        configure_primary_site "$2" "$3" "${4:-public}" "${5:-false}"
        ;;
    primary-remove)
        [ -z "${2:-}" ] && { log_error "Domain required"; usage; exit 1; }
        [ -z "${3:-}" ] && { log_error "Site prefix required"; usage; exit 1; }
        remove_primary_site "$2" "$3"
        ;;
    proxy-network)
        ensure_proxy_network
        ;;
    caddy-start)
        start_caddy
        ;;
    caddy-acme-check)
        resolve_caddy_acme_email
        ;;
    caddy-stop)
        stop_caddy
        ;;
    *)
        usage
        exit 1
        ;;
esac
