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

# --- ordinary PHP spacing and either quote style survive migration ----------
site="$TEST_DIR/quoted"
write_site "$site" /opt/old/php /opt/old/ffmpeg /opt/old/convert /opt/old/mysqldump
python3 - "$site/admin/include/setup.php" <<'PYFIX'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace(']=', '] = ').replace('"', "'").replace('https://example.com', 'https://old.example')
p.write_text(s)
PYFIX
run_config "$site" > "$TEST_DIR/quoted.log" 2>&1 || fail "single-quoted settings must migrate"
# shellcheck disable=SC2016  # Execute the synthetic fixture as PHP.
php -r '
require $argv[1];
$expected = ["project_path" => $argv[2], "project_url" => "https://example.com",
    "memcache_server" => "127.0.0.1", "php_path" => "/usr/local/bin/php",
    "ffmpeg_path" => "/usr/bin/ffmpeg", "image_magick_path" => "/usr/bin/convert",
    "mysqldump_path" => "/usr/bin/mysqldump"];
foreach ($expected as $key => $value) {
    if (($config[$key] ?? null) !== $value) {
        fwrite(STDERR, "Incorrect migrated setting: $key\n"); exit(1);
    }
}
' "$site/admin/include/setup.php" "$site" || fail "PHP must read migrated paths and URL"
cp "$site/admin/include/setup.php" "$TEST_DIR/quoted.first"
run_config "$site" > /dev/null 2>&1 || fail "quoted settings must support a second run"
cmp -s "$site/admin/include/setup.php" "$TEST_DIR/quoted.first" || fail "quoted migration must be idempotent"

# A computed value cannot be rewritten safely and must not report success.
site="$TEST_DIR/computed"
write_site "$site" /usr/bin/php /usr/bin/ffmpeg /usr/bin/convert /usr/bin/mysqldump
python3 - "$site/admin/include/setup.php" <<'PYFIX'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace('"/home/old/www"', '"' + str(p.parents[2]) + '" . "/wrong"')
p.write_text(s)
PYFIX
if run_config "$site" > "$TEST_DIR/computed.log" 2>&1; then
    fail "a computed project_path must stop initialization"
fi
grep -Fq 'Could not configure project_path' "$TEST_DIR/computed.log" || fail "missing project_path diagnostic"

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

# --- .user.ini files naming the old server's directory follow the site -----
site="$TEST_DIR/userini"
write_site "$site" /usr/bin/php /usr/bin/ffmpeg /usr/bin/convert /usr/bin/mysqldump
mkdir -p "$site/admin" "$site/contents/videos"
printf '%s\n' 'auto_prepend_file=/home/old/www/lib/guard.php' 'error_log = "/home/old/www/admin/logs/php.log"' \
    'include_path=".:/home/old/www2/lib"' > "$site/.user.ini"
printf '%s\n' 'auto_prepend_file=/home/old/www/admin/prepend.php' > "$site/admin/.user.ini"
printf '%s\n' 'auto_prepend_file=/home/old/www/lib/guard.php' > "$site/contents/videos/.user.ini"
run_config "$site" > "$TEST_DIR/userini.log" 2>&1 || fail "a site with .user.ini files must be configured"
grep -Fxq "auto_prepend_file=$site/lib/guard.php" "$site/.user.ini" ||
    fail "the prepend file of the root .user.ini must follow the site (got '$(head -n 1 "$site/.user.ini")')"
grep -Fxq "error_log = \"$site/admin/logs/php.log\"" "$site/.user.ini" || fail "a quoted path must follow the site"
grep -Fxq 'include_path=".:/home/old/www2/lib"' "$site/.user.ini" ||
    fail "a path that only starts like the old directory must stay"
grep -Fxq "auto_prepend_file=$site/admin/prepend.php" "$site/admin/.user.ini" || fail "a .user.ini below the root must follow too"
grep -Fxq 'auto_prepend_file=/home/old/www/lib/guard.php' "$site/contents/videos/.user.ini" ||
    fail "contents/, where PHP does not run, must not be walked"
grep -Fq ".user.ini: paths under /home/old/www now under $site" "$TEST_DIR/userini.log" || fail "the rewrite must be announced"
cp "$site/.user.ini" "$TEST_DIR/userini.first"
run_config "$site" > "$TEST_DIR/userini-again.log" 2>&1 || fail "the second run must succeed"
cmp -s "$site/.user.ini" "$TEST_DIR/userini.first" || fail "a second run must leave .user.ini unchanged"
if grep -Fq "now under" "$TEST_DIR/userini-again.log"; then fail "a second run must not announce a rewrite"; fi

# --- plugin settings naming the old server's directory follow the site -----
site="$TEST_DIR/plugins"
write_site "$site" /usr/bin/php /usr/bin/ffmpeg /usr/bin/convert /usr/bin/mysqldump
mkdir -p "$site/admin/data/plugins/backup" "$site/admin/data/plugins/mapper" "$site/admin/data/plugins/other"
# shellcheck disable=SC2016  # PHP code.
php -r '
file_put_contents($argv[1] . "/backup/data.dat", serialize(["backup_folder" => "/home/old/www/admin/data/backup",
    "auto_backup_daily" => 1, "tod" => 0]));
file_put_contents($argv[1] . "/mapper/data.dat", serialize(["map" => ["from" => "/home/old/www", "to" => "/srv/elsewhere"],
    "near" => "/home/old/www2/data", "title" => "moved from /home/old/www"]));
file_put_contents($argv[1] . "/other/data.dat", "not serialized /home/old/www/admin");
' "$site/admin/data/plugins"
cp "$site/admin/data/plugins/other/data.dat" "$TEST_DIR/other.dat"
run_config "$site" > "$TEST_DIR/plugins.log" 2>&1 || fail "a site with plugin settings must be configured"
# shellcheck disable=SC2016  # PHP code.
php -r '
$backup = unserialize(file_get_contents($argv[1] . "/backup/data.dat"));
$mapper = unserialize(file_get_contents($argv[1] . "/mapper/data.dat"));
$expected = [
    [$backup["backup_folder"], $argv[2] . "/admin/data/backup"], [$backup["auto_backup_daily"], 1],
    [$mapper["map"]["from"], $argv[2]], [$mapper["map"]["to"], "/srv/elsewhere"],
    [$mapper["near"], "/home/old/www2/data"], [$mapper["title"], "moved from /home/old/www"],
];
foreach ($expected as [$got, $want]) {
    if ($got !== $want) { fwrite(STDERR, "plugin setting " . var_export($got, true) . " instead of " . var_export($want, true) . "\n"); exit(1); }
}
' "$site/admin/data/plugins" "$site" || fail "plugin settings under the old directory must follow the site, the others stay"
cmp -s "$site/admin/data/plugins/other/data.dat" "$TEST_DIR/other.dat" || fail "a file that is not a serialized array must stay as it is"
grep -Fq "admin/data/plugins/backup/data.dat: settings under /home/old/www now under $site" "$TEST_DIR/plugins.log" ||
    fail "the plugin settings rewrite must be announced"
cp "$site/admin/data/plugins/backup/data.dat" "$TEST_DIR/backup.first"
run_config "$site" > "$TEST_DIR/plugins-again.log" 2>&1 || fail "the second run must succeed"
cmp -s "$site/admin/data/plugins/backup/data.dat" "$TEST_DIR/backup.first" || fail "a second run must leave the plugin settings unchanged"

echo "PASS: binaries of an imported site point inside the containers"
