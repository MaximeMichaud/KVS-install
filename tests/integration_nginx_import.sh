#!/bin/bash
# Optional real-nginx routing proof with synthetic data and a local image.
# shellcheck disable=SC2034
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NGINX_TEST_IMAGE=${NGINX_TEST_IMAGE:-nginx:alpine}
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
TEST_DIR=$(mktemp -d /tmp/kvs-nginx-import.XXXXXX)
container="kvs-nginx-import-$RANDOM-$$"
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then docker logs "$container" 2>/dev/null >&2 || true; fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/import.sh"
awk '
    /^import_ensure_nginx_rewrites\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" > "$TEST_DIR/setup-functions.sh"
# shellcheck source=/dev/null
source "$TEST_DIR/setup-functions.sh"
RED='' NC='' DOMAIN=example.test IMPORT_MODE=true
IMPORT_STAGING="$TEST_DIR/import" IMPORT_REUSE_SITE_DIR=''
IMPORT_REMOTE_DIR='' IMPORT_OLD_PATH=/srv/example
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
{ printf 'server { root /srv/example;\n'; cat explicit.conf; printf '}\n'; } > source.conf
if (import_ensure_nginx_rewrites "$site") > setup.log 2>&1; then fail 'nested recovery must fail'; fi
[ ! -e "$site/_INSTALL/nginx_config.txt" ] || fail 'nested recovery wrote partial rules'
IMPORT_NGINX_REWRITES="$TEST_DIR/explicit.conf"
import_ensure_nginx_rewrites "$site" > setup.log
cmp explicit.conf "$site/_INSTALL/nginx_config.txt" || fail 'explicit fragment changed'

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
        include /fixture/site/_INSTALL/nginx_config.txt;
        location = / { return 200 "home\n"; }
        location = /admin/ { return 200 "admin\n"; }
        location / { return 404; }
    }
}
NGINX
chmod -R a+rX "$TEST_DIR"
docker run -d --name "$container" --pull never --read-only \
    --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /tmp:rw,noexec,nosuid,size=16m --memory 64m --pids-limit 32 \
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
assert_http() {
    local path=$1 expected_status=$2 expected_body=${3:-} status
    status=$(curl --noproxy '*' -sS --max-time 3 -o response -w '%{http_code}' "$base$path")
    [ "$status" = "$expected_status" ] || fail "HTTP status for $path: $status"
    if [ -n "$expected_body" ]; then
        [ "$(cat response)" = "$expected_body" ] || fail "HTTP body for $path"
    fi
}
check_routes() {
    assert_http / 200 home
    assert_http /admin/ 200 admin
    assert_http /plain 200 destination
    assert_http /limited/item 403
    assert_http '/limited/item?preview=no' 403
    assert_http '/limited/item?preview=yes' 200 preview
    assert_http /missing 404
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
cmp explicit.conf "$site/_INSTALL/nginx_config.txt" || fail 'saved override was not restored'
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
echo 'PASS: 14 HTTP routing checks, nginx validation, persisted override and reload'
