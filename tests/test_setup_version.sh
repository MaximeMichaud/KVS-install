#!/bin/bash
# shellcheck disable=SC2016  # The patterns are literal code of setup.sh.
# The setup header and the file transfer line name the version that runs: a
# server left on an older one shows it in the lines an operator copies from
# the terminal. A release kvsctl laid names itself in docker/RELEASE, a git
# checkout gives its commit, and anything else leaves the lines as they were.
set -euo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-version.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The version code of setup.sh, run from a docker/ directory like the real one.
probe() {
    mkdir -p "$1/docker"
    {
        awk '$0 == "kvs_install_version() {" { capture = 1 } capture { print } capture && /^}$/ { exit }' \
            "$ROOT_DIR/docker/setup.sh"
        grep -Fx 'KVS_INSTALL_VERSION=$(kvs_install_version)' "$ROOT_DIR/docker/setup.sh"
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

# A checkout kvsctl upgraded holds the files of a release, which names
# itself on the first line of docker/RELEASE; the commit is the old one.
printf '26.10.0\n' > "$TEST_DIR/checkout/docker/RELEASE"
[ "$(probe "$TEST_DIR/checkout")" = 26.10.0 ] ||
    fail "a release in a checkout must read 26.10.0, got '$(probe "$TEST_DIR/checkout")'"
printf '26.11.0-rc1\r\nmore lines a release may add\n' > "$TEST_DIR/checkout/docker/RELEASE"
[ "$(probe "$TEST_DIR/checkout")" = 26.11.0-rc1 ] ||
    fail "only the first line of docker/RELEASE counts, got '$(probe "$TEST_DIR/checkout")'"
printf '26.12.0' > "$TEST_DIR/plain/docker/RELEASE"
[ "$(probe "$TEST_DIR/plain")" = 26.12.0 ] ||
    fail "a release outside a checkout must read 26.12.0, got '$(probe "$TEST_DIR/plain")'"
# The header prints it with echo -e: a line that is no version name is
# ignored, and so is an empty one.
printf '\\e[2J 26.10.0\n' > "$TEST_DIR/checkout/docker/RELEASE"
[ "$(probe "$TEST_DIR/checkout")" = "$expected" ] ||
    fail "a docker/RELEASE that names no version must fall back to the commit, got '$(probe "$TEST_DIR/checkout")'"
: > "$TEST_DIR/plain/docker/RELEASE"
[ -z "$(probe "$TEST_DIR/plain")" ] || fail "an empty docker/RELEASE outside a checkout must leave the version empty"

grep -Fq '=== KVS Docker Setup${KVS_INSTALL_VERSION:+ (kvs-install $KVS_INSTALL_VERSION)} ===' "$ROOT_DIR/docker/setup.sh" ||
    fail "the setup header must show the version"
grep -Fq 'Transferring the site files from $IMPORT_SSH_TARGET:$IMPORT_REMOTE_DIR${KVS_INSTALL_VERSION:+ (kvs-install $KVS_INSTALL_VERSION)}...' "$ROOT_DIR/docker/setup.sh" ||
    fail "the file transfer line must show the version"
echo "PASS: the setup header and the transfer line name the release or the commit that runs"
