#!/bin/bash
set -euo pipefail

# The KVS rewrites file (_INSTALL/nginx_config.txt, "SYSTEM / DO NOT CHANGE")
# maps /embed/<id>/ to /player/iframe_embed.php: the player that other sites
# put in an iframe. A server-wide "X-Frame-Options: SAMEORIGIN" reaches that
# response through add_header inheritance and every browser then refuses to
# render the embed, so the site templates must drop the header for it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT_DIR}/docker/nginx/docker-entrypoint.sh"
TEST_DIR=$(mktemp -d)
REAL_OPENSSL=$(type -P openssl || true)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -n "$REAL_OPENSSL" ] || fail "OpenSSL is required"

# shellcheck disable=SC2016
MAP_RULE='map $uri $kvs_frame_options {'
# shellcheck disable=SC2016
HEADER_RULE='add_header X-Frame-Options $kvs_frame_options always;'
EMBED_RULE='~^/player/iframe_embed\.php$ "";'

assert_embed_player_not_frame_restricted() {
    local file="$1"

    if grep -Fq 'add_header X-Frame-Options "SAMEORIGIN" always;' "$file"; then
        fail "a fixed X-Frame-Options header also covers the embed player in ${file}"
    fi
    grep -Fq "$MAP_RULE" "$file" ||
        fail "no frame options map in ${file}"
    grep -Fq "$EMBED_RULE" "$file" ||
        fail "the frame options map does not exempt the embed player in ${file}"
    grep -Fq 'default                      "SAMEORIGIN";' "$file" ||
        fail "the frame options map does not keep SAMEORIGIN for the site in ${file}"
    grep -Fq "$HEADER_RULE" "$file" ||
        fail "X-Frame-Options is not sent from the map in ${file}"
    # The map must sit in the http context, before the first server block.
    [ "$(grep -nF "$MAP_RULE" "$file" | head -n 1 | cut -d: -f1)" -lt \
        "$(grep -n '^server {' "$file" | head -n 1 | cut -d: -f1)" ] ||
        fail "the frame options map is not declared before the server blocks in ${file}"
}

# The generated config must keep the nginx variables of the map untouched.
run_rendered_template_case() {
    local domain='example.com'
    local case_dir="${TEST_DIR}/rendered"
    local ssl_dir="${case_dir}/etc/nginx/ssl/${domain}"
    local generated_config="${case_dir}/etc/nginx/conf.d/kvs.conf"

    mkdir -p "$ssl_dir" "${case_dir}/etc/nginx/templates" \
        "${case_dir}/etc/nginx/conf.d"
    "$REAL_OPENSSL" req -x509 -nodes -days 1 -newkey rsa:1024 \
        -keyout "${ssl_dir}/key.pem" \
        -out "${ssl_dir}/cert.pem" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain},DNS:www.${domain}" \
        >/dev/null 2>&1
    cp "${ROOT_DIR}/conf/nginx/templates/kvs.conf.tpl" \
        "${case_dir}/etc/nginx/templates/kvs.conf.tpl"
    sed \
        -e "s|/etc/nginx|${case_dir}/etc/nginx|g" \
        -e 's|exec /docker-entrypoint.sh "$@"|exec "$@"|' \
        -e '/^[[:space:]]*monitor_certificate_changes &$/c\    : # Not needed here.' \
        "$ENTRYPOINT" > "${case_dir}/docker-entrypoint.sh"

    DOMAIN="$domain" USE_WWW=false SSL_PROVIDER=selfsigned \
        bash "${case_dir}/docker-entrypoint.sh" true >/dev/null

    assert_embed_player_not_frame_restricted "$generated_config"
    [ "$(grep -Fc "$HEADER_RULE" "$generated_config")" -eq 1 ] ||
        fail "the rendered config does not send X-Frame-Options exactly once per response"
}

assert_embed_player_not_frame_restricted \
    "${ROOT_DIR}/conf/nginx/templates/kvs.conf.tpl"
assert_embed_player_not_frame_restricted \
    "${ROOT_DIR}/docker/multi-site/nginx/kvs-caddy.conf.template"
run_rendered_template_case

echo "PASS: Nginx embed frame hardening"
