#!/bin/bash
# KVS Docker Reconfiguration Script
# Applies .env changes without full reinstall

set -e
set -o pipefail

# Keep help and option validation available from anywhere, before any check
# that assumes an installed stack.
while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            cat << 'EOF'
KVS Docker Reconfiguration Script

USAGE:
    ./reconfigure.sh [OPTIONS]

DESCRIPTION:
    Applies the settings currently stored in .env to a running
    installation, without reinstalling it. It synchronizes the TLS
    services, rewrites the KVS server URLs when USE_WWW or the public
    HTTPS port changed, recreates Nginx with the updated environment,
    and verifies the persisted state afterwards.

    Switching MODE between single and multi is not handled here,
    because it requires the orchestration performed by setup.sh.

OPTIONS:
    --help      Show this help message

REQUIREMENTS:
    Run it from the docker directory of the installation. The .env file
    must exist and the stack must already be running.
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Must run from docker directory
if [ ! -f "docker-compose.yml" ]; then
    echo -e "${RED}ERROR: Run from docker directory${NC}"
    exit 1
fi

# Must have .env
if [ ! -f ".env" ]; then
    echo -e "${RED}ERROR: .env not found${NC}"
    exit 1
fi

# Load environment
# shellcheck source=/dev/null
source .env
DOMAIN="${DOMAIN:-}"

set_env_value() {
    local key="$1"
    local value="$2"
    local env_owner
    local temp_file
    local temp_owner

    if ! env_owner=$(stat -c '%u:%g' .env) ||
        ! temp_file=$(mktemp ./.env.tmp.XXXXXX); then
        return 1
    fi
    if ! sed "/^${key}=/d" .env > "$temp_file" ||
        ! printf '%s=%s\n' "$key" "$value" >> "$temp_file" ||
        ! chmod 600 "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    if ! temp_owner=$(stat -c '%u:%g' "$temp_file"); then
        rm -f -- "$temp_file"
        return 1
    fi
    if [ "$temp_owner" != "$env_owner" ] &&
        ! chown "$env_owner" "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    if [ "$(grep -Fxc "${key}=${value}" "$temp_file")" -ne 1 ] ||
        ! mv -f -- "$temp_file" .env; then
        rm -f -- "$temp_file"
        return 1
    fi
    [ "$(grep -Fxc "${key}=${value}" .env)" -eq 1 ]
}

add_compose_profile() {
    local profile="$1"
    local profiles
    local filtered=""
    local item
    local -a profile_items

    if ! profiles=$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tail -n 1); then
        return 1
    fi
    IFS=',' read -r -a profile_items <<< "$profiles"
    for item in "${profile_items[@]}"; do
        [ -n "$item" ] || continue
        [ "$item" = "$profile" ] && continue
        case ",${filtered}," in
            *",${item},"*) continue ;;
        esac
        if [ -n "$filtered" ]; then
            filtered="${filtered},${item}"
        else
            filtered="$item"
        fi
    done
    if [ -n "$filtered" ]; then
        filtered="${filtered},${profile}"
    else
        filtered="$profile"
    fi
    if ! set_env_value COMPOSE_PROFILES "$filtered"; then
        return 1
    fi
    COMPOSE_PROFILES="$filtered"
    export COMPOSE_PROFILES
}

remove_compose_profile() {
    local profile="$1"
    local profiles
    local filtered=""
    local item
    local -a profile_items

    if ! profiles=$(sed -n 's/^COMPOSE_PROFILES=//p' .env | tail -n 1); then
        return 1
    fi
    IFS=',' read -r -a profile_items <<< "$profiles"
    for item in "${profile_items[@]}"; do
        [ -n "$item" ] || continue
        [ "$item" = "$profile" ] && continue
        case ",${filtered}," in
            *",${item},"*) continue ;;
        esac
        if [ -n "$filtered" ]; then
            filtered="${filtered},${item}"
        else
            filtered="$item"
        fi
    done
    if ! set_env_value COMPOSE_PROFILES "$filtered"; then
        return 1
    fi
    COMPOSE_PROFILES="$filtered"
    export COMPOSE_PROFILES
}

validate_domain() {
    local domain="$1"
    local label
    local -a labels

    [ -n "$domain" ] && [ "${#domain}" -le 64 ] || return 1
    [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$ ]] ||
        return 1
    IFS='.' read -r -a labels <<< "$domain"
    for label in "${labels[@]}"; do
        [ "${#label}" -le 63 ] || return 1
    done
}

validate_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

parse_publish_endpoint_port() {
    local endpoint="$1"
    local host=""
    local port
    local octet
    local -a octets

    if [[ "$endpoint" =~ ^([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$endpoint" =~ ^\[([0-9A-Fa-f:.%]+)\]:([0-9]+)$ ]]; then
        port="${BASH_REMATCH[2]}"
    elif [[ "$endpoint" =~ ^(([0-9]{1,3}\.){3}[0-9]{1,3}):([0-9]+)$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[3]}"
        IFS='.' read -r -a octets <<< "$host"
        for octet in "${octets[@]}"; do
            [ "$((10#$octet))" -le 255 ] || return 1
        done
    else
        return 1
    fi
    [ "${#port}" -le 5 ] && ((10#$port >= 1 && 10#$port <= 65535)) ||
        return 1
    PARSED_PUBLISH_PORT=$((10#$port))
}

resolve_project_https_port() {
    local endpoint="${HTTPS_PORT:-443}"

    if [ "${MODE:-single}" = "multi" ]; then
        PROJECT_HTTPS_PORT=443
        return 0
    fi
    if ! parse_publish_endpoint_port "$endpoint"; then
        echo -e "${RED}ERROR: Invalid HTTPS_PORT endpoint: ${endpoint}${NC}"
        return 1
    fi
    PROJECT_HTTPS_PORT="$PARSED_PUBLISH_PORT"
}

resolve_public_http_port() {
    local endpoint="${HTTP_PORT:-80}"

    if [ "${MODE:-single}" = "multi" ]; then
        PUBLIC_HTTP_PORT=80
        return 0
    fi
    if ! parse_publish_endpoint_port "$endpoint"; then
        echo -e "${RED}ERROR: Invalid HTTP_PORT endpoint: ${endpoint}${NC}"
        return 1
    fi
    PUBLIC_HTTP_PORT="$PARSED_PUBLISH_PORT"
}

include_www_for_domain() {
    local dot_count

    [ "${USE_WWW:-false}" = "true" ] && return 0
    dot_count=$(printf '%s' "$DOMAIN" | tr -cd '.' | wc -c)
    [ "$dot_count" -eq 1 ]
}

# Validate required vars and refuse mode changes that require setup orchestration.
MODE="${MODE:-single}"
SSL_PROVIDER="${SSL_PROVIDER:-letsencrypt}"
USE_WWW="${USE_WWW:-false}"
SITE_PREFIX="${SITE_PREFIX:-kvs}"

if ! validate_domain "${DOMAIN:-}"; then
    echo -e "${RED}ERROR: DOMAIN is missing or invalid in .env${NC}"
    exit 1
fi
if [ -z "${MARIADB_PASSWORD:-}" ]; then
    echo -e "${RED}ERROR: MARIADB_PASSWORD not set in .env${NC}"
    exit 1
fi
if [[ ! "$SITE_PREFIX" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
    [ "${#SITE_PREFIX}" -gt 235 ]; then
    echo -e "${RED}ERROR: SITE_PREFIX is invalid in .env${NC}"
    exit 1
fi
case "$MODE" in
    single)
        if [[ ":${COMPOSE_FILE:-}:" == *":docker-compose.multi.yml:"* ]] ||
            [ -e multi-site/sites/.primary.env ] ||
            [ -L multi-site/sites/.primary.env ]; then
            echo -e "${RED}ERROR: Mode transitions must be performed with setup.sh${NC}"
            exit 1
        fi
        ;;
    multi)
        if [[ ":${COMPOSE_FILE:-}:" != *":docker-compose.multi.yml:"* ]]; then
            echo -e "${RED}ERROR: Multi-site mode requires docker-compose.multi.yml${NC}"
            echo "Run setup.sh to perform a mode transition safely."
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}ERROR: Invalid MODE in .env: ${MODE}${NC}"
        exit 1
        ;;
esac
case "$SSL_PROVIDER" in
    letsencrypt|zerossl|selfsigned) ;;
    *)
        echo -e "${RED}ERROR: Invalid SSL_PROVIDER in .env: ${SSL_PROVIDER}${NC}"
        exit 1
        ;;
esac
case "$USE_WWW" in
    true|false) ;;
    *)
        echo -e "${RED}ERROR: USE_WWW must be true or false${NC}"
        exit 1
        ;;
esac
if [ "$MODE" = "multi" ] && [ "$SSL_PROVIDER" = "zerossl" ]; then
    echo -e "${RED}ERROR: Multi-site mode does not support selecting ZeroSSL explicitly${NC}"
    exit 1
fi
if [ "$SSL_PROVIDER" != "selfsigned" ] && ! validate_email "${EMAIL:-}"; then
    echo -e "${RED}ERROR: A valid EMAIL is required for public certificates${NC}"
    exit 1
fi

resolve_project_https_port || exit $?
resolve_public_http_port || exit $?
if [ "$MODE" = "single" ] && [ "$SSL_PROVIDER" != "selfsigned" ] &&
    [ "$PUBLIC_HTTP_PORT" -ne 80 ]; then
    echo -e "${RED}ERROR: Direct ACME HTTP-01 validation requires host TCP port 80${NC}"
    exit 1
fi
export MODE SSL_PROVIDER USE_WWW SITE_PREFIX PROJECT_HTTPS_PORT
EXPECTED_SSL_SKIP=0
if [ "$SSL_PROVIDER" = "selfsigned" ]; then
    EXPECTED_SSL_SKIP=1
fi

echo -e "${CYAN}=== KVS Reconfiguration ===${NC}"
echo "Domain: $DOMAIN"
echo "SSL Provider: ${SSL_PROVIDER}"
echo ""

# Get container prefix
CONTAINER_PREFIX="${SITE_PREFIX:-kvs}"
PHP_CONTAINER="${CONTAINER_PREFIX}-php"
NGINX_CONTAINER="${CONTAINER_PREFIX}-nginx"
ACME_CONTAINER="${CONTAINER_PREFIX}-acme"
PENDING_MULTI_ROUTE=false
MULTI_DB_BEFORE=''
MULTI_DB_AFTER=''
MULTI_SETUP_BEFORE=''
MULTI_SETUP_AFTER=''
MULTI_PLUGIN_BEFORE=''
MULTI_PLUGIN_AFTER=''
MULTI_ROLLBACK_ARMED=false
MULTI_TRANSACTION_COMMITTED=false
CADDY_ROLLBACK_ARMED=false
CADDY_ROLLBACK_DIR=''
CADDY_ROUTE_FILE=''
CADDY_RESERVATION_FILE=''
CADDY_ROUTE_EXISTED=false
CADDY_RESERVATION_EXISTED=false

# Check containers are running
if ! RUNNING_CONTAINER_NAMES=$(docker ps --format '{{.Names}}' 2>/dev/null); then
    echo -e "${RED}ERROR: Could not inspect running containers${NC}"
    exit 1
fi
if ! grep -Fxq "$PHP_CONTAINER" <<< "$RUNNING_CONTAINER_NAMES"; then
    echo -e "${RED}ERROR: ${PHP_CONTAINER} not running${NC}"
    exit 1
fi
if [ "$MODE" = "multi" ]; then
    if ! grep -Fxq kvs-caddy <<< "$RUNNING_CONTAINER_NAMES"; then
        echo -e "${RED}ERROR: kvs-caddy must be running for multi-site reconfiguration${NC}"
        exit 1
    fi
    if ! docker exec kvs-caddy caddy validate --config /etc/caddy/Caddyfile \
        >/dev/null; then
        echo -e "${RED}ERROR: The current Caddy configuration is invalid${NC}"
        exit 1
    fi
    PENDING_MULTI_ROUTE=true
fi

# Run MariaDB queries through stdin so neither credentials nor large SQL
# payloads appear in process arguments.
run_mariadb_query() {
    local mode="$1"
    local query="$2"
    local -a client_args=(-h mariadb -u "$DOMAIN")

    if [ "$mode" = scalar ]; then
        client_args+=( -N -B )
    fi
    client_args+=( "$DOMAIN" )
    {
        printf '%s\n' "$MARIADB_PASSWORD"
        printf '%s\n' "$query"
    } | docker exec -i "$PHP_CONTAINER" sh -c '
        IFS= read -r MYSQL_PWD || exit 1
        export MYSQL_PWD
        exec mariadb "$@"
    ' sh "${client_args[@]}"
}

run_query() {
    run_mariadb_query normal "$1"
}

run_scalar_query() {
    run_mariadb_query scalar "$1"
}

capture_server_state() {
    run_scalar_query "SELECT CONCAT(
            server_id, '|',
            IF(urls IS NULL, 1, 0), '|',
            REPLACE(REPLACE(TO_BASE64(COALESCE(urls, '')), CHAR(10), ''), CHAR(13), ''), '|',
            IF(streaming_skip_ssl_check IS NULL, 1, 0), '|',
            COALESCE(CAST(streaming_skip_ssl_check AS CHAR), '')
        )
        FROM ktvs_admin_servers
        ORDER BY server_id;"
}

validate_server_state() {
    local snapshot="$1"
    local server_id
    local urls_null
    local urls_base64
    local skip_null
    local skip_value
    local extra
    local rows=0
    local -A seen_ids=()

    [ -n "$snapshot" ] || return 1
    while IFS='|' read -r server_id urls_null urls_base64 skip_null skip_value extra; do
        [[ "$server_id" =~ ^[0-9]+$ ]] || return 1
        [[ "$urls_null" =~ ^[01]$ ]] || return 1
        [[ "$urls_base64" =~ ^[A-Za-z0-9+/=]*$ ]] || return 1
        [[ "$skip_null" =~ ^[01]$ ]] || return 1
        [ -z "$extra" ] || return 1
        if [ "$urls_null" -eq 1 ] && [ -n "$urls_base64" ]; then
            return 1
        fi
        if [ "$skip_null" -eq 1 ]; then
            [ -z "$skip_value" ] || return 1
        else
            [[ "$skip_value" =~ ^-?[0-9]+$ ]] || return 1
        fi
        [ -z "${seen_ids[$server_id]:-}" ] || return 1
        seen_ids[$server_id]=1
        rows=$((rows + 1))
    done <<< "$snapshot"
    [ "$rows" -gt 0 ]
}

capture_php_file_state() {
    local path="$1"

    docker exec -e KVS_SNAPSHOT_PATH="$path" "$PHP_CONTAINER" php -r '
        $path = getenv("KVS_SNAPSHOT_PATH");
        if (!is_string($path) || $path === "" || is_link($path)) exit(2);
        if (!file_exists($path)) {
            echo "absent|||||", PHP_EOL;
            exit(0);
        }
        if (!is_file($path) || !is_readable($path)) exit(3);
        $contents = file_get_contents($path);
        $stat = stat($path);
        if (!is_string($contents) || !is_array($stat)) exit(4);
        printf(
            "file|%d|%d|%04o|%s|%s\n",
            $stat["uid"],
            $stat["gid"],
            $stat["mode"] & 07777,
            hash("sha256", $contents),
            base64_encode($contents)
        );
    '
}

update_php_file_guarded() {
    local path="$1"
    local update_kind="$2"
    local expected_snapshot="$3"

    printf '%s\n' "$expected_snapshot" |
        docker exec -i --user 1000:1000 \
            -e KVS_GUARDED_PATH="$path" \
            -e KVS_GUARDED_UPDATE="$update_kind" \
            -e PROJECT_URL="$SERVER_URL" \
            "$PHP_CONTAINER" php -r '
                function format_state(string $contents, array $stat, int $mode): string {
                    return sprintf(
                        "file|%d|%d|%04o|%s|%s",
                        $stat["uid"],
                        $stat["gid"],
                        $mode,
                        hash("sha256", $contents),
                        base64_encode($contents)
                    );
                }

                function snapshot(string $path): ?array {
                    clearstatcache(true, $path);
                    if (is_link($path)) return null;
                    if (!file_exists($path)) return ["absent|||||", null, null];
                    if (!is_file($path) || !is_readable($path)) return null;
                    $contents = file_get_contents($path);
                    $stat = stat($path);
                    if (!is_string($contents) || !is_array($stat)) return null;
                    $mode = $stat["mode"] & 07777;
                    return [format_state($contents, $stat, $mode), $contents, $stat];
                }

                $path = getenv("KVS_GUARDED_PATH");
                $kind = getenv("KVS_GUARDED_UPDATE");
                $projectUrl = getenv("PROJECT_URL");
                $expected = rtrim(stream_get_contents(STDIN), "\r\n");
                if (!is_string($path) || $path === "" ||
                    !is_string($kind) || !is_string($projectUrl) ||
                    !in_array($kind, ["setup", "plugin"], true)) exit(2);
                $before = snapshot($path);
                if (!is_array($before) || !hash_equals($expected, $before[0])) exit(3);
                if ($before[0] === "absent|||||") {
                    if ($kind !== "plugin") exit(4);
                    echo $before[0], PHP_EOL;
                    exit(0);
                }
                [, $contents, $stat] = $before;
                if (!is_string($contents) || !is_array($stat)) exit(5);

                if ($kind === "setup") {
                    $quote = chr(39);
                    $prefix = "\$config[" . $quote . "project_url" . $quote . "]=\"";
                    $offset = 0;
                    $replacements = 0;
                    while (($start = strpos($contents, $prefix, $offset)) !== false) {
                        $valueStart = $start + strlen($prefix);
                        $valueEnd = strpos($contents, "\"", $valueStart);
                        if ($valueEnd === false) exit(6);
                        $contents = substr($contents, 0, $valueStart) . $projectUrl .
                            substr($contents, $valueEnd);
                        $offset = $valueStart + strlen($projectUrl) + 1;
                        $replacements++;
                    }
                    if ($replacements < 1) exit(6);
                    $targetMode = $stat["mode"] & 07777;
                } else {
                    $data = @unserialize($contents, ["allowed_classes" => false]);
                    if (!is_array($data)) exit(7);
                    foreach (["outgoing_url", "outgoing_url_albums", "outgoing_url_searches"] as $key) {
                        $data[$key] = $projectUrl;
                    }
                    $contents = serialize($data);
                    $targetMode = 0600;
                }

                $targetState = format_state($contents, $stat, $targetMode);
                $temporary = tempnam(dirname($path), ".guarded.");
                if ($temporary === false) exit(8);
                $written = file_put_contents($temporary, $contents, LOCK_EX);
                $prepared = $written === strlen($contents) &&
                    @chown($temporary, (int) $stat["uid"]) &&
                    @chgrp($temporary, (int) $stat["gid"]) &&
                    chmod($temporary, $targetMode);
                $temporaryState = snapshot($temporary);
                if (!$prepared || !is_array($temporaryState) ||
                    !hash_equals($targetState, $temporaryState[0])) {
                    @unlink($temporary);
                    exit(9);
                }
                $current = snapshot($path);
                if (!is_array($current) || !hash_equals($expected, $current[0])) {
                    @unlink($temporary);
                    exit(10);
                }
                if (!rename($temporary, $path)) {
                    @unlink($temporary);
                    exit(11);
                }
                $after = snapshot($path);
                if (!is_array($after) || !hash_equals($targetState, $after[0])) exit(12);
                echo $targetState, PHP_EOL;
            '
}

validate_php_file_state() {
    local snapshot="$1"

    if [ "$snapshot" = 'absent|||||' ]; then
        return 0
    fi
    [[ "$snapshot" =~ ^file\|[0-9]+\|[0-9]+\|[0-7]{4}\|[0-9a-f]{64}\|[A-Za-z0-9+/=]+$ ]]
}

prepare_multi_application_snapshot() {
    if ! MULTI_DB_BEFORE=$(capture_server_state) ||
        ! validate_server_state "$MULTI_DB_BEFORE" ||
        ! MULTI_SETUP_BEFORE=$(capture_php_file_state \
            /var/www/kvs/admin/include/setup.php) ||
        ! validate_php_file_state "$MULTI_SETUP_BEFORE" ||
        [ "${MULTI_SETUP_BEFORE%%|*}" != file ] ||
        ! MULTI_PLUGIN_BEFORE=$(capture_php_file_state \
            /var/www/kvs/admin/data/plugins/external_search/data.dat) ||
        ! validate_php_file_state "$MULTI_PLUGIN_BEFORE"; then
        echo -e "${RED}ERROR: Could not snapshot the application state for Caddy rollback${NC}"
        return 1
    fi
}

capture_multi_application_result() {
    local current_db
    local current_setup
    local current_plugin

    if ! current_db=$(capture_server_state) ||
        ! validate_server_state "$current_db" ||
        ! current_setup=$(capture_php_file_state \
            /var/www/kvs/admin/include/setup.php) ||
        ! validate_php_file_state "$current_setup" ||
        [ "${current_setup%%|*}" != file ] ||
        ! current_plugin=$(capture_php_file_state \
            /var/www/kvs/admin/data/plugins/external_search/data.dat) ||
        ! validate_php_file_state "$current_plugin" ||
        [ "$current_db" != "$MULTI_DB_AFTER" ] ||
        [ "$current_setup" != "$MULTI_SETUP_AFTER" ] ||
        [ "$current_plugin" != "$MULTI_PLUGIN_AFTER" ]; then
        echo -e "${RED}ERROR: Could not capture the reconfigured application state${NC}"
        return 1
    fi
}

restore_php_file_state() {
    local path="$1"
    local expected_snapshot="$2"
    local target_snapshot="$3"

    printf '%s\n%s\n' "$expected_snapshot" "$target_snapshot" |
        docker exec -i -e KVS_ROLLBACK_PATH="$path" "$PHP_CONTAINER" php -r '
            function snapshot(string $path): string {
                if (is_link($path)) return "invalid";
                if (!file_exists($path)) return "absent|||||";
                if (!is_file($path) || !is_readable($path)) return "invalid";
                $contents = file_get_contents($path);
                $stat = stat($path);
                if (!is_string($contents) || !is_array($stat)) return "invalid";
                return sprintf(
                    "file|%d|%d|%04o|%s|%s",
                    $stat["uid"],
                    $stat["gid"],
                    $stat["mode"] & 07777,
                    hash("sha256", $contents),
                    base64_encode($contents)
                );
            }

            $path = getenv("KVS_ROLLBACK_PATH");
            $lines = file("php://stdin", FILE_IGNORE_NEW_LINES);
            if (!is_string($path) || $path === "" || !is_array($lines) || count($lines) !== 2) exit(2);
            [$expected, $target] = $lines;
            if (!hash_equals($expected, snapshot($path))) exit(3);
            if ($target === "absent|||||") {
                if ((file_exists($path) || is_link($path)) && !unlink($path)) exit(4);
                exit(snapshot($path) === $target ? 0 : 5);
            }
            $parts = explode("|", $target, 6);
            if (count($parts) !== 6 || $parts[0] !== "file") exit(6);
            [, $uid, $gid, $mode, $hash, $encoded] = $parts;
            if (!preg_match("/^[0-9]+$/D", $uid) ||
                !preg_match("/^[0-9]+$/D", $gid) ||
                !preg_match("/^[0-7]{4}$/D", $mode) ||
                !preg_match("/^[0-9a-f]{64}$/D", $hash)) exit(7);
            $contents = base64_decode($encoded, true);
            if (!is_string($contents) || !hash_equals($hash, hash("sha256", $contents))) exit(8);
            $temporary = tempnam(dirname($path), ".rollback.");
            if ($temporary === false) exit(9);
            $ok = file_put_contents($temporary, $contents, LOCK_EX) !== false &&
                chown($temporary, (int) $uid) &&
                chgrp($temporary, (int) $gid) &&
                chmod($temporary, octdec($mode)) &&
                rename($temporary, $path);
            if (!$ok) {
                @unlink($temporary);
                exit(10);
            }
            exit(hash_equals($target, snapshot($path)) ? 0 : 11);
        '
}

restore_server_state() {
    local target_snapshot="$1"
    local expected_snapshot="$2"
    local server_id
    local urls_null
    local urls_base64
    local skip_null
    local skip_value
    local extra
    local count=0
    local ids=''
    local url_cases=''
    local skip_cases=''
    local expected_conditions=''
    local url_expression
    local skip_expression
    local expected_urls_null
    local expected_urls_base64
    local expected_skip_null
    local expected_skip_value
    local expected_url_expression
    local expected_skip_expression
    local id_separator=''
    local condition_separator=''
    local sql
    local restored_snapshot
    local -A expected_rows=()

    validate_server_state "$target_snapshot" || return 1
    validate_server_state "$expected_snapshot" || return 1
    while IFS='|' read -r server_id urls_null urls_base64 skip_null skip_value extra; do
        expected_rows[$server_id]="${urls_null}|${urls_base64}|${skip_null}|${skip_value}"
    done <<< "$expected_snapshot"
    while IFS='|' read -r server_id urls_null urls_base64 skip_null skip_value extra; do
        [ -n "${expected_rows[$server_id]:-}" ] || return 1
        IFS='|' read -r expected_urls_null expected_urls_base64 \
            expected_skip_null expected_skip_value <<< "${expected_rows[$server_id]}"
        if [ "$urls_null" -eq 1 ]; then
            url_expression='NULL'
        else
            url_expression="FROM_BASE64('${urls_base64}')"
        fi
        if [ "$skip_null" -eq 1 ]; then
            skip_expression='NULL'
        else
            skip_expression="$skip_value"
        fi
        if [ "$expected_urls_null" -eq 1 ]; then
            expected_url_expression='NULL'
        else
            expected_url_expression="FROM_BASE64('${expected_urls_base64}')"
        fi
        if [ "$expected_skip_null" -eq 1 ]; then
            expected_skip_expression='NULL'
        else
            expected_skip_expression="$expected_skip_value"
        fi
        ids="${ids}${id_separator}${server_id}"
        url_cases="${url_cases} WHEN ${server_id} THEN ${url_expression}"
        skip_cases="${skip_cases} WHEN ${server_id} THEN ${skip_expression}"
        expected_conditions="${expected_conditions}${condition_separator}(server_id=${server_id} AND BINARY urls <=> BINARY ${expected_url_expression} AND streaming_skip_ssl_check <=> ${expected_skip_expression})"
        id_separator=','
        condition_separator=' OR '
        count=$((count + 1))
        unset 'expected_rows[$server_id]'
    done <<< "$target_snapshot"
    [ "$count" -gt 0 ] && [ "${#expected_rows[@]}" -eq 0 ] || return 1
    sql="UPDATE ktvs_admin_servers AS target
        JOIN (
            SELECT COUNT(*) AS total_count,
                COALESCE(SUM(CASE WHEN (${expected_conditions}) THEN 1 ELSE 0 END), 0) AS matching_count
            FROM ktvs_admin_servers
        ) AS guard
            ON guard.total_count=${count} AND guard.matching_count=${count}
        SET target.urls = CASE target.server_id${url_cases} ELSE target.urls END,
            target.streaming_skip_ssl_check = CASE target.server_id${skip_cases} ELSE target.streaming_skip_ssl_check END
        WHERE target.server_id IN (${ids});"
    run_query "$sql" || return 1
    restored_snapshot=$(capture_server_state) || return 1
    [ "$restored_snapshot" = "$target_snapshot" ]
}

rollback_multi_application_state() {
    local current_db
    local current_setup
    local current_plugin
    local rollback_status=0

    if ! current_db=$(capture_server_state) ||
        ! validate_server_state "$current_db" ||
        ! current_setup=$(capture_php_file_state \
            /var/www/kvs/admin/include/setup.php) ||
        ! validate_php_file_state "$current_setup" ||
        ! current_plugin=$(capture_php_file_state \
            /var/www/kvs/admin/data/plugins/external_search/data.dat) ||
        ! validate_php_file_state "$current_plugin" ||
        [ "$current_db" != "$MULTI_DB_AFTER" ] ||
        [ "$current_setup" != "$MULTI_SETUP_AFTER" ] ||
        [ "$current_plugin" != "$MULTI_PLUGIN_AFTER" ]; then
        echo -e "${RED}ERROR: Application state changed concurrently; rollback was not attempted${NC}"
        return 1
    fi
    if [ "$MULTI_SETUP_AFTER" != "$MULTI_SETUP_BEFORE" ] &&
        ! restore_php_file_state /var/www/kvs/admin/include/setup.php \
            "$MULTI_SETUP_AFTER" "$MULTI_SETUP_BEFORE"; then
        rollback_status=1
    fi
    if [ "$MULTI_PLUGIN_AFTER" != "$MULTI_PLUGIN_BEFORE" ] &&
        ! restore_php_file_state \
            /var/www/kvs/admin/data/plugins/external_search/data.dat \
            "$MULTI_PLUGIN_AFTER" "$MULTI_PLUGIN_BEFORE"; then
        rollback_status=1
    fi
    if [ "$MULTI_DB_AFTER" != "$MULTI_DB_BEFORE" ] &&
        ! restore_server_state "$MULTI_DB_BEFORE" "$MULTI_DB_AFTER"; then
        rollback_status=1
    fi
    if [ "$rollback_status" -ne 0 ]; then
        echo -e "${RED}ERROR: Application rollback failed and requires manual recovery${NC}"
        return 1
    fi
    echo -e "${GREEN}Application state restored after the reconfiguration failure${NC}" || true
    return 0
}

restore_caddy_route_state() {
    local rollback_failed=false

    [ "$CADDY_ROLLBACK_ARMED" = true ] || return 0
    if [ "$CADDY_ROUTE_EXISTED" = true ]; then
        if ! rm -f -- "$CADDY_ROUTE_FILE" ||
            ! cp -a -- "$CADDY_ROLLBACK_DIR/route" "$CADDY_ROUTE_FILE"; then
            rollback_failed=true
        fi
    else
        rm -f -- "$CADDY_ROUTE_FILE" || rollback_failed=true
    fi
    if [ "$CADDY_RESERVATION_EXISTED" = true ]; then
        if ! rm -f -- "$CADDY_RESERVATION_FILE" ||
            ! cp -a -- "$CADDY_ROLLBACK_DIR/reservation" \
                "$CADDY_RESERVATION_FILE"; then
            rollback_failed=true
        fi
    else
        rm -f -- "$CADDY_RESERVATION_FILE" || rollback_failed=true
    fi
    if [ "$rollback_failed" = true ]; then
        echo -e "${RED}ERROR: Caddy rollback failed; recovery files remain in ${CADDY_ROLLBACK_DIR}${NC}"
        return 1
    fi
    if ! docker exec kvs-caddy caddy validate --config /etc/caddy/Caddyfile \
        >/dev/null 2>&1 ||
        ! docker exec kvs-caddy caddy reload --force \
            --config /etc/caddy/Caddyfile \
        >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Restored Caddy configuration could not be reloaded${NC}"
        return 1
    fi
    CADDY_ROLLBACK_ARMED=false
    if ! rm -rf -- "$CADDY_ROLLBACK_DIR"; then
        echo -e "${YELLOW}WARNING: Caddy was restored, but ${CADDY_ROLLBACK_DIR} could not be removed${NC}"
    fi
    CADDY_ROLLBACK_DIR=''
    echo -e "${GREEN}Caddy route restored after the reconfiguration failure${NC}" || true
    return 0
}

multi_rollback_on_exit() {
    local status=$?
    local caddy_restored=true

    trap - EXIT
    if [ "$MULTI_TRANSACTION_COMMITTED" = true ]; then
        if [ -n "$CADDY_ROLLBACK_DIR" ] &&
            ! rm -rf -- "$CADDY_ROLLBACK_DIR"; then
            echo -e "${YELLOW}WARNING: Could not remove ${CADDY_ROLLBACK_DIR}${NC}"
        fi
    else
        if [ "$CADDY_ROLLBACK_ARMED" = true ] &&
            ! restore_caddy_route_state; then
            caddy_restored=false
            status=1
        elif [ "$CADDY_ROLLBACK_ARMED" != true ] &&
            [ -n "$CADDY_ROLLBACK_DIR" ]; then
            if ! rm -rf -- "$CADDY_ROLLBACK_DIR"; then
                echo -e "${YELLOW}WARNING: Could not remove ${CADDY_ROLLBACK_DIR}${NC}"
                status=1
            fi
            CADDY_ROLLBACK_DIR=''
        fi
        if [ "$MULTI_ROLLBACK_ARMED" = true ]; then
            if [ "$caddy_restored" = true ]; then
                if ! rollback_multi_application_state; then
                    status=1
                fi
            else
                echo -e "${RED}ERROR: Application rollback was skipped because Caddy could not be restored${NC}"
            fi
        fi
    fi
    exit "$status"
}

build_server_state_guard() {
    local snapshot="$1"
    local server_id
    local urls_null
    local urls_base64
    local skip_null
    local skip_value
    local extra
    local url_expression
    local skip_expression
    local separator=''

    validate_server_state "$snapshot" || return 1
    SERVER_STATE_GUARD=''
    SERVER_STATE_ROWS=0
    while IFS='|' read -r server_id urls_null urls_base64 skip_null skip_value extra; do
        if [ "$urls_null" -eq 1 ]; then
            url_expression='NULL'
        else
            url_expression="FROM_BASE64('${urls_base64}')"
        fi
        if [ "$skip_null" -eq 1 ]; then
            skip_expression='NULL'
        else
            skip_expression="$skip_value"
        fi
        SERVER_STATE_GUARD="${SERVER_STATE_GUARD}${separator}(server_id=${server_id} AND BINARY urls <=> BINARY ${url_expression} AND streaming_skip_ssl_check <=> ${skip_expression})"
        separator=' OR '
        SERVER_STATE_ROWS=$((SERVER_STATE_ROWS + 1))
    done <<< "$snapshot"
    [ "$SERVER_STATE_ROWS" -gt 0 ]
}

run_application_update_query() {
    local set_clause="$1"
    local where_clause="$2"
    local current_state
    local updated_state
    local guard_result
    local update_result

    if [ "$MODE" != multi ]; then
        run_query "UPDATE ktvs_admin_servers SET ${set_clause} WHERE ${where_clause};"
        return $?
    fi
    if ! current_state=$(capture_server_state) ||
        [ "$current_state" != "$MULTI_DB_AFTER" ]; then
        echo -e "${RED}ERROR: Database state changed concurrently before update${NC}"
        return 1
    fi
    if ! build_server_state_guard "$MULTI_DB_AFTER"; then
        echo -e "${RED}ERROR: Could not build the database update guard${NC}"
        return 1
    fi
    update_result=$(run_scalar_query "
        LOCK TABLES ktvs_admin_servers WRITE;
        SET @kvs_guard_ok = (
            SELECT IF(
                COUNT(*)=${SERVER_STATE_ROWS} AND
                COALESCE(SUM(CASE WHEN (${SERVER_STATE_GUARD}) THEN 1 ELSE 0 END), 0)=${SERVER_STATE_ROWS},
                1,
                0
            )
            FROM ktvs_admin_servers
        );
        UPDATE ktvs_admin_servers
        SET ${set_clause}
        WHERE (${where_clause}) AND @kvs_guard_ok=1;
        SELECT @kvs_guard_ok;
        SELECT CONCAT(
            server_id, '|',
            IF(urls IS NULL, 1, 0), '|',
            REPLACE(REPLACE(TO_BASE64(COALESCE(urls, '')), CHAR(10), ''), CHAR(13), ''), '|',
            IF(streaming_skip_ssl_check IS NULL, 1, 0), '|',
            COALESCE(CAST(streaming_skip_ssl_check AS CHAR), '')
        )
        FROM ktvs_admin_servers
        ORDER BY server_id;
        UNLOCK TABLES;
    ") || return 1
    guard_result=${update_result%%$'\n'*}
    if [ "$guard_result" = "$update_result" ]; then
        updated_state=''
    else
        updated_state=${update_result#*$'\n'}
    fi
    if [ "$guard_result" != 1 ]; then
        echo -e "${RED}ERROR: Database state changed concurrently during update${NC}"
        return 1
    fi
    if ! validate_server_state "$updated_state"; then
        echo -e "${RED}ERROR: Could not capture database state after update${NC}"
        return 1
    fi
    MULTI_DB_AFTER="$updated_state"
    if ! current_state=$(capture_server_state) ||
        ! validate_server_state "$current_state" ||
        [ "$current_state" != "$MULTI_DB_AFTER" ]; then
        echo -e "${RED}ERROR: Database state changed concurrently after update${NC}"
        return 1
    fi
}

sync_direct_tls_profile() {
    local acme_container_names

    if [ "$MODE" = "single" ] && [ "$SSL_PROVIDER" != "selfsigned" ]; then
        add_compose_profile direct-tls
    else
        remove_compose_profile direct-tls
        if ! acme_container_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
            echo -e "${RED}ERROR: Could not inspect ACME containers${NC}"
            return 1
        fi
        if grep -Fxq "$ACME_CONTAINER" <<< "$acme_container_names"; then
            if ! docker stop "$ACME_CONTAINER" >/dev/null; then
                echo -e "${RED}ERROR: Could not stop ${ACME_CONTAINER}${NC}"
                return 1
            fi
            if ! docker rm "$ACME_CONTAINER" >/dev/null; then
                echo -e "${RED}ERROR: Could not remove ${ACME_CONTAINER}${NC}"
                return 1
            fi
        fi
        if ! acme_container_names=$(docker ps -a --format '{{.Names}}' 2>/dev/null); then
            echo -e "${RED}ERROR: Could not verify ACME container removal${NC}"
            return 1
        fi
        if grep -Fxq "$ACME_CONTAINER" <<< "$acme_container_names"; then
            echo -e "${RED}ERROR: ${ACME_CONTAINER} is still present${NC}"
            return 1
        fi
    fi
}

nginx_certificate_matches_provider() {
    local expected_provider="$1"
    local include_www=false

    if include_www_for_domain; then
        include_www=true
    fi
    docker exec \
        -e KVS_CERT_DOMAIN="$DOMAIN" \
        -e KVS_CERT_INCLUDE_WWW="$include_www" \
        -e KVS_CERT_PROVIDER="$expected_provider" \
        "$NGINX_CONTAINER" sh -c '
            cert="/etc/nginx/ssl/${KVS_CERT_DOMAIN}/cert.pem"
            key="/etc/nginx/ssl/${KVS_CERT_DOMAIN}/key.pem"
            [ -s "$cert" ] && [ -s "$key" ] || exit 1
            san_entries=$(
                openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null |
                    sed "1d; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d" |
                    tr "," "\n" |
                    sed "s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d"
            ) || exit 1
            [ -n "$san_entries" ] || exit 1
            if printf "%s\n" "$san_entries" | grep -Ev "^DNS:" >/dev/null; then
                exit 1
            fi
            actual_dns_names=$(
                printf "%s\n" "$san_entries" |
                    sed -n "s/^DNS://p" | LC_ALL=C sort
            ) || exit 1
            expected_dns_names=$(
                printf "%s\n" "$KVS_CERT_DOMAIN"
                if [ "$KVS_CERT_INCLUDE_WWW" = true ]; then
                    printf "%s\n" "www.${KVS_CERT_DOMAIN}"
                fi
            )
            expected_dns_names=$(
                printf "%s\n" "$expected_dns_names" | LC_ALL=C sort
            ) || exit 1
            [ "$actual_dns_names" = "$expected_dns_names" ] || exit 1
            not_before=$(openssl x509 -in "$cert" -noout -startdate) || exit 1
            not_before=${not_before#notBefore=}
            not_before_epoch=$(LC_ALL=C date -u -d "$not_before" +%s) || exit 1
            now_epoch=$(date -u +%s) || exit 1
            [ "$not_before_epoch" -le "$now_epoch" ] || exit 1
            openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1 || exit 1
            openssl x509 -in "$cert" -noout -checkhost "$KVS_CERT_DOMAIN" \
                >/dev/null 2>&1 || exit 1
            if [ "$KVS_CERT_INCLUDE_WWW" = true ]; then
                openssl x509 -in "$cert" -noout -checkhost "www.${KVS_CERT_DOMAIN}" \
                    >/dev/null 2>&1 || exit 1
            fi
            subject=$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253) || exit 1
            issuer=$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253) || exit 1
            subject=${subject#subject=}
            issuer=${issuer#issuer=}
            case "$KVS_CERT_PROVIDER" in
                public|letsencrypt|zerossl)
                    [ "$subject" != "$issuer" ] || exit 1
                    ca_bundle=/etc/ssl/certs/ca-certificates.crt
                    [ -s "$ca_bundle" ] || exit 1
                    openssl verify -purpose sslserver -CAfile "$ca_bundle" \
                        -untrusted "$cert" "$cert" >/dev/null 2>&1 || exit 1
                    case "$KVS_CERT_PROVIDER" in
                        letsencrypt)
                            case "$issuer" in
                                *"O=Let"*"s Encrypt"*) ;;
                                *) exit 1 ;;
                            esac
                            ;;
                        zerossl)
                            case "$issuer" in
                                *"O=ZeroSSL"*|*"CN=ZeroSSL"*) ;;
                                *) exit 1 ;;
                            esac
                            ;;
                    esac
                    ;;
                selfsigned)
                    [ "$subject" = "$issuer" ] || exit 1
                    openssl verify -check_ss_sig -CAfile "$cert" "$cert" \
                        >/dev/null 2>&1 || exit 1
                    ;;
                *) exit 1 ;;
            esac
            cert_public_key=$(openssl x509 -in "$cert" -pubkey -noout) || exit 1
            private_public_key=$(openssl pkey -in "$key" -pubout -passin pass:) || exit 1
            [ "$cert_public_key" = "$private_public_key" ]
        ' >/dev/null 2>&1
}

generate_self_signed_certificate() {
    local certificate_san="DNS:${DOMAIN}"

    if include_www_for_domain; then
        certificate_san="${certificate_san},DNS:www.${DOMAIN}"
    fi
    docker exec \
        -e KVS_CERT_DOMAIN="$DOMAIN" \
        -e KVS_CERT_SAN="$certificate_san" \
        "$NGINX_CONTAINER" sh -c '
            set -eu
            target_dir="/etc/nginx/ssl/${KVS_CERT_DOMAIN}"
            mkdir -p "$target_dir"
            staging_dir=$(mktemp -d "${target_dir}/.selfsigned.XXXXXX")
            cleanup_staging() { rm -rf "$staging_dir"; }
            trap cleanup_staging EXIT INT TERM
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "${staging_dir}/key.pem" \
                -out "${staging_dir}/cert.pem" \
                -subj "/CN=${KVS_CERT_DOMAIN}" \
                -addext "subjectAltName=${KVS_CERT_SAN}" >/dev/null 2>&1
            chmod 600 "${staging_dir}/key.pem"
            chmod 644 "${staging_dir}/cert.pem"
            mv -f "${staging_dir}/key.pem" "${target_dir}/key.pem"
            mv -f "${staging_dir}/cert.pem" "${target_dir}/cert.pem"
        '
}

configure_multi_route() {
    local tls_mode="public"
    local running_container_names

    [ "$SSL_PROVIDER" != "selfsigned" ] || tls_mode="internal"
    if ! running_container_names=$(docker ps --format '{{.Names}}' 2>/dev/null); then
        echo -e "${RED}ERROR: Could not inspect Caddy state${NC}"
        return 1
    fi
    if ! grep -Fxq kvs-caddy <<< "$running_container_names"; then
        echo -e "${RED}ERROR: kvs-caddy must be running for multi-site reconfiguration${NC}"
        return 1
    fi
    CADDY_ROUTE_FILE="multi-site/caddy/sites/${DOMAIN}.caddy"
    CADDY_RESERVATION_FILE="multi-site/sites/.primary.env"
    CADDY_ROUTE_EXISTED=false
    CADDY_RESERVATION_EXISTED=false
    if ! CADDY_ROLLBACK_DIR=$(mktemp -d); then
        echo -e "${RED}ERROR: Could not create the Caddy rollback directory${NC}"
        return 1
    fi
    if [ -e "$CADDY_ROUTE_FILE" ] || [ -L "$CADDY_ROUTE_FILE" ]; then
        if ! cp -a -- "$CADDY_ROUTE_FILE" "$CADDY_ROLLBACK_DIR/route"; then
            rm -rf -- "$CADDY_ROLLBACK_DIR" || true
            CADDY_ROLLBACK_DIR=''
            echo -e "${RED}ERROR: Could not back up the current Caddy route${NC}"
            return 1
        fi
        CADDY_ROUTE_EXISTED=true
    fi
    if [ -e "$CADDY_RESERVATION_FILE" ] || [ -L "$CADDY_RESERVATION_FILE" ]; then
        if ! cp -a -- "$CADDY_RESERVATION_FILE" \
            "$CADDY_ROLLBACK_DIR/reservation"; then
            rm -rf -- "$CADDY_ROLLBACK_DIR" || true
            CADDY_ROLLBACK_DIR=''
            echo -e "${RED}ERROR: Could not back up the primary reservation${NC}"
            return 1
        fi
        CADDY_RESERVATION_EXISTED=true
    fi

    CADDY_ROLLBACK_ARMED=true
    if ! ./multi-site/site-manager.sh primary-config \
        "$DOMAIN" "$SITE_PREFIX" "$tls_mode" "$USE_WWW"; then
        echo -e "${RED}ERROR: Could not generate the updated primary Caddy route${NC}"
        return 1
    fi
    if ! docker exec kvs-caddy caddy validate --config /etc/caddy/Caddyfile \
        >/dev/null; then
        echo -e "${RED}ERROR: Caddy rejected the updated primary route${NC}"
        return 1
    fi
    if ! docker exec kvs-caddy caddy reload --force \
        --config /etc/caddy/Caddyfile; then
        echo -e "${RED}ERROR: Caddy could not reload the updated primary route${NC}"
        return 1
    fi
    # This assignment is the transaction commit point. The EXIT trap either
    # restores both Caddy and the application before it, or preserves both new
    # states after it, including when the shell receives INT or TERM.
    MULTI_TRANSACTION_COMMITTED=true
    CADDY_ROLLBACK_ARMED=false
    if ! rm -rf -- "$CADDY_ROLLBACK_DIR"; then
        echo -e "${YELLOW}WARNING: Caddy was updated, but ${CADDY_ROLLBACK_DIR} could not be removed${NC}"
    fi
    CADDY_ROLLBACK_DIR=''
}

get_configured_acme_api() {
    docker exec -e KVS_ACME_DOMAIN="$DOMAIN" "$ACME_CONTAINER" sh -c '
        config_file="/acme.sh/${KVS_ACME_DOMAIN}_ecc/${KVS_ACME_DOMAIN}.conf"
        if [ ! -e "$config_file" ]; then
            printf "%s\n" __KVS_ABSENT__
            exit 0
        fi
        [ -f "$config_file" ] && [ -r "$config_file" ] || exit 1
        api=$(sed -n "s/^Le_API=//p" "$config_file" | tail -n 1)
        [ -n "$api" ] || {
            printf "%s\n" __KVS_UNKNOWN__
            exit 0
        }
        single_quote=$(printf "\047")
        api=${api#"$single_quote"}
        api=${api%"$single_quote"}
        api=${api#\"}
        api=${api%\"}
        printf "%s\n" "$api"
    '
}

acme_api_matches_provider() {
    local api="$1"

    case "$SSL_PROVIDER:$api" in
        letsencrypt:*letsencrypt*) return 0 ;;
        zerossl:*zerossl*) return 0 ;;
        *) return 1 ;;
    esac
}

issue_and_install_public_certificate() {
    local acme_output
    local acme_status=0
    local configured_acme_api
    local force_issuance=false
    local -a issue_args

    issue_args=(
        acme.sh --issue
        -d "$DOMAIN"
        --webroot /var/www/_letsencrypt
        --keylength ec-256
        --accountemail "$EMAIL"
    )
    if include_www_for_domain; then
        issue_args+=( -d "www.${DOMAIN}" )
    fi
    if [ "$SSL_PROVIDER" = "letsencrypt" ]; then
        issue_args+=( --server letsencrypt )
    else
        issue_args+=( --server zerossl )
    fi
    if ! configured_acme_api=$(get_configured_acme_api); then
        echo -e "${RED}ERROR: Could not inspect the configured ACME provider${NC}"
        return 1
    fi
    if [ "$configured_acme_api" != __KVS_ABSENT__ ] &&
        ! acme_api_matches_provider "$configured_acme_api"; then
        force_issuance=true
    fi
    if ! nginx_certificate_matches_provider "$SSL_PROVIDER"; then
        force_issuance=true
    fi
    if [ "$force_issuance" = true ]; then
        issue_args+=( --force )
    fi

    if acme_output=$(docker exec "$ACME_CONTAINER" "${issue_args[@]}" 2>&1); then
        acme_status=0
    else
        acme_status=$?
    fi
    if [ "$acme_status" -ne 0 ] &&
        ! { [ "$acme_status" -eq 2 ] &&
            grep -Fq 'Domains not changed.' <<< "$acme_output" &&
            grep -Eq 'Skipping|Skip' <<< "$acme_output"; }; then
        echo -e "${RED}ERROR: Certificate issuance failed${NC}"
        printf '%s\n' "$acme_output"
        return 1
    fi
    if ! configured_acme_api=$(get_configured_acme_api) ||
        ! acme_api_matches_provider "$configured_acme_api"; then
        echo -e "${RED}ERROR: ACME did not persist the requested certificate provider${NC}"
        return 1
    fi
    if ! docker exec "$ACME_CONTAINER" acme.sh --install-cert \
        -d "$DOMAIN" \
        --ecc \
        --key-file "/etc/nginx/ssl/${DOMAIN}/key.pem" \
        --fullchain-file "/etc/nginx/ssl/${DOMAIN}/cert.pem" \
        --reloadcmd true; then
        echo -e "${RED}ERROR: Certificate installation failed${NC}"
        return 1
    fi
    if ! nginx_certificate_matches_provider "$SSL_PROVIDER"; then
        echo -e "${RED}ERROR: Installed certificate was not issued by the requested provider${NC}"
        return 1
    fi
    if ! docker exec "$NGINX_CONTAINER" nginx -t >/dev/null; then
        echo -e "${RED}ERROR: Nginx rejected the installed certificate${NC}"
        return 1
    fi
    if ! docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null; then
        echo -e "${RED}ERROR: Nginx could not reload the installed certificate${NC}"
        return 1
    fi
}

recreate_runtime_services() {
    local profile
    local -a services=(php-fpm cron)
    local -a active_profiles

    IFS=',' read -r -a active_profiles <<< "${COMPOSE_PROFILES:-}"
    for profile in "${active_profiles[@]}"; do
        case "$profile" in
            dragonfly|memcached|manticore) services+=("$profile") ;;
        esac
    done
    docker compose up -d --force-recreate --no-deps "${services[@]}" >/dev/null
}

if [ "$MODE" = "multi" ]; then
    prepare_multi_application_snapshot || exit 1
    MULTI_DB_AFTER="$MULTI_DB_BEFORE"
    MULTI_SETUP_AFTER="$MULTI_SETUP_BEFORE"
    MULTI_PLUGIN_AFTER="$MULTI_PLUGIN_BEFORE"
    MULTI_ROLLBACK_ARMED=true
    MULTI_TRANSACTION_COMMITTED=false
    trap multi_rollback_on_exit EXIT
fi

# 1. Synchronize TLS services and validate the effective certificate.
echo -e "${CYAN}Configuring SSL settings...${NC}"
if ! sync_direct_tls_profile; then
    exit 1
fi
if [ "$MODE" = "multi" ]; then
    if ! docker compose up -d --force-recreate nginx >/dev/null; then
        echo -e "${RED}ERROR: Could not recreate Nginx${NC}"
        exit 1
    fi
    if [ "$SSL_PROVIDER" = "selfsigned" ]; then
        run_application_update_query \
            "streaming_skip_ssl_check = 1" "1=1"
        echo -e "${GREEN}Caddy internal TLS selected${NC}"
    else
        run_application_update_query \
            "streaming_skip_ssl_check = 0" "1=1"
        echo -e "${GREEN}Caddy public TLS selected${NC}"
    fi
elif [ "$SSL_PROVIDER" = "selfsigned" ]; then
    if ! docker compose up -d --force-recreate nginx >/dev/null; then
        echo -e "${RED}ERROR: Could not recreate Nginx${NC}"
        exit 1
    fi
    if ! nginx_certificate_matches_provider selfsigned; then
        if ! generate_self_signed_certificate; then
            echo -e "${RED}ERROR: Could not generate the self-signed certificate${NC}"
            exit 1
        fi
    fi
    if ! nginx_certificate_matches_provider selfsigned; then
        echo -e "${RED}ERROR: Self-signed certificate validation failed${NC}"
        exit 1
    fi
    if ! docker exec "$NGINX_CONTAINER" nginx -t >/dev/null ||
        ! docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null; then
        echo -e "${RED}ERROR: Nginx could not load the self-signed certificate${NC}"
        exit 1
    fi
    run_query "UPDATE ktvs_admin_servers SET streaming_skip_ssl_check = 1;"
    echo -e "${GREEN}Self-signed TLS configured and SSL verification disabled${NC}"
else
    if ! docker compose up -d --force-recreate nginx acme >/dev/null; then
        echo -e "${RED}ERROR: Could not start Nginx and ACME${NC}"
        exit 1
    fi
    issue_and_install_public_certificate || exit 1
    run_query "UPDATE ktvs_admin_servers SET streaming_skip_ssl_check = 0;"
    echo -e "${GREEN}Public certificate installed and SSL verification enabled${NC}"
fi

if ! recreate_runtime_services; then
    echo -e "${RED}ERROR: Could not recreate the application services${NC}"
    exit 1
fi
if ! docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1 ||
    ! docker exec "$NGINX_CONTAINER" nginx -s reload >/dev/null; then
    echo -e "${RED}ERROR: Nginx could not reload after backend recreation${NC}"
    exit 1
fi
set_env_value PROJECT_HTTPS_PORT "$PROJECT_HTTPS_PORT"
export PROJECT_HTTPS_PORT

# 2. Update server URLs based on USE_WWW
echo -e "${CYAN}Configuring server URLs...${NC}"
HTTPS_PORT_SUFFIX=""
if [ "$PROJECT_HTTPS_PORT" -ne 443 ]; then
    HTTPS_PORT_SUFFIX=":${PROJECT_HTTPS_PORT}"
fi
if [ "$USE_WWW" = "true" ]; then
    SERVER_URL="https://www.${DOMAIN}${HTTPS_PORT_SUFFIX}"
else
    SERVER_URL="https://${DOMAIN}${HTTPS_PORT_SUFFIX}"
fi

# Replace only this project's bounded storage prefix. The optional old port is
# consumed, so repeated runs and 443/non-443 transitions remain idempotent.
DOMAIN_PATTERN=${DOMAIN//./[.]}
run_application_update_query \
    "urls = REGEXP_REPLACE(urls, '^https://(www[.])?${DOMAIN_PATTERN}(:[0-9]+)?/contents/', '${SERVER_URL}/contents/')" \
    "urls REGEXP '^https://(www[.])?${DOMAIN_PATTERN}(:[0-9]+)?/contents/'"

SETUP_PATH=/var/www/kvs/admin/include/setup.php
if [ "$MODE" = multi ]; then
    EXPECTED_SETUP_STATE="$MULTI_SETUP_AFTER"
elif ! EXPECTED_SETUP_STATE=$(capture_php_file_state "$SETUP_PATH") ||
    ! validate_php_file_state "$EXPECTED_SETUP_STATE" ||
    [ "${EXPECTED_SETUP_STATE%%|*}" != file ]; then
    echo -e "${RED}Failed to inspect the KVS project configuration${NC}"
    exit 1
fi
if ! UPDATED_SETUP_STATE=$(update_php_file_guarded \
    "$SETUP_PATH" setup "$EXPECTED_SETUP_STATE") ||
    ! validate_php_file_state "$UPDATED_SETUP_STATE" ||
    [ "${UPDATED_SETUP_STATE%%|*}" != file ]; then
    echo -e "${RED}Failed to update the KVS project URL${NC}"
    exit 1
fi
if [ "$MODE" = multi ]; then
    MULTI_SETUP_AFTER="$UPDATED_SETUP_STATE"
fi
if ! docker exec --user 1000:1000 -e PROJECT_URL="$SERVER_URL" \
    "$PHP_CONTAINER" php -r '
        $file = "/var/www/kvs/admin/include/setup.php";
        $needle = "\$config[" . chr(39) . "project_url" . chr(39) . "]=\"" .
            getenv("PROJECT_URL") . "\"";
        $contents = @file_get_contents($file);
        exit(is_string($contents) && strpos($contents, $needle) !== false ? 0 : 1);
    '; then
    echo -e "${RED}Failed to verify the KVS project URL${NC}"
    exit 1
fi

PLUGIN_PATH=/var/www/kvs/admin/data/plugins/external_search/data.dat
if [ "$MODE" = multi ]; then
    EXPECTED_PLUGIN_STATE="$MULTI_PLUGIN_AFTER"
elif ! EXPECTED_PLUGIN_STATE=$(capture_php_file_state "$PLUGIN_PATH") ||
    ! validate_php_file_state "$EXPECTED_PLUGIN_STATE"; then
    echo -e "${RED}Failed to inspect the Manticore external-search data${NC}"
    exit 1
fi
if ! UPDATED_PLUGIN_STATE=$(update_php_file_guarded \
    "$PLUGIN_PATH" plugin "$EXPECTED_PLUGIN_STATE") ||
    ! validate_php_file_state "$UPDATED_PLUGIN_STATE"; then
    echo -e "${RED}Failed to update the Manticore external-search URL${NC}"
    exit 1
fi
if [ "$MODE" = multi ]; then
    MULTI_PLUGIN_AFTER="$UPDATED_PLUGIN_STATE"
fi
echo -e "${GREEN}Server URLs set to: ${SERVER_URL}/contents/...${NC}"

# 3. Validate the Nginx instance recreated with the updated environment.
echo -e "${CYAN}Validating nginx...${NC}"
if docker exec "$NGINX_CONTAINER" nginx -t 2>/dev/null; then
    echo -e "${GREEN}Nginx is using the updated public URL${NC}"
else
    echo -e "${RED}Nginx config test failed${NC}"
    exit 1
fi

# Verify the persisted server state before reporting success.
echo ""
echo "Current settings:"
if ! MATCHING_URL_COUNT=$(run_scalar_query \
    "SELECT COUNT(*) FROM ktvs_admin_servers WHERE urls LIKE '${SERVER_URL}/contents/%';") ||
    ! STALE_PROJECT_URL_COUNT=$(run_scalar_query \
        "SELECT COUNT(*) FROM ktvs_admin_servers WHERE urls REGEXP '^https://(www[.])?${DOMAIN_PATTERN}(:[0-9]+)?/contents/' AND urls NOT LIKE '${SERVER_URL}/contents/%';") ||
    ! SSL_MISMATCH_COUNT=$(run_scalar_query \
        "SELECT COUNT(*) FROM ktvs_admin_servers WHERE COALESCE(streaming_skip_ssl_check,-1)<>${EXPECTED_SSL_SKIP};"); then
    echo -e "${RED}ERROR: Could not verify the reconfigured database state${NC}"
    exit 1
fi
if ! [[ "$MATCHING_URL_COUNT" =~ ^[0-9]+$ ]] ||
    ! [[ "$STALE_PROJECT_URL_COUNT" =~ ^[0-9]+$ ]] ||
    ! [[ "$SSL_MISMATCH_COUNT" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}ERROR: Database verification returned invalid counters${NC}"
    exit 1
fi
if [ "$MATCHING_URL_COUNT" -lt 1 ] || [ "$STALE_PROJECT_URL_COUNT" -ne 0 ] ||
    [ "$SSL_MISMATCH_COUNT" -ne 0 ]; then
    echo -e "${RED}ERROR: Reconfigured database values do not match the requested state${NC}"
    exit 1
fi
if ! run_query \
    "SELECT server_id, urls, streaming_skip_ssl_check FROM ktvs_admin_servers;"; then
    echo -e "${RED}ERROR: Could not verify the reconfigured server state${NC}"
    exit 1
fi
if [ "$PENDING_MULTI_ROUTE" = true ]; then
    capture_multi_application_result || exit 1
    if ! configure_multi_route; then
        exit 1
    fi
    MULTI_ROLLBACK_ARMED=false
    trap - EXIT
    MULTI_DB_BEFORE=''
    MULTI_DB_AFTER=''
    MULTI_SETUP_BEFORE=''
    MULTI_SETUP_AFTER=''
    MULTI_PLUGIN_BEFORE=''
    MULTI_PLUGIN_AFTER=''
    MULTI_TRANSACTION_COMMITTED=false
    CADDY_ROLLBACK_ARMED=false
    CADDY_ROLLBACK_DIR=''
    CADDY_ROUTE_FILE=''
    CADDY_RESERVATION_FILE=''
    CADDY_ROUTE_EXISTED=false
    CADDY_RESERVATION_EXISTED=false
    echo -e "${GREEN}Caddy primary route updated and reloaded${NC}"
fi
echo ""
echo -e "${GREEN}=== Reconfiguration Complete ===${NC}"
