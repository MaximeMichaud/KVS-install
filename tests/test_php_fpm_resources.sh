#!/bin/bash
# Exercise runtime sizing against synthetic kernel files, without touching a
# live pool. The generated file is read again after each independent startup.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/kvs-fpm-resources.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=docker/php/fpm-config.sh
source "$ROOT_DIR/docker/php/fpm-config.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
reset_case() {
    unset PHP_FPM_MEMORY_PERCENT PHP_FPM_PROCESS_MEMORY_MB PHP_FPM_MAX_CHILDREN \
        PHP_FPM_START_SERVERS PHP_FPM_MIN_SPARE_SERVERS PHP_FPM_MAX_SPARE_SERVERS
    rm -rf "$WORK/root"
    fixture="$WORK/root"
    mkdir -p "$fixture/proc/self" "$fixture/usr/local/etc/php-fpm.d" "$fixture/sys/fs/cgroup"
    printf 'MemTotal: 16777216 kB\nMemAvailable: 1024 kB\n' > "$fixture/proc/meminfo"
    : > "$fixture/proc/self/cgroup"
    : > "$fixture/proc/self/mountinfo"
    pool="$fixture/usr/local/etc/php-fpm.d/zz-kvs-pool.conf"
}
v2() {
    printf '0::%s\n' "${1:-/}" > "$fixture/proc/self/cgroup"
    printf '1 0 0:1 %s /sys/fs/cgroup ro - cgroup2 cgroup rw\n' "${2:-/}" > "$fixture/proc/self/mountinfo"
}
sizes() {
    awk '$1 ~ /^pm\./ { printf "%s%s", sep, $3; sep=" " } END { print "" }' "$pool"
}
assert_sizes() {
    configure_php_fpm "$fixture" > "$WORK/startup.log" || fail 'startup failed'
    [ "$(sizes)" = "$1" ] || fail "expected $1, got $(sizes)"
    grep -Fxq 'pm = dynamic' "$pool" || fail 'pool mode missing'
    [ "$(stat -c %a "$pool")" = 644 ] || fail 'pool is not readable'
}
reject() {
    cp "$pool" "$WORK/before"
    if configure_php_fpm "$fixture" > "$WORK/error.log" 2>&1; then fail "accepted $1"; fi
    cmp -s "$pool" "$WORK/before" || fail "changed pool on $1"
    grep -q 'ERROR:' "$WORK/error.log" || fail "no explanation for $1"
}

reset_case
assert_sizes '64 16 8 32'
printf 'MemTotal: 33554432 kB\nMemAvailable: 1 kB\n' > "$fixture/proc/meminfo"
assert_sizes '128 32 16 64'
printf 'MemTotal: 1048576 kB\nMemAvailable: 999999 kB\n' > "$fixture/proc/meminfo"
assert_sizes '4 1 1 2'
echo 'PASS: pool scales with capacity rather than fluctuating free memory'

reset_case
v2
printf '1073741824\n' > "$fixture/sys/fs/cgroup/memory.max"
assert_sizes '4 1 1 2'
printf 'max\n' > "$fixture/sys/fs/cgroup/memory.max"
assert_sizes '64 16 8 32'
printf '34359738368\n' > "$fixture/sys/fs/cgroup/memory.max"
assert_sizes '64 16 8 32'
printf '67108864\n' > "$fixture/sys/fs/cgroup/memory.max"
assert_sizes '1 1 1 1'
echo 'PASS: cgroup v2 cap, unlimited, host ceiling and small containers'

reset_case
v2 / /docker/php
printf '2147483648\n' > "$fixture/sys/fs/cgroup/memory.max"
assert_sizes '8 2 1 4'
rm "$fixture/proc/self/mountinfo"
reject 'missing mount information'
echo 'PASS: private cgroup namespace and missing kernel information'

reset_case
v2 /slice/php
mkdir -p "$fixture/sys/fs/cgroup/slice/php" "$fixture/sys/fs/cgroup/unrelated"
printf 'max\n' > "$fixture/sys/fs/cgroup/memory.max"
printf '2147483648\n' > "$fixture/sys/fs/cgroup/slice/memory.max"
printf '4294967296\n' > "$fixture/sys/fs/cgroup/slice/php/memory.max"
printf '67108864\n' > "$fixture/sys/fs/cgroup/unrelated/memory.max"
assert_sizes '8 2 1 4'
v2 /slice/php /slice
mkdir -p "$fixture/sys/fs/cgroup/php"
printf '1073741824\n' > "$fixture/sys/fs/cgroup/php/memory.max"
assert_sizes '4 1 1 2'
echo 'PASS: process membership, visible ancestor limits and subtree mounts'

reset_case
mkdir -p "$fixture/sys/fs/cgroup/memory/docker/php"
printf '2:cpu,cpuacct:/docker/php\n3:memory:/docker/php\n' > "$fixture/proc/self/cgroup"
printf '2 0 0:2 /docker/php /sys/fs/cgroup/memory ro - cgroup cgroup rw,memory\n' > "$fixture/proc/self/mountinfo"
printf '1073741824\n' > "$fixture/sys/fs/cgroup/memory/memory.limit_in_bytes"
assert_sizes '4 1 1 2'
printf '9223372036854771712\n' > "$fixture/sys/fs/cgroup/memory/memory.limit_in_bytes"
assert_sizes '64 16 8 32'
printf '2 0 0:2 / /sys/fs/cgroup/memory ro - cgroup cgroup rw,memory\n' > "$fixture/proc/self/mountinfo"
printf '2147483648\n' > "$fixture/sys/fs/cgroup/memory/docker/memory.limit_in_bytes"
printf 'max\n' > "$fixture/sys/fs/cgroup/memory/docker/php/memory.limit_in_bytes"
assert_sizes '8 2 1 4'
echo 'PASS: cgroup v1 bind mount, unlimited sentinel and ancestor limits'

reset_case
PHP_FPM_MEMORY_PERCENT=50
assert_sizes '128 32 16 64'
PHP_FPM_PROCESS_MEMORY_MB=128
assert_sizes '64 16 8 32'
PHP_FPM_MAX_CHILDREN=12
assert_sizes '12 3 1 6'
PHP_FPM_START_SERVERS=8
assert_sizes '12 8 1 8'
PHP_FPM_MIN_SPARE_SERVERS=8
PHP_FPM_MAX_SPARE_SERVERS=10
assert_sizes '12 8 8 10'
PHP_FPM_START_SERVERS=auto
assert_sizes '12 8 8 10'
unset PHP_FPM_MIN_SPARE_SERVERS
PHP_FPM_MAX_SPARE_SERVERS=1
assert_sizes '12 1 1 1'
echo 'PASS: budget, worker estimate and partial manual overrides'

reset_case
assert_sizes '64 16 8 32'
for name in PHP_FPM_MEMORY_PERCENT PHP_FPM_PROCESS_MEMORY_MB PHP_FPM_MAX_CHILDREN \
    PHP_FPM_START_SERVERS PHP_FPM_MIN_SPARE_SERVERS PHP_FPM_MAX_SPARE_SERVERS; do
    for value in 0 -1 01 1.5 999999999999999999999 '2+2' '1;touch unexpected'; do
        printf -v "$name" '%s' "$value"
        reject "$name=$value"
    done
    unset "$name"
done
PHP_FPM_MEMORY_PERCENT=101
reject 'percentage over 100'
unset PHP_FPM_MEMORY_PERCENT
PHP_FPM_MAX_CHILDREN=4
PHP_FPM_MIN_SPARE_SERVERS=5
reject 'minimum greater than maximum'
unset PHP_FPM_MIN_SPARE_SERVERS
PHP_FPM_START_SERVERS=4
PHP_FPM_MAX_SPARE_SERVERS=2
reject 'start greater than spare maximum'
unset PHP_FPM_START_SERVERS PHP_FPM_MAX_SPARE_SERVERS PHP_FPM_MAX_CHILDREN
printf 'MemTotal: invalid kB\n' > "$fixture/proc/meminfo"
reject 'unreadable capacity'
PHP_FPM_MAX_CHILDREN=20
assert_sizes '20 5 2 10'
echo 'PASS: invalid settings preserve the previous pool; manual sizing needs no memory probe'

# Read the file in a separate process, as FPM does after the entrypoint.
reset_case
configure_php_fpm "$fixture" >/dev/null
bash -eu -c 'source "$1"; configure_php_fpm "$2"' bash \
    "$ROOT_DIR/docker/php/fpm-config.sh" "$fixture" >/dev/null
[ "$(sizes)" = '64 16 8 32' ] || fail 'restart changed unchanged sizing'
[ "$(find "${pool%/*}" -type f | wc -l)" = 1 ] || fail 'startup left duplicate pool files'
echo 'PASS: repeated startup persists one complete pool configuration'

# The values must reach both deployment modes through actual Compose parsing.
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    for compose in docker/docker-compose.yml docker/multi-site/docker-compose.site.yml.template; do
        for overrides in no yes; do
            (
                unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES
                export DOMAIN=fpm.example.com SITE_PREFIX=fpm-test MARIADB_ROOT_PASSWORD=fixture-root MARIADB_PASSWORD=fixture-user
                if [ "$overrides" = yes ]; then
                    export PHP_FPM_MEMORY_PERCENT=40 PHP_FPM_PROCESS_MEMORY_MB=96 \
                        PHP_FPM_MAX_CHILDREN=40 PHP_FPM_START_SERVERS=10 \
                        PHP_FPM_MIN_SPARE_SERVERS=5 PHP_FPM_MAX_SPARE_SERVERS=20
                fi
                docker compose --env-file /dev/null -f "$ROOT_DIR/$compose" config --format json
            ) > "$WORK/compose.json"
            python3 - "$WORK/compose.json" "$overrides" <<'PY'
import json
import sys
env = json.load(open(sys.argv[1]))["services"]["php-fpm"]["environment"]
names = ["MEMORY_PERCENT", "PROCESS_MEMORY_MB", "MAX_CHILDREN", "START_SERVERS", "MIN_SPARE_SERVERS", "MAX_SPARE_SERVERS"]
expected = ["25", "64", "auto", "auto", "auto", "auto"] if sys.argv[2] == "no" else ["40", "96", "40", "10", "5", "20"]
assert [env["PHP_FPM_" + name] for name in names] == expected, env
PY
        done
    done
    echo 'PASS: standalone and multi-site Compose forward defaults and manual settings'
else
    [ "${CI:-false}" != true ] || fail 'Compose required in CI'
    echo 'SKIP: Compose unavailable'
fi
