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

certificate_pair_is_valid() {
    certificate_not_before=''
    certificate_not_before_epoch=''
    certificate_now_epoch=''
    certificate_san_entries=''
    certificate_actual_dns_names=''
    certificate_expected_dns_names=''

    [ -s "${SSL_DIR}/cert.pem" ] || return 1
    [ -s "${SSL_DIR}/key.pem" ] || return 1
    certificate_san_entries=$(
        openssl x509 -in "${SSL_DIR}/cert.pem" -noout -ext subjectAltName \
            2>/dev/null |
            sed "1d; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d" |
            tr ',' '\n' |
            sed "s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d"
    ) || return 1
    [ -n "$certificate_san_entries" ] || return 1
    if printf '%s\n' "$certificate_san_entries" | grep -Ev "^DNS:" >/dev/null; then
        return 1
    fi
    certificate_actual_dns_names=$(
        printf '%s\n' "$certificate_san_entries" |
            sed -n "s/^DNS://p" | LC_ALL=C sort
    ) || return 1
    certificate_expected_dns_names=$(
        printf '%s\n' "$DOMAIN"
        if [ "$INCLUDE_WWW" = "true" ]; then
            printf '%s\n' "www.${DOMAIN}"
        fi
    )
    certificate_expected_dns_names=$(
        printf '%s\n' "$certificate_expected_dns_names" | LC_ALL=C sort
    ) || return 1
    [ "$certificate_actual_dns_names" = "$certificate_expected_dns_names" ] || return 1

    certificate_not_before=$(
        LC_ALL=C openssl x509 -in "${SSL_DIR}/cert.pem" -noout -startdate 2>/dev/null
    ) || return 1
    case "$certificate_not_before" in
        notBefore=*) certificate_not_before=${certificate_not_before#notBefore=} ;;
        *) return 1 ;;
    esac
    certificate_not_before_epoch=$(
        LC_ALL=C date -u -d "$certificate_not_before" +%s 2>/dev/null
    ) || return 1
    certificate_now_epoch=$(date -u +%s) || return 1
    [ "$certificate_not_before_epoch" -le "$certificate_now_epoch" ] || return 1

    openssl x509 -in "${SSL_DIR}/cert.pem" -noout -checkend 0 \
        >/dev/null 2>&1 || return 1
    openssl x509 -in "${SSL_DIR}/cert.pem" -noout -checkhost "$DOMAIN" \
        >/dev/null 2>&1 || return 1
    if [ "$INCLUDE_WWW" = "true" ]; then
        openssl x509 -in "${SSL_DIR}/cert.pem" -noout -checkhost "www.${DOMAIN}" \
            >/dev/null 2>&1 || return 1
    fi

    certificate_public_key=$(
        openssl x509 -in "${SSL_DIR}/cert.pem" -pubkey -noout 2>/dev/null
    ) || return 1
    private_public_key=$(
        openssl pkey -in "${SSL_DIR}/key.pem" -pubout -passin pass: 2>/dev/null
    ) || return 1

    [ "$certificate_public_key" = "$private_public_key" ]
}

# Generate self-signed cert if not exists (fallback until ACME runs)
# Skip if SSL_PROVIDER=none (behind reverse proxy like Caddy)
if [ "$SSL_PROVIDER" != "none" ]; then
    SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
    if ! certificate_pair_is_valid; then
        echo "SSL certificate pair is missing, invalid, or mismatched; generating a self-signed certificate..."
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

monitor_certificate_changes() (
    certificate_monitor_cert_file="/etc/nginx/ssl/${DOMAIN}/cert.pem"
    certificate_monitor_key_file="/etc/nginx/ssl/${DOMAIN}/key.pem"
    certificate_monitor_interval="${CERTIFICATE_RELOAD_INTERVAL:-300}"

    case "$certificate_monitor_interval" in
        ''|*[!0-9]*) certificate_monitor_interval=300 ;;
    esac
    if [ "$certificate_monitor_interval" -lt 1 ]; then
        certificate_monitor_interval=300
    fi
    certificate_monitor_previous_hash=$(
        sha256sum "$certificate_monitor_cert_file" "$certificate_monitor_key_file" \
            2>/dev/null || true
    )
    while sleep "$certificate_monitor_interval"; do
        certificate_monitor_current_hash=$(
            sha256sum "$certificate_monitor_cert_file" "$certificate_monitor_key_file" \
                2>/dev/null || true
        )
        [ -n "$certificate_monitor_current_hash" ] || continue
        [ "$certificate_monitor_current_hash" != "$certificate_monitor_previous_hash" ] || continue
        if nginx -t >/dev/null 2>&1 && nginx -s reload; then
            certificate_monitor_previous_hash="$certificate_monitor_current_hash"
            echo "Reloaded Nginx after a certificate change"
        fi
    done
)

# Generate site config from template (before official entrypoint runs)
if [ -f /etc/nginx/templates/kvs.conf.tpl ]; then
    # shellcheck disable=SC2016
    envsubst '${DOMAIN} ${MAIN_SERVER_NAME} ${PUBLIC_SERVER_NAMES} ${REDIRECT_HOST} ${PROJECT_HTTPS_PORT} ${HTTPS_PORT_SUFFIX} ${WWW_REDIRECT_BLOCK} ${KVS_ROOT} ${PHP_FPM_UPSTREAM} ${RESOLVER_LINE}' \
        < /etc/nginx/templates/kvs.conf.tpl \
        > /etc/nginx/conf.d/kvs.conf
    echo "Generated kvs.conf for domain: ${DOMAIN} (USE_WWW=${USE_WWW})"
fi

if [ "$SSL_PROVIDER" != "none" ]; then
    monitor_certificate_changes &
fi

# Execute the original nginx entrypoint
exec /docker-entrypoint.sh "$@"
