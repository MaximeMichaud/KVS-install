#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT_DIR}/docker/nginx/docker-entrypoint.sh"
TEST_DIR=$(mktemp -d)
REAL_OPENSSL=$(type -P openssl || true)
MONITOR_PID=''

cleanup() {
    if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -n "$REAL_OPENSSL" ] || fail "OpenSSL is required"

line_number() {
    local file="$1"
    local text="$2"
    local line

    line=$(grep -nF "$text" "$file" | head -n 1 | cut -d: -f1)
    [ -n "$line" ] || fail "missing Nginx rule in ${file}: ${text}"
    printf '%s\n' "$line"
}

assert_protected_locations_precede_php() {
    local file="$1"
    local php_line
    local protected_line
    local rule

    php_line=$(line_number "$file" 'location ~ \.php$ {')
    for rule in \
        'location ~* /blocks/.*\.php$ {' \
        'location ~* /langs/.*\.php$ {' \
        'location ~* /template/.*\.php$ {' \
        'location ~* /tmp/.*\.php$ {' \
        'location ~ /\. {' \
        'location ~ ^/(admin/include|tmp)/ {'
    do
        protected_line=$(line_number "$file" "$rule")
        [ "$protected_line" -lt "$php_line" ] ||
            fail "protected rule follows the generic PHP handler in ${file}: ${rule}"
    done
}

generate_fixture_pair() {
    local name="$1"
    local primary_domain="$2"
    local include_www="${3:-true}"
    local extra_san="${4:-}"
    local pair_dir="${TEST_DIR}/fixtures/${name}"
    local certificate_san="DNS:${primary_domain}"

    if [ "$include_www" = true ]; then
        certificate_san="${certificate_san},DNS:www.${primary_domain}"
    fi
    if [ -n "$extra_san" ]; then
        certificate_san="${certificate_san},DNS:${extra_san}"
    fi

    mkdir -p "$pair_dir"
    "$REAL_OPENSSL" req -x509 -nodes -days 1 -newkey rsa:1024 \
        -keyout "${pair_dir}/key.pem" \
        -out "${pair_dir}/cert.pem" \
        -subj "/CN=${primary_domain}" \
        -addext "subjectAltName=${certificate_san}" \
        >/dev/null 2>&1
}

generate_timed_fixture_pair() {
    local name="$1"
    local primary_domain="$2"
    local start_date="$3"
    local end_date="$4"
    local pair_dir="${TEST_DIR}/fixtures/${name}"
    local config_file="${pair_dir}/openssl.cnf"

    mkdir -p "${pair_dir}/newcerts"
    : > "${pair_dir}/index.txt"
    printf '%s\n' '1000' > "${pair_dir}/serial"
    "$REAL_OPENSSL" req -new -nodes -newkey rsa:1024 \
        -keyout "${pair_dir}/key.pem" \
        -out "${pair_dir}/request.pem" \
        -subj "/CN=${primary_domain}" >/dev/null 2>&1
    sed \
        -e "s|__PAIR_DIR__|${pair_dir}|g" \
        -e "s|__PRIMARY_DOMAIN__|${primary_domain}|g" \
        > "$config_file" <<'EOF'
[ ca ]
default_ca = test_ca

[ test_ca ]
dir = __PAIR_DIR__
database = $dir/index.txt
new_certs_dir = $dir/newcerts
certificate = $dir/cert.pem
private_key = $dir/key.pem
serial = $dir/serial
default_md = sha256
policy = policy_any
x509_extensions = certificate_extensions

[ policy_any ]
commonName = supplied

[ certificate_extensions ]
basicConstraints = CA:false
subjectAltName = DNS:__PRIMARY_DOMAIN__,DNS:www.__PRIMARY_DOMAIN__
EOF
    "$REAL_OPENSSL" ca -batch -selfsign -notext \
        -config "$config_file" \
        -in "${pair_dir}/request.pem" \
        -out "${pair_dir}/cert.pem" \
        -startdate "$start_date" \
        -enddate "$end_date" >/dev/null 2>&1
}

generate_fixture_pair pair-a example.com
generate_fixture_pair pair-b example.com
generate_fixture_pair wrong-host other.example
generate_fixture_pair extra-san example.com true unexpected.example
generate_fixture_pair subdomain-only 7.0.2.maximemichaud.ca false
generate_fixture_pair monitor-a renew.example.com false
generate_fixture_pair monitor-b renew.example.com false
generate_timed_fixture_pair expired example.com 20000101000000Z 20000102000000Z
generate_timed_fixture_pair future example.com \
    "$(date -u -d '+1 day' +%Y%m%d%H%M%SZ)" \
    "$(date -u -d '+2 days' +%Y%m%d%H%M%SZ)"
mkdir -p "${TEST_DIR}/fixtures/cn-only"
"$REAL_OPENSSL" req -x509 -nodes -days 1 -newkey rsa:1024 \
    -keyout "${TEST_DIR}/fixtures/cn-only/key.pem" \
    -out "${TEST_DIR}/fixtures/cn-only/cert.pem" \
    -subj /CN=example.com >/dev/null 2>&1
export REAL_OPENSSL
export TEST_GENERATED_KEY="${TEST_DIR}/fixtures/pair-b/key.pem"
export TEST_GENERATED_CERT="${TEST_DIR}/fixtures/pair-b/cert.pem"

openssl() {
    local key_file=''
    local cert_file=''

    if [ "${1:-}" != req ]; then
        "$REAL_OPENSSL" "$@"
        return
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -keyout)
                key_file="$2"
                shift 2
                ;;
            -out)
                cert_file="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    cp "$TEST_GENERATED_KEY" "$key_file"
    cp "$TEST_GENERATED_CERT" "$cert_file"
}
export -f openssl

assert_valid_pair() {
    local name="$1"
    local ssl_dir="$2"
    local cert_public_key
    local key_public_key
    local not_before
    local not_before_epoch
    local actual_dns_names

    cert_public_key=$(
        "$REAL_OPENSSL" x509 -in "${ssl_dir}/cert.pem" -pubkey -noout 2>/dev/null
    ) || fail "${name}: certificate is not parseable"
    key_public_key=$(
        "$REAL_OPENSSL" pkey -in "${ssl_dir}/key.pem" -pubout -passin pass: 2>/dev/null
    ) || fail "${name}: private key is not parseable"
    [ "$cert_public_key" = "$key_public_key" ] || fail "${name}: certificate and key do not match"
    not_before=$(LC_ALL=C "$REAL_OPENSSL" x509 -in "${ssl_dir}/cert.pem" -noout -startdate)
    not_before=${not_before#notBefore=}
    not_before_epoch=$(LC_ALL=C date -u -d "$not_before" +%s)
    [ "$not_before_epoch" -le "$(date -u +%s)" ] ||
        fail "${name}: certificate is not valid yet"
    "$REAL_OPENSSL" x509 -in "${ssl_dir}/cert.pem" -noout -checkend 0 >/dev/null 2>&1 ||
        fail "${name}: certificate is expired"
    "$REAL_OPENSSL" x509 -in "${ssl_dir}/cert.pem" -noout -checkhost example.com >/dev/null 2>&1 ||
        fail "${name}: certificate does not cover example.com"
    "$REAL_OPENSSL" x509 -in "${ssl_dir}/cert.pem" -noout -checkhost www.example.com >/dev/null 2>&1 ||
        fail "${name}: certificate does not cover www.example.com"
    actual_dns_names=$(
        "$REAL_OPENSSL" x509 -in "${ssl_dir}/cert.pem" -noout -ext subjectAltName |
            sed '1d' | tr ',' '\n' |
            sed -n 's/^[[:space:]]*DNS://p' | LC_ALL=C sort
    )
    [ "$actual_dns_names" = $'example.com\nwww.example.com' ] ||
        fail "${name}: certificate does not contain the exact requested DNS SAN set"
}

run_certificate_case() {
    local name="$1"
    local initial_state="$2"
    local case_dir="${TEST_DIR}/${name}"
    local ssl_dir="${case_dir}/etc/nginx/ssl/example.com"
    local before_cert=''
    local before_key=''

    mkdir -p "$ssl_dir" "${case_dir}/etc/nginx/templates" "${case_dir}/etc/nginx/conf.d"
    cp "${ROOT_DIR}/conf/nginx/templates/kvs.conf.tpl" \
        "${case_dir}/etc/nginx/templates/kvs.conf.tpl"
    sed \
        -e "s|/etc/nginx|${case_dir}/etc/nginx|g" \
        -e 's|exec /docker-entrypoint.sh "$@"|exec "$@"|' \
        -e '/^[[:space:]]*monitor_certificate_changes &$/c\    : # Tested separately below.' \
        "$ENTRYPOINT" > "${case_dir}/docker-entrypoint.sh"

    case "$initial_state" in
        missing)
            ;;
        certificate-only)
            cp "${TEST_DIR}/fixtures/pair-a/cert.pem" "${ssl_dir}/cert.pem"
            ;;
        key-only)
            cp "${TEST_DIR}/fixtures/pair-a/key.pem" "${ssl_dir}/key.pem"
            ;;
        empty-certificate)
            : > "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/pair-a/key.pem" "${ssl_dir}/key.pem"
            ;;
        empty-key)
            cp "${TEST_DIR}/fixtures/pair-a/cert.pem" "${ssl_dir}/cert.pem"
            : > "${ssl_dir}/key.pem"
            ;;
        valid)
            cp "${TEST_DIR}/fixtures/pair-a/cert.pem" "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/pair-a/key.pem" "${ssl_dir}/key.pem"
            before_cert=$(sha256sum "${ssl_dir}/cert.pem")
            before_key=$(sha256sum "${ssl_dir}/key.pem")
            ;;
        mismatched)
            cp "${TEST_DIR}/fixtures/pair-a/cert.pem" "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/pair-b/key.pem" "${ssl_dir}/key.pem"
            ;;
        corrupt-certificate)
            printf '%s\n' 'not a certificate' > "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/pair-a/key.pem" "${ssl_dir}/key.pem"
            ;;
        corrupt-key)
            cp "${TEST_DIR}/fixtures/pair-a/cert.pem" "${ssl_dir}/cert.pem"
            printf '%s\n' 'not a private key' > "${ssl_dir}/key.pem"
            ;;
        wrong-host)
            cp "${TEST_DIR}/fixtures/wrong-host/cert.pem" "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/wrong-host/key.pem" "${ssl_dir}/key.pem"
            ;;
        cn-only)
            cp "${TEST_DIR}/fixtures/cn-only/cert.pem" "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/cn-only/key.pem" "${ssl_dir}/key.pem"
            ;;
        extra-san)
            cp "${TEST_DIR}/fixtures/extra-san/cert.pem" "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/extra-san/key.pem" "${ssl_dir}/key.pem"
            ;;
        expired)
            cp "${TEST_DIR}/fixtures/expired/cert.pem" "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/expired/key.pem" "${ssl_dir}/key.pem"
            ;;
        future)
            cp "${TEST_DIR}/fixtures/future/cert.pem" "${ssl_dir}/cert.pem"
            cp "${TEST_DIR}/fixtures/future/key.pem" "${ssl_dir}/key.pem"
            ;;
    esac

    DOMAIN=example.com USE_WWW=false SSL_PROVIDER=selfsigned \
        bash "${case_dir}/docker-entrypoint.sh" true >/dev/null

    assert_valid_pair "$name" "$ssl_dir"

    if [ "$initial_state" = valid ]; then
        [ "$(sha256sum "${ssl_dir}/cert.pem")" = "$before_cert" ] ||
            fail "a valid certificate was replaced"
        [ "$(sha256sum "${ssl_dir}/key.pem")" = "$before_key" ] ||
            fail "a valid private key was replaced"
    fi
}

run_public_port_case() {
    local domain='7.0.2.maximemichaud.ca'
    local case_dir="${TEST_DIR}/public-port"
    local ssl_dir="${case_dir}/etc/nginx/ssl/${domain}"
    local generated_config="${case_dir}/etc/nginx/conf.d/kvs.conf"
    local before_cert
    local before_key

    mkdir -p "$ssl_dir" "${case_dir}/etc/nginx/templates" \
        "${case_dir}/etc/nginx/conf.d"
    cp "${TEST_DIR}/fixtures/subdomain-only/cert.pem" "${ssl_dir}/cert.pem"
    cp "${TEST_DIR}/fixtures/subdomain-only/key.pem" "${ssl_dir}/key.pem"
    cp "${ROOT_DIR}/conf/nginx/templates/kvs.conf.tpl" \
        "${case_dir}/etc/nginx/templates/kvs.conf.tpl"
    sed \
        -e "s|/etc/nginx|${case_dir}/etc/nginx|g" \
        -e 's|exec /docker-entrypoint.sh "$@"|exec "$@"|' \
        -e '/^[[:space:]]*monitor_certificate_changes &$/c\    : # Tested separately below.' \
        "$ENTRYPOINT" > "${case_dir}/docker-entrypoint.sh"

    before_cert=$(sha256sum "${ssl_dir}/cert.pem")
    before_key=$(sha256sum "${ssl_dir}/key.pem")
    DOMAIN="$domain" USE_WWW=false SSL_PROVIDER=selfsigned PROJECT_HTTPS_PORT=18445 \
        bash "${case_dir}/docker-entrypoint.sh" true >/dev/null

    [ "$(sha256sum "${ssl_dir}/cert.pem")" = "$before_cert" ] ||
        fail "a valid subdomain-only certificate was replaced"
    [ "$(sha256sum "${ssl_dir}/key.pem")" = "$before_key" ] ||
        fail "a valid subdomain-only private key was replaced"
    grep -Eq "server_name[[:space:]]+${domain};" "$generated_config" ||
        fail "the requested subdomain is absent from the generated Nginx config"
    if grep -Fq "www.${domain}" "$generated_config"; then
        fail "a nested www hostname was generated for a subdomain"
    fi
    # shellcheck disable=SC2016
    grep -Fq "return 301 https://${domain}:18445\$request_uri;" "$generated_config" ||
        fail "the HTTP redirect lost the custom public HTTPS port"
    # shellcheck disable=SC2016
    [ "$(grep -Fc 'fastcgi_param HTTP_HOST $host;' "$generated_config")" -eq 2 ] ||
        fail "FastCGI HTTP_HOST is not normalized without the public port"
    [ "$(grep -Fc 'fastcgi_param SERVER_PORT 18445;' "$generated_config")" -eq 2 ] ||
        fail "FastCGI SERVER_PORT does not expose the custom public HTTPS port"
}

assert_invalid_public_port() {
    local invalid_port="$1"
    local output_file="${TEST_DIR}/invalid-port-${invalid_port}.log"

    if PROJECT_HTTPS_PORT="$invalid_port" SSL_PROVIDER=none \
        sh "$ENTRYPOINT" true >"$output_file" 2>&1; then
        fail "an invalid public HTTPS port was accepted: ${invalid_port}"
    fi
    grep -Fq 'ERROR: PROJECT_HTTPS_PORT' "$output_file" ||
        fail "an invalid public HTTPS port failed without a clear error: ${invalid_port}"
}

test_certificate_monitor() {
    local domain='renew.example.com'
    local case_dir="${TEST_DIR}/certificate-monitor"
    local ssl_dir="${case_dir}/ssl/${domain}"
    local monitor_function="${case_dir}/monitor-function.sh"
    local mock_dir="${case_dir}/bin"

    mkdir -p "$ssl_dir" "$mock_dir"
    cp "${TEST_DIR}/fixtures/monitor-a/cert.pem" "${ssl_dir}/cert.pem"
    cp "${TEST_DIR}/fixtures/monitor-a/key.pem" "${ssl_dir}/key.pem"

    awk '
        /^monitor_certificate_changes\(\) \($/ { capture = 1 }
        capture { print }
        capture && /^\)$/ { exit }
    ' "$ENTRYPOINT" |
        sed "s|/etc/nginx/ssl|${case_dir}/ssl|g" > "$monitor_function"
    grep -Fq 'nginx -t' "$monitor_function" ||
        fail "the certificate monitor does not validate Nginx before reload"
    grep -Fq 'nginx -s reload' "$monitor_function" ||
        fail "the certificate monitor does not reload Nginx"

    cat > "${mock_dir}/sleep" <<'EOF'
#!/bin/sh
if [ "${1:-}" = 1 ]; then
    if [ -e "$TEST_RELOAD_FILE" ]; then
        exit 1
    fi
    : > "$TEST_MONITOR_READY"
    while [ ! -e "$TEST_MONITOR_TRIGGER" ]; do
        "$TEST_REAL_SLEEP" 0.02
    done
    exit 0
fi
exec "$TEST_REAL_SLEEP" "$@"
EOF
    cat > "${mock_dir}/nginx" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_NGINX_LOG"
case "$*" in
    -t)
        exit 0
        ;;
    '-s reload')
        : > "$TEST_RELOAD_FILE"
        exit 0
        ;;
esac
exit 97
EOF
    chmod 0755 "${mock_dir}/sleep" "${mock_dir}/nginx"

    export TEST_MONITOR_READY="${case_dir}/ready"
    export TEST_MONITOR_TRIGGER="${case_dir}/trigger"
    export TEST_RELOAD_FILE="${case_dir}/reloaded"
    export TEST_NGINX_LOG="${case_dir}/nginx.log"
    export TEST_REAL_SLEEP
    TEST_REAL_SLEEP=$(type -P sleep)

    # shellcheck source=/dev/null
    . "$monitor_function"
    PATH="${mock_dir}:${PATH}" DOMAIN="$domain" CERTIFICATE_RELOAD_INTERVAL=1 \
        monitor_certificate_changes >"${case_dir}/monitor.log" 2>&1 &
    MONITOR_PID=$!

    for _ in $(seq 1 100); do
        [ -e "$TEST_MONITOR_READY" ] && break
        "$TEST_REAL_SLEEP" 0.02
    done
    [ -e "$TEST_MONITOR_READY" ] || fail "the certificate monitor did not start"

    cp "${TEST_DIR}/fixtures/monitor-b/cert.pem" "${ssl_dir}/cert.pem"
    cp "${TEST_DIR}/fixtures/monitor-b/key.pem" "${ssl_dir}/key.pem"
    : > "$TEST_MONITOR_TRIGGER"

    for _ in $(seq 1 100); do
        [ -e "$TEST_RELOAD_FILE" ] && break
        "$TEST_REAL_SLEEP" 0.02
    done
    [ -e "$TEST_RELOAD_FILE" ] || fail "a certificate change did not reload Nginx"
    wait "$MONITOR_PID" || fail "the certificate monitor exited unexpectedly"
    MONITOR_PID=''

    [ "$(grep -Fxc -- '-t' "$TEST_NGINX_LOG")" -eq 1 ] ||
        fail "the certificate monitor did not run exactly one Nginx validation"
    [ "$(grep -Fxc -- '-s reload' "$TEST_NGINX_LOG")" -eq 1 ] ||
        fail "the certificate monitor did not run exactly one Nginx reload"
    grep -Fq 'Reloaded Nginx after a certificate change' "${case_dir}/monitor.log" ||
        fail "the successful certificate reload was not reported"
    grep -Fq 'monitor_certificate_changes &' "$ENTRYPOINT" ||
        fail "the certificate monitor is defined but never started"
}

assert_protected_locations_precede_php \
    "${ROOT_DIR}/conf/nginx/templates/kvs.conf.tpl"
assert_protected_locations_precede_php \
    "${ROOT_DIR}/docker/multi-site/nginx/kvs-caddy.conf.template"

run_certificate_case neither-present missing
run_certificate_case certificate-only certificate-only
run_certificate_case key-only key-only
run_certificate_case empty-certificate empty-certificate
run_certificate_case empty-key empty-key
run_certificate_case valid-pair valid
run_certificate_case mismatched-pair mismatched
run_certificate_case corrupt-certificate corrupt-certificate
run_certificate_case corrupt-key corrupt-key
run_certificate_case wrong-host wrong-host
run_certificate_case cn-only cn-only
run_certificate_case extra-san extra-san
run_certificate_case expired expired
run_certificate_case future future
run_public_port_case
assert_invalid_public_port 0
assert_invalid_public_port 65536
assert_invalid_public_port invalid
test_certificate_monitor

# The standalone site config denies the server-side include directory with a
# prefix location, which wins over the PHP handler whatever the block order.
grep -Fq 'location ^~ /admin/include/ {' "$ROOT_DIR/conf/nginx/conf.d/domain.conf" ||
    fail "standalone site config does not deny /admin/include/"

# phpMyAdmin is installed outside the site root by the standalone installer
# and needs its own location; its PHP sub-location must carry the socket
# placeholder the installer rewrites, like the generic handler.
grep -Fq 'location /phpmyadmin/ {' "$ROOT_DIR/conf/nginx/conf.d/domain.conf" ||
    fail "standalone site config does not serve phpMyAdmin"
[ "$(grep -c 'fastcgi_pass unix:/var/run/php/phpX.X-fpm.sock;' "$ROOT_DIR/conf/nginx/conf.d/domain.conf")" -eq 2 ] ||
    fail "standalone site config must route phpMyAdmin PHP files through the placeholder socket"
grep -Fq 'open_basedir=/usr/share/phpmyadmin/' "$ROOT_DIR/conf/nginx/conf.d/domain.conf" ||
    fail "phpMyAdmin location must carry its own open_basedir (the site value sticks to FPM workers)"

# Let's Encrypt certificates carry no OCSP responder any more, so stapling
# only produces a warning at every reload.
for conf in conf/nginx/nginx.conf docker/nginx/nginx.conf; do
    grep -q 'ssl_stapling' "$ROOT_DIR/$conf" && fail "$conf still enables OCSP stapling"
done

echo "PASS: Nginx hardening"
