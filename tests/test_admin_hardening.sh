#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-admin-hardening.XXXXXX)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# Fingerprints KVS ships in admin/data/system/ap.dat for admin/123 and for
# the kvs_support account: substr(md5(login . stored_hash), 0, 20).
DEFAULT_ADMIN_FINGERPRINT=a16efad9c4826988b64d
SUPPORT_FINGERPRINT=70cd8a1663585e053d04

md5_hex() {
    printf '%s' "$1" | md5sum | cut -c1-32
}

# Fingerprint the admin login expects once the given password is stored as
# md5("pass:" . md5(password)).
expected_fingerprint() {
    local hash

    hash=$(md5_hex "pass:$(md5_hex "$1")")
    printf 'admin%s' "$hash" | md5sum | cut -c1-20
}

fingerprint_file() {
    printf '%s/www/admin/data/system/ap.dat\n' "$1"
}

make_case() {
    local name="$1"
    local case_dir="$TEST_DIR/$name"

    mkdir -p "$case_dir/www/admin/data/system"
    printf '%s\n' 1 > "$case_dir/admin-count"
    printf '%s\n' 1 > "$case_dir/admin-default"
    printf '%s\n' 1 > "$case_dir/support-option"
    printf '{"admins":[{"id":"1","hash":"%s"},{"id":"2","hash":"%s"}]}' \
        "$DEFAULT_ADMIN_FINGERPRINT" "$SUPPORT_FINGERPRINT" > "$(fingerprint_file "$case_dir")"
    cat > "$case_dir/common.sh" <<'EOF'
KVS_PATH="$TEST_STATE/www"
log_info() { printf '[INFO] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }
log_error() { printf '[ERROR] %s\n' "$1" >&2; }

db_query() {
    local query="$1"

    case "$query" in
        *"user_id=1 AND login='admin' AND pass="*) cat "$TEST_STATE/admin-default" ;;
        *"user_id=1 AND login='admin'"*) cat "$TEST_STATE/admin-count" ;;
        *"variable='ENABLE_KVS_SUPPORT_ACCESS'"*) cat "$TEST_STATE/support-option" ;;
        *) return 90 ;;
    esac
}

db_exec() {
    local query="$1"

    if [[ "$query" == *"user_id=1 AND login='admin'"* ]]; then
        if [ "${TEST_DB_EXEC_FAIL:-none}" = admin ]; then
            return 41
        fi
        printf '%s\n' 0 > "$TEST_STATE/admin-default"
        : > "$TEST_STATE/admin-updated"
    elif [[ "$query" == *"ktvs_options"* ]]; then
        if [ "${TEST_DB_EXEC_FAIL:-none}" = support ]; then
            return 42
        fi
        if [ "${TEST_SUPPORT_STUCK:-0}" != 1 ]; then
            printf '%s\n' 0 > "$TEST_STATE/support-option"
        fi
        : > "$TEST_STATE/support-updated"
    else
        : > "$TEST_STATE/unexpected-exec"
        return 91
    fi
}
EOF
    sed "s|source /init/lib/common.sh|source ${case_dir}/common.sh|" \
        "$ROOT_DIR/docker/init/docker-entrypoint.d/35-harden-admin-users.sh" \
        > "$case_dir/script.sh"
    chmod +x "$case_dir/script.sh"
    printf '%s\n' "$case_dir"
}

assert_fingerprints() {
    local case_dir="$1"
    local admin_fingerprint="$2"
    local file

    file=$(fingerprint_file "$case_dir")
    grep -Fq "{\"id\":\"1\",\"hash\":\"${admin_fingerprint}\"}" "$file" ||
        fail "$(basename "$case_dir"): ap.dat does not carry the expected admin fingerprint"
    grep -Fq "{\"id\":\"2\",\"hash\":\"${SUPPORT_FINGERPRINT}\"}" "$file" ||
        fail "$(basename "$case_dir"): ap.dat support entry was altered"
}

valid_password='test-only-admin-password-32-chars'
valid_fingerprint=$(expected_fingerprint "$valid_password")

case_dir=$(make_case provided)
TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1
[ -f "$case_dir/admin-updated" ] || fail "provided admin password was not applied"
[ "$(cat "$case_dir/admin-default")" = 0 ] || fail "default admin verifier remains"
assert_fingerprints "$case_dir" "$valid_fingerprint"
grep -Fq "$valid_password" "$case_dir/output.log" && fail "admin password leaked to output"
grep -Eq '[a-f0-9]{20}' "$case_dir/output.log" && fail "password verifier or fingerprint leaked to output"
[ ! -e "$case_dir/unexpected-exec" ] || fail "unexpected SQL statement was executed"

case_dir=$(make_case short)
if TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD=too-short \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "short admin password was accepted"
fi
[ ! -e "$case_dir/admin-updated" ] || fail "short password changed the admin account"
assert_fingerprints "$case_dir" "$DEFAULT_ADMIN_FINGERPRINT"

case_dir=$(make_case preserved)
printf '%s\n' 0 > "$case_dir/admin-default"
TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD='' \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1
[ ! -e "$case_dir/admin-updated" ] || fail "existing admin password was unexpectedly rotated"
assert_fingerprints "$case_dir" "$DEFAULT_ADMIN_FINGERPRINT"

case_dir=$(make_case default-without-replacement)
if TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD='' \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "default admin credential was accepted without replacement"
fi
grep -Fq 'still uses the archive default credential' "$case_dir/output.log" ||
    fail "default admin credential failure was not explicit"

case_dir=$(make_case missing-admin)
printf '%s\n' 0 > "$case_dir/admin-count"
if TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "missing primary admin account was accepted"
fi

case_dir=$(make_case sql-failure)
if TEST_STATE="$case_dir" TEST_DB_EXEC_FAIL=admin KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "admin SQL update failure was ignored"
fi

case_dir=$(make_case fingerprint-file-missing)
rm "$(fingerprint_file "$case_dir")"
TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1
[ -f "$case_dir/admin-updated" ] || fail "missing ap.dat blocked the admin password change"
grep -Fq 'ap.dat not found' "$case_dir/output.log" ||
    fail "missing ap.dat was not reported"
[ ! -e "$(fingerprint_file "$case_dir")" ] || fail "missing ap.dat was created"

case_dir=$(make_case fingerprint-file-invalid)
printf 'not json' > "$(fingerprint_file "$case_dir")"
if TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "unreadable ap.dat was ignored"
fi
[ ! -e "$case_dir/admin-updated" ] ||
    fail "admin password changed although the login fingerprint could not be registered"

case_dir=$(make_case fingerprint-entry-added)
printf '{"admins":[{"id":"2","hash":"%s"}]}' "$SUPPORT_FINGERPRINT" > "$(fingerprint_file "$case_dir")"
TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1
grep -Fq "{\"id\":\"1\",\"hash\":\"${valid_fingerprint}\",\"lock_ip\":\"\"}" "$(fingerprint_file "$case_dir")" ||
    fail "missing admin entry was not added to ap.dat"

# KVS support access stays enabled unless the operator opts out.
case_dir=$(make_case support-default)
TEST_STATE="$case_dir" KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1
[ ! -e "$case_dir/support-updated" ] || fail "support access was changed without an opt-out"
[ "$(cat "$case_dir/support-option")" = 1 ] || fail "support access option was altered by default"
grep -Fq 'left as configured' "$case_dir/output.log" || fail "support access default was not reported"

case_dir=$(make_case support-disabled)
TEST_STATE="$case_dir" DISABLE_KVS_SUPPORT_ACCESS=true KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1
[ -f "$case_dir/support-updated" ] || fail "support access opt-out was not applied"
[ "$(cat "$case_dir/support-option")" = 0 ] || fail "support access option was not disabled"
assert_fingerprints "$case_dir" "$valid_fingerprint"
grep -Fq 'support access disabled' "$case_dir/output.log" || fail "support access opt-out was not reported"

case_dir=$(make_case support-disabled-rerun)
printf '%s\n' 0 > "$case_dir/admin-default"
TEST_STATE="$case_dir" DISABLE_KVS_SUPPORT_ACCESS=true KVS_ADMIN_PASSWORD='' \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1
[ "$(cat "$case_dir/support-option")" = 0 ] || fail "support access opt-out was skipped on rerun"
[ ! -e "$case_dir/admin-updated" ] || fail "rerun opt-out rotated the admin password"

case_dir=$(make_case support-invalid-value)
if TEST_STATE="$case_dir" DISABLE_KVS_SUPPORT_ACCESS=yes KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "invalid DISABLE_KVS_SUPPORT_ACCESS value was accepted"
fi
[ ! -e "$case_dir/support-updated" ] || fail "invalid opt-out value changed support access"
grep -Fq 'must be true or false' "$case_dir/output.log" || fail "invalid opt-out value was not explained"

case_dir=$(make_case support-not-applied)
if TEST_STATE="$case_dir" TEST_SUPPORT_STUCK=1 DISABLE_KVS_SUPPORT_ACCESS=true KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "unchanged support access option was accepted"
fi
grep -Fq 'could not be disabled' "$case_dir/output.log" || fail "unchanged support access was not explained"

case_dir=$(make_case support-sql-failure)
if TEST_STATE="$case_dir" TEST_DB_EXEC_FAIL=support DISABLE_KVS_SUPPORT_ACCESS=true KVS_ADMIN_PASSWORD="$valid_password" \
    bash "$case_dir/script.sh" > "$case_dir/output.log" 2>&1; then
    fail "support access SQL failure was ignored"
fi

if grep -q '^KVS_ADMIN_PASSWORD=' "$ROOT_DIR/docker/.env.example"; then
    fail "admin password was added to the persistent environment template"
fi
if grep -Eq 'set_env_value[[:space:]]+KVS_ADMIN_PASSWORD' "$ROOT_DIR/docker/setup.sh"; then
    fail "setup persists the one-time admin password"
fi
init_line=$(grep -nF 'docker compose --profile setup run --rm --no-deps kvs-init' \
    "$ROOT_DIR/docker/setup.sh" | cut -d: -f1)
unset_line=$(grep -nF 'unset KVS_ADMIN_PASSWORD' "$ROOT_DIR/docker/setup.sh" | head -n 1 | cut -d: -f1)
next_step_line=$(grep -nF 'progress_bar "Configuring disk space limit"' \
    "$ROOT_DIR/docker/setup.sh" | cut -d: -f1)
[ -n "$init_line" ] && [ -n "$unset_line" ] && [ -n "$next_step_line" ] ||
    fail "admin credential lifecycle markers are missing"
[ "$init_line" -lt "$unset_line" ] && [ "$unset_line" -lt "$next_step_line" ] ||
    fail "one-time admin password is not reported and cleared immediately after init"

# The opt-out reaches the init container in both compose layouts and defaults
# to keeping support access.
grep -q '^DISABLE_KVS_SUPPORT_ACCESS=false$' "$ROOT_DIR/docker/.env.example" ||
    fail "environment template does not default DISABLE_KVS_SUPPORT_ACCESS to false"
# shellcheck disable=SC2016  # The literal compose substitution is the pattern.
grep -Fq 'DISABLE_KVS_SUPPORT_ACCESS=${DISABLE_KVS_SUPPORT_ACCESS:-false}' \
    "$ROOT_DIR/docker/docker-compose.yml" ||
    fail "single-site compose does not pass DISABLE_KVS_SUPPORT_ACCESS to kvs-init"
# shellcheck disable=SC2016  # The literal compose substitution is the pattern.
grep -Fq 'DISABLE_KVS_SUPPORT_ACCESS=${DISABLE_KVS_SUPPORT_ACCESS:-false}' \
    "$ROOT_DIR/docker/multi-site/docker-compose.site.yml.template" ||
    fail "multi-site compose template does not pass DISABLE_KVS_SUPPORT_ACCESS to kvs-init"
grep -Eq "ktvs_admin_users[^;]*(kvs_support|status_id=0)" \
    "$ROOT_DIR/docker/init/docker-entrypoint.d/35-harden-admin-users.sh" &&
    fail "init step still touches the kvs_support account row"

setup_copy="$TEST_DIR/setup.sh"
# Bypass the root guard only in this disposable copy so the test reaches the
# headless input validation without writing to the host log directory.
# Keep EUID literal while replacing the guard in the temporary fixture.
# shellcheck disable=SC2016
sed \
    -e "s|/opt/kvs/logs|${TEST_DIR}/setup-logs|g" \
    -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
    "$ROOT_DIR/docker/setup.sh" > "$setup_copy"
chmod +x "$setup_copy"

if KVS_ADMIN_PASSWORD=short HEADLESS=y bash "$setup_copy" \
    > "$TEST_DIR/setup-short.log" 2>&1; then
    fail "setup accepted a short headless admin password"
fi
grep -Fq 'must contain at least 20 characters' "$TEST_DIR/setup-short.log" ||
    fail "setup did not explain the admin password requirement"

if DISABLE_KVS_SUPPORT_ACCESS=yes HEADLESS=y bash "$setup_copy" \
    > "$TEST_DIR/setup-support.log" 2>&1; then
    fail "setup accepted an invalid DISABLE_KVS_SUPPORT_ACCESS value"
fi
grep -Fq 'DISABLE_KVS_SUPPORT_ACCESS must be true or false' "$TEST_DIR/setup-support.log" ||
    fail "setup did not explain the support access opt-out values"

echo "PASS: Administrative account hardening"
