#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/kvs-init-resume-hardening.XXXXXX)
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

make_common_mock() {
    local destination="$1"

    cat > "$destination" <<'EOF'
KVS_PATH=${TEST_KVS_PATH:?}
KVS_ARCHIVE_DIR=${TEST_ARCHIVE_DIR:-}

log_info() { printf '[INFO] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }
log_error() { printf '[ERROR] %s\n' "$1"; }

kvs_is_installed() {
    [ -f "$KVS_PATH/admin/include/setup.php" ]
}

find_kvs_archive() {
    printf '%s\n' "${TEST_ARCHIVE:-}"
}

db_query() {
    MYSQL_PWD="$MARIADB_PASSWORD" mariadb --test-query "$1"
}

get_project_url() {
    if [ "${USE_WWW:-false}" = "true" ]; then
        printf 'https://www.%s\n' "$DOMAIN"
    else
        printf 'https://%s\n' "$DOMAIN"
    fi
}
EOF
}

make_configure_database_common_mock() {
    local destination="$1"

    cat > "$destination" <<'EOF'
KVS_PATH=${TEST_KVS_PATH:?}
CONFIG_STATE=${TEST_CONFIG_STATE:?}

log_info() { printf '[INFO] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }
log_error() { printf '[ERROR] %s\n' "$1"; }

get_project_url() {
    local host="$DOMAIN"
    local port="${PROJECT_HTTPS_PORT:-443}"
    local suffix=''

    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if ((10#$port < 1 || 10#$port > 65535)); then
        return 1
    fi
    port=$((10#$port))
    [ "$port" -eq 443 ] || suffix=":${port}"
    [ "${USE_WWW:-false}" != true ] || host="www.${DOMAIN}"
    printf 'https://%s%s\n' "$host" "$suffix"
}

db_exec() {
    local query="$1"
    local project_url

    printf 'exec:%s\n' "$query" >> "$CONFIG_STATE/calls.log"
    if [[ "$query" == *'REGEXP_REPLACE('* ]]; then
        [ "${TEST_URL_UPDATE_FAIL:-false}" != true ] || return 41
        project_url=$(get_project_url) || return 42
        printf '%s/contents/videos\n' "$project_url" > "$CONFIG_STATE/url"
        return 0
    fi
    if [[ "$query" == *'streaming_skip_ssl_check = 1'* ]]; then
        [ "${TEST_TLS_UPDATE_FAIL:-false}" != true ] || return 43
        printf '1\n' > "$CONFIG_STATE/ssl-skip"
        return 0
    fi
    if [[ "$query" == *'streaming_skip_ssl_check = 0'* ]]; then
        [ "${TEST_TLS_UPDATE_FAIL:-false}" != true ] || return 43
        printf '0\n' > "$CONFIG_STATE/ssl-skip"
        return 0
    fi
    return 0
}

db_query() {
    local query="$1"
    local project_url
    local current_url
    local current_skip
    local expected

    printf 'query:%s\n' "$query" >> "$CONFIG_STATE/calls.log"
    [ "${TEST_DB_QUERY_FAIL:-false}" != true ] || return 44
    project_url=$(get_project_url) || return 45
    current_url=$(<"$CONFIG_STATE/url")
    current_skip=$(<"$CONFIG_STATE/ssl-skip")

    if [[ "$query" == *'urls LIKE '* ]]; then
        if [ "${TEST_URL_COUNTER_MODE:-valid}" = invalid ]; then
            printf 'invalid-counter\n'
        elif [[ "$current_url" == "${project_url}/contents/"* ]]; then
            printf '1\n'
        else
            printf '0\n'
        fi
        return 0
    fi
    if [[ "$query" == *'urls REGEXP '* ]]; then
        if [[ "$current_url" == "${project_url}/contents/"* ]]; then
            printf '0\n'
        else
            printf '1\n'
        fi
        return 0
    fi
    if [[ "$query" == *'COALESCE(streaming_skip_ssl_check'* ]]; then
        expected=${query##*<>}
        expected=${expected%%;*}
        if [ "$current_skip" = "$expected" ]; then
            printf '0\n'
        else
            printf '1\n'
        fi
        return 0
    fi
    return 46
}
EOF
}

make_script_copy() {
    local source="$1"
    local common_mock="$2"
    local destination="$3"

    sed "s|source /init/lib/common.sh|source ${common_mock}|" \
        "$source" > "$destination"
    chmod +x "$destination"
}

make_archive() {
    local case_dir="$1"
    local archive="$2"
    local final_marker="${3:-true}"
    local payload="$case_dir/archive-payload"

    mkdir -p "$payload/admin/include" "$payload/_INSTALL"
    cat > "$payload/admin/include/setup.php" <<'EOF'
<?php
$config['project_url'] = "https://licensed.example";
EOF
    printf '%s\n' 'archive-version' > "$payload/version.txt"
    cat > "$payload/_INSTALL/install_db.sql" <<'EOF'
CREATE TABLE `ktvs_options` (`variable` VARCHAR(255), `value` TEXT);
INSERT INTO storage VALUES ('https://licensed.example/contents/videos');
EOF
    if [ "$final_marker" = "true" ]; then
        printf '%s\n' \
            "insert into \`ktvs_options\`(\`variable\`,\`value\`) values ('INITIAL_VERSION','7.0.2');" \
            >> "$payload/_INSTALL/install_db.sql"
    fi
    (
        cd "$payload"
        zip -qr "$archive" .
    )
}

make_mariadb_mock() {
    local destination="$1"

    cat > "$destination" <<'EOF'
#!/bin/bash
set -euo pipefail

state=${TEST_DB_STATE:?}
mkdir -p "$state"

if [ "${MYSQL_PWD:-}" != "${MARIADB_PASSWORD:?}" ]; then
    printf 'missing MYSQL_PWD\n' >> "$state/password-errors.log"
    exit 97
fi
for argument in "$@"; do
    if [[ "$argument" == *"$MARIADB_PASSWORD"* ]]; then
        printf 'password exposed in argument: %s\n' "$argument" \
            >> "$state/password-errors.log"
        exit 98
    fi
done
printf 'MYSQL_PWD accepted\n' >> "$state/password-auth.log"

if [ "${1:-}" = "--test-query" ]; then
    query=${2:-}
    printf 'query:%s\n' "$query" >> "$state/calls.log"

    if [[ "$query" == *"information_schema.tables"* ]]; then
        if [ "${TEST_DB_INSPECTION_FAIL:-false}" = "true" ]; then
            exit 19
        fi
        if [ -f "$state/table-count" ]; then
            cat "$state/table-count"
        else
            printf '0\n'
        fi
        exit 0
    fi

    if [[ "$query" == *"INITIAL_VERSION"* ]]; then
        if [ -f "$state/initial-version" ]; then
            cat "$state/initial-version"
        fi
        exit 0
    fi

    exit 23
fi

printf 'import\n' >> "$state/calls.log"
cat > "$state/imported.sql"

case "${TEST_IMPORT_MODE:-success}" in
    fail)
        printf '3\n' > "$state/table-count"
        rm -f "$state/initial-version"
        exit 42
        ;;
    mismatch)
        printf '180\n' > "$state/table-count"
        printf '7.0.1\n' > "$state/initial-version"
        ;;
    success)
        printf '180\n' > "$state/table-count"
        sed -nE \
            "s/.*['\"]INITIAL_VERSION['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\\1/p" \
            "$state/imported.sql" | tail -n 1 > "$state/initial-version"
        ;;
    *)
        exit 24
        ;;
esac
EOF
    chmod +x "$destination"
}

count_imports() {
    local calls_file="$1"

    if [ ! -f "$calls_file" ]; then
        printf '0\n'
        return
    fi
    grep -c '^import$' "$calls_file" || true
}

test_extraction_resumes_only_the_same_archive() {
    local case_dir="$TMP_ROOT/extraction-resume"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/00-extract.sh"
    local archive="$case_dir/KVS_7.0.2_licensed.example.zip"
    local output="$case_dir/first-run.log"
    local archive_sha256

    mkdir -p "$site_dir" "$mock_bin"
    make_archive "$case_dir" "$archive"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/00-extract.sh" \
        "$common_mock" "$script_copy"

    cat > "$mock_bin/cp" <<'EOF'
#!/bin/bash
set -e
source_dir=${2%/.}
destination=${3%/}
mkdir -p "$destination/admin/include"
/usr/bin/cp "$source_dir/admin/include/setup.php" "$destination/admin/include/setup.php"
printf '%s\n' 'interrupted-promotion' > "$destination/version.txt"
exit 55
EOF
    chmod +x "$mock_bin/cp"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        bash "$script_copy" > "$output" 2>&1; then
        fail "interrupted KVS promotion was reported as successful"
    fi

    [ -f "$site_dir/.kvs-extraction-in-progress" ] ||
        fail "interrupted extraction did not keep its in-progress marker"
    [ ! -e "$site_dir/.kvs-extraction-complete" ] ||
        fail "interrupted extraction wrote its completion marker"
    assert_file_contains "$site_dir/version.txt" "interrupted-promotion"
    assert_file_contains "$output" "Could not promote the staged KVS extraction"

    archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
    assert_file_contains "$site_dir/.kvs-extraction-in-progress" "sha256=$archive_sha256"

    cp "$archive" "$case_dir/KVS_7.0.2_other.zip"
    printf '%s' 'different-archive' >> "$case_dir/KVS_7.0.2_other.zip"
    if TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$case_dir/KVS_7.0.2_other.zip" \
        bash "$script_copy" > "$case_dir/different-archive.log" 2>&1; then
        fail "interrupted extraction accepted a different archive"
    fi
    assert_file_contains "$case_dir/different-archive.log" \
        "interrupted extraction belongs to a different KVS archive"
    assert_file_contains "$site_dir/version.txt" "interrupted-promotion"

    TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        bash "$script_copy" > "$case_dir/resume.log" 2>&1

    [ -f "$site_dir/.kvs-extraction-complete" ] ||
        fail "resumed extraction did not write its completion marker"
    [ ! -e "$site_dir/.kvs-extraction-in-progress" ] ||
        fail "resumed extraction left its in-progress marker"
    assert_file_contains "$site_dir/version.txt" "archive-version"
    assert_file_contains "$case_dir/resume.log" "Resuming interrupted KVS extraction"

    printf '%s\n' 'site-customization' > "$site_dir/version.txt"
    TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        bash "$script_copy" > "$case_dir/completed-rerun.log" 2>&1
    assert_file_contains "$site_dir/version.txt" "site-customization"
    assert_file_contains "$case_dir/completed-rerun.log" \
        "KVS extraction is complete, skipping extraction"

    pass "KVS extraction resumes a marked promotion and preserves the completed site"
}

test_extraction_preserves_unmarked_existing_sites() {
    local case_dir="$TMP_ROOT/extraction-existing"
    local site_dir="$case_dir/site"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/00-extract.sh"

    mkdir -p "$site_dir/admin/include"
    printf '%s\n' 'legacy-customization' > "$site_dir/admin/include/setup.php"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/00-extract.sh" \
        "$common_mock" "$script_copy"

    TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE='' \
        bash "$script_copy" > "$case_dir/output.log" 2>&1

    assert_file_contains "$site_dir/admin/include/setup.php" "legacy-customization"
    [ ! -e "$site_dir/.kvs-extraction-complete" ] ||
        fail "legacy site was assigned an unproven completion marker"
    assert_file_contains "$case_dir/output.log" \
        "Existing KVS installation found without an extraction marker, preserving it"

    pass "unmarked legacy KVS installations are preserved without archive writes"
}

test_extraction_refuses_unknown_or_inconsistent_trees() {
    local case_dir="$TMP_ROOT/extraction-refusal"
    local site_dir="$case_dir/site"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/00-extract.sh"

    mkdir -p "$site_dir"
    printf '%s\n' 'keep-me' > "$site_dir/custom-file"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/00-extract.sh" \
        "$common_mock" "$script_copy"

    if TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE='' \
        bash "$script_copy" > "$case_dir/unknown.log" 2>&1; then
        fail "extraction accepted an unknown non-empty site tree"
    fi
    assert_file_contains "$site_dir/custom-file" "keep-me"
    assert_file_contains "$case_dir/unknown.log" "Refusing to overwrite existing files"

    rm -f "$site_dir/custom-file"
    printf '%s\n' 'archive=test.zip' > "$site_dir/.kvs-extraction-complete"
    if TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE='' \
        bash "$script_copy" > "$case_dir/inconsistent.log" 2>&1; then
        fail "extraction accepted a completion marker without setup.php"
    fi
    assert_file_contains "$case_dir/inconsistent.log" \
        "KVS extraction marker exists, but setup.php is missing"

    pass "unknown and inconsistent site trees fail without being overwritten"
}

test_incomplete_archive_never_reaches_the_live_tree() {
    local case_dir="$TMP_ROOT/extraction-invalid-archive"
    local site_dir="$case_dir/site"
    local payload="$case_dir/payload"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/00-extract.sh"
    local archive="$case_dir/KVS_7.0.2_incomplete.zip"

    mkdir -p "$site_dir" "$payload/admin/include"
    printf '%s\n' 'incomplete-setup' > "$payload/admin/include/setup.php"
    (
        cd "$payload"
        zip -qr "$archive" .
    )
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/00-extract.sh" \
        "$common_mock" "$script_copy"

    if TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        bash "$script_copy" > "$case_dir/output.log" 2>&1; then
        fail "incomplete KVS archive was promoted to the live tree"
    fi

    [ ! -e "$site_dir/admin/include/setup.php" ] ||
        fail "staging leaked setup.php from an incomplete archive"
    [ ! -e "$site_dir/.kvs-extraction-in-progress" ] ||
        fail "invalid archive wrote an in-progress marker"
    [ ! -e "$site_dir/.kvs-extraction-complete" ] ||
        fail "invalid archive wrote a completion marker"
    assert_file_contains "$case_dir/output.log" \
        "KVS archive is missing required installation files"

    pass "an incomplete archive fails entirely inside disposable staging"
}

test_complete_database_is_preserved() {
    local case_dir="$TMP_ROOT/database-complete"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"

    mkdir -p "$site_dir" "$mock_bin" "$state"
    printf '245\n' > "$state/table-count"
    printf '6.3.2\n' > "$state/initial-version"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" \
        "$common_mock" "$script_copy"
    make_mariadb_mock "$mock_bin/mariadb"

    PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_DB_STATE="$state" \
        DOMAIN=existing.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1

    [ "$(count_imports "$state/calls.log")" = "0" ] ||
        fail "complete existing database was imported again"
    assert_file_contains "$case_dir/output.log" \
        "Database import is complete (INITIAL_VERSION=6.3.2), skipping import"

    pass "a complete older database is preserved using its own final marker"
}

test_partial_database_fails_conservatively() {
    local case_dir="$TMP_ROOT/database-partial"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"

    mkdir -p "$site_dir" "$mock_bin" "$state"
    printf '37\n' > "$state/table-count"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" \
        "$common_mock" "$script_copy"
    make_mariadb_mock "$mock_bin/mariadb"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_DB_STATE="$state" \
        DOMAIN=partial.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1; then
        fail "partial database was accepted as a complete import"
    fi

    [ "$(count_imports "$state/calls.log")" = "0" ] ||
        fail "partial database was modified by a second import"
    assert_file_contains "$case_dir/output.log" \
        "Database contains 37 tables but has no valid INITIAL_VERSION marker"
    assert_file_contains "$case_dir/output.log" \
        "refusing to re-import or modify existing data"

    pass "tables without INITIAL_VERSION stop safely before re-import"
}

test_interrupted_import_is_not_retried_over_partial_tables() {
    local case_dir="$TMP_ROOT/database-interrupted"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"
    local archive="$case_dir/KVS_7.0.2_licensed.example.zip"

    mkdir -p "$site_dir" "$mock_bin" "$state"
    make_archive "$case_dir" "$archive"
    mkdir -p "$site_dir/_INSTALL"
    cp "$case_dir/archive-payload/_INSTALL/install_db.sql" \
        "$site_dir/_INSTALL/install_db.sql"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" \
        "$common_mock" "$script_copy"
    make_mariadb_mock "$mock_bin/mariadb"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_DB_STATE="$state" \
        TEST_IMPORT_MODE=fail \
        DOMAIN=target.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/first-run.log" 2>&1; then
        fail "interrupted database import was reported as successful"
    fi
    assert_file_contains "$case_dir/first-run.log" \
        "Database import failed; preserving"
    [ -f "$site_dir/_INSTALL/install_db.sql" ] ||
        fail "failed import removed the source SQL dump"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_DB_STATE="$state" \
        TEST_IMPORT_MODE=success \
        DOMAIN=target.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/retry.log" 2>&1; then
        fail "retry accepted the partial database without its final marker"
    fi

    [ "$(count_imports "$state/calls.log")" = "1" ] ||
        fail "interrupted database received a second import attempt"
    assert_file_contains "$case_dir/retry.log" \
        "A previous import may be incomplete"

    pass "an interrupted import remains explicit and is never overlaid"
}

test_successful_import_verifies_the_dump_marker() {
    local case_dir="$TMP_ROOT/database-success"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"
    local archive="$case_dir/KVS_7.0.2_licensed.example.zip"

    mkdir -p "$site_dir" "$mock_bin" "$state"
    make_archive "$case_dir" "$archive"
    mkdir -p "$site_dir/_INSTALL"
    cp "$case_dir/archive-payload/_INSTALL/install_db.sql" \
        "$site_dir/_INSTALL/install_db.sql"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" \
        "$common_mock" "$script_copy"
    make_mariadb_mock "$mock_bin/mariadb"

    PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_DB_STATE="$state" \
        TEST_IMPORT_MODE=success \
        DOMAIN=target.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1

    [ "$(count_imports "$state/calls.log")" = "1" ] ||
        fail "empty database was not imported exactly once"
    assert_file_contains "$state/imported.sql" \
        "https://target.example/contents/videos"
    assert_file_contains "$state/initial-version" "7.0.2"
    assert_file_contains "$case_dir/output.log" \
        "Database imported successfully (INITIAL_VERSION=7.0.2)"
    [ ! -e "$state/password-errors.log" ] ||
        fail "the MariaDB password was exposed through process arguments"
    [ "$(grep -Fc 'MYSQL_PWD accepted' "$state/password-auth.log")" -ge 3 ] ||
        fail "database inspection, import, and verification did not use MYSQL_PWD"

    pass "successful import verifies INITIAL_VERSION from the real dump tail"
}

test_dump_without_final_marker_is_rejected() {
    local case_dir="$TMP_ROOT/database-no-final-marker"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"
    local archive="$case_dir/KVS_7.0.2_licensed.example.zip"

    mkdir -p "$site_dir" "$mock_bin" "$state"
    make_archive "$case_dir" "$archive" false
    mkdir -p "$site_dir/_INSTALL"
    cp "$case_dir/archive-payload/_INSTALL/install_db.sql" \
        "$site_dir/_INSTALL/install_db.sql"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" \
        "$common_mock" "$script_copy"
    make_mariadb_mock "$mock_bin/mariadb"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_DB_STATE="$state" \
        DOMAIN=target.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1; then
        fail "SQL dump without a final INITIAL_VERSION marker was imported"
    fi

    [ "$(count_imports "$state/calls.log")" = "0" ] ||
        fail "invalid SQL dump reached MariaDB"
    assert_file_contains "$case_dir/output.log" \
        "install_db.sql does not end with a valid INITIAL_VERSION marker"

    pass "a dump without its own final completion marker is rejected before import"
}

test_marker_mismatch_after_import_is_fatal() {
    local case_dir="$TMP_ROOT/database-marker-mismatch"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"
    local archive="$case_dir/KVS_7.0.2_licensed.example.zip"

    mkdir -p "$site_dir" "$mock_bin" "$state"
    make_archive "$case_dir" "$archive"
    mkdir -p "$site_dir/_INSTALL"
    cp "$case_dir/archive-payload/_INSTALL/install_db.sql" \
        "$site_dir/_INSTALL/install_db.sql"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" \
        "$common_mock" "$script_copy"
    make_mariadb_mock "$mock_bin/mariadb"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_ARCHIVE="$archive" \
        TEST_DB_STATE="$state" \
        TEST_IMPORT_MODE=mismatch \
        DOMAIN=target.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1; then
        fail "database marker mismatch was reported as successful"
    fi

    assert_file_contains "$case_dir/output.log" \
        "Database import completion marker mismatch"
    assert_file_contains "$case_dir/output.log" \
        "Expected INITIAL_VERSION=7.0.2, got 7.0.1"

    pass "post-import marker mismatch remains a fatal, explicit state"
}

test_database_inspection_failure_is_not_treated_as_empty() {
    local case_dir="$TMP_ROOT/database-inspection-failure"
    local site_dir="$case_dir/site"
    local mock_bin="$case_dir/bin"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/30-import-database.sh"

    mkdir -p "$site_dir" "$mock_bin" "$state"
    make_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/30-import-database.sh" \
        "$common_mock" "$script_copy"
    make_mariadb_mock "$mock_bin/mariadb"

    if PATH="$mock_bin:/usr/bin:/bin" \
        TEST_KVS_PATH="$site_dir" \
        TEST_DB_STATE="$state" \
        TEST_DB_INSPECTION_FAIL=true \
        DOMAIN=target.example \
        MARIADB_PASSWORD=test-password \
        USE_WWW=false \
        bash "$script_copy" > "$case_dir/output.log" 2>&1; then
        fail "database inspection failure was treated as an empty database"
    fi

    [ "$(count_imports "$state/calls.log")" = "0" ] ||
        fail "database import ran after inspection failure"
    assert_file_contains "$case_dir/output.log" \
        "Could not inspect the database before import"

    pass "database inspection errors stop before any import"
}

test_existing_database_url_and_tls_state_are_synchronized() {
    local case_dir="$TMP_ROOT/database-configuration"
    local site_dir="$case_dir/site"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/40-configure-database.sh"
    local first_url
    local first_skip

    mkdir -p "$site_dir/admin/data" "$state"
    printf '%s\n' \
        'https://7.0.2.maximemichaud.ca:18445/contents/videos' > "$state/url"
    printf '0\n' > "$state/ssl-skip"
    make_configure_database_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/40-configure-database.sh" \
        "$common_mock" "$script_copy"

    TEST_KVS_PATH="$site_dir" \
        TEST_CONFIG_STATE="$state" \
        DOMAIN=7.0.2.maximemichaud.ca \
        USE_WWW=false \
        PROJECT_HTTPS_PORT=443 \
        SSL_PROVIDER=selfsigned \
        bash "$script_copy" > "$case_dir/selfsigned.log" 2>&1

    [ "$(<"$state/url")" = \
        'https://7.0.2.maximemichaud.ca/contents/videos' ] ||
        fail "existing :18445 URL was not normalized to implicit port 443"
    [ "$(<"$state/ssl-skip")" = 1 ] ||
        fail "self-signed configuration did not enable the TLS exception"
    assert_file_contains "$case_dir/selfsigned.log" \
        'Server URLs configured: https://7.0.2.maximemichaud.ca/contents/...'
    assert_file_contains "$case_dir/selfsigned.log" \
        'SSL verification disabled for self-signed certificate'

    first_url=$(<"$state/url")
    first_skip=$(<"$state/ssl-skip")
    TEST_KVS_PATH="$site_dir" \
        TEST_CONFIG_STATE="$state" \
        DOMAIN=7.0.2.maximemichaud.ca \
        USE_WWW=false \
        PROJECT_HTTPS_PORT=443 \
        SSL_PROVIDER=selfsigned \
        bash "$script_copy" > "$case_dir/idempotent.log" 2>&1
    [ "$(<"$state/url")" = "$first_url" ] &&
        [ "$(<"$state/ssl-skip")" = "$first_skip" ] ||
        fail "repeated database configuration was not idempotent"

    TEST_KVS_PATH="$site_dir" \
        TEST_CONFIG_STATE="$state" \
        DOMAIN=7.0.2.maximemichaud.ca \
        USE_WWW=true \
        PROJECT_HTTPS_PORT=18445 \
        SSL_PROVIDER=letsencrypt \
        bash "$script_copy" > "$case_dir/public.log" 2>&1

    [ "$(<"$state/url")" = \
        'https://www.7.0.2.maximemichaud.ca:18445/contents/videos' ] ||
        fail "USE_WWW with a non-default HTTPS port was not persisted"
    [ "$(<"$state/ssl-skip")" = 0 ] ||
        fail "public TLS did not re-enable certificate verification"
    assert_file_contains "$case_dir/public.log" \
        'Server URLs configured: https://www.7.0.2.maximemichaud.ca:18445/contents/...'
    assert_file_contains "$case_dir/public.log" \
        'SSL verification enabled for public certificate'

    pass "existing server URLs and TLS verification synchronize bidirectionally and idempotently"
}

test_database_configuration_errors_are_propagated() {
    local case_dir="$TMP_ROOT/database-configuration-errors"
    local site_dir="$case_dir/site"
    local state="$case_dir/state"
    local common_mock="$case_dir/common.sh"
    local script_copy="$case_dir/40-configure-database.sh"
    local original_url='https://7.0.2.maximemichaud.ca:18445/contents/videos'

    mkdir -p "$site_dir/admin/data" "$state"
    make_configure_database_common_mock "$common_mock"
    make_script_copy \
        "$REPO_ROOT/docker/init/docker-entrypoint.d/40-configure-database.sh" \
        "$common_mock" "$script_copy"

    printf '%s\n' "$original_url" > "$state/url"
    printf '7\n' > "$state/ssl-skip"
    if TEST_KVS_PATH="$site_dir" \
        TEST_CONFIG_STATE="$state" \
        TEST_URL_COUNTER_MODE=invalid \
        DOMAIN=7.0.2.maximemichaud.ca \
        USE_WWW=false \
        PROJECT_HTTPS_PORT=443 \
        SSL_PROVIDER=selfsigned \
        bash "$script_copy" > "$case_dir/invalid-counter.log" 2>&1; then
        fail "invalid URL verification counter was accepted"
    fi
    assert_file_contains "$case_dir/invalid-counter.log" \
        'Persisted server URLs do not match https://7.0.2.maximemichaud.ca'
    [ "$(<"$state/ssl-skip")" = 7 ] ||
        fail "TLS state changed after an invalid URL counter"

    printf '%s\n' "$original_url" > "$state/url"
    printf '7\n' > "$state/ssl-skip"
    if TEST_KVS_PATH="$site_dir" \
        TEST_CONFIG_STATE="$state" \
        TEST_URL_UPDATE_FAIL=true \
        DOMAIN=7.0.2.maximemichaud.ca \
        USE_WWW=false \
        PROJECT_HTTPS_PORT=443 \
        SSL_PROVIDER=selfsigned \
        bash "$script_copy" > "$case_dir/update-failure.log" 2>&1; then
        fail "database URL update failure was ignored"
    fi
    assert_file_contains "$case_dir/update-failure.log" \
        'Could not synchronize persisted server URLs'
    [ "$(<"$state/url")" = "$original_url" ] ||
        fail "failed database URL update changed persisted state"
    [ "$(<"$state/ssl-skip")" = 7 ] ||
        fail "TLS state changed after the database URL update failed"

    printf '%s\n' "$original_url" > "$state/url"
    printf '7\n' > "$state/ssl-skip"
    if TEST_KVS_PATH="$site_dir" \
        TEST_CONFIG_STATE="$state" \
        TEST_DB_QUERY_FAIL=true \
        DOMAIN=7.0.2.maximemichaud.ca \
        USE_WWW=false \
        PROJECT_HTTPS_PORT=443 \
        SSL_PROVIDER=selfsigned \
        bash "$script_copy" > "$case_dir/query-failure.log" 2>&1; then
        fail "database URL verification failure was ignored"
    fi
    assert_file_contains "$case_dir/query-failure.log" \
        'Could not verify persisted server URLs'
    [ "$(<"$state/ssl-skip")" = 7 ] ||
        fail "TLS state changed after database URL verification failed"

    printf '%s\n' 'https://7.0.2.maximemichaud.ca/contents/videos' > "$state/url"
    printf '0\n' > "$state/ssl-skip"
    if TEST_KVS_PATH="$site_dir" \
        TEST_CONFIG_STATE="$state" \
        TEST_TLS_UPDATE_FAIL=true \
        DOMAIN=7.0.2.maximemichaud.ca \
        USE_WWW=false \
        PROJECT_HTTPS_PORT=443 \
        SSL_PROVIDER=selfsigned \
        bash "$script_copy" > "$case_dir/tls-failure.log" 2>&1; then
        fail "database TLS update failure was ignored"
    fi
    assert_file_contains "$case_dir/tls-failure.log" \
        'Could not synchronize server TLS verification'
    [ "$(<"$state/ssl-skip")" = 0 ] ||
        fail "failed database TLS update changed persisted state"

    pass "invalid counters and database failures stop configuration explicitly"
}

test_extraction_resumes_only_the_same_archive
test_extraction_preserves_unmarked_existing_sites
test_extraction_refuses_unknown_or_inconsistent_trees
test_incomplete_archive_never_reaches_the_live_tree
test_complete_database_is_preserved
test_partial_database_fails_conservatively
test_interrupted_import_is_not_retried_over_partial_tables
test_successful_import_verifies_the_dump_marker
test_dump_without_final_marker_is_rejected
test_marker_mismatch_after_import_is_fatal
test_database_inspection_failure_is_not_treated_as_empty
test_existing_database_url_and_tls_state_are_synchronized
test_database_configuration_errors_are_propagated

echo "1..$TESTS_RUN"
