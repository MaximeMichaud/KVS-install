#!/bin/bash
# Optional real-nginx routing proof with synthetic data and a local image.
# Source mode also requires a local PHP-FPM image (PHP_TEST_IMAGE).
# shellcheck disable=SC2034
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NGINX_TEST_IMAGE=${NGINX_TEST_IMAGE:-nginx:alpine}
PHP_TEST_IMAGE=${PHP_TEST_IMAGE:-php:8.3-fpm-alpine}
NGINX_IMPORT_TEST_MODE=${NGINX_IMPORT_TEST_MODE:-file}
case "$NGINX_IMPORT_TEST_MODE" in
    file|source) ;;
    *) echo 'ERROR: NGINX_IMPORT_TEST_MODE must be file or source' >&2; exit 1 ;;
esac
if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
else
    endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
fi
case "$endpoint" in
    unix://*) ;;
    *) echo 'ERROR: this integration test requires a local Docker socket' >&2; exit 1 ;;
esac
docker image inspect "$NGINX_TEST_IMAGE" >/dev/null
if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then docker image inspect "$PHP_TEST_IMAGE" >/dev/null; fi
TEST_DIR=$(mktemp -d /tmp/kvs-nginx-import.XXXXXX)
container="kvs-nginx-import-$RANDOM-$$"
php_container="$container-php"
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        docker logs "$container" 2>/dev/null >&2 || true
        docker logs "$php_container" 2>/dev/null >&2 || true
    fi
    docker rm -f "$php_container" >/dev/null 2>&1 || true
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
for name in import_prepare_source_nginx_rewrites import_ensure_nginx_rewrites; do
    awk -v signature="$name() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh"
done > "$TEST_DIR/setup-functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/setup-functions.sh"
RED='' NC='' DOMAIN=example.test IMPORT_MODE=true
IMPORT_STAGING="$TEST_DIR/import" IMPORT_REUSE_SITE_DIR=''
IMPORT_REMOTE_DIR='' IMPORT_OLD_PATH=/srv/example
IMPORT_DETECTED_DOMAIN=example.test
IMPORT_NGINX_CONFIG="$TEST_DIR/source.conf" IMPORT_NGINX_REWRITES=''
site="$TEST_DIR/site"
mkdir -p "$TEST_DIR/kvs-archive"
cd "$TEST_DIR"
cat > explicit.conf <<'NGINX'
rewrite ^/plain$ /destination last;
location /limited/ {
    if ($arg_preview = yes) {
        rewrite ^ /preview last;
    }
    return 403;
}
location = /preview { return 200 "preview\n"; }
location = /destination { return 200 "destination\n"; }
NGINX
if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then
    # This fragment exists only on the simulated source. The destination starts empty.
    cat >> explicit.conf <<'NGINX'
location = /php-check {
    internal;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    fastcgi_param SCRIPT_FILENAME $document_root/php-check.php;
}
include members-area.conf;
NGINX
fi
{
    printf '# configuration file /etc/nginx/nginx.conf:\n'
    printf 'server { server_name example.test; root /srv/example; include routes.conf; }\n'
    printf '# configuration file /etc/nginx/routes.conf:\n'
    cat explicit.conf
    if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then cat "$ROOT_DIR/tests/fixtures/nginx-auth-request.conf"; fi
    printf '# configuration file /etc/nginx/cdn.conf:\n'
    printf 'server { server_name cdn.example.test; root /srv/example/contents; location / { rewrite ^ /wrong-cdn last; } }\n'
} > source.conf
if (import_ensure_nginx_rewrites "$site") > setup.log 2>&1; then fail 'nested recovery must fail'; fi
[ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail 'nested recovery wrote partial rules'
if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then
    IMPORT_NGINX_REWRITES=source
    # Only the collected source report remains available to the new destination.
    rm explicit.conf
else
    IMPORT_NGINX_REWRITES="$TEST_DIR/explicit.conf"
fi
import_ensure_nginx_rewrites "$site" > setup.log
if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then
    grep -Fq 'fastcgi_pass php-fpm:9000;' "$site/_INSTALL/nginx_config.txt" || fail 'PHP backend was not adapted'
    cp "$site/_INSTALL/nginx_config.txt" expected.conf
else
    cmp explicit.conf "$site/_INSTALL/nginx_config.txt" || fail 'explicit fragment changed'
    cp explicit.conf expected.conf
fi

mkdir -p "$site/members/7/thumbs" "$site/members/originals"
printf 'member photo\n' > "$site/members/7/photo.jpg"
printf 'public thumbnail\n' > "$site/members/7/thumbs/photo.jpg"
printf 'original upload\n' > "$site/members/originals/photo.jpg"
cat > "$site/check_member.php" <<'PHP'
<?php
// A synthetic authorizer: no site code, credentials or database connection.
if (($_SERVER['MEMBER_ALBUM_ID'] ?? '') !== '7') {
    http_response_code(500);
    exit;
}
header('X-Auth-Check: checked');
$result = $_SERVER['HTTP_X_FIXTURE_AUTH'] ?? '';
http_response_code($result === 'allow' ? 204 : ($result === 'error' ? 500 : 403));
PHP
cat > php-fpm.conf <<'FPM'
[global]
error_log = /proc/self/fd/2
[www]
listen = 127.0.0.1:9000
pm = static
pm.max_children = 1
catch_workers_output = yes
FPM
cat > nginx.conf <<'NGINX'
pid /tmp/nginx.pid;
error_log /dev/stderr notice;
events {}
http {
    access_log /dev/stdout;
    client_body_temp_path /tmp/client;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 8080;
        server_name example.test;
        root /fixture/site;
        error_page 404 /404.php;
        include /fixture/site/_INSTALL/nginx_config.txt;
        location = / { return 200 "home\n"; }
        location = /admin/ { return 200 "admin\n"; }
        location = /404.php { return 404 "missing\n"; }
        # The recovered member guards must precede the normal asset handler.
        location ~* \.(jpg|png)$ { expires 180d; }
        location / { return 404; }
    }
}
NGINX
chmod -R a+rX "$TEST_DIR"
docker run -d --name "$container" --pull never --read-only \
    --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m --memory 64m --pids-limit 32 \
    --add-host php-fpm:127.0.0.1 \
    -p 127.0.0.1::8080 -v "$TEST_DIR:/fixture:ro" \
    --entrypoint nginx "$NGINX_TEST_IMAGE" -c /fixture/nginx.conf -g 'daemon off;' >/dev/null
port=$(docker port "$container" 8080/tcp | sed -n 's/^127\.0\.0\.1://p')
[ -n "$port" ] || fail 'missing local HTTP port'
base="http://127.0.0.1:$port"
for ((attempt = 0; attempt < 40; attempt++)); do
    if curl --noproxy '*' -fsS --max-time 1 "$base/" > response 2>/dev/null; then break; fi
    sleep 0.1
done
docker exec "$container" nginx -t -c /fixture/nginx.conf > validation.log 2>&1
if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then
    # Share only the disposable nginx network namespace. The adapted php-fpm
    # name resolves to loopback inside it; no PHP port is exposed on the host.
    docker run -d --name "$php_container" --pull never --read-only \
        --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
        --network "container:$container" --tmpfs /tmp:rw,noexec,nosuid,size=16m \
        --memory 64m --pids-limit 32 -v "$TEST_DIR:/fixture:ro" \
        --entrypoint php-fpm "$PHP_TEST_IMAGE" -n -F -y /fixture/php-fpm.conf >/dev/null
    for ((attempt = 0; attempt < 40; attempt++)); do
        if docker logs "$php_container" 2>&1 | grep -q 'ready to handle connections'; then break; fi
        sleep 0.1
    done
    docker logs "$php_container" 2>&1 | grep -q 'ready to handle connections' || fail 'PHP-FPM did not start'
fi
checks=0
assert_http() {
    local path=$1 expected_status=$2 expected_body=${3:-} authorization=${4:-deny} status
    status=$(curl --noproxy '*' -sS --max-time 3 -D headers -o response -w '%{http_code}' \
        -H "X-Fixture-Auth: $authorization" "$base$path")
    [ "$status" = "$expected_status" ] || fail "HTTP status for $path: $status"
    if [ -n "$expected_body" ]; then
        [ "$(cat response)" = "$expected_body" ] || fail "HTTP body for $path"
    fi
    checks=$((checks + 1))
}
check_routes() {
    assert_http / 200 home
    assert_http /admin/ 200 admin
    assert_http /plain 200 destination
    assert_http /limited/item 403
    assert_http '/limited/item?preview=no' 403
    assert_http '/limited/item?preview=yes' 200 preview
    assert_http /missing 404
    if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then
        assert_http /php-check 404
        assert_http /members/originals/photo.jpg 404
        assert_http /members/7/thumbs/photo.jpg 200 'public thumbnail'
        assert_http /members/7/photo.jpg 404 missing
        cp response denied-response
        assert_http /members/7/absent.jpg 404 missing
        cmp response denied-response || fail 'denied and missing member files differ'
        assert_http /members/7/photo.jpg 200 'member photo' allow
        grep -qi '^Cache-Control: private, no-store' headers || fail 'an authorized member file can be cached'
        grep -qi '^X-Member-Check: checked' headers || fail 'authorization result variable was lost'
        assert_http /members/7/photo.jpg 500 '' error
        assert_http /_member_check 404 missing allow
        assert_http /_members_only/members/7/photo.jpg 404 '' allow
    fi
}
check_routes
# Simulate another transfer replacing _INSTALL, then restore from disk in a
# fresh setup process and verify the real server after a reload.
printf 'rewrite ^ /missing last;\n' > "$site/_INSTALL/nginx_config.txt"
(
    export RED NC DOMAIN IMPORT_MODE IMPORT_STAGING IMPORT_REUSE_SITE_DIR
    export IMPORT_NGINX_REWRITES=''
    bash -eu -c 'source "$1"; import_ensure_nginx_rewrites "$2"' bash "$TEST_DIR/setup-functions.sh" "$site"
) > setup.log
cmp expected.conf "$site/_INSTALL/nginx_config.txt" || fail 'saved override was not restored'
docker exec "$container" nginx -t -c /fixture/nginx.conf >> validation.log 2>&1
docker exec "$container" nginx -s reload -c /fixture/nginx.conf >> validation.log 2>&1
# Wait for nginx to log the new worker before checking the restored routing.
for ((attempt = 0; attempt < 40; attempt++)); do
    workers=$(docker logs "$container" 2>&1 | grep -c 'start worker process' || true)
    if [ "$workers" -ge 2 ]; then break; fi
    sleep 0.1
done
[ "$workers" -ge 2 ] || fail 'nginx did not reload'
check_routes
if [ "$NGINX_IMPORT_TEST_MODE" = source ]; then
    docker stop --time 3 "$php_container" >/dev/null
    assert_http /members/7/photo.jpg 500 '' allow
    assert_http /members/7/thumbs/photo.jpg 200 'public thumbnail'
    echo "PASS: $checks HTTP routing checks, PHP authorization, backend failure, persistence and reload"
else
    echo "PASS: $checks HTTP routing checks, nginx validation, persisted override and reload"
fi
