#!/bin/bash
# shellcheck disable=SC2034  # Variables are consumed by extracted production functions.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-setup-acme.XXXXXX)

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
{
    extract_function include_www_for_domain
    extract_function get_configured_acme_api
    extract_function acme_api_matches_provider
    extract_function configure_direct_acme_certificate
} > "$functions_file"
# shellcheck source=/dev/null
source "$functions_file"

RED=''
GREEN=''
NC=''

sleep() {
    return 0
}

run_step() {
    shift
    "$@"
}

docker() {
    printf '%s\n' "$*" >> "${MOCK_CALLS:?}"
    if [ "${1:-}" = compose ] && [ "${2:-}" = exec ] &&
        [ "${4:-}" = acme ] && [ "${5:-}" = acme.sh ]; then
        case "${6:-}" in
            --issue)
                printf '%s\n' "${MOCK_ISSUE_OUTPUT:-Cert success}"
                return "${MOCK_ISSUE_STATUS:-0}"
                ;;
            --install-cert)
                return "${MOCK_INSTALL_STATUS:-0}"
                ;;
        esac
    fi
    if [ "${1:-}" = compose ] && [ "${2:-}" = exec ] &&
        [ "${4:-}" = acme ] && [ "${5:-}" = sh ]; then
        count=0
        if [ -f "${MOCK_ACME_API_STATE:?}" ]; then
            count=$(cat "$MOCK_ACME_API_STATE")
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$MOCK_ACME_API_STATE"
        if [ "$count" -eq 1 ]; then
            printf '%s\n' "${MOCK_INITIAL_ACME_API:-__KVS_ABSENT__}"
        elif [ "$SSL_PROVIDER" = letsencrypt ]; then
            printf '%s\n' 'https://acme-v02.api.letsencrypt.org/directory'
        else
            printf '%s\n' 'https://acme.zerossl.com/v2/DV90'
        fi
        return 0
    fi
    if [ "${1:-}" = compose ] && [ "${2:-}" = exec ] &&
        [ "${4:-}" = nginx ] && [ "${5:-}" = nginx ]; then
        return "${MOCK_RELOAD_STATUS:-0}"
    fi
    return "${MOCK_START_STATUS:-0}"
}

nginx_has_public_certificate() {
    local expected_provider="${1:-public}"
    local count=${MOCK_CERT_CALL_COUNT:-0}
    local result=${MOCK_CERT_VALID:-true}
    local -a results

    count=$((count + 1))
    MOCK_CERT_CALL_COUNT=$count
    printf 'validate-certificate %s\n' "$expected_provider" >> "${MOCK_CALLS:?}"
    if [ -n "${MOCK_CERT_RESULTS:-}" ]; then
        IFS=',' read -r -a results <<< "$MOCK_CERT_RESULTS"
        if [ "$count" -le "${#results[@]}" ]; then
            result=${results[$((count - 1))]}
        else
            result=${results[$((${#results[@]} - 1))]}
        fi
    fi
    [ "$result" = true ]
}

run_case() {
    local name="$1"
    local domain="$2"
    local provider="$3"

    MOCK_CALLS="$TEST_DIR/${name}.calls"
    MOCK_ACME_API_STATE="$TEST_DIR/${name}.api-state"
    : > "$MOCK_CALLS"
    rm -f "$MOCK_ACME_API_STATE"
    export MOCK_CALLS MOCK_ACME_API_STATE
    DOMAIN="$domain"
    SSL_PROVIDER="$provider"
    EMAIL=admin@example.com
    USE_WWW=false
    MOCK_CERT_CALL_COUNT=0
    configure_direct_acme_certificate > "$TEST_DIR/${name}.output" 2>&1
}

unset MOCK_ISSUE_STATUS MOCK_INSTALL_STATUS MOCK_CERT_VALID MOCK_RELOAD_STATUS
run_case apex example.com letsencrypt
grep -Fq 'compose exec -T acme acme.sh --issue -d example.com' "$TEST_DIR/apex.calls" ||
    fail "the apex certificate was not issued"
grep -Fq -- '-d www.example.com --server letsencrypt' "$TEST_DIR/apex.calls" ||
    fail "the apex certificate omitted its required www SAN"
grep -Fq 'compose exec -T acme acme.sh --install-cert -d example.com' \
    "$TEST_DIR/apex.calls" || fail "the issued apex certificate was not installed"
grep -Fq 'compose exec -T nginx nginx -s reload' "$TEST_DIR/apex.calls" ||
    fail "Nginx was not reloaded after certificate validation"

run_case subdomain 7.0.2.maximemichaud.ca zerossl
grep -Fq -- '--accountemail admin@example.com --server zerossl' \
    "$TEST_DIR/subdomain.calls" || fail "ZeroSSL did not receive the account email"
if grep -Fq 'www.7.0.2.maximemichaud.ca' "$TEST_DIR/subdomain.calls"; then
    fail "the requested subdomain unexpectedly received a nested www SAN"
fi

MOCK_INITIAL_ACME_API='https://acme-v02.api.letsencrypt.org/directory'
export MOCK_INITIAL_ACME_API
run_case provider-switch 7.0.2.maximemichaud.ca zerossl
grep -Fq -- '--server zerossl --force' "$TEST_DIR/provider-switch.calls" ||
    fail "a Let's Encrypt to ZeroSSL transition was not forced"
unset MOCK_INITIAL_ACME_API

# acme.sh may persist the new Le_API before a forced provider transition
# fails. The still-installed certificate issuer must therefore force every
# retry independently of that mutable marker.
MOCK_INITIAL_ACME_API='https://acme.zerossl.com/v2/DV90'
MOCK_CERT_RESULTS='false,true'
export MOCK_INITIAL_ACME_API MOCK_CERT_RESULTS
run_case provider-retry 7.0.2.maximemichaud.ca zerossl
grep -Fq -- '--server zerossl --force' "$TEST_DIR/provider-retry.calls" ||
    fail "a stale certificate issuer did not force the provider retry"
[ "$(grep -Fc 'validate-certificate zerossl' "$TEST_DIR/provider-retry.calls")" -eq 2 ] ||
    fail "the requested provider was not checked before and after issuance"
unset MOCK_INITIAL_ACME_API MOCK_CERT_RESULTS

MOCK_CALLS="$TEST_DIR/issue-failure.calls"
MOCK_ACME_API_STATE="$TEST_DIR/issue-failure.api-state"
: > "$MOCK_CALLS"
rm -f "$MOCK_ACME_API_STATE"
export MOCK_CALLS MOCK_ACME_API_STATE
DOMAIN=example.com
SSL_PROVIDER=letsencrypt
EMAIL=admin@example.com
USE_WWW=false
MOCK_ISSUE_STATUS=42
MOCK_ISSUE_OUTPUT='test issuance failure'
export MOCK_ISSUE_STATUS MOCK_ISSUE_OUTPUT
if configure_direct_acme_certificate > "$TEST_DIR/issue-failure.output" 2>&1; then
    fail "a certificate issuance failure returned success"
fi
grep -Fq 'SSL certificate issue failed' "$TEST_DIR/issue-failure.output" ||
    fail "the certificate issuance failure was not explicit"
if grep -Fq -- '--install-cert' "$MOCK_CALLS"; then
    fail "installation ran after a failed certificate issuance"
fi
unset MOCK_ISSUE_STATUS MOCK_ISSUE_OUTPUT

MOCK_CALLS="$TEST_DIR/install-failure.calls"
MOCK_ACME_API_STATE="$TEST_DIR/install-failure.api-state"
: > "$MOCK_CALLS"
rm -f "$MOCK_ACME_API_STATE"
export MOCK_CALLS MOCK_ACME_API_STATE
MOCK_INSTALL_STATUS=43
export MOCK_INSTALL_STATUS
if configure_direct_acme_certificate > "$TEST_DIR/install-failure.output" 2>&1; then
    fail "a certificate installation failure returned success"
fi
[ "$(grep -Fc validate-certificate "$MOCK_CALLS")" -eq 1 ] ||
    fail "certificate validation ran again after installation failed"
unset MOCK_INSTALL_STATUS

MOCK_CALLS="$TEST_DIR/validation-failure.calls"
MOCK_ACME_API_STATE="$TEST_DIR/validation-failure.api-state"
: > "$MOCK_CALLS"
rm -f "$MOCK_ACME_API_STATE"
export MOCK_CALLS MOCK_ACME_API_STATE
MOCK_CERT_VALID=false
export MOCK_CERT_VALID
if configure_direct_acme_certificate > "$TEST_DIR/validation-failure.output" 2>&1; then
    fail "an invalid installed certificate returned success"
fi
if grep -Fq 'compose exec -T nginx nginx -s reload' "$MOCK_CALLS"; then
    fail "Nginx reloaded an invalid installed certificate"
fi
unset MOCK_CERT_VALID

MOCK_ISSUE_STATUS=2
MOCK_ISSUE_OUTPUT='Domains not changed. Skipping, Next renewal time is later.'
export MOCK_ISSUE_STATUS MOCK_ISSUE_OUTPUT
run_case skipped example.com letsencrypt
grep -Fq -- '--install-cert' "$TEST_DIR/skipped.calls" ||
    fail "an existing ACME certificate was not reinstalled"
unset MOCK_ISSUE_STATUS MOCK_ISSUE_OUTPUT

# shellcheck disable=SC2016
grep -Fq 'private_public_key=$(openssl pkey' "$ROOT_DIR/docker/setup.sh" ||
    fail "setup does not validate the certificate and private key pair"
# shellcheck disable=SC2016
grep -Fq 'checkhost "www.${DOMAIN}"' "$ROOT_DIR/docker/setup.sh" ||
    fail "setup does not validate the requested www SAN"
grep -Fq 'subject#subject=' "$ROOT_DIR/docker/setup.sh" ||
    fail "setup does not reject a self-signed ACME fallback"
grep -Fq 'openssl verify -purpose sslserver' "$ROOT_DIR/docker/setup.sh" ||
    fail "setup does not validate the public certificate trust chain"
grep -Fq 'O=ZeroSSL' "$ROOT_DIR/docker/setup.sh" ||
    fail "setup does not validate the selected public certificate issuer"

echo "PASS: Setup ACME hardening"
