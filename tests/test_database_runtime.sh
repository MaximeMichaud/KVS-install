#!/bin/bash
# shellcheck disable=SC2034,SC2329
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/database.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
for pair in '256 128M' '512 128M' '1024 256M' '2048 512M' '8192 2048M' '24576 4096M'; do
    read -r available expected <<< "$pair"
    [ "$(database_buffer_pool_for_host "$available")" = "$expected" ] || fail "RAM budget $pair"
done

database_available_memory_mb() { echo 24576; }
docker() {
    case "$*" in
        'compose config') cat "$TEST_DIR/compose.yml" ;;
        'compose ps -a -q mariadb') echo test-container ;;
        inspect*) echo "${CONTAINER_STATE:-0 running}" ;;
        'compose logs --tail 20 mariadb') echo 'fixture startup failure' ;;
        *) fail "Unexpected Docker call: $*" ;;
    esac
}
set_env_value() { printf '%s=%s\n' "$1" "$2" > "$TEST_DIR/persisted.env"; }
cat > "$TEST_DIR/compose.yml" <<'YAML'
services:
  mariadb:
    mem_limit: "1073741824"
    deploy:
      resources:
        limits:
          memory: "536870912"
        reservations:
          memory: "134217728"
  php-fpm:
    mem_limit: "1000000"
YAML
[ "$(database_compose_memory_limit)" = 536870912 ] || fail 'Docker memory limit parsing'
MARIADB_BUFFER_POOL_SIZE=''
MARIADB_BUFFER_POOL_SIZE_REQUEST=''
database_configure_buffer_pool > "$TEST_DIR/sizing.log"
grep -Fxq 'MARIADB_BUFFER_POOL_SIZE=128M' "$TEST_DIR/persisted.env" || fail 'capped automatic pool persistence'
MARIADB_BUFFER_POOL_SIZE_REQUEST=1G
if database_configure_buffer_pool > "$TEST_DIR/rejected.log" 2>&1; then fail 'pool exceeding container limit accepted'; fi
grep -Fxq 'MARIADB_BUFFER_POOL_SIZE=128M' "$TEST_DIR/persisted.env" || fail 'rejected pool changed saved value'
printf 'services:\n  mariadb:\n    image: mariadb\n' > "$TEST_DIR/compose.yml"
MARIADB_BUFFER_POOL_SIZE_REQUEST=2G
database_configure_buffer_pool >/dev/null
grep -Fxq 'MARIADB_BUFFER_POOL_SIZE=2G' "$TEST_DIR/persisted.env" || fail 'explicit pool persistence'
MARIADB_BUFFER_POOL_SIZE_REQUEST=''
database_configure_buffer_pool >/dev/null
grep -Fxq 'MARIADB_BUFFER_POOL_SIZE=2G' "$TEST_DIR/persisted.env" || fail 'saved pool was overwritten'
MARIADB_BUFFER_POOL_SIZE_REQUEST='2G;echo unsafe'
if database_configure_buffer_pool >/dev/null 2>&1; then fail 'malformed size accepted'; fi

IMPORT_DUMP_TABLES=8
fixture_snapshot=$'tables\t3\npool\t536870912\ninnodb_data_written\t1048576\noperation\tSending data\t9\tktvs_videos\t25.0'
line=$(database_progress_line 3671 "$fixture_snapshot" $'1048576\t2097152')
for expected in '1:01:11 waiting' '50%, SQL may still be running' '3/8 tables created' 'InnoDB written 1.0 MiB' '512.0 MiB' 'ktvs_videos, 9s' 'statement 25.0%'; do
    [[ "$line" == *"$expected"* ]] || fail "missing progress field $expected: $line"
done
[[ "$(database_progress_line 0 '' '')" == *'SQL status unavailable'* ]] || fail 'startup diagnostic missing'

database_root_query() { return 1; }
database_import_snapshot() { printf '%s\n' "$fixture_snapshot"; }
database_dump_position() { printf '1048576\t2097152\n'; }
database_wait_ready 60 yes > "$TEST_DIR/progress.log"
grep -q 'dump read' "$TEST_DIR/progress.log" || fail 'one-shot monitor did not report replay'
if CONTAINER_STATE='1 running' database_wait_ready 60 yes > "$TEST_DIR/restart.log" 2>&1; then fail 'restart was accepted'; fi
if CONTAINER_STATE='0 exited' database_wait_ready 60 yes > "$TEST_DIR/stopped.log" 2>&1; then fail 'stopped container was accepted'; fi
if database_wait_ready invalid >/dev/null 2>&1; then fail 'invalid timeout accepted'; fi
database_root_query() { return 0; }
database_wait_ready 60 > "$TEST_DIR/ready.log"
grep -q 'This alone does not verify an import' "$TEST_DIR/ready.log" || fail 'TCP readiness claims import completion'
echo 'PASS: MariaDB memory sizing, persistence and import monitoring'
