#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT_DIR}/docker/manticore/docker-entrypoint.sh"
TEMPLATE="${ROOT_DIR}/docker/manticore/manticore.conf.template"
TEST_DIR=$(mktemp -d)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v envsubst >/dev/null 2>&1 || fail "envsubst is required"

mkdir -p "${TEST_DIR}/etc/manticoresearch" "${TEST_DIR}/var/log/manticore"
cp "$TEMPLATE" "${TEST_DIR}/etc/manticoresearch/manticore.conf.template"
sed \
    -e "s|/etc/manticoresearch|${TEST_DIR}/etc/manticoresearch|g" \
    -e "s|/var/log/manticore|${TEST_DIR}/var/log/manticore|g" \
    -e 's|exec /usr/local/bin/manticore-entrypoint.sh "$@"|exec "$@"|' \
    "$ENTRYPOINT" > "${TEST_DIR}/docker-entrypoint.sh"

export CHOWN_LOG="${TEST_DIR}/chown.log"
export CHMOD_LOG="${TEST_DIR}/chmod.log"
export GOSU_LOG="${TEST_DIR}/gosu.log"
export INDEXER_LOG="${TEST_DIR}/indexer.log"
export MARIADB_LOG="${TEST_DIR}/mariadb.log"

mariadb() {
    printf 'password=%s\n' "${MYSQL_PWD:-<unset>}" >> "$MARIADB_LOG"
    printf 'argument=%s\n' "$@" >> "$MARIADB_LOG"
    return 0
}

indexer() {
    printf '%s\n' "${TEST_EFFECTIVE_USER:-unset}" >> "$INDEXER_LOG"
    [ "${TEST_EFFECTIVE_USER:-}" = manticore ] || return 91
    echo "deterministic indexer failure" >&2
    return 37
}

service() {
    return 0
}

chown() {
    printf '%s\n' "$*" >> "$CHOWN_LOG"
}

chmod() {
    printf '%s\n' "$*" >> "$CHMOD_LOG"
    command chmod "$@"
}

gosu() {
    local target_user="${1:-}"

    printf '%s\n' "$*" >> "$GOSU_LOG"
    [ "$target_user" = manticore ] || return 92
    shift
    TEST_EFFECTIVE_USER="$target_user" "$@"
}

export -f mariadb indexer service chown chmod gosu

output=$(
    DOMAIN=example.com \
    MARIADB_PASSWORD=test-password \
    bash "${TEST_DIR}/docker-entrypoint.sh" true 2>&1
)

generated_config="${TEST_DIR}/etc/manticoresearch/manticore.conf"
# Manticore must receive these placeholders literally.
# shellcheck disable=SC2016
grep -Fq 'video_id BETWEEN $start AND $end' "$generated_config" ||
    fail "the video range placeholders were modified"
# shellcheck disable=SC2016
grep -Fq 'album_id BETWEEN $start AND $end' "$generated_config" ||
    fail "the album range placeholders were modified"
grep -Fq 'source example_com_videos' "$generated_config" ||
    fail "DOMAIN_SAFE was not substituted"
grep -Fq 'sql_pass = test-password' "$generated_config" ||
    fail "MARIADB_PASSWORD was not substituted"
[ "$(stat -c %a "$generated_config")" = 600 ] ||
    fail "the generated Manticore configuration is not mode 600"

grep -Fxq -- "-R manticore:manticore /var/lib/manticore ${TEST_DIR}/var/log/manticore" \
    "$CHOWN_LOG" || fail "Manticore data and log paths are not assigned to manticore"
grep -Fxq "manticore:manticore ${generated_config}" "$CHOWN_LOG" ||
    fail "the generated configuration is not assigned to manticore"
grep -Fxq "600 ${generated_config}" "$CHMOD_LOG" ||
    fail "the generated configuration did not receive mode 600"
grep -Fq 'manticore bash -o pipefail -c indexer --all' "$GOSU_LOG" ||
    fail "the initial index build does not pass through gosu manticore"
grep -Fxq manticore "$INDEXER_LOG" ||
    fail "the initial indexer did not execute with the manticore identity"
grep -Fxq 'password=test-password' "$MARIADB_LOG" ||
    fail "the MariaDB readiness check did not authenticate through MYSQL_PWD"
if grep '^argument=' "$MARIADB_LOG" | grep -Fq 'test-password'; then
    fail "the MariaDB password was exposed through process arguments"
fi

grep -Fq 'Initial indexing had warnings' <<< "$output" ||
    fail "an indexer failure was not reported"
if grep -Fq 'Initial indexes built successfully' <<< "$output"; then
    fail "an indexer failure was reported as successful"
fi

echo "PASS: Manticore entrypoint hardening"
