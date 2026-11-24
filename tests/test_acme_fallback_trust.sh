#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
trust=$root/docker/tls/internal-trust.sh
work=$(mktemp -d)
pid=''
cleanup() {
    if [ -n "$pid" ]; then kill -- "-$pid" 2>/dev/null || true; wait "$pid" || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
export DOMAIN=storage.test SSL_PROVIDER=letsencrypt KVS_TLS_TRUST_DIR=$work/share KVS_TLS_CA_DIR=$work/ca
export KVS_TLS_CERT_FILE=$work/live.pem KVS_TLS_WAIT_SECONDS=0
mkdir -p "$work/bin" "$work/ca" "$work/share"
cat > "$work/bin/update-ca-certificates" <<'STUB'
#!/bin/sh
cat "$KVS_TLS_CA_DIR/"*.crt > "$KVS_TLS_CA_DIR/bundle" 2>/dev/null || :
STUB
chmod +x "$work/bin/update-ca-certificates"
export PATH="$work/bin:$PATH"
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 1 \
    -subj "/CN=$DOMAIN" -addext "subjectAltName=DNS:$DOMAIN" -addext basicConstraints=critical,CA:FALSE \
    -keyout "$work/leaf.key" -out "$work/leaf.pem" >/dev/null 2>&1
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 1 \
    -subj /CN=FixtureCA -keyout "$work/ca.key" -out "$work/ca.pem" >/dev/null 2>&1
openssl x509 -x509toreq -in "$work/leaf.pem" -signkey "$work/leaf.key" -out "$work/leaf.csr" 2>/dev/null
openssl x509 -req -in "$work/leaf.csr" -CA "$work/ca.pem" -CAkey "$work/ca.key" \
    -set_serial 2 -days 1 -out "$work/public.pem" >/dev/null 2>&1
cp "$work/leaf.pem" "$KVS_TLS_CERT_FILE"
for provider in letsencrypt zerossl; do
    DOMAIN=wrong.test SSL_PROVIDER=$provider sh "$trust" publish 2> "$work/warning"
    grep -Fq WARNING "$work/warning"
    [ -f "$work/share/wrong.test.pem" ]
    [ ! -s "$work/share/wrong.test.pem" ]
done
if DOMAIN=wrong.test SSL_PROVIDER=selfsigned sh "$trust" publish; then exit 1; fi
# A stale malformed publication cannot hold up a healthy public origin.
echo invalid > "$work/share/$DOMAIN.pem"
cp "$work/leaf.pem" "$work/ca/kvs-internal-site.crt"
# shellcheck disable=SC2016  # Expanded by the application.
setsid sh "$trust" run sh -c 'test ! -s "$KVS_TLS_CA_DIR/bundle"' > "$work/stale.log" 2>&1 &
pid=$!
wait "$pid" || { cat "$work/stale.log"; exit 1; }
kill -- "-$pid" 2>/dev/null || true
pid=''
rm "$work/share/$DOMAIN.pem"
# The command starts before nginx has published anything.
# shellcheck disable=SC2016  # Expanded by the started application.
setsid sh "$trust" run sh -c 'touch "$1"; exec sleep 60' sh "$work/ready" > "$work/start.log" 2>&1 &
pid=$!
wait_for() {
    for ((i=0; i<100; i++)); do
        if "$@"; then return 0; fi
        sleep 0.05
    done
    cat "$work/start.log"
    return 1
}
wait_for test -f "$work/ready"
cp "$work/leaf.pem" "$KVS_TLS_CERT_FILE"
sh "$trust" publish
cmp "$work/leaf.pem" "$work/share/$DOMAIN.pem"
wait_for cmp -s "$work/leaf.pem" "$work/ca/bundle"
cp "$work/public.pem" "$KVS_TLS_CERT_FILE"
sh "$trust" publish
[ ! -s "$work/share/$DOMAIN.pem" ]
wait_for test ! -s "$work/ca/bundle"
kill -- "-$pid"
wait "$pid" || true
pid=''
# The reverse-proxy origin has no direct certificate exchange.
SSL_PROVIDER=none sh "$trust" publish
[ ! -e "$work/share/$DOMAIN.pem" ]
cp "$work/leaf.pem" "$work/share/$DOMAIN.pem"
SSL_PROVIDER=none sh "$trust" run true
[ ! -s "$work/ca/bundle" ]
echo 'PASS: public startup, fallback trust, issuance and revocation'
