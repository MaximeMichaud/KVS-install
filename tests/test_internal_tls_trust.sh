#!/bin/bash
# With SSL_PROVIDER=selfsigned, docker/tls/internal-trust.sh publishes the
# nginx certificate and installs it as a root of the PHP and cron trust
# store. It must take one that cannot sign other certificates only: with a
# default "openssl req -x509" certificate (CA:TRUE), one whose key usage
# allows certificate signing, or one without basicConstraints, which GnuTLS
# (the wget of the PHP-FPM and cron images) takes as an issuer, whoever
# holds the nginx key could sign a certificate for any host and PHP and
# cron would trust it. Such a certificate is not published, an earlier
# publication of it is not installed, and PHP and cron still start, without
# that trust, rather than restart for as long as an older nginx keeps it.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/docker/tls/internal-trust.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kvs-tls-trust.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# GnuTLS takes a trusted root without basicConstraints as an issuer where
# OpenSSL does not, so a check OpenSSL alone verifies cannot pass here.
gnutls=yes
if ! command -v certtool >/dev/null 2>&1; then
    [ "${CI:-}" != true ] || fail 'certtool (gnutls-bin) is required in CI'
    gnutls=no
    echo 'SKIP: the GnuTLS checks, certtool is not installed'
fi

mkdir -p "$WORK/bin"
cat > "$WORK/bin/update-ca-certificates" <<'SH'
#!/bin/sh
set -eu
# The bundle holds every installed certificate, as the real tool builds it.
cat "$KVS_TLS_CA_DIR"/*.crt > "$TEST_CA_BUNDLE.new" 2>/dev/null || : > "$TEST_CA_BUNDLE.new"
mv "$TEST_CA_BUNDLE.new" "$TEST_CA_BUNDLE"
SH
chmod +x "$WORK/bin/update-ca-certificates"
export PATH="$WORK/bin:$PATH"
export DOMAIN=site.fixture.test SSL_PROVIDER=selfsigned
# No v3_ca defaults: the certificate gets the extensions it is given only.
printf '%s\n' '[req]' 'distinguished_name = dn' '[dn]' > "$WORK/bare.cnf"

# make_certificate <name> [openssl req arguments...]
make_certificate() {
    local name="$1"
    shift
    mkdir -p "$WORK/$name"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 2 \
        -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" "$@" \
        -keyout "$WORK/$name/key.pem" -out "$WORK/$name/cert.pem" > "$WORK/$name/generate.log" 2>&1 ||
        fail "$name: $(cat "$WORK/$name/generate.log")"
}

# What nginx generates.
make_certificate generated -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'extendedKeyUsage=serverAuth'
# CA:FALSE wins over a key usage that allows signing, for both libraries.
make_certificate ca-false-cert-sign -config "$WORK/bare.cnf" -addext 'basicConstraints=CA:FALSE' \
    -addext 'keyUsage=digitalSignature,keyCertSign'
# No basicConstraints and no key usage: OpenSSL calls it no SSL server CA,
# GnuTLS takes it as an issuer.
make_certificate bare -config "$WORK/bare.cnf"
make_certificate ca-true -addext 'basicConstraints=critical,CA:TRUE'
make_certificate cert-sign -config "$WORK/bare.cnf" -addext 'keyUsage=digitalSignature,keyCertSign'
# Valid in every way but for another host: never trusted, and not a reason
# to start without trust.
mkdir -p "$WORK/wrong-host"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 2 \
    -subj /CN=other.fixture.test -addext 'subjectAltName=DNS:other.fixture.test' \
    -addext 'basicConstraints=critical,CA:FALSE' -keyout "$WORK/wrong-host/key.pem" \
    -out "$WORK/wrong-host/cert.pem" > "$WORK/wrong-host/generate.log" 2>&1 ||
    fail "wrong-host: $(cat "$WORK/wrong-host/generate.log")"

# A server certificate for another host, signed with the key of the case,
# as whoever holds the nginx key could make one.
openssl req -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -subj /CN=other.fixture.test \
    -keyout "$WORK/other.key" -out "$WORK/other.csr" > "$WORK/other.log" 2>&1
printf '%s\n' 'subjectAltName=DNS:other.fixture.test' 'extendedKeyUsage=serverAuth' > "$WORK/other.ext"

# The certificate for another host verifies against the trust bundle, with
# OpenSSL or with GnuTLS.
other_host_trusted() {
    local case_dir="$1"
    if openssl verify -CAfile "$TEST_CA_BUNDLE" -no-CApath -purpose sslserver \
        -verify_hostname other.fixture.test "$case_dir/other.pem" > "$case_dir/verify-other.log" 2>&1; then
        return 0
    fi
    [ "$gnutls" = yes ] && [ -s "$TEST_CA_BUNDLE" ] || return 1
    certtool --verify --load-ca-certificate "$TEST_CA_BUNDLE" --verify-hostname other.fixture.test \
        --verify-purpose 1.3.6.1.5.5.7.3.1 --infile "$case_dir/other.pem" > "$case_dir/gnutls-other.log" 2>&1
}

# start_application <log> [wait seconds]: internal-trust.sh run, as the
# PHP-FPM and cron entrypoints end, with a one second wait by default. It
# runs in a process group of its own, so that the trust watcher it leaves
# behind stops with it.
start_application() {
    local log="$1" pid status=0
    # shellcheck disable=SC2016  # Expanded by the started command.
    KVS_TLS_WAIT_SECONDS="${2:-1}" setsid sh "$SCRIPT" run sh -c '
        if [ -e "$KVS_TLS_CA_DIR/kvs-internal-site.crt" ]; then
            echo "STARTED WITH INTERNAL TRUST"
        else
            echo "STARTED WITHOUT INTERNAL TRUST"
        fi' > "$log" 2>&1 &
    pid=$!
    wait "$pid" || status=$?
    kill -- "-$pid" 2>/dev/null || true
    return "$status"
}

for name in generated ca-false-cert-sign bare ca-true cert-sign; do
    case_dir="$WORK/$name"
    export KVS_TLS_CA_DIR="$case_dir/ca" KVS_TLS_TRUST_DIR="$case_dir/trust"
    export KVS_TLS_CERT_FILE="$case_dir/cert.pem" TEST_CA_BUNDLE="$case_dir/bundle.pem"
    mkdir -p "$KVS_TLS_CA_DIR" "$KVS_TLS_TRUST_DIR"
    openssl x509 -req -in "$WORK/other.csr" -CA "$case_dir/cert.pem" -CAkey "$case_dir/key.pem" \
        -set_serial 2 -days 1 -extfile "$WORK/other.ext" -out "$case_dir/other.pem" \
        > "$case_dir/sign.log" 2>&1 || fail "$name: could not sign the other host: $(cat "$case_dir/sign.log")"
    # The fixture is what its name says: the key signs a certificate that a
    # trust store holding the certificate as a root verifies, with OpenSSL
    # or GnuTLS, unless the certificate says CA:FALSE.
    cp "$case_dir/cert.pem" "$KVS_TLS_CA_DIR/fixture.crt"
    update-ca-certificates
    case "$name" in
        generated|ca-false-cert-sign)
            ! other_host_trusted "$case_dir" || fail "$name: the fixture signs certificates"
            ;;
        bare)
            ! openssl verify -CAfile "$TEST_CA_BUNDLE" -no-CApath -purpose sslserver \
                -verify_hostname other.fixture.test "$case_dir/other.pem" > /dev/null 2>&1 ||
                fail 'bare: OpenSSL takes the fixture as an issuer'
            [ "$gnutls" = no ] || other_host_trusted "$case_dir" ||
                fail 'bare: GnuTLS does not take the fixture as an issuer'
            ;;
        *)
            other_host_trusted "$case_dir" || fail "$name: the fixture does not sign certificates"
            ;;
    esac
    rm -f "$KVS_TLS_CA_DIR/fixture.crt"
    update-ca-certificates

    publish_status=0
    sh "$SCRIPT" publish > "$case_dir/publish.log" 2>&1 || publish_status=$?
    [ "$publish_status" -eq 0 ] || fail "$name: publish failed, which stops nginx: $(cat "$case_dir/publish.log")"
    case "$name" in
        generated|ca-false-cert-sign)
            cmp -s "$case_dir/cert.pem" "$KVS_TLS_TRUST_DIR/$DOMAIN.pem" ||
                fail "$name: publish did not publish a certificate that cannot sign others"
            ;;
        *)
            [ -f "$KVS_TLS_TRUST_DIR/$DOMAIN.pem" ] && [ ! -s "$KVS_TLS_TRUST_DIR/$DOMAIN.pem" ] ||
                fail "$name: publish published a certificate that may sign others"
            grep -Fxq 'WARNING: not publishing a self-signed certificate that may sign other certificates; PHP and cron get no internal TLS trust until nginx, on an image of this release, replaces it' \
                "$case_dir/publish.log" || fail "$name: publish did not say why: $(cat "$case_dir/publish.log")"
            # PHP and cron start on the empty publication, without trust.
            start_status=0
            start_application "$case_dir/start-empty.log" || start_status=$?
            { [ "$start_status" -eq 0 ] && grep -Fxq 'STARTED WITHOUT INTERNAL TRUST' "$case_dir/start-empty.log"; } ||
                fail "$name: the application did not start on the empty publication: $(cat "$case_dir/start-empty.log")"
            ;;
    esac

    # An earlier start, or a release that took it, installed the certificate:
    # sync is checked on that published file as well.
    cp "$case_dir/cert.pem" "$KVS_TLS_TRUST_DIR/$DOMAIN.pem"
    cp "$case_dir/cert.pem" "$KVS_TLS_CA_DIR/kvs-internal-site.crt"
    update-ca-certificates
    sync_status=0
    sh "$SCRIPT" sync > "$case_dir/sync.log" 2>&1 || sync_status=$?

    case "$name" in
        generated|ca-false-cert-sign)
            [ "$sync_status" -eq 0 ] || fail "$name: sync refused a certificate that cannot sign others: $(cat "$case_dir/sync.log")"
            openssl verify -CAfile "$TEST_CA_BUNDLE" -no-CApath -purpose sslserver \
                -verify_hostname "$DOMAIN" "$case_dir/cert.pem" > "$case_dir/verify.log" 2>&1 ||
                fail "$name: the site's own certificate is not trusted: $(cat "$case_dir/verify.log")"
            ;;
        *)
            [ "$sync_status" -ne 0 ] || fail "$name: sync installed a certificate that may sign others"
            grep -Fxq 'ERROR: refusing internal TLS trust that may sign other certificates' "$case_dir/sync.log" ||
                fail "$name: sync did not say why: $(cat "$case_dir/sync.log")"
            [ ! -e "$KVS_TLS_CA_DIR/kvs-internal-site.crt" ] ||
                fail "$name: sync kept a certificate that may sign others in the trust store"
            # An nginx that does not publish again leaves that file: PHP and
            # cron start without its trust once the wait is over.
            cp "$case_dir/cert.pem" "$KVS_TLS_CA_DIR/kvs-internal-site.crt"
            update-ca-certificates
            start_status=0
            start_application "$case_dir/start.log" || start_status=$?
            [ "$start_status" -eq 0 ] ||
                fail "$name: the application refused to start on the old publication: $(cat "$case_dir/start.log")"
            grep -Fxq 'WARNING: the published certificate may sign other certificates; starting without internal TLS trust until nginx publishes another one' \
                "$case_dir/start.log" || fail "$name: the start did not say why: $(cat "$case_dir/start.log")"
            grep -Fxq 'STARTED WITHOUT INTERNAL TRUST' "$case_dir/start.log" ||
                fail "$name: the application started with the old trust: $(cat "$case_dir/start.log")"
            # The wait rebuilt the trust store once, not at every retry.
            [ "$(grep -c 'refusing internal TLS trust' "$case_dir/start.log")" -eq 1 ] ||
                fail "$name: the old publication was processed again: $(cat "$case_dir/start.log")"
            # Without a wait, on the first refusal.
            cp "$case_dir/cert.pem" "$KVS_TLS_CA_DIR/kvs-internal-site.crt"
            update-ca-certificates
            start_status=0
            start_application "$case_dir/start-now.log" 0 || start_status=$?
            { [ "$start_status" -eq 0 ] && grep -Fxq 'STARTED WITHOUT INTERNAL TRUST' "$case_dir/start-now.log"; } ||
                fail "$name: the application did not start without a wait: $(cat "$case_dir/start-now.log")"
            ;;
    esac
    ! other_host_trusted "$case_dir" ||
        fail "$name: the trust store accepts a certificate for another host signed with the nginx key"
    printf 'PASS: %s\n' "$name"
done

# start_application_in_background <log> <wait seconds>: start_application
# with a longer wait, in the background; its pid in start_pid.
start_application_in_background() {
    KVS_TLS_WAIT_SECONDS="$2" setsid sh "$SCRIPT" run sh -c 'echo STARTED' > "$1" 2>&1 &
    start_pid=$!
}

# Only a publication that may sign others lets the application start without
# trust: one that goes missing while it waits stops it again.
case_dir="$WORK/ca-true"
export KVS_TLS_CA_DIR="$case_dir/ca" KVS_TLS_TRUST_DIR="$case_dir/trust"
export KVS_TLS_CERT_FILE="$case_dir/cert.pem" TEST_CA_BUNDLE="$case_dir/bundle.pem"
cp "$case_dir/cert.pem" "$KVS_TLS_TRUST_DIR/$DOMAIN.pem"
start_application_in_background "$case_dir/start-missing.log" 4
for _ in $(seq 1 100); do
    grep -q 'refusing internal TLS trust' "$case_dir/start-missing.log" && break
    sleep 0.05
done
rm -f "$KVS_TLS_TRUST_DIR/$DOMAIN.pem"
start_status=0
wait "$start_pid" || start_status=$?
kill -- "-$start_pid" 2>/dev/null || true
{ [ "$start_status" -ne 0 ] && grep -Fxq 'ERROR: internal TLS trust is not ready; refusing to start' "$case_dir/start-missing.log"; } ||
    fail "the application started once the publication was gone: $(cat "$case_dir/start-missing.log")"
printf 'PASS: %s\n' 'missing after a refusal'

# Once the application started without that trust, the watcher installs the
# next publication, and refuses the old one again when it comes back,
# revoking what it had installed.
case_dir="$WORK/switch"
export KVS_TLS_CA_DIR="$case_dir/ca" KVS_TLS_TRUST_DIR="$case_dir/trust"
export KVS_TLS_CERT_FILE="$case_dir/cert.pem" TEST_CA_BUNDLE="$case_dir/bundle.pem"
mkdir -p "$KVS_TLS_CA_DIR" "$KVS_TLS_TRUST_DIR"
# publish <fixture>: what nginx does, a rename over the shared file.
publish_fixture() {
    cp "$WORK/$1/cert.pem" "$KVS_TLS_TRUST_DIR/.next"
    mv -f "$KVS_TLS_TRUST_DIR/.next" "$KVS_TLS_TRUST_DIR/$DOMAIN.pem"
}
# installed_within <fixture or nothing>: the trust store holds it, or no
# installation-owned certificate, within ten seconds.
installed_within() {
    for _ in $(seq 1 100); do
        if [ -z "$1" ]; then
            [ ! -e "$KVS_TLS_CA_DIR/kvs-internal-site.crt" ] && return 0
        elif cmp -s "$WORK/$1/cert.pem" "$KVS_TLS_CA_DIR/kvs-internal-site.crt" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}
publish_fixture ca-true
start_application_in_background "$case_dir/start.log" 0
start_status=0
wait "$start_pid" || start_status=$?
{ [ "$start_status" -eq 0 ] && grep -Fxq STARTED "$case_dir/start.log"; } || {
    kill -- "-$start_pid" 2>/dev/null || true
    fail "the application did not start on the old publication: $(cat "$case_dir/start.log")"
}
switch_status=ok
publish_fixture generated
installed_within generated || switch_status="the next publication was not installed"
if [ "$switch_status" = ok ]; then
    publish_fixture ca-true
    installed_within '' || switch_status="the old publication came back and the trust installed since was kept"
fi
kill -- "-$start_pid" 2>/dev/null || true
[ "$switch_status" = ok ] || fail "$switch_status: $(cat "$case_dir/start.log")"
printf 'PASS: %s\n' 'old publication back after another'

# An invalid publication still stops it, as a missing one does.
case_dir="$WORK/wrong-host"
export KVS_TLS_CA_DIR="$case_dir/ca" KVS_TLS_TRUST_DIR="$case_dir/trust"
export KVS_TLS_CERT_FILE="$case_dir/cert.pem" TEST_CA_BUNDLE="$case_dir/bundle.pem"
mkdir -p "$KVS_TLS_CA_DIR" "$KVS_TLS_TRUST_DIR"
cp "$case_dir/cert.pem" "$KVS_TLS_TRUST_DIR/$DOMAIN.pem"
start_status=0
start_application "$case_dir/start.log" || start_status=$?
{ [ "$start_status" -ne 0 ] && grep -Fxq 'ERROR: internal TLS trust is not ready; refusing to start' "$case_dir/start.log"; } ||
    fail "the application started on a publication for another host: $(cat "$case_dir/start.log")"
! grep -q 'STARTED' "$case_dir/start.log" || fail 'the application ran on a publication for another host'
printf 'PASS: %s\n' 'wrong-host'

echo 'All 8 internal TLS trust tests passed.'
