#!/bin/bash
# Use a locally available PHP-FPM base with the actual entrypoint and sizing
# helper. No network, application volumes or existing containers are used.
# shellcheck disable=SC2016
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/kvs-fpm-runtime.XXXXXX")
NAME="kvs-fpm-resources-$$"
IMAGE="kvs-fpm-resources-test:$$"
cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
BASE=${PHP_FPM_TEST_IMAGE:-$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get php-fpm 8.1)}
docker image inspect "$BASE" >/dev/null || fail 'pull the PHP-FPM test base before running this offline suite'

# Exercise the real COPY instructions as well as the entrypoint. The rest of
# the production build installs unrelated extensions and downloads binaries.
printf 'FROM %s\n' "$BASE" > "$WORK/Dockerfile"
awk '/^COPY (fpm-config.sh|docker-entrypoint.sh) / { print }' "$ROOT_DIR/docker/php/Dockerfile" >> "$WORK/Dockerfile"
cat >> "$WORK/Dockerfile" <<'DOCKER'
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENV KVS_MEMCACHE_LOOPBACK=false YT_DLP_AUTO_UPDATE=no
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["php-fpm"]
DOCKER
docker build --network none --pull=false -q -f "$WORK/Dockerfile" -t "$IMAGE" "$ROOT_DIR/docker/php" > "$WORK/build.log"

assert_effective() {
    local log=$1 maximum=$2 start=$3 minimum=$4 spare=$5
    for pair in "pm.max_children = $maximum" "pm.start_servers = $start" \
        "pm.min_spare_servers = $minimum" "pm.max_spare_servers = $spare"; do
        grep -Fq "$pair" "$log" || fail "FPM did not load $pair"
    done
    grep -q 'test is successful' "$log" || fail 'FPM configuration check failed'
}

docker run --rm --network none --memory 1g "$IMAGE" php-fpm -tt > "$WORK/default.log" 2>&1
assert_effective "$WORK/default.log" 4 1 1 2
docker run --rm --network none --memory 2g -e PHP_FPM_MEMORY_PERCENT=50 \
    "$IMAGE" php-fpm -tt > "$WORK/budget.log" 2>&1
assert_effective "$WORK/budget.log" 16 4 2 8
docker run --rm --network none --memory 1g -e PHP_FPM_MAX_CHILDREN=12 \
    -e PHP_FPM_START_SERVERS=4 -e PHP_FPM_MIN_SPARE_SERVERS=2 -e PHP_FPM_MAX_SPARE_SERVERS=6 \
    "$IMAGE" php-fpm -tt > "$WORK/manual.log" 2>&1
assert_effective "$WORK/manual.log" 12 4 2 6
echo 'PASS: real FPM loads automatic, memory-capped and manual pool settings'

if docker run --rm --network none --memory 1g -e PHP_FPM_MAX_CHILDREN=2 \
    -e PHP_FPM_MIN_SPARE_SERVERS=3 "$IMAGE" php-fpm -tt > "$WORK/invalid.log" 2>&1; then
    fail 'entrypoint started FPM with contradictory settings'
fi
grep -q 'ERROR: PHP-FPM requires' "$WORK/invalid.log" || fail 'missing configuration error'
echo 'PASS: invalid pool settings stop startup with a useful error'

docker run --rm --network none --memory 1g -e PHP_FPM_MAX_CHILDREN=invalid \
    "$IMAGE" bash -c 'test ! -f /usr/local/etc/php-fpm.d/zz-kvs-pool.conf' > "$WORK/cli.log" 2>&1
echo 'PASS: maintenance commands do not configure or start the FPM pool'

docker run -d --name "$NAME" --network none --memory 1g "$IMAGE" > /dev/null
ready() {
    for _ in $(seq 1 50); do
        if docker exec "$NAME" bash -c 'exec 3<>/dev/tcp/127.0.0.1/9000' >/dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    docker logs "$NAME" >&2
    fail 'FPM did not start accepting connections'
}
ready
docker exec "$NAME" php-fpm -tt > "$WORK/before.log" 2>&1
assert_effective "$WORK/before.log" 4 1 1 2
docker exec "$NAME" cat /usr/local/etc/php-fpm.d/zz-kvs-pool.conf > "$WORK/before.conf"
docker restart "$NAME" >/dev/null
ready
docker exec "$NAME" php-fpm -tt > "$WORK/after.log" 2>&1
assert_effective "$WORK/after.log" 4 1 1 2
docker exec "$NAME" cat /usr/local/etc/php-fpm.d/zz-kvs-pool.conf > "$WORK/after.conf"
cmp "$WORK/before.conf" "$WORK/after.conf" || fail 'restart did not preserve calculated settings'
echo 'PASS: actual FPM starts, restarts and reloads the same generated pool'
