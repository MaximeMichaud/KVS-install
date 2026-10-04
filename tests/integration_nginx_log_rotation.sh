#!/bin/bash
# Optional real-Nginx proof of the site log rotation: requests keep arriving
# while the site logs rotate, and each one is found exactly once in the
# generations, before and after a container restart. It needs a local Nginx
# image with curl (NGINX_TEST_IMAGE), never pulls one and runs without network.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NGINX_TEST_IMAGE=${NGINX_TEST_IMAGE:-nginx:alpine}
docker image inspect "$NGINX_TEST_IMAGE" >/dev/null
TEST_DIR=$(mktemp -d /tmp/kvs-nginx-log-rotation.XXXXXX)
container="kvs-nginx-log-rotation-$RANDOM-$$"
cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        docker logs "$container" 2>/dev/null >&2 || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

install -m 0755 "$ROOT_DIR/docker/nginx/rotate-site-logs.sh" "$TEST_DIR/rotate-site-logs"
# The site logs as the KVS templates write them; /missing/ adds an error line
# per request.
cat > "$TEST_DIR/nginx.conf" <<'NGINX'
user nginx;
pid /run/nginx.pid;
worker_processes 4;
events { worker_connections 1024; }
http {
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log warn;
    server {
        listen 127.0.0.1:8080;
        access_log /var/log/nginx/example.com.access.log;
        error_log /var/log/nginx/example.com.error.log warn;
        root /nonexistent;
        location /ok/ { return 204; }
    }
}
NGINX

docker run -d --name "$container" --pull never --network none \
    -e NGINX_LOG_MAX_SIZE=32k -e NGINX_LOG_KEEP=200 -e NGINX_LOG_CHECK_INTERVAL=1 \
    -v "$TEST_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$TEST_DIR/rotate-site-logs:/usr/local/bin/rotate-site-logs:ro" \
    --entrypoint /bin/sh "$NGINX_TEST_IMAGE" \
    -c '/usr/local/bin/rotate-site-logs & exec nginx -g "daemon off;"' >/dev/null

# Sends batches of requests from four clients at once, over several check
# intervals: /ok/<client>/<n> and /missing/<client>/<n> alternate.
send_requests() {
    local pass="$1"

    docker exec -e PASS="$pass" "$container" sh -c '
        for client in a b c d; do
            (
                batch=0
                while [ "$batch" -lt 12 ]; do
                    first=$((batch * 50 + 1))
                    last=$((first + 49))
                    curl -s "http://127.0.0.1:8080/{ok,missing}/${PASS}${client}/[${first}-${last}]" >/dev/null
                    batch=$((batch + 1))
                    sleep 0.3
                done
            ) &
        done
        wait
    '
}

# Puts every generation of a log back together, oldest first, once the last
# one has been compressed.
collect() {
    docker exec -e LOG="$1" "$container" sh -c '
        cd /var/log/nginx
        generation=200
        while [ "$generation" -ge 1 ]; do
            if [ -f "${LOG}.${generation}.gz" ]; then gzip -dc "${LOG}.${generation}.gz"; fi
            generation=$((generation - 1))
        done
        if [ -f "${LOG}.1" ]; then cat "${LOG}.1"; fi
        cat "$LOG"
    '
}

# Each request of a pass must be in the access logs once, and each /missing/
# one in the error logs once.
assert_each_request_once() {
    local pass="$1"
    local expected=2400
    local kind

    collect example.com.access.log > "$TEST_DIR/access.log"
    collect example.com.error.log > "$TEST_DIR/error.log"
    for kind in ok missing error; do
        if [ "$kind" = error ]; then
            sed -n "s|.*open() \"/nonexistent/missing/\\(${pass}[a-d]/[0-9]*\\)\" failed.*|\\1|p" \
                "$TEST_DIR/error.log"
        else
            sed -n "s|.*\"GET /${kind}/\\(${pass}[a-d]/[0-9]*\\) HTTP.*|\\1|p" "$TEST_DIR/access.log"
        fi | sort | uniq -c > "$TEST_DIR/${kind}.counts"
        [ "$(wc -l < "$TEST_DIR/${kind}.counts")" -eq "$expected" ] ||
            fail "pass ${pass}: $(wc -l < "$TEST_DIR/${kind}.counts") of ${expected} ${kind} lines are in the logs"
        if awk '$1 != 1' "$TEST_DIR/${kind}.counts" | grep -q .; then
            fail "pass ${pass}: a ${kind} line is logged more than once"
        fi
    done
}

compressed_generations() {
    docker exec "$container" sh -c 'ls /var/log/nginx | grep -c "^example\.com\.access\.log\.[0-9]*\.gz$"' || true
}

# Waits until no rotation is pending: every rotated log is compressed and the
# live logs are under the limit, so that the generations stay put.
wait_until_settled() {
    local attempt

    for attempt in $(seq 1 60); do
        if docker exec "$container" sh -c '
            cd /var/log/nginx
            for log in example.com.access.log example.com.error.log; do
                [ ! -e "${log}.1" ] && [ "$(stat -c %s "$log")" -lt 32768 ] || exit 1
            done
        '; then
            return 0
        fi
        sleep 0.5
    done
    fail "the rotation did not settle after ${attempt} attempts"
}

sleep 1
send_requests 1
wait_until_settled
assert_each_request_once 1
generations=$(compressed_generations)
[ "$generations" -ge 3 ] || fail "the access log rotated ${generations} times under load"

# After a restart, the rotation carries on from the files it left.
docker restart "$container" >/dev/null
sleep 1
send_requests 2
wait_until_settled
assert_each_request_once 2
assert_each_request_once 1
[ "$(compressed_generations)" -gt "$generations" ] || fail "the rotation did not resume after a restart"

docker exec "$container" sh -c '[ -L /var/log/nginx/access.log ] && [ -L /var/log/nginx/error.log ]' ||
    fail "the links to the container output were touched"
if docker logs "$container" 2>&1 | grep -q 'WARNING'; then
    fail "the rotation reported a problem: $(docker logs "$container" 2>&1 | grep WARNING | head -n 1)"
fi
echo "PASS: Nginx site logs rotate under load without losing a line ($NGINX_TEST_IMAGE)"
