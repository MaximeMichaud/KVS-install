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

# Run alone, the setup keeps no copy of the password and says so. Run by
# kvs-install.sh, whose log keeps everything it prints, it names that log
# instead of claiming the password is not logged, and calls it readable by
# root only when it is: a regular file, not a link, with no permission for
# the group or others. The installer leaves a log path that is a link, or
# no regular file, as the operator set it.
grep -Fq "is not written to .env or the setup log." <<<"$out" ||
    fail "a setup run alone must say the password is not logged: $out"
logs="$TEST_DIR/logs"
mkdir "$logs"
printf 'log\n' > "$logs/private.log"
chmod 600 "$logs/private.log"
printf 'log\n' > "$logs/shared.log"
chmod 644 "$logs/shared.log"
printf 'log\n' > "$logs/group.log"
chmod 640 "$logs/group.log"
ln -s "$logs/private.log" "$logs/link-to-private.log"
ln -s "$logs/shared.log" "$logs/link-to-shared.log"
ln -s /dev/null "$logs/link-to-null.log"
mkfifo -m 600 "$logs/fifo.log"
for log in private.log shared.log group.log link-to-private.log link-to-shared.log link-to-null.log fifo.log missing.log; do
    out=$(KVS_INSTALL_LOG="$logs/$log" run_announce true)
    grep -Fq "$SAMPLE_PASSWORD" <<<"$out" ||
        fail "$log: the password must be shown under the installer too: $out"
    if grep -Fq "or the setup log" <<<"$out"; then
        fail "$log: under the installer, the setup must not claim the password is not logged: $out"
    fi
    if [ "$log" = private.log ]; then
        grep -Fq "is not written to .env; the installer log $logs/$log, readable by root only, keeps it." <<<"$out" ||
            fail "$log: under the installer, the setup must say which log keeps the password: $out"
    else
        grep -Fq "is not written to .env; the installer writes what is shown here to $logs/$log." <<<"$out" ||
            fail "$log: the setup must name where the installer writes its output: $out"
        if grep -Fq "readable by root only" <<<"$out"; then
            fail "$log: a log that is not a private regular file must not be called readable by root only: $out"
        fi
    fi
done
echo "PASS: the setup says where the password is kept, and calls the log private only when it is"

# A renamed primary account keeps its login: the password goes with the
# login it really has, not with the archive's admin.
out=$(bash -c '
    set -e
    source "$1"
    KVS_ADMIN_PASSWORD_GENERATED=true
    KVS_ADMIN_PASSWORD="$2"
    KVS_ADMIN_LOGIN=boss
    announce_generated_admin_password
' _ "$harness" "$SAMPLE_PASSWORD")
grep -Fxq "  Admin login: boss" <<<"$out" ||
    fail "the one-time password was not shown with the account's own login: $out"
echo "PASS: the one-time password is shown with the account's own login"

# setup_plan_admin_password carries the login the check found to the
# announcement, plans nothing for a hardened account, keeps a supplied
# password without asking MariaDB, and stops when the check fails. The check
# itself runs against a real MariaDB in integration_admin_default_check.sh.
plan_harness="$TEST_DIR/plan-harness.sh"
{
    echo "RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''; DEBUG_LOG=/dev/null"
    extract_function setup_plan_admin_password
    extract_function announce_generated_admin_password
} > "$plan_harness"
grep -q '^setup_plan_admin_password() {' "$plan_harness" ||
    fail "setup_plan_admin_password not found in setup.sh"
grep -A1 -x 'KVS_ADMIN_LOGIN="admin"' "$SETUP" | grep -qx 'setup_plan_admin_password || exit 1' ||
    fail "setup.sh does not plan the admin password, or goes on when the check fails"

run_plan() {
    local check="$1" supplied="$2"
    bash -c '
        set -e
        source "$1"
        check=$2
        setup_default_admin_login() { echo checked >&2; eval "$check"; }
        KVS_ADMIN_PASSWORD_GENERATED=false
        KVS_ADMIN_PASSWORD="$3"
        KVS_ADMIN_LOGIN=admin
        setup_plan_admin_password || { echo "plan-failed"; exit 0; }
        echo "generated=$KVS_ADMIN_PASSWORD_GENERATED length=${#KVS_ADMIN_PASSWORD}"
        announce_generated_admin_password
    ' _ "$plan_harness" "$check" "$supplied" 2>&1
}

out=$(run_plan 'printf "%s\n" boss' "")
grep -Fxq "generated=true length=32" <<<"$out" ||
    fail "a renamed account with the default password got no one-time password: $out"
grep -Fxq "  Admin login: boss" <<<"$out" ||
    fail "the planned password was announced under another login than the account's: $out"
echo "PASS: the planned password is announced with the login the check found"

out=$(run_plan 'true' "")
grep -Fxq "generated=false length=0" <<<"$out" ||
    fail "a hardened account got a new password planned: $out"
echo "PASS: a hardened account gets no password planned"

out=$(run_plan 'printf "%s\n" boss' "$SAMPLE_PASSWORD")
grep -Fxq "generated=false length=${#SAMPLE_PASSWORD}" <<<"$out" ||
    fail "a supplied password was replaced: $out"
if grep -Fxq checked <<<"$out"; then
    fail "the default check ran although a password was supplied"
fi
echo "PASS: a supplied password is kept without a check"

out=$(run_plan 'return 1' "")
grep -Fxq plan-failed <<<"$out" ||
    fail "a failed check did not stop the planning: $out"
grep -Fq "ERROR: could not check whether the primary KVS admin account" <<<"$out" ||
    fail "a failed check stopped the planning without saying why: $out"
echo "PASS: a failed check stops the setup with an error"

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
