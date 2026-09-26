#!/bin/bash
# Optional local proof that resume init commands use valid Compose run options.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_image=${COMPOSE_TEST_IMAGE:-alpine:3.24}
if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint=$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')
else
    endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
fi
case "$endpoint" in
    unix://*) ;;
    *) echo 'ERROR: this integration test requires a local Docker socket' >&2; exit 1 ;;
esac
docker image inspect "$source_image" >/dev/null
fixture=$(mktemp -d /tmp/kvs-resume-compose.XXXXXX)
export COMPOSE_PROJECT_NAME="kvs-resume-compose-$RANDOM-$$"
export COMPOSE_FILE="$fixture/compose.yml"
export COMPOSE_TEST_IMAGE="127.0.0.1:9/$COMPOSE_PROJECT_NAME:latest"
build_image="$COMPOSE_PROJECT_NAME-kvs-init:latest"

cleanup() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        for logfile in "$fixture"/*.log; do
            [ ! -f "$logfile" ] || tail -n 20 "$logfile" >&2
        done
    fi
    docker compose --profile setup down -v >/dev/null 2>&1 || true
    docker image rm "$build_image" >/dev/null 2>&1 || true
    docker image rm "$COMPOSE_TEST_IMAGE" >/dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Execute the actual setup commands, including their current resume flags.
python3 - "$root/docker/setup.sh" "$fixture/commands.sh" <<'PY'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
resume = re.search(r'^setup_resume_import\(\) \{\n(.*?)^\}', source, re.M | re.S)
assert resume, 'missing resume helper'
flags = re.findall(r'^\s*(SETUP_RUN_FLAGS=\([^\n]*\))\s*$', resume[1], re.M)
assert len(flags) == 1, 'ambiguous resume run options'
commands = re.findall(
    r'^\s*(docker compose --profile setup run --rm --no-deps '
    r'"\$\{SETUP_RUN_FLAGS\[@\]\}" (phpmyadmin-init|kvs-init))\s*$', source, re.M)
assert {name for _, name in commands} == {'phpmyadmin-init', 'kvs-init'}
assert len(commands) == 2, 'ambiguous init run commands'
with pathlib.Path(sys.argv[2]).open('w') as output:
    output.write(flags[0] + '\n')
    for name in ('setup_resume_docker_query', 'setup_resume_require_init_image'):
        helper = re.search(r'^' + name + r'\(\) \{\n.*?^\}', source, re.M | re.S)
        assert helper, 'missing init image guard helper: ' + name
        output.write(helper[0] + '\n')
    for command, name in commands:
        output.write('run_' + name.replace('-', '_') + '() {\n    ' + command + '\n}\n')
PY
# shellcheck source=/dev/null
source "$fixture/commands.sh"
mkdir "$fixture/output" "$fixture/build"
chmod 777 "$fixture/output"
# A build attempt fails at Dockerfile parsing, before any image or network use.
printf 'FROM scratch\nKVS_TEST_MUST_NOT_BUILD\n' > "$fixture/build/Dockerfile"
cat > "$COMPOSE_FILE" <<'YAML'
services:
  mariadb:
    image: ${COMPOSE_TEST_IMAGE}
    network_mode: none
    mem_limit: 32m
    command: [sh, -c, "echo started > /output/database-started; sleep 60"]
    volumes: ["./output:/output"]
  phpmyadmin-init:
    image: ${COMPOSE_TEST_IMAGE}
    pull_policy: always
    network_mode: none
    mem_limit: 32m
    command: [sh, -c, "echo phpmyadmin-init >> /output/initialized"]
    volumes: ["./output:/output"]
    depends_on: [mariadb]
    profiles: [setup]
  kvs-init:
    build: ./build
    pull_policy: build
    network_mode: none
    mem_limit: 32m
    command: [sh, -c, "echo kvs-init >> /output/initialized"]
    volumes: ["./output:/output"]
    depends_on: [mariadb]
    profiles: [setup]
YAML
# Even a pull regression can only contact loopback, never an external registry.
docker image tag "$source_image" "$COMPOSE_TEST_IMAGE"
docker image tag "$source_image" "$build_image"
image_before=$(docker image inspect --format '{{.Id}}' "$build_image")

# Reproduce the rejected option independently of the fixed production flags.
for service in phpmyadmin-init kvs-init; do
    if docker compose --profile setup run --rm --no-deps --no-build --pull never \
        "$service" > "$fixture/baseline-$service.log" 2>&1; then
        fail "the obsolete --no-build option unexpectedly succeeded for $service"
    fi
    grep -Fq 'unknown flag: --no-build' "$fixture/baseline-$service.log" ||
        fail "the baseline did not reproduce the Compose parser failure for $service"
done
echo 'PASS: both original init commands reproduce the unsupported --no-build option.'

setup_resume_require_init_image > "$fixture/cached-image.log" 2>&1
run_phpmyadmin_init > "$fixture/phpmyadmin.log" 2>&1
[ "$(cat "$fixture/output/initialized")" = phpmyadmin-init ] || fail 'phpMyAdmin init did not execute'
[ -z "$(docker compose ps -a -q mariadb)" ] || fail 'phpMyAdmin init created the database dependency'
run_kvs_init > "$fixture/kvs.log" 2>&1
[ "$(cat "$fixture/output/initialized")" = $'phpmyadmin-init\nkvs-init' ] || fail 'KVS init did not execute once'
[ -z "$(docker compose ps -a -q mariadb)" ] || fail 'KVS init created the database dependency'
[ ! -e "$fixture/output/database-started" ] || fail 'the database dependency ran'
[ "$(docker image inspect --format '{{.Id}}' "$build_image")" = "$image_before" ] || fail 'the cached build image changed'
echo 'PASS: actual setup init commands execute with cached images, without starting MariaDB, pulling or building.'

# Only remove this test's unique image tag; the original cached image remains.
docker image rm "$build_image" >/dev/null
if setup_resume_require_init_image > "$fixture/missing-image.log" 2>&1; then
    fail 'resume accepted an unavailable KVS initialization image'
fi
grep -Fq 'recovery will not rebuild it' "$fixture/missing-image.log" || fail 'the missing image was not clearly reported'
[ "$(cat "$fixture/output/initialized")" = $'phpmyadmin-init\nkvs-init' ] || fail 'the failed guard ran another initializer'
[ -z "$(docker compose ps -a -q mariadb)" ] || fail 'the failed guard changed the database dependency'
if docker image inspect "$build_image" >/dev/null 2>&1; then
    fail 'the failed guard recreated the missing initialization image'
fi
echo 'PASS: the actual preflight guard refuses a missing KVS image without building or running another service.'
