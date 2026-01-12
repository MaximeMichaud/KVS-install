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

# =============================================================================
# Helper Functions
# =============================================================================

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

domain_to_safe() {
    echo "$1" | tr '.' '-' | tr '[:upper:]' '[:lower:]'
}

check_caddy_running() {
    if ! docker ps --format '{{.Names}}' | grep -q "kvs-caddy"; then
        log_error "Caddy is not running. Start it first:"
        echo "  cd ${SCRIPT_DIR} && docker compose -f docker-compose.caddy.yml up -d"
        exit 1
    fi
}

reload_caddy() {
    log_info "Reloading Caddy configuration..."
    docker exec kvs-caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
    log_success "Caddy reloaded"
}

# =============================================================================
# Add Site
# =============================================================================

add_site() {
    local domain="$1"
    local domain_safe
    domain_safe=$(domain_to_safe "$domain")
    local site_dir="${SITES_DIR}/${domain}"
    local site_prefix="kvs-${domain_safe}"

    log_info "Adding site: ${domain}"

    # Check if site already exists
    if [ -d "$site_dir" ]; then
        log_error "Site ${domain} already exists at ${site_dir}"
        exit 1
    fi

    # Check KVS archive
    if ! ls ../kvs-archive/KVS_*.zip 1>/dev/null 2>&1; then
        log_error "No KVS archive found in ../kvs-archive/"
        exit 1
    fi

    # Create site directory
    mkdir -p "${site_dir}"
    log_success "Created site directory: ${site_dir}"

    # Create webroot directory
    local webroot="/var/www/${domain}"
    mkdir -p "${webroot}"
    chown 1000:1000 "${webroot}"
    log_success "Created webroot: ${webroot}"

    # Generate .env file
    cat > "${site_dir}/.env" << EOF
# Site configuration for ${domain}
DOMAIN=${domain}
SITE_PREFIX=${site_prefix}
USE_WWW=false

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

# Cache
COMPOSE_PROFILES=dragonfly
CACHE_MEMORY=512
EOF
    log_success "Generated .env file"

    # Copy docker-compose template
    cp "${SCRIPT_DIR}/docker-compose.site.yml.template" "${site_dir}/docker-compose.yml"
    log_success "Created docker-compose.yml"

    # Generate Caddy site config
    # Detect if subdomain (more than 2 parts = subdomain, no www needed)
    local domain_parts
    domain_parts=$(echo "$domain" | tr '.' '\n' | wc -l)
    local server_names="$domain"
    if [ "$domain_parts" -le 2 ]; then
        server_names="${domain}, www.${domain}"
    fi

    cat > "${CADDY_SITES_DIR}/${domain}.caddy" << EOF
# KVS Site: ${domain}
${server_names} {
    reverse_proxy ${site_prefix}-nginx:80 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
    }

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
    log_success "Generated Caddy config: ${CADDY_SITES_DIR}/${domain}.caddy"

    echo ""
    log_success "Site ${domain} created successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Start Caddy (if not running):"
    echo "     cd ${SCRIPT_DIR} && docker compose -f docker-compose.caddy.yml up -d"
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
    docker compose --profile setup up phpmyadmin-init
    docker compose --profile setup up kvs-init

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
    local site_dir="${SITES_DIR}/${domain}"
    local caddy_config="${CADDY_SITES_DIR}/${domain}.caddy"
    local webroot="/var/www/${domain}"

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
    if docker ps --format '{{.Names}}' | grep -q "kvs-caddy"; then
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

    if [ ! -d "$SITES_DIR" ] || [ -z "$(ls -A $SITES_DIR 2>/dev/null)" ]; then
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

            # Check if running
            if docker ps --format '{{.Names}}' | grep -q "${site_prefix}-nginx"; then
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
    if docker ps --format '{{.Names}}' | grep -q "kvs-caddy"; then
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
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.caddy.yml up -d
    log_success "Caddy proxy started"
}

# =============================================================================
# Stop Caddy
# =============================================================================

stop_caddy() {
    log_info "Stopping Caddy proxy..."
    cd "$SCRIPT_DIR"
    docker compose -f docker-compose.caddy.yml down
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

mkdir -p "$SITES_DIR"
mkdir -p "$CADDY_SITES_DIR"

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
