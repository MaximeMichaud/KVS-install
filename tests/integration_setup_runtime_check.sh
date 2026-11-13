#!/bin/bash
# shellcheck disable=SC2034  # Variables are read by the extracted code of setup.sh.
# Real-Docker proof of setup_verify_runtime_services, the check setup.sh
# runs before it calls itself complete (H5). tests/test_setup_runtime_check.sh
# drives it through a Docker stand-in; this suite runs the functions of
# docker/setup.sh as written against containers of a Compose project, so
# the inspect format, the oneoff label of docker compose run and docker exec
# are the ones Docker answers:
#
#   ok         runs, with a healthcheck that passes
#   crash      exits 78 after a second and restarts in a loop, with no
#              healthcheck: a look right after its start finds it running
#   manticore  runs, with a healthcheck that fails (searchd not up yet),
#              unhealthy after a start period of 1 s
#   lone       never started, only a container of docker compose run
#
# The services run the Alpine of docker/images.lock, which
# tests/run-integration.sh pulls first: this suite never pulls. They have
# no network and publish no port; the project is removed at the end.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SETUP="$ROOT_DIR/docker/setup.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "docker is required"
image=$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get alpine)
docker image inspect "$image" >/dev/null 2>&1 || fail "$image is not on this machine (tests/run-integration.sh pulls it)"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kvs-setup-runtime-integration.XXXXXX")
export COMPOSE_PROJECT_NAME="kvs-setup-runtime-$$-$RANDOM"
export COMPOSE_FILE="$TEST_DIR/compose.yml"

cleanup() {
    local status=$?

    if [ "$status" -ne 0 ]; then
        docker compose ps -a >&2 2>&1 || true
    fi
    docker compose down -t 0 --remove-orphans >/dev/null 2>&1 || true
    docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" |
        xargs -r docker rm -f >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cat > "$COMPOSE_FILE" <<YML
services:
  ok:
    image: $image
    network_mode: none
    pull_policy: never
    restart: unless-stopped
    command: ["sleep", "600"]
    healthcheck:
      test: ["CMD", "true"]
      interval: 1s
      timeout: 1s
      retries: 1
  crash:
    image: $image
    network_mode: none
    pull_policy: never
    restart: unless-stopped
    command: ["sh", "-c", "sleep 1; exit 78"]
  manticore:
    image: $image
    network_mode: none
    pull_policy: never
    restart: unless-stopped
    command: ["sleep", "600"]
    healthcheck:
      test: ["CMD", "false"]
      interval: 1s
      timeout: 1s
      retries: 1
      start_period: 1s
  lone:
    image: $image
    network_mode: none
    pull_policy: never
    command: ["true"]
YML

extract_function() {
    awk -v signature="$1() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$SETUP"
}
{
    extract_function setup_verify_runtime_services
    extract_function setup_manticore_builds
} > "$TEST_DIR/functions.sh"
grep -q '^setup_manticore_builds() {' "$TEST_DIR/functions.sh" || fail "setup.sh has no setup_manticore_builds"
# shellcheck source=/dev/null
source "$TEST_DIR/functions.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/docker/lib/database.sh"
SETUP_RUNTIME_WAIT_SECONDS=30
SETUP_CRON_PENDING=false

# check <up|down> <description> <expected error or ''> <service...>
check() {
    local want="$1" description="$2" expected="$3" status=0
    shift 3

    SETUP_RUNTIME_SERVICES=("$@")
    setup_verify_runtime_services > "$TEST_DIR/out" 2>&1 || status=$?
    if [ "$want" = up ]; then
        [ "$status" -eq 0 ] || fail "$description: taken for down: $(cat "$TEST_DIR/out")"
    else
        [ "$status" -ne 0 ] || fail "$description: taken for up: $(cat "$TEST_DIR/out")"
        grep -Eq "^ERROR: $expected\$" "$TEST_DIR/out" ||
            fail "$description: the error must match '$expected': $(cat "$TEST_DIR/out")"
    fi
}

docker compose up -d --pull never ok manticore >/dev/null 2>&1 || fail "the services did not start"
manticore=$(docker compose ps -a -q manticore)
for _ in $(seq 1 60); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' "$manticore")" != unhealthy ] || break
    command sleep 0.5
done
[ "$(docker inspect --format '{{.State.Health.Status}}' "$manticore")" = unhealthy ] ||
    fail "the manticore stand-in never turned unhealthy"
for _ in $(seq 1 60); do
    [ "$(docker inspect --format '{{.State.Health.Status}}' "$(docker compose ps -a -q ok)")" != healthy ] || break
    command sleep 0.5
done

check up "a service that runs and is healthy" '' ok
# Checked right after its start, as setup.sh checks what it started.
for attempt in 1 2 3; do
    docker compose up -d --force-recreate --pull never crash >/dev/null 2>&1 || fail "crash did not start"
    check down "a service in a restart loop (attempt $attempt)" \
        'the crash container restarts \(exit code [0-9]+, [0-9]+ restarts\)\.' crash
done

# Without --rm, docker compose run leaves an exited one-off container of
# the service, as does a run --rm cut short.
docker compose run --no-deps --pull never ok true >/dev/null 2>&1 || fail "the one-off container did not run"
[ "$(docker compose ps -a -q ok | wc -l)" -eq 2 ] || fail "docker compose ps does not list the one-off container"
check up "a service beside an exited one-off container" '' ok
docker compose run --no-deps --pull never lone >/dev/null 2>&1 || fail "the one-off lone container did not run"
[ -n "$(docker compose ps -a -q lone)" ] || fail "docker compose ps does not list the one-off lone container"
check down "a service with a one-off container only" 'the lone service has no container\.' lone

check down "Manticore unhealthy, no build" 'the manticore container is unhealthy: its healthcheck fails\.' manticore
docker exec "$manticore" sh -c 'mkdir -p /var/run/manticore && : > /var/run/manticore/kvs-requested-build'
check up "Manticore unhealthy while its start builds every index" '' ok manticore
docker exec "$manticore" sh -c ': > /var/run/manticore/kvs-build-failed'
check down "Manticore with a failed build recorded" 'the manticore container is unhealthy: its healthcheck fails\.' manticore
docker exec "$manticore" sh -c 'rm /var/run/manticore/kvs-build-failed && : > /var/run/manticore/kvs-rebuild-failed'
check down "Manticore with a failed rebuild recorded" 'the manticore container is unhealthy: its healthcheck fails\.' manticore
docker exec "$manticore" sh -c 'rm /var/run/manticore/kvs-rebuild-failed'
check up "Manticore building again" '' manticore

echo "PASS: the runtime check reads real containers: restart loops, one-off containers and a Manticore build"
