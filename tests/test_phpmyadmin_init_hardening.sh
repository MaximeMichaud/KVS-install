#!/bin/bash
set -euo pipefail

# Run as a namespaced root user so numeric ownership can be verified without
# sudo. The isolated network also proves that every download is mocked.
if [ "${KVS_PHPMYADMIN_TEST_NAMESPACED:-false}" != true ]; then
    command -v unshare >/dev/null 2>&1 || {
        echo "FAIL: unshare is required for phpMyAdmin ownership tests" >&2
        exit 1
    }
    exec unshare --map-auto --map-root-user --net \
        env KVS_PHPMYADMIN_TEST_NAMESPACED=true bash "$0"
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INIT_SCRIPT="${ROOT_DIR}/docker/phpmyadmin/init.sh"
PRIMARY_COMPOSE="${ROOT_DIR}/docker/docker-compose.yml"
SECONDARY_COMPOSE="${ROOT_DIR}/docker/multi-site/docker-compose.site.yml.template"
TEST_DIR=$(mktemp -d /tmp/kvs-phpmyadmin-hardening.XXXXXX)
MOCK_BIN="${TEST_DIR}/bin"
ARCHIVE_DIR="${TEST_DIR}/archives"
VALID_ARCHIVE="${ARCHIVE_DIR}/phpMyAdmin-valid.tar.gz"
INCOMPLETE_ARCHIVE="${ARCHIVE_DIR}/phpMyAdmin-incomplete.tar.gz"
REAL_MV=$(command -v mv)
RUNTIME_VOLUME=

cleanup() {
    if [ -n "$RUNTIME_VOLUME" ]; then
        docker volume rm -f "$RUNTIME_VOLUME" >/dev/null 2>&1 || true
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || fail "Docker Compose is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ "$(id -u)" -eq 0 ] || fail "the ownership test did not enter its user namespace"

mkdir -p "$MOCK_BIN" "$ARCHIVE_DIR"
cat > "${MOCK_BIN}/apk" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "${MOCK_APK_LOG:?}"
EOF
cat > "${MOCK_BIN}/curl" <<'EOF'
#!/bin/sh
output=
url=

printf '%s\n' "$*" >> "${MOCK_CURL_LOG:?}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output=$2
            shift 2
            ;;
        -*)
            shift
            ;;
        *)
            url=$1
            shift
            ;;
    esac
done
[ -n "$output" ] || exit 64

case "$url" in
    https://files.phpmyadmin.net/phpMyAdmin/9.9.9/phpMyAdmin-9.9.9-all-languages.tar.gz)
        case "${MOCK_CURL_MODE:?}" in
            download-failure)
                exit 22
                ;;
            incomplete)
                cp "$MOCK_INCOMPLETE_ARCHIVE" "$output"
                ;;
            valid|checksum-mismatch)
                cp "$MOCK_VALID_ARCHIVE" "$output"
                ;;
            *)
                exit 65
                ;;
        esac
        ;;
    *)
        exit 22
        ;;
esac
EOF
cat > "${MOCK_BIN}/mv" <<'EOF'
#!/bin/sh
if [ -n "${MOCK_MV_FAIL_AT:-}" ]; then
    count=0
    if [ -f "${MOCK_MV_STATE:?}" ]; then
        count=$(cat "$MOCK_MV_STATE")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$MOCK_MV_STATE"
    if [ "$count" -eq "$MOCK_MV_FAIL_AT" ]; then
        exit 73
    fi
fi
exec "${MOCK_REAL_MV:?}" "$@"
EOF
chmod 0755 "${MOCK_BIN}/apk" "${MOCK_BIN}/curl" "${MOCK_BIN}/mv"

valid_root="${ARCHIVE_DIR}/valid/phpMyAdmin-9.9.9-all-languages"
mkdir -p "${valid_root}/libraries"
cat > "${valid_root}/index.php" <<'EOF'
<?php
echo 'new phpMyAdmin';
EOF
cat > "${valid_root}/config.sample.inc.php" <<'EOF'
<?php
$cfg['blowfish_secret'] = '';
$cfg['Servers'][1]['host'] = 'mariadb';
EOF
printf '%s\n' 'release asset' > "${valid_root}/libraries/release.txt"
tar -czf "$VALID_ARCHIVE" -C "${ARCHIVE_DIR}/valid" \
    phpMyAdmin-9.9.9-all-languages

incomplete_root="${ARCHIVE_DIR}/incomplete/phpMyAdmin-9.9.9-all-languages"
mkdir -p "$incomplete_root"
printf '%s\n' '<?php echo "incomplete";' > "${incomplete_root}/index.php"
tar -czf "$INCOMPLETE_ARCHIVE" -C "${ARCHIVE_DIR}/incomplete" \
    phpMyAdmin-9.9.9-all-languages

seed_complete_installation() {
    local target="$1"

    mkdir -p "${target}/tmp" "${target}/libraries"
    printf '%s\n' '<?php echo "legacy phpMyAdmin";' > "${target}/index.php"
    cat > "${target}/config.inc.php" <<'EOF'
<?php $cfg["legacy"] = true;
EOF
    printf '%s\n' 'legacy asset' > "${target}/libraries/legacy.txt"
    printf '%s\n' 'session data' > "${target}/tmp/session"
    chown -R 0:0 "$target"
    chmod 0755 "$target" "${target}/libraries"
    chmod 0644 "${target}/index.php" "${target}/libraries/legacy.txt"
    chown -R 1000:1000 "${target}/config.inc.php" "${target}/tmp"
    chmod 0600 "${target}/config.inc.php"
    chmod 0700 "${target}/tmp"
}

tree_fingerprint() {
    local target="$1"

    tar --sort=name --mtime=@0 --numeric-owner -cf - -C "$target" . |
        sha256sum | awk '{print $1}'
}

assert_no_transients() {
    local target="$1"
    local temp_root="$2"

    if find "$target" -mindepth 1 -maxdepth 1 \
        \( -name '.kvs-install-next.*' -o -name '.kvs-install-backup.*' -o \
        -name '.kvs-install-complete.*' \) -print -quit | grep -q .; then
        fail "phpMyAdmin promotion left a transient target entry"
    fi
    if find "$temp_root" -mindepth 1 -print -quit | grep -q .; then
        fail "phpMyAdmin initialization left a temporary download or staging tree"
    fi
}

archive_sha256() {
    case "$1" in
        incomplete) sha256sum "$INCOMPLETE_ARCHIVE" | cut -d' ' -f1 ;;
        checksum-mismatch) printf '%064d\n' 0 ;;
        *) sha256sum "$VALID_ARCHIVE" | cut -d' ' -f1 ;;
    esac
}

run_init() {
    local mode="$1"
    local target="$2"
    local temp_root="$3"
    local output="$4"
    local curl_log="$5"
    local apk_log="$6"
    local mv_fail_at="${7:-}"

    MOCK_CURL_MODE="$mode" \
    MOCK_VALID_ARCHIVE="$VALID_ARCHIVE" \
    MOCK_INCOMPLETE_ARCHIVE="$INCOMPLETE_ARCHIVE" \
    MOCK_CURL_LOG="$curl_log" \
    MOCK_APK_LOG="$apk_log" \
    MOCK_REAL_MV="$REAL_MV" \
    MOCK_MV_FAIL_AT="$mv_fail_at" \
    MOCK_MV_STATE="${output}.mv-state" \
    PHPMYADMIN_TARGET_DIR="$target" \
    PHPMYADMIN_VERSION=9.9.9 \
    PHPMYADMIN_SHA256="$(archive_sha256 "$mode")" \
    TMPDIR="$temp_root" \
    PATH="${MOCK_BIN}:$PATH" \
        "$INIT_SCRIPT" > "$output" 2>&1
}

assert_failure_preserves_installation() {
    local mode="$1"
    local case_dir="${TEST_DIR}/${mode}"
    local target="${case_dir}/target"
    local temp_root="${case_dir}/tmp"
    local before
    local after

    mkdir -p "$target" "$temp_root"
    seed_complete_installation "$target"
    before=$(tree_fingerprint "$target")
    if run_init "$mode" "$target" "$temp_root" "${case_dir}/output.log" \
        "${case_dir}/curl.log" "${case_dir}/apk.log"; then
        fail "${mode} unexpectedly initialized phpMyAdmin"
    fi
    after=$(tree_fingerprint "$target")

    [ "$before" = "$after" ] ||
        fail "${mode} damaged the existing complete installation"
    [ ! -e "${target}/.kvs-install-complete" ] ||
        fail "${mode} created a false completion marker"
    [ -s "${target}/libraries/legacy.txt" ] ||
        fail "${mode} removed an existing release asset"
    assert_no_transients "$target" "$temp_root"
}

assert_failure_preserves_installation download-failure
assert_failure_preserves_installation checksum-mismatch
assert_failure_preserves_installation incomplete

promotion_failure_dir="${TEST_DIR}/promotion-failure"
promotion_failure_target="${promotion_failure_dir}/target"
promotion_failure_temp="${promotion_failure_dir}/tmp"
mkdir -p "$promotion_failure_target" "$promotion_failure_temp"
seed_complete_installation "$promotion_failure_target"
promotion_failure_before=$(tree_fingerprint "$promotion_failure_target")
# Four existing top-level entries are backed up first. Failing the second move
# from the verified release exercises rollback after promotion has started.
if run_init valid "$promotion_failure_target" "$promotion_failure_temp" \
    "${promotion_failure_dir}/output.log" "${promotion_failure_dir}/curl.log" \
    "${promotion_failure_dir}/apk.log" 6; then
    fail "a failed phpMyAdmin promotion unexpectedly returned success"
fi
promotion_failure_after=$(tree_fingerprint "$promotion_failure_target")
[ "$promotion_failure_before" = "$promotion_failure_after" ] ||
    fail "a failed phpMyAdmin promotion did not restore the previous installation"
[ ! -e "${promotion_failure_target}/.kvs-install-complete" ] ||
    fail "a failed phpMyAdmin promotion created a completion marker"
assert_no_transients "$promotion_failure_target" "$promotion_failure_temp"

success_dir="${TEST_DIR}/success"
success_target="${success_dir}/target"
success_temp="${success_dir}/tmp"
success_curl_log="${success_dir}/curl.log"
success_apk_log="${success_dir}/apk.log"
mkdir -p "$success_target" "$success_temp"
seed_complete_installation "$success_target"
run_init valid "$success_target" "$success_temp" "${success_dir}/first.log" \
    "$success_curl_log" "$success_apk_log"

grep -Fq 'phpMyAdmin initialized successfully' "${success_dir}/first.log" ||
    fail "successful promotion was not reported"
grep -Fq 'new phpMyAdmin' "${success_target}/index.php" ||
    fail "the verified release was not promoted"
[ ! -e "${success_target}/libraries/legacy.txt" ] ||
    fail "the old release survived successful promotion"
[ -s "${success_target}/libraries/release.txt" ] ||
    fail "the new release is incomplete after promotion"
[ "$(cat "${success_target}/.kvs-install-complete")" = complete ] ||
    fail "the completion marker has invalid content"
[ "$(stat -c '%u:%g:%a' "${success_target}/.kvs-install-complete")" = '0:0:600' ] ||
    fail "the completion marker is not private and root-owned"
[ "$(stat -c '%u:%g:%a' "${success_target}/config.inc.php")" = '1000:1000:600' ] ||
    fail "config.inc.php is not private and readable by PHP-FPM"
[ "$(stat -c '%u:%g:%a' "${success_target}/tmp")" = '1000:1000:700' ] ||
    fail "the phpMyAdmin temporary directory is not private and writable by PHP-FPM"
[ "$(stat -c '%u:%g:%a' "${success_target}/index.php")" = '0:0:644' ] ||
    fail "phpMyAdmin application code remains writable by PHP-FPM"
[ "$(stat -c '%u:%g:%a' "$success_target")" = '0:0:755' ] ||
    fail "the phpMyAdmin application root remains writable by PHP-FPM"
if grep -Fq "\$cfg['blowfish_secret'] = '';" "${success_target}/config.inc.php"; then
    fail "config.inc.php retained an empty application secret"
fi
secret=$(sed -n "s/.*blowfish_secret.*= '\([A-Za-z0-9]\{32\}\)';.*/\1/p" \
    "${success_target}/config.inc.php")
[ "${#secret}" -eq 32 ] || fail "config.inc.php has no 32-character application secret"
assert_no_transients "$success_target" "$success_temp"

first_fingerprint=$(tree_fingerprint "$success_target")
: > "$success_curl_log"
: > "$success_apk_log"
run_init download-failure "$success_target" "$success_temp" \
    "${success_dir}/second.log" "$success_curl_log" "$success_apk_log"
second_fingerprint=$(tree_fingerprint "$success_target")
[ "$first_fingerprint" = "$second_fingerprint" ] ||
    fail "an idempotent rerun changed the initialized release"
grep -Fq 'phpMyAdmin is already initialized' "${success_dir}/second.log" ||
    fail "an idempotent rerun was not detected"
[ ! -s "$success_curl_log" ] || fail "an idempotent rerun attempted a download"
[ ! -s "$success_apk_log" ] || fail "an idempotent rerun attempted package installation"
assert_no_transients "$success_target" "$success_temp"

# Exercise the same script with Alpine's BusyBox tools when the project image
# is already available locally. Image pulls are deliberately forbidden here.
if docker image inspect alpine:latest >/dev/null 2>&1; then
    RUNTIME_VOLUME="kvs-phpmyadmin-hardening-${RANDOM}-$$"
    docker volume create "$RUNTIME_VOLUME" >/dev/null
    docker run --rm --network none \
        -e MOCK_CURL_MODE=valid \
        -e PHPMYADMIN_VERSION=9.9.9 \
        -e PHPMYADMIN_SHA256="$(archive_sha256 valid)" \
        -e MOCK_VALID_ARCHIVE=/archives/phpMyAdmin-valid.tar.gz \
        -e MOCK_INCOMPLETE_ARCHIVE=/archives/phpMyAdmin-incomplete.tar.gz \
        -e MOCK_CURL_LOG=/tmp/curl.log \
        -e MOCK_APK_LOG=/tmp/apk.log \
        -e MOCK_REAL_MV=/bin/mv \
        -e PATH=/mock:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        -v "${RUNTIME_VOLUME}:/usr/share/phpmyadmin" \
        -v "${INIT_SCRIPT}:/usr/local/bin/init-phpmyadmin:ro" \
        -v "${MOCK_BIN}:/mock:ro" \
        -v "${ARCHIVE_DIR}:/archives:ro" \
        --entrypoint /usr/local/bin/init-phpmyadmin \
        alpine:latest >/dev/null || fail "the initializer failed with Alpine BusyBox"
    docker run --rm --network none \
        -v "${RUNTIME_VOLUME}:/usr/share/phpmyadmin:ro" \
        alpine:latest sh -ceu '
            [ "$(stat -c "%u:%g:%a" /usr/share/phpmyadmin/.kvs-install-complete)" = 0:0:600 ]
            [ "$(stat -c "%u:%g:%a" /usr/share/phpmyadmin/config.inc.php)" = 1000:1000:600 ]
            [ "$(stat -c "%u:%g:%a" /usr/share/phpmyadmin/tmp)" = 1000:1000:700 ]
            [ -s /usr/share/phpmyadmin/index.php ]
        ' || fail "the Alpine runtime produced unsafe phpMyAdmin metadata"
    docker volume rm -f "$RUNTIME_VOLUME" >/dev/null
    RUNTIME_VOLUME=
fi

grep -Fq './phpmyadmin/init.sh:/usr/local/bin/init-phpmyadmin:ro' "$PRIMARY_COMPOSE" ||
    fail "the primary Compose file does not mount the verified initializer"
grep -Fq '../../../phpmyadmin/init.sh:/usr/local/bin/init-phpmyadmin:ro' \
    "$SECONDARY_COMPOSE" ||
    fail "the secondary Compose template uses the wrong initializer path"
if grep -Fq 'cp -r /var/www/html' "$SECONDARY_COMPOSE"; then
    fail "the secondary Compose template still uses the fragile one-shot copy"
fi

render_root="${TEST_DIR}/render/docker"
secondary_project="${render_root}/multi-site/sites/secondary.example.com"
mkdir -p "${render_root}/phpmyadmin" "$secondary_project"
cp "$INIT_SCRIPT" "${render_root}/phpmyadmin/init.sh"
cp "$SECONDARY_COMPOSE" "${secondary_project}/docker-compose.yml"

compose_env=(
    DOMAIN=secondary.example.com
    SITE_PREFIX=kvs-secondary
    MARIADB_ROOT_PASSWORD=test-root-password
    MARIADB_PASSWORD=test-site-password
)
env "${compose_env[@]}" docker compose \
    --project-directory "${ROOT_DIR}/docker" \
    --profile setup -f "$PRIMARY_COMPOSE" config --format json \
    > "${TEST_DIR}/primary.json"
env "${compose_env[@]}" docker compose \
    --project-directory "$secondary_project" \
    --profile setup -f "${secondary_project}/docker-compose.yml" config --format json \
    > "${TEST_DIR}/secondary.json"

assert_rendered_initializer() {
    local rendered="$1"
    local expected_source="$2"

    jq -e '.services["phpmyadmin-init"].image == "alpine:latest"' "$rendered" \
        >/dev/null || fail "rendered Compose does not use the Alpine initializer image"
    jq -e '.services["phpmyadmin-init"].entrypoint == ["/usr/local/bin/init-phpmyadmin"]' \
        "$rendered" >/dev/null || fail "rendered Compose has the wrong initializer entrypoint"
    jq -e --arg source "$expected_source" '
        .services["phpmyadmin-init"].volumes[] |
        select(.target == "/usr/local/bin/init-phpmyadmin") |
        .type == "bind" and .source == $source and .read_only == true
    ' "$rendered" >/dev/null || fail "rendered Compose has an unsafe initializer mount"
}

assert_rendered_initializer "${TEST_DIR}/primary.json" \
    "$(realpath "${ROOT_DIR}/docker/phpmyadmin/init.sh")"
assert_rendered_initializer "${TEST_DIR}/secondary.json" \
    "$(realpath "${render_root}/phpmyadmin/init.sh")"

echo "PASS: phpMyAdmin initialization hardening"
