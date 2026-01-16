#!/bin/bash
# shellcheck disable=SC1091
set -e

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
    SKIP_PRESS_ENTER=1                      # Skip "press enter" prompts
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

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

# Run a command with spinner, showing title and result
run_step() {
    local title="$1"
    shift
    local logfile="/tmp/run_step_$$.log"

    if command -v gum &>/dev/null; then
        # With gum: show spinner, log output to file
        # Note: $@ and $0 must be expanded by sh -c, not the parent shell
        # shellcheck disable=SC2016
        if gum spin --spinner dot --title "$title" -- sh -c '"$@" >"$0" 2>&1' "$logfile" "$@"; then
            echo -e "  ${GREEN}✓${NC} $title"
            rm -f "$logfile"
            return 0
        else
            echo -e "  ${RED}✗${NC} $title"
            [ -s "$logfile" ] && echo "    Error:" && head -10 "$logfile" | sed 's/^/    /'
            rm -f "$logfile"
            return 1
        fi
    else
        # Fallback without gum
        echo -n "  $title..."
        if "$@" >"$logfile" 2>&1; then
            echo -e " ${GREEN}✓${NC}"
            rm -f "$logfile"
            return 0
        else
            echo -e " ${RED}✗${NC}"
            [ -s "$logfile" ] && head -10 "$logfile" | sed 's/^/    /'
            rm -f "$logfile"
            return 1
        fi
    fi
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
        read -rp "Enter your domain (e.g., mysite.com): " DOMAIN
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
        read -rp "Select [1-3] (default: 1): " PREFIX_CHOICE
    fi

    case $PREFIX_CHOICE in
        2)
            SITE_PREFIX="kvs"
            echo -e "${GREEN}Using legacy prefix: kvs${NC}"
            ;;
        3)
            while true; do
                read -rp "Enter custom prefix (e.g., kvs-mysite): " SITE_PREFIX
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
    read -rp "Select SSL provider [1-3] (default: 1): " SSL_CHOICE
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
            read -rp "Enter your email (required for $SSL_PROVIDER): " EMAIL
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
        read -rp "Select MariaDB version [1-${#VERSIONS[@]}] (default: 1): " DB_CHOICE
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

# PHP version selection based on KVS version
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

    # Version comparison
    KVS_MAJOR=$(echo "$KVS_VERSION" | cut -d. -f1)
    KVS_MINOR=$(echo "$KVS_VERSION" | cut -d. -f2)

    if [ "$KVS_MAJOR" -lt 6 ]; then
        echo -e "${RED}KVS $KVS_VERSION requires PHP 7.4-8.0${NC}"
        echo -e "${YELLOW}Warning: PHP 7.x is EOL. Consider upgrading KVS.${NC}"
        sed -i "s/PHP_VERSION=.*/PHP_VERSION=8.0/" .env
        echo "Set PHP version to 8.0"
    elif [ "$KVS_MAJOR" -eq 6 ] && [ "$KVS_MINOR" -lt 2 ]; then
        echo "KVS 6.0-6.1 requires PHP 8.0"
        sed -i "s/PHP_VERSION=.*/PHP_VERSION=8.0/" .env
    else
        # KVS 6.2+ requires PHP 8.1
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
        read -rp "Install IonCube? [1-2] (default: 1): " IONCUBE_CHOICE
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
        read -rp "Press Enter when ready..."
    fi

    if ! ls kvs-archive/KVS_*.zip 1>/dev/null 2>&1; then
        echo -e "${RED}ERROR: Still no KVS archive found. Exiting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}KVS archive found${NC}"

# Now select PHP version based on KVS
select_php_version

# IonCube selection
if [ "$IONCUBE" = "YES" ]; then
    select_ioncube
fi

# Cache selection (dragonfly/memcached)
select_cache() {
    echo ""
    echo -e "${CYAN}Cache Server${NC}"
    # Skip prompt if already set (headless mode)
    if [[ -z "$CACHE_CHOICE" ]]; then
        echo "  1) Dragonfly (faster, modern) (default)"
        echo "  2) Memcached (legacy, same as standalone)"
        read -rp "Select cache [1-2] (default: 1): " CACHE_CHOICE
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
        read -rp "Select mode [1-2] (default: 1): " MODE_CHOICE
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
            docker compose up -d --force-recreate mariadb >/dev/null 2>&1

            # Wait for healthcheck (up to 60 seconds)
            for i in {1..12}; do
                if docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
                    break
                fi
                sleep 5
            done

            if docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
                echo -e "${GREEN}Connection verified - using existing database${NC}"
                docker compose down >/dev/null 2>&1
                return 0
            else
                echo -e "${RED}Connection failed - credentials may not match volume${NC}"
                docker compose down >/dev/null 2>&1
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
            read -rp "Select [1-2]: " VOLUME_CHOICE
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
            read -rp "Stop existing KVS containers? [Y/n]: " STOP_EXISTING
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
            read -rp "Select [1-3]: " DNS_CHOICE
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
if ! run_step "Building PHP-FPM container" docker compose build php-fpm; then
    echo -e "${RED}Docker build failed${NC}"
    echo -e "${YELLOW}If error mentions 'parent snapshot does not exist', run:${NC}"
    echo "  docker builder prune -af"
    echo "Then re-run this script."
    exit 1
fi

progress_bar "Building Cron container"
run_step "Building Cron container" docker compose build cron

progress_bar "Building Nginx container"
run_step "Building Nginx container" docker compose build nginx

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
docker compose pull --quiet 2>/dev/null || true
if docker compose up -d --force-recreate >/dev/null 2>&1; then
    echo -e " ${GREEN}✓${NC}"
else
    echo -e " ${RED}✗${NC}"
    echo "    Check: docker compose logs"
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
echo -e "${RED}=== SECURITY WARNING ===${NC}"
echo -e "${YELLOW}Default admin credentials:${NC}"
echo "  Login:    admin"
echo "  Password: 123"
echo ""
echo -e "${RED}Change this immediately after first login${NC}"
