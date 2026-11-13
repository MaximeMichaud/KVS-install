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

    mkdir -p "${fixture}/multi-site" "${fixture}/kvs-archive" "${fixture}/bin"
    cp "${ROOT_DIR}/docker/multi-site/site-manager.sh" "${fixture}/multi-site/"
    cp "${ROOT_DIR}/docker/multi-site/docker-compose.site.yml.template" \
        "${fixture}/multi-site/"
    # A new site takes its PHP build bases from docker/images.lock.
    cp "${ROOT_DIR}/docker/bin/resolve-bases.sh" "${fixture}/bin/"
    cp "${ROOT_DIR}/docker/images.lock" "${fixture}/"
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
            # The R1 collision checks query Compose project labels with
            # --filter. Plain name checks (Caddy, nginx) carry no --filter and
            # keep their historical answer below. Both label queries default to
            # empty, so an add in the other fixtures still sees no project.
            # MOCK_CONTAINER_STATE names a file of "<project><TAB><working
            # dir>" lines, the containers a case starts with: the label
            # queries answer for the project they filter on, and a listing
            # of every container's project and working directory prints it
            # (MOCK_PS_STATUS makes that listing fail).
            local mock_arg mock_filter="" mock_state_project mock_state_dir
            for mock_arg in "$@"; do
                case "$mock_arg" in
                    label=com.docker.compose.project=*)
                        mock_filter=${mock_arg#label=com.docker.compose.project=}
                        ;;
                esac
            done
            if [[ " $* " == *' --filter '* ]]; then
                case " $* " in
                    *project.working_dir*)
                        [ -z "${MOCK_PROJECT_WORKDIRS:-}" ] ||
                            printf '%s\n' "${MOCK_PROJECT_WORKDIRS}"
                        ;;
                    *)
                        [ -z "${MOCK_PROJECT_CONTAINERS:-}" ] ||
                            printf '%s\n' "${MOCK_PROJECT_CONTAINERS}"
                        ;;
                esac
                if [ -n "${MOCK_CONTAINER_STATE:-}" ] && [ -n "$mock_filter" ]; then
                    while IFS=$'\t' read -r mock_state_project mock_state_dir; do
                        [ "$mock_state_project" = "$mock_filter" ] || continue
                        case " $* " in
                            *project.working_dir*) printf '%s\n' "$mock_state_dir" ;;
                            *) printf 'id-%s\n' "$mock_state_project" ;;
                        esac
                    done < "$MOCK_CONTAINER_STATE"
                fi
                return 0
            fi
            if [[ " $* " == *'com.docker.compose.project.working_dir'* ]]; then
                [ "${MOCK_PS_STATUS:-0}" -eq 0 ] || return "$MOCK_PS_STATUS"
                [ -z "${MOCK_CONTAINER_STATE:-}" ] || cat "$MOCK_CONTAINER_STATE"
                return 0
            fi
            if [ "${MOCK_CADDY_RUNNING:-true}" = true ]; then
                printf '%s\n' 'kvs-caddy'
            fi
            ;;
        volume)
            # volume ls --filter label=com.docker.compose.project=<project>
            # lists the volumes of MOCK_PROJECT_VOLUMES that Compose would have
            # named for that project, <project>_<volume>; without the filter,
            # all of them. MOCK_VOLUME_LS_STATUS makes the listing fail.
            [ "${MOCK_VOLUME_LS_STATUS:-0}" -eq 0 ] || return "$MOCK_VOLUME_LS_STATUS"
            local mock_arg mock_project="" mock_volume
            for mock_arg in "$@"; do
                case "$mock_arg" in
                    label=com.docker.compose.project=*)
                        mock_project=${mock_arg#label=com.docker.compose.project=}
                        ;;
                esac
            done
            # MOCK_VOLUME_STATE names a file of volumes too, one per line,
            # which a down -v of their project empties.
            while IFS= read -r mock_volume; do
                [ -n "$mock_volume" ] || continue
                if [ -z "$mock_project" ] || [[ "$mock_volume" == "${mock_project}_"* ]]; then
                    printf '%s\n' "$mock_volume"
                fi
            done < <(
                [ -z "${MOCK_PROJECT_VOLUMES:-}" ] || printf '%s\n' "$MOCK_PROJECT_VOLUMES"
                [ -z "${MOCK_VOLUME_STATE:-}" ] || cat "$MOCK_VOLUME_STATE"
            )
            return 0
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
            # The options before the subcommand, the ones that choose the
            # project and its files.
            local -a mock_global=()
            local mock_arg mock_index=2 mock_project=""
            while [ "$mock_index" -le "$#" ]; do
                mock_arg=${!mock_index}
                case "$mock_arg" in
                    -p|-f|--profile|--project-directory|--env-file)
                        mock_global+=("$mock_arg")
                        mock_index=$((mock_index + 1))
                        [ "$mock_arg" != -p ] || mock_project=${!mock_index}
                        mock_global+=("${!mock_index}")
                        ;;
                    -*) mock_global+=("$mock_arg") ;;
                    *) break ;;
                esac
                mock_index=$((mock_index + 1))
            done
            if [[ " $* " == *' down -v '* ]]; then
                # MOCK_COMPOSE_RENDER=<prefix>: what the real Compose loads
                # with those options in this directory, from the same
                # environment, written to <prefix>.services and
                # <prefix>.volumes (config needs no daemon and no network).
                if [ -n "${MOCK_COMPOSE_RENDER:-}" ]; then
                    "$REAL_DOCKER" compose "${mock_global[@]}" config --services \
                        > "${MOCK_COMPOSE_RENDER}.services" 2>&1
                    "$REAL_DOCKER" compose "${mock_global[@]}" config --volumes \
                        > "${MOCK_COMPOSE_RENDER}.volumes" 2>&1
                fi
                [ "${MOCK_COMPOSE_DOWN_STATUS:-0}" -eq 0 ] || return "$MOCK_COMPOSE_DOWN_STATUS"
                # down -v takes the containers and volumes of its project.
                if [ -n "$mock_project" ] && [ -n "${MOCK_CONTAINER_STATE:-}" ]; then
                    awk -F '\t' -v p="$mock_project" '$1 != p' "$MOCK_CONTAINER_STATE" \
                        > "${MOCK_CONTAINER_STATE}.new"
                    mv "${MOCK_CONTAINER_STATE}.new" "$MOCK_CONTAINER_STATE"
                fi
                if [ -n "$mock_project" ] && [ -n "${MOCK_VOLUME_STATE:-}" ]; then
                    awk -v p="${mock_project}_" 'index($0, p) != 1' "$MOCK_VOLUME_STATE" \
                        > "${MOCK_VOLUME_STATE}.new"
                    mv "${MOCK_VOLUME_STATE}.new" "$MOCK_VOLUME_STATE"
                fi
                return 0
            fi
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
            # The login of user 1 while it holds the archive password.
            if [[ " $* " == *'MD5(CONCAT('* ]]; then
                [ "${MOCK_ADMIN_QUERY_STATUS:-0}" -eq 0 ] || return "$MOCK_ADMIN_QUERY_STATUS"
                if [ -n "${MOCK_ADMIN_STATE_FILE:-}" ] &&
                    grep -Fxq default "$MOCK_ADMIN_STATE_FILE" 2>/dev/null; then
                    printf '%s\n' "${MOCK_ADMIN_LOGIN:-admin}"
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
# The mock's MOCK_COMPOSE_RENDER runs the real Compose.
export REAL_DOCKER

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

# A new site builds PHP-FPM and cron from the bases docker/images.lock pins
# for its series, like the primary site, and the template reads them.
site_php=$(sed -n 's/^PHP_VERSION=//p' "$example_env")
pinned_fpm=$("${ROOT_DIR}/docker/bin/resolve-bases.sh" --get php-fpm "$site_php")
pinned_cli=$("${ROOT_DIR}/docker/bin/resolve-bases.sh" --get php-cli "$site_php")
grep -Fxq "PHP_FPM_BASE=${pinned_fpm}" "$example_env" ||
    fail "a new site does not carry the pinned PHP-FPM base of PHP ${site_php}"
grep -Fxq "PHP_CLI_BASE=${pinned_cli}" "$example_env" ||
    fail "a new site does not carry the pinned PHP CLI base of PHP ${site_php}"
example_config=$(
    cd "${TEST_DIR}/valid/docker/multi-site/sites/example.com"
    "$REAL_DOCKER" compose config --format json
)
[ "$(jq -r '.services["php-fpm"].build.args.PHP_BASE' <<< "$example_config")" = "$pinned_fpm" ] ||
    fail "the PHP-FPM of a new site does not build from its pinned base"
[ "$(jq -r '.services.cron.build.args.PHP_BASE' <<< "$example_config")" = "$pinned_cli" ] ||
    fail "the cron of a new site does not build from its pinned base"

# A series the lock does not know stops the addition before anything exists.
create_fixture unpinned
unpinned_root="${TEST_DIR}/unpinned/docker"
sed -i '/^php-fpm[[:space:]]8\.1[[:space:]]/d' "${unpinned_root}/images.lock"
set +e
KVS_WEBROOT_BASE="${TEST_DIR}/unpinned/webroots" \
    bash "${unpinned_root}/multi-site/site-manager.sh" add example.org > "${TEST_DIR}/unpinned/out" 2>&1
unpinned_status=$?
set -e
[ "$unpinned_status" -ne 0 ] || fail "a site was added without a pinned PHP base"
grep -Fq 'PHP 8.1 has no pinned base in docker/images.lock' "${TEST_DIR}/unpinned/out" ||
    fail "the missing PHP base was not reported: $(cat "${TEST_DIR}/unpinned/out")"
[ ! -e "${unpinned_root}/multi-site/sites/example.org" ] &&
    [ ! -e "${unpinned_root}/multi-site/caddy/sites/example.org.caddy" ] &&
    [ ! -e "${TEST_DIR}/unpinned/webroots/example.org" ] ||
    fail "a site refused for its PHP base left files behind"

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

# A kept database whose user 1 was renamed but still has the archive
# password: the one-time password is printed with that login. When the check
# itself fails, the start stops before kvs-init instead of printing a login
# it did not read next to a password it applied.
renamed_state="${TEST_DIR}/valid/admin-state-renamed"
renamed_output="${TEST_DIR}/valid/renamed-start.log"
printf '%s\n' default > "$renamed_state"
MOCK_DOCKER_LOG="${TEST_DIR}/valid/renamed-docker.log" \
MOCK_ADMIN_STATE_FILE="$renamed_state" \
MOCK_ADMIN_LOGIN=boss \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" start example.com > "$renamed_output"
grep -Fxq 'Admin login: boss' "$renamed_output" ||
    fail "the one-time password was not shown with the renamed account's login"
grep -Fq 'One-time admin password:' "$renamed_output" ||
    fail "a renamed account with the archive password got no one-time password"

check_failure_state="${TEST_DIR}/valid/admin-state-check-failure"
check_failure_output="${TEST_DIR}/valid/check-failure-start.log"
check_failure_log="${TEST_DIR}/valid/check-failure-docker.log"
printf '%s\n' default > "$check_failure_state"
set +e
MOCK_DOCKER_LOG="$check_failure_log" \
MOCK_ADMIN_STATE_FILE="$check_failure_state" \
MOCK_ADMIN_QUERY_STATUS=1 \
KVS_WEBROOT_BASE="$valid_webroot" \
    bash "$valid_script" start example.com > "$check_failure_output" 2>&1
check_failure_status=$?
set -e
[ "$check_failure_status" -ne 0 ] ||
    fail "a failed admin account check did not stop the start"
if grep -Fq 'Admin login:' "$check_failure_output" ||
    grep -Fq 'run --rm --no-deps kvs-init' "$check_failure_log"; then
    fail "the start went on after the admin account check failed"
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

# ---------------------------------------------------------------------------
# R1: a new site must not reuse the primary's Compose project, and remove must
# not 'down -v' a project whose containers were created from another directory
# (a single-mode primary that shares the kvs-<domain> project name).
# ---------------------------------------------------------------------------

# setup.sh names the primary a-test.example kvs-a-test (its domain without the
# TLD), and add a.test derives the same kvs-a-test. A single-mode primary
# records it in docker/.env only, with no .primary.env: add must refuse it.
create_fixture r1_env
r1_env_script="${TEST_DIR}/r1_env/docker/multi-site/site-manager.sh"
printf 'COMPOSE_PROJECT_NAME=kvs-a-test\nSITE_PREFIX=kvs-a-test\n' > "${TEST_DIR}/r1_env/docker/.env"  # pragma: allowlist secret
set +e
MOCK_DOCKER_LOG="${TEST_DIR}/r1_env/docker.log" \
KVS_WEBROOT_BASE="${TEST_DIR}/r1_env/webroots" \
    bash "$r1_env_script" add a.test >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] ||
    fail "add reused the single-mode primary's project recorded in docker/.env"
[ ! -e "${TEST_DIR}/r1_env/docker/multi-site/sites/a.test" ] ||
    fail "the refused add created the site directory"

# Whatever docker/.env says, a project that already owns containers must not be
# reused: docker/.env names another prefix here, but a container exists.
create_fixture r1_label
r1_label_script="${TEST_DIR}/r1_label/docker/multi-site/site-manager.sh"
printf 'COMPOSE_PROJECT_NAME=kvs-other\nSITE_PREFIX=kvs-other\n' > "${TEST_DIR}/r1_label/docker/.env"  # pragma: allowlist secret
set +e
MOCK_PROJECT_CONTAINERS='c0ffee' \
MOCK_DOCKER_LOG="${TEST_DIR}/r1_label/docker.log" \
KVS_WEBROOT_BASE="${TEST_DIR}/r1_label/webroots" \
    bash "$r1_label_script" add a.test >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] ||
    fail "add reused a Compose project that already has containers"
[ ! -e "${TEST_DIR}/r1_label/docker/multi-site/sites/a.test" ] ||
    fail "the refused add (existing project) created the site directory"

# The primary registers its own prefix. setup.sh has written it to docker/.env
# before it runs primary-config, the first time multi mode is set up (a fresh
# multi install or a single to multi switch, where the primary's containers
# already exist). Neither the docker/.env check nor the container check of add
# may refuse it, or setup.sh stops and every re-run fails the same way.
create_fixture r1_primary
r1_primary_script="${TEST_DIR}/r1_primary/docker/multi-site/site-manager.sh"
r1_primary_sites="${TEST_DIR}/r1_primary/docker/multi-site/sites"
printf 'SITE_PREFIX=kvs-a-test\nCOMPOSE_PROJECT_NAME=kvs-a-test\nMODE=multi\nDOMAIN=a-test.example\n' \
    > "${TEST_DIR}/r1_primary/docker/.env"  # pragma: allowlist secret
set +e
MOCK_CADDY_RUNNING=false \
    bash "$r1_primary_script" primary-config a-test.example kvs-a-test internal false \
    > "${TEST_DIR}/r1_primary/out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] ||
    fail "primary-config refused the primary's own prefix recorded in docker/.env: $(cat "${TEST_DIR}/r1_primary/out")"
grep -Fxq 'SITE_PREFIX=kvs-a-test' "${r1_primary_sites}/.primary.env" 2>/dev/null ||
    fail "primary-config did not record the primary's reservation"
rm -f "${r1_primary_sites}/.primary.env"
set +e
MOCK_CADDY_RUNNING=false MOCK_PROJECT_CONTAINERS='0123abcd' \
    bash "$r1_primary_script" primary-config a-test.example kvs-a-test internal false \
    > "${TEST_DIR}/r1_primary/out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] ||
    fail "primary-config refused the primary because its own containers exist: $(cat "${TEST_DIR}/r1_primary/out")"
echo "PASS: primary-config accepts the primary's own prefix and containers"

# remove must not 'down -v' a project whose containers were created elsewhere.
create_fixture r1_remove
r1_remove_script="${TEST_DIR}/r1_remove/docker/multi-site/site-manager.sh"
r1_remove_site="${TEST_DIR}/r1_remove/docker/multi-site/sites/a.test"
mkdir -p "$r1_remove_site"
printf 'DOMAIN=a.test\nSITE_PREFIX=kvs-a-test\nCOMPOSE_PROJECT_NAME=kvs-a-test\n' \
    > "$r1_remove_site/.env"
: > "$r1_remove_site/docker-compose.yml"
r1_remove_log="${TEST_DIR}/r1_remove/docker.log"
: > "$r1_remove_log"
set +e
printf 'yes\n' | MOCK_PROJECT_WORKDIRS="${TEST_DIR}/r1_remove/docker" \
    MOCK_DOCKER_LOG="$r1_remove_log" \
    KVS_WEBROOT_BASE="${TEST_DIR}/r1_remove/webroots" \
    bash "$r1_remove_script" remove a.test >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ] ||
    fail "remove tore down a project whose working directory differs"
! grep -q 'compose.* down -v' "$r1_remove_log" ||
    fail "remove ran 'docker compose down -v' on a project from another directory"
[ -d "$r1_remove_site" ] ||
    fail "remove deleted the site directory despite refusing 'down -v'"

# A site created before the add checks existed can still share the primary's
# project. With the primary stopped by 'docker compose down', its containers
# are gone and only its volumes remain, so no label tells them apart: remove
# must refuse a project the primary records in docker/.env or .primary.env.
for r1_record in env reservation; do
    create_fixture "r1_shared_${r1_record}"
    r1_shared_root="${TEST_DIR}/r1_shared_${r1_record}/docker"
    r1_shared_site="${r1_shared_root}/multi-site/sites/a.test"
    mkdir -p "$r1_shared_site"
    printf 'DOMAIN=a.test\nSITE_PREFIX=kvs-a-test\nCOMPOSE_PROJECT_NAME=kvs-a-test\n' \
        > "$r1_shared_site/.env"
    : > "$r1_shared_site/docker-compose.yml"
    if [ "$r1_record" = env ]; then
        printf 'COMPOSE_PROJECT_NAME=kvs-a-test\nSITE_PREFIX=kvs-a-test\n' > "${r1_shared_root}/.env"  # pragma: allowlist secret
    else
        printf 'DOMAIN=a-test.example\nSITE_PREFIX=kvs-a-test\n' \
            > "${r1_shared_root}/multi-site/sites/.primary.env"
        chmod 600 "${r1_shared_root}/multi-site/sites/.primary.env"
    fi
    r1_shared_log="${TEST_DIR}/r1_shared_${r1_record}/docker.log"
    : > "$r1_shared_log"
    set +e
    printf 'yes\nn\n' | MOCK_PROJECT_VOLUMES='kvs-a-test_mariadb-data' \
        MOCK_DOCKER_LOG="$r1_shared_log" \
        KVS_WEBROOT_BASE="${TEST_DIR}/r1_shared_${r1_record}/webroots" \
        bash "${r1_shared_root}/multi-site/site-manager.sh" remove a.test >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] ||
        fail "remove accepted a site sharing the primary's project (${r1_record})"
    ! grep -q 'compose.* down -v' "$r1_shared_log" ||
        fail "remove ran 'docker compose down -v' on the primary's project (${r1_record})"
    [ -d "$r1_shared_site" ] ||
        fail "remove deleted a site sharing the primary's project (${r1_record})"
done
echo "PASS: remove refuses a project the primary records, without containers"

# The guard must still allow a legitimate removal whose project comes from this
# site's own directory, also when Compose recorded it through a symlinked path,
# and down -v must name the site's project so an exported COMPOSE_PROJECT_NAME
# cannot point it at another stack.
create_fixture r1_remove_ok
r1_ok_script="${TEST_DIR}/r1_remove_ok/docker/multi-site/site-manager.sh"
r1_ok_site="${TEST_DIR}/r1_remove_ok/docker/multi-site/sites/a.test"
mkdir -p "$r1_ok_site"
ln -s "$r1_ok_site" "${TEST_DIR}/r1_remove_ok/site-link"
printf 'DOMAIN=a.test\nSITE_PREFIX=kvs-a-test\nCOMPOSE_PROJECT_NAME=kvs-a-test\n' \
    > "$r1_ok_site/.env"
: > "$r1_ok_site/docker-compose.yml"
r1_ok_log="${TEST_DIR}/r1_remove_ok/docker.log"
: > "$r1_ok_log"
set +e
printf 'yes\n' | MOCK_PROJECT_WORKDIRS="${TEST_DIR}/r1_remove_ok/site-link" \
    COMPOSE_PROJECT_NAME=kvs-elsewhere \
    MOCK_DOCKER_LOG="$r1_ok_log" \
    KVS_WEBROOT_BASE="${TEST_DIR}/r1_remove_ok/webroots" \
    bash "$r1_ok_script" remove a.test >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 0 ] ||
    fail "remove refused a legitimate site whose project matches its own directory"
grep -Fxq "compose -p kvs-a-test down -v --remove-orphans" "$r1_ok_log" ||
    fail "a legitimate remove did not run 'docker compose -p kvs-a-test down -v --remove-orphans': $(cat "$r1_ok_log")"
[ ! -d "$r1_ok_site" ] ||
    fail "a legitimate remove kept the site directory"

# R2: a host two sites would both serve makes the Caddy config ambiguous, so
# every reload fails and a restart takes all sites down. An add must refuse
# such a host and leave no half-made site.
create_fixture r2_hosts
r2_script="${TEST_DIR}/r2_hosts/docker/multi-site/site-manager.sh"
r2_webroot="${TEST_DIR}/r2_hosts/webroots"
r2_caddy="${TEST_DIR}/r2_hosts/docker/multi-site/caddy/sites"
r2_sites="${TEST_DIR}/r2_hosts/docker/multi-site/sites"

# A two-label site also serves its www host through a redirect.
KVS_WEBROOT_BASE="$r2_webroot" bash "$r2_script" add collide.example >/dev/null
[ -f "${r2_caddy}/collide.example.caddy" ] || fail "R2: the first site was not created"

set +e
KVS_WEBROOT_BASE="$r2_webroot" \
    bash "$r2_script" add www.collide.example > "${TEST_DIR}/r2_hosts/out" 2>&1
r2_status=$?
set -e
[ "$r2_status" -ne 0 ] ||
    fail "R2: a second site claimed www.collide.example, already served by the first"
[ ! -e "${r2_caddy}/www.collide.example.caddy" ] ||
    fail "R2: the ambiguous www.collide.example route was written"
[ ! -e "${r2_sites}/www.collide.example" ] ||
    fail "R2: the refused site left its directory behind"
[ ! -e "${r2_webroot}/www.collide.example" ] ||
    fail "R2: the refused site left its webroot behind"
grep -Fq 'already served by another Caddy site' "${TEST_DIR}/r2_hosts/out" ||
    fail "R2: the host collision was not reported: $(cat "${TEST_DIR}/r2_hosts/out")"
echo "PASS: add refuses a host an existing site's www redirect already claims"

# The reverse order: a www host added first, then its apex, which serves
# that same www host.
create_fixture r2_reverse
rev_script="${TEST_DIR}/r2_reverse/docker/multi-site/site-manager.sh"
rev_webroot="${TEST_DIR}/r2_reverse/webroots"
rev_caddy="${TEST_DIR}/r2_reverse/docker/multi-site/caddy/sites"
KVS_WEBROOT_BASE="$rev_webroot" bash "$rev_script" add www.flip.example >/dev/null
[ -f "${rev_caddy}/www.flip.example.caddy" ] || fail "R2: www.flip.example was not created"
set +e
KVS_WEBROOT_BASE="$rev_webroot" \
    bash "$rev_script" add flip.example > "${TEST_DIR}/r2_reverse/out" 2>&1
rev_status=$?
set -e
[ "$rev_status" -ne 0 ] ||
    fail "R2: the apex flip.example claimed the www host of an existing site"
[ ! -e "${rev_caddy}/flip.example.caddy" ] ||
    fail "R2: the ambiguous apex route was written"
echo "PASS: add refuses an apex whose www host an existing site already serves"

# A genuinely distinct site is still accepted.
KVS_WEBROOT_BASE="$r2_webroot" bash "$r2_script" add distinct.example >/dev/null
[ -f "${r2_caddy}/distinct.example.caddy" ] ||
    fail "R2: a non-colliding site was refused"
echo "PASS: a non-colliding site is still added"

# remove can keep a site's webroot. A later add of that domain that is refused
# (here because www.keep.example took its www host meanwhile, or because of an
# invalid CADDY_TLS_MODE) must leave that webroot and its files alone: the
# refusal comes before anything is created.
create_fixture r2_keep
keep_script="${TEST_DIR}/r2_keep/docker/multi-site/site-manager.sh"
keep_webroot="${TEST_DIR}/r2_keep/webroots"
KVS_WEBROOT_BASE="$keep_webroot" bash "$keep_script" add keep.example >/dev/null
mkdir -p "${keep_webroot}/keep.example/contents/videos"
printf 'video\n' > "${keep_webroot}/keep.example/contents/videos/1.mp4"
printf 'yes\nn\n' | MOCK_CADDY_RUNNING=false KVS_WEBROOT_BASE="$keep_webroot" \
    bash "$keep_script" remove keep.example >/dev/null
[ -f "${keep_webroot}/keep.example/contents/videos/1.mp4" ] ||
    fail "R2: remove did not keep the webroot it was told to keep"
set +e
KVS_WEBROOT_BASE="$keep_webroot" CADDY_TLS_MODE=bogus \
    bash "$keep_script" add keep.example > "${TEST_DIR}/r2_keep/out" 2>&1
keep_status=$?
set -e
[ "$keep_status" -ne 0 ] || fail "R2: add accepted an invalid CADDY_TLS_MODE"
[ -f "${keep_webroot}/keep.example/contents/videos/1.mp4" ] ||
    fail "R2: a refused add (invalid TLS mode) deleted a webroot that predates it"
KVS_WEBROOT_BASE="$keep_webroot" bash "$keep_script" add www.keep.example >/dev/null
set +e
KVS_WEBROOT_BASE="$keep_webroot" \
    bash "$keep_script" add keep.example > "${TEST_DIR}/r2_keep/out" 2>&1
keep_status=$?
set -e
[ "$keep_status" -ne 0 ] ||
    fail "R2: keep.example claimed the host of www.keep.example"
[ -f "${keep_webroot}/keep.example/contents/videos/1.mp4" ] ||
    fail "R2: a refused add deleted a webroot that predates it"
[ ! -e "${TEST_DIR}/r2_keep/docker/multi-site/sites/keep.example" ] ||
    fail "R2: the refused add left its site directory behind"
echo "PASS: a refused add keeps a webroot that predates it"

# A route that cannot be written is a failure, not a created site.
if [ "$(id -u)" -ne 0 ]; then
    create_fixture r2_write
    write_script="${TEST_DIR}/r2_write/docker/multi-site/site-manager.sh"
    write_caddy="${TEST_DIR}/r2_write/docker/multi-site/caddy/sites"
    mkdir -p "$write_caddy"
    chmod 555 "$write_caddy"
    set +e
    KVS_WEBROOT_BASE="${TEST_DIR}/r2_write/webroots" \
        bash "$write_script" add y.example > "${TEST_DIR}/r2_write/out" 2>&1
    write_status=$?
    set -e
    chmod 755 "$write_caddy"
    [ "$write_status" -ne 0 ] ||
        fail "R2: add reported success although the Caddy route could not be written"
    ! grep -Fq 'created successfully' "${TEST_DIR}/r2_write/out" ||
        fail "R2: a failed route write was reported as a created site"
    [ ! -e "${TEST_DIR}/r2_write/docker/multi-site/sites/y.example" ] ||
        fail "R2: the failed add left its site directory behind"
    [ ! -e "${TEST_DIR}/r2_write/webroots/y.example" ] ||
        fail "R2: the failed add left the webroot it created behind"
    # The same failure over a webroot that predates the add keeps it.
    mkdir -p "${TEST_DIR}/r2_write/webroots/z.example/contents"
    printf 'video\n' > "${TEST_DIR}/r2_write/webroots/z.example/contents/1.mp4"
    chmod 555 "$write_caddy"
    set +e
    KVS_WEBROOT_BASE="${TEST_DIR}/r2_write/webroots" \
        bash "$write_script" add z.example > "${TEST_DIR}/r2_write/out" 2>&1
    write_status=$?
    set -e
    chmod 755 "$write_caddy"
    [ "$write_status" -ne 0 ] ||
        fail "R2: add reported success although the Caddy route could not be written (z.example)"
    [ -f "${TEST_DIR}/r2_write/webroots/z.example/contents/1.mp4" ] ||
        fail "R2: a failed add deleted a webroot that predates it"
    echo "PASS: a route that cannot be written fails the add"
fi

# Hand-written routes in caddy/sites may list several addresses in one block,
# with a scheme, a port or capitals. Every one of them is a claimed host.
create_fixture r2_multi
multi_script="${TEST_DIR}/r2_multi/docker/multi-site/site-manager.sh"
multi_caddy="${TEST_DIR}/r2_multi/docker/multi-site/caddy/sites"
mkdir -p "$multi_caddy"
cat > "${multi_caddy}/hand.caddy" <<'CADDY'
# Hand-written route
b.example, www.b.example {
    respond "b"
}

https://C.example:443 {
    respond "c"
}
CADDY
for multi_host in www.b.example c.example; do
    set +e
    KVS_WEBROOT_BASE="${TEST_DIR}/r2_multi/webroots" \
        bash "$multi_script" add "$multi_host" > "${TEST_DIR}/r2_multi/out" 2>&1
    multi_status=$?
    set -e
    [ "$multi_status" -ne 0 ] ||
        fail "R2: add claimed ${multi_host}, already listed in a hand-written route"
    [ ! -e "${multi_caddy}/${multi_host}.caddy" ] ||
        fail "R2: the ambiguous ${multi_host} route was written"
done
echo "PASS: add refuses every address of a hand-written multi-address route"

# R5: remove used to hide a failed 'docker compose down -v' and delete the site
# directory and its route anyway. The volumes stayed with no configuration left
# to manage them, and add refuses the domain while its project owns volumes.
# The fixture's project is kvs-r5-example, the one add gives r5.example.
r5_site_fixture() {
    local name=$1
    create_fixture "$name"
    r5_root="${TEST_DIR}/${name}/docker/multi-site"
    r5_site="${r5_root}/sites/r5.example"
    r5_route="${r5_root}/caddy/sites/r5.example.caddy"
    r5_log="${TEST_DIR}/${name}/docker.log"
    r5_webroot="${TEST_DIR}/${name}/webroots"
    mkdir -p "$r5_site" "${r5_root}/caddy/sites"
    printf 'DOMAIN=r5.example\nSITE_PREFIX=kvs-r5-example\nCOMPOSE_PROJECT_NAME=kvs-r5-example\n' > "$r5_site/.env"
    : > "$r5_site/docker-compose.yml"
    printf 'r5.example {\n    reverse_proxy n.r5.example:80\n}\n' > "$r5_route"
    : > "$r5_log"
}
r5_remove() {
    local name=$1
    shift
    set +e
    printf 'yes\nn\n' | env "$@" MOCK_DOCKER_LOG="$r5_log" KVS_WEBROOT_BASE="$r5_webroot" \
        bash "${r5_root}/site-manager.sh" remove r5.example > "${TEST_DIR}/${name}/out" 2>&1
    r5_status=$?
    set -e
}

# A failed down -v stops the removal and keeps the site directory and route.
r5_site_fixture r5_down
r5_remove r5_down MOCK_COMPOSE_DOWN_STATUS=1
[ "$r5_status" -ne 0 ] || fail "R5: remove reported success although 'docker compose down -v' failed"
[ -f "$r5_site/.env" ] || fail "R5: remove deleted the site directory after a failed 'down -v'"
[ -f "$r5_route" ] || fail "R5: remove deleted the Caddy route after a failed 'down -v'"
! grep -Fq 'removed completely' "${TEST_DIR}/r5_down/out" ||
    fail "R5: a failed 'down -v' was reported as a complete removal"

# Volumes of the project still there after down -v: the removal stops too.
r5_site_fixture r5_left
r5_remove r5_left MOCK_PROJECT_VOLUMES='kvs-r5-example_mariadb-data'
[ "$r5_status" -ne 0 ] || fail "R5: remove reported success with the project's volumes still present"
[ -f "$r5_site/.env" ] || fail "R5: remove deleted the site directory while its volumes remain"
[ -f "$r5_route" ] || fail "R5: remove deleted the Caddy route while the site's volumes remain"
grep -Fq 'kvs-r5-example_mariadb-data' "${TEST_DIR}/r5_left/out" ||
    fail "R5: the leftover volume was not named: $(cat "${TEST_DIR}/r5_left/out")"

# Those volumes, once the site directory and route are gone as an older remove
# left them, stop a new add of the domain; another project's volume does not.
rm -rf "$r5_site" "$r5_route"
r5_add() {
    set +e
    env "$@" KVS_WEBROOT_BASE="$r5_webroot" \
        bash "${r5_root}/site-manager.sh" add r5.example > "${TEST_DIR}/r5_left/add.out" 2>&1
    r5_status=$?
    set -e
}
r5_add MOCK_PROJECT_VOLUMES='kvs-r5-example_mariadb-data'
[ "$r5_status" -ne 0 ] || fail "R5: add reused the volumes a failed remove left behind"
grep -Fq 'A Docker Compose project named kvs-r5-example already exists' "${TEST_DIR}/r5_left/add.out" ||
    fail "R5: add did not name the project that owns the volumes: $(cat "${TEST_DIR}/r5_left/add.out")"
[ ! -e "$r5_site" ] || fail "R5: the refused add created the site directory"
r5_add MOCK_PROJECT_VOLUMES='kvs-r5-other_mariadb-data'
[ "$r5_status" -eq 0 ] ||
    fail "R5: add refused r5.example over another project's volume: $(cat "${TEST_DIR}/r5_left/add.out")"

# A volume listing that fails after down -v stops the removal as well: it
# cannot show that nothing was left behind.
r5_site_fixture r5_vols_fail
r5_remove r5_vols_fail MOCK_VOLUME_LS_STATUS=1
[ "$r5_status" -ne 0 ] || fail "R5: remove reported success although the volumes could not be listed"
[ -f "$r5_site/.env" ] || fail "R5: remove deleted the site directory without listing its volumes"
[ -f "$r5_route" ] || fail "R5: remove deleted the Caddy route without listing the site's volumes"
grep -Fq 'Could not list the volumes of kvs-r5-example' "${TEST_DIR}/r5_vols_fail/out" ||
    fail "R5: the failed volume listing was not reported: $(cat "${TEST_DIR}/r5_vols_fail/out")"

# Another project's volume is no leftover of this site: remove completes.
r5_site_fixture r5_other
r5_remove r5_other MOCK_PROJECT_VOLUMES='kvs-r5-other_mariadb-data'
[ "$r5_status" -eq 0 ] ||
    fail "R5: remove took another project's volume for a leftover: $(cat "${TEST_DIR}/r5_other/out")"
[ ! -e "$r5_site" ] || fail "R5: remove kept the site directory over another project's volume"

# A removal that works ends with the Caddy reload even when its input ends at
# the webroot prompt (EOF answers no): read used to stop the script under
# set -e there, after the route was gone but before Caddy was told. down -v
# names the site's project.
r5_site_fixture r5_eof
mkdir -p "${r5_webroot}/r5.example/contents"
printf 'video\n' > "${r5_webroot}/r5.example/contents/1.mp4"
set +e
printf 'yes\n' | MOCK_DOCKER_LOG="$r5_log" KVS_WEBROOT_BASE="$r5_webroot" \
    bash "${r5_root}/site-manager.sh" remove r5.example > "${TEST_DIR}/r5_eof/out" 2>&1
r5_status=$?
set -e
[ "$r5_status" -eq 0 ] ||
    fail "R5: remove stopped at the webroot prompt on EOF: $(cat "${TEST_DIR}/r5_eof/out")"
[ ! -e "$r5_site" ] || fail "R5: a working remove kept the site directory"
[ ! -e "$r5_route" ] || fail "R5: a working remove kept the Caddy route"
[ -f "${r5_webroot}/r5.example/contents/1.mp4" ] || fail "R5: EOF at the webroot prompt removed the webroot"
grep -Fxq "compose -p kvs-r5-example down -v --remove-orphans" "$r5_log" ||
    fail "R5: down -v did not name the site's project: $(cat "$r5_log")"
grep -q '^exec kvs-caddy caddy reload' "$r5_log" ||
    fail "R5: Caddy was not reloaded after the removal: $(cat "$r5_log")"

# down -v loads the files start and stop load, in the site directory: its
# docker-compose.yml and the override Compose picks next to it. With -f
# docker-compose.yml alone, a service and a volume only in the override
# would outlive "removed completely". The real Compose renders what down -v and
# a plain 'docker compose' (start, stop) load, for two of the override names
# Compose looks for.
for r5_override in docker-compose.override.yml compose.override.yaml; do
    r5_case="r5_override_${r5_override%%.*}"
    create_fixture "$r5_case"
    r5_root="${TEST_DIR}/${r5_case}/docker/multi-site"
    r5_site="${r5_root}/sites/r5.example"
    r5_webroot="${TEST_DIR}/${r5_case}/webroots"
    KVS_WEBROOT_BASE="$r5_webroot" bash "${r5_root}/site-manager.sh" add r5.example >/dev/null
    printf 'services:\n  backup:\n    image: busybox\n    volumes:\n      - backup-data:/data\nvolumes:\n  backup-data:\n' \
        > "${r5_site}/${r5_override}"
    r5_services=$(cd "$r5_site" && "$REAL_DOCKER" compose config --services | sort)
    r5_volumes=$(cd "$r5_site" && "$REAL_DOCKER" compose config --volumes | sort)
    { grep -Fxq backup <<< "$r5_services" && grep -Fxq backup-data <<< "$r5_volumes"; } ||
        fail "R5: the real Compose did not load ${r5_override}: ${r5_services}"
    set +e
    printf 'yes\nn\n' | MOCK_COMPOSE_RENDER="${TEST_DIR}/${r5_case}/render" \
        KVS_WEBROOT_BASE="$r5_webroot" \
        bash "${r5_root}/site-manager.sh" remove r5.example > "${TEST_DIR}/${r5_case}/out" 2>&1
    r5_status=$?
    set -e
    [ "$r5_status" -eq 0 ] || fail "R5: remove with ${r5_override} failed: $(cat "${TEST_DIR}/${r5_case}/out")"
    [ "$(sort "${TEST_DIR}/${r5_case}/render.services")" = "$r5_services" ] ||
        fail "R5: down -v did not load the services start loads with ${r5_override}: $(cat "${TEST_DIR}/${r5_case}/render.services")"
    [ "$(sort "${TEST_DIR}/${r5_case}/render.volumes")" = "$r5_volumes" ] ||
        fail "R5: down -v did not load the volumes start loads with ${r5_override}: $(cat "${TEST_DIR}/${r5_case}/render.volumes")"
done

# An add that stops early leaves sites/<domain> without docker-compose.yml,
# and without an .env when it stopped at the webroot. remove asked for a
# project name, down -v had no compose file and add said the site exists.
# remove now finds that nothing of the site runs and deletes the empty
# directory, and add works again. The webroot base sits under a regular file,
# which mkdir cannot create even as root.
create_fixture r5_half
r5_root="${TEST_DIR}/r5_half/docker/multi-site"
r5_site="${r5_root}/sites/r5.example"
r5_log="${TEST_DIR}/r5_half/docker.log"
: > "${TEST_DIR}/r5_half/file"
for r5_attempt in 1 2; do
    set +e
    KVS_WEBROOT_BASE="${TEST_DIR}/r5_half/file/www" \
        bash "${r5_root}/site-manager.sh" add r5.example > "${TEST_DIR}/r5_half/add${r5_attempt}.out" 2>&1
    r5_status=$?
    set -e
    [ "$r5_status" -ne 0 ] || fail "R5: add worked with a webroot it cannot create"
done
[ -d "$r5_site" ] && [ -z "$(ls -A "$r5_site")" ] ||
    fail "R5: the add that stopped did not leave the empty site directory this case needs"
grep -Fq "Run './site-manager.sh remove r5.example'" "${TEST_DIR}/r5_half/add2.out" ||
    fail "R5: add of a half-created site did not point to remove: $(cat "${TEST_DIR}/r5_half/add2.out")"
: > "$r5_log"
set +e
MOCK_DOCKER_LOG="$r5_log" KVS_WEBROOT_BASE="${TEST_DIR}/r5_half/webroots" \
    bash "${r5_root}/site-manager.sh" remove r5.example < /dev/null > "${TEST_DIR}/r5_half/out" 2>&1
r5_status=$?
set -e
[ "$r5_status" -eq 0 ] || fail "R5: remove of a half-created site failed: $(cat "${TEST_DIR}/r5_half/out")"
grep -Fq 'Nothing of r5.example runs' "${TEST_DIR}/r5_half/out" ||
    fail "R5: remove did not say that nothing of the half-created site runs: $(cat "${TEST_DIR}/r5_half/out")"
[ ! -e "$r5_site" ] || fail "R5: remove kept the empty directory of a half-created site"
! grep -q '^compose' "$r5_log" || fail "R5: remove ran Compose without the site's docker-compose.yml: $(cat "$r5_log")"
KVS_WEBROOT_BASE="${TEST_DIR}/r5_half/webroots" \
    bash "${r5_root}/site-manager.sh" add r5.example > "${TEST_DIR}/r5_half/add3.out" 2>&1 ||
    fail "R5: add still refused the domain after remove: $(cat "${TEST_DIR}/r5_half/add3.out")"

# A directory with files left, here an .env naming no project with the
# primary's docker-compose.yml in the parent directory, is not deleted:
# remove prints the command that deletes it, and runs no Compose there,
# which would have taken the primary's file and project.
r5_site_fixture r5_files_left
printf 'DOMAIN=r5.example\n' > "$r5_site/.env"
rm -f "$r5_site/docker-compose.yml"
printf 'services:\n  mariadb:\n    image: mariadb\n' > "${TEST_DIR}/r5_files_left/docker/docker-compose.yml"
printf 'COMPOSE_PROJECT_NAME=kvs-primary\n' > "${TEST_DIR}/r5_files_left/docker/.env"  # pragma: allowlist secret
r5_remove r5_files_left
[ "$r5_status" -ne 0 ] || fail "R5: remove reported success for a site directory it kept"
! grep -q '^compose' "$r5_log" || fail "R5: remove ran Compose without the site's docker-compose.yml: $(cat "$r5_log")"
[ -f "$r5_site/.env" ] || fail "R5: remove deleted a site directory that still holds files"
r5_command=$(sed -n 's/^  \(rm -r -- .*\)$/\1/p' "${TEST_DIR}/r5_files_left/out")
[ -n "$r5_command" ] || fail "R5: remove printed no command to delete the directory: $(cat "${TEST_DIR}/r5_files_left/out")"
eval "$r5_command"
[ ! -e "$r5_site" ] && [ -d "${r5_root}/sites" ] ||
    fail "R5: the printed command '${r5_command}' did not delete exactly the site directory"

# Without docker-compose.yml, what Docker still holds of the site keeps the
# directory: volumes of the project its .env names, volumes of the project
# its directory name gives, containers created from it, or a container
# listing that fails. remove says to put docker-compose.yml back.
r5_held() {
    local name=$1
    shift
    r5_site_fixture "$name"
    rm -f "$r5_site/docker-compose.yml"
    : > "${TEST_DIR}/${name}/containers"
    r5_remove "$name" MOCK_CONTAINER_STATE="${TEST_DIR}/${name}/containers" "$@"
    [ "$r5_status" -ne 0 ] || fail "R5: ${name}: remove reported success with the site's resources left"
    [ -f "$r5_site/.env" ] && [ -f "$r5_route" ] || fail "R5: ${name}: remove deleted the site's files"
    ! grep -q '^compose' "$r5_log" || fail "R5: ${name}: remove ran Compose without docker-compose.yml"
}
r5_held r5_held_env MOCK_PROJECT_VOLUMES='kvs-r5-example_mariadb-data'
{ grep -Fq 'volumes of kvs-r5-example: kvs-r5-example_mariadb-data' "${TEST_DIR}/r5_held_env/out" &&
    grep -Fq "docker-compose.site.yml.template ${r5_site}/docker-compose.yml" "${TEST_DIR}/r5_held_env/out"; } ||
    fail "R5: the volumes held without docker-compose.yml were not named: $(cat "${TEST_DIR}/r5_held_env/out")"
r5_held r5_held_dir MOCK_PROJECT_VOLUMES='r5example_mariadb-data'
grep -Fq 'volumes of r5example: r5example_mariadb-data' "${TEST_DIR}/r5_held_dir/out" ||
    fail "R5: the volumes of the directory's project were not named: $(cat "${TEST_DIR}/r5_held_dir/out")"
r5_site_fixture r5_held_containers
rm -f "$r5_site/docker-compose.yml"
printf 'kvs-r5-example\t%s\n' "$r5_site" > "${TEST_DIR}/r5_held_containers/containers"
r5_remove r5_held_containers MOCK_CONTAINER_STATE="${TEST_DIR}/r5_held_containers/containers"
{ [ "$r5_status" -ne 0 ] && [ -f "$r5_site/.env" ] &&
    grep -Fq 'containers of kvs-r5-example' "${TEST_DIR}/r5_held_containers/out"; } ||
    fail "R5: containers created from a site without docker-compose.yml did not stop remove: $(cat "${TEST_DIR}/r5_held_containers/out")"
# Even an empty directory stays when the containers or the volumes cannot
# be listed.
for r5_listing in ps volume; do
    r5_site_fixture "r5_held_${r5_listing}"
    rm -f "$r5_site/.env" "$r5_site/docker-compose.yml"
    if [ "$r5_listing" = ps ]; then
        r5_remove "r5_held_${r5_listing}" MOCK_PS_STATUS=1
        r5_message='Could not list the containers created from'
    else
        r5_remove "r5_held_${r5_listing}" MOCK_VOLUME_LS_STATUS=1
        r5_message='Could not list the volumes of r5example'
    fi
    { [ "$r5_status" -ne 0 ] && [ -d "$r5_site" ] &&
        grep -Fq "$r5_message" "${TEST_DIR}/r5_held_${r5_listing}/out"; } ||
        fail "R5: a failed ${r5_listing} listing did not stop remove: $(cat "${TEST_DIR}/r5_held_${r5_listing}/out")"
done
echo "PASS: remove stops on a failed or incomplete 'down -v', loads the site's override and clears a half-created site"

# A site added before add wrote COMPOSE_PROJECT_NAME has only SITE_PREFIX in
# its .env, and start, a plain 'docker compose' in its directory, runs it
# under the project Compose derives from the directory name. remove took
# SITE_PREFIX: its down -v found nothing and succeeded, the working directory
# and leftover checks asked about the wrong project, and the site's
# containers and volumes outlived "removed completely". The real Compose
# gives the name the cases expect.
r5_legacy() {
    local name=$1
    create_fixture "$name"
    r5_root="${TEST_DIR}/${name}/docker/multi-site"
    r5_site="${r5_root}/sites/legacy-site.example"
    r5_webroot="${TEST_DIR}/${name}/webroots"
    r5_log="${TEST_DIR}/${name}/docker.log"
    r5_containers="${TEST_DIR}/${name}/containers"
    r5_volumes="${TEST_DIR}/${name}/volumes"
    KVS_WEBROOT_BASE="$r5_webroot" bash "${r5_root}/site-manager.sh" add legacy-site.example >/dev/null
    sed -i '/^COMPOSE_PROJECT_NAME=/d' "$r5_site/.env"
    : > "$r5_log"
    : > "$r5_containers"
    : > "$r5_volumes"
}
r5_legacy_remove() {
    local name=$1
    shift
    set +e
    printf 'yes\nn\n' | env MOCK_CONTAINER_STATE="$r5_containers" MOCK_VOLUME_STATE="$r5_volumes" \
        "$@" MOCK_DOCKER_LOG="$r5_log" KVS_WEBROOT_BASE="$r5_webroot" \
        bash "${r5_root}/site-manager.sh" remove legacy-site.example > "${TEST_DIR}/${name}/out" 2>&1
    r5_status=$?
    set -e
}
r5_legacy_refused() {
    [ "$r5_status" -ne 0 ] || fail "R5: $2: remove was accepted"
    grep -Fq "$1" "${TEST_DIR}/$3/out" || fail "R5: $2: the refusal was not explained: $(cat "${TEST_DIR}/$3/out")"
    ! grep -q 'compose.* down -v' "$r5_log" || fail "R5: $2: remove ran down -v: $(cat "$r5_log")"
    [ -f "$r5_site/.env" ] || fail "R5: $2: remove deleted the site directory"
}

r5_legacy r5_legacy_containers
r5_legacy_project=$(cd "$r5_site" && "$REAL_DOCKER" compose config --format json | jq -r .name)
[ "$r5_legacy_project" = legacy-siteexample ] ||
    fail "R5: the real Compose names the legacy site ${r5_legacy_project}, not legacy-siteexample"
r5_legacy_prefix=$(sed -n 's/^SITE_PREFIX=//p' "$r5_site/.env")
ln -s "$r5_site" "${TEST_DIR}/r5_legacy_containers/site-link"
printf '%s\t%s\n' "$r5_legacy_project" "$r5_site" "$r5_legacy_project" \
    "${TEST_DIR}/r5_legacy_containers/site-link" other "${TEST_DIR}/r5_legacy_containers" > "$r5_containers"
printf '%s\n' "${r5_legacy_project}_mariadb-data" "${r5_legacy_project}_nginx-logs" \
    other_mariadb-data > "$r5_volumes"
r5_legacy_remove r5_legacy_containers
[ "$r5_status" -eq 0 ] || fail "R5: remove of a legacy site failed: $(cat "${TEST_DIR}/r5_legacy_containers/out")"
grep -Fxq "compose -p ${r5_legacy_project} down -v --remove-orphans" "$r5_log" ||
    fail "R5: remove did not take the legacy site down as ${r5_legacy_project}: $(cat "$r5_log")"
[ "$(cut -f1 "$r5_containers")" = other ] && [ "$(cat "$r5_volumes")" = other_mariadb-data ] ||
    fail "R5: the legacy site's containers or volumes outlived its removal: $(cat "$r5_containers" "$r5_volumes")"
[ ! -e "$r5_site" ] || fail "R5: remove kept the legacy site's directory"

# The containers decide, compared through the directory they resolve to:
# a site started with COMPOSE_PROJECT_NAME exported in the shell, through a
# symlinked path, runs under that name and no other.
r5_legacy r5_legacy_custom
ln -s "$r5_site" "${TEST_DIR}/r5_legacy_custom/site-link"
printf 'custom\t%s\n' "${TEST_DIR}/r5_legacy_custom/site-link" > "$r5_containers"
printf '%s\n' custom_mariadb-data > "$r5_volumes"
r5_legacy_remove r5_legacy_custom
{ [ "$r5_status" -eq 0 ] && [ ! -s "$r5_volumes" ] && [ ! -s "$r5_containers" ] &&
    grep -Fxq "compose -p custom down -v --remove-orphans" "$r5_log"; } ||
    fail "R5: the project of a legacy site's containers was not used: $(cat "${TEST_DIR}/r5_legacy_custom/out" "$r5_log")"

# With its containers gone (stopped by 'docker compose down'), the volumes
# tell the project: those of the directory's project, or of SITE_PREFIX.
r5_legacy r5_legacy_volumes
printf '%s\n' "${r5_legacy_project}_mariadb-data" > "$r5_volumes"
r5_legacy_remove r5_legacy_volumes
{ [ "$r5_status" -eq 0 ] && [ ! -s "$r5_volumes" ] &&
    grep -Fxq "compose -p ${r5_legacy_project} down -v --remove-orphans" "$r5_log"; } ||
    fail "R5: a legacy site's volumes did not give its project: $(cat "${TEST_DIR}/r5_legacy_volumes/out" "$r5_log")"
r5_legacy r5_legacy_prefix_volumes
printf '%s\n' "${r5_legacy_prefix}_mariadb-data" > "$r5_volumes"
r5_legacy_remove r5_legacy_prefix_volumes
[ "$r5_status" -eq 0 ] && [ ! -s "$r5_volumes" ] ||
    fail "R5: the volumes of a legacy site's SITE_PREFIX were left: $(cat "${TEST_DIR}/r5_legacy_prefix_volumes/out" "$r5_log")"

# Nothing left anywhere: down -v runs as the project start would use.
r5_legacy r5_legacy_nothing
r5_legacy_remove r5_legacy_nothing
{ [ "$r5_status" -eq 0 ] &&
    grep -Fxq "compose -p ${r5_legacy_project} down -v --remove-orphans" "$r5_log"; } ||
    fail "R5: a legacy site with nothing left was not taken down as ${r5_legacy_project}: $(cat "${TEST_DIR}/r5_legacy_nothing/out" "$r5_log")"

# Two projects claim the site, through containers or through volumes: remove
# cannot tell which one is the site's and stops.
r5_legacy r5_legacy_two_containers
printf '%s\t%s\n' "$r5_legacy_project" "$r5_site" second "$r5_site" > "$r5_containers"
r5_legacy_remove r5_legacy_two_containers
r5_legacy_refused 'Containers of several Compose projects were created from' "two projects' containers" \
    r5_legacy_two_containers
r5_legacy r5_legacy_two_volumes
printf '%s\n' "${r5_legacy_prefix}_mariadb-data" "${r5_legacy_project}_mariadb-data" > "$r5_volumes"
r5_legacy_remove r5_legacy_two_volumes
r5_legacy_refused "both ${r5_legacy_prefix} and ${r5_legacy_project} hold volumes" "two projects' volumes" \
    r5_legacy_two_volumes

# The checks that protect the primary apply to the project found: a legacy
# site whose SITE_PREFIX is the primary's project, the primary stopped with
# only its volumes left, and the project of the site's containers when they
# were also created from another directory.
r5_legacy r5_legacy_primary
printf 'COMPOSE_PROJECT_NAME=%s\n' "$r5_legacy_prefix" > "${TEST_DIR}/r5_legacy_primary/docker/.env"  # pragma: allowlist secret
printf '%s\n' "${r5_legacy_prefix}_mariadb-data" > "$r5_volumes"
r5_legacy_remove r5_legacy_primary
r5_legacy_refused 'the primary site uses that project name' "a SITE_PREFIX the primary uses" r5_legacy_primary
r5_legacy r5_legacy_foreign
printf '%s\t%s\n' "$r5_legacy_project" "$r5_site" "$r5_legacy_project" "${TEST_DIR}/r5_legacy_foreign/docker" \
    > "$r5_containers"
r5_legacy_remove r5_legacy_foreign
r5_legacy_refused "it has containers from ${TEST_DIR}/r5_legacy_foreign/docker" "a project from another directory too" \
    r5_legacy_foreign
r5_legacy r5_legacy_ps
r5_legacy_remove r5_legacy_ps MOCK_PS_STATUS=1
r5_legacy_refused 'Could not list the containers created from' "a failed container listing" r5_legacy_ps
r5_legacy r5_legacy_volume_ls
r5_legacy_remove r5_legacy_volume_ls MOCK_VOLUME_LS_STATUS=1
r5_legacy_refused "Could not list the volumes of ${r5_legacy_prefix}" "a failed volume listing" r5_legacy_volume_ls
echo "PASS: remove finds the Compose project of a site whose .env names none"

echo "PASS: Multi-site manager hardening"
