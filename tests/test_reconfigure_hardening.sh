#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d /tmp/kvs-reconfigure-hardening.XXXXXX)
ASSERTIONS=0
LAST_DIR=''
LAST_STATUS=0

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$actual" = "$expected" ] ||
        fail "${message}: expected '${expected}', got '${actual}'"
}

assert_gt() {
    local minimum="$1"
    local actual="$2"
    local message="$3"

    ASSERTIONS=$((ASSERTIONS + 1))
    [[ "$actual" =~ ^[0-9]+$ ]] && [ "$actual" -gt "$minimum" ] ||
        fail "${message}: expected more than '${minimum}', got '${actual}'"
}

assert_success() {
    local message="$1"

    assert_eq 0 "$LAST_STATUS" "$message"
}

assert_failure() {
    local message="$1"

    ASSERTIONS=$((ASSERTIONS + 1))
    [ "$LAST_STATUS" -ne 0 ] || fail "${message}: command unexpectedly succeeded"
}

assert_contains() {
    local file="$1"
    local needle="$2"
    local message="$3"

    ASSERTIONS=$((ASSERTIONS + 1))
    grep -Fq -- "$needle" "$file" || fail "$message"
}

assert_not_contains() {
    local file="$1"
    local needle="$2"
    local message="$3"

    ASSERTIONS=$((ASSERTIONS + 1))
    if grep -Fq -- "$needle" "$file"; then
        fail "$message"
    fi
}

assert_count() {
    local expected="$1"
    local file="$2"
    local needle="$3"
    local message="$4"
    local actual

    actual=$(grep -Fc -- "$needle" "$file" || true)
    assert_eq "$expected" "$actual" "$message"
}

assert_before() {
    local file="$1"
    local first="$2"
    local second="$3"
    local message="$4"
    local first_line
    local second_line

    first_line=$(grep -nFm 1 -- "$first" "$file" | cut -d : -f 1 || true)
    second_line=$(grep -nFm 1 -- "$second" "$file" | cut -d : -f 1 || true)
    ASSERTIONS=$((ASSERTIONS + 1))
    [ -n "$first_line" ] && [ -n "$second_line" ] &&
        [ "$first_line" -lt "$second_line" ] || fail "$message"
}

file_snapshot() {
    local contents="$1"
    local digest
    local encoded

    digest=$(printf '%s' "$contents" | sha256sum)
    digest=${digest%% *}
    encoded=$(printf '%s' "$contents" | base64 -w 0)
    printf 'file|1000|1000|0600|%s|%s\n' "$digest" "$encoded"
}

database_snapshot() {
    local url="$1"
    local skip="$2"
    local encoded

    encoded=$(printf '%s' "$url" | base64 -w 0)
    printf '1|0|%s|0|%s\n' "$encoded" "$skip"
}

database_snapshot_url() {
    local snapshot_file="$1"
    local encoded

    encoded=$(cut -d '|' -f 3 "$snapshot_file")
    printf '%s' "$encoded" | base64 -d
}

fixture_env_value() {
    local fixture="$1"
    local key="$2"

    sed -n "s/^${key}=//p" "$fixture/.env" | tail -n 1
}

initialize_application_state() {
    local fixture="$1"
    local domain
    local mode
    local provider
    local use_www
    local https_endpoint
    local https_port
    local host
    local port_suffix=''
    local before_url
    local after_url
    local case_conflict_url
    local expected_skip=0

    domain=$(fixture_env_value "$fixture" DOMAIN)
    mode=$(fixture_env_value "$fixture" MODE)
    provider=$(fixture_env_value "$fixture" SSL_PROVIDER)
    use_www=$(fixture_env_value "$fixture" USE_WWW)
    https_endpoint=$(fixture_env_value "$fixture" HTTPS_PORT)
    https_port=${https_endpoint##*:}
    host="$domain"
    [ "$use_www" != true ] || host="www.${domain}"
    if [ "$mode" != multi ] && [ "$https_port" -ne 443 ]; then
        port_suffix=":${https_port}"
    fi
    [ "$provider" != selfsigned ] || expected_skip=1

    before_url="https://${domain}:9443/contents/"
    after_url="https://${host}${port_suffix}/contents/"
    case_conflict_url="${after_url%contents/}Contents/"
    database_snapshot "$before_url" 0 > "$fixture/state/db-before"
    database_snapshot "$after_url" "$expected_skip" > "$fixture/state/db-after"
    database_snapshot "https://concurrent.example/contents/" 9 > \
        "$fixture/state/db-conflict"
    database_snapshot "$case_conflict_url" "$expected_skip" > \
        "$fixture/state/db-case-conflict"
    cp "$fixture/state/db-before" "$fixture/state/db-current"
    cp "$fixture/state/db-before" "$fixture/state/db-expected-current"

    file_snapshot "setup-before:${domain}" > "$fixture/state/setup-before"
    file_snapshot "setup-after:https://${host}${port_suffix}" > \
        "$fixture/state/setup-after"
    file_snapshot "setup-concurrent:${domain}" > "$fixture/state/setup-conflict"
    cp "$fixture/state/setup-before" "$fixture/state/setup-current"

    file_snapshot "plugin-before:${domain}" > "$fixture/state/plugin-before"
    file_snapshot "plugin-after:https://${host}${port_suffix}" > \
        "$fixture/state/plugin-after"
    file_snapshot "plugin-concurrent:${domain}" > "$fixture/state/plugin-conflict"
    cp "$fixture/state/plugin-before" "$fixture/state/plugin-current"
}

initialize_long_database_state() {
    local fixture="$1"
    local rows="$2"
    local before_line
    local after_line
    local row
    local -a before
    local -a after

    before_line=$(<"$fixture/state/db-before")
    after_line=$(<"$fixture/state/db-after")
    IFS='|' read -r -a before <<< "$before_line"
    IFS='|' read -r -a after <<< "$after_line"
    : > "$fixture/state/db-before"
    : > "$fixture/state/db-after"
    for ((row = 1; row <= rows; row++)); do
        printf '%s|%s|%s|%s|%s\n' "$row" "${before[1]}" "${before[2]}" \
            "${before[3]}" "${before[4]}" >> "$fixture/state/db-before"
        printf '%s|%s|%s|%s|%s\n' "$row" "${after[1]}" "${after[2]}" \
            "${after[3]}" "${after[4]}" >> "$fixture/state/db-after"
    done
    cp "$fixture/state/db-before" "$fixture/state/db-current"
    cp "$fixture/state/db-before" "$fixture/state/db-expected-current"
}

set_env_value() {
    local fixture="$1"
    local key="$2"
    local value="$3"

    sed -i "/^${key}=/d" "$fixture/.env"
    printf '%s=%s\n' "$key" "$value" >> "$fixture/.env"
}

create_fixture() {
    local name="$1"
    local fixture="$TEST_ROOT/$name"

    mkdir -p "$fixture/bin" "$fixture/multi-site/sites" \
        "$fixture/multi-site/caddy/sites"
    cp "$ROOT_DIR/docker/reconfigure.sh" "$fixture/reconfigure.sh"
    chmod +x "$fixture/reconfigure.sh"
    : > "$fixture/docker-compose.yml"

    cat > "$fixture/.env" <<'EOF'
DOMAIN=7.0.2.maximemichaud.ca
EMAIL=admin@example.com
USE_WWW=false
SITE_PREFIX=kvs
SSL_PROVIDER=letsencrypt
MARIADB_PASSWORD=test-password
COMPOSE_PROFILES=dragonfly
COMPOSE_FILE=docker-compose.yml
HTTP_PORT=80
HTTPS_PORT=443
PROJECT_HTTPS_PORT=443
MODE=single
EOF

    cat > "$fixture/multi-site/site-manager.sh" <<'EOF'
#!/bin/bash
set -u
printf 'site-manager' >> "${MOCK_CALLS:?}"
printf ' %q' "$@" >> "$MOCK_CALLS"
printf '\n' >> "$MOCK_CALLS"

[ "${1:-}" = primary-config ] || exit 64
mkdir -p multi-site/caddy/sites multi-site/sites
printf 'domain=%s prefix=%s tls=%s www=%s\n' \
    "$2" "$3" "$4" "$5" > "multi-site/caddy/sites/${2}.caddy"
printf 'DOMAIN=%s\nSITE_PREFIX=%s\n' "$2" "$3" > multi-site/sites/.primary.env
exit "${MOCK_SITE_MANAGER_STATUS:-0}"
EOF
    chmod +x "$fixture/multi-site/site-manager.sh"

    cat > "$fixture/bin/docker" <<'EOF'
#!/bin/bash
set -u

log_call() {
    printf 'docker' >> "${MOCK_CALLS:?}"
    printf ' %q' "$@" >> "$MOCK_CALLS"
    printf '\n' >> "$MOCK_CALLS"
    printf 'docker-text %s\n' "$*" >> "$MOCK_CALLS"
}

next_status() {
    local values_name="$1"
    local counter_name="$2"
    local values="${!values_name:-0}"
    local counter_file="${MOCK_STATE:?}/${counter_name}"
    local count=0
    local index
    local -a statuses

    if [ -f "$counter_file" ]; then
        read -r count < "$counter_file" || count=0
    fi
    count=$((count + 1))
    NEXT_COUNT="$count"
    printf '%s\n' "$count" > "$counter_file"
    IFS=',' read -r -a statuses <<< "$values"
    index=$((count - 1))
    if [ "$index" -ge "${#statuses[@]}" ]; then
        index=$((${#statuses[@]} - 1))
    fi
    NEXT_STATUS="${statuses[$index]}"
}

print_names() {
    local name

    for name in $1; do
        printf '%s\n' "$name"
    done
}

set_expected_database_url() {
    local current_line
    local expected_line
    local temporary="${MOCK_STATE:?}/db-current.tmp"
    local -a current
    local -a expected

    : > "$temporary"
    while IFS=$'\t' read -r current_line expected_line; do
        IFS='|' read -r -a current <<< "$current_line"
        IFS='|' read -r -a expected <<< "$expected_line"
        [ "${current[0]}" = "${expected[0]}" ] || return 1
        printf '%s|%s|%s|%s|%s\n' "${current[0]}" "${expected[1]}" \
            "${expected[2]}" "${current[3]}" "${current[4]}" >> "$temporary"
    done < <(paste "$MOCK_STATE/db-current" "$MOCK_STATE/db-after")
    mv "$temporary" "$MOCK_STATE/db-current"
    cp "$MOCK_STATE/db-current" "$MOCK_STATE/db-expected-current"
}

set_expected_database_skip() {
    local current_line
    local expected_line
    local temporary="${MOCK_STATE:?}/db-current.tmp"
    local -a current
    local -a expected

    : > "$temporary"
    while IFS=$'\t' read -r current_line expected_line; do
        IFS='|' read -r -a current <<< "$current_line"
        IFS='|' read -r -a expected <<< "$expected_line"
        [ "${current[0]}" = "${expected[0]}" ] || return 1
        printf '%s|%s|%s|%s|%s\n' "${current[0]}" "${current[1]}" \
            "${current[2]}" "${expected[3]}" "${expected[4]}" >> "$temporary"
    done < <(paste "$MOCK_STATE/db-current" "$MOCK_STATE/db-after")
    mv "$temporary" "$MOCK_STATE/db-current"
    cp "$MOCK_STATE/db-current" "$MOCK_STATE/db-expected-current"
}

record_query_kind() {
    local kind="$1"
    local bytes="$2"
    local maximum=0

    printf 'mariadb-query %s bytes=%s\n' "$kind" "$bytes" >> "$MOCK_CALLS"
    if [ -f "$MOCK_STATE/max-query-bytes" ]; then
        read -r maximum < "$MOCK_STATE/max-query-bytes" || maximum=0
    fi
    if [ "$bytes" -gt "$maximum" ]; then
        printf '%s\n' "$bytes" > "$MOCK_STATE/max-query-bytes"
    fi
}

inject_concurrent_mutation() {
    case "${MOCK_CONCURRENT_MUTATION_TARGET:-}" in
        db) cp "$MOCK_STATE/db-conflict" "$MOCK_STATE/db-current" ;;
        setup) cp "$MOCK_STATE/setup-conflict" "$MOCK_STATE/setup-current" ;;
        plugin) cp "$MOCK_STATE/plugin-conflict" "$MOCK_STATE/plugin-current" ;;
        '') return 0 ;;
        *) exit 97 ;;
    esac
    printf 'concurrent-mutation %s\n' "$MOCK_CONCURRENT_MUTATION_TARGET" >> \
        "$MOCK_CALLS"
}

log_call "$@"
joined=" $* "

case "${1:-}" in
    ps)
        if [[ "$joined" == *' -a '* ]]; then
            if [ "${MOCK_PS_ALL_STATUS:-0}" -ne 0 ]; then
                exit "$MOCK_PS_ALL_STATUS"
            fi
            print_names "${MOCK_ALL_NAMES:-}"
            if [ -f "${MOCK_STATE:?}/acme-present" ]; then
                printf '%s\n' kvs-acme
            fi
        else
            print_names "${MOCK_RUNNING_NAMES:-kvs-php}"
            exit "${MOCK_PS_STATUS:-0}"
        fi
        exit 0
        ;;
    stop)
        exit "${MOCK_STOP_STATUS:-0}"
        ;;
    rm)
        if [ "${MOCK_RM_STATUS:-0}" -eq 0 ]; then
            rm -f "${MOCK_STATE:?}/acme-present"
        fi
        exit "${MOCK_RM_STATUS:-0}"
        ;;
    compose)
        if [[ "$joined" == *' --no-deps '* ]]; then
            exit "${MOCK_RUNTIME_STATUS:-0}"
        fi
        exit "${MOCK_COMPOSE_STATUS:-0}"
        ;;
    exec)
        if [[ "$joined" == *' kvs-caddy caddy validate '* ]]; then
            next_status MOCK_CADDY_VALIDATE_RESULTS caddy-validate-count
            printf 'caddy-validate count=%s status=%s\n' \
                "$NEXT_COUNT" "$NEXT_STATUS" >> "$MOCK_CALLS"
            if [ "$NEXT_COUNT" -eq 2 ] &&
                [ "${MOCK_CADDY_VALIDATE_SIGNAL:-}" = TERM ]; then
                printf 'caddy-validate signal=TERM\n' >> "$MOCK_CALLS"
                kill -TERM "$PPID"
                exit 143
            fi
            if [ "$NEXT_COUNT" -eq 2 ] && [ "$NEXT_STATUS" -ne 0 ]; then
                inject_concurrent_mutation
            fi
            exit "$NEXT_STATUS"
        fi
        if [[ "$joined" == *' kvs-caddy caddy reload '* ]]; then
            next_status MOCK_CADDY_RELOAD_RESULTS caddy-reload-count
            printf 'caddy-reload count=%s status=%s\n' \
                "$NEXT_COUNT" "$NEXT_STATUS" >> "$MOCK_CALLS"
            if [[ "$joined" != *' caddy reload --force --config '* ]]; then
                printf 'caddy-reload force=false\n' >> "$MOCK_CALLS"
                exit 85
            fi
            printf 'caddy-reload force=true\n' >> "$MOCK_CALLS"
            exit "$NEXT_STATUS"
        fi
        if [[ "$joined" == *' KVS_ACME_DOMAIN='*' kvs-acme sh -c '* ]]; then
            if [ -f "${MOCK_STATE:?}/acme-api" ]; then
                cat "$MOCK_STATE/acme-api"
            else
                printf '%s\n' __KVS_ABSENT__
            fi
            exit "${MOCK_ACME_INSPECT_STATUS:-0}"
        fi
        if [[ "$joined" == *' kvs-acme acme.sh --issue '* ]]; then
            printf '%s\n' "${MOCK_ISSUE_OUTPUT:-Certificate issued}"
            if { [ "${MOCK_ISSUE_STATUS:-0}" -eq 0 ] ||
                [ "${MOCK_MUTATE_ACME_API_ON_FAILURE:-false}" = true ]; } &&
                [ "${MOCK_PERSIST_ACME_API:-true}" = true ]; then
                if [[ "$joined" == *' --server zerossl '* ]]; then
                    printf '%s\n' 'https://acme.zerossl.com/v2/DV90' > \
                        "${MOCK_STATE:?}/acme-api"
                else
                    printf '%s\n' 'https://acme-v02.api.letsencrypt.org/directory' > \
                        "${MOCK_STATE:?}/acme-api"
                fi
            fi
            exit "${MOCK_ISSUE_STATUS:-0}"
        fi
        if [[ "$joined" == *' kvs-acme acme.sh --install-cert '* ]]; then
            exit "${MOCK_INSTALL_STATUS:-0}"
        fi
        if [[ "$joined" == *' KVS_CERT_PROVIDER='*' kvs-nginx sh -c '* ]]; then
            next_status MOCK_CERT_RESULTS certificate-check-count
            exit "$NEXT_STATUS"
        fi
        if [[ "$joined" == *' KVS_CERT_SAN='*' kvs-nginx sh -c '* ]]; then
            exit "${MOCK_GENERATE_STATUS:-0}"
        fi
        if [[ "$joined" == *' kvs-nginx nginx -t '* ]]; then
            next_status MOCK_NGINX_TEST_RESULTS nginx-test-count
            exit "$NEXT_STATUS"
        fi
        if [[ "$joined" == *' kvs-nginx nginx -s reload '* ]]; then
            next_status MOCK_NGINX_RELOAD_RESULTS nginx-reload-count
            exit "$NEXT_STATUS"
        fi
        if [[ "$joined" == *' kvs-php sh -c '* &&
            "$joined" == *'IFS= read -r MYSQL_PWD'* &&
            "$joined" == *'exec mariadb "$@"'* ]]; then
            submitted_password=''
            IFS= read -r submitted_password || exit 92
            sql=$(cat)
            [ "$submitted_password" = "${MOCK_MARIADB_PASSWORD:?}" ] || exit 91
            query_bytes=${#sql}
            printf 'mariadb-argv' >> "$MOCK_STATE/mariadb.argv"
            printf ' %q' "$@" >> "$MOCK_STATE/mariadb.argv"
            printf '\n' >> "$MOCK_STATE/mariadb.argv"

            if [[ "$sql" == *'LOCK TABLES ktvs_admin_servers WRITE'* &&
                "$sql" == *'@kvs_guard_ok'* ]]; then
                if [[ "$sql" == *'SET UPDATE ktvs_admin_servers'* ||
                    "$sql" == *'WHERE ;'* ]]; then
                    exit 89
                fi
                guard_result=${MOCK_APPLICATION_GUARD_RESULT:-1}
                if [[ "$sql" == *'streaming_skip_ssl_check = 1'* ]]; then
                    record_query_kind tls-skip-1-guarded "$query_bytes"
                    if [ "${MOCK_TLS_DB_STATUS:-0}" -eq 0 ] &&
                        [ "$guard_result" = 1 ]; then
                        set_expected_database_skip
                    fi
                    [ "${MOCK_TLS_DB_STATUS:-0}" -eq 0 ] ||
                        exit "$MOCK_TLS_DB_STATUS"
                elif [[ "$sql" == *'streaming_skip_ssl_check = 0'* ]]; then
                    record_query_kind tls-skip-0-guarded "$query_bytes"
                    if [ "${MOCK_TLS_DB_STATUS:-0}" -eq 0 ] &&
                        [ "$guard_result" = 1 ]; then
                        set_expected_database_skip
                    fi
                    [ "${MOCK_TLS_DB_STATUS:-0}" -eq 0 ] ||
                        exit "$MOCK_TLS_DB_STATUS"
                elif [[ "$sql" == *'REGEXP_REPLACE'* ]]; then
                    record_query_kind update-url-guarded "$query_bytes"
                    if [ "${MOCK_URL_DB_STATUS:-0}" -eq 0 ] &&
                        [ "$guard_result" = 1 ]; then
                        set_expected_database_url
                    fi
                    [ "${MOCK_URL_DB_STATUS:-0}" -eq 0 ] ||
                        exit "$MOCK_URL_DB_STATUS"
                else
                    exit 88
                fi
                printf '%s\n' "$guard_result"
                cat "$MOCK_STATE/db-current"
                if [ "${MOCK_DB_MUTATION_AFTER_UNLOCK:-false}" = true ]; then
                    cp "$MOCK_STATE/db-conflict" "$MOCK_STATE/db-current"
                    printf 'database-mutation-after-unlock\n' >> "$MOCK_CALLS"
                fi
                exit 0
            fi
            if [[ "$sql" == *'SELECT CONCAT('* ]]; then
                record_query_kind snapshot "$query_bytes"
                cat "${MOCK_STATE:?}/db-current"
                exit "${MOCK_SNAPSHOT_STATUS:-0}"
            fi
            if [[ "$sql" == *'UPDATE ktvs_admin_servers AS target'* &&
                "$sql" == *'guard.total_count='* ]]; then
                if [ -n "${MOCK_REQUIRE_ROLLBACK_QUERY_BYTES:-}" ] &&
                    [ "$query_bytes" -le "$MOCK_REQUIRE_ROLLBACK_QUERY_BYTES" ]; then
                    exit 90
                fi
                if [[ "$sql" == *'BINARY urls <=> BINARY '* ]]; then
                    record_query_kind rollback-binary "$query_bytes"
                else
                    record_query_kind rollback-collated "$query_bytes"
                fi
                printf 'database-rollback-attempt\n' >> "$MOCK_CALLS"
                if [ "${MOCK_DB_CASE_MUTATION_AT_GUARD:-false}" = true ]; then
                    cp "$MOCK_STATE/db-case-conflict" "$MOCK_STATE/db-current"
                    printf 'database-case-mutation-at-guard\n' >> "$MOCK_CALLS"
                fi
                if cmp -s "$MOCK_STATE/db-current" \
                    "$MOCK_STATE/db-expected-current"; then
                    cp "$MOCK_STATE/db-before" "$MOCK_STATE/db-current"
                elif [ "${MOCK_DB_CASE_MUTATION_AT_GUARD:-false}" = true ] &&
                    [[ "$sql" != *'BINARY urls <=> BINARY '* ]]; then
                    # Model a case-insensitive utf8mb4_unicode_ci comparison.
                    cp "$MOCK_STATE/db-before" "$MOCK_STATE/db-current"
                fi
                exit "${MOCK_DB_RESTORE_STATUS:-0}"
            fi
            if [[ "$sql" == *'SELECT COUNT(*) FROM '*' urls LIKE '* ]]; then
                record_query_kind verify-matching-url "$query_bytes"
                if [ "${MOCK_EMPTY_MATCHING_COUNT:-false}" != true ]; then
                    if [ -n "${MOCK_MATCHING_COUNT+x}" ]; then
                        printf '%s\n' "$MOCK_MATCHING_COUNT"
                    elif cmp -s "$MOCK_STATE/db-current" "$MOCK_STATE/db-after"; then
                        printf '1\n'
                    else
                        printf '0\n'
                    fi
                fi
                exit "${MOCK_SCALAR_STATUS:-0}"
            fi
            if [[ "$sql" == *'SELECT COUNT(*) FROM '*' urls REGEXP '* ]]; then
                record_query_kind verify-stale-url "$query_bytes"
                if [ "${MOCK_EMPTY_STALE_COUNT:-false}" != true ]; then
                    if [ -n "${MOCK_STALE_COUNT+x}" ]; then
                        printf '%s\n' "$MOCK_STALE_COUNT"
                    elif cmp -s "$MOCK_STATE/db-current" "$MOCK_STATE/db-after"; then
                        printf '0\n'
                    else
                        printf '1\n'
                    fi
                fi
                exit "${MOCK_SCALAR_STATUS:-0}"
            fi
            if [[ "$sql" == *'SELECT COUNT(*) FROM '*' COALESCE'* ]]; then
                record_query_kind verify-tls "$query_bytes"
                if [ "${MOCK_EMPTY_SSL_MISMATCH_COUNT:-false}" != true ]; then
                    if [ -n "${MOCK_SSL_MISMATCH_COUNT+x}" ]; then
                        printf '%s\n' "$MOCK_SSL_MISMATCH_COUNT"
                    elif cmp -s "$MOCK_STATE/db-current" "$MOCK_STATE/db-after"; then
                        printf '0\n'
                    else
                        printf '1\n'
                    fi
                fi
                exit "${MOCK_SCALAR_STATUS:-0}"
            fi
            if [[ "$sql" == *'SELECT server_id'* ]]; then
                record_query_kind final-state "$query_bytes"
                printf '%s\n' "${MOCK_FINAL_QUERY_OUTPUT:-1 https://7.0.2.maximemichaud.ca/contents/ 0}"
                exit "${MOCK_FINAL_QUERY_STATUS:-0}"
            fi
            if [[ "$sql" == *'streaming_skip_ssl_check = 1'* ]]; then
                record_query_kind tls-skip-1 "$query_bytes"
                if [ "${MOCK_TLS_DB_STATUS:-0}" -eq 0 ]; then
                    set_expected_database_skip
                fi
                exit "${MOCK_TLS_DB_STATUS:-0}"
            fi
            if [[ "$sql" == *'streaming_skip_ssl_check = 0'* ]]; then
                record_query_kind tls-skip-0 "$query_bytes"
                if [ "${MOCK_TLS_DB_STATUS:-0}" -eq 0 ]; then
                    set_expected_database_skip
                fi
                exit "${MOCK_TLS_DB_STATUS:-0}"
            fi
            if [[ "$sql" == *'REGEXP_REPLACE'* ]]; then
                record_query_kind update-url "$query_bytes"
                if [ "${MOCK_URL_DB_STATUS:-0}" -eq 0 ]; then
                    set_expected_database_url
                fi
                exit "${MOCK_URL_DB_STATUS:-0}"
            fi
            record_query_kind other "$query_bytes"
            exit 0
        fi
        if [[ "$joined" == *' KVS_SNAPSHOT_PATH='*' kvs-php php -r '* ]]; then
            if [[ "$joined" == *'/admin/include/setup.php'* ]]; then
                cat "${MOCK_STATE:?}/setup-current"
            elif [[ "$joined" == *'/plugins/external_search/data.dat'* ]]; then
                cat "${MOCK_STATE:?}/plugin-current"
            else
                exit 96
            fi
            exit "${MOCK_FILE_SNAPSHOT_STATUS:-0}"
        fi
        if [[ "$joined" == *' KVS_ROLLBACK_PATH='*' kvs-php php -r '* ]]; then
            mapfile -t rollback_states
            [ "${#rollback_states[@]}" -eq 2 ] || exit 95
            if [[ "$joined" == *'/admin/include/setup.php'* ]]; then
                state_file="$MOCK_STATE/setup-current"
            elif [[ "$joined" == *'/plugins/external_search/data.dat'* ]]; then
                state_file="$MOCK_STATE/plugin-current"
            else
                exit 94
            fi
            printf 'file-rollback-attempt %s\n' "$state_file" >> "$MOCK_CALLS"
            [ "$(<"$state_file")" = "${rollback_states[0]}" ] || exit 3
            printf '%s\n' "${rollback_states[1]}" > "$state_file"
            exit 0
        fi
        if [[ "$joined" == *' KVS_GUARDED_PATH='* &&
            "$joined" == *' KVS_GUARDED_UPDATE='*' kvs-php php -r '* ]]; then
            mapfile -t guarded_states
            [ "${#guarded_states[@]}" -eq 1 ] || exit 87
            if [[ "$joined" == *' KVS_GUARDED_UPDATE=setup '* ]]; then
                update_kind=setup
                state_file="$MOCK_STATE/setup-current"
                target_file="$MOCK_STATE/setup-after"
                update_status=${MOCK_SETUP_WRITE_STATUS:-0}
                if [ "${MOCK_SETUP_CONCURRENT_BEFORE_GUARD:-false}" = true ]; then
                    cp "$MOCK_STATE/setup-conflict" "$state_file"
                    printf 'guarded-file-concurrent kind=setup\n' >> "$MOCK_CALLS"
                fi
            elif [[ "$joined" == *' KVS_GUARDED_UPDATE=plugin '* ]]; then
                update_kind=plugin
                state_file="$MOCK_STATE/plugin-current"
                target_file="$MOCK_STATE/plugin-after"
                update_status=${MOCK_PLUGIN_STATUS:-0}
                if [ "${MOCK_PLUGIN_CONCURRENT_BEFORE_GUARD:-false}" = true ]; then
                    cp "$MOCK_STATE/plugin-conflict" "$state_file"
                    printf 'guarded-file-concurrent kind=plugin\n' >> "$MOCK_CALLS"
                fi
            else
                exit 86
            fi
            printf 'guarded-file-update kind=%s\n' "$update_kind" >> "$MOCK_CALLS"
            [ "$(<"$state_file")" = "${guarded_states[0]}" ] || exit 3
            [ "$update_status" -eq 0 ] || exit "$update_status"
            cp "$target_file" "$state_file"
            cat "$state_file"
            exit 0
        fi
        if [[ "$joined" == *' kvs-php php -r '*'/admin/include/setup.php'* ]]; then
            if [ "${MOCK_SETUP_VERIFY_STATUS:-0}" -eq 0 ] &&
                ! cmp -s "${MOCK_STATE:?}/setup-current" "$MOCK_STATE/setup-after"; then
                exit 93
            fi
            exit "${MOCK_SETUP_VERIFY_STATUS:-0}"
        fi
        exit 0
        ;;
esac

exit 0
EOF
    chmod +x "$fixture/bin/docker"

    cat > "$fixture/bin/rm" <<'EOF'
#!/bin/bash
set -u

printf 'rm' >> "${MOCK_CALLS:?}"
printf ' %q' "$@" >> "$MOCK_CALLS"
printf '\n' >> "$MOCK_CALLS"
target="${!#}"
if [ "${MOCK_CADDY_BACKUP_SIGNAL_AFTER_COMMIT:-false}" = true ] &&
    [ "${1:-}" = -rf ] && [ -d "$target" ] &&
    { [ -e "$target/route" ] || [ -e "$target/reservation" ]; } &&
    [ ! -e "${MOCK_STATE:?}/backup-signal-sent" ]; then
    : > "$MOCK_STATE/backup-signal-sent"
    printf 'caddy-backup-cleanup signal=TERM\n' >> "$MOCK_CALLS"
    kill -TERM "$PPID"
    exit 143
fi
if [ "${MOCK_CADDY_BACKUP_RM_STATUS:-0}" -ne 0 ] &&
    [ "${1:-}" = -rf ] && [ -d "$target" ] &&
    { [ -e "$target/route" ] || [ -e "$target/reservation" ]; }; then
    exit "$MOCK_CADDY_BACKUP_RM_STATUS"
fi
exec /usr/bin/rm "$@"
EOF
    chmod +x "$fixture/bin/rm"
}

run_case() {
    local name="$1"
    local assignment
    local db_password
    local long_db_rows=0
    shift

    LAST_DIR="$TEST_ROOT/$name"
    mkdir -p "$LAST_DIR/state"
    : > "$LAST_DIR/docker.calls"
    rm -f "$LAST_DIR/state"/*
    for assignment in "$@"; do
        if [ "$assignment" = MOCK_ACME_PRESENT=true ]; then
            : > "$LAST_DIR/state/acme-present"
        elif [[ "$assignment" == MOCK_ACME_API=* ]]; then
            printf '%s\n' "${assignment#MOCK_ACME_API=}" > "$LAST_DIR/state/acme-api"
        elif [[ "$assignment" == MOCK_LONG_DB_ROWS=* ]]; then
            long_db_rows=${assignment#MOCK_LONG_DB_ROWS=}
        fi
    done
    initialize_application_state "$LAST_DIR"
    if [ "$long_db_rows" -gt 0 ]; then
        initialize_long_database_state "$LAST_DIR" "$long_db_rows"
    fi
    db_password=$(fixture_env_value "$LAST_DIR" MARIADB_PASSWORD)

    set +e
    {
        (
            cd "$LAST_DIR"
            env \
                PATH="$LAST_DIR/bin:/usr/bin:/bin" \
                TMPDIR="$LAST_DIR/state" \
                MOCK_CALLS="$LAST_DIR/docker.calls" \
                MOCK_STATE="$LAST_DIR/state" \
                MOCK_MARIADB_PASSWORD="$db_password" \
                MOCK_RUNNING_NAMES=kvs-php \
                "$@" \
                ./reconfigure.sh
        ) > "$LAST_DIR/output.log" 2>&1
        LAST_STATUS=$?
    } 2>/dev/null
    set -e
}

# Public direct TLS, exact SANs, profiles, stopped Nginx/ACME, runtime services,
# plugin safety, persisted port, and the final verified success marker.
create_fixture public-success
set_env_value "$TEST_ROOT/public-success" COMPOSE_PROFILES \
    'dragonfly,direct-tls,dragonfly'
set_env_value "$TEST_ROOT/public-success" HTTPS_PORT '127.0.0.1:18443'
run_case public-success
assert_success "public reconfiguration"
assert_eq 'dragonfly,direct-tls' \
    "$(sed -n 's/^COMPOSE_PROFILES=//p' "$LAST_DIR/.env")" \
    "direct TLS profile synchronization"
assert_count 1 "$LAST_DIR/.env" 'PROJECT_HTTPS_PORT=18443' \
    "persisted HTTPS port"
assert_contains "$LAST_DIR/docker.calls" \
    'docker compose up -d --force-recreate nginx acme' \
    "stopped Nginx and ACME were not started"
assert_contains "$LAST_DIR/docker.calls" \
    'acme.sh --issue -d 7.0.2.maximemichaud.ca' \
    "the actual KVS subdomain was not issued"
assert_not_contains "$LAST_DIR/docker.calls" 'www.7.0.2.maximemichaud.ca' \
    "the KVS subdomain unexpectedly received a nested www SAN"
assert_contains "$LAST_DIR/docker.calls" \
    '--accountemail admin@example.com --server letsencrypt' \
    "Let's Encrypt did not receive the selected account and server"
assert_contains "$LAST_DIR/docker.calls" 'acme.sh --install-cert' \
    "the public certificate was not installed"
assert_contains "$LAST_DIR/docker.calls" \
    'compose up -d --force-recreate --no-deps php-fpm cron dragonfly' \
    "PHP, cron, and the active cache were not recreated"
assert_contains "$LAST_DIR/docker.calls" '--user 1000:1000' \
    "project files were not updated as the KVS owner"
assert_contains "$LAST_DIR/docker.calls" 'tempnam' \
    "the plugin update did not use a same-directory temporary file"
assert_contains "$LAST_DIR/docker.calls" \
    'PROJECT_URL=https://7.0.2.maximemichaud.ca:18443' \
    "the effective HTTPS port was not propagated to project files"
assert_contains "$LAST_DIR/output.log" '=== Reconfiguration Complete ===' \
    "verified public reconfiguration did not report completion"
assert_contains "$LAST_DIR/state/mariadb.argv" \
    'mariadb-argv exec -i kvs-php sh -c' \
    "MariaDB was not invoked through the stdin wrapper"
assert_not_contains "$LAST_DIR/state/mariadb.argv" '-ptest-password' \
    "the database password appeared in MariaDB process arguments"
assert_not_contains "$LAST_DIR/state/mariadb.argv" 'test-password' \
    "the database password appeared in the captured Docker arguments"
assert_not_contains "$LAST_DIR/state/mariadb.argv" ' -e ' \
    "MariaDB SQL was passed with the legacy -e argument"
assert_not_contains "$LAST_DIR/state/mariadb.argv" \
    'UPDATE ktvs_admin_servers' \
    "an UPDATE statement appeared in MariaDB process arguments"
assert_not_contains "$LAST_DIR/docker.calls" 'test-password' \
    "the database password was written to the mock call log"

# Atomic .env replacement must not depend on append permission on the old
# inode. This reproduces the former partial-write path with a mode-0444 file.
create_fixture readonly-env
chmod 0444 "$TEST_ROOT/readonly-env/.env"
run_case readonly-env
assert_success "atomic persistence over a read-only .env inode"
assert_eq 'dragonfly,direct-tls' \
    "$(sed -n 's/^COMPOSE_PROFILES=//p' "$LAST_DIR/.env")" \
    "profile persistence over a read-only .env inode"
assert_eq 600 "$(stat -c '%a' "$LAST_DIR/.env")" \
    "atomically replaced .env permissions"
assert_not_contains "$LAST_DIR/output.log" 'Permission denied' \
    "atomic .env persistence emitted a permission failure"

# Apex domains intentionally receive both requested SANs.
create_fixture apex-sans
set_env_value "$TEST_ROOT/apex-sans" DOMAIN example.com
run_case apex-sans
assert_success "apex public reconfiguration"
assert_contains "$LAST_DIR/docker.calls" \
    'acme.sh --issue -d example.com --webroot /var/www/_letsencrypt --keylength ec-256 --accountemail admin@example.com -d www.example.com --server letsencrypt' \
    "the apex issuance did not request the exact domain and www SANs"

# ZeroSSL is explicit, receives the email, and a provider transition is forced.
create_fixture zerossl-transition
set_env_value "$TEST_ROOT/zerossl-transition" SSL_PROVIDER zerossl
run_case zerossl-transition \
    MOCK_ACME_API=https://acme-v02.api.letsencrypt.org/directory
assert_success "ZeroSSL provider transition"
assert_contains "$LAST_DIR/docker.calls" \
    '--accountemail admin@example.com --server zerossl --force' \
    "a Let's Encrypt to ZeroSSL transition was not forced explicitly"

# acme.sh can persist the requested Le_API before a forced issuance fails.
# The next run must trust the installed certificate issuer instead of that
# partially mutated state and must never report the stale certificate as valid.
create_fixture zerossl-partial-mutation
set_env_value "$TEST_ROOT/zerossl-partial-mutation" SSL_PROVIDER zerossl
run_case zerossl-partial-mutation \
    MOCK_ACME_API=https://acme-v02.api.letsencrypt.org/directory \
    MOCK_CERT_RESULTS=1 \
    MOCK_ISSUE_STATUS=61 \
    MOCK_MUTATE_ACME_API_ON_FAILURE=true \
    'MOCK_ISSUE_OUTPUT=forced provider transition failed'
assert_failure "forced provider transition failure"
assert_eq 'https://acme.zerossl.com/v2/DV90' \
    "$(<"$LAST_DIR/state/acme-api")" \
    "the ACME mutation fixture did not reproduce the partial Le_API write"

run_case zerossl-partial-mutation \
    MOCK_ACME_API=https://acme.zerossl.com/v2/DV90 \
    MOCK_CERT_RESULTS=1,1 \
    MOCK_ISSUE_STATUS=2 \
    'MOCK_ISSUE_OUTPUT=Domains not changed. Skipping. Next renewal time is later.'
assert_failure "stale Let's Encrypt certificate after a partial ZeroSSL transition"
assert_contains "$LAST_DIR/docker.calls" '--server zerossl --force' \
    "an issuer mismatch did not force the retry despite a matching Le_API"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "a stale certificate from the wrong provider reported success"

# ACME renewal skips are accepted only for the exact status and markers.
create_fixture acme-skip
run_case acme-skip \
    MOCK_ACME_API=https://acme-v02.api.letsencrypt.org/directory \
    MOCK_ISSUE_STATUS=2 \
    'MOCK_ISSUE_OUTPUT=Domains not changed. Skipping. Next renewal time is later.'
assert_success "valid ACME renewal skip"
assert_contains "$LAST_DIR/docker.calls" 'acme.sh --install-cert' \
    "an existing skipped certificate was not reinstalled"

create_fixture acme-bad-skip
run_case acme-bad-skip \
    MOCK_ACME_API=https://acme-v02.api.letsencrypt.org/directory \
    MOCK_ISSUE_STATUS=2 \
    'MOCK_ISSUE_OUTPUT=Domains not changed.'
assert_failure "ACME status 2 without both skip markers"
assert_not_contains "$LAST_DIR/docker.calls" 'acme.sh --install-cert' \
    "installation ran after an ambiguous ACME status 2"

create_fixture acme-other-failure
run_case acme-other-failure \
    MOCK_ACME_API=https://acme-v02.api.letsencrypt.org/directory \
    MOCK_ISSUE_STATUS=42 \
    'MOCK_ISSUE_OUTPUT=Domains not changed. Skipping.'
assert_failure "non-skip ACME status"
assert_not_contains "$LAST_DIR/docker.calls" 'acme.sh --install-cert' \
    "installation ran after a certificate issuance failure"
assert_not_contains "$LAST_DIR/docker.calls" 'mariadb-query tls-skip-0' \
    "strict SSL was persisted after a certificate issuance failure"

# Every public certificate stage must fail closed.
create_fixture install-failure
run_case install-failure MOCK_INSTALL_STATUS=43
assert_failure "certificate installation failure"
assert_not_contains "$LAST_DIR/docker.calls" 'KVS_CERT_PROVIDER=public' \
    "certificate validation ran after installation failed"

create_fixture validation-failure
run_case validation-failure MOCK_CERT_RESULTS=44
assert_failure "public certificate validation failure"
assert_not_contains "$LAST_DIR/docker.calls" 'kvs-nginx nginx -t' \
    "Nginx tested an invalid public certificate"

create_fixture nginx-test-failure
run_case nginx-test-failure MOCK_NGINX_TEST_RESULTS=45
assert_failure "Nginx certificate configuration test failure"
assert_not_contains "$LAST_DIR/docker.calls" 'kvs-nginx nginx -s reload' \
    "Nginx reloaded after rejecting the installed certificate"

create_fixture nginx-reload-failure
run_case nginx-reload-failure MOCK_NGINX_RELOAD_RESULTS=46
assert_failure "Nginx certificate reload failure"
assert_not_contains "$LAST_DIR/docker.calls" 'mariadb-query tls-skip-0' \
    "strict SSL was persisted after Nginx reload failed"

create_fixture compose-failure
run_case compose-failure MOCK_COMPOSE_STATUS=47
assert_failure "Nginx and ACME compose failure"
assert_not_contains "$LAST_DIR/docker.calls" 'acme.sh --issue' \
    "certificate issuance ran when Nginx and ACME did not start"

# A self-signed transition removes ACME and regenerates an exact SAN cert.
create_fixture selfsigned
set_env_value "$TEST_ROOT/selfsigned" SSL_PROVIDER selfsigned
set_env_value "$TEST_ROOT/selfsigned" COMPOSE_PROFILES \
    'dragonfly,direct-tls,direct-tls'
run_case selfsigned MOCK_ACME_PRESENT=true MOCK_CERT_RESULTS=1,0
assert_success "self-signed transition"
assert_eq dragonfly "$(sed -n 's/^COMPOSE_PROFILES=//p' "$LAST_DIR/.env")" \
    "direct TLS profile removal"
assert_contains "$LAST_DIR/docker.calls" 'docker stop kvs-acme' \
    "the ACME container was not stopped"
assert_contains "$LAST_DIR/docker.calls" 'docker rm kvs-acme' \
    "the ACME container was not removed"
assert_contains "$LAST_DIR/docker.calls" \
    'KVS_CERT_SAN=DNS:7.0.2.maximemichaud.ca' \
    "the self-signed certificate did not receive the exact SAN"
assert_not_contains "$LAST_DIR/docker.calls" \
    'KVS_CERT_SAN=DNS:7.0.2.maximemichaud.ca,DNS:www.7.0.2.maximemichaud.ca' \
    "the self-signed subdomain received an unwanted www SAN"
assert_contains "$LAST_DIR/docker.calls" 'mariadb-query tls-skip-1' \
    "self-signed TLS did not persist the SSL verification exception"

create_fixture acme-stop-failure
set_env_value "$TEST_ROOT/acme-stop-failure" SSL_PROVIDER selfsigned
set_env_value "$TEST_ROOT/acme-stop-failure" COMPOSE_PROFILES direct-tls
run_case acme-stop-failure MOCK_ACME_PRESENT=true MOCK_STOP_STATUS=48
assert_failure "ACME stop failure"
assert_not_contains "$LAST_DIR/docker.calls" 'docker rm kvs-acme' \
    "ACME removal ran after stop failed"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "ACME stop failure reported success"

create_fixture acme-remove-failure
set_env_value "$TEST_ROOT/acme-remove-failure" SSL_PROVIDER selfsigned
run_case acme-remove-failure MOCK_ACME_PRESENT=true MOCK_RM_STATUS=49
assert_failure "ACME removal failure"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "ACME removal failure reported success"

create_fixture acme-inspect-failure
set_env_value "$TEST_ROOT/acme-inspect-failure" SSL_PROVIDER selfsigned
run_case acme-inspect-failure MOCK_PS_ALL_STATUS=50
assert_failure "ACME inspection failure"
assert_not_contains "$LAST_DIR/docker.calls" 'compose up' \
    "reconfiguration continued after ACME inspection failed"

create_fixture running-inspect-failure
run_case running-inspect-failure MOCK_PS_STATUS=51
assert_failure "running container inspection failure"
assert_not_contains "$LAST_DIR/docker.calls" 'compose up' \
    "reconfiguration continued after running container inspection failed"

# Runtime recreation and the mandatory post-PHP Nginx reload fail closed.
create_fixture runtime-failure
run_case runtime-failure MOCK_RUNTIME_STATUS=52
assert_failure "application service recreation failure"
assert_not_contains "$LAST_DIR/output.log" 'Configuring server URLs' \
    "URL updates ran after PHP recreation failed"

create_fixture backend-reload-failure
run_case backend-reload-failure MOCK_NGINX_RELOAD_RESULTS=0,53
assert_failure "post-PHP Nginx reload failure"
assert_not_contains "$LAST_DIR/output.log" 'Configuring server URLs' \
    "URL updates ran after the post-PHP reload failed"

# setup.php and plugin updates are owner-scoped, verified, and fail closed.
create_fixture setup-verify-failure
run_case setup-verify-failure MOCK_SETUP_VERIFY_STATUS=54
assert_failure "setup.php verification failure"
assert_not_contains "$LAST_DIR/docker.calls" '/plugins/external_search/' \
    "the plugin update ran after setup.php verification failed"

create_fixture plugin-failure
run_case plugin-failure MOCK_PLUGIN_STATUS=55
assert_failure "plugin update failure"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "plugin update failure reported success"

# The final database counters, query, and banner are a verified transaction.
create_fixture database-mismatch
run_case database-mismatch MOCK_SSL_MISMATCH_COUNT=1
assert_failure "database state mismatch"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "a database mismatch reported success"

create_fixture empty-database-counters
run_case empty-database-counters \
    MOCK_EMPTY_STALE_COUNT=true \
    MOCK_EMPTY_SSL_MISMATCH_COUNT=true
assert_failure "empty database verification counters"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "empty database counters reported success"
assert_contains "$LAST_DIR/output.log" \
    'Database verification returned invalid counters' \
    "empty database counters did not produce an explicit validation error"

create_fixture final-query-failure
run_case final-query-failure MOCK_FINAL_QUERY_STATUS=56
assert_failure "final database query failure"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "the completion banner preceded a failing final query"

# Multi-site changes are delayed until every prior check passes. A final Caddy
# failure restores the route, reservation, database, setup.php, and plugin to
# their exact pre-run snapshots.
create_fixture caddy-internal
set_env_value "$TEST_ROOT/caddy-internal" MODE multi
set_env_value "$TEST_ROOT/caddy-internal" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
set_env_value "$TEST_ROOT/caddy-internal" SSL_PROVIDER selfsigned
set_env_value "$TEST_ROOT/caddy-internal" USE_WWW true
set_env_value "$TEST_ROOT/caddy-internal" COMPOSE_PROFILES \
    'dragonfly,direct-tls'
run_case caddy-internal MOCK_RUNNING_NAMES='kvs-php kvs-caddy'
assert_success "multi-site internal TLS transition"
assert_contains "$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy" \
    'tls=internal www=true' \
    "Caddy did not receive internal TLS and USE_WWW=true"
assert_eq dragonfly "$(sed -n 's/^COMPOSE_PROFILES=//p' "$LAST_DIR/.env")" \
    "multi-site direct TLS profile removal"
assert_count 1 "$LAST_DIR/docker.calls" 'caddy-reload force=true' \
    "successful Caddy route activation was not forced"
assert_not_contains "$LAST_DIR/docker.calls" 'caddy-reload force=false' \
    "successful Caddy route activation used an unforced reload"

# Recreating an upstream can change its Docker IP without changing one byte of
# Caddy route text. The unchanged route must still receive a forced reload.
create_fixture caddy-unchanged-route
set_env_value "$TEST_ROOT/caddy-unchanged-route" MODE multi
set_env_value "$TEST_ROOT/caddy-unchanged-route" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' \
    'domain=7.0.2.maximemichaud.ca prefix=kvs tls=public www=false' > \
    "$TEST_ROOT/caddy-unchanged-route/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' 'DOMAIN=7.0.2.maximemichaud.ca' 'SITE_PREFIX=kvs' > \
    "$TEST_ROOT/caddy-unchanged-route/multi-site/sites/.primary.env"
unchanged_route_hash=$(sha256sum \
    "$TEST_ROOT/caddy-unchanged-route/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy")
run_case caddy-unchanged-route MOCK_RUNNING_NAMES='kvs-php kvs-caddy'
assert_success "unchanged Caddy route with a recreated upstream"
assert_eq "$unchanged_route_hash" \
    "$(sha256sum "$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy")" \
    "unchanged-route fixture unexpectedly changed its route text"
assert_contains "$LAST_DIR/docker.calls" \
    'compose up -d --force-recreate --no-deps php-fpm cron dragonfly' \
    "unchanged-route fixture did not recreate the application upstream"
assert_count 1 "$LAST_DIR/docker.calls" 'caddy-reload force=true' \
    "unchanged route did not force Caddy upstream reprovisioning"
assert_before "$LAST_DIR/docker.calls" \
    'compose up -d --force-recreate --no-deps php-fpm cron dragonfly' \
    'caddy-reload force=true' \
    "Caddy reloaded before the upstream was recreated"

# The armed EXIT trap compensates failures before Caddy activation. Rolling
# post-mutation snapshots let it restore even commands that changed state and
# then returned an error.
create_fixture multi-runtime-rollback
set_env_value "$TEST_ROOT/multi-runtime-rollback" MODE multi
set_env_value "$TEST_ROOT/multi-runtime-rollback" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
set_env_value "$TEST_ROOT/multi-runtime-rollback" SSL_PROVIDER selfsigned
run_case multi-runtime-rollback \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_RUNTIME_STATUS=52
assert_failure "multi-site runtime failure rollback"
assert_eq "$(<"$LAST_DIR/state/db-before")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "runtime failure did not restore the database"
assert_eq "$(<"$LAST_DIR/state/setup-before")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "runtime failure did not preserve setup.php"
assert_eq "$(<"$LAST_DIR/state/plugin-before")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "runtime failure did not preserve plugin data"
assert_contains "$LAST_DIR/output.log" \
    'Application state restored after the reconfiguration failure' \
    "runtime failure did not trigger the armed rollback trap"
assert_not_contains "$LAST_DIR/docker.calls" 'site-manager primary-config' \
    "Caddy activation ran after a runtime failure"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "multi-site runtime failure reported success"

# The locked query returns its snapshot before UNLOCK. A mutation injected
# immediately afterwards must be detected by the second snapshot and preserved
# instead of being mistaken for state owned by this reconfiguration.
create_fixture multi-database-after-unlock-conflict
set_env_value "$TEST_ROOT/multi-database-after-unlock-conflict" MODE multi
set_env_value "$TEST_ROOT/multi-database-after-unlock-conflict" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
set_env_value "$TEST_ROOT/multi-database-after-unlock-conflict" SSL_PROVIDER \
    selfsigned
run_case multi-database-after-unlock-conflict \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_DB_MUTATION_AFTER_UNLOCK=true
assert_failure "database mutation after UNLOCK"
assert_eq "$(<"$LAST_DIR/state/db-conflict")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "post-UNLOCK database mutation was overwritten"
assert_eq "$(<"$LAST_DIR/state/setup-before")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "post-UNLOCK conflict changed setup.php"
assert_eq "$(<"$LAST_DIR/state/plugin-before")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "post-UNLOCK conflict changed plugin data"
assert_contains "$LAST_DIR/docker.calls" 'database-mutation-after-unlock' \
    "post-UNLOCK mutation was not injected"
assert_contains "$LAST_DIR/output.log" \
    'Database state changed concurrently after update' \
    "post-UNLOCK mutation was not detected"
assert_contains "$LAST_DIR/output.log" \
    'Application state changed concurrently; rollback was not attempted' \
    "post-UNLOCK mutation did not block rollback"
assert_not_contains "$LAST_DIR/docker.calls" 'database-rollback-attempt' \
    "database rollback ran after a post-UNLOCK mutation"
assert_not_contains "$LAST_DIR/docker.calls" 'file-rollback-attempt' \
    "file rollback ran after a post-UNLOCK mutation"
assert_not_contains "$LAST_DIR/docker.calls" 'site-manager primary-config' \
    "Caddy activation ran after a post-UNLOCK mutation"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "post-UNLOCK database conflict reported success"

create_fixture multi-setup-guarded-failure
set_env_value "$TEST_ROOT/multi-setup-guarded-failure" MODE multi
set_env_value "$TEST_ROOT/multi-setup-guarded-failure" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
run_case multi-setup-guarded-failure \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_SETUP_WRITE_STATUS=54
assert_failure "multi-site guarded setup.php failure rollback"
assert_eq "$(<"$LAST_DIR/state/db-before")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "setup.php failure did not restore the database"
assert_eq "$(<"$LAST_DIR/state/setup-before")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "guarded setup.php failure changed the file"
assert_eq "$(<"$LAST_DIR/state/plugin-before")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "setup.php failure did not preserve plugin data"
assert_contains "$LAST_DIR/output.log" \
    'Application state restored after the reconfiguration failure' \
    "guarded setup.php failure did not trigger rollback"
assert_not_contains "$LAST_DIR/docker.calls" 'site-manager primary-config' \
    "Caddy activation ran after setup.php failed"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "multi-site setup.php failure reported success"

create_fixture multi-plugin-guarded-failure
set_env_value "$TEST_ROOT/multi-plugin-guarded-failure" MODE multi
set_env_value "$TEST_ROOT/multi-plugin-guarded-failure" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
run_case multi-plugin-guarded-failure \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_PLUGIN_STATUS=55
assert_failure "multi-site guarded plugin failure rollback"
assert_eq "$(<"$LAST_DIR/state/db-before")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "plugin failure did not restore the database"
assert_eq "$(<"$LAST_DIR/state/setup-before")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "plugin failure did not restore setup.php"
assert_eq "$(<"$LAST_DIR/state/plugin-before")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "guarded plugin failure changed plugin data"
assert_contains "$LAST_DIR/output.log" \
    'Application state restored after the reconfiguration failure' \
    "guarded plugin failure did not trigger rollback"
assert_not_contains "$LAST_DIR/docker.calls" 'site-manager primary-config' \
    "Caddy activation ran after plugin data failed"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "multi-site plugin failure reported success"

# Reproduce the former capture/write race inside the guarded setup update. A
# concurrent mutation immediately before the compare-and-swap must be rejected,
# preserved exactly, and must block rollback of all application components.
create_fixture multi-setup-cas-conflict
set_env_value "$TEST_ROOT/multi-setup-cas-conflict" MODE multi
set_env_value "$TEST_ROOT/multi-setup-cas-conflict" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
run_case multi-setup-cas-conflict \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_SETUP_CONCURRENT_BEFORE_GUARD=true
assert_failure "guarded setup.php compare-and-swap conflict"
assert_eq "$(<"$LAST_DIR/state/db-after")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "setup.php CAS conflict unexpectedly rolled back the database"
assert_eq "$(<"$LAST_DIR/state/setup-conflict")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "concurrent setup.php mutation was overwritten"
assert_eq "$(<"$LAST_DIR/state/plugin-before")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "setup.php CAS conflict changed plugin data"
assert_contains "$LAST_DIR/docker.calls" \
    'guarded-file-concurrent kind=setup' \
    "setup.php CAS mutation was not injected"
assert_contains "$LAST_DIR/output.log" \
    'Failed to update the KVS project URL' \
    "setup.php CAS conflict was not rejected"
assert_contains "$LAST_DIR/output.log" \
    'Application state changed concurrently; rollback was not attempted' \
    "setup.php CAS conflict did not block rollback"
assert_not_contains "$LAST_DIR/docker.calls" 'database-rollback-attempt' \
    "database rollback ran after a setup.php CAS conflict"
assert_not_contains "$LAST_DIR/docker.calls" 'file-rollback-attempt' \
    "file rollback ran after a setup.php CAS conflict"
assert_not_contains "$LAST_DIR/docker.calls" 'site-manager primary-config' \
    "Caddy activation ran after a setup.php CAS conflict"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "setup.php CAS conflict reported success"

# Once Caddy has accepted and reloaded the new route, failure to delete the
# rollback directory is only a cleanup warning. The committed route and the
# matching application state must remain active.
create_fixture caddy-backup-cleanup-warning
set_env_value "$TEST_ROOT/caddy-backup-cleanup-warning" MODE multi
set_env_value "$TEST_ROOT/caddy-backup-cleanup-warning" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-backup-cleanup-warning/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-backup-cleanup-warning/multi-site/sites/.primary.env"
run_case caddy-backup-cleanup-warning \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_BACKUP_RM_STATUS=60
assert_success "Caddy backup cleanup warning"
assert_contains "$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy" \
    'tls=public www=false' \
    "the accepted Caddy route was rolled back after cleanup failed"
assert_eq "$(<"$LAST_DIR/state/db-after")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "database state was rolled back after Caddy committed the route"
assert_eq "$(<"$LAST_DIR/state/setup-after")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "setup.php was rolled back after Caddy committed the route"
assert_eq "$(<"$LAST_DIR/state/plugin-after")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "plugin data was rolled back after Caddy committed the route"
assert_contains "$LAST_DIR/output.log" \
    'WARNING: Caddy was updated, but' \
    "Caddy backup cleanup failure did not emit a warning"
assert_contains "$LAST_DIR/output.log" '=== Reconfiguration Complete ===' \
    "committed Caddy route with a cleanup warning did not report success"
assert_not_contains "$LAST_DIR/docker.calls" 'database-rollback-attempt' \
    "database rollback ran after Caddy had committed the route"
assert_not_contains "$LAST_DIR/docker.calls" 'file-rollback-attempt' \
    "file rollback ran after Caddy had committed the route"

create_fixture caddy-validation-rollback
set_env_value "$TEST_ROOT/caddy-validation-rollback" MODE multi
set_env_value "$TEST_ROOT/caddy-validation-rollback" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-validation-rollback/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-validation-rollback/multi-site/sites/.primary.env"
run_case caddy-validation-rollback \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_VALIDATE_RESULTS=0,57,0
assert_failure "Caddy validation failure"
assert_eq old-route \
    "$(<"$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy")" \
    "Caddy route rollback"
assert_eq old-reservation \
    "$(<"$LAST_DIR/multi-site/sites/.primary.env")" \
    "Caddy reservation rollback"
assert_eq "$(<"$LAST_DIR/state/db-before")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "database rollback after final Caddy validation failure"
assert_eq "$(<"$LAST_DIR/state/setup-before")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "setup.php rollback after final Caddy validation failure"
assert_eq "$(<"$LAST_DIR/state/plugin-before")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "plugin rollback after final Caddy validation failure"
assert_contains "$LAST_DIR/docker.calls" 'database-rollback-attempt' \
    "database rollback was not attempted after the final Caddy failure"
assert_count 2 "$LAST_DIR/docker.calls" 'file-rollback-attempt' \
    "both application files were not rolled back"
assert_contains "$LAST_DIR/output.log" \
    'Application state restored after the reconfiguration failure' \
    "successful application rollback was not confirmed"
assert_before "$LAST_DIR/docker.calls" 'caddy-reload count=1 status=0' \
    'file-rollback-attempt' \
    "application rollback ran before the old Caddy route was reloaded"
assert_count 1 "$LAST_DIR/docker.calls" 'caddy-reload force=true' \
    "restored Caddy route was not force-reloaded"
assert_not_contains "$LAST_DIR/docker.calls" 'caddy-reload force=false' \
    "Caddy restoration used an unforced reload"
assert_contains "$LAST_DIR/docker.calls" \
    'site-manager primary-config 7.0.2.maximemichaud.ca kvs public false' \
    "Caddy did not receive public TLS and USE_WWW=false"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "Caddy validation failure reported success"

# TERM while validating the generated route occurs before the commit point.
# The EXIT trap must restore and reload Caddy before rolling back application
# state, while preserving the signal exit status.
create_fixture caddy-precommit-sigterm
set_env_value "$TEST_ROOT/caddy-precommit-sigterm" MODE multi
set_env_value "$TEST_ROOT/caddy-precommit-sigterm" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-precommit-sigterm/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-precommit-sigterm/multi-site/sites/.primary.env"
run_case caddy-precommit-sigterm \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_VALIDATE_SIGNAL=TERM
assert_eq 143 "$LAST_STATUS" "pre-commit Caddy SIGTERM status"
assert_eq old-route \
    "$(<"$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy")" \
    "pre-commit SIGTERM did not restore the Caddy route"
assert_eq old-reservation \
    "$(<"$LAST_DIR/multi-site/sites/.primary.env")" \
    "pre-commit SIGTERM did not restore the Caddy reservation"
assert_eq "$(<"$LAST_DIR/state/db-before")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "pre-commit SIGTERM did not restore the database"
assert_eq "$(<"$LAST_DIR/state/setup-before")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "pre-commit SIGTERM did not restore setup.php"
assert_eq "$(<"$LAST_DIR/state/plugin-before")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "pre-commit SIGTERM did not restore plugin data"
assert_contains "$LAST_DIR/docker.calls" 'caddy-validate signal=TERM' \
    "pre-commit SIGTERM was not injected during Caddy validation"
assert_contains "$LAST_DIR/output.log" \
    'Caddy route restored after the reconfiguration failure' \
    "pre-commit SIGTERM did not confirm Caddy restoration"
assert_contains "$LAST_DIR/output.log" \
    'Application state restored after the reconfiguration failure' \
    "pre-commit SIGTERM did not confirm application restoration"
assert_before "$LAST_DIR/docker.calls" 'caddy-reload count=1 status=0' \
    'file-rollback-attempt' \
    "pre-commit SIGTERM rolled back the application before Caddy"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "pre-commit SIGTERM reported success"

# If the old Caddy route cannot be validated after its files are restored, the
# application must remain in its new state to avoid routing old application
# URLs through an unconfirmed proxy configuration.
create_fixture caddy-restore-failure-preserves-application
set_env_value "$TEST_ROOT/caddy-restore-failure-preserves-application" MODE multi
set_env_value "$TEST_ROOT/caddy-restore-failure-preserves-application" \
    COMPOSE_FILE 'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-restore-failure-preserves-application/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-restore-failure-preserves-application/multi-site/sites/.primary.env"
run_case caddy-restore-failure-preserves-application \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_VALIDATE_RESULTS=0,57,58
assert_failure "restored Caddy validation failure"
assert_eq old-route \
    "$(<"$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy")" \
    "failed Caddy restoration did not put back the route file"
assert_eq old-reservation \
    "$(<"$LAST_DIR/multi-site/sites/.primary.env")" \
    "failed Caddy restoration did not put back the reservation file"
assert_eq "$(<"$LAST_DIR/state/db-after")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "application database was rolled back after Caddy restoration failed"
assert_eq "$(<"$LAST_DIR/state/setup-after")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "setup.php was rolled back after Caddy restoration failed"
assert_eq "$(<"$LAST_DIR/state/plugin-after")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "plugin data was rolled back after Caddy restoration failed"
assert_not_contains "$LAST_DIR/docker.calls" 'database-rollback-attempt' \
    "database rollback ran after Caddy restoration failed"
assert_not_contains "$LAST_DIR/docker.calls" 'file-rollback-attempt' \
    "file rollback ran after Caddy restoration failed"
assert_contains "$LAST_DIR/output.log" \
    'Restored Caddy configuration could not be reloaded' \
    "failed restored Caddy validation did not report an error"
assert_contains "$LAST_DIR/output.log" \
    'Application rollback was skipped because Caddy could not be restored' \
    "application preservation after Caddy restoration failure was not reported"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "failed Caddy restoration reported success"

# TERM during rollback-directory cleanup happens after the explicit Caddy
# commit point. Both new states must remain and the EXIT trap may only clean up.
create_fixture caddy-postcommit-sigterm
set_env_value "$TEST_ROOT/caddy-postcommit-sigterm" MODE multi
set_env_value "$TEST_ROOT/caddy-postcommit-sigterm" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-postcommit-sigterm/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-postcommit-sigterm/multi-site/sites/.primary.env"
run_case caddy-postcommit-sigterm \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_BACKUP_SIGNAL_AFTER_COMMIT=true
assert_eq 143 "$LAST_STATUS" "post-commit Caddy SIGTERM status"
assert_contains "$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy" \
    'tls=public www=false' \
    "post-commit SIGTERM rolled back the accepted Caddy route"
assert_eq "$(<"$LAST_DIR/state/db-after")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "post-commit SIGTERM rolled back the database"
assert_eq "$(<"$LAST_DIR/state/setup-after")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "post-commit SIGTERM rolled back setup.php"
assert_eq "$(<"$LAST_DIR/state/plugin-after")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "post-commit SIGTERM rolled back plugin data"
assert_contains "$LAST_DIR/docker.calls" \
    'caddy-backup-cleanup signal=TERM' \
    "post-commit SIGTERM was not injected during backup cleanup"
assert_not_contains "$LAST_DIR/docker.calls" 'database-rollback-attempt' \
    "database rollback ran after the Caddy commit point"
assert_not_contains "$LAST_DIR/docker.calls" 'file-rollback-attempt' \
    "file rollback ran after the Caddy commit point"
assert_not_contains "$LAST_DIR/output.log" \
    'Caddy route restored after the reconfiguration failure' \
    "post-commit SIGTERM restored the old Caddy route"
assert_not_contains "$LAST_DIR/output.log" \
    'Application state restored after the reconfiguration failure' \
    "post-commit SIGTERM restored old application state"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "post-commit SIGTERM reported normal completion"

# A rollback query larger than Linux MAX_ARG_STRLEN must still reach MariaDB
# intact because SQL is streamed over stdin instead of placed in one argv item.
create_fixture caddy-large-sql-rollback
set_env_value "$TEST_ROOT/caddy-large-sql-rollback" MODE multi
set_env_value "$TEST_ROOT/caddy-large-sql-rollback" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-large-sql-rollback/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-large-sql-rollback/multi-site/sites/.primary.env"
run_case caddy-large-sql-rollback \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_VALIDATE_RESULTS=0,57,0 \
    MOCK_LONG_DB_ROWS=800 \
    MOCK_REQUIRE_ROLLBACK_QUERY_BYTES=131072
assert_failure "large SQL Caddy rollback"
assert_gt 131072 "$(<"$LAST_DIR/state/max-query-bytes")" \
    "rollback SQL did not exceed MAX_ARG_STRLEN"
assert_eq "$(<"$LAST_DIR/state/db-before")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "large streamed rollback SQL did not restore the database"
assert_contains "$LAST_DIR/docker.calls" 'mariadb-query rollback-binary' \
    "large rollback SQL did not reach the stdin-aware mock"
assert_not_contains "$LAST_DIR/state/mariadb.argv" \
    'UPDATE ktvs_admin_servers AS target' \
    "large rollback SQL leaked into process arguments"
assert_not_contains "$LAST_DIR/state/mariadb.argv" '-ptest-password' \
    "database password leaked into large-query process arguments"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "a failing Caddy route with large rollback SQL reported success"

# A concurrent database mutation after the post-update snapshot must trip the
# compare-and-swap guard. No application component may be overwritten.
create_fixture caddy-cas-conflict
set_env_value "$TEST_ROOT/caddy-cas-conflict" MODE multi
set_env_value "$TEST_ROOT/caddy-cas-conflict" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-cas-conflict/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-cas-conflict/multi-site/sites/.primary.env"
run_case caddy-cas-conflict \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_VALIDATE_RESULTS=0,57,0 \
    MOCK_CONCURRENT_MUTATION_TARGET=db
assert_failure "Caddy rollback compare-and-swap conflict"
assert_eq "$(<"$LAST_DIR/state/db-conflict")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "concurrent database state was overwritten"
assert_eq "$(<"$LAST_DIR/state/setup-after")" \
    "$(<"$LAST_DIR/state/setup-current")" \
    "setup.php was overwritten despite the CAS conflict"
assert_eq "$(<"$LAST_DIR/state/plugin-after")" \
    "$(<"$LAST_DIR/state/plugin-current")" \
    "plugin data was overwritten despite the CAS conflict"
assert_not_contains "$LAST_DIR/docker.calls" 'database-rollback-attempt' \
    "database restoration ran despite a concurrent mutation"
assert_not_contains "$LAST_DIR/docker.calls" 'file-rollback-attempt' \
    "file restoration ran despite a concurrent mutation"
assert_contains "$LAST_DIR/output.log" \
    'Application state changed concurrently; rollback was not attempted' \
    "the CAS conflict did not produce the explicit safety error"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "a Caddy rollback CAS conflict reported success"

# Reproduce a concurrent URL update that differs only by case after the first
# snapshot comparison and immediately before the guarded SQL UPDATE. Under a
# case-insensitive collation, the guard must still reject the rollback.
create_fixture caddy-cas-case-conflict
set_env_value "$TEST_ROOT/caddy-cas-case-conflict" MODE multi
set_env_value "$TEST_ROOT/caddy-cas-case-conflict" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-cas-case-conflict/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-cas-case-conflict/multi-site/sites/.primary.env"
run_case caddy-cas-case-conflict \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_VALIDATE_RESULTS=0,57,0 \
    MOCK_DB_CASE_MUTATION_AT_GUARD=true
assert_failure "case-only database compare-and-swap conflict"
assert_eq 'https://7.0.2.maximemichaud.ca/contents/' \
    "$(database_snapshot_url "$LAST_DIR/state/db-after")" \
    "expected database snapshot URL"
assert_eq 'https://7.0.2.maximemichaud.ca/Contents/' \
    "$(database_snapshot_url "$LAST_DIR/state/db-case-conflict")" \
    "case-only concurrent database snapshot URL"
assert_eq "$(<"$LAST_DIR/state/db-case-conflict")" \
    "$(<"$LAST_DIR/state/db-current")" \
    "case-only concurrent database state was overwritten"
assert_contains "$LAST_DIR/docker.calls" \
    'database-case-mutation-at-guard' \
    "case-only mutation was not injected at the SQL guard"
assert_contains "$LAST_DIR/docker.calls" \
    'mariadb-query rollback-binary' \
    "the exercised SQL guard did not use bytewise URL comparison"
assert_contains "$LAST_DIR/output.log" \
    'Application rollback failed and requires manual recovery' \
    "the rejected case-only CAS rollback did not fail explicitly"
assert_not_contains "$LAST_DIR/output.log" \
    'Application state restored after the reconfiguration failure' \
    "a rejected case-only CAS rollback was reported as restored"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "a case-only Caddy rollback CAS conflict reported success"

create_fixture caddy-reload-rollback
set_env_value "$TEST_ROOT/caddy-reload-rollback" MODE multi
set_env_value "$TEST_ROOT/caddy-reload-rollback" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-reload-rollback/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-reload-rollback/multi-site/sites/.primary.env"
run_case caddy-reload-rollback \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_CADDY_VALIDATE_RESULTS=0,0,0 \
    MOCK_CADDY_RELOAD_RESULTS=59,0
assert_failure "Caddy reload failure"
assert_eq old-route \
    "$(<"$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy")" \
    "Caddy route rollback after reload failure"
assert_eq old-reservation \
    "$(<"$LAST_DIR/multi-site/sites/.primary.env")" \
    "Caddy reservation rollback after reload failure"
assert_count 2 "$LAST_DIR/docker.calls" 'caddy-reload force=true' \
    "failed activation and restored route were not both force-reloaded"
assert_not_contains "$LAST_DIR/docker.calls" 'caddy-reload force=false' \
    "reload failure recovery used an unforced Caddy reload"
assert_not_contains "$LAST_DIR/output.log" 'Reconfiguration Complete' \
    "Caddy reload failure reported success"

create_fixture caddy-deferred
set_env_value "$TEST_ROOT/caddy-deferred" MODE multi
set_env_value "$TEST_ROOT/caddy-deferred" COMPOSE_FILE \
    'docker-compose.yml:docker-compose.multi.yml'
printf '%s\n' old-route > \
    "$TEST_ROOT/caddy-deferred/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy"
printf '%s\n' old-reservation > \
    "$TEST_ROOT/caddy-deferred/multi-site/sites/.primary.env"
run_case caddy-deferred \
    MOCK_RUNNING_NAMES='kvs-php kvs-caddy' \
    MOCK_PLUGIN_STATUS=58
assert_failure "pre-Caddy plugin failure"
assert_eq old-route \
    "$(<"$LAST_DIR/multi-site/caddy/sites/7.0.2.maximemichaud.ca.caddy")" \
    "Caddy route changed before all application checks passed"
assert_eq old-reservation \
    "$(<"$LAST_DIR/multi-site/sites/.primary.env")" \
    "Caddy reservation changed before all application checks passed"
assert_not_contains "$LAST_DIR/docker.calls" 'site-manager primary-config' \
    "Caddy activation ran before the plugin check completed"

# Static checks retain the cryptographic and atomic-update invariants exercised
# through the full-script mocks above.
# shellcheck disable=SC2016
assert_contains "$ROOT_DIR/docker/reconfigure.sh" \
    '[ "$actual_dns_names" = "$expected_dns_names" ]' \
    "certificate validation does not enforce the exact DNS SAN set"
assert_contains "$ROOT_DIR/docker/reconfigure.sh" \
    'openssl verify -purpose sslserver' \
    "public certificate trust validation is missing"
assert_contains "$ROOT_DIR/docker/reconfigure.sh" \
    'openssl verify -check_ss_sig' \
    "self-signed certificate signature validation is missing"
# shellcheck disable=SC2016
assert_contains "$ROOT_DIR/docker/reconfigure.sh" \
    'private_public_key=$(openssl pkey' \
    "certificate/private-key pair validation is missing"
# shellcheck disable=SC2016
assert_contains "$ROOT_DIR/docker/reconfigure.sh" \
    'BINARY urls <=> BINARY ${expected_url_expression}' \
    "database rollback CAS does not force a bytewise URL comparison"
assert_contains "$ROOT_DIR/docker/reconfigure.sh" \
    $'chown($temporary, (int) $uid) &&\n                chgrp($temporary, (int) $gid) &&\n                chmod($temporary, octdec($mode)) &&' \
    "file rollback does not restore ownership before special mode bits"
reconfigure_reload_count=$(grep -Fc \
    'docker exec kvs-caddy caddy reload' "$ROOT_DIR/docker/reconfigure.sh")
reconfigure_forced_reload_count=$(grep -Fc \
    'docker exec kvs-caddy caddy reload --force' \
    "$ROOT_DIR/docker/reconfigure.sh")
assert_eq "$reconfigure_reload_count" "$reconfigure_forced_reload_count" \
    "reconfigure.sh contains an unforced Caddy reload path"
[ "$reconfigure_reload_count" -gt 0 ] ||
    fail "reconfigure.sh no longer contains a Caddy reload path"

echo "PASS: Reconfigure hardening (${ASSERTIONS} assertions)"
