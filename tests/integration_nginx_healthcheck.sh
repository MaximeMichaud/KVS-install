#!/bin/bash
# Real-Nginx proof of the Nginx health checks of the Compose files. Each
# layout renders its configuration through the real
# docker/nginx/docker-entrypoint.sh, in the nginx base docker/images.lock
# pins, and the probe Compose declares for it runs in that container:
#
#   single      docker-compose.yml alone: /health on port 80 is the redirect
#               to HTTPS (301)
#   primary     docker-compose.yml with docker-compose.multi.yml, the primary
#               site of a multi-site installation behind Caddy (200)
#   site        an additional site, multi-site/docker-compose.site.yml.template
#               (200)
#
# The probe must pass in each, and the previous probe, which sent no Host
# header, must fail: Nginx closes the connection (444) on a host it does not
# serve, so a probe that passes there would prove nothing. PHP-FPM is never
# started; its name points at a port where nothing listens, so the probe
# cannot depend on it.
#
# The containers run with no network and publish no port. The pinned base is
# pulled when it is not on this machine; NGINX_TEST_IMAGE names another
# image to run instead.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly DOMAIN=example.com
# The probe docker-compose.yml declared before it named the site.
readonly -a OLD_PROBE=(curl -fsS -o /dev/null http://127.0.0.1/)

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v openssl >/dev/null 2>&1 || fail "openssl is required for the DH parameters"

IMAGE=${NGINX_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get nginx)}
readonly IMAGE
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Pulling $IMAGE"
    docker pull --quiet "$IMAGE" >/dev/null || fail "cannot pull $IMAGE"
fi

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvsctltest-stack-nginx-health.XXXXXX")
readonly TEST_DIR
readonly NAME_PREFIX="kvsctltest-stack-nginx-health-$$-$RANDOM"
containers=()

cleanup() {
    local status=$? container

    for container in "${containers[@]}"; do
        if [ "$status" -ne 0 ]; then
            echo "--- logs of $container" >&2
            docker logs "$container" >&2 2>&1 || true
        fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# What the setup and the init container leave for Nginx: the DH parameters
# (setup.sh), and the KVS rewrites, written to the nginx-includes volume by
# the init. -dsaparam makes them in a moment; Nginx only loads them.
openssl dhparam -dsaparam -out "$TEST_DIR/dhparam.pem" 2048 >/dev/null 2>&1 ||
    fail "openssl could not write DH parameters"
mkdir -p "$TEST_DIR/includes"
: > "$TEST_DIR/includes/kvs-rewrites.conf"
# The image installs both scripts executable.
install -m 0755 "$ROOT_DIR/docker/nginx/docker-entrypoint.sh" "$TEST_DIR/custom-entrypoint.sh"
install -m 0755 "$ROOT_DIR/docker/nginx/rotate-site-logs.sh" "$TEST_DIR/rotate-site-logs"
chmod 0755 "$TEST_DIR"

# The .env Compose reads for the probes; only DOMAIN reaches them.
sed -e "s/^DOMAIN=.*/DOMAIN=${DOMAIN}/" \
    -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=root-password/' \
    -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=kvs-password/' \
    "$ROOT_DIR/docker/.env.example" > "$TEST_DIR/env"
mkdir -p "$TEST_DIR/site"
cp "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template" "$TEST_DIR/site/docker-compose.yml"

# probe_of <layout>: the health check test of the nginx service, as Compose
# renders it for the layout, one argument per line. "CMD" is dropped: Docker
# runs the rest as the command, like docker exec does.
probe_of() {
    local -a files

    case "$1" in
        single) files=(-f "$ROOT_DIR/docker/docker-compose.yml") ;;
        primary) files=(-f "$ROOT_DIR/docker/docker-compose.yml" -f "$ROOT_DIR/docker/docker-compose.multi.yml") ;;
        site) files=(-f "$TEST_DIR/site/docker-compose.yml") ;;
    esac
    docker compose --env-file "$TEST_DIR/env" "${files[@]}" config --format json |
        jq -er '.services.nginx.healthcheck.test | if .[0] == "CMD" then .[1:][] else error("not a CMD test") end'
}

# start_layout <layout> <container>: the nginx container of the layout, with
# the mounts and the environment its Compose file gives it. php-fpm resolves
# to the loopback, where nothing listens.
start_layout() {
    local layout="$1" container="$2"
    local -a args=(
        -d --name "$container" --pull never --network none
        --add-host php-fpm:127.0.0.1
        --entrypoint /custom-entrypoint.sh
        -e "DOMAIN=$DOMAIN" -e USE_WWW=false -e PROJECT_HTTPS_PORT=443
        -v "$TEST_DIR/custom-entrypoint.sh:/custom-entrypoint.sh:ro"
        -v "$TEST_DIR/rotate-site-logs:/usr/local/bin/rotate-site-logs:ro"
        -v "$ROOT_DIR/docker/nginx/nginx.conf:/etc/nginx/nginx.conf:ro"
        -v "$ROOT_DIR/conf/nginx/globals:/etc/nginx/globals:ro"
        -v "$TEST_DIR/includes:/etc/nginx/includes:ro"
    )

    case "$layout" in
        single)
            args+=(
                -v "$ROOT_DIR/conf/nginx/templates:/etc/nginx/templates:ro"
                -v "$TEST_DIR/dhparam.pem:/etc/nginx/dhparam.pem:ro"
            )
            ;;
        primary)
            args+=(
                -e SSL_PROVIDER=none
                -v "$ROOT_DIR/conf/nginx/templates:/etc/nginx/templates:ro"
                -v "$ROOT_DIR/docker/multi-site/nginx/kvs-caddy.conf.template:/etc/nginx/templates/kvs.conf.tpl:ro"
                -v "$TEST_DIR/dhparam.pem:/etc/nginx/dhparam.pem:ro"
            )
            ;;
        site)
            # No DH parameters in this layout; the official entrypoint of the
            # image renders the *.template file itself.
            args+=(
                -e SSL_PROVIDER=none
                -v "$ROOT_DIR/docker/multi-site/nginx/kvs-caddy.conf.template:/etc/nginx/templates/kvs.conf.template:ro"
            )
            ;;
    esac
    containers+=("$container")
    docker run "${args[@]}" "$IMAGE" nginx -g 'daemon off;' >/dev/null ||
        fail "$layout: the nginx container did not start"
}

# wait_for_nginx <container>: until port 80 accepts a connection. curl
# exits 7 while nothing listens; any other status means Nginx answered.
wait_for_nginx() {
    local container="$1" attempt status

    for ((attempt = 0; attempt < 60; attempt++)); do
        [ "$(docker inspect --format '{{.State.Running}}' "$container")" = true ] ||
            fail "$container stopped before Nginx answered"
        status=0
        docker exec "$container" curl -s -o /dev/null --max-time 2 http://127.0.0.1/ || status=$?
        [ "$status" -eq 7 ] || return 0
        sleep 0.5
    done
    fail "$container: Nginx did not listen on port 80 within 30 seconds"
}

# http_status <container> <path> [curl arguments]
http_status() {
    local container="$1" path="$2"
    shift 2
    docker exec "$container" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "http://127.0.0.1$path" || true
}

check_layout() {
    local layout="$1" expected="$2" container status
    local -a probe without_host=()

    mapfile -t probe < <(probe_of "$layout")
    [ "${#probe[@]}" -gt 0 ] || fail "$layout: no health check test for nginx"
    container="${NAME_PREFIX}-${layout}"
    start_layout "$layout" "$container"
    wait_for_nginx "$container"

    docker exec "$container" "${probe[@]}" ||
        fail "$layout: the health check (${probe[*]}) failed against a working Nginx"
    status=$(http_status "$container" /health -H "Host: $DOMAIN")
    [ "$status" = "$expected" ] ||
        fail "$layout: /health answered $status, expected $expected"

    # The same probe without its Host header, and the probe it replaces, hit
    # the catch-all server and must fail.
    local skip=no argument
    for argument in "${probe[@]}"; do
        if [ "$skip" = yes ]; then
            skip=no
            continue
        fi
        if [ "$argument" = -H ]; then
            skip=yes
            continue
        fi
        without_host+=("$argument")
    done
    [ "${#without_host[@]}" -lt "${#probe[@]}" ] || fail "$layout: the probe sends no Host header"
    if docker exec "$container" "${without_host[@]}" 2>/dev/null; then
        fail "$layout: the probe passed without its Host header, so it cannot tell the site from the catch-all"
    fi
    status=0
    docker exec "$container" "${OLD_PROBE[@]}" 2>/dev/null || status=$?
    [ "$status" -ne 0 ] || fail "$layout: the probe without a Host header passed against the catch-all server"

    echo "PASS: $layout: the health check passes (/health answers $expected) and the probe without a Host header fails (curl status $status)"
}

check_layout single 301
check_layout primary 200
check_layout site 200

# PHP-FPM was unreachable all along: a PHP request fails on the layouts that
# hand it to PHP-FPM, while their health check passed.
for layout in primary site; do
    status=$(http_status "${NAME_PREFIX}-$layout" /index.php -H "Host: $DOMAIN")
    [ "$status" = 502 ] || fail "$layout: a PHP request answered $status without PHP-FPM, expected 502"
done
echo "PASS: the health checks do not need PHP-FPM"
