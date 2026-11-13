#!/bin/bash
# phpMyAdmin keeps the MariaDB password of whoever logs in to it, so it runs
# in a PHP-FPM pool of its own, never as the site's www-data (UID 1000): the
# PHP-FPM entrypoint writes that pool, which listens on a socket only nginx's
# group may open, turns on OPcache's permission check, and takes over the
# tmp/ an earlier release gave to UID 1000, but never the config.inc.php it
# gave that user, which docker/phpmyadmin/init.sh writes anew first.
# tests/integration_php_security.py
# runs the same on a built image; this suite checks the entrypoint's choices
# one by one, and that the image, the initializer and nginx agree on them.
set -euo pipefail

# Run as a namespaced root user so numeric ownership can be verified without
# sudo.
if [ "${KVS_PHPMYADMIN_POOL_TEST_NAMESPACED:-false}" != true ]; then
    command -v unshare >/dev/null 2>&1 || {
        echo "FAIL: unshare is required for the phpMyAdmin pool ownership tests" >&2
        exit 1
    }
    exec unshare --map-auto --map-root-user --net \
        env KVS_PHPMYADMIN_POOL_TEST_NAMESPACED=true bash "$0"
fi

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENTRYPOINT="${ROOT_DIR}/docker/php/docker-entrypoint.sh"
PHP_DOCKERFILE="${ROOT_DIR}/docker/php/Dockerfile"
INIT_SCRIPT="${ROOT_DIR}/docker/phpmyadmin/init.sh"
TEST_DIR=$(mktemp -d /tmp/kvs-phpmyadmin-pool.XXXXXX)
SOCKET_PATH=/usr/share/phpmyadmin/.kvs-fpm/php-fpm.sock

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || fail "the ownership test did not enter its user namespace"

# The two functions of the entrypoint, with every path moved under the case.
make_case() {
    local case_dir="$1"

    rm -rf "$case_dir"
    mkdir -p "${case_dir}/fpm.d" "${case_dir}/conf.d" "${case_dir}/bin"
    awk '/^prepare_phpmyadmin_files\(\) \{$/, /^}$/; /^apply_phpmyadmin_pool\(\) \{$/, /^}$/' \
        "$ENTRYPOINT" |
        sed -e "s|/usr/share/phpmyadmin|${case_dir}/phpmyadmin|g" \
            -e "s|/usr/local/etc/php-fpm.d|${case_dir}/fpm.d|g" \
            -e "s|/usr/local/etc/php/conf.d|${case_dir}/conf.d|g" \
            > "${case_dir}/functions.sh"
    grep -q '^apply_phpmyadmin_pool() {$' "${case_dir}/functions.sh" ||
        fail "apply_phpmyadmin_pool is missing from the entrypoint"
    # The image has the kvs-phpmyadmin user, this host does not.
    cat > "${case_dir}/bin/id" << 'EOF'
#!/bin/sh
[ -z "${TEST_ID_FAILS:-}" ] || exit 1
case "$1 $2" in
    "-u kvs-phpmyadmin"|"-g kvs-phpmyadmin") echo 999 ;;
    *) exit 1 ;;
esac
EOF
    chmod 0755 "${case_dir}/bin/id"
}

# A phpmyadmin-data volume as an earlier release left it: root's code,
# config.inc.php and tmp/ for the site's user, a template planted in tmp/.
seed_legacy_volume() {
    local directory="$1/phpmyadmin"

    mkdir -p "${directory}/tmp/twig/aa"
    printf '%s\n' "<?php \$cfg['blowfish_secret'] = 'kept-secret';" > "${directory}/config.inc.php"  # pragma: allowlist secret
    printf '%s\n' '<?php echo "phpMyAdmin";' > "${directory}/index.php"
    printf '%s\n' '<?php echo "planted";' > "${directory}/tmp/twig/aa/planted.php"
    chown 0:0 "$directory" "${directory}/index.php"
    chmod 0755 "$directory"
    chown -R 1000:1000 "${directory}/config.inc.php" "${directory}/tmp"
    chmod 0600 "${directory}/config.inc.php"
    chmod 0700 "${directory}/tmp"
}

# The same volume once phpmyadmin-init of this release wrote config.inc.php
# anew, root's and read by phpMyAdmin's group: tmp/ is still the site's.
seed_initialized_volume() {
    local directory="$1/phpmyadmin"

    seed_legacy_volume "$1"
    printf '%s\n' "<?php \$cfg['blowfish_secret'] = 'new-secret';" > "${directory}/config.inc.php"  # pragma: allowlist secret
    chown 0:999 "${directory}/config.inc.php"
    chmod 0640 "${directory}/config.inc.php"
}

run_pool() {
    local case_dir="$1"

    # shellcheck disable=SC2016  # The inner shell expands $1.
    env PATH="${case_dir}/bin:${PATH}" TEST_ID_FAILS="${TEST_ID_FAILS:-}" \
        bash -c 'set -e; source "$1"; apply_phpmyadmin_pool' sh "${case_dir}/functions.sh" \
        > "${case_dir}/stdout" 2> "${case_dir}/stderr" ||
        fail "the entrypoint stopped: $(cat "${case_dir}/stderr")"
}

owners() {
    stat -c '%u:%g:%a' "$1"
}

assert_pool_written() {
    local case_dir="$1"
    local pool="${case_dir}/fpm.d/zz-kvs-phpmyadmin.conf"
    local key
    local expected

    [ -f "$pool" ] || fail "no phpMyAdmin pool was written: $(cat "${case_dir}/stderr")"
    # Every setting the pool must have, as PHP-FPM reads it.
    while IFS='|' read -r key expected; do
        [ "$(sed -n "s/^${key} = //p" "$pool")" = "$expected" ] ||
            fail "the phpMyAdmin pool must set ${key} = ${expected}: $(grep -F "${key} =" "$pool")"
    done << EOF
user|kvs-phpmyadmin
group|kvs-phpmyadmin
listen|${case_dir}/phpmyadmin/.kvs-fpm/php-fpm.sock
listen.group|101
listen.mode|0660
security.limit_extensions|.php
php_admin_value\[session.save_path\]|/var/lib/kvs-phpmyadmin/sessions
php_admin_value\[upload_tmp_dir\]|/var/lib/kvs-phpmyadmin/tmp
php_admin_value\[sys_temp_dir\]|/var/lib/kvs-phpmyadmin/tmp
EOF
    [ "$(grep -c '^\[' "$pool")" = 1 ] || fail "the phpMyAdmin pool file must hold one pool"
    grep -Fxq '[phpmyadmin]' "$pool" || fail "the phpMyAdmin pool file must hold the phpmyadmin pool"
    [ "$(grep -c '^listen = ' "$pool")" = 1 ] || fail "the phpMyAdmin pool must listen once"
    [ "$(grep -v '^;' "${case_dir}/conf.d/zz-kvs-phpmyadmin.ini")" = 'opcache.validate_permission = 1' ] ||
        fail "OPcache must check the permission of a cached script: $(cat "${case_dir}/conf.d/zz-kvs-phpmyadmin.ini" 2>&1)"
    grep -Fxq 'phpMyAdmin runs in its own PHP-FPM pool as kvs-phpmyadmin' "${case_dir}/stdout" ||
        fail "the pool was started without saying so: $(cat "${case_dir}/stdout")"
}

assert_no_pool() {
    local case_dir="$1"

    [ ! -e "${case_dir}/fpm.d/zz-kvs-phpmyadmin.conf" ] ||
        fail "a phpMyAdmin pool was written: $(cat "${case_dir}/stdout" "${case_dir}/stderr")"
    [ ! -e "${case_dir}/conf.d/zz-kvs-phpmyadmin.ini" ] ||
        fail "the OPcache setting of the pool was written without the pool"
}

# --- the config.inc.php of an earlier release is not served ----------------
# The site's PHP could write it: code it added would run in phpMyAdmin's pool.
# Root alone may have written the one the pool reads, and only phpmyadmin-init
# can tell an earlier release's file and write it anew.
config_refusal="config.inc.php may have been written by another user than root, as earlier releases let the site's PHP do, so phpMyAdmin is not served until phpmyadmin-init writes it anew: run setup.sh, or docker compose --profile setup run --rm phpmyadmin-init, then docker compose restart php-fpm"
for config_state in legacy root-group-writable root-world-writable other-user; do
    case_dir="${TEST_DIR}/config-${config_state}"
    make_case "$case_dir"
    seed_legacy_volume "$case_dir"
    directory="${case_dir}/phpmyadmin"
    case "$config_state" in
        root-group-writable) chown 0:1000 "${directory}/config.inc.php"; chmod 0660 "${directory}/config.inc.php" ;;
        root-world-writable) chown 0:0 "${directory}/config.inc.php"; chmod 0646 "${directory}/config.inc.php" ;;
        other-user) chown 33:33 "${directory}/config.inc.php"; chmod 0644 "${directory}/config.inc.php" ;;
    esac
    cp "${directory}/config.inc.php" "${case_dir}/config.before"
    config_before=$(stat -c '%i:%u:%g:%a' "${directory}/config.inc.php")
    run_pool "$case_dir"
    assert_no_pool "$case_dir"
    grep -Fxq "WARNING: ${directory}/${config_refusal}" "${case_dir}/stderr" ||
        fail "${config_state}: phpMyAdmin was left out without saying why: $(cat "${case_dir}/stderr")"
    { [ "$(stat -c '%i:%u:%g:%a' "${directory}/config.inc.php")" = "$config_before" ] &&
        cmp -s "${case_dir}/config.before" "${directory}/config.inc.php"; } ||
        fail "${config_state}: the entrypoint took config.inc.php over, so phpmyadmin-init could no longer tell it apart"
done

# --- an earlier release's volume is taken over, its configuration written ---
case_dir="${TEST_DIR}/legacy"
make_case "$case_dir"
seed_initialized_volume "$case_dir"
directory="${case_dir}/phpmyadmin"
cp "${directory}/config.inc.php" "${case_dir}/config.before"
config_inode=$(stat -c '%i' "${directory}/config.inc.php")
run_pool "$case_dir"
assert_pool_written "$case_dir"
[ ! -s "${case_dir}/stderr" ] || fail "taking over a volume printed: $(cat "${case_dir}/stderr")"
[ "$(stat -c '%i' "${directory}/config.inc.php"):$(owners "${directory}/config.inc.php")" = "${config_inode}:0:999:640" ] ||
    fail "config.inc.php must stay the same file, root's, read by phpMyAdmin's user only: $(owners "${directory}/config.inc.php")"
cmp -s "${case_dir}/config.before" "${directory}/config.inc.php" ||
    fail "taking over the volume changed the configuration"
[ "$(owners "${directory}/tmp")" = 999:999:700 ] ||
    fail "tmp/ must be private to phpMyAdmin's user: $(owners "${directory}/tmp")"
[ -z "$(find "${directory}/tmp" -mindepth 1 -print -quit)" ] ||
    fail "the templates the site's user could write in tmp/ were kept"
[ "$(owners "$directory")" = 0:0:755 ] || fail "the phpMyAdmin directory must stay root's"
[ -d "${directory}/.kvs-fpm" ] && [ ! -L "${directory}/.kvs-fpm" ] &&
    [ "$(owners "${directory}/.kvs-fpm")" = 0:0:755 ] ||
    fail "the socket directory must be root's, so the site's user cannot put a socket there"
[ "$(owners "${directory}/index.php")" = 0:0:644 ] || fail "the phpMyAdmin code changed owner"

# A second start changes nothing: tmp/ is phpMyAdmin's and keeps what it holds.
mkdir -p "${directory}/tmp/twig"
printf '%s\n' '<?php' > "${directory}/tmp/twig/cache.php"
chown -R 999:999 "${directory}/tmp/twig"
run_pool "$case_dir"
assert_pool_written "$case_dir"
[ -s "${directory}/tmp/twig/cache.php" ] || fail "a restart emptied the cache phpMyAdmin wrote itself"

# A configuration root wrote by hand, readable by all, is root's still.
case_dir="${TEST_DIR}/root-config"
make_case "$case_dir"
seed_initialized_volume "$case_dir"
directory="${case_dir}/phpmyadmin"
chown 0:0 "${directory}/config.inc.php"
chmod 0644 "${directory}/config.inc.php"
run_pool "$case_dir"
assert_pool_written "$case_dir"
[ "$(owners "${directory}/config.inc.php")" = 0:999:640 ] ||
    fail "a config.inc.php root alone wrote was not given to phpMyAdmin's group: $(owners "${directory}/config.inc.php")"

# --- what is not root's own directory is put back ---------------------------
case_dir="${TEST_DIR}/planted"
make_case "$case_dir"
seed_initialized_volume "$case_dir"
directory="${case_dir}/phpmyadmin"
mkdir -p "${case_dir}/elsewhere"
printf '%s\n' keep > "${case_dir}/elsewhere/file"
chown -R 1000:1000 "${case_dir}/elsewhere"
ln -s "${case_dir}/elsewhere" "${directory}/.kvs-fpm"
rm -rf "${directory}/tmp"
ln -s "${case_dir}/elsewhere" "${directory}/tmp"
chown 1000:1000 "$directory"
chmod 0775 "$directory"
run_pool "$case_dir"
assert_pool_written "$case_dir"
[ "$(owners "$directory")" = 0:0:755 ] || fail "a phpMyAdmin directory the site's user could write was kept"
[ -d "${directory}/.kvs-fpm" ] && [ ! -L "${directory}/.kvs-fpm" ] ||
    fail "a link in place of the socket directory was kept"
[ -d "${directory}/tmp" ] && [ ! -L "${directory}/tmp" ] && [ "$(owners "${directory}/tmp")" = 999:999:700 ] ||
    fail "a link in place of tmp/ was kept"
[ "$(cat "${case_dir}/elsewhere/file")" = keep ] && [ "$(owners "${case_dir}/elsewhere")" = 1000:1000:755 ] ||
    fail "the target of a link was changed"

# --- no phpMyAdmin, no pool --------------------------------------------------
case_dir="${TEST_DIR}/unmounted"
make_case "$case_dir"
printf '%s\n' stale > "${case_dir}/fpm.d/zz-kvs-phpmyadmin.conf"
printf '%s\n' stale > "${case_dir}/conf.d/zz-kvs-phpmyadmin.ini"
run_pool "$case_dir"
assert_no_pool "$case_dir"
grep -Fxq "phpMyAdmin is not mounted on ${case_dir}/phpmyadmin, so its PHP-FPM pool is not started" \
    "${case_dir}/stdout" || fail "a missing phpMyAdmin volume was not reported: $(cat "${case_dir}/stdout")"
[ ! -s "${case_dir}/stderr" ] || fail "a missing phpMyAdmin volume is no error: $(cat "${case_dir}/stderr")"

# --- files that cannot change hands keep phpMyAdmin out, PHP-FPM up ----------
for failure in id chown config-link; do
    case_dir="${TEST_DIR}/failure-${failure}"
    make_case "$case_dir"
    seed_legacy_volume "$case_dir"
    directory="${case_dir}/phpmyadmin"
    case "$failure" in
        id)
            TEST_ID_FAILS=1 run_pool "$case_dir"
            ;;
        chown)
            printf '%s\n' '#!/bin/sh' 'exit 1' > "${case_dir}/bin/chown"
            chmod 0755 "${case_dir}/bin/chown"
            run_pool "$case_dir"
            ;;
        config-link)
            mv "${directory}/config.inc.php" "${case_dir}/config.real"
            ln -s "${case_dir}/config.real" "${directory}/config.inc.php"
            run_pool "$case_dir"
            [ "$(owners "${case_dir}/config.real")" = 1000:1000:600 ] ||
                fail "the target of a config.inc.php link was changed"
            ;;
    esac
    assert_no_pool "$case_dir"
    grep -Fxq "WARNING: cannot give ${directory} to kvs-phpmyadmin, so phpMyAdmin is not served" \
        "${case_dir}/stderr" || fail "${failure}: the pool was left out without saying why: $(cat "${case_dir}/stderr")"
done

# --- the entrypoint runs it for PHP-FPM only ---------------------------------
grep -Fq "$(printf '        configure_php_fpm\n        apply_phpmyadmin_pool\n')" "$ENTRYPOINT" ||
    fail "the entrypoint must write the phpMyAdmin pool when it starts PHP-FPM"
[ "$(grep -c '^ *apply_phpmyadmin_pool$' "$ENTRYPOINT")" = 1 ] ||
    fail "the entrypoint must write the phpMyAdmin pool once"

# --- the image, the initializer and nginx agree ------------------------------
grep -Fq 'groupadd --system --gid 999 kvs-phpmyadmin' "$PHP_DOCKERFILE" ||
    fail "the PHP image must create the kvs-phpmyadmin group with GID 999"
grep -Fq 'useradd --system --uid 999 --gid 999 ' "$PHP_DOCKERFILE" ||
    fail "the PHP image must create kvs-phpmyadmin with UID 999"
grep -Fxq 'RUNTIME_UID=999' "$INIT_SCRIPT" ||
    fail "init.sh must give tmp/ to the UID of kvs-phpmyadmin"
grep -Fxq 'RUNTIME_GID=999' "$INIT_SCRIPT" ||
    fail "init.sh must give the phpMyAdmin files to the GID of kvs-phpmyadmin"
# shellcheck disable=SC2016  # The literal line of init.sh.
grep -Fxq 'SOCKET_DIR="${TARGET_DIR}/.kvs-fpm"' "$INIT_SCRIPT" ||
    fail "init.sh must leave the socket directory of the entrypoint in place"
# nginx's workers run as the nginx user of its image, which the pool lets in
# by its GID.
grep -Eq '^user +nginx;$' "${ROOT_DIR}/docker/nginx/nginx.conf" ||
    fail "nginx's workers must run as the nginx user (GID 101) the pool lets in"
for template in "${ROOT_DIR}/conf/nginx/templates/kvs.conf.tpl" \
    "${ROOT_DIR}/docker/multi-site/nginx/kvs-caddy.conf.template"; do
    php_location=$(awk '/location ~ \^\/phpmyadmin\/\(\.\+\\\.php\)\$ \{/, /^        }$/' "$template")
    [ -n "$php_location" ] || fail "${template}: no phpMyAdmin PHP location"
    [ "$(printf '%s\n' "$php_location" | sed -n 's/^ *fastcgi_pass \(.*\);$/\1/p')" = "unix:${SOCKET_PATH}" ] ||
        fail "${template}: phpMyAdmin must go to its own pool's socket: $(printf '%s\n' "$php_location" | grep fastcgi_pass)"
done
# The volume holds the socket: PHP-FPM writes it, nginx only opens it.
for compose_file in "${ROOT_DIR}/docker/docker-compose.yml" \
    "${ROOT_DIR}/docker/multi-site/docker-compose.site.yml.template"; do
    for service in nginx php-fpm; do
        expected="- phpmyadmin-data:/usr/share/phpmyadmin"
        if [ "$service" = nginx ]; then
            expected="${expected}:ro"
        fi
        awk -v name="  ${service}:" '$0 == name { found = 1; next } found && /^  [^ ]/ { exit } found' \
            "$compose_file" | sed 's/^ *//' | grep -Fxq -- "$expected" ||
            fail "${compose_file}: ${service} must mount ${expected#- }"
    done
done

echo "PASS: phpMyAdmin runs in its own PHP-FPM pool"
