#!/bin/bash
# A site imported from another server keeps, in admin/include/setup.php,
# the binaries where that server had them. KVS runs every background task
# through php_path (KvsUtilities::exec_php), every screenshot through
# image_magick_path, conversions through ffmpeg_path and backups through
# mysqldump_path, so each of them must point inside the PHP and cron
# images once the site runs in the containers. Paths the images ship stay
# as they are, a key the file does not set is not invented.
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/kvs-init-binary-paths.XXXXXX)

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat > "$TEST_DIR/common.sh" <<'EOF'
KVS_PATH=${TEST_KVS_PATH:?}
log_info() { printf '[INFO] %s\n' "$1"; }
log_warn() { printf '[WARN] %s\n' "$1"; }
log_error() { printf '[ERROR] %s\n' "$1" >&2; }
get_project_url() { printf 'https://%s\n' "$DOMAIN"; }
EOF
sed "s|source /init/lib/common.sh|source ${TEST_DIR}/common.sh|" \
    "$ROOT_DIR/docker/init/docker-entrypoint.d/10-config-php.sh" > "$TEST_DIR/10-config-php.sh"

# The value of a $config key as PHP reads it.
config_value() {
    sed -n -E "s/^[[:space:]]*\\\$config[[:space:]]*\\[[[:space:]]*'$2'[[:space:]]*\\][[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\\1/p" "$1" | head -n 1
}

# write_site <dir> <php> <ffmpeg> <convert> <mysqldump>: a site as KVS
# writes setup.php, with the binaries of the server it comes from.
write_site() {
    mkdir -p "$1/admin/include"
    cat > "$1/admin/include/setup.php" <<PHP
<?php
\$config['project_path']="/home/old/www";
\$config['project_url']="https://example.com";
\$config['project_title']="Old Tube";

\$config['php_path']="$2";
\$config['ffmpeg_path']="$3";
\$config['image_magick_path']="$4";
\$config['mysqldump_path']="$5";

\$config['memcache_server']="localhost";
\$config['tables_prefix']="ktvs_";
PHP
    cat > "$1/admin/include/setup_db.php" <<'PHP'
<?php
define('DB_HOST','localhost');
define('DB_LOGIN','old_user');
define('DB_PASS','old-password');
define('DB_DEVICE','old_database');
PHP
}

run_config() {
    TEST_KVS_PATH="$1" DOMAIN=example.com MARIADB_PASSWORD=test-password USE_WWW=false \
        bash "$TEST_DIR/10-config-php.sh"
}

# --- binaries of a cPanel or CloudLinux server are pointed inside the images
site="$TEST_DIR/imported"
write_site "$site" /opt/alt/php74/usr/bin/php /home/old/bin/ffmpeg /opt/im/bin/convert /usr/local/mysql/bin/mysqldump
run_config "$site" > "$TEST_DIR/imported.log" 2>&1 || fail "the configuration of an imported site must succeed"
setup_php="$site/admin/include/setup.php"
[ "$(config_value "$setup_php" php_path)" = /usr/local/bin/php ] ||
    fail "php_path must point at the PHP of the images (got '$(config_value "$setup_php" php_path)')"
[ "$(config_value "$setup_php" ffmpeg_path)" = /usr/bin/ffmpeg ] ||
    fail "ffmpeg_path must point at the ffmpeg of the images (got '$(config_value "$setup_php" ffmpeg_path)')"
[ "$(config_value "$setup_php" image_magick_path)" = /usr/bin/convert ] ||
    fail "image_magick_path must point at the convert of the images (got '$(config_value "$setup_php" image_magick_path)')"
[ "$(config_value "$setup_php" mysqldump_path)" = /usr/bin/mysqldump ] ||
    fail "mysqldump_path must point at the mysqldump of the images (got '$(config_value "$setup_php" mysqldump_path)')"
for label in "php path: /opt/alt/php74/usr/bin/php" "ffmpeg path: /home/old/bin/ffmpeg" \
    "image_magick path: /opt/im/bin/convert" "mysqldump path: /usr/local/mysql/bin/mysqldump"; do
    grep -Fq "$label is not in the container" "$TEST_DIR/imported.log" ||
        fail "the replaced path must be announced ($label)"
done
[ "$(config_value "$setup_php" project_path)" = "$site" ] || fail "project_path must still be adopted"

# --- paths the images ship, at either of their locations, are kept ---------
site="$TEST_DIR/container"
write_site "$site" /usr/bin/php /usr/local/bin/ffmpeg /usr/local/bin/convert /usr/bin/mariadb-dump
run_config "$site" > "$TEST_DIR/container.log" 2>&1 || fail "paths inside the images must be accepted"
setup_php="$site/admin/include/setup.php"
[ "$(config_value "$setup_php" php_path)" = /usr/bin/php ] || fail "/usr/bin/php is in the images and must stay"
[ "$(config_value "$setup_php" ffmpeg_path)" = /usr/local/bin/ffmpeg ] || fail "/usr/local/bin/ffmpeg must stay"
[ "$(config_value "$setup_php" image_magick_path)" = /usr/local/bin/convert ] || fail "/usr/local/bin/convert must stay"
[ "$(config_value "$setup_php" mysqldump_path)" = /usr/bin/mariadb-dump ] || fail "/usr/bin/mariadb-dump must stay"
if grep -Fq "is not in the container" "$TEST_DIR/container.log"; then
    fail "a path inside the images must not be reported as replaced"
fi

# --- a hand-edited line with spaces is reached too, a re-run changes nothing
site="$TEST_DIR/spaced"
write_site "$site" /usr/bin/php /usr/bin/ffmpeg /usr/bin/convert /usr/bin/mysqldump
sed -i "s|^\$config\['php_path'\]=.*|\$config['php_path'] = \"/usr/bin/php8.2\";|" "$site/admin/include/setup.php"
run_config "$site" > /dev/null 2>&1 || fail "a spaced php_path line must be handled"
setup_php="$site/admin/include/setup.php"
[ "$(config_value "$setup_php" php_path)" = /usr/local/bin/php ] ||
    fail "a spaced php_path line must be rewritten (got '$(config_value "$setup_php" php_path)')"
cp "$setup_php" "$TEST_DIR/spaced.first"
run_config "$site" > /dev/null 2>&1 || fail "the second run must succeed"
cmp -s "$setup_php" "$TEST_DIR/spaced.first" || fail "a second run must leave setup.php unchanged"

# --- a key the file does not set is left out --------------------------------
site="$TEST_DIR/without"
write_site "$site" /usr/bin/php /usr/bin/ffmpeg /usr/bin/convert /usr/bin/mysqldump
sed -i "/mysqldump_path/d" "$site/admin/include/setup.php"
run_config "$site" > /dev/null 2>&1 || fail "a setup.php without mysqldump_path must be accepted"
if grep -q "mysqldump_path" "$site/admin/include/setup.php"; then
    fail "a key the site does not set must not be invented"
fi

# --- the debug switches of the old server are turned off, once -------------
site="$TEST_DIR/debug"
write_site "$site" /usr/bin/php /usr/bin/ffmpeg /usr/bin/convert /usr/bin/mysqldump
printf '%s\n' "/* for dev debugging */" "\$config['enable_debug']=\"true\";" "\$config['sql_debug']='true';" >> "$site/admin/include/setup.php"
run_config "$site" > "$TEST_DIR/debug.log" 2>&1 || fail "a site with the debug switches on must be configured"
setup_php="$site/admin/include/setup.php"
[ "$(config_value "$setup_php" enable_debug)" = false ] ||
    fail "enable_debug must be turned off (got '$(config_value "$setup_php" enable_debug)')"
[ "$(config_value "$setup_php" sql_debug)" = false ] ||
    fail "sql_debug, the query log switch, must be turned off whatever its quotes (got '$(config_value "$setup_php" sql_debug)')"
grep -Fq "KVS enable_debug was on in setup.php: turned off" "$TEST_DIR/debug.log" ||
    fail "the enable_debug switch-off must be announced"
grep -Fq "KVS sql_debug was on in setup.php: turned off" "$TEST_DIR/debug.log" ||
    fail "the sql_debug switch-off must be announced"
run_config "$site" > "$TEST_DIR/debug-again.log" 2>&1 || fail "the second run must succeed"
if grep -Fq "was on in setup.php: turned off" "$TEST_DIR/debug-again.log"; then
    fail "a second run must not announce a switch-off again"
fi
site="$TEST_DIR/nodebug"
write_site "$site" /usr/bin/php /usr/bin/ffmpeg /usr/bin/convert /usr/bin/mysqldump
run_config "$site" > /dev/null 2>&1 || fail "a setup.php without the debug switches must be accepted"
if grep -q "enable_debug\|sql_debug" "$site/admin/include/setup.php"; then
    fail "a debug switch must not be invented"
fi

echo "PASS: binaries of an imported site point inside the containers"
