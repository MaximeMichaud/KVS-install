#!/bin/sh
set -e

DOMAIN="${DOMAIN:-example.com}"
USE_WWW="${USE_WWW:-false}"
SSL_PROVIDER="${SSL_PROVIDER:-selfsigned}"
PROJECT_HTTPS_PORT="${PROJECT_HTTPS_PORT:-443}"

case "$PROJECT_HTTPS_PORT" in
    ''|*[!0-9]*)
        echo "ERROR: PROJECT_HTTPS_PORT must be a numeric TCP port" >&2
        exit 1
        ;;
esac
if [ "$PROJECT_HTTPS_PORT" -lt 1 ] || [ "$PROJECT_HTTPS_PORT" -gt 65535 ]; then
    echo "ERROR: PROJECT_HTTPS_PORT must be between 1 and 65535" >&2
    exit 1
fi
HTTPS_PORT_SUFFIX=""
if [ "$PROJECT_HTTPS_PORT" -ne 443 ]; then
    HTTPS_PORT_SUFFIX=":${PROJECT_HTTPS_PORT}"
fi

DOMAIN_DOT_COUNT=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
INCLUDE_WWW=false
if [ "$USE_WWW" = "true" ] || [ "$DOMAIN_DOT_COUNT" -eq 1 ]; then
    INCLUDE_WWW=true
fi
PUBLIC_SERVER_NAMES="$DOMAIN"
CERTIFICATE_SAN="DNS:${DOMAIN}"
if [ "$INCLUDE_WWW" = "true" ]; then
    PUBLIC_SERVER_NAMES="${DOMAIN} www.${DOMAIN}"
    CERTIFICATE_SAN="${CERTIFICATE_SAN},DNS:www.${DOMAIN}"
fi

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
            -addext "subjectAltName=${CERTIFICATE_SAN}" \
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
    return 301 https://www.${DOMAIN}${HTTPS_PORT_SUFFIX}\$request_uri;
}"
elif [ "$INCLUDE_WWW" = "true" ]; then
    MAIN_SERVER_NAME="${DOMAIN}"
    REDIRECT_HOST="${DOMAIN}"
    WWW_REDIRECT_BLOCK="server {
    listen 443 ssl;
    http2 on;
    server_name www.${DOMAIN};
    ssl_certificate /etc/nginx/ssl/${DOMAIN}/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/key.pem;
    return 301 https://${DOMAIN}${HTTPS_PORT_SUFFIX}\$request_uri;
}"
else
    MAIN_SERVER_NAME="${DOMAIN}"
    REDIRECT_HOST="${DOMAIN}"
    WWW_REDIRECT_BLOCK=""
fi

export DOMAIN MAIN_SERVER_NAME PUBLIC_SERVER_NAMES REDIRECT_HOST \
    PROJECT_HTTPS_PORT HTTPS_PORT_SUFFIX WWW_REDIRECT_BLOCK

# Generate site config from template (before official entrypoint runs)
if [ -f /etc/nginx/templates/kvs.conf.tpl ]; then
    # shellcheck disable=SC2016
    envsubst '${DOMAIN} ${MAIN_SERVER_NAME} ${PUBLIC_SERVER_NAMES} ${REDIRECT_HOST} ${PROJECT_HTTPS_PORT} ${HTTPS_PORT_SUFFIX} ${WWW_REDIRECT_BLOCK} ${KVS_ROOT} ${PHP_FPM_UPSTREAM} ${RESOLVER_LINE}' \
        < /etc/nginx/templates/kvs.conf.tpl \
        > /etc/nginx/conf.d/kvs.conf
    echo "Generated kvs.conf for domain: ${DOMAIN} (USE_WWW=${USE_WWW})"
fi

# Execute the original nginx entrypoint
exec /docker-entrypoint.sh "$@"
