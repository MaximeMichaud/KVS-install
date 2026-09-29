#!/bin/bash
# Persistent resource selection through the real env writer and Compose parser.
# No daemon, network, database, or system configuration is changed by this test.
# shellcheck disable=SC2034,SC1090,SC2016
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/kvs-db-resources.XXXXXX)
trap 'rm -rf "$work"' EXIT
real_docker=$(type -P docker)
# shellcheck source=/dev/null
source "$root/docker/lib/database.sh"
source <(sed -n '/^set_env_value() {/,/^}/p' "$root/docker/setup.sh")
cd "$work"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
database_available_memory_mb() { echo "${AVAILABLE_MB:-24576}"; }
database_capacity_memory_mb() { echo "${CAPACITY_MB:-32768}"; }
docker() {
    [ "$1" = compose ] || return 97
    shift
    "$real_docker" compose --env-file "$work/.env" \
        -f "$root/docker/docker-compose.yml" "${compose_extra[@]}" "$@"
}
reset_case() {
    unset MARIADB_BUFFER_POOL_SIZE MARIADB_BUFFER_POOL_SIZE_REQUEST
    unset MARIADB_REDO_LOG_SIZE MARIADB_REDO_LOG_SIZE_REQUEST
    unset AVAILABLE_MB CAPACITY_MB
    compose_extra=()
    cat > .env <<'ENV'
DOMAIN=resources.example.com
SITE_PREFIX=kvs-resources
MARIADB_ROOT_PASSWORD=fixture-root-only
MARIADB_PASSWORD=fixture-user-only
ENV
    chmod 600 .env
}
read_saved() {
    bash -eu -c 'source "$1"; printf "%s %s\n" "$MARIADB_BUFFER_POOL_SIZE" "$MARIADB_REDO_LOG_SIZE"' sh "$work/.env"
}
assert_unchanged_failure() {
    cp .env before.env
    if database_configure_resources > failure.log 2>&1; then fail "$1 accepted"; fi
    cmp .env before.env || fail "$1 changed persisted settings"
}

for pair in '256 128M' '512 256M' '1024 512M' '8192 4096M' '24576 12288M' '65536 32768M'; do
    read -r budget expected <<< "$pair"
    [ "$(database_buffer_pool_for_host "$budget")" = "$expected" ] || fail "pool budget $budget"
done
for budget in 0 1 128 255 invalid; do
    if database_buffer_pool_for_host "$budget" >/dev/null 2>&1; then fail "insufficient budget $budget accepted"; fi
done
for pair in '128 128M' '256 128M' '1024 512M' '4096 2048M' '12288 2048M'; do
    read -r pool expected <<< "$pair"
    [ "$(database_redo_for_pool "$pool")" = "$expected" ] || fail "redo for $pool pool"
done

reset_case
database_configure_resources > sizing.log
[ "$(read_saved)" = '12288M 2048M' ] || fail '24 GiB automatic sizes not persisted'
[ "$(stat -c '%a' .env)" = 600 ] || fail 'env file permissions changed'
docker compose config --format json > rendered.json
jq -e '.services.mariadb.command == ["--innodb-buffer-pool-size=12288M", "--innodb-log-file-size=2048M"]' rendered.json >/dev/null || fail 'persisted settings missing from rendered startup'
# Read from the saved file in a new process without the exported values.
env -u MARIADB_BUFFER_POOL_SIZE -u MARIADB_REDO_LOG_SIZE "$real_docker" compose \
    --env-file "$work/.env" -f "$root/docker/docker-compose.yml" config --format json > fresh.json
jq -e '.services.mariadb.command == ["--innodb-buffer-pool-size=12288M", "--innodb-log-file-size=2048M"]' fresh.json >/dev/null || fail 'new process lost saved startup settings'
AVAILABLE_MB=1024
database_configure_resources >/dev/null
[ "$(read_saved)" = '12288M 2048M' ] || fail 'rerun resized a saved pool based on remaining free RAM'
echo 'PASS: automatic sizing persisted, reloaded and rendered for startup'

reset_case
MARIADB_BUFFER_POOL_SIZE=4G
database_configure_resources >/dev/null
[ "$(read_saved)" = '4G 2048M' ] || fail 'legacy pool was guessed to be automatic'
MARIADB_BUFFER_POOL_SIZE_REQUEST=auto
AVAILABLE_MB=18432
database_configure_resources >/dev/null
[ "$(read_saved)" = '9216M 2048M' ] || fail 'explicit auto did not recalculate pool'
MARIADB_BUFFER_POOL_SIZE_REQUEST=2G
MARIADB_REDO_LOG_SIZE_REQUEST=512M
database_configure_resources >/dev/null
[ "$(read_saved)" = '2G 512M' ] || fail 'explicit sizes lost precedence'
MARIADB_BUFFER_POOL_SIZE_REQUEST=64M
database_configure_resources >/dev/null
[ "$(read_saved)" = '64M 512M' ] || fail 'explicit small pool was replaced by automatic minimum'
echo 'PASS: saved sizes, explicit overrides and explicit recalculation'

reset_case
cat > limits.yml <<'YAML'
services:
  mariadb:
    mem_limit: 1g
YAML
compose_extra=(-f "$work/limits.yml")
database_configure_resources >/dev/null
[ "$(read_saved)" = '512M 256M' ] || fail 'Compose cap not reflected in both defaults'
unset MARIADB_BUFFER_POOL_SIZE MARIADB_REDO_LOG_SIZE
AVAILABLE_MB=512
CAPACITY_MB=512
database_configure_resources >/dev/null
[ "$(read_saved)" = '256M 128M' ] || fail 'smaller cgroup budget ignored'
MARIADB_BUFFER_POOL_SIZE_REQUEST=512M
assert_unchanged_failure 'explicit pool without container headroom'
echo 'PASS: Compose and cgroup budgets, including explicit-size rejection'

reset_case
AVAILABLE_MB=0
assert_unchanged_failure 'zero available RAM'
unset AVAILABLE_MB
MARIADB_BUFFER_POOL_SIZE_REQUEST=12G
for value in 0G 513G 2M 08G 999999999999999999999G '2G;echo unexpected'; do
    MARIADB_REDO_LOG_SIZE_REQUEST=$value
    assert_unchanged_failure "invalid redo $value"
done
MARIADB_REDO_LOG_SIZE_REQUEST=2G
MARIADB_BUFFER_POOL_SIZE_REQUEST=999999999999999999999G
assert_unchanged_failure 'oversized numeric pool'
echo 'PASS: invalid sizing cannot partially rewrite env settings'

reset_case
cat > command.yml <<'YAML'
services:
  mariadb:
    command: ["mariadbd"]
YAML
compose_extra=(-f "$work/command.yml")
assert_unchanged_failure 'command override removing resource flags'
for alias in loose-innodb-buffer-pool-size maximum-innodb-buffer-pool-size loose-innodb-log-file-size; do
    cat > command.yml <<'YAML'
services:
  mariadb:
    command:
      - --innodb-buffer-pool-size=${MARIADB_BUFFER_POOL_SIZE}
      - --innodb-log-file-size=${MARIADB_REDO_LOG_SIZE}
YAML
    printf '      - --%s=24G\n' "$alias" >> command.yml
    assert_unchanged_failure "late $alias override"
done
echo 'PASS: effective command override detected before persistence'

reset_case
MARIADB_BUFFER_POOL_SIZE=512M
MARIADB_REDO_LOG_SIZE=128M
database_root_query() { printf '536870912\t%s\n' "${ACTUAL_REDO:-134217728}"; }
database_verify_running_resources >/dev/null
ACTUAL_REDO=100663296
if database_verify_running_resources >/dev/null 2>&1; then fail 'running default redo accepted'; fi
echo 'PASS: SQL readback rejects a server ignoring saved settings'

reset_case
printf 'MARIADB_BUFFER_POOL_SIZE=1G\nMARIADB_REDO_LOG_SIZE=512M\n' >> .env
"$real_docker" compose --env-file "$work/.env" \
    -f "$root/docker/multi-site/docker-compose.site.yml.template" config --format json > secondary.json
jq -e '.services.mariadb.command == ["--innodb-buffer-pool-size=1G", "--innodb-log-file-size=512M"]' secondary.json >/dev/null || fail 'secondary template ignores persistent sizes'
echo 'PASS: secondary template honors its own explicit resource budget'
