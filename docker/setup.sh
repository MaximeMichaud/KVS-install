#!/bin/bash
# shellcheck disable=SC1091
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== KVS Docker Setup ===${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Please run as root${NC}"
    exit 1
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

# SSL provider selection FIRST (before email)
echo ""
echo -e "${CYAN}SSL Certificate Provider${NC}"
echo "  1) Let's Encrypt (recommended, default)"
echo "  2) ZeroSSL"
echo "  3) Self-signed (dev/testing or behind reverse proxy)"
read -rp "Select SSL provider [1-3] (default: 1): " SSL_CHOICE

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
        ;;
    *)
        SSL_PROVIDER="letsencrypt"
        sed -i "s/SSL_PROVIDER=.*/SSL_PROVIDER=letsencrypt/" .env
        echo -e "${GREEN}Selected Let's Encrypt${NC}"
        ;;
esac

# Prompt for email only if using letsencrypt or zerossl
if [ "$SSL_PROVIDER" != "selfsigned" ] && [ "$EMAIL" = "admin@example.com" ]; then
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

    echo ""
    read -rp "Select MariaDB version [1-${#VERSIONS[@]}] (default: 1): " DB_CHOICE

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
    elif [ "$KVS_MAJOR" -eq 6 ] && [ "$KVS_MINOR" -lt 4 ]; then
        echo "KVS 6.2-6.3 requires PHP 8.1"
        sed -i "s/PHP_VERSION=.*/PHP_VERSION=8.1/" .env
    else
        # KVS 6.4+ supports PHP 8.1 and 8.3
        echo ""
        echo "KVS $KVS_VERSION supports PHP 8.1 and 8.3"
        echo "  1) PHP 8.1 (Stable, recommended)"
        echo "  2) PHP 8.3 (Latest)"
        read -rp "Select PHP version [1-2] (default: 1): " PHP_CHOICE

        case $PHP_CHOICE in
            2)
                sed -i "s/PHP_VERSION=.*/PHP_VERSION=8.3/" .env
                echo -e "${GREEN}Selected PHP 8.3${NC}"
                ;;
            *)
                sed -i "s/PHP_VERSION=.*/PHP_VERSION=8.1/" .env
                echo -e "${GREEN}Selected PHP 8.1${NC}"
                ;;
        esac
    fi
}

# IonCube selection
select_ioncube() {
    echo ""
    echo -e "${CYAN}IonCube Loader${NC}"
    echo "KVS requires IonCube for encoded files."
    echo "  1) Yes - Install IonCube (required for KVS) (default)"
    echo "  2) No - Skip (only if you have unencoded KVS)"
    read -rp "Install IonCube? [1-2] (default: 1): " IONCUBE_CHOICE

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
    read -rp "Press Enter when ready..."

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
    echo "  1) Dragonfly (faster, modern) (default)"
    echo "  2) Memcached (legacy, same as standalone)"
    read -rp "Select cache [1-2] (default: 1): " CACHE_CHOICE

    case $CACHE_CHOICE in
        2)
            sed -i "s/COMPOSE_PROFILES=.*/COMPOSE_PROFILES=memcached/" .env
            echo -e "${GREEN}Selected Memcached${NC}"
            ;;
        *)
            sed -i "s/COMPOSE_PROFILES=.*/COMPOSE_PROFILES=dragonfly/" .env
            echo -e "${GREEN}Selected Dragonfly${NC}"
            ;;
    esac
}

select_cache

# Mode selection (single/multi)
select_mode() {
    echo ""
    echo -e "${CYAN}Installation Mode${NC}"
    echo "  1) Single site (default) - direct nginx, best performance"
    echo "  2) Multi site - Traefik proxy, run multiple KVS on same server"
    read -rp "Select mode [1-2] (default: 1): " MODE_CHOICE

    case $MODE_CHOICE in
        2)
            sed -i "s/MODE=.*/MODE=multi/" .env
            # Add multi to COMPOSE_PROFILES
            CURRENT_PROFILES=$(grep "^COMPOSE_PROFILES=" .env | cut -d= -f2)
            sed -i "s/COMPOSE_PROFILES=.*/COMPOSE_PROFILES=${CURRENT_PROFILES},multi/" .env
            # Create override to remove nginx ports
            cat > docker-compose.override.yml << 'OVERRIDE'
services:
  nginx:
    ports: []
OVERRIDE
            echo -e "${GREEN}Multi-site mode enabled with Traefik${NC}"
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

    # Check if volume exists
    # Volume name = <directory>_mariadb-data (Docker Compose default)
    PROJECT_NAME=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    VOLUME_NAME="${PROJECT_NAME}_mariadb-data"
    if docker volume ls -q | grep -q "^${VOLUME_NAME}$"; then
        echo -e "${YELLOW}Existing MariaDB volume found: ${VOLUME_NAME}${NC}"
        echo -e "${YELLOW}Note: MariaDB ignores password env vars when data exists${NC}"

        # Check if .env has non-default passwords (meaning we generated them before)
        source .env
        if [ "$MARIADB_ROOT_PASSWORD" != "CHANGE_ME_ROOT_PASSWORD" ] && [ -n "$MARIADB_ROOT_PASSWORD" ]; then
            echo "Saved credentials found in .env"

            # Try to verify connection by starting container briefly
            echo "Verifying database connection..."
            docker compose up -d --force-recreate mariadb >/dev/null 2>&1
            sleep 5

            if docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
                echo -e "${GREEN}Connection verified - using existing database${NC}"
                docker compose down >/dev/null 2>&1
                return 0
            else
                echo -e "${RED}Connection failed - password mismatch${NC}"
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
        read -rp "Select [1-2]: " VOLUME_CHOICE

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
if [ "$MARIADB_ROOT_PASSWORD" = "CHANGE_ME_ROOT_PASSWORD" ]; then
    MARIADB_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
    sed -i "s|MARIADB_ROOT_PASSWORD=CHANGE_ME_ROOT_PASSWORD|MARIADB_ROOT_PASSWORD=$MARIADB_ROOT_PASSWORD|" .env
    echo -e "${GREEN}Generated MariaDB root password${NC}"
fi

if [ "$MARIADB_PASSWORD" = "CHANGE_ME_KVS_PASSWORD" ]; then
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
    # Check if it's a KVS docker container
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "kvs-"; then
        echo -e "${YELLOW}Existing KVS containers detected${NC}"
        docker ps --filter "name=kvs-" --format "table {{.Names}}\t{{.Status}}"
        echo ""
        read -rp "Stop existing KVS containers? [Y/n]: " STOP_EXISTING
        if [ "$STOP_EXISTING" != "n" ] && [ "$STOP_EXISTING" != "N" ]; then
            echo "Stopping existing containers..."
            docker compose down 2>/dev/null || true
            docker ps -q --filter "name=kvs-" | xargs -r docker stop 2>/dev/null || true
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
        read -rp "Select [1-3]: " DNS_CHOICE
        case $DNS_CHOICE in
            1) continue ;;
            2) echo "Continuing without valid DNS..."; break ;;
            3) exit 1 ;;
            *) continue ;;
        esac
    fi
done

# Generate dhparam if not exists
if [ ! -f nginx/dhparam.pem ]; then
    echo "Generating DH parameters (this may take a while)..."
    openssl dhparam -out nginx/dhparam.pem 2048
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
echo ""
echo -e "${CYAN}Building Docker images...${NC}"
if ! docker compose build; then
    echo -e "${RED}Docker build failed${NC}"
    echo -e "${YELLOW}If error mentions 'parent snapshot does not exist', run:${NC}"
    echo "  docker builder prune -af"
    echo "Then re-run this script."
    exit 1
fi

# Create bind mount directory
mkdir -p /var/www/"$DOMAIN"
chown 1000:1000 /var/www/"$DOMAIN"

# Step 2: Start infrastructure services
echo ""
echo -e "${CYAN}Starting infrastructure services...${NC}"
docker compose up -d --force-recreate mariadb

# Wait for MariaDB (max 3 minutes)
echo "Waiting for MariaDB to be ready..."
TRIES=0
MAX_TRIES=90
until docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" > /dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ $TRIES -ge $MAX_TRIES ]; then
        echo -e "${RED}ERROR: MariaDB not ready after 3 minutes${NC}"
        echo "Check logs: docker compose logs mariadb"
        exit 1
    fi
    sleep 2
done
echo -e "${GREEN}MariaDB is ready${NC}"

# Step 3: Initialize phpMyAdmin and KVS
echo ""
echo -e "${CYAN}Initializing phpMyAdmin and KVS...${NC}"
docker compose --profile setup up --force-recreate phpmyadmin-init kvs-init

# Step 4: Start nginx and get certificate
echo ""
docker compose up -d --force-recreate nginx acme

# Wait a moment for nginx to start
sleep 5

# SSL Certificate based on SSL_PROVIDER
SSL_PROVIDER="${SSL_PROVIDER:-letsencrypt}"
echo -e "${CYAN}SSL Provider: ${SSL_PROVIDER}${NC}"

if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    echo -e "${GREEN}Using self-signed certificate (already generated)${NC}"
else
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

# Step 5: Start all services
echo ""
echo -e "${CYAN}Starting all services...${NC}"
docker compose up -d --force-recreate

# Reload nginx to pick up SSL
docker compose exec nginx nginx -s reload || true

# Done
echo ""
echo -e "${GREEN}=== Setup Complete ===${NC}"
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
