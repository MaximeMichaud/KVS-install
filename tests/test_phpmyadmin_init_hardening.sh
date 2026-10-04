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
UNEXPECTED_HOST_ARCHIVE="${ARCHIVE_DIR}/phpMyAdmin-unexpected-host.tar.gz"
SAMPLE_HOST_LINE="\$cfg['Servers'][\$i]['host'] = 'localhost';"
MARIADB_HOST_LINE="\$cfg['Servers'][\$i]['host'] = 'mariadb';"
REAL_MV=$(command -v mv)
REAL_RM=$(command -v rm)
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
    https://www.phpmyadmin.net/downloads/)
        printf '%s\n' \
            '<a href="https://files.phpmyadmin.net/phpMyAdmin/9.9.9/phpMyAdmin-9.9.9-all-languages.tar.gz">Download</a>' \
            > "$output"
        ;;
    https://files.phpmyadmin.net/phpMyAdmin/9.9.9/phpMyAdmin-9.9.9-all-languages.tar.gz)
        case "${MOCK_CURL_MODE:?}" in
            download-failure)
                exit 22
                ;;
            incomplete)
                cp "$MOCK_INCOMPLETE_ARCHIVE" "$output"
                ;;
            unexpected-host)
                cp "$MOCK_UNEXPECTED_HOST_ARCHIVE" "$output"
                ;;
            valid)
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
$cfg['Servers'][$i]['host'] = 'localhost';
EOF
printf '%s\n' 'release asset' > "${valid_root}/libraries/release.txt"
tar -czf "$VALID_ARCHIVE" -C "${ARCHIVE_DIR}/valid" \
    phpMyAdmin-9.9.9-all-languages

# A release whose sample no longer has the localhost line must stop the
# installation rather than keep a host that PHP-FPM cannot reach.
unexpected_host_root="${ARCHIVE_DIR}/unexpected-host/phpMyAdmin-9.9.9-all-languages"
mkdir -p "$unexpected_host_root"
cp "${valid_root}/index.php" "${unexpected_host_root}/index.php"
cat > "${unexpected_host_root}/config.sample.inc.php" <<'EOF'
<?php
$cfg['blowfish_secret'] = '';
$cfg['Servers'][$i]['host'] = '127.0.0.1';
EOF
tar -czf "$UNEXPECTED_HOST_ARCHIVE" -C "${ARCHIVE_DIR}/unexpected-host" \
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
    MOCK_UNEXPECTED_HOST_ARCHIVE="$UNEXPECTED_HOST_ARCHIVE" \
    MOCK_CURL_LOG="$curl_log" \
    MOCK_APK_LOG="$apk_log" \
    MOCK_REAL_MV="$REAL_MV" \
    MOCK_MV_FAIL_AT="$mv_fail_at" \
    MOCK_MV_STATE="${output}.mv-state" \
    PHPMYADMIN_TARGET_DIR="$target" \
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
assert_failure_preserves_installation incomplete
assert_failure_preserves_installation unexpected-host
grep -Fq 'phpMyAdmin sample configuration has no localhost server entry' \
    "${TEST_DIR}/unexpected-host/output.log" ||
    fail "an unexpected sample database host was not reported"

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
grep -Fqx "$MARIADB_HOST_LINE" "${success_target}/config.inc.php" ||
    fail "config.inc.php does not connect to the mariadb service"
if grep -Fq "'localhost'" "${success_target}/config.inc.php"; then
    fail "config.inc.php still connects to localhost"
fi
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

# Volumes initialized before the database host was written keep the sample's
# localhost line. A rerun fixes that line inside the same file and nothing else.
seed_initialized_installation() {
    local target="$1"
    shift

    seed_complete_installation "$target"
    printf '%s\n' '<?php' "\$cfg['Servers'][\$i]['auth_type'] = 'cookie';" "$@" \
        > "${target}/config.inc.php"
    printf '%s\n' complete > "${target}/.kvs-install-complete"
    chmod 0600 "${target}/.kvs-install-complete"
}

repair_dir="${TEST_DIR}/repair"
repair_target="${repair_dir}/target"
repair_temp="${repair_dir}/tmp"
repair_config="${repair_target}/config.inc.php"
mkdir -p "$repair_target" "$repair_temp"
# The commented copy has to survive, and the blank last line shows that the
# rewrite keeps the end of the file as it was.
seed_initialized_installation "$repair_target" "$SAMPLE_HOST_LINE" \
    "// ${SAMPLE_HOST_LINE}" ''
awk -v sample="$SAMPLE_HOST_LINE" -v mariadb="$MARIADB_HOST_LINE" \
    '$0 == sample { $0 = mariadb } { print }' "$repair_config" \
    > "${repair_dir}/expected.php"
repair_inode=$(stat -c '%i' "$repair_config")
run_init download-failure "$repair_target" "$repair_temp" "${repair_dir}/first.log" \
    "${repair_dir}/curl.log" "${repair_dir}/apk.log"
grep -Fq 'phpMyAdmin is already initialized' "${repair_dir}/first.log" ||
    fail "the database host repair did not start from the initialized installation"
grep -Fxq 'Switched the sample localhost server entry of config.inc.php to mariadb' \
    "${repair_dir}/first.log" || fail "the database host repair was not reported"
cmp -s "${repair_dir}/expected.php" "$repair_config" ||
    fail "the database host repair changed more than the sample host line"
[ "$(stat -c '%i:%u:%g:%a' "$repair_config")" = "${repair_inode}:1000:1000:600" ] ||
    fail "the database host repair replaced config.inc.php or changed its metadata"
[ "$(stat -c '%u:%g:%a' "${repair_target}/.kvs-install-complete")" = '0:0:600' ] ||
    fail "the database host repair changed the completion marker"

repaired_fingerprint=$(tree_fingerprint "$repair_target")
repaired_mtime=$(stat -c '%y' "$repair_config")
run_init download-failure "$repair_target" "$repair_temp" "${repair_dir}/second.log" \
    "${repair_dir}/curl.log" "${repair_dir}/apk.log"
grep -Fq 'phpMyAdmin is already initialized' "${repair_dir}/second.log" ||
    fail "the repaired installation is no longer initialized"
[ "$(cat "${repair_dir}/second.log")" = 'phpMyAdmin is already initialized' ] ||
    fail "a rerun repaired the database host again"
[ "$(tree_fingerprint "$repair_target")" = "$repaired_fingerprint" ] ||
    fail "a rerun changed the repaired installation"
[ "$(stat -c '%y' "$repair_config")" = "$repaired_mtime" ] ||
    fail "a rerun rewrote the repaired configuration"
[ ! -s "${repair_dir}/curl.log" ] || fail "the database host repair attempted a download"
[ ! -s "${repair_dir}/apk.log" ] ||
    fail "the database host repair attempted package installation"
assert_no_transients "$repair_target" "$repair_temp"

# Any other host line was set on purpose, and so was a copy of the sample line
# that someone commented out or reformatted: the rerun leaves the file alone.
assert_host_left_alone() {
    local name="$1"
    shift
    local case_dir="${TEST_DIR}/${name}"
    local target="${case_dir}/target"
    local temp_root="${case_dir}/tmp"
    local config="${target}/config.inc.php"
    local fingerprint
    local mtime

    mkdir -p "$target" "$temp_root"
    seed_initialized_installation "$target" "$@"
    fingerprint=$(tree_fingerprint "$target")
    mtime=$(stat -c '%y' "$config")
    run_init download-failure "$target" "$temp_root" "${case_dir}/output.log" \
        "${case_dir}/curl.log" "${case_dir}/apk.log" ||
        fail "${name} made the initializer fail"
    [ "$(cat "${case_dir}/output.log")" = 'phpMyAdmin is already initialized' ] ||
        fail "${name} was not left alone as an initialized installation"
    [ "$(tree_fingerprint "$target")" = "$fingerprint" ] ||
        fail "${name} changed the installation"
    [ "$(stat -c '%y' "$config")" = "$mtime" ] ||
        fail "${name} rewrote the configuration"
    assert_no_transients "$target" "$temp_root"
}

assert_host_left_alone custom-host \
    "\$cfg['Servers'][\$i]['host'] = 'db.example.internal';"
assert_host_left_alone near-miss-host "// ${SAMPLE_HOST_LINE}" \
    "    ${SAMPLE_HOST_LINE}" "${SAMPLE_HOST_LINE/ = /  =  }"

# Writing in place empties config.inc.php before the new content goes in. A
# write cut short must fail the run and leave no completion marker, so the
# partial file is never taken for an initialized installation.
cut_dir="${TEST_DIR}/cut-write"
cut_target="${cut_dir}/target"
cut_temp="${cut_dir}/tmp"
cut_config="${cut_target}/config.inc.php"
mkdir -p "$cut_target" "$cut_temp"
seed_initialized_installation "$cut_target" "$SAMPLE_HOST_LINE"
# The comments bring the file to the size of the real sample, past the limit.
seq -f '// Sample configuration comment %g' 1 150 >> "$cut_config"
cut_size=$(stat -c '%s' "$cut_config")
# bash counts ulimit -f in KiB. With SIGXFSZ ignored, the cut is a write error
# that the initializer sees rather than a signal that kills it.
if (trap '' XFSZ; ulimit -f 1; run_init download-failure "$cut_target" "$cut_temp" \
    "${cut_dir}/output.log" "${cut_dir}/curl.log" "${cut_dir}/apk.log"); then
    fail "a configuration rewrite cut short was reported as a success"
fi
[ "$(stat -c '%s' "$cut_config")" -lt "$cut_size" ] ||
    fail "the file size limit did not cut the configuration rewrite short"
grep -Fxq "ERROR: Could not point phpMyAdmin at the mariadb service in ${cut_config}" \
    "${cut_dir}/output.log" || fail "a configuration rewrite cut short was not reported"
[ ! -e "${cut_target}/.kvs-install-complete" ] ||
    fail "a configuration rewrite cut short kept the completion marker"
assert_no_transients "$cut_target" "$cut_temp"

# The marker goes before config.inc.php is emptied. When it cannot be removed,
# the run fails and the configuration stays exactly as it was.
kept_dir="${TEST_DIR}/kept-marker"
kept_target="${kept_dir}/target"
kept_temp="${kept_dir}/tmp"
mkdir -p "$kept_target" "$kept_temp" "${kept_dir}/bin"
cat > "${kept_dir}/bin/rm" <<'EOF'
#!/bin/sh
case "$*" in
    */.kvs-install-complete)
        exit 1
        ;;
esac
exec "${MOCK_REAL_RM:?}" "$@"
EOF
chmod 0755 "${kept_dir}/bin/rm"
seed_initialized_installation "$kept_target" "$SAMPLE_HOST_LINE"
kept_fingerprint=$(tree_fingerprint "$kept_target")
if MOCK_REAL_RM="$REAL_RM" PATH="${kept_dir}/bin:$PATH" \
    run_init download-failure "$kept_target" "$kept_temp" "${kept_dir}/output.log" \
    "${kept_dir}/curl.log" "${kept_dir}/apk.log"; then
    fail "a repair that could not remove the completion marker succeeded"
fi
[ "$(tree_fingerprint "$kept_target")" = "$kept_fingerprint" ] ||
    fail "config.inc.php was rewritten while its completion marker was in place"
grep -Fq 'ERROR: Could not point phpMyAdmin at the mariadb service' \
    "${kept_dir}/output.log" ||
    fail "a repair that could not remove the completion marker was not reported"
assert_no_transients "$kept_target" "$kept_temp"

# Exercise the same script with Alpine's BusyBox tools when the project image
# is already available locally. Image pulls are deliberately forbidden here.
if docker image inspect alpine:latest >/dev/null 2>&1; then
    RUNTIME_VOLUME="kvs-phpmyadmin-hardening-${RANDOM}-$$"
    docker volume create "$RUNTIME_VOLUME" >/dev/null
    docker run --rm --network none \
        -e MOCK_CURL_MODE=valid \
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
    # Put back the localhost line of earlier installations. Its repair runs
    # before apk, so BusyBox alone has to rewrite it in place.
    docker run --rm --network none \
        -e MOCK_CURL_MODE=download-failure \
        -e MOCK_CURL_LOG=/tmp/curl.log \
        -e MOCK_APK_LOG=/tmp/apk.log \
        -e MOCK_REAL_MV=/bin/mv \
        -e LEGACY_HOST_LINE="$SAMPLE_HOST_LINE" \
        -e EXPECTED_HOST_LINE="$MARIADB_HOST_LINE" \
        -e PATH=/mock:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        -v "${RUNTIME_VOLUME}:/usr/share/phpmyadmin" \
        -v "${INIT_SCRIPT}:/usr/local/bin/init-phpmyadmin:ro" \
        -v "${MOCK_BIN}:/mock:ro" \
        alpine:latest sh -ceu '
            config=/usr/share/phpmyadmin/config.inc.php
            grep -Fqx "$EXPECTED_HOST_LINE" "$config"
            printf "%s\n" "<?php" "$LEGACY_HOST_LINE" "// $LEGACY_HOST_LINE" > "$config"
            metadata=$(stat -c "%i:%u:%g:%a" "$config")
            [ "${metadata#*:}" = 1000:1000:600 ]
            init-phpmyadmin > /tmp/repair.log
            grep -Fqx "Switched the sample localhost server entry of config.inc.php to mariadb" \
                /tmp/repair.log
            grep -Fqx "$EXPECTED_HOST_LINE" "$config"
            grep -Fqx "// $LEGACY_HOST_LINE" "$config"
            [ "$(stat -c "%i:%u:%g:%a" "$config")" = "$metadata" ]
            init-phpmyadmin > /tmp/rerun.log
            [ "$(cat /tmp/rerun.log)" = "phpMyAdmin is already initialized" ]
            [ ! -e /tmp/curl.log ]
            [ ! -e /tmp/apk.log ]
        ' || fail "the Alpine runtime did not write or repair the database host in place"
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
