#!/bin/bash
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
export RED='' NC=''
fail() { echo "FAIL: $*" >&2; exit 1; }

# Run the setup block that saves the canonical port and the URL shown on exit.
# shellcheck source=/dev/null
source "$root/docker/lib/host-validation.sh"
setup_port() (
    export GREEN='' CYAN='' YELLOW=''
    export HEADLESS=${HEADLESS-y} DOMAIN=site.test USE_WWW=false EMAIL=${EMAIL-ops@site.test}
    # shellcheck source=/dev/null
    source <(sed -n '/^parse_publish_endpoint() {/,/^}/p; /^publish_address_key() {/,/^}/p; /^resolve_public_port_configuration() {/,/^}/p;
        /^function validate_port_override() {/,/^}/p; /^prompt_read() {/,/^}/p;
        /^remove_env_value() {/,/^}/p; /^set_env_value() {/,/^}/p' "$root/docker/setup.sh")
    # shellcheck source=/dev/null
    source <(sed -n '/^select_project_https_port() {/,/^}/p; /^ask_existing_volume() {/,/^}/p;
        /^delete_database_volume() {/,/^}/p; /^nginx_has_public_certificate() {/,/^}/p' "$root/docker/setup.sh")
    if [ "${STOP_AFTER_FIRST_WRITE:-no}" = yes ] || [ "${FAIL_PORT_WRITE:-no}" = yes ]; then
        # Interrupt the fixture just after the atomic replacement of .env.
        # shellcheck disable=SC2329  # Called by the sourced .env writer.
        mv() {
            if [ "${FAIL_PORT_WRITE:-no}" = yes ] && [ "${*: -1}" = .env ]; then return 1; fi
            command mv "$@" || exit 1
            [ "${*: -1}" != .env ] || exit 17
        }
    fi
    # Exercise the actual option parser and developer defaults when passed --dev.
    # shellcheck source=/dev/null
    # shellcheck disable=SC2016
    source <(sed -n '/^DEV_MODE=false$/,/^done$/p; /^if \[ "\$DEV_MODE" = true \]; then/,/^fi$/p' "$root/docker/setup.sh") "$@"
    # Capture and apply overrides around loading the saved environment, as setup does.
    # shellcheck source=/dev/null
    # shellcheck disable=SC2016
    source <(sed -n '/^declare -A KVS_PORT_OVERRIDES=/,/^done$/p;
        /^unset SITE_PREFIX_LEGACY SITE_PREFIX_RESELECT/,/^check_mariadb_stop_grace_period/{ /^check_mariadb_stop_grace_period/!p; };
        /^# Persist explicit port overrides/,/^if \[ -n "\$KVS_DOMAIN_OVERRIDE"/{ /^if \[ -n "\$KVS_DOMAIN_OVERRIDE"/!p; }' "$root/docker/setup.sh")
    [ "${STOP_AFTER_OVERRIDES:-no}" != yes ] || exit 0
    # shellcheck disable=SC2034  # Read by the sourced setup steps.
    if [ "${MODE:?missing fixture mode}" = single ]; then MODE_CHOICE=${MODE_CHOICE-1}; else MODE_CHOICE=${MODE_CHOICE-}; fi
    # shellcheck disable=SC2034
    MARIADB_VERSION=11.8 SETUP_SCRIPT_DIR=$root/docker VOLUME_CHOICE=1
    # shellcheck disable=SC2034
    SETUP_RUN_FLAGS=()
    # shellcheck disable=SC2329  # Invoked by the setup steps below.
    configure_direct_tls_profile() { :; }
    # shellcheck disable=SC2329
    setup_drop_acme_installed_pair() { :; }
    # shellcheck disable=SC2329
    check_configured_ports() { [ "${REFUSE_STEP:-}" != ports ]; }
    # shellcheck disable=SC2329
    database_configure_resources() { [ "${REFUSE_STEP:-}" != database ]; }
    # shellcheck disable=SC2329
    resolve_support_access_setting() { [ "${REFUSE_STEP:-}" != support ]; }
    # shellcheck disable=SC2329
    require_compose_config() { [ "${REFUSE_STEP:-}" != compose ]; }
    # shellcheck disable=SC2329
    check_dns() { [ "${REFUSE_STEP:-}" != dns ]; }
    # shellcheck disable=SC2329
    include_www_for_domain() { return 1; }
    # shellcheck disable=SC2034
    DNS_RETRY_ATTEMPTS=0 DNS_RETRY_DELAY=0 DNS_CHOICE=3 SERVER_IP=192.0.2.1
    # shellcheck disable=SC2329
    import_require_empty_volume() { :; }
    # shellcheck disable=SC2329
    import_stage_dump() { [ "${REFUSE_STEP:-}" != dump ] || exit 1; }
    # shellcheck disable=SC2329
    require_multi_compose_version() { return 0; }
    # shellcheck disable=SC2329
    port_conflicts_to_resolve() { return 1; }
    # shellcheck source=/dev/null
    source <(sed -n '/^stop_for_configured_ports() {/,/^}/p' "$root/docker/setup.sh")
    # The Caddy email check needs the real route manager: only the cases
    # that install it run the check.
    # shellcheck disable=SC2329
    check_setup_caddy_contacts() { :; }
    if [ "${CADDY_EMAIL_CHECK:-no}" = yes ]; then
        # shellcheck source=/dev/null
        source <(sed -n '/^check_setup_caddy_contacts() {/,/^}/p' "$root/docker/setup.sh")
    fi
    # shellcheck disable=SC2329
    run_step() { shift; "$@"; }
    # shellcheck disable=SC2329
    docker() {
        case "$*" in
            ps\ --filter*) return 0 ;;
            'compose config') printf '  mariadb-data:\n    name: disposable\n' ;;
            'volume ls -q') [ ! -e volume ] || echo disposable ;;
            'run --rm -v disposable:/data:ro '*) echo 11.8.1 ;;
            'compose down --timeout 10') touch stopped ;;
            'volume inspect disposable') [ -e volume ] ;;
            'volume rm disposable') rm volume ;;
            'compose run --rm --no-deps -T --entrypoint sh -e KVS_CERT_PROVIDER=public nginx -c '*)
                touch probe
                case ${PUBLIC_CERT:-no} in
                    yes) return 0 ;;
                    no)
                        local script=${!#} result=0
                        script=${script//\/etc\/ssl\/certs\/ca-certificates.crt/$PWD/ca.pem}
                        KVS_CERT_PROVIDER=public sh -c "${script//\/etc\/nginx\/ssl/$PWD/empty-volume}" || result=$?
                        echo "$result" > probe-status
                        return "$result" ;;
                    *) return 125 ;;
                esac ;;
            'compose --profile setup run --rm --no-deps kvs-init'|'compose up -d --force-recreate nginx')
                bash -c 'printf "%s %s\n" "${SSL_PROVIDER:-}" "$PROJECT_HTTPS_PORT"' >> services ;;
            *) return 64 ;;
        esac
    }
    # shellcheck source=/dev/null
    source <(sed -n '/^select_mode() {/,/^}/p; /^configure_mode() {/,/^}/p; /^set_compose_file() {/,/^}/p;
        /^validate_email() {/,/^}/p; /^compose_files_for() {/,/^}/p; /^check_cloudflare_configuration() {/,/^}/p;
        /^replace_setup_database_volume() {/,/^}/p' "$root/docker/setup.sh")
    # shellcheck disable=SC2034
    IMPORT_MODE=false SITE_PREFIX=kvs-site
    # Preserve the script order from mode selection through volume deletion,
    # certificate detection and the actual init and Nginx service commands.
    # shellcheck source=/dev/null
    # shellcheck disable=SC2016
    source <(sed -n '/^# Read the requested mode/,/^select_cache$/{ /^select_cache$/!p; };
        /^SETUP_VOLUME_TO_DELETE=""$/,/^fi$/p;
        /^resolve_support_access_setting || exit 1$/p; /^database_configure_resources || exit 1$/p;
        /^if \[ "${DEV_SSL_INTELLIGENT:-false}" = true \]; then/,/^fi$/p;
        /^require_compose_config || exit 1$/p; /^dns_retries_left=\$DNS_RETRY_ATTEMPTS/,/^done$/p; /^import_stage_dump$/p;
        /^check_configured_ports || exit 1$/p; /^MODE=\$PREVIOUS_MODE$/p; /^configure_mode || exit /p;
        /^check_setup_caddy_contacts || exit 1$/p;
        /^stop_for_configured_ports || exit 1$/p; /^replace_setup_database_volume || exit 1$/p;
        /^run_step "Initializing KVS"/,+1p; /^    run_step "Starting Nginx" docker compose up -d --force-recreate nginx$/p;
        /^PUBLIC_HTTPS_PORT_SUFFIX=""/,/^echo -e.*Website:/{ /^echo -e.*Website:/!p; }' "$root/docker/setup.sh")
    printf 'url=%s\nbound=%s\n' "$PUBLIC_PROJECT_URL" "$PUBLIC_HTTPS_PORT"
)

reconfigure_port() (
    # shellcheck source=/dev/null
    source <(sed -n '/^unset CLOUDFLARE_ENABLED COMPOSE_PROFILES/,/^source .env$/p' "$root/docker/reconfigure.sh")
    # shellcheck source=/dev/null
    source <(sed -n '/^parse_publish_endpoint_port() {/,/^}/p; /^resolve_project_https_port() {/,/^}/p' "$root/docker/reconfigure.sh")
    resolve_project_https_port || exit 1
    # shellcheck source=/dev/null
    # shellcheck disable=SC2016
    source <(sed -n '/^set_env_value() {/,/^}/p; /^set_env_value PROJECT_HTTPS_PORT/p' "$root/docker/reconfigure.sh")
    # shellcheck disable=SC2034
    USE_WWW=false DOMAIN=site.test
    # shellcheck source=/dev/null
    source <(sed -n '/^HTTPS_PORT_SUFFIX=""/,/^# Replace only/{ /^# Replace only/!p; }' "$root/docker/reconfigure.sh")
    echo "url=$SERVER_URL"
    echo "project=$PROJECT_HTTPS_PORT"
)

check_port() {
    local mode=$1 ssl=$2 endpoint=$3 saved=$4 want=$5 bound=$6 suffix=""
    printf 'MODE=%s\nSSL_PROVIDER=%s\nHTTPS_PORT=%s\n' "$mode" "$ssl" "$endpoint" > .env
    [ "$saved" = missing ] || echo "PROJECT_HTTPS_PORT=$saved" >> .env
    reconfigure_port > out || fail "reconfigure: $*"
    grep -Fxq "project=$want" out || fail "reconfigure port: $*"
    setup_port > out || fail "setup: $*"
    [ "$want" = 443 ] || suffix=":$want"
    grep -Fxq "url=https://site.test$suffix" out || fail "printed URL: $*"
    grep -Fxq "bound=$bound" out || fail "published port: $*"
    grep -Fxq "PROJECT_HTTPS_PORT=$want" .env || fail "saved port: $*"
}

check_port single selfsigned 8443 443 443 8443
check_port single selfsigned '[2001:db8::1]:8443' 09443 9443 8443
check_port single selfsigned 8443 missing 8443 8443
check_port single selfsigned 8443 '' 8443 8443
check_port single letsencrypt 8443 443 8443 8443
check_port multi selfsigned 8443 9443 443 443

for mode in single multi; do
    printf '%s\n' "MODE=$mode" SSL_PROVIDER=letsencrypt HTTPS_PORT=8443 PROJECT_HTTPS_PORT=443 PROJECT_HTTPS_PORT_PINNED=true > .env
    reconfigure_port > out || fail "public reconfiguration failed"
    grep -Fxq PROJECT_HTTPS_PORT_PINNED=false .env || fail "a computed port kept its former proxy pin"
done

# A fresh template follows the configured binding without a saved proxy port.
grep -E '^(SSL_PROVIDER|MODE|PROJECT_HTTPS_PORT|HTTPS_PORT)=' "$root/docker/.env.example" |
    sed -e 's/^SSL_PROVIDER=.*/SSL_PROVIDER=selfsigned/' -e 's/^HTTPS_PORT=.*/HTTPS_PORT=8443/' > .env
setup_port > out || fail "fresh template refused"
grep -Fxq 'PROJECT_HTTPS_PORT=8443' .env || fail "fresh template pinned the URL to another port"

# A changed binding moves a previously matching canonical port. A proxy port
# stays independent, including when both overrides are supplied together.
write_saved() {
    printf 'MODE=single\nSSL_PROVIDER=selfsigned\nHTTPS_PORT=8443\nPROJECT_HTTPS_PORT=%s\n' "$1" > .env
}
write_saved 08443
HTTPS_PORT=9443 setup_port > out || fail "changed bind port refused"
grep -Fxq 'PROJECT_HTTPS_PORT=9443' .env || fail "canonical port did not follow the changed binding"
write_saved 8443
HEADLESS='' HTTPS_PORT='[2001:db8::1]:8443' setup_port < /dev/null > out ||
    fail "changing only the bind address discarded the saved port"
write_saved 443
sed -i '/^HTTPS_PORT=/d' .env
HTTPS_PORT=9443 setup_port > out || fail "changing the default binding failed"
grep -Fxq 'PROJECT_HTTPS_PORT=9443' .env || fail "moving the default binding did not update the URL"
write_saved 8443
STOP_AFTER_OVERRIDES=yes HTTPS_PORT=9443 setup_port > out || fail "interrupted setup fixture failed"
grep -Fxq 'HTTPS_PORT=9443' .env || fail "fixture stopped before saving the new binding"
setup_port > out || fail "rerun after a binding change failed"
grep -Fxq 'PROJECT_HTTPS_PORT=9443' .env || fail "rerun after an interruption kept the previous binding"
write_saved 443
HTTPS_PORT=9443 setup_port > out || fail "changed proxy binding refused"
grep -Fxq 'PROJECT_HTTPS_PORT=443' .env || fail "moving the binding changed the proxy port"
write_saved 8443
status=0
STOP_AFTER_FIRST_WRITE=yes HTTPS_PORT=9443 PROJECT_HTTPS_PORT=10443 setup_port > out || status=$?
[ "$status" = 17 ] || fail "fixture did not stop after the first write"
setup_port > out || fail "resume after paired overrides failed"
grep -Fxq 'PROJECT_HTTPS_PORT=10443' .env || fail "interruption lost the proxy port"
grep -Fxq 'bound=9443' out || fail "interruption lost the binding"
write_saved 8443
cp .env before
if FAIL_PORT_WRITE=yes HTTPS_PORT=9443 PROJECT_HTTPS_PORT=10443 setup_port > out; then fail "failed rename accepted"; fi
cmp before .env || fail "failed rename changed the old port pair"
write_saved 443
HTTPS_PORT=9443 PROJECT_HTTPS_PORT=8443 setup_port > out || fail "explicit port overrides refused"
grep -Fxq 'PROJECT_HTTPS_PORT=8443' .env || fail "explicit proxy port did not win"

write_saved ''
PROJECT_HTTPS_PORT=08443 setup_port > out || fail "explicit pin refused"
HTTPS_PORT=9443 setup_port > out || fail "could not move binding"
grep -Fxq 'PROJECT_HTTPS_PORT=8443' .env || fail "explicit pin followed its former binding"
write_saved ''
HEADLESS='' setup_port <<< 8443 > out || fail "interactive pin refused"
HTTPS_PORT=9443 setup_port > out || fail "could not move binding after prompt"
grep -Fxq 'PROJECT_HTTPS_PORT=8443' .env || fail "interactive pin followed its former binding"

for saved in '' 65536 443; do
    write_saved "$saved"
    touch volume
    rm -f stopped
    status=0
    HEADLESS='' setup_port </dev/null > out 2>&1 || status=$?
    if [ "$saved" = 443 ]; then
        { [ "$status" = 0 ] && [ -e stopped ] && [ ! -e volume ]; } || fail "valid port did not reach volume deletion"
    else
        { [ "$status" = 1 ] && [ ! -e stopped ] && [ -e volume ]; } || fail "volume touched before port validation"
        if [ -z "$saved" ]; then
            grep -Fq 'no answer left' out || fail "missing EOF diagnostic"
        else
            grep -Fq 'PROJECT_HTTPS_PORT must be a number' out || fail "missing invalid port diagnostic"
        fi
    fi
done

# Exercise the route manager used when returning from a multi-site install.
mkdir -p multi-site
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> routes\n' > multi-site/site-manager.sh
chmod +x multi-site/site-manager.sh
# Refuse overlapping TCP sockets before retiring a route. Different
# addresses in the same family may publish the same port.
for headless in y ''; do
    for pair in '18443 18443' '18443 [::1]:18443' '0.0.0.0:18443 192.0.2.1:18443' \
        '[::]:18443 [2001:db8::1]:18443' '[::ffff:192.0.2.1]:18443 192.0.2.1:18443' \
        '[2001:DB8::a]:18443 [2001:0db8:0:0:0:0:0:a]:18443'; do
        read -r http https <<< "$pair"
        printf '%s\n' MODE=multi SSL_PROVIDER=selfsigned "HTTP_PORT=$http" "HTTPS_PORT=$https" PROJECT_HTTPS_PORT=443 > .env
        rm -f stopped routes
        touch volume
        if HEADLESS=$headless MODE_CHOICE=1 setup_port </dev/null > out 2>&1; then fail "accepted overlapping $pair"; fi
        { [ -e volume ] && [ ! -e stopped ] && [ ! -e routes ] &&
            grep -Fq "HTTP_PORT=$http and HTTPS_PORT=$https overlap" out; } || fail "late or unexplained refusal of $pair"
    done
done
for pair in '192.0.2.1:18443 192.0.2.2:18443' '[2001:db8::1]:18443 [2001:db8::2]:18443' \
    '0.0.0.0:18443 [::]:18443'; do
    read -r http https <<< "$pair"
    printf '%s\n' MODE=single SSL_PROVIDER=selfsigned "HTTP_PORT=$http" "HTTPS_PORT=$https" > .env
    setup_port > out || fail "refused distinct sockets $pair"
done
for mode in single multi; do
    for headless in '' y; do
        printf '%s\n' "MODE=$mode" SSL_PROVIDER=letsencrypt HTTP_PORT=8080 HTTPS_PORT=8443 PROJECT_HTTPS_PORT=443 > .env
        rm -f stopped routes
        touch volume
        status=0
        # An interactive operator selects single site; headless uses the same choice.
        if [ "$mode" = single ] && [ -z "$headless" ]; then
            HEADLESS='' MODE_CHOICE='' setup_port <<< 1 > out 2>&1 || status=$?
        else
            HEADLESS=$headless MODE_CHOICE=1 setup_port </dev/null > out 2>&1 || status=$?
        fi
        { [ "$status" = 1 ] && grep -Fq 'requires host TCP port 80' out; } || fail "ACME refusal ($mode/$headless): $(cat out)"
        [ -e volume ] && [ ! -e stopped ] && [ ! -e routes ] || fail "ACME refusal touched the site"
    done
done
# Run the inner volume probe with a locally trusted leaf certificate.
mkdir -p empty-volume/site.test bin
cert_dir=empty-volume/site.test
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=TestCA \
    -addext basicConstraints=critical,CA:TRUE -keyout ca.key -out ca.pem 2>/dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=site.test \
    -keyout "$cert_dir/key.pem" -out site.csr 2>/dev/null
printf '%s\n' 'subjectAltName=DNS:site.test,DNS:www.site.test' 'extendedKeyUsage=serverAuth' > extensions
openssl x509 -req -in site.csr -CA ca.pem -CAkey ca.key -CAcreateserial -extfile extensions \
    -days 1 -out "$cert_dir/cert.pem" 2>/dev/null
export REAL_OPENSSL
REAL_OPENSSL=$(command -v openssl)
cat > bin/openssl <<'SH'
#!/bin/sh
if [ "$1" = "$FAIL_TOOL" ]; then exit 42; fi
if [ "$1" = verify ] && [ "$FAIL_TOOL" = verify-error ]; then exit 2; fi
exec "$REAL_OPENSSL" "$@"
SH
# shellcheck disable=SC2016  # FAIL_TOOL is read inside the date fixture.
printf '#!/bin/sh\n[ "$FAIL_TOOL" != date ] || exit 127\nexec "%s" "$@"\n' "$(command -v date)" > bin/date
chmod +x bin/openssl bin/date
for failure in none date x509 pkey verify verify-error cert.pem key.pem ca.pem email dev-email; do
    printf '%s\n' MODE=multi SSL_PROVIDER=letsencrypt HTTP_PORT=8080 HTTPS_PORT=8443 PROJECT_HTTPS_PORT=443 > .env
    rm -f stopped routes
    touch volume
    email=ops@site.test
    case $failure in
        cert.pem|key.pem) mv "$cert_dir/$failure" missing ;;
        ca.pem) mv ca.pem missing ;;
        email) email=admin@example.com ;;
        dev-email) email=dev@localhost.local ;;
    esac
    status=0
    EMAIL=$email PATH="$PWD/bin:$PATH" FAIL_TOOL=$failure MODE_CHOICE=1 PUBLIC_CERT=no setup_port --dev > out 2>&1 || status=$?
    { [ "$status" = 1 ] && [ -e volume ] && [ ! -e stopped ] && [ ! -e routes ]; } ||
        fail "certificate check ($failure) touched the site: $(cat out)"
    case $failure in
        none) expected='requires host TCP port 80' ;;
        email|dev-email) expected='A valid EMAIL is required' ;;
        cert.pem|key.pem) expected=$failure; mv missing "$cert_dir/$failure" ;;
        ca.pem) expected=ca.pem; mv missing ca.pem ;;
        date) expected='date notBefore' ;;
        verify-error) expected='openssl verify' ;;
        *) expected="openssl $failure" ;;
    esac
    grep -Fq "$expected" out || fail "certificate check ($failure) did not name $expected: $(cat out)"
done
# An empty mount or empty domain directory is a fresh install. The probe
# distinguishes that state from an examined rejection and from a failed read.
mv "$cert_dir" saved-pair
rm -f volume
for mode in single multi; do
    choice=1
    if [ "$mode" = multi ]; then choice=2; mkdir "$cert_dir"; fi
    printf '%s\n' "MODE=$mode" SSL_PROVIDER=letsencrypt > .env
    MODE_CHOICE=$choice PUBLIC_CERT=no setup_port --dev > out || fail "fresh $mode: $(cat out)"
    { [ "$(cat probe-status)" = 43 ] && grep -Fxq SSL_PROVIDER=selfsigned .env &&
        grep -Fxq "MODE=$mode" .env; } || fail "fresh $mode did not select self-signed TLS"
done
rmdir "$cert_dir"
for invalid in volume domain cert.pem key.pem; do
    case $invalid in
        volume) mv empty-volume absent-volume ;;
        domain) ln -s absent-directory "$cert_dir" ;;
        *.pem) mkdir "$cert_dir"; ln -s absent-file "$cert_dir/$invalid" ;;
    esac
    printf '%s\n' MODE=single SSL_PROVIDER=selfsigned > .env
    if PUBLIC_CERT=no setup_port --dev > out 2>&1; then fail "accepted inaccessible $invalid"; fi
    [ "$(cat probe-status)" = 1 ] || fail "inaccessible $invalid treated as an empty volume"
    case $invalid in
        volume) mv absent-volume empty-volume ;;
        domain) rm "$cert_dir" ;;
        *.pem) rm "$cert_dir/$invalid"; rmdir "$cert_dir" ;;
    esac
done
mv saved-pair "$cert_dir"
for initial_email in '' admin@example.com primary@site.test; do
    printf '%s\n' MODE=multi SSL_PROVIDER=selfsigned "EMAIL=$initial_email" > .env
    KVS_EMAIL=ops@site.test MODE_CHOICE=2 PUBLIC_CERT=no setup_port --dev > out ||
        fail "refused the contact for a retained public certificate: $(cat out)"
    want=ops@site.test
    [ "$initial_email" != primary@site.test ] || want=$initial_email
    { grep -Fxq "EMAIL=$want" .env && grep -Fxq SSL_PROVIDER=letsencrypt .env; } ||
        fail "wrong ACME contact or provider for the retained certificate"
done
for rejection in untrusted name-constraint missing-www extra-san; do
    case $rejection in
        untrusted)
            mv ca.pem trusted.pem
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
                -subj /CN=OtherCA -keyout other.key -out ca.pem 2>/dev/null ;;
        name-constraint)
            openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=Intermediate \
                -keyout intermediate.key -out intermediate.csr 2>/dev/null
            printf '%s\n' 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,keyCertSign,cRLSign' \
                'nameConstraints=critical,permitted;DNS:.example.test' > intermediate.ext
            openssl x509 -req -in intermediate.csr -CA ca.pem -CAkey ca.key -extfile intermediate.ext \
                -days 1 -out intermediate.pem 2>/dev/null
            openssl x509 -req -in site.csr -CA intermediate.pem -CAkey intermediate.key -extfile extensions \
                -days 1 -out "$cert_dir/cert.pem" 2>/dev/null
            cat intermediate.pem >> "$cert_dir/cert.pem" ;;
        missing-www|extra-san)
            names=DNS:site.test
            if [ "$rejection" = extra-san ]; then names+=,DNS:www.site.test,DNS:other.test; fi
            echo "subjectAltName=$names" > extensions
            openssl x509 -req -in site.csr -CA ca.pem -CAkey ca.key -extfile extensions \
                -days 1 -out "$cert_dir/cert.pem" 2>/dev/null ;;
    esac
    printf '%s\n' MODE=multi SSL_PROVIDER=letsencrypt HTTP_PORT=8080 HTTPS_PORT=8443 > .env
    touch volume
    MODE_CHOICE=1 PUBLIC_CERT=no setup_port --dev > out || fail "certificate rejection ($rejection): $(cat out)"
    { [ ! -e volume ] && grep -Fxq SSL_PROVIDER=selfsigned .env; } || fail "accepted $rejection certificate"
    [ "$(cat probe-status)" = 42 ] || fail "$rejection was not an examined rejection"
    if [ "$rejection" = untrusted ]; then mv trusted.pem ca.pem; fi
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=site.test \
    -addext 'subjectAltName=DNS:site.test,DNS:www.site.test' -keyout "$cert_dir/key.pem" -out "$cert_dir/cert.pem" 2>/dev/null
for cert in yes no error; do
    printf '%s\n' MODE=multi SSL_PROVIDER=letsencrypt HTTP_PORT=8080 HTTPS_PORT=8443 PROJECT_HTTPS_PORT=443 > .env
    rm -f stopped routes probe
    touch volume
    status=0
    MODE_CHOICE=1 PUBLIC_CERT=$cert setup_port --dev > out 2>&1 || status=$?
    [ -e probe ] || fail "developer setup refused the initial provider before detection"
    if [ "$cert" = no ]; then
        { [ "$status" = 0 ] && [ ! -e volume ] && [ -e stopped ] && grep -Fxq 'primary-remove site.test kvs-site' routes; } ||
            fail "a self-signed developer install must accept HTTP_PORT=8080: $(cat out)"
        grep -Fxq SSL_PROVIDER=selfsigned .env || fail "wrong effective provider"
    else
        { [ "$status" = 1 ] && [ -e volume ] && [ ! -e stopped ] && [ ! -e routes ]; } || fail "developer refusal touched the site"
        if [ "$cert" = yes ]; then grep -Fq 'requires host TCP port 80' out || fail "wrong ACME refusal"; fi
        if [ "$cert" = error ]; then grep -Fq 'Could not inspect' out || fail "probe failure treated as a certificate decision"; fi
    fi
done
for step in support database dns compose dump ports; do
    printf '%s\n' MODE=multi SSL_PROVIDER=selfsigned HTTP_PORT=8080 HTTPS_PORT=8443 > .env
    rm -f stopped routes
    touch volume
    status=0
    MODE_CHOICE=1 REFUSE_STEP=$step setup_port > out 2>&1 || status=$?
    { [ "$status" = 1 ] && [ -e volume ] && [ ! -e stopped ] && [ ! -e routes ]; } || fail "$step refused after retirement"
done
rm -f volume
for entry in setup_port reconfigure_port; do
    write_saved 8443
    echo PROJECT_HTTPS_PORT_PINNED=false >> .env
    sed -i 's/^HTTPS_PORT=8443/HTTPS_PORT=9443/' .env
    "$entry" > out || fail "$entry refused a computed port after editing the binding"
    { grep -Fxq 'PROJECT_HTTPS_PORT=9443' .env && grep -Fxq PROJECT_HTTPS_PORT_PINNED=false .env; } || fail "$entry pinned a stale port"
    grep -Fxq 'url=https://site.test:9443' out || fail "$entry built a stale URL"
    for legacy in 08443 10443; do
        write_saved "$legacy"
        echo PROJECT_HTTPS_PORT_PINNED= >> .env
        "$entry" > out || fail "$entry rejected a legacy empty flag"
        want=false
        [ "$legacy" = 08443 ] || want=true
        grep -Fxq "PROJECT_HTTPS_PORT_PINNED=$want" .env || fail "$entry misread an empty legacy flag"
    done
done
write_saved 8443
echo PROJECT_HTTPS_PORT_PINNED=false >> .env
sed -i 's/^HTTPS_PORT=8443/HTTPS_PORT=9443/' .env
HTTPS_PORT=10443 setup_port > out || fail "exported binding with a stale computed port"
{ grep -Fxq PROJECT_HTTPS_PORT=10443 .env && grep -Fxq PROJECT_HTTPS_PORT_PINNED=false .env; } || fail "a stale computed port overrode the exported binding"

for cert in yes no; do
    printf '%s\n' MODE=single SSL_PROVIDER=letsencrypt HTTPS_PORT=8443 PROJECT_HTTPS_PORT= > .env
    rm -f probe services
    PROJECT_HTTPS_PORT=443 PUBLIC_CERT=$cert setup_port --dev > out || fail "developer setup failed"
    want='selfsigned 443'
    [ "$cert" != yes ] || want='letsencrypt 8443'
    [ -e probe ] || fail "developer setup did not check the certificate volume"
    [ "$(cat services)" = "$(printf '%s\n%s' "$want" "$want")" ] || fail "services started with the wrong provider or port"
    reconfigure_port > out || fail "developer settings were not persisted"
    grep -Fxq "project=${want##* }" out || fail "wrong saved developer port"
done

for entry in setup_port reconfigure_port; do
    write_saved 443
    echo PROJECT_HTTPS_PORT_PINNED=invalid >> .env
    cp .env before
    if "$entry" > out 2>&1; then fail "$entry accepted an unknown pin marker"; fi
    { cmp before .env && grep -Fq 'must be empty, true or false' out; } || fail "$entry misread a malformed pin"
done

for invalid in '192.0.2.1:443' 0 65536; do
    printf 'MODE=single\nSSL_PROVIDER=selfsigned\nHTTPS_PORT=8443\nPROJECT_HTTPS_PORT=%s\n' "$invalid" > .env
    if setup_port > out 2>&1; then fail "setup accepted invalid canonical port $invalid"; fi
    if reconfigure_port > out 2>&1; then fail "reconfigure accepted invalid canonical port $invalid"; fi
    grep -Fxq "PROJECT_HTTPS_PORT=$invalid" .env || fail "refusal overwrote the port"
done
printf '%s\n' MODE=single SSL_PROVIDER=selfsigned HTTPS_PORT=8443 > .env
cp .env before
PROJECT_HTTPS_PORT=9555 reconfigure_port > out || fail "missing port refused"
grep -Fxq 'project=8443' out || fail "an inherited shell value replaced the missing saved port"
cp before .env
if HEADLESS='' setup_port < /dev/null > out 2>&1; then fail "missing interactive answer was accepted"; fi
cmp .env before || fail "EOF overwrote the port"
HEADLESS='' setup_port <<< 443 > out || fail "interactive proxy port was rejected"
grep -Fxq 'PROJECT_HTTPS_PORT=443' .env || fail "interactive proxy port was lost"

# A self-signed multi-site primary needs no EMAIL, but a saved route of
# another site may need a certificate from Let's Encrypt: Caddy is then
# refused before shutdown, including when the run keeps the database volume.
rm -rf multi-site
mkdir -p multi-site/caddy/sites
cp "$root/docker/multi-site/site-manager.sh" multi-site/
printf 'primary.example {\n    tls internal\n}\n' > multi-site/caddy/sites/primary.caddy
mkdir -p "./lib"
cp "$root/docker/lib/host-validation.sh" "./lib/"
# caddy_case <refused|deleted|kept> <EMAIL> <route body> [volume: yes|no]
caddy_case() {
    local want=$1 email=$2 route=$3 volume=${4:-yes} status=0
    printf 'other.test {\n%s    reverse_proxy web:80\n}\n' "$route" > multi-site/caddy/sites/other.caddy
    printf '%s\n' MODE=multi SSL_PROVIDER=selfsigned "EMAIL=$email" > .env
    rm -f stopped volume
    [ "$volume" = no ] || touch volume
    DOCKER_HOST=unix:///nonexistent.sock CADDY_EMAIL_CHECK=yes EMAIL=$email setup_port > out 2>&1 || status=$?
    case $want in
        refused)
            [ "$status" = 1 ] || fail "an unusable Caddy email (EMAIL=$email) did not stop the run: $(cat out)"
            [[ ! -e stopped && ( $volume == no || -e volume ) ]] ||
                fail "the run stopped the project or deleted the volume before refusing the Caddy email"
            if [[ $volume == yes ]]; then
                grep -Fq 'stopped before deleting the database volume disposable, which was kept' out || fail 'missing volume name'
            else
                grep -Fq 'Setup stopped before changing the running stack' out || fail 'missing pre-shutdown diagnostic'
                if grep -Fq 'database volume' out; then fail 'claimed a volume was selected'; fi
            fi
            { grep -Fq 'No ACME email for Caddy' out &&
                grep -Fq "Set EMAIL to a valid address in $PWD/.env" out; } ||
                fail "the Caddy email refusal does not say what to do: $(cat out)"
            ! grep -Fq 'caddy-start' out ||
                fail "the refusal also tells the operator to start Caddy by hand: $(cat out)" ;;
        deleted)
            [ "$status" = 0 ] || fail "a usable Caddy configuration (EMAIL=$email) was refused: $(cat out)"
            [ ! -e volume ] && [ -e stopped ] || fail "the approved volume replacement did not run" ;;
        kept)
            [ "$status" = 0 ] || fail "a run that deletes no volume was refused for the Caddy email: $(cat out)"
            ! grep -Fq 'No ACME email for Caddy' out ||
                fail "a run that deletes no volume ran the early Caddy email check" ;;
    esac
}
caddy_case refused '' ''
caddy_case refused admin@example.com ''
caddy_case deleted ops@sub.example.com ''
caddy_case deleted '' $'    tls internal\n'
caddy_case refused '' '' no
caddy_case refused 'ops@site.test' '' no
caddy_case refused ops@sub.example.com $'    tls ops@site.test\n' no
caddy_case kept '' $'    tls internal\n' no
# The import volume counts as well; the resume path and single-site mode
# never recreate Caddy.
(
    # shellcheck source=/dev/null
    source <(sed -n '/^check_setup_caddy_contacts() {/,/^}/p' "$root/docker/setup.sh")
    printf 'other.test {\n    reverse_proxy web:80\n}\n' > multi-site/caddy/sites/other.caddy
    printf '%s\n' MODE=multi SSL_PROVIDER=selfsigned EMAIL= > .env
    export DOCKER_HOST=unix:///nonexistent.sock
    # shellcheck disable=SC2034  # Read by the sourced check.
    EMAIL='' SETUP_VOLUME_TO_DELETE=''
    # shellcheck disable=SC2034
    MODE=multi RESUME_IMPORT=false IMPORT_VOLUME_TO_DELETE=imported
    if check_setup_caddy_contacts > out 2>&1; then fail "the import volume was not protected"; fi
    grep -Fq 'database volume imported, which was kept' out || fail "the refusal does not name the import volume"
    RESUME_IMPORT=true
    check_setup_caddy_contacts > out 2>&1 || fail "the resume path ran the early Caddy email check"
    # shellcheck disable=SC2034
    MODE=single RESUME_IMPORT=false
    check_setup_caddy_contacts > out 2>&1 || fail "single-site mode ran the Caddy email check"
)
# The check is the line after the one that writes the primary route, above
# the removal of the unused containers, the retirement and the stop.
line_of() { grep -nFx -- "$1" "$root/docker/setup.sh" | cut -d: -f1; }
# shellcheck disable=SC2016
route_line=$(line_of 'if [ "$MODE" = multi ]; then prepare_multi_site_proxy || exit 1; fi')
check_line=$(line_of 'check_setup_caddy_contacts || exit 1')
retire_line=$(line_of 'retirement_finish || exit 1')
stop_line=$(line_of 'stop_for_configured_ports || exit 1')
[[ "$route_line $check_line $retire_line $stop_line" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] &&
    [ "$check_line" -eq "$((route_line + 1))" ] && [ "$check_line" -lt "$retire_line" ] && [ "$check_line" -lt "$stop_line" ] ||
    fail "the Caddy email check is not between the primary route and the first stop"
echo "PASS: setup and reconfigure preserve the self-signed site's external HTTPS port"
