#!/bin/bash
# The one-time admin password of a fresh install is shown before kvs-init.
# 35-harden sets it early, and an init script that fails afterwards (for
# example 80-manticore when its sources are unreachable) ends the setup
# under set -e; a password shown only after a successful kvs-init would be
# lost with no way to recover it.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

SETUP="$ROOT_DIR/docker/setup.sh"
SAMPLE_PASSWORD="OneTimeSecretValue1234567890" # pragma: allowlist secret

extract_function() {
    local name="$1"

    awk -v signature="${name}() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$SETUP"
}

# The harness holds the production function and stubs the colours it uses.
harness="$TEST_DIR/harness.sh"
{
    echo "RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''"
    extract_function announce_generated_admin_password
} > "$harness"
grep -q '^announce_generated_admin_password() {' "$harness" ||
    fail "announce_generated_admin_password not found in setup.sh"

run_announce() {
    local generated="$1"
    bash -c '
        set -e
        source "$1"
        KVS_ADMIN_PASSWORD_GENERATED="$2"
        KVS_ADMIN_PASSWORD="$3"
        announce_generated_admin_password
    ' _ "$harness" "$generated" "$SAMPLE_PASSWORD"
}

# A generated password is printed, with the login, so a later failure cannot
# lose it.
out=$(run_announce true)
grep -Fq "$SAMPLE_PASSWORD" <<<"$out" ||
    fail "the generated one-time password was not shown"
grep -Fq "Admin login:" <<<"$out" ||
    fail "the admin login was not shown with the generated password"
echo "PASS: a generated one-time password is disclosed"

# A kept or supplied password prints nothing here (nothing to lose, or shown
# elsewhere).
out=$(run_announce false)
if grep -Fq "$SAMPLE_PASSWORD" <<<"$out"; then
    fail "a password was shown when none was generated"
fi
echo "PASS: nothing is disclosed when no password was generated"

# The disclosure must run before the kvs-init step, not after it.
call_line=$(grep -n '^announce_generated_admin_password$' "$SETUP" | tail -1 | cut -d: -f1)
init_line=$(grep -n 'run_step "Initializing KVS"' "$SETUP" | head -1 | cut -d: -f1)
[ -n "$call_line" ] || fail "announce_generated_admin_password is never called"
[ -n "$init_line" ] || fail "the kvs-init step was not found"
[ "$call_line" -lt "$init_line" ] ||
    fail "the password is disclosed at line $call_line, after kvs-init at line $init_line"
echo "PASS: the disclosure runs before kvs-init"

# The summary must not claim an existing password was verified: setup cannot
# verify it, and after a lost generated password the claim is false.
if grep -q 'preserved and verified' "$SETUP"; then
    fail "the summary still claims the existing password was verified"
fi
echo "PASS: the summary no longer claims the password was verified"

echo "All admin password disclosure tests passed"
