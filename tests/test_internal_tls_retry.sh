#!/bin/bash
# Repeated syncs must repair a failed trust-store update even when the
# installation-owned certificate was already removed by the first attempt.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/docker/tls/internal-trust.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-tls-retry.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/update-ca-certificates" <<'SH'
#!/bin/sh
set -eu
printf 'update\n' >> "$TEST_CA_CALLS"
if [ "${TEST_CA_FAIL:-no}" = yes ]; then
    echo 'fixture: trust-store update failed' >&2
    exit 1
fi
# Model the bundle independently of its source files, using real PEM data.
cat "$KVS_TLS_CA_DIR"/*.crt > "$TEST_CA_BUNDLE.new"
mv "$TEST_CA_BUNDLE.new" "$TEST_CA_BUNDLE"
SH
chmod +x "$WORK/bin/update-ca-certificates"
export PATH="$WORK/bin:$PATH"
export DOMAIN=site.fixture.test SSL_PROVIDER=selfsigned

for name in site other; do
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 2 \
        -subj "/CN=$name.fixture.test" -addext "subjectAltName=DNS:$name.fixture.test" \
        -addext 'basicConstraints=critical,CA:FALSE' -addext 'extendedKeyUsage=serverAuth' \
        -keyout "$WORK/$name.key" -out "$WORK/$name.pem" > "$WORK/generate-$name.log" 2>&1
done

for mode in empty missing invalid public; do
    case_dir="$WORK/$mode"
    mkdir -p "$case_dir/ca" "$case_dir/trust"
    export KVS_TLS_CA_DIR="$case_dir/ca" KVS_TLS_TRUST_DIR="$case_dir/trust"
    export TEST_CA_BUNDLE="$case_dir/bundle.pem" TEST_CA_CALLS="$case_dir/calls"
    export TEST_CA_FAIL=no SSL_PROVIDER=selfsigned
    cp "$WORK/site.pem" "$KVS_TLS_CA_DIR/kvs-internal-site.crt"
    cp "$WORK/other.pem" "$KVS_TLS_CA_DIR/other.crt"
    update-ca-certificates
    openssl verify -CAfile "$TEST_CA_BUNDLE" -no-CApath "$WORK/site.pem" > "$case_dir/verify-before.log" 2>&1 ||
        fail "$mode fixture is not initially trusted"
    cp "$TEST_CA_BUNDLE" "$case_dir/bundle-before.pem"
    case "$mode" in
        empty) : > "$KVS_TLS_TRUST_DIR/$DOMAIN.pem" ;;
        missing) ;;
        invalid) printf 'invalid certificate\n' > "$KVS_TLS_TRUST_DIR/$DOMAIN.pem" ;;
        public) SSL_PROVIDER=letsencrypt ;;
    esac

    TEST_CA_FAIL=yes
    if sh "$SCRIPT" sync > "$case_dir/first.log" 2>&1; then
        fail "$mode accepted a failed trust-store update"
    fi
    [ ! -e "$KVS_TLS_CA_DIR/kvs-internal-site.crt" ] || fail "$mode did not reach certificate removal"
    cmp -s "$TEST_CA_BUNDLE" "$case_dir/bundle-before.pem" || fail "$mode failure did not retain the old bundle"

    TEST_CA_FAIL=no
    status=0
    sh "$SCRIPT" sync > "$case_dir/retry.log" 2>&1 || status=$?
    case "$mode" in
        empty|public) [ "$status" -eq 0 ] || fail "$mode did not recover after the updater recovered" ;;
        missing|invalid) [ "$status" -ne 0 ] || fail "$mode publication unexpectedly became ready" ;;
    esac
    [ "$(wc -l < "$TEST_CA_CALLS")" -eq 3 ] || fail "$mode skipped the trust-store update on retry"
    if openssl verify -CAfile "$TEST_CA_BUNDLE" -no-CApath "$WORK/site.pem" > "$case_dir/verify-after.log" 2>&1; then
        fail "$mode kept trusting the removed certificate after retry"
    fi
    openssl verify -CAfile "$TEST_CA_BUNDLE" -no-CApath "$WORK/other.pem" > "$case_dir/verify-other.log" 2>&1 ||
        fail "$mode removed unrelated trust"
    printf 'PASS: %s publication retries a failed trust-store update\n' "$mode"
done

echo 'All 4 internal TLS retry tests passed.'
