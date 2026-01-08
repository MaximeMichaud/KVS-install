#!/bin/bash
# KVS Docker Reconfiguration Script
# Applies .env changes without full reinstall

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Must run from docker directory
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}ERROR: Run from docker directory${NC}"
    exit 1
fi

# Must have .env
if [ ! -f ".env" ]; then
    echo -e "${RED}ERROR: .env not found${NC}"
    exit 1
fi

# Load environment
# shellcheck source=/dev/null
source .env

# Validate required vars
if [ -z "$DOMAIN" ]; then
    echo -e "${RED}ERROR: DOMAIN not set in .env${NC}"
    exit 1
fi

if [ -z "$MARIADB_PASSWORD" ]; then
    echo -e "${RED}ERROR: MARIADB_PASSWORD not set in .env${NC}"
    exit 1
fi

echo -e "${CYAN}=== KVS Reconfiguration ===${NC}"
echo "Domain: $DOMAIN"
echo "SSL Provider: ${SSL_PROVIDER:-letsencrypt}"
echo ""

# Get container prefix
CONTAINER_PREFIX="${SITE_PREFIX:-kvs}"
PHP_CONTAINER="${CONTAINER_PREFIX}-php"
NGINX_CONTAINER="${CONTAINER_PREFIX}-nginx"
ACME_CONTAINER="${CONTAINER_PREFIX}-acme"

# Check containers are running
if ! docker ps --format '{{.Names}}' | grep -q "^${PHP_CONTAINER}$"; then
    echo -e "${RED}ERROR: ${PHP_CONTAINER} not running${NC}"
    exit 1
fi

# Function to run mariadb query
run_query() {
    docker exec "$PHP_CONTAINER" mariadb -h mariadb -u "$DOMAIN" -p"$MARIADB_PASSWORD" "$DOMAIN" -e "$1"
}

# 1. Update SSL verification based on SSL_PROVIDER
echo -e "${CYAN}Configuring SSL settings...${NC}"
SSL_PROVIDER="${SSL_PROVIDER:-letsencrypt}"

if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    run_query "UPDATE ktvs_admin_servers SET streaming_skip_ssl_check = 1;"
    echo -e "${GREEN}SSL verification disabled (self-signed)${NC}"

    # Generate self-signed cert if needed
    if ! docker exec "$NGINX_CONTAINER" test -f "/etc/nginx/ssl/${DOMAIN}/cert.pem" 2>/dev/null; then
        echo "Generating self-signed certificate..."
        docker exec "$NGINX_CONTAINER" mkdir -p "/etc/nginx/ssl/${DOMAIN}"
        docker exec "$NGINX_CONTAINER" openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "/etc/nginx/ssl/${DOMAIN}/key.pem" \
            -out "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
            -subj "/CN=${DOMAIN}" 2>/dev/null
        echo -e "${GREEN}Self-signed certificate generated${NC}"
    fi
else
    run_query "UPDATE ktvs_admin_servers SET streaming_skip_ssl_check = 0;"
    echo -e "${GREEN}SSL verification enabled${NC}"

    # Try to get Let's Encrypt/ZeroSSL cert
    if docker ps --format '{{.Names}}' | grep -q "^${ACME_CONTAINER}$"; then
        echo "Checking SSL certificate..."

        # Check if cert exists and is valid
        if docker exec "$ACME_CONTAINER" acme.sh --list | grep -q "$DOMAIN"; then
            echo -e "${GREEN}Certificate already exists${NC}"
        else
            echo "Requesting certificate from ${SSL_PROVIDER}..."
            ACME_CMD="acme.sh --issue -d $DOMAIN -d www.$DOMAIN --webroot /var/www/_letsencrypt --keylength ec-256"
            if [ "$SSL_PROVIDER" = "letsencrypt" ]; then
                ACME_CMD="$ACME_CMD --server letsencrypt"
            fi
            if docker exec "$ACME_CONTAINER" sh -c "$ACME_CMD" 2>&1 | grep -q "Cert success\|Skipping"; then
                docker exec "$ACME_CONTAINER" acme.sh --install-cert \
                    -d "$DOMAIN" \
                    --ecc \
                    --key-file "/etc/nginx/ssl/${DOMAIN}/key.pem" \
                    --fullchain-file "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
                    --reloadcmd "true"
                echo -e "${GREEN}Certificate installed${NC}"
            else
                echo -e "${YELLOW}Certificate request failed - using existing cert${NC}"
            fi
        fi
    fi
fi

# 2. Update server URLs based on USE_WWW
echo -e "${CYAN}Configuring server URLs...${NC}"
if [ "$USE_WWW" = "true" ]; then
    SERVER_URL="https://www.${DOMAIN}"
else
    SERVER_URL="https://${DOMAIN}"
fi

# Update URLs in database
run_query "UPDATE ktvs_admin_servers SET urls = REPLACE(urls, 'https://www.${DOMAIN}', '${SERVER_URL}') WHERE urls LIKE '%/contents/%';"
run_query "UPDATE ktvs_admin_servers SET urls = REPLACE(urls, 'https://${DOMAIN}', '${SERVER_URL}') WHERE urls LIKE '%/contents/%';"
echo -e "${GREEN}Server URLs set to: ${SERVER_URL}/contents/...${NC}"

# 3. Reload nginx
echo -e "${CYAN}Reloading nginx...${NC}"
if docker exec "$NGINX_CONTAINER" nginx -t 2>/dev/null; then
    docker exec "$NGINX_CONTAINER" nginx -s reload 2>/dev/null
    echo -e "${GREEN}Nginx reloaded${NC}"
else
    echo -e "${RED}Nginx config test failed${NC}"
    exit 1
fi

# Summary
echo ""
echo -e "${GREEN}=== Reconfiguration Complete ===${NC}"
echo ""
echo "Current settings:"
run_query "SELECT server_id, urls, streaming_skip_ssl_check FROM ktvs_admin_servers;" 2>/dev/null
