#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-compose-oneshot.XXXXXX)
PROJECT_NAME="kvs-oneshot-$$"

cleanup() {
    docker compose -p "$PROJECT_NAME" -f "$TEST_DIR/compose.yml" down -v \
        --remove-orphans >/dev/null 2>&1 || true
    docker network ls -q \
        --filter "label=com.docker.compose.project=${PROJECT_NAME}" | \
        xargs -r docker network rm >/dev/null 2>&1 || true
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker is required"
# The Alpine image the release pins for phpmyadmin-init, pulled when this
# machine lacks it, rather than whatever alpine:latest happens to be cached.
ALPINE_IMAGE=$("$ROOT_DIR/docker/bin/resolve-bases.sh" --get alpine -)
docker image inspect "$ALPINE_IMAGE" >/dev/null 2>&1 ||
    docker pull -q "$ALPINE_IMAGE" >/dev/null ||
    fail "the Alpine image $ALPINE_IMAGE is neither on this machine nor pullable"

cat > "$TEST_DIR/compose.yml" <<EOF
services:
  phpmyadmin-init:
    image: ${ALPINE_IMAGE}
    pull_policy: never
    network_mode: none
    command: ["sh", "-c", "exit 42"]
    profiles: ["setup"]
  kvs-init:
    image: ${ALPINE_IMAGE}
    pull_policy: never
    network_mode: none
    command: ["sh", "-c", "exit 43"]
    profiles: ["setup"]
EOF

set +e
docker compose -p "$PROJECT_NAME" -f "$TEST_DIR/compose.yml" \
    --profile setup run --rm --no-deps phpmyadmin-init >/dev/null 2>&1
phpmyadmin_status=$?
docker compose -p "$PROJECT_NAME" -f "$TEST_DIR/compose.yml" \
    --profile setup run --rm --no-deps kvs-init >/dev/null 2>&1
kvs_status=$?
set -e

[ "$phpmyadmin_status" -eq 42 ] ||
    fail "phpMyAdmin one-shot exit 42 became ${phpmyadmin_status}"
[ "$kvs_status" -eq 43 ] || fail "KVS one-shot exit 43 became ${kvs_status}"
if docker ps -aq --filter "label=com.docker.compose.project=${PROJECT_NAME}" | grep -q .; then
    fail "a disposable one-shot container remained after --rm"
fi

grep -Eq 'docker compose --profile setup run --rm --no-deps .*phpmyadmin-init$' \
    "$ROOT_DIR/docker/setup.sh" || fail "setup does not use a checked phpMyAdmin one-shot"
grep -Eq 'docker compose --profile setup run --rm --no-deps .*kvs-init$' \
    "$ROOT_DIR/docker/setup.sh" || fail "setup does not use a checked KVS one-shot"
grep -Fq 'docker compose --profile setup run --rm --no-deps phpmyadmin-init' \
    "$ROOT_DIR/docker/multi-site/site-manager.sh" ||
    fail "the multi-site manager does not use a checked phpMyAdmin one-shot"
grep -Fq 'docker compose --profile setup run --rm --no-deps kvs-init' \
    "$ROOT_DIR/docker/multi-site/site-manager.sh" ||
    fail "the multi-site manager does not use a checked KVS one-shot"

echo "PASS: Compose one-shot failure propagation"
