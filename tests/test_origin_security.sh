#!/bin/bash
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-origin-security.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

# Inspect the effective Compose model, including optional service profiles.
env DOMAIN=example.test MARIADB_ROOT_PASSWORD=test-root MARIADB_PASSWORD=test-user \
    docker compose --env-file "$ROOT_DIR/docker/.env.example" \
    -f "$ROOT_DIR/docker/docker-compose.yml" --profile dragonfly \
    --profile memcached --profile manticore config --format json > "$TEST_DIR/compose.json"
jq -e '
    [.services | to_entries[] | select(.key != "nginx") |
     .value.ports[]? | select(.host_ip != "127.0.0.1")] | length == 0
' "$TEST_DIR/compose.json" >/dev/null
jq -e '
    (.services.nginx.ports | map(.target) | sort) == [80,443] and
    (.services.mariadb.ports | map(.target)) == [3306] and
    (.services.memcached.ports | map(.target)) == [11211] and
    (.services.dragonfly.ports | map(.target)) == [11211] and
    (.services["php-fpm"].ports // [] | length) == 0
' "$TEST_DIR/compose.json" >/dev/null

env DOMAIN=example.test MARIADB_ROOT_PASSWORD=test-root MARIADB_PASSWORD=test-user \
    docker compose --env-file "$ROOT_DIR/docker/.env.example" \
    -f "$ROOT_DIR/docker/docker-compose.yml" -f "$ROOT_DIR/docker/docker-compose.multi.yml" \
    --profile dragonfly --profile memcached --profile manticore \
    config --format json > "$TEST_DIR/multi.json"
jq -e '
    [.services | to_entries[] | .value.ports[]? |
     select(.host_ip != "127.0.0.1")] | length == 0
' "$TEST_DIR/multi.json" >/dev/null

env DOMAIN=example.test SITE_PREFIX=origin-test MARIADB_ROOT_PASSWORD=test-root MARIADB_PASSWORD=test-user \
    docker compose --env-file "$ROOT_DIR/docker/.env.example" \
    -f "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template" \
    --profile dragonfly --profile memcached --profile manticore \
    config --format json > "$TEST_DIR/additional-site.json"
jq -e '
    [.services[] | .ports[]?] | length == 0
' "$TEST_DIR/additional-site.json" >/dev/null

printf 'PASS: backend ports are loopback-only; Redis/FastCGI/internal HTTP are not published; multi-site Nginx is private.\n'
