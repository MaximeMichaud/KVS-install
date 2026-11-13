#!/bin/bash
# The interactive DNS check of kvs-install.sh offers "wait 60 seconds and
# check again". That option slept and called check_dns_configuration again,
# but DNS_ACTION still held "2", so the recursive call skipped the prompt and
# waited again without ever asking: a still-wrong domain kept re-checking on
# its own and could only be left with Ctrl-C. The function now clears the
# choice before prompting, so every pass asks again. This drives the extracted
# function with stubbed curl, dig and sleep and a scripted answer on stdin.
set -u

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$TEST_DIR/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# The function as the script defines it, up to its own column-zero closing
# brace (the nested helpers close with indented braces).
awk '/^function check_dns_configuration\(\) \{/{f=1} f{print} f&&/^}/{exit}' \
    "$ROOT_DIR/kvs-install.sh" > "$WORK/dns.sh"
grep -q 'check_dns_configuration()' "$WORK/dns.sh" ||
    fail "check_dns_configuration is not defined in kvs-install.sh"

# Run the function with the external tools stubbed. curl returns a fixed
# public IPv4 and no IPv6 (so the IPv6 branch is skipped); dig always answers
# an address that differs from it, so the domain never matches; sleep records
# how many times the wait ran and aborts the whole shell once it is clear the
# function is looping on the wait instead of asking again. prompt_read reads
# the scripted answers from standard input, as the real one does.
run_retry() {
    local feed=$1
    SLEEP_COUNT="$WORK/sleeps"
    echo 0 > "$SLEEP_COUNT"
    printf '%s' "$feed" | SLEEP_COUNT="$SLEEP_COUNT" bash -c '
        set -u
        red=; green=; normal=; HEADLESS=; DOMAIN=example.com; DNS_ACTION=""
        curl() {
            case "$*" in
                *api64.ipify.org*) printf "" ;;
                *api.ipify.org*) printf "203.0.113.10" ;;
                *) printf "" ;;
            esac
        }
        dig() { printf "198.51.100.9\n"; }
        sleep() {
            local n
            n=$(( $(cat "$SLEEP_COUNT") + 1 ))
            echo "$n" > "$SLEEP_COUNT"
            if [ "$n" -ge 3 ]; then
                echo "SLEEP-LOOP-ABORT"
                exit 97
            fi
        }
        prompt_read() {
            read -r "$@" && return 0
            echo "NO-INPUT-LEFT" >&2
            exit 1
        }
        source "$1"
        check_dns_configuration
        echo "status=$?"
    ' _ "$WORK/dns.sh" 2>&1
}

# A straight "continue" is answered once, with no wait.
out=$(run_retry $'1\n')
grep -q 'status=0' <<< "$out" || fail "answering 1 must continue, got: $out"
grep -q 'Continuing installation despite DNS issues' <<< "$out" ||
    fail "answering 1 must report that it continues, got: $out"
[ "$(cat "$WORK/sleeps")" -eq 0 ] || fail "answering 1 must not wait"

# "Wait and check again", then "continue": the function must ask a second
# time after the single wait instead of waiting on its own forever.
out=$(run_retry $'2\n1\n')
grep -q 'SLEEP-LOOP-ABORT' <<< "$out" &&
    fail "the wait option must re-prompt, not loop on the wait: $out"
grep -q 'status=0' <<< "$out" || fail "a retry then continue must succeed, got: $out"
grep -q 'Continuing installation despite DNS issues' <<< "$out" ||
    fail "the second answer must be read and acted on, got: $out"
[ "$(cat "$WORK/sleeps")" -eq 1 ] ||
    fail "exactly one wait must run before the re-prompt, got $(cat "$WORK/sleeps")"

echo "ok - the DNS wait option re-prompts after each retry instead of looping"
