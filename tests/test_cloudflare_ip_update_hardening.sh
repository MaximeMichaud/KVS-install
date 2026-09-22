#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/conf/nginx/scripts/update-cloudflare-ip-list.sh"
TEST_DIR=$(mktemp -d)
TARGET_FILE="${TEST_DIR}/cloudflare-ip-list.conf"

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

curl() {
    local url="${*: -1}"

    case "$url" in
        *ips-v4)
            if [ "${MOCK_CURL_MODE:-success}" = invalid-ipv4-octet ]; then
                printf '%s\n' '999.51.100.0/24'
                return 0
            fi
            if [ "${MOCK_CURL_MODE:-success}" = invalid-ipv4-prefix ]; then
                printf '%s\n' '198.51.100.0/33'
                return 0
            fi
            printf '%s\n' '198.51.100.0/24' '203.0.113.0/24'
            ;;
        *ips-v6)
            if [ "${MOCK_CURL_MODE:-success}" = fail-ipv6 ]; then
                return 22
            fi
            if [ "${MOCK_CURL_MODE:-success}" = invalid-ipv6-address ]; then
                printf '%s\n' '2001::db8::/32'
                return 0
            fi
            if [ "${MOCK_CURL_MODE:-success}" = invalid-ipv6-prefix ]; then
                printf '%s\n' '2001:db8::/129'
                return 0
            fi
            printf '%s\n' '2001:db8::/32' '2001:db8:1:2:3:4:5:6/64'
            ;;
        *)
            return 22
            ;;
    esac
}
export -f curl

assert_failed_update_preserves_target() {
    local mode="$1"
    local before_failure
    local after_failure
    local failure_status

    printf '%s\n' 'set_real_ip_from 192.0.2.0/24;' > "$TARGET_FILE"
    before_failure=$(sha256sum "$TARGET_FILE")
    set +e
    MOCK_CURL_MODE="$mode" CLOUDFLARE_IP_LIST_FILE="$TARGET_FILE" \
        bash "$SCRIPT" >/dev/null 2>&1
    failure_status=$?
    set -e
    after_failure=$(sha256sum "$TARGET_FILE")

    [ "$failure_status" -ne 0 ] || fail "${mode}: invalid input returned success"
    [ "$before_failure" = "$after_failure" ] || fail "${mode}: invalid input replaced the target"
    if compgen -G "${TARGET_FILE}.tmp.*" >/dev/null; then
        fail "${mode}: invalid input left a temporary file"
    fi
}

grep -Fq \
    'CLOUDFLARE_IP_LIST_FILE:-/etc/nginx/globals/cloudflare-ip-list.conf' \
    "$SCRIPT" || fail "the production target does not default to /etc/nginx/globals"
if grep -Fq '/etc/nginx/mich/' "$SCRIPT"; then
    fail "the obsolete /etc/nginx/mich target is still present"
fi

printf '%s\n' 'set_real_ip_from 192.0.2.0/24;' > "$TARGET_FILE"
chmod 0640 "$TARGET_FILE"

CLOUDFLARE_IP_LIST_FILE="$TARGET_FILE" bash "$SCRIPT"
first_checksum=$(sha256sum "$TARGET_FILE")
CLOUDFLARE_IP_LIST_FILE="$TARGET_FILE" bash "$SCRIPT"
second_checksum=$(sha256sum "$TARGET_FILE")

[ "$first_checksum" = "$second_checksum" ] || fail "repeated updates are not idempotent"
[ "$(stat -c '%a' "$TARGET_FILE")" = 640 ] || fail "the target mode was not preserved"
[ "$(wc -l < "$TARGET_FILE")" -eq 4 ] || fail "the generated range count is incorrect"
grep -Fxq 'set_real_ip_from 198.51.100.0/24;' "$TARGET_FILE" ||
    fail "the IPv4 ranges were not written"
grep -Fxq 'set_real_ip_from 2001:db8::/32;' "$TARGET_FILE" ||
    fail "the IPv6 ranges were not written"

for failure_mode in \
    fail-ipv6 \
    invalid-ipv4-octet \
    invalid-ipv4-prefix \
    invalid-ipv6-address \
    invalid-ipv6-prefix
do
    assert_failed_update_preserves_target "$failure_mode"
done

echo "PASS: Cloudflare IP update hardening"
