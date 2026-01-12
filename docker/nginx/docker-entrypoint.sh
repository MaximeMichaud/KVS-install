#!/bin/sh
set -e

DOMAIN="${DOMAIN:-example.com}"
USE_WWW="${USE_WWW:-false}"
SSL_PROVIDER="${SSL_PROVIDER:-selfsigned}"

# Generate self-signed cert if not exists (fallback until ACME runs)
# Skip if SSL_PROVIDER=none (behind reverse proxy like Caddy)
if [ "$SSL_PROVIDER" != "none" ]; then
    SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
    if [ ! -f "${SSL_DIR}/cert.pem" ]; then
        echo "SSL certificate not found, generating self-signed certificate..."
        mkdir -p "${SSL_DIR}"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "${SSL_DIR}/key.pem" \
            -out "${SSL_DIR}/cert.pem" \
            -subj "/CN=${DOMAIN}" \
            -addext "subjectAltName=DNS:${DOMAIN},DNS:www.${DOMAIN}" \
            2>/dev/null
        echo "Self-signed certificate generated for ${DOMAIN}"
    fi
else
    echo "SSL_PROVIDER=none: Skipping SSL certificate generation (behind reverse proxy)"
fi

# Remove default nginx config (conflicts with our server blocks)
rm -f /etc/nginx/conf.d/default.conf

# Docker-specific settings
export KVS_ROOT="/var/www/kvs"
export PHP_FPM_UPSTREAM="php-fpm:9000"
export RESOLVER_LINE="resolver 127.0.0.11 valid=30s;"

# Determine server names based on USE_WWW
if [ "$USE_WWW" = "true" ]; then
    MAIN_SERVER_NAME="www.${DOMAIN}"
    REDIRECT_HOST="www.${DOMAIN}"
    WWW_REDIRECT_BLOCK="server {
    listen 443 ssl;
    http2 on;
    server_name ${DOMAIN};
    ssl_certificate /etc/nginx/ssl/${DOMAIN}/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/key.pem;
    return 301 https://www.${DOMAIN}\$request_uri;
}"
else
    MAIN_SERVER_NAME="${DOMAIN}"
    REDIRECT_HOST="${DOMAIN}"
    WWW_REDIRECT_BLOCK="server {
    listen 443 ssl;
    http2 on;
    server_name www.${DOMAIN};
    ssl_certificate /etc/nginx/ssl/${DOMAIN}/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/key.pem;
    return 301 https://${DOMAIN}\$request_uri;
}"
fi

export DOMAIN MAIN_SERVER_NAME REDIRECT_HOST WWW_REDIRECT_BLOCK

# Generate site config from template (before official entrypoint runs)
if [ -f /etc/nginx/templates/kvs.conf.template ]; then
    # shellcheck disable=SC2016
    envsubst '${DOMAIN} ${MAIN_SERVER_NAME} ${REDIRECT_HOST} ${WWW_REDIRECT_BLOCK} ${KVS_ROOT} ${PHP_FPM_UPSTREAM} ${RESOLVER_LINE}' \
        < /etc/nginx/templates/kvs.conf.template \
        > /etc/nginx/conf.d/kvs.conf
    echo "Generated kvs.conf for domain: ${DOMAIN} (USE_WWW=${USE_WWW})"
fi

# Execute the original nginx entrypoint
exec /docker-entrypoint.sh "$@"
