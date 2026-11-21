#!/bin/bash
# Observe the arguments of the editors used on temporary fixture files.
set -euo pipefail

if [ "$(id -u)" != 0 ]; then
    exec unshare --map-auto --map-root-user --net bash "$0"
fi
root=$(cd "$(dirname "$0")/.." && pwd)
# The PHP reader runs as another uid and must be able to traverse the parent.
work=$(mktemp -d /tmp/kvs-config-arguments.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/site/admin/include"
export EDIT_LOG="$work/arguments" KVS_PATH="$work/site"
db_file="$KVS_PATH/admin/include/setup_db.php"
for tool in sed grep php; do
    # shellcheck disable=SC2016  # Expanded by the wrapper.
    printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "$EDIT_LOG"\nexec "%s" "$@"\n' \
        "$(command -v "$tool")" > "$work/bin/$tool"
done
cat > "$work/bin/chown" <<'SH'
#!/bin/sh
[ "$1" = 1000:1000 ] && [ "$2" != "$KVS_PATH/admin/include/setup_db.php" ] &&
    [ "$(stat -c %a "$2")" = 600 ] || exit 1
[ "${DENY_CHOWN:-false}" = false ] || exit 1
exec /usr/bin/chown "$@"
SH
chmod +x "$work/bin/"*
printf 'log_info() { :; }\nlog_warn() { :; }\nlog_error() { echo "$*" >&2; }\n' > "$work/common"
sed "s|source /init/lib/common.sh|source $work/common|" \
    "$root/docker/init/docker-entrypoint.d/10-config-php.sh" > "$work/config.sh"
cat > "$db_file" <<'PHP'
<?php
define('DB_HOST','localhost');
define('DB_LOGIN','old');
define('DB_PASS','old');
define('DB_DEVICE','old');
PHP

export DOMAIN=site.test
export PATH="$work/bin:$PATH"
export MARIADB_PASSWORD="fixtureMarker&\\'#|"
chmod 755 "$work"
chmod 644 "$db_file"
mv "$db_file" "$work/template.php"
ln -s ../../../template.php "$db_file"
cp "$work/template.php" "$work/original"
sed -i "s/'DB_DEVICE','old'/'DB_DEVICE',getenv('DOMAIN')/" "$work/template.php"
cp "$work/template.php" "$work/invalid"
if bash "$work/config.sh" > "$work/db.log" 2>&1; then
    echo "FAIL: computed database settings accepted" >&2
    exit 1
fi
grep -Fq 'does not define DB_DEVICE' "$work/db.log"
cmp "$work/template.php" "$work/invalid"
[ -L "$db_file" ] && [ "$(stat -c %u:%g:%a "$work/template.php")" = 0:0:644 ] || exit 1
cd "${db_file%/*}"
setpriv --reuid=1000 --regid=1000 --clear-groups /usr/bin/test -r setup_db.php
rm "$db_file"
cp "$work/invalid" "$db_file"
if bash "$work/config.sh" > "$work/db.log" 2>&1; then
    echo "FAIL: invalid regular configuration accepted" >&2
    exit 1
fi
cmp "$db_file" "$work/invalid"
[ "$(stat -c %u:%g:%a "$db_file")" = 0:0:644 ]
setpriv --reuid=1000 --regid=1000 --clear-groups /usr/bin/test -r setup_db.php
rm "$db_file"
ln -s ../../../template.php "$db_file"

cp "$work/original" "$work/template.php"
if DENY_CHOWN=true bash "$work/config.sh" > "$work/db.log" 2>&1; then
    echo "FAIL: published without the requested ownership" >&2
    exit 1
fi
[ -L "$db_file" ] && cmp "$work/original" "$work/template.php" || exit 1
[ "$(stat -c %a "$work/template.php")" = 644 ]
[ "$(ls -A "${db_file%/*}")" = setup_db.php ]

for MARIADB_PASSWORD in "$MARIADB_PASSWORD" $'fixtureMarker\r\none\n' $'fixtureMarker\n\n'; do
    (umask 0777; bash "$work/config.sh") > "$work/db.log"
    [ ! -L "$db_file" ] && [ "$(stat -c %u:%g:%a "$db_file")" = 1000:1000:600 ] || exit 1
    # shellcheck disable=SC2016
    setpriv --reuid=1000 --regid=1000 --clear-groups /usr/bin/php -r \
        'require $argv[1]; exit(DB_PASS === getenv("MARIADB_PASSWORD") ? 0 : 1);' setup_db.php
done
sed -i '1s/<?php/<?/' "$db_file"
bash "$work/config.sh" > "$work/db.log"
# shellcheck disable=SC2016
setpriv --reuid=1000 --regid=1000 --clear-groups /usr/bin/php -d short_open_tag=1 -r \
    'require $argv[1]; exit(DB_PASS === getenv("MARIADB_PASSWORD") ? 0 : 1);' setup_db.php
cmp "$work/template.php" "$work/original"
[ "$(stat -c %u:%g:%a "$work/template.php")" = 0:0:644 ]
if /usr/bin/grep -Fq fixtureMarker "$EDIT_LOG"; then
    echo "FAIL: the database password was passed to an editor as an argument" >&2
    exit 1
fi

PATH=${PATH#*:}
# Run the same configuration writer used for fresh and legacy installs.
sed '/^if is_initialized; then/,$d' "$root/docker/phpmyadmin/init.sh" > "$work/pma.sh"
# shellcheck disable=SC2016  # Expanded by the configuration writer.
echo 'write_config_from_sample "$1" "$2"' >> "$work/pma.sh"
cat > "$work/sample" <<'PHP'
$cfg['blowfish_secret'] = '';
$cfg['Servers'][$i]['host'] = 'localhost';
PHP
: > "$EDIT_LOG"
PATH="$work/bin:$PATH" sh "$work/pma.sh" "$work/sample" "$work/config.inc.php"
secret=$(sed -n "s/^.*blowfish_secret.*= '\([A-Za-z0-9]\{32\}\)';$/\1/p" "$work/config.inc.php")
[ "${#secret}" = 32 ] || { echo "FAIL: missing application secret" >&2; exit 1; }
if grep -Fq "$secret" "$EDIT_LOG"; then
    echo "FAIL: the application secret was passed to an editor as an argument" >&2
    exit 1
fi
sed '/blowfish_secret/d' "$work/sample" > "$work/missing"
if PATH="$work/bin:$PATH" sh "$work/pma.sh" "$work/missing" "$work/config.inc.php" > "$work/missing.log" 2>&1; then
    echo "FAIL: configuration without an application secret was accepted" >&2
    exit 1
fi
grep -Fq 'Could not write the phpMyAdmin application secret' "$work/missing.log"
echo "PASS: both configuration writers keep secrets out of editor arguments"
