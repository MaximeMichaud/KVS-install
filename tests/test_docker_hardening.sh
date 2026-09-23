#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/kvs-docker-hardening.XXXXXX)
TESTS_RUN=0

cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    echo "not ok - $1" >&2
    exit 1
}

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "ok $TESTS_RUN - $1"
}

assert_file_contains() {
    local file="$1"
    local expected="$2"

    grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_file_not_contains() {
    local file="$1"
    local unexpected="$2"

    if grep -Fq -- "$unexpected" "$file"; then
        fail "$file unexpectedly contains: $unexpected"
    fi
}

make_setup_test_copy() {
    local destination="$1"
    local log_dir="$2"

    # The EUID expression must remain literal in the temporary copy.
    # shellcheck disable=SC2016
    sed \
        -e "s|/opt/kvs/logs|${log_dir}|g" \
        -e 's/if \[ "$EUID" -ne 0 \]; then/if false; then/' \
        "$REPO_ROOT/docker/setup.sh" > "$destination"
    chmod +x "$destination"
}

make_preflight_mocks() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/docker" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then
    echo "Docker version 28.0.0, build test"
elif [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
    echo "Docker Compose version v2.35.0"
fi
exit 0
EOF
    cat > "$bin_dir/curl" <<'EOF'
#!/bin/bash
exit 0
EOF
    cat > "$bin_dir/gum" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$bin_dir/docker" "$bin_dir/curl" "$bin_dir/gum"
}

make_root_guard_test_copy() {
    local destination="$1"
    local log_dir="$2"

    # Replace the readonly Bash EUID check only in the disposable test copy so
    # the guard remains testable when the suite itself runs as root.
    # shellcheck disable=SC2016
    sed \
        -e "s|/opt/kvs/logs|${log_dir}|g" \
        -e 's/if \[ "$EUID" -ne 0 \]; then/if [ "${KVS_TEST_EUID:-0}" -ne 0 ]; then/' \
        "$REPO_ROOT/docker/setup.sh" > "$destination"
    chmod +x "$destination"
}

make_root_guard_mocks() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/docker" <<'EOF'
#!/bin/bash
printf 'docker %s\n' "$*" >> "$KVS_ROOT_GUARD_CALL_LOG"
if [ "${1:-}" = "--version" ]; then
    echo "Docker version 28.0.0, build test"
elif [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
    echo "Docker Compose version v2.35.0"
fi
exit 0
EOF
    cat > "$bin_dir/curl" <<'EOF'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$KVS_ROOT_GUARD_CALL_LOG"
exit 0
EOF
    cat > "$bin_dir/gum" <<'EOF'
#!/bin/bash
printf 'gum %s\n' "$*" >> "$KVS_ROOT_GUARD_CALL_LOG"
exit 0
EOF
    cat > "$bin_dir/ss" <<'EOF'
#!/bin/bash
printf 'ss %s\n' "$*" >> "$KVS_ROOT_GUARD_CALL_LOG"
exit 0
EOF
    chmod +x "$bin_dir/docker" "$bin_dir/curl" "$bin_dir/gum" "$bin_dir/ss"
}

test_help_is_side_effect_free_without_root() {
    local case_dir="$TMP_ROOT/setup-help-root-guard"
    local mock_bin="$case_dir/bin"
    local log_dir="$case_dir/logs"
    local setup_copy="$case_dir/setup.sh"
    local call_log="$case_dir/calls.log"
    local output="$case_dir/output.log"
    local error="$case_dir/error.log"

    mkdir -p "$log_dir"
    printf 'preserve-this-trace\n' > "$log_dir/setup-trace.log"
    make_root_guard_test_copy "$setup_copy" "$log_dir"
    make_root_guard_mocks "$mock_bin"

    KVS_TEST_EUID=1000 \
        KVS_ROOT_GUARD_CALL_LOG="$call_log" \
        PATH="$mock_bin:/usr/bin:/bin" \
        "$setup_copy" --help > "$output" 2> "$error"

    assert_file_contains "$output" "USAGE:"
    [ ! -s "$error" ] || fail "setup --help wrote an unexpected root error"
    [ ! -e "$log_dir/setup-debug.log" ] || fail "setup --help initialized the debug log"
    grep -Fxq 'preserve-this-trace' "$log_dir/setup-trace.log" ||
        fail "setup --help removed or changed the legacy trace"
    [ ! -s "$call_log" ] || fail "setup --help invoked an external pre-flight command"

    pass "setup help remains available without root or side effects"
}

test_root_guard_precedes_logs_and_preflight() {
    local case_dir="$TMP_ROOT/setup-operational-root-guard"
    local mock_bin="$case_dir/bin"
    local log_dir="$case_dir/logs"
    local setup_copy="$case_dir/setup.sh"
    local call_log="$case_dir/calls.log"
    local output="$case_dir/output.log"
    local error="$case_dir/error.log"
    local status

    mkdir -p "$log_dir"
    printf 'preserve-this-trace\n' > "$log_dir/setup-trace.log"
    make_root_guard_test_copy "$setup_copy" "$log_dir"
    make_root_guard_mocks "$mock_bin"

    set +e
    KVS_TEST_EUID=1000 \
        KVS_ROOT_GUARD_CALL_LOG="$call_log" \
        PATH="$mock_bin:/usr/bin:/bin" \
        "$setup_copy" > "$output" 2> "$error"
    status=$?
    set -e

    [ "$status" -eq 1 ] || fail "non-root setup did not exit with status 1"
    grep -Fxq 'ERROR: Please run as root' "$error" ||
        fail "non-root setup did not report the root requirement on stderr"
    assert_file_not_contains "$output" "Pre-flight Checks"
    [ ! -e "$log_dir/setup-debug.log" ] || fail "non-root setup initialized the debug log"
    grep -Fxq 'preserve-this-trace' "$log_dir/setup-trace.log" ||
        fail "non-root setup removed or changed the legacy trace"
    [ ! -s "$call_log" ] || fail "non-root setup invoked an external pre-flight command"

    pass "setup rejects non-root execution before logs and pre-flight checks"
}

test_secure_logs_env_and_headless_overrides() {
    local case_dir="$TMP_ROOT/setup-headless"
    local work_dir="$case_dir/work"
    local mock_bin="$case_dir/bin"
    local output="$case_dir/output.log"
    local setup_copy="$case_dir/setup.sh"
    local status

    mkdir -p "$work_dir" "$case_dir/logs"
    chmod 755 "$case_dir/logs"
    touch "$case_dir/logs/setup-debug.log"
    touch "$case_dir/logs/setup-trace.log"
    chmod 644 "$case_dir/logs/setup-debug.log"
    chmod 644 "$case_dir/logs/setup-trace.log"
    cp "$REPO_ROOT/docker/.env.example" "$work_dir/.env"
    chmod 644 "$work_dir/.env"
    sed -i \
        -e 's/CHANGE_ME_ROOT_PASSWORD/TEST_ROOT_SECRET_SENTINEL/' \
        -e 's/CHANGE_ME_KVS_PASSWORD/TEST_KVS_SECRET_SENTINEL/' \
        "$work_dir/.env"
    make_preflight_mocks "$mock_bin"
    make_setup_test_copy "$setup_copy" "$case_dir/logs"

    set +e
    (
        cd "$work_dir"
        PATH="$mock_bin:/usr/bin:/bin" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL=ops@mysite.test \
            HTTP_PORT=127.0.0.4:18080 \
            HTTPS_PORT='[::1]:18443' \
            "$setup_copy"
    ) > "$output" 2>&1
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "setup should stop because the KVS archive fixture is absent"
    assert_file_contains "$work_dir/.env" "DOMAIN=mysite.test"
    assert_file_contains "$work_dir/.env" "EMAIL=ops@mysite.test"
    assert_file_contains "$work_dir/.env" "HTTP_PORT=127.0.0.4:18080"
    assert_file_contains "$work_dir/.env" "HTTPS_PORT=[::1]:18443"
    assert_file_not_contains "$output" "Enter your domain"
    assert_file_not_contains "$output" "Enter your email"
    [ "$(stat -c %a "$case_dir/logs")" = "700" ] || fail "log directory mode is not 700"
    [ "$(stat -c %a "$case_dir/logs/setup-debug.log")" = "600" ] || fail "debug log mode is not 600"
    [ "$(stat -c %a "$work_dir/.env")" = "600" ] || fail ".env mode is not 600"
    [ ! -e "$case_dir/logs/setup-trace.log" ] || fail "setup trace log should not exist"
    assert_file_not_contains "$case_dir/logs/setup-debug.log" "TEST_ROOT_SECRET_SENTINEL"
    assert_file_not_contains "$case_dir/logs/setup-debug.log" "TEST_KVS_SECRET_SENTINEL"
    if grep -Eq 'BASH_XTRACEFD|TRACE_LOG|^[[:space:]]*set -x([[:space:]]|$)' "$REPO_ROOT/docker/setup.sh"; then
        fail "global shell tracing is still enabled"
    fi

    pass "setup protects logs and .env without tracing headless secrets"
}

test_headless_override_validation() {
    local case_dir="$TMP_ROOT/setup-invalid"
    local work_dir="$case_dir/work"
    local mock_bin="$case_dir/bin"
    local output="$case_dir/output.log"
    local setup_copy="$case_dir/setup.sh"

    mkdir -p "$work_dir" "$case_dir/logs"
    cp "$REPO_ROOT/docker/.env.example" "$work_dir/.env"
    make_preflight_mocks "$mock_bin"
    make_setup_test_copy "$setup_copy" "$case_dir/logs"

    if (
        cd "$work_dir"
        PATH="$mock_bin:/usr/bin:/bin" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN='../invalid' \
            EMAIL=ops@mysite.test \
            "$setup_copy"
    ) > "$output" 2>&1; then
        fail "setup accepted an invalid headless domain"
    fi

    assert_file_contains "$output" "ERROR: Invalid domain format: ../invalid"
    assert_file_not_contains "$output" "Enter your domain"

    if (
        cd "$work_dir"
        PATH="$mock_bin:/usr/bin:/bin" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL=invalid-email \
            "$setup_copy"
    ) > "$output" 2>&1; then
        fail "setup accepted an invalid headless email"
    fi
    assert_file_contains "$output" "ERROR: Invalid email format: invalid-email"
    assert_file_not_contains "$output" "Enter your email"

    if (
        cd "$work_dir"
        PATH="$mock_bin:/usr/bin:/bin" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL='' \
            SSL_CHOICE=1 \
            "$setup_copy"
    ) > "$output" 2>&1; then
        fail "setup accepted an empty email for an ACME provider"
    fi
    assert_file_contains "$output" "ERROR: Set EMAIL to a valid address in headless mode"
    assert_file_not_contains "$output" "Enter your email"

    if (
        cd "$work_dir"
        PATH="$mock_bin:/usr/bin:/bin" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL=invalid-email \
            SSL_CHOICE=3 \
            "$setup_copy"
    ) > "$output" 2>&1; then
        fail "self-signed setup accepted a non-empty invalid email"
    fi
    assert_file_contains "$output" "ERROR: Invalid email format: invalid-email"
    pass "setup validates headless overrides without reading stdin"
}

test_selfsigned_headless_accepts_empty_email() {
    local case_dir="$TMP_ROOT/setup-selfsigned-empty-email"
    local work_dir="$case_dir/work"
    local mock_bin="$case_dir/bin"
    local output="$case_dir/output.log"
    local setup_copy="$case_dir/setup.sh"
    local status

    mkdir -p "$work_dir" "$case_dir/logs"
    cp "$REPO_ROOT/docker/.env.example" "$work_dir/.env"
    make_preflight_mocks "$mock_bin"
    make_setup_test_copy "$setup_copy" "$case_dir/logs"

    set +e
    (
        cd "$work_dir"
        PATH="$mock_bin:/usr/bin:/bin" \
            HEADLESS=y \
            PREFLIGHT_BYPASS=y \
            DOMAIN=mysite.test \
            EMAIL='' \
            SSL_CHOICE=3 \
            "$setup_copy"
    ) > "$output" 2>&1
    status=$?
    set -e

    [ "$status" -ne 0 ] || fail "setup should stop because the KVS archive fixture is absent"
    assert_file_contains "$output" "ERROR: Still no KVS archive found. Exiting."
    assert_file_not_contains "$output" "ERROR: Invalid email format"
    assert_file_not_contains "$output" "ERROR: Set EMAIL"
    assert_file_not_contains "$output" "Enter your email"
    grep -qx 'EMAIL=' "$work_dir/.env" || fail "empty self-signed email override was not preserved"
    assert_file_contains "$work_dir/.env" "SSL_PROVIDER=selfsigned"
    pass "self-signed headless setup accepts and preserves an empty email"
}

make_init_common_mock() {
    local destination="$1"

    cat > "$destination" <<'EOF'
KVS_PATH=${TEST_KVS_PATH:?}
KVS_ARCHIVE_DIR=${TEST_ARCHIVE_DIR:-}
log_info() { printf '[INFO] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }
log_error() { printf '[ERROR] %s\n' "$1"; }
db_query() {
    if [[ "$1" == *"INITIAL_VERSION"* ]]; then
        printf '%s\n' "${TEST_INITIAL_VERSION:-7.0.2}"
    else
        printf '%s\n' "${TEST_TABLE_COUNT:-0}"
    fi
}
find_kvs_archive() { printf '%s\n' "${TEST_ARCHIVE:-}"; }
get_project_url() {
    local suffix=""
    if [ "${PROJECT_HTTPS_PORT:-443}" != 443 ]; then
        suffix=":${PROJECT_HTTPS_PORT}"
    fi
    if [ "${USE_WWW:-false}" = "true" ]; then
        printf 'https://www.%s%s\n' "$DOMAIN" "$suffix"
    else
        printf 'https://%s%s\n' "$DOMAIN" "$suffix"
    fi
}
get_safe_domain() {
    local safe="$DOMAIN"
    printf '%s\n' "${safe//[.-]/_}"
}
EOF
}

test_database_import_failure_is_fatal() {
    local case_dir="$TMP_ROOT/import"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"
    local archive="$case_dir/KVS_7.0.2_example.com.zip"
    local output="$case_dir/output.log"

    mkdir -p "$site_dir/_INSTALL" "$mock_bin"
    cat > "$site_dir/_INSTALL/install_db.sql" <<'EOF'
CREATE TABLE test_table (id INT);
INSERT INTO `ktvs_options` (`variable`,`value`) VALUES ('INITIAL_VERSION','7.0.2');
EOF
    touch "$archive"
    make_init_common_mock "$common_mock"
    sed "s|source /init/lib/common.sh|source ${common_mock}|" \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" > "$script_copy"
    cat > "$mock_bin/mariadb" <<'EOF'
#!/bin/bash
exit 42
EOF
    cat > "$mock_bin/unzip" <<'EOF'
#!/bin/bash
printf '%s\n' '$config['"'"'project_url'"'"'] = "https://www.example.com";'
EOF
    chmod +x "$mock_bin/mariadb" "$mock_bin/unzip"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        DOMAIN=example.com \
        MARIADB_PASSWORD=test-password \
        USE_WWW=true \
        bash "$script_copy" > "$output" 2>&1; then
        fail "database import failure was reported as success"
    fi

    [ -f "$site_dir/_INSTALL/install_db.sql" ] || fail "_INSTALL was removed after an import failure"
    assert_file_contains "$output" "Database import failed; preserving"
    assert_file_not_contains "$output" "Database imported successfully"
    pass "database import failures propagate and preserve _INSTALL"
}

test_database_import_normalizes_archive_urls() {
    local case_dir="$TMP_ROOT/import-urls"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"
    local archive="$case_dir/KVS_7.0.2_licensed.example.zip"
    local original_hash

    mkdir -p "$site_dir/_INSTALL" "$mock_bin"
    cat > "$site_dir/_INSTALL/install_db.sql" <<'EOF'
INSERT INTO servers VALUES ('https://www.licensed.example/contents/videos');
INSERT INTO servers VALUES ('https://www.licensed.example/contents/albums');
INSERT INTO servers VALUES ('https://www.licensed.example.evil/leave-this-alone');
INSERT INTO servers VALUES ('https://third-party.example/leave-this-alone');
INSERT INTO `ktvs_options` (`variable`,`value`) VALUES ('INITIAL_VERSION','7.0.2');
EOF
    original_hash=$(sha256sum "$site_dir/_INSTALL/install_db.sql" | awk '{print $1}')
    touch "$archive"
    make_init_common_mock "$common_mock"
    sed "s|source /init/lib/common.sh|source ${common_mock}|" \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" > "$script_copy"

    cat > "$mock_bin/unzip" <<'EOF'
#!/bin/bash
if [ "${TEST_ARCHIVE_URL_MODE:-valid}" = invalid ]; then
    printf '%s\n' '$config['"'"'project_url'"'"'] = "https://invalid_host.example";'
else
    printf '%s\n' '$config['"'"'project_url'"'"'] = "https://www.licensed.example";'
fi
EOF
    cat > "$mock_bin/mariadb" <<'EOF'
#!/bin/bash
cat > "${TEST_IMPORTED_SQL:?}"
printf '%s\n' import >> "${TEST_MARIADB_CALLS:?}"
EOF
    chmod +x "$mock_bin/unzip" "$mock_bin/mariadb"

    PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_IMPORTED_SQL="$case_dir/imported.sql" \
        TEST_MARIADB_CALLS="$case_dir/mariadb-calls.log" \
        DOMAIN=7.0.2.target.example \
        PROJECT_HTTPS_PORT=18443 \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1

    grep -Fq 'https://7.0.2.target.example:18443/contents/videos' "$case_dir/imported.sql" ||
        fail "video storage URL was not normalized"
    grep -Fq 'https://7.0.2.target.example:18443/contents/albums' "$case_dir/imported.sql" ||
        fail "album storage URL was not normalized"
    grep -Fq 'https://www.licensed.example.evil/leave-this-alone' "$case_dir/imported.sql" ||
        fail "a neighboring hostname was modified"
    grep -Fq 'https://third-party.example/leave-this-alone' "$case_dir/imported.sql" ||
        fail "an unrelated URL was modified"
    [ "$(sha256sum "$site_dir/_INSTALL/install_db.sql" | awk '{print $1}')" = "$original_hash" ] ||
        fail "URL normalization modified the original install_db.sql"

    PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_IMPORTED_SQL="$case_dir/imported-www.sql" \
        TEST_MARIADB_CALLS="$case_dir/mariadb-calls.log" \
        DOMAIN=7.0.2.target.example \
        PROJECT_HTTPS_PORT=18443 \
        MARIADB_PASSWORD=test-password \
        USE_WWW=true \
        bash "$script_copy" > "$case_dir/output-www.log" 2>&1
    grep -Fq 'https://www.7.0.2.target.example:18443/contents/videos' "$case_dir/imported-www.sql" ||
        fail "USE_WWW target URL was not normalized"

    : > "$case_dir/mariadb-calls-invalid.log"
    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_ARCHIVE_URL_MODE=invalid \
        TEST_IMPORTED_SQL="$case_dir/imported-invalid.sql" \
        TEST_MARIADB_CALLS="$case_dir/mariadb-calls-invalid.log" \
        DOMAIN=7.0.2.target.example \
        PROJECT_HTTPS_PORT=18443 \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output-invalid.log" 2>&1; then
        fail "database import accepted an invalid archive project URL"
    fi
    [ ! -s "$case_dir/mariadb-calls-invalid.log" ] ||
        fail "MariaDB was called after archive URL validation failed"
    assert_file_contains "$case_dir/output-invalid.log" "Invalid source project URL"

    pass "database import normalizes bounded archive URLs without changing license metadata"
}

test_nginx_rewrites_are_atomic_and_non_empty() {
    local case_dir="$TMP_ROOT/rewrites"
    local site_dir="$case_dir/site"
    local includes_dir="$case_dir/includes"
    local mock_bin="$case_dir/bin"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/50-nginx-rewrites.sh"
    local archive="$case_dir/KVS_7.0.2_example.com.zip"
    local output="$case_dir/output.log"

    mkdir -p "$site_dir" "$includes_dir" "$mock_bin"
    touch "$archive"
    make_init_common_mock "$common_mock"
    sed \
        -e "s|source /init/lib/common.sh|source ${common_mock}|" \
        -e "s|NGINX_INCLUDES=\"/nginx-includes\"|NGINX_INCLUDES=\"${includes_dir}\"|" \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/50-nginx-rewrites.sh" > "$script_copy"
    cat > "$mock_bin/unzip" <<'EOF'
#!/bin/bash
if [ "${TEST_UNZIP_MODE:-fail}" = "success" ]; then
    printf '%s\n' 'location / { try_files $uri $uri/ /index.php?$args; }'
    exit 0
fi
exit 9
EOF
    chmod +x "$mock_bin/unzip"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        bash "$script_copy" > "$output" 2>&1; then
        fail "rewrite extraction failure was reported as success"
    fi
    [ ! -e "$includes_dir/kvs-rewrites.conf" ] || fail "failed extraction left a destination file"
    if find "$includes_dir" -type f -name '.kvs-rewrites.conf.*' | grep -q .; then
        fail "failed extraction left a temporary rewrite file"
    fi

    PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_UNZIP_MODE=success \
        bash "$script_copy" > "$output" 2>&1
    [ -s "$includes_dir/kvs-rewrites.conf" ] || fail "successful extraction did not install non-empty rewrites"
    assert_file_contains "$includes_dir/kvs-rewrites.conf" "try_files"
    pass "nginx rewrites use a non-empty atomic destination"
}

test_manticore_scripts_support_numeric_domains_and_internal_api() {
    local case_dir="$TMP_ROOT/manticore-scripts"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local temp_dir="$case_dir/tmp"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/80-manticore.sh"
    local kind
    local installed_file

    mkdir -p "$site_dir" "$mock_bin" "$temp_dir"
    make_init_common_mock "$common_mock"
    sed \
        -e "s|/tmp/|${temp_dir}/|g" \
        -e "s|source /init/lib/common.sh|source ${common_mock}|" \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/80-manticore.sh" > "$script_copy"

    cat > "$mock_bin/curl" <<'EOF'
#!/bin/bash
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
        shift
        : > "$1"
        exit 0
    fi
    shift
done
exit 2
EOF
    cat > "$mock_bin/unzip" <<'EOF'
#!/bin/bash
destination=${!#}
for kind in videos albums searches; do
    cat > "$destination/kvs_manticore_search_${kind}.php" <<PHP
<?php
\$manticore_host = '127.0.0.1';
\$manticore_index = 'projectname_${kind}';
\$sql_upper = "SELECT * FROM \$manticore_index WHERE MATCH(?)";
\$sql_lower = "select * from \$manticore_index where id=1";
header('Content-type: text/plain');
http_response_code(503);
die('[FATAL]: Manticore error: ' . \$e->getMessage());
PHP
done
EOF
    chmod +x "$mock_bin/curl" "$mock_bin/unzip"

    if ! PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        DOMAIN=7.0.2.target.example \
        PROJECT_HTTPS_PORT=18443 \
        ENABLE_MANTICORE=true \
        bash "$script_copy" > "$case_dir/output.log" 2>&1; then
        sed -n '1,80p' "$case_dir/output.log" >&2
        fail "Manticore script configuration failed"
    fi

    for kind in videos albums searches; do
        installed_file="$site_dir/kvs_manticore_search_${kind}.php"
        [ -f "$installed_file" ] || fail "Manticore $kind script was not installed"
        grep -Fq "\$manticore_index = '7_0_2_target_example_${kind}';" "$installed_file" ||
            fail "Manticore $kind index name was not configured"
        # shellcheck disable=SC2016
        grep -Fq 'FROM `$manticore_index`' "$installed_file" ||
            fail "uppercase Manticore index reference was not quoted"
        # shellcheck disable=SC2016
        grep -Fq 'from `$manticore_index`' "$installed_file" ||
            fail "lowercase Manticore index reference was not quoted"
        assert_file_not_contains "$installed_file" "[FATAL]"
        assert_file_contains "$installed_file" '<search_feed total_count="0" from="0" query=""></search_feed>'
    done

    # shellcheck disable=SC2016
    php -r '
        $data = unserialize(file_get_contents($argv[1]));
        $expected = "http://manticore-api:8080/";
        foreach (["api_call", "api_call_albums", "api_call_searches"] as $key) {
            if (!isset($data[$key]) || !str_starts_with($data[$key], $expected)) exit(1);
        }
        foreach (["outgoing_url", "outgoing_url_albums", "outgoing_url_searches"] as $key) {
            if (($data[$key] ?? null) !== "https://7.0.2.target.example:18443") exit(2);
        }
    ' "$site_dir/admin/data/plugins/external_search/data.dat" ||
        fail "Manticore plugin does not use the internal Nginx API port"

    grep -Fq 'listen      8080;' "$REPO_ROOT/conf/nginx/templates/kvs.conf.tpl" ||
        fail "single-site Nginx lacks the internal Manticore listener"
    grep -Fq 'listen      8080;' "$REPO_ROOT/docker/multi-site/nginx/kvs-caddy.conf.template" ||
        fail "multi-site Nginx lacks the internal Manticore listener"

    TEST_KVS_PATH="$site_dir" \
        DOMAIN=7.0.2.target.example \
        ENABLE_MANTICORE=false \
        bash "$script_copy" > "$case_dir/disabled-output.log" 2>&1
    [ ! -e "$site_dir/admin/data/plugins/external_search/data.dat" ] ||
        fail "disabling Manticore left the external-search plugin enabled"
    for kind in videos albums searches; do
        [ ! -e "$site_dir/kvs_manticore_search_${kind}.php" ] ||
            fail "disabling Manticore left the $kind API script installed"
    done

    pass "Manticore quotes numeric indexes and uses an internal non-TLS API"
}

test_project_url_uses_validated_public_https_port() {
    local common="$REPO_ROOT/docker/init/lib/common.sh"

    (
        # shellcheck source=/dev/null
        source "$common"
        # shellcheck disable=SC2034  # Read by get_project_url from the sourced file.
        DOMAIN=7.0.2.target.example
        # shellcheck disable=SC2034  # Read by get_project_url from the sourced file.
        USE_WWW=false
        # shellcheck disable=SC2034  # Read by get_project_url from the sourced file.
        PROJECT_HTTPS_PORT=18443
        [ "$(get_project_url)" = "https://7.0.2.target.example:18443" ]
        # shellcheck disable=SC2034  # Read by get_project_url from the sourced file.
        USE_WWW=true
        [ "$(get_project_url)" = "https://www.7.0.2.target.example:18443" ]
        # shellcheck disable=SC2034  # Read by get_project_url from the sourced file.
        PROJECT_HTTPS_PORT=443
        [ "$(get_project_url)" = "https://www.7.0.2.target.example" ]
        # shellcheck disable=SC2034  # Read by get_project_url from the sourced file.
        for PROJECT_HTTPS_PORT in text 0 65536; do
            if get_project_url >/dev/null 2>&1; then
                exit 1
            fi
        done
    ) || fail "project URL did not validate and preserve the public HTTPS port"

    pass "project URL validates and preserves the public HTTPS port"
}

test_permission_script_skips_empty_xargs_batches() {
    local case_dir="$TMP_ROOT/permissions"
    local site_dir="$case_dir/site"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/60-permissions.sh"

    mkdir -p \
        "$site_dir/_INSTALL" \
        "$site_dir/admin/logs" \
        "$site_dir/admin/data" \
        "$site_dir/admin/include" \
        "$site_dir/admin/smarty/cache" \
        "$site_dir/admin/smarty/template-c" \
        "$site_dir/admin/smarty/template-c-site" \
        "$site_dir/contents" \
        "$site_dir/template" \
        "$site_dir/langs" \
        "$site_dir/static"
    printf '%s\n' 'database credential fixture' > "$site_dir/admin/include/setup_db.php"
    chmod 755 "$site_dir/admin/include/setup_db.php"
    cat > "$site_dir/_INSTALL/install_permissions.sh" <<'EOF'
#!/bin/bash
cd ..
find admin/logs -type f -iname '*.never-present' | xargs chmod 666
EOF
    make_init_common_mock "$common_mock"
    sed "s|source /init/lib/common.sh|source ${common_mock}|" \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/60-permissions.sh" > "$script_copy"

    TEST_KVS_PATH="$site_dir" bash "$script_copy" > "$case_dir/output.log" 2>&1
    assert_file_not_contains "$case_dir/output.log" "missing operand"
    assert_file_contains "$site_dir/_INSTALL/install_permissions.sh" "xargs -r chmod"
    [ "$(stat -c '%a' "$site_dir/admin/include/setup_db.php")" = 600 ] ||
        fail "setup_db.php credentials remain readable by other local users"
    assert_file_not_contains "$REPO_ROOT/docker/init/docker-entrypoint.d/00-extract.sh" \
        "bash install_permissions.sh"
    pass "KVS permissions avoid empty xargs errors and run once at finalization"
}

test_final_compose_failure_is_fatal() {
    local block_file="$TMP_ROOT/compose-up-block.sh"
    local output="$TMP_ROOT/compose-up-output.log"

    awk '
        /^if log_command docker compose up -d --force-recreate; then$/ { capture = 1 }
        capture { print }
        capture && /^fi$/ { exit }
    ' "$REPO_ROOT/docker/setup.sh" > "$block_file"

    if (
        set -e
        # These names and the function are consumed by the sourced production block.
        # shellcheck disable=SC2034
        RED=''
        # shellcheck disable=SC2034
        GREEN=''
        # shellcheck disable=SC2034
        NC=''
        # shellcheck disable=SC2034
        DEBUG_LOG=/tmp/test-debug.log
        # shellcheck disable=SC2329
        log_command() { return 1; }
        # shellcheck source=/dev/null
        source "$block_file"
        echo "unexpected continuation"
    ) > "$output" 2>&1; then
        fail "setup continued after the final docker compose up failure"
    fi
    assert_file_not_contains "$output" "unexpected continuation"
    pass "final docker compose up failure terminates setup"
}

test_preflight_disk_check_measures_the_tightest_filesystem() {
    local functions_file="$TMP_ROOT/preflight-disk.sh"
    local stub_docker_root="$TMP_ROOT/docker-root"
    local output

    awk '
        $0 == "preflight_free_disk_gb() {" { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/docker/setup.sh" > "$functions_file"
    mkdir -p "$stub_docker_root"

    output=$(
        # shellcheck source=/dev/null
        source "$functions_file"
        # shellcheck disable=SC2329  # Stubs consumed by the extracted function.
        docker() { echo "$stub_docker_root"; }
        # shellcheck disable=SC2329
        df() {
            echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
            case "${*: -1}" in
                "$stub_docker_root") echo "fs 1 1 $((5 * 1024 * 1024)) 1% /data" ;;
                *) echo "fs 1 1 $((40 * 1024 * 1024)) 1% /" ;;
            esac
        }
        preflight_free_disk_gb
    )
    [ "$output" = "5 $stub_docker_root" ] || fail "the Docker root directory must win when it is the tightest: got '$output'"

    output=$(
        # shellcheck source=/dev/null
        source "$functions_file"
        # shellcheck disable=SC2329
        docker() { return 1; }
        # shellcheck disable=SC2329
        df() {
            echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
            echo "fs 1 1 $((40 * 1024 * 1024)) 1% /"
        }
        preflight_free_disk_gb
    )
    [ "${output%% *}" = "40" ] || fail "without Docker the site filesystem must be measured: got '$output'"
    [ "$output" != "${output#* /}" ] || fail "the measured path must be reported: got '$output'"

    # Docker 29: images live under the containerd root, not under data-root.
    local stub_containerd_root="$TMP_ROOT/containerd-root"
    mkdir -p "$stub_containerd_root"
    printf 'disabled_plugins = ["cri"]\nroot = "%s"\n' "$stub_containerd_root" > "$TMP_ROOT/containerd.toml"
    output=$(
        # shellcheck source=/dev/null
        source "$functions_file"
        # shellcheck disable=SC2034  # Read by the extracted production function.
        CONTAINERD_CONFIG_FILE="$TMP_ROOT/containerd.toml"
        # shellcheck disable=SC2329
        docker() {
            case "$*" in
                *DockerRootDir*) echo "$stub_docker_root" ;;
                *driver-type*) echo "io.containerd.snapshotter.v1" ;;
            esac
        }
        # shellcheck disable=SC2329
        df() {
            echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
            case "${*: -1}" in
                "$stub_containerd_root") echo "fs 1 1 $((3 * 1024 * 1024)) 1% /" ;;
                *) echo "fs 1 1 $((40 * 1024 * 1024)) 1% /data" ;;
            esac
        }
        preflight_free_disk_gb
    )
    [ "$output" = "3 $stub_containerd_root" ] || fail "the containerd root must be measured with the containerd snapshotter: got '$output'"

    pass "preflight disk check measures the site, Docker root and containerd root filesystems"
}

test_failed_step_shows_its_last_lines_and_a_full_disk() {
    local functions_file="$TMP_ROOT/report-step-failure.sh"
    local logfile="$TMP_ROOT/failed-step.log"
    local output

    awk '
        $0 == "report_step_failure() {" { capture = 1 }
        capture { print }
        capture && /^}$/ { exit }
    ' "$REPO_ROOT/docker/setup.sh" > "$functions_file"
    {
        echo "#1 [internal] load build definition from Dockerfile"
        seq 2 40 | sed 's/^/#/'
        echo "E: Write error - write (28: No space left on device)"
    } > "$logfile"

    output=$(
        # shellcheck source=/dev/null
        source "$functions_file"
        # shellcheck disable=SC2034  # Read by the extracted production function.
        DEBUG_LOG="$TMP_ROOT/setup-debug.log"
        report_step_failure "$logfile"
    )
    grep -Fq "No space left on device" <<< "$output" || fail "the last line of a failed step must be shown"
    grep -Fq "load build definition" <<< "$output" && fail "the BuildKit preamble must not crowd out the cause"
    grep -Fq "$TMP_ROOT/setup-debug.log" <<< "$output" || fail "the debug log must be named"
    grep -Fq "The filesystem is full" <<< "$output" || fail "a full filesystem must be called out"

    : > "$logfile"
    output=$(
        # shellcheck source=/dev/null
        source "$functions_file"
        report_step_failure "$logfile"
    )
    [ -z "$output" ] || fail "an empty log must print nothing: got '$output'"

    pass "failed step reports its last lines and a full disk"
}

test_optional_gum_install_failure_is_nonfatal() {
    local block_file="$TMP_ROOT/optional-gum.sh"
    local output="$TMP_ROOT/optional-gum-output.log"

    awk '
        /^# Gum only improves the interactive output/ { capture = 1 }
        capture { print }
        capture && /^install_gum .*\|\| true$/ { exit }
    ' "$REPO_ROOT/docker/setup.sh" > "$block_file"

    (
        set -e
        # shellcheck disable=SC2329  # Called by the sourced production block.
        install_gum() { return 1; }
        # shellcheck source=/dev/null
        source "$block_file"
        echo "plain-text fallback continued"
    ) > "$output" 2>&1

    assert_file_contains "$output" "plain-text fallback continued"
    pass "optional gum installation failure uses the plain-text fallback"
}

test_setup_rebuilds_init_and_optional_manticore_images() {
    local block_file="$TMP_ROOT/build-runtime-images.sh"
    local enabled_calls="$TMP_ROOT/build-enabled.log"
    local disabled_calls="$TMP_ROOT/build-disabled.log"

    awk '
        /^progress_bar "Building Nginx and initialization containers"$/ { capture = 1 }
        capture { print }
        capture && /docker compose build .*"\$\{BUILD_TARGETS\[@\]\}"/ { exit }
    ' "$REPO_ROOT/docker/setup.sh" > "$block_file"

    (
        # shellcheck disable=SC2329  # Called by the sourced production block.
        progress_bar() { :; }
        # shellcheck disable=SC2329  # Called by the sourced production block.
        run_step() { printf '%s\n' "$*" > "$enabled_calls"; }
        # shellcheck disable=SC2034  # Read by the sourced production block.
        ENABLE_MANTICORE=true
        # shellcheck disable=SC2034  # Read by the sourced production block.
        DOCKER_BUILD_FLAGS=''
        # shellcheck source=/dev/null
        source "$block_file"
    )
    grep -Fq 'docker compose build nginx kvs-init manticore' "$enabled_calls" ||
        fail "setup does not rebuild the enabled Manticore image"

    (
        # shellcheck disable=SC2329  # Called by the sourced production block.
        progress_bar() { :; }
        # shellcheck disable=SC2329  # Called by the sourced production block.
        run_step() { printf '%s\n' "$*" > "$disabled_calls"; }
        # shellcheck disable=SC2034  # Read by the sourced production block.
        ENABLE_MANTICORE=false
        # shellcheck disable=SC2034  # Read by the sourced production block.
        DOCKER_BUILD_FLAGS=''
        # shellcheck source=/dev/null
        source "$block_file"
    )
    grep -Fq 'docker compose build nginx kvs-init' "$disabled_calls" ||
        fail "setup does not rebuild the KVS initialization image"
    if grep -Fq 'manticore' "$disabled_calls"; then
        fail "setup rebuilds Manticore when the feature is disabled"
    fi

    pass "setup rebuilds initialization and enabled Manticore images"
}

make_reconfigure_docker_mock() {
    local destination="$1"

    cat > "$destination" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${TEST_DOCKER_CALLS:?}"

if [ "${1:-}" = "ps" ]; then
    printf '%s\n' kvs-php kvs-nginx kvs-acme
    exit "${TEST_DOCKER_PS_STATUS:-0}"
fi

if [[ "$*" == *'/acme.sh/'* ]] && [[ "$*" == *'Le_API'* ]]; then
    printf '%s\n' 'https://acme-v02.api.letsencrypt.org/directory'
    exit 0
fi

if [[ " $* " == *' kvs-php sh -c '* ]] &&
    [[ "$*" == *'IFS= read -r MYSQL_PWD'* ]] &&
    [[ "$*" == *'exec mariadb "$@"'* ]]; then
    submitted_password=''
    IFS= read -r submitted_password || exit 92
    sql=$(cat)
    [ "$submitted_password" = "${TEST_MARIADB_PASSWORD:?}" ] || exit 91

    case "$sql" in
        *'urls LIKE '*) printf '%s\n' 1 ;;
        *'urls REGEXP '*) printf '%s\n' 0 ;;
        *'COALESCE(streaming_skip_ssl_check'*) printf '%s\n' 0 ;;
        *'SELECT server_id, urls, streaming_skip_ssl_check'*)
            printf '%s\n' '1 https://example.com/contents/videos 0'
            ;;
        *'UPDATE ktvs_admin_servers SET '*) ;;
        *) exit 90 ;;
    esac
    exit 0
fi

if [[ " $* " == *' KVS_SNAPSHOT_PATH='*' kvs-php php -r '* ]]; then
    if [[ "$*" == *'/admin/include/setup.php'* ]]; then
        printf '%s\n' 'file|1000|1000|0600|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|YQ=='
    elif [[ "$*" == *'/plugins/external_search/data.dat'* ]]; then
        printf '%s\n' 'absent|||||'
    else
        exit 89
    fi
    exit 0
fi

if [[ " $* " == *' KVS_GUARDED_PATH='* ]] &&
    [[ "$*" == *' KVS_GUARDED_UPDATE='*' kvs-php php -r '* ]]; then
    expected_snapshot=''
    IFS= read -r expected_snapshot || exit 88
    if [[ " $* " == *' KVS_GUARDED_UPDATE=setup '* ]]; then
        [ "$expected_snapshot" = 'file|1000|1000|0600|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|YQ==' ] ||
            exit 87
        printf '%s\n' 'file|1000|1000|0600|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|Yg=='
    elif [[ " $* " == *' KVS_GUARDED_UPDATE=plugin '* ]]; then
        [ "$expected_snapshot" = 'absent|||||' ] || exit 86
        printf '%s\n' 'absent|||||'
    else
        exit 85
    fi
    exit 0
fi

exit 0
EOF
    chmod +x "$destination"
}

run_reconfigure_case() {
    local case_dir="$1"
    local domain="$2"

    mkdir -p "$case_dir/bin"
    cat > "$case_dir/.env" <<EOF
DOMAIN=${domain}
MARIADB_PASSWORD=test-password
SSL_PROVIDER=letsencrypt
USE_WWW=false
SITE_PREFIX=kvs
MODE=single
EMAIL=admin@example.com
HTTP_PORT=80
HTTPS_PORT=443
COMPOSE_PROFILES=dragonfly
EOF
    touch "$case_dir/docker-compose.yml" "$case_dir/docker-calls.log"
    make_reconfigure_docker_mock "$case_dir/bin/docker"

    (
        cd "$case_dir"
        PATH="$case_dir/bin:/usr/bin:/bin" \
            TEST_DOCKER_CALLS="$case_dir/docker-calls.log" \
            TEST_DOCKER_PS_STATUS="${TEST_DOCKER_PS_STATUS:-0}" \
            TEST_MARIADB_PASSWORD=test-password \
            "$REPO_ROOT/docker/reconfigure.sh"
    ) > "$case_dir/output.log" 2>&1
}

test_reconfigure_fails_when_container_inspection_fails() {
    local case_dir="$TMP_ROOT/reconfigure-ps-failure"

    if TEST_DOCKER_PS_STATUS=42 run_reconfigure_case "$case_dir" example.com; then
        fail "reconfigure ignored a failed Docker container inspection"
    fi
    assert_file_contains "$case_dir/output.log" \
        "ERROR: Could not inspect running containers"
    assert_file_not_contains "$case_dir/docker-calls.log" "compose"
    pass "reconfigure rejects a failed Docker container inspection"
}

test_reconfigure_issues_the_exact_requested_sans_and_installs() {
    local apex_case="$TMP_ROOT/reconfigure-apex"
    local subdomain_case="$TMP_ROOT/reconfigure-subdomain"

    run_reconfigure_case "$apex_case" example.com
    assert_file_contains "$apex_case/docker-calls.log" \
        "exec kvs-acme acme.sh --issue -d example.com --webroot /var/www/_letsencrypt --keylength ec-256 --accountemail admin@example.com -d www.example.com --server letsencrypt"
    assert_file_contains "$apex_case/docker-calls.log" \
        "exec kvs-acme acme.sh --install-cert -d example.com --ecc"
    assert_file_contains "$apex_case/output.log" "Reconfiguration Complete"
    assert_file_contains "$apex_case/docker-calls.log" \
        'exec -i kvs-php sh -c'
    assert_file_not_contains "$apex_case/docker-calls.log" 'test-password'
    assert_file_not_contains "$apex_case/docker-calls.log" \
        'UPDATE ktvs_admin_servers'
    assert_file_not_contains "$apex_case/docker-calls.log" \
        'SELECT COUNT(*) FROM ktvs_admin_servers'

    run_reconfigure_case "$subdomain_case" 7.0.2.maximemichaud.ca
    assert_file_contains "$subdomain_case/docker-calls.log" \
        "exec kvs-acme acme.sh --issue -d 7.0.2.maximemichaud.ca --webroot /var/www/_letsencrypt --keylength ec-256 --accountemail admin@example.com --server letsencrypt"
    assert_file_not_contains "$subdomain_case/docker-calls.log" "www.7.0.2.maximemichaud.ca"
    assert_file_contains "$subdomain_case/docker-calls.log" \
        "exec kvs-acme acme.sh --install-cert -d 7.0.2.maximemichaud.ca --ecc"
    pass "reconfigure issues and installs the exact requested certificate SANs"
}

test_php_password_escaping() {
    local case_dir="$TMP_ROOT/php-password"
    local site_dir="$case_dir/site"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/10-config-php.sh"
    local setup_db="$site_dir/admin/include/setup_db.php"
    local password="a&b\\c'd|e#f"
    local expected="define('DB_PASS','a&b\\\\c\\'d|e#f');"

    mkdir -p "$site_dir/admin/include"
    make_init_common_mock "$common_mock"
    sed "s|source /init/lib/common.sh|source ${common_mock}|" \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/10-config-php.sh" > "$script_copy"
    cat > "$setup_db" <<'EOF'
<?php
define('DB_HOST','localhost');
define('DB_LOGIN','old-user');
define('DB_PASS','old-password');
define('DB_DEVICE','old-database');
EOF

    TEST_KVS_PATH="$site_dir" \
        DOMAIN=example.com \
        MARIADB_PASSWORD="$password" \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1

    grep -Fqx -- "$expected" "$setup_db" || {
        sed -n "/DB_PASS/p" "$setup_db" >&2
        fail "PHP database password was not escaped correctly"
    }
    [ "$(stat -c '%a' "$setup_db")" = 600 ] ||
        fail "database credentials were exposed before final permission hardening"

    password="next&\\value's|separator#"
    expected="define('DB_PASS','next&\\\\value\\'s|separator#');"
    TEST_KVS_PATH="$site_dir" \
        DOMAIN=example.com \
        MARIADB_PASSWORD="$password" \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1
    grep -Fqx -- "$expected" "$setup_db" || fail "escaped password replacement is not repeatable"
    pass "PHP password escaping preserves ampersands, backslashes, apostrophes and separators"
}

test_help_is_side_effect_free_without_root
test_root_guard_precedes_logs_and_preflight
test_secure_logs_env_and_headless_overrides
test_headless_override_validation
test_selfsigned_headless_accepts_empty_email
test_database_import_failure_is_fatal
test_database_import_normalizes_archive_urls
test_nginx_rewrites_are_atomic_and_non_empty
test_manticore_scripts_support_numeric_domains_and_internal_api
test_project_url_uses_validated_public_https_port
test_permission_script_skips_empty_xargs_batches
test_setup_rebuilds_init_and_optional_manticore_images
test_final_compose_failure_is_fatal
test_optional_gum_install_failure_is_nonfatal
test_preflight_disk_check_measures_the_tightest_filesystem
test_failed_step_shows_its_last_lines_and_a_full_disk
test_reconfigure_fails_when_container_inspection_fails
test_reconfigure_issues_the_exact_requested_sans_and_installs
test_php_password_escaping

echo "All $TESTS_RUN Docker hardening tests passed."
