#!/bin/bash
# The pre-flight checks of docker/setup.sh ask "Continue anyway? [y/N]" when
# a check warns (no internet, under 10 GB free). Only PREFLIGHT_BYPASS skipped
# the question, not HEADLESS=y: a headless run asked it anyway, then, with
# nothing on its input, ended with status 1 and no message (a plain read
# under set -e), or waited on a terminal. A headless run without
# PREFLIGHT_BYPASS now stops with the reason; an interactive one asks through
# prompt_read, which names the end of its input.
set -uo pipefail
ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-preflight-headless.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

awk '
    $0 == "preflight_checks() {" || $0 == "preflight_kernel_writeback_status() {" ||
        $0 == "docker_is_the_snap() {" || $0 == "prompt_read() {" { capture = 1 }
    capture { print }
    capture && /^}$/ { capture = 0 }
' "$ROOT_DIR/docker/setup.sh" > "$WORK/preflight.sh"
grep -q '^preflight_checks() {' "$WORK/preflight.sh" || fail "preflight_checks is not defined in docker/setup.sh"
grep -q '^prompt_read() {' "$WORK/preflight.sh" || fail "prompt_read is not defined in docker/setup.sh"

# preflight <warning: internet|disk|none> <HEADLESS> <PREFLIGHT_BYPASS> <DEV_MODE>:
# the checks under set -e, as the setup runs them, on a host whose only
# problem is the given warning. Prints the output, then exit=<status>.
preflight() {
    # shellcheck disable=SC2016
    bash -c '
        set -e
        source "$1"
        # shellcheck disable=SC2034
        RED="" GREEN="" YELLOW="" CYAN="" NC="" IMPORT_MODE=false
        WARNING=$2 HEADLESS=$3 PREFLIGHT_BYPASS=$4 DEV_MODE=$5
        docker() {
            case "$1" in
                --version) echo "Docker version 29.0.0, build test" ;;
                compose) echo "Docker Compose version v2.40.0" ;;
            esac
        }
        free() {
            echo "               total        used        free      shared  buff/cache   available"
            echo "Mem:            8000        1000        5000           0        2000        7000"
            echo "Swap:           2048           0        2048"
        }
        uname() { echo 7.2.9; }
        preflight_free_disk_gb() { if [ "$WARNING" = disk ]; then echo "5 /"; else echo "40 /"; fi; }
        check_internet() { [ "$WARNING" != internet ]; }
        preflight_checks
        echo "the setup went on"
    ' _ "$WORK/preflight.sh" "$@" 2>&1
    # A question leaves no newline behind: the status goes on its own line.
    printf '\nexit=%s\n' "$?"
}

# Headless, a warning, no PREFLIGHT_BYPASS: an explicit error, no question,
# whether the input is at its end or holds an answer.
for warning in internet disk; do
    out=$(preflight "$warning" y '' '' < /dev/null)
    grep -qx 'exit=1' <<< "$out" || fail "a headless run with a $warning warning must stop, got: $out"
    grep -q 'ERROR: the pre-flight checks above have warnings, and a headless run cannot ask whether to continue' <<< "$out" ||
        fail "a headless run with a $warning warning must say why it stops, got: $out"
    grep -q 'PREFLIGHT_BYPASS=y' <<< "$out" || fail "the error must name PREFLIGHT_BYPASS, got: $out"
    if grep -q 'Continue anyway' <<< "$out"; then fail "a headless run must not ask, got: $out"; fi
    if grep -q 'the setup went on' <<< "$out"; then fail "a headless run must not go on past the warning"; fi
done
out=$(printf 'y\n' | preflight internet y '' '')
grep -qx 'exit=1' <<< "$out" || fail "a headless run must not read an answer from its input, got: $out"
if grep -q 'Continue anyway' <<< "$out"; then fail "a headless run must not ask even with input, got: $out"; fi
pass "a headless run with a warning and no PREFLIGHT_BYPASS stops with the reason"

out=$(preflight internet y y '' < /dev/null)
grep -qx 'exit=0' <<< "$out" || fail "PREFLIGHT_BYPASS=y must let a headless run go on, got: $out"
grep -q 'Continuing with warnings' <<< "$out" || fail "PREFLIGHT_BYPASS=y must say it goes on, got: $out"
out=$(preflight internet y '' true < /dev/null)
grep -qx 'exit=0' <<< "$out" || fail "--dev must go on past the warnings, got: $out"
out=$(preflight none y '' '' < /dev/null)
grep -qx 'exit=0' <<< "$out" || fail "a headless run without warnings must go on, got: $out"
pass "PREFLIGHT_BYPASS, --dev and a clean host still go on"

# Interactive: the question is asked; y goes on, anything else cancels, and
# the end of the input is named instead of a silent exit.
out=$(printf 'y\n' | preflight internet '' '' '')
grep -q 'Continue anyway? \[y/N\]' <<< "$out" || fail "an interactive run must ask, got: $out"
grep -qx 'exit=0' <<< "$out" || fail "an interactive y must go on, got: $out"
out=$(printf 'n\n' | preflight internet '' '' '')
grep -qx 'exit=1' <<< "$out" || fail "an interactive n must cancel, got: $out"
grep -q 'Installation cancelled' <<< "$out" || fail "an interactive n must say it cancels, got: $out"
out=$(preflight internet '' '' '' < /dev/null)
grep -qx 'exit=1' <<< "$out" || fail "an interactive run at the end of its input must stop, got: $out"
grep -q 'no answer left on standard input' <<< "$out" || fail "the end of the input must be named, got: $out"
pass "an interactive run asks, and names the end of its input"

# The headless variables of the README name PREFLIGHT_BYPASS, which a
# headless run with a warning now needs to go on (the error points at it).
readme=$(tr -d '\r' < "$ROOT_DIR/README.md")
headless_table=$(awk '
    /^\| Variable \| Values \| Default \| Description \|$/ { table = ""; capture = 1 }
    capture && /^$/ { if (table ~ /\| `HEADLESS` \|/) { printf "%s", table; exit } capture = 0 }
    capture { table = table $0 "\n" }
' <<< "$readme")
# shellcheck disable=SC2016  # Literal Markdown backticks.
grep -q '^| `HEADLESS` |' <<< "$headless_table" || fail "the README has no table of headless variables with HEADLESS"
# shellcheck disable=SC2016  # Literal Markdown backticks.
grep -Eq '^\| `PREFLIGHT_BYPASS` \| `y` \| .*pre-flight warnings' <<< "$headless_table" ||
    fail "the README table of headless variables must document PREFLIGHT_BYPASS=y"
pass "the README lists PREFLIGHT_BYPASS with the headless variables"
