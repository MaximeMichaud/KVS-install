#!/bin/bash
# Real-Nginx proof that PHP reaches the site's own URL from inside the
# site's Docker network. KVS fetches its own URLs server side, the storage
# server checks among them, at the address get_project_url
# (docker/init/lib/common.sh) writes into project_url and the storage
# URLs. Each layout renders its configuration through the real
# docker/nginx/docker-entrypoint.sh, in the nginx base docker/images.lock
# pins, with the aliases, extra hosts and environment Compose renders for
# it, and a PHP client fetches the URL the init computes:
#
#   single      HTTPS published on 8443, with and without USE_WWW: the
#               URL is https://DOMAIN:8443 (or www.DOMAIN), an alias of
#               nginx on kvs-network, and the host maps 8443 to port 443 of
#               the container. Nginx must answer that port inside the
#               network too, the redirect of the other name included, and
#               refuse an unknown SNI there as on 443.
#   8080        HTTPS published on 8080, the plain HTTP port of
#               manticore-api in the container: that port cannot take TLS
#               too, so it stays plain HTTP and the entrypoint warns.
#   primary     the primary site of a multi-site installation: Caddy
#               terminates TLS on the host's port 443 and this Nginx has no
#               TLS listener, so the site's names are no alias of it, and
#               PHP-FPM and cron, which are not on Caddy's network, map them
#               to host-gateway. A Caddy stand-in (an Nginx that terminates
#               TLS and passes the request to the primary Nginx on port 80,
#               as Caddy does) runs on a network of its own and publishes
#               its port 443 on the gateway address only, on a port Docker
#               picks; the client connects to that port for the project URL
#               (cURL's CONNECT_TO), the name resolved through its hosts
#               file, and gets the site through Docker's forwarding.
#   additional  an additional multi-site site: its PHP-FPM and cron map
#               the site's names to host-gateway the same way.
#
# The single-site containers run on an internal network. Docker forwards a
# published port only for a network that is not internal, so the
# multi-site ones run on two such networks, created for the suite; the
# Caddy stand-in publishes on the gateway address alone, and nothing is
# fetched from any other host: the suite checks that the names come from
# the hosts file before it resolves them. Everything it creates is removed
# with it. The suite never pulls an image: tests/run-integration.sh pulls
# the pinned ones first. NGINX_TEST_IMAGE and PHP_TEST_IMAGE name other
# images to run instead.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR
readonly SITE=example.test
readonly SENTINEL=internal-site-url-sentinel

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v openssl >/dev/null 2>&1 || fail "openssl is required for the DH parameters"

NGINX_IMAGE=${NGINX_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get nginx)}
PHP_IMAGE=${PHP_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-cli 8.1)}
readonly NGINX_IMAGE PHP_IMAGE
for image in "$NGINX_IMAGE" "$PHP_IMAGE"; do
    docker image inspect "$image" >/dev/null 2>&1 ||
        fail "$image is not present; tests/run-integration.sh pulls it first"
done

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvsctltest-internal-site-url.XXXXXX")
readonly TEST_DIR
readonly NAME_PREFIX="kvsctltest-internal-site-url-$$-$RANDOM"
containers=()
networks=()

cleanup() {
    local status=$? container network

    for container in "${containers[@]}"; do
        if [ "$status" -ne 0 ]; then
            echo "--- logs of $container" >&2
            docker logs "$container" >&2 2>&1 || true
        fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    done
    for network in "${networks[@]}"; do
        docker network rm "$network" >/dev/null 2>&1 || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# What the setup and the init container leave for Nginx: the DH parameters
# and the KVS rewrites. -dsaparam makes them in a moment; Nginx only loads
# them.
openssl dhparam -dsaparam -out "$TEST_DIR/dhparam.pem" 2048 >/dev/null 2>&1 ||
    fail "openssl could not write DH parameters"
mkdir -p "$TEST_DIR/includes" "$TEST_DIR/webroot"
: > "$TEST_DIR/includes/kvs-rewrites.conf"
printf '%s\n' "$SENTINEL" > "$TEST_DIR/webroot/probe.txt"
install -m 0755 "$ROOT_DIR/docker/nginx/docker-entrypoint.sh" "$TEST_DIR/custom-entrypoint.sh"
install -m 0755 "$ROOT_DIR/docker/nginx/rotate-site-logs.sh" "$TEST_DIR/rotate-site-logs"
# The client fetches the URL the way KVS does, with PHP's cURL. The
# certificate is the self-signed one of the entrypoint: what PHP trusts is
# integration_internal_tls.py's subject, this suite checks where the URL
# leads.
cat > "$TEST_DIR/fetch.php" <<'PHP'
<?php
$c = curl_init($argv[1]);
curl_setopt_array($c, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 5,
    CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_SSL_VERIFYPEER => false,
    CURLOPT_SSL_VERIFYHOST => 0, CURLOPT_PROXY => '', CURLOPT_HEADER => true]);
if (isset($argv[2]) && $argv[2] !== '') {
    curl_setopt($c, CURLOPT_RESOLVE, [$argv[2]]);
}
if (isset($argv[3])) {
    curl_setopt($c, CURLOPT_CONNECT_TO, [$argv[3]]);
}
$response = curl_exec($c);
$headers = $response === false ? '' : substr($response, 0, curl_getinfo($c, CURLINFO_HEADER_SIZE));
preg_match('/^Location: *(\S+)/mi', $headers, $location);
echo json_encode(['errno' => curl_errno($c), 'http' => curl_getinfo($c, CURLINFO_HTTP_CODE),
    'body' => $response === false ? '' : trim(substr($response, strlen($headers))),
    'location' => $location[1] ?? '']), "\n";
PHP
chmod 0755 "$TEST_DIR"
chmod -R a+rX "$TEST_DIR"

# env_for <layout> <https port> <use www>: the .env of the layout, with
# HTTPS published on the port as setup.sh records it (PROJECT_HTTPS_PORT
# follows HTTPS_PORT; multi mode forces 443 in its override).
env_for() {
    sed -e "s/^DOMAIN=.*/DOMAIN=${SITE}/" \
        -e "s/^HTTPS_PORT=.*/HTTPS_PORT=$2/" \
        -e "s/^PROJECT_HTTPS_PORT=.*/PROJECT_HTTPS_PORT=$2/" \
        -e "s/^USE_WWW=.*/USE_WWW=$3/" \
        -e 's/^SSL_PROVIDER=.*/SSL_PROVIDER=selfsigned/' \
        -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=root-password/' \
        -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=kvs-password/' \
        "$ROOT_DIR/docker/.env.example" > "$TEST_DIR/$1.env"
}

# render <layout> <compose file...>: the Compose configuration of the
# layout, as JSON, with the setup profile that runs kvs-init.
render() {
    local layout="$1" file
    local -a files=()

    shift
    for file in "$@"; do
        files+=(-f "$ROOT_DIR/docker/$file")
    done
    docker compose --env-file "$TEST_DIR/$layout.env" --profile setup "${files[@]}" \
        config --format json > "$TEST_DIR/$layout.json" ||
        fail "$layout: docker compose config failed"
}

# setting <layout> <service> <key>: one environment value Compose gives the
# service in the layout.
setting() {
    jq -er --arg service "$2" --arg key "$3" '.services[$service].environment[$key]' "$TEST_DIR/$1.json" ||
        fail "$1: Compose gives $2 no $3"
}

# project_url <layout>: the URL the init writes into project_url and the
# storage URLs, from get_project_url and the environment of kvs-init.
project_url() {
    DOMAIN=$(setting "$1" kvs-init DOMAIN) \
        USE_WWW=$(setting "$1" kvs-init USE_WWW) \
        PROJECT_HTTPS_PORT=$(setting "$1" kvs-init PROJECT_HTTPS_PORT) \
        bash -c 'source "$1" && get_project_url' _ "$ROOT_DIR/docker/init/lib/common.sh"
}

# start_layout <layout> <template>: an internal network for the layout, its
# nginx on it with the aliases Compose gives nginx on kvs-network and the
# site template the layout mounts, and a PHP client. php-fpm resolves to
# the loopback, where nothing listens. Sets nginx_ip.
start_layout() {
    local layout="$1" template="$2" network="${NAME_PREFIX}-$1" alias
    local -a args aliases

    mapfile -t aliases < <(jq -r '.services.nginx.networks["kvs-network"].aliases // [] | .[]' "$TEST_DIR/$layout.json")
    docker network create --internal "$network" >/dev/null || fail "$layout: cannot create the test network"
    networks+=("$network")
    args=(
        -d --name "$network-nginx" --pull never --network "$network"
        --add-host php-fpm:127.0.0.1
        --entrypoint /custom-entrypoint.sh
        -e "DOMAIN=$(setting "$layout" nginx DOMAIN)"
        -e "USE_WWW=$(setting "$layout" nginx USE_WWW)"
        -e "MODE=$(setting "$layout" nginx MODE)"
        -e "SSL_PROVIDER=$(setting "$layout" nginx SSL_PROVIDER)"
        -e "PROJECT_HTTPS_PORT=$(setting "$layout" nginx PROJECT_HTTPS_PORT)"
        -v "$TEST_DIR/custom-entrypoint.sh:/custom-entrypoint.sh:ro"
        -v "$TEST_DIR/rotate-site-logs:/usr/local/bin/rotate-site-logs:ro"
        -v "$TEST_DIR/webroot:/var/www/kvs:ro"
        -v "$ROOT_DIR/docker/nginx/nginx.conf:/etc/nginx/nginx.conf:ro"
        -v "$ROOT_DIR/conf/nginx/globals:/etc/nginx/globals:ro"
        -v "$ROOT_DIR/conf/nginx/templates:/etc/nginx/templates:ro"
        -v "$ROOT_DIR/$template:/etc/nginx/templates/kvs.conf.tpl:ro"
        -v "$TEST_DIR/includes:/etc/nginx/includes:ro"
        -v "$TEST_DIR/dhparam.pem:/etc/nginx/dhparam.pem:ro"
    )
    for alias in "${aliases[@]}"; do
        args+=(--network-alias "$alias")
    done
    containers+=("$network-nginx")
    docker run "${args[@]}" "$NGINX_IMAGE" nginx -g 'daemon off;' >/dev/null ||
        fail "$layout: the nginx container did not start"
    wait_for_nginx "$network-nginx"
    containers+=("$network-client")
    docker run -d --name "$network-client" --pull never --network "$network" \
        -v "$TEST_DIR/fetch.php:/fetch.php:ro" "$PHP_IMAGE" sleep infinity >/dev/null ||
        fail "$layout: the PHP client container did not start"
    nginx_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$network-nginx")
    [ -n "$nginx_ip" ] || fail "$layout: no address for the nginx container"
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

# client <layout> <command...>: runs in the PHP container on the layout's
# network.
client() {
    docker exec "${NAME_PREFIX}-$1-client" "${@:2}"
}

# fetch <layout> <url> [<host:port:address>]: what PHP's cURL got for the
# URL, as JSON; the third argument pins the address of the URL's host.
fetch() {
    client "$1" php /fetch.php "${@:2}"
}

# expect_site <layout> <url> <what>: the URL serves the site's probe file.
expect_site() {
    local result

    result=$(fetch "$1" "$2/probe.txt")
    jq -e --arg body "$SENTINEL" '.errno == 0 and .http == 200 and .body == $body' <<<"$result" >/dev/null ||
        fail "$1: $3 ($2) does not serve the site from inside the network: $result"
}

# expect_redirect <layout> <from> <to>: a 301 from one URL to the other.
expect_redirect() {
    local result

    result=$(fetch "$1" "$2/probe.txt")
    jq -e --arg location "$3/probe.txt" '.errno == 0 and .http == 301 and .location == $location' <<<"$result" >/dev/null ||
        fail "$1: $2 does not redirect to $3 inside the network: $result"
}

# expect_unknown_sni_refused <layout> <port>: an unknown SNI on the port is
# refused during the handshake, the catch-all server holding no certificate.
expect_unknown_sni_refused() {
    local result

    result=$(fetch "$1" "https://unrelated.test:$2/probe.txt" "unrelated.test:$2:$nginx_ip")
    jq -e '.errno == 35 and .http == 0' <<<"$result" >/dev/null ||
        fail "$1: an unknown SNI on port $2 was not refused in the handshake: $result"
}

# --- single site, HTTPS published on 8443 ---
for www in false true; do
    layout=single-www-$www
    env_for "$layout" 8443 "$www"
    render "$layout" docker-compose.yml
    canonical=$SITE other=www.$SITE
    if [ "$www" = true ]; then canonical=www.$SITE other=$SITE; fi
    url=$(project_url "$layout") || fail "$layout: get_project_url failed"
    [ "$url" = "https://$canonical:8443" ] || fail "$layout: the project URL is $url, expected https://$canonical:8443"
    start_layout "$layout" conf/nginx/templates/kvs.conf.tpl
    expect_site "$layout" "$url" "the project URL"
    # The other name redirects to the project URL on the same port.
    expect_redirect "$layout" "https://$other:8443" "$url"
    # The internal TLS proof of reconfigure.sh names no port: 443 stays.
    expect_site "$layout" "https://$canonical" "port 443"
    expect_unknown_sni_refused "$layout" 443
    expect_unknown_sni_refused "$layout" 8443
    echo "PASS: $layout: PHP fetches $url from inside the network, https://$other:8443 redirects to it, 443 still serves the site, an unknown SNI is refused on both ports"
done

# --- single site, HTTPS published on 8080 ---
# 8080 is the plain HTTP port of manticore-api in this container: Nginx
# turns every listener of a port into TLS when one of them asks for it, so
# no TLS listener goes there, and the entrypoint says why.
layout=single-8080
env_for "$layout" 8080 false
render "$layout" docker-compose.yml
start_layout "$layout" conf/nginx/templates/kvs.conf.tpl
status=$(docker exec "${NAME_PREFIX}-$layout-nginx" curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -H 'Host: manticore-api' http://127.0.0.1:8080/ || true)
[ "$status" = 404 ] || fail "$layout: manticore-api answered $status over plain HTTP on 8080, expected 404"
expect_site "$layout" "https://$SITE" "port 443"
logs=$(docker logs "${NAME_PREFIX}-$layout-nginx" 2>&1) || fail "$layout: cannot read the nginx logs"
grep -Fq "WARNING: PROJECT_HTTPS_PORT=8080 is a plain HTTP port of this container" <<<"$logs" ||
    fail "$layout: the entrypoint did not warn that 8080 cannot take TLS"
echo "PASS: $layout: manticore-api keeps plain HTTP on 8080, 443 still serves the site, the entrypoint warns"

# --- multi-site: the primary site and an additional one ---
# gateway_hosts <json> <service>: the extra hosts Compose gives the service,
# one "name address" line each, sorted.
gateway_hosts() {
    jq -r --arg service "$2" '.services[$service].extra_hosts // [] | .[]' "$1" |
        sed -E 's/^([^=:]+)[=:]/\1 /' | sort
}

# expect_gateway_hosts <json> <domain> <what>: PHP-FPM and cron map the
# site's names, and nothing else, to host-gateway. The suite resolves these
# names only once this holds: without the mapping they would go to the DNS
# of the host.
expect_gateway_hosts() {
    local service expected

    expected=$(printf '%s host-gateway\n' "$2" "www.$2" | sort)
    for service in php-fpm cron; do
        [ "$(gateway_hosts "$1" "$service")" = "$expected" ] ||
            fail "$3: $service does not map the site's names to host-gateway: $(gateway_hosts "$1" "$service" | paste -sd ',')"
    done
}

layout=primary
env_for "$layout" 443 false
render "$layout" docker-compose.yml docker-compose.multi.yml
url=$(project_url "$layout") || fail "$layout: get_project_url failed"
[ "$url" = "https://$SITE" ] || fail "$layout: the project URL is $url, expected https://$SITE"
mapfile -t aliases < <(jq -r '.services.nginx.networks["kvs-network"].aliases // [] | .[]' "$TEST_DIR/$layout.json")
[ "${aliases[*]}" = manticore-api ] ||
    fail "$layout: the primary Nginx has the aliases ${aliases[*]} on kvs-network; only manticore-api, the site's names must lead to Caddy"
expect_gateway_hosts "$TEST_DIR/$layout.json" "$SITE" "$layout"

# The template of an additional site, rendered as site-manager.sh lays it.
second=second.test
mkdir -p "$TEST_DIR/sites/$second"
cp "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template" "$TEST_DIR/sites/$second/docker-compose.yml"
printf 'DOMAIN=%s\nSITE_PREFIX=kvs-second\nMARIADB_ROOT_PASSWORD=root-password\nMARIADB_PASSWORD=kvs-password\n' \
    "$second" > "$TEST_DIR/sites/$second/.env"
(cd "$TEST_DIR/sites/$second" && docker compose config --format json) > "$TEST_DIR/additional.json" ||
    fail "additional: docker compose config failed"
expect_gateway_hosts "$TEST_DIR/additional.json" "$second" additional

# The address host-gateway stands for, as Docker writes it in a container.
probe_name="${NAME_PREFIX}-gateway"
containers+=("$probe_name")
gateway=$(docker run --rm --name "$probe_name" --pull never --network none \
    --add-host "gateway.test:host-gateway" --entrypoint awk "$PHP_IMAGE" \
    '$2 == "gateway.test" && $1 ~ /^[0-9.]+$/ { print $1; exit }' /etc/hosts) ||
    fail "Docker cannot resolve host-gateway"
[[ "$gateway" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail "host-gateway is no IPv4 address: '$gateway'"

site_network="${NAME_PREFIX}-$layout"
proxy_network="${NAME_PREFIX}-proxy"
for network in "$site_network" "$proxy_network"; do
    docker network create "$network" >/dev/null || fail "$layout: cannot create the network $network"
    networks+=("$network")
done

# The primary Nginx, with the aliases Compose gives it on kvs-network and,
# on the proxy network, the n.DOMAIN alias Caddy addresses it by.
args=(
    -d --name "$site_network-nginx" --pull never --network "$site_network"
    --add-host php-fpm:127.0.0.1
    --entrypoint /custom-entrypoint.sh
    -e "DOMAIN=$(setting "$layout" nginx DOMAIN)"
    -e "USE_WWW=$(setting "$layout" nginx USE_WWW)"
    -e "MODE=$(setting "$layout" nginx MODE)"
    -e "SSL_PROVIDER=$(setting "$layout" nginx SSL_PROVIDER)"
    -e "PROJECT_HTTPS_PORT=$(setting "$layout" nginx PROJECT_HTTPS_PORT)"
    -v "$TEST_DIR/custom-entrypoint.sh:/custom-entrypoint.sh:ro"
    -v "$TEST_DIR/rotate-site-logs:/usr/local/bin/rotate-site-logs:ro"
    -v "$TEST_DIR/webroot:/var/www/kvs:ro"
    -v "$ROOT_DIR/docker/nginx/nginx.conf:/etc/nginx/nginx.conf:ro"
    -v "$ROOT_DIR/conf/nginx/globals:/etc/nginx/globals:ro"
    -v "$ROOT_DIR/docker/multi-site/nginx/kvs-caddy.conf.template:/etc/nginx/templates/kvs.conf.tpl:ro"
    -v "$TEST_DIR/includes:/etc/nginx/includes:ro"
    -v "$TEST_DIR/dhparam.pem:/etc/nginx/dhparam.pem:ro"
)
for alias in "${aliases[@]}"; do
    args+=(--network-alias "$alias")
done
containers+=("$site_network-nginx")
docker run "${args[@]}" "$NGINX_IMAGE" nginx -g 'daemon off;' >/dev/null ||
    fail "$layout: the nginx container did not start"
mapfile -t proxy_aliases < <(jq -r '.services.nginx.networks["kvs-proxy"].aliases // [] | .[]' "$TEST_DIR/$layout.json")
args=()
for alias in "${proxy_aliases[@]}"; do
    args+=(--alias "$alias")
done
docker network connect "${args[@]}" "$proxy_network" "$site_network-nginx" ||
    fail "$layout: cannot connect the primary Nginx to the proxy network"
wait_for_nginx "$site_network-nginx"
nginx_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$site_network\").IPAddress}}" "$site_network-nginx")
upstream_ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"$proxy_network\").IPAddress}}" "$site_network-nginx")
[ -n "$nginx_ip" ] && [ -n "$upstream_ip" ] || fail "$layout: no address for the primary Nginx"

# The Caddy stand-in: TLS for the site's names, the request passed to the
# primary Nginx by address, as Caddy passes it to n.DOMAIN:80.
mkdir -p "$TEST_DIR/stand-in"
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -subj "/CN=$SITE" \
    -addext "subjectAltName=DNS:$SITE,DNS:www.$SITE,DNS:$second,DNS:www.$second" \
    -keyout "$TEST_DIR/stand-in/key.pem" -out "$TEST_DIR/stand-in/cert.pem" >/dev/null 2>&1 ||
    fail "openssl could not write the certificate of the Caddy stand-in"
cat > "$TEST_DIR/stand-in/default.conf" <<NGINX
server {
    listen 443 ssl;
    server_name $SITE www.$SITE;
    ssl_certificate /stand-in/cert.pem;
    ssl_certificate_key /stand-in/key.pem;
    location / {
        proxy_pass http://$upstream_ip:80;
        proxy_set_header Host \$host;
    }
}
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /stand-in/cert.pem;
    ssl_certificate_key /stand-in/key.pem;
    return 200 "stand-in:\$host";
}
NGINX
chmod -R a+rX "$TEST_DIR/stand-in"
containers+=("$proxy_network-caddy")
docker run -d --name "$proxy_network-caddy" --pull never --network "$proxy_network" \
    -p "$gateway::443" \
    -v "$TEST_DIR/stand-in:/stand-in:ro" \
    -v "$TEST_DIR/stand-in/default.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$NGINX_IMAGE" >/dev/null || fail "$layout: the Caddy stand-in did not start"
published=$(docker port "$proxy_network-caddy" 443/tcp | awk -F: -v gateway="$gateway" '$1 == gateway { print $2; exit }')
[[ "$published" =~ ^[0-9]+$ ]] || fail "$layout: the Caddy stand-in is not published on $gateway: $(docker port "$proxy_network-caddy" 443/tcp)"
# Until it accepts TLS connections: curl exits 7 while nothing listens.
for ((attempt = 0; attempt < 60; attempt++)); do
    [ "$(docker inspect --format '{{.State.Running}}' "$proxy_network-caddy")" = true ] ||
        fail "$layout: the Caddy stand-in stopped"
    status=0
    docker exec "$proxy_network-caddy" curl -sk -o /dev/null --max-time 2 https://127.0.0.1/ || status=$?
    [ "$status" -eq 7 ] || break
    sleep 0.5
done

# start_client <name> <json> <network>: a PHP client with the extra hosts
# Compose gives php-fpm in the layout.
start_client() {
    local name="$1" host address
    local -a hosts=()

    while read -r host address; do
        hosts+=(--add-host "$host:$address")
    done < <(gateway_hosts "$2" php-fpm)
    containers+=("$name")
    docker run -d --name "$name" --pull never --network "$3" "${hosts[@]}" \
        -v "$TEST_DIR/fetch.php:/fetch.php:ro" "$PHP_IMAGE" sleep infinity >/dev/null ||
        fail "the PHP client $name did not start"
}

start_client "$site_network-client" "$TEST_DIR/$layout.json" "$site_network"
for name in "$SITE" "www.$SITE"; do
    resolved=$(client "$layout" getent ahosts "$name" | awk '{ print $1 }' | sort -u | paste -sd ' ')
    [ "$resolved" = "$gateway" ] ||
        fail "$layout: $name resolves to '$resolved' inside the site network, not to the gateway $gateway"
done
resolved=$(client "$layout" getent ahosts manticore-api | awk '{ print $1 }' | sort -u || true)
grep -qxF "$nginx_ip" <<<"$resolved" || fail "$layout: manticore-api no longer resolves to the primary Nginx"
result=$(fetch "$layout" "$url/probe.txt" '' "$SITE:443::$published")
jq -e --arg body "$SENTINEL" '.errno == 0 and .http == 200 and .body == $body' <<<"$result" >/dev/null ||
    fail "$layout: PHP did not get the site at $url through the host and the Caddy stand-in: $result"
echo "PASS: $layout: the site's names lead PHP to the host, where Docker forwards to Caddy, which serves the site at $url; manticore-api still leads to the primary Nginx"

# The additional site: its own network, its names mapped the same way, the
# same Caddy stand-in answering for them.
additional_network="${NAME_PREFIX}-additional"
docker network create "$additional_network" >/dev/null || fail "additional: cannot create the network"
networks+=("$additional_network")
start_client "$additional_network-client" "$TEST_DIR/additional.json" "$additional_network"
for name in "$second" "www.$second"; do
    resolved=$(client additional getent ahosts "$name" | awk '{ print $1 }' | sort -u | paste -sd ' ')
    [ "$resolved" = "$gateway" ] ||
        fail "additional: $name resolves to '$resolved', not to the gateway $gateway"
done
result=$(fetch additional "https://$second/" '' "$second:443::$published")
jq -e --arg body "stand-in:$second" '.errno == 0 and .http == 200 and .body == $body' <<<"$result" >/dev/null ||
    fail "additional: PHP did not reach the Caddy stand-in at https://$second through the host: $result"
echo "PASS: additional: the site's names lead PHP to the host, where Docker forwards to Caddy"

echo "All internal site URL checks passed"
