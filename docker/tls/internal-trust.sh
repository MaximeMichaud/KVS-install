#!/bin/sh
# Exchange only the installation's public certificate, never its private key.
# NGINX writes the producer volume; PHP and cron mount it read-only.
set -eu

DOMAIN=${DOMAIN:-example.com}
SSL_PROVIDER=${SSL_PROVIDER:-letsencrypt}
TRUST_DIR=${KVS_TLS_TRUST_DIR:-/run/kvs-internal-tls}
CA_DIR=${KVS_TLS_CA_DIR:-/usr/local/share/ca-certificates}
CERT_FILE=${KVS_TLS_CERT_FILE:-/etc/nginx/ssl/$DOMAIN/cert.pem}
TRUST_FILE=$TRUST_DIR/$DOMAIN.pem
CA_FILE=$CA_DIR/kvs-internal-site.crt
applied_hash=''

case "$DOMAIN" in
    ''|*[!A-Za-z0-9.-]*|.*|*..*) echo 'ERROR: invalid internal TLS domain' >&2; exit 1 ;;
esac

self_signed() {
    subject=$(openssl x509 -in "$1" -noout -subject -nameopt RFC2253) || return 1
    issuer=$(openssl x509 -in "$1" -noout -issuer -nameopt RFC2253) || return 1
    [ "${subject#subject=}" = "${issuer#issuer=}" ] || return 1
    openssl verify -CAfile "$1" -no-CApath -check_ss_sig \
        -purpose sslserver -verify_hostname "$DOMAIN" "$1" >/dev/null 2>&1
}

publish() (
    mkdir -p "$TRUST_DIR"
    candidate=$(mktemp "$TRUST_DIR/.certificate.XXXXXX")
    trap 'rm -f "$candidate"' EXIT
    # An empty publication means no private trust is needed. CA-issued certs
    # keep using the system trust store. Never learn trust from the network.
    if [ "$SSL_PROVIDER" = selfsigned ]; then
        openssl x509 -in "$CERT_FILE" -out "$candidate"
        if ! self_signed "$candidate"; then
            subject=$(openssl x509 -in "$candidate" -noout -subject -nameopt RFC2253)
            issuer=$(openssl x509 -in "$candidate" -noout -issuer -nameopt RFC2253)
            if [ "${subject#subject=}" = "${issuer#issuer=}" ]; then
                echo 'ERROR: refusing an invalid self-signed certificate' >&2
                exit 1
            fi
            : > "$candidate"
        fi
    fi
    chmod 0644 "$candidate"
    if ! cmp -s "$candidate" "$TRUST_FILE"; then
        mv -f "$candidate" "$TRUST_FILE"
        echo 'Published internal TLS trust certificate'
    fi
)

remove_trust() {
    if [ -e "$CA_FILE" ]; then
        rm -f "$CA_FILE" || return 1
        update-ca-certificates >/dev/null || return 1
    fi
}

sync_trust() {
    if [ "$SSL_PROVIDER" != selfsigned ]; then
        remove_trust
        return $?
    fi
    if [ ! -f "$TRUST_FILE" ]; then
        remove_trust
        applied_hash=''
        return 1
    fi
    current_hash=$(sha256sum "$TRUST_FILE") || return 1
    [ "$current_hash" != "$applied_hash" ] || return 0
    mkdir -p "$CA_DIR" || return 1
    candidate=$(mktemp "$CA_DIR/.kvs-internal.XXXXXX") || return 1
    if [ -s "$TRUST_FILE" ]; then
        # Parse a snapshot: the producer may replace the shared file at any time.
        if ! openssl x509 -in "$TRUST_FILE" -out "$candidate" ||
            ! self_signed "$candidate"; then
            rm -f "$candidate"
            remove_trust
            applied_hash=''
            echo 'ERROR: refusing invalid internal TLS trust' >&2
            return 1
        fi
        if ! chmod 0644 "$candidate" || ! mv -f "$candidate" "$CA_FILE"; then
            rm -f "$candidate"
            return 1
        fi
        update-ca-certificates >/dev/null || return 1
    else
        rm -f "$candidate"
        remove_trust || return 1
    fi
    applied_hash=$current_hash
    echo 'Internal TLS trust synchronized; certificate verification remains enabled'
}

case "${1:-}" in
    publish) publish ;;
    sync) sync_trust ;;
    run)
        shift
        # Also load public CA files explicitly mounted by the operator (for
        # example a development CA). Private keys are never needed here.
        update-ca-certificates >/dev/null
        # NGINX depends on PHP being started, not healthy. Docker can start
        # NGINX and publish its certificate while this entrypoint waits.
        wait_seconds=${KVS_TLS_WAIT_SECONDS:-120}
        case "$wait_seconds" in ''|*[!0-9]*) exit 1 ;; esac
        while ! sync_trust; do
            if [ "$wait_seconds" -le 0 ]; then
                echo 'ERROR: internal TLS trust is not ready; refusing to start' >&2
                exit 1
            fi
            wait_seconds=$((wait_seconds - 1))
            sleep 1
        done
        if [ "$SSL_PROVIDER" = selfsigned ]; then
            # Refresh the trust store used by FPM workers and cron CLI tasks.
            # Invalid/missing publications revoke the old trust, never TLS checks.
            (while sleep 2; do sync_trust || true; done) &
        fi
        exec "$@"
        ;;
    *) echo 'Usage: internal-trust.sh publish|sync|run COMMAND [ARG...]' >&2; exit 2 ;;
esac
