#!/bin/bash
# shellcheck disable=SC2034  # Variables are consumed by extracted production functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-php.XXXXXX)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

extract_function() {
    local name="$1"

    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$ROOT_DIR/docker/setup.sh"
}

functions_file="$TEST_DIR/functions.sh"
{
    grep -m1 '^readonly SUPPORTED_PHP_VERSIONS=' "$ROOT_DIR/docker/setup.sh"
    extract_function php_version_is_supported
    extract_function kvs_documented_php_version
    extract_function select_php_version
} > "$functions_file"
# shellcheck source=/dev/null
source "$functions_file"

RED=''
GREEN=''
YELLOW=''
CYAN=''
NC=''

# The production function persists through set_env_value; record instead.
set_env_value() {
    printf '%s=%s\n' "$1" "$2" > "$TEST_DIR/applied"
}

applied_version() {
    [ -f "$TEST_DIR/applied" ] || return 1
    cut -d= -f2- < "$TEST_DIR/applied"
}

# Each case runs in its own directory holding only the archive under test.
seed_archive() {
    local version="$1"

    rm -rf "$TEST_DIR/work"
    mkdir -p "$TEST_DIR/work/kvs-archive"
    : > "$TEST_DIR/work/kvs-archive/KVS_${version}_[example.com].zip"
    rm -f "$TEST_DIR/applied"
    cd "$TEST_DIR/work"
}

run_case() {
    local description="$1"
    local expected="$2"
    shift 2

    if ! ( "$@" ) > "$TEST_DIR/out" 2>&1; then
        cat "$TEST_DIR/out" >&2
        fail "$description: selection exited non-zero"
    fi
    local actual
    actual=$(applied_version) ||
        fail "$description: no PHP version was applied"
    [ "$actual" = "$expected" ] ||
        fail "$description: expected PHP $expected, got $actual"
}

# 1. An encoded archive is pinned to the version KVS documents for it.
seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "encoded 7.0.2" 8.1 select_php_version

seed_archive 6.2.0
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "encoded 6.2.0" 7.4 select_php_version

seed_archive 5.5.0
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "encoded 5.5.0" 7.4 select_php_version

# 2. An encoded archive must not silently consume a stray interactive answer.
seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=''
run_case "encoded stays non-interactive" 8.1 select_php_version < /dev/null

# 3. The explicit override stays available, but it must warn first.
seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION=8.3 HEADLESS=y
run_case "encoded override" 8.3 select_php_version
grep -q "WARNING: the archive is IonCube encoded" "$TEST_DIR/out" ||
    fail "overriding an encoded archive did not warn about the loader"

# 4. Without IonCube the documented version is only the default.
seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=y
run_case "unencoded default" 8.1 select_php_version

seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION=8.4 HEADLESS=y
run_case "unencoded override" 8.4 select_php_version

# 5. Interactively, an empty answer keeps the default and a version is taken.
seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=''
run_case "unencoded empty answer" 8.1 select_php_version <<< ""

seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=''
run_case "unencoded interactive answer" 8.3 select_php_version <<< "8.3"

# 6. Unsupported versions are rejected before anything is written.
seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION=8.9 HEADLESS=y
if ( select_php_version ) > "$TEST_DIR/out" 2>&1; then
    fail "an unsupported PHP version was accepted"
fi
grep -q "Unsupported PHP version: 8.9" "$TEST_DIR/out" ||
    fail "rejecting an unsupported version did not explain why"
[ ! -f "$TEST_DIR/applied" ] ||
    fail "an unsupported version was written to .env"

seed_archive 7.0.2
IONCUBE=YES KVS_PHP_VERSION=5.6 HEADLESS=y
if ( select_php_version ) > "$TEST_DIR/out" 2>&1; then
    fail "an unsupported PHP version was accepted for an encoded archive"
fi
[ ! -f "$TEST_DIR/applied" ] ||
    fail "an unsupported version was written for an encoded archive"

seed_archive 7.0.2
IONCUBE=NO KVS_PHP_VERSION='' HEADLESS=''
if ( select_php_version ) > "$TEST_DIR/out" 2>&1 <<< "8.9"; then
    fail "an unsupported interactive answer was accepted"
fi
[ ! -f "$TEST_DIR/applied" ] ||
    fail "an unsupported interactive answer was written to .env"

# 7. A missing or unreadable archive falls back without failing the install.
rm -rf "$TEST_DIR/work"
mkdir -p "$TEST_DIR/work/kvs-archive"
rm -f "$TEST_DIR/applied"
cd "$TEST_DIR/work"
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "missing archive" 8.1 select_php_version

seed_archive 7.0.2
mv "kvs-archive/KVS_7.0.2_[example.com].zip" "kvs-archive/KVS_unreleased.zip"
IONCUBE=YES KVS_PHP_VERSION='' HEADLESS=y
run_case "unparsable archive name" 8.1 select_php_version

cd "$ROOT_DIR"
echo "PASS: Setup PHP version selection"
