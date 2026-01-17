#!/bin/bash
# shellcheck disable=SC1091
set -e

#################################################################
# Debug Logging Setup
#################################################################
readonly DEBUG_LOG="/opt/kvs/logs/setup-debug.log"
readonly TRACE_LOG="/opt/kvs/logs/setup-trace.log"

# Create logs directory
mkdir -p /opt/kvs/logs 2>/dev/null || true

# Initialize logs
{
    echo "========================================"
    echo "KVS Docker Setup - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo ""
} >> "$DEBUG_LOG" 2>/dev/null || true

# Enable command tracing (set -x) to a separate log
export PS4='+ $(date "+%H:%M:%S") ${BASH_SOURCE##*/}:${LINENO}: '
exec 19>>"$TRACE_LOG" 2>/dev/null || exec 19>/dev/null
BASH_XTRACEFD=19
set -x

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

    --help      Show this help message

EXAMPLES:
    # Production installation
    ./setup.sh

    # Development mode (fast testing)
    ./setup.sh --dev

    # Headless production (CI/CD)
    HEADLESS=y DOMAIN=example.com EMAIL=admin@example.com ./setup.sh
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
    export EMAIL="${EMAIL:-dev@localhost}"

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
    MODE_CHOICE=${MODE_CHOICE:-1}           # 1=performance, 2=compatibility
    VOLUME_CHOICE=${VOLUME_CHOICE:-2}       # For credential mismatch: 1=delete volume, 2=exit (safe default)
    STOP_EXISTING=${STOP_EXISTING:-Y}       # Y=stop existing containers
    DNS_CHOICE=${DNS_CHOICE:-2}             # 1=retry, 2=continue anyway, 3=exit
    GEOIP_CHOICE=${GEOIP_CHOICE:-1}         # 1=download GeoLite2-Country, 2=skip
    SKIP_PRESS_ENTER=1                      # Skip "press enter" prompts
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# Pre-flight checks before installation
preflight_checks() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                     Pre-flight Checks                            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    local failed=0

    # 1. Docker installed
    if command -v docker >/dev/null 2>&1; then
        local docker_version
        docker_version=$(docker --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        echo -e "${GREEN}✓${NC} Docker installed: ${docker_version}"
    else
        echo -e "${RED}✗${NC} Docker not installed"
        echo "  Install: curl -fsSL https://get.docker.com | sh"
        ((failed++))
    fi

    # 2. Docker Compose installed
    if docker compose version >/dev/null 2>&1; then
        local compose_version
        compose_version=$(docker compose version | grep -oP '\d+\.\d+\.\d+' | head -1)
        echo -e "${GREEN}✓${NC} Docker Compose installed: ${compose_version}"
    else
        echo -e "${RED}✗${NC} Docker Compose not installed"
        echo "  Docker Compose v2 is required (plugin, not standalone)"
        ((failed++))
    fi

    # 3. Disk space check
    local free_gb
    free_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
    if (( free_gb >= 20 )); then
        echo -e "${GREEN}✓${NC} Disk space: ${free_gb} GB available"
    elif (( free_gb >= 10 )); then
        echo -e "${YELLOW}⚠${NC} Disk space: ${free_gb} GB available (minimum 10 GB, recommended 20 GB)"
    else
        echo -e "${RED}✗${NC} Disk space: ${free_gb} GB available (need at least 10 GB)"
        ((failed++))
    fi

    # 4. RAM check
    local total_ram free_ram
    total_ram=$(free -m | awk 'NR==2 {print int($2/1024)}')
    free_ram=$(free -m | awk 'NR==2 {print int($7/1024)}')
    if (( total_ram >= 2 )); then
        echo -e "${GREEN}✓${NC} RAM: ${total_ram} GB total, ${free_ram} GB available"
    else
        echo -e "${YELLOW}⚠${NC} RAM: ${total_ram} GB total (recommended 2 GB minimum)"
    fi

    # 5. Internet connectivity
    echo -n "  Checking internet connectivity... "
    if check_internet; then
        echo -e "${GREEN}✓${NC} Connected"
    else
        echo -e "${RED}✗${NC} No internet connection"
        echo "  Internet required for downloading Docker images and dependencies"
        ((failed++))
    fi

    # 6. Required commands
    local required_cmds=("curl" "unzip" "sed" "awk" "grep")
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
        ((failed++))
    fi

    echo ""

    # Exit if critical checks failed
    if (( failed > 0 )); then
        echo -e "${RED}Pre-flight checks failed. Please fix the issues above before continuing.${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ All pre-flight checks passed${NC}"
    echo ""
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
            [ -s "$logfile" ] && echo "    Error:" && head -10 "$logfile" | sed 's/^/    /'
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
            [ -s "$logfile" ] && head -10 "$logfile" | sed 's/^/    /'
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
    OPTIONS_TABLE=$(docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$DOMAIN" -N -e \
        "SHOW TABLES LIKE '%options%';" 2>/dev/null | grep -E 'options$' | head -1) || OPTIONS_TABLE=""

    if [ -n "$OPTIONS_TABLE" ]; then
        # Update the disk space limit setting (|| true to prevent set -e crash)
        # KVS uses 'variable' column, not 'name'
        docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$DOMAIN" -e \
            "UPDATE $OPTIONS_TABLE SET value='$MIN_FREE_SPACE' WHERE variable='MAIN_SERVER_MIN_FREE_SPACE_MB';" 2>/dev/null || true

        # Also update storage server group limit
        docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" "$DOMAIN" -e \
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

# Install gum silently at startup
install_gum

# Run pre-flight checks
preflight_checks

echo -e "${CYAN}=== KVS Docker Setup ===${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Please run as root${NC}"
    exit 1
fi

# Detect existing installation and warn
# Look for KVS-related containers (any prefix ending with -php, -mariadb, etc.)
EXISTING_CONTAINERS=$(docker ps -a --format "{{.Names}}" 2>/dev/null | grep -cE -- '-(php|mariadb|nginx|dragonfly|memcached|cron)$') || EXISTING_CONTAINERS=0
EXISTING_VOLUMES=$(docker volume ls --filter "name=docker_" -q 2>/dev/null | wc -l)

if [ "$EXISTING_CONTAINERS" -gt 0 ] || [ "$EXISTING_VOLUMES" -gt 0 ]; then
    echo -e "${YELLOW}WARNING: Re-running on existing installation (${EXISTING_CONTAINERS} container(s), ${EXISTING_VOLUMES} volume(s))${NC}"
    echo -e "${YELLOW}Persisted data from a previous run may cause issues if it was misconfigured.${NC}"
    echo ""
fi

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

# Load environment
source .env

# Domain validation
validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Email validation
validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

# Prompt for domain
if [ "$DOMAIN" = "example.com" ]; then
    while true; do
        echo -n "Enter your domain (e.g., mysite.com): "
        read -r DOMAIN
        if validate_domain "$DOMAIN"; then
            sed -i "s/DOMAIN=example.com/DOMAIN=$DOMAIN/" .env
            break
        else
            echo -e "${RED}Invalid domain format. Please try again.${NC}"
        fi
    done
fi

# Site prefix for container naming (multi-site support)
select_site_prefix() {
    echo ""
    echo -e "${CYAN}Container Prefix (for multi-site support)${NC}"

    # Generate default from domain (remove TLD)
    # e.g., maximemichaud.ca -> maximemichaud, example.com -> example
    DEFAULT_PREFIX="${DOMAIN%.*}"
    # Sanitize: lowercase, replace dots/underscores with hyphens
    DEFAULT_PREFIX=$(echo "$DEFAULT_PREFIX" | tr '[:upper:]' '[:lower:]' | tr '._' '-')

    echo "Container names will be: {prefix}-php, {prefix}-mariadb, etc."
    echo "  Default: kvs-${DEFAULT_PREFIX} (e.g., kvs-${DEFAULT_PREFIX}-php)"

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
                if [[ "$SITE_PREFIX" =~ ^[a-z][a-z0-9-]*$ ]]; then
                    break
                else
                    echo -e "${RED}Invalid prefix. Use lowercase letters, numbers, and hyphens only.${NC}"
                fi
            done
            echo -e "${GREEN}Using custom prefix: ${SITE_PREFIX}${NC}"
            ;;
        *)
            SITE_PREFIX="kvs-${DEFAULT_PREFIX}"
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
if [ "$SITE_PREFIX" = "kvs" ]; then
    select_site_prefix
fi

# Ensure COMPOSE_PROJECT_NAME matches SITE_PREFIX (for existing .env files)
if [ "$COMPOSE_PROJECT_NAME" != "$SITE_PREFIX" ] 2>/dev/null; then
    if grep -q "^COMPOSE_PROJECT_NAME=" .env; then
        sed -i "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=$SITE_PREFIX/" .env
    else
        echo "COMPOSE_PROJECT_NAME=$SITE_PREFIX" >> .env
    fi
    export COMPOSE_PROJECT_NAME="$SITE_PREFIX"
fi

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

# Prompt for email only if using letsencrypt or zerossl
if [ "$SSL_PROVIDER" != "selfsigned" ] && [ "$EMAIL" = "admin@example.com" ]; then
    # Use EMAIL from environment if set (headless mode)
    if [[ -n "$KVS_EMAIL" ]]; then
        EMAIL="$KVS_EMAIL"
        sed -i "s/EMAIL=admin@example.com/EMAIL=$EMAIL/" .env
    else
        while true; do
            echo -n "Enter your email (required for $SSL_PROVIDER): "
        read -r EMAIL
            if validate_email "$EMAIL"; then
                sed -i "s/EMAIL=admin@example.com/EMAIL=$EMAIL/" .env
                break
            else
                echo -e "${RED}Invalid email format. Please try again.${NC}"
            fi
        done
    fi
fi

# MariaDB version selection with endoflife.date API
select_mariadb_version() {
    echo ""
    echo -e "${CYAN}Fetching MariaDB LTS versions from endoflife.date...${NC}"

    # Fetch data from API
    MARIADB_DATA=$(curl -s --connect-timeout 5 "https://endoflife.date/api/mariadb.json" 2>/dev/null)

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
        ((i++))
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
select_php_version() {
    echo ""
    echo -e "${CYAN}Checking KVS version for PHP compatibility...${NC}"

    # Find KVS archive and extract version
    KVS_FILE=$(find kvs-archive -maxdepth 1 -name 'KVS_*.zip' 2>/dev/null | head -n1)
    if [ -z "$KVS_FILE" ]; then
        echo -e "${YELLOW}KVS archive not found yet. Using default PHP 8.1${NC}"
        return
    fi

    # Extract version from filename (KVS_X.X.X_domain.zip)
    KVS_VERSION=$(basename "$KVS_FILE" | grep -oP 'KVS_\K[0-9]+\.[0-9]+\.[0-9]+' || echo "")

    if [ -z "$KVS_VERSION" ]; then
        echo -e "${YELLOW}Could not detect KVS version. Using default PHP 8.1${NC}"
        return
    fi

    echo "Detected KVS version: $KVS_VERSION"

    # Version comparison (major.minor.patch)
    KVS_MAJOR=$(echo "$KVS_VERSION" | cut -d. -f1)
    KVS_MINOR=$(echo "$KVS_VERSION" | cut -d. -f2)
    KVS_PATCH=$(echo "$KVS_VERSION" | cut -d. -f3)

    # Official KVS PHP requirements:
    # 6.4, 6.3, 6.2.1+ → PHP 8.1
    # 6.2.0            → PHP 7.1-7.4
    # 6.1, 6.0         → PHP 7.1-7.4
    # 5.5              → PHP 7.2-7.4

    if [ "$KVS_MAJOR" -lt 6 ]; then
        # KVS 5.x → PHP 7.4
        echo -e "${YELLOW}KVS $KVS_VERSION requires PHP 7.2-7.4${NC}"
        echo -e "${YELLOW}Warning: PHP 7.x is EOL. Consider upgrading KVS.${NC}"
        sed -i "s/PHP_VERSION=.*/PHP_VERSION=7.4/" .env
        echo "Set PHP version to 7.4"
    elif [ "$KVS_MAJOR" -eq 6 ] && [ "$KVS_MINOR" -lt 2 ]; then
        # KVS 6.0-6.1 → PHP 7.4
        echo -e "${YELLOW}KVS $KVS_VERSION requires PHP 7.1-7.4${NC}"
        echo -e "${YELLOW}Warning: PHP 7.x is EOL. Consider upgrading KVS.${NC}"
        sed -i "s/PHP_VERSION=.*/PHP_VERSION=7.4/" .env
        echo "Set PHP version to 7.4"
    elif [ "$KVS_MAJOR" -eq 6 ] && [ "$KVS_MINOR" -eq 2 ] && [ "$KVS_PATCH" -eq 0 ]; then
        # KVS 6.2.0 → PHP 7.4
        echo -e "${YELLOW}KVS 6.2.0 requires PHP 7.1-7.4${NC}"
        echo -e "${YELLOW}Warning: Upgrade to KVS 6.2.1+ for PHP 8.1 support.${NC}"
        sed -i "s/PHP_VERSION=.*/PHP_VERSION=7.4/" .env
        echo "Set PHP version to 7.4"
    else
        # KVS 6.2.1+, 6.3.x, 6.4.x → PHP 8.1
        echo "KVS $KVS_VERSION requires PHP 8.1"
        sed -i "s/PHP_VERSION=.*/PHP_VERSION=8.1/" .env
        echo -e "${GREEN}Set PHP 8.1${NC}"
    fi
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

# Run version selections if using defaults
if [ "$MARIADB_VERSION" = "11.8" ]; then
    select_mariadb_version
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

# Now select PHP version based on KVS
select_php_version

# Auto-detect IonCube encoding
detect_ioncube

# IonCube version selection (only if IonCube detected)
if [ "$IONCUBE" = "YES" ]; then
    select_ioncube
fi

# Reload .env to get user's IonCube choice
source .env

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
            sed -i "s/COMPOSE_PROFILES=.*/COMPOSE_PROFILES=memcached/" .env
            echo -e "${GREEN}Selected Memcached${NC}"
            # Remove orphan dragonfly container if exists (port conflict)
            docker stop "${SITE_PREFIX}-dragonfly" 2>/dev/null || true
            docker rm "${SITE_PREFIX}-dragonfly" 2>/dev/null || true
            ;;
        *)
            sed -i "s/COMPOSE_PROFILES=.*/COMPOSE_PROFILES=dragonfly/" .env
            echo -e "${GREEN}Selected Dragonfly${NC}"
            # Remove orphan memcached container if exists (port conflict)
            docker stop "${SITE_PREFIX}-memcached" 2>/dev/null || true
            docker rm "${SITE_PREFIX}-memcached" 2>/dev/null || true
            ;;
    esac
}

select_cache

# Mode selection (single/multi)
select_mode() {
    echo ""
    echo -e "${CYAN}Installation Mode${NC}"
    # Skip prompt if already set (headless mode)
    if [[ -z "$MODE_CHOICE" ]]; then
        echo "  1) Single site (default) - direct nginx, best performance"
        echo "  2) Multi site - Caddy proxy (see multi-site/site-manager.sh)"
        echo -n "Select mode [1-2] (default: 1): "
        read -r MODE_CHOICE
    fi

    case $MODE_CHOICE in
        2)
            echo -e "${YELLOW}Multi-site mode uses Caddy reverse proxy${NC}"
            echo "After setup, use: ./multi-site/site-manager.sh add <domain>"
            sed -i "s/MODE=.*/MODE=single/" .env
            echo -e "${GREEN}Single site mode configured (add more sites via site-manager.sh)${NC}"
            ;;
        *)
            sed -i "s/MODE=.*/MODE=single/" .env
            rm -f docker-compose.override.yml
            echo -e "${GREEN}Single site mode (direct nginx)${NC}"
            ;;
    esac
}

if [ "$MODE" = "single" ]; then
    select_mode
fi

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
        echo "ENABLE_MANTICORE=true" >> .env
        # Add manticore to COMPOSE_PROFILES (supports multiple profiles)
        CURRENT_PROFILES=$(grep "^COMPOSE_PROFILES=" .env | cut -d'=' -f2)
        if [[ "$CURRENT_PROFILES" != *"manticore"* ]]; then
            if [ -n "$CURRENT_PROFILES" ]; then
                sed -i "s/COMPOSE_PROFILES=.*/COMPOSE_PROFILES=${CURRENT_PROFILES},manticore/" .env
            else
                sed -i "s/COMPOSE_PROFILES=.*/COMPOSE_PROFILES=manticore/" .env
            fi
        fi
        echo -e "${GREEN}✓ Manticore Search enabled${NC}"
        echo "  External Search plugin will be auto-configured during installation"
    else
        echo "ENABLE_MANTICORE=false" >> .env
        echo -e "${YELLOW}Manticore Search disabled${NC}"
    fi
}

select_manticore

# Check for existing MariaDB volume
# Based on MariaDB Docker best practices: env vars are IGNORED if data exists
# See: https://mariadb.com/kb/en/docker-official-image-frequently-asked-questions/
check_existing_volume() {
    echo ""
    echo -e "${CYAN}Checking for existing MariaDB data...${NC}"

    # Get the actual volume name from docker compose (most reliable method)
    # This respects COMPOSE_PROJECT_NAME and any compose config
    VOLUME_NAME=$(docker compose config 2>/dev/null | grep -A1 'mariadb-data:' | grep 'name:' | awk '{print $2}')

    # Fallback: compute from docker compose project name
    if [ -z "$VOLUME_NAME" ]; then
        # Docker Compose uses directory name, lowercased, non-alphanumeric removed
        PROJECT_NAME=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
        VOLUME_NAME="${PROJECT_NAME}_mariadb-data"
    fi

    if docker volume ls -q | grep -q "^${VOLUME_NAME}$"; then
        echo -e "${YELLOW}Existing MariaDB volume found: ${VOLUME_NAME}${NC}"
        echo -e "${YELLOW}Note: MariaDB ignores password env vars when data exists${NC}"

        # Check if .env has non-default passwords (meaning we generated them before)
        source .env
        if [ "$MARIADB_ROOT_PASSWORD" != "CHANGE_ME_ROOT_PASSWORD" ] && [ -n "$MARIADB_ROOT_PASSWORD" ]; then  # pragma: allowlist secret
            echo "Saved credentials found in .env"

            # Try to verify connection by starting container briefly
            echo "Verifying database connection..."
            log_command docker compose up -d --force-recreate mariadb

            # Wait for healthcheck (up to 60 seconds)
            for i in {1..12}; do
                if log_command docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1"; then
                    break
                fi
                sleep 5
            done

            if log_command docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1"; then
                echo -e "${GREEN}Connection verified - using existing database${NC}"
                log_command docker compose down
                return 0
            else
                echo -e "${RED}Connection failed - credentials may not match volume${NC}"
                log_command docker compose down
            fi
        fi

        # Volume exists but credentials don't work or don't exist
        echo ""
        echo -e "${RED}WARNING: Cannot connect with saved credentials${NC}"
        echo "The volume contains data created with different credentials."
        echo ""
        echo "Options:"
        echo "  1) Delete volume and start fresh (DATA WILL BE LOST)"
        echo "  2) Exit - manually backup or reset password first"
        echo ""
        echo "To reset password manually:"
        echo "  docker run --rm -v ${VOLUME_NAME}:/var/lib/mysql mariadb:${MARIADB_VERSION:-11.8} \\"
        echo "    --skip-grant-tables --user=mysql &"
        echo "  # Then connect and reset: ALTER USER 'root'@'localhost' IDENTIFIED BY 'newpass';"
        echo ""
        # Skip prompt if already set (headless mode)
        if [[ -z "$VOLUME_CHOICE" ]]; then
            echo -n "Select [1-2]: "
        read -r VOLUME_CHOICE
        fi

        case $VOLUME_CHOICE in
            1)
                echo -e "${YELLOW}Stopping containers and removing volume...${NC}"
                docker compose down 2>/dev/null || true
                docker volume rm "$VOLUME_NAME" 2>/dev/null || true
                echo -e "${GREEN}Volume removed. Will create fresh database.${NC}"
                ;;
            *)
                echo "Exiting. Please backup your data or fix credentials."
                exit 1
                ;;
        esac
    else
        echo "No existing MariaDB volume - will create fresh database."
    fi
}

check_existing_volume

# Generate passwords if still defaults
source .env
if [ "$MARIADB_ROOT_PASSWORD" = "CHANGE_ME_ROOT_PASSWORD" ]; then  # pragma: allowlist secret
    MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
    sed -i "s|MARIADB_ROOT_PASSWORD=CHANGE_ME_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD=$MARIADB_ROOT_PASSWORD|" .env
    echo -e "${GREEN}Generated MariaDB root password${NC}"
fi

if [ "$MARIADB_PASSWORD" = "CHANGE_ME_KVS_PASSWORD" ]; then  # pragma: allowlist secret
    MARIADB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
    sed -i "s|MARIADB_PASSWORD=CHANGE_ME_KVS_PASSWORD|MARIADB_PASSWORD=$MARIADB_PASSWORD|" .env
    echo -e "${GREEN}Generated MariaDB KVS password${NC}"
fi

# Reload .env
source .env

# Open firewall ports if ufw is active
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo -e "${CYAN}Opening firewall ports 80 and 443...${NC}"
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    echo -e "${GREEN}Firewall ports opened${NC}"
fi

# Check if ports are available
echo ""
echo -e "${CYAN}Checking if ports 80 and 443 are available...${NC}"
if ss -tuln | grep -qE ':80\s' || ss -tuln | grep -qE ':443\s'; then
    # Check if it's a KVS docker container (use SITE_PREFIX or detect by service suffix)
    KVS_CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E -- "^${SITE_PREFIX}-|-(php|mariadb|nginx)$" || true)
    if [ -n "$KVS_CONTAINERS" ]; then
        echo -e "${YELLOW}Existing KVS containers detected${NC}"
        docker ps --filter "name=${SITE_PREFIX}-" --format "table {{.Names}}\t{{.Status}}" 2>/dev/null || \
            docker ps --format "table {{.Names}}\t{{.Status}}" 2>/dev/null | grep -E -- "-(php|mariadb|nginx)"
        echo ""
        # Skip prompt if already set (headless mode)
        if [[ -z "$STOP_EXISTING" ]]; then
            echo -n "Stop existing KVS containers? [Y/n]: "
        read -r STOP_EXISTING
        fi
        if [ "$STOP_EXISTING" != "n" ] && [ "$STOP_EXISTING" != "N" ]; then
            echo "Stopping existing containers..."
            docker compose down 2>/dev/null || true
            docker ps -q --filter "name=${SITE_PREFIX}-" 2>/dev/null | xargs -r docker stop 2>/dev/null || true
            echo -e "${GREEN}Existing containers stopped${NC}"
        fi
    else
        echo -e "${RED}WARNING: Ports 80/443 in use by non-KVS process${NC}"
        ss -tuln | grep -E ':(80|443)\s'
    fi
fi

# DNS Check Function
check_dns() {
    echo ""
    echo -e "${CYAN}Checking DNS configuration...${NC}"
    SERVER_IP=$(curl -s --connect-timeout 5 https://api.ipify.org)
    # Use getent instead of dig (more portable)
    DOMAIN_IP=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1)
    WWW_IP=$(getent hosts "www.$DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1)

    dns_ok=true
    echo "Server IP: $SERVER_IP"
    if [ "$DOMAIN_IP" = "$SERVER_IP" ]; then
        echo -e "  $DOMAIN: ${GREEN}OK${NC} -> $DOMAIN_IP"
    else
        echo -e "  $DOMAIN: ${RED}MISMATCH${NC} -> $DOMAIN_IP (expected: $SERVER_IP)"
        dns_ok=false
    fi
    if [ "$WWW_IP" = "$SERVER_IP" ]; then
        echo -e "  www.$DOMAIN: ${GREEN}OK${NC} -> $WWW_IP"
    else
        echo -e "  www.$DOMAIN: ${RED}MISMATCH${NC} -> $WWW_IP (expected: $SERVER_IP)"
        dns_ok=false
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
        echo "  - A record for www.$DOMAIN -> $SERVER_IP"
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

progress_bar "Building Nginx container"
# shellcheck disable=SC2086  # Intentional word splitting for optional --no-cache flag
run_step "Building Nginx container" docker compose build $DOCKER_BUILD_FLAGS nginx

# Create bind mount directory
mkdir -p /var/www/"$DOMAIN"
chown 1000:1000 /var/www/"$DOMAIN"

# Step 2: Start infrastructure services
progress_bar "Starting MariaDB"
run_step "Starting MariaDB" docker compose up -d --force-recreate mariadb

# Wait for MariaDB (max 3 minutes)
echo -n "  Waiting for MariaDB..."
TRIES=0
MAX_TRIES=90
while ! docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" > /dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ $TRIES -ge $MAX_TRIES ]; then
        echo -e " ${RED}✗${NC}"
        echo -e "${RED}ERROR: MariaDB not ready after 3 minutes${NC}"
        echo "Check logs: docker compose logs mariadb"
        exit 1
    fi
    sleep 2
done
echo -e " ${GREEN}✓${NC}"

# Step 3: Initialize phpMyAdmin and KVS
progress_bar "Initializing phpMyAdmin"
run_step "Initializing phpMyAdmin" docker compose --profile setup up --force-recreate phpmyadmin-init

progress_bar "Initializing KVS"
run_step "Initializing KVS" docker compose --profile setup up --force-recreate kvs-init

# Show permission verification result from kvs-init logs
echo -e "  ${CYAN}Permission verification:${NC}"
docker compose logs kvs-init 2>/dev/null | grep -E "(permissions|Permission|CREATED|FIXED|OK)" | tail -5 | sed 's/^/    /'

# Step 4: Configure KVS disk space limit
progress_bar "Configuring disk space limit"
configure_disk_space_limit

# Step 5: Start nginx and get certificate
progress_bar "Starting Nginx"
run_step "Starting Nginx" docker compose up -d --force-recreate nginx

# SSL Certificate based on SSL_PROVIDER
SSL_PROVIDER="${SSL_PROVIDER:-letsencrypt}"

# Dev mode: intelligent SSL detection (reuse existing cert if available)
if [ "${DEV_SSL_INTELLIGENT:-false}" = "true" ]; then
    echo ""
    echo "🔍 Dev mode: Checking for existing SSL certificate..."

    # Check if acme-certs volume exists and contains a valid certificate
    VOLUME_NAME="${COMPOSE_PROJECT_NAME}_acme-certs"

    if docker volume inspect "$VOLUME_NAME" &>/dev/null; then
        # Volume exists - check if certificate files exist for this domain
        if docker run --rm -v "$VOLUME_NAME:/certs:ro" alpine \
           sh -c "test -f /certs/${DOMAIN}/cert.pem && test -f /certs/${DOMAIN}/key.pem" 2>/dev/null; then
            SSL_PROVIDER="letsencrypt"
            echo -e "  ${GREEN}✓${NC} Found existing Let's Encrypt certificate - reusing (0s, no warnings)"
        else
            SSL_PROVIDER="selfsigned"
            echo -e "  ${YELLOW}✓${NC} No existing certificate - using self-signed (fast, but browser warnings)"
        fi
    else
        SSL_PROVIDER="selfsigned"
        echo -e "  ${YELLOW}✓${NC} No acme-certs volume - using self-signed (fast, but browser warnings)"
    fi
    echo ""
fi

if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    echo -e "  ${GREEN}✓${NC} Using self-signed certificate"
else
    run_step "Starting ACME" docker compose up -d --force-recreate acme
    sleep 3
    echo "Issuing SSL certificate for $DOMAIN..."

    # Build acme.sh command
    ACME_ARGS="--issue -d $DOMAIN -d www.$DOMAIN --webroot /var/www/_letsencrypt --keylength ec-256 --accountemail $EMAIL"
    if [ "$SSL_PROVIDER" = "letsencrypt" ]; then
        ACME_ARGS="$ACME_ARGS --server letsencrypt"
    fi

    ACME_OUTPUT=$(docker compose exec acme sh -c "acme.sh $ACME_ARGS" 2>&1) || true

    if echo "$ACME_OUTPUT" | grep -q "Cert success"; then
        # New certificate issued - install it
        docker compose exec acme acme.sh --install-cert \
            -d "$DOMAIN" \
            --ecc \
            --key-file "/etc/nginx/ssl/${DOMAIN}/key.pem" \
            --fullchain-file "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
            --reloadcmd "true"
        echo -e "${GREEN}SSL certificate installed${NC}"
    elif echo "$ACME_OUTPUT" | grep -q "Skipping"; then
        # Certificate still valid - just reinstall to ensure files are in place
        docker compose exec acme acme.sh --install-cert \
            -d "$DOMAIN" \
            --ecc \
            --key-file "/etc/nginx/ssl/${DOMAIN}/key.pem" \
            --fullchain-file "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
            --reloadcmd "true" 2>/dev/null || true
        echo -e "${GREEN}SSL certificate still valid, using existing${NC}"
    else
        echo -e "${RED}SSL certificate issue failed${NC}"
        echo "$ACME_OUTPUT"
        echo "Site will use self-signed certificate until you run:"
        echo "  docker compose exec acme acme.sh --issue -d $DOMAIN -d www.$DOMAIN --webroot /var/www/_letsencrypt --force"
    fi
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
fi

progress_bar "Reloading Nginx"
run_step "Reloading Nginx" docker compose exec nginx nginx -s reload

# Done
progress_success "KVS Docker Setup Complete!"
echo ""
if [ "$USE_WWW" = "true" ]; then
    echo -e "${CYAN}Website:${NC}     https://www.$DOMAIN"
else
    echo -e "${CYAN}Website:${NC}     https://$DOMAIN"
fi
echo -e "${CYAN}phpMyAdmin:${NC}  https://$DOMAIN/phpmyadmin"
echo -e "${CYAN}Database:${NC}    $DOMAIN"
echo -e "${CYAN}DB User:${NC}     $DOMAIN"
echo -e "${CYAN}DB Password:${NC} $MARIADB_PASSWORD"
echo ""
echo -e "${CYAN}Credentials saved in .env file${NC}"
echo ""
if [ -f docker-compose.override.yml ]; then
    echo -e "${CYAN}KVS Files:${NC}   /var/www/$DOMAIN"
    echo -e "${CYAN}kvs-cli:${NC}     kvs-cli --path=/var/www/$DOMAIN"
    echo ""
fi
echo "To view logs: docker compose logs -f"
echo "To stop: docker compose down"
echo "To restart: docker compose up -d"
echo ""
echo -e "${CYAN}Debug logs:${NC}"
echo "  Setup:  $DEBUG_LOG"
echo "  Trace:  $TRACE_LOG"
echo ""
echo -e "${RED}=== SECURITY WARNING ===${NC}"
echo -e "${YELLOW}Default admin credentials:${NC}"
echo "  Login:    admin"
echo "  Password: 123"
echo ""
echo -e "${RED}Change this immediately after first login${NC}"

# Mark end of installation in logs
{
    echo "========================================"
    echo "KVS Docker Setup Completed - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
} >> "$DEBUG_LOG" 2>/dev/null || true
