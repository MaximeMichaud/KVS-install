#!/bin/bash
# A headless import from a local site directory (IMPORT_SITE_DIR and
# IMPORT_DB_DUMP) with no KVS archive at hand: the site's own
# _INSTALL/nginx_config.txt is found, IMPORT_NGINX_REWRITES is accepted, and
# the setup goes on to MariaDB with the site in place. The rewrites used to
# be looked for in /var/www/<domain> before the copy: the site's own rules
# were missed, and explicit ones written there first made the copy refuse a
# directory that was no longer empty. The real docker/setup.sh runs with
# strict stubs; database_wait_ready ends it.
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /tmp/kvs-directory-import.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
cat > "$fixture/bin/docker" <<'SH'
#!/bin/bash
printf 'docker %s\n' "$*" >> "$CALLS"
case "$*" in
    --version) echo 'Docker version 29.1.0, build stub' ;;
    'compose version') echo 'Docker Compose version v2.40.3' ;;
    info*|ps*|'volume ls'*|'compose config'|stop*|rm*) exit 0 ;;
    'compose build'*) echo build >> "$CALLS" ;;
    'compose up -d --force-recreate mariadb') echo mariadb-start >> "$CALLS" ;;
    *) echo "unexpected:docker $*" >> "$CALLS"; exit 97 ;;
esac
SH
cat > "$fixture/bin/blocked" <<'SH'
#!/bin/bash
printf 'unexpected:%s %s\n' "$(basename "$0")" "$*" >> "$CALLS"
exit 97
SH
cat > "$fixture/bin/openssl" <<'SH'
#!/bin/bash
[ "$1" != dhparam ] || exit 97
exec /usr/bin/openssl "$@"
SH
printf '#!/bin/bash\nexit 7\n' > "$fixture/bin/curl"
printf '#!/bin/bash\nexit 0\n' > "$fixture/bin/ss"
printf '#!/bin/bash\nexit 2\n' > "$fixture/bin/getent"
printf '#!/bin/bash\nexit 1\n' > "$fixture/bin/ufw"
chmod +x "$fixture/bin/"*
for tool in sudo apt apt-get systemctl ssh scp; do
    ln -s blocked "$fixture/bin/$tool"
done

# run_case <name> <with _INSTALL: yes|no> [IMPORT_NGINX_REWRITES content]
run_case() {
    local dir=$fixture/$1
    mkdir -p "$dir/logs" "$dir/www" "$dir/oldsite/admin/include"
    cp -a "$root/docker" "$dir/docker"
    cp "$root/kvs-export.sh" "$dir/kvs-export.sh"
    python3 - "$dir/docker/setup.sh" "$dir" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
assert t.count('if [ "$EUID" -ne 0 ]; then') == 1
t = t.replace('if [ "$EUID" -ne 0 ]; then', 'if false; then')
t = t.replace('/opt/kvs/logs', sys.argv[2] + '/logs').replace('/var/www/', sys.argv[2] + '/www/')
p.write_text(t)
PY
    cat >> "$dir/docker/lib/database.sh" <<'SH'
database_configure_resources() { :; }
database_import_jobs() { echo 2; }
database_wait_ready() { echo wait >> "$CALLS"; exit 42; }
SH
    : > "$dir/docker/nginx/dhparam.pem"
    cat > "$dir/oldsite/admin/include/setup.php" <<'PHP'
<?php
$config['project_path']="/var/www/old.example.com";
$config['project_url']="https://old.example.com";
$config['tables_prefix']="ktvs_";
PHP
    echo '<?php' > "$dir/oldsite/admin/include/setup_db.php"
    printf "<?php\n\$config['project_version']='7.0.2';\n" > "$dir/oldsite/admin/include/version.php"
    echo '<?php // plain PHP' > "$dir/oldsite/admin/include/functions_base.php"
    if [ "$2" = yes ]; then
        mkdir "$dir/oldsite/_INSTALL"
        printf 'rewrite ^/videos/$ /videos.php last;\n' > "$dir/oldsite/_INSTALL/nginx_config.txt"
    fi
    local rules=
    if [ -n "${3:-}" ]; then
        rules=$dir/rules.conf
        printf '%s\n' "$3" > "$rules"
    fi
    cat > "$dir/dump.sql" <<'SQL'
CREATE TABLE `ktvs_options` (`variable` varchar(100) NOT NULL, `value` text, PRIMARY KEY (`variable`));
INSERT INTO `ktvs_options` VALUES ('INITIAL_VERSION','7.0.2');
-- Dump completed on 2026-09-29 12:00:00
SQL
    (
        cd "$dir/docker" || exit 1
        export CALLS="$dir/calls" PATH="$fixture/bin:/usr/bin:/bin"
        export HEADLESS=y PREFLIGHT_BYPASS=y SSL_CHOICE=3 GEOIP_CHOICE=2 MANTICORE_CHOICE=2
        export DNS_CHOICE=2 CACHE_CHOICE=1 DB_CHOICE=1 IONCUBE_CHOICE=1
        export DOMAIN=dir.example.com EMAIL=admin@dir.example.com
        export IMPORT_SITE_DIR="$dir/oldsite" IMPORT_DB_DUMP="$dir/dump.sql"
        [ -z "$rules" ] || export IMPORT_NGINX_REWRITES="$rules"
        bash ./setup.sh
    ) > "$dir/output.log" 2>&1
}

check_case() {
    local dir=$fixture/$1 site=$fixture/$1/www/dir.example.com
    if grep -Fxq wait "$dir/calls" 2>/dev/null && ! grep -q '^unexpected:' "$dir/calls" &&
        [ -s "$site/admin/include/setup.php" ] &&
        grep -Fxq "$2" "$site/_INSTALL/nginx_config.txt" 2>/dev/null; then
        echo "PASS: $3"
        return 0
    fi
    { grep -E 'ERROR|could not' "$dir/output.log"; grep '^unexpected:' "$dir/calls"; } | sed 's/\x1b\[[0-9;]*m//g' >&2
    echo "FAIL: $3" >&2
    return 1
}

status=0
run_case install-rules yes
check_case install-rules 'rewrite ^/videos/$ /videos.php last;' \
    "a site directory's own _INSTALL/nginx_config.txt is used and MariaDB is reached" || status=1
run_case explicit-rules no 'rewrite ^/albums/$ /albums.php last;'
check_case explicit-rules 'rewrite ^/albums/$ /albums.php last;' \
    'IMPORT_NGINX_REWRITES with a site directory reaches MariaDB with the site in place' || status=1
exit "$status"
