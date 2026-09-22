#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
REAL_DOCKER=$(type -P docker || true)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -n "$REAL_DOCKER" ] || fail "the Docker CLI with Compose support is required"

create_fixture() {
    local name="$1"
    local fixture="${TEST_DIR}/${name}/docker"

    mkdir -p "${fixture}/multi-site" "${fixture}/kvs-archive"
    cp "${ROOT_DIR}/docker/multi-site/site-manager.sh" "${fixture}/multi-site/"
    cp "${ROOT_DIR}/docker/multi-site/docker-compose.site.yml.template" \
        "${fixture}/multi-site/"
    : > "${fixture}/kvs-archive/KVS_test.zip"
}

openssl() {
    if [ -n "${MOCK_OPENSSL_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$MOCK_OPENSSL_LOG"
    fi
    printf '%s\n' 'deterministic-test-password'
}

chown() {
    return 0
}

docker() {
    if [ -n "${MOCK_DOCKER_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"
    fi

    case "${1:-}" in
        ps)
            if [ "${MOCK_CADDY_RUNNING:-true}" = true ]; then
                printf '%s\n' 'kvs-caddy'
            fi
            ;;
        network)
            case "${2:-}" in
                inspect)
                    [ "${MOCK_NETWORK_EXISTS:-true}" = true ]
                    ;;
                create)
                    MOCK_NETWORK_EXISTS=true
                    ;;
            esac
            ;;
        exec)
            if [ "${3:-}" = wget ]; then
                return 0
            fi
            return "${MOCK_CADDY_RELOAD_STATUS:-0}"
            ;;
        compose)
            if [[ " $* " == *' exec -T mariadb healthcheck.sh --connect --innodb_initialized '* ]]; then
                return "${MOCK_MARIADB_HEALTH_STATUS:-0}"
            fi
            if [[ " $* " == *' information_schema.tables '* ]]; then
                if [ -n "${MOCK_ADMIN_STATE_FILE:-}" ] &&
                    [ -s "$MOCK_ADMIN_STATE_FILE" ]; then
                    printf '%s\n' 1
                else
                    printf '%s\n' 0
                fi
                return 0
            fi
            if [[ " $* " == *'MD5(CONCAT('* ]]; then
                if [ -n "${MOCK_ADMIN_STATE_FILE:-}" ] &&
                    grep -Fxq default "$MOCK_ADMIN_STATE_FILE" 2>/dev/null; then
                    printf '%s\n' 1
                else
                    printf '%s\n' 0
                fi
                return 0
            fi
            if [[ " $* " == *' run --rm --no-deps phpmyadmin-init '* ]]; then
                return "${MOCK_PHPMYADMIN_INIT_STATUS:-0}"
            fi
            if [[ " $* " == *' run --rm --no-deps kvs-init '* ]]; then
                if [ -n "${MOCK_ADMIN_PASSWORD_LOG:-}" ]; then
                    if [ -n "${KVS_ADMIN_PASSWORD:-}" ]; then
                        printf '%s\n' set >> "$MOCK_ADMIN_PASSWORD_LOG"
                    else
                        printf '%s\n' empty >> "$MOCK_ADMIN_PASSWORD_LOG"
                    fi
                fi
                if [ "${MOCK_KVS_INIT_STATUS:-0}" -ne 0 ]; then
                    return "$MOCK_KVS_INIT_STATUS"
                fi
                if [ -n "${MOCK_ADMIN_STATE_FILE:-}" ]; then
                    printf '%s\n' hardened > "$MOCK_ADMIN_STATE_FILE"
                fi
                return 0
            fi
            return 0
            ;;
    esac
}
export -f openssl chown docker

create_fixture invalid
invalid_script="${TEST_DIR}/invalid/docker/multi-site/site-manager.sh"
invalid_webroot="${TEST_DIR}/invalid/webroots"
invalid_log="${TEST_DIR}/invalid/docker.log"
: > "$invalid_log"

for command in add start stop remove proxy-config; do
    set +e
    MOCK_DOCKER_LOG="$invalid_log" \
    KVS_WEBROOT_BASE="$invalid_webroot" \
        bash "$invalid_script" "$command" '../../escape.example' >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "${command} accepted a path traversal domain"
done

set +e
MOCK_DOCKER_LOG="$invalid_log" \
KVS_WEBROOT_BASE="$invalid_webroot" \
    bash "$invalid_script" primary-config '../../escape.example' kvs-valid >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "primary-config accepted a path traversal domain"

set +e
MOCK_CADDY_RUNNING=false \
KVS_WEBROOT_BASE="$invalid_webroot" \
    bash "$invalid_script" primary-remove '../../escape.example' kvs-valid >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "primary-remove accepted a path traversal domain"

printf -v mariadb_oversized_label '%*s' 61 ''
mariadb_oversized_label=${mariadb_oversized_label// /a}
set +e
KVS_WEBROOT_BASE="$invalid_webroot" \
    bash "$invalid_script" proxy-config "${mariadb_oversized_label}.com" public >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "proxy-config accepted a domain longer than MariaDB supports"

printf -v max_domain_label '%*s' 63 ''
printf -v oversized_domain_tail '%*s' 48 ''
max_domain_label=${max_domain_label// /a}
oversized_domain_tail=${oversized_domain_tail// /b}
oversized_domain="${max_domain_label}.${max_domain_label}.${max_domain_label}.${oversized_domain_tail}"
set +e
KVS_WEBROOT_BASE="$invalid_webroot" \
    bash "$invalid_script" proxy-config "$oversized_domain" public >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] || fail "proxy-config accepted a domain longer than generated filenames support"

[ ! -e "${TEST_DIR}/invalid/docker/multi-site/sites" ] ||
    fail "an invalid domain created the sites directory"
[ ! -e "${TEST_DIR}/invalid/docker/multi-site/caddy" ] ||
    fail "an invalid domain created the Caddy directory"
[ ! -e "$invalid_webroot" ] || fail "an invalid domain created a webroot"
[ ! -s "$invalid_log" ] || fail "an invalid domain invoked Docker"

create_fixture primary-remove
primary_remove_script="${TEST_DIR}/primary-remove/docker/multi-site/site-manager.sh"
primary_remove_root="${TEST_DIR}/primary-remove/docker/multi-site"
primary_remove_registration="${primary_remove_root}/sites/.primary.env"
primary_remove_route="${primary_remove_root}/caddy/sites/remove.example.com.caddy"
bash "$primary_remove_script" primary-config remove.example.com kvs-remove >/dev/null

set +e
MOCK_CADDY_RUNNING=true \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove modified routing while Caddy was running"
[ -f "$primary_remove_registration" ] && [ -f "$primary_remove_route" ] ||
    fail "a rejected live primary removal changed its files"

set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-other >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove accepted a mismatched site prefix"
[ -f "$primary_remove_registration" ] && [ -f "$primary_remove_route" ] ||
    fail "a mismatched primary removal changed its files"

mkdir -p "${primary_remove_root}/sites/remove.example.com"
set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove deleted a route still used by a managed site"
rmdir "${primary_remove_root}/sites/remove.example.com"

sed -i 's/reverse_proxy n\.remove\.example\.com:80/reverse_proxy unexpected:80/' \
    "$primary_remove_route"
set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove deleted an unexpected Caddy route"
bash "$primary_remove_script" primary-config remove.example.com kvs-remove >/dev/null

MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null
[ ! -e "$primary_remove_registration" ] && [ ! -e "$primary_remove_route" ] ||
    fail "primary-remove left the primary reservation or route behind"
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null ||
    fail "primary-remove is not idempotent after a completed removal"

cat > "$primary_remove_route" <<'EOF'
# KVS Site: remove.example.com
remove.example.com {
    reverse_proxy n.remove.example.com:80
}
EOF
set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove deleted an orphaned route without a reservation"
[ -f "$primary_remove_route" ] ||
    fail "primary-remove removed the orphaned route it rejected"
rm -f "$primary_remove_route"

: > "$primary_remove_registration"
chmod 0600 "$primary_remove_registration"
set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove treated an empty reservation as an idempotent absence"
[ -f "$primary_remove_registration" ] ||
    fail "primary-remove deleted an invalid empty reservation"

cat > "$primary_remove_registration" <<'EOF'
DOMAIN=remove.example.com
DOMAIN=shadow.example.com
SITE_PREFIX=kvs-remove
EOF
chmod 0600 "$primary_remove_registration"
set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove accepted duplicate reservation keys"

cat > "$primary_remove_registration" <<'EOF'
DOMAIN=remove.example.com
SITE_PREFIX=kvs-remove
EOF
chmod 0644 "$primary_remove_registration"
set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove accepted an insecure reservation mode"
rm -f "$primary_remove_registration"

printf '%s\n' 'not a reservation' > "${primary_remove_root}/reservation-target"
ln -s "${primary_remove_root}/reservation-target" "$primary_remove_registration"
set +e
MOCK_CADDY_RUNNING=false \
    bash "$primary_remove_script" primary-remove remove.example.com kvs-remove >/dev/null 2>&1
primary_remove_status=$?
set -e
[ "$primary_remove_status" -ne 0 ] ||
    fail "primary-remove followed a symbolic-link reservation"
rm -f "$primary_remove_registration"

create_fixture valid
valid_script="${TEST_DIR}/valid/docker/multi-site/site-manager.sh"
valid_webroot="${TEST_DIR}/valid/webroots"

(
    cd /
    KVS_WEBROOT_BASE="$valid_webroot" bash "$valid_script" add example.com >/dev/null
)

example_route="${TEST_DIR}/valid/docker/multi-site/caddy/sites/example.com.caddy"
grep -Fq 'www.example.com {' "$example_route" ||
    fail "a two-label managed site lost its historical www route"
grep -Fq 'redir https://example.com{uri} permanent' "$example_route" ||
    fail "a managed site's www host is not redirected to its canonical domain"

example_env="${TEST_DIR}/valid/docker/multi-site/sites/example.com/.env"
[ -f "$example_env" ] || fail "a valid site was not created from another directory"
[ "$(stat -c '%a' "$example_env")" = 600 ] || fail "the generated .env is not mode 0600"
[ -d "${valid_webroot}/example.com" ] || fail "the configured webroot base was not used"

KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" primary-config primary.example.co.uk kvs-reserved-com internal true >/dev/null
primary_route="${TEST_DIR}/valid/docker/multi-site/caddy/sites/primary.example.co.uk.caddy"
[ -f "$primary_route" ] || fail "primary-config did not create the primary route"
grep -Fq 'reverse_proxy n.primary.example.co.uk:80' "$primary_route" ||
    fail "primary-config generated the wrong upstream"
grep -Fq 'tls internal' "$primary_route" ||
    fail "primary-config did not preserve the internal TLS mode"
grep -Fq 'www.primary.example.co.uk {' "$primary_route" ||
    fail "primary-config omitted the canonical www hostname"
grep -Fq 'redir https://www.primary.example.co.uk{uri} permanent' "$primary_route" ||
    fail "primary-config omitted the canonical www redirect"
primary_registration="${TEST_DIR}/valid/docker/multi-site/sites/.primary.env"
[ "$(stat -c '%a' "$primary_registration")" = 600 ] ||
    fail "the primary site reservation is not mode 0600"
grep -Fxq 'SITE_PREFIX=kvs-reserved-com' "$primary_registration" ||
    fail "the primary site prefix was not reserved"
[ ! -e "${TEST_DIR}/valid/docker/multi-site/sites/primary.example.co.uk" ] ||
    fail "primary-config unexpectedly created a site stack"
[ ! -e "${valid_webroot}/primary.example.co.uk" ] ||
    fail "primary-config unexpectedly created a webroot"

primary_route_hash=$(sha256sum "$primary_route")
set +e
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" add primary.example.co.uk >/dev/null 2>&1
primary_duplicate_status=$?
set -e
[ "$primary_duplicate_status" -ne 0 ] || fail "the primary domain was accepted as a second site"
[ ! -e "${TEST_DIR}/valid/docker/multi-site/sites/primary.example.co.uk" ] ||
    fail "the rejected primary duplicate created a second stack"
[ "$(sha256sum "$primary_route")" = "$primary_route_hash" ] ||
    fail "the rejected primary duplicate overwrote its Caddy route"

set +e
KVS_WEBROOT_BASE="$valid_webroot" bash "$valid_script" add reserved.com >/dev/null 2>&1
primary_prefix_status=$?
set -e
[ "$primary_prefix_status" -ne 0 ] || fail "a primary site prefix collision was accepted"
[ ! -e "${TEST_DIR}/valid/docker/multi-site/sites/reserved.com" ] ||
    fail "a primary prefix collision created a site"

KVS_WEBROOT_BASE="$valid_webroot" bash "$valid_script" add a-b.com >/dev/null

# Simulate a site generated by the previous lossy dot-to-hyphen mapping.
sed -i 's/^SITE_PREFIX=.*/SITE_PREFIX=kvs-a-b-com/' \
    "${TEST_DIR}/valid/docker/multi-site/sites/a-b.com/.env"
set +e
KVS_WEBROOT_BASE="$valid_webroot" bash "$valid_script" add a.b.com >/dev/null 2>&1
legacy_collision_status=$?
set -e
[ "$legacy_collision_status" -ne 0 ] || fail "a legacy prefix collision was accepted"
[ ! -e "${TEST_DIR}/valid/docker/multi-site/sites/a.b.com" ] ||
    fail "a legacy prefix collision created a site"

sed -i 's/^SITE_PREFIX=.*/SITE_PREFIX=kvs-a_b-com/' \
    "${TEST_DIR}/valid/docker/multi-site/sites/a-b.com/.env"
KVS_WEBROOT_BASE="$valid_webroot" bash "$valid_script" add a.b.com >/dev/null
KVS_WEBROOT_BASE="$valid_webroot" bash "$valid_script" add ab.com >/dev/null

if grep -Fq 'www.a.b.com' \
    "${TEST_DIR}/valid/docker/multi-site/caddy/sites/a.b.com.caddy"; then
    fail "a managed subdomain unexpectedly requested a www certificate"
fi

first_prefix=$(sed -n 's/^SITE_PREFIX=//p' \
    "${TEST_DIR}/valid/docker/multi-site/sites/a-b.com/.env")
second_prefix=$(sed -n 's/^SITE_PREFIX=//p' \
    "${TEST_DIR}/valid/docker/multi-site/sites/a.b.com/.env")
[ "$first_prefix" != "$second_prefix" ] || fail "two valid domains received the same prefix"
[ "$first_prefix" = 'kvs-a_b-com' ] || fail "the hyphenated domain prefix is unexpected"
[ "$second_prefix" = 'kvs-a-b-com' ] || fail "the dotted domain prefix is unexpected"

dotted_config=$(
    cd "${TEST_DIR}/valid/docker/multi-site/sites/a.b.com"
    "$REAL_DOCKER" compose config --format json
)
compact_config=$(
    cd "${TEST_DIR}/valid/docker/multi-site/sites/ab.com"
    "$REAL_DOCKER" compose config --format json
)
grep -Fq '"name": "kvs-a-b-com"' <<< "$dotted_config" ||
    fail "the dotted domain Compose project name is incorrect"
grep -Fq '"name": "kvs-a-b-com_mariadb-data"' <<< "$dotted_config" ||
    fail "the dotted domain volume name is incorrect"
grep -Fq '"name": "kvs-ab-com"' <<< "$compact_config" ||
    fail "the compact domain Compose project name is incorrect"
grep -Fq '"name": "kvs-ab-com_mariadb-data"' <<< "$compact_config" ||
    fail "the compact domain volume name is incorrect"
if grep -Fq '"name": "kvs-a-b-com"' <<< "$compact_config"; then
    fail "distinct domains received the same Compose project name"
fi

start_log="${TEST_DIR}/valid/start-twice.log"
admin_state="${TEST_DIR}/valid/admin-state"
admin_password_log="${TEST_DIR}/valid/admin-password-state.log"
admin_generation_log="${TEST_DIR}/valid/admin-generation.log"
first_start_output="${TEST_DIR}/valid/first-start.log"
second_start_output="${TEST_DIR}/valid/second-start.log"
: > "$start_log"
: > "$admin_password_log"
: > "$admin_generation_log"
MOCK_DOCKER_LOG="$start_log" \
MOCK_ADMIN_STATE_FILE="$admin_state" \
MOCK_ADMIN_PASSWORD_LOG="$admin_password_log" \
MOCK_OPENSSL_LOG="$admin_generation_log" \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" start example.com > "$first_start_output"
MOCK_DOCKER_LOG="$start_log" \
MOCK_ADMIN_STATE_FILE="$admin_state" \
MOCK_ADMIN_PASSWORD_LOG="$admin_password_log" \
MOCK_OPENSSL_LOG="$admin_generation_log" \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" start example.com > "$second_start_output"

[ "$(grep -Fc 'One-time admin password:' "$first_start_output")" -eq 1 ] ||
    fail "the first start did not generate exactly one admin password"
if grep -Fq 'One-time admin password:' "$second_start_output"; then
    fail "the second start regenerated an already hardened admin password"
fi
[ "$(wc -l < "$admin_generation_log")" -eq 1 ] ||
    fail "the admin password generator did not run exactly once across two starts"
[ "$(sed -n '1p' "$admin_password_log")" = set ] &&
    [ "$(sed -n '2p' "$admin_password_log")" = empty ] ||
    fail "KVS initialization did not receive the password only on first hardening"
[ "$(grep -Fxc 'compose up -d mariadb' "$start_log")" -eq 2 ] ||
    fail "MariaDB was not started explicitly before both initializations"
[ "$(grep -Fxc 'compose --profile setup run --rm --no-deps phpmyadmin-init' \
    "$start_log")" -eq 2 ] ||
    fail "phpMyAdmin initialization is not a checked one-shot on every start"
[ "$(grep -Fxc 'compose --profile setup run --rm --no-deps kvs-init' \
    "$start_log")" -eq 2 ] ||
    fail "KVS initialization is not a checked one-shot on every start"
[ "$(grep -Fxc \
    'exec kvs-caddy caddy reload --force --config /etc/caddy/Caddyfile' \
    "$start_log")" -eq 2 ] ||
    fail "an unchanged site start did not force Caddy upstream reprovisioning"
if grep -F 'exec kvs-caddy caddy reload' "$start_log" |
    grep -Fvq 'caddy reload --force --config'; then
    fail "a successful site start used an unforced Caddy reload"
fi
# The Docker mock records the literal in-container shell program.
# shellcheck disable=SC2016
grep -Fq 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot' "$start_log" ||
    fail "multisite database inspection does not authenticate through MYSQL_PWD"
# shellcheck disable=SC2016
if grep -Fq -- '-p"$MARIADB_ROOT_PASSWORD"' "$start_log"; then
    fail "multisite database inspection exposes the password in MariaDB arguments"
fi
if grep -Fq 'deterministic-test-password' "$start_log"; then
    fail "a generated password was exposed in host-side Docker arguments"
fi
if grep -Eq '^KVS_ADMIN_PASSWORD=' "$example_env"; then
    fail "the generated admin password was persisted in the site environment"
fi

mkdir -p "${TEST_DIR}/valid/docker/multi-site/sites/oneshot-failure.example"
oneshot_failure_log="${TEST_DIR}/valid/oneshot-failure.log"
set +e
MOCK_PHPMYADMIN_INIT_STATUS=42 \
MOCK_DOCKER_LOG="$oneshot_failure_log" \
MOCK_ADMIN_STATE_FILE="$admin_state" \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" start oneshot-failure.example >/dev/null 2>&1
oneshot_failure_status=$?
set -e
[ "$oneshot_failure_status" -eq 42 ] ||
    fail "a failing phpMyAdmin one-shot did not propagate its exit status"
grep -Fxq 'compose --profile setup run --rm --no-deps phpmyadmin-init' \
    "$oneshot_failure_log" || fail "the failing phpMyAdmin one-shot was not invoked"
if grep -Fq 'run --rm --no-deps kvs-init' "$oneshot_failure_log" ||
    grep -Fxq 'compose up -d' "$oneshot_failure_log"; then
    fail "site startup continued after a failed phpMyAdmin one-shot"
fi

mkdir -p "${TEST_DIR}/valid/docker/multi-site/sites/kvs-init-failure.example"
kvs_init_failure_log="${TEST_DIR}/valid/kvs-init-failure.log"
set +e
MOCK_KVS_INIT_STATUS=43 \
MOCK_DOCKER_LOG="$kvs_init_failure_log" \
MOCK_ADMIN_STATE_FILE="$admin_state" \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" start kvs-init-failure.example >/dev/null 2>&1
kvs_init_failure_status=$?
set -e
[ "$kvs_init_failure_status" -eq 43 ] ||
    fail "a failing KVS one-shot did not propagate its exit status"
grep -Fxq 'compose --profile setup run --rm --no-deps phpmyadmin-init' \
    "$kvs_init_failure_log" || fail "phpMyAdmin one-shot did not precede KVS initialization"
grep -Fxq 'compose --profile setup run --rm --no-deps kvs-init' \
    "$kvs_init_failure_log" || fail "the failing KVS one-shot was not invoked"
if grep -Fxq 'compose up -d' "$kvs_init_failure_log"; then
    fail "site startup continued after a failed KVS one-shot"
fi

printf -v long_label_a '%*s' 60 ''
long_label_a=${long_label_a// /a}
long_domain="${long_label_a}.com"
KVS_WEBROOT_BASE="$valid_webroot" bash "$valid_script" add "$long_domain" >/dev/null
[ -d "${TEST_DIR}/valid/docker/multi-site/sites/${long_domain}" ] ||
    fail "a domain at the MariaDB identifier limit was rejected"

printf -v max_label '%*s' 63 ''
printf -v final_label '%*s' 44 ''
max_label=${max_label// /a}
final_label=${final_label// /b}
oversized_prefix_domain="${max_label}.${max_label}.${max_label}.${final_label}"
set +e
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" add "$oversized_prefix_domain" >/dev/null 2>&1
oversized_domain_status=$?
set -e
[ "$oversized_domain_status" -ne 0 ] || fail "a domain longer than MariaDB supports was accepted"
[ ! -e "${TEST_DIR}/valid/docker/multi-site/sites/${oversized_prefix_domain}" ] ||
    fail "an unsupported long domain created a site"

mkdir -p "${TEST_DIR}/valid/docker/multi-site/sites/reload.example"
reload_log="${TEST_DIR}/valid/reload.log"
set +e
MOCK_CADDY_RELOAD_STATUS=23 \
MOCK_DOCKER_LOG="$reload_log" \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" start reload.example > "${TEST_DIR}/valid/reload-output.log" 2>&1
reload_status=$?
set -e

[ "$reload_status" -ne 0 ] || fail "a failed Caddy reload returned success"
grep -Fxq \
    'exec kvs-caddy caddy reload --force --config /etc/caddy/Caddyfile' \
    "$reload_log" || fail "the failing Caddy reload did not use --force"
grep -Fq 'Failed to reload Caddy configuration' \
    "${TEST_DIR}/valid/reload-output.log" || fail "the Caddy reload failure was not reported"
if grep -Fq 'Caddy reloaded' "${TEST_DIR}/valid/reload-output.log"; then
    fail "a failed Caddy reload was reported as successful"
fi
if grep -Fq 'Site reload.example started' "${TEST_DIR}/valid/reload-output.log"; then
    fail "the site was reported as started after a failed Caddy reload"
fi

caddy_start_log="${TEST_DIR}/valid/caddy-start.log"
MOCK_NETWORK_EXISTS=false \
MOCK_DOCKER_LOG="$caddy_start_log" \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" caddy-start >/dev/null
network_create_line=$(grep -nF 'network create kvs-proxy' "$caddy_start_log" | cut -d: -f1)
compose_up_line=$(grep -nF 'compose -p multi-site -f docker-compose.caddy.yml up -d' \
    "$caddy_start_log" | cut -d: -f1)
[ -n "$network_create_line" ] || fail "caddy-start did not create the external network"
[ -n "$compose_up_line" ] || fail "caddy-start did not preserve the historical Compose project"
[ "$network_create_line" -lt "$compose_up_line" ] ||
    fail "Caddy started before its external network was created"

reload_call_count=$(grep -Fc 'docker exec kvs-caddy caddy reload' \
    "$ROOT_DIR/docker/multi-site/site-manager.sh")
forced_reload_call_count=$(grep -Fc 'docker exec kvs-caddy caddy reload --force' \
    "$ROOT_DIR/docker/multi-site/site-manager.sh")
[ "$reload_call_count" -eq "$forced_reload_call_count" ] &&
    [ "$reload_call_count" -gt 0 ] ||
    fail "site-manager.sh contains an unforced Caddy reload path"

echo "PASS: Multi-site manager hardening"
