#!/bin/bash
# Exercise the generated configurations with real, isolated Nginx and Caddy.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NGINX_TEST_IMAGE=${NGINX_TEST_IMAGE:-nginx:alpine}
CADDY_TEST_IMAGE=${CADDY_TEST_IMAGE:-caddy:2-alpine}
endpoint=${DOCKER_HOST:-$(docker context inspect "${DOCKER_CONTEXT:-$(docker context show)}" --format '{{.Endpoints.docker.Host}}')}
case "$endpoint" in unix://*) ;; *) echo 'ERROR: local Docker socket required' >&2; exit 1 ;; esac
docker image inspect "$NGINX_TEST_IMAGE" "$CADDY_TEST_IMAGE" >/dev/null
TEST_DIR=$(mktemp -d /tmp/kvs-origin-http.XXXXXX)
network="kvs-origin-$$-$RANDOM"
containers=()
cleanup() {
    local status=$?
    for container in "${containers[@]}"; do
        if [ "$status" -ne 0 ]; then docker logs "$container" >&2 2>/dev/null || true; fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    done
    docker network rm "$network" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

docker network create "$network" >/dev/null
mkdir -p "$TEST_DIR/site" "$TEST_DIR/acme/.well-known/acme-challenge" "$TEST_DIR/includes"
printf 'origin-site-sentinel\n' > "$TEST_DIR/site/index.html"
printf 'acme-sentinel\n' > "$TEST_DIR/acme/.well-known/acme-challenge/proof"
: > "$TEST_DIR/includes/kvs-rewrites.conf"
openssl genpkey -genparam -algorithm DH -pkeyopt group:ffdhe2048 \
    -out "$TEST_DIR/dhparam.pem" 2>/dev/null
sed -e 's/worker_processes     auto;/worker_processes     2;/' \
    -e 's|access_log           /var/log/nginx/access.log;|access_log /dev/stdout;|' \
    -e 's|error_log            /var/log/nginx/error.log warn;|error_log /dev/stderr warn;|' \
    "$ROOT_DIR/docker/nginx/nginx.conf" > "$TEST_DIR/nginx.conf"

render() {
    local name=$1 domain=$2 www=$3 provider=$4 template=$5
    local root="$TEST_DIR/$name"
    mkdir -p "$root/etc/nginx/templates" "$root/etc/nginx/conf.d" "$root/etc/nginx/ssl/$domain"
    cp "$template" "$root/etc/nginx/templates/kvs.conf.tpl"
    sed -e "s|/etc/nginx|$root/etc/nginx|g" \
        -e 's|exec /docker-entrypoint.sh "$@"|exec "$@"|' \
        -e '/^[[:space:]]*monitor_certificate_changes &$/c\    : # No background worker in the rendering fixture.' \
        "$ROOT_DIR/docker/nginx/docker-entrypoint.sh" > "$root/entrypoint.sh"
    DOMAIN="$domain" USE_WWW="$www" SSL_PROVIDER="$provider" \
        sh "$root/entrypoint.sh" true > "$root/render.log"
    # Restore the production paths after rendering outside the container.
    sed -i "s|$root/etc/nginx|/etc/nginx|g" "$root/etc/nginx/conf.d/kvs.conf"
    chmod -R a+rX "$TEST_DIR"
}

start_nginx() {
    local name=$1
    local main_config="$TEST_DIR/nginx.conf"
    if [ -f "$TEST_DIR/$name/nginx.conf" ]; then main_config="$TEST_DIR/$name/nginx.conf"; fi
    nginx_container="$network-$name"
    containers+=("$nginx_container")
    docker run -d --pull never --name "$nginx_container" \
        --network "$network" --network-alias n.example.test \
        --add-host php-fpm:127.0.0.1 --memory 128m --pids-limit 128 \
        -p 127.0.0.1::80 -p 127.0.0.1::443 \
        -v "$main_config:/etc/nginx/nginx.conf:ro" \
        -v "$TEST_DIR/$name/etc/nginx/conf.d:/etc/nginx/conf.d:ro" \
        -v "$TEST_DIR/$name/etc/nginx/ssl:/etc/nginx/ssl:ro" \
        -v "$TEST_DIR/dhparam.pem:/etc/nginx/dhparam.pem:ro" \
        -v "$TEST_DIR/includes:/etc/nginx/includes:ro" \
        -v "$ROOT_DIR/conf/nginx/globals:/etc/nginx/globals:ro" \
        -v "$TEST_DIR/site:/var/www/kvs:ro" \
        -v "$TEST_DIR/site:/var/www/example.test:ro" \
        -v "$TEST_DIR/acme:/var/www/_letsencrypt:ro" \
        --entrypoint nginx "$NGINX_TEST_IMAGE" -g 'daemon off;' >/dev/null
    wait_nginx
}

wait_nginx() {
    # Docker can allocate new ephemeral host ports after a restart.
    http_port=$(docker port "$nginx_container" 80/tcp | sed -n 's/^127\.0\.0\.1://p')
    https_port=$(docker port "$nginx_container" 443/tcp | sed -n 's/^127\.0\.0\.1://p')
    for ((attempt=0; attempt<50; attempt++)); do
        if curl --noproxy '*' -sS --max-time 1 -H "Host: $domain" \
            "http://127.0.0.1:$http_port/" > /dev/null 2>&1; then
            docker exec "$nginx_container" nginx -t > "$TEST_DIR/validation.log" 2>&1
            return
        fi
        sleep 0.1
    done
    fail 'Nginx did not start'
}

request() {
    curl_status=0
    http_status=$(curl --noproxy '*' --http1.1 -ksS --max-time 4 \
        -D "$TEST_DIR/headers" -o "$TEST_DIR/body" -w '%{http_code}' "$@" \
        2> "$TEST_DIR/curl-error") || curl_status=$?
}
assert_closed() {
    request "$@"
    [ "$http_status" = 000 ] || fail "request leaked an HTTP response: $* ($http_status)"
    case "$curl_status" in 52|56) ;; *) fail "expected closed HTTP connection, got curl $curl_status: $*" ;; esac
    [ ! -s "$TEST_DIR/headers" ] || fail 'rejected request leaked headers'
}
assert_tls_rejected() {
    local port=$1 sni=$2
    local args=()
    if [ -n "$sni" ]; then args=(-servername "$sni"); else args=(-noservername); fi
    if timeout 5 openssl s_client -connect "127.0.0.1:$port" "${args[@]}" \
        -showcerts </dev/null > "$TEST_DIR/tls.log" 2>&1; then
        fail "TLS accepted unknown SNI: $sni"
    fi
    grep -q 'BEGIN CERTIFICATE' "$TEST_DIR/tls.log" && fail 'default TLS server exposed a certificate'
    grep -Eiq 'alert|handshake failure' "$TEST_DIR/tls.log" || fail 'TLS failed for an unrelated reason'
}

for variant in direct www subdomain; do
    domain=example.test
    www=false
    if [ "$variant" = www ]; then www=true; fi
    if [ "$variant" = subdomain ]; then domain=sub.example.test; fi
    canonical="$domain"
    if [ "$www" = true ]; then canonical="www.$domain"; fi
    render "$variant" "$domain" "$www" selfsigned "$ROOT_DIR/conf/nginx/templates/kvs.conf.tpl"
    start_nginx "$variant"

    for pass in initial regenerated; do
        assert_closed "http://127.0.0.1:$http_port/"
        assert_closed -H 'Host: unrelated.test' "http://127.0.0.1:$http_port/"
        assert_closed -H 'Host: [::1]' "http://127.0.0.1:$http_port/"
        assert_closed --http1.0 -H 'Host:' "http://127.0.0.1:$http_port/"
        assert_tls_rejected "$https_port" ''
        assert_tls_rejected "$https_port" unrelated.test
        assert_closed --resolve "$canonical:$https_port:127.0.0.1" \
            -H 'Host: unrelated.test' "https://$canonical:$https_port/"
        assert_closed --http1.0 --resolve "$canonical:$https_port:127.0.0.1" \
            -H 'Host:' "https://$canonical:$https_port/"
        request --resolve "$canonical:$https_port:127.0.0.1" "https://$canonical:$https_port/index.html"
        [ "$http_status" = 200 ] || fail "canonical site failed: HTTP $http_status, curl $curl_status"
        grep -qx 'origin-site-sentinel' "$TEST_DIR/body" || fail 'incorrect canonical site body'
        request -H "Host: $domain" "http://127.0.0.1:$http_port/path"
        [ "$http_status" = 301 ] || fail 'domain redirect failed'
        grep -Fq "Location: https://$canonical/path" "$TEST_DIR/headers" || fail 'incorrect canonical redirect'
        request -H "Host: $domain" "http://127.0.0.1:$http_port/.well-known/acme-challenge/proof"
        [ "$http_status" = 200 ] || fail 'ACME challenge failed'
        grep -qx acme-sentinel "$TEST_DIR/body" || fail 'incorrect ACME challenge body'
        assert_closed "http://127.0.0.1:$http_port/.well-known/acme-challenge/proof"
        if [ "$variant" = subdomain ]; then assert_tls_rejected "$https_port" "www.$domain"; fi
        if [ "$pass" = initial ]; then
            render "$variant" "$domain" "$www" selfsigned "$ROOT_DIR/conf/nginx/templates/kvs.conf.tpl"
            docker restart "$nginx_container" >/dev/null
            wait_nginx
        fi
    done
    docker rm -f "$nginx_container" >/dev/null
    printf 'PASS: %s host/SNI rejection, valid site, redirects and ACME after regeneration/restart.\n' "$variant"
done

domain=example.test
render proxy "$domain" false none "$ROOT_DIR/docker/multi-site/nginx/kvs-caddy.conf.template"
start_nginx proxy
assert_closed "http://127.0.0.1:$http_port/"
request -H 'Host: example.test' "http://127.0.0.1:$http_port/health"
[ "$http_status" = 200 ] || fail 'named health check failed'
# Run the actual additional-site Compose health check against this upstream.
env DOMAIN=example.test SITE_PREFIX=origin-test MARIADB_ROOT_PASSWORD=test-root MARIADB_PASSWORD=test-user \
    docker compose --env-file "$ROOT_DIR/docker/.env.example" \
    -f "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template" \
    config --format json > "$TEST_DIR/additional-site.json"
mapfile -t health_command < <(jq -r '.services.nginx.healthcheck.test[1:][]' "$TEST_DIR/additional-site.json")
docker exec "$nginx_container" "${health_command[@]}" > "$TEST_DIR/container-health.log"

mkdir -p "$TEST_DIR/caddy/sites"
# Use the installer's real CLI in a temporary directory, with an internal CA.
cp "$ROOT_DIR/docker/multi-site/site-manager.sh" "$TEST_DIR/site-manager.sh"
CADDY_SITES_DIR="$TEST_DIR/caddy/sites"
bash "$TEST_DIR/site-manager.sh" proxy-config example.test internal false true > "$TEST_DIR/caddy-generation.log"
sed -i 's/health_interval 30s/health_interval 1s/' "$CADDY_SITES_DIR/example.test.caddy"
cp "$ROOT_DIR/docker/multi-site/caddy/Caddyfile" "$TEST_DIR/caddy/Caddyfile"
caddy_container="$network-caddy"
containers+=("$caddy_container")
docker run -d --pull never --name "$caddy_container" --network "$network" \
    --memory 192m --pids-limit 64 -p 127.0.0.1::80 -p 127.0.0.1::443 \
    -v "$TEST_DIR/caddy:/etc/caddy:ro" --tmpfs /data --tmpfs /config \
    "$CADDY_TEST_IMAGE" >/dev/null
caddy_http=$(docker port "$caddy_container" 80/tcp | sed -n 's/^127\.0\.0\.1://p')
caddy_https=$(docker port "$caddy_container" 443/tcp | sed -n 's/^127\.0\.0\.1://p')
for ((attempt=0; attempt<50; attempt++)); do
    request --resolve "example.test:$caddy_https:127.0.0.1" "https://example.test:$caddy_https/index.html"
    if [ "$http_status" = 200 ]; then break; fi
    sleep 0.1
done
[ "$http_status" = 200 ] || fail 'Caddy site failed'
grep -qx origin-site-sentinel "$TEST_DIR/body" || fail 'incorrect Caddy site body'
# Let active health checks run before proving the route still serves the site.
sleep 3
request --resolve "example.test:$caddy_https:127.0.0.1" "https://example.test:$caddy_https/index.html"
[ "$http_status" = 200 ] || fail 'Caddy marked the hostname-protected upstream unhealthy'
assert_closed "http://127.0.0.1:$caddy_http/"
assert_closed -H 'Host: unrelated.test' "http://127.0.0.1:$caddy_http/"
assert_tls_rejected "$caddy_https" ''
assert_tls_rejected "$caddy_https" unrelated.test
request -H 'Host: example.test' "http://127.0.0.1:$caddy_http/path"
[ "$http_status" = 308 ] || fail 'Caddy HTTP-to-HTTPS redirect failed'
grep -Fq 'Location: https://example.test/path' "$TEST_DIR/headers" || fail 'incorrect Caddy redirect'
printf 'PASS: real Caddy routing, active health checks, unknown HTTP hosts and unknown/missing TLS SNI.\n'

# Exercise the standalone templates using the same Nginx binary in isolation.
domain=example.test
render native "$domain" false selfsigned "$ROOT_DIR/conf/nginx/templates/kvs.conf.tpl"
sed -e 's/user                 www-data;/user                 nginx;/' \
    -e 's/worker_processes     auto;/worker_processes     2;/' \
    "$ROOT_DIR/conf/nginx/nginx.conf" > "$TEST_DIR/native/nginx.conf"
sed -e 's/domain.tld/example.test/g' -e 's/project_url/example.test/g' \
    "$ROOT_DIR/conf/nginx/conf.d/sslgen.conf" > "$TEST_DIR/native/etc/nginx/conf.d/kvs.conf"
start_nginx native
assert_closed "http://127.0.0.1:$http_port/"
assert_tls_rejected "$https_port" ''
request -H 'Host: example.test' "http://127.0.0.1:$http_port/.well-known/acme-challenge/proof"
[ "$http_status" = 200 ] || fail 'standalone ACME bootstrap failed'

sed -e 's/domain.tld/example.test/g' -e 's/project_url/example.test/g' \
    -e 's/redirect_server_name/www.example.test/g' \
    "$ROOT_DIR/conf/nginx/conf.d/domain.conf" > "$TEST_DIR/native/etc/nginx/conf.d/kvs.conf"
docker restart "$nginx_container" >/dev/null
wait_nginx
assert_closed "http://127.0.0.1:$http_port/"
assert_closed -H 'Host: unrelated.test' "http://127.0.0.1:$http_port/"
assert_tls_rejected "$https_port" ''
assert_tls_rejected "$https_port" unrelated.test
assert_closed --resolve "example.test:$https_port:127.0.0.1" \
    -H 'Host: unrelated.test' "https://example.test:$https_port/"
assert_closed --http1.0 --resolve "example.test:$https_port:127.0.0.1" \
    -H 'Host:' "https://example.test:$https_port/"
request --resolve "example.test:$https_port:127.0.0.1" "https://example.test:$https_port/index.html"
[ "$http_status" = 200 ] || fail 'standalone site failed'
grep -qx origin-site-sentinel "$TEST_DIR/body" || fail 'incorrect standalone site body'
request --resolve "www.example.test:$https_port:127.0.0.1" "https://www.example.test:$https_port/path"
[ "$http_status" = 301 ] || fail 'standalone canonical redirect failed'
grep -Fq 'Location: https://example.test/path' "$TEST_DIR/headers" || fail 'incorrect standalone redirect'
printf 'PASS: standalone bootstrap ACME, host/SNI rejection, configured site and canonical redirect.\n'
