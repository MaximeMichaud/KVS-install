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

# Prompt for email
if [ "$EMAIL" = "admin@example.com" ]; then
    while true; do
        read -rp "Enter your email (for SSL certificates): " EMAIL
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
    MARIADB_DATA=$(curl -s "https://endoflife.date/api/mariadb.json" 2>/dev/null)

    if [ -z "$MARIADB_DATA" ]; then
        echo -e "${YELLOW}Could not fetch version data. Using defaults.${NC}"
        return
    fi

    echo ""
    echo "Available MariaDB LTS versions:"
    echo ""

    # Parse and display LTS versions with status
    # LTS versions: 11.4, 10.11, 10.6, 10.5 (and 11.8 when released)
    TODAY=$(date +%Y-%m-%d)

    i=1
    declare -a VERSIONS

    # Check each LTS version
    for version in "11.4" "10.11" "10.6"; do
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
    echo "  1) Yes - Install IonCube (default)"
    echo "  2) No - Skip IonCube"
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
if [ "$MARIADB_VERSION" = "11.4" ]; then
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
if ss -tuln | grep -qE ':80\s'; then
    echo -e "${RED}WARNING: Port 80 is already in use${NC}"
    ss -tuln | grep -E ':80\s'
fi
if ss -tuln | grep -qE ':443\s'; then
    echo -e "${RED}WARNING: Port 443 is already in use${NC}"
    ss -tuln | grep -E ':443\s'
fi

# DNS Check Function
check_dns() {
    echo ""
    echo -e "${CYAN}Checking DNS configuration...${NC}"
    SERVER_IP=$(curl -s https://api.ipify.org)
    DOMAIN_IP=$(dig +short "$DOMAIN" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    WWW_IP=$(dig +short "www.$DOMAIN" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)

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
docker compose build

# Step 2: Start infrastructure services
echo ""
echo -e "${CYAN}Starting infrastructure services...${NC}"
docker compose up -d mariadb

# Wait for MariaDB
echo "Waiting for MariaDB to be ready..."
until docker compose exec -T mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "SELECT 1" > /dev/null 2>&1; do
    sleep 2
done
echo -e "${GREEN}MariaDB is ready${NC}"

# Step 3: Initialize phpMyAdmin and KVS
echo ""
echo -e "${CYAN}Initializing phpMyAdmin and KVS...${NC}"
docker compose --profile setup up phpmyadmin-init kvs-init

# Step 4: Start nginx and get certificate
echo ""
docker compose up -d nginx acme

# Wait a moment for nginx to start
sleep 5

# SSL Certificate based on SSL_PROVIDER
SSL_PROVIDER="${SSL_PROVIDER:-letsencrypt}"
echo -e "${CYAN}SSL Provider: ${SSL_PROVIDER}${NC}"

if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    echo -e "${GREEN}Using self-signed certificate (already generated)${NC}"
else
    echo "Issuing SSL certificate for $DOMAIN..."

    # Build command based on provider
    ACME_CMD="acme.sh --issue -d $DOMAIN -d www.$DOMAIN --webroot /var/www/_letsencrypt --keylength ec-256 --accountemail $EMAIL"
    if [ "$SSL_PROVIDER" = "letsencrypt" ]; then
        ACME_CMD="$ACME_CMD --server letsencrypt"
    fi

    if docker compose exec acme sh -c "$ACME_CMD"; then
        # Install certificate only if issue succeeded
        docker compose exec acme acme.sh --install-cert \
            -d "$DOMAIN" \
            --ecc \
            --key-file "/etc/nginx/ssl/${DOMAIN}/key.pem" \
            --fullchain-file "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
            --reloadcmd "true"

        echo -e "${GREEN}SSL certificate installed${NC}"
    else
        echo -e "${RED}SSL certificate issue failed${NC}"
        echo "Site will use self-signed certificate until you run:"
        echo "  docker compose exec acme sh -c '$ACME_CMD --force'"
    fi
fi

# Step 5: Start all services
echo ""
echo -e "${CYAN}Starting all services...${NC}"
docker compose up -d

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
