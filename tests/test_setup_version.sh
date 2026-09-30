#!/bin/bash
# shellcheck disable=SC2016  # The patterns are literal code of setup.sh.
# The setup header and the file transfer line name the commit that runs: a
# server left on an older checkout shows it in the lines an operator copies
# from the terminal. Outside a git checkout the lines stay as they were.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-version.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The assignment of setup.sh, run from a docker/ directory like the real one.
probe() {
    mkdir -p "$1/docker"
    {
        awk '/^KVS_INSTALL_VERSION=/ { capture = 1 } capture { print } capture && /KVS_INSTALL_VERSION=""$/ { exit }' \
            "$ROOT_DIR/docker/setup.sh"
        printf '%s\n' 'echo "$KVS_INSTALL_VERSION"'
    } > "$1/docker/version.sh"
    bash "$1/docker/version.sh"
}

git init -q "$TEST_DIR/checkout"
git -C "$TEST_DIR/checkout" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m one
GIT_COMMITTER_DATE='2026-01-02T03:04:05Z' git -C "$TEST_DIR/checkout" -c user.name=test -c user.email=test@example.com \
    commit -q --allow-empty -m two
expected="$(git -C "$TEST_DIR/checkout" rev-parse --short HEAD), 2026-01-02"
[ "$(probe "$TEST_DIR/checkout")" = "$expected" ] || fail "the version of a checkout must read '$expected', got '$(probe "$TEST_DIR/checkout")'"
[ -z "$(probe "$TEST_DIR/plain")" ] || fail "outside a git checkout the version must stay empty"
grep -Fq '=== KVS Docker Setup${KVS_INSTALL_VERSION:+ (kvs-install $KVS_INSTALL_VERSION)} ===' "$ROOT_DIR/docker/setup.sh" ||
    fail "the setup header must show the version"
grep -Fq 'Transferring the site files from $IMPORT_SSH_TARGET:$IMPORT_REMOTE_DIR${KVS_INSTALL_VERSION:+ (kvs-install $KVS_INSTALL_VERSION)}...' "$ROOT_DIR/docker/setup.sh" ||
    fail "the file transfer line must show the version"
echo "PASS: the setup header and the transfer line name the commit that runs"
