#!/bin/bash
# Exercise the SQL from both installers on the same MariaDB fixtures.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
image=$("$root/docker/bin/resolve-bases.sh" --get mariadb 11.4)
if ! docker image inspect "$image" >/dev/null 2>&1; then
    if [ "${CI:-}" = true ]; then
        echo "FAIL: storage URL checks require the pinned MariaDB 11.4 image" >&2
        exit 1
    fi
    echo "SKIP: storage URL checks need the local MariaDB 11.4 image"
    exit 0
fi
work=$(mktemp -d)
container=
cleanup() {
    [ -z "$container" ] || docker rm -fv "$container" >/dev/null
    rm -rf "$work"
}
trap cleanup EXIT
container=$(docker run -d --pull never --network none --tmpfs /var/lib/mysql \
    -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=fixture "$image" \
    --innodb-buffer-pool-size=32M)
for ((i=0; i<120; i++)); do
    docker exec "$container" healthcheck.sh --connect --innodb_initialized >/dev/null 2>&1 && break
    sleep 1
done
export container
mariadb() { docker exec -i "$container" mariadb -uroot "$@"; }
export -f mariadb
mariadb fixture <<'SQL'
CREATE TABLE ktvs_admin_servers (server_id INT PRIMARY KEY AUTO_INCREMENT, urls TEXT, expected TEXT, path TEXT, streaming_skip_ssl_check INT);
CREATE TABLE ktvs_admin_conversion_servers (path TEXT);
SQL
cat > "$work/common" <<'SH'
get_tables_prefix() { echo ktvs_; }
get_project_url() { echo https://site.test; }
log_info() { echo "$*"; }
log_warn() { echo "$*"; }
log_error() { echo "$*" >&2; }
db_exec() { mariadb fixture -e "$1"; }
db_query() { mariadb fixture -N -e "$1"; }
SH
sed "s|source /init/lib/common.sh|source $work/common|" \
    "$root/docker/init/docker-entrypoint.d/40-configure-database.sh" > "$work/configure.sh"
export DOMAIN=site.test URL=site.test KVS_PATH="$work/site" SSL_PROVIDER=public IMPORT_SOURCE_DOMAIN=old.test
mkdir -p "$KVS_PATH/admin/data"
run_installer() {
    if [ "$1" = docker ]; then
        bash "$work/configure.sh"
    else
        # shellcheck disable=SC2016  # The child shell sources the installer.
        bash -c 'source "$1"; configure_kvs_servers fixture' _ "$root/kvs-install.sh"
    fi
}
for installer in docker native; do
    host=$DOMAIN
    [ "$installer" != docker ] || host=$IMPORT_SOURCE_DOMAIN
    # A remote first line, two old local URLs, mixed LF/CRLF and an old
    # URL embedded in a CDN query, which is not itself a storage endpoint.
    mariadb fixture <<SQL
DELETE FROM ktvs_admin_servers;
SET @remote = 'https://cdn.test/file?next=http://${host}/contents/nested';
INSERT INTO ktvs_admin_servers (urls, expected) VALUES (
    CONCAT(@remote, CHAR(13,10), 'http://www.${host}:81/contents/a', CHAR(10), 'https://${host}:82/contents/b'),
    CONCAT(@remote, CHAR(13,10), 'https://site.test/contents/a', CHAR(10), 'https://site.test/contents/b'));
SQL
    run_installer "$installer" > "$work/$installer.log" 2>&1 || { cat "$work/$installer.log"; exit 1; }
    if [ "$installer" = docker ]; then
        grep -Fq "Server URLs configured:" "$work/$installer.log" || { echo "FAIL: no local endpoint counted"; exit 1; }
    fi
    [ "$(mariadb fixture -N -e 'SELECT urls = BINARY expected FROM ktvs_admin_servers')" = 1 ] ||
        { echo "FAIL: $installer did not rewrite exactly the local URL lines" >&2; exit 1; }

    # A trigger models a write that returns success but leaves a later
    # line stale. A canonical first line must not mask the failure.
    mariadb fixture <<SQL
UPDATE ktvs_admin_servers SET urls = CONCAT('https://site.test/contents/a', CHAR(10), 'http://${host}/contents/b');
CREATE TRIGGER keep_urls BEFORE UPDATE ON ktvs_admin_servers FOR EACH ROW SET NEW.urls = OLD.urls;
SQL
    if run_installer "$installer" > "$work/$installer.log" 2>&1; then
        echo "FAIL: $installer accepted a stale second URL" >&2
        exit 1
    fi
    grep -Fq 'do not match' "$work/$installer.log"
    mariadb fixture -e 'DROP TRIGGER keep_urls'
done
# The verification flag applies to the whole row, including later endpoints.
mariadb fixture <<'SQL'
TRUNCATE ktvs_admin_servers;
SET @local = 'https://site.test/contents/a', @cdn = 'https://cdn.test/contents/b';
INSERT INTO ktvs_admin_servers (urls, streaming_skip_ssl_check) VALUES
    (CONCAT(@local, CHAR(13,10), @cdn), 1), (CONCAT(@cdn, CHAR(10), @local), 1),
    (CONCAT(@local, CHAR(13,10), @local, CHAR(10)), 0), (@cdn, 1), (@cdn, 0);
SQL
MODE=multi SSL_PROVIDER=selfsigned run_installer docker > "$work/policy.log"
flags=$(mariadb fixture -N -e 'SELECT GROUP_CONCAT(streaming_skip_ssl_check ORDER BY server_id) FROM ktvs_admin_servers')
[ "$flags" = '0,0,1,1,0' ] || { echo "FAIL: storage TLS flags $flags"; exit 1; }
for id in 1 2; do grep -Fq "Storage server $id mixes" "$work/policy.log"; done
mariadb fixture <<'SQL'
DELETE FROM ktvs_admin_servers;
INSERT INTO ktvs_admin_servers (urls) VALUES ('https://cdn.test/b'),
    (CONCAT('https://cdn.test/b', CHAR(10), 'https://site.test/other'));
SQL
run_installer docker > "$work/count.log"
grep -Fq 'external hosts (1)' "$work/count.log"

# Execute the reconfiguration update and its verification on the same database.
# A remote first line exercises the WHERE and the matching counter separately
# from a canonical first line that could hide a stale second URL.
reconfigure=$root/docker/reconfigure.sh
sed -n '/^run_application_update_query() {/,/^}/p; /^DOMAIN_PATTERN=/,/^$/p' "$reconfigure" > "$work/update"
# shellcheck disable=SC2016  # Match the shell assignment in the source.
sed -n '/^if ! MATCHING_URL_COUNT=$(run_scalar_query/,/^if ! run_query/{ /^if ! run_query/!p; }' \
    "$reconfigure" > "$work/check"
reconfigure_urls() (
    set -e
    # shellcheck disable=SC2034
    MODE=single TABLES_PREFIX=ktvs_ EXPECTED_SSL_SKIP=${1:-0} SERVER_URL=https://site.test:8443
    # shellcheck disable=SC2034
    RED='' NC=''
    # shellcheck disable=SC2329  # Called by the extracted SQL.
    run_query() { mariadb fixture -N -e "$1"; }
    # shellcheck disable=SC2329
    run_scalar_query() { run_query "$1"; }
    # shellcheck disable=SC1091,SC1090
    source "$work/update"
    # shellcheck disable=SC1091,SC1090
    source "$work/check"
    printf 'matching=%s stale=%s\n' "$MATCHING_URL_COUNT" "$STALE_PROJECT_URL_COUNT"
)
mariadb fixture <<'SQL'
DELETE FROM ktvs_admin_servers;
SET @cdn = 'https://cdn.test/?source=https://site.test/contents/nested';
INSERT INTO ktvs_admin_servers (urls, expected, streaming_skip_ssl_check) VALUES
    (CONCAT(@cdn, CHAR(13,10), 'https://site.test/contents/a', CHAR(10), 'https://www.site.test:443/contents/b'),
     CONCAT(@cdn, CHAR(13,10), 'https://site.test:8443/contents/a', CHAR(10), 'https://site.test:8443/contents/b'), 0),
    -- http endpoints of the site, first or later in the field, as both installers rewrite them.
    (CONCAT('http://site.test/contents/c', CHAR(10), @cdn, CHAR(10), 'http://www.site.test:81/contents/d'),
     CONCAT('https://site.test:8443/contents/c', CHAR(10), @cdn, CHAR(10), 'https://site.test:8443/contents/d'), 0),
    ('http://cdn.test/contents/e', 'http://cdn.test/contents/e', 0),
    -- Names that only contain the site's name are other hosts.
    ('http://sub.site.test/contents/x', 'http://sub.site.test/contents/x', 0),
    ('http://site.test.example/contents/x', 'http://site.test.example/contents/x', 0),
    ('http://sitextest/contents/x', 'http://sitextest/contents/x', 0);
SQL
reconfigure_urls > "$work/reconfigure.log"
grep -Fxq 'matching=2 stale=0' "$work/reconfigure.log"
[ "$(mariadb fixture -N -e 'SELECT MIN(urls = BINARY expected), COUNT(*) FROM ktvs_admin_servers')" = $'1\t6' ] ||
    { echo "FAIL: reconfiguration did not rewrite exactly the local URL lines" >&2; exit 1; }
# Reconfiguration uses the same row-wide TLS policy after the URL rewrite.
mariadb fixture <<'SQL'
TRUNCATE ktvs_admin_servers;
SET @local = 'http://www.site.test:81/contents/a', @cdn = 'https://cdn.test/b';
INSERT INTO ktvs_admin_servers (urls, streaming_skip_ssl_check) VALUES
    (CONCAT(@local, CHAR(13,10), @cdn), 1), (CONCAT(@cdn, CHAR(10), @local), 1),
    (CONCAT(@local, CHAR(13,10), @local, CHAR(10)), 0), (@cdn, 1), (@cdn, 0);
SQL
reconfigure_urls 1 > "$work/reconfigure.log" || { cat "$work/reconfigure.log"; exit 1; }
flags=$(mariadb fixture -N -e 'SELECT GROUP_CONCAT(streaming_skip_ssl_check ORDER BY server_id) FROM ktvs_admin_servers')
[ "$flags" = '0,0,1,1,0' ] || { echo "FAIL: reconfigured storage TLS flags $flags"; exit 1; }
echo "PASS: reconfigured storage TLS flags $flags"
mariadb fixture <<'SQL'
UPDATE ktvs_admin_servers SET streaming_skip_ssl_check = 1 WHERE server_id = 2;
CREATE TRIGGER keep_flag BEFORE UPDATE ON ktvs_admin_servers FOR EACH ROW
    SET NEW.streaming_skip_ssl_check = OLD.streaming_skip_ssl_check;
SQL
if reconfigure_urls 1 > "$work/reconfigure.log" 2>&1; then
    echo "FAIL: reconfiguration accepted a mixed row with verification disabled" >&2
    exit 1
fi
grep -Fq 'do not match the requested state' "$work/reconfigure.log"
mariadb fixture -e 'DROP TRIGGER keep_flag; UPDATE ktvs_admin_servers SET streaming_skip_ssl_check = 0'
mariadb fixture <<'SQL'
UPDATE ktvs_admin_servers SET urls = CONCAT('https://site.test:8443/contents/a', CHAR(13,10), 'https://site.test/contents/b');
CREATE TRIGGER keep_urls BEFORE UPDATE ON ktvs_admin_servers FOR EACH ROW SET NEW.urls = OLD.urls;
SQL
if reconfigure_urls > "$work/reconfigure.log" 2>&1; then
    echo "FAIL: reconfiguration accepted a stale second URL" >&2
    exit 1
fi
grep -Fq 'do not match the requested state' "$work/reconfigure.log"
# An http endpoint that stays behind is stale as well.
mariadb fixture <<'SQL'
DROP TRIGGER keep_urls;
UPDATE ktvs_admin_servers SET urls = CONCAT('https://site.test:8443/contents/a', CHAR(10), 'http://site.test/contents/b');
CREATE TRIGGER keep_urls BEFORE UPDATE ON ktvs_admin_servers FOR EACH ROW SET NEW.urls = OLD.urls;
SQL
if reconfigure_urls > "$work/reconfigure.log" 2>&1; then
    echo "FAIL: reconfiguration accepted a stale http URL" >&2
    exit 1
fi
grep -Fq 'do not match the requested state' "$work/reconfigure.log"
echo "PASS: both installers and reconfiguration rewrite and verify individual storage URLs"
