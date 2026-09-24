#!/bin/bash
# shellcheck disable=SC2034  # Variables are consumed by the extracted production function.
# A headless run of setup.sh takes every answer from the environment or a
# default. The Manticore question had no default: with a terminal the run
# blocked on it, without one read failed and set -e ended the setup.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-manticore.XXXXXX)

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

# The harness holds the production function and stubs for what it calls.
harness="$TEST_DIR/harness.sh"
{
    echo "RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''"
    echo "SITE_PREFIX=kvs"
    printf '%s\n' "set_env_value() { printf '%s=%s\\n' \"\$1\" \"\$2\" >> '$TEST_DIR/applied'; }"
    echo "remove_env_value() { :; }"
    echo "add_compose_profile() { :; }"
    echo "remove_compose_profile() { :; }"
    echo "docker() { :; }"
    extract_function select_manticore
} > "$harness"
grep -q '^select_manticore() {' "$harness" || fail "select_manticore not found in setup.sh"

# Runs the selection the way setup.sh does, under set -e in its own shell,
# with stdin as given. An unattended run (nohup, CI, ssh without a
# terminal) has stdin at EOF, which an empty input stands for.
run_case() {
    local description="$1"
    local expected="$2"
    local headless="$3"
    local choice="$4"
    local input="$5"
    local status=0

    rm -f "$TEST_DIR/applied"
    printf '%s' "$input" > "$TEST_DIR/stdin"
    set +e
    bash -c 'set -e; source "$1"; HEADLESS="$2"; MANTICORE_CHOICE="$3"; select_manticore' \
        _ "$harness" "$headless" "$choice" < "$TEST_DIR/stdin" > "$TEST_DIR/out" 2>&1
    status=$?
    set -e
    if [ "$status" -ne 0 ]; then
        fail "$description: select_manticore exited $status: $(tail -n 2 "$TEST_DIR/out")"
    fi
    grep -qx "ENABLE_MANTICORE=$expected" "$TEST_DIR/applied" 2>/dev/null ||
        fail "$description: expected ENABLE_MANTICORE=$expected, applied: $(cat "$TEST_DIR/applied" 2>/dev/null)"
    if [ "$headless" = y ] && grep -q 'Choice \[2\]' "$TEST_DIR/out"; then
        fail "$description: a headless run showed the Manticore prompt"
    fi
    echo "PASS: $description"
}

run_case "headless run without MANTICORE_CHOICE skips Manticore" false y "" ""
run_case "headless run with MANTICORE_CHOICE=1 enables Manticore" true y 1 ""
run_case "headless run with MANTICORE_CHOICE=2 skips Manticore" false y 2 ""
run_case "interactive run reads the answer" true "" "" $'1\n'
run_case "interactive run defaults to skip on an empty answer" false "" "" $'\n'

echo "All Manticore headless tests passed"
