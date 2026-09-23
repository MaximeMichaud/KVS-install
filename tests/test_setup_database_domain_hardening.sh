#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-database-domain.XXXXXX)

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
extract_function verify_existing_database_domain > "$functions_file"
[ -s "$functions_file" ] || fail "could not extract verify_existing_database_domain"
# shellcheck source=/dev/null
source "$functions_file"

# shellcheck disable=SC2034  # Read by the sourced functions.
RED='' GREEN='' YELLOW='' NC='' DOMAIN=mysite.test

# The query is always the last argument of run_root_mariadb.
run_root_mariadb() {
    local query="${*: -1}"

    printf '%s\n' "$query" >> "${MOCK_CALLS:?}"
    if [ "${MOCK_QUERY_STATUS:-0}" -ne 0 ]; then
        return "$MOCK_QUERY_STATUS"
    fi
    case "$query" in
        *information_schema.schemata*) printf '%s\n' "${MOCK_SCHEMA_COUNT:-1}" ;;
        *mysql.user*) printf '%s\n' "${MOCK_USER_COUNT:-1}" ;;
        *) return 90 ;;
    esac
}

run_case() {
    local name="$1"

    MOCK_CALLS="$TEST_DIR/${name}.calls"
    : > "$MOCK_CALLS"
    verify_existing_database_domain > "$TEST_DIR/${name}.output" 2>&1
}

run_case present || fail "a matching database and user were rejected"
grep -Fq 'are present' "$TEST_DIR/present.output" ||
    fail "a matching database was not reported"
grep -Fq "schema_name='mysite.test'" "$TEST_DIR/present.calls" ||
    fail "the schema query did not target the configured domain"
grep -Fq "user='mysite.test'" "$TEST_DIR/present.calls" ||
    fail "the user query did not target the configured domain"

MOCK_SCHEMA_COUNT=0
if run_case missing-schema; then
    fail "a volume initialized for another domain was accepted"
fi
grep -Fq 'initialized for another domain' "$TEST_DIR/missing-schema.output" ||
    fail "the domain mismatch was not explained"
grep -Fq 'Restore the original DOMAIN' "$TEST_DIR/missing-schema.output" ||
    fail "the domain mismatch did not name the fix"
unset MOCK_SCHEMA_COUNT

MOCK_USER_COUNT=0
if run_case missing-user; then
    fail "a volume without the database user was accepted"
fi
unset MOCK_USER_COUNT

MOCK_QUERY_STATUS=1
run_case query-failure || fail "an inconclusive check aborted the setup"
grep -Fq 'Could not verify' "$TEST_DIR/query-failure.output" ||
    fail "an inconclusive check was not reported"
unset MOCK_QUERY_STATUS

connect_line=$(grep -nF 'Connection successful - using existing database' \
    "$ROOT_DIR/docker/setup.sh" | head -n 1 | cut -d: -f1)
verify_line=$(grep -nF 'verify_existing_database_domain || exit $?' \
    "$ROOT_DIR/docker/setup.sh" | head -n 1 | cut -d: -f1)
init_line=$(grep -nF 'progress_bar "Initializing phpMyAdmin"' \
    "$ROOT_DIR/docker/setup.sh" | head -n 1 | cut -d: -f1)
[ -n "$connect_line" ] && [ -n "$verify_line" ] && [ -n "$init_line" ] ||
    fail "the domain check call site is missing"
[ "$connect_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$init_line" ] ||
    fail "the domain check does not run between the connection check and initialization"

grep -Fq 'initialized for another domain' \
    "$ROOT_DIR/docker/init/docker-entrypoint.d/20-wait-mariadb.sh" ||
    fail "the init wait step does not explain a volume from another domain"

echo "PASS: Setup database domain hardening"
