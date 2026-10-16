#!/bin/bash
# Real entrypoint, Nginx and PHP-FPM on an internal-only test network.
# No host ports or application data are used. Images can be overridden for
# local builds; otherwise use the same pinned bases as the Dockerfiles.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
endpoint=${DOCKER_HOST:-$(docker context inspect "${DOCKER_CONTEXT:-$(docker context show)}" --format '{{.Endpoints.docker.Host}}')}
case "$endpoint" in unix://*) ;; *) echo 'ERROR: local Docker socket required' >&2; exit 1 ;; esac
TEST_DIR=$(mktemp -d "${TMPDIR:-/var/tmp}/kvs-cloudflare-http.XXXXXX")
PREFIX="kvs-cloudflare-test-$$-$RANDOM"
NETWORK="$PREFIX"
containers=()
fail() { echo "FAIL: $*" >&2; exit 1; }
cleanup() {
    local status=$? container
    for container in "${containers[@]}"; do
        if [ "$status" -ne 0 ]; then docker logs --tail 30 "$container" >&2 2>&1 || true; fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    done
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
NGINX_IMAGE=${NGINX_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get nginx)}
PHP_IMAGE=${PHP_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-fpm 8.1)}
for image in "$NGINX_IMAGE" "$PHP_IMAGE"; do
    docker image inspect "$image" >/dev/null 2>&1 || docker pull "$image" >/dev/null
done
docker network create --internal "$NETWORK" >/dev/null
mkdir -p "$TEST_DIR/www"
chmod 0755 "$TEST_DIR" "$TEST_DIR/www"
install -m 0755 "$ROOT_DIR/docker/nginx/docker-entrypoint.sh" "$TEST_DIR/entrypoint.sh"
install -m 0755 "$ROOT_DIR/docker/nginx/rotate-site-logs.sh" "$TEST_DIR/rotate-site-logs"
install -m 0755 "$ROOT_DIR/docker/nginx/cloudflare-realip-check.sh" "$TEST_DIR/cloudflare-check.sh"
cat > "$TEST_DIR/www/ip.php" <<'PHP'
<?php
header('Content-Type: text/plain');
echo $_SERVER['REMOTE_ADDR'];
PHP
chmod 0644 "$TEST_DIR/www/ip.php"
php="$PREFIX-php"
containers+=("$php")
docker run -d --name "$php" --pull never --network "$NETWORK" --network-alias php-fpm \
    -v "$TEST_DIR/www:/var/www/kvs:ro" "$PHP_IMAGE" php-fpm -F >/dev/null
openssl dhparam -dsaparam -out "$TEST_DIR/dhparam.pem" 2048 >/dev/null 2>&1

fixture() {
    local name=$1 ranges=$2
    local dir="$TEST_DIR/$name"
    mkdir -p "$dir/conf.d" "$dir/templates" "$dir/globals"
    # Do not start one worker per host CPU in every disposable test container.
    sed 's/worker_processes     auto;/worker_processes     2;/' \
        "$ROOT_DIR/docker/nginx/nginx.conf" > "$dir/nginx.conf"
    if [ "$ranges" = trusted ]; then
        printf 'set_real_ip_from 127.0.0.1/32;\nset_real_ip_from ::1/128;\n' > "$dir/globals/cloudflare-ip-list.conf"
    else
        cp "$ROOT_DIR/conf/nginx/globals/cloudflare-ip-list.conf" "$dir/globals/"
    fi
    cat > "$dir/templates/kvs.conf.tpl" <<'NGINX'
server {
    listen 80;
    server_name example.test;
    access_log /var/log/nginx/cloudflare-test.access.log;
    # A successful config dump must never be printed by the entrypoint.
    set $private_test_marker "configuration-dump-must-stay-private";
    location / {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /var/www/kvs/ip.php;
        fastcgi_pass php-fpm:9000;
    }
}
NGINX
    printf '# Operator file must survive.\n' > "$dir/conf.d/operator.conf"
}

start() {
    local name=$1 value=$2 mode=${3:-single}
    local dir="$TEST_DIR/$name"
    container="$PREFIX-$name"
    containers+=("$container")
    local -a env=(-e "MODE=$mode" -e DOMAIN=example.test -e SSL_PROVIDER=none)
    [ "$value" = absent ] || env+=(-e "CLOUDFLARE_ENABLED=$value")
    docker run -d --name "$container" --pull never --network "$NETWORK" --memory 128m --pids-limit 128 \
        --entrypoint /custom-entrypoint.sh "${env[@]}" \
        -v "$TEST_DIR/entrypoint.sh:/custom-entrypoint.sh:ro" \
        -v "$TEST_DIR/rotate-site-logs:/usr/local/bin/rotate-site-logs:ro" \
        -v "$TEST_DIR/cloudflare-check.sh:/docker-entrypoint.d/40-kvs-cloudflare.sh:ro" \
        -v "$dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$dir/conf.d:/etc/nginx/conf.d" \
        -v "$dir/templates:/etc/nginx/templates:ro" \
        -v "$dir/globals:/etc/nginx/globals:ro" \
        -v "$TEST_DIR/dhparam.pem:/etc/nginx/dhparam.pem:ro" \
        "$NGINX_IMAGE" nginx -g 'daemon off;' >/dev/null
}

ready() {
    local attempt
    for ((attempt=0; attempt<100; attempt++)); do
        [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] || fail "$container stopped"
        if docker exec "$container" curl -fsS --max-time 2 -H 'Host: example.test' http://127.0.0.1/ > "$TEST_DIR/response" 2>/dev/null; then return; fi
        sleep 0.1
    done
    fail "$container never reached PHP"
}

address() {
    local expected=$1
    shift
    local actual
    actual=$(docker exec "$container" curl -fsS --max-time 5 -H 'Host: example.test' "$@" http://127.0.0.1/)
    [ "$actual" = "$expected" ] || fail "PHP received $actual, expected $expected"
    # Nginx and PHP must agree, rather than just exposing the raw header.
    docker exec "$container" tail -n 1 /var/log/nginx/cloudflare-test.access.log |
        grep -Fq "$expected -" || fail 'the access log did not use the visitor IP'
}

rejected() {
    local expected=$1 attempt
    for ((attempt=0; attempt<100; attempt++)); do
        if [ "$(docker inspect --format '{{.State.Running}}' "$container")" = false ]; then
            [ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" != 0 ] || fail 'invalid configuration exited successfully'
            docker logs "$container" > "$TEST_DIR/rejected.log" 2>&1
            grep -Fq "$expected" "$TEST_DIR/rejected.log" || fail "missing diagnostic: $expected"
            if grep -Fq 'configuration-dump-must-stay-private' "$TEST_DIR/rejected.log"; then fail 'configuration contents were logged'; fi
            return
        fi
        sleep 0.1
    done
    fail 'invalid configuration started Nginx'
}

for value in absent false empty; do
    fixture "$value" trusted
    setting=$value
    [ "$value" != empty ] || setting=''
    start "$value" "$setting"
    ready
    address 127.0.0.1 -H 'CF-Connecting-IP: 203.0.113.42'
    if docker exec "$container" test -e /run/kvs-nginx/cloudflare-realip.conf; then fail 'disabled config exists'; fi
done

fixture enabled trusted
main_before=$(sha256sum "$TEST_DIR/enabled/nginx.conf")
start enabled true
ready
address 203.0.113.42 -H 'CF-Connecting-IP: 203.0.113.42' -H 'X-Forwarded-For: 198.51.100.9'
address 2001:db8::42 -H 'CF-Connecting-IP: 2001:db8::42'
address 127.0.0.1
address 127.0.0.1 -H 'CF-Connecting-IP: invalid'
[ "$(sha256sum "$TEST_DIR/enabled/nginx.conf")" = "$main_before" ] || fail 'read-only main configuration changed'
docker logs "$container" > "$TEST_DIR/enabled.log" 2>&1
if grep -Fq 'configuration-dump-must-stay-private' "$TEST_DIR/enabled.log"; then fail 'configuration contents were logged'; fi
docker restart "$container" >/dev/null
ready
address 203.0.113.43 -H 'CF-Connecting-IP: 203.0.113.43'
docker exec "$container" sh -c 'test "$(find /run/kvs-nginx -type f | wc -l)" -eq 1'

# A new container keeps the host's conf.d but not the runtime fragment.
docker rm -f "$container" >/dev/null
start enabled false
ready
address 127.0.0.1 -H 'CF-Connecting-IP: 203.0.113.42'
if docker exec "$container" test -e /run/kvs-nginx/cloudflare-realip.conf; then fail 'runtime config survived recreation'; fi
# A plain restart retains the writable layer. False must remove only its
# own stale fragment before Nginx parses that layer again.
docker exec "$container" sh -c 'mkdir -p /run/kvs-nginx; printf "invalid stale configuration;\n" > /run/kvs-nginx/cloudflare-realip.conf; printf "# Keep this other fragment.\n" > /run/kvs-nginx/operator.conf'
docker restart "$container" >/dev/null
ready
address 127.0.0.1 -H 'CF-Connecting-IP: 203.0.113.42'
if docker exec "$container" test -e /run/kvs-nginx/cloudflare-realip.conf; then fail 'disabled restart kept its stale fragment'; fi
docker exec "$container" test -s /run/kvs-nginx/operator.conf || fail 'disabled restart deleted another fragment'
grep -Fxq '# Operator file must survive.' "$TEST_DIR/enabled/conf.d/operator.conf" || fail 'operator file was changed'
if find "$TEST_DIR/enabled/conf.d" -name '*cloudflare*' | grep -q .; then fail 'runtime config leaked into persistent conf.d'; fi

fixture untrusted shipped
start untrusted true
ready
address 127.0.0.1 -H 'CF-Connecting-IP: 203.0.113.42' -H 'X-Forwarded-For: 198.51.100.1' -H 'X-Real-IP: 198.51.100.2'

# Operator templates are rendered by the official entrypoint before the
# Cloudflare check. This explicit include does not exist on first startup.
fixture operator-template trusted
printf 'include /etc/nginx/conf.d/snippet.conf;\n' >> "$TEST_DIR/operator-template/conf.d/operator.conf"
# shellcheck disable=SC2016  # These are Nginx variables, not shell variables.
printf 'map $host $operator_marker { default ready; }\n' > "$TEST_DIR/operator-template/templates/snippet.conf.template"
start operator-template true
ready
address 203.0.113.45 -H 'CF-Connecting-IP: 203.0.113.45'
test -s "$TEST_DIR/operator-template/conf.d/snippet.conf" || fail 'operator template was not rendered'

fixture duplicate trusted
printf 'real_ip_header X-Forwarded-For;\n' >> "$TEST_DIR/duplicate/conf.d/operator.conf"
manual_before=$(sha256sum "$TEST_DIR/duplicate/conf.d/operator.conf")
start duplicate true
rejected 'existing manual Real IP directives'
[ "$(sha256sum "$TEST_DIR/duplicate/conf.d/operator.conf")" = "$manual_before" ] || fail 'manual conflict was overwritten'

fixture old-main trusted
sed -i '\|include /run/kvs-nginx/\*.conf;|d' "$TEST_DIR/old-main/nginx.conf"
start old-main true
rejected 'nginx.conf does not load'
docker rm -f "$container" >/dev/null
start old-main false
ready
address 127.0.0.1 -H 'CF-Connecting-IP: 203.0.113.42'

fixture invalid trusted
start invalid yes
rejected 'CLOUDFLARE_ENABLED must be true or false'
fixture multi trusted
start multi true multi
rejected 'single-site mode only'
fixture missing-list trusted
: > "$TEST_DIR/missing-list/globals/cloudflare-ip-list.conf"
start missing-list true
rejected 'non-empty Cloudflare IP list'

echo 'PASS: Cloudflare restores IPs in real PHP and logs; disable/restart/recreation, trust boundaries and migration diagnostics verified'
