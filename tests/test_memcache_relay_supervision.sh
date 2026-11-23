#!/bin/bash
set -euo pipefail

# The PHP-FPM and cron entrypoints start a socat relay from 127.0.0.1 to the
# cache service and then exec the container's main process. These cases run
# the function of each entrypoint the same way, with a stub socat, and stop
# the relay to see what happens to it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
RUNNING=()

cleanup() {
    local group
    for group in "${RUNNING[@]}"; do
        kill -KILL -- "-$group" 2>/dev/null || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# wait_lines <file> <count>: until the file holds that many lines.
wait_lines() {
    local file=$1 count=$2 attempt
    for ((attempt = 0; attempt < 300; attempt++)); do
        [ "$(wc -l < "$file")" -lt "$count" ] || return 0
        sleep 0.1
    done
    return 1
}

mkdir "$TEST_DIR/bin"
# Each relay start is one line: its PID and its arguments. The relay then
# runs until it is stopped, or ends at once with SOCAT_STUB_STATUS.
cat > "$TEST_DIR/bin/socat" <<'STUB'
#!/bin/bash
printf '%s %s\n' "$$" "$*" >> "$SOCAT_STUB_LOG"
[ -z "${SOCAT_STUB_STATUS:-}" ] || exit "$SOCAT_STUB_STATUS"
exec sleep 300
STUB
# The entrypoint asks PHP whether the loopback port already answers.
cat > "$TEST_DIR/bin/php" <<'STUB'
#!/bin/bash
exit "${PHP_STUB_STATUS:-1}"
STUB
chmod +x "$TEST_DIR/bin/socat" "$TEST_DIR/bin/php"

# start_entrypoint <image> <case>: the function of that entrypoint, then
# the exec that ends it, in a process group of its own.
start_entrypoint() {
    local image=$1 name=$2
    local dir="$TEST_DIR/$image-$name"

    mkdir "$dir"
    : > "$dir/socat.log"
    {
        echo 'set -e'
        sed -n '/^start_memcache_loopback() {$/,/^}$/p' "$ROOT_DIR/docker/$image/docker-entrypoint.sh"
        echo 'start_memcache_loopback'
        echo 'exec sleep 300'
    } > "$dir/entrypoint.sh"
    grep -Fq 'socat "TCP4-LISTEN:' "$dir/entrypoint.sh" ||
        fail "$image: start_memcache_loopback could not be read from the entrypoint"
    PATH="$TEST_DIR/bin:$PATH" SOCAT_STUB_LOG="$dir/socat.log" \
        setsid bash "$dir/entrypoint.sh" > "$dir/out" 2> "$dir/err" &
    RUNNING+=("$!")
    CASE_DIR=$dir
}

relay='TCP4-LISTEN:11300,bind=127.0.0.1,reuseaddr,fork TCP:cache.test:11300'
for image in php cron; do
    # A relay that is stopped, twice, is started again both times with the
    # same route, after the entrypoint's exec, and each stop is reported.
    KVS_MEMCACHE_HOST=cache.test KVS_MEMCACHE_PORT=11300 start_entrypoint "$image" stopped
    wait_lines "$CASE_DIR/socat.log" 1 || fail "$image: the relay was not started"
    grep -Fxq 'Memcache loopback: 127.0.0.1:11300 -> cache.test:11300' "$CASE_DIR/out" ||
        fail "$image: the relay route was not announced"
    for stop in 1 2; do
        read -r relay_pid _ < <(sed -n "${stop}p" "$CASE_DIR/socat.log")
        kill -TERM "$relay_pid"
        wait_lines "$CASE_DIR/socat.log" $((stop + 1)) ||
            fail "$image: the relay was not started again after stop $stop"
    done
    [ "$(cut -d ' ' -f 2- "$CASE_DIR/socat.log" | sort -u)" = "$relay" ] ||
        fail "$image: a relay was started with another route: $(cat "$CASE_DIR/socat.log")"
    [ "$(cut -d ' ' -f 1 "$CASE_DIR/socat.log" | sort -u | wc -l)" -eq 3 ] ||
        fail "$image: the three relays were not three processes"
    [ "$(grep -Fxc 'WARNING: the Memcache loopback 127.0.0.1:11300 stopped (status 143), starting it again in 2 seconds' \
        "$CASE_DIR/err")" -eq 2 ] ||
        fail "$image: the two relay stops were not reported: $(cat "$CASE_DIR/err")"

    # A relay that cannot run is not started in a tight loop: no more than
    # one start every two seconds, and its status is reported.
    started=$(date +%s)
    SOCAT_STUB_STATUS=7 KVS_MEMCACHE_HOST=cache.test KVS_MEMCACHE_PORT=11300 \
        start_entrypoint "$image" failing
    wait_lines "$CASE_DIR/socat.log" 2 || fail "$image: a failing relay was not started again"
    sleep 1
    starts=$(wc -l < "$CASE_DIR/socat.log")
    elapsed=$(($(date +%s) - started + 1))
    [ "$starts" -le $((elapsed / 2 + 1)) ] ||
        fail "$image: a failing relay was started $starts times in $elapsed seconds"
    grep -Fxq 'WARNING: the Memcache loopback 127.0.0.1:11300 stopped (status 7), starting it again in 2 seconds' \
        "$CASE_DIR/err" || fail "$image: the status of a failing relay was not reported"

    # Nothing is started, and so nothing supervised, when the loopback is
    # turned off or when the port already answers.
    KVS_MEMCACHE_LOOPBACK=false start_entrypoint "$image" disabled
    PHP_STUB_STATUS=0 start_entrypoint "$image" listening
    sleep 3
    [ ! -s "$TEST_DIR/$image-disabled/socat.log" ] ||
        fail "$image: a relay was started with KVS_MEMCACHE_LOOPBACK=false"
    [ ! -s "$TEST_DIR/$image-listening/socat.log" ] ||
        fail "$image: a relay was started on a port that already answers"
    echo "PASS: the $image entrypoint starts a stopped Memcache loopback relay again"
done

echo "PASS: Memcache relay supervision"
