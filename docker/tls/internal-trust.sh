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
# The publication last refused because it may sign other certificates, once
# its trust was removed, and whether the last sync refused it.
signing_hash=''
signing_refused=no

case "$DOMAIN" in
    ''|*[!A-Za-z0-9.-]*|.*|*..*) echo 'ERROR: invalid internal TLS domain' >&2; exit 1 ;;
esac

# The trust store takes the certificate as a root, so it must not be able to
# sign others, or whoever holds the nginx key could sign a certificate for
# any host that PHP and cron then trust. A default "openssl req -x509"
# certificate is CA:TRUE; one with no basicConstraints at all signs for
# GnuTLS, which the wget of the PHP-FPM and cron images uses, as a trusted
# root even where OpenSSL refuses; one whose key usage allows certificate
# signing signs for OpenSSL. The certificate must say CA:FALSE, and OpenSSL
# must call it no SSL server CA.
signs_no_certificate() {
    basic_constraints=$(openssl x509 -in "$1" -noout -ext basicConstraints 2>/dev/null) || return 1
    [ "$(printf '%s\n' "$basic_constraints" | sed '1d' | tr -d ' \t')" = 'CA:FALSE' ] || return 1
    openssl x509 -in "$1" -noout -purpose 2>/dev/null | grep -Fxq 'SSL server CA : No'
}

self_signed_for_domain() {
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
        if ! self_signed_for_domain "$candidate"; then
            subject=$(openssl x509 -in "$candidate" -noout -subject -nameopt RFC2253)
            issuer=$(openssl x509 -in "$candidate" -noout -issuer -nameopt RFC2253)
            if [ "${subject#subject=}" = "${issuer#issuer=}" ]; then
                echo 'ERROR: refusing an invalid self-signed certificate' >&2
                exit 1
            fi
            : > "$candidate"
        elif ! signs_no_certificate "$candidate"; then
            # nginx replaces such a pair when it starts, so only an nginx
            # image older than this script gets here. It keeps serving, and
            # PHP and cron run without the internal trust, rather than trust
            # this certificate or restart for as long as nginx keeps it.
            echo 'WARNING: not publishing a self-signed certificate that may sign other certificates; PHP and cron get no internal TLS trust until nginx, on an image of this release, replaces it' >&2
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
    rm -f "$CA_FILE" || return 1
    # A previous attempt may have removed the source certificate but failed
    # to rebuild the bundle. Its absence does not mean trust was revoked.
    update-ca-certificates >/dev/null || return 1
}

sync_trust() {
    signing_refused=no
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
    if [ "$current_hash" = "$signing_hash" ]; then
        # Refused and removed already: wait for another publication without
        # rebuilding the trust store every two seconds.
        signing_refused=yes
        return 1
    fi
    mkdir -p "$CA_DIR" || return 1
    candidate=$(mktemp "$CA_DIR/.kvs-internal.XXXXXX") || return 1
    if [ -s "$TRUST_FILE" ]; then
        # Parse a snapshot: the producer may replace the shared file at any time.
        if ! openssl x509 -in "$TRUST_FILE" -out "$candidate" ||
            ! self_signed_for_domain "$candidate"; then
            rm -f "$candidate"
            remove_trust
            applied_hash=''
            echo 'ERROR: refusing invalid internal TLS trust' >&2
            return 1
        fi
        if ! signs_no_certificate "$candidate"; then
            # What nginx published before this script refused it.
            rm -f "$candidate"
            applied_hash=''
            echo 'ERROR: refusing internal TLS trust that may sign other certificates' >&2
            remove_trust || return 1
            signing_hash=$current_hash
            signing_refused=yes
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
    # A refused publication that comes back is checked, and refused, again.
    signing_hash=''
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
                if [ "$signing_refused" = yes ]; then
                    # An nginx image older than this script keeps such a
                    # pair, and an nginx that is not restarted publishes
                    # nothing new: start without that trust rather than
                    # restart for good. The watcher below takes the next
                    # publication.
                    echo 'WARNING: the published certificate may sign other certificates; starting without internal TLS trust until nginx publishes another one' >&2
                    break
                fi
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
