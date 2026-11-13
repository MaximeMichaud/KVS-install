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

KVS_INTERNAL_PRE_REGEX='^/(admin/(data|logs|smarty|stamp|template|tools)|tmp)/'
KVS_INTERNAL_PRE_RULE="location ~ ${KVS_INTERNAL_PRE_REGEX} {"
KVS_INTERNAL_POST_REGEX='^/admin/(include(?!/(uploader|get_upload_status)\.php$)|plugins)/'
KVS_INTERNAL_POST_RULE="location ~ ${KVS_INTERNAL_POST_REGEX} {"
# The first asset regex, which the server-only deny must precede.
KVS_ASSET_RULE='location ~* \.(?:css(\.map)?|js(\.map)?|jpe?g|'
# Uploads land under contents/: no PHP may run there, a .phar or a PATH_INFO
# path through one (up.phar/x.php) included.
KVS_CONTENTS_PHP_REGEX='^/contents/.*\.(?:php|phar)(?:/|$)'
KVS_CONTENTS_PHP_RULE="location ~* ${KVS_CONTENTS_PHP_REGEX} {"

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
        "$KVS_INTERNAL_PRE_RULE" \
        "$KVS_INTERNAL_POST_RULE"
    do
        protected_line=$(line_number "$file" "$rule")
        [ "$protected_line" -lt "$php_line" ] ||
            fail "protected rule follows the generic PHP handler in ${file}: ${rule}"
    done
}

# The KVS nginx_config.txt shipped with every release marks admin/data,
# admin/logs, admin/plugins, admin/smarty, admin/stamp, admin/template,
# admin/tools and tmp internal with plain prefix locations that lose to the
# first matching regular expression, so an asset regex would serve a file
# there and the PHP handler would run a script there. Two regular expressions
# deny them. The server-only directories, denied before the asset regexes so
# no extension is served. admin/plugins and admin/include, denied after the
# asset regexes: a plugin's admin page loads its JS and CSS from admin/plugins,
# and admin/include keeps the two upload scripts the admin panel requests.
assert_kvs_internal_directories_denied_before_php() {
    local file="$1"
    local php_line pre_line post_line directory

    php_line=$(line_number "$file" 'location ~ \.php$ {')
    pre_line=$(line_number "$file" "$KVS_INTERNAL_PRE_RULE")
    post_line=$(line_number "$file" "$KVS_INTERNAL_POST_RULE")
    { [ "$pre_line" -lt "$php_line" ] && [ "$post_line" -lt "$php_line" ]; } ||
        fail "a KVS internal directory is denied after the PHP handler in ${file}"
    # The server-only directories, including tmp, are denied and the admin
    # panel and its plugins are not: the deny of assets must leave them out.
    for directory in data logs smarty stamp template tools; do
        printf '/admin/%s/system/leak.js\n' "$directory" |
            grep -Pq "$KVS_INTERNAL_PRE_REGEX" ||
            fail "the server-only deny does not cover /admin/${directory}/ in ${file}"
    done
    printf '/tmp/leak.mp4\n' | grep -Pq "$KVS_INTERNAL_PRE_REGEX" ||
        fail "the server-only deny does not cover /tmp/ in ${file}"
    for path in /admin/index.php /admin/plugins/p/admin.js /admin/plugins/p/admin.php /admin/include/uploader.php; do
        printf '%s\n' "$path" | grep -Pq "$KVS_INTERNAL_PRE_REGEX" &&
            fail "the server-only deny wrongly covers ${path} in ${file}"
    done
    # admin/plugins scripts and the rest of admin/include are denied after the
    # asset regexes; the two upload scripts and the admin panel are not.
    for path in /admin/plugins/p/admin.php /admin/include/setup_db.php /admin/include/cron.php; do
        printf '%s\n' "$path" | grep -Pq "$KVS_INTERNAL_POST_REGEX" ||
            fail "the admin deny leaves ${path} reachable in ${file}"
    done
    for script in uploader get_upload_status; do
        printf '/admin/include/%s.php\n' "$script" |
            grep -Pq "$KVS_INTERNAL_POST_REGEX" &&
            fail "the admin deny blocks the upload script ${script}.php in ${file}"
    done
    printf '/admin/index.php\n' | grep -Pq "$KVS_INTERNAL_POST_REGEX" &&
        fail "the admin deny blocks the admin panel itself in ${file}"
    grep -q 'location ^~ /admin/include/' "$file" &&
        fail "a ^~ prefix location hides the admin uploader scripts from the PHP handler in ${file}"
    return 0
}

# The server-only deny must come before the asset regexes, or an asset there
# is served over it. In the standalone config those regexes live in
# globals/general.conf, included after the deny.
assert_internal_dirs_denied_before_assets() {
    local file="$1"
    local pre_line asset_line

    pre_line=$(line_number "$file" "$KVS_INTERNAL_PRE_RULE")
    if grep -qF "$KVS_ASSET_RULE" "$file"; then
        asset_line=$(line_number "$file" "$KVS_ASSET_RULE")
    else
        asset_line=$(line_number "$file" 'include globals/general.conf;')
    fi
    [ "$pre_line" -lt "$asset_line" ] ||
        fail "the server-only directories are denied after the asset regexes in ${file}"
}

assert_contents_php_denied_before_php() {
    local file="$1"
    local contents_line
    local php_line
    local path

    contents_line=$(line_number "$file" "$KVS_CONTENTS_PHP_RULE")
    php_line=$(line_number "$file" 'location ~ \.php$ {')
    [ "$contents_line" -lt "$php_line" ] ||
        fail "PHP under /contents/ is denied after the PHP handler in ${file}"
    for path in /contents/other/evil.php /contents/other/up.phar /contents/other/up.phar/x.php \
        /contents/videos_sources/1/EVIL.PHP; do
        printf '%s\n' "$path" | grep -Piq "$KVS_CONTENTS_PHP_REGEX" ||
            fail "the contents rule of ${file} leaves ${path} to the PHP handler"
    done
    for path in /contents/videos_screenshots/1/1.jpg /contents/albums/sources/1/photo.php.jpg \
        /contents/other/pharmacy.mp4 /index.php /admin/index.php; do
        printf '%s\n' "$path" | grep -Piq "$KVS_CONTENTS_PHP_REGEX" &&
            fail "the contents rule of ${file} denies ${path}"
    done
    return 0
}

# The body of the first location block opened on the line that holds the
# rule, its whitespace collapsed to single spaces. A protected rule that
# exists and comes before the PHP handler still lets nginx serve the file as
# plain text once its body says "allow all;" or loses "internal;".
location_body() {
    local file="$1"
    local rule="$2"

    RULE="$rule" awk '
        !started {
            start = index($0, ENVIRON["RULE"])
            if (start == 0) next
            started = 1
            $0 = substr($0, start + length(ENVIRON["RULE"]))
        }
        {
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                else if (c == "}" && depth-- == 0) { closed = 1; exit }
                body = body c
            }
            body = body " "
        }
        END {
            if (!closed) exit 1
            gsub(/[ \t]+/, " ", body)
            sub(/^ /, "", body)
            sub(/ $/, "", body)
            print body
        }
    ' "$file"
}

assert_location_body() {
    local file="$1"
    local rule="$2"
    local expected="$3"
    local body

    body=$(location_body "$file" "$rule") ||
        fail "no complete location block for ${rule} in ${file}"
    [ "$body" = "$expected" ] ||
        fail "${rule} in ${file} holds '${body}', expected '${expected}'"
}

assert_location_body_has() {
    local file="$1"
    local rule="$2"
    local directive="$3"
    local body

    body=$(location_body "$file" "$rule") ||
        fail "no complete location block for ${rule} in ${file}"
    case " ${body} " in
        *" ${directive} "*) ;;
        *) fail "${rule} in ${file} lacks ${directive}" ;;
    esac
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
generate_fixture_pair subdomain-only 7.0.2.example.org false
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
        -e "s|/run/kvs-nginx|${case_dir}/run/kvs-nginx|g" \
        -e 's|exec /docker-entrypoint.sh "$@"|exec "$@"|' \
        -e '/^[[:space:]]*monitor_certificate_changes &$/c\    : # Tested separately below.' \
        -e '\|^/usr/local/bin/rotate-site-logs &$|c\: # Tested in test_log_rotation.sh.' \
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
    local domain='7.0.2.example.org'
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
        -e "s|/run/kvs-nginx|${case_dir}/run/kvs-nginx|g" \
        -e 's|exec /docker-entrypoint.sh "$@"|exec "$@"|' \
        -e '/^[[:space:]]*monitor_certificate_changes &$/c\    : # Tested separately below.' \
        -e '\|^/usr/local/bin/rotate-site-logs &$|c\: # Tested in test_log_rotation.sh.' \
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
    # PHP and cron reach https://<domain>:18445 inside the Docker network,
    # where the name leads to this container: the TLS servers listen there
    # as on 443, the catch-all included (integration_internal_site_url.sh).
    [ "$(grep -Ec '^[[:space:]]*listen[[:space:]]+18445 ssl;' "$generated_config")" -eq 1 ] &&
        [ "$(grep -Ec '^[[:space:]]*listen[[:space:]]+18445 ssl default_server;' "$generated_config")" -eq 1 ] &&
        [ "$(grep -Ec '^[[:space:]]*listen[[:space:]]+443 ssl;' "$generated_config")" -eq 1 ] ||
        fail "the TLS servers do not listen on the custom public HTTPS port inside the container"
}

# The site template is bind-mounted from the checkout while the entrypoint
# that renders it is part of the nginx image, and a git pull lands before
# setup.sh rebuilds that image: the entrypoint of the image in place then
# renders the newer template. envsubst leaves a variable it was not given as
# it is, which Nginx refuses as an unknown directive, so the container
# restarts in a loop. The template therefore names only variables the
# entrypoint of 26.11.0 substitutes; anything newer, such as the listeners
# of a custom HTTPS port, the entrypoint adds to the rendered file.
assert_template_renders_with_older_entrypoints() {
    local known=' DOMAIN MAIN_SERVER_NAME PUBLIC_SERVER_NAMES PUBLIC_HOST_RULES REDIRECT_HOST PROJECT_HTTPS_PORT HTTPS_PORT_SUFFIX WWW_REDIRECT_BLOCK KVS_ROOT PHP_FPM_UPSTREAM RESOLVER_LINE '
    local variable

    # shellcheck disable=SC2016 # The template's placeholders, literally.
    while IFS= read -r variable; do
        [[ "$known" == *" ${variable} "* ]] ||
            fail "kvs.conf.tpl names \${${variable}}, which the entrypoint of an older nginx image leaves in place"
    done < <(grep -o '\${[A-Za-z_][A-Za-z0-9_]*}' "${ROOT_DIR}/conf/nginx/templates/kvs.conf.tpl" |
        sed 's/^\${//; s/}$//' | sort -u)
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
        /^certificate_pair_is_valid\(\) \{/ { capture = 1 }
        /^publish_internal_trust\(\) \{/ { capture = 1 }
        capture { print }
        capture && /^\}$/ { capture = 0 }
    ' "$ENTRYPOINT" > "$monitor_function"
    awk '
        /^monitor_certificate_changes\(\) \($/ { capture = 1 }
        capture { print }
        capture && /^\)$/ { exit }
    ' "$ENTRYPOINT" |
        sed "s|/etc/nginx/ssl|${case_dir}/ssl|g" >> "$monitor_function"
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
    PATH="${mock_dir}:${PATH}" DOMAIN="$domain" SSL_DIR="$ssl_dir" \
        INCLUDE_WWW=false SSL_PROVIDER=letsencrypt CERTIFICATE_RELOAD_INTERVAL=1 \
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
# The standalone site config includes the same KVS nginx_config.txt (the
# installer copies it to globals/kvs.conf), so it needs the same guard.
for site_config in \
    conf/nginx/templates/kvs.conf.tpl \
    docker/multi-site/nginx/kvs-caddy.conf.template \
    conf/nginx/conf.d/domain.conf
do
    assert_kvs_internal_directories_denied_before_php "${ROOT_DIR}/${site_config}"
    assert_internal_dirs_denied_before_assets "${ROOT_DIR}/${site_config}"
    assert_location_body "${ROOT_DIR}/${site_config}" "$KVS_INTERNAL_PRE_RULE" 'deny all;'
    assert_location_body "${ROOT_DIR}/${site_config}" "$KVS_INTERNAL_POST_RULE" 'deny all;'
    assert_location_body_has "${ROOT_DIR}/${site_config}" 'location ^~ /contents/videos/ {' 'internal;'
    assert_contents_php_denied_before_php "${ROOT_DIR}/${site_config}"
    assert_location_body "${ROOT_DIR}/${site_config}" "$KVS_CONTENTS_PHP_RULE" 'deny all;'
done
for site_config in \
    conf/nginx/templates/kvs.conf.tpl \
    docker/multi-site/nginx/kvs-caddy.conf.template
do
    assert_location_body "${ROOT_DIR}/${site_config}" 'location ~ /\. {' 'deny all;'
    # PHP-FPM gets only a script that exists, never one it would find by
    # cutting a PATH_INFO path short.
    # shellcheck disable=SC2016  # An nginx variable, not a shell one.
    assert_location_body_has "${ROOT_DIR}/${site_config}" 'location ~ \.php$ {' \
        'try_files $fastcgi_script_name =404;'
    for directory in blocks langs template tmp; do
        assert_location_body "${ROOT_DIR}/${site_config}" "location ~* /${directory}/.*\.php\$ {" 'internal;'
    done
done
# The standalone site config takes its dotfile and KVS internal locations,
# and the existing-script check of its PHP handler, from the globals it
# includes.
assert_location_body_has "${ROOT_DIR}/conf/nginx/conf.d/domain.conf" 'location ~ \.php$ {' \
    'include globals/php_fastcgi.conf;'
# shellcheck disable=SC2016  # An nginx variable, not a shell one.
grep -Eq '^try_files +\$fastcgi_script_name =404;$' "${ROOT_DIR}/conf/nginx/globals/php_fastcgi.conf" ||
    fail "the PHP handler of the standalone site config runs scripts that do not exist"
assert_location_body "${ROOT_DIR}/conf/nginx/globals/security.conf" \
    'location ~ /\.(?!well-known(?:/|$)) {' 'deny all;'
for directory in blocks langs template tmp; do
    assert_location_body "${ROOT_DIR}/conf/nginx/globals/kvs.conf" "location ~* /${directory}/.*\.php\$ {" 'internal;'
done

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
assert_template_renders_with_older_entrypoints
assert_invalid_public_port 0
assert_invalid_public_port 65536
assert_invalid_public_port invalid
test_certificate_monitor


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
