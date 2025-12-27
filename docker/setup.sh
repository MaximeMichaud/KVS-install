#!/bin/bash
# shellcheck disable=SC1091
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== KVS Docker Setup ===${NC}"
echo ""

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

# Prompt for configuration if not set
if [ "$DOMAIN" = "example.com" ]; then
    read -rp "Enter your domain (e.g., mysite.com): " DOMAIN
    sed -i "s/DOMAIN=example.com/DOMAIN=$DOMAIN/" .env
fi

if [ "$EMAIL" = "admin@example.com" ]; then
    read -rp "Enter your email (for SSL certificates): " EMAIL
    sed -i "s/EMAIL=admin@example.com/EMAIL=$EMAIL/" .env
fi

if [ "$MARIADB_ROOT_PASSWORD" = "CHANGE_ME_ROOT_PASSWORD" ]; then
    # Generate password without special chars that break sed
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

# Check for KVS archive
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

# Generate dhparam if not exists
if [ ! -f nginx/dhparam.pem ]; then
    echo "Generating DH parameters (this may take a while)..."
    openssl dhparam -out nginx/dhparam.pem 2048
fi

# Create bind mount directory if override file exists
if [ -f docker-compose.override.yml ]; then
    echo ""
    echo -e "${CYAN}Bind mount enabled - creating /var/www/${DOMAIN}...${NC}"
    sudo mkdir -p "/var/www/${DOMAIN}"
    sudo chown -R 1000:1000 "/var/www/${DOMAIN}"
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

# Step 4: Start acme.sh and get certificate
echo ""
echo -e "${CYAN}Starting ACME for SSL certificates...${NC}"
docker compose up -d nginx acme

# Wait a moment for nginx to start
sleep 5

# Issue SSL certificate
echo "Issuing SSL certificate for $DOMAIN..."
docker compose exec acme --issue \
    -d "$DOMAIN" \
    -d "www.$DOMAIN" \
    -w /var/www/_letsencrypt \
    --keylength ec-256 \
    --accountemail "$EMAIL" || true

# Install certificate
docker compose exec acme --install-cert \
    -d "$DOMAIN" \
    --ecc \
    --key-file "/etc/nginx/ssl/${DOMAIN}/key.pem" \
    --fullchain-file "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
    --reloadcmd "true" || {
    echo -e "${RED}SSL certificate installation failed${NC}"
    echo "You may need to configure DNS first and run this script again"
}

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
