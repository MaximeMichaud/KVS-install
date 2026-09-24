#!/bin/bash
# shellcheck disable=SC2034,SC2329
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker Compose is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
extract_function() {
    local function_name="$1"
    local destination="$2"

    awk -v signature="${function_name}() {" '
    $0 == signature { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' "$ROOT_DIR/docker/setup.sh" >> "$destination"
}

mode_function="$TEST_DIR/configure-mode.sh"
: > "$mode_function"
extract_function add_compose_profile "$mode_function"
extract_function remove_compose_profile "$mode_function"
extract_function require_multi_compose_version "$mode_function"
extract_function set_compose_file "$mode_function"
extract_function select_mode "$mode_function"
extract_function configure_direct_tls_profile "$mode_function"
extract_function configure_mode "$mode_function"

set_env_value() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

remove_env_value() {
    sed -i "/^$1=/d" .env
}

version_at_least() {
    [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

docker() {
    if [ -n "${MOCK_DOCKER_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
    fi
    if [ "${1:-}" = compose ] && [ "${2:-}" = version ]; then
        echo "Docker Compose version v${MOCK_COMPOSE_VERSION:-2.35.0}"
        return 0
    fi
    if [ "${1:-}" = ps ]; then
        if [ "${MOCK_CADDY_RUNNING:-false}" = true ]; then
            echo 'kvs-caddy'
        fi
        if [ "${MOCK_ACME_PRESENT:-false}" = true ] && [ "${2:-}" = -a ]; then
            echo 'kvs-primary-acme'
        fi
        return 0
    fi
    if [ "${1:-}" = stop ]; then
        return 0
    fi
    if [ "${1:-}" = rm ]; then
        MOCK_ACME_PRESENT=false
        return 0
    fi
    return 64
}

RED=''
GREEN=''
YELLOW=''
CYAN=''
NC=''
MAX_SITE_PREFIX_LENGTH=235
# shellcheck source=/dev/null
source "$mode_function"

mode_work="$TEST_DIR/mode"
mkdir -p "$mode_work"
(
    cd "$mode_work"
    cat > .env <<'EOF'
MODE=single
DOMAIN=primary.example.com
SITE_PREFIX=kvs-primary
SSL_PROVIDER=letsencrypt
COMPOSE_PROFILES=dragonfly
EOF
    cat > docker-compose.override.yml <<'EOF'
services:
  nginx:
    ports:
      - "80:80"
      - "443:443"
EOF
    mkdir -p multi-site
    cat > multi-site/site-manager.sh <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_PRIMARY_REMOVE_LOG"
exit "${MOCK_PRIMARY_REMOVE_STATUS:-0}"
EOF
    chmod 0755 multi-site/site-manager.sh
    export MOCK_PRIMARY_REMOVE_LOG="$mode_work/primary-remove.log"
    export MOCK_PRIMARY_REMOVE_STATUS=0
    MOCK_DOCKER_LOG="$mode_work/docker.log"
    DOMAIN=primary.example.com
    SITE_PREFIX=kvs-primary
    SSL_PROVIDER=letsencrypt
    COMPOSE_PROFILES=dragonfly
    MODE=single
    MODE_CHOICE=2
    configure_mode >/dev/null
    [ "$MODE" = multi ] || fail "MODE_CHOICE=2 did not select multi mode"
    [ "$PROGRESS_TOTAL" = 12 ] || fail "multi mode retained the single-site progress total"
    grep -Fxq 'MODE=multi' .env || fail "multi mode was not persisted"
    grep -Fxq 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.multi.yml' .env ||
        fail "the multi-site hardening override was not persisted last"
    grep -Fxq 'COMPOSE_PROFILES=dragonfly' .env ||
        fail "multi mode retained the direct TLS profile"

    MOCK_CADDY_RUNNING=true
    MODE=multi
    MODE_CHOICE=1
    set +e
    configure_mode >/dev/null 2>&1
    transition_status=$?
    set -e
    [ "$transition_status" -ne 0 ] || fail "multi-to-single transition ignored a running Caddy proxy"
    grep -Fxq 'MODE=multi' .env || fail "a rejected mode transition modified .env"

    MOCK_CADDY_RUNNING=false
    MOCK_PRIMARY_REMOVE_STATUS=23
    export MOCK_PRIMARY_REMOVE_STATUS
    set +e
    configure_mode >/dev/null 2>&1
    cleanup_status=$?
    set -e
    [ "$cleanup_status" -ne 0 ] ||
        fail "multi-to-single transition ignored a failed primary route cleanup"
    grep -Fxq 'MODE=multi' .env || fail "a failed primary cleanup changed MODE"
    grep -Fxq 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.multi.yml' .env ||
        fail "a failed primary cleanup removed the multi-site Compose override"

    MOCK_PRIMARY_REMOVE_STATUS=0
    export MOCK_PRIMARY_REMOVE_STATUS
    configure_mode >/dev/null
    [ "$MODE" = single ] || fail "MODE_CHOICE=1 did not restore single mode"
    [ "$PROGRESS_TOTAL" = 11 ] || fail "single mode retained the multi-site progress total"
    if grep -q '^COMPOSE_FILE=' .env; then
        fail "single mode retained the multi-site Compose override"
    fi
    [ -f docker-compose.override.yml ] || fail "single mode deleted the user Compose override"
    grep -Fxq 'primary-remove primary.example.com kvs-primary' "$MOCK_PRIMARY_REMOVE_LOG" ||
        fail "multi-to-single did not remove the exact primary route reservation"
    [ "$(grep -Fxc 'primary-remove primary.example.com kvs-primary' "$MOCK_PRIMARY_REMOVE_LOG")" -eq 2 ] ||
        fail "the primary route cleanup was not attempted exactly once per eligible transition"
    grep -Fxq 'COMPOSE_PROFILES=dragonfly,direct-tls' .env ||
        fail "single-site Let's Encrypt did not enable direct TLS"

    configure_mode >/dev/null
    [ "$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tr ',' '\n' | grep -c '^direct-tls$')" -eq 1 ] ||
        fail "repeated direct TLS configuration duplicated the profile"
    SSL_PROVIDER=selfsigned
    MOCK_ACME_PRESENT=true
    configure_direct_tls_profile
    configure_direct_tls_profile
    grep -Fxq 'COMPOSE_PROFILES=dragonfly' .env ||
        fail "self-signed TLS did not remove only the direct TLS profile"
    [ "$(grep -Fxc 'stop kvs-primary-acme' "$mode_work/docker.log")" -ge 1 ] ||
        fail "disabling direct TLS did not stop the stale ACME container"
    [ "$(grep -Fxc 'rm kvs-primary-acme' "$mode_work/docker.log")" -ge 1 ] ||
        fail "disabling direct TLS did not remove the stale ACME container"
    SSL_PROVIDER=zerossl
    MODE=single
    configure_direct_tls_profile
    configure_direct_tls_profile
    [ "$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tr ',' '\n' | grep -c '^direct-tls$')" -eq 1 ] ||
        fail "repeated ZeroSSL configuration duplicated the direct TLS profile"
    MODE=multi
    configure_direct_tls_profile
    configure_direct_tls_profile
    grep -Fxq 'COMPOSE_PROFILES=dragonfly' .env ||
        fail "multi mode retained a stale direct TLS profile"

    printf '%s\n' 'MODE=multi' > .env
    MODE=multi
    unset MODE_CHOICE
    HEADLESS=y
    MOCK_COMPOSE_VERSION=2.23.3
    set +e
    configure_mode >/dev/null 2>&1
    old_compose_status=$?
    set -e
    [ "$old_compose_status" -ne 0 ] || fail "persisted multi mode accepted an unsupported Compose version"
    MOCK_COMPOSE_VERSION=2.35.0
    configure_mode >/dev/null
    [ "$MODE" = multi ] || fail "headless re-run changed a persisted multi mode"
    [ "$PROGRESS_TOTAL" = 12 ] || fail "headless multi re-run used the wrong progress total"
)

# kvsctl pins the images of the installed release in
# docker-compose.release.yml and records the file in COMPOSE_FILE. Re-running
# the setup rebuilds that key, and dropping the entry would silently rebuild
# every service from the Dockerfiles under an installed release.
release_pins_work="$TEST_DIR/release-pins"
mkdir -p "$release_pins_work"
(
    cd "$release_pins_work"
    cat > .env <<'EOF'
MODE=single
DOMAIN=pinned.example.com
SITE_PREFIX=kvs-pinned
SSL_PROVIDER=letsencrypt
COMPOSE_PROFILES=dragonfly
COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml
EOF
    : > docker-compose.release.yml
    mkdir -p multi-site
    cat > multi-site/site-manager.sh <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 0755 multi-site/site-manager.sh
    DOMAIN=pinned.example.com
    SITE_PREFIX=kvs-pinned
    SSL_PROVIDER=letsencrypt
    COMPOSE_PROFILES=dragonfly
    MODE=single
    MODE_CHOICE=1
    configure_mode > kept.log
    grep -Fxq 'COMPOSE_FILE=docker-compose.yml:docker-compose.release.yml' .env ||
        fail "single mode deleted the kvsctl release image pins"
    grep -Fq 'Kept the kvsctl release image pins' kept.log ||
        fail "single mode did not report that the release pins were kept"

    cat > docker-compose.override.yml <<'EOF'
services:
  nginx:
    environment:
      - EXAMPLE=1
EOF
    MODE_CHOICE=1
    configure_mode >/dev/null
    grep -Fxq 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.release.yml' .env ||
        fail "the user Compose override was not kept ahead of the release pins"

    MODE_CHOICE=2
    configure_mode >/dev/null
    grep -Fxq 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.release.yml:docker-compose.multi.yml' .env ||
        fail "multi mode did not keep the release pins ahead of the multi-site hardening"

    MODE_CHOICE=1
    configure_mode >/dev/null
    grep -Fxq 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.release.yml' .env ||
        fail "the multi-to-single transition lost the release pins"

    rm -f docker-compose.release.yml
    MODE_CHOICE=1
    configure_mode > removed.log
    if grep -q '^COMPOSE_FILE=' .env; then
        fail "single mode kept a COMPOSE_FILE pointing at a missing release override"
    fi
    if grep -Fq 'Kept the kvsctl release image pins' removed.log; then
        fail "single mode reported release pins it did not keep"
    fi

    : > docker-compose.release.yml
    MODE_CHOICE=1
    configure_mode >/dev/null
    if grep -q '^COMPOSE_FILE=' .env; then
        fail "single mode adopted a release override that COMPOSE_FILE never named"
    fi
)
unset -f docker

domain_validation_source="$TEST_DIR/domain-validation.sh"
: > "$domain_validation_source"
extract_function validate_domain "$domain_validation_source"
# shellcheck source=/dev/null
source "$domain_validation_source"
printf -v oversized_label '%*s' 64 ''
oversized_label=${oversized_label// /a}
if validate_domain "${oversized_label}.com"; then
    fail "setup accepted a DNS label longer than 63 characters"
fi
printf -v mariadb_oversized_label '%*s' 61 ''
mariadb_oversized_label=${mariadb_oversized_label// /a}
if validate_domain "${mariadb_oversized_label}.com"; then
    fail "setup accepted a domain longer than MariaDB identifiers support"
fi
printf -v supported_label '%*s' 63 ''
printf -v oversized_domain_tail '%*s' 48 ''
supported_label=${supported_label// /a}
oversized_domain_tail=${oversized_domain_tail// /b}
if validate_domain "${supported_label}.${supported_label}.${supported_label}.${oversized_domain_tail}"; then
    fail "setup accepted an oversized domain"
fi
grep -Fq "DOMAIN=\${DOMAIN,,}" "$ROOT_DIR/docker/setup.sh" ||
    fail "setup no longer canonicalizes domains before multi-site routing"

prefix_source="$TEST_DIR/site-prefix.sh"
: > "$prefix_source"
extract_function validate_site_prefix "$prefix_source"
# shellcheck source=/dev/null
source "$prefix_source"
printf -v long_domain_label '%*s' 60 ''
long_domain_label=${long_domain_label// /a}
long_prefix_domain="${long_domain_label}.com"
validate_domain "$long_prefix_domain" || fail "setup rejected its maximum supported domain length"
printf -v prefix_fill '%*s' $((235 - 4)) ''
prefix_fill=${prefix_fill// /a}
generated_prefix="kvs-${prefix_fill}"
letsencrypt_volume_suffix='letsencrypt-webroot'
[ "${#generated_prefix}" -eq 235 ] || fail "the maximum supported site prefix length changed"
[ $((${#generated_prefix} + 1 + ${#letsencrypt_volume_suffix})) -le 255 ] ||
    fail "a generated primary volume name exceeds the filesystem component limit"
validate_site_prefix "$generated_prefix" || fail "the maximum safe site prefix is invalid"

port_function_source="$TEST_DIR/public-ports.sh"
: > "$port_function_source"
extract_function parse_publish_endpoint "$port_function_source"
extract_function publish_endpoint_is_listening "$port_function_source"
extract_function container_publishes_host_port "$port_function_source"
extract_function caddy_publishes_required_multi_site_ports "$port_function_source"
extract_function resolve_public_port_configuration "$port_function_source"
# shellcheck source=/dev/null
source "$port_function_source"

PUBLISH_HOST=''
PUBLISH_PORT=''
parse_publish_endpoint 80 || fail "plain public port was rejected"
[ -z "$PUBLISH_HOST" ] && [ "$PUBLISH_PORT" = 80 ] ||
    fail "plain public port was parsed incorrectly"
parse_publish_endpoint 127.0.0.4:8080 || fail "IPv4 public endpoint was rejected"
[ "$PUBLISH_HOST" = 127.0.0.4 ] && [ "$PUBLISH_PORT" = 8080 ] ||
    fail "IPv4 public endpoint was parsed incorrectly"
parse_publish_endpoint '[::1]:8443' || fail "IPv6 public endpoint was rejected"
[ "$PUBLISH_HOST" = ::1 ] && [ "$PUBLISH_PORT" = 8443 ] ||
    fail "IPv6 public endpoint was parsed incorrectly"
for invalid_endpoint in 0 65536 text 127.0.0.999:80 '::1:443' '[::1]'; do
    if parse_publish_endpoint "$invalid_endpoint"; then
        fail "invalid public endpoint was accepted: $invalid_endpoint"
    fi
done

ss() {
    printf '%s' "${MOCK_SS_OUTPUT:-}"
}
MOCK_SS_OUTPUT=$'LISTEN 0 4096 127.0.0.2:80 0.0.0.0:*\nLISTEN 0 4096 127.0.0.3:80 0.0.0.0:*\n'
if publish_endpoint_is_listening 127.0.0.4:80 tcp; then
    fail "an endpoint-specific check treated another loopback address as occupied"
fi
publish_endpoint_is_listening 127.0.0.2:80 tcp ||
    fail "an endpoint-specific check missed its exact listener"
MOCK_SS_OUTPUT=$'LISTEN 0 4096 0.0.0.0:80 0.0.0.0:*\n'
publish_endpoint_is_listening 127.0.0.4:80 tcp ||
    fail "an endpoint-specific check missed a wildcard listener"
unset -f ss

docker() {
    if [ "${1:-}" = ps ]; then
        printf '%s\n' kvs-caddy
        return 0
    fi
    if [ "${1:-}" = port ]; then
        case "${3:-}" in
            80/tcp) printf '127.0.0.4:%s\n' "${MOCK_CADDY_HTTP_PORT:-80}" ;;
            443/tcp) printf '127.0.0.4:%s\n' "${MOCK_CADDY_HTTPS_PORT:-443}" ;;
            443/udp)
                [ "${MOCK_CADDY_UDP_PRESENT:-true}" = true ] &&
                    printf '127.0.0.4:%s\n' "${MOCK_CADDY_HTTPS_PORT:-443}"
                ;;
        esac
        return 0
    fi
    return 64
}
caddy_publishes_required_multi_site_ports ||
    fail "a running Caddy with exact host ports 80/443 was not recognized"
MOCK_CADDY_HTTP_PORT=18080
if caddy_publishes_required_multi_site_ports; then
    fail "a high-port Caddy instance was mistaken for the required port 80 owner"
fi
MOCK_CADDY_HTTP_PORT=80
MOCK_CADDY_UDP_PRESENT=false
if caddy_publishes_required_multi_site_ports; then
    fail "Caddy without the required HTTP/3 mapping was accepted"
fi
unset MOCK_CADDY_HTTP_PORT MOCK_CADDY_UDP_PRESENT
unset -f docker

MODE=single
HTTP_PORT=127.0.0.4:18080
HTTPS_PORT='[::1]:18443'
resolve_public_port_configuration >/dev/null || fail "single-site custom endpoints were rejected"
[ "$PUBLIC_HTTP_ENDPOINT" = 127.0.0.4:18080 ] && [ "$PUBLIC_HTTP_PORT" = 18080 ] &&
    [ "$PUBLIC_HTTPS_ENDPOINT" = '[::1]:18443' ] && [ "$PUBLIC_HTTPS_PORT" = 18443 ] ||
    fail "single-site public endpoints were not resolved correctly"
MODE=multi
resolve_public_port_configuration >/dev/null || fail "multi-site public endpoints were rejected"
[ "$PUBLIC_HTTP_ENDPOINT" = 80 ] && [ "$PUBLIC_HTTPS_ENDPOINT" = 443 ] ||
    fail "multi-site mode did not retain Caddy's fixed public ports"

# shellcheck disable=SC2016
grep -Fq 'ufw allow "${PUBLIC_HTTP_PORT}/tcp"' "$ROOT_DIR/docker/setup.sh" ||
    fail "UFW does not use the configured HTTP port"
# shellcheck disable=SC2016
grep -Fq 'ufw allow "${PUBLIC_HTTPS_PORT}/tcp"' "$ROOT_DIR/docker/setup.sh" ||
    fail "UFW does not use the configured HTTPS port"

env_file="$TEST_DIR/multi.env"
sed \
    -e 's/^DOMAIN=.*/DOMAIN=first.example.com/' \
    -e 's/^SITE_PREFIX=.*/SITE_PREFIX=kvs-first/' \
    -e 's/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=kvs-first/' \
    "$ROOT_DIR/docker/.env.example" > "$env_file"

single_json="$TEST_DIR/single.json"
single_direct_tls_json="$TEST_DIR/single-direct-tls.json"
single_persisted_direct_tls_env="$TEST_DIR/single-persisted-direct-tls.env"
single_persisted_direct_tls_json="$TEST_DIR/single-persisted-direct-tls.json"
multi_json="$TEST_DIR/multi.json"
multi_profile_json="$TEST_DIR/multi-profile.json"
override_json="$TEST_DIR/multi-with-user-override.json"
caddy_json="$TEST_DIR/caddy.json"
custom_ports_env="$TEST_DIR/custom-ports.env"
custom_ports_json="$TEST_DIR/custom-ports.json"
long_prefix_env="$TEST_DIR/long-prefix.env"
long_prefix_json="$TEST_DIR/long-prefix.json"
stale_public_port_env="$TEST_DIR/stale-public-port.env"
stale_public_port_single_json="$TEST_DIR/stale-public-port-single.json"
stale_public_port_multi_json="$TEST_DIR/stale-public-port-multi.json"
docker compose --env-file "$env_file" \
    -f "$ROOT_DIR/docker/docker-compose.yml" config --format json > "$single_json"
docker compose --env-file "$env_file" --profile direct-tls \
    -f "$ROOT_DIR/docker/docker-compose.yml" config --format json > "$single_direct_tls_json"
sed 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=dragonfly,direct-tls/' \
    "$env_file" > "$single_persisted_direct_tls_env"
docker compose --env-file "$single_persisted_direct_tls_env" \
    -f "$ROOT_DIR/docker/docker-compose.yml" \
    config --format json > "$single_persisted_direct_tls_json"
docker compose --env-file "$env_file" \
    -f "$ROOT_DIR/docker/docker-compose.yml" \
    -f "$ROOT_DIR/docker/docker-compose.multi.yml" \
    config --format json > "$multi_json"
docker compose --env-file "$env_file" --profile manticore \
    -f "$ROOT_DIR/docker/docker-compose.yml" \
    -f "$ROOT_DIR/docker/docker-compose.multi.yml" \
    config --format json > "$multi_profile_json"
cat > "$TEST_DIR/user-override.yml" <<'EOF'
services:
  nginx:
    ports:
      - "80:80"
      - "443:443"
EOF
docker compose --env-file "$env_file" \
    -f "$ROOT_DIR/docker/docker-compose.yml" \
    -f "$TEST_DIR/user-override.yml" \
    -f "$ROOT_DIR/docker/docker-compose.multi.yml" \
    config --format json > "$override_json"
docker compose -p multi-site \
    -f "$ROOT_DIR/docker/multi-site/docker-compose.caddy.yml" \
    config --format json > "$caddy_json"
sed \
    -e 's/^MARIADB_HOST_PORT=.*/MARIADB_HOST_PORT=13306/' \
    -e 's/^CACHE_HOST_PORT=.*/CACHE_HOST_PORT=11212/' \
    -e 's/^MANTICORE_MYSQL_HOST_PORT=.*/MANTICORE_MYSQL_HOST_PORT=19306/' \
    -e 's/^MANTICORE_HTTP_HOST_PORT=.*/MANTICORE_HTTP_HOST_PORT=19308/' \
    "$env_file" > "$custom_ports_env"
docker compose --env-file "$custom_ports_env" --profile dragonfly --profile manticore \
    -f "$ROOT_DIR/docker/docker-compose.yml" config --format json > "$custom_ports_json"
sed \
    -e "s/^DOMAIN=.*/DOMAIN=${long_prefix_domain}/" \
    -e "s/^SITE_PREFIX=.*/SITE_PREFIX=${generated_prefix}/" \
    -e "s/^COMPOSE_PROJECT_NAME=.*/COMPOSE_PROJECT_NAME=${generated_prefix}/" \
    "$ROOT_DIR/docker/.env.example" > "$long_prefix_env"
docker compose --env-file "$long_prefix_env" \
    -f "$ROOT_DIR/docker/docker-compose.yml" config --format json > "$long_prefix_json"
sed 's/^PROJECT_HTTPS_PORT=.*/PROJECT_HTTPS_PORT=18445/' \
    "$env_file" > "$stale_public_port_env"
docker compose --env-file "$stale_public_port_env" --profile setup \
    -f "$ROOT_DIR/docker/docker-compose.yml" \
    config --format json > "$stale_public_port_single_json"
docker compose --env-file "$stale_public_port_env" --profile setup \
    -f "$ROOT_DIR/docker/docker-compose.yml" \
    -f "$ROOT_DIR/docker/docker-compose.multi.yml" \
    config --format json > "$stale_public_port_multi_json"
jq -e '.volumes["letsencrypt-webroot"].name | length == 255' \
    "$long_prefix_json" >/dev/null || fail "the maximum generated volume name is not filesystem-safe"
jq -e '[.volumes[].name | length] | max <= 255' "$long_prefix_json" >/dev/null ||
    fail "a generated Compose volume name exceeds 255 bytes"

jq -e '.name == "kvs-first"' "$single_json" >/dev/null ||
    fail "single mode changed the primary Compose project"
jq -e '.name == "kvs-first"' "$multi_json" >/dev/null ||
    fail "multi mode changed the primary Compose project"
jq -e '[.services.nginx.ports[] | {target, published, protocol}] | sort_by(.target, .protocol) == [
    {"target": 80, "published": "80", "protocol": "tcp"},
    {"target": 443, "published": "443", "protocol": "tcp"}
]' "$single_json" >/dev/null || fail "single mode changed the exact Nginx port mapping"
jq -e '.services.mariadb.ports == [{"mode":"ingress","target":3306,"published":"3306","protocol":"tcp","host_ip":"127.0.0.1"}]' \
    "$single_json" >/dev/null || fail "default MariaDB localhost port mapping changed"
jq -e '.services.dragonfly.ports == [{"mode":"ingress","target":11211,"published":"11211","protocol":"tcp","host_ip":"127.0.0.1"}]' \
    "$single_json" >/dev/null || fail "default cache localhost port mapping changed"
jq -e '.services.mariadb.ports == [{"mode":"ingress","target":3306,"published":"13306","protocol":"tcp","host_ip":"127.0.0.1"}] and
    .services.dragonfly.ports == [{"mode":"ingress","target":11211,"published":"11212","protocol":"tcp","host_ip":"127.0.0.1"}] and
    ([.services.manticore.ports[] | {target, published, protocol, host_ip}] | sort_by(.target)) == [
        {"target":9306,"published":"19306","protocol":"tcp","host_ip":"127.0.0.1"},
        {"target":9308,"published":"19308","protocol":"tcp","host_ip":"127.0.0.1"}
    ]' "$custom_ports_json" >/dev/null || fail "custom localhost service ports were not rendered exactly"
jq -e '.services.nginx.ports == null' "$multi_json" >/dev/null ||
    fail "multi mode still publishes Nginx ports"
jq -e '.services.nginx.ports == null' "$override_json" >/dev/null ||
    fail "a user override reintroduced Nginx ports after multi hardening"
jq -e '.services.nginx.environment.SSL_PROVIDER == "none"' "$multi_json" >/dev/null ||
    fail "multi mode did not disable direct Nginx TLS"
jq -e '.services.nginx.networks["kvs-proxy"].aliases | index("n.first.example.com")' \
    "$multi_json" >/dev/null || fail "primary Nginx is missing its Caddy alias"
jq -e '.services.nginx.volumes[] | select(.target == "/etc/nginx/templates/kvs.conf.tpl") | .source | endswith("/docker/multi-site/nginx/kvs-caddy.conf.template")' \
    "$multi_json" >/dev/null || fail "multi mode did not replace the Nginx site template"
jq -e '.services.nginx.depends_on.acme == null' "$multi_json" >/dev/null ||
    fail "multi Nginx still starts the direct ACME service"
jq -e '.services.acme == null' "$single_json" >/dev/null ||
    fail "self-signed/default Compose starts the direct ACME daemon"
jq -e '.services.acme != null' "$single_direct_tls_json" >/dev/null ||
    fail "the direct-tls profile lost its ACME service"
jq -e '.services.acme != null' "$single_persisted_direct_tls_json" >/dev/null ||
    fail "a persisted direct-tls profile did not activate the ACME service"
jq -e '[.services.acme.volumes[]? | select(.source == "/var/run/docker.sock")] | length == 0' \
    "$single_direct_tls_json" >/dev/null ||
    fail "the direct ACME service retains access to the Docker socket"
jq -e '.services.acme == null' "$multi_json" >/dev/null ||
    fail "direct ACME is active in multi mode"
jq -e '.services.nginx.environment.PROJECT_HTTPS_PORT == "18445" and
    .services["kvs-init"].environment.PROJECT_HTTPS_PORT == "18445"' \
    "$stale_public_port_single_json" >/dev/null ||
    fail "single mode lost its configured public HTTPS port"
jq -e '.services.nginx.environment.PROJECT_HTTPS_PORT == "443" and
    .services["kvs-init"].environment.PROJECT_HTTPS_PORT == "443"' \
    "$stale_public_port_multi_json" >/dev/null ||
    fail "multi mode did not force the Caddy-facing HTTPS port to 443"

volume_keys='["mariadb-data", "phpmyadmin-data", "nginx-includes", "nginx-logs", "acme-certs", "letsencrypt-webroot"]'
single_volumes=$(jq -S --argjson keys "$volume_keys" '[.volumes as $volumes | $keys[] | $volumes[.].name]' "$single_json")
multi_volumes=$(jq -S --argjson keys "$volume_keys" '[.volumes as $volumes | $keys[] | $volumes[.].name]' "$multi_json")
[ "$single_volumes" = "$multi_volumes" ] ||
    fail "multi mode changed the primary site's volume names"
jq -e '.volumes["manticore-data"].name == "kvs-first_manticore-data"' \
    "$multi_profile_json" >/dev/null || fail "multi mode changed the Manticore data volume"
jq -e '[.services.nginx, .services["php-fpm"], .services.cron] |
    all(.[]; any(.volumes[]; .target == "/var/www/kvs" and
        .source == "/var/www/first.example.com"))' \
    "$multi_json" >/dev/null || fail "multi mode changed a primary KVS webroot mount"
jq -e '.services.mariadb.volumes[] | select(.target == "/var/lib/mysql") |
    .source == "mariadb-data"' "$multi_json" >/dev/null ||
    fail "multi mode changed the MariaDB data mount"
jq -e '.networks["kvs-network"].name == "kvs-first_kvs-network" and
    .networks["kvs-proxy"].external == true and
    .networks["kvs-proxy"].name == "kvs-proxy"' "$multi_json" >/dev/null ||
    fail "multi mode rendered the wrong primary networks"

jq -e '.name == "multi-site"' "$caddy_json" >/dev/null ||
    fail "Caddy does not preserve its historical Compose project name"
jq -e '.volumes["caddy-data"].name == "multi-site_caddy-data" and
    .volumes["caddy-config"].name == "multi-site_caddy-config"' \
    "$caddy_json" >/dev/null || fail "Caddy abandoned its historical certificate volumes"
jq -e '[.services.caddy.ports[] | {target, published, protocol}] | sort_by(.target, .protocol) == [
    {"target": 80, "published": "80", "protocol": "tcp"},
    {"target": 443, "published": "443", "protocol": "tcp"},
    {"target": 443, "published": "443", "protocol": "udp"}
]' "$caddy_json" >/dev/null || fail "Caddy is not the exact public 80/443 owner"
jq -e '.networks["kvs-proxy"].external == true' "$caddy_json" >/dev/null ||
    fail "Caddy does not use the shared external network"
jq -e '.services.caddy.environment.CADDY_ADMIN == null' "$caddy_json" >/dev/null ||
    fail "Caddy exposes an admin listen override to the shared proxy network"
grep -Fq 'admin localhost:2019' "$ROOT_DIR/docker/multi-site/caddy/Caddyfile" ||
    fail "Caddy's admin API is not limited to the container loopback"

fixture="$TEST_DIR/proxy"
mkdir -p "$fixture/caddy/sites"
cp "$ROOT_DIR/docker/multi-site/site-manager.sh" "$fixture/site-manager.sh"
cp "$ROOT_DIR/docker/multi-site/caddy/Caddyfile" "$fixture/caddy/Caddyfile"
bash "$fixture/site-manager.sh" primary-config first.example.com kvs-first internal true >/dev/null
grep -Fq 'redir https://www.first.example.com{uri} permanent' \
    "$fixture/caddy/sites/first.example.com.caddy" ||
    fail "the primary USE_WWW choice did not generate a canonical redirect"
caddy_image=$(jq -r '.services.caddy.image' "$caddy_json")
docker run --rm --entrypoint caddy \
    -v "$fixture/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
    -v "$fixture/caddy/sites:/etc/caddy/sites:ro" \
    "$caddy_image" validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 ||
    fail "the generated primary Caddy route is invalid"

grep -Fq 'ufw allow 443/udp' "$ROOT_DIR/docker/setup.sh" ||
    fail "multi-site HTTP/3 is published without its firewall rule"
[ "$(grep -Fc 'fastcgi_param HTTPS on;' "$ROOT_DIR/docker/multi-site/nginx/kvs-caddy.conf.template")" = 2 ] ||
    fail "multi-site PHP requests are not marked as HTTPS"
grep -Fq "fastcgi_param REMOTE_ADDR \$http_x_real_ip;" \
    "$ROOT_DIR/docker/multi-site/nginx/kvs-caddy.conf.template" ||
    fail "multi-site PHP requests do not receive the forwarded client address"
grep -Fq 'Multi-site mode does not support selecting ZeroSSL explicitly' \
    "$ROOT_DIR/docker/setup.sh" ||
    fail "multi-site mode can silently ignore an explicit ZeroSSL choice"
[ "$(grep -Fc 'docker compose --profile setup run --rm --no-deps phpmyadmin-init' \
    "$ROOT_DIR/docker/setup.sh")" -eq 1 ] ||
    fail "setup does not run phpMyAdmin initialization as a checked one-shot"
[ "$(grep -Fc 'docker compose --profile setup run --rm --no-deps kvs-init' \
    "$ROOT_DIR/docker/setup.sh")" -eq 1 ] ||
    fail "setup does not run KVS initialization as a checked one-shot"
[ "$(grep -Fc 'docker compose --profile setup run --rm --no-deps phpmyadmin-init' \
    "$ROOT_DIR/docker/multi-site/site-manager.sh")" -eq 1 ] ||
    fail "site-manager does not run phpMyAdmin initialization as a checked one-shot"
[ "$(grep -Fc 'docker compose --profile setup run --rm --no-deps kvs-init' \
    "$ROOT_DIR/docker/multi-site/site-manager.sh")" -eq 1 ] ||
    fail "site-manager does not run KVS initialization as a checked one-shot"
if grep -Fq '/var/run/docker.sock' "$ROOT_DIR/docker/docker-compose.yml"; then
    fail "the direct ACME service still mounts the Docker socket"
fi
if grep -Fq 'run_step "Starting Caddy reverse proxy" start_multi_site_proxy' \
    "$ROOT_DIR/docker/setup.sh"; then
    fail "the Caddy step still passes a shell function through run_step"
fi

run_step_source="$TEST_DIR/run-step.sh"
: > "$run_step_source"
extract_function run_step "$run_step_source"
# shellcheck source=/dev/null
source "$run_step_source"
DEBUG_LOG="$TEST_DIR/run-step-debug.log"
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/gum" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
[ "${1:-}" = -- ] && shift
exec "$@"
EOF
cat > "$TEST_DIR/caddy-runner" <<EOF
#!/bin/sh
printf '%s %s\n' "\$ACME_EMAIL" "\$1" > "$TEST_DIR/caddy-run-step-result"
EOF
chmod +x "$TEST_DIR/bin/gum" "$TEST_DIR/caddy-runner"
PATH="$TEST_DIR/bin:$PATH" run_step "Starting Caddy reverse proxy" \
    env ACME_EMAIL=ops@example.com "$TEST_DIR/caddy-runner" caddy-start >/dev/null
grep -Fxq 'ops@example.com caddy-start' "$TEST_DIR/caddy-run-step-result" ||
    fail "run_step did not execute the Caddy command with Gum present"

echo "PASS: Primary multi-site setup hardening"
