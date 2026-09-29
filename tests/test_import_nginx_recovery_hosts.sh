#!/bin/bash
# The automatic recovery of the KVS rewrites from the old server's nginx
# configuration (no _INSTALL, no archive, no IMPORT_NGINX_REWRITES) must not
# carry the rules of another host whose vhost shares the site's files, such
# as a CDN origin, into the site's own vhost.
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-nginx-recovery-hosts.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
awk '$0 == "import_ensure_nginx_rewrites() {" { capture = 1 } capture { print } capture && /^}$/ { exit }' \
    "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"
# shellcheck disable=SC2034  # Read by the extracted function.
{
    RED='' NC='' DOMAIN=example.com IMPORT_MODE=true IMPORT_NGINX_REWRITES=''
    IMPORT_OLD_PATH=/var/www/example.com IMPORT_REMOTE_DIR=/var/www/example.com
    IMPORT_DETECTED_DOMAIN=example.com IMPORT_STAGING="$TEST_DIR/import"
    IMPORT_NGINX_CONFIG="$TEST_DIR/old-nginx.conf"
}
mkdir -p "$TEST_DIR/work" && cd "$TEST_DIR/work" || exit 1
status=0

# recover <case> <expected rules>
recover() {
    local site="$TEST_DIR/$1"
    rm -rf "$site" "$IMPORT_STAGING"
    mkdir -p "$site"
    # A subshell: the function exits the setup when it finds no rules.
    if ! (import_ensure_nginx_rewrites "$site") > "$TEST_DIR/$1.log" 2>&1; then
        cat "$TEST_DIR/$1.log" >&2
        echo "FAIL: $1: the recovery stopped" >&2
        status=1
        return
    fi
    if [ "$(grep -v '^#' "$site/_INSTALL/nginx_config.txt")" != "$2" ]; then
        grep -v '^#' "$site/_INSTALL/nginx_config.txt" | sed 's/^/  got: /' >&2
        echo "FAIL: $1: $3" >&2
        status=1
        return
    fi
    echo "PASS: $1: $3"
}

cat > "$IMPORT_NGINX_CONFIG" <<'EOF'
# configuration file /etc/nginx/nginx.conf:
http { include /etc/nginx/sites-enabled/*; }
# configuration file /etc/nginx/sites-enabled/cdn.example.com:
server {
    listen 443 ssl;
    server_name cdn.example.com;
    root /var/www/example.com/contents;
    rewrite ^/(.*)$ /videos_screenshots/$1 break;
}
# configuration file /etc/nginx/sites-enabled/example.com:
server {
    listen 443 ssl;
    server_name example.com www.example.com;
    root /var/www/example.com;
    rewrite ^/videos/$ /videos_list.php last;
}
EOF
recover cdn 'rewrite ^/videos/$ /videos_list.php last;' \
    "only the site's own rules, not those of the CDN host sharing its files"

# A lone catch-all vhost still serves the site: its rules stay.
cat > "$IMPORT_NGINX_CONFIG" <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/example.com;
    rewrite ^/videos/$ /videos_list.php last;
}
EOF
recover catch-all 'rewrite ^/videos/$ /videos_list.php last;' 'a catch-all vhost of the site is still recovered'

# The default server of the machine, named after the machine, serves the
# site when no vhost is named after it: its rules stay.
cat > "$IMPORT_NGINX_CONFIG" <<'EOF'
server {
    listen 80 default_server;
    server_name server1.hosting.example;
    root /var/www/example.com;
    rewrite ^/videos/$ /videos_list.php last;
}
EOF
recover machine-name 'rewrite ^/videos/$ /videos_list.php last;' \
    'a site no vhost is named after keeps the rules of the vhost serving it'
exit "$status"
