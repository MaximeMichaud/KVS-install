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

# The table prefix written in the setup.php of the KVS archive a new site
# starts from (ktvs_ for every archive KVS ships).
archive_tables_prefix() {
    local archive pattern prefix

    archive=$(compgen -G "${KVS_ARCHIVE_DIR}/KVS_*.zip" | head -n 1)
    pattern="s/^[[:space:]]*\\\$config\\[[[:space:]]*['\"]tables_prefix['\"][[:space:]]*\\][[:space:]]*=[[:space:]]*['\"]([^'\"]*)['\"].*/\\1/p"
    prefix=""
    if [ -n "$archive" ] && command -v unzip >/dev/null 2>&1; then
        prefix=$(unzip -p "$archive" admin/include/setup.php 2>/dev/null | sed -n -E "$pattern" | head -n 1)
    fi
    [[ "$prefix" =~ ^[A-Za-z0-9_]{1,32}$ ]] || prefix=ktvs_
    printf '%s\n' "$prefix"
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

write_caddy_site_config() {
    local domain="$1"
    local tls_mode="${2:-public}"
    local use_www="${3:-false}"
    local include_www="${4:-auto}"
    local canonical_host
    local alternate_host=""
    local dot_count
    local tls_directive=""
    local temp_file

    validate_domain "$domain" || return 1
    case "$tls_mode" in
        public)
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
    if [ "$use_www" = true ]; then
        include_www=true
        canonical_host="www.${domain}"
        alternate_host="$domain"
    else
        canonical_host="$domain"
        if [ "$include_www" = true ]; then
            alternate_host="www.${domain}"
        fi
    fi

    mkdir -p "$CADDY_SITES_DIR"
    temp_file=$(mktemp "${CADDY_SITES_DIR}/.${domain}.caddy.XXXXXX")
    {
        cat << EOF
# KVS Site: ${domain}
${canonical_host} {
    reverse_proxy n.${domain}:80 {
        health_uri /health
        health_interval 30s
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
            cat << EOF

${alternate_host} {
    redir https://${canonical_host}{uri} permanent
${tls_directive}
}
EOF
        fi
    } > "$temp_file"
    mv -f "$temp_file" "${CADDY_SITES_DIR}/${domain}.caddy"
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

add_site() {
    local domain="$1"
    validate_domain "$domain" || return 1
    validate_primary_site_file || return 1

    local domain_safe
    domain_safe=$(domain_to_safe "$domain")
    local site_dir="${SITES_DIR}/${domain}"
    local site_prefix="kvs-${domain_safe}"
    local primary_domain

    primary_domain=$(primary_site_value DOMAIN)
    if [ "$primary_domain" = "$domain" ]; then
        log_error "Domain ${domain} is reserved by the primary site"
        return 1
    fi

    log_info "Adding site: ${domain}"

    # Check if site already exists
    if [ -d "$site_dir" ]; then
        log_error "Site ${domain} already exists at ${site_dir}"
        exit 1
    fi

    if [ -e "${CADDY_SITES_DIR}/${domain}.caddy" ]; then
        log_error "A Caddy route already exists for ${domain}"
        return 1
    fi

    ensure_site_prefix_available "$domain" "$site_prefix" || return 1

    # Check KVS archive
    if ! compgen -G "${KVS_ARCHIVE_DIR}/KVS_*.zip" >/dev/null; then
        log_error "No KVS archive found in ${KVS_ARCHIVE_DIR}/"
        exit 1
    fi

    # Create site directory
    mkdir -p "$SITES_DIR" "$CADDY_SITES_DIR"
    mkdir -p "${site_dir}"
    log_success "Created site directory: ${site_dir}"

    # Create webroot directory
    local webroot="${WEBROOT_BASE}/${domain}"
    mkdir -p "${webroot}"
    chown 1000:1000 "${webroot}"
    log_success "Created webroot: ${webroot}"

    # Generate .env file. The table prefix is the one of the archive's
    # setup.php (ktvs_ for every archive KVS ships); the init reads it from
    # the site itself, .env carries it for the scripts outside the container.
    local tables_prefix
    tables_prefix=$(archive_tables_prefix)
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
MARIADB_VERSION=11.8
MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
MARIADB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')

# PHP
PHP_VERSION=8.1
IONCUBE=YES
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

    # Generate Caddy site config
    write_caddy_site_config "$domain" "${CADDY_TLS_MODE:-public}" false auto

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

start_site() {
    local domain="$1"
    local admin_password="${KVS_ADMIN_PASSWORD:-}"
    local generated_admin_password=false
    local attempt
    local admin_table_count
    local default_admin_count
    validate_domain "$domain" || return 1

    local site_dir="${SITES_DIR}/${domain}"

    if [ ! -d "$site_dir" ]; then
        log_error "Site ${domain} does not exist. Create it first with: ./site-manager.sh add ${domain}"
        exit 1
    fi

    check_caddy_running

    log_info "Starting site: ${domain}"
    cd "$site_dir"

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
            if ! default_admin_count=$(docker compose exec -T -e "TABLES_PREFIX=$(site_tables_prefix)" mariadb sh -c '
                MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -N "$MARIADB_DATABASE" -e \
                    "SELECT COUNT(*) FROM ${TABLES_PREFIX}admin_users WHERE user_id=1 AND login=\"admin\" AND pass=MD5(CONCAT(\"pass:\",MD5(\"123\")));"
            ' 2>/dev/null); then
                log_error "Could not verify the KVS admin account before initialization"
                return 1
            fi
            case "$default_admin_count" in
                ''|*[!0-9]*)
                    log_error "Invalid default admin account count"
                    return 1
                    ;;
            esac
            [ "$default_admin_count" -gt 0 ] && generated_admin_password=true
        fi
        if [ "$generated_admin_password" = true ]; then
            admin_password=$(openssl rand -base64 30 | tr -d '/+=' | cut -c 1-32)
        fi
    fi
    KVS_ADMIN_PASSWORD="$admin_password" \
        docker compose --profile setup run --rm --no-deps kvs-init
    if [ "$generated_admin_password" = true ]; then
        echo "Admin login: admin"
        echo "One-time admin password: ${admin_password}"
        echo "Save it now; it is not written to the site .env file."
    fi
    unset admin_password

    # Start all services
    log_info "Starting services..."
    docker compose up -d

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

    # Stop containers and remove volumes
    cd "$site_dir"
    docker compose down -v 2>/dev/null || true

    # Remove Caddy config
    rm -f "$caddy_config"
    log_success "Removed Caddy config"

    # Remove site directory
    rm -rf "$site_dir"
    log_success "Removed site directory"

    # Remove webroot (ask first)
    if [ -d "$webroot" ]; then
        read -rp "Also remove webroot ${webroot}? [y/N]: " remove_webroot
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

start_caddy() {
    log_info "Starting Caddy proxy..."
    mkdir -p "$CADDY_SITES_DIR"
    ensure_proxy_network
    cd "$SCRIPT_DIR"
    # Preserve the historical implicit Compose project and its certificate
    # volumes while still using the externally managed kvs-proxy network.
    docker compose -p multi-site -f docker-compose.caddy.yml up -d
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
    caddy-stop)
        stop_caddy
        ;;
    *)
        usage
        exit 1
        ;;
esac
