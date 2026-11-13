#!/bin/bash
# The cron image reports a KVS cron.php that fails, through its Docker
# health check and through the probe of kvsctl doctor. A cron.php that
# failed every minute used to leave the container healthy and doctor "ok":
# both looked at the cron daemon alone, cron.php writes its errors to
# /var/log/cron.log, not to the container's output, and it exits 0 on most
# of them (MariaDB down, its password refused, another host holding its
# cron registration).
#
#   tests/integration_cron_health.sh [cron image]
#
# The image is the argument, or KVS_CRON_TEST_IMAGE without one.
#
# The image runs as Compose runs it (init, no-new-privileges), on no
# network, with a synthetic site whose cron.php answers as KVS does in the
# case cron-mode names. In one container its own cron daemon runs the KVS
# task of the crontab, kvs-cron-run, every minute: a failed run and a
# completed one are recorded as www-data, the health check and the doctor
# probe report them, a record older than the limit or than a restart does
# not count, and an image without kvs-cron-health falls back to the daemon.
# In a second one, whose daemon has no KVS task, kvs-cron-run runs once per
# case, as the crontab runs it: what each kind of output counts as, the
# grace of "Duplicate cron operation" after a start, the files a killed run
# leaves, and a daemon that is gone. The health check is the one
# docker/docker-compose.yml declares, the doctor probe the one
# cli/internal/doctor/runtime.go sends. The docker images workflow runs
# this suite on the cron image it builds; the suite never pulls or builds
# an image.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT_DIR

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$#" -le 1 ] || fail "usage: $0 [cron image]"
readonly IMAGE=${1:-${KVS_CRON_TEST_IMAGE:-}}
[ -n "$IMAGE" ] || fail "name the cron image to test, as the argument or in KVS_CRON_TEST_IMAGE"
command -v docker >/dev/null 2>&1 || fail "docker is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
docker image inspect "$IMAGE" >/dev/null 2>&1 || fail "$IMAGE is not present"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-cron-health.XXXXXX")
readonly TEST_DIR
readonly NAME="kvs-cron-health-test-$$-$RANDOM"
readonly DAEMON="$NAME-daemon" DIRECT="$NAME-direct"
cleanup() {
    local status=$? container
    for container in "$DAEMON" "$DIRECT"; do
        if [ "$status" -ne 0 ]; then
            echo "--- $container" >&2
            docker logs "$container" >&2 2>&1 || true
            docker exec "$container" tail -n 20 /var/log/cron.log >&2 2>&1 || true
        fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    done
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# The health check of the cron service, as Compose renders it.
sed -e 's/^DOMAIN=.*/DOMAIN=example.test/' \
    -e 's/^MARIADB_ROOT_PASSWORD=.*/MARIADB_ROOT_PASSWORD=root-password/' \
    -e 's/^MARIADB_PASSWORD=.*/MARIADB_PASSWORD=kvs-password/' \
    "$ROOT_DIR/docker/.env.example" > "$TEST_DIR/env"
health_test=$(docker compose --env-file "$TEST_DIR/env" -f "$ROOT_DIR/docker/docker-compose.yml" \
    config --format json | jq -er '.services.cron.healthcheck.test |
        if .[0] == "CMD-SHELL" and length == 2 then .[1] else error("not a CMD-SHELL test") end') ||
    fail "the cron service has no CMD-SHELL health check"
# The probe kvsctl doctor runs in the cron container: the Go raw string.
# shellcheck disable=SC2016
probe=$(sed -n '/^const cronProbe = `/,/`$/p' "$ROOT_DIR/cli/internal/doctor/runtime.go" |
    sed -e '1s/^const cronProbe = `//' -e '$s/`$//')
[ -n "$probe" ] || fail "cronProbe not found in cli/internal/doctor/runtime.go"

# A site whose cron.php prints and exits as KVS 7.0.2 does in each case
# (its cron.php, encoded, measured with MariaDB down, a refused password,
# a registration held by another host, a missing loader). The [FATAL] line
# of KVS ends without a newline.
mkdir -p "$TEST_DIR/site/admin/include"
cat > "$TEST_DIR/site/admin/include/cron.php" <<'PHP'
<?php
switch (trim((string) @file_get_contents(__DIR__ . '/cron-mode'))) {
    case 'finished':
        echo "INFO  Executed cron_check_db process\nINFO  Finished\n";
        exit(0);
    case 'locked':
        echo "Already locked\n";
        exit(0);
    case 'unknown':
        echo "cron-health-test: a line KVS may print one day\n";
        exit(0);
    case 'fatal-db':
        echo "[FATAL]: can't connect to database defined in /admin/include/setup_db.php: Access denied";
        exit(0);
    case 'duplicate':
        echo "ERROR Duplicate cron operation: kvs-cron:/var/www/kvs / other-host:/var/www/kvs\n";
        exit(0);
    case 'loader':
        echo "Script error: the ionCube Loader for PHP needs to be installed.\n";
        exit(199);
    case 'sleep':
        sleep(60);
        exit(0);
    default:
        kvs_cron_health_test_undefined_function();
}
PHP
mode() {
    printf '%s\n' "$1" > "$TEST_DIR/site/admin/include/cron-mode"
}
mode fatal
: > "$TEST_DIR/no-kvs-task"
chmod -R a+rX "$TEST_DIR"

run_args=(--pull never --network none --init --security-opt no-new-privileges:true
    -e KVS_MEMCACHE_LOOPBACK=false -v "$TEST_DIR/site:/var/www/kvs:ro")
docker run -d --name "$DAEMON" "${run_args[@]}" "$IMAGE" >/dev/null ||
    fail "the cron container did not start"

# health <container> [docker exec options]: runs the health check; sets
# health_status and health_output.
health() {
    health_status=0
    health_output=$(docker exec "${@:2}" "$1" sh -c "$health_test") || health_status=$?
}

# doctor <container> [docker exec options]: runs the doctor probe; sets
# doctor_output.
doctor() {
    doctor_output=$(docker exec "${@:2}" "$1" sh -c "$probe") ||
        fail "the doctor probe failed: $doctor_output"
}

# wait_run <text>: until a run by the cron daemon has written the text to
# cron.log once more, and kvs-cron-run has recorded it.
wait_run() {
    local before attempt count
    before=$(docker exec "$DAEMON" grep -c -F -- "$1" /var/log/cron.log || true)
    for ((attempt = 0; attempt < 90; attempt++)); do
        count=$(docker exec "$DAEMON" grep -c -F -- "$1" /var/log/cron.log || true)
        if [ "${count:-0}" -gt "${before:-0}" ]; then
            # kvs-cron-run records the run right after the log.
            sleep 1
            return 0
        fi
        sleep 2
    done
    fail "the cron daemon did not run cron.php within 180 seconds"
}

# record <container> <file>: the modification time of a record, 0 when
# there is none.
record() {
    docker exec "$1" stat -c %Y "/var/lib/kvs-cron/$2" 2>/dev/null || echo 0
}

# --- the cron daemon runs kvs-cron-run ---

# A new container has five minutes to complete its first run.
health "$DAEMON"
[ "$health_status" -eq 0 ] && [[ "$health_output" == "cron.php has not completed a run yet"* ]] ||
    fail "a new container is not healthy while it waits for its first run: $health_status $health_output"
sleep 2
health "$DAEMON" -e KVS_CRON_MAX_AGE=1
[ "$health_status" -ne 0 ] &&
    [[ "$(head -n 1 <<<"$health_output")" == "cron.php has not completed a run since the container started "* ]] ||
    fail "a container past its first window with no completed run is healthy: $health_status $health_output"
echo "PASS: a new container is healthy for its first window only"

# cron.php dies with a fatal error, exit status 255.
wait_run 'kvs_cron_health_test_undefined_function'
[ "$(record "$DAEMON" last-success)" = 0 ] || fail "a failed cron.php recorded a completed run"
[ "$(docker exec "$DAEMON" stat -c %U /var/lib/kvs-cron/last-failure 2>/dev/null)" = www-data ] ||
    fail "the cron daemon did not record the failed run as www-data"
health "$DAEMON" -e KVS_CRON_MAX_AGE=1
[ "$health_status" -ne 0 ] &&
    [[ "$(sed -n 2p <<<"$health_output")" == "last failure "*" s ago, exit status 255: "*"Fatal error: "*kvs_cron_health_test_undefined_function* ]] ||
    fail "the health check did not report the fatal error of cron.php: $health_status $health_output"
doctor "$DAEMON" -e KVS_CRON_MAX_AGE=1
mapfile -t lines <<<"$doctor_output"
if [ "${#lines[@]}" -ne 3 ] || [ "${lines[0]}" != www-data ] ||
    [[ "${lines[1]}" != "failed cron.php has not completed a run since the container started"* ]] ||
    [[ "${lines[2]}" != "last failure "*"exit status 255: "*kvs_cron_health_test_undefined_function* ]]; then
    fail "the doctor probe did not report the failed run alone: $doctor_output"
fi
echo "PASS: a cron.php that dies is recorded as failed; the health check and doctor report its error"

# cron.php completes a run: recorded as www-data.
mode finished
wait_run 'INFO  Finished'
# The next runs fail again; the next one is a minute away.
mode fatal
[ "$(docker exec "$DAEMON" stat -c %U /var/lib/kvs-cron/last-success 2>/dev/null)" = www-data ] ||
    fail "a completed run was not recorded as www-data"
health "$DAEMON"
[ "$health_status" -eq 0 ] && [[ "$health_output" == "cron.php last completed a run "* ]] ||
    fail "the health check failed right after a completed run: $health_status $health_output"
doctor "$DAEMON"
[[ "$(sed -n 2p <<<"$doctor_output")" == "ok cron.php last completed a run "*" s ago" ]] ||
    fail "the doctor probe did not report the recent run: $doctor_output"
# Each run's output reaches cron.log whole, the earlier failure included.
for text in 'INFO  Finished' 'kvs_cron_health_test_undefined_function'; do
    docker exec "$DAEMON" grep -Fq -- "$text" /var/log/cron.log ||
        fail "cron.log lacks the output of the runs ($text)"
done
echo "PASS: a completed run is recorded; the health check and doctor pass"

# The last run grows old: unhealthy past the limit.
docker exec -u www-data "$DAEMON" sh -c 'touch -d "@$(( $(date +%s) - 45 ))" /var/lib/kvs-cron/last-success'
health "$DAEMON" -e KVS_CRON_MAX_AGE=30
[ "$health_status" -ne 0 ] && [[ "$(head -n 1 <<<"$health_output")" == *"more than 30 s"* ]] ||
    fail "a completed run older than the limit passed the health check: $health_status $health_output"
doctor "$DAEMON" -e KVS_CRON_MAX_AGE=30
[[ "$(sed -n 2p <<<"$doctor_output")" == "failed cron.php last completed a run "*"more than 30 s"* ]] ||
    fail "the doctor probe did not report the old run: $doctor_output"
echo "PASS: a completed run older than the limit fails the health check and doctor"

# A restart keeps the records, which predate the new start: the container
# has its first window again.
docker restart "$DAEMON" >/dev/null
health "$DAEMON" -e KVS_CRON_MAX_AGE=30
[ "$health_status" -eq 0 ] && [[ "$health_output" == "cron.php has not completed a run yet"* ]] ||
    fail "a restarted container judged by a record of its previous run: $health_status $health_output"
echo "PASS: a restarted container is judged from its own start"

# An image older than kvs-cron-health is probed through its daemon alone,
# and its crontab runs cron.php itself, which doctor still recognizes.
docker exec "$DAEMON" rm -f /usr/local/bin/kvs-cron-health
health "$DAEMON"
[ "$health_status" -eq 0 ] || fail "the health check fails on an image without kvs-cron-health: $health_output"
doctor "$DAEMON"
[ "$doctor_output" = www-data ] || fail "the doctor probe reported a result without kvs-cron-health: $doctor_output"
docker exec "$DAEMON" sh -c "printf '%s\n' '* * * * * www-data cd /var/www/kvs/admin/include && /usr/local/bin/php cron.php >> /var/log/cron.log 2>&1' > /etc/cron.d/kvs-cron"
doctor "$DAEMON"
[ "$doctor_output" = www-data ] || fail "the doctor probe does not recognize the schedule of an older image: $doctor_output"
echo "PASS: without kvs-cron-health, the health check and doctor fall back to the daemon and the schedule"
docker rm -f "$DAEMON" >/dev/null

# --- one run per case, as the crontab runs it ---

# The daemon of this container has no KVS task, so only the runs below
# write the records; it runs to be found by the health check.
docker run -d --name "$DIRECT" "${run_args[@]}" -v "$TEST_DIR/no-kvs-task:/etc/cron.d/kvs-cron:ro" \
    "$IMAGE" sleep infinity >/dev/null || fail "the second cron container did not start"
docker exec "$DIRECT" cron || fail "the cron daemon did not start in the second container"
sleep 2

# temporaries: how many temporary files kvs-cron-run left.
temporaries() {
    docker exec "$DIRECT" find /var/lib/kvs-cron -name '.run.*' | wc -l
}

# run_case <mode>: one run of kvs-cron-run as www-data, which leaves no
# temporary file behind; sets run_status.
run_case() {
    local left
    left=$(temporaries)
    mode "$1"
    run_status=0
    docker exec -u www-data "$DIRECT" /usr/local/bin/kvs-cron-run || run_status=$?
    [ "$(temporaries)" -le "$left" ] || fail "$1: the run left a temporary file in /var/lib/kvs-cron"
}

# expect_failed <mode> <exit status> <text>: the run fails, records no
# completed run but the failure with its status and the text, and the
# health check reports that line once no completed run is recent.
expect_failed() {
    local success
    success=$(record "$DIRECT" last-success)
    run_case "$1"
    [ "$run_status" -ne 0 ] || fail "$1: kvs-cron-run exited 0 for a failed run"
    [ "$(record "$DIRECT" last-success)" = "$success" ] || fail "$1: a failed run was recorded as completed"
    [[ "$(docker exec "$DIRECT" cat /var/lib/kvs-cron/last-failure)" == "$2 "*"$3"* ]] ||
        fail "$1: the failure was not recorded with exit status $2 and '$3': $(docker exec "$DIRECT" cat /var/lib/kvs-cron/last-failure)"
    # A limit of 0 s: a run completed a second ago is old already.
    sleep 1.1
    health "$DIRECT" -e KVS_CRON_MAX_AGE=0 -e KVS_CRON_DUPLICATE_GRACE=0
    [ "$health_status" -ne 0 ] &&
        [[ "$(sed -n 2p <<<"$health_output")" == "last failure "*" s ago, exit status $2: "*"$3"* ]] ||
        fail "$1: the health check did not report the failed run: $health_status $health_output"
}

# expect_completed <mode>: the run completes and is recorded, and the
# health check passes on that record, not on the first window.
expect_completed() {
    local before
    before=$(docker exec "$DIRECT" date +%s)
    run_case "$1"
    [ "$run_status" -eq 0 ] || fail "$1: kvs-cron-run exited $run_status for a completed run"
    [ "$(record "$DIRECT" last-success)" -ge "$before" ] || fail "$1: the completed run was not recorded"
    health "$DIRECT" -e KVS_CRON_MAX_AGE=30 -e KVS_CRON_DUPLICATE_GRACE=0
    [ "$health_status" -eq 0 ] && [[ "$health_output" == "cron.php last completed a run "* ]] ||
        fail "$1: the health check did not pass on the completed run: $health_status $health_output"
}

expect_failed fatal-db 0 "[FATAL]: can't connect to database"
[ -z "$(docker exec "$DIRECT" tail -c 1 /var/log/cron.log)" ] ||
    fail "the [FATAL] line of KVS was left without its newline in cron.log"
expect_failed fatal 255 'Fatal error: '
expect_failed loader 199 'Script error: the ionCube Loader'
echo "PASS: a [FATAL] line with exit status 0, a fatal error and any other non-zero exit fail the run"

expect_failed duplicate 0 'ERROR Duplicate cron operation'
health "$DIRECT" -e KVS_CRON_MAX_AGE=0
[ "$health_status" -eq 0 ] && [[ "$health_output" == *"(Duplicate cron operation), the container started "* ]] ||
    fail "a Duplicate cron operation within the grace after the start is not healthy: $health_status $health_output"
echo "PASS: a Duplicate cron operation is healthy for the grace after a start, unhealthy past it"

expect_completed finished
expect_completed locked
expect_completed unknown
# A completed run is newer than the last failure: once old, it is not
# reported with that failure.
sleep 1.1
health "$DIRECT" -e KVS_CRON_MAX_AGE=0 -e KVS_CRON_DUPLICATE_GRACE=0
[ "$health_status" -ne 0 ] && [ "$health_output" = "${health_output%%$'\n'*}" ] &&
    [[ "$health_output" == "cron.php last completed a run "*": see /var/log/cron.log" ]] ||
    fail "a failure older than the last completed run was reported: $health_status $health_output"
expect_failed fatal-db 0 "[FATAL]: can't connect to database"
echo "PASS: INFO Finished, Already locked and any other output with exit status 0 complete the run"

# A run killed on the way, as docker stop kills it, leaves its temporary
# output, which changes nothing; a later run removes one older than a day.
expect_completed finished
success=$(record "$DIRECT" last-success)
failure=$(docker exec "$DIRECT" cat /var/lib/kvs-cron/last-failure)
docker exec -u www-data "$DIRECT" touch -d '2 days ago' /var/lib/kvs-cron/.run.stale
mode sleep
docker exec -d -u www-data "$DIRECT" /usr/local/bin/kvs-cron-run
for ((attempt = 0; attempt < 30; attempt++)); do
    docker exec "$DIRECT" pgrep -f 'cron[.]php' >/dev/null && break
    sleep 0.5
done
docker exec "$DIRECT" pkill -KILL -f /usr/local/bin/kvs-cron-run || fail "the run to kill was not found"
docker exec "$DIRECT" pkill -KILL -f 'cron[.]php' || true
[ "$(docker exec "$DIRECT" find /var/lib/kvs-cron -name '.run.*' ! -name .run.stale | wc -l)" -ge 1 ] ||
    fail "the killed run left no temporary output: the case tests nothing"
[ "$(record "$DIRECT" last-success)" = "$success" ] &&
    [ "$(docker exec "$DIRECT" cat /var/lib/kvs-cron/last-failure)" = "$failure" ] ||
    fail "a killed run changed the records"
health "$DIRECT" -e KVS_CRON_MAX_AGE=30 -e KVS_CRON_DUPLICATE_GRACE=0
[ "$health_status" -eq 0 ] || fail "a killed run changed the health: $health_output"
expect_completed finished
docker exec "$DIRECT" test ! -e /var/lib/kvs-cron/.run.stale ||
    fail "a temporary output older than a day was not removed"
echo "PASS: a killed run leaves the records and the health as they were"

# The daemon is gone, though the container runs.
docker exec "$DIRECT" pkill -x cron
health "$DIRECT"
[ "$health_status" -ne 0 ] && [ "$health_output" = "the cron daemon is not running" ] ||
    fail "the health check passed without the cron daemon: $health_status $health_output"
echo "PASS: the health check fails without the cron daemon"

echo "All cron health checks passed"
